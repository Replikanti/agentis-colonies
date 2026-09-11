#!/bin/sh
# poc-runner-stub.sh — deterministic offline replacement for run-poc.sh, wired through run-vector-hunt.sh's
# --poc-runner seam. NO agentis, NO forge, NO network. It emits the same `POC|<target>|<verdict>` contract
# run-vector-hunt.sh parses: a PoC-PASS (FINDING) for exactly the reentrant executeDeposit vector, CLEAN for
# every other enumerated vector. Verdict is keyed off the --hypothesis text the engine templates from the
# CALLEE-VECTOR (a fixture may match a known token; the ENGINE never does).
#
# #2178: a `__timeout__` hypothesis token drives a TIMEOUT verdict UNTIL the escalated --cli-timeout-ms ceiling
# reaches DF_STUB_TIMEOUT_CLEARS_AT_MS (default: never — stays TIMEOUT so the RUNAWAY guard is exercised). Every
# invocation APPENDS the received --cli-timeout-ms to <out>/cli-timeout.seen, so the demo can assert the
# escalation actually raised the ceiling monotonically. The default (no `__timeout__`) path is byte-identical to
# pre-#2178: existing goldens are unaffected.
set -u
target=""
hyp=""
out=""
cli_timeout=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) target="${2:-}"; shift 2 ;;
    --hypothesis) hyp="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --cli-timeout-ms) cli_timeout="${2:-}"; shift 2 ;;
    --repo|--class|--backend|--model|--agentis|--callee-expr|--callee-hazard) shift 2 ;;
    *) shift ;;
  esac
done

# #2178: record the escalation trail (one ceiling per invocation) so the demo can prove a monotone raise.
if [ -n "$out" ] && [ -n "$cli_timeout" ]; then
  mkdir -p "$out"
  printf '%s\n' "$cli_timeout" >> "$out/cli-timeout.seen"
fi

case "$hyp" in
  *__timeout__*)
    # A size-timeout: stays TIMEOUT unless the escalated ceiling reaches the clear-at threshold (default: never,
    # so the bounded escalation stops with a terminal TIMEOUT — the RUNAWAY guard).
    clears_at="${DF_STUB_TIMEOUT_CLEARS_AT_MS:-0}"
    if [ "$clears_at" -gt 0 ] && [ -n "$cli_timeout" ] && [ "$cli_timeout" -ge "$clears_at" ]; then
      echo "POC|$target|CLEAN"
    else
      echo "POC|$target|TIMEOUT"
    fi
    ;;
  *executeDeposit*) echo "POC|$target|FINDING" ;;
  *) echo "POC|$target|CLEAN" ;;
esac
exit 0
