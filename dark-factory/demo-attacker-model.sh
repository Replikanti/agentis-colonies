#!/usr/bin/env bash
# demo-attacker-model.sh — the gate for the #2373 "DERIVE THE ATTACKER MODEL" generation directive.
#
# What the change is: hunter.ag gained a PURE-META directive, gated by `ATTACKER_MODEL=1` (default OFF), that asks
# the hunter to write down the attacker model PER FUNCTION before it proposes any mechanism, as one
# `PRECOND|<file:function>|caller=..|state=..|timing=..|config=..|input=..` line per in-scope function; to name, on
# every CANDIDATE line, the PRECOND field the mechanism exploits; and to re-argue each of its own `no-loss` / `guard`
# dismissals against those fields, logging each re-check as `RECHECK|<file:function[:line]>|<no-loss|guard>|
# <fields>|<kept|reopened>`. An honesty-gated `PRECOND-STEP|<subsystem>|<cls>|on` sentinel makes the injection
# observable in the cell log. Why: #2311's corrected verdict selected the GENERATION lever, and the hint that
# recovered rows there was the attacker's capability or precondition (L2), not the bug class (L1).
#
# The default is OFF on purpose and is NOT a defect this gate should "fix": the step is UNMEASURED, and #2211/#2213
# showed a generation directive can be net-negative. The default flips only if #2373's pre-registered rule says so.
# Parts 1-2 prove the MACHINERY; part 3 proves the model COMPLIES. None of it proves recall.
#
# Three parts:
#   1) SOURCE-GUARD (the CI floor: grep/awk only, no agentis, no forge, no network). The four helpers, the
#      marker/sentinel coupling, the `== "1"` (default-OFF) polarity, the ""-when-disabled gate, the splice directly
#      above the lens, the env_passthrough registration, the three new record boundaries, token distinctness, the
#      load-bearing sentences, an OVERFITTING denylist, substrate purity, and synthetic logs through the SHIPPED
#      `_join_wrapped_candidates` and `_distinct_sentinel_count`, both sliced out of run-discovery.sh by line range.
#   2) LIVE-UNDER-MOCK ([SKIP] without an `agentis` binary). Real hunt cells through run-discovery.sh --backend mock:
#      `PRECOND-STEP|` present with ATTACKER_MODEL=1, absent when unset or "0". Plus a DIRLEN byte-identity probe
#      over the helpers EXTRACTED FROM hunter.ag by line range (unset, "", "0", "2", "true" are all 0 bytes).
#   3) LIVE-AGENT MUTATION ([SKIP] without `flat-cyborg` + `agentis`). Each fixture runs twice, only the flag flips:
#      (i)  PRECOND half: ON emits a PRECOND| line for every in-scope function before the first CANDIDATE|/SAFE;
#           OFF emits no PRECOND| and no RECHECK|.
#      (ii) RECHECK half, run with SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 as in the measured arms: (a) every
#           `no-loss`/`guard` DISMISS| has a RECHECK| for the same file:function, (b) every RECHECK| ends in
#           kept|reopened and every reopened function has its own CANDIDATE| line, (c) at least one RECHECK| exists.
#           A live model cannot be forced to dismiss: with no `no-loss`/`guard` DISMISS after one retry, (c) is
#           reported [INCONCLUSIVE], never [PASS]. (a) and (b) still fail hard.
#
# Usage:  dark-factory/demo-attacker-model.sh
#         DEMO_EVIDENCE_DIR=<dir> keeps a copy of part 3's cell logs (the work dir itself is always removed).
# Exit: 0 = all assertions held (an [INCONCLUSIVE] line is not a failure); non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HUNTER="$HERE/auditor/agents/hunter.ag"
DISCOVERY="$HERE/run-discovery.sh"
CHANGELOG="$HERE/CHANGELOG.md"
OPZ_FIXDIR="$HERE/fixtures/operationalize/contracts"
AM_FIXDIR="$HERE/fixtures/attacker-model/contracts"
PAIRED="$OPZ_FIXDIR/PairedPoolVault.sol"
GUARDED="$AM_FIXDIR/GuardedVault.sol"

FAILS=0
INCONCLUSIVE=0
note() { echo "demo-attacker-model.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }
inconclusive() { echo "  [INCONCLUSIVE] $*"; INCONCLUSIVE=$((INCONCLUSIVE + 1)); }

# Hermetic arms: every arm below sets the knobs it needs on its own command line, so a value exported in the
# caller's shell can never turn an OFF arm ON.
unset ATTACKER_MODEL SEVERITY_RUBRIC GROUND_EVIDENCE

for f in "$HUNTER" "$DISCOVERY" "$CHANGELOG" "$PAIRED" "$GUARDED"; do
  [ -f "$f" ] || { note "required file not found: $f" >&2; exit 3; }
done

WORK="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# The multi-line `"..." + "..."` string joins are flattened first, so an assertion matches the PROMPT text the model
# receives rather than one source line of it (the demo-operationalize-lens.sh idiom).
HUNTER_FLAT="$(tr '\n' ' ' < "$HUNTER" | sed 's/"[[:space:]]*+[[:space:]]*"//g')"
MARKER_WANT="=== DERIVE THE ATTACKER MODEL (per function, before mechanisms) ==="

# ----------------------------------------------------------------------------------------------------------
# PART 1 — SOURCE-GUARD (CI floor: grep/awk only)
# ----------------------------------------------------------------------------------------------------------
note "1) hunter.ag declares the four #2373 helpers ..."
AM_FNS="attacker_model_marker attacker_model_block attacker_model_enabled attacker_model_directive"
MISSING_FN=""
for fn in $AM_FNS; do
  grep -q "^fn $fn(" "$HUNTER" || MISSING_FN="$MISSING_FN $fn"
done
if [ -z "$MISSING_FN" ]; then
  ok "all 4 marker/block/toggle/directive helpers are declared in hunter.ag"
else
  bad "hunter.ag is missing #2373 helper(s):$MISSING_FN"
fi
# No detector, deliberately: the flag is the only gate, which keeps the OFF->ON measurement single-variable.
if grep -A3 '^fn attacker_model_directive(' "$HUNTER" | grep -qi 'code\|detector\|has_'; then
  bad "attacker_model_directive() grew a payload/detector argument — the flag must stay the ONLY gate"
else
  ok "attacker_model_directive() takes no payload and consults no detector (the flag is the only gate)"
fi

note "2) the marker IS the block's literal first line, and IS what the sentinel greps ..."
if grep -A2 '^fn attacker_model_block(' "$HUNTER" | grep -q 'return attacker_model_marker() + "\\n"'; then
  ok "attacker_model_block() opens with attacker_model_marker() (a reword cannot desync the sentinel gate)"
else
  bad "attacker_model_block() no longer opens with attacker_model_marker() — the sentinel could claim a frame that was not injected, or never fire"
fi
MARKER="$(sed -n '/^fn attacker_model_marker(/,/^}$/p' "$HUNTER" | sed -n 's/^[[:space:]]*return "\(.*\)";$/\1/p')"
if [ "$MARKER" = "$MARKER_WANT" ]; then
  ok "attacker_model_marker() is the planned literal '$MARKER_WANT'"
else
  bad "attacker_model_marker() is '$MARKER', not the planned literal — the sentinel keys on it"
fi
if [ -n "$MARKER" ]; then
  case "$HUNTER_FLAT" in
    *"$MARKER"*) ok "the marker literal is a substring of the rendered text (index_of can match it)" ;;
    *) bad "the marker literal is NOT a substring of the rendered text — the sentinel would never fire" ;;
  esac
fi

note "3) default-OFF polarity: only the literal \"1\" opts in ..."
if grep -A2 '^fn attacker_model_enabled(' "$HUNTER" | grep -q 'return getenv("ATTACKER_MODEL") == "1";'; then
  ok "attacker_model_enabled() is getenv(\"ATTACKER_MODEL\") == \"1\" — unset/\"\"/\"0\"/\"2\"/any other value = OFF = the default"
else
  bad "attacker_model_enabled() no longer reads == \"1\" — the directive would not be default-OFF"
fi
if grep -A2 '^fn attacker_model_enabled(' "$HUNTER" | grep -q '!= "0"'; then
  bad "attacker_model_enabled() was flipped to the default-ON (!= \"0\") polarity — #2373 ships OPT-IN until measured"
else
  ok "the toggle was NOT \"fixed\" into the default-ON polarity of CALLEE_TRUST"
fi
if grep -A2 '^fn attacker_model_directive(' "$HUNTER" | grep -q 'if !attacker_model_enabled() { return ""; }'; then
  ok "attacker_model_directive() returns \"\" when the flag is off (an OFF cell prompts byte-identical)"
else
  bad "attacker_model_directive() lost its \"\"-when-disabled early return — the default arm's prompt would change"
fi

note "4) the splice: bound after 'let opz', concatenated between '+ opz' and the lens header ..."
OPZ_LET_N="$(grep -n '^let opz = operationalize_directive();$' "$HUNTER" | head -1 | cut -d: -f1)"
AM_LET_N="$(grep -n '^let amodel = attacker_model_directive();$' "$HUNTER" | head -1 | cut -d: -f1)"
if [ -n "$OPZ_LET_N" ] && [ -n "$AM_LET_N" ] && [ "$AM_LET_N" -gt "$OPZ_LET_N" ]; then
  ok "'let amodel = attacker_model_directive();' (line $AM_LET_N) is bound after 'let opz' (line $OPZ_LET_N)"
else
  bad "the 'let amodel = attacker_model_directive();' binding is missing or precedes 'let opz' (amodel@'$AM_LET_N' opz@'$OPZ_LET_N')"
fi
OPZ_CAT_N="$(grep -n '^  + opz$' "$HUNTER" | head -1 | cut -d: -f1)"
AM_CAT_N="$(grep -n '^  + amodel$' "$HUNTER" | head -1 | cut -d: -f1)"
LENS_N="$(grep -n '^  + "=== HUNT THIS BUG CLASS (the lens) ===' "$HUNTER" | head -1 | cut -d: -f1)"
if [ -n "$OPZ_CAT_N" ] && [ -n "$AM_CAT_N" ] && [ -n "$LENS_N" ] \
   && [ "$AM_CAT_N" -eq $((OPZ_CAT_N + 1)) ] && [ "$LENS_N" -eq $((AM_CAT_N + 1)) ]; then
  ok "'+ amodel' (line $AM_CAT_N) sits directly after '+ opz' and directly above the lens header (the frame sits above the class it frames)"
else
  bad "'+ amodel' is not between '+ opz' and the lens header by line order (opz@'$OPZ_CAT_N' amodel@'$AM_CAT_N' lens@'$LENS_N')"
fi

note "5) the PRECOND-STEP| sentinel and its honesty gate ..."
if grep -q 'print("PRECOND-STEP|" + subsystem + "|" + cls + "|on");' "$HUNTER"; then
  ok "the sentinel is printed as PRECOND-STEP|<subsystem>|<cls>|on"
else
  bad "the PRECOND-STEP|<subsystem>|<cls>|on sentinel emission is gone or reshaped"
fi
if grep -B1 'print("PRECOND-STEP|"' "$HUNTER" | grep -q 'if index_of(instruction, attacker_model_marker()) >= 0 {'; then
  ok "the sentinel is gated on the marker being in the assembled instruction (index_of), never on the toggle"
else
  bad "the PRECOND-STEP sentinel is not gated on index_of(instruction, attacker_model_marker())"
fi
OPZ_SENT_N="$(grep -n 'print("OPERATIONALIZE|"' "$HUNTER" | head -1 | cut -d: -f1)"
AM_SENT_N="$(grep -n 'print("PRECOND-STEP|"' "$HUNTER" | head -1 | cut -d: -f1)"
PROMPT_N="$(grep -n '^let verdict = prompt(instruction, code) -> string;$' "$HUNTER" | head -1 | cut -d: -f1)"
if [ -n "$OPZ_SENT_N" ] && [ -n "$AM_SENT_N" ] && [ -n "$PROMPT_N" ] \
   && [ "$AM_SENT_N" -gt "$OPZ_SENT_N" ] && [ "$AM_SENT_N" -lt "$PROMPT_N" ]; then
  ok "the sentinel is printed after the OPERATIONALIZE| sentinel and before the prompt() call"
else
  bad "the sentinel is not between the OPERATIONALIZE| sentinel and the prompt() call (opz@'$OPZ_SENT_N' step@'$AM_SENT_N' prompt@'$PROMPT_N')"
fi
if grep 'print("PRECOND-STEP|"' "$HUNTER" | grep -q 'CANDIDATE|'; then
  bad "the PRECOND-STEP sentinel carries a 'CANDIDATE|' substring (would false-accept a cell)"
else
  ok "the sentinel carries no 'CANDIDATE|' substring (lib/run-agent-validated.sh cannot false-accept a cell on it)"
fi
if grep -q 'ATTACKER_MODEL #2373' "$HUNTER" && grep -q 'PRECOND-STEP|<subsystem>|<cls>|on' "$HUNTER" \
   && grep -q 'PRECOND|<file:function>|caller=' "$HUNTER" && grep -q 'RECHECK|<file:function\[:line\]>|' "$HUNTER"; then
  ok "hunter.ag's header documents the ATTACKER_MODEL knob and the PRECOND-STEP|/PRECOND|/RECHECK| lines"
else
  bad "hunter.ag's header Env/Stdout contract does not document ATTACKER_MODEL and its three lines"
fi

note "6) the knob reaches hunter.ag (exec.env_passthrough) ..."
# getenv() reads the SANITISED env: without the allowlist entry the opt-in never arrives and the knob is silently
# inert (#1426). The [,"] terminator lets a later knob be appended without failing this.
if grep -q '^  echo "exec.env_passthrough = .*,ATTACKER_MODEL[,"]' "$DISCOVERY"; then
  ok "run-discovery.sh registers ATTACKER_MODEL on exec.env_passthrough"
else
  bad "run-discovery.sh does NOT pass ATTACKER_MODEL through exec.env_passthrough — the knob would be silently inert"
fi
if grep -q '^  # #2373 ATTACKER_MODEL' "$DISCOVERY"; then
  ok "the allowlist doc block records why ATTACKER_MODEL is on it"
else
  bad "the allowlist doc block has no #2373 ATTACKER_MODEL line"
fi

note "7) the three new tokens are RECORD BOUNDARIES in _join_wrapped_candidates ..."
BOUNDARY_LINE="$(grep -n 'BLACKBOARD-/ ||' "$DISCOVERY" | head -1 | cut -d: -f2-)"
BOUND_MISS=""
case "$BOUNDARY_LINE" in *'/^[[:space:]]*PRECOND\|/'*) ;; *) BOUND_MISS="$BOUND_MISS PRECOND|" ;; esac
case "$BOUNDARY_LINE" in *'/^[[:space:]]*PRECOND-STEP\|/'*) ;; *) BOUND_MISS="$BOUND_MISS PRECOND-STEP|" ;; esac
case "$BOUNDARY_LINE" in *'/^[[:space:]]*RECHECK\|/'*) ;; *) BOUND_MISS="$BOUND_MISS RECHECK|" ;; esac
if [ -z "$BOUNDARY_LINE" ]; then
  bad "could not find the _join_wrapped_candidates boundary alternation in run-discovery.sh"
elif [ -z "$BOUND_MISS" ]; then
  ok "_join_wrapped_candidates lists PRECOND|, PRECOND-STEP| and RECHECK| next to the sibling boundary tokens"
else
  bad "the _join_wrapped_candidates boundary alternation is missing:$BOUND_MISS"
fi

note "8) token distinctness: no new token collides with an existing hunter-log token ..."
# Anchored consumers match `^[[:space:]]*<TOKEN>\|`, so a collision is one token being a PREFIX of another
# (`PRECOND` vs `PRECOND-STEP` is safe: the `-` sits where the `|` would have to be).
COLLIDE=""
NEW_TOKENS="PRECOND| PRECOND-STEP| RECHECK|"
for new in $NEW_TOKENS; do
  # The other new tokens are compared too, so PRECOND| vs PRECOND-STEP| is checked both ways.
  for old in 'CANDIDATE|' 'SAFE' 'VERDICT|' 'OPCHECK|' 'PARAM|' 'PARAM-TRACE|' 'TRACE|' 'READ|' 'PTRACE|' 'DISMISS|' \
             'OPERATIONALIZE|' 'SEVERITY-RUBRIC|' 'GROUND-EVIDENCE|' $NEW_TOKENS; do
    [ "$old" = "$new" ] && continue
    case "$new" in "$old"*) COLLIDE="$COLLIDE $new~$old" ;; esac
    case "$old" in "$new"*) COLLIDE="$COLLIDE $old~$new" ;; esac
  done
  case "$new" in *'CANDIDATE|'*) COLLIDE="$COLLIDE $new~CANDIDATE|" ;; esac
done
if [ -z "$COLLIDE" ]; then
  ok "PRECOND|, PRECOND-STEP| and RECHECK| are distinct from CANDIDATE|/SAFE/VERDICT|/OPCHECK|/PARAM|/PARAM-TRACE|/TRACE|/READ|/PTRACE|/DISMISS| and from each other"
else
  bad "a new token collides with an existing one under anchored matching:$COLLIDE"
fi
# The suffix side: `RECHECK|` ends in `CHECK|` and `PRECOND|` in `COND|`. A shipped consumer grepping either
# UNANCHORED would read the new lines as its own. Demos are excluded (they are the tests, not consumers).
SUFFIX_HITS="$WORK/suffix-hits.txt"
find "$HERE" "$HERE/../tools" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.ag' \) \
  ! -name 'demo-*' ! -path '*/fixtures/*' 2>/dev/null \
  | while IFS= read -r src; do
      grep -nHE '(^|[^A-Za-z_-])(CHECK|COND)\\?\|' "$src" 2>/dev/null || true
    done > "$SUFFIX_HITS"
if [ -s "$SUFFIX_HITS" ]; then
  bad "a shipped consumer greps an unanchored CHECK| or COND| (it would read RECHECK|/PRECOND| lines as its own)"
  head -3 "$SUFFIX_HITS" | sed 's/^/      /' >&2
else
  ok "no shipped consumer greps an unanchored CHECK| or COND| (RECHECK|/PRECOND| cannot be misread by a suffix match)"
fi

note "9) the directive carries its load-bearing sentences ..."
DIRECTIVE_MISS=""
for s in \
  "$MARKER_WANT" \
  "write down WHO the attacker is and WHAT they control, separately for EACH in-scope function" \
  "For EACH in-scope function, BEFORE any mechanism and before any CANDIDATE line, emit one line of its own:" \
  "PRECOND|<file:function>|caller=<who can call it: permissionless, or which role>|state=<" \
  "|timing=<" "|config=<any value a setter ADMITS" "|input=<" \
  "Each CANDIDATE line names the PRECOND field its mechanism exploits" \
  "RE-CHECK YOUR OWN DISMISSALS." \
  "must be re-argued against EACH PRECOND field of its function before it stands" \
  "RECHECK|<file:function[:line]>|<no-loss or guard>|<the PRECOND fields you re-argued it against>|<kept or reopened>" \
  "goes on its OWN CANDIDATE line, never inside the RECHECK line" \
  "A RECHECK line or a PRECOND line never contains the text CANDIDATE|" \
  "Derive every field from THIS payload: never invent a caller, a setter or an input the code does not have"
do
  case "$HUNTER_FLAT" in *"$s"*) ;; *) DIRECTIVE_MISS="$DIRECTIVE_MISS [$s]" ;; esac
done
if [ -z "$DIRECTIVE_MISS" ]; then
  ok "the directive keeps PRECOND-per-function, cite-the-PRECOND-field, the re-check, the RECHECK grammar and the never-CANDIDATE|-inside rule"
else
  bad "the directive lost load-bearing text:$DIRECTIVE_MISS"
fi

note "10) OVERFITTING GUARD: the directive stays PURE-META ..."
# Generic text only: no protocol, product, contract, named role or mechanism noun. The tokens below include the
# products named in earlier lenses and the shapes of the #2311 rows the dev check is pointed at, so the step can
# never be tuned into an answer for them.
BLOCK_BODY="$WORK/attacker-model-body.txt"
awk '/^fn attacker_model_block\(/{f=1} f{print} f&&/^}$/{exit}' "$HUNTER" > "$BLOCK_BODY"
DENY='Curve|Convex|Pendle|Balancer|Uniswap|Aave|Numa|numa|Peapods|peapods|burve|Burve|WETH|ERC-?[0-9]|\.sol|[Oo]wner|[Aa]dmin|[Kk]eeper|[Gg]overn|[Gg]uardian|[Ll]iquidat|[Oo]racle|[Ff]lash|[Rr]egime|[Mm]int|[Vv]ault|[Pp]ool|[Ll]ending|[Bb]orrow|[Ss]wap'
if [ ! -s "$BLOCK_BODY" ]; then
  bad "could not slice attacker_model_block() out of hunter.ag"
elif grep -Eq "$DENY" "$BLOCK_BODY"; then
  bad "the directive block names a protocol/product/role/mechanism specific (it would leak an answer into a hunt)"
  grep -nE "$DENY" "$BLOCK_BODY" | head -3 | sed 's/^/      /' >&2
else
  ok "the directive names no protocol, product, contract, named role or mechanism (pure-meta)"
fi

note "11) substrate purity (#1587): the #2373 block is builtins-only ..."
AM_BLOCK="$WORK/attacker-model-block.txt"
awk '/^\/\/ --- #2373 ATTACKER-MODEL DIRECTIVE/{f=1; next} f&&/^\/\/ --- /{exit} f{print}' "$HUNTER" \
  | grep -v '^[[:space:]]*//' > "$AM_BLOCK"
if [ ! -s "$AM_BLOCK" ]; then
  bad "could not slice the #2373 block out of hunter.ag (header comment renamed?)"
elif grep -Eq 'exec sh|python3 -c|reduce\(|regex_|awk|sed |date ' "$AM_BLOCK"; then
  bad "the #2373 block introduced an embedded interpreter / regex / reduce (substrate-purity ratchet)"
  grep -nE 'exec sh|python3 -c|reduce\(|regex_|awk|sed |date ' "$AM_BLOCK" | head -3 | sed 's/^/      /' >&2
else
  ok "the #2373 block uses only getenv and O(1) string concat (no exec sh, no regex/reduce, no per-element cost)"
fi

note "12) synthetic logs through the SHIPPED _join_wrapped_candidates ..."
JWC_AWK="$WORK/join-wrapped.awk"
sed -n '/^_join_wrapped_candidates() {$/,/^}$/p' "$DISCOVERY" \
  | sed -n "/^  awk '$/,/^  ' /p" | sed "1d; \$d" > "$JWC_AWK"
WRAP_LOG="$WORK/wrapped-cell.log"
{
  printf 'PRECOND-STEP|vault|C5|on\n'
  printf 'CANDIDATE|Vault.sol:settle:40|C5|High|via timing the caller settles before the rate moves|deploy a\n'
  printf '  stub, settle, and assert the first settlement used the old rate\n'
  printf 'PRECOND|Vault.sol:settle|caller=permissionless|state=stored rate|timing=caller picks|config=none|input=amount\n'
  printf 'CANDIDATE|Vault.sol:claim:55|C5|Medium|via state the stored index is preset|stub the index,\n'
  printf '  claim twice, and assert the second claim pays again\n'
  printf '  RECHECK|Vault.sol:claim:55|guard|caller,state,timing|reopened\n'
  printf 'CANDIDATE|Vault.sol:sweep:70|C5|Medium|via config an admitted value skips the check|set the value,\n'
  printf '  sweep, and assert the balance left the contract\n'
  printf 'PRECOND-STEP|vault|C5|on\n'
  printf 'SAFE\n'
} > "$WRAP_LOG"
if [ ! -s "$JWC_AWK" ]; then
  bad "could not extract the _join_wrapped_candidates awk program from run-discovery.sh (reshaped?)"
else
  JOINED="$(awk -f "$JWC_AWK" "$WRAP_LOG")"
  JOINED_N="$(printf '%s\n' "$JOINED" | grep -c 'CANDIDATE|')"
  if [ "$JOINED_N" -ne 3 ]; then
    bad "the three wrapped records did not reconstruct into exactly three CANDIDATE| lines (got $JOINED_N)"
  elif printf '%s' "$JOINED" | grep -q 'PRECOND\|RECHECK|'; then
    bad "a PRECOND|/RECHECK|/PRECOND-STEP| line was glued onto an open CANDIDATE| record (the boundary does not hold)"
  elif printf '%s' "$JOINED" | grep -q 'assert the first settlement used the old rate' \
       && printf '%s' "$JOINED" | grep -q 'assert the second claim pays again' \
       && printf '%s' "$JOINED" | grep -q 'assert the balance left the contract'; then
    ok "a PRECOND| line, an indented RECHECK| line and a PRECOND-STEP| line each close a wrapped CANDIDATE record: three candidates, every tail kept, nothing glued"
  else
    bad "a wrapped continuation line was lost while joining the records"
  fi
fi

note "13) the anchored count idiom: PRECOND| is not PRECOND-STEP| ..."
CNT_FNS="$WORK/count-fns.sh"
sed -n '/^_distinct_sentinel_count() {$/,/^}$/p' "$DISCOVERY" > "$CNT_FNS"
COUNT_LOG="$WORK/count-cell.log"
{
  printf 'PRECOND-STEP|vault|C5|on\n'
  printf 'PRECOND|Vault.sol:settle|caller=permissionless|state=a|timing=b|config=none|input=c\n'
  printf '  PRECOND|Vault.sol:claim|caller=permissionless|state=a|timing=b|config=none|input=c\n'
  printf 'PRECOND|Vault.sol:settle|caller=permissionless|state=a|timing=b|config=none|input=c\n'
  printf 'RECHECK|Vault.sol:claim|no-loss|caller,timing|kept\n'
  printf 'SAFE\n'
} > "$COUNT_LOG"
if ! grep -q '^_distinct_sentinel_count() {$' "$CNT_FNS"; then
  bad "could not slice _distinct_sentinel_count out of run-discovery.sh (reshaped?)"
else
  # shellcheck disable=SC1090  # sliced from the shipped script at run time
  . "$CNT_FNS"
  N_PRE="$(_distinct_sentinel_count PRECOND "$COUNT_LOG")"
  N_STEP="$(_distinct_sentinel_count PRECOND-STEP "$COUNT_LOG")"
  N_RE="$(_distinct_sentinel_count RECHECK "$COUNT_LOG")"
  N_RAW="$(grep -cE '^[[:space:]]*PRECOND\|' "$COUNT_LOG")"
  if [ "$N_PRE" = "2" ] && [ "$N_STEP" = "1" ] && [ "$N_RE" = "1" ] && [ "$N_RAW" = "3" ]; then
    ok "the shipped count gives PRECOND|=2 distinct (3 raw, one indented), PRECOND-STEP|=1, RECHECK|=1 — the sentinel never counts as a PRECOND| line"
  else
    bad "anchored counts are off: PRECOND|=$N_PRE (want 2) raw=$N_RAW (want 3) PRECOND-STEP|=$N_STEP (want 1) RECHECK|=$N_RE (want 1)"
  fi
fi

note "14) fixtures and CHANGELOG ..."
if grep -q 'require(msg.sender == owner, "not owner");' "$GUARDED" && grep -q 'function sweepSurplus(' "$GUARDED"; then
  ok "GuardedVault.sol: one function behind one real, provable guard (the textbook guard dismissal)"
else
  bad "GuardedVault.sol lost the single owner check it exists to carry"
fi
# A fixture is fed to the model VERBATIM; one that narrates the expected output would teach the OFF arm to emit it
# (the measured #2211 contamination).
if grep -Eqi 'PRECOND|RECHECK|attacker model|attacker_model|dismiss|Curve|Convex|Pendle|Balancer|Uniswap|Aave' "$GUARDED"; then
  bad "GuardedVault.sol narrates the contract that consumes it or names a real protocol"
  grep -nEi 'PRECOND|RECHECK|attacker model|attacker_model|dismiss' "$GUARDED" | head -3 | sed 's/^/      /' >&2
else
  ok "GuardedVault.sol names no protocol and never narrates the PRECOND|/RECHECK| contract"
fi
if grep -Eqi 'PRECOND|RECHECK|attacker model' "$PAIRED"; then
  bad "PairedPoolVault.sol (reused as the PRECOND fixture) narrates the #2373 contract"
else
  ok "PairedPoolVault.sol (reused for the PRECOND half) does not narrate the #2373 contract"
fi
if sed -n '/^## \[Unreleased\]/,/^## \[[0-9]/p' "$CHANGELOG" | grep -q 'ATTACKER_MODEL'; then
  ok "CHANGELOG.md [Unreleased] records the ATTACKER_MODEL knob"
else
  bad "CHANGELOG.md [Unreleased] has no ATTACKER_MODEL entry"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 2 — LIVE UNDER MOCK (needs the agentis binary; clean [SKIP] otherwise)
# ----------------------------------------------------------------------------------------------------------
# _arm <label> <fixture-path> <class> <backend>: stage a one-contract repo + scope + brief, run ONE hunter cell
# through run-discovery.sh, print the cell log path. Parts 2 and 3 share it, so the live gate exercises the SAME
# path the mock gate does.
_arm() {
  _label="$1"; _sol="$2"; _cls="$3"; _backend="$4"
  _base="$(basename "$_sol")"
  _repo="$WORK/$_label-repo"; mkdir -p "$_repo/contracts"
  cp "$_sol" "$_repo/contracts/$_base"
  printf 'vault | %s | contracts/%s\n' "$_cls" "$_base" > "$WORK/$_label-scope.tsv"
  printf '# brief\nInvariants to break: a user can only ever move value that is theirs; the books always balance.\nKnown issues to exclude: none.\n' \
    > "$WORK/$_label-brief.md"
  "$DISCOVERY" --repo "$_repo" --scope "$WORK/$_label-scope.tsv" --brief "$WORK/$_label-brief.md" \
    --only "vault" --classes "$_cls" --backend "$_backend" --agentis agentis --out "$WORK/$_label" \
    > "$WORK/$_label.out" 2>&1 || true
  printf '%s\n' "$WORK/$_label/run/hunt_vault_$_cls.log"
}

if ! command -v agentis >/dev/null 2>&1; then
  note "15-16) live-under-mock sentinel ON/OFF + byte-identity probe ..."
  skip "no agentis binary on PATH — the mock hunt cells and the extracted-helper probe cannot run"
else
  note "15) live-under-mock: PRECOND-STEP| with ATTACKER_MODEL=1, absent when unset or \"0\" ..."
  M_ON="$(ATTACKER_MODEL=1 _arm mock-on "$PAIRED" C23 mock)"
  M_OFF="$(_arm mock-off "$PAIRED" C23 mock)"
  M_ZERO="$(ATTACKER_MODEL=0 _arm mock-zero "$PAIRED" C23 mock)"
  if [ ! -f "$M_ON" ] || [ ! -f "$M_OFF" ] || [ ! -f "$M_ZERO" ]; then
    bad "the mock hunt cells produced no cell log (run-discovery.sh did not reach hunter.ag)"
    tail -5 "$WORK/mock-on.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    if grep -q '^PRECOND-STEP|vault|C23|on$' "$M_ON"; then
      ok "ATTACKER_MODEL=1: the sentinel fired end-to-end (run-discovery.sh -> env_passthrough -> hunter.ag getenv)"
    else
      bad "ATTACKER_MODEL=1: NO PRECOND-STEP| sentinel — the opt-in did not reach hunter.ag (env_passthrough gap?)"
    fi
    if grep -q 'PRECOND-STEP|' "$M_OFF"; then
      bad "ATTACKER_MODEL unset: a PRECOND-STEP| sentinel appeared — the directive is NOT default-OFF"
    else
      ok "ATTACKER_MODEL unset: no PRECOND-STEP| sentinel (default OFF)"
    fi
    if grep -q 'PRECOND-STEP|' "$M_ZERO"; then
      bad "ATTACKER_MODEL=0: a PRECOND-STEP| sentinel appeared — a value other than \"1\" opted in"
    else
      ok "ATTACKER_MODEL=0: no PRECOND-STEP| sentinel (only the literal \"1\" opts in)"
    fi
  fi

  note "16) byte-identity probe over the helpers extracted from hunter.ag by line range ..."
  FRAG="$WORK/am.frag"; : > "$FRAG"
  FRAG_MISS=""
  for fn in $AM_FNS; do
    awk -v want="^fn $fn\\\\(" '$0 ~ want {f=1} f{print} f&&/^}$/{exit}' "$HUNTER" >> "$FRAG"
    printf '\n' >> "$FRAG"
    grep -q "^fn $fn(" "$FRAG" || FRAG_MISS="$FRAG_MISS $fn"
  done
  if [ -n "$FRAG_MISS" ]; then
    bad "could not extract #2373 helpers from hunter.ag by line range (renamed?):$FRAG_MISS"
  else
    SB="$WORK/probe"; mkdir -p "$SB"
    ( cd "$SB" && agentis init >/dev/null 2>&1 ) || true
    printf 'exec.env_passthrough = ATTACKER_MODEL\n' > "$SB/.agentis/config"
    {
      printf 'cb 300000;\n\n'
      cat "$FRAG"
      printf 'print("BLOCKLEN=" + to_string(len(attacker_model_block())));\n'
      printf 'print("MARKERPOS=" + to_string(index_of(attacker_model_block(), attacker_model_marker() + "\\n")));\n'
      printf 'print("DIRLEN=" + to_string(len(attacker_model_directive())));\n'
    } > "$SB/probe.ag"
    # _probe <KEY> <mode> [value]: mode "unset" runs with ATTACKER_MODEL removed from the env, "set" with the value.
    _probe() {
      if [ "$2" = "unset" ]; then
        _pv="$( cd "$SB" && env -u ATTACKER_MODEL agentis go probe.ag 2>&1 | grep "^$1=" | tail -1 )"  # no-pii: the probe never calls prompt() — it prints string lengths
      else
        _pv="$( cd "$SB" && ATTACKER_MODEL="$3" agentis go probe.ag 2>&1 | grep "^$1=" | tail -1 )"  # no-pii: length-only probe, no prompt()
      fi
      printf '%s\n' "${_pv#"$1"=}"
    }
    BLOCK_LEN="$(_probe BLOCKLEN unset)"
    MARKER_POS="$(_probe MARKERPOS unset)"
    DIR_ON="$(_probe DIRLEN set 1)"
    case "$BLOCK_LEN" in
      ''|*[!0-9]*) bad "the byte-identity probe did not complete (BLOCKLEN='$BLOCK_LEN')" ;;
      0) bad "attacker_model_block() is empty — the directive could never reach a prompt" ;;
      *) ok "attacker_model_block() is $BLOCK_LEN bytes (the directive is really assembled)" ;;
    esac
    if [ "$MARKER_POS" = "0" ]; then
      ok "the marker plus a newline sits at offset 0 of the rendered block (it IS the block's first line)"
    else
      bad "the marker is not the rendered block's first line (index_of gave '$MARKER_POS')"
    fi
    if [ "$DIR_ON" = "$BLOCK_LEN" ] && [ "$BLOCK_LEN" != "0" ]; then
      ok "ATTACKER_MODEL=1: attacker_model_directive() = $DIR_ON bytes = the full block"
    else
      bad "ATTACKER_MODEL=1: attacker_model_directive() ($DIR_ON) != the full block ($BLOCK_LEN)"
    fi
    OFF_VALUES_BAD=""
    D_UNSET="$(_probe DIRLEN unset)"
    [ "$D_UNSET" = "0" ] || OFF_VALUES_BAD="$OFF_VALUES_BAD unset=$D_UNSET"
    for v in "" 0 2 true " 1" "1 "; do
      d="$(_probe DIRLEN set "$v")"
      [ "$d" = "0" ] || OFF_VALUES_BAD="$OFF_VALUES_BAD '$v'=$d"
    done
    if [ -z "$OFF_VALUES_BAD" ]; then
      ok "ATTACKER_MODEL unset, \"\", \"0\", \"2\", \"true\", \" 1\" and \"1 \": the directive is 0 bytes — concatenating it is a no-op, so the prompt is byte-identical to before"
    else
      bad "a value other than \"1\" produced a non-empty directive:$OFF_VALUES_BAD"
    fi
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# PART 3 — LIVE-AGENT MUTATION GATE. The directive is English prose the MODEL interprets: no `.ag` code derives an
# attacker model, so only the real hunter.ag over `flat-cyborg` (this federation's live backend) can show the model
# complies. Each fixture runs twice with only the flag flipped; that pair IS the mutation. Clean [SKIP] otherwise.
# ----------------------------------------------------------------------------------------------------------
# _lines <TOKEN> <log>: the whitespace-trimmed `<TOKEN>|...` lines of a log (anchored, like the shipped counts).
_lines() { grep -E "^[[:space:]]*$1\|" "$2" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true; }
# _fnkey <loc>: `path/File.sol:function[:line]` -> `File.sol:function` (basename + function, backticks/space dropped).
# The model may or may not repeat the repo-relative directory, so the key is the file's basename plus the function.
_fnkey() {
  _k="$(printf '%s' "$1" | tr -d '` ')"
  _kf="${_k%%:*}"; _kr="${_k#*:}"; _kfn="${_kr%%:*}"
  [ "$_kr" = "$_k" ] && _kfn=""
  printf '%s:%s\n' "${_kf##*/}" "$_kfn"
}
# _field <line> <n>: the n-th `|`-separated field, trimmed.
_field() { printf '%s\n' "$1" | cut -d'|' -f"$2" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
# _qual_dismiss_keys <log>: one fn key per DISMISS| line whose ground is no-loss or guard.
_qual_dismiss_keys() {
  _lines DISMISS "$1" | while IFS= read -r _d; do
    _g="$(_field "$_d" 3 | tr '[:upper:]' '[:lower:]')"
    case "$_g" in no-loss|guard) _fnkey "$(_field "$_d" 2)" ;; esac
  done | sort -u
}
_keep_evidence() {
  [ -n "${DEMO_EVIDENCE_DIR:-}" ] || return 0
  mkdir -p "$DEMO_EVIDENCE_DIR"
  for _e in "$WORK"/live-*; do
    [ -e "$_e" ] || continue
    case "$_e" in *-repo) continue ;; esac
    cp -r "$_e" "$DEMO_EVIDENCE_DIR/" 2>/dev/null || true
  done
}

if ! command -v flat-cyborg >/dev/null 2>&1 || ! command -v agentis >/dev/null 2>&1; then
  note "17-18) live-agent ON/OFF mutation gate ..."
  skip "no flat-cyborg/agentis on PATH — the real hunter.ag compliance with the directive cannot be exercised"
else
  note "17) live-agent (i) PRECOND half: same fixture, same cell, only the flag flips ..."
  L1_ON="$(ATTACKER_MODEL=1 _arm live-i-on "$PAIRED" C23 flat-cyborg)"
  L1_OFF="$(_arm live-i-off "$PAIRED" C23 flat-cyborg)"
  if [ ! -f "$L1_ON" ]; then
    bad "(i) ON arm: no cell log — run-discovery.sh did not reach a verdict over the real backend"
    tail -8 "$WORK/live-i-on.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    if grep -q '^PRECOND-STEP|vault|C23|on$' "$L1_ON"; then
      ok "(i) ON arm: the PRECOND-STEP| sentinel is in the live cell log"
    else
      bad "(i) ON arm: no PRECOND-STEP| sentinel — the directive was not injected"
    fi
    VER_LINE="$(grep -nE '^[[:space:]]*(CANDIDATE\||SAFE[[:space:]]*$)' "$L1_ON" | head -1 | cut -d: -f1)"
    PRE_N="$(_lines PRECOND "$L1_ON" | grep -c . || true)"
    MISSING_PRE=""
    for fn in enterPool exitPool; do
      first="$(grep -nE "^[[:space:]]*PRECOND\|[^|]*:$fn([:|[:space:]]|$)" "$L1_ON" | head -1 | cut -d: -f1)"
      if [ -z "$first" ]; then
        MISSING_PRE="$MISSING_PRE $fn(none)"
      elif [ -n "$VER_LINE" ] && [ "$first" -gt "$VER_LINE" ]; then
        MISSING_PRE="$MISSING_PRE $fn(after-verdict@$first>$VER_LINE)"
      fi
    done
    if [ -z "$VER_LINE" ]; then
      bad "(i) ON arm: no CANDIDATE|/SAFE verdict line in the live reply"
    elif [ -z "$MISSING_PRE" ]; then
      ok "(i) ON arm: $PRE_N PRECOND| line(s), one for each in-scope function (enterPool, exitPool), all before the first verdict line ($VER_LINE)"
    else
      bad "(i) ON arm: in-scope function(s) without a PRECOND| line before the verdict:$MISSING_PRE"
      _lines PRECOND "$L1_ON" | head -4 | sed 's/^/      /' >&2
    fi
    if _lines PRECOND "$L1_ON" | grep -q 'CANDIDATE|'; then
      bad "(i) ON arm: a PRECOND| line contains 'CANDIDATE|' (the unanchored hunter predicate would false-accept it)"
    else
      ok "(i) ON arm: no PRECOND| line contains 'CANDIDATE|'"
    fi
  fi
  if [ ! -f "$L1_OFF" ]; then
    bad "(i) OFF arm: no cell log — run-discovery.sh did not reach a verdict over the real backend"
    tail -8 "$WORK/live-i-off.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    OFF_PRE="$(_lines PRECOND "$L1_OFF" | grep -c . || true)"
    OFF_RE="$(_lines RECHECK "$L1_OFF" | grep -c . || true)"
    if [ "$OFF_PRE" -eq 0 ] && [ "$OFF_RE" -eq 0 ] && ! grep -q 'PRECOND-STEP|' "$L1_OFF"; then
      ok "(i) OFF arm: zero PRECOND| lines, zero RECHECK| lines and no sentinel — they appear and disappear with the flag alone"
    else
      bad "(i) OFF arm: $OFF_PRE PRECOND| / $OFF_RE RECHECK| line(s) or a sentinel without the flag — the OFF arm is contaminated"
    fi
  fi

  note "18) live-agent (ii) RECHECK half under SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 ..."
  # _recheck_ab <log> <tag>: assertions (a) and (b) on one ON reply — both fail hard on every ON run.
  _recheck_ab() {
    _rl="$1"; _rt="$2"
    _rk="$WORK/$_rt.recheck-keys"
    _lines RECHECK "$_rl" | while IFS= read -r _r; do _fnkey "$(_field "$_r" 2)"; done | sort -u > "$_rk"
    _uncovered=""
    for _q in $(_qual_dismiss_keys "$_rl"); do
      grep -qxF "$_q" "$_rk" || _uncovered="$_uncovered $_q"
    done
    if [ -z "$_uncovered" ]; then
      ok "(ii)(a) $_rt: every no-loss/guard DISMISS| has a RECHECK| for the same file:function ($(_qual_dismiss_keys "$_rl" | grep -c . || true) dismissed function(s))"
    else
      bad "(ii)(a) $_rt: no-loss/guard DISMISS| without a RECHECK| for the same function:$_uncovered"
      _lines DISMISS "$_rl" | head -4 | sed 's/^/      /' >&2
    fi
    _badtail=""; _noreport=""
    _cands="$WORK/$_rt.cand-keys"
    _lines CANDIDATE "$_rl" | while IFS= read -r _c; do _fnkey "$(_field "$_c" 2)"; done | sort -u > "$_cands"
    while IFS= read -r _r; do
      [ -n "$_r" ] || continue
      _last="$(printf '%s\n' "$_r" | awk -F'|' '{print $NF}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      case "$_last" in
        kept) ;;
        reopened) _rkey="$(_fnkey "$(_field "$_r" 2)")"; grep -qxF "$_rkey" "$_cands" || _noreport="$_noreport $_rkey" ;;
        *) _badtail="$_badtail [$_last]" ;;
      esac
      case "$_r" in *'CANDIDATE|'*) _badtail="$_badtail [contains CANDIDATE|]" ;; esac
    done <<EOF
$(_lines RECHECK "$_rl")
EOF
    if [ -z "$_badtail" ] && [ -z "$_noreport" ]; then
      ok "(ii)(b) $_rt: every RECHECK| ends in kept|reopened, none contains 'CANDIDATE|', and every reopened function has its own CANDIDATE| line"
    else
      bad "(ii)(b) $_rt: RECHECK| grammar broken — bad tails:${_badtail:- none}; reopened without a CANDIDATE|:${_noreport:- none}"
      _lines RECHECK "$_rl" | head -4 | sed 's/^/      /' >&2
    fi
  }
  L2_ON="$(ATTACKER_MODEL=1 SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 _arm live-ii-on "$GUARDED" C5 flat-cyborg)"
  L2_OFF="$(SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 _arm live-ii-off "$GUARDED" C5 flat-cyborg)"
  if [ ! -f "$L2_ON" ]; then
    bad "(ii) ON arm: no cell log — run-discovery.sh did not reach a verdict over the real backend"
    tail -8 "$WORK/live-ii-on.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    if grep -q '^PRECOND-STEP|vault|C5|on$' "$L2_ON"; then
      ok "(ii) ON arm: the PRECOND-STEP| sentinel is in the live cell log"
    else
      bad "(ii) ON arm: no PRECOND-STEP| sentinel — the directive was not injected"
    fi
    _recheck_ab "$L2_ON" "ON run 1"
    L2_FINAL="$L2_ON"
    if [ -z "$(_qual_dismiss_keys "$L2_ON")" ]; then
      note "    (ii) ON run 1 wrote no no-loss/guard DISMISS| — one retry, as the plan allows ..."
      L2_RETRY="$(ATTACKER_MODEL=1 SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 _arm live-ii-on-retry "$GUARDED" C5 flat-cyborg)"
      if [ -f "$L2_RETRY" ]; then
        _recheck_ab "$L2_RETRY" "ON run 2"
        L2_FINAL="$L2_RETRY"
      else
        bad "(ii) ON retry: no cell log"
      fi
    fi
    RE_N="$(_lines RECHECK "$L2_FINAL" | grep -c . || true)"
    QD_N="$(_qual_dismiss_keys "$L2_FINAL" | grep -c . || true)"
    REOPEN_N="$(_lines RECHECK "$L2_FINAL" | grep -c '|[[:space:]]*reopened$' || true)"
    if [ "$RE_N" -ge 1 ]; then
      ok "(ii)(c) at least one RECHECK| line exists ($RE_N RECHECK|, $REOPEN_N reopened, over $QD_N no-loss/guard-dismissed function(s))"
    elif [ "$QD_N" -eq 0 ]; then
      inconclusive "(ii)(c) the model wrote no no-loss/guard DISMISS| even after one retry, so no RECHECK| was owed — the re-check is NOT proven live here; the dev run's RECHECK counts are the first real evidence"
    else
      bad "(ii)(c) $QD_N no-loss/guard-dismissed function(s) but zero RECHECK| lines — the re-check was skipped"
    fi
  fi
  if [ ! -f "$L2_OFF" ]; then
    bad "(ii) OFF arm: no cell log — run-discovery.sh did not reach a verdict over the real backend"
    tail -8 "$WORK/live-ii-off.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    OFF2_PRE="$(_lines PRECOND "$L2_OFF" | grep -c . || true)"
    OFF2_RE="$(_lines RECHECK "$L2_OFF" | grep -c . || true)"
    OFF2_D="$(_lines DISMISS "$L2_OFF" | grep -c . || true)"
    if [ "$OFF2_PRE" -eq 0 ] && [ "$OFF2_RE" -eq 0 ] && ! grep -q 'PRECOND-STEP|' "$L2_OFF"; then
      ok "(ii) OFF arm: zero PRECOND| / RECHECK| lines and no sentinel with the rubric on ($OFF2_D DISMISS| line(s)) — the re-check telemetry appears with the flag alone"
    else
      bad "(ii) OFF arm: $OFF2_PRE PRECOND| / $OFF2_RE RECHECK| line(s) or a sentinel without the flag — the OFF arm is contaminated"
    fi
  fi
  _keep_evidence
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  if [ "$INCONCLUSIVE" -gt 0 ]; then
    note "PASS with $INCONCLUSIVE INCONCLUSIVE — the #2373 attacker-model directive's wiring holds; the live re-check was not exercised (see the [INCONCLUSIVE] line)"
  else
    note "PASS — the #2373 attacker-model directive (pure-meta text, default-OFF ATTACKER_MODEL, PRECOND-STEP| sentinel, PRECOND|/RECHECK| contract, record boundaries) holds"
  fi
  note "NOTE: this gate proves WIRING and model COMPLIANCE only. Recall is UNMEASURED until #2373's dev and held-out runs."
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
