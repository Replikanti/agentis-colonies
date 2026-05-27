#!/bin/bash
# run-research-smoke-local.sh -- wrapper around tools/run-research.sh that
# builds the research-foundry container from a local agentis-core source
# tree (via Containerfile.research-local-smoke) instead of pulling the
# official release binary from GitHub (#816). Intended ONLY for
# pre-release smoke testing of an unreleased `agentis` build that has not
# yet shipped a tagged release.
#
# DO NOT use this script for production research runs. The production
# path is `tools/run-research.sh`, which uses `Containerfile.research`
# with a pinned `ARG AGENTIS_VERSION=vX.Y.Z` and verifies the downloaded
# binary's SHA256 against the published sidecar. A locally-built binary
# carries no published checksum and is unreproducible across hosts.
#
# Env vars (all optional; defaults shown):
#   AGENTIS_CORE_SOURCE   Path to the agentis-core source checkout. The
#                         bind mount target inside the build is
#                         /agentis-core-source. Defaults to ../agentis-core
#                         (sibling to the agentis-colonies repo).
#   RESEARCH_TOTAL_TICKS  Smoke tick count. Defaults to 25 (smoke-test
#                         scale; production validation uses 75 via
#                         tools/run-research.sh's default). Override only
#                         when extending the smoke window for a specific
#                         repro -- typical smoke is the 25-tick default.
#   RESEARCH_IMAGE_TAG    Container tag to build + run. Defaults to
#                         `research-foundry:smoke-local`.
#   RESEARCH_PODMAN_BUILD_ARGS  Extra `podman build` flags to pass through
#                         (e.g. `--no-cache`).
#
# All other `RESEARCH_*` env vars are forwarded verbatim to run-research.sh
# (see that script's header for the full catalogue).
#
# Usage:
#   AGENTIS_CORE_SOURCE=/path/to/agentis-core ./tools/run-research-smoke-local.sh

set -euo pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(cd "$THIS_DIR/.." && pwd)"

AGENTIS_CORE_SOURCE_RAW="${AGENTIS_CORE_SOURCE:-../agentis-core}"
# Resolve to an absolute path so podman build accepts the -v mount source.
AGENTIS_CORE_SOURCE_ABS="$(cd "$AGENTIS_CORE_SOURCE_RAW" 2>/dev/null && pwd)" || {
    echo "run-research-smoke-local: AGENTIS_CORE_SOURCE does not resolve to an existing directory: $AGENTIS_CORE_SOURCE_RAW" >&2
    echo "                          set AGENTIS_CORE_SOURCE=/path/to/agentis-core or check out the source as a sibling of agentis-colonies." >&2
    exit 2
}

if [ ! -f "$AGENTIS_CORE_SOURCE_ABS/Cargo.toml" ]; then
    echo "run-research-smoke-local: $AGENTIS_CORE_SOURCE_ABS does not look like an agentis-core checkout (no Cargo.toml)." >&2
    exit 2
fi

CONTAINERFILE="$THIS_DIR/Containerfile.research-local-smoke"
if [ ! -f "$CONTAINERFILE" ]; then
    echo "run-research-smoke-local: missing $CONTAINERFILE" >&2
    exit 2
fi

# Smoke-scale defaults. Operators can override via env -- the wrapper just
# wires them through to run-research.sh's existing env-var handling.
export RESEARCH_TOTAL_TICKS="${RESEARCH_TOTAL_TICKS:-25}"
export RESEARCH_IMAGE_TAG="${RESEARCH_IMAGE_TAG:-research-foundry:smoke-local}"

PODMAN_EXTRA_ARGS="${RESEARCH_PODMAN_BUILD_ARGS:-}"

echo "run-research-smoke-local: building smoke image"
echo "  source        : $AGENTIS_CORE_SOURCE_ABS"
echo "  Containerfile : $CONTAINERFILE"
echo "  image tag     : $RESEARCH_IMAGE_TAG"
echo "  ticks         : $RESEARCH_TOTAL_TICKS"

# shellcheck disable=SC2086
podman build \
    -t "$RESEARCH_IMAGE_TAG" \
    -f "$CONTAINERFILE" \
    -v "${AGENTIS_CORE_SOURCE_ABS}:/agentis-core-source:ro,Z" \
    $PODMAN_EXTRA_ARGS \
    "$FED_DIR"

# Hand off to the production orchestrator. RESEARCH_IMAGE_TAG above keeps
# run-research.sh's `podman image exists $IMAGE_TAG ||` check truthy so the
# orchestrator skips its own (release-tarball) build step.
echo "run-research-smoke-local: handing off to tools/run-research.sh"
exec "$THIS_DIR/run-research.sh" "$@"
