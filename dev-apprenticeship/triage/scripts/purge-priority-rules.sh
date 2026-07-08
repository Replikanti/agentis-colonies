#!/bin/bash
# purge-priority-rules.sh: retire priority-contaminated crystallized rules
# from the labeler's rule pool (#1478).
#
# The mutation half of the #1478 audit/purge pass. It calls the sibling
# `audit-priority-rules.sh --json` to ENUMERATE the contaminated rules (so
# both scripts share the single contamination predicate in
# lib/priority-rule-audit.py — the heuristic can never drift between report
# and purge), then hands that JSONL to lib/priority-rule-purge.py, which
# RETIRES each flagged rule by de-registering it from the crystallizer index
# (+ removing its telemetry sidecar). The immutable content-addressed rule
# object is left in place but un-indexed, so it is inert; the clean decision
# re-crystallizes from post-#1474 verdicts on the daemons' next pass.
#
# Dry-run by DEFAULT — prints what would be retired and writes nothing. Pass
# `--apply` to perform the retirement. Stop the federation first (a running
# daemon can re-crystallize between enumeration and rewrite):
#     ./kill-federation.sh   # from dev-apprenticeship/
#
# Usage:
#   purge-priority-rules.sh [--fed-dir DIR] [--class label,...]
#                           [--allow tok1,tok2] [--apply]
#
#   --fed-dir DIR  federation root containing .agentis/ (default: $COLONY_DIR/..
#                  when exported by start-colony.sh, else this script's
#                  federation root).
#   --class LIST   crystallizer action_type list to scan (default: label).
#   --allow LIST   extra always-canonical tokens never flagged.
#   --apply        perform the retirement (default: dry-run preview).
#
# Exit codes: 0 ok, 1 missing prereq, 2 usage error.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT="$SCRIPT_DIR/audit-priority-rules.sh"
PURGE_HELPER="$SCRIPT_DIR/lib/priority-rule-purge.py"

FED_DIR=""
CLASSES="label"
ALLOW=""
APPLY=0

emit_error() { echo "purge-priority-rules.sh: $*" >&2; }

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
        --apply)   APPLY=1; shift ;;
        -h|--help)
            sed -n '2,36p' "$0"
            exit 0
            ;;
        *)
            emit_error "unknown flag: $1"
            exit 2
            ;;
    esac
done

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
if [ ! -x "$AUDIT" ]; then
    emit_error "sibling audit script not executable: $AUDIT"
    exit 1
fi
if [ ! -f "$PURGE_HELPER" ]; then
    emit_error "missing helper: $PURGE_HELPER"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    emit_error "python3 not on PATH"
    exit 1
fi

# Build the shared audit invocation (enumeration only — --json).
audit_args=(--fed-dir "$FED_DIR" --class "$CLASSES" --json)
if [ -n "$ALLOW" ]; then
    audit_args+=(--allow "$ALLOW")
fi

purge_args=(--knowledge-dir "$FED_DIR/.agentis/knowledge")
if [ "$APPLY" = "1" ]; then
    purge_args+=(--apply)
fi

"$AUDIT" "${audit_args[@]}" | python3 "$PURGE_HELPER" "${purge_args[@]}"
