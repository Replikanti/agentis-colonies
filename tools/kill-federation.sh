#!/usr/bin/env bash
# kill-federation.sh — reliable full shutdown of an agentis federation.
#
# Works around upstream bugs where `agentis daemon stop --all` and per-agent
# `agentis daemon stop <id>` can report failure while daemons actually die,
# or report success while they linger. This script uses OS-level signals
# (TERM then KILL with timeout), verifies every PID is actually gone, and
# cleans the stale registry sidecar files afterwards.
#
# Safe to run:
#   - when the federation is fully running
#   - when it's partially running (some daemons dead, some alive)
#   - when it's already stopped (no-op, registry cleanup only)
#   - when the dashboard is running (stops it too)
#
# Exit codes:
#   0  all agentis processes dead, registry clean, dashboard stopped
#   1  at least one process survived SIGKILL / federation not fully clean
#   2  invalid invocation / missing federation dir / bad flag
#
# Why `set -u` only (no `-e`/`-o pipefail`):
#   This script is defence-in-depth. Each step (signal, sweep, cleanup,
#   verify) must be allowed to soft-fail without aborting the next step,
#   so that a partial failure still results in maximum cleanup. The final
#   verification block returns the authoritative exit code. Do NOT add
#   `set -e` here — future reviewers, please leave this as-is.
set -u

# --- Self-resolution (matches install.sh / start-federation.sh idiom) ---
SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOL_DIR="$(dirname "$SCRIPT_PATH")"
: "$TOOL_DIR"  # silence "unused" — kept for parity with sibling tools

# --- Defaults (overridable via flags) ---
FED_DIR=""
DRY_RUN=0
JSON_MODE=0
NO_BACKUP=0
# When set, revert the ancestor-chain walk to unconditional exclusion —
# every ancestor is kept alive regardless of whether it matches a kill
# pattern. Used by the dashboard /kill endpoint so the HTTP server that
# invoked us survives long enough to flush its response. CLI callers
# get the default (conditional exclusion) behaviour, which is what
# colonies #188 actually requires — a stale dashboard higher up the
# ancestor chain will be killed, freeing port 8420.
PRESERVE_ANCESTORS=0
# Default daemon match pattern. Narrowed from the original draft's bare
# 'agentis' to 'agentis daemon' to avoid self-killing the running script,
# sibling clones of agentis-colonies, the operator's editor titles, and
# `tail -f .agentis/logs/...` sessions. Residual risk: a custom wrapper
# that launches daemons with a different argv0 will be missed — the
# `--match-pattern` test hook below exists to validate that path.
DAEMON_MATCH='agentis daemon'
# Dashboard pattern: standalone federation-dashboard entry script (#252;
# previously tools/federation-dashboard.sh) + any dashboard.sh shell
# wrapper processes. Separate from DAEMON_MATCH so the test harness can
# point it at a fixture tag without touching real dashboards.
DASHBOARD_MATCH='federation-dashboard|dashboard\.sh'
# Dashboard Python server pattern: the `python3 -m http.server` child of
# the dashboard wrapper. Overridable for the same reason as above.
DASH_PY_MATCH='Python.*dashboard|Python.*\.dashboard'

usage() {
    cat <<'EOF'
Usage: kill-federation.sh [OPTIONS] [FEDERATION-DIR]

Reliably stop an agentis federation: agents, dashboard, registry sidecar
files, and a backup tarball before cleanup. Bypasses the agentis CLI and
uses OS signals so it works even when `agentis daemon stop --all` lies.

Positional:
  FEDERATION-DIR     Directory containing .agentis/ state (default: $(pwd)).
                     Overridden by --fed-dir if both are given.

Options:
  -h, --help         Show this help and exit (0).
  --dry-run          List target PIDs and registry files but do not signal
                     or delete. Always exits 0 unless invocation is bad.
  --json             Emit a single trailing JSON line on stdout for machine
                     consumers (e.g. dashboard kill button). Human-readable
                     coloured prose still goes to stderr.
  --no-backup        Skip the tar.gz backup of .agentis/daemon/. Used by
                     CI / tests where the registry is fixture data.
  --preserve-ancestors
                     Exclude every process in this script's ancestor chain
                     from the kill set, even if its argv matches a kill
                     pattern or it holds the dashboard port. Used by the
                     dashboard /kill endpoint so the HTTP server that
                     invoked us survives long enough to flush the JSON
                     response. CLI callers should normally NOT set this —
                     stale dashboards in the ancestor chain will be
                     missed (colonies #188).
  --fed-dir DIR      Federation dir (overrides positional argument). Used
                     by the dev-apprenticeship/kill-federation.sh wrapper.

Exit codes:
  0   federation fully stopped (or dry-run completed)
  1   at least one process survived SIGKILL / not fully clean
  2   invalid flag, missing federation dir, or other bad invocation

Notes:
  Port 8420 is verified with `lsof` if available, falling back to `ss`
  (iproute2). On minimal images without either, the port check is
  skipped and reported as "unknown" (treated as clean).
EOF
}

# --- Argument parsing ---
# Hidden flag --match-pattern PATTERN: substitutes the daemon match string
# so the test harness (tools/test-kill-federation.sh) can exercise the
# kill machinery against fixture processes without touching real agentis
# daemons. Kept undocumented in --help by design; do NOT remove during
# future cleanups — see the note in tools/test-kill-federation.sh.
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --json)
            JSON_MODE=1
            shift
            ;;
        --no-backup)
            NO_BACKUP=1
            shift
            ;;
        --preserve-ancestors)
            PRESERVE_ANCESTORS=1
            shift
            ;;
        --fed-dir)
            if [ $# -lt 2 ]; then
                echo "kill-federation.sh: --fed-dir requires an argument" >&2
                exit 2
            fi
            FED_DIR="$2"
            shift 2
            ;;
        --match-pattern)
            if [ $# -lt 2 ]; then
                echo "kill-federation.sh: --match-pattern requires an argument" >&2
                exit 2
            fi
            DAEMON_MATCH="$2"
            shift 2
            ;;
        --dashboard-pattern)
            # Hidden test hook: substitutes the dashboard match pattern
            # so tests don't accidentally signal a real dashboard.sh
            # running on the operator's machine. See
            # tools/test-kill-federation.sh.
            if [ $# -lt 2 ]; then
                echo "kill-federation.sh: --dashboard-pattern requires an argument" >&2
                exit 2
            fi
            DASHBOARD_MATCH="$2"
            shift 2
            ;;
        --dashboard-py-pattern)
            # Hidden test hook: substitutes the dashboard-python server
            # match pattern. Same rationale as --dashboard-pattern.
            if [ $# -lt 2 ]; then
                echo "kill-federation.sh: --dashboard-py-pattern requires an argument" >&2
                exit 2
            fi
            DASH_PY_MATCH="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "kill-federation.sh: unknown flag: $1" >&2
            echo "Try --help for usage." >&2
            exit 2
            ;;
        *)
            if [ -z "$FED_DIR" ]; then
                FED_DIR="$1"
            else
                echo "kill-federation.sh: unexpected argument: $1" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

if [ -z "$FED_DIR" ]; then
    FED_DIR="$(pwd)"
fi

# --- Output helpers ---
# Human-readable prose goes to stderr so --json can keep stdout clean
# for the single trailing JSON line.
step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*" >&2; }
ok()   { printf '  \033[1;32mok\033[0m %s\n' "$*" >&2; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*" >&2; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*" >&2; }

# --- Resolve federation ---
step "Resolving federation"

if [ ! -d "$FED_DIR" ]; then
    fail "Federation dir missing: $FED_DIR"
    exit 2
fi
AGENTIS_DIR="$FED_DIR/.agentis"
if [ ! -d "$AGENTIS_DIR" ]; then
    # Fallback: maybe FED_DIR is a colony inside a federation; walk up one.
    if [ -d "$FED_DIR/../.agentis" ]; then
        AGENTIS_DIR="$FED_DIR/../.agentis"
    else
        warn "No .agentis dir under $FED_DIR; assuming standalone mode"
        AGENTIS_DIR=""
    fi
fi
ok "federation dir = $FED_DIR"
[ -n "$AGENTIS_DIR" ] && ok "agentis state  = $AGENTIS_DIR"
[ "$DRY_RUN" -eq 1 ] && warn "DRY-RUN: no signals will be sent, no files deleted"

# --- Collect PIDs (once, up front, with precise patterns) ---
step "Collecting target PIDs"

# Use newline separation internally so we can count without word-splitting
# surprises. Convert to space-separated lists for the signal loops.
AGENTIS_PIDS_NL="$(pgrep -f "$DAEMON_MATCH" 2>/dev/null | sort -u || true)"
DASHBOARD_PIDS_NL="$(pgrep -f "$DASHBOARD_MATCH" 2>/dev/null | sort -u || true)"
DASH_PY_PIDS_NL="$(pgrep -f "$DASH_PY_MATCH" 2>/dev/null | sort -u || true)"

# Port-based fallback discovery (colonies #188): anything listening on the
# dashboard's bound port is a dashboard by definition, even if its argv
# drifted away from DASHBOARD_MATCH / DASH_PY_MATCH across commits (this
# is what the #188 reporter observed — old leftover servers with argvs
# that no longer matched the default regex survived a "kill federation").
# Union the port-listener set into DASH_PY_PIDS_NL so the same filter_self
# pass below applies uniformly.
#
# Uses lsof when present (universal on macOS + most Linux), falls back to
# `ss` (iproute2, always present on modern Linux incl. Alpine). Non-root
# may get empty pid= on some `ss` variants; that's fine — the pgrep pass
# above is the primary mechanism.
DASHBOARD_PORT=8420
if command -v lsof >/dev/null 2>&1; then
    PORT_PIDS_NL="$(lsof -iTCP:"$DASHBOARD_PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u || true)"
elif command -v ss >/dev/null 2>&1; then
    # ss output line: LISTEN 0 128 ... users:(("python3",pid=1234,fd=5))
    PORT_PIDS_NL="$(ss -ltnp "sport = :$DASHBOARD_PORT" 2>/dev/null \
        | grep -oE 'pid=[0-9]+' \
        | cut -d= -f2 \
        | sort -u \
        || true)"
else
    PORT_PIDS_NL=""
fi
if [ -n "$PORT_PIDS_NL" ]; then
    DASH_PY_PIDS_NL="$(printf '%s\n%s\n' "$DASH_PY_PIDS_NL" "$PORT_PIDS_NL" \
        | grep -v '^$' | sort -u || true)"
fi

# Don't ever signal ourselves — exclude this script's PID from every PID
# list and every pkill sweep. We also walk our ancestor chain and exclude
# any ancestor that is NOT itself a kill target (see _is_kill_target
# below). Why: pgrep -f matches against the FULL command line, so any
# test harness or wrapper that invokes us with a flag value like
# `--match-pattern foo` will appear in pgrep results because `foo` is
# a substring of *its own* argv. Blindly excluding the entire ancestor
# chain prevents this from killing the caller — but it also drops
# legitimate targets (colonies #188: the dashboard Python server
# invoking us via /kill became our ancestor and got excluded from the
# kill set, leaving the dashboard alive after a "kill federation"
# request). Conditional exclusion keeps harmless ancestors (test
# runners, CI shells) out while still killing federation ancestors.
SELF_PID=$$
# Helper: decide whether a given PID is a legitimate kill target. Called
# from the ancestor walk below to skip-exclude matching ancestors. A PID
# is a kill target when its argv matches any of the three kill patterns,
# OR when it holds the dashboard port (PORT_PIDS_NL).
_is_kill_target() {
    local pid="$1"
    local cmd
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || echo '')"
    if [ -n "$cmd" ]; then
        if printf '%s\n' "$cmd" | grep -Eq -- "$DAEMON_MATCH" \
        || printf '%s\n' "$cmd" | grep -Eq -- "$DASHBOARD_MATCH" \
        || printf '%s\n' "$cmd" | grep -Eq -- "$DASH_PY_MATCH"; then
            return 0
        fi
    fi
    if [ -n "$PORT_PIDS_NL" ]; then
        while IFS= read -r _pp; do
            [ "$_pp" = "$pid" ] && return 0
        done <<< "$PORT_PIDS_NL"
    fi
    return 1
}
# Walk the full parent chain back to PID 1. Exclude ancestors ONLY when
# they are not themselves kill targets. Stop at PID 1 (init) — it's never
# a kill target.
EXCLUDE_PIDS="$SELF_PID"
_walk_pid="$PPID"
_walk_safety=0
while [ -n "$_walk_pid" ] && [ "$_walk_pid" != "0" ] && [ "$_walk_pid" != "1" ] && [ "$_walk_safety" -lt 32 ]; do
    if [ "$PRESERVE_ANCESTORS" -eq 1 ]; then
        # Backwards-compat mode for the dashboard /kill endpoint: the
        # HTTP server must outlive subprocess.run so it can flush the
        # JSON response. Exclude every ancestor unconditionally.
        EXCLUDE_PIDS="$EXCLUDE_PIDS $_walk_pid"
    elif _is_kill_target "$_walk_pid"; then
        # Matching ancestor — leave it in the kill set (e.g. a stale
        # dashboard Python server higher up the chain, colonies #188).
        :
    else
        EXCLUDE_PIDS="$EXCLUDE_PIDS $_walk_pid"
    fi
    # `ps -o ppid=` works on every POSIX ps; trim handles macOS leading spaces.
    _next_pid="$(ps -o ppid= -p "$_walk_pid" 2>/dev/null | tr -d ' ' || echo '')"
    if [ -z "$_next_pid" ] && [ "$_walk_pid" != "1" ]; then
        # Rare race: an ancestor exited mid-walk so `ps` returned nothing
        # before we reached PID 1. Higher ancestors are now un-excludable;
        # log a hint so operators can correlate if the script ever flags
        # one of them as a kill target.
        warn "ancestor walk: ps returned empty ppid for PID $_walk_pid before reaching 1; higher ancestors not excluded"
    fi
    _walk_pid="$_next_pid"
    _walk_safety=$((_walk_safety + 1))
done
unset _walk_pid _walk_safety _next_pid
SCRIPT_BASENAME="$(basename "$SCRIPT_PATH")"
filter_self() {
    local input="$1"
    [ -z "$input" ] && return 0
    printf '%s\n' "$input" | while IFS= read -r p; do
        [ -z "$p" ] && continue
        local skip=0
        for ex in $EXCLUDE_PIDS; do
            [ "$p" = "$ex" ] && skip=1 && break
        done
        [ "$skip" -eq 1 ] && continue
        # If the process is already gone (e.g. a transient `$()` subshell
        # that was captured by pgrep and died before we could re-check),
        # drop it — it's not a kill target.
        if ! kill -0 "$p" 2>/dev/null; then
            continue
        fi
        # Also skip any process whose own argv mentions this script's
        # basename — covers the transient `$()` bash subshells spawned by
        # this very script (whose argv is the parent script's argv, and
        # therefore contains the user-supplied PATTERN as a flag value).
        # Without this, pgrep -f PATTERN matches our own subshells and
        # the verification step reports phantom "live processes".
        local cmd
        cmd="$(ps -o command= -p "$p" 2>/dev/null || echo '')"
        case "$cmd" in
            # Exclude pgrep itself: on slow runners or under strace, the
            # verifying `pgrep -f PATTERN` process can outlive its own
            # exec window long enough to appear in its own results
            # (its argv contains PATTERN as a literal substring).
            pgrep*) skip=1 ;;
            *"$SCRIPT_BASENAME"*) skip=1 ;;
        esac
        [ "$skip" -eq 1 ] && continue
        printf '%s\n' "$p"
    done
}
AGENTIS_PIDS_NL="$(filter_self "$AGENTIS_PIDS_NL")"
DASHBOARD_PIDS_NL="$(filter_self "$DASHBOARD_PIDS_NL")"
DASH_PY_PIDS_NL="$(filter_self "$DASH_PY_PIDS_NL")"

# Safe alternative to `pkill -SIG -f PATTERN`: pgrep matches, filter
# self/ancestors, then send the signal manually. Used by the sweep step
# below — pkill itself has no exclusion mechanism.
safe_killall() {
    local sig="$1" pattern="$2"
    local pids
    pids="$(pgrep -f "$pattern" 2>/dev/null | sort -u || true)"
    pids="$(filter_self "$pids")"
    [ -z "$pids" ] && return 0
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        kill "-$sig" "$p" 2>/dev/null || true
    done <<< "$pids"
}

AGENTIS_PIDS="$(printf '%s' "$AGENTIS_PIDS_NL" | tr '\n' ' ')"
DASHBOARD_PIDS="$(printf '%s' "$DASHBOARD_PIDS_NL" | tr '\n' ' ')"
DASH_PY_PIDS="$(printf '%s' "$DASH_PY_PIDS_NL" | tr '\n' ' ')"

count_pids() {
    [ -z "$1" ] && { echo 0; return; }
    printf '%s\n' "$1" | grep -c .
}
AGENTIS_COUNT=$(count_pids "$AGENTIS_PIDS_NL")
DASHBOARD_COUNT=$(count_pids "$DASHBOARD_PIDS_NL")
DASH_PY_COUNT=$(count_pids "$DASH_PY_PIDS_NL")

echo "  agentis daemon PIDs ($AGENTIS_COUNT): ${AGENTIS_PIDS:-(none)}" >&2
echo "  dashboard PIDs      ($DASHBOARD_COUNT): ${DASHBOARD_PIDS:-(none)}" >&2
echo "  dashboard python    ($DASH_PY_COUNT): ${DASH_PY_PIDS:-(none)}" >&2

ALL_PIDS_NL="$(printf '%s\n%s\n%s\n' "$AGENTIS_PIDS_NL" "$DASHBOARD_PIDS_NL" "$DASH_PY_PIDS_NL" | grep -v '^$' | sort -u || true)"
ALL_PIDS="$(printf '%s' "$ALL_PIDS_NL" | tr '\n' ' ')"
ALL_COUNT=$(count_pids "$ALL_PIDS_NL")

# --- Dry-run shortcut ---
if [ "$DRY_RUN" -eq 1 ]; then
    step "Dry-run: registry files that would be removed"
    REG_FILES_LIST=""
    if [ -n "$AGENTIS_DIR" ] && [ -d "$AGENTIS_DIR/daemon" ]; then
        for ext in pid watchdog.pid colony heartbeat status stop; do
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                echo "  would remove: $f" >&2
                REG_FILES_LIST="$REG_FILES_LIST$f"$'\n'
            done < <(find "$AGENTIS_DIR/daemon" -maxdepth 1 -name "*.$ext" -type f 2>/dev/null)
        done
    fi
    REG_COUNT=$(printf '%s' "$REG_FILES_LIST" | grep -c . || true)
    ok "dry-run complete: $ALL_COUNT process(es), $REG_COUNT registry file(s) would be touched"
    if [ "$JSON_MODE" -eq 1 ]; then
        printf '{"dry_run":true,"agentis":%d,"dashboard":%d,"dashboard_python":%d,"total_processes":%d,"registry_files":%d,"backup":null,"exit":0}\n' \
            "$AGENTIS_COUNT" "$DASHBOARD_COUNT" "$DASH_PY_COUNT" "$ALL_COUNT" "$REG_COUNT"
    fi
    exit 0
fi

# --- SIGTERM (graceful) ---
step "SIGTERM everything (graceful)"

if [ "$ALL_COUNT" -gt 0 ]; then
    # Word-split intentional: ALL_PIDS is a controlled space-separated PID list.
    # shellcheck disable=SC2086
    for pid in $ALL_PIDS; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null && ok "TERM $pid"
        fi
    done
    sleep 3
else
    ok "no live processes to signal"
fi

# --- SIGKILL survivors ---
step "SIGKILL any survivors"

SURVIVORS_NL=""
# shellcheck disable=SC2086  # see SIGTERM loop
for pid in $ALL_PIDS; do
    if kill -0 "$pid" 2>/dev/null; then
        SURVIVORS_NL="$SURVIVORS_NL$pid"$'\n'
    fi
done
SURVIVORS_NL="$(printf '%s' "$SURVIVORS_NL" | grep -v '^$' || true)"
SURVIVOR_COUNT=$(count_pids "$SURVIVORS_NL")

if [ "$SURVIVOR_COUNT" -gt 0 ]; then
    SURVIVORS="$(printf '%s' "$SURVIVORS_NL" | tr '\n' ' ')"
    warn "survived SIGTERM: $SURVIVORS — escalating to SIGKILL"
    # shellcheck disable=SC2086  # controlled PID list
    for pid in $SURVIVORS; do
        kill -KILL "$pid" 2>/dev/null && ok "KILL $pid"
    done
    sleep 1
else
    ok "all processes exited on SIGTERM"
fi

# --- Sweep stragglers (narrow pattern) ---
step "Sweep stragglers matching '$DAEMON_MATCH'"

# We re-use the precise DAEMON_MATCH pattern (default 'agentis daemon')
# rather than bare 'agentis' to avoid matching this script's own argv,
# sibling clones, or unrelated agentis-* processes. Residual risk: a
# stray daemon launched with a wrapper that mangled argv0 won't be
# caught — covered by the verification block below which surfaces it.
safe_killall TERM "$DAEMON_MATCH"
sleep 1
safe_killall KILL "$DAEMON_MATCH"
sleep 1

REMAINING_NL="$(filter_self "$(pgrep -f "$DAEMON_MATCH" 2>/dev/null | sort -u || true)")"
REMAINING=$(count_pids "$REMAINING_NL")
if [ "$REMAINING" -gt 0 ]; then
    fail "$REMAINING process(es) matching '$DAEMON_MATCH' still alive after KILL"
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        ps -o pid=,command= -p "$p" >&2 2>/dev/null || true
    done <<< "$REMAINING_NL"
fi
[ "$REMAINING" -eq 0 ] && ok "no processes matching '$DAEMON_MATCH' alive"

# --- Registry cleanup ---
step "Cleaning stale registry"

BACKUP_PATH=""
if [ -n "$AGENTIS_DIR" ] && [ -d "$AGENTIS_DIR/daemon" ]; then
    if [ "$NO_BACKUP" -eq 0 ]; then
        # n1: skip the backup entirely if `daemon/` has no regular files
        # (only inbox/ subdirs or it's empty). Avoids leaving a ~100-byte
        # empty tarball behind on every nothing-to-clean run.
        _has_files=0
        if find "$AGENTIS_DIR/daemon" -maxdepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
            _has_files=1
        fi
        if [ "$_has_files" -eq 0 ]; then
            ok "no registry files to back up — skipping tarball"
        else
            TS=$(date +%Y%m%d-%H%M%S)
            BACKUP_DIR="$AGENTIS_DIR/backups"
            mkdir -p "$BACKUP_DIR" 2>/dev/null || true
            # Append PID as a suffix so two operators running this script
            # in the same wall-clock second don't clobber each other's
            # backup tarball. PID is preferred over `mktemp` to avoid
            # adding a dependency we don't already require.
            BACKUP_PATH="$BACKUP_DIR/agentis-daemon-registry-backup-$TS-$$.tar.gz"
            if tar czf "$BACKUP_PATH" -C "$AGENTIS_DIR" daemon 2>/dev/null; then
                ok "backup: $BACKUP_PATH"
            else
                warn "backup failed (continuing): $BACKUP_PATH"
                BACKUP_PATH=""
            fi
        fi
        unset _has_files
    else
        ok "backup skipped (--no-backup)"
    fi

    # Use find -delete (not shell globs) — avoids 'no match' failures on
    # bash 3.2 / zsh when a registry happens to be empty.
    for ext in pid watchdog.pid colony heartbeat status stop; do
        find "$AGENTIS_DIR/daemon" -maxdepth 1 -name "*.$ext" -type f -delete 2>/dev/null || true
    done
    # Use `find -printf '.'` rather than `wc -l` so a filename containing
    # a literal newline doesn't inflate the count. Fall back to `wc -l` if
    # `find -printf` is unavailable (e.g. BSD/macOS find).
    REMAINING_FILES=$(find "$AGENTIS_DIR/daemon" -maxdepth 1 -type f -printf '.' 2>/dev/null | wc -c | tr -d ' ')
    if [ -z "$REMAINING_FILES" ]; then
        REMAINING_FILES=$(find "$AGENTIS_DIR/daemon" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
    fi
    ok "registry sidecar files removed (${REMAINING_FILES} regular files remain — inbox/ subdirs kept)"
else
    warn "no $AGENTIS_DIR/daemon — skipping registry cleanup"
fi

# --- Verification ---
step "Verification"

# Keep PID lists (not just counts) so we can include surviving_pids in
# the --json output for callers to finish the job without re-discovery
# (colonies #188, point 4).
FINAL_AGENTIS_NL="$(filter_self "$(pgrep -f "$DAEMON_MATCH" 2>/dev/null | sort -u || true)")"
FINAL_DASH_NL="$(filter_self "$(pgrep -f "$DASHBOARD_MATCH" 2>/dev/null | sort -u || true)")"
FINAL_DASH_PY_NL="$(filter_self "$(pgrep -f "$DASH_PY_MATCH" 2>/dev/null | sort -u || true)")"
FINAL_AGENTIS=$(count_pids "$FINAL_AGENTIS_NL")
FINAL_DASH=$(count_pids "$FINAL_DASH_NL")

# lsof is not installed everywhere (minimal containers, busybox). Try
# `ss` (iproute2, universal on Linux including Alpine) before falling
# back to "unknown" so the port check still works on minimal images.
FINAL_PORT_PIDS_NL=""
if command -v lsof >/dev/null 2>&1; then
    FINAL_PORT_PIDS_NL="$(lsof -iTCP:"$DASHBOARD_PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u || true)"
    FINAL_PORT=$(printf '%s\n' "$FINAL_PORT_PIDS_NL" | grep -c . || true)
    FINAL_PORT=${FINAL_PORT:-0}
elif command -v ss >/dev/null 2>&1; then
    # `ss -ltn 'sport = :<PORT>'` lists only listeners on that TCP port.
    # Count via `grep -c .` after stripping the header line. `-ltnp`
    # additionally exposes the `pid=<N>` field used for surviving_pids.
    FINAL_PORT=$(ss -ltn "sport = :$DASHBOARD_PORT" 2>/dev/null | tail -n +2 | grep -c .)
    FINAL_PORT=${FINAL_PORT:-0}
    FINAL_PORT_PIDS_NL="$(ss -ltnp "sport = :$DASHBOARD_PORT" 2>/dev/null \
        | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)"
else
    warn "neither lsof nor ss installed — skipping port $DASHBOARD_PORT check"
    FINAL_PORT="unknown"
fi

# Union all four survivor sources so the JSON caller (dashboard kill
# button) has the complete list of PIDs still blocking a clean state.
SURVIVING_PIDS_NL="$(printf '%s\n%s\n%s\n%s\n' \
    "$FINAL_AGENTIS_NL" "$FINAL_DASH_NL" "$FINAL_DASH_PY_NL" "$FINAL_PORT_PIDS_NL" \
    | grep -v '^$' | sort -u || true)"

REGISTRY_REMAINING=0
if [ -n "$AGENTIS_DIR" ] && [ -d "$AGENTIS_DIR/daemon" ]; then
    # See the matching `find -printf '.'` block above for why we don't pipe
    # to `wc -l` here — newlines in filenames would inflate the count.
    REGISTRY_REMAINING=$(find "$AGENTIS_DIR/daemon" -maxdepth 1 -type f -printf '.' 2>/dev/null | wc -c | tr -d ' ')
    if [ -z "$REGISTRY_REMAINING" ]; then
        REGISTRY_REMAINING=$(find "$AGENTIS_DIR/daemon" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
    fi
fi

echo "  matching processes: $FINAL_AGENTIS" >&2
echo "  dashboard processes: $FINAL_DASH" >&2
echo "  port 8420 listen:    $FINAL_PORT" >&2
echo "  registry files:      $REGISTRY_REMAINING" >&2

EXIT_CODE=0
PORT_OK=1
case "$FINAL_PORT" in
    0|unknown) PORT_OK=1 ;;
    *) PORT_OK=0 ;;
esac

if [ "$FINAL_AGENTIS" -eq 0 ] && [ "$FINAL_DASH" -eq 0 ] && [ "$PORT_OK" -eq 1 ]; then
    ok "federation fully stopped"
    EXIT_CODE=0
else
    fail "not fully clean — see counters above"
    EXIT_CODE=1
fi

if [ "$JSON_MODE" -eq 1 ]; then
    # Emit BACKUP_PATH as null (not empty string) when not produced, so
    # JSON consumers can `if data["backup"] is None: ...` cleanly.
    if [ -n "$BACKUP_PATH" ]; then
        BACKUP_JSON="\"$BACKUP_PATH\""
    else
        BACKUP_JSON="null"
    fi
    if [ "$FINAL_PORT" = "unknown" ]; then
        PORT_JSON="null"
    else
        PORT_JSON="$FINAL_PORT"
    fi
    # surviving_pids: JSON array of every PID still alive across the three
    # pgrep passes + the port listener set (colonies #188, point 4). Lets
    # the dashboard surface "2 processes survived: [1234, 5678]" without
    # shelling out again.
    if [ -z "$SURVIVING_PIDS_NL" ]; then
        SURVIVING_JSON="[]"
    else
        SURVIVING_JSON="[$(printf '%s' "$SURVIVING_PIDS_NL" | tr '\n' ',' | sed 's/,$//')]"
    fi
    printf '{"dry_run":false,"agentis":%d,"dashboard":%d,"port_8420":%s,"registry_remaining":%d,"backup":%s,"surviving_pids":%s,"exit":%d}\n' \
        "$FINAL_AGENTIS" "$FINAL_DASH" "$PORT_JSON" "$REGISTRY_REMAINING" "$BACKUP_JSON" "$SURVIVING_JSON" "$EXIT_CODE"
fi

exit "$EXIT_CODE"
