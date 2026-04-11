#!/bin/bash
# tools/check-exec-sh.sh: Flag unsafe string concatenation into `exec sh` in .ag files.
#
# Colony agents build shell commands by concatenating strings and pass the
# result to `exec sh`. LLM-tainted values (titles, descriptions, usernames,
# label names) must be wrapped in `shell_escape(...)` before concatenation
# or the agent is vulnerable to shell injection. This was the root cause of
# issue #49 / PR #56 in the triage colony.
#
# This checker is a grep-level guardrail: for every variable that is later
# passed to `exec sh`, it scans `let <var> = ...` assignments in the same
# file and flags any `+` concatenation segment that is not one of:
#
#   - a string literal (starts with `"`)
#   - `shell_escape(...)`
#   - `to_string(...)`
#
# Indirection through function calls (e.g. `let cmd = issues_cmd()`) is not
# followed — this is deliberate, per #57 ("grep-level check, not a full
# parser"). Authors can suppress a finding on a line that the checker
# cannot prove safe by adding `// colony-lint: safe-exec-concat` to the
# same line or the preceding line.
#
# Usage: ./tools/check-exec-sh.sh [path]
# Exit 0 if no unsafe patterns, 1 if one or more findings, 2 on usage error.

set -euo pipefail

SCAN_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ ! -e "$SCAN_ROOT" ]; then
    echo "check-exec-sh: scan root does not exist: $SCAN_ROOT" >&2
    exit 2
fi

FAIL=0

# is_safe_segment <trimmed_segment>
# Return 0 if the segment is one of the known-safe forms, 1 otherwise.
is_safe_segment() {
    local seg="$1"
    case "$seg" in
        '"'*)            return 0 ;;  # string literal
        'shell_escape('*) return 0 ;;
        'to_string('*)   return 0 ;;
    esac
    return 1
}

# trim <string>
trim() {
    local s="$1"
    # strip leading whitespace
    s="${s#"${s%%[![:space:]]*}"}"
    # strip trailing whitespace
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# check_file <path>
# Scan one .ag file. Prints findings to stdout. Returns 0 always; the
# caller tracks FAIL via the global counter.
check_file() {
    local ag_file="$1"

    # Collect unique identifiers appearing on the RHS of `exec sh`.
    # We intentionally only match bare identifiers — `exec sh "literal"`
    # (with a string literal) is always safe and never flagged.
    # Trailing `|| true` so that a file with zero matches does not trip
    # `set -e` on the grep-returns-1 path.
    local exec_vars
    exec_vars="$(grep -oE 'exec[[:space:]]+sh[[:space:]]+[a-zA-Z_][a-zA-Z_0-9]*' "$ag_file" 2>/dev/null \
        | awk '{print $NF}' | sort -u || true)"

    [ -z "$exec_vars" ] && return 0

    local var
    while IFS= read -r var; do
        [ -z "$var" ] && continue

        # Find every `let <var> = ...` line in this file.
        local match
        while IFS= read -r match; do
            [ -z "$match" ] && continue

            local line_no rhs
            line_no="${match%%:*}"
            rhs="${match#*:}"

            # Suppression comment on the same line.
            if printf '%s' "$rhs" | grep -q 'colony-lint: safe-exec-concat'; then
                continue
            fi

            # Suppression comment on the preceding line.
            local prev=""
            if [ "$line_no" -gt 1 ]; then
                prev="$(sed -n "$((line_no - 1))p" "$ag_file" 2>/dev/null || true)"
            fi
            if printf '%s' "$prev" | grep -q 'colony-lint: safe-exec-concat'; then
                continue
            fi

            # Strip `let <var> =` prefix and trailing `;`.
            rhs="${rhs#*=}"
            rhs="${rhs%%;*}"

            # No concatenation → nothing to check (pure literal or function
            # call, both of which this checker trusts by design).
            case "$rhs" in
                *'+'*) ;;
                *) continue ;;
            esac

            # Naive split on `+`. This does not correctly tokenize `+`
            # inside string literals or function arguments, but none of
            # the colony `.ag` files currently exercise that pattern. If
            # a future file does, the checker will produce a false
            # positive and the author can suppress it with the inline
            # comment — better loud than silent.
            local IFS_save="$IFS"
            IFS='+'
            # shellcheck disable=SC2206  # intentional word-splitting on +
            local segments=( $rhs )
            IFS="$IFS_save"

            local seg trimmed
            for seg in "${segments[@]}"; do
                trimmed="$(trim "$seg")"
                [ -z "$trimmed" ] && continue
                if ! is_safe_segment "$trimmed"; then
                    # SC2016 disable: the backticked `// colony-lint:
                    # safe-exec-concat` token is a literal comment that
                    # authors paste into `.ag` source, not a shell expansion.
                    # shellcheck disable=SC2016
                    printf '[UNSAFE] %s:%s: let %s = ... + %s (wrap in shell_escape or to_string, or annotate with `// colony-lint: safe-exec-concat`)\n' \
                        "$ag_file" "$line_no" "$var" "$trimmed"
                    FAIL=$((FAIL + 1))
                fi
            done
        done < <(grep -nE "^[[:space:]]*let[[:space:]]+${var}[[:space:]]*=" "$ag_file" || true)
    done <<< "$exec_vars"
}

# Main: walk .ag files under SCAN_ROOT.
if [ -f "$SCAN_ROOT" ]; then
    check_file "$SCAN_ROOT"
else
    while IFS= read -r -d '' f; do
        check_file "$f"
    done < <(find "$SCAN_ROOT" -type f -name '*.ag' -print0)
fi

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "check-exec-sh: $FAIL unsafe concat finding(s)"
    exit 1
fi

exit 0
