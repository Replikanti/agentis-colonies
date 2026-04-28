#!/bin/bash
# GitHub API wrapper for triage colony agents (ADR-0002, #256 PR 2 of 7).
# Called by .ag agents via forge-api.sh dispatch when FORGE_TYPE=github.
#
# Required env vars (set by start-colony.sh from [forge.github] in colony.toml):
#   GITHUB_URL    - API base (default https://api.github.com; override for GHE)
#   GITHUB_TOKEN  - personal access token (classic or fine-grained)
#   GITHUB_OWNER  - repo owner (user or org)
#   GITHUB_REPO   - repo name
#
# Usage (identical contract to gitlab-api.sh):
#   github-api.sh issues [--since ISO8601] [--state open|closed|all] [--view <name>]
#   github-api.sh create-issue --title <t> --description <d> [--labels l1,l2]
#   github-api.sh update-issue <number> [--add-labels l1,l2] [--remove-labels l1,l2] [--assignee login]
#   github-api.sh members [--view <name>]
#   github-api.sh get-issue <number> [--view <name>]
#   github-api.sh labels  [--view <name>]
#   github-api.sh add-note <number> --body <text>
#
# Views and JSON shape are GitLab-normalized (author.username, labels-as-strings,
# assignees[].username, iid=number, state=opened/closed). See ADR-0002 §Shape.
#
# Exit codes:
#   0  ok (2xx)
#   1  usage error (required flag missing, backend rejection)
#   2  unknown flag / view / auth failure (4xx 401/403)
#   3  rate limited (429 or secondary rate-limit, after retries)
#   4  other 4xx client error
#   5  5xx server error OR transport failure

set -e

# emit_error <message>
# Matches gitlab-api.sh emit_error contract: JSON error object to stderr.
emit_error() {
    printf '%s' "$1" | python3 -c 'import sys,json; print(json.dumps({"error": sys.stdin.read()}), file=sys.stderr)'
}

# normalize_issues
# Reads GitHub issues-list JSON from stdin, writes GitLab-shape JSON to stdout.
# Shape contract (fields triage views consume):
#   iid (<- number), title, description (<- body), state (open->opened),
#   labels: ["name", ...] (GitHub returns [{name, ...}]; flatten to strings),
#   assignees: [{username}, ...] (GitHub field: login -> username),
#   author: {username} (GitHub field: user.login -> username),
#   created_at, updated_at, user_notes_count (<- comments).
# Also filters out pull_request entries — GitHub's /issues endpoint mixes PRs
# with issues, but the triage colony only cares about issues.
normalize_issues() {
    python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = []
for x in data:
    if "pull_request" in x:  # skip PRs
        continue
    out.append({
        "iid": x.get("number"),
        "title": x.get("title"),
        "description": x.get("body"),
        "state": "opened" if x.get("state") == "open" else x.get("state"),
        "labels": [lab if isinstance(lab, str) else lab.get("name") for lab in (x.get("labels") or []) if isinstance(lab, (str, dict))],
        "assignees": [{"username": a.get("login")} for a in (x.get("assignees") or [])],
        "author": {"username": (x.get("user") or {}).get("login")},
        "created_at": x.get("created_at"),
        "updated_at": x.get("updated_at"),
        "user_notes_count": x.get("comments", 0),
    })
print(json.dumps(out))
PY
}

# normalize_issue
# Single-issue variant of normalize_issues. Outputs a single object (not array).
normalize_issue() {
    python3 /dev/fd/3 3<<'PY'
import sys, json
x = json.loads(sys.stdin.read())
print(json.dumps({
    "iid": x.get("number"),
    "title": x.get("title"),
    "description": x.get("body"),
    "state": "opened" if x.get("state") == "open" else x.get("state"),
    "labels": [lab if isinstance(lab, str) else lab.get("name") for lab in (x.get("labels") or []) if isinstance(lab, (str, dict))],
    "assignees": [{"username": a.get("login")} for a in (x.get("assignees") or [])],
    "author": {"username": (x.get("user") or {}).get("login")},
    "created_at": x.get("created_at"),
    "updated_at": x.get("updated_at"),
    "user_notes_count": x.get("comments", 0),
}))
PY
}

# normalize_members
# Reads GitHub collaborators JSON, writes GitLab-shape members JSON.
# GitLab `name` is a real display name; GitHub's /collaborators endpoint
# returns `login` only (no `name` field). Fall back to login so the shape
# has no nulls — the router agent uses `username` for mechanical assignment,
# `name` is only for display and null-vs-login doesn't matter operationally.
normalize_members() {
    python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = []
for x in data:
    login = x.get("login")
    out.append({
        "id": x.get("id"),
        "username": login,
        "name": login,  # fallback; GitHub /collaborators doesn't return name
    })
print(json.dumps(out))
PY
}

# normalize_labels
# GitHub labels are close to GitLab's but have slightly different field set
# (no text_color, no *_count fields). We forward name/description/color which
# is what the labels-summary view keeps anyway.
normalize_labels() {
    python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = [{
    "name": x.get("name"),
    "description": x.get("description"),
    "color": "#" + x.get("color", "").lstrip("#"),
} for x in data]
print(json.dumps(out))
PY
}

# project_json <view-name>
# Same contract as gitlab-api.sh project_json: read normalized GitLab-shape
# JSON from stdin, write downselected projection to stdout. Duplicated here
# (not sourced from gitlab-api.sh) so github-api.sh has no runtime coupling.
# Kept byte-identical to the gitlab-api.sh version; drift is checked by
# tools/test-gitlab-views.sh which runs both implementations against the
# same fixtures.
project_json() {
    local view="$1"
    if [ "${GITLAB_VIEW_MODE:-}" = "raw" ]; then
        cat
        return 0
    fi
    local DATA
    DATA="$(cat)"
    case "$view" in
        raw)
            printf '%s' "$DATA"
            ;;
        labeler)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
print(json.dumps([{"iid": x.get("iid"), "title": x.get("title"), "labels": x.get("labels", []),
                   "author": {"username": (x.get("author") or {}).get("username")}} for x in data]))
PY
            ;;
        router)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = [{"iid": x.get("iid"), "title": x.get("title"), "labels": x.get("labels", []),
        "assignees": [{"username": a.get("username")} for a in x.get("assignees", [])]} for x in data]
print(json.dumps(out))
PY
            ;;
        prioritizer)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
print(json.dumps([{"iid": x.get("iid"), "title": x.get("title"), "labels": x.get("labels", []),
                   "author": {"username": (x.get("author") or {}).get("username")}} for x in data]))
PY
            ;;
        issue_creator)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = [{"iid": x.get("iid"), "title": x.get("title"), "description": x.get("description"),
        "labels": x.get("labels", []),
        "author": {"username": (x.get("author") or {}).get("username")}} for x in data]
print(json.dumps(out))
PY
            ;;
        members-summary)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
print(json.dumps([{"id": x.get("id"), "username": x.get("username"), "name": x.get("name")} for x in data]))
PY
            ;;
        labels-summary)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
print(json.dumps([{"name": x.get("name"), "description": x.get("description"), "color": x.get("color")} for x in data]))
PY
            ;;
        feedback-issue)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
x = json.loads(sys.stdin.read())
print(json.dumps({"iid": x.get("iid"), "state": x.get("state"), "labels": x.get("labels", [])}))
PY
            ;;
        *)
            emit_error "unknown view: $view"
            exit 2
            ;;
    esac
}

# #316 M3a: defensive --repo strip. The forge-api.sh dispatcher consumes
# --repo before exec'ing this wrapper, so reaching this code with --repo
# in argv means either (a) someone called github-api.sh directly bypassing
# the dispatcher (e.g. an operator debugging) or (b) a future caller
# evolves and the dispatcher's strip regresses. Either way, swallow it
# silently here so the verb-parser case below never sees an unknown flag.
# Tokens travel via env (GITHUB_TOKEN already exported by the dispatcher
# on the multi-repo path), never argv.
NEW_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            shift 2
            ;;
        *)
            NEW_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- ${NEW_ARGS[@]+"${NEW_ARGS[@]}"}

if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_OWNER:-}" ] || [ -z "${GITHUB_REPO:-}" ]; then
    emit_error "GITHUB_TOKEN, GITHUB_OWNER, and GITHUB_REPO must be set"
    exit 1
fi

GITHUB_URL="${GITHUB_URL:-https://api.github.com}"
API="$GITHUB_URL/repos/$GITHUB_OWNER/$GITHUB_REPO"

# gh_call <method> <url> [curl-args...]
#
# Mirror of gitlab-api.sh gl_call: transport retry on 429/5xx/timeout, no-retry
# on 401/403, actionable auth error, bounded curl --max-time, structured exit
# codes. GitHub-specific: Authorization: Bearer, Accept: application/vnd.github+json,
# and the X-GitHub-Api-Version: 2022-11-28 header (pinned so server-side default
# flips don't silently change the response shape).
#
# Env knobs (same defaults as gl_call):
#   GITHUB_CURL_MAX_TIME  per-attempt --max-time seconds (default 90)
#   GITHUB_CURL_RETRIES   retry budget for 5xx/timeouts/429 (default 3)
gh_call() {
    local method="$1" url="$2"
    shift 2
    local max_time="${GITHUB_CURL_MAX_TIME:-90}"
    local max_retries="${GITHUB_CURL_RETRIES:-3}"
    local attempt=0 delay=3 rc code snippet body_file
    body_file="$(mktemp)"
    trap 'rm -f "$body_file"; trap - RETURN' RETURN

    while :; do
        attempt=$((attempt + 1))
        code=""
        rc=0
        code="$(curl -sS -w '%{http_code}' -o "$body_file" \
            --max-time "$max_time" \
            -X "$method" \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$@" \
            "$url" 2>/dev/null)" || rc=$?

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
                # GitHub returns 403 both for auth and for secondary rate limits.
                # Distinguish via response body: "rate limit" / "abuse" => retryable,
                # otherwise auth. This avoids hard-failing a transient throttle as
                # an unrecoverable auth error.
                snippet="$(head -c 200 "$body_file")"
                case "$snippet" in
                    *"rate limit"*|*"abuse"*|*"secondary rate"*)
                        if [ "$attempt" -le "$max_retries" ]; then
                            sleep "$delay"
                            delay=$((delay * 2))
                            continue
                        fi
                        emit_error "rate limited (HTTP $code secondary) after $attempt attempts on $method $url"
                        return 3
                        ;;
                    *)
                        emit_error "auth failure (HTTP $code) on $method $url: $snippet — check PAT scope/expiry"
                        return 2
                        ;;
                esac
                ;;
            429)
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

gh_get() {
    gh_call GET "$1"
}

gh_get_q() {
    local url="$1"
    shift
    gh_call GET "$url" -G "$@"
}

gh_post() {
    gh_call POST "$1" -H "Content-Type: application/json" -d "$2"
}

gh_patch() {
    gh_call PATCH "$1" -H "Content-Type: application/json" -d "$2"
}

CMD="${1:?Usage: github-api.sh <command> [args...]}"
shift

case "$CMD" in
    issues)
        SINCE=""
        STATE="open"
        VIEW=""
        while [ $# -gt 0 ]; do
            case "$1" in
                # GitLab uses "opened" in the state filter; GitHub uses "open".
                # Translate the GitLab spelling so forge-api.sh callers don't need
                # per-backend state vocabulary.
                --since) SINCE="$2"; shift 2 ;;
                --state)
                    case "$2" in
                        opened|open) STATE="open" ;;
                        closed)      STATE="closed" ;;
                        all)         STATE="all" ;;
                        *) emit_error "unknown state: $2 (expected open|closed|all)"; exit 2 ;;
                    esac
                    shift 2
                    ;;
                --view) VIEW="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        ARGS=(
            --data-urlencode "state=$STATE"
            --data-urlencode "per_page=20"
            --data-urlencode "sort=updated"
            --data-urlencode "direction=desc"
        )
        if [ -n "$SINCE" ]; then
            ARGS+=(--data-urlencode "since=$SINCE")
        fi
        # Two-step so gh_call's non-zero exit survives the normalize/project pipe
        # (same reason as gitlab-api.sh's body=... || exit $? pattern).
        body="$(gh_get_q "$API/issues" "${ARGS[@]}")" || exit $?
        normalized="$(printf '%s' "$body" | normalize_issues)"
        if [ -n "$VIEW" ]; then
            printf '%s' "$normalized" | project_json "$VIEW"
        else
            printf '%s' "$normalized"
        fi
        ;;

    create-issue)
        TITLE=""
        DESC=""
        LABELS=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --title) TITLE="$2"; shift 2 ;;
                --description) DESC="$2"; shift 2 ;;
                --labels) LABELS="$2"; shift 2 ;;
                # Priority is expressed via labels on GitHub — there is no
                # priority field on the issue. Rejecting loud instead of
                # silent-drop so any caller passing --priority gets an
                # actionable message (they should use --labels "priority::X").
                --priority)
                    emit_error "--priority is not supported on GitHub; use --labels \"priority::<level>\" instead"
                    exit 2
                    ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -z "$TITLE" ]; then
            emit_error "--title is required"
            exit 1
        fi
        # Build JSON body via python3 json.dumps so titles and descriptions
        # containing quotes, backslashes, newlines, or control chars are
        # escaped correctly. GitHub accepts `labels` as an array of strings
        # (which is where GitLab's comma-separated string differs).
        JSON_BODY=$(TITLE="$TITLE" DESC="$DESC" LABELS="$LABELS" python3 - <<'PY'
import os, json
body = {"title": os.environ["TITLE"]}
if os.environ.get("DESC"):
    body["body"] = os.environ["DESC"]
if os.environ.get("LABELS"):
    body["labels"] = [s.strip() for s in os.environ["LABELS"].split(",") if s.strip()]
print(json.dumps(body))
PY
)
        body="$(gh_post "$API/issues" "$JSON_BODY")" || exit $?
        # Normalize the returned issue to GitLab shape so callers can consume
        # the iid field from the response without branching on backend.
        printf '%s' "$body" | normalize_issue
        ;;

    update-issue)
        ID="${1:?Usage: github-api.sh update-issue <number> [--add-labels ...] ...}"
        shift
        ADD_LABELS=""
        REMOVE_LABELS=""
        ASSIGNEE=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --add-labels) ADD_LABELS="$2"; shift 2 ;;
                --remove-labels) REMOVE_LABELS="$2"; shift 2 ;;
                --assignee) ASSIGNEE="$2"; shift 2 ;;
                --priority)
                    emit_error "--priority is not supported on GitHub; use --add-labels \"priority::<level>\" instead"
                    exit 2
                    ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        # Fail fast if no modifying flags were passed (mirror of gitlab-api.sh).
        if [ -z "$ADD_LABELS" ] && [ -z "$REMOVE_LABELS" ] && [ -z "$ASSIGNEE" ]; then
            emit_error "update-issue requires at least one of --add-labels, --remove-labels, --assignee"
            exit 1
        fi
        case "$ID" in
            ''|*[!0-9]*) emit_error "issue number must be numeric: $ID"; exit 2 ;;
        esac
        # Add-labels: POST /issues/{n}/labels with {"labels": [...]} — GitHub
        # supports this natively (appends, no PATCH needed).
        if [ -n "$ADD_LABELS" ]; then
            ADD_JSON=$(LABELS="$ADD_LABELS" python3 -c 'import os, json; print(json.dumps({"labels": [s.strip() for s in os.environ["LABELS"].split(",") if s.strip()]}))')
            gh_post "$API/issues/$ID/labels" "$ADD_JSON" >/dev/null || exit $?
        fi
        # Remove-labels: DELETE /issues/{n}/labels/{name} per label. GitHub has
        # no bulk remove endpoint — loop. URL-encode via python3 so label names
        # containing '/', ' ', '::' etc. survive. Idempotency parity with
        # gitlab-api.sh: a 404 (label already absent) is a no-op, not an error.
        # Use gh_call so 429 + 5xx retry, secondary-rate-limit 403 detection,
        # and the transport-failure handling all work identically to every
        # other verb. gh_call emits to stderr + returns 4 on any 4xx; capture
        # stderr, and if it reports HTTP 404 specifically, swallow silently.
        if [ -n "$REMOVE_LABELS" ]; then
            IFS=',' read -r -a _RM <<< "$REMOVE_LABELS"
            for lab in "${_RM[@]}"; do
                lab_trimmed="$(printf '%s' "$lab" | python3 -c 'import sys; print(sys.stdin.read().strip())')"
                [ -z "$lab_trimmed" ] && continue
                enc="$(printf '%s' "$lab_trimmed" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')"
                del_err="$(mktemp)"
                set +e
                gh_call DELETE "$API/issues/$ID/labels/$enc" >/dev/null 2> "$del_err"
                del_rc=$?
                set -e
                if [ "$del_rc" -eq 4 ] && grep -q 'HTTP 404' "$del_err"; then
                    rm -f "$del_err"
                    continue  # label already absent — no-op
                fi
                if [ "$del_rc" -ne 0 ]; then
                    cat "$del_err" >&2
                    rm -f "$del_err"
                    exit "$del_rc"
                fi
                rm -f "$del_err"
            done
        fi
        # Assignee: POST /issues/{n}/assignees with {"assignees": [login]}.
        # GitHub silently drops unknown or non-collaborator assignees with a
        # 201 — validate by re-reading the issue and asserting the login is
        # present, so "unknown user" fails loud (matching gitlab-api.sh).
        if [ -n "$ASSIGNEE" ]; then
            ASSIGN_JSON=$(LOGIN="$ASSIGNEE" python3 -c 'import os, json; print(json.dumps({"assignees": [os.environ["LOGIN"]]}))')
            gh_post "$API/issues/$ID/assignees" "$ASSIGN_JSON" >/dev/null || exit $?
            check="$(gh_get "$API/issues/$ID")" || exit $?
            present=$(LOGIN="$ASSIGNEE" CHECK="$check" python3 <<'PY'
import os, json
x = json.loads(os.environ["CHECK"])
login = os.environ["LOGIN"]
print("1" if any((a or {}).get("login") == login for a in (x.get("assignees") or [])) else "0")
PY
)
            if [ "$present" != "1" ]; then
                emit_error "update-issue: unknown user: $ASSIGNEE (GitHub silently drops non-collaborator assignees)"
                exit 1
            fi
        fi
        # Return the updated issue so callers have a consistent response shape.
        body="$(gh_get "$API/issues/$ID")" || exit $?
        printf '%s' "$body" | normalize_issue
        ;;

    members)
        VIEW=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --view) VIEW="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        body="$(gh_get "$API/collaborators?per_page=100")" || exit $?
        normalized="$(printf '%s' "$body" | normalize_members)"
        if [ -n "$VIEW" ]; then
            case "$VIEW" in
                summary) INTERNAL_VIEW="members-summary" ;;
                raw) INTERNAL_VIEW="raw" ;;
                *) emit_error "unknown view: $VIEW"; exit 2 ;;
            esac
            printf '%s' "$normalized" | project_json "$INTERNAL_VIEW"
        else
            printf '%s' "$normalized"
        fi
        ;;

    get-issue)
        if [ $# -lt 1 ]; then
            emit_error "Usage: github-api.sh get-issue <number> [--view <name>]"
            exit 2
        fi
        ID="$1"
        shift
        VIEW=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --view) VIEW="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        case "$ID" in
            ''|*[!0-9]*) emit_error "issue number must be numeric: $ID"; exit 2 ;;
        esac
        body="$(gh_get "$API/issues/$ID")" || exit $?
        normalized="$(printf '%s' "$body" | normalize_issue)"
        if [ -n "$VIEW" ]; then
            printf '%s' "$normalized" | project_json "$VIEW"
        else
            printf '%s' "$normalized"
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
        body="$(gh_get "$API/labels?per_page=100")" || exit $?
        normalized="$(printf '%s' "$body" | normalize_labels)"
        if [ -n "$VIEW" ]; then
            case "$VIEW" in
                summary) INTERNAL_VIEW="labels-summary" ;;
                raw) INTERNAL_VIEW="raw" ;;
                *) emit_error "unknown view: $VIEW"; exit 2 ;;
            esac
            printf '%s' "$normalized" | project_json "$INTERNAL_VIEW"
        else
            printf '%s' "$normalized"
        fi
        ;;

    add-note)
        ID="${1:?Usage: github-api.sh add-note <number> --body <text>}"
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
            ''|*[!0-9]*) emit_error "issue number must be numeric: $ID"; exit 2 ;;
        esac
        JSON_BODY=$(printf '%s' "$BODY" | python3 -c 'import sys,json; print(json.dumps({"body": sys.stdin.read()}))')
        gh_post "$API/issues/$ID/comments" "$JSON_BODY"
        ;;

    rate-limit-status)
        # GitHub's /rate_limit endpoint does NOT count against the
        # authenticated REST budget, so dashboards can poll this freely.
        # Normalize the "core" resource (the same bucket REST reads draw
        # from) to the GitLab-shape {remaining, limit, reset_at} contract.
        # ADR-0002 PR 7 of 7 for #256.
        resp="$(gh_get "$GITHUB_URL/rate_limit")" || exit $?
        RATE_RESP="$resp" python3 <<'PY'
import os, json, datetime
try:
    d = json.loads(os.environ["RATE_RESP"])
except Exception:
    print(json.dumps({"remaining": None, "limit": None, "reset_at": None}))
    raise SystemExit(0)
# Prefer resources.core (matches what REST reads draw from); fall back
# to the top-level rate summary for old GHE instances that omit it.
core = (d.get("resources") or {}).get("core") or d.get("rate") or {}
reset = core.get("reset")
reset_at = None
if isinstance(reset, (int, float)):
    reset_at = datetime.datetime.fromtimestamp(int(reset), tz=datetime.timezone.utc).isoformat().replace("+00:00", "Z")
print(json.dumps({"remaining": core.get("remaining"), "limit": core.get("limit"), "reset_at": reset_at}))
PY
        ;;

    *)
        emit_error "unknown command: $CMD"
        exit 1
        ;;
esac
