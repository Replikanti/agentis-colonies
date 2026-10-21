#!/usr/bin/env bash
# lib/confidential.sh — the bash side of the confidential-mode switch (#2327, epic #2317 M1).
#
# Sourced by every dark-factory script that must refuse or contain a confidential tree (a dir holding an entry
# named DF-CONFIDENTIAL, and everything below it; see lib/confidential.py and
# docs/agentarena.md#confidential-mode). It defines exactly two functions, and every bash caller uses them —
# none calls `confidential.py is-confidential` directly (demo-confidential-mode.sh enforces this):
#
#   df_is_confidential <path>...   returns 0 ("confidential") when DF_CONFIDENTIAL is set to anything other
#                                  than ''/0, or when any <path> lies in a marked tree. It returns 0 for EVERY
#                                  helper exit code except 1, so a missing or crashing python counts as
#                                  confidential (fail closed). Prints nothing.
#                                  To ask about the marker alone (ignoring the env switch), call it with
#                                  `DF_CONFIDENTIAL= df_is_confidential <path>`.
#   df_confidential_mark <dir>     mkdir -p <dir> (0700) and write <dir>/DF-CONFIDENTIAL (0600). Idempotent.
#                                  Returns the helper's exit code (non-zero = the mark was not written).
#
# Test seam: DF_CONFIDENTIAL_PY names the interpreter (default python3), so the self-test can stand in a
# missing or crashing one.
#
# Usage:  . lib/confidential.sh            (from a script)
#         bash lib/confidential.sh --self-test

_DF_CONF_PY_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/confidential.py"

df_is_confidential() {
  local rc=0
  "${DF_CONFIDENTIAL_PY:-python3}" -I "$_DF_CONF_PY_FILE" is-confidential "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 1 ]
}

df_confidential_mark() {
  local rc=0
  "${DF_CONFIDENTIAL_PY:-python3}" -I "$_DF_CONF_PY_FILE" mark "$1" || rc=$?
  return "$rc"
}

_df_conf_self_test() {
  local work fails=0 n=0
  work="$(mktemp -d "${TMPDIR:-/tmp}/confidential-sh-selftest.XXXXXX")" || return 1
  # shellcheck disable=SC2317,SC2329  # invoked indirectly via the result helpers below
  _ok()  { n=$((n + 1)); echo "  [PASS] $*"; }
  # shellcheck disable=SC2317,SC2329
  _bad() { n=$((n + 1)); fails=$((fails + 1)); echo "  [FAIL] $*"; }
  mkdir -p "$work/task/repo/src" "$work/plain"
  : > "$work/task/DF-CONFIDENTIAL"
  printf '#!/bin/sh\nexit 1\n' > "$work/py-says-no"
  printf '#!/bin/sh\nexit 134\n' > "$work/py-crashes"  # the exit code of an aborted process
  printf '#!/bin/sh\nexit 70\n' > "$work/py-fails"
  chmod +x "$work/py-says-no" "$work/py-crashes" "$work/py-fails"
  echo "confidential.sh --self-test"
  if DF_CONFIDENTIAL='' df_is_confidential "$work/task/repo/src"; then _ok "a path under a marker -> confidential"; else _bad "a path under a marker -> not confidential"; fi
  if DF_CONFIDENTIAL='' df_is_confidential "$work/plain"; then _bad "an unmarked path -> confidential"; else _ok "an unmarked path -> not confidential"; fi
  if DF_CONFIDENTIAL=1 df_is_confidential "$work/plain"; then _ok "DF_CONFIDENTIAL=1 -> confidential"; else _bad "DF_CONFIDENTIAL=1 -> not confidential"; fi
  if DF_CONFIDENTIAL='' DF_CONFIDENTIAL_PY="$work/no-such-python" df_is_confidential "$work/plain"; then _ok "a missing interpreter -> confidential (fail closed)"; else _bad "a missing interpreter -> not confidential"; fi
  if DF_CONFIDENTIAL='' DF_CONFIDENTIAL_PY="$work/py-crashes" df_is_confidential "$work/plain"; then _ok "a crashing interpreter (exit 134) -> confidential (fail closed)"; else _bad "a crashing interpreter -> not confidential"; fi
  if DF_CONFIDENTIAL='' DF_CONFIDENTIAL_PY="$work/py-fails" df_is_confidential "$work/plain"; then _ok "an interpreter exiting 70 -> confidential (fail closed)"; else _bad "an interpreter exiting 70 -> not confidential"; fi
  if DF_CONFIDENTIAL='' DF_CONFIDENTIAL_PY="$work/py-says-no" df_is_confidential "$work/task"; then _bad "exit 1 -> confidential"; else _ok "only exit 1 means not confidential"; fi
  if df_confidential_mark "$work/out/hunt" && [ -f "$work/out/hunt/DF-CONFIDENTIAL" ] \
     && DF_CONFIDENTIAL='' df_is_confidential "$work/out/hunt/verify"; then
    _ok "df_confidential_mark writes the marker and the tree reads as confidential"
  else
    _bad "df_confidential_mark did not mark the tree"
  fi
  if DF_CONFIDENTIAL_PY="$work/py-fails" df_confidential_mark "$work/out2" 2>/dev/null; then _bad "a failing mark returned 0"; else _ok "a failing mark returns non-zero"; fi
  rm -rf "$work"
  if [ "$fails" -eq 0 ]; then echo "confidential.sh --self-test: PASS ($n checks)"; return 0; fi
  echo "confidential.sh --self-test: FAIL ($fails of $n)"
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --self-test) _df_conf_self_test; exit $? ;;
    *) echo "usage: bash lib/confidential.sh --self-test (or source it)" >&2; exit 2 ;;
  esac
fi
