#!/usr/bin/env bash
# demo-function-coverage.sh — the gate for the #2256 BREADTH FUNCTION-COVERAGE GATE (knob FUNCTION_COVERAGE=1).
#
# What the change is. In the #2245 final exam a rare row sat in a function that WAS in the zone's sliced function
# list, and none of the six cells on that zone mentioned the function at all: they converged on another subsystem of
# the same zone. Such a "never looked" miss is invisible to every per-cell gate (OPCHECK->TRACE, DISMISS grounds,
# the parameter audit), because those only constrain what a cell says about what it chose to look at. So #2256 adds
# a ZONE-level output gate:
#   * hunter.ag asks for one `READ|<file:function>|<evidence>` line per traced function (honesty-gated
#     `FUNCTION-COVERAGE|` sentinel);
#   * lib/inheritance.py zone-functions enumerates the line's GATED functions (the #2253 function model);
#   * run-discovery.sh matches them against every FINAL cell log of the line (READ|/DISMISS|/CANDIDATE|/PARAM|/
#     CALLEE-VECTOR|, a READ counting only when grounded in the body), and runs ONE coverage cell over the (capped,
#     ranked) untouched functions after the depth pass;
#   * run-zone-hunt.sh charges that cell up front and trims it (never a breadth class) under a cell budget.
# `FUNCTION_COVERAGE=1` opts in; unset (the DEFAULT) leaves the prompt, the report, the results JSON and the banner
# byte-identical.
#
# Nothing asserted here is a recall claim — recall is the operator's pre-registered measurement on a fresh set.
#
# Eight parts. Parts 1-7 are the CI floor: grep/awk/python3 plus the SHIPPED shell functions sliced out of
# run-discovery.sh and offline --agentis / run-discovery stubs, so they need no agentis, no forge, no network, no LLM.
#   1) hunter.ag SOURCE-GUARD — helpers, marker/sentinel coupling, `== "1"` polarity, ""-when-off, splice order,
#      single-class byte-identity paths, token invariants, overfitting/domain-noun denylist (+ negative control).
#   2) WIRING — passthrough + cell env, the three record boundaries through the SHIPPED awk joiner, the coverage
#      block after the depth pass, both recorded-run filters, first-class-only promotions.
#   3) inheritance.py zone-functions on fixtures (+ the other subcommands' output unchanged vs origin/main).
#   4) THE SLICED GATE over synthetic logs, with negative controls.
#   5) END-TO-END through run-discovery.sh with an offline --agentis stub (a-i).
#   6) run-zone-hunt.sh through a run-discovery shim: charge, trim, OFF byte-identity, merged record.
#   7) MUTATION RESISTANCE — eight mutations of COPIES, each must flip a named fixture.
#   8) NEEDS agentis ([SKIP] otherwise) — 0-byte helper probe under every knob combination, live mock sentinels.
# Every detector has a NEGATIVE CONTROL: a guard that never fires is indistinguishable from one that cannot.
#
# Usage:  dark-factory/demo-function-coverage.sh
# Exit: 0 = all assertions held; non-zero = a regression.
# Dash-safe fixtures: no $'...', literal glyphs only, printf with no \xHH escapes.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HUNTER="$HERE/auditor/agents/hunter.ag"
DISCOVERY="$HERE/run-discovery.sh"
ZONEHUNT="$HERE/run-zone-hunt.sh"
INHERIT="$HERE/lib/inheritance.py"

FAILS=0
note() { echo "demo-function-coverage.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for f in "$HUNTER" "$DISCOVERY" "$ZONEHUNT" "$INHERIT"; do
  [ -f "$f" ] || { note "required file not found: $f" >&2; exit 3; }
done
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

WORK="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
# Never touch a live hunt registry: every driver run below gets its own throwaway state dir.
DARK_FACTORY_DIR="$WORK/df-state"; export DARK_FACTORY_DIR
mkdir -p "$DARK_FACTORY_DIR"
# Every knob of the pipeline starts UNSET here, whatever the calling shell exported.
unset FUNCTION_COVERAGE COVERAGE_REASK_FNS SEVERITY_RUBRIC GROUND_EVIDENCE PARAM_AUDIT OPERATIONALIZE_LENS DF_TIER2 2>/dev/null || true

# _agfn <file> <fn> — one `.ag` helper, sliced by line range (never a copy that can drift).
_agfn() {
  awk -v want="^fn $2\\\\(" '$0 ~ want {f=1} f{print} f&&/^}$/{exit}' "$1"
}
# _shfn <file> <fn> — the same for a shell function.
_shfn() {
  sed -n "/^$2() {\$/,/^}\$/p" "$1"
}
# _flat <text> — flatten the multi-line `"..." + "..."` joins, so an assertion matches the PROMPT text.
_flat() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/"[[:space:]]*+[[:space:]]*"//g'
}
# _eq <label> <got> <want>
_eq() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', want '$3'"; fi; }

# ----------------------------------------------------------------------------------------------------------
# PART 1 — hunter.ag SOURCE-GUARD
# ----------------------------------------------------------------------------------------------------------
note "1) hunter.ag declares the eight #2256 helpers ..."
FC_FNS="function_coverage_marker function_coverage_enabled function_coverage_block function_coverage_directive coverage_pass_block coverage_fn_count class_sections class_field"
MISS=""
for fn in $FC_FNS; do
  grep -q "^fn $fn(" "$HUNTER" || MISS="$MISS $fn"
done
if [ -z "$MISS" ]; then ok "all 8 marker/toggle/block/directive/coverage-frame/count/class helpers are declared"; else bad "missing #2256 helper(s):$MISS"; fi

note "2) the marker is the block's literal FIRST LINE, and both sentinels are honesty-gated ..."
if _agfn "$HUNTER" function_coverage_block | sed -n 2p | grep -q 'return function_coverage_marker() + "\\n"'; then
  ok "function_coverage_block() opens with function_coverage_marker() — the sentinel greps a string that really renders"
else
  bad "function_coverage_block() no longer opens with its marker"
fi
if grep -q 'if index_of(instruction, function_coverage_marker()) >= 0 {' "$HUNTER" \
   && grep -q 'print("FUNCTION-COVERAGE|" + subsystem + "|" + cls + "|on");' "$HUNTER"; then
  ok "FUNCTION-COVERAGE| is printed only when the marker is demonstrably IN the prompt about to be sent"
else
  bad "the FUNCTION-COVERAGE| sentinel is missing or no longer gated on index_of(instruction, marker)"
fi
if grep -A2 'print("FUNCTION-COVERAGE|" + subsystem' "$HUNTER" | grep -q 'function_coverage_enabled()'; then
  bad "the FUNCTION-COVERAGE| sentinel consults the toggle — it must be gated on the marker only"
else
  ok "the FUNCTION-COVERAGE| sentinel consults no toggle"
fi
if grep -B1 'print("COVERAGE-CELL|" + subsystem' "$HUNTER" | grep -q 'if len(cpass) > 0 {'; then
  ok "COVERAGE-CELL| is printed only when the coverage frame is non-empty (i.e. only on the one coverage cell)"
else
  bad "the COVERAGE-CELL| sentinel is not gated on a non-empty coverage frame"
fi

note "3) DEFAULT-OFF polarity and the \"\"-when-off gates ..."
if _agfn "$HUNTER" function_coverage_enabled | grep -q 'getenv("FUNCTION_COVERAGE") == "1"'; then
  ok "function_coverage_enabled() is == \"1\" (unset / \"0\" / \"true\" are all OFF — the DEFAULT)"
else
  bad "function_coverage_enabled() changed polarity"
fi
if _agfn "$HUNTER" function_coverage_directive | grep -q 'if !function_coverage_enabled() { return ""; }'; then
  ok "function_coverage_directive() returns \"\" when the knob is off"
else
  bad "function_coverage_directive() lost its \"\"-when-off early return"
fi
if _agfn "$HUNTER" coverage_pass_block | grep -q 'if fns == "" { return ""; }'; then
  ok "coverage_pass_block() is \"\" without COVERAGE_REASK_FNS — every breadth/depth cell prompts identically"
else
  bad "coverage_pass_block() no longer short-circuits on an empty COVERAGE_REASK_FNS"
fi
if _agfn "$HUNTER" function_coverage_enabled | grep -q 'SEVERITY_RUBRIC\|GROUND_EVIDENCE\|OPERATIONALIZE_LENS\|PARAM_AUDIT'; then
  bad "function_coverage_enabled() reads another knob — one knob, one delta per arm"
else
  ok "function_coverage_enabled() reads no other knob"
fi

note "4) the SPLICE ORDER: + paudit -> + fcov -> + extres, and + depth -> + cpass ..."
L_PAU="$(grep -n '^  + paudit$' "$HUNTER" | head -1 | cut -d: -f1)"
L_FCV="$(grep -n '^  + fcov$' "$HUNTER" | head -1 | cut -d: -f1)"
L_EXT="$(grep -n '^  + extres$' "$HUNTER" | head -1 | cut -d: -f1)"
L_DEP="$(grep -n '^  + depth$' "$HUNTER" | head -1 | cut -d: -f1)"
L_CPS="$(grep -n '^  + cpass$' "$HUNTER" | head -1 | cut -d: -f1)"
L_APX="$(grep -n '^  + appx$' "$HUNTER" | head -1 | cut -d: -f1)"
if [ -n "$L_PAU" ] && [ -n "$L_FCV" ] && [ -n "$L_EXT" ] && [ "$L_PAU" -lt "$L_FCV" ] && [ "$L_FCV" -lt "$L_EXT" ] \
   && [ -n "$L_DEP" ] && [ -n "$L_CPS" ] && [ -n "$L_APX" ] && [ "$L_DEP" -lt "$L_CPS" ] && [ "$L_CPS" -lt "$L_APX" ]; then
  ok "the READ contract sits between the parameter audit and the resolver verb; the coverage frame right after the depth frame"
else
  bad "a #2256 splice point moved (paudit=$L_PAU fcov=$L_FCV extres=$L_EXT depth=$L_DEP cpass=$L_CPS appx=$L_APX)"
fi
if grep -q '^let fcov = function_coverage_directive();$' "$HUNTER" && grep -q '^let cpass = coverage_pass_block();$' "$HUNTER"; then
  ok "both blocks are assembled once, at top level, beside the other conditional reads"
else
  bad "hunter.ag no longer assembles the fcov/cpass top-level bindings"
fi

note "5) the single-class paths are byte-identical, and the answer contract asks for ONE class id ..."
if _agfn "$HUNTER" class_sections | grep -q 'if index_of(cls, ",") < 0 { return class_section(taxo, cls); }' \
   && _agfn "$HUNTER" class_field | grep -q 'if index_of(cls, ",") < 0 { return cls; }'; then
  ok "class_sections()/class_field() return class_section(cls) / cls VERBATIM for a single class id"
else
  bad "a single-class path of class_sections()/class_field() is no longer the verbatim input"
fi
if grep -q '^let classDoc = class_sections(getenv("TAXONOMY"), cls);$' "$HUNTER" \
   && grep -q '"CANDIDATE|<file:function:line>|class=" + class_field(cls) + "|<severity=Medium|High>|' "$HUNTER"; then
  ok "the lens and the CANDIDATE contract route through class_sections()/class_field()"
else
  bad "the lens or the CANDIDATE contract bypasses class_sections()/class_field()"
fi
if _agfn "$HUNTER" class_field | grep -q 'exactly ONE of'; then
  ok "on a class LIST the contract asks for exactly ONE class id (a lead never carries a list)"
else
  bad "class_field() no longer asks for exactly one id on a class list"
fi

note "6) TOKEN INVARIANTS: no #2256 token carries CANDIDATE|, SAFE or VERDICT| ..."
TOK_BAD=""
for tok in 'READ|' 'FUNCTION-COVERAGE|' 'COVERAGE-CELL|'; do
  case "$tok" in *'CANDIDATE|'*|*'SAFE'*|*'VERDICT|'*) TOK_BAD="$TOK_BAD $tok" ;; esac
done
BLOCK_FLAT="$(_flat "$(_agfn "$HUNTER" function_coverage_block)")"
case "$BLOCK_FLAT" in *'CANDIDATE|'*) TOK_BAD="$TOK_BAD block:CANDIDATE|" ;; esac
case "$BLOCK_FLAT" in *'READ|<file:function>|<what you checked there, naming a variable, call or condition from its body>'*) ;; *) TOK_BAD="$TOK_BAD grammar" ;; esac
case "$BLOCK_FLAT" in *'never itself a finding'*) ;; *) TOK_BAD="$TOK_BAD never-a-finding" ;; esac
if [ -z "$TOK_BAD" ]; then
  ok "no #2256 token (nor the READ contract text) contains CANDIDATE|/SAFE/VERDICT|; the READ grammar + never-a-finding clause are in the prompt"
else
  bad "a #2256 token or the READ contract is wrong:$TOK_BAD"
fi

note "7) OVERFITTING + DOMAIN-NOUN GUARD over the prompt-visible #2256 text ..."
PROMPT_TXT="$WORK/prompt-text.txt"
{
  _agfn "$HUNTER" function_coverage_marker
  _agfn "$HUNTER" function_coverage_block
  _agfn "$HUNTER" coverage_pass_block
  _agfn "$HUNTER" class_field
} > "$PROMPT_TXT"
DENY='Curve|Convex|Pendle|Balancer|Uniswap|Aave|Compound|useEth|use_eth|WETH|wrapNative|slot0|ERC-?[0-9]|\.sol'
GT_ID='(^|[^[:alnum:]_])[HM]-[0-9]{1,2}([^[:alnum:]_]|$)'
NOUNS='(^|[^[:alnum:]_])(fee|fees|deadline|deadlines|chain|chains|bridge|bridges|deposit|deposits|buffer|buffers|duration|durations|lockup|lockups|rounding|oracle|oracles|pool|pools|token|tokens|slippage|price|prices|vault|vaults|withdraw|liquidation|collateral)([^[:alnum:]_]|$)'
if [ ! -s "$PROMPT_TXT" ]; then
  bad "could not slice the #2256 prompt text out of hunter.ag"
elif grep -Eq "$DENY" "$PROMPT_TXT"; then
  bad "the #2256 text names a protocol/product/file specific"
elif grep -qi 'corpus-bench' "$PROMPT_TXT"; then
  bad "the #2256 text names the corpus"
elif grep -EqI "$GT_ID" "$PROMPT_TXT"; then
  bad "the #2256 text carries a ground-truth finding id"
elif grep -Eqi "$NOUNS" "$PROMPT_TXT"; then
  bad "the #2256 text carries a domain noun"
  grep -nEi "$NOUNS" "$PROMPT_TXT" | head -3 | sed 's/^/      /' >&2
else
  ok "the #2256 text names no protocol, product, file, corpus, ground-truth id or domain noun (pure-meta)"
fi
printf 'the Balancer vault takes a fee on Foo.sol and GT %s-9 confirms it\n' 'H' > "$WORK/planted.txt"
if grep -Eq "$DENY" "$WORK/planted.txt" && grep -EqI "$GT_ID" "$WORK/planted.txt" && grep -Eqi "$NOUNS" "$WORK/planted.txt"; then
  ok "the overfitting, ground-truth-id and domain-noun detectors all fire on a planted hint (negative control)"
else
  bad "a denylist detector does not fire on a planted hint — the guard is dead"
fi

note "8) substrate purity: the #2256 .ag code adds no embedded interpreter ..."
PURE="$WORK/pure.txt"
awk '/--- #2256 BREADTH FUNCTION-COVERAGE GATE/{f=1} f&&(/^let dir = getenv\("TARGET_DIR"\);$/||/^\/\/ --- #2264 BREADTH PROMISES/){exit} f{print}' "$HUNTER" \
  | grep -v '^[[:space:]]*//' > "$PURE"
if [ ! -s "$PURE" ] || ! grep -q 'fn function_coverage_block' "$PURE"; then
  bad "could not slice the #2256 block out of hunter.ag (header renamed?)"
elif grep -Eq 'exec sh|python3 -c|awk |sed -|[^a-z]date ' "$PURE"; then
  bad "the #2256 block introduced an embedded interpreter / exec sh escape"
elif [ "$(grep -c 'regex_split\|reduce(' "$PURE")" -gt 3 ]; then
  bad "the #2256 block grew per-element regex/reduce use beyond class_sections()/coverage_fn_count()"
else
  ok "no exec sh / embedded interpreter; the only fold is class_sections() over the zone's class list (bounded)"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 2 — WIRING
# ----------------------------------------------------------------------------------------------------------
note "9) exec.env_passthrough + the cell env carry both names (#1426) ..."
D_PASS="$(grep 'echo "exec.env_passthrough' "$DISCOVERY" | head -1)"
W_MISS=""
case "$D_PASS" in *FUNCTION_COVERAGE*) ;; *) W_MISS="$W_MISS FUNCTION_COVERAGE(passthrough)" ;; esac
case "$D_PASS" in *COVERAGE_REASK_FNS*) ;; *) W_MISS="$W_MISS COVERAGE_REASK_FNS(passthrough)" ;; esac
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
grep -q 'FUNCTION_COVERAGE="${FUNCTION_COVERAGE:-}"' "$DISCOVERY" || W_MISS="$W_MISS FUNCTION_COVERAGE(env)"
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
grep -q 'COVERAGE_REASK_FNS="$rc_cov_fns"' "$DISCOVERY" || W_MISS="$W_MISS COVERAGE_REASK_FNS(env)"
if [ -z "$W_MISS" ]; then ok "both names are allowlisted AND exported into the hunter cell env"; else bad "the #2256 wiring is incomplete:$W_MISS"; fi

note "10) the three tokens are RECORD BOUNDARIES in the SHIPPED awk joiner ..."
JWC_AWK="$WORK/join-wrapped.awk"
_shfn "$DISCOVERY" _join_wrapped_candidates | sed -n "/^  awk '\$/,/^  ' /p" | sed '1d; $d' > "$JWC_AWK"
if [ ! -s "$JWC_AWK" ]; then
  bad "could not extract the _join_wrapped_candidates awk program (reshaped?)"
else
  JB_BAD=""
  for tok in 'READ|Vault.sol:exit|checked the bound' 'FUNCTION-COVERAGE|vault|C1|on' 'COVERAGE-CELL|vault|C1,C6|2'; do
    printf 'CANDIDATE|Vault.sol:exit:48|C1|Medium|the exit leg reverts|deploy a\n  stub and assert the revert\n%s\nSAFE\n' "$tok" > "$WORK/wrap.log"
    JOINED="$(awk -f "$JWC_AWK" "$WORK/wrap.log")"
    if [ "$(printf '%s\n' "$JOINED" | grep -c 'CANDIDATE|' || true)" != "1" ] \
       || printf '%s\n' "$JOINED" | grep -q 'READ|\|COVERAGE' \
       || ! printf '%s\n' "$JOINED" | grep -q 'deploy a stub and assert the revert$'; then
      JB_BAD="$JB_BAD ${tok%%|*}"
    fi
  done
  if [ -z "$JB_BAD" ]; then ok "a READ|/FUNCTION-COVERAGE|/COVERAGE-CELL| line closes an open PTY-wrapped CANDIDATE record"; else bad "the joiner glued a #2256 line into a candidate:$JB_BAD"; fi
fi

note "11) the coverage block sits AFTER the depth pass and BEFORE the report footer ..."
L_DPASS="$(grep -n '^  DEPTH_PLAN="\$RUN/depth-plan.tsv"$' "$DISCOVERY" | head -1 | cut -d: -f1)"
L_DLOOP="$(grep -n '^  done < "\$DEPTH_PLAN"$' "$DISCOVERY" | head -1 | cut -d: -f1)"
L_FCB="$(grep -n '^# #2256 BREADTH FUNCTION-COVERAGE PASS' "$DISCOVERY" | head -1 | cut -d: -f1)"
L_NEG="$(grep -n '^# #1707: only a run with ZERO candidates AND ZERO failed cells' "$DISCOVERY" | head -1 | cut -d: -f1)"
if [ -n "$L_DPASS" ] && [ -n "$L_DLOOP" ] && [ -n "$L_FCB" ] && [ -n "$L_NEG" ] \
   && [ "$L_DPASS" -lt "$L_DLOOP" ] && [ "$L_DLOOP" -lt "$L_FCB" ] && [ "$L_FCB" -lt "$L_NEG" ]; then
  ok "the coverage pass runs after the depth pass (the depth plan never sees it) and before the rigorous-negative line"
else
  bad "the coverage block moved (depth-plan=$L_DPASS depth-loop-end=$L_DLOOP coverage=$L_FCB negative=$L_NEG)"
fi

note "12) both recorded-run filters drop phase:\"coverage\", and promotions pass only the first class ..."
if [ "$(grep -c 'c.get("phase") not in ("depth", "coverage")' "$DISCOVERY")" = "2" ] \
   && ! grep -q 'c.get("phase") != "depth"' "$DISCOVERY"; then
  ok "_probe_recorded_run and _seed_from_recorded_run both drop depth AND coverage cells"
else
  bad "a recorded-run filter still lets a coverage cell seed a depth plan"
fi
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
if grep -q '_rubric_promote "$rc_log" "${rc_cls%%,\*}"' "$DISCOVERY" && grep -q '_param_promote "$rc_log" "${rc_cls%%,\*}"' "$DISCOVERY"; then
  ok "both promotion calls pass the first class id only (a promoted lead never carries a class list)"
else
  bad "a promotion call passes the raw class list"
fi
# shellcheck disable=SC2016  # the single quotes are deliberate: these greps match LITERAL source text
if grep -q 'run_cell "$RUN" "$FC_SUBSYS" "$FC_CLS" "$FC_SCOPE" "$FC_LOG" "" "" "" "" "$FC_ITEMS"' "$DISCOVERY" \
   && grep -q 'scrape_cell_log "$FC_SUBSYS" "$FC_CLS" "$FC_LOG" .* coverage$' "$DISCOVERY"; then
  ok "the coverage cell runs through the unchanged run_cell (10th param) + scrape_cell_log (phase coverage)"
else
  bad "the coverage cell no longer goes through run_cell + scrape_cell_log"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 3 — inheritance.py zone-functions
# ----------------------------------------------------------------------------------------------------------
FXR="$WORK/fx-repo"
mkdir -p "$FXR/contracts" "$FXR/lib/oz"
{
  printf '%s\n' '// SPDX-License-Identifier: MIT'
  printf '%s\n' 'pragma solidity ^0.8.20;'
  printf '%s\n' 'import "./Base.sol";'
  printf '%s\n' 'interface IHook { function ping(uint256 a) external; }'
  printf '%s\n' 'library MathLib { function bump(uint256 x) public returns (uint256) { return x + 1; } }'
  printf '%s\n' 'contract Vault is Base, Owned {'
  printf '%s\n' '    uint256 public total;'
  printf '%s\n' '    uint256 public limit;'
  printf '%s\n' '    mapping(address => uint256) public pending;'
  printf '%s\n' '    function deposit(uint256 amount) external {'
  printf '%s\n' '        _pull(amount);'
  printf '%s\n' '    }'
  printf '%s\n' '    function deposit(uint256 amount, address onBehalf) external {'
  printf '%s\n' '        _pull(amount);'
  printf '%s\n' '        pending[onBehalf] = amount;'
  printf '%s\n' '    }'
  printf '%s\n' '    function withdraw('
  printf '%s\n' '        uint256 shares,'
  printf '%s\n' '        address receiver'
  printf '%s\n' '    ) external nonReentrant {'
  printf '%s\n' '        pending[receiver] = shares;'
  printf '%s\n' '    }'
  printf '%s\n' '    function setLimit(uint256 newLimit) external onlyOwner {'
  printf '%s\n' '        limit = newLimit;'
  printf '%s\n' '    }'
  printf '%s\n' '    function sweep(address to) external onlyOwner {'
  printf '%s\n' '        token.transfer(to, total);'
  printf '%s\n' '    }'
  printf '%s\n' '    function peek() external view returns (uint256) { return total; }'
  printf '%s\n' '    function calc(uint256 x) public pure returns (uint256) { return x; }'
  printf '%s\n' '    function _pull(uint256 amt) internal {'
  printf '%s\n' '        token.transferFrom(msg.sender, address(this), amt);'
  printf '%s\n' '        total += amt;'
  printf '%s\n' '    }'
  printf '%s\n' '    function _hidden() private { total = 0; }'
  printf '%s\n' '    function initialize(address o) external initializer { owner = o; }'
  printf '%s\n' '    function initializeV2() external { limit = 1; }'
  printf '%s\n' '    function upgradeHook() external reinitializer(2) { limit = 2; }'
  printf '%s\n' '    function setup() external onlyInitializing { limit = 3; }'
  printf '%s\n' '    function hook() external virtual;'
  printf '%s\n' '}'
} > "$FXR/contracts/Vault.sol"
{
  printf '%s\n' 'pragma solidity ^0.8.20;'
  printf '%s\n' 'import "../lib/oz/Owned.sol";'
  printf '%s\n' 'contract Base {'
  printf '%s\n' '    address public token;'
  printf '%s\n' '    function rescue(address to) external { payable(to).transfer(1); }'
  printf '%s\n' '    function withdraw(uint256 s, address r) external virtual { }'
  printf '%s\n' '}'
} > "$FXR/contracts/Base.sol"
printf '%s\n' 'contract Owned { address public owner; function transferOwnership(address n) external { owner = n; } }' > "$FXR/lib/oz/Owned.sol"
{
  printf '%s\n' 'pragma solidity ^0.8.20;'
  printf '%s\n' 'contract Big {'
  printf '%s\n' '    uint256 public stored;'
  i=1; while [ "$i" -le 2050 ]; do printf '    // filler line %s\n' "$i"; i=$((i + 1)); done
  printf '%s\n' '    function late(uint256 v) external { stored = v; }'
  printf '%s\n' '}'
} > "$FXR/contracts/Big.sol"
{
  printf '%s\n' 'abstract contract Abs {'
  printf '%s\n' '    function run() external virtual;'
  printf '%s\n' '    function _x() internal virtual;'
  printf '%s\n' '}'
} > "$FXR/contracts/Abs.sol"
{
  printf '%s\n' 'import "./Abs.sol";'
  printf '%s\n' 'contract Impl is Abs {'
  printf '%s\n' '    function run() external override { }'
  printf '%s\n' '    function _x() internal override { }'
  printf '%s\n' '}'
} > "$FXR/contracts/Impl.sol"
FXF="contracts/Vault.sol"

_zf() { python3 "$INHERIT" zone-functions --repo "$FXR" --files "$1"; }

note "13) zone-functions: the gate predicate, overload dedupe, multi-line header, rank, and the INH record ..."
ZF_OUT="$(_zf "$FXF")"; ZF_RC=$?
_eq "exit 0 on a valid call" "$ZF_RC" "0"
_eq "FN rows in RANK order: value/open, value/guarded, state/open, state/guarded" \
  "$(printf '%s\n' "$ZF_OUT" | awk -F'\t' '$1 == "FN" { printf "%s:%s:%s ", $3, $4, $5 }')" \
  "deposit:value:open sweep:value:guarded withdraw:state:open setLimit:state:guarded "
EXCL_BAD=""
for x in peek calc _pull _hidden initialize initializeV2 upgradeHook setup hook ping bump; do
  printf '%s\n' "$ZF_OUT" | awk -F'\t' -v f="$x" '$1 == "FN" && $3 == f { found = 1 } END { exit (found ? 0 : 1) }' && EXCL_BAD="$EXCL_BAD $x"
done
if [ -z "$EXCL_BAD" ]; then
  ok "view, pure, internal, private, the initializer family (name/initializer/reinitializer/onlyInitializing), body-less virtual, interface and library functions are all excluded"
else
  bad "a function that must not be gated is gated:$EXCL_BAD"
fi
_eq "the two deposit overloads dedupe into ONE row" "$(printf '%s\n' "$ZF_OUT" | awk -F'\t' '$1 == "FN" && $3 == "deposit"' | wc -l | tr -d ' ')" "1"
_eq "a thin external wrapper is VALUE through its one-hop internal callee; its identifiers include the callee's body" \
  "$(printf '%s\n' "$ZF_OUT" | awk -F'\t' '$3 == "deposit" { print $4 ":" ($6 ~ /(^| )_pull( |$)/ && $6 ~ /(^| )transferFrom( |$)/ && $6 !~ /(^| )deposit( |$)/ ? "ids-ok" : "ids-bad") }')" "value:ids-ok"
_eq "the multi-line header parses (withdraw) and its body identifiers are extracted" \
  "$(printf '%s\n' "$ZF_OUT" | awk -F'\t' '$3 == "withdraw" { print $6 }')" "pending receiver shares"
_eq "an own-source base OUTSIDE the line is recorded as INH (never gated); the overridden base function and the vendored base are not" \
  "$(printf '%s\n' "$ZF_OUT" | awk -F'\t' '$1 == "INH" { printf "%s:%s:%s ", $2, $3, $4 }')" "contracts/Base.sol:rescue:value "
_eq "a rel@fn slice restricts the gate to its (gated) names" \
  "$(_zf "$FXF@setLimit+peek+_pull" | awk -F'\t' '$1 == "FN" { printf "%s ", $3 }')" "setLimit "
_eq "a function past line 2000 of a whole file IS gated (breadth never saw it)" \
  "$(_zf "contracts/Big.sol" | awk -F'\t' '$1 == "FN" { printf "%s ", $3 }')" "late "
NOTHING="$(_zf "programs/x.rs,contracts/Missing.sol,/etc/passwd.sol,../escape.sol,contracts/../contracts/Vault.sol")"; NRC=$?
_eq ".rs, missing, absolute and .. tokens contribute nothing, with exit 0" "${NOTHING:-<empty>}:$NRC" "<empty>:0"
python3 "$INHERIT" zone-functions --repo "$FXR" >/dev/null 2>&1; U_RC=$?
python3 "$INHERIT" zone-functions --repo "$WORK/nope" --files x.sol >/dev/null 2>&1; R_RC=$?
_eq "usage error exits 2, an unreadable --repo exits 3" "$U_RC:$R_RC" "2:3"

note "14) the other subcommands' output is UNCHANGED vs origin/main on the same fixtures ..."
if git -C "$HERE" cat-file -e origin/main:dark-factory/lib/inheritance.py 2>/dev/null; then
  git -C "$HERE" show origin/main:dark-factory/lib/inheritance.py > "$WORK/inheritance.origin.py"
  printf '[{"id":"z","files":["contracts/Vault.sol","contracts/Abs.sol"],"scope_files":["contracts/Vault.sol","contracts/Abs.sol"]}]\n' > "$WORK/zones.json"
  SUB_BAD=""
  for v in origin new; do
    if [ "$v" = origin ]; then PY="$WORK/inheritance.origin.py"; else PY="$INHERIT"; fi
    D="$WORK/sub-$v"; mkdir -p "$D"
    python3 "$PY" appendix --zones "$WORK/zones.json" --repo "$FXR" > "$D/appendix" 2>&1
    python3 "$PY" implementor --repo "$FXR" --file contracts/Abs.sol > "$D/implementor" 2>&1
    python3 "$PY" reach-targets --zones "$WORK/zones.json" --repo "$FXR" --max 3 > "$D/reach-targets" 2>&1
    python3 "$PY" reach-inventory --repo "$FXR" --target contracts/Vault.sol --out-tsv "$D/ri.tsv" --out-inventory "$D/ri.inv" > "$D/reach-inventory" 2>&1
    python3 "$PY" promise-sources --repo "$FXR" --target contracts/Vault.sol --out "$D/ps.txt" > "$D/promise-sources" 2>&1
  done
  for f in appendix implementor reach-targets reach-inventory promise-sources ri.tsv ri.inv ps.txt; do
    cmp -s "$WORK/sub-origin/$f" "$WORK/sub-new/$f" || SUB_BAD="$SUB_BAD $f"
  done
  if [ -z "$SUB_BAD" ] && [ -s "$WORK/sub-new/ri.tsv" ] && [ -s "$WORK/sub-new/implementor" ]; then
    ok "appendix / implementor / reach-targets / reach-inventory / promise-sources are byte-identical to origin/main's"
  else
    bad "a pre-existing subcommand's output changed:$SUB_BAD"
  fi
else
  skip "origin/main not available in this checkout — demo-map-zones/-verify-findings/-deep-hunt-reach still pin those subcommands"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 4 — THE GATE, FIXTURE-DRIVEN (the shipped functions, sliced — never copied)
# ----------------------------------------------------------------------------------------------------------
note "15) the shipped gate block slices out of run-discovery.sh and loads ..."
FNS="$WORK/gate-fns.sh"
{
  for fn in _count_stdin _json_str _distinct_sentinel_count _join_wrapped_candidates _dismiss_lines _param_lines \
            _param_fn_of _rubric_promoted_candidates _param_promoted_candidates _cell_candidates; do
    _shfn "$DISCOVERY" "$fn"
  done
  grep '^_json_str() {' "$DISCOVERY"
  sed -n '/^# --- #2256: THE BREADTH FUNCTION-COVERAGE GATE/,/^# --- end #2256 block ---$/p' "$DISCOVERY"
} > "$FNS"
FNS_OK=1
for need in _fcov_enabled _fcov_cap _fcov_armed _fcov_answered _fcov_functions _fcov_breadth_logs _fcov_trace_rows \
            _fcov_read_grounded _fcov_table _fcov_ungrounded _fcov_listed _fcov_over_cap _fcov_scope_tokens _fcov_items \
            _fcov_record_json _param_fn_of _cell_candidates _json_str; do
  grep -q "^$need() {" "$FNS" || { FNS_OK=0; bad "could not slice $need out of run-discovery.sh"; }
done
if [ "$FNS_OK" -eq 1 ]; then
  # shellcheck disable=SC1090  # sliced out of run-discovery.sh at runtime, by design
  . "$FNS"
  ok "the #2256 gate block (and the shipped helpers it reuses) extracted and sourced"
fi

# _cl <name> <line...> — write a synthetic cell log and print its path.
_cl() {
  _cl_path="$WORK/$1.log"; shift
  : > "$_cl_path"
  for _cl_line in "$@"; do printf '%s\n' "$_cl_line" >> "$_cl_path"; done
  printf '%s\n' "$_cl_path"
}
SENT='FUNCTION-COVERAGE|vault|C1|on'
# The synthetic gated set (zone-functions' row shape): three functions with known body identifiers.
F3="$WORK/f3.fns"
{
  printf 'FN\t%s\tdeposit\tvalue\topen\t_pull amount total\n' "$FXF"
  printf 'FN\t%s\tsweep\tvalue\tguarded\ttoken transfer total\n' "$FXF"
  printf 'FN\t%s\tsetLimit\tstate\tguarded\tlimit newLimit\n' "$FXF"
  printf 'INH\tcontracts/Base.sol\trescue\tvalue\topen\t-\n'
} > "$F3"

if [ "$FNS_OK" -eq 1 ]; then
  note "16) FIRE: two functions covered (a grounded READ, a DISMISS), one untouched -> exactly that one is listed ..."
  L1="$(_cl fire "$SENT" "READ|$FXF:deposit|traced _pull into the running total" "DISMISS|$FXF:sweep:27|guard|$FXF:25 onlyOwner" "SAFE")"
  _fcov_table "$F3" "$L1" > "$WORK/fire.table"
  _eq "covered-by per function" "$(cut -f2,5 "$WORK/fire.table" | tr '\t\n' ': ')" "deposit:read sweep:dismiss setLimit:none "
  _eq "listed = exactly the untouched one" "$(_fcov_listed "$WORK/fire.table" | cut -f2 | tr '\n' ' ')" "setLimit "
  _eq "the coverage cell's IN_SCOPE is one rel@fn token per file" "$(_fcov_scope_tokens "$FXF,contracts/Base.sol" "$(_fcov_listed "$WORK/fire.table")")" "$FXF@setLimit"
  _eq "the coverage cell is told rel:fn" "$(_fcov_items "$(_fcov_listed "$WORK/fire.table")")" "$FXF:setLimit"
  if _fcov_armed "$L1"; then ok "the sentinel arms the gate"; else bad "a log with FUNCTION-COVERAGE| does not arm the gate"; fi
  REC="$(_fcov_record_json vault "$FXF" "$F3" "$WORK/fire.table" ran "$WORK/nothing.after" 0)"
  if printf '%s\n' "$REC" | python3 -c '
import sys, json
r = json.loads(sys.stdin.read())
assert r["total"] == 3 and r["value_moving"] == 2 and r["covered"] == 2, r
assert r["covered_by"] == {"read": 1, "dismiss": 1, "candidate": 0, "param": 0, "callee_vector": 0}, r["covered_by"]
assert r["uncovered"] == ["contracts/Vault.sol:setLimit"] and r["listed"] == ["contracts/Vault.sol:setLimit"], r
assert r["over_cap"] == [] and r["coverage_cell"] == "ran" and r["inherited_outside"] == 1, r
assert r["still_untouched"] == ["contracts/Vault.sol:setLimit"], r
'; then ok "the function_coverage record carries the plan's key set and values"; else bad "the record is wrong: $REC"; fi

  note "17) NEGATIVE CONTROL: every function covered once (READ, DISMISS, CANDIDATE, PARAM) -> nothing listed ..."
  F4="$WORK/f4.fns"
  { cat "$F3"; printf 'FN\t%s\twithdraw\tstate\topen\tpending receiver shares\n' "$FXF"; } > "$F4"
  L2="$(_cl ctl "$SENT" "READ|$FXF:deposit|_pull is the only writer" "DISMISS|$FXF:sweep|guard|onlyOwner" \
        "CANDIDATE|$FXF:setLimit:23|C1|Medium|the limit write is unbounded|set it and assert" "PARAM|#1|$FXF:withdraw|shares|caller")"
  _fcov_table "$F4" "$L2" > "$WORK/ctl.table"
  _eq "each function has its own covering kind" "$(cut -f2,5 "$WORK/ctl.table" | tr '\t\n' ': ')" "deposit:read sweep:dismiss setLimit:candidate withdraw:param "
  _eq "nothing is listed" "$(_fcov_listed "$WORK/ctl.table" | _count_stdin)" "0"
  REC2="$(_fcov_record_json vault "$FXF" "$F4" "$WORK/ctl.table" none "$WORK/nothing.after" 0)"
  if printf '%s\n' "$REC2" | grep -q '"coverage_cell":"none"' && printf '%s\n' "$REC2" | grep -q '"listed":\[\]' \
     && printf '%s\n' "$REC2" | grep -q '"covered_by":{"read":1,"dismiss":1,"candidate":1,"param":1,"callee_vector":0}'; then
    ok "coverage_cell:\"none\", an empty listed[], and one count per trace kind"
  else
    bad "the control record is wrong: $REC2"
  fi
  L2B="$(_cl ctlcv "$SENT" "CALLEE-VECTOR|setLimit|token.transfer|reentrant|dismissed: immutable")"
  _eq "a CALLEE-VECTOR| line covers its function too" "$(_fcov_table "$F3" "$L2B" | awk -F'\t' '$2 == "setLimit" { print $5 }')" "callee_vector"

  note "18) GROUNDING: an ungrounded READ (\"checked, fine\") covers nothing and is counted ..."
  L3="$(_cl ungr "$SENT" "READ|$FXF:setLimit|checked, fine" "READ|$FXF:deposit|traced _pull" "READ|$FXF:nowhere|an internal helper, not gated" "SAFE")"
  _eq "the ungrounded READ leaves setLimit untouched" "$(_fcov_table "$F3" "$L3" | awk -F'\t' '$2 == "setLimit" { print $5 }')" "none"
  _eq "reads_ungrounded counts it (the grounded one and the non-gated one are not counted)" "$(_fcov_ungrounded "$F3" "$L3")" "1"
  if _fcov_read_grounded "raised limit above the old value" "limit newLimit" && ! _fcov_read_grounded "checked, fine" "limit newLimit" \
     && _fcov_read_grounded "anything" "-"; then
    ok "_fcov_read_grounded: a body identifier grounds, prose does not, an empty body (-) accepts any READ"
  else
    bad "_fcov_read_grounded decides wrongly"
  fi

  note "19) LOCATION MATCH: Router.sol:deposit does not cover Vault.sol:deposit; a bare deposit covers both ..."
  FRD="$WORK/frd.fns"
  { printf 'FN\t%s\tdeposit\tvalue\topen\t_pull amount\n' "$FXF"; printf 'FN\tcontracts/Router.sol\tdeposit\tvalue\topen\troute amount\n'; } > "$FRD"
  LR="$(_cl router "$SENT" "DISMISS|contracts/Router.sol:deposit|guard|routes only")"
  _eq "file-qualified location covers its own file only" "$(_fcov_table "$FRD" "$LR" | cut -f1,5 | tr '\t\n' '= ')" "$FXF=none contracts/Router.sol=dismiss "
  LB="$(_cl bare "$SENT" "DISMISS|deposit|guard|both guarded")"
  _eq "a bare function name covers every file's function of that name" "$(_fcov_table "$FRD" "$LB" | cut -f5 | tr '\n' ' ')" "dismiss dismiss "

  note "20) SUPERSEDED ATTEMPTS never count; NO SENTINEL is unarmed; no answered cell is detected ..."
  RD="$WORK/attrun"; mkdir -p "$RD"
  printf '%s\nSAFE\n' "$SENT" > "$RD/hunt_v_C1.log"
  printf '%s\nREAD|%s:setLimit|limit raised\nSAFE\n' "$SENT" "$FXF" > "$RD/hunt_v_C1.log.untraced-attempt-1"
  ATT_LOGS="$(_fcov_breadth_logs "$RD" v C1)"
  _eq "the breadth log lister names the final log only" "$ATT_LOGS" "$RD/hunt_v_C1.log"
  _eq "... so the trace in the superseded attempt covers nothing" "$(_fcov_table "$F3" "$ATT_LOGS" | awk -F'\t' '$2 == "setLimit" { print $5 }')" "none"
  L4="$(_cl unarmed "READ|$FXF:deposit|traced _pull" "SAFE")"
  if _fcov_armed "$L4"; then bad "a log with no FUNCTION-COVERAGE| arms the gate"; else ok "no sentinel => unarmed (the gate reads the SENTINEL, never the env)"; fi
  L5="$(_cl novalid "$SENT")"; : > "$L5.novalid"
  L6="$(_cl timeout "$SENT")"; : > "$L6.timeout"
  if ! _fcov_answered "$L5" "$L6" && _fcov_answered "$L5" "$L1"; then
    ok "every breadth cell .novalid/.timeout => no answered cell; one answered cell is enough"
  else
    bad "_fcov_answered misjudges .novalid/.timeout cells"
  fi

  note "21) CAP: 15 untouched functions -> 12 listed (value/open first) and 3 over_cap ..."
  CAPR="$WORK/cap-repo"; mkdir -p "$CAPR/contracts"
  {
    printf '%s\n' 'contract Many {'
    printf '%s\n' '    uint256 public x;'
    i=1; while [ "$i" -le 15 ]; do
      case $((i % 4)) in
        0) printf '    function f%s(uint256 v) external { x = v; }\n' "$i" ;;
        1) printf '    function f%s(uint256 v) external onlyOwner { x = v; }\n' "$i" ;;
        2) printf '    function f%s(uint256 v) external onlyOwner { x += v; }\n' "$i" ;;
        3) printf '    function f%s(uint256 v) external { x -= v; }\n' "$i" ;;
      esac
      i=$((i + 1))
    done
    printf '%s\n' '}'
  } > "$CAPR/contracts/Many.sol"
  _fcov_functions "$INHERIT" "$CAPR" "contracts/Many.sol" > "$WORK/cap.fns"
  CL="$(_cl caplog "$SENT" "SAFE")"
  _fcov_table "$WORK/cap.fns" "$CL" > "$WORK/cap.table"
  _eq "15 gated functions, all untouched" "$(awk -F'\t' '$5 == "none"' "$WORK/cap.table" | _count_stdin)" "15"
  _eq "12 listed" "$(_fcov_listed "$WORK/cap.table" | _count_stdin)" "12"
  _eq "3 over the cap: the LAST three of the lowest rank (state/guarded, declaration order)" \
    "$(_fcov_over_cap "$WORK/cap.table" | cut -f2 | tr '\n' ' ')" "f5 f9 f13 "
  _eq "the listed head is value/open first (f3 f7 f11 f15 -x)" "$(_fcov_listed "$WORK/cap.table" | head -4 | cut -f2 | tr '\n' ' ')" "f3 f7 f11 f15 "
fi

# ----------------------------------------------------------------------------------------------------------
# PART 5 — END-TO-END through run-discovery.sh (offline --agentis stub, no LLM)
# ----------------------------------------------------------------------------------------------------------
# The stub replaces the SUBSTRATE, so this part tests the DRIVER half. It prints the sentinels itself (only when the
# knob would have rendered them), scripted trace lines per STUB_MODE / STUB_COV, and records what the coverage cell
# was handed (COVERAGE_REASK_FNS, IN_SCOPE, HUNT_CLASS).
HSTUB="$WORK/agentis-hunt-stub"
cat > "$HSTUB" <<'STUBEOF'
#!/bin/sh
set -u
F=contracts/Vault.sol
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    if [ "${FUNCTION_COVERAGE:-}" = "1" ] && [ "${STUB_ARM:-1}" = "1" ]; then printf 'FUNCTION-COVERAGE|%s|%s|on\n' "${SUBSYSTEM:-}" "${HUNT_CLASS:-}"; fi
    if [ -n "${COVERAGE_REASK_FNS:-}" ]; then
      printf 'COVERAGE-CELL|%s|%s|n\n' "${SUBSYSTEM:-}" "${HUNT_CLASS:-}"
      [ -n "${STUB_REC:-}" ] && printf 'FNS=%s\nSCOPE=%s\nCLASS=%s\n' "$COVERAGE_REASK_FNS" "$(printf '%s' "${IN_SCOPE:-}" | tr '\n' ',')" "${HUNT_CLASS:-}" >> "$STUB_REC"
      case "${STUB_COV:-all}" in
        all)     printf 'READ|%s:withdraw|pending[receiver] is written from shares\nREAD|%s:setLimit|limit = newLimit\n' "$F" "$F" ;;
        partial) printf 'READ|%s:withdraw|pending[receiver] is written from shares\n' "$F" ;;
        cand)    printf 'READ|%s:withdraw|pending[receiver] is written from shares\n' "$F"
                 printf 'CANDIDATE|%s:setLimit:24|class=C6|Medium|the limit accepts any value|set it and assert\n' "$F"
                 exit 0 ;;
      esac
      printf 'SAFE\n'; exit 0
    fi
    if [ -n "${DEPTH_TARGET:-}" ]; then printf 'SAFE\n'; exit 0; fi
    case "${STUB_MODE:-fire}" in
      novalid) exit 0 ;;
      all)
        printf 'READ|%s:deposit|traced _pull into total\n' "$F"
        printf 'DISMISS|%s:sweep|guard|%s:26 onlyOwner\n' "$F" "$F"
        printf 'PARAM|#1|%s:withdraw|shares|caller\nPARAM-TRACE|#1|unbounded|written to pending\n' "$F"
        printf 'READ|%s:setLimit|limit is overwritten\n' "$F" ;;
      *)
        printf 'READ|%s:deposit|traced _pull into total\n' "$F"
        printf 'DISMISS|%s:sweep|guard|%s:26 onlyOwner\n' "$F" "$F" ;;
    esac
    if [ "${STUB_CAND:-0}" = "1" ] && [ "${HUNT_CLASS:-}" = "C1" ]; then
      printf 'CANDIDATE|%s:deposit:10|C1|High|the pull is not checked|deposit and assert\n' "$F"
      exit 0
    fi
    printf 'SAFE\n'; exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$HSTUB"
HREPO="$WORK/h-repo"; mkdir -p "$HREPO/contracts"
cp "$FXR/contracts/Vault.sol" "$FXR/contracts/Base.sol" "$HREPO/contracts/"
printf 'vault | C1,C6 | contracts/Vault.sol\n' > "$WORK/h-scope.tsv"
printf '# brief\nInvariants to break: the documented paths stay available.\nKnown issues to exclude: none.\n' > "$WORK/h-brief.md"

# _hunt <label> [extra run-discovery args...] — one offline hunt of the fixture line; prints the out dir.
_hunt() {
  _h_label="$1"; shift
  "$DISCOVERY" --repo "$HREPO" --scope "$WORK/h-scope.tsv" --brief "$WORK/h-brief.md" \
    --backend mock --agentis "$HSTUB" --out "$WORK/$_h_label" "$@" > "$WORK/$_h_label.out" 2>&1 || true
  printf '%s\n' "$WORK/$_h_label"
}
# _jq <results.json> <python expression over d> — print one value from a results file.
_jq() {
  python3 -c 'import sys, json; d = json.load(open(sys.argv[1], encoding="utf-8")); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null
}

note "22) end-to-end (a) FIRE: exactly ONE extra coverage cell, narrowed and class-listed ..."
STUB_REC="$WORK/rec-a.txt"; export STUB_REC
A="$(FUNCTION_COVERAGE=1 STUB_MODE=fire STUB_COV=all _hunt ea)"
AJ="$A/discovery-results.json"
_eq "totals.cells = 2 breadth + 1 coverage, totals.coverage_cells = 1" "$(_jq "$AJ" '(d["totals"]["cells"], d["totals"]["coverage_cells"])')" "(3, 1)"
_eq "the coverage cell is the one phase:coverage cell, class list + narrowed files" \
  "$(_jq "$AJ" '[(c["class"], c["files"]) for c in d["cells"] if c.get("phase") == "coverage"]')" "[('C1,C6', 'contracts/Vault.sol@withdraw+setLimit')]"
_eq "the cell was handed the rel:fn list, the narrowed IN_SCOPE and the class list" "$(tr '\n' ' ' < "$STUB_REC")" \
  "FNS=contracts/Vault.sol:withdraw, contracts/Vault.sol:setLimit SCOPE=contracts/Vault.sol@withdraw+setLimit CLASS=C1,C6 "
_eq "the record: ran, 2 of 4 covered, listed 2, nothing left untouched" \
  "$(_jq "$AJ" '(lambda r: (r["coverage_cell"], r["total"], r["covered"], r["listed"], r["still_untouched"], r["inherited_outside"]))(d["function_coverage"][0])')" \
  "('ran', 4, 2, ['contracts/Vault.sol:withdraw', 'contracts/Vault.sol:setLimit'], [], 1)"
if [ -f "$A/run/hunt_vault_coverage.log" ] && grep -q '^COVERAGE-CELL|vault|C1,C6|' "$A/run/hunt_vault_coverage.log" \
   && [ -s "$A/run/function-coverage_vault.tsv" ] && grep -q ', 1 coverage, ' "$A.out" \
   && grep -q '^- Function coverage (#2256) `vault`: 2/4 gated function(s)' "$A/discovery-report.md"; then
  ok "the coverage log, the sidecar, the banner suffix and the report footer line are all there"
else
  bad "a #2256 artifact is missing (log/sidecar/banner/footer)"
fi
_eq "the sidecar records breadth and after-coverage-cell coverage" "$(cut -f2,5,6 "$A/run/function-coverage_vault.tsv" | tr '\t\n' ': ')" \
  "deposit:read:- sweep:dismiss:- withdraw:none:read setLimit:none:read "
_eq "an armed cell carries the per-cell reads dosage key" "$(_jq "$AJ" '[c.get("reads") for c in d["cells"]]')" "[1, 1, 2]"

note "23) end-to-end (b) NEGATIVE CONTROL: breadth traced everything -> zero extra cells ..."
B="$(FUNCTION_COVERAGE=1 STUB_MODE=all _hunt eb)"
_eq "totals.cells stays 2, coverage_cells 0, record none" \
  "$(_jq "$B/discovery-results.json" '(d["totals"]["cells"], d["totals"]["coverage_cells"], d["function_coverage"][0]["coverage_cell"])')" "(2, 0, 'none')"
if [ ! -e "$B/run/hunt_vault_coverage.log" ]; then ok "no coverage log was written"; else bad "a coverage cell ran on a fully traced line"; fi

note "24) end-to-end (c) KNOB OFF: report + results JSON byte-identical to FUNCTION_COVERAGE=0 and to origin/main ..."
C1D="$(STUB_MODE=fire _hunt ec1)"
C2D="$(FUNCTION_COVERAGE=0 STUB_MODE=fire _hunt ec2)"
C3D="$(FUNCTION_COVERAGE=true STUB_MODE=fire _hunt ec3)"
if cmp -s "$C1D/discovery-report.md" "$C2D/discovery-report.md" && cmp -s "$C1D/discovery-results.json" "$C2D/discovery-results.json" \
   && cmp -s "$C1D/discovery-report.md" "$C3D/discovery-report.md" && cmp -s "$C1D/discovery-results.json" "$C3D/discovery-results.json"; then
  ok "unset, 0 and \"true\" produce the same report and results JSON (only the literal 1 opts in)"
else
  bad "the knob-OFF values disagree"
fi
OFF_BAD=""
for d in "$C1D" "$C2D" "$C3D"; do
  for g in "$d/run/fcov" "$d/run/fcov-lines.tsv" "$d/run/function-coverage_vault.tsv" "$d/run/hunt_vault_coverage.log"; do
    [ -e "$g" ] && OFF_BAD="$OFF_BAD ${g##*/}"
  done
  grep -q 'function_coverage\|coverage_cells\|"reads"' "$d/discovery-results.json" && OFF_BAD="$OFF_BAD json-key"
  grep -q 'coverage,' "$d.out" && OFF_BAD="$OFF_BAD banner"
done
if [ -z "$OFF_BAD" ]; then ok "knob off: no sidecar, no fcov file, no coverage log, no JSON key, no banner suffix"; else bad "the knob-OFF run is NOT inert:$OFF_BAD"; fi
if git -C "$HERE" cat-file -e origin/main:dark-factory/run-discovery.sh 2>/dev/null \
   && ! git -C "$HERE" show origin/main:dark-factory/run-discovery.sh | grep -q '_fcov_enabled'; then
  OSHIM="$WORK/origin-shim"; mkdir -p "$OSHIM"
  for _f in "$HERE"/*; do
    _b="$(basename "$_f")"
    [ "$_b" = "run-discovery.sh" ] && continue
    ln -s "$_f" "$OSHIM/$_b"
  done
  git -C "$HERE" show origin/main:dark-factory/run-discovery.sh > "$OSHIM/run-discovery.sh"
  chmod +x "$OSHIM/run-discovery.sh"
  STUB_MODE=fire "$OSHIM/run-discovery.sh" --repo "$HREPO" --scope "$WORK/h-scope.tsv" --brief "$WORK/h-brief.md" \
    --backend mock --agentis "$HSTUB" --out "$WORK/eco" > "$WORK/eco.out" 2>&1 || true
  if cmp -s "$C1D/discovery-report.md" "$WORK/eco/discovery-report.md" && cmp -s "$C1D/discovery-results.json" "$WORK/eco/discovery-results.json" \
     && [ "$(grep -c '' "$C1D.out")" = "$(grep -c '' "$WORK/eco.out")" ]; then
    ok "knob off: the report and the results JSON are byte-identical to origin/main's run-discovery.sh"
  else
    bad "knob off differs from origin/main's run-discovery.sh"
    diff "$C1D/discovery-results.json" "$WORK/eco/discovery-results.json" | head -4 | sed 's/^/      /' >&2
  fi
else
  skip "origin/main (pre-#2256) run-discovery.sh not available — the unset/0/true comparison above stands in"
fi

note "25) end-to-end (d) --jobs 2 yields the same record and coverage cell as --jobs 1 ..."
unset STUB_REC
D1="$(FUNCTION_COVERAGE=1 STUB_MODE=fire STUB_COV=all _hunt ed1 --jobs 1)"
D2="$(FUNCTION_COVERAGE=1 STUB_MODE=fire STUB_COV=all _hunt ed2 --jobs 2)"
_eq "function_coverage[] and the coverage cell object are identical across --jobs" \
  "$(_jq "$D1/discovery-results.json" '(d["function_coverage"], [c for c in d["cells"] if c.get("phase") == "coverage"]) == (lambda e: (e["function_coverage"], [c for c in e["cells"] if c.get("phase") == "coverage"]))(json.load(open(sys.argv[1].replace("ed1", "ed2"), encoding="utf-8")))')" "True"
[ -f "$D2/discovery-results.json" ] || bad "the --jobs 2 run produced no results"

note "26) end-to-end (e) every breadth cell .novalid -> skipped:no-answered-cell, no cell ..."
E="$(FUNCTION_COVERAGE=1 STUB_MODE=novalid DF_AGENT_MAX_ATTEMPTS=1 _hunt ee)"
_eq "skipped:no-answered-cell and no coverage cell" \
  "$(_jq "$E/discovery-results.json" '(d["function_coverage"][0]["coverage_cell"], d["totals"]["coverage_cells"], d["totals"]["failed"])')" "('skipped:no-answered-cell', 0, 2)"

note "27) end-to-end (f) a coverage cell that leaves a listed function untraced -> still_untouched, no second cell ..."
F="$(FUNCTION_COVERAGE=1 STUB_MODE=fire STUB_COV=partial _hunt ef)"
_eq "still_untouched names the function the coverage cell skipped; one coverage cell only" \
  "$(_jq "$F/discovery-results.json" '(d["function_coverage"][0]["still_untouched"], d["totals"]["coverage_cells"], len([c for c in d["cells"] if c.get("phase") == "coverage"]))')" \
  "(['contracts/Vault.sol:setLimit'], 1, 1)"
_eq "exactly one hunt_*_coverage.log" "$(find "$F/run" -name 'hunt_*_coverage.log*' | wc -l | tr -d ' ')" "1"

note "28) end-to-end (g) --depth-max-cells 1: the depth plan is unchanged and the coverage cell follows the depth cell ..."
G_ON="$(FUNCTION_COVERAGE=1 STUB_MODE=fire STUB_CAND=1 STUB_COV=all _hunt eg-on --depth-max-cells 1)"
G_OFF="$(STUB_MODE=fire STUB_CAND=1 _hunt eg-off --depth-max-cells 1)"
if [ -s "$G_ON/run/depth-plan.tsv" ] && cmp -s <(cut -f1-3 "$G_ON/run/depth-plan.tsv") <(cut -f1-3 "$G_OFF/run/depth-plan.tsv"); then
  ok "the depth plan is identical with the knob on and off ($(cut -f1-3 "$G_ON/run/depth-plan.tsv" | tr '\t' ' '))"
else
  bad "the coverage gate changed the depth plan"
fi
_eq "cells[] order: breadth, breadth, depth, coverage" "$(_jq "$G_ON/discovery-results.json" '[c.get("phase", "breadth") for c in d["cells"]]')" \
  "['breadth', 'breadth', 'depth', 'coverage']"

note "29) end-to-end (h) a coverage-cell candidate reaches the report and candidates[] with ONE class id ..."
H="$(FUNCTION_COVERAGE=1 STUB_MODE=fire STUB_COV=cand _hunt eh)"
_eq "the coverage cell's candidate carries class=C6, never the list" \
  "$(_jq "$H/discovery-results.json" '[c["candidates"] for c in d["cells"] if c.get("phase") == "coverage"]')" \
  "[['contracts/Vault.sol:setLimit:24|class=C6|Medium|the limit accepts any value|set it and assert']]"
if grep -q '| vault | C1,C6 | contracts/Vault.sol:setLimit:24 / class=C6 / Medium' "$H/discovery-report.md"; then
  ok "the lead reached discovery-report.md"
else
  bad "the coverage-cell lead never reached discovery-report.md"
fi

note "30) end-to-end (i) no FUNCTION-COVERAGE| sentinel in any breadth log -> skipped:unarmed ..."
I="$(FUNCTION_COVERAGE=1 STUB_ARM=0 STUB_MODE=fire _hunt ei)"
_eq "skipped:unarmed, no coverage cell" "$(_jq "$I/discovery-results.json" '(d["function_coverage"][0]["coverage_cell"], d["totals"]["coverage_cells"])')" "('skipped:unarmed', 0)"
note "30b) --depth-from ignores the knob, and a recorded coverage cell is never carried as a breadth cell ..."
FUNCTION_COVERAGE=1 "$DISCOVERY" --repo "$HREPO" --brief "$WORK/h-brief.md" --backend mock --agentis "$HSTUB" --out "$WORK/ej3" \
  --depth-max-cells 1 --depth-from "$A/discovery-results.json" > "$WORK/ej3.out" 2>&1 || true
if grep -q 'FUNCTION_COVERAGE=1 is ignored under --depth-from' "$WORK/ej3.out" && ! grep -q 'function_coverage' "$WORK/ej3/discovery-results.json" 2>/dev/null \
   && [ "$(_jq "$WORK/ej3/discovery-results.json" 'd["depth_from"]["carried_cells"]')" = "2" ]; then
  ok "--depth-from ignores the knob with one stderr line, and the recorded coverage cell is NOT carried as breadth"
else
  bad "--depth-from mishandles the knob or carried the recorded coverage cell"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 6 — run-zone-hunt.sh: charge, trim, OFF byte-identity, merged record (through a run-discovery shim)
# ----------------------------------------------------------------------------------------------------------
ZFIX="$HERE/fixtures/zone-map"
if [ ! -f "$ZFIX/zones.fixture.txt" ] || ! command -v git >/dev/null 2>&1; then
  skip "31-34) the zone-map fixtures or git are missing — run-zone-hunt.sh part skipped"
else
  ZREPO="$WORK/z-target"; mkdir -p "$ZREPO"
  cp -R "$ZFIX/contracts" "$ZREPO/contracts"
  rm -rf "$ZREPO/contracts/registry"
  git -C "$ZREPO" init -q
  git -C "$ZREPO" config user.email demo@example.invalid
  git -C "$ZREPO" config user.name demo
  git -C "$ZREPO" add -A
  git -C "$ZREPO" commit -qm baseline
  ZSTUB="$WORK/agentis-zone-stub"
  printf '#!/bin/sh\ncase "${1:-}" in init) mkdir -p .agentis ;; esac\nexit 0\n' > "$ZSTUB"; chmod +x "$ZSTUB"
  # The recorder: --list-cells probes run the REAL script; a hunt records argv + the knob it saw and writes a
  # minimal results file (plus a function_coverage record only when the knob is on, as run-discovery.sh would).
  REC_DISC="$WORK/rec-discovery.sh"
  cat > "$REC_DISC" <<'RECEOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "--list-cells" ] && exec "$DF_REAL_DISCOVERY" "$@"; done
printf '%s | FC=%s\n' "$*" "${FUNCTION_COVERAGE-unset}" >> "$DF_ARGV_LOG"
out="" ; only=""
while [ $# -gt 0 ]; do
  case "$1" in --out) out="$2"; shift 2 ;; --only) only="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$out"
fc=""
if [ "${FUNCTION_COVERAGE:-}" = "1" ]; then fc=',"function_coverage":[{"subsystem":"'"$only"'","coverage_cell":"none"}]'; fi
printf '{"repo":"z-target","cells":[],"totals":{"cells":0,"candidates":0,"steers":0,"failed":0}%s}\n' "$fc" > "$out/discovery-results.json"
printf '# stub\n' > "$out/discovery-report.md"
exit 0
RECEOF
  chmod +x "$REC_DISC"
  # _shim <dir> <run-zone-hunt source> — every dark-factory entry point symlinked, run-discovery.sh = the recorder.
  _shim() {
    mkdir -p "$1"
    for _f in "$HERE"/*; do
      _b="$(basename "$_f")"
      case "$_b" in run-discovery.sh|run-zone-hunt.sh) continue ;; esac
      ln -s "$_f" "$1/$_b"
    done
    cp "$REC_DISC" "$1/run-discovery.sh"
    cp "$2" "$1/run-zone-hunt.sh"; chmod +x "$1/run-zone-hunt.sh"
  }
  _shim "$WORK/zshim" "$ZONEHUNT"
  # _zh <label> <shim> [extra args...] — one offline capstone run; argv log at $WORK/<label>.argv.
  _zh() {
    _z_label="$1"; _z_shim="$2"; shift 2
    : > "$WORK/$_z_label.argv"
    DF_ARGV_LOG="$WORK/$_z_label.argv" DF_REAL_DISCOVERY="$DISCOVERY" \
      "$_z_shim/run-zone-hunt.sh" --repo "$ZREPO" --out "$WORK/$_z_label" --drop-dir "$WORK/$_z_label/drop" --scope-hint contracts \
      --backend mock --agentis "$ZSTUB" --map-fixture "$ZFIX/zones.fixture.txt" --brief-fixture "$ZFIX/briefs.fixture.txt" \
      --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
      --in-scope "the whole in-scope program" "$@" > "$WORK/$_z_label.out" 2> "$WORK/$_z_label.err"
    printf '%s\n' "$?"
  }

  note "31) knob ON: every zone is charged breadth + depth + 1 up front, with the detail string ..."
  ZRC="$(FUNCTION_COVERAGE=1 _zh zon "$WORK/zshim" --zone-depth-cells 1)"
  _eq "the capstone exits 0" "$ZRC" "0"
  if python3 - "$WORK/zon" <<'PY'
import sys, os, json
rec = json.load(open(os.path.join(sys.argv[1], "coverage", "zone-coverage.json"), encoding="utf-8"))
z = dict((x["id"], x) for x in rec["zones"])
for zid, planned in (("contracts_liquidation", 2), ("contracts_vault", 3), ("contracts_governance", 2), ("contracts_oracle", 2)):
    e = z[zid]
    assert e["cells_charged"] == planned + 1 + 1, "%s charged %r, want %d" % (zid, e["cells_charged"], planned + 2)
    assert "function-coverage cell(s) (#2256" in (e.get("detail") or ""), "%s detail %r" % (zid, e.get("detail"))
PY
  then ok "each zone: cells_charged = planned breadth + 1 depth + 1 coverage, and the detail names the coverage cell"
  else bad "the knob-ON charge is wrong"; sed 's/^/      /' "$WORK/zon.err" | tail -5 >&2
  fi
  _eq "every hunt invocation saw FUNCTION_COVERAGE=1 and --depth-max-cells 1" \
    "$(grep -c -- '--depth-max-cells 1 .*| FC=1$' "$WORK/zon.argv")" "4"
  _eq "the merged file carries one function_coverage record per zone, zone-tagged" \
    "$(_jq "$WORK/zon/discovery/discovery-results.merged.json" 'sorted(r["zone"] for r in d["function_coverage"])')" \
    "['contracts_governance', 'contracts_liquidation', 'contracts_oracle', 'contracts_vault']"

  note "32) a cap equal to the planned breadth TRIMS the coverage cell (never a breadth class); coverage outranks depth ..."
  ZRC="$(FUNCTION_COVERAGE=1 _zh zcap "$WORK/zshim" --zone-cell-budget 3 --zone-depth-cells 1)"
  _eq "the capped capstone exits 0" "$ZRC" "0"
  VAULT_LINE="$(grep -- '--only vault deposits ' "$WORK/zcap.argv")"
  case "$VAULT_LINE" in
    *'--classes'*) bad "the trimmed zone dropped a breadth class: $VAULT_LINE" ;;
    *'| FC=0') ok "the 3-cell zone at cap 3: coverage trimmed (the hunt saw FUNCTION_COVERAGE=0), no --classes" ;;
    *) bad "the trimmed zone's hunt did not see FUNCTION_COVERAGE=0: $VAULT_LINE" ;;
  esac
  _eq "the 2-cell zones keep coverage (FC=1) and give up depth (no --depth-max-cells): coverage outranks depth" \
    "$(grep -v -- '--only vault deposits ' "$WORK/zcap.argv" | grep -c -v -- '--depth-max-cells' | tr -d ' ')/$(grep -v -- '--only vault deposits ' "$WORK/zcap.argv" | grep -c '| FC=1$')" "3/3"
  if python3 - "$WORK/zcap" <<'PY'
import sys, os, json
out = sys.argv[1]
rec = json.load(open(os.path.join(out, "coverage", "zone-coverage.json"), encoding="utf-8"))
z = dict((x["id"], x) for x in rec["zones"])
v = z["contracts_vault"]
assert v["cells_charged"] == 3 and "trimmed" in v["detail"] and "#2256" in v["detail"], v
for zid in ("contracts_liquidation", "contracts_governance", "contracts_oracle"):
    assert z[zid]["cells_charged"] == 3, (zid, z[zid]["cells_charged"])
m = json.load(open(os.path.join(out, "discovery", "discovery-results.merged.json"), encoding="utf-8"))
fc = dict((r["zone"], r) for r in m["function_coverage"])
assert fc["contracts_vault"]["coverage_cell"] == "skipped:trimmed", fc["contracts_vault"]
assert fc["contracts_oracle"]["coverage_cell"] == "none", fc["contracts_oracle"]
PY
  then ok "the record charges 3 everywhere, names the trim, and the merged file records skipped:trimmed for that zone"
  else bad "the trim record / merged record is wrong"
  fi
  if grep -q '| FC=1$' "$WORK/zcap.argv" && [ "$(tail -1 "$WORK/zcap.argv" | sed 's/.*| FC=//')" = "1" ]; then
    ok "the knob is restored after the trimmed zone (later zones see FUNCTION_COVERAGE=1)"
  else
    bad "the knob was not restored after the trimmed zone"
  fi

  note "33) knob OFF: argv, env and the coverage record are byte-identical (vs origin/main when available) ..."
  ZRC="$(_zh zoff "$WORK/zshim" --zone-depth-cells 1)"
  _eq "the knob-OFF capstone exits 0" "$ZRC" "0"
  if grep -q 'FC=unset' "$WORK/zoff.argv" && ! grep -q 'FC=[01]' "$WORK/zoff.argv" \
     && ! grep -q 'function_coverage' "$WORK/zoff/discovery/discovery-results.merged.json" \
     && ! grep -q '2256' "$WORK/zoff/coverage/zone-coverage.json"; then
    ok "knob off: no FUNCTION_COVERAGE in the hunt env, no #2256 detail, no function_coverage key in the merged file"
  else
    bad "the knob-OFF capstone is not inert"
  fi
  if git -C "$HERE" cat-file -e origin/main:dark-factory/run-zone-hunt.sh 2>/dev/null \
     && ! git -C "$HERE" show origin/main:dark-factory/run-zone-hunt.sh | grep -q 'ZFCOV_EFF'; then
    git -C "$HERE" show origin/main:dark-factory/run-zone-hunt.sh > "$WORK/rz-origin.sh"
    _shim "$WORK/zshim-origin" "$WORK/rz-origin.sh"
    ZRC="$(_zh zorig "$WORK/zshim-origin" --zone-depth-cells 1)"
    _norm() {
      python3 - "$1" "$2" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
def strip(o):
    if isinstance(o, dict):
        return dict((k, strip(v)) for k, v in o.items() if not k.endswith("_at"))
    if isinstance(o, list):
        return [strip(x) for x in o]
    if isinstance(o, str):
        return o.replace(sys.argv[2], "<OUT>")
    return o
print(json.dumps(strip(d), sort_keys=True))
PY
    }
    if [ "$(sed "s#$WORK/zoff#<OUT>#g" "$WORK/zoff.argv")" = "$(sed "s#$WORK/zorig#<OUT>#g" "$WORK/zorig.argv")" ] \
       && [ "$(_norm "$WORK/zoff/coverage/zone-coverage.json" "$WORK/zoff")" = "$(_norm "$WORK/zorig/coverage/zone-coverage.json" "$WORK/zorig")" ] \
       && [ "$(_norm "$WORK/zoff/discovery/discovery-results.merged.json" "$WORK/zoff")" = "$(_norm "$WORK/zorig/discovery/discovery-results.merged.json" "$WORK/zorig")" ]; then
      ok "knob off: the STAGE 3 argv+env, the coverage record and the merged file match origin/main's run-zone-hunt.sh"
    else
      bad "knob off differs from origin/main's run-zone-hunt.sh (argv / coverage record / merged file)"
      diff "$WORK/zoff.argv" "$WORK/zorig.argv" | head -4 | sed 's/^/      /' >&2
    fi
  else
    skip "origin/main (pre-#2256) run-zone-hunt.sh not available — the OFF inertness checks above stand in"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# PART 7 — MUTATION RESISTANCE (each rule must be load-bearing)
# ----------------------------------------------------------------------------------------------------------
if [ "$FNS_OK" -eq 1 ]; then
  note "34) eight mutations of COPIES — each must flip a named fixture ..."
  # _probe — the fixture verdicts under whatever functions are currently defined, as one line.
  _probe() {
    _p1="$(_fcov_table "$F3" "$WORK/ungr.log" | awk -F'\t' '$2 == "setLimit" { print $5 }')"
    _p2="$(_fcov_table "$FRD" "$WORK/router.log" | awk -F'\t' '$1 == "contracts/Vault.sol" { print $5 }')"
    _p3="$(_fcov_table "$F3" "$WORK/fire.log" | awk -F'\t' '$2 == "sweep" { print $5 }')"
    _p4="$(_fcov_table "$F4" "$WORK/ctl.log" | awk -F'\t' '$2 == "withdraw" { print $5 }')"
    if _fcov_armed "$WORK/unarmed.log"; then _p5=armed; else _p5=unarmed; fi
    _p6="$(_fcov_over_cap "$WORK/cap.table" | _count_stdin)"
    # shellcheck disable=SC2046  # the lister's paths (mktemp, no spaces) must split into one argument per log
    _p7="$(_fcov_table "$F3" $(_fcov_breadth_logs "$WORK/attrun" v C1) | awk -F'\t' '$2 == "setLimit" { print $5 }')"
    printf 'grounding=%s location=%s dismiss=%s param=%s arming=%s cap=%s attempts=%s\n' "$_p1" "$_p2" "$_p3" "$_p4" "$_p5" "$_p6" "$_p7"
  }
  BASE="$(_probe)"
  if [ "$BASE" = "grounding=none location=none dismiss=dismiss param=param arming=unarmed cap=3 attempts=none" ]; then
    ok "control (unmutated): $BASE"
  else
    bad "the unmutated control is wrong: $BASE"
  fi
  # _mutate <label> <field-that-must-flip> <sed program>
  _mutate() {
    _m_file="$WORK/mut-$1.sh"
    sed "$3" "$FNS" > "$_m_file"
    if cmp -s "$FNS" "$_m_file"; then bad "mutation '$1' did not apply (the targeted line moved?)"; return; fi
    # shellcheck disable=SC1090  # a mutated copy of the sliced functions, generated at runtime by design
    _m_got="$( . "$_m_file"; _probe )"
    _m_want="$(printf '%s\n' "$BASE" | tr ' ' '\n' | grep "^$2=")"
    _m_now="$(printf '%s\n' "$_m_got" | tr ' ' '\n' | grep "^$2=")"
    if [ "$_m_want" != "$_m_now" ]; then ok "mutation '$1' flips $2 ($_m_want -> $_m_now)"; else bad "mutation '$1' flips NOTHING on $2"; fi
  }
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate drop-read-grounding grounding 's/if _fcov_read_grounded "\$ft_ev" "\${ft_ids:--}"; then ft_by="read"; break; fi/ft_by="read"; break/'
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate name-only-matching location 's/\$3 == fn \&\& (\$2 == "-" || \$2 == b)/$3 == fn/'
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate drop-dismiss-source dismiss '/_dismiss_lines "\$ftr_log" | awk/d'
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate drop-param-source param '/_param_lines "\$ftr_log" | awk/d'
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate drop-sentinel-arming arming 's/grep -qE .\^\[\[:space:\]\]\*FUNCTION-COVERAGE\\|. "\$fa_log" 2>\/dev\/null && return 0/return 0/'
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate off-by-one-cap cap 's/if (n > c) print/if (n >= c) print/'
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate count-superseded-attempts attempts 's#printf .%s\\n. "\$fbl_run/hunt_\${fbl_slug}_\${fbl_cls}.log"$#for x in "$fbl_run/hunt_${fbl_slug}_${fbl_cls}.log"*; do printf "%s\\n" "$x"; done#'
  # The eighth mutation targets the PYTHON helper (a copy): drop the view/pure exclusion.
  sed 's/"state_changing": vis in ("external", "public") and mut not in ("view", "pure"),/"state_changing": vis in ("external", "public"),/' \
    "$INHERIT" > "$WORK/inheritance.mut.py"
  if cmp -s "$INHERIT" "$WORK/inheritance.mut.py"; then
    bad "mutation 'drop-view-pure-exclusion' did not apply (the targeted line moved?)"
  else
    M_ORIG="$(_zf "$FXF" | awk -F'\t' '$1 == "FN" && ($3 == "peek" || $3 == "calc")' | _count_stdin)"
    M_NOW="$(python3 "$WORK/inheritance.mut.py" zone-functions --repo "$FXR" --files "$FXF" | awk -F'\t' '$1 == "FN" && ($3 == "peek" || $3 == "calc")' | _count_stdin)"
    if [ "$M_ORIG" != "$M_NOW" ]; then ok "mutation 'drop-view-pure-exclusion' flips the gated set (view/pure rows $M_ORIG -> $M_NOW)"; else bad "mutation 'drop-view-pure-exclusion' flips NOTHING"; fi
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# PART 8 — NEEDS agentis: the AGENT half (clean [SKIP] otherwise)
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  note "35-36) byte-identity probe + live-under-mock sentinels ..."
  skip "no agentis binary on PATH — the extracted-helper probe and the real mock hunter cells cannot run"
else
  note "35) byte-identity probe: the #2256 helpers print 0 bytes under EVERY other-knob combination when unset ..."
  FRAG="$WORK/fcov.frag"; : > "$FRAG"
  FRAG_MISS=""
  for fn in function_coverage_marker function_coverage_enabled function_coverage_block function_coverage_directive coverage_pass_block class_field; do
    _agfn "$HUNTER" "$fn" >> "$FRAG"; printf '\n' >> "$FRAG"
    grep -q "^fn $fn(" "$FRAG" || FRAG_MISS="$FRAG_MISS $fn"
  done
  if [ -n "$FRAG_MISS" ]; then
    bad "could not extract the helpers from hunter.ag by line range:$FRAG_MISS"
  else
    SB="$WORK/probe"; mkdir -p "$SB"
    ( cd "$SB" && agentis init >/dev/null 2>&1 ) || true
    printf 'exec.env_passthrough = FUNCTION_COVERAGE,COVERAGE_REASK_FNS,SEVERITY_RUBRIC,GROUND_EVIDENCE,OPERATIONALIZE_LENS,PARAM_AUDIT\n' > "$SB/.agentis/config"
    {
      printf 'cb 300000;\n\n'
      cat "$FRAG"
      printf 'print("DIRLEN=" + to_string(len(function_coverage_directive())));\n'
      printf 'print("CPASSLEN=" + to_string(len(coverage_pass_block())));\n'
      printf 'print("BLOCKLEN=" + to_string(len(function_coverage_block())));\n'
      printf 'print("FIELD1=" + class_field("C6"));\n'
      printf 'print("FIELDN=" + class_field("C1,C6"));\n'
    } > "$SB/probe.ag"
    _pl() {
      _pl_k="$1"; shift
      _pl_v="$( cd "$SB" && env -u FUNCTION_COVERAGE -u COVERAGE_REASK_FNS -u SEVERITY_RUBRIC -u GROUND_EVIDENCE -u OPERATIONALIZE_LENS -u PARAM_AUDIT "$@" agentis go probe.ag 2>&1 | grep "^$_pl_k=" | tail -1 )"  # no-pii: length-only probe, no prompt()
      printf '%s\n' "${_pl_v#"$_pl_k"=}"
    }
    BLOCK_LEN="$(_pl BLOCKLEN)"
    case "$BLOCK_LEN" in
      ''|*[!0-9]*|0) bad "the probe did not complete or the block is empty (BLOCKLEN='$BLOCK_LEN')" ;;
      *) ok "the READ contract block is $BLOCK_LEN bytes (the MEASURED prompt cost of the knob, printed rather than assumed)" ;;
    esac
    ZERO_BAD=""
    for sr in "" SEVERITY_RUBRIC=1; do
      for pa in "" PARAM_AUDIT=1; do
        for ol in "" OPERATIONALIZE_LENS=1; do
          for fc in "" FUNCTION_COVERAGE=0 FUNCTION_COVERAGE=true; do
            # shellcheck disable=SC2086  # the empty members must vanish, the set ones must split into env words
            _d="$(_pl DIRLEN $sr $pa $ol $fc)$(_pl CPASSLEN $sr $pa $ol $fc)"
            [ "$_d" = "00" ] || ZERO_BAD="$ZERO_BAD [$sr $pa $ol $fc -> $_d]"
          done
        done
      done
    done
    if [ -z "$ZERO_BAD" ]; then
      ok "knob unset/0/true (no coverage list): both #2256 blocks are 0 bytes under all 24 combinations of the other knobs"
    else
      bad "a knob-OFF combination rendered #2256 bytes:$ZERO_BAD"
    fi
    _eq "FUNCTION_COVERAGE=1 renders exactly the block + one newline" "$(_pl DIRLEN FUNCTION_COVERAGE=1)" "$((BLOCK_LEN + 1))"
    _eq "class_field is the id itself on one class, and asks for ONE of a list" "$(_pl FIELD1)|$(_pl FIELDN)" "C6|<exactly ONE of: C1,C6>"
    # class_sections() needs class_section()'s taxonomy reader (an exec sh), so it is probed with --enable-exec.
    SX="$WORK/probe-sections"; mkdir -p "$SX"
    ( cd "$SX" && agentis init >/dev/null 2>&1 ) || true
    {
      printf 'cb 300000;\n\n'
      _agfn "$HUNTER" class_section; printf '\n'
      _agfn "$HUNTER" class_sections; printf '\n'
      printf 'let t = "%s";\n' "$HERE/auditor/bug-taxonomy.md"
      printf 'print("ONE=" + to_string(len(class_section(t, "C1"))));\n'
      printf 'print("SIX=" + to_string(len(class_section(t, "C6"))));\n'
      printf 'print("VIA=" + to_string(len(class_sections(t, "C1"))));\n'
      printf 'print("SAME=" + to_string(class_sections(t, "C1") == class_section(t, "C1")));\n'
      printf 'print("LIST=" + to_string(len(class_sections(t, "C1, C6"))));\n'
    } > "$SX/sections.ag"
    SX_OUT="$( cd "$SX" && agentis go sections.ag --enable-exec --grant-pii 2>&1 )"
    SX_ONE="$(printf '%s\n' "$SX_OUT" | sed -n 's/^ONE=//p' | tail -1)"
    SX_SIX="$(printf '%s\n' "$SX_OUT" | sed -n 's/^SIX=//p' | tail -1)"
    SX_LIST="$(printf '%s\n' "$SX_OUT" | sed -n 's/^LIST=//p' | tail -1)"
    case "$SX_ONE:$SX_SIX" in
      *[!0-9:]*|:*|*:|0:*|*:0) bad "the class_section probe did not complete (ONE='$SX_ONE' SIX='$SX_SIX')" ;;
      *) _eq "class_sections(C1) == class_section(C1) byte for byte, and a list concatenates its sections" \
           "$(printf '%s\n' "$SX_OUT" | sed -n 's/^SAME=//p' | tail -1):$SX_LIST" "true:$((SX_ONE + 1 + SX_SIX))" ;;
    esac
  fi

  note "36) live-under-mock: FUNCTION-COVERAGE| only with the knob, COVERAGE-CELL| only with a non-empty list ..."
  LM="$WORK/live"; mkdir -p "$LM"
  ( cd "$LM" && agentis init >/dev/null 2>&1 ) || true
  cp "$HUNTER" "$LM/hunter.ag"; cp "$HERE/auditor/slice-fns.sh" "$LM/slice-fns.sh"
  {
    printf 'llm.backend = mock\n'
    printf 'exec.env_passthrough = TARGET_DIR,IN_SCOPE,SCOPE_BRIEF,TAXONOMY,HUNT_CLASS,SUBSYSTEM,SLICER,FUNCTION_COVERAGE,COVERAGE_REASK_FNS\n'
    printf 'learning.enabled = true\nexperience.enabled = true\nknowledge.enabled = true\n'
  } > "$LM/.agentis/config"
  _live() {
    ( cd "$LM" && env TARGET_DIR="$HREPO" IN_SCOPE="contracts/Vault.sol" SCOPE_BRIEF="$WORK/h-brief.md" \
        TAXONOMY="$HERE/auditor/bug-taxonomy.md" SUBSYSTEM=vault SLICER="$LM/slice-fns.sh" "$@" \
        agentis go hunter.ag --enable-exec --enable-messaging --grant-pii 2>&1 )
  }
  LV_ON="$(_live HUNT_CLASS=C1 FUNCTION_COVERAGE=1)"
  LV_OFF="$(_live HUNT_CLASS=C1)"
  LV_CELL="$(_live HUNT_CLASS=C1,C6 FUNCTION_COVERAGE=1 COVERAGE_REASK_FNS="contracts/Vault.sol:withdraw, contracts/Vault.sol:setLimit")"
  if printf '%s\n' "$LV_ON" | grep -q '^FUNCTION-COVERAGE|vault|C1|on$' && ! printf '%s\n' "$LV_OFF" | grep -q 'FUNCTION-COVERAGE|'; then
    ok "FUNCTION_COVERAGE=1: the sentinel fired in a real hunter cell; default: absent"
  else
    bad "the FUNCTION-COVERAGE| sentinel does not follow the knob in a real hunter cell"
    printf '%s\n' "$LV_ON" | tail -3 | sed 's/^/      /' >&2
  fi
  if printf '%s\n' "$LV_CELL" | grep -q '^COVERAGE-CELL|vault|C1,C6|2$' && ! printf '%s\n' "$LV_ON" | grep -q 'COVERAGE-CELL|'; then
    ok "COVERAGE-CELL| (with the listed count) fires only with a non-empty COVERAGE_REASK_FNS, and the class-list cell runs"
  else
    bad "the COVERAGE-CELL| sentinel is wrong in a real hunter cell"
    printf '%s\n' "$LV_CELL" | tail -3 | sed 's/^/      /' >&2
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "ALL ASSERTIONS HELD — the #2256 breadth function-coverage gate is wired, output-gated, bounded and default OFF."
  note "NOTE: nothing above is a recall claim; that is the operator's pre-registered measurement on a fresh set."
  exit 0
fi
note "$FAILS assertion(s) FAILED"
exit 1
