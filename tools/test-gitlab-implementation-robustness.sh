#!/usr/bin/env bash
# test-gitlab-implementation-robustness.sh: command-dispatcher robustness tests
# for dev-apprenticeship/implementation/scripts/gitlab-api.sh, covering the
# GitLab-adapter ports of two GitHub fixes (#1149/#1150) raised against the
# #1117 first federation run:
#
#   #1169  commit-files --actions must tolerate raw control characters inside
#          file `content` (LLM output routinely carries literal newlines/tabs).
#          json.loads(ACTIONS) now passes strict=False; a strict parse rejects
#          such payloads with "Invalid control character". Mirrors github #1149.
#
#   #1170  create-branch must be idempotent: when the create POST fails with an
#          error containing "Branch already exists" (a retry after a prior failed
#          commit), the branch being present is the desired end state, so the
#          wrapper GETs the existing branch and emits it as success (exit 0). Any
#          OTHER failure must still propagate. Mirrors github #1150.
#
# Like test-github-implementation-robustness.sh, this drives the full CMD
# dispatcher against a STUBBED curl placed on PATH — the same stub-curl idiom as
# test-rate-limit-backoff.sh. The stub dispatches on "<method> <url-suffix>" read
# from a per-request routing table, writes the body to the curl -o file, and
# prints the HTTP status code on stdout (mirroring real gl_call -w/-o behaviour).
#
# Usage: ./tools/test-gitlab-implementation-robustness.sh
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$REPO_ROOT/dev-apprenticeship/implementation/scripts/gitlab-api.sh"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

FAKE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FAKE_ROOT"' EXIT

# ---- Stub curl ---------------------------------------------------------------
# The stub maps "<METHOD> <url-suffix>" to a status code + body file. The
# routing table lives in $STUB_DIR/routes (one "METHOD<TAB>suffix<TAB>code<TAB>bodyfile"
# per line); the stub matches by METHOD plus a URL suffix substring. The real
# gl_call passes "-o <body>", "-X <method>", and the URL as the final argv.
FAKE_BIN="$FAKE_ROOT/bin"
STUB_DIR="$FAKE_ROOT/stub"
mkdir -p "$FAKE_BIN" "$STUB_DIR"
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
out=""
method="GET"
url=""
prev=""
for a in "$@"; do
    case "$prev" in
        -o) out="$a" ;;
        -X) method="$a" ;;
    esac
    case "$a" in
        http://*|https://*) url="$a" ;;
    esac
    prev="$a"
done
routes="$STUB_DIR/routes"
code="404"
body=""
if [ -f "$routes" ]; then
    while IFS=$'\t' read -r r_method r_suffix r_code r_bodyfile; do
        [ -z "$r_method" ] && continue
        if [ "$r_method" = "$method" ]; then
            case "$url" in
                *"$r_suffix") code="$r_code"; body="$r_bodyfile" ;;
                *"$r_suffix"*) code="$r_code"; body="$r_bodyfile" ;;
            esac
        fi
    done < "$routes"
fi
if [ -n "$out" ]; then
    if [ -n "$body" ] && [ -f "$body" ]; then
        cat "$body" > "$out"
    else
        : > "$out"
    fi
fi
printf '%s' "$code"
exit 0
EOF
chmod +x "$FAKE_BIN/curl"

# add_route <method> <url-suffix> <http-code> <body-string>
ROUTE_SEQ=0
add_route() {
    local method="$1" suffix="$2" code="$3" body="$4"
    ROUTE_SEQ=$((ROUTE_SEQ + 1))
    local bf="$STUB_DIR/body-$ROUTE_SEQ.json"
    printf '%s' "$body" > "$bf"
    printf '%s\t%s\t%s\t%s\n' "$method" "$suffix" "$code" "$bf" >> "$STUB_DIR/routes"
}

reset_routes() {
    : > "$STUB_DIR/routes"
    ROUTE_SEQ=0
}

run_api() {
    PATH="$FAKE_BIN:$PATH" \
    STUB_DIR="$STUB_DIR" \
    GITLAB_URL="https://gitlab.example.com" \
    GITLAB_TOKEN="stub" \
    GITLAB_PROJECT="o%2Fr" \
    GITLAB_CURL_RETRIES=0 \
        bash "$SCRIPT" "$@"
}

# =============================================================================
# #1169: commit-files tolerates raw control chars in --actions content.
# =============================================================================
reset_routes
COMMIT_SHA="1111111111111111111111111111111111111111"
# GitLab's one-shot POST /repository/commits returns the new commit object.
add_route POST "/repository/commits" 201 "{\"id\":\"$COMMIT_SHA\",\"short_id\":\"1111111\",\"title\":\"msg\"}"

# --actions whose `content` carries RAW newlines (literal control chars in the
# JSON string). A strict json.loads would raise "Invalid control character".
ACTIONS_RAW_NL=$(python3 - <<'PY'
import json
# Build the payload, then re-emit with the content's newlines left LITERAL
# (not \n-escaped) so the bytes handed to the wrapper contain raw control chars.
content = "line one\nline two\n\tindented\n"
payload = '[{"action":"create","file_path":"src/foo.py","content":' + json.dumps(content) + '}]'
# json.dumps escaped the newlines; undo that so they are literal control chars.
payload = payload.replace('\\n', '\n').replace('\\t', '\t')
print(payload, end="")
PY
)

CF_ERR_FILE="$FAKE_ROOT/cf-err"
CF_OUT="$(run_api commit-files --branch feat-x --message "msg" --actions "$ACTIONS_RAW_NL" 2>"$CF_ERR_FILE")"
CF_RC=$?
CF_ERR="$(cat "$CF_ERR_FILE")"

case "$CF_ERR" in
    *"Invalid control character"*)
        fail "#1169 commit-files: raw control chars in content rejected ('Invalid control character')" ;;
    *)
        pass "#1169 commit-files: raw control chars in content accepted (no 'Invalid control character')" ;;
esac

if [ "$CF_RC" -eq 0 ]; then
    pass "#1169 commit-files: POST /repository/commits exits 0 with control-char content"
else
    fail "#1169 commit-files: expected exit 0, got $CF_RC (stderr: $CF_ERR)"
fi

case "$CF_OUT" in
    *"$COMMIT_SHA"*)
        pass "#1169 commit-files: commit body echoed on success" ;;
    *)
        fail "#1169 commit-files: expected commit body on stdout, got '$CF_OUT'" ;;
esac

# Strict-parse control: prove the OLD (strict) behaviour WOULD have failed, so
# the test is actually guarding the strict=False change and not a no-op.
STRICT_RC=0
ACTIONS="$ACTIONS_RAW_NL" python3 -c 'import os,json; json.loads(os.environ["ACTIONS"])' 2>/dev/null || STRICT_RC=$?
if [ "$STRICT_RC" -ne 0 ]; then
    pass "#1169 control: strict json.loads rejects this payload (strict=False is load-bearing)"
else
    fail "#1169 control: strict json.loads unexpectedly accepted raw control chars"
fi

# =============================================================================
# #1170: create-branch is idempotent on a "Branch already exists" error.
# =============================================================================
reset_routes
BASE_SHA="abcdef0000000000000000000000000000000000"
EXISTING_BRANCH_BODY="{\"name\":\"feat-y\",\"commit\":{\"id\":\"$BASE_SHA\"}}"
# Create POST answers 400 with the GitLab "Branch already exists" message.
add_route POST "/repository/branches"        400 "{\"message\":\"Branch already exists\"}"
# Idempotent fallback: GET the existing branch (URL-encoded name).
add_route GET  "/repository/branches/feat-y" 200 "$EXISTING_BRANCH_BODY"

CB_ERR_FILE="$FAKE_ROOT/cb-err"
CB_OUT="$(run_api create-branch --name feat-y --ref main 2>"$CB_ERR_FILE")"
CB_RC=$?
CB_ERR="$(cat "$CB_ERR_FILE")"

if [ "$CB_RC" -eq 0 ]; then
    pass "#1170 create-branch: 'Branch already exists' treated as success (exit 0)"
else
    fail "#1170 create-branch: expected exit 0 on already-existing branch, got $CB_RC (stderr: $CB_ERR)"
fi

case "$CB_OUT" in
    *"feat-y"*)
        pass "#1170 create-branch: emits the existing branch body (create-shaped payload)" ;;
    *)
        fail "#1170 create-branch: expected existing branch on stdout, got '$CB_OUT'" ;;
esac

# Negative path: a DIFFERENT failure (not 'already exists') must still propagate
# as a failure — the idempotency shim must not mask real errors.
reset_routes
add_route POST "/repository/branches" 400 "{\"message\":\"Invalid reference name 'bogus'\"}"

CB2_ERR_FILE="$FAKE_ROOT/cb2-err"
run_api create-branch --name feat-z --ref bogus >/dev/null 2>"$CB2_ERR_FILE"
CB2_RC=$?
CB2_ERR="$(cat "$CB2_ERR_FILE")"

if [ "$CB2_RC" -ne 0 ]; then
    pass "#1170 create-branch: non-'already exists' failure still propagates (rc=$CB2_RC)"
else
    fail "#1170 create-branch: unrelated failure was masked as success (should propagate)"
fi

case "$CB2_ERR" in
    *"Invalid reference name"*|*"client error"*)
        pass "#1170 create-branch: real-error stderr re-surfaced on the non-idempotent path" ;;
    *)
        fail "#1170 create-branch: expected the original error on stderr, got '$CB2_ERR'" ;;
esac

# Happy path: a clean create (201) is unaffected by the idempotency shim.
reset_routes
add_route POST "/repository/branches" 201 "{\"name\":\"feat-new\",\"commit\":{\"id\":\"$BASE_SHA\"}}"

CB3_OUT="$(run_api create-branch --name feat-new --ref main 2>/dev/null)"
CB3_RC=$?
if [ "$CB3_RC" -eq 0 ]; then
    case "$CB3_OUT" in
        *"feat-new"*)
            pass "#1170 create-branch: clean 201 create still emits the created branch (exit 0)" ;;
        *)
            fail "#1170 create-branch: clean create lost its body, got '$CB3_OUT'" ;;
    esac
else
    fail "#1170 create-branch: clean 201 create regressed to exit $CB3_RC"
fi

# =============================================================================
# #1360: mr-notes verb — exists, returns the raw GitLab notes shape, exit 2 on
# a non-numeric number. The review-resolver in code_writer polls this durable
# notes endpoint; the raw shape carries id, body, author.username, created_at,
# and the `system` boolean the scanner filters on.
# =============================================================================
reset_routes
NOTES_BODY='[{"id":101,"body":"**Review Summary** (automated)","author":{"username":"reviewbot"},"created_at":"2026-04-10T10:00:00Z","system":false},{"id":99,"body":"label added","author":{"username":"reviewbot"},"created_at":"2026-04-10T09:00:00Z","system":true}]'
add_route GET "/merge_requests/5/notes" 200 "$NOTES_BODY"

MN_ERR_FILE="$FAKE_ROOT/mn-err"
MN_OUT="$(run_api mr-notes 5 2>"$MN_ERR_FILE")"
MN_RC=$?

if [ "$MN_RC" -eq 0 ]; then
    pass "#1360 mr-notes: GET /merge_requests/{iid}/notes exits 0"
else
    fail "#1360 mr-notes: expected exit 0, got $MN_RC (stderr: $(cat "$MN_ERR_FILE"))"
fi

MN_SHAPE="$(MN="$MN_OUT" python3 -c '
import os, json
d = json.loads(os.environ["MN"])
n = d[0]
ok = (n["id"] == 101 and n["author"]["username"] == "reviewbot"
      and n["created_at"] == "2026-04-10T10:00:00Z" and n["system"] is False
      and isinstance(n["body"], str) and d[1]["system"] is True)
print("ok" if ok else "bad")
' 2>/dev/null)"
if [ "$MN_SHAPE" = "ok" ]; then
    pass "#1360 mr-notes: raw GitLab notes shape (id, body, author.username, created_at, system) round-trips"
else
    fail "#1360 mr-notes: notes shape mismatch, got '$MN_OUT'"
fi

# Non-numeric iid is rejected with exit 2 BEFORE any network call.
reset_routes
MN2_RC=0
run_api mr-notes not-a-number >/dev/null 2>&1 || MN2_RC=$?
if [ "$MN2_RC" -eq 2 ]; then
    pass "#1360 mr-notes: non-numeric iid exits 2"
else
    fail "#1360 mr-notes: expected exit 2 on non-numeric iid, got $MN2_RC"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
