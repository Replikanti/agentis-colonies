#!/bin/bash
# tools/check-impl-prompt-gate.sh: Flag unguarded `prompt()` calls in implementation/agents/*.ag.
#
# The implementation colony is wired to run many times per minute against a
# GitLab project. If an `implementation/` agent calls `prompt()` without a
# memo-based staleness gate, a single stuck issue or stuck MR can drive
# ~60 LLM calls per hour per agent. Issue #200 / PR #204 fixed the three
# ticking agents; this lint prevents a future implementation/ agent from
# silently re-introducing the same drift.
#
# Rule: every `prompt(...)` call in a `*.ag` file under
# `*/implementation/agents/` must be preceded within the same function by
# either:
#   1. a `recall_latest(...)` read, or
#   2. a call to a "gate function" — a free function defined in the same
#      file whose body contains `recall_latest(...)`.
#
# Authors can suppress a false positive on a specific line by adding
# `// colony-lint: impl-prompt-gate-ok` to the `prompt(` line itself or to
# the preceding line. Prefer a real memo gate; use the suppression only
# when the prompt is on a proven cold-path (e.g., guarded by upstream
# emitters that already carry memo gates).
#
# This is a grep/awk-level check, not a full parser. Known caveats:
#   - Gate check is textual within-function. If `recall_latest()` appears
#     in one branch of an `if/else` and `prompt()` in a sibling branch,
#     the check passes but the prompt is in fact unguarded. Use the
#     suppression comment if you hit this deliberately; fix the code
#     otherwise.
#   - `/* */` block comments are not recognised (no .ag file uses them).
#   - Braces inside string literals (e.g., `"{ foo }"`) are ignored by
#     stripping `//` line comments only; none of the current .ag files
#     exercises that pattern.
#
# Usage: ./tools/check-impl-prompt-gate.sh [path]
# Exit 0 if no unguarded prompts, 1 if one or more findings, 2 on usage error.

set -euo pipefail

SCAN_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ ! -e "$SCAN_ROOT" ]; then
    echo "check-impl-prompt-gate: scan root does not exist: $SCAN_ROOT" >&2
    exit 2
fi

FAIL=0

# check_file <path>
# Scan one .ag file. Prints findings to stdout. Updates global FAIL.
check_file() {
    local ag_file="$1"

    # Pass 1: collect gate function names — fns whose body contains
    # `recall_latest(`. Output: one name per line.
    local gate_fns
    gate_fns="$(awk '
        BEGIN { depth = 0; in_fn = 0; fn_name = ""; gate_seen = 0 }

        {
            # Detect top-level `fn NAME(` when not already inside one.
            if (!in_fn && depth == 0 && match($0, /^[[:space:]]*fn[[:space:]]+[a-zA-Z_][a-zA-Z_0-9]*/)) {
                s = substr($0, RSTART, RLENGTH)
                sub(/^[[:space:]]*fn[[:space:]]+/, "", s)
                fn_name = s
                in_fn = 1
                gate_seen = 0
            }

            if (in_fn && $0 ~ /recall_latest[[:space:]]*\(/) {
                gate_seen = 1
            }

            # Update brace depth using a copy with line-comments stripped.
            line = $0
            sub(/\/\/.*$/, "", line)
            opens = gsub(/\{/, "", line)
            closes = gsub(/\}/, "", line)
            depth += opens - closes

            if (in_fn && depth <= 0) {
                if (gate_seen && fn_name != "") print fn_name
                in_fn = 0
                fn_name = ""
                gate_seen = 0
                if (depth < 0) depth = 0
            }
        }
    ' "$ag_file" | sort -u)"

    # Pass 2: flag each `prompt(` call inside a fn that was not preceded
    # within the same fn by `recall_latest(` or a gate-fn call.
    local findings
    findings="$(awk -v gate_fns_str="$gate_fns" -v file="$ag_file" '
        BEGIN {
            n = split(gate_fns_str, arr, "\n")
            for (i = 1; i <= n; i++) {
                if (arr[i] != "") gate_fns[arr[i]] = 1
            }
            depth = 0; in_fn = 0; fn_name = ""; gate_seen = 0
            prev_line = ""
        }

        {
            entered_fn_this_line = 0
            if (!in_fn && depth == 0 && match($0, /^[[:space:]]*fn[[:space:]]+[a-zA-Z_][a-zA-Z_0-9]*/)) {
                s = substr($0, RSTART, RLENGTH)
                sub(/^[[:space:]]*fn[[:space:]]+/, "", s)
                fn_name = s
                in_fn = 1
                gate_seen = 0
                entered_fn_this_line = 1
            }

            if (in_fn) {
                # Rule 1: recall_latest() in same fn.
                if ($0 ~ /recall_latest[[:space:]]*\(/) gate_seen = 1

                # Rule 2: call to a known gate function in same fn.
                if (!gate_seen) {
                    for (g in gate_fns) {
                        # `g(` where `g` is a whole-word identifier.
                        # [^a-zA-Z_0-9] ensures we do not match a prefix
                        # of another name.
                        pat = "(^|[^a-zA-Z_0-9])" g "[[:space:]]*\\("
                        if ($0 ~ pat) { gate_seen = 1; break }
                    }
                }

                # Check for `prompt(` on this line — but only flag if this
                # is not the `fn prompt(` definition line itself (defensive;
                # agentis has no user-defined prompt function but belt-and-braces).
                if (!entered_fn_this_line && $0 ~ /prompt[[:space:]]*\(/) {
                    # Exclude the standalone `fn prompt(` definition case.
                    if ($0 !~ /^[[:space:]]*fn[[:space:]]+prompt[[:space:]]*\(/) {
                        suppressed = 0
                        if ($0 ~ /colony-lint:[[:space:]]*impl-prompt-gate-ok/) suppressed = 1
                        else if (prev_line ~ /colony-lint:[[:space:]]*impl-prompt-gate-ok/) suppressed = 1

                        if (!suppressed && !gate_seen) {
                            printf "[UNGATED] %s:%d: prompt() in fn `%s` is not preceded by recall_latest() or a gate-fn call (add a memo gate or annotate with `// colony-lint: impl-prompt-gate-ok`)\n", file, NR, fn_name
                        }
                    }
                }
            }

            # Update brace depth for next iteration.
            line = $0
            sub(/\/\/.*$/, "", line)
            opens = gsub(/\{/, "", line)
            closes = gsub(/\}/, "", line)
            depth += opens - closes

            if (in_fn && depth <= 0) {
                in_fn = 0
                fn_name = ""
                gate_seen = 0
                if (depth < 0) depth = 0
            }

            prev_line = $0
        }
    ' "$ag_file")"

    if [ -n "$findings" ]; then
        printf '%s\n' "$findings"
        local count
        count="$(printf '%s\n' "$findings" | grep -c '^\[UNGATED\]' || true)"
        FAIL=$((FAIL + count))
    fi
}

# Main: walk only implementation/agents/*.ag files under SCAN_ROOT.
if [ -f "$SCAN_ROOT" ]; then
    # Single-file mode: scan regardless of path (useful for testing).
    check_file "$SCAN_ROOT"
else
    while IFS= read -r -d '' f; do
        check_file "$f"
    done < <(find "$SCAN_ROOT" -type f -path '*/implementation/agents/*.ag' -print0)
fi

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "check-impl-prompt-gate: $FAIL unguarded prompt() finding(s)"
    exit 1
fi

exit 0
