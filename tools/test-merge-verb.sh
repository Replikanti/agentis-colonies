#!/usr/bin/env bash
# test-merge-verb.sh: gate tests for the `merge` verb in the code-review
# colony's github-api.sh (#1317).
#
# The merge verb is the single SAFETY chokepoint of the autonomous
# auto-merge loop. It MUST refuse any PR that is not cleanly mergeable
# AND all-green on CI, and it MUST fire the squash-merge PUT only when
# both gates pass. This test stubs the GitHub API via a curl shim that
# serves canned JSON keyed on the request URL, then inspects a trace of
# every (METHOD, URL) the wrapper issued to assert whether the merge PUT
# fired.
#
# Cases:
#   (a) mergeable=true + all checks success ⇒ PUT .../merge fires
#   (b) a failing/pending check ⇒ refused (exit 4), NO merge PUT
#   (c) mergeable=false/null ⇒ refused (exit 4), NO merge PUT
#
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/dev-apprenticeship/code-review/scripts/github-api.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -x "$SCRIPT" ]; then
    echo "[FAIL] github-api.sh not found or not executable: $SCRIPT"
    exit 1
fi

TMPDIR_SHIM="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SHIM"' EXIT

# curl shim: serves canned JSON per URL and records a (METHOD URL) trace.
# The scenario JSON files are picked from $SHIM_FIXTURES by a stable name
# derived from the URL path, so each test points $SHIM_FIXTURES at a dir
# carrying the pull / check-runs payloads for that scenario.
cat > "$TMPDIR_SHIM/curl" <<'CURL_SHIM'
#!/usr/bin/env bash
METHOD="GET"
URL=""
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -X) METHOD="$2"; shift 2 ;;
        -d|--data) shift 2 ;;
        -H) shift 2 ;;
        -G) shift ;;
        --data-urlencode) shift 2 ;;
        -sS|-S|-s|-f) shift ;;
        -w|--max-time) shift 2 ;;
        -o) OUT="$2"; shift 2 ;;
        *) URL="$1"; shift ;;
    esac
done

# Record the call so the test can assert which verbs fired.
printf '%s %s\n' "$METHOD" "$URL" >> "$CURL_TRACE"

body=""
code="200"
case "$URL" in
    */pulls/*/merge)
        # The squash-merge PUT. Only reached when both gates pass.
        body='{"merged":true,"message":"Pull Request successfully merged"}'
        ;;
    */pulls/*)
        # Pull metadata: mergeable + head.sha + head.ref.
        body="$(cat "$SHIM_FIXTURES/pull.json")"
        ;;
    */commits/*/check-runs)
        body="$(cat "$SHIM_FIXTURES/checks.json")"
        ;;
    */git/refs/heads/*)
        # Best-effort branch delete after merge.
        code="204"
        body=""
        ;;
    *)
        body='{}'
        ;;
esac

if [ -n "$OUT" ]; then
    printf '%s' "$body" > "$OUT"
fi
# gl_call/gh_call read the HTTP code from `-w "%{http_code}"` on stdout.
printf '%s' "$code"
CURL_SHIM
chmod +x "$TMPDIR_SHIM/curl"

export CURL_TRACE="$TMPDIR_SHIM/trace"

run_merge() {
    # $1 = fixtures dir for this scenario. Resets the trace, runs the verb.
    : > "$CURL_TRACE"
    SHIM_FIXTURES="$1" PATH="$TMPDIR_SHIM:$PATH" \
        GITHUB_URL=https://api.github.test GITHUB_TOKEN=tok \
        GITHUB_OWNER=acme GITHUB_REPO=widget \
        "$SCRIPT" merge 7 2>&1
}

merge_put_fired() {
    grep -q '^PUT .*/pulls/7/merge$' "$CURL_TRACE"
}

# ---- Fixtures for case (a): green + mergeable ----
A_DIR="$TMPDIR_SHIM/a"
mkdir -p "$A_DIR"
printf '%s' '{"mergeable": true, "head": {"sha": "abc123", "ref": "feature/x"}}' > "$A_DIR/pull.json"
printf '%s' '{"check_runs": [{"name": "ci", "status": "completed", "conclusion": "success"}, {"name": "lint", "status": "completed", "conclusion": "skipped"}]}' > "$A_DIR/checks.json"

# ---- Fixtures for case (b): mergeable but a pending check ----
B_DIR="$TMPDIR_SHIM/b"
mkdir -p "$B_DIR"
printf '%s' '{"mergeable": true, "head": {"sha": "def456", "ref": "feature/y"}}' > "$B_DIR/pull.json"
printf '%s' '{"check_runs": [{"name": "ci", "status": "completed", "conclusion": "success"}, {"name": "e2e", "status": "in_progress", "conclusion": null}]}' > "$B_DIR/checks.json"

# ---- Fixtures for case (b2): mergeable but a failing check ----
B2_DIR="$TMPDIR_SHIM/b2"
mkdir -p "$B2_DIR"
printf '%s' '{"mergeable": true, "head": {"sha": "fed654", "ref": "feature/z"}}' > "$B2_DIR/pull.json"
printf '%s' '{"check_runs": [{"name": "ci", "status": "completed", "conclusion": "failure"}]}' > "$B2_DIR/checks.json"

# ---- Fixtures for case (b3): mergeable but NO checks (empty list) ----
B3_DIR="$TMPDIR_SHIM/b3"
mkdir -p "$B3_DIR"
printf '%s' '{"mergeable": true, "head": {"sha": "aaa111", "ref": "feature/w"}}' > "$B3_DIR/pull.json"
printf '%s' '{"check_runs": []}' > "$B3_DIR/checks.json"

# ---- Fixtures for case (c): mergeable=false ----
C_DIR="$TMPDIR_SHIM/c"
mkdir -p "$C_DIR"
printf '%s' '{"mergeable": false, "head": {"sha": "ccc333", "ref": "feature/c"}}' > "$C_DIR/pull.json"
printf '%s' '{"check_runs": [{"name": "ci", "status": "completed", "conclusion": "success"}]}' > "$C_DIR/checks.json"

# ---- Fixtures for case (c2): mergeable=null (GitHub still computing) ----
C2_DIR="$TMPDIR_SHIM/c2"
mkdir -p "$C2_DIR"
printf '%s' '{"mergeable": null, "head": {"sha": "ddd444", "ref": "feature/d"}}' > "$C2_DIR/pull.json"
printf '%s' '{"check_runs": [{"name": "ci", "status": "completed", "conclusion": "success"}]}' > "$C2_DIR/checks.json"

# ===== Case (a): green + mergeable ⇒ merge PUT fires =====
out="$(run_merge "$A_DIR")"
rc=$?
if [ "$rc" -eq 0 ] && merge_put_fired; then
    pass "case (a) mergeable=true + all checks green: PUT /merge fired, exit 0"
else
    fail "case (a)" "rc=$rc fired=$(merge_put_fired && echo yes || echo no) out=$out trace=$(cat "$CURL_TRACE")"
fi

# ===== Case (b): pending check ⇒ refused, NO merge PUT =====
out="$(run_merge "$B_DIR")"
rc=$?
if [ "$rc" -eq 4 ] && ! merge_put_fired; then
    pass "case (b) pending check: refused (exit 4), NO merge PUT"
else
    fail "case (b)" "rc=$rc fired=$(merge_put_fired && echo yes || echo no) out=$out trace=$(cat "$CURL_TRACE")"
fi

# ===== Case (b2): failing check ⇒ refused, NO merge PUT =====
out="$(run_merge "$B2_DIR")"
rc=$?
if [ "$rc" -eq 4 ] && ! merge_put_fired; then
    pass "case (b2) failing check: refused (exit 4), NO merge PUT"
else
    fail "case (b2)" "rc=$rc fired=$(merge_put_fired && echo yes || echo no) out=$out trace=$(cat "$CURL_TRACE")"
fi

# ===== Case (b3): empty check_runs ⇒ refused, NO merge PUT =====
out="$(run_merge "$B3_DIR")"
rc=$?
if [ "$rc" -eq 4 ] && ! merge_put_fired; then
    pass "case (b3) empty check_runs: refused (exit 4), NO merge PUT"
else
    fail "case (b3)" "rc=$rc fired=$(merge_put_fired && echo yes || echo no) out=$out trace=$(cat "$CURL_TRACE")"
fi

# ===== Case (c): mergeable=false ⇒ refused, NO merge PUT =====
out="$(run_merge "$C_DIR")"
rc=$?
if [ "$rc" -eq 4 ] && ! merge_put_fired; then
    pass "case (c) mergeable=false: refused (exit 4), NO merge PUT"
else
    fail "case (c)" "rc=$rc fired=$(merge_put_fired && echo yes || echo no) out=$out trace=$(cat "$CURL_TRACE")"
fi

# ===== Case (c2): mergeable=null ⇒ refused, NO merge PUT =====
out="$(run_merge "$C2_DIR")"
rc=$?
if [ "$rc" -eq 4 ] && ! merge_put_fired; then
    pass "case (c2) mergeable=null: refused (exit 4), NO merge PUT"
else
    fail "case (c2)" "rc=$rc fired=$(merge_put_fired && echo yes || echo no) out=$out trace=$(cat "$CURL_TRACE")"
fi

# ===== Non-numeric PR number ⇒ exit 2 =====
set +e
out="$(SHIM_FIXTURES="$A_DIR" PATH="$TMPDIR_SHIM:$PATH" \
    GITHUB_URL=https://api.github.test GITHUB_TOKEN=tok \
    GITHUB_OWNER=acme GITHUB_REPO=widget \
    "$SCRIPT" merge abc 2>&1)"
rc=$?
set -e 2>/dev/null || true
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi 'numeric'; then
    pass "non-numeric pr number: exit 2 + clear error"
else
    fail "non-numeric pr number" "rc=$rc out=$out"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
