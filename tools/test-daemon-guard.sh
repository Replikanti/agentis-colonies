#!/usr/bin/env bash
# tools/test-daemon-guard.sh (#1750/#1869): pins the contract of
# tools/lib/daemon-guard.sh — the shared spawn/reap guard the three
# live-daemon tools tests use so they stop leaking `agentis daemon`
# processes past their own workspace.
#
# Deliberately uses a FAKE `agentis` shim instead of the real binary: the
# shim forks a grandchild the way the real watchdog forks `daemon-inner`,
# which is the exact shape that made the old `kill $!` teardown a no-op.
# That keeps this test offline, fast, and runnable on CI (where no agentis
# binary exists) while still exercising the group kill and the scope sweep.
#
# Tests:
#   1. spawn + reap leaves ZERO survivors — including the grandchild.
#   2. reap is SCOPED: an identical shim running outside the scope dir is
#      untouched.
#   3. daemon_guard_teardown preserves $? when `rm -rf` fails AND when it
#      succeeds (the trap must never rewrite the script's verdict).
#   4. daemon_guard_survivors reports a deliberately orphaned in-scope
#      process and returns non-zero.
#   5. With setsid unavailable, the fallback still reaps the whole tree via
#      the scope sweep.
#   6. A process whose argv merely CONTAINS "agentis daemon" but lives
#      outside the scope is never signalled.
#
# Auto-discovered by tools/colony-lint.sh's `find tools -name test-*.sh`
# loop (bash, [PASS]/[FAIL] lines, `Results: N passed, M failed` trailer).
# Usage: ./tools/test-daemon-guard.sh
# Exit 0 if all tests pass, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/lib/daemon-guard.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if [ ! -f "$LIB" ]; then
    fail "library missing" "$LIB"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# shellcheck source=tools/lib/daemon-guard.sh
. "$LIB"

TEST_ROOT="$(mktemp -d)"
# Last-resort net: whatever a failing assertion left behind is reaped against
# TEST_ROOT (which every fixture lives under), never host-wide.
cleanup_all() {
    _rc=$?
    DAEMON_GUARD_SCOPE="$TEST_ROOT"
    daemon_guard_reap >/dev/null 2>&1 || true
    rm -rf "$TEST_ROOT" 2>/dev/null || true
    return "$_rc"
}
trap cleanup_all EXIT

# install_fake_agentis <bin_dir>: a stand-in for the real binary whose
# `daemon` mode forks a `daemon-inner` grandchild and then idles, so both
# processes carry an argv matching `agentis daemon` and share the launch cwd.
install_fake_agentis() {
    _bin="$1"
    mkdir -p "$_bin"
    cat > "$_bin/agentis" <<'SHIM'
#!/usr/bin/env bash
# Fake agentis for tools/test-daemon-guard.sh — models the watchdog/inner pair.
set -u
mode="${1:-}"
shift || true
if [ "$mode" = "daemon" ]; then
    "$0" daemon-inner "$@" &
fi
while true; do
    sleep 1
done
SHIM
    chmod +x "$_bin/agentis"
}

# spawn_raw <cwd> <argv...>: a launch the guard knows nothing about (no ledger
# entry) — models the operator's own federation and the orphan left behind by
# a crashed run. setsid when available, so the fixture is torn down as a group.
spawn_raw() {
    _cwd="$1"
    shift
    if command -v setsid >/dev/null 2>&1; then
        ( cd "$_cwd" && exec setsid "$@" ) </dev/null >"$_cwd/raw.log" 2>&1 &
    else
        ( cd "$_cwd" && exec "$@" ) </dev/null >"$_cwd/raw.log" 2>&1 &
    fi
}

# live_in_scope <scope>: count of live shim processes whose cwd is the scope.
live_in_scope() {
    _scope="$1"
    _n=0
    for _p in $(pgrep -f 'agentis daemon' 2>/dev/null || true); do
        [ "$_p" = "$$" ] && continue
        _cwd="$(readlink "/proc/$_p/cwd" 2>/dev/null || true)"
        _cwd="${_cwd% (deleted)}"
        case "$_cwd" in
            "$_scope"|"$_scope"/*) _n=$((_n + 1)) ;;
        esac
    done
    printf '%s' "$_n"
}

BIN="$TEST_ROOT/bin"
install_fake_agentis "$BIN"
export PATH="$BIN:$PATH"

# --- Test 1: spawn + reap kills the whole tree (watchdog + grandchild) ---
SCOPE1="$TEST_ROOT/scope1"
mkdir -p "$SCOPE1"
: > "$SCOPE1/fake.ag"
daemon_guard_init "$SCOPE1"
PID1="$(daemon_guard_spawn --cwd "$SCOPE1" --log "$SCOPE1/daemon.log" \
    -- agentis daemon "$SCOPE1/fake.ag" --colony demo --enable-exec)"
sleep 1
TREE1="$(live_in_scope "$SCOPE1")"
if [ -n "$PID1" ] && [ "$TREE1" -ge 2 ]; then
    pass "spawn launched the watchdog AND its daemon-inner grandchild (pid=$PID1, tree=$TREE1)"
else
    fail "spawn launched a two-process tree" "pid=[$PID1] tree=$TREE1"
fi

daemon_guard_reap >/dev/null 2>&1 || true
sleep 0.5
LEFT1="$(live_in_scope "$SCOPE1")"
if [ "$LEFT1" -eq 0 ]; then
    pass "reap left ZERO survivors in scope (the grandchild died too — the #1869 leak)"
else
    fail "reap left survivors" "count=$LEFT1"
fi

# --- Test 2 + 6: the reap is scoped, both by cwd and by argv ---
SCOPE2="$TEST_ROOT/scope2"
OUTSIDE="$TEST_ROOT/outside"
mkdir -p "$SCOPE2" "$OUTSIDE"
: > "$SCOPE2/fake.ag"
: > "$OUTSIDE/fake.ag"
daemon_guard_init "$SCOPE2"
PID2="$(daemon_guard_spawn --cwd "$SCOPE2" --log "$SCOPE2/daemon.log" \
    -- agentis daemon "$SCOPE2/fake.ag" --colony demo)"
# A bystander with a matching argv, living entirely outside the scope — the
# operator's own federation, modelled. It must survive untouched.
spawn_raw "$OUTSIDE" agentis daemon "$OUTSIDE/fake.ag" --colony other
sleep 1
BYSTANDER_BEFORE="$(live_in_scope "$OUTSIDE")"

daemon_guard_reap >/dev/null 2>&1 || true
sleep 0.5
LEFT2="$(live_in_scope "$SCOPE2")"
BYSTANDER_AFTER="$(live_in_scope "$OUTSIDE")"
if [ "$LEFT2" -eq 0 ]; then
    pass "reap cleared the in-scope tree (pid=$PID2)"
else
    fail "reap cleared the in-scope tree" "count=$LEFT2"
fi
if [ "$BYSTANDER_BEFORE" -ge 2 ] && [ "$BYSTANDER_AFTER" = "$BYSTANDER_BEFORE" ]; then
    pass "out-of-scope 'agentis daemon' process NOT signalled (before=$BYSTANDER_BEFORE after=$BYSTANDER_AFTER)"
else
    fail "out-of-scope process survives the reap" "before=$BYSTANDER_BEFORE after=$BYSTANDER_AFTER"
fi

# Tear the bystander down explicitly, now that its survival is proven.
DAEMON_GUARD_SCOPE="$OUTSIDE"
daemon_guard_reap >/dev/null 2>&1 || true

# --- Test 4: survivors reports an orphan and returns non-zero ---
SCOPE4="$TEST_ROOT/scope4"
mkdir -p "$SCOPE4"
: > "$SCOPE4/fake.ag"
spawn_raw "$SCOPE4" agentis daemon "$SCOPE4/fake.ag" --colony orphan
sleep 1
SURV_OUT="$(daemon_guard_survivors "$SCOPE4")" && SURV_RC=0 || SURV_RC=$?
if [ "$SURV_RC" -ne 0 ] && [ -n "$SURV_OUT" ] \
   && printf '%s\n' "$SURV_OUT" | grep -q 'agentis daemon'; then
    pass "survivors reported the in-scope orphan and returned non-zero (rc=$SURV_RC)"
else
    fail "survivors on an orphaned in-scope process" "rc=$SURV_RC out=[$SURV_OUT]"
fi

DAEMON_GUARD_SCOPE="$SCOPE4"
daemon_guard_reap >/dev/null 2>&1 || true
sleep 0.5
if daemon_guard_survivors "$SCOPE4" >/dev/null 2>&1; then
    pass "survivors returns 0 (and prints nothing) once the scope is clean"
else
    fail "survivors still non-zero after reaping the orphan"
fi

# --- Test 5: no setsid -> fallback still reaps the whole tree ---
SCOPE5="$TEST_ROOT/scope5"
mkdir -p "$SCOPE5"
: > "$SCOPE5/fake.ag"
daemon_guard_init "$SCOPE5"
DAEMON_GUARD_SETSID="$TEST_ROOT/no-such-setsid"
PID5="$(daemon_guard_spawn --cwd "$SCOPE5" --log "$SCOPE5/daemon.log" \
    -- agentis daemon "$SCOPE5/fake.ag" --colony fallback)"
DAEMON_GUARD_SETSID="setsid"
sleep 1
TREE5="$(live_in_scope "$SCOPE5")"
LEDGER_MARK="$(grep -c "^pid:$PID5\$" "$DAEMON_GUARD_LEDGER" 2>/dev/null || true)"
if [ "$TREE5" -ge 2 ] && [ "$LEDGER_MARK" = "1" ]; then
    pass "no setsid: launch recorded as a single-pid entry (never group-killed), tree=$TREE5"
else
    fail "no-setsid launch shape" "tree=$TREE5 ledger_pid_entries=$LEDGER_MARK"
fi
daemon_guard_reap >/dev/null 2>&1 || true
sleep 0.5
LEFT5="$(live_in_scope "$SCOPE5")"
if [ "$LEFT5" -eq 0 ]; then
    pass "no setsid: the scope sweep still reaped the whole tree"
else
    fail "no-setsid fallback left survivors" "count=$LEFT5"
fi
# The test script's own process group must have survived all of the above.
if kill -0 "$$" 2>/dev/null; then
    pass "the guard never signalled the test script's own process group"
else
    fail "the test script's own group was signalled"
fi

# --- Test 3: teardown preserves $? on a failing AND a succeeding rm -rf ---
# Run in child scripts so the assertion is on the real EXIT-trap path.
write_rc_fixture() {
    # write_rc_fixture <path> <exit_code> <make_rm_fail:0|1>
    _path="$1"; _code="$2"; _hard="$3"
    cat > "$_path" <<FIXTURE
set -u
. "$LIB"
W="\$(mktemp -d)"
mkdir -p "\$W/sub"
: > "\$W/sub/f"
if [ "$_hard" = "1" ]; then
    chmod 500 "\$W/sub"
fi
daemon_guard_init "\$W"
trap 'daemon_guard_teardown "\$W"' EXIT
printf '%s\n' "\$W"
exit $_code
FIXTURE
}

RC_FIX="$TEST_ROOT/rc-ok.sh"
write_rc_fixture "$RC_FIX" 7 0
RC_OK_DIR="$(bash "$RC_FIX")" && RC_OK=0 || RC_OK=$?
if [ "$RC_OK" -eq 7 ] && [ ! -d "$RC_OK_DIR" ]; then
    pass "teardown preserved exit status 7 and removed the workspace"
else
    fail "teardown on a succeeding rm -rf" "rc=$RC_OK dir_left=[$RC_OK_DIR]"
fi

RC_FIX2="$TEST_ROOT/rc-hard.sh"
write_rc_fixture "$RC_FIX2" 42 1
RC_HARD_DIR="$(bash "$RC_FIX2")" && RC_HARD=0 || RC_HARD=$?
if [ "$RC_HARD" -eq 42 ]; then
    pass "teardown preserved exit status 42 even when rm -rf could not finish"
else
    fail "teardown on a failing rm -rf" "rc=$RC_HARD"
fi
if [ -n "${RC_HARD_DIR:-}" ] && [ -d "$RC_HARD_DIR" ]; then
    chmod 700 "$RC_HARD_DIR/sub" 2>/dev/null || true
    rm -rf "$RC_HARD_DIR" 2>/dev/null || true
fi

# And the function's own return value, called directly.
# shellcheck disable=SC1090 # same $LIB already sourced (and followed) above
( set -u; . "$LIB"; W="$(mktemp -d)"; daemon_guard_init "$W"; \
  ( exit 13 ); daemon_guard_teardown "$W" ) && DIRECT_RC=0 || DIRECT_RC=$?
if [ "$DIRECT_RC" -eq 13 ]; then
    pass "daemon_guard_teardown returns the status it was entered with (13)"
else
    fail "daemon_guard_teardown return value" "rc=$DIRECT_RC"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
