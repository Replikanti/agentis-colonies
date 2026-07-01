#!/bin/bash
# GitHub API wrapper for implementation colony agents (ADR-0002, #256 PR 4 of 7).
# Called by .ag agents via forge-api.sh dispatch when FORGE_TYPE=github.
#
# Required env vars (set by start-colony.sh from [forge.github] in colony.toml):
#   GITHUB_URL    - API base (default https://api.github.com; override for GHE)
#   GITHUB_TOKEN  - personal access token (classic or fine-grained)
#   GITHUB_OWNER  - repo owner (user or org)
#   GITHUB_REPO   - repo name
#
# Optional env vars:
#   IMPLEMENTATION_TRIGGER_LABEL  label used by assigned-issues (default
#                                 "implementation", parity with gitlab-api.sh)
#   GITLAB_DEFAULT_BRANCH         base/target branch for create-branch +
#                                 create-mr (default "main"). The name is
#                                 a GitLab holdover kept for backend-agnostic
#                                 dispatch (ADR-0002); renaming the env var
#                                 was deferred past #256 to avoid an extra
#                                 cross-colony churn — operators still set
#                                 the value via [forge.<backend>] default_branch.
#   GITHUB_ME                     authenticated-user login (optional, used
#                                 to scope assigned-issues)
#   GITHUB_CURL_MAX_TIME          per-attempt --max-time seconds (default 90)
#   GITHUB_CURL_RETRIES           retry budget for 5xx/timeouts/429 (default 3)
#
# Usage (identical contract to gitlab-api.sh):
#   github-api.sh merge-requests [--state opened|merged|closed|all] [--since ISO8601]
#                                [--per-page N] [--view <name>]
#   github-api.sh mr-changes <number>
#   github-api.sh mr-commits <number>
#   github-api.sh issue <number>
#   github-api.sh assigned-issues [--since ISO8601] [--view <name>] [--include-unassigned]
#   github-api.sh assigned-issues-by-label-events --since ISO8601 [--view <name>] [--include-unassigned]
#   github-api.sh issue-label-events <number> [--since ISO8601] [--label NAME]
#   github-api.sh create-branch --name <name> [--ref <ref>]
#   github-api.sh commit-files --branch <b> --message <m> --actions <json>
#   github-api.sh create-mr --source <branch> --title <title> [--description <d>]
#   github-api.sh add-note <number> --body <text>
#   github-api.sh get-file --path <path> [--ref <branch>]
#
# Views (opt-in projection; byte-identical to gitlab-api.sh):
#   merge-requests  --view impl       [{iid, title, merged_at, target_branch}]
#   assigned-issues --view assigned   [{iid, title, description, labels,
#                                       assignees:[{username}], priority}]
#   <cmd>           --view raw        explicit pass-through (same as no flag)
#   GITLAB_VIEW_MODE=raw              env-override that forces pass-through.
#
# Semantic collapses vs GitLab:
#   /pulls               replaces /merge_requests; state merged -> closed +
#                        client-side merged_at!=null filter; no `since`
#                        query param, --since is client-side on updated_at.
#   /pulls/{n}/files     replaces /merge_requests/{iid}/changes; per-file
#                        entries are wrapped into {"changes": [...]} for
#                        shape parity with the GitLab MR-changes response.
#   /pulls/{n}/commits   replaces /merge_requests/{iid}/commits; author
#                        data lifted from commit.author into GitLab-style
#                        {id, title, message, author_name, created_at}.
#   /issues/{n}/timeline replaces /resource_label_events (PR 3 parity).
#   /git/refs + /git/trees + /git/commits
#                        implement commit-files via the 5-step Git DB dance,
#                        since GitHub has no one-shot multi-file commit endpoint.
#
# Exit codes:
#   0  ok (2xx)
#   1  usage error (required flag missing, backend rejection, unsupported action)
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
# Reads GitHub issues-list JSON from stdin, writes GitLab-shape JSON.
# Filters pull_request entries (GitHub /issues mixes PRs with issues).
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
        # GitHub has no "priority" field; leave null so the assigned view's
        # priority key resolves consistently (None, not missing).
        "priority": None,
    })
print(json.dumps(out))
PY
}

# normalize_issue
# Single-issue variant (used by `issue <n>` and by assigned-issues-by-label-events
# after a timeline hit).
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
    "priority": None,
}))
PY
}

# normalize_pulls
# Reads GitHub pulls-list JSON, writes GitLab-MR-shape JSON.
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
        # /pulls list endpoint omits changed_files (only on single-PR fetch);
        # forward as null. Consumers tolerate null.
        "changes_count": x.get("changed_files"),
        "user_notes_count": x.get("comments", 0),
    })
print(json.dumps(out))
PY
}

# normalize_mr_changes
# Reads GitHub /pulls/{n}/files JSON, writes a GitLab-mr-changes-shape JSON
# object: {"changes": [{"old_path", "new_path", "diff", "new_file",
# "deleted_file", "renamed_file"}, ...]}. Matches the subset that the
# implementation .ag agents feed to prompt() when learning from prior MRs.
# GitHub's "status" field drives new_file/deleted_file/renamed_file; "patch"
# is the unified-diff text (may be absent on binary files).
normalize_mr_changes() {
    python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = []
for f in data:
    status = f.get("status") or ""
    path = f.get("filename") or ""
    prev = f.get("previous_filename") or path
    out.append({
        "old_path": prev,
        "new_path": path,
        "diff": f.get("patch") or "",
        "new_file": status == "added",
        "deleted_file": status == "removed",
        "renamed_file": status == "renamed",
    })
print(json.dumps({"changes": out}))
PY
}

# normalize_mr_commits
# Reads GitHub /pulls/{n}/commits JSON, writes a GitLab-mr-commits-shape
# JSON array: [{"id", "title", "message", "author_name", "created_at"}, ...].
# GitHub's `commit.author` carries {name, email, date}; we lift `name` into
# the flat author_name field for prompt-friendliness. "title" is the first
# line of the commit message (same as GitLab's behavior).
normalize_mr_commits() {
    python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = []
for c in data:
    commit = c.get("commit") or {}
    author = commit.get("author") or {}
    msg = commit.get("message") or ""
    title = msg.split("\n", 1)[0] if msg else ""
    out.append({
        "id": c.get("sha"),
        "title": title,
        "message": msg,
        "author_name": author.get("name"),
        "created_at": author.get("date"),
    })
print(json.dumps(out))
PY
}

# normalize_notes
# Reads GitHub /issues/{n}/comments JSON, writes GitLab /notes-shape:
# [{id, body, author:{username}, created_at, system}]. GitHub's issue-comments
# endpoint returns only human discussion — state-change / label / review
# system events live in /issues/{n}/timeline. We stamp system: false on every
# row so the GitLab-shape filter (`if not system`) that consumers apply over
# mr-notes continues to work. Ported from the code-review backend (#1360) so the
# review-resolver in code_writer can poll its own PRs' durable review notes.
normalize_notes() {
    python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = [{
    "id": c.get("id"),
    "body": c.get("body"),
    "author": {"username": (c.get("user") or {}).get("login")},
    "created_at": c.get("created_at"),
    "updated_at": c.get("updated_at"),
    "system": False,
} for c in data]
print(json.dumps(out))
PY
}

# normalize_timeline <label_filter> <since_filter>
# Reads GitHub /issues/{n}/timeline JSON, writes GitLab resource_label_events
# shape: [{ts, action, label, user}]. Same logic as the planning wrapper —
# duplicated rather than sourced so the two scripts have no runtime coupling.
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
# Byte-identical to gitlab-api.sh project_json; test-gitlab-views.sh enforces
# parity. Two views (impl, assigned) plus raw pass-throughs.
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
        impl)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = [{"iid": x.get("iid"), "title": x.get("title"),
        "merged_at": x.get("merged_at"), "target_branch": x.get("target_branch")} for x in data]
print(json.dumps(out))
PY
            ;;
        assigned)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
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
# Mirrors planning/triage gh_call: retry on 429/5xx/timeout, no-retry on
# 401/403 non-rate-limit, 403-secondary-rate detection via body snippet,
# bounded curl --max-time.
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

gh_patch() {
    gh_call PATCH "$1" -H "Content-Type: application/json" -d "$2"
}

CMD="${1:?Usage: github-api.sh <command> [args...]}"
shift

case "$CMD" in
    merge-requests)
        # Same as planning's merge-requests arm: state collapse + client-side
        # --since filter (GitHub /pulls has no `since` query param).
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

    mr-changes)
        IID="${1:?Usage: github-api.sh mr-changes <number>}"
        case "$IID" in
            ''|*[!0-9]*) emit_error "PR number must be numeric: $IID"; exit 2 ;;
        esac
        body="$(gh_get_q "$API/pulls/$IID/files" --data-urlencode "per_page=100")" || exit $?
        printf '%s' "$body" | normalize_mr_changes
        ;;

    mr-commits)
        IID="${1:?Usage: github-api.sh mr-commits <number>}"
        case "$IID" in
            ''|*[!0-9]*) emit_error "PR number must be numeric: $IID"; exit 2 ;;
        esac
        body="$(gh_get_q "$API/pulls/$IID/commits" --data-urlencode "per_page=100")" || exit $?
        printf '%s' "$body" | normalize_mr_commits
        ;;

    mr-notes)
        # #1360: read the PR's discussion notes for the review-resolver in
        # code_writer (poll the durable review note instead of the ephemeral bus).
        # Ported from the code-review backend so the normalized shape is identical.
        NUM="${1:?Usage: github-api.sh mr-notes <number>}"
        case "$NUM" in
            ''|*[!0-9]*) emit_error "pr number must be numeric: $NUM"; exit 2 ;;
        esac
        # GitHub PR conversation comments live under the issues endpoint
        # (same number). Inline review comments at /pulls/{n}/comments are
        # a separate stream consumers don't currently ingest; adding them
        # later would be additive in this endpoint.
        body="$(gh_get_q "$API/issues/$NUM/comments" \
            --data-urlencode "per_page=100" \
            --data-urlencode "sort=created" \
            --data-urlencode "direction=desc")" || exit $?
        printf '%s' "$body" | normalize_notes
        ;;

    pr-checks)
        # #1332: CI verdict read for the bounded red-PR recovery loop (code_writer
        # re-drives its OWN red PRs). Prints exactly two space-separated tokens on
        # stdout: `STATE=<red|green|pending> REF=<head-branch>`. Same check-runs
        # verdict logic as the code-review colony's #1317 merge gate, but read-only
        # and reporting red/pending/green instead of a binary refuse — recovery
        # acts only on `red`, never `pending` (don't race CI). Pagination fail-safe:
        # if total_count exceeds the fetched page a red check could hide on a later
        # page, so report `pending` (never `green`).
        NUM="${1:?Usage: github-api.sh pr-checks <number>}"
        case "$NUM" in
            ''|*[!0-9]*) emit_error "pr number must be numeric: $NUM"; exit 2 ;;
        esac

        pull_json="$(gh_get "$API/pulls/$NUM")" || exit $?
        PR_META="$(printf '%s' "$pull_json" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
print("HEAD_SHA=" + str((d.get("head") or {}).get("sha") or ""))
print("HEAD_REF=" + str((d.get("head") or {}).get("ref") or ""))
')" || { emit_error "PR #$NUM: failed to parse pull metadata"; exit 4; }
        HEAD_SHA="$(printf '%s\n' "$PR_META" | sed -n 's/^HEAD_SHA=//p')"
        HEAD_REF="$(printf '%s\n' "$PR_META" | sed -n 's/^HEAD_REF=//p')"
        if [ -z "$HEAD_SHA" ]; then
            emit_error "PR #$NUM: missing head.sha; cannot read CI"
            exit 4
        fi

        checks_json="$(gh_get_q "$API/commits/$HEAD_SHA/check-runs" --data-urlencode "per_page=100")" || exit $?
        STATE="$(printf '%s' "$checks_json" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
runs = d.get("check_runs") or []
total = d.get("total_count")
if total is None:
    total = len(runs)
if not runs:
    print("pending")
    sys.exit(0)
if total > len(runs):
    print("pending")
    sys.exit(0)
ok_conclusions = {"success", "neutral", "skipped"}
state = "green"
for r in runs:
    if r.get("status") != "completed":
        print("pending")
        sys.exit(0)
    if r.get("conclusion") not in ok_conclusions:
        state = "red"
print(state)
')" || { emit_error "PR #$NUM: failed to parse check-runs"; exit 4; }
        printf 'STATE=%s REF=%s\n' "$STATE" "$HEAD_REF"
        ;;

    issue)
        IID="${1:?Usage: github-api.sh issue <number>}"
        case "$IID" in
            ''|*[!0-9]*) emit_error "issue number must be numeric: $IID"; exit 2 ;;
        esac
        body="$(gh_get "$API/issues/$IID")" || exit $?
        printf '%s' "$body" | normalize_issue
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
        # GitLab uses assignee_id=Any to match any assignee. GitHub's /issues
        # endpoint accepts assignee=* with the same "assigned to any user"
        # semantic. When GITHUB_ME is set, narrow to that operator so the
        # colony doesn't process work assigned to teammates.
        # #291: --include-unassigned drops the assignee filter so the label
        # alone is the trigger signal. Unblocks code_writer's action path on
        # repos where labeled issues are typically unassigned.
        ASSIGNEE="${GITHUB_ME:-*}"
        ARGS=(
            --data-urlencode "state=open"
            --data-urlencode "labels=${IMPLEMENTATION_TRIGGER_LABEL:-implementation}"
            --data-urlencode "per_page=20"
            --data-urlencode "sort=updated"
            --data-urlencode "direction=desc"
        )
        if [ "$INCLUDE_UNASSIGNED" = "0" ]; then
            ARGS+=(--data-urlencode "assignee=$ASSIGNEE")
        fi
        if [ -n "$SINCE" ]; then
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

    issue-label-events)
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

    assigned-issues-by-label-events)
        # Composite parity query: currently-assigned+labeled ∪ timeline-added-
        # in-window for the same assignee. Same structure as planning's
        # issues-by-label-events but with the assignee filter.
        # #291: --include-unassigned drops the assignee filter; label-event
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
        ASSIGNEE="${GITHUB_ME:-*}"
        BASE_ARGS=(
            --data-urlencode "state=open"
            --data-urlencode "per_page=20"
            --data-urlencode "sort=updated"
            --data-urlencode "direction=desc"
            --data-urlencode "since=$EV_SINCE"
        )
        if [ "$INCLUDE_UNASSIGNED" = "0" ]; then
            BASE_ARGS+=(--data-urlencode "assignee=$ASSIGNEE")
        fi
        recent_raw="$(gh_get_q "$API/issues" "${BASE_ARGS[@]}")" || exit $?
        recent="$(printf '%s' "$recent_raw" | normalize_issues)"
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

    create-branch)
        # GitLab has POST /repository/branches {branch, ref}. GitHub needs
        # two steps: resolve `ref` (branch name) to its head SHA, then
        # POST /git/refs {ref: "refs/heads/<name>", sha: <head_sha>}.
        NAME=""
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
        # Step 1: resolve ref to SHA. If REF looks like a bare SHA (40 hex
        # chars), skip the ref resolution entirely — GitHub also accepts a
        # tag or a full ref path but those aren't used by the .ag code today.
        case "$REF" in
            *[!0-9a-fA-F]*|"")
                ref_body="$(gh_get "$API/git/refs/heads/$REF")" || exit $?
                REF_SHA="$(REF_BODY="$ref_body" python3 -c 'import os,json;print((json.loads(os.environ["REF_BODY"]).get("object") or {}).get("sha") or "")')"
                if [ -z "$REF_SHA" ]; then
                    emit_error "could not resolve ref '$REF' to a commit SHA"
                    exit 1
                fi
                ;;
            *)
                # 40-hex sha — short-circuit.
                if [ "${#REF}" -eq 40 ]; then
                    REF_SHA="$REF"
                else
                    ref_body="$(gh_get "$API/git/refs/heads/$REF")" || exit $?
                    REF_SHA="$(REF_BODY="$ref_body" python3 -c 'import os,json;print((json.loads(os.environ["REF_BODY"]).get("object") or {}).get("sha") or "")')"
                fi
                ;;
        esac
        # Step 2: create the new ref.
        JSON_BODY=$(NAME="$NAME" SHA="$REF_SHA" python3 - <<'PY'
import os, json
print(json.dumps({"ref": "refs/heads/" + os.environ["NAME"], "sha": os.environ["SHA"]}))
PY
)
        # Idempotency (#1150): a retry after a prior failed commit finds the
        # branch already present, and GitHub answers the create POST with HTTP
        # 422 "Reference already exists". The branch being present is the
        # desired end state, so treat that one case as success: GET the existing
        # ref and emit it so callers receive a create-shaped payload, exit 0.
        # gh_post surfaces the 422 body snippet on stderr (gh_call's 4xx arm),
        # so we capture stderr to a temp file and only swallow the "already
        # exists" signature — any other failure re-surfaces its error and
        # propagates the original gh_post exit code.
        create_err_file="$(mktemp)"
        create_out=""
        create_rc=0
        create_out="$(gh_post "$API/git/refs" "$JSON_BODY" 2>"$create_err_file")" || create_rc=$?
        if [ "$create_rc" -eq 0 ]; then
            rm -f "$create_err_file"
            printf '%s' "$create_out"
        else
            create_err="$(cat "$create_err_file")"
            rm -f "$create_err_file"
            case "$create_err" in
                *"Reference already exists"*|*"already exists"*)
                    # Branch already present — desired end state reached.
                    existing_ref="$(gh_get "$API/git/refs/heads/$NAME")" || exit $?
                    printf '%s' "$existing_ref"
                    ;;
                *)
                    # Real failure: re-surface the captured error and propagate
                    # the original gh_post exit code.
                    printf '%s\n' "$create_err" >&2
                    exit "$create_rc"
                    ;;
            esac
        fi
        ;;

    commit-files)
        # GitLab ships a single POST /repository/commits with an actions
        # array. GitHub has no equivalent one-shot endpoint, so we drive
        # the Git Database API through 5 calls:
        #   1. GET /git/refs/heads/{branch}       -> head commit SHA
        #   2. GET /git/commits/{head_sha}        -> base tree SHA
        #   3. POST /git/trees {base_tree, tree}  -> new tree SHA
        #   4. POST /git/commits {message, tree, parents} -> new commit SHA
        #   5. PATCH /git/refs/heads/{branch} {sha} -> ref updated
        # Actions supported: create, update (both map to tree entry with
        # content), delete (tree entry with sha:null). move/chmod are not
        # emitted by any current .ag agent; we fail loud rather than silently
        # mishandle them.
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
        # Validate actions JSON up front so a malformed payload fails before
        # we spend an HTTP call. Rejects move/chmod loudly.
        ACTIONS="$ACTIONS" python3 - <<'PY' >/dev/null
import os, json, sys
try:
    # strict=False permits literal control chars (raw newlines, tabs) inside
    # JSON strings — LLM-generated file `content` routinely carries them (#1149).
    a = json.loads(os.environ["ACTIONS"], strict=False)
except Exception as e:
    print(json.dumps({"error": f"invalid --actions JSON: {e}"}), file=sys.stderr)
    sys.exit(1)
if not isinstance(a, list):
    print(json.dumps({"error": "--actions must be a JSON array"}), file=sys.stderr)
    sys.exit(1)
for entry in a:
    if not isinstance(entry, dict):
        print(json.dumps({"error": "each action must be a JSON object"}), file=sys.stderr)
        sys.exit(1)
    action = entry.get("action")
    if action not in ("create", "update", "delete"):
        print(json.dumps({"error": f"unsupported action '{action}' (supported on GitHub: create, update, delete)"}), file=sys.stderr)
        sys.exit(1)
    if not entry.get("file_path"):
        print(json.dumps({"error": "each action requires file_path"}), file=sys.stderr)
        sys.exit(1)
    if action in ("create", "update") and entry.get("content") is None:
        print(json.dumps({"error": f"action '{action}' requires content"}), file=sys.stderr)
        sys.exit(1)
PY
        # Step 1: branch head SHA.
        ref_body="$(gh_get "$API/git/refs/heads/$BRANCH")" || exit $?
        HEAD_SHA="$(REF_BODY="$ref_body" python3 -c 'import os,json;print((json.loads(os.environ["REF_BODY"]).get("object") or {}).get("sha") or "")')"
        if [ -z "$HEAD_SHA" ]; then
            emit_error "could not resolve head SHA for branch '$BRANCH'"
            exit 1
        fi
        # Step 2: base tree SHA.
        commit_body="$(gh_get "$API/git/commits/$HEAD_SHA")" || exit $?
        BASE_TREE_SHA="$(COMMIT_BODY="$commit_body" python3 -c 'import os,json;print((json.loads(os.environ["COMMIT_BODY"]).get("tree") or {}).get("sha") or "")')"
        if [ -z "$BASE_TREE_SHA" ]; then
            emit_error "could not resolve base tree SHA for commit $HEAD_SHA"
            exit 1
        fi
        # Step 3: build tree. For delete, tree entry carries sha:null so
        # GitHub removes the path. For create/update, carry content inline.
        TREE_BODY=$(ACTIONS="$ACTIONS" BASE_TREE="$BASE_TREE_SHA" python3 - <<'PY'
import os, json
# strict=False mirrors the up-front validation parse (#1149): file content
# may contain raw control chars that strict JSON would reject.
actions = json.loads(os.environ["ACTIONS"], strict=False)
tree = []
for a in actions:
    path = a["file_path"]
    if a["action"] == "delete":
        tree.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
    else:
        tree.append({"path": path, "mode": "100644", "type": "blob", "content": a["content"]})
print(json.dumps({"base_tree": os.environ["BASE_TREE"], "tree": tree}))
PY
)
        tree_resp="$(gh_post "$API/git/trees" "$TREE_BODY")" || exit $?
        NEW_TREE_SHA="$(TREE_RESP="$tree_resp" python3 -c 'import os,json;print(json.loads(os.environ["TREE_RESP"]).get("sha") or "")')"
        if [ -z "$NEW_TREE_SHA" ]; then
            emit_error "tree creation returned no sha"
            exit 1
        fi
        # Step 4: create commit on the new tree.
        COMMIT_POST_BODY=$(MESSAGE="$MESSAGE" TREE="$NEW_TREE_SHA" PARENT="$HEAD_SHA" python3 - <<'PY'
import os, json
print(json.dumps({
    "message": os.environ["MESSAGE"],
    "tree": os.environ["TREE"],
    "parents": [os.environ["PARENT"]],
}))
PY
)
        commit_resp="$(gh_post "$API/git/commits" "$COMMIT_POST_BODY")" || exit $?
        NEW_COMMIT_SHA="$(COMMIT_RESP="$commit_resp" python3 -c 'import os,json;print(json.loads(os.environ["COMMIT_RESP"]).get("sha") or "")')"
        if [ -z "$NEW_COMMIT_SHA" ]; then
            emit_error "commit creation returned no sha"
            exit 1
        fi
        # Step 5: fast-forward the branch ref. Final response echoes the ref
        # object — callers treat truthy output as success.
        REF_PATCH_BODY=$(SHA="$NEW_COMMIT_SHA" python3 - <<'PY'
import os, json
print(json.dumps({"sha": os.environ["SHA"]}))
PY
)
        gh_patch "$API/git/refs/heads/$BRANCH" "$REF_PATCH_BODY"
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
        JSON_BODY=$(SOURCE="$SOURCE" TITLE="$TITLE" DESC="$DESC" \
            DEFAULT_BRANCH="${GITLAB_DEFAULT_BRANCH:-main}" python3 - <<'PY'
import os, json
body = {
    "head": os.environ["SOURCE"],
    "base": os.environ["DEFAULT_BRANCH"],
    "title": os.environ["TITLE"],
}
if os.environ.get("DESC"):
    body["body"] = os.environ["DESC"]
print(json.dumps(body))
PY
)
        gh_post "$API/pulls" "$JSON_BODY"
        ;;

    add-note)
        IID="${1:?Usage: github-api.sh add-note <number> --body <text>}"
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
        case "$IID" in
            ''|*[!0-9]*) emit_error "issue number must be numeric: $IID"; exit 2 ;;
        esac
        JSON_BODY=$(printf '%s' "$BODY" | python3 -c 'import sys,json; print(json.dumps({"body": sys.stdin.read()}))')
        gh_post "$API/issues/$IID/comments" "$JSON_BODY"
        ;;

    get-file)
        # #1172: fetch the raw decoded content of a single file at --ref so
        # code_writer can EDIT an existing file instead of clobbering it with
        # a from-scratch rewrite. GET /repos/{o}/{r}/contents/{path}?ref={ref}
        # returns a JSON object with base64-encoded `.content`; we decode it to
        # stdout. A 404 (file does not exist on that ref) is NOT an error here:
        # the caller treats empty output as "new file", so we swallow the 404
        # and exit 0. Any other HTTP error propagates (gh_get's emit_error +
        # non-zero return).
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
        # gh_get emits a 404 client error on stderr and returns 4. Capture both
        # so we can distinguish the benign "file absent" 404 from a real error.
        gf_err_file="$(mktemp)"
        gf_out=""
        gf_rc=0
        gf_out="$(gh_get_q "$API/contents/$FILE_PATH" --data-urlencode "ref=$FILE_REF" 2>"$gf_err_file")" || gf_rc=$?
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
