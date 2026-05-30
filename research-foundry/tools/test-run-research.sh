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
#  41a-j. #835 env-driven crystallizer verification knobs. Four
#      RESEARCH_CRYSTALLIZE_* env vars default to an empty sentinel
#      and emit their evolution.crystallize_* key only when set
#      (emit-only-when-overridden). 41i pins the conditional guard;
#      41j is a regression sentinel against an unconditional
#      emit-with-default that would break the byte-identical
#      production-config guarantee.
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
# 17. Phase 9 PR-C (#663) + #670 + #711 + #828 follow-up: per-colony
# RESEARCH_<COLONY>_REPLICAS env defaults exist for all 17 non-explorer
# colonies. #711 lowered the baseline from 2 to 1 to drop the federation
# peak request rate and clear the 9-stage cascade within the run window.
# #828 then bumped the four triage-tier colonies (NOTICER, NOVELTY, SKEPTIC,
# PRIOR_ADVOCATE) back to 3 so the M2-Malthusian replicate gate and the
# knowledge_market samples>1 density get non-trivial cross-replica selection
# pressure; the sequential preprint pipeline, the rate-limited searchers, and
# the single-writer AUDITOR stay at 1. (EXPLORER defaults to 5, checked
# separately.)
# ---------------------------------------------------------------------------
for c in NOTICER NOVELTY SKEPTIC PRIOR_ADVOCATE; do
    assert_contains "17. RESEARCH_${c}_REPLICAS defaults to 3 (#828)" "$SRC" \
        "\"\${RESEARCH_${c}_REPLICAS:=3}\""
done
for c in FORMULATOR VERIFIER \
         ARXIV_SEARCH OEIS_SEARCH GROUPPROPS_SEARCH SCHOLAR_SEARCH \
         AUDITOR \
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
assert_contains "24e. llm.tier.autonomous.cli_command_args = --model claude-sonnet-4-6" "$SRC" \
    'printf "llm.tier.autonomous.cli_command_args = --model claude-sonnet-4-6\\n"'

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
assert_contains "30a. check-learn-tags.sh schema covers lean_check:success" "$LEARN_TAGS_SRC" \
    '"lean_check:success")'
assert_contains "30b. check-learn-tags.sh schema covers lean_check:partial" "$LEARN_TAGS_SRC" \
    '"lean_check:partial")'
assert_contains "30c. check-learn-tags.sh schema covers lean_check:failure" "$LEARN_TAGS_SRC" \
    '"lean_check:failure")'

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

# ---------------------------------------------------------------------------
# 37. #768 PR-1: corpus inventory tool. corpus-inventory.py classifies
# every paper in data/papers/ through the same 5-bucket heuristic used
# by novelty.ag::_classify_bucket. check-corpus-balance.sh wraps it for
# CI consumption (--json mode) and reports any classified bucket >50%
# as a failure. These two files are a wiring-level pair -- the shell
# script invokes the python tool -- so guard them together.
# ---------------------------------------------------------------------------
INV_PATH="$SCRIPT_DIR/corpus-inventory.py"
BAL_PATH="$SCRIPT_DIR/check-corpus-balance.sh"
if [ ! -f "$INV_PATH" ]; then
    echo "[FAIL] 37a. research-foundry/tools/corpus-inventory.py missing at $INV_PATH"
    FAIL=$((FAIL + 1))
else
    INV_SRC="$(cat "$INV_PATH")"
    assert_contains "37a. corpus-inventory.py has python3 shebang" "$INV_SRC" \
        "#!/usr/bin/env python3"
    assert_contains "37b. corpus-inventory.py exposes --json flag" "$INV_SRC" \
        '"--json"'
    assert_contains "37c. corpus-inventory.py mirrors the 5 novelty.ag buckets" "$INV_SRC" \
        '"group_theory"'
fi
if [ ! -f "$BAL_PATH" ]; then
    echo "[FAIL] 37d. research-foundry/tools/check-corpus-balance.sh missing at $BAL_PATH"
    FAIL=$((FAIL + 1))
else
    BAL_SRC="$(cat "$BAL_PATH")"
    assert_contains "37d. check-corpus-balance.sh has bash shebang" "$BAL_SRC" \
        "#!/usr/bin/env bash"
    assert_contains "37e. check-corpus-balance.sh invokes corpus-inventory.py" "$BAL_SRC" \
        'corpus-inventory.py'
    assert_contains "37f. check-corpus-balance.sh consumes JSON mode" "$BAL_SRC" \
        '--json'
fi


# 38. #767: Malthusian death pressure -- aging-out + size-decrement bug fix.
#
# Per-colony `.ag` files publish `colony:cull_self_request:<pid>` when
# their `age_ticks` counter crosses RESEARCH_AGING_THRESHOLD; the
# cull-replicas.sh sidecar reads those requests, applies the
# RESEARCH_AGING_FITNESS_FLOOR check in Python, and emits a ledger row
# with `reason=aging`. Independently, the cull pipeline now decrements
# `colony-<name>:size` after `agentis daemon stop` and re-increments it
# after the respawn -- a load-bearing bug fix that lets the
# M2-Malthusian `size >= max_replicas` gate keep firing across cull
# cycles. The aging behaviour is opt-in via RESEARCH_AGING_ENABLED=1;
# the size-decrement bug fix is unconditional.
# ---------------------------------------------------------------------------
CULL_REPLICAS_PATH="$(cd "$SCRIPT_DIR/../.." && pwd)/tools/cull-replicas.sh"
CULL_REPLICAS_SRC="$(cat "$CULL_REPLICAS_PATH")"

assert_contains "38a. run-research.sh defaults RESEARCH_AGING_ENABLED to 0 (opt-in)" "$SRC" \
    ': "${RESEARCH_AGING_ENABLED:=0}"'
assert_contains "38b. run-research.sh defaults RESEARCH_AGING_THRESHOLD to 100" "$SRC" \
    ': "${RESEARCH_AGING_THRESHOLD:=100}"'
assert_contains "38c. run-research.sh defaults RESEARCH_AGING_FITNESS_FLOOR to 0.3" "$SRC" \
    ': "${RESEARCH_AGING_FITNESS_FLOOR:=0.3}"'
assert_contains "38d. env_passthrough names RESEARCH_AGING_ENABLED" "$SRC" \
    "RESEARCH_AGING_ENABLED"
assert_contains "38e. env_passthrough names RESEARCH_AGING_THRESHOLD" "$SRC" \
    "RESEARCH_AGING_THRESHOLD"
assert_contains "38f. env_passthrough names RESEARCH_AGING_FITNESS_FLOOR" "$SRC" \
    "RESEARCH_AGING_FITNESS_FLOOR"
assert_contains "38g. bootstrap seeds env:RESEARCH_AGING_ENABLED memo" "$SRC" \
    'agentis memo set env:RESEARCH_AGING_ENABLED'
assert_contains "38h. bootstrap seeds env:RESEARCH_AGING_THRESHOLD memo" "$SRC" \
    'agentis memo set env:RESEARCH_AGING_THRESHOLD'
assert_contains "38i. bootstrap seeds env:RESEARCH_AGING_FITNESS_FLOOR memo" "$SRC" \
    'agentis memo set env:RESEARCH_AGING_FITNESS_FLOOR'

# 38j-l. Every research-foundry .ag exposes the _age_tick_and_check
# helper AND calls it at tick() entry. 18 colonies total -- explorer,
# noticer, formulator, verifier, novelty, skeptic, arxiv-search, oeis-
# search, groupprops-search, scholar-search, prior_advocate, auditor,
# introducer, theorist, computer, editor, reviewer, submitter.
RF_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AG_FILES_FOUND=0
AG_HELPER_OK=0
AG_CALL_OK=0
for ag_path in \
    "$RF_ROOT/explorer/agents/explorer.ag" \
    "$RF_ROOT/noticer/agents/noticer.ag" \
    "$RF_ROOT/formulator/agents/formulator.ag" \
    "$RF_ROOT/verifier/agents/verifier.ag" \
    "$RF_ROOT/novelty/agents/novelty.ag" \
    "$RF_ROOT/skeptic/agents/skeptic.ag" \
    "$RF_ROOT/arxiv-search/agents/arxiv-search.ag" \
    "$RF_ROOT/oeis-search/agents/oeis-search.ag" \
    "$RF_ROOT/groupprops-search/agents/groupprops-search.ag" \
    "$RF_ROOT/scholar-search/agents/scholar-search.ag" \
    "$RF_ROOT/prior_advocate/agents/prior_advocate.ag" \
    "$RF_ROOT/auditor/agents/auditor.ag" \
    "$RF_ROOT/introducer/agents/introducer.ag" \
    "$RF_ROOT/theorist/agents/theorist.ag" \
    "$RF_ROOT/computer/agents/computer.ag" \
    "$RF_ROOT/editor/agents/editor.ag" \
    "$RF_ROOT/reviewer/agents/reviewer.ag" \
    "$RF_ROOT/submitter/agents/submitter.ag" \
; do
    if [ ! -f "$ag_path" ]; then
        continue
    fi
    AG_FILES_FOUND=$((AG_FILES_FOUND + 1))
    if grep -Fq "fn _age_tick_and_check(colony: string, self_pid: string) -> int" "$ag_path"; then
        AG_HELPER_OK=$((AG_HELPER_OK + 1))
    fi
    if grep -Fq "_age_tick_and_check(_colony_name, _self_pid)" "$ag_path"; then
        AG_CALL_OK=$((AG_CALL_OK + 1))
    fi
done

if [ "$AG_FILES_FOUND" -eq 18 ]; then
    echo "[PASS] 37j. enumerated all 18 research-foundry .ag files"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 37j. enumerated all 18 research-foundry .ag files (got $AG_FILES_FOUND)"
    FAIL=$((FAIL + 1))
fi

if [ "$AG_HELPER_OK" -eq 18 ]; then
    echo "[PASS] 37k. all 18 .ag files define _age_tick_and_check helper"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 37k. _age_tick_and_check helper missing in $((18 - AG_HELPER_OK)) of 18 .ag files"
    FAIL=$((FAIL + 1))
fi

if [ "$AG_CALL_OK" -eq 18 ]; then
    echo "[PASS] 37l. all 18 .ag tick() functions invoke _age_tick_and_check"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 37l. _age_tick_and_check call site missing in $((18 - AG_CALL_OK)) of 18 .ag tick() bodies"
    FAIL=$((FAIL + 1))
fi

# Spot-check one .ag for the request key the sidecar reads.
assert_contains "38m. explorer.ag publishes colony:cull_self_request:<pid> memo" \
    "$(cat "$RF_ROOT/explorer/agents/explorer.ag")" \
    'memo_write("colony:cull_self_request:"'

# 38n-t. cull-replicas.sh bug fix + aging scan.
assert_contains "38n. cull-replicas.sh decrements colony-<colony>:size after agentis daemon stop" \
    "$CULL_REPLICAS_SRC" \
    'agentis memo set "colony-$COLONY_NAME:size" "$NEW_SIZE"'
assert_contains "38o. cull-replicas.sh re-increments colony-<colony>:size after respawn (net-zero)" \
    "$CULL_REPLICAS_SRC" \
    'agentis memo set "colony-$COLONY_NAME:size" "$NEW_SIZE_POST"'
assert_contains "38p. cull-replicas.sh scans colony:cull_self_request:<pid> requests" \
    "$CULL_REPLICAS_SRC" \
    'colony:cull_self_request:'
assert_contains "38q. cull-replicas.sh reads env:RESEARCH_AGING_FITNESS_FLOOR memo" \
    "$CULL_REPLICAS_SRC" \
    'env:RESEARCH_AGING_FITNESS_FLOOR'
assert_contains "38r. cull-replicas.sh emits cull row with dynamic reason (aging vs fitness_bottom_pct)" \
    "$CULL_REPLICAS_SRC" \
    "reason = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else 'fitness_bottom_pct'"
assert_contains "38s. cull-replicas.sh respawn row carries kill_reason" \
    "$CULL_REPLICAS_SRC" \
    "'kill_reason': kill_reason"
assert_contains "38t. cull-replicas.sh clears colony:cull_self_request memo after acting" \
    "$CULL_REPLICAS_SRC" \
    'memo del "colony:cull_self_request:$pid"'

# 38u. emit_step surfaces aging-out enablement in the orchestrator log.
assert_contains "38u. orchestrator emit_step names death-pressure aging-out enablement" "$OUT" \
    "death-pressure aging-out"

# ---------------------------------------------------------------------------
# 39. #768 PR-2: _classify_bucket keyword-vocab expansion. The single-
# substring-on-bucket-name heuristic (29.2% match on the 24-paper corpus)
# is replaced by a per-bucket keyword list (~18 lemmas per bucket) drawn
# from arxiv abstracts. Parity contract spans four sites:
#   (a) novelty.ag::_classify_bucket
#   (b) explorer.ag::_classify_bucket_explorer
#   (c) tools/corpus-inventory.py::classify_bucket
#   (d) novelty.ag::_sparsest_bucket inline buckets=[...] (5-name list,
#       unchanged this PR -- guarded so future bucket additions diverge
#       from a single audit point).
# Plus the new `_classify_buckets_all` sibling + observational
# `novelty:bucket_tags:<claim_id>` memo write (single-bucket primary
# stays the load-bearing path; CSV tags are telemetry-only this PR).
# Acceptance: corpus-inventory --json reports unclassified < 30% on the
# unchanged 24-paper corpus (was 70.8% pre-PR).
# ---------------------------------------------------------------------------
NOV_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/novelty/agents/novelty.ag"
EXP_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/explorer/agents/explorer.ag"
INV_PATH="$SCRIPT_DIR/corpus-inventory.py"

# Sample keywords picked from each bucket vocabulary -- presence
# everywhere proves the four parity sites agree on the post-PR-2 list.
# Each (bucket-name, sample-keyword) pair is grepped across the three
# active sites (novelty.ag, explorer.ag, corpus-inventory.py); the
# _sparsest_bucket guard (39o) covers site (d).
for site_label_path in "novelty.ag:$NOV_PATH" "explorer.ag:$EXP_PATH" "corpus-inventory.py:$INV_PATH"; do
    site_label="${site_label_path%%:*}"
    site_path="${site_label_path#*:}"
    SITE_SRC="$(cat "$site_path")"
    # Substring (not quoted) -- .ag stores keywords as escaped \"foo\"
    # inside the python shell-out, the .py file stores them as bare "foo"
    # entries in a dict literal. Bare substring matches both.
    assert_contains "39a/$site_label has group_theory bucket"   "$SITE_SRC" 'group_theory'
    assert_contains "39b/$site_label has combinatorics bucket"  "$SITE_SRC" 'combinatorics'
    assert_contains "39c/$site_label has number_theory bucket"  "$SITE_SRC" 'number_theory'
    assert_contains "39d/$site_label has probability bucket"    "$SITE_SRC" 'probability'
    assert_contains "39e/$site_label has algebra bucket"        "$SITE_SRC" 'algebra'
    assert_contains "39f/$site_label has group_theory keyword sylow"      "$SITE_SRC" 'sylow'
    assert_contains "39g/$site_label has combinatorics keyword hypergraph" "$SITE_SRC" 'hypergraph'
    assert_contains "39h/$site_label has number_theory keyword hecke"      "$SITE_SRC" 'hecke'
    assert_contains "39i/$site_label has probability keyword martingale"   "$SITE_SRC" 'martingale'
    assert_contains "39j/$site_label has algebra keyword cohomology"       "$SITE_SRC" 'cohomology'
done

NOV_SRC_39="$(cat "$NOV_PATH")"
assert_contains "39k. novelty.ag defines _classify_buckets_all" "$NOV_SRC_39" \
    "fn _classify_buckets_all"
assert_contains "39l. novelty.ag writes novelty:bucket_tags memo" "$NOV_SRC_39" \
    'memo_write("novelty:bucket_tags:"'
assert_contains "39m. novelty.ag calls _classify_buckets_all from loss shaping" "$NOV_SRC_39" \
    '_classify_buckets_all(topic_label)'
assert_contains "39n. _classify_bucket lowercases haystack (case-insensitive)" "$NOV_SRC_39" \
    'argv[1].lower()'
assert_contains "39o. _sparsest_bucket still pins the 5 canonical buckets" "$NOV_SRC_39" \
    'buckets=[\"group_theory\",\"combinatorics\",\"number_theory\",\"probability\",\"algebra\"]'

# Live acceptance: run the inventory and verify unclassified < 30% on
# the current 24-paper corpus. Skips if python3 is missing (also covered
# by the inventory tool's own header check).
if command -v python3 >/dev/null 2>&1; then
    PAPERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/data/papers"
    if [ -d "$PAPERS_DIR" ]; then
        UNCL_PCT="$(python3 "$INV_PATH" --json 2>/dev/null \
            | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    t=d.get("total") or 0
    u=d.get("unclassified") or 0
    print(100.0*u/t if t else 100.0)
except Exception:
    print(100.0)')"
        UNCL_INT="$(printf '%.0f' "$UNCL_PCT" 2>/dev/null || echo 100)"
        if [ "$UNCL_INT" -lt 30 ]; then
            echo "[PASS] 39p. corpus-inventory unclassified < 30% (got ${UNCL_PCT}%)"
            PASS=$((PASS + 1))
        else
            echo "[FAIL] 39p. corpus-inventory unclassified >= 30% (got ${UNCL_PCT}%)"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "[SKIP] 39p. corpus-inventory live check (papers dir missing)"
    fi
else
    echo "[SKIP] 39p. corpus-inventory live check (python3 missing)"
fi

# ---------------------------------------------------------------------------
# 40. #825: per-tier LLM backend routing. Additive over #746's per-tier
# `cli_command_args` lines: each tier also gets a `backend = <name>`
# line so the highest-volume / lowest-stakes work (shadow) routes to a
# cheap OpenRouter-hosted Qwen model while terminal decisions
# (autonomous) stay on the claude backend (model claude-sonnet-4-6).
# Plus per-agent overrides for the
# three highest-stake terminal-writers (auditor, theorist, submitter)
# that pin claude-opus-4-8 regardless of tier. agentis-core's
# Config::scoped().flatten() resolves per-agent -> per-tier -> top-level
# at each prompt() call.
# ---------------------------------------------------------------------------
assert_contains "40a. llm.tier.shadow.backend = openai" "$SRC" \
    'printf "llm.tier.shadow.backend = openai\\n"'
assert_contains "40b. llm.tier.propose.backend = claude" "$SRC" \
    'printf "llm.tier.propose.backend = claude\\n"'
assert_contains "40c. llm.tier.review-gated.backend = claude" "$SRC" \
    'printf "llm.tier.review-gated.backend = claude\\n"'
assert_contains "40d. llm.tier.autonomous.backend = claude" "$SRC" \
    'printf "llm.tier.autonomous.backend = claude\\n"'
assert_contains "40e. shadow-tier openai endpoint emitted" "$SRC" \
    'printf "llm.tier.shadow.openai.endpoint = %s\\n"'
assert_contains "40f. shadow-tier openai model emitted" "$SRC" \
    'printf "llm.tier.shadow.openai.model = %s\\n"'
assert_contains "40g. shadow-tier openai api_key_env emitted" "$SRC" \
    'printf "llm.tier.shadow.openai.api_key_env = %s\\n"'
assert_contains "40h. agents.auditor.llm.backend = claude" "$SRC" \
    'printf "agents.auditor.llm.backend = claude\\n"'
assert_contains "40i. agents.auditor.llm pins claude-opus-4-8" "$SRC" \
    'printf "agents.auditor.llm.cli_command_args = --model claude-opus-4-8\\n"'
assert_contains "40j. agents.theorist.llm.backend = claude" "$SRC" \
    'printf "agents.theorist.llm.backend = claude\\n"'
assert_contains "40k. agents.theorist.llm pins claude-opus-4-8" "$SRC" \
    'printf "agents.theorist.llm.cli_command_args = --model claude-opus-4-8\\n"'
assert_contains "40l. agents.submitter.llm.backend = claude" "$SRC" \
    'printf "agents.submitter.llm.backend = claude\\n"'
assert_contains "40m. agents.submitter.llm pins claude-opus-4-8" "$SRC" \
    'printf "agents.submitter.llm.cli_command_args = --model claude-opus-4-8\\n"'

# ---------------------------------------------------------------------------
# 40n-o. #825 follow-up: RESEARCH_PER_TIER_ROUTING=0 opt-out toggle. When
# set, the per-tier backend block + per-agent overrides must be skipped
# (the bootstrap then falls back to top-level llm.* defaults plus
# #746's per-tier cli_command_args lines -- byte-identical to pre-#825).
# The opt-out works by gating the entire per-tier block in run-research.sh
# at the bootstrap-emit site. Dry-run mode short-circuits write_bootstrap
# before emitting the heredoc, so the runtime-behaviour assertions
# extract the relevant block from the source via awk to verify the gate
# wraps both the per-tier backend lines and the per-agent overrides.
# ---------------------------------------------------------------------------
assert_contains "40n. RESEARCH_PER_TIER_ROUTING gate present in source" "$SRC" \
    '"${RESEARCH_PER_TIER_ROUTING:-1}" = "1"'
assert_contains "40o. RESEARCH_PER_TIER_ROUTING documented in header" "$SRC" \
    "RESEARCH_PER_TIER_ROUTING"

# Extract the lines between the bootstrap-emit gate-open `if [
# "${RESEARCH_PER_TIER_ROUTING:-1}" = "1" ]; then` (the SECOND
# occurrence in run-research.sh; the first is the pre-flight warning
# check ABOVE the emit_step block, which has different scope) and the
# corresponding closing `fi`. Then assert the extracted block contains
# the representative per-tier + per-agent lines.
GATED_BLOCK="$(awk '
    /"\$\{RESEARCH_PER_TIER_ROUTING:-1\}" = "1"/ {
        seen++
        if (seen == 2) { in_block=1 }
        next
    }
    in_block && /^[[:space:]]*fi[[:space:]]*$/ { exit }
    in_block { print }
' "$ORCH")"
assert_contains "40p. opt-out gate wraps llm.tier.shadow.backend line" "$GATED_BLOCK" \
    'printf "llm.tier.shadow.backend = openai\\n"'
assert_contains "40q. opt-out gate wraps agents.auditor.llm.backend line" "$GATED_BLOCK" \
    'printf "agents.auditor.llm.backend = claude\\n"'
assert_contains "40r. opt-out gate wraps agents.submitter.llm.cli_command_args" "$GATED_BLOCK" \
    'printf "agents.submitter.llm.cli_command_args = --model claude-opus-4-8\\n"'
# Sanity check: #746's per-tier cli_command_args lines live OUTSIDE the
# gated block (they come from the older #746 block above the #825 gate).
# Their absence inside GATED_BLOCK proves the gate scope is correct.
assert_not_contains "40s. #746 llm.tier.autonomous.cli_command_args lives outside the #825 gate" \
    "$GATED_BLOCK" 'printf "llm.tier.autonomous.cli_command_args = --model claude-sonnet-4-6\\n"'

# ---------------------------------------------------------------------------
# 40t-v. #825 follow-up: when OPENROUTER_API_KEY env is set, the
# default LLM_BACKEND=claude podman invocation must thread it into the
# container so shadow-tier prompt() can read it. When unset, the spawn
# command stays unchanged (operator may have opted out via
# RESEARCH_PER_TIER_ROUTING=0 or just doesn't use per-tier routing). The
# pre-flight check at validate_env_or_die surfaces a warning (not a hard
# fail) under LLM_BACKEND=claude + RESEARCH_PER_TIER_ROUTING=1 + missing
# key, so operators get an early signal instead of an opaque shadow-tier
# 401 once an agent's confidence dips into shadow.
# ---------------------------------------------------------------------------
assert_contains "40t. claude-branch podman spawn threads OPENROUTER_API_KEY conditionally" "$SRC" \
    'openai_key_env_flag=" -e $OPENAI_KEY_ENV='
assert_contains "40u. pre-flight warning string present in source" "$SRC" \
    "per-tier shadow routing won't work"
assert_contains "40v. pre-flight check covers LLM_BACKEND=claude + RESEARCH_PER_TIER_ROUTING=1" "$SRC" \
    'if [ "$LLM_BACKEND" = "claude" ] && [ "${RESEARCH_PER_TIER_ROUTING:-1}" = "1" ]'

# Live snapshot: when OPENROUTER_API_KEY is set in the env, the emitted
# claude-backend spawn line carries `-e OPENROUTER_API_KEY=...`.
WITH_KEY_OUT="$(RESEARCH_DRY_RUN=1 \
                OPENROUTER_API_KEY=test-or-key-xxxxxxxxxxxx \
                RESEARCH_TOPICS=number_theory,combinatorics \
                RESEARCH_PAPER_CORPUS=/tmp/research-corpus \
                RESEARCH_TICK_INTERVAL_S=30 \
                RESEARCH_TOTAL_TICKS=12 \
                RESEARCH_DAEMONS_PER_COLONY=2 \
                RESEARCH_HOLD_PERIOD=5 \
                RESEARCH_RUN_DIR="$WORK_DIR/run-with-key" \
                bash "$ORCH" 2>&1)" || true
assert_contains "40w. OPENROUTER_API_KEY=set => -e OPENROUTER_API_KEY in spawn" "$WITH_KEY_OUT" \
    'podman run -d --replace --name research-foundry-laptop -e OPENROUTER_API_KEY='

# Live snapshot: when OPENROUTER_API_KEY is unset, the pre-flight warning
# fires and the spawn line does NOT carry `-e OPENROUTER_API_KEY=`.
WITHOUT_KEY_OUT="$(env -u OPENROUTER_API_KEY \
                   RESEARCH_DRY_RUN=1 \
                   RESEARCH_TOPICS=number_theory,combinatorics \
                   RESEARCH_PAPER_CORPUS=/tmp/research-corpus \
                   RESEARCH_TICK_INTERVAL_S=30 \
                   RESEARCH_TOTAL_TICKS=12 \
                   RESEARCH_DAEMONS_PER_COLONY=2 \
                   RESEARCH_HOLD_PERIOD=5 \
                   RESEARCH_RUN_DIR="$WORK_DIR/run-without-key" \
                   bash "$ORCH" 2>&1)" || true
assert_contains "40x. unset OPENROUTER_API_KEY surfaces pre-flight warning" "$WITHOUT_KEY_OUT" \
    "per-tier shadow routing won't work"
assert_not_contains "40y. unset OPENROUTER_API_KEY => no -e flag in spawn" "$WITHOUT_KEY_OUT" \
    '-e OPENROUTER_API_KEY='

# 41. #835: env-driven crystallizer verification config knobs. The four
# RESEARCH_CRYSTALLIZE_* knobs default to an empty sentinel and emit their
# evolution.crystallize_* key into the container .agentis/config ONLY when
# set (emit-only-when-overridden), so an unset production run emits none of
# them and the generated config stays byte-identical to today. Source-level
# assertions are the right shape: the bootstrap printf lines run inside the
# container-side generated script and never reach dry-run stdout (same
# precedent as test 40g's conditional shadow-tier key). Tests 41i/41j pin
# the conditional emit strategy so a future implementer cannot silently flip
# to emit-always-with-default and break the byte-identical guarantee.
assert_contains "41a. emits evolution.crystallize_interval printf" "$SRC" \
    'printf "evolution.crystallize_interval = %s\\n"'
assert_contains "41b. emits evolution.crystallize_compact_interval printf" "$SRC" \
    'printf "evolution.crystallize_compact_interval = %s\\n"'
assert_contains "41c. emits evolution.crystallize_peer_fetch_enabled printf" "$SRC" \
    'printf "evolution.crystallize_peer_fetch_enabled = true\\n"'
assert_contains "41d. emits evolution.crystallize_allow_cross_daemon printf" "$SRC" \
    'printf "evolution.crystallize_allow_cross_daemon = true\\n"'
assert_contains "41e. CRYSTALLIZE_INTERVAL defaults to empty sentinel" "$SRC" \
    'CRYSTALLIZE_INTERVAL="${RESEARCH_CRYSTALLIZE_INTERVAL:-}"'
assert_contains "41f. CRYSTALLIZE_COMPACT_INTERVAL defaults to empty sentinel" "$SRC" \
    'CRYSTALLIZE_COMPACT_INTERVAL="${RESEARCH_CRYSTALLIZE_COMPACT_INTERVAL:-}"'
assert_contains "41g. CRYSTALLIZE_PEER_FETCH defaults to empty sentinel" "$SRC" \
    'CRYSTALLIZE_PEER_FETCH="${RESEARCH_CRYSTALLIZE_PEER_FETCH:-}"'
assert_contains "41h. CRYSTALLIZE_ALLOW_CROSS_DAEMON defaults to empty sentinel" "$SRC" \
    'CRYSTALLIZE_ALLOW_CROSS_DAEMON="${RESEARCH_CRYSTALLIZE_ALLOW_CROSS_DAEMON:-}"'
# 41i: the interval emit is conditional, not always-on (guard co-located).
assert_contains "41i. crystallize_interval emit is wrapped in a non-empty guard" "$SRC" \
    'if [ -n "$CRYSTALLIZE_INTERVAL" ]; then'
# 41j: regression sentinel -- no unconditional emit-with-default line. If
# this ever appears, the production .agentis/config is no longer byte-
# identical to a pre-#835 run.
assert_not_contains "41j. no unconditional crystallize_interval = 100 emit" "$SRC" \
    'printf "evolution.crystallize_interval = 100\\n"'

# ---------------------------------------------------------------------------
# 42. #840: cache-coherence gate inside build_image(). The cached-image
# reuse path must still print the `podman image exists` gate (so operators
# see what is being checked). Any build invocation -- cache miss, forced
# rebuild via RESEARCH_FORCE_REBUILD=1, or live version-mismatch rebuild
# in the non-dry-run path -- must pin `--build-arg AGENTIS_VERSION=` so
# the rebuild is reproducible. The RESEARCH_FORCE_REBUILD=1 dry-run
# variant must surface both `podman rmi -f` and the pinned build command
# in the transcript.
# ---------------------------------------------------------------------------
assert_contains "42a. build_image dry-run keeps the podman image exists gate" "$OUT" \
    "podman image exists research-foundry:latest"
assert_contains "42b. dry-run build invocation pins --build-arg AGENTIS_VERSION=" "$OUT" \
    "--build-arg AGENTIS_VERSION="

FORCE_REBUILD_OUT="$(RESEARCH_DRY_RUN=1 RESEARCH_FORCE_REBUILD=1 \
                     RESEARCH_RUN_DIR="$WORK_DIR/run-force-rebuild" \
                     bash "$ORCH" 2>&1)"
assert_contains "42c. RESEARCH_FORCE_REBUILD=1 dry-run emits podman rmi -f" "$FORCE_REBUILD_OUT" \
    "podman rmi -f research-foundry:latest"
assert_contains "42d. RESEARCH_FORCE_REBUILD=1 dry-run emits pinned build command" "$FORCE_REBUILD_OUT" \
    "podman build --build-arg AGENTIS_VERSION="

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
