#!/bin/bash
# GitLab API wrapper for planning colony agents.
# Called by .ag agents via exec sh.
#
# Required env vars (set by start-colony.sh from colony.toml):
#   GITLAB_URL     - GitLab instance URL (e.g. https://gitlab.example.com)
#   GITLAB_TOKEN   - Personal access token or project token
#   GITLAB_PROJECT - URL-encoded project path (e.g. your-org%2Fyour-project)
#
# Optional env vars:
#   PLANNING_TRIGGER_LABEL - label matched by --needs-planning
#                            (default: "needs-planning"). Override via
#                            the [planning] trigger_label key in
#                            colony.toml to match project-local
#                            taxonomies (e.g. "DEV::not started").
#                            Scoped labels with `::` and spaces are
#                            supported — `--data-urlencode` handles
#                            the encoding.
#
# Usage:
#   gitlab-api.sh issues --needs-planning [--since ISO8601] [--view <name>]
#   gitlab-api.sh issues-by-label-events --since ISO8601 [--view <name>]
#   gitlab-api.sh issue-label-events <iid> [--since ISO8601] [--label NAME]
#   gitlab-api.sh add-note <iid> --body <text>
#   gitlab-api.sh merge-requests [--state merged] [--since ISO8601] [--per-page N] [--view <name>]
#
# Views (opt-in projection; default is full JSON):
#   issues         --view planning     [{iid, title, description, labels,
#                                        author:{username}, created_at}]
#   merge-requests --view planning-mr  [{iid, title, description, labels,
#                                        changes_count, user_notes_count,
#                                        merged_at, target_branch}]
#   <cmd>          --view raw          explicit pass-through (same as no flag)
#   GITLAB_VIEW_MODE=raw               env-override that forces pass-through globally.
#
# Planning only reads from GitLab and posts comments. It never changes labels,
# approves, assigns, or merges. That surface lives in triage / code-review /
# release colonies. If you are tempted to add a write endpoint here, it
# probably belongs in a different colony.
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
# stdout. See the triage colony's gitlab-api.sh for the full design note.
project_json() {
    local view="$1"
    if [ "${GITLAB_VIEW_MODE:-}" = "raw" ]; then
        cat
        return 0
    fi
    # Capture stdin once: python3 below reads the projection script from a
    # `<<'PY'` heredoc (which occupies python's stdin), so the payload has
    # to travel via env var rather than a pipe.
    local DATA
    DATA="$(cat)"
    case "$view" in
        raw)
            printf '%s' "$DATA"
            ;;
        planning)
            DATA="$DATA" python3 <<'PY'
import os, json
data = json.loads(os.environ["DATA"])
out = [{"iid": x.get("iid"), "title": x.get("title"), "description": x.get("description"),
        "labels": x.get("labels", []),
        "author": {"username": (x.get("author") or {}).get("username")},
        "created_at": x.get("created_at")} for x in data]
print(json.dumps(out))
PY
            ;;
        planning-mr)
            DATA="$DATA" python3 <<'PY'
import os, json
data = json.loads(os.environ["DATA"])
out = [{"iid": x.get("iid"), "title": x.get("title"), "description": x.get("description"),
        "labels": x.get("labels", []), "changes_count": x.get("changes_count"),
        "user_notes_count": x.get("user_notes_count"),
        "merged_at": x.get("merged_at"), "target_branch": x.get("target_branch")} for x in data]
print(json.dumps(out))
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

CMD="${1:?Usage: gitlab-api.sh <command> [args...]}"
shift

case "$CMD" in
    issues)
        SINCE=""
        NEEDS_PLANNING=0
        VIEW=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --since) SINCE="$2"; shift 2 ;;
                --needs-planning) NEEDS_PLANNING=1; shift ;;
                --view) VIEW="$2"; shift 2 ;;
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
            # #223: label read from env var (seeded by start-colony.sh
            # from colony.toml [planning] trigger_label). Default
            # "needs-planning" preserves pre-#223 behavior for configs
            # that lack the key.
            ARGS+=(--data-urlencode "labels=${PLANNING_TRIGGER_LABEL:-needs-planning}")
        fi
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
        gl_post "$API/$ITEMS/$ID/notes" "$JSON_BODY"
        ;;

    issue-label-events)
        # #235: expose GitLab resource_label_events for a single issue, with
        # optional client-side filter by label name and/or since timestamp.
        # Projection: [{ts, action, label, user}] — stable shape independent
        # of GitLab schema drift. The endpoint itself has no --since query
        # param (unlike /issues), so the filter runs client-side.
        IID="${1:?Usage: gitlab-api.sh issue-label-events <iid> [--since ISO8601] [--label NAME]}"
        shift
        EV_SINCE=""
        EV_LABEL=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --since) EV_SINCE="$2"; shift 2 ;;
                --label) EV_LABEL="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        body="$(gl_get "$API/$ITEMS/$IID/resource_label_events?per_page=100")" || exit $?
        # Pass body via env (BODY=) rather than stdin because the heredoc
        # (<<'PY') would otherwise override the piped input — shellcheck
        # SC2259. Same idiom as the split / hit / matched / final blocks
        # below in issues-by-label-events.
        BODY="$body" EV_SINCE="$EV_SINCE" EV_LABEL="$EV_LABEL" python3 <<'PY'
import os, json
events = json.loads(os.environ["BODY"])
since = os.environ.get("EV_SINCE", "")
label = os.environ.get("EV_LABEL", "")
out = []
for ev in events:
    ev_label = (ev.get("label") or {}).get("name")
    ev_ts = ev.get("created_at") or ""
    if since and ev_ts < since:
        continue
    if label and ev_label != label:
        continue
    out.append({
        "ts": ev_ts,
        "action": ev.get("action"),
        "label": ev_label,
        "user": (ev.get("user") or {}).get("username"),
    })
print(json.dumps(out))
PY
        ;;

    issues-by-label-events)
        # #235: events-aware trigger query. Returns the union of
        #   (a) open issues that currently carry $PLANNING_TRIGGER_LABEL, and
        #   (b) open issues that had the label added at any point in
        #       [--since, now] per resource_label_events.
        # Closes the observability gap where a short-lived trigger label
        # (e.g. "DEV::not started" on projects that transition it in
        # seconds) is added and removed between two 60 s polls and the
        # current-state snapshot misses it entirely.
        EV_SINCE=""
        VIEW=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --since) EV_SINCE="$2"; shift 2 ;;
                --view) VIEW="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -z "$EV_SINCE" ]; then
            emit_error "--since is required for issues-by-label-events"
            exit 2
        fi
        LABEL="${PLANNING_TRIGGER_LABEL:-needs-planning}"
        # Fetch recent open issues with no label filter so we catch those
        # that had the trigger label briefly and lost it again.
        BASE_ARGS=(
            --data-urlencode "state=opened"
            --data-urlencode "per_page=20"
            --data-urlencode "order_by=updated_at"
            --data-urlencode "sort=desc"
            --data-urlencode "updated_after=$EV_SINCE"
        )
        recent="$(gl_get_q "$API/$ITEMS" "${BASE_ARGS[@]}")" || exit $?
        # Split into currently-labeled (include directly) and need-events-check.
        split="$(RECENT="$recent" LABEL="$LABEL" python3 <<'PY'
import os, json
items = json.loads(os.environ["RECENT"])
label = os.environ["LABEL"]
current = [x for x in items if label in (x.get("labels") or [])]
to_check = [x["iid"] for x in items if label not in (x.get("labels") or [])]
print(json.dumps({"current": current, "to_check": to_check}))
PY
)" || exit $?
        current_list="$(printf '%s' "$split" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)["current"]))')"
        iids_to_check="$(printf '%s' "$split" | python3 -c 'import sys,json;print(" ".join(str(i) for i in json.load(sys.stdin)["to_check"]))')"
        matched="[]"
        for IID in $iids_to_check; do
            ev_body="$(gl_get "$API/$ITEMS/$IID/resource_label_events?per_page=100")" || continue
            hit="$(EVBODY="$ev_body" LABEL="$LABEL" EV_SINCE="$EV_SINCE" python3 <<'PY'
import os, json
events = json.loads(os.environ["EVBODY"])
label = os.environ["LABEL"]
since = os.environ["EV_SINCE"]
for ev in events:
    ev_label = (ev.get("label") or {}).get("name")
    ev_ts = ev.get("created_at") or ""
    if ev_label == label and ev.get("action") == "add" and ev_ts >= since:
        print("1"); break
else:
    print("")
PY
)"
            if [ -n "$hit" ]; then
                issue_body="$(gl_get "$API/$ITEMS/$IID")" || continue
                matched="$(MATCHED="$matched" ISSUE="$issue_body" python3 <<'PY'
import os, json
acc = json.loads(os.environ["MATCHED"])
acc.append(json.loads(os.environ["ISSUE"]))
print(json.dumps(acc))
PY
)"
            fi
        done
        # Union current + matched, dedup by iid, preserve current-first ordering.
        final="$(CUR="$current_list" MATCHED="$matched" python3 <<'PY'
import os, json
a = json.loads(os.environ["CUR"])
b = json.loads(os.environ["MATCHED"])
seen = set()
out = []
for x in a + b:
    iid = x.get("iid")
    if iid in seen:
        continue
    seen.add(iid)
    out.append(x)
print(json.dumps(out))
PY
)"
        if [ -n "$VIEW" ]; then
            printf '%s' "$final" | project_json "$VIEW"
        else
            printf '%s' "$final"
        fi
        ;;

    merge-requests)
        STATE="opened"
        SINCE=""
        VIEW=""
        PER_PAGE=20
        while [ $# -gt 0 ]; do
            case "$1" in
                --state) STATE="$2"; shift 2 ;;
                --since) SINCE="$2"; shift 2 ;;
                --view) VIEW="$2"; shift 2 ;;
                --per-page) PER_PAGE="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        case "$PER_PAGE" in
            ''|*[!0-9]*) emit_error "invalid --per-page: $PER_PAGE (integer required)"; exit 2 ;;
        esac
        ARGS=(
            --data-urlencode "state=$STATE"
            --data-urlencode "per_page=$PER_PAGE"
            --data-urlencode "order_by=updated_at"
            --data-urlencode "sort=desc"
        )
        if [ -n "$SINCE" ]; then
            ARGS+=(--data-urlencode "updated_after=$SINCE")
        fi
        if [ -n "$VIEW" ]; then
            # Two-step pipe so gl_call's non-zero exit survives projection (see
            # issues branch above).
            body="$(gl_get_q "$API/merge_requests" "${ARGS[@]}")" || exit $?
            printf '%s' "$body" | project_json "$VIEW"
        else
            gl_get_q "$API/merge_requests" "${ARGS[@]}"
        fi
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
