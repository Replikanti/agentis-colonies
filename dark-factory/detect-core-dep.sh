#!/bin/sh
# detect-core-dep.sh — mechanical (no-LLM) CORE-DEPENDENCY / delegatecall-singleton detector for the
# dark-factory deep-hunt path (#1763 G1). Lifted out of run-invariant-hunt.sh's inline yearn-only grep+locate
# so the runner rewires to a single call and the SHAPE detection is generalized, while yearn stays an explicit,
# byte-preserved special case.
#
# Contract:
#   detect-core-dep.sh <target-source-file> <staged-repo-root>
#   stdout: EITHER nothing (EMPTY — no resolvable core dependency) OR exactly one line
#           `<abs_singleton_src>:<Name>:<addr>|<featureset>`
#   stderr: shape diagnostics (which shape was recognized, and why it did / did not resolve).
#   exit:   always 0 (EMPTY is a normal outcome, not an error).
#
# HIGHEST-RISK failure mode = OVER-FIRE: a FALSE singleton detection threads a wrong `<path>:Name:addr` into the
# prover's `vm.etch` directive => HARNESS_ERROR or a silently wrong share path. Mitigation, baked in here: the
# detector recognizes the general delegatecall-singleton SHAPES (EIP-1967 proxy, diamond/facets, generic
# constant-address delegatecall) but only ever resolves a CONCRETE `<source:Name:address>` against a
# KNOWN-SINGLETON REGISTRY (yearn-v3 is the only entry today) — a bare EIP-1967 runtime slot value, a diamond's
# per-selector facet, or an arbitrary external delegatecall address is NOT mechanically resolvable to an in-repo
# impl source without guessing, and a wrong singleton is worse than none. So: recognize the shape, try to
# resolve against the registry, and emit EMPTY on ANY miss / ambiguity / unresolvable address. NEVER emit a
# guessed address.
#
# featureset: a short deterministic tag list. `dcs` (delegatecall-singleton) on a positive detection. G2/G3 will
# later append `ahg` (admin-health-guard) / `dda` (deferred-accounting); this only emits what G1 detects (`dcs`).
#
# No LLM, no network, no forge — pure grep+locate, the kind of mechanical tooling the substrate-purity rule
# explicitly allows. POSIX sh.
set -u

SRC="${1:-}"
ROOT="${2:-}"

# Known PUBLIC facts. The yearn-v3 TokenizedStrategy singleton address (on-chain constant, lifted verbatim from
# run-invariant-hunt.sh) and the canonical EIP-1967 implementation slot (the same constant run-live-watch.sh's
# IMPL_SLOT watches). Both are public on-chain / standard facts.
YEARN_ADDR="0xD377919FA87120584B21279a491F82D5265A139c"
IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"

say() { echo "detect-core-dep.sh: $*" >&2; }

# EMPTY on any bad input — never guess.
if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  say "no readable target source ('$SRC') — EMPTY"
  exit 0
fi
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  say "no staged repo root ('$ROOT') — EMPTY"
  exit 0
fi

# locate_yearn_singleton — the ONE registry entry: the real TokenizedStrategy.sol staged inside the repo copy
# (its own remappings intact). Primary well-known path, then a `find` fallback. Prints the abs path or nothing.
locate_yearn_singleton() {
  _ts="$ROOT/lib/tokenized-strategy/src/TokenizedStrategy.sol"
  if [ ! -f "$_ts" ]; then
    _ts="$(find "$ROOT"/lib -name TokenizedStrategy.sol -print -quit 2>/dev/null || true)"
  fi
  if [ -n "$_ts" ] && [ -f "$_ts" ]; then
    printf '%s' "$_ts"
  fi
}

emit() { # <abs_src> <Name> <addr> <featureset>
  printf '%s:%s:%s|%s\n' "$1" "$2" "$3" "$4"
}

# ---------------------------------------------------------------------------------------------------------
# (A) yearn-v3 BaseStrategy -> TokenizedStrategy — MOST-SPECIFIC-FIRST; the permanent CI-enforced regression
# case. The ERC4626 share logic is delegatecalled to the TokenizedStrategy singleton at the hard-coded
# constant YEARN_ADDR; resolve the REAL singleton source in the staged repo copy.
# ---------------------------------------------------------------------------------------------------------
if grep -qE 'TokenizedStrategy|BaseStrategy' "$SRC" 2>/dev/null; then
  _y="$(locate_yearn_singleton)"
  if [ -n "$_y" ]; then
    say "[A] yearn-v3 signal — real TokenizedStrategy singleton staged at $_y"
    emit "$_y" "TokenizedStrategy" "$YEARN_ADDR" "dcs"
    exit 0
  fi
  say "[A] yearn-v3 signal found but TokenizedStrategy.sol not located under $ROOT/lib — EMPTY (no guess)"
  exit 0
fi

# ---------------------------------------------------------------------------------------------------------
# (B/C/D) general delegatecall-singleton SHAPES. Recognize the shape, then resolve ONLY against the
# known-singleton registry (yearn is the only entry today). Anything unresolvable => EMPTY.
# ---------------------------------------------------------------------------------------------------------
has_dc=0
if grep -q 'delegatecall' "$SRC" 2>/dev/null; then has_dc=1; fi
has_fallback=0
if grep -q 'fallback' "$SRC" 2>/dev/null; then has_fallback=1; fi

shape=""
if grep -q "$IMPL_SLOT" "$SRC" 2>/dev/null; then
  shape="eip1967-proxy"                                        # (B) EIP-1967 impl-slot literal
elif [ "$has_fallback" = 1 ] && [ "$has_dc" = 1 ] && grep -qiE 'facet|diamond|selector' "$SRC" 2>/dev/null; then
  shape="diamond-facets"                                       # (C) selector->facet dispatch in fallback()
elif [ "$has_fallback" = 1 ] && [ "$has_dc" = 1 ]; then
  shape="proxy-fallback"                                       # (B) fallback() delegatecall proxy
elif [ "$has_dc" = 1 ]; then
  shape="generic-delegatecall"                                 # (D) `address constant X = 0x..; X.delegatecall(..)`
fi

if [ -z "$shape" ]; then
  say "no core-dependency (delegatecall-singleton) shape in target — EMPTY"
  exit 0
fi

# Registry resolution BY ADDRESS: a recognized shape is resolvable only if the target references a KNOWN
# singleton address in a delegatecall CODE context AND that singleton's real source is locatable in-repo. This
# generalizes the (B)/(D) constant-address case beyond the yearn NAME signal while staying registry-bounded
# (never a guessed address). A diamond's per-selector facets and a bare EIP-1967 runtime slot value carry no
# such constant => they fall through to EMPTY.
# #1771 review — OVER-FIRE hardening: strip `//` line-comments before the address match, so a bare mention of the
# registry address in a COMMENT (not a real constant/delegatecall use) does NOT resolve the singleton. The yearn
# NAME path (case A above) is unaffected; only this secondary by-address branch is tightened to non-comment code.
if [ "$has_dc" = 1 ] && sed 's://.*::' "$SRC" 2>/dev/null | grep -qi "$YEARN_ADDR"; then
  _y="$(locate_yearn_singleton)"
  if [ -n "$_y" ]; then
    say "[$shape] resolved via known-singleton registry (address match $YEARN_ADDR) — $_y"
    emit "$_y" "TokenizedStrategy" "$YEARN_ADDR" "dcs"
    exit 0
  fi
fi

say "[$shape] delegatecall-singleton shape recognized, but no registry match resolves its (source:Name:address) — EMPTY (no guessed address)"
exit 0
