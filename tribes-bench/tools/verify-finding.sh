#!/bin/bash
# verify-finding.sh: deterministic verifier for tribes-bench Stages 0/1.
#
# Reads a JSON finding object on stdin (`{"line": <int>, "rationale": <string>,
# "class": <string|optional>}`) and emits a verdict on stdout
# (`{"verified": <bool>, "bug_id": <string|null>}`).
#
# Verification rule: a finding matches a planted bug iff
#   |finding.line - bug.line| <= bug.line_tolerance
# AND the source slice at the planted line contains bug.signature
# AND (when finding.class is set) bug.class == finding.class.
#
# Stage 0 wire format does not include `class` — Stage 0 inputs keep the
# Stage 0 (line, signature) predicate unchanged. Stage 1 inputs include
# `class` and additionally require the manifest entry's `class` field
# match. Note: Stage 0's `bugs.json` uses `class = "command-injection"`
# (hyphen) and Stage 1 standardises on `class = "command_injection"`
# (underscore) — they never collide because Stage 0 never sends `class`
# on the wire.
#
# Pure shell + jq + grep — no LLM, no agentis. The verifier is the source
# of ground truth for Stages 0/1 telemetry; do not call into prompt() here.
#
# Env (with sane defaults relative to the federation directory):
#   TARGET_DIR      (default: <fed>/targets/stage0)
#   BUGS_MANIFEST   (default: $TARGET_DIR/bugs.json)
#
# CLI flags (all optional; stdin JSON remains the primary input channel):
#   --help, -h           Print usage and exit 0.
#   --class <CLASS>      Override `class` field if absent on stdin (Stage 1
#                        smoke testing). When set, requires bug.class match.
#   --bug-id <ID>        When set, additionally require the matched bug's id
#                        equals <ID> (Stage 1 smoke testing).
#
# Exit codes: 0 always (the verdict goes on stdout). The script never
# fails the caller — a malformed input emits {"verified": false,
# "bug_id": null} so downstream telemetry can still classify the row as
# a false positive.

set -e

print_help() {
    cat <<'EOF'
Usage: verify-finding.sh [--class <CLASS>] [--bug-id <ID>]

Reads a JSON finding from stdin and emits a JSON verdict on stdout.

Stdin: {"line": <int>, "class": <string|optional>}
Stdout: {"verified": <bool>, "bug_id": <string|null>}

Env:
  TARGET_DIR     default: <fed>/targets/stage0
  BUGS_MANIFEST  default: $TARGET_DIR/bugs.json

Flags (Stage 1 smoke testing; back-compat default = Stage 0 behaviour):
  --class <CLASS>   Provide class when stdin omits it.
  --bug-id <ID>     Require the matched bug.id equals <ID>.
  --help, -h        Print this help and exit 0.
EOF
}

CLI_CLASS=""
CLI_BUG_ID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            print_help
            exit 0
            ;;
        --class)
            if [ -z "${2:-}" ]; then
                echo "verify-finding.sh: --class requires an argument" >&2
                exit 0
            fi
            CLI_CLASS="$2"
            shift 2
            ;;
        --bug-id)
            if [ -z "${2:-}" ]; then
                echo "verify-finding.sh: --bug-id requires an argument" >&2
                exit 0
            fi
            CLI_BUG_ID="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "verify-finding.sh: unknown flag: $1" >&2
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

TARGET_DIR="${TARGET_DIR:-$FED_DIR/targets/stage0}"

# #561 rotation layer-2: prefer hunter:bugs_manifest memo (set by orchestrator
# rotation timer post-#547) over env var. Memo > env > hardcoded default chain.
# Backward compatible: deployments without memo writes fall back to env behavior.
ROTATED_MANIFEST=$(agentis memo get hunter:bugs_manifest 2>/dev/null | python3 -c 'import sys,json; data=sys.stdin.read().strip(); print(json.loads(data) if data.startswith(chr(34)) else data)' 2>/dev/null)
ROTATED_DIR=$(agentis memo get hunter:target_dir 2>/dev/null | python3 -c 'import sys,json; data=sys.stdin.read().strip(); print(json.loads(data) if data.startswith(chr(34)) else data)' 2>/dev/null)

if [ -n "$ROTATED_DIR" ] && [ -d "$ROTATED_DIR" ]; then
    TARGET_DIR="$ROTATED_DIR"
fi
if [ -n "$ROTATED_MANIFEST" ] && [ -f "$ROTATED_MANIFEST" ]; then
    BUGS_MANIFEST="$ROTATED_MANIFEST"
fi

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

# Read optional class field. Empty == "any class accepted" (Stage 0 path).
# CLI --class overrides only when stdin omits the field.
FINDING_CLASS="$(printf '%s' "$INPUT" | jq -r '.class // empty' 2>/dev/null || true)"
if [ -z "$FINDING_CLASS" ] && [ -n "$CLI_CLASS" ]; then
    FINDING_CLASS="$CLI_CLASS"
fi

# Iterate planted bugs. For each, check the line-window predicate first
# (cheap), then confirm the signature substring is present at the
# planted line in the source file. When class is set, additionally
# require manifest bug.class match.
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

    # Class predicate: only enforced when finding.class is set. Stage 0
    # inputs keep the Stage 0 line+signature predicate unchanged.
    if [ -n "$FINDING_CLASS" ]; then
        BUG_CLASS="$(jq -r ".bugs[$i].class // \"\"" "$BUGS_MANIFEST")"
        if [ "$BUG_CLASS" != "$FINDING_CLASS" ]; then
            i=$((i + 1))
            continue
        fi
    fi

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
        # Bug-id predicate: when --bug-id is set, additionally require
        # the matched bug's id equals it.
        if [ -n "$CLI_BUG_ID" ] && [ "$BUG_ID" != "$CLI_BUG_ID" ]; then
            i=$((i + 1))
            continue
        fi
        emit_verdict "true" "$BUG_ID"
        exit 0
    fi

    i=$((i + 1))
done

emit_verdict "false" ""
