#!/bin/bash
# start-federation.sh - Start all 5 colonies of the Dev Apprenticeship federation
#
# Launches triage, code-review, planning, implementation, and release colonies
# in sequence. Each colony starts its agents as background daemon processes.
#
# Usage: ./start-federation.sh [path/to/federation-dir]
#        ./start-federation.sh              # uses script's own directory
#
# Env vars (forwarded to start-colony.sh):
#   TRUNCATE_LOGS=1   zero out .agentis/logs/*.log at spawn time.
#                     Zero-config fallback for boxes without logrotate;
#                     loses history between restarts. For long-running
#                     federations, use ops/logrotate.conf instead.

set -e

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="${1:-$SCRIPT_DIR}"

COLONIES=(triage code-review planning implementation release)

echo ""
echo "Dev Apprenticeship Federation"
echo "============================="
echo ""

# Refuse to start if any agentis daemon is already running under this
# federation root. A second invocation would spawn 21 more daemons
# racing the first set for the same GitLab project (dup labels, dup
# comments, dup MRs) and there is no safe way to untangle them after
# the fact — stop-all hits both generations equally.
#
# NB: `agentis daemon list` writes the human-readable table to stderr
# (eprintln! in agentis-core src/cli/daemon.rs), so the previous
# version of this guard grepped empty stdout and never matched.
# `--json` goes to stdout and is table-layout-stable, so we key on
# the structured field instead of the table row.
if agentis daemon list --json 2>/dev/null | grep -Fq '"state":"running"'; then
    echo "[!!] A federation is already running under this directory."
    echo "     Stop it first:  agentis daemon stop --all"
    echo "     Inspect it:     agentis daemon list"
    exit 1
fi

# Pre-flight: check all configs exist
for colony in "${COLONIES[@]}"; do
    CONFIG="$FED_DIR/$colony/config/colony.toml"
    if [ ! -f "$CONFIG" ]; then
        echo "[!!] Missing config: $CONFIG"
        echo "     Run ./install.sh first."
        exit 1
    fi
done

# After laptop sleep/reboot, heartbeat files under .agentis/daemon/
# retain the pre-sleep mtime and the watchdog reads them as "last
# heartbeat was N hours ago", killing every fresh child on its first
# tick. Wipe them before any child writes a fresh one. Safe because
# the double-start guard above proved there is no live federation to
# disrupt.
#
# #302: the original wipe targeted "$FED_DIR/.agentis/daemon" which is
# an empty placeholder dir created by install.sh §4. The actual agentis
# registry lives at "$FED_DIR/../.agentis/daemon" (repo root); each
# colony has a `.agentis` symlink pointing there. Daemons resolve their
# agentis_root by walking up from cwd, so the heartbeat files always
# materialise in the repo-root .agentis, never the federation-dir one.
# Sweep both paths to cover legacy installs (real .agentis under fed)
# AND the modern symlink layout (real .agentis at repo root).
for candidate in "$FED_DIR/.agentis/daemon" "$FED_DIR/../.agentis/daemon"; do
    if [ -d "$candidate" ]; then
        # *.pid / *.status / *.watchdog.pid go stale on the same axis as
        # *.heartbeat — on wake they point at PIDs from the previous boot
        # which may now belong to an unrelated process. Sweep them all.
        rm -f "$candidate"/*.heartbeat \
              "$candidate"/*.pid \
              "$candidate"/*.status \
              "$candidate"/*.watchdog.pid 2>/dev/null || true
    fi
done

# Start each colony
TOTAL_AGENTS=0
for colony in "${COLONIES[@]}"; do
    echo "Starting $colony colony..."
    "$FED_DIR/$colony/scripts/start-colony.sh" &
    # Count agents in this colony's config
    AGENT_COUNT=$(grep -c '^\[\[agents\]\]' "$FED_DIR/$colony/config/colony.toml" 2>/dev/null || echo 0)
    TOTAL_AGENTS=$((TOTAL_AGENTS + AGENT_COUNT))
    sleep 3  # stagger colony starts
done

echo ""
echo "============================="
echo "Federation started: 5 colonies, $TOTAL_AGENTS agents"
echo ""
echo "Monitor:"
echo "  agentis daemon list           # Running agents"
echo "  agentis federation status     # Federation overview"
echo "  agentis colony health         # Colony health"
echo "  tail -f .agentis/logs/<agent>.log"
echo ""
echo "Stop:     agentis daemon stop --all"
echo ""

# --- Auto-promote scheduler sidecar (#216) ---
#
# Reads .auto-promote-install.toml (written by install.sh §7) and, if
# enabled, spawns a background loop that invokes tools/auto-promote.sh
# every interval_s seconds. The sidecar self-terminates once no agentis
# daemons are running under this federation (e.g. after kill-federation.sh
# has swept them), so its lifetime tracks the federation's without
# needing kill-federation.sh to know about it. A trap on EXIT/TERM/INT
# kills it immediately when the operator Ctrl-Cs this script.
AUTO_PROMOTE_INSTALL_FILE="$FED_DIR/.auto-promote-install.toml"
AUTO_PROMOTE_PID=""
AP_PARSE_TOML="$SCRIPT_DIR/../tools/parse-toml.sh"
if [ -f "$AUTO_PROMOTE_INSTALL_FILE" ]; then
    if [ ! -r "$AP_PARSE_TOML" ]; then
        # Broken checkout — parse-toml.sh is expected to ship with the repo.
        # Sourcing a missing file under `set -e` would error-exit after the
        # 5 colonies have already been backgrounded, orphaning them. Skip
        # the sidecar block instead and let the federation run without it.
        echo "[!!] Auto-promote scheduler: tools/parse-toml.sh not readable, skipping."
    else
        CONFIG="$AUTO_PROMOTE_INSTALL_FILE"
        # shellcheck source=../tools/parse-toml.sh
        source "$AP_PARSE_TOML"
        AP_ENABLED="$(parse_toml auto_promote enabled 2>/dev/null || true)"
        AP_INTERVAL="$(parse_toml auto_promote interval_s 2>/dev/null || true)"
        case "$AP_INTERVAL" in
            ''|*[!0-9]*) AP_INTERVAL=1800 ;;
            *) [ "$AP_INTERVAL" -gt 0 ] || AP_INTERVAL=1800 ;;
        esac
        if [ "$AP_ENABLED" = "true" ]; then
            AP_LOG_DIR="$FED_DIR/.agentis/logs"
            AP_LOG="$AP_LOG_DIR/auto-promote.log"
            mkdir -p "$AP_LOG_DIR"
            AP_SCRIPT="$SCRIPT_DIR/../tools/auto-promote.sh"
            AP_FED_NAME="$(basename "$FED_DIR")"
            if [ ! -x "$AP_SCRIPT" ]; then
                echo "[!!] Auto-promote scheduler: tools/auto-promote.sh not executable, skipping."
            else
                # Stamp sidecar start time so the dashboard collector can
                # distinguish "fresh sidecar that hasn't ticked yet" from
                # "stuck sidecar that has stopped ticking" (#274). The
                # template suppresses DEGRADED while now-started_at <
                # interval_s + 120s grace.
                date +%s > "$AP_LOG_DIR/auto-promote.sidecar_started_at"
                (
                    # First action is a tick (not a sleep) so log activity
                    # appears immediately after spawn — the dashboard's
                    # liveness probe is satisfied on first regen instead of
                    # after a full interval_s (#274).
                    while :; do
                        if ! agentis daemon list --json 2>/dev/null | grep -Fq '"state":"running"'; then
                            printf '=== %s: no running daemons; sidecar exiting ===\n' \
                                "$(date -Iseconds)" >> "$AP_LOG"
                            exit 0
                        fi
                        {
                            printf '=== %s: sidecar tick ===\n' "$(date -Iseconds)"
                            "$AP_SCRIPT" "$AP_FED_NAME" 2>&1 \
                                || printf '[sidecar] auto-promote.sh exited %s\n' "$?"
                        } >> "$AP_LOG"
                        sleep "$AP_INTERVAL"
                    done
                ) &
                AUTO_PROMOTE_PID=$!
                # shellcheck disable=SC2064  # Expand PID at trap-install time, not at trigger time.
                trap "[ -n \"$AUTO_PROMOTE_PID\" ] && kill \"$AUTO_PROMOTE_PID\" 2>/dev/null; [ -n \"\${COST_CAP_PID:-}\" ] && kill \"\$COST_CAP_PID\" 2>/dev/null; [ -n \"\${SNAPSHOT_REFRESH_PID:-}\" ] && kill \"\$SNAPSHOT_REFRESH_PID\" 2>/dev/null; [ -n \"\${COST_RATE_PID:-}\" ] && kill \"\$COST_RATE_PID\" 2>/dev/null; exit" EXIT TERM INT
                echo "Auto-promote scheduler: PID $AUTO_PROMOTE_PID, every ${AP_INTERVAL}s (log: .agentis/logs/auto-promote.log)"
                echo ""
            fi
        fi
    fi
fi

# --- Cost-cap sidecar (#318) ---
#
# Reads .cost-cap.toml (written by install.sh §7.5) and, if enabled,
# spawns a background loop that invokes tools/cost-cap.sh every
# interval_s seconds. Mirrors the auto-promote sidecar shape: TOML
# presence gate, self-terminate when the federation has zero running
# daemons, EXIT/TERM/INT trap. Stamps cost-cap.sidecar_started_at for
# the dashboard liveness check (#274 grace logic).
COST_CAP_INSTALL_FILE="$FED_DIR/.cost-cap.toml"
COST_CAP_PID=""
CC_PARSE_TOML="$SCRIPT_DIR/../tools/parse-toml.sh"
if [ -f "$COST_CAP_INSTALL_FILE" ]; then
    if [ ! -r "$CC_PARSE_TOML" ]; then
        echo "[!!] Cost-cap sidecar: tools/parse-toml.sh not readable, skipping."
    else
        CONFIG="$COST_CAP_INSTALL_FILE"
        # shellcheck source=../tools/parse-toml.sh
        source "$CC_PARSE_TOML"
        CC_ENABLED_VAL="$(parse_toml cost enabled 2>/dev/null || true)"
        CC_INTERVAL="$(parse_toml cost interval_s 2>/dev/null || true)"
        case "$CC_INTERVAL" in
            ''|*[!0-9]*) CC_INTERVAL=60 ;;
            *) [ "$CC_INTERVAL" -gt 0 ] || CC_INTERVAL=60 ;;
        esac
        if [ "$CC_ENABLED_VAL" = "true" ]; then
            CC_LOG_DIR="$FED_DIR/.agentis/logs"
            CC_LOG="$CC_LOG_DIR/cost-cap.log"
            mkdir -p "$CC_LOG_DIR"
            CC_SCRIPT="$SCRIPT_DIR/../tools/cost-cap.sh"
            CC_FED_NAME="$(basename "$FED_DIR")"
            if [ ! -x "$CC_SCRIPT" ]; then
                echo "[!!] Cost-cap sidecar: tools/cost-cap.sh not executable, skipping."
            else
                # Sidecar-start timestamp for the dashboard's startup grace
                # window (#274 logic shared with auto-promote).
                date +%s > "$CC_LOG_DIR/cost-cap.sidecar_started_at"
                (
                    # First action is a tick (not a sleep) so log activity
                    # appears immediately after spawn.
                    while :; do
                        if ! agentis daemon list --json 2>/dev/null | grep -Fq '"state":"running"'; then
                            printf '=== %s: no running daemons; sidecar exiting ===\n' \
                                "$(date -Iseconds)" >> "$CC_LOG"
                            exit 0
                        fi
                        {
                            printf '=== %s: cost-cap tick ===\n' "$(date -Iseconds)"
                            "$CC_SCRIPT" "$CC_FED_NAME" 2>&1 \
                                || printf '[sidecar] cost-cap.sh exited %s\n' "$?"
                        } >> "$CC_LOG"
                        sleep "$CC_INTERVAL"
                    done
                ) &
                COST_CAP_PID=$!
                # shellcheck disable=SC2064
                trap "[ -n \"\${AUTO_PROMOTE_PID:-}\" ] && kill \"\$AUTO_PROMOTE_PID\" 2>/dev/null; [ -n \"$COST_CAP_PID\" ] && kill \"$COST_CAP_PID\" 2>/dev/null; [ -n \"\${SNAPSHOT_REFRESH_PID:-}\" ] && kill \"\$SNAPSHOT_REFRESH_PID\" 2>/dev/null; [ -n \"\${COST_RATE_PID:-}\" ] && kill \"\$COST_RATE_PID\" 2>/dev/null; exit" EXIT TERM INT
                echo "Cost-cap sidecar: PID $COST_CAP_PID, every ${CC_INTERVAL}s (log: .agentis/logs/cost-cap.log)"
                echo ""
            fi
        fi
    fi
fi

# --- Shared-snapshot refresh sidecar (#1111) ---
#
# The Triage colony publishes ONE shared GitLab issues snapshot per colony
# per tick (#1111/#1112): triage/scripts/start-colony.sh writes the compact
# envelope to the `gitlab:snapshot:issues` memo plus an epoch freshness key
# at `gitlab:snapshot:issues:ts`. Every triage agent reads that memo instead
# of each curling /issues, collapsing the former 3-4x duplicate fetch per
# tick down to one. The snapshot is published on full-colony bootstrap, but
# the agents' snapshot_fresh() gate treats anything older than 600s as stale
# and degrades to a per-agent direct fetch — i.e. without periodic refresh
# the I/O win evaporates after the freshness window and every agent
# permanently falls back to the per-agent fetch #1111 set out to eliminate.
#
# This sidecar keeps the snapshot fresh by re-running the daemon-free
# `--snapshot-refresh` mode on an interval SHORTER than the 600s window
# (default 300s) so a fresh snapshot is always within reach. It mirrors the
# auto-promote / cost-cap sidecar shape: self-terminate when the federation
# has zero running daemons, EXIT/TERM/INT trap that kills it on shutdown.
#
# Backward-safe: a missing triage start-colony.sh, or a refresh failure, is
# logged and ignored — the snapshot step itself is total-on-failure (it
# leaves the prior snapshot in place on error), so a sidecar hiccup never
# breaks the federation; agents simply degrade to direct fetch until the
# next successful refresh.
SNAPSHOT_REFRESH_INTERVAL="${SNAPSHOT_REFRESH_INTERVAL_S:-300}"
case "$SNAPSHOT_REFRESH_INTERVAL" in
    ''|*[!0-9]*) SNAPSHOT_REFRESH_INTERVAL=300 ;;
    *) [ "$SNAPSHOT_REFRESH_INTERVAL" -gt 0 ] || SNAPSHOT_REFRESH_INTERVAL=300 ;;
esac
SNAPSHOT_REFRESH_PID=""
SNAP_START_COLONY="$FED_DIR/triage/scripts/start-colony.sh"
if [ ! -x "$SNAP_START_COLONY" ]; then
    echo "[!!] Snapshot-refresh sidecar: triage/scripts/start-colony.sh not executable, skipping."
else
    SNAP_LOG_DIR="$FED_DIR/.agentis/logs"
    SNAP_LOG="$SNAP_LOG_DIR/snapshot-refresh.log"
    mkdir -p "$SNAP_LOG_DIR"
    (
        # First action is a tick (not a sleep) so the snapshot is refreshed
        # immediately and the freshness clock restarts right after spawn.
        while :; do
            if ! agentis daemon list --json 2>/dev/null | grep -Fq '"state":"running"'; then
                printf '=== %s: no running daemons; sidecar exiting ===\n' \
                    "$(date -Iseconds)" >> "$SNAP_LOG"
                exit 0
            fi
            {
                printf '=== %s: snapshot-refresh tick ===\n' "$(date -Iseconds)"
                "$SNAP_START_COLONY" --snapshot-refresh 2>&1 \
                    || printf '[sidecar] start-colony.sh --snapshot-refresh exited %s\n' "$?"
            } >> "$SNAP_LOG"
            sleep "$SNAPSHOT_REFRESH_INTERVAL"
        done
    ) &
    SNAPSHOT_REFRESH_PID=$!
    # shellcheck disable=SC2064  # Expand PID at trap-install time, not at trigger time.
    trap "[ -n \"\${AUTO_PROMOTE_PID:-}\" ] && kill \"\$AUTO_PROMOTE_PID\" 2>/dev/null; [ -n \"\${COST_CAP_PID:-}\" ] && kill \"\$COST_CAP_PID\" 2>/dev/null; [ -n \"$SNAPSHOT_REFRESH_PID\" ] && kill \"$SNAPSHOT_REFRESH_PID\" 2>/dev/null; [ -n \"\${COST_RATE_PID:-}\" ] && kill \"\$COST_RATE_PID\" 2>/dev/null; exit" EXIT TERM INT
    echo "Snapshot-refresh sidecar: PID $SNAPSHOT_REFRESH_PID, every ${SNAPSHOT_REFRESH_INTERVAL}s (log: .agentis/logs/snapshot-refresh.log)"
    echo ""
fi

# --- Cost-rate instrumentation sidecar (#1114) ---
#
# Periodically runs tools/cost-rate-report.sh, which folds each colony's
# per-prompt spend rows (#311) plus `agentis stats --json --per-identity`
# into a machine-readable per-agent / per-role cost+rate report (prompts,
# prompts/hour, chars in/out proxies, cost_usd, the throttle-vs-task-error
# split, and retries). The log is the recorded artifact that proves the
# #1114 "a run produces a machine-readable log with all fields" DoD line on
# a live federation.
#
# Mirrors the snapshot-refresh / auto-promote / cost-cap sidecar shape: a
# tick-first background loop (emit immediately, not after a sleep), the same
# ''|*[!0-9]* / -gt 0 interval validation, self-terminate when the
# federation has zero running daemons, and an EXIT/TERM/INT trap that kills
# it on shutdown.
#
# Backward-safe: if tools/cost-rate-report.sh is not executable (broken
# checkout, chmod -x), the sidecar is skipped with a warning and the
# federation runs without it — the report is observational only and never
# gates the agents.
COST_RATE_INTERVAL="${COST_RATE_INTERVAL_S:-60}"
case "$COST_RATE_INTERVAL" in
    ''|*[!0-9]*) COST_RATE_INTERVAL=60 ;;
    *) [ "$COST_RATE_INTERVAL" -gt 0 ] || COST_RATE_INTERVAL=60 ;;
esac
COST_RATE_PID=""
COST_RATE_SCRIPT="$SCRIPT_DIR/../tools/cost-rate-report.sh"
COST_RATE_FED_NAME="$(basename "$FED_DIR")"
if [ ! -x "$COST_RATE_SCRIPT" ]; then
    echo "[!!] Cost-rate sidecar: tools/cost-rate-report.sh not executable, skipping."
else
    CR_LOG_DIR="$FED_DIR/.agentis/logs"
    CR_LOG="$CR_LOG_DIR/cost-rate.log"
    mkdir -p "$CR_LOG_DIR"
    (
        # First action is a tick (not a sleep) so a cost-rate report appears
        # immediately after spawn instead of after a full interval.
        while :; do
            if ! agentis daemon list --json 2>/dev/null | grep -Fq '"state":"running"'; then
                printf '=== %s: no running daemons; sidecar exiting ===\n' \
                    "$(date -Iseconds)" >> "$CR_LOG"
                exit 0
            fi
            {
                printf '=== %s: cost-rate tick ===\n' "$(date -Iseconds)"
                "$COST_RATE_SCRIPT" "$COST_RATE_FED_NAME" 2>&1 \
                    || printf '[sidecar] cost-rate-report.sh exited %s\n' "$?"
            } >> "$CR_LOG"
            sleep "$COST_RATE_INTERVAL"
        done
    ) &
    COST_RATE_PID=$!
    # shellcheck disable=SC2064  # Expand PID at trap-install time, not at trigger time.
    trap "[ -n \"\${AUTO_PROMOTE_PID:-}\" ] && kill \"\$AUTO_PROMOTE_PID\" 2>/dev/null; [ -n \"\${COST_CAP_PID:-}\" ] && kill \"\$COST_CAP_PID\" 2>/dev/null; [ -n \"\${SNAPSHOT_REFRESH_PID:-}\" ] && kill \"\$SNAPSHOT_REFRESH_PID\" 2>/dev/null; [ -n \"$COST_RATE_PID\" ] && kill \"$COST_RATE_PID\" 2>/dev/null; exit" EXIT TERM INT
    echo "Cost-rate sidecar: PID $COST_RATE_PID, every ${COST_RATE_INTERVAL}s (log: .agentis/logs/cost-rate.log)"
    echo ""
fi

# --- Self-observe sidecar (#1266 M3) ---
#
# Periodically runs tools/self-observe.sh so the federation proposes its OWN
# work — documentation drift, untracked TODOs, and recurring self-failures
# scanned from its own .agentis/logs — as small, deduplicated, rate-limited
# tracking issues. The robust shape of self-tuning: observation is a
# deterministic shell scan (no LLM, no over-exploration), and every finding
# becomes a SMALL issue the proven small-issue pipeline can fix.
#
# Opt-in: runs only when SELF_OBSERVE_SIDECAR=1 (default off — autonomous
# issue filing on a shared tracker is a deliberate choice). DRY-RUN by default
# (proposals go to the log only); set SELF_OBSERVE_FILE=1 to actually create
# issues — dedup + the SELF_OBSERVE_MAX_NEW rate-limit bound the volume.
# Mirrors the other sidecars: tick-first loop, self-terminate when the
# federation has zero running daemons, EXIT/TERM/INT trap.
SELF_OBSERVE_PID=""
if [ "${SELF_OBSERVE_SIDECAR:-0}" = "1" ]; then
    SO_INTERVAL="${SELF_OBSERVE_INTERVAL_S:-3600}"
    case "$SO_INTERVAL" in
        ''|*[!0-9]*) SO_INTERVAL=3600 ;;
        *) [ "$SO_INTERVAL" -gt 0 ] || SO_INTERVAL=3600 ;;
    esac
    SO_SCRIPT="$SCRIPT_DIR/../tools/self-observe.sh"
    if [ ! -x "$SO_SCRIPT" ]; then
        echo "[!!] Self-observe sidecar: tools/self-observe.sh not executable, skipping."
    else
        SO_LOG_DIR="$FED_DIR/.agentis/logs"
        SO_LOG="$SO_LOG_DIR/self-observe.log"
        mkdir -p "$SO_LOG_DIR"
        if [ "${SELF_OBSERVE_FILE:-0}" = "1" ]; then SO_MODE_LABEL="--file"; else SO_MODE_LABEL="dry-run"; fi
        date +%s > "$SO_LOG_DIR/self-observe.sidecar_started_at"
        (
            # First action is a tick (not a sleep) so a proposal pass appears
            # immediately after spawn. AGENT_LOG_DIR points the self-failure
            # detector at this federation's own daemon logs. GH auth rides the
            # forge token already in the environment.
            while :; do
                if ! agentis daemon list --json 2>/dev/null | grep -Fq '"state":"running"'; then
                    printf '=== %s: no running daemons; sidecar exiting ===\n' \
                        "$(date -Iseconds)" >> "$SO_LOG"
                    exit 0
                fi
                {
                    printf '=== %s: self-observe tick (%s) ===\n' "$(date -Iseconds)" "$SO_MODE_LABEL"
                    if [ "${SELF_OBSERVE_FILE:-0}" = "1" ]; then
                        AGENT_LOG_DIR="$SO_LOG_DIR" GH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}" \
                            "$SO_SCRIPT" --file 2>&1 \
                            || printf '[sidecar] self-observe.sh exited %s\n' "$?"
                    else
                        AGENT_LOG_DIR="$SO_LOG_DIR" GH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}" \
                            "$SO_SCRIPT" 2>&1 \
                            || printf '[sidecar] self-observe.sh exited %s\n' "$?"
                    fi
                } >> "$SO_LOG"
                sleep "$SO_INTERVAL"
            done
        ) &
        SELF_OBSERVE_PID=$!
        # shellcheck disable=SC2064  # Expand PID at trap-install time, not at trigger time.
        trap "[ -n \"\${AUTO_PROMOTE_PID:-}\" ] && kill \"\$AUTO_PROMOTE_PID\" 2>/dev/null; [ -n \"\${COST_CAP_PID:-}\" ] && kill \"\$COST_CAP_PID\" 2>/dev/null; [ -n \"\${SNAPSHOT_REFRESH_PID:-}\" ] && kill \"\$SNAPSHOT_REFRESH_PID\" 2>/dev/null; [ -n \"\${COST_RATE_PID:-}\" ] && kill \"\$COST_RATE_PID\" 2>/dev/null; [ -n \"$SELF_OBSERVE_PID\" ] && kill \"$SELF_OBSERVE_PID\" 2>/dev/null; exit" EXIT TERM INT
        echo "Self-observe sidecar: PID $SELF_OBSERVE_PID, every ${SO_INTERVAL}s ($SO_MODE_LABEL) (log: .agentis/logs/self-observe.log)"
        echo ""
    fi
fi

wait
