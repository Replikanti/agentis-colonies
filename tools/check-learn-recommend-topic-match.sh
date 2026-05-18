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
# check. The grep is `learn(` / `recommend(` at line scope; one call
# per line is the federation-wide convention.
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
# either. dev-apprenticeship colonies use the legacy
# `recommend("<task-topic>", ...)` -> `learn("<gitlab-action-topic>", ...)`
# split that predates this rule (multiple plumbing migrations not
# done); they are out of scope for this lint until that migration
# lands. The find glob is therefore the same per-federation set as
# `check-learn-tags.sh` (#622 PR-3).
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

# Extract the literal first-arg topic from a single-line `<call>(` site.
# Returns the topic via stdout, or empty string when the first arg is
# not a string literal (variable / concat). The match is intentionally
# strict: only `<call>("<topic>",` patterns are accepted.
extract_first_arg_literal() {
    local line="$1"
    local call="$2"
    # Strip `//` line comment if any.
    case "$line" in
        *"//"*) line="${line%%//*}" ;;
    esac
    # Find `<call>(` and everything after.
    case "$line" in
        *"$call("*) ;;
        *) echo ""; return 0 ;;
    esac
    local body="${line#*"$call"\(}"
    # Strip leading whitespace.
    body="${body#"${body%%[![:space:]]*}"}"
    # Require opening quote.
    case "$body" in
        \"*) ;;
        *) echo ""; return 0 ;;
    esac
    body="${body#\"}"
    # Capture up to the next `"`.
    local close="${body%%\"*}"
    if [ "$close" = "$body" ]; then
        # No closing quote on this line.
        echo ""
        return 0
    fi
    # Reject embedded escape sequences or `+` continuation. A valid
    # literal must be followed by `,` or `)` after optional whitespace.
    local after="${body#"$close"\"}"
    after="${after#"${after%%[![:space:]]*}"}"
    case "$after" in
        ","*|")"*) echo "$close"; return 0 ;;
        *) echo ""; return 0 ;;
    esac
}

check_file() {
    local ag_file="$1"
    local learn_topics=""
    local recommend_topics=""

    # First pass: collect learn topics.
    while IFS= read -r line; do
        # Strip `//` comment for grep purposes.
        local clean="$line"
        case "$clean" in
            *"//"*) clean="${clean%%//*}" ;;
        esac
        case "$clean" in
            *learn\(*)
                local t
                t="$(extract_first_arg_literal "$line" "learn")"
                if [ -n "$t" ]; then
                    learn_topics="$learn_topics
$t"
                fi
                ;;
        esac
    done < "$ag_file"

    # Second pass: collect recommend topics.
    while IFS= read -r line; do
        local clean="$line"
        case "$clean" in
            *"//"*) clean="${clean%%//*}" ;;
        esac
        case "$clean" in
            *recommend\(*)
                local t
                t="$(extract_first_arg_literal "$line" "recommend")"
                if [ -n "$t" ]; then
                    recommend_topics="$recommend_topics
$t"
                fi
                ;;
        esac
    done < "$ag_file"

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
# Same set as `check-learn-tags.sh`: tribes-bench + the three research
# federations math-foundry / claim-auditor / preprint-foundry
# (#622 PR-3). dev-apprenticeship is intentionally excluded — see
# header for rationale.
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
        -path '*/research-foundry/*/agents/*.ag' \
        \) -print0)
fi

if [ "$FAIL" -gt 0 ]; then
    echo "" >&2
    echo "check-learn-recommend-topic-match: $FAIL violation(s)" >&2
    exit 1
fi

exit 0
