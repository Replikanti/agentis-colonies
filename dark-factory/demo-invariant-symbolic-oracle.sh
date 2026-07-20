#!/usr/bin/env bash
# demo-invariant-symbolic-oracle.sh — proof of the #1732 COMPLEMENTARY symbolic / bounded-model-checking oracle.
#
# The gap this closes: the deep-hunt has a single oracle — Foundry's stateful fuzzer, which SAMPLES call
# sequences and so can MISS a value-conservation break on a rare path (#1716). #1732 wires the ALREADY-SHIPPED
# SOUND gate `evm-harness/halmos-verify.sh` (Halmos symbolic execution + an SMT solver) in as a SECOND,
# INDEPENDENT oracle that runs over the SAME generated invariant test AFTER the fuzzer verdict. The FUZZER stays
# the SOLE primary verdict; the symbolic result is a SEPARATE `SYMBOLIC|<file:fn>|<verdict>` marker + its own
# `## Symbolic oracle (complementary)` report section. There is ZERO `.ag` change: halmos consumes the generated
# `invariant_*` directly via `--function`.
#
# This is a SOURCE-GUARD + offline demo (always CI-safe, no LLM; the LIVE assertions run only when forge AND
# agentis are present and SKIP cleanly otherwise). It pins:
#   (a) run-invariant-hunt.sh defaults SYMBOLIC_ORACLE="" (flag OFF);
#   (b) the symbolic block is gated on $SYMBOLIC_ORACLE and its invocation sits AFTER the primary $REPORT is
#       written and BEFORE the #1731 replay block clobbers test/ (so $INV_OUT is intact; off => byte-identical);
#   (c) it invokes the STAGED halmos gate (`sh "$RUN/halmos-verify.sh"`), staged via `cp "$GATE_HALMOS" ...`,
#       NOT a fresh `agentis go` / no per-element .ag loop;
#   (d) the exit->verdict map (0->PROVED / 1->COUNTEREXAMPLE / 3->INCONCLUSIVE / *->HARNESS_ERROR) is present
#       and a RUNNER-side `command -v halmos`+`command -v forge` clean-SKIP guard exists (tool-absence is a
#       SKIPPED row, never a HARNESS_ERROR — the gate itself exits 2 on tool-absence, so the SKIP must be here);
#   (e) the symbolic slice references NONE of verdict_of / final_verdict / $VERD / verified_findings /
#       --require-import / --require-contract (the fuzzer stays the sole verdict; the #1471 gate is untouched);
#   (f) it emits a `SYMBOLIC|` marker + a `## Symbolic oracle (complementary)` report section;
#   (g) run-zone-hunt.sh forwards --symbolic-oracle / --symbolic-timeout verbatim to BOTH deep-hunt $INVHUNT
#       invocations, and invariant-prover.ag is byte-untouched (the fuzzer anchors still present);
#   (h) LIVE (forge + agentis; halmos optional): run the fixture vault once WITH --symbolic-oracle and once
#       WITHOUT, assert the `## Symbolic oracle (complementary)` section appears ONLY with the flag AND the
#       primary INVARIANT| verdict is IDENTICAL with vs without the flag (the oracle never alters the fuzzer
#       verdict). With halmos present a SYMBOLIC| row is produced; absent it, a clean SKIPPED row.
#
# Usage:  dark-factory/demo-invariant-symbolic-oracle.sh
# Exit: 0 = all assertions hold (live part SKIPs cleanly when the toolchain is absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
RUNNER="$HERE/run-invariant-hunt.sh"
GATE_HALMOS="$HERE/evm-harness/halmos-verify.sh"

FAILS=0
note() { echo "demo-invariant-symbolic-oracle.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$PROVER" ] || { note "prover not found: $PROVER" >&2; exit 3; }
[ -f "$RUNNER" ] || { note "runner not found: $RUNNER" >&2; exit 3; }
[ -f "$GATE_HALMOS" ] || { note "halmos-verify gate not found: $GATE_HALMOS" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# (a) DEFAULT-OFF — run-invariant-hunt.sh defaults --symbolic-oracle OFF.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the default-off flag ..."

if grep -q 'SYMBOLIC_ORACLE=""' "$RUNNER"; then
  ok "run-invariant-hunt.sh defaults --symbolic-oracle OFF (SYMBOLIC_ORACLE=\"\")"
else
  bad "run-invariant-hunt.sh does not default --symbolic-oracle OFF"
fi

if grep -q 'SYMBOLIC_TIMEOUT=""' "$RUNNER"; then
  ok "run-invariant-hunt.sh defaults --symbolic-timeout empty (=> the gate's own default 60)"
else
  bad "run-invariant-hunt.sh does not default --symbolic-timeout empty"
fi

# ----------------------------------------------------------------------------------------------------------
# (b) GATED + ORDERED — the invocation is gated on $SYMBOLIC_ORACLE, AFTER the $REPORT write, BEFORE #1731.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the flag gate + the ordering (after \$REPORT, before the #1731 replay clobber) ..."

if grep -q 'if \[ -n "$SYMBOLIC_ORACLE" \]; then' "$RUNNER"; then
  ok "the symbolic block is gated on \$SYMBOLIC_ORACLE (off => byte-identical)"
else
  bad "the symbolic block is not gated on \$SYMBOLIC_ORACLE"
fi

_report_ln="$(grep -n '} > "$REPORT"' "$RUNNER" | head -1 | cut -d: -f1)"
_symcall_ln="$(grep -n 'symbolic_oracle "$REPORT"' "$RUNNER" | head -1 | cut -d: -f1)"
_replay_ln="$(grep -n 'if \[ -n "$REPLAY_CORPUS" \] && \[ -n "$PATTERN_STORE" \]; then' "$RUNNER" | tail -1 | cut -d: -f1)"
if [ -n "$_report_ln" ] && [ -n "$_symcall_ln" ] && [ -n "$_replay_ln" ] \
   && [ "$_symcall_ln" -gt "$_report_ln" ] && [ "$_symcall_ln" -lt "$_replay_ln" ]; then
  ok "the symbolic pass runs AFTER the primary \$REPORT write and BEFORE the #1731 replay clobbers test/ (\$INV_OUT intact)"
else
  bad "the symbolic pass is NOT ordered after \$REPORT and before the #1731 replay block"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) STAGED GATE — invokes the STAGED halmos-verify.sh, staged via cp; NO agentis spawn / per-element loop.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the staged-gate invocation (no agentis spawn / per-element loop) ..."

_so_body="$(awk '/^symbolic_oracle\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$RUNNER")"

if grep -q 'GATE_HALMOS="$HERE/evm-harness/halmos-verify.sh"' "$RUNNER" \
   && printf '%s\n' "$_so_body" | grep -q 'cp "$GATE_HALMOS" "$RUN/halmos-verify.sh"'; then
  ok "the halmos gate is resolved from evm-harness/ and STAGED into \$RUN/halmos-verify.sh (cp)"
else
  bad "the halmos gate is not resolved + staged via cp into \$RUN/halmos-verify.sh"
fi

if printf '%s\n' "$_so_body" | grep -q 'sh "$RUN/halmos-verify.sh" --repo "$REPO_IN_RUN" --target "$INV_OUT" --function "$MATCH"' \
   && ! printf '%s\n' "$_so_body" | grep -Eq '"\$AGENTIS" go|agentis go'; then
  ok "symbolic_oracle runs the STAGED halmos-verify.sh over \$INV_OUT (--function \$MATCH); NO agentis spawn, NO .ag loop"
else
  bad "symbolic_oracle does not run the staged gate / spawns agentis (the pass must be one pure-shell gate call)"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) EXIT->VERDICT MAP + the RUNNER-side command-v halmos+forge SKIP guard.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the exit->verdict map + the tool-absence SKIP guard ..."

if printf '%s\n' "$_so_body" | grep -q '0) SYMV="PROVED" ;;' \
   && printf '%s\n' "$_so_body" | grep -q '1) SYMV="COUNTEREXAMPLE" ;;' \
   && printf '%s\n' "$_so_body" | grep -q '3) SYMV="INCONCLUSIVE" ;;' \
   && printf '%s\n' "$_so_body" | grep -q '\*) SYMV="HARNESS_ERROR" ;;'; then
  ok "the exit->verdict map is present (0->PROVED / 1->COUNTEREXAMPLE / 3->INCONCLUSIVE / *->HARNESS_ERROR)"
else
  bad "the exit->verdict map (0/1/3/*) is missing or wrong"
fi

# The clean SKIP for tool-absence MUST live in the RUNNER: halmos-verify.sh exits 2 on tool-absence, which is
# indistinguishable from a real harness error, so a `command -v halmos`+`command -v forge` guard must SKIP first.
if printf '%s\n' "$_so_body" | grep -q 'command -v halmos' \
   && printf '%s\n' "$_so_body" | grep -q 'command -v forge' \
   && printf '%s\n' "$_so_body" | grep -q 'SKIPPED (halmos/forge not on PATH)'; then
  ok "a runner-side command -v halmos+forge guard SKIPs (a SKIPPED row, exit-neutral) — tool-absence is never HARNESS_ERROR"
else
  bad "the runner-side command -v halmos+forge tool-absence SKIP guard is missing"
fi

# The fuzzer-HARNESS_ERROR path (no generated test) is ALSO a clean SKIP, not a symbolic verdict.
if printf '%s\n' "$_so_body" | grep -q 'if \[ ! -f "$INV_OUT" \]; then' \
   && printf '%s\n' "$_so_body" | grep -q 'SKIPPED (no generated invariant test)'; then
  ok "a missing \$INV_OUT (fuzzer HARNESS_ERROR) is a clean SKIPPED row, no symbolic verdict"
else
  bad "the missing-\$INV_OUT SKIP guard is absent"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) FUZZER STAYS SOLE VERDICT — the symbolic function never touches the verdict / #1471 gate machinery.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that the symbolic pass never touches the fuzzer verdict / verified_findings / #1471 gate ..."

_so_slice="$(printf '%s\n' "$_so_body" | grep -v '^[[:space:]]*#')"
if printf '%s\n' "$_so_slice" | grep -Eq 'verdict_of|final_verdict|\$VERD|verified_findings|--require-import|--require-contract'; then
  bad "the symbolic_oracle body references the fuzzer verdict / verified_findings / the #1471 gate (must stay untouched)"
  printf '%s\n' "$_so_slice" | grep -En 'verdict_of|final_verdict|\$VERD|verified_findings|--require-import|--require-contract' | sed 's/^/         | /'
else
  ok "symbolic_oracle references NONE of verdict_of / final_verdict / \$VERD / verified_findings / the #1471 gate"
fi

# The gated invocation block passes ONLY $REPORT to symbolic_oracle — it never reads $VERD.
_gate_block="$(awk '/^if \[ -n "\$SYMBOLIC_ORACLE" \]; then$/{f=1} f{print} f&&/^fi$/{exit}' "$RUNNER")"
if printf '%s\n' "$_gate_block" | grep -q 'symbolic_oracle "$REPORT"' \
   && ! printf '%s\n' "$_gate_block" | grep -q '\$VERD'; then
  ok "the gated invocation passes only \$REPORT (never \$VERD) — the fuzzer verdict is not an input to the oracle"
else
  bad "the gated invocation reads \$VERD / does not pass just \$REPORT"
fi

# ----------------------------------------------------------------------------------------------------------
# (f) SEPARATE CHANNEL — a SYMBOLIC| marker + a `## Symbolic oracle (complementary)` report section.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the SYMBOLIC| marker + the report section ..."

if printf '%s\n' "$_so_body" | grep -q 'echo "SYMBOLIC|$TARGET|$SYMV" >&2'; then
  ok "symbolic_oracle emits a SYMBOLIC|<target>|<verdict> stderr marker (run-symbolic.sh's convention)"
else
  bad "symbolic_oracle does not emit the SYMBOLIC| marker"
fi

if printf '%s\n' "$_so_body" | grep -q '## Symbolic oracle (complementary)'; then
  ok "symbolic_oracle appends its own ## Symbolic oracle (complementary) report section"
else
  bad "symbolic_oracle does not append the ## Symbolic oracle (complementary) section"
fi

# ----------------------------------------------------------------------------------------------------------
# (g) ZONE PASS-THROUGH + invariant-prover.ag BYTE-UNTOUCHED (the fuzzer anchors intact).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the run-zone-hunt.sh pass-through + the untouched .ag fuzzer anchors ..."

ZONE="$HERE/run-zone-hunt.sh"
if [ -f "$ZONE" ]; then
  _fwd_count="$(grep -c '${DEEP_FWD\[@\]+"${DEEP_FWD\[@\]}"}' "$ZONE")"
  if grep -q 'DEEP_FWD+=(--symbolic-oracle)' "$ZONE" \
     && grep -q 'DEEP_FWD+=(--symbolic-timeout "$2")' "$ZONE" \
     && [ "$_fwd_count" -eq 2 ]; then
    ok "run-zone-hunt.sh forwards --symbolic-oracle / --symbolic-timeout verbatim to BOTH \$INVHUNT invocations"
  else
    bad "run-zone-hunt.sh does not forward both symbolic flags to both deep-hunt invocations"
  fi
else
  bad "run-zone-hunt.sh not found: $ZONE"
fi

# invariant-prover.ag is byte-untouched: the fuzzer verdict anchors + the #1471 gate must all still be present,
# and there must be NO SYMBOLIC| / halmos wiring in the .ag (halmos consumes the generated invariant_* directly).
if grep -q 'print("INVARIANT|" + targetFn + "|" + verdict);' "$PROVER" \
   && grep -q 'fn verdict_of(rc: int) -> string' "$PROVER" \
   && grep -q 'fn final_verdict(rc: int, violated: bool) -> string' "$PROVER" \
   && grep -q -- '--require-import ' "$PROVER"; then
  ok "invariant-prover.ag's INVARIANT| marker, verdict_of, final_verdict, and the #1471 gate are all still present"
else
  bad "an invariant-prover.ag fuzzer/marker/#1471 anchor is missing (the .ag must stay byte-untouched)"
fi

# No NEW symbolic wiring in the fuzzer prover: it must not PRINT a SYMBOLIC| verdict nor INVOKE the halmos gate
# (halmos-verify.sh / a HALMOS_VERIFY env). The zero-.ag-change contract: halmos reads the generated invariant_*
# from the SHELL runner, never from the prover. (A prose comment mentioning symbolic-prover.ag/Halmos is fine.)
if ! grep -q 'print("SYMBOLIC|' "$PROVER" \
   && ! grep -q 'halmos-verify' "$PROVER" \
   && ! grep -q 'HALMOS_VERIFY' "$PROVER"; then
  ok "invariant-prover.ag emits NO SYMBOLIC| verdict and invokes NO halmos gate (zero .ag change — the wiring is shell-only)"
else
  bad "invariant-prover.ag prints SYMBOLIC| or invokes the halmos gate (the wiring must be shell-only, no .ag change)"
fi

# ----------------------------------------------------------------------------------------------------------
# (h) LIVE — run WITH vs WITHOUT the flag; the section appears only with it; the PRIMARY verdict is identical.
# ----------------------------------------------------------------------------------------------------------
if ! command -v forge >/dev/null 2>&1; then
  skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run the live oracle assertions"
elif ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the agentis runtime to run the live oracle assertions"
else
  note "running the live symbolic-oracle assertions under forge + agentis ..."
  if command -v halmos >/dev/null 2>&1; then
    note "  halmos IS on PATH — expecting a real SYMBOLIC| verdict row"
  else
    note "  halmos NOT on PATH — expecting a clean SKIPPED row (tool-absence must never be a HARNESS_ERROR)"
  fi
  [ -x "$RUNNER" ] || { note "runner not executable: $RUNNER" >&2; exit 3; }
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT

  # The same tiny VULNERABLE ERC4626-style vault + proven fixture handler used by demo-invariant-corpus-replay.sh.
  mkdir -p "$WORK/repo/src" "$WORK/repo/test"
  printf '[profile.default]\nsrc = "src"\nout = "out"\n\n[invariant]\nruns = 64\ndepth = 32\nfail_on_revert = false\n' > "$WORK/repo/foundry.toml"
  cat > "$WORK/repo/src/Vault.sol" <<'SOL'
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
  constructor(Token a){ asset=a; }
  function deposit(uint assets) external returns(uint s){
    uint ta = asset.balanceOf(address(this));
    s = totalShares==0 ? assets : assets*totalShares/ta;
    asset.transferFrom(msg.sender,address(this),assets);
    shares[msg.sender]+=s; totalShares+=s;
  }
  function withdraw(uint s) external returns(uint assets){
    uint ta = asset.balanceOf(address(this));
    assets = s*ta/totalShares;
    shares[msg.sender]-=s; totalShares-=s;
    asset.transfer(msg.sender,assets);
  }
}
SOL

  cat > "$WORK/fixture.t.sol" <<'SOL'
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

  _primary_verd() {  # $1 = run.log -> the primary fuzzer verdict from the INVARIANT-HUNT banner
    grep 'INVARIANT-HUNT:' "$1" 2>/dev/null | tail -1 | sed -E 's/.*-> ([A-Z_]+) .*/\1/'
  }

  # WITHOUT the flag — baseline primary verdict; NO symbolic section.
  note "  running run-invariant-hunt.sh WITHOUT --symbolic-oracle (baseline) ..."
  "$RUNNER" --repo "$WORK/repo" --target "Vault.sol:Vault" --class "C-erc4626" \
            --handler-fixture "$WORK/fixture.t.sol" --backend mock \
            --runs 64 --depth 32 --seed 1 --out "$WORK/out-off" >"$WORK/off.log" 2>&1
  _off_rc=$?
  REPORT_OFF="$WORK/out-off/invariant-report.md"

  # WITH the flag — same run + the complementary symbolic section.
  note "  running run-invariant-hunt.sh WITH --symbolic-oracle (complementary oracle) ..."
  "$RUNNER" --repo "$WORK/repo" --target "Vault.sol:Vault" --class "C-erc4626" \
            --handler-fixture "$WORK/fixture.t.sol" --backend mock \
            --runs 64 --depth 32 --seed 1 --out "$WORK/out-on" --symbolic-oracle --symbolic-timeout 30 >"$WORK/on.log" 2>&1
  _on_rc=$?
  REPORT_ON="$WORK/out-on/invariant-report.md"

  if [ "$_off_rc" -ne 0 ] || [ ! -f "$REPORT_OFF" ] || [ "$_on_rc" -ne 0 ] || [ ! -f "$REPORT_ON" ]; then
    bad "a run did not complete (off rc=$_off_rc, on rc=$_on_rc); on.log tail:"
    sed 's/^/         | /' "$WORK/on.log" 2>/dev/null | tail -20
  else
    # The symbolic section appears ONLY with the flag.
    if grep -q '## Symbolic oracle (complementary)' "$REPORT_ON" \
       && ! grep -q '## Symbolic oracle (complementary)' "$REPORT_OFF"; then
      ok "the ## Symbolic oracle (complementary) section appears WITH the flag and is absent WITHOUT it"
      note "  the symbolic-oracle section:"
      sed -n '/## Symbolic oracle (complementary)/,$p' "$REPORT_ON" | sed 's/^/         | /'
    else
      bad "the symbolic section did not appear only-with-the-flag (on has it: $(grep -cq '## Symbolic oracle' "$REPORT_ON" && echo yes || echo no))"
    fi

    # The PRIMARY fuzzer verdict is IDENTICAL with vs without the flag (the oracle never alters it).
    _pv_off="$(_primary_verd "$WORK/off.log")"
    _pv_on="$(_primary_verd "$WORK/on.log")"
    if [ -n "$_pv_off" ] && [ "$_pv_off" = "$_pv_on" ]; then
      ok "the PRIMARY fuzzer verdict is identical with vs without --symbolic-oracle ($_pv_on) — the oracle never alters it"
    else
      bad "the primary fuzzer verdict differs with the flag (off='$_pv_off' on='$_pv_on') — the oracle must not touch it"
    fi

    # A SYMBOLIC| marker (halmos present) OR a clean SKIPPED row (halmos absent) — never a bare HARNESS_ERROR row.
    if command -v halmos >/dev/null 2>&1; then
      if grep -q 'SYMBOLIC|Vault.sol:Vault|' "$WORK/on.log"; then
        ok "halmos present: a SYMBOLIC|Vault.sol:Vault|<verdict> marker was emitted"
      else
        bad "halmos present but no SYMBOLIC| marker was emitted"
        sed 's/^/         | /' "$WORK/on.log" 2>/dev/null | tail -20
      fi
    else
      if grep -q 'SKIPPED (halmos/forge not on PATH)' "$REPORT_ON"; then
        ok "halmos absent: the symbolic pass emitted a clean SKIPPED row (never a HARNESS_ERROR)"
      else
        bad "halmos absent but the symbolic pass did not emit the expected SKIPPED row"
        sed -n '/## Symbolic oracle/,$p' "$REPORT_ON" | sed 's/^/         | /'
      fi
    fi
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #1732 complementary symbolic/BMC oracle is wired — run-invariant-hunt.sh runs the SHIPPED SOUND"
  note "      halmos-verify.sh gate over the SAME generated invariant AFTER the fuzzer verdict (default-off, gated"
  note "      on \$SYMBOLIC_ORACLE, byte-identical when off), behind a runner-side command -v halmos+forge SKIP so"
  note "      tool-absence is never a HARNESS_ERROR. The FUZZER stays the SOLE verdict: the symbolic result is a"
  note "      SEPARATE SYMBOLIC| marker + ## Symbolic oracle (complementary) report section and never touches"
  note "      \$VERD / the INVARIANT| marker / verified_findings.json / the #1471 gate. Zero .ag change:"
  note "      invariant-prover.ag is byte-untouched (halmos consumes the generated invariant_* via --function)."
  note "      (A no-argument invariant_* can be vacuously PROVED — deep symbolic properties are a deferred"
  note "      generation concern; this ships the WIRING. Live section runs under forge + agentis.)"
  exit 0
fi
note "DEMO FAILED — a #1732 symbolic-oracle assertion did not hold" >&2
exit 1
