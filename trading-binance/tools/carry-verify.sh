#!/usr/bin/env bash
# carry-verify.sh -- deterministic settlement verifier for a delta-neutral
# funding-CARRY basket decision (#1175 M1). The carry analogue of
# verify-trade.sh.
#
# A delta-neutral carry position (short perp + long spot) has ~zero directional
# PnL -- the two legs cancel -- so the realised return over a forward window is
# the funding collected: when funding > 0 the short-perp leg RECEIVES it. The
# net return of a basket is the weighted sum of each symbol's forward funding,
# minus the turnover cost of changing the basket vs the previous one.
#
# Inputs (env):
#   DECISION_JSON        Basket: {"positions":[{"symbol":"LINKUSDT","weight":0.25},...]}.
#                        Empty positions / weights summing to 0 = cash (FLAT).
#                        Weights are fractions of capital; remainder = cash (0 carry).
#   FUNDING_DIR          Dir of per-symbol funding CSVs <SYM>.csv
#                        (header fundingTime,fundingRate; as written by
#                        tools/funding-download.py).
#   SETTLE_START         Forward window start, epoch ms (inclusive).
#   SETTLE_END           Forward window end, epoch ms (exclusive).
#   COST_BPS_ROUNDTRIP   (optional, default 20) round-trip cost in bps applied
#                        to basket turnover (both legs).
#   PREV_POSITIONS_JSON  (optional, default empty) previous basket positions,
#                        same shape as DECISION_JSON.positions, for turnover.
#
# Settlement:
#   fwd_funding_s   = sum of fundingRate for symbol s in [SETTLE_START, SETTLE_END)
#   carry_bps       = sum_s weight_s * fwd_funding_s * 10000
#   turnover        = sum_s |weight_new_s - weight_prev_s|         # one-way x2 over a full cycle
#   turnover_cost_bps = COST_BPS_ROUNDTRIP * turnover / 2          # amortised round-trip
#   net_bps         = carry_bps - turnover_cost_bps
#
# Output (stdout, single-line JSON):
#   {"verified":true,"carry_bps":..,"turnover_cost_bps":..,"net_bps":..,
#    "per_symbol":[{"symbol":..,"weight":..,"funding_bps":..}, ...]}
#
# Exit codes: 0 ok; 2 bad/missing args.
set -euo pipefail

DECISION_JSON="${DECISION_JSON:-}"
FUNDING_DIR="${FUNDING_DIR:-}"
SETTLE_START="${SETTLE_START:-}"
SETTLE_END="${SETTLE_END:-}"
COST_BPS_ROUNDTRIP="${COST_BPS_ROUNDTRIP:-20}"
PREV_POSITIONS_JSON="${PREV_POSITIONS_JSON:-}"

if [ -z "$DECISION_JSON" ]; then
    echo "carry-verify: DECISION_JSON is required" >&2; exit 2
fi
if [ -z "$FUNDING_DIR" ] || [ ! -d "$FUNDING_DIR" ]; then
    echo "carry-verify: FUNDING_DIR must be an existing directory (got: '$FUNDING_DIR')" >&2; exit 2
fi
case "$SETTLE_START" in ''|*[!0-9]*) echo "carry-verify: SETTLE_START must be epoch ms (got: '$SETTLE_START')" >&2; exit 2;; esac
case "$SETTLE_END" in ''|*[!0-9]*) echo "carry-verify: SETTLE_END must be epoch ms (got: '$SETTLE_END')" >&2; exit 2;; esac

python3 - "$DECISION_JSON" "$FUNDING_DIR" "$SETTLE_START" "$SETTLE_END" \
         "$COST_BPS_ROUNDTRIP" "$PREV_POSITIONS_JSON" <<'PYCARRY'
import sys, json, csv, os

decision_raw, funding_dir, start_s, end_s, cost_rt_s, prev_raw = sys.argv[1:7]
start = int(start_s); end = int(end_s)
try:
    cost_rt = float(cost_rt_s)
except ValueError:
    cost_rt = 20.0


def parse_positions(raw):
    if not raw or not raw.strip():
        return {}
    try:
        obj = json.loads(raw)
    except Exception:
        return {}
    if isinstance(obj, dict):
        pos = obj.get("positions", [])
    elif isinstance(obj, list):
        pos = obj
    else:
        pos = []
    out = {}
    for p in pos:
        try:
            sym = str(p["symbol"]).upper()
            w = float(p.get("weight", 0.0))
        except Exception:
            continue
        if sym:
            out[sym] = out.get(sym, 0.0) + w
    return out


def fwd_funding(sym):
    path = os.path.join(funding_dir, sym + ".csv")
    if not os.path.isfile(path):
        return None
    total = 0.0
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            try:
                t = int(r["fundingTime"]); fr = float(r["fundingRate"])
            except Exception:
                continue
            if start <= t < end:
                total += fr
    return total


cur = parse_positions(decision_raw)
prev = parse_positions(prev_raw)

carry_bps = 0.0
per_symbol = []
for sym in sorted(cur.keys()):
    w = cur[sym]
    f = fwd_funding(sym)
    f_eff = f if f is not None else 0.0
    contrib = w * f_eff * 10000.0
    carry_bps += contrib
    per_symbol.append({
        "symbol": sym,
        "weight": round(w, 6),
        "funding_bps": round(f_eff * 10000.0, 4),
        "missing_data": f is None,
    })

# turnover = sum over the union of symbols of |w_new - w_prev|
syms = set(cur) | set(prev)
turnover = sum(abs(cur.get(s, 0.0) - prev.get(s, 0.0)) for s in syms)
turnover_cost_bps = cost_rt * turnover / 2.0
net_bps = carry_bps - turnover_cost_bps

verdict = {
    "verified": True,
    "carry_bps": round(carry_bps, 4),
    "turnover_cost_bps": round(turnover_cost_bps, 4),
    "net_bps": round(net_bps, 4),
    "gross_weight": round(sum(cur.values()), 6),
    "per_symbol": per_symbol,
}
sys.stdout.write(json.dumps(verdict, separators=(",", ":")))
PYCARRY
