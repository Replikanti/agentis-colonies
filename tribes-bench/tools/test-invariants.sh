#!/usr/bin/env bash
# tribes-bench/tools/test-invariants.sh -- pins the reputation-floor
# environmental invariant modules under tribes-bench/config/invariants/ (#1735;
# agentis-core #950 signal payload-v4, #953 <colony> token).
#
# ONE shared signal binding -- signal reputation = memo("reputation:tribes-bench-<colony>")
# -- expressed twice at two severities:
#   reputation-floor-costly.inv     -> class = costly,     when reputation < 0.3
#   reputation-floor-inviolable.inv -> class = inviolable, when reputation < 0.1
#
# The design leans on the <colony> substitution token (agentis-core #953)
# resolving each daemon to its own tribe (`--colony tribe-<name>`), so ONE
# module set correctly scopes all five tribes with no cross-tribe
# contamination. <self> would be WRONG here: every tribe's hunter is launched
# from a source file literally named `hunter.ag`, so <self> resolves to the
# identical "hunter" for all five and cannot distinguish tribes.
#
# Three layers (mirroring research-foundry's #1736 / trading-binance's #1737
# convention, extended with a Layer 3 launch-flag pin):
#   Layer 1 (grammar)     -- pure grep, always runs. Asserts class / signal /
#                            when per module, AND that the string `<self>` is
#                            ABSENT (the exact bug this design avoids).
#   Layer 2 (fixture)     -- requires agentis (>= v1.28.0 for <colony>) on PATH;
#                            skipped otherwise. Pins the memo-format contract +
#                            fail-closed clean load + a non-empty set hash.
#   Layer 3 (launch pin)  -- pure grep, always runs. Asserts every
#                            tribe-*/scripts/start-colony.sh still launches its
#                            daemon `--colony tribe-<name>` matching its dir --
#                            the load-bearing fact the <colony> scoping needs.
#
# A genuine live-daemon self-cull integration test (spawning a real
# `agentis daemon` with daemon.invariant_sweep=true and observing a self-cull)
# is deliberately out of scope -- Layer 2 pins everything provable without one.
#
# Usage: bash tribes-bench/tools/test-invariants.sh

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

# --- Layer 1: grammar (module -> expected class + floor) ---------------
# Each .inv must carry exactly one `class = <expected>` directive, exactly one
# `signal reputation = memo("reputation:tribes-bench-<colony>")` binding, and
# exactly one `when reputation < <floor>` clause. The <colony> template (NOT
# <self>) is the whole correctness point, so both the presence of <colony> and
# the ABSENCE of <self> are asserted.
SIGNAL_LINE='signal reputation = memo("reputation:tribes-bench-<colony>")'

check_module() {
    file="$1"
    expected_class="$2"
    expected_floor="$3"
    path="$INV_DIR/$file"
    if [ ! -f "$path" ]; then
        fail "grammar: $file exists" "missing at $path"
        return
    fi
    # Strip comments + blank lines so directive counts are exact.
    body="$(grep -vE '^[[:space:]]*(#|$)' "$path")"

    class_count="$(printf '%s\n' "$body" | grep -cE '^class[[:space:]]*=' || true)"
    if [ "$class_count" -eq 1 ] && printf '%s\n' "$body" | grep -qE "^class[[:space:]]*=[[:space:]]*${expected_class}[[:space:]]*\$"; then
        pass "grammar: $file has exactly one 'class = $expected_class' directive"
    else
        fail "grammar: $file class directive" "want exactly one 'class = $expected_class', got $class_count class line(s)"
    fi

    signal_count="$(printf '%s\n' "$body" | grep -cE '^signal[[:space:]]' || true)"
    if [ "$signal_count" -eq 1 ] && printf '%s\n' "$body" | grep -qxF "$SIGNAL_LINE"; then
        pass "grammar: $file binds the <colony>-scoped reputation signal"
    else
        fail "grammar: $file signal binding" "want exactly one '$SIGNAL_LINE', got $signal_count signal line(s)"
    fi

    # The load-bearing negative assertion: <self> cannot distinguish tribes
    # (all hunters share the source basename 'hunter'), so it must NOT appear.
    if grep -qF '<self>' "$path"; then
        fail "grammar: $file <self> absent" "found '<self>' -- it resolves to 'hunter' for every tribe and cannot scope per tribe; use '<colony>'"
    else
        pass "grammar: $file does not use '<self>' (uses '<colony>')"
    fi

    when_count="$(printf '%s\n' "$body" | grep -cE '^when[[:space:]]' || true)"
    if [ "$when_count" -eq 1 ] && printf '%s\n' "$body" | grep -qE "^when[[:space:]]+reputation[[:space:]]*<[[:space:]]*${expected_floor}[[:space:]]*\$"; then
        pass "grammar: $file has exactly one 'when reputation < $expected_floor' clause"
    else
        fail "grammar: $file when clause" "want exactly one 'when reputation < $expected_floor', got $when_count when line(s)"
    fi
}

check_module "reputation-floor-costly.inv" costly 0.3
check_module "reputation-floor-inviolable.inv" inviolable 0.1

# --- Layer 3: launch-flag pin (pure grep, always runs) -----------------
# The whole <colony>-scoping design depends on each tribe's daemon being
# launched `--colony tribe-<name>` matching its own directory. If a future
# edit drops or renames that flag, the shared module set silently mis-scopes
# across tribes again -- pin it here, not just once during planning.
for tribe_dir in "$FED_DIR"/tribe-*; do
    [ -d "$tribe_dir" ] || continue
    tribe_name="$(basename "$tribe_dir")"
    start_colony="$tribe_dir/scripts/start-colony.sh"
    if [ ! -f "$start_colony" ]; then
        fail "launch-pin: $tribe_name start-colony.sh exists" "missing at $start_colony"
        continue
    fi
    if grep -qE "^[[:space:]]*--colony[[:space:]]+${tribe_name}([[:space:]]|\\\\|\$)" "$start_colony"; then
        pass "launch-pin: $tribe_name launches its daemon '--colony $tribe_name'"
    else
        fail "launch-pin: $tribe_name '--colony $tribe_name'" "no '--colony $tribe_name' daemon-launch flag found in $start_colony"
    fi
done

# --- Layer 2: fixture-based memo contract + clean load (requires agentis) ---
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

# --- 2a: memo-format contract. The whole signal design leans on
# `agentis memo set` writing a QUOTED string float ({"value":"0.5"}); a bare
# JSON number reads as Missing -> cull (the #950-review fail-closed shape).
# Pin the exact on-disk shape so a future core release that changes it fails
# CI immediately instead of degrading silently in a live run.
( cd "$WORK" && agentis memo set "reputation:tribes-bench-tribe-alpha" "0.5" >/dev/null 2>&1 ) || true
MEMO_JSONL="$WORK/.agentis/memo/reputation:tribes-bench-tribe-alpha.jsonl"
if [ -f "$MEMO_JSONL" ] && grep -q '"value":"0.5"' "$MEMO_JSONL"; then
    pass "fixture: memo set writes a quoted-string value (\"value\":\"0.5\")"
else
    fail "fixture: memo quoted-string value" "expected '\"value\":\"0.5\"' in $MEMO_JSONL: $(cat "$MEMO_JSONL" 2>/dev/null)"
fi

# --- 2b: fail-closed clean load. Point a workdir config at the checked-in
# module dir and run the read-only `agentis invariant check --json` CLI. Both
# modules are memo/runtime-derived signal modules, so they are INERT on this
# source-shape-only surface -- never cull, never pass on the signal (they are
# counted in skipped_runtime_modules). This pins "the set loads clean and
# reports a stable set hash", NOT cull/pass parity (there is no self-cull to
# observe on this CLI surface -- that lives on the live-daemon path, out of
# scope here).
printf 'evolution.invariants_dir = %s\n' "$INV_DIR" >> "$WORK/.agentis/config"
INV_JSON="$(cd "$WORK" && agentis invariant check "$FED_DIR/tribe-alpha/agents/hunter.ag" --json 2>/dev/null)" && INV_RC=0 || INV_RC=$?
if [ "$INV_RC" -eq 0 ]; then
    pass "fixture: invariant check loads the module set clean (exit 0, signal modules inert on source-shape surface)"
else
    fail "fixture: invariant check clean load" "expected exit 0, got $INV_RC: $INV_JSON"
fi

SET_HASH="$(printf '%s' "$INV_JSON" | python3 -c "
import json, sys
try:
    obj = json.loads(sys.stdin.read())
except (json.JSONDecodeError, ValueError):
    sys.exit(0)
sys.stdout.write(str(obj.get('set_hash', '')))
" 2>/dev/null || true)"
if [ -n "$SET_HASH" ]; then
    pass "fixture: invariant check reports a non-empty set_hash ($SET_HASH)"
else
    fail "fixture: invariant check set_hash" "empty set_hash in output: $INV_JSON"
fi

SKIPPED_RT="$(printf '%s' "$INV_JSON" | python3 -c "
import json, sys
try:
    obj = json.loads(sys.stdin.read())
except (json.JSONDecodeError, ValueError):
    sys.exit(0)
sys.stdout.write(str(obj.get('skipped_runtime_modules', -1)))
" 2>/dev/null || true)"
if [ -n "$SKIPPED_RT" ] && [ "$SKIPPED_RT" -ge 2 ] 2>/dev/null; then
    pass "fixture: both signal modules are runtime-only, inert on this surface (skipped_runtime_modules=$SKIPPED_RT >= 2)"
else
    fail "fixture: skipped_runtime_modules >= 2" "expected >= 2 skipped runtime modules, got '$SKIPPED_RT': $INV_JSON"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
