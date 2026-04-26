# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for the agentis-colonies dev-apprenticeship federation
# (#324). Produces a runnable image that bundles:
#   - the agentis runtime binary (downloaded from Replikanti/agentis releases,
#     verified against its `.sha256` sidecar, stripped, placed at
#     /usr/local/bin/agentis)
#   - the dev-apprenticeship federation tree under /opt/agentis-colonies/
#   - the shared platform tooling under /opt/agentis-colonies/tools/
#
# Build args:
#   AGENTIS_VERSION       — tag to download from Replikanti/agentis releases
#                           (defaults to the value baked into
#                           dev-apprenticeship/.agentis-version at build time
#                           via the GitHub Actions workflow).
#   FEDERATION_VERSION    — informational, embedded as an OCI label.
#
# Targets supported by linux/amd64 + linux/arm64 (multi-arch via buildx).
# `TARGETARCH` is set automatically by buildx; we map it to the agentis asset
# name so the same Dockerfile produces both architectures from one BuildKit
# invocation.
#
# Run:
#   docker run --rm -e GITLAB_TOKEN=... -e GITLAB_URL=... -e GITLAB_PROJECT=... \
#       -v $PWD/data:/data \
#       ghcr.io/replikanti/agentis-colonies:dev-apprenticeship-1.2.0
#
# See deploy/README.md for full operator setup (compose + k8s recipes).

# -----------------------------------------------------------------------------
# Stage 1: builder — downloads + verifies the agentis binary.
# -----------------------------------------------------------------------------
# Why debian:13-slim (not 12)? agentis >= 1.4.7 binaries are dynamically linked
# against GLIBC 2.39 (the toolchain the release runners use). Debian 12 ships
# GLIBC 2.36 — running the binary on 12-slim fails at startup with "GLIBC_2.39
# not found". Debian 13 ships GLIBC 2.41 which satisfies the requirement. If a
# future agentis release lowers the GLIBC floor, this can be downgraded; until
# then, do NOT bump down without verifying `ldd --version` against the pinned
# AGENTIS_VERSION below.
FROM debian:13-slim AS builder

ARG AGENTIS_VERSION=1.4.7
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Map TARGETARCH (amd64 / arm64) to the asset name shipped by Replikanti/agentis.
# The release contract uploads both binary + .sha256 sidecar for each arch:
#   agentis-linux-x86_64        + agentis-linux-x86_64.sha256
#   agentis-linux-aarch64       + agentis-linux-aarch64.sha256
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ASSET="agentis-linux-x86_64" ;; \
        arm64) ASSET="agentis-linux-aarch64" ;; \
        *)     echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    BASE="https://github.com/Replikanti/agentis/releases/download/v${AGENTIS_VERSION}"; \
    curl -fsSL -o "${ASSET}"        "${BASE}/${ASSET}"; \
    curl -fsSL -o "${ASSET}.sha256" "${BASE}/${ASSET}.sha256"; \
    sha256sum -c "${ASSET}.sha256"; \
    install -d /out; \
    install -m 0755 "${ASSET}" /out/agentis; \
    strip /out/agentis 2>/dev/null || true; \
    /out/agentis --version

# -----------------------------------------------------------------------------
# Stage 2: runtime — minimal image with bash, python3, jq, curl, git.
# -----------------------------------------------------------------------------
# Same GLIBC 2.39 constraint as the builder stage (see comment above the
# builder FROM); keep both stages on debian:13-slim until agentis lowers
# the floor. If you ever change one, change both.
FROM debian:13-slim AS runtime

ARG AGENTIS_VERSION=1.4.7
ARG FEDERATION_VERSION=unknown

LABEL org.opencontainers.image.title="agentis-colonies"
LABEL org.opencontainers.image.description="dev-apprenticeship federation + agentis runtime"
LABEL org.opencontainers.image.source="https://github.com/Replikanti/agentis-colonies"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.vendor="Replikanti"
LABEL org.opencontainers.image.version="${FEDERATION_VERSION}"
LABEL agentis.version="${AGENTIS_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive

# Runtime dependencies:
#   bash             — every script in tools/ + dev-apprenticeship/ uses #!/bin/bash
#   python3          — install.sh, parse-toml.sh, the auto-promote helpers,
#                      cost-cap helpers, every start-colony.sh symlink-resolution.
#                      Debian 13 ships python3.13 with tomllib in stdlib.
#   jq               — idiomatic JSON extraction in shell wrappers.
#   gawk             — colony-lint-flag-allowlist.awk + the auto-promote awks
#                      use GNU awk extensions; mawk (Debian default) lacks gensub.
#   curl             — gitlab-api.sh / github-api.sh wrappers.
#   git              — install.sh prereq check + on-host repo introspection.
#   ca-certificates  — TLS for forge API calls.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        gawk \
        git \
        jq \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Non-root operator account. Match conventional UID/GID 1000 so volume mounts
# from typical Linux hosts do not require chmod gymnastics.
RUN groupadd --gid 1000 agentis \
    && useradd --uid 1000 --gid 1000 --shell /bin/bash --create-home agentis

# Agentis binary from the builder stage.
COPY --from=builder /out/agentis /usr/local/bin/agentis

# Federation tree + shared platform tooling. The .dockerignore at the repo
# root keeps contributor-only paths (CLAUDE.md, .github/, doc/, tools/test-*.sh,
# tools/colony-lint*, tools/check-*.sh, federation-dashboard/, worktrees/,
# dist/, .agentis state) out of the build context, so the COPY below mirrors
# the BUNDLE.manifest runtime contract without needing a `find -prune` recipe.
WORKDIR /opt/agentis-colonies

COPY --chown=agentis:agentis dev-apprenticeship/ /opt/agentis-colonies/dev-apprenticeship/
COPY --chown=agentis:agentis tools/             /opt/agentis-colonies/tools/
COPY --chown=agentis:agentis doc/               /opt/agentis-colonies/doc/
COPY --chown=agentis:agentis README.md LICENSE  /opt/agentis-colonies/
COPY --chown=agentis:agentis examples/docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Operator data lives under /data — mounted as a volume in real deployments
# so experience JSONL + memo store survive container restarts. The agentis
# root resolver walks up from cwd, so we symlink the federation's .agentis
# into /data and let the federation-side install/start scripts populate it.
RUN install -d -o agentis -g agentis /data \
    && install -d -o agentis -g agentis /opt/agentis-colonies/.agentis

VOLUME ["/data"]

# Optional Compose / k8s healthcheck. `agentis daemon list` is cheap and
# returns rc=0 even when zero daemons are running, so a non-zero rc signals
# a real binary / config problem rather than a pre-bootstrap state.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD agentis daemon list >/dev/null 2>&1 || exit 1

USER agentis

# Default federation. Operators can override via `-e FEDERATION=<name>`
# once additional federations ship.
ENV FEDERATION=dev-apprenticeship
ENV PATH="/usr/local/bin:${PATH}"

ENTRYPOINT ["/entrypoint.sh"]
CMD []
