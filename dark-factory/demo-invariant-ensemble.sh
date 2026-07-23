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

# Non-value-custody classes also get "" (defensive — the ensemble only runs on value_custody deep-hunt zones).
if grep -q 'if !is_value_custody(klass) { return ""; }' "$PROVER"; then
  ok "metamorphic_variant_seed() returns \"\" for a non-value-custody class (defensive no-op)"
else
  bad "metamorphic_variant_seed() no longer guards on is_value_custody() (could steer a non-custody class)"
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
