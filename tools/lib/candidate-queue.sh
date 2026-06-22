#!/usr/bin/env bash
# tools/lib/candidate-queue.sh — shared, dependency-free helper for
# appending and reading structured issue-candidate records as JSONL over
# a single agentis memo key. Queue primitive that the issue_creator will
# consume for #1266 M1 (added in #1273).
#
# Record shape — one JSON object per line (JSONL):
#   {"title": <str>, "body": <str>, "labels": <str>,
#    "fingerprint": <str>, "source": <str>}
#
# Titles and bodies routinely contain quotes and newlines; every field is
# encoded with python3 json.dumps so the on-the-wire JSONL stays valid and
# survives the read-modify-write round trip.
#
# Storage: a single agentis memo key holds the whole JSONL blob. Default
# `issue_creator:candidates`, overridable via CANDIDATE_QUEUE_KEY. Append is
# a read-modify-write against that one key.
#
# Dependencies: bash + python3 + the `agentis memo get/set` CLI. Nothing else.
#
# Usage: source this file, then:
#   candidate_queue_append "<title>" "<body>" "<labels>" "<fingerprint>" "<source>"
#   candidate_queue_read   # prints the stored JSONL to stdout

CANDIDATE_QUEUE_KEY="${CANDIDATE_QUEUE_KEY:-issue_creator:candidates}"

# candidate_queue_read: print all stored records (the raw JSONL) to stdout.
# Empty/unset key prints nothing. Command substitution callers get a blob
# with trailing newlines stripped, which is exactly what append wants.
candidate_queue_read() {
    agentis memo get "$CANDIDATE_QUEUE_KEY" 2>/dev/null || true
}

# candidate_queue_append <title> <body> <labels> <fingerprint> <source>
# Encode one JSONL record (fields passed through the environment so no shell
# quoting can break json.dumps' safe encoding) and append it to the queue.
candidate_queue_append() {
    local line existing updated
    line="$(CQ_TITLE="${1-}" CQ_BODY="${2-}" CQ_LABELS="${3-}" \
            CQ_FP="${4-}" CQ_SRC="${5-}" python3 -c '
import json, os
print(json.dumps({
    "title":       os.environ.get("CQ_TITLE", ""),
    "body":        os.environ.get("CQ_BODY", ""),
    "labels":      os.environ.get("CQ_LABELS", ""),
    "fingerprint": os.environ.get("CQ_FP", ""),
    "source":      os.environ.get("CQ_SRC", ""),
}, ensure_ascii=False))
')" || return 1

    existing="$(candidate_queue_read)"
    if [ -n "$existing" ]; then
        updated="$existing
$line"
    else
        updated="$line"
    fi

    agentis memo set "$CANDIDATE_QUEUE_KEY" "$updated"
}
