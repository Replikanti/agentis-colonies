#!/usr/bin/env bash
# dark-factory/lib/flat-cyborg-env.sh — default a wide flat-cyborg PTY for every
# script that drives the flat-cyborg backend.
#
# WHY: flat-cyborg's Ink TUI soft-wraps any reply line longer than the PTY width
# (a fixed 120 columns before flat-cyborg >= 0.16.0's `--cols`/`$FLAT_CYBORG_COLS`,
# see flat-cyborg#78/#79); a screen-read `--extract` reply then comes back
# re-wrapped, and `|`-delimited protocol lines lose trailing fields (measured
# live: `ZONE|` class lists on #2118, `CANDIDATE|...|poc` on the refute gate).
# agentis-core builds the flat-cyborg argv itself (no flag passthrough), so the
# environment variable is the only channel today. Sourcing this file makes 600
# columns the federation default while an operator override still wins; older
# flat-cyborg binaries (< 0.16.0) ignore the variable harmlessly.
#
# Guarded against double-sourcing (several scripts source more than one lib/*
# file that could, in principle, source this one too).
if [ -n "${_DF_FLAT_CYBORG_ENV_SOURCED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
_DF_FLAT_CYBORG_ENV_SOURCED=1

export FLAT_CYBORG_COLS="${FLAT_CYBORG_COLS:-600}"
