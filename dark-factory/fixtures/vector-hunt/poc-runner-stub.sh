#!/bin/sh
# poc-runner-stub.sh — deterministic offline replacement for run-poc.sh, wired through run-vector-hunt.sh's
# --poc-runner seam. NO agentis, NO forge, NO network. It emits the same `POC|<target>|<verdict>` contract
# run-vector-hunt.sh parses: a PoC-PASS (FINDING) for exactly the reentrant executeDeposit vector, CLEAN for
# every other enumerated vector. Verdict is keyed off the --hypothesis text the engine templates from the
# CALLEE-VECTOR (a fixture may match a known token; the ENGINE never does).
set -u
target=""
hyp=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) target="${2:-}"; shift 2 ;;
    --hypothesis) hyp="${2:-}"; shift 2 ;;
    --repo|--class|--backend|--model|--out|--agentis) shift 2 ;;
    *) shift ;;
  esac
done
case "$hyp" in
  *executeDeposit*) echo "POC|$target|FINDING" ;;
  *) echo "POC|$target|CLEAN" ;;
esac
exit 0
