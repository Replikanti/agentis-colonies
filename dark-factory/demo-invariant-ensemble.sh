#!/usr/bin/env bash
# demo-invariant-ensemble.sh — proof of the #1778 SINGLE-RUN METAMORPHIC ENSEMBLE lever on the deep-hunt path.
#
# Single-draw variance was killing recall: a value-custody target's rare High hides in a per-unit-price /
# per-share value-conservation break that ONE generated invariant often fails to state. #1778 adds a default-off
# `--ensemble-candidates <N>` flag: for a value-custody target the runner steers N DISTINCT relational-invariant
# VARIANTS (large-vs-small unit-price monotonicity, before-vs-after holder-price, actor-A-vs-B parity) — each its
# own prover generation (INV_ENSEMBLE_VARIANT="<i>") + its own forge run(s) through the UNCHANGED gate — and
# takes an ENSEMBLE-VOTE verdict (any FINDING => FINDING; else any HARNESS_ERROR => HARNESS_ERROR; else CLEAN).
# The prover gains ONLY two additive, empty-by-default builders (is_value_custody + metamorphic_variant_seed);
# the ensemble LOOP + verdict aggregation live in run-invariant-hunt.sh, mirroring the #1731 cross-run ensemble.
#
# This is a SOURCE-GUARD demo (always CI-safe, no toolchain, no agentis, no forge, no LLM): it asserts the prover
# wiring is present + gated to be BYTE-IDENTICAL when the ensemble is OFF, the three variant shapes are present,
# the runner parses/validates/guards --ensemble-candidates + appends INV_ENSEMBLE_VARIANT to the allowlist +
# carries the aggregate synthesis, the verdict/marker/#1471 gate are untouched, and the bench forwarding is wired.
#
# Usage:  dark-factory/demo-invariant-ensemble.sh
# Exit: 0 = all assertions hold ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
RUNNER="$HERE/run-invariant-hunt.sh"
ZONEHUNT="$HERE/run-zone-hunt.sh"
ABBENCH="$HERE/bench/corpus-bench/deep-hunt-ab.sh"

FAILS=0
note() { echo "demo-invariant-ensemble.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

for f in "$PROVER" "$RUNNER" "$ZONEHUNT" "$ABBENCH"; do
  [ -f "$f" ] || { note "required file not found: $f" >&2; exit 3; }
done

# ----------------------------------------------------------------------------------------------------------
# 1) PROVER WIRING + BYTE-IDENTICAL-WHEN-OFF GUARD — is_value_custody() + metamorphic_variant_seed() are defined,
#    normalize through the SAME class_to_keyword(to_lower()) normalizer, return "" on an empty variant (the OFF
#    default => byte-identical generation prompt), and are folded into generate_test's dynamic instruction from
#    the module-scope INV_ENSEMBLE_VARIANT getenv.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1778 prover wiring + byte-identical-when-OFF guard ..."

if grep -q 'fn is_value_custody(klass: string) -> bool' "$PROVER"; then
  ok "is_value_custody() is defined on the prover"
else
  bad "is_value_custody() missing from the prover"
fi

if grep -q 'fn metamorphic_variant_seed(klass: string, variant: string) -> string' "$PROVER"; then
  ok "metamorphic_variant_seed() is defined on the prover"
else
  bad "metamorphic_variant_seed() missing from the prover"
fi

if grep -q 'class_to_keyword(to_lower(klass))' "$PROVER"; then
  ok "the ensemble selectors normalize via class_to_keyword(to_lower(klass)) (the production BARE-code path)"
else
  bad "the ensemble selectors do not normalize the bare taxonomy code (regressed to raw label)"
fi

# The empty-variant early return is the byte-identical-when-OFF contract: an empty INV_ENSEMBLE_VARIANT => "".
if grep -q 'if variant == "" { return ""; }' "$PROVER"; then
  ok "metamorphic_variant_seed() returns \"\" on an empty variant (OFF => byte-identical generation prompt)"
else
  bad "metamorphic_variant_seed() lost its empty-variant early return (OFF no longer byte-identical)"
fi

# #1783 (M3) — CUSTODY-FIRST / ORACLE-SECOND precedence. Value-custody is checked BEFORE is_oracle_dependent, and
# a class that is neither falls through to a final `return "";` — so a non-custody / non-oracle class (and the
# empty variant guarded above) yields a BYTE-IDENTICAL generation prompt. A value-custody label containing "price"
# hits the custody branch first (the oracle detector fires false on it).
# (.ag has no `else if`; the oracle branch nests as `else { if is_oracle_dependent(klass) { ... } else {} }`.)
_vc_ln="$(grep -n 'if is_value_custody(klass) {' "$PROVER" | head -1 | cut -d: -f1)"
_or_ln="$(grep -n 'if is_oracle_dependent(klass) {' "$PROVER" | head -1 | cut -d: -f1)"
if [ -n "$_vc_ln" ] && [ -n "$_or_ln" ] && [ "$_vc_ln" -lt "$_or_ln" ]; then
  ok "metamorphic_variant_seed() checks is_value_custody() BEFORE is_oracle_dependent() (custody-first precedence)"
else
  bad "metamorphic_variant_seed() lost the custody-first / oracle-second precedence"
fi

# #1784 (M3) — ORACLE-SECOND / LIVENESS-THIRD precedence. is_oracle_dependent is checked BEFORE
# is_liveness_sensitive (nested in its else), so an oracle label never reaches the liveness branch.
_lv_ln="$(grep -n 'if is_liveness_sensitive(klass) {' "$PROVER" | head -1 | cut -d: -f1)"
if [ -n "$_or_ln" ] && [ -n "$_lv_ln" ] && [ "$_or_ln" -lt "$_lv_ln" ]; then
  ok "metamorphic_variant_seed() checks is_oracle_dependent() BEFORE is_liveness_sensitive() (oracle-second precedence)"
else
  bad "metamorphic_variant_seed() lost the oracle-second / liveness-third precedence"
fi

# The neither-custody-nor-oracle-nor-liveness branch returns "" (byte-identical for out-of-class targets). Match the
# inner liveness-else tail `} else { <ws> return ""; <ws> }` — the arm reached when none of the three detectors fires.
if grep -Pzoq 'if is_liveness_sensitive\(klass\) \{[\s\S]*?\} else \{\s*\n\s*return "";\s*\n\s*\}' "$PROVER"; then
  ok "metamorphic_variant_seed() ends with a return \"\"; fallthrough (non-custody + non-oracle + non-liveness => byte-identical)"
else
  bad "metamorphic_variant_seed() lost the final return \"\"; fallthrough (out-of-class no longer byte-identical)"
fi

# #1783 (M1) — the oracle-manipulation detector sibling of is_value_custody, with DISJOINT keywords.
if grep -q 'fn is_oracle_dependent(klass: string) -> bool' "$PROVER"; then
  ok "is_oracle_dependent() is defined on the prover (oracle-manipulation lens class)"
else
  bad "is_oracle_dependent() missing from the prover"
fi

# C2 (Oracle integrity) maps to the "oracle" keyword in class_to_keyword (the bare-code production path).
if grep -q 'if class_is(k, "c2") { return "oracle"; }' "$PROVER"; then
  ok "class_to_keyword() maps the bare C2 taxonomy code to the \"oracle\" keyword"
else
  bad "class_to_keyword() does not map C2 to \"oracle\" (the oracle lens would never route)"
fi

if grep -q 'let ensembleVariant = getenv("INV_ENSEMBLE_VARIANT");' "$PROVER"; then
  ok "the prover reads INV_ENSEMBLE_VARIANT from the sanitized env (module scope)"
else
  bad "the prover does not read INV_ENSEMBLE_VARIANT (the ensemble variant would be inert)"
fi

if grep -q 'metamorphic_variant_seed(effClass, ensembleVariant)' "$PROVER"; then
  ok "generate_test folds metamorphic_variant_seed(effClass, ensembleVariant) into the instruction"
else
  bad "generate_test does not fold the ensemble variant seed into the generation instruction"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) THE THREE VARIANT SHAPES — large-vs-small unit-price monotonicity (incl. the pB <= pS + pS/1000 + 1
#    tolerance form via the contract's own simulate*/preview* views), before-vs-after holder per-share price,
#    and actor-A-vs-B value parity.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1778 three metamorphic-ensemble variant shapes ..."

if grep -q 'LARGE-vs-SMALL per-unit-price MONOTONICITY' "$PROVER" \
   && grep -q 'simulate\*` / `preview\*' "$PROVER"; then
  ok "variant 0 present (large-vs-small unit-price monotonicity via simulate*/preview* views)"
else
  bad "variant 0 missing (large-vs-small unit-price monotonicity)"
fi

if grep -q 'require(pB <= pS + pS/1000 + 1' "$PROVER"; then
  ok "variant 0 carries the forge-proven pB <= pS + pS/1000 + 1 tolerance form"
else
  bad "variant 0 missing the pB <= pS + pS/1000 + 1 tolerance form"
fi

if grep -q 'BEFORE-vs-AFTER MONOTONICITY relation for an EXISTING' "$PROVER" \
   && grep -q 'require(afterPer >= beforePer' "$PROVER"; then
  ok "variant 1 present (before-vs-after existing-holder per-share price monotonicity)"
else
  bad "variant 1 missing (before-vs-after holder-price)"
fi

if grep -q 'ACTOR-A-vs-ACTOR-B PARITY relation' "$PROVER" \
   && grep -q 'actor A/B value parity broken' "$PROVER"; then
  ok "variant 2 present (actor-A-vs-B same-sized-op value parity)"
else
  bad "variant 2 missing (actor-A-vs-B parity)"
fi

# ----------------------------------------------------------------------------------------------------------
# 2b) #1783 ORACLE-MANIPULATION LENS CLASS — the oracle branch is present in action_checklist_prompt() and
#     metamorphic_relation_prompt() (matched inline, DISJOINT keywords, placed after the reentran block), and the
#     three oracle ensemble variant seeds are present with their forge-proven require() forms. Default-off is
#     preserved by the custody-first precedence asserted in section 1.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1783 oracle-manipulation lens class ..."

# action_checklist_prompt() oracle branch — price-perturbation + stale-then-fresh actions.
if grep -q 'PRICE-PERTURBATION action' "$PROVER" \
   && grep -q 'STALE-THEN-FRESH read action' "$PROVER"; then
  ok "action_checklist_prompt() carries the oracle branch (price-perturbation + stale-then-fresh actions)"
else
  bad "action_checklist_prompt() missing the oracle branch"
fi

# metamorphic_relation_prompt() oracle menu — the three shapes.
if grep -q 'MONOTONE-PRICE-RESPONSE' "$PROVER" \
   && grep -q 'STALE-VS-FRESH PARITY' "$PROVER" \
   && grep -q 'MANIPULATION-BOUNDED-EXTRACTION' "$PROVER"; then
  ok "metamorphic_relation_prompt() carries the three oracle metamorphic shapes"
else
  bad "metamorphic_relation_prompt() missing one or more oracle metamorphic shapes"
fi

# The three oracle ensemble variant seeds + their pinned require() forms.
if grep -q 'ORACLE-PRICE MONOTONICITY relation' "$PROVER" \
   && grep -q 'require(vHi >= vLo && vHi <= vLo + vLo/20 + 1' "$PROVER"; then
  ok "oracle variant 0 present (bounded-move price monotonicity, vHi/vLo require form)"
else
  bad "oracle variant 0 missing (bounded-move price monotonicity)"
fi

if grep -q 'STALE-vs-FRESH oracle PARITY relation' "$PROVER" \
   && grep -q 'require(vStale <= vFresh + vFresh/1000 + 1' "$PROVER"; then
  ok "oracle variant 1 present (stale-vs-fresh parity, vStale/vFresh require form)"
else
  bad "oracle variant 1 missing (stale-vs-fresh parity)"
fi

if grep -q 'MANIPULATION-BOUNDED-EXTRACTION relation' "$PROVER" \
   && grep -q 'require(gainA <= gainB + gainB/1000 + 1' "$PROVER"; then
  ok "oracle variant 2 present (manipulation-bounded-extraction, gainA/gainB require form)"
else
  bad "oracle variant 2 missing (manipulation-bounded-extraction)"
fi

# run-zone-hunt.sh dominant_class() routes an oracle-dependent zone (C2, no custody-primary code) to the oracle
# lens — appended AFTER C6/C10/C11 so value-custody-primary zones stay byte-identical.
# (substring match: #1784 appends "C16" after "C2", so the tuple no longer ends at C2 — assert the "C11", "C2"
# ordering that keeps custody-primary codes ahead of the oracle code, unchanged by the C16 append.)
if grep -q '"C10", "C11", "C2"' "$ZONEHUNT"; then
  ok "run-zone-hunt.sh dominant_class() appends C2 after C10/C11 (oracle zones reach the lens; custody unchanged)"
else
  bad "run-zone-hunt.sh dominant_class() does not route C2 (the oracle lens never fires on the live path)"
fi

# ----------------------------------------------------------------------------------------------------------
# 2c) #1784 ARITHMETIC-OVERFLOW / LIVENESS (DoS) LENS CLASS — the liveness branch is present in
#     action_checklist_prompt() and metamorphic_relation_prompt() (matched inline, DISJOINT keywords, placed after
#     the oracle block), and the two liveness ensemble variant seeds are present with their require()/try-catch
#     forms. Default-off is preserved by the oracle-second / liveness-third precedence asserted in section 1.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1784 arithmetic-overflow / liveness (DoS) lens class ..."

# #1784 (M1) — the liveness detector sibling of is_value_custody / is_oracle_dependent, with DISJOINT keywords.
if grep -q 'fn is_liveness_sensitive(klass: string) -> bool' "$PROVER"; then
  ok "is_liveness_sensitive() is defined on the prover (arithmetic-overflow / liveness lens class)"
else
  bad "is_liveness_sensitive() missing from the prover"
fi

# C16 (State-machine liveness / stuck-state) maps to the "liveness" keyword in class_to_keyword (the bare-code path).
if grep -q 'if class_is(k, "c16") { return "liveness"; }' "$PROVER"; then
  ok "class_to_keyword() maps the bare C16 taxonomy code to the \"liveness\" keyword"
else
  bad "class_to_keyword() does not map C16 to \"liveness\" (the liveness lens would never route)"
fi

# action_checklist_prompt() liveness branch — wrap-boundary + full-range entrypoint-sweep actions.
if grep -q 'WRAP-BOUNDARY action' "$PROVER" \
   && grep -q 'FULL-RANGE ENTRYPOINT-SWEEP action' "$PROVER"; then
  ok "action_checklist_prompt() carries the liveness branch (wrap-boundary + full-range entrypoint-sweep actions)"
else
  bad "action_checklist_prompt() missing the liveness branch"
fi

# metamorphic_relation_prompt() liveness menu — the two shapes.
if grep -q 'NO-REVERT-ON-VALID-RANGE' "$PROVER" \
   && grep -q 'NARROW-INT-NO-WRAP' "$PROVER"; then
  ok "metamorphic_relation_prompt() carries the two liveness metamorphic shapes"
else
  bad "metamorphic_relation_prompt() missing one or more liveness metamorphic shapes"
fi

# The two liveness ensemble variant seeds + their pinned require()/try-catch forms.
if grep -q 'NO-REVERT-ON-VALID-RANGE relation' "$PROVER" \
   && grep -q 'critical path bricked over valid input' "$PROVER"; then
  ok "liveness variant 0 present (no-revert-on-valid-range, try/catch revert form)"
else
  bad "liveness variant 0 missing (no-revert-on-valid-range)"
fi

if grep -q 'NARROW-INT-NO-WRAP relation' "$PROVER" \
   && grep -q 'require(cAfter >= cBefore' "$PROVER"; then
  ok "liveness variant 1 present (narrow-int-no-wrap, cAfter/cBefore require form)"
else
  bad "liveness variant 1 missing (narrow-int-no-wrap)"
fi

# run-zone-hunt.sh dominant_class() routes a liveness-only zone (C16, no custody-primary or oracle code) to the
# liveness lens — appended AFTER C6/C10/C11/C2 so value-custody and oracle zones stay byte-identical.
if grep -q 'for c in ("C6", "C10", "C11", "C2", "C16"):' "$ZONEHUNT"; then
  ok "run-zone-hunt.sh dominant_class() appends C16 after C2 (liveness zones reach the lens; custody/oracle unchanged)"
else
  bad "run-zone-hunt.sh dominant_class() does not route C16 (the liveness lens never fires on the live path)"
fi

# ----------------------------------------------------------------------------------------------------------
# 3) RUNNER — parses --ensemble-candidates (default 0, whole-number-validated), guards N<2=>OFF and fixture=>OFF,
#    appends INV_ENSEMBLE_VARIANT to the exec.env_passthrough allowlist at the END, and carries the aggregate
#    vote + the CANDIDATE|/aggregate-INVARIANT| synthesis.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1778 run-invariant-hunt.sh ensemble loop + aggregation ..."

if grep -q -- '--ensemble-candidates) need "$#"; ENSEMBLE_CANDIDATES="$2"; shift 2 ;;' "$RUNNER"; then
  ok "the runner parses --ensemble-candidates"
else
  bad "the runner does not parse --ensemble-candidates"
fi

if grep -q 'ENSEMBLE_CANDIDATES="0"' "$RUNNER"; then
  ok "--ensemble-candidates defaults to 0 (OFF)"
else
  bad "--ensemble-candidates does not default to 0"
fi

# Whole-number validation with empty => 0 (the --corpus-max idiom).
if grep -q "run-invariant-hunt.sh: --ensemble-candidates must be a whole number" "$RUNNER"; then
  ok "--ensemble-candidates is whole-number-validated"
else
  bad "--ensemble-candidates is not whole-number-validated"
fi

# The ON path is gated on N>=2 AND the LLM path (no --handler-fixture) => N<2 or fixture => the OFF single run.
if grep -q 'if \[ "$ENSEMBLE_CANDIDATES" -ge 2 \] && \[ -z "$FIXTURE_IN_RUN" \]; then' "$RUNNER"; then
  ok "the ON path is guarded N>=2 AND non-fixture (N<2 or fixture => OFF single path)"
else
  bad "the ON path is not guarded on N>=2 AND non-fixture"
fi

# INV_ENSEMBLE_VARIANT is APPENDED at the END of the allowlist (after INV_CORE_FEATURES).
if grep -q ',INV_CORE_FEATURES,INV_ENSEMBLE_VARIANT"' "$RUNNER"; then
  ok "INV_ENSEMBLE_VARIANT is appended at the END of the exec.env_passthrough allowlist"
else
  bad "INV_ENSEMBLE_VARIANT is not appended at the END of the exec.env_passthrough allowlist"
fi

# The env-block plumbing threads INV_ENSEMBLE_VARIANT="$_variant" into the per-candidate agentis go.
if grep -q 'INV_ENSEMBLE_VARIANT="$_variant"' "$RUNNER"; then
  ok "run_one_candidate threads INV_ENSEMBLE_VARIANT into the per-candidate env block"
else
  bad "run_one_candidate does not thread INV_ENSEMBLE_VARIANT into the env block"
fi

# The single agentis go was factored into run_one_candidate (called ONCE with variant="" on the OFF path).
if grep -q 'VERD="$(run_one_candidate "" "$INV_OUT" "$CELL_LOG")"' "$RUNNER"; then
  ok "the OFF path calls run_one_candidate ONCE with variant=\"\" + the canonical INV_OUT/CELL_LOG"
else
  bad "the OFF path does not call run_one_candidate with the canonical variant/INV_OUT/CELL_LOG"
fi

# Aggregate vote: any FINDING => FINDING; else any HARNESS_ERROR => HARNESS_ERROR; else CLEAN.
if grep -q 'ENS_AGG="CLEAN"' "$RUNNER" \
   && grep -q 'if \[ "$ENS_AGG" != "FINDING" \]; then ENS_AGG="FINDING"' "$RUNNER" \
   && grep -q 'if \[ "$ENS_AGG" != "FINDING" \] && \[ -n "$ENS_HAD_HARNESS" \]; then ENS_AGG="HARNESS_ERROR"; fi' "$RUNNER"; then
  ok "the ensemble aggregate vote holds (>=1 FINDING => FINDING; else >=1 HARNESS_ERROR => HARNESS_ERROR; else CLEAN)"
else
  bad "the ensemble aggregate-vote table regressed"
fi

# Per-candidate diagnostics use a CANDIDATE| prefix that carries NO INVARIANT| substring.
if grep -q 'CANDIDATE|$TARGET|$ens_i|$ens_i|$ens_verd' "$RUNNER"; then
  ok "per-candidate diagnostics use the CANDIDATE| prefix (no INVARIANT| substring)"
else
  bad "per-candidate diagnostics do not use the CANDIDATE| prefix"
fi

# The aggregate INVARIANT| is synthesized as the LAST such line so both tail -1 consumers read it unchanged.
if grep -q "printf 'INVARIANT|%s|%s\\\\n' \"\$TARGET\" \"\$VERD\"" "$RUNNER"; then
  ok "the aggregate INVARIANT|<target>|<verdict> is synthesized as the LAST INVARIANT| line"
else
  bad "the aggregate INVARIANT| synthesis is missing"
fi

# ----------------------------------------------------------------------------------------------------------
# 4) VERDICT CONTRACT UNTOUCHED — the prover's INVARIANT| marker, verdict_of(), and the #1471 target-linkage
#    gate strings are unchanged. The ensemble is prompt steering (per candidate) + a shell-side vote; it must
#    NEVER become a second gate or alter the marker contract.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that #1778 left the verdict/marker/linkage contract intact ..."

if grep -q 'print("INVARIANT|" + targetFn + "|" + verdict);' "$PROVER"; then
  ok "the INVARIANT|<target>|<verdict> marker emission is unchanged (fuzzer stays the sole verdict)"
else
  bad "the INVARIANT| marker emission changed unexpectedly"
fi

if grep -q 'fn verdict_of(rc: int) -> string {' "$PROVER"; then
  ok "verdict_of(rc) is unchanged (the fuzzer exit code is still the sole verdict source)"
else
  bad "verdict_of() changed unexpectedly"
fi

if grep -q -- '--require-import' "$PROVER" && grep -q -- '--require-contract' "$PROVER"; then
  ok "the #1471 --require-import/--require-contract target-linkage gate strings are intact"
else
  bad "the #1471 target-linkage gate strings changed unexpectedly"
fi

# The #1725 handler-action normalizer count must stay EXACTLY 2 (is_value_custody uses a distinct `vk`, and
# metamorphic_variant_seed reuses metamorphic_relation_prompt's `mk` — neither collides with the count).
if [ "$(grep -c 'let k = class_to_keyword(to_lower(klass));' "$PROVER")" -eq 2 ]; then
  ok "the #1725 handler-action normalizer count is still exactly 2 (#1778 did not collide with it)"
else
  bad "the #1725 handler-action normalizer count changed (#1778 collided with action_checklist_* wiring)"
fi

# ----------------------------------------------------------------------------------------------------------
# 5) BENCH FORWARDING — run-zone-hunt.sh forwards --ensemble-candidates verbatim via DEEP_FWD, and
#    deep-hunt-ab.sh forwards it into the --live ON arm's deep-hunt lens (self-test path untouched).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1778 bench forwarding ..."

if grep -q -- '--ensemble-candidates) nv "$#"; DEEP_FWD+=(--ensemble-candidates "$2"); shift 2 ;;' "$ZONEHUNT"; then
  ok "run-zone-hunt.sh forwards --ensemble-candidates verbatim via DEEP_FWD"
else
  bad "run-zone-hunt.sh does not forward --ensemble-candidates via DEEP_FWD"
fi

if grep -q -- '--ensemble-candidates) nv "$#"; ENSEMBLE_CANDIDATES="$2"; shift 2 ;;' "$ABBENCH" \
   && grep -q '${ENSEMBLE_CANDIDATES:+--ensemble-candidates "$ENSEMBLE_CANDIDATES"}' "$ABBENCH"; then
  ok "deep-hunt-ab.sh parses --ensemble-candidates and forwards it into the --live ON-arm lens"
else
  bad "deep-hunt-ab.sh does not parse + forward --ensemble-candidates into the --live ON arm"
fi

# ----------------------------------------------------------------------------------------------------------
# 6) MERGE ADAPTER READS THE AGGREGATE, NOT A PER-CANDIDATE LOG — the ensemble writes per-candidate logs
#    `invariant_<t>_c<N>.log` ALONGSIDE the canonical aggregate `invariant_<t>.log`. The run-zone-hunt.sh
#    merge adapter globs `invariant_*.log` and reads `sorted()[-1]`; since `_` (0x5F) > `.` (0x2E) in
#    codepoint order, WITHOUT a filter `sorted()[-1]` lands on the last per-candidate CLEAN log and silently
#    drops a real ensemble FINDING (the Δ=+0 regression). Guard both the source filter AND the behaviour.
# ----------------------------------------------------------------------------------------------------------
note "guarding the #1778 merge adapter (aggregate log wins over per-candidate logs) ..."

if grep -qE '_c\[0-9\]\+\\\.log\$' "$ZONEHUNT"; then
  ok "run-zone-hunt.sh merge adapter filters per-candidate _c<N>.log out of the invariant_*.log glob"
else
  bad "run-zone-hunt.sh merge adapter does NOT filter per-candidate _c<N>.log (ensemble FINDING would be dropped)"
fi

# Behavioural: replicate the adapter's selection over the real failure-pattern filenames and assert it
# picks the FINDING aggregate, not a CLEAN per-candidate. Pure python3 (CI-safe; no toolchain/agentis/forge).
_sel_tmp="$(mktemp -d)"
: > "$_sel_tmp/invariant_src_Pool_sol.log"        # aggregate (ensemble-vote verdict lives here)
: > "$_sel_tmp/invariant_src_Pool_sol_c0.log"
: > "$_sel_tmp/invariant_src_Pool_sol_c1.log"
: > "$_sel_tmp/invariant_src_Pool_sol_c2.log"
printf 'INVARIANT|src/Pool.sol|FINDING\n' > "$_sel_tmp/invariant_src_Pool_sol.log"
printf 'INVARIANT|src/Pool.sol|CLEAN\n'   > "$_sel_tmp/invariant_src_Pool_sol_c2.log"
_picked="$(python3 - "$_sel_tmp" <<'PY'
import sys, os, glob, re
d = sys.argv[1]
logs = sorted(glob.glob(os.path.join(d, "invariant_*.log")))
logs = [p for p in logs if not re.search(r"_c[0-9]+\.log$", os.path.basename(p))]
verdict = None
with open(logs[-1], encoding="utf-8", errors="ignore") as fh:
    for line in fh:
        if "INVARIANT|" in line:
            verdict = line.split("INVARIANT|", 1)[1].strip().split("|")[1].strip()
print(verdict or "NONE")
PY
)"
rm -rf "$_sel_tmp"
if [ "$_picked" = "FINDING" ]; then
  ok "merge adapter selection reads the aggregate FINDING (not a per-candidate CLEAN) under codepoint sort"
else
  bad "merge adapter selection picked '$_picked' (expected FINDING) — the codepoint-sort regression is back"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: #1778 single-run metamorphic ensemble is wired — is_value_custody() + metamorphic_variant_seed()"
  note "      are defined, byte-identical when OFF (empty INV_ENSEMBLE_VARIANT => \"\"), the three variant shapes"
  note "      (large-vs-small unit-price, before-vs-after holder-price, actor-A-vs-B parity) are present, the"
  note "      runner parses/validates/guards --ensemble-candidates + appends INV_ENSEMBLE_VARIANT at the END of"
  note "      the allowlist + synthesizes the CANDIDATE|/aggregate-INVARIANT| vote, the INVARIANT| marker +"
  note "      verdict_of + #1471 gate are untouched, the #1725 normalizer count is still 2, and the bench"
  note "      forwarding (run-zone-hunt.sh DEEP_FWD + deep-hunt-ab.sh --live ON arm) is wired."
  exit 0
fi
note "DEMO FAILED — a #1778 metamorphic-ensemble wiring assertion did not hold" >&2
exit 1
