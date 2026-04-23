#!/bin/bash
# tools/check-forge-dispatch.sh: Flag direct backend-wrapper calls from .ag files.
#
# Under the forge abstraction (ADR-0002, #256), `.ag` agents must call
# `scripts/forge-api.sh` — the per-colony dispatcher that reads
# `$FORGE_TYPE` and forwards to the matching backend wrapper (gitlab-api.sh
# or github-api.sh). An agent that hardcodes `scripts/gitlab-api.sh` (or
# `scripts/github-api.sh`) silently breaks on the other backend: with
# `FORGE_TYPE=github`, start-colony.sh exports only GITHUB_* env and the
# gitlab-api.sh env-check fails, then .ag try/catch swallows the error.
#
# The check fires per-colony, and only once that colony ships a concrete
# GitHub backend (`scripts/github-api.sh`). Colonies that still have only
# the dispatcher skeleton (#256 PRs 3-6 pending) are exempt — an operator
# cannot meaningfully run them on `FORGE_TYPE=github` yet, so there is
# nothing to enforce.
#
# Usage: ./tools/check-forge-dispatch.sh [path]
# Exit 0 if no findings, 1 if one or more findings, 2 on usage error.

set -euo pipefail

SCAN_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ ! -e "$SCAN_ROOT" ]; then
    echo "check-forge-dispatch: scan root does not exist: $SCAN_ROOT" >&2
    exit 2
fi

FAIL=0

# Discover colonies that ship a concrete GitHub backend. Those are the
# colonies where `.ag` agents MUST route through forge-api.sh.
while IFS= read -r github_backend; do
    colony_dir="$(dirname "$(dirname "$github_backend")")"
    agents_dir="$colony_dir/agents"
    [ -d "$agents_dir" ] || continue

    while IFS= read -r ag_file; do
        [ -f "$ag_file" ] || continue
        # Strip line comments (everything after `//`) before matching.
        matches=$(awk '
            {
                line = $0
                pos = index(line, "//")
                if (pos > 0) line = substr(line, 1, pos - 1)
                if (line ~ /scripts\/(gitlab|github)-api\.sh/) print NR ":" $0
            }
        ' "$ag_file") || true
        if [ -n "$matches" ]; then
            FAIL=1
            echo "check-forge-dispatch: direct backend-wrapper call in $ag_file — use scripts/forge-api.sh"
            printf '%s\n' "$matches" | sed 's/^/  /'
        fi
    done < <(find "$agents_dir" -type f -name '*.ag' 2>/dev/null)
done < <(find "$SCAN_ROOT" -type f -path '*/scripts/github-api.sh' 2>/dev/null)

exit "$FAIL"
