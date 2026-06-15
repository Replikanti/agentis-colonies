#!/usr/bin/env bash
# demo-fm3-oracle.sh — FM3 (#1057, epic #1041): oracle / price perturbation as a STATEFUL FUZZ DIMENSION.
#
# FM1 forks real state and FM2 composes protocols, but the price/oracle stayed STATIC — so the flashloan-
# funded price-manipulation drain (the class where bounty money concentrates) was unreachable. FM3 lets the
# fuzzer MOVE the price within attacker-reachable bounds as one of its actions, so an oracle-dependent
# invariant is exercised under manipulation.
#
# This demo proves the dimension on a two-sided calibration pair through the REAL forge-invariant.sh gate:
#   - a constant-product Pool whose spot price the Handler can push UP (swap quote-in) — the manipulation lever;
#   - LendVuln values collateral at the LIVE spot -> the fuzzer sequences manipulate-price -> borrow to
#     over-lend far past the collateral's HONEST value -> the deep solvency invariant BREAKS (FINDING);
#   - LendSafe prices off a fixed anchor + a 1% deviation bound that reverts a manipulated borrow -> only
#     honest borrows succeed -> the SAME invariant HOLDS (CLEAN). The twin proves 0 false-VERIFIED: the
#     dimension fires on the bug and stays silent on the hardened control.
# The verdict is the FUZZER's (forge pass/fail + shrunk witness), never an LLM.
#
# Offline + deterministic (fixed --seed); no network. SKIPs cleanly if forge is not installed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/evm-harness/forge-invariant.sh"

FAIL=0
pass() { echo "demo-fm3-oracle.sh: [PASS] $1"; }
fail() { echo "demo-fm3-oracle.sh: [FAIL] $1" >&2; FAIL=1; }
skip() { echo "demo-fm3-oracle.sh: [SKIP] $1"; }

if ! command -v forge >/dev/null 2>&1; then
  if [ -x "$HOME/.foundry/bin/forge" ]; then PATH="$HOME/.foundry/bin:$PATH"; else
    skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run this calibration"; exit 0
  fi
fi
[ -x "$GATE" ] || { echo "demo-fm3-oracle.sh: gate not executable: $GATE" >&2; exit 3; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PROJ="$WORK/proj"; mkdir -p "$PROJ/src" "$PROJ/test"
printf '[profile.default]\nsrc = "src"\nout = "out"\n\n[invariant]\nruns = 200\ndepth = 48\nfail_on_revert = false\n' > "$PROJ/foundry.toml"

# --- The price source + two lenders (collateral token0, quote token1). Self-contained, forge-std-free. ---
cat > "$PROJ/src/Oracle.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// A minimal constant-product pool. Spot price = quote per collateral = r1*1e18/r0. swapQuoteIn pushes the
/// collateral price UP (r1 up, r0 down) — the attacker's manipulation lever (the EVM analog of a flashloan
/// -funded swap). swap0In pushes it down. No TWAP — the instantaneous reserves ARE the price.
contract Pool {
    uint256 public r0; // collateral reserve
    uint256 public r1; // quote reserve
    constructor(uint256 a, uint256 b) { r0 = a; r1 = b; }
    function price() public view returns (uint256) { return (r1 * 1e18) / r0; }
    function swapQuoteIn(uint256 amt1) external { uint256 k = r0 * r1; r1 += amt1; r0 = k / r1; }
    function swap0In(uint256 amt0) external { uint256 k = r0 * r1; r0 += amt0; r1 = k / r0; }
}

interface ILend { function borrow(uint256 collateral) external returns (uint256); }

/// INSECURE — values collateral at the LIVE spot price. An attacker who pushed the spot up in the same
/// sequence borrows far more than the collateral is honestly worth.
contract LendVuln is ILend {
    Pool public pool; uint256 public debt;
    constructor(Pool p) { pool = p; }
    function borrow(uint256 collateral) external returns (uint256 b) {
        b = (collateral * pool.price()) / 1e18; debt += b; return b;
    }
}

/// SECURE — prices off a fixed anchor (a TWAP stand-in) and rejects a borrow when the live spot deviates
/// beyond a tight bound, so a same-sequence manipulation can never be trusted. Honest borrows still pass.
contract LendSafe is ILend {
    Pool public pool; uint256 public debt; uint256 public immutable anchor;
    uint256 public constant MAX_DEV_BPS = 100; // 1%
    constructor(Pool p) { pool = p; anchor = p.price(); }
    function borrow(uint256 collateral) external returns (uint256 b) {
        uint256 s = pool.price();
        uint256 hi = (anchor * (10000 + MAX_DEV_BPS)) / 10000;
        uint256 lo = (anchor * (10000 - MAX_DEV_BPS)) / 10000;
        require(s <= hi && s >= lo, "price out of bounds");
        b = (collateral * anchor) / 1e18; debt += b; return b;
    }
}
SOL

# --- The oracle-perturbation invariant test, parameterized by the lender under test. The Handler exposes the
#     PRICE-MOVEMENT action (doManipUp) alongside doBorrow; the deep invariant says total borrowed must never
#     exceed the collateral's value at the HONEST anchor price (+ dust). forge-std-free (targetContracts()). ---
write_test() {  # $1 = test file, $2 = lender contract name (LendVuln|LendSafe)
  cat > "$1" <<SOL
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Pool, ILend, $2} from "../src/Oracle.sol";

contract Handler {
    Pool public pool; ILend public lender;
    uint256 public immutable anchor;   // the honest price, fixed at deploy
    uint256 public borrowedTotal;      // sum of quote borrowed across successful borrows
    uint256 public collateralTotal;    // sum of collateral those borrows were against
    constructor(Pool p, ILend l) { pool = p; lender = l; anchor = p.price(); }
    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo; return lo + (x % (hi - lo + 1));
    }
    // FM3 price-movement action: skew the pool's spot price UP within an attacker-reachable range.
    function doManipUp(uint256 amt1) public { amt1 = _bound(amt1, 1e18, 1e24); try pool.swapQuoteIn(amt1) {} catch {} }
    function doManipDown(uint256 amt0) public { amt0 = _bound(amt0, 1e18, 1e24); try pool.swap0In(amt0) {} catch {} }
    // Borrow against fuzzed collateral; only count borrows the lender actually accepted.
    function doBorrow(uint256 c) public {
        c = _bound(c, 1e18, 1e21);
        try lender.borrow(c) returns (uint256 b) { borrowedTotal += b; collateralTotal += c; } catch {}
    }
}

abstract contract InvBase {
    address[] private _t;
    function targetContracts() public view returns (address[] memory) { return _t; }
    function _target(address a) internal { _t.push(a); }
}

contract OracleManipTest is InvBase {
    Pool pool; $2 lender; Handler h;
    function setUp() public {
        pool = new Pool(1e24, 1e24);          // honest price = 1e18
        lender = new $2(pool);
        h = new Handler(pool, ILend(address(lender)));
        _target(address(h));
    }
    // DEEP invariant: total borrowed must stay within the collateral's value at the HONEST anchor price.
    // The vulnerable lender lets a manipulate-up -> borrow sequence over-lend past that -> a SEQUENCE the
    // fuzzer must find. The hardened lender's bound rejects the manipulated borrow -> this always holds.
    function invariant_no_overborrow() public view {
        uint256 ct = h.collateralTotal();
        if (ct == 0) return;
        uint256 honestMax = (ct * h.anchor()) / 1e18;
        require(h.borrowedTotal() <= honestMax + 1e6, "over-borrowed at a manipulated price");
    }
}
SOL
}

write_test "$PROJ/test/OracleVuln.t.sol" "LendVuln"
write_test "$PROJ/test/OracleSafe.t.sol" "LendSafe"

# --- Run the REAL gate on each side. Verdict = forge exit (1=FINDING, 0=CLEAN, 2=harness error). ---
run_gate() { "$GATE" --repo "$PROJ" --target "$1" --runs 200 --depth 48 --seed 1 >"$2" 2>&1; echo $?; }

VLOG="$WORK/vuln.log"; SLOG="$WORK/safe.log"
vrc="$(run_gate "test/OracleVuln.t.sol" "$VLOG")"
src="$(run_gate "test/OracleSafe.t.sol" "$SLOG")"

if [ "$vrc" -eq 1 ]; then pass "INSECURE: oracle-manipulation FINDING — the fuzzer sequenced price-move -> over-borrow (verdict = forge)"; else fail "INSECURE expected FINDING (exit 1), got exit $vrc"; sed -n '1,20p' "$VLOG" >&2; fi
if [ "$src" -eq 0 ]; then pass "SECURE twin: CLEAN — the deviation bound rejected the manipulated borrow (0 false-VERIFIED)"; else fail "SECURE expected CLEAN (exit 0), got exit $src"; sed -n '1,20p' "$SLOG" >&2; fi

if [ "$FAIL" -eq 0 ]; then
  echo "demo-fm3-oracle.sh: PASS: FM3 oracle/price perturbation is a real fuzz dimension — moving the spot price"
  echo "      as a Handler action breaks the solvency invariant on the spot-priced lender (FINDING) and is"
  echo "      rejected by the anchor+bound twin (CLEAN). Verdict is the fuzzer's; deterministic; offline."
  exit 0
fi
echo "demo-fm3-oracle.sh: FAIL — see [FAIL] lines above" >&2
exit 1
