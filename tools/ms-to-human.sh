#!/usr/bin/env sh
# tools/ms-to-human.sh (#1246): format a millisecond duration as a compact
# human-readable string using integer (floor-division) math only -- no decimals.
#
#   Input range (ms)         Output      Example
#   < 1000                   <N>ms       500     -> 500ms
#   >= 1000,    < 60000      <S>s        2000    -> 2s
#   >= 60000,   < 3600000    <M>m<S>s    90000   -> 1m30s
#   >= 3600000               <H>h<M>m    5400000 -> 1h30m
#
# S / M are the *remainder* seconds / minutes: 90000 -> 1 minute 30 seconds ->
# 1m30s; 5400000 -> 1 hour 30 minutes -> 1h30m.
#
# $1 is a non-negative integer count of milliseconds. Any missing, empty,
# negative, or non-integer input prints "0ms" and exits 0 -- the helper is
# total and never crashes. POSIX sh, dash-safe: no bashisms, no printf '\xNN'.
set -eu

ms="${1:-}"

# Guard: accept only a non-empty run of ASCII digits. This rejects the missing
# arg (empty), explicit empty string, negatives (the '-' is non-digit), and any
# non-integer (decimals, letters). Leading zeros are harmless to the math below.
case "$ms" in
    ''|*[!0-9]*)
        echo "0ms"
        exit 0
        ;;
esac

if [ "$ms" -lt 1000 ]; then
    echo "${ms}ms"
elif [ "$ms" -lt 60000 ]; then
    echo "$((ms / 1000))s"
elif [ "$ms" -lt 3600000 ]; then
    echo "$((ms / 60000))m$((ms / 1000 % 60))s"
else
    echo "$((ms / 3600000))h$((ms / 60000 % 60))m"
fi
