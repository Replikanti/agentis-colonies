#!/usr/bin/env bash
# demo-symbolic-orchestrate-live.sh — #1032: the LIVE coordinator -> Halmos symbolic-prove route, end-to-end.
#
# demo-symbolic-orchestrate.sh proves the OFFLINE orchestration: the self-orchestrating coordinator CHOOSES
# `symbolic-prove` for a pending candidate and a DISPATCH_FIXTURE stands in for the SOUND verdict. THIS demo
# closes the LIVE slice: with an operator-supplied single-candidate symbolic context (SYM_REPO + SYM_SPEC +
# the HALMOS_VERIFY gate path), the coordinator's chosen `symbolic-prove` action runs REAL Halmos
# (symbolic execution + z3) END-TO-END inside the autonomous loop and maps its SOUND exit code to the gate
# outcome — never an LLM opinion:
#   exit 1 = COUNTEREXAMPLE -> confirmed   (a concrete input is a real bug, CONFIRMED with a witness)
#   exit 0 = PROVED         -> refuted     (the invariant holds for ALL inputs — the lead is killed by a proof)
#   exit 3/2/other = INCONCLUSIVE/harness -> dry
#
# The fixture for the live route is a tiny Foundry vault with a REAL rounding-direction solvency bug:
# `convertToAssets` rounds UP (`(shares*totalAssets + totalShares - 1) / totalShares`), so it can pay out
# MORE than the fair floor `shares*totalAssets/totalShares` — value is minted, the vault becomes insolvent.
# The Halmos spec asserts the solvency invariant `paid <= shares*totalAssets/totalShares` over SYMBOLIC
# inputs: against the buggy vault Halmos returns a concrete COUNTEREXAMPLE (-> confirmed); against the FIXED
# vault (round DOWN — `shares*totalAssets/totalShares`) Halmos PROVES it for all inputs (-> refuted).
#
# The coordinator is driven with a PENDING candidate seeded directly (so `symbolic-prove` is the chosen
# VERIFY action immediately, with --sym-policy-style SYM_POLICY_TT lifting it over refute/poc-screen) and the
# live SYM env supplied — exactly the single-candidate context run-coordinator.sh's --sym-repo/--sym-spec
# flags wire. The multi-candidate code-carrying path (a discovered lead auto-carrying its contract+invariant
# through PENDING) stays a broader follow-up; this demo proves the symbolic slice runs Halmos for real.
#
# CI has neither halmos nor forge (nor necessarily agentis), so if ANY is missing this prints a single
# [SKIP] line and exits 0 (mirroring demo-symbolic.sh / the colony-lint skip convention) instead of failing.
# Install the toolchain to run it for real:
#   curl -L https://foundry.paradigm.xyz | bash && foundryup    # forge
#   uv tool install halmos                                      # halmos (bundles z3)
#
# Usage:  dark-factory/demo-symbolic-orchestrate-live.sh
# Exit: 0 = both live verdicts correct (or tools absent -> SKIP) ; non-zero = a live verdict was wrong.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
COORD_AG="$HERE/auditor/agents/coordinator.ag"
GATE="$HERE/evm-harness/halmos-verify.sh"
RUNNER="$HERE/run-coordinator.sh"

FAILS=0
note() { echo "demo-symbolic-orchestrate-live.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

# Skip EARLY (before any work) when the toolchain is missing, so CI without halmos/forge/agentis reports a
# clean [SKIP] + exit 0 rather than a harness error.
if ! command -v forge >/dev/null 2>&1 || ! command -v halmos >/dev/null 2>&1; then
  skip "forge and/or halmos not on PATH — install foundryup + 'uv tool install halmos' to run this demo"
  exit 0
fi
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the agentis runtime to drive the substrate coordinator loop"
  exit 0
fi

[ -f "$COORD_AG" ] || { note "coordinator agent not found at $COORD_AG" >&2; exit 3; }
[ -f "$GATE" ]     || { note "halmos-verify gate not found at $GATE" >&2; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- build the tiny Foundry vault repo: a real rounding-direction solvency bug + its fix ---------------
# VaultBuggy.convertToAssets rounds UP (mints value -> insolvent); VaultFixed rounds DOWN (floor -> solvent).
# uint16 widths keep the symbolic search tiny so z3 returns a sound verdict in seconds. Specs are written
# with printf '%s' / heredocs of TRUSTED static content authored HERE (not an LLM completion / untrusted
# candidate code), so no shell_escape gymnastics are needed; the substrate write path (symbolic-prover.ag)
# is the one that escapes UNTRUSTED specs.
REPO="$WORK/vault"
mkdir -p "$REPO/src" "$REPO/test"
cat > "$REPO/foundry.toml" <<'EOF'
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
test = "test"
EOF
cat > "$REPO/src/Vault.sol" <<'EOF'
// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

// A share-accounting vault. convertToAssets(shares) converts a share balance to its
// redeemable asset amount. The SOLVENCY invariant is that a redemption never pays out
// MORE than the fair floor `shares * totalAssets / totalShares` — paying more mints value
// and makes the vault insolvent. uint16 widths keep the symbolic search space tiny.
contract VaultBuggy {
    // BUG: rounds UP (`+ totalShares - 1`), so a redemption can pay out one wei more than
    // the fair floor — value is minted, the vault becomes insolvent. Halmos finds a concrete
    // (shares, totalAssets, totalShares) witness that breaks `paid <= floor`.
    function convertToAssets(uint16 shares, uint16 totalAssets, uint16 totalShares)
        external pure returns (uint16)
    {
        require(totalShares > 0, "no shares");
        require(shares <= totalShares, "too many");
        uint256 num = uint256(shares) * uint256(totalAssets) + uint256(totalShares) - 1;
        return uint16(num / uint256(totalShares));
    }
}

contract VaultFixed {
    // FIX: rounds DOWN (floor division), so the payout never exceeds the fair floor —
    // solvency holds for ALL inputs and Halmos PROVES it.
    function convertToAssets(uint16 shares, uint16 totalAssets, uint16 totalShares)
        external pure returns (uint16)
    {
        require(totalShares > 0, "no shares");
        require(shares <= totalShares, "too many");
        uint256 num = uint256(shares) * uint256(totalAssets);
        return uint16(num / uint256(totalShares));
    }
}
EOF
cat > "$REPO/test/SolvencyBuggy.t.sol" <<'EOF'
// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import {VaultBuggy} from "../src/Vault.sol";

// SOLVENCY spec against the BUGGY vault: assert the redemption never exceeds the fair floor.
// The round-UP bug violates it -> Halmos returns a COUNTEREXAMPLE (exit 1) -> outcome `confirmed`.
contract SolvencyBuggyTest {
    VaultBuggy internal vault;
    function setUp() public { vault = new VaultBuggy(); }

    function check_solvency(uint16 shares, uint16 totalAssets, uint16 totalShares) public view {
        if (totalShares == 0) return;
        if (shares > totalShares) return;
        uint16 paid = vault.convertToAssets(shares, totalAssets, totalShares);
        uint256 fairFloor = (uint256(shares) * uint256(totalAssets)) / uint256(totalShares);
        assert(uint256(paid) <= fairFloor);
    }
}
EOF
cat > "$REPO/test/SolvencyFixed.t.sol" <<'EOF'
// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import {VaultFixed} from "../src/Vault.sol";

// SAME solvency spec against the FIXED vault: round-DOWN payout never exceeds the floor, so
// Halmos PROVES it for ALL inputs (exit 0) -> outcome `refuted` (the lead is killed by a proof).
contract SolvencyFixedTest {
    VaultFixed internal vault;
    function setUp() public { vault = new VaultFixed(); }

    function check_solvency(uint16 shares, uint16 totalAssets, uint16 totalShares) public view {
        if (totalShares == 0) return;
        if (shares > totalShares) return;
        uint16 paid = vault.convertToAssets(shares, totalAssets, totalShares);
        uint256 fairFloor = (uint256(shares) * uint256(totalAssets)) / uint256(totalShares);
        assert(uint256(paid) <= fairFloor);
    }
}
EOF

# --- the coordinator store, configured EXACTLY like run-coordinator.sh's orchestrate bootstrap with the
# LIVE symbolic env whitelisted (SYM_REPO/SYM_SPEC/SYM_FUNCTION/HALMOS_VERIFY) + the 180s exec timeout the
# live Halmos run needs. $1 = store dir. ---------------------------------------------------------------
init_store() {
  _d="$1"; mkdir -p "$_d"; cp "$COORD_AG" "$_d/coordinator.ag"
  ( cd "$_d" && agentis init >/dev/null 2>&1 )
  {
    echo "llm.backend = mock"
    echo "trace.level = normal"
    echo "exec.env_passthrough = SCOPE,CLASS_FITNESS,POLICY,PENDING,BUDGET,DRY_STREAK,DRY_CAP,PREV_ACTION,PREV_KEY,LAST_OUTCOME,DISPATCH_ENABLED,DISPATCH_FIXTURE,HUNT_FIXTURE,ORCHESTRATE_ENABLED,STEPS,SYM_POLICY_TT,SYM_REPO,SYM_SPEC,SYM_FUNCTION,HALMOS_VERIFY"
    echo "exec.default_timeout_ms = 180000"
    echo "learning.enabled = true"
    echo "experience.enabled = true"
  } > "$_d/.agentis/config"
}

# The FACTS: one huntable cell, a candidate seeded directly into PENDING (so symbolic-prove is the chosen
# VERIFY action immediately), the symbolic-prove policy SEEDED (SYM_POLICY_TT=15000 = +1.5) so it outranks
# refute/poc-screen, and the LIVE symbolic env supplied so the chosen action runs REAL Halmos. BUDGET=1: one
# decision, one live symbolic verify. $1 = store, $2 = the SYM_SPEC the live route runs.
SCOPE_FX=$'vault accounting|C1'
FIT_FX="C1=0.5500"
orchestrate_live() {
  _store="$1"; _spec="$2"
  # --grant-pii: scope + spec repo text can carry addresses/identifiers that trip the PII heuristic;
  # benign fixture, kept uniform with the other flagged demos + recurrence defense (#1690).
  ( cd "$_store" && env \
      SCOPE="$SCOPE_FX" CLASS_FITNESS="$FIT_FX" PENDING="cand-0|vault accounting|C1" \
      BUDGET=1 DRY_CAP=3 STEPS="0" SYM_POLICY_TT=15000 \
      SYM_REPO="$REPO" SYM_SPEC="$_spec" SYM_FUNCTION="check" \
      HALMOS_VERIFY="$GATE" \
      ORCHESTRATE_ENABLED=1 DISPATCH_ENABLED=1 DISPATCH_FIXTURE="" \
      agentis go coordinator.ag --enable-exec --enable-messaging --grant-pii 2>&1 )
}
read_outcome() { ( cd "$1" && agentis memo get coordinator:last_outcome ) 2>/dev/null | tail -1; }

# The action TYPE of one decisions.tsv row (the `action=<type>` field).
row_action() { printf '%s' "$1" | awk -F'\t' '{ for (i=1;i<=NF;i++) if ($i ~ /^action=/) { sub(/^action=/,"",$i); print $i } }'; }

echo "=================================================================================="
echo " (1) BUGGY vault: coordinator CHOOSES symbolic-prove -> REAL Halmos -> COUNTEREXAMPLE -> confirmed"
echo "=================================================================================="
init_store "$WORK/cex"
note "driving the coordinator with the LIVE symbolic env (SYM_REPO + SolvencyBuggy.t.sol) — running REAL Halmos ..."
OUT_CEX="$(orchestrate_live "$WORK/cex" "$REPO/test/SolvencyBuggy.t.sol")"
MARK_CEX="$(printf '%s\n' "$OUT_CEX" | grep -E '^ORCHESTRATE\|' | head -1)"
ACTION_CEX="$(printf '%s\n' "$OUT_CEX" | grep -E '^ACTION\|symbolic-prove\|' | head -1)"
LIVE_CEX="$(printf '%s\n' "$OUT_CEX" | grep -E 'LIVE symbolic-prove .* running REAL Halmos' | head -1)"
DISPATCH_CEX="$(printf '%s\n' "$OUT_CEX" | grep -E '^DISPATCH\|symbolic-prove\|' | head -1)"
OUTCOME_CEX="$(read_outcome "$WORK/cex")"

if [ -n "$MARK_CEX" ]; then ok "the single agentis go completed in-substrate ($MARK_CEX)"
else bad "no ORCHESTRATE| completion marker — the in-substrate loop did not run"; printf '%s\n' "$OUT_CEX" | sed 's/^/        | /' | tail -20; fi
if [ -n "$ACTION_CEX" ]; then ok "the coordinator CHOSE symbolic-prove for the pending candidate"
else bad "the coordinator did not choose symbolic-prove (the seeded policy did not lift it / wrong scenario)"; fi
if [ -n "$LIVE_CEX" ]; then ok "the LIVE route fired: it ran REAL Halmos (not the honest stub)"
else bad "the live symbolic route did NOT fire — symbolic-prove fell through to the stub (env not passed?)"; fi
case "$DISPATCH_CEX" in DISPATCH\|symbolic-prove\|cand-0\|confirmed) ok "DISPATCH| outcome = confirmed (Halmos COUNTEREXAMPLE -> confirmed, the SOUND verdict)";; *) bad "expected 'DISPATCH|symbolic-prove|cand-0|confirmed', got '$DISPATCH_CEX'";; esac
case "$OUTCOME_CEX" in symbolic-prove\|cand-0\|confirmed) ok "durable coordinator:last_outcome memo = '$OUTCOME_CEX' (a real bug, CONFIRMED by a concrete witness)";; *) bad "expected 'symbolic-prove|cand-0|confirmed' in the memo, got '$OUTCOME_CEX'";; esac

echo
echo "=================================================================================="
echo " (2) FIXED vault: same route, Halmos PROVES the invariant -> PROVED -> refuted"
echo "=================================================================================="
init_store "$WORK/proved"
note "driving the coordinator with the LIVE symbolic env (SYM_REPO + SolvencyFixed.t.sol) — running REAL Halmos ..."
OUT_PROVED="$(orchestrate_live "$WORK/proved" "$REPO/test/SolvencyFixed.t.sol")"
MARK_PROVED="$(printf '%s\n' "$OUT_PROVED" | grep -E '^ORCHESTRATE\|' | head -1)"
DISPATCH_PROVED="$(printf '%s\n' "$OUT_PROVED" | grep -E '^DISPATCH\|symbolic-prove\|' | head -1)"
OUTCOME_PROVED="$(read_outcome "$WORK/proved")"

if [ -n "$MARK_PROVED" ]; then ok "the single agentis go completed in-substrate ($MARK_PROVED)"
else bad "no ORCHESTRATE| completion marker on the FIXED run"; printf '%s\n' "$OUT_PROVED" | sed 's/^/        | /' | tail -20; fi
case "$DISPATCH_PROVED" in DISPATCH\|symbolic-prove\|cand-0\|refuted) ok "DISPATCH| outcome = refuted (Halmos PROVED -> refuted, the lead killed by a proof)";; *) bad "expected 'DISPATCH|symbolic-prove|cand-0|refuted', got '$DISPATCH_PROVED'";; esac
case "$OUTCOME_PROVED" in symbolic-prove\|cand-0\|refuted) ok "durable coordinator:last_outcome memo = '$OUTCOME_PROVED' (safe: the invariant holds for ALL inputs)";; *) bad "expected 'symbolic-prove|cand-0|refuted' in the memo, got '$OUTCOME_PROVED'";; esac

echo
echo "=================================================================================="
echo " (3) THE SOUND VERDICT drives the sign: the SAME route, opposite outcomes from the vault alone"
echo "=================================================================================="
# The ONLY thing that changed between (1) and (2) is the vault (buggy vs fixed) the spec runs against; the
# coordinator decision, the action, the env wiring are identical. The OUTCOME flipped confirmed<->refuted
# purely from Halmos's exit code — never an LLM opinion. That is the epic's thesis, now LIVE.
if [ "$OUTCOME_CEX" = "symbolic-prove|cand-0|confirmed" ] && [ "$OUTCOME_PROVED" = "symbolic-prove|cand-0|refuted" ]; then
  ok "same coordinator route, opposite SOUND outcomes (buggy -> confirmed / fixed -> refuted) — the verdict is Halmos's exit code"
else
  bad "the live verdicts did not flip with the vault: buggy='$OUTCOME_CEX' fixed='$OUTCOME_PROVED'"
fi

echo
echo "=================================================================================="
echo " (4) run-coordinator.sh --sym-repo/--sym-spec wiring — the operator flags validate the live context"
echo "=================================================================================="
# Smoke the operator-facing flags: the two must be supplied together, --sym-repo must be a foundry project,
# --sym-spec must exist. (The full hunt->push->route loop via run-coordinator.sh needs a hunt-confirm to push
# a candidate, which the offline orchestration proof covers; here we assert the LIVE-context flag plumbing.)
if [ -x "$RUNNER" ]; then
  _scope="$WORK/scope.tsv"; printf 'vault accounting | C1\n' > "$_scope"
  # --sym-repo without --sym-spec must fail (exit 2): the live context is supplied together.
  if "$RUNNER" --scope "$_scope" --sym-repo "$REPO" --budget 0 >/dev/null 2>&1; then
    bad "run-coordinator.sh accepted --sym-repo without --sym-spec (should require both)"
  else
    ok "run-coordinator.sh requires --sym-repo and --sym-spec together (the live context)"
  fi
  # A non-foundry --sym-repo must fail (exit 2).
  _bad="$WORK/notfoundry"; mkdir -p "$_bad"
  if "$RUNNER" --scope "$_scope" --sym-repo "$_bad" --sym-spec "$REPO/test/SolvencyBuggy.t.sol" --budget 0 >/dev/null 2>&1; then
    bad "run-coordinator.sh accepted a non-foundry --sym-repo (no foundry.toml)"
  else
    ok "run-coordinator.sh rejects a --sym-repo that is not a foundry project (no foundry.toml)"
  fi
else
  skip "run-coordinator.sh not executable — skipping the operator-flag smoke"
fi

echo
echo "=================================================================================="
if [ "$FAILS" -eq 0 ]; then
  note "PROVEN LIVE. The self-orchestrating coordinator's symbolic-prove action ran REAL Halmos end-to-end"
  note "inside the autonomous loop for an operator-supplied candidate: the BUGGY vault's solvency spec"
  note "returned a COUNTEREXAMPLE -> confirmed (a real bug with a concrete witness); the FIXED vault PROVED"
  note "the invariant -> refuted (safe). The verdict is Halmos's exit code, never an LLM opinion. Submission"
  note "stays human-gated; this colony never posts. Multi-candidate code-carrying remains a follow-up."
  exit 0
fi
note "FAILED: $FAILS assertion(s) did not hold — see above."
exit 1
