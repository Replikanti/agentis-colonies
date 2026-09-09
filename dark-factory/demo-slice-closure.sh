#!/usr/bin/env bash
# demo-slice-closure.sh — the OFFLINE gate for auditor/slice-fns.sh's SAME-FILE CALLEE CLOSURE
# (#2150, sub-milestone D1.1 of epic #2130).
#
# What the change is: a function-level slice used to contain ONLY the requested functions plus the contract
# header. Real contracts put nothing interesting in the external entry point — it delegates to same-file
# `internal` helpers, and those are where the state writes and the external calls live. A slice of the entry
# point alone therefore showed the hunter (and every deterministic detector that reads the assembled payload,
# e.g. hunter.ag's #2145 attacker-controlled-callee net) a contract with no external call in it at all.
# slice-fns.sh now expands the requested names, BEFORE extraction, with the internal/private same-file
# functions transitively reachable from them, bounded by SLICE_MAX_DEPTH (default 3) and SLICE_MAX_LINES
# (default 2000). Extraction, header handling, printing and the whole-file fallback are untouched: the
# closure only decides WHICH names are wanted.
#
# This demo is the CI floor: pure sh/awk over a checked-in fixture — no agentis, no forge, no network, no LLM.
# The slicer is invoked exactly the way production invokes it (`sh <slicer> <file> "<fns>"`, per hunter.ag's
# cat_file), so a bashism would fail here the same way it would fail a CI cell.
#
# Usage:  dark-factory/demo-slice-closure.sh
# Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SLICER="$HERE/auditor/slice-fns.sh"
FIX="$HERE/fixtures/slice-closure/contracts/ClosureChain.sol"
BIG="$HERE/fixtures/zone-map/contracts/liquidation/Liquidation.sol"

FAILS=0
note() { echo "demo-slice-closure.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

for f in "$SLICER" "$FIX" "$BIG"; do
  [ -f "$f" ] || { note "required file not found: $f" >&2; exit 3; }
done

WORK="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# _slice <errfile> <file> <fns> — run the slicer the way hunter.ag's cat_file does, keeping stderr aside so
# the truncation note can be asserted separately from the payload.
_slice() { _err="$1"; shift; sh "$SLICER" "$1" "$2" 2>"$_err"; }

# How many `function <name>(` definition lines a payload carries. The closure's whole risk is over-inclusion,
# so counting is worth more than a per-name grep: a net that quietly pulled in the whole contract would still
# satisfy every "contains _a" assertion.
_nfn() { grep -c '^[[:space:]]*function [A-Za-z_]' 2>/dev/null || true; }

# ----------------------------------------------------------------------------------------------------------
note "1) default caps: the closure walks the chain entry -> _a -> _b ..."
OUT="$(_slice "$WORK/e1" "$FIX" "entry")"
ERR="$(cat "$WORK/e1")"
N="$(printf '%s\n' "$OUT" | _nfn)"
if printf '%s\n' "$OUT" | grep -q '^    function entry(' \
   && printf '%s\n' "$OUT" | grep -q '^    function _a(' \
   && printf '%s\n' "$OUT" | grep -q '^    function _b('; then
  ok "requesting only 'entry' yields entry + _a (hop 1) + _b (hop 2)"
else
  bad "the transitive closure did not reach both internal helpers from 'entry' (got $N function(s))"
fi
# The POINT of the fix: the external call only exists inside the second-hop helper, so this line is the thing
# a detector reading the payload could never see before.
if printf '%s\n' "$OUT" | grep -q 'IThing(cfg.get()).ping('; then
  ok "the computed-target external call inside the 2-hop helper is IN the slice (the #2145-class blind spot)"
else
  bad "the external call inside _b is still absent from an 'entry' slice — the closure does not reach it"
fi
# Not a visibility sweep and not a whole-file dump: an internal helper nobody calls and an uncalled external
# sibling must both stay out.
if printf '%s\n' "$OUT" | grep -q 'function _neverCalled(' ; then
  bad "_neverCalled (internal, unreachable from entry) was pulled in — the closure is a visibility sweep, not a call graph"
elif printf '%s\n' "$OUT" | grep -q 'function unrelated(' ; then
  bad "unrelated (external, never called) was pulled in — the closure over-includes"
elif [ "$N" -eq 3 ]; then
  ok "exactly 3 functions in the slice (entry, _a, _b) — no unreachable helper, no uncalled sibling"
else
  bad "expected exactly 3 functions in the closure slice, got $N"
fi
if [ -z "$ERR" ]; then
  ok "the closure reached a fixpoint within the default caps — no truncation note on stderr"
else
  bad "an unexpected stderr note was emitted at the default caps: $ERR"
fi

# ----------------------------------------------------------------------------------------------------------
note "2) the header is still printed unconditionally (extraction/printing untouched) ..."
if printf '%s\n' "$OUT" | grep -q '^pragma solidity' \
   && printf '%s\n' "$OUT" | grep -q '^contract ClosureChain {' \
   && printf '%s\n' "$OUT" | grep -q '^    address public owner;'; then
  ok "pragma + contract declaration + state variables still lead the slice"
else
  bad "the header (pragma / contract decl / state vars) is no longer emitted ahead of the functions"
fi

# ----------------------------------------------------------------------------------------------------------
note "3) SLICE_MAX_DEPTH bounds the walk ..."
OUT1="$(SLICE_MAX_DEPTH=1 _slice "$WORK/e2" "$FIX" "entry")"
ERR1="$(cat "$WORK/e2")"
N1="$(printf '%s\n' "$OUT1" | _nfn)"
if printf '%s\n' "$OUT1" | grep -q '^    function _a(' && ! printf '%s\n' "$OUT1" | grep -q '^    function _b('; then
  ok "SLICE_MAX_DEPTH=1 takes hop 1 (_a) and stops before hop 2 (_b)"
else
  bad "SLICE_MAX_DEPTH=1 did not stop after one hop (got $N1 function(s))"
fi
if printf '%s\n' "$OUT1" | grep -q 'IThing(cfg.get()).ping('; then
  bad "SLICE_MAX_DEPTH=1 still carried _b's external call — the depth cap is not enforced"
else
  ok "the depth-1 slice carries no second-hop code at all"
fi
# The depth cap stopping short of a fixpoint is exactly the case the note exists to report: the payload is
# silently smaller than the call graph, and an operator raising the cap is the only way to see the rest.
case "$ERR1" in
  'slice-fns: closure truncated (depth-cap 1) — 1 callee(s) omitted') ok "the depth cap reports itself on stderr, naming the cap and the omitted-callee count" ;;
  '') bad "the depth cap stopped the closure short of a fixpoint but emitted no stderr note" ;;
  *) bad "unexpected depth-cap note: $ERR1" ;;
esac

# ----------------------------------------------------------------------------------------------------------
note "4) SLICE_MAX_LINES bounds the payload ..."
# 50 sits between the 43-line entry+_a slice and the 58-line entry+_a+_b one for this fixture, so _b is the
# single callee the budget cannot afford.
OUT2="$(SLICE_MAX_LINES=50 _slice "$WORK/e3" "$FIX" "entry")"
ERR2="$(cat "$WORK/e3")"
if printf '%s\n' "$OUT2" | grep -q '^    function _a(' && ! printf '%s\n' "$OUT2" | grep -q '^    function _b('; then
  ok "a line budget that fits entry+_a but not _b keeps _a and drops _b"
else
  bad "SLICE_MAX_LINES did not bound the closure at the expected point"
fi
case "$ERR2" in
  'slice-fns: closure truncated (line-cap 50) — 1 callee(s) omitted') ok "the line cap reports itself on stderr, naming the cap and the omitted-callee count" ;;
  '') bad "the line cap silently shrank the slice with no stderr note" ;;
  *) bad "unexpected line-cap note: $ERR2" ;;
esac
# A budget too small even for the requested function must not start dropping REQUESTED names — the closure
# only ever decides what to ADD.
OUT3="$(SLICE_MAX_LINES=1 _slice "$WORK/e4" "$FIX" "entry")"
if printf '%s\n' "$OUT3" | grep -q '^    function entry(' && [ "$(printf '%s\n' "$OUT3" | _nfn)" -eq 1 ]; then
  ok "an exhausted budget still emits the REQUESTED function (only closure-discovered callees are droppable)"
else
  bad "SLICE_MAX_LINES=1 dropped the requested function itself"
fi

# ----------------------------------------------------------------------------------------------------------
note "5) SLICE_MAX_DEPTH=0 reproduces the pre-#2150 slice BYTE FOR BYTE ..."
# The reference is the extraction awk EXTRACTED FROM THE SHIPPED SCRIPT BY LINE RANGE (the repo's
# `f&&/^}$/{exit}` idiom) rather than a copy pasted into this demo: that stage is what #2150 left untouched,
# so running it alone on the RAW name list is precisely "the slicer as it was".
A="$(grep -nF 'OUT="$(awk -v fns="$FNS"' "$SLICER" | head -1 | cut -d: -f1)"
B="$(grep -nF "' \"\$F\")\" && rc=0" "$SLICER" | head -1 | cut -d: -f1)"
EXTRACT="$WORK/extract.awk"
if [ -n "$A" ] && [ -n "$B" ] && [ "$B" -gt "$A" ]; then
  sed -n "$((A + 1)),$((B - 1))p" "$SLICER" > "$EXTRACT"
fi
if [ ! -s "$EXTRACT" ]; then
  bad "could not extract the extraction awk program from slice-fns.sh by line range (reshaped?)"
else
  REF="$(awk -v fns="entry" -f "$EXTRACT" "$FIX")"
  GOT="$(SLICE_MAX_DEPTH=0 _slice "$WORK/e5" "$FIX" "entry")"
  if [ "$REF" = "$GOT" ]; then
    ok "SLICE_MAX_DEPTH=0 output is byte-identical to the untouched extraction stage (the closure is opt-out)"
  else
    bad "SLICE_MAX_DEPTH=0 does NOT reproduce the pre-closure slice byte for byte"
  fi
  if [ -s "$WORK/e5" ]; then
    bad "SLICE_MAX_DEPTH=0 wrote to stderr — a disabled closure must be entirely silent"
  else
    ok "SLICE_MAX_DEPTH=0 is silent on stderr"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
note "6) the pre-existing fallbacks are untouched ..."
# No names at all -> first 2000 lines, unchanged.
if [ "$(sh "$SLICER" "$FIX" "" 2>/dev/null | _nfn)" -eq 7 ]; then
  ok "an empty name list still falls back to the whole file (all 7 definitions)"
else
  bad "the empty-name-list whole-file fallback regressed"
fi
# A name that matches nothing -> whole-file fallback (a typo must never yield an empty payload). The closure
# runs first and expands nothing, so the extraction stage still sees no match and still exits 3.
FB="$(_slice "$WORK/e6" "$FIX" "noSuchFunction")"
if printf '%s\n' "$FB" | grep -q 'function unrelated(' && printf '%s\n' "$FB" | grep -q '^interface ICfg {'; then
  ok "an unmatched name still falls back to the whole file (typo never yields an empty payload)"
else
  bad "the no-match whole-file fallback regressed"
fi

# ----------------------------------------------------------------------------------------------------------
note "7) shape sanity on a realistic multi-function contract (fixtures/zone-map liquidation) ..."
# Not a synthetic chain: the checked-in liquidation contract has 13 functions across 4 externally-callable
# entry points, so this arm is where accidental whole-file inclusion, duplicated functions or an
# order-dependent walk would show up.
LOUT="$(_slice "$WORK/e7" "$BIG" "liquidate")"
LN="$(printf '%s\n' "$LOUT" | _nfn)"
if printf '%s\n' "$LOUT" | grep -q '^    function liquidate(' \
   && printf '%s\n' "$LOUT" | grep -q '^    function seize(' \
   && printf '%s\n' "$LOUT" | grep -q '^    function _healthFactor('; then
  ok "liquidate pulls in its internal helpers seize + _healthFactor (the real reason the slice was blind)"
else
  bad "the closure did not reach liquidate's internal helpers on the liquidation fixture"
fi
if printf '%s\n' "$LOUT" | grep -q '^    function setOracle(' || printf '%s\n' "$LOUT" | grep -q '^    function openPosition('; then
  bad "unrelated entry points leaked into the liquidate slice (over-inclusion on a realistic contract)"
elif [ "$LN" -eq 3 ]; then
  ok "exactly 3 functions in the liquidate slice — no unrelated entry point, no whole-file dump"
else
  bad "expected 3 functions in the liquidate slice, got $LN"
fi
DUPS="$(printf '%s\n' "$LOUT" | grep '^    function ' | sort | uniq -d | _nfn)"
if [ "$DUPS" -eq 0 ]; then
  ok "no function is emitted twice (a diamond in the call graph is visited once)"
else
  bad "$DUPS function definition(s) were emitted more than once"
fi
H1="$(_slice "$WORK/e8" "$BIG" "liquidate" | cksum)"
H2="$(_slice "$WORK/e9" "$BIG" "liquidate" | cksum)"
H3="$(_slice "$WORK/e10" "$BIG" "seize,liquidate" | cksum)"
if [ "$H1" = "$H2" ]; then
  ok "repeated runs are byte-identical (the walk order is deterministic)"
else
  bad "two runs over the same input produced different slices (non-deterministic walk order)"
fi
# The output order is FILE order, decided by the printer, so naming a discovered callee explicitly cannot
# change the payload — which is what makes the request list a SET rather than a sequence.
if [ "$H1" = "$H3" ]; then
  ok "naming a discovered callee explicitly yields the same slice (request order carries no meaning)"
else
  bad "requesting 'seize,liquidate' differs from the closure of 'liquidate' alone"
fi

# ----------------------------------------------------------------------------------------------------------
note "8) source-guard: the two caps are documented and defaulted where the script reads them ..."
if grep -q 'SLICE_MAX_DEPTH="\${SLICE_MAX_DEPTH:-3}"' "$SLICER" \
   && grep -q 'SLICE_MAX_LINES="\${SLICE_MAX_LINES:-2000}"' "$SLICER"; then
  ok "SLICE_MAX_DEPTH defaults to 3 and SLICE_MAX_LINES to 2000 in the script itself"
else
  bad "the SLICE_MAX_DEPTH / SLICE_MAX_LINES defaults moved or changed value"
fi
if grep -q 'SLICE_MAX_DEPTH' "$SLICER" && grep -q '0 disables the closure entirely' "$SLICER"; then
  ok "the header documents the caps and the depth-0 opt-out"
else
  bad "slice-fns.sh's header no longer documents the closure knobs"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the same-file callee closure (transitive walk, depth/line caps, truncation note, depth-0 identity, untouched fallbacks) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
