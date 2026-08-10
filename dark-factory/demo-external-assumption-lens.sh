#!/usr/bin/env bash
# demo-external-assumption-lens.sh — OFFLINE, DETERMINISTIC source-guard for the EXTERNAL-ASSUMPTION hunt
# lens (#1872): two new bug classes for the shape the corpus-bench notional contest showed the hunter has no
# lens for — the target's own code is internally consistent, and the bug is an ASSUMPTION it makes about a
# SECOND protocol.
#
#   C22 — Cross-protocol asset / unit equivalence: two DIFFERENT externally-issued assets treated as one
#         (an SY/YT pair, native ETH vs WETH, an LP/receipt token vs its underlying) at a hardcoded 1:1 rate.
#   C23 — Hardcoded external-integration parameter: a literal/`constant`/`immutable` argument to an external
#         call that is correct for exactly ONE external configuration (a `useEth` flag, a `dexId`, a coin
#         index, a hardcoded pool address) on a path that can reach another.
#
# The change is content-only: the two taxonomy classes plus two PROMPT-ONLY zone-mapper detection rules. So
# this demo is a source-guard, and it guards the three things that can silently rot:
#   1. the ANTI-CATCH-ALL contract — each class carries its `NOT this class` + `required evidence` guard
#      headers and its enumerate-the-artefacts hunt keywords. A class whose hunt collapses to "enumerate the
#      assumptions" fires on every zone that imports anything and burns the cell budget (#1830).
#   2. the CELL-BUDGET guard — the zone-mapper gains a MENU entry (which DISPLACES a class inside the
#      `1-4` cap), deliberately NOT a deterministic `apply_*_backstop`/force-include (which would ADD a cell
#      to every matching zone unconditionally). Both facts are pinned here as a decision, not an omission.
#   3. the `class_section()` EXTRACTION anchor — hunter.ag slices the taxonomy with `index($0,"## "c" ")==1`,
#      so `C2` must not swallow `C22`/`C23`. This test runs that exact awk against the real file: it is the
#      one way this change could silently break an already-working lens (C2).
#
# Usage:  dark-factory/demo-external-assumption-lens.sh
# Requires: awk + grep (the floor — no agentis, no forge, no network, CI-safe).
# Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TAXONOMY="$HERE/auditor/bug-taxonomy.md"
MAPPER="$HERE/auditor/agents/zone-mapper.ag"
HUNTER="$HERE/auditor/agents/hunter.ag"
MAPZONES="$HERE/map-zones.sh"
DISCOVERY="$HERE/run-discovery.sh"

FAILS=0
note() { echo "demo-external-assumption-lens.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -f "$TAXONOMY" ] || { note "bug-taxonomy.md not found: $TAXONOMY" >&2; exit 3; }
[ -f "$MAPPER" ]   || { note "zone-mapper.ag not found: $MAPPER" >&2; exit 3; }
[ -f "$HUNTER" ]   || { note "hunter.ag not found: $HUNTER" >&2; exit 3; }
[ -f "$MAPZONES" ] || { note "map-zones.sh not found: $MAPZONES" >&2; exit 3; }
[ -f "$DISCOVERY" ] || { note "run-discovery.sh not found: $DISCOVERY" >&2; exit 3; }

# hunter.ag's own class_section() awk anchor, verbatim in shape: take the `## <cls> ` section and stop at the
# next `## ` header that is not this class. Used by assertion (c) as the extraction pin.
class_section() {
  awk -v c="$1" 'index($0,"## "c" ")==1{f=1} f&&index($0,"## ")==1&&index($0,"## "c" ")!=1{exit} f{print}' \
    "$TAXONOMY" 2>/dev/null
}

# ----------------------------------------------------------------------------------------------------------
# (a) The taxonomy declares both new classes as top-level sections (what class_section() anchors on).
# ----------------------------------------------------------------------------------------------------------
note "1) bug-taxonomy.md declares the C22 + C23 class headers ..."
for c in C22 C23; do
  if grep -q "^## $c " "$TAXONOMY"; then
    ok "bug-taxonomy.md declares the '## $c ' class header"
  else
    bad "bug-taxonomy.md missing the '## $c ' class header"
  fi
done

# ----------------------------------------------------------------------------------------------------------
# (b) The ANTI-CATCH-ALL contract: each class carries its two guard headers plus the enumerate-the-artefacts
#     keywords. Asserted as TEXT so the guards cannot be quietly deleted while the class stays declared.
# ----------------------------------------------------------------------------------------------------------
note "2) each new class carries its NOT-this-class + required-evidence guards and its enumeration keywords ..."
for c in C22 C23; do
  sec="$(class_section "$c")"
  miss=""
  case "$sec" in *"**NOT this class:**"*) ;; *) miss="$miss [NOT this class]" ;; esac
  case "$sec" in *"**required evidence (else report SAFE):**"*) ;; *) miss="$miss [required evidence]" ;; esac
  case "$sec" in *"enumerate, do not intuit"*) ;; *) miss="$miss [enumerate, do not intuit]" ;; esac
  case "$sec" in *"(i)"*) ;; *) miss="$miss [(i)]" ;; esac
  case "$sec" in *"(ii)"*) ;; *) miss="$miss [(ii)]" ;; esac
  case "$sec" in *"(iii)"*) ;; *) miss="$miss [(iii)]" ;; esac
  if [ -z "$miss" ]; then
    ok "$c carries NOT-this-class, the three-part required-evidence contract, and the enumeration instruction"
  else
    bad "$c is missing its anti-catch-all guards:$miss"
  fi
done

# The class-specific artefacts each hunt must enumerate (not "the assumptions" — named, countable things).
note "3) the enumeration targets are the NAMED artefacts, per class ..."
c22="$(class_section C22)"
c22_miss=""
for k in "every token address" "every external interface" "ONE arithmetic step" "issuer"; do
  case "$c22" in *"$k"*) ;; *) c22_miss="$c22_miss [$k]" ;; esac
done
if [ -z "$c22_miss" ]; then
  ok "C22 enumerates token addresses, imported interfaces, the meeting points and the ISSUER's guarantee"
else
  bad "C22 hunt lost an enumeration target:$c22_miss"
fi
c23="$(class_section C23)"
c23_miss=""
for k in "for EVERY external call" "immutable" "SET of external configurations" "round trip"; do
  case "$c23" in *"$k"*) ;; *) c23_miss="$c23_miss [$k]" ;; esac
done
if [ -z "$c23_miss" ]; then
  ok "C23 enumerates external calls, literal/constant/immutable arguments, the valid-configuration set and the round trip"
else
  bad "C23 hunt lost an enumeration target:$c23_miss"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) EXTRACTION PIN: hunter.ag's `## <cls> ` awk anchor over the REAL taxonomy. C2 must not swallow C22/C23
#     (the prefix-collision risk this change introduces), and C22 must stop before C23.
# ----------------------------------------------------------------------------------------------------------
note "4) class_section() extraction pin: C2 / C22 / C23 slice cleanly (no '## C2 ' vs '## C22 ' collision) ..."
# shellcheck disable=SC2016  # matched VERBATIM against hunter.ag's source (an awk anchor inside an exec-sh string)
if grep -qF 'index($0,\"## \"c\" \")==1' "$HUNTER"; then
  ok "hunter.ag still slices the taxonomy with the '## <cls> ' anchor this test replicates"
else
  bad "hunter.ag's class_section() anchor changed — this extraction pin no longer guards the real code path"
fi
for c in C2 C22 C23; do
  sec="$(class_section "$c")"
  if [ -n "$sec" ]; then
    ok "class_section($c) returns a non-empty slice"
  else
    bad "class_section($c) returned an EMPTY slice — the class is unreachable from hunter.ag"
  fi
done
sec_c2="$(class_section C2)"
case "$sec_c2" in
  *"## C22"*) bad "the C2 slice swallowed the C22 section (prefix collision)" ;;
  *"## C23"*) bad "the C2 slice swallowed the C23 section (prefix collision)" ;;
  *) ok "the C2 slice contains neither '## C22' nor '## C23' (C2's own lens is intact)" ;;
esac
case "$(class_section C22)" in
  *"## C23"*) bad "the C22 slice ran past its own section into C23" ;;
  *) ok "the C22 slice stops before '## C23'" ;;
esac

# ----------------------------------------------------------------------------------------------------------
# (d) The zone-mapper carries both PROMPT-ONLY detection rules, each with its explicit negative clause.
# ----------------------------------------------------------------------------------------------------------
note "5) zone-mapper.ag carries both DETECTION RULE paragraphs with their do-NOT-add clauses ..."
# The instruction is a multi-line `"..." + "..."` concatenation, so a sentence can straddle two source lines.
# Flatten the string joins first, then assert on the PROMPT text the model actually receives.
MAPPER_FLAT="$(tr '\n' ' ' < "$MAPPER" | sed 's/"[[:space:]]*+[[:space:]]*"//g')"
for c in C22 C23; do
  case "$c" in
    C22) hdr="CROSS-PROTOCOL ASSET / UNIT EQUIVALENCE DETECTION RULE (C22)" ;;
    *)   hdr="HARDCODED EXTERNAL-INTEGRATION PARAMETER DETECTION RULE (C23)" ;;
  esac
  hit=1
  case "$MAPPER_FLAT" in *"$hdr"*) ;; *) hit=0 ;; esac
  case "$MAPPER_FLAT" in *"do NOT add $c"*) ;; *) hit=0 ;; esac
  if [ "$hit" -eq 1 ]; then
    ok "zone-mapper.ag has the $c detection rule and its 'do NOT add $c' negative clause"
  else
    bad "zone-mapper.ag missing the $c detection rule or its 'do NOT add $c' negative clause"
  fi
done
if grep -q 'ONLY WHEN' "$MAPPER"; then
  ok "the new rules gate inclusion on an explicit ONLY-WHEN condition (menu entry, not a catch-all)"
else
  bad "the new detection rules lost their ONLY-WHEN gating condition"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) CELL-BUDGET guard (#1830), pinned as a DECISION: no deterministic force-include for C22/C23, and the
#     class-count cap still reads 1-4. A menu addition displaces a class inside the cap; a force-include would
#     add a cell to every matching zone unconditionally.
# ----------------------------------------------------------------------------------------------------------
note "6) cell-budget guard: no force-include for C22/C23 and the 1-4 class cap is untouched ..."
if grep -nE 'force_include|apply_[a-z_]*backstop' "$MAPPER" | grep -q 'C2[23]'; then
  bad "zone-mapper.ag gained a deterministic force-include/backstop for C22 or C23 (cell-budget regression)"
else
  ok "no force_include / apply_*_backstop references C22 or C23 (the classes stay menu-only)"
fi
if grep -q 'pick the 1-4 that genuinely fit' "$MAPPER"; then
  ok "zone-mapper.ag still caps the class list at 1-4 per zone"
else
  bad "the 'pick the 1-4 that genuinely fit' class-count cap is gone (cell-budget regression)"
fi

# ----------------------------------------------------------------------------------------------------------
# (f) READ-ONLY / NEVER-SUBMIT: no network or submission verb on the path this lens is driven through.
# ----------------------------------------------------------------------------------------------------------
note "7) read-only / never-submit on the map + discovery path this lens rides ..."
egress=0
for s in "$MAPZONES" "$DISCOVERY"; do
  if grep -vE '^[[:space:]]*#' "$s" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
    egress=1
  fi
done
if [ "$egress" -eq 0 ]; then
  ok "no network / no submission verb on the map + discovery path (read-only, never submits)"
else
  bad "a network/submission verb appears on the map + discovery path"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the C22/C23 external-assumption lens (guarded class text + prompt-only zone-mapper rules) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
