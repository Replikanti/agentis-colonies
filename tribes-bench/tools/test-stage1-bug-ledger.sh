#!/bin/bash
# test-stage1-bug-ledger.sh — race-resilience smoke for the M3 ledger.
#
# Spawns 10 background workers that each append 10 simulated finding
# rows to the bug-ledger.jsonl over 10 distinct bug_ids (so each
# worker writes to every bug once with a randomly-stagged ts). Then
# runs the same first-finder reduction analyse-stage1.py uses (group
# by bug_id, take min(ts) tribe) and asserts that for every bug_id
# exactly one tribe is the first finder.
#
# Why this matters: the in-band reward path uses a memo-based check
# that races; the analyser determines first-finder POST-HOC. This test
# confirms the post-hoc reduction is correct in the worst-case where
# every tribe finds every bug almost simultaneously.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LEDGER="$TMP/bug-ledger.jsonl"
: > "$LEDGER"

# 10 simulated finding rows per worker × 10 background workers = 100
# rows total, racing for the same 10 bug_ids.
N_WORKERS=10
N_BUGS=10

i=0
while [ "$i" -lt "$N_WORKERS" ]; do
    (
        j=0
        while [ "$j" -lt "$N_BUGS" ]; do
            ts="$(python3 -c 'import time, random; print(int(time.time()*1000) + random.randint(0, 100))')"
            tribe="tribe-$i"
            row="{\"ts\": $ts, \"tribe\": \"$tribe\", \"bug_id\": \"BUG-$j\", \"reward\": 200}"
            printf '%s\n' "$row" >> "$LEDGER"
            j=$((j + 1))
        done
    ) &
    i=$((i + 1))
done

wait

# Sanity: 100 rows total.
got_rows="$(wc -l < "$LEDGER" | tr -d ' ')"
expected_rows=$((N_WORKERS * N_BUGS))
if [ "$got_rows" != "$expected_rows" ]; then
    echo "[FAIL] ledger has $got_rows rows, expected $expected_rows" >&2
    exit 1
fi

# Run the same first-finder reduction analyse-stage1.py uses. Output:
# one line per bug_id of the form `BUG-N <count_first_finders>`. We
# expect every count to be exactly 1.
RESULT="$(python3 "$SCRIPT_DIR/test-stage1-bug-ledger-reduce.py" "$LEDGER")"

PASS=0
FAIL=0
echo "$RESULT" | while IFS=' ' read -r bug_id count; do
    if [ "$count" = "1" ]; then
        echo "[PASS] $bug_id has exactly 1 first-finder"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $bug_id has $count first-finders (expected 1)"
        FAIL=$((FAIL + 1))
    fi
done

# `while read` runs in a subshell so PASS/FAIL counts above are local;
# re-derive the verdict from RESULT to escape the subshell.
TOTAL_BUGS="$(printf '%s\n' "$RESULT" | wc -l | tr -d ' ')"
NON_UNIQUE="$(printf '%s\n' "$RESULT" | awk '$2 != "1" { print }' | wc -l | tr -d ' ')"

echo ""
echo "Results: $TOTAL_BUGS bug_ids checked, $NON_UNIQUE with non-unique first-finder"
[ "$NON_UNIQUE" -eq 0 ] && [ "$TOTAL_BUGS" = "$N_BUGS" ]
