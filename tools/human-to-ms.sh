#!/usr/bin/env sh
# tools/human-to-ms.sh (#1260): parse a compact human-readable duration string
# back into total integer milliseconds -- the inverse of tools/ms-to-human.sh.
#
# Accepts exactly the shapes ms-to-human.sh emits (and, generally, any sum of
# h/m/s/ms tokens):
#
#   Input     Output (ms)
#   500ms     500
#   2s        2000
#   1m30s     90000
#   1h30m     5400000
#   59s       59000
#   1m0s      60000
#   1h0m      3600000
#
# $1 is the duration string. Each <digits><unit> token contributes
# hours*3600000 + minutes*60000 + seconds*1000 + milliseconds, summed left to
# right. The `ms` suffix is matched before `m`, so 500ms is 500 milliseconds
# while 5m is 5 minutes (300000).
#
# Any missing, empty, or malformed input (a shape that does not fully tokenize
# into <digits>{h|m|s|ms} runs) prints "0" and exits 0 -- the helper is total
# and never crashes. POSIX sh, dash-safe: no bashisms, integer math only, no
# printf '\xNN'.
set -eu

rest="${1:-}"

total=0
ok=1

# Empty / missing input is not a valid duration -> fall through to "0".
[ -n "$rest" ] || ok=0

while [ -n "$rest" ]; do
    # Peel the leading run of ASCII digits. If the token does not start with a
    # digit, the input is malformed.
    digits="${rest%%[!0-9]*}"
    if [ -z "$digits" ]; then
        ok=0
        break
    fi
    rest="${rest#"$digits"}"

    # Strip leading zeros so $(( )) never sees an invalid octal literal such as
    # "08"; always keep at least one digit.
    while [ "${digits#0}" != "$digits" ] && [ "${#digits}" -gt 1 ]; do
        digits="${digits#0}"
    done

    # Classify the unit suffix and add its contribution. `ms` MUST be tested
    # before `m` so "500ms" is milliseconds, not minutes.
    case "$rest" in
        ms*) total=$((total + digits))          ; rest="${rest#ms}" ;;
        h*)  total=$((total + digits * 3600000)); rest="${rest#h}"  ;;
        m*)  total=$((total + digits * 60000))  ; rest="${rest#m}"  ;;
        s*)  total=$((total + digits * 1000))   ; rest="${rest#s}"  ;;
        *)   ok=0; break ;;
    esac
done

[ "$ok" -eq 1 ] || total=0

echo "$total"
