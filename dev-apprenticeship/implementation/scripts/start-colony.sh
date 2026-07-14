#!/bin/bash
# Start the Implementation colony (part of Dev Apprenticeship federation)
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

# Parse forge config from TOML via the shared helper.
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

# #225: configurable trigger label for assigned-issues filter. Empty if
# not configured (pre-#225 setups); the backend wrapper falls back to the
# hardcoded default "implementation" via ${VAR:-implementation}. The label
# itself is backend-agnostic — both gitlab-api.sh and github-api.sh
# consume IMPLEMENTATION_TRIGGER_LABEL identically.
IMPLEMENTATION_TRIGGER_LABEL=$(parse_toml implementation trigger_label)

# #291: require_assignee knob. When "false" (the new default), code_writer's
# action path also fires on labeled-but-unassigned issues — the normal state
# on most repos. Existing operators who want to keep the pre-#291 contributor-
# hand-off behaviour set require_assignee = true in [implementation].
IMPLEMENTATION_REQUIRE_ASSIGNEE=$(parse_toml implementation require_assignee)
IMPLEMENTATION_REQUIRE_ASSIGNEE="${IMPLEMENTATION_REQUIRE_ASSIGNEE:-true}"

# #1537 M3: the caller-driven edit loop (#1354) is now the SOLE editing path —
# code_writer.ag always drives the attempt/continuation/verify/finalize state
# machine itself (ag_edit_step for ordinary issues, ag_decompose_step for
# epics). The AG_DRIVEN_EDIT_LOOP opt-out and its [implementation]
# ag_driven_edit_loop key are retired; there is no longer an in-shell
# multi-attempt route to fall back to.

# #224: primary branch name. Read from whichever of [forge.gitlab] or
# [forge.github] the operator selected via [forge].type. The env var
# is kept as GITLAB_DEFAULT_BRANCH for cross-backend parity (both
# backend wrappers consume ${GITLAB_DEFAULT_BRANCH:-main}). PR 7 of
# #256 retired the legacy top-level [gitlab].default_branch fallback.
# #316 M2: under [[forge.github]] array form, pull default_branch from
# entry [0] for back-compat with M2-only deployments. M3 moves
# default_branch into per-repo iteration.
case "$FORGE_TYPE" in
    github)
        if [ "${REPO_COUNT:-0}" = "0" ]; then
            GITLAB_DEFAULT_BRANCH=$(parse_toml forge.github default_branch)
        else
            GITLAB_DEFAULT_BRANCH=$(parse_toml_array_get forge.github 0 default_branch)
        fi
        ;;
    *)
        GITLAB_DEFAULT_BRANCH=$(parse_toml forge.gitlab default_branch)
        ;;
esac

export FORGE_TYPE
export IMPLEMENTATION_TRIGGER_LABEL
export IMPLEMENTATION_REQUIRE_ASSIGNEE
export GITLAB_DEFAULT_BRANCH
export COLONY_DIR
# LLM-session concurrency cap (#1352): pin the slot pool to a fed-FIXED path
# (cwd-independent, derived from this script's location) so EVERY daemon — the
# normal launch AND a `--restart-agent` respawn from a different cwd (e.g. the
# dashboard) — resolves the SAME K-slot semaphore and the cap stays truly
# federation-wide. Without this, tools/lib/llm-session-slot.sh falls back to a
# PWD-relative pool and the cap fragments under restart.
AGENTIS_LLM_SLOTS_DIR="$(cd "$COLONY_DIR/.." && pwd)/.agentis/llm-slots"
export AGENTIS_LLM_SLOTS_DIR

# #316 M5a: --print-repos-json probe for the federation-dashboard collector.
# Emits the GITHUB_REPOS_JSON value (empty string for legacy single-block
# configs) and exits. Probed once per colony per dashboard regen so the
# collector can fan rate-limit + per-(agent, repo) memo lookups out across
# every entry. Placed right after env load so the probe is fast (no daemon
# launches, no memo seeding) and stays cheap to call every refresh cycle.
if [ "${1:-}" = "--print-repos-json" ]; then
    echo "${GITHUB_REPOS_JSON:-}"
    exit 0
fi

# #291: seed code_writer:require_assignee memo so the .ag agent can read the
# knob via recall_latest() and pick the `--include-unassigned` forge flag on
# assigned-issues polls. Skipped on single-agent respawn / rate-limit-status
# for the same reason as the other seeds: bootstrap concern, not per-tick.
if [ -z "$RESTART_AGENT" ] && [ "$RATE_LIMIT_STATUS" = "0" ]; then
    FED_ROOT="$(cd "$REPO_ROOT/dev-apprenticeship" && pwd)"
    (cd "$FED_ROOT" && agentis memo set code_writer:require_assignee "$IMPLEMENTATION_REQUIRE_ASSIGNEE" >/dev/null 2>&1) || true

    # #316 M5a: per-repo trigger label memo seeding. When the colony is
    # configured with [[forge.github]] array form (REPO_COUNT > 0), loop
    # entries and seed `<owner>__<repo>:implementation:labels:trigger` for
    # each entry that declares an inline `labels = { trigger = "..." }`
    # value. Single-block configs (REPO_COUNT=0) skip this loop entirely
    # — implementation has no legacy unscoped trigger memo, only the
    # IMPLEMENTATION_TRIGGER_LABEL env var, so this is purely additive.
    if [ "${REPO_COUNT:-0}" -gt 0 ]; then
        i=0
        while [ "$i" -lt "$REPO_COUNT" ]; do
            ent_owner=$(parse_toml_array_get forge.github "$i" owner)
            ent_repo=$(parse_toml_array_get forge.github "$i" repo)
            ent_trigger=$(parse_toml_array_get_inline forge.github "$i" labels trigger)
            if [ -n "$ent_owner" ] && [ -n "$ent_repo" ] && [ -n "$ent_trigger" ]; then
                (cd "$FED_ROOT" && agentis memo set "${ent_owner}__${ent_repo}:implementation:labels:trigger" "$ent_trigger" >/dev/null 2>&1) || true
            fi
            i=$((i + 1))
        done
    fi
fi

AGENTS=(
    code_writer
    test_writer
    refactorer
    commit_composer
)

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

# Per-agent tick-interval override (#146, retuned #1367). The implementation
# agents are active (code_writer, test_writer, refactorer, commit_composer),
# but on an aligned 60s tick all 21 federation daemons fired prompt() on the
# same boundary and overheated the host (#1367). We STAGGER these four across
# 90000/120000/150000ms so their steady-state ticks interleave rather than
# bunch. code_writer keeps the shortest (90s) since it launches/polls the
# detached edit jobs and benefits from prompt re-polling; the rest stagger
# behind it. Fallback is 120000ms.
tick_interval_for() {
    case "$1" in
        code_writer)     echo 90000 ;;
        commit_composer) echo 120000 ;;
        test_writer)     echo 120000 ;;
        refactorer)      echo 150000 ;;
        *)               echo 120000 ;;
    esac
}

# Per-tick cognitive-budget cap override (#1115). Config-driven, mirroring
# the per-agent tick-interval pattern (#146): a per-agent `cb_per_tick` under
# the matching `[[agents]]` entry wins; otherwise the colony-wide
# `[colony].cb_per_tick` default applies; otherwise the federation-wide
# fallback (2000, matching `daemon.cb_per_tick` in `<fed>/.agentis/config`
# written by install.sh). Spliced onto every `agentis daemon` launch as
# `--cb-per-tick <n>` so a runaway tick cannot burn the whole budget in one
# pass. The flag is a real `agentis daemon` flag (unlike `--config-override`,
# #351), so this lands on the binary.
CB_PER_TICK_DEFAULT="$(parse_toml colony cb_per_tick)"
case "$CB_PER_TICK_DEFAULT" in
    ''|*[!0-9]*) CB_PER_TICK_DEFAULT=2000 ;;
    *) [ "$CB_PER_TICK_DEFAULT" -gt 0 ] || CB_PER_TICK_DEFAULT=2000 ;;
esac

cb_per_tick_for() {
    local want="$1"
    local n i name val
    n="$(parse_toml_array_count agents 2>/dev/null || echo 0)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    i=0
    while [ "$i" -lt "$n" ]; do
        name="$(parse_toml_array_get agents "$i" name 2>/dev/null || echo '')"
        if [ "$name" = "$want" ]; then
            val="$(parse_toml_array_get agents "$i" cb_per_tick 2>/dev/null || echo '')"
            case "$val" in
                ''|*[!0-9]*) : ;;
                *) if [ "$val" -gt 0 ]; then echo "$val"; return 0; fi ;;
            esac
            break
        fi
        i=$((i + 1))
    done
    echo "$CB_PER_TICK_DEFAULT"
}

# Per-daemon prompt-timeout-s cap (#1203). The `agentis daemon`
# `--prompt-timeout-s` flag (#649) defaults to 120s and OVERRIDES
# `llm.cli_timeout_ms`, so a large-context flat-cyborg round-trip (>120s, e.g.
# editing a ~47KB README) gets killed mid-prompt and surfaces as
# `[llm.cancelled]`. We resolve a wall-clock cap from `[colony].prompt_timeout_s`
# when set (positive integer), else default 300s — generous enough for big
# files on the flat-cyborg backend — and splice it onto every `agentis daemon`
# launch as `--prompt-timeout-s "$PROMPT_TIMEOUT_S"` (a real daemon flag, like
# `--cb-per-tick`). Mirrors the CB_PER_TICK_DEFAULT validation shape.
PROMPT_TIMEOUT_S="$(parse_toml colony prompt_timeout_s)"
case "$PROMPT_TIMEOUT_S" in
    ''|*[!0-9]*) PROMPT_TIMEOUT_S=300 ;;
    *) [ "$PROMPT_TIMEOUT_S" -gt 0 ] || PROMPT_TIMEOUT_S=300 ;;
esac

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
    # #285: kill any pre-existing daemon for this agent before respawning —
    # otherwise every restart silently accumulates another live daemon-inner
    # process (the registry collapses duplicates by agent_id, so they are
    # invisible from `agentis daemon list`). The kill/poll/verify machine
    # itself (registry query, SIGTERM, 5s exit poll, SIGKILL escalation,
    # sidecar cleanup) is shared by all five colonies via
    # tools/lib/daemon-restart.sh (#1357); see
    # doc/adr/daemon-restart-supervision.md for the supervision end state.
    FED_ROOT="$(cd "$REPO_ROOT/dev-apprenticeship" && pwd)"
    # shellcheck source=../../../tools/lib/daemon-restart.sh
    # shellcheck disable=SC1091  # colony-lint runs shellcheck without -x
    . "$REPO_ROOT/tools/lib/daemon-restart.sh"
    daemon_restart_kill_existing "$FED_ROOT" implementation "$RESTART_AGENT"
    tick=$(tick_interval_for "$RESTART_AGENT")
    cb=$(cb_per_tick_for "$RESTART_AGENT")
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
        --colony implementation \
        --enable-exec \
        --enable-messaging \
        --tick-interval "$tick" \
        --cb-per-tick "$cb" \
        --prompt-timeout-s "$PROMPT_TIMEOUT_S" \
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

echo "Starting Implementation colony (${#AGENTS[@]} agents)..."
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
    cb=$(cb_per_tick_for "$agent")
    echo "  Starting $agent (tick=${interval}ms, cb-per-tick=${cb})..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony implementation \
        --enable-exec \
        --enable-messaging \
        --tick-interval "$interval" \
        --cb-per-tick "$cb" \
        --prompt-timeout-s "$PROMPT_TIMEOUT_S" \
        ${CC_ARGS[@]+"${CC_ARGS[@]}"} &
    sleep 2  # stagger starts to reduce API contention
done

echo "Colony started. Use 'agentis daemon list' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
