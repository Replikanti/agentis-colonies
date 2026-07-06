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
SNAPSHOT_REFRESH=0
INGEST_REFRESH=0
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
        --snapshot-refresh)
            # #1111: re-run the shared-snapshot publish step and exit. Lets a
            # lightweight sidecar (or start-federation.sh) refresh the
            # per-colony GitLab snapshot every tick without re-bootstrapping
            # the colony. Reuses the full env-load path below.
            SNAPSHOT_REFRESH=1
            shift
            ;;
        --ingest)
            # #1431: run the incremental crystallizer ingestion and exit.
            # Distills operator decisions (labels / assignees / priority
            # labels) updated since the triage:ingest:cursor memo into the
            # federation KnowledgeBase via tools/backfill-crystallizer.sh
            # --incremental, so the rule pool keeps tracking the operator
            # even on issues the agents never touched. Reuses the full
            # env-load path below (forge tokens included) exactly like
            # --snapshot-refresh; invoked by the start-federation.sh ingest
            # sidecar or manually by the operator.
            INGEST_REFRESH=1
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

AGENTS=(
    issue_creator
    labeler
    prioritizer
    router
)

# #1111/#1112: publish ONE shared GitLab snapshot per colony per tick.
#
# Fetches the issues collection exactly once via forge-api.sh (the single
# fetch implementation), compresses it (#1112, snapshot-compress.py inside
# the backend wrapper), and writes the compact envelope to the shared
# `gitlab:snapshot:issues` memo plus an epoch-seconds freshness key at
# `gitlab:snapshot:issues:ts`. Every triage agent then reads that memo via
# recall_latest() instead of each curling /issues — collapsing the former
# 3x-per-tick duplicate fetch (labeler + router + prioritizer; +
# issue_creator) down to one.
#
# Total-on-failure: a fetch/compress failure leaves the prior snapshot (and
# its ts) in place; agents see a stale ts and degrade to a direct fetch.
# We only publish a snapshot that parses to a non-empty envelope, so a
# transient error never overwrites a good snapshot with `[]`.
publish_snapshot() {
    local fed_root="$1"
    local snap
    snap="$("$COLONY_DIR/scripts/forge-api.sh" snapshot issues 2>/dev/null)" || return 0
    # Guard: only publish a structurally-valid, non-empty envelope. The
    # compressed empty form is `{"chunks":[],...,"count":0,...}`; refuse to
    # clobber a good snapshot with an empty one on a transient fetch error.
    local ok
    ok="$(SNAP="$snap" python3 -c 'import os,json,sys
try:
    e=json.loads(os.environ["SNAP"])
    sys.stdout.write("1" if isinstance(e,dict) and e.get("count",0)>0 else "0")
except Exception:
    sys.stdout.write("0")' 2>/dev/null || printf '0')"
    if [ "$ok" != "1" ]; then
        return 0
    fi
    local now
    now="$(date +%s)"
    (cd "$fed_root" && agentis memo set gitlab:snapshot:issues "$snap" >/dev/null 2>&1) || true
    (cd "$fed_root" && agentis memo set gitlab:snapshot:issues:ts "$now" >/dev/null 2>&1) || true
}

# #1111: --snapshot-refresh mode. Re-publish the shared snapshot and exit.
# Same env-load path as --rate-limit-status; safe to invoke every tick from
# a sidecar. No daemon launches, no memo seeding, no log truncation.
if [ "$SNAPSHOT_REFRESH" = "1" ]; then
    SNAP_FED_ROOT="$(cd "$REPO_ROOT/dev-apprenticeship" && pwd)"
    publish_snapshot "$SNAP_FED_ROOT"
    exit 0
fi

# #1431: --ingest mode. Incremental crystallizer ingestion and exit. Same
# env-load path as --snapshot-refresh (forge tokens exported above), so the
# backfill tool's forge fetch authenticates without any extra wiring. The
# tool is total-on-failure operationally: a fetch/driver failure exits
# non-zero and the sidecar logs it, but nothing in the colony is mutated
# beyond the already-idempotent learn/distill/validate rows.
if [ "$INGEST_REFRESH" = "1" ]; then
    INGEST_FED_ROOT="$(cd "$REPO_ROOT/dev-apprenticeship" && pwd)"
    exec "$REPO_ROOT/tools/backfill-crystallizer.sh" \
        --fed-dir "$INGEST_FED_ROOT" --colony-dir "$COLONY_DIR" --incremental
fi

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

    # #316 M5a: per-repo trigger label memo seeding. When the colony is
    # configured with [[forge.github]] array form (REPO_COUNT > 0), loop
    # entries and seed `<owner>__<repo>:triage:labels:trigger` for each
    # entry that declares an inline `labels = { trigger = "..." }` value.
    # Single-block configs (REPO_COUNT=0) skip this loop entirely so the
    # legacy unscoped seed above stays the only memo write — preserves
    # byte-identity for v1.3.0 operators.
    if [ "${REPO_COUNT:-0}" -gt 0 ]; then
        i=0
        while [ "$i" -lt "$REPO_COUNT" ]; do
            ent_owner=$(parse_toml_array_get forge.github "$i" owner)
            ent_repo=$(parse_toml_array_get forge.github "$i" repo)
            ent_trigger=$(parse_toml_array_get_inline forge.github "$i" labels trigger)
            if [ -n "$ent_owner" ] && [ -n "$ent_repo" ] && [ -n "$ent_trigger" ]; then
                (cd "$FED_ROOT" && agentis memo set "${ent_owner}__${ent_repo}:triage:labels:trigger" "$ent_trigger" >/dev/null 2>&1) || true
            fi
            i=$((i + 1))
        done
    fi

    # #1111: seed the shared GitLab snapshot once on full-colony bootstrap so
    # the first tick of every agent already reads the memo instead of
    # cold-curling /issues. A sidecar (or the next bootstrap) keeps it fresh
    # via `--snapshot-refresh`. Best-effort: a fetch failure here just means
    # the first tick falls back to a direct fetch (backward-safe).
    publish_snapshot "$FED_ROOT"
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

# Per-agent tick-interval override (#146, retuned #1367). Mixed colony: router
# and prioritizer are reactive (periodic routing sweeps, re-ranking) and run at
# 3-min cadence since minute-grained latency on priority changes is not
# observable. issue_creator and labeler are active, but an aligned 60s tick
# bunched every federation daemon on one boundary and overheated the host
# (#1367), so they are STAGGERED across 90000/120000ms to interleave with the
# other active colonies. Fallback is 120000ms.
tick_interval_for() {
    case "$1" in
        router|prioritizer) echo 180000 ;;
        issue_creator)      echo 90000 ;;
        labeler)            echo 120000 ;;
        *)                  echo 120000 ;;
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
    daemon_restart_kill_existing "$FED_ROOT" triage "$RESTART_AGENT"
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
        --colony triage \
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
    cb=$(cb_per_tick_for "$agent")
    echo "  Starting $agent (tick=${interval}ms, cb-per-tick=${cb})..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony triage \
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
