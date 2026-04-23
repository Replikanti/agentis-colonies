#!/usr/bin/env bash
# test-rate-limit-status.sh: unit-test the `rate-limit-status` subcommand
# shipped across all 10 per-colony forge wrappers in #256 PR 7 (v1.0.0).
#
# Contract: every wrapper's `rate-limit-status` subcommand prints a single
# JSON object of shape
#     {"remaining": <int|null>, "limit": <int|null>, "reset_at": <ISO-8601-Z|null>}
# and exits 0 on transport success. Behavior under transport failure:
#   GitLab: missing/absent RateLimit-* response headers → forward nulls,
#           exit 0 (common case on self-hosted GitLab without rate-limiting)
#   GitHub: /rate_limit failure → propagate the non-zero gh_call exit
#
# The backends are exercised by swapping `curl` in $PATH with a shim that
# writes canned responses. Each wrapper is tested in isolation.
#
# Exit 0 all-pass, 1 any-fail.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
COLONIES="triage planning implementation code-review release"
PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# Pinned reset timestamp: 1735689600 = 2025-01-01T00:00:00Z. Must round-trip
# through the Python `datetime.fromtimestamp(..., tz=UTC).isoformat()`
# call inside both wrapper arms to the exact string below.
EXPECTED_RESET_AT="2025-01-01T00:00:00Z"

# -----------------------------------------------------------------------------
# Shim dir hosting fake `curl`. PATH is prepended for each invocation so the
# real `curl` is never reached. Mode switch via CURL_SHIM_MODE env var:
#   github_ok        — emit GitHub /rate_limit JSON body, HTTP 200
#   gitlab_headers   — emit RateLimit-* headers to -D <file>, no body
#   gitlab_noheaders — emit minimal HTTP status line, no RateLimit-* headers
#   gitlab_fail      — exit 6 (DNS resolution failure) to simulate transport
#                      failure; gitlab-api.sh's arm tolerates this with `|| :`
#   github_fail      — exit 6 for the same reason; github-api.sh's arm must
#                      propagate this (bubble up via `|| exit $?`)
# -----------------------------------------------------------------------------
SHIM_DIR="$TMPDIR_TEST/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/curl" <<'SHIM'
#!/usr/bin/env bash
# Fake curl. Parses -o <body_file>, -D <hdr_file>, -w <fmt> flags, emits
# canned response based on $CURL_SHIM_MODE, returns the rc/http_code the
# wrapper expects.

body_file=""
hdr_file=""
want_code=0

while [ $# -gt 0 ]; do
    case "$1" in
        -o) body_file="$2"; shift 2 ;;
        -D) hdr_file="$2"; shift 2 ;;
        -w)
            case "$2" in
                *'%{http_code}'*) want_code=1 ;;
            esac
            shift 2
            ;;
        --max-time|-X|-H|-G|--data-urlencode|-d)
            shift 2
            ;;
        -s|-sS|-S) shift ;;
        *)         shift ;;
    esac
done

case "${CURL_SHIM_MODE:-}" in
    github_ok)
        if [ -n "$body_file" ]; then
            cat > "$body_file" <<'JSON'
{"resources":{"core":{"limit":5000,"remaining":4321,"reset":1735689600,"used":679},
              "search":{"limit":30,"remaining":30,"reset":1735689600,"used":0}},
 "rate":{"limit":5000,"remaining":4321,"reset":1735689600,"used":679}}
JSON
        fi
        if [ "$want_code" = "1" ]; then
            printf '200'
        fi
        exit 0
        ;;
    github_fail)
        exit 6
        ;;
    gitlab_headers)
        if [ -n "$hdr_file" ]; then
            cat > "$hdr_file" <<'HDR'
HTTP/2 200
Content-Type: application/json
RateLimit-Remaining: 598
RateLimit-Limit: 600
RateLimit-Reset: 1735689600
HDR
        fi
        # Body routed to /dev/null by the wrapper's -o /dev/null arg.
        exit 0
        ;;
    gitlab_noheaders)
        if [ -n "$hdr_file" ]; then
            cat > "$hdr_file" <<'HDR'
HTTP/2 200
Content-Type: application/json
HDR
        fi
        exit 0
        ;;
    gitlab_fail)
        # Simulate transport failure (e.g. DNS). gitlab-api.sh tolerates
        # this with `|| :` and still emits a null-valued JSON object.
        exit 6
        ;;
    *)
        echo "curl shim: unknown CURL_SHIM_MODE=${CURL_SHIM_MODE:-<unset>}" >&2
        exit 99
        ;;
esac
SHIM
chmod +x "$SHIM_DIR/curl"

# Helper: run a wrapper's rate-limit-status subcommand with the shim curl and
# return stdout for JSON assertion.
run_wrapper() {
    local wrapper="$1" mode="$2"
    shift 2
    PATH="$SHIM_DIR:$PATH" CURL_SHIM_MODE="$mode" \
        GITLAB_URL="https://example.invalid" \
        GITLAB_TOKEN="fake-token" \
        GITLAB_PROJECT="org/repo" \
        GITHUB_URL="https://api.github.com" \
        GITHUB_TOKEN="ghp_fake-token" \
        GITHUB_OWNER="org" \
        GITHUB_REPO="repo" \
        GITHUB_CURL_RETRIES="0" \
        GITLAB_CURL_RETRIES="0" \
        GITLAB_CURL_MAX_TIME="5" \
        GITHUB_CURL_MAX_TIME="5" \
        bash "$wrapper" rate-limit-status "$@"
}

# JSON shape assertion via python3. All three keys must be present.
assert_shape() {
    local name="$1" json="$2" expect_remaining="$3" expect_limit="$4" expect_reset="$5"
    local py_out
    py_out="$(printf '%s' "$json" | python3 -c "
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception as e:
    print('INVALID_JSON:' + str(e))
    sys.exit(1)
need = ['remaining', 'limit', 'reset_at']
for k in need:
    if k not in d:
        print('MISSING_KEY:' + k)
        sys.exit(1)
print(json.dumps([d.get('remaining'), d.get('limit'), d.get('reset_at')]))
")"
    case "$py_out" in
        INVALID_JSON:*|MISSING_KEY:*)
            fail "$name" "$py_out on output: $json"
            return 1
            ;;
    esac
    local expected
    expected="$(python3 -c "import json; print(json.dumps([${expect_remaining}, ${expect_limit}, ${expect_reset}]))")"
    if [ "$py_out" = "$expected" ]; then
        pass "$name"
    else
        fail "$name" "got=$py_out want=$expected"
    fi
}

# -----------------------------------------------------------------------------
# Test matrix — all 5 colonies, both backends, 3 modes each.
# -----------------------------------------------------------------------------
for colony in $COLONIES; do
    gitlab_wrapper="$REPO_ROOT/dev-apprenticeship/$colony/scripts/gitlab-api.sh"
    github_wrapper="$REPO_ROOT/dev-apprenticeship/$colony/scripts/github-api.sh"

    # --- GitLab, headers present ---
    out="$(run_wrapper "$gitlab_wrapper" gitlab_headers 2>/dev/null)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$colony/gitlab: headers-present expected rc=0 got rc=$rc" "out=$(printf '%.120s' "$out")"
    else
        assert_shape "$colony/gitlab: rate-limit-status with headers" "$out" \
            "598" "600" "'${EXPECTED_RESET_AT}'"
    fi

    # --- GitLab, no RateLimit-* headers (self-hosted default) ---
    out="$(run_wrapper "$gitlab_wrapper" gitlab_noheaders 2>/dev/null)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$colony/gitlab: no-headers expected rc=0 got rc=$rc" "out=$(printf '%.120s' "$out")"
    else
        assert_shape "$colony/gitlab: rate-limit-status without headers (nulls)" "$out" \
            "None" "None" "None"
    fi

    # --- GitLab, transport failure → arm still emits nulls, exits 0 ---
    out="$(run_wrapper "$gitlab_wrapper" gitlab_fail 2>/dev/null)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$colony/gitlab: transport-failure expected rc=0 got rc=$rc" "out=$(printf '%.120s' "$out")"
    else
        assert_shape "$colony/gitlab: rate-limit-status on transport failure (nulls)" "$out" \
            "None" "None" "None"
    fi

    # --- GitHub, /rate_limit succeeds ---
    out="$(run_wrapper "$github_wrapper" github_ok 2>/dev/null)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$colony/github: /rate_limit expected rc=0 got rc=$rc" "out=$(printf '%.120s' "$out")"
    else
        assert_shape "$colony/github: rate-limit-status parses /rate_limit" "$out" \
            "4321" "5000" "'${EXPECTED_RESET_AT}'"
    fi

    # --- GitHub, transport failure → non-zero rc propagated ---
    out="$(run_wrapper "$github_wrapper" github_fail 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "$colony/github: transport-failure should propagate non-zero rc (got 0)" "out=$(printf '%.120s' "$out")"
    else
        pass "$colony/github: transport failure propagates non-zero exit (rc=$rc)"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
