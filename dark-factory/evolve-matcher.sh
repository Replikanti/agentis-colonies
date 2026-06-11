#!/usr/bin/env bash
# #861 M4 — evolve the fuzzy matcher's granularity (shingle-Jaccard threshold × shingle width k)
# against a held-out fork-pair FITNESS ORACLE. Runs pattern-evolver.ag, which searches the genome,
# records each candidate as substrate experience via learn(), and writes the F-beta-max config to
# evolved:fuzzy_threshold / evolved:fuzzy_k. reconn adopts that config on the next audit (run-audit.sh
# --use-evolved). The recall harness IS the fitness function — the granularity tunes itself.
#
# Usage:
#   evolve-matcher.sh --fork-base <base.sol> --fork-fork <fork.sol> --evm-harness <dir> \
#     [--beta 2] [--agentis <bin>] [--out <dir>]
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"; FORK_BASE=""; FORK_FORK=""; EVM_HARNESS=""; OUT="$PWD/evolve-out"; BETA="2"
need() { [ "$1" -ge 2 ] || { echo "evolve-matcher.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --fork-base) need "$#"; FORK_BASE="$2"; shift 2 ;;
    --fork-fork) need "$#"; FORK_FORK="$2"; shift 2 ;;
    --evm-harness) need "$#"; EVM_HARNESS="$2"; shift 2 ;;
    --beta) need "$#"; BETA="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "evolve-matcher.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done
[ -f "$FORK_BASE" ] || { echo "evolve-matcher.sh: --fork-base not found: $FORK_BASE" >&2; exit 2; }
[ -f "$FORK_FORK" ] || { echo "evolve-matcher.sh: --fork-fork not found: $FORK_FORK" >&2; exit 2; }
[ -n "$EVM_HARNESS" ] || { echo "evolve-matcher.sh: --evm-harness <dir> required" >&2; exit 2; }
EVM_HARNESS="$(cd "$EVM_HARNESS" && pwd)"
FORK_BASE="$(cd "$(dirname "$FORK_BASE")" && pwd)/$(basename "$FORK_BASE")"
FORK_FORK="$(cd "$(dirname "$FORK_FORK")" && pwd)/$(basename "$FORK_FORK")"

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"; RUN="$OUT/run"; rm -rf "$RUN"; mkdir -p "$RUN"
cp "$HERE/auditor/agents/pattern-evolver.ag" "$RUN/pattern-evolver.ag"
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "trace.level = normal"
  echo "experience.enabled = true"
  echo "learning.enabled = true"
  echo "exec.env_passthrough = EVM_HARNESS_DIR,FORK_BASE,FORK_FORK,EVOLVE_BETA"
  echo "exec.default_timeout_ms = 60000"
} > "$RUN/.agentis/config"

echo "evolve: searching genome against fork-pair oracle $(basename "$FORK_BASE") -> $(basename "$FORK_FORK") (beta=$BETA) ..." >&2
( cd "$RUN" && env EVM_HARNESS_DIR="$EVM_HARNESS" FORK_BASE="$FORK_BASE" FORK_FORK="$FORK_FORK" EVOLVE_BETA="$BETA" \
    "$AGENTIS" go pattern-evolver.ag --enable-exec ) 2>&1 | grep '^evolve:'

# surface the evolved config from the memo store for the operator / run-audit --use-evolved.
TH="$(cd "$RUN" && "$AGENTIS" memo get evolved:fuzzy_threshold 2>/dev/null || true)"
K="$(cd "$RUN" && "$AGENTIS" memo get evolved:fuzzy_k 2>/dev/null || true)"
echo "evolved-config-dir: $RUN" >&2
[ -n "$TH" ] && echo "evolved: fuzzy_threshold=$TH fuzzy_k=$K" >&2
