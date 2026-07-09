#!/usr/bin/env bash
# demo-pattern-memory.sh — Integration M3 (#1037, FINAL milestone): the federation INVENTS its own attack
# methods, STORES the winning ones in the pattern DAG, and RECALLS them to seed future hunts — the loop the
# user described, closed end-to-end.
#
# M1 made the coordinator AUTONOMOUSLY choose + LIVE-run the stateful-invariant fuzzer; M2 let each lead carry
# its OWN context. M3 adds the PATTERN MEMORY: a winning invariant pattern (one that produced a FINDING) is
# PERSISTED to the DAG pattern memory (the `invpat:*` namespace, reusing the same `dag_put`/`recall_latest`/
# `memo_write` primitives as the `bugpat:*` fork-matcher) and RECALLED to seed a LATER hunt on the same bug
# class — and `invent-method` can propose a NEW invariant class the next hunt then uses.
#
# This demo proves the MEMORY LOOP across three legs, ALL through `run-autonomous-hunt.sh --pattern-store` (the
# coordinator's autonomous choice + the prover's persist/recall), with a PERSISTENT store S shared across runs:
#   (1) Run 1 on the VULNERABLE vault A (class C1) -> FINDING -> the winning pattern is PERSISTED to S
#       (`invpat:latest:C1` present in S + an `INVPAT-LEARNED|C1|...` line in the run log).
#   (2) Run 2 on a STRUCTURALLY-DIFFERENT vulnerable vault B of the SAME class C1 -> the prover RECALLS the
#       stored pattern (`RECALL-INVPAT|C1|...` in the run log) and B -> FINDING. discovered -> stored in the
#       DAG -> recalled -> reused ACROSS targets.
#   (3) invent-method leg: a deterministic method-inventor proposal (a `METHOD|...` fixture) seeds a NEW
#       invariant class as `invpat:invented:C1`; the next hunt's prover consults it as a generation hint
#       (`RECALL-INVPAT|C1|METHOD|...`) and finds the bug -> FINDING. the self-invents feed.
#
# HONEST FRAMING. The claim is the MEMORY LOOP works (persist / recall / reuse), NOT that recall is strictly
# necessary for the fuzzer to find B — both vaults are vulnerable, so each would FIND on its own. What the demo
# proves is that the discovered pattern is STORED in the DAG and RECALLED to seed the later hunt, observably.
# The verdict is the FUZZER's exit code, never the LLM's; a FINDING is a LEAD a human triages, never an
# auto-submission; this colony never posts.
#
# CI has no forge (nor necessarily agentis), so if EITHER is missing this prints a single [SKIP] line and
# exits 0 (mirroring demo-autonomous-hunt.sh / demo-candidate-carry.sh). Install the toolchain to run:
#   curl -L https://foundry.paradigm.xyz | bash && foundryup    # forge (has built-in invariant fuzzing)
#
# Usage:  dark-factory/demo-pattern-memory.sh
# Exit: 0 = the memory loop held (persist on A, recall+reuse on B, invent-method seeds + steers the next hunt),
#       or tools absent -> SKIP ; non-zero = an assertion failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HERE/run-autonomous-hunt.sh"

FAILS=0
note() { echo "demo-pattern-memory.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

# Skip EARLY (before any work) when the toolchain is missing, so CI without forge reports a clean [SKIP] +
# exit 0 rather than a harness error. agentis is required to drive the substrate coordinator loop + the store.
if ! command -v forge >/dev/null 2>&1; then
  skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run this demo"
  exit 0
fi
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the agentis runtime to drive the substrate coordinator loop"
  exit 0
fi

[ -x "$RUNNER" ] || { note "runner not found / not executable: $RUNNER" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-pattern-memory.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# Build the foundry repos: TWO structurally-different VULNERABLE vaults of the SAME class C1 (the ERC4626
# inflation attack). A and B differ in the share-pricing expression's STRUCTURE (spacing/parenthesization) but
# are the same vulnerable class — so the SAME deep invariant catches both, and B's pattern is a genuine
# transfer target for A's recalled pattern. Same scaffolding demo-autonomous-hunt.sh / demo-candidate-carry.sh
# use, so the SAME fixture handler+invariant drives both. C is a third copy for the invent-method leg.
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
  uint constant VS = 1000000000000000000000000000; uint constant VA = 1; // virtual offset (unused in the vulnerable builds)
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

# VULNERABLE vault A: classic ERC4626 share price (no virtual offset) -> donation inflates ta, the next
# deposit mints 0 shares -> the depositor's claim collapses far below their deposit (a MULTI-STEP attack).
mk_repo "$WORK/A" \
  's = totalShares==0 ? assets : assets*totalShares/ta;' \
  'assets = s*ta/totalShares;'

# VULNERABLE vault B: SAME class C1 (no virtual offset, same inflation bug) but a structurally-different
# pricing expression (fully parenthesized, spaced) — proving the recalled pattern transfers across a
# differently-shaped target, not a byte-identical twin.
mk_repo "$WORK/B" \
  's = totalShares == 0 ? assets : (assets * totalShares) / ta;' \
  'assets = (s * ta) / totalShares;'

# VULNERABLE vault C: a third copy for the invent-method leg (a fresh store so the invented hint is the recall
# descriptor, not a prior FINDING).
mk_repo "$WORK/C" \
  's = totalShares==0 ? assets : assets*totalShares/ta;' \
  'assets = s*ta/totalShares;'

# ----------------------------------------------------------------------------------------------------------
# The PROVEN fixture handler+invariant (from demo-autonomous-hunt.sh / demo-candidate-carry.sh), written
# DIRECTLY into each repo's test/ dir so each --target points the coordinator's LIVE invariant route at it.
# ----------------------------------------------------------------------------------------------------------
write_fixture() {  # $1 = repo dir
  cat > "$1/test/Inv.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Vault, Token} from "../src/Vault.sol";

contract Handler {
    Vault public v; Token public t;
    uint public victimDeposited;
    uint public victimShares;
    constructor(Vault _v, Token _t){ v=_v; t=_t; }
    function _bound(uint x, uint lo, uint hi) internal pure returns (uint) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
    function attackerSeed() public { t.mint(address(this), 1); v.deposit(1); }
    function attackerDonate(uint a) public { a = _bound(a, 1, 1e24); t.mint(address(v), a); }
    function victimDeposit(uint a) public {
        a = _bound(a, 1e6, 1e18);
        t.mint(address(this), a);
        uint s = v.deposit(a);
        victimDeposited += a; victimShares += s;
    }
}

abstract contract InvBase {
    address[] private _targets;
    function targetContracts() public view returns (address[] memory) { return _targets; }
    function _target(address a) internal { _targets.push(a); }
}

contract VaultInvariantTest is InvBase {
    Vault v; Token t; Handler h;
    function setUp() public { t=new Token(); v=new Vault(t); h=new Handler(v,t); _target(address(h)); }
    function invariant_victim_not_robbed() public view {
        uint vd = h.victimDeposited();
        if (vd == 0) return;
        uint ts = v.totalShares();
        uint claim = ts == 0 ? 0 : h.victimShares() * t.balanceOf(address(v)) / ts;
        require(claim + 1e6 >= vd, "victim robbed");
    }
}
SOL
}
write_fixture "$WORK/A"
write_fixture "$WORK/B"
write_fixture "$WORK/C"

# The deterministic method-inventor proposal for the invent-method leg (the same `METHOD|...` shape
# method-inventor.ag emits, used OFFLINE so the wiring is provable without an LLM).
cat > "$WORK/method.txt" <<'METHOD_EOF'
METHOD|seq-rounding-drift|C1|fuzz multi-call deposit/withdraw sequences asserting no-depositor-loss under any interleave|forge invariant over a Handler exposing the protocol actions as bounded actors|a control vault with a known share-rounding-drift bug must FAIL the invariant while the hardened twin holds
METHOD_EOF

SEED=1
# Drive one target through the FULL coordinator loop with a PERSISTENT pattern store. $1=repo, $2=out dir,
# $3=pattern store dir, $4 (optional) = a method-fixture for the invent-method leg.
run_one() {
  _repo="$1"; _out="$2"; _store="$3"; _method="${4:-}"
  if [ -n "$_method" ]; then
    "$RUNNER" --repo "$_repo" --target "$_repo/test/Inv.t.sol" --match invariant \
              --backend mock --runs 256 --depth 64 --seed "$SEED" --steps 2 \
              --pattern-store "$_store" --method-fixture "$_method" --out "$_out" >"$_out.log" 2>&1
  else
    "$RUNNER" --repo "$_repo" --target "$_repo/test/Inv.t.sol" --match invariant \
              --backend mock --runs 256 --depth 64 --seed "$SEED" --steps 2 \
              --pattern-store "$_store" --out "$_out" >"$_out.log" 2>&1
  fi
}
run_log() { printf '%s' "$1/run/orchestrate.log"; }

# ==========================================================================================================
# (1) Run 1 — VULNERABLE vault A -> FINDING -> the winning pattern is PERSISTED to the shared store S.
# ==========================================================================================================
STORE="$WORK/pattern-store"
echo "=================================================================================="
echo " (1) RUN 1: vault A (class C1) -> coordinator CHOOSES invariant-hunt -> FINDING -> PERSIST to DAG"
echo "=================================================================================="
note "driving vault A through the coordinator loop with --pattern-store $STORE ..."
run_one "$WORK/A" "$WORK/A-out" "$STORE"; RC1=$?
LOG1="$(run_log "$WORK/A-out")"
if [ "$RC1" -ne 0 ] || [ ! -f "$LOG1" ]; then
  bad "Run 1 did not complete (exit $RC1); runner log:"
  sed 's/^/        | /' "$WORK/A-out.log" 2>/dev/null | tail -25
  note "DEMO FAILED — Run 1 produced no orchestrate log." >&2
  exit 1
fi
# A: the coordinator autonomously chose invariant-hunt and the fuzzer confirmed (the bug reproduced).
if grep -qE '^ACTION\|invariant-hunt\|cand-0\|' "$LOG1" && grep -qE '^DISPATCH\|invariant-hunt\|cand-0\|confirmed' "$LOG1"; then
  ok "(1a) Run 1: coordinator AUTONOMOUSLY chose invariant-hunt on A and the LIVE fuzzer CONFIRMED (FINDING)"
else
  bad "(1a) Run 1: missing ACTION/DISPATCH confirmed for A"
  grep -E '^(ACTION|DISPATCH)\|invariant-hunt\|' "$LOG1" | sed 's/^/        | /'
fi
# B: the winning pattern was PERSISTED to the DAG memory (the INVPAT-LEARNED line + the invpat:latest:C1 memo).
if grep -qE '^INVPAT-LEARNED\|C1\|' "$LOG1"; then
  ok "(1b) Run 1: the prover PERSISTED the winning invariant pattern (INVPAT-LEARNED|C1|... in the run log)"
else
  bad "(1b) Run 1: no INVPAT-LEARNED|C1| line — the winning pattern was not persisted"
  grep -E 'INVPAT|RECALL' "$LOG1" | sed 's/^/        | /'
fi
LATEST="$( ( cd "$STORE" && agentis memo get invpat:latest:C1 ) 2>/dev/null )"
if [ -n "$LATEST" ]; then
  ok "(1c) Run 1: invpat:latest:C1 is present in the PERSISTENT store S  ->  [$LATEST]"
else
  bad "(1c) Run 1: invpat:latest:C1 is absent from the persistent store S ($STORE)"
  ( cd "$STORE" && agentis memo list 2>/dev/null ) | grep -i invpat | sed 's/^/        | /'
fi

# ==========================================================================================================
# (2) Run 2 — STRUCTURALLY-DIFFERENT vulnerable vault B of the SAME class C1, SAME store S -> the stored
#     pattern is RECALLED to seed B's hunt, and B -> FINDING. discovered -> stored -> recalled -> reused.
# ==========================================================================================================
echo
echo "=================================================================================="
echo " (2) RUN 2: vault B (same class C1, different shape), same store S -> RECALL the stored pattern -> FINDING"
echo "=================================================================================="
note "driving vault B through the coordinator loop with the SAME --pattern-store $STORE ..."
run_one "$WORK/B" "$WORK/B-out" "$STORE"; RC2=$?
LOG2="$(run_log "$WORK/B-out")"
if [ "$RC2" -ne 0 ] || [ ! -f "$LOG2" ]; then
  bad "Run 2 did not complete (exit $RC2); runner log:"
  sed 's/^/        | /' "$WORK/B-out.log" 2>/dev/null | tail -25
  note "DEMO FAILED — Run 2 produced no orchestrate log." >&2
  exit 1
fi
# The proof of the loop: the stored pattern from A was RECALLED to seed B's hunt (the prover's RECALL-INVPAT).
if grep -qE '^RECALL-INVPAT\|C1\|' "$LOG2"; then
  RECALLED="$(grep -E '^RECALL-INVPAT\|C1\|' "$LOG2" | head -1)"
  ok "(2a) Run 2: the stored pattern was RECALLED to seed B's hunt  ->  $RECALLED"
else
  bad "(2a) Run 2: no RECALL-INVPAT|C1| line — the stored pattern was not recalled across runs"
  grep -E 'INVPAT|RECALL' "$LOG2" | sed 's/^/        | /'
fi
# B reproduced (the recalled-pattern-seeded hunt still finds the bug on the differently-shaped target).
if grep -qE '^DISPATCH\|invariant-hunt\|cand-0\|confirmed' "$LOG2"; then
  ok "(2b) Run 2: vault B -> DISPATCH|invariant-hunt|cand-0|confirmed (FINDING on the recalled-pattern target)"
else
  bad "(2b) Run 2: vault B did not confirm"
  grep -E '^DISPATCH\|invariant-hunt\|' "$LOG2" | sed 's/^/        | /'
fi

# ==========================================================================================================
# (3) invent-method leg — a method-inventor proposal seeds a NEW invariant class (invpat:invented:C1) in a
#     FRESH store; the next hunt's prover consults it as a generation hint and finds the bug.
# ==========================================================================================================
echo
echo "=================================================================================="
echo " (3) INVENT-METHOD: a proposed NEW invariant class (fixture) seeds the next hunt -> FINDING"
echo "=================================================================================="
INVENT_STORE="$WORK/invent-store"
note "driving vault C with a method-inventor proposal (--method-fixture) into a fresh store ..."
run_one "$WORK/C" "$WORK/C-out" "$INVENT_STORE" "$WORK/method.txt"; RC3=$?
LOG3="$(run_log "$WORK/C-out")"
if [ "$RC3" -ne 0 ] || [ ! -f "$LOG3" ]; then
  bad "invent-method leg did not complete (exit $RC3); runner log:"
  sed 's/^/        | /' "$WORK/C-out.log" 2>/dev/null | tail -25
else
  # The proposed class was seeded as invpat:invented:C1 in the store.
  INVENTED="$( ( cd "$INVENT_STORE" && agentis memo get invpat:invented:C1 ) 2>/dev/null )"
  if [ -n "$INVENTED" ]; then
    ok "(3a) invent-method seeded a NEW invariant class as invpat:invented:C1 in the store"
  else
    bad "(3a) invent-method did not seed invpat:invented:C1"
    ( cd "$INVENT_STORE" && agentis memo list 2>/dev/null ) | grep -i invent | sed 's/^/        | /'
  fi
  # The next hunt's prover consulted the invented class as a generation hint (the RECALL-INVPAT carries the METHOD line).
  if grep -qE '^RECALL-INVPAT\|C1\|METHOD\|' "$LOG3"; then
    ok "(3b) the next hunt's generation CONSULTED the invented class (RECALL-INVPAT|C1|METHOD|...)"
  else
    bad "(3b) the invented class was not consulted by the next hunt's generation"
    grep -E 'INVPAT|RECALL' "$LOG3" | sed 's/^/        | /'
  fi
  # And the hunt still found the bug.
  if grep -qE '^DISPATCH\|invariant-hunt\|cand-0\|confirmed' "$LOG3"; then
    ok "(3c) the invent-method-seeded hunt found the bug -> DISPATCH|invariant-hunt|cand-0|confirmed"
  else
    bad "(3c) the invent-method-seeded hunt did not confirm"
    grep -E '^DISPATCH\|invariant-hunt\|' "$LOG3" | sed 's/^/        | /'
  fi
fi

echo
echo "=================================================================================="
if [ "$FAILS" -eq 0 ]; then
  note "PROVEN. The MEMORY LOOP is closed end-to-end: Run 1 on vault A produced a FINDING and the winning"
  note "invariant pattern was PERSISTED to the DAG pattern memory (invpat:latest:C1 in the shared store);"
  note "Run 2 on a structurally-different vault B of the SAME class RECALLED that stored pattern to seed its"
  note "hunt (RECALL-INVPAT|C1|...) and B -> FINDING — discovered -> stored in the DAG -> recalled -> reused"
  note "ACROSS targets. The invent-method leg seeds a NEW proposed invariant class (invpat:invented:C1) that"
  note "the next hunt's generation consults. HONEST scope: the claim is that the memory loop works (persist/"
  note "recall/reuse), not that recall is necessary for the fuzzer to find B. The verdict is the FUZZER's"
  note "exit code, never the LLM's; submission stays human-gated; this colony never posts."
  exit 0
fi
note "DEMO FAILED — $FAILS assertion(s) did not hold (see above)." >&2
exit 1
