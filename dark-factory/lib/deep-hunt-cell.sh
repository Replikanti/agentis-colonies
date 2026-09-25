#!/usr/bin/env bash
# dark-factory/lib/deep-hunt-cell.sh — the deep-hunt TIME-BUDGET cell shim + worker (#2258). Two roles:
#
# 1. The $INVHUNT STAND-IN inside run-zone-hunt.sh's STAGE 4.5 loop while the scheduler (lib/deep-hunt-sched.sh) is
#    active. It is invoked with the loop's exact engine argv:
#      DH_MODE=enqueue  write that argv NUL-separated to $DH_STATE/argv/$DH_CUR_SEQ and exit 1, so the loop's own
#                       `|| continue` skips the row's post-processing (the cell has not run yet);
#      DH_MODE=collect  exit 0 at once, so the loop post-processes the cell the worker already ran.
#
# 2. The WORKER, launched in the background by the scheduler:
#      deep-hunt-cell.sh --worker <seq> <cap-s> [<cap-kind cell|zone>]
#    It holds one slot of the dedicated dark-factory LLM-session pool for the cell's lifetime, runs the REAL engine
#    ($DH_ENGINE) with the recorded argv under lib/cell-watchdog.sh (staleness bound on the live path, 0 on the
#    --handler-fixture path — the legacy wrapping; plus the wall cap <cap-s>, 0 = none), classifies the outcome and
#    writes `$DH_STATE/rc/<seq>` (rc \t status \t reason \t target_broken \t broken_loc; `-` for an empty field).
#    TERM is forwarded to the watchdog, which kills the engine group, so a stopped run leaves no orphan engine.
#
# Environment (exported by dh_sched_init): DH_STATE DH_ENGINE DH_STALE DH_POLL DH_SKIP [DH_LLM_SLOTS_DIR].
set -u

DH_HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" != "--worker" ]; then
  case "${DH_MODE:-}" in
    enqueue)
      [ -n "${DH_STATE:-}" ] && [ -n "${DH_CUR_SEQ:-}" ] || { echo "deep-hunt-cell.sh: DH_STATE/DH_CUR_SEQ unset" >&2; exit 2; }
      printf '%s\0' "$@" > "$DH_STATE/argv/$DH_CUR_SEQ" || { echo "deep-hunt-cell.sh: cannot record $DH_STATE/argv/$DH_CUR_SEQ" >&2; exit 2; }
      exit 1 ;;
    collect) exit 0 ;;
    *) echo "deep-hunt-cell.sh: called outside a deep-hunt scheduler pass (DH_MODE unset) (#2258)" >&2; exit 2 ;;
  esac
fi

SEQ="${2:?deep-hunt-cell.sh --worker: <seq> required}"
CAP="${3:-0}"
CAP_KIND="${4:-cell}"
case "$CAP" in ''|*[!0-9]*) CAP=0 ;; esac
: "${DH_STATE:?deep-hunt-cell.sh: DH_STATE unset}" "${DH_ENGINE:?deep-hunt-cell.sh: DH_ENGINE unset}"

# shellcheck source=deep-hunt-sched.sh
. "$DH_HERE/deep-hunt-sched.sh"

META="$DH_STATE/meta/$SEQ"
DZOUT="$(sed -n 6p "$META" 2>/dev/null)"
ARGV=()
while IFS= read -r -d '' _a; do ARGV+=("$_a"); done < "$DH_STATE/argv/$SEQ"

write_rc() {  # rc status reason broken loc
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:--}" "${4:-0}" "${5:--}" > "$DH_STATE/rc/$SEQ.tmp" \
    && mv "$DH_STATE/rc/$SEQ.tmp" "$DH_STATE/rc/$SEQ"
}

if [ -z "$DZOUT" ] || [ "${#ARGV[@]}" -eq 0 ]; then
  echo "deep-hunt-cell.sh: queue entry $SEQ has no run dir / argv under $DH_STATE" >&2
  write_rc 2 ENGINE_FAILED no-queue-entry 0 -
  exit 2
fi

# Staleness bound: the live path gets DEEP_CELL_STALE_S, the offline --handler-fixture path 0 (it was never wrapped).
STALE="${DH_STALE:-0}"
for _a in "${ARGV[@]}"; do [ "$_a" = "--handler-fixture" ] && STALE=0; done
EXTRA=()
[ "${DH_SKIP:-0}" = 1 ] && EXTRA+=(--forge-diag)

_w_child=""
_w_term() {
  if [ -n "$_w_child" ]; then
    kill -TERM "$_w_child" 2>/dev/null || true
    wait "$_w_child" 2>/dev/null || true
  fi
  exit 143
}
trap _w_term TERM

_w_t0="$(date +%s)"
"$DH_HERE/cell-watchdog.sh" "$DZOUT" "$STALE" "${DH_POLL:-45}" "$CAP" -- \
  "$DH_ENGINE" "${ARGV[@]}" ${EXTRA[@]+"${EXTRA[@]}"} &
_w_child=$!
RC=0
wait "$_w_child" || RC=$?
_w_child=""
printf '%s\t%s\t%s\t%s\n' "$SEQ" "$_w_t0" "$(date +%s)" "$RC" >> "$DH_STATE/timing.tsv" 2>/dev/null || true

VERDICT="$(dh_agg_verdict "$DZOUT")"
REASON="-"
COLLECT_RC="$RC"
if [ "$RC" -eq 124 ]; then
  if [ -n "$VERDICT" ]; then
    STATUS="$VERDICT"; REASON=tail-killed; COLLECT_RC=0
  else
    STATUS=TIMEOUT
    if [ "$CAP_KIND" = zone ]; then REASON=zone-budget; else REASON="cell-timeout=${CAP}s"; fi
    # Diagnostic only: the per-candidate verdicts a killed ensemble cell had already produced.
    _w_cands=""
    for _c in "$DZOUT"/run/invariant_*_c[0-9]*.log; do
      [ -e "$_c" ] || continue
      _cv="$(grep 'INVARIANT|' "$_c" 2>/dev/null | tail -1 | sed 's/.*INVARIANT|//' | cut -d'|' -f2 | tr -d '[:space:]')"
      _cn="$(basename "$_c" .log)"; _cn="${_cn##*_}"
      _w_cands="${_w_cands:+$_w_cands,}$_cn:${_cv:-none}"
    done
    [ -z "$_w_cands" ] || REASON="$REASON candidates=$_w_cands"
  fi
elif [ "$RC" -eq 0 ]; then
  case "$VERDICT" in
    FINDING|CLEAN|HARNESS_ERROR|TRANSIENT_ERROR|LOW_COVERAGE|LOW_PROMISE_COVERAGE) STATUS="$VERDICT" ;;
    *) STATUS=HARNESS_ERROR ;;
  esac
elif [ "$RC" -eq 143 ] || [ "$RC" -eq 137 ]; then
  STATUS=ENGINE_FAILED; REASON=stale-watchdog
else
  STATUS=ENGINE_FAILED; REASON="rc=$RC"
fi

BROKEN=0; BLOC="-"
if [ "${DH_SKIP:-0}" = 1 ] && [ "$STATUS" != TIMEOUT ]; then
  IFS='	' read -r BROKEN BLOC <<EOF
$(dh_target_broken "$DZOUT")
EOF
  [ -n "${BLOC:-}" ] || BLOC="-"
fi

write_rc "$COLLECT_RC" "$STATUS" "$REASON" "${BROKEN:-0}" "$BLOC"
exit 0
