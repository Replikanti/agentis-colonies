#!/bin/bash
# GitLab API wrapper for code-review colony agents.
# Called by .ag agents via exec shell.
#
# Required env vars (set by start-colony.sh from colony.toml):
#   GITLAB_URL     - GitLab instance URL
#   GITLAB_TOKEN   - Personal access token or project token
#   GITLAB_PROJECT - URL-encoded project path
#
# Usage:
#   gitlab-api.sh merge-requests [--since ISO8601] [--state opened|merged|all]
#   gitlab-api.sh mr <iid>
#   gitlab-api.sh mr-changes <iid>
#   gitlab-api.sh mr-notes <iid>
#   gitlab-api.sh mr-approvals <iid>
#   gitlab-api.sh post-note <iid> --body <text>
#   gitlab-api.sh approve <iid>
#   gitlab-api.sh issues [--since ISO8601] [--state opened|closed|all]
#   gitlab-api.sh members
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

CMD="${1:?Usage: gitlab-api.sh <command> [args...]}"
shift

case "$CMD" in
    merge-requests)
        SINCE=""
        STATE="opened"
        while [ $# -gt 0 ]; do
            case "$1" in
                --since) SINCE="$2"; shift 2 ;;
                --state) STATE="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        URL="$API/merge_requests?state=$STATE&per_page=20&order_by=updated_at&sort=desc"
        if [ -n "$SINCE" ]; then
            URL="$URL&updated_after=$SINCE"
        fi
        gl_get "$URL"
        ;;

    mr)
        IID="${1:?Usage: gitlab-api.sh mr <iid>}"
        gl_get "$API/merge_requests/$IID"
        ;;

    mr-changes)
        IID="${1:?Usage: gitlab-api.sh mr-changes <iid>}"
        gl_get "$API/merge_requests/$IID/changes"
        ;;

    mr-notes)
        IID="${1:?Usage: gitlab-api.sh mr-notes <iid>}"
        gl_get "$API/merge_requests/$IID/notes?per_page=100&order_by=created_at&sort=desc"
        ;;

    mr-approvals)
        IID="${1:?Usage: gitlab-api.sh mr-approvals <iid>}"
        gl_get "$API/merge_requests/$IID/approvals"
        ;;

    post-note)
        IID="${1:?Usage: gitlab-api.sh post-note <iid> --body <text>}"
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
        JSON_BODY=$(printf '%s' "$BODY" | python3 -c 'import sys,json; print(json.dumps({"body": sys.stdin.read()}))')
        gl_post "$API/merge_requests/$IID/notes" "$JSON_BODY"
        ;;

    approve)
        IID="${1:?Usage: gitlab-api.sh approve <iid>}"
        gl_post "$API/merge_requests/$IID/approve" "{}"
        ;;

    members)
        gl_get "$API/members/all?per_page=100"
        ;;

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
        URL="$API/issues?state=$STATE&per_page=20&order_by=updated_at&sort=desc"
        if [ -n "$SINCE" ]; then
            URL="$URL&updated_after=$SINCE"
        fi
        gl_get "$URL"
        ;;

    *)
        echo "{\"error\": \"Unknown command: $CMD\"}" >&2
        exit 1
        ;;
esac
