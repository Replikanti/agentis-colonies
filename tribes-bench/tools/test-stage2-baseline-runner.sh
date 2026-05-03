#!/bin/bash
# test-stage2-baseline-runner.sh — pure-offline + opportunistic-live
# assertions for Stage 2 M3 (#394) baseline harness.
#
# Mirrors the shape of test-stage2-cognitive-market.sh and
# test-stage2-reputation.sh: PASS/FAIL/SKIP helpers, exit 0 on green.
# Implements the 7 cases from §5 Test A of the plan.
#
# Cases:
#   1. tools/run-baseline.sh exists, executable, bash -n clean.
#   2. tools/run-baseline.sh prints "[run-baseline] total CB: <n>" with
#      n == 5 * initial_cb (calibration default 8000 → 40000 post-#404).
#   3. templates/tribe-baseline/colony.toml.template + agents/
#      hunter-baseline.ag.template exist with the documented placeholders.
#   4. hunter-baseline.ag.template has the three M3 deltas vs alpha:
#      `learn(..., ["baseline-no-replicate"])`, `learn(..., ["baseline-no-market"])`,
#      no `replicate(`, no `knowledge_buy(`, no `knowledge_sell(`.
#   5. Live smoke: skip when `agentis` not on PATH OR
#      ANTHROPIC_API_KEY/CLAUDE_API_KEY/equivalent unset; otherwise run
#      with STAGE2_BASELINE_WALL_CLOCK_S=15 and assert exit 0 + a
#      runs/baseline-* dir lands with telemetry.csv.
#   6. run-baseline-render.py byte-substitutes correctly (positive case).
#   7. run-baseline-meta.py emits valid JSON with the required keys.

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

assert_not_contains() {
    label="$1"; file="$2"; needle="$3"
    if [ ! -f "$file" ]; then
        echo "[FAIL] $label (file missing: $file)"
        FAIL=$((FAIL + 1))
        return
    fi
    if grep -Fq -- "$needle" "$file"; then
        echo "[FAIL] $label"
        echo "       file:   $file"
        echo "       found:  $needle"
        FAIL=$((FAIL + 1))
    else
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    fi
}

skip_case() {
    echo "[SKIP] $1 ($2)"
    SKIP=$((SKIP + 1))
}

# --- 1. run-baseline.sh exists, executable, bash -n clean ---
RB="$FED_DIR/tools/run-baseline.sh"
if [ -f "$RB" ]; then
    if [ -x "$RB" ]; then
        echo "[PASS] tools/run-baseline.sh exists and is executable"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] tools/run-baseline.sh exists but is NOT executable"
        FAIL=$((FAIL + 1))
    fi
    if bash -n "$RB" 2>/dev/null; then
        echo "[PASS] tools/run-baseline.sh: bash -n exit 0"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] tools/run-baseline.sh: bash -n exit non-zero"
        FAIL=$((FAIL + 1))
    fi
else
    echo "[FAIL] tools/run-baseline.sh missing"
    FAIL=$((FAIL + 1))
fi

# --- 2. Total CB: 5 * initial_cb (calibration default 8000 -> 40000) ---
# Read the source for the BASELINE_CB arithmetic — we don't need to run
# the script; we just verify the formula. Then verify the calibration
# default is 8000 (#404) so the inferred total matches expectation.
if [ -f "$RB" ]; then
    if grep -Fq 'BASELINE_CB="$((INITIAL_CB * 5))"' "$RB"; then
        echo "[PASS] run-baseline.sh: BASELINE_CB = 5 * initial_cb"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] run-baseline.sh: BASELINE_CB formula not 5 * initial_cb"
        FAIL=$((FAIL + 1))
    fi
    if grep -Fq '[run-baseline] total CB:' "$RB"; then
        echo "[PASS] run-baseline.sh prints '[run-baseline] total CB:'"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] run-baseline.sh missing 'total CB' echo"
        FAIL=$((FAIL + 1))
    fi
fi

INITIAL_CB_TOML="$(python3 "$FED_DIR/tools/run-stage1-calibration.py" "$FED_DIR/calibration.toml" tribe.economy initial_cb 8000)"
EXPECTED_CB=$((INITIAL_CB_TOML * 5))
assert_eq "calibration.toml initial_cb * 5 = expected baseline CB" "40000" "$EXPECTED_CB"

# --- 3. Templates exist with documented placeholders ---
TMPL_TOML="$FED_DIR/templates/tribe-baseline/colony.toml.template"
TMPL_AG="$FED_DIR/templates/tribe-baseline/agents/hunter-baseline.ag.template"
for f in "$TMPL_TOML" "$TMPL_AG"; do
    if [ -f "$f" ]; then
        echo "[PASS] template exists: $(basename "$f")"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] template missing: $f"
        FAIL=$((FAIL + 1))
    fi
done

assert_contains "colony.toml.template has {{CB_BUDGET}} placeholder" "$TMPL_TOML" "{{CB_BUDGET}}"
assert_contains "colony.toml.template has {{LLM_BACKEND}} placeholder" "$TMPL_TOML" "{{LLM_BACKEND}}"
assert_contains "hunter-baseline.ag.template has {{CB_BUDGET}} placeholder" "$TMPL_AG" "{{CB_BUDGET}}"

# --- 4. Three M3 deltas vs alpha hunter ---
assert_contains "hunter-baseline.ag has baseline-no-replicate tag" "$TMPL_AG" "baseline-no-replicate"
assert_contains "hunter-baseline.ag has baseline-no-market tag" "$TMPL_AG" "baseline-no-market"
assert_not_contains "hunter-baseline.ag does NOT call replicate(" "$TMPL_AG" "replicate("
assert_not_contains "hunter-baseline.ag does NOT call knowledge_buy(" "$TMPL_AG" "knowledge_buy("
assert_not_contains "hunter-baseline.ag does NOT call knowledge_sell(" "$TMPL_AG" "knowledge_sell("

# --- 5. Live smoke run (opportunistic) ---
HAS_KEY=0
if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${CLAUDE_API_KEY:-}" ] || [ -n "${OPENAI_API_KEY:-}" ]; then
    HAS_KEY=1
fi
if ! command -v agentis >/dev/null 2>&1; then
    skip_case "live smoke run" "agentis not on PATH"
elif [ "$HAS_KEY" = "0" ]; then
    skip_case "live smoke run" "no LLM API key in env"
else
    SMOKE_OUT="$TMP/smoke.log"
    if STAGE2_BASELINE_WALL_CLOCK_S=15 STAGE2_BASELINE_SNAPSHOT_S=10 \
        bash "$RB" >"$SMOKE_OUT" 2>&1; then
        last_run="$(ls -td "$FED_DIR"/runs/baseline-* 2>/dev/null | head -1 || true)"
        if [ -n "$last_run" ] && [ -f "$last_run/telemetry.csv" ]; then
            echo "[PASS] live smoke: telemetry.csv produced at $last_run"
            PASS=$((PASS + 1))
        else
            echo "[FAIL] live smoke: telemetry.csv NOT produced"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "[FAIL] live smoke: run-baseline.sh exited non-zero (see $SMOKE_OUT)"
        FAIL=$((FAIL + 1))
    fi
fi

# --- 6. run-baseline-render.py byte substitution ---
RENDER="$FED_DIR/tools/run-baseline-render.py"
if [ -f "$RENDER" ]; then
    SRC="$TMP/in.txt"; DST="$TMP/out.txt"
    printf 'cb {{CB}}; backend={{B}}; tag={{CB}}\n' > "$SRC"
    if python3 "$RENDER" "$SRC" "$DST" "CB=42" "B=claude" 2>/dev/null; then
        if [ -f "$DST" ]; then
            content="$(cat "$DST")"
            expected="cb 42; backend=claude; tag=42"
            assert_eq "render byte substitution" "$expected" "$content"
        else
            echo "[FAIL] render: no output file"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "[FAIL] render: exit non-zero"
        FAIL=$((FAIL + 1))
    fi
else
    echo "[FAIL] tools/run-baseline-render.py missing"
    FAIL=$((FAIL + 1))
fi

# --- 7. run-baseline-meta.py emits valid JSON with required keys ---
META="$FED_DIR/tools/run-baseline-meta.py"
if [ -f "$META" ]; then
    OUT="$TMP/meta.json"
    if python3 "$META" "$OUT" "2026-01-01T00:00:00Z" "3600" "600" "claude" "5000" "baseline" 2>/dev/null; then
        keys="$(python3 -c "import json; d=json.load(open('$OUT')); print(','.join(sorted(d.keys())))")"
        expected="baseline_cb,kind,llm_backend,snapshot_s,started_at,wall_clock_s"
        assert_eq "run-meta.json has the 6 required keys" "$expected" "$keys"
    else
        echo "[FAIL] run-baseline-meta.py: exit non-zero"
        FAIL=$((FAIL + 1))
    fi
else
    echo "[FAIL] tools/run-baseline-meta.py missing"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
