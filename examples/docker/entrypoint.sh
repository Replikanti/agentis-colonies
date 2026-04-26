#!/bin/bash
# entrypoint.sh — container entry for agentis-colonies (#324).
#
# Bootstraps the federation on first run, then exec()s into
# `<federation>/start-federation.sh`. Designed for both `docker run` and k8s
# Deployments where the persistent volume is mounted at /data.
#
# Inputs (env vars):
#   FEDERATION       — federation directory under /opt/agentis-colonies/
#                      (default: dev-apprenticeship; set in Dockerfile)
#   FORGE_TYPE       — gitlab | github (default: gitlab)
#
#   GitLab path:
#     GITLAB_URL, GITLAB_TOKEN, GITLAB_PROJECT, GITLAB_ME (optional)
#
#   GitHub path:
#     GITHUB_URL (optional), GITHUB_TOKEN, GITHUB_OWNER, GITHUB_REPO,
#     GITHUB_ME (optional)
#
# All env vars are forwarded by the colony start-colony.sh scripts to .ag
# agents via `exec.env_passthrough` (which install.sh writes during step 4).
#
# Behaviour:
#   - On first start (empty /data/.agentis), runs `agentis init` + the
#     idempotent fragments of dev-apprenticeship/install.sh that DO NOT
#     require operator input (config copy, key writes, lifecycle dir).
#     Skips interactive prompts (forge creds + dashboard install).
#   - On subsequent starts, /data/.agentis already exists so the bootstrap
#     is a no-op.
#   - Then exec()s into start-federation.sh so PID 1 = the federation
#     supervisor (signals propagate cleanly).

set -eu

FEDERATION="${FEDERATION:-dev-apprenticeship}"
FED_DIR="/opt/agentis-colonies/${FEDERATION}"
FORGE_TYPE="${FORGE_TYPE:-gitlab}"

if [ ! -d "$FED_DIR" ]; then
    echo "[entrypoint] federation '${FEDERATION}' not found at ${FED_DIR}" >&2
    echo "[entrypoint] available federations:" >&2
    ls -1 /opt/agentis-colonies/ | grep -vE '^(tools|doc|README\.md|LICENSE)$' >&2 || true
    exit 1
fi

# /data is the volume mount. We point the federation's .agentis/ symlink at
# it so experience JSONL + memo store survive container restarts.
mkdir -p /data/.agentis
if [ ! -L /opt/agentis-colonies/.agentis ] \
   || [ "$(readlink /opt/agentis-colonies/.agentis)" != /data/.agentis ]; then
    rm -rf /opt/agentis-colonies/.agentis
    ln -s /data/.agentis /opt/agentis-colonies/.agentis
fi

# Per-colony .agentis symlinks (mirrors install.sh §4 behaviour) so daemons
# launched from a colony cwd resolve to the federation-shared registry rather
# than spawning a divergent empty one.
COLONIES="$(ls -1 "$FED_DIR" 2>/dev/null \
    | while IFS= read -r entry; do
        [ -d "$FED_DIR/$entry/config" ] && printf '%s\n' "$entry"
    done || true)"

for colony in $COLONIES; do
    target="/data/.agentis"
    link="${FED_DIR}/${colony}/.agentis"
    if [ ! -L "$link" ] || [ "$(readlink "$link")" != "$target" ]; then
        rm -rf "$link"
        ln -s "$target" "$link"
    fi
done

# First-run bootstrap. The agentis CLI's `init` is idempotent so this is safe
# to call on every start; the work it does (creating /data/.agentis/config
# and the lifecycle dir) only happens once.
if [ ! -f /data/.agentis/config ]; then
    echo "[entrypoint] /data/.agentis/config missing — running first-run bootstrap"
    (cd /opt/agentis-colonies && agentis init >/dev/null 2>&1) || true

    # Mirror the keys install.sh §4 writes. These are required for the
    # federation to complete a single tick on a real LLM backend.
    cfg=/data/.agentis/config
    touch "$cfg"
    write_key() {
        local key="$1"
        local value="$2"
        local grep_key
        grep_key=$(printf '%s' "$key" | sed 's/\./\\./g')
        if ! grep -q "^${grep_key}[[:space:]]*=" "$cfg" 2>/dev/null; then
            printf '%s = %s\n' "$key" "$value" >> "$cfg"
        fi
    }
    write_key 'federation.enabled'           'true'
    write_key 'knowledge.federation_enabled' 'true'
    write_key 'daemon.tick_interval_ms'      '60000'
    write_key 'daemon.heartbeat_interval_ms' '900000'
    write_key 'daemon.cb_per_tick'           '2000'
    write_key 'experience.enabled'           'true'
    write_key 'exec.env_passthrough'         'COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*'
    write_key 'exec.default_timeout_ms'      '120000'
    write_key 'pii_transmit'                 'allow'
    write_key 'knowledge.enabled'            'true'
    write_key 'learning.enabled'             'true'
    chmod 600 "$cfg" 2>/dev/null || true
fi

# Materialise per-colony colony.toml from colony.example.toml (the runtime
# expects colony.toml; install.sh normally does this but we skip it for
# unattended container starts) and write the [forge].type from $FORGE_TYPE.
for colony in $COLONIES; do
    cfg_dir="${FED_DIR}/${colony}/config"
    if [ -f "$cfg_dir/colony.example.toml" ] && [ ! -f "$cfg_dir/colony.toml" ]; then
        cp "$cfg_dir/colony.example.toml" "$cfg_dir/colony.toml"
        chmod 600 "$cfg_dir/colony.toml" 2>/dev/null || true
    fi
    if [ -f "$cfg_dir/colony.toml" ]; then
        python3 - "$cfg_dir/colony.toml" "$FORGE_TYPE" <<'PY' || true
import sys, re
path, forge_type = sys.argv[1:3]
with open(path) as f:
    lines = f.readlines()
in_forge = False
out = []
for line in lines:
    stripped = line.strip()
    if stripped.startswith('[') and stripped.endswith(']'):
        in_forge = (stripped[1:-1].strip() == 'forge')
    if in_forge and re.match(r'\s*type\s*=\s*"[^"]*"', line):
        line = re.sub(r'(type\s*=\s*)"[^"]*"',
                      lambda m: m.group(1) + '"' + forge_type + '"',
                      line, count=1)
    out.append(line)
with open(path, 'w') as f:
    f.write(''.join(out))
PY
    fi
done

# A non-empty token is required. We abort early with a clear message rather
# than letting start-federation.sh fail mid-startup with a less-useful trace.
if [ "$FORGE_TYPE" = "gitlab" ]; then
    if [ -z "${GITLAB_TOKEN:-}" ]; then
        echo "[entrypoint] GITLAB_TOKEN env var is required (FORGE_TYPE=gitlab)" >&2
        exit 1
    fi
elif [ "$FORGE_TYPE" = "github" ]; then
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        echo "[entrypoint] GITHUB_TOKEN env var is required (FORGE_TYPE=github)" >&2
        exit 1
    fi
else
    echo "[entrypoint] FORGE_TYPE must be gitlab or github (got '${FORGE_TYPE}')" >&2
    exit 1
fi

# If the user passed a command (`docker run ... <cmd>`), run it instead of the
# federation. Useful for ad-hoc inspection (`docker run ... agentis daemon list`).
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

cd "$FED_DIR"
exec ./start-federation.sh
