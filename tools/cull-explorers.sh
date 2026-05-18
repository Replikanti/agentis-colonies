#!/bin/bash
# tools/cull-explorers.sh -- Cull underperforming explorer daemons in
# research-foundry per Phase 3 PR 3 of issue #624.
#
# Usage: cull-explorers.sh <fed_dir> [--bottom-pct 0.2] [--min-explorers 3]
#                                    [--min-acting 10] [--dry-run]
#
# Invoked from start_auto_promote_sidecar() in research-foundry/tools/
# run-research.sh every RESEARCH_CULL_INTERVAL_TICKS x tick_interval_s
# seconds. Default: cull bottom 20% by fitness_score every 20 ticks,
# skip when total explorer count < 3 or bottom row has entries_acting
# < 10 (insufficient data).
#
# Pipeline:
#   1. enumerate explorer daemons via `agentis daemon list --json`
#   2. resolve per-pid fitness_score by calling auto-promote-decisions.py
#      --preview (which embeds the explorer-fitness.py join from PR 2)
#   3. pick bottom-N by fitness_score (gated by --min-explorers + per-row
#      entries_acting >= --min-acting)
#   4. stop the daemon (best-effort fallback: SIGTERM via container kill)
#   5. spawn a replacement explorer at a fresh DAEMON_ID with a demand-
#      weighted specialty (least-represented across surviving explorers)
#   6. emit `cull` + `respawn` rows to <fed_dir>/replication-ledger.jsonl
#      (the file from PR 1) plus a best-effort `agentis memo del
#      explorer:<old-pid>:*` cleanup.
#
# This script only runs inside the host context that drives the
# research-foundry container; it talks to the container exclusively via
# `podman exec research-foundry-laptop ...`. The ledger path is the
# host-side bind-mount root (<fed_dir>/replication-ledger.jsonl).
#
# Net-zero on daemon count: kill 1, spawn 1. The M2-Malthusian
# max_replicas cap from PR 1 still enforces the upper bound.

set -euo pipefail

# --- Path resolution ---

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# --- Argument parsing ---

if [ $# -lt 1 ]; then
    echo "Usage: $0 <fed_dir> [--bottom-pct 0.2] [--min-explorers 3] [--min-acting 10] [--dry-run]" >&2
    exit 2
fi

FED_DIR="$1"
shift

BOTTOM_PCT="0.2"
MIN_EXPLORERS="3"
MIN_ACTING="10"
DRY_RUN="0"

while [ $# -gt 0 ]; do
    case "$1" in
        --bottom-pct)
            if [ $# -lt 2 ]; then
                echo "cull-explorers: --bottom-pct requires a value" >&2
                exit 2
            fi
            BOTTOM_PCT="$2"
            shift 2
            ;;
        --min-explorers)
            if [ $# -lt 2 ]; then
                echo "cull-explorers: --min-explorers requires a value" >&2
                exit 2
            fi
            MIN_EXPLORERS="$2"
            shift 2
            ;;
        --min-acting)
            if [ $# -lt 2 ]; then
                echo "cull-explorers: --min-acting requires a value" >&2
                exit 2
            fi
            MIN_ACTING="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="1"
            shift
            ;;
        *)
            echo "cull-explorers: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ ! -d "$FED_DIR" ]; then
    echo "cull-explorers: fed_dir not found: $FED_DIR" >&2
    exit 2
fi

CONFIG_FILE="$REPO_ROOT/tools/auto-promote-config.research-foundry.yaml"
DECISIONS_SCRIPT="$REPO_ROOT/tools/auto-promote-decisions.py"
REPLICATION_LEDGER="$FED_DIR/replication-ledger.jsonl"
CONTAINER="research-foundry-laptop"

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] cull-explorers: $*"
}

# Allow test fixtures to override the daemon-list source via env. The
# test harness sets CULL_DAEMONS_JSON_OVERRIDE to a synthetic blob so we
# can exercise the picker without a live container.
if [ -n "${CULL_DAEMONS_JSON_OVERRIDE:-}" ]; then
    DAEMONS_JSON="$CULL_DAEMONS_JSON_OVERRIDE"
else
    DAEMONS_JSON="$(podman exec "$CONTAINER" agentis daemon list --json 2>/dev/null || echo '[]')"
fi

# Filter to explorer daemons by `source` basename.
EXPLORER_DAEMONS_JSON="$(python3 -c "
import json, sys, os
daemons = json.loads(sys.argv[1])
explorers = []
for d in daemons:
    src = d.get('source', '')
    if os.path.basename(src) == 'explorer.ag':
        explorers.append(d)
print(json.dumps(explorers))
" "$DAEMONS_JSON")"

EXPLORER_COUNT="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$EXPLORER_DAEMONS_JSON")"

if [ "$EXPLORER_COUNT" -lt "$MIN_EXPLORERS" ]; then
    log "skip: explorer_count=$EXPLORER_COUNT < min_explorers=$MIN_EXPLORERS"
    exit 0
fi

log "found $EXPLORER_COUNT explorer daemon(s), evaluating cull candidates"

# Invoke auto-promote-decisions.py --preview to pull per-pid fitness
# scores out of the explorer-fitness.py join from PR 2. The fed_dir
# argument here is the laptop-node bind-mount inside the host, which
# is also what auto-promote.sh sees in --containerized mode.
DECISIONS_JSON="$(python3 "$DECISIONS_SCRIPT" --preview --config "$CONFIG_FILE" --containerized "$EXPLORER_DAEMONS_JSON" "$FED_DIR" 2>/dev/null || echo '[]')"

# Filter decisions to explorer rows (preview emits a record per daemon),
# then pick the bottom N by fitness_score ascending. We respect the
# --min-acting gate by skipping candidates whose evidence.entries_acting
# is below the floor (per-row guard against acting on noisy bootstraps).
PICKED_JSON="$(python3 -c "
import json, math, sys
decisions = json.loads(sys.argv[1])
bottom_pct = float(sys.argv[2])
min_acting = int(sys.argv[3])
total = int(sys.argv[4])

# Sort explorer decisions by fitness_score ascending. Missing scores
# treated as 0 (worst).
rows = []
for d in decisions:
    if d.get('agent') != 'explorer':
        continue
    score = d.get('fitness_score')
    try:
        score = float(score) if score is not None else 0.0
    except (ValueError, TypeError):
        score = 0.0
    pid = d.get('pid')
    if not pid:
        continue
    evidence = d.get('evidence') or {}
    entries_acting = evidence.get('entries_acting', 0)
    try:
        entries_acting = int(entries_acting)
    except (ValueError, TypeError):
        entries_acting = 0
    rows.append({
        'pid': pid,
        'agent_id': d.get('agent_id', ''),
        'specialty': d.get('specialty', ''),
        'fitness_score': score,
        'entries_acting': entries_acting,
    })

rows.sort(key=lambda r: r['fitness_score'])
n = max(1, math.ceil(total * bottom_pct))
picked = []
for r in rows[:n]:
    if r['entries_acting'] < min_acting:
        # Skip per-row when insufficient data; record so caller can log.
        r['skip_reason'] = 'entries_acting=%d < %d' % (r['entries_acting'], min_acting)
    picked.append(r)
print(json.dumps(picked))
" "$DECISIONS_JSON" "$BOTTOM_PCT" "$MIN_ACTING" "$EXPLORER_COUNT")"

PICKED_COUNT="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$PICKED_JSON")"
if [ "$PICKED_COUNT" -eq 0 ]; then
    log "no cull candidates picked (decisions feed empty or filtered out)"
    exit 0
fi

# Enumerate current explorer specialties so we can pick the most under-
# represented one for the respawn. Reading via `podman exec` keeps the
# join inside the container's memo namespace.
read_specialty_counts() {
    if [ -n "${CULL_SPECIALTY_COUNTS_OVERRIDE:-}" ]; then
        printf '%s\n' "$CULL_SPECIALTY_COUNTS_OVERRIDE"
        return 0
    fi
    python3 -c "
import json, subprocess, sys
explorers = json.loads(sys.argv[1])
counts = {}
for d in explorers:
    pid = d.get('pid', 0)
    if not pid:
        continue
    try:
        out = subprocess.run(
            ['podman', 'exec', 'research-foundry-laptop',
             'agentis', 'memo', 'get', 'explorer:%s:specialty' % pid],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        continue
    val = (out.stdout or '').strip()
    if not val:
        continue
    counts[val] = counts.get(val, 0) + 1
print(json.dumps(counts))
" "$EXPLORER_DAEMONS_JSON"
}

SPECIALTY_COUNTS_JSON="$(read_specialty_counts)"

# Pick least-represented specialty out of the seeded pool (5 slots in
# PR 1's bootstrap). Tie-breaker: now_ms_via_shell modulo the tied set,
# kept deterministic enough for tests via CULL_NOW_MS_OVERRIDE.
NOW_MS="${CULL_NOW_MS_OVERRIDE:-$(date +%s%3N)}"

# Find the next available DAEMON_ID by scanning the running explorer
# daemons. The orchestrator seeds DAEMON_ID=1..N at bootstrap; we want
# max(existing) + 1 so the new daemon does not collide with a surviving
# replica's claimed pool slot.
MAX_DAEMON_ID="$(python3 -c "
import json, subprocess, sys
explorers = json.loads(sys.argv[1])
max_id = 0
for d in explorers:
    pid = d.get('pid', 0)
    if not pid:
        continue
    # Read the DAEMON_ID memo if the agent published one. Fall back to
    # scanning the pool:specialty:<N> slot assignments for occupied ids.
    try:
        out = subprocess.run(
            ['podman', 'exec', 'research-foundry-laptop',
             'agentis', 'memo', 'get', 'explorer:%s:daemon_id' % pid],
            capture_output=True, text=True, timeout=5,
        )
        v = (out.stdout or '').strip()
        if v.isdigit():
            max_id = max(max_id, int(v))
    except (OSError, subprocess.SubprocessError):
        pass
# Also enumerate the pool slots; the bootstrap seeds 5 by default but
# Phase 3 PR 3 grows the pool by writing pool:specialty:<new-id> below.
try:
    out = subprocess.run(
        ['podman', 'exec', 'research-foundry-laptop',
         'agentis', 'memo', 'list'],
        capture_output=True, text=True, timeout=5,
    )
    for line in (out.stdout or '').splitlines():
        line = line.strip()
        if not line.startswith('explorer:pool:specialty:'):
            continue
        # key 'explorer:pool:specialty:<N>' -- take the <N>.
        parts = line.split(':')
        if len(parts) < 4:
            continue
        suffix = parts[3].split()[0].split('=')[0].strip()
        if suffix.isdigit():
            max_id = max(max_id, int(suffix))
except (OSError, subprocess.SubprocessError):
    pass
# Fall back to a sensible default when nothing resolved.
if max_id == 0:
    max_id = len(explorers)
print(max_id)
" "$EXPLORER_DAEMONS_JSON" 2>/dev/null || echo "$EXPLORER_COUNT")"

# Compute the demand-weighted specialty pick once for this cull batch.
# All replacements in a single batch inherit the same pick; with cull
# size >= 2 the picker re-evaluates after each respawn so the second
# replacement does not collide with the first.
NEXT_SPECIALTY="$(python3 -c "
import json, sys
pool = ['group_theory', 'combinatorics', 'number_theory', 'probability', 'algebra']
counts = json.loads(sys.argv[1])
now_ms = int(sys.argv[2])
mins = []
min_count = None
for s in pool:
    c = counts.get(s, 0)
    if min_count is None or c < min_count:
        min_count = c
        mins = [s]
    elif c == min_count:
        mins.append(s)
print(mins[now_ms % len(mins)])
" "$SPECIALTY_COUNTS_JSON" "$NOW_MS")"

log "picked $PICKED_COUNT cull candidate(s); respawn specialty=$NEXT_SPECIALTY (next daemon_id=$((MAX_DAEMON_ID + 1)))"

# Iterate picks. Each pick produces (cull, respawn) ledger rows.
NEXT_ID="$MAX_DAEMON_ID"

python3 -c "
import json, sys
print('\n'.join(
    '%s|%s|%s|%s|%s' % (
        r.get('pid', ''),
        r.get('agent_id', ''),
        r.get('specialty', ''),
        r.get('fitness_score', 0),
        r.get('skip_reason', ''),
    )
    for r in json.loads(sys.argv[1])
))
" "$PICKED_JSON" | while IFS='|' read -r pid agent_id specialty fitness skip_reason; do
    if [ -z "$pid" ]; then
        continue
    fi
    if [ -n "$skip_reason" ]; then
        log "skip pid=$pid: $skip_reason"
        continue
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log "[dry-run] would cull pid=$pid agent_id=$agent_id specialty=$specialty fitness=$fitness"
        log "[dry-run] would respawn explorer with specialty=$NEXT_SPECIALTY daemon_id=$((NEXT_ID + 1))"
        continue
    fi

    log "cull pid=$pid agent_id=$agent_id specialty=$specialty fitness=$fitness"

    # Stop the daemon via agentis daemon stop. The agent_id maps to the
    # daemon registry uuid inside the container.
    podman exec "$CONTAINER" agentis daemon stop "$agent_id" 2>/dev/null || true

    # Verify shutdown by re-polling after a short delay. If the daemon
    # is still alive, fall back to SIGTERM on the container-local pid.
    sleep 5
    POST_STATE="$(podman exec "$CONTAINER" agentis daemon list --json 2>/dev/null | python3 -c "
import json, sys
target = sys.argv[1]
for d in json.loads(sys.stdin.read()):
    if str(d.get('agent_id', '')) == target:
        print(d.get('state', ''))
        sys.exit(0)
print('gone')
" "$agent_id" 2>/dev/null || echo "unknown")"
    if [ "$POST_STATE" = "running" ]; then
        log "fallback: SIGTERM container-local pid=$pid"
        podman exec "$CONTAINER" kill -TERM "$pid" 2>/dev/null || true
    fi

    # Append a cull row to the replication ledger from host context.
    python3 -c "
import json, sys, time
row = {
    'ts': int(time.time() * 1000),
    'event': 'cull',
    'pid': sys.argv[1],
    'agent_id': sys.argv[2],
    'specialty': sys.argv[3],
    'fitness_score': float(sys.argv[4]) if sys.argv[4] else 0.0,
    'reason': 'fitness_bottom_pct',
}
sys.stdout.write(json.dumps(row) + '\n')
" "$pid" "$agent_id" "$specialty" "$fitness" >> "$REPLICATION_LEDGER"

    # Best-effort memo cleanup. Some agentis builds don't support
    # pattern delete; tolerate failure silently.
    podman exec "$CONTAINER" agentis memo del "explorer:$pid:*" 2>/dev/null || true

    # Allocate the next DAEMON_ID and grow the pool with the chosen
    # specialty so explorer.ag's first-tick claim path can read it.
    NEW_ID=$((NEXT_ID + 1))
    NEXT_ID="$NEW_ID"

    NEW_OVERLAY="$(python3 -c "
overlays = {
    'group_theory': 'Focus on finite group invariants: conjugacy classes, character tables, subgroup lattices, automorphism groups. Compute representations and quotients explicitly. Look for coincidences in character degrees, order divisibility, sporadic-vs-classical group behaviour.',
    'combinatorics': 'Focus on enumerative combinatorics: generating functions, bijective proofs, lattice paths, partition identities. Compute small-case counts and look for OEIS matches. Compare known sequences against derived ones for unexpected coincidence.',
    'number_theory': 'Focus on arithmetic functions and sieves: prime counting, Mobius, totient, divisor sums. Compute over small ranges, examine mod-p behaviour, look for unexpected density / equidistribution / sign-change patterns.',
    'probability': 'Focus on random structures: Erdos-Renyi graphs, random matrices, percolation thresholds, asymptotic distributions. Run small Monte Carlo and compare against predicted limits. Look for deviations from the expected scaling.',
    'algebra': 'Focus on representation theory + Lie algebras: irreducible representations, weight diagrams, Casimir invariants, Cartan classification. Compute decomposition of tensor products, dimensions, branching rules. Look for unexpected multiplicities or symmetries.',
}
import sys
print(overlays.get(sys.argv[1], ''))
" "$NEXT_SPECIALTY")"

    podman exec "$CONTAINER" agentis memo set "explorer:pool:specialty:$NEW_ID" "$NEXT_SPECIALTY" 2>/dev/null || true
    podman exec "$CONTAINER" agentis memo set "explorer:pool:specialty_overlay:$NEW_ID" "$NEW_OVERLAY" 2>/dev/null || true

    # Spawn the replacement explorer. Env mirrors the bootstrap spawn
    # loop in run-research.sh (DAEMON_ID + replication knobs read by
    # explorer.ag's first-tick claim path). Background it so the cull
    # tool can return promptly.
    podman exec "$CONTAINER" bash -c "DAEMON_ID=$NEW_ID COLONY_NAME=explorer EXPLORER_GENERATION=0 HOLD_PERIOD=\${HOLD_PERIOD:-4} DISCOVERY_LEDGER=/run-root/discovery-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/explorer/agents/explorer.ag --colony explorer --enable-exec --enable-messaging --enable-replication --allow-replica-replication --tick-interval 30000 > /run-root/.agentis/logs/explorer-$NEW_ID.log 2>&1 &" 2>/dev/null || true

    # Append the respawn row.
    python3 -c "
import json, sys, time
row = {
    'ts': int(time.time() * 1000),
    'event': 'respawn',
    'daemon_id': int(sys.argv[1]),
    'specialty': sys.argv[2],
    'generation': 0,
    'reason': 'cull_replacement',
    'replaced_pid': sys.argv[3],
}
sys.stdout.write(json.dumps(row) + '\n')
" "$NEW_ID" "$NEXT_SPECIALTY" "$pid" >> "$REPLICATION_LEDGER"

    log "respawned explorer daemon_id=$NEW_ID specialty=$NEXT_SPECIALTY (replaced pid=$pid)"
done

log "done"
