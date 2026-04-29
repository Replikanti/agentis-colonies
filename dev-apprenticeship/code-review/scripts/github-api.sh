#!/bin/bash
# GitHub API wrapper for code-review colony agents (ADR-0002, #256 PR 5 of 7).
# Called by .ag agents via forge-api.sh dispatch when FORGE_TYPE=github.
#
# Required env vars (set by start-colony.sh from [forge.github] in colony.toml):
#   GITHUB_URL    - API base (default https://api.github.com; override for GHE)
#   GITHUB_TOKEN  - personal access token (classic or fine-grained)
#   GITHUB_OWNER  - repo owner (user or org)
#   GITHUB_REPO   - repo name
#
# Optional env vars:
#   GITHUB_ME             authenticated-user login (optional, for personal
#                         vs team tagging via style_reviewer etc.)
#   GITHUB_CURL_MAX_TIME  per-attempt --max-time seconds (default 90)
#   GITHUB_CURL_RETRIES   retry budget for 5xx/timeouts/429 (default 3)
#
# Usage (identical contract to gitlab-api.sh):
#   github-api.sh merge-requests [--state opened|merged|closed|all] [--since ISO8601]
#                                [--per-page N] [--view <name>]
#   github-api.sh mr-changes <number>
#   github-api.sh mr-notes <number>
#   github-api.sh post-note <number> --body <text>
#   github-api.sh approve <number>
#   github-api.sh get-issue <number>
#
# Views (opt-in projection; byte-identical to gitlab-api.sh):
#   merge-requests --view reviewer  [{iid, state, title, labels,
#                                     source_branch, target_branch, draft,
#                                     author:{username}}]
#   <cmd>          --view raw       explicit pass-through (same as no flag)
#   GITLAB_VIEW_MODE=raw            env-override that forces pass-through.
#
# Semantic collapses vs GitLab:
#   /pulls                   replaces /merge_requests; state merged -> closed +
#                            client-side merged_at!=null filter; no `since`
#                            query param, --since is client-side on updated_at.
#                            Carries `draft` natively — the only normalize_pulls
#                            addition vs the implementation colony's shape.
#   /pulls/{n}/files         replaces /merge_requests/{iid}/changes; per-file
#                            entries are wrapped into {"changes": [...]} for
#                            shape parity with the GitLab MR-changes response.
#   /issues/{n}/comments     replaces /merge_requests/{iid}/notes. Every GitHub
#                            PR is also an issue (same number), and PR
#                            conversation comments land in the issues-comments
#                            endpoint. System events (merged/labeled/...) live
#                            in /issues/{n}/timeline and are intentionally
#                            excluded from mr-notes (agents only read human
#                            discussion). The normalizer emits system: false
#                            on every row so downstream shape stays stable.
#   /pulls/{n}/reviews       replaces /merge_requests/{iid}/approve; POST with
#                            {"event": "APPROVE"} creates an approving review.
#                            Unlike GitLab, GitHub has no idempotent /approve
#                            endpoint — calling this twice creates two reviews
#                            (approval_decider guards on its own decide-once
#                            memo; double-approve is inert but visible).
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

# normalize_pulls
# Reads GitHub pulls-list JSON, writes GitLab-MR-shape JSON. Superset of the
# planning/implementation normalize_pulls: adds `draft` (needed by the
# reviewer view). Duplicated rather than sourced for script-independence per
# ADR-0002. State collapse: open -> opened; closed + merged_at -> merged;
# closed + no merged_at stays closed.
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
        # `draft` is native on GitHub PRs. The reviewer view passes this
        # through so style/logic/security/test reviewers can skip drafts.
        "draft": bool(x.get("draft")),
        "merged_at": x.get("merged_at"),
        "created_at": x.get("created_at"),
        "updated_at": x.get("updated_at"),
        # /pulls list endpoint omits changed_files; forward as null.
        "changes_count": x.get("changed_files"),
        "user_notes_count": x.get("comments", 0),
    })
print(json.dumps(out))
PY
}

# normalize_mr_changes
# Reads GitHub /pulls/{n}/files JSON, writes a GitLab-mr-changes-shape JSON
# object: {"changes": [{"old_path", "new_path", "diff", "new_file",
# "deleted_file", "renamed_file"}, ...]}. The reviewers feed `diff` (unified
# patch text) straight into prompt() so drift in this shape breaks all four
# finding streams silently.
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

# normalize_issue
# Single-issue variant. Reads GitHub /issues/{n} JSON, writes GitLab-issue-
# shape JSON: {iid, title, description, state, labels, assignees, author,
# created_at, updated_at, user_notes_count}. Lifted from triage/scripts/
# github-api.sh's normalize_issue (#317) so the reviewer-side resolver can
# consume the same shape across the two callers without depending on the
# triage colony being installed alongside.
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

# normalize_notes
# Reads GitHub /issues/{n}/comments JSON, writes GitLab /notes-shape:
# [{id, body, author:{username}, created_at, system}]. GitHub's issue-comments
# endpoint returns only human discussion — state-change / label / review
# system events live in /issues/{n}/timeline. We stamp system: false on every
# row so the GitLab-shape filter (`if not system`) that reviewers apply over
# mr-notes continues to work.
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

# project_json <view-name>
# Byte-identical to gitlab-api.sh project_json; test-gitlab-views.sh enforces
# parity. One view (reviewer) plus raw pass-through.
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
        reviewer)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
# #104 parity: keep author.username so style_reviewer tags personal vs team.
# #317: keep description so reviewers can scan it for cross-repo refs.
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
# Mirrors planning/triage/implementation gh_call: retry on 429/5xx/timeout,
# no-retry on 401/403 non-rate-limit, 403-secondary-rate detection via body
# snippet, bounded curl --max-time. Exit codes 0/2/3/4/5 match gl_call.
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
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
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
            401)
                snippet="$(head -c 200 "$body_file")"
                emit_error "auth failure (HTTP 401) on $method $url: $snippet — check PAT scope/expiry"
                return 2
                ;;
            403)
                # GitHub overloads 403: could be missing scope (permanent) or
                # secondary rate-limit / abuse-detection (transient). Heuristic
                # on the error body — matches the triage/planning/impl wrappers.
                snippet="$(head -c 400 "$body_file")"
                if printf '%s' "$snippet" | grep -qiE 'rate limit|abuse|secondary rate'; then
                    if [ "$attempt" -le "$max_retries" ]; then
                        sleep "$delay"
                        delay=$((delay * 2))
                        continue
                    fi
                    emit_error "secondary rate limit (HTTP 403) after $attempt attempts: $snippet"
                    return 3
                fi
                emit_error "auth/permission failure (HTTP 403) on $method $url: $snippet — check PAT scope"
                return 2
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
        # GitLab state semantics -> GitHub /pulls state:
        #   opened -> open, closed -> closed, all -> all,
        #   merged -> closed + client-side merged_at!=null filter.
        case "$STATE" in
            opened) GH_STATE="open" ;;
            closed) GH_STATE="closed" ;;
            all)    GH_STATE="all" ;;
            merged) GH_STATE="closed" ;;
            *) emit_error "invalid --state: $STATE (expected opened|closed|merged|all)"; exit 2 ;;
        esac
        ARGS=(
            --data-urlencode "state=$GH_STATE"
            --data-urlencode "per_page=$PER_PAGE"
            --data-urlencode "sort=updated"
            --data-urlencode "direction=desc"
        )
        body="$(gh_get_q "$API/pulls" "${ARGS[@]}")" || exit $?
        # Normalize first, then apply client-side filters (--state merged /
        # --since), then optionally project.
        normalized="$(printf '%s' "$body" | normalize_pulls)"
        filtered="$(STATE="$STATE" SINCE="$SINCE" DATA="$normalized" python3 <<'PY'
import os, json
items = json.loads(os.environ["DATA"])
state = os.environ.get("STATE", "")
since = os.environ.get("SINCE", "")
out = []
for x in items:
    if state == "merged" and x.get("state") != "merged":
        continue
    if since and (x.get("updated_at") or "") < since:
        continue
    out.append(x)
print(json.dumps(out))
PY
)" || exit $?
        if [ -n "$VIEW" ]; then
            printf '%s' "$filtered" | project_json "$VIEW"
        else
            printf '%s' "$filtered"
        fi
        ;;

    mr-changes)
        NUM="${1:?Usage: github-api.sh mr-changes <number>}"
        case "$NUM" in
            ''|*[!0-9]*) emit_error "pr number must be numeric: $NUM"; exit 2 ;;
        esac
        body="$(gh_get_q "$API/pulls/$NUM/files" --data-urlencode "per_page=100")" || exit $?
        printf '%s' "$body" | normalize_mr_changes
        ;;

    mr-notes)
        NUM="${1:?Usage: github-api.sh mr-notes <number>}"
        case "$NUM" in
            ''|*[!0-9]*) emit_error "pr number must be numeric: $NUM"; exit 2 ;;
        esac
        # GitHub PR conversation comments live under the issues endpoint
        # (same number). Inline review comments at /pulls/{n}/comments are
        # a separate stream reviewers don't currently ingest; adding them
        # later would be additive in this endpoint.
        body="$(gh_get_q "$API/issues/$NUM/comments" \
            --data-urlencode "per_page=100" \
            --data-urlencode "sort=created" \
            --data-urlencode "direction=desc")" || exit $?
        printf '%s' "$body" | normalize_notes
        ;;

    post-note)
        NUM="${1:?Usage: github-api.sh post-note <number> --body <text>}"
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
        case "$NUM" in
            ''|*[!0-9]*) emit_error "pr number must be numeric: $NUM"; exit 2 ;;
        esac
        # Same /issues/{n}/comments endpoint as implementation's add-note —
        # GitHub doesn't split issue-notes from MR-notes the way GitLab does.
        JSON_BODY=$(printf '%s' "$BODY" | python3 -c 'import sys,json; print(json.dumps({"body": sys.stdin.read()}))')
        gh_post "$API/issues/$NUM/comments" "$JSON_BODY"
        ;;

    approve)
        NUM="${1:?Usage: github-api.sh approve <number>}"
        case "$NUM" in
            ''|*[!0-9]*) emit_error "pr number must be numeric: $NUM"; exit 2 ;;
        esac
        # POST /pulls/{n}/reviews with event=APPROVE. Unlike GitLab's
        # idempotent /approve, GitHub creates a new review object every call;
        # approval_decider already guards via its decide-once memo so double
        # invocations here would only waste a round-trip and a review row.
        gh_post "$API/pulls/$NUM/reviews" '{"event":"APPROVE"}'
        ;;

    get-issue)
        # #317: single-issue fetch for the cross-repo reference resolver.
        # Argv parity with triage/scripts/github-api.sh's get-issue (lifted
        # there for the planning/triage feedback matcher); the resolver in
        # tools/resolve-cross-repo-ref.sh consumes the normalized GitLab-
        # shape JSON for cache record reshaping.
        if [ $# -lt 1 ]; then
            emit_error "Usage: github-api.sh get-issue <number>"
            exit 2
        fi
        NUM="$1"
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        case "$NUM" in
            ''|*[!0-9]*) emit_error "issue number must be numeric: $NUM"; exit 2 ;;
        esac
        body="$(gh_get "$API/issues/$NUM")" || exit $?
        printf '%s' "$body" | normalize_issue
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
