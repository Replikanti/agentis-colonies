#!/usr/bin/env bash
# test-planning-update-issue.sh: gate tests for the `update-issue` verb added
# to the planning colony's github-api.sh and gitlab-api.sh (#1362).
#
# The planning->implementation handoff (plan_reviewer's opt-in auto-promotion
# hook) advances an approved-plan issue by adding the implementation trigger
# label and removing the needs-planning label via this verb. The verb MUST:
#   GitHub: issue one DELETE per --remove-labels entry, swallow a 404 (label
#           already absent) silently, and still POST --add-labels alongside.
#   GitLab: PUT a body carrying both add_labels and remove_labels.
#
# Both backends are stubbed via a curl shim that serves canned JSON keyed on
# the request URL and records a (METHOD URL) trace, so the test can assert
# which API calls fired without touching a real forge.
#
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GH_SCRIPT="$REPO_ROOT/dev-apprenticeship/planning/scripts/github-api.sh"
GL_SCRIPT="$REPO_ROOT/dev-apprenticeship/planning/scripts/gitlab-api.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -x "$GH_SCRIPT" ]; then
    echo "[FAIL] planning github-api.sh not found or not executable: $GH_SCRIPT"
    exit 1
fi
if [ ! -x "$GL_SCRIPT" ]; then
    echo "[FAIL] planning gitlab-api.sh not found or not executable: $GL_SCRIPT"
    exit 1
fi

TMPDIR_SHIM="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SHIM"' EXIT

# curl shim: serves canned JSON per URL, records a (METHOD URL) trace, and
# captures any PUT/POST body to $BODY_TRACE. The HTTP code returned for a
# DELETE is taken from $SHIM_DELETE_CODE so a test can simulate a 404
# (label already absent) on the remove-label path.
cat > "$TMPDIR_SHIM/curl" <<'CURL_SHIM'
#!/usr/bin/env bash
METHOD="GET"
URL=""
OUT=""
DATA=""
while [ $# -gt 0 ]; do
    case "$1" in
        -X) METHOD="$2"; shift 2 ;;
        -d|--data) DATA="$2"; shift 2 ;;
        -H) shift 2 ;;
        -G) shift ;;
        --data-urlencode) shift 2 ;;
        -sS|-S|-s|-f) shift ;;
        -w|--max-time) shift 2 ;;
        -o) OUT="$2"; shift 2 ;;
        *) URL="$1"; shift ;;
    esac
done

printf '%s %s\n' "$METHOD" "$URL" >> "$CURL_TRACE"
if [ -n "$DATA" ]; then
    printf '%s\n' "$DATA" >> "$BODY_TRACE"
fi

body=""
code="200"
case "$METHOD $URL" in
    DELETE\ */issues/*/labels/*)
        # Remove-a-single-label. Code is configurable so a test can drive
        # the 404 (already absent) idempotency path.
        code="${SHIM_DELETE_CODE:-200}"
        body='[]'
        ;;
    POST\ */issues/*/labels)
        # Add-labels append.
        body='[{"name":"implementation"}]'
        ;;
    *)
        # Single-issue read / PUT response (GitLab + GitHub final re-read).
        body='{"iid":7,"number":7,"title":"t","labels":[]}'
        ;;
esac

if [ -n "$OUT" ]; then
    printf '%s' "$body" > "$OUT"
fi
printf '%s' "$code"
CURL_SHIM
chmod +x "$TMPDIR_SHIM/curl"

export CURL_TRACE="$TMPDIR_SHIM/trace"
export BODY_TRACE="$TMPDIR_SHIM/body"

run_gh() {
    : > "$CURL_TRACE"
    : > "$BODY_TRACE"
    SHIM_DELETE_CODE="${SHIM_DELETE_CODE:-200}" PATH="$TMPDIR_SHIM:$PATH" \
        GITHUB_URL=https://api.github.test GITHUB_TOKEN=tok \
        GITHUB_OWNER=acme GITHUB_REPO=widget \
        "$GH_SCRIPT" update-issue "$@" 2>&1
}

run_gl() {
    : > "$CURL_TRACE"
    : > "$BODY_TRACE"
    PATH="$TMPDIR_SHIM:$PATH" \
        GITLAB_URL=https://gitlab.test GITLAB_TOKEN=tok GITLAB_PROJECT=acme%2Fwidget \
        "$GL_SCRIPT" update-issue "$@" 2>&1
}

# ===== GitHub: --remove-labels issues a DELETE per label =====
out="$(run_gh 7 --remove-labels needs-planning)"
rc=$?
del_count="$(grep -c '^DELETE .*/issues/7/labels/' "$CURL_TRACE")"
if [ "$rc" -eq 0 ] && [ "$del_count" -eq 1 ]; then
    pass "github: --remove-labels needs-planning issues exactly 1 DELETE"
else
    fail "github single remove" "rc=$rc del_count=$del_count out=$out trace=$(cat "$CURL_TRACE")"
fi

# ===== GitHub: --remove-labels with two labels issues two DELETEs =====
out="$(run_gh 7 --remove-labels needs-planning,stale)"
rc=$?
del_count="$(grep -c '^DELETE .*/issues/7/labels/' "$CURL_TRACE")"
if [ "$rc" -eq 0 ] && [ "$del_count" -eq 2 ]; then
    pass "github: --remove-labels with 2 labels issues 2 DELETEs"
else
    fail "github two removes" "rc=$rc del_count=$del_count out=$out trace=$(cat "$CURL_TRACE")"
fi

# ===== GitHub: a 404 on DELETE (label already absent) is ignored =====
out="$(SHIM_DELETE_CODE=404 run_gh 7 --remove-labels needs-planning)"
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "github: DELETE 404 (label already absent) is a no-op, not an error (exit 0)"
else
    fail "github 404 ignored" "rc=$rc out=$out trace=$(cat "$CURL_TRACE")"
fi

# ===== GitHub: --add-labels still works alongside --remove-labels =====
out="$(run_gh 7 --add-labels implementation --remove-labels needs-planning)"
rc=$?
add_fired="$(grep -c '^POST .*/issues/7/labels$' "$CURL_TRACE")"
del_count="$(grep -c '^DELETE .*/issues/7/labels/' "$CURL_TRACE")"
if [ "$rc" -eq 0 ] && [ "$add_fired" -eq 1 ] && [ "$del_count" -eq 1 ]; then
    pass "github: --add-labels + --remove-labels in one call fires both POST and DELETE"
else
    fail "github add+remove" "rc=$rc add=$add_fired del=$del_count out=$out trace=$(cat "$CURL_TRACE")"
fi

# ===== GitHub: no modifying flags ⇒ exit 1 =====
set +e
out="$(run_gh 7)"
rc=$?
set -e 2>/dev/null || true
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi 'at least one of'; then
    pass "github: update-issue with no flags exits 1 + clear error"
else
    fail "github no-flags" "rc=$rc out=$out"
fi

# ===== GitLab: remove_labels appears in the PUT body =====
out="$(run_gl 7 --remove-labels needs-planning)"
rc=$?
put_fired="$(grep -c '^PUT ' "$CURL_TRACE")"
has_remove="$(grep -c 'remove_labels' "$BODY_TRACE")"
if [ "$rc" -eq 0 ] && [ "$put_fired" -ge 1 ] && [ "$has_remove" -ge 1 ]; then
    pass "gitlab: --remove-labels PUTs a body carrying remove_labels"
else
    fail "gitlab remove body" "rc=$rc put=$put_fired remove=$has_remove out=$out body=$(cat "$BODY_TRACE")"
fi

# ===== GitLab: --add-labels + --remove-labels both in the PUT body =====
out="$(run_gl 7 --add-labels implementation --remove-labels needs-planning)"
rc=$?
has_add="$(grep -c 'add_labels' "$BODY_TRACE")"
has_remove="$(grep -c 'remove_labels' "$BODY_TRACE")"
if [ "$rc" -eq 0 ] && [ "$has_add" -ge 1 ] && [ "$has_remove" -ge 1 ]; then
    pass "gitlab: --add-labels + --remove-labels PUTs a body carrying both"
else
    fail "gitlab add+remove body" "rc=$rc add=$has_add remove=$has_remove out=$out body=$(cat "$BODY_TRACE")"
fi

# ===== GitLab: no modifying flags ⇒ exit 1 =====
set +e
out="$(run_gl 7)"
rc=$?
set -e 2>/dev/null || true
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi 'at least one of'; then
    pass "gitlab: update-issue with no flags exits 1 + clear error"
else
    fail "gitlab no-flags" "rc=$rc out=$out"
fi

# ===== plan_reviewer.ag promotion-hook source structure (#1362) =====
# The .ag has no unit harness (colony-lint is its syntax/tier gate), so the
# promotion contract is asserted by source-grep: the hook must be opt-in
# (gated on PLAN_AUTO_PROMOTE == "1"), epic-guarded, and only fire on the
# autonomous approve path (i.e. it lives after the successful plan post,
# alongside the rl_clear/posted-marker success block — NOT in the failure
# or non-autonomous branches).
AG="$REPO_ROOT/dev-apprenticeship/planning/agents/plan_reviewer.ag"

if grep -q 'getenv("PLAN_AUTO_PROMOTE")' "$AG"; then
    pass "plan_reviewer.ag: promotion gated on getenv(\"PLAN_AUTO_PROMOTE\")"
else
    fail "plan_reviewer.ag gate" "no getenv(\"PLAN_AUTO_PROMOTE\") found"
fi

if grep -q 'index_of(issue_detail, "\\"" + epic_label + "\\"")' "$AG"; then
    pass "plan_reviewer.ag: epic guard searches raw issue JSON for the quoted epic label"
else
    fail "plan_reviewer.ag epic guard" "no index_of epic_label guard found"
fi

if grep -q 'recall_latest("planning:labels:epic")' "$AG"; then
    pass "plan_reviewer.ag: epic label resolved from planning:labels:epic vocabulary memo"
else
    fail "plan_reviewer.ag epic vocab" "no recall_latest(planning:labels:epic) found"
fi

if grep -q 'forge-api.sh update-issue ' "$AG" \
    && grep -q -- '--remove-labels' "$AG"; then
    pass "plan_reviewer.ag: promotion calls update-issue with --add-labels/--remove-labels"
else
    fail "plan_reviewer.ag promote call" "no update-issue --remove-labels invocation found"
fi

# The promotion hook must sit in the autonomous success block: the
# PLAN_AUTO_PROMOTE gate appears AFTER the autonomous "Posted plan to issue"
# print and BEFORE the failure-branch "else" (the rate-limit/post-failed
# path), proving approve-only firing.
posted_line="$(grep -n 'Posted plan to issue' "$AG" | head -1 | cut -d: -f1)"
gate_line="$(grep -n 'getenv("PLAN_AUTO_PROMOTE")' "$AG" | head -1 | cut -d: -f1)"
postfail_line="$(grep -n 'post-failed' "$AG" | head -1 | cut -d: -f1)"
if [ -n "$posted_line" ] && [ -n "$gate_line" ] && [ -n "$postfail_line" ] \
    && [ "$gate_line" -gt "$posted_line" ] && [ "$gate_line" -lt "$postfail_line" ]; then
    pass "plan_reviewer.ag: promotion hook sits in the autonomous approve (successful-post) block"
else
    fail "plan_reviewer.ag hook placement" "posted=$posted_line gate=$gate_line postfail=$postfail_line"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
