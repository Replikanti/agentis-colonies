#!/usr/bin/env bash
# tools/lib/daemon-guard.sh — shared spawn/reap guard for the tools tests that
# launch a REAL `agentis daemon` (#1750, #1869).
#
# The problem it removes: `( cd D && agentis daemon X.ag ... ) &` produces
# THREE processes — the subshell (`$!`), the `agentis daemon` watchdog, and
# the `agentis daemon-inner` worker it forks. Killing the recorded `$!` leaves
# both agentis processes alive; the watchdog reparents to PID 1 and keeps
# ticking against the test's (already deleted) workspace. Leaked daemons
# survive `git worktree remove`, accumulate across lint runs, and compete for
# LLM capacity until a later run degrades or hangs.
#
# Without `setsid` the daemon inherits the TEST SCRIPT's own process group, so
# the obvious `kill -- -$PGID` would kill the test script too. This helper
# therefore launches every daemon through `setsid` so it becomes its own
# session + group leader (`pgid == sid == pid`), records that leader pid, and
# reaps the whole group with a single `kill -- -<pgid>`. A second, independent
# safety net sweeps any process that both matches `agentis daemon` AND lives
# under the run's own workspace — the run-unique scope key (the `.ag` path is
# NOT unique, it is the shared repo path).
#
# Deliberately NOT built on tools/kill-federation.sh: its `DAEMON_MATCH` is
# host-wide by design, which is exactly why colony-lint refuses to run
# test-kill-federation.sh / test-kill-endpoint.sh by default (#329). Nothing
# here ever issues a bare `pkill -f 'agentis daemon'`.
#
# Dependencies: bash 3.2+ (no associative arrays, no `mapfile`), coreutils,
# `ps`, optionally `pgrep` and `setsid`. Degrades on hosts without `setsid`
# (macOS) or without `/proc`: single-pid ledger entries plus a `ps -eo
# pid=,args=` argv sweep.
#
# Usage:
#   . "$REPO_ROOT/tools/lib/daemon-guard.sh"
#   WORK="$(mktemp -d)"
#   daemon_guard_init "$WORK"
#   trap 'daemon_guard_teardown "$WORK"' EXIT
#   pid="$(daemon_guard_spawn --cwd "$WORK/fed" --log "$WORK/daemon.log" \
#            -- env FOO=bar agentis daemon agent.ag --colony c --enable-exec)"
#   ...
#   daemon_guard_stop "$pid"          # deliberate mid-sequence kill
#   daemon_guard_survivors "$WORK"    # prints "pid<TAB>argv", non-zero if any
#
# Do NOT add `TERM` to the same trap: bash already runs the EXIT trap on
# SIGTERM (measured rc=143), so the teardown would run twice.

# Physical path of the workspace this run owns; the scope key for every sweep.
DAEMON_GUARD_SCOPE="${DAEMON_GUARD_SCOPE:-}"
# Ledger of launched daemons, deliberately created OUTSIDE the scope dir so
# teardown still works after the workspace has been removed.
DAEMON_GUARD_LEDGER="${DAEMON_GUARD_LEDGER:-}"
# The session-leader launcher. Overridable so tests can exercise the
# no-setsid degradation path without surgery on PATH.
DAEMON_GUARD_SETSID="${DAEMON_GUARD_SETSID:-setsid}"

# daemon_guard_init <scope_dir>
#   Records the physical scope path and (re)uses one ledger file per shell.
#   Safe to call repeatedly; the ledger is never recreated while it exists.
daemon_guard_init() {
    local scope="${1:-}" resolved=""
    if [ -n "$scope" ] && [ -d "$scope" ]; then
        resolved="$(cd "$scope" 2>/dev/null && pwd -P)" || resolved=""
    fi
    if [ -n "$resolved" ]; then
        DAEMON_GUARD_SCOPE="$resolved"
    else
        DAEMON_GUARD_SCOPE="$scope"
    fi
    if [ -z "$DAEMON_GUARD_LEDGER" ] || [ ! -f "$DAEMON_GUARD_LEDGER" ]; then
        DAEMON_GUARD_LEDGER="$(mktemp "${TMPDIR:-/tmp}/daemon-guard-ledger.XXXXXX" 2>/dev/null)" \
            || DAEMON_GUARD_LEDGER=""
    fi
    return 0
}

# daemon_guard_spawn --cwd <dir> --log <file> -- <argv...>
#   Launches <argv...> with cwd=<dir>, stdin </dev/null, stdout+stderr into
#   <file>, and echoes the pid to reap. With `setsid` that pid is the session
#   + group leader (`sh -c` writes its own `$$`, then `exec` hands the pid to
#   the real argv unchanged) and the ledger marks it `pgid:` — group-killable.
#   Without `setsid` the entry is marked `pid:` and is NEVER group-killed,
#   because the process shares the caller's group.
daemon_guard_spawn() {
    local cwd="" log="/dev/null" pidfile pid n

    while [ $# -gt 0 ]; do
        case "$1" in
            --cwd) cwd="$2"; shift 2 ;;
            --log) log="$2"; shift 2 ;;
            --) shift; break ;;
            *) echo "daemon_guard_spawn: unexpected argument: $1" >&2; return 2 ;;
        esac
    done
    if [ $# -eq 0 ]; then
        echo "daemon_guard_spawn: no command given" >&2
        return 2
    fi
    [ -n "$cwd" ] || cwd="$PWD"
    [ -n "$DAEMON_GUARD_LEDGER" ] || daemon_guard_init "$cwd"

    pidfile="$(mktemp "${TMPDIR:-/tmp}/daemon-guard-pid.XXXXXX" 2>/dev/null)" || pidfile=""

    if [ -n "$pidfile" ] && command -v "$DAEMON_GUARD_SETSID" >/dev/null 2>&1; then
        # shellcheck disable=SC2016 # $$ must expand in the launched sh, not here
        ( cd "$cwd" && exec "$DAEMON_GUARD_SETSID" \
            sh -c 'echo $$ > "$1"; shift; exec "$@"' _ "$pidfile" "$@" ) \
            </dev/null >"$log" 2>&1 &
        pid=""
        n=0
        while [ "$n" -lt 50 ]; do
            pid="$(cat "$pidfile" 2>/dev/null || true)"
            case "$pid" in
                ''|*[!0-9]*) pid="" ;;
                *) break ;;
            esac
            sleep 0.1
            n=$((n + 1))
        done
        rm -f "$pidfile" 2>/dev/null || true
        if [ -n "$pid" ]; then
            _daemon_guard_record "pgid:$pid"
            printf '%s\n' "$pid"
            return 0
        fi
        # setsid resolved but the leader pid never materialised (exec failed,
        # or the process died instantly). Fall through: a plain background
        # launch at least leaves the ledger something to stop.
    fi
    rm -f "$pidfile" 2>/dev/null || true

    ( cd "$cwd" && exec "$@" ) </dev/null >"$log" 2>&1 &
    pid=$!
    _daemon_guard_record "pid:$pid"
    printf '%s\n' "$pid"
    return 0
}

# daemon_guard_stop <pid> [timeout_s]
#   TERM -> poll -> STOP -> KILL. Group-scoped when the ledger recorded the
#   pid as a session leader, single-pid otherwise. Returns 0 once nothing of
#   the target is left, 1 if something survived even SIGKILL.
daemon_guard_stop() {
    local pid="${1:-}" timeout_s="${2:-10}" mode="pid" i limit
    case "$pid" in
        ''|*[!0-9]*) return 0 ;;
    esac
    if [ -n "$DAEMON_GUARD_LEDGER" ] && [ -f "$DAEMON_GUARD_LEDGER" ] \
       && grep -q "^pgid:$pid\$" "$DAEMON_GUARD_LEDGER" 2>/dev/null; then
        mode="pgid"
    fi

    _daemon_guard_signal TERM "$mode" "$pid"
    limit=$((timeout_s * 5))
    i=0
    while [ "$i" -lt "$limit" ]; do
        _daemon_guard_alive "$mode" "$pid" || break
        sleep 0.2
        i=$((i + 1))
    done

    if _daemon_guard_alive "$mode" "$pid"; then
        # STOP before KILL: a frozen watchdog cannot fork a replacement
        # daemon-inner in the window between our signal and its exit.
        _daemon_guard_signal STOP "$mode" "$pid"
        _daemon_guard_signal KILL "$mode" "$pid"
        i=0
        while [ "$i" -lt 25 ]; do
            _daemon_guard_alive "$mode" "$pid" || break
            sleep 0.2
            i=$((i + 1))
        done
    fi

    _daemon_guard_forget "$pid"
    if _daemon_guard_alive "$mode" "$pid"; then
        return 1
    fi
    return 0
}

# daemon_guard_survivors [scope_dir]
#   Prints "pid<TAB>argv" for every live process that matches `agentis daemon`
#   AND belongs to <scope_dir> (its cwd is at/under the scope, or the scope
#   path appears in its argv). Self and the whole ancestor chain are excluded.
#   Returns 0 when the list is empty, 1 otherwise.
daemon_guard_survivors() {
    local scope="${1:-${DAEMON_GUARD_SCOPE:-}}" excl pid args found=0
    [ -n "$scope" ] || return 0
    case "$scope" in
        /*) ;;
        *) scope="$(cd "$scope" 2>/dev/null && pwd -P)" || scope="${1:-}" ;;
    esac
    [ -n "$scope" ] || return 0

    excl="$(_daemon_guard_exclude_pids)"
    for pid in $(_daemon_guard_candidate_pids); do
        case " $excl " in
            *" $pid "*) continue ;;
        esac
        kill -0 "$pid" 2>/dev/null || continue
        args="$(_daemon_guard_args "$pid")"
        case "$args" in
            *"agentis daemon"*) ;;
            *) continue ;;
        esac
        _daemon_guard_in_scope "$pid" "$scope" "$args" || continue
        printf '%s\t%s\n' "$pid" "$args"
        found=1
    done
    [ "$found" -eq 0 ]
}

# daemon_guard_reap
#   Stops every live ledger entry, then applies the same stop sequence to
#   whatever the scope sweep still reports. Returns the number of survivors
#   left afterwards (0 = clean).
daemon_guard_reap() {
    local entries line pid _rest survivors n=0

    if [ -n "$DAEMON_GUARD_LEDGER" ] && [ -f "$DAEMON_GUARD_LEDGER" ]; then
        entries="$(cat "$DAEMON_GUARD_LEDGER" 2>/dev/null || true)"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            pid="${line#*:}"
            daemon_guard_stop "$pid" 10 || true
        done <<EOF
$entries
EOF
    fi

    survivors="$(daemon_guard_survivors "${DAEMON_GUARD_SCOPE:-}" || true)"
    if [ -n "$survivors" ]; then
        while read -r pid _rest; do
            daemon_guard_stop "$pid" 5 || true
        done <<EOF
$survivors
EOF
    fi

    survivors="$(daemon_guard_survivors "${DAEMON_GUARD_SCOPE:-}" || true)"
    if [ -n "$survivors" ]; then
        n="$(printf '%s\n' "$survivors" | wc -l | tr -d ' ')"
    fi
    return "$n"
}

# daemon_guard_teardown [scope_dir]
#   The EXIT-trap body: capture the script's status FIRST, reap (kill before
#   rm removes the ENOTEMPTY race), remove the workspace and the ledger, then
#   hand the original status back. Every step is best-effort — a teardown must
#   never turn a passing run red, nor mask a failing one.
daemon_guard_teardown() {
    local _rc=$?
    local scope="${1:-${DAEMON_GUARD_SCOPE:-}}"

    if [ -n "$scope" ]; then
        daemon_guard_init "$scope" >/dev/null 2>&1 || true
    fi
    daemon_guard_reap >/dev/null 2>&1 || true
    if [ -n "$scope" ]; then
        rm -rf "$scope" 2>/dev/null || true
    fi
    if [ -n "${DAEMON_GUARD_LEDGER:-}" ]; then
        rm -f "$DAEMON_GUARD_LEDGER" 2>/dev/null || true
        DAEMON_GUARD_LEDGER=""
    fi
    return "$_rc"
}

# --- internals ---

_daemon_guard_record() {
    [ -n "${DAEMON_GUARD_LEDGER:-}" ] || return 0
    printf '%s\n' "$1" >> "$DAEMON_GUARD_LEDGER" 2>/dev/null || true
    return 0
}

_daemon_guard_forget() {
    local pid="$1" tmp
    [ -n "${DAEMON_GUARD_LEDGER:-}" ] && [ -f "$DAEMON_GUARD_LEDGER" ] || return 0
    tmp="$(mktemp "${TMPDIR:-/tmp}/daemon-guard-ledger.XXXXXX" 2>/dev/null)" || return 0
    grep -v -e "^pgid:$pid\$" -e "^pid:$pid\$" "$DAEMON_GUARD_LEDGER" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$DAEMON_GUARD_LEDGER" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    return 0
}

# Group signals only reach a group we created via setsid; `pid` entries are
# single-pid strictly, so a fallback launch can never take the caller's own
# process group down with it.
_daemon_guard_signal() {
    local sig="$1" mode="$2" pid="$3"
    if [ "$mode" = "pgid" ]; then
        kill -"$sig" -- "-$pid" 2>/dev/null || true
    fi
    kill -"$sig" "$pid" 2>/dev/null || true
    return 0
}

_daemon_guard_alive() {
    local mode="$1" pid="$2"
    if [ "$mode" = "pgid" ] && kill -0 -- "-$pid" 2>/dev/null; then
        return 0
    fi
    kill -0 "$pid" 2>/dev/null
}

_daemon_guard_candidate_pids() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f 'agentis daemon' 2>/dev/null || true
    else
        ps -eo pid=,args= 2>/dev/null | while read -r p rest; do
            case "$rest" in
                *"agentis daemon"*) printf '%s\n' "$p" ;;
            esac
        done
    fi
    return 0
}

_daemon_guard_args() {
    local pid="$1" out=""
    if [ -r "/proc/$pid/cmdline" ]; then
        out="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    fi
    if [ -z "$out" ]; then
        out="$(ps -o args= -p "$pid" 2>/dev/null | head -1 || true)"
    fi
    printf '%s' "$out"
}

# cwd is the run-unique key; the argv fallback covers hosts without /proc and
# daemons that chdir'd away after launch.
_daemon_guard_in_scope() {
    local pid="$1" scope="$2" args="$3" cwd=""
    if [ -r "/proc/$pid/cwd" ]; then
        cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
        cwd="${cwd% (deleted)}"
    fi
    if [ -n "$cwd" ]; then
        case "$cwd" in
            "$scope"|"$scope"/*) return 0 ;;
        esac
    fi
    case "$args" in
        *"$scope"*) return 0 ;;
    esac
    return 1
}

# Self + ancestor chain, so a sweep can never signal the test script, its
# shell, or the lint driver above it (same idea as tools/kill-federation.sh).
_daemon_guard_exclude_pids() {
    local out="$$ ${BASHPID:-} " walk="${PPID:-}" safety=0
    while [ -n "$walk" ] && [ "$walk" != "0" ] && [ "$walk" != "1" ] && [ "$safety" -lt 32 ]; do
        out="$out$walk "
        walk="$(ps -o ppid= -p "$walk" 2>/dev/null | tr -d ' ' || true)"
        safety=$((safety + 1))
    done
    printf '%s' "$out"
}
