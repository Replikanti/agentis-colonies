#!/usr/bin/env bash
# demo-zero-total-lens.sh — OFFLINE, DETERMINISTIC gate for the ZERO-PARTICIPATION lens (#2245): one new bug
# class, C25, for the shape the held-out generation misses keep landing on — a path reads an aggregate
# PARTICIPATION TOTAL (a distribution pool's unit count, a totalSupply/effectiveSupply, a totalStaked) and
# mishandles the ZERO edge in one of two directions:
#
#   C25 — Empty distribution / zero participation edge:
#         (a) FALSE ZERO GATE   — a `require(total > 0)` blocks an ordinary user action on a leg whose share
#                                 of the flow is legitimately zero (its allocation weight is set to zero,
#                                 nobody ever subscribed), a state the protocol's own config surface reaches;
#         (b) FALSE NON-ZERO    — the total is floored by a virtual/minimum constant so it can never read
#                                 zero, the "no participants, stop distributing" branch is dead, and the
#                                 emission keeps accruing with no recipient.
#
# The lens IS the taxonomy section (hunter.ag slices `## <cls> ` out of auditor/bug-taxonomy.md and builds the
# cell prompt from it) plus a deterministic zone-mapper route. hunter.ag is NOT touched — a pure-meta directive
# block in the hunter is the shape that measured Delta=+0 (#2213), and it cannot be routed per zone. So this
# demo guards BOTH halves, the text and the behaviour:
#   1. the ANTI-CATCH-ALL contract — C25 carries its `NOT this class` list (naming the neighbours it must not
#      absorb), its FOUR-part required-evidence rule, both named directions and the three-part hunt. A class
#      whose hunt collapses to "check the empty case" fires everywhere and burns the cell budget (#1830).
#   2. the `class_section()` EXTRACTION anchor — hunter.ag slices with `index($0,"## "c" ")==1`, so `C2` must
#      not swallow `C25` and the `C24` slice must stop before `## C25`. Run against the REAL taxonomy file.
#   3. the two DELIBERATE non-changes — no `class_to_keyword()` entry for C25 in invariant-prover.ag (that map
#      routes the depth/metamorphic action menu, an unmeasured second variable; C22/C23/C24 have no entry
#      either) and no `C25`/`zero_total` token in hunter.ag.
#   4. the zone-mapper ROUTE, source-guarded AND exercised: the deterministic net, its force-include, the
#      ONLY-WHEN detection rule, prompt purity — and, when agentis is present, a REAL, LLM-FREE probe of the
#      shipped `apply_backstop()` over three fixtures (two TRUE, one FALSE).
#
# This demo proves the MACHINERY and the TEXT, never the capability: whether C25 recovers a rare row is the
# held-out measurement on the frozen bases (an operator step, not CI).
#
# Usage:  dark-factory/demo-zero-total-lens.sh
# Requires: awk + grep (the floor); agentis additionally enables the behavioural probe (skipped without it).
# Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TAXONOMY="$HERE/auditor/bug-taxonomy.md"
MAPPER="$HERE/auditor/agents/zone-mapper.ag"
HUNTER="$HERE/auditor/agents/hunter.ag"
PROVER="$HERE/auditor/agents/invariant-prover.ag"

FAILS=0
note() { echo "demo-zero-total-lens.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$TAXONOMY" ] || { note "bug-taxonomy.md not found: $TAXONOMY" >&2; exit 3; }
[ -f "$MAPPER" ]   || { note "zone-mapper.ag not found: $MAPPER" >&2; exit 3; }
[ -f "$HUNTER" ]   || { note "hunter.ag not found: $HUNTER" >&2; exit 3; }
[ -f "$PROVER" ]   || { note "invariant-prover.ag not found: $PROVER" >&2; exit 3; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# hunter.ag's own class_section() awk anchor, verbatim in shape: take the `## <cls> ` section and stop at the
# next `## ` header that is not this class.
class_section() {
  awk -v c="$1" 'index($0,"## "c" ")==1{f=1} f&&index($0,"## ")==1&&index($0,"## "c" ")!=1{exit} f{print}' \
    "$TAXONOMY" 2>/dev/null
}

# ----------------------------------------------------------------------------------------------------------
# (a) The taxonomy declares C25 as a top-level section (what class_section() anchors on).
# ----------------------------------------------------------------------------------------------------------
note "1) bug-taxonomy.md declares the C25 class header ..."
if grep -q '^## C25 ' "$TAXONOMY"; then
  ok "bug-taxonomy.md declares the '## C25 ' class header"
else
  bad "bug-taxonomy.md missing the '## C25 ' class header"
fi

# ----------------------------------------------------------------------------------------------------------
# (b) ANTI-CATCH-ALL contract: the guard headers, the FOUR-part evidence rule, the enumerate instruction.
# ----------------------------------------------------------------------------------------------------------
note "2) C25 carries its NOT-this-class + four-part required-evidence guards and the enumeration instruction ..."
C25="$(class_section C25)"
miss=""
case "$C25" in *"**NOT this class:**"*) ;; *) miss="$miss [NOT this class]" ;; esac
case "$C25" in *"**required evidence (else report SAFE):**"*) ;; *) miss="$miss [required evidence]" ;; esac
case "$C25" in *"enumerate, do not intuit"*) ;; *) miss="$miss [enumerate, do not intuit]" ;; esac
case "$C25" in *"(i)"*) ;; *) miss="$miss [(i)]" ;; esac
case "$C25" in *"(ii)"*) ;; *) miss="$miss [(ii)]" ;; esac
case "$C25" in *"(iii)"*) ;; *) miss="$miss [(iii)]" ;; esac
case "$C25" in *"(iv)"*) ;; *) miss="$miss [(iv)]" ;; esac
if [ -z "$miss" ]; then
  ok "C25 carries NOT-this-class, the FOUR-part required-evidence contract, and the enumeration instruction"
else
  bad "C25 is missing its anti-catch-all guards:$miss"
fi

# The NOT-this-class list must NAME the neighbour classes C25 would otherwise absorb. Without them the class
# degenerates into "check the empty case everywhere" and re-labels work the other lenses already do.
note "3) the NOT-this-class list names every neighbour class C25 must not absorb ..."
nb_miss=""
for k in C11 C1 C9 C6 C16 C19 C24; do
  case "$C25" in *"($k"*) ;; *) nb_miss="$nb_miss [$k]" ;; esac
done
if [ -z "$nb_miss" ]; then
  ok "C25 disambiguates itself against C11/C1/C9/C6/C16/C19/C24"
else
  bad "C25's NOT-this-class list lost a neighbour class:$nb_miss"
fi

# Both DIRECTIONS and the three-part hunt: the class is a DOMAIN description, and these names are what keep it
# from collapsing into a "be more thorough" meta-directive (the measured null shape).
note "4) both directions and the three-part hunt survive ..."
sh_miss=""
for k in "false zero gate" "false non-zero" "HOW ZERO IS REACHED" "WHAT THE PATH DOES AT ZERO" "WHO PAYS"; do
  case "$C25" in *"$k"*) ;; *) sh_miss="$sh_miss [$k]" ;; esac
done
if [ -z "$sh_miss" ]; then
  ok "C25 names both directions (false zero gate / false non-zero) and all three hunt steps"
else
  bad "C25 lost a direction or a hunt step:$sh_miss"
fi

# The hunt must ask for the named, countable artefacts — the reachable zero state and the setter that produces
# it, the floor constant that removes it, and the economic-vs-raw-count distinction that IS the bug.
note "5) the hunt enumerates the NAMED artefacts (reachable zero, floor constant, economic vs raw count) ..."
h_miss=""
for k in "NAME the setter" "UNREACHABLE" "RAW COUNT" "allocation"; do
  case "$C25" in *"$k"*) ;; *) h_miss="$h_miss [$k]" ;; esac
done
if [ -z "$h_miss" ]; then
  ok "C25's hunt enumerates the reachable-zero states + their setters, the floor constant, and the economic-vs-raw-count split"
else
  bad "C25 hunt lost an enumeration target:$h_miss"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) EXTRACTION PIN: hunter.ag's `## <cls> ` awk anchor over the REAL taxonomy. C2 must not swallow C25, and
#     the C24 slice must stop before `## C25` (the prefix/adjacency risk this change adds).
# ----------------------------------------------------------------------------------------------------------
note "6) class_section() extraction pin: C2 / C24 / C25 slice cleanly ..."
# shellcheck disable=SC2016  # matched VERBATIM against hunter.ag's source (an awk anchor inside an exec-sh string)
if grep -qF 'index($0,\"## \"c\" \")==1' "$HUNTER"; then
  ok "hunter.ag still slices the taxonomy with the '## <cls> ' anchor this test replicates"
else
  bad "hunter.ag's class_section() anchor changed — this extraction pin no longer guards the real code path"
fi
for c in C2 C24 C25; do
  if [ -n "$(class_section "$c")" ]; then
    ok "class_section($c) returns a non-empty slice"
  else
    bad "class_section($c) returned an EMPTY slice — the class is unreachable from hunter.ag"
  fi
done
case "$(class_section C2)" in
  *"## C25"*) bad "the C2 slice swallowed the C25 section (prefix collision)" ;;
  *) ok "the C2 slice does not contain '## C25' (C2's own lens is intact)" ;;
esac
case "$(class_section C24)" in
  *"## C25"*) bad "the C24 slice ran past its own section into C25" ;;
  *) ok "the C24 slice stops before '## C25'" ;;
esac
case "$C25" in
  *"## C24"*) bad "the C25 slice ran backwards into C24" ;;
  *) ok "the C25 slice contains only its own class text" ;;
esac

# The routing note hunter/zone-mapper authors read first must mention C25, else the class is invisible to a
# human extending the taxonomy.
note "7) the Hunter usage notes route a zero-participation zone to C25 ..."
if grep -q 'so it can never read zero → C25' "$TAXONOMY"; then
  ok "the Hunter usage notes carry the C25 routing clause"
else
  bad "the Hunter usage notes lost the C25 routing clause"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) The two DELIBERATE non-changes, pinned as decisions rather than omissions.
# ----------------------------------------------------------------------------------------------------------
note "8) deliberate non-changes: hunter.ag untouched, no class_to_keyword() entry for C25 ..."
if grep -qE 'C25|zero_total' "$HUNTER"; then
  bad "hunter.ag gained a C25 / zero_total token — the lens is the taxonomy section, not a hunter directive block (the pure-meta shape measured Delta=+0)"
else
  ok "hunter.ag carries no C25 / zero_total token (the class reaches the cell through the taxonomy menu only)"
fi
if grep -q 'class_to_keyword' "$PROVER"; then
  if grep -qE 'class_is\(k, "c25"\)' "$PROVER"; then
    bad "invariant-prover.ag gained a class_to_keyword() entry for C25 — that re-routes the depth/metamorphic action menu, an unmeasured second variable (C22/C23/C24 have no entry either)"
  else
    ok "invariant-prover.ag's class_to_keyword() has no C25 entry (C25 falls through to the generic default, like C22/C23/C24)"
  fi
else
  bad "invariant-prover.ag no longer defines class_to_keyword() — this decision pin no longer guards anything"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) The zone-mapper ROUTE: the deterministic net, its force-include, the diagnostic, the chain order and the
#     ONLY-WHEN-shaped detection rule with its explicit escape clause.
# ----------------------------------------------------------------------------------------------------------
note "9) zone-mapper.ag carries the deterministic C25 net, its force-include and the ZERO-TOTAL| diagnostic ..."
net_miss=""
for f in has_participation_total_surface has_participation_zero_gate has_participation_division \
         has_supply_floor_constant contains_zero_total_signal apply_zero_total_backstop; do
  grep -q "fn $f" "$MAPPER" || net_miss="$net_miss [$f]"
done
grep -q 'force_include(classesCsv, "C25")' "$MAPPER" || net_miss="$net_miss [force_include C25]"
grep -q '"ZERO-TOTAL|"' "$MAPPER" || net_miss="$net_miss [ZERO-TOTAL| diagnostic]"
if [ -z "$net_miss" ]; then
  ok "zone-mapper.ag defines the four C25 surfaces, contains_zero_total_signal, apply_zero_total_backstop -> force_include C25, and the ZERO-TOTAL| line"
else
  bad "zone-mapper.ag is missing part of the #2245 C25 route:$net_miss"
fi

# The diagnostic is emitted ONLY WHEN THE NET FIRES (unlike CROSS-UNIT|/STALE-STATE|, which print true/false
# unconditionally), so a zone the net is silent on produces byte-identical mapper output to before this change.
note "10) the ZERO-TOTAL| diagnostic is emitted only when the net fires ..."
if grep -q '^if contains_zero_total_signal(code) { print("ZERO-TOTAL|" + zoneId + "|true"); }$' "$MAPPER"; then
  ok "the ZERO-TOTAL| line is guarded by contains_zero_total_signal() (silent zones keep byte-identical output)"
else
  bad "the ZERO-TOTAL| diagnostic is no longer gated on the net firing — a silent zone's mapper output is no longer byte-identical"
fi

# Chain order: the C25 backstop runs AFTER the #2218 net and BEFORE apply_fitness_reorder, so a forced C25 is
# still fitness-ranked like a forced C5/C8/C19/C22/C24 (and never lands outside the reordered CSV).
note "11) apply_zero_total_backstop is chained after the #2218 net and before the fitness reorder ..."
if awk '/fn apply_backstop/{f=1} f&&/apply_state_assumption_backstop\(/{s=NR} f&&/apply_zero_total_backstop\(/{z=NR} f&&/apply_fitness_reorder\(/{print (s&&z&&s<z&&z<NR) ? "ok" : "no"; exit}' "$MAPPER" | grep -q '^ok$'; then
  ok "apply_zero_total_backstop sits between apply_state_assumption_backstop and apply_fitness_reorder"
else
  bad "apply_zero_total_backstop is not chained between the #2218 backstop and the fitness reorder"
fi

note "12) the C25 detection rule is ONLY-WHEN shaped and carries its do-NOT-add escape ..."
# The instruction is a multi-line `"..." + "..."` concatenation, so a sentence can straddle two source lines.
# Slice the PROMPT region (`let instruction =` .. the `prompt(` call) and flatten the string joins, so every
# assertion below is about the text the model actually receives — never about the file's comments.
MAPPER_FLAT="$(awk '/^let instruction =/{f=1} f{print} /let verdict = prompt\(/{exit}' "$MAPPER" \
  | tr '\n' ' ' | sed 's/"[[:space:]]*+[[:space:]]*"//g')"
rule_hit=1
case "$MAPPER_FLAT" in *"EMPTY DISTRIBUTION / ZERO PARTICIPATION EDGE DETECTION RULE (C25)"*) ;; *) rule_hit=0 ;; esac
case "$MAPPER_FLAT" in *"INCLUDE \`C25\` (empty distribution / zero participation edge) ONLY WHEN"*) ;; *) rule_hit=0 ;; esac
case "$MAPPER_FLAT" in *"do NOT add C25"*) ;; *) rule_hit=0 ;; esac
if [ "$rule_hit" -eq 1 ]; then
  ok "zone-mapper.ag has the C25 detection rule, its ONLY-WHEN gate and its 'do NOT add C25' escape clause"
else
  bad "zone-mapper.ag missing the C25 detection rule, its ONLY-WHEN gate or its 'do NOT add C25' escape clause"
fi
# The rule must stay a CLASS description: no target name, no fixture name, no ground-truth row id may leak into
# the prompt (that would make the measurement a memorisation test rather than a lens test).
if printf '%s' "$MAPPER_FLAT" | grep -qiE 'zerogatedexit|flooredemission|seededsharevault|corpus-bench'; then
  bad "a fixture/corpus identifier leaked into the zone-mapper PROMPT — the detection rules must describe the CLASS, never the rows they were derived from"
else
  ok "no fixture/corpus identifier appears in the zone-mapper prompt (the rules describe classes, not the corpus)"
fi
# The net helper names are POST-classification machinery: they must never reach the prompt, or a zone on which
# the net does not fire would no longer get the byte-identical instruction its verdict was measured on.
if printf '%s' "$MAPPER_FLAT" | grep -qE 'zero_total|participation_total_surface|ZERO-TOTAL\|'; then
  bad "a C25 net helper name leaked into the zone-mapper PROMPT (the net is post-classification only)"
else
  ok "no C25 net helper name appears in the zone-mapper prompt (the net stays post-classification only)"
fi
if grep -q 'pick the 1-4 that genuinely fit' "$MAPPER"; then
  ok "zone-mapper.ag still caps the LLM class list at 1-4 per zone (#1830 cell-budget guard)"
else
  bad "the 'pick the 1-4 that genuinely fit' class-count cap is gone (cell-budget regression)"
fi

# ----------------------------------------------------------------------------------------------------------
# (f) BEHAVIOUR, offline and WITHOUT an LLM. The mock backend's reply carries no ZONE| sentinel, so
#     apply_backstop()'s append is unreachable through a real zone run — this drives the REAL, shipped
#     apply_backstop() over three Solidity fixtures instead, exactly the probe idiom demo-map-zones.sh uses.
#     Pins: (1) both TRUE fixtures force C25 exactly once, appended as ONE new trailing ZONE| line;
#           (2) the FALSE fixture leaves the verdict BYTE-IDENTICAL (no C25, no appended line, no diagnostic);
#           (3) a zone already carrying C25 gets no duplicate.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — skipping the apply_backstop() C25 behaviour probe (source guards above still ran)"
else
  note "13) apply_backstop() C25 behaviour over TRUE/TRUE/FALSE fixtures (real .ag functions, no LLM) ..."
  FIX="$WORK/fixtures"
  mkdir -p "$FIX"

  # TRUE #1 — the FALSE ZERO GATE direction. The exit path is gated on the staker pool's RAW UNIT COUNT while
  # the allocation weight that decides whether anything is owed to that pool at all is an admin-settable basis
  # point that may legitimately be zero. With the weight at zero nobody ever gets units, so the gate reverts a
  # normal user exit forever — a state the protocol's own setter reaches.
  cat > "$FIX/ZeroGatedExit.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IDistributionPool {
    function totalUnits() external view returns (uint128);
}

contract ZeroGatedExit {
    IDistributionPool public stakerPool;
    uint256 public stakerAllocationBp;
    mapping(address => uint256) public locked;

    function setStakerAllocationBp(uint256 bp) external {
        stakerAllocationBp = bp;
    }

    function exit(uint256 amount) external {
        require(stakerPool.totalUnits() > 0, "no units");
        locked[msg.sender] = locked[msg.sender] - amount;
    }
}
SOL

  # TRUE #2 — the FALSE NON-ZERO direction. effectiveSupply() is floored by a virtual-shares constant, so the
  # "nobody is subscribed, stop emitting" branch below it is dead code: the emission keeps accruing per unit of
  # a supply made of nothing but the floor, with no real recipient.
  cat > "$FIX/FlooredEmission.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract FlooredEmission {
    uint256 internal constant VIRTUAL_SHARES = 1e6;

    uint256 public rawSupply;
    uint256 public emissionPerSecond;
    uint256 public lastAccrual;
    uint256 public accRewardPerUnit;

    function effectiveSupply() public view returns (uint256) {
        return rawSupply + VIRTUAL_SHARES;
    }

    function accrueEmission() public {
        if (effectiveSupply() == 0) {
            return;
        }
        uint256 elapsed = block.timestamp - lastAccrual;
        accRewardPerUnit = accRewardPerUnit + (emissionPerSecond * elapsed * 1e18) / effectiveSupply();
        lastAccrual = block.timestamp;
    }
}
SOL

  # FALSE — a share vault whose total is provably non-zero for every later call because a permanent first
  # deposit is seeded at construction, and whose per-share math goes through a mulDiv helper. Nothing gates on
  # the total being zero, nothing floors it to dodge a zero branch: there is no zero edge here to mishandle.
  # NB this is a NEGATIVE CONTROL FOR THE ROUTE, and the route is a token net: the same vault written with a
  # literal `assets * totalSupply / totalAssets` would trip the division surface and be routed anyway. A route
  # over-including is a cell; the class rule in the prompt is what decides. What this control proves is the
  # thing that matters for cost — merely NAMING a participation total is not enough to pull the class in.
  cat > "$FIX/SeededShareVault.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library ShareMath {
    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a * b) / d;
    }
}

contract SeededShareVault {
    uint256 public totalSupply;
    uint256 public totalAssets;

    constructor() {
        totalSupply = 1e18;
        totalAssets = 1e18;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        shares = ShareMath.mulDiv(assets, totalSupply, totalAssets);
        totalSupply = totalSupply + shares;
        totalAssets = totalAssets + assets;
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
    echo '// #2245 probe tail (demo-zero-total-lens.sh): drive the SHIPPED apply_backstop() over three'
    echo '// fixtures. Two carry the C25 shape and must force it exactly once; the third names a participation'
    echo '// total but handles no zero edge and must leave the verdict byte-identical.'
    echo "let zgGate = \"$(flatten "$FIX/ZeroGatedExit.sol")\";"
    echo "let zgFloor = \"$(flatten "$FIX/FlooredEmission.sol")\";"
    echo "let zgSafe = \"$(flatten "$FIX/SeededShareVault.sol")\";"
  } >> "$PROBE/backstop-probe.ag"
  cat >> "$PROBE/backstop-probe.ag" <<'AG'
print("ZT-T1|" + apply_backstop("ZONE|zgate|Distribution|C7|why", zgGate));
print("ZT-T2|" + apply_backstop("ZONE|zfloor|Rewards|C7|why", zgFloor));
print("ZT-T3|" + apply_backstop("ZONE|zsafe|Vault|C7|why", zgSafe));
print("ZT-T4|" + apply_backstop("ZONE|zdup|Distribution|C25,C7|why", zgGate));
// The shipped emit shape, replayed: the diagnostic exists ONLY when the net fires.
if contains_zero_total_signal(zgGate) { print("ZT-DIAG|zgate|true"); }
if contains_zero_total_signal(zgFloor) { print("ZT-DIAG|zfloor|true"); }
if contains_zero_total_signal(zgSafe) { print("ZT-DIAG|zsafe|true"); }
AG
  ( cd "$PROBE" && agentis init >/dev/null 2>&1 ) || true
  # knowledge.enabled: apply_fitness_reorder() calls query_knowledge("hunt-fitness"); nothing is imported here,
  # so the reorder stays an identity and the CSV order below is the backstop's own.
  printf 'llm.backend = mock\nlearning.enabled = true\nexperience.enabled = true\nknowledge.enabled = true\n' > "$PROBE/.agentis/config"
  ( cd "$PROBE" && agentis go backstop-probe.ag ) > "$PROBE/probe.log" 2>&1
  ZT_RC=$?
  # Each print() emits the (possibly two-line) verdict; take the tag line and the line after it.
  ZT_T1_NEXT="$(awk '/^ZT-T1\|/{getline; print; exit}' "$PROBE/probe.log")"
  ZT_T2_NEXT="$(awk '/^ZT-T2\|/{getline; print; exit}' "$PROBE/probe.log")"
  ZT_T3_LINE="$(awk '/^ZT-T3\|/{print; exit}' "$PROBE/probe.log")"
  ZT_T3_NEXT="$(awk '/^ZT-T3\|/{getline; print; exit}' "$PROBE/probe.log")"
  ZT_T4_LINE="$(awk '/^ZT-T4\|/{print; exit}' "$PROBE/probe.log")"
  ZT_T4_NEXT="$(awk '/^ZT-T4\|/{getline; print; exit}' "$PROBE/probe.log")"
  if [ "$ZT_RC" -ne 0 ]; then
    bad "the apply_backstop() probe did not run (exit $ZT_RC)"
    sed 's/^/      /' "$PROBE/probe.log" | head -20 >&2
  else
    if [ "$ZT_T1_NEXT" = "ZONE|zgate|Distribution|C7,C25|why" ]; then
      ok "TRUE (false zero gate): apply_backstop() appends ONE rebuilt ZONE| line with C25 added exactly once"
    else
      bad "TRUE (false zero gate): want the appended line 'ZONE|zgate|Distribution|C7,C25|why', got '$ZT_T1_NEXT'"
    fi
    # NB the floored-emission fixture legitimately also trips the #2218 C24 net (an emission carried per unit
    # of supply IS a stale-definition surface), so the appended CSV is matched on the C25 addition, not pinned
    # byte-for-byte — the two classes are neighbours by design and the taxonomy's NOT-this-class list is what
    # separates them in the cell.
    case "$ZT_T2_NEXT" in
      "ZONE|zfloor|Rewards|C7,"*"C25"*"|why")
        ok "TRUE (false non-zero): a floored effectiveSupply feeding a live emission forces C25 (appended line '$ZT_T2_NEXT')" ;;
      *)
        bad "TRUE (false non-zero): the appended line does not carry C25, got '$ZT_T2_NEXT'" ;;
    esac
    # "no appended line" = the line after the tag is the NEXT tag, not a rebuilt `ZONE|` line.
    ZT_T3_APPENDED=0
    case "$ZT_T3_NEXT" in "ZONE|"*) ZT_T3_APPENDED=1 ;; esac
    ZT_T4_APPENDED=0
    case "$ZT_T4_NEXT" in "ZONE|"*) ZT_T4_APPENDED=1 ;; esac
    if [ "$ZT_T3_LINE" = "ZT-T3|ZONE|zsafe|Vault|C7|why" ] && [ "$ZT_T3_APPENDED" -eq 0 ]; then
      ok "FALSE: apply_backstop() returns the verdict BYTE-IDENTICAL when the C25 net does not fire (no C25, no appended line)"
    else
      bad "FALSE: the no-fire verdict was not byte-identical (got '$ZT_T3_LINE' + next '$ZT_T3_NEXT')"
    fi
    if [ "$ZT_T4_LINE" = "ZT-T4|ZONE|zdup|Distribution|C25,C7|why" ] && [ "$ZT_T4_APPENDED" -eq 0 ]; then
      ok "a zone that ALREADY carries C25 gets no duplicate (force_include dedupe, no appended line)"
    else
      bad "duplicate-C25 regression (got '$ZT_T4_LINE' + next '$ZT_T4_NEXT')"
    fi
    ZT_DIAG="$(grep -c '^ZT-DIAG|' "$PROBE/probe.log")"
    if grep -q '^ZT-DIAG|zgate|true$' "$PROBE/probe.log" \
       && grep -q '^ZT-DIAG|zfloor|true$' "$PROBE/probe.log" \
       && ! grep -q '^ZT-DIAG|zsafe|' "$PROBE/probe.log" \
       && [ "$ZT_DIAG" -eq 2 ]; then
      ok "the diagnostic is emitted for both TRUE fixtures and for NEITHER the FALSE one (exactly 2 lines)"
    else
      bad "diagnostic conditionality regressed (expected 2 lines, zgate+zfloor only; got $ZT_DIAG)"
      grep '^ZT-DIAG|' "$PROBE/probe.log" | sed 's/^/      /' >&2
    fi
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the C25 zero-participation lens (guarded class text + deterministic zone-mapper route + fixture behaviour) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
