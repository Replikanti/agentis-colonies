#!/usr/bin/env python3
"""xsectional-paper.py -- periodic paper-trade snapshot for the cross-sectional
momentum trading strategy (#1197). The live forward gate, the long-short analogue
of carry-paper.py. Tracks what the vol-targeted cross-sectional book WOULD do,
accumulating a real out-of-sample record marked by realised price returns.

Run periodically (e.g. weekly via cron) on the #1194/#1197 winning config
(weekly / top-4 / 30-day lookback, vol-targeted to a chosen annualised vol).
Each run:
  1. fetch daily closes for the universe (live fapi, or --klines-file for tests);
  2. RANK by trailing --lookback-days return; LONG top-K / SHORT bottom-K,
     dollar-neutral (#1194);
  3. SETTLE the prior snapshot: realised forward return of the prior basket over
     [prior_ts, now] = mean(longs) - mean(shorts), times the prior leverage,
     minus turnover cost of rebalancing prior->new; append period net + cumulative;
  4. SIZE the new book by TRAILING-VOL TARGETING (#1197): leverage =
     target_per_period_vol / trailing realised vol of past period returns (PAST
     only, no look-ahead), capped at --max-leverage.

Ledger is JSON-lines (gitignored, runtime state). Standard library only.
"""
import argparse
import datetime
import json
import math
import os
import sys
import urllib.request

DAY_MS = 86400000


def epoch_ms(s):
    if s.isdigit():
        return int(s)
    return int(datetime.datetime.strptime(s, "%Y-%m-%d").replace(
        tzinfo=datetime.timezone.utc).timestamp() * 1000)


def daily_closes(symbol, start, end):
    out = {}
    cur = start
    while cur < end:
        url = ("https://fapi.binance.com/fapi/v1/klines?symbol=%s&interval=1d&startTime=%d&endTime=%d&limit=1000"
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


def load_series(symbols, start, end, klines_file):
    if klines_file:
        raw = json.load(open(klines_file))
        return {s: {int(t): float(c) for t, c in raw[s].items()} for s in symbols if s in raw}
    series = {}
    for s in symbols:
        cl = daily_closes(s, start, end)
        if len(cl) > 1:
            series[s] = cl
    return series


def close_at(days_sorted, ts):
    best = None
    for d in days_sorted:
        if d <= ts:
            best = d
        else:
            break
    return best


def stdev(xs):
    n = len(xs)
    if n < 2:
        return 0.0
    m = sum(xs) / n
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (n - 1))


def ledger_rows(path):
    if not os.path.isfile(path):
        return []
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbols", required=True)
    ap.add_argument("--ledger", required=True)
    ap.add_argument("--top-k", type=int, default=4)
    ap.add_argument("--lookback-days", type=int, default=30)
    ap.add_argument("--cost-bps-roundtrip", type=float, default=60.0)
    ap.add_argument("--rebalance-days", type=int, default=7,
                    help="cadence for vol annualisation (informational; run at this period)")
    ap.add_argument("--target-vol-pct", type=float, default=20.0)
    ap.add_argument("--vol-window", type=int, default=8)
    ap.add_argument("--max-leverage", type=float, default=3.0)
    ap.add_argument("--now", type=int, default=None)
    ap.add_argument("--start", default="2024-01-01")
    ap.add_argument("--klines-file", default=None, help="JSON {sym:{ts:close}} override for tests")
    args = ap.parse_args(argv)

    symbols = [s.strip().upper() for s in args.symbols.split(",") if s.strip()]
    end = (args.now + DAY_MS) if args.now is not None else epoch_ms(
        datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")) + DAY_MS
    series = load_series(symbols, epoch_ms(args.start), end, args.klines_file)
    if len(series) < 2 * args.top_k:
        sys.stderr.write("xsectional-paper: not enough symbols with data\n")
        return 2
    days_sorted = sorted(set().union(*[set(c) for c in series.values()]))
    now = args.now if args.now is not None else days_sorted[-1]
    cost = args.cost_bps_roundtrip / 10000.0

    # 2. rank trailing return -> long top-K / short bottom-K
    t_lb, t_now = close_at(days_sorted, now - args.lookback_days * DAY_MS), close_at(days_sorted, now)
    trailing = {}
    for s, cl in series.items():
        if t_lb in cl and t_now in cl and cl[t_lb] > 0:
            trailing[s] = cl[t_now] / cl[t_lb] - 1.0
    if len(trailing) < 2 * args.top_k:
        sys.stderr.write("xsectional-paper: not enough symbols with trailing data\n")
        return 2
    ranked = sorted(trailing, key=lambda s: trailing[s], reverse=True)
    longs, shorts = ranked[:args.top_k], ranked[-args.top_k:]

    rows = ledger_rows(args.ledger)
    prev = rows[-1] if rows else None

    # 3. settle prior period (realised forward return of prior basket)
    period_gross = 0.0
    period_net = 0.0
    cumulative = prev["cumulative_net_pct"] if prev else 0.0
    if prev is not None:
        p_now = close_at(days_sorted, prev["ts"])
        pl, ps = prev["longs"], prev["shorts"]

        def basket_fwd(names):
            rs = []
            for s in names:
                cl = series.get(s, {})
                if p_now in cl and t_now in cl and cl[p_now] > 0:
                    rs.append(cl[t_now] / cl[p_now] - 1.0)
            return sum(rs) / len(rs) if rs else 0.0
        period_gross = basket_fwd(pl) - basket_fwd(ps)
        changed = len(set(longs) ^ set(pl)) + len(set(shorts) ^ set(ps))
        turnover = (changed / 2.0) / (2.0 * args.top_k)
        lev_prev = prev["leverage"]
        period_net = lev_prev * (period_gross - cost * turnover)
        cumulative = round(cumulative + period_net * 100, 4)

    # 4. size the new book by trailing-vol targeting (past period_gross only)
    hist = [r["period_gross_pct"] / 100.0 for r in rows[-args.vol_window:]]
    reb_per_year = 365.0 / args.rebalance_days
    tgt_per = (args.target_vol_pct / 100.0) / math.sqrt(reb_per_year)
    tv = stdev(hist) if len(hist) >= 2 else 0.0
    leverage = round(min(args.max_leverage, tgt_per / tv), 3) if tv > 0 else 1.0

    row = {
        "ts": now,
        "longs": longs,
        "shorts": shorts,
        "leverage": leverage,
        "period_gross_pct": round(period_gross * 100, 4),
        "period_net_pct": round(period_net * 100, 4),
        "cumulative_net_pct": cumulative,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.ledger)), exist_ok=True)
    with open(args.ledger, "a") as fh:
        fh.write(json.dumps(row, separators=(",", ":")) + "\n")

    print("[xsectional-paper] %s  L=%s S=%s  lev=%.2fx" % (
        now, ",".join(longs), ",".join(shorts), leverage))
    print("  settled prior: gross=%.2f%% net=%.2f%%  |  cumulative=%.2f%%" % (
        period_gross * 100, period_net * 100, cumulative))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
