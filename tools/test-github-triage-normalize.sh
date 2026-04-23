#!/usr/bin/env bash
# test-github-triage-normalize.sh: unit-test the GitHub -> GitLab-shape
# normalizers in dev-apprenticeship/triage/scripts/github-api.sh
# (ADR-0002, #256 PR 2).
#
# GitHub API responses differ from GitLab's in field names (number vs iid,
# user vs author, login vs username), label shape (objects vs strings),
# state vocabulary (open vs opened), and response-body composition (issues
# list is mixed with PRs, pull_request key must be filtered out).
#
# github-api.sh normalizes these before handing JSON to project_json so the
# existing views and .ag agents can consume it unmodified. This test feeds
# canned GitHub fixtures through each normalize_* function and asserts the
# output is byte-correct GitLab-shape JSON.
#
# Matches the style of test-gitlab-views.sh (bash 3.2 discipline, python3
# for JSON, build_prelude pattern for sourcing the script under test).
#
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$REPO_ROOT/dev-apprenticeship/triage/scripts/github-api.sh"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# GitHub-shape fixtures. Hand-constructed from the actual
# https://docs.github.com/rest/issues/issues#list-repository-issues schema so
# the normalizer sees realistic payloads including the `pull_request` key
# (issues endpoint mixes issues and PRs), labels as objects, user vs author
# rename, login vs username rename, state open/closed (no "opened"), and
# `comments` as the user_notes_count equivalent.
FIXTURE_ISSUES='[
  {"url":"https://api.github.com/repos/o/r/issues/1","number":1,"title":"First",
   "body":"desc-1","state":"open","labels":[{"id":1,"name":"bug","color":"ff0000"},
   {"id":2,"name":"priority::high","color":"ff8800"}],
   "user":{"login":"alice","id":7,"type":"User"},
   "assignees":[{"login":"bob","id":8},{"login":"carol","id":9}],
   "created_at":"2026-04-01T10:00:00Z","updated_at":"2026-04-02T10:00:00Z",
   "comments":3,"author_association":"MEMBER"},
  {"url":"https://api.github.com/repos/o/r/issues/2","number":2,"title":"Second",
   "body":"desc-2","state":"open","labels":[],
   "user":{"login":"alice","id":7,"type":"User"},
   "assignees":[],"created_at":"2026-04-03T10:00:00Z","updated_at":"2026-04-04T10:00:00Z",
   "comments":0,"author_association":"MEMBER"},
  {"url":"https://api.github.com/repos/o/r/issues/3","number":3,"title":"PR-not-issue",
   "body":"pr-body","state":"open","labels":[{"id":3,"name":"feature","color":"00ff00"}],
   "user":{"login":"alice","id":7,"type":"User"},"assignees":[],
   "created_at":"2026-04-05T10:00:00Z","updated_at":"2026-04-06T10:00:00Z","comments":1,
   "pull_request":{"url":"https://api.github.com/repos/o/r/pulls/3",
   "html_url":"https://github.com/o/r/pull/3","diff_url":"","patch_url":""}}
]'

FIXTURE_SINGLE_ISSUE='{"url":"https://api.github.com/repos/o/r/issues/42","number":42,
  "title":"Single","body":"single-desc","state":"closed",
  "labels":[{"id":99,"name":"bug","color":"ff0000"}],
  "user":{"login":"alice","id":7},"assignees":[{"login":"bob","id":8}],
  "created_at":"2026-04-01T10:00:00Z","updated_at":"2026-04-10T10:00:00Z","comments":5}'

# GitHub /collaborators response — login only, no `name` field (that requires
# an extra /users/{login} hop). Our normalizer falls back to login for name.
FIXTURE_MEMBERS='[
  {"login":"alice","id":7,"type":"User","site_admin":false,
   "permissions":{"admin":true,"maintain":true,"push":true,"triage":true,"pull":true},
   "role_name":"admin"},
  {"login":"bob","id":8,"type":"User","site_admin":false,
   "permissions":{"admin":false,"maintain":false,"push":true,"triage":true,"pull":true},
   "role_name":"write"}
]'

# GitHub /labels response — color is a plain 6-hex-char string with no '#';
# our normalizer prepends '#' so downstream views match the GitLab shape.
FIXTURE_LABELS='[
  {"id":1,"name":"bug","description":"Something is broken","color":"ff0000","default":true},
  {"id":2,"name":"feature","description":"New functionality","color":"00ff00","default":false}
]'

# Source just the function defs from github-api.sh. Matches the pattern in
# test-gitlab-views.sh: awk-stops at the CLI case statement (CMD=) so the
# script never tries to hit an API. Stored in a temp file because `bash -c`
# can only `source` a path, not a variable.
build_prelude() {
    awk '/^CMD=/{exit} {print}' "$SCRIPT" > "$1"
}

# run_fn <fn-name> <input-json>
# Pipes the fixture through the named normalize function and prints stdout.
# The GITHUB_* dummy env vars satisfy github-api.sh's top-level env-check
# block (it fires during source-time because the check is outside a fn).
run_fn() {
    local fn="$1" input="$2"
    local prelude
    prelude=$(mktemp)
    build_prelude "$prelude"
    # shellcheck disable=SC1090,SC2016  # $1/$2/$3 are inner bash -c argv
    GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r bash -c '
        source "$1"
        printf "%s" "$2" | "$3"
    ' _ "$prelude" "$input" "$fn"
    local rc=$?
    rm -f "$prelude"
    return $rc
}

# json_extract <json> <python-expr>
# Evaluates a python expression against the JSON in the DATA env var and
# prints the result. Used in assertions to poke specific fields without
# writing one-off jq pipelines (keeps the test bash-3.2 friendly).
json_extract() {
    DATA="$1" python3 -c "
import os, json
data = json.loads(os.environ['DATA'])
print($2)
"
}

# assert_eq <expected> <actual> <label>
assert_eq() {
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3: expected='$1' actual='$2'"
    fi
}

# --- normalize_issues: PR filter + shape ---
ISSUES_OUT=$(run_fn normalize_issues "$FIXTURE_ISSUES")

# PR-filter: 3 items in, 2 out (issue #3 has pull_request key, must be dropped).
COUNT=$(json_extract "$ISSUES_OUT" "len(data)")
assert_eq "2" "$COUNT" "normalize_issues: pull_request entries filtered out"

# iid <- number mapping (the crux of every view that consumes iid).
IID0=$(json_extract "$ISSUES_OUT" "data[0]['iid']")
IID1=$(json_extract "$ISSUES_OUT" "data[1]['iid']")
assert_eq "1" "$IID0" "normalize_issues: issue[0].iid == number"
assert_eq "2" "$IID1" "normalize_issues: issue[1].iid == number"

# state open -> opened (matches GitLab vocabulary that .ag agents use).
STATE0=$(json_extract "$ISSUES_OUT" "data[0]['state']")
assert_eq "opened" "$STATE0" "normalize_issues: state open -> opened"

# labels: [{name}] -> [name] (flattened to strings for the labeler view).
LABELS0=$(json_extract "$ISSUES_OUT" "','.join(data[0]['labels'])")
assert_eq "bug,priority::high" "$LABELS0" "normalize_issues: labels flattened to strings"

# author.username <- user.login (feeds the #104 personal/team tagging path).
AUTHOR0=$(json_extract "$ISSUES_OUT" "data[0]['author']['username']")
assert_eq "alice" "$AUTHOR0" "normalize_issues: author.username == user.login"

# assignees[].username <- login (router's assignment decisions read this).
ASSIGNEE0_0=$(json_extract "$ISSUES_OUT" "data[0]['assignees'][0]['username']")
ASSIGNEE0_1=$(json_extract "$ISSUES_OUT" "data[0]['assignees'][1]['username']")
assert_eq "bob" "$ASSIGNEE0_0" "normalize_issues: assignee[0].username == login"
assert_eq "carol" "$ASSIGNEE0_1" "normalize_issues: assignee[1].username == login"

# user_notes_count <- comments (feedback-issue view can reuse this field).
NOTES0=$(json_extract "$ISSUES_OUT" "data[0]['user_notes_count']")
assert_eq "3" "$NOTES0" "normalize_issues: user_notes_count == comments"

# Empty labels/assignees on issue[1] normalize to [], not null.
EMPTY_LABELS=$(json_extract "$ISSUES_OUT" "data[1]['labels']")
EMPTY_ASSIGNEES=$(json_extract "$ISSUES_OUT" "data[1]['assignees']")
assert_eq "[]" "$EMPTY_LABELS" "normalize_issues: empty labels -> []"
assert_eq "[]" "$EMPTY_ASSIGNEES" "normalize_issues: empty assignees -> []"

# --- normalize_issue (single-issue variant) ---
SINGLE_OUT=$(run_fn normalize_issue "$FIXTURE_SINGLE_ISSUE")
SINGLE_IID=$(DATA="$SINGLE_OUT" python3 -c "import os, json; print(json.loads(os.environ['DATA'])['iid'])")
SINGLE_STATE=$(DATA="$SINGLE_OUT" python3 -c "import os, json; print(json.loads(os.environ['DATA'])['state'])")
assert_eq "42" "$SINGLE_IID" "normalize_issue: iid == number"
# Single-issue state "closed" stays as "closed" (translation is only for "open").
assert_eq "closed" "$SINGLE_STATE" "normalize_issue: state closed stays closed"

# --- normalize_members ---
MEMBERS_OUT=$(run_fn normalize_members "$FIXTURE_MEMBERS")
M_COUNT=$(json_extract "$MEMBERS_OUT" "len(data)")
M_USER0=$(json_extract "$MEMBERS_OUT" "data[0]['username']")
M_NAME0=$(json_extract "$MEMBERS_OUT" "data[0]['name']")
M_ID0=$(json_extract "$MEMBERS_OUT" "data[0]['id']")
assert_eq "2" "$M_COUNT" "normalize_members: two entries"
assert_eq "alice" "$M_USER0" "normalize_members: username == login"
assert_eq "alice" "$M_NAME0" "normalize_members: name falls back to login"
assert_eq "7" "$M_ID0" "normalize_members: id preserved"

# --- normalize_labels ---
LABELS_OUT=$(run_fn normalize_labels "$FIXTURE_LABELS")
L_COUNT=$(json_extract "$LABELS_OUT" "len(data)")
L_NAME0=$(json_extract "$LABELS_OUT" "data[0]['name']")
L_COLOR0=$(json_extract "$LABELS_OUT" "data[0]['color']")
L_DESC0=$(json_extract "$LABELS_OUT" "data[0]['description']")
assert_eq "2" "$L_COUNT" "normalize_labels: two entries"
assert_eq "bug" "$L_NAME0" "normalize_labels: name preserved"
# GitHub returns "ff0000"; we prepend '#' so the color field matches GitLab shape.
assert_eq "#ff0000" "$L_COLOR0" "normalize_labels: color prefixed with #"
assert_eq "Something is broken" "$L_DESC0" "normalize_labels: description preserved"

# --- End-to-end: normalize_issues -> project_json labeler ---
# Proves the pipe agents depend on actually produces the same shape as gitlab's
# labeler view (iid, title, labels, author). If this drifts, a github triage
# agent running `issues --view labeler` would silently see different keys.
PIPE_PRELUDE=$(mktemp)
build_prelude "$PIPE_PRELUDE"
# shellcheck disable=SC1090,SC2016
E2E_OUT=$(GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r bash -c '
    source "$1"
    printf "%s" "$2" | normalize_issues | project_json labeler
' _ "$PIPE_PRELUDE" "$FIXTURE_ISSUES")
rm -f "$PIPE_PRELUDE"

E2E_COUNT=$(json_extract "$E2E_OUT" "len(data)")
E2E_KEYS=$(json_extract "$E2E_OUT" "','.join(sorted(data[0].keys()))")
E2E_IID=$(json_extract "$E2E_OUT" "data[0]['iid']")
E2E_AUTHOR=$(json_extract "$E2E_OUT" "data[0]['author']['username']")
assert_eq "2" "$E2E_COUNT" "e2e: normalize | labeler view emits 2 items (PR filtered)"
assert_eq "author,iid,labels,title" "$E2E_KEYS" "e2e: labeler view keys match gitlab shape"
assert_eq "1" "$E2E_IID" "e2e: labeler view carries iid through pipe"
assert_eq "alice" "$E2E_AUTHOR" "e2e: labeler view carries author.username through pipe"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
