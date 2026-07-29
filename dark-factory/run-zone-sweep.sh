#!/usr/bin/env bash
# run-zone-sweep.sh — #1828 (M3). THE SELF-TUNING-BREADTH ENTRYPOINT: one operator command that runs a zone
# hunt and then CLOSES ITS OWN COVERAGE GAPS, with no operator step anywhere in the loop.
#
# It is a THIN layer ABOVE run-zone-hunt.sh and MODIFIES NOTHING below it:
#   run-zone-hunt.sh (breadth)  ->  lib/gap-policy.py decide  ->  run-zone-hunt.sh --rehunt-gaps  ->  ... -> report
# Every ingredient except the decision was shipped by #1830 (the coverage record, `gaps`, `--rehunt-gaps`,
# `--rehunt-max-attempts`, the union-across-attempts merge). This script adds the LOOP and the REPORT; the
# rule it asks lives in lib/gap-policy.py. run-zone-hunt.sh stays the single-pass, tactical entrypoint and is
# byte-identical to before this issue — a file that is not touched cannot regress its golden pin.
#
# THE TWO BOUNDS (both load-bearing; neither may be removed):
#   1. --max-rehunt-passes (default 2). The record's own `--rehunt-max-attempts` ceiling bounds only the
#      ARTIFACT-BEARING statuses: `attempts[]` is appended by `zone-coverage.py retry`, which run-zone-hunt.sh
#      calls only on the `retry` action, so a zone DENIED ON ADMISSION (`budget_exhausted`) never gains an
#      attempt entry and `gaps --max-attempts N` keeps emitting `hunt` for it forever. A loop bounded by the
#      record alone would SPIN on exactly the case this issue exists to close.
#   2. The NO-PROGRESS guard inside gap-policy.py: a plain re-hunt that closed nothing provably repeats, so the
#      rule escalates to the budget branch or gives up instead of re-issuing the identical pass.
#
# BUDGETS. --budget-ceiling defaults to 0 = NO RAISE PERMITTED, so `raise_budget_and_rehunt` is unreachable
# unless the operator authorizes a ceiling; a raise then goes STRAIGHT to that ceiling, which makes at most ONE
# raise per sweep possible.
#
# WHAT IT NEVER DOES. It never re-runs STAGE 1/2: `remap_target` is a REPORTED decision, not an action, because
# a re-map invalidates the briefs and the very record the policy is reasoning over. It adds ZERO egress — every
# finding still halts at run-audit-pass.sh's PENDING-HUMAN-REVIEW and deliver-submission.sh's marker refuse.
#
# Usage:
#   run-zone-sweep.sh --repo <dir> [--out <dir>] [options] [-- <run-zone-hunt.sh flags ...>]
#
# Options:
#   --repo <dir>               Cloned target repo root. REQUIRED (forwarded to run-zone-hunt.sh).
#   --out <dir>                Output dir for the whole sweep (default: ./zone-hunt-out). Forwarded.
#   --max-rehunt-passes <N>    Max RE-HUNT passes after the breadth pass (default 2; 0 = breadth only, which
#                              makes the sweep byte-equivalent to a plain run-zone-hunt.sh invocation).
#   --rehunt-max-attempts <N>  Per-zone attempt ceiling handed to BOTH the policy and the runner (default 2).
#   --rehunt-include-partial   Also act on PARTIAL zones (hunted_degraded / budget_truncated). Default off.
#   --budget-ceiling <N>       Max run cell budget the sweep may raise itself to (default 0 = never).
#   -h, --help                 This help.
#   --                         Everything after it is forwarded VERBATIM to every run-zone-hunt.sh invocation.
#
# The passthrough may NOT contain --rehunt-gaps / --rehunt-include-partial / --rehunt-max-attempts (the sweep
# owns the re-entry) or --deep-hunt-only (which is mutually exclusive with a re-hunt): exit 2.
#
# REPORT (written on every exit path ONCE THE SWEEP HAS STARTED, including every abort path — an incomplete
# sweep is never silent. Usage errors (exit 2) and missing-prerequisite errors (exit 3) return before the
# ledger exists: there is no sweep to report on, and no --out to write it to, so they are loud on stderr
# instead. #1849.):
#   <out>/coverage/gap-remediation.json   the ledger: one entry per pass with gaps_before/after + closed
#   <out>/coverage/gap-report.md          the human report: what closed, what remains, and why
#
# Exit: 0 the final coverage record is `complete` ; 2 usage ; 3 missing prerequisite ; 5 gaps remain after the
#       policy exhausted its options (the report is written and named on stderr) ; otherwise the inner
#       run-zone-hunt.sh exit code (an aborted pass is propagated, never masked).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ZONEHUNT="$HERE/run-zone-hunt.sh"
GAPPOLICY="$HERE/lib/gap-policy.py"
REPO="" ; OUT="$PWD/zone-hunt-out"
MAX_REHUNT_PASSES=2 ; REHUNT_MAX_ATTEMPTS=2 ; REHUNT_INCLUDE_PARTIAL=0 ; BUDGET_CEILING=0
PASSTHRU=()

nv() { [ "$1" -ge 2 ] || { echo "run-zone-sweep.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)                   nv "$#"; REPO="$2"; shift 2 ;;
    --out)                    nv "$#"; OUT="$2"; shift 2 ;;
    --max-rehunt-passes)      nv "$#"; MAX_REHUNT_PASSES="$2"; shift 2 ;;
    --rehunt-max-attempts)    nv "$#"; REHUNT_MAX_ATTEMPTS="$2"; shift 2 ;;
    --rehunt-include-partial) REHUNT_INCLUDE_PARTIAL=1; shift ;;
    --budget-ceiling)         nv "$#"; BUDGET_CEILING="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do PASSTHRU+=("$1"); shift; done ;;
    *) echo "run-zone-sweep.sh: unknown flag $1 (run-zone-hunt.sh flags go after --)" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "run-zone-sweep.sh: --repo <cloned repo dir> required (clone it with fetch-target.sh)" >&2; exit 2; }
case "$MAX_REHUNT_PASSES" in ''|*[!0-9]*) echo "run-zone-sweep.sh: --max-rehunt-passes must be a non-negative integer (got '$MAX_REHUNT_PASSES')" >&2; exit 2 ;; esac
case "$REHUNT_MAX_ATTEMPTS" in ''|*[!0-9]*) echo "run-zone-sweep.sh: --rehunt-max-attempts must be a positive integer (got '$REHUNT_MAX_ATTEMPTS')" >&2; exit 2 ;; esac
case "$BUDGET_CEILING" in ''|*[!0-9]*) echo "run-zone-sweep.sh: --budget-ceiling must be a non-negative integer (got '$BUDGET_CEILING')" >&2; exit 2 ;; esac
[ "$REHUNT_MAX_ATTEMPTS" -ge 1 ] || { echo "run-zone-sweep.sh: --rehunt-max-attempts must be >= 1 (got '$REHUNT_MAX_ATTEMPTS')" >&2; exit 2; }
# The sweep OWNS the re-entry: letting a passthrough set it too would make the loop's bound ambiguous (whose
# --rehunt-max-attempts wins?) and would let pass 1 itself be a re-hunt, which the ledger's pass 1 is not.
for _arg in ${PASSTHRU+"${PASSTHRU[@]}"}; do
  case "$_arg" in
    --rehunt-gaps|--rehunt-include-partial|--rehunt-max-attempts)
      echo "run-zone-sweep.sh: $_arg is owned by the sweep and must not be passed through (use the sweep's own flag)" >&2; exit 2 ;;
    --deep-hunt-only)
      echo "run-zone-sweep.sh: --deep-hunt-only cannot be passed through (it is mutually exclusive with a re-hunt)" >&2; exit 2 ;;
  esac
done

[ -x "$ZONEHUNT" ] || { echo "run-zone-sweep.sh: required entrypoint not found/executable: $ZONEHUNT" >&2; exit 3; }
[ -f "$GAPPOLICY" ] || { echo "run-zone-sweep.sh: required helper not found: $GAPPOLICY" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "run-zone-sweep.sh: python3 not installed" >&2; exit 3; }

REPO="$(cd "$REPO" && pwd)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
# The coverage record's path is a CONTRACT (#1830, no flag); the ledger and the report are its siblings.
COVERAGE_DIR="$OUT/coverage"
COVERAGE_JSON="$COVERAGE_DIR/zone-coverage.json"
LEDGER="$COVERAGE_DIR/gap-remediation.json"
REPORT="$COVERAGE_DIR/gap-report.md"
mkdir -p "$COVERAGE_DIR"

TERMINAL_REASON="unset"

# ----------------------------------------------------------------------------------------------------------
# The report is written on every exit path from HERE ON — including every abort path — so an incomplete sweep
# is never silent. It is a trap, not a call site, precisely because the interesting exits are the unhappy ones.
#
# The boundary is deliberate and is the whole content of #1849: the argument and prerequisite checks above
# return BEFORE this point, and they have nothing to report — the ledger does not exist yet, and a usage error
# may not even carry an --out to write into. `finish` degrades to a no-op in that state anyway (it is gated on
# `[ -f "$LEDGER" ]`), so moving the trap up would buy a silent no-op rather than a report. Those paths stay
# loud on stderr instead. Everything after this line, including a mid-sweep abort, produces the report.
# ----------------------------------------------------------------------------------------------------------
finish() {
  fin_rc=$?
  trap - EXIT
  if [ -f "$LEDGER" ]; then
    # --coverage is optional on BOTH calls: an aborted breadth pass leaves no record, and the sweep still owes
    # the operator a report saying exactly that.
    if [ -f "$COVERAGE_JSON" ]; then
      python3 "$GAPPOLICY" ledger finish --file "$LEDGER" --terminal-reason "$TERMINAL_REASON" \
        --coverage "$COVERAGE_JSON" >/dev/null 2>&1 || true
      python3 "$GAPPOLICY" report --ledger "$LEDGER" --coverage "$COVERAGE_JSON" \
        --max-attempts "$REHUNT_MAX_ATTEMPTS" > "$REPORT" 2>/dev/null || true
    else
      python3 "$GAPPOLICY" ledger finish --file "$LEDGER" --terminal-reason "$TERMINAL_REASON" \
        >/dev/null 2>&1 || true
      python3 "$GAPPOLICY" report --ledger "$LEDGER" > "$REPORT" 2>/dev/null || true
    fi
  fi
  if [ -f "$REPORT" ]; then
    cat "$REPORT"
    if [ "$fin_rc" -ne 0 ]; then
      echo "run-zone-sweep.sh: gap remediation report: $REPORT (terminal reason: $TERMINAL_REASON)" >&2
    fi
  fi
  exit "$fin_rc"
}
trap finish EXIT

gap_list() {
  # The gap set as the RECORD sees it (`gap_zones`), for the ledger's before/after columns. Deliberately NOT
  # the actionability set: a pass that turns a `budget_exhausted` zone into a `budget_truncated` one closed
  # nothing, and the no-progress guard must be able to see that.
  python3 - "$COVERAGE_JSON" <<'PY'
import sys, json
try:
    rec = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
sys.stdout.write(",".join(rec.get("gap_zones", []) or []))
PY
}
is_complete() {
  python3 - "$COVERAGE_JSON" <<'PY'
import sys, json
try:
    rec = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
sys.exit(0 if rec.get("complete") else 1)
PY
}

# ----------------------------------------------------------------------------------------------------------
# PASS 1 — the ordinary breadth pass. Exit 0 is a clean run; exit 4 is a passthrough --require-coverage halt
# (run-zone-hunt.sh stops BEFORE STAGE 4/5 and the record is already on disk), which is a normal continue for
# the sweep — the whole point is that the gap gets closed. Anything else aborts and is propagated verbatim.
# ----------------------------------------------------------------------------------------------------------
python3 "$GAPPOLICY" ledger init --file "$LEDGER" --coverage "$COVERAGE_JSON" --repo "$(basename "$REPO")"

echo "run-zone-sweep.sh: [pass 1] breadth pass -> $OUT ..." >&2
PASS_RC=0
"$ZONEHUNT" --repo "$REPO" --out "$OUT" ${PASSTHRU+"${PASSTHRU[@]}"} || PASS_RC=$?
if [ "$PASS_RC" -ne 0 ] && [ "$PASS_RC" -ne 4 ]; then
  TERMINAL_REASON="breadth_pass_failed"
  echo "run-zone-sweep.sh: [pass 1] run-zone-hunt.sh exited $PASS_RC — aborting the sweep" >&2
  exit "$PASS_RC"
fi
[ -f "$COVERAGE_JSON" ] || { TERMINAL_REASON="no_coverage_record"; echo "run-zone-sweep.sh: run-zone-hunt.sh produced no $COVERAGE_JSON" >&2; exit 3; }
GAPS_AFTER="$(gap_list)"
python3 "$GAPPOLICY" ledger append --file "$LEDGER" --decision initial --exit-code "$PASS_RC" \
  --gaps-before "" --gaps-after "$GAPS_AFTER" --detail "the breadth pass"

# ----------------------------------------------------------------------------------------------------------
# THE LOOP — at most --max-rehunt-passes iterations, and every iteration is one policy decision followed by at
# most one run-zone-hunt.sh --rehunt-gaps pass. The pass ceiling is enforced HERE as well as inside the rule,
# so neither bound alone is load-bearing (see the header).
# ----------------------------------------------------------------------------------------------------------
RUN_BUDGET_OVERRIDE="" ; ZONE_BUDGET_OVERRIDE=""
# Built once: the sweep's own opinion about partials, in the two vocabularies that need it.
POLICY_PARTIAL=() ; RUNNER_PARTIAL=()
if [ "$REHUNT_INCLUDE_PARTIAL" -eq 1 ]; then
  POLICY_PARTIAL=(--include-partial)
  RUNNER_PARTIAL=(--rehunt-include-partial)
fi
PASSES_DONE=0
while : ; do
  if is_complete; then
    TERMINAL_REASON="complete"
    break
  fi
  if [ "$PASSES_DONE" -ge "$MAX_REHUNT_PASSES" ]; then
    TERMINAL_REASON="pass_ceiling"
    echo "run-zone-sweep.sh: $PASSES_DONE re-hunt pass(es) done, --max-rehunt-passes is $MAX_REHUNT_PASSES — stopping" >&2
    break
  fi
  BUDGET_ARG=()
  [ -z "$RUN_BUDGET_OVERRIDE" ] || BUDGET_ARG=(--run-cell-budget "$RUN_BUDGET_OVERRIDE")
  DECISION="$(python3 "$GAPPOLICY" decide --coverage "$COVERAGE_JSON" --ledger "$LEDGER" \
    --max-passes "$MAX_REHUNT_PASSES" --max-attempts "$REHUNT_MAX_ATTEMPTS" \
    --budget-ceiling "$BUDGET_CEILING" \
    ${BUDGET_ARG+"${BUDGET_ARG[@]}"} ${POLICY_PARTIAL+"${POLICY_PARTIAL[@]}"})"
  VERB="$(printf '%s\n' "$DECISION" | cut -d'|' -f2)"
  DARGS="$(printf '%s\n' "$DECISION" | cut -d'|' -f3)"
  DWHY="$(printf '%s\n' "$DECISION" | cut -d'|' -f4)"
  DREASON="$(printf '%s\n' "$DARGS" | tr ';' '\n' | sed -n 's/^reason=//p')"
  echo "run-zone-sweep.sh: [policy] $VERB ($DARGS) — $DWHY" >&2

  case "$VERB" in
    rehunt_now) : ;;
    raise_budget_and_rehunt)
      RUN_BUDGET_OVERRIDE="$(printf '%s\n' "$DARGS" | tr ';' '\n' | sed -n 's/^run_cell_budget=//p')"
      ZONE_BUDGET_OVERRIDE="$(printf '%s\n' "$DARGS" | tr ';' '\n' | sed -n 's/^zone_cell_budget=//p')"
      ;;
    remap_target|give_up)
      TERMINAL_REASON="${DREASON:-$VERB}"
      break ;;
    *)
      TERMINAL_REASON="unknown_decision"
      echo "run-zone-sweep.sh: gap-policy.py returned an unknown verb '$VERB'" >&2
      exit 3 ;;
  esac

  BUDGET_ARG=()
  [ -z "$RUN_BUDGET_OVERRIDE" ] || BUDGET_ARG=(--run-cell-budget "$RUN_BUDGET_OVERRIDE")
  # `zone_cell_budget=0` means "drop the per-zone cap for this pass" — 0 is meaningful, so the guard is on
  # emptiness, not on the value.
  [ -z "$ZONE_BUDGET_OVERRIDE" ] || BUDGET_ARG+=(--zone-cell-budget "$ZONE_BUDGET_OVERRIDE")
  GAPS_BEFORE="$GAPS_AFTER"
  PASSES_DONE=$((PASSES_DONE + 1))
  echo "run-zone-sweep.sh: [pass $((PASSES_DONE + 1))] $VERB: re-hunting the gap set ..." >&2
  PASS_RC=0
  # The sweep's own flags come AFTER the passthrough so they win (run-zone-hunt.sh's arg loop is last-wins) —
  # that is how a raise overrides a passthrough --run-cell-budget without rewriting the operator's arguments.
  "$ZONEHUNT" --repo "$REPO" --out "$OUT" ${PASSTHRU+"${PASSTHRU[@]}"} \
    --rehunt-gaps --rehunt-max-attempts "$REHUNT_MAX_ATTEMPTS" \
    ${RUNNER_PARTIAL+"${RUNNER_PARTIAL[@]}"} ${BUDGET_ARG+"${BUDGET_ARG[@]}"} \
    || PASS_RC=$?
  GAPS_AFTER="$(gap_list)"
  python3 "$GAPPOLICY" ledger append --file "$LEDGER" --decision "$VERB" --exit-code "$PASS_RC" \
    --gaps-before "$GAPS_BEFORE" --gaps-after "$GAPS_AFTER" \
    ${BUDGET_ARG+"${BUDGET_ARG[@]}"} \
    --detail "$DWHY"
  if [ "$PASS_RC" -ne 0 ] && [ "$PASS_RC" -ne 4 ]; then
    TERMINAL_REASON="rehunt_pass_failed"
    echo "run-zone-sweep.sh: [pass $((PASSES_DONE + 1))] run-zone-hunt.sh --rehunt-gaps exited $PASS_RC — aborting the sweep" >&2
    exit "$PASS_RC"
  fi
done

if is_complete; then
  echo "run-zone-sweep.sh: coverage COMPLETE after $PASSES_DONE re-hunt pass(es)" >&2
  exit 0
fi
echo "run-zone-sweep.sh: coverage INCOMPLETE after $PASSES_DONE re-hunt pass(es) (terminal reason: $TERMINAL_REASON)" >&2
exit 5
