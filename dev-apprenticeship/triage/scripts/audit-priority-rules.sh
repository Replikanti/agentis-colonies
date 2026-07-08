#!/bin/bash
# audit-priority-rules.sh: enumerate crystallized rules whose `action` slot
# still carries a priority-like token (#1478, #1482).
#
# #1474 / PR #1477 added the runtime filter `strip_priority_like_labels()`
# that strips priority-like tokens (`priority*` outside the canonical scoped
# set, `^P\d+$`, `urgent`) from labeler's suggestions AND from the
# crystallized-rule replay path. That guarantees such tokens can no longer be
# APPLIED. But any rule crystallized BEFORE the filter shipped may still hold
# a bare `P1`-`P4` / `urgent` token baked into its action slot in the
# KnowledgeBase — wasting a condition-class slot (its hit now filters down to
# an empty label set) and keeping stale vocabulary in the rule-pool stats.
#
# This is the read-only enumeration half. It recovers the rule pool through
# `agentis knowledge export` (the documented #1478 recipe) rather than
# re-implementing core's on-disk persistence — the first cut (PR #1481) read
# the wrong key, parsed core's binary object bytes as JSON, and text-scanned
# the whole blob, so it silently reported `contaminated: 0` against real state
# (#1482). Only each rule's `action` slot is inspected; the `condition` slot
# is never scanned, so a priority-like keyword in an issue title cannot
# false-flag a clean rule. The mutation half lives in the sibling
# `purge-priority-rules.sh`, which shares the same predicate via lib/.
#
# Usage:
#   audit-priority-rules.sh [--fed-dir DIR] [--class label,route,...]
#                           [--allow tok1,tok2] [--json] [--force]
#                           [--knowledge-dir DIR]
#
#   --fed-dir DIR  federation root containing .agentis/ (default: $COLONY_DIR/..
#                  when exported by start-colony.sh, else this script's
#                  federation root).
#   --class LIST   comma-separated crystallizer action_type list to scan
#                  (default: label — the labeler's class, the only one this
#                  contamination applies to).
#   --allow LIST   extra always-canonical tokens never flagged (scoped
#                  `priority::*` labels are already exempt by construction).
#   --json         machine-readable JSONL (one object per contaminated rule +
#                  a trailing `_summary` object); used by purge-priority-rules.sh.
#   --force        run even when the federation has live daemons (see below).
#   --knowledge-dir DIR
#                  offline/fallback source: read a plain-JSON knowledge dir of
#                  per-class rule files directly instead of `agentis knowledge
#                  export` (deployments without semantic-DAG persistence, or
#                  inspection without a running `agentis`).
#
# Live-daemon guard: an `agentis knowledge export` snapshot taken while the
# triage daemons run may not reflect in-memory rules the crystallizer has not
# yet persisted, and purge-after-audit would race a daemon that re-crystallizes
# the very rule being retired. The tool therefore REFUSES to run against a
# federation with live daemons unless `--force` is passed.
#
# Exit codes: 0 ok (report printed, whether clean or contaminated),
#             1 missing prereq (no .agentis, no python3, no agentis, no helper),
#             2 usage error (unknown flag / missing value),
#             3 live daemons present and --force not given.
#
# Read-only: this script never writes to the rule pool.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/lib/priority-rule-audit.py"

FED_DIR=""
CLASSES="label"
ALLOW=""
JSON=0
FORCE=0
KNOWLEDGE_DIR_OVERRIDE=""

emit_error() { echo "audit-priority-rules.sh: $*" >&2; }

need_val() {
    if [ "$2" -lt 2 ]; then
        emit_error "$1 requires a value"
        exit 2
    fi
}

# Count live daemons registered for FED_DIR (0 when agentis absent/cold).
live_daemon_count() {
    fed="$1"
    if ! command -v agentis >/dev/null 2>&1; then
        echo 0
        return
    fi
    out="$( (cd "$fed" && agentis daemon list --json) 2>/dev/null || : )"
    if [ -z "$out" ]; then
        echo 0
        return
    fi
    python3 -c 'import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    print(0); sys.exit(0)
if isinstance(d,dict):
    d=d.get("daemons",d.get("agents",[]))
print(len(d) if isinstance(d,list) else 0)' "$out" 2>/dev/null || echo 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --fed-dir) need_val "$1" $#; FED_DIR="$2"; shift 2 ;;
        --class)   need_val "$1" $#; CLASSES="$2"; shift 2 ;;
        --allow)   need_val "$1" $#; ALLOW="$2"; shift 2 ;;
        --knowledge-dir) need_val "$1" $#; KNOWLEDGE_DIR_OVERRIDE="$2"; shift 2 ;;
        --json)    JSON=1; shift ;;
        --force)   FORCE=1; shift ;;
        -h|--help)
            sed -n '2,60p' "$0"
            exit 0
            ;;
        *)
            emit_error "unknown flag: $1"
            exit 2
            ;;
    esac
done

# Resolve the federation root. Explicit --fed-dir wins; else the COLONY_DIR
# exported by start-colony.sh (<fed>/triage); else this script's own tree
# (<fed>/triage/scripts/audit-priority-rules.sh -> <fed>).
if [ -z "$FED_DIR" ]; then
    if [ -n "${COLONY_DIR:-}" ]; then
        FED_DIR="$(cd "$COLONY_DIR/.." && pwd)"
    else
        FED_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
    fi
fi

if [ ! -d "$FED_DIR/.agentis" ]; then
    emit_error "--fed-dir must point at a federation root with .agentis/ (got: $FED_DIR)"
    exit 1
fi
if [ ! -f "$HELPER" ]; then
    emit_error "missing helper: $HELPER"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    emit_error "python3 not on PATH"
    exit 1
fi

# Live-daemon guard (skipped only with --force).
if [ "$FORCE" != "1" ]; then
    n="$(live_daemon_count "$FED_DIR")"
    if [ "$n" != "0" ]; then
        emit_error "federation has $n live daemon(s); an export snapshot may be stale and"
        emit_error "purge-after-audit would race a re-crystallizing daemon. Stop the"
        emit_error "federation (./kill-federation.sh) or pass --force to override."
        exit 3
    fi
fi

# Offline/fallback: read a plain-JSON knowledge dir directly.
if [ -n "$KNOWLEDGE_DIR_OVERRIDE" ]; then
    set -- --knowledge-dir "$KNOWLEDGE_DIR_OVERRIDE" --class "$CLASSES"
    if [ -n "$ALLOW" ]; then set -- "$@" --allow "$ALLOW"; fi
    if [ "$JSON" = "1" ]; then set -- "$@" --json; fi
    exec python3 "$HELPER" "$@"
fi

# Primary path: recover the pool through `agentis knowledge export`.
if ! command -v agentis >/dev/null 2>&1; then
    emit_error "agentis not on PATH (needed for 'knowledge export'); pass --knowledge-dir for offline inspection"
    exit 1
fi

py_args=(--export - --class "$CLASSES")
if [ -n "$ALLOW" ]; then py_args+=(--allow "$ALLOW"); fi
if [ "$JSON" = "1" ]; then py_args+=(--json); fi

(cd "$FED_DIR" && agentis knowledge export) | python3 "$HELPER" "${py_args[@]}"
