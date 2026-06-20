#!/usr/bin/env python3
"""intraday-xs.py -- intraday cross-sectional long-short backtest on HOURLY bars
(#1201). The intraday counterpart to the daily cross-sectional momentum (#1194):
at short horizons crypto's documented cross-sectional edge flips from momentum to
REVERSAL (overreaction snapback). Rank alts by trailing L-hour return, long the
losers / short the winners (reversal) -- and the momentum sign for contrast --
hold H hours, rebalance, walk-forward.

Honest prior: intraday is the most arbed timeframe and turnover cost (many
rebalances/day) dominates -- the per-trade reversal edge is a few bps and a
~6-10 bps round-trip can eat it. This tests, after realistic intraday cost,
whether anything survives.

Walk-forward on a regular hourly grid (no look-ahead): at bar i, selection return
= close[i]/close[i-L] (PAST); realised = close[i+H]/close[i] (FUTURE); step i by
H. Standard library only. Hourly perp klines from fapi.binance.com.
"""
import argparse
import datetime
import json
import math
import sys
import urllib.request

HOUR_MS = 3600000


def epoch_ms(s):
    if s.isdigit():
        return int(s)
    return int(datetime.datetime.strptime(s, "%Y-%m-%d").replace(
        tzinfo=datetime.timezone.utc).timestamp() * 1000)


def hourly_closes(symbol, start, end):
    out = {}
    cur = start
    while cur < end:
        url = ("https://fapi.binance.com/fapi/v1/klines?symbol=%s&interval=1h&startTime=%d&endTime=%d&limit=1000"
               % (symbol, cur, end))
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                batch = json.load(r)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write("klines %s err: %s\n" % (symbol, e))
            return out
        if not batch:
            break
        for k in batch:
            out[k[0]] = float(k[4])
        cur = batch[-1][0] + 1
        if len(batch) < 1000:
            break
    return out


def stdev(xs):
    n = len(xs)
    if n < 2:
        return 0.0
    m = sum(xs) / n
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (n - 1))


def run(closes, grid, lookback_h, hold_h, top_k, reversal, cost_rt):
    cost = cost_rt / 10000.0
    rets = []
    prev_long, prev_short = set(), set()
    i = lookback_h
    n = len(grid)
    while i + hold_h < n:
        t_lb, t_now, t_fwd = grid[i - lookback_h], grid[i], grid[i + hold_h]
        trailing, forward = {}, {}
        for s, cl in closes.items():
            if t_lb in cl and t_now in cl and t_fwd in cl and cl[t_lb] > 0 and cl[t_now] > 0:
                trailing[s] = cl[t_now] / cl[t_lb] - 1.0
                forward[s] = cl[t_fwd] / cl[t_now] - 1.0
        if len(trailing) < 2 * top_k:
            i += hold_h
            continue
        # reversal: long the LOSERS (bottom), short the WINNERS (top)
        ranked = sorted(trailing, key=lambda s: trailing[s])  # ascending = losers first
        if reversal:
            longs, shorts = set(ranked[:top_k]), set(ranked[-top_k:])
        else:  # momentum
            longs, shorts = set(ranked[-top_k:]), set(ranked[:top_k])
        gross = sum(forward[s] for s in longs) / len(longs) - sum(forward[s] for s in shorts) / len(shorts)
        changed = len(longs ^ prev_long) + len(shorts ^ prev_short)
        turn = (changed / 2.0) / (2.0 * top_k)
        rets.append(gross - cost * turn)
        prev_long, prev_short = longs, shorts
        i += hold_h
    if len(rets) < 10:
        return None
    total = sum(rets)
    reb_per_year = (365.0 * 24.0) / hold_h
    sd = stdev(rets)
    sharpe = (total / len(rets)) / sd * math.sqrt(reb_per_year) if sd > 0 else 0.0
    peak = mdd = acc = 0.0
    for r in rets:
        acc += r
        peak = max(peak, acc)
        mdd = max(mdd, peak - acc)
    return {
        "rebalances": len(rets),
        "ann_pct": round(total * reb_per_year / len(rets) * 100, 2),
        "sharpe": round(sharpe, 2),
        "max_dd_pct": round(mdd * 100, 1),
        "avg_per_reb_bps": round(total / len(rets) * 10000, 2),
    }


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbols", required=True)
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    ap.add_argument("--top-k", type=int, default=4)
    ap.add_argument("--cost-bps-roundtrip", type=float, default=8.0)
    ap.add_argument("--lookbacks", default="1,2,4,6")
    ap.add_argument("--holds", default="1,2,4")
    args = ap.parse_args(argv)

    symbols = [s.strip().upper() for s in args.symbols.split(",") if s.strip()]
    start, end = epoch_ms(args.start), epoch_ms(args.end)
    closes = {}
    for s in symbols:
        cl = hourly_closes(s, start, end)
        if len(cl) > 200:
            closes[s] = cl
    if len(closes) < 6:
        sys.stderr.write("not enough symbols\n")
        return 2
    grid = sorted(set().union(*[set(c) for c in closes.values()]))

    out = {"symbols_loaded": len(closes), "hours": len(grid), "cost_bps": args.cost_bps_roundtrip, "results": []}
    for lb in [int(x) for x in args.lookbacks.split(",")]:
        for h in [int(x) for x in args.holds.split(",")]:
            for reversal in (True, False):
                r = run(closes, grid, lb, h, args.top_k, reversal, args.cost_bps_roundtrip)
                if r:
                    r["lookback_h"], r["hold_h"] = lb, h
                    r["signal"] = "reversal" if reversal else "momentum"
                    out["results"].append(r)
    out["results"].sort(key=lambda r: -r["sharpe"])
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
