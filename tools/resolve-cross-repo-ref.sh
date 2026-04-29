#!/bin/bash
# tools/resolve-cross-repo-ref.sh: glue script that resolves a stream of
# `<owner>/<repo>#<N>` cross-repo refs into a markdown context block (#317).
#
# Reads the ref list on stdin (one per line, as emitted by
# scan-cross-repo-refs.sh), and for each ref:
#   1. Tries cross-repo-cache.sh get; on hit, uses the cached record.
#   2. On cache miss/expired, invokes
#      `<colony-dir>/scripts/forge-api.sh get-issue <number> --repo <owner>/<repo>`
#      and reshapes the result into the cache schema, writes via
#      cross-repo-cache.sh put.
#   3. Records the (src=this-PR-context, tgt=the-ref) pair in the
#      federation-shared closed-by-index for the bidirectional surface.
#
# `--max <N>` caps the number of refs resolved per invocation (default
# 5). Excess refs are silently dropped after N — the cap exists to bound
# the prompt-context size and forge call budget, not to surface a
# structured "more refs elided" hint.
#
# `--src-owner <o> --src-repo <r> --src-iid <N>` (optional): when all
# three are supplied, each successful resolve also records a closed-by
# entry pairing this source with the resolved target. Skipped when
# missing — the cross-repo *resolver* (read-side) is independent of the
# closed-by *recorder* (write-side); both can be invoked in isolation.
#
# Out-of-config repo handling: forge-api.sh exits non-zero when --repo
# isn't in GITHUB_REPOS_JSON. Resolver writes a tombstone record to
# cache (so we don't re-attempt the API for an entire TTL window) and
# silently skips the ref in the markdown output. Tombstones carry
# `state == "unresolvable"`.
#
# Stdout: leading `\n\n## Cross-repo references mentioned in this PR\n`
# followed by one bullet per resolved ref. Empty stdout when no refs
# resolved (caller can concat unconditionally — it's empty-string-safe).
#
# Bash 3.2 portable. No heredocs (CLAUDE.md). All JSON shape work is
# delegated to python3 -c one-liners via env-var payloads — same
# pattern as the .ag agents' repo_field() helper. Tokens NEVER appear
# in cache records or stdout (test 6 enforces).
#
# Exit codes:
#   0  ok (markdown on stdout, possibly empty)
#   2  usage error / malformed args

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

COLONY_DIR=""
MAX_REFS=5
SRC_OWNER=""
SRC_REPO=""
SRC_IID=""

while [ $# -gt 0 ]; do
    case "$1" in
        --colony-dir)
            COLONY_DIR="${2:-}"
            shift 2
            ;;
        --max)
            MAX_REFS="${2:-5}"
            shift 2
            ;;
        --src-owner)
            SRC_OWNER="${2:-}"
            shift 2
            ;;
        --src-repo)
            SRC_REPO="${2:-}"
            shift 2
            ;;
        --src-iid)
            SRC_IID="${2:-}"
            shift 2
            ;;
        *)
            echo "resolve-cross-repo-ref: unknown flag: $1" >&2
            exit 2
            ;;
    esac
done

if [ -z "$COLONY_DIR" ]; then
    echo "resolve-cross-repo-ref: --colony-dir is required" >&2
    exit 2
fi

case "$MAX_REFS" in
    ''|*[!0-9]*)
        echo "resolve-cross-repo-ref: --max must be numeric (got '$MAX_REFS')" >&2
        exit 2
        ;;
esac

FORGE_API="$COLONY_DIR/scripts/forge-api.sh"
CACHE="$SCRIPT_DIR/cross-repo-cache.sh"
CLOSED_BY="$SCRIPT_DIR/closed-by-index.sh"

for tool in "$CACHE" "$CLOSED_BY"; do
    if [ ! -x "$tool" ]; then
        echo "resolve-cross-repo-ref: helper missing or not executable: $tool" >&2
        exit 2
    fi
done

# Read all refs upfront into a temp file so the per-ref subprocesses
# don't inherit and consume our stdin.
REFS_FILE="$(mktemp)"
trap 'rm -f "$REFS_FILE"' EXIT
cat >"$REFS_FILE"

# Reshape the raw forge-api get-issue JSON into the cache schema. Caps:
# title 200 chars, labels max 10 entries x 32 chars each. Tokens NEVER
# appear in the input (the github-api.sh /issues endpoint shape carries
# only public fields), but we explicitly project a known set of keys —
# defence in depth.
RESHAPE_PY='import os, json, datetime
raw = os.environ.get("RAW","")
owner = os.environ.get("OWNER","")
repo = os.environ.get("REPO","")
number = os.environ.get("NUMBER","")
try:
    src = json.loads(raw) if raw else {}
except Exception:
    src = {}
title = str(src.get("title") or "")
if len(title) > 200:
    title = title[:200]
state = str(src.get("state") or "")
labels = src.get("labels") or []
out_labels = []
for lab in labels[:10]:
    if isinstance(lab, dict):
        lab = lab.get("name") or ""
    s = str(lab)[:32]
    if s:
        out_labels.append(s)
fetched = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
try:
    num_int = int(number)
except Exception:
    num_int = 0
print(json.dumps({
    "owner": owner,
    "repo": repo,
    "number": num_int,
    "title": title,
    "state": state,
    "labels": out_labels,
    "fetched_at": fetched,
}))
'

# Tombstone written when a ref resolves to a repo not in GITHUB_REPOS_JSON
# (or when the API call otherwise fails). state == "unresolvable" is the
# magic marker the resolver later filters out of rendered output.
TOMBSTONE_PY='import os, json, datetime
owner = os.environ.get("OWNER","")
repo = os.environ.get("REPO","")
number = os.environ.get("NUMBER","")
try:
    num_int = int(number)
except Exception:
    num_int = 0
print(json.dumps({
    "owner": owner,
    "repo": repo,
    "number": num_int,
    "title": "",
    "state": "unresolvable",
    "labels": [],
    "fetched_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
}))
'

# Extract just the `state` field of a cache record.
STATE_PY='import sys, json
try:
    rec = json.loads(sys.stdin.read())
except Exception:
    rec = {}
print(rec.get("state",""))
'

# Render one markdown bullet line for a resolved record.
# shellcheck disable=SC2016
RENDER_PY='import sys, json, os
try:
    rec = json.loads(sys.stdin.read())
except Exception:
    rec = {}
owner = sys.argv[1] if len(sys.argv) > 1 else rec.get("owner","")
repo = sys.argv[2] if len(sys.argv) > 2 else rec.get("repo","")
num = sys.argv[3] if len(sys.argv) > 3 else str(rec.get("number",""))
title = rec.get("title","")
state = rec.get("state","")
labels = rec.get("labels") or []
labels_str = ", ".join(labels) if labels else ""
parts = ["- `%s/%s#%s`" % (owner, repo, num)]
if state:
    parts.append("(%s)" % state)
if title:
    parts.append("- " + title)
if labels_str:
    parts.append("[" + labels_str + "]")
print(" ".join(parts))
'

# Walk the ref file. Bash 3.2 doesn't have mapfile; while-read is portable.
RESOLVED_COUNT=0
RESOLVED_BODY=""

while IFS= read -r REF; do
    [ -z "$REF" ] && continue
    if [ "$RESOLVED_COUNT" -ge "$MAX_REFS" ]; then
        break
    fi

    # Parse `<owner>/<repo>#<N>` via parameter expansion (no =~ on bash 3.2).
    SLASH="${REF%%/*}"
    REST="${REF#*/}"
    REPO_PART="${REST%%#*}"
    NUM="${REST##*#}"

    if [ -z "$SLASH" ] || [ -z "$REPO_PART" ] || [ -z "$NUM" ] || [ "$REPO_PART" = "$REST" ]; then
        continue
    fi
    case "$NUM" in
        ''|*[!0-9]*) continue ;;
    esac

    OWNER="$SLASH"
    REPO="$REPO_PART"

    # 1. Cache get.
    HIT=""
    if HIT="$("$CACHE" get --colony-dir "$COLONY_DIR" "$OWNER" "$REPO" "$NUM" 2>/dev/null)"; then
        :
    else
        HIT=""
    fi

    if [ -z "$HIT" ]; then
        # 2. Cache miss/expired -> forge-api get-issue. The dispatcher
        # exits non-zero when --repo isn't in GITHUB_REPOS_JSON; treat
        # any non-zero from forge-api as out-of-config and tombstone.
        RAW=""
        FORGE_RC=0
        RAW="$("$FORGE_API" get-issue "$NUM" --repo "$OWNER/$REPO" 2>/dev/null)" || FORGE_RC=$?
        if [ "$FORGE_RC" -ne 0 ] || [ -z "$RAW" ]; then
            OWNER="$OWNER" REPO="$REPO" NUMBER="$NUM" python3 -c "$TOMBSTONE_PY" \
                | "$CACHE" put --colony-dir "$COLONY_DIR" "$OWNER" "$REPO" "$NUM" >/dev/null 2>&1 || true
            continue
        fi
        RECORD="$(OWNER="$OWNER" REPO="$REPO" NUMBER="$NUM" RAW="$RAW" python3 -c "$RESHAPE_PY" 2>/dev/null || true)"
        if [ -z "$RECORD" ]; then
            OWNER="$OWNER" REPO="$REPO" NUMBER="$NUM" python3 -c "$TOMBSTONE_PY" \
                | "$CACHE" put --colony-dir "$COLONY_DIR" "$OWNER" "$REPO" "$NUM" >/dev/null 2>&1 || true
            continue
        fi
        printf '%s' "$RECORD" | "$CACHE" put --colony-dir "$COLONY_DIR" "$OWNER" "$REPO" "$NUM" >/dev/null 2>&1 || true
        HIT="$RECORD"
    fi

    # Skip tombstones from rendered output.
    STATE_FIELD="$(printf '%s' "$HIT" | python3 -c "$STATE_PY" 2>/dev/null || true)"
    if [ "$STATE_FIELD" = "unresolvable" ]; then
        continue
    fi

    # 3. closed-by index recording (optional — only when src-* triplet is set).
    if [ -n "$SRC_OWNER" ] && [ -n "$SRC_REPO" ] && [ -n "$SRC_IID" ]; then
        "$CLOSED_BY" record \
            --colony-dir "$COLONY_DIR" \
            --src-owner "$SRC_OWNER" \
            --src-repo "$SRC_REPO" \
            --src-iid "$SRC_IID" \
            --tgt-owner "$OWNER" \
            --tgt-repo "$REPO" \
            --tgt-iid "$NUM" >/dev/null 2>&1 || true
    fi

    # 4. Render bullet line.
    BULLET="$(printf '%s' "$HIT" | python3 -c "$RENDER_PY" "$OWNER" "$REPO" "$NUM" 2>/dev/null || true)"
    if [ -n "$BULLET" ]; then
        if [ -z "$RESOLVED_BODY" ]; then
            RESOLVED_BODY="$BULLET"
        else
            RESOLVED_BODY="$RESOLVED_BODY
$BULLET"
        fi
        RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
    fi
done <"$REFS_FILE"

if [ "$RESOLVED_COUNT" -gt 0 ]; then
    printf '\n\n## Cross-repo references mentioned in this PR\n%s\n' "$RESOLVED_BODY"
fi

exit 0
