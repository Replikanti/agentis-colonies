#!/bin/bash
# tools/test-agentis-memo-freshness.sh: unit tests for the shared
# memo-freshness module extracted in #709 from
# federation-dashboard/lib/federation-dashboard-collector.py and
# tools/auto-promote-decisions.py. Covers:
#
#   1. STALENESS_TICKS default (no env) = 3.
#   2. STALENESS_TICKS env=10 -> 10.
#   3. STALENESS_TICKS env=0 clamps to 1.
#   4. STALENESS_TICKS env=abc -> 3 (try/except fallback).
#   5. parse_last_check_epoch("2026-05-19T12:34:56Z") matches the expected
#      epoch derived from `date -d` / python fallback.
#   6. parse_last_check_epoch(None) + bad-shape -> None.
#   7. read_memo_raw against a seeded value (skipped if `agentis` not on
#      PATH, mirroring test-dashboard-freshness-liveness.sh).
#   8. resolve_tick_interval_ms with explicit fed_tools_dir + cache-hit on
#      the 2nd call returns the same value without re-spawning the helper.
#
# Usage: ./tools/test-agentis-memo-freshness.sh
# Exit 0 on full pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# Common Python prelude that adds the tools dir to sys.path so the
# module loads under its real filename (hyphen-free).
PYPATH_PRELUDE="import sys; sys.path.insert(0, '$SCRIPT_DIR')"

# --- Test 1: default STALENESS_TICKS = 3 ---
ACTUAL="$(unset FEDERATION_DASHBOARD_STALENESS_TICKS; python3 -c "$PYPATH_PRELUDE
import agentis_memo_freshness as f
print(f.STALENESS_TICKS)
")"
if [ "$ACTUAL" = "3" ]; then
    pass "1: STALENESS_TICKS default = 3"
else
    fail "1: STALENESS_TICKS default" "expected 3, got $ACTUAL"
fi

# --- Test 2: env=10 -> 10 ---
ACTUAL="$(FEDERATION_DASHBOARD_STALENESS_TICKS=10 python3 -c "$PYPATH_PRELUDE
import agentis_memo_freshness as f
print(f.STALENESS_TICKS)
")"
if [ "$ACTUAL" = "10" ]; then
    pass "2: STALENESS_TICKS env=10 -> 10"
else
    fail "2: STALENESS_TICKS env=10" "expected 10, got $ACTUAL"
fi

# --- Test 3: env=0 clamps to 1 ---
ACTUAL="$(FEDERATION_DASHBOARD_STALENESS_TICKS=0 python3 -c "$PYPATH_PRELUDE
import agentis_memo_freshness as f
print(f.STALENESS_TICKS)
")"
if [ "$ACTUAL" = "1" ]; then
    pass "3: STALENESS_TICKS env=0 clamps to 1"
else
    fail "3: STALENESS_TICKS env=0 clamp" "expected 1, got $ACTUAL"
fi

# --- Test 4: env=abc -> 3 (fallback) ---
ACTUAL="$(FEDERATION_DASHBOARD_STALENESS_TICKS=abc python3 -c "$PYPATH_PRELUDE
import agentis_memo_freshness as f
print(f.STALENESS_TICKS)
")"
if [ "$ACTUAL" = "3" ]; then
    pass "4: STALENESS_TICKS env=abc -> 3 fallback"
else
    fail "4: STALENESS_TICKS env=abc fallback" "expected 3, got $ACTUAL"
fi

# --- Test 5: parse_last_check_epoch on a real ISO-8601 UTC string ---
ISO_FIXTURE="2026-05-19T12:34:56Z"
EXPECTED_EPOCH="$(date -u -d "$ISO_FIXTURE" '+%s' 2>/dev/null || \
                  python3 -c "import datetime; print(int(datetime.datetime(2026,5,19,12,34,56,tzinfo=datetime.timezone.utc).timestamp()))")"
ACTUAL="$(python3 -c "$PYPATH_PRELUDE
import agentis_memo_freshness as f
v = f.parse_last_check_epoch('$ISO_FIXTURE')
print(int(v) if v is not None else 'None')
")"
if [ "$ACTUAL" = "$EXPECTED_EPOCH" ]; then
    pass "5: parse_last_check_epoch($ISO_FIXTURE) = $EXPECTED_EPOCH"
else
    fail "5: parse_last_check_epoch ISO-8601" "expected $EXPECTED_EPOCH, got $ACTUAL"
fi

# --- Test 6: parse_last_check_epoch(None) + bad shape -> None ---
ACTUAL="$(python3 -c "$PYPATH_PRELUDE
import agentis_memo_freshness as f
results = [f.parse_last_check_epoch(None), f.parse_last_check_epoch(''), f.parse_last_check_epoch('not-an-iso-date'), f.parse_last_check_epoch('2026-05-19')]
print(','.join('None' if r is None else str(r) for r in results))
")"
if [ "$ACTUAL" = "None,None,None,None" ]; then
    pass "6: parse_last_check_epoch(None / '' / bad-shape / date-only) all return None"
else
    fail "6: parse_last_check_epoch None/bad" "expected 'None,None,None,None', got '$ACTUAL'"
fi

# --- Test 7: read_memo_raw against seeded value ---
if ! command -v agentis >/dev/null 2>&1; then
    echo "[SKIP] 7: agentis binary not found on \$PATH (read_memo_raw end-to-end)"
else
    PROBE_DIR="$TMPDIR_TEST/probe"
    mkdir -p "$PROBE_DIR"
    (cd "$PROBE_DIR" && agentis memo set probe:key "probe-value-709" >/dev/null 2>&1) || true
    PROBE_OUT="$(cd "$PROBE_DIR" && agentis memo get probe:key 2>/dev/null | tr -d '\r\n ')" || PROBE_OUT=""
    if [ "$PROBE_OUT" != "probe-value-709" ]; then
        echo "[SKIP] 7: installed agentis ($(agentis --version 2>&1)) memo get does not return a clean scalar"
    else
        ACTUAL="$(python3 -c "$PYPATH_PRELUDE
import agentis_memo_freshness as f
v = f.read_memo_raw('$PROBE_DIR', 'probe:key')
print(v if v is not None else 'None')
")"
        if [ "$ACTUAL" = "probe-value-709" ]; then
            pass "7: read_memo_raw(probe:key) returns seeded value"
        else
            fail "7: read_memo_raw seeded" "expected 'probe-value-709', got '$ACTUAL'"
        fi
    fi
fi

# --- Test 8: resolve_tick_interval_ms with explicit fed_tools_dir + cache hit ---
# Build a tiny federation fixture: one colony with a start-colony.sh that
# resolve-tick-interval.py can parse for a fixed tick_interval_for() value.
T8_FED="$TMPDIR_TEST/t8/fed"
mkdir -p "$T8_FED/stub-colony/scripts" "$T8_FED/stub-colony/agents"
cat > "$T8_FED/stub-colony/scripts/start-colony.sh" <<'SH'
#!/bin/bash
tick_interval_for() {
    case "$1" in
        cached_agent) echo 90000 ;;
        *) echo 60000 ;;
    esac
}
SH
chmod +x "$T8_FED/stub-colony/scripts/start-colony.sh"

ACTUAL="$(python3 -c "$PYPATH_PRELUDE
import agentis_memo_freshness as f
# First call: spawns the helper subprocess; should resolve to 90000.
v1 = f.resolve_tick_interval_ms('cached_agent', 'stub-colony', '$T8_FED', fed_tools_dir='$SCRIPT_DIR')
# Sentinel: stash the cache contents so we can verify the 2nd call hits.
cache_after_first = dict(f._tick_interval_cache)
# Replace the cached value with a sentinel; the 2nd call should return
# the sentinel, proving it consulted the cache (no fresh subprocess that
# would have produced 90000 again).
f._tick_interval_cache[('cached_agent', 'stub-colony')] = 12345
v2 = f.resolve_tick_interval_ms('cached_agent', 'stub-colony', '$T8_FED', fed_tools_dir='$SCRIPT_DIR')
print('%d|%d|%s' % (v1, v2, ('cached_agent', 'stub-colony') in cache_after_first))
")"
if [ "$ACTUAL" = "90000|12345|True" ]; then
    pass "8: resolve_tick_interval_ms returns 90000 on first call and hits cache on second"
else
    fail "8: resolve_tick_interval_ms + cache" "expected '90000|12345|True', got '$ACTUAL'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
