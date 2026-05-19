#!/bin/bash
# tools/check-learn-recommend-topic-match.sh: Enforce CLAUDE.md's
# "learn() topic must match the topic in recommend() within the same
# agent" rule statically (#622 PR-3).
#
# Background
# ==========
# Confidence-update plumbing in agentis-core ties a `recommend()` call's
# topic to the `learn()` rows that scored that recommendation. When a
# `recommend("foo", ...)` is paired with a `learn("bar", ...)` in the
# same file, the recommend has no scored history — the agent's
# confidence drifts at the runtime's default rate instead of being
# steered by acted outcomes. This is silent: there is no syntax error,
# no runtime panic, just stuck confidence.
#
# Rule
# ----
# For every `*.ag` file under `*/agents/*.ag` (excluding `*/runs/*`
# per-tick snapshots), the set of topic strings appearing in
# `recommend("<topic>", ...)` calls MUST be a subset of the set of topic
# strings appearing in `learn("<topic>", ...)` calls in the same file.
# A recommend with no matching learn is a hard violation.
#
# A `learn()` with no matching `recommend()` is allowed (an agent may
# learn without recommending; this is the dominant pattern in
# observe-only colonies). Asymmetry is one-directional.
#
# Scope
# -----
# Both topic-extraction operations use the literal first-arg shape
# `learn("<topic>", ...)` / `recommend("<topic>", ...)` — dynamic /
# variable-driven topics (e.g. `learn(topic_var, ...)`) are silently
# skipped; this lint is a static guardrail, not an exhaustive runtime
# check. Both single-line and multi-line shapes are accepted via the
# flattened-buffer parser (#635); a `learn(` token followed only by
# whitespace + newline before the `"topic",` literal is treated the
# same as `learn("topic", ...)` on one line.
#
# Suppression
# -----------
# This rule has no per-line suppression because the failure mode (silent
# confidence drift) is a correctness bug, not a stylistic call.
# Authors who intentionally diverge topics must rename one of the
# calls.
#
# Today (#622) 0 `recommend()` calls exist in the research federations
# (math-foundry, claim-auditor, preprint-foundry), so the lint is
# vacuously green for all three. tribes-bench hunters use raw memo
# reads for confidence steering and have no `recommend()` calls
# either. dev-apprenticeship colonies are in scope (#635 follow-up):
# the parser now handles multi-line `learn(\n  "<topic>", ...)` shapes
# used by four planning agents (plan_reviewer, risk_assessor,
# scope_estimator, task_decomposer), so the pre-#635 exclusion has
# been dropped.
#
# Usage: ./tools/check-learn-recommend-topic-match.sh [path]
# Exit 0 on clean, 1 on subset violation, 2 on usage error.

set -euo pipefail

SCAN_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ ! -e "$SCAN_ROOT" ]; then
    echo "check-learn-recommend-topic-match: scan root does not exist: $SCAN_ROOT" >&2
    exit 2
fi

FAIL=0

# Extract literal first-arg topics for every `<call>(` site in an .ag
# file, including the multi-line shape `<call>(\n  "<topic>", ...)`
# used by dev-apprenticeship planning agents (`plan_reviewer.ag`,
# `risk_assessor.ag`, `scope_estimator.ag`, `task_decomposer.ag`).
# Single-line shapes continue to work unchanged.
#
# Implementation: awk one-pass scan that strips `//` line comments,
# tracks whether we are inside a `<call>(` and, on the FIRST literal
# `"..."` token whose closing quote is followed by `,` or `)`, emits
# the literal on stdout. Anything other than a literal first-arg
# (variable / concat / dynamic) yields no output for that site. Awk
# is used (not bash parameter expansion) because per-file flattening
# in bash gives O(n^2) suffix scans on large agents -- the awk one-pass
# keeps the whole lint under 2s on the full federation tree.
#
# Output: one topic per line on stdout. The caller collects the lines
# into a bash variable for set-membership testing.
collect_topics_awk() {
    local ag_file="$1"
    local call="$2"
    awk -v CALL="$call" '
        function flush_finding(    body, q2, lit, after, c, q1) {
            # `buf` holds everything after the most recent <call>(.
            q1 = index(buf, "\"")
            if (q1 == 0) return 0
            body = substr(buf, q1 + 1)
            q2 = index(body, "\"")
            if (q2 == 0) return 0
            lit = substr(body, 1, q2 - 1)
            after = substr(body, q2 + 1)
            sub(/^[ \t\n\r]+/, "", after)
            c = substr(after, 1, 1)
            if (c == "," || c == ")") {
                print lit
                return 1
            }
            return 0
        }
        BEGIN { in_call = 0; buf = "" }
        {
            line = $0
            cidx = index(line, "//")
            if (cidx > 0) line = substr(line, 1, cidx - 1)
            n = length(line)
            i = 1
            while (i <= n) {
                if (!in_call) {
                    idx = index(substr(line, i), CALL "(")
                    if (idx == 0) break
                    i = i + idx - 1 + length(CALL) + 1
                    in_call = 1
                    buf = ""
                    continue
                }
                ch = substr(line, i, 1)
                buf = buf ch
                if (ch == ")") {
                    flush_finding()
                    in_call = 0
                    buf = ""
                    i = i + 1
                    continue
                }
                if (ch == ",") {
                    flush_finding()
                    in_call = 0
                    buf = ""
                    i = i + 1
                    continue
                }
                i = i + 1
            }
            if (in_call) buf = buf "\n"
        }
        END {
            if (in_call) flush_finding()
        }
    ' "$ag_file"
}

check_file() {
    local ag_file="$1"
    local learn_topics=""
    local recommend_topics=""

    learn_topics="$(collect_topics_awk "$ag_file" "learn")"
    recommend_topics="$(collect_topics_awk "$ag_file" "recommend")"

    # Empty recommend set → vacuously a subset.
    [ -z "${recommend_topics// /}" ] && return 0

    # For each unique recommend topic, ensure it appears in learn_topics.
    local r_uniq
    r_uniq="$(printf '%s\n' "$recommend_topics" | sort -u)"
    local rt found
    while IFS= read -r rt; do
        [ -z "$rt" ] && continue
        found=0
        local lt
        while IFS= read -r lt; do
            [ -z "$lt" ] && continue
            if [ "$lt" = "$rt" ]; then
                found=1
                break
            fi
        done <<EOF
$learn_topics
EOF
        if [ "$found" = "0" ]; then
            printf '%s — VIOLATION: recommend("%s", ...) has no matching learn("%s", ...) in the same file\n' "$ag_file" "$rt" "$rt"
            FAIL=$((FAIL + 1))
        fi
    done <<EOF
$r_uniq
EOF
}

# Main: walk per-federation agent trees and skip per-run snapshots.
# Covers tribes-bench, research-foundry, AND dev-apprenticeship. The
# multi-line `learn(\n  "<topic>", ...)` shape used by four
# dev-apprenticeship planning agents (plan_reviewer, risk_assessor,
# scope_estimator, task_decomposer) is supported via the flattened-
# buffer parser above (#635). Per-run snapshots under */runs/* are
# skipped as before.
if [ -f "$SCAN_ROOT" ]; then
    check_file "$SCAN_ROOT"
else
    while IFS= read -r -d '' f; do
        case "$f" in
            */runs/*) continue ;;
        esac
        check_file "$f"
    done < <(find "$SCAN_ROOT" -type f \( \
        -path '*/tribes-bench/tribe-*/agents/*.ag' -o \
        -path '*/research-foundry/*/agents/*.ag' -o \
        -path '*/dev-apprenticeship/*/agents/*.ag' \
        \) -print0)
fi

if [ "$FAIL" -gt 0 ]; then
    echo "" >&2
    echo "check-learn-recommend-topic-match: $FAIL violation(s)" >&2
    exit 1
fi

exit 0
