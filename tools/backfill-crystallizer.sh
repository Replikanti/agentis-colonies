#!/bin/bash
# tools/backfill-crystallizer.sh: distill historical operator decisions into
# the triage crystallizer pool (#1431).
#
# BM25 retrieval (#1429/#1430) can only rank what is already in the rule
# pool / KnowledgeBase — and without this tool the pool grows only from
# runtime LLM decisions (cold start: zero rules on a fresh federation, zero
# Stage 1/1b hits for days). The forge already holds the training data:
# every labeled / assigned / prioritized issue is an operator-confirmed
# (context -> action) pair extractable deterministically, with ZERO LLM
# calls. This tool converts them into learn() + distill() +
# knowledge_validate() rows via a generated .ag driver executed with
# `agentis go` from the federation root; classes seen >= 3 times reach the
# crystallize gate and materialize as replayable rules on the daemons' next
# M141 pass.
#
# Canonical contexts/actions come from tools/lib/canonical-context.py — the
# shared builder drift-guarded against the agents' inline builders by
# tools/test-canonical-context.sh — so backfilled rules are byte-reachable
# from Stage 1 prefix replay and Stage 1b BM25 class-confirm.
#
# Usage:
#   backfill-crystallizer.sh --fed-dir <dir> [--colony-dir <dir>]
#                            [--issues-json <file>] [--max N]
#                            [--classes label,route,prioritize]
#                            [--dry-run] [--incremental] [--keep]
#
#   --fed-dir      federation root (contains .agentis). Required.
#   --colony-dir   triage colony dir for the forge fetch (default:
#                  $COLONY_DIR, else <fed-dir>/triage). The fetch runs
#                  `<colony>/scripts/forge-api.sh issues --view raw`, so
#                  the forge env (GITLAB_*/GITHUB_*) must be present —
#                  invoke via `triage/scripts/start-colony.sh --ingest`
#                  for the sourced-env path, or export it yourself.
#   --issues-json  read raw issues JSON from a file instead of the forge
#                  (offline / test path; no env needed).
#   --max N        cap on issues considered, newest first (default 200).
#   --classes      comma list (default all three).
#   --dry-run      print the would-be rule table, write nothing.
#   --incremental  only issues updated since the triage:ingest:cursor memo;
#                  advance the cursor afterwards. The continuous-ingestion
#                  mode the start-federation.sh sidecar drives.
#   --keep         keep the generated driver files (prints their dir).
#
# Exit codes: 0 ok (including "nothing to do"), 1 missing prereq/input,
# 2 usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CANON="$SCRIPT_DIR/lib/canonical-context.py"
GEN="$SCRIPT_DIR/lib/backfill-gen.py"

FED_DIR=""
COLONY_DIR_ARG=""
ISSUES_JSON=""
MAX_ISSUES="${BACKFILL_MAX_ISSUES:-200}"
CLASSES="label,route,prioritize"
DRY_RUN=0
INCREMENTAL=0
KEEP=0

need_val() {
    if [ "$2" -lt 2 ]; then
        echo "backfill-crystallizer.sh: $1 requires a value" >&2
        exit 2
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --fed-dir)      need_val "$1" $#; FED_DIR="$2"; shift 2 ;;
        --colony-dir)   need_val "$1" $#; COLONY_DIR_ARG="$2"; shift 2 ;;
        --issues-json)  need_val "$1" $#; ISSUES_JSON="$2"; shift 2 ;;
        --max)          need_val "$1" $#; MAX_ISSUES="$2"; shift 2 ;;
        --classes)      need_val "$1" $#; CLASSES="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --incremental)  INCREMENTAL=1; shift ;;
        --keep)         KEEP=1; shift ;;
        *)
            echo "backfill-crystallizer.sh: unknown flag: $1" >&2
            exit 2
            ;;
    esac
done

case "$MAX_ISSUES" in
    ''|*[!0-9]*) echo "backfill-crystallizer.sh: --max must be a number" >&2; exit 2 ;;
esac

if [ -z "$FED_DIR" ] || [ ! -d "$FED_DIR/.agentis" ]; then
    echo "backfill-crystallizer.sh: --fed-dir must point at a federation root with .agentis/" >&2
    exit 1
fi
if [ ! -f "$CANON" ] || [ ! -f "$GEN" ]; then
    echo "backfill-crystallizer.sh: missing tools/lib helpers" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
if [ "$KEEP" = "1" ]; then
    trap - EXIT
else
    trap 'rm -rf "$WORK_DIR"' EXIT
fi

RAW_JSON="$WORK_DIR/issues.json"
if [ -n "$ISSUES_JSON" ]; then
    if [ ! -f "$ISSUES_JSON" ]; then
        echo "backfill-crystallizer.sh: --issues-json file not found: $ISSUES_JSON" >&2
        exit 1
    fi
    cp "$ISSUES_JSON" "$RAW_JSON"
else
    COLONY_DIR_EFF="${COLONY_DIR_ARG:-${COLONY_DIR:-$FED_DIR/triage}}"
    FORGE="$COLONY_DIR_EFF/scripts/forge-api.sh"
    if [ ! -x "$FORGE" ]; then
        echo "backfill-crystallizer.sh: forge-api.sh not executable at $FORGE" >&2
        exit 1
    fi
    if ! COLONY_DIR="$COLONY_DIR_EFF" "$FORGE" issues --view raw > "$RAW_JSON" 2>"$WORK_DIR/fetch.err"; then
        echo "backfill-crystallizer.sh: forge fetch failed:" >&2
        cat "$WORK_DIR/fetch.err" >&2
        exit 1
    fi
fi

# Operator identity + priority vocabulary from the federation memo store —
# the same sources the agents read (gitlab:me, triage:labels:priority).
ME_VAL="$( (cd "$FED_DIR" && agentis memo get gitlab:me 2>/dev/null) || true)"
PV_VAL="$( (cd "$FED_DIR" && agentis memo get triage:labels:priority 2>/dev/null) || true)"

SINCE=""
ORDER="newest"
if [ "$INCREMENTAL" = "1" ]; then
    SINCE="$( (cd "$FED_DIR" && agentis memo get triage:ingest:cursor 2>/dev/null) || true)"
    # Oldest-first is load-bearing in incremental mode: with newest-first,
    # a window holding more than --max decided issues (guaranteed on the
    # first ever tick, where the cursor is empty) would advance the cursor
    # past the un-processed older tail and skip it FOREVER. Oldest-first
    # makes each tick a monotonic step through history — a large backlog
    # drains at --max issues per sidecar tick. Raise BACKFILL_MAX_ISSUES
    # to drain faster.
    ORDER="oldest"
fi

TRIPLES="$WORK_DIR/triples.jsonl"
CURSOR_FILE="$WORK_DIR/cursor.txt"
ME="$ME_VAL" PV="$PV_VAL" python3 "$CANON" triples \
    --classes "$CLASSES" --max "$MAX_ISSUES" --since "$SINCE" \
    --order "$ORDER" --cursor-out "$CURSOR_FILE" < "$RAW_JSON" > "$TRIPLES"

TRIPLE_COUNT="$(grep -c . "$TRIPLES" || true)"
if [ "$TRIPLE_COUNT" -eq 0 ]; then
    echo "backfill-crystallizer.sh: no decided issues to ingest (since='${SINCE}')"
    # Still advance the cursor in incremental mode so a quiet window does
    # not re-scan the same issues forever.
    if [ "$INCREMENTAL" = "1" ] && [ -s "$CURSOR_FILE" ]; then
        (cd "$FED_DIR" && agentis memo set triage:ingest:cursor "$(cat "$CURSOR_FILE")" >/dev/null 2>&1) || true
    fi
    exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
    python3 "$GEN" --table < "$TRIPLES"
    exit 0
fi

if ! command -v agentis >/dev/null 2>&1; then
    echo "backfill-crystallizer.sh: agentis not on PATH (needed to run the driver)" >&2
    exit 1
fi

# Chunk the driver so a huge history cannot blow one file's CB budget:
# 100 triples per driver, each with its own generated `cb` ceiling.
split -l 100 "$TRIPLES" "$WORK_DIR/chunk."
RC=0
for chunk in "$WORK_DIR"/chunk.*; do
    [ -f "$chunk" ] || continue
    driver="$chunk.ag"
    python3 "$GEN" < "$chunk" > "$driver"
    if ! (cd "$FED_DIR" && agentis go "$driver") >> "$WORK_DIR/run.log" 2>&1; then
        echo "backfill-crystallizer.sh: driver failed for $driver (see $WORK_DIR/run.log)" >&2
        RC=1
        # Keep the evidence on failure even without --keep.
        trap - EXIT
    fi
done

if [ "$RC" -eq 0 ] && [ "$INCREMENTAL" = "1" ] && [ -s "$CURSOR_FILE" ]; then
    (cd "$FED_DIR" && agentis memo set triage:ingest:cursor "$(cat "$CURSOR_FILE")" >/dev/null 2>&1) || true
fi

if [ "$RC" -eq 0 ]; then
    echo "backfill-crystallizer.sh: ingested $TRIPLE_COUNT triples (classes: $CLASSES)"
else
    echo "backfill-crystallizer.sh: attempted $TRIPLE_COUNT triples, at least one driver failed (classes: $CLASSES)" >&2
fi
if [ "$KEEP" = "1" ] || [ "$RC" -ne 0 ]; then
    echo "backfill-crystallizer.sh: work dir kept at $WORK_DIR"
fi
exit "$RC"
