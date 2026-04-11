#!/bin/bash
# GitLab API wrapper for triage colony agents.
# Called by .ag agents via exec sh.
#
# Required env vars (set by start-colony.sh from colony.toml):
#   GITLAB_URL     - GitLab instance URL (e.g. https://gitlab.example.com)
#   GITLAB_TOKEN   - Personal access token or project token
#   GITLAB_PROJECT - URL-encoded project path (e.g. your-org%2Fyour-project)
#
# Usage:
#   gitlab-api.sh issues [--since ISO8601] [--state opened|closed|all]
#   gitlab-api.sh issue <id>
#   gitlab-api.sh issue-events <id>
#   gitlab-api.sh issue-notes <id>
#   gitlab-api.sh create-issue --title <t> --description <d> [--labels l1,l2] [--priority p]
#   gitlab-api.sh update-issue <id> [--add-labels l1,l2] [--remove-labels l1,l2] [--priority p] [--assignee username]
#   gitlab-api.sh members
#   gitlab-api.sh labels
#
# Returns JSON to stdout. Exit code 0 on success, 1 on error, 2 on unknown flag.

set -e

if [ -z "$GITLAB_URL" ] || [ -z "$GITLAB_TOKEN" ] || [ -z "$GITLAB_PROJECT" ]; then
    echo '{"error": "GITLAB_URL, GITLAB_TOKEN, and GITLAB_PROJECT must be set"}' >&2
    exit 1
fi

API="$GITLAB_URL/api/v4/projects/$GITLAB_PROJECT"

# emit_error <message>
# Print a JSON error object to stderr with <message> safely encoded via
# python3 json.dumps. Use this anywhere the message contains user-supplied
# input (flag names, command names) that could contain quotes, backslashes,
# or newlines which would otherwise break naive string interpolation.
# Does NOT exit — the caller controls the exit code.
emit_error() {
    printf '%s' "$1" | python3 -c 'import sys,json; print(json.dumps({"error": sys.stdin.read()}), file=sys.stderr)'
}

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

gl_put() {
    curl -sfS --max-time 30 \
        -X PUT \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$2" \
        "$1"
}

CMD="${1:?Usage: gitlab-api.sh <command> [args...]}"
shift

case "$CMD" in
    issues)
        SINCE=""
        STATE="opened"
        while [ $# -gt 0 ]; do
            case "$1" in
                --since) SINCE="$2"; shift 2 ;;
                --state) STATE="$2"; shift 2 ;;
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
        gl_get_q "$API/issues" "${ARGS[@]}"
        ;;

    issue)
        ID="${1:?Usage: gitlab-api.sh issue <id>}"
        gl_get "$API/issues/$ID"
        ;;

    issue-events)
        ID="${1:?Usage: gitlab-api.sh issue-events <id>}"
        gl_get "$API/issues/$ID/resource_label_events?per_page=50"
        ;;

    issue-notes)
        ID="${1:?Usage: gitlab-api.sh issue-notes <id>}"
        gl_get "$API/issues/$ID/notes?per_page=50&order_by=created_at&sort=desc"
        ;;

    create-issue)
        TITLE=""
        DESC=""
        LABELS=""
        PRIORITY=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --title) TITLE="$2"; shift 2 ;;
                --description) DESC="$2"; shift 2 ;;
                --labels) LABELS="$2"; shift 2 ;;
                --priority) PRIORITY="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -z "$TITLE" ]; then
            echo '{"error": "--title is required"}' >&2
            exit 1
        fi
        # Build JSON body via python3 json.dumps so titles and descriptions
        # containing quotes, backslashes, newlines, or control chars are
        # escaped correctly. Values are passed via env vars to keep argv
        # clean and avoid re-quoting hell.
        JSON_BODY=$(TITLE="$TITLE" DESC="$DESC" LABELS="$LABELS" PRIORITY="$PRIORITY" python3 - <<'PY'
import os, json
body = {"title": os.environ["TITLE"]}
if os.environ.get("DESC"):
    body["description"] = os.environ["DESC"]
if os.environ.get("LABELS"):
    body["labels"] = os.environ["LABELS"]
if os.environ.get("PRIORITY"):
    body["priority"] = os.environ["PRIORITY"]
print(json.dumps(body))
PY
)
        gl_post "$API/issues" "$JSON_BODY"
        ;;

    update-issue)
        ID="${1:?Usage: gitlab-api.sh update-issue <id> [--add-labels ...] ...}"
        shift
        ADD_LABELS=""
        REMOVE_LABELS=""
        PRIORITY=""
        ASSIGNEE=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --add-labels) ADD_LABELS="$2"; shift 2 ;;
                --remove-labels) REMOVE_LABELS="$2"; shift 2 ;;
                --priority) PRIORITY="$2"; shift 2 ;;
                --assignee) ASSIGNEE="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        USER_ID=""
        if [ -n "$ASSIGNEE" ]; then
            # Look up user ID by username. Use gl_get_q so usernames with
            # `+`, `&`, or non-ASCII characters survive encoding intact.
            USER_JSON=$(gl_get_q "$GITLAB_URL/api/v4/users" --data-urlencode "username=$ASSIGNEE")
            USER_ID=$(echo "$USER_JSON" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
        fi
        # Build JSON body via python3 json.dumps so label names and priority
        # strings containing quotes, backslashes, commas, or control chars
        # are escaped correctly. Only non-empty fields are included.
        JSON_BODY=$(ADD_LABELS="$ADD_LABELS" REMOVE_LABELS="$REMOVE_LABELS" PRIORITY="$PRIORITY" ASSIGNEE_ID="$USER_ID" python3 - <<'PY'
import os, json
body = {}
if os.environ.get("ADD_LABELS"):
    body["add_labels"] = os.environ["ADD_LABELS"]
if os.environ.get("REMOVE_LABELS"):
    body["remove_labels"] = os.environ["REMOVE_LABELS"]
if os.environ.get("PRIORITY"):
    body["priority"] = os.environ["PRIORITY"]
if os.environ.get("ASSIGNEE_ID"):
    body["assignee_ids"] = [int(os.environ["ASSIGNEE_ID"])]
print(json.dumps(body))
PY
)
        gl_put "$API/issues/$ID" "$JSON_BODY"
        ;;

    members)
        gl_get "$API/members/all?per_page=100"
        ;;

    labels)
        gl_get "$API/labels?per_page=100"
        ;;

    *)
        emit_error "unknown command: $CMD"
        exit 1
        ;;
esac
