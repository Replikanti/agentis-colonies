#!/bin/sh
# agentis-stub.sh — the ONE offline `--agentis` stub for the #1713 deep-hunt A/B self-test. It stands in for
# every substrate call the run-zone-hunt.sh chain makes (hunter.ag / refuter.ag / coordinator.ag + `memo get`)
# PLUS the deep-hunt engine's invariant-prover.ag. Deterministic, no LLM / forge / network. It encodes:
#   - breadth (hunter.ag): the value-custody zone surfaces ONE Medium admin-setter lead at
#     src/Vault.sol:setFee -- deliberately NOT the deposit-inflation drain, so the breadth pass MISSES the
#     High truth row (truth.tsv S-D1, keyed on Vault.sol:deposit).
#   - depth (invariant-prover.ag): a canned FINDING whose shrunk STEP| witness leads with deposit(, so the
#     merge adapter resolves location = src/Vault.sol:deposit -> score-match scores it a High HIT.
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
          # a breadth lead on an admin setter -- NOT the deposit-inflation drain (so it MISSES S-D1).
          echo "CANDIDATE|src/Vault.sol:setFee:30|C6|Medium|admin fee setter lead|call setFee with a crafted bps"
        else
          echo "SAFE"
        fi
        exit 0 ;;
      refuter.ag)
        echo "VERDICT|REAL|${CAND_FILE_FN:-}|${CAND_CLASS:-}|survived a hostile read"
        exit 0 ;;
      invariant-prover.ag)
        # the deep engine's contract: exactly one INVARIANT|<file:fn>|<verdict> line, then STEP| witness lines
        # on a FINDING. The multi-step donate/inflation sequence leads with deposit(, so the adapter's
        # "first identifier-before-(" scrape yields `deposit`.
        # #1774: the verdict is parametrized via an inherited DEEP_HUNT_VERDICT (default FINDING => byte-identical
        # to before, the Δ=+1 path). DEEP_HUNT_VERDICT=CLEAN emits a CLEAN verdict with NO witness so STAGE 4.5's
        # adapter merges 0 findings (the deterministic Δ=0 fixture — models the live "lens ran but merged 0" case).
        verd="${DEEP_HUNT_VERDICT:-FINDING}"
        echo "INVARIANT|src/Vault.sol:deposit|$verd"
        if [ "$verd" = "FINDING" ]; then
          echo "STEP|deposit(1)"
          echo "STEP|attackerDonate(1000000000000000000000000)"
          echo "STEP|deposit(1000000000000000000)"
        fi
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
