#!/bin/bash
# tools/test-docker-build.sh — build-only smoke test for the multi-stage
# Dockerfile shipped in #324.
#
# What this checks:
#   1. `docker build --target=runtime .` succeeds.
#   2. The resulting image contains the agentis binary at /usr/local/bin/agentis
#      and runs `agentis --version` cleanly.
#   3. The federation tree was COPYed into /opt/agentis-colonies/dev-apprenticeship/.
#   4. The runtime entrypoint exists and is executable.
#   5. The runtime user is the non-root `agentis` (UID 1000).
#
# Why build-only: pushing requires registry credentials we don't have outside
# the GitHub Actions release workflow. Smoke-test the build locally; the
# workflow runs the same Dockerfile under `docker/build-push-action`.
#
# Skip behaviour:
#   - If `docker` is not on PATH, every test prints [SKIP] and the script
#     returns 0 — colony-lint.sh auto-discovers tools/test-*.sh and runs them
#     unconditionally, so this script MUST stay green even on docker-less
#     CI runners.
#   - Set AGENTIS_SKIP_DOCKER_TESTS=1 in the environment to skip explicitly
#     (useful when docker is installed but the daemon is not running, or to
#     keep local lint cycles fast).
#
# Exit code 0 if all assertions pass (or are skipped), 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
SKIP=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1: $2"; SKIP=$((SKIP + 1)); }

# Skip outright in three cases:
#   - operator opted out via AGENTIS_SKIP_DOCKER_TESTS=1
#   - docker binary missing (lint runners on macOS without Docker Desktop)
#   - docker daemon unreachable (`docker info` non-zero) — happens on CI
#     runners that ship the client without spinning up the daemon, and on
#     restricted environments where DOCKER_HOST is unset.
if [ "${AGENTIS_SKIP_DOCKER_TESTS:-0}" = "1" ]; then
    skip "docker build" "AGENTIS_SKIP_DOCKER_TESTS=1"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
    skip "docker build" "docker binary not found on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

if ! docker info >/dev/null 2>&1; then
    skip "docker build" "docker daemon unreachable (docker info failed)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# We tag the image with a unique name so concurrent runs don't trample
# each other; trap removes it on exit.
TAG="agentis-colonies-test-build:$(date +%s)-$$"
trap 'docker image rm -f "$TAG" >/dev/null 2>&1 || true' EXIT

# ----- Test 1: build succeeds -----
BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"; docker image rm -f "$TAG" >/dev/null 2>&1 || true' EXIT
if (cd "$REPO_ROOT" && docker build --target=runtime -t "$TAG" .) >"$BUILD_LOG" 2>&1; then
    pass "docker build --target=runtime"
else
    fail "docker build --target=runtime" "build exited non-zero; tail of log:"
    tail -40 "$BUILD_LOG"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# ----- Test 2: agentis --version runs -----
if VERSION_OUT="$(docker run --rm --entrypoint agentis "$TAG" --version 2>&1)"; then
    pass "agentis --version: $VERSION_OUT"
else
    fail "agentis --version" "non-zero exit; out=$VERSION_OUT"
fi

# ----- Test 3: federation tree present -----
if docker run --rm --entrypoint /bin/sh "$TAG" -c \
        'test -f /opt/agentis-colonies/dev-apprenticeship/start-federation.sh && \
         test -f /opt/agentis-colonies/dev-apprenticeship/install.sh && \
         test -f /opt/agentis-colonies/dev-apprenticeship/VERSION' >/dev/null 2>&1; then
    pass "federation tree present at /opt/agentis-colonies/dev-apprenticeship/"
else
    fail "federation tree" "expected files missing under /opt/agentis-colonies/dev-apprenticeship/"
fi

# ----- Test 4: entrypoint installed + executable -----
if docker run --rm --entrypoint /bin/sh "$TAG" -c \
        'test -x /entrypoint.sh' >/dev/null 2>&1; then
    pass "/entrypoint.sh installed and executable"
else
    fail "entrypoint" "/entrypoint.sh missing or not executable"
fi

# ----- Test 5: non-root user -----
if WHOAMI="$(docker run --rm --entrypoint /bin/sh "$TAG" -c 'id -un')"; then
    if [ "$WHOAMI" = "agentis" ]; then
        pass "container runs as non-root user 'agentis'"
    else
        fail "non-root user" "expected 'agentis', got '$WHOAMI'"
    fi
else
    fail "non-root user" "id -un failed"
fi

# ----- Test 6: shared platform tooling present -----
# parse-toml.sh is sourced, not executed — it ships without the exec bit on
# disk and that's correct. Other scripts are exec-targets and must be -x.
if docker run --rm --entrypoint /bin/sh "$TAG" -c \
        'test -r /opt/agentis-colonies/tools/parse-toml.sh && \
         test -x /opt/agentis-colonies/tools/auto-promote.sh && \
         test -x /opt/agentis-colonies/tools/kill-federation.sh' >/dev/null 2>&1; then
    pass "shared platform tooling present at /opt/agentis-colonies/tools/"
else
    fail "shared tooling" "expected scripts missing under /opt/agentis-colonies/tools/"
fi

# ----- Test 7: contributor-only files NOT present (verifies .dockerignore) -----
LEAKED=""
for path in \
    /opt/agentis-colonies/CLAUDE.md \
    /opt/agentis-colonies/tools/colony-lint.sh \
    /opt/agentis-colonies/tools/test-docker-build.sh \
    /opt/agentis-colonies/.github \
    /opt/agentis-colonies/federation-dashboard; do
    if docker run --rm --entrypoint /bin/sh "$TAG" -c "test -e $path" >/dev/null 2>&1; then
        LEAKED="$LEAKED $path"
    fi
done
if [ -z "$LEAKED" ]; then
    pass "contributor-only files excluded by .dockerignore"
else
    fail "dockerignore leak" "leaked paths:$LEAKED"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
