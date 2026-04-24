#!/usr/bin/env bash
# test-github-release-normalize.sh: unit-test the GitHub -> GitLab-shape
# normalizers in dev-apprenticeship/release/scripts/github-api.sh
# (ADR-0002, #256 PR 6).
#
# The release colony's surface is broader than code-review's: four normalizers
# (releases, tags, pipelines, pulls) and four views (release-summary,
# tag-summary, pipeline-summary, release-mr). Two of the normalizers forward
# nulls where GitHub's list responses lack the GitLab-equivalent field:
#   normalize_tags  — message, commit.created_at (require N+1 per-tag calls
#                     to /git/tags and /git/commits to recover)
#   normalize_releases — commit (not embedded in the /releases list response)
# normalize_pipelines has the heaviest collapse logic — two GitHub fields
# (status, conclusion) → one GitLab field (status) — and this test locks down
# every branch so ship_decider's `status == "success"` check stays accurate.
#
# Style matches test-github-triage/planning/implementation/code-review-normalize.sh
# (bash 3.2, python3 for JSON, build_prelude pattern for sourcing the
# script under test).
#
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$REPO_ROOT/dev-apprenticeship/release/scripts/github-api.sh"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# --- Fixtures ---

# GitHub /releases list response. `body` (GitLab `description`), `published_at`
# (GitLab `released_at`), and author:{login} are the three renames. `commit` is
# intentionally absent from GitHub's list response (available via per-release
# /releases/{id} + /git/refs/tags/{tag} dance — not worth N+1 calls for prompt
# context); the normalizer forwards commit: null.
FIXTURE_RELEASES='[
  {"id":501,"tag_name":"v1.2.3","name":"Release 1.2.3",
   "body":"- fix: bug A\n- feat: thing B","draft":false,"prerelease":false,
   "created_at":"2026-03-01T10:00:00Z","published_at":"2026-03-01T12:00:00Z",
   "author":{"login":"alice","id":7},
   "html_url":"https://github.com/o/r/releases/tag/v1.2.3"},
  {"id":502,"tag_name":"v1.2.2","name":"Release 1.2.2",
   "body":"- fix: something","draft":false,"prerelease":false,
   "created_at":"2026-02-15T10:00:00Z","published_at":"2026-02-15T12:00:00Z",
   "author":{"login":"bob","id":8},
   "html_url":"https://github.com/o/r/releases/tag/v1.2.2"}
]'

# GitHub /tags list response. Thin payload — no tag-object message (annotated
# tag metadata lives behind per-tag /git/tags/{sha}) and no commit.created_at
# (lives behind /git/commits/{sha}). short_id is derived from the first 8 sha
# characters to match GitLab's output.
FIXTURE_TAGS='[
  {"name":"v1.2.3","commit":{"sha":"abc123def456abc123def456abc123def456abcd",
                             "url":"https://api.github.com/repos/o/r/commits/abc123d"},
   "zipball_url":"https://github.com/o/r/zipball/v1.2.3",
   "tarball_url":"https://github.com/o/r/tarball/v1.2.3",
   "node_id":"MDIwOlRhZ1YxLjIuMw=="},
  {"name":"v1.2.2","commit":{"sha":"fff111aaa222fff111aaa222fff111aaa222fff1",
                             "url":"https://api.github.com/repos/o/r/commits/fff111a"},
   "zipball_url":"https://github.com/o/r/zipball/v1.2.2",
   "tarball_url":"https://github.com/o/r/tarball/v1.2.2",
   "node_id":"MDIwOlRhZ1YxLjIuMg=="}
]'

# GitHub /actions/runs response. Envelope-wrapped {total_count, workflow_runs}.
# The five distinct status/conclusion combinations below are the full state
# machine ship_decider and release_checker need to reason about.
FIXTURE_PIPELINES='{"total_count":5,"workflow_runs":[
  {"id":9001,"name":"CI","head_branch":"main","head_sha":"abc123def456abc123def456abc123def456abcd",
   "status":"completed","conclusion":"success",
   "created_at":"2026-04-06T10:00:00Z","updated_at":"2026-04-06T10:15:00Z",
   "html_url":"https://github.com/o/r/actions/runs/9001"},
  {"id":9002,"name":"CI","head_branch":"main","head_sha":"def456abc123def456abc123def456abc123def4",
   "status":"completed","conclusion":"failure",
   "created_at":"2026-04-06T09:00:00Z","updated_at":"2026-04-06T09:10:00Z",
   "html_url":"https://github.com/o/r/actions/runs/9002"},
  {"id":9003,"name":"CI","head_branch":"main","head_sha":"111222333444111222333444111222333444aaaa",
   "status":"in_progress","conclusion":null,
   "created_at":"2026-04-06T11:00:00Z","updated_at":"2026-04-06T11:00:00Z",
   "html_url":"https://github.com/o/r/actions/runs/9003"},
  {"id":9004,"name":"CI","head_branch":"main","head_sha":"555666777888555666777888555666777888bbbb",
   "status":"queued","conclusion":null,
   "created_at":"2026-04-06T11:05:00Z","updated_at":"2026-04-06T11:05:00Z",
   "html_url":"https://github.com/o/r/actions/runs/9004"},
  {"id":9005,"name":"CI","head_branch":"main","head_sha":"999aaaabbbbccccdddd999aaaabbbbccccdddd00",
   "status":"completed","conclusion":"cancelled",
   "created_at":"2026-04-05T20:00:00Z","updated_at":"2026-04-05T20:05:00Z",
   "html_url":"https://github.com/o/r/actions/runs/9005"}
]}'

# GitHub /pulls list response (same shape as code-review/planning/implementation
# fixtures, no `draft` need here — release-mr view doesnt consume it). The
# state collapse coverage (open -> opened; closed + merged_at -> merged;
# closed + null -> closed) is repeated per-colony on purpose: each github-api.sh
# ships its own normalize_pulls copy and this test certifies *this* copy.
FIXTURE_PULLS='[
  {"number":20,"title":"Open PR","body":"desc-20","state":"open","merged_at":null,
   "labels":[{"name":"release-note"}],"user":{"login":"alice"},
   "base":{"ref":"main"},"head":{"ref":"feat/x"},
   "created_at":"2026-04-01T10:00:00Z","updated_at":"2026-04-02T10:00:00Z",
   "comments":1,"changed_files":3},
  {"number":21,"title":"Merged PR","body":"desc-21","state":"closed",
   "merged_at":"2026-04-05T12:00:00Z",
   "labels":[{"name":"bug"}],"user":{"login":"bob"},
   "base":{"ref":"main"},"head":{"ref":"fix/y"},
   "created_at":"2026-04-03T10:00:00Z","updated_at":"2026-04-05T12:00:00Z",
   "comments":2,"changed_files":5},
  {"number":22,"title":"Closed No-Merge","body":"desc-22","state":"closed",
   "merged_at":null,
   "labels":[],"user":{"login":"carol"},
   "base":{"ref":"main"},"head":{"ref":"wip/z"},
   "created_at":"2026-04-04T10:00:00Z","updated_at":"2026-04-04T12:00:00Z",
   "comments":0}
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

# --- normalize_releases ---
RELEASES_OUT=$(run_fn normalize_releases "$FIXTURE_RELEASES")
R_COUNT=$(json_extract "$RELEASES_OUT" "len(data)")
assert_eq "2" "$R_COUNT" "normalize_releases: two entries"

R0_TAG=$(json_extract "$RELEASES_OUT" "data[0]['tag_name']")
R0_NAME=$(json_extract "$RELEASES_OUT" "data[0]['name']")
R0_DESC=$(json_extract "$RELEASES_OUT" "data[0]['description']")
R0_RELEASED=$(json_extract "$RELEASES_OUT" "data[0]['released_at']")
R0_CREATED=$(json_extract "$RELEASES_OUT" "data[0]['created_at']")
R0_AUTHOR=$(json_extract "$RELEASES_OUT" "data[0]['author']['username']")
R0_COMMIT=$(json_extract "$RELEASES_OUT" "repr(data[0]['commit'])")
assert_eq "v1.2.3" "$R0_TAG" "normalize_releases: tag_name preserved"
assert_eq "Release 1.2.3" "$R0_NAME" "normalize_releases: name preserved"
assert_eq "- fix: bug A
- feat: thing B" "$R0_DESC" "normalize_releases: description <- body"
assert_eq "2026-03-01T12:00:00Z" "$R0_RELEASED" "normalize_releases: released_at <- published_at"
assert_eq "2026-03-01T10:00:00Z" "$R0_CREATED" "normalize_releases: created_at preserved"
assert_eq "alice" "$R0_AUTHOR" "normalize_releases: author.username <- author.login"
assert_eq "None" "$R0_COMMIT" "normalize_releases: commit forwarded null"

# --- normalize_tags ---
TAGS_OUT=$(run_fn normalize_tags "$FIXTURE_TAGS")
T_COUNT=$(json_extract "$TAGS_OUT" "len(data)")
assert_eq "2" "$T_COUNT" "normalize_tags: two entries"

T0_NAME=$(json_extract "$TAGS_OUT" "data[0]['name']")
T0_MSG=$(json_extract "$TAGS_OUT" "repr(data[0]['message'])")
T0_TARGET=$(json_extract "$TAGS_OUT" "data[0]['target']")
T0_COMMIT_ID=$(json_extract "$TAGS_OUT" "data[0]['commit']['id']")
T0_COMMIT_SHORT=$(json_extract "$TAGS_OUT" "data[0]['commit']['short_id']")
T0_COMMIT_CREATED=$(json_extract "$TAGS_OUT" "repr(data[0]['commit']['created_at'])")
assert_eq "v1.2.3" "$T0_NAME" "normalize_tags: name preserved"
assert_eq "None" "$T0_MSG" "normalize_tags: message forwarded null (no /git/tags round-trip)"
assert_eq "abc123def456abc123def456abc123def456abcd" "$T0_TARGET" "normalize_tags: target <- commit.sha"
assert_eq "abc123def456abc123def456abc123def456abcd" "$T0_COMMIT_ID" "normalize_tags: commit.id <- commit.sha"
assert_eq "abc123de" "$T0_COMMIT_SHORT" "normalize_tags: commit.short_id = sha[:8]"
assert_eq "None" "$T0_COMMIT_CREATED" "normalize_tags: commit.created_at forwarded null"

# --- normalize_pipelines: status/conclusion collapse is the critical one ---
PIPE_OUT=$(run_fn normalize_pipelines "$FIXTURE_PIPELINES")
P_COUNT=$(json_extract "$PIPE_OUT" "len(data)")
assert_eq "5" "$P_COUNT" "normalize_pipelines: envelope unwrapped to 5 entries"

P0_STATUS=$(json_extract "$PIPE_OUT" "data[0]['status']")
P1_STATUS=$(json_extract "$PIPE_OUT" "data[1]['status']")
P2_STATUS=$(json_extract "$PIPE_OUT" "data[2]['status']")
P3_STATUS=$(json_extract "$PIPE_OUT" "data[3]['status']")
P4_STATUS=$(json_extract "$PIPE_OUT" "data[4]['status']")
assert_eq "success" "$P0_STATUS" "normalize_pipelines: completed+success -> success"
assert_eq "failed"  "$P1_STATUS" "normalize_pipelines: completed+failure -> failed"
assert_eq "running" "$P2_STATUS" "normalize_pipelines: in_progress -> running"
assert_eq "pending" "$P3_STATUS" "normalize_pipelines: queued -> pending"
assert_eq "failed"  "$P4_STATUS" "normalize_pipelines: completed+cancelled -> failed"

P0_ID=$(json_extract "$PIPE_OUT" "data[0]['id']")
P0_REF=$(json_extract "$PIPE_OUT" "data[0]['ref']")
P0_SHA=$(json_extract "$PIPE_OUT" "data[0]['sha']")
P0_CREATED=$(json_extract "$PIPE_OUT" "data[0]['created_at']")
P0_WEB=$(json_extract "$PIPE_OUT" "data[0]['web_url']")
assert_eq "9001" "$P0_ID" "normalize_pipelines: id preserved"
assert_eq "main" "$P0_REF" "normalize_pipelines: ref <- head_branch"
assert_eq "abc123def456abc123def456abc123def456abcd" "$P0_SHA" "normalize_pipelines: sha <- head_sha"
assert_eq "2026-04-06T10:00:00Z" "$P0_CREATED" "normalize_pipelines: created_at preserved"
assert_eq "https://github.com/o/r/actions/runs/9001" "$P0_WEB" "normalize_pipelines: web_url <- html_url"

# Bare-array fallback: /actions/runs normally returns {workflow_runs:[...]}
# but the normalizer also accepts a raw array so ad-hoc callers (e.g. piping
# a pre-unwrapped JSON) dont need to re-wrap.
BARE_PIPE='[{"id":1,"name":"x","head_branch":"main","head_sha":"0000","status":"completed","conclusion":"success","created_at":"2026-01-01T00:00:00Z","html_url":"https://github.com/o/r/actions/runs/1"}]'
BARE_OUT=$(run_fn normalize_pipelines "$BARE_PIPE")
BARE_COUNT=$(json_extract "$BARE_OUT" "len(data)")
BARE_STATUS=$(json_extract "$BARE_OUT" "data[0]['status']")
assert_eq "1" "$BARE_COUNT" "normalize_pipelines: bare-array input also accepted"
assert_eq "success" "$BARE_STATUS" "normalize_pipelines: bare-array status collapse still works"

# --- normalize_pulls: state collapse + MR-shape (release-mr-consuming fields) ---
PULLS_OUT=$(run_fn normalize_pulls "$FIXTURE_PULLS")
PL_COUNT=$(json_extract "$PULLS_OUT" "len(data)")
assert_eq "3" "$PL_COUNT" "normalize_pulls: three entries"

PL0_STATE=$(json_extract "$PULLS_OUT" "data[0]['state']")
PL1_STATE=$(json_extract "$PULLS_OUT" "data[1]['state']")
PL2_STATE=$(json_extract "$PULLS_OUT" "data[2]['state']")
assert_eq "opened" "$PL0_STATE" "normalize_pulls: open -> opened"
assert_eq "merged" "$PL1_STATE" "normalize_pulls: closed + merged_at -> merged"
assert_eq "closed" "$PL2_STATE" "normalize_pulls: closed + null merged_at stays closed"

PL1_IID=$(json_extract "$PULLS_OUT" "data[1]['iid']")
PL1_DESC=$(json_extract "$PULLS_OUT" "data[1]['description']")
PL1_MERGED=$(json_extract "$PULLS_OUT" "data[1]['merged_at']")
PL1_TGT=$(json_extract "$PULLS_OUT" "data[1]['target_branch']")
PL1_LABELS=$(json_extract "$PULLS_OUT" "','.join(data[1]['labels'])")
assert_eq "21" "$PL1_IID" "normalize_pulls: iid <- number"
assert_eq "desc-21" "$PL1_DESC" "normalize_pulls: description <- body"
assert_eq "2026-04-05T12:00:00Z" "$PL1_MERGED" "normalize_pulls: merged_at preserved"
assert_eq "main" "$PL1_TGT" "normalize_pulls: target_branch <- base.ref"
assert_eq "bug" "$PL1_LABELS" "normalize_pulls: labels flattened to strings"

# --- End-to-end: project_json views consume normalized output ---
# release-summary: 4 keys (tag_name, name, released_at, description)
E2E_RS=$(
    PRELUDE=$(mktemp)
    build_prelude "$PRELUDE"
    # shellcheck disable=SC1090,SC2016
    GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r bash -c '
        source "$1"
        printf "%s" "$2" | normalize_releases | project_json release-summary
    ' _ "$PRELUDE" "$FIXTURE_RELEASES"
    rm -f "$PRELUDE"
)
E2E_RS_KEYS=$(json_extract "$E2E_RS" "','.join(sorted(data[0].keys()))")
E2E_RS_TAG=$(json_extract "$E2E_RS" "data[0]['tag_name']")
assert_eq "description,name,released_at,tag_name" "$E2E_RS_KEYS" "e2e release-summary: view keys match gitlab"
assert_eq "v1.2.3" "$E2E_RS_TAG" "e2e release-summary: tag_name through pipe"

# tag-summary: 3 top-level keys (name, message, commit); commit has short_id, created_at
E2E_TS=$(
    PRELUDE=$(mktemp)
    build_prelude "$PRELUDE"
    # shellcheck disable=SC1090,SC2016
    GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r bash -c '
        source "$1"
        printf "%s" "$2" | normalize_tags | project_json tag-summary
    ' _ "$PRELUDE" "$FIXTURE_TAGS"
    rm -f "$PRELUDE"
)
E2E_TS_KEYS=$(json_extract "$E2E_TS" "','.join(sorted(data[0].keys()))")
E2E_TS_COMMIT_KEYS=$(json_extract "$E2E_TS" "','.join(sorted(data[0]['commit'].keys()))")
E2E_TS_SHORT=$(json_extract "$E2E_TS" "data[0]['commit']['short_id']")
assert_eq "commit,message,name" "$E2E_TS_KEYS" "e2e tag-summary: top-level keys match gitlab"
assert_eq "created_at,short_id" "$E2E_TS_COMMIT_KEYS" "e2e tag-summary: commit keys match gitlab"
assert_eq "abc123de" "$E2E_TS_SHORT" "e2e tag-summary: short_id through pipe"

# pipeline-summary: 6 keys (id, status, ref, sha, created_at, web_url)
E2E_PS=$(
    PRELUDE=$(mktemp)
    build_prelude "$PRELUDE"
    # shellcheck disable=SC1090,SC2016
    GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r bash -c '
        source "$1"
        printf "%s" "$2" | normalize_pipelines | project_json pipeline-summary
    ' _ "$PRELUDE" "$FIXTURE_PIPELINES"
    rm -f "$PRELUDE"
)
E2E_PS_KEYS=$(json_extract "$E2E_PS" "','.join(sorted(data[0].keys()))")
E2E_PS_STATUS=$(json_extract "$E2E_PS" "data[0]['status']")
assert_eq "created_at,id,ref,sha,status,web_url" "$E2E_PS_KEYS" "e2e pipeline-summary: view keys match gitlab"
assert_eq "success" "$E2E_PS_STATUS" "e2e pipeline-summary: status through pipe"

# release-mr: 6 keys (iid, title, description, merged_at, labels, target_branch)
E2E_MR=$(
    PRELUDE=$(mktemp)
    build_prelude "$PRELUDE"
    # shellcheck disable=SC1090,SC2016
    GITHUB_URL=http://x GITHUB_TOKEN=y GITHUB_OWNER=o GITHUB_REPO=r bash -c '
        source "$1"
        printf "%s" "$2" | normalize_pulls | project_json release-mr
    ' _ "$PRELUDE" "$FIXTURE_PULLS"
    rm -f "$PRELUDE"
)
E2E_MR_KEYS=$(json_extract "$E2E_MR" "','.join(sorted(data[0].keys()))")
E2E_MR_IID=$(json_extract "$E2E_MR" "data[1]['iid']")
E2E_MR_STATE_MERGED=$(json_extract "$E2E_MR" "data[1]['merged_at']")
assert_eq "description,iid,labels,merged_at,target_branch,title" "$E2E_MR_KEYS" "e2e release-mr: view keys match gitlab"
assert_eq "21" "$E2E_MR_IID" "e2e release-mr: iid through pipe"
assert_eq "2026-04-05T12:00:00Z" "$E2E_MR_STATE_MERGED" "e2e release-mr: merged_at through pipe"

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
