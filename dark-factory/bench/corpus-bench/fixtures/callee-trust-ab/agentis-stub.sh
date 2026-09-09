#!/bin/sh
# agentis-stub.sh — the ONE offline `--agentis` stub for the #2157 CALLEE-TRUST A/B self-test. It stands in for
# every substrate call the run-zone-hunt.sh chain makes (hunter.ag / refuter.ag / coordinator.ag + `memo get`).
# Deterministic, no LLM / forge / network. It encodes the D1 (CALLEE-TRUST) toggle behaviour:
#   - breadth (hunter.ag): the value-custody C6 cell emits a SAFE verdict in BOTH arms, so no breadth CANDIDATE
#     ever reaches verify (verified[] stays empty on the breadth base). ONLY when CALLEE_TRUST != "0" does it
#     ALSO emit the D1 diagnostics — a CALLEE-TRUST| sentinel and a `CALLEE-VECTOR|executeDeposit|...|reentrant`
#     candidate — into the cell log. That models the #2145 directive firing: STAGE 4.6 (--vector-hunt) then
#     harvests that candidate. With CALLEE_TRUST=0 the log carries NO CALLEE-VECTOR line (the OFF/control arm),
#     so even if --vector-hunt were on, the harvest finds nothing.
#   - refuter.ag / coordinator.ag: minimal REAL/PASS stubs so the breadth pass completes end to end.
# The rare finding itself is produced by STAGE 4.6 (run-vector-hunt.sh + the shared poc-runner-stub.sh), NOT
# here — this stub only decides whether the D1 candidate that seeds it EXISTS.
# dash-safe: no arrays, no $'...', literal glyphs only.
set -u
cmd="${1:-}"
sub="${2:-}"
case "$cmd" in
  init) mkdir -p .agentis; exit 0 ;;
  memo)
    if [ "$sub" = "get" ] && [ "${3:-}" = "coordinator:pass_result" ] && [ -f .agentis/pass_result ]; then
      cat .agentis/pass_result
    fi
    exit 0 ;;
  go)
    case "$sub" in
      hunter.ag)
        s="${SUBSYSTEM:-}"; c="${HUNT_CLASS:-}"
        if [ "$s" = "value vault" ] && [ "$c" = "C6" ]; then
          # D1 toggle: emit the CALLEE-TRUST| sentinel + the settable-oracle CALLEE-VECTOR candidate ONLY when
          # the directive is ON. The candidate's <fn> is executeDeposit and the hazard is reentrant, so the
          # shared poc-runner-stub.sh (keyed on the hypothesis text) reproduces exactly that vector as PoC-PASS.
          if [ "${CALLEE_TRUST:-1}" != "0" ]; then
            echo "CALLEE-TRUST|value vault|C6|2|v2"
            echo "CALLEE-VECTOR|executeDeposit|oracle.getPrice()|reentrant|CANDIDATE"
          fi
        fi
        # Breadth verdict is SAFE in both arms: the ONLY verified-findings difference between control and
        # treatment is the STAGE 4.6 vector-hunt merge, never a breadth candidate.
        echo "SAFE"
        exit 0 ;;
      refuter.ag)
        echo "VERDICT|REAL|${CAND_FILE_FN:-}|${CAND_CLASS:-}|survived a hostile read"
        exit 0 ;;
      coordinator.ag)
        loc="${FINDING_LOCATION:-}"
        out="${SUBMISSION_DRAFT_OUT:-}"
        if [ -n "$out" ]; then
          {
            echo "SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW"
            echo "FIELD|title|verified finding at $loc"
            echo "FIELD|severity|${SEVERITY_BAND:-}"
            echo ""
            echo "A human reviews this draft and files it manually. This is never auto-submitted."
          } > "$out"
        fi
        printf '%s' "PENDING-HUMAN-REVIEW" > .agentis/pass_result
        echo "PASS|PENDING-HUMAN-REVIEW"
        exit 0 ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
