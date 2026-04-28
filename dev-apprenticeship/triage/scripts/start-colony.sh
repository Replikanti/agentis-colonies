#!/bin/bash
# Start the Triage colony (part of Dev Apprenticeship federation)
#
# Each agent runs as a separate agentis daemon process.
# They discover each other via colony UDP and communicate over TCP emit/listen.
#
# Usage:
#   ./scripts/start-colony.sh [path/to/colony.toml]
#   ./scripts/start-colony.sh --restart-agent <name> [path/to/colony.toml]
#
# --restart-agent mode (#257) respawns exactly one agent with the full colony
# env, skips log truncation and memo seeding (those are full-colony bootstrap
# concerns), and exits 0 on success with a single "started ... pid=... tick=..."
# line on stdout for the dashboard to parse. Exit codes: 0=ok, 2=unknown flag,
# 3=unknown agent name for this colony, 4=daemon launch failure.
#
# --rate-limit-status mode (federation-dashboard 0.3.0) reuses the env-load
# path and execs `forge-api.sh rate-limit-status`, printing the JSON contract
# `{remaining, limit, reset_at}` to stdout. Used by the dashboard's rate-limit
# tile so it can surface remaining API budget per colony without parsing
# colony.toml itself (the #257 decoupling principle).

set -e

# Parse flags. --restart-agent <name> swaps the script into single-agent
# respawn mode; --rate-limit-status execs forge-api.sh rate-limit-status
# instead of launching daemons. Positional arg (if any) remains the config
# path, for backwards compatibility with pre-#257 callers.
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

# Resolve symlinks on $0 itself so the script works when invoked via a symlink.
SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
COLONY_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="${1:-$COLONY_DIR/config/colony.toml}"

if [ ! -f "$CONFIG" ]; then
    echo "Config not found: $CONFIG"
    echo "Copy config/colony.example.toml to config/colony.toml and edit it."
    exit 1
fi

# Parse GitLab config from TOML via the shared helper.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../../tools/parse-toml.sh
# shellcheck disable=SC1091  # colony-lint runs shellcheck without -x
. "$REPO_ROOT/tools/parse-toml.sh"

# #256: forge backend selection. `[forge].type` picks which backend
# wrapper forge-api.sh dispatches to. Legal values: "gitlab", "github".
# PR 7 of #256 (MAJOR bump) made `[forge]` authoritative and retired
# the legacy top-level `[gitlab]` section. `parse_toml forge type`
# defaults to "gitlab" when unset so a fresh colony.toml that lists
# only `[forge.gitlab]` without the selector still launches cleanly.
FORGE_TYPE=$(parse_toml forge type)
FORGE_TYPE="${FORGE_TYPE:-gitlab}"

case "$FORGE_TYPE" in
    gitlab)
        # PR 7 of #256 (MAJOR bump) made [forge.gitlab] authoritative.
        # The legacy top-level [gitlab] fallback branches retired here.
        GITLAB_URL=$(parse_toml forge.gitlab url)
        GITLAB_TOKEN=$(parse_toml forge.gitlab token)
        GITLAB_PROJECT_RAW=$(parse_toml forge.gitlab project)
        GITLAB_ME=$(parse_toml forge.gitlab me)

        if [ -z "$GITLAB_URL" ] || [ -z "$GITLAB_TOKEN" ] || [ -z "$GITLAB_PROJECT_RAW" ]; then
            echo "Error: GitLab config incomplete in $CONFIG"
            echo "Required: url, token, project under [forge.gitlab]"
            exit 1
        fi

        # URL-encode the project path (replace / with %2F)
        GITLAB_PROJECT="${GITLAB_PROJECT_RAW//\//%2F}"

        export GITLAB_URL
        export GITLAB_TOKEN
        export GITLAB_PROJECT
        export GITLAB_ME
        ;;
    github)
        # #316 M2: detect single-block [forge.github] vs array-of-tables
        # [[forge.github]]. parse_toml_array_count returns 0 for the legacy
        # single-table shape, N>0 for the new shape. M1's lint guarantees
        # exactly one shape is present (both-forms is a hard fail).
        REPO_COUNT=$(parse_toml_array_count forge.github)
        REPO_COUNT="${REPO_COUNT:-0}"

        if [ "$REPO_COUNT" = "0" ]; then
            # Legacy single-block path — byte-identical to pre-#316 behaviour.
            GITHUB_URL=$(parse_toml forge.github url)
            GITHUB_URL="${GITHUB_URL:-https://api.github.com}"
            GITHUB_OWNER=$(parse_toml forge.github owner)
            GITHUB_REPO=$(parse_toml forge.github repo)
            GITHUB_TOKEN=$(parse_toml forge.github token)
            GITHUB_ME=$(parse_toml forge.github me)

            if [ -z "$GITHUB_OWNER" ] || [ -z "$GITHUB_REPO" ] || [ -z "$GITHUB_TOKEN" ]; then
                echo "Error: GitHub config incomplete in $CONFIG"
                echo "Required: owner, repo, token under [forge.github]"
                exit 1
            fi

            export GITHUB_URL GITHUB_OWNER GITHUB_REPO GITHUB_TOKEN GITHUB_ME
            # GITHUB_REPOS_JSON intentionally NOT exported on this path —
            # M3 agents probe `${GITHUB_REPOS_JSON:-}` and fall back to the
            # single-repo flow when empty.
        else
            # #316 M2: multi-block path. Build a JSON array of every entry
            # and export as GITHUB_REPOS_JSON; back-compat-export entry [0]
            # as GITHUB_OWNER/GITHUB_REPO/etc. so M2-only deployments (no
            # M3 agents yet) keep working against the first repo.
            REPOS_JSON_TMP=""
            FIRST_OWNER=""; FIRST_REPO=""; FIRST_TOKEN=""; FIRST_URL=""; FIRST_ME=""
            i=0
            while [ "$i" -lt "$REPO_COUNT" ]; do
                ent_url=$(parse_toml_array_get forge.github "$i" url)
                ent_url="${ent_url:-https://api.github.com}"
                ent_owner=$(parse_toml_array_get forge.github "$i" owner)
                ent_repo=$(parse_toml_array_get forge.github "$i" repo)
                ent_token=$(parse_toml_array_get forge.github "$i" token)
                ent_me=$(parse_toml_array_get forge.github "$i" me)

                if [ -z "$ent_owner" ] || [ -z "$ent_repo" ] || [ -z "$ent_token" ]; then
                    echo "Error: GitHub config incomplete in $CONFIG" >&2
                    echo "Required: owner, repo, token under [[forge.github]] entry [$i]" >&2
                    exit 1
                fi

                if [ "$i" = "0" ]; then
                    FIRST_URL="$ent_url"; FIRST_OWNER="$ent_owner"; FIRST_REPO="$ent_repo"
                    FIRST_TOKEN="$ent_token"; FIRST_ME="$ent_me"
                fi

                # Build per-entry JSON via env (NEVER argv — tokens stay off `ps`).
                ent_json=$(GH_URL="$ent_url" GH_OWNER="$ent_owner" GH_REPO="$ent_repo" \
                           GH_TOKEN="$ent_token" GH_ME="$ent_me" \
                    python3 -c 'import json,os; print(json.dumps({"url":os.environ["GH_URL"],"owner":os.environ["GH_OWNER"],"repo":os.environ["GH_REPO"],"token":os.environ["GH_TOKEN"],"me":os.environ.get("GH_ME","")}))')

                if [ -z "$REPOS_JSON_TMP" ]; then
                    REPOS_JSON_TMP="$ent_json"
                else
                    REPOS_JSON_TMP="$REPOS_JSON_TMP,$ent_json"
                fi
                i=$((i + 1))
            done

            GITHUB_REPOS_JSON="[$REPOS_JSON_TMP]"
            GITHUB_URL="$FIRST_URL"; GITHUB_OWNER="$FIRST_OWNER"; GITHUB_REPO="$FIRST_REPO"
            GITHUB_TOKEN="$FIRST_TOKEN"; GITHUB_ME="$FIRST_ME"

            export GITHUB_URL GITHUB_OWNER GITHUB_REPO GITHUB_TOKEN GITHUB_ME GITHUB_REPOS_JSON
        fi
        ;;
    *)
        echo "Error: unknown [forge].type '$FORGE_TYPE' in $CONFIG (expected: gitlab|github)" >&2
        exit 1
        ;;
esac

export FORGE_TYPE
export COLONY_DIR

AGENTS=(
    issue_creator
    labeler
    prioritizer
    router
)

# #226: vocabulary memo seeding. Operator-tuned priority label vocabulary
# overrides the hardcoded defaults baked into the prioritizer prompts.
# Read from colony.toml on every restart so config edits take effect on
# the next start-colony cycle (no install.sh re-run). Failures are
# non-fatal: the agent falls back to the pre-#226 hardcoded strings via
# the `recall_latest() / if len() > 0` pattern.
# #257: only seed on full-colony launch, not on single-agent respawn —
# memo seeding is bootstrap, not per-tick.
if [ -z "$RESTART_AGENT" ] && [ "$RATE_LIMIT_STATUS" = "0" ]; then
    PRIORITY_LABELS=$(parse_toml triage.labels priority)
    FED_ROOT="$(cd "$REPO_ROOT/dev-apprenticeship" && pwd)"
    if [ -n "$PRIORITY_LABELS" ]; then
        (cd "$FED_ROOT" && agentis memo set triage:labels:priority "$PRIORITY_LABELS" >/dev/null 2>&1) || true
    fi
fi

# Opt-in log truncation. Off by default so operators who rely on log
# history across restarts are not surprised. Set TRUNCATE_LOGS=1 in
# the environment (or via start-federation.sh) to bound disk use
# between manual restarts. Real log rotation should use the
# logrotate.conf sample in ops/ instead; this is the zero-config
# fallback for laptops that do not have logrotate configured.
# #257: skip on single-agent respawn — log truncation is a full-colony
# fresh-start concern; clobbering a single agent's log surprises operators
# and erases the timeline the dashboard is about to render.
if [ -z "$RESTART_AGENT" ] && [ "$RATE_LIMIT_STATUS" = "0" ] && [ "${TRUNCATE_LOGS:-0}" = "1" ]; then
    AGENTIS_LOGS="$REPO_ROOT/dev-apprenticeship/.agentis/logs"
    if [ -d "$AGENTIS_LOGS" ]; then
        for agent in "${AGENTS[@]}"; do
            : > "$AGENTIS_LOGS/${agent}.log" 2>/dev/null || true
        done
    fi
fi

# #319 PR 1: per-colony LLM backend override. The optional [llm] block
# in colony.toml lets a colony pin its own backend / command / model /
# api_key_env. When any key is set we splice it as `--config-override
# llm.<key>=<value>` onto every daemon CLI; absent keys inherit the
# federation-wide default from `<fed>/.agentis/config`. The cost-cap
# downgrade override file (read below) takes precedence over this block.
# `--enable-exec` is required since agentis v1.1.6 (exec sh is opt-in; see #484/#489).
# `--enable-messaging` is required for cross-agent emit/listen (#484, v1.1.6+).

# Per-agent tick-interval override (#146). Mixed colony: issue_creator and
# labeler are active (they produce work on every tick driven by incoming
# issues) and stay on the 60s default; router and prioritizer are reactive
# (periodic routing sweeps, re-ranking) and run at 3-min cadence since
# minute-grained latency on priority changes is not observable. Fallback is
# 60000ms.
tick_interval_for() {
    case "$1" in
        router|prioritizer) echo 180000 ;;
        *)                  echo 60000 ;;
    esac
}

# #319 PR 1 + #318: combined LLM-config override emitter.
#
# Precedence (highest first):
#   1. <fed>/.agentis/llm-backend-override file written by tools/cost-cap.sh
#      on a metered breach. Today the file is a single line containing the
#      backend name (e.g. "mock"); future PRs in #319 generalise this to a
#      small TOML doc. When this file exists we emit ONLY the override-file
#      backend and ignore the colony [llm] block — downgrade should be a
#      clean snap to mock without leaking colony-specific keys.
#   2. [llm] block in colony.toml (this PR). Each set key emits one
#      `--config-override llm.<key>=<value>` flag pair.
#   3. Federation-wide default from <fed>/.agentis/config (consumed by
#      agentis daemon directly when no overrides are spliced).
#
# Each line of stdout is one CLI token; the caller reads the stream into
# the CC_ARGS bash array via `while IFS= read -r line` so quoting is preserved.
llm_override_args() {
    # NOTE: `agentis daemon` does NOT accept `--config-override` (#351 — the
    # flag is in upstream's release-notes / colonies CLAUDE.md but never landed
    # on the actual binary as of agentis 1.4.7). Emitting it makes every
    # respawn die with `unknown flag: --config-override`, breaking restart on
    # any colony that has either a `[llm]` block or a cost-cap downgrade
    # override file.
    #
    # Until the upstream flag lands, we emit nothing here. Colonies fall back
    # to the federation-wide `<fed>/.agentis/config` for `llm.*` keys, which
    # is the same behaviour as pre-#348 federations. The colony.toml `[llm]`
    # block stays in the schema as a forward-compatible documentation surface
    # so operators don't have to delete it before the upstream fix; it just
    # has no runtime effect today.
    #
    # Cost-cap downgrade (#318) is also affected — the `<fed>/.agentis/llm-
    # backend-override` file write succeeds but the spliced flag was always
    # rejected by the binary, so the breach path never actually re-spawned
    # daemons on `mock`. A follow-up coordinated with upstream restores the
    # primitive once the flag exists.
    :
}

# Rate-limit status mode (federation-dashboard 0.3.0). Same env-load path
# as --restart-agent but execs forge-api.sh rate-limit-status and exits.
# Skips the daemon launch entirely; safe to invoke every dashboard refresh
# (60s) since it is a single read-only API call per colony.
if [ "$RATE_LIMIT_STATUS" = "1" ]; then
    exec "$COLONY_DIR/scripts/forge-api.sh" rate-limit-status
fi

# #257: single-agent respawn path. Dashboard's /restart endpoint delegates
# here instead of reading [gitlab] config itself. All env exports above
# already happened; we validate the agent name, launch exactly one daemon,
# emit one parseable line on stdout, and exit.
if [ -n "$RESTART_AGENT" ]; then
    valid=0
    for a in "${AGENTS[@]}"; do
        [ "$a" = "$RESTART_AGENT" ] && valid=1
    done
    if [ "$valid" = "0" ]; then
        echo "start-colony.sh: unknown agent '$RESTART_AGENT' for this colony" >&2
        exit 3
    fi
    # #285: kill any pre-existing daemon for this agent before respawning.
    # The daemon registry (`agentis daemon list`) indexes by agent_id and
    # collapses duplicates to a single entry, so a silently-accumulated old
    # daemon-inner process is invisible from that view. Query the JSON form by
    # colony + source-path suffix (backend-agnostic), SIGTERM the live PID,
    # poll every 0.2s × 25 iterations (5s) for exit, SIGKILL survivors + 1s
    # settle. Best-effort sidecar cleanup afterwards so the registry does
    # not carry a stale pointer to the dead agent_id. Pattern mirrors
    # tools/kill-federation.sh (#161/#162) applied at per-agent scope.
    FED_ROOT="$(cd "$REPO_ROOT/dev-apprenticeship" && pwd)"
    # `agentis daemon list` is a read-only registry query, not a daemon launch;
    # the indirection via AGENTIS_BIN keeps colony-lint's launch-flag whitelist
    # (#68/#71) from misreading `--json` as a daemon flag on the same line.
    AGENTIS_BIN=agentis
    # shellcheck disable=SC2015 # pipe to python3, not an if-then-else
    existing_entry="$(cd "$FED_ROOT" && "$AGENTIS_BIN" daemon list --json 2>/dev/null | python3 -c '
import json, sys
try:
    daemons = json.load(sys.stdin)
except Exception:
    sys.exit(0)
colony = sys.argv[1]
suffix = "/agents/" + sys.argv[2] + ".ag"
for d in daemons:
    if d.get("colony") == colony and str(d.get("source", "")).endswith(suffix):
        pid = d.get("pid")
        aid = d.get("agent_id", "") or ""
        if isinstance(pid, int) and pid > 0:
            print("%d|%s" % (pid, aid))
            break
' triage "$RESTART_AGENT" 2>/dev/null || true)"
    existing_pid="${existing_entry%%|*}"
    existing_agent_id="${existing_entry#*|}"
    [ "$existing_pid" = "$existing_entry" ] && existing_agent_id=""
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        kill -TERM "$existing_pid" 2>/dev/null || true
        i=0
        while [ "$i" -lt 25 ]; do
            kill -0 "$existing_pid" 2>/dev/null || break
            sleep 0.2
            i=$((i + 1))
        done
        if kill -0 "$existing_pid" 2>/dev/null; then
            kill -KILL "$existing_pid" 2>/dev/null || true
            sleep 1
        fi
    fi
    if [ -n "$existing_agent_id" ]; then
        for ext in pid watchdog.pid colony heartbeat status stop; do
            rm -f "$FED_ROOT/.agentis/daemon/${existing_agent_id}.${ext}" 2>/dev/null || true
        done
    fi
    tick=$(tick_interval_for "$RESTART_AGENT")
    # Detach daemon stdio from any inherited pipes (e.g. the dashboard's
    # subprocess.run(capture_output=True) pipes). Without this, the daemon
    # keeps those fds open after start-colony.sh exits, and the Python
    # caller blocks on read until its own timeout — reporting spurious
    # "restart failed" even though the agent came up fine.
    CC_ARGS=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        CC_ARGS+=("$line")
    done < <(llm_override_args)
    agentis daemon "$COLONY_DIR/agents/${RESTART_AGENT}.ag" \
        --colony triage \
        --enable-exec \
        --enable-messaging \
        --tick-interval "$tick" \
        ${CC_ARGS[@]+"${CC_ARGS[@]}"} </dev/null >/dev/null 2>&1 &
    agent_pid=$!
    sleep 0.5
    if ! kill -0 "$agent_pid" 2>/dev/null; then
        echo "start-colony.sh: agentis daemon failed to launch $RESTART_AGENT" >&2
        exit 4
    fi
    echo "started $RESTART_AGENT pid=$agent_pid tick=$tick"
    exit 0
fi

echo "Starting Triage colony (${#AGENTS[@]} agents)..."
case "$FORGE_TYPE" in
    gitlab) echo "  GitLab: $GITLAB_URL ($GITLAB_PROJECT_RAW)" ;;
    github) echo "  GitHub: $GITHUB_URL ($GITHUB_OWNER/$GITHUB_REPO)" ;;
esac

CC_ARGS=()
while IFS= read -r line; do
    [ -z "$line" ] && continue
    CC_ARGS+=("$line")
done < <(llm_override_args)
for agent in "${AGENTS[@]}"; do
    interval=$(tick_interval_for "$agent")
    echo "  Starting $agent (tick=${interval}ms)..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony triage \
        --enable-exec \
        --enable-messaging \
        --tick-interval "$interval" \
        ${CC_ARGS[@]+"${CC_ARGS[@]}"} &
    sleep 2  # stagger starts to reduce API contention
done

echo "Colony started. Use 'agentis daemon list' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
