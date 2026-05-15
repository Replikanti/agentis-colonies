#!/usr/bin/env python3
"""binance-feed-download.py - Download Binance USDT-margined perpetual futures klines.

Fetches historical kline (candlestick) data from the Binance USDT-margined
perpetual futures public REST API (`/fapi/v1/klines`), paginates over
multi-day windows with HTTP 429 / 5xx retry, and writes deterministic
date-sharded CSV files under
`<output-dir>/<symbol>/<timeframe>/<YYYY-MM-DD>.csv` for intraday timeframes
(`30m`, `1h`) or `<output-dir>/<symbol>/<timeframe>/<YYYY>.csv` for daily.

CSV columns (header on every file):
    timestamp_ms,open,high,low,close,volume,quote_volume,trades,
    taker_buy_volume,taker_buy_quote_volume

Output is overwritten on re-run (deterministic). No live API calls in CI:
`test-binance-feed-download.sh` serves a local fixture via http.server and
passes `--binance-base-url http://localhost:<port>`.

Standard library only — no `requests` / `pandas` dependency.

Usage:
    binance-feed-download.py --symbol BTCUSDT --timeframe 30m \\
        --start 2026-02-15 --end 2026-05-15 \\
        --output-dir trading-binance/data
"""
import argparse
import json
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

VALID_TIMEFRAMES = ("30m", "1h", "1d")
INTERVAL_MS = {
    "30m": 30 * 60 * 1000,
    "1h": 60 * 60 * 1000,
    "1d": 24 * 60 * 60 * 1000,
}
MAX_LIMIT = 1500
DEFAULT_BASE_URL = "https://fapi.binance.com"
KLINES_PATH = "/fapi/v1/klines"


def _parse_args(argv):
    p = argparse.ArgumentParser(
        description="Download Binance USDT-M perpetual futures klines as CSV.",
    )
    p.add_argument("--symbol", required=True, help="Binance futures symbol (e.g. BTCUSDT).")
    p.add_argument(
        "--timeframe",
        required=True,
        choices=VALID_TIMEFRAMES,
        help="Candle interval (30m, 1h, or 1d).",
    )
    p.add_argument("--start", required=True, help="UTC start date YYYY-MM-DD (inclusive).")
    p.add_argument("--end", required=True, help="UTC end date YYYY-MM-DD (inclusive).")
    p.add_argument(
        "--output-dir",
        default="trading-binance/data",
        help="Output root directory (default: trading-binance/data).",
    )
    p.add_argument(
        "--binance-base-url",
        default=DEFAULT_BASE_URL,
        help=argparse.SUPPRESS,
    )
    return p.parse_args(argv)


def _parse_utc_date(s):
    """Parse YYYY-MM-DD as midnight UTC. Raises ValueError on bad input."""
    dt = datetime.strptime(s, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    return dt


def _date_to_ms(dt):
    return int(dt.timestamp() * 1000)


def _fetch_page(base_url, symbol, interval, start_ms, end_ms, limit):
    """Fetch one klines page from Binance. Returns parsed JSON (list of lists).

    Retries on 429 (once after Retry-After) and 5xx (3 attempts, 2s/4s/8s
    backoff). Hard-fails on 418 / 451 (IP ban) and JSON parse errors.
    """
    params = {
        "symbol": symbol,
        "interval": interval,
        "startTime": start_ms,
        "endTime": end_ms,
        "limit": limit,
    }
    qs = urllib.parse.urlencode(params)
    url = base_url.rstrip("/") + KLINES_PATH + "?" + qs

    retried_429 = False
    backoff_attempts = 0
    backoff_delays = [2, 4, 8]

    while True:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "agentis-binance-feed/0.1"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read()
            try:
                return json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as e:
                sys.stderr.write("ERROR: JSON parse failed: " + str(e) + "\n")
                sys.stderr.write("Raw response: " + repr(body[:1024]) + "\n")
                sys.exit(1)

        except urllib.error.HTTPError as e:
            code = e.code
            if code == 429:
                if retried_429:
                    sys.stderr.write("ERROR: HTTP 429 persisted after one retry — abort\n")
                    sys.exit(1)
                retry_after_hdr = e.headers.get("Retry-After") if e.headers else None
                try:
                    delay = int(retry_after_hdr) if retry_after_hdr else 60
                except (TypeError, ValueError):
                    delay = 60
                sys.stderr.write(
                    "WARN: HTTP 429 — sleeping " + str(delay) + "s before retry\n"
                )
                time.sleep(delay)
                retried_429 = True
                continue
            if code in (418, 451):
                sys.stderr.write("ERROR: Binance IP ban (HTTP " + str(code) + ") — abort\n")
                sys.exit(1)
            if 500 <= code < 600:
                if backoff_attempts >= len(backoff_delays):
                    sys.stderr.write(
                        "ERROR: HTTP " + str(code) + " persisted after "
                        + str(len(backoff_delays)) + " retries — abort\n"
                    )
                    sys.exit(1)
                delay = backoff_delays[backoff_attempts]
                sys.stderr.write(
                    "WARN: HTTP " + str(code) + " — sleeping " + str(delay)
                    + "s (attempt " + str(backoff_attempts + 1) + "/"
                    + str(len(backoff_delays)) + ")\n"
                )
                time.sleep(delay)
                backoff_attempts += 1
                continue
            sys.stderr.write("ERROR: HTTP " + str(code) + " " + str(e.reason) + "\n")
            sys.exit(1)

        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if backoff_attempts >= len(backoff_delays):
                sys.stderr.write(
                    "ERROR: network error persisted after "
                    + str(len(backoff_delays)) + " retries: " + str(e) + "\n"
                )
                sys.exit(1)
            delay = backoff_delays[backoff_attempts]
            sys.stderr.write(
                "WARN: network error " + str(e) + " — sleeping " + str(delay)
                + "s (attempt " + str(backoff_attempts + 1) + "/"
                + str(len(backoff_delays)) + ")\n"
            )
            time.sleep(delay)
            backoff_attempts += 1
            continue


def _fetch_all(base_url, symbol, interval, start_ms, end_ms):
    """Page through Binance klines from start_ms to end_ms. De-dup by ts_ms."""
    interval_ms = INTERVAL_MS[interval]
    current_start = start_ms
    all_rows = []

    while current_start <= end_ms:
        page = _fetch_page(
            base_url, symbol, interval, current_start, end_ms, MAX_LIMIT
        )
        if not isinstance(page, list):
            sys.stderr.write(
                "ERROR: unexpected response shape (not a list): "
                + repr(page)[:512] + "\n"
            )
            sys.exit(1)
        if not page:
            break
        all_rows.extend(page)
        last_ts = page[-1][0]
        next_start = last_ts + interval_ms
        if next_start <= current_start:
            # Defensive: prevent infinite loop on degenerate response.
            break
        current_start = next_start
        if len(page) < MAX_LIMIT:
            break

    seen = {}
    for row in all_rows:
        seen[row[0]] = row
    return [seen[ts] for ts in sorted(seen.keys())]


def _project_row(raw):
    """Project Binance kline array to our CSV column ordering.

    Binance returns:
        [0]  ts_ms                     -> timestamp_ms
        [1]  open                      -> open
        [2]  high                      -> high
        [3]  low                       -> low
        [4]  close                     -> close
        [5]  volume                    -> volume
        [6]  close_ts_ms               (dropped: derivable from ts + interval)
        [7]  quote_volume              -> quote_volume
        [8]  trades                    -> trades
        [9]  taker_buy_volume          -> taker_buy_volume
        [10] taker_buy_quote_volume    -> taker_buy_quote_volume
        [11] ignore                    (dropped)
    """
    return [
        str(raw[0]),
        str(raw[1]),
        str(raw[2]),
        str(raw[3]),
        str(raw[4]),
        str(raw[5]),
        str(raw[7]),
        str(raw[8]),
        str(raw[9]),
        str(raw[10]),
    ]


CSV_HEADER = (
    "timestamp_ms,open,high,low,close,volume,quote_volume,trades,"
    "taker_buy_volume,taker_buy_quote_volume"
)


def _shard_key(ts_ms, timeframe):
    """Group rows into per-date (intraday) or per-year (daily) files."""
    dt = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc)
    if timeframe == "1d":
        return str(dt.year)
    return dt.strftime("%Y-%m-%d")


def _write_shards(rows, output_dir, symbol, timeframe):
    """Group projected rows by shard key, write one CSV per group."""
    by_shard = {}
    for raw in rows:
        ts_ms = int(raw[0])
        key = _shard_key(ts_ms, timeframe)
        by_shard.setdefault(key, []).append(_project_row(raw))

    out_root = pathlib.Path(output_dir) / symbol / timeframe
    out_root.mkdir(parents=True, exist_ok=True)

    written = []
    for key in sorted(by_shard.keys()):
        out_path = out_root / (key + ".csv")
        with open(out_path, "w") as f:
            f.write(CSV_HEADER + "\n")
            for row in by_shard[key]:
                f.write(",".join(row) + "\n")
        written.append(out_path)
    return written


def main(argv=None):
    args = _parse_args(argv if argv is not None else sys.argv[1:])

    try:
        start_dt = _parse_utc_date(args.start)
        end_dt = _parse_utc_date(args.end)
    except ValueError as e:
        sys.stderr.write("ERROR: invalid date format (expected YYYY-MM-DD): " + str(e) + "\n")
        sys.exit(2)

    if end_dt < start_dt:
        sys.stderr.write("ERROR: --end is before --start\n")
        sys.exit(2)

    # End date is inclusive — extend to end-of-day UTC.
    start_ms = _date_to_ms(start_dt)
    end_ms = _date_to_ms(end_dt) + (24 * 60 * 60 * 1000) - 1

    sys.stderr.write(
        "Fetching " + args.symbol + " " + args.timeframe
        + " from " + args.start + " to " + args.end
        + " (" + args.binance_base_url + ")\n"
    )

    rows = _fetch_all(
        args.binance_base_url, args.symbol, args.timeframe, start_ms, end_ms
    )

    sys.stderr.write("Fetched " + str(len(rows)) + " unique candles\n")

    written = _write_shards(rows, args.output_dir, args.symbol, args.timeframe)
    sys.stderr.write("Wrote " + str(len(written)) + " CSV file(s)\n")
    for p in written:
        sys.stderr.write("  " + str(p) + "\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
