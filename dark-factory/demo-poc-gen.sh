#!/usr/bin/env bash
# demo-poc-gen.sh — proof of the #1507 CONCRETE-EXPLOIT-SEQUENCE PoC class (hardhat + non-invariant foundry).
#
# The SECOND PoC class alongside the invariant machinery: poc-writer.ag writes ONE concrete attack-SEQUENCE test
# (not a property-fuzz handler) and the toolchain-parametric gate (evm-harness/hardhat-poc.sh /
# evm-harness/forge-poc.sh) JUDGES it. A concrete PoC is written to PASS iff the exploit works, so the gate
# INVERTS the runner's polarity: a PASSING test is a FINDING (the exploit reproduced), a FAILING test is CLEAN
# (refuted), and a compile/tooling error or a #1471 linkage reject is HARNESS_ERROR (not a verdict).
#
# HONEST CI BOUNDARY. Real PoC-gen needs an LLM + target repo + npm — NOT CI-friendly. This demo has THREE tiers,
# and states clearly what runs on CI vs needs the toolchain:
#   1) SOURCE-GUARD (ALWAYS, CI-safe, no toolchain): asserts the poc-writer.ag wiring (env contract, POC|/POC-FILE|
#      markers, the byte-identical verdict_of mapping, the fresh-deploy-only link_args, the repair loop, the
#      emit/learn/memo tail), both gates' --require-import/--require-contract parsing + #1471 reasons + the
#      INVERTED-polarity classify, detect-toolchain.sh's three outputs, and run-poc.sh's env_passthrough list.
#   2) CI-SAFE MECHANICAL (ALWAYS, no toolchain): detect-toolchain over the hardhat fixture -> "hardhat" and over
#      a throwaway foundry.toml -> "foundry"; hardhat-poc.sh --classify reports/{pass,fail,empty}.json -> exit
#      1/0/2 (the verdict-PARSING path pinned against captured mocha JSON — genuinely exercised on CI); and the
#      #1471 linkage-reject over the substituted PoC (linkage runs BEFORE npx, so NO node needed).
#   3) LIVE (SKIP unless the toolchain is present): the full npm install + compile + `npx hardhat test` e2e over
#      the bundled fixture via poc-writer.ag on the POC_FIXTURE path (NO LLM) -> POC|...|FINDING, gated on npx +
#      pre-installed hardhat deps; and a throwaway foundry project exercising forge-poc.sh FINDING / CLEAN /
#      linkage-reject, gated on `command -v forge`. The LLM generation path is NEVER on CI (like every
#      dark-factory live path). To run the hardhat e2e locally: `npm install --legacy-peer-deps` inside
#      evm-harness/hardhat-poc-fixture/ first (its node_modules are intentionally NOT committed).
#
# Usage:  dark-factory/demo-poc-gen.sh
# Exit: 0 = all assertions hold (live parts SKIP cleanly when the toolchain is absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVER="$HERE/auditor/agents/poc-writer.ag"
HH_GATE="$HERE/evm-harness/hardhat-poc.sh"
FG_GATE="$HERE/evm-harness/forge-poc.sh"
DETECT="$HERE/evm-harness/detect-toolchain.sh"
RUNNER="$HERE/run-poc.sh"
FIX="$HERE/evm-harness/hardhat-poc-fixture"

FAILS=0
note() { echo "demo-poc-gen.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for f in "$PROVER" "$HH_GATE" "$FG_GATE" "$DETECT" "$RUNNER"; do
  [ -f "$f" ] || { note "required file not found: $f" >&2; exit 3; }
done

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD — the wiring must exist regardless of toolchain (CI-safe).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1507 concrete-exploit PoC wiring ..."

# poc-writer.ag env contract.
missing_env=""
for v in TARGET_FN BUG_HYPOTHESIS POC_KIND POC_REPO POC_OUT POC_HARNESS CODE_PATH POC_FIXTURE POC_MATCH POC_REPAIR_ROUNDS; do
  grep -q "getenv(\"$v\")" "$PROVER" || missing_env="$missing_env $v"
done
[ -z "$missing_env" ] && ok "poc-writer.ag reads the env contract (TARGET_FN/BUG_HYPOTHESIS/POC_KIND/POC_REPO/POC_OUT/POC_HARNESS/...)" \
  || bad "poc-writer.ag missing getenv for:$missing_env"

# The verdict marker + the runnable-PoC line.
if grep -q 'print("POC|"' "$PROVER" && grep -q 'print("POC-FILE|"' "$PROVER"; then
  ok "poc-writer.ag prints the POC|<target>|<verdict> marker + a POC-FILE|<path> line on a FINDING"
else
  bad "poc-writer.ag missing the POC| / POC-FILE| stdout contract"
fi

# The verdict_of mapping must be BYTE-IDENTICAL to invariant-prover.ag (the gate owns the inversion, not the .ag).
# #2033: the rc==3 -> TRANSIENT_ERROR branch is part of that byte-identity — poc-writer mirrors it inertly (the
# PoC gates do not emit exit 3 today) so a refactor cannot split the two provers' verdict_of.
INVPROVER="$HERE/auditor/agents/invariant-prover.ag"
if grep -q 'if rc == 1 { return "FINDING"; }' "$PROVER" \
   && grep -q 'if rc == 0 { return "CLEAN"; }' "$PROVER" \
   && grep -q 'if rc == 3 { return "TRANSIENT_ERROR"; }' "$PROVER" \
   && grep -q 'return "HARNESS_ERROR";' "$PROVER" \
   && grep -q 'if rc == 3 { return "TRANSIENT_ERROR"; }' "$INVPROVER"; then
  ok "poc-writer.ag verdict_of(rc) is byte-identical to invariant-prover.ag (1->FINDING, 0->CLEAN, 3->TRANSIENT_ERROR, else->HARNESS_ERROR)"
else
  bad "poc-writer.ag verdict_of mapping drifted from invariant-prover.ag (incl. the #2033 rc==3 -> TRANSIENT_ERROR branch)"
fi

# The fresh-deploy-only #1471 link_args guard + the gate threading.
if grep -q 'fn link_args' "$PROVER" && grep -q 'if len(cPath) == 0 { return ""; }' "$PROVER" \
   && grep -q -- '--require-import' "$PROVER" && grep -q 'run_gate(gate, pocRepo, pocOut, pocMatch, linkArgs)' "$PROVER"; then
  ok "poc-writer.ag threads the #1471 link args into the gate ONLY when CODE_PATH is known"
else
  bad "poc-writer.ag missing the #1471 link_args threading"
fi

# The bounded compile-repair loop (mirrors invariant-prover.ag's #1073 shape).
if grep -q 'fn repair_loop' "$PROVER" && grep -q 'fn repair_step' "$PROVER" && grep -q 'fn rstate' "$PROVER"; then
  ok "poc-writer.ag has the bounded compile-repair loop (rstate / repair_step / repair_loop)"
else
  bad "poc-writer.ag missing the bounded repair loop"
fi

# The emit/learn/memo tail.
if grep -q 'emit("dark-factory:poc_verdict"' "$PROVER" \
   && grep -q 'learn("poc-write"' "$PROVER" && grep -q 'memo_write("poc-writer:last_check"' "$PROVER"; then
  ok "poc-writer.ag emits dark-factory:poc_verdict + records the learn/memo tail"
else
  bad "poc-writer.ag missing the emit / learn / memo tail"
fi

# Both gates parse the linkage flags + emit the #1471 reason + implement the INVERTED-polarity classify.
for g in "$HH_GATE" "$FG_GATE"; do
  gb="$(basename "$g")"
  if grep -q -- '--require-import)' "$g" && grep -q -- '--require-contract)' "$g"; then
    ok "$gb parses --require-import / --require-contract"
  else
    bad "$gb missing --require-import / --require-contract parsing"
  fi
  if grep -q '#1471 target-linkage' "$g"; then
    ok "$gb emits the #1471 target-linkage HARNESS_ERROR reason"
  else
    bad "$gb missing the #1471 target-linkage reason"
  fi
  # The inverted polarity: a PASSING exploit test is the FINDING (documented + implemented).
  if grep -qi 'INVERTED' "$g" && grep -q 'FINDING' "$g" && grep -q 'CLEAN' "$g" && grep -q 'HARNESS_ERROR' "$g"; then
    ok "$gb documents + implements the inverted polarity (pass=FINDING / fail=CLEAN / error=HARNESS_ERROR)"
  else
    bad "$gb missing the inverted-polarity classify contract"
  fi
done

# The hardhat gate must carry the exit-code contract 0/1/2 (return codes from classify_json).
if grep -q 'return 1' "$HH_GATE" && grep -q 'return 0' "$HH_GATE" && grep -q 'return 2' "$HH_GATE"; then
  ok "hardhat-poc.sh classify maps to the 1/0/2 exit contract"
else
  bad "hardhat-poc.sh missing the 1/0/2 classify exit codes"
fi

# run-poc.sh env_passthrough carries the whole poc-writer contract.
if grep -q 'exec.env_passthrough = TARGET_FN,TARGET_CLASS,BUG_HYPOTHESIS,POC_KIND,POC_REPO,POC_OUT,POC_HARNESS,POC_FIXTURE,CODE_PATH,TARGET_FIXTURES_DIR,POC_MATCH,POC_REPAIR_ROUNDS' "$RUNNER"; then
  ok "run-poc.sh env_passthrough carries the full poc-writer env contract"
else
  bad "run-poc.sh env_passthrough is missing a poc-writer env key"
fi

# #1535: run-poc.sh emits a machine-readable `POC|<target>|<verdict>` line on its OWN stdout (the shape the
# coordinator's poc_class scrapes via run_stage_live), distinct from — and additive to — the human-facing
# `================ POC: $TARGET -> $VERD ================` banner the gated hardhat e2e below still pins.
if grep -q 'echo "POC|$TARGET|$VERD"' "$RUNNER" && grep -q '================ POC: $TARGET -> $VERD ================' "$RUNNER"; then
  ok "run-poc.sh emits the additive POC|<target>|<verdict> stdout line AND keeps the arrow-form banner"
else
  bad "run-poc.sh missing the additive POC|<target>|<verdict> line or the arrow-form banner regressed"
fi

# #1540: on a FINDING, run-poc.sh best-effort re-invokes the gate against the warm rundir to capture durable
# run-evidence (poc-run.txt) and surfaces the runnable-PoC path + run-log on its OWN stdout (POC-FILE|/POC-RUN|),
# additive to the POC|<target>|<verdict> line — the coordinator hand-off / deliver-submission --poc-run source.
if grep -q 'POC_RUN_TXT="$OUT/poc-run.txt"' "$RUNNER" \
   && grep -q 'bash "$GATE_IN_RUN" --repo "$REPO_IN_RUN" --target "$POC_OUT" --match "$MATCH" >"$POC_RUN_TXT" 2>&1 || true' "$RUNNER" \
   && grep -q 'echo "POC-FILE|$POC_OUT"' "$RUNNER" && grep -q 'echo "POC-RUN|$POC_RUN_TXT"' "$RUNNER"; then
  ok "run-poc.sh captures poc-run.txt on a FINDING + emits the additive POC-FILE|/POC-RUN| stdout lines (#1540)"
else
  bad "run-poc.sh missing the #1540 run-evidence capture / POC-FILE|/POC-RUN| stdout wiring"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) CI-SAFE MECHANICAL — detect-toolchain + the --classify verdict-parse + the linkage-reject (no toolchain).
# ----------------------------------------------------------------------------------------------------------
note "exercising the CI-safe mechanical paths (no toolchain) ..."

# detect-toolchain over the hardhat fixture -> "hardhat" (no `|| true` — we assert the exit code too).
dt_hh="$(bash "$DETECT" "$FIX" 2>/dev/null)"; dt_hh_rc=$?
if [ "$dt_hh" = "hardhat" ] && [ "$dt_hh_rc" -eq 0 ]; then
  ok "detect-toolchain over the hardhat fixture -> hardhat (rc 0)"
else
  bad "detect-toolchain over the hardhat fixture should be 'hardhat' rc 0, got '$dt_hh' rc=$dt_hh_rc"
fi
# detect-toolchain over a throwaway foundry.toml -> "foundry".
FT="$(mktemp -d)"; printf '[profile.default]\nsrc = "src"\n' > "$FT/foundry.toml"
dt_fg="$(bash "$DETECT" "$FT" 2>/dev/null)"; dt_fg_rc=$?
rm -rf "$FT"
if [ "$dt_fg" = "foundry" ] && [ "$dt_fg_rc" -eq 0 ]; then
  ok "detect-toolchain over a throwaway foundry.toml -> foundry (rc 0)"
else
  bad "detect-toolchain over a foundry.toml should be 'foundry' rc 0, got '$dt_fg' rc=$dt_fg_rc"
fi
# detect-toolchain over an empty dir -> "unknown" (rc 3).
ED="$(mktemp -d)"
dt_un="$(bash "$DETECT" "$ED" 2>/dev/null)"; dt_un_rc=$?
rm -rf "$ED"
if [ "$dt_un" = "unknown" ] && [ "$dt_un_rc" -eq 3 ]; then
  ok "detect-toolchain over an empty dir -> unknown (rc 3)"
else
  bad "detect-toolchain over an empty dir should be 'unknown' rc 3, got '$dt_un' rc=$dt_un_rc"
fi

# hardhat-poc.sh --classify over the three captured mocha reporter JSONs -> the INVERTED-polarity verdict codes.
bash "$HH_GATE" --classify "$FIX/reports/pass.json"  >/dev/null 2>&1; cls_pass=$?
bash "$HH_GATE" --classify "$FIX/reports/fail.json"  >/dev/null 2>&1; cls_fail=$?
bash "$HH_GATE" --classify "$FIX/reports/empty.json" >/dev/null 2>&1; cls_empty=$?
if [ "$cls_pass" -eq 1 ]; then ok "hardhat-poc.sh --classify pass.json -> FINDING (exit 1) — a PASSING PoC is the finding"; else bad "classify pass.json should be exit 1 (FINDING), got $cls_pass"; fi
if [ "$cls_fail" -eq 0 ]; then ok "hardhat-poc.sh --classify fail.json -> CLEAN (exit 0) — a FAILING PoC is refuted"; else bad "classify fail.json should be exit 0 (CLEAN), got $cls_fail"; fi
if [ "$cls_empty" -eq 2 ]; then ok "hardhat-poc.sh --classify empty.json -> HARNESS_ERROR (exit 2) — no test ran"; else bad "classify empty.json should be exit 2 (HARNESS_ERROR), got $cls_empty"; fi

# The #1471 linkage-reject over the substituted PoC — the gate rejects BEFORE any npx spend, so NO node needed
# and NO npm install pollutes the tree (the reject exits at linkage with rc 2). This is the CI-safe anti-
# fabrication assertion; the genuinely-linked POSITIVE case is exercised by the LIVE hardhat e2e in part 3 (which
# is toolchain-gated), so we deliberately do NOT run the linked gate here — it would trigger an npm install.
sub_out="$(bash "$HH_GATE" --repo "$FIX" --target test/substituted.poc.test.js \
            --require-import contracts/Vuln.sol --require-contract Vuln 2>&1)"; sub_rc=$?
if [ "$sub_rc" -eq 2 ] && printf '%s' "$sub_out" | grep -q '#1471 target-linkage'; then
  ok "substituted PoC (drives a non-target) -> HARNESS_ERROR (2) + #1471 reason, BEFORE any node/npm spend"
else
  bad "substituted PoC should be HARNESS_ERROR (2)+#1471, got rc=$sub_rc"
  printf '%s\n' "$sub_out" | sed 's/^/        | /' | tail -5
fi

# ----------------------------------------------------------------------------------------------------------
# 3) LIVE — full e2e (SKIP unless the toolchain is present).
# ----------------------------------------------------------------------------------------------------------
note "live e2e (skips cleanly when the toolchain is absent) ..."

# 3a) HARDHAT — the full npm install + compile + `npx hardhat test` path via poc-writer.ag on the POC_FIXTURE
# path (NO LLM). Gated on npx + pre-installed hardhat deps (its node_modules are intentionally NOT committed).
if ! command -v npx >/dev/null 2>&1; then
  skip "npx not on PATH — install Node.js to run the hardhat live e2e"
elif ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the hardhat live e2e via poc-writer.ag"
elif [ ! -d "$FIX/node_modules" ]; then
  skip "hardhat deps not installed (run 'npm install --legacy-peer-deps' in evm-harness/hardhat-poc-fixture/) — CI boundary: the live hardhat e2e needs the toolchain"
else
  HH_OUT="$(mktemp -d)"
  hh_run="$(bash "$RUNNER" --repo "$FIX" --target "contracts/Vuln.sol:Vuln" --class "C-reentrancy" \
             --poc-fixture "$FIX/test/exploit.poc.test.js" --code "$FIX/contracts/Vuln.sol" \
             --backend mock --out "$HH_OUT" 2>&1)"; hh_rc=$?
  if printf '%s' "$hh_run" | grep -q 'POC: contracts/Vuln.sol:Vuln -> FINDING'; then
    ok "hardhat live e2e (poc-writer.ag on the POC_FIXTURE path, NO LLM) -> POC|...|FINDING"
  else
    bad "hardhat live e2e should end in FINDING (rc=$hh_rc)"
    printf '%s\n' "$hh_run" | sed 's/^/        | /' | tail -8
  fi
  # #1535: the same real run-poc.sh output must also carry the additive machine-readable POC| verdict line.
  if printf '%s' "$hh_run" | grep -qF 'POC|contracts/Vuln.sol:Vuln|FINDING'; then
    ok "run-poc.sh emitted the additive POC|contracts/Vuln.sol:Vuln|FINDING line on its own stdout (#1535)"
  else
    bad "run-poc.sh did not emit the additive POC|<target>|FINDING line (#1535 emit regression)"
  fi
  rm -rf "$HH_OUT"
fi

# 3a-bis) RELATIVE-PATH REGRESSION (#1531). hand-invoke hardhat-poc.sh DIRECTLY (bypassing run-poc.sh's own
# `REPO="$(cd "$REPO" && pwd)"` normalization) with a RELATIVE --repo/--target from a DIFFERENT cwd — the exact
# manual-invocation shape that used to double the path (".../hardhat-poc-fixture/hardhat-poc-fixture/...") into a
# false HARNESS_ERROR before the fix. Gated the same as 3a (needs npx + installed hardhat deps).
if ! command -v npx >/dev/null 2>&1; then
  skip "npx not on PATH — skipping the #1531 relative-path regression check"
elif [ ! -d "$FIX/node_modules" ]; then
  skip "hardhat deps not installed — skipping the #1531 relative-path regression check"
else
  REL_PARENT="$(dirname "$FIX")"
  REL_FIX="$(basename "$FIX")"
  rel_out="$(cd "$REL_PARENT" && bash "$HH_GATE" --repo "$REL_FIX" --target test/exploit.poc.test.js \
              --require-import contracts/Vuln.sol --require-contract Vuln 2>&1)"; rel_rc=$?
  if [ "$rel_rc" -eq 1 ]; then
    ok "hardhat-poc.sh with a RELATIVE --repo/--target (different cwd) -> FINDING (exit 1), no doubled-path HARNESS_ERROR (#1531)"
  else
    bad "hardhat-poc.sh with a RELATIVE --repo/--target should be FINDING (1), got rc=$rel_rc (doubled-path regression?)"
    printf '%s\n' "$rel_out" | sed 's/^/        | /' | tail -8
  fi
fi

# 3b) FOUNDRY — a throwaway foundry project exercising forge-poc.sh FINDING / CLEAN / linkage-reject. Gated on
# `command -v forge` (like demo-invariant-linkage.sh's live part).
if ! command -v forge >/dev/null 2>&1; then
  skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run the foundry live gate checks"
else
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/src" "$WORK/test"
  printf '[profile.default]\nsrc = "src"\nout = "out"\n' > "$WORK/foundry.toml"
  cat > "$WORK/src/Bank.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Bank {
  mapping(address => uint) public bal;
  function deposit() external payable { bal[msg.sender] += msg.value; }
}
SOL
  # (a) a PoC written to PASS iff the exploit holds -> FINDING.
  cat > "$WORK/test/Poc_Bank.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Bank} from "../src/Bank.sol";
contract PocBank {
  function test_exploit() external {
    Bank b = new Bank();
    require(b.bal(address(this)) == 0, "exploit reproduced");
  }
}
SOL
  fg_find="$(bash "$FG_GATE" --repo "$WORK" --target test/Poc_Bank.t.sol --require-import src/Bank.sol --require-contract Bank 2>&1)"; fg_find_rc=$?
  if [ "$fg_find_rc" -eq 1 ]; then ok "forge-poc.sh: a passing exploit PoC -> FINDING (exit 1)"; else bad "forge-poc.sh passing PoC should be FINDING (1), got $fg_find_rc"; printf '%s\n' "$fg_find" | sed 's/^/        | /' | tail -4; fi
  # (b) a PoC that FAILS -> CLEAN.
  cat > "$WORK/test/Poc_Bank.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Bank} from "../src/Bank.sol";
contract PocBank {
  function test_exploit() external {
    Bank b = new Bank();
    b.deposit();
    require(1 == 2, "exploit did not reproduce");
  }
}
SOL
  fg_clean="$(bash "$FG_GATE" --repo "$WORK" --target test/Poc_Bank.t.sol --require-import src/Bank.sol --require-contract Bank 2>&1)"; fg_clean_rc=$?
  if [ "$fg_clean_rc" -eq 0 ]; then ok "forge-poc.sh: a failing exploit PoC -> CLEAN (exit 0)"; else bad "forge-poc.sh failing PoC should be CLEAN (0), got $fg_clean_rc"; printf '%s\n' "$fg_clean" | sed 's/^/        | /' | tail -4; fi
  # (c) a substituted toy of the same name -> #1471 linkage reject.
  cat > "$WORK/test/Poc_Toy.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Bank { function bal(address) external pure returns (uint) { return 0; } }
contract PocToy { function test_x() external pure { require(true, "x"); } }
SOL
  fg_lnk="$(bash "$FG_GATE" --repo "$WORK" --target test/Poc_Toy.t.sol --require-import src/Bank.sol --require-contract Bank 2>&1)"; fg_lnk_rc=$?
  if [ "$fg_lnk_rc" -eq 2 ] && printf '%s' "$fg_lnk" | grep -q '#1471 target-linkage'; then
    ok "forge-poc.sh: a substituted same-named toy -> HARNESS_ERROR (2) + #1471 reason"
  else
    bad "forge-poc.sh substituted toy should be HARNESS_ERROR (2)+#1471, got $fg_lnk_rc"
    printf '%s\n' "$fg_lnk" | sed 's/^/        | /' | tail -4
  fi
  # (d) RELATIVE-PATH REGRESSION (#1531): the still-FAILING Poc_Bank.t.sol from (b), hand-invoked with a RELATIVE
  # --repo/--target from a DIFFERENT cwd — the manual-invocation shape that used to double the path into a false
  # HARNESS_ERROR before the fix.
  fg_rel_parent="$(dirname "$WORK")"
  fg_rel_repo="$(basename "$WORK")"
  fg_rel="$(cd "$fg_rel_parent" && bash "$FG_GATE" --repo "$fg_rel_repo" --target test/Poc_Bank.t.sol --require-import src/Bank.sol --require-contract Bank 2>&1)"; fg_rel_rc=$?
  if [ "$fg_rel_rc" -eq 0 ]; then
    ok "forge-poc.sh with a RELATIVE --repo/--target (different cwd) -> CLEAN (exit 0), no doubled-path HARNESS_ERROR (#1531)"
  else
    bad "forge-poc.sh with a RELATIVE --repo/--target should be CLEAN (0), got rc=$fg_rel_rc (doubled-path regression?)"
    printf '%s\n' "$fg_rel" | sed 's/^/        | /' | tail -8
  fi
  rm -rf "$WORK"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the concrete-exploit PoC class wires poc-writer.ag + the two gates + detect-toolchain + run-poc.sh;"
  note "      the inverted verdict polarity (pass=FINDING) is pinned on CI against captured mocha JSON; the #1471"
  note "      anti-fabrication gate rejects a substituted target BEFORE any tooling spend; the LLM + npm live"
  note "      paths are toolchain-gated and SKIP cleanly on CI."
  exit 0
fi
note "DEMO FAILED — a #1507 PoC-gen assertion did not hold" >&2
exit 1
