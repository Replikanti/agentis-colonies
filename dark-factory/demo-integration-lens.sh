#!/usr/bin/env bash
# demo-integration-lens.sh — the OFFLINE gate for the #2191 EXTERNAL-INTEGRATION / ORACLE-ASSUMPTION directive
# (the elite-recall cross-class wedge).
#
# What the change is: hunter.ag gained a deterministic external-integration detector and a GENERIC
# assumption-naming directive it injects into the shared hunt instruction — "in ADDITION to the bug class
# above, for every external call, price/rate read, and point where two externally-issued amounts meet, NAME
# the assumption this code makes about the external protocol and show the permissionless path that violates
# it". The directive is CROSS-CLASS (it fires whatever HUNT_CLASS a cell runs), `""`-gated (a zone with no
# integration surface prompts byte-for-byte as before), and toggled by INTEGRATION_LENS (=0 forces the OFF
# control arm even where the detector fires). An `INTEGRATION-LENS|<subsystem>|<cls>|<n>` sentinel makes the
# injection observable in the cell log.
#
# Parts 1-2 prove the MACHINERY, never the capability. Whether the directive actually makes a hunter GENERATE
# the integration/oracle vector it was missing is only provable by a sandboxed, refusal-fallback-off,
# transcript-attributed live A/B (bench/corpus-bench/integration-lens-ab.sh --live) — an operator step,
# deliberately NOT a CI gate (a mock backend does not reason).
#
# Two parts:
#   1) SOURCE-GUARD (the CI floor — pure grep/awk: no agentis, no forge, no network). The detector helpers,
#      the directive's load-bearing sentences, the ""-when-false gate, the toggle, the splice position, the
#      sentinel and its honesty gate, the record boundary, substrate purity, the two fixtures' shapes, that the
#      detector/directive carry NO protocol-specific token (the overfitting guard), and the decision that the
#      taxonomy gains NO new class (this is a cross-class re-framing, documented as a usage note, not a lens).
#   2) LIVE-UNDER-MOCK ([SKIP] without an `agentis` binary). One REAL offline hunt cell per fixture through
#      run-discovery.sh --backend mock --classes C2: the sentinel MUST be printed for the integration fixture
#      and MUST be ABSENT for the plain one; INTEGRATION_LENS=0 MUST suppress it even on the integration
#      fixture. Plus a BYTE-IDENTITY probe that runs the detector helpers EXTRACTED FROM hunter.ag BY LINE
#      RANGE (so a copy-pasted twin cannot drift from the agent it claims to measure) and asserts the injected
#      block is the EMPTY string on the plain arm AND under INTEGRATION_LENS=0 — concatenating "" into the
#      instruction is a no-op, which is what "the prompt is byte-identical" means here.
#
# Usage:  dark-factory/demo-integration-lens.sh
# Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HUNTER="$HERE/auditor/agents/hunter.ag"
TAXONOMY="$HERE/auditor/bug-taxonomy.md"
DISCOVERY="$HERE/run-discovery.sh"
FIXDIR="$HERE/fixtures/integration-lens/contracts"
INTEGRATION="$FIXDIR/IntegrationVault.sol"
PLAIN="$FIXDIR/PlainVault.sol"

FAILS=0
note() { echo "demo-integration-lens.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for f in "$HUNTER" "$TAXONOMY" "$DISCOVERY" "$INTEGRATION" "$PLAIN"; do
  [ -f "$f" ] || { note "required file not found: $f" >&2; exit 3; }
done

WORK="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# The multi-line `"..." + "..."` string joins are flattened first, so an assertion can match the PROMPT text
# the model actually receives rather than one source line of it (same idiom as demo-callee-trust-lens.sh).
HUNTER_FLAT="$(tr '\n' ' ' < "$HUNTER" | sed 's/"[[:space:]]*+[[:space:]]*"//g')"

# The #2191-specific helpers plus the #2145 call-surface helpers the detector reuses (needed for the
# byte-identity probe's transitive extraction below).
DETECTOR_FNS="has_low_level_call_surface interface_call_pattern is_view_idiom_method has_interface_call_surface has_call_surface signal_score has_valuation_read_shape hardcoded_bool_arg_pattern hardcoded_int_arg_pattern has_hardcoded_call_arg has_dual_asset_representation integration_signal_count has_external_integration_surface integration_lens_marker integration_assumption_block integration_lens_enabled integration_directive"
NEW_FNS="has_valuation_read_shape hardcoded_bool_arg_pattern hardcoded_int_arg_pattern has_hardcoded_call_arg has_dual_asset_representation integration_signal_count has_external_integration_surface integration_lens_marker integration_assumption_block integration_lens_enabled integration_directive"

# ----------------------------------------------------------------------------------------------------------
# PART 1 — SOURCE-GUARD (CI floor: grep/awk only)
# ----------------------------------------------------------------------------------------------------------
note "1) hunter.ag declares the external-integration detector helpers ..."
MISSING_FN=""
for fn in $NEW_FNS; do
  grep -q "^fn $fn(" "$HUNTER" || MISSING_FN="$MISSING_FN $fn"
done
if [ -z "$MISSING_FN" ]; then
  ok "all 11 #2191 detector/directive/toggle helpers are declared in hunter.ag"
else
  bad "hunter.ag is missing detector helper(s):$MISSING_FN"
fi

# The detector is an AND of a call surface and an integration signal — never one alone. A net that fired on
# "there is an external call" would inject the directive into essentially every zone.
if grep -A3 '^fn has_external_integration_surface(' "$HUNTER" | grep -q 'if !has_call_surface(code) { return false; }' \
   && grep -A3 '^fn has_external_integration_surface(' "$HUNTER" | grep -q 'return integration_signal_count(code) > 0;'; then
  ok "has_external_integration_surface() = call surface AND an integration signal (not a bare call-surface net)"
else
  bad "has_external_integration_surface() no longer ANDs the call surface with an integration signal"
fi

# The three integration signals are each independently reachable, and their count is what the sentinel reports.
SIG_MISS=""
for sig in has_valuation_read_shape has_hardcoded_call_arg has_dual_asset_representation; do
  grep -A4 '^fn integration_signal_count(' "$HUNTER" | grep -q "$sig(code)" || SIG_MISS="$SIG_MISS $sig"
done
if [ -z "$SIG_MISS" ]; then
  ok "integration_signal_count() sums all three signals (valuation read / hardcoded call arg / dual asset representation)"
else
  bad "integration_signal_count() dropped signal(s):$SIG_MISS"
fi

note "2) the directive carries its load-bearing sentences ..."
DIRECTIVE_MISS=""
for s in \
  "=== WHAT DOES THIS CODE TRUST ABOUT THE EXTERNAL PROTOCOL? ===" \
  "In ADDITION to the bug class above" \
  "NAME in ONE sentence the ASSUMPTION this code makes about the external protocol" \
  "show the PERMISSIONLESS path" \
  "OVER-MINTS, OVER-WITHDRAWS, UNDER-COLLATERALISES" \
  "INTEGRATION-ASSUMPTION|<fn>|<external-call-or-read>|" \
  "A shape or a hardcoded value ALONE is NEVER a finding" \
  "defer the detail to it and do NOT"
do
  case "$HUNTER_FLAT" in *"$s"*) ;; *) DIRECTIVE_MISS="$DIRECTIVE_MISS [$s]" ;; esac
done
if [ -z "$DIRECTIVE_MISS" ]; then
  ok "the directive keeps its header, the additive framing, the name-the-assumption + permissionless-path demand, the over-mint consequence, the audit-trail output line, the shape-alone-is-not-a-finding guard, and the defer-to-the-deep-lens rule"
else
  bad "the directive lost load-bearing text:$DIRECTIVE_MISS"
fi

# The block references the deep enumeration lenses by NAME so it defers detail to them instead of duplicating
# their bullets (a per-class rewrite would regress other contests — kept out of scope).
if printf '%s' "$HUNTER_FLAT" | grep -q 'C2, C15, C21, C22 or C23'; then
  ok "the directive defers artefact enumeration to the C2/C15/C21/C22/C23 deep lenses (no duplicated bullets)"
else
  bad "the directive no longer names the C2/C15/C21/C22/C23 deep lenses to defer enumeration to"
fi

# GENERICITY / OVERFITTING GUARD (STRUCTURAL): the detector helpers AND the directive block must key on generic
# SHAPES only — no protocol name and no target-specific function-name match token. A reviewer must not be able
# to find a protocol/target-specific string anywhere in the detector or the directive. Sliced from the code
# region itself (the #2191 block), so surrounding narrative comments elsewhere are free to be specific.
GUARD_REGION="$WORK/integration-region.txt"
awk '/--- #2191 EXTERNAL-INTEGRATION/{f=1} f&&/^let dir = getenv\("TARGET_DIR"\);$/{exit} f{print}' "$HUNTER" > "$GUARD_REGION"
PROTO_RE='Curve|Pendle|Morpho|Balancer|Notional|notional|Aave|Compound|Uniswap|Yearn|Symm|Crestal|Yieldoor|getWithdrawRequestValue|_getPTRate'
if [ ! -s "$GUARD_REGION" ]; then
  bad "could not slice the #2191 detector/directive region out of hunter.ag (header renamed?)"
elif grep -Eq "$PROTO_RE" "$GUARD_REGION"; then
  bad "the #2191 detector/directive names a protocol / target-specific token (it would teach-to-the-target and void a live A/B)"
  grep -nE "$PROTO_RE" "$GUARD_REGION" | head -3 | sed 's/^/      /' >&2
else
  ok "the #2191 detector/directive names no protocol / target-specific token (generic shapes only — the overfitting guard holds)"
fi

# The directive block itself (not just the whole region) is generic too — sliced fn-body only.
BLOCK_BODY="$WORK/integration-body.txt"
awk '/^fn integration_assumption_block\(/{f=1} f{print} f&&/^}$/{exit}' "$HUNTER" > "$BLOCK_BODY"
if [ ! -s "$BLOCK_BODY" ]; then
  bad "could not slice integration_assumption_block() out of hunter.ag"
elif grep -Eq "$PROTO_RE|\\.sol" "$BLOCK_BODY"; then
  bad "the directive block names a target-specific contract/function (it would leak an answer into a hunt)"
else
  ok "the directive block names no target-specific contract/function (generic — injecting it cannot leak an answer)"
fi

note "3) the \"\"-when-false gate, the toggle, and the splice position ..."
if grep -A2 '^fn integration_assumption_block(' "$HUNTER" | grep -q 'if !has { return ""; }'; then
  ok "integration_assumption_block() returns \"\" when the detector found nothing (undetected zones prompt byte-identical)"
else
  bad "integration_assumption_block() lost its \"\"-when-false early return — an undetected zone's prompt would change"
fi
# The block is spliced as a bare `+ integ` term (so the empty string is a no-op), directly after `+ callee` and
# before `+ focus` — both cross-class re-framings sit ahead of every per-zone conditional block.
if grep -q '^  + integ$' "$HUNTER" \
   && grep -B1 '^  + integ$' "$HUNTER" | grep -q '^  + callee$' \
   && grep -A1 '^  + integ$' "$HUNTER" | grep -q '^  + focus$'; then
  ok "the directive is spliced as a bare '+ integ' term between '+ callee' and '+ focus' (frames the whole hunt)"
else
  bad "the '+ integ' splice is gone or no longer sits between '+ callee' and '+ focus' in the instruction chain"
fi
if grep -q 'let integ = integration_directive(code);' "$HUNTER"; then
  ok "the block is derived from the detector over the assembled payload, once per cell (via integration_directive)"
else
  bad "the 'let integ = integration_directive(code);' binding is gone"
fi
# #2191 A/B toggle: integration_directive() gates the block on the INTEGRATION_LENS env so the A/B has an OFF
# arm. It must (a) default ON = wrap integration_assumption_block(has_external_integration_surface(code)), and
# (b) return "" when disabled, so INTEGRATION_LENS=0 forces the directive off even where the detector fires.
if grep -A2 '^fn integration_lens_enabled(' "$HUNTER" | grep -q 'return getenv("INTEGRATION_LENS") != "0";'; then
  ok "integration_lens_enabled() is ON unless INTEGRATION_LENS=0 (unset/any-other value = default ON = byte-identical)"
else
  bad "integration_lens_enabled() no longer reads getenv(\"INTEGRATION_LENS\") != \"0\" (the OFF arm would be unreachable)"
fi
if grep -A2 '^fn integration_directive(' "$HUNTER" | grep -q 'if !integration_lens_enabled() { return ""; }' \
   && grep -A3 '^fn integration_directive(' "$HUNTER" | grep -q 'return integration_assumption_block(has_external_integration_surface(code));'; then
  ok "integration_directive() returns \"\" when disabled, else the unchanged block (ON = pre-#2191 behaviour)"
else
  bad "integration_directive() no longer \"\"-gates on the toggle while otherwise wrapping the detector block"
fi
# The toggle is silently inert unless INTEGRATION_LENS rides run-discovery.sh's exec.env_passthrough (getenv
# reads the SANITISED env — the #1426/#1428 failure mode the DEPTH_TARGET/CALLEE_TRUST allowlist entries guard).
if grep -q '^  echo "exec.env_passthrough = .*,INTEGRATION_LENS"' "$DISCOVERY"; then
  ok "run-discovery.sh registers INTEGRATION_LENS on exec.env_passthrough (the OFF toggle can reach hunter.ag)"
else
  bad "run-discovery.sh does NOT pass INTEGRATION_LENS through exec.env_passthrough — INTEGRATION_LENS=0 would be inert"
fi

note "4) the INTEGRATION-LENS sentinel and its honesty gate ..."
if grep -q 'print("INTEGRATION-LENS|" + subsystem + "|" + cls + "|" + to_string(integration_signal_count(code)));' "$HUNTER"; then
  ok "the sentinel is printed as INTEGRATION-LENS|<subsystem>|<cls>|<n>"
else
  bad "the INTEGRATION-LENS|<subsystem>|<cls>|<n> sentinel emission is gone or reshaped"
fi
# Gated on the marker being IN the assembled instruction, never on the detector's return value — the same
# honesty contract CALLEE-TRUST| / APPENDIX-CONTEXT| carry.
if grep -B1 'print("INTEGRATION-LENS|"' "$HUNTER" | grep -q 'if index_of(instruction, integration_lens_marker()) >= 0 {'; then
  ok "the sentinel is gated on the marker actually being in the assembled instruction (index_of), not on the detector flag"
else
  bad "the INTEGRATION-LENS sentinel is no longer gated on the marker being present in the assembled instruction"
fi
# A diagnostic carrying `CANDIDATE|` would let lib/run-agent-validated.sh's sentinel predicate false-accept a
# cell that never produced a finding.
if grep 'print("INTEGRATION-LENS|"' "$HUNTER" | grep -q 'CANDIDATE|'; then
  bad "the INTEGRATION-LENS sentinel carries a 'CANDIDATE|' substring (would false-accept a cell)"
else
  ok "the sentinel carries no 'CANDIDATE|' substring (cannot false-accept a cell)"
fi
if grep -q 'INTEGRATION-LENS|<subsystem>|<cls>|<n>' "$HUNTER"; then
  ok "hunter.ag's header documents INTEGRATION-LENS| among the diagnostics that may precede the verdict"
else
  bad "hunter.ag's header Stdout contract does not mention the INTEGRATION-LENS| diagnostic"
fi

note "5) the sentinel is a RECORD BOUNDARY in run-discovery.sh (#2147 discipline) ..."
BOUNDARY_LINE="$(grep -n 'BLACKBOARD-/ ||' "$DISCOVERY" | head -1 | cut -d: -f2-)"
case "$BOUNDARY_LINE" in
  *'INTEGRATION-LENS\|'*) ok "run-discovery.sh's _join_wrapped_candidates boundary alternation lists INTEGRATION-LENS| next to the sibling sentinels" ;;
  '') bad "could not find the _join_wrapped_candidates boundary alternation in run-discovery.sh" ;;
  *) bad "the _join_wrapped_candidates boundary alternation does NOT list INTEGRATION-LENS| — the sentinel could be glued onto an open CANDIDATE| record" ;;
esac

note "6) substrate purity (#1587): the detector is builtins-only ..."
# CODE lines only: the block's own prose legitimately discusses external calls and the audit-trail line, and a
# grep over comments would flag the documentation of the rule it enforces.
IL_BLOCK="$WORK/integration-code.txt"
grep -v '^[[:space:]]*//' "$GUARD_REGION" > "$IL_BLOCK"
if [ ! -s "$IL_BLOCK" ]; then
  bad "could not slice the #2191 code region out of hunter.ag (header comment renamed?)"
elif grep -Eq 'exec sh|python3 -c|awk |sed -|[^a-z]date ' "$IL_BLOCK"; then
  bad "the #2191 block introduced an embedded interpreter / exec sh escape (substrate-purity ratchet)"
  grep -nE 'exec sh|python3 -c|awk |sed -|[^a-z]date ' "$IL_BLOCK" | head -3 | sed 's/^/      /' >&2
else
  ok "the #2191 block uses only native builtins (no exec sh, no embedded python3/awk/sed/date)"
fi

note "7) DECISION: no new taxonomy class — a cross-class re-framing documented as a usage note ..."
if grep -q '^## C24 ' "$TAXONOMY"; then
  bad "bug-taxonomy.md gained a '## C24 ' class — #2191 is explicitly a cross-class directive, NOT a new class"
else
  ok "bug-taxonomy.md declares no C24 class (the directive composes across classes, it does not add one)"
fi
if grep -q 'Cross-class external-integration/oracle-assumption directive (#2191' "$TAXONOMY"; then
  ok "bug-taxonomy.md's Hunter usage notes document the #2191 cross-class directive (one note, no per-class text edits)"
else
  bad "bug-taxonomy.md does not carry the #2191 Hunter usage note"
fi

note "8) the two fixtures have the shapes the detector discriminates on ..."
if grep -q 'IPool(pool).deposit(assets, true);' "$INTEGRATION" \
   && grep -q 'oracle.getPrice();' "$INTEGRATION" \
   && grep -q 'address public immutable pool;' "$INTEGRATION"; then
  ok "IntegrationVault.sol: interface-typed call + hardcoded bool arg + oracle read, immutable targets (positive arm)"
else
  bad "IntegrationVault.sol lost the interface call / hardcoded arg / oracle read it exists to carry"
fi
if ! grep -Eq '\.call\(|\.call\{|IOracle|IPool|getPrice|latestRoundData|safeTransfer' "$PLAIN"; then
  ok "PlainVault.sol: no external call surface, no oracle/valuation read (negative arm)"
else
  bad "PlainVault.sol no longer isolates the plain (no-integration) case"
fi

note "9) read-only: no network / no submission verb on the discovery path this directive rides ..."
if grep -vE '^[[:space:]]*#' "$DISCOVERY" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
  bad "a network/submission verb appears on run-discovery.sh"
else
  ok "no network / no submission verb on run-discovery.sh (read-only, never submits)"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 2 — LIVE UNDER MOCK (needs the agentis binary; clean [SKIP] otherwise)
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  note "10-12) live-under-mock sentinel discrimination + toggle suppression + byte-identity probe ..."
  skip "no agentis binary on PATH — the mock hunt cells and the extracted-helper probe cannot run"
else
  note "10) live-under-mock: one real offline hunt cell per fixture (--backend mock, HUNT_CLASS=C2) ..."
  # _arm <label> <fixture-basename> : stage a one-contract repo + scope + brief, run ONE hunter cell through
  # run-discovery.sh on the mock backend, print the cell log path.
  _arm() {
    _label="$1"; _sol="$2"
    _repo="$WORK/$_label-repo"; mkdir -p "$_repo/contracts"
    cp "$FIXDIR/$_sol.sol" "$_repo/contracts/$_sol.sol"
    printf 'vault | C2 | contracts/%s.sol\n' "$_sol" > "$WORK/$_label-scope.tsv"
    printf '# brief\nInvariants to break: minted shares are worth at most what was deposited.\nKnown issues to exclude: none.\n' \
      > "$WORK/$_label-brief.md"
    "$DISCOVERY" --repo "$_repo" --scope "$WORK/$_label-scope.tsv" --brief "$WORK/$_label-brief.md" \
      --only "vault" --classes C2 --backend mock --agentis agentis --out "$WORK/$_label" \
      > "$WORK/$_label.out" 2>&1 || true
    printf '%s\n' "$WORK/$_label/run/hunt_vault_C2.log"
  }

  INT_LOG="$(_arm integration IntegrationVault)"
  PLN_LOG="$(_arm plain PlainVault)"

  if [ ! -f "$INT_LOG" ] || [ ! -f "$PLN_LOG" ]; then
    bad "the mock hunt cells produced no cell log (run-discovery.sh did not reach hunter.ag)"
    tail -5 "$WORK/integration.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    if grep -q '^INTEGRATION-LENS|vault|C2|' "$INT_LOG"; then
      ok "integration fixture: the directive fired — $(grep -m1 '^INTEGRATION-LENS|' "$INT_LOG")"
    else
      bad "integration fixture: NO INTEGRATION-LENS| sentinel — the directive was not injected"
    fi
    # The <n> field must report the signals that actually fired (valuation read + hardcoded arg = 2).
    if grep -q '^INTEGRATION-LENS|vault|C2|2$' "$INT_LOG"; then
      ok "the sentinel reports 2 integration signals (valuation read + hardcoded call arg), not a constant"
    else
      bad "the sentinel's <n> field does not report the 2 signals this fixture carries"
    fi
    if grep -q 'INTEGRATION-LENS' "$PLN_LOG"; then
      bad "plain fixture: an INTEGRATION-LENS| sentinel appeared — the detector over-fires"
    else
      ok "plain fixture: NO INTEGRATION-LENS| sentinel (the detector does not over-fire)"
    fi
  fi

  note "10b) live-under-mock: INTEGRATION_LENS=0 suppresses the directive+sentinel even where the detector fires ..."
  OFF_LOG="$(INTEGRATION_LENS=0 _arm integration-off IntegrationVault)"
  if [ ! -f "$OFF_LOG" ]; then
    bad "the INTEGRATION_LENS=0 mock hunt cell produced no cell log (run-discovery.sh did not reach hunter.ag)"
    tail -5 "$WORK/integration-off.out" 2>/dev/null | sed 's/^/      /' >&2
  elif grep -q 'INTEGRATION-LENS' "$OFF_LOG"; then
    bad "integration fixture with INTEGRATION_LENS=0: a sentinel still appeared — the OFF toggle did not reach hunter.ag (env_passthrough gap?)"
  else
    ok "integration fixture with INTEGRATION_LENS=0: NO INTEGRATION-LENS| sentinel — the OFF arm suppresses the directive end-to-end (control arm is clean)"
  fi

  note "11) byte-identity probe: the directive is the EMPTY string on the plain fixture and under INTEGRATION_LENS=0 ..."
  # The helpers are EXTRACTED FROM hunter.ag BY LINE RANGE, so this probe measures the shipped code rather than
  # a copy that can drift (the demo-discovery-parallel.sh idiom).
  FRAG="$WORK/detector.frag"; : > "$FRAG"
  FRAG_MISS=""
  for fn in $DETECTOR_FNS; do
    awk -v want="^fn $fn\\\\(" '$0 ~ want {f=1} f{print} f&&/^}$/{exit}' "$HUNTER" >> "$FRAG"
    printf '\n' >> "$FRAG"
    grep -q "^fn $fn(" "$FRAG" || FRAG_MISS="$FRAG_MISS $fn"
  done
  if [ -n "$FRAG_MISS" ]; then
    bad "could not extract detector helpers from hunter.ag by line range (renamed?):$FRAG_MISS"
  else
    SQ="'"
    SB="$WORK/probe"; mkdir -p "$SB"
    ( cd "$SB" && agentis init >/dev/null 2>&1 ) || true
    printf 'exec.env_passthrough = FIXTURE,INTEGRATION_LENS\n' > "$SB/.agentis/config"
    {
      printf 'cb 300000;\n\n'
      cat "$FRAG"
      printf 'let p = getenv("FIXTURE");\n'
      # shellcheck disable=SC2016  # ${p} is an .ag interpolation in the generated probe, not a shell expansion
      printf 'let code = exec sh "sed -n %s1,2000p%s ${p}";\n' "$SQ" "$SQ"
      # BLOCKLEN = the raw block (detector only, toggle-independent). DIRLEN = what actually enters the prompt
      # after the INTEGRATION_LENS gate — so DIRLEN==BLOCKLEN proves the default is byte-identical, and DIRLEN==0
      # (under INTEGRATION_LENS=0) proves the OFF arm suppresses even a firing detector.
      printf 'print("BLOCKLEN=" + to_string(len(integration_assumption_block(has_external_integration_surface(code)))));\n'
      printf 'print("DIRLEN=" + to_string(len(integration_directive(code))));\n'
    } > "$SB/probe.ag"
    _blocklen() {
      _bl="$( cd "$SB" && FIXTURE="$1" agentis go probe.ag --enable-exec 2>&1 | grep '^BLOCKLEN=' | tail -1 )"  # no-pii: the probe never calls prompt() — it only reads a checked-in Solidity fixture and prints a length
      printf '%s\n' "${_bl#BLOCKLEN=}"
    }
    # _dirlen <fixture> <integration-lens-value|"">: the toggle-gated directive length. An empty second argument
    # runs with INTEGRATION_LENS UNSET (the default-ON case).
    _dirlen() {
      if [ -n "$2" ]; then
        _dl="$( cd "$SB" && FIXTURE="$1" INTEGRATION_LENS="$2" agentis go probe.ag --enable-exec 2>&1 | grep '^DIRLEN=' | tail -1 )"  # no-pii: length-only probe, no prompt()
      else
        _dl="$( cd "$SB" && FIXTURE="$1" agentis go probe.ag --enable-exec 2>&1 | grep '^DIRLEN=' | tail -1 )"  # no-pii: length-only probe, no prompt()
      fi
      printf '%s\n' "${_dl#DIRLEN=}"
    }
    INT_LEN="$(_blocklen "$INTEGRATION")"
    PLN_LEN="$(_blocklen "$PLAIN")"
    case "$PLN_LEN" in
      0) ok "plain fixture: the injected block is \"\" (0 bytes) — concatenating it is a no-op, so the prompt is byte-identical to the pre-#2191 one" ;;
      ''|*[!0-9]*) bad "the byte-identity probe did not complete on the plain fixture (got '$PLN_LEN')" ;;
      *) bad "plain fixture: the injected block is $PLN_LEN bytes — the prompt is NOT byte-identical" ;;
    esac
    case "$INT_LEN" in
      ''|*[!0-9]*) bad "the byte-identity probe did not complete on the integration fixture (got '$INT_LEN')" ;;
      0) bad "integration fixture: the injected block is empty — the directive would never reach a prompt" ;;
      *) ok "integration fixture: the injected block is $INT_LEN bytes (the directive is really assembled)" ;;
    esac

    note "11b) INTEGRATION_LENS toggle: default-ON is byte-identical, INTEGRATION_LENS=0 suppresses a firing detector ..."
    DIR_DEFAULT="$(_dirlen "$INTEGRATION" "")"
    if [ "$DIR_DEFAULT" = "$INT_LEN" ] && [ "$INT_LEN" != "0" ] 2>/dev/null; then
      ok "INTEGRATION_LENS unset (default): integration_directive() = $DIR_DEFAULT bytes = the raw block — byte-identical to pre-#2191"
    else
      bad "INTEGRATION_LENS unset: integration_directive() ($DIR_DEFAULT) != the raw block ($INT_LEN) — the default is NOT byte-identical"
    fi
    DIR_OFF="$(_dirlen "$INTEGRATION" "0")"
    case "$DIR_OFF" in
      0) ok "INTEGRATION_LENS=0 on the integration fixture: integration_directive() is \"\" (0 bytes) — the OFF arm is byte-identical to the no-directive case even where the detector fires" ;;
      ''|*[!0-9]*) bad "the toggle probe did not complete under INTEGRATION_LENS=0 (got '$DIR_OFF')" ;;
      *) bad "INTEGRATION_LENS=0: integration_directive() is $DIR_OFF bytes on the integration fixture — the OFF arm does NOT suppress the directive" ;;
    esac
    DIR_ON="$(_dirlen "$INTEGRATION" "1")"
    if [ "$DIR_ON" = "$INT_LEN" ] 2>/dev/null; then
      ok "INTEGRATION_LENS=1: integration_directive() = $DIR_ON bytes = the raw block (any non-0 value is ON)"
    else
      bad "INTEGRATION_LENS=1: integration_directive() ($DIR_ON) != the raw block ($INT_LEN)"
    fi
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the #2191 external-integration/oracle-assumption directive (detector, \"\"-gate, toggle, splice, INTEGRATION-LENS sentinel, overfitting guard) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
