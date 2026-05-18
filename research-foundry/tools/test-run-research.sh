#!/usr/bin/env bash
# research-foundry/tools/test-run-research.sh -- smoke test for
# run-research.sh --dry-run mode (#638). Replaces the retired
# math-foundry/tools/test-run-foundry.sh.
#
# Assertions:
#
#   1. RESEARCH_DRY_RUN=1 exits 0
#   2. emit_step transcript names the configured topics
#   3. emit_step transcript names the configured paper corpus
#   4. emit_step transcript names the configured tick interval
#   5. emit_step transcript names the configured total ticks
#   6. emit_step transcript names the configured daemons per colony
#   7. emit_step transcript names the configured hold period
#   8. Invalid RESEARCH_TOTAL_TICKS=0 rejected with exit 2
#   9. Empty RESEARCH_TOPICS rejected with exit 2
#  10. Bootstrap-script generation step is emitted in dry-run output,
#      and names all 16 colonies.
#  11. Container spawn command is emitted in dry-run output using the
#      `research-foundry-laptop` name (single sidecar block).
#  12. Run-meta.json write step is emitted in dry-run output
#  13. Cleanup trap is installed in dry-run output (single trap line)
#  14. Auto-promote sidecar block emitted exactly once.
#  15. Header doc names every documented RESEARCH_* env var
#  16. Source-run / --source-* flags are gone (regression guard for
#      cross-fed recall removal).
#
# Standard library only -- no pytest, no requests, no live LLM, no
# podman.
#
# Usage: bash research-foundry/tools/test-run-research.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCH="$SCRIPT_DIR/run-research.sh"

PASS=0
FAIL=0

assert_contains() {
    label="$1"; haystack="$2"; needle="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       needle not found: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    label="$1"; haystack="$2"; needle="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        echo "[FAIL] $label"
        echo "       needle unexpectedly present: $needle"
        FAIL=$((FAIL + 1))
    else
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    fi
}

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

if [ ! -x "$ORCH" ]; then
    echo "[FAIL] run-research.sh not executable at $ORCH"
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---------------------------------------------------------------------------
# 1-7. Dry-run with explicit knobs surfaces every config line.
# ---------------------------------------------------------------------------
DRY_RC=0
OUT="$(RESEARCH_DRY_RUN=1 \
       RESEARCH_TOPICS=number_theory,combinatorics \
       RESEARCH_PAPER_CORPUS=/tmp/research-corpus \
       RESEARCH_TICK_INTERVAL_S=30 \
       RESEARCH_TOTAL_TICKS=12 \
       RESEARCH_DAEMONS_PER_COLONY=2 \
       RESEARCH_HOLD_PERIOD=5 \
       RESEARCH_RUN_DIR="$WORK_DIR/run-default" \
       bash "$ORCH" 2>&1)" || DRY_RC=$?

assert_eq "1. RESEARCH_DRY_RUN=1 exits 0" "0" "$DRY_RC"
assert_contains "2. emit_step names topics" "$OUT" "topics: number_theory,combinatorics"
assert_contains "3. emit_step names paper corpus" "$OUT" "paper corpus: /tmp/research-corpus"
assert_contains "4. emit_step names tick interval" "$OUT" "tick interval: 30s"
assert_contains "5. emit_step names total ticks" "$OUT" "total ticks: 12"
assert_contains "6. emit_step names daemons per colony" "$OUT" "daemons per colony: 2"
assert_contains "7. emit_step names hold period" "$OUT" "hold period: 5"

# ---------------------------------------------------------------------------
# 8. Invalid total ticks rejected.
# ---------------------------------------------------------------------------
INVALID_RC=0
INVALID_OUT="$(RESEARCH_DRY_RUN=1 RESEARCH_TOTAL_TICKS=0 \
               bash "$ORCH" 2>&1 || true)"
RESEARCH_DRY_RUN=1 RESEARCH_TOTAL_TICKS=0 bash "$ORCH" >/dev/null 2>&1 || INVALID_RC=$?
assert_eq "8a. RESEARCH_TOTAL_TICKS=0 exits 2" "2" "$INVALID_RC"
assert_contains "8b. zero-ticks stderr names the variable" "$INVALID_OUT" \
    "RESEARCH_TOTAL_TICKS must be >= 1"

# ---------------------------------------------------------------------------
# 9. Empty RESEARCH_TOPICS rejected.
# ---------------------------------------------------------------------------
EMPTY_RC=0
EMPTY_OUT="$(RESEARCH_DRY_RUN=1 RESEARCH_TOPICS= \
             bash "$ORCH" 2>&1 || true)"
RESEARCH_DRY_RUN=1 RESEARCH_TOPICS= bash "$ORCH" >/dev/null 2>&1 || EMPTY_RC=$?
assert_eq "9a. empty RESEARCH_TOPICS exits 2" "2" "$EMPTY_RC"
assert_contains "9b. empty-topics stderr names the variable" "$EMPTY_OUT" \
    "RESEARCH_TOPICS must be a non-empty comma-separated list"

# ---------------------------------------------------------------------------
# 10. Bootstrap-script generation names all 16 colonies.
# ---------------------------------------------------------------------------
assert_contains "10a. bootstrap-script generation step emitted" "$OUT" \
    "generating bootstrap script"
assert_contains "10b. bootstrap names explorer/noticer/.../submitter" "$OUT" \
    "colonies=explorer,noticer,skeptic,formulator,verifier,novelty,arxiv-search,oeis-search,groupprops-search,scholar-search,auditor,introducer,theorist,computer,editor,submitter"

# ---------------------------------------------------------------------------
# 11. Spawn command uses research-foundry-laptop name (single).
# ---------------------------------------------------------------------------
SPAWN_COUNT="$(printf '%s\n' "$OUT" | grep -cF 'podman run -d --replace --name research-foundry-laptop' || true)"
assert_eq "11. single research-foundry-laptop spawn command emitted" "1" "$SPAWN_COUNT"

# ---------------------------------------------------------------------------
# 12. run-meta.json write step emitted.
# ---------------------------------------------------------------------------
assert_contains "12. run-meta.json write step emitted" "$OUT" \
    "writing run-meta.json"

# ---------------------------------------------------------------------------
# 13. Cleanup trap installed (single trap line).
# ---------------------------------------------------------------------------
TRAP_COUNT="$(printf '%s\n' "$OUT" | grep -cF 'podman stop --time 5 research-foundry-laptop' || true)"
assert_eq "13. single cleanup-trap line emitted" "1" "$TRAP_COUNT"

# ---------------------------------------------------------------------------
# 14. Auto-promote sidecar emitted exactly once (either as the dry-run
# placeholder when the config file is present, or as a "missing,
# skipping" message when it is not -- both forms count toward the
# single-sidecar-block invariant).
# ---------------------------------------------------------------------------
SIDECAR_PLACEHOLDER="$(printf '%s\n' "$OUT" | grep -cF 'auto-promote-sidecar placeholder:' || true)"
SIDECAR_SKIP="$(printf '%s\n' "$OUT" | grep -cE 'auto-promote sidecar: .*(missing, skipping|disabled via)' || true)"
SIDECAR_COUNT=$((SIDECAR_PLACEHOLDER + SIDECAR_SKIP))
assert_eq "14. single auto-promote sidecar block emitted" "1" "$SIDECAR_COUNT"

# ---------------------------------------------------------------------------
# 15. Header-doc sanity (env vars documented).
# ---------------------------------------------------------------------------
SRC="$(cat "$ORCH")"
assert_contains "15a. header documents RESEARCH_TOPICS" "$SRC" "RESEARCH_TOPICS"
assert_contains "15b. header documents RESEARCH_PAPER_CORPUS" "$SRC" "RESEARCH_PAPER_CORPUS"
assert_contains "15c. header documents RESEARCH_TICK_INTERVAL_S" "$SRC" "RESEARCH_TICK_INTERVAL_S"
assert_contains "15d. header documents RESEARCH_TOTAL_TICKS" "$SRC" "RESEARCH_TOTAL_TICKS"
assert_contains "15e. header documents RESEARCH_DRY_RUN" "$SRC" "RESEARCH_DRY_RUN"
assert_contains "15f. header documents RESEARCH_RUN_DIR" "$SRC" "RESEARCH_RUN_DIR"
assert_contains "15g. header documents RESEARCH_AUTO_PROMOTE" "$SRC" "RESEARCH_AUTO_PROMOTE"
assert_contains "15h. header documents RESEARCH_FITNESS_REWARD_NOVEL_PER_TICK" "$SRC" \
    "RESEARCH_FITNESS_REWARD_NOVEL_PER_TICK"

# ---------------------------------------------------------------------------
# 16. Cross-fed recall flags are gone.
# ---------------------------------------------------------------------------
assert_not_contains "16a. --source-run flag removed" "$SRC" "--source-run"
assert_not_contains "16b. --source-audit-run flag removed" "$SRC" "--source-audit-run"
assert_not_contains "16c. --source-foundry-run flag removed" "$SRC" "--source-foundry-run"
assert_not_contains "16d. SOURCE_* env validation removed" "$SRC" "RESEARCH_SOURCE_RUN"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
