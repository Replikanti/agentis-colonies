#!/usr/bin/env bash
# test-github-planning-normalize.sh: unit-test the GitHub -> GitLab-shape
# normalizers in dev-apprenticeship/planning/scripts/github-api.sh
# (ADR-0002, #256 PR 3).
#
# Planning's normalizer surface differs from triage's: no members/labels
# enumeration (planning doesn't assign), but two planning-specific
# normalizers — normalize_pulls (for `merge-requests` command) and
# normalize_timeline (for `issue-label-events`) — covering the GitHub
# /pulls and /issues/{n}/timeline endpoints respectively.
#
# Matches the style of test-github-triage-normalize.sh (bash 3.2, python3
# for JSON, build_prelude pattern for sourcing the script under test).
#
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$REPO_ROOT/dev-apprenticeship/planning/scripts/github-api.sh"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# GitHub /issues fixture: two real issues plus one pull_request-bearing entry
# that must be filtered out. Mirrors the triage fixture so parity bugs in
# normalize_issues show up on either side.
FIXTURE_ISSUES='[
  {"url":"https://api.github.com/repos/o/r/issues/1","number":1,"title":"Plan me",
   "body":"epic-desc","state":"open","labels":[{"id":1,"name":"needs-planning"},
   {"id":2,"name":"epic"}],
   "user":{"login":"alice","id":7,"type":"User"},
   "assignees":[{"login":"bob","id":8}],
   "created_at":"2026-04-01T10:00:00Z","updated_at":"2026-04-02T10:00:00Z",
   "comments":2,"author_association":"MEMBER"},
  {"url":"https://api.github.com/repos/o/r/issues/2","number":2,"title":"Another",
   "body":"desc-2","state":"open","labels":[],
   "user":{"login":"alice","id":7,"type":"User"},
   "assignees":[],"created_at":"2026-04-03T10:00:00Z","updated_at":"2026-04-04T10:00:00Z",
   "comments":0,"author_association":"MEMBER"},
  {"url":"https://api.github.com/repos/o/r/issues/3","number":3,"title":"I-am-a-PR",
   "body":"pr-body","state":"open","labels":[{"id":3,"name":"needs-planning"}],
   "user":{"login":"alice","id":7,"type":"User"},"assignees":[],
   "created_at":"2026-04-05T10:00:00Z","updated_at":"2026-04-06T10:00:00Z","comments":1,
   "pull_request":{"url":"https://api.github.com/repos/o/r/pulls/3"}}
]'

FIXTURE_SINGLE_ISSUE='{"url":"https://api.github.com/repos/o/r/issues/42","number":42,
  "title":"Single","body":"single-desc","state":"closed",
  "labels":[{"id":99,"name":"epic"}],
  "user":{"login":"alice","id":7},"assignees":[{"login":"bob","id":8}],
  "created_at":"2026-04-01T10:00:00Z","updated_at":"2026-04-10T10:00:00Z","comments":5}'

# GitHub /pulls fixture. scope_estimator reads `merge-requests --state merged
# --view planning-mr`, so the normalizer must:
#   (1) state open -> opened
#   (2) state closed with merged_at != null -> merged
#   (3) state closed with merged_at == null -> closed (rejected PR)
#   (4) target_branch <- base.ref, source_branch <- head.ref
#   (5) user_notes_count <- comments
#   (6) changes_count <- changed_files (often absent on list endpoint — null ok)
FIXTURE_PULLS='[
  {"url":"https://api.github.com/repos/o/r/pulls/10","number":10,"title":"Open PR",
   "body":"pr-10","state":"open","merged_at":null,
   "labels":[{"id":1,"name":"feature"}],
   "user":{"login":"alice"},"base":{"ref":"main"},"head":{"ref":"feat/x"},
   "created_at":"2026-04-01T10:00:00Z","updated_at":"2026-04-02T10:00:00Z",
   "comments":1},
  {"url":"https://api.github.com/repos/o/r/pulls/11","number":11,"title":"Merged PR",
   "body":"pr-11","state":"closed","merged_at":"2026-04-05T12:00:00Z",
   "labels":[{"id":2,"name":"bugfix"}],
   "user":{"login":"alice"},"base":{"ref":"main"},"head":{"ref":"fix/y"},
   "created_at":"2026-04-03T10:00:00Z","updated_at":"2026-04-05T12:00:00Z",
   "comments":4,"changed_files":7},
  {"url":"https://api.github.com/repos/o/r/pulls/12","number":12,"title":"Rejected PR",
   "body":"pr-12","state":"closed","merged_at":null,
   "labels":[],
   "user":{"login":"carol"},"base":{"ref":"main"},"head":{"ref":"wip/z"},
   "created_at":"2026-04-04T10:00:00Z","updated_at":"2026-04-06T10:00:00Z",
   "comments":0}
]'

# GitHub /issues/{n}/timeline fixture. Per the GitHub REST API, events vary
# wildly — `labeled` / `unlabeled` carry a `label: {name, color}` object, and
# most other event kinds (`committed`, `reviewed`, `cross-referenced`, ...)
# should be ignored. The normalizer's job is to drop non-label events and map
# labeled -> "add", unlabeled -> "remove".
FIXTURE_TIMELINE='[
  {"id":1,"event":"labeled","created_at":"2026-04-10T10:00:00Z",
   "actor":{"login":"alice"},"label":{"name":"needs-planning","color":"ff0000"}},
  {"id":2,"event":"cross-referenced","created_at":"2026-04-10T10:01:00Z",
   "actor":{"login":"bob"}},
  {"id":3,"event":"unlabeled","created_at":"2026-04-11T09:00:00Z",
   "actor":{"login":"alice"},"label":{"name":"needs-planning","color":"ff0000"}},
  {"id":4,"event":"labeled","created_at":"2026-04-12T09:00:00Z",
   "actor":{"login":"alice"},"label":{"name":"epic","color":"00ff00"}},
  {"id":5,"event":"committed","created_at":"2026-04-12T09:30:00Z"}
]'

# Source just the function defs. Same awk-stop trick as test-github-triage.
build_prelude() {
    awk '/^CMD=/{exit} {print}' "$SCRIPT" > "$1"
}

# run_fn <fn-name> <input-json> [args...]
# Pipes the fixture through the named normalize fn with optional args.
# Dummy GITHUB_* env satisfies the env-check block that fires at source time.
run_fn() {
    local fn="$1" input="$2"
    shift 2
    local prelude
    prelude=$(mktemp)
    build_prelude "$prelude"
    # shellcheck disable=SC1090,SC2016
    GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r bash -c '
        source "$1"
        input="$2"
        fn="$3"
        shift 3
        printf "%s" "$input" | "$fn" "$@"
    ' _ "$prelude" "$input" "$fn" "$@"
    local rc=$?
    rm -f "$prelude"
    return $rc
}

json_extract() {
    DATA="$1" python3 -c "
import os, json
data = json.loads(os.environ['DATA'])
print($2)
"
}

assert_eq() {
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3: expected='$1' actual='$2'"
    fi
}

# --- normalize_issues: PR filter + shape ---
ISSUES_OUT=$(run_fn normalize_issues "$FIXTURE_ISSUES")

COUNT=$(json_extract "$ISSUES_OUT" "len(data)")
assert_eq "2" "$COUNT" "normalize_issues: pull_request entries filtered out"

IID0=$(json_extract "$ISSUES_OUT" "data[0]['iid']")
assert_eq "1" "$IID0" "normalize_issues: iid == number"

STATE0=$(json_extract "$ISSUES_OUT" "data[0]['state']")
assert_eq "opened" "$STATE0" "normalize_issues: state open -> opened"

LABELS0=$(json_extract "$ISSUES_OUT" "','.join(data[0]['labels'])")
assert_eq "needs-planning,epic" "$LABELS0" "normalize_issues: labels flattened to strings"

AUTHOR0=$(json_extract "$ISSUES_OUT" "data[0]['author']['username']")
assert_eq "alice" "$AUTHOR0" "normalize_issues: author.username == user.login"

# --- normalize_issue (single-issue variant) ---
SINGLE_OUT=$(run_fn normalize_issue "$FIXTURE_SINGLE_ISSUE")
SINGLE_IID=$(DATA="$SINGLE_OUT" python3 -c "import os, json; print(json.loads(os.environ['DATA'])['iid'])")
SINGLE_STATE=$(DATA="$SINGLE_OUT" python3 -c "import os, json; print(json.loads(os.environ['DATA'])['state'])")
assert_eq "42" "$SINGLE_IID" "normalize_issue: iid == number"
assert_eq "closed" "$SINGLE_STATE" "normalize_issue: state closed stays closed"

# --- normalize_pulls: state collapse + MR-shape ---
PULLS_OUT=$(run_fn normalize_pulls "$FIXTURE_PULLS")
P_COUNT=$(json_extract "$PULLS_OUT" "len(data)")
assert_eq "3" "$P_COUNT" "normalize_pulls: three entries"

P0_STATE=$(json_extract "$PULLS_OUT" "data[0]['state']")
P1_STATE=$(json_extract "$PULLS_OUT" "data[1]['state']")
P2_STATE=$(json_extract "$PULLS_OUT" "data[2]['state']")
assert_eq "opened" "$P0_STATE" "normalize_pulls: open -> opened"
assert_eq "merged" "$P1_STATE" "normalize_pulls: closed + merged_at -> merged"
assert_eq "closed" "$P2_STATE" "normalize_pulls: closed + no merged_at -> closed"

P1_TGT=$(json_extract "$PULLS_OUT" "data[1]['target_branch']")
P1_SRC=$(json_extract "$PULLS_OUT" "data[1]['source_branch']")
P1_MERGED=$(json_extract "$PULLS_OUT" "data[1]['merged_at']")
P1_CHANGES=$(json_extract "$PULLS_OUT" "data[1]['changes_count']")
P1_NOTES=$(json_extract "$PULLS_OUT" "data[1]['user_notes_count']")
assert_eq "main" "$P1_TGT" "normalize_pulls: target_branch <- base.ref"
assert_eq "fix/y" "$P1_SRC" "normalize_pulls: source_branch <- head.ref"
assert_eq "2026-04-05T12:00:00Z" "$P1_MERGED" "normalize_pulls: merged_at preserved"
assert_eq "7" "$P1_CHANGES" "normalize_pulls: changes_count <- changed_files"
assert_eq "4" "$P1_NOTES" "normalize_pulls: user_notes_count <- comments"

# Open PR has no changed_files in list endpoint — forwarded as null, not missing.
P0_CHANGES=$(json_extract "$PULLS_OUT" "repr(data[0]['changes_count'])")
assert_eq "None" "$P0_CHANGES" "normalize_pulls: missing changed_files -> null"

# --- normalize_timeline: label events only + add/remove mapping ---
TIMELINE_OUT=$(run_fn normalize_timeline "$FIXTURE_TIMELINE" "" "")
T_COUNT=$(json_extract "$TIMELINE_OUT" "len(data)")
assert_eq "3" "$T_COUNT" "normalize_timeline: non-label events dropped (committed/cross-referenced)"

T0_ACTION=$(json_extract "$TIMELINE_OUT" "data[0]['action']")
T0_LABEL=$(json_extract "$TIMELINE_OUT" "data[0]['label']")
T0_USER=$(json_extract "$TIMELINE_OUT" "data[0]['user']")
assert_eq "add" "$T0_ACTION" "normalize_timeline: labeled -> add"
assert_eq "needs-planning" "$T0_LABEL" "normalize_timeline: label.name preserved"
assert_eq "alice" "$T0_USER" "normalize_timeline: actor.login -> user"

T1_ACTION=$(json_extract "$TIMELINE_OUT" "data[1]['action']")
assert_eq "remove" "$T1_ACTION" "normalize_timeline: unlabeled -> remove"

# --- normalize_timeline: label filter ---
TL_LABEL_ONLY=$(run_fn normalize_timeline "$FIXTURE_TIMELINE" "needs-planning" "")
TL_LABEL_COUNT=$(json_extract "$TL_LABEL_ONLY" "len(data)")
assert_eq "2" "$TL_LABEL_COUNT" "normalize_timeline: label filter narrows to 'needs-planning' events"

# --- normalize_timeline: since filter ---
TL_SINCE=$(run_fn normalize_timeline "$FIXTURE_TIMELINE" "" "2026-04-11T00:00:00Z")
TL_SINCE_COUNT=$(json_extract "$TL_SINCE" "len(data)")
assert_eq "2" "$TL_SINCE_COUNT" "normalize_timeline: since filter drops pre-cutoff events"

# --- End-to-end: normalize_issues -> project_json planning ---
# Ensures the view keys stay locked to {iid, title, description, labels,
# author, created_at} — scope_estimator/risk_assessor/task_decomposer all
# read this projection and drift would silently misfeed their prompts.
PIPE_PRELUDE=$(mktemp)
build_prelude "$PIPE_PRELUDE"
# shellcheck disable=SC1090,SC2016
E2E_OUT=$(GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r bash -c '
    source "$1"
    printf "%s" "$2" | normalize_issues | project_json planning
' _ "$PIPE_PRELUDE" "$FIXTURE_ISSUES")
rm -f "$PIPE_PRELUDE"

E2E_COUNT=$(json_extract "$E2E_OUT" "len(data)")
E2E_KEYS=$(json_extract "$E2E_OUT" "','.join(sorted(data[0].keys()))")
E2E_IID=$(json_extract "$E2E_OUT" "data[0]['iid']")
E2E_AUTHOR=$(json_extract "$E2E_OUT" "data[0]['author']['username']")
assert_eq "2" "$E2E_COUNT" "e2e planning: normalize | planning view emits 2 items (PR filtered)"
assert_eq "author,created_at,description,iid,labels,title" "$E2E_KEYS" "e2e planning: view keys match gitlab shape"
assert_eq "1" "$E2E_IID" "e2e planning: view carries iid through pipe"
assert_eq "alice" "$E2E_AUTHOR" "e2e planning: view carries author.username through pipe"

# --- End-to-end: normalize_pulls -> project_json planning-mr ---
PIPE_PRELUDE2=$(mktemp)
build_prelude "$PIPE_PRELUDE2"
# shellcheck disable=SC1090,SC2016
E2E_MR_OUT=$(GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r bash -c '
    source "$1"
    printf "%s" "$2" | normalize_pulls | project_json planning-mr
' _ "$PIPE_PRELUDE2" "$FIXTURE_PULLS")
rm -f "$PIPE_PRELUDE2"

E2E_MR_COUNT=$(json_extract "$E2E_MR_OUT" "len(data)")
E2E_MR_KEYS=$(json_extract "$E2E_MR_OUT" "','.join(sorted(data[0].keys()))")
E2E_MR_MERGED=$(json_extract "$E2E_MR_OUT" "data[1]['merged_at']")
E2E_MR_TGT=$(json_extract "$E2E_MR_OUT" "data[1]['target_branch']")
assert_eq "3" "$E2E_MR_COUNT" "e2e planning-mr: normalize | planning-mr view emits 3 items"
assert_eq "changes_count,description,iid,labels,merged_at,target_branch,title,user_notes_count" "$E2E_MR_KEYS" "e2e planning-mr: view keys match gitlab-mr shape"
assert_eq "2026-04-05T12:00:00Z" "$E2E_MR_MERGED" "e2e planning-mr: merged_at carried through"
assert_eq "main" "$E2E_MR_TGT" "e2e planning-mr: target_branch carried through"

# --- Large payload (>200 KB) regression test for #279 ---
# 50 PRs × ~5 KB body each exceeds MAX_ARG_STRLEN when passed via env var.
# Fix: normalize_pulls reads HTTP body from stdin instead of env var.
# The payload is generated INSIDE the bash -c scope so the test harness itself
# does not hit the exec argv limit it is trying to certify the wrapper against.
LARGE_PRELUDE=$(mktemp)
build_prelude "$LARGE_PRELUDE"
# shellcheck disable=SC1090,SC2016
LARGE_OUT=$(GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r bash -c '
    source "$1"
    python3 -c "import json; print(json.dumps([{\"number\":i,\"title\":f\"t{i}\",\"body\":\"x\"*5000,\"state\":\"open\",\"labels\":[],\"user\":{\"login\":\"u\"},\"base\":{\"ref\":\"main\"},\"head\":{\"ref\":\"f\"},\"merged_at\":None,\"created_at\":\"2026-01-01T00:00:00Z\",\"updated_at\":\"2026-01-01T00:00:00Z\",\"changed_files\":0,\"additions\":0,\"deletions\":0} for i in range(50)]))" | normalize_pulls
' _ "$LARGE_PRELUDE")
LARGE_RC=$?
rm -f "$LARGE_PRELUDE"
assert_eq "0" "$LARGE_RC" "normalize_pulls: large payload (>200 KB) exits 0 (#279)"
if [ -n "$LARGE_OUT" ]; then
    pass "normalize_pulls: large payload produces non-empty stdout (#279)"
else
    fail "normalize_pulls: large payload produces non-empty stdout (#279): stdout was empty"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
