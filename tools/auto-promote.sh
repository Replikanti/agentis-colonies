#!/usr/bin/env bash
# auto-promote.sh — Layer 1 auto-promote / auto-evolve scheduler script
#
# Reads experience + memo + daemon state, evaluates per-agent fitness
# rules from auto-promote-config.yaml, and promotes or evolves agents
# whose metrics meet the thresholds.
#
# Intended to be invoked periodically (e.g. every 30 min) by the
# sidecar that `dev-apprenticeship/start-federation.sh` spawns when
# `.auto-promote-install.toml` (written by install.sh §7) has
# `enabled = true`. See #216. Safe to run when the federation is
# stopped — exits 0 with a no-op log line.
#
# All actions default to --dry-run (config: dry_run: true). Flip to
# false in auto-promote-config.yaml only after reviewing the journal.
#
# Promote ladder (four-tier, ADR-0001 / #177): the steps list in
# auto-promote-config.yaml drives progression shadow(0.4) -> propose(0.6)
# -> review-gated(0.8) -> autonomous(0.95). This script is fully
# YAML-driven — no numeric thresholds are hardcoded here.
#
# Fitness signal (#186): rows in the experience store are classified
# by their `tags` field into acting / observe / legacy-untagged buckets.
# reject_rate and delta_slope are computed on acting rows only, so
# observe-step noise cannot swamp evidence for tier-gated behaviour.
# See doc/auto-promote.md for the full DMN decision table and formula
# derivation.
#
# Usage: ./tools/auto-promote.sh <federation-dir> [--live]
#        ./tools/auto-promote.sh <federation-dir> [--containerized] [--config <path>]
#        ./tools/auto-promote.sh dev-apprenticeship
#        ./tools/auto-promote.sh dev-apprenticeship --live   # override dry_run
#        ./tools/auto-promote.sh /run-root/laptop-node --containerized \
#            --config tools/auto-promote-config.research-foundry.yaml
#
# --containerized opts out of the dev-apprenticeship-specific
# `[gitlab]`-in-colony.toml respawn path; the forge-less
# `research-foundry/` federation needs this because its 18 colonies
# have `forge.type = "none"` and the daemon must be respawned without
# GITLAB_* env composition (#622, #638).
#
# --config overrides the default tools/auto-promote-config.yaml path.
#
# Prerequisites: agentis, python3 (with PyYAML or a fallback parser)
#
# Layer 1 of the auto-governance roadmap (#148). See README for layers 2+3.

set -euo pipefail

# --- Path resolution ---

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <federation-dir> [--live] [--containerized] [--config <path>]"
    echo "Example: $0 dev-apprenticeship"
    echo "Example: $0 /path/to/run/laptop-node --containerized --config tools/auto-promote-config.research-foundry.yaml"
    exit 1
fi

# First positional arg is always the federation dir (or run-dir/laptop-node in
# containerized mode). Remaining args are parsed as flags below.
FED_ARG="$1"
shift

FED_DIR="$REPO_ROOT/$FED_ARG"
if [ ! -d "$FED_DIR" ]; then
    FED_DIR="$FED_ARG"  # try as absolute/relative path
fi
if [ ! -d "$FED_DIR" ]; then
    echo "Federation directory not found: $FED_ARG"
    exit 1
fi

LIVE_OVERRIDE=false
CONTAINERIZED=false
CONFIG_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --live)
            LIVE_OVERRIDE=true
            shift
            ;;
        --containerized)
            CONTAINERIZED=true
            shift
            ;;
        --config)
            if [ $# -lt 2 ]; then
                echo "auto-promote: --config requires a path argument" >&2
                exit 1
            fi
            CONFIG_OVERRIDE="$2"
            shift 2
            ;;
        *)
            echo "auto-promote: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [ -n "$CONFIG_OVERRIDE" ]; then
    # Resolve --config against $REPO_ROOT first (so callers may pass a
    # repo-relative path like `tools/auto-promote-config.research-foundry.yaml`),
    # then fall back to treating it as an absolute/relative path verbatim.
    if [ -f "$REPO_ROOT/$CONFIG_OVERRIDE" ]; then
        CONFIG_FILE="$REPO_ROOT/$CONFIG_OVERRIDE"
    else
        CONFIG_FILE="$CONFIG_OVERRIDE"
    fi
else
    CONFIG_FILE="$SCRIPT_DIR/auto-promote-config.yaml"
fi
JOURNAL_FILE="$SCRIPT_DIR/auto-promote-journal.jsonl"
LOCK_FILE="$SCRIPT_DIR/.auto-promote.lock"

# --- Safety guard 2: Lock file (advisory, atomic) ---
# The parent shell opens fd 200 on LOCK_FILE, then the Python helper calls
# fcntl.flock(LOCK_EX | LOCK_NB) on the inherited fd. POSIX flock locks are
# per open-file-description: the helper exits after acquiring, but the lock
# persists as long as this shell keeps fd 200 open — which it does until the
# whole run exits. Replaces the flock(1) binary from util-linux, which is not
# present on stock macOS (#245).
#
# Note: on NFS fcntl.flock is advisory and subject to server quirks. The
# LOCK_FILE sits in $SCRIPT_DIR next to the script, which is a local FS on
# every supported install path.

exec 200>"$LOCK_FILE"
if ! python3 "$SCRIPT_DIR/auto-promote-lock.py" 200 "$LOCK_FILE" 2>/dev/null; then
    echo "Another auto-promote instance is running. Exiting."
    exit 0
fi
# fd 200 is held until the process exits — no cleanup trap needed.

# --- Logging + journal helpers ---

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] auto-promote: $*"
}

# Append a structured JSON line to the journal.
# Args: agent, decision, evidence_json [, from, to]
# Matches the spec format from #148: top-level from/to + evidence object.
journal_append() {
    local agent="$1" decision="$2" evidence_json="$3"
    local step_from="${4:-}" step_to="${5:-}"
    python3 -c "
import json, sys, time
entry = {
    'ts': int(time.time()),
    'ts_iso': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'agent': sys.argv[1],
    'decision': sys.argv[2],
    'dry_run': sys.argv[3] == 'true',
    'evidence': json.loads(sys.argv[4]),
}
if sys.argv[5]:
    try: entry['from'] = float(sys.argv[5])
    except ValueError: pass
if sys.argv[6]:
    try: entry['to'] = float(sys.argv[6])
    except ValueError: pass
print(json.dumps(entry))
" "$agent" "$decision" "$DRY_RUN" "$evidence_json" "$step_from" "$step_to" >> "$JOURNAL_FILE"
}

# --- Parse config ---

if [ ! -f "$CONFIG_FILE" ]; then
    log "Config not found: $CONFIG_FILE"
    exit 1
fi

# Parse YAML config into shell variables. Config parsing lives in
# auto-promote-config-parser.py (tries PyYAML, falls back to a minimal
# parser). Inlining that block in a `eval "$(python3 - <<'PYCONFIG' ...)"`
# heredoc tripped the macOS bash 3.2 parser — same class of bug as #170 /
# #172 fixed for federation-dashboard.sh. See #245.
eval "$(python3 "$SCRIPT_DIR/auto-promote-config-parser.py" "$CONFIG_FILE")"

# --live flag overrides config dry_run
if [ "$LIVE_OVERRIDE" = "true" ]; then
    DRY_RUN="false"
else
    DRY_RUN="$CFG_DRY_RUN"
fi

log "Starting (dry_run=$DRY_RUN, fed=$FED_DIR)"

# --- Safety guard 1: Federation running check ---

# All agentis CLI commands must run from $FED_DIR so the CLI finds
# .agentis/ (daemon registry, memo store, experience). Matches the
# cwd=fed_dir pattern in federation-dashboard.sh.
DAEMONS_JSON=$(cd "$FED_DIR" && agentis daemon list --json 2>/dev/null 200>&- || echo "[]")
DAEMON_COUNT=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d))" "$DAEMONS_JSON")

if [ "$DAEMON_COUNT" -eq 0 ]; then
    # #177: no journal row for federation-down — otherwise a weekend with
    # the federation stopped accumulates ~96 identical _system no-op rows
    # (scheduler ticks every 30 min). The tick log still records the no-op.
    log "Federation not running, no-op"
    exit 0
fi

log "Found $DAEMON_COUNT daemon(s) running"

# --- Build per-agent state ---
# For each running daemon, collect: agent name, colony, pid, confidence,
# experience entry count, reject rate, delta slope.

if [ "$CONTAINERIZED" = "true" ]; then
    CONTAINERIZED_ARG="true"
else
    CONTAINERIZED_ARG="false"
fi
DECISIONS_JSON=$(python3 "$SCRIPT_DIR/auto-promote-decisions.py" \
    "$DAEMONS_JSON" "$FED_DIR" \
    "$CFG_MIN_ENTRIES" "$CFG_MIN_ACTING_ENTRIES" "$CFG_MIN_RUNTIME_HOURS" \
    "$CFG_REJECT_RATE_THRESHOLD" "$CFG_DELTA_SLOPE_WINDOW" "$CFG_DELTA_SLOPE_MIN" \
    "$CFG_PROMOTE_STEPS" "$CFG_EVOLVE_SLOPE_NEG_FOR" "$CFG_EVOLVE_REJECT_ABOVE" \
    "$CONTAINERIZED_ARG")

# --- Execute decisions ---

PROMOTE_COUNT=0
EVOLVE_COUNT=0
SKIP_COUNT=0

# Parse decisions and act on each.
# Process substitution (< <(...)) instead of pipe so the while loop runs
# in the current shell — counter variables survive after the loop.
while IFS='|' read -r decision agent colony step_from step_to reason evidence_json; do

    case "$decision" in
        skip)
            log "SKIP $agent ($colony): $reason"
            journal_append "$agent" "skip" "$evidence_json"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            ;;

        promote)
            log "PROMOTE $agent ($colony): $step_from -> $step_to"
            if [ "$DRY_RUN" = "true" ]; then
                log "  [dry-run] Would run: agentis memo set ${agent}:confidence $step_to"
                log "  [dry-run] Would restart daemon for $agent"
                journal_append "$agent" "promote" \
                    "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['action']='dry-run'; print(json.dumps(e))" "$evidence_json")" \
                    "$step_from" "$step_to"
            else
                # Write new confidence to memo (cwd=FED_DIR for .agentis/ resolution)
                log "  Writing confidence: agentis memo set ${agent}:confidence $step_to"
                if (cd "$FED_DIR" && agentis memo set "${agent}:confidence" "$step_to") 2>&1; then
                    log "  Memo written successfully"
                else
                    log "  WARNING: memo set failed for $agent"
                    journal_append "$agent" "promote-failed" \
                        "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['error']='memo_set_failed'; print(json.dumps(e))" "$evidence_json")" \
                        "$step_from" "$step_to"
                    continue
                fi

                # Restart the daemon so it picks up the new confidence.
                # Use the same stop+respawn pattern as the dashboard (#137).
                # The respawn must export GITLAB_* env vars from colony.toml
                # (the scheduler's environment won't have them).
                log "  Restarting daemon for $agent..."
                AGENT_AG_FILE=""
                AGENT_COLONY_DIR=""
                for cdir in "$FED_DIR"/*/; do
                    candidate="${cdir}agents/${agent}.ag"
                    if [ -f "$candidate" ]; then
                        AGENT_AG_FILE="$candidate"
                        AGENT_COLONY_DIR="$cdir"
                        break
                    fi
                done

                if [ -z "$AGENT_AG_FILE" ]; then
                    log "  WARNING: could not find .ag file for $agent, skipping restart"
                    journal_append "$agent" "promote-partial" \
                        "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['action']='memo-only'; e['warning']='ag_file_not_found'; print(json.dumps(e))" "$evidence_json")" \
                        "$step_from" "$step_to"
                    continue
                fi

                # Read gitlab config from colony.toml (mirrors dashboard restart_daemon).
                # Skipped in --containerized mode: research federations use
                # `forge.type = "none"` and the daemon respawns without
                # GITLAB_* env composition (#622).
                if [ "$CONTAINERIZED" = "true" ]; then
                    SPAWN_ENV="export COLONY_DIR=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$AGENT_COLONY_DIR")"
                else
                    COLONY_TOML="${AGENT_COLONY_DIR}config/colony.toml"
                    SPAWN_ENV=$(python3 -c "
import sys, os
toml_path = sys.argv[1]
colony_dir = sys.argv[2]
# Minimal TOML [gitlab] section reader (same approach as federation-dashboard.sh)
vals = {}
in_section = False
try:
    with open(toml_path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('[') and line.endswith(']'):
                in_section = (line[1:-1].strip() == 'gitlab')
                continue
            if not in_section or '=' not in line:
                continue
            k, _, v = line.partition('=')
            k = k.strip()
            v = v.strip().strip('\"').strip(\"'\")
            vals[k] = v
except OSError:
    pass
url = vals.get('url', '')
token = vals.get('token', '')
project_raw = vals.get('project', '')
me = vals.get('me', '')
if not url or not token or not project_raw:
    print('__INCOMPLETE__')
else:
    project = project_raw.replace('/', '%2F')
    # Shell-safe export statements
    import shlex
    print(f'export GITLAB_URL={shlex.quote(url)}')
    print(f'export GITLAB_TOKEN={shlex.quote(token)}')
    print(f'export GITLAB_PROJECT={shlex.quote(project)}')
    print(f'export GITLAB_ME={shlex.quote(me)}')
    print(f'export COLONY_DIR={shlex.quote(colony_dir)}')
" "$COLONY_TOML" "$AGENT_COLONY_DIR" 2>/dev/null)

                    if [ "$SPAWN_ENV" = "__INCOMPLETE__" ] || [ -z "$SPAWN_ENV" ]; then
                        log "  WARNING: incomplete [gitlab] in $COLONY_TOML, skipping restart"
                        journal_append "$agent" "promote-partial" \
                            "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['action']='memo-only'; e['warning']='incomplete_colony_toml'; print(json.dumps(e))" "$evidence_json")" \
                            "$step_from" "$step_to"
                        continue
                    fi
                fi

                # Find agent_id from daemon list
                AGENT_ID=$(python3 -c "
import json, sys, os
daemons = json.loads(sys.argv[1])
agent = sys.argv[2]
for d in daemons:
    src = d.get('source', '')
    if os.path.basename(src) == agent + '.ag':
        print(d.get('agent_id', ''))
        break
" "$DAEMONS_JSON" "$agent")

                # Stop the daemon (cwd=FED_DIR for .agentis/ resolution)
                if [ -n "$AGENT_ID" ]; then
                    (cd "$FED_DIR" && agentis daemon stop "$AGENT_ID" 200>&-) 2>&1 || true
                    sleep 3
                fi

                # Resolve per-agent tick interval from start-colony.sh (#155)
                TICK_INTERVAL=$(python3 "$SCRIPT_DIR/resolve-tick-interval.py" "$agent" "$AGENT_COLONY_DIR" 2>/dev/null) || true
                TICK_INTERVAL="${TICK_INTERVAL:-60000}"

                # Respawn with GITLAB_* env vars from colony.toml
                (
                    eval "$SPAWN_ENV"
                    cd "$AGENT_COLONY_DIR"
                    agentis daemon "$AGENT_AG_FILE" \
                        --colony "$colony" \
                        --enable-exec \
                        --enable-messaging \
                        --tick-interval "$TICK_INTERVAL" 200>&- &
                )
                log "  Daemon respawned for $agent"

                journal_append "$agent" "promote" \
                    "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['action']='executed'; print(json.dumps(e))" "$evidence_json")" \
                    "$step_from" "$step_to"
            fi
            PROMOTE_COUNT=$((PROMOTE_COUNT + 1))
            ;;

        evolve)
            log "EVOLVE $agent ($colony): $reason"
            if [ "$DRY_RUN" = "true" ]; then
                log "  [dry-run] Would run: agentis evolve $agent.ag (generations=$CFG_EVOLVE_GENERATIONS, population=$CFG_EVOLVE_POPULATION)"
                journal_append "$agent" "evolve" \
                    "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['action']='dry-run'; print(json.dumps(e))" "$evidence_json")"
            else
                # Find the .ag file for the agent
                AGENT_AG_FILE=""
                for cdir in "$FED_DIR"/*/; do
                    candidate="${cdir}agents/${agent}.ag"
                    if [ -f "$candidate" ]; then
                        AGENT_AG_FILE="$candidate"
                        break
                    fi
                done

                if [ -z "$AGENT_AG_FILE" ]; then
                    log "  WARNING: could not find .ag file for $agent, skipping evolve"
                    journal_append "$agent" "evolve-failed" \
                        "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['error']='ag_file_not_found'; print(json.dumps(e))" "$evidence_json")"
                    continue
                fi

                # Phase 7 PR-A (#628): when `evolve.mutation.enabled=true`
                # in the active config, route to the new auto-evolve-ab
                # harness (mutator + validity gate + A/B + ledger). The
                # legacy `agentis evolve` path is preserved unchanged
                # when the flag is false (default), so dev-apprenticeship
                # and every pre-#628 federation keeps its existing
                # behaviour.
                if [ "${CFG_EVOLVE_MUTATION_ENABLED:-false}" = "true" ]; then
                    log "  Routing to auto-evolve-ab.sh (mutation.enabled=true)"
                    # PR-B (#628): pass --containerized through so the
                    # A/B harness uses `podman exec` for the candidate
                    # daemon spawn (research-foundry path). Non-
                    # containerized federations stay on the legacy
                    # `agentis evolve` path because mutation.enabled
                    # defaults to false there. Plain positional args
                    # avoid bash arrays (macOS 3.2 portability).
                    if [ "$CONTAINERIZED" = "true" ]; then
                        EVOLVE_OUTPUT=$("$SCRIPT_DIR/auto-evolve-ab.sh" \
                            "$FED_DIR" "$agent" "$colony" "$AGENT_AG_FILE" \
                            --ticks "$CFG_EVOLVE_AB_TICKS" \
                            --config "$CONFIG_FILE" \
                            --containerized 2>&1) || true
                    else
                        EVOLVE_OUTPUT=$("$SCRIPT_DIR/auto-evolve-ab.sh" \
                            "$FED_DIR" "$agent" "$colony" "$AGENT_AG_FILE" \
                            --ticks "$CFG_EVOLVE_AB_TICKS" \
                            --config "$CONFIG_FILE" 2>&1) || true
                    fi
                    log "  Auto-evolve-ab output: $EVOLVE_OUTPUT"

                    journal_append "$agent" "evolve" \
                        "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['action']='auto-evolve-ab'; e['evolve_output']=sys.argv[2][:500]; print(json.dumps(e))" "$evidence_json" "$EVOLVE_OUTPUT")"
                else
                    log "  Running: agentis evolve $AGENT_AG_FILE"
                    EVOLVE_OUTPUT=$(cd "$FED_DIR" && agentis evolve "$AGENT_AG_FILE" \
                        --generations "$CFG_EVOLVE_GENERATIONS" \
                        --population "$CFG_EVOLVE_POPULATION" \
                        --weights "$CFG_EVOLVE_WEIGHTS" 2>&1) || true
                    log "  Evolve output: $EVOLVE_OUTPUT"

                    journal_append "$agent" "evolve" \
                        "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['action']='executed'; e['evolve_output']=sys.argv[2][:500]; print(json.dumps(e))" "$evidence_json" "$EVOLVE_OUTPUT")"
                fi
            fi
            EVOLVE_COUNT=$((EVOLVE_COUNT + 1))
            ;;
    esac
done < <(python3 -c "
import json, sys
decisions = json.loads(sys.argv[1])
for d in decisions:
    decision = d.get('decision', 'skip')
    agent = d.get('agent', '')
    colony = d.get('colony', '')
    step_from = d.get('from', '')
    step_to = d.get('to', '')
    reason = d.get('reason', '')
    evidence = json.dumps(d.get('evidence', d))
    print(f'{decision}|{agent}|{colony}|{step_from}|{step_to}|{reason}|{evidence}')
" "$DECISIONS_JSON")

log "Done. Promotes=$PROMOTE_COUNT, Evolves=$EVOLVE_COUNT, Skips=$SKIP_COUNT"
