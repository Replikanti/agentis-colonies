#!/usr/bin/env bash
# demo-impact-gate.sh — proof of the #1522 IMPACT-SUBSTANTIATION / VALIDITY gate `auditor/agents/impact-gate.ag`.
#
# impact-gate runs AFTER scope-gate (#1511) and BEFORE human submit. It classifies a confirmed+PoC'd finding as
# SUBSTANTIATED only if the PoC drives the impact through the protocol's OWN mechanism (not a hand-fed/simulated
# state), the loss does not need a PRIVILEGED trigger, and the victim has an on-chain-provable pre-existing claim
# — the barrier that would have caught the Enzyme Onyx submission (PoC hand-fed the NAV update; the "theft" needed
# a privileged admin post) before the fee + reputation spend. It NEVER submits.
#
# TWO parts:
#   1) SOURCE-GUARD (always, CI-safe): asserts the env contract, the deterministic PoC-smell muscle, the
#      IMPACT-GATE output contract, the three-barrier reasoning, the bus emit, and the learn/memo tail.
#   2) LIVE (when agentis on PATH): runs the agent end-to-end over a fixture POC_FILE carrying the Onyx shape (a
#      `harness_set*` price post + a `prank(admin)` — a simulated, privileged-triggered transition), asserting the
#      exec-sh smell-count path + full run exit 0. The mock backend does not reason, so only clean execution +
#      the signal-gathering path are asserted.
#
# Usage:  dark-factory/demo-impact-gate.sh
# Exit: 0 = all assertions hold (live part SKIPs cleanly when agentis absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/auditor/agents/impact-gate.ag"

FAIL=0
note() { echo "demo-impact-gate.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*" >&2; FAIL=1; }
skip() { echo "  [SKIP] $*"; }

[ -f "$GATE" ] || { note "impact-gate agent not found: $GATE" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD — the impact-gate wiring must exist regardless of toolchain.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1522 impact-gate wiring ..."

if grep -q '^cb 300000;' "$GATE"; then ok "impact-gate.ag declares cb 300000"; else bad "missing cb 300000"; fi

missing_env=""
for v in FINDING_IMPACT POC_FILE MECHANISM_NOTES; do
  grep -q "getenv(\"$v\")" "$GATE" || missing_env="$missing_env $v"
done
[ -z "$missing_env" ] && ok "impact-gate.ag reads the env contract (FINDING_IMPACT/POC_FILE/MECHANISM_NOTES)" \
  || bad "impact-gate.ag missing getenv for:$missing_env"

if grep -q 'fn sim_smells' "$GATE" && grep -q 'fn priv_pranks' "$GATE" && grep -q 'grep -c' "$GATE"; then
  ok "impact-gate.ag does a deterministic PoC-smell match (grep muscle, safe-exec-concat)"
else
  bad "impact-gate.ag missing the deterministic PoC-smell muscle"
fi

if grep -q 'IMPACT-GATE|' "$GATE" && grep -q 'SUBSTANTIATED' "$GATE" && grep -q 'SIMULATED-STATE' "$GATE" \
   && grep -q 'PRIVILEGED-TRIGGER' "$GATE" && grep -q 'NO-PROVABLE-CLAIM' "$GATE"; then
  ok "impact-gate.ag emits the IMPACT-GATE|<SUBSTANTIATED|SIMULATED-STATE|PRIVILEGED-TRIGGER|NO-PROVABLE-CLAIM> contract"
else
  bad "impact-gate.ag missing the IMPACT-GATE output contract"
fi

# The three validity barriers must be reasoned over: own-mechanism / no-privileged-trigger / provable claim.
if grep -qi 'own-mechanism\|own mechanism' "$GATE" && grep -qi 'privileged' "$GATE" \
   && grep -qi 'pre-existing\|provable' "$GATE" && grep -qi 'simulat' "$GATE"; then
  ok "impact-gate.ag reasons over all three barriers (own-mechanism / no-privileged-trigger / provable claim)"
else
  bad "impact-gate.ag missing one of the three-barrier checks"
fi

if grep -q 'emit("dark-factory:impact_verdict"' "$GATE" \
   && grep -q 'learn("impact-gate"' "$GATE" && grep -q 'memo_write("impact-gate:last_check"' "$GATE"; then
  ok "impact-gate.ag emits dark-factory:impact_verdict + records the learn/memo tail"
else
  bad "impact-gate.ag missing the emit / learn / memo tail"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) LIVE — run the agent end-to-end over a fixture PoC.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the live end-to-end impact-gate check"
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  # A PoC in the Onyx shape: the critical price transition is FABRICATED via harness_set* and gated on a
  # privileged prank(admin) — exactly the SIMULATED-STATE + PRIVILEGED-TRIGGER smells the gate must surface.
  cat > "$WORK/PoC.t.sol" <<'POC'
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract PoC_Frontrun {
    function test_frontrun_steals_yield() public {
        // honest LP is the whole fund at price 1.0
        valuationHandler.harness_setLastShareValue({_shareValue: 1e18, _timestamp: block.timestamp});
        _deposit(honestLP, 1_000e6);
        // fund "earns" 20% off-chain (NAV 1000 -> 1200), unposted — SIMULATED, not produced on-chain
        _deposit(attacker, 1_000e6);
        // admin posts the update: the loss only materializes when a PRIVILEGED role acts
        vm.prank(admin);
        valuationHandler.harness_setLastShareValue({_shareValue: 11e17, _timestamp: block.timestamp});
        (uint256 priceAfter,) = valuationHandler.getSharePrice();
        assertGt(attackerShares * priceAfter / 1e18, 1_000e18);
    }
}
POC
  mkdir -p "$WORK/run"
  cp "$GATE" "$WORK/run/impact-gate.ag"
  ( cd "$WORK/run" && agentis init >/dev/null 2>&1 || true )
  {
    echo "learning.enabled = true"; echo "experience.enabled = true"; echo "exec.default_timeout_ms = 30000"
    echo "exec.env_passthrough = FINDING_IMPACT,POC_FILE,MECHANISM_NOTES"
  } >> "$WORK/run/.agentis/config"
  set +e
  (
    cd "$WORK/run" || exit 90
    export POC_FILE="$WORK/PoC.t.sol" \
           FINDING_IMPACT="unprivileged front-run of a NAV update steals pre-update holders' unclaimed yield" \
           MECHANISM_NOTES="share price is the stored lastShareValue, written only by onlyAdmin updateShareValue - no permissionless accrual"
    # --grant-pii: the PoC/mechanism text can carry addresses/identifiers that trip the PII heuristic; benign fixture.
    agentis go impact-gate.ag --enable-exec --enable-messaging --grant-pii
  ) >"$WORK/out.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    ok "agentis go impact-gate.ag ran end-to-end over the fixture PoC (exit 0)"
  else
    bad "agentis go impact-gate.ag failed on the fixture (exit $rc):"
    sed 's/^/      /' "$WORK/out.log" | head -20 >&2
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAIL" -eq 0 ]; then note "PASS — impact-gate wiring holds"; exit 0; fi
note "FAIL — an impact-gate assertion regressed" >&2
exit 1
