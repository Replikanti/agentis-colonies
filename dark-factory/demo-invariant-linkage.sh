#!/usr/bin/env bash
# demo-invariant-linkage.sh — proof of the #1471 TARGET-LINKAGE GATE on the invariant-hunt generation path.
#
# The bug: when the real target is hard to harness, the LLM that generates the `*.t.sol` invariant test can
# silently substitute its OWN toy contract of the same name and the fuzzer "finds" a bug it planted THERE — a
# false FINDING against FABRICATED code (proven live: a Liquity BOLD StabilityPool run produced a test that
# imported nothing and defined its own 16-line `contract StabilityPool`). The fix arms a static gate in
# `evm-harness/forge-invariant.sh` (`--require-import` + `--require-contract`) that the prover threads in ONLY
# in pure fresh-deploy mode (no fork / no composability context, real CODE_PATH): a test that does not import
# the in-scope target, OR shadows it with a same-named toy, is HARNESS_ERROR (2) BEFORE any fuzzing — never a
# verdict.
#
# This demo has TWO parts:
#   1) SOURCE-GUARD (always, CI-safe, no toolchain): asserts the gate wiring + the prover's fresh-deploy-only
#      threading are present, so a refactor that drops either is caught even on runners with no forge.
#   2) LIVE (when forge is on PATH): builds a throwaway foundry project and runs the gate over (a) a substituted
#      toy target -> exit 2 + the #1471 reason, and (b) a test that imports the real target -> the gate proceeds
#      past linkage. agentis is NOT needed (the gate is exercised directly).
#
# Usage:  dark-factory/demo-invariant-linkage.sh
# Exit: 0 = all assertions hold (live parts SKIP cleanly when forge is absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/evm-harness/forge-invariant.sh"
PROVER="$HERE/auditor/agents/invariant-prover.ag"

FAILS=0
note() { echo "demo-invariant-linkage.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$GATE" ]   || { note "gate not found: $GATE" >&2; exit 3; }
[ -f "$PROVER" ] || { note "prover not found: $PROVER" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD — the wiring must exist regardless of toolchain.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1471 target-linkage wiring ..."

# The gate accepts and acts on the two new flags.
if grep -q -- '--require-import)' "$GATE" && grep -q -- '--require-contract)' "$GATE"; then
  ok "forge-invariant.sh parses --require-import / --require-contract"
else
  bad "forge-invariant.sh missing --require-import / --require-contract parsing"
fi
# The gate emits the #1471 HARNESS_ERROR reason (both the missing-import and the shadow branch).
if grep -q '#1471 target-linkage' "$GATE" && grep -q "does not import the in-scope target" "$GATE" \
   && grep -q "shadow" "$GATE"; then
  ok "forge-invariant.sh emits the #1471 HARNESS_ERROR reasons (missing-import + shadow)"
else
  bad "forge-invariant.sh missing a #1471 HARNESS_ERROR reason"
fi

# The prover threads the gate args ONLY in pure fresh-deploy mode: link_args early-returns "" on any fork /
# composability signal and on an empty CODE_PATH, and the gate invocation uses the combined gateExtra.
if grep -q 'fn link_args' "$PROVER" \
   && grep -q 'if len(fUrl) > 0 { return ""; }' "$PROVER" \
   && grep -q 'if len(fTarget) > 0 { return ""; }' "$PROVER" \
   && grep -q 'if len(fContext) > 0 { return ""; }' "$PROVER" \
   && grep -q 'if len(cPath) == 0 { return ""; }' "$PROVER"; then
  ok "invariant-prover.ag link_args is fresh-deploy-only (fork/composability/empty-code all return \"\")"
else
  bad "invariant-prover.ag link_args missing a fresh-deploy-only guard"
fi
if grep -q -- '--require-import' "$PROVER" && grep -q 'let gateExtra = fork + linkArgs;' "$PROVER" \
   && grep -q 'run_gate(gate, invRepo, invOut, invMatch, budget, gateExtra)' "$PROVER"; then
  ok "invariant-prover.ag threads gateExtra (fork + link args) into the gate call"
else
  bad "invariant-prover.ag does not thread the link args into the gate call"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) LIVE — exercise the gate against a real forge project (skip cleanly when forge is absent).
# ----------------------------------------------------------------------------------------------------------
if ! command -v forge >/dev/null 2>&1; then
  skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run the live gate checks"
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  mkdir -p "$WORK/src" "$WORK/test"
  printf '[profile.default]\nsrc = "src"\nout = "out"\n\n[invariant]\nruns = 8\ndepth = 4\nfail_on_revert = false\n' > "$WORK/foundry.toml"
  cat > "$WORK/src/StabilityPool.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract StabilityPool {
  uint public total;
  function add(uint a) external { total += a; }
}
SOL
  # (a) SUBSTITUTED TOY: no import + its own `contract StabilityPool` shadow -> the #1471 gate must reject it.
  cat > "$WORK/test/Toy.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract StabilityPool { uint public bal; function deposit(uint a) external { bal += a; } }
abstract contract InvBase {
  address[] private _t;
  function targetContracts() public view returns (address[] memory){ return _t; }
  function _target(address a) internal { _t.push(a); }
}
contract ToyInv is InvBase {
  StabilityPool p;
  function setUp() public { p = new StabilityPool(); _target(address(p)); }
  function invariant_ok() public view { require(p.bal() >= 0, "x"); }
}
SOL
  toy_out="$(sh "$GATE" --repo "$WORK" --target test/Toy.t.sol --match invariant \
              --require-import src/StabilityPool.sol --require-contract StabilityPool 2>&1)"; toy_rc=$?
  if [ "$toy_rc" -eq 2 ] && printf '%s' "$toy_out" | grep -q '#1471 target-linkage'; then
    ok "substituted toy target -> HARNESS_ERROR (2) with the #1471 reason (no fuzzing, no false FINDING)"
  else
    bad "substituted toy target should be HARNESS_ERROR (2)+#1471, got rc=$toy_rc"
    printf '%s\n' "$toy_out" | sed 's/^/        | /' | tail -5
  fi

  # (b) LINKED: imports the real target + a StabilityPoolHarness (the word boundary must NOT trip the shadow
  #     check), no shadow -> the gate proceeds PAST linkage to a real verdict.
  cat > "$WORK/test/Good.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {StabilityPool} from "../src/StabilityPool.sol";
abstract contract InvBase {
  address[] private _t;
  function targetContracts() public view returns (address[] memory){ return _t; }
  function _target(address a) internal { _t.push(a); }
}
contract StabilityPoolHarness {
  StabilityPool p;
  constructor(StabilityPool _p){ p = _p; }
  function poke(uint a) public { p.add(a); }
}
contract GoodInv is InvBase {
  StabilityPool p; StabilityPoolHarness h;
  function setUp() public { p = new StabilityPool(); h = new StabilityPoolHarness(p); _target(address(h)); }
  function invariant_total_nonneg() public view { require(p.total() >= 0, "x"); }
}
SOL
  good_out="$(sh "$GATE" --repo "$WORK" --target test/Good.t.sol --match invariant \
               --require-import src/StabilityPool.sol --require-contract StabilityPool 2>&1)"; good_rc=$?
  if ! printf '%s' "$good_out" | grep -q '#1471 target-linkage'; then
    ok "linked test (imports real target, StabilityPoolHarness) proceeds past linkage (rc=$good_rc, no #1471)"
  else
    bad "linked test wrongly rejected by the #1471 gate (rc=$good_rc)"
    printf '%s\n' "$good_out" | sed 's/^/        | /' | tail -5
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #1471 target-linkage gate rejects a substituted/self-authored target as HARNESS_ERROR and"
  note "      passes a genuinely-linked test, and the prover arms it ONLY in fresh-deploy mode (never in a"
  note "      fork/composability run where the target is an on-chain address, not a source import)."
  exit 0
fi
note "DEMO FAILED — a #1471 linkage assertion did not hold" >&2
exit 1
