#!/usr/bin/env bash
# test-xsectional-paper.sh -- unit tests for xsectional-paper.py (#1197). Fixture
# klines (--klines-file) exercise ranking (long top-K / short bottom-K), prior-
# snapshot settlement (realised forward return), turnover cost, vol-target
# leverage, and cumulative accounting. No network.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAPER="$SCRIPT_DIR/xsectional-paper.py"
[ -f "$PAPER" ] || { echo "FAIL: missing $PAPER" >&2; exit 1; }

PASS=0; FAIL=0
FIX="$(mktemp -d)"; LEDGER="$FIX/ledger.jsonl"; KL="$FIX/klines.json"
trap 'rm -rf "$FIX"' EXIT

# Fixture: 6 symbols, days at base + {0,2,4}*DAY. AAA/BBB up, CCC/DDD flat,
# EEE/FFF down across each 2-day step -> longs={AAA,BBB}, shorts={EEE,FFF}.
python3 - "$KL" <<'PY'
import json, sys
DAY=86400000; base=1700000000000
d0,d2,d4 = base, base+2*DAY, base+4*DAY
kl={
 "AAAUSDT":{d0:100,d2:130,d4:143},   # +30% then +10%
 "BBBUSDT":{d0:100,d2:120,d4:126},   # +20% then +5%
 "CCCUSDT":{d0:100,d2:100,d4:100},   # flat
 "DDDUSDT":{d0:100,d2:100,d4:100},   # flat
 "EEEUSDT":{d0:100,d2:80, d4:76},    # -20% then -5%
 "FFFUSDT":{d0:100,d2:70, d4:63},    # -30% then -10%
}
json.dump({s:{str(t):v for t,v in d.items()} for s,d in kl.items()}, open(sys.argv[1],"w"))
PY
BASE=1700000000000; DAY=86400000
NOW1=$((BASE+2*DAY)); NOW2=$((BASE+4*DAY))
SYMS="AAAUSDT,BBBUSDT,CCCUSDT,DDDUSDT,EEEUSDT,FFFUSDT"

field() { python3 -c 'import sys,json;print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
jlist() { python3 -c 'import sys,json;print(",".join(json.loads(sys.argv[1])[sys.argv[2]]))' "$1" "$2"; }
assert_eq() { python3 -c 'import sys;sys.exit(0 if abs(float(sys.argv[1])-float(sys.argv[2]))<1e-4 else 1)' "$2" "$3" \
  && { echo "[PASS] $1 (=$2)"; PASS=$((PASS+1)); } || { echo "[FAIL] $1 got=$2 want=$3"; FAIL=$((FAIL+1)); }; }
assert_str() { [ "$2" = "$3" ] && { echo "[PASS] $1 (=$2)"; PASS=$((PASS+1)); } || { echo "[FAIL] $1 got=$2 want=$3"; FAIL=$((FAIL+1)); }; }

# Snapshot 1 at NOW1: rank trailing [NOW1-2d, NOW1] -> longs AAA,BBB / shorts EEE,FFF; no prior.
python3 "$PAPER" --symbols "$SYMS" --ledger "$LEDGER" --top-k 2 --lookback-days 2 \
  --cost-bps-roundtrip 60 --rebalance-days 2 --klines-file "$KL" --now "$NOW1" >/dev/null
R1="$(tail -1 "$LEDGER")"
assert_str "1a. snapshot1 longs = AAAUSDT,BBBUSDT" "$(jlist "$R1" longs)" "AAAUSDT,BBBUSDT"
assert_str "1b. snapshot1 shorts = EEEUSDT,FFFUSDT" "$(jlist "$R1" shorts)" "EEEUSDT,FFFUSDT"
assert_eq  "1c. snapshot1 leverage 1.0 (no history)" "$(field "$R1" leverage)" "1.0"
assert_eq  "1d. snapshot1 period_net 0 (no prior)" "$(field "$R1" period_net_pct)" "0"

# Snapshot 2 at NOW2: settle prior. fwd longs mean(+10,+5)=7.5%, shorts mean(-5,-10)=-7.5%
# -> gross = 15%; basket unchanged -> turnover 0; lev_prev 1.0 -> net +15%; cumulative 15%.
python3 "$PAPER" --symbols "$SYMS" --ledger "$LEDGER" --top-k 2 --lookback-days 2 \
  --cost-bps-roundtrip 60 --rebalance-days 2 --klines-file "$KL" --now "$NOW2" >/dev/null
R2="$(tail -1 "$LEDGER")"
assert_eq  "2a. snapshot2 period_gross = 15%" "$(field "$R2" period_gross_pct)" "15"
assert_eq  "2b. snapshot2 period_net = 15% (lev 1, turnover 0)" "$(field "$R2" period_net_pct)" "15"
assert_eq  "2c. cumulative = 15%" "$(field "$R2" cumulative_net_pct)" "15"
assert_str "2d. snapshot2 basket unchanged (longs)" "$(jlist "$R2" longs)" "AAAUSDT,BBBUSDT"

# Turnover-cost path: settle the SAME prior but force a basket change by dropping
# AAA/EEE from the universe at NOW2 -> new longs/shorts differ -> turnover>0 -> cost bites.
LEDGER2="$FIX/ledger2.jsonl"; cp "$LEDGER" "$LEDGER2"  # reuse snapshot1+2? no -> fresh
: > "$LEDGER2"
python3 "$PAPER" --symbols "$SYMS" --ledger "$LEDGER2" --top-k 2 --lookback-days 2 \
  --cost-bps-roundtrip 60 --rebalance-days 2 --klines-file "$KL" --now "$NOW1" >/dev/null
python3 "$PAPER" --symbols "BBBUSDT,CCCUSDT,DDDUSDT,EEEUSDT,FFFUSDT,AAAUSDT" --ledger "$LEDGER2" --top-k 3 --lookback-days 2 \
  --cost-bps-roundtrip 60 --rebalance-days 2 --klines-file "$KL" --now "$NOW2" >/dev/null
R3="$(tail -1 "$LEDGER2")"
# with top-k 3 at NOW2 the prior was top-k 2; basket differs -> turnover>0 -> net < gross
gross3="$(field "$R3" period_gross_pct)"; net3="$(field "$R3" period_net_pct)"
python3 -c 'import sys;sys.exit(0 if float(sys.argv[1])>float(sys.argv[2]) else 1)' "$gross3" "$net3" \
  && { echo "[PASS] 3. turnover cost makes net < gross ($net3 < $gross3)"; PASS=$((PASS+1)); } \
  || { echo "[FAIL] 3. expected net<gross got net=$net3 gross=$gross3"; FAIL=$((FAIL+1)); }

# Insufficient symbols -> exit 2
python3 "$PAPER" --symbols "AAAUSDT,BBBUSDT" --ledger "$FIX/l3" --top-k 2 --klines-file "$KL" --now "$NOW1" >/dev/null 2>&1 \
  && { echo "[FAIL] 4. too-few-symbols should exit nonzero"; FAIL=$((FAIL+1)); } \
  || { echo "[PASS] 4. too-few-symbols exits nonzero"; PASS=$((PASS+1)); }

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
