#!/bin/bash
# test-verify-finding.sh: unit tests for the deterministic verifier.
#
# Default mode: feeds three known-good and three known-bad Stage 0
# finding fixtures into verify-finding.sh and asserts the expected
# verdicts. Exit 0 on pass.
#
# `STAGE1=1` mode: switches BUGS_MANIFEST + TARGET_DIR to targets/stage1
# and runs six additional fixtures (one good per class + three bad
# fixtures exercising class dispatch, line-window, and malformed input).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

VERIFIER="$SCRIPT_DIR/verify-finding.sh"

STAGE_MODE="${STAGE1:-0}"
if [ "$STAGE_MODE" = "1" ]; then
    TARGET_DIR="$FED_DIR/targets/stage1"
else
    TARGET_DIR="$FED_DIR/targets/stage0"
fi

if [ ! -x "$VERIFIER" ]; then
    echo "Error: verify-finding.sh not found or not executable at $VERIFIER" >&2
    exit 1
fi

if [ ! -f "$TARGET_DIR/bugs.json" ]; then
    echo "Error: bugs.json not found at $TARGET_DIR/bugs.json" >&2
    exit 1
fi

PASS=0
FAIL=0

run_case() {
    # $1: label
    # $2: expected verified ("true"|"false")
    # $3: expected bug_id (empty for null)
    # $4: stdin JSON
    local label="$1"
    local exp_verified="$2"
    local exp_bug_id="$3"
    local input="$4"

    local out
    # Hoisted out of the env-assignment prefix: referencing $TARGET_DIR in a
    # later word of the same command reads the OUTER value, which is what is
    # meant here, but shellcheck flags the ambiguity (SC2097/SC2098).
    local bugs_manifest="$TARGET_DIR/bugs.json"
    out="$(printf '%s' "$input" | TARGET_DIR="$TARGET_DIR" BUGS_MANIFEST="$bugs_manifest" bash "$VERIFIER")"

    local got_verified
    got_verified="$(printf '%s' "$out" | jq -r '.verified')"
    local got_bug_id
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

if [ "$STAGE_MODE" = "1" ]; then
    # --- Stage 1 mode (STAGE1=1): six fixtures across 3 classes ---

    run_case "good: S1-CMDINJ-001 with class" "true" "S1-CMDINJ-001" \
        '{"line": 12, "class": "command_injection"}'

    run_case "good: S1-PATHTRV-002 with class" "true" "S1-PATHTRV-002" \
        '{"line": 20, "class": "path_traversal"}'

    run_case "good: S1-FMTSTR-002 with class" "true" "S1-FMTSTR-002" \
        '{"line": 24, "class": "format_string"}'

    # Class-dispatch: line 12 declared as format_string. cmd_inj bugs at
    # lines 12,21,28,35 are filtered out by the class predicate; no
    # format_string bug is within tolerance of line 12 (fmtstr bugs at
    # lines 16,24,36 → ranges 14-18, 22-26, 34-38), so verdict = false.
    run_case "bad: cmd_inj line claimed as format_string" "false" "" \
        '{"line": 12, "class": "format_string"}'

    run_case "bad: line outside any planted bug window" "false" "" \
        '{"line": 99, "class": "command_injection"}'

    run_case "bad: malformed (missing line)" "false" "" \
        '{"class": "command_injection"}'

    echo ""
    echo "Results (Stage 1): $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
    exit
fi

# --- Three known-good fixtures (one per planted bug, exact line) ---

run_case "good: ci-001 exact line" "true" "ci-001" \
    '{"line": 12, "rationale": "user_arg interpolated into sh -c via format!"}'

run_case "good: ci-002 within tolerance" "true" "ci-002" \
    '{"line": 22, "rationale": "Command::new path built from caller-supplied subcmd"}'

run_case "good: ci-003 exact line" "true" "ci-003" \
    '{"line": 29, "rationale": "path interpolated into bash -c pipeline string"}'

# --- Three known-bad fixtures ---

# (a) line outside tolerance window for every planted bug.
run_case "bad: line far from any planted bug" "false" "" \
    '{"line": 41, "rationale": "false alarm in main()"}'

# (b) inside tolerance window but pointing at a line whose source slice
#     does not contain any planted signature (the function declarations
#     above the bug bodies).
run_case "bad: inside window but signature absent at planted line" "false" "" \
    '{"line": 8, "rationale": "claim near list_dir signature"}'

# (c) malformed input: no line field.
run_case "bad: malformed input (missing line)" "false" "" \
    '{"rationale": "no line"}'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
