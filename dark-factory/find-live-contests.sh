#!/usr/bin/env bash
# find-live-contests.sh — the scheduled entry point of live audit-contest discovery (#2312). A thin launcher for
# the one-shot agent auditor/agents/contest-finder.ag, which owns everything that decides something: the platform
# list (IMMUNEFI, CODEHAWKS, SHERLOCK, CANTINA, CODE4RENA), the page walks, the live rules, the per-platform
# fetch status and the whole output block. This script only prepares an agentis workspace, maps flags to env,
# runs `agentis go` under a global timeout, and prints the agent's out.tsv verbatim. It never filters, greps or
# rewrites that output, so a new platform needs no change here.
#
# Usage: find-live-contests.sh [--now <epoch-s>] [--<platform>-from <file>]... [--<platform>-url <url>]... [-h]
#   <platform> is one of immunefi, codehawks, sherlock, cantina, code4rena.
#   --<platform>-from : offline hatch, read a recorded response instead of fetching (no network for that
#                       platform). --sherlock-from and --code4rena-from are repeatable: the k-th file is page k.
#                       An unreadable file is a usage error (exit 2).
#   --<platform>-url  : endpoint override (the defaults live only in the agent). Sherlock and Code4rena append
#                       their page query to it.
#   --now             : pin the clock to <epoch-s> (tests); default the real clock.
#
# Output (stdout), one block per run:
#   rows    PLATFORM<TAB>title<TAB>ends=..<TAB>prize=..<TAB>kyc=..<TAB>status=..<TAB>url=..
#   STATUS  STATUS<TAB>PLATFORM<TAB>ok|fetch-failed|parse-failed|unsupported<TAB>live=N<TAB>items=N[...]
#           exactly one per platform, on every run, including runs with 0 live contests
#   RUN     RUN<TAB><utc-iso><TAB>platforms=N<TAB>ok=N<TAB>cb_spent=N   (last line)
#   If the agent did not finish (agentis missing, non-zero exit, timeout, no RUN line) the only line is
#   STATUS<TAB>ALL<TAB>agent-failed<TAB>reason=...<TAB>at=<utc-iso>, and the run log is kept at
#   ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/contest-finder-last-failure.log. A run never prints nothing.
#
# Scheduling is operator-side, for example:
#   0 */6 * * * PATH=<agentis install dir>:/usr/bin:/bin <checkout>/dark-factory/find-live-contests.sh \
#       >> ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/live-contests.log 2>&1
#   Cron's default PATH lacks the agentis install dir; that case prints the agent-failed line.
#
# Env: AGENTIS (agentis binary; default `command -v agentis`), DARK_FACTORY_DIR (failure-log dir),
#      CONTEST_FINDER_AG (test-only: run this agent file instead of the in-repo one).
# Requires: agentis >= 1.29.0 (`exec argv`), curl for live fetches, coreutils `timeout`.
# Read-only: unauthenticated GETs only, no ledger, no queue.
# Exit: 0 = the agent finished (per-platform failures are reported in STATUS lines), 2 = usage error,
#       3 = the agent did not finish.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
AG="${CONTEST_FINDER_AG:-$HERE/auditor/agents/contest-finder.ag}"
DFDIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"
# Slow but answering endpoints take at most 2 walked platforms x 20 pages x 30 s + 3 x 30 s = 1290 s; 1800 s
# leaves a 510 s margin and stays far below the 6 h cadence, so scheduled runs cannot overlap.
GLOBAL_TIMEOUT_S=1800

usage() {
  while IFS= read -r line; do
    case "$line" in
      '#!'*) continue ;;
      '#'*) printf '%s\n' "${line#\#}" ;;
      *) break ;;
    esac
  done < "$0"
}

die_usage() { echo "find-live-contests.sh: $*" >&2; exit 2; }
nv() { [ "$1" -ge 2 ] || die_usage "$2 requires a value"; }

NOW="" ; IMMUNEFI_URL="" ; CODEHAWKS_URL="" ; SHERLOCK_URL="" ; CANTINA_URL="" ; CODE4RENA_URL=""
# Offline files: one newline-separated list per platform (paths may contain spaces).
IMMUNEFI_FILES="" ; CODEHAWKS_FILES="" ; SHERLOCK_FILES="" ; CANTINA_FILES="" ; CODE4RENA_FILES=""
add_file() {
  [ -f "$2" ] && [ -r "$2" ] || die_usage "$1: cannot read $2"
  printf '%s\n%s' "$3" "$2"
}
single() {
  [ -z "$2" ] || die_usage "$1 is not repeatable"
}
while [ $# -gt 0 ]; do case "$1" in
  -h|--help) usage; exit 0 ;;
  --now) nv "$#" "$1"
    case "$2" in ''|*[!0-9]*) die_usage "--now wants epoch seconds, got: $2" ;; esac
    NOW="$2"; shift 2 ;;
  --immunefi-from)  nv "$#" "$1"; single "$1" "$IMMUNEFI_FILES";  IMMUNEFI_FILES="$(add_file "$1" "$2" "$IMMUNEFI_FILES")" || exit 2; shift 2 ;;
  --codehawks-from) nv "$#" "$1"; single "$1" "$CODEHAWKS_FILES"; CODEHAWKS_FILES="$(add_file "$1" "$2" "$CODEHAWKS_FILES")" || exit 2; shift 2 ;;
  --cantina-from)   nv "$#" "$1"; single "$1" "$CANTINA_FILES";   CANTINA_FILES="$(add_file "$1" "$2" "$CANTINA_FILES")" || exit 2; shift 2 ;;
  --sherlock-from)  nv "$#" "$1"; SHERLOCK_FILES="$(add_file "$1" "$2" "$SHERLOCK_FILES")" || exit 2; shift 2 ;;
  --code4rena-from) nv "$#" "$1"; CODE4RENA_FILES="$(add_file "$1" "$2" "$CODE4RENA_FILES")" || exit 2; shift 2 ;;
  --immunefi-url)   nv "$#" "$1"; IMMUNEFI_URL="$2"; shift 2 ;;
  --codehawks-url)  nv "$#" "$1"; CODEHAWKS_URL="$2"; shift 2 ;;
  --sherlock-url)   nv "$#" "$1"; SHERLOCK_URL="$2"; shift 2 ;;
  --cantina-url)    nv "$#" "$1"; CANTINA_URL="$2"; shift 2 ;;
  --code4rena-url)  nv "$#" "$1"; CODE4RENA_URL="$2"; shift 2 ;;
  *) die_usage "unknown argument: $1 (see -h)" ;;
esac; done

RUN="$(mktemp -d "${TMPDIR:-/tmp}/contest-finder.XXXXXX")" || { echo "find-live-contests.sh: mktemp failed" >&2; exit 3; }
trap 'rm -rf "$RUN"' EXIT
LOG="$RUN/run.log"
: > "$LOG"

agent_failed() {
  printf 'STATUS\tALL\tagent-failed\treason=%s\tat=%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if mkdir -p "$DFDIR" 2>/dev/null; then cp "$LOG" "$DFDIR/contest-finder-last-failure.log" 2>/dev/null || true; fi
  exit 3
}

[ -n "${AGENTIS:-}" ] || AGENTIS="$(command -v agentis 2>/dev/null || true)"
[ -n "$AGENTIS" ] && [ -x "$AGENTIS" ] || agent_failed "agentis-not-found"
[ -r "$AG" ] || agent_failed "agent-file-missing"

( cd "$RUN" && "$AGENTIS" init ) >>"$LOG" 2>&1 || agent_failed "init-failed"
SANDBOX="$RUN/.agentis/sandbox"
mkdir -p "$SANDBOX" || agent_failed "init-failed"
# getenv() in the agent sees only allowlisted variables; this line lists every CF_* the agent reads.
{
  echo "llm.backend = mock"
  echo "exec.env_passthrough = CF_NOW_EPOCH,CF_IMMUNEFI_FROM,CF_CODEHAWKS_FROM,CF_SHERLOCK_FROM,CF_CANTINA_FROM,CF_CODE4RENA_FROM,CF_IMMUNEFI_URL,CF_CODEHAWKS_URL,CF_SHERLOCK_URL,CF_CANTINA_URL,CF_CODE4RENA_URL"
} >> "$RUN/.agentis/config"
cp "$AG" "$RUN/contest-finder.ag" || agent_failed "agent-file-missing"

# Copy a platform's offline files into the sandbox as <platform>-<k>.json; prints the page count ("" = live).
stage() {
  k=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    k=$((k + 1))
    cp "$f" "$SANDBOX/$1-$k.json" || return 1
  done <<EOF
$2
EOF
  [ "$k" -gt 0 ] && echo "$k"
  return 0
}
CF_IMMUNEFI_FROM="$(stage immunefi "$IMMUNEFI_FILES")" || agent_failed "stage-failed"
CF_CODEHAWKS_FROM="$(stage codehawks "$CODEHAWKS_FILES")" || agent_failed "stage-failed"
CF_SHERLOCK_FROM="$(stage sherlock "$SHERLOCK_FILES")" || agent_failed "stage-failed"
CF_CANTINA_FROM="$(stage cantina "$CANTINA_FILES")" || agent_failed "stage-failed"
CF_CODE4RENA_FROM="$(stage code4rena "$CODE4RENA_FILES")" || agent_failed "stage-failed"
export CF_NOW_EPOCH="$NOW" CF_IMMUNEFI_FROM CF_CODEHAWKS_FROM CF_SHERLOCK_FROM CF_CANTINA_FROM CF_CODE4RENA_FROM
export CF_IMMUNEFI_URL="$IMMUNEFI_URL" CF_CODEHAWKS_URL="$CODEHAWKS_URL" CF_SHERLOCK_URL="$SHERLOCK_URL" \
       CF_CANTINA_URL="$CANTINA_URL" CF_CODE4RENA_URL="$CODE4RENA_URL"

( cd "$RUN" && timeout "$GLOBAL_TIMEOUT_S" "$AGENTIS" go contest-finder.ag --enable-exec ) >>"$LOG" 2>&1  # no-pii: contest-finder.ag makes no prompt() call
rc=$?
[ "$rc" -eq 124 ] && agent_failed "timeout-${GLOBAL_TIMEOUT_S}s"
[ "$rc" -eq 0 ] || agent_failed "exit-$rc"
OUT="$SANDBOX/out.tsv"
[ -s "$OUT" ] || agent_failed "no-output"
case "$(tail -n 1 "$OUT")" in
  RUN*) ;;
  *) agent_failed "no-run-line" ;;
esac
cat "$OUT"
exit 0
