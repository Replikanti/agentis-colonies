#!/usr/bin/env bash
# demo-admitted-param-lens.sh — OFFLINE, DETERMINISTIC gate for the ADMITTED-PARAMETER lens (#2245,
# iteration 4): one new bug class, C26, for the shape where a value the design CONSTRAINS is admitted from
# outside the function that consumes it and is never checked there:
#
#   C26 — Admitted parameter / unenforced bound:
#         (a) UNENFORCED BOUND / UNCHECKED ADMITTED VALUE — a caller- or non-owner-role-supplied parameter
#             (a route/set id, a minimum-out, a deadline, a slippage limit) is forwarded into an external
#             call or written into config with no `require` and no lookup on it IN THAT FUNCTION;
#         (b) UNVALIDATED COMBINATION — two individually valid configuration choices (an asset
#             representation and a pool/route type) are accepted separately and never validated as a PAIR,
#             so a valid-looking setup reaches a path that assumes the other choice.
#
# The lens IS the taxonomy section (hunter.ag slices `## <cls> ` out of auditor/bug-taxonomy.md and builds
# the cell prompt from it) plus a deterministic zone-mapper route. hunter.ag is NOT touched — a pure-meta
# directive block in the hunter is the shape that measured Delta=+0 (#2213), and it cannot be routed per
# zone. So this demo guards BOTH halves, the text and the behaviour:
#   1. the ANTI-CATCH-ALL contract — C26 carries its `NOT this class` list (naming the neighbours it must
#      not absorb, C23 first of all), its FOUR-part required-evidence rule, both named directions and the
#      four-step hunt. A class whose hunt collapses to "check every parameter" fires everywhere and burns
#      the cell budget (#1830).
#   2. the `class_section()` EXTRACTION anchor — hunter.ag slices with `index($0,"## "c" ")==1`, so `C2`
#      must not swallow `C26` and the `C25` slice must stop before `## C26`. Run against the REAL taxonomy.
#   3. the DELIBERATE non-changes — no `C26`/`admitted_param` token in hunter.ag, no `class_to_keyword()`
#      entry in invariant-prover.ag, the `DF_TIER2_RARE_CLASSES` default untouched, and C23's section
#      byte-unchanged (C26 is C23 INVERTED — admitted vs hardcoded — and must not be shipped by widening
#      C23's prompt text, which earlier arms were measured with).
#   4. the zone-mapper ROUTE, source-guarded AND exercised: the four surfaces, the AND, the force-include,
#      the chain position, the gated diagnostic, prompt purity, the TOKEN-PROVENANCE contract (every token
#      is dev-attested or already in this repo's own C23/C12 class text; none of the rejected held-out-only
#      candidates is present) — and, when agentis is present, a REAL, LLM-FREE probe of the shipped
#      `apply_backstop()` over four fixtures.
#
# This demo proves the MACHINERY and the TEXT, never the capability: whether C26 recovers a rare row is the
# held-out measurement on the frozen bases (an operator step, not CI).
#
# Usage:  dark-factory/demo-admitted-param-lens.sh
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

FAILS=0
note() { echo "demo-admitted-param-lens.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$TAXONOMY" ]  || { note "bug-taxonomy.md not found: $TAXONOMY" >&2; exit 3; }
[ -f "$MAPPER" ]    || { note "zone-mapper.ag not found: $MAPPER" >&2; exit 3; }
[ -f "$HUNTER" ]    || { note "hunter.ag not found: $HUNTER" >&2; exit 3; }
[ -f "$PROVER" ]    || { note "invariant-prover.ag not found: $PROVER" >&2; exit 3; }
[ -f "$DISCOVERY" ] || { note "run-discovery.sh not found: $DISCOVERY" >&2; exit 3; }

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
# (a) The taxonomy declares C26 as a top-level section (what class_section() anchors on).
# ----------------------------------------------------------------------------------------------------------
note "1) bug-taxonomy.md declares the C26 class header ..."
if grep -q '^## C26 ' "$TAXONOMY"; then
  ok "bug-taxonomy.md declares the '## C26 ' class header"
else
  bad "bug-taxonomy.md missing the '## C26 ' class header"
fi

# ----------------------------------------------------------------------------------------------------------
# (b) ANTI-CATCH-ALL contract: the guard headers, the FOUR-part evidence rule, the enumerate instruction.
# ----------------------------------------------------------------------------------------------------------
note "2) C26 carries its NOT-this-class + four-part required-evidence guards and the enumeration instruction ..."
C26="$(class_section C26)"
miss=""
case "$C26" in *"**NOT this class:**"*) ;; *) miss="$miss [NOT this class]" ;; esac
case "$C26" in *"**required evidence (else report SAFE):**"*) ;; *) miss="$miss [required evidence]" ;; esac
case "$C26" in *"enumerate, do not intuit"*) ;; *) miss="$miss [enumerate, do not intuit]" ;; esac
case "$C26" in *"(i)"*) ;; *) miss="$miss [(i)]" ;; esac
case "$C26" in *"(ii)"*) ;; *) miss="$miss [(ii)]" ;; esac
case "$C26" in *"(iii)"*) ;; *) miss="$miss [(iii)]" ;; esac
case "$C26" in *"(iv)"*) ;; *) miss="$miss [(iv)]" ;; esac
if [ -z "$miss" ]; then
  ok "C26 carries NOT-this-class, the FOUR-part required-evidence contract, and the enumeration instruction"
else
  bad "C26 is missing its anti-catch-all guards:$miss"
fi

# The NOT-this-class list must NAME the neighbour classes C26 would otherwise absorb. Without them the class
# degenerates into "check every parameter everywhere" and re-labels work the other lenses already do. C23 is
# the load-bearing one: it is the exact INVERSE case (the wrong value is a literal IN the code).
note "3) the NOT-this-class list names every neighbour class C26 must not absorb ..."
nb_miss=""
for k in C23 C12 C5 C22 C24 C25 C19; do
  case "$C26" in *"($k"*|*"(**$k"*) ;; *) nb_miss="$nb_miss [$k]" ;; esac
done
if [ -z "$nb_miss" ]; then
  ok "C26 disambiguates itself against C23/C12/C5/C22/C24/C25/C19"
else
  bad "C26's NOT-this-class list lost a neighbour class:$nb_miss"
fi

# Both DIRECTIONS and the four-step hunt: the class is a DOMAIN description, and these names are what keep it
# from collapsing into a "be more thorough" meta-directive (the measured null shape).
note "4) both directions and the four-step hunt survive ..."
sh_miss=""
for k in "unenforced bound" "unvalidated combination" "LIST THE ADMITTED VALUES" "FIND THE ENFORCEMENT" \
         "CROSS THE TWO CONFIG AXES" "WHO PAYS"; do
  case "$C26" in *"$k"*) ;; *) sh_miss="$sh_miss [$k]" ;; esac
done
if [ -z "$sh_miss" ]; then
  ok "C26 names both directions (unenforced bound / unvalidated combination) and all four hunt steps"
else
  bad "C26 lost a direction or a hunt step:$sh_miss"
fi

# The hunt must ask for the named, countable artefacts — the enforcement has to be IN THE SAME FUNCTION, an
# off-chain or documentary check is explicitly NOT enforcement, and the config grid has to be written out.
note "5) the hunt enumerates the NAMED artefacts (same-function enforcement, the non-enforcement escape, the grid) ..."
h_miss=""
for k in "IN THE SAME FUNCTION" "is NOT enforcement" "small grid" "admitted set"; do
  case "$C26" in *"$k"*) ;; *) h_miss="$h_miss [$k]" ;; esac
done
if [ -z "$h_miss" ]; then
  ok "C26's hunt demands same-function enforcement, rejects off-chain/documentary checks, and asks for the config grid"
else
  bad "C26 hunt lost an enumeration target:$h_miss"
fi

# The two lint rules the #2231/#2233 guard applies to every prompt-visible file, asserted here on the class
# text itself so a future edit of THIS section cannot reintroduce corpus ground truth into the lens.
note "6) the C26 class text is free of corpus ground truth (the #2231/#2233 rules, applied to this section) ..."
gt_bad=0
case "$C26" in *"corpus-bench"*) gt_bad=1 ;; esac
if printf '%s\n' "$C26" | grep -qE '(^|[^[:alnum:]_])[HM]-[0-9]{1,2}([^[:alnum:]_]|$)'; then gt_bad=1; fi
if [ "$gt_bad" -eq 0 ]; then
  ok "the C26 section carries no 'corpus-bench' literal and no contest GT finding id"
else
  bad "the C26 section carries corpus ground truth — the lens must describe the CODE SHAPE, never the rows it was scored on"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) EXTRACTION PIN: hunter.ag's `## <cls> ` awk anchor over the REAL taxonomy. C2 must not swallow C26, and
#     the C25 slice must stop before `## C26` (the prefix/adjacency risk this change adds).
# ----------------------------------------------------------------------------------------------------------
note "7) class_section() extraction pin: C2 / C25 / C26 slice cleanly ..."
# shellcheck disable=SC2016  # matched VERBATIM against hunter.ag's source (an awk anchor inside an exec-sh string)
if grep -qF 'index($0,\"## \"c\" \")==1' "$HUNTER"; then
  ok "hunter.ag still slices the taxonomy with the '## <cls> ' anchor this test replicates"
else
  bad "hunter.ag's class_section() anchor changed — this extraction pin no longer guards the real code path"
fi
for c in C2 C25 C26; do
  if [ -n "$(class_section "$c")" ]; then
    ok "class_section($c) returns a non-empty slice"
  else
    bad "class_section($c) returned an EMPTY slice — the class is unreachable from hunter.ag"
  fi
done
case "$(class_section C2)" in
  *"## C26"*) bad "the C2 slice swallowed the C26 section (prefix collision)" ;;
  *) ok "the C2 slice does not contain '## C26' (C2's own lens is intact)" ;;
esac
case "$(class_section C25)" in
  *"## C26"*) bad "the C25 slice ran past its own section into C26" ;;
  *) ok "the C25 slice stops before '## C26'" ;;
esac
case "$C26" in
  *"## C25"*) bad "the C26 slice ran backwards into C25" ;;
  *) ok "the C26 slice contains only its own class text" ;;
esac

# The routing note hunter/zone-mapper authors read first must mention C26, else the class is invisible to a
# human extending the taxonomy.
note "8) the Hunter usage notes route an admitted-parameter zone to C26 ..."
if grep -q 'in one path → C26' "$TAXONOMY"; then
  ok "the Hunter usage notes carry the C26 routing clause"
else
  bad "the Hunter usage notes lost the C26 routing clause"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) The DELIBERATE non-changes, pinned as decisions rather than omissions.
# ----------------------------------------------------------------------------------------------------------
note "9) deliberate non-changes: hunter.ag untouched, no class_to_keyword() entry, tier-2 default untouched ..."
if grep -qE 'C26|admitted_param' "$HUNTER"; then
  bad "hunter.ag gained a C26 / admitted_param token — the lens is the taxonomy section, not a hunter directive block (the pure-meta shape measured Delta=+0)"
else
  ok "hunter.ag carries no C26 / admitted_param token (the class reaches the cell through the taxonomy menu only)"
fi
if grep -q 'class_to_keyword' "$PROVER"; then
  if grep -qE 'class_is\(k, "c26"\)' "$PROVER"; then
    bad "invariant-prover.ag gained a class_to_keyword() entry for C26 — that re-routes the depth/metamorphic action menu, an unmeasured second variable (C22/C23/C24/C25 have no entry either)"
  else
    ok "invariant-prover.ag's class_to_keyword() has no C26 entry (C26 falls through to the generic default, like C22/C23/C24/C25)"
  fi
else
  bad "invariant-prover.ag no longer defines class_to_keyword() — this decision pin no longer guards anything"
fi
# C26 is a ROUTED class, not a tier-2 promotion: the rare-class priority list is a second variable and stays
# exactly as #2217 shipped it (C25 was held out of it for the same reason).
if grep -q 'DF_TIER2_RARE_CLASSES:-C19,C20,C21,C22,C23,C24}' "$DISCOVERY"; then
  ok "run-discovery.sh's DF_TIER2_RARE_CLASSES default is unchanged (C26 is routed, not tier-2 promoted)"
else
  bad "run-discovery.sh's DF_TIER2_RARE_CLASSES default changed — C26 must not enter the rare-class priority list in this iteration"
fi

# C23 is the INVERSE class (a literal hardcoded IN the code). Shipping C26 by widening C23 would mutate a
# prompt string the earlier measurement arms were scored with, so C23's section is pinned byte-for-byte.
# NB: if C23 is ever deliberately revised, re-baseline this digest IN THE SAME COMMIT and say so there.
note "10) C23's section is byte-unchanged (C26 is not shipped by widening its inverse) ..."
C23_CKSUM="$(class_section C23 | cksum)"
C23_EXPECT="2054321986 2710"
if [ "$C23_CKSUM" = "$C23_EXPECT" ]; then
  ok "the C23 section is byte-identical to the text the earlier arms were measured with"
else
  bad "the C23 section changed (cksum '$C23_CKSUM', expected '$C23_EXPECT') — C26 must not be implemented by editing C23"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) The zone-mapper ROUTE: the deterministic net, its force-include, the diagnostic, the chain order, the
#     ONLY-WHEN-shaped detection rule with its escape clause, and the TOKEN-PROVENANCE contract.
# ----------------------------------------------------------------------------------------------------------
note "11) zone-mapper.ag carries the deterministic C26 net, its force-include and the ADMITTED-PARAM| diagnostic ..."
net_miss=""
for f in has_admitted_route_param has_asset_type_selector has_admitted_bound_param has_nonowner_admission \
         contains_admitted_param_signal apply_admitted_param_backstop; do
  grep -q "fn $f" "$MAPPER" || net_miss="$net_miss [$f]"
done
grep -q 'force_include(classesCsv, "C26")' "$MAPPER" || net_miss="$net_miss [force_include C26]"
grep -q '"ADMITTED-PARAM|"' "$MAPPER" || net_miss="$net_miss [ADMITTED-PARAM| diagnostic]"
if [ -z "$net_miss" ]; then
  ok "zone-mapper.ag defines the four C26 surfaces, contains_admitted_param_signal, apply_admitted_param_backstop -> force_include C26, and the ADMITTED-PARAM| line"
else
  bad "zone-mapper.ag is missing part of the #2245 iteration-4 C26 route:$net_miss"
fi

# The AND composition, asserted on the source: the admission surface is MANDATORY (an early return when it is
# absent) and each of the three value surfaces is sufficient on its own once admission holds. A net that ORs
# the admission surface in would fire on any contract naming a deadline.
note "12) the net's composition is (route OR asset OR bound) AND non-owner admission ..."
NET_BODY="$(awk '/^fn contains_admitted_param_signal/{f=1} f{print} f&&/^}/{exit}' "$MAPPER")"
comp_ok=1
case "$NET_BODY" in *"if !has_nonowner_admission(code) { return false; }"*) ;; *) comp_ok=0 ;; esac
case "$NET_BODY" in *"if has_admitted_route_param(code) { return true; }"*) ;; *) comp_ok=0 ;; esac
case "$NET_BODY" in *"if has_asset_type_selector(code) { return true; }"*) ;; *) comp_ok=0 ;; esac
case "$NET_BODY" in *"if has_admitted_bound_param(code) { return true; }"*) ;; *) comp_ok=0 ;; esac
if [ "$comp_ok" -eq 1 ]; then
  ok "contains_admitted_param_signal() requires the admission surface and accepts any one of the three value surfaces"
else
  bad "the C26 net composition changed — admission must be mandatory and each value surface sufficient"
fi

# TOKEN PROVENANCE (#2245 iteration-4 decision 1): the net is tuned on the DEV design zones plus vocabulary
# this repo's own C23/C12 class text already ships. Every token line therefore carries a (D)/(T) tag, and the
# candidates that were observable ONLY in held-out code are rejected and must never appear in the net.
note "13) token-provenance contract: every net token is tagged (D) or (T), no held-out-only token is present ..."
NET_REGION="$(awk '/^fn has_admitted_route_param/{f=1} f{print} f&&/^fn contains_admitted_param_signal/{g=1} g&&/^}/{exit}' "$MAPPER")"
untagged="$(printf '%s\n' "$NET_REGION" | grep 'index_of(code,' | grep -cv '// (')"
if [ "$untagged" -eq 0 ]; then
  ok "every index_of() token in the C26 net carries a (D)/(T) provenance tag"
else
  bad "$untagged token(s) in the C26 net have no provenance tag — a token must be dev-attested or already in this repo's class text"
  printf '%s\n' "$NET_REGION" | grep 'index_of(code,' | grep -v '// (' | sed 's/^/      /' >&2
fi
rej=""
for t in maxFee ttl dstChainId dstEid destinations Duration duration; do
  case "$NET_REGION" in *"\"$t\""*) rej="$rej [$t]" ;; esac
done
if [ -z "$rej" ]; then
  ok "none of the rejected held-out-only candidate tokens appears in the C26 net (no tuning on the test set)"
else
  bad "a rejected held-out-only token is back in the C26 net:$rej — widening the net to reach a held-out zone is tuning on the test set"
fi

# The diagnostic is emitted ONLY WHEN THE NET FIRES (unlike CROSS-UNIT|/STALE-STATE|, which print true/false
# unconditionally), so a zone the net is silent on produces byte-identical mapper output to before this change.
note "14) the ADMITTED-PARAM| diagnostic is emitted only when the net fires ..."
if grep -q '^if contains_admitted_param_signal(code) { print("ADMITTED-PARAM|" + zoneId + "|true"); }$' "$MAPPER"; then
  ok "the ADMITTED-PARAM| line is guarded by contains_admitted_param_signal() (silent zones keep byte-identical output)"
else
  bad "the ADMITTED-PARAM| diagnostic is no longer gated on the net firing — a silent zone's mapper output is no longer byte-identical"
fi

# Chain order: the C26 backstop runs AFTER the #2245 C25 net and BEFORE apply_fitness_reorder, so a forced
# C26 is still fitness-ranked like a forced C5/C8/C19/C22/C24/C25 (and never lands outside the reordered CSV).
note "15) apply_admitted_param_backstop is chained after the C25 backstop and before the fitness reorder ..."
if awk '/fn apply_backstop/{f=1} f&&/apply_zero_total_backstop\(/{z=NR} f&&/apply_admitted_param_backstop\(/{a=NR} f&&/apply_fitness_reorder\(/{print (z&&a&&z<a&&a<NR) ? "ok" : "no"; exit}' "$MAPPER" | grep -q '^ok$'; then
  ok "apply_admitted_param_backstop sits between apply_zero_total_backstop and apply_fitness_reorder"
else
  bad "apply_admitted_param_backstop is not chained between the C25 backstop and the fitness reorder"
fi

note "16) the C26 detection rule is ONLY-WHEN shaped and carries its do-NOT-add escape ..."
# The instruction is a multi-line `"..." + "..."` concatenation, so a sentence can straddle two source lines.
# Slice the PROMPT region (`let instruction =` .. the `prompt(` call) and flatten the string joins, so every
# assertion below is about the text the model actually receives — never about the file's comments.
MAPPER_FLAT="$(awk '/^let instruction =/{f=1} f{print} /let verdict = prompt\(/{exit}' "$MAPPER" \
  | tr '\n' ' ' | sed 's/"[[:space:]]*+[[:space:]]*"//g')"
rule_hit=1
case "$MAPPER_FLAT" in *"ADMITTED PARAMETER / UNENFORCED BOUND DETECTION RULE (C26)"*) ;; *) rule_hit=0 ;; esac
case "$MAPPER_FLAT" in *"INCLUDE \`C26\` (admitted parameter / unenforced bound) ONLY WHEN"*) ;; *) rule_hit=0 ;; esac
case "$MAPPER_FLAT" in *"do NOT add C26"*) ;; *) rule_hit=0 ;; esac
if [ "$rule_hit" -eq 1 ]; then
  ok "zone-mapper.ag has the C26 detection rule, its ONLY-WHEN gate and its 'do NOT add C26' escape clause"
else
  bad "zone-mapper.ag missing the C26 detection rule, its ONLY-WHEN gate or its 'do NOT add C26' escape clause"
fi
# The rule must stay a CLASS description: no target name, no fixture name, no ground-truth row id may leak
# into the prompt (that would make the measurement a memorisation test rather than a lens test).
if printf '%s' "$MAPPER_FLAT" | grep -qiE 'routedbounddispatch|pairedassetstrategy|ownerboundedfees|corpus-bench'; then
  bad "a fixture/corpus identifier leaked into the zone-mapper PROMPT — the detection rules must describe the CLASS, never the rows they were derived from"
else
  ok "no fixture/corpus identifier appears in the zone-mapper prompt (the rules describe classes, not the corpus)"
fi
# The net helper names are POST-classification machinery: they must never reach the prompt, or a zone on which
# the net does not fire would no longer get the byte-identical instruction its verdict was measured on.
if printf '%s' "$MAPPER_FLAT" | grep -qE 'admitted_param|nonowner_admission|ADMITTED-PARAM\|'; then
  bad "a C26 net helper name leaked into the zone-mapper PROMPT (the net is post-classification only)"
else
  ok "no C26 net helper name appears in the zone-mapper prompt (the net stays post-classification only)"
fi
if grep -q 'pick the 1-4 that genuinely fit' "$MAPPER"; then
  ok "zone-mapper.ag still caps the LLM class list at 1-4 per zone (#1830 cell-budget guard)"
else
  bad "the 'pick the 1-4 that genuinely fit' class-count cap is gone (cell-budget regression)"
fi

# ----------------------------------------------------------------------------------------------------------
# (f) BEHAVIOUR, offline and WITHOUT an LLM. The mock backend's reply carries no ZONE| sentinel, so
#     apply_backstop()'s append is unreachable through a real zone run — this drives the REAL, shipped
#     apply_backstop() over four Solidity fixtures instead, exactly the probe idiom demo-map-zones.sh uses.
#     Pins: (1) both TRUE fixtures force C26 exactly once, appended as ONE new trailing ZONE| line;
#           (2) the FALSE fixture leaves the verdict BYTE-IDENTICAL (no C26, no appended line, no diagnostic);
#           (3) a zone already carrying C26 gets no duplicate.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — skipping the apply_backstop() C26 behaviour probe (source guards above still ran)"
else
  note "17) apply_backstop() C26 behaviour over TRUE/TRUE/FALSE/DUP fixtures (real .ag functions, no LLM) ..."
  FIX="$WORK/fixtures"
  mkdir -p "$FIX"

  # TRUE #1 — the UNENFORCED BOUND direction. A role-gated entrypoint decodes a route id and a
  # minimum-out/deadline pair out of a caller-supplied `bytes` payload and forwards all three into an
  # external router with no `require` on any of them in that function: an in-role call picks a route the
  # design never admitted and terms the design never allowed.
  cat > "$FIX/RoutedBoundDispatch.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IRouter {
    function swapVia(uint16 dexId, uint256 amountIn, uint256 minOut, uint256 deadline) external;
}

contract RoutedBoundDispatch {
    struct TradeParams {
        uint16 dexId;
        uint256 minOut;
        uint256 deadline;
    }

    IRouter public router;
    address public rebalancer;

    modifier onlyRebalancer() {
        require(msg.sender == rebalancer, "not rebalancer");
        _;
    }

    function dispatch(uint256 amountIn, bytes calldata payload) external onlyRebalancer {
        TradeParams memory p = abi.decode(payload, (TradeParams));
        router.swapVia(p.dexId, amountIn, p.minOut, p.deadline);
    }
}
SOL

  # TRUE #2 — the UNVALIDATED COMBINATION direction. The asset representation and the pool type are written
  # by two separate role-gated setters and are never validated as a pair, so the wrapped-asset + native-pool
  # cell reaches a leg the code does not handle and the strategy cannot trade in a configuration the
  # protocol's own setters can reach.
  cat > "$FIX/PairedAssetStrategy.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface INativePool {
    function exchange(uint8 poolType, uint256 amount) external payable;
}

contract PairedAssetStrategy {
    address public constant ETH_ADDRESS = address(0);

    address public manager;
    address public asset;
    uint8 public poolType;
    bool public useEth;

    modifier onlyManager() {
        require(msg.sender == manager, "not manager");
        _;
    }

    function setAsset(address newAsset) external onlyManager {
        asset = newAsset;
    }

    function setPool(uint8 newPoolType) external onlyManager {
        poolType = newPoolType;
    }

    function trade(uint256 amount) external onlyManager {
        if (useEth) {
            INativePool(asset).exchange(poolType, amount);
        } else {
            INativePool(asset).exchange(poolType, amount);
        }
    }
}
SOL

  # FALSE — the near miss. Every value this contract consumes is either a literal it owns or an argument the
  # OWNER supplies and the SAME function bounds with a `require`; nothing is decoded from a caller payload
  # and no route id, asset-representation selector or external bound is named. There is no admitted value
  # here to leave unchecked.
  # NB this is a NEGATIVE CONTROL FOR THE ROUTE, and the route is a token net: the same contract written with
  # a role modifier and a decoded params struct would be routed. A route over-including is a cell; the class
  # rule in the prompt is what decides. What this control proves is the thing that matters for cost — merely
  # having a configurable number is not enough to pull the class in.
  cat > "$FIX/OwnerBoundedFees.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract OwnerBoundedFees {
    uint256 internal constant MAX_FEE_BPS = 500;

    address public owner;
    uint256 public feeBps;

    constructor() {
        owner = msg.sender;
        feeBps = 100;
    }

    function setFeeBps(uint256 newFeeBps) external {
        require(msg.sender == owner, "not owner");
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
    }

    function feeOn(uint256 amount) public view returns (uint256) {
        return (amount * feeBps) / 10000;
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
    echo '// #2245 iteration-4 probe tail (demo-admitted-param-lens.sh): drive the SHIPPED apply_backstop()'
    echo '// over three fixtures. Two carry the C26 shape and must force it exactly once; the third bounds'
    echo '// every value it owns inside an owner-only setter and must leave the verdict byte-identical.'
    echo "let apRoute = \"$(flatten "$FIX/RoutedBoundDispatch.sol")\";"
    echo "let apPair = \"$(flatten "$FIX/PairedAssetStrategy.sol")\";"
    echo "let apSafe = \"$(flatten "$FIX/OwnerBoundedFees.sol")\";"
  } >> "$PROBE/backstop-probe.ag"
  cat >> "$PROBE/backstop-probe.ag" <<'AG'
print("AP-T1|" + apply_backstop("ZONE|aroute|Dispatcher|C7|why", apRoute));
print("AP-T2|" + apply_backstop("ZONE|apair|Strategy|C7|why", apPair));
print("AP-T3|" + apply_backstop("ZONE|asafe|Fees|C7|why", apSafe));
print("AP-T4|" + apply_backstop("ZONE|adup|Dispatcher|C26,C7|why", apRoute));
// The shipped emit shape, replayed: the diagnostic exists ONLY when the net fires.
if contains_admitted_param_signal(apRoute) { print("AP-DIAG|aroute|true"); }
if contains_admitted_param_signal(apPair) { print("AP-DIAG|apair|true"); }
if contains_admitted_param_signal(apSafe) { print("AP-DIAG|asafe|true"); }
AG
  ( cd "$PROBE" && agentis init >/dev/null 2>&1 ) || true
  # knowledge.enabled: apply_fitness_reorder() calls query_knowledge("hunt-fitness"); nothing is imported here,
  # so the reorder stays an identity and the CSV order below is the backstop's own.
  printf 'llm.backend = mock\nlearning.enabled = true\nexperience.enabled = true\nknowledge.enabled = true\n' > "$PROBE/.agentis/config"
  ( cd "$PROBE" && agentis go backstop-probe.ag ) > "$PROBE/probe.log" 2>&1
  AP_RC=$?
  # Each print() emits the (possibly two-line) verdict; take the tag line and the line after it.
  AP_T1_NEXT="$(awk '/^AP-T1\|/{getline; print; exit}' "$PROBE/probe.log")"
  AP_T2_NEXT="$(awk '/^AP-T2\|/{getline; print; exit}' "$PROBE/probe.log")"
  AP_T3_LINE="$(awk '/^AP-T3\|/{print; exit}' "$PROBE/probe.log")"
  AP_T3_NEXT="$(awk '/^AP-T3\|/{getline; print; exit}' "$PROBE/probe.log")"
  AP_T4_LINE="$(awk '/^AP-T4\|/{print; exit}' "$PROBE/probe.log")"
  AP_T4_NEXT="$(awk '/^AP-T4\|/{getline; print; exit}' "$PROBE/probe.log")"
  # "C26 exactly once" — the forced class must be added, and added a single time.
  # Count C26 in the CLASS CSV field only (field 4 of the rebuilt `ZONE|` line), never in the whole line.
  c26_count() { printf '%s\n' "$1" | awk -F'|' '{print $4}' | tr ',' '\n' | grep -c '^C26$'; }
  if [ "$AP_RC" -ne 0 ]; then
    bad "the apply_backstop() probe did not run (exit $AP_RC)"
    sed 's/^/      /' "$PROBE/probe.log" | head -20 >&2
  else
    case "$AP_T1_NEXT" in
      "ZONE|aroute|Dispatcher|"*"C26"*"|why")
        if [ "$(c26_count "$AP_T1_NEXT")" -eq 1 ]; then
          ok "TRUE (unenforced bound): a role-gated decode forwarding a route id + bounds forces C26 exactly once (appended line '$AP_T1_NEXT')"
        else
          bad "TRUE (unenforced bound): C26 appears $(c26_count "$AP_T1_NEXT") times in '$AP_T1_NEXT'"
        fi ;;
      *)
        bad "TRUE (unenforced bound): the appended line does not carry C26, got '$AP_T1_NEXT'" ;;
    esac
    case "$AP_T2_NEXT" in
      "ZONE|apair|Strategy|"*"C26"*"|why")
        if [ "$(c26_count "$AP_T2_NEXT")" -eq 1 ]; then
          ok "TRUE (unvalidated combination): two independently-set config choices behind a non-owner role force C26 exactly once (appended line '$AP_T2_NEXT')"
        else
          bad "TRUE (unvalidated combination): C26 appears $(c26_count "$AP_T2_NEXT") times in '$AP_T2_NEXT'"
        fi ;;
      *)
        bad "TRUE (unvalidated combination): the appended line does not carry C26, got '$AP_T2_NEXT'" ;;
    esac
    # "no appended line" = the line after the tag is the NEXT tag, not a rebuilt `ZONE|` line.
    AP_T3_APPENDED=0
    case "$AP_T3_NEXT" in "ZONE|"*) AP_T3_APPENDED=1 ;; esac
    AP_T4_APPENDED=0
    case "$AP_T4_NEXT" in "ZONE|"*) AP_T4_APPENDED=1 ;; esac
    if [ "$AP_T3_LINE" = "AP-T3|ZONE|asafe|Fees|C7|why" ] && [ "$AP_T3_APPENDED" -eq 0 ]; then
      ok "FALSE: apply_backstop() returns the verdict BYTE-IDENTICAL when the C26 net does not fire (no C26, no appended line)"
    else
      bad "FALSE: the no-fire verdict was not byte-identical (got '$AP_T3_LINE' + next '$AP_T3_NEXT')"
    fi
    if [ "$AP_T4_LINE" = "AP-T4|ZONE|adup|Dispatcher|C26,C7|why" ] && [ "$AP_T4_APPENDED" -eq 0 ]; then
      ok "a zone that ALREADY carries C26 gets no duplicate (force_include dedupe, no appended line)"
    else
      bad "duplicate-C26 regression (got '$AP_T4_LINE' + next '$AP_T4_NEXT')"
    fi
    AP_DIAG="$(grep -c '^AP-DIAG|' "$PROBE/probe.log")"
    if grep -q '^AP-DIAG|aroute|true$' "$PROBE/probe.log" \
       && grep -q '^AP-DIAG|apair|true$' "$PROBE/probe.log" \
       && ! grep -q '^AP-DIAG|asafe|' "$PROBE/probe.log" \
       && [ "$AP_DIAG" -eq 2 ]; then
      ok "the diagnostic is emitted for both TRUE fixtures and for NEITHER the FALSE one (exactly 2 lines)"
    else
      bad "diagnostic conditionality regressed (expected 2 lines, aroute+apair only; got $AP_DIAG)"
      grep '^AP-DIAG|' "$PROBE/probe.log" | sed 's/^/      /' >&2
    fi
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the C26 admitted-parameter lens (guarded class text + deterministic zone-mapper route + fixture behaviour) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
