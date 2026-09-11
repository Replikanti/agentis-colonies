#!/bin/sh
# agentis-stub.sh — the ONE offline `--agentis` stub for the #2191 INTEGRATION_LENS A/B self-test. It stands in
# for every substrate call the run-zone-hunt.sh chain makes (hunter.ag / refuter.ag / coordinator.ag +
# `memo get`). Deterministic, no LLM / forge / network. It encodes the #2191 toggle behaviour:
#   - breadth (hunter.ag): the value-custody C2 cell emits the INTEGRATION-LENS| sentinel AND a breadth
#     CANDIDATE at Vault.sol:deposit ONLY when INTEGRATION_LENS != "0" (the directive fired). With
#     INTEGRATION_LENS=0 it emits a bare SAFE (the OFF/control arm), so the pre-refute discovery merge carries
#     NO candidate and generation-recall scores the rare truth row a MISS. That models the #2191 directive
#     changing WHETHER the assumption is named -- which is exactly the GENERATION-recall delta this A/B measures.
#   - refuter.ag / coordinator.ag: minimal REAL/PASS stubs so the breadth+verify pass completes end to end.
# The metric this A/B headlines is GENERATION-recall (pre-refute candidates via generation-recall.sh), so the
# ONLY thing that matters here is whether the breadth CANDIDATE that names the bug EXISTS in each arm.
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
        if [ "$s" = "value vault" ] && [ "$c" = "C2" ]; then
          # #2191 toggle: emit the INTEGRATION-LENS| sentinel + the external-integration CANDIDATE ONLY when the
          # directive is ON. The candidate's location is Vault.sol:deposit, matching the rare truth row S-IL1.
          if [ "${INTEGRATION_LENS:-1}" != "0" ]; then
            echo "INTEGRATION-LENS|value vault|C2|2"
            echo "CANDIDATE|src/Vault.sol:deposit:22|C2|High|a manipulated external oracle price or imbalanced pool return over-mints shares|deploy the vault with a hostile oracle, deposit, and assert over-minted shares drain vault value"
            exit 0
          fi
        fi
        # OFF/control arm (or any other cell): a bare SAFE, so no breadth candidate reaches the discovery merge.
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
