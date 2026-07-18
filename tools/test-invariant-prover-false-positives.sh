#!/usr/bin/env bash
# shellcheck disable=SC2016  # grep -F patterns intentionally contain literal backticks/$ matched verbatim in the .ag source
# tools/test-invariant-prover-false-positives.sh -- deterministic regression
# guard for #1080 (dark-factory). A real autonomous sweep triaged two FINDINGs
# to HARNESS ARTIFACTS (false positives), not real bugs:
#   1. UNBOUNDED FUZZ INPUTS. An oracle target's price-setter action was
#      unbounded, so the fuzzer drove the reported price to absurd magnitudes
#      (2.26e30) and a "price within a sanity band" invariant trivially broke.
#      A real attack is a realistic depeg (~$1.20), not 1e30.
#   2. MOCK-DEP DECIMALS MISMATCH. A mocked dependency used 18 decimals while
#      the real contract computes that token in 6 decimals (10^12 scaling) -> a
#      solvency invariant broke spuriously.
#
# The fix adds TWO directives to the `generate_test()` instruction string:
#   - REALISTIC INPUT BOUNDS: BOUND every fuzzed input via the private
#     `_bound(x, lo, hi)` to a REALISTIC range, ESPECIALLY external-perturbation
#     actions (price/oracle/deviation/donation/fee/rate setters), NEVER an
#     arbitrary `uint`; an invariant may break ONLY under a realistic multi-step
#     sequence, and a break caused SOLELY by an absurd-magnitude input (e.g. a
#     price of 1e30) is NOT a finding and the harness must not allow it.
#   - MOCK-DEP FIDELITY: any mock of an external dependency MUST match the REAL
#     units/decimals/types the target assumes (read from the target source —
#     e.g. a 6-decimal USDC mock returns 6); a mismatched mock is INVALID and
#     produces false findings.
#
# This test pins both directives in `generate_test()` so they cannot silently
# regress. Pure grep/awk over the .ag source — no agentis runtime, no LLM, no
# forge required. Auto-discovered and run by tools/colony-lint.sh's
# `tools/test-*.sh` loop.
#
# Assertions over the `generate_test()` instruction text:
#   (a) The realistic-input-bounds directive is present: it directs `_bound`ing
#       every fuzzed input to a REALISTIC range, calls out external-perturbation
#       actions (price/oracle setters etc.) explicitly, and forbids an arbitrary
#       `uint` for them.
#   (b) The realistic-bounds directive carries the "absurd-magnitude input is
#       NOT a finding" framing (the 1e30 example + "NOT a finding").
#   (c) The mock-dep fidelity directive is present: any mock of an external
#       dependency MUST match the REAL units/decimals/types the target assumes,
#       and a mismatched mock is INVALID / produces false findings.
#   (d) The #1067 budget + prior anchors survive (still EXACTLY ONE lens-driven
#       invariant under ~120 lines, real-target import/deploy, no forge-std,
#       targetContracts(), output-only) — the new bullets are guidance, not
#       extra invariants.
#
# Usage: bash tools/test-invariant-prover-false-positives.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AG="$REPO_ROOT/dark-factory/auditor/agents/invariant-prover.ag"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$AG" ]; then
    fail "ag exists" "$AG not found"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Extract the STATIC generation instruction. Since #1720 it is factored out of
# generate_test() into the module-level `harness_skeleton()` (the canonical
# compiling skeleton) + the `sharedScaffold` string (the requirement paragraphs
# + bug-class lens + answer contract); generate_test appends sharedScaffold and
# the compile-repair chain re-injects it. Capture BOTH blocks so the assertions
# scope to that instruction text and never to doc comments or other agents.
gen_body="$(awk '/^fn harness_skeleton\(/{f=1} f{print} f&&/^}/{f=0}' "$AG"; awk '/^let sharedScaffold/{f=1} f{print} f&&/;[[:space:]]*$/{f=0}' "$AG")"

if [ -z "$gen_body" ]; then
    fail "generate_test body found" "no 'fn generate_test(...)' block in $AG"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# (a) The realistic-input-bounds directive must direct `_bound`ing every fuzzed
# input to a REALISTIC range, call out external-perturbation actions, and forbid
# an arbitrary `uint` for them.
rb_fail=""
printf '%s\n' "$gen_body" | grep -Fq 'REALISTIC INPUT BOUNDS' \
    || rb_fail="${rb_fail} realistic-bounds-header"
printf '%s\n' "$gen_body" | grep -Fq 'EXTERNAL-PERTURBATION action' \
    || rb_fail="${rb_fail} external-perturbation-callout"
printf '%s\n' "$gen_body" | grep -Eq 'price/oracle setters' \
    || rb_fail="${rb_fail} price-oracle-setters-example"
printf '%s\n' "$gen_body" | grep -Fq 'NEVER an arbitrary `uint`' \
    || rb_fail="${rb_fail} never-arbitrary-uint"

if [ -z "$rb_fail" ]; then
    pass "(a) generate_test directs realistic _bound-ing of every fuzzed input (esp. external-perturbation setters)"
else
    fail "(a) generate_test directs realistic input bounds" \
         "missing realistic-bounds piece(s):$rb_fail"
fi

# (b) The realistic-bounds directive must carry the "absurd-magnitude input is
# NOT a finding" framing: the 1e30 example AND the explicit "NOT a finding".
if printf '%s\n' "$gen_body" | grep -Fq '1e30' \
   && printf '%s\n' "$gen_body" | grep -Fq 'absurd-magnitude input' \
   && printf '%s\n' "$gen_body" | grep -Fq 'is NOT a finding'; then
    pass "(b) generate_test frames an absurd-magnitude-input break (1e30) as NOT a finding"
else
    fail "(b) generate_test frames an absurd-magnitude-input break as NOT a finding" \
         "missing the 1e30 / 'absurd-magnitude input' / 'is NOT a finding' framing"
fi

# (c) The mock-dep fidelity directive must require any mock of an external
# dependency to MATCH the REAL units/decimals/types the target assumes, with the
# decimals example, and must mark a mismatched mock INVALID / a false-finding
# source.
md_fail=""
printf '%s\n' "$gen_body" | grep -Fq 'MOCK-DEP FIDELITY' \
    || md_fail="${md_fail} mock-fidelity-header"
printf '%s\n' "$gen_body" | grep -Fq 'MUST match the REAL' \
    || md_fail="${md_fail} match-real-units"
printf '%s\n' "$gen_body" | grep -Fq 'units/decimals/types' \
    || md_fail="${md_fail} units-decimals-types"
printf '%s\n' "$gen_body" | grep -Fq "mock's \`decimals()\` must return 6" \
    || md_fail="${md_fail} decimals-example"
printf '%s\n' "$gen_body" | grep -Fq 'is INVALID and produces false findings' \
    || md_fail="${md_fail} invalid-false-findings"

if [ -z "$md_fail" ]; then
    pass "(c) generate_test requires mocks to match the target's real units/decimals/types (else INVALID)"
else
    fail "(c) generate_test requires mock-dep unit/decimal/type fidelity" \
         "missing mock-fidelity piece(s):$md_fail"
fi

# (d) The #1067 budget + the prior anchors must survive: the new bullets are
# guidance, not extra invariants. Still EXACTLY ONE lens-driven invariant under
# ~120 lines, real-target import/deploy, no forge-std, targetContracts(),
# output-only.
anchor_fail=""
printf '%s\n' "$gen_body" | grep -Fq 'EXACTLY ONE' \
    || anchor_fail="${anchor_fail} exactly-one-invariant"
printf '%s\n' "$gen_body" | grep -Eq 'under ~?120 lines' \
    || anchor_fail="${anchor_fail} 120-line-budget"
printf '%s\n' "$gen_body" | grep -Fq 'IMPORT and DEPLOY the REAL target' \
    || anchor_fail="${anchor_fail} real-target"
printf '%s\n' "$gen_body" | grep -Fq 'Do NOT import forge-std' \
    || anchor_fail="${anchor_fail} no-forge-std"
printf '%s\n' "$gen_body" | grep -Fq 'targetContracts()' \
    || anchor_fail="${anchor_fail} targetContracts-ABI"
printf '%s\n' "$gen_body" | grep -Fq 'Output ONLY the Solidity source' \
    || anchor_fail="${anchor_fail} output-only"

if [ -z "$anchor_fail" ]; then
    pass "(d) #1067 budget + prior anchors survive (one lens invariant, ~120 lines, real-target, no forge-std, output-only)"
else
    fail "(d) #1067 budget + prior anchors survive" \
         "missing anchor(s):$anchor_fail"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
