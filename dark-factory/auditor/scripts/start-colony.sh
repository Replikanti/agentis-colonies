#!/bin/bash
# Start the Auditor colony (part of the Dark Factory federation).
#
# Usage:
#   ./scripts/start-colony.sh [path/to/colony.toml]
#
# The auditor is a one-shot `agentis go` audit pipeline (reconn -> guard ->
# tracker -> synthesis), NOT a long-lived daemon. This launcher resolves the
# colony directory and execs the pipeline in the hardened sandbox. It does not
# launch `agentis daemon`, so there are no daemon flags to allowlist.
#
# Audit inputs are passed via the environment (all optional; see
# config/colony.example.toml [audit] and the colony README):
#   SOLANA_HARNESS_DIR  warm offline solana-program-test harness (real SVM)
#   BOUNTY_TARGET       in-scope program to audit (default: embedded vault)
#   BOUNTY_POC          human-supplied PoC candidate (gated by assess)
#   BOUNTY_SNAPSHOT     host-side RPC account dump, replayed offline
#
# Exit codes: 0 ok, 2 unknown flag, 1 missing agent file / missing agentis.

set -euo pipefail

POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            echo "start-colony.sh: unknown flag: $1" >&2
            exit 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
if [ ${#POSITIONAL[@]} -gt 0 ]; then
    set -- "${POSITIONAL[@]}"
else
    set --
fi

# Symlink-safe $0 resolution.
SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
COLONY_DIR="$(dirname "$SCRIPT_DIR")"

# #2119: wide flat-cyborg PTY by default for every flat-cyborg config emission (see the helper header).
# shellcheck source=../../lib/flat-cyborg-env.sh
# shellcheck disable=SC1091
. "$COLONY_DIR/../lib/flat-cyborg-env.sh"

# Positional config-path arg is accepted for symmetry with other colonies and
# to let operators document a non-default config; the one-shot pipeline reads
# its inputs from the environment, not the TOML, so the path is informational.
CONFIG="${1:-$COLONY_DIR/config/colony.toml}"
if [ ! -f "$CONFIG" ]; then
    echo "Note: config not found ($CONFIG) — running with environment inputs only." >&2
    echo "      Copy config/colony.example.toml to config/colony.toml to silence this." >&2
fi

AGENT_FILE="$COLONY_DIR/agents/auditor.ag"
if [ ! -f "$AGENT_FILE" ]; then
    echo "start-colony.sh: agent file not found: $AGENT_FILE" >&2
    exit 1
fi

if ! command -v agentis >/dev/null 2>&1; then
    echo "start-colony.sh: agentis not found on PATH — install it before running an audit." >&2
    exit 1
fi

echo "Starting auditor pipeline: agentis go $AGENT_FILE (hardened sandbox, offline)"
# --grant-pii: the real target's contract source (reached via env) can embed addresses/identifiers
# that trip the PII heuristic; input is benign public contract text (#1690).
exec agentis go "$AGENT_FILE" \
    --enable-exec \
    --enable-messaging \
    --grant-pii \
    --sandbox-profile hardened
