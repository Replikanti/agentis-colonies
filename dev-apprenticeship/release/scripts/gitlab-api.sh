#!/bin/bash
# GitLab API wrapper for release colony agents.
# Called by .ag agents via exec sh.
#
# Required env vars (set by start-colony.sh from colony.toml):
#   GITLAB_URL     - GitLab instance URL (e.g. https://gitlab.example.com)
#   GITLAB_TOKEN   - Personal access token or project token
#   GITLAB_PROJECT - URL-encoded project path (e.g. your-org%2Fyour-project)
#
# Usage:
#   gitlab-api.sh releases [--per-page N]
#   gitlab-api.sh tags [--per-page N]
#   gitlab-api.sh pipelines --ref <branch> [--per-page N]
#   gitlab-api.sh merge-requests --state merged [--since ISO8601]
#   gitlab-api.sh mr-commits <iid>
#   gitlab-api.sh create-tag --name <name> --ref <ref> [--message <m>]
#   gitlab-api.sh create-release --tag <tag> --name <name> --description <d>
#   gitlab-api.sh post-note <iid> --body <text>
#
# The release colony reads release history, CI status, and merged MRs to learn
# shipping patterns. Write endpoints create tags and releases. All write
# endpoints build JSON bodies via python3 json.dumps to handle special characters.
#
# Returns JSON to stdout. Exit code 0 on success, 1 on error, 2 on unknown flag.

set -e

# emit_error <message>
# Print a JSON error object to stderr with <message> safely encoded via
# python3 json.dumps. Use this anywhere the message contains user-supplied
# input (flag names, command names) that could contain quotes, backslashes,
# or newlines which would otherwise break naive string interpolation.
# Does NOT exit. The caller controls the exit code.
emit_error() {
    printf '%s' "$1" | python3 -c 'import sys,json; print(json.dumps({"error": sys.stdin.read()}), file=sys.stderr)'
}

if [ -z "$GITLAB_URL" ] || [ -z "$GITLAB_TOKEN" ] || [ -z "$GITLAB_PROJECT" ]; then
    emit_error "GITLAB_URL, GITLAB_TOKEN, and GITLAB_PROJECT must be set"
    exit 1
fi

API="$GITLAB_URL/api/v4/projects/$GITLAB_PROJECT"

gl_get() {
    curl -sfS --max-time 30 \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$1"
}

# gl_get_q <url> [--data-urlencode k=v ...]
# Uses curl -G so each key=value pair is URL-encoded safely. Use this
# for any endpoint whose query string takes values that could contain
# spaces, '&', '#', or non-ASCII. Plain path-only GETs keep using gl_get.
gl_get_q() {
    local url="$1"
    shift
    curl -sfS -G --max-time 30 \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$@" \
        "$url"
}

gl_post() {
    curl -sfS --max-time 30 \
        -X POST \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$2" \
        "$1"
}

CMD="${1:?Usage: gitlab-api.sh <command> [args...]}"
shift

case "$CMD" in
    releases)
        PER_PAGE="20"
        while [ $# -gt 0 ]; do
            case "$1" in
                --per-page) PER_PAGE="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        gl_get_q "$API/releases" \
            --data-urlencode "per_page=$PER_PAGE" \
            --data-urlencode "order_by=released_at" \
            --data-urlencode "sort=desc"
        ;;

    tags)
        PER_PAGE="20"
        while [ $# -gt 0 ]; do
            case "$1" in
                --per-page) PER_PAGE="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        gl_get_q "$API/repository/tags" \
            --data-urlencode "per_page=$PER_PAGE" \
            --data-urlencode "order_by=updated" \
            --data-urlencode "sort=desc"
        ;;

    pipelines)
        REF=""
        PER_PAGE="5"
        while [ $# -gt 0 ]; do
            case "$1" in
                --ref) REF="$2"; shift 2 ;;
                --per-page) PER_PAGE="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -z "$REF" ]; then
            emit_error "--ref is required"
            exit 1
        fi
        gl_get_q "$API/pipelines" \
            --data-urlencode "ref=$REF" \
            --data-urlencode "per_page=$PER_PAGE" \
            --data-urlencode "order_by=updated_at" \
            --data-urlencode "sort=desc"
        ;;

    merge-requests)
        STATE="opened"
        SINCE=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --state) STATE="$2"; shift 2 ;;
                --since) SINCE="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        ARGS=(
            --data-urlencode "state=$STATE"
            --data-urlencode "per_page=100"
            --data-urlencode "order_by=updated_at"
            --data-urlencode "sort=desc"
        )
        if [ -n "$SINCE" ]; then
            ARGS+=(--data-urlencode "updated_after=$SINCE")
        fi
        gl_get_q "$API/merge_requests" "${ARGS[@]}"
        ;;

    mr-commits)
        IID="${1:?Usage: gitlab-api.sh mr-commits <iid>}"
        gl_get "$API/merge_requests/$IID/commits?per_page=100"
        ;;

    create-tag)
        NAME=""
        REF="main"
        MESSAGE=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --name) NAME="$2"; shift 2 ;;
                --ref) REF="$2"; shift 2 ;;
                --message) MESSAGE="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -z "$NAME" ]; then
            emit_error "--name is required"
            exit 1
        fi
        JSON_BODY=$(NAME="$NAME" REF="$REF" MESSAGE="$MESSAGE" python3 - <<'PY'
import os, json
body = {"tag_name": os.environ["NAME"], "ref": os.environ["REF"]}
if os.environ.get("MESSAGE"):
    body["message"] = os.environ["MESSAGE"]
print(json.dumps(body))
PY
)
        gl_post "$API/repository/tags" "$JSON_BODY"
        ;;

    create-release)
        TAG=""
        NAME=""
        DESC=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --tag) TAG="$2"; shift 2 ;;
                --name) NAME="$2"; shift 2 ;;
                --description) DESC="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -z "$TAG" ] || [ -z "$NAME" ]; then
            emit_error "--tag and --name are required"
            exit 1
        fi
        JSON_BODY=$(TAG="$TAG" NAME="$NAME" DESC="$DESC" python3 - <<'PY'
import os, json
body = {"tag_name": os.environ["TAG"], "name": os.environ["NAME"]}
if os.environ.get("DESC"):
    body["description"] = os.environ["DESC"]
print(json.dumps(body))
PY
)
        gl_post "$API/releases" "$JSON_BODY"
        ;;

    post-note)
        IID="${1:?Usage: gitlab-api.sh post-note <iid> --body <text>}"
        shift
        BODY=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --body) BODY="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -z "$BODY" ]; then
            emit_error "--body is required"
            exit 1
        fi
        JSON_BODY=$(printf '%s' "$BODY" | python3 -c 'import sys,json; print(json.dumps({"body": sys.stdin.read()}))')
        gl_post "$API/merge_requests/$IID/notes" "$JSON_BODY"
        ;;

    *)
        emit_error "unknown command: $CMD"
        exit 1
        ;;
esac
