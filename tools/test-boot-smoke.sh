#!/usr/bin/env bash
# tools/test-boot-smoke.sh -- boot-level smoke for research-foundry (#760).
#
# Why: wiring-level greps in research-foundry/tools/test-run-research.sh
# pass even when production is broken at boot. #758 was the canonical
# example -- `openssl genpkey -out <file>` wrote a 119-byte PEM PKCS8 key,
# every daemon's audit-signing init rejected it, watchdogs hit max
# restarts, no tick ever fired -- but the source-grep tests stayed green
# because the openssl literal was still present in run-research.sh.
#
# This test runs the actual research-foundry container with a tiny budget
# (2 ticks * 1 daemon * 18 colonies, ~45s wall) and asserts five things:
#
#   1. orchestrator exits 0
#   2. no <run>/laptop-node/.agentis/daemon/*.watchdog.log contains
#      `max restarts (5) reached`
#   3. no <run>/laptop-node/.agentis/daemon/*.watchdog.log contains
#      `Invalid signing key`
#   4. no <run>/laptop-node/.agentis/logs/*.log contains `parse error`
#      or `EvalError`
#   5. <run>/laptop-node/.agentis/experience/ holds at least one
#      <daemon-short>.jsonl file (proof that at least one daemon got past
#      boot and emitted an experience row)
#
# Opt-in -- not run by default by `tools/colony-lint.sh`. Operators MUST
# run `bash tools/colony-lint.sh --boot-smoke` (or invoke this script
# directly) before merging any PR that touches `research-foundry/tools/`
# or `research-foundry/*/agents/*.ag`.
#
# Skipped gracefully when podman or the research-foundry image are
# unavailable (CI runners without container support).
#
# Usage:  bash tools/test-boot-smoke.sh
# Exit:   0 = pass / skip,  1 = fail

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCH="$REPO_ROOT/research-foundry/tools/run-research.sh"
IMAGE_TAG="${RESEARCH_IMAGE_TAG:-localhost/research-foundry:latest}"

PASS=0
FAIL=0

assert_eq() {
    label="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       expected: $expected"
        echo "       actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_no_match() {
    label="$1"; glob="$2"; needle="$3"
    matched=""
    # Loop so an empty glob (no files) means PASS, not error.
    for f in $glob; do
        [ -f "$f" ] || continue
        if grep -Fq -- "$needle" "$f"; then
            matched="$f"
            break
        fi
    done
    if [ -z "$matched" ]; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       needle found in: $matched"
        echo "       needle:          $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_glob_nonempty() {
    label="$1"; glob="$2"
    count=0
    for f in $glob; do
        [ -f "$f" ] || continue
        count=$((count + 1))
    done
    if [ "$count" -gt 0 ]; then
        echo "[PASS] $label ($count file(s))"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       no files match glob: $glob"
        FAIL=$((FAIL + 1))
    fi
}

# --- Skip when prerequisites are absent -------------------------------------
if ! command -v podman >/dev/null 2>&1; then
    echo "[SKIP] test-boot-smoke: podman not on PATH (CI without container support)"
    exit 0
fi

if ! podman image exists "$IMAGE_TAG" 2>/dev/null; then
    echo "[SKIP] test-boot-smoke: image '$IMAGE_TAG' not built locally"
    echo "       build with: cd research-foundry && podman build -t $IMAGE_TAG -f tools/Containerfile.research ."
    exit 0
fi

if [ ! -x "$ORCH" ]; then
    echo "[FAIL] test-boot-smoke: run-research.sh not executable at $ORCH"
    exit 1
fi

# --- Run a real (tiny) container --------------------------------------------
WORK_DIR="$(mktemp -d)"
RUN_DIR="$WORK_DIR/run"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[INFO] test-boot-smoke: running 2-tick container in $RUN_DIR (~45s wall)"

ORCH_RC=0
RESEARCH_TOTAL_TICKS=2 \
RESEARCH_DAEMONS_PER_COLONY=1 \
RESEARCH_HOLD_PERIOD=1 \
RESEARCH_TICK_INTERVAL_S=10 \
RESEARCH_TOPICS=group_theory \
RESEARCH_AUTO_PROMOTE=0 \
RESEARCH_CULL_ENABLED=0 \
RESEARCH_RUN_LABEL=boot-smoke \
RESEARCH_RUN_DIR="$RUN_DIR" \
RESEARCH_IMAGE_TAG="$IMAGE_TAG" \
RESEARCH_PERSISTENT_DISABLED=1 \
    bash "$ORCH" >"$WORK_DIR/orch.stdout" 2>"$WORK_DIR/orch.stderr" || ORCH_RC=$?

# --- Assertions -------------------------------------------------------------
assert_eq "1. orchestrator exits 0" "0" "$ORCH_RC"

DAEMON_DIR="$RUN_DIR/laptop-node/.agentis/daemon"
LOG_DIR="$RUN_DIR/laptop-node/.agentis/logs"
EXP_DIR="$RUN_DIR/laptop-node/.agentis/experience"

# Quote-suppress to keep the literal glob string intact for assert_*; the
# helpers expand it themselves via the unquoted `for` loop.
# shellcheck disable=SC2086
assert_no_match "2. no watchdog log reports 'max restarts (5) reached'" \
    "$DAEMON_DIR/*.watchdog.log" \
    "max restarts (5) reached"

# shellcheck disable=SC2086
assert_no_match "3. no watchdog log reports 'Invalid signing key'" \
    "$DAEMON_DIR/*.watchdog.log" \
    "Invalid signing key"

# Two needles for assertion 4: parse error AND EvalError. Run twice so
# each surfaces its own [PASS]/[FAIL] line.
# shellcheck disable=SC2086
assert_no_match "4a. no daemon log contains 'parse error'" \
    "$LOG_DIR/*.log" \
    "parse error"

# shellcheck disable=SC2086
assert_no_match "4b. no daemon log contains 'EvalError'" \
    "$LOG_DIR/*.log" \
    "EvalError"

# shellcheck disable=SC2086
assert_glob_nonempty "5. .agentis/experience/<short>.jsonl exists for at least one daemon" \
    "$EXP_DIR/*.jsonl"

# --- Summary ----------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -ne 0 ]; then
    echo ""
    echo "Diagnostic output (orchestrator stderr tail):"
    tail -40 "$WORK_DIR/orch.stderr" 2>/dev/null || true
fi

[ "$FAIL" -eq 0 ]
