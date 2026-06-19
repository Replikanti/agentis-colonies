#!/usr/bin/env bash
# test-github-implementation-robustness.sh: command-dispatcher robustness tests
# for dev-apprenticeship/implementation/scripts/github-api.sh, covering two
# live-run regressions found during the #1117 first federation run:
#
#   #1149  commit-files --actions must tolerate raw control characters inside
#          file `content` (LLM output routinely carries literal newlines/tabs).
#          Both json.loads(ACTIONS) calls now pass strict=False; a strict parse
#          rejects such payloads with "Invalid control character".
#
#   #1150  create-branch must be idempotent: when the create POST answers HTTP
#          422 "Reference already exists" (a retry after a prior failed commit),
#          the branch being present is the desired end state, so the wrapper
#          GETs the existing ref and emits it as success (exit 0). Any OTHER
#          failure must still propagate.
#
#   #1172  get-file must decode the base64 `.content` of an existing file to
#          stdout, return empty + exit 0 on a 404 (so the caller treats "no
#          existing content" as "new file"), and propagate other HTTP errors.
#          code_writer.ag must fetch existing content (get-file) before the
#          code-gen prompt so an EDIT preserves the file instead of clobbering
#          it (grep-level wiring assertion).
#
# Unlike test-github-implementation-normalize.sh (which sources just the
# function defs and exercises the normalizers), this test drives the full CMD
# dispatcher against a STUBBED curl placed on PATH — the same stub-curl idiom
# as test-rate-limit-backoff.sh. The stub dispatches on "<method> <url-path>"
# read from a per-request script file, writes the body to the curl -o file, and
# prints the HTTP status code on stdout (mirroring real gh_call -w/-o behaviour).
#
# Usage: ./tools/test-github-implementation-robustness.sh
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$REPO_ROOT/dev-apprenticeship/implementation/scripts/github-api.sh"
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
# gh_call passes "-o <body>", "-X <method>", and the URL as the final argv.
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
    GITHUB_URL="https://api.github.com" \
    GITHUB_TOKEN="stub" \
    GITHUB_OWNER="o" \
    GITHUB_REPO="r" \
    GITHUB_CURL_RETRIES=0 \
        bash "$SCRIPT" "$@"
}

# =============================================================================
# #1149: commit-files tolerates raw control chars in --actions content.
# =============================================================================
reset_routes
HEAD_SHA="1111111111111111111111111111111111111111"
TREE_SHA="2222222222222222222222222222222222222222"
NEW_TREE_SHA="3333333333333333333333333333333333333333"
NEW_COMMIT_SHA="4444444444444444444444444444444444444444"
add_route GET   "/git/refs/heads/feat-x"  200 "{\"object\":{\"sha\":\"$HEAD_SHA\"}}"
add_route GET   "/git/commits/$HEAD_SHA"   200 "{\"tree\":{\"sha\":\"$TREE_SHA\"}}"
add_route POST  "/git/trees"               201 "{\"sha\":\"$NEW_TREE_SHA\"}"
add_route POST  "/git/commits"             201 "{\"sha\":\"$NEW_COMMIT_SHA\"}"
add_route PATCH "/git/refs/heads/feat-x"   200 "{\"ref\":\"refs/heads/feat-x\",\"object\":{\"sha\":\"$NEW_COMMIT_SHA\"}}"

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
        fail "#1149 commit-files: raw control chars in content rejected ('Invalid control character')" ;;
    *)
        pass "#1149 commit-files: raw control chars in content accepted (no 'Invalid control character')" ;;
esac

if [ "$CF_RC" -eq 0 ]; then
    pass "#1149 commit-files: full Git-DB chain exits 0 with control-char content"
else
    fail "#1149 commit-files: expected exit 0, got $CF_RC (stderr: $CF_ERR)"
fi

case "$CF_OUT" in
    *"refs/heads/feat-x"*)
        pass "#1149 commit-files: final ref-patch body echoed on success" ;;
    *)
        fail "#1149 commit-files: expected ref body on stdout, got '$CF_OUT'" ;;
esac

# Strict-parse control: prove the OLD (strict) behaviour WOULD have failed, so
# the test is actually guarding the strict=False change and not a no-op.
STRICT_RC=0
ACTIONS="$ACTIONS_RAW_NL" python3 -c 'import os,json; json.loads(os.environ["ACTIONS"])' 2>/dev/null || STRICT_RC=$?
if [ "$STRICT_RC" -ne 0 ]; then
    pass "#1149 control: strict json.loads rejects this payload (strict=False is load-bearing)"
else
    fail "#1149 control: strict json.loads unexpectedly accepted raw control chars"
fi

# =============================================================================
# #1150: create-branch is idempotent on HTTP 422 "Reference already exists".
# =============================================================================
reset_routes
BASE_SHA="abcdef0000000000000000000000000000000000"
EXISTING_REF_BODY="{\"ref\":\"refs/heads/feat-y\",\"object\":{\"sha\":\"$BASE_SHA\",\"type\":\"commit\"}}"
# Step 1: resolve --ref main to its head SHA.
add_route GET  "/git/refs/heads/main"   200 "{\"object\":{\"sha\":\"$BASE_SHA\"}}"
# Step 2: create POST answers 422 (branch already present).
add_route POST "/git/refs"              422 "{\"message\":\"Reference already exists\",\"documentation_url\":\"https://docs.github.com/\"}"
# Idempotent fallback: GET the existing ref.
add_route GET  "/git/refs/heads/feat-y" 200 "$EXISTING_REF_BODY"

CB_ERR_FILE="$FAKE_ROOT/cb-err"
CB_OUT="$(run_api create-branch --name feat-y --ref main 2>"$CB_ERR_FILE")"
CB_RC=$?
CB_ERR="$(cat "$CB_ERR_FILE")"

if [ "$CB_RC" -eq 0 ]; then
    pass "#1150 create-branch: 422 'Reference already exists' treated as success (exit 0)"
else
    fail "#1150 create-branch: expected exit 0 on already-existing ref, got $CB_RC (stderr: $CB_ERR)"
fi

case "$CB_OUT" in
    *"refs/heads/feat-y"*)
        pass "#1150 create-branch: emits the existing ref body (create-shaped payload)" ;;
    *)
        fail "#1150 create-branch: expected existing ref on stdout, got '$CB_OUT'" ;;
esac

# Negative path: a DIFFERENT 422 (not 'already exists') must still propagate as
# a failure — the idempotency shim must not mask real errors.
reset_routes
add_route GET  "/git/refs/heads/main"   200 "{\"object\":{\"sha\":\"$BASE_SHA\"}}"
add_route POST "/git/refs"              422 "{\"message\":\"Validation Failed: sha is not a valid commit\"}"

CB2_ERR_FILE="$FAKE_ROOT/cb2-err"
run_api create-branch --name feat-z --ref main >/dev/null 2>"$CB2_ERR_FILE"
CB2_RC=$?
CB2_ERR="$(cat "$CB2_ERR_FILE")"

if [ "$CB2_RC" -ne 0 ]; then
    pass "#1150 create-branch: non-'already exists' 422 still propagates as failure (rc=$CB2_RC)"
else
    fail "#1150 create-branch: unrelated 422 was masked as success (should propagate)"
fi

case "$CB2_ERR" in
    *"Validation Failed"*|*"client error"*)
        pass "#1150 create-branch: real-error stderr re-surfaced on the non-idempotent path" ;;
    *)
        fail "#1150 create-branch: expected the original error on stderr, got '$CB2_ERR'" ;;
esac

# Happy path: a clean create (201) is unaffected by the idempotency shim.
reset_routes
add_route GET  "/git/refs/heads/main"   200 "{\"object\":{\"sha\":\"$BASE_SHA\"}}"
add_route POST "/git/refs"              201 "{\"ref\":\"refs/heads/feat-new\",\"object\":{\"sha\":\"$BASE_SHA\"}}"

CB3_OUT="$(run_api create-branch --name feat-new --ref main 2>/dev/null)"
CB3_RC=$?
if [ "$CB3_RC" -eq 0 ]; then
    case "$CB3_OUT" in
        *"refs/heads/feat-new"*)
            pass "#1150 create-branch: clean 201 create still emits the created ref (exit 0)" ;;
        *)
            fail "#1150 create-branch: clean create lost its body, got '$CB3_OUT'" ;;
    esac
else
    fail "#1150 create-branch: clean 201 create regressed to exit $CB3_RC"
fi

# =============================================================================
# #1172: get-file decodes base64 content; 404 -> empty + exit 0.
# =============================================================================
reset_routes
# Build a base64-encoded GitHub contents response for an existing file.
GETFILE_BODY=$(python3 - <<'PY'
import json, base64
content = "line one\nline two\n"
b64 = base64.b64encode(content.encode()).decode()
print(json.dumps({"content": b64, "encoding": "base64", "path": "src/foo.py"}), end="")
PY
)
add_route GET "/contents/src/foo.py" 200 "$GETFILE_BODY"

GF_ERR_FILE="$FAKE_ROOT/gf-err"
GF_OUT="$(run_api get-file --path src/foo.py --ref main 2>"$GF_ERR_FILE")"
GF_RC=$?
GF_ERR="$(cat "$GF_ERR_FILE")"

if [ "$GF_RC" -eq 0 ]; then
    pass "#1172 get-file: existing file decodes to exit 0"
else
    fail "#1172 get-file: expected exit 0 on existing file, got $GF_RC (stderr: $GF_ERR)"
fi

case "$GF_OUT" in
    *"line one"*)
        pass "#1172 get-file: base64 .content decoded to raw stdout" ;;
    *)
        fail "#1172 get-file: expected decoded content on stdout, got '$GF_OUT'" ;;
esac

# 404: file does not exist on this ref -> empty output, exit 0.
reset_routes
add_route GET "/contents/src/missing.py" 404 "{\"message\":\"Not Found\"}"

GF2_ERR_FILE="$FAKE_ROOT/gf2-err"
GF2_OUT="$(run_api get-file --path src/missing.py --ref main 2>"$GF2_ERR_FILE")"
GF2_RC=$?
GF2_ERR="$(cat "$GF2_ERR_FILE")"

if [ "$GF2_RC" -eq 0 ]; then
    pass "#1172 get-file: 404 (missing file) treated as success (exit 0)"
else
    fail "#1172 get-file: expected exit 0 on 404, got $GF2_RC (stderr: $GF2_ERR)"
fi

if [ -z "$GF2_OUT" ]; then
    pass "#1172 get-file: 404 (missing file) emits empty stdout (caller -> new file)"
else
    fail "#1172 get-file: expected empty stdout on 404, got '$GF2_OUT'"
fi

# A non-404 HTTP error must still propagate (not be masked as a missing file).
reset_routes
add_route GET "/contents/src/boom.py" 500 "{\"message\":\"server error\"}"

run_api get-file --path src/boom.py --ref main >/dev/null 2>/dev/null
GF3_RC=$?
if [ "$GF3_RC" -ne 0 ]; then
    pass "#1172 get-file: non-404 HTTP error still propagates as failure (rc=$GF3_RC)"
else
    fail "#1172 get-file: a 500 was masked as success (should propagate)"
fi

# Unknown flag -> exit 2 (verb-parser contract parity with the other arms).
reset_routes
run_api get-file --path src/foo.py --bogus x >/dev/null 2>/dev/null
GF4_RC=$?
if [ "$GF4_RC" -eq 2 ]; then
    pass "#1172 get-file: unknown flag exits 2"
else
    fail "#1172 get-file: expected exit 2 on unknown flag, got $GF4_RC"
fi

# =============================================================================
# #1172: code_writer.ag wires get-file into the code-gen context (grep-level).
# =============================================================================
CW_AG="$REPO_ROOT/dev-apprenticeship/implementation/agents/code_writer.ag"
if grep -q "get-file --path" "$CW_AG"; then
    pass "#1172 code_writer.ag: fetches existing content via 'get-file --path' before code-gen"
else
    fail "#1172 code_writer.ag: no 'get-file --path' fetch found before code-gen"
fi

if grep -q "EDIT this" "$CW_AG"; then
    pass "#1172 code_writer.ag: existing-file block instructs the model to EDIT and preserve"
else
    fail "#1172 code_writer.ag: existing-file EDIT instruction missing from code_context"
fi

if grep -q "If an existing file is shown, EDIT it" "$CW_AG"; then
    pass "#1172 code_writer.ag: code-gen prompt updated to EDIT-when-existing"
else
    fail "#1172 code_writer.ag: code-gen prompt not updated for the EDIT path"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
