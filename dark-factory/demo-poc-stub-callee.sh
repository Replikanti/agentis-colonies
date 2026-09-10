#!/usr/bin/env bash
# demo-poc-stub-callee.sh — the OFFLINE gate for the #2171 HOSTILE-STUB-CALLEE directive (epic #2130 follow-up).
#
# What the change is: poc-writer.ag gained a DETERMINISTIC stub-eligibility gate and a hostile-stub synthesis
# directive. When run-vector-hunt.sh hands it a CALLEE-VECTOR whose target callee is BOTH settable over
# CODE_PATH (D1's #2145 signals, ported byte-identical) AND out-of-scope (interface-only, no in-repo
# `contract <Type>` body), the model is directed to model the callee as an ATTACKER-DEPLOYED hostile stub (the
# Royco MaliciousOracle idiom) injected via the discovered setter, instead of refuting the vector to CLEAN
# because the callee's real code cannot be driven. The gate is AND-ed and FAIL-CLOSED: an immutable/hardcoded
# or in-scope-implemented callee is byte-identical to today (stub_directive returns "" -> the prompt is
# unchanged), so no finding is fabricated on a callee that is not actually attacker-controllable. verdict_of is
# untouched: a stub PoC that PASSES is an honest FINDING carrying the controlling role as its precondition.
#
# Two parts:
#   1) SOURCE-GUARD (the CI floor — pure grep/awk: no agentis, no forge, no network). The eligibility helpers,
#      the AND/fail-closed gate, the ""-when-ineligible splice, the directive's load-bearing sentences (the
#      Royco idiom + the role-precondition note + the distinct-stub-name guard), the unchanged verdict_of, the
#      env plumbing through run-poc.sh + run-vector-hunt.sh, substrate purity over the directive TEXT, the three
#      fixture arms, and read-only/never-submit.
#   2) LIVE ([SKIP] without agentis / forge). (a) an extracted-helper probe: the eligibility helpers sliced FROM
#      poc-writer.ag BY LINE RANGE assert stub_eligible = 1 for the out-of-scope+settable arm, 0 for the
#      immutable arm, 0 for the in-scope-implemented arm, and 0 for an empty callee-expr — the negative arms
#      prove NO stub is fabricated. (b) fail-before/pass-after through the REAL forge-poc.sh gate: the control
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

for f in "$PROVER" "$RUNNER" "$VHUNT" "$SCOPED" "$IMMUT" "$INSCOPE" "$INSCOPEIFACE" "$MULTILINE" "$TRANSITIVE" "$COMMENTBRACE" "$STRINGSLASH" "$POC_CONTROL" "$POC_STUB"; do
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
HELPER_FNS="is_plain_cast_callee callee_type_of callee_addr_expr is_bare_identifier addr_has_computed_target mutable_var_state_pattern callee_addr_settable scope_probe callee_out_of_scope stub_eligible hazard_behaviour stub_directive"
MISSING_FN=""
for fn in $HELPER_FNS; do
  grep -q "^fn $fn(" "$PROVER" || MISSING_FN="$MISSING_FN $fn"
done
if [ -z "$MISSING_FN" ]; then
  ok "all 12 callee-specific settability/type/scope/eligibility/directive helpers are declared in poc-writer.ag"
else
  bad "poc-writer.ag is missing helper(s):$MISSING_FN"
fi

# #2175 review BUG 1: settability MUST be tied to the SPECIFIC callee address, never file-level. callee_addr_settable
# must derive the backing address from CALLEE_EXPR (callee_addr_expr), accept a computed getter target, else require
# THAT var to be a mutable state var (mutable_var_state_pattern over the specific name) — so an immutable callee with
# an unrelated setter elsewhere is NOT armed.
SETT_BODY="$WORK/callee-addr-settable.txt"
awk '/^fn callee_addr_settable\(/{f=1} f{print} f&&/^}$/{exit}' "$PROVER" > "$SETT_BODY"
if grep -Fq 'let addr = callee_addr_expr(calleeExpr);' "$SETT_BODY" \
   && grep -Fq 'if addr_has_computed_target(addr) { return true; }' "$SETT_BODY" \
   && grep -Fq 'return len(regex_find_all(mutable_var_state_pattern(addr), code)) > 0;' "$SETT_BODY"; then
  ok "callee_addr_settable() ties settability to the SPECIFIC backing address inside CALLEE_EXPR (computed getter, or that var declared mutable) — not file-level"
else
  bad "callee_addr_settable() no longer resolves settability over the callee's OWN backing address (BUG 1 regression risk)"
fi
# The specific-var mutable pattern must still exclude immutable/constant by construction (at most one visibility
# keyword between `address` and the var name), so an immutable backing address is never settable.
if grep -A2 '^fn mutable_var_state_pattern(' "$PROVER" | grep -Fq 'address(?:\\s+(?:public|internal|private))?\\s+" + varName'; then
  ok "mutable_var_state_pattern() keys on the specific var and admits at most one visibility keyword (immutable/constant excluded by construction)"
else
  bad "mutable_var_state_pattern() no longer keys on the specific var / no longer excludes immutable by construction"
fi

note "2) stub_eligible() is an AND-gate and FAIL-CLOSED (never fabricates a finding on a non-attacker-controllable / in-scope callee) ..."
ELIG_BODY="$WORK/stub-eligible.txt"
awk '/^fn stub_eligible\(/{f=1} f{print} f&&/^}$/{exit}' "$PROVER" > "$ELIG_BODY"
GATE_MISS=""
for g in \
  'if len(calleeExpr) == 0 { return false; }' \
  'if len(typeName) == 0 { return false; }' \
  'if !callee_addr_settable(calleeExpr, code) { return false; }' \
  'return callee_out_of_scope(typeName, repo);'
do
  grep -Fq "$g" "$ELIG_BODY" || GATE_MISS="$GATE_MISS [$g]"
done
if [ -z "$GATE_MISS" ]; then
  ok "stub_eligible() ANDs (callee-expr present) + (type extracts) + (callee-specific settable) + (out-of-scope), fail-closed on an empty callee/type"
else
  bad "stub_eligible() lost an AND / fail-closed guard:$GATE_MISS"
fi

# #2176 review (rounds 3-5): out-of-scope resolution must be FAIL-CLOSED BY CONSTRUCTION. grep/awk cannot tell
# Solidity comments from strings from code, so the resolver matches RAW file text and NEVER strips comments: a
# carrier appearing anywhere (even in a comment/string) => IN-scope (safe missed stub); out-of-scope only when it
# appears NOWHERE. It recognizes `(contract|interface) <Name> is ...IX...` carriers (transitive interface chains)
# and bounds the base-list scan by `;` (never in a header) not `{`, so a `{` hidden in a comment cannot truncate
# it. No awk/sed comment-stripper (that round-4 stripper opened comment-state on a `/*` inside a STRING and ate a
# real carrier — round-5 regression). Out-of-scope ONLY on a definitive SCANNED; FOUND / "" stay in-scope.
SP_BODY="$WORK/scope-probe.txt"
awk '/^fn scope_probe\(/{f=1} f{print} f&&/^}$/{exit}' "$PROVER" > "$SP_BODY"
OOS_BODY="$WORK/callee-out-of-scope.txt"
awk '/^fn callee_out_of_scope\(/{f=1} f{print} f&&/^}$/{exit}' "$PROVER" > "$OOS_BODY"
SP_MISS=""
# RAW matching: the resolver must NOT strip comments (no embedded awk/sed text processor).
grep -Eq '(^|[^A-Za-z0-9_])(awk|sed)[[:space:]]' "$SP_BODY" && SP_MISS="$SP_MISS [must-not-strip-comments]"
grep -Fq "(contract|interface)[[:space:]]+[A-Za-z0-9_]+[[:space:]]+is[^;]*[^A-Za-z0-9_]\" + typeName" "$SP_BODY" || SP_MISS="$SP_MISS [contract|interface-carrier-semicolon-bound]"
grep -Fq 'grep -zqE' "$SP_BODY" || SP_MISS="$SP_MISS [grep-z]"
# out-of-scope ONLY on a definitive SCANNED; FOUND and "" (no source / ambiguous) both stay in-scope (no stub).
grep -Fq 'if probe == "SCANNED" { return true; }' "$OOS_BODY" || SP_MISS="$SP_MISS [scanned-gate]"
grep -Fq 'return false;' "$OOS_BODY" || SP_MISS="$SP_MISS [fail-closed-default]"
if [ -z "$SP_MISS" ]; then
  ok "scope resolution matches RAW text (no comment stripping), recognizes contract OR interface carriers (transitive chains) bounded by ';' not '{', scans with grep -z, and is out-of-scope ONLY on a definitive SCANNED (fail-closed in-scope otherwise)"
else
  bad "scope resolution is not fail-closed-by-construction:$SP_MISS"
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
if grep -q 'let stubEligible = stub_eligible(calleeExpr, code, pocRepo);' "$PROVER" \
   && grep -q 'let stubLine = stub_directive(stubEligible, calleeExpr, calleeHazard);' "$PROVER"; then
  ok "stubEligible/stubLine are derived once from the CALLEE_EXPR env over the CODE_PATH contents + POC_REPO"
else
  bad "the stubEligible/stubLine derivation from the CALLEE_EXPR env is gone"
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
if grep -q 'VERD="\$(run_poc_once "\$VH" "\$VHYP" "\$VCALLEE" "\$VHAZ")"' "$VHUNT"; then
  ok "run_poc_once is called with the vector's VCALLEE/VHAZ (they are read, not just field-split placeholders)"
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

note "10) the fixture arms have the shapes the gate discriminates on (incl. the two #2175-review repros) ..."
if grep -q 'function setOracle(address newOracle) external' "$SCOPED" \
   && grep -q '^    address public oracle;$' "$SCOPED" \
   && grep -q 'IOracle(oracle).price();' "$SCOPED" \
   && grep -q '^interface IOracle {$' "$SCOPED" \
   && ! grep -q '^contract IOracle' "$SCOPED"; then
  ok "ScopedVault.sol: interface-typed call + setter + mutable address state, IOracle NOT implemented in scope (positive arm)"
else
  bad "ScopedVault.sol lost the setter / mutable address state / interface-only (out-of-scope) call it exists to carry"
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
if grep -q '^contract MaliciousOracle' "$POC_STUB" && ! grep -q '^contract ScopedVault' "$POC_STUB" \
   && grep -q 'import {ScopedVault} from "../src/ScopedVault.sol";' "$POC_STUB"; then
  ok "Poc_stub.t.sol imports the in-scope ScopedVault + declares a DISTINCT MaliciousOracle stub (no #1471 target shadow)"
else
  bad "Poc_stub.t.sol no longer imports ScopedVault or its stub name shadows the target"
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
note "12) extracted-helper probe: the stub_eligible truth table over all fixture arms (incl. both #2175-review repros) ..."
if ! command -v agentis >/dev/null 2>&1; then
  skip "no agentis binary on PATH — the extracted-helper eligibility probe cannot run"
else
  # Extract the eligibility helpers FROM poc-writer.ag BY LINE RANGE (dependency order), so a copy cannot drift
  # from the shipped agent (the demo-callee-trust-lens.sh idiom).
  PROBE_FNS="is_plain_cast_callee callee_type_of callee_addr_expr is_bare_identifier addr_has_computed_target mutable_var_state_pattern callee_addr_settable scope_probe callee_out_of_scope stub_eligible"
  FRAG="$WORK/elig.frag"; : > "$FRAG"; FRAG_MISS=""
  for fn in $PROBE_FNS; do
    awk -v want="^fn $fn\\\\(" '$0 ~ want {f=1} f{print} f&&/^}$/{exit}' "$PROVER" >> "$FRAG"
    printf '\n' >> "$FRAG"
    grep -q "^fn $fn(" "$FRAG" || FRAG_MISS="$FRAG_MISS $fn"
  done
  if [ -n "$FRAG_MISS" ]; then
    bad "could not extract eligibility helpers from poc-writer.ag by line range (renamed?):$FRAG_MISS"
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
      printf 'if stub_eligible(cexpr, code, repo) { print("ELIG=1"); } else { print("ELIG=0"); }\n'
    } > "$SB/probe.ag"
    # Stage a one-file repo per arm so callee_out_of_scope greps only that arm's src/.
    _stage() { _a="$1"; _f="$2"; mkdir -p "$WORK/$_a/src"; cp "$_f" "$WORK/$_a/src/$(basename "$_f")"; printf '%s\n' "$WORK/$_a"; }
    R_SCOPED="$(_stage scoped "$SCOPED")"
    R_IMMUT="$(_stage immut "$IMMUT")"
    R_INSCOPE="$(_stage inscope "$INSCOPE")"
    R_IFACE="$(_stage iface "$INSCOPEIFACE")"
    R_ML="$(_stage ml "$MULTILINE")"
    R_TRANS="$(_stage trans "$TRANSITIVE")"
    R_CB="$(_stage cb "$COMMENTBRACE")"
    R_SS="$(_stage ss "$STRINGSLASH")"
    _elig() {
      ( cd "$SB" && FIXTURE="$1" REPODIR="$2" CEXPR="$3" agentis go probe.ag --enable-exec 2>&1 | grep '^ELIG=' | tail -1 )  # no-pii: the probe never calls prompt() — it reads a checked-in Solidity fixture and prints one eligibility bit
    }
    E_SCOPED="$(_elig "$R_SCOPED/src/ScopedVault.sol" "$R_SCOPED" 'IOracle(oracle)')"
    E_IMMUT="$(_elig "$R_IMMUT/src/ImmutableCalleeVault.sol" "$R_IMMUT" 'IOracle(oracle)')"
    E_INSCOPE="$(_elig "$R_INSCOPE/src/InScopeCalleeVault.sol" "$R_INSCOPE" 'PriceFeed(feed)')"
    E_IFACE="$(_elig "$R_IFACE/src/InScopeInterfaceCalleeVault.sol" "$R_IFACE" 'IPriceFeed(feed)')"
    E_ML="$(_elig "$R_ML/src/MultiLineImplCalleeVault.sol" "$R_ML" 'IPriceFeed(feed)')"
    E_TRANS="$(_elig "$R_TRANS/src/TransitiveImplCalleeVault.sol" "$R_TRANS" 'IOracle(oracle)')"
    E_CB="$(_elig "$R_CB/src/CommentBraceImplCalleeVault.sol" "$R_CB" 'IPriceFeed(feed)')"
    E_SS="$(_elig "$R_SS/src/StringSlashImplCalleeVault.sol" "$R_SS" 'IPriceFeed(feed)')"
    E_EMPTY="$(_elig "$R_SCOPED/src/ScopedVault.sol" "$R_SCOPED" '')"
    [ "$E_SCOPED" = "ELIG=1" ] && ok "out-of-scope + settable callee -> stub_eligible = 1 (a hostile stub is synthesized)" \
      || bad "out-of-scope + settable callee should be eligible (got '$E_SCOPED')"
    [ "$E_IMMUT" = "ELIG=0" ] && ok "BUG-1 repro: immutable callee WITH an unrelated setter present -> stub_eligible = 0 (NO stub fabricated)" \
      || bad "immutable callee with an unrelated setter must NOT be eligible (got '$E_IMMUT') — file-level settability regression"
    [ "$E_INSCOPE" = "ELIG=0" ] && ok "in-scope concrete callee (PriceFeed) -> stub_eligible = 0 (NO stub fabricated)" \
      || bad "in-scope concrete callee must NOT be eligible (got '$E_INSCOPE')"
    [ "$E_IFACE" = "ELIG=0" ] && ok "BUG-2 repro: interface-cast callee with a single-line in-scope impl -> stub_eligible = 0 (NO stub fabricated)" \
      || bad "interface-cast callee with an in-scope implementer must NOT be eligible (got '$E_IFACE') — interface-blind scope regression"
    [ "$E_ML" = "ELIG=0" ] && ok "#2176 repro: interface-cast callee with a MULTI-LINE-inheritance in-scope impl -> stub_eligible = 0 (NO stub fabricated)" \
      || bad "multi-line-inheritance in-scope implementer must NOT be eligible (got '$E_ML') — formatting-blind scope regression"
    [ "$E_TRANS" = "ELIG=0" ] && ok "#2176 round-4 path-1: callee carried only via a TRANSITIVE interface chain (interface IOracleV2 is IOracle) -> stub_eligible = 0 (NO stub fabricated)" \
      || bad "transitive-interface-chain carrier must NOT be eligible (got '$E_TRANS') — interface-carrier regression"
    [ "$E_CB" = "ELIG=0" ] && ok "#2176 round-4 path-2: in-scope impl header with an inline comment { } brace -> stub_eligible = 0 (';'-bound header, base still found)" \
      || bad "comment-brace-in-header impl must NOT be eligible (got '$E_CB') — header-truncation regression"
    [ "$E_SS" = "ELIG=0" ] && ok "#2176 round-5 path: /* inside a STRING literal before the in-scope carrier -> stub_eligible = 0 (raw matching, no comment-state)" \
      || bad "/*-in-string impl must NOT be eligible (got '$E_SS') — comment-stripping regression reintroduced"
    [ "$E_EMPTY" = "ELIG=0" ] && ok "empty callee-expr (ordinary run-poc.sh path) -> stub_eligible = 0 (inert, byte-identical)" \
      || bad "empty callee-expr must NOT be eligible (got '$E_EMPTY')"
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
    bash "$RUNNER" --repo "$FIXROOT" --target "src/ScopedVault.sol:ScopedVault" \
      --poc-fixture "$_fx" --code "$SCOPED" --out "$_od" --backend mock 2>&1 \
      | grep -E '^POC\|' | grep -v 'POC-FILE|' | tail -1 | sed 's/.*POC|//' | cut -d'|' -f2
  }
  V_CTRL="$(_verdict "$POC_CONTROL" "$WORK/ctrl")"
  V_STUB="$(_verdict "$POC_STUB" "$WORK/stub")"
  [ "$V_CTRL" = "CLEAN" ] && ok "fail-before: the honest-callee control PoC FAILS its exploit assertion -> POC|...|CLEAN (no finding)" \
    || bad "control PoC should be CLEAN (honest callee, no over-credit), got '$V_CTRL'"
  [ "$V_STUB" = "FINDING" ] && ok "pass-after: the hostile MaliciousOracle stub (injected via setOracle) reproduces the over-credit -> POC|...|FINDING" \
    || bad "stub PoC should be FINDING (hostile injected callee over-credits), got '$V_STUB'"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the #2171 hostile-stub-callee gate (AND/fail-closed eligibility, \"\"-splice, Royco directive, unchanged verdict_of, env plumbing, negative arms) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
