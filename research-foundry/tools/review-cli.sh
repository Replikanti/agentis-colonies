#!/bin/bash
# review-cli.sh -- HITL review helper for the preprint-foundry
# federation (#596).
#
# Lists DRAFTED rows in the latest preprint-ledger.jsonl under
# preprint-foundry/runs/, optionally renders the per-claim main.pdf via
# `xdg-open`, and writes the per-claim HITL approval memo key that the
# submitter colony reads on its next tick.
#
# Usage:
#   ./tools/review-cli.sh                                # list DRAFTED rows
#   ./tools/review-cli.sh --list                         # explicit list mode
#   ./tools/review-cli.sh --run <run-ts>                 # operate on a specific run
#   ./tools/review-cli.sh --show <claim-id>              # open main.pdf for the claim
#   ./tools/review-cli.sh --approve <claim-id>           # flip human_status=approved
#   ./tools/review-cli.sh --reject <claim-id> --reason "..."  # flip rejected + reason
#
# Notes:
#   - The memo write is delivered via `podman exec` against the running
#     preprint-foundry container (one daemon set per run). When the
#     container is not running, the helper falls back to writing the
#     memo against the run-dir's hermetic `.agentis/` directly via
#     `agentis memo set` with cwd set to the laptop-node dir.
#   - The submitter's next tick observes the flag; nothing is sent until
#     then. Approval is idempotent: re-approving an already-SUBMITTED
#     claim is a no-op.
#
# Exit codes:
#   0   ok
#   2   invalid flag / missing arg
#   3   no run dir / no preprint-ledger / claim id not in DRAFTED set
#   4   memo write failure

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"

MODE="list"
RUN_TS=""
CLAIM_ID=""
REASON=""

while [ $# -gt 0 ]; do
    case "$1" in
        --list)
            MODE="list"
            shift
            ;;
        --run)
            if [ -z "${2:-}" ]; then
                echo "review-cli: --run requires a timestamp" >&2
                exit 2
            fi
            RUN_TS="$2"
            shift 2
            ;;
        --show)
            if [ -z "${2:-}" ]; then
                echo "review-cli: --show requires a claim id" >&2
                exit 2
            fi
            MODE="show"
            CLAIM_ID="$2"
            shift 2
            ;;
        --approve)
            if [ -z "${2:-}" ]; then
                echo "review-cli: --approve requires a claim id" >&2
                exit 2
            fi
            MODE="approve"
            CLAIM_ID="$2"
            shift 2
            ;;
        --reject)
            if [ -z "${2:-}" ]; then
                echo "review-cli: --reject requires a claim id" >&2
                exit 2
            fi
            MODE="reject"
            CLAIM_ID="$2"
            shift 2
            ;;
        --reason)
            if [ -z "${2:-}" ]; then
                echo "review-cli: --reason requires text" >&2
                exit 2
            fi
            REASON="$2"
            shift 2
            ;;
        -h|--help)
            awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$SCRIPT_PATH"
            exit 0
            ;;
        *)
            echo "review-cli: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# Resolve the run dir.
RUNS_DIR="$FED_DIR/runs"
if [ ! -d "$RUNS_DIR" ]; then
    echo "review-cli: no runs dir at $RUNS_DIR (run tools/run-preprint.sh first)" >&2
    exit 3
fi

if [ -n "$RUN_TS" ]; then
    RUN_DIR="$RUNS_DIR/$RUN_TS"
else
    # Latest run by name (timestamps sort lexicographically).
    RUN_DIR="$(ls -1d "$RUNS_DIR"/*/ 2>/dev/null | sort | tail -n 1 || true)"
    RUN_DIR="${RUN_DIR%/}"
fi
if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
    echo "review-cli: could not resolve run dir (RUNS_DIR=$RUNS_DIR RUN_TS=$RUN_TS)" >&2
    exit 3
fi

LEDGER="$RUN_DIR/preprint-ledger.jsonl"
if [ ! -f "$LEDGER" ]; then
    echo "review-cli: no preprint-ledger.jsonl at $LEDGER" >&2
    exit 3
fi

LAPTOP_DIR="$RUN_DIR/laptop-node"
CONTAINER_NAME="research-foundry-laptop"

# Helper: write a memo key. Prefer the running container; fall back to
# direct agentis-cli against the laptop-node dir.
memo_set() {
    key="$1"
    value="$2"
    if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        podman exec "$CONTAINER_NAME" agentis memo set "$key" "$value" >/dev/null 2>&1 || return 1
    else
        if [ ! -d "$LAPTOP_DIR/.agentis" ]; then
            echo "review-cli: container not running and no $LAPTOP_DIR/.agentis to fall back on" >&2
            return 1
        fi
        (cd "$LAPTOP_DIR" && agentis memo set "$key" "$value" >/dev/null 2>&1) || return 1
    fi
    return 0
}

# Helper: render DRAFTED rows as a tab-separated table.
list_drafted() {
    python3 - "$LEDGER" <<'PYLIST'
import json, sys
path = sys.argv[1]
print("CLAIM_ID\tTITLE\tCOMPILE_OK\tPDF_PATH")
drafted = {}
status = {}
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        cid = row.get("source_claim_id")
        if not cid:
            continue
        st = row.get("status", "")
        # Latest status per claim wins (rows are append-only chronological).
        status[cid] = st
        if st == "DRAFTED":
            drafted[cid] = row
for cid, row in drafted.items():
    cur = status.get(cid, "DRAFTED")
    if cur != "DRAFTED":
        continue
    title = row.get("title", "")
    ok = row.get("latex_compile_ok", False)
    pdf = (row.get("preprint_path") or "") + "/main.pdf"
    print(cid + "\t" + str(title)[:60] + "\t" + str(ok) + "\t" + pdf)
PYLIST
}

# Helper: read the PDF path for a given claim id from the ledger.
pdf_path_for_claim() {
    python3 - "$LEDGER" "$1" <<'PYPDF'
import json, sys
path, target = sys.argv[1], sys.argv[2]
result = ""
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("source_claim_id") == target and row.get("status") == "DRAFTED":
            result = (row.get("preprint_path") or "") + "/main.pdf"
            break
print(result)
PYPDF
}

case "$MODE" in
    list)
        echo "[review-cli] run dir: $RUN_DIR"
        echo "[review-cli] ledger:  $LEDGER"
        echo ""
        list_drafted
        ;;
    show)
        pdf="$(pdf_path_for_claim "$CLAIM_ID")"
        if [ -z "$pdf" ]; then
            echo "review-cli: no DRAFTED row for claim_id=$CLAIM_ID" >&2
            exit 3
        fi
        host_pdf="$LAPTOP_DIR$(echo "$pdf" | sed -e 's|^/run-root||')"
        if [ ! -f "$host_pdf" ]; then
            echo "review-cli: PDF not found on host: $host_pdf" >&2
            echo "  container path was: $pdf" >&2
            exit 3
        fi
        if command -v xdg-open >/dev/null 2>&1; then
            xdg-open "$host_pdf" >/dev/null 2>&1 &
            echo "[review-cli] opened $host_pdf via xdg-open"
        else
            echo "[review-cli] xdg-open not available; pdf path: $host_pdf"
        fi
        ;;
    approve)
        key="submitter:$CLAIM_ID:human_status"
        if memo_set "$key" "approved"; then
            echo "[review-cli] approved $CLAIM_ID ($key = approved)"
            echo "[review-cli] submitter will SMTP-send on its next tick."
        else
            echo "review-cli: failed to write memo key $key" >&2
            exit 4
        fi
        ;;
    reject)
        key="submitter:$CLAIM_ID:human_status"
        reason_key="submitter:$CLAIM_ID:human_reject_reason"
        if memo_set "$key" "rejected"; then
            if [ -n "$REASON" ]; then
                memo_set "$reason_key" "$REASON" || true
            fi
            echo "[review-cli] rejected $CLAIM_ID ($key = rejected)"
            if [ -n "$REASON" ]; then
                echo "[review-cli] reason: $REASON"
            fi
            echo "[review-cli] submitter will write HUMAN_REJECTED row on its next tick."
        else
            echo "review-cli: failed to write memo key $key" >&2
            exit 4
        fi
        ;;
esac

exit 0
