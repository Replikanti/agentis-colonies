#!/usr/bin/env bash
# demo-callee-trust-lens.sh — the OFFLINE gate for the #2145 ATTACKER-CONTROLLED-CALLEE directive
# (milestone D1 of epic #2130).
#
# What the change is: hunter.ag gained a deterministic settable-callee detector and a GENERIC trust-model
# directive it injects into the shared hunt instruction — "for every external call, ask who controls the
# TARGET address; a config/admin/deployer/oracle/registry-settable callee is ATTACKER-CONTROLLED for
# reentrancy, return-value and gas purposes, even though the SETTER is a trusted role". The directive is
# `""`-gated, so a zone without a settable call target prompts byte-for-byte as it did before, and a
# `CALLEE-TRUST|<subsystem>|<cls>|<n>` sentinel makes the injection observable in the cell log.
#
# This demo proves the MACHINERY, never the capability. Whether the directive actually makes a hunter
# GENERATE the vector it was missing is only provable by a sandboxed, refusal-fallback-off,
# transcript-attributed live re-hunt of a post-cutoff held-out target — an operator step, deliberately NOT
# a CI gate (a mock backend does not reason).
#
# Two parts:
#   1) SOURCE-GUARD (the CI floor — pure grep/awk: no agentis, no forge, no network). The detector helpers,
#      the directive's load-bearing sentences, the ""-when-false gate, the splice position, the sentinel and
#      its honesty gate, substrate purity, the two fixtures' shapes, and the decision that the taxonomy gains
#      NO new class (this is a cross-class re-framing, not a lens-per-class addition).
#   2) LIVE-UNDER-MOCK ([SKIP] without an `agentis` binary). One REAL offline hunt cell per fixture through
#      run-discovery.sh --backend mock --classes C8: the sentinel MUST be printed for the settable-callee
#      fixture and MUST be ABSENT for the immutable-callee one. Plus a BYTE-IDENTITY probe that runs the
#      detector helpers EXTRACTED FROM hunter.ag BY LINE RANGE (the repo's `f&&/^}$/{exit}` idiom, so a
#      copy-pasted twin cannot drift from the agent it claims to measure) over each fixture and asserts the
#      injected block is the EMPTY string on the immutable arm — concatenating "" into the instruction is a
#      no-op, which is what "the prompt is byte-identical" means here.
#
# Usage:  dark-factory/demo-callee-trust-lens.sh
# Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HUNTER="$HERE/auditor/agents/hunter.ag"
TAXONOMY="$HERE/auditor/bug-taxonomy.md"
DISCOVERY="$HERE/run-discovery.sh"
FIXDIR="$HERE/fixtures/callee-trust/contracts"
SETTABLE="$FIXDIR/SettableOracleVault.sol"
IMMUTABLE="$FIXDIR/ImmutableOracleVault.sol"
TRANSITIVE="$FIXDIR/TransitiveOracleVault.sol"

FAILS=0
note() { echo "demo-callee-trust-lens.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for f in "$HUNTER" "$TAXONOMY" "$DISCOVERY" "$SETTABLE" "$IMMUTABLE" "$TRANSITIVE"; do
  [ -f "$f" ] || { note "required file not found: $f" >&2; exit 3; }
done

WORK="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# The multi-line `"..." + "..."` string joins are flattened first, so an assertion can match the PROMPT text
# the model actually receives rather than one source line of it (same idiom as demo-external-assumption-lens).
HUNTER_FLAT="$(tr '\n' ' ' < "$HUNTER" | sed 's/"[[:space:]]*+[[:space:]]*"//g')"

# ----------------------------------------------------------------------------------------------------------
# PART 1 — SOURCE-GUARD (CI floor: grep/awk only)
# ----------------------------------------------------------------------------------------------------------
note "1) hunter.ag declares the settable-callee detector helpers ..."
DETECTOR_FNS="has_low_level_call_surface interface_call_pattern is_view_idiom_method has_interface_call_surface has_call_surface address_setter_pattern has_address_setter mutable_address_state_pattern has_mutable_address_state computed_target_pattern is_plain_cast_callee has_computed_call_target signal_score settable_signal_count has_settable_target has_attacker_controlled_callee callee_trust_marker callee_trust_block"
MISSING_FN=""
for fn in $DETECTOR_FNS; do
  grep -q "^fn $fn(" "$HUNTER" || MISSING_FN="$MISSING_FN $fn"
done
if [ -z "$MISSING_FN" ]; then
  ok "all 18 detector/directive helpers are declared in hunter.ag"
else
  bad "hunter.ag is missing detector helper(s):$MISSING_FN"
fi

# The detector is an AND of a call surface and a settable-target signal — never one of them alone. A net that
# fired on "there is an external call" would inject the directive into essentially every zone.
if grep -A3 '^fn has_attacker_controlled_callee(' "$HUNTER" | grep -q 'if !has_call_surface(code) { return false; }' \
   && grep -A3 '^fn has_attacker_controlled_callee(' "$HUNTER" | grep -q 'return has_settable_target(code);'; then
  ok "has_attacker_controlled_callee() = call surface AND settable target (not a bare call-surface net)"
else
  bad "has_attacker_controlled_callee() no longer ANDs the call surface with a settable-target signal"
fi

# The three settable-target signals are each independently reachable, and their count is what the sentinel
# reports. Losing one silently narrows the detector without changing any assertion about "it still fires".
SIG_MISS=""
for sig in has_address_setter has_mutable_address_state has_computed_call_target; do
  grep -A4 '^fn settable_signal_count(' "$HUNTER" | grep -q "$sig(code)" || SIG_MISS="$SIG_MISS $sig"
done
if [ -z "$SIG_MISS" ]; then
  ok "settable_signal_count() sums all three settable-target signals (setter / mutable state / computed target)"
else
  bad "settable_signal_count() dropped signal(s):$SIG_MISS"
fi

note "2) the directive carries its load-bearing sentences ..."
DIRECTIVE_MISS=""
for s in \
  "=== WHO CONTROLS THE CALL TARGET? ===" \
  "ask WHO CONTROLS THE CALLEE" \
  "treat the CALLEE'S BEHAVIOUR as ATTACKER-CONTROLLED" \
  "This stays IN SCOPE even though the SETTER is a trusted role" \
  "Do NOT invent a callee"
do
  case "$HUNTER_FLAT" in *"$s"*) ;; *) DIRECTIVE_MISS="$DIRECTIVE_MISS [$s]" ;; esac
done
if [ -z "$DIRECTIVE_MISS" ]; then
  ok "the directive keeps its header, its who-controls-the-callee question, the hostile-callee framing, the trusted-setter override and the do-not-invent guard"
else
  bad "the directive lost load-bearing text:$DIRECTIVE_MISS"
fi

# GENERICITY is what makes injecting this safe on a held-out target: a directive naming a protocol, contract
# or function would hand the model the answer and invalidate any live measurement taken with it on. Sliced
# from the block itself, not from the file, so surrounding comments are free to be specific.
BLOCK_BODY="$WORK/callee-trust-body.txt"
awk '/^fn callee_trust_block\(/{f=1} f{print} f&&/^}$/{exit}' "$HUNTER" > "$BLOCK_BODY"
if [ ! -s "$BLOCK_BODY" ]; then
  bad "could not slice callee_trust_block() out of hunter.ag"
elif grep -Eq 'Royco|getCollateralAssetOracle|executeDeposit|IRoycoPriceOracle|\.sol' "$BLOCK_BODY"; then
  bad "the directive block names a target-specific contract/function (it would leak an answer into a hunt)"
  grep -nE 'Royco|getCollateralAssetOracle|executeDeposit|IRoycoPriceOracle|\.sol' "$BLOCK_BODY" | head -3 | sed 's/^/      /' >&2
else
  ok "the directive names no target-specific contract/function (generic — injecting it cannot leak an answer)"
fi

note "3) the \"\"-when-false gate and the splice position ..."
if grep -A2 '^fn callee_trust_block(' "$HUNTER" | grep -q 'if !has { return ""; }'; then
  ok "callee_trust_block() returns \"\" when the detector found nothing (undetected zones prompt byte-identical)"
else
  bad "callee_trust_block() lost its \"\"-when-false early return — an undetected zone's prompt would change"
fi

# The block is spliced as a bare `+ callee` term, which is what makes the empty string a no-op, and it sits
# directly after the role preamble so it frames the WHOLE hunt (every class), ahead of `focus`/`depth`/`appx`.
if grep -q '^  + callee$' "$HUNTER" && grep -A1 '^  + callee$' "$HUNTER" | grep -q '^  + focus$'; then
  ok "the directive is spliced as a bare '+ callee' term immediately before '+ focus' (frames the whole hunt)"
else
  bad "the '+ callee' splice is gone or no longer sits directly before '+ focus' in the instruction chain"
fi
if grep -q 'let callee = callee_trust_block(has_attacker_controlled_callee(code));' "$HUNTER"; then
  ok "the block is derived from the detector over the assembled payload, once per cell"
else
  bad "the 'let callee = callee_trust_block(has_attacker_controlled_callee(code));' binding is gone"
fi

note "4) the CALLEE-TRUST sentinel and its honesty gate ..."
if grep -q 'print("CALLEE-TRUST|" + subsystem + "|" + cls + "|" + to_string(settable_signal_count(code)));' "$HUNTER"; then
  ok "the sentinel is printed as CALLEE-TRUST|<subsystem>|<cls>|<n>"
else
  bad "the CALLEE-TRUST|<subsystem>|<cls>|<n> sentinel emission is gone or reshaped"
fi
# Gated on the marker being IN the assembled instruction, never on the detector's return value — the same
# honesty contract APPENDIX-CONTEXT| carries, so a cell log can never claim a re-framing that was not sent.
if grep -B1 'print("CALLEE-TRUST|"' "$HUNTER" | grep -q 'if index_of(instruction, callee_trust_marker()) >= 0 {'; then
  ok "the sentinel is gated on the marker actually being in the assembled instruction (index_of), not on the detector flag"
else
  bad "the CALLEE-TRUST sentinel is no longer gated on the marker being present in the assembled instruction"
fi
# A diagnostic carrying `CANDIDATE|` would let lib/run-agent-validated.sh's sentinel predicate false-accept a
# cell that never produced a finding.
if grep 'print("CALLEE-TRUST|"' "$HUNTER" | grep -q 'CANDIDATE|'; then
  bad "the CALLEE-TRUST sentinel carries a 'CANDIDATE|' substring (would false-accept a cell)"
else
  ok "the sentinel carries no 'CANDIDATE|' substring (cannot false-accept a cell)"
fi
if grep -q 'CALLEE-TRUST|<subsystem>|<cls>|<n>' "$HUNTER"; then
  ok "hunter.ag's header documents CALLEE-TRUST| among the diagnostics that may precede the verdict"
else
  bad "hunter.ag's header Stdout contract does not mention the CALLEE-TRUST| diagnostic"
fi

note "5) the sentinel is a RECORD BOUNDARY in run-discovery.sh (#2147) ..."
# hunter.ag's comment claims the sentinel is treated as a record boundary by _join_wrapped_candidates. That
# claim has to be enforced, not merely written: the sentinel is printed BEFORE prompt() today, so a missing
# boundary is currently harmless — and would stay invisible until an ordering change glued a CALLEE-TRUST|
# line onto an open CANDIDATE| record as prose.
BOUNDARY_LINE="$(grep -n 'BLACKBOARD-/ ||' "$DISCOVERY" | head -1 | cut -d: -f2-)"
case "$BOUNDARY_LINE" in
  *'CALLEE-TRUST\|'*) ok "run-discovery.sh's _join_wrapped_candidates boundary alternation lists CALLEE-TRUST| next to the sibling sentinels" ;;
  '') bad "could not find the _join_wrapped_candidates boundary alternation in run-discovery.sh" ;;
  *) bad "the _join_wrapped_candidates boundary alternation does NOT list CALLEE-TRUST| — the sentinel could be glued onto an open CANDIDATE| record" ;;
esac

# Behavioural half: run the SHIPPED awk program (sliced out of run-discovery.sh, so a copy-pasted twin cannot
# drift from it) over a synthetic PTY-wrapped CANDIDATE followed by the sentinel. Pure awk — no agentis, no
# forge, no network — so it stays in the CI floor.
JWC_AWK="$WORK/join-wrapped.awk"
sed -n '/^_join_wrapped_candidates() {$/,/^}$/p' "$DISCOVERY" \
  | sed -n "/^  awk '$/,/^  ' /p" | sed "1d; \$d" > "$JWC_AWK"
WRAP_LOG="$WORK/wrapped-cell.log"
{
  printf 'CALLEE-TRUST|vault|C8|2\n'
  printf 'CANDIDATE|Vault.sol:deposit:41|C8|High|reenter deposit through the settable oracle callee|deploy a\n'
  printf '  hostile oracle, call deposit, reenter and assert the stale balance\n'
  printf 'CALLEE-TRUST|vault|C8|2\n'
  printf 'SAFE\n'
} > "$WRAP_LOG"
if [ ! -s "$JWC_AWK" ]; then
  bad "could not extract the _join_wrapped_candidates awk program from run-discovery.sh (reshaped?)"
else
  JOINED="$(awk -f "$JWC_AWK" "$WRAP_LOG")"
  JOINED_N="$(printf '%s\n' "$JOINED" | grep -c 'CANDIDATE|')"
  if [ "$JOINED_N" -ne 1 ]; then
    bad "the wrapped record did not reconstruct into exactly one CANDIDATE| line (got $JOINED_N)"
  elif printf '%s' "$JOINED" | grep -q 'CALLEE-TRUST'; then
    bad "a CALLEE-TRUST| line was glued onto the open CANDIDATE| record as prose (the boundary does not hold)"
  elif printf '%s' "$JOINED" | grep -q 'assert the stale balance'; then
    ok "a CALLEE-TRUST| line after a PTY-wrapped CANDIDATE closes the record: one joined candidate, wrapped tail kept, no sentinel text in it"
  else
    bad "the wrapped continuation line was lost while joining the record"
  fi
fi

note "6) substrate purity (#1587): the detector is builtins-only ..."
# CODE lines only: the block's own prose legitimately discusses `exec sh` and interpreters, and a grep over
# comments would flag the documentation of the very rule it is enforcing.
CT_BLOCK="$WORK/callee-trust-block.txt"
awk '/--- #2145 ATTACKER-CONTROLLED-CALLEE DIRECTIVE/{f=1} f&&/^let dir = getenv\("TARGET_DIR"\);$/{exit} f{print}' \
  "$HUNTER" | grep -v '^[[:space:]]*//' > "$CT_BLOCK"
if [ ! -s "$CT_BLOCK" ]; then
  bad "could not slice the #2145 block out of hunter.ag (header comment renamed?)"
elif grep -Eq 'exec sh|python3 -c|awk |sed -|[^a-z]date ' "$CT_BLOCK"; then
  bad "the #2145 block introduced an embedded interpreter / exec sh escape (substrate-purity ratchet)"
  grep -nE 'exec sh|python3 -c|awk |sed -|[^a-z]date ' "$CT_BLOCK" | head -3 | sed 's/^/      /' >&2
else
  ok "the #2145 block uses only native builtins (no exec sh, no embedded python3/awk/sed/date)"
fi

note "7) DECISION: no new taxonomy class — this is a cross-class re-framing, not a lens-per-class addition ..."
if grep -q '^## C24 ' "$TAXONOMY"; then
  bad "bug-taxonomy.md gained a '## C24 ' class — D1 is explicitly a directive, NOT a new class"
else
  ok "bug-taxonomy.md declares no C24 class (the directive replaces a per-class lens, per epic #2130)"
fi
if grep -qi 'CALLEE-TRUST\|attacker-controlled callee' "$TAXONOMY"; then
  bad "bug-taxonomy.md was edited for #2145 — the re-framing belongs in the shared hunter instruction"
else
  ok "bug-taxonomy.md carries no #2145 text (untouched by this change)"
fi

note "8) the two fixtures have the shapes the detector discriminates on ..."
if grep -q 'function setOracle(address newOracle) external' "$SETTABLE" \
   && grep -q '^    address public oracle;$' "$SETTABLE" \
   && grep -q 'IOracle(oracle).poke();' "$SETTABLE"; then
  ok "SettableOracleVault.sol: interface-typed call + address setter + mutable address state (positive arm)"
else
  bad "SettableOracleVault.sol lost the setter / mutable address state / interface-typed call it exists to carry"
fi
if grep -q '^    address public immutable oracle;$' "$IMMUTABLE" \
   && grep -q 'IOracle(oracle).poke();' "$IMMUTABLE" \
   && ! grep -q 'function set' "$IMMUTABLE"; then
  ok "ImmutableOracleVault.sol: same call shape, immutable target, no setter (negative arm)"
else
  bad "ImmutableOracleVault.sol no longer isolates the immutable-target case (same call shape, no setter)"
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
  note "10-12) live-under-mock sentinel discrimination + callee-closure arm + byte-identity probe ..."
  skip "no agentis binary on PATH — the mock hunt cells and the extracted-helper probe cannot run"
else
  note "10) live-under-mock: one real offline hunt cell per fixture (--backend mock, HUNT_CLASS=C8) ..."
  # _arm <label> <fixture-basename> [<scope-token>]: stage a one-contract repo + scope + brief, run ONE hunter
  # cell through run-discovery.sh on the mock backend, print the cell log path. The optional third argument
  # overrides the scope token, so an arm can hand the cell a FUNCTION-SLICED `file@fn` entry (#2150) instead of
  # the whole file.
  _arm() {
    _label="$1"; _sol="$2"; _tok="${3:-contracts/$_sol.sol}"
    _repo="$WORK/$_label-repo"; mkdir -p "$_repo/contracts"
    cp "$FIXDIR/$_sol.sol" "$_repo/contracts/$_sol.sol"
    printf 'vault | C8 | %s\n' "$_tok" > "$WORK/$_label-scope.tsv"
    printf '# brief\nInvariants to break: share accounting is conserved.\nKnown issues to exclude: none.\n' \
      > "$WORK/$_label-brief.md"
    "$DISCOVERY" --repo "$_repo" --scope "$WORK/$_label-scope.tsv" --brief "$WORK/$_label-brief.md" \
      --only "vault" --classes C8 --backend mock --agentis agentis --out "$WORK/$_label" \
      > "$WORK/$_label.out" 2>&1 || true
    printf '%s\n' "$WORK/$_label/run/hunt_vault_C8.log"
  }

  SET_LOG="$(_arm settable SettableOracleVault)"
  IMM_LOG="$(_arm immutable ImmutableOracleVault)"

  if [ ! -f "$SET_LOG" ] || [ ! -f "$IMM_LOG" ]; then
    bad "the mock hunt cells produced no cell log (run-discovery.sh did not reach hunter.ag)"
    tail -5 "$WORK/settable.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    if grep -q '^CALLEE-TRUST|vault|C8|' "$SET_LOG"; then
      ok "settable-callee fixture: the directive fired — $(grep -m1 '^CALLEE-TRUST|' "$SET_LOG")"
    else
      bad "settable-callee fixture: NO CALLEE-TRUST| sentinel — the directive was not injected"
    fi
    # The <n> field must report the signals that actually fired (setter + mutable address state = 2), not a
    # constant: a hardcoded count would make the cell log unable to say WHY the directive fired.
    if grep -q '^CALLEE-TRUST|vault|C8|2$' "$SET_LOG"; then
      ok "the sentinel reports 2 settable-target signals (setter + mutable address state), not a constant"
    else
      bad "the sentinel's <n> field does not report the 2 signals this fixture carries"
    fi
    if grep -q 'CALLEE-TRUST' "$IMM_LOG"; then
      bad "immutable-callee fixture: a CALLEE-TRUST| sentinel appeared — the detector over-fires"
    else
      ok "immutable-callee fixture: NO CALLEE-TRUST| sentinel (the detector does not over-fire)"
    fi
  fi

  note "11) live-under-mock: the detector fires THROUGH the slicer's same-file callee closure (#2150) ..."
  # The zone is scoped `contracts/TransitiveOracleVault.sol@deposit` — the external entry point ONLY. Its body
  # holds no external call; the computed-target poke lives one hop away in the internal `_settleOracle` helper,
  # which slice-fns.sh's #2150 closure has to pull into the payload for the detector to have anything to see.
  # This is the arm that fails on the pre-#2150 slicer, and it exercises the REAL path
  # (run-discovery.sh -> hunter.ag cat_file -> `sh slice-fns.sh <file> '<fns>'`), not the slicer in isolation.
  TRANS_LOG="$(_arm transitive TransitiveOracleVault "contracts/TransitiveOracleVault.sol@deposit")"
  if [ ! -f "$TRANS_LOG" ]; then
    bad "the function-sliced mock hunt cell produced no cell log (run-discovery.sh did not reach hunter.ag)"
    tail -5 "$WORK/transitive.out" 2>/dev/null | sed 's/^/      /' >&2
  elif grep -q '^CALLEE-TRUST|vault|C8|1$' "$TRANS_LOG"; then
    # <n>=1 pins WHICH signal fired: the computed target, which exists only inside the closure-pulled helper.
    # A 2 or 3 here would mean the fixture leaked a setter or a mutable address state variable into the header
    # and the arm would prove nothing about the closure.
    ok "a file@fn scope entry naming only the entry point still reaches the callee: CALLEE-TRUST|vault|C8|1 (computed target, one hop away)"
  elif grep -q '^CALLEE-TRUST|' "$TRANS_LOG"; then
    bad "the sentinel fired with the wrong signal count — the fixture leaked a setter/mutable-address signal into the header: $(grep -m1 '^CALLEE-TRUST|' "$TRANS_LOG")"
  else
    bad "NO CALLEE-TRUST| sentinel on the function-sliced cell — the same-file callee closure (#2150) did not put _settleOracle in the payload"
  fi

  note "12) byte-identity probe: the directive is the EMPTY string on the immutable-callee fixture ..."
  # The helpers are EXTRACTED FROM hunter.ag BY LINE RANGE, so this probe measures the shipped code rather
  # than a copy that can drift (the demo-discovery-parallel.sh 18g idiom).
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
    printf 'exec.env_passthrough = FIXTURE\n' > "$SB/.agentis/config"
    {
      printf 'cb 300000;\n\n'
      cat "$FRAG"
      printf 'let p = getenv("FIXTURE");\n'
      # The probe reads the fixture the same way hunter.ag's cat_file() does. SQ keeps the single quotes
      # out of the format string (literal glyphs only — no \xHH escapes, which dash's printf does not expand).
      # shellcheck disable=SC2016  # ${p} is an .ag interpolation in the generated probe, not a shell expansion
      printf 'let code = exec sh "sed -n %s1,2000p%s ${p}";\n' "$SQ" "$SQ"
      printf 'print("BLOCKLEN=" + to_string(len(callee_trust_block(has_attacker_controlled_callee(code)))));\n'
    } > "$SB/probe.ag"
    _blocklen() {
      _bl="$( cd "$SB" && FIXTURE="$1" agentis go probe.ag --enable-exec 2>&1 | grep '^BLOCKLEN=' | tail -1 )"  # no-pii: the probe never calls prompt() — it only reads a checked-in Solidity fixture and prints a length
      printf '%s\n' "${_bl#BLOCKLEN=}"
    }
    SET_LEN="$(_blocklen "$SETTABLE")"
    IMM_LEN="$(_blocklen "$IMMUTABLE")"
    case "$IMM_LEN" in
      0) ok "immutable-callee fixture: the injected block is \"\" (0 bytes) — concatenating it is a no-op, so the prompt is byte-identical to the pre-#2145 one" ;;
      ''|*[!0-9]*) bad "the byte-identity probe did not complete on the immutable-callee fixture (got '$IMM_LEN')" ;;
      *) bad "immutable-callee fixture: the injected block is $IMM_LEN bytes — the prompt is NOT byte-identical" ;;
    esac
    case "$SET_LEN" in
      ''|*[!0-9]*) bad "the byte-identity probe did not complete on the settable-callee fixture (got '$SET_LEN')" ;;
      0) bad "settable-callee fixture: the injected block is empty — the directive would never reach a prompt" ;;
      *) ok "settable-callee fixture: the injected block is $SET_LEN bytes (the directive is really assembled)" ;;
    esac
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the #2145 attacker-controlled-callee directive (detector, \"\"-gate, splice, CALLEE-TRUST sentinel) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
