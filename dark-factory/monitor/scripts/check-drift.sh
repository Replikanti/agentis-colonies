#!/bin/sh
# check-drift.sh — watch-spec DRIFT detector for the Monitor colony (#1097).
#
# A static watch-spec (run-live-watch.sh's MONITOR_INV_SPEC) is DERIVED ONCE. When
# the target UPGRADES (new implementation, changed params, new method selectors) the
# spec silently stops matching the deployed contract — the monitor keeps "watching"
# stale invariants and goes effectively BLIND without saying so. This periodic job
# re-reads the deployed-target FINGERPRINT (the deployed-bytecode hash + the EIP-1967
# implementation slot) that run-live-watch.sh captured at derivation time, compares
# it to the live chain, and raises a `drift` alert (severity HIGH) when they no
# longer match — so the monitor SAYS it has gone blind on a stale spec.
#
# READ-ONLY / NON-CUSTODIAL: only `cast code` / `cast storage` reads (routed through
# scripts/cast-read.sh so the RPC failover + consensus apply). Holds no key, never
# writes the chain. On drift it forwards an alert through scripts/notify.sh (the
# colony's sink) and posts the fact to the monitor:signal:drift blackboard memo when
# `agentis` is available — exactly the bus->page path the watchers use.
#
# Usage:
#   check-drift.sh [--fingerprint <file>]
#     --fingerprint <file>  the fingerprint JSON run-live-watch.sh wrote (default:
#                           "$MONITOR_INV_SPEC.fingerprint.json", i.e. next to the
#                           watch-spec). The file records the address + the captured
#                           code_hash + impl_slot.
#
# Environment (the same contract the watchers + cast-read.sh read):
#   MONITOR_CAST          path to the `cast` binary (foundry). "" => cannot re-read
#                         the fingerprint => exit 3 (no check; never a false alert).
#   MONITOR_RPC_URLS / MONITOR_RPC_URL / MONITOR_RPC_CONSENSUS   RPC list + quorum.
#   MONITOR_INV_SPEC      the watch-spec path; its sibling .fingerprint.json is the
#                         default fingerprint file.
#   MONITOR_WEBHOOK_URL[/_HIGH]  alert sink (forwarded to notify.sh on drift).
#
# Exit codes: 0 no drift (or quiet: nothing captured to compare against),
#   2 usage error, 3 no reader / no fingerprint to check, 4 DRIFT detected
#   (an alert was raised).
#
# POSIX sh / dash-safe: no bashisms, no arrays, no `\xHH` printf escapes. CI runs
# this under `sh` = dash. shellcheck-clean.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FINGERPRINT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --fingerprint)
            if [ -z "${2:-}" ]; then
                echo "check-drift.sh: --fingerprint requires a path" >&2
                exit 2
            fi
            FINGERPRINT="$2"
            shift 2
            ;;
        --help|-h)
            awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"
            exit 0
            ;;
        -*)
            echo "check-drift.sh: unknown flag: $1" >&2
            exit 2
            ;;
        *)
            echo "check-drift.sh: unexpected argument: $1" >&2
            exit 2
            ;;
    esac
done

# Default the fingerprint file to the watch-spec's sibling.
if [ -z "$FINGERPRINT" ]; then
    SPEC="${MONITOR_INV_SPEC:-}"
    if [ -n "$SPEC" ]; then
        FINGERPRINT="$SPEC.fingerprint.json"
    fi
fi

if [ -z "$FINGERPRINT" ] || [ ! -f "$FINGERPRINT" ]; then
    echo "check-drift.sh: no fingerprint file (set --fingerprint or MONITOR_INV_SPEC); nothing to check" >&2
    exit 3
fi

# Read the captured baseline fields out of the fingerprint JSON via python3 (a hard
# federation dependency); a malformed file yields empty fields (nothing to compare).
FP_FIELDS="$(FP_FILE="$FINGERPRINT" python3 -c '
import json, os, sys
try:
    with open(os.environ["FP_FILE"], "r", encoding="utf-8") as fh:
        obj = json.load(fh)
    if not isinstance(obj, dict):
        obj = {}
except Exception:
    obj = {}
addr = str(obj.get("address", ""))
ch = str(obj.get("code_hash", ""))
impl = str(obj.get("impl_slot", "")).lower()
# Tab-separated so a value can never split a field.
sys.stdout.write("\t".join((addr, ch, impl)))
')"
BASE_ADDR="$(printf '%s' "$FP_FIELDS" | cut -f1)"
BASE_HASH="$(printf '%s' "$FP_FIELDS" | cut -f2)"
BASE_IMPL="$(printf '%s' "$FP_FIELDS" | cut -f3)"

if [ -z "$BASE_ADDR" ]; then
    echo "check-drift.sh: fingerprint has no address; nothing to check" >&2
    exit 3
fi
if [ -z "$BASE_HASH" ] && [ -z "$BASE_IMPL" ]; then
    # The fingerprint was written empty (no cast / unreachable RPC at derivation) —
    # there is no captured baseline, so a drift can only ever be a CHANGE vs a real
    # baseline. Stay quiet (never a false alarm on an absent baseline).
    echo "check-drift.sh: fingerprint captured no code_hash/impl baseline; nothing to compare — quiet" >&2
    exit 0
fi

CAST="${MONITOR_CAST:-}"
if [ -z "$CAST" ]; then
    echo "check-drift.sh: MONITOR_CAST unset; cannot re-read the target — no check (never a false alert)" >&2
    exit 3
fi

CAST_READ="$SCRIPT_DIR/cast-read.sh"
if [ ! -x "$CAST_READ" ]; then
    echo "check-drift.sh: cast-read.sh not found/executable at $CAST_READ" >&2
    exit 3
fi

IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"

# Re-read the live deployed CODE + IMPL through cast-read.sh (RPC failover +
# consensus in ONE place). An all-endpoints-fail read yields "" (the no-read
# sentinel) — which we treat as "cannot check this tick", NOT as drift (a blind RPC
# must never masquerade as an upgrade).
CUR_CODE="$("$CAST_READ" code "$BASE_ADDR" 2>/dev/null || true)"
CUR_IMPL="$("$CAST_READ" storage "$BASE_ADDR" "$IMPL_SLOT" 2>/dev/null || true)"

CUR_HASH=""
if [ -n "$CUR_CODE" ] && [ "$CUR_CODE" != "0x" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        CUR_HASH="$(printf '%s' "$CUR_CODE" | sha256sum | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        CUR_HASH="$(printf '%s' "$CUR_CODE" | shasum -a 256 | awk '{print $1}')"
    fi
fi

# Compare each captured field to the live re-read. A field drifts only when it has
# BOTH a captured baseline AND a live read that DIFFERS — a no-read (empty live
# value) is never drift.
CODE_DRIFT=0
IMPL_DRIFT=0
if [ -n "$BASE_HASH" ] && [ -n "$CUR_HASH" ] && [ "$CUR_HASH" != "$BASE_HASH" ]; then
    CODE_DRIFT=1
fi
if [ -n "$BASE_IMPL" ] && [ -n "$CUR_IMPL" ] && [ "$CUR_IMPL" != "$BASE_IMPL" ]; then
    IMPL_DRIFT=1
fi

if [ "$CODE_DRIFT" -eq 0 ] && [ "$IMPL_DRIFT" -eq 0 ]; then
    echo "check-drift.sh: no drift — deployed code/impl still match the watch-spec fingerprint ($BASE_ADDR)"
    exit 0
fi

# --- DRIFT: the spec has gone blind on an upgraded target -----------------------
# Build a compact, deterministic alert (kind=drift, severity=high) and forward it
# through notify.sh (the colony sink) so a page is delivered. The body is passed to
# notify.sh via env (no untrusted interpolation) and posted to the blackboard memo.
WHICH="code+impl"
if [ "$CODE_DRIFT" -eq 1 ] && [ "$IMPL_DRIFT" -eq 0 ]; then
    WHICH="code"
elif [ "$CODE_DRIFT" -eq 0 ] && [ "$IMPL_DRIFT" -eq 1 ]; then
    WHICH="impl"
fi

ALERT="$(ADDR="$BASE_ADDR" WHICH="$WHICH" \
    BASE_HASH="$BASE_HASH" CUR_HASH="$CUR_HASH" BASE_IMPL="$BASE_IMPL" CUR_IMPL="$CUR_IMPL" \
    python3 -c '
import json, os
print(json.dumps({
    "watcher": "drift",
    "kind": "drift",
    "verdict": "spec-stale",
    "drifted": os.environ["WHICH"],
    "address": os.environ["ADDR"],
    "baseline_code_hash": os.environ["BASE_HASH"],
    "current_code_hash": os.environ["CUR_HASH"],
    "baseline_impl": os.environ["BASE_IMPL"],
    "current_impl": os.environ["CUR_IMPL"],
    "severity": "high",
}))
')"

echo "check-drift.sh: DRIFT detected on $BASE_ADDR ($WHICH changed) — the watch-spec has gone blind; re-derive" >&2

# Post to the blackboard memo (the coordinator/operator read it), best-effort.
if command -v agentis >/dev/null 2>&1; then
    agentis memo set "monitor:signal:drift" "$ALERT" >/dev/null 2>&1 || true
fi

# Forward through the colony sink so a page is actually delivered. notify.sh routes
# `high` severity to MONITOR_WEBHOOK_URL_HIGH (falling back to MONITOR_WEBHOOK_URL),
# and prints to stdout when no webhook is configured (the no-op sink).
NOTIFY="$SCRIPT_DIR/notify.sh"
if [ -x "$NOTIFY" ]; then
    "$NOTIFY" "$ALERT" || true
else
    echo "[monitor:alert] $ALERT"
fi

exit 4
