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
#      and names all 18 colonies.
#  11. Container spawn command is emitted in dry-run output using the
#      `research-foundry-laptop` name (single sidecar block).
#  12. Run-meta.json write step is emitted in dry-run output
#  13. Cleanup trap is installed in dry-run output (single trap line)
#  14. Auto-promote sidecar block emitted exactly once.
#  15. Header doc names every documented RESEARCH_* env var
#  16. Source-run / --source-* flags are gone (regression guard for
#      cross-fed recall removal).
#  18a-d. Sidecar `.auto-promote-install.toml` is written at
#      $LAPTOP_DIR (enabled = true on the default path, enabled =
#      false when RESEARCH_AUTO_PROMOTE=0) and removed by the cleanup
#      trap — so the dashboard's sidecar liveness probe (#248 / #378)
#      reports installed=true instead of `orphan` (#699).
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
# 10. Bootstrap-script generation names all 18 colonies.
# ---------------------------------------------------------------------------
assert_contains "10a. bootstrap-script generation step emitted" "$OUT" \
    "generating bootstrap script"
assert_contains "10b. bootstrap names explorer/noticer/.../submitter" "$OUT" \
    "colonies=explorer,noticer,skeptic,formulator,verifier,novelty,arxiv-search,oeis-search,groupprops-search,scholar-search,prior_advocate,auditor,introducer,theorist,computer,editor,reviewer,submitter"

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

# ---------------------------------------------------------------------------
# 17. Phase 9 PR-C (#663) + #670 + #711 follow-up: per-colony
# RESEARCH_<COLONY>_REPLICAS env defaults exist for all 17 non-explorer
# colonies, defaulting to 1 (lowered from 2 in #711 to drop the federation
# peak request rate from ~78 -> ~44 calls/min and clear the 9-stage
# cascade within the 60-min default run window).
# ---------------------------------------------------------------------------
for c in NOTICER FORMULATOR VERIFIER NOVELTY SKEPTIC \
         ARXIV_SEARCH OEIS_SEARCH GROUPPROPS_SEARCH SCHOLAR_SEARCH \
         PRIOR_ADVOCATE AUDITOR \
         INTRODUCER THEORIST COMPUTER EDITOR REVIEWER SUBMITTER; do
    assert_contains "17. RESEARCH_${c}_REPLICAS defaults to 1" "$SRC" \
        "\"\${RESEARCH_${c}_REPLICAS:=1}\""
done

# ---------------------------------------------------------------------------
# 18. Phase 9 PR-C (#663): spawn loops use seq 1 $RESEARCH_<COLONY>_REPLICAS
# for every non-explorer colony.
# ---------------------------------------------------------------------------
for c in NOTICER FORMULATOR VERIFIER NOVELTY SKEPTIC \
         ARXIV_SEARCH OEIS_SEARCH GROUPPROPS_SEARCH SCHOLAR_SEARCH \
         PRIOR_ADVOCATE AUDITOR \
         INTRODUCER THEORIST COMPUTER EDITOR REVIEWER SUBMITTER; do
    assert_contains "18. spawn loop uses RESEARCH_${c}_REPLICAS" "$SRC" \
        "\$RESEARCH_${c}_REPLICAS"
done

# ---------------------------------------------------------------------------
# 19. Phase 9 PR-C (#663): every spawn line in the 18 daemon blocks
# carries `--enable-replication --allow-replica-replication`. Count
# the substring across the bootstrap heredoc; explorer + 17 others = 18.
# ---------------------------------------------------------------------------
REPL_COUNT="$(printf '%s\n' "$SRC" | grep -cF -- "--enable-replication --allow-replica-replication" || true)"
if [ "$REPL_COUNT" -ge 18 ]; then
    echo "[PASS] 19. >=18 spawn lines carry --enable-replication --allow-replica-replication (count=$REPL_COUNT)"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 19. >=18 spawn lines carry --enable-replication --allow-replica-replication: got $REPL_COUNT"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# 20. Phase 9 PR-C (#663): RESEARCH_CULL_COLONIES default now covers all
# 18 colonies (was `explorer` only in PR-B).
# ---------------------------------------------------------------------------
assert_contains "20a. RESEARCH_CULL_COLONIES default includes explorer" "$SRC" \
    "RESEARCH_CULL_COLONIES:=explorer,"
assert_contains "20b. RESEARCH_CULL_COLONIES includes noticer" "$SRC" \
    "explorer,noticer,"
assert_contains "20c. RESEARCH_CULL_COLONIES includes submitter" "$SRC" \
    ",submitter}"

# ---------------------------------------------------------------------------
# 21. #670 follow-up: RESEARCH_JITTER_DISABLED is on the exec.env_passthrough
# allowlist so the per-tick `_jitter_sleep()` helper inside each .ag can read
# the disable flag via `printenv`.
# ---------------------------------------------------------------------------
assert_contains "21. RESEARCH_JITTER_DISABLED in exec.env_passthrough" "$SRC" \
    "RESEARCH_JITTER_DISABLED"

# ---------------------------------------------------------------------------
# 22. #679: lifecycle-on-default. Birth/death/respawn must engage in the
# default 30-tick run-research.sh run without operator opt-in. Four knobs
# were flipped:
#   - RESEARCH_CULL_ENABLED       :  0 -> 1   (function-scoped fallback)
#   - RESEARCH_CULL_INTERVAL_TICKS: 20 -> 5   (both :=5 default + :-5 fallback)
#   - RESEARCH_<COLONY>_REPRODUCTIVE_FITNESS_THRESHOLD: 10 -> 3 (all 18 colonies)
#   - RESEARCH_CULL_MIN_ACTING    : 10 -> 3   (function-scoped fallback)
# Explorer-specific RESEARCH_CULL_MIN_EXPLORERS=3 stays untouched as
# floor protection.
# ---------------------------------------------------------------------------
assert_contains "22a. RESEARCH_CULL_ENABLED defaults to 1" "$SRC" \
    "CULL_ENABLED=\"\${RESEARCH_CULL_ENABLED:-1}\""
assert_contains "22b. RESEARCH_CULL_INTERVAL_TICKS top-level default is 5" "$SRC" \
    ": \"\${RESEARCH_CULL_INTERVAL_TICKS:=5}\""
assert_contains "22c. RESEARCH_CULL_INTERVAL_TICKS function-scoped fallback is 5" "$SRC" \
    "CULL_INTERVAL_TICKS=\"\${RESEARCH_CULL_INTERVAL_TICKS:-5}\""
assert_contains "22d. RESEARCH_CULL_MIN_ACTING defaults to 3" "$SRC" \
    "CULL_MIN_ACTING=\"\${RESEARCH_CULL_MIN_ACTING:-3}\""
assert_contains "22e. CULL_MIN_EXPLORERS floor protection unchanged at 3" "$SRC" \
    "CULL_MIN_EXPLORERS=\"\${RESEARCH_CULL_MIN_EXPLORERS:-3}\""
for c in EXPLORER NOTICER SKEPTIC FORMULATOR VERIFIER NOVELTY \
         ARXIV_SEARCH OEIS_SEARCH GROUPPROPS_SEARCH SCHOLAR_SEARCH \
         AUDITOR PRIOR_ADVOCATE INTRODUCER THEORIST COMPUTER \
         EDITOR REVIEWER SUBMITTER; do
    assert_contains "22f. RESEARCH_${c}_REPRODUCTIVE_FITNESS_THRESHOLD defaults to 3" "$SRC" \
        "\"\${RESEARCH_${c}_REPRODUCTIVE_FITNESS_THRESHOLD:=3}\""
done

# ---------------------------------------------------------------------------
# 18a-d (#699): start_auto_promote_sidecar writes .auto-promote-install.toml
# at $LAPTOP_DIR so the dashboard's sidecar liveness probe (#248 / #378)
# reports installed=true, status="ok" instead of running_orphan=true,
# status="orphan". Schema must byte-match dev-apprenticeship/install.sh
# (federation-dashboard-collector.py:906 parses [auto_promote] with
# underscore). Cleanup trap removes the file on EXIT/INT/TERM.
# ---------------------------------------------------------------------------
assert_contains "18a. dry-run emits .auto-promote-install.toml write" "$OUT" \
    "> $WORK_DIR/run-default/laptop-node/.auto-promote-install.toml"
assert_contains "18b. emitted file content carries the [auto_promote] section header" "$OUT" \
    '[auto_promote]\nenabled = true\ninterval_s = 300\n'

DISABLED_OUT="$(RESEARCH_DRY_RUN=1 RESEARCH_AUTO_PROMOTE=0 \
                RESEARCH_RUN_DIR="$WORK_DIR/run-disabled" \
                bash "$ORCH" 2>&1)"
assert_contains "18c. RESEARCH_AUTO_PROMOTE=0 emits enabled = false write" "$DISABLED_OUT" \
    '[auto_promote]\nenabled = false\n'

assert_contains "18d. cleanup trap removes .auto-promote-install.toml on EXIT/INT/TERM" "$OUT" \
    "rm -f \"$WORK_DIR/run-default/laptop-node/.auto-promote-install.toml\""

# ---------------------------------------------------------------------------
# 23. #711: per-colony RESEARCH_<COLONY>_CLAUDE_MODEL env defaults. 8
# colonies stay opus (quality-critical: math creativity, correctness,
# decisive verdicts); 10 colonies downgrade to sonnet (mechanical /
# parsing / scripted output).
# ---------------------------------------------------------------------------
for c in EXPLORER FORMULATOR VERIFIER NOVELTY \
         PRIOR_ADVOCATE AUDITOR THEORIST EDITOR; do
    assert_contains "23. RESEARCH_${c}_CLAUDE_MODEL defaults to opus" "$SRC" \
        "\"\${RESEARCH_${c}_CLAUDE_MODEL:=opus}\""
done
for c in NOTICER SKEPTIC \
         ARXIV_SEARCH OEIS_SEARCH GROUPPROPS_SEARCH SCHOLAR_SEARCH \
         INTRODUCER COMPUTER REVIEWER SUBMITTER; do
    assert_contains "23. RESEARCH_${c}_CLAUDE_MODEL defaults to sonnet" "$SRC" \
        "\"\${RESEARCH_${c}_CLAUDE_MODEL:=sonnet}\""
done

# ---------------------------------------------------------------------------
# 24. #711: each of the 18 daemon spawn lines in the bootstrap heredoc
# carries `ANTHROPIC_MODEL=$RESEARCH_<COLONY>_CLAUDE_MODEL` so the claude
# CLI honors the per-colony model split natively.
# ---------------------------------------------------------------------------
for c in EXPLORER NOTICER SKEPTIC FORMULATOR VERIFIER NOVELTY \
         ARXIV_SEARCH OEIS_SEARCH GROUPPROPS_SEARCH SCHOLAR_SEARCH \
         PRIOR_ADVOCATE AUDITOR \
         INTRODUCER THEORIST COMPUTER EDITOR REVIEWER SUBMITTER; do
    assert_contains "24. spawn line references RESEARCH_${c}_CLAUDE_MODEL" "$SRC" \
        "\$RESEARCH_${c}_CLAUDE_MODEL"
done
ANTHROPIC_COUNT="$(printf '%s\n' "$SRC" | grep -cF -- "ANTHROPIC_MODEL=%s" || true)"
if [ "$ANTHROPIC_COUNT" -ge 18 ]; then
    echo "[PASS] 24. >=18 spawn lines prefix ANTHROPIC_MODEL=%s (count=$ANTHROPIC_COUNT)"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 24. >=18 spawn lines prefix ANTHROPIC_MODEL=%s: got $ANTHROPIC_COUNT"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# 25. #711: the shared `llm.args` printf line drops the `--model %s` slot
# (model now comes from ANTHROPIC_MODEL env on each spawn) but keeps the
# `--effort %s` slot (effort is orthogonal to the model split).
# ---------------------------------------------------------------------------
assert_not_contains "25a. llm.args printf no longer carries --model %s" "$SRC" \
    "llm.args = -p --output-format json --model %s"
assert_contains "25b. llm.args printf still carries --effort %s" "$SRC" \
    "--effort %s"
assert_contains "25c. ANTHROPIC_MODEL added to exec.env_passthrough allowlist" "$SRC" \
    "RESEARCH_JITTER_DISABLED,ANTHROPIC_MODEL"

# ---------------------------------------------------------------------------
# 26. #740: AdaptiveEngine activation. The hermetic .agentis/config block
# in run-research.sh must write `learning.enabled = true` so the
# recommend() / adapt() / score_options() builtins are live. Mirrors
# dev-apprenticeship/install.sh L707.
# ---------------------------------------------------------------------------
assert_contains "26. run-research.sh writes learning.enabled = true" "$SRC" \
    'printf "learning.enabled = true\\n"'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
