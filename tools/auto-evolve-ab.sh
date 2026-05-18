#!/usr/bin/env bash
# auto-evolve-ab.sh — Phase 7 PR-A plumbing for self-improving .ag
# mutation harness (#628).
#
# Invoked by `tools/auto-promote.sh` when
# `evolve.mutation.enabled = true` in the active auto-promote-config.
# When the flag is false (the default) the legacy `agentis evolve`
# path runs instead — see auto-promote.sh evolve handler.
#
# Pipeline (PR-A, mutator stubbed):
#   1. Pre-flight throttle: count open candidate files in
#      `<colony>/agents/.evolve/`; abort with `evolve_throttled` ledger
#      row when the cap is hit.
#   2. Generate stub candidate: copy parent .ag to
#      `<colony>/agents/.evolve/<agent>.ag.candidate-gen-N` with a
#      trivial cosmetic comment. PR-B replaces this with the real
#      LLM-driven mutator (`auto-evolve-mutate.py`).
#   3. Validity gate (3 checks): `agentis commit` succeeds, tier
#      coverage regex passes (mirroring colony-lint.sh §475-490), and
#      a `cb <N>;` budget line is present. On failure, write a
#      `mutation_rejected` ledger row + exit.
#   4. PR-A skip: do NOT actually run A/B (no daemon spawn / score
#      comparison yet). Log `ab_skipped_pr_a_stub` ledger row to mark
#      the placeholder. PR-B fills this in.
#   5. Cleanup: remove the stub candidate. When `evolve.dry_run=true`,
#      do NOT archive the parent or respawn. When false (PR-C scope),
#      archive parent to `<fed-dir>/<archive_dir>/<agent>-gen-N-<sha8>.ag`.
#
# Usage:
#   tools/auto-evolve-ab.sh <fed-dir> <agent-name> <colony> <parent-ag-path>
#       [--ticks K] [--config <yaml>] [--dry-run]
#
# Exit codes:
#   0 — success (ledger written, regardless of decision)
#   1 — usage / arg error
#   2 — config / parser error
#
# Out of scope for PR-A:
#   - real LLM mutation (deferred to PR-B `auto-evolve-mutate.py`)
#   - A/B daemon spawn + score comparison (PR-B)
#   - flipping `evolve.dry_run=false` (PR-C)

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 <fed-dir> <agent-name> <colony> <parent-ag-path>"
    echo "          [--ticks K] [--config <yaml>] [--dry-run]"
    exit 1
}

if [ $# -lt 4 ]; then
    usage
fi

FED_DIR="$1"
AGENT_NAME="$2"
COLONY="$3"
PARENT_AG="$4"
shift 4

AB_TICKS_OVERRIDE=""
CONFIG_OVERRIDE=""
DRY_RUN_FORCE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --ticks)
            if [ $# -lt 2 ]; then
                echo "auto-evolve-ab: --ticks requires a value" >&2
                exit 1
            fi
            AB_TICKS_OVERRIDE="$2"
            shift 2
            ;;
        --config)
            if [ $# -lt 2 ]; then
                echo "auto-evolve-ab: --config requires a path argument" >&2
                exit 1
            fi
            CONFIG_OVERRIDE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN_FORCE=true
            shift
            ;;
        *)
            echo "auto-evolve-ab: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [ ! -d "$FED_DIR" ]; then
    echo "auto-evolve-ab: federation dir not found: $FED_DIR" >&2
    exit 1
fi
if [ ! -f "$PARENT_AG" ]; then
    echo "auto-evolve-ab: parent .ag file not found: $PARENT_AG" >&2
    exit 1
fi

# Resolve config path: --config wins; otherwise default to the
# adjacent default config. Same resolution rule as auto-promote.sh
# (#622): try repo-root-relative first, then verbatim.
if [ -n "$CONFIG_OVERRIDE" ]; then
    if [ -f "$REPO_ROOT/$CONFIG_OVERRIDE" ]; then
        CONFIG_FILE="$REPO_ROOT/$CONFIG_OVERRIDE"
    else
        CONFIG_FILE="$CONFIG_OVERRIDE"
    fi
else
    CONFIG_FILE="$SCRIPT_DIR/auto-promote-config.yaml"
fi
if [ ! -f "$CONFIG_FILE" ]; then
    echo "auto-evolve-ab: config not found: $CONFIG_FILE" >&2
    exit 2
fi

# Parse config — same parser as auto-promote.sh sidecar. Pulls the
# `CFG_EVOLVE_*` set added in PR-A's parser update.
eval "$(python3 "$SCRIPT_DIR/auto-promote-config-parser.py" "$CONFIG_FILE")"

# CLI --dry-run forces dry-run regardless of config.
if [ "$DRY_RUN_FORCE" = "true" ]; then
    EVOLVE_DRY_RUN="true"
else
    EVOLVE_DRY_RUN="$CFG_EVOLVE_DRY_RUN"
fi

# --ticks overrides config-driven AB ticks; otherwise fall back.
if [ -n "$AB_TICKS_OVERRIDE" ]; then
    AB_TICKS="$AB_TICKS_OVERRIDE"
else
    AB_TICKS="$CFG_EVOLVE_AB_TICKS"
fi

LEDGER_PATH="$FED_DIR/$CFG_EVOLVE_LEDGER_PATH"
ARCHIVE_DIR="$FED_DIR/$CFG_EVOLVE_ARCHIVE_DIR"
EVOLVE_DIR="$FED_DIR/$COLONY/agents/.evolve"

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] auto-evolve-ab: $*"
}

# Append a ledger row. Args:
#   1: event name (evolve_cycle | mutation_rejected | evolve_throttled |
#      ab_inconclusive | ab_skipped_pr_a_stub)
#   2: extras JSON (object literal merged into the base record)
# The base record always carries ts, event, agent, colony, generation,
# parent_sha8, ab_ticks, dry_run so downstream tooling can rely on
# those fields being present on every row.
ledger_append() {
    local event="$1"
    local extras_json="$2"
    mkdir -p "$(dirname "$LEDGER_PATH")"
    python3 "$SCRIPT_DIR/auto-evolve-ab-ledger.py" \
        "$LEDGER_PATH" "$event" \
        "$AGENT_NAME" "$COLONY" \
        "$GENERATION_NEXT" "$PARENT_SHA" \
        "$AB_TICKS" "$EVOLVE_DRY_RUN" \
        "$extras_json" >> "$LEDGER_PATH"
}

# ------------------------------------------------------------------
# 0. Resolve parent_sha + generation_current
# ------------------------------------------------------------------

PARENT_SHA=$(python3 -c "
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    print(hashlib.sha256(f.read()).hexdigest())
" "$PARENT_AG")
PARENT_SHA8="${PARENT_SHA:0:8}"

# Read current generation from the ledger if it exists. Mirrors the
# scan in auto-promote-decisions.py so the two agree on `generation_current`.
GENERATION_CURRENT=$(python3 -c "
import json, os, sys
ledger = sys.argv[1]
sha = sys.argv[2]
sha8 = sha[:8]
max_gen = 0
if os.path.isfile(ledger):
    with open(ledger) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if not isinstance(row, dict):
                continue
            if row.get('parent_sha8') != sha8 and row.get('parent_sha') != sha:
                continue
            g = row.get('generation')
            try:
                gi = int(g) if g is not None else 0
            except (ValueError, TypeError):
                gi = 0
            if gi > max_gen:
                max_gen = gi
print(max_gen)
" "$LEDGER_PATH" "$PARENT_SHA")
GENERATION_NEXT=$((GENERATION_CURRENT + 1))

log "Starting (agent=$AGENT_NAME colony=$COLONY parent_sha8=$PARENT_SHA8 gen_next=$GENERATION_NEXT dry_run=$EVOLVE_DRY_RUN)"

# ------------------------------------------------------------------
# 0a. Generation cap check
# ------------------------------------------------------------------

if [ "$GENERATION_NEXT" -gt "$CFG_EVOLVE_MUTATION_MAX_GENERATIONS" ]; then
    log "  generation cap reached: next=$GENERATION_NEXT > max=$CFG_EVOLVE_MUTATION_MAX_GENERATIONS"
    ledger_append "evolve_throttled" "{\"reason\":\"max_generations_reached\",\"max_generations\":$CFG_EVOLVE_MUTATION_MAX_GENERATIONS}"
    exit 0
fi

# ------------------------------------------------------------------
# 1. Pre-flight throttle: count open candidate files
# ------------------------------------------------------------------

mkdir -p "$EVOLVE_DIR"
OPEN_COUNT=$(find "$EVOLVE_DIR" -maxdepth 1 -name "*.candidate-gen-*" -type f 2>/dev/null | wc -l)
OPEN_COUNT=$((OPEN_COUNT + 0))

if [ "$OPEN_COUNT" -ge "$CFG_EVOLVE_MUTATION_MAX_CONCURRENT_PER_COLONY" ]; then
    log "  throttle: $OPEN_COUNT open candidates >= max=$CFG_EVOLVE_MUTATION_MAX_CONCURRENT_PER_COLONY"
    ledger_append "evolve_throttled" "{\"open_candidates\":$OPEN_COUNT,\"max_concurrent_per_colony\":$CFG_EVOLVE_MUTATION_MAX_CONCURRENT_PER_COLONY}"
    exit 0
fi

# ------------------------------------------------------------------
# 2. Generate stub candidate (PR-A placeholder for LLM mutator)
# ------------------------------------------------------------------

CANDIDATE_PATH="$EVOLVE_DIR/${AGENT_NAME}.ag.candidate-gen-${GENERATION_NEXT}"
# Stub mutation: copy parent + append a cosmetic comment. PR-B replaces
# this block with the real `tools/auto-evolve-mutate.py` LLM call.
cp "$PARENT_AG" "$CANDIDATE_PATH"
printf '\n// Stub mutation generated by PR-A (#628) — replaced by LLM mutator in PR-B\n' >> "$CANDIDATE_PATH"

CANDIDATE_SHA=$(python3 -c "
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    print(hashlib.sha256(f.read()).hexdigest())
" "$CANDIDATE_PATH")
CANDIDATE_SHA8="${CANDIDATE_SHA:0:8}"

log "  stub candidate written: $CANDIDATE_PATH (sha8=$CANDIDATE_SHA8)"

# ------------------------------------------------------------------
# 3. Validity gate (3 checks)
# ------------------------------------------------------------------

VALIDITY_FAILS=""

# 3a. `agentis commit <candidate>` succeeds. Mirrors the colony-lint
# pattern (#177): bootstrap a temp .agentis/ once via `agentis init`
# so `agentis commit` doesn't error out with "Not an Agentis repository".
VALIDITY_TMP="$(mktemp -d)"
if command -v agentis >/dev/null 2>&1; then
    (cd "$VALIDITY_TMP" && agentis init >/dev/null 2>&1) || true
    if ! (cd "$VALIDITY_TMP" && agentis commit "$CANDIDATE_PATH") >/dev/null 2>&1; then
        VALIDITY_FAILS="$VALIDITY_FAILS agentis_commit_failed"
    fi
else
    # agentis not on PATH — record but don't hard-fail. The smoke test
    # exercises this branch and downstream pipelines must still write
    # a ledger row for visibility.
    VALIDITY_FAILS="$VALIDITY_FAILS agentis_binary_missing"
fi
rm -rf "$VALIDITY_TMP"

# 3b. Tier-coverage regex (mirrors colony-lint.sh:475-490). The
# canonical pattern collapses shadow into the else-fallthrough, so we
# require the three explicit tier literals (propose / review-gated /
# autonomous) plus at least one tier(...) call.
TIER_OK=true
if ! grep -qE '\btier\s*\(\s*"[^"]+"\s*\)' "$CANDIDATE_PATH" \
    && ! grep -qE '\brepo_tier\s*\(\s*"[^"]+"\s*,' "$CANDIDATE_PATH"; then
    TIER_OK=false
fi
for tier_name in propose review-gated autonomous; do
    if ! grep -qE "\"$tier_name\"" "$CANDIDATE_PATH"; then
        TIER_OK=false
    fi
done
if ! $TIER_OK; then
    VALIDITY_FAILS="$VALIDITY_FAILS tier_coverage_missing"
fi

# 3c. `cb <N>;` budget line present at the top.
if ! grep -qE '^\s*cb\s+[0-9]+\s*;' "$CANDIDATE_PATH"; then
    VALIDITY_FAILS="$VALIDITY_FAILS cb_budget_missing"
fi

if [ -n "$VALIDITY_FAILS" ]; then
    # Normalise leading space for the ledger extras JSON.
    VALIDITY_FAILS_CSV=$(echo "$VALIDITY_FAILS" | sed 's/^ //;s/ /,/g')
    log "  validity gate failed: $VALIDITY_FAILS_CSV"
    ledger_append "mutation_rejected" \
        "{\"candidate_sha8\":\"$CANDIDATE_SHA8\",\"reason\":\"validity_gate\",\"failed_checks\":\"$VALIDITY_FAILS_CSV\"}"
    rm -f "$CANDIDATE_PATH"
    exit 0
fi

log "  validity gate passed"

# ------------------------------------------------------------------
# 4. A/B spawn (PR-A stub: log placeholder + skip)
# ------------------------------------------------------------------

log "  A/B run skipped in PR-A (placeholder); PR-B wires real spawn + scoring"
ledger_append "ab_skipped_pr_a_stub" \
    "{\"candidate_sha8\":\"$CANDIDATE_SHA8\",\"note\":\"PR-A plumbing only; A/B harness lives in PR-B\"}"

# ------------------------------------------------------------------
# 5. Cleanup
# ------------------------------------------------------------------

if [ "$EVOLVE_DRY_RUN" = "true" ]; then
    log "  dry-run: removing stub candidate, no archive, no respawn"
    rm -f "$CANDIDATE_PATH"
else
    # PR-C scope: archive parent + respawn daemon. Plumbed here so the
    # interface is stable but unreachable until PR-C flips dry_run off.
    mkdir -p "$ARCHIVE_DIR"
    ARCHIVE_PATH="$ARCHIVE_DIR/${AGENT_NAME}-gen-${GENERATION_NEXT}-${PARENT_SHA8}.ag"
    cp "$PARENT_AG" "$ARCHIVE_PATH"
    log "  archived parent to $ARCHIVE_PATH"
    rm -f "$CANDIDATE_PATH"
fi

log "Done."
