#!/bin/bash
# tools/check-reality-check.sh: Flag dev-apprenticeship acting agents that
# write to the forge (open MRs, post notes, tag/release, merge) but never
# wire the reality-check feedback loop and carry no documented waiver.
#
# The reality-check loop (doc/feedback-loop.md) closes an agent's own
# ground-truth gap: a `<agent>:pending_verdict` memo records what the agent
# asserted so a later tick can compare it against the forge's actual outcome
# and correct the agent's confidence. Wave 1 (#1453) proved the pattern on
# code_writer; Wave 2 (M1-M5) fanned it out to every other acting agent. As
# of this check, 21 of the 22 dev-apprenticeship agents are wired and one
# (planning/risk_assessor) carries a documented file-scope waiver — its risk
# list has no separable mechanical forge signal to compare against. This
# lint is the regression guard: a NEW acting agent, or a new acting call
# site added to an existing agent, that skips both wiring and waiver fails
# the check.
#
# Rule (scope: dev-apprenticeship only, file granularity, not call-site):
#   Every `dev-apprenticeship/*/agents/*.ag` file whose (comment-stripped)
#   text calls one of the 9 forge write verbs through forge-api.sh —
#   create-mr, add-note, post-note, commit-files, create-tag, create-release,
#   create-issue, update-issue, merge — must either (a) contain the literal
#   string `"<agent_name>:pending_verdict"` (the memo key the 4-step loop in
#   doc/feedback-loop.md reads/writes), or (b) carry a line matching
#   `colony-lint: reality-check-waived: <reason>` somewhere in the file.
#   File-scope, not call-site-scope: the umbrella issue phrases the rule
#   per-agent ("every .ag ... must either wire ... or waive ..."), and
#   risk_assessor's single waiver already matches that granularity — no
#   current agent needs a finer per-call-site waiver.
#
# Verb detection is comment-stripped (a `//`-prefixed doc-comment mentioning
# a verb, e.g. "// example: forge-api.sh create-tag --name v1", must not
# count as an acting call) and boundary-anchored on trailing whitespace:
# `forge-api\.sh[[:space:]]+(create-mr|add-note|post-note|commit-files|
# create-tag|create-release|create-issue|update-issue|merge)[[:space:]]`.
# The trailing `[[:space:]]` is load-bearing: without it, the `merge`
# alternative would also match the READ verb `merge-requests`/
# `merge_requests` (list open MRs) that most code-review agents call
# constantly — every real `merge` write call site is followed by a space
# then the next argument, so the boundary costs nothing on the true
# positives and eliminates this false-positive class.
#
# This is a grep/awk-level check, not a full parser.
#
# Usage: ./tools/check-reality-check.sh [repo-root]
# Exit 0 if clean, 1 if one or more findings, 2 on usage error.

set -euo pipefail
# Disable pathname expansion out of caution: nothing here relies on
# globbing, and this mirrors check-getenv-allowlist.sh's defensive posture.
set -f

SCAN_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ ! -d "$SCAN_ROOT" ]; then
    echo "check-reality-check: scan root does not exist: $SCAN_ROOT" >&2
    exit 2
fi

FED_DIR="$SCAN_ROOT/dev-apprenticeship"

if [ ! -d "$FED_DIR" ]; then
    echo "check-reality-check: $FED_DIR not found" >&2
    exit 2
fi

FAIL=0

# matched_verbs <path>: prints each matched write-verb token (one per
# line, may repeat) found in the comment-stripped text of the file.
# Mirrors check-getenv-allowlist.sh's `sub(/(^|[[:space:]])\/\/.*$/, ...)`
# strip-then-`while (match(...))` idiom.
matched_verbs() {
    awk '
    {
        clean = $0
        sub(/(^|[[:space:]])\/\/.*$/, "", clean)
        rest = clean
        while (match(rest, /forge-api\.sh[[:space:]]+(create-mr|add-note|post-note|commit-files|create-tag|create-release|create-issue|update-issue|merge)[[:space:]]/)) {
            tok = substr(rest, RSTART, RLENGTH)
            verb = tok
            sub(/^forge-api\.sh[[:space:]]+/, "", verb)
            sub(/[[:space:]]+$/, "", verb)
            print verb
            rest = substr(rest, RSTART + RLENGTH)
        }
    }
    ' "$1"
}

while IFS= read -r -d '' f; do
    verbs=""
    while IFS= read -r verb; do
        [ -n "$verb" ] || continue
        case ",$verbs," in
            *",$verb,"*) ;;
            *) verbs="${verbs:+$verbs,}$verb" ;;
        esac
    done < <(matched_verbs "$f")

    if [ -z "$verbs" ]; then
        continue
    fi

    agent_name="$(basename "$f" .ag)"

    wired=0
    if grep -qF "\"${agent_name}:pending_verdict\"" "$f"; then
        wired=1
    fi

    waived=0
    if grep -qE 'colony-lint:[[:space:]]*reality-check-waived:' "$f"; then
        waived=1
    fi

    if [ "$wired" -eq 0 ] && [ "$waived" -eq 0 ]; then
        printf '[UNWIRED] %s: forge write verb(s) (%s) present but no "%s:pending_verdict" reality-check wiring and no reality-check-waived annotation — wire the agent into doc/feedback-loop.md'"'"'s 4-step idiom (see #1453) or waive with '"'"'// colony-lint: reality-check-waived: <reason>'"'"'\n' "$f" "$verbs" "$agent_name"
        FAIL=$((FAIL + 1))
    fi
done < <(find "$FED_DIR" -type f -path '*/agents/*.ag' -print0)

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "check-reality-check: $FAIL finding(s)"
    exit 1
fi

exit 0
