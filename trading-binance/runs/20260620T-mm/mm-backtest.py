#!/usr/bin/env python3
"""mm-backtest.py -- symmetric market-making feasibility on tick data (#1205).
Tests whether the intraday reversal edge (#1202: the maker's, not the taker's)
is net-positive for a simple symmetric market-maker after maker fees + adverse
selection.

OPTIMISTIC FILL MODEL (read this): a resting quote fills when a trade crosses it
(touch-based), assuming front-of-queue, no cancel latency, no partial-fill
competition. This OVERSTATES a real MM's fills -> a positive result is an UPPER
BOUND; a negative result is decisive (real MM is worse). True MM needs L2/L3 book
+ latency modelling, not available here.

Fill logic (Binance aggTrades is_buyer_maker semantics):
  is_buyer_maker=True  -> a market SELL hit a resting BID. Our bid at b fills (we
    BUY) if the trade price <= b.
  is_buyer_maker=False -> a market BUY hit a resting ASK. Our ask at a fills (we
    SELL) if the trade price >= a.
Fair value = trailing EMA of trade price, updated AFTER the fill check (no
look-ahead). Quotes: bid = fair*(1-d), ask = fair*(1+d), d = half-spread.
Inventory capped at +/- max_inventory_notional. maker_fee_bps > 0 = we PAY (cost),
< 0 = rebate (earn). P&L = cash + inventory marked at last price + fees.

Tick data: Binance daily aggTrades dumps (data.binance.vision). Std lib only.
"""
import argparse
import csv
import io
import json
import math
import sys
import urllib.request
import zipfile


def download_aggtrades(symbol, date):
    url = ("https://data.binance.vision/data/futures/um/daily/aggTrades/%s/%s-aggTrades-%s.zip"
           % (symbol, symbol, date))
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            blob = r.read()
    except Exception as e:  # noqa: BLE001
        sys.stderr.write("aggTrades %s %s err: %s\n" % (symbol, date, e))
        return []
    out = []
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        name = z.namelist()[0]
        with z.open(name) as fh:
            rdr = csv.reader(io.TextIOWrapper(fh, "utf-8"))
            first = next(rdr)
            # header present iff first cell is non-numeric
            if first and first[0].replace(".", "").isdigit():
                rows = [first]
            else:
                rows = []
            for row in rdr:
                rows.append(row)
            # columns: agg_id, price, qty, first_id, last_id, transact_time, is_buyer_maker
            for row in rows:
                try:
                    out.append((int(row[5]), float(row[1]), float(row[2]), row[6].strip().lower() == "true"))
                except (ValueError, IndexError):
                    continue
    out.sort()
    return out


def simulate(trades, half_spread_bps, max_inv_notional, maker_fee_bps, quote_notional, ema_alpha,
             inventory_skew_bps=0.0):
    if not trades:
        return None
    d = half_spread_bps / 10000.0
    fee = maker_fee_bps / 10000.0
    skew = inventory_skew_bps / 10000.0
    fair = trades[0][1]
    cash = 0.0
    inv = 0.0          # inventory in base qty
    fills = 0
    vol_notional = 0.0
    max_abs_inv_notional = 0.0
    for (_, p, q, is_buyer_maker) in trades:
        inv_notional = inv * fair
        # inventory skew: when long (inv>0) shift quotes DOWN to stop buying /
        # start offloading; when short shift up. frac in [-1, 1].
        frac = max(-1.0, min(1.0, inv_notional / max_inv_notional)) if max_inv_notional else 0.0
        shift = skew * fair * frac
        bid = fair * (1.0 - d) - shift
        ask = fair * (1.0 + d) - shift
        if is_buyer_maker and p <= bid and inv_notional < max_inv_notional:
            fq = min(quote_notional / bid, q)
            inv += fq
            cash -= bid * fq
            cash -= fee * bid * fq
            fills += 1
            vol_notional += bid * fq
        elif (not is_buyer_maker) and p >= ask and inv_notional > -max_inv_notional:
            fq = min(quote_notional / ask, q)
            inv -= fq
            cash += ask * fq
            cash -= fee * ask * fq
            fills += 1
            vol_notional += ask * fq
        fair = fair * (1.0 - ema_alpha) + p * ema_alpha
        max_abs_inv_notional = max(max_abs_inv_notional, abs(inv * fair))
    last = trades[-1][1]
    pnl = cash + inv * last
    return {
        "pnl": round(pnl, 4),
        "fills": fills,
        "traded_notional": round(vol_notional, 1),
        "final_inventory_notional": round(inv * last, 2),
        "max_abs_inventory_notional": round(max_abs_inv_notional, 1),
        "pnl_bps_of_volume": round(pnl / vol_notional * 10000, 3) if vol_notional > 0 else 0.0,
    }


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default="LINKUSDT")
    ap.add_argument("--dates", default=None, help="comma-separated YYYY-MM-DD (required unless --trades-file)")
    ap.add_argument("--half-spreads-bps", default="2,4,6,10")
    ap.add_argument("--maker-fees-bps", default="2,0,-0.5",
                    help="positive=pay, negative=rebate")
    ap.add_argument("--max-inventory-notional", type=float, default=5000.0)
    ap.add_argument("--quote-notional", type=float, default=1000.0)
    ap.add_argument("--ema-alphas", default="0.02,0.1,0.3",
                    help="fair-value EMA responsiveness; higher = tracks price faster")
    ap.add_argument("--inventory-skews-bps", default="0", help="quote skew per unit inventory")
    ap.add_argument("--trades-file", default=None, help="CSV time,price,qty,is_buyer_maker for tests")
    args = ap.parse_args(argv)

    if args.trades_file:
        trades = []
        with open(args.trades_file) as fh:
            for row in csv.reader(fh):
                trades.append((int(row[0]), float(row[1]), float(row[2]), row[3].strip().lower() == "true"))
        trades.sort()
        days = 1
    elif not args.dates:
        sys.stderr.write("mm-backtest: --dates or --trades-file required\n")
        return 2
    else:
        dates = [x.strip() for x in args.dates.split(",") if x.strip()]
        trades = []
        for dt in dates:
            trades.extend(download_aggtrades(args.symbol, dt))
        trades.sort()
        days = len(dates)
    if len(trades) < 100:
        sys.stderr.write("mm-backtest: not enough trades (%d)\n" % len(trades))
        return 2

    out = {"symbol": args.symbol, "days": days, "trades": len(trades),
           "max_inventory_notional": args.max_inventory_notional,
           "quote_notional": args.quote_notional, "results": []}
    for hs in [float(x) for x in args.half_spreads_bps.split(",")]:
        for fee in [float(x) for x in args.maker_fees_bps.split(",")]:
            for sk in [float(x) for x in args.inventory_skews_bps.split(",")]:
                for alpha in [float(x) for x in args.ema_alphas.split(",")]:
                    r = simulate(trades, hs, args.max_inventory_notional, fee, args.quote_notional,
                                 alpha, sk)
                    if not r:
                        continue
                    r["half_spread_bps"] = hs
                    r["maker_fee_bps"] = fee
                    r["inventory_skew_bps"] = sk
                    r["ema_alpha"] = alpha
                    # return on capital (capital ~ max inventory), annualised
                    cap = args.max_inventory_notional
                    r["roc_pct_annualised"] = round(r["pnl"] / cap * (365.0 / max(days, 1)) * 100, 1) if cap else 0.0
                    out["results"].append(r)
    out["results"].sort(key=lambda r: -r["pnl"])
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
