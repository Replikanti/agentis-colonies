#!/usr/bin/env bash
# completion-gate.sh - First-real-task completion gate (#1116)
#
# Mechanically evaluates the single binary completion criterion defined in
# doc/dev-apprenticeship-first-task.md: the federation has "completed" a
# nominated task if and only if it has opened a pull request that
#   (a) is mergeable (applies cleanly, no conflicts), and
#   (b) passes the target repo's existing gate green — for this repo that is
#       tools/colony-lint.sh with 0 failed PLUS every required CI check.
#
# The point of this script is that the criterion is checkable by a non-author
# WITHOUT a judgement call. It prints a tick/cross per sub-condition and an
# overall verdict, and exits non-zero unless every condition passes.
#
# Usage:
#     ./tools/completion-gate.sh <fed-dir> <target-issue> --pr <N> [--repo <owner/repo>]
#
# Exit codes: 0 all conditions pass (DONE), 1 a condition failed (NOT DONE),
#             2 usage / environment error.
#
# Per the CLAUDE.md no-heredoc invariant this script uses no heredocs, and is
# dash-safe (no bashisms in the control flow).

set -eu

# --- Path resolution (mirrors cost-cap.sh) ---

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 <fed-dir> <target-issue> --pr <N> [--repo <owner/repo>]" >&2
    exit 2
}

# ASCII markers, matching colony-lint's [PASS] style — dash-safe (no \xHH
# printf escapes, which dash cannot render; see the CI shell lesson).
mark_ok() { printf '[PASS] %s\n' "$1"; }
mark_no() { printf '[FAIL] %s\n' "$1"; }

if [ $# -lt 2 ]; then
    usage
fi

FED_ARG="$1"
TARGET_ISSUE="$2"
shift 2

PR_NUMBER=""
REPO=""

while [ $# -gt 0 ]; do
    case "$1" in
        --pr)
            [ $# -ge 2 ] || usage
            PR_NUMBER="$2"
            shift 2
            ;;
        --repo)
            [ $# -ge 2 ] || usage
            REPO="$2"
            shift 2
            ;;
        *)
            echo "completion-gate.sh: unknown argument: $1" >&2
            usage
            ;;
    esac
done

if [ -z "$PR_NUMBER" ]; then
    echo "completion-gate.sh: --pr <N> is required (the PR the federation opened for the task)" >&2
    usage
fi

# Resolve the federation dir (accept either a repo-relative or absolute path).
FED_DIR="$REPO_ROOT/$FED_ARG"
if [ ! -d "$FED_DIR" ]; then
    FED_DIR="$FED_ARG"
fi
if [ ! -d "$FED_DIR" ]; then
    echo "completion-gate.sh: federation directory not found: $FED_ARG" >&2
    exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "completion-gate.sh: 'gh' (GitHub CLI) is required for the PR checks." >&2
    exit 2
fi

# Default repo: the gh-resolved repo for REPO_ROOT, else the canonical slug.
if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
fi
if [ -z "$REPO" ]; then
    REPO="Replikanti/agentis-colonies"
fi

echo "== completion gate =="
echo "repo:         $REPO"
echo "target issue: #$TARGET_ISSUE"
echo "pull request: #$PR_NUMBER"
echo "federation:   $FED_DIR"
echo ""

OVERALL=0

# --- Condition 1: the PR is mergeable (applies cleanly) ---
PR_JSON="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state,mergeable,body,title 2>/dev/null || true)"
if [ -z "$PR_JSON" ]; then
    mark_no "PR #$PR_NUMBER not found in $REPO"
    OVERALL=1
else
    PR_STATE="$(printf '%s' "$PR_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("state",""))')"
    PR_MERGEABLE="$(printf '%s' "$PR_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("mergeable",""))')"
    # GitHub computes mergeability asynchronously; a freshly-opened PR reports
    # UNKNOWN for a few seconds. Re-query (up to 3x) so the gate does not emit
    # a transient false NOT-DONE when it is run right after the PR is opened.
    RETRY=0
    while [ "$PR_STATE" = "OPEN" ] && [ "$PR_MERGEABLE" = "UNKNOWN" ] && [ "$RETRY" -lt 3 ]; do
        sleep 2
        RETRY=$((RETRY + 1))
        PR_MERGEABLE="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json mergeable --jq '.mergeable' 2>/dev/null || echo UNKNOWN)"
    done
    # MERGEABLE, or already MERGED, both satisfy "applies cleanly".
    if [ "$PR_STATE" = "MERGED" ]; then
        mark_ok "mergeable: PR already MERGED (applied cleanly)"
    elif [ "$PR_MERGEABLE" = "MERGEABLE" ]; then
        mark_ok "mergeable: PR is MERGEABLE (no conflicts)"
    else
        mark_no "mergeable: PR state=$PR_STATE mergeable=$PR_MERGEABLE (not a clean apply)"
        OVERALL=1
    fi

    # Sanity tie-back: the PR references the nominated target issue.
    PR_BODY="$(printf '%s' "$PR_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("body","") or "")')"
    case "$PR_BODY" in
        *"#$TARGET_ISSUE"*)
            echo "   (references #$TARGET_ISSUE)" ;;
        *)
            echo "   (note: PR body does not mention #$TARGET_ISSUE — confirm this is the right PR)" ;;
    esac
fi

# --- Condition 2: every required CI check on the PR is green ---
if [ -n "$PR_JSON" ]; then
    CHECKS="$(gh pr checks "$PR_NUMBER" --repo "$REPO" --json name,state 2>/dev/null || true)"
    if [ -z "$CHECKS" ]; then
        # No checks configured is not a pass for a code task; flag it.
        mark_no "CI checks: none reported for PR #$PR_NUMBER (cannot confirm green)"
        OVERALL=1
    else
        NOT_GREEN="$(printf '%s' "$CHECKS" | python3 -c 'import sys,json
rows=json.load(sys.stdin)
bad=[r["name"] for r in rows if r.get("state") not in ("SUCCESS","SKIPPED","NEUTRAL")]
print(",".join(bad))')"
        if [ -z "$NOT_GREEN" ]; then
            mark_ok "CI checks: all green"
        else
            mark_no "CI checks: not green -> $NOT_GREEN"
            OVERALL=1
        fi
    fi
fi

# --- Condition 3: local colony-lint passes 0-failed ---
# colony-lint is repo-wide (it lints every federation in the checkout), so it
# takes no federation argument; <fed-dir> labels the run and is validated for
# existence above. This is the canonical green gate for this repo.
LINT_SCRIPT="$SCRIPT_DIR/colony-lint.sh"
if [ ! -x "$LINT_SCRIPT" ]; then
    mark_no "colony-lint: $LINT_SCRIPT not executable"
    OVERALL=1
else
    if ! command -v agentis >/dev/null 2>&1; then
        echo "   (warning: 'agentis' not on PATH — colony-lint will skip agentis-dependent checks; export \$HOME/.cargo/bin)"
    fi
    echo "   (running colony-lint — this can take a few minutes when agentis is installed)..."
    LINT_OUT="$("$LINT_SCRIPT" 2>&1 || true)"
    LINT_RESULT="$(printf '%s\n' "$LINT_OUT" | grep -E '^Results:' | tail -1)"
    case "$LINT_RESULT" in
        *"0 failed"*)
            mark_ok "colony-lint: $LINT_RESULT" ;;
        "")
            mark_no "colony-lint: no Results line (lint did not complete)"
            OVERALL=1 ;;
        *)
            mark_no "colony-lint: $LINT_RESULT"
            OVERALL=1 ;;
    esac
fi

echo ""
if [ "$OVERALL" -eq 0 ]; then
    printf '[PASS] VERDICT: DONE - task #%s completed by PR #%s (all conditions pass)\n' "$TARGET_ISSUE" "$PR_NUMBER"
    exit 0
fi
printf '[FAIL] VERDICT: NOT DONE - one or more conditions failed (see above)\n'
exit 1
