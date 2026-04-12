#!/bin/bash
# GitLab API wrapper for planning colony agents.
# Called by .ag agents via exec sh.
#
# Required env vars (set by start-colony.sh from colony.toml):
#   GITLAB_URL     - GitLab instance URL (e.g. https://gitlab.example.com)
#   GITLAB_TOKEN   - Personal access token or project token
#   GITLAB_PROJECT - URL-encoded project path (e.g. your-org%2Fyour-project)
#
# Usage:
#   gitlab-api.sh issues --needs-planning [--since ISO8601]
#   gitlab-api.sh add-note <iid> --body <text>
#   gitlab-api.sh merge-requests [--state merged] [--since ISO8601]
#
# Planning only reads from GitLab and posts comments. It never changes labels,
# approves, assigns, or merges. That surface lives in triage / code-review /
# release colonies. If you are tempted to add a write endpoint here, it
# probably belongs in a different colony.
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
    issues)
        SINCE=""
        NEEDS_PLANNING=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --since) SINCE="$2"; shift 2 ;;
                --needs-planning) NEEDS_PLANNING=1; shift ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        ARGS=(
            --data-urlencode "state=opened"
            --data-urlencode "per_page=20"
            --data-urlencode "order_by=updated_at"
            --data-urlencode "sort=desc"
        )
        if [ "$NEEDS_PLANNING" -eq 1 ]; then
            ARGS+=(--data-urlencode "labels=needs-planning")
        fi
        if [ -n "$SINCE" ]; then
            ARGS+=(--data-urlencode "updated_after=$SINCE")
        fi
        gl_get_q "$API/issues" "${ARGS[@]}"
        ;;

    add-note)
        ID="${1:?Usage: gitlab-api.sh add-note <iid> --body <text>}"
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
        # Use python3 json.dumps so newlines, quotes, backslashes, and control
        # chars are all escaped correctly and markdown formatting is preserved.
        JSON_BODY=$(printf '%s' "$BODY" | python3 -c 'import sys,json; print(json.dumps({"body": sys.stdin.read()}))')
        gl_post "$API/issues/$ID/notes" "$JSON_BODY"
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
            --data-urlencode "per_page=20"
            --data-urlencode "order_by=updated_at"
            --data-urlencode "sort=desc"
        )
        if [ -n "$SINCE" ]; then
            ARGS+=(--data-urlencode "updated_after=$SINCE")
        fi
        gl_get_q "$API/merge_requests" "${ARGS[@]}"
        ;;

    *)
        emit_error "unknown command: $CMD"
        exit 1
        ;;
esac
