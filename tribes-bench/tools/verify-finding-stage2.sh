#!/bin/bash
# verify-finding-stage2.sh: deterministic verifier for tribes-bench Stage 2.
#
# Distinct file from `verify-finding.sh` (the Stage 0/1 verifier) so the
# Stage 0/1 surface stays byte-identical — Stage 2 ships its own copy with
# its own default TARGET_DIR + BUGS_MANIFEST. The dispatch logic is the
# same: line-window match against bugs.json + class equality + signature
# substring.
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
# Stage 2 introduces a wider class palette than Stages 0/1. Recognised
# class strings on the wire (matched against bugs.json `class` field):
#   use_after_free, uninitialised_memory, memory_corruption,
#   heap_overflow, data_race, send_violation, missing_lock,
#   dangling_borrow.
# Stages 0/1 strings (command_injection, path_traversal, format_string)
# remain valid for forward-compat — class matching is a literal string
# equality test against the manifest, not a closed enum.
#
# Pure shell + jq + grep — no LLM, no agentis. The verifier is the source
# of ground truth for Stage 2 telemetry; do not call into prompt() here.
#
# Env (with sane defaults relative to the federation directory):
#   TARGET_DIR              (default: <fed>/targets/stage2/smallvec-v0.6.13)
#   BUGS_MANIFEST           (default: <fed>/targets/stage2/bugs.json)
#   BUG_LEDGER_PATH         (optional: when set, the verifier appends a
#                            row to this file on every verified=true
#                            path. Closes #491 -- hunters no longer write
#                            the ledger directly via `exec sh ... >>`.
#                            Stage 0/1 callers omit this env and see no
#                            behaviour change.)
#   TRIBE_NAME              (required when BUG_LEDGER_PATH is set: tribe
#                            identity stamped on the ledger row + used
#                            for the first-finder check.)
#   LEDGER_REWARD_FULL      (default: 200; reward for first-finder)
#   LEDGER_REWARD_SUBSEQUENT (default: 50; reward for re-finders)
#
# Linux-only concurrency note: when BUG_LEDGER_PATH is set, append uses
# `flock -x` (util-linux) on `${BUG_LEDGER_PATH}.lock` so concurrent
# tribes do not interleave bytes. Stage 3 runs Ubuntu 24.04 in container
# so util-linux is present; on macOS the verifier falls back to a plain
# `>>` append (the gameable-channel risk is the issue, not the
# concurrency one).
#
# Schema invariant: the appended row is byte-identical to the row
# previously emitted by hunter.ag, namely
#   {"ts": <ms>, "tribe": "<name>", "bug_id": "<id>", "reward": <int>}
# with `ts` from `date +%s%3N`. analyse-stage3.py and downstream
# consumers see no schema change.
#
# CLI flags (all optional; stdin JSON remains the primary input channel):
#   --help, -h           Print usage and exit 0.
#   --class <CLASS>      Override `class` field if absent on stdin.
#                        When set, requires bug.class match.
#   --bug-id <ID>        When set, additionally require the matched bug's
#                        id equals <ID>.
#
# Exit codes: 0 always (the verdict goes on stdout). The script never
# fails the caller — a malformed input emits {"verified": false,
# "bug_id": null} so downstream telemetry can still classify the row as
# a false positive.

set -e

print_help() {
    printf '%s\n' \
        'Usage: verify-finding-stage2.sh [--class <CLASS>] [--bug-id <ID>]' \
        '' \
        'Reads a JSON finding from stdin and emits a JSON verdict on stdout.' \
        '' \
        'Stdin: {"line": <int>, "class": <string|optional>}' \
        'Stdout: {"verified": <bool>, "bug_id": <string|null>}' \
        '' \
        'Env:' \
        '  TARGET_DIR     default: <fed>/targets/stage2/smallvec-v0.6.13' \
        '  BUGS_MANIFEST  default: <fed>/targets/stage2/bugs.json' \
        '' \
        'Flags:' \
        '  --class <CLASS>   Provide class when stdin omits it.' \
        '  --bug-id <ID>     Require the matched bug.id equals <ID>.' \
        '  --help, -h        Print this help and exit 0.'
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
                echo "verify-finding-stage2.sh: --class requires an argument" >&2
                exit 0
            fi
            CLI_CLASS="$2"
            shift 2
            ;;
        --bug-id)
            if [ -z "${2:-}" ]; then
                echo "verify-finding-stage2.sh: --bug-id requires an argument" >&2
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
            echo "verify-finding-stage2.sh: unknown flag: $1" >&2
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

TARGET_DIR="${TARGET_DIR:-$FED_DIR/targets/stage2/smallvec-v0.6.13}"
BUGS_MANIFEST="${BUGS_MANIFEST:-$FED_DIR/targets/stage2/bugs.json}"
BUG_LEDGER_PATH="${BUG_LEDGER_PATH:-}"
TRIBE_NAME="${TRIBE_NAME:-}"
LEDGER_REWARD_FULL="${LEDGER_REWARD_FULL:-200}"
LEDGER_REWARD_SUBSEQUENT="${LEDGER_REWARD_SUBSEQUENT:-50}"

emit_verdict() {
    # $1: "true" | "false"
    # $2: bug_id (empty for null)
    if [ -n "$2" ]; then
        printf '{"verified": %s, "bug_id": "%s"}\n' "$1" "$2"
    else
        printf '{"verified": %s, "bug_id": null}\n' "$1"
    fi
}

ts_ms() {
    # GNU date %N supports millisecond precision on Linux; if unavailable
    # (BSD date on macOS), fall back to python3 which the Stage 3 base
    # image always ships.
    local out
    out="$(date +%s%3N 2>/dev/null || true)"
    case "$out" in
        ''|*N*)
            python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0
            ;;
        *)
            printf '%s\n' "$out"
            ;;
    esac
}

append_ledger_row() {
    # $1: bug_id (non-empty on the verified=true path)
    # No-op when BUG_LEDGER_PATH or TRIBE_NAME is empty so Stage 0/1
    # callers and unit-tests without ledger plumbing keep working.
    local bug_id="$1"
    if [ -z "$BUG_LEDGER_PATH" ] || [ -z "$TRIBE_NAME" ] || [ -z "$bug_id" ]; then
        return 0
    fi

    # First-finder check: grep the ledger for any prior row that already
    # claimed this bug_id. If absent OR the first claim is by this same
    # tribe (idempotent re-find within the tribe), reward is the FULL
    # bounty; otherwise the SUBSEQUENT discount applies.
    local reward="$LEDGER_REWARD_FULL"
    if [ -f "$BUG_LEDGER_PATH" ]; then
        local prior
        prior="$(grep -F "\"bug_id\": \"$bug_id\"" "$BUG_LEDGER_PATH" 2>/dev/null | head -1 || true)"
        if [ -n "$prior" ]; then
            if printf '%s' "$prior" | grep -qF "\"tribe\": \"$TRIBE_NAME\""; then
                reward="$LEDGER_REWARD_FULL"
            else
                reward="$LEDGER_REWARD_SUBSEQUENT"
            fi
        fi
    fi

    local ts
    ts="$(ts_ms)"
    local row
    row="$(printf '{"ts": %s, "tribe": "%s", "bug_id": "%s", "reward": %s}' \
        "$ts" "$TRIBE_NAME" "$bug_id" "$reward")"

    # flock -x on a sibling .lock file so concurrent tribes do not
    # interleave bytes mid-append. Falls back to a plain `>>` when
    # flock(1) is missing (BSD / macOS).
    if command -v flock >/dev/null 2>&1; then
        (
            flock -x 9
            printf '%s\n' "$row" >>"$BUG_LEDGER_PATH"
        ) 9>>"${BUG_LEDGER_PATH}.lock"
    else
        printf '%s\n' "$row" >>"$BUG_LEDGER_PATH"
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

# Read optional class field. Empty == "any class accepted" (Stage 0
# back-compat). CLI --class overrides only when stdin omits the field.
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

    # Class predicate: only enforced when finding.class is set.
    # #531: when STAGE3_VERIFIER_CLASS_ALIASES is "1" (default), a
    # finding.class in the same alias group as bug.class also matches.
    # Alias groups capture LLM-naming ambiguities the M98 v3 take-4
    # smoke surfaced — heap_overflow described as memory_corruption,
    # use_after_free as dangling_borrow, data_race as missing_lock.
    # Set STAGE3_VERIFIER_CLASS_ALIASES=0 for strict matching.
    if [ -n "$FINDING_CLASS" ]; then
        BUG_CLASS="$(jq -r ".bugs[$i].class // \"\"" "$BUGS_MANIFEST")"
        if [ "$BUG_CLASS" != "$FINDING_CLASS" ]; then
            ALIAS_MODE="${STAGE3_VERIFIER_CLASS_ALIASES:-1}"
            CLASS_MATCH=0
            if [ "$ALIAS_MODE" = "1" ]; then
                case "$BUG_CLASS" in
                    heap_overflow|memory_corruption|buffer_overflow)
                        case "$FINDING_CLASS" in
                            heap_overflow|memory_corruption|buffer_overflow) CLASS_MATCH=1 ;;
                        esac
                        ;;
                    use_after_free|dangling_borrow)
                        case "$FINDING_CLASS" in
                            use_after_free|dangling_borrow) CLASS_MATCH=1 ;;
                        esac
                        ;;
                    data_race|missing_lock)
                        case "$FINDING_CLASS" in
                            data_race|missing_lock) CLASS_MATCH=1 ;;
                        esac
                        ;;
                esac
            fi
            if [ "$CLASS_MATCH" -eq 0 ]; then
                i=$((i + 1))
                continue
            fi
            # Aliased match — log to stderr so post-mortems can
            # distinguish strict vs aliased verifications without
            # changing the JSON verdict shape on stdout.
            echo "verify-finding-stage2: aliased class match: bug.class=$BUG_CLASS finding.class=$FINDING_CLASS bug_id=$(jq -r ".bugs[$i].id" "$BUGS_MANIFEST")" >&2
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
        append_ledger_row "$BUG_ID"
        emit_verdict "true" "$BUG_ID"
        exit 0
    fi

    i=$((i + 1))
done

emit_verdict "false" ""
