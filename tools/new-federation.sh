#!/bin/bash
# new-federation.sh: scaffold a new federation under the agentis-colonies repo.
#
# Generates the directory shape required by ADR-0003
# (doc/adr/ADR-0003-federation-portability-contract.md): VERSION, CHANGELOG.md,
# README.md, BUNDLE.manifest, install.sh, plus one starter colony with a
# start-colony.sh that already supports the --restart-agent and
# --rate-limit-status flags consumed by federation-dashboard.
#
# Output passes `tools/colony-lint.sh` clean. By default the generated TOML
# carries a forge=gitlab stub. Pass `--no-forge` (#373) to scaffold a
# non-forge federation: the generated `colony.example.toml` declares
# `forge.type = "none"` and the generated `start-colony.sh` skips the
# forge env-wiring block entirely. ADR-0002 remains normative for forge-bound
# colonies; ADR-0003 covers the non-forge case.
#
# Usage: ./tools/new-federation.sh [--no-forge] <federation-name> [<starter-colony-name>]
# Example: ./tools/new-federation.sh data-ops ingestion
# Example: ./tools/new-federation.sh --no-forge metrics-bench ingestion

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    cat <<EOF
Usage: $0 [--no-forge] <federation-name> [<starter-colony-name>]

Scaffolds a new federation under \$REPO_ROOT/<federation-name>/ with one
starter colony. Output conforms to ADR-0003 and passes colony-lint.

Arguments:
  <federation-name>        Lowercase alphanumeric with dashes. Required.
  <starter-colony-name>    Lowercase alphanumeric with dashes. Defaults to "core".

Flags:
  --no-forge               Scaffold a non-forge federation (#373). The generated
                           colony.example.toml declares \`forge.type = "none"\`
                           and start-colony.sh skips the forge env-wiring block.
EOF
    exit 1
}

NO_FORGE=0
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-forge)
            NO_FORGE=1
            shift
            ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            echo "Error: unknown flag: $1" >&2
            usage
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]}"

[ $# -ge 1 ] || usage
[ $# -le 2 ] || usage

FEDERATION="$1"
COLONY="${2:-core}"
FED_PATH="$REPO_ROOT/$FEDERATION"
COL_PATH="$FED_PATH/$COLONY"

# Validate names.
name_re='^[a-z][a-z0-9-]*$'
if [[ ! "$FEDERATION" =~ $name_re ]]; then
    echo "Error: federation name must be lowercase alphanumeric with dashes (got: '$FEDERATION')" >&2
    exit 1
fi
if [[ ! "$COLONY" =~ $name_re ]]; then
    echo "Error: colony name must be lowercase alphanumeric with dashes (got: '$COLONY')" >&2
    exit 1
fi

# Reserved names — would clash with discovery in colony-lint or with
# the standalone federation-dashboard component.
case "$FEDERATION" in
    tools|doc|federation-dashboard|.github|dist|worktrees)
        echo "Error: federation name '$FEDERATION' is reserved" >&2
        exit 1
        ;;
esac

if [ -e "$FED_PATH" ]; then
    echo "Error: '$FEDERATION' already exists at $FED_PATH" >&2
    exit 1
fi

# Pretty names: "data-ops" -> "Data Ops".
pretty() { echo "$1" | sed 's/-/ /g' | awk '{for (i=1; i<=NF; i++) $i=toupper(substr($i,1,1)) substr($i,2)}1'; }
FED_PRETTY="$(pretty "$FEDERATION")"
COL_PRETTY="$(pretty "$COLONY")"

echo "Scaffolding federation '$FEDERATION' (starter colony: '$COLONY')..."

mkdir -p "$COL_PATH/agents" "$COL_PATH/config" "$COL_PATH/scripts"
touch "$COL_PATH/agents/.gitkeep"

# --- Federation-level files ---

echo "0.1.0" > "$FED_PATH/VERSION"

cat > "$FED_PATH/BUNDLE.manifest" <<EOF
$FEDERATION/
EOF

today="$(date '+%Y-%m-%d')"
cat > "$FED_PATH/CHANGELOG.md" <<EOF
# Changelog — $FEDERATION

All notable changes to the \`$FEDERATION/\` federation will be documented in
this file.

This federation follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
at the federation level. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Tags use the prefixed form \`$FEDERATION-v<X.Y.Z>\` so other federations
in this repo can release independently without collision.

Every release declares its runtime floor as \`**Requires:** agentis >= X.Y.Z\`.

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

## [0.1.0] — $today

Initial scaffold via \`tools/new-federation.sh\`. Conforms to
[ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md).

**Requires:** agentis >= 1.4.1

### Added

- One starter colony: \`$COLONY/\` with placeholder agent slot.
- ADR-0003-compliant \`scripts/start-colony.sh\` (supports
  \`--restart-agent\`, \`--rate-limit-status\`, exit 2 on unknown flag).

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/$FEDERATION-v0.1.0...HEAD
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/$FEDERATION-v0.1.0
EOF

cat > "$FED_PATH/README.md" <<EOF
# $FED_PRETTY

![Version: 0.1.0](https://img.shields.io/badge/version-0.1.0-blue) ![Status: Alpha](https://img.shields.io/badge/status-alpha-orange)

**Version:** \`0.1.0\` · [Changelog](./CHANGELOG.md) · **Requires:** agentis >= \`1.4.1\`

> One-paragraph description of what real-world workflow this federation
> learns. Replace this stub with the federation's domain identity (the
> top-level \`README.md\` and \`doc/federation-patterns.md\` cross-link to
> this paragraph).

This federation was scaffolded via
[\`tools/new-federation.sh\`](../tools/new-federation.sh) and conforms to
[ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md). See
[\`doc/federation-patterns.md\`](../doc/federation-patterns.md) for example
federation shapes, and
[\`doc/ag-first-guide.md\`](../doc/ag-first-guide.md) before writing any
\`exec sh\` — it covers which side of that boundary a decision belongs on, what
moving work into \`.ag\` costs in CB, and the runtime traps that pass
\`agentis commit\` and fail later.

## Colonies

| Colony | Description | Agents |
|--------|-------------|--------|
| [$COLONY](./$COLONY/) | <!-- TODO: describe what this colony does --> | 0 |

## Quickstart

\`\`\`bash
./install.sh             # interactive setup
./$COLONY/scripts/start-colony.sh
\`\`\`

## Tier contract

Every agent in this federation gates its behaviour on the four-tier
confidence ladder defined in
[ADR-0001](../doc/adr/ADR-0001-confidence-tiers.md):

- \`shadow\` — observe + memo, no emit, no external write
- \`propose\` — emit on bus + draft external writes
- \`review-gated\` — direct external writes (non-terminal)
- \`autonomous\` — terminal external writes (merge, tag, ack alert, post reply, …)
EOF

cat > "$FED_PATH/install.sh" <<'INSTALL_EOF'
#!/bin/bash
# install.sh: idempotent setup for this federation.
#
# Stub generated by tools/new-federation.sh. Replace with the federation's
# real prerequisites + credential prompts + memo seeding. Must exit 0 when
# the federation is ready to start.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_NAME="$(basename "$SCRIPT_DIR")"

echo "Installing $FED_NAME federation..."
echo
echo "TODO: implement prerequisite checks, config copying, credential prompts,"
echo "memo seeding, and (optionally) federation-dashboard install per the"
echo ".dashboard-version pin."
echo
echo "For each colony under $SCRIPT_DIR/, copy:"
echo "  <colony>/config/colony.example.toml -> <colony>/config/colony.toml"
echo "and edit the [forge] / data-source / [llm] sections."
echo
echo "Done."
INSTALL_EOF
chmod +x "$FED_PATH/install.sh"

# --- Colony-level files ---

cat > "$COL_PATH/README.md" <<EOF
# $COL_PRETTY Colony

> Part of the [$FED_PRETTY](../) federation.

<!-- TODO: Describe what this colony does and what agents it contains. -->

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| <!-- agent name --> | \`agents/example_agent.ag\` | <!-- what it learns --> | ~N observations |

## Setup

1. Copy and edit the config:
   \`\`\`bash
   cp config/colony.example.toml config/colony.toml
   \`\`\`

2. Configure your forge or data-source connection in \`colony.toml\`.

3. Start the colony:
   \`\`\`bash
   ./scripts/start-colony.sh
   \`\`\`
EOF

# Build the [forge] section once, depending on --no-forge. The two branches
# are kept as standalone heredocs (no nesting) so bash 3.2 stays happy.
if [ "$NO_FORGE" = "1" ]; then
    forge_block="$(cat <<'FORGE_EOF'
# Non-forge federation (#373, ADR-0003).
# `forge.type = "none"` is the explicit opt-out: colony-lint enforces the
# [forge] block presence but skips sub-block validation. Replace this
# with a real [forge] block (see ADR-0002) if/when the federation grows
# a forge dependency.
[forge]
type = "none"
FORGE_EOF
)"
else
    forge_block="$(cat <<'FORGE_EOF'
# Forge configuration (post-#256, ADR-0002).
# Set type to "gitlab", "github", or "none" (non-forge federation, #373).
[forge]
type = "gitlab"

[forge.gitlab]
url = "https://gitlab.example.com"
token = "glpat-your-token-here"
project = "your-org/your-project"
me = "your-username"

# [forge.github]
# owner = "your-org"
# repo  = "your-repo"
# token = "ghp_your-token-here"
# me    = "your-username"
FORGE_EOF
)"
fi

cat > "$COL_PATH/config/colony.example.toml" <<EOF
# $COL_PRETTY Colony Configuration
#
# Part of the $FED_PRETTY federation.
# Copy to colony.toml and edit for your environment.

[colony]
name = "$COLONY"
tick_interval_ms = 60000

$forge_block

[llm]
# Only "backend" is read today. Keep "cli" — it means "use the agentis daemon
# default CLI adapter", which INHERITS the federation backend from
# .agentis/config (typically flat-cyborg, the flat-rate Claude PTY wrapper).
# Do not hardcode "flat-cyborg" here: that would override the federation
# default and break host-run federations that use the flat-cyborg-claude.sh
# wrapper. See CLAUDE.md "LLM backend".
backend = "cli"

# Agent definitions
# Each agent runs as a separate agentis daemon process.
# They discover each other via colony UDP and communicate over TCP emit/listen.

[[agents]]
name = "example_agent"
source = "agents/example_agent.ag"
cb_budget = 800
tick_interval_ms = 60000
EOF

# ADR-0003-conformant start-colony.sh template:
#   - python3-realpath \$0 (symlink-safe)
#   - sources <fed>/../tools/parse-toml.sh
#   - exports COLONY_DIR + forge env
#   - supports --restart-agent <name> and --rate-limit-status
#   - exit 2 on unknown flag, exit 3 on unknown agent, exit 4 on launch failure
#   - emits "started <agent> pid=<n> tick=<ms>" on --restart-agent success
#
# Single-quoted heredoc keeps everything literal; sed below substitutes
# the per-federation tokens.
cat > "$COL_PATH/scripts/start-colony.sh" <<'START_EOF'
#!/bin/bash
# Start the COLONY_PRETTY_PLACEHOLDER colony (part of the FED_PRETTY_PLACEHOLDER federation).
#
# Usage:
#   ./scripts/start-colony.sh [path/to/colony.toml]
#   ./scripts/start-colony.sh --restart-agent <name> [path/to/colony.toml]
#   ./scripts/start-colony.sh --rate-limit-status
#
# ADR-0003 conformance: --restart-agent (#257) respawns one agent with full
# colony env, skips memo seeding + log truncation; --rate-limit-status
# (federation-dashboard 0.3.0) execs forge-api.sh rate-limit-status. Exit
# codes: 0 ok, 2 unknown flag / missing arg, 3 unknown agent, 4 daemon
# launch failure.

set -e

RESTART_AGENT=""
RATE_LIMIT_STATUS=0
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --restart-agent)
            if [ -z "${2:-}" ]; then
                echo "start-colony.sh: --restart-agent requires an agent name" >&2
                exit 2
            fi
            RESTART_AGENT="$2"
            shift 2
            ;;
        --rate-limit-status)
            RATE_LIMIT_STATUS=1
            shift
            ;;
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
set -- "${POSITIONAL[@]}"

# Symlink-safe $0 resolution.
SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
COLONY_DIR="$(dirname "$SCRIPT_DIR")"
FED_DIR="$(dirname "$COLONY_DIR")"
CONFIG="${1:-$COLONY_DIR/config/colony.toml}"

if [ ! -f "$CONFIG" ]; then
    echo "Config not found: $CONFIG"
    echo "Copy config/colony.example.toml to config/colony.toml and edit it."
    exit 1
fi

# Source parse-toml.sh: try <fed>/tools first, then <fed>/../tools (the
# latter is the in-repo layout; the former is for standalone tarball
# installs that ship tools/ inside the federation directory).
PARSE_TOML=""
for cand in "$FED_DIR/tools/parse-toml.sh" "$FED_DIR/../tools/parse-toml.sh"; do
    if [ -f "$cand" ]; then
        PARSE_TOML="$cand"
        break
    fi
done
if [ -z "$PARSE_TOML" ]; then
    echo "Error: tools/parse-toml.sh not found in $FED_DIR/tools or $FED_DIR/../tools" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$PARSE_TOML"

# BEGIN FORGE_BLOCK
# Forge env wiring (ADR-0002). Replace this block with whatever env vars
# this colony's .ag agents consume via exec sh.
FORGE_TYPE=$(parse_toml forge type)
FORGE_TYPE="${FORGE_TYPE:-gitlab}"

case "$FORGE_TYPE" in
    gitlab)
        GITLAB_URL=$(parse_toml forge.gitlab url)
        GITLAB_TOKEN=$(parse_toml forge.gitlab token)
        GITLAB_PROJECT_RAW=$(parse_toml forge.gitlab project)
        GITLAB_ME=$(parse_toml forge.gitlab me)
        if [ -z "$GITLAB_URL" ] || [ -z "$GITLAB_TOKEN" ] || [ -z "$GITLAB_PROJECT_RAW" ]; then
            echo "Error: GitLab config incomplete in $CONFIG" >&2
            echo "Required: url, token, project under [forge.gitlab]" >&2
            exit 1
        fi
        GITLAB_PROJECT="${GITLAB_PROJECT_RAW//\//%2F}"
        export GITLAB_URL GITLAB_TOKEN GITLAB_PROJECT GITLAB_ME
        ;;
    github)
        GITHUB_URL=$(parse_toml forge.github url)
        GITHUB_URL="${GITHUB_URL:-https://api.github.com}"
        GITHUB_OWNER=$(parse_toml forge.github owner)
        GITHUB_REPO=$(parse_toml forge.github repo)
        GITHUB_TOKEN=$(parse_toml forge.github token)
        GITHUB_ME=$(parse_toml forge.github me)
        if [ -z "$GITHUB_OWNER" ] || [ -z "$GITHUB_REPO" ] || [ -z "$GITHUB_TOKEN" ]; then
            echo "Error: GitHub config incomplete in $CONFIG" >&2
            echo "Required: owner, repo, token under [forge.github]" >&2
            exit 1
        fi
        export GITHUB_URL GITHUB_OWNER GITHUB_REPO GITHUB_TOKEN GITHUB_ME
        ;;
    none)
        # ADR-0003 / #373 — non-forge federation: nothing to export here.
        # If this colony's agents need data-source env vars (e.g. TARGET_DIR,
        # VERIFIER_PATH), wire them below this case block.
        ;;
    *)
        echo "Error: unknown [forge].type '$FORGE_TYPE' in $CONFIG (expected: gitlab|github|none)" >&2
        exit 1
        ;;
esac

export FORGE_TYPE
export COLONY_DIR
# END FORGE_BLOCK

# TODO: list this colony's agent names here. Each must have a matching
# <colony>/agents/<name>.ag file.
AGENTS=(
)

if [ ${#AGENTS[@]} -eq 0 ] && [ "$RATE_LIMIT_STATUS" = "0" ] && [ -z "$RESTART_AGENT" ]; then
    echo "No agents defined yet. Edit AGENTS=( ... ) in this script after creating .ag files." >&2
    exit 1
fi

# Per-agent tick-interval override. Add cases for agents whose natural
# cadence differs from the 60s default.
tick_interval_for() {
    case "$1" in
        # example_reactive_agent) echo 300000 ;;
        *) echo 60000 ;;
    esac
}

# --rate-limit-status mode (federation-dashboard 0.3.0). Replace with the
# real rate-limit primitive your data source exposes; the platform consumes
# the JSON contract `{remaining, limit, reset_at}` only.
if [ "$RATE_LIMIT_STATUS" = "1" ]; then
    if [ -x "$COLONY_DIR/scripts/forge-api.sh" ]; then
        exec "$COLONY_DIR/scripts/forge-api.sh" rate-limit-status
    fi
    echo '{"remaining": null, "limit": null, "reset_at": null, "error": "rate-limit-status not implemented for this colony"}'
    exit 0
fi

# --restart-agent mode (#257). Single-agent respawn, no log truncation,
# no memo seeding (those are full-colony bootstrap concerns).
if [ -n "$RESTART_AGENT" ]; then
    valid=0
    for a in "${AGENTS[@]}"; do
        [ "$a" = "$RESTART_AGENT" ] && valid=1
    done
    if [ "$valid" = "0" ]; then
        echo "start-colony.sh: unknown agent '$RESTART_AGENT' for this colony" >&2
        exit 3
    fi
    tick=$(tick_interval_for "$RESTART_AGENT")
    agentis daemon "$COLONY_DIR/agents/${RESTART_AGENT}.ag" \
        --colony COLONY_NAME_PLACEHOLDER \
        --enable-exec \
        --enable-messaging \
        --tick-interval "$tick" </dev/null >/dev/null 2>&1 &
    agent_pid=$!
    sleep 0.5
    if ! kill -0 "$agent_pid" 2>/dev/null; then
        echo "start-colony.sh: agentis daemon failed to launch $RESTART_AGENT" >&2
        exit 4
    fi
    echo "started $RESTART_AGENT pid=$agent_pid tick=$tick"
    exit 0
fi

echo "Starting COLONY_PRETTY_PLACEHOLDER colony (${#AGENTS[@]} agents)..."

for agent in "${AGENTS[@]}"; do
    interval=$(tick_interval_for "$agent")
    echo "  Starting $agent (tick=${interval}ms)..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony COLONY_NAME_PLACEHOLDER \
        --enable-exec \
        --enable-messaging \
        --tick-interval "$interval" &
    sleep 2
done

echo "Colony started. Use 'agentis daemon list' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
START_EOF

# Substitute per-federation tokens.
sed -i \
    -e "s/COLONY_PRETTY_PLACEHOLDER/$COL_PRETTY/g" \
    -e "s/FED_PRETTY_PLACEHOLDER/$FED_PRETTY/g" \
    -e "s/COLONY_NAME_PLACEHOLDER/$COLONY/g" \
    "$COL_PATH/scripts/start-colony.sh"

# When --no-forge is set, swap the BEGIN FORGE_BLOCK..END FORGE_BLOCK
# range for a non-forge no-op (mirroring tribes-bench/tribe-*/scripts/
# start-colony.sh). Done with awk for portability across macOS bash 3.2.
if [ "$NO_FORGE" = "1" ]; then
    NF_TMP="$(mktemp)"
    awk '
        /^# BEGIN FORGE_BLOCK$/ {
            print "# Non-forge federation (#373, ADR-0003). The colony.example.toml"
            print "# declares forge.type = \"none\" so colony-lint accepts the config"
            print "# without a [forge.gitlab] / [forge.github] sub-block; no agent"
            print "# in this colony calls forge-api.sh. Replace TODO env vars below"
            print "# with whatever your data source needs (data warehouse, helpdesk"
            print "# API, on-disk corpus, …)."
            print "# TODO: export DATA_SOURCE_URL / TOKEN / etc. for your .ag agents."
            print "export COLONY_DIR"
            skip = 1
            next
        }
        /^# END FORGE_BLOCK$/ {
            skip = 0
            next
        }
        skip != 1 { print }
    ' "$COL_PATH/scripts/start-colony.sh" > "$NF_TMP"
    mv "$NF_TMP" "$COL_PATH/scripts/start-colony.sh"
else
    # Strip the marker comments — they are only meaningful to the scaffolder.
    sed -i \
        -e '/^# BEGIN FORGE_BLOCK$/d' \
        -e '/^# END FORGE_BLOCK$/d' \
        "$COL_PATH/scripts/start-colony.sh"
fi

chmod +x "$COL_PATH/scripts/start-colony.sh"

# --- Print next steps ---

if [ "$NO_FORGE" = "1" ]; then
    config_step="Edit $COL_PATH/config/colony.example.toml — this federation was scaffolded
     with --no-forge, so the [forge] block declares \`type = \"none\"\` (#373,
     ADR-0003). Wire your real data source (data warehouse, helpdesk API,
     on-disk corpus, …) by adding env vars consumed by your .ag agents via
     exec sh; do NOT add [forge.gitlab] / [forge.github] sub-blocks unless
     this federation grows a forge dependency."
    script_step="Edit $COL_PATH/scripts/start-colony.sh — fill in the AGENTS=() array
     and replace the placeholder \`export COLONY_DIR\` block with whatever
     env vars your agents consume via exec sh. The forge env-wiring case
     statement was omitted because of --no-forge."
else
    config_step="Edit $COL_PATH/config/colony.example.toml — adapt the [forge] block
     (set type to \"gitlab\", \"github\", or \"none\" per #373 / ADR-0003)
     and fill the matching sub-block."
    script_step="Edit $COL_PATH/scripts/start-colony.sh — fill in the AGENTS=() array
     and replace the forge env block with whatever env vars your agents
     consume via exec sh."
fi

cat <<EOF

Federation '$FEDERATION' scaffolded at $FED_PATH/

Next steps:
  1. Edit $FED_PATH/README.md — replace the one-paragraph stub with your
     federation's real domain identity.
  2. Edit $FED_PATH/install.sh — add prerequisite checks + credential prompts
     for your data source (forge, data warehouse, helpdesk API, …).
  3. $config_step
  4. $script_step
  5. Author .ag agents under $COL_PATH/agents/. Tier-gate every external
     write per ADR-0001.
  6. Add '$FEDERATION' to the COMPONENTS array in tools/check-changelog.sh
     so the release-PR check covers it.
  7. Add a row to the top-level README.md Federations table.
  8. Run: ./tools/colony-lint.sh
EOF
