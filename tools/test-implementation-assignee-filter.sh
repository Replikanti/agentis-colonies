#!/usr/bin/env bash
# test-implementation-assignee-filter.sh: unit-test the #291 --include-unassigned
# flag on the implementation colony's forge wrappers (gitlab-api.sh and
# github-api.sh) via an `assigned-issues` dispatch. The test swaps `curl` in
# $PATH with a shim that inspects the --data-urlencode args actually sent and
# emits a JSON body shaped after what the real forge would return for that
# query.
#
# Contract (both backends):
#   assigned-issues             → 1 issue (labeled+assigned-to-operator only)
#   assigned-issues
#        --include-unassigned   → 2 issues (both labeled, regardless of assignee)
#
# The assignee filter semantics differ between backends but the wrapper
# contract is byte-identical:
#   GitLab: default passes assignee_id=Any, --include-unassigned drops it
#   GitHub: default passes assignee=<GITHUB_ME>, --include-unassigned drops it
#
# Matches the test style of tools/test-rate-limit-status.sh (PATH curl shim,
# bash 3.2, python3 for JSON). Exit 0 all-pass, 1 any-fail.
# Related: #291.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
GITLAB_WRAPPER="$REPO_ROOT/dev-apprenticeship/implementation/scripts/gitlab-api.sh"
GITHUB_WRAPPER="$REPO_ROOT/dev-apprenticeship/implementation/scripts/github-api.sh"
PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# -----------------------------------------------------------------------------
# Curl shim. Inspects the --data-urlencode args actually passed and decides
# whether the wrapper was invoked with or without the assignee filter. Emits
# a different issues-list JSON accordingly.
#
# Two canned fixtures:
#   ASSIGNED_ONLY  — one issue labeled AND assigned (pre-#291 contract)
#   ALL_LABELED    — both labeled issues, one assigned and one unassigned
# -----------------------------------------------------------------------------
SHIM_DIR="$TMPDIR_TEST/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/curl" <<'SHIM'
#!/usr/bin/env bash
# Fake curl for assigned-issues dispatch. Detects whether the caller passed
# any form of assignee filter via --data-urlencode and routes the response
# fixture accordingly.

body_file=""
want_code=0
has_assignee=0

while [ $# -gt 0 ]; do
    case "$1" in
        -o) body_file="$2"; shift 2 ;;
        -w)
            case "$2" in
                *'%{http_code}'*) want_code=1 ;;
            esac
            shift 2
            ;;
        --data-urlencode)
            case "$2" in
                assignee_id=*|assignee=*) has_assignee=1 ;;
            esac
            shift 2
            ;;
        --max-time|-X|-H|-G|-d|-D)
            shift 2
            ;;
        -s|-sS|-S) shift ;;
        *)         shift ;;
    esac
done

# Two-issue fixture: #1 labeled+assigned (alice), #2 labeled+unassigned.
# Byte-compatible with both gitlab-api.sh normalize_issues inputs (no
# transformation on this script; gitlab passes through) and
# github-api.sh normalize_issues inputs (transforms labels + assignees).
ASSIGNED_ONLY_GITLAB='[
  {"iid":1,"title":"Assigned + labeled","description":"desc-1","state":"opened",
   "labels":["implementation"],
   "author":{"username":"alice"},
   "assignees":[{"username":"alice"}],
   "created_at":"2026-04-01T10:00:00Z","updated_at":"2026-04-02T10:00:00Z",
   "user_notes_count":0,"priority":null}
]'

ALL_LABELED_GITLAB='[
  {"iid":1,"title":"Assigned + labeled","description":"desc-1","state":"opened",
   "labels":["implementation"],
   "author":{"username":"alice"},
   "assignees":[{"username":"alice"}],
   "created_at":"2026-04-01T10:00:00Z","updated_at":"2026-04-02T10:00:00Z",
   "user_notes_count":0,"priority":null},
  {"iid":2,"title":"Unassigned + labeled","description":"desc-2","state":"opened",
   "labels":["implementation"],
   "author":{"username":"alice"},
   "assignees":[],
   "created_at":"2026-04-03T10:00:00Z","updated_at":"2026-04-04T10:00:00Z",
   "user_notes_count":0,"priority":null}
]'

# GitHub fixtures use GitHub-native shape (labels as {id,name}, assignees as
# {login}) since github-api.sh runs normalize_issues which remaps.
ASSIGNED_ONLY_GITHUB='[
  {"url":"https://api.github.com/repos/o/r/issues/1","number":1,"title":"Assigned + labeled",
   "body":"desc-1","state":"open","labels":[{"id":1,"name":"implementation"}],
   "user":{"login":"alice","id":7},
   "assignees":[{"login":"alice","id":7}],
   "created_at":"2026-04-01T10:00:00Z","updated_at":"2026-04-02T10:00:00Z","comments":0}
]'

ALL_LABELED_GITHUB='[
  {"url":"https://api.github.com/repos/o/r/issues/1","number":1,"title":"Assigned + labeled",
   "body":"desc-1","state":"open","labels":[{"id":1,"name":"implementation"}],
   "user":{"login":"alice","id":7},
   "assignees":[{"login":"alice","id":7}],
   "created_at":"2026-04-01T10:00:00Z","updated_at":"2026-04-02T10:00:00Z","comments":0},
  {"url":"https://api.github.com/repos/o/r/issues/2","number":2,"title":"Unassigned + labeled",
   "body":"desc-2","state":"open","labels":[{"id":1,"name":"implementation"}],
   "user":{"login":"alice","id":7},
   "assignees":[],
   "created_at":"2026-04-03T10:00:00Z","updated_at":"2026-04-04T10:00:00Z","comments":0}
]'

# Pick fixture set based on which backend the test caller announced via
# CURL_SHIM_BACKEND, then pick the cardinality based on whether the wrapper
# actually issued an assignee filter.
case "${CURL_SHIM_BACKEND:-}" in
    gitlab)
        if [ "$has_assignee" = "1" ]; then
            payload="$ASSIGNED_ONLY_GITLAB"
        else
            payload="$ALL_LABELED_GITLAB"
        fi
        ;;
    github)
        if [ "$has_assignee" = "1" ]; then
            payload="$ASSIGNED_ONLY_GITHUB"
        else
            payload="$ALL_LABELED_GITHUB"
        fi
        ;;
    *)
        echo "curl shim: CURL_SHIM_BACKEND must be gitlab|github" >&2
        exit 99
        ;;
esac

if [ -n "$body_file" ]; then
    printf '%s' "$payload" > "$body_file"
fi
if [ "$want_code" = "1" ]; then
    printf '200'
fi
exit 0
SHIM
chmod +x "$SHIM_DIR/curl"

# -----------------------------------------------------------------------------
# run_wrapper <wrapper> <backend> [extra-flag...]
#
# Dispatches `assigned-issues --view raw` so we get back the full normalized
# issue list (projection `raw` is byte-identical to the unprojected list but
# survives the two-step pipe). The caller passes --include-unassigned (or not)
# as an extra positional.
# -----------------------------------------------------------------------------
run_wrapper() {
    local wrapper="$1" backend="$2"
    shift 2
    PATH="$SHIM_DIR:$PATH" CURL_SHIM_BACKEND="$backend" \
        GITLAB_URL="https://example.invalid" \
        GITLAB_TOKEN="fake-token" \
        GITLAB_PROJECT="org/repo" \
        GITHUB_URL="https://api.github.com" \
        GITHUB_TOKEN="ghp_fake-token" \
        GITHUB_OWNER="org" \
        GITHUB_REPO="repo" \
        GITHUB_ME="alice" \
        IMPLEMENTATION_TRIGGER_LABEL="implementation" \
        GITHUB_CURL_RETRIES="0" \
        GITLAB_CURL_RETRIES="0" \
        GITLAB_CURL_MAX_TIME="5" \
        GITHUB_CURL_MAX_TIME="5" \
        bash "$wrapper" assigned-issues "$@"
}

# count_issues <json> → prints integer length of the JSON array
count_issues() {
    DATA="$1" python3 -c '
import os, json, sys
try:
    d = json.loads(os.environ["DATA"])
except Exception as e:
    print("INVALID_JSON:" + str(e))
    sys.exit(1)
print(len(d) if isinstance(d, list) else -1)
'
}

assert_count() {
    local name="$1" expect="$2" json="$3"
    local got
    got="$(count_issues "$json")"
    if [ "$got" = "$expect" ]; then
        pass "$name"
    else
        fail "$name" "got=$got want=$expect json=$(printf '%.200s' "$json")"
    fi
}

# -----------------------------------------------------------------------------
# Test matrix: two backends × two flag modes.
# -----------------------------------------------------------------------------

# --- GitLab, no flag: wrapper passes assignee_id=Any → shim returns 1 issue.
out="$(run_wrapper "$GITLAB_WRAPPER" gitlab 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
    fail "gitlab: default (no flag) expected rc=0 got rc=$rc" "out=$(printf '%.200s' "$out")"
else
    assert_count "gitlab: default (no flag) returns 1 labeled+assigned issue" "1" "$out"
fi

# --- GitLab, --include-unassigned: wrapper drops the filter → shim returns 2.
out="$(run_wrapper "$GITLAB_WRAPPER" gitlab --include-unassigned 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
    fail "gitlab: --include-unassigned expected rc=0 got rc=$rc" "out=$(printf '%.200s' "$out")"
else
    assert_count "gitlab: --include-unassigned returns 2 labeled issues" "2" "$out"
fi

# --- GitHub, no flag: wrapper passes assignee=<GITHUB_ME> → shim returns 1.
out="$(run_wrapper "$GITHUB_WRAPPER" github 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
    fail "github: default (no flag) expected rc=0 got rc=$rc" "out=$(printf '%.200s' "$out")"
else
    assert_count "github: default (no flag) returns 1 labeled+assigned issue" "1" "$out"
fi

# --- GitHub, --include-unassigned: wrapper drops the filter → shim returns 2.
out="$(run_wrapper "$GITHUB_WRAPPER" github --include-unassigned 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
    fail "github: --include-unassigned expected rc=0 got rc=$rc" "out=$(printf '%.200s' "$out")"
else
    assert_count "github: --include-unassigned returns 2 labeled issues" "2" "$out"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
