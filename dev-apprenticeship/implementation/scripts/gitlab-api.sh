#!/bin/bash
# GitLab API wrapper for implementation colony agents.
# Called by .ag agents via exec sh.
#
# Required env vars (set by start-colony.sh from colony.toml):
#   GITLAB_URL     - GitLab instance URL (e.g. https://gitlab.example.com)
#   GITLAB_TOKEN   - Personal access token or project token
#   GITLAB_PROJECT - URL-encoded project path (e.g. your-org%2Fyour-project)
#
# Usage:
#   gitlab-api.sh merge-requests [--state merged] [--since ISO8601]
#   gitlab-api.sh mr-changes <iid>
#   gitlab-api.sh mr-commits <iid>
#   gitlab-api.sh issue <iid>
#   gitlab-api.sh assigned-issues [--since ISO8601]
#   gitlab-api.sh create-branch --name <name> --ref <ref>
#   gitlab-api.sh commit-files --branch <b> --message <m> --actions <json>
#   gitlab-api.sh create-mr --source <branch> --title <title> [--description <d>]
#   gitlab-api.sh post-note <iid> --body <text>
#
# Implementation colony both reads from and writes to GitLab: it creates
# branches, commits code, and opens merge requests. All write endpoints
# build JSON bodies via python3 json.dumps to handle special characters.
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
            --data-urlencode "per_page=20"
            --data-urlencode "order_by=updated_at"
            --data-urlencode "sort=desc"
        )
        if [ -n "$SINCE" ]; then
            ARGS+=(--data-urlencode "updated_after=$SINCE")
        fi
        gl_get_q "$API/merge_requests" "${ARGS[@]}"
        ;;

    mr-changes)
        IID="${1:?Usage: gitlab-api.sh mr-changes <iid>}"
        gl_get "$API/merge_requests/$IID/changes"
        ;;

    mr-commits)
        IID="${1:?Usage: gitlab-api.sh mr-commits <iid>}"
        gl_get "$API/merge_requests/$IID/commits?per_page=100"
        ;;

    issue)
        IID="${1:?Usage: gitlab-api.sh issue <iid>}"
        gl_get "$API/issues/$IID"
        ;;

    assigned-issues)
        SINCE=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --since) SINCE="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        ARGS=(
            --data-urlencode "state=opened"
            --data-urlencode "assignee_id=Any"
            --data-urlencode "labels=implementation"
            --data-urlencode "per_page=20"
            --data-urlencode "order_by=updated_at"
            --data-urlencode "sort=desc"
        )
        if [ -n "$SINCE" ]; then
            ARGS+=(--data-urlencode "updated_after=$SINCE")
        fi
        gl_get_q "$API/issues" "${ARGS[@]}"
        ;;

    create-branch)
        NAME=""
        REF="main"
        while [ $# -gt 0 ]; do
            case "$1" in
                --name) NAME="$2"; shift 2 ;;
                --ref) REF="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -z "$NAME" ]; then
            emit_error "--name is required"
            exit 1
        fi
        JSON_BODY=$(NAME="$NAME" REF="$REF" python3 - <<'PY'
import os, json
print(json.dumps({"branch": os.environ["NAME"], "ref": os.environ["REF"]}))
PY
)
        gl_post "$API/repository/branches" "$JSON_BODY"
        ;;

    commit-files)
        BRANCH=""
        MESSAGE=""
        ACTIONS=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --branch) BRANCH="$2"; shift 2 ;;
                --message) MESSAGE="$2"; shift 2 ;;
                --actions) ACTIONS="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -z "$BRANCH" ] || [ -z "$MESSAGE" ] || [ -z "$ACTIONS" ]; then
            emit_error "--branch, --message, and --actions are all required"
            exit 1
        fi
        # ACTIONS is a JSON array of {action, file_path, content} objects.
        # We pass it as raw JSON so python3 can parse and embed it.
        JSON_BODY=$(BRANCH="$BRANCH" MESSAGE="$MESSAGE" ACTIONS="$ACTIONS" python3 - <<'PY'
import os, json
actions = json.loads(os.environ["ACTIONS"])
body = {
    "branch": os.environ["BRANCH"],
    "commit_message": os.environ["MESSAGE"],
    "actions": actions,
}
print(json.dumps(body))
PY
)
        gl_post "$API/repository/commits" "$JSON_BODY"
        ;;

    create-mr)
        SOURCE=""
        TITLE=""
        DESC=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --source) SOURCE="$2"; shift 2 ;;
                --title) TITLE="$2"; shift 2 ;;
                --description) DESC="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -z "$SOURCE" ] || [ -z "$TITLE" ]; then
            emit_error "--source and --title are required"
            exit 1
        fi
        JSON_BODY=$(SOURCE="$SOURCE" TITLE="$TITLE" DESC="$DESC" python3 - <<'PY'
import os, json
body = {
    "source_branch": os.environ["SOURCE"],
    "target_branch": "main",
    "title": os.environ["TITLE"],
}
if os.environ.get("DESC"):
    body["description"] = os.environ["DESC"]
print(json.dumps(body))
PY
)
        gl_post "$API/merge_requests" "$JSON_BODY"
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
