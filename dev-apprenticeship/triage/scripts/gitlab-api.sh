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
# Returns JSON to stdout. Exit code 0 on success, 1 on error.

set -e

if [ -z "$GITLAB_URL" ] || [ -z "$GITLAB_TOKEN" ] || [ -z "$GITLAB_PROJECT" ]; then
    echo '{"error": "GITLAB_URL, GITLAB_TOKEN, and GITLAB_PROJECT must be set"}' >&2
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
                *) shift ;;
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
                *) shift ;;
            esac
        done
        if [ -z "$TITLE" ]; then
            echo '{"error": "--title is required"}' >&2
            exit 1
        fi
        # Build JSON body
        BODY="{\"title\":\"$TITLE\""
        if [ -n "$DESC" ]; then
            BODY="$BODY,\"description\":\"$DESC\""
        fi
        if [ -n "$LABELS" ]; then
            BODY="$BODY,\"labels\":\"$LABELS\""
        fi
        if [ -n "$PRIORITY" ]; then
            BODY="$BODY,\"priority\":\"$PRIORITY\""
        fi
        BODY="$BODY}"
        gl_post "$API/issues" "$BODY"
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
                *) shift ;;
            esac
        done
        BODY="{"
        SEP=""
        if [ -n "$ADD_LABELS" ]; then
            BODY="$BODY${SEP}\"add_labels\":\"$ADD_LABELS\""
            SEP=","
        fi
        if [ -n "$REMOVE_LABELS" ]; then
            BODY="$BODY${SEP}\"remove_labels\":\"$REMOVE_LABELS\""
            SEP=","
        fi
        if [ -n "$PRIORITY" ]; then
            BODY="$BODY${SEP}\"priority\":\"$PRIORITY\""
            SEP=","
        fi
        if [ -n "$ASSIGNEE" ]; then
            # Look up user ID by username. Use gl_get_q so usernames with
            # `+`, `&`, or non-ASCII characters survive encoding intact.
            USER_JSON=$(gl_get_q "$GITLAB_URL/api/v4/users" --data-urlencode "username=$ASSIGNEE")
            USER_ID=$(echo "$USER_JSON" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
            if [ -n "$USER_ID" ]; then
                BODY="$BODY${SEP}\"assignee_ids\":[$USER_ID]"
                SEP=","
            fi
        fi
        BODY="$BODY}"
        gl_put "$API/issues/$ID" "$BODY"
        ;;

    members)
        gl_get "$API/members/all?per_page=100"
        ;;

    labels)
        gl_get "$API/labels?per_page=100"
        ;;

    *)
        echo "{\"error\": \"Unknown command: $CMD\"}" >&2
        exit 1
        ;;
esac
