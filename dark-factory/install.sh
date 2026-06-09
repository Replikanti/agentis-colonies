#!/bin/bash
# install.sh: idempotent setup for the dark-factory federation.
#
# dark-factory is an experimental research scaffold: an autonomous
# Solana/Anchor bounty auditor. There are no forge credentials to prompt
# for (`forge.type = "none"`). Install only:
#   1. Copy the auditor colony's colony.example.toml to colony.toml so
#      start-colony.sh has something to read.
#   2. Point the operator at the one-time offline toolchain build.
#
# The audit pipeline runs offline through the real Solana SVM, but the
# ~711-crate dependency graph must be fetched + warm-built ONCE (network
# on). That step is setup-solana-toolchain.sh; it is NOT run here because
# it needs network and produces a ~3 GB target the operator owns.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_NAME="$(basename "$SCRIPT_DIR")"

echo "Installing $FED_NAME federation..."

example="$SCRIPT_DIR/auditor/config/colony.example.toml"
target="$SCRIPT_DIR/auditor/config/colony.toml"
if [ ! -f "$target" ] && [ -f "$example" ]; then
    cp "$example" "$target"
    echo "  copied auditor/config/colony.toml from example"
fi

if command -v agentis >/dev/null 2>&1; then
    echo "  agentis CLI found: $(agentis version 2>/dev/null || echo unknown)"
else
    echo "  agentis CLI not found on PATH — install it before running an audit"
    echo "  (proprietary closed-source binary, free for Linux/macOS: https://github.com/Replikanti/agentis)"
fi

echo
echo "Done."
echo
echo "Next steps:"
echo "  1. (one-time, network ON) build the offline Solana toolchain:"
echo "       bash $FED_NAME/setup-solana-toolchain.sh [WORKDIR]"
echo "     This fetches + warm-builds the harness dependency graph so every"
echo "     subsequent audit compiles + runs the generated PoC fully offline."
echo "  2. run an audit (one-shot pipeline):"
echo "       bash $FED_NAME/auditor/scripts/start-colony.sh"
echo "  3. read $FED_NAME/auditor/README.md for the env contract"
echo "     (SOLANA_HARNESS_DIR / BOUNTY_TARGET / BOUNTY_POC)."
