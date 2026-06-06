#!/bin/bash
# tools/check-llm-prompt-list-ops.sh: Flag broken push() patterns in LLM
# prompt strings inside research-foundry agent .ag files.
#
# Why this exists (#943): the agentis `push(list, x)` builtin is PURE --
# it returns a NEW list and does NOT mutate the input. Several
# research-foundry agents (notably explorer.ag) embed `.ag` source as
# example code inside their LLM prompt strings, and the LLM copies that
# example shape verbatim. A bare `push(acc, x);` in such an example
# teaches the LLM to discard the new list, so the explorer-emitted code
# silently produces empty lists, the novelty / verifier / auditor chain
# never lands a NOVEL verdict, and the federation produces 0 preprints
# (the empirical failure mode that surfaced in run 20260603T181235Z:
# 48 of 50 explorer codes used bare `push(acc, x);` -> 0 preprints over
# multiple takes).
#
# Rule: inside a double-quoted string literal in any *.ag file under
# `research-foundry/<colony>/agents/`, a bare `push(...);` statement
# (`push` followed by parens followed by `;`) is FORBIDDEN unless the
# call is captured by a surrounding `let <name> = push(...)` or
# `<name> = push(...)` binding on the same physical line, or the line
# above carries the escape comment `// colony-lint: prompt-push-ok`.
#
# Authors can suppress a false positive on a specific line by adding
# `// colony-lint: prompt-push-ok` to the preceding line.
#
# Implementation: per-line awk pass. The vast majority of agentis-prompt
# examples are emitted as a single very-long line (the prompt string is
# one return literal). We track whether each line is "inside a string"
# by counting unescaped `"` chars before each `push(` match. We do NOT
# attempt to parse the .ag grammar -- false positives in real code can
# be silenced by the escape comment.
#
# Known caveats:
#   - Only `push(` is matched; other pure builtins (`concat`,
#     `substring`, ...) are not yet checked.
#   - A `push(...);` whose left bracket is on one line and right
#     bracket on the next would be missed. No such case exists in
#     research-foundry today (prompts are single-line return literals).
#   - `//` line comments inside a prompt string are NOT stripped (a
#     `push(` mention inside such a comment would still trigger; not
#     observed in practice).
#
# Usage: ./tools/check-llm-prompt-list-ops.sh [path]
# Exit 0 if no findings, 1 if one or more findings, 2 on usage error.

set -euo pipefail

SCAN_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ ! -e "$SCAN_ROOT" ]; then
    echo "check-llm-prompt-list-ops: scan root does not exist: $SCAN_ROOT" >&2
    exit 2
fi

FAIL=0

check_file() {
    local ag_file="$1"
    local findings
    findings="$(awk -v file="$ag_file" '
        # is_inside_string(line, pos): return 1 if column `pos` (1-based)
        # sits inside a double-quoted string literal on `line`. Counts
        # unescaped `"` chars in `line[1..pos-1]`. Backslash-escaped
        # quotes do not toggle.
        function is_inside_string(line, pos,    i, c, q, in_s) {
            in_s = 0
            i = 1
            while (i < pos) {
                c = substr(line, i, 1)
                if (c == "\\") { i += 2; continue }
                if (c == "\"") in_s = !in_s
                i += 1
            }
            return in_s
        }

        # find_next_push(line, start): return the column of the next
        # `push(` token at or after column `start`, or 0 if none. Uses
        # `index()` rather than `match()` so RLENGTH does not get
        # clobbered elsewhere.
        function find_next_push(line, start,    rest, hit) {
            rest = substr(line, start)
            hit = index(rest, "push(")
            if (hit == 0) return 0
            return start + hit - 1
        }

        # check_line(line, lineno, prev): scan one line for bare
        # `push(...);` patterns inside a string literal.
        function check_line(line, lineno, prev,    p, after_idx, end_paren, after_close, captured, before, before_tail, suppressed, snip_start_disp, snip) {
            p = find_next_push(line, 1)
            while (p > 0) {
                # Skip if this `push(` is not inside a string literal.
                if (!is_inside_string(line, p)) {
                    p = find_next_push(line, p + 5)
                    continue
                }

                # Find the matching `)` for this `push(`. We scan
                # forward from `p+5` counting paren depth.
                end_paren = find_matching_paren(line, p + 4)
                if (end_paren == 0) {
                    # Unbalanced -- skip.
                    p = find_next_push(line, p + 5)
                    continue
                }
                after_close = substr(line, end_paren + 1)

                # Bare statement form: `push(...);` -- the very next
                # non-space char after `)` is `;`. If anything else,
                # the call is being consumed by a surrounding
                # expression (return value used, arg to outer call, ...).
                if (after_close !~ /^[[:space:]]*;/) {
                    p = find_next_push(line, p + 5)
                    continue
                }

                # Brace-tail expression form: `push(...);` followed
                # immediately by `}` THEN an `else` (or another `}` from
                # a nested block whose outer block has an `else`). The
                # agentis idiom `let next = if cond { push(acc, x); }
                # else { acc; };` captures the push result via the
                # outer `let next = if {...} else {...};`. The bare
                # `if cond { push(acc, x); }; return ...` form (no
                # else) DROPS the push -- so we ONLY skip when an
                # `else` token appears between the closing `}` and the
                # next `;`.
                #
                # We look ahead in `after_close` for the first `;`
                # after the closing `}` chain. If we hit an `else`
                # first, treat as captured (skip). If we hit a `;`,
                # the if-statement form discarded the value -- FALL
                # THROUGH to the bad-push report.
                if (after_close ~ /^[[:space:]]*;[[:space:]]*\}/) {
                    lookahead = after_close
                    # Strip leading `;` and any number of `}` chars
                    # (with optional whitespace between) so we land at
                    # the first content after the brace-close chain.
                    sub(/^[[:space:]]*;[[:space:]]*/, "", lookahead)
                    while (lookahead ~ /^\}[[:space:]]*/) {
                        sub(/^\}[[:space:]]*/, "", lookahead)
                    }
                    if (lookahead ~ /^else([^a-zA-Z_0-9]|$)/) {
                        p = find_next_push(line, p + 5)
                        continue
                    }
                }

                # Capture check: look at the chars immediately before
                # `push(`. If they end in `let <name> = ` or `<name> = `,
                # treat as captured.
                before = substr(line, 1, p - 1)
                before_tail = before
                if (length(before_tail) > 60) before_tail = substr(before_tail, length(before_tail) - 60 + 1)

                captured = 0
                if (before_tail ~ /(^|[^a-zA-Z_0-9])let[[:space:]]+[a-zA-Z_][a-zA-Z_0-9]*[[:space:]]*=[[:space:]]*$/) captured = 1
                else if (before_tail ~ /[a-zA-Z_0-9][[:space:]]*=[[:space:]]*$/ && before_tail !~ /==[[:space:]]*$/) captured = 1

                if (captured) {
                    p = find_next_push(line, p + 5)
                    continue
                }

                # Suppression: `// colony-lint: prompt-push-ok` on the
                # previous line.
                suppressed = 0
                if (prev ~ /colony-lint:[[:space:]]*prompt-push-ok($|[[:space:]]|[^a-z0-9-])/) suppressed = 1

                if (!suppressed) {
                    if (p > 20) snip_start_disp = p - 20
                    else snip_start_disp = 1
                    snip = substr(line, snip_start_disp, 60)
                    gsub(/\\n/, "\\\\n", snip)
                    printf "[BAD-PUSH] %s:%d: bare `push(...);` inside LLM prompt string discards the new list (use `let acc = push(acc, x)` or annotate with `// colony-lint: prompt-push-ok`): ...%s...\n", file, lineno, snip
                }

                p = find_next_push(line, end_paren + 1)
            }
        }

        # find_matching_paren(line, open_pos): given that `line[open_pos]`
        # is `(`, return the column of the matching `)`, or 0 if not
        # found within a reasonable limit. Uses index/substring math
        # (no match() / RLENGTH) so callers are not affected.
        function find_matching_paren(line, open_pos,    depth, i, c, llen) {
            depth = 1
            i = open_pos + 1
            llen = length(line)
            while (i <= llen) {
                c = substr(line, i, 1)
                if (c == "(") depth += 1
                else if (c == ")") {
                    depth -= 1
                    if (depth == 0) return i
                }
                i += 1
            }
            return 0
        }

        BEGIN { prev = "" }
        { check_line($0, NR, prev); prev = $0 }
    ' "$ag_file")"

    if [ -n "$findings" ]; then
        printf '%s\n' "$findings"
        local count
        count="$(printf '%s\n' "$findings" | grep -c '^\[BAD-PUSH\]' || true)"
        FAIL=$((FAIL + count))
    fi
}

# Walk *.ag files under research-foundry/<colony>/agents/.
# Other federations (dev-apprenticeship, tribes-bench) do not emit
# `.ag` source inside LLM prompts, so the rule is research-foundry
# scoped.
if [ -f "$SCAN_ROOT" ]; then
    check_file "$SCAN_ROOT"
else
    while IFS= read -r -d '' f; do
        check_file "$f"
    done < <(find "$SCAN_ROOT" -type f -path '*/research-foundry/*/agents/*.ag' -print0)
fi

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "check-llm-prompt-list-ops: $FAIL bare-push finding(s) inside LLM prompt strings"
    exit 1
fi

exit 0
