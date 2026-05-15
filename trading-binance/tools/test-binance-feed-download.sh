#!/usr/bin/env bash
# trading-binance/tools/test-binance-feed-download.sh
#
# Unit tests for `binance-feed-download.py` (#573 PR-2).
#
# Spawns a local python http.server that serves two-page klines fixture JSON
# matching Binance `/fapi/v1/klines` shape, runs the downloader against
# `--binance-base-url http://127.0.0.1:<port>`, and asserts:
#
#   Test 1: output CSV file exists at expected shard path
#   Test 2: CSV header line matches the documented column ordering
#   Test 3: row count = page-1 (1500) + page-2 (500) - 1 boundary duplicate = 1999
#   Test 4: field projection — close_ts_ms (idx 6) dropped, ignore (idx 11) dropped,
#           and column 7 of CSV (quote_volume) maps to Binance idx 7
#   Test 5: pagination — fixture server received exactly 2 GET requests
#   Test 6: rows are sorted by timestamp_ms ascending and unique (de-dup worked)
#
# Standard library only — no pytest, no requests. Self-contained: fixture
# JSON is generated inline by a small python helper invoked from this shell
# script; the fixture http server is plain `python3 -m http.server` shimmed
# via a tiny subclass that returns the right JSON for /fapi/v1/klines and
# logs hit count.
#
# Usage: bash trading-binance/tools/test-binance-feed-download.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOWNLOADER="$SCRIPT_DIR/binance-feed-download.py"

PORT="${BINANCE_FIXTURE_PORT:-19340}"
WORK_DIR="$(mktemp -d)"
SERVER_LOG="$WORK_DIR/server.log"
SERVER_PID_FILE="$WORK_DIR/server.pid"
HIT_COUNT_FILE="$WORK_DIR/hit-count"
OUTPUT_DIR="$WORK_DIR/data"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

cleanup() {
    if [ -f "$SERVER_PID_FILE" ]; then
        local pid
        pid="$(cat "$SERVER_PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            # Give it a brief moment to release the port.
            sleep 0.2
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Spawn fixture HTTP server
# ---------------------------------------------------------------------------
exit_setup_fail() {
    fail "$1"
    echo "--- server log ---"
    cat "$SERVER_LOG" 2>/dev/null || true
    echo "--- end server log ---"
    exit 1
}

FIXTURE_SERVER="$WORK_DIR/fixture-server.py"
cat > "$FIXTURE_SERVER" <<'PYFIXTURE'
"""Local fixture HTTP server for Binance klines unit tests.

Args:
    1: bind port
    2: hit-count file path (one integer, total requests to /fapi/v1/klines)
    3: pid file (we don't write here — outer shell tracks the PID)

Page 1: 1500 candles starting at FIRST_TS, ts step = 30 minutes.
Page 2: 500 candles starting at FIRST_TS + 1499 * step.
        -> page-2[0] timestamp == page-1[1499] timestamp (boundary overlap,
        target of de-dup logic). Net unique count = 1500 + 500 - 1 = 1999.

Fields produced match Binance contract exactly (12 fields, idx 6 = close_ts,
idx 11 = ignore). Numerics emitted as strings (Binance does the same).
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1])
HIT_FILE = sys.argv[2]

FIRST_TS = 1_700_000_000_000  # arbitrary anchor (2023-11-14 UTC-ish)
STEP_MS = 30 * 60 * 1000  # 30m
PAGE1_LEN = 1500
PAGE2_LEN = 500
BOUNDARY_TS = FIRST_TS + (PAGE1_LEN - 1) * STEP_MS  # page-1 last == page-2 first

_lock = threading.Lock()
_hits = {"n": 0}


def _make_candle(idx):
    ts = FIRST_TS + idx * STEP_MS
    base = 30000.0 + idx
    return [
        ts,
        f"{base:.2f}",
        f"{base + 10:.2f}",
        f"{base - 10:.2f}",
        f"{base + 1:.2f}",
        f"{100 + idx}.0",
        ts + STEP_MS - 1,
        f"{(100 + idx) * base:.2f}",
        50 + idx,
        f"{(50 + idx) / 2:.2f}",
        f"{(50 + idx) * base / 2:.2f}",
        "0",
    ]


def _page1():
    return [_make_candle(i) for i in range(PAGE1_LEN)]


def _page2():
    # Index PAGE1_LEN-1 = boundary candle, then PAGE2_LEN-1 fresh.
    return [_make_candle(PAGE1_LEN - 1 + i) for i in range(PAGE2_LEN)]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Quiet by default.
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        if parsed.path != "/fapi/v1/klines":
            self.send_response(404)
            self.end_headers()
            return
        with _lock:
            _hits["n"] += 1
            n = _hits["n"]
            with open(HIT_FILE, "w") as f:
                f.write(str(n))
        q = parse_qs(parsed.query)
        # Decide page by startTime: first call requests at FIRST_TS, second
        # call advances past page-1 last + STEP_MS.
        start_time = int(q.get("startTime", ["0"])[0])
        if start_time <= FIRST_TS:
            payload = _page1()
        else:
            payload = _page2()
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    with open(HIT_FILE, "w") as f:
        f.write("0")
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
PYFIXTURE

python3 "$FIXTURE_SERVER" "$PORT" "$HIT_COUNT_FILE" "$SERVER_PID_FILE" > "$SERVER_LOG" 2>&1 &
SERVER_BG_PID=$!
echo "$SERVER_BG_PID" > "$SERVER_PID_FILE"

ready=0
for _ in $(seq 1 50); do
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 0.1
done
if [ "$ready" -ne 1 ]; then
    exit_setup_fail "fixture server did not become ready on port $PORT"
fi

# ---------------------------------------------------------------------------
# Run the downloader against the fixture
# ---------------------------------------------------------------------------
# Anchor TS is 2023-11-14 UTC; pick a date range that covers fixture span.
# Page 1 = 1500 * 30m = 750 hours = 31.25 days starting at FIRST_TS.
# Use a wide window so the downloader stops via "short read" on page 2.
SYMBOL="BTCUSDT"
TIMEFRAME="30m"
START_DATE="2023-11-14"
END_DATE="2024-01-31"

if ! python3 "$DOWNLOADER" \
    --symbol "$SYMBOL" \
    --timeframe "$TIMEFRAME" \
    --start "$START_DATE" \
    --end "$END_DATE" \
    --output-dir "$OUTPUT_DIR" \
    --binance-base-url "http://127.0.0.1:$PORT" \
    > "$WORK_DIR/downloader.stdout" 2> "$WORK_DIR/downloader.stderr"; then
    echo "--- downloader stderr ---"
    cat "$WORK_DIR/downloader.stderr"
    echo "--- end downloader stderr ---"
    fail "downloader exited non-zero"
    exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: output CSV file exists at expected shard path
# ---------------------------------------------------------------------------
SHARD_ROOT="$OUTPUT_DIR/$SYMBOL/$TIMEFRAME"
shard_count=$(find "$SHARD_ROOT" -name '*.csv' -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$shard_count" -gt 0 ]; then
    pass "output CSV file(s) exist under $SHARD_ROOT (count=$shard_count)"
else
    fail "no output CSV files found under $SHARD_ROOT"
fi

# ---------------------------------------------------------------------------
# Test 2: every CSV file has the documented header
# ---------------------------------------------------------------------------
EXPECTED_HEADER="timestamp_ms,open,high,low,close,volume,quote_volume,trades,taker_buy_volume,taker_buy_quote_volume"
header_ok=1
while IFS= read -r f; do
    actual="$(head -n 1 "$f")"
    if [ "$actual" != "$EXPECTED_HEADER" ]; then
        header_ok=0
        echo "  bad header in $f: $actual"
    fi
done < <(find "$SHARD_ROOT" -name '*.csv' -type f)
if [ "$header_ok" -eq 1 ]; then
    pass "every CSV file has the expected header"
else
    fail "at least one CSV file has wrong header"
fi

# ---------------------------------------------------------------------------
# Test 3: total row count (excluding headers) = 1999 (1500 + 500 - 1 dedup)
# ---------------------------------------------------------------------------
total_rows=0
while IFS= read -r f; do
    n=$(($(wc -l < "$f") - 1))
    total_rows=$((total_rows + n))
done < <(find "$SHARD_ROOT" -name '*.csv' -type f)
if [ "$total_rows" -eq 1999 ]; then
    pass "total row count = 1999 (de-dup at page boundary worked)"
else
    fail "total row count = $total_rows, expected 1999"
fi

# ---------------------------------------------------------------------------
# Test 4: field projection — column 7 (quote_volume) in CSV must equal
# Binance fixture idx 7 (string formatted as `(100+i) * base`).
# Use the first row of the first shard. Fixture idx 0 = FIRST_TS = 1700000000000,
# base = 30000.0, so quote_volume = 100 * 30000.00 = "3000000.00".
# ---------------------------------------------------------------------------
first_shard="$(find "$SHARD_ROOT" -name '*.csv' -type f | sort | head -n 1)"
first_row="$(sed -n '2p' "$first_shard")"
IFS=',' read -r c_ts c_open c_high c_low c_close c_vol c_qv c_trades c_tbv c_tbqv <<< "$first_row"
if [ "$c_ts" = "1700000000000" ] \
    && [ "$c_open" = "30000.00" ] \
    && [ "$c_qv" = "3000000.00" ] \
    && [ "$c_trades" = "50" ]; then
    pass "field projection — timestamp_ms, open, quote_volume, trades map to Binance idx 0/1/7/8"
else
    fail "field projection mismatch: ts=$c_ts open=$c_open qv=$c_qv trades=$c_trades"
fi

# ---------------------------------------------------------------------------
# Test 5: pagination — exactly 2 GET requests to /fapi/v1/klines
# ---------------------------------------------------------------------------
hits="$(cat "$HIT_COUNT_FILE" 2>/dev/null || echo 0)"
if [ "$hits" = "2" ]; then
    pass "pagination — fixture server received exactly 2 GET requests"
else
    fail "pagination — expected 2 GET requests, got $hits"
fi

# ---------------------------------------------------------------------------
# Test 6: rows monotonically increasing by timestamp_ms (sorted + unique)
# ---------------------------------------------------------------------------
sort_ok=$(python3 - "$SHARD_ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
all_ts = []
for p in sorted(root.glob("*.csv")):
    with open(p) as f:
        next(f)  # skip header
        for line in f:
            ts = int(line.split(",", 1)[0])
            all_ts.append(ts)
if all_ts == sorted(set(all_ts)) and len(all_ts) == len(set(all_ts)):
    print("1")
else:
    print("0")
PY
)
if [ "$sort_ok" = "1" ]; then
    pass "rows are sorted by timestamp_ms ascending and unique"
else
    fail "rows are not strictly sorted/unique by timestamp_ms"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
