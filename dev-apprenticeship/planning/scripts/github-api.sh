#!/bin/bash
# GitHub API wrapper for planning colony agents (ADR-0002, #256 PR 3 of 7).
# Called by .ag agents via forge-api.sh dispatch when FORGE_TYPE=github.
#
# Required env vars (set by start-colony.sh from [forge.github] in colony.toml):
#   GITHUB_URL    - API base (default https://api.github.com; override for GHE)
#   GITHUB_TOKEN  - personal access token (classic or fine-grained)
#   GITHUB_OWNER  - repo owner (user or org)
#   GITHUB_REPO   - repo name
#
# Optional env vars (same as gitlab-api.sh):
#   PLANNING_TRIGGER_LABEL   label used by --needs-planning (default "needs-planning")
#   GITHUB_CURL_MAX_TIME     per-attempt --max-time seconds (default 90)
#   GITHUB_CURL_RETRIES      retry budget for 5xx/timeouts/429 (default 3)
#
# Usage (identical contract to gitlab-api.sh):
#   github-api.sh issues [--needs-planning] [--since ISO8601] [--view <name>]
#   github-api.sh issues-by-label-events --since ISO8601 [--view <name>]
#   github-api.sh issue-label-events <number> [--since ISO8601] [--label NAME]
#   github-api.sh add-note <number> --body <text>
#   github-api.sh merge-requests [--state opened|merged|all] [--since ISO8601]
#                                [--per-page N] [--view <name>]
#
# Views and JSON shape are GitLab-normalized (iid <- number, author.username,
# labels-as-strings, state "open"->"opened", target_branch <- base.ref). See
# ADR-0002 §Shape. Planning only reads + posts comments; no write surface.
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
# Shape contract (fields planning views + agents consume):
#   iid (<- number), title, description (<- body), state (open->opened),
#   labels: ["name", ...] (accept both [{name, ...}] and bare strings for GHE),
#   assignees: [{username}, ...], author: {username}, created_at, updated_at,
#   user_notes_count (<- comments).
# Filters out pull_request entries — GitHub's /issues mixes PRs with issues,
# but planning only cares about issues for triage-time fields.
normalize_issues() {
    python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = []
for x in data:
    if "pull_request" in x:
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
# Single-issue variant. Used by issues-by-label-events when re-fetching a
# full issue body after a timeline hit.
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

# normalize_pulls
# Reads GitHub pulls-list JSON, writes GitLab-MR-shape JSON. Field mapping:
#   iid         <- number
#   title, description (<- body)
#   state       GitHub open -> opened; GitHub closed with merged_at != null -> merged
#   labels      flattened to strings (dict|str tolerant for GHE)
#   target_branch <- base.ref
#   merged_at   direct
#   changes_count GitHub /pulls list does NOT include changed_files; forwarded
#                 as None (planning-mr view consumers — scope_estimator — tolerate
#                 null; they only use it when present for complexity scoring)
#   user_notes_count <- comments (issue-style comments; GitHub also has
#                 review_comments separately but comments is the closest analog
#                 to GitLab's user_notes_count on MRs)
normalize_pulls() {
    python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = []
for x in data:
    st = x.get("state")
    if st == "open":
        st = "opened"
    elif st == "closed" and x.get("merged_at"):
        st = "merged"
    out.append({
        "iid": x.get("number"),
        "title": x.get("title"),
        "description": x.get("body"),
        "state": st,
        "labels": [lab if isinstance(lab, str) else lab.get("name") for lab in (x.get("labels") or []) if isinstance(lab, (str, dict))],
        "author": {"username": (x.get("user") or {}).get("login")},
        "target_branch": (x.get("base") or {}).get("ref"),
        "source_branch": (x.get("head") or {}).get("ref"),
        "merged_at": x.get("merged_at"),
        "created_at": x.get("created_at"),
        "updated_at": x.get("updated_at"),
        "changes_count": x.get("changed_files"),
        "user_notes_count": x.get("comments", 0),
    })
print(json.dumps(out))
PY
}

# normalize_timeline <label_filter> <since_filter>
# Reads GitHub /issues/{n}/timeline JSON, writes GitLab resource_label_events
# shape: [{ts, action, label, user}]. GitHub event names:
#   labeled   -> action "add"
#   unlabeled -> action "remove"
# Other timeline events (committed, reviewed, merged, cross-referenced, ...)
# are dropped. Matches gitlab-api.sh's client-side since/label filtering so
# the .ag consumer code is backend-agnostic.
normalize_timeline() {
    local label_filter="$1" since_filter="$2"
    local DATA
    DATA="$(cat)"
    DATA="$DATA" LABEL="$label_filter" SINCE="$since_filter" python3 <<'PY'
import os, json
data = json.loads(os.environ["DATA"])
label = os.environ.get("LABEL", "")
since = os.environ.get("SINCE", "")
out = []
for ev in data:
    kind = ev.get("event")
    if kind not in ("labeled", "unlabeled"):
        continue
    ev_label = (ev.get("label") or {}).get("name")
    ev_ts = ev.get("created_at") or ""
    if since and ev_ts < since:
        continue
    if label and ev_label != label:
        continue
    out.append({
        "ts": ev_ts,
        "action": "add" if kind == "labeled" else "remove",
        "label": ev_label,
        "user": (ev.get("actor") or {}).get("login"),
    })
print(json.dumps(out))
PY
}

# project_json <view-name>
# Same contract as gitlab-api.sh project_json: read normalized GitLab-shape
# JSON from stdin, write downselected projection to stdout. Duplicated here
# byte-identically so test-gitlab-views.sh's parity block catches drift.
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
        planning)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = [{"iid": x.get("iid"), "title": x.get("title"), "description": x.get("description"),
        "labels": x.get("labels", []),
        "author": {"username": (x.get("author") or {}).get("username")},
        "created_at": x.get("created_at")} for x in data]
print(json.dumps(out))
PY
            ;;
        planning-mr)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
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

if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_OWNER:-}" ] || [ -z "${GITHUB_REPO:-}" ]; then
    emit_error "GITHUB_TOKEN, GITHUB_OWNER, and GITHUB_REPO must be set"
    exit 1
fi

GITHUB_URL="${GITHUB_URL:-https://api.github.com}"
API="$GITHUB_URL/repos/$GITHUB_OWNER/$GITHUB_REPO"

# gh_call <method> <url> [curl-args...]
#
# Mirror of gitlab-api.sh gl_call (and triage github-api.sh gh_call): retry on
# 429/5xx/timeout, no-retry on 401/403, 403-secondary-rate detection via body,
# bounded curl --max-time, structured exit codes.
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

CMD="${1:?Usage: github-api.sh <command> [args...]}"
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
            --data-urlencode "state=open"
            --data-urlencode "per_page=20"
            --data-urlencode "sort=updated"
            --data-urlencode "direction=desc"
        )
        if [ "$NEEDS_PLANNING" -eq 1 ]; then
            # GitHub /issues accepts a comma-separated labels filter — same semantic
            # as GitLab's ?labels=. Scoped labels (::) and spaces pass through
            # --data-urlencode cleanly.
            ARGS+=(--data-urlencode "labels=${PLANNING_TRIGGER_LABEL:-needs-planning}")
        fi
        if [ -n "$SINCE" ]; then
            # GitHub uses `since` (not `updated_after` like GitLab).
            ARGS+=(--data-urlencode "since=$SINCE")
        fi
        body="$(gh_get_q "$API/issues" "${ARGS[@]}")" || exit $?
        normalized="$(printf '%s' "$body" | normalize_issues)"
        if [ -n "$VIEW" ]; then
            printf '%s' "$normalized" | project_json "$VIEW"
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

    issue-label-events)
        # GitHub's equivalent of GitLab /issues/{iid}/resource_label_events is
        # /issues/{n}/timeline filtered to event in ("labeled", "unlabeled").
        # Timeline has no --since query; we filter client-side (same as
        # gitlab-api.sh does for parity).
        IID="${1:?Usage: github-api.sh issue-label-events <number> [--since ISO8601] [--label NAME]}"
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
        case "$IID" in
            ''|*[!0-9]*) emit_error "issue number must be numeric: $IID"; exit 2 ;;
        esac
        body="$(gh_get_q "$API/issues/$IID/timeline" --data-urlencode "per_page=100")" || exit $?
        printf '%s' "$body" | normalize_timeline "$EV_LABEL" "$EV_SINCE"
        ;;

    issues-by-label-events)
        # Composite trigger query (parity with gitlab-api.sh issues-by-label-events).
        # Returns the union of:
        #   (a) open issues that currently carry $PLANNING_TRIGGER_LABEL, and
        #   (b) open issues that had that label added at any point in
        #       [--since, now] per the /timeline endpoint.
        # Closes the same short-lived-trigger-label observability gap as the
        # GitLab variant — the current-state snapshot misses issues where the
        # label was added and removed between two 60s polls.
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
        BASE_ARGS=(
            --data-urlencode "state=open"
            --data-urlencode "per_page=20"
            --data-urlencode "sort=updated"
            --data-urlencode "direction=desc"
            --data-urlencode "since=$EV_SINCE"
        )
        recent_raw="$(gh_get_q "$API/issues" "${BASE_ARGS[@]}")" || exit $?
        recent="$(printf '%s' "$recent_raw" | normalize_issues)"
        # Split: currently-labeled (direct include) vs. needs timeline check.
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
            tl_body="$(gh_get_q "$API/issues/$IID/timeline" --data-urlencode "per_page=100")" || continue
            hit="$(TLBODY="$tl_body" LABEL="$LABEL" EV_SINCE="$EV_SINCE" python3 <<'PY'
import os, json
events = json.loads(os.environ["TLBODY"])
label = os.environ["LABEL"]
since = os.environ["EV_SINCE"]
for ev in events:
    if ev.get("event") != "labeled":
        continue
    ev_label = (ev.get("label") or {}).get("name")
    ev_ts = ev.get("created_at") or ""
    if ev_label == label and ev_ts >= since:
        print("1"); break
else:
    print("")
PY
)"
            if [ -n "$hit" ]; then
                issue_raw="$(gh_get "$API/issues/$IID")" || continue
                issue_norm="$(printf '%s' "$issue_raw" | normalize_issue)"
                matched="$(MATCHED="$matched" ISSUE="$issue_norm" python3 <<'PY'
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

    merge-requests)
        # GitHub has /pulls (pull requests). Semantic collapses:
        #   --state opened -> GitHub `open`
        #   --state merged -> GitHub `closed` + local filter on merged_at != null
        #                     (GitHub's /pulls has no "merged" state)
        #   --state all    -> GitHub `all`
        # GitHub /pulls does NOT accept `since` directly; we fetch sort=updated
        # desc + filter client-side. `per_page` bounds the response so this is
        # deterministic for the scope_estimator's "recent MRs" window.
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
        MERGED_FILTER=0
        case "$STATE" in
            opened|open) GH_STATE="open" ;;
            closed)      GH_STATE="closed" ;;
            merged)      GH_STATE="closed"; MERGED_FILTER=1 ;;
            all)         GH_STATE="all" ;;
            *) emit_error "unknown --state: $STATE (expected opened|merged|closed|all)"; exit 2 ;;
        esac
        ARGS=(
            --data-urlencode "state=$GH_STATE"
            --data-urlencode "per_page=$PER_PAGE"
            --data-urlencode "sort=updated"
            --data-urlencode "direction=desc"
        )
        body="$(gh_get_q "$API/pulls" "${ARGS[@]}")" || exit $?
        normalized="$(printf '%s' "$body" | normalize_pulls)"
        if [ "$MERGED_FILTER" -eq 1 ] || [ -n "$SINCE" ]; then
            normalized="$(printf '%s' "$normalized" | SINCE="$SINCE" MERGED="$MERGED_FILTER" python3 /dev/fd/3 3<<'PY'
import os, sys, json
items = json.loads(sys.stdin.read())
since = os.environ.get("SINCE", "")
merged_only = os.environ.get("MERGED", "0") == "1"
out = []
for x in items:
    if merged_only and not x.get("merged_at"):
        continue
    if since:
        ts = x.get("updated_at") or ""
        if ts < since:
            continue
    out.append(x)
print(json.dumps(out))
PY
)"
        fi
        if [ -n "$VIEW" ]; then
            printf '%s' "$normalized" | project_json "$VIEW"
        else
            printf '%s' "$normalized"
        fi
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
