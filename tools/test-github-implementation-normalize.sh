#!/usr/bin/env bash
# test-github-implementation-normalize.sh: unit-test the GitHub -> GitLab-shape
# normalizers in dev-apprenticeship/implementation/scripts/github-api.sh
# (ADR-0002, #256 PR 4).
#
# Implementation's normalizer surface adds two endpoints planning did not need:
#   normalize_mr_changes   for `mr-changes` command (/pulls/{n}/files)
#   normalize_mr_commits   for `mr-commits` command (/pulls/{n}/commits)
# The other normalizers (normalize_issues, normalize_issue, normalize_pulls,
# normalize_timeline) are duplicated from the planning wrapper by design —
# intentional copy to keep the two scripts runtime-independent. This test
# re-asserts their shape so drift on either side fails loudly.
#
# Matches the style of test-github-triage-normalize.sh and
# test-github-planning-normalize.sh (bash 3.2, python3 for JSON, build_prelude
# pattern for sourcing the script under test).
#
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$REPO_ROOT/dev-apprenticeship/implementation/scripts/github-api.sh"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# --- Fixtures ---

# GitHub /issues fixture: two real issues plus one pull_request-bearing entry
# (must be filtered out).
FIXTURE_ISSUES='[
  {"url":"https://api.github.com/repos/o/r/issues/1","number":1,"title":"Impl me",
   "body":"impl-desc","state":"open","labels":[{"id":1,"name":"implementation"},
   {"id":2,"name":"priority:high"}],
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
   "body":"pr-body","state":"open","labels":[{"id":3,"name":"implementation"}],
   "user":{"login":"alice","id":7,"type":"User"},"assignees":[],
   "created_at":"2026-04-05T10:00:00Z","updated_at":"2026-04-06T10:00:00Z","comments":1,
   "pull_request":{"url":"https://api.github.com/repos/o/r/pulls/3"}}
]'

FIXTURE_SINGLE_ISSUE='{"url":"https://api.github.com/repos/o/r/issues/42","number":42,
  "title":"Single","body":"single-desc","state":"closed",
  "labels":[{"id":99,"name":"implementation"}],
  "user":{"login":"alice","id":7},"assignees":[{"login":"bob","id":8}],
  "created_at":"2026-04-01T10:00:00Z","updated_at":"2026-04-10T10:00:00Z","comments":5}'

# GitHub /pulls fixture. The `impl` view extracts {iid, title, merged_at,
# target_branch} — commit_composer reads --state merged --view impl to learn
# from prior MRs.
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

# GitHub /pulls/{n}/files fixture. Status drives new_file/deleted_file/renamed_file;
# patch carries the unified diff (absent on binary files — forwarded as empty
# string, not null, to match the subset gitlab-api.sh emits).
FIXTURE_PULL_FILES='[
  {"filename":"src/lib/new_feature.py","status":"added",
   "additions":42,"deletions":0,"changes":42,
   "patch":"@@ -0,0 +1,42 @@\n+def foo():\n+    pass\n"},
  {"filename":"src/lib/old_name.py","status":"renamed",
   "previous_filename":"src/lib/really_old_name.py",
   "additions":1,"deletions":1,"changes":2,
   "patch":"@@ -1,1 +1,1 @@\n-# old\n+# new\n"},
  {"filename":"src/lib/gone.py","status":"removed",
   "additions":0,"deletions":10,"changes":10,
   "patch":"@@ -1,10 +0,0 @@\n-line1\n-line2\n"},
  {"filename":"assets/logo.png","status":"modified","additions":0,"deletions":0,"changes":0}
]'

# GitHub /pulls/{n}/commits fixture. commit.author carries {name, email, date};
# the normalizer flattens it into {author_name, created_at} and derives title
# from the first line of message.
FIXTURE_PULL_COMMITS='[
  {"sha":"abc123","commit":{
     "author":{"name":"Alice Example","email":"alice@example.com",
               "date":"2026-04-01T10:00:00Z"},
     "message":"feat: add foo\n\nLonger body\nwith details."}},
  {"sha":"def456","commit":{
     "author":{"name":"Bob Example","email":"bob@example.com",
               "date":"2026-04-02T11:00:00Z"},
     "message":"fix: bar"}}
]'

# GitHub /issues/{n}/timeline fixture. Only labeled/unlabeled should survive
# normalize_timeline; the rest (committed, cross-referenced, ...) drop out.
FIXTURE_TIMELINE='[
  {"id":1,"event":"labeled","created_at":"2026-04-10T10:00:00Z",
   "actor":{"login":"alice"},"label":{"name":"implementation","color":"ff0000"}},
  {"id":2,"event":"cross-referenced","created_at":"2026-04-10T10:01:00Z",
   "actor":{"login":"bob"}},
  {"id":3,"event":"unlabeled","created_at":"2026-04-11T09:00:00Z",
   "actor":{"login":"alice"},"label":{"name":"implementation","color":"ff0000"}},
  {"id":4,"event":"labeled","created_at":"2026-04-12T09:00:00Z",
   "actor":{"login":"alice"},"label":{"name":"priority:high","color":"00ff00"}},
  {"id":5,"event":"committed","created_at":"2026-04-12T09:30:00Z"}
]'

# GitHub /issues/{n}/comments fixture for normalize_notes (#1360): the
# review-resolver mr-notes verb reads PR conversation comments under the issues
# endpoint. normalize_notes must emit the GitLab notes shape
# {id, body, author:{username}, created_at, system:false}.
FIXTURE_NOTES='[
  {"id":101,"body":"**Review Summary** (automated)\n\nMissing regression test.",
   "user":{"login":"reviewbot","id":1},"created_at":"2026-04-10T10:00:00Z",
   "updated_at":"2026-04-10T10:00:00Z"},
  {"id":102,"body":"Please also tighten the error message.",
   "user":{"login":"alice","id":2},"created_at":"2026-04-10T11:00:00Z",
   "updated_at":"2026-04-10T11:00:00Z"}
]'

# --- Plumbing: source just the function defs (stop before the CMD dispatcher) ---
build_prelude() {
    awk '/^CMD=/{exit} {print}' "$SCRIPT" > "$1"
}

# run_fn <fn-name> <input-json> [args...]
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
assert_eq "implementation,priority:high" "$LABELS0" "normalize_issues: labels flattened to strings"

AUTHOR0=$(json_extract "$ISSUES_OUT" "data[0]['author']['username']")
assert_eq "alice" "$AUTHOR0" "normalize_issues: author.username == user.login"

ASSIGNEE0=$(json_extract "$ISSUES_OUT" "data[0]['assignees'][0]['username']")
assert_eq "bob" "$ASSIGNEE0" "normalize_issues: assignees[].username <- login"

# --- normalize_issue (single-issue variant) ---
SINGLE_OUT=$(run_fn normalize_issue "$FIXTURE_SINGLE_ISSUE")
SINGLE_IID=$(json_extract "$SINGLE_OUT" "data['iid']")
SINGLE_STATE=$(json_extract "$SINGLE_OUT" "data['state']")
SINGLE_ASSIGNEE=$(json_extract "$SINGLE_OUT" "data['assignees'][0]['username']")
assert_eq "42" "$SINGLE_IID" "normalize_issue: iid == number"
assert_eq "closed" "$SINGLE_STATE" "normalize_issue: state closed stays closed"
assert_eq "bob" "$SINGLE_ASSIGNEE" "normalize_issue: single-issue assignees preserved"

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

P0_CHANGES=$(json_extract "$PULLS_OUT" "repr(data[0]['changes_count'])")
assert_eq "None" "$P0_CHANGES" "normalize_pulls: missing changed_files -> null"

# --- normalize_mr_changes: /pulls/{n}/files -> {changes: [...]} ---
CHANGES_OUT=$(run_fn normalize_mr_changes "$FIXTURE_PULL_FILES")
CH_TOP_KEYS=$(json_extract "$CHANGES_OUT" "','.join(sorted(data.keys()))")
assert_eq "changes" "$CH_TOP_KEYS" "normalize_mr_changes: wraps into {changes: [...]}"

CH_COUNT=$(json_extract "$CHANGES_OUT" "len(data['changes'])")
assert_eq "4" "$CH_COUNT" "normalize_mr_changes: four entries"

CH0_NEW=$(json_extract "$CHANGES_OUT" "data['changes'][0]['new_file']")
CH0_OLD_PATH=$(json_extract "$CHANGES_OUT" "data['changes'][0]['old_path']")
CH0_NEW_PATH=$(json_extract "$CHANGES_OUT" "data['changes'][0]['new_path']")
assert_eq "True" "$CH0_NEW" "normalize_mr_changes: status added -> new_file=true"
assert_eq "src/lib/new_feature.py" "$CH0_OLD_PATH" "normalize_mr_changes: added file old_path == new_path"
assert_eq "src/lib/new_feature.py" "$CH0_NEW_PATH" "normalize_mr_changes: added file new_path preserved"

CH1_RENAMED=$(json_extract "$CHANGES_OUT" "data['changes'][1]['renamed_file']")
CH1_OLD_PATH=$(json_extract "$CHANGES_OUT" "data['changes'][1]['old_path']")
CH1_NEW_PATH=$(json_extract "$CHANGES_OUT" "data['changes'][1]['new_path']")
assert_eq "True" "$CH1_RENAMED" "normalize_mr_changes: status renamed -> renamed_file=true"
assert_eq "src/lib/really_old_name.py" "$CH1_OLD_PATH" "normalize_mr_changes: renamed old_path <- previous_filename"
assert_eq "src/lib/old_name.py" "$CH1_NEW_PATH" "normalize_mr_changes: renamed new_path <- filename"

CH2_DELETED=$(json_extract "$CHANGES_OUT" "data['changes'][2]['deleted_file']")
assert_eq "True" "$CH2_DELETED" "normalize_mr_changes: status removed -> deleted_file=true"

# Binary file with no patch — diff should be empty string, not missing.
CH3_DIFF=$(json_extract "$CHANGES_OUT" "repr(data['changes'][3]['diff'])")
assert_eq "''" "$CH3_DIFF" "normalize_mr_changes: binary (no patch) -> diff=''"

# --- normalize_mr_commits: /pulls/{n}/commits -> [{id, title, message, author_name, created_at}] ---
COMMITS_OUT=$(run_fn normalize_mr_commits "$FIXTURE_PULL_COMMITS")
C_COUNT=$(json_extract "$COMMITS_OUT" "len(data)")
assert_eq "2" "$C_COUNT" "normalize_mr_commits: two entries"

C0_ID=$(json_extract "$COMMITS_OUT" "data[0]['id']")
C0_TITLE=$(json_extract "$COMMITS_OUT" "data[0]['title']")
C0_AUTHOR=$(json_extract "$COMMITS_OUT" "data[0]['author_name']")
C0_DATE=$(json_extract "$COMMITS_OUT" "data[0]['created_at']")
assert_eq "abc123" "$C0_ID" "normalize_mr_commits: id <- sha"
assert_eq "feat: add foo" "$C0_TITLE" "normalize_mr_commits: title is first line of message"
assert_eq "Alice Example" "$C0_AUTHOR" "normalize_mr_commits: author_name <- commit.author.name"
assert_eq "2026-04-01T10:00:00Z" "$C0_DATE" "normalize_mr_commits: created_at <- commit.author.date"

# --- normalize_notes (#1360): /issues/{n}/comments -> GitLab notes shape ---
NOTES_OUT=$(run_fn normalize_notes "$FIXTURE_NOTES")
N_COUNT=$(json_extract "$NOTES_OUT" "len(data)")
assert_eq "2" "$N_COUNT" "normalize_notes: two notes"

N0_KEYS=$(json_extract "$NOTES_OUT" "','.join(sorted(data[0].keys()))")
assert_eq "author,body,created_at,id,system,updated_at" "$N0_KEYS" "normalize_notes: GitLab notes shape keys"

N0_ID=$(json_extract "$NOTES_OUT" "data[0]['id']")
N0_AUTHOR=$(json_extract "$NOTES_OUT" "data[0]['author']['username']")
N0_SYSTEM=$(json_extract "$NOTES_OUT" "data[0]['system']")
N0_CREATED=$(json_extract "$NOTES_OUT" "data[0]['created_at']")
assert_eq "101" "$N0_ID" "normalize_notes: id <- comment.id"
assert_eq "reviewbot" "$N0_AUTHOR" "normalize_notes: author.username <- user.login"
assert_eq "False" "$N0_SYSTEM" "normalize_notes: system stamped false (so the GitLab-shape filter works)"
assert_eq "2026-04-10T10:00:00Z" "$N0_CREATED" "normalize_notes: created_at preserved"

# --- mr-notes verb (#1360): exists + rejects a non-numeric number with exit 2 ---
# The numeric guard runs BEFORE any network call, so this needs no curl stub.
if grep -Eq '^[[:space:]]*mr-notes\)' "$SCRIPT"; then
    pass "mr-notes verb: present in the GitHub implementation backend"
else
    fail "mr-notes verb: present in the GitHub implementation backend"
fi
MRNOTES_RC=0
GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r \
    bash "$SCRIPT" mr-notes not-a-number >/dev/null 2>&1 || MRNOTES_RC=$?
assert_eq "2" "$MRNOTES_RC" "mr-notes verb: non-numeric number exits 2"

# --- normalize_timeline: label events only + add/remove mapping ---
TIMELINE_OUT=$(run_fn normalize_timeline "$FIXTURE_TIMELINE" "" "")
T_COUNT=$(json_extract "$TIMELINE_OUT" "len(data)")
assert_eq "3" "$T_COUNT" "normalize_timeline: non-label events dropped (committed/cross-referenced)"

T0_ACTION=$(json_extract "$TIMELINE_OUT" "data[0]['action']")
T0_LABEL=$(json_extract "$TIMELINE_OUT" "data[0]['label']")
T0_USER=$(json_extract "$TIMELINE_OUT" "data[0]['user']")
assert_eq "add" "$T0_ACTION" "normalize_timeline: labeled -> add"
assert_eq "implementation" "$T0_LABEL" "normalize_timeline: label.name preserved"
assert_eq "alice" "$T0_USER" "normalize_timeline: actor.login -> user"

T1_ACTION=$(json_extract "$TIMELINE_OUT" "data[1]['action']")
assert_eq "remove" "$T1_ACTION" "normalize_timeline: unlabeled -> remove"

TL_LABEL_ONLY=$(run_fn normalize_timeline "$FIXTURE_TIMELINE" "implementation" "")
TL_LABEL_COUNT=$(json_extract "$TL_LABEL_ONLY" "len(data)")
assert_eq "2" "$TL_LABEL_COUNT" "normalize_timeline: label filter narrows to 'implementation' events"

TL_SINCE=$(run_fn normalize_timeline "$FIXTURE_TIMELINE" "" "2026-04-11T00:00:00Z")
TL_SINCE_COUNT=$(json_extract "$TL_SINCE" "len(data)")
assert_eq "2" "$TL_SINCE_COUNT" "normalize_timeline: since filter drops pre-cutoff events"

# --- End-to-end: normalize_issues -> project_json assigned ---
# code_writer reads `assigned-issues --view assigned` for trigger detection.
# The view keys must stay locked to {iid, title, description, labels,
# assignees, priority, updated_at} — drift would silently misfeed prompts.
PIPE_PRELUDE=$(mktemp)
build_prelude "$PIPE_PRELUDE"
# shellcheck disable=SC1090,SC2016
E2E_OUT=$(GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r bash -c '
    source "$1"
    printf "%s" "$2" | normalize_issues | project_json assigned
' _ "$PIPE_PRELUDE" "$FIXTURE_ISSUES")
rm -f "$PIPE_PRELUDE"

E2E_COUNT=$(json_extract "$E2E_OUT" "len(data)")
E2E_KEYS=$(json_extract "$E2E_OUT" "','.join(sorted(data[0].keys()))")
E2E_IID=$(json_extract "$E2E_OUT" "data[0]['iid']")
E2E_ASSIGNEE=$(json_extract "$E2E_OUT" "data[0]['assignees'][0]['username']")
E2E_PRIORITY=$(json_extract "$E2E_OUT" "repr(data[0]['priority'])")
assert_eq "2" "$E2E_COUNT" "e2e assigned: normalize | assigned view emits 2 items (PR filtered)"
assert_eq "assignees,description,iid,labels,priority,title,updated_at" "$E2E_KEYS" "e2e assigned: view keys match gitlab shape"
assert_eq "1" "$E2E_IID" "e2e assigned: view carries iid through pipe"
assert_eq "bob" "$E2E_ASSIGNEE" "e2e assigned: view carries assignees[].username through pipe"
assert_eq "None" "$E2E_PRIORITY" "e2e assigned: GitHub issue -> priority null"

# --- End-to-end: normalize_pulls -> project_json impl ---
# commit_composer reads `merge-requests --state merged --view impl` to learn
# merge cadence. View keys must be {iid, title, merged_at, target_branch}.
PIPE_PRELUDE2=$(mktemp)
build_prelude "$PIPE_PRELUDE2"
# shellcheck disable=SC1090,SC2016
E2E_MR_OUT=$(GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r bash -c '
    source "$1"
    printf "%s" "$2" | normalize_pulls | project_json impl
' _ "$PIPE_PRELUDE2" "$FIXTURE_PULLS")
rm -f "$PIPE_PRELUDE2"

E2E_MR_COUNT=$(json_extract "$E2E_MR_OUT" "len(data)")
E2E_MR_KEYS=$(json_extract "$E2E_MR_OUT" "','.join(sorted(data[0].keys()))")
E2E_MR_MERGED=$(json_extract "$E2E_MR_OUT" "data[1]['merged_at']")
E2E_MR_TGT=$(json_extract "$E2E_MR_OUT" "data[1]['target_branch']")
assert_eq "3" "$E2E_MR_COUNT" "e2e impl: normalize | impl view emits 3 items"
assert_eq "iid,merged_at,target_branch,title" "$E2E_MR_KEYS" "e2e impl: view keys match gitlab impl shape"
assert_eq "2026-04-05T12:00:00Z" "$E2E_MR_MERGED" "e2e impl: merged_at carried through"
assert_eq "main" "$E2E_MR_TGT" "e2e impl: target_branch carried through"

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
