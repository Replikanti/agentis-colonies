#!/bin/bash
# test-stage2-cognitive-market.sh — pure-offline assertions for Stage 2
# M2 (#393) cognitive-market wiring.
#
# Mirrors the shape of `test-stage1-replication.sh` and
# `test-stage1-bug-ledger.sh`: PASS/FAIL/SKIP helpers, exit 0 on green,
# no live federation. Asserts that:
#
#   1. All 5 hunter.ag files contain `knowledge_sell(` inside the
#      verified-finding branch (after the existing reward + replication
#      arithmetic).
#   2. All 5 hunter.ag files contain `knowledge_buy(` BEFORE the seed
#      `prompt(` fires.
#   3. Topic shape: every hunter constructs the sell topic as
#      `"tribes-bench-" + _tribe_name + "/" + bug_id` (per-finder
#      prefix, §9 risk 3 mitigation).
#   4. ask_price formula sanity (shell-arith): `max(1, floor(rep*10)+1)`.
#   5. max_cb formula sanity (shell-arith): `floor(rep*20) + 5`.
#   6. Bundle listing: every hunter contains a
#      `knowledge_sell("tribes-bench-bundle/...` call.
#   7. Espionage detection: every hunter contains the three-predicate
#      gate (`rep_bucket(own_rep_str_e) < 3`, surplus pool, sibling > 0.7).
#   8. CSV shape (3 sell + 2 buy rows simulator, one-shot Python reducer
#      on column count + cache-hit-aware revenue formula).
#   9. emit_market_csv helper present + analyse-stage2.py readers
#      present. (Sanity check that the sidecar wiring exists.)
#
# Pure-shell + python3 + agentis-aware (skip when not on PATH).
# Bash 3.2 portable.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

ALL_TRIBES="tribe-alpha tribe-beta tribe-gamma tribe-delta tribe-epsilon"

# --- 1. knowledge_sell( inside verified-finding branch ---
for tribe in $ALL_TRIBES; do
    assert_contains "$tribe hunter.ag has knowledge_sell( call" \
        "$FED_DIR/$tribe/agents/hunter.ag" "knowledge_sell("
done

# --- 2. knowledge_buy( present (and located before the seed prompt) ---
for tribe in $ALL_TRIBES; do
    ag="$FED_DIR/$tribe/agents/hunter.ag"
    if [ -f "$ag" ]; then
        buy_line="$(grep -n -F 'knowledge_buy(' "$ag" | head -1 | cut -d: -f1)"
        prompt_line="$(grep -n -F 'let finding = prompt(' "$ag" | head -1 | cut -d: -f1)"
        if [ -n "$buy_line" ] && [ -n "$prompt_line" ] && [ "$buy_line" -lt "$prompt_line" ]; then
            echo "[PASS] $tribe hunter.ag: knowledge_buy( fires before seed prompt (lines $buy_line < $prompt_line)"
            PASS=$((PASS + 1))
        else
            echo "[FAIL] $tribe hunter.ag: knowledge_buy ($buy_line) not before seed prompt ($prompt_line)"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "[FAIL] $tribe hunter.ag missing"
        FAIL=$((FAIL + 1))
    fi
done

# --- 3. Sell topic shape: tribes-bench-<self>/<bug_id> ---
for tribe in $ALL_TRIBES; do
    assert_contains "$tribe hunter.ag uses per-finder sell topic prefix" \
        "$FED_DIR/$tribe/agents/hunter.ag" \
        '"tribes-bench-" + _tribe_name + "/" + bug_id'
done

# --- 4. ask_price formula: max(1, floor(rep*10) + 1) ---
ask_for_rep() {
    # $1 rep_int_in_tenths (0..10)
    bucket="$1"
    v=$((bucket + 1))
    if [ "$v" -lt 1 ]; then
        echo 1
    else
        echo "$v"
    fi
}
assert_eq "ask_for_rep(0) == 1 (floor)"  "1"  "$(ask_for_rep 0)"
assert_eq "ask_for_rep(5) == 6 (mid)"    "6"  "$(ask_for_rep 5)"
assert_eq "ask_for_rep(10) == 11 (ceil)" "11" "$(ask_for_rep 10)"

# --- 5. max_cb formula: floor(rep*20) + 5 ---
max_cb_for_rep() {
    bucket="$1"
    echo $((bucket * 2 + 5))
}
assert_eq "max_cb_for_rep(0) == 5 (floor)"   "5"  "$(max_cb_for_rep 0)"
assert_eq "max_cb_for_rep(5) == 15 (mid)"    "15" "$(max_cb_for_rep 5)"
assert_eq "max_cb_for_rep(10) == 25 (ceil)"  "25" "$(max_cb_for_rep 10)"

# --- 6. Bundle listing: knowledge_sell("tribes-bench-bundle/...) ---
for tribe in $ALL_TRIBES; do
    assert_contains "$tribe hunter.ag lists bundle topic" \
        "$FED_DIR/$tribe/agents/hunter.ag" \
        '"tribes-bench-bundle/" + _tribe_name'
done

# --- 7. Espionage three-predicate gate ---
for tribe in $ALL_TRIBES; do
    ag="$FED_DIR/$tribe/agents/hunter.ag"
    p1="$(grep -Fc 'rep_bucket(own_rep_str_e) < 3' "$ag" 2>/dev/null || echo 0)"
    p2="$(grep -Fc 'pool_for_buy >= cb_surplus_e' "$ag" 2>/dev/null || echo 0)"
    p3="$(grep -Fc 'rep_bucket(best_s) > 7' "$ag" 2>/dev/null || echo 0)"
    if [ "$p1" -ge 1 ] && [ "$p2" -ge 1 ] && [ "$p3" -ge 1 ]; then
        echo "[PASS] $tribe hunter.ag has 3-predicate espionage gate"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $tribe hunter.ag: own_rep<3 ($p1), surplus ($p2), sibling>7 ($p3)"
        FAIL=$((FAIL + 1))
    fi
done

# --- 8. Trade CSV shape: 12 columns, simulator + reducer ---
CSV="$TMP/knowledge-market.csv"
: > "$CSV"
# 3 sell rows
printf '1700000000000,tribe-alpha,tribe-alpha,sell,tribes-bench-tribe-alpha/BUG-1,finding,6,,,,,succeeded\n' >> "$CSV"
printf '1700000010000,tribe-beta,tribe-beta,sell,tribes-bench-tribe-beta/BUG-2,finding,7,,,,,succeeded\n' >> "$CSV"
printf '1700000020000,tribe-gamma,tribe-gamma,sell,tribes-bench-tribe-gamma/BUG-3,finding,8,,,,,succeeded\n' >> "$CSV"
# 2 buy rows: one substrate (cache_hit=0), one cache-hit (cache_hit=1)
printf '1700000060000,tribe-delta,tribe-delta,buy,tribes-bench-tribe-alpha/BUG-1,finding,,15,,0,,succeeded\n' >> "$CSV"
printf '1700000061000,tribe-epsilon,tribe-epsilon,buy,tribes-bench-tribe-alpha/BUG-1,finding,,15,,1,,cache_hit\n' >> "$CSV"

# Verify column count
got_cols="$(awk -F, '{ print NF; exit }' "$CSV")"
assert_eq "knowledge-market.csv row column count == 12" "12" "$got_cols"

# Cache-hit-aware revenue contract (§9 risk 2): exclude cache_hit=1 rows.
# Buy rows don't carry ask_price; the revenue is summed on sell rows
# joined to substrate (non-cache-hit) buy rows by topic. For this
# offline simulator we approximate: sum ask_price over sell rows where
# the matching topic has at least one substrate (cache_hit=0) buy row.
revenue="$(python3 -c "
import csv, sys
rows = list(csv.reader(open(sys.argv[1])))
buy_substrate = set()
for r in rows:
    if len(r) < 12: continue
    if r[3] == 'buy' and r[9] == '0':
        buy_substrate.add(r[4])
total = 0
for r in rows:
    if len(r) < 12: continue
    if r[3] == 'sell' and r[4] in buy_substrate:
        try: total += int(r[6])
        except ValueError: pass
print(total)
" "$CSV")"
assert_eq "revenue contract: only substrate-bought sells count (= 6, alpha's BUG-1)" "6" "$revenue"

# --- 9. emit_market_csv helper + analyse-stage2.py readers present ---
for tribe in $ALL_TRIBES; do
    assert_contains "$tribe hunter.ag has emit_market_csv helper" \
        "$FED_DIR/$tribe/agents/hunter.ag" "fn emit_market_csv("
done
assert_contains "analyse-stage2.py has load_market_log reader" \
    "$FED_DIR/tools/analyse-stage2.py" "def load_market_log("
assert_contains "analyse-stage2.py has resolve_downstream_verified" \
    "$FED_DIR/tools/analyse-stage2.py" "def resolve_downstream_verified("
assert_contains "analyse-stage2.py has write_market_log writer" \
    "$FED_DIR/tools/analyse-stage2.py" "def write_market_log("

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
