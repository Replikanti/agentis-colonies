#!/usr/bin/env bash
# demo-variant-coverage-lens.sh — OFFLINE, DETERMINISTIC gate for the VARIANT-COVERAGE lens (#2265): one new
# bug class, C27, for the shape where a protocol ADMITS several variants of one configurable thing and a
# consuming path handles only some of them:
#
#   C27 — Variant coverage gap:
#         (a) MISSING BRANCH — a consumer handles some of the admitted variants and falls through for the
#             rest (a default or zero return, a revert, a silently skipped step);
#         (b) BASIC-VARIANT HANDLING APPLIED — a consumer never reads the discriminator and treats every
#             variant like the basic one (a plain transfer on a rebasing token, 1:1 on a wrapped token, the
#             wrong interface version's call shape).
#
# The lens IS the taxonomy section (hunter.ag slices `## <cls> ` out of auditor/bug-taxonomy.md and builds
# the cell prompt from it) plus a deterministic SINGLE-ZONE zone-mapper route. The admission and the consumer
# usually sit in different contracts; the class text carries the repository-wide hunt, the route only fires
# on a zone that reads a variant DISCRIMINATOR and owns a VALUE PATH. hunter.ag is NOT touched. This demo
# guards both halves, the text and the behaviour:
#   1. the ANTI-CATCH-ALL contract — C27 carries its `NOT this class` list (C21/C22/C23/C26/C9/C15/C16), its
#      FOUR-part required-evidence rule, both named directions and the four-step hunt, including the
#      WHOLE-repository search and the counterpart-asymmetry check.
#   2. the `class_section()` EXTRACTION anchor, run against the REAL taxonomy: C2 must not swallow C27, the
#      C26 slice must stop before `## C27`, and the C27 slice must not run backwards into C26.
#   3. the DELIBERATE non-changes — no `C27`/`variant_coverage` token in hunter.ag, no `class_to_keyword()`
#      entry, the `DF_TIER2_RARE_CLASSES` default untouched, no C27 token in lib/composition-surfaces.py
#      (no cross-zone pairing), and C26's section byte-unchanged (C27 is ONE axis, C26 is a PAIR of axes;
#      C27 is not shipped by widening C26's prompt text, which earlier arms were scored with).
#   4. the zone-mapper ROUTE, source-guarded AND exercised: the five helpers, the AND, the force-include, the
#      chain position, the gated diagnostic, prompt purity, the TOKEN-PROVENANCE contract with a pinned
#      digest of the frozen token list — and, when agentis is present, a REAL, LLM-FREE probe of the shipped
#      `apply_backstop()` over five fixtures (one TRUE per discriminator surface, two FALSE) plus a DUP.
#
# This demo proves the MACHINERY and the TEXT, never the capability: whether C27 recovers a rare row is the
# pre-registered measurement on the sealed reserve set (an operator step after merge, not CI).
#
# Usage:  dark-factory/demo-variant-coverage-lens.sh
# Requires: awk + grep (the floor); agentis additionally enables the behavioural probe (skipped without it).
# Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TAXONOMY="$HERE/auditor/bug-taxonomy.md"
MAPPER="$HERE/auditor/agents/zone-mapper.ag"
HUNTER="$HERE/auditor/agents/hunter.ag"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
DISCOVERY="$HERE/run-discovery.sh"
COMPOSITION="$HERE/lib/composition-surfaces.py"

FAILS=0
note() { echo "demo-variant-coverage-lens.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$TAXONOMY" ]    || { note "bug-taxonomy.md not found: $TAXONOMY" >&2; exit 3; }
[ -f "$MAPPER" ]      || { note "zone-mapper.ag not found: $MAPPER" >&2; exit 3; }
[ -f "$HUNTER" ]      || { note "hunter.ag not found: $HUNTER" >&2; exit 3; }
[ -f "$PROVER" ]      || { note "invariant-prover.ag not found: $PROVER" >&2; exit 3; }
[ -f "$DISCOVERY" ]   || { note "run-discovery.sh not found: $DISCOVERY" >&2; exit 3; }
[ -f "$COMPOSITION" ] || { note "lib/composition-surfaces.py not found: $COMPOSITION" >&2; exit 3; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# hunter.ag's own class_section() awk anchor, verbatim in shape: take the `## <cls> ` section and stop at
# the next `## ` header that is not this class.
class_section() {
  awk -v c="$1" 'index($0,"## "c" ")==1{f=1} f&&index($0,"## ")==1&&index($0,"## "c" ")!=1{exit} f{print}' \
    "$TAXONOMY" 2>/dev/null
}

# ----------------------------------------------------------------------------------------------------------
# (a) The taxonomy declares C27 as a top-level section (what class_section() anchors on).
# ----------------------------------------------------------------------------------------------------------
note "1) bug-taxonomy.md declares the C27 class header ..."
if grep -q '^## C27 ' "$TAXONOMY"; then
  ok "bug-taxonomy.md declares the '## C27 ' class header"
else
  bad "bug-taxonomy.md missing the '## C27 ' class header"
fi

# ----------------------------------------------------------------------------------------------------------
# (b) ANTI-CATCH-ALL contract: the guard headers, the FOUR-part evidence rule, the enumerate instruction.
# ----------------------------------------------------------------------------------------------------------
note "2) C27 carries its NOT-this-class + four-part required-evidence guards and the enumeration instruction ..."
C27="$(class_section C27)"
miss=""
case "$C27" in *"**NOT this class:**"*) ;; *) miss="$miss [NOT this class]" ;; esac
case "$C27" in *"**required evidence (else report SAFE):**"*) ;; *) miss="$miss [required evidence]" ;; esac
case "$C27" in *"enumerate, do not intuit"*) ;; *) miss="$miss [enumerate, do not intuit]" ;; esac
case "$C27" in *"(i)"*) ;; *) miss="$miss [(i)]" ;; esac
case "$C27" in *"(ii)"*) ;; *) miss="$miss [(ii)]" ;; esac
case "$C27" in *"(iii)"*) ;; *) miss="$miss [(iii)]" ;; esac
case "$C27" in *"(iv)"*) ;; *) miss="$miss [(iv)]" ;; esac
case "$C27" in *"Missing any of the four -> not a C27 candidate"*) ;; *) miss="$miss [four-part SAFE rule]" ;; esac
if [ -z "$miss" ]; then
  ok "C27 carries NOT-this-class, the FOUR-part required-evidence contract, and the enumeration instruction"
else
  bad "C27 is missing its anti-catch-all guards:$miss"
fi

# The NOT-this-class list must NAME the neighbour classes C27 would otherwise absorb. C26 is the load-bearing
# one: a PAIR of configuration axes never validated together is C26, ONE axis wider than its consumers is C27.
note "3) the NOT-this-class list names every neighbour class C27 must not absorb ..."
NOT_LINE="$(printf '%s\n' "$C27" | grep '^- \*\*NOT this class:\*\*')"
nb_miss=""
for k in C21 C22 C23 C26 C9 C15 C16; do
  case "$NOT_LINE" in *"($k)"*|*"($k "*) ;; *) nb_miss="$nb_miss [$k]" ;; esac
done
if [ -z "$nb_miss" ]; then
  ok "C27 disambiguates itself against C21/C22/C23/C26/C9/C15/C16"
else
  bad "C27's NOT-this-class list lost a neighbour class:$nb_miss"
fi
case "$NOT_LINE" in
  *"C27 is ONE axis"*) ok "C27's NOT-this-class list spells out the one-axis (C27) vs two-axis (C26) split" ;;
  *) bad "C27's NOT-this-class list lost the one-axis vs two-axis split against C26" ;;
esac

# Both DIRECTIONS and the four-step hunt: the class is a DOMAIN description, and these names are what keep it
# from collapsing into a "be more thorough" meta-directive (the measured null shape).
note "4) both directions and the four-step hunt survive ..."
sh_miss=""
for k in "missing branch" "basic-variant handling applied" "AXES + ADMITTED SETS" "EVERY CONSUMER" \
         "COVERAGE GRID" "WHO PAYS"; do
  case "$C27" in *"$k"*) ;; *) sh_miss="$sh_miss [$k]" ;; esac
done
if [ -z "$sh_miss" ]; then
  ok "C27 names both directions (missing branch / basic-variant handling applied) and all four hunt steps"
else
  bad "C27 lost a direction or a hunt step:$sh_miss"
fi

# The hunt must reach ACROSS contracts (the admission usually lives elsewhere) and must ask for the named,
# countable artefacts: the admitted set, the per-cell grid marks, the counterpart-pair asymmetry check and the
# terminal-else check.
note "5) the hunt enumerates the NAMED artefacts (whole-repo search, grid marks, counterpart asymmetry, terminal else) ..."
h_miss=""
for k in "WHOLE repository" "FULL set" "HANDLED / MISSING / BASIC-APPLIED" "counterpart pairs" "UNEVEN coverage" \
         "else revert" "never read the discriminator"; do
  case "$C27" in *"$k"*) ;; *) h_miss="$h_miss [$k]" ;; esac
done
if [ -z "$h_miss" ]; then
  ok "C27's hunt searches the whole repository, writes the coverage grid and checks counterpart asymmetry"
else
  bad "C27 hunt lost an enumeration target:$h_miss"
fi

# The two lint rules the #2231/#2233 guard applies to every prompt-visible file, asserted here on the class
# text itself so a future edit of THIS section cannot reintroduce corpus ground truth into the lens.
note "6) the C27 class text is free of corpus ground truth (the #2231/#2233 rules, applied to this section) ..."
gt_bad=0
case "$C27" in *"corpus-bench"*) gt_bad=1 ;; esac
if printf '%s\n' "$C27" | grep -qE '(^|[^[:alnum:]_])[HM]-[0-9]{1,2}([^[:alnum:]_]|$)'; then gt_bad=1; fi
if [ "$gt_bad" -eq 0 ]; then
  ok "the C27 section carries no 'corpus-bench' literal and no contest GT finding id"
else
  bad "the C27 section carries corpus ground truth — the lens must describe the CODE SHAPE, never the rows it was scored on"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) EXTRACTION PIN: hunter.ag's `## <cls> ` awk anchor over the REAL taxonomy. C2 must not swallow C27, the
#     C26 slice must stop before `## C27`, and the C27 slice must not run backwards into C26.
# ----------------------------------------------------------------------------------------------------------
note "7) class_section() extraction pin: C2 / C26 / C27 slice cleanly ..."
# shellcheck disable=SC2016  # matched VERBATIM against hunter.ag's source (an awk anchor inside an exec-sh string)
if grep -qF 'index($0,\"## \"c\" \")==1' "$HUNTER"; then
  ok "hunter.ag still slices the taxonomy with the '## <cls> ' anchor this test replicates"
else
  bad "hunter.ag's class_section() anchor changed — this extraction pin no longer guards the real code path"
fi
for c in C2 C26 C27; do
  if [ -n "$(class_section "$c")" ]; then
    ok "class_section($c) returns a non-empty slice"
  else
    bad "class_section($c) returned an EMPTY slice — the class is unreachable from hunter.ag"
  fi
done
case "$(class_section C2)" in
  *"## C27"*) bad "the C2 slice swallowed the C27 section (prefix collision)" ;;
  *) ok "the C2 slice does not contain '## C27' (C2's own lens is intact)" ;;
esac
case "$(class_section C26)" in
  *"## C27"*) bad "the C26 slice ran past its own section into C27" ;;
  *) ok "the C26 slice stops before '## C27'" ;;
esac
case "$C27" in
  *"## C26"*) bad "the C27 slice ran backwards into C26" ;;
  *) ok "the C27 slice contains only its own class text (plus the trailing usage notes it inherits as the last class)" ;;
esac

# The routing note hunter/zone-mapper authors read first must mention C27, else the class is invisible to a
# human extending the taxonomy.
note "8) the Hunter usage notes route a variant-discriminator zone to C27 ..."
if grep -q 'depends on which variant it is handling → C27' "$TAXONOMY"; then
  ok "the Hunter usage notes carry the C27 routing clause"
else
  bad "the Hunter usage notes lost the C27 routing clause"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) The DELIBERATE non-changes, pinned as decisions rather than omissions.
# ----------------------------------------------------------------------------------------------------------
note "9) deliberate non-changes: hunter.ag untouched, no class_to_keyword() entry, tier-2 default untouched, no cross-zone pairing ..."
if grep -qE 'C27|variant_coverage' "$HUNTER"; then
  bad "hunter.ag gained a C27 / variant_coverage token — the lens is the taxonomy section, not a hunter directive block (the pure-meta shape measured Delta=+0)"
else
  ok "hunter.ag carries no C27 / variant_coverage token (the class reaches the cell through the taxonomy menu only)"
fi
if grep -q 'class_to_keyword' "$PROVER"; then
  if grep -qE 'class_is\(k, "c27"\)' "$PROVER"; then
    bad "invariant-prover.ag gained a class_to_keyword() entry for C27 — that re-routes the depth/metamorphic action menu, an unmeasured second variable"
  else
    ok "invariant-prover.ag's class_to_keyword() has no C27 entry (C27 falls through to the generic default, like C22-C26)"
  fi
else
  bad "invariant-prover.ag no longer defines class_to_keyword() — this decision pin no longer guards anything"
fi
if grep -q 'DF_TIER2_RARE_CLASSES:-C19,C20,C21,C22,C23,C24}' "$DISCOVERY"; then
  ok "run-discovery.sh's DF_TIER2_RARE_CLASSES default is unchanged (C27 is routed, not tier-2 promoted)"
else
  bad "run-discovery.sh's DF_TIER2_RARE_CLASSES default changed — C27 must not enter the rare-class priority list in this iteration"
fi
# The route is SINGLE-ZONE by decision: the composition-surfaces helper only feeds deep-hunt target selection
# and never reaches scope.tsv classes, so C27 does not ride it.
if grep -qE 'C27|variant' "$COMPOSITION"; then
  bad "lib/composition-surfaces.py gained a C27/variant token — the C27 route is single-zone by decision (no cross-zone pairing)"
else
  ok "lib/composition-surfaces.py carries no C27 token (single-zone route; the class text carries the repository-wide hunt)"
fi

# C26 is the TWO-axis neighbour. Shipping C27 by widening C26 would mutate a prompt string earlier arms were
# scored with, so C26's section is pinned byte-for-byte (its 8 class lines plus the separating blank line;
# before C27 existed the C26 slice ran to EOF and also carried the usage notes, which C27 now inherits).
# NB: if C26 is ever deliberately revised, re-baseline this digest IN THE SAME COMMIT and say so there.
note "10) C26's section is byte-unchanged (C27 is not shipped by widening its two-axis neighbour) ..."
C26_CKSUM="$(class_section C26 | cksum)"
C26_EXPECT="1619095498 5266"
if [ "$C26_CKSUM" = "$C26_EXPECT" ]; then
  ok "the C26 section is byte-identical to the text the earlier arms were measured with"
else
  bad "the C26 section changed (cksum '$C26_CKSUM', expected '$C26_EXPECT') — C27 must not be implemented by editing C26"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) The zone-mapper ROUTE: the deterministic net, its force-include, the diagnostic, the chain order, the
#     ONLY-WHEN-shaped detection rule with its escape clause, and the TOKEN-PROVENANCE contract.
# ----------------------------------------------------------------------------------------------------------
note "11) zone-mapper.ag carries the deterministic C27 net, its force-include and the VARIANT-COVERAGE| diagnostic ..."
net_miss=""
for f in has_variant_enum_ref has_variant_type_flag has_interface_probe has_variant_consumer_path \
         contains_variant_coverage_signal apply_variant_coverage_backstop; do
  grep -q "fn $f" "$MAPPER" || net_miss="$net_miss [$f]"
done
grep -q 'force_include(classesCsv, "C27")' "$MAPPER" || net_miss="$net_miss [force_include C27]"
grep -q '"VARIANT-COVERAGE|"' "$MAPPER" || net_miss="$net_miss [VARIANT-COVERAGE| diagnostic]"
if [ -z "$net_miss" ]; then
  ok "zone-mapper.ag defines the four C27 surfaces, contains_variant_coverage_signal, apply_variant_coverage_backstop -> force_include C27, and the VARIANT-COVERAGE| line"
else
  bad "zone-mapper.ag is missing part of the #2265 C27 route:$net_miss"
fi

# The AND composition, asserted on the source: the consumer surface is MANDATORY (an early return when it is
# absent) and each of the three discriminator surfaces is sufficient on its own once a value path exists. A
# net that ORs the consumer in would fire on every registry and type declaration that names a kind enum.
note "12) the net's composition is (enum ref OR type flag OR interface probe) AND a consumer value path ..."
NET_BODY="$(awk '/^fn contains_variant_coverage_signal/{f=1} f{print} f&&/^}/{exit}' "$MAPPER")"
comp_ok=1
case "$NET_BODY" in *"if !has_variant_consumer_path(code) { return false; }"*) ;; *) comp_ok=0 ;; esac
case "$NET_BODY" in *"if has_variant_enum_ref(code) { return true; }"*) ;; *) comp_ok=0 ;; esac
case "$NET_BODY" in *"if has_variant_type_flag(code) { return true; }"*) ;; *) comp_ok=0 ;; esac
case "$NET_BODY" in *"if has_interface_probe(code) { return true; }"*) ;; *) comp_ok=0 ;; esac
if [ "$comp_ok" -eq 1 ]; then
  ok "contains_variant_coverage_signal() requires the consumer surface and accepts any one of the three discriminator surfaces"
else
  bad "the C27 net composition changed — the consumer value path must be mandatory and each discriminator surface sufficient"
fi

# The net region: flat index_of only. No regex, no exec sh (the substrate-purity discipline of its siblings).
NET_REGION="$(awk '/^fn has_variant_enum_ref/{f=1} f{print} f&&/^fn contains_variant_coverage_signal/{g=1} g&&/^}/{exit}' "$MAPPER")"
note "13) the C27 net is flat index_of only (no regex_, no exec sh) ..."
case "$NET_REGION" in
  *"regex_"*|*"exec sh"*) bad "the C27 net region uses regex_/exec sh — it must stay a flat index_of net" ;;
  *) ok "the C27 net region uses flat index_of only" ;;
esac

# TOKEN PROVENANCE (#2265, binding): every token is generic vocabulary (G), already in this repo's class text
# (T) or dev-attested (D), tagged in-line. The frozen token list is pinned by digest, so any later widening is
# a deliberate re-baseline in the same commit — never a silent edit after seeing a measurement set.
note "14) token-provenance contract: every net token is tagged (G)/(T)/(D) and the frozen token list is pinned ..."
untagged="$(printf '%s\n' "$NET_REGION" | grep 'index_of(code,' | grep -cvE '// \((G|T|D)\)')"
if [ "$untagged" -eq 0 ]; then
  ok "every index_of() token in the C27 net carries a (G)/(T)/(D) provenance tag"
else
  bad "$untagged token(s) in the C27 net have no (G)/(T)/(D) provenance tag"
  printf '%s\n' "$NET_REGION" | grep 'index_of(code,' | grep -vE '// \((G|T|D)\)' | sed 's/^/      /' >&2
fi
TOKENS_CKSUM="$(printf '%s\n' "$NET_REGION" | grep -o 'index_of(code, "[^"]*")' | cksum)"
TOKENS_EXPECT="295864682 707"
if [ "$TOKENS_CKSUM" = "$TOKENS_EXPECT" ]; then
  ok "the C27 token list matches the frozen digest (25 tokens across the four surfaces)"
else
  bad "the C27 token list changed (cksum '$TOKENS_CKSUM', expected '$TOKENS_EXPECT') — widening the net after a measurement is tuning on the test set; re-baseline only as a deliberate, stated decision"
fi

# The diagnostic is emitted ONLY WHEN THE NET FIRES, so a zone the net is silent on produces byte-identical
# mapper output to before this change.
note "15) the VARIANT-COVERAGE| diagnostic is emitted only when the net fires ..."
if grep -q '^if contains_variant_coverage_signal(code) { print("VARIANT-COVERAGE|" + zoneId + "|true"); }$' "$MAPPER"; then
  ok "the VARIANT-COVERAGE| line is guarded by contains_variant_coverage_signal() (silent zones keep byte-identical output)"
else
  bad "the VARIANT-COVERAGE| diagnostic is no longer gated on the net firing — a silent zone's mapper output is no longer byte-identical"
fi

# Chain order: the C27 backstop runs AFTER the C26 net and BEFORE apply_fitness_reorder, so a forced C27 is
# still fitness-ranked like every other forced class (and never lands outside the reordered CSV).
note "16) apply_variant_coverage_backstop is chained after the C26 backstop and before the fitness reorder ..."
if awk '/fn apply_backstop/{f=1} f&&/apply_admitted_param_backstop\(/{a=NR} f&&/apply_variant_coverage_backstop\(/{v=NR} f&&/apply_fitness_reorder\(/{print (a&&v&&a<v&&v<NR) ? "ok" : "no"; exit}' "$MAPPER" | grep -q '^ok$'; then
  ok "apply_variant_coverage_backstop sits between apply_admitted_param_backstop and apply_fitness_reorder"
else
  bad "apply_variant_coverage_backstop is not chained between the C26 backstop and the fitness reorder"
fi
if grep -q 'let reordered = apply_fitness_reorder(withVariantCoverage);' "$MAPPER"; then
  ok "apply_fitness_reorder consumes the post-C27 class set"
else
  bad "apply_fitness_reorder no longer consumes the post-C27 class set (the forced C27 would be dropped)"
fi

note "17) the C27 detection rule is ONLY-WHEN shaped and carries its do-NOT-add escape ..."
# The instruction is a multi-line `"..." + "..."` concatenation, so a sentence can straddle two source lines.
# Slice the PROMPT region (`let instruction =` .. the `prompt(` call) and flatten the string joins, so every
# assertion below is about the text the model actually receives — never about the file's comments.
MAPPER_FLAT="$(awk '/^let instruction =/{f=1} f{print} /let verdict = prompt\(/{exit}' "$MAPPER" \
  | tr '\n' ' ' | sed 's/"[[:space:]]*+[[:space:]]*"//g')"
rule_hit=1
case "$MAPPER_FLAT" in *"VARIANT COVERAGE GAP DETECTION RULE (C27)"*) ;; *) rule_hit=0 ;; esac
case "$MAPPER_FLAT" in *"INCLUDE \`C27\` (variant coverage gap) ONLY WHEN"*) ;; *) rule_hit=0 ;; esac
case "$MAPPER_FLAT" in *"do NOT add C27"*) ;; *) rule_hit=0 ;; esac
case "$MAPPER_FLAT" in *"LIFECYCLE STATE"*) ;; *) rule_hit=0 ;; esac
if [ "$rule_hit" -eq 1 ]; then
  ok "zone-mapper.ag has the C27 detection rule, its ONLY-WHEN gate, the lifecycle-enum escape and its 'do NOT add C27' clause"
else
  bad "zone-mapper.ag missing the C27 detection rule, its ONLY-WHEN gate, the lifecycle-enum escape or its 'do NOT add C27' clause"
fi
# The rule must stay a CLASS description: no fixture name, no corpus marker may leak into the prompt.
if printf '%s' "$MAPPER_FLAT" | grep -qiE 'kinddispatchpool|rebasingawarevault|probedhookrouter|lifecycleescrow|kindregistry|corpus-bench'; then
  bad "a fixture/corpus identifier leaked into the zone-mapper PROMPT — the detection rules must describe the CLASS, never the rows they were derived from"
else
  ok "no fixture/corpus identifier appears in the zone-mapper prompt (the rules describe classes, not the corpus)"
fi
# The net helper names and the diagnostic are POST-classification machinery: they must never reach the prompt.
if printf '%s' "$MAPPER_FLAT" | grep -qE 'variant_coverage|variant_enum_ref|variant_type_flag|interface_probe|variant_consumer_path|VARIANT-COVERAGE\|'; then
  bad "a C27 net helper / diagnostic name leaked into the zone-mapper PROMPT (the net is post-classification only)"
else
  ok "no C27 net helper or diagnostic name appears in the zone-mapper prompt (the net stays post-classification only)"
fi
if grep -q 'pick the 1-4 that genuinely fit' "$MAPPER"; then
  ok "zone-mapper.ag still caps the LLM class list at 1-4 per zone (#1830 cell-budget guard)"
else
  bad "the 'pick the 1-4 that genuinely fit' class-count cap is gone (cell-budget regression)"
fi

# ----------------------------------------------------------------------------------------------------------
# (f) BEHAVIOUR, offline and WITHOUT an LLM. The mock backend's reply carries no ZONE| sentinel, so
#     apply_backstop()'s append is unreachable through a real zone run — this drives the REAL, shipped
#     apply_backstop() over five Solidity fixtures instead, exactly the probe idiom demo-map-zones.sh uses.
#     Pins: (1) each TRUE fixture (one per discriminator surface) forces C27 exactly once, appended as ONE
#           new trailing ZONE| line;
#           (2) both FALSE fixtures leave the verdict BYTE-IDENTICAL (no C27, no appended line, no diagnostic);
#           (3) a zone already carrying C27 gets no duplicate.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — skipping the apply_backstop() C27 behaviour probe (source guards above still ran)"
else
  note "18) apply_backstop() C27 behaviour over TRUE/TRUE/TRUE/FALSE/FALSE/DUP fixtures (real .ag functions, no LLM) ..."
  FIX="$WORK/fixtures"
  mkdir -p "$FIX"

  # TRUE #1 — ENUM-MEMBER discriminator, MISSING-BRANCH direction. The entry path handles every member of
  # the pool-kind enum; the exit path handles fewer and falls through, so the unhandled kind pays out zero.
  cat > "$FIX/KindDispatchPool.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

enum PoolKind { Stable, Weighted, Native }

contract KindDispatchPool {
    mapping(address => PoolKind) public kindOf;
    mapping(address => uint256) public held;

    function deposit(address pool, uint256 amount) external {
        PoolKind k = kindOf[pool];
        if (k == PoolKind.Stable) {
            held[pool] += amount;
        } else if (k == PoolKind.Weighted) {
            held[pool] += amount;
        } else if (k == PoolKind.Native) {
            held[pool] += amount;
        } else {
            revert("unknown kind");
        }
    }

    function withdraw(address pool, uint256 amount) external returns (uint256 out) {
        PoolKind k = kindOf[pool];
        if (k == PoolKind.Stable) {
            out = amount;
        } else if (k == PoolKind.Weighted) {
            out = amount;
        }
    }
}
SOL

  # TRUE #2 — TYPE-FLAG discriminator, BASIC-VARIANT direction. A per-asset rebasing flag is recorded at
  # registration, while redeem pays the recorded amount as if nothing rebased.
  cat > "$FIX/RebasingAwareVault.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract RebasingAwareVault {
    struct AssetConfig {
        bool listed;
        bool isRebasing;
    }

    mapping(address => AssetConfig) public configOf;
    mapping(address => mapping(address => uint256)) public recorded;

    function register(address asset, bool rebasing) external {
        configOf[asset] = AssetConfig({listed: true, isRebasing: rebasing});
    }

    function redeem(address asset, uint256 amount) external returns (uint256) {
        require(configOf[asset].listed, "unlisted");
        uint256 owed = recorded[asset][msg.sender];
        require(owed >= amount, "too much");
        recorded[asset][msg.sender] = owed - amount;
        return amount;
    }
}
SOL

  # TRUE #3 — INTERFACE-PROBE discriminator, MISSING-BRANCH direction. The registry admits a hook when the
  # ERC-165 probe returns true for EITHER of two interface ids, while the route path only speaks the first.
  cat > "$FIX/ProbedHookRouter.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC165Like {
    function supportsInterface(bytes4 id) external view returns (bool);
}

interface IHookA {
    function beforeRoute(address sender, uint256 amount) external returns (uint256);
}

contract ProbedHookRouter {
    bytes4 public constant HOOK_A_ID = 0x11111111;
    bytes4 public constant HOOK_B_ID = 0x22222222;

    mapping(address => bool) public hookAllowed;

    function registerHook(address hook) external {
        bool a = IERC165Like(hook).supportsInterface(HOOK_A_ID);
        bool b = IERC165Like(hook).supportsInterface(HOOK_B_ID);
        require(a || b, "unsupported hook");
        hookAllowed[hook] = true;
    }

    function swapWithHook(address hook, uint256 amount) external returns (uint256) {
        require(hookAllowed[hook], "not allowed");
        return IHookA(hook).beforeRoute(msg.sender, amount);
    }
}
SOL

  # FALSE #1 — a LIFECYCLE enum gates a value path. Open/settled is a state machine, not a variant axis of a
  # configurable thing; none of the discriminator surfaces is present, so the verdict must stay byte-identical.
  # NB it must trip no SIBLING net either (no deduction, no external call, no narrow cast, no role gate), so
  # that any change in the verdict can only come from C27.
  cat > "$FIX/LifecycleEscrow.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract LifecycleEscrow {
    enum Status { Open, Settled }

    mapping(uint256 => Status) public statusOf;
    mapping(uint256 => uint256) public amountOf;
    mapping(address => uint256) public credit;

    function open(uint256 id, uint256 amount) external {
        statusOf[id] = Status.Open;
        amountOf[id] = amount;
    }

    function settle(uint256 id) external {
        require(statusOf[id] == Status.Open, "not open");
        statusOf[id] = Status.Settled;
    }

    function withdraw(uint256 id) external returns (uint256) {
        require(statusOf[id] == Status.Settled, "not settled");
        uint256 amt = amountOf[id];
        amountOf[id] = 0;
        credit[msg.sender] += amt;
        return amt;
    }
}
SOL

  # FALSE #2 — the discriminator WITHOUT a value path. A registry validates and stores a kind enum and
  # exposes getters only; this proves the AND. The consumer tokens are bare substrings, so they are kept out
  # of this fixture's identifiers AND comments.
  cat > "$FIX/KindRegistry.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

enum MarketKind { Spot, Perp }

contract KindRegistry {
    address public owner;
    mapping(address => MarketKind) public kindOf;
    mapping(address => bool) public listed;

    constructor() {
        owner = msg.sender;
    }

    function register(address market, MarketKind kind) external {
        require(msg.sender == owner, "not owner");
        require(kind == MarketKind.Spot || kind == MarketKind.Perp, "bad kind");
        kindOf[market] = kind;
        listed[market] = true;
    }

    function isSpot(address market) external view returns (bool) {
        return listed[market] && kindOf[market] == MarketKind.Spot;
    }
}
SOL

  PROBE="$WORK/probe"
  mkdir -p "$PROBE"
  awk '/^let dir = getenv\("TARGET_DIR"\);/{exit} {print}' "$MAPPER" > "$PROBE/backstop-probe.ag"
  # The fixtures are real Solidity files (readable, reviewable); the probe consumes them as .ag string
  # literals, because cat_file() inside the mapper's scoped_code() needs a capability the probe deliberately
  # does not grant. flatten() escapes backslashes + double quotes and joins the file onto one line, which is
  # exactly the blob shape apply_backstop() is handed in production (`code` is a concatenation, never parsed).
  flatten() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$1" | tr '\n' ' '; }
  {
    echo '// #2265 probe tail (demo-variant-coverage-lens.sh): drive the SHIPPED apply_backstop() over five'
    echo '// fixtures. Three carry the C27 shape (one per discriminator surface) and must force it exactly once;'
    echo '// two do not (a lifecycle enum; a discriminator with no value path) and must stay byte-identical.'
    echo "let vcEnum = \"$(flatten "$FIX/KindDispatchPool.sol")\";"
    echo "let vcFlag = \"$(flatten "$FIX/RebasingAwareVault.sol")\";"
    echo "let vcProbe = \"$(flatten "$FIX/ProbedHookRouter.sol")\";"
    echo "let vcLife = \"$(flatten "$FIX/LifecycleEscrow.sol")\";"
    echo "let vcReg = \"$(flatten "$FIX/KindRegistry.sol")\";"
  } >> "$PROBE/backstop-probe.ag"
  cat >> "$PROBE/backstop-probe.ag" <<'AG'
print("VC-T1|" + apply_backstop("ZONE|venum|Pool|C7|why", vcEnum));
print("VC-T2|" + apply_backstop("ZONE|vflag|Vault|C7|why", vcFlag));
print("VC-T3|" + apply_backstop("ZONE|vprobe|Router|C7|why", vcProbe));
print("VC-T4|" + apply_backstop("ZONE|vlife|Escrow|C7|why", vcLife));
print("VC-T5|" + apply_backstop("ZONE|vreg|Registry|C7|why", vcReg));
print("VC-T6|" + apply_backstop("ZONE|vdup|Pool|C27,C7|why", vcEnum));
// The shipped emit shape, replayed: the diagnostic exists ONLY when the net fires.
if contains_variant_coverage_signal(vcEnum) { print("VC-DIAG|venum|true"); }
if contains_variant_coverage_signal(vcFlag) { print("VC-DIAG|vflag|true"); }
if contains_variant_coverage_signal(vcProbe) { print("VC-DIAG|vprobe|true"); }
if contains_variant_coverage_signal(vcLife) { print("VC-DIAG|vlife|true"); }
if contains_variant_coverage_signal(vcReg) { print("VC-DIAG|vreg|true"); }
AG
  ( cd "$PROBE" && agentis init >/dev/null 2>&1 ) || true
  # knowledge.enabled: apply_fitness_reorder() calls query_knowledge("hunt-fitness"); nothing is imported here,
  # so the reorder stays an identity and the CSV order below is the backstop's own.
  printf 'llm.backend = mock\nlearning.enabled = true\nexperience.enabled = true\nknowledge.enabled = true\n' > "$PROBE/.agentis/config"
  ( cd "$PROBE" && agentis go backstop-probe.ag ) > "$PROBE/probe.log" 2>&1
  VC_RC=$?
  # "C27 exactly once" — count C27 in the CLASS CSV field only (field 4 of the rebuilt `ZONE|` line).
  c27_count() { printf '%s\n' "$1" | awk -F'|' '{print $4}' | tr ',' '\n' | grep -c '^C27$'; }
  # Each print() emits the (possibly two-line) verdict; take the tag line and the line after it.
  tag_next() { awk -v t="^$1\\\\|" '$0 ~ t {getline; print; exit}' "$PROBE/probe.log"; }
  tag_line() { awk -v t="^$1\\\\|" '$0 ~ t {print; exit}' "$PROBE/probe.log"; }
  if [ "$VC_RC" -ne 0 ]; then
    bad "the apply_backstop() probe did not run (exit $VC_RC)"
    sed 's/^/      /' "$PROBE/probe.log" | head -20 >&2
  else
    for spec in "VC-T1:venum:Pool:enum-member discriminator (missing branch)" \
                "VC-T2:vflag:Vault:type-flag discriminator (basic-variant handling)" \
                "VC-T3:vprobe:Router:interface-probe discriminator (missing branch)"; do
      tag="${spec%%:*}"; rest="${spec#*:}"; zid="${rest%%:*}"; rest="${rest#*:}"; zname="${rest%%:*}"; label="${rest#*:}"
      nxt="$(tag_next "$tag")"
      case "$nxt" in
        "ZONE|$zid|$zname|"*"C27"*"|why")
          if [ "$(c27_count "$nxt")" -eq 1 ]; then
            ok "TRUE ($label): forces C27 exactly once (appended line '$nxt')"
          else
            bad "TRUE ($label): C27 appears $(c27_count "$nxt") times in '$nxt'"
          fi ;;
        *)
          bad "TRUE ($label): the appended line does not carry C27, got '$nxt'" ;;
      esac
    done
    # "no appended line" = the line after the tag is the NEXT tag, not a rebuilt `ZONE|` line.
    for spec in "VC-T4:ZONE|vlife|Escrow|C7|why:a lifecycle-status enum gating a value path" \
                "VC-T5:ZONE|vreg|Registry|C7|why:a stored kind enum with getters only (no value path)" \
                "VC-T6:ZONE|vdup|Pool|C27,C7|why:a zone that ALREADY carries C27 (force_include dedupe)"; do
      tag="${spec%%:*}"; rest="${spec#*:}"; want="${rest%%:*}"; label="${rest#*:}"
      line="$(tag_line "$tag")"; nxt="$(tag_next "$tag")"
      appended=0
      case "$nxt" in "ZONE|"*) appended=1 ;; esac
      if [ "$line" = "$tag|$want" ] && [ "$appended" -eq 0 ]; then
        ok "FALSE/DUP ($label): apply_backstop() returns the verdict BYTE-IDENTICAL (no added C27, no appended line)"
      else
        bad "FALSE/DUP ($label): the verdict was not byte-identical (got '$line' + next '$nxt')"
      fi
    done
    VC_DIAG="$(grep -c '^VC-DIAG|' "$PROBE/probe.log")"
    if grep -q '^VC-DIAG|venum|true$' "$PROBE/probe.log" \
       && grep -q '^VC-DIAG|vflag|true$' "$PROBE/probe.log" \
       && grep -q '^VC-DIAG|vprobe|true$' "$PROBE/probe.log" \
       && ! grep -q '^VC-DIAG|vlife|' "$PROBE/probe.log" \
       && ! grep -q '^VC-DIAG|vreg|' "$PROBE/probe.log" \
       && [ "$VC_DIAG" -eq 3 ]; then
      ok "the diagnostic is emitted for the three TRUE fixtures and for NEITHER FALSE one (exactly 3 lines)"
    else
      bad "diagnostic conditionality regressed (expected 3 lines, venum+vflag+vprobe only; got $VC_DIAG)"
      grep '^VC-DIAG|' "$PROBE/probe.log" | sed 's/^/      /' >&2
    fi
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the C27 variant-coverage lens (guarded class text + deterministic zone-mapper route + fixture behaviour) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
