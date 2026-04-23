#!/usr/bin/env bash
# test-gitlab-add-note.sh: smoke test for the add-note back-port in the
# triage colony's gitlab-api.sh (#256 PR 2).
#
# The labeler, prioritizer, and router agents' review-gated branches shell
# out to `gitlab-api.sh add-note <iid> --body ...`. Before PR 2 the triage
# gitlab-api.sh had no add-note arm, and the call silently failed with
# "unknown command: add-note" under .ag try/catch.
#
# This test verifies:
#   - `add-note` is a recognised subcommand
#   - missing --body exits 1 with a clear error
#   - unknown flag exits 2
#   - non-numeric iid exits 2 with a clear error
#   - happy path builds the expected JSON body and hits the expected URL
#     (via a curl shim that echoes its invocation instead of calling out)
#
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/dev-apprenticeship/triage/scripts/gitlab-api.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -x "$SCRIPT" ]; then
    echo "[FAIL] gitlab-api.sh not found or not executable: $SCRIPT"
    exit 1
fi

# --- Test 1: missing --body exits 1 ---
set +e
out=$(GITLAB_URL=http://x GITLAB_TOKEN=y GITLAB_PROJECT=z "$SCRIPT" add-note 42 2>&1)
rc=$?
set -e
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi 'body is required'; then
    pass "missing --body: exit 1 + clear error"
else
    fail "missing --body" "rc=$rc out=$out"
fi

# --- Test 2: unknown flag exits 2 ---
set +e
out=$(GITLAB_URL=http://x GITLAB_TOKEN=y GITLAB_PROJECT=z "$SCRIPT" add-note 42 --body "hi" --bogus value 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi 'unknown flag'; then
    pass "unknown flag: exit 2 + clear error"
else
    fail "unknown flag" "rc=$rc out=$out"
fi

# --- Test 3: non-numeric iid exits 2 ---
set +e
out=$(GITLAB_URL=http://x GITLAB_TOKEN=y GITLAB_PROJECT=z "$SCRIPT" add-note 'abc' --body "hi" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi 'numeric'; then
    pass "non-numeric iid: exit 2 + clear error"
else
    fail "non-numeric iid" "rc=$rc out=$out"
fi

# --- Test 4: happy path builds correct JSON + URL ---
# Shim curl: prints method, URL, and stdin (the JSON body) to stdout, then
# exits 0 with a minimal JSON response so the caller's jq/awk is happy.
TMPDIR_SHIM="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SHIM"' EXIT
cat > "$TMPDIR_SHIM/curl" <<'CURL_SHIM'
#!/usr/bin/env bash
# Parse the last positional arg as the URL, scan for "-X <method>" and
# "-d <body>". Emit a shim trace file the test can inspect.
METHOD=""
BODY=""
URL=""
while [ $# -gt 0 ]; do
    case "$1" in
        -X) METHOD="$2"; shift 2 ;;
        --data|-d) BODY="$2"; shift 2 ;;
        -H) shift 2 ;;
        -sS|-S|-s|-f) shift ;;
        -w|--max-time) shift 2 ;;
        -o)
            # Swallow the output-file arg so we don't write curl's own -w
            # status to the trace. Write nothing to it.
            : > "$2"
            shift 2
            ;;
        *) URL="$1"; shift ;;
    esac
done
printf 'METHOD=%s\nURL=%s\nBODY=%s\n' "$METHOD" "$URL" "$BODY" > "$CURL_TRACE"
# gl_call reads the HTTP code from `-w "%{http_code}"` stdout; emit 200.
printf '200'
CURL_SHIM
chmod +x "$TMPDIR_SHIM/curl"
export CURL_TRACE="$TMPDIR_SHIM/trace"

set +e
out=$(PATH="$TMPDIR_SHIM:$PATH" GITLAB_URL=http://example.gitlab GITLAB_TOKEN=tok GITLAB_PROJECT=42 "$SCRIPT" add-note 7 --body 'hello world' 2>&1)
rc=$?
set -e

if [ "$rc" -eq 0 ] && [ -s "$CURL_TRACE" ]; then
    trace="$(cat "$CURL_TRACE")"
    ok=1
    printf '%s' "$trace" | grep -q '^METHOD=POST$' || ok=0
    printf '%s' "$trace" | grep -q '/projects/42/issues/7/notes' || ok=0
    # JSON body should have {"body": "hello world"}.
    if ! printf '%s' "$trace" | python3 -c '
import sys, json, re
t = sys.stdin.read()
m = re.search(r"^BODY=(.*)$", t, re.M)
assert m, "BODY= line missing in trace"
b = json.loads(m.group(1))
assert b == {"body": "hello world"}, f"unexpected body: {b}"
'; then
        ok=0
    fi
    if [ "$ok" -eq 1 ]; then
        pass "happy path: POST /issues/7/notes with {body:'hello world'}"
    else
        fail "happy path" "trace=$trace out=$out"
    fi
else
    fail "happy path" "rc=$rc out=$out trace_exists=$([ -s "$CURL_TRACE" ] && echo yes || echo no)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
