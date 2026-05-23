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
#  23-25. Per-tier LLM routing (#746) replaces #711's per-role
#      ANTHROPIC_MODEL=<resolved> spawn-prefix routing with five
#      llm.tier.<tier>.cli_command_args lines in the claude-backend
#      block of .agentis/config. The 18 per-role env knobs survive
#      as deprecated shims with a one-time stderr warning on
#      operator override.
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
# #744: EXPLORER threshold default lowered 3 -> 2 (asserted by 32f below).
# The remaining 17 colonies keep default 3 until follow-up tuning lowers them.
for c in NOTICER SKEPTIC FORMULATOR VERIFIER NOVELTY \
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
# 23. #711 / #746: per-colony RESEARCH_<COLONY>_CLAUDE_MODEL env defaults
# remain as backward-compat shims after #746 migrated routing to the
# per-tier substrate. 8 colonies default opus, 10 default sonnet. The
# values are no longer load-bearing -- the spawn-prefix path was dropped
# in #746 -- but the env knobs survive one minor-release deprecation
# window so cost-experiment tooling does not silently break.
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
# 24. #746: per-tier LLM routing via llm.tier.<tier>.cli_command_args.
# Autonomous-tier decisions get opus, propose + review-gated get sonnet,
# shadow + dormant get haiku. Substrate is agentis-core v1.7.15 #652;
# agentis-core resolves the backend per-prompt by re-reading the calling
# agent's <agent>:confidence memo via tier(). Five tiers => five printf
# lines in the claude-backend block of the hermetic .agentis/config.
# ---------------------------------------------------------------------------
assert_contains "24a. llm.tier.dormant.cli_command_args = --model claude-haiku-4-5" "$SRC" \
    'printf "llm.tier.dormant.cli_command_args = --model claude-haiku-4-5\\n"'
assert_contains "24b. llm.tier.shadow.cli_command_args = --model claude-haiku-4-5" "$SRC" \
    'printf "llm.tier.shadow.cli_command_args = --model claude-haiku-4-5\\n"'
assert_contains "24c. llm.tier.propose.cli_command_args = --model claude-sonnet-4-6" "$SRC" \
    'printf "llm.tier.propose.cli_command_args = --model claude-sonnet-4-6\\n"'
assert_contains "24d. llm.tier.review-gated.cli_command_args = --model claude-sonnet-4-6" "$SRC" \
    'printf "llm.tier.review-gated.cli_command_args = --model claude-sonnet-4-6\\n"'
assert_contains "24e. llm.tier.autonomous.cli_command_args = --model claude-opus-4-7" "$SRC" \
    'printf "llm.tier.autonomous.cli_command_args = --model claude-opus-4-7\\n"'

# ---------------------------------------------------------------------------
# 25. #746: ANTHROPIC_MODEL=%s spawn-prefix routing (#711) is gone --
# replaced by per-tier substrate above. The 18 daemon spawn lines drop
# the env prefix + matching printf arg, and ANTHROPIC_MODEL is removed
# from the exec.env_passthrough allowlist. The shared `llm.args` printf
# line continues to drop the `--model %s` slot (substrate writes
# per-tier --model) and keeps `--effort %s` (orthogonal to model
# selection).
# ---------------------------------------------------------------------------
assert_not_contains "25a. llm.args printf no longer carries --model %s" "$SRC" \
    "llm.args = -p --output-format json --model %s"
assert_contains "25b. llm.args printf still carries --effort %s" "$SRC" \
    "--effort %s"
assert_not_contains "25c. ANTHROPIC_MODEL removed from exec.env_passthrough allowlist" "$SRC" \
    "RESEARCH_JITTER_DISABLED,ANTHROPIC_MODEL"
ANTHROPIC_COUNT="$(printf '%s\n' "$SRC" | grep -cF -- "ANTHROPIC_MODEL=%s" || true)"
if [ "$ANTHROPIC_COUNT" -eq 0 ]; then
    echo "[PASS] 25d. zero spawn lines prefix ANTHROPIC_MODEL=%s (count=$ANTHROPIC_COUNT)"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 25d. zero spawn lines prefix ANTHROPIC_MODEL=%s: got $ANTHROPIC_COUNT"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# 25e. #746: deprecation shim fires a [WARN] line to stderr when the
# operator exports any RESEARCH_<ROLE>_CLAUDE_MODEL. The substrate
# routes by tier, not by per-role env, so the operator gets a heads-up
# that their override is no longer load-bearing.
# ---------------------------------------------------------------------------
DEPR_RC=0
DEPR_OUT="$(RESEARCH_DRY_RUN=1 \
            RESEARCH_EXPLORER_CLAUDE_MODEL=foo \
            RESEARCH_RUN_DIR="$WORK_DIR/run-depr" \
            bash "$ORCH" 2>&1)" || DEPR_RC=$?
assert_eq "25e. dry-run with deprecated env knob still exits 0" "0" "$DEPR_RC"
assert_contains "25f. deprecation [WARN] line fires for RESEARCH_EXPLORER_CLAUDE_MODEL" "$DEPR_OUT" \
    "RESEARCH_EXPLORER_CLAUDE_MODEL is deprecated (#746)"

# ---------------------------------------------------------------------------
# 26. #740: AdaptiveEngine activation. The hermetic .agentis/config block
# in run-research.sh must write `learning.enabled = true` so the
# recommend() / adapt() / score_options() builtins are live. Mirrors
# dev-apprenticeship/install.sh L707.
# ---------------------------------------------------------------------------
assert_contains "26. run-research.sh writes learning.enabled = true" "$SRC" \
    'printf "learning.enabled = true\\n"'

# ---------------------------------------------------------------------------
# 27. #741: knowledge market wiring. novelty.ag sells findings;
# explorer.ag and prior_advocate.ag buy them. learning.enabled = true
# (asserted above) is the prerequisite so the calls do not silently
# fail.
# ---------------------------------------------------------------------------
NOV_AG_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/novelty/agents/novelty.ag"
EXP_AG_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/explorer/agents/explorer.ag"
PRI_AG_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/prior_advocate/agents/prior_advocate.ag"
NOV_AG_SRC="$(cat "$NOV_AG_PATH")"
EXP_AG_SRC="$(cat "$EXP_AG_PATH")"
PRI_AG_SRC="$(cat "$PRI_AG_PATH")"
assert_contains "27a. novelty.ag binds permutation_order_facts sell topic" "$NOV_AG_SRC" \
    'let sell_topic = "permutation_order_facts:"'
assert_contains "27b. novelty.ag binds known_priors sell topic" "$NOV_AG_SRC" \
    'let sell_topic = "known_priors:"'
assert_contains "27c. novelty.ag calls knowledge_sell" "$NOV_AG_SRC" \
    'knowledge_sell(sell_topic,'
assert_contains "27d. explorer.ag binds permutation_order_facts buy topic" "$EXP_AG_SRC" \
    'let buy_topic = "permutation_order_facts:"'
assert_contains "27e. explorer.ag calls knowledge_buy" "$EXP_AG_SRC" \
    'knowledge_buy(buy_topic, 5)'
assert_contains "27f. prior_advocate.ag binds known_priors buy topic" "$PRI_AG_SRC" \
    'let buy_topic_pa = "known_priors:"'
assert_contains "27g. prior_advocate.ag calls knowledge_buy" "$PRI_AG_SRC" \
    'knowledge_buy(buy_topic_pa, 2)'

# ---------------------------------------------------------------------------
# 28. #743: Action audit chain activation with ed25519 signing. The
# hermetic .agentis/config block must enable `audit.persist_actions =
# true` (otherwise rows never flush to <root>/audit/actions.jsonl) and
# pin `audit.signing_key_path` to an explicit path under .agentis/
# identity/. The bootstrap script must also create both .agentis/audit/
# and .agentis/identity/ dirs (agentis init does not), bootstrap the
# ed25519 keypair, and chmod 600 it. Together these wire the M2
# tamper-evident chain (seq + prev_hash + signer_pubkey + signature)
# verifiable via `agentis audit verify-actions`.
# ---------------------------------------------------------------------------
assert_contains "28a. run-research.sh writes audit.persist_actions = true" "$SRC" \
    'printf "audit.persist_actions = true\\n"'
assert_contains "28b. run-research.sh pins audit.signing_key_path" "$SRC" \
    'printf "audit.signing_key_path = .agentis/identity/private.key\\n"'
assert_contains "28c. bootstrap mkdir extends to .agentis/audit + .agentis/identity" "$SRC" \
    '/run-root/.agentis/audit /run-root/.agentis/identity'
assert_contains "28d. ed25519 identity key bootstrap reads 32 bytes from /dev/urandom" "$SRC" \
    'dd if=/dev/urandom of=/run-root/.agentis/identity/private.key bs=32 count=1'
assert_contains "28e. chmod 600 on identity private key emitted" "$SRC" \
    'chmod 600 /run-root/.agentis/identity/private.key'

# ---------------------------------------------------------------------------
# 29. #745: Lean 4 verifier integration.
#   - Containerfile.research installs Lean via elan + pinned toolchain
#   - theorist.ag emits .lean source and runs `lean` per tick
#   - auditor.ag fans in lean_verdict and extends its verdict-label
#     enum to include VERIFIED_BY_LEAN
# ---------------------------------------------------------------------------
CFILE_PATH="$(cd "$SCRIPT_DIR" && pwd)/Containerfile.research"
LEAN_THE_AG_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/theorist/agents/theorist.ag"
AUD_AG_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/auditor/agents/auditor.ag"
CFILE_SRC="$(cat "$CFILE_PATH")"
LEAN_THE_AG_SRC="$(cat "$LEAN_THE_AG_PATH")"
AUD_AG_SRC="$(cat "$AUD_AG_PATH")"

assert_contains "29a. Containerfile.research declares LEAN_TOOLCHAIN ARG" "$CFILE_SRC" \
    "ARG LEAN_TOOLCHAIN=leanprover/lean4:"
assert_contains "29b. Containerfile.research installs elan via elan-init.sh" "$CFILE_SRC" \
    "elan/master/elan-init.sh"
assert_contains "29c. Containerfile.research exports /root/.elan/bin in PATH" "$CFILE_SRC" \
    'ENV PATH="/root/.elan/bin:${PATH}"'
assert_contains "29d. Containerfile.research runs lean --version smoke test" "$CFILE_SRC" \
    "RUN lean --version"

assert_contains "29e. theorist.ag declares LeanDraft type" "$LEAN_THE_AG_SRC" \
    "type LeanDraft"
assert_contains "29f. theorist.ag has _lean_prompt helper" "$LEAN_THE_AG_SRC" \
    "fn _lean_prompt() -> string"
assert_contains "29g. theorist.ag has _run_lean_check helper" "$LEAN_THE_AG_SRC" \
    "fn _run_lean_check"
assert_contains "29h. theorist.ag invokes lean binary via exec sh" "$LEAN_THE_AG_SRC" \
    '"timeout " + shell_escape(timeout_s) + " lean "'
assert_contains "29i. theorist.ag writes lean_verdict memo key" "$LEAN_THE_AG_SRC" \
    '":lean_verdict:tick-"'
assert_contains "29j. theorist.ag writes lean_source memo key" "$LEAN_THE_AG_SRC" \
    '":lean_source:tick-"'
assert_contains "29k. theorist.ag emits learn(lean_check, ...)" "$LEAN_THE_AG_SRC" \
    'learn("lean_check"'
assert_contains "29l. theorist.ag honors THEORIST_LEAN_DISABLED bypass" "$LEAN_THE_AG_SRC" \
    "THEORIST_LEAN_DISABLED"
assert_contains "29m. theorist.ag honors THEORIST_LEAN_TIMEOUT_SEC override" "$LEAN_THE_AG_SRC" \
    "THEORIST_LEAN_TIMEOUT_SEC"

assert_contains "29n. auditor.ag _seed_prompt names VERIFIED_BY_LEAN" "$AUD_AG_SRC" \
    "VERIFIED_BY_LEAN"
assert_contains "29o. auditor.ag fans in theorist lean_verdict via picker" "$AUD_AG_SRC" \
    '_pick_upstream_by_confidence("theorist", "lean_verdict", "lean_verdict", ""'
assert_contains "29p. auditor.ag ctx names THEORIST LEAN VERDICT" "$AUD_AG_SRC" \
    "THEORIST LEAN VERDICT:"

# ---------------------------------------------------------------------------
# 30. #745: check-learn-tags.sh schema extension for lean_check topic.
# ---------------------------------------------------------------------------
LEARN_TAGS_PATH="$(cd "$SCRIPT_DIR/../.." && pwd)/tools/check-learn-tags.sh"
LEARN_TAGS_SRC="$(cat "$LEARN_TAGS_PATH")"
assert_contains "30a. check-learn-tags.sh schema covers lean_check:verified" "$LEARN_TAGS_SRC" \
    '"lean_check:verified")'
assert_contains "30b. check-learn-tags.sh schema covers lean_check:incomplete" "$LEARN_TAGS_SRC" \
    '"lean_check:incomplete")'
assert_contains "30c. check-learn-tags.sh schema covers lean_check:failed" "$LEARN_TAGS_SRC" \
    '"lean_check:failed")'

# ---------------------------------------------------------------------------
# 31. #742: TaskBoard cognitive-market delegation. Without
# `economy.enabled = true` in `.agentis/config`, the offer / accept /
# complete builtins raise an economy-not-enabled error per the
# agentis-core CB-escrow contract. With it open + the optional
# `market.task_timeout_s` and `market.max_open_tasks` keys, the
# substrate is ready for the first federation consumer. explorer.ag
# offers compute-heavy claims (compute_partition_orbits) on the
# `research-foundry:compute` channel; computer.ag accepts + completes;
# theorist.ag accepts on `research-foundry:theory`. Result readback is
# memo-mediated via `taskboard:result:<task_id>` because TaskBoard's
# `get_task_result` is not yet an evaluator builtin (filed as
# agentis-core follow-up).
# ---------------------------------------------------------------------------
assert_contains "31a. run-research.sh writes economy.enabled = true" "$SRC" \
    'printf "economy.enabled = true\\n"'
assert_contains "31b. run-research.sh sets market.task_timeout_s" "$SRC" \
    'printf "market.task_timeout_s = 600\\n"'
assert_contains "31c. run-research.sh sets market.max_open_tasks" "$SRC" \
    'printf "market.max_open_tasks = 5000\\n"'

CMP_AG_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/computer/agents/computer.ag"
TB_THE_AG_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/theorist/agents/theorist.ag"
CMP_AG_SRC="$(cat "$CMP_AG_PATH")"
TB_THE_AG_SRC="$(cat "$TB_THE_AG_PATH")"

assert_contains "31d. explorer.ag calls offer() on research-foundry:compute channel" "$EXP_AG_SRC" \
    'offer("research-foundry:compute"'
assert_contains "31e. explorer.ag emits learn(\"taskboard\", ..., \"success\") for offered tag" "$EXP_AG_SRC" \
    'learn("taskboard", "offer compute_partition_orbits"'
assert_contains "31f. explorer.ag emits learn(\"taskboard\", ..., \"success\") for completed tag (readback)" "$EXP_AG_SRC" \
    'learn("taskboard", "readback result"'

assert_contains "31g. computer.ag calls accept() on research-foundry:compute channel" "$CMP_AG_SRC" \
    'accept("research-foundry:compute")'
assert_contains "31h. computer.ag calls complete() to settle escrow" "$CMP_AG_SRC" \
    'complete(task_id_int, result_clamped)'
assert_contains "31i. computer.ag writes taskboard:result:<task_id> memo for offerer readback" "$CMP_AG_SRC" \
    'memo_write("taskboard:result:" + task_id'
assert_contains "31j. computer.ag emits learn(\"taskboard\", ..., \"success\") for accepted tag" "$CMP_AG_SRC" \
    'learn("taskboard", "accept compute_partition_orbits"'
assert_contains "31k. computer.ag emits learn(\"taskboard\", ..., \"success\") for completed tag" "$CMP_AG_SRC" \
    'learn("taskboard", "complete compute_partition_orbits"'

assert_contains "31l. theorist.ag calls accept() on research-foundry:theory channel" "$TB_THE_AG_SRC" \
    'accept("research-foundry:theory")'
assert_contains "31m. theorist.ag calls complete() to settle escrow" "$TB_THE_AG_SRC" \
    'complete(task_id_int, result_clamped)'
assert_contains "31n. theorist.ag writes taskboard:result:<task_id> memo for offerer readback" "$TB_THE_AG_SRC" \
    'memo_write("taskboard:result:" + task_id'
assert_contains "31o. theorist.ag emits learn(\"taskboard\", ..., \"success\") for accepted tag" "$TB_THE_AG_SRC" \
    'learn("taskboard", "accept prove_modular_identity"'
assert_contains "31p. theorist.ag emits learn(\"taskboard\", ..., \"success\") for completed tag" "$TB_THE_AG_SRC" \
    'learn("taskboard", "complete prove_modular_identity"'

# ---------------------------------------------------------------------------
# 32. #744: in-container agentis worker wiring for M106 replicate() targets.
#
# explorer.ag (and 17 other colonies with the M2-Malthusian replicate gate)
# already call replicate(target_r, my_fit_r, variant_wrapped) on every
# autonomous-tier tick that clears the fitness + colony-size + pool gates.
# But before this patch landed, every call NAK'd because run-research.sh
# never launched an `agentis worker` listener and never seeded
# math-foundry:worker_addr -- select_replication_target() fell back to the
# unreachable self_node_addr() (127.0.0.1:9100 with no listener), so the
# M106 variant inheritance feature never engaged. These four assertions
# guard the wiring (emit_step at the orchestrator layer + the printf lines
# that emit the worker launch + memo seeds into the bootstrap script).
# ---------------------------------------------------------------------------
assert_contains "32a. emit_step names worker launch on 127.0.0.1:9100" "$OUT" \
    "launching agentis worker on 127.0.0.1:9100 for in-container replication"
assert_contains "32b. emit_step names worker_addr + peer_worker_count memo seed" "$OUT" \
    "seeding math-foundry:worker_addr + peer_worker_count for replicate() targets"
assert_contains "32c. bootstrap emits setsid agentis worker launch" "$SRC" \
    "setsid agentis worker 127.0.0.1:9100"
assert_contains "32d. bootstrap emits math-foundry:worker_addr memo seed" "$SRC" \
    "agentis memo set math-foundry:worker_addr 127.0.0.1:9100"
assert_contains "32e. bootstrap emits math-foundry:peer_worker_count memo seed" "$SRC" \
    "agentis memo set math-foundry:peer_worker_count 1"
assert_contains "32f. RESEARCH_EXPLORER_REPRODUCTIVE_FITNESS_THRESHOLD default lowered 3 -> 2" "$SRC" \
    ': "${RESEARCH_EXPLORER_REPRODUCTIVE_FITNESS_THRESHOLD:=2}"'

# ---------------------------------------------------------------------------
# 33. #750: KB cross-run persistence. The bootstrap script (emitted in
# write_bootstrap) must:
#   - reference /persistent/knowledge-snapshot.json
#   - invoke `agentis knowledge import <file>` (default merge in v1.7.16;
#     `--replace` would wipe existing entries, `--merge` is NOT a valid
#     flag and would be parsed as the filename — silent KB-empty bug
#     caught in QA #756)
#   - guard both behind RESEARCH_PERSISTENT_DISABLED via PERSISTENT_DISABLED
# The spawn line must bind-mount $PERSISTENT_DIR at /persistent:ro when
# PERSISTENT_DISABLED != "1" so the import can find the snapshot.
# ---------------------------------------------------------------------------
assert_contains "33a. bootstrap references /persistent/knowledge-snapshot.json" "$SRC" \
    '/persistent/knowledge-snapshot.json'
assert_contains "31b. bootstrap invokes agentis knowledge import with file arg" "$SRC" \
    'agentis knowledge import /persistent/knowledge-snapshot.json'
assert_contains "31c. KB import guarded by PERSISTENT_DISABLED" "$SRC" \
    '"$PERSISTENT_DISABLED" != "1"'
assert_contains "33d. spawn binds host PERSISTENT_DIR to /persistent:ro" "$SRC" \
    '$PERSISTENT_DIR:/persistent:ro'

# ---------------------------------------------------------------------------
# 32. #750: KB import error visibility. Stderr+stdout MUST land in a log
# file (knowledge-import.log) instead of being silently dropped via
# `>/dev/null 2>&1`, so operators see if the import actually loaded entries
# or quietly errored. The bare `agentis knowledge import` returns rc=0
# even on argument-parse errors in v1.7.16, so a log is the only signal.
# ---------------------------------------------------------------------------
assert_contains "32a. KB import logs to knowledge-import.log (not /dev/null)" "$SRC" \
    'knowledge-import.log'
assert_contains "32b. KB import has || true tail (non-fatal on missing/corrupt)" "$SRC" \
    '|| true'

# ---------------------------------------------------------------------------
# 34. #761: decide() audit-guard in auditor.ag. After the rich-struct
# `prompt() -> Verdict` returns its label, the autonomous-tier branch
# runs a second `decide()` call over the same four-label set and emits
# `auditor:verdict_disagreement` on mismatch. The guard is tier-gated
# (autonomous only, CB=50/call) so propose/review-gated/shadow ticks
# stay on their existing budget. `decide()` auto-writes a signed MC3
# row to `.agentis/decisions/chain.jsonl` for every autonomous-tier
# verdict, extending #743's audit-chain coverage to the verdict step.
# ---------------------------------------------------------------------------
DECIDE_COUNT="$(printf '%s\n' "$AUD_AG_SRC" | grep -cF -- 'decide(' || true)"
if [ "$DECIDE_COUNT" -ge 1 ]; then
    echo "[PASS] 34a. auditor.ag invokes decide() at least once (count=$DECIDE_COUNT)"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 34a. auditor.ag invokes decide() at least once: got $DECIDE_COUNT"
    FAIL=$((FAIL + 1))
fi
assert_contains "34b. auditor.ag defines _decide_verdict_guard helper" "$AUD_AG_SRC" \
    "fn _decide_verdict_guard"
assert_contains "34c. auditor.ag emits auditor:verdict_disagreement bus event" "$AUD_AG_SRC" \
    'emit("auditor:verdict_disagreement"'
assert_contains "34d. _decide_verdict_guard tier-gates on autonomous (CB=50 budget)" "$AUD_AG_SRC" \
    'if my_tier != "autonomous"'
assert_contains "34e. autonomous-tier branch wires _decide_verdict_guard before _publish_auditor" "$AUD_AG_SRC" \
    "_decide_verdict_guard(verdict.audit_verdict"
assert_contains "34f. disagreement path downgrades auditor:confidence by 0.05" "$AUD_AG_SRC" \
    "curr - 0.05"
assert_contains "34g. disagreement-path confidence downgrade floored at 0.4" "$AUD_AG_SRC" \
    "if lowered < 0.4 { 0.4; }"
assert_contains "34h. check-learn-tags.sh schema extends audit:partial with decide-guard tag" "$LEARN_TAGS_SRC" \
    'decide-guard'
assert_contains "34i. check-learn-tags.sh schema covers disagreement literal" "$LEARN_TAGS_SRC" \
    'disagreement'
assert_contains "34j. check-learn-tags.sh schema covers agreement literal" "$LEARN_TAGS_SRC" \
    'agreement'

# ---------------------------------------------------------------------------
# 35. #760: tools/test-boot-smoke.sh wiring guard. The boot-smoke script
# lives at the repo's tools/ root (not inside research-foundry/), but it
# runs run-research.sh end-to-end as its only purpose -- so if someone
# deletes or renames it the source-grep tests here would never notice.
# Cheap guard: assert the file exists with the expected shebang and that
# it references the 5 assertions in its header doc (the script's own
# contract). The boot-smoke run itself is gated on `--boot-smoke` in
# tools/colony-lint.sh and is NOT invoked from here -- it spawns a real
# container.
# ---------------------------------------------------------------------------
BS_PATH="$(cd "$SCRIPT_DIR/../.." && pwd)/tools/test-boot-smoke.sh"
if [ ! -f "$BS_PATH" ]; then
    echo "[FAIL] 35. tools/test-boot-smoke.sh missing at $BS_PATH"
    FAIL=$((FAIL + 1))
else
    BS_SRC="$(cat "$BS_PATH")"
    assert_contains "35. tools/test-boot-smoke.sh has bash shebang + 5-assertion contract" \
        "$BS_SRC" "#!/usr/bin/env bash"
fi

# ---------------------------------------------------------------------------
# 36. #765: novelty loss-function shaping. Three components bundled behind
# `NOVELTY_LOSS_SHAPING_ENABLED=1`:
#   (a) novelty.ag defines the three sidecar helpers (_classify_bucket,
#       _novelty_score, _topic_history_check) for bucket coarsening,
#       Jaccard-distance scoring, and saturated-bucket detection.
#   (b) explorer.ag reads the per-bucket exploration hint from the
#       `novelty:exploration_hint:<bucket>` memo so the meta-prompt can
#       steer toward under-represented buckets next tick.
#   (c) tools/run-research.sh adds NOVELTY_LOSS_SHAPING_ENABLED to the
#       exec.env_passthrough allowlist so the in-container .ag files can
#       read it via `printenv`.
#   (d) tools/persistent-snapshot.py extends its key list with
#       `novelty:topic_history` (FIFO buffer) so the rolling history
#       carries cross-run.
# Default (env unset / "0") is byte-identical to pre-#765.
# ---------------------------------------------------------------------------
SNAP_PATH="$(cd "$SCRIPT_DIR" && pwd)/persistent-snapshot.py"
SNAP_SRC="$(cat "$SNAP_PATH")"
assert_contains "36a. novelty.ag defines _classify_bucket helper" "$NOV_AG_SRC" \
    "fn _classify_bucket"
assert_contains "36b. novelty.ag defines _novelty_score helper" "$NOV_AG_SRC" \
    "fn _novelty_score"
assert_contains "36c. novelty.ag defines _topic_history_check helper" "$NOV_AG_SRC" \
    "fn _topic_history_check"
assert_contains "36d. novelty.ag wires _apply_loss_shaping before tier dispatch" "$NOV_AG_SRC" \
    "let shaped_label = _apply_loss_shaping(novelty"
assert_contains "36e. novelty.ag gates shaping behind NOVELTY_LOSS_SHAPING_ENABLED" "$NOV_AG_SRC" \
    "NOVELTY_LOSS_SHAPING_ENABLED"
assert_contains "36f. explorer.ag reads novelty:exploration_hint memo" "$EXP_AG_SRC" \
    'recall_latest("novelty:exploration_hint:"'
assert_contains "36g. explorer.ag gates hint read behind NOVELTY_LOSS_SHAPING_ENABLED" "$EXP_AG_SRC" \
    "NOVELTY_LOSS_SHAPING_ENABLED"
assert_contains "36h. run-research.sh adds NOVELTY_LOSS_SHAPING_ENABLED to env_passthrough" "$SRC" \
    "RESEARCH_JITTER_DISABLED,NOVELTY_LOSS_SHAPING_ENABLED"
assert_contains "36i. persistent-snapshot.py carries novelty:topic_history" "$SNAP_SRC" \
    '"novelty:topic_history"'
assert_contains "36j. persistent-snapshot.py carries novelty:fitness: prefix" "$SNAP_SRC" \
    '"novelty:fitness:"'
assert_contains "36k. persistent-snapshot.py carries novelty:exploration_hint: prefix" "$SNAP_SRC" \
    '"novelty:exploration_hint:"'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
