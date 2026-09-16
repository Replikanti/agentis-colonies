#!/usr/bin/env bash
# demo-resolve-cell.sh — the gate for #2235 PR B: the discovery cell's ACCESS to resolve-external.sh, the
# `EXTERNAL-CITED` evidence kind, and the harness re-open that decides whether such a citation counts.
#
# What the change is. PR A shipped a deterministic, LLM-free resolver that turns an external SYMBOL into a
# `path:line` anyone can re-open. On its own it changed no hunt: nothing called it. This PR gives a discovery
# cell the VERB — `run-discovery.sh --external-resolve` copies the resolver into the cell dir (the hunt
# sandbox binds the cell dir, never the colonies checkout), binds ONE extra directory (the cache) into that
# sandbox, and hands hunter.ag a pure-meta directive stating the command, its input contract (a symbol or an
# address, never a URL), the per-cell budget and how a resolved fact is cited:
#     TRACE|#<k>|CLEAN|EXTERNAL-CITED <path>:<line> — <the property those lines state>
# The load-bearing half is NOT the prompt (prompt text is not a gate — the #2213 lesson) but the harness:
# _uncited_dismissal_lines RE-OPENS every such citation, FROM THE CACHE OR THE REPO AND NEVER FROM THE
# NETWORK, and accepts it only when the path lies under one of those two roots, the file exists, and the
# cited lines literally state a fact token. Anything else marks THAT check uncited — the #2230 per-check
# semantics, no new status vocabulary, never a whole-cell failure.
#
# DEFAULT OFF. Without --external-resolve (or `DF_EXTERNAL_RESOLVE=1`) the directive is exactly "" bytes, no
# resolver is copied anywhere, the sandbox bind set is unchanged, and the per-cell JSON key set is untouched.
# The knob is deliberately INDEPENDENT of OPERATIONALIZE_LENS (issue #2235 STOP-1 decision 2): the dismissals
# it exists to give a cell a move against were measured in lens-OFF arms too.
#
# Three parts, in cost order:
#   1) SOURCE GUARD (the CI floor — pure grep/awk, no agentis, no forge, no network, no LLM): the four
#      hunter.ag helpers, the marker/sentinel coupling, the lens-INDEPENDENCE of the gate, the splice point
#      inside the shared RULES block right after the config rule, the directive's load-bearing sentences, an
#      OVERFITTING denylist over that text, substrate purity, the flag + env knob and their default-OFF
#      polarity, the resolver copy into $RUN and into every per-cell dir, all four env_passthrough entries
#      (the #1426 inert-knob trap), the conditional HUNT_SANDBOX_EXTERNAL export, the optional sandbox bind,
#      and the new record boundary.
#   2) THE GATE (CI floor again — the SHIPPED functions sliced out of run-discovery.sh by function name, so a
#      copy-pasted twin cannot drift): a cache citation whose lines state the fact is ACCEPTED; the same file
#      cited on a range that states nothing is uncited; a cache path that does not exist is uncited; a path
#      under NEITHER root is uncited even when the file there does state the fact (it is never opened); `..`
#      cannot walk out of a root; a repo-relative citation still works and the #2225/#2227 branches are
#      unchanged; one bad citation marks ONE check, not the cell; and with no cache root the pre-#2235
#      behaviour is exactly what it was.
#   3) LIVE UNDER MOCK ([SKIP] without an `agentis` binary): real offline hunt cells through
#      run-discovery.sh --backend mock, ON and OFF, plus a DIRLEN byte-identity probe running the helpers
#      EXTRACTED FROM hunter.ag by name. ON: the sentinel fires end-to-end (env_passthrough -> getenv), the
#      resolver is in the cell dir, the budget dir exists. OFF: no sentinel, no resolver anywhere under the
#      run dir, and the same per-cell JSON key set.
#
# What this demo does NOT prove: that the model USES the verb, or that using it finds anything. The directive
# is English prose interpreted by an LLM; a mock backend never reasons. That is the live ON/OFF mutation arm's
# job (an operator step, deliberately not CI — this host runs a held-out freeze) and M4's, and no assertion
# here may be read as a recall claim.
#
# Usage: dark-factory/demo-resolve-cell.sh
# Exit:  0 = every assertion held; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HUNTER="$HERE/auditor/agents/hunter.ag"
DISCOVERY="$HERE/run-discovery.sh"
SANDBOX="$HERE/lib/claude-sandboxed.sh"
RESOLVER="$HERE/resolve-external.sh"

FAILS=0
note() { echo "demo-resolve-cell.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for f in "$HUNTER" "$DISCOVERY" "$SANDBOX" "$RESOLVER"; do
  [ -f "$f" ] || { note "missing input: $f" >&2; exit 3; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-resolve-cell.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ==========================================================================================================
# PART 1 — SOURCE GUARD
# ==========================================================================================================
note "1) hunter.ag carries the four resolver helpers and the marker is the block's literal first line ..."
EXT_FNS="external_resolve_marker external_resolve_block external_resolve_directive"
MISS=""
for fn in $EXT_FNS; do grep -q "^fn $fn(" "$HUNTER" || MISS="$MISS $fn"; done
[ -z "$MISS" ] && ok "hunter.ag declares:$(printf ' %s' $EXT_FNS)" || bad "hunter.ag is missing:$MISS"

MARKER="$(sed -n '/^fn external_resolve_marker(/,/^}$/p' "$HUNTER" | sed -n 's/^[[:space:]]*return "\(.*\)";$/\1/p')"
if [ -n "$MARKER" ]; then
  ok "the marker is a single literal: $MARKER"
else
  bad "external_resolve_marker() does not return one string literal"
fi
if sed -n '/^fn external_resolve_block(/,/^}$/p' "$HUNTER" | head -2 | grep -q 'external_resolve_marker() + "\\n"'; then
  ok "external_resolve_block() opens with the marker (so what the sentinel greps is what renders)"
else
  bad "the block does not start with external_resolve_marker() — a reword could desync the sentinel"
fi

note "2) the sentinel is gated on the marker being IN the assembled prompt, never on getenv ..."
if grep -q 'if index_of(instruction, external_resolve_marker()) >= 0 {' "$HUNTER" \
   && grep -q 'print("EXTERNAL-RESOLVE|" + subsystem + "|" + cls + "|on");' "$HUNTER"; then
  ok "EXTERNAL-RESOLVE| fires only when the directive is demonstrably in the prompt about to be sent"
else
  bad "the EXTERNAL-RESOLVE| sentinel is missing or is gated on something other than the assembled instruction"
fi
if printf '%s' "EXTERNAL-RESOLVE|" | grep -q 'CANDIDATE|'; then
  bad "the sentinel token carries a CANDIDATE| substring"
else
  ok "the sentinel carries no CANDIDATE| substring (run-agent-validated.sh cannot false-accept a cell on it)"
fi

note "3) the directive is gated ONLY on EXTERNAL_RESOLVER — lens-INDEPENDENT (STOP-1 decision 2) ..."
DIR_BODY="$(sed -n '/^fn external_resolve_directive(/,/^}$/p' "$HUNTER")"
if printf '%s\n' "$DIR_BODY" | grep -q 'getenv("EXTERNAL_RESOLVER")' \
   && printf '%s\n' "$DIR_BODY" | grep -q 'if resolver == "" { return ""; }'; then
  ok "external_resolve_directive() returns \"\" for an empty EXTERNAL_RESOLVER (the OFF prompt is byte-identical)"
else
  bad "the directive's empty-env gate is missing — an OFF cell's prompt would not be byte-identical"
fi
if printf '%s\n' "$DIR_BODY" | grep -qiE 'operationaliz|OPERATIONALIZE_LENS'; then
  bad "the resolver directive is gated on the #2211 lens — STOP-1 decision 2 requires it to be independent"
else
  ok "the directive mentions no lens toggle: a lens-OFF cell can still be given the verb"
fi

note "4) splice point: inside the shared RULES block, immediately after the config-realizability rule ..."
RULES="$(sed -n '/^  + config_realizability_rule()/,/Subsystem under review/p' "$HUNTER")"
if printf '%s\n' "$RULES" | grep -q '^  + extres$'; then
  ok "extres is concatenated after config_realizability_rule() and before the subsystem line"
else
  bad "the resolver directive is not spliced between the config rule and the subsystem line"
fi
if grep -q '^let extres = external_resolve_directive();$' "$HUNTER"; then
  ok "the directive is read once into \`extres\`, next to the other conditional blocks"
else
  bad "hunter.ag does not read external_resolve_directive() into extres"
fi

note "5) the directive states the verb, the input contract, the budget, the grammar and the citation rule ..."
BLOCK="$(sed -n '/^fn external_resolve_block(/,/^}$/p' "$HUNTER")"
_says() { printf '%s\n' "$BLOCK" | grep -qiF "$1"; }
_pin() { if _says "$2"; then ok "the directive states: $1"; else bad "the directive no longer states: $1 ($2)"; fi; }
_pin "the resolved/unresolved output grammar"          'EXTERNAL|<symbol>|unresolved|<reason>'
_pin "the input contract is an identifier, not a URL"  'no URL, no host'
_pin "the per-cell budget"                             'BUDGET: at most '
_pin "the EXTERNAL-CITED evidence kind"                'TRACE|#<k>|CLEAN|EXTERNAL-CITED'
_pin "that the citation is re-opened and read back"    'RE-OPENED and read back'
_pin "that an unresolved external claim is UNRESOLVED" 'UNRESOLVED, never'
if printf '%s\n' "$BLOCK" | grep -q 'CANDIDATE|'; then
  bad "the directive text contains a CANDIDATE| substring"
else
  ok "the directive text carries no CANDIDATE| substring"
fi
CMD_MISS=""
for _v in resolver repo cache state budget; do
  printf '%s\n' "$BLOCK" | grep -q "+ $_v" || CMD_MISS="$CMD_MISS $_v"
done
if [ -z "$CMD_MISS" ]; then
  ok "every path and the budget are PASSED IN (the model never has to invent a cache path or a bound)"
else
  bad "the directive does not interpolate:$CMD_MISS — the model would have to invent those values"
fi

note "6) OVERFITTING denylist: the directive names no protocol, product, token or unit ..."
DENY='Curve|Convex|Pendle|Balancer|Uniswap|Aave|Compound|Chainlink|LayerZero|Across|Connext|Everclear|Lido|Morpho|Euler|Maker|USDC|USDT|DAI|WETH|stETH|wstETH|ERC-?4626|ERC-?7540'
HITS="$(printf '%s\n' "$BLOCK" | grep -Eio "$DENY" | sort -u | tr '\n' ' ')"
if [ -z "$HITS" ]; then
  ok "no protocol/product/token/standard name in the directive (it cannot leak an answer on a held-out target)"
else
  bad "the directive names: $HITS — it must stay pure-meta"
fi

note "7) substrate purity: the block is top-level string concat, no exec sh, no per-element work ..."
if printf '%s\n' "$BLOCK" "$DIR_BODY" | grep -qE 'exec sh|reduce|for_each|map\(|python3 -c'; then
  bad "the resolver helpers introduce an exec/per-element construct — every cell would pay for it"
else
  ok "no exec sh, no reduce/map, no embedded interpreter in either helper"
fi

note "8) run-discovery.sh: the flag and its env twin exist and are default OFF ..."
if grep -q -- '--external-resolve) EXT_RESOLVE=1; shift ;;' "$DISCOVERY"; then
  ok "--external-resolve is a no-value flag"
else
  bad "run-discovery.sh has no --external-resolve flag"
fi
if grep -q 'case "${DF_EXTERNAL_RESOLVE:-}" in 1) EXT_RESOLVE=1 ;; \*) EXT_RESOLVE=0 ;; esac' "$DISCOVERY"; then
  ok "DF_EXTERNAL_RESOLVE=1 is the only value that opts in; unset/anything else is OFF (the default)"
else
  bad "the DF_EXTERNAL_RESOLVE default-OFF polarity is missing or was widened"
fi
if grep -q 'EXTERNAL_RESOLVER="" ; EXTERNAL_CACHE="" ; EXTERNAL_BUDGET="" ; EXTERNAL_BUDGET_DIR=""' "$DISCOVERY"; then
  ok "all four shell-side variables initialise EMPTY, so every OFF path is inert"
else
  bad "the external-resolve variables are not initialised empty (an OFF run could leak a non-empty env)"
fi

note "9) the resolver is COPIED into the run dir and into every per-cell dir (the sandbox sees no checkout) ..."
if grep -q 'cp "$HERE/resolve-external.sh" "$RUN/resolve-external.sh"' "$DISCOVERY"; then
  ok "the run dir gets a copy, next to the slice-fns.sh copy"
else
  bad "resolve-external.sh is not copied into \$RUN — a path into the colonies checkout does not exist in the sandbox"
fi
if grep -q 'if \[ -n "$EXTERNAL_RESOLVER" \]; then cp "$RUN/resolve-external.sh" "$cdir/resolve-external.sh"; fi' "$DISCOVERY"; then
  ok "every parallel per-cell dir gets its own copy (same idiom as slice-fns.sh)"
else
  bad "the parallel fan-out does not copy the resolver into the per-cell dir"
fi
if grep -q 'EXTERNAL_RESOLVER="${EXTERNAL_RESOLVER:+$rc_dir/resolve-external.sh}"' "$DISCOVERY"; then
  ok "the cell is handed the copy inside ITS OWN dir (\$rc_dir), which is what the sandbox binds"
else
  bad "the cell env does not point EXTERNAL_RESOLVER at the per-cell copy"
fi

note "10) all four knobs ride exec.env_passthrough (the #1426 inert-knob trap) ..."
PASS_LINE="$(grep -n 'exec.env_passthrough = ' "$DISCOVERY" | head -1 | cut -d: -f2-)"
PT_MISS=""
for k in EXTERNAL_RESOLVER EXTERNAL_CACHE EXTERNAL_BUDGET_STATE EXTERNAL_BUDGET; do
  case "$PASS_LINE" in *"$k"*) : ;; *) PT_MISS="$PT_MISS $k" ;; esac
done
[ -z "$PT_MISS" ] \
  && ok "EXTERNAL_RESOLVER / EXTERNAL_CACHE / EXTERNAL_BUDGET_STATE / EXTERNAL_BUDGET are all registered" \
  || bad "unregistered (getenv would read the sanitised env and the feature would be silently inert):$PT_MISS"

note "11) the sandbox bind is opt-in, appended AFTER the tmpfs \$HOME, and absent by default ..."
if grep -q 'EXTERNAL="${HUNT_SANDBOX_EXTERNAL:-}"' "$SANDBOX" \
   && grep -q '\[ -n "$EXTERNAL" \] && \[ -e "$EXTERNAL" \] && binds+=(--bind "$EXTERNAL" "$EXTERNAL")' "$SANDBOX"; then
  ok "lib/claude-sandboxed.sh binds the cache only when the var is set AND the dir exists"
else
  bad "the optional HUNT_SANDBOX_EXTERNAL bind is missing from lib/claude-sandboxed.sh"
fi
TMPFS_LN="$(grep -n -- '--tmpfs "\$H"' "$SANDBOX" | head -1 | cut -d: -f1)"
EXTB_LN="$(grep -n 'binds+=(--bind "$EXTERNAL" "$EXTERNAL")' "$SANDBOX" | head -1 | cut -d: -f1)"
if [ -n "$TMPFS_LN" ] && [ -n "$EXTB_LN" ] && [ "$EXTB_LN" -gt "$TMPFS_LN" ]; then
  ok "the bind is appended after --tmpfs \$HOME (a \$HOME-default cache is not masked by the tmpfs)"
else
  bad "the external bind is not after the tmpfs \$HOME entry (tmpfs=$TMPFS_LN, bind=$EXTB_LN)"
fi
if grep -q 'export HUNT_SANDBOX_EXTERNAL="$EXTERNAL_CACHE"' "$DISCOVERY"; then
  EXPORT_LN="$(grep -n 'export HUNT_SANDBOX_EXTERNAL=' "$DISCOVERY" | head -1 | cut -d: -f1)"
  GUARD_LN="$(grep -n 'if \[ "$EXT_RESOLVE" -eq 1 \]; then' "$DISCOVERY" | head -1 | cut -d: -f1)"
  if [ -n "$GUARD_LN" ] && [ "$EXPORT_LN" -gt "$GUARD_LN" ]; then
    ok "run-discovery.sh exports HUNT_SANDBOX_EXTERNAL only INSIDE the --external-resolve branch"
  else
    bad "HUNT_SANDBOX_EXTERNAL is exported unconditionally — a default run's sandbox view would change"
  fi
else
  bad "run-discovery.sh never exports HUNT_SANDBOX_EXTERNAL"
fi
for f in run-refute.sh run-invariant-hunt.sh map-zones.sh gen-briefs.sh run-poc.sh; do
  if grep -q 'HUNT_SANDBOX_EXTERNAL' "$HERE/$f" 2>/dev/null; then
    bad "$f exports HUNT_SANDBOX_EXTERNAL — only the discovery emitter has the cache"
  fi
done
ok "the other five hunt emitters do not bind the cache (the widening is scoped to discovery cells)"

note "12) EXTERNAL-RESOLVE| is a record boundary in _join_wrapped_candidates ..."
if sed -n '/^_join_wrapped_candidates() {$/,/^}$/p' "$DISCOVERY" | grep -q 'EXTERNAL-RESOLVE\\|'; then
  ok "a sentinel can never be glued onto an open CANDIDATE| record as prose"
else
  bad "EXTERNAL-RESOLVE| is not in the record-boundary predicate"
fi

# ==========================================================================================================
# PART 2 — THE GATE (shipped functions, sliced by name)
# ==========================================================================================================
note "13) the shipped gate functions slice out of run-discovery.sh and load ..."
GATE_FNS="$WORK/gate-fns.sh"
{
  for fn in _distinct_sentinel_count _distinct_trace_lines _uncited_dismissal_lines _uncited_dismissals \
            _unresolved_trace_count _ids_of_lines _check_ids _count_stdin _untraced_rule _missing_check_ids \
            _orphan_trace_ids _unnumbered_opchecks _uncited_check_ids _shortfall_id_list _all_checks_untraced \
            _opcheck_trace_gap _untraced_safe; do
    sed -n "/^$fn() {\$/,/^}\$/p" "$DISCOVERY"
  done
} > "$GATE_FNS"
GATE_LOADED=0
if grep -q '^_uncited_dismissal_lines() {$' "$GATE_FNS" && grep -q '^_uncited_check_ids() {$' "$GATE_FNS" \
   && grep -q '^_opcheck_trace_gap() {$' "$GATE_FNS"; then
  # shellcheck disable=SC1090  # sliced out of run-discovery.sh at runtime, by design
  . "$GATE_FNS"
  GATE_LOADED=1
  ok "the SHIPPED _uncited_dismissal_lines / _uncited_check_ids / _opcheck_trace_gap were sourced (not copies)"
else
  bad "could not slice the gate functions out of run-discovery.sh (renamed or reshaped?)"
fi

# Two roots the harness owns, and one directory that is NEITHER — the third exists to prove a cited file
# outside both is never opened even when its text WOULD satisfy the content check.
REPO_DIR="$WORK/repo"; CACHE_DIR="$WORK/cache"; OUTSIDE="$WORK/outside"
mkdir -p "$REPO_DIR/src" "$CACHE_DIR/repo/github.com/example-org/ext-lib@default/src" \
         "$CACHE_DIR/sourcify/1/0xabc/sources" "$OUTSIDE"
{
  echo "// synthetic: the repo's own view of the external rate"
  echo "contract Consumer {"
  echo "    // the consumer assumes the rate is scaled by 1e18 for every source"
  echo "    function priceOf(address a) external view returns (uint256) { return 0; }"
  echo "}"
} > "$REPO_DIR/src/Consumer.sol"
{
  echo "// synthetic cached upstream source"
  echo "interface IExtRate {"
  echo "    /// @dev the returned value is scaled by 1e18 for a standard source"
  echo "    function rate(address s) external view returns (uint256);"
  echo "    /// a line that states no fact at all"
  echo "    function owner() external view returns (address);"
  echo "}"
} > "$CACHE_DIR/repo/github.com/example-org/ext-lib@default/src/IExtRate.sol"
{
  echo "// synthetic file OUTSIDE both roots — it DOES state the fact, and must still never be opened"
  echo "// the value is scaled by 1e18"
} > "$OUTSIDE/Elsewhere.sol"

CACHE_SRC="$CACHE_DIR/repo/github.com/example-org/ext-lib@default/src/IExtRate.sol"

_cell_log() {
  _cl_name="$1"; shift
  _cl_path="$WORK/$_cl_name.log"
  : > "$_cl_path"
  for _cl_line in "$@"; do printf '%s\n' "$_cl_line" >> "$_cl_path"; done
  printf '%s\n' "$_cl_path"
}
# _assert_uncited <label> <log> <expected-uncited-ids, space separated or ""> [repo] [cache]
_assert_uncited() {
  _au_label="$1"; _au_log="$2"; _au_want="$3"; _au_repo="${4:-}"; _au_cache="${5:-}"
  _au_got="$(_uncited_check_ids "$_au_log" "$_au_repo" "$_au_cache" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  _au_want="$(printf '%s' "$_au_want" | sed 's/[[:space:]]*$//')"
  if [ "$_au_got" = "$_au_want" ]; then
    ok "$_au_label: uncited check ids = [${_au_got:-none}] (as specified)"
  else
    bad "$_au_label: uncited check ids = [${_au_got:-none}], want [${_au_want:-none}]"
  fi
}

if [ "$GATE_LOADED" -eq 1 ]; then
  note "14) a cache citation whose cited lines STATE the fact is accepted ..."
  ACC_LOG="$(_cell_log ext-accepted \
    'OPERATIONALIZE|vault|C2|on' \
    'EXTERNAL-RESOLVE|vault|C2|on' \
    'OPCHECK|#1|the external rate read|the returned value must carry the unit this zone assumes' \
    "TRACE|#1|CLEAN|EXTERNAL-CITED $CACHE_SRC:3 — the upstream source states the value is scaled by 1e18" \
    'SAFE')"
  _assert_uncited "a resolved cache citation that states the fact" "$ACC_LOG" "" "$REPO_DIR" "$CACHE_DIR"

  note "15) the SAME file, cited on a range that states nothing, is uncited ..."
  NOFACT_LOG="$(_cell_log ext-nofact \
    'OPERATIONALIZE|vault|C2|on' \
    'EXTERNAL-RESOLVE|vault|C2|on' \
    'OPCHECK|#1|the external rate read|the returned value must carry the unit this zone assumes' \
    "TRACE|#1|CLEAN|EXTERNAL-CITED $CACHE_SRC:5-6 — the upstream source is documented" \
    'SAFE')"
  _assert_uncited "the same cache file cited on a factless range" "$NOFACT_LOG" "1" "$REPO_DIR" "$CACHE_DIR"

  note "16) a cache path that does not exist is uncited (a fabricated citation is not a citation) ..."
  MISSING_LOG="$(_cell_log ext-missing \
    'OPERATIONALIZE|vault|C2|on' \
    'EXTERNAL-RESOLVE|vault|C2|on' \
    'OPCHECK|#1|the external rate read|the returned value must carry the unit this zone assumes' \
    "TRACE|#1|CLEAN|EXTERNAL-CITED $CACHE_DIR/repo/github.com/example-org/ext-lib@default/src/Invented.sol:12 — it is scaled by 1e18" \
    'SAFE')"
  _assert_uncited "a cache path that does not exist" "$MISSING_LOG" "1" "$REPO_DIR" "$CACHE_DIR"

  note "17) a path under NEITHER root is uncited — even when the file there DOES state the fact ..."
  OUTSIDE_LOG="$(_cell_log ext-outside \
    'OPERATIONALIZE|vault|C2|on' \
    'EXTERNAL-RESOLVE|vault|C2|on' \
    'OPCHECK|#1|the external rate read|the returned value must carry the unit this zone assumes' \
    "TRACE|#1|CLEAN|EXTERNAL-CITED $OUTSIDE/Elsewhere.sol:2 — the value is scaled by 1e18" \
    'SAFE')"
  _assert_uncited "a citation outside the repo and the cache" "$OUTSIDE_LOG" "1" "$REPO_DIR" "$CACHE_DIR"
  # The fixture itself proves the check is about the ROOT and not about the content: the file exists and its
  # cited line matches the fact regex, so an implementation that opened it would have accepted the citation.
  if sed -n '2p' "$OUTSIDE/Elsewhere.sol" | grep -q '1e18'; then
    ok "the outside file really does state the fact — so the refusal is the ROOT rule, not a content accident"
  else
    bad "the outside fixture no longer states the fact — assertion 17 would pass for the wrong reason"
  fi

  note "18) a relative path with .. cannot walk out of a root ..."
  TRAVERSE_LOG="$(_cell_log ext-traverse \
    'OPERATIONALIZE|vault|C2|on' \
    'EXTERNAL-RESOLVE|vault|C2|on' \
    'OPCHECK|#1|the external rate read|the returned value must carry the unit this zone assumes' \
    "TRACE|#1|CLEAN|EXTERNAL-CITED $CACHE_DIR/../outside/Elsewhere.sol:2 — it is scaled by 1e18" \
    'SAFE')"
  _assert_uncited "a cache-prefixed path containing .." "$TRAVERSE_LOG" "1" "$REPO_DIR" "$CACHE_DIR"

  note "19) a repo-relative EXTERNAL-CITED citation still works (the repo is the other root) ..."
  REPO_LOG="$(_cell_log ext-repo \
    'OPERATIONALIZE|vault|C2|on' \
    'EXTERNAL-RESOLVE|vault|C2|on' \
    'OPCHECK|#1|the external rate read|the returned value must carry the unit this zone assumes' \
    'TRACE|#1|CLEAN|EXTERNAL-CITED src/Consumer.sol:3 — the vendored view states the value is scaled by 1e18' \
    'SAFE')"
  _assert_uncited "a repo-relative citation that states the fact" "$REPO_LOG" "" "$REPO_DIR" "$CACHE_DIR"

  note "20) #2227 is unchanged: the config and external branches behave exactly as before ..."
  CFG_OK_LOG="$(_cell_log cfg-ok \
    'OPERATIONALIZE|vault|C23|on' \
    'OPCHECK|#1|the flag-vs-source pairing|the configured pair must agree on the referent' \
    'TRACE|#1|CLEAN|src/Consumer.sol:3 configures the matching pair, so the deploy-time choice is validated' \
    'SAFE')"
  _assert_uncited "a config-grounds dismissal citing a src/ path (names the flag, not what is shipped)" \
    "$CFG_OK_LOG" "1" "$REPO_DIR" "$CACHE_DIR"
  EXT_BARE_LOG="$(_cell_log ext-bare \
    'OPERATIONALIZE|vault|C2|on' \
    'OPCHECK|#1|the external rate read|the returned value must carry the unit this zone assumes' \
    'TRACE|#1|CLEAN|the call always returns a normalised ratio by construction, a documented invariant' \
    'SAFE')"
  _assert_uncited "an external-fact CLEAN with no citation at all" "$EXT_BARE_LOG" "1" "$REPO_DIR" "$CACHE_DIR"
  # And with NO cache root the two branches answer identically — an OFF run is byte-for-byte the pre-#2235 gate.
  _assert_uncited "the same two with no cache root (an --external-resolve-OFF run)" "$EXT_BARE_LOG" "1" "$REPO_DIR"

  note "21) #2230 per-check semantics: one bad citation marks ONE check, not the cell ..."
  MIXED_LOG="$(_cell_log ext-mixed \
    'OPERATIONALIZE|vault|C2|on' \
    'EXTERNAL-RESOLVE|vault|C2|on' \
    'OPCHECK|#1|the external rate read|the returned value must carry the unit this zone assumes' \
    'OPCHECK|#2|the fee cut|it is taken once per round trip' \
    'OPCHECK|#3|the decimals conversion|both legs use the same scale' \
    "TRACE|#1|CLEAN|EXTERNAL-CITED $CACHE_SRC:3 — the upstream source states the value is scaled by 1e18" \
    "TRACE|#2|CLEAN|EXTERNAL-CITED $CACHE_DIR/repo/github.com/example-org/ext-lib@default/src/Invented.sol:9 — it is scaled by 1e18" \
    'TRACE|#3|UNRESOLVED|the conversion depends on a value this payload does not settle' \
    'SAFE')"
  _assert_uncited "one accepted, one fabricated, one honest UNRESOLVED" "$MIXED_LOG" "2" "$REPO_DIR" "$CACHE_DIR"
  MIXED_GAP="$(_opcheck_trace_gap "$MIXED_LOG" "$REPO_DIR" "$CACHE_DIR")"
  if [ "$MIXED_GAP" = "1" ]; then
    ok "the shortfall is 1 — the cell is not failed wholesale for one bad citation"
  else
    bad "the shortfall is $MIXED_GAP (want 1): a bad citation must mark its own check only"
  fi

  note "22) with no roots at all the branch keeps the documented shape-only behaviour ..."
  _assert_uncited "an EXTERNAL-CITED line judged with neither repo_dir nor cache_dir" "$ACC_LOG" ""
  _assert_uncited "a well-shaped but fabricated citation, judged with no roots" "$MISSING_LOG" ""
else
  skip "14-22) gate fixtures — the shipped functions could not be sliced"
fi

# ==========================================================================================================
# PART 3 — LIVE UNDER MOCK
# ==========================================================================================================
# _arm <label> <extra flag...>: stage a one-contract repo + scope + brief, run ONE hunt cell through
# run-discovery.sh on the MOCK backend, print the out dir.
_arm() {
  _label="$1"; shift
  _repo="$WORK/$_label-repo"; mkdir -p "$_repo/contracts"
  {
    echo "// SPDX-License-Identifier: MIT"
    echo "pragma solidity ^0.8.20;"
    echo "interface IExternalRate { function rate(address s) external view returns (uint256); }"
    echo "contract RateConsumer {"
    echo "    IExternalRate public source;"
    echo "    function priceOf(address a) external view returns (uint256) { return source.rate(a); }"
    echo "}"
  } > "$_repo/contracts/RateConsumer.sol"
  printf 'vault | C2 | contracts/RateConsumer.sol\n' > "$WORK/$_label-scope.tsv"
  printf '# brief\nInvariants to break: the consumer and the source agree on the unit.\nKnown issues to exclude: none.\n' \
    > "$WORK/$_label-brief.md"
  DF_EXTERNAL_CACHE="$WORK/$_label-cache" "$DISCOVERY" --repo "$_repo" --scope "$WORK/$_label-scope.tsv" \
    --brief "$WORK/$_label-brief.md" --only "vault" --classes C2 --backend mock --agentis agentis \
    --out "$WORK/$_label" "$@" > "$WORK/$_label.out" 2>&1 || true
  printf '%s\n' "$WORK/$_label"
}

if ! command -v agentis >/dev/null 2>&1; then
  note "23-25) live-under-mock arms + the byte-identity probe ..."
  skip "no agentis binary on PATH — the mock hunt cells and the extracted-helper probe cannot run"
else
  note "23) live-under-mock ON: the sentinel fires end-to-end and the resolver is in the cell dir ..."
  ON_OUT="$(_arm mock-on --external-resolve)"
  ON_LOG="$ON_OUT/run/hunt_vault_C2.log"
  if [ ! -f "$ON_LOG" ]; then
    bad "the ON mock cell produced no log (run-discovery.sh did not reach hunter.ag)"
    tail -5 "$WORK/mock-on.out" 2>/dev/null | sed 's/^/      /' >&2
  else
    if grep -q '^EXTERNAL-RESOLVE|vault|C2|on$' "$ON_LOG"; then
      ok "--external-resolve: the sentinel fired (run-discovery.sh -> env_passthrough -> hunter.ag getenv)"
    else
      bad "--external-resolve: NO EXTERNAL-RESOLVE| sentinel — the knob did not reach hunter.ag (env_passthrough gap?)"
    fi
    if [ -f "$ON_OUT/run/resolve-external.sh" ]; then
      ok "resolve-external.sh was copied into the run dir the sandbox binds"
    else
      bad "no resolve-external.sh under the run dir — the cell could not invoke it inside the sandbox"
    fi
    if [ -d "$ON_OUT/run/external-budget" ]; then
      ok "the per-cell budget dir exists (the bound is enforced in a file, not in the prompt)"
    else
      bad "no external-budget dir under the run dir"
    fi
  fi

  note "24) live-under-mock OFF (the default): no sentinel, no resolver, same JSON key set ..."
  OFF_OUT="$(_arm mock-off)"
  OFF_LOG="$OFF_OUT/run/hunt_vault_C2.log"
  if [ ! -f "$OFF_LOG" ]; then
    bad "the OFF mock cell produced no log"
  else
    if grep -q 'EXTERNAL-RESOLVE|' "$OFF_LOG"; then
      bad "default run: an EXTERNAL-RESOLVE| sentinel appeared — the verb is NOT default-OFF"
    else
      ok "default run: no sentinel — the directive is opt-in and the prompt is unchanged"
    fi
    if [ -e "$OFF_OUT/run/resolve-external.sh" ]; then
      bad "default run: resolve-external.sh was copied anyway"
    else
      ok "default run: no resolver anywhere under the run dir"
    fi
    ON_KEYS="$(head -1 "$ON_OUT/run/results-cells.jsonl" 2>/dev/null | grep -oE '"[a-z_0-9]+":' | LC_ALL=C sort -u | tr '\n' ' ')"
    OFF_KEYS="$(head -1 "$OFF_OUT/run/results-cells.jsonl" 2>/dev/null | grep -oE '"[a-z_0-9]+":' | LC_ALL=C sort -u | tr '\n' ' ')"
    if [ -n "$OFF_KEYS" ] && [ "$ON_KEYS" = "$OFF_KEYS" ]; then
      ok "the per-cell JSON key set is identical in both arms (the feature adds no field)"
    else
      bad "the per-cell JSON key set differs: ON=[$ON_KEYS] OFF=[$OFF_KEYS]"
    fi
  fi

  note "25) byte-identity probe: the directive is EXACTLY 0 bytes with EXTERNAL_RESOLVER unset ..."
  FRAG="$WORK/ext.frag"; : > "$FRAG"
  FRAG_MISS=""
  for fn in $EXT_FNS; do
    awk -v want="^fn $fn\\\\(" '$0 ~ want {f=1} f{print} f&&/^}$/{exit}' "$HUNTER" >> "$FRAG"
    printf '\n' >> "$FRAG"
    grep -q "^fn $fn(" "$FRAG" || FRAG_MISS="$FRAG_MISS $fn"
  done
  if [ -n "$FRAG_MISS" ]; then
    bad "could not extract the #2235 helpers from hunter.ag by name (renamed?):$FRAG_MISS"
  else
    SB="$WORK/probe"; mkdir -p "$SB"
    ( cd "$SB" && agentis init >/dev/null 2>&1 ) || true
    printf 'exec.env_passthrough = EXTERNAL_RESOLVER,EXTERNAL_CACHE,EXTERNAL_BUDGET_STATE,EXTERNAL_BUDGET,TARGET_DIR,OPERATIONALIZE_LENS\n' \
      > "$SB/.agentis/config"
    {
      printf 'cb 300000;\n\n'
      cat "$FRAG"
      printf 'print("DIRLEN=" + to_string(len(external_resolve_directive())));\n'
    } > "$SB/probe.ag"
    _dirlen() { # $1=EXTERNAL_RESOLVER ("" = unset) ; $2=OPERATIONALIZE_LENS ("" = unset)
      if [ -n "$1" ]; then
        _dl="$( cd "$SB" && EXTERNAL_RESOLVER="$1" EXTERNAL_CACHE="$WORK/cache" EXTERNAL_BUDGET_STATE="$WORK/b" \
                EXTERNAL_BUDGET=5 TARGET_DIR="$WORK/repo" OPERATIONALIZE_LENS="${2:-}" \
                agentis go probe.ag 2>&1 | grep '^DIRLEN=' | tail -1 )"  # no-pii: length-only probe, no prompt()
      else
        _dl="$( cd "$SB" && OPERATIONALIZE_LENS="${2:-}" agentis go probe.ag 2>&1 | grep '^DIRLEN=' | tail -1 )"  # no-pii: length-only probe, no prompt()
      fi
      printf '%s\n' "${_dl#DIRLEN=}"
    }
    D_OFF="$(_dirlen "")"
    D_ON="$(_dirlen "/run/resolve-external.sh")"
    D_OFF_LENS="$(_dirlen "" "1")"
    D_ON_NOLENS="$(_dirlen "/run/resolve-external.sh" "")"
    case "$D_OFF" in
      0) ok "EXTERNAL_RESOLVER unset: the directive is \"\" (0 bytes) — the default prompt is byte-identical" ;;
      ''|*[!0-9]*) bad "the probe did not complete with the env unset (got '$D_OFF')" ;;
      *) bad "EXTERNAL_RESOLVER unset: the directive is $D_OFF bytes — the default is NOT byte-identical" ;;
    esac
    case "$D_ON" in
      ''|*[!0-9]*) bad "the probe did not complete with EXTERNAL_RESOLVER set (got '$D_ON')" ;;
      0) bad "EXTERNAL_RESOLVER set: the directive is still empty — the verb could never reach a prompt" ;;
      *) ok "EXTERNAL_RESOLVER set: the directive is $D_ON bytes (the opt-in really injects it)" ;;
    esac
    if [ "$D_OFF_LENS" = "0" ]; then
      ok "OPERATIONALIZE_LENS=1 alone does NOT inject the verb (the two knobs are independent, both ways)"
    else
      bad "the #2211 lens turned the resolver directive on by itself ($D_OFF_LENS bytes)"
    fi
    if [ "$D_ON_NOLENS" = "$D_ON" ] && [ "$D_ON" != "0" ]; then
      ok "with the lens UNSET the verb is still injected in full — STOP-1 decision 2 holds in the code"
    else
      bad "the verb shrank with the lens unset ($D_ON_NOLENS vs $D_ON) — it is lens-gated after all"
    fi
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: a discovery cell can be handed the external-protocol resolver (opt-in, default OFF), and every"
  note "      EXTERNAL-CITED citation is RE-OPENED by the harness from the audited repo or the resolver cache"
  note "      — never from the network — with the cited lines required to state the fact. A citation outside"
  note "      those two roots, to a file that does not exist, or to a range that states nothing marks THAT"
  note "      check uncited and nothing else. With the knob off: no directive bytes, no resolver copy, no"
  note "      extra sandbox bind, no new JSON field. Whether the model USES the verb is not proven here."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
