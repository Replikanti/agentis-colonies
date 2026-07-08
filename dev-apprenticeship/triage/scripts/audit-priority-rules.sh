#!/bin/bash
# audit-priority-rules.sh: enumerate crystallized rules whose `action` slot
# still carries a priority-like token (#1478).
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
# This is the read-only enumeration half: it reports the count + rule ids of
# contaminated rules in the live pool. The mutation half (retire the flagged
# rules so they re-crystallize cleanly from post-#1474 verdicts) lives in the
# sibling `purge-priority-rules.sh`, which calls THIS script with `--json` so
# both share one contamination predicate (lib/priority-rule-audit.py).
#
# Usage:
#   audit-priority-rules.sh [--fed-dir DIR] [--class label,route,...]
#                           [--allow tok1,tok2] [--json]
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
#
# Exit codes: 0 ok (report printed, whether clean or contaminated),
#             1 missing prereq (no .agentis, no python3, no helper),
#             2 usage error (unknown flag / missing value).
#
# Read-only: this script never writes to the rule pool.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/lib/priority-rule-audit.py"

FED_DIR=""
CLASSES="label"
ALLOW=""
JSON=0

emit_error() { echo "audit-priority-rules.sh: $*" >&2; }

need_val() {
    if [ "$2" -lt 2 ]; then
        emit_error "$1 requires a value"
        exit 2
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --fed-dir) need_val "$1" $#; FED_DIR="$2"; shift 2 ;;
        --class)   need_val "$1" $#; CLASSES="$2"; shift 2 ;;
        --allow)   need_val "$1" $#; ALLOW="$2"; shift 2 ;;
        --json)    JSON=1; shift ;;
        -h|--help)
            sed -n '2,40p' "$0"
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

KNOWLEDGE_DIR="$FED_DIR/.agentis/knowledge"
OBJECTS_DIR="$FED_DIR/.agentis/objects"

set -- --knowledge-dir "$KNOWLEDGE_DIR" --objects-dir "$OBJECTS_DIR" --class "$CLASSES"
if [ -n "$ALLOW" ]; then
    set -- "$@" --allow "$ALLOW"
fi
if [ "$JSON" = "1" ]; then
    set -- "$@" --json
fi

exec python3 "$HELPER" "$@"
