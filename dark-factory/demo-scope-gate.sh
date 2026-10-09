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
#      out-of-scope carve-outs + eligible impacts), asserting full run exit 0. The mock backend does not reason,
#      so the assertions key on the gate's DETERMINISTIC SCOPE-GATE-EVIDENCE| line (#2301): the scope source
#      precedence (SCOPE_FILE > IN_SCOPE > none), the location normalization, the 0/1 asset match, and the
#      no-scope INCOMPLETE verdict that spends no prompt.
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

if grep -q 'fn asset_listed' "$GATE" && grep -q 'fn basename_listed' "$GATE" && grep -q 'index_of(scope, ' "$GATE"; then
  ok "scope-gate.ag does a deterministic asset-path match (native index_of muscle)"
else
  bad "scope-gate.ag missing the deterministic asset-match muscle"
fi

# #2301: IN_SCOPE is the fallback scope source, the location is normalized to its asset path, a no-scope run is a
# deterministic INCOMPLETE, and the gate prints a deterministic evidence line.
if grep -q 'getenv("IN_SCOPE")' "$GATE" && grep -q 'fn resolve_scope' "$GATE" && grep -q 'fn normalize_location' "$GATE" \
   && grep -q 'SCOPE-GATE|INCOMPLETE' "$GATE" && grep -q 'SCOPE-GATE-EVIDENCE|' "$GATE"; then
  ok "scope-gate.ag falls back to IN_SCOPE, normalizes the location, has the INCOMPLETE verdict + evidence line (#2301)"
else
  bad "scope-gate.ag missing the #2301 IN_SCOPE fallback / normalize_location / INCOMPLETE / evidence line"
fi

# #2301: the LLM-originated location must never be interpolated into a shell string again.
if grep -qF "'\${loc}'" "$GATE"; then
  bad "scope-gate.ag still interpolates the finding location into exec sh ('\${loc}')"
else
  ok "scope-gate.ag never interpolates the finding location into exec sh"
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
    echo "exec.env_passthrough = SCOPE_FILE,IN_SCOPE,FINDING_LOCATION,FINDING_IMPACT"
  } >> "$WORK/run/.agentis/config"
  # run_gate <log> <SCOPE_FILE> <IN_SCOPE> <FINDING_LOCATION> -> rc; the agent's whole output lands in <log>.
  run_gate() {
    (
      cd "$WORK/run" || exit 90
      export SCOPE_FILE="$2" IN_SCOPE="$3" FINDING_LOCATION="$4" \
             FINDING_IMPACT="unprivileged reconciliation underflow freezes NAV updates"
      # --grant-pii: scope text carries repo URLs that can trip the PII heuristic; the fixture is benign.
      agentis go scope-gate.ag --enable-exec --enable-messaging --grant-pii
    ) >"$1" 2>&1
  }
  # expect_line <log> <fixed substring> <label>
  expect_line() {
    if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 — expected '$2' in:"; sed 's/^/      /' "$1" | tail -8 >&2; fi
  }

  run_gate "$WORK/out.log" "$WORK/scope.txt" "" "src/components/strategy/StrategyBaseUpgradeable.sol"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "agentis go scope-gate.ag ran end-to-end over the fixture scope (exit 0)"
  else
    bad "agentis go scope-gate.ag failed on the fixture (exit $rc):"
    sed 's/^/      /' "$WORK/out.log" | head -20 >&2
  fi
  expect_line "$WORK/out.log" "SCOPE-GATE-EVIDENCE|source=scope-file|asset=src/components/strategy/StrategyBaseUpgradeable.sol|exact=0|basename=0|" \
    "an unlisted asset in a SCOPE_FILE scope -> evidence source=scope-file exact=0 basename=0"

  # #2301 — location normalization, keyed on the deterministic asset= field (IN_SCOPE carries a non-empty scope).
  _i=0
  while IFS='|' read -r _loc _want; do
    _i=$((_i + 1))
    run_gate "$WORK/norm$_i.log" "" "IN-SCOPE ASSETS: src/vault/Vault.sol" "$_loc"
    expect_line "$WORK/norm$_i.log" "|asset=$_want|" "normalize_location: '$_loc' -> '$_want'"
  done <<'NORM'
src/vault/Vault.sol:withdraw:908|src/vault/Vault.sol
src/oracle/Oracle.sol:42|src/oracle/Oracle.sol
src/v1.2/Foo.sol:bar|src/v1.2/Foo.sol
programs/x/src/lib.rs:handler:42|programs/x/src/lib.rs
0xAbC|0xAbC
eth:0xAbC|eth:0xAbC
NORM

  # #2301 — IN_SCOPE alone is a scope source: the listed asset matches exactly.
  run_gate "$WORK/inscope.log" "" "IN-SCOPE ASSETS: src/vault/Vault.sol, src/oracle/Oracle.sol" "src/vault/Vault.sol:withdraw:908"
  expect_line "$WORK/inscope.log" "SCOPE-GATE-EVIDENCE|source=in-scope|asset=src/vault/Vault.sol|exact=1|" \
    "IN_SCOPE only -> evidence source=in-scope exact=1 (#2301)"

  # #2301 — an unreadable SCOPE_FILE falls back to IN_SCOPE (the gate itself never errors on a bad path).
  run_gate "$WORK/fallback.log" "$WORK/does-not-exist.txt" "IN-SCOPE ASSETS: src/vault/Vault.sol" "src/vault/Vault.sol"
  expect_line "$WORK/fallback.log" "SCOPE-GATE-EVIDENCE|source=in-scope|asset=src/vault/Vault.sol|exact=1|" \
    "unreadable SCOPE_FILE + IN_SCOPE -> falls back to source=in-scope"

  # #2301 — SCOPE_FILE content wins over an unrelated IN_SCOPE.
  run_gate "$WORK/precedence.log" "$WORK/scope.txt" "IN-SCOPE ASSETS: src/strategy/Unrelated.sol" \
    "src/components/value/ValuationHandler.sol:update:12"
  expect_line "$WORK/precedence.log" "SCOPE-GATE-EVIDENCE|source=scope-file|asset=src/components/value/ValuationHandler.sol|exact=1|" \
    "SCOPE_FILE + unrelated IN_SCOPE -> source=scope-file wins, listed asset exact=1"

  # #2301 — no scope text at all: a deterministic INCOMPLETE verdict, and NO prompt is spent.
  run_gate "$WORK/none.log" "" "" "src/vault/Vault.sol:withdraw:908"
  expect_line "$WORK/none.log" "SCOPE-GATE-EVIDENCE|source=none|" "no scope text -> evidence source=none"
  expect_line "$WORK/none.log" "SCOPE-GATE|INCOMPLETE|" "no scope text -> SCOPE-GATE|INCOMPLETE (never a silent OUT-OF-SCOPE-ASSET)"
  if grep -q '^\[prompt\]' "$WORK/none.log"; then
    bad "no scope text still spent a prompt() call"
  else
    ok "no scope text -> no prompt() call"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAIL" -eq 0 ]; then note "PASS — scope-gate wiring holds"; exit 0; fi
note "FAIL — a scope-gate assertion regressed" >&2
exit 1
