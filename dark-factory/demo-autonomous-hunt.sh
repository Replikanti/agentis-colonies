#!/usr/bin/env bash
# demo-autonomous-hunt.sh — Integration M1 (#1037): the self-orchestrating coordinator AUTONOMOUSLY chooses
# and LIVE-runs the stateful-invariant fuzzer, end-to-end, finding the multi-step bug.
#
# demo-invariant-hunt.sh proves the FUZZER engine (an operator calls run-invariant-hunt.sh directly). THIS
# demo proves the INTEGRATION: the operator does NOT call the fuzzer — they hand the coordinator a target and
# the coordinator CHOOSES (by its evolving policy, a policy-weighted argmax — never a fixed sequence) to route
# the candidate through the `invariant-hunt` action, which runs the REAL forge invariant fuzzer and maps its
# exit code to the SOUND outcome (FINDING -> confirmed, CLEAN -> refuted, HARNESS_ERROR -> dry). For EACH of
# two vaults it drives run-autonomous-hunt.sh and asserts:
#   (A) the coordinator AUTONOMOUSLY emitted ACTION|invariant-hunt| for the pending candidate — proving the
#       COORDINATOR chose the engine, not the operator;
#   (B) DISPATCH|invariant-hunt|...|confirmed for the VULNERABLE vault and ...|refuted for the HARDENED twin —
#       the LIVE fuzzer's verdict, never the LLM's;
#   (C) a learn / policy_update for invariant-hunt referencing the verdict appears in the store on the step
#       AFTER the verdict — proving outcome -> policy.
#
# The two vaults are the SAME inflation-vault + hardened-twin demo-invariant-hunt.sh uses (same contracts,
# same fixture handler+invariant that already produce FINDING/CLEAN there). The verdict is the FUZZER's exit
# code, never the LLM's opinion — that is the whole point. A FINDING is a LEAD a human triages, never an
# auto-submission; this colony never posts.
#
# CI has no forge (nor necessarily agentis), so if EITHER is missing this prints a single [SKIP] line and
# exits 0 (mirroring demo-invariant-hunt.sh / the colony-lint skip convention). Install the toolchain to run:
#   curl -L https://foundry.paradigm.xyz | bash && foundryup    # forge (has built-in invariant fuzzing)
#
# Usage:  dark-factory/demo-autonomous-hunt.sh
# Exit: 0 = both verdicts correct (FINDING->confirmed on vulnerable, CLEAN->refuted on hardened, each with the
#       coordinator's autonomous choice + the outcome->policy attribution), or tools absent -> SKIP ; non-zero
#       = an assertion failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HERE/run-autonomous-hunt.sh"

FAILS=0
note() { echo "demo-autonomous-hunt.sh: $*"; }
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-autonomous-hunt.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# Build the two tiny foundry repos: VULNERABLE (no virtual offset) and HARDENED (large virtual-share offset).
# Identical to demo-invariant-hunt.sh's scaffolding so the SAME fixture handler+invariant drives both — only
# the share-pricing math differs (the inflation attack is a MULTI-STEP bug the fuzzer must find by sequence).
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

# VULNERABLE: classic ERC4626 share price (no virtual offset) -> donation inflates ta, the next deposit mints
# 0 shares -> the depositor's claim collapses far below their deposit (a MULTI-STEP donation/inflation attack).
mk_repo "$WORK/vuln" \
  's = totalShares==0 ? assets : assets*totalShares/ta;' \
  'assets = s*ta/totalShares;'

# HARDENED: a large virtual-share/asset offset (the OpenZeppelin ERC4626 decimal-offset mitigation) so the
# share price cannot be inflated enough to round a real depositor to zero shares -> the same attack fails.
mk_repo "$WORK/hard" \
  's = assets * (totalShares + VS) / (ta + VA);' \
  'assets = s * (ta + VA) / (totalShares + VS);'

# ----------------------------------------------------------------------------------------------------------
# The PROVEN fixture handler+invariant (from demo-invariant-hunt.sh), written DIRECTLY into each repo's test/
# dir so run-autonomous-hunt.sh's --target points the coordinator's LIVE invariant route at it. A `Handler`
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
write_fixture "$WORK/vuln"
write_fixture "$WORK/hard"

# Drive one vault through the FULL coordinator loop (the operator hands the coordinator the target; the
# coordinator CHOOSES invariant-hunt and the REAL fuzzer judges). A fixed --seed makes the search reproducible.
# $1 = repo, $2 = output dir. Captures the runner's stderr (the decision trail) + the run log into $2.log.
SEED=1
run_one() {
  "$RUNNER" --repo "$1" --target "$1/test/Inv.t.sol" --match invariant \
            --backend mock --runs 256 --depth 64 --seed "$SEED" --steps 2 --out "$2" >"$2.log" 2>&1
}

# The full orchestrate run log (where the ACTION|/DISPATCH| trail + the LIVE-route message land).
run_log() { printf '%s' "$1/run/orchestrate.log"; }
# The experience store the loop's learn() rows land in (for the outcome->policy attribution check).
exp_store() { printf '%s' "$1/run/.agentis/experience/main.jsonl"; }

assert_vault() {  # $1 = repo, $2 = out dir, $3 = expected verdict (confirmed|refuted), $4 = label
  _repo="$1"; _out="$2"; _want="$3"; _label="$4"
  note "driving the $_label vault -> the coordinator CHOOSES invariant-hunt -> REAL forge fuzzer -> verdict ..."
  run_one "$_repo" "$_out"; _rc=$?
  _log="$(run_log "$_out")"
  _exp="$(exp_store "$_out")"
  if [ "$_rc" -ne 0 ] || [ ! -f "$_log" ]; then
    bad "$_label: run-autonomous-hunt.sh did not complete (exit $_rc); log:"
    sed 's/^/        | /' "$_out.log" 2>/dev/null | tail -25
    return
  fi
  # (A) the coordinator AUTONOMOUSLY chose invariant-hunt for the pending candidate.
  _action="$(grep -E '^ACTION\|invariant-hunt\|' "$_log" | head -1)"
  if [ -n "$_action" ]; then ok "$_label (A): coordinator AUTONOMOUSLY chose invariant-hunt (not the operator)"
  else bad "$_label (A): no 'ACTION|invariant-hunt|' line — the coordinator did not choose the engine"; sed 's/^/        | /' "$_log" 2>/dev/null | tail -25; fi
  # (B) the LIVE fuzzer's verdict crossed back as the expected DISPATCH| outcome.
  _dispatch="$(grep -E '^DISPATCH\|invariant-hunt\|' "$_log" | head -1)"
  case "$_dispatch" in
    DISPATCH\|invariant-hunt\|cand-0\|"$_want")
      ok "$_label (B): DISPATCH|invariant-hunt|cand-0|$_want (the LIVE fuzzer's verdict, never the LLM's)" ;;
    *)
      bad "$_label (B): expected 'DISPATCH|invariant-hunt|cand-0|$_want', got '$_dispatch'"
      note "  the LIVE-route message + verdict the fuzzer produced:"
      grep -E 'LIVE invariant-hunt|FORGE-INVARIANT:' "$_log" 2>/dev/null | sed 's/^/        | /' ;;
  esac
  # (C) the outcome -> policy attribution: a learn row for invariant-hunt referencing the verdict appears in
  # the store on the step AFTER the verdict (step 1 attributes step 0's invariant-hunt). The DISPATCH outcome
  # (confirmed/refuted/dry) is what the attribution records.
  if [ -f "$_exp" ] && grep -q '"in":"invariant-hunt"' "$_exp" && grep -qE "outcome of previous invariant-hunt .* was (confirmed|refuted|dry)" "$_exp"; then
    ok "$_label (C): outcome -> policy: a learn() for invariant-hunt referencing the verdict is in the store"
  else
    bad "$_label (C): no invariant-hunt outcome->policy learn row in the experience store ($_exp)"
    [ -f "$_exp" ] && grep '"action":"coordinator"' "$_exp" 2>/dev/null | sed 's/^/        | /' | tail -5
  fi
}

echo "=================================================================================="
echo " (1) VULNERABLE vault: coordinator CHOOSES invariant-hunt -> FINDING -> confirmed"
echo "=================================================================================="
assert_vault "$WORK/vuln" "$WORK/vuln-out" "confirmed" "VULNERABLE"

echo
echo "=================================================================================="
echo " (2) HARDENED twin: same autonomous route, CLEAN -> refuted (no false positive on the fix)"
echo "=================================================================================="
assert_vault "$WORK/hard" "$WORK/hard-out" "refuted" "HARDENED"

echo
echo "=================================================================================="
if [ "$FAILS" -eq 0 ]; then
  note "PROVEN. The operator handed the coordinator a target and the COORDINATOR autonomously CHOSE the"
  note "stateful-invariant fuzzer (ACTION|invariant-hunt, by its evolving policy — not a fixed sequence) and"
  note "LIVE-ran it: the VULNERABLE vault's inflation attack -> FINDING -> confirmed (a real multi-step bug),"
  note "the HARDENED twin -> CLEAN -> refuted (no false positive). The verdict is the FUZZER's exit code,"
  note "never the LLM's opinion; the outcome evolves the coordinator's policy. Submission stays human-gated;"
  note "this colony never posts."
  exit 0
fi
note "DEMO FAILED — $FAILS assertion(s) did not hold (see above)." >&2
exit 1
