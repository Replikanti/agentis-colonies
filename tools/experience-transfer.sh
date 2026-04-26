#!/usr/bin/env bash
# experience-transfer.sh - Bootstrap a fresh federation from a healthy
# federation's per-agent experience JSONL (#323).
#
# A donor federation EXPORTs its `<resolved-agentis>/experience/*.jsonl`
# stream, keyed by agent NAME (not by `agent_id`, since IDs are
# sha8(...)-derived and never line up across federations). The recipient
# IMPORTs the pack and remaps name -> current target `agent_id`, then
# appends to its own experience store. The first auto-promote tick on
# the recipient counts those rows toward `min_entries` /
# `min_acting_entries`, so a fresh install can leave `shadow` in hours
# instead of weeks.
#
# Knowledge transfer (the second track called out in #323) is **not**
# implemented here — it reuses the existing upstream
# `agentis knowledge export | import` CLI verbatim. Operator instructions
# live in dev-apprenticeship/README.md.
#
# Usage:
#     ./tools/experience-transfer.sh export <fed-dir> [--out PATH]
#         [--since YYYY-MM-DD] [--tags t1,t2]
#         [--max-rows-per-agent N] [--scrub] [--donor-name NAME]
#     ./tools/experience-transfer.sh import <fed-dir> <pack.tar.gz>
#         [--json]
#
# Path hygiene: matches the dashboard wrapper's three-step `.agentis`
# resolver (`<fed>/.agentis` -> `<fed>/../.agentis` -> `.agentis`) so it
# works on the symlinked layout produced by dev-apprenticeship/install.sh
# (every colony's `.agentis` is a symlink to <repo-root>/.agentis).
#
# macOS bash 3.2 portable: no heredocs, no associative arrays, no
# `${var^^}` / `${var,,}`, no `mapfile` / `readarray`. JSONL / tar /
# scrub / dedupe logic lives in the Python sibling
# `tools/experience-transfer-pack.py` — same delegation pattern as
# `tools/cost-cap-sum.py` and `tools/auto-promote-decisions.py`.

set -eu

# --- Path resolution ---

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PACK_HELPER="$SCRIPT_DIR/experience-transfer-pack.py"

if [ ! -f "$PACK_HELPER" ]; then
    echo "Pack helper missing: $PACK_HELPER" >&2
    exit 2
fi

usage() {
    echo "Usage:"
    echo "  $0 export <fed-dir> [--out PATH] [--since YYYY-MM-DD]"
    echo "                      [--tags t1,t2] [--max-rows-per-agent N]"
    echo "                      [--scrub] [--donor-name NAME]"
    echo "  $0 import <fed-dir> <pack.tar.gz> [--json]"
    exit 1
}

# Resolve <fed-dir> against $REPO_ROOT first (the convenience form
# `dev-apprenticeship`), then as a literal path. Matches the resolver
# in tools/auto-promote.sh and tools/cost-cap.sh.
resolve_fed_dir() {
    fed_input="$1"
    if [ -d "$REPO_ROOT/$fed_input" ]; then
        echo "$REPO_ROOT/$fed_input"
    elif [ -d "$fed_input" ]; then
        # Print the absolute path so the helper does not have to
        # second-guess relative inputs after we cd elsewhere.
        (cd "$fed_input" && pwd)
    else
        echo ""
    fi
}

# Prefetch the live daemon list JSON for the given fed_dir. We call
# agentis from inside the federation directory so the CLI finds the
# right `.agentis/`. On any failure (federation stopped, agentis
# missing from PATH, parse error) we emit `[]` — the helper's offline
# fallback resolver picks up the slack.
fetch_daemons_json() {
    fed="$1"
    if ! command -v agentis >/dev/null 2>&1; then
        printf '%s' "[]"
        return
    fi
    # Subshell wrapping isolates `cd` failure and silences shellcheck SC2015
    # — the `|| :` keeps the assignment safe under `set -e` even when the
    # `cd` or `agentis daemon list` step exits non-zero.
    out="$( (cd "$fed" && agentis daemon list --json) 2>/dev/null || : )"
    if [ -z "$out" ]; then
        printf '%s' "[]"
        return
    fi
    # Smoke-test that it parses as JSON; otherwise fall back to [].
    # `python3 -c 'json.loads(sys.argv[1])'` keeps the parse off-stdin
    # so this stays heredoc-free.
    if python3 -c 'import json,sys; json.loads(sys.argv[1])' "$out" >/dev/null 2>&1; then
        printf '%s' "$out"
    else
        printf '%s' "[]"
    fi
}

# --- Subcommand dispatch ---

if [ $# -lt 2 ]; then
    usage
fi

CMD="$1"; shift
FED_INPUT="$1"; shift
FED_DIR="$(resolve_fed_dir "$FED_INPUT")"
if [ -z "$FED_DIR" ]; then
    echo "Federation directory not found: $FED_INPUT" >&2
    exit 2
fi

case "$CMD" in
    export)
        OUT_PATH=""
        SINCE=""
        TAGS=""
        MAX_ROWS=""
        SCRUB=0
        DONOR_NAME=""

        while [ $# -gt 0 ]; do
            case "$1" in
                --out)
                    if [ $# -lt 2 ]; then echo "--out needs PATH" >&2; exit 1; fi
                    OUT_PATH="$2"; shift 2
                    ;;
                --since)
                    if [ $# -lt 2 ]; then echo "--since needs YYYY-MM-DD" >&2; exit 1; fi
                    SINCE="$2"; shift 2
                    ;;
                --tags)
                    if [ $# -lt 2 ]; then echo "--tags needs CSV" >&2; exit 1; fi
                    TAGS="$2"; shift 2
                    ;;
                --max-rows-per-agent)
                    if [ $# -lt 2 ]; then echo "--max-rows-per-agent needs N" >&2; exit 1; fi
                    MAX_ROWS="$2"; shift 2
                    ;;
                --scrub)
                    SCRUB=1; shift
                    ;;
                --donor-name)
                    if [ $# -lt 2 ]; then echo "--donor-name needs NAME" >&2; exit 1; fi
                    DONOR_NAME="$2"; shift 2
                    ;;
                *)
                    echo "Unknown export flag: $1" >&2
                    usage
                    ;;
            esac
        done

        if [ -z "$OUT_PATH" ]; then
            OUT_PATH="$(pwd)/experience-transfer-pack.tar.gz"
        fi

        DAEMONS_JSON="$(fetch_daemons_json "$FED_DIR")"

        set -- pack "$FED_DIR" --out "$OUT_PATH" --daemons-json "$DAEMONS_JSON"
        if [ -n "$SINCE" ]; then set -- "$@" --since "$SINCE"; fi
        if [ -n "$TAGS" ]; then set -- "$@" --tags "$TAGS"; fi
        if [ -n "$MAX_ROWS" ]; then set -- "$@" --max-rows-per-agent "$MAX_ROWS"; fi
        if [ "$SCRUB" -eq 1 ]; then set -- "$@" --scrub; fi
        if [ -n "$DONOR_NAME" ]; then set -- "$@" --donor-name "$DONOR_NAME"; fi

        exec python3 "$PACK_HELPER" "$@"
        ;;

    import)
        if [ $# -lt 1 ]; then
            echo "import requires <pack.tar.gz>" >&2
            usage
        fi
        PACK_PATH="$1"; shift

        JSON_OUT=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --json) JSON_OUT=1; shift ;;
                *) echo "Unknown import flag: $1" >&2; usage ;;
            esac
        done

        if [ ! -f "$PACK_PATH" ]; then
            echo "Pack not found: $PACK_PATH" >&2
            exit 2
        fi

        DAEMONS_JSON="$(fetch_daemons_json "$FED_DIR")"

        set -- unpack "$FED_DIR" "$PACK_PATH" --daemons-json "$DAEMONS_JSON"
        if [ "$JSON_OUT" -eq 1 ]; then set -- "$@" --json; fi

        exec python3 "$PACK_HELPER" "$@"
        ;;

    *)
        usage
        ;;
esac
