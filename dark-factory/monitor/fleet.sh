#!/bin/sh
# fleet.sh — multi-tenant / fleet launcher for the Monitor colony (Dark Factory, #1099).
#
# The monitor colony (scripts/start-colony.sh) watches ONE target via env vars.
# A managed service watching N protocols needs PER-TARGET isolation + fleet ops
# without hand-editing one global env. fleet.sh adds that as a NEW layer ON TOP
# of the existing start-colony.sh — it WRAPS that script, it does NOT modify it.
#
# Isolation model. Each target lives in its own base-dir slot:
#
#   ${MONITOR_FLEET_DIR:-$HOME/.agentis-monitor}/<slug>/
#     target.env       this target's config: address, chain, RPC set, webhook(s),
#                      watch-spec path, tiers (one `KEY=value` per line; sourced).
#     colony.toml      copied from config/colony.example.toml (schema parity).
#     .agentis/        this target's OWN agentis state — daemon registry, memo
#                      (baselines + per-agent tiers), logs. Created on first
#                      `start` by running start-colony.sh with cwd = this dir.
#
# Because `agentis` resolves its store from the cwd's `.agentis/`, invoking the
# UNMODIFIED start-colony.sh from inside a target's slot gives that target a
# private daemon registry, private memo blackboard (baselines never cross), and
# private logs. Targets cannot collide. `stop` scopes the shutdown to that
# target's registry via `kill-federation.sh --fed-dir <slot>`, so target A's
# daemons are never touched when target B is stopped, and an alert from target A
# (its own webhook, read from its own target.env) never routes to target B.
#
# NON-custodial / read-only: fleet.sh only orchestrates the read-only monitor
# colony — it holds no key, signs nothing, touches no funds. The per-target
# webhook URL is the only secret and it lives in the operator's target.env
# (chmod 600), never in the repo.
#
# Usage:
#   fleet.sh add <slug> <0xaddress> [--chain N] [--rpc URLS] [--webhook URL]
#                                   [--webhook-warn URL] [--webhook-high URL]
#                                   [--spec PATH] [--cast PATH] [--force]
#   fleet.sh start <slug> | --all
#   fleet.sh stop  <slug> | --all
#   fleet.sh list
#   fleet.sh status [<slug>]
#   fleet.sh path  <slug>
#
# Common flags (any subcommand):
#   --fleet-dir DIR   Override the base dir (default $MONITOR_FLEET_DIR or
#                     $HOME/.agentis-monitor). Also honoured via the env var.
#   --dry-run         Print what start/stop WOULD do without launching/killing
#                     daemons (used by the runtime-verify harness). `add`,
#                     `list`, `status`, `path` are already side-effect-light and
#                     ignore it for scaffolding but still print a [dry-run] note.
#   -h, --help        Show this header and exit 0.
#
# Env overrides (for tests / non-default layouts):
#   MONITOR_FLEET_DIR        base dir (see --fleet-dir).
#   MONITOR_START_COLONY     path to start-colony.sh (default: sibling
#                            scripts/start-colony.sh). The runtime-verify harness
#                            points this at a stub.
#   MONITOR_KILL_FEDERATION  path to kill-federation.sh (default: resolved from
#                            the federation's tools/ dir). The harness stubs it.
#   AGENTIS_BIN              the agentis binary (default: `agentis` on PATH).
#
# POSIX sh / dash-safe: no bashisms, no arrays, no `\xHH` printf escapes. CI runs
# this under `sh` = dash.
#
# Exit codes: 0 ok, 2 usage error, 3 unknown / missing target, 4 launch/stop
#   failure, 5 missing dependency (agentis / start-colony.sh).

set -eu

# --- self-resolution (symlink-safe, matches the sibling scripts) ---------------
SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"        # .../monitor
FED_DIR="$(dirname "$SCRIPT_DIR")"            # .../dark-factory

START_COLONY="${MONITOR_START_COLONY:-$SCRIPT_DIR/scripts/start-colony.sh}"
COLONY_TEMPLATE="$SCRIPT_DIR/config/colony.example.toml"
AGENTIS_BIN="${AGENTIS_BIN:-agentis}"
# config/target.example.toml is the human-facing per-target config-unit template
# (one client = one of these); `add` materialises the machine contract below as
# target.env, keyed off the same MONITOR_* names that template documents.

# kill-federation.sh: try the in-repo tools/ first, then a tarball-local tools/.
KILL_FED="${MONITOR_KILL_FEDERATION:-}"
if [ -z "$KILL_FED" ]; then
    for cand in "$FED_DIR/../tools/kill-federation.sh" "$FED_DIR/tools/kill-federation.sh"; do
        if [ -f "$cand" ]; then
            KILL_FED="$cand"
            break
        fi
    done
fi

err()  { echo "fleet.sh: $1" >&2; }
need() { [ "$1" -ge 2 ] || { err "missing value for the preceding flag"; exit 2; }; }
show_help() { awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$SCRIPT_PATH"; }

# --- global flag pre-parse (--fleet-dir / --dry-run / --help may appear anywhere)
FLEET_DIR="${MONITOR_FLEET_DIR:-$HOME/.agentis-monitor}"
DRY_RUN=0
# Walk argv, peeling the global flags, leaving subcommand + its args in ARGV_REST.
ARGV_REST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --fleet-dir) need "$#"; FLEET_DIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) show_help; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do ARGV_REST="$ARGV_REST $1"; shift; done; break ;;
        *) ARGV_REST="$ARGV_REST $1"; shift ;;
    esac
done
# Restore the surviving (subcommand + args) into the positional params. The
# values here are slugs / addresses / our own flag tokens — no whitespace.
# shellcheck disable=SC2086
set -- $ARGV_REST

if [ $# -eq 0 ]; then
    err "no subcommand (try: add | start | stop | list | status | path | --help)"
    exit 2
fi
SUBCMD="$1"
shift

# --- helpers -------------------------------------------------------------------

# A slug is a target's stable directory key: lowercase letters, digits, dash,
# underscore. Keeps the base dir flat + predictable and free of path tricks.
valid_slug() {
    case "$1" in
        ''|*[!a-z0-9_-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# A target address is 0x + 40 hex (the backtest.sh idiom).
valid_addr() {
    case "$1" in
        0x*) _hex="${1#0x}" ;;
        *) return 1 ;;
    esac
    case "$_hex" in
        *[!0-9a-fA-F]*) return 1 ;;
    esac
    [ "${#_hex}" -eq 40 ]
}

slot_dir()  { printf '%s/%s' "$FLEET_DIR" "$1"; }
env_file()  { printf '%s/%s/target.env' "$FLEET_DIR" "$1"; }

# Enumerate the slugs that have a target.env, newline-separated (none => empty).
list_slugs() {
    [ -d "$FLEET_DIR" ] || return 0
    for d in "$FLEET_DIR"/*/; do
        [ -d "$d" ] || continue
        [ -f "${d}target.env" ] || continue
        b="$(basename "$d")"
        printf '%s\n' "$b"
    done
}

# Count the LIVE daemons in a slot's registry: each *.pid file's first line is a
# PID; a daemon is live iff `kill -0` succeeds. `agentis daemon list` is
# unreliable across sleep/restart, so we cross-check /proc directly.
live_daemons() {
    _slot="$1"
    _reg="$_slot/.agentis/daemon"
    _n=0
    [ -d "$_reg" ] || { echo 0; return 0; }
    for f in "$_reg"/*.pid; do
        [ -f "$f" ] || continue
        case "$f" in *.watchdog.pid) continue ;; esac
        _pid="$(head -n 1 "$f" 2>/dev/null | tr -d ' \t\r\n' || true)"
        case "$_pid" in ''|*[!0-9]*) continue ;; esac
        if kill -0 "$_pid" 2>/dev/null; then
            _n=$((_n + 1))
        fi
    done
    echo "$_n"
}

require_target() {
    if ! valid_slug "$1"; then
        err "invalid slug '$1' (use lowercase letters, digits, dash, underscore)"
        exit 2
    fi
    if [ ! -f "$(env_file "$1")" ]; then
        err "no target '$1' (run: fleet.sh add $1 <0xaddress>)"
        exit 3
    fi
}

# --- add -----------------------------------------------------------------------
cmd_add() {
    FORCE=0
    SLUG=""; ADDRESS=""
    CHAIN=""; RPC=""; WEBHOOK=""; WEBHOOK_WARN=""; WEBHOOK_HIGH=""; SPEC=""; CAST=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --chain) need "$#"; CHAIN="$2"; shift 2 ;;
            --rpc) need "$#"; RPC="$2"; shift 2 ;;
            --webhook) need "$#"; WEBHOOK="$2"; shift 2 ;;
            --webhook-warn) need "$#"; WEBHOOK_WARN="$2"; shift 2 ;;
            --webhook-high) need "$#"; WEBHOOK_HIGH="$2"; shift 2 ;;
            --spec) need "$#"; SPEC="$2"; shift 2 ;;
            --cast) need "$#"; CAST="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            -*) err "add: unknown flag $1"; exit 2 ;;
            *)
                if [ -z "$SLUG" ]; then SLUG="$1"
                elif [ -z "$ADDRESS" ]; then ADDRESS="$1"
                else err "add: unexpected argument $1"; exit 2
                fi
                shift
                ;;
        esac
    done

    [ -n "$SLUG" ] || { err "add: <slug> required"; exit 2; }
    valid_slug "$SLUG" || { err "add: invalid slug '$SLUG' (lowercase letters, digits, dash, underscore)"; exit 2; }
    [ -n "$ADDRESS" ] || { err "add: <0xaddress> required"; exit 2; }
    valid_addr "$ADDRESS" || { err "add: address must be 0x + 40 hex (got: $ADDRESS)"; exit 2; }
    if [ -n "$CHAIN" ]; then
        case "$CHAIN" in ''|*[!0-9]*) err "add: --chain must be a whole number"; exit 2 ;; esac
    fi

    SLOT="$(slot_dir "$SLUG")"
    ENVF="$(env_file "$SLUG")"
    if [ -f "$ENVF" ] && [ "$FORCE" -eq 0 ]; then
        err "add: target '$SLUG' already exists ($ENVF) — pass --force to overwrite its config"
        exit 2
    fi

    mkdir -p "$SLOT"

    # Per-target colony.toml: a verbatim copy of the colony template so each slot
    # is schema-complete and self-describing. The per-target overrides live in
    # target.env (sourced by `start`), not in this file — the colony template is
    # the agent roster + budgets, shared by every target.
    if [ -f "$COLONY_TEMPLATE" ]; then
        cp "$COLONY_TEMPLATE" "$SLOT/colony.toml"
    fi

    # Per-target env contract. Seeded from the template's keys, then filled with
    # this target's address + the flags. One KEY=value per line; sourced by
    # `start`, which exports each MONITOR_* before invoking start-colony.sh.
    umask 077
    {
        echo "# Monitor fleet target — $SLUG ($ADDRESS)"
        echo "# Generated by fleet.sh add. Edit to tune RPC / webhooks / tiers /"
        echo "# the watch-spec. One KEY=value per line (sourced as POSIX sh)."
        echo "# NEVER commit a real webhook URL — this file is chmod 600 by design."
        echo
        echo "MONITOR_TARGET=$ADDRESS"
        echo "MONITOR_CHAIN_ID=${CHAIN}"
        echo "MONITOR_RPC_URL=${RPC}"
        echo "MONITOR_INV_SPEC=${SPEC}"
        echo "MONITOR_CAST=${CAST}"
        echo "MONITOR_WEBHOOK_URL=${WEBHOOK}"
        echo "MONITOR_WEBHOOK_URL_WARN=${WEBHOOK_WARN}"
        echo "MONITOR_WEBHOOK_URL_HIGH=${WEBHOOK_HIGH}"
        echo
        echo "# Per-target watcher reuse of MONITOR_TARGET (override only if a"
        echo "# watcher reads a DIFFERENT contract than the main target):"
        echo "# MONITOR_GOV_TARGET="
        echo "# MONITOR_LIQ_TARGET="
        echo "# MONITOR_FLOW_TARGET="
        echo "# MONITOR_PAUSE_TARGET="
        echo
        echo "# Per-target alert hardening (see config/colony.example.toml):"
        echo "# MONITOR_HEARTBEAT_INTERVAL_S="
        echo "# MONITOR_DEADMAN_WINDOW_S="
        echo "# MONITOR_NOTIFY_DEDUP_COOLDOWN_S="
        echo
        echo "# Per-target starting confidence (tiers). Seeded per agent by"
        echo "# start-colony.sh; lower a watcher here to observe baselines first."
        echo "# MONITOR_TICK_MS="
    } > "$ENVF"

    echo "added target '$SLUG' -> $SLOT"
    echo "  address : $ADDRESS"
    echo "  config  : $ENVF (chmod 600)"
    echo "  next    : fleet.sh start $SLUG"
}

# --- start ---------------------------------------------------------------------
start_one() {
    SLUG="$1"
    require_target "$SLUG"
    SLOT="$(slot_dir "$SLUG")"
    ENVF="$(env_file "$SLUG")"

    if [ ! -f "$START_COLONY" ]; then
        err "start: start-colony.sh not found at $START_COLONY"
        exit 5
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] would start target '$SLUG':"
        echo "  cwd        : $SLOT"
        echo "  env        : $ENVF"
        echo "  start      : $START_COLONY"
        # Surface the resolved target address so the harness can assert isolation.
        # shellcheck disable=SC1090
        ( set -a; . "$ENVF"; set +a; echo "  target     : ${MONITOR_TARGET:-(unset)}" )
        return 0
    fi

    if ! command -v "$AGENTIS_BIN" >/dev/null 2>&1; then
        err "start: agentis not found on PATH (set AGENTIS_BIN) — install it first"
        exit 5
    fi

    # Initialise this target's OWN agentis store the first time. `agentis init`
    # is run with cwd = the slot, so the store lands in $SLOT/.agentis.
    if [ ! -d "$SLOT/.agentis" ]; then
        ( cd "$SLOT" && "$AGENTIS_BIN" init >/dev/null 2>&1 ) || true
    fi

    # Source this target's env contract and export every MONITOR_* it sets so the
    # UNMODIFIED start-colony.sh (which reads them from the environment) sees this
    # target's address / RPC / webhook(s) / spec — and only this target's.
    # shellcheck disable=SC1090
    ( cd "$SLOT" \
        && set -a \
        && . "$ENVF" \
        && set +a \
        && "$START_COLONY" "$SLOT/colony.toml" ) &
    fleet_pid=$!
    sleep 2
    if ! kill -0 "$fleet_pid" 2>/dev/null; then
        # start-colony.sh runs `wait`, so a live $fleet_pid means it launched.
        # A dead one this early means a launch failure (e.g. agentis missing).
        live="$(live_daemons "$SLOT")"
        if [ "$live" -eq 0 ]; then
            err "start: target '$SLUG' launched no live daemons (see start-colony output)"
            exit 4
        fi
    fi
    echo "started target '$SLUG' (cwd=$SLOT, $(live_daemons "$SLOT") live daemons)"
}

cmd_start() {
    if [ "${1:-}" = "--all" ]; then
        any=0
        for s in $(list_slugs); do
            any=1
            start_one "$s"
        done
        [ "$any" -eq 1 ] || echo "no targets to start (add one: fleet.sh add <slug> <0xaddress>)"
        return 0
    fi
    [ -n "${1:-}" ] || { err "start: <slug> or --all required"; exit 2; }
    start_one "$1"
}

# --- stop ----------------------------------------------------------------------
stop_one() {
    SLUG="$1"
    require_target "$SLUG"
    SLOT="$(slot_dir "$SLUG")"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] would stop target '$SLUG':"
        echo "  fed-dir    : $SLOT"
        echo "  kill       : ${KILL_FED:-(kill-federation.sh not resolved)}"
        echo "  live now   : $(live_daemons "$SLOT") daemon(s)"
        return 0
    fi

    if [ -z "$KILL_FED" ] || [ ! -f "$KILL_FED" ]; then
        err "stop: kill-federation.sh not found (set MONITOR_KILL_FEDERATION)"
        exit 5
    fi

    # --fed-dir scopes the shutdown to THIS target's registry (#440), so other
    # targets' daemons survive. --no-backup: the slot's registry is operational
    # state, not fixture data we need a tarball of on every stop.
    if "$KILL_FED" --fed-dir "$SLOT" --no-backup; then
        echo "stopped target '$SLUG'"
    else
        err "stop: kill-federation.sh reported target '$SLUG' not fully clean"
        exit 4
    fi
}

cmd_stop() {
    if [ "${1:-}" = "--all" ]; then
        any=0
        for s in $(list_slugs); do
            any=1
            stop_one "$s"
        done
        [ "$any" -eq 1 ] || echo "no targets to stop"
        return 0
    fi
    [ -n "${1:-}" ] || { err "stop: <slug> or --all required"; exit 2; }
    stop_one "$1"
}

# --- list ----------------------------------------------------------------------
cmd_list() {
    slugs="$(list_slugs)"
    if [ -z "$slugs" ]; then
        echo "no targets under $FLEET_DIR"
        echo "  add one: fleet.sh add <slug> <0xaddress>"
        return 0
    fi
    echo "targets under $FLEET_DIR:"
    for s in $slugs; do
        ENVF="$(env_file "$s")"
        addr="$(grep '^MONITOR_TARGET=' "$ENVF" 2>/dev/null | head -n 1 | cut -d= -f2- || true)"
        live="$(live_daemons "$(slot_dir "$s")")"
        if [ "$live" -gt 0 ]; then state="running ($live)"; else state="stopped"; fi
        printf '  %-20s %-44s %s\n' "$s" "${addr:-(no address)}" "$state"
    done
}

# --- status --------------------------------------------------------------------
status_one() {
    s="$1"
    ENVF="$(env_file "$s")"
    SLOT="$(slot_dir "$s")"
    addr="$(grep '^MONITOR_TARGET=' "$ENVF" 2>/dev/null | head -n 1 | cut -d= -f2- || true)"
    rpc="$(grep '^MONITOR_RPC_URL=' "$ENVF" 2>/dev/null | head -n 1 | cut -d= -f2- || true)"
    live="$(live_daemons "$SLOT")"
    echo "target: $s"
    echo "  slot       : $SLOT"
    echo "  address    : ${addr:-(unset)}"
    echo "  rpc        : ${rpc:-(unset)}"
    echo "  registry   : $SLOT/.agentis/daemon"
    echo "  live daemons: $live"
}

cmd_status() {
    if [ -n "${1:-}" ]; then
        require_target "$1"
        status_one "$1"
        return 0
    fi
    slugs="$(list_slugs)"
    if [ -z "$slugs" ]; then
        echo "no targets under $FLEET_DIR"
        return 0
    fi
    first=1
    for s in $slugs; do
        [ "$first" -eq 1 ] || echo
        first=0
        status_one "$s"
    done
}

# --- path ----------------------------------------------------------------------
cmd_path() {
    [ -n "${1:-}" ] || { err "path: <slug> required"; exit 2; }
    require_target "$1"
    slot_dir "$1"
}

# --- dispatch ------------------------------------------------------------------
case "$SUBCMD" in
    add)    cmd_add "$@" ;;
    start)  cmd_start "$@" ;;
    stop)   cmd_stop "$@" ;;
    list)   cmd_list "$@" ;;
    status) cmd_status "$@" ;;
    path)   cmd_path "$@" ;;
    help)   show_help ;;
    *) err "unknown subcommand '$SUBCMD' (try: add | start | stop | list | status | path | --help)"; exit 2 ;;
esac
