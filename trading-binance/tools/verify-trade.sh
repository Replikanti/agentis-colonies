#!/bin/bash
# verify-trade.sh -- deterministic PnL verifier for the trading-binance
# federation (#573 PR-4).
#
# Reads a decision + replay context via env vars and emits a single-line
# JSON verdict on stdout. The verifier is the source of ground truth for
# Phase 1 telemetry; no LLM is invoked here.
#
# Env (required unless noted):
#   DECISION_JSON       Decision payload as produced by strategist.ag:
#                       `{"action":"LONG"|"SHORT"|"FLAT","size":<float>,"setup":<string>,"rationale":<string>}`
#   CONTEXT_TICK        Integer index of the candle row at which the
#                       decision was emitted.
#   HOLD_PERIOD         Integer forward-candle count for settlement.
#   CANDLES_CSV         Path to the unified candle CSV produced by
#                       `tools/load-candles.py` (header + ts,open,high,
#                       low,close,volume rows).
#   SLIPPAGE_BPS        (optional, default 5) Per-side slippage in bps.
#   FUNDING_RATE_BPS    (optional, default 1) Funding rate per 8h period
#                       in bps.
#   TIMEFRAME_MINUTES   (optional, default 30) Candle interval in minutes,
#                       used to compute funding blocks.
#
# PnL formula:
#   direction = {LONG: 1, SHORT: -1, FLAT: 0}[action]
#   if FLAT: pnl_bps = 0, classification = "FLAT"
#   else:
#     entry = candles[CONTEXT_TICK + 1].open
#     exit  = candles[CONTEXT_TICK + 1 + HOLD_PERIOD].open
#     raw_bps        = direction * (exit - entry) / entry * 10000 * size
#     slippage_cost  = 2 * SLIPPAGE_BPS * size       # entry + exit
#     funding_blocks = (HOLD_PERIOD * TIMEFRAME_MINUTES) / 480.0   # 480m = 8h
#     funding_cost   = FUNDING_RATE_BPS * size * funding_blocks
#     pnl_bps        = raw_bps - slippage_cost - funding_cost
#     classification = "WIN" if pnl_bps > 0 else "LOSS"
#
# Stdout (one line):
#   {"verified": true, "pnl_bps": -12.34, "classification": "LOSS",
#    "entry": 60123.45, "exit": 60042.10}
#
# Exit codes:
#   0  success — verdict written to stdout
#   2  CONTEXT_TICK + 1 + HOLD_PERIOD overflows the candle stream
#   3  CANDLES_CSV file missing or unreadable
#   4  DECISION_JSON missing / malformed
#
# Mirrors the shell + embedded-Python pattern in
# `tribes-bench/tools/verify-finding-stage2.sh`: stdin/env passthrough,
# single Python heredoc for the numeric compute, no LLM call.

set -e

DECISION_JSON="${DECISION_JSON:-}"
CONTEXT_TICK="${CONTEXT_TICK:-}"
HOLD_PERIOD="${HOLD_PERIOD:-}"
CANDLES_CSV="${CANDLES_CSV:-}"
SLIPPAGE_BPS="${SLIPPAGE_BPS:-5}"
FUNDING_RATE_BPS="${FUNDING_RATE_BPS:-1}"
TIMEFRAME_MINUTES="${TIMEFRAME_MINUTES:-30}"

if [ -z "$DECISION_JSON" ]; then
    echo "verify-trade: DECISION_JSON env required" >&2
    exit 4
fi

case "$CONTEXT_TICK" in
    ''|*[!0-9]*)
        echo "verify-trade: CONTEXT_TICK must be a non-negative integer (got: '$CONTEXT_TICK')" >&2
        exit 4
        ;;
esac

case "$HOLD_PERIOD" in
    ''|*[!0-9]*)
        echo "verify-trade: HOLD_PERIOD must be a non-negative integer (got: '$HOLD_PERIOD')" >&2
        exit 4
        ;;
esac

if [ -z "$CANDLES_CSV" ] || [ ! -f "$CANDLES_CSV" ]; then
    echo "verify-trade: CANDLES_CSV missing or unreadable: '$CANDLES_CSV'" >&2
    exit 3
fi

python3 - "$DECISION_JSON" "$CONTEXT_TICK" "$HOLD_PERIOD" "$CANDLES_CSV" \
        "$SLIPPAGE_BPS" "$FUNDING_RATE_BPS" "$TIMEFRAME_MINUTES" <<'PYVERIFY'
import csv
import json
import sys

decision_raw = sys.argv[1]
context_tick = int(sys.argv[2])
hold_period = int(sys.argv[3])
candles_csv = sys.argv[4]
slippage_bps = float(sys.argv[5])
funding_rate_bps = float(sys.argv[6])
timeframe_minutes = float(sys.argv[7])

try:
    decision = json.loads(decision_raw)
except Exception as exc:
    sys.stderr.write("verify-trade: malformed DECISION_JSON: " + str(exc) + "\n")
    sys.exit(4)

if not isinstance(decision, dict):
    sys.stderr.write("verify-trade: DECISION_JSON is not an object\n")
    sys.exit(4)

action = str(decision.get("action", "")).upper()
size_raw = decision.get("size", 0.0)
try:
    size = float(size_raw)
except (TypeError, ValueError):
    sys.stderr.write("verify-trade: DECISION_JSON.size is not numeric\n")
    sys.exit(4)

direction_map = {"LONG": 1, "SHORT": -1, "FLAT": 0}
if action not in direction_map:
    sys.stderr.write("verify-trade: DECISION_JSON.action must be LONG | SHORT | FLAT (got: '" + action + "')\n")
    sys.exit(4)
direction = direction_map[action]

with open(candles_csv, "r", newline="") as handle:
    reader = csv.DictReader(handle)
    rows = list(reader)

entry_idx = context_tick + 1
exit_idx = context_tick + 1 + hold_period

# FLAT short-circuits before the overflow check: a FLAT decision is
# verifiable regardless of future-candle availability, since its PnL is
# zero by definition. Non-FLAT decisions need both the entry candle and
# the exit candle to be in range.
if direction == 0:
    verdict = {
        "verified": True,
        "pnl_bps": 0.0,
        "pnl_bps_x100": 0,
        "classification": "FLAT",
        "entry": None,
        "exit": None,
    }
    sys.stdout.write(json.dumps(verdict, separators=(",", ":")) + "\n")
    sys.exit(0)

if entry_idx >= len(rows) or exit_idx >= len(rows):
    sys.stderr.write(
        "verify-trade: context_tick + 1 + hold_period overflows candle stream "
        "(entry_idx=" + str(entry_idx) + " exit_idx=" + str(exit_idx)
        + " len=" + str(len(rows)) + ")\n"
    )
    sys.exit(2)

try:
    entry_price = float(rows[entry_idx]["open"])
    exit_price = float(rows[exit_idx]["open"])
except (KeyError, TypeError, ValueError) as exc:
    sys.stderr.write("verify-trade: failed to read open price (" + str(exc) + ")\n")
    sys.exit(3)

if entry_price <= 0:
    sys.stderr.write("verify-trade: non-positive entry price: " + str(entry_price) + "\n")
    sys.exit(3)

raw_bps = direction * (exit_price - entry_price) / entry_price * 10000.0 * size
slippage_cost = 2.0 * slippage_bps * size
funding_blocks = (hold_period * timeframe_minutes) / 480.0
funding_cost = funding_rate_bps * size * funding_blocks
pnl_bps = raw_bps - slippage_cost - funding_cost

classification = "WIN" if pnl_bps > 0 else "LOSS"

# Emit pnl_bps as integer (bps × 100 = pnl_bps_x100) so the .ag side
# can parse_int() without truncating sub-bp precision to zero. Keeps
# legacy pnl_bps float field for human-readable telemetry / analyser.
# Closes #589.
verdict = {
    "verified": True,
    "pnl_bps": round(pnl_bps, 2),
    "pnl_bps_x100": int(round(pnl_bps * 100)),
    "classification": classification,
    "entry": round(entry_price, 4),
    "exit": round(exit_price, 4),
}
sys.stdout.write(json.dumps(verdict, separators=(",", ":")) + "\n")
PYVERIFY
