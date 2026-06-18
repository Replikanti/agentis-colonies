#!/usr/bin/env python3
"""backtest-fade-signal.py -- deterministic reference backtest of the
tribe-zeta volume-divergence FADE signal (issue #1123).

This is the honest "does the signal even work" gate. It is a DETERMINISTIC
reference implementation of the fade thesis encoded in
`tribe-zeta/agents/strategist.ag`'s seed prompt -- it is NOT the LLM
strategist's realised behaviour, and it does not run the other five tribes.
Decisions are settled by the repo's own ground-truth verifier
(`tools/verify-trade.sh`), the exact settler the replay uses, so the PnL
numbers match what a replay would record for the same decisions.

Signal (per candle i, faithful to the seed prompt, raw OHLCV + volMA(20) only):
  volMA = SMA(volume, VOL_MA) over the trailing VOL_MA candles ending at i.
  new L-bar high  = high[i] > max(high[i-L .. i-1])
  new L-bar low   = low[i]  < min(low[i-L .. i-1])
    new high AND volume[i] <= volMA -> SHORT (fade the unconfirmed breakout)
    new low  AND volume[i] <= volMA -> LONG  (fade the unconfirmed breakdown)
    otherwise                        -> FLAT (incl. "volume confirms": at an
                                              extreme but volume[i] > volMA)
  size fixed at 1.0 (deterministic baseline; per-trade bps directly comparable).

Settlement: each non-FLAT decision -> tools/verify-trade.sh with
CONTEXT_TICK=i, HOLD_PERIOD, TIMEFRAME_MINUTES (60 for 1h), SLIPPAGE_BPS,
FUNDING_RATE_BPS. FLAT = 0 bps by definition (not sent to the verifier).

Baseline for the verdict = FLAT (always 0 bps, no trades, no costs).

Standard library only.
"""
import argparse
import csv
import json
import math
import os
import subprocess
import sys


def parse_args(argv):
    p = argparse.ArgumentParser(description="Deterministic fade-signal backtest (#1123).")
    p.add_argument("--candles", required=True, help="Unified candle CSV (from load-candles.py).")
    p.add_argument("--verifier", required=True, help="Path to tools/verify-trade.sh.")
    p.add_argument("--hold-period", type=int, default=8)
    p.add_argument("--vol-ma", type=int, default=20)
    p.add_argument("--timeframe-minutes", type=int, default=60, help="1h = 60 (NOT the verifier's 30 default).")
    p.add_argument("--slippage-bps", type=float, default=5.0)
    p.add_argument("--funding-rate-bps", type=float, default=1.0)
    p.add_argument("--lookbacks", default="20,50,100", help="Comma list of local-extreme lookback windows to sweep.")
    p.add_argument("--size", type=float, default=1.0)
    return p.parse_args(argv)


def load_candles(path):
    with open(path, "r", newline="") as fh:
        rows = list(csv.DictReader(fh))
    out = []
    for r in rows:
        out.append({
            "open": float(r["open"]),
            "high": float(r["high"]),
            "low": float(r["low"]),
            "close": float(r["close"]),
            "volume": float(r["volume"]),
        })
    return out


def settle(verifier, action, size, tick, hold, candles_csv, slip, funding, tf_min):
    """Call the repo verifier for one decision; return pnl_bps (float)."""
    env = dict(os.environ)
    env["DECISION_JSON"] = json.dumps({"action": action, "size": size, "setup": "volume_divergence", "rationale": "deterministic fade backtest"})
    env["CONTEXT_TICK"] = str(tick)
    env["HOLD_PERIOD"] = str(hold)
    env["CANDLES_CSV"] = candles_csv
    env["SLIPPAGE_BPS"] = str(slip)
    env["FUNDING_RATE_BPS"] = str(funding)
    env["TIMEFRAME_MINUTES"] = str(tf_min)
    proc = subprocess.run(["bash", verifier], env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError("verifier failed (rc=%d) tick=%d: %s" % (proc.returncode, tick, proc.stderr.strip()))
    verdict = json.loads(proc.stdout.strip())
    return float(verdict["pnl_bps"]), verdict["classification"]


def signal_for(candles, i, lookback, vol_ma):
    """Return 'LONG' | 'SHORT' | 'FLAT' for candle i under the fade rules."""
    if i < lookback or i < vol_ma:
        return "FLAT"
    vol_window = [candles[j]["volume"] for j in range(i - vol_ma, i)]
    vma = sum(vol_window) / float(vol_ma)
    prior_highs = [candles[j]["high"] for j in range(i - lookback, i)]
    prior_lows = [candles[j]["low"] for j in range(i - lookback, i)]
    new_high = candles[i]["high"] > max(prior_highs)
    new_low = candles[i]["low"] < min(prior_lows)
    weak_volume = candles[i]["volume"] <= vma
    # A bar that is simultaneously a new high and a new low (huge outside bar)
    # is ambiguous -> FLAT.
    if new_high and not new_low and weak_volume:
        return "SHORT"
    if new_low and not new_high and weak_volume:
        return "LONG"
    return "FLAT"


def metrics_for_lookback(candles, candles_csv, lookback, args):
    last_tradable = len(candles) - 1 - 1 - args.hold_period  # need entry i+1 and exit i+1+hold in range
    pnls = []
    wins = 0
    longs = 0
    shorts = 0
    flats = 0
    for i in range(len(candles)):
        if i > last_tradable:
            # decisions beyond here cannot be settled; count remaining as FLAT
            flats += 1
            continue
        action = signal_for(candles, i, lookback, args.vol_ma)
        if action == "FLAT":
            flats += 1
            continue
        pnl, classification = settle(args.verifier, action, args.size, i, args.hold_period,
                                     candles_csv, args.slippage_bps, args.funding_rate_bps,
                                     args.timeframe_minutes)
        pnls.append(pnl)
        if classification == "WIN":
            wins += 1
        if action == "LONG":
            longs += 1
        else:
            shorts += 1
    n = len(pnls)
    total = sum(pnls)
    mean = total / n if n else 0.0
    win_rate = (wins / n * 100.0) if n else 0.0
    # per-trade Sharpe = mean / stddev (population) over realised trades
    if n > 1:
        var = sum((x - mean) ** 2 for x in pnls) / n
        sd = math.sqrt(var)
        sharpe = mean / sd if sd > 0 else 0.0
    else:
        sharpe = 0.0
    # max drawdown (bps) on the cumulative PnL curve over the trade sequence
    peak = 0.0
    cum = 0.0
    max_dd = 0.0
    for x in pnls:
        cum += x
        peak = max(peak, cum)
        max_dd = max(max_dd, peak - cum)
    return {
        "lookback": lookback,
        "trades": n,
        "longs": longs,
        "shorts": shorts,
        "flats": flats,
        "win_rate_pct": round(win_rate, 1),
        "total_pnl_bps": round(total, 2),
        "mean_pnl_bps": round(mean, 3),
        "max_drawdown_bps": round(max_dd, 2),
        "per_trade_sharpe": round(sharpe, 4),
    }


def buy_and_hold_bps(candles, args):
    """Reference: LONG the whole tradable window, size 1.0, net of one round-trip cost."""
    first = candles[0]["open"]
    last = candles[-1]["open"]
    raw = (last - first) / first * 10000.0 * args.size
    slippage = 2.0 * args.slippage_bps * args.size
    # funding over the whole window
    blocks = (len(candles) * args.timeframe_minutes) / 480.0
    funding = args.funding_rate_bps * args.size * blocks
    return round(raw - slippage - funding, 2), round(raw, 2)


def main(argv):
    args = parse_args(argv)
    candles = load_candles(args.candles)
    lookbacks = [int(x) for x in args.lookbacks.split(",") if x.strip()]
    results = [metrics_for_lookback(candles, args.candles, L, args) for L in lookbacks]
    bh_net, bh_raw = buy_and_hold_bps(candles, args)
    out = {
        "window_candles": len(candles),
        "hold_period": args.hold_period,
        "vol_ma": args.vol_ma,
        "timeframe_minutes": args.timeframe_minutes,
        "slippage_bps": args.slippage_bps,
        "funding_rate_bps": args.funding_rate_bps,
        "size": args.size,
        "flat_baseline_total_pnl_bps": 0.0,
        "buy_and_hold_net_bps": bh_net,
        "buy_and_hold_raw_bps": bh_raw,
        "results_by_lookback": results,
    }
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main(sys.argv[1:])
