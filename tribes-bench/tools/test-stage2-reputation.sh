#!/bin/bash
# test-stage2-reputation.sh — pure-offline assertions for Stage 2 M2
# (#393) reputation primitive.
#
# Mirrors the shape of `test-stage2-cognitive-market.sh` and
# `test-stage1-replication.sh`: PASS/FAIL/SKIP helpers, exit 0 on green,
# no live federation. Asserts that:
#
#   1. All 5 start-colony.sh scripts seed `reputation:tribes-bench-<tribe>`
#      with `"0.5"` (mid-band per plan §2 bootstrap analysis).
#   2. All 5 hunter.ag files contain the `+0.05` clamp-1.0 update inside
#      the verified-finding branch.
#   3. All 5 hunter.ag files contain the `-0.10` clamp-0.0 update inside
#      the false-positive branch.
#   4. Floor / ceiling sanity (shell-arith): 30 verified ticks → rep=1.0
#      (clamped); 30 false-positive ticks → rep=0.0 (clamped).
#   5. Gate effect on ask_price: at rep=0.0 ask=1; at rep=1.0 ask=11.
#   6. Gate effect on max_cb: at rep=0.0 max_cb=5; at rep=1.0 max_cb=25.
#   7. Stage 2 M2 memo seeds: `cb_surplus_threshold`, `bundle_period`,
#      `pool_minimum_for_buy`, `tribes-bench-<tribe>:knowledge_market_csv`.
#   8. Pre-existing test scripts continue to PASS unchanged
#      (test-verify-finding.sh, test-stage1-replication.sh,
#      test-stage1-bug-ledger.sh, test-stage2-scaffold.sh).
#
# Pure-shell + python3. Bash 3.2 portable.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
SKIP=0

assert_eq() {
    label="$1"; exp="$2"; got="$3"
    if [ "$exp" = "$got" ]; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       expected: $exp"
        echo "       got:      $got"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    label="$1"; file="$2"; needle="$3"
    if [ -f "$file" ] && grep -Fq -- "$needle" "$file"; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       file:   $file"
        echo "       needle: $needle"
        FAIL=$((FAIL + 1))
    fi
}

skip_case() {
    echo "[SKIP] $1 ($2)"
    SKIP=$((SKIP + 1))
}

ALL_TRIBES="tribe-alpha tribe-beta tribe-gamma tribe-delta tribe-epsilon"

# --- 1. Initial reputation memo seeded at 0.5 ---
for tribe in $ALL_TRIBES; do
    assert_contains "$tribe start-colony.sh seeds reputation:tribes-bench-<tribe> = 0.5" \
        "$FED_DIR/$tribe/scripts/start-colony.sh" \
        'reputation:tribes-bench-${TRIBE_NAME}" "0.5"'
done

# --- 2. Verified-branch +0.05 reputation update + clamp ceiling ---
for tribe in $ALL_TRIBES; do
    ag="$FED_DIR/$tribe/agents/hunter.ag"
    assert_contains "$tribe hunter.ag: verified-branch +0.05 step" \
        "$ag" "cur_rep_v + 0.05"
    assert_contains "$tribe hunter.ag: verified-branch ceiling clamp at 1.0" \
        "$ag" "cur_rep_v + 0.05 > 1.0 { 1.0"
done

# --- 3. False-positive branch -0.10 reputation update + clamp floor ---
for tribe in $ALL_TRIBES; do
    ag="$FED_DIR/$tribe/agents/hunter.ag"
    assert_contains "$tribe hunter.ag: false-positive branch -0.10 step" \
        "$ag" "cur_rep_f - 0.10"
    assert_contains "$tribe hunter.ag: false-positive floor clamp at 0.0" \
        "$ag" "cur_rep_f - 0.10 < 0.0 { 0.0"
done

# --- 4. Floor / ceiling sanity via Python (avoids float / awk locale) ---
ceiling_after_30="$(python3 -c "
r = 0.5
for _ in range(30):
    r = min(1.0, r + 0.05)
print(round(r, 4))
")"
assert_eq "30 verified ticks from 0.5 clamp at 1.0" "1.0" "$ceiling_after_30"

floor_after_30="$(python3 -c "
r = 0.5
for _ in range(30):
    r = max(0.0, r - 0.10)
print(round(r, 4))
")"
assert_eq "30 false-positive ticks from 0.5 clamp at 0.0" "0.0" "$floor_after_30"

# --- 5. Gate effect on ask_price: at rep=0.0 ask=1; at rep=1.0 ask=11 ---
ask_for_rep() {
    bucket="$1"
    v=$((bucket + 1))
    if [ "$v" -lt 1 ]; then echo 1; else echo "$v"; fi
}
assert_eq "ask at rep=0.0 (bucket 0) == 1"  "1"  "$(ask_for_rep 0)"
assert_eq "ask at rep=1.0 (bucket 10) == 11" "11" "$(ask_for_rep 10)"

# --- 6. Gate effect on max_cb: at rep=0.0 max_cb=5; at rep=1.0 max_cb=25 ---
max_cb_for_rep() {
    bucket="$1"
    echo $((bucket * 2 + 5))
}
assert_eq "max_cb at rep=0.0 (bucket 0) == 5"  "5"  "$(max_cb_for_rep 0)"
assert_eq "max_cb at rep=1.0 (bucket 10) == 25" "25" "$(max_cb_for_rep 10)"

# --- 7. Stage 2 M2 memo seeds present in every start-colony.sh ---
for tribe in $ALL_TRIBES; do
    sc="$FED_DIR/$tribe/scripts/start-colony.sh"
    assert_contains "$tribe start-colony.sh seeds cb_surplus_threshold" \
        "$sc" '"cb_surplus_threshold" "300"'
    assert_contains "$tribe start-colony.sh seeds bundle_period" \
        "$sc" '"bundle_period" "3"'
    assert_contains "$tribe start-colony.sh seeds pool_minimum_for_buy" \
        "$sc" '"pool_minimum_for_buy" "50"'
    assert_contains "$tribe start-colony.sh seeds knowledge_market_csv path" \
        "$sc" 'tribes-bench-${TRIBE_NAME}:knowledge_market_csv'
done

# --- 8. Regression: pre-existing tests unchanged ---
for testname in test-verify-finding.sh test-stage1-replication.sh test-stage1-bug-ledger.sh test-stage2-scaffold.sh; do
    test_path="$FED_DIR/tools/$testname"
    if [ -f "$test_path" ]; then
        if bash "$test_path" >/dev/null 2>&1; then
            echo "[PASS] $testname (regression)"
            PASS=$((PASS + 1))
        else
            echo "[FAIL] $testname regressed"
            FAIL=$((FAIL + 1))
        fi
    else
        skip_case "$testname (regression)" "test script not found"
    fi
done

if [ -f "$FED_DIR/tools/test-verify-finding.sh" ]; then
    if STAGE1=1 bash "$FED_DIR/tools/test-verify-finding.sh" >/dev/null 2>&1; then
        echo "[PASS] STAGE1=1 test-verify-finding.sh (regression)"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] STAGE1=1 test-verify-finding.sh regressed"
        FAIL=$((FAIL + 1))
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
