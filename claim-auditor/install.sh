#!/bin/bash
# install.sh -- idempotent setup for the claim-auditor federation (#595).
#
# This federation does NOT call any forge API. It needs only:
#   - the agentis runtime,
#   - python3 + curl (for the searcher HTTP fetches),
#   - podman (for the hermetic run dir spawned by tools/run-auditor.sh),
#   - optionally a Claude CLI / OAuth session at $HOME/.claude when the
#     orchestrator runs with AUDITOR_LLM_BACKEND=claude (the default).
#
# install.sh copies each <colony>/config/colony.example.toml to
# colony.toml in place (no env interpolation needed). The runtime
# knobs that actually control a run live in env vars consumed by
# tools/run-auditor.sh; the colony.toml files exist primarily so
# colony-lint passes.
#
# Usage: ./install.sh

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
FED_NAME="$(basename "$SCRIPT_DIR")"

COLONIES=(arxiv-search oeis-search groupprops-search scholar-search auditor)

# --- Helpers ---
info()  { printf '  %s\n' "$*"; }
ok()    { printf '  [ok] %s\n' "$*"; }
fail()  { printf '  [!!] %s\n' "$*"; }

check_cmd() {
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 found ($(command -v "$1"))"
        return 0
    else
        fail "$1 not found"
        return 1
    fi
}

echo ""
echo "Claim Auditor - Federation Setup"
echo "================================"
echo ""
echo "Checking prerequisites..."

MISSING=0
check_cmd agentis || MISSING=1
check_cmd python3 || MISSING=1
check_cmd podman  || MISSING=1
check_cmd curl    || MISSING=1

if [ "$MISSING" -eq 1 ]; then
    echo ""
    fail "Missing prerequisites. Install them and re-run."
    echo ""
    info "agentis: https://github.com/Replikanti/agentis"
    info "podman:  your system package manager (Fedora/RHEL: dnf install podman)"
    exit 1
fi

# Optional: warn if the host operator has not logged into the claude
# CLI yet. The orchestrator bind-mounts $HOME/.claude into the
# container, so a missing credential file there means every prompt()
# returns an authentication error.
if [ -f "$HOME/.claude/.credentials.json" ]; then
    ok "claude CLI credentials present at \$HOME/.claude/.credentials.json"
else
    info "claude CLI credentials NOT found at \$HOME/.claude/.credentials.json"
    info "  (only needed when AUDITOR_LLM_BACKEND=claude, which is the default)"
fi

# --- Config copy ---
echo ""
echo "Copying colony.example.toml -> colony.toml ..."

for colony in "${COLONIES[@]}"; do
    src="$SCRIPT_DIR/$colony/config/colony.example.toml"
    dst="$SCRIPT_DIR/$colony/config/colony.toml"
    if [ ! -f "$src" ]; then
        fail "missing example config: $src"
        exit 1
    fi
    if [ -f "$dst" ]; then
        info "skipped (already present): $colony/config/colony.toml"
    else
        cp "$src" "$dst"
        ok "$colony/config/colony.toml"
    fi
done

# --- Done ---
echo ""
ok "$FED_NAME is ready."
echo ""
info "Next steps:"
info "  1. Point AUDITOR_SOURCE_RUN at a math-foundry run dir, e.g.:"
info "       export AUDITOR_SOURCE_RUN=\$HOME/agentis-colonies/math-foundry/runs/<ts>"
info "  2. Dry-run:"
info "       bash $SCRIPT_DIR/tools/run-auditor.sh --dry-run --source-run \$AUDITOR_SOURCE_RUN"
info "  3. Real run:"
info "       bash $SCRIPT_DIR/tools/run-auditor.sh --source-run \$AUDITOR_SOURCE_RUN"
echo ""
