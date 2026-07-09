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
# This launcher returns in well under 120s on EVERY invocation. It is a DUMB
# launcher/reporter — it does NOT interpret job state (#1356). The running/done/
# no_edits/error/job-died decision, and the terminal-dir cleanup, now live in
# code_writer.ag's tick (it already polls job state across ticks). This script
# keeps only its irreducible job: fork the detached orchestrator (`.ag` cannot)
# and report the raw job-dir facts.
#   - First call for an issue: create a per-issue job dir, mark it `running`,
#     and launch code-edit-in-checkout.sh DETACHED (setsid, fully redirected,
#     </dev/null). Print `LAUNCHED` and exit 0 immediately — does NOT wait.
#   - A later call that finds an existing job dir: print ONE raw line
#     `STATUS=<s> PID_ALIVE=<0|1> RESULT=<url>` (see below) and exit 0. It does
#     NOT start a second clone/edit (the whole point — the old synchronous
#     version re-cloned every tick), and it does NOT decide what the facts mean.
#   - When the global concurrency cap deferred the launch (no job dir created):
#     print `RUNNING` — the not-yet-done sentinel code_writer re-polls on.
#
# Job dir: <fed>/.agentis/jobs/<colony>/issue-<iid>/ with files:
#   status  : running | done | no_edits | error
#   result  : the PR URL (only when status=done)
#   pid      : pid of the detached orchestrator (the setsid leader)
#   log      : combined stdout+stderr of the detached orchestrator
#
# Poll output (raw, non-deciding — one line, space-separated KEY=VALUE tokens):
#   STATUS=<running|done|no_edits|error|none>  raw status-file content (`none`
#                                              when the file is absent/empty)
#   PID_ALIVE=<0|1>                            1 iff the recorded pid is live
#   RESULT=<url>                               result-file content (PR URL on
#                                              done), empty otherwise (last token)
# code_writer.ag interprets: running+PID_ALIVE=1 -> still running; running+
# PID_ALIVE=0 -> job-died; done+RESULT -> DONE <url>; done+empty -> done-without-
# url; no_edits -> NO_EDITS; error -> job-failed; none/unknown -> stale dir. It
# then issues its own cleanup (rm -rf of the job dir) on every terminal state, so
# the next invocation for the same iid starts fresh.
#
# Job-dir lifecycle / consumption: this launcher NEVER deletes the job dir — the
# cleanup moved to code_writer.ag (#1356), which clears it once it decides a
# terminal state. Idempotency while running is preserved by the pid-liveness
# check, not by the dir's persistence.
#
# Dead/crashed job: if status=running but the recorded pid is no longer alive,
# this launcher just reports `PID_ALIVE=0` alongside `STATUS=running`; code_writer
# reads that as `ERROR job-died` (the detached orchestrator died without writing a
# terminal status — e.g. OOM/SIGKILL) and clears the dir so the next poll
# relaunches. We never hang waiting on a dead pid.
#
# Token handling: the detached child inherits GITHUB_TOKEN from this launcher's
# environment exactly as the synchronous path did. The token VALUE is never
# expanded onto a command line, never echoed, and never written to the job dir.
# The orchestrator's own GIT_ASKPASS path keeps it out of argv / the remote URL.
#
# #1422 M1 — the --decompose-only stand-alone decomposition primitive. When
# code_writer.ag drives the AG-driven decompose loop, it forks ONE detached
# --decompose-only drive: the orchestrator runs only the decomposition step and
# writes the ordered NUL-delimited subtask list to --subtasks-out; its subtask
# count is surfaced on the poll as STATUS=decomposed with a SUBTASKS=<n> token
# (spliced the same way --one-attempt's ATTEMPT_EXIT/CHURN/VERIFY tokens are).
#
# Usage (identical identifying args to code-edit-in-checkout.sh):
#   code-edit-job.sh --owner <o> --repo <r> --issue <iid> \
#       --branch <name> --title <t> --task <text>
#
# Override (testing): CODE_EDIT_ORCH points at a stub orchestrator instead of
# tools/code-edit-in-checkout.sh. The stub must honour the same exit-code
# contract (0 -> PR URL on stdout, 3 -> NO_EDITS, other -> failure).
#
# Global concurrency cap (#1367): each detached orchestrator runs a
# flat-cyborg -> claude (Node) session ~330MB RSS, so an unbounded fan-out
# (code_writer can pick several issues) overheats the host. Before launching a
# NEW job we count the live sibling jobs (status=running + pid alive) under the
# same jobs root; if that count is already >= CODE_EDIT_MAX_CONCURRENT (default
# 2) we print `RUNNING` — the same not-yet-done sentinel code_writer treats as
# "still busy, poll next tick" (it leaves the #1185 markers unset and re-polls)
# — and exit 0 WITHOUT touching this issue's job dir, so the next tick
# re-evaluates the issue cleanly. Polls of an EXISTING job dir are never capped
# (no new orchestrator is started on that path).
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
# --description (#1349) is OPTIONAL: code_writer.ag threads the agent's drafted
# PR/MR body through here; we forward it verbatim to the detached worker. When
# absent the orchestrator falls back to its static template.
DESCRIPTION=""
DECOMPOSE=0
RECOVER=0
# #1354 step 2b — the caller-driven-loop primitives. When AG_DRIVEN_EDIT_LOOP is
# on, code_writer.ag drives the attempt/budget/continuation/verify state machine
# itself and uses this launcher only to fork ONE detached primitive drive per
# tick. --one-attempt runs a single edit and its outcome line is surfaced on the
# poll as STATUS=attempt_done with CHURN/VERIFY/ATTEMPT_EXIT tokens; --finalize
# commits the accumulated diff + opens the PR (surfaced as the ordinary
# done/no_edits/error the default path already reports). --reuse / --continuation
# ride along to the orchestrator verbatim.
ONE_ATTEMPT=0
REUSE=0
FINALIZE=0
CONTINUATION=""
# #1422 M1 — the stand-alone decomposition primitive. --decompose-only runs ONLY
# the decompose drive in the detached orchestrator and its subtask count is
# surfaced on the poll as STATUS=decomposed with a SUBTASKS token; the ordered
# NUL-delimited subtask records land in the caller-named --subtasks-out file
# (which the orchestrator writes OUTSIDE the job dir). Both flags ride through to
# the orchestrator verbatim.
DECOMPOSE_ONLY=0
SUBTASKS_OUT=""

usage() {
    echo "usage: code-edit-job.sh --owner <o> --repo <r> --issue <iid> --branch <name> --title <t> --task <text> [--description <d>] [--decompose] [--decompose-only --subtasks-out <file>] [--recover] [--one-attempt] [--reuse] [--finalize] [--continuation <file>]" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --owner)  OWNER="${2:-}";  shift 2 ;;
        --repo)   REPO="${2:-}";   shift 2 ;;
        --issue)  ISSUE="${2:-}";  shift 2 ;;
        --branch) BRANCH="${2:-}"; shift 2 ;;
        --title)  TITLE="${2:-}";  shift 2 ;;
        --task)   TASK="${2:-}";   shift 2 ;;
        --description) DESCRIPTION="${2:-}"; shift 2 ;;
        --decompose) DECOMPOSE=1; shift ;;
        --recover) RECOVER=1; shift ;;
        --one-attempt) ONE_ATTEMPT=1; shift ;;
        --reuse) REUSE=1; shift ;;
        --finalize) FINALIZE=1; shift ;;
        --continuation) CONTINUATION="${2:-}"; shift 2 ;;
        --decompose-only) DECOMPOSE_ONLY=1; shift ;;
        --subtasks-out) SUBTASKS_OUT="${2:-}"; shift 2 ;;
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
# colony-lint: getenv-unregistered-ok  (test-only override, not an operator knob)
ORCH="${CODE_EDIT_ORCH:-$SCRIPT_DIR/code-edit-in-checkout.sh}"

JOBDIR="$FED_DIR/.agentis/jobs/$COLONY_NAME/issue-$ISSUE"

# Jobs root shared by every issue-<iid> dir for this colony (the parent of
# JOBDIR). The concurrency cap counts live siblings here.
JOBS_ROOT="$(dirname "$JOBDIR")"

# CODE_EDIT_MAX_CONCURRENT (#1367): hard ceiling on simultaneously-running
# detached orchestrators. Validate to a positive integer; fall back to 2 on
# empty / non-numeric / zero garbage.
CODE_EDIT_MAX_CONCURRENT="${CODE_EDIT_MAX_CONCURRENT:-2}"
case "$CODE_EDIT_MAX_CONCURRENT" in
    ''|*[!0-9]*) CODE_EDIT_MAX_CONCURRENT=2 ;;
    *) [ "$CODE_EDIT_MAX_CONCURRENT" -gt 0 ] || CODE_EDIT_MAX_CONCURRENT=2 ;;
esac

# pid_alive <pid>: 0 (true) if the pid names a live process, 1 otherwise.
pid_alive() {
    [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

# count_live_jobs: number of sibling issue-<iid> job dirs under JOBS_ROOT whose
# status reads `running` AND whose recorded pid is alive, EXCLUDING this issue's
# own dir. Reuses the exact same status/pid-liveness logic the poll path uses so
# the two never diverge. Prints an integer.
count_live_jobs() {
    _live=0
    [ -d "$JOBS_ROOT" ] || { printf '%s' 0; return 0; }
    for _d in "$JOBS_ROOT"/issue-*; do
        # Literal-glob guard (no matches) + skip our own dir.
        [ -d "$_d" ] || continue
        [ "$_d" = "$JOBDIR" ] && continue
        _st=""
        if [ -f "$_d/status" ]; then _st="$(cat "$_d/status" 2>/dev/null || true)"; fi
        [ "$_st" = "running" ] || continue
        _p=""
        if [ -f "$_d/pid" ]; then _p="$(cat "$_d/pid" 2>/dev/null || true)"; fi
        if pid_alive "$_p"; then _live=$((_live + 1)); fi
    done
    printf '%s' "$_live"
}

# read_status / read_result: total reads — empty when the file is absent.
read_status() {
    if [ -f "$JOBDIR/status" ]; then cat "$JOBDIR/status" 2>/dev/null || true; fi
}
read_result() {
    if [ -f "$JOBDIR/result" ]; then cat "$JOBDIR/result" 2>/dev/null || true; fi
}

# ---------------------------------------------------------------------------
# Poll an existing job dir (#1356): report the RAW status + pid-liveness +
# result and exit. This launcher no longer INTERPRETS those facts — the
# running/done/no_edits/error/job-died FSM and the terminal-dir cleanup now
# live in code_writer.ag's tick. `none` marks an absent/empty status file (a
# stale or half-written dir); code_writer treats it as stale and clears it.
# A URL carries no spaces, so the single-line KEY=VALUE token format is total.
# ---------------------------------------------------------------------------
if [ -d "$JOBDIR" ]; then
    STATUS="$(read_status)"
    [ -n "$STATUS" ] || STATUS="none"
    PID=""
    if [ -f "$JOBDIR/pid" ]; then PID="$(cat "$JOBDIR/pid" 2>/dev/null || true)"; fi
    if pid_alive "$PID"; then ALIVE=1; else ALIVE=0; fi
    RESULT="$(read_result)"
    # #1354 step 2b: a --one-attempt job records its outcome as re-keyed tokens
    # (ATTEMPT_EXIT/CHURN/VERIFY) in the `attempt` file. Splice them in BEFORE the
    # trailing RESULT= token so RESULT stays last + space-free and the default
    # poll line is byte-identical when no attempt file is present.
    # #1422 M1: a --decompose-only job records its subtask count the same way
    # (SUBTASKS=<n> in the `attempt` file, STATUS=decomposed), so the same splice
    # surfaces `STATUS=decomposed PID_ALIVE=0 SUBTASKS=<n> RESULT=`.
    ATTEMPT=""
    if { [ "$STATUS" = "attempt_done" ] || [ "$STATUS" = "decomposed" ]; } && [ -f "$JOBDIR/attempt" ]; then
        ATTEMPT="$(cat "$JOBDIR/attempt" 2>/dev/null || true)"
    fi
    if [ -n "$ATTEMPT" ]; then
        printf 'STATUS=%s PID_ALIVE=%s %s RESULT=%s\n' "$STATUS" "$ALIVE" "$ATTEMPT" "$RESULT"
    else
        printf 'STATUS=%s PID_ALIVE=%s RESULT=%s\n' "$STATUS" "$ALIVE" "$RESULT"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Global concurrency cap (#1367): before starting a NEW orchestrator, refuse if
# the host is already running CODE_EDIT_MAX_CONCURRENT of them. Print the
# not-yet-done sentinel (`RUNNING`) so code_writer polls again next tick, and do
# NOT create/overwrite this issue's job dir — the next tick re-evaluates cleanly.
# ---------------------------------------------------------------------------
LIVE_JOBS="$(count_live_jobs)"
if [ "$LIVE_JOBS" -ge "$CODE_EDIT_MAX_CONCURRENT" ]; then
    echo "RUNNING"
    exit 0
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
# #1354 step 2b: a --continuation file is authored by the caller (code_writer.ag)
# in its own temp space, which may be reclaimed before this DETACHED worker execs
# the orchestrator. Copy it into the job dir NOW so the job owns a stable copy;
# forward that path (empty when absent).
CONT_FWD=""
if [ -n "$CONTINUATION" ] && [ -r "$CONTINUATION" ]; then
    cp "$CONTINUATION" "$JOBDIR/continuation" 2>/dev/null && CONT_FWD="$JOBDIR/continuation"
fi

export CEJ_ORCH="$ORCH"
export CEJ_JOBDIR="$JOBDIR"
export CEJ_OWNER="$OWNER" CEJ_REPO="$REPO" CEJ_ISSUE="$ISSUE"
export CEJ_BRANCH="$BRANCH" CEJ_TITLE="$TITLE" CEJ_TASK="$TASK"
export CEJ_DESCRIPTION="$DESCRIPTION"
export CEJ_DECOMPOSE="$DECOMPOSE"
export CEJ_RECOVER="$RECOVER"
export CEJ_ONE_ATTEMPT="$ONE_ATTEMPT"
export CEJ_REUSE="$REUSE"
export CEJ_FINALIZE="$FINALIZE"
export CEJ_CONTINUATION="$CONT_FWD"
export CEJ_DECOMPOSE_ONLY="$DECOMPOSE_ONLY"
export CEJ_SUBTASKS_OUT="$SUBTASKS_OUT"

# SC2016: the $CEJ_* refs are deliberately INSIDE single quotes — they must
# expand in the DETACHED child from its inherited env, NOT in this launcher.
# shellcheck disable=SC2016
setsid bash -c '
    set +e
    set -- --owner "$CEJ_OWNER" --repo "$CEJ_REPO" --issue "$CEJ_ISSUE" \
        --branch "$CEJ_BRANCH" --title "$CEJ_TITLE" --task "$CEJ_TASK"
    [ -n "$CEJ_DESCRIPTION" ] && set -- "$@" --description "$CEJ_DESCRIPTION"
    [ "$CEJ_DECOMPOSE" = "1" ] && set -- "$@" --decompose
    [ "$CEJ_RECOVER" = "1" ] && set -- "$@" --recover
    [ "$CEJ_ONE_ATTEMPT" = "1" ] && set -- "$@" --one-attempt
    [ "$CEJ_REUSE" = "1" ] && set -- "$@" --reuse
    [ "$CEJ_FINALIZE" = "1" ] && set -- "$@" --finalize
    [ -n "$CEJ_CONTINUATION" ] && set -- "$@" --continuation "$CEJ_CONTINUATION"
    [ "$CEJ_DECOMPOSE_ONLY" = "1" ] && set -- "$@" --decompose-only
    [ -n "$CEJ_SUBTASKS_OUT" ] && set -- "$@" --subtasks-out "$CEJ_SUBTASKS_OUT"
    "$CEJ_ORCH" "$@" > "$CEJ_JOBDIR/out" 2> "$CEJ_JOBDIR/log"
    rc=$?
    if [ "$CEJ_ONE_ATTEMPT" = "1" ]; then
        # #1354 step 2b: a --one-attempt drive prints exactly ONE structured
        # outcome line and exits 0. Surface its fields to the poller as a
        # dedicated terminal status; the CALLER (code_writer.ag) decides whether
        # to re-drive (--reuse), finalize, or give up. A missing/garbled line or
        # a non-zero exit is a genuine failure of the primitive itself.
        line="$(grep "^ONE_ATTEMPT " "$CEJ_JOBDIR/out" 2>/dev/null | tail -n 1)"
        if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
            # Re-key exit=/churn=/verify= into poll tokens the caller reads with
            # its KEY=value reader (ATTEMPT_EXIT avoids any collision with a bare
            # exit; values are single space-free words so the token line stays
            # total).
            printf "%s" "${line#ONE_ATTEMPT }" \
                | sed "s/exit=/ATTEMPT_EXIT=/; s/churn=/CHURN=/; s/verify=/VERIFY=/" \
                > "$CEJ_JOBDIR/attempt.tmp"
            mv -f "$CEJ_JOBDIR/attempt.tmp" "$CEJ_JOBDIR/attempt"
            printf "attempt_done" > "$CEJ_JOBDIR/status.tmp"
        else
            printf "error" > "$CEJ_JOBDIR/status.tmp"
        fi
    elif [ "$CEJ_DECOMPOSE_ONLY" = "1" ]; then
        # #1422 M1: a --decompose-only drive prints exactly ONE line
        # `DECOMPOSED count=<n>` and exits 0; the subtask records were written to
        # --subtasks-out. Re-key count= into a SUBTASKS= poll token (single
        # space-free word) and surface it as STATUS=decomposed. A missing/garbled
        # line or non-zero exit is a genuine failure of the primitive itself.
        line="$(grep "^DECOMPOSED " "$CEJ_JOBDIR/out" 2>/dev/null | tail -n 1)"
        if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
            printf "%s" "${line#DECOMPOSED }" \
                | sed "s/count=/SUBTASKS=/" \
                > "$CEJ_JOBDIR/attempt.tmp"
            mv -f "$CEJ_JOBDIR/attempt.tmp" "$CEJ_JOBDIR/attempt"
            printf "decomposed" > "$CEJ_JOBDIR/status.tmp"
        else
            printf "error" > "$CEJ_JOBDIR/status.tmp"
        fi
    elif [ "$rc" -eq 0 ]; then
        # Last non-empty line of stdout is the PR URL (default + --finalize).
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
