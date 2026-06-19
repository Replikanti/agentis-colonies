#!/usr/bin/env python3
"""funding-download.py -- fetch Binance USDT-M perpetual funding-rate history
into per-symbol CSVs, for the funding-carry backtest (#1173).

Funding settles every 8h; a delta-neutral carry (short perp + long spot)
receives the funding rate each settlement when funding > 0. This tool pulls
the raw funding-rate series so the deterministic carry backtest can measure the
harvestable carry per symbol out-of-sample.

Mirrors binance-feed-download.py conventions: standard library only (urllib),
paginated, idempotent CSV output under <output-dir>/<SYMBOL>.csv with columns
`fundingTime,fundingRate`. Data is gitignored (like klines).

Endpoint: GET https://fapi.binance.com/fapi/v1/fundingRate
  ?symbol=<SYM>&startTime=<ms>&endTime=<ms>&limit=1000

Usage:
  funding-download.py --symbols BTCUSDT,ETHUSDT,LINKUSDT \
      --start 2026-03-01 --end 2026-06-01 [--output-dir <dir>]
"""
import argparse
import csv
import datetime
import json
import os
import sys
import time
import urllib.request

FAPI = "https://fapi.binance.com/fapi/v1/fundingRate"


def epoch_ms(date_str):
    dt = datetime.datetime.strptime(date_str, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
    return int(dt.timestamp() * 1000)


def fetch_symbol(symbol, start_ms, end_ms, retries=3):
    rows = []
    cur = start_ms
    while cur < end_ms:
        url = "%s?symbol=%s&startTime=%d&endTime=%d&limit=1000" % (FAPI, symbol, cur, end_ms)
        batch = None
        for attempt in range(retries):
            try:
                with urllib.request.urlopen(url, timeout=30) as resp:
                    batch = json.load(resp)
                break
            except Exception as e:  # noqa: BLE001
                if attempt == retries - 1:
                    sys.stderr.write("funding-download: %s failed: %s\n" % (symbol, e))
                    return rows
                time.sleep(1.0 + attempt)
        if not batch:
            break
        rows.extend(batch)
        cur = batch[-1]["fundingTime"] + 1
        if len(batch) < 1000:
            break
    # dedup by fundingTime, sort
    seen = set()
    uniq = []
    for r in sorted(rows, key=lambda r: r["fundingTime"]):
        t = r["fundingTime"]
        if t in seen:
            continue
        seen.add(t)
        uniq.append(r)
    return uniq


def main(argv):
    p = argparse.ArgumentParser(description="Download Binance USDT-M funding-rate history.")
    p.add_argument("--symbols", required=True, help="comma-separated, e.g. BTCUSDT,ETHUSDT")
    p.add_argument("--start", required=True, help="YYYY-MM-DD (UTC, inclusive)")
    p.add_argument("--end", required=True, help="YYYY-MM-DD (UTC, exclusive)")
    p.add_argument("--output-dir", default=None,
                   help="default: <repo>/trading-binance/data/funding")
    args = p.parse_args(argv)

    out_dir = args.output_dir
    if out_dir is None:
        here = os.path.dirname(os.path.abspath(__file__))
        out_dir = os.path.join(os.path.dirname(here), "data", "funding")
    os.makedirs(out_dir, exist_ok=True)

    start_ms = epoch_ms(args.start)
    end_ms = epoch_ms(args.end)
    symbols = [s.strip().upper() for s in args.symbols.split(",") if s.strip()]

    total = 0
    for sym in symbols:
        rows = fetch_symbol(sym, start_ms, end_ms)
        if not rows:
            print("  %-12s 0 events (no data / unavailable)" % sym)
            continue
        path = os.path.join(out_dir, sym + ".csv")
        with open(path, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["fundingTime", "fundingRate"])
            for r in rows:
                w.writerow([r["fundingTime"], r["fundingRate"]])
        total += len(rows)
        print("  %-12s %4d events -> %s" % (sym, len(rows), path))
    print("done: %d symbols, %d funding events, dir=%s" % (len(symbols), total, out_dir))


if __name__ == "__main__":
    main(sys.argv[1:])
