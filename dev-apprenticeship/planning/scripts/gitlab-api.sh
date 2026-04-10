#!/bin/bash
# GitLab API wrapper for planning colony agents.
# Called by .ag agents via exec shell.
#
# Required env vars (set by start-colony.sh from colony.toml):
#   GITLAB_URL     - GitLab instance URL
#   GITLAB_TOKEN   - Personal access token or project token
#   GITLAB_PROJECT - URL-encoded project path
#
# Usage:
#   gitlab-api.sh issues [--since ISO8601] [--state opened|closed|all] [--labels l1,l2]
#   gitlab-api.sh issue <id>
#   gitlab-api.sh issue-notes <id>
#   gitlab-api.sh issue-events <id>
#   gitlab-api.sh post-note <id> --body <text>
#   gitlab-api.sh update-issue <id> --description <text>
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

# Safely build a JSON object with a single string field using python3.
json_field() {
    local key="$1"
    local value="$2"
    printf '%s' "$value" | python3 -c "import sys,json; print(json.dumps({sys.argv[1]: sys.stdin.read()}))" "$key"
}

CMD="${1:?Usage: gitlab-api.sh <command> [args...]}"
shift

case "$CMD" in
    issues)
        SINCE=""
        STATE="opened"
        LABELS=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --since) SINCE="$2"; shift 2 ;;
                --state) STATE="$2"; shift 2 ;;
                --labels) LABELS="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        URL="$API/issues?state=$STATE&per_page=20&order_by=updated_at&sort=desc"
        if [ -n "$SINCE" ]; then
            URL="$URL&updated_after=$SINCE"
        fi
        if [ -n "$LABELS" ]; then
            URL="$URL&labels=$LABELS"
        fi
        gl_get "$URL"
        ;;

    issue)
        ID="${1:?Usage: gitlab-api.sh issue <id>}"
        gl_get "$API/issues/$ID"
        ;;

    issue-notes)
        ID="${1:?Usage: gitlab-api.sh issue-notes <id>}"
        gl_get "$API/issues/$ID/notes?per_page=100&order_by=created_at&sort=desc"
        ;;

    issue-events)
        ID="${1:?Usage: gitlab-api.sh issue-events <id>}"
        gl_get "$API/issues/$ID/resource_label_events?per_page=50"
        ;;

    post-note)
        ID="${1:?Usage: gitlab-api.sh post-note <id> --body <text>}"
        shift
        BODY=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --body) BODY="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        if [ -z "$BODY" ]; then
            echo '{"error": "--body is required"}' >&2
            exit 1
        fi
        JSON_BODY=$(json_field body "$BODY")
        gl_post "$API/issues/$ID/notes" "$JSON_BODY"
        ;;

    update-issue)
        ID="${1:?Usage: gitlab-api.sh update-issue <id> --description <text>}"
        shift
        DESC=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --description) DESC="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        if [ -z "$DESC" ]; then
            echo '{"error": "--description is required"}' >&2
            exit 1
        fi
        JSON_BODY=$(json_field description "$DESC")
        gl_put "$API/issues/$ID" "$JSON_BODY"
        ;;

    labels)
        gl_get "$API/labels?per_page=100"
        ;;

    *)
        echo "{\"error\": \"Unknown command: $CMD\"}" >&2
        exit 1
        ;;
esac
