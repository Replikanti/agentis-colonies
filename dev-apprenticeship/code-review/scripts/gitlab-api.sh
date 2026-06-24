#!/bin/bash
# GitLab API wrapper for code-review colony agents.
# Called by .ag agents via exec sh.
#
# Required env vars (set by start-colony.sh from colony.toml):
#   GITLAB_URL     - GitLab instance URL
#   GITLAB_TOKEN   - Personal access token or project token
#   GITLAB_PROJECT - URL-encoded project path
#
# Usage:
#   gitlab-api.sh merge-requests [--since ISO8601] [--state opened|merged|all] [--per-page N] [--view <name>]
#   gitlab-api.sh mr-changes <iid>
#   gitlab-api.sh mr-notes <iid>
#   gitlab-api.sh post-note <iid> --body <text>
#   gitlab-api.sh approve <iid>
#   gitlab-api.sh merge <iid>   (gated: refuses unless merge_status ==
#                                can_be_merged AND head pipeline succeeded;
#                                squash + remove source branch; #1317)
#   gitlab-api.sh pr-checks <iid>  (CI verdict for the red-PR recovery loop;
#                                prints `STATE=<red|green|pending> REF=<branch>`
#                                on stdout; #1332)
#   gitlab-api.sh get-issue <iid>
#
# Views (opt-in projection; default is full JSON):
#   merge-requests --view reviewer  [{iid, state, title, labels,
#                                     source_branch, target_branch, draft}]
#   merge-requests --view raw       explicit pass-through (same as no flag)
#   GITLAB_VIEW_MODE=raw            env-override that forces pass-through globally.
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
# stdout. See the triage colony's gitlab-api.sh for the full design note;
# the short version is that each view keeps only the fields a downstream
# agent's prompt() actually needs, and GITLAB_VIEW_MODE=raw lets operators
# roll back to full payloads without editing .ag sources.
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
        reviewer)
            DATA="$DATA" python3 <<'PY'
import os, json
data = json.loads(os.environ["DATA"])
# #104: include author.username so style_reviewer can tag knowledge
# as personal (operator's own MR) vs team.
# #317: include description so reviewers can scan it for cross-repo refs.
out = [{"iid": x.get("iid"), "state": x.get("state"), "title": x.get("title"),
        "description": x.get("description"),
        "labels": x.get("labels", []), "source_branch": x.get("source_branch"),
        "target_branch": x.get("target_branch"), "draft": x.get("draft"),
        "author": {"username": (x.get("author") or {}).get("username")}} for x in data]
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

gl_put() {
    gl_call PUT "$1" -H "Content-Type: application/json" -d "$2"
}

CMD="${1:?Usage: gitlab-api.sh <command> [args...]}"
shift

case "$CMD" in
    merge-requests)
        SINCE=""
        STATE="opened"
        VIEW=""
        PER_PAGE=20
        while [ $# -gt 0 ]; do
            case "$1" in
                --since) SINCE="$2"; shift 2 ;;
                --state) STATE="$2"; shift 2 ;;
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

    mr-notes)
        IID="${1:?Usage: gitlab-api.sh mr-notes <iid>}"
        gl_get "$API/merge_requests/$IID/notes?per_page=100&order_by=created_at&sort=desc"
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

    approve)
        IID="${1:?Usage: gitlab-api.sh approve <iid>}"
        gl_post "$API/merge_requests/$IID/approve" "{}"
        ;;

    merge)
        # #1317: gated, opt-in terminal merge (GitHub parity). The SAFETY
        # chokepoint: refuse unless GitLab reports the MR is cleanly
        # mergeable AND its head pipeline succeeded. Either gate failing
        # means no merge (exit 4); the caller logs a no-op and retries.
        IID="${1:?Usage: gitlab-api.sh merge <iid>}"
        case "$IID" in
            ''|*[!0-9]*) emit_error "iid must be numeric: $IID"; exit 2 ;;
        esac

        # GET the MR once and read both gate inputs from it: `merge_status`
        # (must be can_be_merged) and the head pipeline status. GitLab
        # exposes the latest pipeline as either `.head_pipeline` (newer) or
        # `.pipeline` (older); accept whichever is present and require its
        # status == success. Absent / non-success pipeline => refuse.
        mr_json="$(gl_get "$API/merge_requests/$IID")" || exit $?
        MERGE_VERDICT="$(printf '%s' "$mr_json" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
merge_status = d.get("merge_status")
if merge_status != "can_be_merged":
    print("REFUSE merge_status=%s" % merge_status)
    sys.exit(0)
pipeline = d.get("head_pipeline") or d.get("pipeline") or {}
pstatus = pipeline.get("status")
if pstatus != "success":
    print("REFUSE pipeline status=%s" % pstatus)
    sys.exit(0)
print("OK")
')" || { emit_error "MR !$IID: failed to parse merge metadata"; exit 4; }
        if [ "$MERGE_VERDICT" != "OK" ]; then
            emit_error "MR !$IID not mergeable (${MERGE_VERDICT#REFUSE })"
            exit 4
        fi

        # Both gates passed: squash-merge + remove the source branch.
        # Body via python3 json.dumps (repo convention).
        MERGE_BODY="$(python3 -c 'import json; print(json.dumps({"squash": True, "should_remove_source_branch": True}))')"
        gl_put "$API/merge_requests/$IID/merge" "$MERGE_BODY"
        ;;

    pr-checks)
        # #1332: CI verdict read for the bounded red-PR recovery loop. Prints
        # exactly two space-separated tokens on stdout:
        #   STATE=<red|green|pending> REF=<source-branch>
        # so the .ag can branch on STATE and re-drive the EXISTING source
        # branch. Read-only mirror of the #1317 merge gate's pipeline check:
        # head-pipeline pending/running => pending, failed/canceled => red,
        # success => green, missing pipeline => pending (CI not verified yet).
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

    get-issue)
        # #317: single-issue fetch for the cross-repo reference resolver.
        # Argv parity with the triage colony's gitlab-api.sh get-issue (#106
        # introduced it there for the feedback matcher); the resolver in
        # tools/resolve-cross-repo-ref.sh consumes the GitLab-shape JSON
        # directly — no normalization step needed since GitLab issues are
        # the canonical shape that github-api.sh's normalize_issue mirrors.
        if [ $# -lt 1 ]; then
            emit_error "Usage: gitlab-api.sh get-issue <iid>"
            exit 2
        fi
        IID="$1"
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        case "$IID" in
            ''|*[!0-9]*) emit_error "iid must be numeric: $IID"; exit 2 ;;
        esac
        gl_get "$API/$ISSUE_COLLECTION/$IID"
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
