#!/bin/bash
# GitHub API wrapper for release colony agents (ADR-0002, #256 PR 6 of 7).
# Called by .ag agents via forge-api.sh dispatch when FORGE_TYPE=github.
#
# Required env vars (set by start-colony.sh from [forge.github] in colony.toml):
#   GITHUB_URL    - API base (default https://api.github.com; override for GHE)
#   GITHUB_TOKEN  - personal access token (classic or fine-grained)
#   GITHUB_OWNER  - repo owner (user or org)
#   GITHUB_REPO   - repo name
#
# Optional env vars:
#   GITLAB_DEFAULT_BRANCH base/target branch for create-tag (default "main").
#                         The env-var name is a GitLab holdover kept for
#                         backend-agnostic dispatch (ADR-0002); renaming was
#                         deferred past #256 to avoid cross-colony churn —
#                         operators still set the value via
#                         [forge.<backend>] default_branch.
#   GITHUB_ME             authenticated-user login (optional; used as the
#                         `tagger.name` fallback when creating annotated tags)
#   GITHUB_CURL_MAX_TIME  per-attempt --max-time seconds (default 90)
#   GITHUB_CURL_RETRIES   retry budget for 5xx/timeouts/429 (default 3)
#
# Usage (identical contract to gitlab-api.sh):
#   github-api.sh releases [--per-page N] [--view <name>]
#   github-api.sh tags [--per-page N] [--view <name>]
#   github-api.sh pipelines --ref <branch> [--per-page N] [--view <name>]
#   github-api.sh merge-requests [--state opened|merged|closed|all]
#                                [--since ISO8601] [--per-page N] [--view <name>]
#   github-api.sh create-tag --name <name> [--ref <ref>] [--message <m>]
#   github-api.sh create-release --tag <tag> --name <name> --description <d>
#   github-api.sh post-note <number> --body <text>
#
# Views (opt-in projection; byte-identical to gitlab-api.sh):
#   releases       --view release-summary  [{tag_name, name, released_at, description}]
#   tags           --view tag-summary      [{name, message, commit:{short_id, created_at}}]
#   pipelines      --view pipeline-summary [{id, status, ref, sha, created_at, web_url}]
#   merge-requests --view release-mr       [{iid, title, description, merged_at, labels, target_branch}]
#   <cmd>          --view raw              explicit pass-through (same as no flag)
#   GITLAB_VIEW_MODE=raw                   env-override that forces pass-through globally.
#
# Semantic collapses vs GitLab:
#   /releases                replaces /releases; description <- body,
#                            released_at <- published_at. `commit` is not
#                            returned by GitHub in the list response — forward
#                            as null (version_bumper/changelog_writer tolerate).
#   /tags                    replaces /repository/tags. GitHub's /tags omits
#                            tag-object message and commit.created_at; the
#                            normalizer forwards both as null (would require
#                            N+1 per-tag calls to /git/tags and /git/commits
#                            to recover them). tag-summary consumers use this
#                            for prompt context only — not branching signal.
#   /actions/runs            replaces /pipelines. Wrapped response `{workflow_runs:
#                            [...]}` is unpacked; status/conclusion collapse:
#                            completed+success -> "success"; completed+failure/
#                            cancelled/timed_out -> "failed"; in_progress ->
#                            "running"; queued/requested/waiting/pending ->
#                            "pending". GitLab's "skipped" is mapped similarly
#                            (conclusion=skipped -> "success", since a skipped
#                            job is not a failure signal).
#   /pulls                   replaces /merge_requests; state merged -> closed +
#                            client-side merged_at!=null filter; no `since`
#                            query param, --since is client-side on updated_at.
#   /issues/{n}/comments     replaces /merge_requests/{iid}/notes for post-note
#                            (GitHub unifies PR conversation with issue
#                            comments; same endpoint used by code-review's
#                            post-note and triage/planning/impl's add-note).
#   /git/refs + /git/tags    replaces POST /repository/tags. Annotated tags
#                            (non-empty --message) need the 3-step dance:
#                            resolve ref -> POST /git/tags -> POST /git/refs.
#                            Lightweight tags (empty --message) short-circuit
#                            to a single POST /git/refs after ref resolution.
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

# normalize_releases
# Reads GitHub /releases JSON, writes GitLab-releases-shape JSON. Shape is a
# superset of what the release-summary view consumes (tag_name, name,
# released_at, description) plus the fields changelog_writer reads from the
# raw output (author, created_at) when prompted for release-note context.
normalize_releases() {
    python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = [{
    "tag_name": x.get("tag_name"),
    "name": x.get("name"),
    "description": x.get("body"),
    "created_at": x.get("created_at"),
    "released_at": x.get("published_at"),
    "author": {"username": (x.get("author") or {}).get("login")} if x.get("author") else None,
    # /releases list response doesn't embed the underlying commit; forward as
    # null so downstream consumers don't trip on a missing key.
    "commit": None,
} for x in data]
print(json.dumps(out))
PY
}

# normalize_tags
# Reads GitHub /tags JSON, writes GitLab-tags-shape JSON. GitHub's /tags
# payload is much thinner: no tag-object `message`, no commit `created_at`.
# Both are forwarded as null. tag-summary consumers (version_bumper, ship_decider,
# changelog_writer) use these fields for prompt context only — missing values
# degrade prompt quality but do not break branching.
normalize_tags() {
    python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = []
for x in data:
    commit = x.get("commit") or {}
    sha = commit.get("sha")
    out.append({
        "name": x.get("name"),
        # Tag-object message lives behind a separate GET /git/tags/{sha} call
        # for annotated tags; lightweight tags have none. Null is correct for
        # both cases without N+1 calls.
        "message": None,
        "target": sha,
        "commit": {
            "id": sha,
            # GitLab emits 8-char short_id; match that so tag-summary renders
            # identically across backends.
            "short_id": sha[:8] if sha else None,
            # commit.created_at requires a second GET /git/commits/{sha};
            # forward null to keep this a single round-trip.
            "created_at": None,
        },
    })
print(json.dumps(out))
PY
}

# normalize_pipelines
# Reads GitHub /actions/runs JSON (envelope with workflow_runs[]), writes
# GitLab-pipelines-shape JSON. Status collapse mirrors the agentis-colonies
# shape contract in ADR-0002 §"Semantic collapses".
normalize_pipelines() {
    python3 /dev/fd/3 3<<'PY'
import sys, json
envelope = json.loads(sys.stdin.read())
# GitHub wraps the list in {total_count, workflow_runs: [...]}; other endpoints
# return a bare array. Accept both so ad-hoc callers piping raw responses work.
if isinstance(envelope, dict):
    runs = envelope.get("workflow_runs") or []
else:
    runs = envelope
out = []
for r in runs:
    status = r.get("status") or ""
    conclusion = r.get("conclusion") or ""
    if status == "completed":
        if conclusion in ("success", "skipped", "neutral"):
            gl_status = "success"
        elif conclusion in ("failure", "cancelled", "timed_out", "action_required", "stale"):
            gl_status = "failed"
        else:
            # unknown conclusion on completed — treat as failed to avoid
            # falsely reporting success; ship_decider branches on "success".
            gl_status = "failed"
    elif status == "in_progress":
        gl_status = "running"
    elif status in ("queued", "requested", "waiting", "pending"):
        gl_status = "pending"
    else:
        # unknown status — leave as-is so it's visible rather than masked.
        gl_status = status
    out.append({
        "id": r.get("id"),
        "status": gl_status,
        "ref": r.get("head_branch"),
        "sha": r.get("head_sha"),
        "created_at": r.get("created_at"),
        "updated_at": r.get("updated_at"),
        "web_url": r.get("html_url"),
    })
print(json.dumps(out))
PY
}

# normalize_pulls
# Same shape as planning/implementation normalize_pulls — no `draft` field
# (release's release-mr view doesn't expose it; code-review's reviewer view
# does). State collapse: open -> opened; closed + merged_at -> merged;
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
        "merged_at": x.get("merged_at"),
        "created_at": x.get("created_at"),
        "updated_at": x.get("updated_at"),
        "changes_count": x.get("changed_files"),
        "user_notes_count": x.get("comments", 0),
    })
print(json.dumps(out))
PY
}

# project_json <view-name>
# Byte-identical to gitlab-api.sh project_json; test-gitlab-views.sh enforces
# parity for all four release views.
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
        release-summary)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = [{"tag_name": x.get("tag_name"), "name": x.get("name"),
        "released_at": x.get("released_at"), "description": x.get("description")} for x in data]
print(json.dumps(out))
PY
            ;;
        tag-summary)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = [{"name": x.get("name"), "message": x.get("message"),
        "commit": {"short_id": (x.get("commit") or {}).get("short_id"),
                   "created_at": (x.get("commit") or {}).get("created_at")}} for x in data]
print(json.dumps(out))
PY
            ;;
        pipeline-summary)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = [{"id": x.get("id"), "status": x.get("status"), "ref": x.get("ref"),
        "sha": x.get("sha"), "created_at": x.get("created_at"),
        "web_url": x.get("web_url")} for x in data]
print(json.dumps(out))
PY
            ;;
        release-mr)
            printf '%s' "$DATA" | python3 /dev/fd/3 3<<'PY'
import sys, json
data = json.loads(sys.stdin.read())
out = [{"iid": x.get("iid"), "title": x.get("title"), "description": x.get("description"),
        "merged_at": x.get("merged_at"),
        "labels": x.get("labels", []), "target_branch": x.get("target_branch")} for x in data]
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
# Mirrors every other github-api.sh gh_call: retry on 429/5xx/timeout, no-retry
# on 401/403 non-rate-limit, 403-secondary-rate detection via body snippet,
# bounded curl --max-time. Exit codes 0/2/3/4/5 match gl_call.
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
    releases)
        PER_PAGE="20"
        VIEW=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --per-page) PER_PAGE="$2"; shift 2 ;;
                --view) VIEW="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        case "$PER_PAGE" in
            ''|*[!0-9]*) emit_error "invalid --per-page: $PER_PAGE (integer required)"; exit 2 ;;
        esac
        # GitHub's /releases list is sorted by created_at desc by default —
        # matches GitLab's order_by=released_at sort=desc for the common case.
        body="$(gh_get_q "$API/releases" --data-urlencode "per_page=$PER_PAGE")" || exit $?
        normalized="$(printf '%s' "$body" | normalize_releases)"
        if [ -n "$VIEW" ]; then
            printf '%s' "$normalized" | project_json "$VIEW"
        else
            printf '%s' "$normalized"
        fi
        ;;

    tags)
        PER_PAGE="20"
        VIEW=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --per-page) PER_PAGE="$2"; shift 2 ;;
                --view) VIEW="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        case "$PER_PAGE" in
            ''|*[!0-9]*) emit_error "invalid --per-page: $PER_PAGE (integer required)"; exit 2 ;;
        esac
        body="$(gh_get_q "$API/tags" --data-urlencode "per_page=$PER_PAGE")" || exit $?
        normalized="$(printf '%s' "$body" | normalize_tags)"
        if [ -n "$VIEW" ]; then
            printf '%s' "$normalized" | project_json "$VIEW"
        else
            printf '%s' "$normalized"
        fi
        ;;

    pipelines)
        REF=""
        PER_PAGE="5"
        VIEW=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --ref) REF="$2"; shift 2 ;;
                --per-page) PER_PAGE="$2"; shift 2 ;;
                --view) VIEW="$2"; shift 2 ;;
                *) emit_error "unknown flag: $1"; exit 2 ;;
            esac
        done
        if [ -z "$REF" ]; then
            emit_error "--ref is required"
            exit 1
        fi
        case "$PER_PAGE" in
            ''|*[!0-9]*) emit_error "invalid --per-page: $PER_PAGE (integer required)"; exit 2 ;;
        esac
        # GitHub's /actions/runs uses `branch` (not `ref`) for branch-scoped
        # filtering. Translate the arg name at the boundary to keep the
        # .ag-layer contract identical.
        body="$(gh_get_q "$API/actions/runs" \
            --data-urlencode "branch=$REF" \
            --data-urlencode "per_page=$PER_PAGE")" || exit $?
        normalized="$(printf '%s' "$body" | normalize_pipelines)"
        if [ -n "$VIEW" ]; then
            printf '%s' "$normalized" | project_json "$VIEW"
        else
            printf '%s' "$normalized"
        fi
        ;;

    merge-requests)
        STATE="opened"
        SINCE=""
        VIEW=""
        PER_PAGE=100
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
        normalized="$(printf '%s' "$body" | normalize_pulls)"
        # Client-side --state merged and --since filters (GitHub's /pulls has
        # no `since` query param and no distinct "merged" state; see ADR-0002
        # §"PR 3 additions" and §"PR 4 additions").
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

    create-tag)
        NAME=""
        # Honour operator-configured default branch (#224); fall back to
        # "main" when unset.
        REF="${GITLAB_DEFAULT_BRANCH:-main}"
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
        # Step 1: resolve ref to a commit SHA. Short-circuit on 40-hex.
        if [ "${#REF}" -eq 40 ] && printf '%s' "$REF" | grep -qE '^[0-9a-fA-F]{40}$'; then
            REF_SHA="$REF"
        else
            ref_body="$(gh_get "$API/git/refs/heads/$REF")" || exit $?
            REF_SHA="$(REF_BODY="$ref_body" python3 -c 'import os,json;print((json.loads(os.environ["REF_BODY"]).get("object") or {}).get("sha") or "")')"
            if [ -z "$REF_SHA" ]; then
                emit_error "could not resolve ref '$REF' to a commit SHA"
                exit 1
            fi
        fi

        if [ -n "$MESSAGE" ]; then
            # Annotated tag: 3-step dance (resolve above + create tag obj +
            # create ref). Tagger identity prefers GITHUB_ME; falls back to a
            # bot label so repos without a configured `me` still succeed.
            TAGGER_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            TAG_JSON=$(NAME="$NAME" MESSAGE="$MESSAGE" SHA="$REF_SHA" \
                       ME="${GITHUB_ME:-}" DATE="$TAGGER_DATE" python3 - <<'PY'
import os, json
me = os.environ.get("ME") or "agentis-bot"
# noreply email keeps GitHub happy without exposing a real address; the
# domain is the standard GitHub noreply host.
email = me + "@users.noreply.github.com" if me != "agentis-bot" else "agentis-bot@users.noreply.github.com"
print(json.dumps({
    "tag": os.environ["NAME"],
    "message": os.environ["MESSAGE"],
    "object": os.environ["SHA"],
    "type": "commit",
    "tagger": {"name": me, "email": email, "date": os.environ["DATE"]},
}))
PY
)
            tag_resp="$(gh_post "$API/git/tags" "$TAG_JSON")" || exit $?
            TAG_SHA="$(TAG_RESP="$tag_resp" python3 -c 'import os,json;print(json.loads(os.environ["TAG_RESP"]).get("sha") or "")')"
            if [ -z "$TAG_SHA" ]; then
                emit_error "tag-object creation returned no sha; cannot create ref"
                exit 1
            fi
            REF_TARGET_SHA="$TAG_SHA"
        else
            # Lightweight tag: skip /git/tags, point the ref straight at the
            # commit SHA. Matches GitLab create-tag without --message.
            REF_TARGET_SHA="$REF_SHA"
        fi

        REF_JSON=$(NAME="$NAME" SHA="$REF_TARGET_SHA" python3 - <<'PY'
import os, json
print(json.dumps({"ref": "refs/tags/" + os.environ["NAME"], "sha": os.environ["SHA"]}))
PY
)
        # Create the ref; we don't use the response body — we synthesize the
        # GitLab-shape reply below from the inputs we already have. shellcheck
        # SC2034 disable needed because the capture is only for exit-code
        # forwarding via `|| exit $?`.
        # shellcheck disable=SC2034
        ref_resp="$(gh_post "$API/git/refs" "$REF_JSON")" || exit $?

        # Emit a GitLab-tag-shape response so version_bumper's `len > 0`
        # truthy check stays happy and downstream normalize_tags-style
        # consumers don't choke on an unfamiliar envelope.
        NAME="$NAME" MESSAGE="$MESSAGE" COMMIT_SHA="$REF_SHA" REF_TARGET="$REF_TARGET_SHA" python3 <<'PY'
import os, json
sha = os.environ["COMMIT_SHA"]
print(json.dumps({
    "name": os.environ["NAME"],
    "message": os.environ.get("MESSAGE") or None,
    "target": os.environ["REF_TARGET"],
    "commit": {
        "id": sha,
        "short_id": sha[:8] if sha else None,
        "created_at": None,
    },
    "release": None,
}))
PY
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
    body["body"] = os.environ["DESC"]
print(json.dumps(body))
PY
)
        resp="$(gh_post "$API/releases" "$JSON_BODY")" || exit $?
        # Normalize single-item response to GitLab-release shape so the
        # downstream .ag `len > 0` check works identically and any future
        # JSON-field reader gets the expected keys.
        printf '%s' "[$resp]" | normalize_releases | python3 -c 'import sys,json; items=json.load(sys.stdin); print(json.dumps(items[0] if items else {}))'
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
            ''|*[!0-9]*) emit_error "pr/issue number must be numeric: $NUM"; exit 2 ;;
        esac
        # Same /issues/{n}/comments endpoint as code-review's post-note and
        # triage/planning/impl's add-note — GitHub unifies issue and PR
        # conversation comments.
        JSON_BODY=$(printf '%s' "$BODY" | python3 -c 'import sys,json; print(json.dumps({"body": sys.stdin.read()}))')
        gh_post "$API/issues/$NUM/comments" "$JSON_BODY"
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
