#!/usr/bin/env bash
# tools/code-edit-job.sh (#1214): a FAST launcher/poller for the slow
# checkout-edit orchestrator (tools/code-edit-in-checkout.sh).
#
# Why this exists: agentis caps a single `exec sh` invocation at ~120000ms
# (the `exec.default_timeout_ms` knob is ignored), but the orchestrator's job
# (clone + flat-cyborg/claude edit + commit + push + open PR) routinely runs for
# minutes. Run synchronously, the orchestrator gets `ExecTimeout after 120000ms`
# and is killed mid-edit. So the long job MUST run DETACHED and code_writer must
# POLL a result file across ticks.
#
# This launcher returns in well under 120s on EVERY invocation:
#   - First call for an issue: create a per-issue job dir, mark it `running`,
#     and launch code-edit-in-checkout.sh DETACHED (setsid, fully redirected,
#     </dev/null). Print `LAUNCHED` and exit 0 immediately — does NOT wait.
#   - A later call while the detached job is still alive: print `RUNNING`,
#     exit 0. It does NOT start a second clone/edit (the whole point — the old
#     synchronous version re-cloned every tick).
#   - A later call after the job finished: print the terminal state read from
#     the job dir — `DONE <pr-url>` / `NO_EDITS` / `ERROR <short>` — and exit 0.
#
# Job dir: <fed>/.agentis/jobs/<colony>/issue-<iid>/ with files:
#   status  : running | done | no_edits | error
#   result  : the PR URL (only when status=done)
#   pid      : pid of the detached orchestrator (the setsid leader)
#   log      : combined stdout+stderr of the detached orchestrator
#
# Job-dir lifecycle / consumption: this launcher does NOT delete the job dir.
# On a terminal poll (`DONE`/`NO_EDITS`/`ERROR`) it CLEARS the dir so the next
# invocation for the same iid starts a fresh job (a retry after ERROR/NO_EDITS,
# or a brand-new edit if the issue changed). code_writer consumes the terminal
# line on the tick it observes it. Idempotency while running is preserved by the
# pid-liveness check, not by the dir's persistence.
#
# Dead/crashed job: if status=running but the recorded pid is no longer alive,
# the job is treated as `error` (the detached orchestrator died without writing
# a terminal status — e.g. OOM/SIGKILL). We report `ERROR job-died` and clear
# the dir so the next poll relaunches; we never hang waiting on a dead pid.
#
# Token handling: the detached child inherits GITHUB_TOKEN from this launcher's
# environment exactly as the synchronous path did. The token VALUE is never
# expanded onto a command line, never echoed, and never written to the job dir.
# The orchestrator's own GIT_ASKPASS path keeps it out of argv / the remote URL.
#
# Usage (identical identifying args to code-edit-in-checkout.sh):
#   code-edit-job.sh --owner <o> --repo <r> --issue <iid> \
#       --branch <name> --title <t> --task <text>
#
# Override (testing): CODE_EDIT_ORCH points at a stub orchestrator instead of
# tools/code-edit-in-checkout.sh. The stub must honour the same exit-code
# contract (0 -> PR URL on stdout, 3 -> NO_EDITS, other -> failure).
set -eu

# ---------------------------------------------------------------------------
# Arg parsing (mirrors code-edit-in-checkout.sh).
# ---------------------------------------------------------------------------
OWNER=""
REPO=""
ISSUE=""
BRANCH=""
TITLE=""
TASK=""

usage() {
    echo "usage: code-edit-job.sh --owner <o> --repo <r> --issue <iid> --branch <name> --title <t> --task <text>" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --owner)  OWNER="${2:-}";  shift 2 ;;
        --repo)   REPO="${2:-}";   shift 2 ;;
        --issue)  ISSUE="${2:-}";  shift 2 ;;
        --branch) BRANCH="${2:-}"; shift 2 ;;
        --title)  TITLE="${2:-}";  shift 2 ;;
        --task)   TASK="${2:-}";   shift 2 ;;
        *) echo "code-edit-job.sh: unknown flag: $1" >&2; usage; exit 2 ;;
    esac
done

# Legacy single-block fan-out (#316): empty --owner/--repo means the colony env
# carries the real values in GITHUB_OWNER/GITHUB_REPO. Resolve them here so the
# job-dir key and the orchestrator both see the same owner/repo.
if [ -z "$OWNER" ]; then OWNER="${GITHUB_OWNER:-}"; fi
if [ -z "$REPO" ]; then REPO="${GITHUB_REPO:-}"; fi

if [ -z "$OWNER" ] || [ -z "$REPO" ] || [ -z "$ISSUE" ] || [ -z "$BRANCH" ] || [ -z "$TITLE" ] || [ -z "$TASK" ]; then
    echo "code-edit-job.sh: --owner, --repo, --issue, --branch, --title, --task are all required" >&2
    usage
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Resolve FED_DIR + colony name exactly like code-edit-in-checkout.sh so the
# job dir lives under the same federation tree the orchestrator clones into.
# ---------------------------------------------------------------------------
if [ -n "${COLONY_DIR:-}" ]; then
    FED_DIR="$(cd "$COLONY_DIR/.." && pwd)"
    COLONY_NAME="$(basename "$COLONY_DIR")"
else
    FED_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    COLONY_NAME="implementation"
fi

# The slow orchestrator. Overridable for tests via CODE_EDIT_ORCH.
ORCH="${CODE_EDIT_ORCH:-$SCRIPT_DIR/code-edit-in-checkout.sh}"

JOBDIR="$FED_DIR/.agentis/jobs/$COLONY_NAME/issue-$ISSUE"

# pid_alive <pid>: 0 (true) if the pid names a live process, 1 otherwise.
pid_alive() {
    [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

# clear_job: remove the job dir so the next invocation starts fresh.
clear_job() {
    rm -rf "$JOBDIR"
}

# read_status / read_result: total reads — empty when the file is absent.
read_status() {
    [ -f "$JOBDIR/status" ] && cat "$JOBDIR/status" 2>/dev/null || true
}
read_result() {
    [ -f "$JOBDIR/result" ] && cat "$JOBDIR/result" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Poll an existing job dir before launching anything.
# ---------------------------------------------------------------------------
if [ -d "$JOBDIR" ]; then
    STATUS="$(read_status)"
    case "$STATUS" in
        running)
            PID="$([ -f "$JOBDIR/pid" ] && cat "$JOBDIR/pid" 2>/dev/null || true)"
            if pid_alive "$PID"; then
                # Job still in flight — do NOT start a second clone/edit.
                echo "RUNNING"
                exit 0
            fi
            # status=running but the orchestrator is gone: it died without
            # writing a terminal status. Report error + clear so the next poll
            # relaunches; never hang on a dead pid.
            clear_job
            echo "ERROR job-died"
            exit 0
            ;;
        done)
            URL="$(read_result)"
            clear_job
            if [ -n "$URL" ]; then
                echo "DONE $URL"
            else
                # done with no URL recorded — treat as an error so the caller
                # retries rather than silently succeeding with no PR.
                echo "ERROR done-without-url"
            fi
            exit 0
            ;;
        no_edits)
            clear_job
            echo "NO_EDITS"
            exit 0
            ;;
        error)
            clear_job
            echo "ERROR job-failed"
            exit 0
            ;;
        *)
            # Unknown / empty status (a stale or half-written dir): drop it and
            # fall through to a fresh launch below.
            clear_job
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# No live job for this iid — launch one DETACHED and return immediately.
# ---------------------------------------------------------------------------
mkdir -p "$JOBDIR"
printf 'running' > "$JOBDIR/status"

# The detached worker runs the slow orchestrator, captures its exit code, and
# writes the terminal status + result ATOMICALLY (write to a temp file, then
# mv) so a poll never observes a half-written status. The orchestrator's stdout
# (the PR URL on success) is captured to "$JOBDIR/out"; its combined log goes
# to "$JOBDIR/log". The token is inherited via the environment — never named on
# a command line here, so it stays out of any `set -x` trace and the job dir.
#
# We export the identifying args + ORCH/JOBDIR for the worker subshell so the
# detached `setsid bash -c` body carries no untrusted concatenation.
export CEJ_ORCH="$ORCH"
export CEJ_JOBDIR="$JOBDIR"
export CEJ_OWNER="$OWNER" CEJ_REPO="$REPO" CEJ_ISSUE="$ISSUE"
export CEJ_BRANCH="$BRANCH" CEJ_TITLE="$TITLE" CEJ_TASK="$TASK"

# SC2016: the $CEJ_* refs are deliberately INSIDE single quotes — they must
# expand in the DETACHED child from its inherited env, NOT in this launcher.
# shellcheck disable=SC2016
setsid bash -c '
    set +e
    "$CEJ_ORCH" \
        --owner "$CEJ_OWNER" --repo "$CEJ_REPO" --issue "$CEJ_ISSUE" \
        --branch "$CEJ_BRANCH" --title "$CEJ_TITLE" --task "$CEJ_TASK" \
        > "$CEJ_JOBDIR/out" 2> "$CEJ_JOBDIR/log"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        # Last non-empty line of stdout is the PR URL.
        url="$(grep -v "^$" "$CEJ_JOBDIR/out" 2>/dev/null | tail -n 1)"
        printf "%s" "$url" > "$CEJ_JOBDIR/result.tmp"
        mv -f "$CEJ_JOBDIR/result.tmp" "$CEJ_JOBDIR/result"
        printf "done" > "$CEJ_JOBDIR/status.tmp"
    elif [ "$rc" -eq 3 ]; then
        printf "no_edits" > "$CEJ_JOBDIR/status.tmp"
    else
        printf "error" > "$CEJ_JOBDIR/status.tmp"
    fi
    mv -f "$CEJ_JOBDIR/status.tmp" "$CEJ_JOBDIR/status"
' </dev/null >/dev/null 2>&1 &

CHILD_PID=$!
printf '%s' "$CHILD_PID" > "$JOBDIR/pid"
# Detach from the job so this launcher can exit without leaving a tracked child.
disown "$CHILD_PID" 2>/dev/null || true

echo "LAUNCHED"
exit 0
