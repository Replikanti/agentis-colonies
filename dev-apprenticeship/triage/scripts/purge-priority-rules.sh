#!/bin/bash
# purge-priority-rules.sh: retire priority-contaminated crystallized rules
# from the labeler's rule pool (#1478, #1482).
#
# The mutation half of the #1478 audit/purge pass, rebuilt for #1482 on the
# proven export -> filter -> `import --replace` recipe rather than the first
# cut's Python re-implementation of core's persistence (which read the wrong
# key and silently retired nothing). One `agentis knowledge export` snapshot
# drives BOTH the enumeration (lib/priority-rule-audit.py --json, the single
# contamination predicate) and the filter (lib/priority-rule-purge.py), so the
# report and the removal can never diverge. On --apply the filtered pool is
# swapped in via `agentis knowledge import --replace`; the retired rules are
# gone and the clean decision re-crystallizes from post-#1474 verdicts on the
# daemons' next pass.
#
# Dry-run by DEFAULT — prints what would be retired and writes nothing. Pass
# `--apply` to perform the retirement. The federation MUST be stopped first (a
# running daemon can re-crystallize a retired rule straight back into the pool
# between export and import); the tool refuses to run against live daemons
# unless `--force` is given.
#     ./kill-federation.sh   # from dev-apprenticeship/
#
# Usage:
#   purge-priority-rules.sh [--fed-dir DIR] [--class label,...]
#                           [--allow tok1,tok2] [--apply] [--force]
#
#   --fed-dir DIR  federation root containing .agentis/ (default: $COLONY_DIR/..
#                  when exported by start-colony.sh, else this script's
#                  federation root).
#   --class LIST   crystallizer action_type list to scan (default: label).
#   --allow LIST   extra always-canonical tokens never flagged.
#   --apply        perform the retirement (default: dry-run preview).
#   --force        run even when the federation has live daemons (unsafe —
#                  a running daemon can resurrect a retired rule).
#
# Exit codes: 0 ok, 1 missing prereq, 2 usage error, 3 live daemons + no --force.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_HELPER="$SCRIPT_DIR/lib/priority-rule-audit.py"
PURGE_HELPER="$SCRIPT_DIR/lib/priority-rule-purge.py"

FED_DIR=""
CLASSES="label"
ALLOW=""
APPLY=0
FORCE=0

emit_error() { echo "purge-priority-rules.sh: $*" >&2; }

need_val() {
    if [ "$2" -lt 2 ]; then
        emit_error "$1 requires a value"
        exit 2
    fi
}

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
        --apply)   APPLY=1; shift ;;
        --force)   FORCE=1; shift ;;
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
if [ ! -f "$AUDIT_HELPER" ] || [ ! -f "$PURGE_HELPER" ]; then
    emit_error "missing helper(s) under $SCRIPT_DIR/lib/"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    emit_error "python3 not on PATH"
    exit 1
fi
if ! command -v agentis >/dev/null 2>&1; then
    emit_error "agentis not on PATH (needed for 'knowledge export'/'import')"
    exit 1
fi

# Live-daemon guard: purge MUST NOT race a re-crystallizing daemon.
if [ "$FORCE" != "1" ]; then
    n="$(live_daemon_count "$FED_DIR")"
    if [ "$n" != "0" ]; then
        emit_error "federation has $n live daemon(s); a running daemon can resurrect a"
        emit_error "retired rule between export and import. Stop the federation"
        emit_error "(./kill-federation.sh) or pass --force to override."
        exit 3
    fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EXPORT_JSON="$WORK/export.json"
FLAGGED="$WORK/flagged.jsonl"
FILTERED="$WORK/filtered.json"

# One export snapshot drives both enumeration and filter.
(cd "$FED_DIR" && agentis knowledge export) > "$EXPORT_JSON"

audit_args=(--export "$EXPORT_JSON" --class "$CLASSES" --json)
if [ -n "$ALLOW" ]; then audit_args+=(--allow "$ALLOW"); fi
python3 "$AUDIT_HELPER" "${audit_args[@]}" > "$FLAGGED"

if [ "$APPLY" = "1" ]; then
    python3 "$PURGE_HELPER" --export "$EXPORT_JSON" --apply --out "$FILTERED" < "$FLAGGED"
    # Swap the whole pool for the cleaned set.
    (cd "$FED_DIR" && agentis knowledge import --replace) < "$FILTERED"
    echo ""
    echo "purge-priority-rules.sh: imported cleaned pool via 'agentis knowledge import --replace'."
    echo "  Restart the triage daemons so the in-memory pool reloads without the retired rules."
else
    python3 "$PURGE_HELPER" --export "$EXPORT_JSON" < "$FLAGGED"
fi
