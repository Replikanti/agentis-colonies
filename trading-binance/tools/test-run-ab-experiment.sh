#!/bin/bash
# test-run-ab-experiment.sh -- smoke test for run-ab-experiment.sh
# --dry-run mode (#573 PR-5) plus a staged real-run section (#1947).
#
# 8 assertions covering the harness control surface:
#   1. --help works (returns 0, prints usage).
#   2. AB_DRY_RUN=1 AB_N_REPLICATES=2 emits exactly 4 run-replay.sh
#      lines (2 arms * 2 replicates).
#   3. Control replicates carry
#      REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=999.
#   4. Treatment replicates carry
#      REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=3.
#   5. Per-run dirs follow ab-trading-*-{control,treatment}-run-*
#      naming.
#   6. experiment-manifest.json path is emitted in the plan.
#   7. analyze-ab-results.py invocation emitted after the runs.
#   8. Unknown flag exits non-zero (2).
#
# Plus a real-run (AB_DRY_RUN=0) integration section (#1947) driven
# against a staged federation root (mktemp tree + stub run-replay.sh),
# which is where the empty-`runs` manifest bug lived:
#   9.  Happy path: exit 0, manifest carries one entry per replicate with
#       the right arm / run_idx / run_dir / threshold / exit_code, the
#       analyser maps every run dir and comparison.md is written.
#   10. A replicate failing with exit 7 round-trips into the manifest and
#       the harness exits 4.
#   11. Missing write-ab-manifest.py -> exit 3 + `missing dependent script`.
#   12. Failing write-ab-manifest.py -> exit 6 + `manifest assembly failed`.
#   13. The dry-run plan names the real manifest writer.
#
# Standard library only -- no pytest, no live LLM, no podman.
#
# Usage: bash trading-binance/tools/test-run-ab-experiment.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$SCRIPT_DIR/run-ab-experiment.sh"

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

if [ ! -x "$HARNESS" ]; then
    echo "[FAIL] run-ab-experiment.sh not executable at $HARNESS"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. --help works.
# ---------------------------------------------------------------------------
HELP_RC=0
HELP_OUT="$(bash "$HARNESS" --help 2>&1)" || HELP_RC=$?
assert_eq "1a. --help exits 0" "0" "$HELP_RC"
assert_contains "1b. --help prints harness summary" "$HELP_OUT" \
    "A/B emergence experiment harness"
assert_contains "1c. --help documents AB_N_REPLICATES" "$HELP_OUT" \
    "AB_N_REPLICATES"

# ---------------------------------------------------------------------------
# 2-7. AB_DRY_RUN=1 AB_N_REPLICATES=2 -> 4 run-replay invocations + manifest
#      + analyser invocation.
# ---------------------------------------------------------------------------
DRY_RC=0
DRY_OUT="$(AB_DRY_RUN=1 AB_N_REPLICATES=2 \
           AB_SYMBOL=BTCUSDT AB_TIMEFRAME=1h \
           bash "$HARNESS" 2>&1)" || DRY_RC=$?
assert_eq "2a. AB_DRY_RUN=1 exits 0" "0" "$DRY_RC"

run_replay_lines=$(printf '%s\n' "$DRY_OUT" | grep -c 'bash .*run-replay.sh' || true)
assert_eq "2b. exactly 4 run-replay.sh invocations emitted (2 arms x 2 reps)" \
    "4" "$run_replay_lines"

# 3. Control threshold (999) appears in dry-run.
control_999_lines=$(printf '%s\n' "$DRY_OUT" \
    | grep -F 'REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=999' \
    | grep -c 'bash .*run-replay.sh' || true)
assert_eq "3. control replicates carry threshold=999" "2" "$control_999_lines"

# 4. Treatment threshold (3) appears in dry-run.
treatment_3_lines=$(printf '%s\n' "$DRY_OUT" \
    | grep -F 'REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=3 ' \
    | grep -c 'bash .*run-replay.sh' || true)
assert_eq "4. treatment replicates carry threshold=3" "2" "$treatment_3_lines"

# 5. Per-run dir naming convention.
assert_contains "5a. control-run-1 dir name emitted" "$DRY_OUT" \
    "control-run-1"
assert_contains "5b. control-run-2 dir name emitted" "$DRY_OUT" \
    "control-run-2"
assert_contains "5c. treatment-run-1 dir name emitted" "$DRY_OUT" \
    "treatment-run-1"
assert_contains "5d. treatment-run-2 dir name emitted" "$DRY_OUT" \
    "treatment-run-2"

# 6. experiment-manifest.json path emitted.
assert_contains "6. experiment-manifest.json path emitted" "$DRY_OUT" \
    "experiment-manifest.json"

# 7. analyser invocation emitted (after the runs).
assert_contains "7. analyze-ab-results.py invocation emitted" "$DRY_OUT" \
    "analyze-ab-results.py"

# Verify ordering: analyser line appears AFTER the last run-replay line.
analyser_pos=$(printf '%s\n' "$DRY_OUT" | grep -n 'analyze-ab-results.py' | tail -1 | cut -d: -f1)
last_replay_pos=$(printf '%s\n' "$DRY_OUT" | grep -n 'bash .*run-replay.sh' | tail -1 | cut -d: -f1)
if [ -n "$analyser_pos" ] && [ -n "$last_replay_pos" ] && [ "$analyser_pos" -gt "$last_replay_pos" ]; then
    echo "[PASS] 7b. analyser invocation strictly after last replicate"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 7b. analyser invocation ordering wrong (analyser_pos=$analyser_pos last_replay_pos=$last_replay_pos)"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# 8. Unknown flag exits 2.
# ---------------------------------------------------------------------------
UNK_RC=0
bash "$HARNESS" --no-such-flag >/dev/null 2>&1 || UNK_RC=$?
assert_eq "8. unknown flag exits 2" "2" "$UNK_RC"

# ---------------------------------------------------------------------------
# 13. Dry-run plan names the real manifest writer (#1947).
# ---------------------------------------------------------------------------
assert_contains "13. dry-run plan names write-ab-manifest.py" "$DRY_OUT" \
    "write-ab-manifest.py"

# ---------------------------------------------------------------------------
# 9-12. Real-run (AB_DRY_RUN=0) integration against a staged federation
#       root: mktemp tree carrying copies of the harness, the analyser and
#       the manifest writer plus a stub run-replay.sh. No podman, no
#       agentis binary, no network, no LLM.
# ---------------------------------------------------------------------------
STAGED_ROOTS=""
cleanup_staged() {
    for staged in $STAGED_ROOTS; do
        [ -n "$staged" ] && rm -rf "$staged"
    done
}
trap cleanup_staged EXIT

# _stage_fed_root <replay-exit-code> -> prints the staged FED_ROOT path.
_stage_fed_root() {
    stage_rc="$1"
    staged_root="$(mktemp -d)"
    STAGED_ROOTS="$STAGED_ROOTS $staged_root"
    mkdir -p "$staged_root/tools"
    cp "$HARNESS" "$staged_root/tools/run-ab-experiment.sh"
    cp "$SCRIPT_DIR/analyze-ab-results.py" "$staged_root/tools/analyze-ab-results.py"
    cp "$SCRIPT_DIR/write-ab-manifest.py" "$staged_root/tools/write-ab-manifest.py"
    {
        echo '#!/bin/bash'
        echo '# Stub run-replay.sh: creates the pinned run dir, then exits.'
        echo 'mkdir -p "$REPLAY_RUN_DIR"'
        echo "exit $stage_rc"
    } > "$staged_root/tools/run-replay.sh"
    chmod +x "$staged_root/tools/run-ab-experiment.sh" \
             "$staged_root/tools/run-replay.sh" \
             "$staged_root/tools/write-ab-manifest.py"
    printf '%s' "$staged_root"
}

# Repo-local runs/ must stay untouched by the staged runs.
REPO_RUNS_DIR="$(dirname "$SCRIPT_DIR")/runs"
repo_runs_before="$(ls -1 "$REPO_RUNS_DIR" 2>/dev/null | wc -l | tr -d ' ')"

# --- 9. Happy path -----------------------------------------------------------
FED_OK="$(_stage_fed_root 0)"
OK_RC=0
OK_ERR="$(FED_ROOT="$FED_OK" AB_DRY_RUN=0 AB_N_REPLICATES=2 \
          AB_SYMBOL=BTCUSDT AB_TIMEFRAME=1h \
          bash "$FED_OK/tools/run-ab-experiment.sh" 2>&1 >/dev/null)" || OK_RC=$?
assert_eq "9a. staged real run exits 0" "0" "$OK_RC"

OK_EXP_DIR="$(find "$FED_OK/runs" -mindepth 1 -maxdepth 1 -type d -name 'ab-trading-*' 2>/dev/null | head -1)"
OK_MANIFEST="$OK_EXP_DIR/experiment-manifest.json"
if [ -f "$OK_MANIFEST" ]; then
    echo "[PASS] 9b. experiment-manifest.json written"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 9b. experiment-manifest.json missing at $OK_MANIFEST"
    FAIL=$((FAIL + 1))
fi

# Flatten the manifest to one grep-able line per run entry.
MANIFEST_SUMMARY="$(python3 -c '
import json, os, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    m = json.load(f)
runs = m["runs"]
print("nruns=" + str(len(runs)))
for r in runs:
    print("|".join([
        r["arm"],
        str(r["run_idx"]),
        os.path.basename(r["run_dir"].rstrip("/")),
        str(r["strategist_prompt_evolution_threshold"]),
        str(r["exit_code"]),
    ]))
' "$OK_MANIFEST")"

assert_contains "9c. manifest records all 4 replicates" "$MANIFEST_SUMMARY" "nruns=4"
assert_contains "9d. control run 1 recorded with threshold 999 + exit 0" \
    "$MANIFEST_SUMMARY" "control|1|ab-trading-"
assert_contains "9e. control rows carry threshold 999" "$MANIFEST_SUMMARY" \
    "-control-run-2|999|0"
assert_contains "9f. treatment rows carry threshold 3" "$MANIFEST_SUMMARY" \
    "-treatment-run-2|3|0"

if printf '%s' "$OK_ERR" | grep -Fq 'cannot be mapped to an arm'; then
    echo "[FAIL] 9g. analyser reported unmapped run dirs"
    echo "       output: $OK_ERR"
    FAIL=$((FAIL + 1))
else
    echo "[PASS] 9g. analyser mapped every run dir to an arm"
    PASS=$((PASS + 1))
fi

if [ -f "$OK_EXP_DIR/comparison.md" ]; then
    echo "[PASS] 9h. comparison.md written by the analyse step"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 9h. comparison.md missing in $OK_EXP_DIR"
    FAIL=$((FAIL + 1))
fi

# --- 10. Replicate exit codes round-trip ------------------------------------
FED_FAIL="$(_stage_fed_root 7)"
FAIL_RC=0
FED_ROOT="$FED_FAIL" AB_DRY_RUN=0 AB_N_REPLICATES=1 \
    bash "$FED_FAIL/tools/run-ab-experiment.sh" >/dev/null 2>&1 || FAIL_RC=$?
assert_eq "10a. failing replicates exit 4" "4" "$FAIL_RC"

FAIL_MANIFEST="$(find "$FED_FAIL/runs" -mindepth 2 -maxdepth 2 -name 'experiment-manifest.json' 2>/dev/null | head -1)"
FAIL_SUMMARY="$(python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    m = json.load(f)
codes = sorted(set(str(r["exit_code"]) for r in m["runs"]))
print("nruns=" + str(len(m["runs"])) + " codes=" + ",".join(codes))
' "$FAIL_MANIFEST")"
assert_contains "10b. every manifest row records exit_code 7" "$FAIL_SUMMARY" \
    "nruns=2 codes=7"

# --- 11. Missing manifest writer --------------------------------------------
FED_NOWRITER="$(_stage_fed_root 0)"
rm -f "$FED_NOWRITER/tools/write-ab-manifest.py"
NOWRITER_RC=0
NOWRITER_ERR="$(FED_ROOT="$FED_NOWRITER" AB_DRY_RUN=0 AB_N_REPLICATES=1 \
                bash "$FED_NOWRITER/tools/run-ab-experiment.sh" 2>&1 >/dev/null)" || NOWRITER_RC=$?
assert_eq "11a. missing write-ab-manifest.py exits 3" "3" "$NOWRITER_RC"
assert_contains "11b. missing writer names the dependency" "$NOWRITER_ERR" \
    "missing dependent script"

# --- 12. Failing manifest writer --------------------------------------------
FED_BADWRITER="$(_stage_fed_root 0)"
{
    echo '#!/usr/bin/env python3'
    echo '# Stub writer: consumes the record stream, then fails.'
    echo 'import sys'
    echo 'sys.stdin.buffer.read()'
    echo 'sys.exit(1)'
} > "$FED_BADWRITER/tools/write-ab-manifest.py"
chmod +x "$FED_BADWRITER/tools/write-ab-manifest.py"
BADWRITER_RC=0
BADWRITER_ERR="$(FED_ROOT="$FED_BADWRITER" AB_DRY_RUN=0 AB_N_REPLICATES=1 \
                 bash "$FED_BADWRITER/tools/run-ab-experiment.sh" 2>&1 >/dev/null)" || BADWRITER_RC=$?
assert_eq "12a. failing manifest writer exits 6" "6" "$BADWRITER_RC"
assert_contains "12b. failing writer reports manifest assembly failure" \
    "$BADWRITER_ERR" "manifest assembly failed"

# --- Staged runs never touch the repo's own runs/ ---------------------------
repo_runs_after="$(ls -1 "$REPO_RUNS_DIR" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "staged runs leave trading-binance/runs/ untouched" \
    "$repo_runs_before" "$repo_runs_after"

# Header-doc sanity.
SRC="$(cat "$HARNESS")"
assert_contains "header documents AB_N_REPLICATES" "$SRC" "AB_N_REPLICATES"
assert_contains "header documents AB_SYMBOL" "$SRC" "AB_SYMBOL"
assert_contains "header documents AB_TIMEFRAME" "$SRC" "AB_TIMEFRAME"
assert_contains "header documents AB_SPEED" "$SRC" "AB_SPEED"
assert_contains "header documents AB_DRY_RUN" "$SRC" "AB_DRY_RUN"
assert_contains "header documents binance-feed-download prerequisite" "$SRC" \
    "binance-feed-download.py"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
