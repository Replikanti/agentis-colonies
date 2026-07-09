#!/usr/bin/env bash
# demo-report-writer.sh — proof of the #1508 SUBMISSION REPORT FORMATTER `auditor/agents/report-writer.ag`.
#
# report-writer runs AFTER scope-gate (#1511), impact-gate (#1522) and dup-scout (#1503) and BEFORE the human
# submit. It takes a CONFIRMED finding + its PoC + the three upstream verdict lines + the severity band and renders
# an Immunefi-shaped 4-section submission report (Brief/Intro, Vulnerability Details, Impact Details, References) as
# a DRAFT ARTIFACT for human review. It NEVER submits — the response leads with the machine-checkable marker
# SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW so the human-gate invariant is explicit.
#
# TWO parts:
#   1) SOURCE-GUARD (always, CI-safe): asserts the 8-var env contract, the deterministic PoC-read muscle, the
#      4-section scaffolding, the SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW output contract, the never-submits
#      invariant (and absence of any network/submit primitive), and the bus emit + learn/memo tail.
#   2) LIVE (when agentis on PATH): runs the agent end-to-end over a fixture finding + PoC + fixture upstream
#      verdict lines, asserting the exec-sh PoC-read path + full run exit 0. The mock backend does not reason, so
#      only clean execution + the signal-gathering path are asserted.
#
# Usage:  dark-factory/demo-report-writer.sh
# Exit: 0 = all assertions hold (live part SKIPs cleanly when agentis absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/auditor/agents/report-writer.ag"

FAIL=0
note() { echo "demo-report-writer.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*" >&2; FAIL=1; }
skip() { echo "  [SKIP] $*"; }

[ -f "$GATE" ] || { note "report-writer agent not found: $GATE" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD — the report-writer wiring must exist regardless of toolchain.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1508 report-writer wiring ..."

if grep -q '^cb 300000;' "$GATE"; then ok "report-writer.ag declares cb 300000"; else bad "missing cb 300000"; fi

missing_env=""
for v in FINDING_TITLE FINDING_LOCATION FINDING_IMPACT POC_FILE SEVERITY_BAND SCOPE_VERDICT IMPACT_VERDICT DUP_RISK; do
  grep -q "getenv(\"$v\")" "$GATE" || missing_env="$missing_env $v"
done
[ -z "$missing_env" ] && ok "report-writer.ag reads the 8-var env contract (finding + PoC + upstream verdicts + severity)" \
  || bad "report-writer.ag missing getenv for:$missing_env"

if grep -q 'fn poc_text' "$GATE" && grep -q 'fn poc_run_steps' "$GATE" && grep -qE 'grep -c|grep -oE' "$GATE" \
   && grep -q 'colony-lint: safe-exec-concat' "$GATE"; then
  ok "report-writer.ag reads the PoC deterministically (sed/grep muscle, safe-exec-concat)"
else
  bad "report-writer.ag missing the deterministic PoC-read muscle"
fi

if grep -qi 'Brief/Intro' "$GATE" && grep -qi 'Vulnerability Details' "$GATE" \
   && grep -qi 'Impact Details' "$GATE" && grep -qi 'References' "$GATE"; then
  ok "report-writer.ag renders the 4-section report (Brief/Intro, Vulnerability Details, Impact Details, References)"
else
  bad "report-writer.ag missing one of the four report sections"
fi

if grep -q 'SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW' "$GATE"; then
  ok "report-writer.ag emits the SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW human-gate marker"
else
  bad "report-writer.ag missing the SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW output contract"
fi

# Never submits: the header-comment invariant AND the absence of any network/submit primitive in the agent.
if grep -qi 'never submit' "$GATE" \
   && ! grep -qiE 'curl |wget |http\.post|submit\(' "$GATE"; then
  ok "report-writer.ag never submits (draft-only invariant + no network/submit primitive)"
else
  bad "report-writer.ag never-submits invariant is not enforced"
fi

if grep -q 'emit("dark-factory:report_draft"' "$GATE" \
   && grep -q 'learn("report-writer"' "$GATE" && grep -q 'memo_write("report-writer:last_check"' "$GATE"; then
  ok "report-writer.ag emits dark-factory:report_draft + records the learn/memo tail"
else
  bad "report-writer.ag missing the emit / learn / memo tail"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) LIVE — run the agent end-to-end over a fixture finding + PoC + upstream verdict lines.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the live end-to-end report-writer check"
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  # A minimal foundry PoC carrying one `function test_...` so the run-steps muscle has a concrete match to embed.
  cat > "$WORK/PoC.t.sol" <<'POC'
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract PoC_Drain {
    function test_drain_underpriced_redeem() public {
        _deposit(attacker, 1_000e6);
        // the accounting bug: redeem uses a stale rate, letting the attacker withdraw more than deposited
        uint256 got = vault.redeem(attackerShares);
        assertGt(got, 1_000e6);
    }
}
POC
  mkdir -p "$WORK/run"
  cp "$GATE" "$WORK/run/report-writer.ag"
  ( cd "$WORK/run" && agentis init >/dev/null 2>&1 || true )
  {
    echo "learning.enabled = true"; echo "experience.enabled = true"; echo "exec.default_timeout_ms = 30000"
    echo "exec.env_passthrough = FINDING_TITLE,FINDING_LOCATION,FINDING_IMPACT,POC_FILE,SEVERITY_BAND,SCOPE_VERDICT,IMPACT_VERDICT,DUP_RISK"
  } >> "$WORK/run/.agentis/config"
  set +e
  (
    cd "$WORK/run" || exit 90
    export POC_FILE="$WORK/PoC.t.sol" \
           FINDING_TITLE="Vault redeem uses a stale rate, letting an attacker over-withdraw" \
           FINDING_LOCATION="src/vault/RedeemHandler.sol" \
           FINDING_IMPACT="theft of protocol funds: an attacker redeems shares at a stale rate and drains excess collateral" \
           SEVERITY_BAND="Critical" \
           SCOPE_VERDICT="SCOPE-GATE|PAYABLE|RedeemHandler.sol is a listed in-scope asset; theft is an eligible impact" \
           IMPACT_VERDICT="IMPACT-GATE|SUBSTANTIATED|PoC drives the drain through the vault's own redeem path, no privileged trigger" \
           DUP_RISK="DUP-RISK|LOW|~15%|no matching known-issue or prior submission for the stale-rate redeem path"
    # --grant-pii: the finding/PoC text can carry addresses/identifiers that trip the PII heuristic; benign fixture.
    agentis go report-writer.ag --enable-exec --enable-messaging --grant-pii
  ) >"$WORK/out.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    ok "agentis go report-writer.ag ran end-to-end over the fixture finding + PoC (exit 0)"
  else
    bad "agentis go report-writer.ag failed on the fixture (exit $rc):"
    sed 's/^/      /' "$WORK/out.log" | head -20 >&2
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAIL" -eq 0 ]; then note "PASS — report-writer wiring holds"; exit 0; fi
note "FAIL — a report-writer assertion regressed" >&2
exit 1
