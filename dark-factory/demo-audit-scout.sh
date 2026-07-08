#!/usr/bin/env bash
# demo-audit-scout.sh — proof of the #1487 audit-aware DEVISE stage `auditor/agents/audit-scout.ag`.
#
# audit-scout is the .ag embodiment of the audit-awareness that until #1487 lived only in shell (#1485's
# fetch-audits.sh + novelty-gate.sh): it ingests a target's OWN audit reports and devises the RESIDUAL
# attack surface (what N prior auditors MISSED — the only rewardable part of an audited target), feeding the
# hunter / invariant-prover engines residual-focused specs and novelty-gate the exclusion boundary. fetch-
# audits.sh stays the muscle; the DEVISE decision moved onto the substrate bus.
#
# TWO parts:
#   1) SOURCE-GUARD (always, CI-safe, no toolchain): asserts the env contract, the BOUNDARY/RESIDUAL/NO-
#      RESIDUAL output contract, the fetch-audits ingest wiring, the bus emits, and the learn/memo tail — so
#      a refactor that drops the audit-awareness is caught even on runners with no agentis binary.
#   2) LIVE (when agentis is on PATH): `agentis go audit-scout.ag` over a fixture with a pre-fetched AUDIT_DIR,
#      asserting the agent runs end-to-end on the substrate (env read -> exec sh ingest -> prompt -> print ->
#      emit -> learn -> memo) and exits 0. The mock backend does not reason, so only clean execution + the
#      audit-ingest path are asserted, never a specific finding.
#
# Usage:  dark-factory/demo-audit-scout.sh
# Exit: 0 = all assertions hold (live part SKIPs cleanly when agentis is absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCOUT="$HERE/auditor/agents/audit-scout.ag"
FETCH="$HERE/fetch-audits.sh"

FAILS=0
note() { echo "demo-audit-scout.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$SCOUT" ] || { note "audit-scout agent not found: $SCOUT" >&2; exit 3; }
[ -f "$FETCH" ] || { note "fetch-audits.sh (the ingest muscle) not found: $FETCH" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD — the audit-aware DEVISE wiring must exist regardless of toolchain.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1487 audit-aware DEVISE wiring ..."

# cb decl must match the colony registration budget.
if grep -q '^cb 300000;' "$SCOUT"; then
  ok "audit-scout.ag declares cb 300000 (matches the colony cb_budget)"
else
  bad "audit-scout.ag missing the cb 300000 declaration"
fi

# The env contract: the target, its audits (pre-fetched dir OR URLs), and the fetch muscle path.
missing_env=""
for v in TARGET_DIR IN_SCOPE AUDIT_DIR AUDIT_URLS FETCH_AUDITS SCOPE_BRIEF; do
  grep -q "getenv(\"$v\")" "$SCOUT" || missing_env="$missing_env $v"
done
if [ -z "$missing_env" ]; then
  ok "audit-scout.ag reads the full env contract (TARGET_DIR/IN_SCOPE/AUDIT_DIR/AUDIT_URLS/FETCH_AUDITS/SCOPE_BRIEF)"
else
  bad "audit-scout.ag missing getenv for:$missing_env"
fi

# It ingests the target's audits via the fetch-audits.sh muscle (default sibling path + a fetch call).
if grep -q 'fetch-audits.sh' "$SCOUT" && grep -q 'fn fetch_and_read' "$SCOUT" && grep -q 'fn audit_corpus' "$SCOUT"; then
  ok "audit-scout.ag wires the fetch-audits.sh ingest muscle (audit_corpus prefers AUDIT_DIR, else fetches)"
else
  bad "audit-scout.ag does not wire the fetch-audits.sh ingest path"
fi

# The DEVISE output contract: BOUNDARY (exclusion set) + RESIDUAL (leads) + NO-RESIDUAL (clean) tokens.
if grep -q 'BOUNDARY|' "$SCOUT" && grep -q 'RESIDUAL|' "$SCOUT" && grep -q 'NO-RESIDUAL' "$SCOUT"; then
  ok "audit-scout.ag emits the BOUNDARY / RESIDUAL / NO-RESIDUAL output contract"
else
  bad "audit-scout.ag missing a BOUNDARY / RESIDUAL / NO-RESIDUAL output token"
fi

# The prompt must anchor on the residual (known = unrewardable; only what auditors missed pays).
if grep -q 'RESIDUAL' "$SCOUT" && grep -qi 'known' "$SCOUT" && grep -qi 'downgrad' "$SCOUT"; then
  ok "audit-scout.ag devise prompt anchors on the residual (known/downgraded excluded)"
else
  bad "audit-scout.ag devise prompt does not anchor on the residual boundary"
fi

# The bus emits that feed the attack engines + novelty-gate, and the fitness/idle tail.
if grep -q 'emit("dark-factory:audit_boundary"' "$SCOUT" \
   && grep -q 'emit("dark-factory:residual_hypothesis"' "$SCOUT"; then
  ok "audit-scout.ag emits dark-factory:audit_boundary + dark-factory:residual_hypothesis"
else
  bad "audit-scout.ag missing a dark-factory:audit_boundary / residual_hypothesis emit"
fi
if grep -q 'learn("devise"' "$SCOUT" && grep -q 'memo_write("audit-scout:last_check"' "$SCOUT"; then
  ok "audit-scout.ag records the devise attempt (learn) + writes its last_check memo"
else
  bad "audit-scout.ag missing the learn/memo tail"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) LIVE — run the agent end-to-end on the substrate over a fixture with a pre-fetched AUDIT_DIR.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the live end-to-end audit-scout check"
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  # A tiny in-scope target + a pre-fetched audit report (the fetch-audits.sh NN-*.txt layout) with one known
  # finding, so the ingest path is exercised without any network.
  mkdir -p "$WORK/target/src" "$WORK/audits" "$WORK/run"
  cat > "$WORK/target/src/Vault.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Vault {
  mapping(address => uint) public bal;
  function deposit() external payable { bal[msg.sender] += msg.value; }
  function withdraw(uint a) external { bal[msg.sender] -= a; payable(msg.sender).transfer(a); }
}
SOL
  cat > "$WORK/audits/01-known.txt" <<'TXT'
Audit report — Vault
[High] Reentrancy in withdraw(): external transfer before balance update is a known finding, fixed.
TXT
  cp "$SCOUT" "$WORK/run/audit-scout.ag"
  # Init the store FIRST, then write the config: experience/learning for the learn() tail, and the
  # exec.env_passthrough allowlist WITHOUT which getenv() reads a sanitized (empty) env and the ingest
  # path never sees the fixture (mirrors run-discovery.sh's store setup).
  ( cd "$WORK/run" && agentis init >/dev/null 2>&1 || true )
  {
    echo "learning.enabled = true"
    echo "experience.enabled = true"
    echo "exec.default_timeout_ms = 30000"
    echo "exec.env_passthrough = TARGET_DIR,IN_SCOPE,AUDIT_DIR,AUDIT_URLS,FETCH_AUDITS,SCOPE_BRIEF"
  } >> "$WORK/run/.agentis/config"
  set +e
  (
    cd "$WORK/run" || exit 90
    export TARGET_DIR="$WORK/target" IN_SCOPE="src/Vault.sol" \
           AUDIT_DIR="$WORK/audits" FETCH_AUDITS="$FETCH" SCOPE_BRIEF=""
    agentis go audit-scout.ag --enable-exec --enable-messaging
  ) >"$WORK/out.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    ok "agentis go audit-scout.ag ran end-to-end over the fixture AUDIT_DIR (exit 0)"
  else
    bad "agentis go audit-scout.ag failed on the fixture (exit $rc):"
    sed 's/^/      /' "$WORK/out.log" | head -20 >&2
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — audit-aware DEVISE stage wiring holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
