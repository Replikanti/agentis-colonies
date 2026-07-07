#!/usr/bin/env bash
# test-invariant-codepath-resolution.sh — regression for #1475.
#
# run-invariant-hunt.sh must resolve the LLM source path (CODE_PATH) for a NESTED `--target`
# (e.g. `src/contracts/vault/Vault.sol:Vault`), not only the bare `src/<basename>` convention. A nested
# target that fell through to an EMPTY CODE_PATH used to leave the LLM with no source (it fabricates a toy
# of the same name) AND disarm the #1471 target-linkage gate (which only arms when CODE_PATH is non-empty),
# so a fabricated toy reached a FINDING/CLEAN verdict instead of HARNESS_ERROR.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RIH="$HERE/../dark-factory/run-invariant-hunt.sh"

FAIL=0
pass() { echo "test-invariant-codepath-resolution.sh: [PASS] $1"; }
fail() { echo "test-invariant-codepath-resolution.sh: [FAIL] $1" >&2; FAIL=1; }

if [ ! -f "$RIH" ]; then
  echo "test-invariant-codepath-resolution.sh: [FAIL] run-invariant-hunt.sh not found at $RIH" >&2
  exit 1
fi

# --- 1. SOURCE ANCHOR: the fix tries the repo-root path BEFORE the src/ convention ------------------------
# The two literal `[ -f "$REPO/..." ]` probes are grepped verbatim (single-quoted: no shell expansion wanted).
# shellcheck disable=SC2016
root_ln="$(grep -nF '[ -f "$REPO/$_c" ]' "$RIH" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016
src_ln="$(grep -nF '[ -f "$REPO/src/$_c" ]' "$RIH" | head -1 | cut -d: -f1)"
if [ -n "$root_ln" ] && [ -n "$src_ln" ] && [ "$root_ln" -lt "$src_ln" ]; then
  pass "CODE_PATH resolution tries \$REPO/\$_c before \$REPO/src/\$_c (nested-path aware)"
else
  fail "CODE_PATH resolution must try \$REPO/\$_c BEFORE \$REPO/src/\$_c (#1475 regression: root=$root_ln src=$src_ln)"
fi

# --- 2. FUNCTIONAL: the resolution rule resolves nested / src-prefixed / bare targets ---------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/src/contracts/vault" "$REPO/src"
printf 'contract Vault {}\n' > "$REPO/src/contracts/vault/Vault.sol"
printf 'contract Morpho {}\n' > "$REPO/src/Morpho.sol"

resolve() {  # $1 = --target label -> echoes resolved CODE ("" if none), using the run-invariant-hunt rule
  local TARGET="$1" _c CODE=""
  _c="${TARGET%%:*}"
  if [ -f "$REPO/$_c" ]; then
    CODE="$REPO/$_c"
  elif [ -f "$REPO/src/$_c" ]; then
    CODE="$REPO/src/$_c"
  fi
  printf '%s' "$CODE"
}

if [ "$(resolve 'src/contracts/vault/Vault.sol:Vault')" = "$REPO/src/contracts/vault/Vault.sol" ]; then
  pass "nested --target resolves to the real file (arms the #1471 gate)"
else
  fail "nested --target did not resolve to the real file"
fi

if [ "$(resolve 'src/Morpho.sol:Morpho')" = "$REPO/src/Morpho.sol" ]; then
  pass "src/-prefixed --target resolves"
else
  fail "src/-prefixed --target did not resolve"
fi

if [ "$(resolve 'Morpho.sol:Morpho')" = "$REPO/src/Morpho.sol" ]; then
  pass "bare-basename --target resolves via the src/ convention"
else
  fail "bare-basename --target did not resolve"
fi

if [ -z "$(resolve 'src/DoesNotExist.sol:X')" ]; then
  pass "a nonexistent --target resolves to empty (no false source)"
else
  fail "nonexistent --target should resolve to empty"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-invariant-codepath-resolution.sh: ALL CHECKS PASSED"
  exit 0
else
  echo "test-invariant-codepath-resolution.sh: FAILURES ABOVE" >&2
  exit 1
fi
