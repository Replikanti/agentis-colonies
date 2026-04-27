#!/bin/bash
# test-verify-finding.sh: unit tests for the Stage 0 deterministic verifier.
#
# Feeds three known-good and three known-bad finding fixtures into
# verify-finding.sh and asserts the expected verdicts. Exit 0 on pass.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

VERIFIER="$SCRIPT_DIR/verify-finding.sh"
TARGET_DIR="$FED_DIR/targets/stage0"

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
    out="$(printf '%s' "$input" | TARGET_DIR="$TARGET_DIR" BUGS_MANIFEST="$TARGET_DIR/bugs.json" bash "$VERIFIER")"

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
