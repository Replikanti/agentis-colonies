#!/bin/sh
# cast-read.sh — the ONE place chain reads happen for the Monitor colony (#1098).
#
# A read-only / non-custodial wrapper around foundry `cast` that adds RPC FAILOVER
# (a list of endpoints, tried in order) and an optional READ CONSENSUS (require >=N
# endpoints to AGREE on the value before returning it) — so a single lying / lagging
# RPC node cannot drive a false `violated` verdict, and a flaky endpoint is not
# confused with an on-chain fact. Centralised here so the six watchers' read
# functions do NOT each re-implement failover; their `read_uint` / `read_view` /
# `read_slot` / `read_balance` call THIS instead of `cast` directly.
#
# READ-ONLY: only the read subcommands are permitted — `call`, `storage`,
# `balance`, `code`. Anything that signs or writes (`send`, `mktx`, `wallet`, ...)
# is REJECTED with a usage error. The wrapper holds no key, never writes the chain.
#
# Usage:
#   cast-read.sh [--to-dec] <subcommand> <args...>
#     <subcommand>  one of: call | storage | balance | code
#     --to-dec      pipe the read through `cast --to-dec` (decimal output); used by
#                   the watchers that compare integers. Omit for the raw 0x word
#                   (storage slots / owner addresses compare as hex).
#   examples:
#     cast-read.sh --to-dec call 0xVAULT 'totalSupply()'
#     cast-read.sh storage 0xPROXY 0x360894...d382bbc
#     cast-read.sh --to-dec balance 0xPOOL
#     cast-read.sh code 0xTARGET
#
# Environment (exported by scripts/start-colony.sh; add each to
# exec.env_passthrough in .agentis/config so the sandboxed `exec sh` can read it):
#   MONITOR_CAST         path to the `cast` binary (foundry). "" => no reader; the
#                        wrapper emits the no-read sentinel (empty + exit 3).
#   MONITOR_RPC_URLS     comma-separated list of RPC endpoints, tried IN ORDER on
#                        failure (the failover list). "" => fall back to the single
#                        MONITOR_RPC_URL.
#   MONITOR_RPC_URL      the single-endpoint fallback when MONITOR_RPC_URLS is unset.
#   MONITOR_RPC_CONSENSUS  read-consensus quorum. "" / 0 / 1 => first-success
#                        failover (no consensus). "1"-as-flag is treated as the
#                        default quorum 2; any integer N>=2 requires N endpoints to
#                        AGREE on the value before it is returned. On disagreement
#                        (or fewer than N endpoints could be read) the wrapper emits
#                        the no-read sentinel — a single node can NOT force a value.
#
# NO-READ SENTINEL: empty stdout + a non-zero exit (distinct from a real verdict).
#   exit 0  a value was read (printed on stdout)
#   exit 2  usage error (bad / missing / non-read subcommand)
#   exit 3  no reader configured (MONITOR_CAST or no endpoint at all)
#   exit 4  ALL endpoints failed, OR consensus could not be reached (no-read)
#
# POSIX sh / dash-safe: no bashisms, no arrays, no `\xHH` printf escapes. CI runs
# this under `sh` = dash. shellcheck-clean.

set -eu

TO_DEC=0
if [ "${1:-}" = "--to-dec" ]; then
    TO_DEC=1
    shift
fi

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "cast-read.sh: missing read subcommand (call|storage|balance|code)" >&2
    exit 2
fi
shift

# READ-ONLY allowlist: reject anything that is not a pure read subcommand. This is
# the non-custodial guard — `send` / `mktx` / `wallet` / any write can never run
# through this path even if a caller mis-wires an argument.
case "$SUBCMD" in
    call|storage|balance|code) ;;
    *)
        echo "cast-read.sh: '$SUBCMD' is not a read subcommand (only call|storage|balance|code)" >&2
        exit 2
        ;;
esac

CAST="${MONITOR_CAST:-}"
if [ -z "$CAST" ]; then
    # No reader configured -> the no-read sentinel (empty + non-zero). The watcher
    # treats this exactly like a transient failure: no reading -> no false flag.
    exit 3
fi

# Build the endpoint list: MONITOR_RPC_URLS (comma-separated) wins; else the single
# MONITOR_RPC_URL. An empty list is the no-read sentinel.
RPCS="${MONITOR_RPC_URLS:-}"
if [ -z "$RPCS" ]; then
    RPCS="${MONITOR_RPC_URL:-}"
fi
if [ -z "$RPCS" ]; then
    exit 3
fi

# Consensus quorum. "" / 0 / 1 => no consensus (first-success failover). The flag
# value "1" is accepted as a shorthand for the default quorum of 2 (the issue's
# "MONITOR_RPC_CONSENSUS=1" form); any integer >= 2 is taken literally. A
# non-numeric value disables consensus.
CONSENSUS_RAW="${MONITOR_RPC_CONSENSUS:-}"
case "$CONSENSUS_RAW" in
    ''|*[!0-9]*) QUORUM=0 ;;
    *) QUORUM="$CONSENSUS_RAW" ;;
esac
if [ "$QUORUM" = "1" ]; then
    QUORUM=2
fi

# read_one <rpc> <cast-args...> — read the value from ONE endpoint, optionally
# decoded to decimal, normalised to a single comparable token. Echoes the value on
# success, NOTHING on failure (a miss). `set +e` + `2>/dev/null` so a transient RPC
# error is a clean miss, never an abort. Every dynamic value is quoted; the
# subcommand is the allowlisted token above, never untrusted text.
read_one() {
    _rpc="$1"
    shift
    set +e
    if [ "$TO_DEC" = "1" ]; then
        _val="$("$CAST" "$SUBCMD" --rpc-url "$_rpc" "$@" 2>/dev/null | "$CAST" --to-dec 2>/dev/null)"
    else
        _val="$("$CAST" "$SUBCMD" --rpc-url "$_rpc" "$@" 2>/dev/null)"
    fi
    set -e
    # First whitespace-free token only (cast appends a newline; some reads print
    # trailing metadata), lowercased for stable hex comparison.
    _tok="$(printf '%s' "$_val" | awk 'NR==1{print $1}')"
    printf '%s' "$_tok" | tr '[:upper:]' '[:lower:]'
}

if [ "$QUORUM" -ge 2 ]; then
    # --- consensus mode: require >= QUORUM endpoints to AGREE on the value -------
    # Read EVERY endpoint into a newline-delimited tally, then return the value (if
    # any) whose count reaches the quorum. On disagreement (no value reaches quorum)
    # or too few readable endpoints, emit the no-read sentinel — a single lying /
    # lagging node can NOT push a value past the quorum on its own.
    READINGS=""
    REST="$RPCS"
    while [ -n "$REST" ]; do
        RPC="${REST%%,*}"
        case "$REST" in
            *,*) REST="${REST#*,}" ;;
            *) REST="" ;;
        esac
        [ -n "$RPC" ] || continue
        VAL="$(read_one "$RPC" "$@")"
        [ -n "$VAL" ] || continue
        READINGS="$READINGS$VAL
"
    done
    if [ -z "$READINGS" ]; then
        exit 4
    fi
    # The most-agreed value + its count (sort|uniq -c, highest count first). awk
    # avoids relying on a fixed `uniq -c` column width across platforms.
    WINNER="$(printf '%s' "$READINGS" | sort | uniq -c | sort -rn | awk 'NR==1{$1=$1; print}')"
    WIN_CNT="${WINNER%% *}"
    WIN_VAL="${WINNER#* }"
    case "$WIN_CNT" in
        ''|*[!0-9]*) exit 4 ;;
    esac
    if [ "$WIN_CNT" -ge "$QUORUM" ]; then
        printf '%s\n' "$WIN_VAL"
        exit 0
    fi
    # No value reached the quorum -> no-read (disagreement or too few endpoints).
    exit 4
fi

# --- failover mode (no consensus): first endpoint to return a value wins --------
REST="$RPCS"
while [ -n "$REST" ]; do
    RPC="${REST%%,*}"
    case "$REST" in
        *,*) REST="${REST#*,}" ;;
        *) REST="" ;;
    esac
    [ -n "$RPC" ] || continue
    VAL="$(read_one "$RPC" "$@")"
    if [ -n "$VAL" ]; then
        printf '%s\n' "$VAL"
        exit 0
    fi
done

# Every endpoint failed -> the no-read sentinel (empty stdout + exit 4). Distinct
# from a real verdict: the watcher sees "" and stays quiet (no false flag).
exit 4
