#!/usr/bin/env python3
"""backtest-momentum-rmultiple.py -- deterministic momentum/breakout backtest
under the R-multiple exit model (issue #1154, follow-up to #1148).

The honest "does the lever move the goal" gate. Tests whether a positive-skew
**momentum** signal settled by the **R-multiple** verifier (small stop, larger
target) produces a positive EXPECTANCY on the same real BTCUSDT window where
the #1123 deterministic FADE (negative skew, fixed-time exit) lost (-360 bps).

It is a DETERMINISTIC reference signal, NOT the LLM strategist. Decisions are
settled by the repo's own ground-truth verifier (tools/verify-trade.sh) with
its #1148 R-multiple stop/target exits, so the PnL is what a replay would
record for the same decisions.

Signal (momentum / breakout -- the inverse of the fade; enter WITH confirmed moves):
  volMA = SMA(volume, VOL_MA) over the trailing VOL_MA candles ending at i.
  new L-bar high = high[i] > max(high[i-L .. i-1]); new L-bar low = low[i] < min(...).
  confirmed = volume[i] >= volMA (genuine move, not a thin/manipulated one).
    new high AND confirmed AND not new low -> LONG  (ride the breakout up)
    new low  AND confirmed AND not new high -> SHORT (ride the breakdown)
    otherwise                                -> FLAT
  size fixed at 1.0.

Exit: R-multiple via verify-trade.sh -- STOP_BPS / TARGET_BPS (swept), small
stop + larger target = asymmetric payoff (low win rate, larger winners). FLAT
= 0 bps, not sent to the verifier.

Reports per R-multiple config: trades, win rate (expected LOW), total + mean
PnL bps (= expectancy), PROFIT FACTOR (gross win / gross loss), max drawdown,
and the exit_reason breakdown (stop / target / time). Baselines: FLAT (0),
the #1123 fade (-360 bps), buy-and-hold.

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
    p = argparse.ArgumentParser(description="Momentum + R-multiple backtest (#1154).")
    p.add_argument("--candles", required=True)
    p.add_argument("--verifier", required=True)
    p.add_argument("--hold-period", type=int, default=8)
    p.add_argument("--vol-ma", type=int, default=20)
    p.add_argument("--lookback", type=int, default=20)
    p.add_argument("--timeframe-minutes", type=int, default=60)
    p.add_argument("--slippage-bps", type=float, default=5.0)
    p.add_argument("--funding-rate-bps", type=float, default=1.0)
    p.add_argument("--size", type=float, default=1.0)
    # R-multiple sweep: each entry is "stop_bps:target_bps".
    p.add_argument("--r-configs", default="100:100,100:200,100:300")
    return p.parse_args(argv)


def load_candles(path):
    with open(path, "r", newline="") as fh:
        rows = list(csv.DictReader(fh))
    return [{
        "open": float(r["open"]), "high": float(r["high"]),
        "low": float(r["low"]), "close": float(r["close"]),
        "volume": float(r["volume"]),
    } for r in rows]


def settle(verifier, action, size, tick, hold, candles_csv, slip, funding, tf_min, stop_bps, target_bps):
    env = dict(os.environ)
    env["DECISION_JSON"] = json.dumps({"action": action, "size": size, "setup": "momentum", "rationale": "deterministic momentum r-multiple backtest"})
    env["CONTEXT_TICK"] = str(tick)
    env["HOLD_PERIOD"] = str(hold)
    env["CANDLES_CSV"] = candles_csv
    env["SLIPPAGE_BPS"] = str(slip)
    env["FUNDING_RATE_BPS"] = str(funding)
    env["TIMEFRAME_MINUTES"] = str(tf_min)
    env["STOP_BPS"] = str(stop_bps)
    env["TARGET_BPS"] = str(target_bps)
    proc = subprocess.run(["bash", verifier], env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError("verifier rc=%d tick=%d: %s" % (proc.returncode, tick, proc.stderr.strip()))
    v = json.loads(proc.stdout.strip())
    return float(v["pnl_bps"]), v["classification"], v.get("exit_reason", "time")


def signal_for(candles, i, lookback, vol_ma):
    """Momentum/breakout: enter WITH a confirmed new extreme."""
    if i < lookback or i < vol_ma:
        return "FLAT"
    vma = sum(candles[j]["volume"] for j in range(i - vol_ma, i)) / float(vol_ma)
    prior_highs = [candles[j]["high"] for j in range(i - lookback, i)]
    prior_lows = [candles[j]["low"] for j in range(i - lookback, i)]
    new_high = candles[i]["high"] > max(prior_highs)
    new_low = candles[i]["low"] < min(prior_lows)
    confirmed = candles[i]["volume"] >= vma
    if new_high and confirmed and not new_low:
        return "LONG"
    if new_low and confirmed and not new_high:
        return "SHORT"
    return "FLAT"


def metrics(candles, candles_csv, args, stop_bps, target_bps):
    last_tradable = len(candles) - 1 - 1 - args.hold_period
    pnls, longs, shorts, wins = [], 0, 0, 0
    flats = 0
    reasons = {"stop": 0, "target": 0, "time": 0}
    for i in range(len(candles)):
        if i > last_tradable:
            flats += 1
            continue
        action = signal_for(candles, i, args.lookback, args.vol_ma)
        if action == "FLAT":
            flats += 1
            continue
        pnl, cls, reason = settle(args.verifier, action, args.size, i, args.hold_period,
                                  candles_csv, args.slippage_bps, args.funding_rate_bps,
                                  args.timeframe_minutes, stop_bps, target_bps)
        pnls.append(pnl)
        reasons[reason] = reasons.get(reason, 0) + 1
        if cls == "WIN":
            wins += 1
        if action == "LONG":
            longs += 1
        else:
            shorts += 1
    n = len(pnls)
    total = sum(pnls)
    mean = total / n if n else 0.0
    win_rate = (wins / n * 100.0) if n else 0.0
    gross_win = sum(x for x in pnls if x > 0)
    gross_loss = -sum(x for x in pnls if x < 0)
    profit_factor = (gross_win / gross_loss) if gross_loss > 0 else (float("inf") if gross_win > 0 else 0.0)
    peak = cum = max_dd = 0.0
    for x in pnls:
        cum += x
        peak = max(peak, cum)
        max_dd = max(max_dd, peak - cum)
    return {
        "stop_bps": stop_bps, "target_bps": target_bps,
        "r_multiple": round(target_bps / stop_bps, 2) if stop_bps else None,
        "trades": n, "longs": longs, "shorts": shorts, "flats": flats,
        "win_rate_pct": round(win_rate, 1),
        "total_pnl_bps": round(total, 2),
        "mean_pnl_bps_expectancy": round(mean, 3),
        "profit_factor": (round(profit_factor, 3) if profit_factor != float("inf") else "inf"),
        "max_drawdown_bps": round(max_dd, 2),
        "exit_reasons": reasons,
    }


def buy_and_hold_bps(candles, args):
    first, last = candles[0]["open"], candles[-1]["open"]
    raw = (last - first) / first * 10000.0 * args.size
    slippage = 2.0 * args.slippage_bps * args.size
    blocks = (len(candles) * args.timeframe_minutes) / 480.0
    funding = args.funding_rate_bps * args.size * blocks
    return round(raw - slippage - funding, 2)


def main(argv):
    args = parse_args(argv)
    candles = load_candles(args.candles)
    configs = []
    for spec in args.r_configs.split(","):
        s, t = spec.split(":")
        configs.append((float(s), float(t)))
    results = [metrics(candles, args.candles, args, s, t) for s, t in configs]
    out = {
        "window_candles": len(candles),
        "hold_period": args.hold_period, "vol_ma": args.vol_ma, "lookback": args.lookback,
        "timeframe_minutes": args.timeframe_minutes,
        "slippage_bps": args.slippage_bps, "funding_rate_bps": args.funding_rate_bps,
        "size": args.size,
        "flat_baseline_total_pnl_bps": 0.0,
        "fade_1123_total_pnl_bps_L20": -360.02,
        "buy_and_hold_net_bps": buy_and_hold_bps(candles, args),
        "results_by_r_multiple": results,
    }
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main(sys.argv[1:])
