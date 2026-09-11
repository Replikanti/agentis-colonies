#!/usr/bin/env bash
# demo-poc-stub-callee.sh — the OFFLINE gate for the #2171 HOSTILE-STUB-CALLEE directive + the #2179
# attacker-repointable-vs-admin-upgradeable refinement (epic #2130 follow-up).
#
# What the change is: poc-writer.ag gained a DETERMINISTIC stub-eligibility gate and a hostile-stub synthesis
# directive. When run-vector-hunt.sh hands it a CALLEE-VECTOR whose target callee is BOTH settable over
# CODE_PATH (D1's #2145 signals, ported byte-identical) AND out-of-scope (interface-only, no in-repo
# `contract <Type>` body), the model is directed to model the callee as an ATTACKER-DEPLOYED hostile stub (the
# Royco MaliciousOracle idiom) injected via the discovered setter, instead of refuting the vector to CLEAN
# because the callee's real code cannot be driven. #2179 tightens "settable" to ATTACKER-repointable: a stub
# arms ONLY when the backing address is mutable AND written by an UNGUARDED EXTERNAL setter — an owner/role-
# guarded (admin/governance) setter, an internal writer, an immutable address, or a getter-resolved (out-of-
# scope-setter) target all FAIL CLOSED. The gate is now a CLASSIFIER stub_class() returning one of `armed` /
# `suppressed:{no-callee,no-type,not-settable,admin-or-unprovable,in-scope}`, and every suppression is surfaced
# as a `STUB-GATE|<class>|<callee-expr>` audit line (before POC|, relayed by run-poc.sh). An immutable/guarded/
# in-scope callee stays byte-identical to today (stub_directive returns "" -> the prompt is unchanged), so no
# finding is fabricated on a callee that is not actually attacker-controllable. verdict_of is untouched.
#
# Two parts:
#   1) SOURCE-GUARD (the CI floor — pure grep/awk: no agentis, no forge, no network). The eligibility helpers,
#      the AND/fail-closed gate, the ""-when-ineligible splice, the directive's load-bearing sentences (the
#      Royco idiom + the role-precondition note + the distinct-stub-name guard), the unchanged verdict_of, the
#      env plumbing through run-poc.sh + run-vector-hunt.sh, substrate purity over the directive TEXT, the three
#      fixture arms, and read-only/never-submit.
#   2) LIVE ([SKIP] without agentis / forge). (a) an extracted-helper probe: the eligibility helpers sliced FROM
#      poc-writer.ag BY LINE RANGE assert stub_class = armed for the unguarded-external + out-of-scope arm and a
#      suppressed:* reason for every negative arm (owner-guarded, modifier-guarded, immutable, getter/no-type,
#      in-scope, empty) — the negative arms prove NO stub is fabricated. (b) fail-before/pass-after through the
#      REAL forge-poc.sh gate: the control
#      PoC (honest callee) -> POC|...|CLEAN and the stub PoC (hostile MaliciousOracle injected) -> POC|...|FINDING,
#      NO LLM.
#
# Usage:  dark-factory/demo-poc-stub-callee.sh
# Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVER="$HERE/auditor/agents/poc-writer.ag"
RUNNER="$HERE/run-poc.sh"
VHUNT="$HERE/run-vector-hunt.sh"
FIXROOT="$HERE/fixtures/poc-stub-callee"
FIXSRC="$FIXROOT/src"
SCOPED="$FIXSRC/ScopedVault.sol"
PERMISSIONLESS="$FIXSRC/PermissionlessCalleeVault.sol"
ROLEGUARD="$FIXSRC/RoleGuardedCalleeVault.sol"
IMMUT="$FIXSRC/ImmutableCalleeVault.sol"
INSCOPE="$FIXSRC/InScopeCalleeVault.sol"
INSCOPEIFACE="$FIXSRC/InScopeInterfaceCalleeVault.sol"
MULTILINE="$FIXSRC/MultiLineImplCalleeVault.sol"
TRANSITIVE="$FIXSRC/TransitiveImplCalleeVault.sol"
COMMENTBRACE="$FIXSRC/CommentBraceImplCalleeVault.sol"
STRINGSLASH="$FIXSRC/StringSlashImplCalleeVault.sol"
POC_CONTROL="$FIXROOT/Poc_control.t.sol"
POC_STUB="$FIXROOT/Poc_stub.t.sol"

FAILS=0
note() { echo "demo-poc-stub-callee.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for f in "$PROVER" "$RUNNER" "$VHUNT" "$SCOPED" "$PERMISSIONLESS" "$ROLEGUARD" "$IMMUT" "$INSCOPE" "$INSCOPEIFACE" "$MULTILINE" "$TRANSITIVE" "$COMMENTBRACE" "$STRINGSLASH" "$POC_CONTROL" "$POC_STUB"; do
  [ -f "$f" ] || { note "required file not found: $f" >&2; exit 3; }
done

WORK="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# Flatten the multi-line `"..." + "..."` string joins so an assertion can match the PROMPT/directive text the
# model actually receives rather than one source line of it (same idiom as demo-callee-trust-lens.sh).
PROVER_FLAT="$(tr '\n' ' ' < "$PROVER" | sed 's/"[[:space:]]*+[[:space:]]*"//g')"

# ----------------------------------------------------------------------------------------------------------
# PART 1 — SOURCE-GUARD (CI floor: grep/awk only)
# ----------------------------------------------------------------------------------------------------------
note "1) poc-writer.ag declares the eligibility + directive helpers ..."
HELPER_FNS="callee_type_of callee_addr_expr is_bare_identifier mutable_var_state_pattern callee_addr_mutable setter_window_pattern window_is_privileged window_is_externally_reachable callee_attacker_settable scope_probe callee_out_of_scope stub_class stub_eligible hazard_behaviour stub_directive"
MISSING_FN=""
for fn in $HELPER_FNS; do
  grep -q "^fn $fn(" "$PROVER" || MISSING_FN="$MISSING_FN $fn"
done
if [ -z "$MISSING_FN" ]; then
  ok "all 15 callee-type/settability/window/scope/classifier/directive helpers are declared in poc-writer.ag"
else
  bad "poc-writer.ag is missing helper(s):$MISSING_FN"
fi

# #2179: the computed-getter "settable" shortcut is GONE. A getter-resolved target's setter lives OUTSIDE the
# audit scope (unprovable, never attacker-settable), so is_plain_cast_callee, addr_has_computed_target, and the
# old callee_addr_settable must be ABSENT from the agent entirely (their return would re-open the admin/attacker
# conflation this fix closes).
GONE_MISS=""
for g in is_plain_cast_callee addr_has_computed_target callee_addr_settable; do
  grep -q "$g" "$PROVER" && GONE_MISS="$GONE_MISS [$g]"
done
if [ -z "$GONE_MISS" ]; then
  ok "the computed-getter settable shortcut (is_plain_cast_callee/addr_has_computed_target) and the old callee_addr_settable are GONE (a getter-resolved target is unprovable, not attacker-settable)"
else
  bad "a removed #2179 shortcut/name is still present:$GONE_MISS"
fi

# #2179 BUG (the over-assumption): attacker-repointability MUST require an UNGUARDED EXTERNAL setter, not merely a
# mutable declaration. callee_attacker_settable ANDs (backing address mutable-declared) with (>=1 setter window
# that is externally reachable AND not privileged), over the SPECIFIC backing var.
SETT_BODY="$WORK/callee-attacker-settable.txt"
awk '/^fn callee_attacker_settable\(/{f=1} f{print} f&&/^}$/{exit}' "$PROVER" > "$SETT_BODY"
if grep -Fq 'if !callee_addr_mutable(calleeExpr, code) { return false; }' "$SETT_BODY" \
   && grep -Fq 'regex_find_all(setter_window_pattern(addr), code)' "$SETT_BODY" \
   && grep -Fq 'if window_is_privileged(w) { return false; }' "$SETT_BODY" \
   && grep -Fq 'return window_is_externally_reachable(w);' "$SETT_BODY"; then
  ok "callee_attacker_settable() ANDs a mutable backing declaration with an UNGUARDED (not-privileged) EXTERNALLY-reachable setter window — an admin/governance-guarded setter does NOT arm"
else
  bad "callee_attacker_settable() no longer requires an unguarded external setter window (the #2179 over-assumption would return)"
fi

# callee_addr_mutable ties the mutable-declaration check to the SPECIFIC backing bare identifier from CALLEE_EXPR.
MUT_BODY="$WORK/callee-addr-mutable.txt"
awk '/^fn callee_addr_mutable\(/{f=1} f{print} f&&/^}$/{exit}' "$PROVER" > "$MUT_BODY"
if grep -Fq 'let addr = callee_addr_expr(calleeExpr);' "$MUT_BODY" \
   && grep -Fq 'if !is_bare_identifier(addr) { return false; }' "$MUT_BODY" \
   && grep -Fq 'return len(regex_find_all(mutable_var_state_pattern(addr), code)) > 0;' "$MUT_BODY"; then
  ok "callee_addr_mutable() ties the mutable-declaration check to the SPECIFIC backing identifier inside CALLEE_EXPR (not file-level)"
else
  bad "callee_addr_mutable() no longer resolves the mutable declaration over the callee's OWN backing address"
fi

# The specific-var mutable pattern must still exclude immutable/constant by construction (at most one visibility
# keyword between `address` and the var name), so an immutable backing address is never settable.
if grep -A2 '^fn mutable_var_state_pattern(' "$PROVER" | grep -Fq 'address(?:\\s+(?:public|internal|private))?\\s+" + varName'; then
  ok "mutable_var_state_pattern() keys on the specific var and admits at most one visibility keyword (immutable/constant excluded by construction)"
else
  bad "mutable_var_state_pattern() no longer keys on the specific var / no longer excludes immutable by construction"
fi

# The privilege vocabulary (role/owner/authorization guards) + the external|public reachability predicate must be
# present — every guard token is ADDITIVE, strictly increasing fail-closed coverage.
PRIV_MISS=""
for tok in 'only[A-Z]' '.sender' 'hasRole' '_checkOwner' '_checkRole' '_authorizeUpgrade' 'requiresAuth' 'isAuthorized' '(?:external|public)'; do
  grep -Fq "$tok" "$PROVER" || PRIV_MISS="$PRIV_MISS [$tok]"
done
if [ -z "$PRIV_MISS" ]; then
  ok "the privilege vocabulary (onlyX / msg.sender== / hasRole / _checkOwner / _checkRole / _authorizeUpgrade / requiresAuth / isAuthorized) and the external|public reachability predicate are all present"
else
  bad "window privilege/reachability vocabulary is missing:$PRIV_MISS"
fi

note "2) stub_class() is the fail-closed classifier — exactly six tokens, AND-ordered (callee-expr -> type -> settable -> out-of-scope) ..."
CLASS_BODY="$WORK/stub-class.txt"
awk '/^fn stub_class\(/{f=1} f{print} f&&/^}$/{exit}' "$PROVER" > "$CLASS_BODY"
GATE_MISS=""
for g in \
  'if len(calleeExpr) == 0 { return "suppressed:no-callee"; }' \
  'if len(typeName) == 0 { return "suppressed:no-type"; }' \
  'if !callee_addr_mutable(calleeExpr, code) { return "suppressed:not-settable"; }' \
  'if !callee_attacker_settable(calleeExpr, code) { return "suppressed:admin-or-unprovable"; }' \
  'if !callee_out_of_scope(typeName, repo) { return "suppressed:in-scope"; }' \
  'return "armed";'
do
  grep -Fq "$g" "$CLASS_BODY" || GATE_MISS="$GATE_MISS [$g]"
done
# exactly six DISTINCT return tokens, no seventh
CLASS_TOKENS="$(grep -oE 'return "(armed|suppressed:[a-z-]*)"' "$CLASS_BODY" | sort -u | wc -l | tr -d ' ')"
if [ -z "$GATE_MISS" ] && [ "$CLASS_TOKENS" = "6" ]; then
  ok "stub_class() returns exactly six tokens (armed + 5 suppressed:* reasons) in fail-closed order; every suppression names its reason"
else
  bad "stub_class() lost a token / ordering guard:$GATE_MISS (distinct tokens=$CLASS_TOKENS, want 6)"
fi
if grep -Fq 'return stub_class(calleeExpr, code, repo) == "armed";' "$PROVER"; then
  ok "stub_eligible() is stub_class(...) == \"armed\" — the \"\"-splice and the AND/fail-closed ordering are untouched"
else
  bad "stub_eligible() is no longer derived from stub_class(...) == \"armed\""
fi

note "3) stub_directive() returns \"\" when ineligible (byte-identical splice for the ordinary / immutable / in-scope paths) ..."
if grep -A1 '^fn stub_directive(' "$PROVER" | grep -q 'if !eligible { return ""; }'; then
  ok "stub_directive() returns \"\" when the gate is not eligible — concatenating it is a no-op, so the prompt is byte-identical to pre-#2171"
else
  bad "stub_directive() lost its \"\"-when-ineligible early return — an ineligible callee's prompt would change (fabrication risk)"
fi

note "4) the directive carries its load-bearing sentences ..."
DIR_MISS=""
for s in \
  "HOSTILE-STUB CALLEE (the Royco MaliciousOracle idiom)" \
  "model it as ATTACKER-DEPLOYED code" \
  "do NOT refute the vector for being unprovable" \
  "contract Malicious" \
  "IMPLEMENTS the callee's interface" \
  "POINT the target's settable callee at it via the discovered setter" \
  "Keep the stub's name DISTINCT from the target contract" \
  "as the exploit's PRECONDITION"
do
  case "$PROVER_FLAT" in *"$s"*) ;; *) DIR_MISS="$DIR_MISS [$s]" ;; esac
done
if [ -z "$DIR_MISS" ]; then
  ok "the directive names the Royco MaliciousOracle idiom, the attacker-deployed framing, the interface-implementing Malicious<Type> stub, the setter injection, the distinct-name guard and the role precondition"
else
  bad "the directive lost load-bearing text:$DIR_MISS"
fi

# The hazard selector must cover all three D1 hazards.
HAZ_MISS=""
for h in 'if hazard == "reentrant"' 'if hazard == "gas"'; do
  grep -A4 '^fn hazard_behaviour(' "$PROVER" | grep -Fq "$h" || HAZ_MISS="$HAZ_MISS [$h]"
done
if [ -z "$HAZ_MISS" ]; then
  ok "hazard_behaviour() selects reentrant / gas / (default) return-value stub behaviour"
else
  bad "hazard_behaviour() dropped a hazard branch:$HAZ_MISS"
fi

note "5) verdict_of is UNCHANGED — a stub PoC PASS is scored by the SAME inverted-polarity gate (no new verdict token) ..."
if grep -q 'if rc == 1 { return "FINDING"; }' "$PROVER" \
   && grep -q 'if rc == 0 { return "CLEAN"; }' "$PROVER" \
   && grep -q 'if rc == 3 { return "TRANSIENT_ERROR"; }' "$PROVER" \
   && grep -q 'return "HARNESS_ERROR";' "$PROVER"; then
  ok "verdict_of(rc) is unchanged (1->FINDING, 0->CLEAN, 3->TRANSIENT_ERROR, else->HARNESS_ERROR); no stub-specific verdict"
else
  bad "verdict_of(rc) was altered — the stub path must not add a verdict token or change the gate polarity"
fi

note "6) the directive is spliced after refLine in BOTH prompt builders (bare '+ stubLine' term = \"\" no-op) ..."
SPLICE_N="$(awk '/^         \+ refLine$/{getline nl; if (nl ~ /^         \+ stubLine$/) c++} END{print c+0}' "$PROVER")"
if [ "$SPLICE_N" -eq 2 ]; then
  ok "'+ stubLine' sits directly after '+ refLine' in both the foundry and hardhat prompt builders (byte-identical when \"\")"
else
  bad "'+ stubLine' is not spliced directly after '+ refLine' in both prompt builders (found $SPLICE_N of 2)"
fi
if grep -q 'let stubClass = stub_class(calleeExpr, code, pocRepo);' "$PROVER" \
   && grep -q 'let stubEligible = stubClass == "armed";' "$PROVER" \
   && grep -q 'let stubLine = stub_directive(stubEligible, calleeExpr, calleeHazard);' "$PROVER"; then
  ok "stubClass/stubEligible/stubLine are derived once from the CALLEE_EXPR env over the CODE_PATH contents + POC_REPO"
else
  bad "the stubClass/stubEligible/stubLine derivation from the CALLEE_EXPR env is gone"
fi

note "6b) the STUB-GATE audit line (#2179) is emitted ONLY under a non-empty CALLEE_EXPR, before POC|, and relayed ..."
# poc-writer.ag: the print is guarded by `len(calleeExpr) > 0` and sits immediately before the POC| marker, so
# the ordinary (no-callee) path prints NOTHING (byte-identical). The line carries no `POC|` substring.
GATE_LINE='print("STUB-GATE|" + stubClass + "|" + calleeExpr);'
if awk '/if len\(calleeExpr\) > 0 \{/{g=1} g && /print\("STUB-GATE\|" \+ stubClass \+ "\|" \+ calleeExpr\);/{ok=1} g && /print\("POC\|"/{if(ok)print"SEQ-OK"; exit}' "$PROVER" | grep -q 'SEQ-OK'; then
  ok "poc-writer.ag prints STUB-GATE|<class>|<callee-expr> under a non-empty CALLEE_EXPR guard, immediately before the POC| marker"
else
  bad "the STUB-GATE line is not guarded by a non-empty CALLEE_EXPR / is not emitted before the POC| marker"
fi
case "$GATE_LINE" in *"POC|"*) bad "the STUB-GATE line contains a POC| substring — it would corrupt the verdict parse" ;; *) ok "the STUB-GATE line carries no POC| substring, so grep 'POC|' | grep -v 'POC-FILE|' never mis-parses it" ;; esac
# run-poc.sh relays the STUB-GATE line from the cell log (the same idiom as POC-FILE|), after the POC| line.
if grep -q "grep '^STUB-GATE|' \"\$CELL_LOG\" | tail -1" "$RUNNER" && grep -q 'echo "$STUB_GATE_LINE"' "$RUNNER"; then
  ok "run-poc.sh relays the poc-writer STUB-GATE| line on its own stdout (after the POC| verdict line)"
else
  bad "run-poc.sh does not relay the STUB-GATE| audit line"
fi


note "7) run-poc.sh threads CALLEE_EXPR / CALLEE_HAZARD end-to-end ..."
if grep -q -- '--callee-expr) need' "$RUNNER" && grep -q -- '--callee-hazard) need' "$RUNNER"; then
  ok "run-poc.sh parses --callee-expr / --callee-hazard"
else
  bad "run-poc.sh does not parse --callee-expr / --callee-hazard"
fi
if grep -q 'exec.env_passthrough = TARGET_FN,TARGET_CLASS,BUG_HYPOTHESIS,POC_KIND,POC_REPO,POC_OUT,POC_HARNESS,POC_FIXTURE,CODE_PATH,CALLEE_EXPR,CALLEE_HAZARD,TARGET_FIXTURES_DIR,POC_MATCH,POC_REPAIR_ROUNDS' "$RUNNER"; then
  ok "run-poc.sh registers CALLEE_EXPR,CALLEE_HAZARD on exec.env_passthrough (getenv reads the sanitised env)"
else
  bad "run-poc.sh does NOT allowlist CALLEE_EXPR,CALLEE_HAZARD on exec.env_passthrough — the stub env would be silently inert"
fi
if grep -q 'CALLEE_EXPR="\$CALLEE_EXPR"' "$RUNNER" && grep -q 'CALLEE_HAZARD="\$CALLEE_HAZARD"' "$RUNNER"; then
  ok "run-poc.sh exports CALLEE_EXPR/CALLEE_HAZARD into the agentis go env block"
else
  bad "run-poc.sh does not export CALLEE_EXPR/CALLEE_HAZARD into the agentis go env block"
fi

note "8) run-vector-hunt.sh threads the already-parsed CALLEE-VECTOR fields into the PoC runner ..."
if grep -q -- '--callee-expr "\$rp_callee" --callee-hazard "\$rp_haz"' "$VHUNT"; then
  ok "run-vector-hunt.sh passes --callee-expr/--callee-hazard from the vector's own fields to run-poc.sh"
else
  bad "run-vector-hunt.sh does not thread the CALLEE-VECTOR callee-expr/hazard into the PoC runner"
fi
if grep -q 'VERD="\$(run_poc_once "\$VH" "\$VHYP" "\$VCALLEE" "\$VHAZ" "\$CUR_TIMEOUT")"' "$VHUNT"; then
  ok "run_poc_once is called with the vector's VCALLEE/VHAZ (they are read, not just field-split placeholders; #2178 appended the escalated --cli-timeout-ms as a trailing arg)"
else
  bad "run_poc_once is not called with VCALLEE/VHAZ"
fi
# An out-of-scope-but-settable candidate must reach the PoC runner: the enumerate loop filters only on the
# CANDIDATE disposition (contamination discipline), NEVER on scope — dropping an out-of-scope vector here would
# make the whole hostile-stub path unreachable. Scope the "no scope filter" check to the python enumerate block.
PY_ENUM="$WORK/enum.py"
awk '/^python3 - /{f=1} f{print} f&&/^PY$/{exit}' "$VHUNT" > "$PY_ENUM"
if grep -q 'if not disp.startswith("CANDIDATE"):' "$VHUNT" && ! grep -iq 'scope' "$PY_ENUM"; then
  ok "run-vector-hunt.sh's enumerate loop filters only on the CANDIDATE disposition, never on scope (an out-of-scope settable candidate still reaches the stub path)"
else
  bad "run-vector-hunt.sh appears to scope-filter candidates before the PoC runner — the hostile-stub path could be unreachable"
fi

note "9) substrate purity (#1587): the directive TEXT is builtins-only (the detector's repo-grep is legitimate tooling) ..."
DIR_BLOCK="$WORK/directive-block.txt"
{
  awk '/^fn hazard_behaviour\(/{f=1} f{print} f&&/^}$/{exit}' "$PROVER"
  awk '/^fn stub_directive\(/{f=1} f{print} f&&/^}$/{exit}' "$PROVER"
} | grep -v '^[[:space:]]*//' > "$DIR_BLOCK"
if [ ! -s "$DIR_BLOCK" ]; then
  bad "could not slice the directive-text fns (hazard_behaviour/stub_directive) out of poc-writer.ag"
elif grep -Eq 'exec sh|python3 -c|awk |sed -|[^a-z]date ' "$DIR_BLOCK"; then
  bad "the directive-text block introduced an embedded interpreter / exec sh escape (substrate-purity ratchet)"
  grep -nE 'exec sh|python3 -c|awk |sed -|[^a-z]date ' "$DIR_BLOCK" | head -3 | sed 's/^/      /' >&2
else
  ok "hazard_behaviour()/stub_directive() use only native builtins (no exec sh / embedded interpreter in the directive text)"
fi

note "10) the fixture arms have the shapes the gate discriminates on (positive + privilege + scope repros) ..."
# POSITIVE arm (#2179): PermissionlessCalleeVault — mutable oracle + UNGUARDED external setter + out-of-scope IOracle.
if grep -q 'function setOracle(address newOracle) external {' "$PERMISSIONLESS" \
   && ! grep -q 'require(' "$PERMISSIONLESS" \
   && ! grep -q 'onlyRole' "$PERMISSIONLESS" \
   && grep -q '^    address public oracle;$' "$PERMISSIONLESS" \
   && grep -q 'IOracle(oracle).price();' "$PERMISSIONLESS" \
   && grep -q '^interface IOracle {$' "$PERMISSIONLESS" \
   && ! grep -q '^contract IOracle' "$PERMISSIONLESS"; then
  ok "PermissionlessCalleeVault.sol: mutable oracle + UNGUARDED external setOracle + interface-only IOracle (the armed positive arm)"
else
  bad "PermissionlessCalleeVault.sol lost the unguarded setter / mutable address / interface-only call the armed arm needs"
fi
# NEGATIVE arm (inline require guard): ScopedVault — same shape, but setOracle is gated by require(msg.sender == owner).
if grep -q 'function setOracle(address newOracle) external' "$SCOPED" \
   && grep -q 'require(msg.sender == owner' "$SCOPED" \
   && grep -q '^    address public oracle;$' "$SCOPED" \
   && grep -q '^interface IOracle {$' "$SCOPED" \
   && ! grep -q '^contract IOracle' "$SCOPED"; then
  ok "ScopedVault.sol: mutable oracle + OWNER-guarded (require msg.sender == owner) setter, IOracle out-of-scope (admin-guarded negative arm, inline-require style)"
else
  bad "ScopedVault.sol lost the owner-guarded setter it now exists to carry (admin-or-unprovable arm)"
fi
# NEGATIVE arm (modifier guard): RoleGuardedCalleeVault — setOracle gated by an onlyRole(ADMIN_ROLE) modifier.
if grep -q 'function setOracle(address newOracle) external onlyRole(ADMIN_ROLE)' "$ROLEGUARD" \
   && grep -q 'modifier onlyRole(bytes32 role)' "$ROLEGUARD" \
   && grep -q '^interface IOracle {$' "$ROLEGUARD" \
   && ! grep -q '^contract IOracle' "$ROLEGUARD"; then
  ok "RoleGuardedCalleeVault.sol: mutable oracle + MODIFIER-guarded (onlyRole) setter, IOracle out-of-scope (admin-guarded negative arm, modifier style)"
else
  bad "RoleGuardedCalleeVault.sol lost the onlyRole-modifier-guarded setter it exists to carry"
fi
# BUG-1 repro: immutable CALLEE (`oracle`) with an UNRELATED setter/mutable address present (real targets have them).
if grep -q 'address public immutable oracle;' "$IMMUT" \
   && grep -q 'IOracle(oracle).price();' "$IMMUT" \
   && grep -q 'function setTreasury(address newTreasury) external' "$IMMUT" \
   && ! grep -q 'function setOracle' "$IMMUT"; then
  ok "ImmutableCalleeVault.sol: immutable oracle callee WITH an unrelated setTreasury setter, no oracle setter (BUG-1 settability repro)"
else
  bad "ImmutableCalleeVault.sol no longer mirrors the BUG-1 repro (immutable callee + unrelated setter)"
fi
if grep -q '^contract PriceFeed {$' "$INSCOPE" \
   && grep -q 'function setFeed(address newFeed) external' "$INSCOPE" \
   && grep -q 'PriceFeed(feed).price();' "$INSCOPE"; then
  ok "InScopeCalleeVault.sol: settable callee cast to a concrete in-scope contract PriceFeed (scope negative arm)"
else
  bad "InScopeCalleeVault.sol no longer isolates the in-scope concrete-callee case"
fi
# BUG-2 repro (single-line): settable callee cast to an INTERFACE with a differently-named in-scope implementer.
if grep -q '^contract ChainlinkPriceFeed is IPriceFeed {$' "$INSCOPEIFACE" \
   && grep -q 'function setFeed(address newFeed) external' "$INSCOPEIFACE" \
   && grep -q 'IPriceFeed(feed).price();' "$INSCOPEIFACE"; then
  ok "InScopeInterfaceCalleeVault.sol: settable callee cast to IPriceFeed with a single-line in-scope implementer (BUG-2 scope repro)"
else
  bad "InScopeInterfaceCalleeVault.sol no longer mirrors the BUG-2 repro (interface cast + differently-named in-scope impl)"
fi
# #2176 repro (MULTI-LINE inheritance): the base IPriceFeed sits on a different line than `contract <Name> is`.
if grep -q '^contract ChainlinkPriceFeed is$' "$MULTILINE" \
   && grep -q '^    IPriceFeed$' "$MULTILINE" \
   && grep -q 'function setFeed(address newFeed) external' "$MULTILINE" \
   && grep -q 'IPriceFeed(feed).price();' "$MULTILINE"; then
  ok "MultiLineImplCalleeVault.sol: settable IPriceFeed callee with a MULTI-LINE inheritance impl (base on its own line) (#2176 repro)"
else
  bad "MultiLineImplCalleeVault.sol no longer mirrors the #2176 multi-line-inheritance repro"
fi
# #2176 round-4 path 1 (TRANSITIVE interface): only an interface extends IOracle; the impl implements that interface.
if grep -q '^interface IOracleV2 is IOracle {$' "$TRANSITIVE" \
   && grep -q '^contract ChainImpl is IOracleV2 {$' "$TRANSITIVE" \
   && grep -q 'function setOracle(address newOracle) external' "$TRANSITIVE" \
   && grep -q 'IOracle(oracle).price();' "$TRANSITIVE"; then
  ok "TransitiveImplCalleeVault.sol: settable IOracle callee carried only via a transitive interface chain (interface IOracleV2 is IOracle) (path-1 repro)"
else
  bad "TransitiveImplCalleeVault.sol no longer mirrors the transitive-interface-chain repro"
fi
# #2176 round-4 path 2 (comment-brace in header): an inline comment with { } in the multi-line inheritance list.
if grep -q '^contract CommentBraceFeed is$' "$COMMENTBRACE" \
   && grep -q 'braces that must not truncate the header' "$COMMENTBRACE" \
   && grep -q '^    IPriceFeed$' "$COMMENTBRACE" \
   && grep -q 'function setFeed(address newFeed) external' "$COMMENTBRACE" \
   && grep -q 'IPriceFeed(feed).price();' "$COMMENTBRACE"; then
  ok "CommentBraceImplCalleeVault.sol: settable IPriceFeed callee whose impl header carries an inline comment with { } braces (path-2 repro)"
else
  bad "CommentBraceImplCalleeVault.sol no longer mirrors the comment-brace-in-header repro"
fi
# #2176 round-5 path (/*-in-string): a `/*` inside a Solidity STRING literal before the in-scope carrier.
if grep -q '"price feed adapter /\* v2";' "$STRINGSLASH" \
   && grep -q '^contract StringSlashFeed is IPriceFeed {$' "$STRINGSLASH" \
   && grep -q 'function setFeed(address newFeed) external' "$STRINGSLASH" \
   && grep -q 'IPriceFeed(feed).price();' "$STRINGSLASH"; then
  ok "StringSlashImplCalleeVault.sol: settable IPriceFeed callee with a /* inside a STRING literal before the in-scope impl (round-5 repro)"
else
  bad "StringSlashImplCalleeVault.sol no longer mirrors the /*-in-string-literal repro"
fi
if grep -q '^contract MaliciousOracle' "$POC_STUB" && ! grep -q '^contract PermissionlessCalleeVault' "$POC_STUB" \
   && grep -q 'import {PermissionlessCalleeVault} from "../src/PermissionlessCalleeVault.sol";' "$POC_STUB"; then
  ok "Poc_stub.t.sol imports the in-scope PermissionlessCalleeVault + declares a DISTINCT MaliciousOracle stub (no #1471 target shadow)"
else
  bad "Poc_stub.t.sol no longer imports PermissionlessCalleeVault or its stub name shadows the target"
fi

note "11) read-only: no network / no submission verb on the PoC / vector-hunt paths ..."
NET_HIT=0
for s in "$RUNNER" "$VHUNT"; do
  if grep -vE '^[[:space:]]*#' "$s" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then NET_HIT=1; fi
done
if [ "$NET_HIT" -eq 0 ]; then
  ok "no network / no submission verb on run-poc.sh or run-vector-hunt.sh (read-only, never submits)"
else
  bad "a network/submission verb appears on the PoC / vector-hunt path"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 2 — LIVE (needs agentis for the probe + forge for the gate; clean [SKIP] otherwise)
# ----------------------------------------------------------------------------------------------------------
note "12) extracted-helper probe: the stub_class truth table over all fixture arms (positive + privilege + scope) ..."
if ! command -v agentis >/dev/null 2>&1; then
  skip "no agentis binary on PATH — the extracted-helper classification probe cannot run"
else
  # Extract the classification helpers FROM poc-writer.ag BY LINE RANGE (dependency order), so a copy cannot drift
  # from the shipped agent (the demo-callee-trust-lens.sh idiom).
  PROBE_FNS="callee_type_of callee_addr_expr is_bare_identifier mutable_var_state_pattern callee_addr_mutable setter_window_pattern window_is_privileged window_is_externally_reachable callee_attacker_settable scope_probe callee_out_of_scope stub_class"
  FRAG="$WORK/class.frag"; : > "$FRAG"; FRAG_MISS=""
  for fn in $PROBE_FNS; do
    awk -v want="^fn $fn\\\\(" '$0 ~ want {f=1} f{print} f&&/^}$/{exit}' "$PROVER" >> "$FRAG"
    printf '\n' >> "$FRAG"
    grep -q "^fn $fn(" "$FRAG" || FRAG_MISS="$FRAG_MISS $fn"
  done
  if [ -n "$FRAG_MISS" ]; then
    bad "could not extract classification helpers from poc-writer.ag by line range (renamed?):$FRAG_MISS"
  else
    SB="$WORK/probe"; mkdir -p "$SB"
    ( cd "$SB" && agentis init >/dev/null 2>&1 ) || true
    printf 'exec.env_passthrough = FIXTURE,REPODIR,CEXPR\n' > "$SB/.agentis/config"
    SQ="'"
    {
      printf 'cb 300000;\n\n'
      cat "$FRAG"
      printf 'let p = getenv("FIXTURE");\n'
      printf 'let repo = getenv("REPODIR");\n'
      printf 'let cexpr = getenv("CEXPR");\n'
      # shellcheck disable=SC2016  # ${p} is an .ag interpolation in the generated probe, not a shell expansion
      printf 'let code = exec sh "sed -n %s1,4000p%s ${p}";\n' "$SQ" "$SQ"  # no-pii: reads a checked-in Solidity fixture, no prompt()
      printf 'print("CLASS=" + stub_class(cexpr, code, repo));\n'
    } > "$SB/probe.ag"
    # Stage a one-file repo per arm so callee_out_of_scope greps only that arm's src/.
    _stage() { _a="$1"; _f="$2"; mkdir -p "$WORK/$_a/src"; cp "$_f" "$WORK/$_a/src/$(basename "$_f")"; printf '%s\n' "$WORK/$_a"; }
    R_PERM="$(_stage perm "$PERMISSIONLESS")"
    R_SCOPED="$(_stage scoped "$SCOPED")"
    R_ROLE="$(_stage role "$ROLEGUARD")"
    R_IMMUT="$(_stage immut "$IMMUT")"
    R_INSCOPE="$(_stage inscope "$INSCOPE")"
    R_IFACE="$(_stage iface "$INSCOPEIFACE")"
    R_ML="$(_stage ml "$MULTILINE")"
    R_TRANS="$(_stage trans "$TRANSITIVE")"
    R_CB="$(_stage cb "$COMMENTBRACE")"
    R_SS="$(_stage ss "$STRINGSLASH")"
    _class() {
      ( cd "$SB" && FIXTURE="$1" REPODIR="$2" CEXPR="$3" agentis go probe.ag --enable-exec 2>&1 | grep '^CLASS=' | tail -1 | sed 's/^CLASS=//' )  # no-pii: the probe never calls prompt() — it reads a checked-in Solidity fixture and prints one classification token
    }
    _suppressed() { case "$1" in suppressed:*) return 0 ;; *) return 1 ;; esac; }
    C_PERM="$(_class "$R_PERM/src/PermissionlessCalleeVault.sol" "$R_PERM" 'IOracle(oracle)')"
    C_SCOPED="$(_class "$R_SCOPED/src/ScopedVault.sol" "$R_SCOPED" 'IOracle(oracle)')"
    C_ROLE="$(_class "$R_ROLE/src/RoleGuardedCalleeVault.sol" "$R_ROLE" 'IOracle(oracle)')"
    C_PROXY="$(_class "$R_PERM/src/PermissionlessCalleeVault.sol" "$R_PERM" 'nProxy(payable(address(oracle))).getImplementation()')"
    C_IMMUT="$(_class "$R_IMMUT/src/ImmutableCalleeVault.sol" "$R_IMMUT" 'IOracle(oracle)')"
    C_INSCOPE="$(_class "$R_INSCOPE/src/InScopeCalleeVault.sol" "$R_INSCOPE" 'PriceFeed(feed)')"
    C_IFACE="$(_class "$R_IFACE/src/InScopeInterfaceCalleeVault.sol" "$R_IFACE" 'IPriceFeed(feed)')"
    C_ML="$(_class "$R_ML/src/MultiLineImplCalleeVault.sol" "$R_ML" 'IPriceFeed(feed)')"
    C_TRANS="$(_class "$R_TRANS/src/TransitiveImplCalleeVault.sol" "$R_TRANS" 'IOracle(oracle)')"
    C_CB="$(_class "$R_CB/src/CommentBraceImplCalleeVault.sol" "$R_CB" 'IPriceFeed(feed)')"
    C_SS="$(_class "$R_SS/src/StringSlashImplCalleeVault.sol" "$R_SS" 'IPriceFeed(feed)')"
    C_EMPTY="$(_class "$R_PERM/src/PermissionlessCalleeVault.sol" "$R_PERM" '')"
    # POSITIVE arm: unguarded external setter + out-of-scope callee -> armed (the gate cannot silently degrade to never-arm).
    [ "$C_PERM" = "armed" ] && ok "PermissionlessCalleeVault + IOracle(oracle): UNGUARDED external setter, out-of-scope callee -> armed (AC pass arm)" \
      || bad "PermissionlessCalleeVault should be armed (got '$C_PERM') — the positive arm regressed"
    # SIGNATURE FLIP (#2179): the owner-guarded ScopedVault armed pre-#2179; it must now suppress as admin-or-unprovable.
    [ "$C_SCOPED" = "suppressed:admin-or-unprovable" ] && ok "ScopedVault + IOracle(oracle): OWNER-guarded (require msg.sender==owner) setter -> suppressed:admin-or-unprovable (the #2179 fix signature; armed pre-#2179)" \
      || bad "ScopedVault should be suppressed:admin-or-unprovable (got '$C_SCOPED') — the admin/attacker conflation is back"
    [ "$C_ROLE" = "suppressed:admin-or-unprovable" ] && ok "RoleGuardedCalleeVault + IOracle(oracle): MODIFIER-guarded (onlyRole) setter -> suppressed:admin-or-unprovable" \
      || bad "RoleGuardedCalleeVault should be suppressed:admin-or-unprovable (got '$C_ROLE') — modifier-guard privilege not detected"
    [ "$C_PROXY" = "suppressed:no-type" ] && ok "nProxy(payable(address(oracle))).getImplementation() -> suppressed:no-type (the issue named expression: the \\b anchor keeps the mid-word capital out)" \
      || bad "the nProxy(...) getter expression should be suppressed:no-type (got '$C_PROXY') — callee_type_of word-boundary fix regressed"
    [ "$C_IMMUT" = "suppressed:not-settable" ] && ok "ImmutableCalleeVault (immutable oracle + unrelated mutable setter) -> suppressed:not-settable (immutable callee never arms)" \
      || bad "immutable callee must be suppressed:not-settable (got '$C_IMMUT')"
    [ "$C_EMPTY" = "suppressed:no-callee" ] && ok "empty callee-expr (ordinary run-poc.sh path) -> suppressed:no-callee (inert, byte-identical)" \
      || bad "empty callee-expr must be suppressed:no-callee (got '$C_EMPTY')"
    # SCOPE/privilege repros: the six in-scope arms carry owner-guarded setters, so under #2179 they suppress on the
    # privilege axis (admin-or-unprovable) BEFORE the scope check — a suppressed:* outcome either way (never a stub).
    for pair in "InScope=$C_INSCOPE" "InScopeIface=$C_IFACE" "MultiLine=$C_ML" "Transitive=$C_TRANS" "CommentBrace=$C_CB" "StringSlash=$C_SS"; do
      _n="${pair%%=*}"; _v="${pair#*=}"
      if _suppressed "$_v"; then ok "$_n in-scope repro -> $_v (suppressed:* — NO stub fabricated)"
      else bad "$_n in-scope repro must stay suppressed:* (got '$_v')"; fi
    done
  fi
fi

note "13) fail-before/pass-after through the REAL forge-poc.sh gate (NO LLM) ..."
if ! command -v agentis >/dev/null 2>&1; then
  skip "no agentis binary on PATH — the run-poc.sh fixture path cannot run"
elif ! command -v forge >/dev/null 2>&1; then
  skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run the forge fail-before/pass-after gate"
else
  _verdict() {
    _fx="$1"; _od="$2"
    bash "$RUNNER" --repo "$FIXROOT" --target "src/PermissionlessCalleeVault.sol:PermissionlessCalleeVault" \
      --poc-fixture "$_fx" --code "$PERMISSIONLESS" --out "$_od" --backend mock 2>&1 \
      | grep -E '^POC\|' | grep -v 'POC-FILE|' | tail -1 | sed 's/.*POC|//' | cut -d'|' -f2
  }
  V_CTRL="$(_verdict "$POC_CONTROL" "$WORK/ctrl")"
  V_STUB="$(_verdict "$POC_STUB" "$WORK/stub")"
  [ "$V_CTRL" = "CLEAN" ] && ok "fail-before: the honest-callee control PoC FAILS its exploit assertion -> POC|...|CLEAN (no finding)" \
    || bad "control PoC should be CLEAN (honest callee, no over-credit), got '$V_CTRL'"
  [ "$V_STUB" = "FINDING" ] && ok "pass-after: the hostile MaliciousOracle stub (injected via the UNGUARDED setOracle) reproduces the over-credit -> POC|...|FINDING" \
    || bad "stub PoC should be FINDING (hostile injected callee over-credits), got '$V_STUB'"

  # BYTE-IDENTITY on the unchanged path (#2179 AC3): a run-poc.sh invocation WITHOUT --callee-expr emits NO
  # STUB-GATE| line and exactly one POC| verdict marker — identical to pre-#2179.
  BID_OUT="$(bash "$RUNNER" --repo "$FIXROOT" --target "src/PermissionlessCalleeVault.sol:PermissionlessCalleeVault" \
    --poc-fixture "$POC_CONTROL" --code "$PERMISSIONLESS" --out "$WORK/bid" --backend mock 2>&1)"
  BID_STUB="$(printf '%s\n' "$BID_OUT" | grep -c '^STUB-GATE|')"
  BID_POC="$(printf '%s\n' "$BID_OUT" | grep -c '^POC|')"
  if [ "$BID_STUB" = "0" ] && [ "$BID_POC" = "1" ]; then
    ok "no --callee-expr -> ZERO STUB-GATE| lines and exactly one POC| marker (byte-identical ordinary path, AC3)"
  else
    bad "the no-callee path is not byte-identical (STUB-GATE lines=$BID_STUB want 0, POC| markers=$BID_POC want 1)"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the #2171/#2179 hostile-stub-callee gate (attacker-repointable classifier, STUB-GATE audit line, \"\"-splice, Royco directive, unchanged verdict_of, env plumbing, negative arms) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
