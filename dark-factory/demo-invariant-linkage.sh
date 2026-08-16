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
#      threading are present, PLUS the #1776 general single-target fresh-deploy generalization (resolve_in_repo_src /
#      targetInRepoRel / effImport / singleFresh / targetImport), so a refactor that drops either is caught even on
#      runners with no forge.
#   2) LIVE (when forge is on PATH): builds a throwaway foundry project and runs the gate over (a) a substituted
#      toy target -> exit 2 + the #1471 reason, (b) a test that imports the real in-repo target -> the gate proceeds
#      past linkage, and (c) a test importing the flat copy staged ONE DIR ABOVE the Foundry root
#      (`../../target-code.sol`) -> HARNESS_ERROR (the #1776 non-yearn failure the generalization fixes). agentis is
#      NOT needed (the gate is exercised directly).
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

# #1776 — GENERAL single-target fresh-deploy generalization: the prover must resolve the target's REAL in-repo
# source (targetInRepoRel via resolve_in_repo_src) and, on the singleFresh path, (a) pin the skeleton import to it
# (effImport) and (b) arm the #1471 gate with the in-repo target basename (targetImport) instead of the staged
# `../../target-code.sol`. Off the singleFresh path fork / fork-context stay byte-identical; composable-fresh
# gets its OWN in-repo global-import pin (#1926) — the singleFresh else-branch import is still `import_line(
# targetName, effImport)`. A refactor dropping this regresses the non-yearn HARNESS_ERROR (#1776), so pin it here.
if grep -q 'fn resolve_in_repo_src(repo: string, file: string) -> string' "$PROVER" \
   && grep -q 'let targetInRepoRel = rel_import_path(invOut, targetSrcAbs);' "$PROVER" \
   && grep -q 'let effImport = ' "$PROVER" \
   && grep -q 'else { import_line(targetName, effImport) };' "$PROVER"; then
  ok "invariant-prover.ag resolves the in-repo target source + pins the skeleton import to it on singleFresh (effImport)"
else
  bad "invariant-prover.ag does not compute targetInRepoRel/effImport for the single-target fresh-deploy import (#1776)"
fi
if grep -q 'let singleFresh = single_fresh(forkMode, composableMode, composableFresh);' "$PROVER" \
   && grep -q 'let targetImport = ' "$PROVER" \
   && grep -q 'let linkArgs = link_args(forkUrl, forkTarget, forkContext, codePath, targetName, targetImport);' "$PROVER"; then
  ok "invariant-prover.ag arms linkArgs with targetImport (in-repo basename on singleFresh, vaultTargetImport on vaultRoute)"
else
  bad "invariant-prover.ag does not arm linkArgs with the generalized targetImport (#1776)"
fi
if grep -q 'fn single_fresh_import_guard(single: bool) -> string' "$PROVER" \
   && grep -q 'single_fresh_import_guard(singleFresh)' "$PROVER"; then
  ok "invariant-prover.ag weaves the single-target in-repo-import forbiddance into sharedScaffold gated on singleFresh"
else
  bad "invariant-prover.ag does not weave the singleFresh in-repo-import forbiddance (#1776)"
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

  # (c) FLAT-COPY-ABOVE-ROOT (#1776, the yieldoor/Leverager HARNESS_ERROR): a harness that imports the flattened
  #     target staged ONE DIR ABOVE the Foundry root (`../../target-code.sol`, the pipeline's <rundir>/target-code.sol
  #     shape) must HARNESS_ERROR — solc refuses a relative import that escapes the project root — whereas the in-repo
  #     `../src/<Target>.sol` import (case b) compiles + proceeds. This pins the exact contrast the #1776
  #     generalization fixes: the general single-target fresh-deploy path must import the real in-repo source, never
  #     the flat copy. The gate is armed with the FLAT basename here so the #1471 check passes and the COMPILE failure
  #     is what surfaces (reproducing the measured yieldoor error), not a linkage rejection.
  NEST="$WORK/nested"
  mkdir -p "$NEST/repo/src" "$NEST/repo/test"
  printf '[profile.default]\nsrc = "src"\nout = "out"\n\n[invariant]\nruns = 8\ndepth = 4\nfail_on_revert = false\n' > "$NEST/repo/foundry.toml"
  # the flattened copy staged ONE DIR ABOVE the Foundry root — present ONLY for the link-gate's textual check.
  cat > "$NEST/target-code.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Leverager { uint public total; function add(uint a) external { total += a; } }
SOL
  # the REAL in-repo source (what the #1776 generalization imports instead).
  cat > "$NEST/repo/src/Leverager.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Leverager { uint public total; function add(uint a) external { total += a; } }
SOL
  cat > "$NEST/repo/test/Flat.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Leverager} from "../../target-code.sol";
abstract contract InvBase {
  address[] private _t;
  function targetContracts() public view returns (address[] memory){ return _t; }
  function _target(address a) internal { _t.push(a); }
}
contract FlatInv is InvBase {
  Leverager p;
  function setUp() public { p = new Leverager(); _target(address(p)); }
  function invariant_total_nonneg() public view { require(p.total() >= 0, "x"); }
}
SOL
  flat_out="$(sh "$GATE" --repo "$NEST/repo" --target test/Flat.t.sol --match invariant \
               --require-import target-code.sol --require-contract Leverager 2>&1)"; flat_rc=$?
  if [ "$flat_rc" -ne 0 ]; then
    ok "flat-copy-above-root import (../../target-code.sol) -> HARNESS_ERROR (rc=$flat_rc) — solc cannot escape the Foundry root (#1776)"
  else
    bad "flat-copy-above-root import should HARNESS_ERROR — got rc=$flat_rc (the #1776 general-path import bug)"
    printf '%s\n' "$flat_out" | sed 's/^/        | /' | tail -5
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
