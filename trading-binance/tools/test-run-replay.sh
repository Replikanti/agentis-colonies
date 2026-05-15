#!/usr/bin/env bash
# trading-binance/tools/test-run-replay.sh — smoke test for run-replay.sh
# --dry-run mode + load-candles.py wiring (#573 PR-3).
#
# Assertions:
#
#   1. REPLAY_DRY_RUN=1 exits 0
#   2. emit_step transcript names the configured symbol
#   3. emit_step transcript names the configured timeframe
#   4. emit_step transcript names the configured daemon count
#   5. emit_step transcript names the configured lookback window
#   6. emit_step transcript names the configured hold period
#   7. emit_step transcript names the configured replay speed
#   8. Invalid REPLAY_TIMEFRAME=15m rejected with exit 2 + helpful stderr
#   9. Missing data dir rejected (real run: load-candles.py file-not-found)
#  10. REPLAY_DATA_DIR with valid fixture CSV is processed end-to-end
#      (load-candles.py invoked, candles.csv generated in RUN_DIR)
#  11. load-candles.py rejects continuity-gap fixture
#  12. Bootstrap-script generation step is emitted in dry-run output
#  13. Container spawn command is emitted in dry-run output (echo-only)
#  14. Run-meta.json write step is emitted in dry-run output
#  15. Cleanup trap is installed in dry-run output
#
# Standard library only — no pytest, no requests, no live LLM, no podman.
# Self-contained: fixture CSV is generated inline.
#
# Usage: bash trading-binance/tools/test-run-replay.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCH="$SCRIPT_DIR/run-replay.sh"
LOADER="$SCRIPT_DIR/load-candles.py"

PASS=0
FAIL=0

assert_contains() {
    label="$1"; haystack="$2"; needle="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       needle not found: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_eq() {
    label="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       expected: $expected"
        echo "       actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

if [ ! -x "$ORCH" ]; then
    echo "[FAIL] run-replay.sh not executable at $ORCH"
    exit 1
fi
if [ ! -f "$LOADER" ]; then
    echo "[FAIL] load-candles.py missing at $LOADER"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1-7. Dry-run with explicit knobs surfaces every config line.
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

DRY_RC=0
OUT="$(REPLAY_DRY_RUN=1 \
       REPLAY_SYMBOL=BTCUSDT \
       REPLAY_TIMEFRAME=30m \
       REPLAY_DAEMON_COUNT=5 \
       REPLAY_LOOKBACK_WINDOW=200 \
       REPLAY_HOLD_PERIOD=8 \
       REPLAY_SPEED=100 \
       REPLAY_RUN_DIR="$WORK_DIR/run-default" \
       bash "$ORCH" 2>&1)" || DRY_RC=$?

assert_eq "1. REPLAY_DRY_RUN=1 exits 0" "0" "$DRY_RC"
assert_contains "2. emit_step names symbol" "$OUT" "replay symbol: BTCUSDT"
assert_contains "3. emit_step names timeframe" "$OUT" "timeframe: 30m"
assert_contains "4. emit_step names daemon count" "$OUT" "daemon count: 5"
assert_contains "5. emit_step names lookback window" "$OUT" "lookback window: 200"
assert_contains "6. emit_step names hold period" "$OUT" "hold period: 8"
assert_contains "7. emit_step names replay speed" "$OUT" "replay speed: 100"

# ---------------------------------------------------------------------------
# 8. Invalid timeframe rejection.
# ---------------------------------------------------------------------------
INVALID_OUT="$(REPLAY_DRY_RUN=1 REPLAY_TIMEFRAME=15m \
               bash "$ORCH" 2>&1 || true)"
INVALID_RC=0
REPLAY_DRY_RUN=1 REPLAY_TIMEFRAME=15m bash "$ORCH" >/dev/null 2>&1 || INVALID_RC=$?
assert_eq "8a. REPLAY_TIMEFRAME=15m exits 2" "2" "$INVALID_RC"
assert_contains "8b. invalid-timeframe stderr names accepted set" "$INVALID_OUT" \
    "REPLAY_TIMEFRAME must be one of 30m|1h|1d"

# ---------------------------------------------------------------------------
# 9. Missing data dir rejected (real-run: load-candles.py file-not-found).
# Dry-run intentionally does NOT validate the data dir so the plan can be
# emitted without on-disk fixtures; the real-run path delegates to
# load-candles.py which is the single point of "data dir exists" enforcement.
# ---------------------------------------------------------------------------
MISSING_DIR="$WORK_DIR/nonexistent-data"
MISSING_RC=0
REPLAY_DATA_DIR="$MISSING_DIR" REPLAY_SYMBOL=BTCUSDT REPLAY_TIMEFRAME=30m \
    REPLAY_RUN_DIR="$WORK_DIR/run-missing" \
    python3 "$LOADER" --data-dir "$MISSING_DIR" --symbol BTCUSDT \
    --timeframe 30m >/dev/null 2>&1 || MISSING_RC=$?
assert_eq "9. load-candles.py rejects missing data dir with exit 3" "3" "$MISSING_RC"

# ---------------------------------------------------------------------------
# 10. Valid fixture CSV is processed end-to-end: load-candles.py emits a
# unified stream with the documented header and the expected row count.
# Build a tiny 100-row 30m fixture under $WORK_DIR/data/BTCUSDT/30m/.
# ---------------------------------------------------------------------------
FIX_DIR="$WORK_DIR/data/BTCUSDT/30m"
mkdir -p "$FIX_DIR"
FIX_CSV="$FIX_DIR/2026-01-01.csv"
python3 - "$FIX_CSV" 100 <<'PYFIX'
import sys

out_path = sys.argv[1]
n = int(sys.argv[2])
ANCHOR = 1735689600000  # 2025-01-01 00:00 UTC
STEP = 30 * 60 * 1000
header = (
    "timestamp_ms,open,high,low,close,volume,quote_volume,trades,"
    "taker_buy_volume,taker_buy_quote_volume"
)
with open(out_path, "w") as f:
    f.write(header + "\n")
    for i in range(n):
        ts = ANCHOR + i * STEP
        row = [str(ts), "100", "101", "99", "100", "10", "1000", "5", "5", "500"]
        f.write(",".join(row) + "\n")
PYFIX

CANDLES_OUT="$WORK_DIR/candles-fixture.csv"
LOADER_RC=0
python3 "$LOADER" --data-dir "$WORK_DIR/data" --symbol BTCUSDT \
    --timeframe 30m >"$CANDLES_OUT" 2>"$WORK_DIR/loader-stderr" || LOADER_RC=$?
assert_eq "10a. load-candles.py exits 0 on valid fixture" "0" "$LOADER_RC"
loader_header=$(head -1 "$CANDLES_OUT")
assert_eq "10b. load-candles.py header matches contract" \
    "timestamp_ms,open,high,low,close,volume,quote_volume,trades,taker_buy_volume,taker_buy_quote_volume" \
    "$loader_header"
loader_rows=$(( $(wc -l <"$CANDLES_OUT") - 1 ))
assert_eq "10c. load-candles.py emits 100 data rows" "100" "$loader_rows"

# 10d. End-to-end: REPLAY_DRY_RUN=1 against the fixture data dir surfaces
# the fixture path in the plan transcript (validates data-dir threading).
FIXTURE_OUT="$(REPLAY_DRY_RUN=1 \
               REPLAY_DATA_DIR="$WORK_DIR/data" \
               REPLAY_SYMBOL=BTCUSDT \
               REPLAY_TIMEFRAME=30m \
               REPLAY_RUN_DIR="$WORK_DIR/run-fixture" \
               bash "$ORCH" 2>&1)"
assert_contains "10d. fixture data-dir threaded into orchestrator output" \
    "$FIXTURE_OUT" "data dir: $WORK_DIR/data"
assert_contains "10e. load-candles.py invocation visible in dry-run" \
    "$FIXTURE_OUT" "python3 $LOADER --data-dir $WORK_DIR/data --symbol BTCUSDT --timeframe 30m"

# ---------------------------------------------------------------------------
# 11. load-candles.py rejects a continuity gap > 2x interval.
# Build a 30m fixture where row 50 jumps 4 hours forward (8x the step).
# ---------------------------------------------------------------------------
GAP_DIR="$WORK_DIR/gap-data/BTCUSDT/30m"
mkdir -p "$GAP_DIR"
GAP_CSV="$GAP_DIR/2026-01-01.csv"
python3 - "$GAP_CSV" <<'PYGAP'
import sys

out_path = sys.argv[1]
ANCHOR = 1735689600000  # 2025-01-01 00:00 UTC
STEP = 30 * 60 * 1000
JUMP = 8 * STEP  # 4h gap = 8x step, breaks the 2x cap
header = (
    "timestamp_ms,open,high,low,close,volume,quote_volume,trades,"
    "taker_buy_volume,taker_buy_quote_volume"
)
with open(out_path, "w") as f:
    f.write(header + "\n")
    ts = ANCHOR
    for i in range(60):
        row = [str(ts), "100", "101", "99", "100", "10", "1000", "5", "5", "500"]
        f.write(",".join(row) + "\n")
        ts += JUMP if i == 50 else STEP
PYGAP

GAP_RC=0
python3 "$LOADER" --data-dir "$WORK_DIR/gap-data" --symbol BTCUSDT \
    --timeframe 30m >/dev/null 2>"$WORK_DIR/gap-stderr" || GAP_RC=$?
assert_eq "11. load-candles.py rejects continuity-gap fixture with exit 4" \
    "4" "$GAP_RC"

# ---------------------------------------------------------------------------
# 12-15. Bootstrap, spawn, run-meta, cleanup-trap steps are all emitted.
# ---------------------------------------------------------------------------
assert_contains "12. bootstrap-script generation step emitted" "$OUT" \
    "generating bootstrap script"
assert_contains "13. container spawn command emitted via echo prefix" "$OUT" \
    "+ podman run -d --name replay-laptop"
assert_contains "14. run-meta.json write step emitted" "$OUT" \
    "writing run-meta.json"
assert_contains "15. cleanup trap installed" "$OUT" \
    "trap 'podman stop --time 5 replay-laptop"

# Header-doc sanity (env vars documented).
SRC="$(cat "$ORCH")"
assert_contains "header documents REPLAY_DATA_DIR" "$SRC" "REPLAY_DATA_DIR"
assert_contains "header documents REPLAY_SYMBOL" "$SRC" "REPLAY_SYMBOL"
assert_contains "header documents REPLAY_TIMEFRAME" "$SRC" "REPLAY_TIMEFRAME"
assert_contains "header documents REPLAY_SPEED" "$SRC" "REPLAY_SPEED"
assert_contains "header documents REPLAY_DAEMON_COUNT" "$SRC" "REPLAY_DAEMON_COUNT"
assert_contains "header documents REPLAY_LOOKBACK_WINDOW" "$SRC" "REPLAY_LOOKBACK_WINDOW"
assert_contains "header documents REPLAY_HOLD_PERIOD" "$SRC" "REPLAY_HOLD_PERIOD"
assert_contains "header documents REPLAY_DRY_RUN" "$SRC" "REPLAY_DRY_RUN"
assert_contains "header documents REPLAY_RUN_DIR" "$SRC" "REPLAY_RUN_DIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
