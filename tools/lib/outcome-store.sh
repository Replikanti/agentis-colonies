#!/usr/bin/env bash
# tools/lib/outcome-store.sh — shared, dependency-free helper for appending
# and reading self-filed-issue OUTCOME records as JSONL over a single agentis
# memo key. Sibling of tools/lib/candidate-queue.sh (#1273); consumed by
# tools/track-issue-outcomes.sh (#1402, M4 step 1 of #1266).
#
# Record shape — one JSON object per line (JSONL):
#   {"iid": <int>, "signal_class": <str>, "outcome": <str>, "closed_at": <str>}
#
# Every field is encoded with python3 json.dumps so the on-the-wire JSONL
# stays valid and survives the read-modify-write round trip.
#
# Storage: a single agentis memo key holds the whole JSONL blob. Default
# `self_observe:outcomes`, overridable via OUTCOME_STORE_KEY. Append is a
# read-modify-write against that one key.
#
# Dependencies: bash + python3 + the `agentis memo get/set` CLI. Nothing else.
#
# Usage: source this file, then:
#   outcome_store_read                              # prints the stored JSONL
#   outcome_store_has_iid <iid>                     # exit 0 when iid recorded
#   outcome_store_append <iid> <signal_class> <outcome> <closed_at>

OUTCOME_STORE_KEY="${OUTCOME_STORE_KEY:-self_observe:outcomes}"

# outcome_store_read: print all stored records (the raw JSONL) to stdout.
# Empty/unset key prints nothing.
outcome_store_read() {
    agentis memo get "$OUTCOME_STORE_KEY" 2>/dev/null || true
}

# outcome_store_has_iid <iid>: exit 0 when the store already holds a record
# for this iid — the dedup key that makes re-runs idempotent — 1 otherwise.
# Malformed lines are skipped, never fatal.
outcome_store_has_iid() {
    outcome_store_read | OS_IID="${1-}" python3 -c '
import json, os, sys
try:
    want = int(os.environ.get("OS_IID", ""))
except ValueError:
    sys.exit(1)
for ln in sys.stdin:
    ln = ln.strip()
    if not ln:
        continue
    try:
        rec = json.loads(ln)
    except ValueError:
        continue
    if rec.get("iid") == want:
        sys.exit(0)
sys.exit(1)
'
}

# outcome_store_append <iid> <signal_class> <outcome> <closed_at>
# Encode one JSONL record (fields passed through the environment so no shell
# quoting can break json.dumps' safe encoding) and append it to the store.
outcome_store_append() {
    local line existing updated
    line="$(OS_IID="${1-}" OS_SIGNAL="${2-}" OS_OUTCOME="${3-}" \
            OS_CLOSED="${4-}" python3 -c '
import json, os
try:
    iid = int(os.environ.get("OS_IID", ""))
except ValueError:
    iid = 0
print(json.dumps({
    "iid":          iid,
    "signal_class": os.environ.get("OS_SIGNAL", ""),
    "outcome":      os.environ.get("OS_OUTCOME", ""),
    "closed_at":    os.environ.get("OS_CLOSED", ""),
}, ensure_ascii=False))
')" || return 1

    existing="$(outcome_store_read)"
    if [ -n "$existing" ]; then
        updated="$existing
$line"
    else
        updated="$line"
    fi

    agentis memo set "$OUTCOME_STORE_KEY" "$updated"
}
