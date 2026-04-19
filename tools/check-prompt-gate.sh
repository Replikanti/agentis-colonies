#!/bin/bash
# tools/check-prompt-gate.sh: Flag unguarded `prompt()` calls in ticking colonies.
#
# The implementation, planning, code-review, and triage colonies are wired
# to run many times per minute against a GitLab project. If one of their
# agents calls `prompt()` without a memo-based staleness gate, a single
# stuck issue or stuck MR can drive ~60 LLM calls per hour per agent.
# Earlier PRs fixed three code paths one-by-one: #200 / PR #204
# (implementation drafts), #187 / PR #190 (planning observe-step),
# #201 / PR #206 (code-review pattern-learning). This lint prevents
# future edits from silently (re-)introducing the same drift pattern in
# any of the four ticking colonies. Scope was initially implementation-only
# (#205 / PR #207), extended to planning + code-review in #208, and
# extended preventively to triage in #210.
#
# Triage coverage is purely preventive (no prior drift incident occurred,
# unlike the other three colonies). Triage ticks every 60–180s per #146,
# so an unguarded `prompt()` would have the same cost impact as the
# already-covered colonies.
#
# Rule: every `prompt(...)` call in a `*.ag` file under
# `*/implementation/agents/`, `*/planning/agents/`, `*/code-review/agents/`,
# or `*/triage/agents/` must be preceded within the same function by
# either:
#   1. a `recall_latest(...)` read, or
#   2. a call to a "gate function" — a free function defined in the same
#      file whose body contains `recall_latest(...)`.
#
# Authors can suppress a false positive on a specific line by adding
# `// colony-lint: prompt-gate-ok` (or the legacy alias
# `// colony-lint: impl-prompt-gate-ok`) to the `prompt(` line itself or
# to the preceding line. Prefer a real memo gate; use the suppression
# only when the prompt is on a proven cold-path (e.g., guarded by
# upstream emitters that already carry memo gates).
#
# This is a grep/awk-level check, not a full parser. Known caveats:
#   - Gate check is textual within-function. If `recall_latest()` appears
#     in one branch of an `if/else` and `prompt()` in a sibling branch,
#     the check passes but the prompt is in fact unguarded. Use the
#     suppression comment if you hit this deliberately; fix the code
#     otherwise.
#   - `/* */` block comments are not recognised (no .ag file uses them).
#     `//` line comments are stripped before matching, so neither
#     `prompt(` nor `recall_latest(` nor a gate-fn name inside a `//`
#     comment triggers the checker.
#   - Same-line ordering is respected: if a gate call appears AFTER a
#     `prompt(` on the same physical line, it does NOT cover that
#     prompt (only triggers on subsequent lines).
#   - Braces or `prompt(` tokens inside string literals are not
#     specially handled (comments are, string literals are not) — none
#     of the current .ag files exercises that pattern.
#
# Usage: ./tools/check-prompt-gate.sh [path]
# Exit 0 if no unguarded prompts, 1 if one or more findings, 2 on usage error.

set -euo pipefail

SCAN_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ ! -e "$SCAN_ROOT" ]; then
    echo "check-prompt-gate: scan root does not exist: $SCAN_ROOT" >&2
    exit 2
fi

FAIL=0

# check_file <path>
# Scan one .ag file. Prints findings to stdout. Updates global FAIL.
check_file() {
    local ag_file="$1"

    # Pass 1: collect gate function names — fns whose body contains
    # `recall_latest(` (outside of a `//` line comment). Output: one
    # name per line.
    local gate_fns
    gate_fns="$(awk '
        BEGIN { depth = 0; in_fn = 0; fn_name = ""; gate_seen = 0 }

        {
            # `clean` is the line with any `//` line-comment stripped,
            # so comments cannot trigger gate detection or brace counting.
            clean = $0
            sub(/\/\/.*$/, "", clean)

            # Detect top-level `fn NAME(` when not already inside one.
            if (!in_fn && depth == 0 && match(clean, /^[[:space:]]*fn[[:space:]]+[a-zA-Z_][a-zA-Z_0-9]*/)) {
                s = substr(clean, RSTART, RLENGTH)
                sub(/^[[:space:]]*fn[[:space:]]+/, "", s)
                fn_name = s
                in_fn = 1
                gate_seen = 0
            }

            if (in_fn && clean ~ /recall_latest[[:space:]]*\(/) {
                gate_seen = 1
            }

            opens = gsub(/\{/, "", clean)
            closes = gsub(/\}/, "", clean)
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
            prev_clean = ""
        }

        # is_gated(text): return 1 if `text` contains a gate trigger.
        function is_gated(text,    g, pat) {
            if (text ~ /recall_latest[[:space:]]*\(/) return 1
            for (g in gate_fns) {
                pat = "(^|[^a-zA-Z_0-9])" g "[[:space:]]*\\("
                if (text ~ pat) return 1
            }
            return 0
        }

        {
            # Strip `//` line-comments before any matching so that
            # `prompt(`, `recall_latest(`, and gate-fn names inside a
            # comment are ignored.
            clean = $0
            sub(/\/\/.*$/, "", clean)

            entered_fn_this_line = 0
            if (!in_fn && depth == 0 && match(clean, /^[[:space:]]*fn[[:space:]]+[a-zA-Z_][a-zA-Z_0-9]*/)) {
                s = substr(clean, RSTART, RLENGTH)
                sub(/^[[:space:]]*fn[[:space:]]+/, "", s)
                fn_name = s
                in_fn = 1
                gate_seen = 0
                entered_fn_this_line = 1
            }

            if (in_fn && !entered_fn_this_line) {
                # Check for a `prompt(` on this line first, so that a
                # gate call that appears AFTER the prompt on the same
                # physical line does not retroactively "cover" it.
                pp = match(clean, /prompt[[:space:]]*\(/)
                if (pp > 0) {
                    # Only the portion of the line BEFORE the `prompt(`
                    # counts as a preceding gate for this specific prompt.
                    left = substr(clean, 1, pp - 1)
                    local_gate = gate_seen
                    if (!local_gate && is_gated(left)) local_gate = 1

                    suppressed = 0
                    # Suppression comment check uses the ORIGINAL line so
                    # `// colony-lint: prompt-gate-ok` (or the legacy alias
                    # `// colony-lint: impl-prompt-gate-ok`) is visible.
                    # The trailing `($|[[:space:]]|[^a-z0-9-])` is a
                    # word-boundary — without it, a typo like
                    # `prompt-gate-okey` would spuriously suppress the check.
                    if ($0 ~ /colony-lint:[[:space:]]*(impl-)?prompt-gate-ok($|[[:space:]]|[^a-z0-9-])/) suppressed = 1
                    else if (prev_original ~ /colony-lint:[[:space:]]*(impl-)?prompt-gate-ok($|[[:space:]]|[^a-z0-9-])/) suppressed = 1

                    if (!suppressed && !local_gate) {
                        printf "[UNGATED] %s:%d: prompt() in fn `%s` is not preceded by recall_latest() or a gate-fn call (add a memo gate or annotate with `// colony-lint: prompt-gate-ok`)\n", file, NR, fn_name
                    }
                }

                # Update gate_seen from the whole cleaned line AFTER the
                # prompt check so that gate triggers carry forward to
                # subsequent lines.
                if (!gate_seen && is_gated(clean)) gate_seen = 1
            }

            opens = gsub(/\{/, "", clean)
            closes = gsub(/\}/, "", clean)
            depth += opens - closes

            if (in_fn && depth <= 0) {
                in_fn = 0
                fn_name = ""
                gate_seen = 0
                if (depth < 0) depth = 0
            }

            prev_original = $0
        }
    ' "$ag_file")"

    if [ -n "$findings" ]; then
        printf '%s\n' "$findings"
        local count
        count="$(printf '%s\n' "$findings" | grep -c '^\[UNGATED\]' || true)"
        FAIL=$((FAIL + count))
    fi
}

# Main: walk *.ag files in the four ticking agent directories.
# Covers all four ticking colonies that contain prompt()-based agents
# that must be protected by a staleness gate (see #200, #201, #205, #208,
# and #210 — triage coverage is preventive, not reactive).
if [ -f "$SCAN_ROOT" ]; then
    # Single-file mode: scan regardless of path (useful for testing).
    check_file "$SCAN_ROOT"
else
    while IFS= read -r -d '' f; do
        check_file "$f"
    done < <(find "$SCAN_ROOT" -type f \( \
        -path '*/implementation/agents/*.ag' -o \
        -path '*/planning/agents/*.ag' -o \
        -path '*/code-review/agents/*.ag' -o \
        -path '*/triage/agents/*.ag' \
    \) -print0)
fi

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "check-prompt-gate: $FAIL unguarded prompt() finding(s)"
    exit 1
fi

exit 0
