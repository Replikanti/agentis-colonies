#!/bin/bash
# install.sh -- idempotent setup for the research-foundry federation (#638).
#
# Consolidates the three retired install scripts (math-foundry,
# claim-auditor, preprint-foundry) into one. This federation does NOT
# call any forge API. It needs:
#   - the agentis runtime,
#   - python3 + curl,
#   - podman (for the hermetic run dir spawned by tools/run-research.sh),
#   - host `pdflatex` / `gap` are nice-to-have for local review
#     (tools/review-cli.sh --show); the container always ships its own
#     TeX Live + GAP copy.
#   - optionally a Claude CLI / OAuth session at $HOME/.claude when the
#     orchestrator runs with RESEARCH_LLM_BACKEND=claude (the default).
#
# install.sh copies each <colony>/config/colony.example.toml to
# colony.toml in place and copies config/authors.toml.example to
# config/authors.toml IF the latter is missing (the operator MUST then
# edit it with real author metadata before the submitter colony will
# produce a valid arxiv-metadata.json).
#
# Usage: ./install.sh

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
FED_NAME="$(basename "$SCRIPT_DIR")"

COLONIES=(
    # Math pipeline.
    explorer
    noticer
    formulator
    verifier
    novelty
    # Claim audit.
    arxiv-search
    oeis-search
    groupprops-search
    scholar-search
    auditor
    # Preprint pipeline.
    introducer
    theorist
    computer
    editor
    submitter
)

# --- Helpers ---
info()  { printf '  %s\n' "$*"; }
ok()    { printf '  [ok] %s\n' "$*"; }
warn()  { printf '  [warn] %s\n' "$*"; }
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

check_cmd_warn() {
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 found ($(command -v "$1"))"
    else
        warn "$1 not found ($2)"
    fi
}

echo ""
echo "Research Foundry - Federation Setup"
echo "==================================="
echo ""
echo "Checking prerequisites..."

MISSING=0
check_cmd agentis || MISSING=1
check_cmd python3 || MISSING=1
check_cmd podman  || MISSING=1
check_cmd curl    || MISSING=1

# Host-side niceties for local review; the container always ships its
# own pdflatex / latexmk / gap.
check_cmd_warn pdflatex "host PDF preview / review-cli --show needs it; container has its own copy"
check_cmd_warn gap "host group-theory reproducibility-script runs need it; container has its own copy"
check_cmd_warn claude "RESEARCH_LLM_BACKEND=claude needs the CLI on the host for credential-volume mount"

if [ "$MISSING" -eq 1 ]; then
    echo ""
    fail "Missing required prerequisites. Install them and re-run."
    echo ""
    info "agentis: https://github.com/Replikanti/agentis"
    info "podman:  your system package manager (Fedora/RHEL: dnf install podman)"
    exit 1
fi

# Optional: warn if the host operator has not logged into the claude
# CLI yet.
if [ -f "$HOME/.claude/.credentials.json" ]; then
    ok "claude CLI credentials present at \$HOME/.claude/.credentials.json"
else
    info "claude CLI credentials NOT found at \$HOME/.claude/.credentials.json"
    info "  (only needed when RESEARCH_LLM_BACKEND=claude, which is the default)"
fi

# --- Per-colony config copy ---
echo ""
echo "Copying colony.example.toml -> colony.toml for 18 colonies ..."

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

# --- Federation-level authors.toml ---
echo ""
echo "Copying config/authors.toml.example -> config/authors.toml ..."
authors_src="$SCRIPT_DIR/config/authors.toml.example"
authors_dst="$SCRIPT_DIR/config/authors.toml"
if [ ! -f "$authors_src" ]; then
    fail "missing example author config: $authors_src"
    exit 1
fi
if [ -f "$authors_dst" ]; then
    info "skipped (already present): config/authors.toml"
else
    cp "$authors_src" "$authors_dst"
    ok "config/authors.toml"
    warn "Edit config/authors.toml with real author metadata BEFORE running run-research.sh."
    warn "arXiv submissions without a verifiable human author will be rejected by moderation."
fi

# --- Done ---
echo ""
ok "$FED_NAME is ready."
echo ""
info "Next steps:"
info "  1. Edit config/authors.toml with real author metadata (name, email, ORCID)."
info "  2. (One-time) populate data/papers/ with cached arXiv corpora:"
info "       python3 $SCRIPT_DIR/tools/fetch-papers.py --help"
info "  3. Dry-run:"
info "       bash $SCRIPT_DIR/tools/run-research.sh --dry-run"
info "  4. Real run (spawns 18 colonies in podman):"
info "       bash $SCRIPT_DIR/tools/run-research.sh"
info "  5. Review DRAFTED preprints and approve/reject via:"
info "       bash $SCRIPT_DIR/tools/review-cli.sh"
echo ""
