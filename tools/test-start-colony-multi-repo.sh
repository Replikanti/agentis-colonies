#!/bin/bash
# tools/test-start-colony-multi-repo.sh: unit tests for #316 M2 — start-
# colony.sh per-repo env wiring.
#
# Tests:
#   1. Regression: single-block exports GITHUB_OWNER/REPO/TOKEN/URL/ME, no GITHUB_REPOS_JSON.
#   2. Multi-block (1 entry): GITHUB_REPOS_JSON has 1 entry; back-compat vars carry first-entry values.
#   3. Multi-block (3 entries): GITHUB_REPOS_JSON has 3 entries in source order.
#   4. Multi-block + secret:// URI tokens -> resolved plaintext (skip if no secret-tool).
#   5. Malformed multi-block (missing owner in entry [1]) -> exit non-zero with clear error.
#   6. Env-passthrough: GITHUB_REPOS_JSON in shell env at daemon-launch + .agentis/config glob accepts it.
#
# Standard scaffold: set -eu, mktemp -d isolation, EXIT trap for cleanup.
# Auto-discovered by tools/colony-lint.sh's tools-test loop.
#
# Usage: ./tools/test-start-colony-multi-repo.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
START="$REPO_ROOT/dev-apprenticeship/triage/scripts/start-colony.sh"
INSTALL_SH="$REPO_ROOT/dev-apprenticeship/install.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
# #1008: per-run-unique fake-daemon marker. A fixed `pkill -f` marker reaps a
# concurrent run's fakes (sibling worktrees on one host); appending the PID +
# the unique mktemp basename scopes every pkill to THIS run's processes.
RUN_MARKER="fake-daemon-for-test-316m2-$$-$(basename "$TMPDIR_TEST")"
cleanup() {
    pkill -f "$RUN_MARKER" 2>/dev/null || true
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1${2:+: $2}"; }

# Shim: stub `agentis` so daemon launch dumps env then sleeps. The
# `exec -a "$T316M2_MARKER" sleep 5` form rewrites argv[0] to the per-run
# unique marker (#1008) so the EXIT-trap pkill -f can reap THIS run's stray
# sleeps without hitting a concurrent run's. The marker arrives via env.
SHIM_DIR="$TMPDIR_TEST/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/agentis" <<'SHIM'
#!/bin/bash
[ "${1:-}" = "daemon" ] && [ "${2:-}" = "list" ] && { printf '[]\n'; exit 0; }
[ "${1:-}" = "memo" ] && exit 0
if [ "${1:-}" = "daemon" ]; then
    [ -n "${T316M2_ENV_DUMP:-}" ] && env > "$T316M2_ENV_DUMP"
    exec -a "${T316M2_MARKER:-fake-daemon-for-test-316m2}" sleep 5
fi
exit 0
SHIM
chmod +x "$SHIM_DIR/agentis"

# Per-call wall-clock cap + bounded retry for run_start (#1679). The
# `--restart-agent` path spawns ~25 cold `python3` starts (TOML parsing via
# tools/parse-toml.sh) BEFORE the shimmed daemon launches — idle that preamble
# is ~1.3 s, but its latency scales with host contention and under a busy CI
# host it once blew the old hardcoded `timeout 4`, killing the script (rc=124,
# empty stderr) and flaking the test. A generous 30 s cap (~10-23x idle
# headroom) plus a retry that fires ONLY on the timeout-kill code lets a rare
# transient spike self-heal without masking real failures. Both env-overridable
# for slow runners.
START_TIMEOUT="${START_TIMEOUT:-30}"
START_MAX_ATTEMPTS="${START_MAX_ATTEMPTS:-3}"

# Run the triage start-colony.sh against $1 with `--restart-agent
# issue_creator`, dumping the env that reaches the (shimmed) `agentis
# daemon` invocation to $2. Caps each call at START_TIMEOUT seconds and
# retries ONLY on a timeout-kill (rc=124), up to START_MAX_ATTEMPTS, so a
# contention spike in the ~25-python preamble self-heals; every other exit
# code (test 5's malformed-config exit 1, launch-failure exit 4) returns
# immediately with no behavioural change (#1679).
run_start() {
    local config="$1" envdump="$2" rc=0 attempt=1
    while :; do
        rc=0
        T316M2_ENV_DUMP="$envdump" T316M2_MARKER="$RUN_MARKER" PATH="$SHIM_DIR:$PATH" \
            timeout "$START_TIMEOUT" bash "$START" --restart-agent issue_creator "$config" \
                >"$TMPDIR_TEST/stdout" 2>"$TMPDIR_TEST/stderr" || rc=$?
        pkill -f "$RUN_MARKER" 2>/dev/null || true
        if [ "$rc" -eq 124 ] && [ "$attempt" -lt "$START_MAX_ATTEMPTS" ]; then
            attempt=$((attempt + 1))
            sleep 1
            continue
        fi
        break
    done
    return $rc
}

# Read the first matching `KEY=...` line from an env-dump file.
envdump_get() { grep -E "^${2}=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }

# JSON helpers — invoked from the shell to keep assertions terse.
json_count() { python3 -c 'import json,sys;print(len(json.loads(sys.argv[1])))' "$1"; }
json_get()   { python3 -c 'import json,sys;a=json.loads(sys.argv[1]);print(a[int(sys.argv[2])][sys.argv[3]])' "$1" "$2" "$3"; }

# --- Test 1: single-block regression ---------------------------------
# A pre-#316 single-block colony.toml must keep exporting GITHUB_OWNER /
# GITHUB_REPO / GITHUB_TOKEN / GITHUB_URL / GITHUB_ME exactly as before
# AND must NOT export GITHUB_REPOS_JSON (M3 agents probe its absence to
# stay on the legacy single-repo path).
CFG1="$TMPDIR_TEST/single.toml"
{
    printf '%s\n' '[forge]'
    printf '%s\n' 'type = "github"'
    printf '%s\n' ''
    printf '%s\n' '[forge.github]'
    printf '%s\n' 'url = "https://api.github.com"'
    printf '%s\n' 'owner = "single-owner"'
    printf '%s\n' 'repo = "single-repo"'
    printf '%s\n' 'token = "single-token"'
    printf '%s\n' 'me = "single-me"'
} > "$CFG1"
ENV1="$TMPDIR_TEST/env1.dump"
if run_start "$CFG1" "$ENV1"; then
    got_owner="$(envdump_get "$ENV1" GITHUB_OWNER)"
    got_repo="$(envdump_get "$ENV1" GITHUB_REPO)"
    got_token="$(envdump_get "$ENV1" GITHUB_TOKEN)"
    got_url="$(envdump_get "$ENV1" GITHUB_URL)"
    got_me="$(envdump_get "$ENV1" GITHUB_ME)"
    has_json="$(grep -c '^GITHUB_REPOS_JSON=' "$ENV1" 2>/dev/null || true)"
    if [ "$got_owner" = "single-owner" ] \
       && [ "$got_repo" = "single-repo" ] \
       && [ "$got_token" = "single-token" ] \
       && [ "$got_url" = "https://api.github.com" ] \
       && [ "$got_me" = "single-me" ] \
       && [ "$has_json" = "0" ]; then
        pass "test 1: single-block exports GITHUB_OWNER/REPO/TOKEN/URL/ME, no GITHUB_REPOS_JSON"
    else
        fail "test 1: single-block exports GITHUB_OWNER/REPO/TOKEN/URL/ME, no GITHUB_REPOS_JSON" \
             "owner='$got_owner' repo='$got_repo' token='$got_token' url='$got_url' me='$got_me' has_json=$has_json"
    fi
else
    fail "test 1: single-block start-colony.sh exited non-zero" \
         "stdout=$(head -c 200 "$TMPDIR_TEST/stdout") stderr=$(head -c 200 "$TMPDIR_TEST/stderr")"
fi

# --- Test 2: multi-block (1 entry) -----------------------------------
# A 1-entry [[forge.github]] config must export GITHUB_REPOS_JSON with
# exactly one element AND back-compat-export the entry-[0] values to
# the legacy GITHUB_OWNER/REPO/TOKEN/URL/ME vars.
CFG2="$TMPDIR_TEST/multi-1.toml"
{
    printf '%s\n' '[forge]'
    printf '%s\n' 'type = "github"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'url = "https://api.github.com"'
    printf '%s\n' 'owner = "alpha-owner"'
    printf '%s\n' 'repo = "alpha-repo"'
    printf '%s\n' 'token = "alpha-token"'
    printf '%s\n' 'me = "alpha-me"'
} > "$CFG2"
ENV2="$TMPDIR_TEST/env2.dump"
if run_start "$CFG2" "$ENV2"; then
    got_owner="$(envdump_get "$ENV2" GITHUB_OWNER)"
    got_repo="$(envdump_get "$ENV2" GITHUB_REPO)"
    got_token="$(envdump_get "$ENV2" GITHUB_TOKEN)"
    got_url="$(envdump_get "$ENV2" GITHUB_URL)"
    got_me="$(envdump_get "$ENV2" GITHUB_ME)"
    got_json="$(envdump_get "$ENV2" GITHUB_REPOS_JSON)"
    if [ -n "$got_json" ]; then
        json_n="$(json_count "$got_json")"
        json_owner0="$(json_get "$got_json" 0 owner)"
        json_repo0="$(json_get "$got_json" 0 repo)"
        json_token0="$(json_get "$got_json" 0 token)"
    else
        json_n="MISSING"; json_owner0=""; json_repo0=""; json_token0=""
    fi
    if [ "$got_owner" = "alpha-owner" ] \
       && [ "$got_repo" = "alpha-repo" ] \
       && [ "$got_token" = "alpha-token" ] \
       && [ "$got_url" = "https://api.github.com" ] \
       && [ "$got_me" = "alpha-me" ] \
       && [ "$json_n" = "1" ] \
       && [ "$json_owner0" = "alpha-owner" ] \
       && [ "$json_repo0" = "alpha-repo" ] \
       && [ "$json_token0" = "alpha-token" ]; then
        pass "test 2: multi-block (1 entry) exports JSON with 1 entry + back-compat vars"
    else
        fail "test 2: multi-block (1 entry) exports JSON with 1 entry + back-compat vars" \
             "owner='$got_owner' repo='$got_repo' json_n='$json_n' json_owner0='$json_owner0' json_repo0='$json_repo0'"
    fi
else
    fail "test 2: multi-block (1 entry) start-colony.sh exited non-zero" \
         "stderr=$(head -c 200 "$TMPDIR_TEST/stderr")"
fi

# --- Test 3: multi-block (3 entries, source order) -------------------
# A 3-entry [[forge.github]] config must export a JSON array of length
# 3 with entries in source order. Back-compat vars carry entry [0].
CFG3="$TMPDIR_TEST/multi-3.toml"
{
    printf '%s\n' '[forge]'
    printf '%s\n' 'type = "github"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'url = "https://api.github.com"'
    printf '%s\n' 'owner = "acme"'
    printf '%s\n' 'repo = "frontend"'
    printf '%s\n' 'token = "tok-fe"'
    printf '%s\n' 'me = "alice"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'url = "https://api.github.com"'
    printf '%s\n' 'owner = "acme"'
    printf '%s\n' 'repo = "backend"'
    printf '%s\n' 'token = "tok-be"'
    printf '%s\n' 'me = "alice"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'url = "https://api.github.com"'
    printf '%s\n' 'owner = "acme"'
    printf '%s\n' 'repo = "infra"'
    printf '%s\n' 'token = "tok-inf"'
    printf '%s\n' 'me = "bob"'
} > "$CFG3"
ENV3="$TMPDIR_TEST/env3.dump"
if run_start "$CFG3" "$ENV3"; then
    got_owner="$(envdump_get "$ENV3" GITHUB_OWNER)"
    got_repo="$(envdump_get "$ENV3" GITHUB_REPO)"
    got_json="$(envdump_get "$ENV3" GITHUB_REPOS_JSON)"
    if [ -n "$got_json" ]; then
        n="$(json_count "$got_json")"
        repo0="$(json_get "$got_json" 0 repo)"
        repo1="$(json_get "$got_json" 1 repo)"
        repo2="$(json_get "$got_json" 2 repo)"
        token2="$(json_get "$got_json" 2 token)"
        me2="$(json_get "$got_json" 2 me)"
    else
        n="MISSING"; repo0=""; repo1=""; repo2=""; token2=""; me2=""
    fi
    if [ "$got_owner" = "acme" ] \
       && [ "$got_repo" = "frontend" ] \
       && [ "$n" = "3" ] \
       && [ "$repo0" = "frontend" ] \
       && [ "$repo1" = "backend" ] \
       && [ "$repo2" = "infra" ] \
       && [ "$token2" = "tok-inf" ] \
       && [ "$me2" = "bob" ]; then
        pass "test 3: multi-block (3 entries) JSON has 3 entries in source order"
    else
        fail "test 3: multi-block (3 entries) JSON has 3 entries in source order" \
             "owner='$got_owner' repo='$got_repo' n='$n' repos=[$repo0,$repo1,$repo2] token2='$token2' me2='$me2'"
    fi
else
    fail "test 3: multi-block (3 entries) start-colony.sh exited non-zero" \
         "stderr=$(head -c 200 "$TMPDIR_TEST/stderr")"
fi

# --- Test 4: secret:// URI tokens resolved to plaintext --------------
# Skip when secret-tool is not on PATH (CI runners + macOS hosts without
# libsecret). When available, store a token under a unique label, build
# a 1-entry config that points at the secret://, and assert the env
# dump carries the resolved plaintext (not the URI).
if command -v secret-tool >/dev/null 2>&1; then
    # parse-toml-secret.py resolves `secret://libsecret/<service>/<key>`
    # via `secret-tool lookup service <service> key <key>`. Match that
    # attribute schema exactly when storing.
    SECRET_SERVICE="agentis-test-316m2-$$"
    SECRET_KEY="token-$$"
    SECRET_VALUE="resolved-plaintext-$$"
    secret_setup_ok=1
    printf '%s' "$SECRET_VALUE" | secret-tool store --label="agentis test 316 m2" \
        service "$SECRET_SERVICE" key "$SECRET_KEY" 2>/dev/null || secret_setup_ok=0
    if [ "$secret_setup_ok" = "1" ]; then
        CFG4="$TMPDIR_TEST/multi-secret.toml"
        {
            printf '%s\n' '[forge]'
            printf '%s\n' 'type = "github"'
            printf '%s\n' ''
            printf '%s\n' '[[forge.github]]'
            printf '%s\n' 'url = "https://api.github.com"'
            printf '%s\n' 'owner = "secret-owner"'
            printf '%s\n' 'repo = "secret-repo"'
            printf '%s\n' "token = \"secret://libsecret/$SECRET_SERVICE/$SECRET_KEY\""
            printf '%s\n' 'me = "secret-me"'
        } > "$CFG4"
        ENV4="$TMPDIR_TEST/env4.dump"
        if run_start "$CFG4" "$ENV4"; then
            got_token="$(envdump_get "$ENV4" GITHUB_TOKEN)"
            got_json="$(envdump_get "$ENV4" GITHUB_REPOS_JSON)"
            json_token0="$(json_get "$got_json" 0 token 2>/dev/null || echo MISSING)"
            if [ "$got_token" = "$SECRET_VALUE" ] && [ "$json_token0" = "$SECRET_VALUE" ]; then
                pass "test 4: secret:// URI tokens resolved to plaintext in both back-compat var + JSON"
            else
                fail "test 4: secret:// URI tokens resolved to plaintext" \
                     "got_token='$got_token' json_token0='$json_token0' expected='$SECRET_VALUE'"
            fi
        else
            fail "test 4: secret:// URI tokens — start-colony.sh exited non-zero" \
                 "stderr=$(head -c 200 "$TMPDIR_TEST/stderr")"
        fi
        secret-tool clear service "$SECRET_SERVICE" key "$SECRET_KEY" 2>/dev/null || true
    else
        skip "test 4: secret-tool present but store failed (no libsecret session)"
    fi
else
    skip "test 4: secret-tool not on PATH — secret:// resolution path uncovered"
fi

# --- Test 5: malformed multi-block (missing owner in entry [1]) ------
# A [[forge.github]] entry that omits owner must abort the script with a
# non-zero exit AND a stderr error message naming the offending entry.
CFG5="$TMPDIR_TEST/multi-bad.toml"
{
    printf '%s\n' '[forge]'
    printf '%s\n' 'type = "github"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'url = "https://api.github.com"'
    printf '%s\n' 'owner = "ok-owner"'
    printf '%s\n' 'repo = "ok-repo"'
    printf '%s\n' 'token = "ok-token"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'url = "https://api.github.com"'
    printf '%s\n' 'repo = "no-owner-repo"'
    printf '%s\n' 'token = "no-owner-token"'
} > "$CFG5"
ENV5="$TMPDIR_TEST/env5.dump"
set +e
run_start "$CFG5" "$ENV5"
rc5=$?
set -e
if [ "$rc5" -ne 0 ] && grep -q 'entry \[1\]' "$TMPDIR_TEST/stderr" \
   && grep -q 'GitHub config incomplete' "$TMPDIR_TEST/stderr"; then
    pass "test 5: malformed multi-block (missing owner) exits non-zero with clear error"
else
    fail "test 5: malformed multi-block (missing owner) exits non-zero with clear error" \
         "rc=$rc5 stderr=$(head -c 300 "$TMPDIR_TEST/stderr")"
fi

# --- Test 6: env passthrough --------------------------------------------
# Two facts must hold:
#   (6a) GITHUB_REPOS_JSON is in the shell env at daemon-launch — the env
#        dump captured by the shim already proves this in tests 2/3, so
#        we re-assert here with a fresh run for clarity.
#   (6b) The literal `GITHUB_*` glob from `dev-apprenticeship/install.sh`
#        (per plan §5: env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,
#        GITHUB_*) accepts the new var name. Glob match is the bash
#        case-pattern operator — `case GITHUB_REPOS_JSON in GITHUB_*) ;;`.
CFG6="$TMPDIR_TEST/multi-passthrough.toml"
{
    printf '%s\n' '[forge]'
    printf '%s\n' 'type = "github"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'url = "https://api.github.com"'
    printf '%s\n' 'owner = "passthrough-owner"'
    printf '%s\n' 'repo = "passthrough-repo"'
    printf '%s\n' 'token = "passthrough-token"'
} > "$CFG6"
ENV6="$TMPDIR_TEST/env6.dump"
sub6_a=0
sub6_b=0
sub6_c=0
if run_start "$CFG6" "$ENV6"; then
    got_json="$(envdump_get "$ENV6" GITHUB_REPOS_JSON)"
    if [ -n "$got_json" ]; then
        sub6_a=1
    fi
fi
# Intentionally a constant case — proves the literal var name matches
# the literal glob from install.sh's env_passthrough line.
# shellcheck disable=SC2194
case GITHUB_REPOS_JSON in
    GITHUB_*) sub6_b=1 ;;
esac
# Probe the install.sh literal that writes env_passthrough. The line
# substitutes the GITHUB_* glob into the .agentis/config — search for
# it byte-for-byte. install.sh is the source of truth for what the
# operator's federation file looks like post-install.
if [ -f "$INSTALL_SH" ] && grep -q 'GITHUB_\*' "$INSTALL_SH"; then
    sub6_c=1
fi
if [ "$sub6_a" = "1" ] && [ "$sub6_b" = "1" ] && [ "$sub6_c" = "1" ]; then
    pass "test 6: GITHUB_REPOS_JSON reaches daemon-launch + GITHUB_* glob accepts it"
else
    fail "test 6: GITHUB_REPOS_JSON reaches daemon-launch + GITHUB_* glob accepts it" \
         "in_env=$sub6_a glob_match=$sub6_b install_writes_glob=$sub6_c"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
