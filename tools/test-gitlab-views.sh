#!/usr/bin/env bash
# test-gitlab-views.sh: unit-test the project_json view projections defined in
# each colony's scripts/gitlab-api.sh (issue #119).
#
# For every (colony, view) pair we care about, this test:
#   1. Sources the colony's gitlab-api.sh (via a "prelude" that stops right
#      before the CLI case statement, so the script never tries to hit
#      $GITLAB_URL) and invokes project_json directly with a fixture on stdin.
#   2. Checks the output parses as JSON (python3 json.load — no jq).
#   3. Checks every top-level array element contains EXACTLY the expected
#      set of keys (no extras — that's the whole point of the projection).
#   4. Checks the output is <= 30% the size of the input (the downselection
#      objective from #119; projections that don't clear this bar have
#      drifted and need a look).
#
# Runs under bash 3.2 (stock macOS) and bash 4+. No associative arrays, no
# mapfile, no ${var^^}, no backslash-newline inside case-pattern labels — same
# discipline as tools/colony-lint.sh so the macOS CI path stays green (#121).
#
# Exit 0 all-pass, 1 any-fail.

set -u  # `set -e` would fire on the first assertion miss; we want to run all
        # cases and report totals, so errors are checked explicitly.

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# Canned GitLab JSON fixtures. Each one is deliberately noisy — has fields
# beyond what any view needs — so a projection that leaks a field by accident
# shows up as an assertion miss in check_keys. Not checked into tests/ per the
# spec; kept inline so the fixture travels with the test.
#
# The noise fields (description_html, avatar_url, _links, time_stats, etc.)
# are also what dominates real GitLab payload size — keep them beefy so the
# 30% size assertion reflects the real-world compression ratio, not a fixture
# artifact. Build_noise() gives each fixture element a chunky HTML blob to
# approximate GitLab's actual description_html bloat.
NOISE='<div class=\"note\"><p>Long description that GitLab renders server-side into bulky HTML with lots of classes and attributes, representing the realistic payload size that drives #119 LLM cost: <a href=\"https://example.gitlab/group/project/-/blob/main/docs/huge-reference-link.md\" class=\"gfm gfm-project_member\" data-reference-type=\"project_member\">reference</a> plus some <code>inline code</code> and <strong>bold text</strong> and more prose that mimics a real issue body after GitLab Markdown pipeline rendering.</p></div>'

FIXTURE_ISSUES='[{"id":100,"iid":1,"project_id":42,"title":"First","description":"desc-1","description_html":"'"$NOISE"'","state":"opened","labels":["bug","priority::high"],"author":{"id":7,"username":"alice","name":"Alice","email":"alice@example.com","avatar_url":"https://secure.gravatar.com/avatar/0123456789abcdef0123456789abcdef?s=80&d=identicon"},"assignees":[{"id":8,"username":"bob","name":"Bob","avatar_url":"https://secure.gravatar.com/avatar/fedcba9876543210fedcba9876543210?s=80&d=identicon"},{"id":9,"username":"carol","avatar_url":"https://secure.gravatar.com/avatar/1111222233334444aaaabbbbccccdddd?s=80&d=identicon"}],"created_at":"2026-04-01T10:00:00Z","updated_at":"2026-04-02T10:00:00Z","weight":null,"user_notes_count":3,"upvotes":1,"downvotes":0,"milestone":null,"web_url":"https://example.gitlab/group/project/-/issues/1","priority":"high","_links":{"self":"https://example.gitlab/api/v4/projects/42/issues/1","notes":"https://example.gitlab/api/v4/projects/42/issues/1/notes","award_emoji":"https://example.gitlab/api/v4/projects/42/issues/1/award_emoji"}},{"id":101,"iid":2,"project_id":42,"title":"Second","description":"desc-2","description_html":"'"$NOISE"'","state":"opened","labels":[],"author":{"id":7,"username":"alice","name":"Alice","email":"alice@example.com","avatar_url":"https://secure.gravatar.com/avatar/0123456789abcdef0123456789abcdef?s=80&d=identicon"},"assignees":[],"created_at":"2026-04-03T10:00:00Z","updated_at":"2026-04-04T10:00:00Z","weight":null,"user_notes_count":0,"upvotes":0,"downvotes":0,"milestone":null,"web_url":"https://example.gitlab/group/project/-/issues/2","priority":null,"_links":{"self":"https://example.gitlab/api/v4/projects/42/issues/2","notes":"https://example.gitlab/api/v4/projects/42/issues/2/notes","award_emoji":"https://example.gitlab/api/v4/projects/42/issues/2/award_emoji"}}]'

FIXTURE_MRS='[{"id":500,"iid":10,"project_id":42,"title":"MR-1","description":"mr-desc","description_html":"'"$NOISE"'","state":"opened","labels":["feature"],"source_branch":"feat/x","target_branch":"main","draft":false,"author":{"id":7,"username":"alice","name":"Alice","avatar_url":"https://secure.gravatar.com/avatar/0123456789abcdef0123456789abcdef?s=80&d=identicon"},"assignee":null,"merge_status":"can_be_merged","merged_at":null,"changes_count":"5","user_notes_count":2,"web_url":"https://example.gitlab/group/project/-/merge_requests/10","pipeline":{"id":999,"status":"success","web_url":"https://example.gitlab/group/project/-/pipelines/999","ref":"feat/x","sha":"abcdef1234567890abcdef1234567890abcdef12"},"head_pipeline":{"id":999,"status":"success","web_url":"https://example.gitlab/group/project/-/pipelines/999","ref":"feat/x","sha":"abcdef1234567890abcdef1234567890abcdef12"},"milestone":null,"time_stats":{"time_estimate":0,"total_time_spent":0,"human_time_estimate":null,"human_total_time_spent":null}},{"id":501,"iid":11,"project_id":42,"title":"MR-2","description":"mr-desc-2","description_html":"'"$NOISE"'","state":"merged","labels":["fix","release-note"],"source_branch":"fix/y","target_branch":"main","draft":true,"author":{"id":7,"username":"alice","name":"Alice","avatar_url":"https://secure.gravatar.com/avatar/0123456789abcdef0123456789abcdef?s=80&d=identicon"},"assignee":null,"merge_status":"merged","merged_at":"2026-04-05T12:00:00Z","changes_count":"2","user_notes_count":0,"web_url":"https://example.gitlab/group/project/-/merge_requests/11","pipeline":{"id":1000,"status":"success","web_url":"https://example.gitlab/group/project/-/pipelines/1000","ref":"fix/y","sha":"ffffff1234567890abcdef1234567890abcdef12"},"head_pipeline":{"id":1000,"status":"success","web_url":"https://example.gitlab/group/project/-/pipelines/1000","ref":"fix/y","sha":"ffffff1234567890abcdef1234567890abcdef12"},"milestone":null,"time_stats":{"time_estimate":0,"total_time_spent":0,"human_time_estimate":null,"human_total_time_spent":null}}]'

FIXTURE_MEMBERS='[{"id":7,"username":"alice","name":"Alice","state":"active","avatar_url":"https://secure.gravatar.com/avatar/0123456789abcdef0123456789abcdef?s=80&d=identicon","web_url":"https://example.gitlab/alice","access_level":50,"expires_at":null,"email":"alice@example.com","created_at":"2024-01-01T00:00:00Z","created_by":{"id":1,"username":"root","name":"Administrator"}},{"id":8,"username":"bob","name":"Bob","state":"active","avatar_url":"https://secure.gravatar.com/avatar/fedcba9876543210fedcba9876543210?s=80&d=identicon","web_url":"https://example.gitlab/bob","access_level":30,"expires_at":null,"email":"bob@example.com","created_at":"2024-02-01T00:00:00Z","created_by":{"id":1,"username":"root","name":"Administrator"}}]'

FIXTURE_LABELS='[{"id":1,"name":"bug","description":"Something is broken","description_html":"'"$NOISE"'","text_color":"#ffffff","color":"#ff0000","subscribed":false,"priority":null,"is_project_label":true,"open_issues_count":12,"closed_issues_count":40,"open_merge_requests_count":3},{"id":2,"name":"feature","description":"New functionality","description_html":"'"$NOISE"'","text_color":"#000000","color":"#00ff00","subscribed":false,"priority":null,"is_project_label":true,"open_issues_count":5,"closed_issues_count":20,"open_merge_requests_count":2}]'

FIXTURE_RELEASES='[{"tag_name":"v1.2.3","name":"Release 1.2.3","description":"- fix: a bug\n- feat: a thing","description_html":"'"$NOISE"'","created_at":"2026-03-01T10:00:00Z","released_at":"2026-03-01T12:00:00Z","author":{"id":7,"username":"alice","avatar_url":"https://secure.gravatar.com/avatar/0123456789abcdef0123456789abcdef?s=80&d=identicon","web_url":"https://example.gitlab/alice"},"commit":{"id":"abc123def456abc123def456abc123def456abcd","short_id":"abc123d","title":"Release 1.2.3","parent_ids":["parent1","parent2"],"created_at":"2026-03-01T10:00:00Z","author_name":"Alice","author_email":"alice@example.com","authored_date":"2026-03-01T10:00:00Z","committer_name":"Alice","committer_email":"alice@example.com","committed_date":"2026-03-01T10:00:00Z"},"assets":{"count":0,"sources":[],"links":[]},"evidences":[{"sha":"abcdef1234567890abcdef1234567890abcdef12","filepath":"https://example.gitlab/group/project/-/releases/v1.2.3/evidences/1.json","collected_at":"2026-03-01T12:00:00Z"}]},{"tag_name":"v1.2.2","name":"Release 1.2.2","description":"- fix: something","description_html":"'"$NOISE"'","created_at":"2026-02-15T10:00:00Z","released_at":"2026-02-15T12:00:00Z","author":{"id":7,"username":"alice","avatar_url":"https://secure.gravatar.com/avatar/0123456789abcdef0123456789abcdef?s=80&d=identicon","web_url":"https://example.gitlab/alice"},"commit":{"id":"fff111aaa222fff111aaa222fff111aaa222fff1","short_id":"fff111a","title":"Release 1.2.2","parent_ids":["parent3","parent4"],"created_at":"2026-02-15T10:00:00Z","author_name":"Alice","author_email":"alice@example.com","authored_date":"2026-02-15T10:00:00Z","committer_name":"Alice","committer_email":"alice@example.com","committed_date":"2026-02-15T10:00:00Z"},"assets":{"count":0,"sources":[],"links":[]},"evidences":[{"sha":"1234567890abcdef1234567890abcdef12345678","filepath":"https://example.gitlab/group/project/-/releases/v1.2.2/evidences/1.json","collected_at":"2026-02-15T12:00:00Z"}]}]'

FIXTURE_TAGS='[{"name":"v1.2.3","message":"Release 1.2.3","target":"abc123def456abc123def456abc123def456abcd","commit":{"id":"abc123def456abc123def456abc123def456abcd","short_id":"abc123d","created_at":"2026-03-01T10:00:00Z","parent_ids":["ppp1ppp1ppp1ppp1ppp1ppp1ppp1ppp1ppp1ppp1"],"title":"chore: bump","message":"chore: bump to 1.2.3","author_name":"Alice","author_email":"alice@example.com","authored_date":"2026-03-01T10:00:00Z","committer_name":"Alice","committer_email":"alice@example.com","committed_date":"2026-03-01T10:00:00Z","web_url":"https://example.gitlab/group/project/-/commit/abc123def456abc123def456abc123def456abcd"},"release":null,"protected":false},{"name":"v1.2.2","message":"","target":"fff111aaa222fff111aaa222fff111aaa222fff1","commit":{"id":"fff111aaa222fff111aaa222fff111aaa222fff1","short_id":"fff111a","created_at":"2026-02-15T10:00:00Z","parent_ids":["ppp2ppp2ppp2ppp2ppp2ppp2ppp2ppp2ppp2ppp2"],"title":"chore: bump","message":"chore: bump to 1.2.2","author_name":"Alice","author_email":"alice@example.com","authored_date":"2026-02-15T10:00:00Z","committer_name":"Alice","committer_email":"alice@example.com","committed_date":"2026-02-15T10:00:00Z","web_url":"https://example.gitlab/group/project/-/commit/fff111aaa222fff111aaa222fff111aaa222fff1"},"release":null,"protected":false}]'

FIXTURE_PIPELINES='[{"id":9001,"project_id":42,"status":"success","ref":"main","sha":"abc123def456abc123def456abc123def456abcd","created_at":"2026-04-06T10:00:00Z","updated_at":"2026-04-06T10:15:00Z","web_url":"https://example.gitlab/group/project/-/pipelines/9001","iid":"9001","name":"main","source":"push","before_sha":"parent1parent1parent1parent1parent1parent","tag":false,"yaml_errors":null,"user":{"id":7,"username":"alice","avatar_url":"https://secure.gravatar.com/avatar/0123456789abcdef0123456789abcdef?s=80&d=identicon","web_url":"https://example.gitlab/alice"},"detailed_status":{"icon":"status_success","text":"passed","label":"passed","group":"success","tooltip":"passed","has_details":true,"details_path":"https://example.gitlab/group/project/-/pipelines/9001","favicon":"favicon.png"}},{"id":9000,"project_id":42,"status":"failed","ref":"main","sha":"123456abcdef123456abcdef123456abcdef1234","created_at":"2026-04-05T10:00:00Z","updated_at":"2026-04-05T10:15:00Z","web_url":"https://example.gitlab/group/project/-/pipelines/9000","iid":"9000","name":"main","source":"push","before_sha":"parent2parent2parent2parent2parent2parent","tag":false,"yaml_errors":null,"user":{"id":7,"username":"alice","avatar_url":"https://secure.gravatar.com/avatar/0123456789abcdef0123456789abcdef?s=80&d=identicon","web_url":"https://example.gitlab/alice"},"detailed_status":{"icon":"status_failed","text":"failed","label":"failed","group":"failed","tooltip":"failed","has_details":true,"details_path":"https://example.gitlab/group/project/-/pipelines/9000","favicon":"favicon.png"}}]'

# Build the sourceable "prelude" for a script. Every gitlab-api.sh ends its
# function block with `CMD=...` and then the big CLI case. We stop at that
# CMD= line so we get just the function defs — no env check explosions, no
# command dispatch, no curl calls. Temp prelude file gets cleaned up in main.
build_prelude() {
    local script="$1"
    local out="$2"
    awk '/^CMD=/{exit} {print}' "$script" > "$out"
}

# run_view <script-path> <internal-view-name> <fixture-json>
# Streams the fixture through project_json and prints the projection.
# Uses dummy GITLAB_URL/TOKEN/PROJECT so the env check passes. Echoes via
# printf to avoid echo's platform quirks (Linux-bash prints -e as literal).
run_view() {
    local script="$1" view="$2" fixture="$3"
    local prelude
    prelude=$(mktemp)
    build_prelude "$script" "$prelude"
    # shellcheck disable=SC1090
    GITLAB_URL=http://x GITLAB_TOKEN=y GITLAB_PROJECT=z bash -c '
        source "$1"
        printf "%s" "$2" | project_json "$3"
    ' _ "$prelude" "$fixture" "$view"
    local rc=$?
    rm -f "$prelude"
    return $rc
}

# check_is_json <json-text> <label>
check_is_json() {
    local text="$1" label="$2"
    if printf '%s' "$text" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
        pass "$label: output is valid JSON"
    else
        fail "$label: output is NOT valid JSON"
    fi
}

# check_keys <json-text> <expected-csv> <label>
# Asserts every array element has EXACTLY the expected set of top-level keys.
# Extras (or missing required keys) fail. Uses python3 symmetric difference.
# DATA travels via env var because the heredoc is already tying up python's
# stdin — same pattern as project_json inside the gitlab-api.sh scripts.
check_keys() {
    local text="$1" expected="$2" label="$3"
    local result
    result=$(DATA="$text" EXPECTED="$expected" python3 <<'PY'
import os, json
try:
    data = json.loads(os.environ["DATA"])
except Exception as e:
    print("PARSE_ERR:" + str(e))
    raise SystemExit(0)
expected = set(x.strip() for x in os.environ["EXPECTED"].split(",") if x.strip())
if not isinstance(data, list):
    print("NOT_LIST")
    raise SystemExit(0)
if not data:
    print("EMPTY")
    raise SystemExit(0)
for i, elem in enumerate(data):
    if not isinstance(elem, dict):
        print("NOT_DICT:" + str(i))
        raise SystemExit(0)
    got = set(elem.keys())
    extra = got - expected
    missing = expected - got
    if extra or missing:
        print("KEYS_MISMATCH:" + str(i) + " extra=" + ",".join(sorted(extra)) + " missing=" + ",".join(sorted(missing)))
        raise SystemExit(0)
print("OK")
PY
)
    if [ "$result" = "OK" ]; then
        pass "$label: top-level keys match {$expected}"
    else
        fail "$label: key check failed: $result"
    fi
}

# check_size <input-text> <output-text> <label>
# Requires output <= 30% of input. We're aiming for ~10x shrinkage in
# realistic payloads; 30% is a loose bar so small fixtures with limited
# field-count-to-value-size ratios don't falsely trip the test.
check_size() {
    local input="$1" output="$2" label="$3"
    local in_size out_size
    in_size=${#input}
    out_size=${#output}
    local threshold=$(( in_size * 30 / 100 ))
    if [ "$out_size" -le "$threshold" ]; then
        pass "$label: size $out_size <= 30% of $in_size (threshold $threshold)"
    else
        fail "$label: size $out_size > 30% of $in_size (threshold $threshold)"
    fi
}

# Runs the full test triplet (valid-json + keys + size) for one view.
#
# Args: colony_label internal_view_name expected_csv fixture
# Resolves script path from colony_label -> dev-apprenticeship/<label>/...
test_view() {
    local colony="$1" view="$2" keys="$3" fixture="$4"
    local label="$colony/$view"
    local script="$REPO_ROOT/dev-apprenticeship/$colony/scripts/gitlab-api.sh"
    if [ ! -f "$script" ]; then
        fail "$label: script not found at $script"
        return
    fi
    local out
    out=$(run_view "$script" "$view" "$fixture")
    check_is_json "$out" "$label"
    check_keys "$out" "$keys" "$label"
    check_size "$fixture" "$out" "$label"
}

# --- Triage ---
test_view "triage" "labeler"        "iid,title,labels"                                  "$FIXTURE_ISSUES"
test_view "triage" "router"         "iid,title,labels,assignees"                        "$FIXTURE_ISSUES"
test_view "triage" "prioritizer"    "iid,title,labels"                                  "$FIXTURE_ISSUES"
test_view "triage" "issue_creator"  "iid,title,description,labels,author"               "$FIXTURE_ISSUES"
test_view "triage" "members-summary" "id,username,name"                                  "$FIXTURE_MEMBERS"
test_view "triage" "labels-summary"  "name,description,color"                            "$FIXTURE_LABELS"

# --- Code-review ---
test_view "code-review" "reviewer" "iid,state,title,labels,source_branch,target_branch,draft" "$FIXTURE_MRS"

# --- Planning ---
test_view "planning" "planning"    "iid,title,description,labels,author,created_at"                    "$FIXTURE_ISSUES"
test_view "planning" "planning-mr" "iid,title,description,labels,changes_count,user_notes_count,merged_at,target_branch" "$FIXTURE_MRS"

# --- Implementation ---
test_view "implementation" "impl"     "iid,title,merged_at,target_branch"                      "$FIXTURE_MRS"
test_view "implementation" "assigned" "iid,title,description,labels,assignees,priority"        "$FIXTURE_ISSUES"

# --- Release ---
test_view "release" "release-summary"  "tag_name,name,released_at,description" "$FIXTURE_RELEASES"
test_view "release" "tag-summary"      "name,message,commit"                   "$FIXTURE_TAGS"
test_view "release" "pipeline-summary" "id,status,ref,sha,created_at,web_url"  "$FIXTURE_PIPELINES"
test_view "release" "release-mr"       "iid,title,description,merged_at,labels,target_branch" "$FIXTURE_MRS"

# --- Rollback / error paths (review #126) ---
# The previous block exercises every declared view. These three extra cases
# lock down the three "escape hatches" around projection so they can't
# regress silently:
#   1. GITLAB_VIEW_MODE=raw env override  -> project_json is a `cat`
#   2. unknown view name                  -> exit 2, no stdout
#   3. explicit `--view raw` argument     -> short-circuit to printf stdin
#
# Any one of these breaking would silently degrade the rollback story:
# operators set GITLAB_VIEW_MODE=raw to undo a bad projection without editing
# .ag sources, and the typo-loud behaviour for unknown views prevents cases
# like `--view labler` silently matching a `*)` wildcard.

# check_equals <expected> <actual> <label>
check_equals() {
    local expected="$1" actual="$2" label="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$label: output matches input"
    else
        fail "$label: output does NOT match input"
    fi
}

# run_view_env <env-assignment> <script> <view> <fixture>
# Variant of run_view that injects an extra env var (e.g. GITLAB_VIEW_MODE=raw)
# into the inner shell. Kept small and inline to match the existing style.
run_view_env() {
    local env_kv="$1" script="$2" view="$3" fixture="$4"
    local prelude
    prelude=$(mktemp)
    build_prelude "$script" "$prelude"
    # $1/$2/$3 below are deliberately inner-shell positional args
    # (bash -c's own argv), not outer-scope variables — same pattern as
    # run_view above.
    # shellcheck disable=SC1090,SC2016
    env "$env_kv" GITLAB_URL=http://x GITLAB_TOKEN=y GITLAB_PROJECT=z bash -c '
        source "$1"
        printf "%s" "$2" | project_json "$3"
    ' _ "$prelude" "$fixture" "$view"
    local rc=$?
    rm -f "$prelude"
    return $rc
}

# Case 1: GITLAB_VIEW_MODE=raw short-circuits even on a normally-valid view.
# Triage's `labeler` exists; with the env override set, project_json must
# return the input byte-for-byte (cat path).
RAW_OUT=$(run_view_env "GITLAB_VIEW_MODE=raw" \
    "$REPO_ROOT/dev-apprenticeship/triage/scripts/gitlab-api.sh" \
    "labeler" "$FIXTURE_ISSUES")
check_equals "$FIXTURE_ISSUES" "$RAW_OUT" "triage/labeler (GITLAB_VIEW_MODE=raw)"

# Case 2: unknown view must exit 2 and not produce a bogus projection.
# We call project_json directly via the prelude-bash wrapper and capture rc.
PRELUDE=$(mktemp)
build_prelude "$REPO_ROOT/dev-apprenticeship/triage/scripts/gitlab-api.sh" "$PRELUDE"
# shellcheck disable=SC1090,SC2016
# SC2016: $1/$2/$3 below are the inner bash -c's positional args.
UNKNOWN_OUT=$(GITLAB_URL=http://x GITLAB_TOKEN=y GITLAB_PROJECT=z bash -c '
    source "$1"
    printf "%s" "$2" | project_json "$3"
' _ "$PRELUDE" "$FIXTURE_ISSUES" "definitely-not-a-view" 2>/dev/null)
UNKNOWN_RC=$?
rm -f "$PRELUDE"
if [ "$UNKNOWN_RC" -eq 2 ] && [ -z "$UNKNOWN_OUT" ]; then
    pass "triage: unknown view exits 2 with empty stdout"
else
    fail "triage: unknown view: rc=$UNKNOWN_RC, stdout='$UNKNOWN_OUT' (want rc=2, empty stdout)"
fi

# Case 3: explicit `--view raw` arg is a pass-through (no env override set).
# Same byte-for-byte equality as case 1, but driven by the `raw) printf...`
# case arm instead of the GITLAB_VIEW_MODE short-circuit.
RAW_ARG_OUT=$(run_view \
    "$REPO_ROOT/dev-apprenticeship/triage/scripts/gitlab-api.sh" \
    "raw" "$FIXTURE_ISSUES")
check_equals "$FIXTURE_ISSUES" "$RAW_ARG_OUT" "triage: --view raw pass-through"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
