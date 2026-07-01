#!/bin/bash
# GitLab API wrapper for implementation colony agents.
# Called by .ag agents via exec sh.
#
# Required env vars (set by start-colony.sh from colony.toml):
#   GITLAB_URL                     - GitLab instance URL (e.g. https://gitlab.example.com)
#   GITLAB_TOKEN                   - Personal access token or project token
#   GITLAB_PROJECT                 - URL-encoded project path (e.g. your-org%2Fyour-project)
#   IMPLEMENTATION_TRIGGER_LABEL   - (optional, #225) label name used by
#                                    `assigned-issues` filter. Defaults to
#                                    "implementation" when unset.
#   GITLAB_DEFAULT_BRANCH          - (optional, #224) primary branch name used as the
#                                    default --ref for create-branch and the
#                                    target_branch for create-mr. Defaults to "main"
#                                    when unset.
#
# Usage:
#   gitlab-api.sh merge-requests [--state merged] [--since ISO8601] [--per-page N] [--view <name>]
#   gitlab-api.sh mr-changes <iid>
#   gitlab-api.sh mr-commits <iid>
#   gitlab-api.sh issue <iid>
#   gitlab-api.sh assigned-issues [--since ISO8601] [--view <name>] [--include-unassigned]
#   gitlab-api.sh assigned-issues-by-label-events --since ISO8601 [--view <name>] [--include-unassigned]
#   gitlab-api.sh issue-label-events <iid> [--since ISO8601] [--label NAME]
#   gitlab-api.sh create-branch --name <name> --ref <ref>
#   gitlab-api.sh commit-files --branch <b> --message <m> --actions <json>
#   gitlab-api.sh create-mr --source <branch> --title <title> [--description <d>]
#   gitlab-api.sh add-note <iid> --body <text>
#   gitlab-api.sh post-note <iid> --body <text>
#   gitlab-api.sh get-file --path <path> [--ref <branch>]
#
# Views (opt-in projection; default is full JSON):
#   merge-requests  --view impl       [{iid, title, merged_at, target_branch}]
#   assigned-issues --view assigned   [{iid, title, description, labels,
#                                       assignees:[{username}], priority, updated_at}]
#   <cmd>           --view raw        explicit pass-through (same as no flag)
#   GITLAB_VIEW_MODE=raw              env-override that forces pass-through globally.
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
        impl)
            DATA="$DATA" python3 <<'PY'
import os, json
data = json.loads(os.environ["DATA"])
out = [{"iid": x.get("iid"), "title": x.get("title"),
        "merged_at": x.get("merged_at"), "target_branch": x.get("target_branch")} for x in data]
print(json.dumps(out))
PY
            ;;
        assigned)
            DATA="$DATA" python3 <<'PY'
import os, json
data = json.loads(os.environ["DATA"])
out = [{"iid": x.get("iid"), "title": x.get("title"), "description": x.get("description"),
        "labels": x.get("labels", []),
        "assignees": [{"username": a.get("username")} for a in x.get("assignees", [])],
        "priority": x.get("priority"), "updated_at": x.get("updated_at")} for x in data]
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

# GitLab renamed the issue-tracking REST collection from /issues to the unified
# /work_items collection (#1119). Resolve the collection segment in one place so
# every issue read/write routes through it. Default = work_items (migrated
# instances). Set GITLAB_ISSUE_COLLECTION=issues to pin the legacy path on a
# non-migrated instance — no code change required.
ISSUE_COLLECTION="${GITLAB_ISSUE_COLLECTION:-work_items}"

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
# _backoff_sleep <delay> — sleep for <delay> seconds plus jitter (#1115).
#
# The retry loop already grows <delay> exponentially (delay=$((delay * 2))).
# Adding jitter on top spreads simultaneous retries from many agents so a
# shared 429 does not synchronise into a thundering-herd retry storm. Jitter
# is equal-jitter: the slept value lands in [delay, delay + delay/2], i.e. up
# to +50% of the base delay, so the lower bound preserves the exponential
# floor while the upper bound stays predictable for tests.
#
# GITLAB_BACKOFF_DRYRUN=1 turns this into a no-sleep trace: the chosen value
# is appended to $GITLAB_BACKOFF_TRACE (one integer per line) and no sleep
# happens, so tools/test-rate-limit-backoff.sh can assert growth + jitter
# bounds deterministically without waiting on real wall-clock seconds.
_backoff_sleep() {
    local base="$1"
    local span jitter slept
    span=$((base / 2))
    if [ "$span" -lt 1 ]; then
        span=1
    fi
    # RANDOM is bash-builtin (0..32767); modulo into [0, span].
    jitter=$((RANDOM % (span + 1)))
    slept=$((base + jitter))
    if [ "${GITLAB_BACKOFF_DRYRUN:-0}" = "1" ]; then
        if [ -n "${GITLAB_BACKOFF_TRACE:-}" ]; then
            echo "$slept" >> "$GITLAB_BACKOFF_TRACE"
        fi
        return 0
    fi
    sleep "$slept"
}

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
                _backoff_sleep "$delay"
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
                    _backoff_sleep "$delay"
                    delay=$((delay * 2))
                    continue
                fi
                emit_error "rate limited (HTTP 429) after $attempt attempts on $method $url"
                return 3
                ;;
            5*)
                if [ "$attempt" -le "$max_retries" ]; then
                    _backoff_sleep "$delay"
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
            # Two-step so gl_call's non-zero exit (auth/429/5xx/transport)
            # survives the projection pipe. A bare `gl_get_q ... | project_json`
            # would let python3 (or `cat` when GITLAB_VIEW_MODE=raw) override
            # the meaningful exit code with 0 or 1, masking the real failure.
            body="$(gl_get_q "$API/merge_requests" "${ARGS[@]}")" || exit $?
            printf '%s' "$body" | project_json "$VIEW"
        else
            gl_get_q "$API/merge_requests" "${ARGS[@]}"
        fi
        ;;

    mr-changes)
        IID="${1:?Usage: gitlab-api.sh mr-changes <iid>}"
        gl_get "$API/merge_requests/$IID/changes"
        ;;

    mr-commits)
        IID="${1:?Usage: gitlab-api.sh mr-commits <iid>}"
        gl_get "$API/merge_requests/$IID/commits?per_page=100"
        ;;

    mr-notes)
        # #1360: read the MR's notes for the review-resolver in code_writer (poll
        # the durable review note instead of the ephemeral bus). Ported from the
        # code-review backend; the raw GitLab notes shape carries id, body,
        # author.username, created_at, and the `system` boolean the scanner filters
        # on. Numeric guard mirrors this backend's pr-checks contract (exit 2).
        IID="${1:?Usage: gitlab-api.sh mr-notes <iid>}"
        case "$IID" in
            ''|*[!0-9]*) emit_error "iid must be numeric: $IID"; exit 2 ;;
        esac
        gl_get "$API/merge_requests/$IID/notes?per_page=100&order_by=created_at&sort=desc"
        ;;

    pr-checks)
        # #1332: CI verdict read for the bounded red-PR recovery loop (code_writer
        # re-drives its OWN red MRs). Prints exactly two space-separated tokens on
        # stdout: `STATE=<red|green|pending> REF=<source-branch>`. Read-only mirror
        # of the code-review colony's #1317 merge gate pipeline check: head-pipeline
        # pending/running => pending, failed/canceled => red, success => green,
        # missing pipeline => pending (CI not verified yet). Recovery acts only on
        # `red`, never `pending` (don't race CI).
        IID="${1:?Usage: gitlab-api.sh pr-checks <iid>}"
        case "$IID" in
            ''|*[!0-9]*) emit_error "iid must be numeric: $IID"; exit 2 ;;
        esac
        mr_json="$(gl_get "$API/merge_requests/$IID")" || exit $?
        VERDICT="$(printf '%s' "$mr_json" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
ref = d.get("source_branch") or ""
pipeline = d.get("head_pipeline") or d.get("pipeline") or {}
pstatus = pipeline.get("status")
if pstatus in ("pending", "running", "created", "waiting_for_resource", "preparing", "scheduled"):
    state = "pending"
elif pstatus in ("failed", "canceled", "cancelled"):
    state = "red"
elif pstatus == "success":
    state = "green"
else:
    state = "pending"
print("STATE=%s REF=%s" % (state, ref))
')" || { emit_error "MR !$IID: failed to parse pipeline metadata"; exit 4; }
        printf '%s\n' "$VERDICT"
        ;;

    issue)
        IID="${1:?Usage: gitlab-api.sh issue <iid>}"
        gl_get "$API/$ISSUE_COLLECTION/$IID"
        ;;

    assigned-issues)
        SINCE=""
        VIEW=""
        INCLUDE_UNASSIGNED=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --since) SINCE="$2"; shift 2 ;;
                --view) VIEW="$2"; shift 2 ;;
                --include-unassigned) INCLUDE_UNASSIGNED=1; shift ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        # #291: --include-unassigned drops the assignee_id=Any filter so the
        # label alone is the trigger signal. Unblocks code_writer's action
        # path on repos where labeled issues are typically unassigned.
        ARGS=(
            --data-urlencode "state=opened"
            --data-urlencode "labels=${IMPLEMENTATION_TRIGGER_LABEL:-implementation}"
            --data-urlencode "per_page=20"
            --data-urlencode "order_by=updated_at"
            --data-urlencode "sort=desc"
        )
        if [ "$INCLUDE_UNASSIGNED" = "0" ]; then
            ARGS+=(--data-urlencode "assignee_id=Any")
        fi
        if [ -n "$SINCE" ]; then
            ARGS+=(--data-urlencode "updated_after=$SINCE")
        fi
        if [ -n "$VIEW" ]; then
            # Two-step pipe so gl_call's non-zero exit survives projection (see
            # merge-requests branch above).
            body="$(gl_get_q "$API/$ISSUE_COLLECTION" "${ARGS[@]}")" || exit $?
            printf '%s' "$body" | project_json "$VIEW"
        else
            gl_get_q "$API/$ISSUE_COLLECTION" "${ARGS[@]}"
        fi
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
        body="$(gl_get "$API/$ISSUE_COLLECTION/$IID/resource_label_events?per_page=100")" || exit $?
        # Pass body via env (BODY=) rather than stdin because the heredoc
        # (<<'PY') would otherwise override the piped input — shellcheck
        # SC2259. Same idiom as the split / hit / matched / final blocks
        # below in assigned-issues-by-label-events.
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

    assigned-issues-by-label-events)
        # #235: events-aware trigger query for implementation colony. Returns
        # the union of
        #   (a) open issues currently assigned to anyone and carrying
        #       $IMPLEMENTATION_TRIGGER_LABEL, and
        #   (b) open assigned issues that had the label added at any point
        #       in [--since, now] per resource_label_events.
        # Closes the observability gap where a short-lived trigger label
        # is added and removed between two 60 s polls. Mirrors the planning
        # colony's issues-by-label-events (#235) but keeps the assignee_id
        # filter that assigned-issues uses.
        # #291: --include-unassigned drops the assignee_id filter; label-event
        # window matching is unchanged.
        EV_SINCE=""
        VIEW=""
        INCLUDE_UNASSIGNED=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --since) EV_SINCE="$2"; shift 2 ;;
                --view) VIEW="$2"; shift 2 ;;
                --include-unassigned) INCLUDE_UNASSIGNED=1; shift ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -z "$EV_SINCE" ]; then
            emit_error "--since is required for assigned-issues-by-label-events"
            exit 2
        fi
        LABEL="${IMPLEMENTATION_TRIGGER_LABEL:-implementation}"
        # Fetch recent open assigned issues with no label filter so we catch
        # those that had the trigger label briefly and lost it again.
        BASE_ARGS=(
            --data-urlencode "state=opened"
            --data-urlencode "per_page=20"
            --data-urlencode "order_by=updated_at"
            --data-urlencode "sort=desc"
            --data-urlencode "updated_after=$EV_SINCE"
        )
        if [ "$INCLUDE_UNASSIGNED" = "0" ]; then
            BASE_ARGS+=(--data-urlencode "assignee_id=Any")
        fi
        recent="$(gl_get_q "$API/$ISSUE_COLLECTION" "${BASE_ARGS[@]}")" || exit $?
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
            ev_body="$(gl_get "$API/$ISSUE_COLLECTION/$IID/resource_label_events?per_page=100")" || continue
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
                issue_body="$(gl_get "$API/$ISSUE_COLLECTION/$IID")" || continue
                matched="$(MATCHED="$matched" ISSUE="$issue_body" python3 <<'PY'
import os, json
acc = json.loads(os.environ["MATCHED"])
acc.append(json.loads(os.environ["ISSUE"]))
print(json.dumps(acc))
PY
)"
            fi
        done
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

    create-branch)
        NAME=""
        # #224: honour operator-configured default branch; fall back to "main"
        # for pre-#224 setups where the env var is unset.
        REF="${GITLAB_DEFAULT_BRANCH:-main}"
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
        # Idempotency (#1170, mirrors github-api.sh create-branch #1150): a retry
        # after a prior failed commit finds the branch already present, and
        # GitLab answers the create POST with an error containing "Branch already
        # exists" (typically HTTP 400). The branch being present is the desired
        # end state, so treat that one case as success: GET the existing branch
        # and emit it so callers receive a create-shaped payload, exit 0.
        # gl_post surfaces the error body snippet on stderr (gl_call's 4xx arm),
        # so we capture stderr to a temp file and only swallow the "already
        # exists" signature — any other failure re-surfaces its error and
        # propagates the original gl_post exit code.
        cb_err_file="$(mktemp)"
        cb_out=""
        cb_rc=0
        cb_out="$(gl_post "$API/repository/branches" "$JSON_BODY" 2>"$cb_err_file")" || cb_rc=$?
        if [ "$cb_rc" -eq 0 ]; then
            rm -f "$cb_err_file"
            printf '%s' "$cb_out"
        else
            cb_err="$(cat "$cb_err_file")"
            rm -f "$cb_err_file"
            case "$cb_err" in
                *"Branch already exists"*|*"already exists"*)
                    # Branch already present — desired end state reached. GitLab
                    # needs the branch name percent-encoded into the URL path
                    # segment (same urllib.parse.quote safe="" idiom as get-file).
                    ENC_BRANCH="$(NAME="$NAME" python3 -c 'import os,urllib.parse;print(urllib.parse.quote(os.environ["NAME"], safe=""))')"
                    existing_branch="$(gl_get "$API/repository/branches/$ENC_BRANCH")" || exit $?
                    printf '%s' "$existing_branch"
                    ;;
                *)
                    # Real failure: re-surface the captured error and propagate
                    # the original gl_post exit code.
                    printf '%s\n' "$cb_err" >&2
                    exit "$cb_rc"
                    ;;
            esac
        fi
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
# strict=False permits literal control chars (raw newlines, tabs) inside JSON
# strings — LLM-generated file `content` routinely carries them (#1169, mirrors
# the github-api.sh commit-files fix #1149). A strict parse rejects such
# payloads with "Invalid control character".
actions = json.loads(os.environ["ACTIONS"], strict=False)
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
        # #224: target_branch reads from operator-configured default branch;
        # env var passed through to the heredoc since python3 cannot see the
        # ${VAR:-fallback} expansion in the bash context.
        JSON_BODY=$(SOURCE="$SOURCE" TITLE="$TITLE" DESC="$DESC" \
            DEFAULT_BRANCH="${GITLAB_DEFAULT_BRANCH:-main}" python3 - <<'PY'
import os, json
body = {
    "source_branch": os.environ["SOURCE"],
    "target_branch": os.environ["DEFAULT_BRANCH"],
    "title": os.environ["TITLE"],
}
if os.environ.get("DESC"):
    body["description"] = os.environ["DESC"]
print(json.dumps(body))
PY
)
        gl_post "$API/merge_requests" "$JSON_BODY"
        ;;

    add-note)
        # Back-ported from triage/scripts/gitlab-api.sh (#256 PR 4). All four
        # implementation agents (code_writer, test_writer, refactorer,
        # commit_composer) shell out to `gitlab-api.sh add-note <iid> --body …`
        # on their review-gated branches; prior to this PR the call silently
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
        gl_post "$API/$ISSUE_COLLECTION/$ID/notes" "$JSON_BODY"
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

    get-file)
        # #1172: fetch the raw decoded content of a single file at --ref so
        # code_writer can EDIT an existing file instead of clobbering it with
        # a from-scratch rewrite. GET /projects/{id}/repository/files/{path}?ref={ref}
        # returns a JSON object with base64-encoded `.content`; we decode it to
        # stdout. The file path must be URL-encoded into the path segment (GitLab
        # requires the whole path percent-encoded, including slashes). A 404
        # (file does not exist on that ref) is NOT an error here: the caller
        # treats empty output as "new file", so we swallow the 404 and exit 0.
        # Any other HTTP error propagates (gl_get's emit_error + non-zero return).
        FILE_PATH=""
        FILE_REF="${GITLAB_DEFAULT_BRANCH:-main}"
        while [ $# -gt 0 ]; do
            case "$1" in
                --path) FILE_PATH="$2"; shift 2 ;;
                --ref) FILE_REF="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -z "$FILE_PATH" ]; then
            emit_error "--path is required"
            exit 1
        fi
        # GitLab needs the file path percent-encoded into the URL path segment
        # (slashes become %2F). python3 urllib.parse.quote with safe="" encodes
        # every reserved char. The ref travels as a -G query param via gl_get_q.
        ENC_PATH="$(FILE_PATH="$FILE_PATH" python3 -c 'import os,urllib.parse;print(urllib.parse.quote(os.environ["FILE_PATH"], safe=""))')"
        gf_err_file="$(mktemp)"
        gf_out=""
        gf_rc=0
        gf_out="$(gl_get_q "$API/repository/files/$ENC_PATH" --data-urlencode "ref=$FILE_REF" 2>"$gf_err_file")" || gf_rc=$?
        if [ "$gf_rc" -eq 0 ]; then
            rm -f "$gf_err_file"
            printf '%s' "$gf_out" | python3 -c 'import sys,json,base64; d=json.loads(sys.stdin.read()); sys.stdout.buffer.write(base64.b64decode((d.get("content") or "")))'
        else
            gf_err="$(cat "$gf_err_file")"
            rm -f "$gf_err_file"
            case "$gf_err" in
                *"HTTP 404"*)
                    # File does not exist on this ref — emit nothing, exit 0.
                    :
                    ;;
                *)
                    printf '%s\n' "$gf_err" >&2
                    exit "$gf_rc"
                    ;;
            esac
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
