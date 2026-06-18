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
#   gitlab-api.sh issues [--since ISO8601] [--state opened|closed|all] [--view <name>]
#   gitlab-api.sh create-issue --title <t> --description <d> [--labels l1,l2] [--priority p]
#   gitlab-api.sh update-issue <id> [--add-labels l1,l2] [--remove-labels l1,l2] [--priority p] [--assignee username]
#   gitlab-api.sh members [--view <name>]
#   gitlab-api.sh labels  [--view <name>]
#   gitlab-api.sh add-note <iid> --body <text>
#
# Views (opt-in projection; default is full JSON):
#   issues  --view labeler        [{iid, title, labels}]
#   issues  --view router         [{iid, title, labels, assignees:[{username}]}]
#   issues  --view prioritizer    [{iid, title, labels}]
#   issues  --view issue_creator  [{iid, title, description, labels, author:{username}}]
#   members --view summary        [{id, username, name}]
#   labels  --view summary        [{name, description, color}]
#   <cmd>   --view raw            explicit pass-through (same as no flag)
#   GITLAB_VIEW_MODE=raw          env-override that forces pass-through globally.
#
# Returns JSON to stdout. Exit code 0 on success, 1 on error, 2 on unknown flag/view.

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

# project_json <view-name>
# Reads full GitLab JSON from stdin, writes a downselected projection to
# stdout. Views keep only the fields that the downstream .ag agent's
# prompt() actually needs, shrinking payloads ~10x and cutting LLM cost.
#
# Views are defined inline in a single python case-dispatch below. Each
# projection stays under 10 lines. Unknown views exit 2 via emit_error
# (matching the rest of the script's "unknown flag" contract).
#
# Env override: GITLAB_VIEW_MODE=raw short-circuits to cat, giving
# operators a one-var rollback if a projection drops a field an agent
# silently depended on.
project_json() {
    local view="$1"
    if [ "${GITLAB_VIEW_MODE:-}" = "raw" ]; then
        cat
        return 0
    fi
    # Capture stdin once. python3 below reads the projection script from a
    # `<<'PY'` heredoc (which ties up python's stdin), so the payload has to
    # travel via env var instead of a pipe. json.loads is cheap enough here
    # that the extra round-trip through memory is invisible next to the
    # LLM cost we're trying to avoid.
    local DATA
    DATA="$(cat)"
    case "$view" in
        raw)
            printf '%s' "$DATA"
            ;;
        labeler)
            DATA="$DATA" python3 <<'PY'
import os, json
data = json.loads(os.environ["DATA"])
# #104: include author.username so labeler can tag knowledge as
# personal (operator's own issue) vs team.
print(json.dumps([{"iid": x.get("iid"), "title": x.get("title"), "labels": x.get("labels", []),
                   "author": {"username": (x.get("author") or {}).get("username")}} for x in data]))
PY
            ;;
        router)
            DATA="$DATA" python3 <<'PY'
import os, json
data = json.loads(os.environ["DATA"])
out = [{"iid": x.get("iid"), "title": x.get("title"), "labels": x.get("labels", []),
        "assignees": [{"username": a.get("username")} for a in x.get("assignees", [])]} for x in data]
print(json.dumps(out))
PY
            ;;
        prioritizer)
            DATA="$DATA" python3 <<'PY'
import os, json
data = json.loads(os.environ["DATA"])
# #104: include author.username for personal/team tagging.
print(json.dumps([{"iid": x.get("iid"), "title": x.get("title"), "labels": x.get("labels", []),
                   "author": {"username": (x.get("author") or {}).get("username")}} for x in data]))
PY
            ;;
        issue_creator)
            DATA="$DATA" python3 <<'PY'
import os, json
data = json.loads(os.environ["DATA"])
out = [{"iid": x.get("iid"), "title": x.get("title"), "description": x.get("description"),
        "labels": x.get("labels", []),
        "author": {"username": (x.get("author") or {}).get("username")}} for x in data]
print(json.dumps(out))
PY
            ;;
        members-summary)
            DATA="$DATA" python3 <<'PY'
import os, json
data = json.loads(os.environ["DATA"])
print(json.dumps([{"id": x.get("id"), "username": x.get("username"), "name": x.get("name")} for x in data]))
PY
            ;;
        labels-summary)
            DATA="$DATA" python3 <<'PY'
import os, json
data = json.loads(os.environ["DATA"])
print(json.dumps([{"name": x.get("name"), "description": x.get("description"), "color": x.get("color")} for x in data]))
PY
            ;;
        feedback-issue)
            # #106: minimal per-issue projection used by the labeler's
            # verdict matcher to compare suggested labels against what the
            # operator actually applied. Keeping the view tiny keeps the
            # round-trip body size (and therefore the agent's input token
            # budget if it ever feeds this back into a prompt) small.
            DATA="$DATA" python3 <<'PY'
import os, json
x = json.loads(os.environ["DATA"])
print(json.dumps({"iid": x.get("iid"), "state": x.get("state"), "labels": x.get("labels", [])}))
PY
            ;;
        *)
            emit_error "unknown view: $view"
            exit 2
            ;;
    esac
}

if [ -z "$GITLAB_URL" ] || [ -z "$GITLAB_TOKEN" ] || [ -z "$GITLAB_PROJECT" ]; then
    emit_error "GITLAB_URL, GITLAB_TOKEN, and GITLAB_PROJECT must be set"
    exit 1
fi

API="$GITLAB_URL/api/v4/projects/$GITLAB_PROJECT"

# #1111: GitLab folded the legacy `issues` REST collection into the unified
# `work_items` collection. Resolve the segment through one helper so the
# rename — and any future per-item-type split — lives in one place instead
# of every call site below. All issue-family work item types (issue,
# incident, task, …) share the single project-level `work_items` collection
# and are distinguished by a type field in the body, not by path. Operators
# on an instance that still serves the legacy path can pin it with
# GITLAB_ITEMS_ENDPOINT=issues (one env var, no code change).
gl_items_path() {
    if [ -n "${GITLAB_ITEMS_ENDPOINT:-}" ]; then
        printf '%s' "$GITLAB_ITEMS_ENDPOINT"
        return 0
    fi
    case "${1:-issue}" in
        issue|incident|task|test_case|ticket) printf 'work_items' ;;
        *)                                     printf 'work_items' ;;
    esac
}
ITEMS="$(gl_items_path issue)"

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
    # from inside the while loop. The trap unregisters itself in its own
    # body — a bare `trap 'rm -f ...' RETURN` in bash is shell-global,
    # not function-local, so without `trap - RETURN` the cleanup would
    # re-fire on every subsequent function return in the script with a
    # stale `$body_file` (out of scope, so rm's target is '').
    trap 'rm -f "$body_file"; trap - RETURN' RETURN

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

gl_put() {
    gl_call PUT "$1" -H "Content-Type: application/json" -d "$2"
}

CMD="${1:?Usage: gitlab-api.sh <command> [args...]}"
shift

case "$CMD" in
    issues)
        SINCE=""
        STATE="opened"
        VIEW=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --since) SINCE="$2"; shift 2 ;;
                --state) STATE="$2"; shift 2 ;;
                --view) VIEW="$2"; shift 2 ;;
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
        if [ -n "$VIEW" ]; then
            # Two-step so gl_call's non-zero exit (auth/429/5xx/transport)
            # survives the projection pipe. A bare `gl_get_q ... | project_json`
            # would let python3 (or `cat` when GITLAB_VIEW_MODE=raw) override
            # the meaningful exit code with 0 or 1, masking the real failure.
            body="$(gl_get_q "$API/$ITEMS" "${ARGS[@]}")" || exit $?
            printf '%s' "$body" | project_json "$VIEW"
        else
            gl_get_q "$API/$ITEMS" "${ARGS[@]}"
        fi
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
            emit_error "--title is required"
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
        gl_post "$API/$ITEMS" "$JSON_BODY"
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
            # If the lookup didn't find a user, fail here. Without this
            # guard the outcome depends on which other flags were passed:
            #   - --assignee only: generic "requires at least one of"
            #     error below, which is confusing because the caller did
            #     pass --assignee.
            #   - --assignee + other flags: silent partial success where
            #     the assignee is dropped and the other fields are PUT
            #     anyway. Even worse.
            # Both paths are confusing, so we fail fast with a clear
            # "unknown user" message instead.
            if [ -z "$USER_ID" ]; then
                emit_error "update-issue: unknown user: $ASSIGNEE"
                exit 1
            fi
        fi
        # Fail fast if no modifying flags were passed. A PUT with body {}
        # is a confusing no-op: GitLab happily returns the unchanged issue
        # as if the update had happened, so the caller has no signal that
        # they forgot to pass anything.
        if [ -z "$ADD_LABELS" ] && [ -z "$REMOVE_LABELS" ] && [ -z "$PRIORITY" ] && [ -z "$USER_ID" ]; then
            emit_error "update-issue requires at least one of --add-labels, --remove-labels, --priority, --assignee"
            exit 1
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
        gl_put "$API/$ITEMS/$ID" "$JSON_BODY"
        ;;

    members)
        VIEW=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --view) VIEW="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -n "$VIEW" ]; then
            # User-facing `--view summary` maps to the internal
            # `members-summary` projection to avoid name collision with
            # the `labels --view summary` projection, which keeps a
            # different set of fields. Unknown names must fail loudly here
            # — falling through would let e.g. `members --view labeler`
            # silently produce a rc=0 bogus projection, inconsistent with
            # the "unknown view exits 2" contract elsewhere.
            case "$VIEW" in
                summary) INTERNAL_VIEW="members-summary" ;;
                raw) INTERNAL_VIEW="raw" ;;
                *) emit_error "unknown view: $VIEW"; exit 2 ;;
            esac
            # Two-step so gl_call's non-zero exit (auth/429/5xx/transport)
            # survives the projection pipe. A bare `gl_get ... | project_json`
            # would let python3 (or `cat` when GITLAB_VIEW_MODE=raw) override
            # the meaningful exit code with 0 or 1, masking the real failure.
            body="$(gl_get "$API/members/all?per_page=100")" || exit $?
            printf '%s' "$body" | project_json "$INTERNAL_VIEW"
        else
            gl_get "$API/members/all?per_page=100"
        fi
        ;;

    get-issue)
        # #106: single-issue fetch for the feedback matcher. Arg is the
        # issue iid (the project-local number, not GitLab's global id).
        # Supports --view feedback-issue to downselect to {iid, state, labels}.
        if [ $# -lt 1 ]; then
            emit_error "Usage: gitlab-api.sh get-issue <iid> [--view <name>]"
            exit 2
        fi
        IID="$1"
        shift
        VIEW=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --view) VIEW="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        case "$IID" in
            ''|*[!0-9]*) emit_error "iid must be numeric: $IID"; exit 2 ;;
        esac
        if [ -n "$VIEW" ]; then
            body="$(gl_get "$API/$ITEMS/$IID")" || exit $?
            printf '%s' "$body" | project_json "$VIEW"
        else
            gl_get "$API/$ITEMS/$IID"
        fi
        ;;

    labels)
        VIEW=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --view) VIEW="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -n "$VIEW" ]; then
            # Unknown names fail here so `labels --view prioritizer` doesn't
            # silently produce a bogus projection (see members branch above).
            case "$VIEW" in
                summary) INTERNAL_VIEW="labels-summary" ;;
                raw) INTERNAL_VIEW="raw" ;;
                *) emit_error "unknown view: $VIEW"; exit 2 ;;
            esac
            # Two-step pipe so gl_call's non-zero exit survives projection (see
            # members branch above).
            body="$(gl_get "$API/labels?per_page=100")" || exit $?
            printf '%s' "$body" | project_json "$INTERNAL_VIEW"
        else
            gl_get "$API/labels?per_page=100"
        fi
        ;;

    add-note)
        # Back-ported from planning/scripts/gitlab-api.sh (#256 PR 2). The
        # labeler, prioritizer, and router agents' review-gated branches
        # shell out to `gitlab-api.sh add-note <iid> --body ...` to post
        # draft suggestions as comments; prior to this PR the call silently
        # failed with "unknown command: add-note" (caught by the .ag try/catch
        # so no operator noticed). Mirrors the github-api.sh add-note arm so
        # the contract is symmetric across backends.
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
        case "$ID" in
            ''|*[!0-9]*) emit_error "issue iid must be numeric: $ID"; exit 2 ;;
        esac
        JSON_BODY=$(printf '%s' "$BODY" | python3 -c 'import sys,json; print(json.dumps({"body": sys.stdin.read()}))')
        gl_post "$API/$ITEMS/$ID/notes" "$JSON_BODY"
        ;;

    rate-limit-status)
        # GitLab does NOT have a dedicated rate-limit endpoint. We trigger
        # a lightweight /version call and extract RateLimit-* response
        # headers (documented at GitLab "User and IP rate limits"). Self-
        # hosted instances with rate limiting disabled return no such
        # headers; we forward nulls in that case so the dashboard tile
        # renders "—" instead of a spurious "0 remaining".
        # ADR-0002 PR 7 of 7 for #256.
        hdr_file="$(mktemp)"
        # /version is the cheapest authenticated endpoint. -D dumps
        # response headers; -o discards body; || : keeps a transport
        # failure from killing the script (nulls forwarded in that case).
        curl -sS -D "$hdr_file" -o /dev/null \
            --max-time "${GITLAB_CURL_MAX_TIME:-30}" \
            -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/version" 2>/dev/null || :
        HDR_FILE="$hdr_file" python3 <<'PY'
import os, json, datetime, re
try:
    with open(os.environ["HDR_FILE"], "r", errors="replace") as f:
        lines = f.readlines()
except Exception:
    lines = []
hdrs = {}
for ln in lines:
    m = re.match(r"([^:]+):\s*(.+?)\s*$", ln)
    if m:
        hdrs[m.group(1).lower()] = m.group(2)
def _int(s):
    try:
        return int(s) if s is not None else None
    except Exception:
        return None
remaining = _int(hdrs.get("ratelimit-remaining"))
limit = _int(hdrs.get("ratelimit-limit"))
reset = _int(hdrs.get("ratelimit-reset"))
reset_at = None
if reset is not None:
    reset_at = datetime.datetime.fromtimestamp(reset, tz=datetime.timezone.utc).isoformat().replace("+00:00", "Z")
print(json.dumps({"remaining": remaining, "limit": limit, "reset_at": reset_at}))
PY
        rm -f "$hdr_file"
        ;;

    *)
        emit_error "unknown command: $CMD"
        exit 1
        ;;
esac
