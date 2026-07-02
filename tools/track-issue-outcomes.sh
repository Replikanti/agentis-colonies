#!/usr/bin/env bash
# tools/track-issue-outcomes.sh — classify the fate of self-filed issues
# (#1402, M4 step 1 of #1266).
#
# The self-observe driver (tools/self-observe.sh, #1266 M3) files small
# tracking issues titled "[self-observe] <kind>: <location>". This script
# closes the feedback gap of that loop: it enumerates those issues, and for
# every CLOSED one not yet recorded classifies the outcome:
#
#   success — closed by a MERGED PR (cross-referenced via the forge API's
#             closing-PR references),
#   noise   — closed without a merged PR (not-planned / wontfix / duplicate,
#             or a closing PR that was itself closed unmerged).
#
# Each classification appends ONE JSONL record
#   {"iid": <n>, "signal_class": "<kind>", "outcome": "success|noise",
#    "closed_at": "<iso8601>"}
# to a memo-backed store (tools/lib/outcome-store.sh, a sibling of
# tools/lib/candidate-queue.sh #1273). signal_class is parsed from the title
# marker (e.g. todo-marker, agent-failure, doc-drift). Idempotent: records
# dedup on iid, so re-running is safe and never duplicates. A transient
# closing-PR lookup failure records NOTHING for that issue (retried next
# run) rather than misfiling it as noise.
#
# Deterministic by design (bash + python3 + the gh CLI; no LLM), same spirit
# as tools/detect-todo-markers.sh (#1272).
#
# Usage:
#   tools/track-issue-outcomes.sh             # scan + record new outcomes
#   tools/track-issue-outcomes.sh --summary   # per-signal-class acceptance
#                                             # rates from the store (reads
#                                             # only the memo, no forge calls)
#
# Knobs (env):
#   TRACK_OUTCOMES_REPO          owner/repo to scan (default Replikanti/agentis-colonies)
#   TRACK_OUTCOMES_GH            gh binary (default gh; overridable for tests)
#   TRACK_OUTCOMES_TITLE_PREFIX  title prefix marking self-filed issues
#                                (default "[self-observe]", matching
#                                tools/self-observe.sh's title format)
#   TRACK_OUTCOMES_LIMIT         max closed issues fetched per scan (default 200)
#   OUTCOME_STORE_KEY            memo key for the store (via lib/outcome-store.sh)
#
# Out of scope (M4 step 2 follow-up): consuming these rates to gate
# self-observe filing volume and issue_creator tier promotion.
#
# Exit: 0 on success (even when there is nothing new to record), 2 on usage error.
set -eu

MODE=scan
case "${1:-}" in
    --summary) MODE=summary ;;
    "")        ;;
    *)         echo "usage: track-issue-outcomes.sh [--summary]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/outcome-store.sh"

REPO="${TRACK_OUTCOMES_REPO:-Replikanti/agentis-colonies}"
GH="${TRACK_OUTCOMES_GH:-gh}"
TITLE_PREFIX="${TRACK_OUTCOMES_TITLE_PREFIX:-[self-observe]}"
LIMIT="${TRACK_OUTCOMES_LIMIT:-200}"
case "$LIMIT" in ''|*[!0-9]*) LIMIT=200 ;; esac

# ---- --summary: per-signal-class acceptance rates from the store ----------
if [ "$MODE" = "summary" ]; then
    outcome_store_read | python3 -c '
import json, sys

stats = {}
for ln in sys.stdin:
    ln = ln.strip()
    if not ln:
        continue
    try:
        rec = json.loads(ln)
    except ValueError:
        continue
    sc = str(rec.get("signal_class") or "unknown")
    st = stats.setdefault(sc, {"success": 0, "noise": 0})
    if rec.get("outcome") == "success":
        st["success"] += 1
    else:
        st["noise"] += 1

if not stats:
    print("[track-outcomes] no recorded outcomes yet.")
    raise SystemExit(0)

print("[track-outcomes] acceptance by signal class:")
tot_s = tot = 0
for sc in sorted(stats):
    s = stats[sc]["success"]
    n = stats[sc]["noise"]
    t = s + n
    tot_s += s
    tot += t
    print("  %-20s %d/%d (%d%%)  success=%d noise=%d"
          % (sc, s, t, int(round(100.0 * s / t)), s, n))
print("[track-outcomes] overall: %d/%d (%d%%)"
      % (tot_s, tot, int(round(100.0 * tot_s / tot))))
'
    exit 0
fi

# ---- scan: enumerate closed self-filed issues, classify + record ----------

# Count of MERGED closing PRs for issue $1, via GraphQL closedByPullRequests-
# References — the forge's canonical "this PR closes that issue" link
# (includeClosedPrs so merged — hence closed — PRs are visible; `merged`
# distinguishes them from closed-unmerged). Prints "ERR" when the API call
# fails or returns unparseable JSON, so the caller can skip recording instead
# of misclassifying a transient failure as noise.
merged_closing_prs() {
    local raw
    # shellcheck disable=SC2016  # $owner/$name/$number are GraphQL variables
    raw="$("$GH" api graphql \
        -F owner="${REPO%%/*}" -F name="${REPO#*/}" -F number="$1" \
        -f query='query($owner: String!, $name: String!, $number: Int!) {
            repository(owner: $owner, name: $name) {
                issue(number: $number) {
                    closedByPullRequestsReferences(first: 20, includeClosedPrs: true) {
                        nodes { number merged }
                    }
                }
            }
        }' 2>/dev/null)" || { echo "ERR"; return 0; }
    printf '%s' "$raw" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    print("ERR")
    raise SystemExit(0)
issue = ((data.get("data") or {}).get("repository") or {}).get("issue") or {}
nodes = (issue.get("closedByPullRequestsReferences") or {}).get("nodes") or []
print(sum(1 for n in nodes if isinstance(n, dict) and n.get("merged") is True))
'
}

RAW="$("$GH" issue list --repo "$REPO" --state closed \
        --search "\"$TITLE_PREFIX\" in:title" \
        --json number,title,closedAt,stateReason --limit "$LIMIT" \
        2>/dev/null || echo '[]')"

# Normalize to TSV candidates: iid, signal_class, closed_at, state_reason.
# The search above is fuzzy; the strict filter is the title-prefix match
# here. signal_class is the marker between the prefix and the first ":"
# ("[self-observe] doc-drift: doc/x.md" -> "doc-drift").
CAND_FILE="$(mktemp)"
trap 'rm -f "$CAND_FILE"' EXIT
printf '%s' "$RAW" | TIO_PREFIX="$TITLE_PREFIX" python3 -c '
import json, os, sys
prefix = os.environ.get("TIO_PREFIX") or "[self-observe]"
try:
    issues = json.load(sys.stdin)
except ValueError:
    issues = []
if not isinstance(issues, list):
    issues = []
for it in issues:
    if not isinstance(it, dict):
        continue
    title = str(it.get("title") or "")
    if not title.startswith(prefix):
        continue
    num = it.get("number")
    if not isinstance(num, int):
        continue
    marker = title[len(prefix):].lstrip()
    signal = marker.split(":", 1)[0].strip() or "unknown"
    print("%d\t%s\t%s\t%s" % (num, signal,
                              str(it.get("closedAt") or ""),
                              str(it.get("stateReason") or "")))
' > "$CAND_FILE"

considered=0
recorded=0
known=0
failed=0
tab="$(printf '\t')"
# Read from the file (not a pipe) so the counters survive in this shell.
while IFS="$tab" read -r iid signal closed_at state_reason; do
    [ -n "$iid" ] || continue
    considered=$((considered + 1))
    if outcome_store_has_iid "$iid"; then
        known=$((known + 1))
        echo "[track-outcomes] already recorded: #$iid ($signal)"
        continue
    fi
    # NOT_PLANNED (wontfix / duplicate / not-planned) is noise by definition —
    # no closing-PR lookup needed.
    if [ "$(printf '%s' "$state_reason" | tr '[:lower:]' '[:upper:]')" = "NOT_PLANNED" ]; then
        outcome="noise"; why="closed as not-planned"
    else
        merged="$(merged_closing_prs "$iid")"
        if [ "$merged" = "ERR" ]; then
            failed=$((failed + 1))
            echo "[track-outcomes] closing-PR lookup FAILED (will retry next run): #$iid ($signal)"
            continue
        elif [ "$merged" -gt 0 ]; then
            outcome="success"; why="closed by merged PR"
        else
            outcome="noise"; why="closed without a merged PR"
        fi
    fi
    outcome_store_append "$iid" "$signal" "$outcome" "$closed_at"
    recorded=$((recorded + 1))
    echo "[track-outcomes] recorded: #$iid $signal -> $outcome ($why)"
done < "$CAND_FILE"

echo "[track-outcomes] done: considered=$considered, recorded=$recorded, already-recorded=$known, lookup-failures=$failed."
