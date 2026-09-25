#!/bin/sh
# agentis-stub.sh — offline stand-in for `agentis` in the #2262 exam runner self-test (exam.sh self-test hands
# it to run-zone-hunt.sh through the --agentis seam, with --backend mock). No LLM, no network. Dash-safe.
#   hunter.ag   the share-pool zone's C1 cell answers one CANDIDATE at Pool.sol:withdraw; every other cell SAFE.
#   refuter.ag  refutes every candidate, so nothing is verified and the delivery stage has nothing to do.
# Test seams (all unset by default):
#   STUB_ENV_DUMP=<file>  every hunter call appends its full environment, then a `--` line, to <file> (the
#                         knob-hygiene assertions read it).
#   STUB_SLEEP=<s>        every hunter call sleeps <s> seconds first (the hard-stop case: HARD_STOP_S < <s>).
set -u
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  memo) exit 0 ;;
  go)
    case "${2:-}" in
      hunter.ag)
        if [ -n "${STUB_ENV_DUMP:-}" ]; then
          env >> "$STUB_ENV_DUMP"
          echo "--" >> "$STUB_ENV_DUMP"
        fi
        if [ -n "${STUB_SLEEP:-}" ]; then sleep "$STUB_SLEEP"; fi
        if [ "${SUBSYSTEM:-}" = "share pool" ] && [ "${HUNT_CLASS:-}" = "C1" ]; then
          echo "CANDIDATE|src/pool/Pool.sol:withdraw:17|C1|High|withdraw prices the exit before the share burn|skew the ratio, then withdraw"
        else
          echo "SAFE"
        fi
        exit 0 ;;
      refuter.ag)
        echo "VERDICT|REFUTED|${CAND_FILE_FN:-}|${CAND_CLASS:-}|stub refuter: refutes every candidate"
        exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
