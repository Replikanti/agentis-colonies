#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# demo-flat-cyborg-env.sh — proof of #2119: lib/flat-cyborg-env.sh defaults a wide
# flat-cyborg PTY (FLAT_CYBORG_COLS=600) with an operator override still winning,
# and every script that emits an agentis config with llm.backend sources it.
#
# CI-safe: sources lib/flat-cyborg-env.sh directly, no agentis/flat-cyborg binary,
# no network, no LLM. Mirrors demo-forge-slot.sh's unit + wiring assertion shape.
#
# Usage:  dark-factory/demo-flat-cyborg-env.sh
# Exit: 0 = all assertions hold ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib/flat-cyborg-env.sh"

[ -f "$LIB" ] || { echo "demo-flat-cyborg-env.sh: lib not found: $LIB" >&2; exit 3; }

FAILS=0
ok()  { echo "  [OK]   $*"; }
bad() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

echo "demo-flat-cyborg-env.sh: 1) default + override, in-process ..."

# (1) unset -> the helper exports FLAT_CYBORG_COLS=600.
_out="$(unset FLAT_CYBORG_COLS; . "$LIB"; echo "$FLAT_CYBORG_COLS")"
if [ "$_out" = "600" ]; then
    ok "unset FLAT_CYBORG_COLS -> sourcing the helper exports 600 (the wide-PTY default)"
else
    bad "default did not land: got '$_out', want 600"
fi

# (2) an operator preset survives (the override wins over the default).
_out="$(FLAT_CYBORG_COLS=333 sh -c '. "'"$LIB"'"; echo "$FLAT_CYBORG_COLS"')"
if [ "$_out" = "333" ]; then
    ok "FLAT_CYBORG_COLS=333 preset -> stays 333 (operator override wins)"
else
    bad "override did not survive: got '$_out', want 333"
fi

# (3) the export actually reaches a CHILD process (not just the sourcing shell's own var table) —
#     this is the channel agentis/flat-cyborg itself reads.
_out="$(unset FLAT_CYBORG_COLS; . "$LIB"; sh -c 'echo "$FLAT_CYBORG_COLS"')"
if [ "$_out" = "600" ]; then
    ok "the default is EXPORTED (visible to a child process), not just a local shell variable"
else
    bad "child process did not see FLAT_CYBORG_COLS=600: got '$_out'"
fi

# (4) double-sourcing (several scripts source more than one lib/*.sh) is a safe no-op: an operator
#     override set BEFORE the first source must not be clobbered by a second source call.
_out="$(FLAT_CYBORG_COLS=42 sh -c '. "'"$LIB"'"; . "'"$LIB"'"; echo "$FLAT_CYBORG_COLS"')"
if [ "$_out" = "42" ]; then
    ok "double-sourcing is a safe no-op (an earlier override is never clobbered by a second source)"
else
    bad "double-source guard failed: got '$_out', want 42"
fi

echo
echo "demo-flat-cyborg-env.sh: 2) wiring — every flat-cyborg-config-emitting script sources the helper ..."

# Every dark-factory script that ever writes a real (non-comment) `llm.backend = ...` config line
# (echo or printf, single- or double-quoted) is a flat-cyborg config emitter and MUST source
# lib/flat-cyborg-env.sh. Comments merely DESCRIBING the backend (like screen-leads.sh's) do not count.
EMITTERS=""
for f in $(grep -lRE 'llm\.backend' "$HERE" --include='*.sh' 2>/dev/null | sort -u); do
    # Note: deliberately NOT `... | grep -qE ...` — under `set -o pipefail`, grep -q's early exit on
    # first match can SIGPIPE the upstream grep, and pipefail then reports the pipeline as failed even
    # though a match WAS found (a real, intermittent race observed while developing this assertion).
    _hit="$(grep -vE '^\s*#' "$f" | grep -E "['\"]llm\.backend[[:space:]]*=")"
    if [ -n "$_hit" ]; then
        EMITTERS="$EMITTERS
$f"
    fi
done
EMITTERS="$(printf '%s\n' "$EMITTERS" | sed '/^$/d')"
if [ -z "$EMITTERS" ]; then
    bad "no llm.backend-emitting script found — the grep pattern itself regressed"
else
    _missing=""
    for f in $EMITTERS; do
        grep -q 'flat-cyborg-env.sh' "$f" || _missing="$_missing $f"
    done
    if [ -z "$_missing" ]; then
        _n="$(printf '%s\n' "$EMITTERS" | wc -l | tr -d ' ')"
        ok "all $_n llm.backend-emitting scripts source lib/flat-cyborg-env.sh"
    else
        bad "these llm.backend-emitting scripts do NOT source lib/flat-cyborg-env.sh:$_missing"
    fi
fi

# auditor/scripts/start-colony.sh emits no config of its own (it execs the auditor pipeline against an
# existing colony.toml) but is the one-shot entry point flat-cyborg#78/#79 targets — sourced explicitly.
START_COLONY="$HERE/auditor/scripts/start-colony.sh"
if [ -f "$START_COLONY" ] && grep -q 'flat-cyborg-env.sh' "$START_COLONY"; then
    ok "auditor/scripts/start-colony.sh sources lib/flat-cyborg-env.sh"
else
    bad "auditor/scripts/start-colony.sh does not source lib/flat-cyborg-env.sh"
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "demo-flat-cyborg-env.sh: PASS — FLAT_CYBORG_COLS defaults to 600, an operator override wins,"
    echo "                         double-sourcing is safe, and every flat-cyborg config emitter is wired."
    exit 0
fi
echo "demo-flat-cyborg-env.sh: DEMO FAILED — a #2119 wide-PTY-default assertion did not hold" >&2
exit 1
