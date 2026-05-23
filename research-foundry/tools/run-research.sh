#!/bin/bash
# run-research.sh -- end-to-end research orchestrator for the
# research-foundry federation (#638).
#
# Consolidates the three retired orchestrators (run-foundry.sh,
# run-auditor.sh, run-preprint.sh) into a single script that drives
# all 18 colonies in one container. Cross-federation memo recall is
# eliminated -- the 9-10-tick cascade through the 17 downstream
# daemons happens inside the merged container because all daemons
# share `.agentis/`. Novelty + auditor agents write `claim:*:tick-N`
# keys directly on positive verdict, so each downstream consumer
# reads its upstream colleague's memo at the next tick without any
# cross-fed JSONL reconstruction.
#
# Architectural shape mirrors the three retired orchestrators
# (emit_step helper, run dir under research-foundry/runs/<ts>/,
# `podman run --replace` idiom, hermetic .agentis/config). The
# tick-stream payload only seeds the `explorer` daemon; the
# downstream cascade proceeds without orchestrator participation.
#
# Per-role model split + idle-skip flags (#726, #729):
#   The 18 colonies run a deliberate two-tier mix: 8 opus colonies
#   (explorer, formulator, novelty, prior_advocate, verifier,
#   auditor, theorist, editor) plus 10 sonnet colonies (noticer,
#   skeptic, 4x search adapters, introducer, computer, reviewer,
#   submitter). The opus tier covers every role whose prompt either
#   gates a downstream cascade verdict or carries the ~200KB
#   research context (paper abstracts + cross-references + verifier
#   reports + prior_advocate output); the sonnet tier covers the
#   mechanical / parsing / scripted roles where output quality is
#   adequate at ~5x lower per-call cost. Every per-role pick is
#   env-overridable via RESEARCH_<ROLE>_CLAUDE_MODEL so any one role
#   can be flipped at runtime without a code change.
#
#   This split matches the Run #14 baseline. #726 originally flipped
#   5 of the opus colonies (explorer, formulator, novelty,
#   prior_advocate, editor) to sonnet for cost; #729 reverts that
#   after Run #15 forensic showed a structural regression -- prompt
#   round-trip on the heavy-context loop exceeded the v1.7.14 120s
#   prompt timeout, ~50% of explorer ticks timed out before writing
#   a claim, and the cascade died before editor reached PDF compile
#   (discovery claims 136 -> 44, PDF preprints 6 -> 0). Operator
#   rule "Na sonnet nedegraduj -- quality nesmi trpet" empirically
#   validated. The right long-term substrate for cost-aware routing
#   is agentis-core's per-tier LLM override (#652, v1.7.15) which
#   routes by confidence tier rather than static per-role pin.
#
#   Every daemon spawn carries --skip-prompt-after-idle and
#   --skip-prompt-without-input. The former elides prompt() on two
#   consecutive no-op ticks (saves 30-50% of LLM calls on listen-
#   driven roles like editor, submitter, theorist, computer,
#   reviewer that idle between upstream events). The latter is a
#   forward-compat no-op today -- no research-foundry .ag declares
#   has_input() yet -- but ships so any future has_input() addition
#   activates the skip path without re-spawning. #729 keeps both
#   flags untouched: Run #15 heartbeat counters showed they never
#   fired (no has_input() declarations yet) so they carried no
#   measurable downside.
#
# Env vars (all optional; defaults shown):
#   RESEARCH_TOPICS              Comma-separated topic labels rotated
#                                across explorer ticks.
#                                Default: number_theory,combinatorics,abstract_algebra,graph_theory
#   RESEARCH_PAPER_CORPUS        Path to cached per-topic JSON corpora.
#                                Default: research-foundry/data/papers
#   RESEARCH_TICK_INTERVAL_S     Seconds between orchestrator ticks.
#                                Default 120 (median of the three
#                                retired feds' 60/120/180s defaults).
#   RESEARCH_TOTAL_TICKS         Number of ticks to drive. Default 75
#                                (#718: bumped from 30 so the default
#                                run is long enough to clear the
#                                auto-promote prereq gate). At the
#                                default 120s tick interval that
#                                yields a 2.5h budget. Auditor's
#                                empirical 12 acting-rows/h rate in
#                                Run #14 lands exactly at the
#                                min_entries=30 threshold; verifier's
#                                20/h clears it with margin. Editor's
#                                9/h still falls short at 2.5h, which
#                                is acceptable -- editor sits
#                                downstream of theorist and promotes
#                                on a slower cycle anyway.
#   RESEARCH_DAEMONS_PER_COLONY  Per-colony daemon count for the math
#                                pipeline (explorer/noticer/formulator/
#                                verifier/novelty). Phase 1 = 1.
#   RESEARCH_HOLD_PERIOD         Ticks before explorer settles a verdict.
#                                Default 4
#   RESEARCH_LLM_BACKEND         llm.backend value injected into hermetic
#                                config. Default: claude
#   RESEARCH_OPENAI_ENDPOINT     Chat-completions URL.
#                                Default: https://openrouter.ai/api/v1/chat/completions
#   RESEARCH_OPENAI_MODEL        Model id when backend=openai.
#                                Default: qwen/qwen3-coder-30b-a3b-instruct
#   RESEARCH_OPENAI_KEY_ENV      Env var carrying the LLM API key.
#                                Default: OPENROUTER_API_KEY
#   RESEARCH_OPENAI_TIMEOUT_MS   Per-request timeout (ms). Default: 180000
#   RESEARCH_CLAUDE_MODEL        Default model for claude backend.
#                                Default: opus
#   RESEARCH_CLAUDE_EFFORT       Default effort. Default: medium
#   RESEARCH_HOST_CLAUDE_DIR     Host path bind-mounted to /root/.claude.
#                                Default: $HOME/.claude
#   RESEARCH_AUDITOR_CONFIDENCE_FLOOR
#                                Quality-gate floor for auditor verdicts
#                                surfaced in run-meta. Default 0.7
#   RESEARCH_AUTHOR_CONFIG       Path to authors.toml (for submitter
#                                colony's arxiv-metadata.json).
#                                Default: <fed>/config/authors.toml
#   RESEARCH_DAEMON_CB_PER_TICK  Per-tick CB replenishment (hermetic
#                                .agentis/config daemon.cb_per_tick).
#                                Default 2000 (mirrors trading-binance
#                                #579). Hermetic memo cap also bumped
#                                from 500 to 50000 (mirrors #587).
#   RESEARCH_DAEMON_HEARTBEAT_MS Watchdog heartbeat (ms). Default
#                                1800000 (mirrors trading-binance #583).
#   RESEARCH_LATEXMK_MAX_PASSES  Max latexmk attempts inside editor.ag.
#                                Default 3
#   RESEARCH_DRY_RUN             1 = emit_step the plan, skip podman.
#                                Default: "" (real run).
#   RESEARCH_RUN_DIR             Output dir override. Default: auto-
#                                timestamped under research-foundry/runs/
#   RESEARCH_PERSISTENT_DIR      Per-federation persistent dir written at
#                                run-end (Phase 5 PR-A of #626) and read
#                                at bootstrap (Phase 5 PR-B of #626).
#                                Default: <fed-dir>/persistent. PR-B
#                                restores `<colony>:confidence` from
#                                `memo-snapshot.json` (falls back to
#                                0.7 if missing) and biases the 5
#                                explorer specialty slots from
#                                `fittest_specialties.json` if present
#                                (falls back to round-robin if missing).
#                                PR-C will aggregate cross-run fitness
#                                and write `fittest_specialties.json`.
#   RESEARCH_PERSISTENT_DISABLED 1 = skip both the run-end memo snapshot
#                                AND the bootstrap hot-start restore.
#                                Default 0 (both on by default).
#   RESEARCH_CROSS_RUN_WINDOW    Number of past run-history.jsonl records
#                                the cross-run aggregator (Phase 5 PR-C of
#                                #626) weights when deriving
#                                fittest_specialties.json. Default 5.
#                                Exponential decay factor is fixed at 0.7
#                                (oldest run in window gets weight
#                                0.7^(N-1); most recent gets 1.0).
#   RESEARCH_IMAGE_TAG           Container image tag built from
#                                Containerfile.research.
#                                Default: research-foundry:latest
#   RESEARCH_ARXIV_GATEWAY       arXiv submission email. Default:
#                                submit@arxiv.org
#   RESEARCH_ARXIV_FROM          From: header for SMTP. Default: empty
#                                (read from authors.toml inside
#                                submitter.ag).
#   RESEARCH_SMTP_HOST           SMTP relay host. Default: localhost
#   RESEARCH_SMTP_PORT           SMTP relay port. Default: 25
#   RESEARCH_FITNESS_REWARD_NOVEL_PER_TICK
#                                Per-tick fitness reward when novelty
#                                referee returns NOVEL. Default: 2
#   RESEARCH_FITNESS_PENALTY_NOT_NOVEL_PER_TICK
#                                Per-tick fitness penalty when novelty
#                                referee returns NOT_NOVEL. Default: 1
#   RESEARCH_EXPLORER_PROMPT_EVOLUTION_THRESHOLD
#                                NOT_NOVEL streak required before
#                                explorer.ag rewrites its prompt body
#                                (M98 v3). Default: 3
#   RESEARCH_EXPLORER_PROMPT_GEN_CAP
#                                Per-lineage generation cap before reset.
#                                Default: 10
#   RESEARCH_EXPLORER_PROMPT_MAX_BYTES
#                                Hard byte cap on rewritten prompt bodies.
#                                Default: 8192
#   RESEARCH_EXPLORER_PROMPT_LEVENSHTEIN_FLOOR
#                                Minimum dissimilarity percent for a
#                                rewrite to be accepted. Default: 20
#   RESEARCH_AUTO_PROMOTE        1 enable auto-promote sidecar
#                                (default), 0 disable.
#   RESEARCH_AUTO_PROMOTE_INTERVAL_S
#                                Seconds between sidecar ticks.
#                                Default 300.
#   RESEARCH_EXPLORER_REPLICAS
#                                Initial explorer replica count seeded by
#                                the bootstrap script. Each replica claims
#                                a distinct mathematical specialty from a
#                                fixed pool. Default 5.
#   RESEARCH_EXPLORER_MAX_REPLICAS
#                                Hard cap on the explorer colony size used
#                                by the M2-Malthusian replicate gate
#                                (colony-explorer:max_replicas). Default 8.
#   RESEARCH_EXPLORER_POOL
#                                Initial colony-explorer:pool seeded for
#                                the M2-Malthusian replicate gate.
#                                Default 5000.
#   RESEARCH_EXPLORER_REPRODUCTIVE_FITNESS_THRESHOLD
#                                Per-pid fitness threshold above which the
#                                replicate gate fires (memo key
#                                explorer:reproductive_fitness_threshold).
#                                Default 3 (#679: lowered from 10 so the
#                                gate fires within the default 30-tick
#                                run, engaging birth/death lifecycle
#                                without operator opt-in).
#   RESEARCH_CULL_ENABLED        1 enable Phase 3 PR 3 cull cycle, 0
#                                disable. Default 1 (#679: lifecycle on
#                                by default so the 30-tick default run
#                                produces at least one cull event).
#   RESEARCH_CULL_INTERVAL_TICKS Sidecar ticks between cull invocations.
#                                Default 5 (#679: lowered from 20 so a
#                                30-tick default run sees ~6 cull
#                                cycles instead of 1).
#   RESEARCH_CULL_BOTTOM_PCT     Fraction of explorers culled per cycle.
#                                Default 0.2 (bottom 20% by fitness).
#   RESEARCH_CULL_MIN_EXPLORERS  Skip cull entirely when total explorer
#                                count falls below this floor. Default 3.
#   RESEARCH_CULL_MIN_ACTING     Skip per-row cull when explorer's
#                                entries_acting is below this floor.
#                                Default 3 (#679: lowered from 10 so
#                                short default runs accumulate enough
#                                acting rows to be eligible for cull).
#   RESEARCH_CULL_COLONIES       Comma-separated list of colony names
#                                the cull cycle iterates over per
#                                tick. Phase 9 PR-C (#663) expands the
#                                default to all 18 colonies now that
#                                every non-explorer colony has its
#                                replicate gate wired up.
#   RESEARCH_<COLONY>_REPLICAS   Initial replica count for each of the
#                                17 non-explorer colonies (Phase 9
#                                PR-B of #663). Phase 9 PR-C flips
#                                defaults to 3 across the board so the
#                                M2-Malthusian replicate gate inside
#                                each .ag can fire. Container shape:
#                                17 colonies x 3 + 5 explorers = 56
#                                daemons total.
#   RESEARCH_<COLONY>_MAX_REPLICAS / _POOL / _REPRODUCTIVE_FITNESS_THRESHOLD
#                                Per-colony M2-Malthusian replicate
#                                gate seeds; defaults mirror the
#                                explorer values.
#
# Flags:
#   --dry-run    Same as RESEARCH_DRY_RUN=1.
#
# Output layout (under research-foundry/runs/<YYYYMMDDTHHMMSSZ>/):
#   orchestrator.log              orchestrator's own log
#   run-meta.json                 config dump
#   discovery-ledger.jsonl        math pipeline rows (novelty.ag)
#   audit-ledger.jsonl            claim-auditor rows (auditor.ag)
#   preprint-ledger.jsonl         preprint pipeline rows (submitter.ag)
#   replication-ledger.jsonl      explorer M2-Malthusian audit trail
#                                 (spawn / replicate rows)
#   laptop-node/
#     bootstrap.sh                container bootstrap (real run only)
#     .agentis/
#       sandbox/                  per-daemon scratch
#       logs/
#       spend/
#     preprints/<claim-id>/       per-claim main.tex / main.pdf /
#                                 reproducibility.* / arxiv-metadata.json /
#                                 submission.tar.gz
#
# Exit codes:
#   0   research run completed (or dry-run plan emitted)
#   1   prerequisite missing (podman, python3 outside dry-run)
#   2   invalid env (e.g. empty topic list)
#   3   paper corpus loading failed
#   4   container spawn failed

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"

# --- Argument parsing ---
DRY_RUN="${RESEARCH_DRY_RUN:-0}"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$SCRIPT_PATH"
            exit 0
            ;;
        *)
            echo "run-research: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# --- Env-var defaults ---
TOPICS_RAW="${RESEARCH_TOPICS-number_theory,combinatorics,abstract_algebra,graph_theory}"
PAPER_CORPUS_RAW="${RESEARCH_PAPER_CORPUS:-$FED_DIR/data/papers}"
TICK_INTERVAL_S="${RESEARCH_TICK_INTERVAL_S:-120}"
TOTAL_TICKS="${RESEARCH_TOTAL_TICKS:-75}"
DAEMONS_PER_COLONY="${RESEARCH_DAEMONS_PER_COLONY:-1}"
HOLD_PERIOD="${RESEARCH_HOLD_PERIOD:-4}"
LLM_BACKEND="${RESEARCH_LLM_BACKEND:-claude}"
OPENAI_ENDPOINT="${RESEARCH_OPENAI_ENDPOINT:-https://openrouter.ai/api/v1/chat/completions}"
OPENAI_MODEL="${RESEARCH_OPENAI_MODEL:-qwen/qwen3-coder-30b-a3b-instruct}"
OPENAI_KEY_ENV="${RESEARCH_OPENAI_KEY_ENV:-OPENROUTER_API_KEY}"
OPENAI_TIMEOUT_MS="${RESEARCH_OPENAI_TIMEOUT_MS:-180000}"
CLAUDE_MODEL="${RESEARCH_CLAUDE_MODEL:-opus}"
CLAUDE_EFFORT="${RESEARCH_CLAUDE_EFFORT:-medium}"
HOST_CLAUDE_DIR="${RESEARCH_HOST_CLAUDE_DIR:-$HOME/.claude}"
CONFIDENCE_FLOOR="${RESEARCH_AUDITOR_CONFIDENCE_FLOOR:-0.7}"
AUTHOR_CONFIG="${RESEARCH_AUTHOR_CONFIG:-$FED_DIR/config/authors.toml}"
DAEMON_CB_PER_TICK="${RESEARCH_DAEMON_CB_PER_TICK:-2000}"
DAEMON_HEARTBEAT_MS="${RESEARCH_DAEMON_HEARTBEAT_MS:-1800000}"
LATEXMK_MAX_PASSES="${RESEARCH_LATEXMK_MAX_PASSES:-3}"
IMAGE_TAG="${RESEARCH_IMAGE_TAG:-research-foundry:latest}"
PERSISTENT_DIR="${RESEARCH_PERSISTENT_DIR:-$FED_DIR/persistent}"
PERSISTENT_DISABLED="${RESEARCH_PERSISTENT_DISABLED:-0}"
CROSS_RUN_WINDOW="${RESEARCH_CROSS_RUN_WINDOW:-5}"
ARXIV_GATEWAY="${RESEARCH_ARXIV_GATEWAY:-submit@arxiv.org}"
ARXIV_FROM="${RESEARCH_ARXIV_FROM:-}"
SMTP_HOST="${RESEARCH_SMTP_HOST:-localhost}"
SMTP_PORT="${RESEARCH_SMTP_PORT:-25}"

# Explorer M98 v3 prompt-evolution + fitness knobs.
: "${RESEARCH_EXPLORER_PROMPT_EVOLUTION_THRESHOLD:=3}"
: "${RESEARCH_EXPLORER_PROMPT_GEN_CAP:=10}"
: "${RESEARCH_EXPLORER_PROMPT_MAX_BYTES:=8192}"
: "${RESEARCH_EXPLORER_PROMPT_LEVENSHTEIN_FLOOR:=20}"
: "${RESEARCH_FITNESS_REWARD_NOVEL_PER_TICK:=2}"
: "${RESEARCH_FITNESS_PENALTY_NOT_NOVEL_PER_TICK:=1}"

# Per-colony Claude model selection (#711, #726, reverted in part by #729).
# Eight colonies run opus (decision-quality roles whose output gates a
# downstream cascade or whose prompt round-trip carries the full
# ~200KB research context: explorer's claim emission, formulator's
# claim structuring, novelty's dedup verdict, prior_advocate's
# counter-argument synthesis, verifier's symbolic-math gating,
# auditor's final claim verdict, theorist's proof scaffolding,
# editor's LaTeX assembly). The remaining 10 colonies run on sonnet
# (noticer, skeptic, 4x search adapters, introducer, computer,
# reviewer, submitter -- mechanical / parsing / scripted output that
# does not feed the heavy-context loop). Wired via
# ANTHROPIC_MODEL=<resolved> on each spawn line (the claude CLI
# honors ANTHROPIC_MODEL natively).
#
# Final split: 8 opus + 10 sonnet, matching the Run #14 baseline.
#
# #726 originally flipped explorer, formulator, novelty,
# prior_advocate, and editor from opus to sonnet for Run #15 as a
# cost optimization. #729 reverts those five back to opus after Run
# #15 forensic showed a structural regression: discovery claims
# dropped 136 -> 44 (-68%), PDF preprints 6 -> 0, daemon tick success
# ~90%+ -> ~50%. Root cause was prompt timeout cascade -- the
# research-foundry pipeline ships ~200KB context per prompt (paper
# abstracts + cross-references + verifier reports + prior_advocate
# output), sonnet's per-token speed advantage is overwhelmed by total
# round-trip exceeding the v1.7.14 prompt timeout (120s), so ~50% of
# explorer ticks time out before writing a claim and the upstream
# cascade dies before editor reaches PDF compile. Operator rule "Na
# sonnet nedegraduj -- quality nesmi trpet" empirically validated.
#
# Per-role overrides via RESEARCH_<ROLE>_CLAUDE_MODEL=<model> at
# runtime preserve full flexibility without a code change. The
# proper long-term substrate for cost-aware routing is agentis-core's
# per-tier LLM override (#652, v1.7.15) which routes by confidence
# tier rather than static per-role pin -- research-foundry will
# adopt that once the federation actually reaches autonomous tier.
: "${RESEARCH_EXPLORER_CLAUDE_MODEL:=opus}"
: "${RESEARCH_NOTICER_CLAUDE_MODEL:=sonnet}"
: "${RESEARCH_SKEPTIC_CLAUDE_MODEL:=sonnet}"
: "${RESEARCH_FORMULATOR_CLAUDE_MODEL:=opus}"
: "${RESEARCH_VERIFIER_CLAUDE_MODEL:=opus}"
: "${RESEARCH_NOVELTY_CLAUDE_MODEL:=opus}"
: "${RESEARCH_ARXIV_SEARCH_CLAUDE_MODEL:=sonnet}"
: "${RESEARCH_OEIS_SEARCH_CLAUDE_MODEL:=sonnet}"
: "${RESEARCH_GROUPPROPS_SEARCH_CLAUDE_MODEL:=sonnet}"
: "${RESEARCH_SCHOLAR_SEARCH_CLAUDE_MODEL:=sonnet}"
: "${RESEARCH_PRIOR_ADVOCATE_CLAUDE_MODEL:=opus}"
: "${RESEARCH_AUDITOR_CLAUDE_MODEL:=opus}"
: "${RESEARCH_INTRODUCER_CLAUDE_MODEL:=sonnet}"
: "${RESEARCH_THEORIST_CLAUDE_MODEL:=opus}"
: "${RESEARCH_COMPUTER_CLAUDE_MODEL:=sonnet}"
: "${RESEARCH_EDITOR_CLAUDE_MODEL:=opus}"
: "${RESEARCH_REVIEWER_CLAUDE_MODEL:=sonnet}"
: "${RESEARCH_SUBMITTER_CLAUDE_MODEL:=sonnet}"

# Phase 3 PR 1 (#624): explorer specialty pool + M2-Malthusian replicate gate seeds.
: "${RESEARCH_EXPLORER_REPLICAS:=5}"
: "${RESEARCH_EXPLORER_MAX_REPLICAS:=8}"
: "${RESEARCH_EXPLORER_POOL:=5000}"
: "${RESEARCH_EXPLORER_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

# Phase 9 PR-B (#663): per-colony replica + pool seeds for the 17
# non-explorer colonies. All default to 1 so PR-B does NOT change the
# observable daemon count (still 5 explorers + 13 singletons; cull
# cycle still only fires for explorer unless RESEARCH_CULL_COLONIES is
# changed). PR-C will flip these to N>=3 where it lights up
# replication per colony.
: "${RESEARCH_NOTICER_REPLICAS:=1}"
: "${RESEARCH_NOTICER_MAX_REPLICAS:=8}"
: "${RESEARCH_NOTICER_POOL:=5000}"
: "${RESEARCH_NOTICER_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_SKEPTIC_REPLICAS:=1}"
: "${RESEARCH_SKEPTIC_MAX_REPLICAS:=8}"
: "${RESEARCH_SKEPTIC_POOL:=5000}"
: "${RESEARCH_SKEPTIC_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_FORMULATOR_REPLICAS:=1}"
: "${RESEARCH_FORMULATOR_MAX_REPLICAS:=8}"
: "${RESEARCH_FORMULATOR_POOL:=5000}"
: "${RESEARCH_FORMULATOR_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_VERIFIER_REPLICAS:=1}"
: "${RESEARCH_VERIFIER_MAX_REPLICAS:=8}"
: "${RESEARCH_VERIFIER_POOL:=5000}"
: "${RESEARCH_VERIFIER_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_NOVELTY_REPLICAS:=1}"
: "${RESEARCH_NOVELTY_MAX_REPLICAS:=8}"
: "${RESEARCH_NOVELTY_POOL:=5000}"
: "${RESEARCH_NOVELTY_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_ARXIV_SEARCH_REPLICAS:=1}"
: "${RESEARCH_ARXIV_SEARCH_MAX_REPLICAS:=8}"
: "${RESEARCH_ARXIV_SEARCH_POOL:=5000}"
: "${RESEARCH_ARXIV_SEARCH_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_OEIS_SEARCH_REPLICAS:=1}"
: "${RESEARCH_OEIS_SEARCH_MAX_REPLICAS:=8}"
: "${RESEARCH_OEIS_SEARCH_POOL:=5000}"
: "${RESEARCH_OEIS_SEARCH_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_GROUPPROPS_SEARCH_REPLICAS:=1}"
: "${RESEARCH_GROUPPROPS_SEARCH_MAX_REPLICAS:=8}"
: "${RESEARCH_GROUPPROPS_SEARCH_POOL:=5000}"
: "${RESEARCH_GROUPPROPS_SEARCH_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_SCHOLAR_SEARCH_REPLICAS:=1}"
: "${RESEARCH_SCHOLAR_SEARCH_MAX_REPLICAS:=8}"
: "${RESEARCH_SCHOLAR_SEARCH_POOL:=5000}"
: "${RESEARCH_SCHOLAR_SEARCH_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_AUDITOR_REPLICAS:=1}"
: "${RESEARCH_AUDITOR_MAX_REPLICAS:=8}"
: "${RESEARCH_AUDITOR_POOL:=5000}"
: "${RESEARCH_AUDITOR_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_PRIOR_ADVOCATE_REPLICAS:=1}"
: "${RESEARCH_PRIOR_ADVOCATE_MAX_REPLICAS:=8}"
: "${RESEARCH_PRIOR_ADVOCATE_POOL:=5000}"
: "${RESEARCH_PRIOR_ADVOCATE_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_INTRODUCER_REPLICAS:=1}"
: "${RESEARCH_INTRODUCER_MAX_REPLICAS:=8}"
: "${RESEARCH_INTRODUCER_POOL:=5000}"
: "${RESEARCH_INTRODUCER_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_THEORIST_REPLICAS:=1}"
: "${RESEARCH_THEORIST_MAX_REPLICAS:=8}"
: "${RESEARCH_THEORIST_POOL:=5000}"
: "${RESEARCH_THEORIST_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_COMPUTER_REPLICAS:=1}"
: "${RESEARCH_COMPUTER_MAX_REPLICAS:=8}"
: "${RESEARCH_COMPUTER_POOL:=5000}"
: "${RESEARCH_COMPUTER_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_EDITOR_REPLICAS:=1}"
: "${RESEARCH_EDITOR_MAX_REPLICAS:=8}"
: "${RESEARCH_EDITOR_POOL:=5000}"
: "${RESEARCH_EDITOR_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_REVIEWER_REPLICAS:=1}"
: "${RESEARCH_REVIEWER_MAX_REPLICAS:=8}"
: "${RESEARCH_REVIEWER_POOL:=5000}"
: "${RESEARCH_REVIEWER_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

: "${RESEARCH_SUBMITTER_REPLICAS:=1}"
: "${RESEARCH_SUBMITTER_MAX_REPLICAS:=8}"
: "${RESEARCH_SUBMITTER_POOL:=5000}"
: "${RESEARCH_SUBMITTER_REPRODUCTIVE_FITNESS_THRESHOLD:=3}"

# Phase 9 PR-B (#663): comma-separated list of colony names eligible
# for the cull cycle. PR-C expands the default to all 18 colonies
# now that every non-explorer colony has its replicate gate wired up.
: "${RESEARCH_CULL_COLONIES:=explorer,noticer,formulator,verifier,novelty,skeptic,arxiv-search,oeis-search,groupprops-search,scholar-search,prior_advocate,auditor,introducer,theorist,computer,editor,reviewer,submitter}"

# Cull-cycle sidecar tick interval. Validated below alongside the other
# numeric knobs (#648 follow-up): a zero / negative / non-integer value
# would crash the auto-promote sidecar via `$((tick_count % 0))` because
# `set -euo pipefail` (line 162) propagates the division-by-zero up
# through the backgrounded subshell, killing both auto-promote AND cull
# for the remainder of the run.
: "${RESEARCH_CULL_INTERVAL_TICKS:=5}"

# --- Validation ---
if [ -z "$TOPICS_RAW" ]; then
    echo "run-research: RESEARCH_TOPICS must be a non-empty comma-separated list" >&2
    exit 2
fi

val=""
for var_name in TICK_INTERVAL_S TOTAL_TICKS DAEMONS_PER_COLONY HOLD_PERIOD OPENAI_TIMEOUT_MS LATEXMK_MAX_PASSES SMTP_PORT RESEARCH_EXPLORER_REPLICAS RESEARCH_EXPLORER_MAX_REPLICAS RESEARCH_EXPLORER_POOL RESEARCH_EXPLORER_REPRODUCTIVE_FITNESS_THRESHOLD RESEARCH_CULL_INTERVAL_TICKS; do
    eval "val=\${$var_name}"
    case "$val" in
        ''|*[!0-9]*)
            echo "run-research: $var_name must be a positive integer (got: $val)" >&2
            exit 2
            ;;
    esac
done
unset val

if [ "$TICK_INTERVAL_S" -lt 1 ]; then
    echo "run-research: RESEARCH_TICK_INTERVAL_S must be >= 1 (got: $TICK_INTERVAL_S)" >&2
    exit 2
fi
if [ "$TOTAL_TICKS" -lt 1 ]; then
    echo "run-research: RESEARCH_TOTAL_TICKS must be >= 1 (got: $TOTAL_TICKS)" >&2
    exit 2
fi
if [ "$DAEMONS_PER_COLONY" -lt 1 ]; then
    echo "run-research: RESEARCH_DAEMONS_PER_COLONY must be >= 1 (got: $DAEMONS_PER_COLONY)" >&2
    exit 2
fi
if [ "$RESEARCH_CULL_INTERVAL_TICKS" -lt 1 ]; then
    echo "run-research: RESEARCH_CULL_INTERVAL_TICKS must be >= 1 (got: $RESEARCH_CULL_INTERVAL_TICKS)" >&2
    exit 2
fi

# Resolve PAPER_CORPUS to absolute path when present so we can pass it
# into containers / helpers safely regardless of where the orchestrator
# is launched from.
if [ -d "$PAPER_CORPUS_RAW" ]; then
    PAPER_CORPUS="$(cd "$PAPER_CORPUS_RAW" && pwd)"
else
    PAPER_CORPUS="$PAPER_CORPUS_RAW"
fi

# --- Per-run hermetic dir ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${RESEARCH_RUN_DIR:-$FED_DIR/runs/$TS}"
ORCH_LOG="$RUN_DIR/orchestrator.log"
RUN_META="$RUN_DIR/run-meta.json"
LAPTOP_DIR="$RUN_DIR/laptop-node"
DISCOVERY_LEDGER="$RUN_DIR/discovery-ledger.jsonl"
AUDIT_LEDGER="$RUN_DIR/audit-ledger.jsonl"
PREPRINT_LEDGER="$RUN_DIR/preprint-ledger.jsonl"
REPLICATION_LEDGER="$RUN_DIR/replication-ledger.jsonl"

# --- Dry-run / real-run dispatch helpers ---
emit_cmd() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '+ %s\n' "$*"
    else
        printf '+ %s\n' "$*" >>"$ORCH_LOG"
        # shellcheck disable=SC2294
        eval "$@"
    fi
}

emit_step() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '# %s\n' "$*"
    else
        printf '# %s\n' "$*" >>"$ORCH_LOG"
    fi
}

# --- Prerequisite checks (skipped in dry-run for portability) ---
if [ "$DRY_RUN" = "0" ]; then
    for bin in podman python3; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            echo "run-research: $bin not found on PATH" >&2
            exit 1
        fi
    done
    if [ "$LLM_BACKEND" = "openai" ]; then
        eval "openai_key_value=\${$OPENAI_KEY_ENV:-}"
        if [ -z "${openai_key_value:-}" ]; then
            echo "run-research: \$$OPENAI_KEY_ENV is empty (required for llm.backend=openai)" >&2
            exit 1
        fi
        unset openai_key_value
    fi
    mkdir -p "$RUN_DIR" "$LAPTOP_DIR" "$LAPTOP_DIR/.agentis/sandbox" "$LAPTOP_DIR/.agentis/logs" "$LAPTOP_DIR/.agentis/spend" "$LAPTOP_DIR/preprints"
    : >"$ORCH_LOG"
    : >"$DISCOVERY_LEDGER"
    : >"$AUDIT_LEDGER"
    : >"$PREPRINT_LEDGER"
    : >"$REPLICATION_LEDGER"
fi

emit_step "run-research: starting (dry_run=$DRY_RUN)"
emit_step "run dir: $RUN_DIR"
emit_step "topics: $TOPICS_RAW"
emit_step "paper corpus: $PAPER_CORPUS"
emit_step "tick interval: ${TICK_INTERVAL_S}s"
emit_step "total ticks: $TOTAL_TICKS"
emit_step "daemons per colony: $DAEMONS_PER_COLONY"
emit_step "hold period: $HOLD_PERIOD"
emit_step "llm backend: $LLM_BACKEND"
emit_step "claude model: $CLAUDE_MODEL"
emit_step "confidence floor: $CONFIDENCE_FLOOR"
emit_step "latexmk max passes: $LATEXMK_MAX_PASSES"
emit_step "image tag: $IMAGE_TAG"
emit_step "arxiv gateway: $ARXIV_GATEWAY (HITL-gated; never auto-sent)"
emit_step "author config: $AUTHOR_CONFIG"

# --- 1) Build (or reuse) the container image ---
build_image() {
    emit_step "checking for existing image $IMAGE_TAG (build if missing)"
    emit_cmd "podman image exists $IMAGE_TAG || podman build -t $IMAGE_TAG -f $TOOLS_DIR/Containerfile.research $FED_DIR"
}

# --- 2) Per-node bootstrap script generator ---
# Single bootstrap that spawns all 18 colonies under one .agentis/.
# Three pipeline groups:
#   math      = explorer, noticer, skeptic, formulator, verifier, novelty
#   searchers = arxiv-search, oeis-search, groupprops-search, scholar-search, prior_advocate, auditor
#   preprint  = introducer, theorist, computer, editor, submitter
# Explorer keeps --enable-replication --allow-replica-replication so
# the M2-Malthusian replicate gate inside explorer.ag can grow its
# population. The remaining 17 colonies run with standard
# --enable-exec --enable-messaging flags. Per-daemon tick interval is
# fixed at 30s (decoupled from the orchestrator's TICK_INTERVAL_S
# `replay:current_tick` advance rate); same reason as the retired
# preprint-foundry bootstrap (daemon polls must be much shorter than
# the orchestrator tick to avoid missing state changes).
write_bootstrap() {
    bootstrap_path="$LAPTOP_DIR/bootstrap.sh"
    emit_step "generating bootstrap script at $bootstrap_path (colonies=18 daemons_per_colony=$DAEMONS_PER_COLONY)"

    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "write-bootstrap path=$bootstrap_path colonies=explorer,noticer,skeptic,formulator,verifier,novelty,arxiv-search,oeis-search,groupprops-search,scholar-search,prior_advocate,auditor,introducer,theorist,computer,editor,reviewer,submitter"
        return
    fi

    {
        printf '#!/bin/bash\n'
        printf '# Auto-generated by run-research.sh -- runs inside the container.\n'
        printf 'set -euo pipefail\n'
        printf 'cd /run-root\n'
        printf 'agentis init >/dev/null 2>&1 || true\n'
        printf '{\n'
        # Union of three retired feds' env_passthrough lists.
        printf '  printf "exec.env_passthrough = DAEMON_ID,COLONY_NAME,HOLD_PERIOD,DISCOVERY_LEDGER,AUDIT_LEDGER,PREPRINT_LEDGER,REPLICATION_LEDGER,EXPLORER_GENERATION,AGENTIS_ROOT,ARXIV_MAX_QUERY_RESULTS,PREPRINT_OUTPUT_ROOT,PREPRINT_AUTHOR_CONFIG,PREPRINT_LATEXMK_MAX_PASSES,PREPRINT_ARXIV_GATEWAY,PREPRINT_ARXIV_FROM,PREPRINT_SMTP_HOST,PREPRINT_SMTP_PORT,EXPLORER_PROMPT_EVOLUTION_THRESHOLD,EXPLORER_PROMPT_GEN_CAP,EXPLORER_PROMPT_MAX_BYTES,EXPLORER_PROMPT_LEVENSHTEIN_FLOOR,FOUNDRY_FITNESS_REWARD_NOVEL_PER_TICK,FOUNDRY_FITNESS_PENALTY_NOT_NOVEL_PER_TICK,RESEARCH_JITTER_DISABLED,ANTHROPIC_MODEL\\n"\n'
        printf '  printf "experience.enabled = true\\n"\n'
        printf '  printf "telemetry.enabled = true\\n"\n'
        # #740: AdaptiveEngine activation. Without this flag the
        # recommend() / adapt() / score_options() builtins silently
        # no-op even though the runtime ships them; learn() rows still
        # land in the experience ledger but cannot feed back into
        # strategy selection. Mirrors dev-apprenticeship/install.sh L707.
        printf '  printf "learning.enabled = true\\n"\n'
        # #741: KnowledgeBase activation. Without this flag knowledge_buy()
        # returns "" and knowledge_sell() returns false silently per
        # agentis-core cli/run.rs:554. Required for the knowledge market
        # wired in novelty/explorer/prior_advocate (#741). KB lives at
        # <root>/knowledge/ per cli/run.rs:561; intra-run sharing works
        # immediately. Cross-run KB persistence requires a separate
        # persistent-snapshot.py extension (filed as follow-up).
        printf '  printf "knowledge.enabled = true\\n"\n'
        # #743: ed25519-signed Action audit chain. Without
        # `audit.persist_actions = true`, agentis-core treats the audit
        # ledger as in-memory only and never flushes rows to
        # <root>/audit/actions.jsonl. Without an explicit
        # `audit.signing_key_path`, the runtime falls back to
        # <root>/identity/private.key — but `agentis init` does not
        # create that key, so signing degrades to unsigned chain rows.
        # We bootstrap the ed25519 keypair explicitly below (mkdir +
        # openssl/agentis identity init + chmod 600) so every Action
        # row gets {seq, prev_hash, signer_pubkey, signature} and
        # `agentis audit verify-actions` reports chained=N (N valid,
        # 0 unsigned). Operator security note: <root>/audit/ and
        # <root>/identity/ become credential-grade artifacts under
        # this config — chmod 600 + restrict to forensic readers.
        printf '  printf "audit.persist_actions = true\\n"\n'
        printf '  printf "audit.signing_key_path = .agentis/identity/private.key\\n"\n'
        # #742: TaskBoard cognitive-market activation. Without
        # `economy.enabled = true`, the offer/accept/complete builtins
        # raise `economy not enabled` at agentis-core boot (the CB
        # pool and TaskBoard handles are wired only when this gate is
        # open).
        # The TaskBoard substrate has shipped in agentis-core since the
        # cognitive market work but no federation has consumed it;
        # research-foundry is the first — explorer offers compute-heavy
        # claims, computer/theorist accept and complete on dedicated
        # channels (research-foundry:compute, research-foundry:theory).
        # `market.task_timeout_s` raises the per-task timeout from the
        # 300 s default so a 600 s tick window (claim → compute →
        # complete) is not preempted by escrow expiry. `market.max_open_tasks`
        # is raised from the 1000 default so an 18-colony × 75-tick run
        # with parallel offers across explorer instances cannot starve
        # on the open-task cap.
        printf '  printf "economy.enabled = true\\n"\n'
        printf '  printf "market.task_timeout_s = 600\\n"\n'
        printf '  printf "market.max_open_tasks = 5000\\n"\n'
        printf '  printf "llm.backend = %s\\n"\n' "$LLM_BACKEND"
        printf '  printf "daemon.cb_per_tick = %s\\n"\n' "$DAEMON_CB_PER_TICK"
        printf '  printf "daemon.heartbeat_interval_ms = %s\\n"\n' "$DAEMON_HEARTBEAT_MS"
        # PII allow: arxiv abstracts, OEIS A-numbers, LaTeX bodies, GAP
        # output all contain long numeric runs that the agentis-core
        # heuristic flags. Mirrors trading-binance fix (#581).
        printf '  printf "pii_transmit = allow\\n"\n'
        # Memo cap bump: 18 colonies x 30 ticks x per-pid keys + per-claim
        # status keys fills the default 500 fast. Mirrors #587.
        printf '  printf "memo.max_keys = 50000\\n"\n'
        if [ "$LLM_BACKEND" = "openai" ]; then
            printf '  printf "llm.openai.endpoint = %s\\n"\n' "$OPENAI_ENDPOINT"
            printf '  printf "llm.openai.model = %s\\n"\n' "$OPENAI_MODEL"
            printf '  printf "llm.openai.api_key_env = %s\\n"\n' "$OPENAI_KEY_ENV"
            printf '  printf "llm.openai.timeout_ms = %s\\n"\n' "$OPENAI_TIMEOUT_MS"
        elif [ "$LLM_BACKEND" = "claude" ]; then
            # Per-colony model split (#711): the shared `llm.args`
            # config no longer carries `--model`. Instead, each daemon
            # spawn line below prepends `ANTHROPIC_MODEL=<resolved>` so
            # the claude CLI picks up the colony's chosen model
            # natively. The shared block keeps `--effort` because that
            # knob is orthogonal to the model split.
            printf '  printf "llm.command = claude\\n"\n'
            printf '  printf "llm.args = -p --output-format json --tools \\"\\" --system-prompt \\"You are a research mathematician drafting an arXiv preprint. Output only valid JSON.\\" --effort %s\\n"\n' "$CLAUDE_EFFORT"
        fi
        printf '} >> .agentis/config\n'
        # Stage all 18 colonies + tools/ + config/ + data/ from the
        # read-only /repo bind-mount.
        printf 'for c in explorer noticer skeptic formulator verifier novelty arxiv-search oeis-search groupprops-search scholar-search prior_advocate auditor introducer theorist computer editor reviewer submitter; do\n'
        printf '    cp -r /repo/research-foundry/$c /run-root/$c\n'
        printf 'done\n'
        printf 'cp -r /repo/research-foundry/tools /run-root/tools\n'
        # #743: extend mkdir with .agentis/audit and .agentis/identity.
        # `agentis init` (L638 above) creates config/daemon/experience/
        # logs/memo/objects/sandbox/spend/suspend but NOT audit/ or
        # identity/, so audit.persist_actions would otherwise fail
        # silently on first ledger flush. Identity dir holds the
        # ed25519 private key bootstrapped immediately below.
        printf 'mkdir -p /run-root/.agentis/sandbox /run-root/.agentis/logs /run-root/.agentis/audit /run-root/.agentis/identity /run-root/config /run-root/preprints /run-root/data\n'
        # #743: bootstrap ed25519 keypair for audit-chain signing.
        # Prefer `agentis identity init` when the pinned runtime ships
        # it; fall back to `openssl genpkey -algorithm ed25519` (always
        # available in the research container per Containerfile.research).
        # chmod 600 because agentis-core #584 M2 release note flags the
        # private key as credential-grade. The `|| true` after chmod is
        # defensive in case `agentis identity init` writes to a
        # different filename — the audit chain will simply fall back to
        # unsigned rows in that case and the verify step will surface it.
        printf 'if command -v agentis >/dev/null 2>&1 && agentis identity init >/dev/null 2>&1; then :; else openssl genpkey -algorithm ed25519 -out /run-root/.agentis/identity/private.key 2>/dev/null || true; fi\n'
        printf 'chmod 600 /run-root/.agentis/identity/private.key 2>/dev/null || true\n'
        printf 'if [ -d /repo/research-foundry/data/papers ]; then cp -r /repo/research-foundry/data/papers /run-root/data/papers; fi\n'
        printf 'if [ -f /repo/research-foundry/config/authors.toml ]; then cp /repo/research-foundry/config/authors.toml /run-root/config/authors.toml; fi\n'
        printf ': > /run-root/discovery-ledger.jsonl\n'
        printf ': > /run-root/audit-ledger.jsonl\n'
        printf ': > /run-root/preprint-ledger.jsonl\n'
        printf ': > /run-root/replication-ledger.jsonl\n'
        # Seed propose-tier confidence for each colony. All keys use the
        # canonical dashed `<basename>:confidence` form per CLAUDE.md Agent
        # conventions; `prior_advocate` remains underscored because its disk
        # basename is `prior_advocate` (the underscore IS its canonical form).
        #
        # Phase 5 PR-B (#626): hot-start restore. If
        # `<persistent-dir>/memo-snapshot.json` (written by PR-A at the
        # last run end) carries a `<colony>:confidence` value, seed the
        # in-container memo with it instead of the legacy 0.7 floor.
        # When the persistent dir / snapshot is missing OR
        # RESEARCH_PERSISTENT_DISABLED=1, the loop emits the
        # byte-identical legacy form so a virgin federation behaves
        # exactly as before.
        prb_snapshot_path="$PERSISTENT_DIR/memo-snapshot.json"
        if [ "$PERSISTENT_DISABLED" != "1" ] && [ -f "$prb_snapshot_path" ]; then
            for prb_c in explorer noticer skeptic formulator verifier novelty arxiv-search oeis-search groupprops-search scholar-search prior_advocate auditor introducer theorist computer editor reviewer submitter; do
                prb_val="$(python3 "$TOOLS_DIR/persistent-load.py" load-confidence "$PERSISTENT_DIR" "$prb_c" 2>/dev/null || true)"
                if [ -n "$prb_val" ]; then
                    printf '(cd /run-root && agentis memo set %s:confidence %s >/dev/null 2>&1 || true)\n' "$prb_c" "$prb_val"
                else
                    printf '(cd /run-root && agentis memo set %s:confidence 0.7 >/dev/null 2>&1 || true)\n' "$prb_c"
                fi
            done
            unset prb_c prb_val
        else
            printf 'for c in explorer noticer skeptic formulator verifier novelty arxiv-search oeis-search groupprops-search scholar-search prior_advocate auditor introducer theorist computer editor reviewer submitter; do\n'
            printf '    (cd /run-root && agentis memo set $c:confidence 0.7 >/dev/null 2>&1 || true)\n'
            printf 'done\n'
        fi
        unset prb_snapshot_path
        # Per-daemon tick interval is 30s (decoupled from orchestrator
        # tick); same lesson as the retired preprint-foundry bootstrap.
        printf 'DAEMON_TICK_INTERVAL_MS=30000\n'
        printf 'EXPLORER_TICK_INTERVAL_MS=30000\n'
        # Phase 9 PR-B (#663): seed every colony's specialty pool +
        # overlays from the source-of-truth table in
        # research-foundry/tools/colony-variants.json. The bind-mounted
        # /repo gives the in-container bootstrap access to that table;
        # a Python one-liner enumerates 18 colonies x 5 variants and
        # `agentis memo set <colony>:pool:specialty:<N>` /
        # `<colony>:pool:specialty_overlay:<N>` for each. With PR-B's
        # N=1 default for non-explorer colonies the .ag first-tick
        # claim logic uses slot=1 only; PR-C will turn this into the
        # full per-colony specialty pool. The legacy hardcoded
        # 5-specialty explorer seed is preserved byte-for-byte by the
        # colony-variants.json `explorer` entry.
        printf 'python3 - <<'"'"'PY'"'"'\n'
        printf 'import json, subprocess\n'
        printf 'with open("/repo/research-foundry/tools/colony-variants.json") as f:\n'
        printf '    data = json.load(f)\n'
        printf 'for colony, entry in (data.get("colonies") or {}).items():\n'
        printf '    variants = entry.get("variants") or []\n'
        printf '    overlays = entry.get("overlays") or {}\n'
        printf '    for n, sp in enumerate(variants, start=1):\n'
        printf '        subprocess.run(["agentis","memo","set","%%s:pool:specialty:%%d" %% (colony,n), sp], cwd="/run-root", check=False)\n'
        printf '        overlay = overlays.get(sp, "")\n'
        printf '        if overlay:\n'
        printf '            subprocess.run(["agentis","memo","set","%%s:pool:specialty_overlay:%%d" %% (colony,n), overlay], cwd="/run-root", check=False)\n'
        printf 'PY\n'
        # Phase 9 PR-B (#663): seed the M2-Malthusian replicate gate
        # memos for every colony, not just explorer. The non-explorer
        # rows default to RESEARCH_<COLONY>_REPLICAS=1 so the observable
        # daemon count is preserved (5 explorer + 13 singletons). PR-C
        # will flip these env knobs to >=3 where it lights up
        # replication; the cull cycle still only fires for the
        # explorer until RESEARCH_CULL_COLONIES is widened.
        printf '(cd /run-root && agentis memo set colony-explorer:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_EXPLORER_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-explorer:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_EXPLORER_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-explorer:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_EXPLORER_POOL"
        printf '(cd /run-root && agentis memo set colony-explorer:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-explorer:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set explorer:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_EXPLORER_REPRODUCTIVE_FITNESS_THRESHOLD"
        # Per-colony M2-Malthusian seeds for the 17 non-explorer
        # research-foundry colonies. PR-B keeps RESEARCH_<COLONY>_REPLICAS
        # at 1 by default so daemon spawn loops below are unaffected; PR-C
        # will flip the env knobs.
        printf '(cd /run-root && agentis memo set colony-noticer:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_NOTICER_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-noticer:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_NOTICER_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-noticer:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_NOTICER_POOL"
        printf '(cd /run-root && agentis memo set colony-noticer:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-noticer:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set noticer:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_NOTICER_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-skeptic:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_SKEPTIC_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-skeptic:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_SKEPTIC_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-skeptic:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_SKEPTIC_POOL"
        printf '(cd /run-root && agentis memo set colony-skeptic:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-skeptic:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set skeptic:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_SKEPTIC_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-formulator:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_FORMULATOR_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-formulator:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_FORMULATOR_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-formulator:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_FORMULATOR_POOL"
        printf '(cd /run-root && agentis memo set colony-formulator:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-formulator:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set formulator:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_FORMULATOR_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-verifier:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_VERIFIER_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-verifier:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_VERIFIER_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-verifier:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_VERIFIER_POOL"
        printf '(cd /run-root && agentis memo set colony-verifier:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-verifier:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set verifier:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_VERIFIER_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-novelty:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_NOVELTY_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-novelty:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_NOVELTY_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-novelty:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_NOVELTY_POOL"
        printf '(cd /run-root && agentis memo set colony-novelty:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-novelty:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set novelty:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_NOVELTY_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-arxiv-search:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_ARXIV_SEARCH_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-arxiv-search:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_ARXIV_SEARCH_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-arxiv-search:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_ARXIV_SEARCH_POOL"
        printf '(cd /run-root && agentis memo set colony-arxiv-search:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-arxiv-search:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set arxiv-search:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_ARXIV_SEARCH_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-oeis-search:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_OEIS_SEARCH_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-oeis-search:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_OEIS_SEARCH_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-oeis-search:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_OEIS_SEARCH_POOL"
        printf '(cd /run-root && agentis memo set colony-oeis-search:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-oeis-search:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set oeis-search:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_OEIS_SEARCH_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-groupprops-search:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_GROUPPROPS_SEARCH_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-groupprops-search:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_GROUPPROPS_SEARCH_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-groupprops-search:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_GROUPPROPS_SEARCH_POOL"
        printf '(cd /run-root && agentis memo set colony-groupprops-search:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-groupprops-search:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set groupprops-search:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_GROUPPROPS_SEARCH_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-scholar-search:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_SCHOLAR_SEARCH_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-scholar-search:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_SCHOLAR_SEARCH_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-scholar-search:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_SCHOLAR_SEARCH_POOL"
        printf '(cd /run-root && agentis memo set colony-scholar-search:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-scholar-search:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set scholar-search:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_SCHOLAR_SEARCH_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-auditor:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_AUDITOR_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-auditor:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_AUDITOR_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-auditor:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_AUDITOR_POOL"
        printf '(cd /run-root && agentis memo set colony-auditor:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-auditor:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set auditor:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_AUDITOR_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-prior_advocate:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_PRIOR_ADVOCATE_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-prior_advocate:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_PRIOR_ADVOCATE_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-prior_advocate:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_PRIOR_ADVOCATE_POOL"
        printf '(cd /run-root && agentis memo set colony-prior_advocate:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-prior_advocate:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set prior_advocate:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_PRIOR_ADVOCATE_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-introducer:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_INTRODUCER_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-introducer:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_INTRODUCER_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-introducer:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_INTRODUCER_POOL"
        printf '(cd /run-root && agentis memo set colony-introducer:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-introducer:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set introducer:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_INTRODUCER_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-theorist:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_THEORIST_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-theorist:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_THEORIST_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-theorist:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_THEORIST_POOL"
        printf '(cd /run-root && agentis memo set colony-theorist:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-theorist:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set theorist:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_THEORIST_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-computer:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_COMPUTER_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-computer:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_COMPUTER_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-computer:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_COMPUTER_POOL"
        printf '(cd /run-root && agentis memo set colony-computer:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-computer:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set computer:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_COMPUTER_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-editor:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_EDITOR_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-editor:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_EDITOR_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-editor:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_EDITOR_POOL"
        printf '(cd /run-root && agentis memo set colony-editor:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-editor:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set editor:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_EDITOR_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-reviewer:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_REVIEWER_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-reviewer:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_REVIEWER_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-reviewer:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_REVIEWER_POOL"
        printf '(cd /run-root && agentis memo set colony-reviewer:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-reviewer:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set reviewer:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_REVIEWER_REPRODUCTIVE_FITNESS_THRESHOLD"
        printf '(cd /run-root && agentis memo set colony-submitter:size %s >/dev/null 2>&1 || true)\n' "$RESEARCH_SUBMITTER_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-submitter:max_replicas %s >/dev/null 2>&1 || true)\n' "$RESEARCH_SUBMITTER_MAX_REPLICAS"
        printf '(cd /run-root && agentis memo set colony-submitter:pool %s >/dev/null 2>&1 || true)\n' "$RESEARCH_SUBMITTER_POOL"
        printf '(cd /run-root && agentis memo set colony-submitter:replication_base_cost 100 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set colony-submitter:replication_k 3 >/dev/null 2>&1 || true)\n'
        printf '(cd /run-root && agentis memo set submitter:reproductive_fitness_threshold %s >/dev/null 2>&1 || true)\n' "$RESEARCH_SUBMITTER_REPRODUCTIVE_FITNESS_THRESHOLD"
        # math pipeline: explorer (with replication) + noticer/formulator/verifier/novelty.
        # Phase 3 PR 1 (#624): spawn RESEARCH_EXPLORER_REPLICAS explorers
        # (default 5) each carrying a distinct DAEMON_ID used by the .ag
        # first-tick logic to claim a specialty from the pool. Generation 0
        # for the initial cohort; child replicates increment generation
        # in the replicate-success branch.
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_EXPLORER_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=explorer EXPLORER_GENERATION=0 HOLD_PERIOD=%s DISCOVERY_LEDGER=/run-root/discovery-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis EXPLORER_PROMPT_EVOLUTION_THRESHOLD=%s EXPLORER_PROMPT_GEN_CAP=%s EXPLORER_PROMPT_MAX_BYTES=%s EXPLORER_PROMPT_LEVENSHTEIN_FLOOR=%s FOUNDRY_FITNESS_REWARD_NOVEL_PER_TICK=%s FOUNDRY_FITNESS_PENALTY_NOT_NOVEL_PER_TICK=%s agentis daemon /run-root/explorer/agents/explorer.ag --colony explorer --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$EXPLORER_TICK_INTERVAL_MS" > /run-root/.agentis/logs/explorer-$i.log 2>&1 &\n' \
            "$RESEARCH_EXPLORER_CLAUDE_MODEL" \
            "$HOLD_PERIOD" \
            "$RESEARCH_EXPLORER_PROMPT_EVOLUTION_THRESHOLD" \
            "$RESEARCH_EXPLORER_PROMPT_GEN_CAP" \
            "$RESEARCH_EXPLORER_PROMPT_MAX_BYTES" \
            "$RESEARCH_EXPLORER_PROMPT_LEVENSHTEIN_FLOOR" \
            "$RESEARCH_FITNESS_REWARD_NOVEL_PER_TICK" \
            "$RESEARCH_FITNESS_PENALTY_NOT_NOVEL_PER_TICK"
        printf 'done\n'
        # Phase 3 PR 1 (#624): emit one `spawn` row per initial explorer
        # into the replication ledger. The bootstrap already knows the
        # loop iteration and the specialty assignment, so emit here
        # rather than racing the .ag's first-tick claim path.
        #
        # Phase 5 PR-B (#626): if `<persistent-dir>/fittest_specialties.json`
        # exists (written by PR-C, NOT yet by anything in-tree at PR-B
        # -- the test suite seeds a synthetic fixture), bias the 5
        # explorer slots so the top 60% of specialties by avg_fitness
        # claim floor(N * 0.8) round-robin slots and the remaining
        # ceil(N * 0.2) slots are forced mutation drawn from non-top
        # variants. When the file is missing OR
        # RESEARCH_PERSISTENT_DISABLED=1, the case statement emits the
        # byte-identical legacy 5-way round-robin so a virgin
        # federation behaves exactly as before.
        prb_fittest_path="$PERSISTENT_DIR/fittest_specialties.json"
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_EXPLORER_REPLICAS"
        printf '    case $i in\n'
        if [ "$PERSISTENT_DISABLED" != "1" ] && [ -f "$prb_fittest_path" ]; then
            prb_slot_idx=1
            python3 "$TOOLS_DIR/persistent-load.py" weighted-specialty-slots \
                "$PERSISTENT_DIR" \
                "$TOOLS_DIR/colony-variants.json" \
                "$RESEARCH_EXPLORER_REPLICAS" 2>/dev/null | while IFS= read -r prb_slot_sp; do
                if [ -n "$prb_slot_sp" ]; then
                    printf '        %s) sp=%s ;;\n' "$prb_slot_idx" "$prb_slot_sp"
                fi
                prb_slot_idx=$((prb_slot_idx + 1))
            done
            unset prb_slot_idx prb_slot_sp
        else
            printf '        1) sp=group_theory ;;\n'
            printf '        2) sp=combinatorics ;;\n'
            printf '        3) sp=number_theory ;;\n'
            printf '        4) sp=probability ;;\n'
            printf '        5) sp=algebra ;;\n'
        fi
        printf '        *) sp=unassigned ;;\n'
        printf '    esac\n'
        printf '    ts_ms=$(date +%%s%%3N)\n'
        printf '    python3 -c '"'"'import json,sys; sys.stdout.write(json.dumps({"ts":int(sys.argv[1]),"event":"spawn","daemon_id":int(sys.argv[2]),"specialty":sys.argv[3],"generation":0,"reason":"initial"})+"\\n")'"'"' "$ts_ms" "$i" "$sp" >> /run-root/replication-ledger.jsonl\n'
        printf 'done\n'
        unset prb_fittest_path
        # Phase 9 PR-C (#663): each of the 4 math downstream colonies
        # spawns RESEARCH_<COLONY>_REPLICAS daemons (default 3 per the
        # PR-C env flip below). Each spawn line carries
        # --enable-replication --allow-replica-replication and a
        # <COLONY>_GENERATION=0 env var so the .ag first-tick claim
        # block reads the seeded specialty pool.
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_NOTICER_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=noticer NOTICER_GENERATION=0 DISCOVERY_LEDGER=/run-root/discovery-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/noticer/agents/noticer.ag --colony noticer --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/noticer-$i.log 2>&1 &\n' \
            "$RESEARCH_NOTICER_CLAUDE_MODEL"
        printf 'done\n'
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_FORMULATOR_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=formulator FORMULATOR_GENERATION=0 DISCOVERY_LEDGER=/run-root/discovery-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/formulator/agents/formulator.ag --colony formulator --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/formulator-$i.log 2>&1 &\n' \
            "$RESEARCH_FORMULATOR_CLAUDE_MODEL"
        printf 'done\n'
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_VERIFIER_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=verifier VERIFIER_GENERATION=0 DISCOVERY_LEDGER=/run-root/discovery-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/verifier/agents/verifier.ag --colony verifier --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/verifier-$i.log 2>&1 &\n' \
            "$RESEARCH_VERIFIER_CLAUDE_MODEL"
        printf 'done\n'
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_NOVELTY_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=novelty NOVELTY_GENERATION=0 DISCOVERY_LEDGER=/run-root/discovery-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/novelty/agents/novelty.ag --colony novelty --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/novelty-$i.log 2>&1 &\n' \
            "$RESEARCH_NOVELTY_CLAUDE_MODEL"
        printf 'done\n'
        # Phase 4 PR-A (#625): skeptic colony gates the formulator on
        # noticer surprises. Phase 9 PR-C (#663) lights up replication.
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_SKEPTIC_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=skeptic SKEPTIC_GENERATION=0 DISCOVERY_LEDGER=/run-root/discovery-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/skeptic/agents/skeptic.ag --colony skeptic --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/skeptic-$i.log 2>&1 &\n' \
            "$RESEARCH_SKEPTIC_CLAUDE_MODEL"
        printf 'done\n'
        # claim-auditor: four searchers + auditor. Audit-trail goes to
        # audit-ledger.jsonl. Phase 9 PR-C (#663) lights up replication
        # per searcher; each gets its own replica-count env knob.
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_ARXIV_SEARCH_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=arxiv-search ARXIV_SEARCH_GENERATION=0 DISCOVERY_LEDGER=/run-root/audit-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl ARXIV_MAX_QUERY_RESULTS=10 AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/arxiv-search/agents/arxiv-search.ag --colony arxiv-search --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/arxiv-search-$i.log 2>&1 &\n' \
            "$RESEARCH_ARXIV_SEARCH_CLAUDE_MODEL"
        printf 'done\n'
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_OEIS_SEARCH_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=oeis-search OEIS_SEARCH_GENERATION=0 DISCOVERY_LEDGER=/run-root/audit-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl ARXIV_MAX_QUERY_RESULTS=10 AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/oeis-search/agents/oeis-search.ag --colony oeis-search --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/oeis-search-$i.log 2>&1 &\n' \
            "$RESEARCH_OEIS_SEARCH_CLAUDE_MODEL"
        printf 'done\n'
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_GROUPPROPS_SEARCH_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=groupprops-search GROUPPROPS_SEARCH_GENERATION=0 DISCOVERY_LEDGER=/run-root/audit-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl ARXIV_MAX_QUERY_RESULTS=10 AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/groupprops-search/agents/groupprops-search.ag --colony groupprops-search --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/groupprops-search-$i.log 2>&1 &\n' \
            "$RESEARCH_GROUPPROPS_SEARCH_CLAUDE_MODEL"
        printf 'done\n'
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_SCHOLAR_SEARCH_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=scholar-search SCHOLAR_SEARCH_GENERATION=0 DISCOVERY_LEDGER=/run-root/audit-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl ARXIV_MAX_QUERY_RESULTS=10 AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/scholar-search/agents/scholar-search.ag --colony scholar-search --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/scholar-search-$i.log 2>&1 &\n' \
            "$RESEARCH_SCHOLAR_SEARCH_CLAUDE_MODEL"
        printf 'done\n'
        # Phase 4 PR-B (#625): prior_advocate colony runs the adversarial
        # reviewer prompt that argues the claim is already known.
        # Phase 9 PR-C (#663) lights up replication.
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_PRIOR_ADVOCATE_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=prior_advocate PRIOR_ADVOCATE_GENERATION=0 DISCOVERY_LEDGER=/run-root/audit-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/prior_advocate/agents/prior_advocate.ag --colony prior_advocate --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/prior_advocate-$i.log 2>&1 &\n' \
            "$RESEARCH_PRIOR_ADVOCATE_CLAUDE_MODEL"
        printf 'done\n'
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_AUDITOR_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=auditor AUDITOR_GENERATION=0 DISCOVERY_LEDGER=/run-root/audit-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/auditor/agents/auditor.ag --colony auditor --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/auditor-$i.log 2>&1 &\n' \
            "$RESEARCH_AUDITOR_CLAUDE_MODEL"
        printf 'done\n'
        # preprint-foundry: introducer / theorist / computer / editor / submitter.
        # Audit-trail goes to preprint-ledger.jsonl. Phase 9 PR-C (#663)
        # lights up replication across the six preprint colonies; the
        # editor + submitter spawn loops carry the LATEXMK / ARXIV envs.
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_INTRODUCER_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=introducer INTRODUCER_GENERATION=0 DISCOVERY_LEDGER=/run-root/preprint-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis PREPRINT_OUTPUT_ROOT=/run-root/preprints PREPRINT_AUTHOR_CONFIG=/run-root/config/authors.toml PREPRINT_LATEXMK_MAX_PASSES=%s agentis daemon /run-root/introducer/agents/introducer.ag --colony introducer --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/introducer-$i.log 2>&1 &\n' \
            "$RESEARCH_INTRODUCER_CLAUDE_MODEL" "$LATEXMK_MAX_PASSES"
        printf 'done\n'
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_THEORIST_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=theorist THEORIST_GENERATION=0 DISCOVERY_LEDGER=/run-root/preprint-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis PREPRINT_OUTPUT_ROOT=/run-root/preprints PREPRINT_AUTHOR_CONFIG=/run-root/config/authors.toml PREPRINT_LATEXMK_MAX_PASSES=%s agentis daemon /run-root/theorist/agents/theorist.ag --colony theorist --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/theorist-$i.log 2>&1 &\n' \
            "$RESEARCH_THEORIST_CLAUDE_MODEL" "$LATEXMK_MAX_PASSES"
        printf 'done\n'
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_COMPUTER_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=computer COMPUTER_GENERATION=0 DISCOVERY_LEDGER=/run-root/preprint-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis PREPRINT_OUTPUT_ROOT=/run-root/preprints PREPRINT_AUTHOR_CONFIG=/run-root/config/authors.toml PREPRINT_LATEXMK_MAX_PASSES=%s agentis daemon /run-root/computer/agents/computer.ag --colony computer --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/computer-$i.log 2>&1 &\n' \
            "$RESEARCH_COMPUTER_CLAUDE_MODEL" "$LATEXMK_MAX_PASSES"
        printf 'done\n'
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_EDITOR_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=editor EDITOR_GENERATION=0 DISCOVERY_LEDGER=/run-root/preprint-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis PREPRINT_OUTPUT_ROOT=/run-root/preprints PREPRINT_AUTHOR_CONFIG=/run-root/config/authors.toml PREPRINT_LATEXMK_MAX_PASSES=%s agentis daemon /run-root/editor/agents/editor.ag --colony editor --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/editor-$i.log 2>&1 &\n' \
            "$RESEARCH_EDITOR_CLAUDE_MODEL" "$LATEXMK_MAX_PASSES"
        printf 'done\n'
        # Phase 4 PR-C (#625): reviewer colony enforces a block-by-default
        # gate before the submitter can write the DRAFTED row. Reads
        # editor:<pid>:final_tex and computer:<pid>:output at
        # upstream_tick = tick_idx - 3, extracts every numerical / symbolic
        # claim in the .tex, flags unsupported claims, writes
        # reviewer:<claim>:approved = "true" ONLY when verdict == approved.
        # Operator override: `agentis memo set reviewer:<claim>:approved true`.
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_REVIEWER_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=reviewer REVIEWER_GENERATION=0 DISCOVERY_LEDGER=/run-root/preprint-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/reviewer/agents/reviewer.ag --colony reviewer --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/reviewer-$i.log 2>&1 &\n' \
            "$RESEARCH_REVIEWER_CLAUDE_MODEL"
        printf 'done\n'
        printf 'for i in $(seq 1 %s); do\n' "$RESEARCH_SUBMITTER_REPLICAS"
        printf '    ANTHROPIC_MODEL=%s DAEMON_ID=$i COLONY_NAME=submitter SUBMITTER_GENERATION=0 DISCOVERY_LEDGER=/run-root/preprint-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis PREPRINT_OUTPUT_ROOT=/run-root/preprints PREPRINT_AUTHOR_CONFIG=/run-root/config/authors.toml PREPRINT_ARXIV_GATEWAY=%s PREPRINT_ARXIV_FROM=%s PREPRINT_SMTP_HOST=%s PREPRINT_SMTP_PORT=%s agentis daemon /run-root/submitter/agents/submitter.ag --colony submitter --enable-exec --enable-messaging --enable-replication --allow-replica-replication --skip-prompt-after-idle --skip-prompt-without-input --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/submitter-$i.log 2>&1 &\n' \
            "$RESEARCH_SUBMITTER_CLAUDE_MODEL" "$ARXIV_GATEWAY" "$ARXIV_FROM" "$SMTP_HOST" "$SMTP_PORT"
        printf 'done\n'
        printf 'while [ ! -e /run-root/.shutdown ]; do sleep 5; done\n'
        printf 'exit 0\n'
    } >"$bootstrap_path"
    chmod +x "$bootstrap_path"
}

# --- 3) Spawn the container ---
spawn_container() {
    emit_step "spawning research-foundry container (image=$IMAGE_TAG)"
    if [ "$LLM_BACKEND" = "claude" ]; then
        # Bind-mount host's ~/.claude into container so claude CLI can
        # read OAuth session tokens (Max 20x flat-rate). ':z' SELinux
        # relabel required on Fedora / RHEL. Mirrors tribes-bench
        # (#535, #540).
        emit_cmd "podman run -d --replace --name research-foundry-laptop -v $REPO_ROOT:/repo:ro -v $LAPTOP_DIR:/run-root:rw -v $HOST_CLAUDE_DIR:/root/.claude:rw,z $IMAGE_TAG /run-root/bootstrap.sh"
    else
        emit_cmd "podman run -d --replace --name research-foundry-laptop -e $OPENAI_KEY_ENV=\"\${$OPENAI_KEY_ENV:-}\" -v $REPO_ROOT:/repo:ro -v $LAPTOP_DIR:/run-root:rw $IMAGE_TAG /run-root/bootstrap.sh"
    fi
}

# --- 4) Cleanup trap ---
AUTO_PROMOTE_PID=""
install_cleanup_trap() {
    emit_step "installing cleanup trap (stop + rm container; kill sidecars; rm sidecar install file)"
    # shellcheck disable=SC2064  # Expand $AUTO_PROMOTE_PID at trigger time.
    emit_cmd "trap '[ -n \"\${AUTO_PROMOTE_PID:-}\" ] && kill \"\$AUTO_PROMOTE_PID\" 2>/dev/null; rm -f \"$LAPTOP_DIR/.auto-promote-install.toml\" 2>/dev/null; podman stop --time 5 research-foundry-laptop 2>/dev/null || true; podman rm -f research-foundry-laptop 2>/dev/null || true' EXIT INT TERM"
}

# --- 4.5) Auto-promote sidecar (#622, consolidated #638) ---
# Spawns a background loop that invokes tools/auto-promote.sh in
# --containerized mode every AP_INTERVAL seconds. Cwd is the host-side
# bind-mount root ($LAPTOP_DIR == <run-dir>/laptop-node/) where the
# container's .agentis/ state materialises. Self-terminates when no
# daemons report `state="running"` (e.g. after signal_shutdown drained
# the container). The cleanup trap installed above kills it on
# orchestrator EXIT/INT/TERM.
#
# Env knobs:
#   RESEARCH_AUTO_PROMOTE             1 enable (default), 0 disable
#   RESEARCH_AUTO_PROMOTE_INTERVAL_S  seconds between sidecar ticks
#                                     (default 300)
start_auto_promote_sidecar() {
    AP_ENABLED="${RESEARCH_AUTO_PROMOTE:-1}"
    AP_INTERVAL="${RESEARCH_AUTO_PROMOTE_INTERVAL_S:-300}"
    # Phase 3 PR 3 (#624): optional cull cycle layered on top of the
    # auto-promote sidecar tick. Phase 10 (#679) flipped the defaults so
    # birth/death engages in the default 30-tick run-research.sh
    # invocation without operator opt-in: ENABLED=1, INTERVAL_TICKS=5,
    # MIN_ACTING=3. The cull cycle kills the bottom-N explorer daemons
    # by fitness_score and respawns replacements with demand-weighted
    # specialty. CULL_MIN_EXPLORERS stays at 3 as a floor protection.
    CULL_ENABLED="${RESEARCH_CULL_ENABLED:-1}"
    CULL_INTERVAL_TICKS="${RESEARCH_CULL_INTERVAL_TICKS:-5}"
    CULL_BOTTOM_PCT="${RESEARCH_CULL_BOTTOM_PCT:-0.2}"
    CULL_MIN_EXPLORERS="${RESEARCH_CULL_MIN_EXPLORERS:-3}"
    CULL_MIN_ACTING="${RESEARCH_CULL_MIN_ACTING:-3}"
    # Phase 9 PR-B (#663): the generalised cull script supersedes the
    # legacy cull-explorers.sh wrapper; we drive it once per colony in
    # $RESEARCH_CULL_COLONIES (comma-separated, default `explorer`).
    # The wrapper still exists for older operators but PR-B prefers
    # the colony-parametric path so we can iterate.
    CULL_SCRIPT="$REPO_ROOT/tools/cull-replicas.sh"
    CULL_COLONIES="${RESEARCH_CULL_COLONIES:-explorer}"
    if [ "$AP_ENABLED" != "1" ]; then
        emit_step "auto-promote sidecar: disabled via RESEARCH_AUTO_PROMOTE=$AP_ENABLED"
        # Write .auto-promote-install.toml so the dashboard's sidecar
        # liveness probe (#248 / #378 / #699) sees installed=true,
        # enabled=false instead of treating a healthy disable as orphan
        # state. Schema matches dev-apprenticeship/install.sh:864-899
        # for parser compatibility (federation-dashboard-collector.py
        # parses [auto_promote] with underscore).
        emit_cmd "printf '# Auto-promote scheduler settings (#148 / #216 / #699).\n#\n# Written by research-foundry/tools/run-research.sh at sidecar spawn.\n# Read by federation-dashboard to derive HEALTHY / DEGRADED banner.\n[auto_promote]\nenabled = false\ninterval_s = $AP_INTERVAL\n' > $LAPTOP_DIR/.auto-promote-install.toml"
        return 0
    fi
    AP_SCRIPT="$REPO_ROOT/tools/auto-promote.sh"
    AP_CONFIG="$REPO_ROOT/tools/auto-promote-config.research-foundry.yaml"
    AP_LOG_DIR="$LAPTOP_DIR/.agentis/logs"
    AP_LOG="$AP_LOG_DIR/auto-promote.log"
    AP_STAMP="$AP_LOG_DIR/auto-promote.sidecar_started_at"
    if [ ! -x "$AP_SCRIPT" ]; then
        emit_step "auto-promote sidecar: $AP_SCRIPT not executable, skipping"
        return 0
    fi
    if [ ! -f "$AP_CONFIG" ]; then
        emit_step "auto-promote sidecar: $AP_CONFIG missing, skipping"
        return 0
    fi
    emit_step "starting auto-promote sidecar (interval=${AP_INTERVAL}s, log=$AP_LOG)"
    if [ "$CULL_ENABLED" = "1" ]; then
        emit_step "cull-replicas cycle: enabled (colonies=$CULL_COLONIES every $CULL_INTERVAL_TICKS sidecar ticks; bottom_pct=$CULL_BOTTOM_PCT, min_explorers=$CULL_MIN_EXPLORERS, min_acting=$CULL_MIN_ACTING)"
    else
        emit_step "cull-replicas cycle: disabled (RESEARCH_CULL_ENABLED=$CULL_ENABLED)"
    fi
    # Write .auto-promote-install.toml so the dashboard's sidecar
    # liveness probe (#248 / #378 / #699) sees installed=true and the
    # configured interval instead of reporting running_orphan=true /
    # status="orphan". Schema matches dev-apprenticeship/install.sh:864-899
    # for parser compatibility (federation-dashboard-collector.py parses
    # [auto_promote] with underscore at line 906). Emitted via emit_cmd
    # so the write surfaces in both the dry-run transcript and the real
    # orchestrator log; the cleanup trap installed above removes the
    # file on EXIT/INT/TERM.
    emit_cmd "printf '# Auto-promote scheduler settings (#148 / #216 / #699).\n#\n# Written by research-foundry/tools/run-research.sh at sidecar spawn.\n# Read by federation-dashboard to derive HEALTHY / DEGRADED banner.\n[auto_promote]\nenabled = true\ninterval_s = $AP_INTERVAL\n' > $LAPTOP_DIR/.auto-promote-install.toml"
    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "auto-promote-sidecar placeholder: cwd=$LAPTOP_DIR config=$AP_CONFIG interval=${AP_INTERVAL}s"
        if [ "$CULL_ENABLED" = "1" ]; then
            emit_cmd "cull-replicas placeholder: script=$CULL_SCRIPT colonies=$CULL_COLONIES every=${CULL_INTERVAL_TICKS} ticks bottom_pct=$CULL_BOTTOM_PCT min_explorers=$CULL_MIN_EXPLORERS min_acting=$CULL_MIN_ACTING"
        fi
        return 0
    fi
    mkdir -p "$AP_LOG_DIR"
    date +%s > "$AP_STAMP"
    (
        # Disable set -e/pipefail inherited from parent — supervisor loop must
        # survive transient child SIGTERM (e.g. operator-side agentis upgrade
        # pkill cascade, #728 Layer 1).
        set +e
        set +o pipefail
        cd "$LAPTOP_DIR"
        tick_count=0
        while :; do
            if ! agentis daemon list --json 2>/dev/null | grep -Fq '"state":"running"'; then
                printf '=== %s: no running daemons; sidecar exiting ===\n' \
                    "$(date -Iseconds)" >> "$AP_LOG"
                exit 0
            fi
            {
                printf '=== %s: sidecar tick ===\n' "$(date -Iseconds)"
                "$AP_SCRIPT" "$LAPTOP_DIR" --containerized --config "$AP_CONFIG" 2>&1 \
                    || printf '[sidecar] auto-promote.sh exited %s\n' "$?"
            } >> "$AP_LOG"
            tick_count=$((tick_count + 1))
            if [ "$CULL_ENABLED" = "1" ] && [ -x "$CULL_SCRIPT" ] \
                    && [ $((tick_count % CULL_INTERVAL_TICKS)) -eq 0 ]; then
                # Phase 9 PR-B (#663): iterate every colony in
                # $CULL_COLONIES so the cull cycle can target each role
                # independently. Default `explorer` preserves the
                # pre-PR-B behaviour.
                IFS=',' read -ra cull_colony_arr <<< "$CULL_COLONIES"
                {
                    printf '=== %s: cull tick (#%d) ===\n' "$(date -Iseconds)" "$tick_count"
                    for cull_colony in "${cull_colony_arr[@]}"; do
                        cull_colony="$(printf '%s' "$cull_colony" | tr -d '[:space:]')"
                        [ -z "$cull_colony" ] && continue
                        printf '--- cull colony=%s ---\n' "$cull_colony"
                        "$CULL_SCRIPT" "$LAPTOP_DIR" "$cull_colony" \
                            --bottom-pct "$CULL_BOTTOM_PCT" \
                            --min-explorers "$CULL_MIN_EXPLORERS" \
                            --min-acting "$CULL_MIN_ACTING" 2>&1 \
                            || printf '[sidecar] cull-replicas.sh exited %s for colony=%s\n' "$?" "$cull_colony"
                    done
                } >> "$AP_LOG"
            fi
            sleep "$AP_INTERVAL"
        done
    ) &
    AUTO_PROMOTE_PID=$!
    emit_step "auto-promote sidecar PID=$AUTO_PROMOTE_PID"
}

# --- 5) Tick stream (main research loop) ---
# For each tick:
#   1. Pick the next topic (round-robin over RESEARCH_TOPICS).
#   2. Sample two distinct papers from the topic's cached corpus.
#   3. Seed `replay:current_*` memo keys read by explorer.ag.
#   4. For each explorer daemon_id 1..N, look up its specialty in the
#      bootstrap-seeded `explorer:pool:specialty:<N>` memo, map specialty
#      to topic via `_explorer_topic_for_specialty`, sample 2 papers
#      from that topic's corpus, and write per-daemon memos:
#        `replay:explorer_topic:daemon:<N>`
#        `replay:explorer_topic_desc:daemon:<N>`
#        `replay:explorer_compute_hints:daemon:<N>`
#        `replay:explorer_paper_{a,b}_{id,title,abstract}:daemon:<N>`
#      Explorer reads its per-daemon memo first (keyed by `$DAEMON_ID`),
#      falls back to the global `replay:current_*` keys when empty.
#   5. Sleep RESEARCH_TICK_INTERVAL_S seconds.
# The 9-10-tick cascade through 14 downstream daemons (noticer -->
# formulator --> verifier --> novelty --> 4 searchers --> auditor -->
# introducer + theorist + computer --> editor --> submitter) happens
# inside the merged container because all daemons share /run-root/
# .agentis/. Each agent reads its upstream colleague's memo directly --
# no cross-fed JSONL reconstruction.
#
# Per-explorer specialty -> topic mapping table (#719).
# Aligns the 5 seeded explorer specialties with the 4 default
# research topics; `algebra` intentionally overlaps with
# `group_theory` (both abstract_algebra). Probability routes to
# graph_theory rather than combinatorics so 4 distinct topics
# are covered across 5 explorers per tick.
#     group_theory   -> abstract_algebra
#     combinatorics  -> combinatorics
#     number_theory  -> number_theory
#     probability    -> graph_theory
#     algebra        -> abstract_algebra
# Unmapped specialties (evolved variants with novel labels)
# return empty -- per-daemon memo write is skipped and the
# explorer falls back to the global `replay:current_topic`.
_explorer_topic_for_specialty() {
    case "$1" in
        group_theory)   echo "abstract_algebra" ;;
        combinatorics)  echo "combinatorics" ;;
        number_theory)  echo "number_theory" ;;
        probability)    echo "graph_theory" ;;
        algebra)        echo "abstract_algebra" ;;
        *)              echo "" ;;
    esac
}
tick_stream() {
    emit_step "starting tick stream (interval=${TICK_INTERVAL_S}s total=${TOTAL_TICKS})"
    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "python3 -c 'research-loop placeholder: topics=$TOPICS_RAW total_ticks=$TOTAL_TICKS interval=$TICK_INTERVAL_S' # tick loop runs in real mode"
        return
    fi
    python3 - "$TOPICS_RAW" "$PAPER_CORPUS" "$TOTAL_TICKS" "$TICK_INTERVAL_S" "$RUN_DIR" "$RESEARCH_EXPLORER_REPLICAS" <<'PYRESEARCH'
import glob
import json
import os
import random
import re
import subprocess
import sys
import time

topics_raw, paper_corpus, total_ticks, interval, run_dir, explorer_replicas = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]),
    int(sys.argv[4]), sys.argv[5], int(sys.argv[6]),
)
topics = [t.strip() for t in topics_raw.split(",") if t.strip()]
if not topics:
    sys.stderr.write("research-loop: no topics\n")
    sys.exit(2)

# Per-explorer specialty -> topic mapping (#719). Keep in sync with
# `_explorer_topic_for_specialty` (above) and the variants in
# `tools/colony-variants.json`. Empty result -> per-daemon memo write
# skipped; explorer falls back to global `replay:current_topic`.
SPECIALTY_TOPIC_MAP = {
    "group_theory": "abstract_algebra",
    "combinatorics": "combinatorics",
    "number_theory": "number_theory",
    "probability": "graph_theory",
    "algebra": "abstract_algebra",
}

corpora = {}
for topic in topics:
    path = os.path.join(paper_corpus, topic + ".json")
    if not os.path.isfile(path):
        sys.stderr.write(
            "research-loop: missing corpus for topic '" + topic + "' at " + path + "\n"
        )
        sys.exit(3)
    with open(path) as f:
        try:
            data = json.load(f)
        except Exception as e:
            sys.stderr.write("research-loop: " + path + " not valid JSON: " + str(e) + "\n")
            sys.exit(3)
    papers = data.get("papers") or []
    if len(papers) < 2:
        sys.stderr.write(
            "research-loop: corpus '" + topic + "' needs at least 2 papers (has "
            + str(len(papers)) + ")\n"
        )
        sys.exit(3)
    corpora[topic] = data


def _memo_set(key, value):
    subprocess.run(
        ["podman", "exec", "research-foundry-laptop", "agentis", "memo", "set", key, value],
        check=False,
    )


def _memo_get(key):
    proc = subprocess.run(
        ["podman", "exec", "research-foundry-laptop", "agentis", "memo", "get", key],
        check=False, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return ""
    out = (proc.stdout or "").strip()
    # `agentis memo get` returns `<error>` style sentinel on miss in some builds.
    if not out or out.startswith("<"):
        return ""
    return out


log_path = os.path.join(run_dir, "orchestrator.log")
rng = random.Random(0xF0FF)
# Per-daemon paper-pair sampling uses a derived RNG so a given (tick,
# daemon_id) draws a deterministic pair from its mapped topic.
for idx in range(total_ticks):
    topic = topics[idx % len(topics)]
    data = corpora[topic]
    papers = data["papers"]
    a, b = rng.sample(papers, 2)
    memo_pairs = [
        ("replay:current_tick", str(idx)),
        ("replay:current_topic", topic),
        ("replay:current_topic_desc", data.get("description", "")),
        ("replay:current_compute_hints", data.get("compute_hints", "sympy, numpy, networkx")),
        ("replay:current_paper_a_id", str(a.get("id", ""))),
        ("replay:current_paper_a_title", str(a.get("title", ""))),
        ("replay:current_paper_a_abstract", str(a.get("abstract", ""))),
        ("replay:current_paper_b_id", str(b.get("id", ""))),
        ("replay:current_paper_b_title", str(b.get("title", ""))),
        ("replay:current_paper_b_abstract", str(b.get("abstract", ""))),
    ]
    for key, value in memo_pairs:
        _memo_set(key, value)

    # Per-explorer (per-DAEMON_ID) topic pinning (#719, #724). Map each
    # explorer's bootstrap-seeded specialty to a topic, sample 2 papers
    # from that topic's corpus, and seed per-daemon memo keys. Explorers
    # whose specialty has no mapping (evolved variants with novel
    # labels) get no per-daemon write -- they fall back to the global
    # `replay:current_*` keys above.
    #
    # #724: enumerate live daemon ids from the specialty-memo glob
    # instead of a hardcoded range. `cull-replicas.sh` writes specialty
    # memos for post-cull replica explorers (daemon_id > initial
    # explorer_replicas), so the orchestrator must read whoever is
    # actually present on disk. The regex filters out the sibling
    # `explorer:pool:specialty_overlay:*.jsonl` files (decoys with a
    # non-numeric suffix after the colon).
    _memo_dir = os.path.join(run_dir, "laptop-node", ".agentis", "memo")
    _spec_re = re.compile(r"^explorer:pool:specialty:(\d+)\.jsonl$")
    daemon_ids = []
    for _path in glob.glob(os.path.join(_memo_dir, "explorer:pool:specialty:*.jsonl")):
        m = _spec_re.match(os.path.basename(_path))
        if m:
            daemon_ids.append(int(m.group(1)))
    daemon_ids.sort()
    per_daemon_log = []
    for daemon_id in daemon_ids:
        specialty = _memo_get("explorer:pool:specialty:" + str(daemon_id))
        mapped_topic = SPECIALTY_TOPIC_MAP.get(specialty, "")
        if not mapped_topic or mapped_topic not in corpora:
            per_daemon_log.append(
                "daemon=" + str(daemon_id) + " specialty=" + (specialty or "?") + " topic=<fallback>"
            )
            continue
        topic_data = corpora[mapped_topic]
        topic_papers = topic_data["papers"]
        d_rng = random.Random(0xF0FF ^ (idx * 1009 + daemon_id))
        if len(topic_papers) >= 2:
            pa, pb = d_rng.sample(topic_papers, 2)
        else:
            pa = pb = topic_papers[0]
        suffix = ":daemon:" + str(daemon_id)
        per_daemon_pairs = [
            ("replay:explorer_topic" + suffix, mapped_topic),
            ("replay:explorer_topic_desc" + suffix, topic_data.get("description", "")),
            ("replay:explorer_compute_hints" + suffix,
             topic_data.get("compute_hints", "sympy, numpy, networkx")),
            ("replay:explorer_paper_a_id" + suffix, str(pa.get("id", ""))),
            ("replay:explorer_paper_a_title" + suffix, str(pa.get("title", ""))),
            ("replay:explorer_paper_a_abstract" + suffix, str(pa.get("abstract", ""))),
            ("replay:explorer_paper_b_id" + suffix, str(pb.get("id", ""))),
            ("replay:explorer_paper_b_title" + suffix, str(pb.get("title", ""))),
            ("replay:explorer_paper_b_abstract" + suffix, str(pb.get("abstract", ""))),
        ]
        for key, value in per_daemon_pairs:
            _memo_set(key, value)
        per_daemon_log.append(
            "daemon=" + str(daemon_id) + " specialty=" + specialty + " topic=" + mapped_topic
        )

    with open(log_path, "a") as log:
        log.write(
            "# tick " + str(idx) + "/" + str(total_ticks)
            + " topic=" + topic + " papers=" + str(a.get("id"))
            + "," + str(b.get("id")) + "\n"
        )
        if per_daemon_log:
            log.write("#   per-explorer: " + "; ".join(per_daemon_log) + "\n")
    time.sleep(interval)
PYRESEARCH
}

# --- 6) Shutdown signal ---
signal_shutdown() {
    emit_step "signalling shutdown (touch /run-root/.shutdown)"
    emit_cmd "podman exec research-foundry-laptop touch /run-root/.shutdown 2>/dev/null || true"
}

# --- 7) run-meta.json ---
write_run_meta() {
    emit_step "writing run-meta.json"
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    emit_cmd "python3 -c 'import json; json.dump({\"started_at\":\"$started_at\",\"topics\":\"$TOPICS_RAW\",\"total_ticks\":$TOTAL_TICKS,\"tick_interval_s\":$TICK_INTERVAL_S,\"daemons_per_colony\":$DAEMONS_PER_COLONY,\"hold_period\":$HOLD_PERIOD,\"llm_backend\":\"$LLM_BACKEND\",\"claude_model\":\"$CLAUDE_MODEL\",\"confidence_floor\":$CONFIDENCE_FLOOR,\"latexmk_max_passes\":$LATEXMK_MAX_PASSES,\"image_tag\":\"$IMAGE_TAG\",\"arxiv_gateway\":\"$ARXIV_GATEWAY\",\"hitl_required\":True}, open(\"$RUN_META\",\"w\"), indent=2)'"
}

# --- Orchestration body ---
install_cleanup_trap
build_image
write_bootstrap
write_run_meta
spawn_container
start_auto_promote_sidecar
tick_stream

if [ "$DRY_RUN" = "1" ]; then
    emit_step "dry-run complete; no container spawned"
    exit 0
fi

signal_shutdown

# Phase 5 PR-A (#626): snapshot curated memo namespaces into the
# per-federation persistent dir so PR-B can read fittest-specialty +
# learned-pitfall state at the next bootstrap. PR-C will aggregate
# cross-run fitness across snapshots. Treated as non-fatal -- a failed
# snapshot must not break the shutdown path.
if [ "$PERSISTENT_DISABLED" != "1" ]; then
    emit_step "snapshotting persistent memo to $PERSISTENT_DIR"
    if ! python3 "$TOOLS_DIR/persistent-snapshot.py" \
            --container research-foundry-laptop \
            --output-dir "$PERSISTENT_DIR" >>"$ORCH_LOG" 2>&1; then
        emit_step "persistent snapshot failed (non-fatal); continuing shutdown"
    fi
fi

# Phase 5 PR-C (#626): cross-run fitness aggregation. Runs the same
# per-pid decision pipeline as the auto-promote sidecar -- including
# the PR-B `evidence.colony_fitness.{specialty, fitness_score}`
# enrichment -- against the still-running container, then appends one
# record to `persistent/run-history.jsonl` and re-derives
# `persistent/fittest_specialties.json` from the last
# RESEARCH_CROSS_RUN_WINDOW records (default 5) with exponential decay
# (factor 0.7). Treated as non-fatal -- if the helper fails the run
# still completes cleanly. The decisions JSON the helper prints to
# stdout is silently discarded here; the side-effect on the
# persistent dir is the only thing we want at run-end.
if [ "$PERSISTENT_DISABLED" != "1" ]; then
    emit_step "aggregating cross-run fitness to $PERSISTENT_DIR (window=$CROSS_RUN_WINDOW)"
    PRC_AP_CONFIG="$REPO_ROOT/tools/auto-promote-config.research-foundry.yaml"
    if [ ! -f "$PRC_AP_CONFIG" ]; then
        emit_step "cross-run aggregation: $PRC_AP_CONFIG missing, skipping"
    else
        PRC_DAEMONS_JSON=$(podman exec research-foundry-laptop \
            agentis daemon list --json 2>/dev/null || echo "[]")
        if ! python3 "$REPO_ROOT/tools/auto-promote-decisions.py" \
                --preview --config "$PRC_AP_CONFIG" --containerized \
                --cross-run \
                --window "$CROSS_RUN_WINDOW" \
                --persistent-dir "$PERSISTENT_DIR" \
                "$PRC_DAEMONS_JSON" "$LAPTOP_DIR" \
                >>"$ORCH_LOG" 2>&1; then
            emit_step "cross-run aggregation failed (non-fatal); continuing"
        fi
        unset PRC_AP_CONFIG PRC_DAEMONS_JSON
    fi
fi

emit_step "run-research: done"
echo "[run-research] run dir: $RUN_DIR"
