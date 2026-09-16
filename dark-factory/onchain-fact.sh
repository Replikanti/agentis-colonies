#!/usr/bin/env bash
# onchain-fact.sh — read an ON-CHAIN value instead of remembering it, deterministically and with NO LLM
# anywhere (#2235, PR C of the external-protocol-reading capability).
#
# WHY
#   PR A/B gave a discovery cell a way to READ external SOURCE. A second class of dismissal does not turn on
#   source at all but on DEPLOYED STATE: "that cap is set to zero", "that role is the timelock", "that rate is
#   one-to-one right now". A cell can neither see nor invent those, so it confabulates or answers UNRESOLVED.
#   This is the missing second verb: one bounded `cast call` against an operator-configured endpoint, whose
#   RESULT is written into the same external cache — so a citation of that value is RE-OPENABLE by the
#   harness from disk, never re-fetched from the network.
#
# THE ENDPOINT IS THE OPERATOR'S, NEVER THE CALLER'S. There is no flag that takes an RPC URL or a host: the
# endpoint is read from DF_EXTERNAL_RPC, then FORK_URL, then ETH_RPC_URL (the same precedence
# resolve-external.sh uses for the ERC-1967 slot read), and it must look like an http(s) URL. With NONE of
# them set the call is NOT made and the answer is `unavailable|no-rpc` — an honest null. A check that rests
# on an `unavailable` line is UNRESOLVED, never CLEAN (issue #2235 STOP-1 decision 4).
#
# INPUTS ARE AN ADDRESS + A SIGNATURE (+ optional plain arguments). The ADDRESS is one the audited payload or
# resolve-external.sh already names — this script never discovers, guesses or accepts a host, and anything
# carrying a shell metacharacter, a scheme or a path fails validation (`bad-input`, exit 2).
#
# OUTPUT — exactly one line on stdout, nothing else (diagnostics go to stderr):
#   ONCHAIN|<chain>:<address>:<selector>|<result>|<block>
#   ONCHAIN|<chain>:<address>:<selector>|unavailable|<reason>
#   reasons (CLOSED vocabulary):
#     no-rpc            no endpoint is configured (or --offline), so nothing was read
#     no-cast           `cast` is not on PATH, so nothing was read
#     revert            the endpoint answered with a revert / an empty result
#     budget-exhausted  --budget-state already spent DF_ONCHAIN_BUDGET calls for this cell
#     bad-input         the input is not an address + a signature (exit 2)
#
# CACHE — key = (chain, address, calldata, block), under the SAME external cache root PR A writes:
#   <cache>/onchain/<chain>/<address>/<block>/<sha256-of-calldata>.tsv
#   one record: <call-id> \t <sig> \t <args> \t <result> \t <block> \t <fetched-at>
# A cache hit costs NO budget and touches NO network — and it is what the harness re-opens: run-discovery.sh
# accepts an `ONCHAIN` citation only when a cached record for that call id and block carries exactly the
# cited result.
#
# Usage:
#   onchain-fact.sh --address 0x.. --sig "<name>(<argtypes>)(<returntypes>)" [--chain <id>] [--args "<a> <b>"]
#                   [--block <n>] [--cache-dir <dir>] [--budget-state <file>] [--offline]
#
# Exit: 0 on any answer OR any refusal (a cell is never derailed); 2 on bad input ONLY.
#
# Offline proof: dark-factory/demo-resolve-cell.sh (canned cache entry, no-rpc, budget, gate — zero network).
#
# PORTABILITY: the directive tells a cell to run this with `sh`, so the body stays POSIX — no `pipefail`, no
# herestring, no `[[`. On a host whose /bin/sh is dash, a bash-only line here would make every invocation exit
# 2 with NO output, which a cell would read as "the tool is broken", not as "the fact is unavailable".
set -u

BUDGET="${DF_ONCHAIN_BUDGET:-5}"          # calls allowed against --budget-state, per CELL
case "$BUDGET" in ''|*[!0-9]*) BUDGET=5 ;; esac
MAX_ARGS=8                                # a bounded verb: more than this is a script, not a fact check

nv() { [ "$1" -ge 2 ] || { echo "onchain-fact.sh: $2 requires a value" >&2; exit 2; }; }

ADDRESS="" ; SIG="" ; CHAIN="1" ; ARGS="" ; BLOCK="" ; CACHE_DIR="" ; BUDGET_STATE="" ; OFFLINE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --address)      nv "$#" "$1"; ADDRESS="$2"; shift 2 ;;
        --sig)          nv "$#" "$1"; SIG="$2"; shift 2 ;;
        --chain)        nv "$#" "$1"; CHAIN="$2"; shift 2 ;;
        --args)         nv "$#" "$1"; ARGS="$2"; shift 2 ;;
        --block)        nv "$#" "$1"; BLOCK="$2"; shift 2 ;;
        --cache-dir)    nv "$#" "$1"; CACHE_DIR="$2"; shift 2 ;;
        --budget-state) nv "$#" "$1"; BUDGET_STATE="$2"; shift 2 ;;
        --offline)      OFFLINE=1; shift ;;
        -h|--help)      sed -n '2,45p' "$0"; exit 0 ;;
        *)              echo "onchain-fact.sh: unknown arg $1" >&2
                        echo 'ONCHAIN|?|unavailable|bad-input'; exit 2 ;;
    esac
done

# ----------------------------------------------------------------------------------------------------------
# Input validation. An address is 40 hex nibbles; a signature is `name(argtypes)` optionally followed by
# `(returntypes)`; an argument is a plain value (hex word, decimal, boolean or identifier). Nothing else is
# accepted — in particular nothing carrying a scheme, a slash, a quote or a shell metacharacter, so neither a
# URL nor a command can reach the `cast` invocation. On refusal the input is NOT echoed back (it may be
# arbitrary bytes), so the one stdout line stays inside the grammar.
# ----------------------------------------------------------------------------------------------------------
bad_input() { echo "onchain-fact.sh: $1" >&2; echo 'ONCHAIN|?|unavailable|bad-input'; exit 2; }

[ -n "$ADDRESS" ] || bad_input "--address 0x<40 hex> is required"
[ -n "$SIG" ] || bad_input "--sig '<name>(<argtypes>)(<returntypes>)' is required"
[ "${#SIG}" -le 128 ] || bad_input "--sig is longer than 128 characters"
echo "$ADDRESS" | grep -qE '^0x[0-9a-fA-F]{40}$' || bad_input "--address must be 0x + 40 hex digits"
echo "$CHAIN" | grep -qE '^[0-9]{1,10}$' || bad_input "--chain must be a decimal chain id"
# The `]` sits FIRST inside each bracket expression on purpose: that is the only portable way to include a
# literal `]`, and a backslash inside a bracket expression is a literal backslash, not an escape.
echo "$SIG" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*\([]A-Za-z0-9_,[ ]*\)(\([]A-Za-z0-9_,[ ]*\))?$' \
    || bad_input "--sig '$SIG' is not a function signature (a URL, a path or a command is never accepted)"
case "$BLOCK" in '') ;; *[!0-9]*) bad_input "--block must be a whole number" ;; esac

# Arguments: split on whitespace, validate each, cap the count. The validated list is what is word-split into
# the `cast` command line below — nothing else ever is.
ARG_N=0
for _a in $ARGS; do
    echo "$_a" | grep -qE '^(0[xX][0-9a-fA-F]+|[0-9]+|true|false|[A-Za-z_][A-Za-z0-9_.-]*)$' \
        || bad_input "--args value '$_a' is not a plain address/number/boolean/identifier"
    ARG_N=$((ARG_N + 1))
done
[ "$ARG_N" -le "$MAX_ARGS" ] || bad_input "--args carries more than $MAX_ARGS values"

# Canonical forms. The address is LOWERCASED everywhere (cache path, call id, the emitted line), so a
# checksummed and a lowercase spelling of the same address can never produce two cache entries or two call
# ids the harness would then fail to match.
ADDR_LC="$(printf '%s' "$ADDRESS" | tr 'A-F' 'a-f')"
# The SELECTOR is the signature up to and including its first `)` — the name and the argument types, with
# whitespace removed. The return types are a decoding hint, not part of the call's identity.
SELECTOR="$(printf '%s' "${SIG%%)*})" | tr -d ' ')"
# The CALLDATA IDENTITY: the selector plus the actual arguments. Two calls with the same selector and
# different arguments are different facts and get different cache entries.
ARGS_CANON="$(printf '%s' "$ARGS" | tr -s ' \t' ' ' | sed -e 's/^ //' -e 's/ $//')"
CALLDATA="$SELECTOR($ARGS_CANON)"
CALL_ID="$CHAIN:$ADDR_LC:$SELECTOR"

CACHE="${CACHE_DIR:-${DARK_FACTORY_DIR:-$HOME/.dark-factory}/external}"
mkdir -p "$CACHE" 2>/dev/null || true

log() { echo "onchain-fact: $*" >&2; }

emit_value() { # $1=result $2=block
    printf 'ONCHAIN|%s|%s|%s\n' "$CALL_ID" "$1" "$2"
    exit 0
}
emit_unavailable() { # $1=reason
    printf 'ONCHAIN|%s|unavailable|%s\n' "$CALL_ID" "$1"
    exit 0
}

# sha256 of a string. posix-portability: deferred (guarded pair — sha256sum on GNU, shasum -a 256 on BSD).
# The fallback is driven by an EMPTY result rather than by the pipeline's exit status: without `pipefail` a
# failing first stage still leaves `cut` successful, so only the value itself can tell the two apart.
str_sha() {
    # posix-portability: deferred (guarded pair — the shasum -a 256 fallback is the next line)
    _s="$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -d' ' -f1)"
    [ -n "$_s" ] || _s="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -d' ' -f1)"
    printf '%s' "${_s:-nosha}"
}
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ----------------------------------------------------------------------------------------------------------
# The endpoint. OPERATOR-CONFIGURED ONLY (see the header): no flag takes one, and the value is never printed,
# never cached and never quoted into anything the model sees — an RPC URL routinely carries an API key.
# ----------------------------------------------------------------------------------------------------------
RPC="${DF_EXTERNAL_RPC:-${FORK_URL:-${ETH_RPC_URL:-}}}"
case "$RPC" in
    '') ;;
    http://*|https://*) ;;
    # Same shape check as run-invariant-hunt.sh's --fork-url. A malformed endpoint is treated as NO endpoint
    # rather than passed to `cast`: the answer is then an honest `no-rpc`, never a silent CLEAN.
    *) log "the configured endpoint is not an http(s) URL — treating it as absent"; RPC="" ;;
esac
[ "$OFFLINE" -eq 1 ] && RPC=""

# ----------------------------------------------------------------------------------------------------------
# Call budget. Only a call that actually leaves the host counts; a cache hit is free. With no --budget-state
# there is nothing to count ACROSS invocations, so a single invocation still spends at most BUDGET calls but
# the cell-level bound is the caller's to pass in (run-discovery.sh does).
# ----------------------------------------------------------------------------------------------------------
BUDGET_SPENT=0
budget_used() {
    if [ -n "$BUDGET_STATE" ] && [ -f "$BUDGET_STATE" ]; then
        _u="$(head -n 1 "$BUDGET_STATE" 2>/dev/null | tr -cd '0-9')"
        echo "${_u:-0}"
    else
        echo "$BUDGET_SPENT"
    fi
}
budget_take() { # 0 = a call may be made (and was charged), 1 = exhausted
    _u="$(budget_used)"
    if [ "$_u" -ge "$BUDGET" ]; then return 1; fi
    BUDGET_SPENT=$((_u + 1))
    if [ -n "$BUDGET_STATE" ]; then
        mkdir -p "$(dirname "$BUDGET_STATE")" 2>/dev/null || true
        echo "$BUDGET_SPENT" > "$BUDGET_STATE" 2>/dev/null || true
    fi
    return 0
}

# ----------------------------------------------------------------------------------------------------------
# The two `cast` seams. Both are replaced by canned readers in demo-resolve-cell.sh, so the self-test
# exercises the REAL cache/budget/grammar code with zero network and no foundry. Every value the command line
# interpolates has been validated above; the endpoint is passed through the environment, never through argv,
# so it cannot end up in a process listing the driven session can read.
# ----------------------------------------------------------------------------------------------------------
DF_CAST_CMD_DEFAULT='cast call --rpc-url "$CAST_RPC" ${CAST_BLOCK:+--block "$CAST_BLOCK"} "$CAST_ADDRESS" "$CAST_SIG" $CAST_ARGS'
DF_CAST_BLOCK_CMD_DEFAULT='cast block-number --rpc-url "$CAST_RPC"'

have_cast() {
    # An overridden seam is its own proof of availability (the demo has no foundry).
    [ -n "${DF_CAST_CMD:-}" ] && return 0
    command -v cast >/dev/null 2>&1
}

# Squeeze a `cast` answer into ONE grammar-safe field: newlines and tabs become spaces, `|` can never appear
# (it would split the emitted record), and foundry's scientific annotation (`123 [1.23e2]`) is dropped so the
# value the model cites is the value the cache holds.
clean_result() {
    printf '%s' "$1" | tr '\n\t|' '   ' | sed -e 's/\[[^]]*\]//g' -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# ----------------------------------------------------------------------------------------------------------
# The BLOCK. The cache key requires one, so it is pinned: --block wins, then FORK_BLOCK (the operator's
# pinned fork block), then one `cast block-number` per CELL — memoised next to the budget state, so every
# call of a cell keys on the SAME block and a cited value can always be found again. Pinning is overhead, not
# a fact read, so it is not charged to the call budget; it does require an endpoint.
# ----------------------------------------------------------------------------------------------------------
pin_block() {
    if [ -n "$BLOCK" ]; then printf '%s\n' "$BLOCK"; return 0; fi
    case "${FORK_BLOCK:-}" in
        ''|*[!0-9]*) : ;;
        *) printf '%s\n' "$FORK_BLOCK"; return 0 ;;
    esac
    pb_memo=""
    if [ -n "$BUDGET_STATE" ]; then pb_memo="$BUDGET_STATE.block-$CHAIN"; fi
    if [ -n "$pb_memo" ] && [ -f "$pb_memo" ]; then
        pb_v="$(head -n 1 "$pb_memo" 2>/dev/null | tr -cd '0-9')"
        if [ -n "$pb_v" ]; then printf '%s\n' "$pb_v"; return 0; fi
    fi
    [ -n "$RPC" ] || return 1
    pb_out="$(CAST_RPC="$RPC" sh -c "${DF_CAST_BLOCK_CMD:-$DF_CAST_BLOCK_CMD_DEFAULT}" 2>/dev/null | tr -cd '0-9')"
    [ -n "$pb_out" ] || return 1
    if [ -n "$pb_memo" ]; then
        mkdir -p "$(dirname "$pb_memo")" 2>/dev/null || true
        echo "$pb_out" > "$pb_memo" 2>/dev/null || true
    fi
    printf '%s\n' "$pb_out"
}

PINNED="$(pin_block)" || PINNED=""
if [ -z "$PINNED" ]; then
    # No block and no way to learn one: nothing can be keyed, so nothing was read.
    log "no block could be pinned (no --block, no FORK_BLOCK, no endpoint that answered)"
    emit_unavailable no-rpc
fi

# ----------------------------------------------------------------------------------------------------------
# CACHE FIRST — this is also the only path an RPC-less host can answer on, which is exactly what makes the
# harness able to re-open a citation without a network.
# ----------------------------------------------------------------------------------------------------------
REC_DIR="$CACHE/onchain/$CHAIN/$ADDR_LC/$PINNED"
REC="$REC_DIR/$(str_sha "$CALLDATA").tsv"
if [ -f "$REC" ]; then
    C_RESULT="$(cut -f4 "$REC" 2>/dev/null | head -n 1)"
    if [ -n "$C_RESULT" ]; then
        log "cache hit for $CALL_ID @$PINNED (no call made)"
        emit_value "$C_RESULT" "$PINNED"
    fi
fi

# ----------------------------------------------------------------------------------------------------------
# THE CALL. Everything below is refusal-first: no endpoint, no `cast`, no budget => one `unavailable` line
# and exit 0. A cell is never derailed, and an `unavailable` answer is never evidence of anything.
# ----------------------------------------------------------------------------------------------------------
[ -n "$RPC" ] || emit_unavailable no-rpc
have_cast || emit_unavailable no-cast
budget_take || { log "call budget of $BUDGET is spent for this cell"; emit_unavailable budget-exhausted; }

# shellcheck disable=SC2086  # $ARGS is the VALIDATED argument list and is deliberately word-split
RAW="$(CAST_RPC="$RPC" CAST_ADDRESS="$ADDRESS" CAST_SIG="$SIG" CAST_ARGS="$ARGS_CANON" CAST_BLOCK="$PINNED" \
    sh -c "${DF_CAST_CMD:-$DF_CAST_CMD_DEFAULT}" 2>/dev/null)"
RESULT="$(clean_result "$RAW")"
[ -n "$RESULT" ] || emit_unavailable revert

mkdir -p "$REC_DIR" 2>/dev/null || true
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$CALL_ID" "$SIG" "$ARGS_CANON" "$RESULT" "$PINNED" "$(now_iso)" \
    > "$REC" 2>/dev/null || log "could not write the cache record at $REC (the citation will not re-open)"
emit_value "$RESULT" "$PINNED"
