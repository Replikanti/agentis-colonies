#!/bin/bash
# verify-finding.sh: Stage 0 deterministic verifier for tribes-bench.
#
# Reads a JSON finding object on stdin (`{"line": <int>, "rationale": <string>}`)
# and emits a verdict on stdout (`{"verified": <bool>, "bug_id": <string|null>}`).
#
# Verification rule: a finding matches a planted bug iff
#   |finding.line - bug.line| <= bug.line_tolerance
# AND the source slice at the planted line contains bug.signature.
#
# Pure shell + jq + grep — no LLM, no agentis. The verifier is the source
# of ground truth for Stage 0 telemetry; do not call into prompt() here.
#
# Env (with sane defaults relative to the federation directory):
#   TARGET_DIR      (default: <fed>/targets/stage0)
#   BUGS_MANIFEST   (default: $TARGET_DIR/bugs.json)
#
# Exit codes: 0 always (the verdict goes on stdout). The script never
# fails the caller — a malformed input emits {"verified": false,
# "bug_id": null} so downstream telemetry can still classify the row as
# a false positive.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

TARGET_DIR="${TARGET_DIR:-$FED_DIR/targets/stage0}"
BUGS_MANIFEST="${BUGS_MANIFEST:-$TARGET_DIR/bugs.json}"

emit_verdict() {
    # $1: "true" | "false"
    # $2: bug_id (empty for null)
    if [ -n "$2" ]; then
        printf '{"verified": %s, "bug_id": "%s"}\n' "$1" "$2"
    else
        printf '{"verified": %s, "bug_id": null}\n' "$1"
    fi
}

if [ ! -f "$BUGS_MANIFEST" ]; then
    emit_verdict "false" ""
    exit 0
fi

INPUT="$(cat)"

FINDING_LINE="$(printf '%s' "$INPUT" | jq -r '.line // empty' 2>/dev/null || true)"
case "$FINDING_LINE" in
    ''|*[!0-9]*)
        emit_verdict "false" ""
        exit 0
        ;;
esac

# Iterate planted bugs. For each, check the line-window predicate first
# (cheap), then confirm the signature substring is present at the
# planted line in the source file.
BUG_COUNT="$(jq -r '.bugs | length' "$BUGS_MANIFEST" 2>/dev/null || echo 0)"
case "$BUG_COUNT" in
    ''|*[!0-9]*) BUG_COUNT=0 ;;
esac

i=0
while [ "$i" -lt "$BUG_COUNT" ]; do
    BUG_ID="$(jq -r ".bugs[$i].id" "$BUGS_MANIFEST")"
    BUG_FILE="$(jq -r ".bugs[$i].file" "$BUGS_MANIFEST")"
    BUG_LINE="$(jq -r ".bugs[$i].line" "$BUGS_MANIFEST")"
    BUG_TOL="$(jq -r ".bugs[$i].line_tolerance" "$BUGS_MANIFEST")"
    BUG_SIG="$(jq -r ".bugs[$i].signature" "$BUGS_MANIFEST")"

    # Line-window predicate: |finding - planted| <= tolerance.
    DIFF=$((FINDING_LINE - BUG_LINE))
    if [ "$DIFF" -lt 0 ]; then DIFF=$((-DIFF)); fi
    if [ "$DIFF" -gt "$BUG_TOL" ]; then
        i=$((i + 1))
        continue
    fi

    # Signature predicate: the source slice at the planted line must
    # contain the signature substring (literal grep, no regex).
    SRC="$TARGET_DIR/$BUG_FILE"
    if [ ! -f "$SRC" ]; then
        i=$((i + 1))
        continue
    fi
    LINE_TEXT="$(sed -n "${BUG_LINE}p" "$SRC")"
    if printf '%s' "$LINE_TEXT" | grep -qF -- "$BUG_SIG"; then
        emit_verdict "true" "$BUG_ID"
        exit 0
    fi

    i=$((i + 1))
done

emit_verdict "false" ""
