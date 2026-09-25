#!/usr/bin/env bash
# demo-breadth-promises.sh — the gate for #2264 BREADTH PROMISES (knob BREADTH_PROMISES=1, default OFF).
#
# What the change is. #2245 iteration 7 extracts the target's cited user-facing PROMISES and turns each into a fuzzer
# invariant — but only the deep hunt (STAGE 4.5) consumed them, while the breadth pass is where the verified rare-row
# hits of the final exam came from. #2264 hands the same promises to the BREADTH cells:
#   * a ZONE PRE-PASS in run-discovery.sh — once per manifest line, never per cell — renders the line's listing
#     (lib/inheritance.py promise-sources --files), runs the ONE-prompt auditor/agents/promise-lister.ag (its
#     instruction a byte-copy of invariant-prover.ag's), and keeps the cited promises with evm-harness/promise-gate.py
#     gate --cap 8 --names-in <the line's own files> (a subject the line never names is `subject-off-payload`);
#   * hunter.ag gets the ACCEPTED block and a `PTRACE|#k|held|<path:line>|...` / `PTRACE|#k|broken|<file:fn>|...`
#     contract (honesty-gated `BREADTH-PROMISES|` sentinel);
#   * run-discovery.sh pairs answers by id, RE-OPENS every held citation (_promise_held_ok), re-asks once naming the
#     open items, and — inside a rubric-ON cell — promotes an open `broken` to ONE Medium candidate per location.
# `BREADTH_PROMISES=1` opts in; unset (the DEFAULT) leaves the prompt, the report, the results JSON and the banner
# byte-identical. Nothing asserted here is a recall claim — recall is the operator's measurement on a fresh set.
#
# Nine parts. Parts 1-8 are the CI floor (grep/awk/python3 + the SHIPPED shell functions sliced out of
# run-discovery.sh + offline --agentis / run-discovery stubs): no agentis, no forge, no network, no LLM.
#   1) SOURCE GUARDS — hunter.ag helpers, marker/sentinel coupling, ""-when-off, splice order, rubric/env gating,
#      token invariants, the lister's byte-identical instruction + lint waivers, the KIND-VOCABULARY pin (+ control).
#   2) THE LISTING — promise-sources --files: order, whole-file slices, ancestors, interfaces, the doc cap, the 160 KB
#      cut, dropped tokens, multi-root, --target byte-identical vs origin/main, --target --files exits 2.
#   3) promise-gate.py --names-in — subject-off-payload never takes a cap slot; flagless output byte-identical.
#   4) THE SLICED GATE over synthetic logs — pairing, every held-* id, discharge, rubric arming, re-ask text, the
#      pinned requirement table + path regex, no TRACE/PARAM-TRACE collision, the shipped joiner boundaries.
#   5) PROMOTION — one Medium lead per resolved location, unresolved / already-promoted drops, model candidates.
#   6) END-TO-END through run-discovery.sh with an offline stub playing the lister AND the hunter (a-h).
#   7) run-zone-hunt.sh through a run-discovery shim — OFF byte-identity, the merged record, the unchanged charge.
#   8) MUTATIONS of COPIES — each must flip a named fixture.
#   9) NEEDS agentis ([SKIP] otherwise) — 0-byte helper probe, rendered kind-free text, live mock hunter + lister.
#
# Usage:  dark-factory/demo-breadth-promises.sh
# Exit: 0 = all assertions held; non-zero = a regression.
# Dash-safe fixtures: no $'...', literal glyphs only, printf with no \xHH escapes.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HUNTER="$HERE/auditor/agents/hunter.ag"
LISTER="$HERE/auditor/agents/promise-lister.ag"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
DISCOVERY="$HERE/run-discovery.sh"
ZONEHUNT="$HERE/run-zone-hunt.sh"
INHERIT="$HERE/lib/inheritance.py"
PGATE="$HERE/evm-harness/promise-gate.py"
RAV="$HERE/lib/run-agent-validated.sh"
DHP_DEMO="$HERE/demo-deep-hunt-promises.sh"

FAILS=0
note() { echo "demo-breadth-promises.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for f in "$HUNTER" "$LISTER" "$PROVER" "$DISCOVERY" "$ZONEHUNT" "$INHERIT" "$PGATE" "$RAV"; do
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
unset BREADTH_PROMISES BREADTH_PROMISE_FILE PTRACE_REASK_IDS PROMISE_SOURCES DF_PROMISE_MAX_REASKS \
  FUNCTION_COVERAGE COVERAGE_REASK_FNS SEVERITY_RUBRIC GROUND_EVIDENCE PARAM_AUDIT OPERATIONALIZE_LENS DF_TIER2 2>/dev/null || true

# The kind vocabulary that must never reach a prompt (#2245 iteration-7 STOP-1 decision 4), matched as whole words,
# any case. A COPY of demo-deep-hunt-promises.sh's definition — pinned equal below, so the two cannot drift.
KIND_WORDS_RE='(^|[^A-Za-z0-9_-])(time-?locks?|ordering|rounding|per-user-conservation|bound|access)([^A-Za-z0-9_-]|$)'

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
# _jq <results.json> <python expression over d> — print one value from a results file.
_jq() {
  python3 -c 'import sys, json; d = json.load(open(sys.argv[1], encoding="utf-8")); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null
}

# ----------------------------------------------------------------------------------------------------------
# The fixture target every part shares. Line numbers are load-bearing: the citations below point at them.
# ----------------------------------------------------------------------------------------------------------
FXR="$WORK/fx-repo"
mkdir -p "$FXR/contracts/interfaces" "$FXR/script" "$FXR/test" "$FXR/mocks" "$FXR/lib/oz" "$FXR/docs"
{
  printf '%s\n' '// SPDX-License-Identifier: MIT'                                  # 1
  printf '%s\n' 'pragma solidity ^0.8.20;'                                         # 2
  printf '%s\n' 'import "./Base.sol";'                                             # 3
  printf '%s\n' 'contract Vault is Base, IVault {'                                 # 4
  printf '%s\n' '    mapping(address => uint256) public shares;'                   # 5
  printf '%s\n' '    mapping(address => uint256) public unlockAt;'                 # 6
  printf '%s\n' '    /// @notice shares cannot leave an account before its unlockAt time'  # 7
  printf '%s\n' '    function exit(uint256 amount) external {'                     # 8
  printf '%s\n' '        require(block.timestamp >= unlockAt[msg.sender], "early");'  # 9
  printf '%s\n' '        shares[msg.sender] -= amount;'                            # 10
  printf '%s\n' '    }'                                                            # 11
  printf '%s\n' '    function enter(uint256 amount) external whenOpen {'           # 12
  printf '%s\n' '        shares[msg.sender] += amount;'                            # 13
  printf '%s\n' '        unlockAt[msg.sender] = block.timestamp + 1 days;'         # 14
  printf '%s\n' '    }'                                                            # 15
  printf '%s\n' '    function move(address to, uint256 amount) external {'         # 16
  printf '%s\n' '        shares[msg.sender] -= amount;'                            # 17
  printf '%s\n' '        shares[to] += amount;'                                    # 18
  printf '%s\n' '    }'                                                            # 19
  printf '%s\n' '    function note(uint256 x) external {'                          # 20
  printf '%s\n' '        emit Noted(x);'                                           # 21
  printf '%s\n' '    }'                                                            # 22
  printf '%s\n' '}'                                                                # 23
} > "$FXR/contracts/Vault.sol"
{
  printf '%s\n' 'pragma solidity ^0.8.20;'
  printf '%s\n' 'import "./interfaces/IBase.sol";'
  printf '%s\n' 'abstract contract Base is IBase {'
  printf '%s\n' '    bool public open;'
  printf '%s\n' '    modifier whenOpen() { require(open, "closed"); _; }'
  printf '%s\n' '}'
} > "$FXR/contracts/Base.sol"
printf '%s\n' 'interface IVault { function exit(uint256 amount) external; }' > "$FXR/contracts/interfaces/IVault.sol"
printf '%s\n' 'interface IBase { function open() external view returns (bool); }' > "$FXR/contracts/interfaces/IBase.sol"
{
  printf '%s\n' 'pragma solidity ^0.8.20;'
  printf '%s\n' 'contract Router {'
  printf '%s\n' '    uint256 public routed;'
  printf '%s\n' '    function route(uint256 amount) external { routed += amount; }'
  printf '%s\n' '}'
} > "$FXR/contracts/Router.sol"
{
  printf '%s\n' 'pragma solidity ^0.8.20;'
  printf '%s\n' 'contract Other {'
  printf '%s\n' '    uint256 public otherThing;'
  printf '%s\n' '    function poke(uint256 v) external { require(v > 0, "zero"); otherThing = v; }'
  printf '%s\n' '}'
} > "$FXR/contracts/Other.sol"
printf '%s\n' 'contract Deploy { function run() external { } }' 'contract D2 { uint256 unlockAt; }' 'contract D3 { function x() external { require(unlockAt > 0); } }' > "$FXR/script/Deploy.s.sol"
printf '%s\n' 'contract VaultTest { function t() external { } }' 'contract T2 { }' 'contract T3 { function y() external { require(unlockAt > 0); } }' > "$FXR/test/Vault.t.sol"
printf '%s\n' 'contract M { function z() external { require(unlockAt > 0); } }' > "$FXR/mocks/M.sol"
printf '%s\n' 'library Guard {' '    function check(uint256 unlockAt) internal view { require(block.timestamp >= unlockAt, "early"); }' '}' > "$FXR/lib/oz/Guard.sol"
{
  printf '%s\n' '# Fixture'
  printf '%s\n' 'The Vault keeps shares per account. Vault exits wait for unlockAt. The Vault never pools shares.'
} > "$FXR/README.md"
printf '%s\n' '# Extra' 'A Vault note.' > "$FXR/docs/extra.md"
printf '%s\n' '# Routing' 'The Router forwards calls.' > "$FXR/docs/router.md"
FXF="contracts/Vault.sol"

# ----------------------------------------------------------------------------------------------------------
# PART 1 — SOURCE GUARDS
# ----------------------------------------------------------------------------------------------------------
note "1) hunter.ag declares the six #2264 helpers ..."
BP_FNS="breadth_promises_marker read_promise_file breadth_promises_block promise_lead_rule ptrace_reask_block breadth_promises_directive"
MISS=""
for fn in $BP_FNS; do
  grep -q "^fn $fn(" "$HUNTER" || MISS="$MISS $fn"
done
if [ -z "$MISS" ]; then ok "marker / reader / block / lead rule / re-ask / directive are all declared"; else bad "missing #2264 helper(s):$MISS"; fi

note "2) the marker is the block's literal FIRST LINE, and the sentinel is honesty-gated ..."
if _agfn "$HUNTER" breadth_promises_block | sed -n 2p | grep -q 'return breadth_promises_marker() + "\\n"'; then
  ok "breadth_promises_block() opens with breadth_promises_marker()"
else
  bad "breadth_promises_block() no longer opens with its marker"
fi
if grep -q 'if index_of(instruction, breadth_promises_marker()) >= 0 {' "$HUNTER" \
   && grep -q 'print("BREADTH-PROMISES|" + subsystem + "|" + cls + "|on");' "$HUNTER" \
   && ! grep -A2 'print("BREADTH-PROMISES|" + subsystem' "$HUNTER" | grep -q 'getenv('; then
  ok "BREADTH-PROMISES| is printed only when the marker is demonstrably IN the prompt about to be sent (never on the env)"
else
  bad "the BREADTH-PROMISES| sentinel is missing or not gated on index_of(instruction, marker)"
fi
L_FCS="$(grep -n 'print("FUNCTION-COVERAGE|" + subsystem' "$HUNTER" | head -1 | cut -d: -f1)"
L_BPS="$(grep -n 'print("BREADTH-PROMISES|" + subsystem' "$HUNTER" | head -1 | cut -d: -f1)"
L_PR="$(grep -n '^let verdict = prompt(instruction, code) -> string;$' "$HUNTER" | head -1 | cut -d: -f1)"
if [ -n "$L_FCS" ] && [ -n "$L_BPS" ] && [ -n "$L_PR" ] && [ "$L_FCS" -lt "$L_BPS" ] && [ "$L_BPS" -lt "$L_PR" ]; then
  ok "the sentinel is printed right after the FUNCTION-COVERAGE one and before prompt()"
else
  bad "the sentinel moved (fcov=$L_FCS bprom=$L_BPS prompt=$L_PR)"
fi

note "3) the directive is \"\" with the env empty OR the file empty; lead rule rubric-gated; re-ask env-gated ..."
DIR_SRC="$(_agfn "$HUNTER" breadth_promises_directive)"
if printf '%s\n' "$DIR_SRC" | grep -q 'let path = getenv("BREADTH_PROMISE_FILE");' \
   && printf '%s\n' "$DIR_SRC" | grep -q 'if path == "" { return ""; }' \
   && printf '%s\n' "$DIR_SRC" | grep -q 'if len(trim(accepted)) == 0 { return ""; }' \
   && printf '%s\n' "$DIR_SRC" | grep -q 'return breadth_promises_block() + promise_lead_rule() + ptrace_reask_block() + accepted + "\\n\\n";'; then
  ok "directive = block + lead rule + re-ask + the ACCEPTED block verbatim, and \"\" without a non-empty file"
else
  bad "breadth_promises_directive() lost a gate or its composition"
fi
if _agfn "$HUNTER" promise_lead_rule | grep -q 'if !severity_rubric_enabled() { return ""; }'; then
  ok "promise_lead_rule() renders only inside a rubric-ON cell"
else
  bad "promise_lead_rule() is not rubric-gated"
fi
if _agfn "$HUNTER" ptrace_reask_block | grep -q 'let items = getenv("PTRACE_REASK_IDS");' \
   && _agfn "$HUNTER" ptrace_reask_block | grep -q 'if items == "" { return ""; }'; then
  ok "ptrace_reask_block() is \"\" unless PTRACE_REASK_IDS is set (every first attempt is unchanged)"
else
  bad "ptrace_reask_block() is not env-gated"
fi
if _agfn "$HUNTER" read_promise_file | grep -q 'exec sh "cat " + shell_escape(path)' \
   && _agfn "$HUNTER" read_promise_file | grep -q 'colony-lint: safe-exec-concat' \
   && ! _agfn "$HUNTER" read_promise_file | grep -q 'sed -n\|SLICER'; then
  ok "read_promise_file() is a plain shell_escape()d cat (no 2000-line cut, no slice branch)"
else
  bad "read_promise_file() is not the plain cat the plan specifies"
fi

note "4) the SPLICE ORDER: + paudit -> + fcov -> + bprom -> + extres ..."
L_PAU="$(grep -n '^  + paudit$' "$HUNTER" | head -1 | cut -d: -f1)"
L_FCV="$(grep -n '^  + fcov$' "$HUNTER" | head -1 | cut -d: -f1)"
L_BPR="$(grep -n '^  + bprom$' "$HUNTER" | head -1 | cut -d: -f1)"
L_EXT="$(grep -n '^  + extres$' "$HUNTER" | head -1 | cut -d: -f1)"
if [ -n "$L_PAU" ] && [ -n "$L_FCV" ] && [ -n "$L_BPR" ] && [ -n "$L_EXT" ] \
   && [ "$L_PAU" -lt "$L_FCV" ] && [ "$L_FCV" -lt "$L_BPR" ] && [ "$L_BPR" -lt "$L_EXT" ] \
   && grep -q '^let bprom = breadth_promises_directive();$' "$HUNTER"; then
  ok "the PTRACE contract sits between the READ contract and the resolver verb, assembled once at top level"
else
  bad "the #2264 splice point moved (paudit=$L_PAU fcov=$L_FCV bprom=$L_BPR extres=$L_EXT)"
fi

note "5) TOKEN INVARIANTS: no #2264 token or block carries CANDIDATE|, SAFE or VERDICT| ..."
TOK_BAD=""
for tok in 'PTRACE|' 'BREADTH-PROMISES|' 'PROMISE-LISTER|' "$(_agfn "$HUNTER" breadth_promises_marker | sed -n 's/^[[:space:]]*return "\(.*\)";$/\1/p')"; do
  [ -n "$tok" ] || TOK_BAD="$TOK_BAD empty-token"
  case "$tok" in *'CANDIDATE|'*|*'SAFE'*|*'VERDICT|'*) TOK_BAD="$TOK_BAD $tok" ;; esac
done
BLOCK_FLAT="$(_flat "$(_agfn "$HUNTER" breadth_promises_block)")"
LEAD_FLAT="$(_flat "$(_agfn "$HUNTER" promise_lead_rule)")"
REASK_FLAT="$(_flat "$(_agfn "$HUNTER" ptrace_reask_block)")"
case "$BLOCK_FLAT$LEAD_FLAT$REASK_FLAT" in *'CANDIDATE|'*|*'VERDICT|'*) TOK_BAD="$TOK_BAD block:CANDIDATE|/VERDICT|" ;; esac
case "$BLOCK_FLAT" in *'PTRACE|#<k>|held|<path>:<line>[-<line>]|<the check at that line that keeps the promise>'*) ;; *) TOK_BAD="$TOK_BAD held-grammar" ;; esac
case "$BLOCK_FLAT" in *'PTRACE|#<k>|broken|<file:function>|<the call sequence that breaks it>'*) ;; *) TOK_BAD="$TOK_BAD broken-grammar" ;; esac
case "$BLOCK_FLAT" in *'never itself a finding'*) ;; *) TOK_BAD="$TOK_BAD never-a-finding" ;; esac
case "$BLOCK_FLAT" in *'answers NOTHING'*) ;; *) TOK_BAD="$TOK_BAD wrong-number-rule" ;; esac
if [ -z "$TOK_BAD" ]; then
  ok "no #2264 token or contract text contains CANDIDATE|/SAFE/VERDICT|; both grammars and the never-a-finding / wrong-number rules are in the prompt"
else
  bad "a #2264 token or the contract text is wrong:$TOK_BAD"
fi

note "6) promise-lister.ag: the extraction instruction is a BYTE-IDENTICAL copy of invariant-prover.ag's ..."
_agfn "$PROVER" promise_extract_instruction > "$WORK/extract.prover"
_agfn "$LISTER" promise_extract_instruction > "$WORK/extract.lister"
if [ -s "$WORK/extract.prover" ] && cmp -s "$WORK/extract.prover" "$WORK/extract.lister"; then
  ok "promise_extract_instruction() bodies are identical ($(wc -l < "$WORK/extract.lister" | tr -d ' ') lines) — edit both or neither"
else
  bad "the lister's extraction instruction DRIFTED from invariant-prover.ag's"
  diff "$WORK/extract.prover" "$WORK/extract.lister" | head -6 | sed 's/^/      /' >&2
fi
LB=""
[ "$(head -1 "$LISTER")" = "cb 300000;" ] || LB="$LB cb"
grep -q '// colony-lint: prompt-gate-ok' "$LISTER" || LB="$LB prompt-gate-ok"
grep -q '// colony-lint: safe-exec-concat' "$LISTER" || LB="$LB safe-exec-concat"
grep -q 'exec sh "cat " + shell_escape(path) + " 2>/dev/null || true";' "$LISTER" || LB="$LB reader"
grep -q '^let sources = read_listing(getenv("PROMISE_SOURCES"));$' "$LISTER" || LB="$LB PROMISE_SOURCES"
grep -q 'print("PROMISE-LISTER|empty");' "$LISTER" || LB="$LB empty"
grep -q 'print("PROMISE-LISTER|on");' "$LISTER" || LB="$LB on"
[ "$(tail -1 "$LISTER")" = 'memo_write("promise-lister:last_check", "done");' ] || LB="$LB memo_write"
[ "$(grep -v '^[[:space:]]*//' "$LISTER" | grep -c 'prompt(')" = "1" ] || LB="$LB one-prompt"
# shellcheck disable=SC2016  # LITERAL source text
grep -q '"$AGENTIS" go promise-lister.ag --enable-exec --grant-pii ) < /dev/null' "$DISCOVERY" || LB="$LB invocation(--grant-pii,/dev/null)"
if [ -z "$LB" ]; then
  ok "cb 300000, both lint waivers, the shell_escape()d reader, PROMISE_SOURCES, empty/on diagnostics, one prompt, --grant-pii + </dev/null"
else
  bad "promise-lister.ag / its invocation is incomplete:$LB"
fi
if grep -q 'promise-lister)' "$RAV" && _shfn "$RAV" df_sentinel_present | grep -q "grep -Eq '^\[\[:space:\]\]\*PROMISE\\\\|' \"\$dsp_log\""; then
  ok "lib/run-agent-validated.sh has the promise-lister stage (a PROMISE| line validates the reply)"
else
  bad "the promise-lister validity predicate is missing or reshaped"
fi

note "7) OVERFITTING + DOMAIN-NOUN GUARD over the prompt-visible #2264 text ..."
PROMPT_TXT="$WORK/prompt-text.txt"
{
  _agfn "$HUNTER" breadth_promises_marker
  _agfn "$HUNTER" breadth_promises_block
  _agfn "$HUNTER" promise_lead_rule
  _agfn "$HUNTER" ptrace_reask_block
} > "$PROMPT_TXT"
DENY='Curve|Convex|Pendle|Balancer|Uniswap|Aave|Compound|useEth|use_eth|WETH|wrapNative|slot0|ERC-?[0-9]|\.sol'
GT_ID='(^|[^[:alnum:]_])[HM]-[0-9]{1,2}([^[:alnum:]_]|$)'
NOUNS='(^|[^[:alnum:]_])(fee|fees|deadline|deadlines|chain|chains|bridge|bridges|deposit|deposits|buffer|buffers|duration|durations|lockup|lockups|rounding|oracle|oracles|pool|pools|token|tokens|slippage|price|prices|vault|vaults|withdraw|liquidation|collateral)([^[:alnum:]_]|$)'
if [ ! -s "$PROMPT_TXT" ]; then
  bad "could not slice the #2264 prompt text out of hunter.ag"
elif grep -Eq "$DENY" "$PROMPT_TXT"; then
  bad "the #2264 text names a protocol/product/file specific"
elif grep -qi 'corpus-bench' "$PROMPT_TXT"; then
  bad "the #2264 text names the corpus"
elif grep -EqI "$GT_ID" "$PROMPT_TXT"; then
  bad "the #2264 text carries a ground-truth finding id"
elif grep -Eqi "$NOUNS" "$PROMPT_TXT"; then
  bad "the #2264 text carries a domain noun"
  grep -nEi "$NOUNS" "$PROMPT_TXT" | head -3 | sed 's/^/      /' >&2
else
  ok "the #2264 text names no protocol, product, file, corpus, ground-truth id or domain noun (pure-meta)"
fi
printf 'the Balancer vault takes a fee on Foo.sol and GT %s-9 confirms it\n' 'H' > "$WORK/planted.txt"
if grep -Eq "$DENY" "$WORK/planted.txt" && grep -EqI "$GT_ID" "$WORK/planted.txt" && grep -Eqi "$NOUNS" "$WORK/planted.txt"; then
  ok "the overfitting, ground-truth-id and domain-noun detectors all fire on a planted hint (negative control)"
else
  bad "a denylist detector does not fire on a planted hint — the guard is dead"
fi

note "8) substrate purity: the #2264 .ag block adds one plain cat and no embedded interpreter ..."
PURE="$WORK/pure.txt"
awk '/--- #2264 BREADTH PROMISES/{f=1} f&&/^let dir = getenv\("TARGET_DIR"\);$/{exit} f{print}' "$HUNTER" \
  | grep -v '^[[:space:]]*//' > "$PURE"
if [ ! -s "$PURE" ] || ! grep -q 'fn breadth_promises_block' "$PURE"; then
  bad "could not slice the #2264 block out of hunter.ag (header renamed?)"
elif [ "$(grep -c 'exec sh' "$PURE")" != "1" ] || grep -Eq 'python3 -c|awk |sed -|[^a-z]date |reduce\(|regex_' "$PURE"; then
  bad "the #2264 block grew an embedded interpreter, a regex/reduce walk or a second exec sh"
else
  ok "exactly one exec sh (the plain cat), no interpreter, no regex/reduce — O(1) string concat otherwise"
fi

note "9) KIND-VOCABULARY PIN (iteration-7 STOP-1 decision 4) over every new prompt-visible string ..."
DHP_RE="$(sed -n "s/^KIND_WORDS_RE='\(.*\)'\$/\1/p" "$DHP_DEMO" 2>/dev/null | head -1)"
_eq "the kind regex is the one demo-deep-hunt-promises.sh pins" "$([ -n "$DHP_RE" ] && [ "$DHP_RE" = "$KIND_WORDS_RE" ] && echo same || echo drifted)" "same"
# A gate-produced ACCEPTED block (the exact text a cell receives): two cited, kind-free promises on the fixture.
{
  printf 'PROMISE|#1|unlockAt|shares cannot leave an account before its unlockAt time|%s:7-9\n' "$FXF"
  printf 'PROMISE|#2|shares|shares of an account move only through that account|%s:16-18\n' "$FXF"
} > "$WORK/kind.raw"
python3 "$PGATE" gate --raw "$WORK/kind.raw" --repo "$FXR" --out "$WORK/kind.tsv" > "$WORK/kind.gate" 2>/dev/null
ACC_BLOCK="$(awk '/^END-ACCEPTED$/{f=0} f{print} /^BEGIN-ACCEPTED$/{f=1}' "$WORK/kind.gate")"
_shfn "$DISCOVERY" _promise_requirement > "$WORK/req.sh"
# shellcheck disable=SC1090,SC1091  # sliced out of run-discovery.sh at runtime, by design
. "$WORK/req.sh"
REQ_ALL=""
for rid in held-cite-missing held-cite-unresolved held-cite-deploy held-cite-out-of-scope held-cite-too-wide held-not-a-check \
           held-names-other held-ungrounded held-deployed-state unknown; do
  REQ_ALL="$REQ_ALL $(_promise_requirement "$rid")"
done
CAND_FIXED="$(_shfn "$DISCOVERY" _promise_promote | grep -oE "promise #\\\$ppm_k \([^)]*\) is broken at|PoC sketch: [^\\\\]*" | tr '\n' ' ')"
KIND_TXT="$WORK/kind-text.txt"
{
  printf '%s\n' "$BLOCK_FLAT" "$ACC_BLOCK" "$LEAD_FLAT" "$REASK_FLAT" "$REQ_ALL" "$CAND_FIXED"
} > "$KIND_TXT"
if [ -z "$ACC_BLOCK" ] || [ "$(printf '%s\n' "$ACC_BLOCK" | grep -c '^#')" != "2" ] || [ -z "$CAND_FIXED" ]; then
  bad "could not assemble the kind-vocabulary sample (accepted block / candidate text missing)"
elif grep -iEq "$KIND_WORDS_RE" "$KIND_TXT"; then
  bad "a kind word reached a #2264 prompt-visible string:"
  grep -inE "$KIND_WORDS_RE" "$KIND_TXT" | head -3 | sed 's/^/      /' >&2
else
  ok "no kind word in the block, a gate-produced ACCEPTED block, the lead rule, the re-ask, every requirement phrase and the promoted candidate text"
fi
sed 's/keeps the promise/keeps the access promise/' "$KIND_TXT" > "$WORK/kind-planted.txt"
if grep -iEq "$KIND_WORDS_RE" "$WORK/kind-planted.txt"; then
  ok "negative control: a copy carrying one kind word is caught"
else
  bad "the kind-vocabulary detector does not fire on a planted kind word — the pin is dead"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 2 — THE LISTING (inheritance.py promise-sources --files)
# ----------------------------------------------------------------------------------------------------------
_ps() { python3 "$INHERIT" promise-sources --repo "$FXR" --files "$1" --out "$2"; }
_hdrs() { grep '^=== ' "$1" | sed 's/^=== //; s/ ===$//' | tr '\n' ' '; }

note "10) --files: token files in token order, then ancestor contracts, interfaces, and at most 2 doc windows ..."
_ps "contracts/Router.sol, $FXF@exit+enter" "$WORK/l1.txt"; L1RC=$?
_eq "exit 0" "$L1RC" "0"
_eq "section order" "$(_hdrs "$WORK/l1.txt")" \
  "contracts/Router.sol contracts/Vault.sol contracts/Base.sol contracts/interfaces/IVault.sol contracts/interfaces/IBase.sol docs/router.md README.md "
if grep -q '^7|     /// @notice shares cannot leave an account before its unlockAt time$' "$WORK/l1.txt" \
   && grep -q '^6|     mapping(address => uint256) public unlockAt;$' "$WORK/l1.txt"; then
  ok "a slice token renders its WHOLE file (NatSpec and state declarations outside the slice), with real line numbers"
else
  bad "the sliced file was not rendered whole / with its real line numbers"
fi
_ps "$FXF@exit,$FXF,$FXF@move" "$WORK/l2.txt"
_eq "a file named by three tokens is rendered once" "$(grep -c "^=== $FXF ===\$" "$WORK/l2.txt")" "1"
L_NUM="$(grep '^9| ' "$WORK/l2.txt" | head -1 | sed 's/^9| //')"
_eq "a listed line re-opens exactly (sed -n 9p)" "$([ "$L_NUM" = "$(sed -n 9p "$FXR/$FXF")" ] && echo exact || echo off)" "exact"

note "11) dropped tokens contribute nothing; an empty result writes an EMPTY file; the 160 KB cut ..."
_ps "programs/x.rs,contracts/Missing.sol,/etc/passwd.sol,../escape.sol,contracts/../contracts/Vault.sol, ,x.txt" "$WORK/l3.txt"; L3RC=$?
_eq "non-.sol, missing, absolute and .. tokens: exit 0 and an empty file" "$L3RC:$(wc -c < "$WORK/l3.txt" | tr -d ' ')" "0:0"
BIG="$FXR/contracts/Huge.sol"
{
  printf '%s\n' 'contract Huge {'
  i=1; while [ "$i" -le 4200 ]; do printf '    // filler line %s of a very large fixture source that pushes the listing past its cap\n' "$i"; i=$((i + 1)); done
  printf '%s\n' '}'
} > "$BIG"
_ps "contracts/Huge.sol,$FXF" "$WORK/l4.txt"
L4SZ="$(wc -c < "$WORK/l4.txt" | tr -d ' ')"
if [ "$(tail -1 "$WORK/l4.txt")" = "... [promise sources truncated at 160 KB] ..." ] && [ "$L4SZ" -le $((160 * 1024 + 64)) ] \
   && ! grep -q "^=== $FXF ===\$" "$WORK/l4.txt"; then
  ok "a listing over 160 KB is cut at a line boundary with the marker and nothing after it ($L4SZ bytes)"
else
  bad "the 160 KB cut did not apply (size $L4SZ, last line '$(tail -1 "$WORK/l4.txt")')"
fi
rm -f "$BIG"

note "12) MULTI-ROOT: only the first token's project root is indexed, headers stay clone-root-relative ..."
MR="$WORK/mr-repo"
mkdir -p "$MR/alpha/src" "$MR/beta/src"
printf '[profile.default]\n' > "$MR/alpha/foundry.toml"; printf '[profile.default]\n' > "$MR/beta/foundry.toml"
printf '%s\n' 'import "./Base.sol";' 'contract Pool is Base {' '    function swap(uint256 a) external { }' '}' > "$MR/alpha/src/Pool.sol"
printf '%s\n' 'abstract contract Base {' '    uint256 public reserve;' '}' > "$MR/alpha/src/Base.sol"
printf '%s\n' 'abstract contract Base {' '    uint256 public other;' '}' > "$MR/beta/src/Base.sol"
python3 "$INHERIT" promise-sources --repo "$MR" --files "alpha/src/Pool.sol@swap" --out "$WORK/mr.txt"
_eq "the ancestor resolves inside its own root (a same-named base in another root is no ambiguity)" "$(_hdrs "$WORK/mr.txt")" "alpha/src/Pool.sol alpha/src/Base.sol "
sed 's/    if len(roots) >= 2:$/    if False:/' "$INHERIT" > "$WORK/inh-noroot.py"
if ! cmp -s "$INHERIT" "$WORK/inh-noroot.py"; then
  cp "$HERE/lib/project_roots.py" "$WORK/project_roots.py"
  python3 "$WORK/inh-noroot.py" promise-sources --repo "$MR" --files "alpha/src/Pool.sol" --out "$WORK/mr0.txt"
  _eq "control: without the per-root index the same-named base is ambiguous and dropped" "$(_hdrs "$WORK/mr0.txt")" "alpha/src/Pool.sol "
else
  bad "could not build the single-root control copy of inheritance.py"
fi

note "13) --target is byte-identical to origin/main's inheritance.py; --target --files exits 2 ..."
if git -C "$HERE" cat-file -e origin/main:dark-factory/lib/inheritance.py 2>/dev/null; then
  git -C "$HERE" show origin/main:dark-factory/lib/inheritance.py > "$WORK/inheritance.origin.py"
  cp "$HERE/lib/project_roots.py" "$WORK/" 2>/dev/null || true
  T_BAD=""
  for t in "$FXF" "$FXF:Vault" contracts/Router.sol contracts/Base.sol contracts/Missing.sol contracts/interfaces/IVault.sol; do
    python3 "$WORK/inheritance.origin.py" promise-sources --repo "$FXR" --target "$t" --out "$WORK/t-o.txt" 2>/dev/null
    python3 "$INHERIT" promise-sources --repo "$FXR" --target "$t" --out "$WORK/t-n.txt" 2>/dev/null
    cmp -s "$WORK/t-o.txt" "$WORK/t-n.txt" || T_BAD="$T_BAD $t"
  done
  for t in alpha/src/Pool.sol beta/src/Base.sol; do
    python3 "$WORK/inheritance.origin.py" promise-sources --repo "$MR" --target "$t" --out "$WORK/t-o.txt" 2>/dev/null
    python3 "$INHERIT" promise-sources --repo "$MR" --target "$t" --out "$WORK/t-n.txt" 2>/dev/null
    cmp -s "$WORK/t-o.txt" "$WORK/t-n.txt" || T_BAD="$T_BAD $t"
  done
  if [ -z "$T_BAD" ]; then ok "promise-sources --target output is byte-identical to origin/main's on 8 targets"; else bad "--target output changed for:$T_BAD"; fi
else
  skip "origin/main not fetched — the --target byte comparison cannot run"
fi
python3 "$INHERIT" promise-sources --repo "$FXR" --target "$FXF" --files "$FXF" --out "$WORK/x.txt" >/dev/null 2>&1; XRC=$?
_eq "--target and --files together is a usage error" "$XRC" "2"

# ----------------------------------------------------------------------------------------------------------
# PART 3 — promise-gate.py --names-in (the subject-off-payload rule)
# ----------------------------------------------------------------------------------------------------------
note "14) --names-in: an off-payload promise is dropped BEFORE the cap and never takes a slot ..."
{
  printf 'PROMISE|#1|unlockAt|shares cannot leave an account before its unlockAt time|%s:7-9\n' "$FXF"
  printf 'PROMISE|#2|otherThing|another contract keeps a positive value|contracts/Other.sol:3-4\n'
  printf 'PROMISE|#3|shares|shares of an account move only through that account|%s:16-18\n' "$FXF"
  printf 'PROMISE|#4|unlockAt|entering sets a fresh waiting time|%s:12-14\n' "$FXF"
} > "$WORK/ni.raw"
printf '%s\n' "$FXF" "../escape.sol" "/etc/passwd" "contracts/Missing.sol" > "$WORK/ni.files"
python3 "$PGATE" gate --raw "$WORK/ni.raw" --repo "$FXR" --out "$WORK/ni.tsv" --cap 2 --names-in "$WORK/ni.files" > "$WORK/ni.gate"
_eq "the summary" "$(grep '^PROMISES|' "$WORK/ni.gate")" "PROMISES|emitted=4|accepted=2|dropped=1|overcap=1"
_eq "#2 is dropped subject-off-payload, #4 is over the cap" "$(grep -E '^PROMISE-(DROPPED|OVERCAP)\|' "$WORK/ni.gate" | tr '\n' ' ')" \
  "PROMISE-DROPPED|#2|subject-off-payload PROMISE-OVERCAP|#4 "
_eq "the accepted set is #1 and #3" "$(cut -f1 "$WORK/ni.tsv" | tr '\n' ' ')" "1 3 "
python3 "$PGATE" gate --raw "$WORK/ni.raw" --repo "$FXR" --out "$WORK/ni0.tsv" --cap 2 > "$WORK/ni0.gate"
_eq "control: without --names-in the same promise takes a cap slot" "$(cut -f1 "$WORK/ni0.tsv" | tr '\n' ' ')" "1 2 "
printf '%s\n' "../escape.sol" "/etc/passwd" > "$WORK/ni-unsafe.files"
python3 "$PGATE" gate --raw "$WORK/ni.raw" --repo "$FXR" --out "$WORK/ni2.tsv" --cap 8 --names-in "$WORK/ni-unsafe.files" > "$WORK/ni2.gate"
_eq "a names-in list of unsafe paths names nothing (every promise off-payload)" "$(grep '^PROMISES|' "$WORK/ni2.gate")" "PROMISES|emitted=4|accepted=0|dropped=4|overcap=0"

note "15) without the flag the gate output is byte-identical to origin/main's promise-gate.py ..."
if git -C "$HERE" cat-file -e origin/main:dark-factory/evm-harness/promise-gate.py 2>/dev/null; then
  git -C "$HERE" show origin/main:dark-factory/evm-harness/promise-gate.py > "$WORK/pg-origin.py"
  {
    printf 'FCB_ab12_BEGIN\n'
    printf 'PROMISE|#1|unlockAt|shares cannot leave an account before its unlockAt time|%s:7-9\n' "$FXF"
    printf '  - PROMISE|#2|shares|moves stay with the account|%s:16-18\n' "$FXF"
    printf 'PROMISE|#2|shares|a duplicate id|%s:16-18\n' "$FXF"
    printf 'PROMISE|#x|shares|a bad id|%s:16\n' "$FXF"
    printf 'PROMISE|#5|run|a deploy cite|script/Deploy.s.sol:1\n'
    printf 'PROMISE|#6|y|a test cite|test/Vault.t.sol:3\n'
    printf 'PROMISE|#7|shares|too wide|%s:1-45\n' "$FXF"
    printf 'PROMISE|#8|exit|names other|%s:5\n' "$FXF"
    printf 'PROMISE|#9|exit|as deployed on mainnet|%s:8\n' "$FXF"
    printf 'PROMISE|#10|note|no citation|see the code\n'
    printf 'FCB_ab12_END\n'
  } > "$WORK/pg.raw"
  PG_BAD=""
  for cap in 8 2; do
    python3 "$WORK/pg-origin.py" gate --raw "$WORK/pg.raw" --repo "$FXR" --out "$WORK/pgo.tsv" --cap "$cap" > "$WORK/pgo.out" 2>&1
    python3 "$PGATE" gate --raw "$WORK/pg.raw" --repo "$FXR" --out "$WORK/pgn.tsv" --cap "$cap" > "$WORK/pgn.out" 2>&1
    { cmp -s "$WORK/pgo.out" "$WORK/pgn.out" && cmp -s "$WORK/pgo.tsv" "$WORK/pgn.tsv"; } || PG_BAD="$PG_BAD cap$cap"
  done
  if [ -z "$PG_BAD" ] && grep -q 'accepted=' "$WORK/pgn.out"; then
    ok "flagless stdout and --out TSV are byte-identical to origin/main's on a fixture covering every drop id"
  else
    bad "the flagless gate output changed:$PG_BAD"
  fi
else
  skip "origin/main not fetched — the flagless byte comparison cannot run"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 4 — THE GATE, FIXTURE-DRIVEN (the shipped functions, sliced — never copied)
# ----------------------------------------------------------------------------------------------------------
note "16) the shipped #2264 block slices out of run-discovery.sh and loads ..."
FNS="$WORK/gate-fns.sh"
{
  for fn in _count_stdin _ids_of_lines _check_ids _distinct_sentinel_count _join_wrapped_candidates _dismiss_lines \
            _param_fn_of _param_mentions _tier2_resolve_file _tier2_emit_loc _fcov_read_grounded _fcov_breadth_logs \
            _rubric_promoted_candidates _param_promoted_candidates _cell_candidates; do
    _shfn "$DISCOVERY" "$fn"
  done
  grep '^_json_str() {' "$DISCOVERY"
  sed -n '/^# --- #2264: BREADTH PROMISES/,/^# --- end #2264 block ---$/p' "$DISCOVERY"
} > "$FNS"
FNS_OK=1
for need in _bp_enabled _bp_cap _bp_extract_attempts _bp_payload_files _bp_prepare_line _promise_armed _ptrace_lines \
            _promise_ids _promise_subject _promise_statement _ptrace_for _promise_unnumbered _promise_orphans _promise_held_ok \
            _promise_requirement _promise_discharge _promise_rows _promise_open_leads _promise_gap _promise_reask_needed \
            _promise_open_items _promise_promote _promise_promoted_candidates _promise_promoted_count _promise_dropped_count \
            _bp_line_rollup _bp_record_json _param_fn_of _param_mentions _fcov_read_grounded _cell_candidates _json_str; do
  grep -q "^$need() {" "$FNS" || { FNS_OK=0; bad "could not slice $need out of run-discovery.sh"; }
done
if [ "$FNS_OK" -eq 1 ]; then
  # shellcheck disable=SC1090  # sliced out of run-discovery.sh at runtime, by design
  . "$FNS"
  ok "the #2264 block (and the shipped helpers it reuses) extracted and sourced"
fi
_eq "the shell cap is 8 and the extraction ceiling 2" "$(_bp_cap 2>/dev/null)/$(_bp_extract_attempts 2>/dev/null)" "8/2"
_eq "the payload list: .sol tokens, @ tails stripped, deduped" "$(_bp_payload_files "$FXF@exit, contracts/Router.sol,$FXF,programs/x.rs" 2>/dev/null | tr '\n' ' ')" \
  "$FXF contracts/Router.sol "

# _cl <name> <line...> — write a synthetic cell log and print its path.
_cl() {
  _cl_path="$WORK/$1.log"; shift
  : > "$_cl_path"
  for _cl_line in "$@"; do printf '%s\n' "$_cl_line" >> "$_cl_path"; done
  printf '%s\n' "$_cl_path"
}
# _snap <log> — give a synthetic log the accepted snapshot of the two fixture promises (#1 unlockAt, #2 shares).
_snap() { cp "$WORK/kind.tsv" "$1.promises.tsv"; }
SENT='BREADTH-PROMISES|vault|C1|on'
RUB='SEVERITY-RUBRIC|vault|C1|on'
HELD1="PTRACE|#1|held|$FXF:9|require on unlockAt blocks the early exit"
HELD2="PTRACE|#2|held|$FXF:12-13|whenOpen gates every write to shares"

if [ "$FNS_OK" -eq 1 ]; then
  note "17) PAIRING by id: first well-formed answer wins, un-numbered answers nothing, orphans are counted ..."
  LP="$(_cl pair "$SENT" "$HELD1" "PTRACE|#1|broken|$FXF:exit|a later answer never overrides the first" \
        "PTRACE|held|$FXF:9|no number" "PTRACE|#7|held|$FXF:9|an orphan" "PTRACE|#2|maybe|$FXF:move|malformed verdict" "SAFE")"
  _snap "$LP"
  _eq "rows: #1 held, #2 unanswered (a malformed verdict answers nothing)" "$(_promise_rows "$LP" "$FXR" | cut -f1,3 | tr '\t\n' ': ')" "1:held 2:unanswered "
  _eq "one un-numbered PTRACE line, one orphan" "$(_promise_unnumbered "$LP")/$(_promise_orphans "$LP")" "1/1"
  _eq "gap = 1 unanswered + 1 un-numbered (no rubric => P3 inert)" "$(_promise_gap "$LP" "$FXR")" "2"
  _eq "the re-ask names them" "$(_promise_open_items "$LP" "$FXR")" "unanswered: #2, 1 un-numbered PTRACE line(s)"
  LPU="$(_cl pair-unarmed "$HELD1" "SAFE")"; _snap "$LPU"
  LPS="$(_cl pair-nosnap "$SENT" "SAFE")"
  if [ "$(_promise_gap "$LPU" "$FXR")" = "0" ] && [ "$(_promise_gap "$LPS" "$FXR")" = "0" ] && ! _promise_armed "$LPU" && ! _promise_armed "$LPS" \
     && [ -z "$(_promise_rows "$LPU" "$FXR")" ]; then
    ok "unarmed without the sentinel OR without the snapshot: gap 0, no rows (the gate reads the SENTINEL + snapshot, never the env)"
  else
    bad "the gate armed without its sentinel or snapshot"
  fi
  LN="$(_cl neg "$SENT" "$HELD1" "$HELD2" "SAFE")"; _snap "$LN"
  _eq "NEGATIVE CONTROL: every promise held with a passing citation -> gap 0" "$(_promise_gap "$LN" "$FXR")" "0"
  if ! _promise_reask_needed "$LN" "$FXR"; then ok "... and no re-ask"; else bad "a fully answered cell was re-asked"; fi

  note "18) the HELD CITATION CONTRACT: every failure id, a passing one, and the shape-only path ..."
  H_BAD=""
  # <expected>|<subject>|<field-4>|<prose>  (expected "ok" = returns 0)
  while IFS='|' read -r hx_want hx_subj hx_f4 hx_prose; do
    [ -n "$hx_want" ] || continue
    hx_got="$(_promise_held_ok "PTRACE|#1|held|$hx_f4|$hx_prose" "$hx_subj" "$FXR")" && hx_got=ok
    [ "$hx_got" = "$hx_want" ] || H_BAD="$H_BAD [$hx_f4: got $hx_got want $hx_want]"
  done <<HXEOF
held-cite-missing|unlockAt|see the require above|x
held-cite-unresolved|unlockAt|/abs/contracts/Vault.sol:9|unlockAt
held-cite-unresolved|unlockAt|../contracts/Vault.sol:9|unlockAt
held-cite-unresolved|unlockAt|contracts/Nope.sol:9|unlockAt
held-cite-unresolved|unlockAt|$FXF:99|unlockAt
held-cite-unresolved|unlockAt|$FXF:9-8|unlockAt
held-cite-deploy|unlockAt|script/Deploy.s.sol:3|unlockAt
held-cite-out-of-scope|unlockAt|test/Vault.t.sol:3|unlockAt
held-cite-out-of-scope|unlockAt|mocks/M.sol:1|unlockAt
held-cite-too-wide|unlockAt|$FXF:1-41|unlockAt
held-not-a-check|unlockAt|$FXF:13-14|unlockAt is written here
held-names-other|shares|$FXF:9|the require on unlockAt
held-ungrounded|unlockAt|$FXF:9|checked, fine
held-deployed-state|unlockAt|$FXF:9|unlockAt is set as deployed
ok|unlockAt|$FXF:9|require on unlockAt blocks the early exit
ok|unlockAt|$FXF:12-14|whenOpen guards the write to unlockAt
ok|_unlockAt|lib/oz/Guard.sol:2|the library require compares unlockAt
HXEOF
  if [ -z "$H_BAD" ]; then
    ok "all nine held-* ids fire on their fixture; a require, a bare-name modifier and a vendored lib/ check each keep a promise"
  else
    bad "the held contract misjudged:$H_BAD"
  fi
  hx_s="$(_promise_held_ok "PTRACE|#1|held|contracts/Nope.sol:9|anything" unlockAt "")" && hx_s=ok
  hx_w="$(_promise_held_ok "PTRACE|#1|held|$FXF:1-41|anything" unlockAt "")" && hx_w=ok
  _eq "EMPTY root = citation SHAPE only (a missing file passes, a too-wide range still fails)" "$hx_s/$hx_w" "ok/held-cite-too-wide"
  LD="$(_cl demote "$SENT" "PTRACE|#1|held|$FXF:13-14|unlockAt is written here" "$HELD2" "SAFE")"; _snap "$LD"
  _eq "a failing held answer is DEMOTED (and counted in the gap)" "$(_promise_rows "$LD" "$FXR" | cut -f3 | tr '\n' ' ')/$(_promise_gap "$LD" "$FXR")" "demoted:held-not-a-check held /1"
  _eq "the re-ask names the requirement" "$(_promise_open_items "$LD" "$FXR")" \
    "not kept by the cited line: #1 (the cited lines do not CHECK anything — cite a require/revert/assert, a conditional, a min/max/clamp, an allowlist or validity lookup, or a modifier)"

  note "19) the re-ask phrase table and the agent text agree in BOTH directions; the path regex is one regex ..."
  REQ_PAIRS='held-cite-missing=path:line
held-cite-missing=in code you were given
held-cite-unresolved=in code you were given
held-cite-deploy=deployment script
held-cite-out-of-scope=a test or a mock
held-cite-too-wide=at most 40 lines
held-not-a-check=CHECK
held-not-a-check=require/revert/assert
held-not-a-check=min/max/clamp
held-not-a-check=allowlist or validity lookup
held-names-other=NAME the promise'"'"'s subject
held-ungrounded=literally in the cited lines
held-deployed-state=deployed value keeps nothing
held-deployed-state=what the code ADMITS'
  REQ_BAD=""
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    rid="${pair%%=*}"; phrase="${pair#*=}"
    case "$(_promise_requirement "$rid")" in *"$phrase"*) ;; *) REQ_BAD="$REQ_BAD req:${rid}[$phrase]" ;; esac
    case "$BLOCK_FLAT" in *"$phrase"*) ;; *) REQ_BAD="$REQ_BAD block:[$phrase]" ;; esac
  done <<EOF
$REQ_PAIRS
EOF
  for rid in $(_shfn "$DISCOVERY" _promise_held_ok | grep -oE "printf 'held-[a-z-]+" | sed "s/printf '//" | sort -u); do
    printf '%s\n' "$REQ_PAIRS" | grep -q "^$rid=" || REQ_BAD="$REQ_BAD unpinned:$rid"
  done
  if [ -z "$REQ_BAD" ]; then
    ok "every failure id the decider prints has a re-ask phrase, and every pinned phrase is in both the table and the prompt"
  else
    bad "the re-ask table and the agent text disagree:$REQ_BAD"
  fi
  PH_RE="$(_shfn "$DISCOVERY" _promise_held_ok | sed -n "s/^[[:space:]]*ph_pathline_re='\(.*\)'\$/\1/p")"
  PB_RE="$(_shfn "$DISCOVERY" _param_bound_ok | sed -n "s/^[[:space:]]*pb_pathline_re='\(.*\)'\$/\1/p")"
  PG_RE="$(sed -n "s/^PB_PATHLINE_RE = r'\(.*\)'\$/\1/p" "$PGATE")"
  PF_RE="$(_shfn "$DISCOVERY" _ptrace_for | sed -n "s/^[[:space:]]*pf_pathline_re='\(.*\)'\$/\1/p")"
  if [ -n "$PH_RE" ] && [ "$PH_RE" = "$PB_RE" ] && [ "$PH_RE" = "$PG_RE" ] && [ "$PH_RE" = "$PF_RE" ]; then
    ok "_promise_held_ok, _ptrace_for, _param_bound_ok and promise-gate.py share ONE citation shape ($PH_RE)"
  else
    bad "the path regexes drifted: held='$PH_RE' ptrace='$PF_RE' param='$PB_RE' gate='$PG_RE'"
  fi

  note "20) DISCHARGE of a broken answer: candidate at the function, DISMISS naming #k, else open; P3 only with the rubric ..."
  BRK="PTRACE|#2|broken|$FXF:move|a second account calls move and pulls the shares out"
  LC="$(_cl dis-cand "$SENT" "$RUB" "$HELD1" "$BRK" "CANDIDATE|$FXF:move:17|C1|Medium|promise #2 fails: shares leave through move|call move")"; _snap "$LC"
  LDM="$(_cl dis-dism "$SENT" "$RUB" "$HELD1" "$BRK" "DISMISS|$FXF:move|no-attacker|#2 needs the caller to own the balance")"; _snap "$LDM"
  LOW="$(_cl dis-other "$SENT" "$RUB" "$HELD1" "$BRK" "DISMISS|$FXF:exit|no-attacker|#2 is only about exit")"; _snap "$LOW"
  LO="$(_cl dis-open "$SENT" "$RUB" "$HELD1" "$BRK" "SAFE")"; _snap "$LO"
  LOR="$(_cl dis-open-norub "$SENT" "$HELD1" "$BRK" "SAFE")"; _snap "$LOR"
  _eq "candidate / dismiss / DISMISS at another function / nothing" \
    "$(for l in "$LC" "$LDM" "$LOW" "$LO"; do _promise_rows "$l" "$FXR" | awk -F'\t' '$1 == 2 { printf "%s ", $5 }'; done)" "candidate dismiss open open "
  _eq "P3 counts the open lead only with SEVERITY-RUBRIC| (gap with / without)" "$(_promise_gap "$LO" "$FXR")/$(_promise_gap "$LOR" "$FXR")" "1/0"
  _eq "the re-ask names the open lead at its location" "$(_promise_open_items "$LO" "$FXR")" "open leads: #2 at $FXF:move"
  if _promise_reask_needed "$LO" "$FXR" && ! _promise_reask_needed "$LC" "$FXR"; then
    ok "an open lead re-asks a no-candidate cell; a cell carrying a model CANDIDATE| is never re-asked"
  else
    bad "_promise_reask_needed misjudges the candidate guard"
  fi
  LNV="$(_cl dis-novalid "$SENT" "$RUB" "$BRK")"; _snap "$LNV"; : > "$LNV.novalid"
  LTO="$(_cl dis-timeout "$SENT" "$RUB" "$BRK")"; _snap "$LTO"; : > "$LTO.timeout"
  if ! _promise_reask_needed "$LNV" "$FXR" && ! _promise_reask_needed "$LTO" "$FXR"; then
    ok "a .novalid / .timeout cell is never re-asked (it owns its FAILED reason)"
  else
    bad "a .novalid/.timeout cell was re-asked"
  fi

  note "21) NO COLLISION: PTRACE| is never a TRACE| or a PARAM-TRACE|; both new tokens are boundaries in the SHIPPED joiner ..."
  LX="$(_cl nocoll "$SENT" "$HELD1" "PTRACE|#3|broken|$FXF:move|x" "SAFE")"
  _eq "TRACE ids / PARAM-TRACE ids / distinct TRACE lines" "$(_check_ids TRACE "$LX" | _count_stdin)/$(_check_ids PARAM-TRACE "$LX" | _count_stdin)/$(_distinct_sentinel_count TRACE "$LX")" "0/0/0"
  if _shfn "$DISCOVERY" _unresolved_check_ids | grep -q 'index(line, "TRACE|") == 1' \
     && ! grep -nE "grep[^|]*'TRACE\\\\\\|'" "$DISCOVERY" | grep -v 'PARAM-TRACE\|PTRACE' | grep -q .; then
    ok "every other TRACE| reader is anchored (^[[:space:]]* or index == 1), so a PTRACE| line can never pair with an OPCHECK"
  else
    bad "an unanchored TRACE| reader exists — a PTRACE| line could be read as a TRACE"
  fi
  JWC_AWK="$WORK/join-wrapped.awk"
  _shfn "$DISCOVERY" _join_wrapped_candidates | sed -n "/^  awk '\$/,/^  ' /p" | sed '1d; $d' > "$JWC_AWK"
  JB_BAD=""
  for tok in "$SENT" "$HELD1" "  PTRACE|#2|broken|$FXF:move|indented"; do
    printf 'CANDIDATE|Vault.sol:exit:48|C1|Medium|the exit leg reverts|deploy a\n  stub and assert the revert\n%s\nSAFE\n' "$tok" > "$WORK/wrap.log"
    JOINED="$(awk -f "$JWC_AWK" "$WORK/wrap.log")"
    if [ "$(printf '%s\n' "$JOINED" | grep -c 'CANDIDATE|' || true)" != "1" ] || printf '%s\n' "$JOINED" | grep -q 'PTRACE\|BREADTH' \
       || ! printf '%s\n' "$JOINED" | grep -q 'deploy a stub and assert the revert$'; then
      JB_BAD="$JB_BAD ${tok%%|*}"
    fi
  done
  if [ -s "$JWC_AWK" ] && [ -z "$JB_BAD" ]; then
    ok "a BREADTH-PROMISES| / PTRACE| line (indented or not) closes an open PTY-wrapped CANDIDATE record"
  else
    bad "the shipped joiner glued a #2264 line into a candidate:$JB_BAD"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# PART 5 — PROMOTION
# ----------------------------------------------------------------------------------------------------------
if [ "$FNS_OK" -eq 1 ]; then
  note "22) an open broken lead becomes ONE Medium candidate per resolved location, with provenance ..."
  LPR="$(_cl prom "$SENT" "$RUB" "$HELD1" "$BRK" "PTRACE|#3|broken|Vault.sol:move|a|b both reach move" \
         "PTRACE|#4|broken|Other.sol:poke|outside the payload" "SAFE")"
  { cat "$WORK/kind.tsv"; printf '3\tunlockAt\tx\t-\tentering sets a fresh waiting time\t%s:12-14\n' "$FXF"; printf '4\totherThing\tx\t-\tanother value\tcontracts/Other.sol:3\n'; } > "$LPR.promises.tsv"
  _promise_promote "$LPR" "C1,C6" "$FXF" "$FXR"
  _eq "the provenance line lists every open id at the location" "$(grep '^PROMISE-PROMOTED|' "$LPR.promise-promoted")" \
    "PROMISE-PROMOTED|$FXF:move|#2,#3|shares, unlockAt"
  _eq "an unresolvable location is dropped and recorded" "$(grep '^PROMISE-DROPPED|' "$LPR.promise-promoted")" "PROMISE-DROPPED|Other.sol:poke|unresolved"
  PCAND="$(grep '^CANDIDATE|' "$LPR.promise-promoted")"
  case "$PCAND" in
    "CANDIDATE|$FXF:move|class=C1|Medium|promise #2 (shares: shares of an account move only through that account) is broken at move: a second account calls move and pulls the shares out|PoC sketch: drive the call sequence above from one or more accounts and assert the promised property fails")
      ok "exactly one Medium candidate at the resolved location, first class id only, the cell's own text as the sequence" ;;
    *) bad "the promoted candidate is wrong: $PCAND" ;;
  esac
  _eq "_cell_candidates unions it; the counters agree" "$(_cell_candidates "$LPR" | grep -c 'CANDIDATE|')/$(_promise_promoted_count "$LPR")/$(_promise_dropped_count "$LPR")" "1/1/1"
  LPIPE="$(_cl prom-pipe "$SENT" "$RUB" "$HELD1" "PTRACE|#2|broken|$FXF:move|first|second|third" "SAFE")"; _snap "$LPIPE"
  _promise_promote "$LPIPE" C1 "$FXF" "$FXR"
  if grep '^CANDIDATE|' "$LPIPE.promise-promoted" | awk -F'|' 'NF == 6 { f = 1 } END { exit (f ? 0 : 1) }' \
     && grep -q 'move: first/second/third|PoC' "$LPIPE.promise-promoted"; then
    ok "a | inside the model's text becomes / — the candidate keeps its six fields"
  else
    bad "a | in the model's text broke the candidate record"
  fi

  note "23) one lead per location across gates; a model candidate is never doubled; decision 2; the guards ..."
  LAR="$(_cl prom-rub "$SENT" "$RUB" "$HELD1" "$BRK" "SAFE")"; _snap "$LAR"
  printf 'RUBRIC-PROMOTED|%s:move|no-attacker\n' "$FXF" > "$LAR.rubric-promoted"
  _promise_promote "$LAR" C1 "$FXF" "$FXR"
  LAP="$(_cl prom-par "$SENT" "$RUB" "$HELD1" "$BRK" "SAFE")"; _snap "$LAP"
  printf 'PARAM-PROMOTED|%s:move|#1|amount\n' "$FXF" > "$LAP.param-promoted"
  _promise_promote "$LAP" C1 "$FXF" "$FXR"
  _eq "a location the rubric / parameter gate already promoted is dropped already-promoted" \
    "$(cat "$LAR.promise-promoted" "$LAP.promise-promoted" | tr '\n' ' ')" \
    "PROMISE-DROPPED|$FXF:move|already-promoted PROMISE-DROPPED|$FXF:move|already-promoted "
  LMC="$(_cl prom-model "$SENT" "$RUB" "$HELD1" "$BRK" "CANDIDATE|$FXF:move:17|C1|High|an unrelated overflow in the arithmetic|fuzz it")"; _snap "$LMC"
  _promise_promote "$LMC" C1 "$FXF" "$FXR"
  _eq "a location already carrying a MODEL candidate is not promoted again (its discharge stays open, silently)" \
    "$(_promise_rows "$LMC" "$FXR" | awk -F'\t' '$1 == 2 { print $5 }')/$(_promise_promoted_count "$LMC")/$(_cell_candidates "$LMC" | grep -c 'CANDIDATE|')" "open/0/1"
  LD2="$(_cl prom-dec2 "$SENT" "$RUB" "$HELD1" "$BRK" "CANDIDATE|$FXF:exit:9|C1|High|an unrelated early exit|call exit")"; _snap "$LD2"
  _promise_promote "$LD2" C1 "$FXF" "$FXR"
  if ! _promise_reask_needed "$LD2" "$FXR" && [ "$(_promise_promoted_count "$LD2")" = "1" ] && [ "$(_cell_candidates "$LD2" | grep -c 'CANDIDATE|')" = "2" ]; then
    ok "decision 2: a cell with another model candidate is NOT re-asked but its open promise lead IS promoted (2 leads, 2 locations)"
  else
    bad "decision 2 is not honoured (candidate cell promotion)"
  fi
  _promise_promote "$LOR" C1 "$FXF" "$FXR"
  cp "$LO" "$WORK/prom-nv.log"; _snap "$WORK/prom-nv.log"; : > "$WORK/prom-nv.log.novalid"
  _promise_promote "$WORK/prom-nv.log" C1 "$FXF" "$FXR"
  cp "$LO" "$WORK/prom-un.log"
  _promise_promote "$WORK/prom-un.log" C1 "$FXF" "$FXR"
  if [ ! -s "$LOR.promise-promoted" ] && [ ! -s "$WORK/prom-nv.log.promise-promoted" ] && [ ! -s "$WORK/prom-un.log.promise-promoted" ]; then
    ok "no promotion without SEVERITY-RUBRIC|, on a .novalid cell, or on an unarmed cell (no snapshot)"
  else
    bad "a promotion happened outside a rubric-ON, answered, armed cell"
  fi
  # shellcheck disable=SC2016  # LITERAL source text / Markdown backticks, nothing may expand
  if _shfn "$DISCOVERY" _promise_promote | grep -q '>> "\$ppm_out"' && ! _shfn "$DISCOVERY" _promise_promote | grep -q '>> "\$ppm_log"' \
     && grep -q 'ppm_out="\$ppm_log.promise-promoted"' "$DISCOVERY"; then
    ok "_promise_promote writes only its sidecar (not ending in .log) — the cell log stays a pure model transcript"
  else
    bad "_promise_promote writes into the cell log or its sidecar was renamed"
  fi

  note "24) the per-line rollup and the breadth_promises record, over FINAL logs only ..."
  RD="$WORK/rollrun"; mkdir -p "$RD"
  cp "$LO" "$RD/hunt_v_C1.log"; _snap "$RD/hunt_v_C1.log"
  _promise_rows "$RD/hunt_v_C1.log" "$FXR" > "$RD/hunt_v_C1.log.promise-trace.tsv"
  _promise_promote "$RD/hunt_v_C1.log" C1 "$FXF" "$FXR"
  cp "$LN" "$RD/hunt_v_C6.log"; _snap "$RD/hunt_v_C6.log"
  _promise_rows "$RD/hunt_v_C6.log" "$FXR" > "$RD/hunt_v_C6.log.promise-trace.tsv"
  cp "$LO" "$RD/hunt_v_C1.log.promise-attempt-1"; _snap "$RD/hunt_v_C1.log.promise-attempt-1"
  cp "$RD/hunt_v_C1.log.promise-trace.tsv" "$RD/hunt_v_C1.log.promise-attempt-1.promise-trace.tsv"
  mkdir -p "$RD/promises"; cp "$WORK/kind.tsv" "$RD/promises/v.accepted.tsv"
  # shellcheck disable=SC2046  # the lister's mktemp paths hold no spaces and must split into one argument per log
  _bp_line_rollup "$RD/promises/v.accepted.tsv" $(_fcov_breadth_logs "$RD" v C1,C6) > "$RD/promises_v.tsv"
  _eq "rollup: #1 held in both cells, #2 broken in one and held in one, promoted once" \
    "$(cut -f1,7,8,9,10 "$RD/promises_v.tsv" | tr '\t\n' ', ')" "1,2,0,0,0 2,1,1,0,1 "
  ROW="$(printf 'v\tC1,C6\t%s\tv\taccepted\t900\t3\t2\t1\t0\t0' "$FXF")"
  # shellcheck disable=SC2046  # as above
  REC="$(_bp_record_json "$ROW" "$RD/promises/v" $(_fcov_breadth_logs "$RD" v C1,C6))"
  if printf '%s\n' "$REC" | python3 -c '
import sys, json
r = json.loads(sys.stdin.read())
want = ["subsystem", "files", "state", "listing_bytes", "emitted", "accepted", "dropped", "off_payload", "overcap",
        "accepted_ids", "cells", "held", "broken", "unanswered", "promoted"]
assert list(r) == want, list(r)
assert (r["state"], r["listing_bytes"], r["emitted"], r["accepted"], r["dropped"]) == ("accepted", 900, 3, 2, 1), r
assert (r["accepted_ids"], r["cells"], r["held"], r["broken"], r["unanswered"], r["promoted"]) == ([1, 2], 2, 3, 1, 0, 1), r
'; then ok "the record carries the plan's key set, in order, counted over the two FINAL logs (the attempt file is ignored)"
  else bad "the breadth_promises record is wrong: $REC"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# PART 6 — END-TO-END through run-discovery.sh (offline --agentis stub, no LLM)
# ----------------------------------------------------------------------------------------------------------
# The stub replaces the SUBSTRATE for BOTH agents, so this part tests the DRIVER half. As the lister it records the
# listing it was handed and prints scripted PROMISE| lines (STUB_PROMISES); as the hunter it records what each call
# was handed (block file, the four re-ask channels) and prints the sentinels only when the real agent would have
# rendered the directive. Per-cell state (which gates already re-asked this cell) lets a cell answer a gate only
# AFTER that gate re-asked it — which is what makes the gate ORDER observable (end-to-end g).
HSTUB="$WORK/agentis-stub"
cat > "$HSTUB" <<'STUBEOF'
#!/bin/sh
set -u
F=contracts/Vault.sol
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go) ;;
  *) exit 0 ;;
esac
if [ "${2:-}" = "promise-lister.ag" ]; then
  printf 'LISTER|%s|%s\n' "$(basename "${PROMISE_SOURCES:-none}")" "$(grep -c '^=== ' "${PROMISE_SOURCES:-/dev/null}" 2>/dev/null)" >> "$STUB_REC"
  printf 'PROMISE-LISTER|on\n'
  case "${STUB_PROMISES:-two}" in
    two)  printf 'PROMISE|#1|unlockAt|shares cannot leave an account before its unlockAt time|%s:7-9\n' "$F"
          printf 'PROMISE|#2|shares|shares of an account move only through that account|%s:16-18\n' "$F" ;;
    none) printf 'PROMISE|#1|nothing|a promise with no citation|see the code\n' ;;
    *)    printf 'no promise lines at all\n' ;;
  esac
  exit 0
fi
cell="${HUNT_CLASS:-}"
[ -n "${DEPTH_TARGET:-}" ] && cell="depth"
[ -n "${COVERAGE_REASK_FNS:-}" ] && cell="coverage"
st="$STUB_STATE/$(printf '%s_%s' "${SUBSYSTEM:-}" "$cell" | tr -c 'A-Za-z0-9_' '_')"
[ -n "${TRACE_REASK_IDS:-}" ] && echo trace >> "$st"
[ -n "${PARAM_REASK_ITEMS:-}" ] && echo param >> "$st"
[ -n "${PTRACE_REASK_IDS:-}" ] && echo promise >> "$st"
[ -n "${DISMISS_REASK_GROUNDS:-}" ] && echo rubric >> "$st"
has() { grep -qx "$1" "$st" 2>/dev/null; }
bf=""; [ -n "${BREADTH_PROMISE_FILE:-}" ] && bf="$(basename "$BREADTH_PROMISE_FILE")"
gate="-"
[ -n "${TRACE_REASK_IDS:-}" ] && gate="trace"
[ -n "${PARAM_REASK_ITEMS:-}" ] && gate="param"
[ -n "${PTRACE_REASK_IDS:-}" ] && gate="promise"
[ -n "${DISMISS_REASK_GROUNDS:-}" ] && gate="rubric"
printf 'HUNT|%s|%s|file=%s|gate=%s|ptrace=%s\n' "${SUBSYSTEM:-}" "$cell" "$bf" "$gate" "${PTRACE_REASK_IDS:-}" >> "$STUB_REC"
[ "${OPERATIONALIZE_LENS:-}" = "1" ] && printf 'OPERATIONALIZE|%s|%s|on\n' "$SUBSYSTEM" "$HUNT_CLASS"
[ "${SEVERITY_RUBRIC:-}" = "1" ] && printf 'SEVERITY-RUBRIC|%s|%s|on\n' "$SUBSYSTEM" "$HUNT_CLASS"
[ "${PARAM_AUDIT:-}" = "1" ] && printf 'PARAM-AUDIT|%s|%s|on\n' "$SUBSYSTEM" "$HUNT_CLASS"
[ "${FUNCTION_COVERAGE:-}" = "1" ] && printf 'FUNCTION-COVERAGE|%s|%s|on\n' "$SUBSYSTEM" "$HUNT_CLASS"
PON=0
if [ -n "${BREADTH_PROMISE_FILE:-}" ] && [ -s "$BREADTH_PROMISE_FILE" ]; then PON=1; printf 'BREADTH-PROMISES|%s|%s|on\n' "$SUBSYSTEM" "$HUNT_CLASS"; fi
if [ "${STUB_MODE:-}" = "allknobs" ] && [ "$cell" != "depth" ] && [ "$cell" != "coverage" ]; then
  printf 'OPCHECK|#1|move|shares are conserved across move\n'
  has trace && printf 'TRACE|#1|CLEAN|%s:17-18 subtracts before it adds\n' "$F"
  has param && printf 'PARAM|#1|%s:move|amount|caller\nPARAM-TRACE|#1|unbounded|amount is subtracted from the caller\n' "$F"
  if [ "$PON" = "1" ] && has promise; then
    printf 'PTRACE|#1|held|%s:9|require on unlockAt blocks the early exit\n' "$F"
    printf 'PTRACE|#2|broken|%s:move|a second account calls move and pulls the shares out\n' "$F"
  fi
  printf 'DISMISS|%s:move|no-attacker|amount is caller-chosen\n' "$F"
  printf 'SAFE\n'; exit 0
fi
if [ "$PON" = "1" ]; then
  printf 'PTRACE|#1|held|%s:9|require on unlockAt blocks the early exit\n' "$F"
  case "${STUB_PT:-partial}" in
    broken) printf 'PTRACE|#2|broken|%s:move|a second account calls move and pulls the shares out\n' "$F" ;;
    all)    printf 'PTRACE|#2|held|%s:12-13|whenOpen gates every write to shares\n' "$F" ;;
    *)      if has promise; then printf 'PTRACE|#2|held|%s:12-13|whenOpen gates every write to shares\n' "$F"; fi ;;
  esac
fi
if [ "${STUB_CAND:-0}" = "1" ] && [ "${HUNT_CLASS:-}" = "C1" ] && [ "$cell" = "C1" ] && [ "${SUBSYSTEM:-}" = "vault" ]; then
  printf 'CANDIDATE|%s:exit:9|C1|High|the early-exit check can be skipped|call exit early and assert\n' "$F"
  exit 0
fi
printf 'SAFE\n'
exit 0
STUBEOF
chmod +x "$HSTUB"
HREPO="$WORK/h-repo"; mkdir -p "$HREPO"
cp -R "$FXR/contracts" "$HREPO/contracts"
printf 'vault | C1,C6 | contracts/Vault.sol\nrouter | C1 | contracts/Router.sol,contracts/Vault.sol@move\n' > "$WORK/h-scope.tsv"
printf '# brief\nInvariants to break: the documented paths stay available.\nKnown issues to exclude: none.\n' > "$WORK/h-brief.md"

# _hunt <label> [extra run-discovery args...] — one offline hunt of the fixture manifest; prints the out dir.
# Each run records into $WORK/<label>.rec and keeps its per-cell stub state in $WORK/<label>.state.
_hunt() {
  _h_label="$1"; shift
  mkdir -p "$WORK/$_h_label.state"; : > "$WORK/$_h_label.rec"
  STUB_REC="$WORK/$_h_label.rec" STUB_STATE="$WORK/$_h_label.state" \
    "$DISCOVERY" --repo "$HREPO" --scope "$WORK/h-scope.tsv" --brief "$WORK/h-brief.md" \
    --backend mock --agentis "$HSTUB" --out "$WORK/$_h_label" "$@" > "$WORK/$_h_label.out" 2>&1 || true
  printf '%s\n' "$WORK/$_h_label"
}

note "25) end-to-end (a) ONE lister call per manifest line, the same block for every breadth cell, none for depth/coverage ..."
A="$(BREADTH_PROMISES=1 FUNCTION_COVERAGE=1 STUB_CAND=1 _hunt ea --depth-max-cells 1)"
_eq "exactly one lister call per manifest line (vault, router), handed its own listing" \
  "$(grep '^LISTER|' "$A.rec" | cut -d'|' -f2 | tr '\n' ' ')" "vault.sources router.sources "
_eq "the router listing renders both token files (Router.sol, the Vault.sol slice as a whole file) plus 3 ancestor files" \
  "$(grep '^LISTER|router' "$A.rec" | cut -d'|' -f3)" "5"
_eq "every FIRST breadth attempt is handed its line's block" \
  "$(grep '^HUNT|' "$A.rec" | awk -F'|' '($3 == "C1" || $3 == "C6") && $5 == "gate=-" { print $2 ":" $3 ":" $4 }' | tr '\n' ' ')" \
  "vault:C1:file=vault.block vault:C6:file=vault.block router:C1:file=router.block "
_eq "depth and coverage cells are handed NO block" \
  "$(grep '^HUNT|' "$A.rec" | awk -F'|' '($3 == "depth" || $3 == "coverage") { print $3 ":" $4 }' | sort -u | tr '\n' ' ')" "coverage:file= depth:file= "
_eq "totals: promise_extractions 2, and the banner says so" \
  "$(_jq "$A/discovery-results.json" 'd["totals"]["promise_extractions"]')/$(grep -c ', 2 promise extraction(s), ' "$A.out")" "2/1"
# shellcheck disable=SC2016  # LITERAL source text / Markdown backticks, nothing may expand
if [ -f "$A/run/promise-lister.ag" ] && [ -s "$A/run/promises/vault.block" ] && [ -s "$A/run/hunt_vault_C6.log.promises.tsv" ] \
   && [ -s "$A/run/hunt_vault_C6.log.promise-trace.tsv" ] && [ -s "$A/run/promises_vault.tsv" ] \
   && ! ls "$A"/run/depth_*.promises.tsv >/dev/null 2>&1 && [ ! -e "$A/run/hunt_vault_coverage.log.promises.tsv" ] \
   && grep -q '^- Breadth promises (#2264) `vault`: accepted; 2 accepted of 2 emitted' "$A/discovery-report.md"; then
  ok "the staged lister, the block, the per-cell snapshot + trace sidecar, the per-line rollup and the report footer are there (none on depth/coverage)"
else
  bad "a #2264 artifact is missing or leaked onto a depth/coverage cell"
fi

note "26) end-to-end (b) an untraced #2 is re-asked ONCE naming #2, and the superseded attempt is kept ..."
_eq "the re-ask named the open number" "$(grep '^HUNT|vault|C6|' "$A.rec" | awk -F'|' '$5 == "gate=promise" { print $6 }')" "ptrace=unanswered: #2"
if [ -f "$A/run/hunt_vault_C6.log.promise-attempt-1" ] && [ ! -f "$A/run/hunt_vault_C6.log.promise-attempt-2" ] \
   && [ "$(_jq "$A/discovery-results.json" '[c.get("promises_held") for c in d["cells"] if c["class"] == "C6" and c.get("phase") is None]')" = "[2]" ]; then
  ok "one re-ask (promise-attempt-1 kept), and the final log holds both promises"
else
  bad "the promise re-ask did not run exactly once, or its answer was lost"
fi
_eq "the model-candidate cell (vault/C1) was NOT re-asked" "$(grep -c '^HUNT|vault|C1|.*gate=promise' "$A.rec")" "0"

note "27) end-to-end (c) a rubric-ON broken promise with no candidate reaches the report, candidates[] and the coverage trace ..."
C="$(BREADTH_PROMISES=1 SEVERITY_RUBRIC=1 FUNCTION_COVERAGE=1 STUB_PT=broken _hunt ec --only vault)"
_eq "each vault cell promoted one Medium lead at the resolved location" \
  "$(_jq "$C/discovery-results.json" '[[x.split("|")[0] + "|" + x.split("|")[2] for x in c["candidates"]] for c in d["cells"] if c.get("phase") is None]')" \
  "[['$FXF:move|Medium'], ['$FXF:move|Medium']]"
if grep -q "| vault | C1 | $FXF:move / class=C1 / Medium / promise #2 (shares:" "$C/discovery-report.md" \
   && [ "$(_jq "$C/discovery-results.json" '[c.get("promise_promoted") for c in d["cells"] if c.get("phase") is None]')" = "[1, 1]" ] \
   && [ "$(_jq "$C/discovery-results.json" 'd["breadth_promises"][0]["promoted"]')" = "2" ]; then
  ok "the lead reached discovery-report.md, the per-cell promise_promoted key and the line record"
else
  bad "the promoted promise lead never reached the report / record"
fi
_eq "a promoted promise counts as a 'candidate' trace for the #2256 coverage gate" \
  "$(awk -F'\t' '$2 == "move" { print $5 }' "$C/run/function-coverage_vault.tsv" 2>/dev/null)" "candidate"

note "28) end-to-end (d) KNOB OFF: report, results JSON and banner byte-identical to BREADTH_PROMISES=0/true and to origin/main ..."
D1="$(_hunt ed1)"; D2="$(BREADTH_PROMISES=0 _hunt ed2)"; D3="$(BREADTH_PROMISES=true _hunt ed3)"
_banner() { grep '^================ DISCOVERY' "$1"; }
if cmp -s "$D1/discovery-report.md" "$D2/discovery-report.md" && cmp -s "$D1/discovery-results.json" "$D2/discovery-results.json" \
   && cmp -s "$D1/discovery-report.md" "$D3/discovery-report.md" && cmp -s "$D1/discovery-results.json" "$D3/discovery-results.json" \
   && [ "$(_banner "$D1.out")" = "$(_banner "$D2.out")" ] && [ "$(_banner "$D1.out")" = "$(_banner "$D3.out")" ]; then
  ok "unset, 0 and \"true\" produce the same report, results JSON and banner (only the literal 1 opts in)"
else
  bad "the knob-OFF values disagree"
fi
OFF_BAD=""
for d in "$D1" "$D2" "$D3"; do
  for g in "$d/run/promises" "$d/run/promise-lister.ag" "$d/run/bp-lines.tsv" "$d/run/bp-calls.log" "$d/run/hunt_vault_C1.log.promises.tsv"; do
    [ -e "$g" ] && OFF_BAD="$OFF_BAD ${g##*/}"
  done
  grep -q 'breadth_promises\|promise_extractions\|"promises' "$d/discovery-results.json" && OFF_BAD="$OFF_BAD json-key"
  grep -q 'promise extraction' "$d.out" && OFF_BAD="$OFF_BAD banner"
  grep -q '^LISTER|' "$d.rec" && OFF_BAD="$OFF_BAD lister-call"
  grep '^HUNT|' "$d.rec" | grep -qv 'file=|' && OFF_BAD="$OFF_BAD block-handed"
done
if [ -z "$OFF_BAD" ]; then ok "knob off: no lister call, no staged lister, no promises/ dir, no snapshot, no JSON key, no banner suffix, no block"; else bad "the knob-OFF run is NOT inert:$OFF_BAD"; fi
if git -C "$HERE" cat-file -e origin/main:dark-factory/run-discovery.sh 2>/dev/null \
   && ! git -C "$HERE" show origin/main:dark-factory/run-discovery.sh | grep -q '_bp_enabled'; then
  OSHIM="$WORK/origin-shim"; mkdir -p "$OSHIM"
  for _f in "$HERE"/*; do
    _b="$(basename "$_f")"
    [ "$_b" = "run-discovery.sh" ] && continue
    ln -s "$_f" "$OSHIM/$_b"
  done
  git -C "$HERE" show origin/main:dark-factory/run-discovery.sh > "$OSHIM/run-discovery.sh"
  chmod +x "$OSHIM/run-discovery.sh"
  mkdir -p "$WORK/eco.state"
  STUB_REC="$WORK/eco.rec" STUB_STATE="$WORK/eco.state" "$OSHIM/run-discovery.sh" --repo "$HREPO" --scope "$WORK/h-scope.tsv" \
    --brief "$WORK/h-brief.md" --backend mock --agentis "$HSTUB" --out "$WORK/eco" > "$WORK/eco.out" 2>&1 || true
  if cmp -s "$D1/discovery-report.md" "$WORK/eco/discovery-report.md" && cmp -s "$D1/discovery-results.json" "$WORK/eco/discovery-results.json" \
     && [ "$(_banner "$D1.out")" = "$(_banner "$WORK/eco.out")" ] && [ "$(grep -c '' "$D1.out")" = "$(grep -c '' "$WORK/eco.out")" ]; then
    ok "knob off: the report, the results JSON and the banner are byte-identical to origin/main's run-discovery.sh"
  else
    bad "knob off differs from origin/main's run-discovery.sh"
    diff "$D1/discovery-results.json" "$WORK/eco/discovery-results.json" | head -4 | sed 's/^/      /' >&2
  fi
else
  skip "origin/main (pre-#2264) run-discovery.sh not available — the unset/0/true comparison above stands in"
fi

note "29) end-to-end (e) --jobs 2 yields the same records as --jobs 1 ..."
E1="$(BREADTH_PROMISES=1 SEVERITY_RUBRIC=1 STUB_PT=broken _hunt ee1 --jobs 1)"
E2="$(BREADTH_PROMISES=1 SEVERITY_RUBRIC=1 STUB_PT=broken _hunt ee2 --jobs 2)"
_eq "breadth_promises[], cells[] and totals are identical across --jobs" \
  "$(_jq "$E1/discovery-results.json" '(d["breadth_promises"], d["cells"], d["totals"]) == (lambda e: (e["breadth_promises"], e["cells"], e["totals"]))(json.load(open(sys.argv[1].replace("ee1", "ee2"), encoding="utf-8")))')" "True"
_eq "--jobs 2 also extracted once per line, before any cell" \
  "$(awk -F'|' '/^LISTER\|/ { l++ } /^HUNT\|/ && l < 2 { early++ } END { print l + 0 ":" early + 0 }' "$E2.rec")" "2:0"

note "30) end-to-end (f) 0 accepted -> none-accepted, and the cells are byte-identical to OFF; no PROMISE line -> extraction-failed ..."
F1="$(BREADTH_PROMISES=1 STUB_PROMISES=none _hunt ef1)"
F0="$(_hunt ef0)"
_eq "state none-accepted on both lines, accepted 0" "$(_jq "$F1/discovery-results.json" '[(r["state"], r["accepted"], r["dropped"]) for r in d["breadth_promises"]]')" \
  "[('none-accepted', 0, 1), ('none-accepted', 0, 1)]"
if [ "$(_jq "$F1/discovery-results.json" 'd["cells"]')" = "$(_jq "$F0/discovery-results.json" 'd["cells"]')" ] \
   && ! grep '^HUNT|' "$F1.rec" | grep -qv 'file=|' && ! grep -l 'BREADTH-PROMISES|' "$F1"/run/hunt_*.log >/dev/null 2>&1; then
  ok "no block handed, no sentinel, and cells[] identical to the knob-OFF run"
else
  bad "a none-accepted line changed its cells"
fi
F2="$(BREADTH_PROMISES=1 STUB_PROMISES=nolines _hunt ef2 --only vault)"
_eq "a reply with no PROMISE| line: 2 validated attempts, then extraction-failed" \
  "$(grep -c '^LISTER|' "$F2.rec"):$(_jq "$F2/discovery-results.json" '(d["breadth_promises"][0]["state"], d["totals"]["promise_extractions"])')" "2:('extraction-failed', 2)"

note "31) end-to-end (g) ALL KNOBS ON: gate order OPCHECK -> PARAM -> PROMISE -> rubric, one lead per location ..."
G="$(BREADTH_PROMISES=1 OPERATIONALIZE_LENS=1 SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 PARAM_AUDIT=1 FUNCTION_COVERAGE=1 STUB_MODE=allknobs _hunt eg --only vault --classes C1)"
_eq "the re-ask order of the one breadth cell" "$(grep '^HUNT|vault|C1|' "$G.rec" | cut -d'|' -f5 | tr '\n' ' ')" \
  "gate=- gate=trace gate=param gate=promise gate=rubric "
_eq "one lead at the location across three promotions (rubric promoted it; the promise gate dropped it already-promoted)" \
  "$(_jq "$G/discovery-results.json" '[c["candidates"] for c in d["cells"] if c.get("phase") is None][0].__len__()')/$(grep -c '^RUBRIC-PROMOTED|' "$G/run/hunt_vault_C1.log.rubric-promoted" 2>/dev/null)/$(cat "$G/run/hunt_vault_C1.log.promise-promoted" 2>/dev/null)" \
  "1/1/PROMISE-DROPPED|$FXF:move|already-promoted"
if python3 - "$G/discovery-results.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
r = d["function_coverage"][0]
want = ["subsystem", "files", "total", "value_moving", "covered", "covered_by", "uncovered", "listed", "over_cap",
        "coverage_cell", "still_untouched", "reads_ungrounded", "inherited_outside"]
assert list(r) == want, list(r)
c = [c for c in d["cells"] if c.get("phase") is None][0]
assert c.get("promises") == 2 and c.get("promises_held") == 1 and c.get("promises_broken") == 1, c
assert "promise_promoted" not in c, c
PY
then ok "the function_coverage record keeps its #2256 key set; the promise keys ride the cell (no promise_promoted: dropped)"
else bad "an all-knobs record is wrong"
fi

note "32) end-to-end (h) --depth-from ignores the knob with one stderr line; DF_PROMISE_MAX_REASKS=0 is gate-only ..."
BREADTH_PROMISES=1 STUB_REC="$WORK/eh.rec" STUB_STATE="$WORK/eh.state" "$DISCOVERY" --repo "$HREPO" --brief "$WORK/h-brief.md" \
  --backend mock --agentis "$HSTUB" --out "$WORK/eh" --depth-max-cells 1 --depth-from "$A/discovery-results.json" > "$WORK/eh.out" 2>&1 || true
if [ "$(grep -c 'BREADTH_PROMISES=1 is ignored under --depth-from' "$WORK/eh.out")" = "1" ] \
   && ! grep -q 'breadth_promises\|promise_extractions' "$WORK/eh/discovery-results.json" 2>/dev/null \
   && ! grep -q '^LISTER|' "$WORK/eh.rec" 2>/dev/null && [ ! -e "$WORK/eh/run/promise-lister.ag" ]; then
  ok "--depth-from: one stderr line, no lister call, no staged lister, no record"
else
  bad "--depth-from mishandles BREADTH_PROMISES"
fi
H0="$(BREADTH_PROMISES=1 SEVERITY_RUBRIC=1 STUB_PT=broken DF_PROMISE_MAX_REASKS=0 _hunt eh0 --only vault)"
if ! grep -q 'gate=promise' "$H0.rec" && [ ! -e "$H0/run/hunt_vault_C6.log.promise-attempt-1" ] \
   && grep -q '^CANDIDATE|' "$H0/run/hunt_vault_C6.log.promise-promoted" 2>/dev/null; then
  ok "DF_PROMISE_MAX_REASKS=0: no re-ask, and the open lead is still promoted"
else
  bad "DF_PROMISE_MAX_REASKS=0 re-asked, or did not promote"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 7 — run-zone-hunt.sh: OFF byte-identity, the merged record, the unchanged charge (through a run-discovery shim)
# ----------------------------------------------------------------------------------------------------------
ZFIX="$HERE/fixtures/zone-map"
if [ ! -f "$ZFIX/zones.fixture.txt" ] || ! command -v git >/dev/null 2>&1; then
  skip "33-35) the zone-map fixtures or git are missing — run-zone-hunt.sh part skipped"
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
  # shellcheck disable=SC2016  # LITERAL source text / Markdown backticks, nothing may expand
  printf '#!/bin/sh\ncase "${1:-}" in init) mkdir -p .agentis ;; esac\nexit 0\n' > "$ZSTUB"; chmod +x "$ZSTUB"
  # The recorder: --list-cells probes run the REAL script; a hunt records argv + the knob it saw and writes a minimal
  # results file — plus a breadth_promises record only when the knob is on AND the zone is not the vault one, so the
  # merged file must carry exactly the zones that emitted one.
  REC_DISC="$WORK/rec-discovery.sh"
  cat > "$REC_DISC" <<'RECEOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "--list-cells" ] && exec "$DF_REAL_DISCOVERY" "$@"; done
printf '%s | BP=%s\n' "$*" "${BREADTH_PROMISES-unset}" >> "$DF_ARGV_LOG"
out="" ; only=""
while [ $# -gt 0 ]; do
  case "$1" in --out) out="$2"; shift 2 ;; --only) only="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$out"
bp=""
if [ "${BREADTH_PROMISES:-}" = "1" ] && [ "$only" != "vault deposits" ]; then
  bp=',"breadth_promises":[{"subsystem":"'"$only"'","state":"accepted","accepted":2}]'
fi
printf '{"repo":"z-target","cells":[],"totals":{"cells":0,"candidates":0,"steers":0,"failed":0}%s}\n' "$bp" > "$out/discovery-results.json"
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
  _charges() {
    python3 - "$1" <<'PY'
import sys, os, json
rec = json.load(open(os.path.join(sys.argv[1], "coverage", "zone-coverage.json"), encoding="utf-8"))
print(" ".join("%s=%s" % (z["id"], z.get("cells_charged")) for z in sorted(rec["zones"], key=lambda z: z["id"])))
PY
  }

  note "33) knob ON: every zone hunt sees the knob, the merged file carries the zone-prefixed records that were emitted ..."
  ZRC="$(BREADTH_PROMISES=1 _zh zon "$WORK/zshim")"
  _eq "the capstone exits 0" "$ZRC" "0"
  _eq "every hunt invocation saw BREADTH_PROMISES=1 (argv unchanged otherwise)" "$(grep -c '| BP=1$' "$WORK/zon.argv")/$(grep -c . "$WORK/zon.argv")" "4/4"
  _eq "breadth_promises[] holds exactly the zones that emitted one, each zone-prefixed" \
    "$(_jq "$WORK/zon/discovery/discovery-results.merged.json" 'sorted((r["zone"], r["subsystem"]) for r in d["breadth_promises"])')" \
    "[('contracts_governance', 'governance'), ('contracts_liquidation', 'liquidation engine'), ('contracts_oracle', 'price oracle')]"

  note "34) knob OFF: argv, env and the merged file byte-identical (vs origin/main when available); the charge is unchanged ..."
  ZRC="$(_zh zoff "$WORK/zshim")"
  _eq "the knob-OFF capstone exits 0" "$ZRC" "0"
  if grep -q 'BP=unset' "$WORK/zoff.argv" && ! grep -q 'BP=[01]' "$WORK/zoff.argv" \
     && ! grep -q 'breadth_promises' "$WORK/zoff/discovery/discovery-results.merged.json"; then
    ok "knob off: no BREADTH_PROMISES in the hunt env, no breadth_promises key in the merged file"
  else
    bad "the knob-OFF capstone is not inert"
  fi
  _eq "the recorded cell charge is the same with the knob on and off (#2264 STOP-1 decision 4)" "$(_charges "$WORK/zon")" "$(_charges "$WORK/zoff")"
  if [ "$(sed "s#$WORK/zon#<OUT>#g; s#| BP=1\$##" "$WORK/zon.argv")" = "$(sed "s#$WORK/zoff#<OUT>#g; s#| BP=unset\$##" "$WORK/zoff.argv")" ]; then
    ok "the STAGE 3 argv is byte-identical with the knob on and off (the knob rides the env only)"
  else
    bad "the knob changed the STAGE 3 argv"
  fi
  if git -C "$HERE" cat-file -e origin/main:dark-factory/run-zone-hunt.sh 2>/dev/null \
     && ! git -C "$HERE" show origin/main:dark-factory/run-zone-hunt.sh | grep -q 'bp_by_zone'; then
    git -C "$HERE" show origin/main:dark-factory/run-zone-hunt.sh > "$WORK/rz-origin.sh"
    _shim "$WORK/zshim-origin" "$WORK/rz-origin.sh"
    ZRC="$(_zh zorig "$WORK/zshim-origin")"
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
    fi
    _eq "run-zone-hunt.sh is ADDITIONS ONLY vs origin/main (every origin line survives, in order)" \
      "$(diff "$WORK/rz-origin.sh" "$ZONEHUNT" | grep -c '^<')" "0"
  else
    skip "origin/main (pre-#2264) run-zone-hunt.sh not available — the OFF inertness checks above stand in"
  fi

  note "35) knob ON with no zone emitting a record: the merged file has NO breadth_promises key ..."
  REC_NONE="$WORK/rec-none.sh"
  # shellcheck disable=SC2016  # LITERAL source text / Markdown backticks, nothing may expand
  sed 's/\[ "\$only" != "vault deposits" \]/false/' "$REC_DISC" > "$REC_NONE"
  _shim "$WORK/zshim-none" "$ZONEHUNT"; cp "$REC_NONE" "$WORK/zshim-none/run-discovery.sh"; chmod +x "$WORK/zshim-none/run-discovery.sh"
  ZRC="$(BREADTH_PROMISES=1 _zh znone "$WORK/zshim-none")"
  if [ "$ZRC" = "0" ] && ! grep -q 'breadth_promises' "$WORK/znone/discovery/discovery-results.merged.json"; then
    ok "absent (never []) when no zone emitted a record"
  else
    bad "the merged file carries breadth_promises with nothing emitted"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# PART 8 — MUTATION RESISTANCE (each rule must be load-bearing)
# ----------------------------------------------------------------------------------------------------------
if [ "$FNS_OK" -eq 1 ]; then
  note "36) ten mutations of COPIES — each must flip a named fixture ..."
  LEMPTY="$(_cl mut-empty "$SENT" "$HELD1" "PTRACE||held|$FXF:9|require on unlockAt with no number" "SAFE")"; _snap "$LEMPTY"
  # _probe — the fixture verdicts under whatever functions are currently defined, as one line.
  _probe() {
    _p1="$(_promise_held_ok "PTRACE|#1|held|contracts/Nope.sol:9|unlockAt" unlockAt "$FXR")" && _p1=ok
    _p2="$(_promise_held_ok "PTRACE|#1|held|$FXF:9|the require on unlockAt" shares "$FXR")" && _p2=ok
    _p3="$(_promise_held_ok "PTRACE|#1|held|$FXF:9|checked, fine" unlockAt "$FXR")" && _p3=ok
    _p4="$(_promise_rows "$LEMPTY" "$FXR" | awk -F'\t' '$1 == 2 { print $3 }')"
    _p5="$(_promise_rows "$LP" "$FXR" | awk -F'\t' '$1 == 2 { print $3 }')"
    _p6="$(_promise_gap "$LOR" "$FXR")"
    _promise_promote "$LPR" C1 "$FXF" "$FXR"; _p7="$(_promise_promoted_count "$LPR")"
    # shellcheck disable=SC2046  # the lister's mktemp paths hold no spaces and must split into one argument per log
    _p8="$(_bp_record_json "$ROW" "$RD/promises/v" $(_fcov_breadth_logs "$RD" v C1,C6) | sed 's/.*"cells":\([0-9]*\).*/\1/')"
    printf 'reopen=%s naming=%s grounding=%s unnumbered=%s pairing=%s rubric=%s unresolved=%s attempts=%s\n' \
      "$_p1" "$_p2" "$_p3" "$_p4" "$_p5" "$_p6" "$_p7" "$_p8"
  }
  BASE="$(_probe)"
  if [ "$BASE" = "reopen=held-cite-unresolved naming=held-names-other grounding=held-ungrounded unnumbered=unanswered pairing=unanswered rubric=0 unresolved=1 attempts=2" ]; then
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
  _mutate drop-held-reopen reopen 's/^  if \[ -n "\$ph_root" \]; then$/  if false; then/'
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate drop-subject-naming naming "s/printf 'held-names-other\\\\n'; return 1/:/"
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate drop-grounding grounding "s/printf 'held-ungrounded\\\\n'; return 1;/:;/"
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate accept-unnumbered unnumbered 's/\[ "\$pf_id" = "#\$2" \] || continue/case "$pf_id" in "#$2"|"") ;; *) continue ;; esac/'
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate pair-by-count pairing 's/\[ "\$pf_id" = "#\$2" \] || continue/:/'
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate drop-rubric-arming rubric "s/if grep -qE '\\^\\[\\[:space:\\]\\]\\*SEVERITY-RUBRIC\\\\|' \"\\\$pg_log\" 2>\\/dev\\/null; then/if true; then/"
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate promote-unresolvable unresolved 's/case "\$ppm_loc" in \*:\*) ppm_path="\$(_tier2_resolve_file "\$ppm_base" "\$ppm_files")" ;; esac/ppm_path="${ppm_loc%%:*}"/'
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  _mutate count-superseded-attempt attempts 's#printf .%s\\n. "\$fbl_run/hunt_\${fbl_slug}_\${fbl_cls}.log"$#for x in "$fbl_run/hunt_${fbl_slug}_${fbl_cls}.log"*; do printf "%s\\n" "$x"; done#'
  # The ninth mutation targets the DRIVER (a copy of run-discovery.sh): extract per CELL instead of per line.
  MSHIM="$WORK/mut-shim"; mkdir -p "$MSHIM"
  for _f in "$HERE"/*; do
    _b="$(basename "$_f")"
    [ "$_b" = "run-discovery.sh" ] && continue
    ln -s "$_f" "$MSHIM/$_b"
  done
  # shellcheck disable=SC2016  # sed programs over LITERAL source text
  sed -e '/^    if _bp_enabled; then BP_STEM="\$(_bp_prepare_line /d' \
      -e 's/^      CELL_LOG="\$RUN\/hunt_\${SLUG}_\${CLS}.log"$/      BP_STEM="$(_bp_prepare_line "$SUBSYS" "$FILES_CSV" "$SLUG" "" < \/dev\/null)"\n&/' \
      "$DISCOVERY" > "$MSHIM/run-discovery.sh"
  chmod +x "$MSHIM/run-discovery.sh"
  # shellcheck disable=SC2016  # LITERAL source text / Markdown backticks, nothing may expand
  if cmp -s "$DISCOVERY" "$MSHIM/run-discovery.sh" || [ "$(grep -c '_bp_prepare_line "\$SUBSYS"' "$MSHIM/run-discovery.sh")" != "1" ]; then
    bad "mutation 'extract-per-cell' did not apply (the call sites moved?)"
  else
    mkdir -p "$WORK/mx.state"; : > "$WORK/mx.rec"
    BREADTH_PROMISES=1 STUB_REC="$WORK/mx.rec" STUB_STATE="$WORK/mx.state" "$MSHIM/run-discovery.sh" --repo "$HREPO" \
      --scope "$WORK/h-scope.tsv" --brief "$WORK/h-brief.md" --backend mock --agentis "$HSTUB" --out "$WORK/mx" > "$WORK/mx.out" 2>&1 || true
    MX_N="$(grep -c '^LISTER|' "$WORK/mx.rec")"; A_N="$(grep -c '^LISTER|' "$A.rec")"
    if [ "$MX_N" != "$A_N" ]; then ok "mutation 'extract-per-cell' flips the stub's lister call count ($A_N -> $MX_N)"; else bad "mutation 'extract-per-cell' flips NOTHING"; fi
  fi
  # The tenth mutation targets the GATE tool (a copy of promise-gate.py): drop the --names-in rule.
  sed 's/        if fail is None and names_in is not None and not _named_in(subject, names_in):/        if False:/' "$PGATE" > "$WORK/pg-mut.py"
  if cmp -s "$PGATE" "$WORK/pg-mut.py"; then
    bad "mutation 'drop-names-in' did not apply (the targeted line moved?)"
  else
    python3 "$WORK/pg-mut.py" gate --raw "$WORK/ni.raw" --repo "$FXR" --out "$WORK/ni-mut.tsv" --cap 2 --names-in "$WORK/ni.files" > /dev/null
    NM="$(cut -f1 "$WORK/ni-mut.tsv" | tr '\n' ' ')"
    if [ "$NM" != "1 3 " ]; then ok "mutation 'drop-names-in' flips the accepted set (1 3 -> $NM)"; else bad "mutation 'drop-names-in' flips NOTHING"; fi
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# PART 9 — NEEDS agentis: the AGENT half (clean [SKIP] otherwise)
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  note "37-39) byte-identity probe + rendered text + live-under-mock hunter and lister ..."
  skip "no agentis binary on PATH — the extracted-helper probe and the real mock cells cannot run"
else
  note "37) byte-identity probe: the #2264 helpers print 0 bytes without a non-empty block, under every other-knob combination ..."
  printf '%s\n' "$ACC_BLOCK" > "$WORK/probe-block.txt"
  : > "$WORK/probe-empty.txt"
  FRAG="$WORK/bp.frag"; : > "$FRAG"
  FRAG_MISS=""
  for fn in severity_rubric_enabled breadth_promises_marker read_promise_file breadth_promises_block promise_lead_rule ptrace_reask_block breadth_promises_directive; do
    _agfn "$HUNTER" "$fn" >> "$FRAG"; printf '\n' >> "$FRAG"
    grep -q "^fn $fn(" "$FRAG" || FRAG_MISS="$FRAG_MISS $fn"
  done
  if [ -n "$FRAG_MISS" ]; then
    bad "could not extract the helpers from hunter.ag by line range:$FRAG_MISS"
  else
    SB="$WORK/probe"; mkdir -p "$SB"
    ( cd "$SB" && agentis init >/dev/null 2>&1 ) || true
    printf 'exec.env_passthrough = BREADTH_PROMISE_FILE,PTRACE_REASK_IDS,SEVERITY_RUBRIC,GROUND_EVIDENCE,OPERATIONALIZE_LENS,PARAM_AUDIT,FUNCTION_COVERAGE\n' > "$SB/.agentis/config"
    {
      printf 'cb 300000;\n\n'
      cat "$FRAG"
      printf 'print("DIRLEN=" + to_string(len(breadth_promises_directive())));\n'
      printf 'print("BLOCKLEN=" + to_string(len(breadth_promises_block())));\n'
      printf 'print("LEADLEN=" + to_string(len(promise_lead_rule())));\n'
      printf 'print("=== RENDER ===");\n'
      printf 'print(breadth_promises_directive());\n'
      printf 'print("=== END ===");\n'
    } > "$SB/probe.ag"
    _pl() {
      _pl_k="$1"; shift
      _pl_v="$( cd "$SB" && env -u BREADTH_PROMISE_FILE -u PTRACE_REASK_IDS -u SEVERITY_RUBRIC -u GROUND_EVIDENCE -u OPERATIONALIZE_LENS -u PARAM_AUDIT -u FUNCTION_COVERAGE "$@" agentis go probe.ag --enable-exec 2>&1 | grep "^$_pl_k=" | tail -1 )"  # no-pii: length-only probe, no prompt()
      printf '%s\n' "${_pl_v#"$_pl_k"=}"
    }
    BLOCK_LEN="$(_pl BLOCKLEN)"
    case "$BLOCK_LEN" in
      ''|*[!0-9]*|0) bad "the probe did not complete or the block is empty (BLOCKLEN='$BLOCK_LEN')" ;;
      *) ok "the PTRACE contract block is $BLOCK_LEN bytes (the MEASURED fixed prompt cost, printed rather than assumed)" ;;
    esac
    ZERO_BAD=""
    for bf in "" "BREADTH_PROMISE_FILE=$WORK/probe-empty.txt" "BREADTH_PROMISE_FILE=$WORK/missing.txt"; do
      for sr in "" SEVERITY_RUBRIC=1; do
        for pa in "" PARAM_AUDIT=1; do
          for ol in "" OPERATIONALIZE_LENS=1; do
            for fc in "" FUNCTION_COVERAGE=1; do
              # shellcheck disable=SC2086  # the empty members must vanish, the set ones must split into env words
              _d="$(_pl DIRLEN $bf $sr $pa $ol $fc PTRACE_REASK_IDS=x)"
              [ "$_d" = "0" ] || ZERO_BAD="$ZERO_BAD [$bf $sr $pa $ol $fc -> $_d]"
            done
          done
        done
      done
    done
    if [ -z "$ZERO_BAD" ]; then
      ok "no file / an empty file / a missing file: the directive is 0 bytes under all 48 combinations of the other knobs (even with PTRACE_REASK_IDS set)"
    else
      bad "a no-promise combination rendered #2264 bytes:$ZERO_BAD"
    fi
    ACC_LEN="$(wc -c < "$WORK/probe-block.txt" | tr -d ' ')"
    LEAD_LEN="$(_pl LEADLEN SEVERITY_RUBRIC=1)"
    _eq "a non-empty block renders exactly contract + block (exec drops its last newline) + two newlines (rubric off), + the lead rule (rubric on)" \
      "$(_pl DIRLEN "BREADTH_PROMISE_FILE=$WORK/probe-block.txt")/$(_pl DIRLEN "BREADTH_PROMISE_FILE=$WORK/probe-block.txt" SEVERITY_RUBRIC=1)" \
      "$((BLOCK_LEN + ACC_LEN + 1))/$((BLOCK_LEN + LEAD_LEN + ACC_LEN + 1))"
    RENDER="$( cd "$SB" && env BREADTH_PROMISE_FILE="$WORK/probe-block.txt" SEVERITY_RUBRIC=1 PTRACE_REASK_IDS="unanswered: #2; not kept by the cited line: #1 ($REQ_ALL); open leads: #3 at contracts/X.sol:f" agentis go probe.ag --enable-exec --grant-pii 2>&1 \
      | awk '/^=== RENDER ===$/{f=1; next} /^=== END ===$/{f=0} f' )"
    if [ -n "$RENDER" ] && printf '%s\n' "$RENDER" | grep -q '^=== PROMISES THIS CODE MAKES' && printf '%s\n' "$RENDER" | grep -q '^LEADS FROM THE PROMISES' \
       && printf '%s\n' "$RENDER" | grep -q '^RE-ASK' && ! printf '%s\n' "$RENDER" | grep -iEq "$KIND_WORDS_RE"; then
      ok "the RENDERED directive (block + lead rule + a re-ask naming every requirement phrase + the gate's block) carries no kind word"
    else
      bad "the rendered directive is incomplete or carries a kind word"
      printf '%s\n' "$RENDER" | grep -inE "$KIND_WORDS_RE" | head -3 | sed 's/^/      /' >&2
    fi
  fi

  note "38) live-under-mock: a real hunter cell prints BREADTH-PROMISES| only with a non-empty block file ..."
  LM="$WORK/live"; mkdir -p "$LM"
  ( cd "$LM" && agentis init >/dev/null 2>&1 ) || true
  cp "$HUNTER" "$LM/hunter.ag"; cp "$HERE/auditor/slice-fns.sh" "$LM/slice-fns.sh"
  {
    printf 'llm.backend = mock\n'
    printf 'exec.env_passthrough = TARGET_DIR,IN_SCOPE,SCOPE_BRIEF,TAXONOMY,HUNT_CLASS,SUBSYSTEM,SLICER,BREADTH_PROMISE_FILE,PTRACE_REASK_IDS\n'
    printf 'learning.enabled = true\nexperience.enabled = true\nknowledge.enabled = true\n'
  } > "$LM/.agentis/config"
  _live() {
    ( cd "$LM" && env TARGET_DIR="$HREPO" IN_SCOPE="$FXF" SCOPE_BRIEF="$WORK/h-brief.md" HUNT_CLASS=C1 \
        TAXONOMY="$HERE/auditor/bug-taxonomy.md" SUBSYSTEM=vault SLICER="$LM/slice-fns.sh" "$@" \
        agentis go hunter.ag --enable-exec --enable-messaging --grant-pii 2>&1 )
  }
  LV_ON="$(_live BREADTH_PROMISE_FILE="$WORK/probe-block.txt")"
  LV_EMPTY="$(_live BREADTH_PROMISE_FILE="$WORK/probe-empty.txt")"
  LV_OFF="$(_live)"
  if printf '%s\n' "$LV_ON" | grep -q '^BREADTH-PROMISES|vault|C1|on$' && ! printf '%s\n' "$LV_EMPTY" | grep -q 'BREADTH-PROMISES|' \
     && ! printf '%s\n' "$LV_OFF" | grep -q 'BREADTH-PROMISES|'; then
    ok "a real hunter cell: the sentinel with a non-empty block; absent with an empty file and with no file"
  else
    bad "the BREADTH-PROMISES| sentinel does not follow the block file in a real hunter cell"
    printf '%s\n' "$LV_ON" | tail -3 | sed 's/^/      /' >&2
  fi

  note "39) live-under-mock: the real promise-lister.ag issues exactly ONE prompt, and none on an empty listing ..."
  LL="$WORK/lister"; mkdir -p "$LL"
  ( cd "$LL" && agentis init >/dev/null 2>&1 ) || true
  cp "$LISTER" "$LL/promise-lister.ag"
  printf 'llm.backend = mock\ntrace.level = normal\nexec.env_passthrough = PROMISE_SOURCES\n' > "$LL/.agentis/config"
  python3 "$INHERIT" promise-sources --repo "$FXR" --files "$FXF" --out "$WORK/lister-src.txt"
  LL_ON="$( cd "$LL" && env PROMISE_SOURCES="$WORK/lister-src.txt" agentis go promise-lister.ag --enable-exec --grant-pii 2>&1 )"
  LL_EMPTY="$( cd "$LL" && env PROMISE_SOURCES="$WORK/probe-empty.txt" agentis go promise-lister.ag --enable-exec --grant-pii 2>&1 )"
  LL_UNSET="$( cd "$LL" && env -u PROMISE_SOURCES agentis go promise-lister.ag --enable-exec --grant-pii 2>&1 )"
  _eq "on a listing: PROMISE-LISTER|on and ONE prompt (the extraction instruction)" \
    "$(printf '%s\n' "$LL_ON" | grep -c '^PROMISE-LISTER|on$')/$(printf '%s\n' "$LL_ON" | grep -c '^\[prompt\] "You are reading a smart-contract system')/$(printf '%s\n' "$LL_ON" | grep -c '^\[prompt\]')" "1/1/1"
  _eq "empty / unset listing: PROMISE-LISTER|empty and NO prompt" \
    "$(printf '%s\n' "$LL_EMPTY" "$LL_UNSET" | grep -c '^PROMISE-LISTER|empty$')/$(printf '%s\n' "$LL_EMPTY" "$LL_UNSET" | grep -c '^\[prompt\]')" "2/0"
  if ! printf '%s\n' "$LL_ON" | grep -Eq '^[[:space:]]*PROMISE\|'; then
    ok "the trace echo of the instruction carries no line the promise-lister validity predicate could mistake for a reply"
  else
    bad "a PROMISE| line leaked into the mock lister log without a model reply"
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "ALL ASSERTIONS HELD — #2264 breadth promises are extracted once per line, output-gated per cell, bounded and default OFF."
  note "NOTE: nothing above is a recall claim; that is the operator's measurement on a fresh set."
  exit 0
fi
note "$FAILS assertion(s) FAILED"
exit 1
