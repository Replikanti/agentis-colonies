#!/usr/bin/env python3
"""tail-risk.py -- measure the tails a funding-only carry backtest cannot see
(#1188). For a delta-neutral carry (short perp + long spot), directional PnL
hedges, but three tails can wipe a book in one event:

  1. BASIS BLOWOUT -- pair PnL at a forced unwind = -(basis_now - basis_entry),
     basis = (perp - spot)/spot. A perp-spot squeeze you're forced to close into
     costs the basis widening. Measure max basis dislocation (perp vs spot daily).
  2. FUNDING SIGN-FLIP -- in a crash funding flips hard negative (short-perp
     PAYS); the trailing filter lags ~lookback days, so the book pays through the
     flip. Measure the worst sustained negative-funding run per symbol.
  3. LIQUIDATION -- a perp short margined at leverage L liquidates on an adverse
     up-move > ~1/L. Measure the worst adverse daily perp move -> max safe L.

Framing: a FULLY-FUNDED 1:1 book (spot fully held, short fully margined, no
leverage) has no liquidation risk and directional cancels through any move -> its
residual tail is only basis + funding-flips (small for liquid alts). A LEVERAGED
book frees capital but adds the liquidation tail. The report gives both.

Perp klines: fapi.binance.com /fapi/v1/klines ; spot: api.binance.com /api/v3/klines.
Funding reused from <funding-dir>/<SYM>.csv. Standard library only.
"""
import argparse
import csv
import datetime
import json
import os
import sys
import urllib.request


def epoch_ms(s):
    if s.isdigit():
        return int(s)
    return int(datetime.datetime.strptime(s, "%Y-%m-%d").replace(
        tzinfo=datetime.timezone.utc).timestamp() * 1000)


def klines(host, path, symbol, interval, start, end):
    out = []
    cur = start
    while cur < end:
        url = ("https://%s%s?symbol=%s&interval=%s&startTime=%d&endTime=%d&limit=1000"
               % (host, path, symbol, interval, cur, end))
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                batch = json.load(r)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write("klines %s %s err: %s\n" % (host, symbol, e))
            return out
        if not batch:
            break
        out.extend(batch)
        cur = batch[-1][0] + 1
        if len(batch) < 1000:
            break
    return out


def load_funding(funding_dir, sym):
    path = os.path.join(funding_dir, sym + ".csv")
    if not os.path.isfile(path):
        return []
    rows = []
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            rows.append((int(r["fundingTime"]), float(r["fundingRate"])))
    rows.sort()
    return rows


def worst_negative_run(funding_rows):
    """Largest-magnitude sum of a consecutive negative-funding streak (what a
    short-perp book PAYS through a sustained flip), in bps."""
    worst = 0.0
    cur = 0.0
    for _, fr in funding_rows:
        if fr < 0:
            cur += fr
            worst = min(worst, cur)
        else:
            cur = 0.0
    return worst * 10000.0


def analyse_symbol(sym, start, end, funding_dir):
    perp = klines("fapi.binance.com", "/fapi/v1/klines", sym, "1d", start, end)
    spot = klines("api.binance.com", "/api/v3/klines", sym, "1d", start, end)
    if not perp or not spot:
        return None
    # align by openTime: close = index 4, high = 2
    pmap = {k[0]: (float(k[4]), float(k[2])) for k in perp}
    smap = {k[0]: float(k[4]) for k in spot}
    bases = []
    for t in sorted(set(pmap) & set(smap)):
        pc, _ = pmap[t]
        sc = smap[t]
        if sc > 0:
            bases.append((pc - sc) / sc)
    if not bases:
        return None
    max_basis = max(bases)
    min_basis = min(bases)
    # worst adverse up-move on the perp (high vs prior close), for liquidation
    pk = sorted(pmap)
    worst_up = 0.0
    for i in range(1, len(pk)):
        prev_close = pmap[pk[i - 1]][0]
        hi = pmap[pk[i]][1]
        if prev_close > 0:
            worst_up = max(worst_up, (hi - prev_close) / prev_close)
    fr = load_funding(funding_dir, sym)
    return {
        "symbol": sym,
        "max_basis_pct": round(max_basis * 100, 3),
        "min_basis_pct": round(min_basis * 100, 3),
        "max_abs_basis_pct": round(max(abs(max_basis), abs(min_basis)) * 100, 3),
        "worst_adverse_day_up_pct": round(worst_up * 100, 2),
        "max_safe_leverage": round(1.0 / worst_up, 1) if worst_up > 0 else None,
        "worst_negative_funding_run_bps": round(worst_negative_run(fr), 2),
        "days": len(bases),
    }


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbols", required=True)
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    ap.add_argument("--funding-dir", required=True)
    ap.add_argument("--annual-carry-pct", type=float, default=5.0,
                    help="reference annual carry to compare the tail against")
    args = ap.parse_args(argv)

    symbols = [s.strip().upper() for s in args.symbols.split(",") if s.strip()]
    start, end = epoch_ms(args.start), epoch_ms(args.end)
    per = []
    for s in symbols:
        r = analyse_symbol(s, start, end, args.funding_dir)
        if r:
            per.append(r)
    if not per:
        sys.stderr.write("no data\n")
        return 2

    # basket (equal-weight) tail aggregates
    basket_worst_basis = max(p["max_abs_basis_pct"] for p in per)
    basket_mean_worst_basis = round(sum(p["max_abs_basis_pct"] for p in per) / len(per), 3)
    basket_worst_negfund = min(p["worst_negative_funding_run_bps"] for p in per)
    basket_mean_negfund = round(sum(p["worst_negative_funding_run_bps"] for p in per) / len(per), 2)
    basket_min_safe_lev = min((p["max_safe_leverage"] for p in per if p["max_safe_leverage"]), default=None)

    out = {
        "window": {"start": args.start, "end": args.end},
        "reference_annual_carry_pct": args.annual_carry_pct,
        "per_symbol": per,
        "basket": {
            "worst_single_symbol_basis_pct": basket_worst_basis,
            "mean_worst_basis_pct": basket_mean_worst_basis,
            "worst_negative_funding_run_bps": basket_worst_negfund,
            "mean_worst_negative_funding_run_bps": basket_mean_negfund,
            "min_safe_leverage_across_basket": basket_min_safe_lev,
        },
        "interpretation": {
            "fully_funded_1to1_tail_pct": round(basket_mean_worst_basis + abs(basket_mean_negfund) / 100.0, 3),
            "note": "fully-funded tail = mean worst basis (forced-unwind) + mean worst sustained negative-funding run; directional cancels (no liquidation). leveraged adds liquidation at moves > 1/L.",
        },
    }
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
