#!/usr/bin/env bash
# tools/lib/daemon-restart.sh — shared single-agent restart machine for the
# --restart-agent path of every colony's start-colony.sh (#1357; extracted
# from the five identical inline kill/poll/verify blocks added in #285).
#
# The daemon registry (`agentis daemon list`) indexes by agent_id and
# collapses duplicates to a single entry, so a silently-accumulated old
# daemon-inner process is invisible from that view. This helper queries the
# JSON form by colony + source-path suffix (backend-agnostic), SIGTERMs the
# live PID, polls every 0.2s × 25 iterations (5s) for exit, SIGKILLs
# survivors + 1s settle, then best-effort removes the registry sidecar files
# (`pid`, `watchdog.pid`, `colony`, `heartbeat`, `status`, `stop`) so the
# registry does not carry a stale pointer to the dead agent_id. Pattern
# mirrors tools/kill-federation.sh (#161/#162) applied at per-agent scope.
#
# This is the interim consolidation of the restart machine; the end state is
# an `agentis daemon restart` subcommand in agentis-core (see
# doc/adr/daemon-restart-supervision.md for the evaluation). The `agentis
# daemon` LAUNCH, its liveness verification, and the parseable
# `started <agent> pid=<n> tick=<ms>` stdout line stay in each colony's
# start-colony.sh — those are irreducibly shell.
#
# Dependencies: bash + python3 + the `agentis daemon list --json` CLI.
#
# Usage: source this file, then:
#   daemon_restart_kill_existing <fed_root> <colony_name> <agent_name>
#
# Always returns 0. A missing registry entry, an already-dead PID, malformed
# registry JSON, and a failed sidecar rm are all best-effort no-ops — the
# callers run under `set -e` and a respawn must never be aborted because
# pre-spawn cleanup found nothing to clean.

# daemon_restart_kill_existing <fed_root> <colony_name> <agent_name>
#   fed_root    — federation root (the directory holding .agentis/), the cwd
#                 for the registry query and the base for sidecar cleanup
#   colony_name — registry `colony` field to match (e.g. "implementation")
#   agent_name  — agent whose `source` ends in /agents/<agent_name>.ag
daemon_restart_kill_existing() {
    local fed_root="$1"
    local colony_name="$2"
    local agent_name="$3"
    local existing_entry existing_pid existing_agent_id i ext

    # `agentis daemon list` is a read-only registry query, not a daemon launch;
    # the indirection via AGENTIS_BIN keeps colony-lint's launch-flag whitelist
    # (#68/#71) from misreading `--json` as a daemon flag on the same line.
    local AGENTIS_BIN=agentis
    # shellcheck disable=SC2015 # pipe to python3, not an if-then-else
    existing_entry="$(cd "$fed_root" && "$AGENTIS_BIN" daemon list --json 2>/dev/null | python3 -c '
import json, sys
try:
    daemons = json.load(sys.stdin)
except Exception:
    sys.exit(0)
colony = sys.argv[1]
suffix = "/agents/" + sys.argv[2] + ".ag"
for d in daemons:
    if d.get("colony") == colony and str(d.get("source", "")).endswith(suffix):
        pid = d.get("pid")
        aid = d.get("agent_id", "") or ""
        if isinstance(pid, int) and pid > 0:
            print("%d|%s" % (pid, aid))
            break
' "$colony_name" "$agent_name" 2>/dev/null || true)"
    existing_pid="${existing_entry%%|*}"
    existing_agent_id="${existing_entry#*|}"
    [ "$existing_pid" = "$existing_entry" ] && existing_agent_id=""
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        kill -TERM "$existing_pid" 2>/dev/null || true
        i=0
        while [ "$i" -lt 25 ]; do
            kill -0 "$existing_pid" 2>/dev/null || break
            sleep 0.2
            i=$((i + 1))
        done
        if kill -0 "$existing_pid" 2>/dev/null; then
            kill -KILL "$existing_pid" 2>/dev/null || true
            sleep 1
        fi
    fi
    if [ -n "$existing_agent_id" ]; then
        for ext in pid watchdog.pid colony heartbeat status stop; do
            rm -f "$fed_root/.agentis/daemon/${existing_agent_id}.${ext}" 2>/dev/null || true
        done
    fi
    return 0
}
