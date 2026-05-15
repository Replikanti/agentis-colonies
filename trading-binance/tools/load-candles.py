#!/usr/bin/env python3
"""load-candles.py - Concatenate PR-2 CSV shards into a unified candle stream.

Reads date-sharded CSV files produced by `binance-feed-download.py` under
`<data-dir>/<symbol>/<timeframe>/<YYYY-MM-DD>.csv` (intraday) or
`<data-dir>/<symbol>/<timeframe>/<YYYY>.csv` (daily), filters by optional
inclusive [start, end] date range, concatenates them sorted by
timestamp_ms, and prints the result to stdout with one header line.

Validates row continuity: rejects any gap > 2x the timeframe interval.
This catches silently-missing shards before they break the replay loop.

Standard library only.

Usage:
    load-candles.py --data-dir trading-binance/data \\
        --symbol BTCUSDT --timeframe 30m \\
        [--start 2026-02-15] [--end 2026-05-13]

Exit codes:
    0  success — unified stream on stdout
    2  invalid arguments / unknown timeframe
    3  missing data dir or no shards in range
    4  continuity violation (gap > 2x interval)
"""
import argparse
import pathlib
import sys
from datetime import datetime, timezone

VALID_TIMEFRAMES = ("30m", "1h", "1d")
INTERVAL_MS = {
    "30m": 30 * 60 * 1000,
    "1h": 60 * 60 * 1000,
    "1d": 24 * 60 * 60 * 1000,
}
CSV_HEADER = (
    "timestamp_ms,open,high,low,close,volume,quote_volume,trades,"
    "taker_buy_volume,taker_buy_quote_volume"
)


def _parse_args(argv):
    p = argparse.ArgumentParser(description="Concatenate Binance CSV shards.")
    p.add_argument("--data-dir", required=True)
    p.add_argument("--symbol", required=True)
    p.add_argument("--timeframe", required=True, choices=VALID_TIMEFRAMES)
    p.add_argument("--start", default="", help="UTC YYYY-MM-DD (inclusive).")
    p.add_argument("--end", default="", help="UTC YYYY-MM-DD (inclusive).")
    return p.parse_args(argv)


def _shard_in_range(name, start, end):
    """Return True iff the shard's date stem falls within [start, end].

    Bare stems (no extension stripping done by caller) like 'YYYY-MM-DD' or
    'YYYY' compare lexicographically against ISO date strings; an empty
    bound is treated as open on that side.
    """
    if start and name < start:
        return False
    if end and name > end:
        return False
    return True


def _read_shard(path):
    """Yield raw CSV rows (excluding header) as strings, with trailing newlines stripped."""
    with open(path, "r") as f:
        header = f.readline().rstrip("\n")
        if header != CSV_HEADER:
            sys.stderr.write(
                "ERROR: " + str(path) + " header mismatch:\n"
                "  expected: " + CSV_HEADER + "\n"
                "  got:      " + header + "\n"
            )
            sys.exit(3)
        for line in f:
            line = line.rstrip("\n")
            if line:
                yield line


def main(argv=None):
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    shard_dir = pathlib.Path(args.data_dir) / args.symbol / args.timeframe
    if not shard_dir.is_dir():
        sys.stderr.write("ERROR: shard directory not found: " + str(shard_dir) + "\n")
        sys.exit(3)

    shards = sorted(shard_dir.glob("*.csv"))
    if args.start or args.end:
        shards = [
            s for s in shards
            if _shard_in_range(s.stem, args.start, args.end)
        ]
    if not shards:
        sys.stderr.write(
            "ERROR: no shards in range under " + str(shard_dir) + "\n"
        )
        sys.exit(3)

    interval_ms = INTERVAL_MS[args.timeframe]
    gap_cap = 2 * interval_ms
    sys.stdout.write(CSV_HEADER + "\n")
    last_ts = None
    total = 0
    for shard in shards:
        for line in _read_shard(shard):
            try:
                ts = int(line.split(",", 1)[0])
            except (ValueError, IndexError):
                sys.stderr.write(
                    "ERROR: malformed row in " + str(shard) + ": " + line + "\n"
                )
                sys.exit(3)
            if last_ts is not None:
                delta = ts - last_ts
                if delta <= 0:
                    sys.stderr.write(
                        "ERROR: non-monotonic ts in " + str(shard)
                        + " (prev=" + str(last_ts) + " cur=" + str(ts) + ")\n"
                    )
                    sys.exit(4)
                if delta > gap_cap:
                    sys.stderr.write(
                        "ERROR: continuity gap " + str(delta) + " ms > "
                        + str(gap_cap) + " ms (2x " + args.timeframe + ") "
                        + "between ts=" + str(last_ts) + " and ts=" + str(ts) + "\n"
                    )
                    sys.exit(4)
            sys.stdout.write(line + "\n")
            last_ts = ts
            total += 1

    first_dt = datetime.fromtimestamp(
        int(open(shards[0]).readlines()[1].split(",", 1)[0]) / 1000,
        tz=timezone.utc,
    )
    sys.stderr.write(
        "Loaded " + str(total) + " candles from " + str(len(shards))
        + " shard(s) starting at " + first_dt.strftime("%Y-%m-%dT%H:%M:%SZ") + "\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
