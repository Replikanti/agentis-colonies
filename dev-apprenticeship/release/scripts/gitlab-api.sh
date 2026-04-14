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

# gl_call <method> <url> [curl-args...]
#
# Single wrapper used by every gl_get/gl_get_q/gl_post/gl_put below.
# Captures HTTP status + response body, distinguishes auth / rate-limit /
# client / server / transport errors, and retries transient ones with
# exponential backoff so the .ag layer doesn't see them.
#
# Exit codes (so callers & agents can reason about failures):
#   0  — 2xx OK (response body on stdout)
#   2  — 401/403 auth failure (actionable error on stderr, no retry)
#   3  — 429 rate limited (after retries exhausted)
#   4  — other 4xx client error (permanent — wrong URL, bad body, etc.)
#   5  — 5xx server error OR transport failure (timeout, DNS, connect)
#
# Env knobs:
#   GITLAB_CURL_MAX_TIME  per-attempt --max-time seconds (default 90)
#                         #115: was hardcoded 30, too short for real
#                         projects where /issues?per_page=100 exceeds 30s
#                         routinely on self-hosted GitLab under load.
#   GITLAB_CURL_RETRIES   retry budget for 5xx/timeouts/429 (default 3).
#                         Budget is attempts-after-first, so 3 means
#                         4 total attempts before giving up.
gl_call() {
    local method="$1" url="$2"
    shift 2
    local max_time="${GITLAB_CURL_MAX_TIME:-90}"
    local max_retries="${GITLAB_CURL_RETRIES:-3}"
    local attempt=0 delay=3 rc code snippet body_file
    body_file="$(mktemp)"
    # bash RETURN trap fires on function exit regardless of return path,
    # so the tmp body file is cleaned up even when we return non-zero
    # from inside the while loop.
    trap 'rm -f "$body_file"' RETURN

    while :; do
        attempt=$((attempt + 1))
        code=""
        rc=0
        # -sS: silent progress, keep errors.  No -f: we *want* to inspect
        # non-2xx responses ourselves instead of losing them to curl's
        # "HTTP error" exit path. -w writes the status to stdout, which
        # we capture; the body goes to $body_file via -o.
        code="$(curl -sS -w '%{http_code}' -o "$body_file" \
            --max-time "$max_time" \
            -X "$method" \
            -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$@" \
            "$url" 2>/dev/null)" || rc=$?

        # Transport failure (exit 28 timeout, 6 DNS, 7 connect, 35 TLS, …).
        # curl didn't get a status line back, so $code is empty.
        if [ "$rc" -ne 0 ] || [ -z "$code" ]; then
            if [ "$attempt" -le "$max_retries" ]; then
                sleep "$delay"
                delay=$((delay * 2))
                continue
            fi
            emit_error "curl transport failure (exit $rc) after $attempt attempts: $method $url"
            return 5
        fi

        case "$code" in
            2*)
                cat "$body_file"
                return 0
                ;;
            401|403)
                # No retry — a fresh attempt with the same token will
                # hit the same wall. Surface an actionable hint so the
                # operator knows to rotate / re-scope their PAT instead
                # of blaming the federation.
                snippet="$(head -c 200 "$body_file")"
                emit_error "auth failure (HTTP $code) on $method $url: $snippet — check PAT scope/expiry"
                return 2
                ;;
            429)
                # GitLab sometimes sends Retry-After, but parsing headers
                # portably across curl versions is fiddly; conservative
                # exponential backoff matches what a Retry-After would
                # typically request on a self-hosted instance.
                if [ "$attempt" -le "$max_retries" ]; then
                    sleep "$delay"
                    delay=$((delay * 2))
                    continue
                fi
                emit_error "rate limited (HTTP 429) after $attempt attempts on $method $url"
                return 3
                ;;
            5*)
                if [ "$attempt" -le "$max_retries" ]; then
                    sleep "$delay"
                    delay=$((delay * 2))
                    continue
                fi
                snippet="$(head -c 200 "$body_file")"
                emit_error "server error (HTTP $code) after $attempt attempts: $snippet"
                return 5
                ;;
            4*)
                snippet="$(head -c 200 "$body_file")"
                emit_error "client error (HTTP $code) on $method $url: $snippet"
                return 4
                ;;
            *)
                emit_error "unexpected HTTP $code on $method $url"
                return 4
                ;;
        esac
    done
}

gl_get() {
    gl_call GET "$1"
}

# gl_get_q <url> [--data-urlencode k=v ...]
# Uses curl -G so each key=value pair is URL-encoded safely. Use this
# for any endpoint whose query string takes values that could contain
# spaces, '&', '#', or non-ASCII. Plain path-only GETs keep using gl_get.
gl_get_q() {
    local url="$1"
    shift
    gl_call GET "$url" -G "$@"
}

gl_post() {
    gl_call POST "$1" -H "Content-Type: application/json" -d "$2"
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
