#!/usr/bin/env bash
# demo-scope-gate.sh — proof of the #1511 SCOPE + ELIGIBILITY gate `auditor/agents/scope-gate.ag`.
#
# scope-gate classifies a confirmed finding as PAYABLE only if its LOCATION is an in-scope asset AND its IMPACT
# is eligible + not an out-of-scope/known-issues carve-out — the barrier that killed the Lombard (out-of-scope
# asset) and Onyx (excluded-carveout) submissions. It runs BEFORE any DEVISE/PoC spend; it never submits.
#
# TWO parts:
#   1) SOURCE-GUARD (always, CI-safe): asserts the env contract, the deterministic asset-match muscle, the
#      SCOPE-GATE output contract, the bus emit, and the learn/memo tail.
#   2) LIVE (when agentis on PATH): runs the agent end-to-end over a fixture SCOPE_FILE (asset list +
#      out-of-scope carve-outs + eligible impacts), asserting the exec-sh asset-match + full run exit 0. The
#      mock backend does not reason, so only clean execution + the signal-gathering path are asserted.
#
# Usage:  dark-factory/demo-scope-gate.sh
# Exit: 0 = all assertions hold (live part SKIPs cleanly when agentis absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/auditor/agents/scope-gate.ag"

FAIL=0
note() { echo "demo-scope-gate.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*" >&2; FAIL=1; }
skip() { echo "  [SKIP] $*"; }

[ -f "$GATE" ] || { note "scope-gate agent not found: $GATE" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD — the scope-gate wiring must exist regardless of toolchain.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1511 scope-gate wiring ..."

if grep -q '^cb 300000;' "$GATE"; then ok "scope-gate.ag declares cb 300000"; else bad "missing cb 300000"; fi

missing_env=""
for v in SCOPE_FILE FINDING_LOCATION FINDING_IMPACT; do
  grep -q "getenv(\"$v\")" "$GATE" || missing_env="$missing_env $v"
done
[ -z "$missing_env" ] && ok "scope-gate.ag reads the env contract (SCOPE_FILE/FINDING_LOCATION/FINDING_IMPACT)" \
  || bad "scope-gate.ag missing getenv for:$missing_env"

if grep -q 'fn asset_listed' "$GATE" && grep -q 'fn basename_listed' "$GATE" && grep -q 'grep -c -F' "$GATE"; then
  ok "scope-gate.ag does a deterministic asset-path match (grep muscle, safe-exec-concat)"
else
  bad "scope-gate.ag missing the deterministic asset-match muscle"
fi

if grep -q 'SCOPE-GATE|' "$GATE" && grep -q 'PAYABLE' "$GATE" && grep -q 'OUT-OF-SCOPE-ASSET' "$GATE" \
   && grep -q 'EXCLUDED-CARVEOUT' "$GATE" && grep -q 'INELIGIBLE-IMPACT' "$GATE"; then
  ok "scope-gate.ag emits the SCOPE-GATE|<PAYABLE|OUT-OF-SCOPE-ASSET|EXCLUDED-CARVEOUT|INELIGIBLE-IMPACT> contract"
else
  bad "scope-gate.ag missing the SCOPE-GATE output contract"
fi

# The three barriers must be reasoned over: asset list, out-of-scope/known-issues (incl. audit-noted), eligible impacts.
if grep -qi 'in-scope asset' "$GATE" && grep -qi 'out-of-scope\|known-issue\|carve' "$GATE" \
   && grep -qi 'eligible' "$GATE" && grep -qi 'audit report' "$GATE"; then
  ok "scope-gate.ag reasons over all three barriers (asset / carve-out incl. audit-noted / eligible-impact)"
else
  bad "scope-gate.ag missing one of the three-barrier checks"
fi

if grep -q 'emit("dark-factory:scope_verdict"' "$GATE" \
   && grep -q 'learn("scope-gate"' "$GATE" && grep -q 'memo_write("scope-gate:last_check"' "$GATE"; then
  ok "scope-gate.ag emits dark-factory:scope_verdict + records the learn/memo tail"
else
  bad "scope-gate.ag missing the emit / learn / memo tail"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) LIVE — run the agent end-to-end over a fixture scope.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the live end-to-end scope-gate check"
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  cat > "$WORK/scope.txt" <<'SCOPE'
IN-SCOPE ASSETS
https://github.com/acme/protocol/blob/main/src/components/issuance/redeem-handlers/ERC7540LikeRedeemQueue.sol
https://github.com/acme/protocol/blob/main/src/components/value/ValuationHandler.sol
OUT OF SCOPE / KNOWN ISSUES
- Deposit/redeem handler DoS from request cancellations (minRequestDuration)
- Anything noted in the audit reports is out of scope.
ELIGIBLE IMPACTS (smart contract)
Critical: direct theft of user funds; permanent freezing of funds; protocol insolvency
High: theft of unclaimed yield; temporary freezing of funds
Medium: griefing
SCOPE
  mkdir -p "$WORK/run"
  cp "$GATE" "$WORK/run/scope-gate.ag"
  ( cd "$WORK/run" && agentis init >/dev/null 2>&1 || true )
  {
    echo "learning.enabled = true"; echo "experience.enabled = true"; echo "exec.default_timeout_ms = 30000"
    echo "exec.env_passthrough = SCOPE_FILE,FINDING_LOCATION,FINDING_IMPACT"
  } >> "$WORK/run/.agentis/config"
  set +e
  (
    cd "$WORK/run" || exit 90
    export SCOPE_FILE="$WORK/scope.txt" \
           FINDING_LOCATION="src/components/strategy/StrategyBaseUpgradeable.sol" \
           FINDING_IMPACT="unprivileged reconciliation underflow freezes NAV updates"
    # --grant-pii: scope text carries repo URLs that can trip the PII heuristic; the fixture is benign.
    agentis go scope-gate.ag --enable-exec --enable-messaging --grant-pii
  ) >"$WORK/out.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    ok "agentis go scope-gate.ag ran end-to-end over the fixture scope (exit 0)"
  else
    bad "agentis go scope-gate.ag failed on the fixture (exit $rc):"
    sed 's/^/      /' "$WORK/out.log" | head -20 >&2
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAIL" -eq 0 ]; then note "PASS — scope-gate wiring holds"; exit 0; fi
note "FAIL — a scope-gate assertion regressed" >&2
exit 1
