#!/usr/bin/env bash
# demo-candidate-carry.sh — Integration M2 (#1037): each discovered lead carries its OWN target context, so the
# coordinator's LIVE invariant-hunt verifies the RIGHT lead — not one shared operator env.
#
# demo-autonomous-hunt.sh (M1) proves ONE candidate routed through the coordinator's autonomous choice over a
# SINGLE flat env (INV_REPO/INV_TARGET). THIS demo proves M2's per-candidate carrying: it seeds TWO candidates
# in ONE run-autonomous-hunt.sh invocation, each with its OWN `candidate:<id>:{repo,target,match}` context, and
# leaves the flat INV_REPO/INV_TARGET env EMPTY. The ONLY way a verdict can resolve for each candidate is via
# its carried memo (the per-candidate-first, env-fallback resolution in run_invariant_live). It then asserts:
#   (A) the coordinator AUTONOMOUSLY chose invariant-hunt for BOTH candidates (ACTION|invariant-hunt|cand-0 and
#       |cand-1) — the COORDINATOR picked the engine, not the operator;
#   (B) DISPATCH|invariant-hunt|cand-0|confirmed (it ran on the VULNERABLE vault A) AND
#       DISPATCH|invariant-hunt|cand-1|refuted (it ran on the HARDENED twin B).
# The SPLIT verdict is the proof: a single shared env could NOT produce two different verdicts. confirmed-on-A
# + refuted-on-B with the flat env EMPTY means each candidate verified its OWN carried target.
#
# The two vaults are the SAME inflation-vault + hardened-twin demo-autonomous-hunt.sh builds (same contracts,
# same fixture handler+invariant that already produce FINDING/CLEAN there). The verdict is the FUZZER's exit
# code, never the LLM's opinion. A FINDING is a LEAD a human triages, never an auto-submission; this colony
# never posts.
#
# CI has no forge (nor necessarily agentis), so if EITHER is missing this prints a single [SKIP] line and
# exits 0 (mirroring demo-autonomous-hunt.sh / the colony-lint skip convention). Install the toolchain to run:
#   curl -L https://foundry.paradigm.xyz | bash && foundryup    # forge (has built-in invariant fuzzing)
#
# Usage:  dark-factory/demo-candidate-carry.sh
# Exit: 0 = both carried verdicts correct (cand-0->confirmed on A, cand-1->refuted on B, each the coordinator's
#       autonomous choice, with the flat env EMPTY), or tools absent -> SKIP ; non-zero = an assertion failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HERE/run-autonomous-hunt.sh"

FAILS=0
note() { echo "demo-candidate-carry.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

# Skip EARLY (before any work) when the toolchain is missing, so CI without forge reports a clean [SKIP] +
# exit 0 rather than a harness error. agentis is required to drive the substrate coordinator loop.
if ! command -v forge >/dev/null 2>&1; then
  skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run this demo"
  exit 0
fi
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the agentis runtime to drive the substrate coordinator loop"
  exit 0
fi

[ -x "$RUNNER" ] || { note "runner not found / not executable: $RUNNER" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-candidate-carry.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# Build the two tiny foundry repos: VULNERABLE (no virtual offset, project A) and HARDENED (large virtual-share
# offset, project B). Identical to demo-autonomous-hunt.sh's scaffolding so the SAME fixture handler+invariant
# drives both — only the share-pricing math differs (the inflation attack is a MULTI-STEP bug the fuzzer must
# find by sequence). Each lives in its OWN temp foundry project; each is carried by its OWN candidate.
# ----------------------------------------------------------------------------------------------------------
mk_repo() {  # $1 = repo dir, $2 = the `s = ...` deposit pricing line, $3 = the `assets = ...` withdraw line
  _dir="$1"; _depositMath="$2"; _withdrawMath="$3"
  mkdir -p "$_dir/src" "$_dir/test"
  printf '[profile.default]\nsrc = "src"\nout = "out"\n\n[invariant]\nruns = 64\ndepth = 32\nfail_on_revert = false\n' > "$_dir/foundry.toml"
  cat > "$_dir/src/Vault.sol" <<SOL
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Token {
  mapping(address=>uint) public balanceOf; uint public totalSupply;
  function mint(address to,uint a) external { balanceOf[to]+=a; totalSupply+=a; }
  function transfer(address to,uint a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[to]+=a; return true; }
  function transferFrom(address f,address t,uint a) external returns(bool){ balanceOf[f]-=a; balanceOf[t]+=a; return true; }
}
contract Vault {
  Token public asset; uint public totalShares; mapping(address=>uint) public shares;
  uint constant VS = 1000000000000000000000000000; uint constant VA = 1; // virtual offset (1e27); VS=1 in the vulnerable build below
  constructor(Token a){ asset=a; }
  function deposit(uint assets) external returns(uint s){
    uint ta = asset.balanceOf(address(this));
    ${_depositMath}
    asset.transferFrom(msg.sender,address(this),assets);
    shares[msg.sender]+=s; totalShares+=s;
  }
  function withdraw(uint s) external returns(uint assets){
    uint ta = asset.balanceOf(address(this));
    ${_withdrawMath}
    shares[msg.sender]-=s; totalShares-=s;
    asset.transfer(msg.sender,assets);
  }
}
SOL
}

# VULNERABLE (project A): classic ERC4626 share price (no virtual offset) -> donation inflates ta, the next
# deposit mints 0 shares -> the depositor's claim collapses far below their deposit (a MULTI-STEP attack).
mk_repo "$WORK/A" \
  's = totalShares==0 ? assets : assets*totalShares/ta;' \
  'assets = s*ta/totalShares;'

# HARDENED (project B): a large virtual-share/asset offset (the OpenZeppelin ERC4626 decimal-offset mitigation)
# so the share price cannot be inflated enough to round a real depositor to zero shares -> the same attack fails.
mk_repo "$WORK/B" \
  's = assets * (totalShares + VS) / (ta + VA);' \
  'assets = s * (ta + VA) / (totalShares + VS);'

# ----------------------------------------------------------------------------------------------------------
# The PROVEN fixture handler+invariant (from demo-autonomous-hunt.sh), written DIRECTLY into each repo's test/
# dir so each candidate's carried --target points the coordinator's LIVE invariant route at it. A `Handler`
# exposes the protocol's actions as bounded actor functions (attackerSeed / attackerDonate / victimDeposit)
# and a DEEP invariant (`invariant_victim_not_robbed`). forge-std-free: targets via the `targetContracts()`
# StdInvariant ABI forge auto-discovers, asserted with plain `require`.
# ----------------------------------------------------------------------------------------------------------
write_fixture() {  # $1 = repo dir
  cat > "$1/test/Inv.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Vault, Token} from "../src/Vault.sol";

// The protocol's actions as a real attacker/user calls them, with fuzzed inputs bounded to realistic ranges.
contract Handler {
    Vault public v; Token public t;
    uint public victimDeposited;   // total assets the honest victim has put in
    uint public victimShares;      // shares the victim holds
    constructor(Vault _v, Token _t){ v=_v; t=_t; }
    // forge-std-free bound: keep a fuzzed uint inside [lo, hi] without the forge-std `bound` cheatcode.
    function _bound(uint x, uint lo, uint hi) internal pure returns (uint) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
    function attackerSeed() public { t.mint(address(this), 1); v.deposit(1); }              // seed 1 share
    function attackerDonate(uint a) public { a = _bound(a, 1, 1e24); t.mint(address(v), a); } // direct transfer, no shares
    function victimDeposit(uint a) public {
        a = _bound(a, 1e6, 1e18);
        t.mint(address(this), a);
        uint s = v.deposit(a);
        victimDeposited += a; victimShares += s;
    }
}

// StdInvariant ABI forge auto-discovers: targetContracts() lists the addresses the fuzzer drives. No forge-std.
abstract contract InvBase {
    address[] private _targets;
    function targetContracts() public view returns (address[] memory) { return _targets; }
    function _target(address a) internal { _targets.push(a); }
}

contract VaultInvariantTest is InvBase {
    Vault v; Token t; Handler h;
    function setUp() public { t=new Token(); v=new Vault(t); h=new Handler(v,t); _target(address(h)); }
    // DEEP invariant: the victim's CLAIM on the vault (shares * vaultBalance / totalShares) must always be
    // worth >= what they deposited, minus dust. The inflation attack makes a victim deposit mint 0 shares,
    // so their claim collapses far below their deposit -> a SEQUENCE the fuzzer must find.
    function invariant_victim_not_robbed() public view {
        uint vd = h.victimDeposited();
        if (vd == 0) return;
        uint ts = v.totalShares();
        uint claim = ts == 0 ? 0 : h.victimShares() * t.balanceOf(address(v)) / ts;
        require(claim + 1e6 >= vd, "victim robbed");   // claim within dust(1e6) of deposit
    }
}
SOL
}
write_fixture "$WORK/A"
write_fixture "$WORK/B"

# ----------------------------------------------------------------------------------------------------------
# ONE run-autonomous-hunt.sh invocation, TWO candidates, each carrying its OWN context. CRITICAL RIGOR: we do
# NOT pass --repo/--target, AND we wipe the flat INV_REPO/INV_TARGET/INV_MATCH from the environment, so the
# ONLY way each candidate can resolve a target is via its carried `candidate:<id>:*` memo. cand-0 -> A
# (vulnerable), cand-1 -> B (hardened). A fixed --seed makes the search reproducible.
# ----------------------------------------------------------------------------------------------------------
OUT="$WORK/out"
SEED=1
note "driving ONE coordinator loop with TWO carried candidates (flat INV_REPO/INV_TARGET EMPTY) ..."
env -u INV_REPO -u INV_TARGET -u INV_MATCH \
  "$RUNNER" \
    --candidate "cand-0|$WORK/A|$WORK/A/test/Inv.t.sol|invariant" \
    --candidate "cand-1|$WORK/B|$WORK/B/test/Inv.t.sol|invariant" \
    --backend mock --runs 256 --depth 64 --seed "$SEED" --out "$OUT" >"$OUT.log" 2>&1
RC=$?

LOG="$OUT/run/orchestrate.log"
if [ "$RC" -ne 0 ] || [ ! -f "$LOG" ]; then
  bad "run-autonomous-hunt.sh did not complete (exit $RC); runner log:"
  sed 's/^/        | /' "$OUT.log" 2>/dev/null | tail -30
  note "DEMO FAILED — the multi-candidate run did not produce an orchestrate log." >&2
  exit 1
fi

# Proof that the flat env really WAS empty for this run (the runner forwards INV_REPO/INV_TARGET from its own
# environment; env -u above wiped them, and no --repo/--target was passed). Surface it for the trail.
note "flat env this run: INV_REPO=[${INV_REPO:-}] INV_TARGET=[${INV_TARGET:-}] (both EMPTY -> verdicts can ONLY come from carried memos)"
note "autonomous decision trail:"
grep -E '^(ACTION|DISPATCH)\|invariant-hunt\|' "$LOG" | sed 's/^/        | /'

# (A) the coordinator AUTONOMOUSLY chose invariant-hunt for BOTH candidates (not the operator).
for cid in cand-0 cand-1; do
  if grep -qE "^ACTION\|invariant-hunt\|$cid\|" "$LOG"; then
    ok "(A) coordinator AUTONOMOUSLY chose invariant-hunt for $cid (not the operator)"
  else
    bad "(A) no 'ACTION|invariant-hunt|$cid|' line — the coordinator did not choose the engine for $cid"
    sed 's/^/        | /' "$LOG" 2>/dev/null | tail -30
  fi
done

# (B) the SPLIT verdict — each candidate's carried target produced its OWN verdict. A shared env could not.
assert_dispatch() {  # $1 = candidate id, $2 = expected verdict, $3 = which carried project
  _cid="$1"; _want="$2"; _proj="$3"
  _line="$(grep -E "^DISPATCH\|invariant-hunt\|$_cid\|" "$LOG" | head -1)"
  case "$_line" in
    DISPATCH\|invariant-hunt\|"$_cid"\|"$_want")
      ok "(B) DISPATCH|invariant-hunt|$_cid|$_want — ran on its carried $_proj (the LIVE fuzzer's verdict)" ;;
    *)
      bad "(B) expected 'DISPATCH|invariant-hunt|$_cid|$_want', got '$_line'"
      note "  the LIVE-route message + verdict the fuzzer produced for $_cid:"
      grep -E "LIVE invariant-hunt of '$_cid'|FORGE-INVARIANT:" "$LOG" 2>/dev/null | sed 's/^/        | /' ;;
  esac
}
assert_dispatch "cand-0" "confirmed" "VULNERABLE vault A"
assert_dispatch "cand-1" "refuted"   "HARDENED twin B"

echo
echo "=================================================================================="
if [ "$FAILS" -eq 0 ]; then
  note "PROVEN. ONE coordinator loop, TWO pending leads, each carrying its OWN context via the durable"
  note "candidate:<id>:{repo,target} memo — with the flat INV_REPO/INV_TARGET env EMPTY. The coordinator"
  note "autonomously chose invariant-hunt for BOTH and the LIVE fuzzer returned a SPLIT verdict: cand-0 ->"
  note "confirmed (it ran on the VULNERABLE vault A) and cand-1 -> refuted (it ran on the HARDENED twin B)."
  note "A shared env could NOT produce two different verdicts — the split PROVES per-candidate carrying."
  note "The verdict is the FUZZER's exit code, never the LLM's; submission stays human-gated; this colony"
  note "never posts."
  exit 0
fi
note "DEMO FAILED — $FAILS assertion(s) did not hold (see above)." >&2
exit 1
