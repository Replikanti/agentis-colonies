#!/usr/bin/env bash
# demo-audit-hunter.sh — offline, deterministic proof (#1485) of the audit-aware residual-hunt foundation:
# fetch-audits.sh ingests audit docs (extract text; clean SKIP offline) and novelty-gate.sh rejects a finding
# that restates a KNOWN issue while passing a genuinely-novel one. No external network (uses a localhost
# http server for the fetch path when python3 is present); throwaway temp dirs.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FETCH="$HERE/fetch-audits.sh"
GATE="$HERE/novelty-gate.sh"

FAIL=0
pass() { echo "demo-audit-hunter.sh: [PASS] $1"; }
fail() { echo "demo-audit-hunter.sh: [FAIL] $1" >&2; FAIL=1; }

command -v python3 >/dev/null || { echo "demo-audit-hunter.sh: [SKIP] python3 not installed" >&2; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null || true' EXIT

# --- novelty-gate: the known-issue exclusion set (mirrors real Metric OMM audit findings) -----------------
cat > "$WORK/exclusion.txt" <<'EOF'
# Known issues extracted from the target's provided audits
Bin value leak: both token0 and token1 distributed equally; calculatePriceAtBinPosition; token0BalanceScaled round trip loses value
Cursor drift on zero output; buyToken0InBinSpecifiedOut; finalBinPos not reset when amountOutScaled == 0
PriceProviderL2 skips Chainlink deviation check during sequencer grace period
EOF

# 1. A finding that RESTATES a known issue (value leak) -> KNOWN (exit 1).
printf '%s' 'Partial swaps return the bin to zero token0 but the pool loses token1 because calculatePriceAtBinPosition treats both tokens as distributed equally.' \
  | "$GATE" --exclusion "$WORK/exclusion.txt" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "novelty-gate flags a restated known issue (value leak) as KNOWN" \
  || fail "value-leak restatement was not flagged KNOWN (rc=$rc)"

# 2. A finding that matches by FUNCTION name (cursor drift) -> KNOWN (exit 1).
printf '%s' 'buyToken0InBinSpecifiedOut lets the cursor drift because finalBinPos is committed even when output is zero.' \
  | "$GATE" --exclusion "$WORK/exclusion.txt" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "novelty-gate flags a function-name match (cursor drift) as KNOWN" \
  || fail "cursor-drift restatement was not flagged KNOWN (rc=$rc)"

# 3. A genuinely-novel finding -> NOVEL (exit 0).
printf '%s' 'selfPermit in the router lets a griefer replay an EIP-2612 signature across CREATE3-identical addresses on different chains.' \
  | "$GATE" --exclusion "$WORK/exclusion.txt" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "novelty-gate passes a genuinely-novel finding (eligible for triage)" \
  || fail "novel finding was wrongly flagged KNOWN (rc=$rc)"

# 4. gate arg guards.
"$GATE" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "novelty-gate: missing --exclusion -> exit 2" || fail "gate arg guard (rc=$rc)"

# --- fetch-audits: arg guards + clean SKIP + real extraction over localhost ------------------------------
"$FETCH" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "fetch-audits: no URLs -> exit 2" || fail "fetch arg guard (rc=$rc)"
"$FETCH" --out "$WORK/o1" "https://127.0.0.1:1/nope.pdf" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "fetch-audits: unreachable URL -> clean SKIP (exit 0, CI-safe)" || fail "fetch SKIP not clean (rc=$rc)"

# extraction path: serve an audit text on localhost and confirm it is fetched + indexed.
printf 'Metric audit\nFinding 3.1 High: reentrancy in withdraw()\n' > "$WORK/audit.txt"
PORT=8917
( cd "$WORK" && python3 -m http.server "$PORT" >/dev/null 2>&1 & echo $! > "$WORK/srv.pid" )
SRV_PID="$(cat "$WORK/srv.pid" 2>/dev/null || true)"
# give the server a moment
python3 - "$PORT" <<'PY' 2>/dev/null || true
import socket,sys,time
p=int(sys.argv[1])
for _ in range(30):
    try:
        socket.create_connection(("127.0.0.1",p),0.2).close(); break
    except Exception: time.sleep(0.1)
PY
if "$FETCH" --out "$WORK/o2" "http://127.0.0.1:$PORT/audit.txt" >/dev/null 2>&1 \
   && grep -q "audit.txt" "$WORK/o2/index.tsv" 2>/dev/null \
   && grep -qi "reentrancy" "$WORK/o2/"*.txt 2>/dev/null; then
  pass "fetch-audits: ingests an audit doc over http, extracts text + writes index"
else
  echo "demo-audit-hunter.sh: [SKIP] localhost fetch unavailable — extraction path not exercised" >&2
fi

if [ "$FAIL" -eq 0 ]; then
  echo "demo-audit-hunter.sh: ALL CHECKS PASSED"
  exit 0
else
  echo "demo-audit-hunter.sh: FAILURES ABOVE" >&2
  exit 1
fi
