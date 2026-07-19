#!/usr/bin/env bash
# demo-invariant-mutant-kill.sh — proof of the #1724 MUTATION-GUIDED invariant-validation kill-set.
#
# The invariant-hunt discovery track judges bugs with the forge-invariant.sh stateful fuzzer, but nothing
# measured whether a GENERATED invariant is actually EXPRESSIVE enough to catch real bugs (the #1716 A/B
# limit). #1724 adds a standardized, per-TARGET_CLASS MUTANT KILL-SET (evm-harness/mutants/) + a runnable
# harness (evm-harness/mutant-kill.sh) that drives each fixture through the SAME forge-invariant.sh gate and
# reports KILLED/SURVIVED. Each class encodes a three-way DISCRIMINATION: the good invariant KILLS the
# mutant AND SURVIVES the clean twin, while the toothless control SURVIVES the mutant — so a "kill" measures
# invariant EXPRESSIVENESS, not a rigged always-fire harness.
#
# This demo has TWO parts:
#   1) SOURCE-GUARD (always, CI-safe, no toolchain): every manifest row references existing fixtures; each
#      class carries base + >=1 mutant + good + toothless fixtures; the harness references forge-invariant.sh,
#      a fixed seed, the 1->KILLED / 0->SURVIVED / 2->ERROR mapping, and the SKIP-without-forge path; and the
#      manifest carries the good-vs-toothless discrimination rows.
#   2) LIVE (when forge is on PATH): run mutant-kill.sh --self-test and assert every row matches expected.
#      agentis is NOT needed (the gate is exercised directly, not through run-invariant-hunt.sh).
#
# Usage:  dark-factory/demo-invariant-mutant-kill.sh
# Exit: 0 = all assertions hold (live part SKIPs cleanly when forge is absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MUTANTS_DIR="$HERE/evm-harness/mutants"
MANIFEST="$MUTANTS_DIR/manifest.tsv"
HARNESS="$HERE/evm-harness/mutant-kill.sh"
GATE="$HERE/evm-harness/forge-invariant.sh"

FAILS=0
note() { echo "demo-invariant-mutant-kill.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$MANIFEST" ] || { note "manifest not found: $MANIFEST" >&2; exit 3; }
[ -f "$HARNESS" ]  || { note "harness not found: $HARNESS" >&2; exit 3; }
[ -f "$GATE" ]     || { note "gate not found: $GATE" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1a) MANIFEST INTEGRITY — every row references existing fixtures, and expected is KILLED|SURVIVED.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1724 manifest integrity ..."

ROWS=0; MISSING=0; BADEXP=0
while IFS="$(printf '\t')" read -r cls cf iff exp rest || [ -n "$cls" ]; do
  case "$cls" in ''|'#'*) continue ;; esac
  ROWS=$((ROWS + 1))
  [ -f "$MUTANTS_DIR/$cls/$cf" ]  || { note "  row references missing contract fixture: $cls/$cf" >&2; MISSING=$((MISSING + 1)); }
  [ -f "$MUTANTS_DIR/$cls/$iff" ] || { note "  row references missing invariant fixture: $cls/$iff" >&2; MISSING=$((MISSING + 1)); }
  case "$exp" in KILLED|SURVIVED) ;; *) note "  row has bad expected column: '$exp'" >&2; BADEXP=$((BADEXP + 1)) ;; esac
done < "$MANIFEST"

if [ "$ROWS" -gt 0 ]; then ok "manifest has $ROWS data rows"; else bad "manifest has no data rows"; fi
if [ "$MISSING" -eq 0 ]; then ok "every manifest row references an existing contract + invariant fixture"; else bad "$MISSING manifest fixture reference(s) missing on disk"; fi
if [ "$BADEXP" -eq 0 ]; then ok "every manifest row's expected column is KILLED|SURVIVED"; else bad "$BADEXP manifest row(s) have a bad expected column"; fi

# ----------------------------------------------------------------------------------------------------------
# 1b) CLASS COMPLETENESS — each class dir carries base + >=1 mutant + a good + a toothless invariant fixture.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that each class carries base + mutant + good + toothless fixtures ..."

for _cdir in "$MUTANTS_DIR"/C-*/; do
  [ -d "$_cdir" ] || continue
  _cls="$(basename "$_cdir")"
  _base=$(ls "$_cdir"*.base.sol 2>/dev/null | wc -l)
  _mut=$(ls "$_cdir"*.mutant-*.sol 2>/dev/null | wc -l)
  _tooth=$(ls "$_cdir"inv_toothless.t.sol 2>/dev/null | wc -l)
  # a "good" invariant fixture = an inv_*.t.sol that is NOT the toothless control
  _good=0
  for _gf in "$_cdir"inv_*.t.sol; do
    [ -e "$_gf" ] || continue
    case "$_gf" in *inv_toothless.t.sol) continue ;; esac
    _good=$((_good + 1))
  done
  if [ "$_base" -ge 1 ] && [ "$_mut" -ge 1 ] && [ "$_good" -ge 1 ] && [ "$_tooth" -ge 1 ]; then
    ok "$_cls: base=$_base mutant=$_mut good=$_good toothless=$_tooth"
  else
    bad "$_cls incomplete: base=$_base mutant=$_mut good=$_good toothless=$_tooth (need base>=1, mutant>=1, good>=1, toothless>=1)"
  fi
done

# ----------------------------------------------------------------------------------------------------------
# 1c) HARNESS WIRING — references the gate, a fixed seed, the exit->verdict mapping, and the SKIP path.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1724 harness wiring ..."

if grep -q 'forge-invariant.sh' "$HARNESS"; then
  ok "mutant-kill.sh drives fixtures through evm-harness/forge-invariant.sh (fuzzer is the sole judge)"
else
  bad "mutant-kill.sh does not reference forge-invariant.sh"
fi

if grep -q 'SEED="1"' "$HARNESS" && grep -q -- '--seed' "$HARNESS"; then
  ok "mutant-kill.sh pins a FIXED --seed (reproducible fuzzing)"
else
  bad "mutant-kill.sh does not pin a fixed --seed"
fi

if grep -q 'VERDICT=KILLED' "$HARNESS" && grep -q 'VERDICT=SURVIVED' "$HARNESS" && grep -q 'VERDICT=ERROR' "$HARNESS"; then
  ok "mutant-kill.sh maps gate exit 1->KILLED / 0->SURVIVED / 2->ERROR"
else
  bad "mutant-kill.sh missing the 1->KILLED / 0->SURVIVED / 2->ERROR exit mapping"
fi

if grep -q 'command -v forge' "$HARNESS" && grep -q '\[SKIP\]' "$HARNESS"; then
  ok "mutant-kill.sh SKIPs cleanly (exit 0) when forge is absent (CI-safe, like demo-invariant-hunt.sh)"
else
  bad "mutant-kill.sh missing the SKIP-without-forge path"
fi

# The harness must SKIP + exit 0 here (this demo runs on CI without forge) — the behavioural proof of the path.
_st_out="$("$HARNESS" --self-test 2>&1)"; _st_rc=$?
if ! command -v forge >/dev/null 2>&1; then
  if [ "$_st_rc" -eq 0 ] && printf '%s' "$_st_out" | grep -q '\[SKIP\]'; then
    ok "mutant-kill.sh --self-test SKIPs + exit 0 without forge (behavioural)"
  else
    bad "mutant-kill.sh --self-test without forge gave exit $_st_rc (expected 0 + [SKIP])"
    printf '%s\n' "$_st_out" | sed 's/^/         | /' | tail -5
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# 1d) DISCRIMINATION ROWS — the manifest must carry a good-KILLS-mutant row AND a toothless-SURVIVES-mutant
#     row (the source-level assertion that a kill measures expressiveness, not a rigged always-fire harness).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the good-vs-toothless discrimination rows ..."

if grep '\.mutant-' "$MANIFEST" | grep 'KILLED' | grep -qv 'inv_toothless'; then
  ok "manifest has a good-invariant x mutant = KILLED row"
else
  bad "manifest missing a good-invariant x mutant = KILLED row"
fi

if grep '\.mutant-' "$MANIFEST" | grep 'inv_toothless' | grep -q 'SURVIVED'; then
  ok "manifest has a toothless x mutant = SURVIVED discrimination row"
else
  bad "manifest missing a toothless x mutant = SURVIVED discrimination row"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) LIVE — run the self-test under forge and assert every row matches expected (skip cleanly if absent).
# ----------------------------------------------------------------------------------------------------------
if ! command -v forge >/dev/null 2>&1; then
  skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run the live mutant kill-set self-test"
else
  note "running the live mutant-kill.sh --self-test under forge ..."
  live_out="$("$HARNESS" --self-test 2>&1)"; live_rc=$?
  if [ "$live_rc" -eq 0 ]; then
    ok "mutant-kill.sh --self-test PASSED — every kill-set row matched its expected verdict under the fuzzer"
    printf '%s\n' "$live_out" | grep -E '\[OK\]|\[FAIL\]' | sed 's/^/         | /'
  else
    bad "mutant-kill.sh --self-test FAILED under forge (exit $live_rc)"
    printf '%s\n' "$live_out" | sed 's/^/         | /' | tail -20
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #1724 mutant kill-set is wired — every manifest row references real fixtures; each class"
  note "      carries base + mutant + good + toothless fixtures; the harness drives them through the untouched"
  note "      forge-invariant.sh gate with a fixed seed and the 1->KILLED / 0->SURVIVED / 2->ERROR mapping, and"
  note "      SKIPs cleanly without forge; and the manifest encodes the good-vs-toothless discrimination. (The"
  note "      live KILLED/SURVIVED verdicts are the fuzzer's — run --self-test under forge to confirm them.)"
  exit 0
fi
note "DEMO FAILED — a #1724 mutant kill-set assertion did not hold" >&2
exit 1
