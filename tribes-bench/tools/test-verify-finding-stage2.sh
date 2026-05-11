#!/bin/bash
# test-verify-finding-stage2.sh: unit tests for the Stage 2 verifier's
# bug-ledger append path (#491). The classification logic (line-window,
# signature, class predicate) is covered by `test-verify-finding.sh`'s
# STAGE1=1 mode against the shared verifier surface; this test focuses
# narrowly on the ledger-write branch that closes the Loose category (a)
# gaming surface.
#
# Cases:
#   1. verified=true + BUG_LEDGER_PATH + TRIBE_NAME set
#      -> row appended, JSON well-formed, tribe + bug_id + reward match,
#         reward is LEDGER_REWARD_FULL (no prior row for this bug_id).
#   2. verified=false
#      -> no append, ledger file untouched.
#   3. BUG_LEDGER_PATH unset (Stage 0/1 caller shape)
#      -> verifier exits 0 with a well-formed verdict and writes nothing.
#   4. Two calls with the same bug_id from different tribes
#      -> first tribe row carries LEDGER_REWARD_FULL,
#         second tribe row carries LEDGER_REWARD_SUBSEQUENT.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

VERIFIER="$SCRIPT_DIR/verify-finding-stage2.sh"
TARGET_DIR="$FED_DIR/targets/stage2/smallvec-v0.6.13"
BUGS_MANIFEST="$FED_DIR/targets/stage2/bugs.json"

if [ ! -x "$VERIFIER" ]; then
    echo "Error: verify-finding-stage2.sh not found or not executable at $VERIFIER" >&2
    exit 1
fi

if [ ! -f "$BUGS_MANIFEST" ]; then
    echo "Error: bugs.json not found at $BUGS_MANIFEST" >&2
    exit 1
fi

# Pull the first verified bug fixture from the manifest so the test is
# resilient to future bugs.json edits — we only care that the verifier
# accepts SOME planted bug, then takes the ledger-write branch.
FIRST_BUG_ID="$(jq -r '.bugs[0].id' "$BUGS_MANIFEST")"
FIRST_BUG_LINE="$(jq -r '.bugs[0].line' "$BUGS_MANIFEST")"
FIRST_BUG_CLASS="$(jq -r '.bugs[0].class' "$BUGS_MANIFEST")"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

fail_with() {
    echo "[FAIL] $1" >&2
    FAIL=$((FAIL + 1))
}

pass_with() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

# Case 1: verified=true + ledger env → row appended with FULL reward.
case1() {
    local ledger="$TMPDIR_TEST/ledger-case1.jsonl"
    : >"$ledger"
    local input
    input="$(printf '{"line": %s, "class": "%s"}' "$FIRST_BUG_LINE" "$FIRST_BUG_CLASS")"
    local out
    out="$(printf '%s' "$input" | \
        TARGET_DIR="$TARGET_DIR" \
        BUGS_MANIFEST="$BUGS_MANIFEST" \
        BUG_LEDGER_PATH="$ledger" \
        TRIBE_NAME="alpha" \
        LEDGER_REWARD_FULL="200" \
        LEDGER_REWARD_SUBSEQUENT="50" \
        bash "$VERIFIER")"
    local got_verified
    got_verified="$(printf '%s' "$out" | jq -r '.verified')"
    if [ "$got_verified" != "true" ]; then
        fail_with "case1: expected verified=true, got $got_verified (out=$out)"
        return
    fi
    if [ ! -s "$ledger" ]; then
        fail_with "case1: ledger file empty after verified=true"
        return
    fi
    local row_count
    row_count="$(wc -l <"$ledger" | tr -d ' ')"
    if [ "$row_count" != "1" ]; then
        fail_with "case1: expected 1 ledger row, got $row_count"
        return
    fi
    local row
    row="$(cat "$ledger")"
    # Well-formed JSON
    if ! printf '%s' "$row" | jq -e '.' >/dev/null 2>&1; then
        fail_with "case1: ledger row is not well-formed JSON: $row"
        return
    fi
    local got_tribe got_bug got_reward
    got_tribe="$(printf '%s' "$row" | jq -r '.tribe')"
    got_bug="$(printf '%s' "$row" | jq -r '.bug_id')"
    got_reward="$(printf '%s' "$row" | jq -r '.reward')"
    if [ "$got_tribe" != "alpha" ] || [ "$got_bug" != "$FIRST_BUG_ID" ] || [ "$got_reward" != "200" ]; then
        fail_with "case1: row fields mismatch (tribe=$got_tribe bug=$got_bug reward=$got_reward)"
        return
    fi
    pass_with "case1: verified=true appends row with FULL reward"
}

# Case 2: verified=false → no append.
case2() {
    local ledger="$TMPDIR_TEST/ledger-case2.jsonl"
    : >"$ledger"
    # Pick a line guaranteed to miss every planted bug window.
    local out
    out="$(printf '{"line": 999999}' | \
        TARGET_DIR="$TARGET_DIR" \
        BUGS_MANIFEST="$BUGS_MANIFEST" \
        BUG_LEDGER_PATH="$ledger" \
        TRIBE_NAME="beta" \
        bash "$VERIFIER")"
    local got_verified
    got_verified="$(printf '%s' "$out" | jq -r '.verified')"
    if [ "$got_verified" != "false" ]; then
        fail_with "case2: expected verified=false, got $got_verified"
        return
    fi
    if [ -s "$ledger" ]; then
        fail_with "case2: ledger should be empty on verified=false, got $(cat "$ledger")"
        return
    fi
    pass_with "case2: verified=false leaves ledger untouched"
}

# Case 3: BUG_LEDGER_PATH unset → no write attempt, verdict still emitted.
case3() {
    local input
    input="$(printf '{"line": %s, "class": "%s"}' "$FIRST_BUG_LINE" "$FIRST_BUG_CLASS")"
    local out
    out="$(printf '%s' "$input" | \
        TARGET_DIR="$TARGET_DIR" \
        BUGS_MANIFEST="$BUGS_MANIFEST" \
        bash "$VERIFIER")"
    local got_verified
    got_verified="$(printf '%s' "$out" | jq -r '.verified')"
    if [ "$got_verified" != "true" ]; then
        fail_with "case3: expected verified=true with no ledger env, got $got_verified"
        return
    fi
    pass_with "case3: missing BUG_LEDGER_PATH is a graceful no-op"
}

# Case 4: same bug_id, two tribes → FULL then SUBSEQUENT.
case4() {
    local ledger="$TMPDIR_TEST/ledger-case4.jsonl"
    : >"$ledger"
    local input
    input="$(printf '{"line": %s, "class": "%s"}' "$FIRST_BUG_LINE" "$FIRST_BUG_CLASS")"

    # First tribe — should get FULL.
    printf '%s' "$input" | \
        TARGET_DIR="$TARGET_DIR" \
        BUGS_MANIFEST="$BUGS_MANIFEST" \
        BUG_LEDGER_PATH="$ledger" \
        TRIBE_NAME="alpha" \
        LEDGER_REWARD_FULL="200" \
        LEDGER_REWARD_SUBSEQUENT="50" \
        bash "$VERIFIER" >/dev/null

    # Second tribe (different name) — should get SUBSEQUENT.
    printf '%s' "$input" | \
        TARGET_DIR="$TARGET_DIR" \
        BUGS_MANIFEST="$BUGS_MANIFEST" \
        BUG_LEDGER_PATH="$ledger" \
        TRIBE_NAME="beta" \
        LEDGER_REWARD_FULL="200" \
        LEDGER_REWARD_SUBSEQUENT="50" \
        bash "$VERIFIER" >/dev/null

    local row_count
    row_count="$(wc -l <"$ledger" | tr -d ' ')"
    if [ "$row_count" != "2" ]; then
        fail_with "case4: expected 2 ledger rows, got $row_count"
        return
    fi
    local r1 r2
    r1="$(sed -n '1p' "$ledger")"
    r2="$(sed -n '2p' "$ledger")"
    local t1 reward1 t2 reward2
    t1="$(printf '%s' "$r1" | jq -r '.tribe')"
    reward1="$(printf '%s' "$r1" | jq -r '.reward')"
    t2="$(printf '%s' "$r2" | jq -r '.tribe')"
    reward2="$(printf '%s' "$r2" | jq -r '.reward')"
    if [ "$t1" != "alpha" ] || [ "$reward1" != "200" ]; then
        fail_with "case4: first row expected alpha/200, got $t1/$reward1"
        return
    fi
    if [ "$t2" != "beta" ] || [ "$reward2" != "50" ]; then
        fail_with "case4: second row expected beta/50, got $t2/$reward2"
        return
    fi
    pass_with "case4: cross-tribe first-finder vs subsequent reward split"
}

case1
case2
case3
case4

# Cases 5-9: #531 class-alias map. Tests the new
# STAGE3_VERIFIER_CLASS_ALIASES env var. Verifies that semantically-
# equivalent class labels match (heap_overflow ↔ memory_corruption,
# use_after_free ↔ dangling_borrow, data_race ↔ missing_lock) and
# that unambiguous singleton classes (uninitialised_memory,
# send_violation) stay strict.

# Helper: invoke verifier with a finding at the given line + class
# and return verified ("true" | "false").
verifier_verdict() {
    local line="$1"
    local class="$2"
    local alias_mode="${3:-1}"
    local out
    out="$(printf '{"line": %s, "class": "%s"}' "$line" "$class" | \
        TARGET_DIR="$TARGET_DIR" \
        BUGS_MANIFEST="$BUGS_MANIFEST" \
        STAGE3_VERIFIER_CLASS_ALIASES="$alias_mode" \
        bash "$VERIFIER" 2>/dev/null)"
    printf '%s' "$out" | jq -r '.verified'
}

# Resolve a bug from the manifest by class predicate for fixture stability.
bug_line_for_class() {
    local cls="$1"
    jq -r --arg c "$cls" 'first(.bugs[] | select(.class == $c)) | .line // "MISSING"' "$BUGS_MANIFEST"
}

case5_strict_mode_rejects_alias() {
    # bug.class=heap_overflow + finding.class=memory_corruption.
    # Strict mode (alias=0) must reject; the line is correct but the
    # class doesn't strict-match.
    local ho_line
    ho_line="$(bug_line_for_class "heap_overflow")"
    if [ "$ho_line" = "MISSING" ]; then
        pass_with "case5: SKIPPED (no heap_overflow bug in manifest)"
        return
    fi
    local v
    v="$(verifier_verdict "$ho_line" "memory_corruption" "0")"
    if [ "$v" = "false" ]; then
        pass_with "case5: strict mode rejects heap_overflow ↔ memory_corruption alias"
    else
        fail_with "case5: strict mode incorrectly accepted alias (got verified=$v)"
    fi
}

case6_alias_mode_accepts_heap_memcorr() {
    # bug.class=heap_overflow + finding.class=memory_corruption.
    # Alias mode (default) must accept.
    local ho_line
    ho_line="$(bug_line_for_class "heap_overflow")"
    if [ "$ho_line" = "MISSING" ]; then
        pass_with "case6: SKIPPED (no heap_overflow bug in manifest)"
        return
    fi
    local v
    v="$(verifier_verdict "$ho_line" "memory_corruption" "1")"
    if [ "$v" = "true" ]; then
        pass_with "case6: alias mode accepts heap_overflow ↔ memory_corruption"
    else
        fail_with "case6: alias mode rejected heap_overflow ↔ memory_corruption (got verified=$v)"
    fi
}

case7_alias_mode_accepts_uaf_dangling() {
    # bug.class=use_after_free + finding.class=dangling_borrow.
    local uaf_line
    uaf_line="$(bug_line_for_class "use_after_free")"
    if [ "$uaf_line" = "MISSING" ]; then
        pass_with "case7: SKIPPED (no use_after_free bug in manifest)"
        return
    fi
    local v
    v="$(verifier_verdict "$uaf_line" "dangling_borrow" "1")"
    if [ "$v" = "true" ]; then
        pass_with "case7: alias mode accepts use_after_free ↔ dangling_borrow"
    else
        fail_with "case7: alias mode rejected use_after_free ↔ dangling_borrow (got verified=$v)"
    fi
}

case8_alias_mode_rejects_um_to_memcorr() {
    # bug.class=uninitialised_memory + finding.class=memory_corruption.
    # uninitialised_memory is a singleton (no alias group); even in
    # alias mode it MUST stay strict.
    local um_line
    um_line="$(bug_line_for_class "uninitialised_memory")"
    if [ "$um_line" = "MISSING" ]; then
        pass_with "case8: SKIPPED (no uninitialised_memory bug in manifest)"
        return
    fi
    local v
    v="$(verifier_verdict "$um_line" "memory_corruption" "1")"
    if [ "$v" = "false" ]; then
        pass_with "case8: alias mode keeps uninitialised_memory strict (no cross-class accept)"
    else
        fail_with "case8: alias mode incorrectly aliased UM → memory_corruption (got verified=$v)"
    fi
}

case9_exact_class_still_works() {
    # Regression: exact-class match must always verify, alias mode or not.
    local v
    v="$(verifier_verdict "$FIRST_BUG_LINE" "$FIRST_BUG_CLASS" "1")"
    if [ "$v" = "true" ]; then
        pass_with "case9: exact-class match still verifies in alias mode"
    else
        fail_with "case9: exact-class match broken in alias mode (got verified=$v)"
    fi
}

case5_strict_mode_rejects_alias
case6_alias_mode_accepts_heap_memcorr
case7_alias_mode_accepts_uaf_dangling
case8_alias_mode_rejects_um_to_memcorr
case9_exact_class_still_works

echo ""
echo "Summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
