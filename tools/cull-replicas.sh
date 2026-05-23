#!/bin/bash
# tools/cull-replicas.sh -- Cull underperforming replica daemons in a
# research-foundry colony, generalising the Phase 3 explorer-only tool
# from #624 to every colony per Phase 9 PR-B of #663.
#
# Usage: cull-replicas.sh <fed_dir> <colony_name>
#                          [--bottom-pct 0.2] [--min-explorers 3]
#                          [--min-acting 10] [--dry-run]
#
# Invoked from start_auto_promote_sidecar() in research-foundry/tools/
# run-research.sh every RESEARCH_CULL_INTERVAL_TICKS x tick_interval_s
# seconds. Default: cull bottom 20% by fitness_score every 20 ticks,
# skip when total replica count < 3 or bottom row has entries_acting
# < 10 (insufficient data).
#
# The legacy wrapper `tools/cull-explorers.sh` forwards to this tool
# with `<colony_name>=explorer` so the existing `run-research.sh` env
# knobs (`RESEARCH_CULL_*`) keep working byte-identically.
#
# Pipeline:
#   1. enumerate <colony_name> daemons via `agentis daemon list --json`
#   2. resolve per-pid fitness_score by calling auto-promote-decisions.py
#      --preview (which embeds the colony-fitness.py join)
#   3. pick bottom-N by fitness_score (gated by --min-explorers + per-row
#      entries_acting >= --min-acting). `--min-explorers` retains its
#      historical name to keep the run-research.sh knobs stable.
#   4. stop the daemon (best-effort fallback: SIGTERM via container kill)
#   5. spawn a replacement at a fresh DAEMON_ID with a demand-weighted
#      specialty/variant (least-represented across survivors).
#   6. emit `cull` + `respawn` rows to <fed_dir>/replication-ledger.jsonl
#      plus a best-effort `agentis memo del <colony_name>:<old-pid>:*`
#      cleanup.
#
# Variant pool + overlay text are looked up at runtime from
# research-foundry/tools/colony-variants.json. When the fed under
# inspection ships no such file (other federations), the tool falls
# back to the explorer-only hardcoded pool so the legacy path keeps
# working.
#
# This script only runs inside the host context that drives the
# research-foundry container; it talks to the container exclusively via
# `podman exec "$CONTAINER" ...`, where $CONTAINER defaults to
# `research-foundry-laptop` and can be overridden by exporting
# `CULL_CONTAINER_NAME=<name>`. Test harnesses set this to a sentinel
# value (`cull-test-noop`) so every `podman exec` fails fast and the
# script's try/except blocks fall through to fixture-provided values
# instead of leaking into a live federation's memo store (issue #685).
# The ledger path is the host-side bind-mount root
# (<fed_dir>/replication-ledger.jsonl).
#
# Net-zero on daemon count: kill 1, spawn 1. The M2-Malthusian
# max_replicas cap from PR 1 still enforces the upper bound.

set -euo pipefail

# --- Path resolution ---

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# --- Argument parsing ---

if [ $# -lt 2 ]; then
    echo "Usage: $0 <fed_dir> <colony_name> [--bottom-pct 0.2] [--min-explorers 3] [--min-acting 10] [--dry-run]" >&2
    exit 2
fi

FED_DIR="$1"
COLONY_NAME="$2"
shift 2

BOTTOM_PCT="0.2"
MIN_EXPLORERS="3"
MIN_ACTING="10"
DRY_RUN="0"

while [ $# -gt 0 ]; do
    case "$1" in
        --bottom-pct)
            if [ $# -lt 2 ]; then
                echo "cull-replicas: --bottom-pct requires a value" >&2
                exit 2
            fi
            BOTTOM_PCT="$2"
            shift 2
            ;;
        --min-explorers)
            if [ $# -lt 2 ]; then
                echo "cull-replicas: --min-explorers requires a value" >&2
                exit 2
            fi
            MIN_EXPLORERS="$2"
            shift 2
            ;;
        --min-acting)
            if [ $# -lt 2 ]; then
                echo "cull-replicas: --min-acting requires a value" >&2
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
            echo "cull-replicas: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# Validate --bottom-pct is a float in [0.0, 1.0]. Without this, a
# misconfigured RESEARCH_CULL_BOTTOM_PCT > 1.0 mass-culls every replica
# (the respawn phase is bounded by M2-Malthusian but the kill phase is
# not). See issue #649.
if ! python3 -c "
import sys
try:
    v = float(sys.argv[1])
except (ValueError, TypeError):
    sys.exit(1)
if not (0.0 <= v <= 1.0):
    sys.exit(1)
" "$BOTTOM_PCT" 2>/dev/null; then
    echo "cull-replicas: --bottom-pct must be a float in [0.0, 1.0], got: $BOTTOM_PCT" >&2
    exit 2
fi

if [ ! -d "$FED_DIR" ]; then
    echo "cull-replicas: fed_dir not found: $FED_DIR" >&2
    exit 2
fi

CONFIG_FILE="$REPO_ROOT/tools/auto-promote-config.research-foundry.yaml"
DECISIONS_SCRIPT="$REPO_ROOT/tools/auto-promote-decisions.py"
REPLICATION_LEDGER="$FED_DIR/replication-ledger.jsonl"
CONTAINER="${CULL_CONTAINER_NAME:-research-foundry-laptop}"
VARIANTS_FILE="$REPO_ROOT/research-foundry/tools/colony-variants.json"

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] cull-replicas[$COLONY_NAME]: $*"
}

# Allow test fixtures to override the daemon-list source via env. The
# test harness sets CULL_DAEMONS_JSON_OVERRIDE to a synthetic blob so we
# can exercise the picker without a live container.
if [ -n "${CULL_DAEMONS_JSON_OVERRIDE:-}" ]; then
    DAEMONS_JSON="$CULL_DAEMONS_JSON_OVERRIDE"
else
    DAEMONS_JSON="$(podman exec "$CONTAINER" agentis daemon list --json 2>/dev/null || echo '[]')"
fi

# Filter to <colony_name> daemons by `source` basename.
COLONY_DAEMONS_JSON="$(python3 -c "
import json, sys, os
daemons = json.loads(sys.argv[1])
target_basename = sys.argv[2] + '.ag'
matches = []
for d in daemons:
    src = d.get('source', '')
    if os.path.basename(src) == target_basename:
        matches.append(d)
print(json.dumps(matches))
" "$DAEMONS_JSON" "$COLONY_NAME")"

COLONY_COUNT="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$COLONY_DAEMONS_JSON")"

if [ "$COLONY_COUNT" -lt "$MIN_EXPLORERS" ]; then
    log "skip: ${COLONY_NAME}_count=$COLONY_COUNT < min_explorers=$MIN_EXPLORERS"
    exit 0
fi

log "found $COLONY_COUNT $COLONY_NAME daemon(s), evaluating cull candidates"

# Invoke auto-promote-decisions.py --preview to pull per-pid fitness
# scores out of the colony-fitness.py join. The fed_dir argument here
# is the laptop-node bind-mount inside the host, which is also what
# auto-promote.sh sees in --containerized mode.
DECISIONS_JSON="$(python3 "$DECISIONS_SCRIPT" --preview --config "$CONFIG_FILE" --containerized "$COLONY_DAEMONS_JSON" "$FED_DIR" 2>/dev/null || echo '[]')"

# Issue #767: aging cull requests scan. Each .ag publishes
# `colony:cull_self_request:<pid>` = "aging" when its `age_ticks` memo
# crosses `env:RESEARCH_AGING_THRESHOLD`. The sidecar reads those keys
# and, when the per-pid fitness sits below
# `env:RESEARCH_AGING_FITNESS_FLOOR`, merges the daemon into the picked
# list with `reason=aging` so the same stop+respawn loop handles both
# fitness-bottom-pct and aging culls. Default
# `env:RESEARCH_AGING_ENABLED=0` keeps the scan empty so the cull
# pipeline behaves byte-identically to pre-#767.
if [ -n "${CULL_AGING_REQUESTS_OVERRIDE:-}" ]; then
    # Test fixture: comma-separated pid list (e.g. "1001,1002").
    AGING_REQUESTS_RAW="$CULL_AGING_REQUESTS_OVERRIDE"
else
    AGING_REQUESTS_RAW="$(podman exec "$CONTAINER" agentis memo list 2>/dev/null | python3 -c "
import sys
prefix = 'colony:cull_self_request:'
pids = []
for line in sys.stdin:
    line = line.strip()
    if not line.startswith(prefix):
        continue
    # Key shape: 'colony:cull_self_request:<pid>[ = value]' -- take the pid.
    rest = line[len(prefix):]
    pid = rest.split()[0].split('=')[0].strip()
    if pid:
        pids.append(pid)
print(','.join(pids))
" 2>/dev/null || echo '')"
fi

# Read aging fitness floor (string -- Python does the float compare).
AGING_FITNESS_FLOOR="${CULL_AGING_FITNESS_FLOOR_OVERRIDE:-}"
if [ -z "$AGING_FITNESS_FLOOR" ]; then
    AGING_FITNESS_FLOOR="$(podman exec "$CONTAINER" agentis memo get env:RESEARCH_AGING_FITNESS_FLOOR 2>/dev/null || true)"
fi
if [ -z "$AGING_FITNESS_FLOOR" ]; then
    AGING_FITNESS_FLOOR="0.3"
fi

# Filter decisions to <colony_name> rows (preview emits a record per
# daemon), then pick the bottom N by fitness_score ascending. We respect
# the --min-acting gate by skipping candidates whose
# evidence.entries_acting is below the floor (per-row guard against
# acting on noisy bootstraps).
#
# Issue #767: aging requests are merged in BEFORE bottom-pct picks.
# A daemon present in both lists keeps reason=aging (load-bearing for
# the ledger event) and bypasses the min-acting gate -- an aged-out
# daemon with low fitness should not be kept alive just because the
# acting-row sample size is small.
PICKED_JSON="$(python3 -c "
import json, math, sys
decisions = json.loads(sys.argv[1])
bottom_pct = float(sys.argv[2])
min_acting = int(sys.argv[3])
total = int(sys.argv[4])
colony = sys.argv[5]
aging_pids_raw = sys.argv[6]
try:
    aging_floor = float(sys.argv[7]) if sys.argv[7] else 0.3
except (ValueError, TypeError):
    aging_floor = 0.3

aging_pids = set()
for p in aging_pids_raw.split(','):
    p = p.strip()
    if p:
        aging_pids.add(p)

# Sort decisions by fitness_score ascending. Missing scores treated as 0
# (worst).
rows = []
aging_rows = []
for d in decisions:
    if d.get('agent') != colony:
        continue
    score = d.get('fitness_score')
    try:
        score = float(score) if score is not None else 0.0
    except (ValueError, TypeError):
        score = 0.0
    evidence = d.get('evidence') or {}
    pid = d.get('pid')
    if not pid:
        # Phase 9 PR-B (#663): some decision shapes (non-explorer
        # promote-path skips) carry the pid only inside the evidence
        # dict. Fall through to that location so the cull picker keeps
        # working even without Chunk 3's top-level decoration.
        pid = evidence.get('pid')
    if not pid:
        continue
    entries_acting = evidence.get('entries_acting', 0)
    try:
        entries_acting = int(entries_acting)
    except (ValueError, TypeError):
        entries_acting = 0
    row = {
        'pid': pid,
        'agent_id': d.get('agent_id', ''),
        'specialty': d.get('specialty', ''),
        'fitness_score': score,
        'entries_acting': entries_acting,
        'reason': 'fitness_bottom_pct',
    }
    rows.append(row)
    # Issue 767 aging-out gate. A daemon whose .ag flagged itself via
    # the colony cull-self-request memo is picked iff its fitness is
    # below the aging floor. This drops the bottom-pct rate-limit so
    # all aged-out unfit daemons get culled in one cycle, subject to
    # the kill plus respawn budget downstream.
    if str(pid) in aging_pids and score < aging_floor:
        aging_row = dict(row)
        aging_row['reason'] = 'aging'
        aging_rows.append(aging_row)

rows.sort(key=lambda r: r['fitness_score'])
n = max(1, math.ceil(total * bottom_pct))
picked_by_pid = {}
# Aging-out picks have priority on the reason field but share the kill
# plus respawn slot so net daemon count is unchanged.
for r in aging_rows:
    picked_by_pid[str(r['pid'])] = r
for r in rows[:n]:
    key = str(r['pid'])
    if key in picked_by_pid:
        # Already picked via aging; keep reason=aging but propagate the
        # bottom-pct min-acting guard as fitness_bottom_pct rows would.
        continue
    if r['entries_acting'] < min_acting:
        # Skip per-row when insufficient data; record so caller can log.
        r['skip_reason'] = 'entries_acting=%d < %d' % (r['entries_acting'], min_acting)
    picked_by_pid[key] = r
print(json.dumps(list(picked_by_pid.values())))
" "$DECISIONS_JSON" "$BOTTOM_PCT" "$MIN_ACTING" "$COLONY_COUNT" "$COLONY_NAME" "$AGING_REQUESTS_RAW" "$AGING_FITNESS_FLOOR")"

PICKED_COUNT="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$PICKED_JSON")"
if [ "$PICKED_COUNT" -eq 0 ]; then
    log "no cull candidates picked (decisions feed empty or filtered out)"
    exit 0
fi

# Enumerate current specialties so we can pick the most under-
# represented one for the respawn. Reading via `podman exec` keeps the
# join inside the container's memo namespace.
read_specialty_counts() {
    if [ -n "${CULL_SPECIALTY_COUNTS_OVERRIDE:-}" ]; then
        printf '%s\n' "$CULL_SPECIALTY_COUNTS_OVERRIDE"
        return 0
    fi
    python3 -c "
import json, subprocess, sys
daemons = json.loads(sys.argv[1])
colony = sys.argv[2]
container = sys.argv[3]
counts = {}
for d in daemons:
    pid = d.get('pid', 0)
    if not pid:
        continue
    try:
        out = subprocess.run(
            ['podman', 'exec', container,
             'agentis', 'memo', 'get', '%s:%s:specialty' % (colony, pid)],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        continue
    val = (out.stdout or '').strip()
    if not val:
        continue
    counts[val] = counts.get(val, 0) + 1
print(json.dumps(counts))
" "$COLONY_DAEMONS_JSON" "$COLONY_NAME" "$CONTAINER"
}

SPECIALTY_COUNTS_JSON="$(read_specialty_counts)"

# Pick least-represented specialty out of the pool defined for this
# colony in research-foundry/tools/colony-variants.json. Tie-breaker:
# now_ms_via_shell modulo the tied set, kept deterministic enough for
# tests via CULL_NOW_MS_OVERRIDE.
NOW_MS="${CULL_NOW_MS_OVERRIDE:-$(date +%s%3N)}"

# Find the next available DAEMON_ID by scanning the running daemons in
# this colony. The orchestrator seeds DAEMON_ID=1..N at bootstrap; we
# want max(existing) + 1 so the new daemon does not collide with a
# surviving replica's claimed pool slot.
MAX_DAEMON_ID="$(python3 -c "
import json, subprocess, sys
daemons = json.loads(sys.argv[1])
colony = sys.argv[2]
container = sys.argv[3]
max_id = 0
for d in daemons:
    pid = d.get('pid', 0)
    if not pid:
        continue
    # Prefer a daemon_id carried in the JSON itself (used by the test
    # harness via CULL_DAEMONS_JSON_OVERRIDE to exercise the gap-
    # allocation path without a live memo store, per issue #650).
    raw = d.get('daemon_id')
    if isinstance(raw, int) and raw > 0:
        max_id = max(max_id, raw)
    elif isinstance(raw, str) and raw.isdigit():
        max_id = max(max_id, int(raw))
    # Read the DAEMON_ID memo if the agent published one. Fall back to
    # scanning the pool:specialty:<N> slot assignments for occupied ids.
    try:
        out = subprocess.run(
            ['podman', 'exec', container,
             'agentis', 'memo', 'get', '%s:%s:daemon_id' % (colony, pid)],
            capture_output=True, text=True, timeout=5,
        )
        v = (out.stdout or '').strip()
        if v.isdigit():
            max_id = max(max_id, int(v))
    except (OSError, subprocess.SubprocessError):
        pass
# Also enumerate the pool slots; the bootstrap seeds N by default but
# the cull respawn grows the pool by writing pool:specialty:<new-id>
# below.
try:
    out = subprocess.run(
        ['podman', 'exec', container,
         'agentis', 'memo', 'list'],
        capture_output=True, text=True, timeout=5,
    )
    prefix = colony + ':pool:specialty:'
    for line in (out.stdout or '').splitlines():
        line = line.strip()
        if not line.startswith(prefix):
            continue
        # key '<colony>:pool:specialty:<N>' -- take the <N>.
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
    max_id = len(daemons)
print(max_id)
" "$COLONY_DAEMONS_JSON" "$COLONY_NAME" "$CONTAINER" 2>/dev/null || echo "$COLONY_COUNT")"

# Helper: demand-weighted specialty pick from colony-variants.json.
# Invoked once per respawn so the picker re-evaluates after each prior
# respawn has bumped its variant's count (issue #647). For the explorer
# colony in feds that ship no variants file (back-compat), we fall back
# to the hardcoded 5-specialty pool the Phase 3 tool used.
pick_next_specialty() {
    python3 -c "
import json, os, sys
variants_path = sys.argv[1]
colony = sys.argv[2]
counts = json.loads(sys.argv[3])
now_ms = int(sys.argv[4])

pool = []
try:
    with open(variants_path) as f:
        data = json.load(f)
    entry = (data.get('colonies') or {}).get(colony) or {}
    raw_pool = entry.get('variants') or []
    if isinstance(raw_pool, list):
        pool = [str(v) for v in raw_pool if v]
except (OSError, IOError, ValueError):
    pool = []

if not pool and colony == 'explorer':
    # Back-compat fallback: federations that do not ship the variants
    # table still rely on the original 5-specialty pool.
    pool = ['group_theory', 'combinatorics', 'number_theory', 'probability', 'algebra']

if not pool:
    # No variants known; emit empty so the caller can detect the case.
    print('')
    sys.exit(0)

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
" "$VARIANTS_FILE" "$COLONY_NAME" "$1" "$NOW_MS"
}

# Probe once up-front so we can early-exit when no variant pool is
# defined for this colony. The actual per-respawn pick happens inside
# the loop below.
PROBE_SPECIALTY="$(pick_next_specialty "$SPECIALTY_COUNTS_JSON")"
if [ -z "$PROBE_SPECIALTY" ]; then
    log "no variant pool resolved for colony=$COLONY_NAME (missing colony-variants.json entry)"
    exit 0
fi

log "picked $PICKED_COUNT cull candidate(s); first respawn specialty=$PROBE_SPECIALTY (next daemon_id=$((MAX_DAEMON_ID + 1)))"

# Iterate picks. Each pick produces (cull, respawn) ledger rows.
NEXT_ID="$MAX_DAEMON_ID"
LIVE_COUNTS_JSON="$SPECIALTY_COUNTS_JSON"

python3 -c "
import json, sys
print('\n'.join(
    '%s|%s|%s|%s|%s|%s' % (
        r.get('pid', ''),
        r.get('agent_id', ''),
        r.get('specialty', ''),
        r.get('fitness_score', 0),
        r.get('skip_reason', ''),
        r.get('reason', 'fitness_bottom_pct'),
    )
    for r in json.loads(sys.argv[1])
))
" "$PICKED_JSON" | while IFS='|' read -r pid agent_id specialty fitness skip_reason reason; do
    if [ -z "$pid" ]; then
        continue
    fi
    if [ -n "$skip_reason" ]; then
        log "skip pid=$pid: $skip_reason"
        continue
    fi

    # Re-evaluate the demand-weighted picker every respawn so multi-pick
    # batches do not collide on the same specialty (issue #647). The
    # LIVE_COUNTS_JSON map is bumped at the end of each iteration to
    # reflect the just-respawned variant.
    NEXT_SPECIALTY="$(pick_next_specialty "$LIVE_COUNTS_JSON")"

    if [ "$DRY_RUN" = "1" ]; then
        NEW_ID=$((NEXT_ID + 1))
        log "[dry-run] would cull pid=$pid agent_id=$agent_id specialty=$specialty fitness=$fitness reason=$reason"
        log "[dry-run] would respawn $COLONY_NAME with specialty=$NEXT_SPECIALTY daemon_id=$NEW_ID"
        # Bump live counts so the next dry-run iteration's picker re-
        # evaluates against the post-respawn distribution.
        LIVE_COUNTS_JSON="$(python3 -c "
import json, sys
counts = json.loads(sys.argv[1])
sp = sys.argv[2]
counts[sp] = counts.get(sp, 0) + 1
print(json.dumps(counts))
" "$LIVE_COUNTS_JSON" "$NEXT_SPECIALTY")"
        # Bump NEXT_ID so multi-pick dry-run batches allocate distinct
        # daemon_ids — mirrors the live-path increment at lines below
        # which is unreachable from the dry-run branch (#675).
        NEXT_ID="$NEW_ID"
        continue
    fi

    log "cull pid=$pid agent_id=$agent_id specialty=$specialty fitness=$fitness reason=$reason"

    # Stop the daemon via agentis daemon stop. The agent_id maps to the
    # daemon registry uuid inside the container.
    podman exec "$CONTAINER" agentis daemon stop "$agent_id" 2>/dev/null || true

    # Issue #767 bug fix (load-bearing, NOT gated): decrement
    # `colony-<colony>:size` after the daemon stop succeeds. Before
    # this patch the cull pipeline killed daemons and respawned them
    # net-zero but never moved the size counter, so every cull cycle
    # the M2-Malthusian `size >= max_replicas` gate inched closer to
    # being permanently shut. The respawn block below re-increments
    # the same counter so the net-zero invariant on daemon count is
    # preserved (size_post == size_pre). When the daemon-stop call
    # itself fails the decrement still fires -- the SIGTERM fallback
    # above is best-effort and the kill+respawn loop continues
    # regardless. CULL_SIZE_DECREMENT_DISABLED=1 disables this leg
    # for the test harness's net-zero invariant check (#767 test 14).
    if [ "${CULL_SIZE_DECREMENT_DISABLED:-0}" != "1" ]; then
        CURR_SIZE="$(podman exec "$CONTAINER" agentis memo get "colony-$COLONY_NAME:size" 2>/dev/null || echo 0)"
        case "$CURR_SIZE" in
            ''|*[!0-9]*) CURR_SIZE=0 ;;
        esac
        if [ "$CURR_SIZE" -gt 0 ]; then
            NEW_SIZE=$((CURR_SIZE - 1))
            podman exec "$CONTAINER" agentis memo set "colony-$COLONY_NAME:size" "$NEW_SIZE" 2>/dev/null || true
            log "size-decrement colony-$COLONY_NAME:size $CURR_SIZE -> $NEW_SIZE (after cull pid=$pid)"
        else
            log "size-decrement colony-$COLONY_NAME:size already 0 (skipped, pid=$pid)"
        fi
    fi

    # Issue #767: clear the aging cull-self-request marker so a
    # surviving daemon does not re-publish on the next sidecar tick.
    # The .ag's `_age_tick_and_check` is idempotent on the request key,
    # so a stale request would race the respawn picker. Best-effort
    # delete -- some agentis builds expose only the bare `memo del`
    # subcommand; failures are silent.
    podman exec "$CONTAINER" agentis memo del "colony:cull_self_request:$pid" 2>/dev/null || true

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
    # Phase 9 PR-C (#663): include the `side` field
    # (discovery|audit|preprint) sourced from colony-variants.json so
    # ledger consumers can aggregate by pipeline arm. Issue #767:
    # `reason` is now plumbed from the picker so aging-out culls land
    # with `reason=aging` instead of the bottom-pct default.
    python3 -c "
import json, os, sys, time
colony = sys.argv[5]
variants_path = sys.argv[6]
reason = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else 'fitness_bottom_pct'
side = ''
try:
    with open(variants_path) as f:
        data = json.load(f)
    entry = (data.get('colonies') or {}).get(colony) or {}
    side = str(entry.get('side', '') or '')
except (OSError, IOError, ValueError):
    side = ''
row = {
    'ts': int(time.time() * 1000),
    'event': 'cull',
    'colony': colony,
    'side': side,
    'pid': sys.argv[1],
    'agent_id': sys.argv[2],
    'specialty': sys.argv[3],
    'fitness_score': float(sys.argv[4]) if sys.argv[4] else 0.0,
    'reason': reason,
}
sys.stdout.write(json.dumps(row) + '\n')
" "$pid" "$agent_id" "$specialty" "$fitness" "$COLONY_NAME" "$VARIANTS_FILE" "$reason" >> "$REPLICATION_LEDGER"

    # Best-effort memo cleanup. Some agentis builds don't support
    # pattern delete; tolerate failure silently.
    podman exec "$CONTAINER" agentis memo del "$COLONY_NAME:$pid:*" 2>/dev/null || true

    # Allocate the next DAEMON_ID and grow the pool with the chosen
    # specialty so the agent's first-tick claim path can read it.
    NEW_ID=$((NEXT_ID + 1))
    NEXT_ID="$NEW_ID"

    NEW_OVERLAY="$(python3 -c "
import json, os, sys
variants_path = sys.argv[1]
colony = sys.argv[2]
specialty = sys.argv[3]
overlay = ''
try:
    with open(variants_path) as f:
        data = json.load(f)
    entry = (data.get('colonies') or {}).get(colony) or {}
    overlays = entry.get('overlays') or {}
    if isinstance(overlays, dict):
        overlay = str(overlays.get(specialty, '') or '')
except (OSError, IOError, ValueError):
    overlay = ''

if not overlay and colony == 'explorer':
    # Back-compat fallback: explorer overlays preserved from the Phase 3
    # hardcoded table so feds without the variants file keep the same
    # respawn text.
    legacy = {
        'group_theory': 'Focus on finite group invariants: conjugacy classes, character tables, subgroup lattices, automorphism groups. Compute representations and quotients explicitly. Look for coincidences in character degrees, order divisibility, sporadic-vs-classical group behaviour.',
        'combinatorics': 'Focus on enumerative combinatorics: generating functions, bijective proofs, lattice paths, partition identities. Compute small-case counts and look for OEIS matches. Compare known sequences against derived ones for unexpected coincidence.',
        'number_theory': 'Focus on arithmetic functions and sieves: prime counting, Mobius, totient, divisor sums. Compute over small ranges, examine mod-p behaviour, look for unexpected density / equidistribution / sign-change patterns.',
        'probability': 'Focus on random structures: Erdos-Renyi graphs, random matrices, percolation thresholds, asymptotic distributions. Run small Monte Carlo and compare against predicted limits. Look for deviations from the expected scaling.',
        'algebra': 'Focus on representation theory + Lie algebras: irreducible representations, weight diagrams, Casimir invariants, Cartan classification. Compute decomposition of tensor products, dimensions, branching rules. Look for unexpected multiplicities or symmetries.',
    }
    overlay = legacy.get(specialty, '')

print(overlay)
" "$VARIANTS_FILE" "$COLONY_NAME" "$NEXT_SPECIALTY")"

    podman exec "$CONTAINER" agentis memo set "$COLONY_NAME:pool:specialty:$NEW_ID" "$NEXT_SPECIALTY" 2>/dev/null || true
    podman exec "$CONTAINER" agentis memo set "$COLONY_NAME:pool:specialty_overlay:$NEW_ID" "$NEW_OVERLAY" 2>/dev/null || true

    # Spawn the replacement. Env mirrors the bootstrap spawn loop in
    # run-research.sh (DAEMON_ID + replication knobs read by <colony>.ag's
    # first-tick claim path). Background it so the cull tool can return
    # promptly.
    podman exec "$CONTAINER" bash -c "DAEMON_ID=$NEW_ID COLONY_NAME=$COLONY_NAME EXPLORER_GENERATION=0 HOLD_PERIOD=\${HOLD_PERIOD:-4} DISCOVERY_LEDGER=/run-root/discovery-ledger.jsonl REPLICATION_LEDGER=/run-root/replication-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/$COLONY_NAME/agents/$COLONY_NAME.ag --colony $COLONY_NAME --enable-exec --enable-messaging --enable-replication --allow-replica-replication --tick-interval 30000 > /run-root/.agentis/logs/$COLONY_NAME-$NEW_ID.log 2>&1 &" 2>/dev/null || true

    # Issue #767 bug fix (load-bearing, NOT gated): re-increment
    # `colony-<colony>:size` to balance the post-stop decrement above
    # so the net daemon count stays unchanged (kill 1 + spawn 1). The
    # M2-Malthusian `size >= max_replicas` gate consumes this counter
    # at every replicate-success path, so a decrement without a paired
    # increment would freeze the cap permanently after the first cull
    # cycle. CULL_SIZE_DECREMENT_DISABLED=1 toggles both legs so the
    # tests can exercise the pre-#767 baseline.
    if [ "${CULL_SIZE_DECREMENT_DISABLED:-0}" != "1" ]; then
        CURR_SIZE_POST="$(podman exec "$CONTAINER" agentis memo get "colony-$COLONY_NAME:size" 2>/dev/null || echo 0)"
        case "$CURR_SIZE_POST" in
            ''|*[!0-9]*) CURR_SIZE_POST=0 ;;
        esac
        NEW_SIZE_POST=$((CURR_SIZE_POST + 1))
        podman exec "$CONTAINER" agentis memo set "colony-$COLONY_NAME:size" "$NEW_SIZE_POST" 2>/dev/null || true
        log "size-increment colony-$COLONY_NAME:size $CURR_SIZE_POST -> $NEW_SIZE_POST (after respawn daemon_id=$NEW_ID)"
    fi

    # Append the respawn row. Phase 9 PR-C (#663): include the `side`
    # field sourced from colony-variants.json. Issue #767: respawn rows
    # carry `kill_reason` so ledger readers can correlate the kill cause
    # (aging vs fitness_bottom_pct) with the replacement.
    python3 -c "
import json, sys, time
colony = sys.argv[4]
variants_path = sys.argv[5]
kill_reason = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else 'fitness_bottom_pct'
side = ''
try:
    with open(variants_path) as f:
        data = json.load(f)
    entry = (data.get('colonies') or {}).get(colony) or {}
    side = str(entry.get('side', '') or '')
except (OSError, IOError, ValueError):
    side = ''
row = {
    'ts': int(time.time() * 1000),
    'event': 'respawn',
    'colony': colony,
    'side': side,
    'daemon_id': int(sys.argv[1]),
    'specialty': sys.argv[2],
    'generation': 0,
    'reason': 'cull_replacement',
    'kill_reason': kill_reason,
    'replaced_pid': sys.argv[3],
}
sys.stdout.write(json.dumps(row) + '\n')
" "$NEW_ID" "$NEXT_SPECIALTY" "$pid" "$COLONY_NAME" "$VARIANTS_FILE" "$reason" >> "$REPLICATION_LEDGER"

    log "respawned $COLONY_NAME daemon_id=$NEW_ID specialty=$NEXT_SPECIALTY reason=$reason (replaced pid=$pid)"

    # Bump live counts so the next iteration's picker re-evaluates
    # against the post-respawn distribution (issue #647).
    LIVE_COUNTS_JSON="$(python3 -c "
import json, sys
counts = json.loads(sys.argv[1])
sp = sys.argv[2]
counts[sp] = counts.get(sp, 0) + 1
print(json.dumps(counts))
" "$LIVE_COUNTS_JSON" "$NEXT_SPECIALTY")"
done

log "done"
