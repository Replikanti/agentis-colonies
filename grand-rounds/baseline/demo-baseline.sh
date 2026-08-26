#!/bin/bash
# demo-baseline.sh — offline, CI-safe checks for the grand-rounds baseline
# colony. Pure bash over fixtures/ + source-guards on agents/pipeline.ag. No
# agentis, no network, no gated data. Exercised by tools/colony-lint.sh.
#
# What CI cannot do is EXECUTE the .ag (no agentis binary on runners), so this
# demo pins structure, the leak guard, and .ag source-shape; the .ag BEHAVIOUR
# is pinned by the operator-run demo-baseline-live.sh mutation test.
#
# Exit 0 all checks pass, 1 otherwise.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BASE_DIR/../.." && pwd)"
AG="$BASE_DIR/agents/pipeline.ag"
TMPL="$BASE_DIR/settings/exomiser-analysis.template.yml"
TOML="$BASE_DIR/config/colony.example.toml"
GUARD="$REPO_ROOT/tools/check-no-gated-data.sh"

pass=0
fail=0
ok() { echo "  [ok] $1"; pass=$((pass + 1)); }
bad() { echo "  [FAIL] $1" >&2; fail=$((fail + 1)); }

echo "grand-rounds/baseline: offline demo"

# --- 1. Leak guard is not vacuous (mutation test) --------------------------
echo "1. leak guard"
if bash "$GUARD" --static >/dev/null 2>&1; then
    ok "check-no-gated-data --static clean on the real tracked tree"
else
    bad "leak guard flags the real tree (should be clean)"
fi

MUT="$(mktemp -d)"
trap 'rm -rf "$MUT"' EXIT
(
    cd "$MUT"
    git init -q
    git config user.email t@t; git config user.name t
    # Plant a concrete HPO id and a gated .vcf outside any fixtures/ allowlist.
    # The id is assembled at runtime (fragments) so this SOURCE file carries no
    # concrete HP:<7 digits> literal — only the planted temp tree does.
    printf 'note: HP:%s seizure\n' '0001250' > leaked-notes.txt
    printf '##fileformat=VCFv4.2\n' > proband.vcf
    git add -A >/dev/null 2>&1
)
if bash "$GUARD" --static --root "$MUT" >/dev/null 2>&1; then
    bad "leak guard did NOT fail on a planted HP id + .vcf (a guard that cannot fail is not a guard)"
else
    ok "check-no-gated-data --static fails on a planted leak"
fi

# --- 2. Fixture purity -----------------------------------------------------
echo "2. fixture purity"
for vcf in "$BASE_DIR"/fixtures/*.vcf; do
    [ -f "$vcf" ] || continue
    b="$(basename "$vcf")"
    if grep -qE '^#CHROM' "$vcf" && grep -qE '\bSAMPLE_SYNTH\b' "$vcf"; then
        ok "$b carries the synthetic sample name SAMPLE_SYNTH"
    else
        bad "$b missing synthetic sample name"
    fi
    records="$(grep -cvE '^#' "$vcf" || true)"
    if [ "$records" -lt 100 ]; then
        ok "$b has $records records (< 100)"
    else
        bad "$b has $records records (>= 100)"
    fi
    if grep -qE 'HP:[0-9]{7}' "$vcf"; then
        bad "$b contains a concrete HP: literal"
    else
        ok "$b has no HP: literal"
    fi
done
if grep -qE '^>chr' "$BASE_DIR/fixtures/mini.fa"; then
    ok "mini.fa is a synthetic mini-contig FASTA"
else
    bad "mini.fa is not a chr-prefixed synthetic FASTA"
fi

# --- 3. Source-guards on agents/pipeline.ag --------------------------------
echo "3. .ag source-guards"
for a in coordinator preprocessor phenotyper exomiser_runner panel_reviewer reconciler emitter; do
    if grep -qE "^agent $a\(\) -> void" "$AG"; then
        ok "agent $a defined"
    else
        bad "agent $a missing"
    fi
done
# Bus-wired: each stage listens and emits.
for ev in "baseline:normalized_vcf" "baseline:hpo_ids" "baseline:panel_hits" "baseline:candidates"; do
    if grep -qF "emit(\"$ev\"" "$AG" && grep -qF "listen(\"$ev\"" "$AG"; then
        ok "bus event $ev is both emitted and listened"
    else
        bad "bus event $ev not fully wired"
    fi
done
# Schema validator enforces all rules.
for rule in "column-count" "chrom_1-not-chr-primary" "epcr-out-of-range" "pair-partial" "finding_type"; do
    if grep -qF "\"$rule\"" "$AG"; then
        ok "schema rule '$rule' enforced"
    else
        bad "schema rule '$rule' absent from validator"
    fi
done
for rule in "too-many-rows" "dup-key"; do
    if grep -qF "\"$rule\"" "$AG"; then
        ok "emit-stage rule '$rule' enforced"
    else
        bad "emit-stage rule '$rule' absent"
    fi
done
# failedVariantFilter is rendered EMPTY (D4) and is not an active template step.
if grep -qF '"{{FAILED_VARIANT_FILTER}}", ""' "$AG"; then
    ok "failedVariantFilter placeholder is rendered empty (D4)"
else
    bad "failedVariantFilter is not rendered empty"
fi
if grep -qE '^\s*failedVariantFilter\s*:' "$TMPL"; then
    bad "template has an ACTIVE failedVariantFilter step (must be a placeholder only)"
else
    ok "template has no active failedVariantFilter step"
fi
# D6 gate compares a stored hash, not mere file presence.
if grep -qF 'approved_hash != draft_hash' "$AG"; then
    ok "D6 gate compares a stored sha256 (not file presence)"
else
    bad "D6 gate does not compare a stored hash"
fi
# No embedded interpreters (substrate-purity spirit).
if grep -qE 'python3 -c|[^a-z]awk |[^a-z]sed ' "$AG"; then
    bad "embedded python3 -c / awk / sed logic found in the .ag"
else
    ok "no embedded python3 -c / awk / sed logic"
fi
# Every exec sh with a dynamic concat carries a safe-exec-concat annotation.
concat_lines="$(grep -cE 'exec sh .*\+ ' "$AG" || true)"
anno_lines="$(grep -cF '// colony-lint: safe-exec-concat' "$AG" || true)"
if [ "$anno_lines" -ge "$concat_lines" ]; then
    ok "exec sh dynamic concats are shell_escape-annotated ($anno_lines >= $concat_lines)"
else
    bad "an exec sh dynamic concat is not shell_escape-annotated ($anno_lines < $concat_lines)"
fi

# --- 4. cb_budget matches the cb <N> declaration ---------------------------
echo "4. cb_budget consistency"
cb_ag="$(grep -oE '^cb [0-9]+;' "$AG" | grep -oE '[0-9]+')"
cb_toml="$(grep -oE 'cb_budget = [0-9]+' "$TOML" | grep -oE '[0-9]+')"
if [ -n "$cb_ag" ] && [ "$cb_ag" = "$cb_toml" ]; then
    ok "cb $cb_ag; == cb_budget $cb_toml"
else
    bad "cb ($cb_ag) != cb_budget ($cb_toml)"
fi

echo "grand-rounds/baseline demo: $pass ok, $fail failed"
[ "$fail" -eq 0 ]
