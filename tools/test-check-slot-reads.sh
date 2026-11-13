#!/usr/bin/env bash
# test-check-slot-reads.sh — the static read guard for the slot gates (#2362): both libraries pass, and every way
# around the builtin read helper is caught (one injected copy per bypass).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CHECK="$HERE/check-slot-reads.sh"
LSS="$HERE/lib/llm-session-slot.sh"
FSS="$ROOT/dark-factory/lib/forge-slot.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if bash "$CHECK" "$LSS" "$FSS" >"$TMP/out" 2>&1; then
    ok "both slot libraries pass the read guard"
else
    bad "the slot libraries fail the read guard: $(head -3 "$TMP/out" | tr '\n' ' ')"
fi

# inject NAME CODE: a copy of the LLM library with one extra function, which must fail the guard.
inject() {
    cp "$LSS" "$TMP/lib.sh"
    printf '\n%s\n' "$2" >> "$TMP/lib.sh"
    if bash "$CHECK" "$TMP/lib.sh" >"$TMP/out" 2>&1; then
        bad "bypass not caught: $1"
    else
        ok "bypass caught: $1 ($(head -1 "$TMP/out" | sed 's/^[^:]*:[0-9]*: //' | cut -c1-60))"
    fi
}
# shellcheck disable=SC2016  # literal source text injected into the copy
{
inject 'grep -q deciding on a stamp' '_lss_x1() { grep -qx "$$" "$1"; }'
inject 'process substitution from head' '_lss_x2() { IFS= read -r v < <(head -n 1 "$1"); }'
inject 'head piped into read' '_lss_x3() { head -n 1 "$1" | { read -r v; }; }'
inject 'backtick cat' '_lss_x4() { v=`cat "$1"`; }'
inject '$(<file)' '_lss_x5() { v=$(<"$1"); }'
inject 'command substitution of cat' '_lss_x6() { v="$(cat "$1")"; }'
inject 'quoted command word' '_lss_x7() { "cat" "$1"; }'
inject 'command word from a variable' '_lss_x8() { $SLOT_CAT "$1"; }'
inject 'input redirection outside the helper' '_lss_x9() { IFS= read -r v < "$1"; }'
inject '$( at the end of a line' '_lss_x10() { v=$(
    cat "$1"); }'
inject 'split command word c\at' '_lss_x11() { c\at "$1"; }'
}

# The helper body itself is pinned: dropping the reset of the value must fail.
sed '/^_lss_read() {$/,/^}$/{/^    _lss_val=""$/d;}' "$LSS" > "$TMP/lib.sh"
if bash "$CHECK" "$TMP/lib.sh" >/dev/null 2>&1; then
    bad "a changed _lss_read body was not caught"
else
    ok "a changed _lss_read body (no reset) is caught"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
