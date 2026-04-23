#!/bin/bash
# Forge dispatcher for the triage colony (ADR-0002, #256).
#
# Agents call this script via exec sh instead of the backend-specific
# wrappers (gitlab-api.sh, github-api.sh). The dispatcher reads the
# FORGE_TYPE env var (exported by start-colony.sh from the [forge].type
# config key) and forwards argv verbatim to the matching backend wrapper.
#
# Agents receive identical normalized JSON regardless of backend. See
# doc/adr/ADR-0002-forge-abstraction.md for the shape contract.
#
# Exit codes:
#   0   success (from the underlying wrapper)
#   1   backend wrapper failure (from the underlying wrapper)
#   2   unknown flag / usage error
#   99  requested FORGE_TYPE has no backend wrapper yet (see #256 PRs 2-6)

set -e

FORGE_TYPE="${FORGE_TYPE:-gitlab}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

case "$FORGE_TYPE" in
    gitlab)
        backend="$SCRIPT_DIR/gitlab-api.sh"
        ;;
    github)
        backend="$SCRIPT_DIR/github-api.sh"
        ;;
    *)
        echo "forge-api.sh: unknown FORGE_TYPE '$FORGE_TYPE' (expected: gitlab|github)" >&2
        exit 2
        ;;
esac

if [ ! -x "$backend" ]; then
    # PR 2 of #256 ships github-api.sh for triage, so a missing github backend
    # here means either a broken install (deleted / chmod -x'd post-install)
    # or — if this dispatcher was copied to another colony pre-PR-2 — that
    # colony's github-api.sh has not landed yet. Emit a uniform "missing or
    # not executable" message and point at the ADR for the rollout state.
    echo "forge-api.sh: backend wrapper missing or not executable: $backend" >&2
    echo "forge-api.sh: re-copy the colony scripts/ directory, or — if upgrading from pre-#256 — see doc/adr/ADR-0002-forge-abstraction.md and https://github.com/Replikanti/agentis-colonies/issues/256 (PRs 2-6) for the GitHub-backend rollout status." >&2
    exit 99
fi

exec "$backend" "$@"
