#!/usr/bin/env bash
# trading-binance/tools/test-invariants.sh -- pins the backtest-only
# environmental invariant modules under trading-binance/config/invariants/
# (#1737).
#
# The two capability-absence .inv modules express the "backtest only" law:
#   no-order-placement.inv -> forbidden_callee = place_order / cancel_order /
#                              submit_order / new_order
#   no-network-egress.inv  -> forbidden_callee = http_get / http_post /
#                              use_tool / smtp_send
#
# Both are `forbidden_callee` (capability-absence) modules, deliberately NOT
# `egress_allow`/`egress_outside_allowlist` -- see the .inv header comments
# and the PR description for why an egress-allowlist module always culls
# the legitimate strategist here (opaque `exec sh` + non-literal replicate
# target).
#
# Two layers, mirroring research-foundry's #1736 test-invariants.sh
# convention: grammar assertions run always (pure grep); the fixture-based
# cull/pass assertions run only when `agentis` (>= v1.25.0, which ships
# forbidden_callee/egress_outside_allowlist payload-v3) is on PATH and are
# skipped otherwise.
#
# Usage: bash trading-binance/tools/test-invariants.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"
INV_DIR="$FED_DIR/config/invariants"

PASS=0
FAIL=0
SKIP=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1"; SKIP=$((SKIP + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Layer 1: grammar (module -> expected forbidden_callee set) --------
# Each .inv must carry exactly one `class = inviolable` directive, exactly
# one `when forbidden_callee_used == true` clause (UNQUOTED boolean --
# a quoted literal is a type mismatch agentis rejects at load), and
# exactly the expected repeatable `forbidden_callee = <name>` directives
# (order-independent).
check_module() {
    local file="$1"
    shift
    local expected_callees="$*"
    local path="$INV_DIR/$file"
    if [ ! -f "$path" ]; then
        fail "grammar: $file exists" "missing at $path"
        return
    fi
    # Strip comments + blank lines so directive counts are exact.
    local body
    body="$(grep -vE '^[[:space:]]*(#|$)' "$path")"

    local class_count
    class_count="$(printf '%s\n' "$body" | grep -cE '^class[[:space:]]*=' || true)"
    if [ "$class_count" -eq 1 ] && printf '%s\n' "$body" | grep -qE '^class[[:space:]]*=[[:space:]]*inviolable[[:space:]]*$'; then
        pass "grammar: $file has exactly one 'class = inviolable' directive"
    else
        fail "grammar: $file class directive" "want exactly one 'class = inviolable', got $class_count class line(s)"
    fi

    local when_count
    when_count="$(printf '%s\n' "$body" | grep -cE '^when[[:space:]]' || true)"
    if [ "$when_count" -eq 1 ] && printf '%s\n' "$body" | grep -qE '^when[[:space:]]+forbidden_callee_used[[:space:]]*==[[:space:]]*true[[:space:]]*$'; then
        pass "grammar: $file has exactly one 'when forbidden_callee_used == true' clause"
    else
        fail "grammar: $file when clause" "want exactly one 'when forbidden_callee_used == true', got $when_count when line(s)"
    fi

    # Guard against a quoted boolean literal (silently never fires).
    if printf '%s\n' "$body" | grep -qE '==[[:space:]]*"'; then
        fail "grammar: $file boolean literal unquoted" "found a quoted literal (== \"...\"), which agentis rejects"
    else
        pass "grammar: $file boolean literal is unquoted"
    fi

    local callee
    for callee in $expected_callees; do
        if printf '%s\n' "$body" | grep -qE "^forbidden_callee[[:space:]]*=[[:space:]]*${callee}[[:space:]]*$"; then
            pass "grammar: $file denies '$callee'"
        else
            fail "grammar: $file denies '$callee'" "no 'forbidden_callee = $callee' directive found"
        fi
    done

    local callee_count
    callee_count="$(printf '%s\n' "$body" | grep -cE '^forbidden_callee[[:space:]]*=' || true)"
    local expected_count
    expected_count="$(printf '%s\n' "$expected_callees" | wc -w | tr -d ' ')"
    if [ "$callee_count" -eq "$expected_count" ]; then
        pass "grammar: $file has exactly $expected_count forbidden_callee directive(s)"
    else
        fail "grammar: $file forbidden_callee count" "want $expected_count, got $callee_count"
    fi
}

check_module "no-order-placement.inv" place_order cancel_order submit_order new_order
check_module "no-network-egress.inv" http_get http_post use_tool smtp_send

# --- Layer 2: fixture-based cull/pass (requires agentis >= v1.25.0) ----
if ! command -v agentis >/dev/null 2>&1; then
    skip "invariant check fixtures (agentis not on PATH)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    [ "$FAIL" -eq 0 ]
    exit $?
fi

WORK="$TMP/work"
mkdir -p "$WORK"
( cd "$WORK" && agentis init >/dev/null 2>&1 ) || true
# Point the harness config at the checked-in module dir (absolute path;
# the daemon/CLI run from a fixed WORKDIR in the real container too).
printf 'evolution.invariants_dir = %s\n' "$INV_DIR" >>"$WORK/.agentis/config"

# `agentis invariant check` self-exits: 0=pass, 3=cull, 1=error.
inv_check() {
    local fixture="$1"
    ( cd "$WORK" && agentis invariant check "$fixture" --json )
}

# --- 2a: capability-absence regression sentinel -- all six real
# strategist.ag sources must pass clean against BOTH modules. This is the
# invariant that the two forbidden callees stay absent from the codebase
# (AC2: no verb is introduced just to have something to block).
for t in alpha beta gamma delta epsilon zeta; do
    strategist="$FED_DIR/tribe-$t/agents/strategist.ag"
    if [ ! -f "$strategist" ]; then
        fail "fixture: tribe-$t strategist.ag exists" "missing at $strategist"
        continue
    fi
    out="$(inv_check "$strategist" 2>/dev/null)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "fixture: tribe-$t strategist.ag passes clean (exit 0)"
    else
        fail "fixture: tribe-$t strategist.ag passes clean" "expected exit 0, got $rc: $out"
    fi
done

# --- 2b: synthetic bad-strategist-order.ag -- culled by no-order-placement
cat >"$TMP/bad-strategist-order.ag" <<'AGEOF'
cb 200;
fn place_order(qty: string) -> void {
    exec sh "echo noop";
}
fn tick(_r: string) -> void {
    let t = tier("probe");
    place_order("1");
}
AGEOF
out="$(inv_check "$TMP/bad-strategist-order.ag" 2>/dev/null)" && rc=0 || rc=$?
if [ "$rc" -eq 3 ]; then
    if printf '%s' "$out" | grep -q "place_order"; then
        pass "fixture: bad-strategist-order.ag culled (exit 3, reason names place_order)"
    else
        fail "fixture: bad-strategist-order.ag culled reason" "exit 3 but reason does not name place_order: $out"
    fi
else
    fail "fixture: bad-strategist-order.ag culled" "expected exit 3, got $rc: $out"
fi

# --- 2c: synthetic bad-strategist-egress.ag -- culled by no-network-egress
cat >"$TMP/bad-strategist-egress.ag" <<'AGEOF'
cb 200;
fn tick(_r: string) -> void {
    let t = tier("probe");
    use_tool("place_order", "post", "BTCUSD");
}
AGEOF
out="$(inv_check "$TMP/bad-strategist-egress.ag" 2>/dev/null)" && rc=0 || rc=$?
if [ "$rc" -eq 3 ]; then
    if printf '%s' "$out" | grep -q "use_tool"; then
        pass "fixture: bad-strategist-egress.ag culled by no-network-egress (exit 3, reason names use_tool)"
    else
        fail "fixture: bad-strategist-egress.ag culled reason" "exit 3 but reason does not name use_tool: $out"
    fi
else
    fail "fixture: bad-strategist-egress.ag culled" "expected exit 3, got $rc: $out"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
