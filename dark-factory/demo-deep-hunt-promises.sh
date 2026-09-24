#!/usr/bin/env bash
# demo-deep-hunt-promises.sh — proof of #2245 (iteration 7) DEEP-HUNT PROMISES: invariants derived from the target's
# user-facing promises, ADDED next to the lens invariant — knob DEEP_HUNT_PROMISES=1 (requires DEEP_HUNT_REACH=1),
# default OFF.
#
# The knob threads: run-zone-hunt.sh (DEEP_HUNT_PROMISES env) -> run-invariant-hunt.sh --promises (writes the
# lib/inheritance.py promise-sources listing to $RUN/promise-sources.txt, stages evm-harness/promise-gate.py)
# -> invariant-prover.ag promisesOn = len(promise-sources.txt) > 0 -> ONE extraction prompt -> promise-gate.py
# gate (citation floor, cap 8) -> one asserting `invariant_p<k>_` per accepted promise (one re-ask on a gap) ->
# LOW_PROMISE_COVERAGE on an uncovered CLEAN. With the knob unset every one of those is inert.
#
# STOP-1 decision 4 (issue #2245): the model lists promises FREE-FORM; NO kind vocabulary appears in any prompt.
# promise-gate.py assigns a kind afterwards for reporting only, and PART 6 pins that the rendered extraction
# prompt, the promise seed and the promise re-ask carry none of the kind words.
#
# PARTS (CI floor = python3 only; agentis/forge parts SKIP cleanly when the tool is absent):
#   1  SOURCE GUARDS: the wiring is present in the shipped shell + .ag (mutation-checkable greps).
#   2  promise-sources: order (target, contracts, interfaces, docs), real line numbers, doc windows, the 160 KB
#      cut, the inert unresolvable target.
#   3  gate: accepted citations, one fixture per drop id, subject normalisation, reporting-only kind, the cap,
#      FCB sentinels, output sanitising, empty/missing input.
#   4  coverage: asserting body, anchoring, --prefix, n/a, missing harness, the verbatim UNCOVERED block.
#   5  END-TO-END OFFLINE via run-zone-hunt.sh --deep-hunt --deep-hunt-only + a stub --agentis: OFF byte-identical
#      to REACH-only, ON reaches the prover through the absolute rundir, LOW_PROMISE_COVERAGE kept + terminal on
#      resume, guard exits.
#   6  (needs agentis) the SHIPPED helpers sliced from the .ag, and the rendered prompts carry no kind vocabulary.
#   7  (needs agentis) the real prover under --backend mock: exactly one extra prompt per promise path.
#   8  (needs agentis + forge) both fixture bugs are caught by their promise invariants; an uncovered promise
#      turns a CLEAN into LOW_PROMISE_COVERAGE.
#   9  PURITY: no contest / [HM]-<n> / domain nouns / kind words in the promise templates; no embedded interpreter.
#  10  MUTATIONS: every gate / coverage / ordering rule is load-bearing.
#
# Usage: dark-factory/demo-deep-hunt-promises.sh
# Exit: 0 = all assertions hold; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INH="$HERE/lib/inheritance.py"
PG="$HERE/evm-harness/promise-gate.py"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
RZH="$HERE/run-zone-hunt.sh"
RIH="$HERE/run-invariant-hunt.sh"
RDISC="$HERE/run-discovery.sh"

FAILS=0
note() { echo "demo-deep-hunt-promises.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Isolate the host-wide forge slot pool (lib/forge-slot.sh) so a stale slot elsewhere never stalls this demo.
export DARK_FACTORY_DIR="$WORK/dfdir"
mkdir -p "$DARK_FACTORY_DIR"

# The kind vocabulary that must never reach a prompt (STOP-1 decision 4), matched as whole words, any case.
KIND_WORDS_RE='(^|[^A-Za-z0-9_-])(time-?locks?|ordering|rounding|per-user-conservation|bound|access)([^A-Za-z0-9_-]|$)'

# extract_fn NAME FILE — slice a single `fn NAME(...) { ... }` block out of a shipped .ag by brace-matching,
# so PART 6 exercises the SHIPPED functions verbatim (never a hand-copy).
extract_fn() {
  awk -v fn="$1" '
    BEGIN { want = "fn " fn "("; depth = 0; on = 0 }
    {
      if (!on && index($0, want) > 0) { on = 1 }
      if (on) {
        print
        n = gsub(/{/, "{"); m = gsub(/}/, "}")
        depth += n - m
        if (depth <= 0 && seen) { exit }
        if (index($0, "{") > 0) seen = 1
      }
    }
  ' "$2"
}

# ================================================================================================
note "1) SOURCE GUARDS: the DEEP_HUNT_PROMISES wiring is present in the shipped files ..."

if grep -q 'DEEP_HUNT_PROMISES="\${DEEP_HUNT_PROMISES:-}"' "$RZH" \
   && grep -q 'DEEP_HUNT_PROMISES must be unset, 0 or 1' "$RZH" \
   && grep -q 'DEEP_HUNT_PROMISES=1 requires DEEP_HUNT_REACH=1' "$RZH" \
   && grep -q 'set -- "\$@" --promises' "$RZH"; then
  ok "run-zone-hunt.sh parses + validates DEEP_HUNT_PROMISES and threads --promises into \$INVHUNT"
else
  bad "run-zone-hunt.sh is missing the DEEP_HUNT_PROMISES knob / validation / threading"
fi

if grep -q -- '--promises) PROMISES=1' "$RIH" && grep -q -- '--promise-fixture) need' "$RIH" \
   && grep -q -- '--promises requires --reach' "$RIH" && grep -q -- '--promise-fixture requires --promises' "$RIH"; then
  ok "run-invariant-hunt.sh parses --promises / --promise-fixture and enforces the --reach / --promises rules"
else
  bad "run-invariant-hunt.sh flag parsing / validation for --promises is missing"
fi

if awk '/^if \[ "\$PROMISES" = "1" \]; then/{f=1} f && /promise-sources --repo "\$REPO_IN_RUN"/{print "found"; exit}' "$RIH" | grep -q found \
   && awk '/^if \[ "\$PROMISES" = "1" \]; then/{f=1} f && /cp "\$HERE\/evm-harness\/promise-gate.py" "\$RUN\/promise-gate.py"/{print "found"; exit}' "$RIH" | grep -q found; then
  ok "the listing write + promise-gate.py staging are nested under the --promises guard (inert when off)"
else
  bad "the promise staging is NOT guarded by --promises"
fi

if grep -q 'let promisesOn = len(promiseSources) > 0;' "$PROVER" \
   && grep -q 'read_reach_file(reachDir + "/promise-sources.txt")' "$PROVER" \
   && ! grep -qE 'getenv\("(DEEP_HUNT_)?PROMISE' "$PROVER"; then
  ok "invariant-prover.ag derives promisesOn from the absolute-rundir promise-sources.txt (no getenv)"
else
  bad "invariant-prover.ag promisesOn is not file-derived"
fi

if git -C "$HERE" cat-file -e origin/main:dark-factory/run-invariant-hunt.sh 2>/dev/null; then
  PT_ORIG="$(git -C "$HERE" show origin/main:dark-factory/run-invariant-hunt.sh | grep '^  echo "exec.env_passthrough = ' || true)"
  PT_NOW="$(grep '^  echo "exec.env_passthrough = ' "$RIH" || true)"
  if [ -n "$PT_ORIG" ] && [ "$PT_ORIG" = "$PT_NOW" ]; then
    ok "run-invariant-hunt.sh exec.env_passthrough line is byte-identical to origin/main (no new PROMISES entry)"
  else
    bad "run-invariant-hunt.sh exec.env_passthrough line changed (PROMISES must not add a passthrough entry)"
  fi
else
  skip "origin/main not fetched — cannot diff the exec.env_passthrough line"
fi

# promiseSeed in generation, repair and BOTH re-asks.
GEN_BLOCK="$(awk '/^fn generate_test\(/{f=1} f{print} f && /^}/{exit}' "$PROVER")"
if printf '%s\n' "$GEN_BLOCK" | grep -A1 -- '+ reachSeed' | grep -q -- '+ promiseSeed' \
   && grep -q 'requiredNames, sharedScaffold + symbolInventorySeed + reachSeed + promiseSeed);' "$PROVER" \
   && grep -q '^let reachSrc = if reaskFired { coverage_reask(cov_uncovered(covDraft), test, sharedScaffold + symbolInventorySeed + reachSeed + promiseSeed) }' "$PROVER" \
   && grep -q '^let firstSrc = if promReaskFired { promise_reask(pcov_uncovered_block(promDraft), reachSrc, sharedScaffold + symbolInventorySeed + reachSeed + promiseSeed) }' "$PROVER"; then
  ok "promiseSeed is spliced into generation, the repair chain, the REACH re-ask AND the promise re-ask"
else
  bad "a promiseSeed splice (generation / repair / re-ask) is missing"
fi

if grep -q '^let promReaskFired = if promisesOn { if usedFixture { false } else { pcov_gap(promDraft) > 0 } } else { false };' "$PROVER"; then
  ok "the promise re-ask is nested under promisesOn AND not-a-fixture"
else
  bad "the promise re-ask gating is wrong"
fi

EXTRACT_BLOCK="$(extract_fn extract_promises "$PROVER")"
if printf '%s\n' "$EXTRACT_BLOCK" | grep -q 'if handlerFixture { return ""; }' \
   && grep -q '^let promiseRaw = extract_promises(promisesOn, promiseFixture, len(fixture) > 0, promiseSources);' "$PROVER"; then
  ok "the extraction is skipped on the HANDLER_FIXTURE path (fixture first, then no LLM)"
else
  bad "the extraction does not skip the HANDLER_FIXTURE path"
fi

if grep -q 'print("INVARIANT|" + targetFn + "|" + verdict);' "$PROVER" \
   && grep -q '^let wrote = write_test(firstSrc, invOut);' "$PROVER" \
   && grep -q '^let firstStop = stop_flag_both(rc_of(firstOut), firstSrc, composableFresh, requiredNames);' "$PROVER" \
   && grep -q '^let initState = rstate(initStopped, firstSrc, firstOut);' "$PROVER"; then
  ok "the pinned INVARIANT| marker and the three pinned firstSrc lines are unchanged"
else
  bad "the pinned marker or a pinned firstSrc line changed"
fi

if grep -E 'print\("PROMISE' "$PROVER" | grep -q 'INVARIANT|'; then
  bad "a PROMISE* readout print line carries an INVARIANT| substring"
else
  ok "no PROMISE* readout line carries an INVARIANT| substring"
fi
if grep -q 'if verdict == "LOW_PROMISE_COVERAGE" { return "partial"; }' "$PROVER"; then
  ok "outcome_of maps LOW_PROMISE_COVERAGE -> partial"
else
  bad "outcome_of does not map LOW_PROMISE_COVERAGE"
fi

# The three citation regex literals are byte-identical to run-discovery.sh _param_bound_ok's pb_* literals.
RE_ALL_EQ=1
for pair in "pb_pathline_re:PB_PATHLINE_RE" "pb_deploy_re:PB_DEPLOY_RE" "pb_admit_re:PB_ADMIT_RE"; do
  shv="${pair%%:*}"; pyv="${pair##*:}"
  SH_LIT="$(grep -E "^  ${shv}='" "$RDISC" | head -1 | sed -E "s/^  ${shv}='(.*)'\$/\\1/")"
  PY_LIT="$(grep -E "^${pyv} = r'" "$PG" | head -1 | sed -E "s/^${pyv} = r'(.*)'\$/\\1/")"
  if [ -z "$SH_LIT" ] || [ "$SH_LIT" != "$PY_LIT" ]; then RE_ALL_EQ=0; echo "      $shv: [$SH_LIT] vs [$PY_LIT]" >&2; fi
done
if [ "$RE_ALL_EQ" = 1 ]; then
  ok "promise-gate.py's path / deploy / deployed-state regexes are byte-identical to run-discovery.sh's pb_* literals"
else
  bad "a promise-gate.py citation regex drifted from run-discovery.sh _param_bound_ok"
fi

# ================================================================================================
note "2) promise-sources (inheritance.py): order, real line numbers, doc windows, the 160 KB cut ..."

PREPO="$WORK/prepo"
mkdir -p "$PREPO/src/fx" "$PREPO/lib/fxv" "$PREPO/script" "$PREPO/mocks" "$PREPO/docs" "$PREPO/test"
printf '[profile.default]\nsrc = "src"\ntest = "test"\n[invariant]\nruns = 32\ndepth = 16\n' > "$PREPO/foundry.toml"

cat > "$PREPO/lib/fxv/FxVendorHook.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/// @notice FxVendorHook is vendored code; it must never be listed or cited.
abstract contract FxVendorHook {
    function _afterMove(address from) internal virtual {}
}
SOL
cat > "$PREPO/src/fx/IFxHold.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
interface IFxHold {
    /// @notice The time before which units received by `account` stay with that account.
    function heldUntil(address account) external view returns (uint256);
}
SOL
cat > "$PREPO/src/fx/FxHoldBase.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IFxHold} from "./IFxHold.sol";
import {FxVendorHook} from "../../lib/fxv/FxVendorHook.sol";
abstract contract FxHoldBase is IFxHold, FxVendorHook {
    /// @notice Seconds a fresh issue stays with the receiving account.
    uint256 public holdPeriod = 1 days;
    /// @notice Per-account time before which units received by the account cannot leave it.
    mapping(address => uint256) public heldUntil;

    /// @dev Units received by `account` cannot leave it before heldUntil[account].
    function _checkHold(address account) internal view {
        require(block.timestamp >= heldUntil[account], "held");
    }
}
SOL
cat > "$PREPO/src/fx/FxHoldToken.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {FxHoldBase} from "./FxHoldBase.sol";
contract FxHoldToken is FxHoldBase {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Issues `amt` to `to`; the units stay with `to` until heldUntil[to].
    function issue(address to, uint256 amt) external {
        balanceOf[to] += amt;
        heldUntil[to] = block.timestamp + holdPeriod;
    }

    function approve(address spender, uint256 amt) external {
        allowance[msg.sender][spender] = amt;
    }

    function transfer(address to, uint256 amt) external {
        _checkHold(msg.sender);
        _move(msg.sender, to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) external {
        require(allowance[from][msg.sender] >= amt, "allowance");
        allowance[from][msg.sender] -= amt;
        _move(from, to, amt);
    }

    function _move(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        _afterMove(from);
    }
}
SOL
cat > "$PREPO/src/fx/FxDebtDesk.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract FxDebtDesk {
    mapping(address => uint256) public wallet;
    mapping(address => uint256) public debt;

    function open(uint256 amt) external {
        debt[msg.sender] += amt;
        wallet[msg.sender] += amt;
    }

    function fund(uint256 amt) external {
        wallet[msg.sender] += amt;
    }

    /// @notice A payment toward `account` never takes more than the account's outstanding debt.
    function repay(address account, uint256 amt) external {
        require(wallet[msg.sender] >= amt, "funds");
        wallet[msg.sender] -= amt;
        if (debt[account] >= amt) {
            debt[account] -= amt;
        } else {
            debt[account] = 0;
        }
    }

    /// @notice Clears the whole debt of `account`, paid by the caller.
    function liquidate(address account) external {
        uint256 d = debt[account];
        require(wallet[msg.sender] >= d, "funds");
        wallet[msg.sender] -= d;
        debt[account] = 0;
    }
}
SOL
cat > "$PREPO/src/fx/FxTally.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract FxTally {
    /// @notice Per-account tally; `take` never moves an account's tally below zero.
    mapping(address => uint256) public tally;

    function add(uint256 amt) external {
        tally[msg.sender] += amt;
    }

    /// @notice `take` only removes what the caller added.
    function take(uint256 amt) external {
        require(tally[msg.sender] >= amt, "tally");
        tally[msg.sender] -= amt;
    }
}
SOL
cat > "$PREPO/script/FxDeploy.s.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// deploys FxDebtDesk and calls repay once
SOL
cat > "$PREPO/mocks/FxNoteMock.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract FxNoteMock { function repay() external {} }
SOL
# Docs: README names the target 3x (and is >= 45 lines for the width fixture), fx-notes 2x, extra 1x, other 0x,
# test/README (excluded dir) 5x. Only README + fx-notes may be listed (cap 2, ranked by mention count).
{
  echo "# Fixture project"
  echo
  echo "FxHoldToken keeps issued units with the receiver for a while. FxHoldToken is the main contract."
  i=0; while [ "$i" -lt 50 ]; do echo "Fixture note line $i."; i=$((i + 1)); done
  echo "See FxHoldToken for the details."
} > "$PREPO/README.md"
printf '# Notes\n\nFxHoldToken notes. FxHoldToken again.\n' > "$PREPO/docs/fx-notes.md"
printf '# Extra\n\nOne FxHoldToken mention.\n' > "$PREPO/docs/extra.md"
printf '# Other\n\nNothing about the target.\n' > "$PREPO/docs/other.md"
printf 'FxHoldToken FxHoldToken FxHoldToken FxHoldToken FxHoldToken\n' > "$PREPO/test/README.md"

# Fixture contract names must not coincide with any held-out / dev corpus contract.
FX_NAMES="FxHoldToken FxHoldBase IFxHold FxDebtDesk FxTally FxVendorHook FxNoteMock"
CORPUS_HIT=""
for nm in $FX_NAMES; do
  if grep -rqw "$nm" "$HERE/bench/corpus-bench/runs" 2>/dev/null \
     || grep -qw "$nm" "$HERE"/bench/corpus-bench/*.tsv 2>/dev/null; then CORPUS_HIT="$CORPUS_HIT $nm"; fi
done
if [ -z "$CORPUS_HIT" ]; then
  ok "no fixture contract name appears as a word in the corpus-bench runs or TSVs"
else
  bad "fixture contract name(s) collide with the corpus:$CORPUS_HIT"
fi

LIST="$WORK/list-hold.txt"
python3 "$INH" promise-sources --repo "$PREPO" --target src/fx/FxHoldToken.sol:FxHoldToken --out "$LIST"; PS_RC=$?
HDRS="$(grep '^=== ' "$LIST" | tr '\n' ';')"
if [ "$PS_RC" -eq 0 ] && [ "$HDRS" = "=== src/fx/FxHoldToken.sol ===;=== src/fx/FxHoldBase.sol ===;=== src/fx/IFxHold.sol ===;=== README.md ===;=== docs/fx-notes.md ===;" ]; then
  ok "listing order: target, ancestor contract, ancestor interface, then the 2 top-ranked docs naming the target"
else
  bad "promise-sources listing order wrong (rc=$PS_RC): $HDRS"
fi
if ! grep -q '^=== lib/' "$LIST" && ! grep -q '^=== docs/extra.md' "$LIST" && ! grep -q '^=== docs/other.md' "$LIST" \
   && ! grep -q '^=== test/' "$LIST"; then
  ok "vendored lib/, a doc beyond the cap, a doc not naming the target and test/ docs are never listed"
else
  bad "promise-sources listed a vendored / over-cap / non-naming / test doc"
fi

# every `N| text` line of the target and base sections equals `sed -n Np` of that file.
LN_OK=1; LN_N=0
for f in src/fx/FxHoldToken.sol src/fx/FxHoldBase.sol; do
  while IFS= read -r l; do
    n="${l%%|*}"; t="${l#*| }"
    [ "$(sed -n "${n}p" "$PREPO/$f")" = "$t" ] || { LN_OK=0; echo "      mismatch $f:$n" >&2; }
    LN_N=$((LN_N + 1))
  done < <(awk -v h="=== $f ===" '$0==h{f=1; next} /^=== /{f=0} f' "$LIST")
done
if [ "$LN_OK" = 1 ] && [ "$LN_N" -gt 20 ]; then
  ok "all $LN_N rendered '<n>| <text>' lines equal 'sed -n <n>p' of their file (citations re-open exactly)"
else
  bad "rendered line numbers do not re-open the real lines ($LN_N checked)"
fi
if ! awk -v h="=== src/fx/FxHoldToken.sol ===" '$0==h{f=1; next} /^=== /{f=0} f' "$LIST" | grep -qE '^[0-9]+\| *$'; then
  ok "blank lines are skipped in the listing"
else
  bad "blank lines were rendered"
fi
if awk '/^=== README.md ===/{f=1; next} /^=== /{f=0} f' "$LIST" | head -1 | grep -q '^1| # Fixture project' \
   && [ "$(awk '/^=== README.md ===/{f=1; next} /^=== /{f=0} f' "$LIST" | tail -1 | cut -d'|' -f1)" -le 200 ]; then
  ok "the README doc window starts at most 20 lines above the first mention and spans <= 200 lines"
else
  bad "the README doc window is wrong"
fi

# the 160 KB cut: a ~105 KB target + a ~105 KB base contract + an interface. The cut must land inside the base
# (at a line boundary, with the marker as the LAST line) and the interface must never appear.
BIG="$WORK/bigrepo"; mkdir -p "$BIG/src"
printf '[profile.default]\nsrc = "src"\n' > "$BIG/foundry.toml"
{
  echo "pragma solidity ^0.8.20;"
  echo "interface IFxBigFace { function ping() external; }"
} > "$BIG/src/IFxBigFace.sol"
{
  echo "pragma solidity ^0.8.20;"
  echo 'import "./IFxBigFace.sol";'
  echo "abstract contract FxBigBase is IFxBigFace {"
  i=0; while [ "$i" -lt 1200 ]; do echo "    uint256 public baseSlot$i; // padding line for the listing cap check number $i"; i=$((i + 1)); done
  echo "}"
} > "$BIG/src/FxBigBase.sol"
{
  echo "pragma solidity ^0.8.20;"
  echo 'import "./FxBigBase.sol";'
  echo "contract FxBigLeaf is FxBigBase {"
  i=0; while [ "$i" -lt 1200 ]; do echo "    uint256 public leafSlot$i; // padding line for the listing cap check number $i"; i=$((i + 1)); done
  echo "    function ping() external {}"
  echo "}"
} > "$BIG/src/FxBigLeaf.sol"
BLIST="$WORK/list-big.txt"
python3 "$INH" promise-sources --repo "$BIG" --target src/FxBigLeaf.sol:FxBigLeaf --out "$BLIST"
B_SIZE="$(wc -c < "$BLIST" | tr -d ' ')"
if [ "$(tail -1 "$BLIST")" = "... [promise sources truncated at 160 KB] ..." ] \
   && [ "$B_SIZE" -le $((160 * 1024 + 64)) ] \
   && grep -q '^=== src/FxBigBase.sol ===' "$BLIST" && ! grep -q '^=== src/IFxBigFace.sol ===' "$BLIST" \
   && [ "$(grep -vcE '^(=== .* ===|[0-9]+\| .*|\.\.\. \[promise sources truncated at 160 KB\] \.\.\.)$' "$BLIST")" -eq 0 ]; then
  ok "the 160 KB cut lands at a line boundary with the marker last; the interface (after the contracts) is what is cut"
else
  bad "the 160 KB cut is wrong (size=$B_SIZE, last=[$(tail -1 "$BLIST")])"
fi

python3 "$INH" promise-sources --repo "$PREPO" --target src/fx/NoSuch.sol:NoSuch --out "$WORK/list-none.txt"; NONE_RC=$?
if [ "$NONE_RC" -eq 0 ] && [ -f "$WORK/list-none.txt" ] && [ ! -s "$WORK/list-none.txt" ]; then
  ok "an unresolvable target writes an EMPTY listing (exit 0) — promisesOn stays false"
else
  bad "an unresolvable target did not give an empty listing (rc=$NONE_RC)"
fi
python3 "$INH" promise-sources --repo "$PREPO" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "promise-sources without --target/--out is a usage error (exit 2)" || bad "promise-sources missing-flag exit is not 2"

# ================================================================================================
note "3) gate (promise-gate.py): citations, drop ids, normalisation, reporting-only kind, cap, sanitising ..."

HOLD_REQ="$(grep -n 'require(block.timestamp >= heldUntil' "$PREPO/src/fx/FxHoldBase.sol" | cut -d: -f1)"
DEBT_DOC="$(grep -n 'never takes more than' "$PREPO/src/fx/FxDebtDesk.sol" | cut -d: -f1)"
DEBT_FN="$(grep -n 'function repay(' "$PREPO/src/fx/FxDebtDesk.sol" | cut -d: -f1)"
VH_LN="$(grep -n 'abstract contract FxVendorHook' "$PREPO/lib/fxv/FxVendorHook.sol" | cut -d: -f1)"
RAW1="$WORK/raw1.txt"
cat > "$RAW1" <<EOF
PROMISE|#1|heldUntil|units issued to an account cannot leave it before its heldUntil time|src/fx/FxHoldBase.sol:$HOLD_REQ
PROMISE|#2|FxDebtDesk.repay()|a payment made after the debt was cleared never takes the payer's funds|src/fx/FxDebtDesk.sol:$DEBT_DOC-$DEBT_FN
PROMISE|#x|repay|a malformed id|src/fx/FxDebtDesk.sol:$DEBT_FN
PROMISE|#1|repay|a repeated id|src/fx/FxDebtDesk.sol:$DEBT_FN
PROMISE|#3|()|no identifier in the subject|src/fx/FxDebtDesk.sol:$DEBT_FN
PROMISE|#4|repay||src/fx/FxDebtDesk.sol:$DEBT_FN
PROMISE|#5|repay|no citation at all|see the code
PROMISE|#6|repay|an absolute path|/etc/fx/FxDebtDesk.sol:1
PROMISE|#7|repay|a parent segment|src/../src/fx/FxDebtDesk.sol:$DEBT_FN
PROMISE|#8|repay|a range outside the file|src/fx/FxDebtDesk.sol:9000
PROMISE|#9|repay|a deployment script|script/FxDeploy.s.sol:3
PROMISE|#10|FxVendorHook|vendored library code|lib/fxv/FxVendorHook.sol:$VH_LN
PROMISE|#11|FxHoldToken|a range longer than forty lines|README.md:1-45
PROMISE|#12|repay|a range naming something else|src/fx/FxHoldBase.sol:$HOLD_REQ
PROMISE|#13|repay|as deployed on mainnet a payment is small|src/fx/FxDebtDesk.sol:$DEBT_FN
PROMISE|#14|FxNoteMock|a staged mock|mocks/FxNoteMock.sol:3
not a promise line at all
EOF
G1="$(python3 "$PG" gate --raw "$RAW1" --repo "$PREPO" --out "$WORK/acc1.tsv")"; G1_RC=$?
if [ "$G1_RC" -eq 0 ] && printf '%s\n' "$G1" | grep -q '^PROMISES|emitted=16|accepted=2|dropped=14|overcap=0$'; then
  ok "gate counts: 16 PROMISE lines emitted (the prose line ignored), 2 accepted, 14 dropped"
else
  bad "gate counts wrong (rc=$G1_RC):"; printf '%s\n' "$G1" | head -3 | sed 's/^/      /' >&2
fi
if printf '%s\n' "$G1" | grep -q "^PROMISE-ACCEPTED|#1|heldUntil|time-lock|units issued to an account cannot leave it before its heldUntil time|src/fx/FxHoldBase.sol:$HOLD_REQ\$" \
   && printf '%s\n' "$G1" | grep -q "^PROMISE-ACCEPTED|#2|repay|ordering|a payment made after the debt was cleared never takes the payer's funds|src/fx/FxDebtDesk.sol:$DEBT_DOC-$DEBT_FN\$"; then
  ok "the require-line hold promise and the NatSpec+header ordering promise are ACCEPTED; 'FxDebtDesk.repay()' normalised to 'repay'"
else
  bad "the two cited promises were not accepted as expected:"; printf '%s\n' "$G1" | grep ACCEPTED | sed 's/^/      /' >&2
fi
EXPECT_DROPS="#x|bad-id #1|dup-id #3|bad-subject #4|no-statement #5|cite-missing #6|cite-unresolved #7|cite-unresolved #8|cite-unresolved #9|cite-deploy #10|cite-out-of-scope #11|cite-too-wide #12|cite-names-other #13|cite-deployed-state #14|cite-out-of-scope"
DROP_OK=1
for d in $EXPECT_DROPS; do
  printf '%s\n' "$G1" | grep -qxF "PROMISE-DROPPED|$d" || { DROP_OK=0; echo "      missing PROMISE-DROPPED|$d" >&2; }
done
[ "$DROP_OK" = 1 ] && ok "every drop id fires on its fixture (bad-id, dup-id, bad-subject, no-statement, 5x cite-*, deploy, out-of-scope x2, too-wide, names-other, deployed-state)" \
  || bad "a drop id did not fire on its fixture"
if [ "$(wc -l < "$WORK/acc1.tsv" | tr -d ' ')" = 2 ] && awk -F'\t' 'NF!=6{e=1} END{exit e}' "$WORK/acc1.tsv"; then
  ok "--out TSV: one 6-column row (k, subject, kind, kind_keyword, statement, cite) per accepted promise"
else
  bad "--out TSV shape wrong"; cat "$WORK/acc1.tsv" | sed 's/^/      /' >&2
fi
ACC_BLOCK="$(printf '%s\n' "$G1" | awk '/^BEGIN-ACCEPTED$/{f=1; next} /^END-ACCEPTED$/{f=0} f')"
if printf '%s\n' "$ACC_BLOCK" | grep -q "^#1 | heldUntil | units issued to an account cannot leave it before its heldUntil time | src/fx/FxHoldBase.sol:$HOLD_REQ\$" \
   && printf '%s\n' "$ACC_BLOCK" | grep -q '^    require(block.timestamp >= heldUntil\[account\], "held");$' \
   && ! printf '%s\n' "$ACC_BLOCK" | grep -qiE "$KIND_WORDS_RE"; then
  ok "the prompt-visible ACCEPTED block carries subject/statement/cite + the cited source lines and NO kind token"
else
  bad "the ACCEPTED block is wrong or carries a kind token:"; printf '%s\n' "$ACC_BLOCK" | sed 's/^/      /' >&2
fi

WALLET_LN="$(grep -n 'mapping(address => uint256) public wallet;' "$PREPO/src/fx/FxDebtDesk.sol" | cut -d: -f1)"
printf 'PROMISE|#1|wallet|the stored figure equals the sum of its parts|src/fx/FxDebtDesk.sol:%s\n' "$WALLET_LN" > "$WORK/raw-other.txt"
if python3 "$PG" gate --raw "$WORK/raw-other.txt" --repo "$PREPO" --out "$WORK/acc-other.tsv" | grep -q '^PROMISE-ACCEPTED|#1|wallet|other|'; then
  ok "a statement with no keyword gets the reporting-only kind 'other'"
else
  bad "the reporting-only kind fallback is not 'other'"
fi

# 10 cited promises -> 8 ACCEPTED + 2 OVERCAP (ascending #k; the cap stops gating).
RAW10="$WORK/raw10.txt"; : > "$RAW10"
k=10; while [ "$k" -ge 1 ]; do
  printf 'PROMISE|#%d|repay|payment rule number %d holds for every account|src/fx/FxDebtDesk.sol:%s\n' "$k" "$k" "$DEBT_FN" >> "$RAW10"
  k=$((k - 1))
done
G10="$(python3 "$PG" gate --raw "$RAW10" --repo "$PREPO" --out "$WORK/acc10.tsv")"
if printf '%s\n' "$G10" | grep -q '^PROMISES|emitted=10|accepted=8|dropped=0|overcap=2$' \
   && printf '%s\n' "$G10" | grep -qx 'PROMISE-OVERCAP|#9' && printf '%s\n' "$G10" | grep -qx 'PROMISE-OVERCAP|#10' \
   && [ "$(cut -f1 "$WORK/acc10.tsv" | tr '\n' ,)" = "1,2,3,4,5,6,7,8," ]; then
  ok "10 cited promises -> 8 ACCEPTED (#1..#8, ascending) + 2 OVERCAP (#9, #10)"
else
  bad "the cap of 8 is not enforced:"; printf '%s\n' "$G10" | head -1 | sed 's/^/      /' >&2
fi

# FCB sentinels stripped; a `|` / `INVARIANT|` inside a statement never reaches the output.
RAWF="$WORK/rawf.txt"
{
  echo "FCB_0a1b2c_BEGIN"
  echo "PROMISE|#1|repay|a payment INVARIANT|CLEAN never takes the funds twice|src/fx/FxDebtDesk.sol:$DEBT_FN FCB_0a1b2c_END"
} > "$RAWF"
GF="$(python3 "$PG" gate --raw "$RAWF" --repo "$PREPO" --out "$WORK/accf.tsv")"
if printf '%s\n' "$GF" | grep -q '^PROMISES|emitted=1|accepted=1|' && ! printf '%s\n' "$GF" | grep -q 'FCB_' \
   && ! printf '%s\n' "$GF" | grep -q 'INVARIANT|' && printf '%s\n' "$GF" | grep -q 'INVARIANT/CLEAN'; then
  ok "FCB result-file sentinels are stripped; an in-statement '|' is mapped to '/' so no output line carries INVARIANT|"
else
  bad "FCB stripping / output sanitising failed:"; printf '%s\n' "$GF" | sed 's/^/      /' >&2
fi

: > "$WORK/raw-empty.txt"
GE="$(python3 "$PG" gate --raw "$WORK/raw-empty.txt" --repo "$PREPO" --out "$WORK/acc-empty.tsv")"; GE_RC=$?
GM="$(python3 "$PG" gate --raw "$WORK/does-not-exist.txt" --repo "$PREPO" --out "$WORK/acc-missing.tsv")"; GM_RC=$?
if [ "$GE_RC" -eq 0 ] && [ "$GM_RC" -eq 0 ] && printf '%s\n' "$GE" | grep -q '^PROMISES|emitted=0|accepted=0|dropped=0|overcap=0$' \
   && printf '%s\n' "$GM" | grep -q '^PROMISES|emitted=0|'; then
  ok "an empty or missing raw file gives emitted=0 and exit 0"
else
  bad "empty/missing raw handling wrong (rc=$GE_RC/$GM_RC)"
fi
python3 "$PG" gate --raw "$RAW1" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "gate CLI misuse (missing --repo/--out) exits 2" || bad "gate CLI misuse did not exit 2"

# ================================================================================================
note "4) coverage (promise-gate.py): asserting body, anchoring, --prefix, n/a, missing harness ..."

ACCT="$WORK/acc-cov.tsv"
printf '1\ts1\tother\t-\tfirst promise\tsrc/fx/FxDebtDesk.sol:3\n2\ts2\tother\t-\tsecond promise\tsrc/fx/FxDebtDesk.sol:4\n3\ts3\tother\t-\tthird promise\tsrc/fx/FxDebtDesk.sol:5\n10\ts10\tother\t-\ttenth promise\tsrc/fx/FxDebtDesk.sol:6\n' > "$ACCT"
cat > "$WORK/h-cov.t.sol" <<'SOL'
contract H {
    uint256 a; uint256 b;
    function invariant_p1_first() public view { require(a == b, "p1"); }
    function invariant_p2_empty() public view { }
    // function invariant_p3_commented() public view { require(false); }
    function invariant_p10_tenth() public view { assert(a >= 0); }
}
SOL
C1="$(python3 "$PG" coverage --accepted "$ACCT" --harness "$WORK/h-cov.t.sol")"
if printf '%s\n' "$C1" | grep -qx 'PCOVERAGE|covered=2|total=4|low' && printf '%s\n' "$C1" | grep -qx 'PCOVERED|#1,#10' \
   && printf '%s\n' "$C1" | grep -qx 'PUNCOVERED|#2,#3'; then
  ok "an asserting invariant_p1_ counts; an empty-body p2 and a commented-out p3 do not; p10 covers #10"
else
  bad "coverage matching wrong:"; printf '%s\n' "$C1" | sed 's/^/      /' >&2
fi
printf '1\ts1\tother\t-\tfirst promise\tsrc/fx/FxDebtDesk.sol:3\n' > "$WORK/acc-one.tsv"
cat > "$WORK/h-p10.t.sol" <<'SOL'
contract H { function invariant_p10_a() public view { require(true, "x"); } }
SOL
if python3 "$PG" coverage --accepted "$WORK/acc-one.tsv" --harness "$WORK/h-p10.t.sol" | grep -qx 'PUNCOVERED|#1'; then
  ok "invariant_p10_a does NOT cover promise #1 (the _p<k>_ match is anchored)"
else
  bad "invariant_p10_ wrongly covers #1"
fi
cat > "$WORK/h-prefix.t.sol" <<'SOL'
contract H { function check_p1_x() public view { require(true, "x"); } }
SOL
if python3 "$PG" coverage --accepted "$WORK/acc-one.tsv" --harness "$WORK/h-prefix.t.sol" --prefix check | grep -qx 'PCOVERAGE|covered=1|total=1|ok' \
   && python3 "$PG" coverage --accepted "$WORK/acc-one.tsv" --harness "$WORK/h-prefix.t.sol" | grep -qx 'PCOVERAGE|covered=0|total=1|low'; then
  ok "--prefix is honoured (check_p1_ covers #1 only under --prefix check)"
else
  bad "--prefix is not honoured"
fi
: > "$WORK/acc-zero.tsv"
if python3 "$PG" coverage --accepted "$WORK/acc-zero.tsv" --harness "$WORK/h-cov.t.sol" | grep -qx 'PCOVERAGE|covered=0|total=0|n/a' \
   && python3 "$PG" coverage --accepted "$WORK/acc-one.tsv" --harness "$WORK/no-such.t.sol" | grep -qx 'PCOVERAGE|covered=0|total=1|low'; then
  ok "no accepted promise -> n/a (vacuous); a missing harness file covers nothing -> low"
else
  bad "the n/a / missing-harness cases are wrong"
fi
# the UNCOVERED block carries the ACCEPTED block's header lines verbatim.
UNC_BLOCK="$(python3 "$PG" coverage --accepted "$WORK/acc1.tsv" --harness "$WORK/no-such.t.sol" | awk '/^BEGIN-UNCOVERED$/{f=1; next} /^END-UNCOVERED$/{f=0} f')"
ACC_HDRS="$(printf '%s\n' "$ACC_BLOCK" | grep '^#')"
if [ -n "$UNC_BLOCK" ] && [ "$UNC_BLOCK" = "$ACC_HDRS" ]; then
  ok "the UNCOVERED block is the ACCEPTED block's '#k | subject | statement | cite' lines, verbatim"
else
  bad "the UNCOVERED block is not verbatim:"; printf '%s\n---\n%s\n' "$UNC_BLOCK" "$ACC_HDRS" | sed 's/^/      /' >&2
fi

# ================================================================================================
note "5) END-TO-END OFFLINE via run-zone-hunt.sh --deep-hunt --deep-hunt-only + stub --agentis ..."

STUB="$WORK/stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
cmd="${1:-}"; sub="${2:-}"
case "$cmd" in
  init) mkdir -p .agentis; exit 0 ;;
  memo) exit 0 ;;
  go)
    case "$sub" in
      zone-mapper.ag) echo "ZONE-CLASS|C10"; exit 0 ;;
      hunter.ag) echo "SAFE"; exit 0 ;;
      refuter.ag) echo "VERDICT|REAL|${CAND_FILE_FN:-}|${CAND_CLASS:-}|x"; exit 0 ;;
      invariant-prover.ag)
        tf="${TARGET_FN:-}"
        rd="${INV_REPO%/repo}"
        # record what reached us through the ABSOLUTE rundir (derived from INV_REPO, as the real prover does).
        echo "PROMISE-PROBE|target=$tf|src=$( [ -s "$rd/promise-sources.txt" ] && echo 1 || echo 0 )|tool=$( [ -f "$rd/promise-gate.py" ] && echo 1 || echo 0 )|ep=$( [ -s "$rd/entry-points.tsv" ] && echo 1 || echo 0 )" >&2
        if [ -s "$rd/promise-sources.txt" ]; then
          echo "PROMISES|$tf|emitted=2|accepted=2|dropped=0|overcap=0|source=llm"
          echo "PROMISE-ACCEPTED|#1|heldUntil|time-lock|units stay with the receiver until heldUntil|src/fx/FxHoldBase.sol:13"
          echo "PROMISE-ACCEPTED|#2|issue|time-lock|every issue restarts the waiting time|src/fx/FxHoldToken.sol:9"
          echo "HANDLER-COVERAGE|$tf|covered=4|total=4|required=3|mode=typed|ok|reask=0"
          echo "PROMISE-COVERAGE-DRAFT|$tf|covered=0|total=2|low"
          echo "PROMISE-COVERAGE|$tf|covered=1|total=2|low|reask=1"
          echo "PROMISE-UNCOVERED|#2"
          echo "INVARIANT|$tf|LOW_PROMISE_COVERAGE"
        elif [ -s "$rd/entry-points.tsv" ]; then
          echo "HANDLER-COVERAGE|$tf|covered=4|total=4|required=3|mode=typed|ok|reask=0"
          echo "INVARIANT|$tf|CLEAN"
        else
          echo "INVARIANT|$tf|CLEAN"
        fi
        exit 0 ;;
      coordinator.ag) exit 0 ;;
      *) echo "SAFE"; exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

MAPFIX="$WORK/mapfix.txt"
cat > "$MAPFIX" <<'FIX'
ZONE|src_fx|fx|C10|value-custody fixture family
CUSTODY|src_fx|true
FIX

DBASE="$WORK/dbase"
"$RZH" --repo "$PREPO" --out "$DBASE" --drop-dir "$DBASE/drop" --scope-hint src/fx \
  --backend mock --agentis "$STUB" \
  --map-fixture "$MAPFIX" \
  --pass-fixture "scope=in;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" >"$WORK/dbase.log" 2>&1
DBASE_RC=$?
if [ "$DBASE_RC" -ne 0 ] || [ ! -f "$DBASE/map/zones.json" ]; then
  skip "the offline breadth base did not build (rc=$DBASE_RC) — skipping the end-to-end run-zone-hunt checks"
  sed -n '1,20p' "$WORK/dbase.log" | sed 's/^/      /' >&2
else
  ok "the offline breadth base built (map/zones.json present)"
  lens_only() { lo="$1"; shift; "$RZH" --repo "$PREPO" --out "$lo" --deep-hunt --deep-hunt-only \
      --backend mock --agentis "$STUB" "$@" >"$lo.log" 2>&1; }
  cell_dirs() { for _cd in "$1"/deep-hunt/*/; do [ -d "$_cd" ] && basename "$_cd"; done; }
  rundir_listing() { ( cd "$1/deep-hunt" 2>/dev/null && find . -maxdepth 3 -path '*/run/*' -type f ! -name '*.log' | sort ); }

  # (a) REACH only (knob unset) vs DEEP_HUNT_PROMISES=0: identical selection, run dirs and rundir files; no
  #     promise file reaches the prover; no promise TSVs.
  A0="$WORK/e2e-a0"; cp -R "$DBASE" "$A0"; DEEP_HUNT_REACH=1 lens_only "$A0"; A0_RC=$?
  A1="$WORK/e2e-a1"; cp -R "$DBASE" "$A1"; DEEP_HUNT_REACH=1 DEEP_HUNT_PROMISES=0 lens_only "$A1"; A1_RC=$?
  if [ "$A0_RC" -eq 0 ] && [ "$A1_RC" -eq 0 ] && grep -q 'FxHoldToken.sol:FxHoldToken' "$A0/.deep-hunt-targets.tsv" \
     && diff -q "$A0/.deep-hunt-targets.tsv" "$A1/.deep-hunt-targets.tsv" >/dev/null \
     && [ "$(ls "$A0/deep-hunt")" = "$(ls "$A1/deep-hunt")" ] && [ "$(rundir_listing "$A0")" = "$(rundir_listing "$A1")" ]; then
    ok "(a) knob unset == DEEP_HUNT_PROMISES=0: identical selection TSV, run dirs and rundir file sets (REACH-only golden)"
  else
    bad "(a) the OFF path drifted between unset and =0 (rc=$A0_RC/$A1_RC)"
  fi
  if ! grep -rhq 'PROMISE-PROBE|.*src=1' "$A0/deep-hunt" 2>/dev/null && grep -rhq 'PROMISE-PROBE|.*src=0|tool=0|ep=1' "$A0/deep-hunt" 2>/dev/null \
     && [ ! -f "$A0/deep-hunt/promise-coverage.tsv" ] && [ ! -f "$A0/deep-hunt/promises.tsv" ] \
     && [ -z "$(find "$A0/deep-hunt" -name 'promise-*' 2>/dev/null)" ]; then
    ok "(a) OFF: no promise-sources.txt / promise-gate.py reach the prover and no promise TSV is written"
  else
    bad "(a) OFF path leaked promise files or TSVs"
  fi

  # (b) ON: files at the absolute rundir; both TSVs; LOW_PROMISE_COVERAGE kept; verified_findings.json unchanged.
  cp "$DBASE/verify/verified_findings.json" "$WORK/vj.before" 2>/dev/null || echo '[]' > "$WORK/vj.before"
  ONP="$WORK/e2e-on"; cp -R "$DBASE" "$ONP"; DEEP_HUNT_REACH=1 DEEP_HUNT_PROMISES=1 lens_only "$ONP"; ON_RC=$?
  PROBE_LINE="$(grep -rh 'PROMISE-PROBE|' "$ONP/deep-hunt" 2>/dev/null | grep 'FxHoldToken' | head -1 || true)"
  if [ "$ON_RC" -eq 0 ] && echo "$PROBE_LINE" | grep -q 'src=1|tool=1|ep=1'; then
    ok "(b) ON: promise-sources.txt + promise-gate.py reached the prover at the ABSOLUTE rundir (INV_REPO-derived)"
  else
    bad "(b) the promise files did not reach the prover (rc=$ON_RC):"; echo "      $PROBE_LINE" >&2
  fi
  if diff -q "$A0/.deep-hunt-targets.tsv" "$ONP/.deep-hunt-targets.tsv" >/dev/null && [ "$(cell_dirs "$A0")" = "$(cell_dirs "$ONP")" ]; then
    ok "(b) the selection TSV and run dirs are the REACH-only ones (PROMISES never changes selection)"
  else
    bad "(b) PROMISES changed the selection or the run dirs"
  fi
  if awk -F'\t' '$1=="src_fx" && $2=="FxHoldToken" && $3=="C10" && $4=="llm" && $5=="2" && $6=="2" && $7=="0" && $8=="0" && $14=="LOW_PROMISE_COVERAGE" {f=1} END{exit !f}' "$ONP/deep-hunt/promise-coverage.tsv" 2>/dev/null \
     && awk -F'\t' '$1=="src_fx" && $2=="FxHoldToken" && $4=="#1" && $5=="heldUntil" && $6=="time-lock" && $9=="1" {f=1} END{exit !f}' "$ONP/deep-hunt/promises.tsv" 2>/dev/null \
     && awk -F'\t' '$1=="src_fx" && $2=="FxHoldToken" && $4=="#2" && $5=="issue" && $6=="time-lock" && $9=="0" {f=1} END{exit !f}' "$ONP/deep-hunt/promises.tsv"; then
    ok "(b) promise-coverage.tsv + promises.tsv rows written; LOW_PROMISE_COVERAGE KEPT; the uncovered #2 is covered=0"
  else
    bad "(b) the promise TSVs are missing / wrong:"; cat "$ONP/deep-hunt/promise-coverage.tsv" "$ONP/deep-hunt/promises.tsv" 2>/dev/null | sed 's/^/      /' >&2
  fi
  if grep -q "LOW_PROMISE_COVERAGE (an accepted user-facing promise had no asserting invariant; not merged)" "$ONP.log" \
     && diff -q "$WORK/vj.before" "$ONP/verify/verified_findings.json" >/dev/null 2>&1; then
    ok "(b) the LOW_PROMISE_COVERAGE cell is echoed and verified_findings.json is byte-unchanged (never merged)"
  else
    bad "(b) LOW_PROMISE_COVERAGE echo missing or verified_findings.json changed"
  fi
  if grep -q '## Promise coverage (DEEP_HUNT_PROMISES)' "$ONP"/deep-hunt/src_fx-C10-FxHoldToken/invariant-report.md 2>/dev/null; then
    ok "(b) the cell report carries the Promise coverage section"
  else
    bad "(b) the cell report is missing the Promise coverage section"
  fi

  # (c) ON + resume: LOW_PROMISE_COVERAGE is terminal.
  DEEP_HUNT_REACH=1 DEEP_HUNT_PROMISES=1 lens_only "$ONP" --deep-hunt-resume; RES_RC=$?
  N_CELLS="$(find "$ONP/deep-hunt" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  if [ "$RES_RC" -eq 0 ] && [ "$N_CELLS" -ge 1 ] \
     && [ "$(grep -c 'already hunted (terminal verdict), skipping' "$ONP.log")" -eq "$N_CELLS" ]; then
    ok "(c) ON + --deep-hunt-resume: the LOW_PROMISE_COVERAGE cell is terminal and skipped"
  else
    bad "(c) LOW_PROMISE_COVERAGE was not treated as terminal on resume (rc=$RES_RC)"
  fi
fi

# (d) guard exits.
DEEP_HUNT_PROMISES=1 "$RZH" --repo "$PREPO" --out "$WORK/g1" --deep-hunt --deep-hunt-only --backend mock --agentis "$STUB" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "(d) DEEP_HUNT_PROMISES=1 without DEEP_HUNT_REACH=1 exits 2" || bad "(d) DEEP_HUNT_PROMISES=1 without REACH did not exit 2"
DEEP_HUNT_REACH=1 DEEP_HUNT_PROMISES=2 "$RZH" --repo "$PREPO" --out "$WORK/g2" --deep-hunt --deep-hunt-only --backend mock --agentis "$STUB" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "(d) DEEP_HUNT_PROMISES=2 exits 2" || bad "(d) DEEP_HUNT_PROMISES=2 did not exit 2"
"$RIH" --repo "$PREPO" --target src/fx/FxDebtDesk.sol --class C10 --backend mock --agentis "$STUB" --out "$WORK/g3" --promises >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "(d) run-invariant-hunt.sh --promises without --reach exits 2" || bad "(d) --promises without --reach did not exit 2"
"$RIH" --repo "$PREPO" --target src/fx/FxDebtDesk.sol --class C10 --backend mock --agentis "$STUB" --out "$WORK/g4" --reach --promise-fixture "$RAW1" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "(d) run-invariant-hunt.sh --promise-fixture without --promises exits 2" || bad "(d) --promise-fixture without --promises did not exit 2"

# ================================================================================================
note "6) (needs agentis) the SHIPPED promise helpers on canned inputs + no kind vocabulary in the rendered prompts ..."
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — skipping the sliced-helper probe"
else
  PROBE="$WORK/probe.ag"
  {
    echo "cb 40000;"
    echo 'let invMatch = "invariant";'
    extract_fn promise_extract_instruction "$PROVER"
    extract_fn promise_seed "$PROVER"
    extract_fn promise_verdict "$PROVER"
    extract_fn pcov_uncovered "$PROVER"
    extract_fn pcov_gap "$PROVER"
    extract_fn pcov_ok "$PROVER"
    extract_fn pcov_body "$PROVER"
    extract_fn pcov_uncovered_block "$PROVER"
    extract_fn promise_reask_instruction "$PROVER"
    extract_fn promise_broken "$PROVER"
    echo 'let blk = "#1 | heldUntil | units stay | src/fx/FxHoldBase.sol:13\n    require(x);";'
    echo 'print("SEEDOFF|" + to_string(len(promise_seed(false, blk, "invariant"))));'
    echo 'print("SEEDEMPTY|" + to_string(len(promise_seed(true, "", "invariant"))));'
    echo 'print("SEEDON|" + to_string(len(promise_seed(true, blk, "invariant"))));'
    echo 'print("V-OFF|" + promise_verdict("CLEAN", false, false));'
    echo 'print("V-LOW|" + promise_verdict("CLEAN", true, false));'
    echo 'print("V-OK|" + promise_verdict("CLEAN", true, true));'
    echo 'print("V-FIND|" + promise_verdict("FINDING", true, false));'
    echo 'print("V-LOWCOV|" + promise_verdict("LOW_COVERAGE", true, false));'
    echo 'print("V-HARN|" + promise_verdict("HARNESS_ERROR", true, false));'
    echo 'let canned = "PCOVERAGE|covered=1|total=3|low\nPCOVERED|#1\nPUNCOVERED|#2,#3\nBEGIN-UNCOVERED\n#2 | a | b | c:1\n#3 | d | e | f:2\nEND-UNCOVERED";'
    echo 'print("GAP|" + to_string(pcov_gap(canned)));'
    echo 'print("OKLOW|" + to_string(pcov_ok(canned)));'
    echo 'print("OKNA|" + to_string(pcov_ok("PCOVERAGE|covered=0|total=0|n/a")));'
    echo 'print("OKOPEN|" + to_string(pcov_ok("no tool output")));'
    echo 'print("BODYNONE|" + pcov_body(""));'
    echo 'print("REASKQUOTE|" + to_string(index_of(promise_reask_instruction(pcov_uncovered_block(canned), "PREVSRC", ""), "#2 | a | b | c:1\n#3 | d | e | f:2") >= 0));'
    echo 'print("BROKEN|" + promise_broken("x\n-- broken invariant: Inv_H.invariant_p2_repay_capped — shrunk exploit sequence:\n-- broken invariant: Inv_H.invariant_lens — shrunk\nstep 1: invariant_p9_not_broken", "invariant"));'
    echo 'print("=== EXTRACT ===");'
    echo 'print(promise_extract_instruction());'
    echo 'print("=== SEED ===");'
    echo 'print(promise_seed(true, blk, "invariant"));'
    echo 'print("=== REASK ===");'
    echo 'print(promise_reask_instruction("#2 | a | b | c:1", "PREVSRC", ""));'
    echo 'print("=== END ===");'
  } > "$PROBE"
  PDIR="$WORK/pdir"; mkdir -p "$PDIR"; cp "$PROBE" "$PDIR/p.ag"
  POUT="$( (cd "$PDIR" && agentis init >/dev/null 2>&1; agentis go p.ag 2>/dev/null) || true )"
  if echo "$POUT" | grep -q 'SEEDOFF|0' && echo "$POUT" | grep -q 'SEEDEMPTY|0' && echo "$POUT" | grep -qE 'SEEDON\|[1-9]'; then
    ok "promise_seed is 0 bytes when off AND when nothing was accepted, non-empty when on"
  else
    bad "promise_seed length probe failed:"; echo "$POUT" | head -20 | sed 's/^/      /' >&2
  fi
  if echo "$POUT" | grep -q 'V-OFF|CLEAN' && echo "$POUT" | grep -q 'V-LOW|LOW_PROMISE_COVERAGE' \
     && echo "$POUT" | grep -q 'V-OK|CLEAN' && echo "$POUT" | grep -q 'V-FIND|FINDING' \
     && echo "$POUT" | grep -q 'V-LOWCOV|LOW_COVERAGE' && echo "$POUT" | grep -q 'V-HARN|HARNESS_ERROR'; then
    ok "promise_verdict: off=identity, CLEAN+gap=LOW_PROMISE_COVERAGE, FINDING never downgraded, LOW_COVERAGE outranks"
  else
    bad "promise_verdict table wrong:"; echo "$POUT" | grep '^V-' | sed 's/^/      /' >&2
  fi
  if echo "$POUT" | grep -q 'GAP|2' && echo "$POUT" | grep -q 'OKLOW|false' && echo "$POUT" | grep -q 'OKNA|true' \
     && echo "$POUT" | grep -q 'OKOPEN|true' && echo "$POUT" | grep -q 'BODYNONE|unmeasured'; then
    ok "pcov_gap / pcov_ok parse the canned output; n/a is ok; no PCOVERAGE| line fails OPEN (readout: unmeasured)"
  else
    bad "promise-coverage parsers wrong:"; echo "$POUT" | grep -E '^(GAP|OK|BODY)' | sed 's/^/      /' >&2
  fi
  if echo "$POUT" | grep -q 'REASKQUOTE|true'; then
    ok "the promise re-ask quotes the UNCOVERED block verbatim"
  else
    bad "the promise re-ask does not quote the uncovered block verbatim"
  fi
  if echo "$POUT" | grep -qx 'BROKEN|invariant_p2_repay_capped'; then
    ok "promise_broken extracts only the broken invariant_p<k>_ names from the '-- broken invariant:' lines"
  else
    bad "promise_broken wrong:"; echo "$POUT" | grep '^BROKEN' | sed 's/^/      /' >&2
  fi
  EXTRACT_TXT="$(echo "$POUT" | awk '/^=== EXTRACT ===$/{f=1; next} /^=== SEED ===$/{f=0} f')"
  SEED_TXT="$(echo "$POUT" | awk '/^=== SEED ===$/{f=1; next} /^=== REASK ===$/{f=0} f')"
  REASK_TXT="$(echo "$POUT" | awk '/^=== REASK ===$/{f=1; next} /^=== END ===$/{f=0} f')"
  if printf '%s\n' "$EXTRACT_TXT" | grep -qF 'PROMISE|#<k>|' && printf '%s\n' "$EXTRACT_TXT" | grep -q 'at most 8' \
     && printf '%s\n' "$EXTRACT_TXT" | grep -q 'AT MOST 40 consecutive lines'; then
    ok "the extraction instruction carries the PROMISE| line format, the cap of 8 and the 40-line citation rule"
  else
    bad "the extraction instruction is missing its format / cap / citation rule"
  fi
  # STOP-1 decision 4: the RENDERED extraction prompt (instruction + the real listing it is sent with), the
  # rendered promise seed (with an ACCEPTED block from the gate) and the promise re-ask carry NO kind word.
  SEED_REAL="$(printf '%s\n' "$SEED_TXT"; printf '%s\n' "$ACC_BLOCK")"
  if [ -n "$EXTRACT_TXT" ] && [ -n "$SEED_TXT" ] && [ -n "$REASK_TXT" ] \
     && ! { printf '%s\n' "$EXTRACT_TXT"; cat "$LIST"; } | grep -qiE "$KIND_WORDS_RE" \
     && ! printf '%s\n' "$SEED_REAL" | grep -qiE "$KIND_WORDS_RE" \
     && ! printf '%s\n' "$REASK_TXT" | grep -qiE "$KIND_WORDS_RE"; then
    ok "no kind vocabulary (time-lock, ordering, rounding, per-user-conservation, bound, access) in the rendered extraction prompt, promise seed or promise re-ask"
  else
    bad "a kind word reached a rendered promise prompt (STOP-1 decision 4):"
    { printf '%s\n' "$EXTRACT_TXT"; cat "$LIST"; printf '%s\n' "$SEED_REAL" "$REASK_TXT"; } | grep -inE "$KIND_WORDS_RE" | sed 's/^/      /' >&2
  fi
fi

# ================================================================================================
note "7) (needs agentis) the real prover under --backend mock: exactly one extra prompt per promise path ..."
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — skipping the live mock-backend probe"
else
  PFIX="$WORK/pfix-live.txt"
  {
    echo "PROMISE|#1|heldUntil|units issued to an account cannot leave it before its heldUntil time|src/fx/FxHoldBase.sol:$HOLD_REQ"
    echo "PROMISE|#2|issue|every issue restarts the receiving account's waiting time|src/fx/FxHoldToken.sol:9"
    echo "PROMISE|#3|transferFrom|a promise with no citation|see the code"
  } > "$PFIX"
  live() { "$RIH" --repo "$PREPO" --target src/fx/FxHoldToken.sol:FxHoldToken --class C10 --backend mock --agentis agentis \
      --repair-rounds 0 --out "$1" "${@:2}" >"$1.log" 2>&1; }
  L0="$WORK/live-reach"; live "$L0" --reach
  L1="$WORK/live-fix"; live "$L1" --reach --promises --promise-fixture "$PFIX"
  L2="$WORK/live-llm"; live "$L2" --reach --promises
  n_prompts() { cat "$1"/run/invariant_*.log 2>/dev/null | grep -c '^\[prompt\]' || true; }
  N0="$(n_prompts "$L0")"; N1="$(n_prompts "$L1")"; N2="$(n_prompts "$L2")"
  if grep -q 'accepted=2|dropped=1|overcap=0|source=fixture' "$L1"/run/invariant_*.log \
     && grep -qx 'PROMISE-DROPPED|#3|cite-missing' "$L1"/run/invariant_*.log \
     && grep -q '^PROMISE-COVERAGE|.*|reask=1$' "$L1"/run/invariant_*.log && [ "$N1" -eq $((N0 + 1)) ]; then
    ok "(fixture) accepted=2|dropped=1|source=fixture, #3 cite-missing, reask=1, and exactly ONE more prompt ($N1 vs $N0: the promise re-ask)"
  else
    bad "(fixture) live promise path wrong (prompts $N1 vs $N0):"; grep -E '^PROMISE|^\[prompt\]' "$L1"/run/invariant_*.log 2>/dev/null | sed 's/^/      /' >&2
  fi
  if grep -q 'accepted=0|dropped=0|overcap=0|source=llm' "$L2"/run/invariant_*.log \
     && grep -q '^PROMISE-COVERAGE|.*|n/a|reask=0$' "$L2"/run/invariant_*.log && [ "$N2" -eq $((N0 + 1)) ] \
     && grep -q '^\[prompt\] "You are reading a smart-contract system' "$L2"/run/invariant_*.log; then
    ok "(llm) source=llm, accepted=0, reask=0, and exactly ONE more prompt ($N2 vs $N0: the extraction)"
  else
    bad "(llm) live extraction path wrong (prompts $N2 vs $N0):"; grep -E '^PROMISE|^\[prompt\]' "$L2"/run/invariant_*.log 2>/dev/null | sed 's/^/      /' >&2
  fi
  if ! grep -q 'PROMISE' "$L0"/run/invariant_*.log && [ ! -f "$L0/run/promise-sources.txt" ]; then
    ok "(--reach alone) no PROMISE substring in the cell log and no promise-sources.txt (the knob reached the real prover only when set)"
  else
    bad "(--reach alone) a PROMISE line or file leaked into the REACH-only run"
  fi
fi

# ================================================================================================
note "8) (needs agentis + forge) promise invariants catch both fixture bugs; an uncovered promise -> LOW_PROMISE_COVERAGE ..."
if ! command -v agentis >/dev/null 2>&1 || ! command -v forge >/dev/null 2>&1; then
  skip "agentis or forge absent — skipping the live forge checks"
else
  cat > "$WORK/hold.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {FxHoldToken} from "../src/fx/FxHoldToken.sol";
contract HoldHandler {
    FxHoldToken public t;
    address public sink = address(0xBEEF);
    bool public early;
    constructor(FxHoldToken _t) { t = _t; }
    function _watch(uint256 beforeBal) internal {
        if (t.balanceOf(address(this)) < beforeBal && block.timestamp < t.heldUntil(address(this))) { early = true; }
    }
    function h_issue(uint256 amt) public { t.issue(address(this), amt % 1e24); }
    function h_approve(uint256 amt) public { t.approve(address(this), amt % 1e24); }
    function h_transfer(uint256 amt) public {
        uint256 b = t.balanceOf(address(this));
        if (b == 0) return;
        try t.transfer(sink, amt % (b + 1)) {} catch {}
        _watch(b);
    }
    function h_transferFrom(uint256 amt) public {
        uint256 b = t.balanceOf(address(this));
        if (b == 0) return;
        uint256 a = amt % (b + 1);
        t.approve(address(this), a);
        try t.transferFrom(address(this), sink, a) {} catch {}
        _watch(b);
    }
}
contract Inv_Hold {
    FxHoldToken t; HoldHandler h;
    function setUp() public { t = new FxHoldToken(); h = new HoldHandler(t); }
    function targetContracts() public view returns (address[] memory a) { a = new address[](1); a[0] = address(h); }
    function invariant_p1_hold_window() public view { require(!h.early(), "left before heldUntil"); }
}
SOL
  cat > "$WORK/debt.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {FxDebtDesk} from "../src/fx/FxDebtDesk.sol";
contract DebtHandler {
    FxDebtDesk public d;
    bool public overtaken;
    constructor(FxDebtDesk _d) { d = _d; }
    function h_open(uint256 amt) public { d.open(amt % 1e24); }
    function h_fund(uint256 amt) public { d.fund(amt % 1e24); }
    function h_liquidate() public { try d.liquidate(address(this)) {} catch {} }
    function h_repay(uint256 amt) public {
        uint256 w = d.wallet(address(this));
        if (w == 0) return;
        uint256 a = amt % (w + 1);
        uint256 owed = d.debt(address(this));
        try d.repay(address(this), a) {
            if (w - d.wallet(address(this)) > owed) { overtaken = true; }
        } catch {}
    }
}
contract Inv_Debt {
    FxDebtDesk d; DebtHandler h;
    function setUp() public { d = new FxDebtDesk(); h = new DebtHandler(d); }
    function targetContracts() public view returns (address[] memory a) { a = new address[](1); a[0] = address(h); }
    function invariant_p2_repay_capped() public view { require(!h.overtaken(), "took more than the debt"); }
}
SOL
  cat > "$WORK/tally.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {FxTally} from "../src/fx/FxTally.sol";
contract TallyHandler {
    FxTally public t;
    uint256 public added;
    uint256 public taken;
    constructor(FxTally _t) { t = _t; }
    function h_add(uint256 amt) public { amt = amt % 1e24; t.add(amt); added += amt; }
    function h_take(uint256 amt) public {
        uint256 cur = t.tally(address(this));
        if (cur == 0) return;
        amt = amt % (cur + 1);
        t.take(amt);
        taken += amt;
    }
}
contract Inv_Tally {
    FxTally t; TallyHandler h;
    function setUp() public { t = new FxTally(); h = new TallyHandler(t); }
    function targetContracts() public view returns (address[] memory a) { a = new address[](1); a[0] = address(h); }
    function invariant_p1_take_only_added() public view { require(h.taken() <= h.added(), "took more than added"); }
}
SOL
  TALLY_DOC="$(grep -n 'never moves an account' "$PREPO/src/fx/FxTally.sol" | cut -d: -f1)"
  TAKE_DOC="$(grep -n 'only removes what the caller added' "$PREPO/src/fx/FxTally.sol" | cut -d: -f1)"
  printf 'PROMISE|#1|heldUntil|units issued to an account cannot leave it before its heldUntil time|src/fx/FxHoldBase.sol:%s\n' "$HOLD_REQ" > "$WORK/pf-hold.txt"
  printf 'PROMISE|#2|repay|a payment toward an account never takes more than its outstanding debt|src/fx/FxDebtDesk.sol:%s-%s\n' "$DEBT_DOC" "$DEBT_FN" > "$WORK/pf-debt.txt"
  {
    printf 'PROMISE|#1|take|a caller only takes out what it added|src/fx/FxTally.sol:%s-%s\n' "$TAKE_DOC" "$((TAKE_DOC + 4))"
    printf 'PROMISE|#2|tally|an account tally never goes below zero|src/fx/FxTally.sol:%s-%s\n' "$TALLY_DOC" "$((TALLY_DOC + 1))"
  } > "$WORK/pf-tally.txt"
  fx_run() { "$RIH" --repo "$PREPO" --target "$1" --class C10 --handler-fixture "$2" --backend mock --agentis agentis \
      --out "$3" "${@:4}" >"$3.log" 2>&1; }
  cell_verdict() { grep 'INVARIANT|' "$1"/run/invariant_*.log 2>/dev/null | tail -1 | sed 's/.*INVARIANT|//' | cut -d'|' -f2; }
  FH="$WORK/fx-hold"; fx_run src/fx/FxHoldToken.sol:FxHoldToken "$WORK/hold.t.sol" "$FH" --reach --promises --promise-fixture "$WORK/pf-hold.txt"
  if [ "$(cell_verdict "$FH")" = "FINDING" ] && grep -qx 'PROMISE-BROKEN|invariant_p1_hold_window' "$FH"/run/invariant_*.log; then
    ok "(hold) the per-account hold bypass is a FINDING and PROMISE-BROKEN names invariant_p1_hold_window"
  else
    bad "(hold) expected FINDING + PROMISE-BROKEN|invariant_p1_… (got '$(cell_verdict "$FH")')"; grep -E 'PROMISE|INVARIANT' "$FH"/run/invariant_*.log 2>/dev/null | sed 's/^/      /' >&2
  fi
  FD="$WORK/fx-debt"; fx_run src/fx/FxDebtDesk.sol:FxDebtDesk "$WORK/debt.t.sol" "$FD" --reach --promises --promise-fixture "$WORK/pf-debt.txt"
  if [ "$(cell_verdict "$FD")" = "FINDING" ] && grep -qx 'PROMISE-BROKEN|invariant_p2_repay_capped' "$FD"/run/invariant_*.log; then
    ok "(debt) a payment after the debt was cleared is a FINDING and PROMISE-BROKEN names invariant_p2_repay_capped"
  else
    bad "(debt) expected FINDING + PROMISE-BROKEN|invariant_p2_… (got '$(cell_verdict "$FD")')"; grep -E 'PROMISE|INVARIANT' "$FD"/run/invariant_*.log 2>/dev/null | sed 's/^/      /' >&2
  fi
  FT="$WORK/fx-tally-on"; fx_run src/fx/FxTally.sol:FxTally "$WORK/tally.t.sol" "$FT" --reach --promises --promise-fixture "$WORK/pf-tally.txt"
  FO="$WORK/fx-tally-off"; fx_run src/fx/FxTally.sol:FxTally "$WORK/tally.t.sol" "$FO" --reach
  if [ "$(cell_verdict "$FT")" = "LOW_PROMISE_COVERAGE" ] && grep -qx 'PROMISE-UNCOVERED|#2' "$FT"/run/invariant_*.log; then
    ok "(tally) a clean harness covering 1 of 2 accepted promises is LOW_PROMISE_COVERAGE (#2 uncovered)"
  else
    bad "(tally) expected LOW_PROMISE_COVERAGE (got '$(cell_verdict "$FT")')"; grep -E 'PROMISE|INVARIANT|HANDLER-COVERAGE' "$FT"/run/invariant_*.log 2>/dev/null | sed 's/^/      /' >&2
  fi
  if [ "$(cell_verdict "$FO")" = "CLEAN" ]; then
    ok "(tally) the same harness without --promises (REACH only) is CLEAN"
  else
    bad "(tally) the REACH-only run was '$(cell_verdict "$FO")' (expected CLEAN)"
  fi
  COLS_ON="$(grep '^| ' "$FT/invariant-report.md" 2>/dev/null | grep -v '^| Target' | head -1 | awk -F'|' '{print $2"|"$3"|"$4}')"
  COLS_OFF="$(grep '^| ' "$FO/invariant-report.md" 2>/dev/null | grep -v '^| Target' | head -1 | awk -F'|' '{print $2"|"$3"|"$4}')"
  if [ -n "$COLS_OFF" ] && [ "$COLS_ON" = "$COLS_OFF" ] && grep -q '## Promise coverage (DEEP_HUNT_PROMISES)' "$FT/invariant-report.md" \
     && ! grep -q '## Promise coverage' "$FO/invariant-report.md"; then
    ok "(tally) the table's Target/Class/Handler columns are unchanged; only the --promises report has the Promise coverage section"
  else
    bad "(tally) report table / section wrong: on=[$COLS_ON] off=[$COLS_OFF]"
  fi
fi

# ================================================================================================
note "9) PURITY: no contest / [HM]-<n> / domain nouns / kind words in the promise templates; no embedded interpreter ..."
TEMPL="$WORK/templates.txt"
{
  sed -n '/^fn promise_extract_instruction(/,/^}/p' "$PROVER"
  sed -n '/^fn promise_seed(/,/^}/p' "$PROVER"
  sed -n '/^fn promise_reask_instruction(/,/^}/p' "$PROVER"
  grep -E '"#%d \| %s' "$PG"
  grep -E '^PROMISE_TRUNC_MARK|"=== "' "$INH"
} > "$TEMPL"
if grep -inE 'codehawks|sherlock|cantina|immunefi|code4rena|\b[HM]-[0-9]+\b' "$TEMPL"; then
  bad "a promise template carries a contest name or an [HM]-<n> tag"
else
  ok "no contest name / [HM]-<n> tag in the promise templates"
fi
if grep -iwE 'transfer|liquidat[a-z]*|repay|borrow|mint|redeem|lockup|vault|router|bridge|reward|oracle|endpoint' "$TEMPL"; then
  bad "a promise template names a domain noun (overfitting guard)"
else
  ok "no domain nouns in the promise templates (overfitting guard)"
fi
if grep -iE "$KIND_WORDS_RE" "$TEMPL"; then
  bad "a promise template carries a kind word (STOP-1 decision 4)"
else
  ok "no kind word in any promise template (STOP-1 decision 4)"
fi
if sed -n '/#2245 (iteration 7/,/^$/p' "$PROVER" | grep -qE "exec sh \"[^\"]*(python3 -c|awk |sed )"; then
  bad "a new .ag PROMISES exec sh embeds a python3 -c / awk / sed one-liner"
else
  ok "the .ag PROMISES code embeds no python3 -c / awk / sed interpreter logic"
fi

# ================================================================================================
note "10) MUTATIONS: every gate / coverage / ordering rule is load-bearing ..."
mutate() {  # $1 = src, $2 = dst, $3 = python-literal old, $4 = new
  python3 - "$1" "$2" "$3" "$4" <<'PYM'
import sys
src = open(sys.argv[1]).read()
if src.count(sys.argv[3]) != 1:
    sys.stderr.write("mutation anchor not found exactly once: " + sys.argv[3] + "\n")
    sys.exit(3)
open(sys.argv[2], "w").write(src.replace(sys.argv[3], sys.argv[4]))
PYM
}
mut_gate() {  # $1 = mutated gate, $2 = expected ACCEPTED id, on RAW1
  python3 "$1" gate --raw "$RAW1" --repo "$PREPO" --out "$WORK/mut.tsv" 2>/dev/null | grep -q "^PROMISE-ACCEPTED|#$2|"
}
M="$WORK/pg-mut.py"
mutate "$PG" "$M" 'if not bare or not any(named.search(ln) for ln in rng_lines):' 'if False:' \
  && mut_gate "$M" 12 && ok "(a) dropping the subject-naming check accepts #12 (names-other) — load-bearing" \
  || bad "(a) the subject-naming mutation did not flip #12"
mutate "$PG" "$M" 'if rel.startswith("/") or ".." in rel:' 'if False:' \
  && mut_gate "$M" 7 && ok "(b) dropping the ../absolute refusal accepts #7 (src/../src/...) — load-bearing" \
  || bad "(b) the ../absolute mutation did not flip #7"
mutate "$PG" "$M" 'CITE_MAX_LINES = 40' 'CITE_MAX_LINES = 400' \
  && mut_gate "$M" 11 && ok "(c) dropping the 40-line width cap accepts #11 (README.md:1-45) — load-bearing" \
  || bad "(c) the width-cap mutation did not flip #11"
mutate "$PG" "$M" 'if re.search(OUT_OF_SCOPE_RE, rel):' 'if False:' \
  && mut_gate "$M" 10 && ok "(d) dropping the out-of-scope refusal accepts #10 (lib/) — load-bearing" \
  || bad "(d) the out-of-scope mutation did not flip #10"
mutate "$PG" "$M" 'DEFAULT_CAP = 8' 'DEFAULT_CAP = 9' \
  && python3 "$M" gate --raw "$RAW10" --repo "$PREPO" --out "$WORK/mut.tsv" | grep -q '^PROMISES|emitted=10|accepted=9|dropped=0|overcap=1$' \
  && ok "(e) cap 8 -> 9 admits a 9th promise — the cap is load-bearing" || bad "(e) the cap mutation did not flip the 10-promise fixture"
mutate "$PG" "$M" 'if _ASSERTS_RE.search(fn_body(harness, m.end())):' 'if True:' \
  && python3 "$M" coverage --accepted "$ACCT" --harness "$WORK/h-cov.t.sol" | grep -qx 'PCOVERED|#1,#2,#10' \
  && ok "(f) dropping the asserting-body rule covers the empty-body #2 — load-bearing" || bad "(f) the asserting-body mutation did not flip #2"
mutate "$PG" "$M" 'r"_p" + str(k) + r"_[A-Za-z0-9_$]+\s*\("' 'r"_p" + str(k) + r"[A-Za-z0-9_$]*\s*\("' \
  && python3 "$M" coverage --accepted "$WORK/acc-one.tsv" --harness "$WORK/h-p10.t.sol" | grep -qx 'PCOVERED|#1' \
  && ok "(g) un-anchoring _p<k>_ lets invariant_p10_a cover #1 — the anchor is load-bearing" || bad "(g) the anchor mutation did not flip #1"
MI="$WORK/inh-mut.py"
mutate "$INH" "$MI" '    for f in contracts + interfaces:' '    for f in interfaces + contracts:' \
  && python3 "$MI" promise-sources --repo "$PREPO" --target src/fx/FxHoldToken.sol:FxHoldToken --out "$WORK/list-mut.txt" \
  && [ "$(grep '^=== ' "$WORK/list-mut.txt" | sed -n 2p)" = "=== src/fx/IFxHold.sol ===" ] \
  && ok "(h) dropping the contracts-before-interfaces order puts the interface second — the order is load-bearing" \
  || bad "(h) the listing-order mutation did not flip the fixture"

# ================================================================================================
echo
if [ "$FAILS" -eq 0 ]; then
  note "ALL CHECKS PASSED"
  exit 0
else
  note "$FAILS CHECK(S) FAILED"
  exit 1
fi
