#!/usr/bin/env bash
# auto-evolve-ab.sh — Phase 7 PR-B harness for self-improving .ag
# mutation + A/B comparison (#628).
#
# Invoked by `tools/auto-promote.sh` when
# `evolve.mutation.enabled = true` in the active auto-promote-config.
# When the flag is false (the default) the legacy `agentis evolve`
# path runs instead — see auto-promote.sh evolve handler.
#
# Pipeline (PR-B):
#   1. Pre-flight throttle: count open candidate files in
#      `<colony>/agents/.evolve/`; abort with `evolve_throttled` ledger
#      row when the cap is hit.
#   2. LLM-driven mutation: invoke `tools/auto-evolve-mutate.py` with
#      the parent .ag + recent experience window. Captures the
#      candidate + a one-line rationale. On mutator failure / shape
#      rejection, write a `mutation_rejected` ledger row + exit.
#   3. Validity gate (4 checks): `agentis commit` succeeds, tier
#      coverage regex passes (mirroring colony-lint.sh §475-490),
#      a `cb <N>;` budget line is present, and the rationale file is
#      non-empty. On failure, write `mutation_rejected` + exit.
#   4. A/B daemon spawn (containerized-only): spawn the candidate
#      daemon under a synthetic agent_id `<agent>-cand-gen-<N>` so its
#      experience writes go to an isolated .jsonl. Wait K ticks
#      bounded by `ab.absolute_max_wait_s`. Score candidate vs
#      canonical via `auto-promote-decisions.py --preview` +
#      `explorer-fitness.py` (or fallback proxy
#      `(acting - reject) / max(acting, 1)`). Compare with
#      `ab.min_delta`. Emit `evolve_cycle` (winner candidate /
#      canonical) or `ab_inconclusive` ledger row.
#   5. Promote winner (DRY-RUN AWARE): when `evolve.dry_run=true`, log
#      and stop. When false (PR-C), if candidate wins: stop candidate,
#      archive parent to
#      `<fed-dir>/<archive_dir>/<agent>-gen-N-<sha8>.ag`, `mv -f`
#      candidate over canonical, respawn canonical daemon. Cleanup
#      always removes the .evolve/ candidate + synthetic experience.
#
# Usage:
#   tools/auto-evolve-ab.sh <fed-dir> <agent-name> <colony> <parent-ag-path>
#       [--ticks K] [--config <yaml>] [--dry-run] [--containerized]
#
# Exit codes:
#   0 — success (ledger written, regardless of decision)
#   1 — usage / arg error
#   2 — config / parser error
#
# Out of scope for PR-B:
#   - flipping `evolve.dry_run=false` for explorer (deferred to PR-C)
#   - bundle-manifest wiring (deferred to PR-C alongside the flip)

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 <fed-dir> <agent-name> <colony> <parent-ag-path>"
    echo "          [--ticks K] [--config <yaml>] [--dry-run] [--containerized]"
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
CONTAINERIZED=false
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
        --containerized)
            CONTAINERIZED=true
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
#      ab_inconclusive | ab_skipped_pr_a_stub | ab_spawn_failed)
#   2: extras JSON (object literal merged into the base record)
# The base record always carries ts, event, agent, colony, generation,
# parent_sha8, ab_ticks, dry_run so downstream tooling can rely on
# those fields being present on every row.
ledger_append() {
    local event="$1"
    local extras_json="$2"
    mkdir -p "$(dirname "$LEDGER_PATH")"
    python3 "$SCRIPT_DIR/auto-evolve-ab-ledger.py" \
        "$event" \
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
# 0b. Per-agent allowlist gate (PR-C, #628)
# ------------------------------------------------------------------
#
# `evolve.mutation.allowed_agents` is a comma-separated list emitted by
# the config parser. `*` is the legacy-compat sentinel meaning "all
# agents allowed" -- dev-apprenticeship + tribes-bench configs that
# omit the key fall through to that path. research-foundry pins it to
# `explorer` only; every other agent invocation short-circuits here.
ALLOWED_AGENTS_CSV="${CFG_EVOLVE_MUTATION_ALLOWED_AGENTS:-*}"
if [ "$ALLOWED_AGENTS_CSV" != "*" ]; then
    AGENT_ALLOWED=$(python3 -c "
import sys
csv = sys.argv[1]
agent = sys.argv[2]
items = [s.strip() for s in csv.split(',') if s.strip()]
print('true' if (agent in items or '*' in items) else 'false')
" "$ALLOWED_AGENTS_CSV" "$AGENT_NAME")
    if [ "$AGENT_ALLOWED" != "true" ]; then
        log "  agent not in allowlist: $AGENT_NAME (allowed=$ALLOWED_AGENTS_CSV)"
        ledger_append "evolve_skipped_not_in_allowlist" \
            "{\"reason\":\"agent_not_in_allowlist\",\"allowed_agents\":\"$ALLOWED_AGENTS_CSV\"}"
        exit 0
    fi
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
# 2. LLM-driven mutation
# ------------------------------------------------------------------

CANDIDATE_PATH="$EVOLVE_DIR/${AGENT_NAME}.ag.candidate-gen-${GENERATION_NEXT}"
RATIONALE_PATH="$EVOLVE_DIR/${AGENT_NAME}.ag.candidate-gen-${GENERATION_NEXT}.rationale.txt"

# Resolve the agent's experience .jsonl. Read by the mutator to compute
# the failure-mode summary that feeds the LLM prompt. The canonical
# layout is `<fed-dir>/.agentis/experience/<agent>.jsonl` (post-#622).
EXPERIENCE_PATH="$FED_DIR/.agentis/experience/${AGENT_NAME}.jsonl"
# A missing experience file is not fatal — the mutator tolerates an
# empty window and produces a no-failure-signal prompt.

# Window K mirrors `ab.min_acting_for_decision` so the mutator surfaces
# the same recent slice the A/B scorer will eventually consume.
MUT_WINDOW="${CFG_EVOLVE_AB_MIN_ACTING_FOR_DECISION:-10}"

set +e
MUT_OUTPUT=$(python3 "$SCRIPT_DIR/auto-evolve-mutate.py" \
    --ag "$PARENT_AG" \
    --experience "$EXPERIENCE_PATH" \
    --window "$MUT_WINDOW" \
    --target-gen "$GENERATION_NEXT" \
    --out "$CANDIDATE_PATH" \
    --rationale-out "$RATIONALE_PATH" \
    --config "$CONFIG_FILE" 2>&1)
MUT_RC=$?
set -e

if [ "$MUT_RC" -ne 0 ]; then
    # Mutator exit 2 = mutation_invalid_shape (LLM returned an
    # unparseable response). Exit 3 = mutator_failed (backend down).
    # Either way, surface the structured reason on the ledger.
    if [ "$MUT_RC" -eq 2 ]; then
        MUT_REASON="mutation_invalid_shape"
    else
        MUT_REASON="mutator_failed"
    fi
    log "  mutator rc=$MUT_RC reason=$MUT_REASON"
    # Strip control characters, drop the double-quote byte (34) so the
    # JSON ledger row doesn't fracture mid-string (#661), and clip stderr
    # to 500 chars so the row stays single-line. We deliberately use
    # python3 here, not sed/tr, so the macOS bash 3.2 quoting story stays
    # compatible.
    MUT_STDERR_CLIP=$(python3 -c "
import sys
buf = sys.argv[1].replace('\n', ' ')[:500]
print(''.join(c for c in buf if c == ' ' or (32 <= ord(c) < 127 and ord(c) != 34)))
" "$MUT_OUTPUT")
    ledger_append "mutation_rejected" \
        "{\"reason\":\"$MUT_REASON\",\"mutator_stderr\":\"$MUT_STDERR_CLIP\"}"
    rm -f "$CANDIDATE_PATH" "$RATIONALE_PATH"
    exit 0
fi

CANDIDATE_SHA=$(python3 -c "
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    print(hashlib.sha256(f.read()).hexdigest())
" "$CANDIDATE_PATH")
CANDIDATE_SHA8="${CANDIDATE_SHA:0:8}"

log "  candidate written: $CANDIDATE_PATH (sha8=$CANDIDATE_SHA8)"

# ------------------------------------------------------------------
# 3. Validity gate (4 checks)
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

# 3d. Rationale file is non-empty. PR-B adds this 4th check so a
# mutator that silently writes the candidate but drops the rationale
# (or a partial mutator failure) doesn't slip through the gate.
if [ ! -s "$RATIONALE_PATH" ]; then
    VALIDITY_FAILS="$VALIDITY_FAILS rationale_empty"
fi

if [ -n "$VALIDITY_FAILS" ]; then
    # Normalise leading space for the ledger extras JSON.
    VALIDITY_FAILS_CSV=$(echo "$VALIDITY_FAILS" | sed 's/^ //;s/ /,/g')
    log "  validity gate failed: $VALIDITY_FAILS_CSV"
    ledger_append "mutation_rejected" \
        "{\"candidate_sha8\":\"$CANDIDATE_SHA8\",\"reason\":\"validity_gate\",\"failed_checks\":\"$VALIDITY_FAILS_CSV\"}"
    rm -f "$CANDIDATE_PATH" "$RATIONALE_PATH"
    exit 0
fi

log "  validity gate passed"

# ------------------------------------------------------------------
# 4. A/B daemon spawn + score comparison
# ------------------------------------------------------------------
#
# Containerized mode only (research-foundry). Non-containerized
# federations keep the legacy `agentis evolve` path via auto-promote.sh
# (gated by `evolve.mutation.enabled`). When --containerized is omitted
# we log an `ab_inconclusive` row and skip — the A/B harness has no
# safe host-side spawn path today (the canonical daemon may be running
# under a different .agentis/ root and rerouting its experience writes
# is out of scope for PR-B).
#
# Synthetic agent_id: `<agent>-cand-gen-<N>`. The candidate's
# experience writes go to
# `<fed-dir>/.agentis/experience/<synthetic-id>.jsonl` and stay
# isolated from the canonical row.
SYNTHETIC_ID="${AGENT_NAME}-cand-gen-${GENERATION_NEXT}"
SYNTH_EXP="$FED_DIR/.agentis/experience/${SYNTHETIC_ID}.jsonl"

# Resolve A/B wait window. tick_interval default is 60000ms (matches
# the start-colony.sh fallback). The harness bounds the wait by
# `ab.absolute_max_wait_s` (default 1800s) so a misconfigured K can't
# pin the sidecar tick indefinitely.
TICK_INTERVAL_MS="${RESEARCH_DAEMON_TICK_INTERVAL_MS:-60000}"
WAIT_MS=$((AB_TICKS * TICK_INTERVAL_MS))
WAIT_S=$((WAIT_MS / 1000))
if [ "$WAIT_S" -gt "$CFG_EVOLVE_AB_ABSOLUTE_MAX_WAIT_S" ]; then
    log "  A/B wait clamped: ${WAIT_S}s -> ${CFG_EVOLVE_AB_ABSOLUTE_MAX_WAIT_S}s (absolute_max_wait_s)"
    WAIT_S="$CFG_EVOLVE_AB_ABSOLUTE_MAX_WAIT_S"
fi

if [ "$CONTAINERIZED" != "true" ]; then
    log "  A/B run skipped: --containerized required for daemon spawn"
    ledger_append "ab_inconclusive" \
        "{\"candidate_sha8\":\"$CANDIDATE_SHA8\",\"reason\":\"non_containerized_mode\",\"wait_s\":$WAIT_S}"
    rm -f "$CANDIDATE_PATH" "$RATIONALE_PATH" "$SYNTH_EXP"
    log "Done."
    exit 0
fi

# Spawn the candidate daemon under the synthetic agent_id. Mirrors
# cull-explorers.sh:410 pattern (podman exec bash -c "... agentis daemon ... &").
# Container name is fixed to `research-foundry-laptop` -- the only
# containerized federation today.
#
# Path translation (fixes #660): $CANDIDATE_PATH is host-side
# `<fed-dir>/<colony>/agents/.evolve/<agent>.ag.candidate-gen-N`. The
# container mounts the federation root at `/run-root/`, so strip the
# host fed-dir prefix and prepend `/run-root/` before handing the path
# to the daemon. Mirrors the respawn block below + cull-explorers.sh:410
# pattern (`/run-root/<colony>/agents/<agent>.ag`).
CONTAINER_NAME="${RESEARCH_CONTAINER_NAME:-research-foundry-laptop}"
CANDIDATE_CONTAINER_PATH="/run-root/${COLONY}/agents/.evolve/${AGENT_NAME}.ag.candidate-gen-${GENERATION_NEXT}"
CANDIDATE_LOG="/run-root/.agentis/logs/${SYNTHETIC_ID}.log"
SPAWN_CMD="agentis daemon $CANDIDATE_CONTAINER_PATH --colony $COLONY --enable-exec --enable-messaging --tick-interval $TICK_INTERVAL_MS > $CANDIDATE_LOG 2>&1 &"

log "  spawning candidate daemon: synthetic_id=$SYNTHETIC_ID wait_s=$WAIT_S"
if ! podman exec "$CONTAINER_NAME" bash -c "$SPAWN_CMD" 2>/dev/null; then
    log "  candidate spawn failed (podman exec rc=$?)"
    ledger_append "ab_spawn_failed" \
        "{\"candidate_sha8\":\"$CANDIDATE_SHA8\",\"container\":\"$CONTAINER_NAME\",\"synthetic_id\":\"$SYNTHETIC_ID\"}"
    rm -f "$CANDIDATE_PATH" "$RATIONALE_PATH" "$SYNTH_EXP"
    log "Done."
    exit 0
fi

# Wait the A/B window. The candidate accumulates experience rows under
# the synthetic .jsonl; the canonical keeps its existing path.
sleep "$WAIT_S"

# Score both daemons. The fallback proxy is
#   (acting_count - reject_count) / max(acting_count, 1)
# computed straight off the .jsonl tail. For explorers we additionally
# try `explorer-fitness.py` for the empirical signal, but the proxy is
# the canonical scalar the A/B comparison runs on -- one path, no
# divergence between explorer / non-explorer agents on this PR.
score_jsonl() {
    local jsonl_path="$1"
    local window="$2"
    python3 -c "
import json, sys
path = sys.argv[1]
window = int(sys.argv[2])
rows = []
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except (json.JSONDecodeError, ValueError):
                pass
except (OSError, IOError):
    pass
rows = rows[-window:] if window > 0 else rows
acting = 0
reject = 0
for r in rows:
    if not isinstance(r, dict):
        continue
    tags = r.get('tags') or []
    if not isinstance(tags, list):
        tags = []
    is_acting = any(str(t) in ('emitted', 'acted', 'review-gated') for t in tags)
    if is_acting:
        acting += 1
    outcome = str(r.get('outcome', '')).lower()
    if outcome in ('reject', 'failure'):
        reject += 1
if acting <= 0:
    print('0.0')
else:
    print('%.6f' % ((acting - reject) / float(acting)))
" "$jsonl_path" "$window"
}

CANDIDATE_SCORE=$(score_jsonl "$SYNTH_EXP" "$AB_TICKS")
CANONICAL_SCORE=$(score_jsonl "$EXPERIENCE_PATH" "$AB_TICKS")

log "  scores: candidate=$CANDIDATE_SCORE canonical=$CANONICAL_SCORE min_delta=$CFG_EVOLVE_AB_MIN_DELTA"

# Compare. We use python3 here because bash arithmetic does not handle
# floating point.
COMPARE_OUT=$(python3 -c "
import sys
cand = float(sys.argv[1])
canon = float(sys.argv[2])
delta_min = float(sys.argv[3])
delta = cand - canon
if delta > delta_min:
    print('candidate %.6f' % delta)
elif delta < -delta_min:
    print('canonical %.6f' % delta)
else:
    print('inconclusive %.6f' % delta)
" "$CANDIDATE_SCORE" "$CANONICAL_SCORE" "$CFG_EVOLVE_AB_MIN_DELTA")

WINNER=$(echo "$COMPARE_OUT" | awk '{print $1}')
DELTA=$(echo "$COMPARE_OUT" | awk '{print $2}')

log "  A/B verdict: winner=$WINNER delta=$DELTA"

# Stop the candidate daemon regardless of verdict. It served its A/B
# purpose; whether we then archive + replace canonical depends on the
# dry-run flag below. Uses the container-side path (#660) so pkill -f
# matches the daemon's actual argv.
podman exec "$CONTAINER_NAME" bash -c "pkill -f 'agentis daemon $CANDIDATE_CONTAINER_PATH' 2>/dev/null || true" >/dev/null 2>&1 || true

if [ "$WINNER" = "inconclusive" ]; then
    ledger_append "ab_inconclusive" \
        "{\"candidate_sha8\":\"$CANDIDATE_SHA8\",\"candidate_score\":$CANDIDATE_SCORE,\"canonical_score\":$CANONICAL_SCORE,\"delta\":$DELTA,\"min_delta\":$CFG_EVOLVE_AB_MIN_DELTA,\"synthetic_id\":\"$SYNTHETIC_ID\"}"
else
    ledger_append "evolve_cycle" \
        "{\"candidate_sha8\":\"$CANDIDATE_SHA8\",\"winner\":\"$WINNER\",\"candidate_score\":$CANDIDATE_SCORE,\"canonical_score\":$CANONICAL_SCORE,\"delta\":$DELTA,\"min_delta\":$CFG_EVOLVE_AB_MIN_DELTA,\"synthetic_id\":\"$SYNTHETIC_ID\"}"
fi

# ------------------------------------------------------------------
# 5. Promote winner (DRY-RUN AWARE)
# ------------------------------------------------------------------

if [ "$EVOLVE_DRY_RUN" = "true" ]; then
    log "  dry-run: ledger captured outcome; no archive, no rename, no respawn"
elif [ "$WINNER" = "candidate" ]; then
    # PR-C scope path: candidate wins, swap it in. Mirrors
    # auto-promote.sh:362-381 respawn pattern.
    mkdir -p "$ARCHIVE_DIR"
    ARCHIVE_PATH="$ARCHIVE_DIR/${AGENT_NAME}-gen-${GENERATION_NEXT}-${PARENT_SHA8}.ag"
    cp "$PARENT_AG" "$ARCHIVE_PATH"
    log "  archived parent to $ARCHIVE_PATH"

    # Atomic-ish: mv candidate over canonical, fsync the parent dir.
    mv -f "$CANDIDATE_PATH" "$PARENT_AG"
    python3 -c "
import os, sys
fd = os.open(os.path.dirname(sys.argv[1]) or '.', os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
" "$PARENT_AG" 2>/dev/null || true

    # Stop the canonical daemon by name. The dashboard / sidecar respawn
    # pattern is `agentis daemon stop <agent_id>` -- we don't have the
    # uuid here, so fall back to the pkill pattern used by cull-explorers.
    podman exec "$CONTAINER_NAME" bash -c "pkill -f 'agentis daemon /run-root/$COLONY/agents/$AGENT_NAME.ag' 2>/dev/null || true" >/dev/null 2>&1 || true
    sleep 3
    # Respawn canonical from the new .ag file.
    RESPAWN_CMD="agentis daemon /run-root/$COLONY/agents/$AGENT_NAME.ag --colony $COLONY --enable-exec --enable-messaging --tick-interval $TICK_INTERVAL_MS > /run-root/.agentis/logs/$AGENT_NAME.log 2>&1 &"
    podman exec "$CONTAINER_NAME" bash -c "$RESPAWN_CMD" 2>/dev/null || \
        log "  WARN: canonical respawn failed"
    log "  canonical respawned with new generation"
else
    log "  canonical won (or inconclusive); no swap"
fi

# Always clean up the synthetic experience + candidate / rationale.
rm -f "$CANDIDATE_PATH" "$RATIONALE_PATH" "$SYNTH_EXP"

log "Done."
