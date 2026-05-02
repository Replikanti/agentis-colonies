#!/bin/bash
# test-stage2-analyse-comparison.sh — Stage 2 M3 (#394) comparison
# report assertions. Pure fixture-driven, NO live agentis spawn.
#
# Mirrors the shape of test-stage2-cognitive-market.sh: PASS/FAIL/SKIP
# helpers, exit 0 on green. Implements the 8 cases from §5 Test C of
# the plan.
#
# Cases:
#   1. analyse-stage2.py --baseline <path> requires the path arg.
#   2. analyse-stage2.py without --baseline produces telemetry.csv but
#      no comparison.md (back-compat).
#   3. analyse-stage2.py --baseline <fixture-csv> produces comparison.md
#      with the 5 fixed sections in the documented order.
#   4. comparison.md section 5 reports `_no market activity in this run_`
#      when knowledge-market.csv is missing or empty.
#   5. comparison.md section 5 reports substrate revenue arithmetic
#      correctly: substrate-bought sells count, cache-hit sells exclude.
#   6. comparison.md section 1: findings/TPs/FPs/first-finder ticks
#      arithmetic vs the fixture.
#   7. comparison.md section 2: cost-per-TP arithmetic (CB / TP).
#   8. comparison.md section 3+4: replication events + run-shape minutes
#      + tribe count arithmetic.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"
ANALYSER="$FED_DIR/tools/analyse-stage2.py"

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

# ---- Build a fixture run-dir + a fixture baseline CSV ----------------------
# A fully self-contained fixture: a single experience JSONL with mixed
# verified + false-positive + observed rows; a single spend JSONL; and a
# knowledge-market.csv with 1 substrate buy + 1 cache-hit buy + 2 sell
# rows (one of which is for the substrate-bought topic).
make_fixture_run_dir() {
    rd="$1"
    mkdir -p "$rd/.agentis/daemon" "$rd/.agentis/experience" "$rd/.agentis/spend"
    # Daemon -> tribe mapping
    printf 'tribe-alpha' > "$rd/.agentis/daemon/agt-1.colony"
    # Experience JSONL: 2 acted (verified), 1 false-positive, 1 observed,
    # 1 replicated, all tagged tribes-bench.
    printf '%s\n' \
        '{"ts": 1700000060000, "topic": "hunt", "subject": "line 10", "outcome": "S2-SMVUAF-001", "tags": ["acted", "tribes-bench", "tribe-alpha", "reward=200"]}' \
        '{"ts": 1700000120000, "topic": "hunt", "subject": "line 20", "outcome": "S2-SMVMEM-001", "tags": ["acted", "tribes-bench", "tribe-alpha", "reward=50"]}' \
        '{"ts": 1700000180000, "topic": "hunt", "subject": "line 30", "outcome": "fp", "tags": ["false-positive", "tribes-bench"]}' \
        '{"ts": 1700000240000, "topic": "hunt", "subject": "line 40", "outcome": "obs", "tags": ["observed", "tribes-bench"]}' \
        '{"ts": 1700000300000, "topic": "replicate", "subject": "n=0", "outcome": "cost=100", "tags": ["replicated", "tribes-bench", "tribe-alpha"]}' \
        > "$rd/.agentis/experience/agt-1.jsonl"
    # Spend JSONL: 5 prompt() spends of 50 CB each = 250 CB total.
    printf '%s\n' \
        '{"ts": 1700000060000, "cb": 50, "colony": "tribe-alpha"}' \
        '{"ts": 1700000120000, "cb": 50, "colony": "tribe-alpha"}' \
        '{"ts": 1700000180000, "cb": 50, "colony": "tribe-alpha"}' \
        '{"ts": 1700000240000, "cb": 50, "colony": "tribe-alpha"}' \
        '{"ts": 1700000300000, "cb": 50, "colony": "tribe-alpha"}' \
        > "$rd/.agentis/spend/agt-1.jsonl"
    : > "$rd/bug-ledger.jsonl"
}

make_fixture_baseline_csv() {
    bc="$1"
    # Header + 1 row of synthetic baseline aggregates: 1 finding, 1 TP,
    # 0 FPs, 60 CB. So baseline CB/TP = 60.
    printf 'minute,tribe,agents_alive,cb_balance,findings_emitted,true_positives,false_positives,bug_class,is_first_finder,tribe_size,replication_event_count,tribe_death_ts\n' > "$bc"
    printf '28333334,tribe-baseline,1,60,1,1,0,use_after_free,1,1,0,\n' >> "$bc"
}

make_market_csv_with_revenue() {
    csv="$1"
    # 1 substrate buy (cache_hit=0) for topic alpha/BUG-1
    printf '1700000060000,tribe-delta,tribe-delta,buy,tribes-bench-tribe-alpha/BUG-1,finding,,15,,0,,succeeded\n' > "$csv"
    # 1 cache-hit buy (cache_hit=1) for topic alpha/BUG-1
    printf '1700000061000,tribe-epsilon,tribe-epsilon,buy,tribes-bench-tribe-alpha/BUG-1,finding,,15,,1,,cache_hit\n' >> "$csv"
    # 1 sell for the substrate-bought topic at ask_price 6 (counts).
    printf '1700000020000,tribe-alpha,tribe-alpha,sell,tribes-bench-tribe-alpha/BUG-1,finding,6,,,,,succeeded\n' >> "$csv"
    # 1 sell for a topic with NO substrate buy, ask_price 7 (must NOT count).
    printf '1700000021000,tribe-beta,tribe-beta,sell,tribes-bench-tribe-beta/BUG-2,finding,7,,,,,succeeded\n' >> "$csv"
}

# Need a federation-style parent dir so analyse-stage2.py's bug-class
# lookup can find targets/stage2/bugs.json. Mock the layout under TMP.
FAKE_FED="$TMP/fakefed"
mkdir -p "$FAKE_FED/runs" "$FAKE_FED/targets/stage2"
# Minimal bugs.json (the fixture references S2-SMVUAF-001 + S2-SMVMEM-001).
printf '%s' '{"bugs": [{"id": "S2-SMVUAF-001", "class": "use_after_free"}, {"id": "S2-SMVMEM-001", "class": "uninitialised_memory"}]}' > "$FAKE_FED/targets/stage2/bugs.json"

# Common run-dir under FAKE_FED so dirname/dirname reaches FAKE_FED.
RD1="$FAKE_FED/runs/20260101T000000Z"
make_fixture_run_dir "$RD1"
BASELINE_CSV="$TMP/baseline.csv"
make_fixture_baseline_csv "$BASELINE_CSV"

# --- 1. --baseline requires path ---
set +e
out="$(python3 "$ANALYSER" "$RD1" --baseline 2>&1)"
ec=$?
set -e
if [ "$ec" != "0" ] && printf '%s' "$out" | grep -qF "requires a path"; then
    echo "[PASS] --baseline requires a path"
    PASS=$((PASS + 1))
else
    echo "[FAIL] --baseline missing-arg path: ec=$ec out=$out"
    FAIL=$((FAIL + 1))
fi

# --- 2. Without --baseline: byte-identical to M2 (no comparison.md) ---
RD2="$FAKE_FED/runs/20260102T000000Z"
make_fixture_run_dir "$RD2"
python3 "$ANALYSER" "$RD2" >/dev/null 2>&1
if [ -f "$RD2/telemetry.csv" ] && [ ! -f "$RD2/comparison.md" ]; then
    echo "[PASS] no --baseline -> no comparison.md (back-compat)"
    PASS=$((PASS + 1))
else
    echo "[FAIL] no --baseline produced unexpected comparison.md"
    FAIL=$((FAIL + 1))
fi

# --- 3. With --baseline: comparison.md emitted with 5 sections ---
RD3="$FAKE_FED/runs/20260103T000000Z"
make_fixture_run_dir "$RD3"
python3 "$ANALYSER" "$RD3" --baseline "$BASELINE_CSV" >/dev/null 2>&1
CMP3="$RD3/comparison.md"
if [ -f "$CMP3" ]; then
    assert_contains "comparison.md section 1 header" "$CMP3" "## 1. Findings volume"
    assert_contains "comparison.md section 2 header" "$CMP3" "## 2. Cost per true positive"
    assert_contains "comparison.md section 3 header" "$CMP3" "## 3. Replication / tribe-size dynamics"
    assert_contains "comparison.md section 4 header" "$CMP3" "## 4. Run shape"
    assert_contains "comparison.md section 5 header" "$CMP3" "## 5. Knowledge market activity"
    # Verify section order via a python helper (no awk locale gotchas).
    order_ok="$(python3 -c "
import sys
text = open('$CMP3').read()
keys = ['## 1.', '## 2.', '## 3.', '## 4.', '## 5.']
positions = [text.find(k) for k in keys]
print('OK' if all(p >= 0 for p in positions) and positions == sorted(positions) else 'BAD')
")"
    assert_eq "comparison.md sections in fixed order" "OK" "$order_ok"
else
    echo "[FAIL] comparison.md not produced for --baseline run"
    FAIL=$((FAIL + 1))
fi

# --- 4. Section 5 reports _no market activity_ when CSV missing/empty ---
assert_contains "section 5 says no market activity (no CSV)" "$CMP3" "_no market activity in this run_"

# Empty CSV must also yield the no-activity message.
RD3b="$FAKE_FED/runs/20260103T000001Z"
make_fixture_run_dir "$RD3b"
: > "$RD3b/knowledge-market.csv"
python3 "$ANALYSER" "$RD3b" --baseline "$BASELINE_CSV" >/dev/null 2>&1
assert_contains "section 5 says no market activity (empty CSV)" "$RD3b/comparison.md" "_no market activity in this run_"

# --- 5. Section 5 substrate revenue arithmetic ---
RD4="$FAKE_FED/runs/20260104T000000Z"
make_fixture_run_dir "$RD4"
make_market_csv_with_revenue "$RD4/knowledge-market.csv"
python3 "$ANALYSER" "$RD4" --baseline "$BASELINE_CSV" >/dev/null 2>&1
CMP4="$RD4/comparison.md"
assert_contains "section 5 substrate revenue line present" "$CMP4" "substrate revenue (cache_hit=0 only)"
assert_contains "section 5 substrate revenue == 6 (alpha BUG-1 only)" "$CMP4" "| substrate revenue (cache_hit=0 only) | 6 |"
assert_contains "section 5 buy ops == 2" "$CMP4" "| buy ops | 2 |"
assert_contains "section 5 sell ops == 2" "$CMP4" "| sell ops | 2 |"
assert_contains "section 5 cache-hit buys == 1" "$CMP4" "| cache-hit buys | 1 |"

# --- 6. Section 1 findings/TPs/FPs/first-finder arithmetic ---
# Fixture: 2 acted, 1 false-positive, 1 observed, 1 replicated.
# findings_emitted = 4 (acted+fp+observed -> +1 each), TPs=2, FPs=1.
# first-finder ticks: depends on bug-ledger which is empty -> 0.
assert_contains "section 1 findings_emitted == 4" "$CMP4" "| total findings | 4 |"
assert_contains "section 1 true positives == 2" "$CMP4" "| true positives | 2 |"
assert_contains "section 1 false positives == 1" "$CMP4" "| false positives | 1 |"
assert_contains "section 1 first-finder ticks == 0" "$CMP4" "| first-finder ticks | 0 |"

# --- 7. Section 2 cost-per-TP arithmetic: 250 CB / 2 TPs = 125.00 ---
assert_contains "section 2 total CB == 250" "$CMP4" "| total CB | 250 |"
assert_contains "section 2 TPs == 2" "$CMP4" "| TPs | 2 |"
assert_contains "section 2 CB / TP == 125.00" "$CMP4" "| CB / TP | 125.00 |"

# --- 8. Section 3+4 arithmetic ---
# replication_event_count: 1 row tagged "replicated" -> 1.
# distinct minutes covered: 5 distinct ts -> 5 minute buckets.
# distinct tribes seen: 1 (tribe-alpha).
assert_contains "section 3 replication events == 1" "$CMP4" "| replication events | 1 |"
assert_contains "section 4 distinct minutes covered == 5" "$CMP4" "| distinct minutes covered | 5 |"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
