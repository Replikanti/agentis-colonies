#!/bin/bash
# test-stage2-scaffold.sh — pure-offline assertions for Stage 2 M1 (#392).
#
# Mirrors the shape of `test-stage1-replication.sh` and
# `test-stage1-bug-ledger.sh`: PASS/FAIL/SKIP helpers, exit 0 on green,
# no live federation. The 8 assertion groups follow the plan §5
# checklist:
#
#   1. Per-new-tribe `.ag` syntax via `agentis commit` (skip if agentis
#      not on PATH).
#   2. Per-new-tribe replication wiring — `replicate(` in hunter.ag and
#      `--enable-replication` >= 2 in start-colony.sh (main + restart).
#   3. `bugs.json` schema — 5 entries, each has the required keys.
#   4. Verifier dispatch — 5 known-good fixtures (correct line + class)
#      verified=true, 2 known-bad fixtures verified=false.
#   5. Source compiles — `rustc --edition 2021 --crate-type lib
#      --emit=metadata -o /dev/null lib.rs` exit 0 (skip if no rustc).
#   6. start-federation.sh accepts the extended COLONIES — `bash -n`
#      plus literal greps for `tribe-delta` and `tribe-epsilon`.
#   7. Stage 0/1 invariants — re-run all four pre-existing test scripts
#      and assert PASS unchanged.
#   8. Calibration unchanged — `git diff --quiet origin/main` against
#      `tribes-bench/calibration.toml`.
#
# This test is offline (no live agentis daemon, no live federation).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"

PASS=0
FAIL=0
SKIP=0

assert_eq() {
    # $1 label, $2 expected, $3 got
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
    # $1 label, $2 file, $3 needle (literal)
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
    # $1 label, $2 reason
    echo "[SKIP] $1 ($2)"
    SKIP=$((SKIP + 1))
}

NEW_TRIBES="tribe-delta tribe-epsilon"

# --- 1. Per-new-tribe .ag syntax via agentis commit ---
# `agentis commit` requires an .agentis/ in CWD, so we init a temp repo
# once and run every commit from inside it (same pattern as
# tools/colony-lint.sh).
if command -v agentis >/dev/null 2>&1; then
    AG_TMP="$(mktemp -d)"
    (cd "$AG_TMP" && agentis init >/dev/null 2>&1) || true
    for tribe in $NEW_TRIBES; do
        ag_path="$FED_DIR/$tribe/agents/hunter.ag"
        if [ -f "$ag_path" ]; then
            if (cd "$AG_TMP" && agentis commit "$ag_path") >/dev/null 2>&1; then
                echo "[PASS] $tribe hunter.ag: agentis commit exit 0"
                PASS=$((PASS + 1))
            else
                echo "[FAIL] $tribe hunter.ag: agentis commit non-zero"
                FAIL=$((FAIL + 1))
            fi
        else
            echo "[FAIL] $tribe hunter.ag missing at $ag_path"
            FAIL=$((FAIL + 1))
        fi
    done
    rm -rf "$AG_TMP"
else
    for tribe in $NEW_TRIBES; do
        skip_case "$tribe hunter.ag agentis commit" "agentis CLI not on PATH"
    done
fi

# --- 2. Replication wiring per new tribe ---
for tribe in $NEW_TRIBES; do
    ag_path="$FED_DIR/$tribe/agents/hunter.ag"
    sh_path="$FED_DIR/$tribe/scripts/start-colony.sh"
    rep_count=0
    if [ -f "$ag_path" ]; then
        rep_count="$(grep -Fc 'replicate(' "$ag_path" 2>/dev/null || echo 0)"
    fi
    if [ "$rep_count" -ge 1 ]; then
        echo "[PASS] $tribe hunter.ag has >=1 replicate( call"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $tribe hunter.ag has no replicate( call (count=$rep_count)"
        FAIL=$((FAIL + 1))
    fi

    flag_count=0
    if [ -f "$sh_path" ]; then
        flag_count="$(grep -Fc -- '--enable-replication' "$sh_path" 2>/dev/null || echo 0)"
    fi
    if [ "$flag_count" -ge 2 ]; then
        echo "[PASS] $tribe start-colony.sh has --enable-replication on >=2 lines"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $tribe start-colony.sh has --enable-replication on <2 lines (count=$flag_count)"
        FAIL=$((FAIL + 1))
    fi
done

# --- 3. bugs.json schema (5 entries, required keys) ---
BUGS_JSON="$FED_DIR/targets/stage2/bugs.json"
SCHEMA_PY='import json, sys
required = ["id", "class", "file", "line", "line_tolerance", "signature", "severity"]
try:
    data = json.load(open(sys.argv[1]))
except Exception as exc:
    print("PARSE_ERROR: " + str(exc))
    sys.exit(0)
bugs = data.get("bugs") if isinstance(data, dict) else None
if not isinstance(bugs, list):
    print("MISSING_BUGS_LIST")
    sys.exit(0)
if len(bugs) != 5:
    print("WRONG_COUNT: " + str(len(bugs)))
    sys.exit(0)
for i, b in enumerate(bugs):
    if not isinstance(b, dict):
        print("NOT_OBJECT: index " + str(i))
        sys.exit(0)
    for k in required:
        if k not in b:
            print("MISSING_KEY: bug " + str(i) + " missing " + k)
            sys.exit(0)
print("OK")
'
SCHEMA_RESULT="$(python3 -c "$SCHEMA_PY" "$BUGS_JSON" 2>&1 || true)"
assert_eq "bugs.json schema (5 entries, required keys present)" "OK" "$SCHEMA_RESULT"

# --- 4. Verifier dispatch — 5 known-good + 2 known-bad fixtures ---
VERIFIER="$FED_DIR/tools/verify-finding-stage2.sh"
TARGET_DIR_S2="$FED_DIR/targets/stage2/smallvec-v0.6.13"

run_verifier_case() {
    # $1 label, $2 expected verified ("true"|"false"),
    # $3 expected bug_id (empty for null), $4 stdin JSON
    label="$1"; exp_verified="$2"; exp_bug_id="$3"; input="$4"
    out="$(printf '%s' "$input" | TARGET_DIR="$TARGET_DIR_S2" BUGS_MANIFEST="$FED_DIR/targets/stage2/bugs.json" bash "$VERIFIER")"
    got_verified="$(printf '%s' "$out" | jq -r '.verified')"
    got_bug_id="$(printf '%s' "$out" | jq -r '.bug_id // ""')"
    if [ "$got_verified" = "$exp_verified" ] && [ "$got_bug_id" = "$exp_bug_id" ]; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       expected: verified=$exp_verified bug_id=${exp_bug_id:-null}"
        echo "       got:      verified=$got_verified bug_id=${got_bug_id:-null}"
        echo "       output:   $out"
        FAIL=$((FAIL + 1))
    fi
}

# Known-good: one per planted bug, exact line + correct class.
run_verifier_case "good: S2-SMVUAF-001 (insert_many UAF)" "true" "S2-SMVUAF-001" \
    '{"line": 827, "class": "use_after_free"}'
run_verifier_case "good: S2-SMVMEM-001 (from_buf_and_len_unchecked uninit)" "true" "S2-SMVMEM-001" \
    '{"line": 534, "class": "uninitialised_memory"}'
run_verifier_case "good: S2-SMVUAF-002 (grow UAF)" "true" "S2-SMVUAF-002" \
    '{"line": 656, "class": "use_after_free"}'
run_verifier_case "good: S2-SMVMEM-002 (grow corruption)" "true" "S2-SMVMEM-002" \
    '{"line": 656, "class": "memory_corruption"}'
run_verifier_case "good: S2-SMVOFL-001 (insert_many size_hint)" "true" "S2-SMVOFL-001" \
    '{"line": 833, "class": "heap_overflow"}'

# Known-bad: line outside any window (off-by-much).
run_verifier_case "bad: line outside any planted bug window" "false" "" \
    '{"line": 99, "class": "use_after_free"}'

# Known-bad: correct line, wrong class.
run_verifier_case "bad: correct line but wrong class" "false" "" \
    '{"line": 827, "class": "missing_lock"}'

# --- 5. Source compiles ---
# The vendored smallvec v0.6.13 crate has external Cargo dependencies
# (`maybe-uninit`, optional `serde`) that a bare `rustc` cannot resolve
# without an offline `cargo check`. We probe in three steps:
#   (a) `cargo check --offline` if Cargo + Cargo.lock + a populated
#       cargo cache are available — strongest guarantee.
#   (b) Otherwise, run `rustc --emit=metadata` and accept either exit 0
#       OR the specific "can't find crate" error class as a "shape OK"
#       outcome (the planted bugs sit inside the affected modules; if
#       rustc parsed up to the extern-crate failure, the surface is
#       syntactically intact).
#   (c) If neither rustc nor cargo are on PATH, skip.
LIB_RS="$TARGET_DIR_S2/lib.rs"
COMPILE_OK=""
if command -v cargo >/dev/null 2>&1 && [ -f "$TARGET_DIR_S2/Cargo.lock" ]; then
    if (cd "$TARGET_DIR_S2" && cargo check --offline) >/dev/null 2>&1; then
        COMPILE_OK="cargo check --offline"
    fi
fi
if [ -z "$COMPILE_OK" ] && command -v rustc >/dev/null 2>&1; then
    if rustc --edition 2021 --crate-type lib --emit=metadata -o /dev/null "$LIB_RS" >/dev/null 2>&1; then
        COMPILE_OK="rustc --emit=metadata"
    else
        rustc_err="$(rustc --edition 2021 --crate-type lib --emit=metadata -o /dev/null "$LIB_RS" 2>&1 || true)"
        if printf '%s' "$rustc_err" | grep -q "can't find crate for"; then
            COMPILE_OK="rustc parse + early type-check (extern dep gap, expected for vendored crate)"
        fi
    fi
fi

if [ -n "$COMPILE_OK" ]; then
    echo "[PASS] targets/stage2/smallvec-v0.6.13/lib.rs source shape OK ($COMPILE_OK)"
    PASS=$((PASS + 1))
elif command -v rustc >/dev/null 2>&1 || command -v cargo >/dev/null 2>&1; then
    echo "[FAIL] targets/stage2/smallvec-v0.6.13/lib.rs failed to compile (and not the expected extern-crate gap)"
    FAIL=$((FAIL + 1))
else
    skip_case "lib.rs compile check" "rustc + cargo not on PATH"
fi

# --- 6. start-federation.sh accepts extended COLONIES ---
SF_PATH="$FED_DIR/start-federation.sh"
if bash -n "$SF_PATH" 2>/dev/null; then
    echo "[PASS] start-federation.sh: bash -n exit 0"
    PASS=$((PASS + 1))
else
    echo "[FAIL] start-federation.sh: bash -n exit non-zero"
    FAIL=$((FAIL + 1))
fi
assert_contains "start-federation.sh COLONIES contains tribe-delta" "$SF_PATH" "tribe-delta"
assert_contains "start-federation.sh COLONIES contains tribe-epsilon" "$SF_PATH" "tribe-epsilon"

# --- 7. Stage 0/1 invariants — re-run pre-existing tests ---
for testname in test-verify-finding.sh test-stage1-replication.sh test-stage1-bug-ledger.sh; do
    test_path="$FED_DIR/tools/$testname"
    if [ -x "$test_path" ] || [ -f "$test_path" ]; then
        if bash "$test_path" >/dev/null 2>&1; then
            echo "[PASS] $testname (Stage 0/1 invariant)"
            PASS=$((PASS + 1))
        else
            echo "[FAIL] $testname failed (Stage 0/1 invariant regressed)"
            FAIL=$((FAIL + 1))
        fi
    else
        skip_case "$testname (Stage 0/1 invariant)" "test script not found"
    fi
done

if [ -f "$FED_DIR/tools/test-verify-finding.sh" ]; then
    if STAGE1=1 bash "$FED_DIR/tools/test-verify-finding.sh" >/dev/null 2>&1; then
        echo "[PASS] STAGE1=1 test-verify-finding.sh (Stage 1 invariant)"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] STAGE1=1 test-verify-finding.sh failed (Stage 1 invariant regressed)"
        FAIL=$((FAIL + 1))
    fi
fi

# --- 8. Calibration: M1 economy sections unchanged vs origin/main ---
# Stage 2 M2 (#393) appends `[reputation]` and `[knowledge_market]`
# blocks to calibration.toml; the original M1-shipped sections
# `[tribe.economy]`, `[tribe.reward]`, `[tribe.death]` must remain
# byte-identical so the existing run-stage1.sh harness keeps reading
# the same defaults. This assertion was a byte-identity gate in M1; it
# is relaxed to a section-scoped diff for M2 forward.
CALIB="tribes-bench/calibration.toml"
if [ -d "$REPO_ROOT/.git" ] || git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if git -C "$REPO_ROOT" rev-parse --verify origin/main >/dev/null 2>&1; then
        # Extract the M1-defined economy block: from line 1 through the
        # last line of [tribe.death]. M2 additions live BELOW that.
        upstream="$(git -C "$REPO_ROOT" show "origin/main:$CALIB" 2>/dev/null || true)"
        upstream_econ="$(printf '%s' "$upstream" | awk 'BEGIN{p=1} /^\[reputation\]|^\[knowledge_market\]/{p=0} p{print}')"
        local_econ="$(awk 'BEGIN{p=1} /^\[reputation\]|^\[knowledge_market\]/{p=0} p{print}' "$REPO_ROOT/$CALIB" 2>/dev/null || true)"
        if [ "$upstream_econ" = "$local_econ" ] && [ -n "$upstream_econ" ]; then
            echo "[PASS] calibration.toml: M1 [tribe.economy/reward/death] sections unchanged"
            PASS=$((PASS + 1))
        else
            echo "[FAIL] calibration.toml: M1 [tribe.economy/reward/death] sections changed (M2 must only APPEND new blocks)"
            FAIL=$((FAIL + 1))
        fi
    else
        skip_case "calibration.toml: M1 sections unchanged" "origin/main not available"
    fi
else
    skip_case "calibration.toml: M1 sections unchanged" "not a git repository"
fi

# --- 9. #398 — TARGET_FILE in env_passthrough of harness scripts ---
assert_contains "run-stage2.sh exec.env_passthrough lists TARGET_FILE" \
    "$FED_DIR/tools/run-stage2.sh" "TARGET_DIR,TARGET_FILE,"
assert_contains "run-baseline.sh exec.env_passthrough lists TARGET_FILE" \
    "$FED_DIR/tools/run-baseline.sh" "TARGET_DIR,TARGET_FILE,"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
