#!/usr/bin/env bash
# test-carry-verify.sh -- unit tests for carry-verify.sh (#1175 M1).
# Builds a fixed funding-CSV fixture in a tempdir and exercises the
# delta-neutral carry settlement: known funding -> known carry, weighting,
# turnover cost, cash/empty, missing data.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFIER="$SCRIPT_DIR/carry-verify.sh"

if [ ! -x "$VERIFIER" ]; then
    echo "FAIL: verifier not executable: $VERIFIER" >&2
    exit 1
fi

PASS=0
FAIL=0

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# LINKUSDT: funding 0.0003 + 0.0004 + 0.0003 = 0.0010 over [1000,3500) -> 10 bps at weight 1.0
printf 'fundingTime,fundingRate\n1000,0.0003\n2000,0.0004\n3000,0.0003\n4000,0.0009\n' > "$FIX/LINKUSDT.csv"
# AAVEUSDT: 0.0002 + 0.0002 = 0.0004 over [1000,3500) -> 4 bps at weight 1.0
# (the -0.0001 at 4000 is OUTSIDE the [1000,3500) test window)
printf 'fundingTime,fundingRate\n1000,0.0002\n2000,0.0002\n4000,-0.0001\n' > "$FIX/AAVEUSDT.csv"
# NEGUSDT: negative funding (short-perp PAYS): -0.0005 over [1000,3500)
printf 'fundingTime,fundingRate\n1000,-0.0002\n2000,-0.0003\n' > "$FIX/NEGUSDT.csv"

# field <json> <key> -> numeric value
jget() { python3 -c 'import sys,json; v=json.loads(sys.argv[1]); print(v[sys.argv[2]])' "$1" "$2"; }

assert_eq() {
    # $1 label, $2 got, $3 want (numeric, tolerance 1e-6)
    local label="$1" got="$2" want="$3"
    if python3 -c 'import sys; g=float(sys.argv[1]); w=float(sys.argv[2]); sys.exit(0 if abs(g-w)<1e-6 else 1)' "$got" "$want"; then
        echo "[PASS] $label (=$got)"; PASS=$((PASS+1))
    else
        echo "[FAIL] $label got=$got want=$want"; FAIL=$((FAIL+1))
    fi
}

# 1. single symbol, full weight, positive funding -> 10 bps carry, no prev -> turnover full (cost = 20*1/2 = 10)
V="$(DECISION_JSON='{"positions":[{"symbol":"LINKUSDT","weight":1.0}]}' FUNDING_DIR="$FIX" \
     SETTLE_START=1000 SETTLE_END=3500 COST_BPS_ROUNDTRIP=20 "$VERIFIER")"
assert_eq "1a. carry_bps single LINK weight1" "$(jget "$V" carry_bps)" "10.0"
assert_eq "1b. turnover_cost from-cash (turnover=1, cost=20*1/2)" "$(jget "$V" turnover_cost_bps)" "10.0"
assert_eq "1c. net_bps = carry - cost" "$(jget "$V" net_bps)" "0.0"

# 2. positive funding => positive carry (delta-neutral short-perp receives)
V="$(DECISION_JSON='{"positions":[{"symbol":"LINKUSDT","weight":0.5}]}' FUNDING_DIR="$FIX" \
     SETTLE_START=1000 SETTLE_END=3500 PREV_POSITIONS_JSON='{"positions":[{"symbol":"LINKUSDT","weight":0.5}]}' "$VERIFIER")"
assert_eq "2a. weight 0.5 -> 5 bps carry" "$(jget "$V" carry_bps)" "5.0"
assert_eq "2b. unchanged basket -> 0 turnover cost" "$(jget "$V" turnover_cost_bps)" "0.0"

# 3. negative funding -> negative carry (short-perp pays)
V="$(DECISION_JSON='{"positions":[{"symbol":"NEGUSDT","weight":1.0}]}' FUNDING_DIR="$FIX" \
     SETTLE_START=1000 SETTLE_END=3500 PREV_POSITIONS_JSON='{"positions":[{"symbol":"NEGUSDT","weight":1.0}]}' "$VERIFIER")"
assert_eq "3. negative funding -> -5 bps carry" "$(jget "$V" carry_bps)" "-5.0"

# 4. multi-symbol weighted basket: 0.5*LINK(10) + 0.5*AAVE(4) = 5 + 2 = 7 bps
V="$(DECISION_JSON='{"positions":[{"symbol":"LINKUSDT","weight":0.5},{"symbol":"AAVEUSDT","weight":0.5}]}' FUNDING_DIR="$FIX" \
     SETTLE_START=1000 SETTLE_END=3500 PREV_POSITIONS_JSON='{"positions":[{"symbol":"LINKUSDT","weight":0.5},{"symbol":"AAVEUSDT","weight":0.5}]}' "$VERIFIER")"
assert_eq "4. weighted basket carry 0.5*10 + 0.5*4" "$(jget "$V" carry_bps)" "7.0"

# 5. cash / empty positions -> 0 carry, 0 cost
V="$(DECISION_JSON='{"positions":[]}' FUNDING_DIR="$FIX" SETTLE_START=1000 SETTLE_END=3500 "$VERIFIER")"
assert_eq "5a. empty basket carry 0" "$(jget "$V" carry_bps)" "0.0"
assert_eq "5b. empty basket cost 0" "$(jget "$V" turnover_cost_bps)" "0.0"

# 6. turnover cost on rotation: prev=LINK(1.0), new=AAVE(1.0) -> turnover=2, cost=20*2/2=20
V="$(DECISION_JSON='{"positions":[{"symbol":"AAVEUSDT","weight":1.0}]}' FUNDING_DIR="$FIX" \
     SETTLE_START=1000 SETTLE_END=3500 COST_BPS_ROUNDTRIP=20 \
     PREV_POSITIONS_JSON='{"positions":[{"symbol":"LINKUSDT","weight":1.0}]}' "$VERIFIER")"
assert_eq "6a. full rotation turnover cost (turnover=2)" "$(jget "$V" turnover_cost_bps)" "20.0"
assert_eq "6b. rotated carry = AAVE 4 bps" "$(jget "$V" carry_bps)" "4.0"

# 7. missing symbol data -> funding 0 (graceful)
V="$(DECISION_JSON='{"positions":[{"symbol":"NOSUCHUSDT","weight":1.0}]}' FUNDING_DIR="$FIX" \
     SETTLE_START=1000 SETTLE_END=3500 PREV_POSITIONS_JSON='{"positions":[{"symbol":"NOSUCHUSDT","weight":1.0}]}' "$VERIFIER")"
assert_eq "7. missing-data symbol -> 0 carry" "$(jget "$V" carry_bps)" "0.0"

# 8. window selection: tighter window [1000,2500) picks only first two LINK events 0.0003+0.0004=0.0007 -> 7 bps
V="$(DECISION_JSON='{"positions":[{"symbol":"LINKUSDT","weight":1.0}]}' FUNDING_DIR="$FIX" \
     SETTLE_START=1000 SETTLE_END=2500 PREV_POSITIONS_JSON='{"positions":[{"symbol":"LINKUSDT","weight":1.0}]}' "$VERIFIER")"
assert_eq "8. forward-window funding sum [1000,2500)" "$(jget "$V" carry_bps)" "7.0"

# 9. bad args -> exit 2
if DECISION_JSON='{"positions":[]}' FUNDING_DIR="$FIX" SETTLE_START=abc SETTLE_END=3500 "$VERIFIER" >/dev/null 2>&1; then
    echo "[FAIL] 9. bad SETTLE_START should exit 2"; FAIL=$((FAIL+1))
else
    echo "[PASS] 9. bad SETTLE_START exits non-zero"; PASS=$((PASS+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
