#!/usr/bin/env bash
# test-github-code-review-normalize.sh: unit-test the GitHub -> GitLab-shape
# normalizers in dev-apprenticeship/code-review/scripts/github-api.sh
# (ADR-0002, #256 PR 5).
#
# Code-review's normalizer surface overlaps partially with implementation's
# but adds `draft` to normalize_pulls (reviewer view needs it) and drops
# normalize_mr_commits (reviewers never consume commit-list data). One new
# normalizer — normalize_notes, mapping /issues/{n}/comments into the
# GitLab-MR-notes shape with system: false stamped on every row.
#
# Style matches test-github-triage/planning/implementation-normalize.sh
# (bash 3.2, python3 for JSON, build_prelude pattern for sourcing the
# script under test).
#
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$REPO_ROOT/dev-apprenticeship/code-review/scripts/github-api.sh"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# --- Fixtures ---

# GitHub /pulls fixture with `draft` flags so the reviewer view's draft
# passthrough gets exercised. The state collapse (open -> opened, closed +
# merged_at -> merged, closed + null merged_at -> closed) is the same
# invariant as planning/implementation but re-asserted here because the
# code-review normalize_pulls is a separate function (duplicated by design
# per ADR-0002 for script independence).
FIXTURE_PULLS='[
  {"url":"https://api.github.com/repos/o/r/pulls/10","number":10,"title":"Draft PR",
   "body":"pr-10","state":"open","draft":true,"merged_at":null,
   "labels":[{"id":1,"name":"feature"}],
   "user":{"login":"alice"},"base":{"ref":"main"},"head":{"ref":"feat/x"},
   "created_at":"2026-04-01T10:00:00Z","updated_at":"2026-04-02T10:00:00Z",
   "comments":1},
  {"url":"https://api.github.com/repos/o/r/pulls/11","number":11,"title":"Ready PR",
   "body":"pr-11","state":"open","draft":false,"merged_at":null,
   "labels":[{"id":2,"name":"bugfix"}],
   "user":{"login":"alice"},"base":{"ref":"main"},"head":{"ref":"fix/y"},
   "created_at":"2026-04-03T10:00:00Z","updated_at":"2026-04-05T12:00:00Z",
   "comments":4,"changed_files":7},
  {"url":"https://api.github.com/repos/o/r/pulls/12","number":12,"title":"Merged PR",
   "body":"pr-12","state":"closed","draft":false,"merged_at":"2026-04-06T12:00:00Z",
   "labels":[],
   "user":{"login":"carol"},"base":{"ref":"main"},"head":{"ref":"wip/z"},
   "created_at":"2026-04-04T10:00:00Z","updated_at":"2026-04-06T12:00:00Z",
   "comments":0}
]'

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
   "patch":"@@ -1,10 +0,0 @@\n-line1\n-line2\n"}
]'

# GitHub /issues/{n}/comments fixture. Only human discussion comes through
# this endpoint — system events (labeled/merged/...) live in /issues/{n}/timeline
# and are intentionally excluded from mr-notes. The normalizer stamps
# system: false on every row so the GitLab-shape filter continues to hold.
FIXTURE_NOTES='[
  {"id":1001,"body":"LGTM, minor nit inline",
   "user":{"login":"alice","id":7},
   "created_at":"2026-04-10T10:00:00Z","updated_at":"2026-04-10T10:00:00Z"},
  {"id":1002,"body":"Fixed the nit, please re-review",
   "user":{"login":"bob","id":8},
   "created_at":"2026-04-10T11:00:00Z","updated_at":"2026-04-10T11:00:00Z"},
  {"id":1003,"body":"Thanks!",
   "user":{"login":"alice","id":7},
   "created_at":"2026-04-10T11:30:00Z","updated_at":"2026-04-10T11:30:00Z"}
]'

# --- Plumbing: source just the function defs (stop before CMD dispatcher) ---
build_prelude() {
    awk '/^CMD=/{exit} {print}' "$SCRIPT" > "$1"
}

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

# --- normalize_pulls: state collapse + draft field + MR-shape ---
PULLS_OUT=$(run_fn normalize_pulls "$FIXTURE_PULLS")
P_COUNT=$(json_extract "$PULLS_OUT" "len(data)")
assert_eq "3" "$P_COUNT" "normalize_pulls: three entries"

P0_STATE=$(json_extract "$PULLS_OUT" "data[0]['state']")
P1_STATE=$(json_extract "$PULLS_OUT" "data[1]['state']")
P2_STATE=$(json_extract "$PULLS_OUT" "data[2]['state']")
assert_eq "opened" "$P0_STATE" "normalize_pulls: open -> opened"
assert_eq "opened" "$P1_STATE" "normalize_pulls: open (non-draft) -> opened"
assert_eq "merged" "$P2_STATE" "normalize_pulls: closed + merged_at -> merged"

P0_DRAFT=$(json_extract "$PULLS_OUT" "data[0]['draft']")
P1_DRAFT=$(json_extract "$PULLS_OUT" "data[1]['draft']")
P2_DRAFT=$(json_extract "$PULLS_OUT" "data[2]['draft']")
assert_eq "True" "$P0_DRAFT" "normalize_pulls: draft:true preserved"
assert_eq "False" "$P1_DRAFT" "normalize_pulls: draft:false preserved"
assert_eq "False" "$P2_DRAFT" "normalize_pulls: closed-merged draft defaults false"

P1_TGT=$(json_extract "$PULLS_OUT" "data[1]['target_branch']")
P1_SRC=$(json_extract "$PULLS_OUT" "data[1]['source_branch']")
P1_AUTHOR=$(json_extract "$PULLS_OUT" "data[1]['author']['username']")
P1_LABELS=$(json_extract "$PULLS_OUT" "','.join(data[1]['labels'])")
assert_eq "main" "$P1_TGT" "normalize_pulls: target_branch <- base.ref"
assert_eq "fix/y" "$P1_SRC" "normalize_pulls: source_branch <- head.ref"
assert_eq "alice" "$P1_AUTHOR" "normalize_pulls: author.username <- user.login"
assert_eq "bugfix" "$P1_LABELS" "normalize_pulls: labels flattened to strings"

P0_CHANGES=$(json_extract "$PULLS_OUT" "repr(data[0]['changes_count'])")
P1_CHANGES=$(json_extract "$PULLS_OUT" "data[1]['changes_count']")
assert_eq "None" "$P0_CHANGES" "normalize_pulls: missing changed_files -> null"
assert_eq "7" "$P1_CHANGES" "normalize_pulls: changes_count <- changed_files"

# --- normalize_mr_changes: /pulls/{n}/files -> {changes: [...]} ---
CHANGES_OUT=$(run_fn normalize_mr_changes "$FIXTURE_PULL_FILES")
CH_TOP_KEYS=$(json_extract "$CHANGES_OUT" "','.join(sorted(data.keys()))")
assert_eq "changes" "$CH_TOP_KEYS" "normalize_mr_changes: wraps into {changes: [...]}"

CH_COUNT=$(json_extract "$CHANGES_OUT" "len(data['changes'])")
assert_eq "3" "$CH_COUNT" "normalize_mr_changes: three entries"

CH0_NEW=$(json_extract "$CHANGES_OUT" "data['changes'][0]['new_file']")
CH0_DIFF=$(json_extract "$CHANGES_OUT" "'def foo' in data['changes'][0]['diff']")
assert_eq "True" "$CH0_NEW" "normalize_mr_changes: status added -> new_file=true"
assert_eq "True" "$CH0_DIFF" "normalize_mr_changes: diff <- patch (carries through)"

CH1_RENAMED=$(json_extract "$CHANGES_OUT" "data['changes'][1]['renamed_file']")
CH1_OLD_PATH=$(json_extract "$CHANGES_OUT" "data['changes'][1]['old_path']")
CH1_NEW_PATH=$(json_extract "$CHANGES_OUT" "data['changes'][1]['new_path']")
assert_eq "True" "$CH1_RENAMED" "normalize_mr_changes: status renamed -> renamed_file=true"
assert_eq "src/lib/really_old_name.py" "$CH1_OLD_PATH" "normalize_mr_changes: renamed old_path <- previous_filename"
assert_eq "src/lib/old_name.py" "$CH1_NEW_PATH" "normalize_mr_changes: renamed new_path <- filename"

CH2_DELETED=$(json_extract "$CHANGES_OUT" "data['changes'][2]['deleted_file']")
assert_eq "True" "$CH2_DELETED" "normalize_mr_changes: status removed -> deleted_file=true"

# --- normalize_notes: /issues/{n}/comments -> GitLab /notes shape ---
NOTES_OUT=$(run_fn normalize_notes "$FIXTURE_NOTES")
N_COUNT=$(json_extract "$NOTES_OUT" "len(data)")
assert_eq "3" "$N_COUNT" "normalize_notes: three entries"

N0_ID=$(json_extract "$NOTES_OUT" "data[0]['id']")
N0_BODY=$(json_extract "$NOTES_OUT" "data[0]['body']")
N0_AUTHOR=$(json_extract "$NOTES_OUT" "data[0]['author']['username']")
N0_SYSTEM=$(json_extract "$NOTES_OUT" "data[0]['system']")
assert_eq "1001" "$N0_ID" "normalize_notes: id preserved"
assert_eq "LGTM, minor nit inline" "$N0_BODY" "normalize_notes: body preserved"
assert_eq "alice" "$N0_AUTHOR" "normalize_notes: author.username <- user.login"
assert_eq "False" "$N0_SYSTEM" "normalize_notes: system: false stamped on every row"

# Iterate: all three rows must have system:false (invariant, not per-entry).
ALL_FALSE=$(json_extract "$NOTES_OUT" "all(not n['system'] for n in data)")
assert_eq "True" "$ALL_FALSE" "normalize_notes: system:false invariant holds for all rows"

# --- End-to-end: normalize_pulls -> project_json reviewer ---
# The four reviewer agents (style/logic/security/test) + approval_decider
# consume `merge-requests --view reviewer` on every tick. The view keys
# must stay locked to {iid, state, title, labels, source_branch,
# target_branch, draft, author}.
PIPE_PRELUDE=$(mktemp)
build_prelude "$PIPE_PRELUDE"
# shellcheck disable=SC1090,SC2016
E2E_OUT=$(GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r bash -c '
    source "$1"
    printf "%s" "$2" | normalize_pulls | project_json reviewer
' _ "$PIPE_PRELUDE" "$FIXTURE_PULLS")
rm -f "$PIPE_PRELUDE"

E2E_COUNT=$(json_extract "$E2E_OUT" "len(data)")
E2E_KEYS=$(json_extract "$E2E_OUT" "','.join(sorted(data[0].keys()))")
E2E_IID=$(json_extract "$E2E_OUT" "data[0]['iid']")
E2E_DRAFT=$(json_extract "$E2E_OUT" "data[0]['draft']")
E2E_AUTHOR=$(json_extract "$E2E_OUT" "data[0]['author']['username']")
assert_eq "3" "$E2E_COUNT" "e2e reviewer: normalize | reviewer view emits 3 items"
assert_eq "author,draft,iid,labels,source_branch,state,target_branch,title" "$E2E_KEYS" "e2e reviewer: view keys match gitlab reviewer shape"
assert_eq "10" "$E2E_IID" "e2e reviewer: view carries iid through pipe"
assert_eq "True" "$E2E_DRAFT" "e2e reviewer: draft flows through pipe"
assert_eq "alice" "$E2E_AUTHOR" "e2e reviewer: author.username preserved"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
