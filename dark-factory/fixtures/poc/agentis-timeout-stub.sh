#!/bin/sh
# agentis-timeout-stub.sh — a tiny fake `agentis` binary for run-poc.sh's --agentis seam (#2178). It lets the
# TIMEOUT classification be proven in MILLISECONDS with NO real timeout, NO LLM, NO forge: on `go` it prints the
# EXACT terminal `[llm.timeout]` literal agentis-core#996 emits (classify_llm_error() -> exec.rs) to the cell log
# and exits 75 (the LlmTimeout exit code). `init` (and anything else) is a quiet success so run-poc.sh's store
# bootstrap proceeds. run-poc.sh must then classify the run as TIMEOUT (df_llm_timeout_in_log OR exit 75), NOT
# HARNESS_ERROR — the exact split this fixture pins without a multi-minute wait.
set -u
case "${1:-}" in
  go)
    # The terminal marker df_llm_timeout_in_log() anchors on (`[llm.timeout] LLM call timed out`), + exit 75.
    echo "Error: runtime error: [llm.timeout] LLM call timed out after 600s"
    exit 75
    ;;
  init)
    # Mirror `agentis init`: create the store dir run-poc.sh writes .agentis/config into (real init does this;
    # without it run-poc.sh's config redirect fails under set -e before the go call is ever reached).
    mkdir -p .agentis
    exit 0
    ;;
  *)
    # version / any other subcommand: quiet success.
    exit 0
    ;;
esac
