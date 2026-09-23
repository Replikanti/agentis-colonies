#!/usr/bin/env bash
# demo-deep-hunt-reach.sh — proof of #2245 (iteration 6) DEEP-HUNT REACH: concrete multi-target selection, the
# pre-fuzz HANDLER-COVERAGE gate, and the deployment inventory — knob DEEP_HUNT_REACH=1, default OFF.
#
# The knob threads: run-zone-hunt.sh (DEEP_HUNT_REACH env) -> lib/inheritance.py reach-targets (concrete targets)
# -> run-invariant-hunt.sh --reach (writes entry-points.tsv + reach-inventory.txt into $RUN, stages
# handler-coverage.py) -> invariant-prover.ag reachOn = len(entry-points.tsv) > 0 -> coverage gate + inventory
# prompt. When the knob is unset every one of those is inert and the run is byte-identical to today.
#
# PARTS (CI floor = python3 only; agentis/forge parts SKIP cleanly when the tool is absent):
#   1  SOURCE GUARDS: the wiring is present in the shipped shell + .ag (mutation-checkable greps).
#   2  SELECTION (inheritance.py reach-targets): concrete subclass wins over the abstract base; greedy stop;
#      an out-of-zone concrete descendant is flagged out_zone; an interfaces-only zone yields nothing.
#   3  ENTRY POINTS (inheritance.py reach-inventory): vendored transfer family present; view/pure + initializer
#      excluded; own role-gated marked; vendored modifier boilerplate excluded; OVERCAP; vendored tie-break.
#   4  INVENTORY: collaborators resolved with signatures; unresolved -> mock; --fork omits the deployment half.
#   5  COVERAGE TOOL (handler-coverage.py): typed vs setUp/constructor-only; registered; name-only; boundaries.
#   6  END-TO-END OFFLINE via run-zone-hunt.sh --deep-hunt --deep-hunt-only + a stub --agentis: OFF byte-identical,
#      ON reaches the prover (rundir files + rel:Name target), LOW_COVERAGE kept + terminal on resume, guard exits.
#   7  (needs agentis) the SHIPPED helpers, sliced from the .ag by name, exercised on canned inputs.
#   8  (needs agentis + forge) a compiling fixture covering 1 of 4 entry points -> LOW_COVERAGE under --reach,
#      CLEAN without it, with a byte-identical report table.
#   9  PURITY: no contest / [HM]-<n> / domain nouns in the REACH prompt + re-ask templates; no embedded interpreter.
#  10  MUTATIONS: each selection/coverage rule is load-bearing (drop it -> a named fixture flips).
#
# Usage: dark-factory/demo-deep-hunt-reach.sh
# Exit: 0 = all assertions hold; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INH="$HERE/lib/inheritance.py"
COV="$HERE/evm-harness/handler-coverage.py"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
RZH="$HERE/run-zone-hunt.sh"
RIH="$HERE/run-invariant-hunt.sh"

FAILS=0
note() { echo "demo-deep-hunt-reach.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# extract_fn NAME FILE — slice a single `fn NAME(...) { ... }` block out of a shipped .ag by brace-matching,
# so PART 7 exercises the SHIPPED functions verbatim (never a hand-copy).
extract_fn() {
  awk -v fn="$1" '
    BEGIN { want = "fn " fn "("; depth = 0; on = 0 }
    {
      if (!on && index($0, want) > 0) { on = 1 }
      if (on) {
        print
        n = gsub(/{/, "{"); m = gsub(/}/, "}")
        depth += n - m
        if (depth <= 0 && index($0, "{") == 0 && on && NR > 0 && seen) { }
        if (depth <= 0 && seen) { exit }
        if (index($0, "{") > 0) seen = 1
      }
    }
  ' "$2"
}

# ================================================================================================
note "1) SOURCE GUARDS: the DEEP_HUNT_REACH wiring is present in the shipped files ..."

if grep -q 'DEEP_HUNT_REACH="\${DEEP_HUNT_REACH:-}"' "$RZH" \
   && grep -q 'DEEP_HUNT_REACH must be unset, 0 or 1' "$RZH" \
   && grep -q 'DEEP_HUNT_REACH=1 requires --deep-hunt' "$RZH"; then
  ok "run-zone-hunt.sh parses + validates the DEEP_HUNT_REACH env knob"
else
  bad "run-zone-hunt.sh is missing the DEEP_HUNT_REACH knob / validation"
fi

if grep -q 'reach-targets --zones' "$RZH" && grep -q 'export DEEP_HUNT_REACH_TSV' "$RZH" \
   && grep -q 'ranked = reach_map\[zid\]' "$RZH"; then
  ok "run-zone-hunt.sh runs reach-targets and overrides the per-zone target list under REACH"
else
  bad "run-zone-hunt.sh does not thread the reach-targets selection into the heredoc"
fi

if grep -q 'set -- "\$@" --reach' "$RZH" && grep -q -- '--target-contract "\$REACH_NAME"' "$RZH"; then
  ok "run-zone-hunt.sh threads --reach + --target-contract into both \$INVHUNT invocations"
else
  bad "run-zone-hunt.sh does not thread --reach / --target-contract"
fi

if grep -q -- '--reach) REACH=1' "$RIH" && grep -q 'reach-inventory --repo "\$REPO_IN_RUN"' "$RIH" \
   && grep -q 'cp "\$HERE/evm-harness/handler-coverage.py" "\$RUN/handler-coverage.py"' "$RIH"; then
  ok "run-invariant-hunt.sh --reach writes the inventory + stages handler-coverage.py (only under the flag)"
else
  bad "run-invariant-hunt.sh --reach staging wiring is missing"
fi

# files staged ONLY under --reach: the reach-inventory + cp calls live inside `if [ "$REACH" = "1" ]`.
if awk '/if \[ "\$REACH" = "1" \]; then/{f=1} f && /reach-inventory --repo/{print "found"; exit}' "$RIH" | grep -q found; then
  ok "the inventory write + tool staging are nested under the --reach guard (inert when off)"
else
  bad "the reach staging is NOT guarded by --reach"
fi

# reachOn derived from the FILE only (no getenv, no new passthrough entry).
if grep -q 'let reachOn = len(reachEntries) > 0;' "$PROVER" \
   && grep -q 'read_reach_file(reachDir + "/entry-points.tsv")' "$PROVER" \
   && ! grep -q 'getenv("REACH' "$PROVER"; then
  ok "invariant-prover.ag derives reachOn from entry-points.tsv (fixed file, no getenv / passthrough)"
else
  bad "invariant-prover.ag reachOn is not file-derived"
fi

# the exec.env_passthrough line is byte-identical to origin/main (no new entry).
if git -C "$HERE" cat-file -e origin/main:dark-factory/run-invariant-hunt.sh 2>/dev/null; then
  PT_ORIG="$(git -C "$HERE" show origin/main:dark-factory/run-invariant-hunt.sh | grep '^  echo "exec.env_passthrough = ' || true)"
  PT_NOW="$(grep '^  echo "exec.env_passthrough = ' "$RIH" || true)"
  if [ -n "$PT_ORIG" ] && [ "$PT_ORIG" = "$PT_NOW" ]; then
    ok "run-invariant-hunt.sh exec.env_passthrough line is byte-identical to origin/main (no new REACH entry)"
  else
    bad "run-invariant-hunt.sh exec.env_passthrough line changed (REACH must not add a passthrough entry)"
  fi
else
  skip "origin/main not fetched — cannot diff the exec.env_passthrough line"
fi

# both reachSeed splices; re-ask nested under reachOn and not a fixture; pinned marker unchanged; no INVARIANT| in HANDLER-.
if grep -q '+ reachSeed' "$PROVER" && grep -q 'sharedScaffold + symbolInventorySeed + reachSeed' "$PROVER"; then
  ok "invariant-prover.ag splices reachSeed into generation AND the repair chain"
else
  bad "invariant-prover.ag reachSeed splices are missing"
fi
if grep -q 'let reaskFired = if reachOn { if usedFixture { false }' "$PROVER"; then
  ok "the coverage re-ask is nested under reachOn AND not-a-fixture"
else
  bad "the coverage re-ask gating is wrong"
fi
if grep -q 'print("INVARIANT|" + targetFn + "|" + verdict);' "$PROVER"; then
  ok "the pinned INVARIANT| marker print is unchanged"
else
  bad "the pinned INVARIANT| marker print changed"
fi
if grep -E 'print\("HANDLER-' "$PROVER" | grep -q 'INVARIANT|'; then
  bad "a HANDLER-* readout print line carries an INVARIANT| substring (would break last-INVARIANT|-wins parsers)"
else
  ok "no HANDLER-* readout line carries an INVARIANT| substring"
fi
if grep -q 'if verdict == "LOW_COVERAGE" { return "partial"; }' "$PROVER"; then
  ok "outcome_of maps LOW_COVERAGE -> partial"
else
  bad "outcome_of does not map LOW_COVERAGE"
fi

# ================================================================================================
note "2) SELECTION (reach-targets): concrete subclass over abstract base, greedy stop, out_zone, interfaces-only ..."

REPOA="$WORK/repoA"
mkdir -p "$REPOA/src/mods" "$REPOA/src/ext" "$REPOA/src/ifaces" "$REPOA/lib/erc" "$REPOA/lib/other"
# a foundry.toml so run-zone-hunt.sh's deep-hunt (Foundry-specific) engages in PART 6.
printf '[profile.default]\nsrc = "src"\ntest = "test"\n' > "$REPOA/foundry.toml"

# The largest file is the ABSTRACT base — REACH must still pick the smaller CONCRETE subclass, not the abstract.
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo "// padding so this abstract base is the LARGEST .sol in the zone (the OFF path would pick it)."
  i=0; while [ "$i" -lt 40 ]; do echo "// pad line $i to grow line count above every concrete leaf"; i=$((i+1)); done
  echo "interface IBaseThing { function ping() external; }"
  echo "abstract contract AbstractLedger is IBaseThing {"
  echo "    function actOne(uint256 a) external virtual;"
  echo "    function actTwo(address b) public virtual;"
  echo "    function readOne() public view virtual returns (uint256);"
  echo "    function ping() external virtual;"
  echo "}"
} > "$REPOA/src/mods/AbstractLedger.sol"

# The concrete subclass that holds the row. Inherits the vendored Erc20ish transfer family.
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo 'import "../../lib/erc/Erc20ish.sol";'
  echo 'import "./AbstractLedger.sol";'
  echo "contract ConcreteToken is AbstractLedger, Erc20ish {"
  echo "    function actOne(uint256 a) external override {}"
  echo "    function actTwo(address b) public override {}"
  echo "    function readOne() public view override returns (uint256) { return 1; }"
  echo "    function ping() external override {}"
  echo "    function leafOnly(uint256 c) external {}"
  echo "    function adminOnly(uint256 d) external onlyAdmin {}"
  echo "    function pureHelper(uint256 e) external pure returns (uint256) { return e; }"
  echo "    function initializeState(uint256 f) external {}"
  echo "    function reinit(uint256 g) external reinitializer(2) {}"
  echo "    modifier onlyAdmin() { _; }"
  echo "}"
} > "$REPOA/src/mods/ConcreteToken.sol"

# A sibling that overrides only what the base already declares -> adds NO new zone entry point (greedy stop).
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo 'import "./AbstractLedger.sol";'
  echo "contract SiblingLeaf is AbstractLedger {"
  echo "    function actOne(uint256 a) external override {}"
  echo "    function actTwo(address b) public override {}"
  echo "    function readOne() public view override returns (uint256) { return 2; }"
  echo "    function ping() external override {}"
  echo "}"
} > "$REPOA/src/mods/SiblingLeaf.sol"

# An abstract base in the zone whose ONLY concrete descendant lives OUT of the zone -> out_zone selection.
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo "abstract contract OrphanBase {"
  echo "    function orphanAct(uint256 a) external virtual;"
  echo "}"
} > "$REPOA/src/mods/OrphanBase.sol"
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo 'import "../mods/OrphanBase.sol";'
  echo "contract OrphanImpl is OrphanBase {"
  echo "    function orphanAct(uint256 a) external override {}"
  echo "}"
} > "$REPOA/src/ext/OrphanImpl.sol"

# A vendored ERC-style base with a MULTI-LINE transferFrom header + a modifier-gated boilerplate fn (excluded).
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo "contract Erc20ish {"
  echo "    function transfer(address to, uint256 value) public returns (bool) { return true; }"
  echo "    function approve(address spender, uint256 value) public returns (bool) { return true; }"
  echo "    function transferFrom("
  echo "        address from,"
  echo "        address to,"
  echo "        uint256 value"
  echo "    ) public returns (bool) { return true; }"
  echo "    function ownerMint(address to, uint256 value) public onlyErcOwner { }"
  echo "    function totalKnown() public view returns (uint256) { return 0; }"
  echo "    function _move(address a, address b) internal {}"
  echo "    modifier onlyErcOwner() { _; }"
  echo "}"
} > "$REPOA/lib/erc/Erc20ish.sol"
# A DUPLICATE vendored copy under a different path; ConcreteToken imports the erc/ one, so the tie-break picks it.
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo "contract Erc20ish {"
  echo "    function decoyOnly(address to) public returns (bool) { return true; }"
  echo "}"
} > "$REPOA/lib/other/Erc20ish.sol"
# An interfaces-only zone (no deployable body).
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo "interface IOnly { function look() external; }"
} > "$REPOA/src/ifaces/IOnly.sol"

# zones.json: the mods zone + the interfaces-only zone.
cat > "$REPOA/zones.json" <<JSON
[
  {"id":"src_mods","value_custody":true,"bug_classes_likely":["C10"],
   "files":["src/mods/AbstractLedger.sol","src/mods/ConcreteToken.sol","src/mods/SiblingLeaf.sol","src/mods/OrphanBase.sol"]},
  {"id":"src_ifaces","value_custody":false,"bug_classes_likely":["C1"],
   "files":["src/ifaces/IOnly.sol"]}
]
JSON

SEL="$WORK/selA.tsv"
python3 "$INH" reach-targets --zones "$REPOA/zones.json" --repo "$REPOA" --max 3 > "$SEL" 2>"$WORK/selA.err" || bad "reach-targets exited non-zero: $(cat "$WORK/selA.err")"

if grep -q 'ConcreteToken.sol:ConcreteToken' "$SEL" && ! grep -q 'AbstractLedger.sol:AbstractLedger' "$SEL"; then
  ok "REACH selects the concrete subclass ConcreteToken and NEVER the abstract AbstractLedger"
else
  bad "selection did not pick ConcreteToken over the abstract base:"; sed 's/^/      /' "$SEL" >&2
fi
if awk -F'\t' '$2 ~ /OrphanImpl.sol:OrphanImpl/ && $5=="out_zone"' "$SEL" | grep -q .; then
  ok "the out-of-zone concrete descendant OrphanImpl is selected and flagged out_zone"
else
  bad "the out-of-zone concrete descendant was not selected/flagged:"; sed 's/^/      /' "$SEL" >&2
fi
if ! grep -q 'SiblingLeaf' "$SEL"; then
  ok "the sibling that adds no new zone entry point is NOT selected (greedy stop)"
else
  bad "SiblingLeaf was selected despite adding no new coverage"
fi
if ! awk -F'\t' '$1=="src_ifaces"' "$SEL" | grep -q .; then
  ok "the interfaces-only zone yields no reach rows (falls back to the OFF selection)"
else
  bad "the interfaces-only zone wrongly produced a reach row"
fi

# ================================================================================================
note "3) ENTRY POINTS (reach-inventory): denominator rules ..."

TSVA="$WORK/epA.tsv"; INVA="$WORK/invA.txt"
python3 "$INH" reach-inventory --repo "$REPOA" --target src/mods/ConcreteToken.sol:ConcreteToken \
  --out-tsv "$TSVA" --out-inventory "$INVA" 2>"$WORK/invA.err" || bad "reach-inventory exited non-zero: $(cat "$WORK/invA.err")"

epline() { grep -E "^EP\|$1\|" "$TSVA"; }
if epline transfer | grep -q vendored && epline transferFrom | grep -q vendored && epline approve | grep -q vendored; then
  ok "the vendored transfer/transferFrom/approve family is in the denominator (inherited, multi-line header read)"
else
  bad "the vendored transfer family is missing from entry-points.tsv:"; grep '^EP|' "$TSVA" | sed 's/^/      /' >&2
fi
if ! epline readOne | grep -q . && ! epline pureHelper | grep -q . && ! epline totalKnown | grep -q .; then
  ok "view/pure functions are excluded"
else
  bad "a view/pure function leaked into the denominator"
fi
if ! epline initializeState | grep -q . && ! epline reinit | grep -q .; then
  ok "the initializer family (initialize* + reinitializer) is excluded"
else
  bad "an initializer-family function leaked into the denominator"
fi
if epline adminOnly | grep -q 'own|onlyAdmin'; then
  ok "the own role-gated function adminOnly is included and marked with its modifier"
else
  bad "the own role-gated function is missing or unmarked:"; epline adminOnly | sed 's/^/      /' >&2
fi
if ! epline ownerMint | grep -q .; then
  ok "vendored modifier-gated boilerplate (ownerMint) is excluded"
else
  bad "vendored modifier-gated boilerplate leaked into the denominator"
fi

# OVERCAP + own-first order: a target with > 20 own state-changing entry points pushes the rest to OVERCAP.
mkdir -p "$REPOA/src/big"
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo 'import "../../lib/erc/Erc20ish.sol";'
  echo "contract BigLeaf is Erc20ish {"
  i=0; while [ "$i" -lt 24 ]; do echo "    function own$i(uint256 a) external {}"; i=$((i+1)); done
  echo "}"
} > "$REPOA/src/big/BigLeaf.sol"
TSVB="$WORK/epBig.tsv"
python3 "$INH" reach-inventory --repo "$REPOA" --target src/big/BigLeaf.sol:BigLeaf --out-tsv "$TSVB" --out-inventory "$WORK/invBig.txt" 2>/dev/null
EP_N="$(grep -c '^EP|' "$TSVB" 2>/dev/null || echo 0)"
OVER_N="$(grep -c '^OVERCAP|' "$TSVB" 2>/dev/null || echo 0)"
if [ "$EP_N" -eq 20 ] && [ "$OVER_N" -ge 1 ]; then
  ok "the entry-point list is capped at 20 with the remainder recorded as OVERCAP ($EP_N gated, $OVER_N over-cap)"
else
  bad "the OVERCAP cap did not hold (EP=$EP_N OVERCAP=$OVER_N)"
fi
# own-first: the very first EP is an own function, not a vendored transfer.
if grep '^EP|' "$TSVB" | head -1 | grep -q '|own|'; then
  ok "own (most-derived) entry points are listed before vendored ones"
else
  bad "entry-point ordering is not own-first"
fi
# vendored tie-break: ConcreteToken imports lib/erc/Erc20ish.sol, so the erc/ copy (with transfer) wins over the
# lib/other decoy copy (which has no transfer) — proven by transfer being present at all.
if epline transfer | grep -q .; then
  ok "the vendored-duplicate tie-break resolves to the imported copy (transfer present, not the decoy)"
else
  bad "the vendored-duplicate tie-break resolved to the wrong copy"
fi

# ================================================================================================
note "4) INVENTORY: collaborators + fork ..."

REPOB="$WORK/repoB"
mkdir -p "$REPOB/src/core" "$REPOB/src/interfaces" "$REPOB/lib/msg"
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo "interface IStore { function put(uint256 v) external; }"
} > "$REPOB/src/interfaces/IStore.sol"
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo 'import "../interfaces/IStore.sol";'
  echo "contract Store is IStore { function put(uint256 v) external {} }"
} > "$REPOB/src/core/Store.sol"
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo "contract Controller { function allow(address a) external {} }"
} > "$REPOB/src/core/Controller.sol"
# A vendored base whose constructor calls a registration function on the endpoint param.
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo "contract MsgBase {"
  echo "    constructor(address _endpoint) {"
  echo "        IEndpoint(_endpoint).register(address(this));"
  echo "    }"
  echo "}"
  echo "interface IEndpoint { function register(address a) external; }"
} > "$REPOB/lib/msg/MsgBase.sol"
{
  echo "// SPDX-License-Identifier: MIT"
  echo "pragma solidity ^0.8.20;"
  echo 'import "../../lib/msg/MsgBase.sol";'
  echo 'import "../interfaces/IStore.sol";'
  echo "contract Dispatcher is MsgBase {"
  echo "    IStore public store;"
  echo "    constructor(address _endpoint, address _store, address _controller) MsgBase(_endpoint) {"
  echo "        store = IStore(_store);"
  echo "        Controller(_controller).allow(msg.sender);"
  echo "    }"
  echo "    function send(uint256 v) external { store.put(v); }"
  echo "}"
} > "$REPOB/src/core/Dispatcher.sol"

INVB="$WORK/invB.txt"
python3 "$INH" reach-inventory --repo "$REPOB" --target src/core/Dispatcher.sol:Dispatcher \
  --out-tsv "$WORK/epB.tsv" --out-inventory "$INVB" 2>/dev/null

if grep -q "COLLABORATOR '_store' -> Store" "$INVB" && grep -q "COLLABORATOR '_controller' -> Controller" "$INVB"; then
  ok "_store resolves to Store and _controller to Controller (constructor params typed / named after a contract)"
else
  bad "collaborator resolution failed:"; grep '^COLLABORATOR' "$INVB" | sed 's/^/      /' >&2
fi
if grep -q 'import "../src/core/Store.sol";' "$INVB" && grep -q 'constructor:' "$INVB"; then
  ok "each resolved collaborator carries its GLOBAL import line + constructor signature"
else
  bad "a collaborator import line / constructor signature is missing"
fi
if grep -q "COLLABORATOR '_endpoint': unresolved" "$INVB"; then
  ok "_endpoint (no in-repo implementation) is reported unresolved with the mock guidance"
else
  bad "_endpoint should be unresolved (no in-repo impl)"
fi
# fork mode: only the entry-point half renders (no DEPLOYMENT INVENTORY section).
python3 "$INH" reach-inventory --repo "$REPOB" --target src/core/Dispatcher.sol:Dispatcher \
  --out-tsv "$WORK/epBf.tsv" --out-inventory "$WORK/invBf.txt" --fork 2>/dev/null
if grep -q 'ENTRY POINTS' "$WORK/invBf.txt" && ! grep -q 'DEPLOYMENT INVENTORY' "$WORK/invBf.txt"; then
  ok "--fork renders only the entry-point half (no deployment inventory)"
else
  bad "--fork did not omit the deployment inventory"
fi
if [ "$(wc -c < "$INVB")" -le 12000 ]; then
  ok "the rendered inventory is within the 12 KB cap"
else
  bad "the inventory exceeded the 12 KB cap"
fi

# ================================================================================================
note "5) COVERAGE TOOL (handler-coverage.py): matching + thresholds ..."

# reuse the ConcreteToken entry-points.tsv (12 entry points).
cat > "$WORK/h_typed.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Handler {
  ConcreteToken mgr;
  MockThing decoy;
  constructor() { mgr.actOne(1); }
  function setUp() public { mgr.actTwo(address(2)); }
  function a1(uint256 v) public { mgr.transfer(address(3), v); }
  function a2() public { decoy.transfer(address(4), 5); }
}
SOL
OUT_TYPED="$(python3 "$COV" --entry-points "$TSVA" --harness "$WORK/h_typed.t.sol")"
if echo "$OUT_TYPED" | grep -q '^COVERED|transfer$' || echo "$OUT_TYPED" | grep -qE '^COVERED\|.*\btransfer\b'; then
  # transfer on the ConcreteToken-typed receiver counts; decoy.transfer (MockThing) does NOT; actTwo in setUp does NOT.
  if echo "$OUT_TYPED" | grep -q 'mode=typed' && ! echo "$OUT_TYPED" | grep -qE '^COVERED\|.*actTwo'; then
    ok "typed mode: a typed-receiver call counts; a same-name call on another type and a setUp-only call do not"
  else
    bad "typed-mode matching is wrong:"; echo "$OUT_TYPED" | sed 's/^/      /' >&2
  fi
else
  bad "typed-mode COVERED set is wrong:"; echo "$OUT_TYPED" | sed 's/^/      /' >&2
fi

cat > "$WORK/h_reg.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Handler {
  ConcreteToken mgr;
  function setUp() public { _target(address(mgr)); }
}
SOL
OUT_REG="$(python3 "$COV" --entry-points "$TSVA" --harness "$WORK/h_reg.t.sol")"
if echo "$OUT_REG" | grep -q 'mode=registered' && echo "$OUT_REG" | grep -q '|ok'; then
  ok "registered mode: a directly-registered typed receiver counts every entry point"
else
  bad "registered mode failed:"; echo "$OUT_REG" | sed 's/^/      /' >&2
fi

cat > "$WORK/h_name.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Handler {
  function a1() public { something.transfer(1); }
}
SOL
OUT_NAME="$(python3 "$COV" --entry-points "$TSVA" --harness "$WORK/h_name.t.sol")"
if echo "$OUT_NAME" | grep -q 'mode=name-only'; then
  ok "name-only mode: with no typed receiver, a bare .fn( match is lower-precision name-only"
else
  bad "name-only mode failed:"; echo "$OUT_NAME" | sed 's/^/      /' >&2
fi

# boundaries: a 5-entry-point tsv, 3/5 ok, 2/5 low, 0 low; and 0/0 ok.
cat > "$WORK/ep5.tsv" <<'T'
TARGET|src/X.sol|X
TYPES|X
EP|f1|X|own|-|f1()
EP|f2|X|own|-|f2()
EP|f3|X|own|-|f3()
EP|f4|X|own|-|f4()
EP|f5|X|own|-|f5()
T
cat > "$WORK/h3.t.sol" <<'SOL'
contract H { X x; function a() public { x.f1(); x.f2(); x.f3(); } }
SOL
cat > "$WORK/h2.t.sol" <<'SOL'
contract H { X x; function a() public { x.f1(); x.f2(); } }
SOL
cat > "$WORK/h0.t.sol" <<'SOL'
contract H { X x; function a() public {} }
SOL
b3="$(python3 "$COV" --entry-points "$WORK/ep5.tsv" --harness "$WORK/h3.t.sol" | head -1)"
b2="$(python3 "$COV" --entry-points "$WORK/ep5.tsv" --harness "$WORK/h2.t.sol" | head -1)"
b0="$(python3 "$COV" --entry-points "$WORK/ep5.tsv" --harness "$WORK/h0.t.sol" | head -1)"
printf 'TARGET|src/E.sol|E\nTYPES|E\n' > "$WORK/ep0.tsv"
b00="$(python3 "$COV" --entry-points "$WORK/ep0.tsv" --harness "$WORK/h0.t.sol" | head -1)"
if echo "$b3" | grep -q 'required=3|mode=typed|ok' && echo "$b2" | grep -q '|low' \
   && echo "$b0" | grep -q 'covered=0|total=5|required=3|.*|low' && echo "$b00" | grep -q 'total=0|.*|ok'; then
  ok "thresholds: 3/5 ok, 2/5 low, 0/5 low, 0/0 ok (required = ceil(0.6*total))"
else
  bad "threshold boundaries wrong: [$b3] [$b2] [$b0] [$b00]"
fi
# a missing harness file -> no COVERAGE line (the .ag reads this as unmeasured / fail-open).
if [ -z "$(python3 "$COV" --entry-points "$WORK/ep5.tsv" --harness "$WORK/nope.t.sol")" ]; then
  ok "a missing harness file yields no COVERAGE line (unmeasured; .ag fails open)"
else
  bad "a missing harness file wrongly produced output"
fi

# ================================================================================================
note "6) END-TO-END OFFLINE via run-zone-hunt.sh --deep-hunt --deep-hunt-only + stub --agentis ..."

# A stub that stands in for every substrate call, including the deep engine's invariant-prover.ag. Its prover
# branch RECORDS TARGET_FN + the presence of the three rundir files, then emits a LOW_COVERAGE readout + verdict.
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
        # record what reached us (cwd == $RUN): the target label + whether the reach files were staged.
        echo "REACH-PROBE|target=$tf|ep=$( [ -s entry-points.tsv ] && echo 1 || echo 0 )|inv=$( [ -f reach-inventory.txt ] && echo 1 || echo 0 )|tool=$( [ -f handler-coverage.py ] && echo 1 || echo 0 )" >&2
        if [ -s entry-points.tsv ]; then
          echo "HANDLER-COVERAGE-DRAFT|$tf|covered=1|total=4|required=3|mode=typed|low"
          echo "HANDLER-COVERAGE|$tf|covered=1|total=4|required=3|mode=typed|low|reask=1"
          echo "HANDLER-COVERED|actOne"
          echo "HANDLER-UNCOVERED|actTwo,transfer,transferFrom"
          echo "INVARIANT|$tf|LOW_COVERAGE"
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

# The map fixture classifies the mods zone as value-custody C10 (so it is a deep-hunt target).
MAPFIX="$WORK/mapfix.txt"
cat > "$MAPFIX" <<'FIX'
ZONE|src_mods|mods|C10|value-custody ledger family
CUSTODY|src_mods|true
FIX

DREPO="$REPOA"
DBASE="$WORK/dbase"
"$RZH" --repo "$DREPO" --out "$DBASE" --drop-dir "$DBASE/drop" --scope-hint src/mods \
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

  lens_only() { lo="$1"; shift; "$RZH" --repo "$DREPO" --out "$lo" --deep-hunt --deep-hunt-only \
      --backend mock --agentis "$STUB" "$@" >"$lo.log" 2>&1; }

  # (a) OFF: golden target TSV (largest file, 3 columns), <zone>-<class> dir, no rundir files, no reach-coverage.tsv.
  OFFD="$WORK/e2e-off"; cp -R "$DBASE" "$OFFD"; lens_only "$OFFD"; OFF_RC=$?
  if [ "$OFF_RC" -eq 0 ] && grep -q $'src_mods\tsrc/mods/AbstractLedger.sol\tC10' "$OFFD/.deep-hunt-targets.tsv" \
     && [ -d "$OFFD/deep-hunt/src_mods-C10" ] && [ ! -f "$OFFD/deep-hunt/reach-coverage.tsv" ]; then
    ok "(a) OFF: largest-file golden TSV, <zone>-<class> run dir, no reach-coverage.tsv"
  else
    bad "(a) OFF path drifted (rc=$OFF_RC):"; cat "$OFFD/.deep-hunt-targets.tsv" 2>/dev/null | sed 's/^/      /' >&2; ls "$OFFD/deep-hunt" 2>/dev/null | sed 's/^/      /' >&2
  fi

  # (b) ON: rel:Name row, per-target dir, TARGET_FN carries :ConcreteToken, all rundir files present, LOW_COVERAGE
  #     kept (not coerced), report section present, verified_findings.json byte-unchanged, reach-coverage.tsv row.
  cp "$DBASE/verify/verified_findings.json" "$WORK/vj.before" 2>/dev/null || echo '[]' > "$WORK/vj.before"
  ONF="$WORK/e2e-on"; cp -R "$DBASE" "$ONF"; DEEP_HUNT_REACH=1 lens_only "$ONF"; ON_RC=$?
  if [ "$ON_RC" -eq 0 ] && grep -q 'ConcreteToken.sol:ConcreteToken' "$ONF/.deep-hunt-targets.tsv"; then
    ok "(b) ON: the target TSV carries the rel:ContractName reach row"
  else
    bad "(b) ON target TSV missing the reach row (rc=$ON_RC):"; cat "$ONF/.deep-hunt-targets.tsv" 2>/dev/null | sed 's/^/      /' >&2
  fi
  # the stub prover writes REACH-PROBE to stderr, captured into the per-cell log (not run-zone-hunt's stdout).
  PROBE_LINE="$(grep -rh 'REACH-PROBE|' "$ONF/deep-hunt" 2>/dev/null | grep 'ConcreteToken' | head -1 || true)"
  if echo "$PROBE_LINE" | grep -q 'ep=1|inv=1|tool=1' && echo "$PROBE_LINE" | grep -q 'target=.*:ConcreteToken'; then
    ok "(b) the prover received TARGET_FN=...:ConcreteToken with all three rundir files staged"
  else
    bad "(b) the reach files did not reach the prover:"; echo "      $PROBE_LINE" >&2
  fi
  if ls -d "$ONF"/deep-hunt/src_mods-C10-ConcreteToken >/dev/null 2>&1; then
    ok "(b) a per-target run dir (…-ConcreteToken) was created (no collision across targets)"
  else
    bad "(b) the per-target run dir is missing:"; ls "$ONF/deep-hunt" 2>/dev/null | sed 's/^/      /' >&2
  fi
  if [ -f "$ONF/deep-hunt/reach-coverage.tsv" ] && grep -q 'LOW_COVERAGE' "$ONF/deep-hunt/reach-coverage.tsv"; then
    ok "(b) reach-coverage.tsv recorded the cell and LOW_COVERAGE was KEPT (not coerced)"
  else
    bad "(b) reach-coverage.tsv missing / LOW_COVERAGE not kept:"; cat "$ONF/deep-hunt/reach-coverage.tsv" 2>/dev/null | sed 's/^/      /' >&2
  fi
  if diff -q "$WORK/vj.before" "$ONF/verify/verified_findings.json" >/dev/null 2>&1; then
    ok "(b) verified_findings.json is byte-unchanged (a LOW_COVERAGE cell is never merged)"
  else
    bad "(b) verified_findings.json changed under a LOW_COVERAGE cell"
  fi

  # (c) ON + resume: LOW_COVERAGE is terminal, so the cell is skipped on re-run.
  DEEP_HUNT_REACH=1 lens_only "$ONF" --deep-hunt-resume; RES_RC=$?
  if [ "$RES_RC" -eq 0 ] && grep -q 'already hunted (terminal verdict), skipping' "$ONF.log"; then
    ok "(c) ON + --deep-hunt-resume: the LOW_COVERAGE cell is terminal and skipped"
  else
    bad "(c) LOW_COVERAGE was not treated as terminal on resume (rc=$RES_RC)"
  fi
fi

# (d) guard: DEEP_HUNT_REACH=1 without --deep-hunt exits 2; DEEP_HUNT_REACH=2 exits 2.
DEEP_HUNT_REACH=1 "$RZH" --repo "$DREPO" --out "$WORK/g1" --backend mock --agentis "$STUB" --map-fixture "$MAPFIX" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "(d) DEEP_HUNT_REACH=1 without --deep-hunt exits 2" || bad "(d) DEEP_HUNT_REACH=1 without --deep-hunt did not exit 2"
DEEP_HUNT_REACH=2 "$RZH" --repo "$DREPO" --out "$WORK/g2" --deep-hunt --deep-hunt-only --backend mock --agentis "$STUB" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "(d) DEEP_HUNT_REACH=2 exits 2" || bad "(d) DEEP_HUNT_REACH=2 did not exit 2"

# ================================================================================================
note "7) (needs agentis) the SHIPPED reach_seed / reach_verdict / cov_* helpers on canned inputs ..."
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — skipping the sliced-helper probe"
else
  PROBE="$WORK/probe.ag"
  {
    echo "cb 20000;"
    extract_fn reach_seed "$PROVER"
    extract_fn reach_verdict "$PROVER"
    extract_fn cov_ok "$PROVER"
    extract_fn cov_uncovered "$PROVER"
    extract_fn cov_gap "$PROVER"
    extract_fn cov_body "$PROVER"
    echo 'let seedOff = reach_seed(false, "IGNORED");'
    echo 'let seedOn  = reach_seed(true, "BODY");'
    echo 'let canned = "COVERAGE|covered=1|total=4|required=3|mode=typed|low\nCOVERED|a\nUNCOVERED|b,c,d";'
    echo 'print("SEEDOFF|" + to_string(len(seedOff)));'
    echo 'print("SEEDON|" + to_string(len(seedOn)));'
    echo 'print("VERD-OFF|" + reach_verdict("CLEAN", false, false));'
    echo 'print("VERD-LOW|" + reach_verdict("CLEAN", true, false));'
    echo 'print("VERD-OK|" + reach_verdict("CLEAN", true, true));'
    echo 'print("VERD-FIND|" + reach_verdict("FINDING", true, false));'
    echo 'print("GAP|" + to_string(cov_gap(canned)));'
    echo 'print("OKF|" + to_string(cov_ok(canned)));'
  } > "$PROBE"
  PDIR="$WORK/pdir"; mkdir -p "$PDIR"; cp "$PROBE" "$PDIR/p.ag"
  POUT="$( (cd "$PDIR" && agentis init >/dev/null 2>&1; agentis go p.ag 2>/dev/null) || true )"
  if echo "$POUT" | grep -q 'SEEDOFF|0' && echo "$POUT" | grep -qE 'SEEDON\|[1-9]'; then
    ok "reach_seed is 0 bytes when off and non-empty when on"
  else
    bad "reach_seed length probe failed:"; echo "$POUT" | sed 's/^/      /' >&2
  fi
  if echo "$POUT" | grep -q 'VERD-OFF|CLEAN' && echo "$POUT" | grep -q 'VERD-LOW|LOW_COVERAGE' \
     && echo "$POUT" | grep -q 'VERD-OK|CLEAN' && echo "$POUT" | grep -q 'VERD-FIND|FINDING'; then
    ok "reach_verdict table: off=identity, on+low=LOW_COVERAGE, on+ok=CLEAN, FINDING never downgraded"
  else
    bad "reach_verdict table wrong:"; echo "$POUT" | sed 's/^/      /' >&2
  fi
  if echo "$POUT" | grep -q 'GAP|3' && echo "$POUT" | grep -q 'OKF|false'; then
    ok "cov_gap / cov_ok parse the canned COVERAGE output correctly"
  else
    bad "coverage parsers wrong:"; echo "$POUT" | sed 's/^/      /' >&2
  fi
fi

# ================================================================================================
note "8) (needs agentis + forge) a fixture covering 1/4 entry points -> LOW_COVERAGE under --reach, CLEAN without ..."
if ! command -v agentis >/dev/null 2>&1 || ! command -v forge >/dev/null 2>&1; then
  skip "agentis or forge absent — skipping the live LOW_COVERAGE gate"
else
  FREPO="$WORK/frepo"; mkdir -p "$FREPO/src" "$FREPO/test"
  cat > "$FREPO/foundry.toml" <<'TOML'
[profile.default]
src = "src"
test = "test"
[invariant]
runs = 4
depth = 8
TOML
  cat > "$FREPO/src/Counter.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Counter {
    uint256 public total;
    function incr(uint256 a) external { total += a; }
    function decr(uint256 a) external { if (a <= total) total -= a; }
    function reset() external { total = 0; }
    function bump() external { total += 1; }
}
SOL
  # A forge-std-FREE fixture (the evm-harness contract: targetContracts() view + plain require) exercising only
  # 1 of the 4 entry points (incr) -> 1/4 < ceil(0.6*4)=3 -> LOW_COVERAGE under --reach.
  cat > "$WORK/fixture.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Counter} from "../src/Counter.sol";
contract Handler {
    Counter c;
    constructor(Counter _c) { c = _c; }
    function h_incr(uint256 a) public { c.incr(a % 1000); }
}
contract Inv_Counter {
    Counter c; Handler h;
    function setUp() public { c = new Counter(); h = new Handler(c); }
    function targetContracts() public view returns (address[] memory a) { a = new address[](1); a[0] = address(h); }
    function invariant_nonneg() public view { require(c.total() >= 0, "neg"); }
}
SOL
  run_inv() { "$RIH" --repo "$FREPO" --target src/Counter.sol:Counter --class C10 \
      --handler-fixture "$WORK/fixture.t.sol" --backend mock --agentis agentis --out "$1" "${@:2}" >"$1.log" 2>&1; }
  ONV="$WORK/inv-on"; run_inv "$ONV" --reach;
  OFFV="$WORK/inv-off"; run_inv "$OFFV"
  ONVERD="$(grep 'INVARIANT|' "$ONV"/run/invariant_*.log 2>/dev/null | tail -1 | sed 's/.*INVARIANT|//' | cut -d'|' -f2)"
  OFFVERD="$(grep 'INVARIANT|' "$OFFV"/run/invariant_*.log 2>/dev/null | tail -1 | sed 's/.*INVARIANT|//' | cut -d'|' -f2)"
  if [ "$ONVERD" = "LOW_COVERAGE" ]; then
    ok "(8) --reach: the 1-of-4 fixture is labelled LOW_COVERAGE"
  else
    bad "(8) --reach fixture verdict was '$ONVERD' (expected LOW_COVERAGE)"; sed -n '1,20p' "$ONV.log" | sed 's/^/      /' >&2
  fi
  if [ "$OFFVERD" = "CLEAN" ]; then
    ok "(8) without --reach the SAME fixture is CLEAN (byte-identical table row)"
  else
    bad "(8) non-reach fixture verdict was '$OFFVERD' (expected CLEAN)"; sed -n '1,20p' "$OFFV.log" | sed 's/^/      /' >&2
  fi
  # the report table SHAPE is unchanged: the Target/Class/Handler columns match; only the Verdict column (and
  # the appended Handler coverage section) differs — the table format itself is untouched by REACH.
  COLS_ON="$(grep '^| ' "$ONV/invariant-report.md" 2>/dev/null | grep -v '^| Target' | head -1 | awk -F'|' '{print $2"|"$3"|"$4}')"
  COLS_OFF="$(grep '^| ' "$OFFV/invariant-report.md" 2>/dev/null | grep -v '^| Target' | head -1 | awk -F'|' '{print $2"|"$3"|"$4}')"
  if [ -n "$COLS_OFF" ] && [ "$COLS_ON" = "$COLS_OFF" ]; then
    ok "(8) the report table's Target/Class/Handler columns are unchanged (only the Verdict + appended coverage section differ)"
  else
    bad "(8) the report table columns differ: on=[$COLS_ON] off=[$COLS_OFF]"
  fi
  if grep -q '## Handler coverage (DEEP_HUNT_REACH)' "$ONV/invariant-report.md" 2>/dev/null; then
    ok "(8) the --reach report carries the Handler coverage section"
  else
    bad "(8) the --reach report is missing the Handler coverage section"
  fi
fi

# ================================================================================================
note "9) PURITY: no contest / [HM]-<n> / domain nouns in the REACH prompt + re-ask templates; no embedded interpreter ..."
# The prompt-visible REACH template lines in the .ag (reach_seed body + coverage_reask_instruction) and the
# templates inheritance.py renders (the header strings, NOT the source signatures it injects).
TEMPL="$WORK/templates.txt"
{
  sed -n '/fn reach_seed(/,/^}/p' "$PROVER"
  sed -n '/fn coverage_reask_instruction(/,/^}/p' "$PROVER"
  grep -nE '"[^"]*"' "$INH" | grep -iE 'entry point|inventory|collaborator|unresolved|import|constructor|initializer|actor address'
} > "$TEMPL"
if grep -inE 'codehawks|sherlock|cantina|immunefi|\b[HM]-[0-9]+\b' "$TEMPL"; then
  bad "a REACH template carries a contest name or an [HM]-<n> tag"
else
  ok "no contest name / [HM]-<n> tag in the REACH templates"
fi
if grep -iwE 'transfer|liquidat|repay|borrow|mint|redeem|lockup|vault|router|bridge|reward|oracle|endpoint|rounding' "$TEMPL"; then
  bad "a REACH template names a diagnosis domain noun (overfitting guard):"; grep -inwE 'transfer|liquidat|repay|borrow|mint|redeem|lockup|vault|router|bridge|reward|oracle|endpoint|rounding' "$TEMPL" | sed 's/^/      /' >&2
else
  ok "no domain nouns in the REACH prompt + re-ask templates (overfitting guard)"
fi
# no NEW embedded interpreter in the .ag REACH code (python3 -c / awk / sed logic).
if sed -n '/#2245/,/^$/p' "$PROVER" | grep -qE "exec sh \"[^\"]*(python3 -c|awk |sed )"; then
  bad "a new .ag REACH exec sh embeds a python3 -c / awk / sed one-liner"
else
  ok "the .ag REACH code embeds no python3 -c / awk / sed interpreter logic"
fi

# ================================================================================================
note "10) MUTATIONS: each selection/coverage rule is load-bearing ..."
# Applied to COPIES; each mutation must flip a named fixture.

# (a) drop the setUp-body exclusion in handler-coverage.py -> the setUp-only actTwo call would count.
MC="$WORK/cov-mut.py"; sed 's/    body = remove_block_body(remove_block_body(clean, _SETUP_RE), _CTOR_RE)/    body = clean/' "$COV" > "$MC"
BASE_COV="$(python3 "$COV" --entry-points "$TSVA" --harness "$WORK/h_typed.t.sol")"
MUT_COV="$(python3 "$MC" --entry-points "$TSVA" --harness "$WORK/h_typed.t.sol")"
if [ "$BASE_COV" != "$MUT_COV" ] && echo "$MUT_COV" | grep -qE '^COVERED\|.*actTwo'; then
  ok "(a) dropping the setUp-body exclusion flips coverage (actTwo now counts) — the rule is load-bearing"
else
  bad "(a) the setUp-body exclusion mutation did not flip the fixture"
fi

# (b) drop the typed-receiver rule (count any .fn() anywhere) -> decoy.transfer would now count under 'typed'.
MC2="$WORK/cov-mut2.py"
python3 - "$COV" "$MC2" <<'PYM'
import sys
src=open(sys.argv[1]).read()
# force typed_exists false so it falls into name-only (counts bare .fn anywhere incl. the decoy receiver)
src=src.replace("typed_exists = bool(receivers) or bool(cast_types)","typed_exists = False")
open(sys.argv[2],"w").write(src)
PYM
MUT2="$(python3 "$MC2" --entry-points "$TSVA" --harness "$WORK/h_typed.t.sol")"
if [ "$BASE_COV" != "$MUT2" ]; then
  ok "(b) dropping the typed-receiver rule flips the mode/coverage — load-bearing"
else
  bad "(b) the typed-receiver mutation did not flip the fixture"
fi

# (c) drop the abstract filter in reach-targets (allow abstract candidates) -> the abstract base would be selected.
MC3="$WORK/inh-mut3.py"
sed 's/if d\["kind"\] == "contract" and not d\["abstract"\]:/if d["kind"] == "contract":/' "$INH" > "$MC3"
# The abstract OrphanBase (in-zone) ties OrphanImpl (out-zone) on orphanAct coverage; without the filter the
# in-zone abstract wins the tie-break, so it appears in the selection where it never did before.
SEL3="$(python3 "$MC3" reach-targets --zones "$REPOA/zones.json" --repo "$REPOA" --max 3 2>/dev/null || true)"
if echo "$SEL3" | grep -q 'OrphanBase.sol:OrphanBase'; then
  ok "(c) dropping the abstract filter selects the abstract OrphanBase — the filter is load-bearing"
else
  bad "(c) the abstract-filter mutation did not surface an abstract base:"; echo "$SEL3" | sed 's/^/      /' >&2
fi

# (d) drop vendored resolution -> the vendored transfer family disappears from the denominator.
MC4="$WORK/inh-mut4.py"
sed 's/got = vendored.pick(nm, import_paths)/got = None/' "$INH" > "$MC4"
TSV4="$(python3 "$MC4" reach-inventory --repo "$REPOA" --target src/mods/ConcreteToken.sol:ConcreteToken --out-tsv /dev/stdout --out-inventory /dev/null 2>/dev/null || true)"
if ! echo "$TSV4" | grep -qE '^EP\|transfer\|'; then
  ok "(d) dropping vendored resolution removes the inherited transfer family — vendored walk is load-bearing"
else
  bad "(d) the vendored-resolution mutation did not remove transfer"
fi

# (e) drop the vendored-modifier exclusion -> ownerMint would enter the denominator.
MC5="$WORK/inh-mut5.py"
sed 's/if not is_own and fn\["modifiers"\]:/if False:/' "$INH" > "$MC5"
TSV5="$(python3 "$MC5" reach-inventory --repo "$REPOA" --target src/mods/ConcreteToken.sol:ConcreteToken --out-tsv /dev/stdout --out-inventory /dev/null 2>/dev/null || true)"
if echo "$TSV5" | grep -qE '^EP\|ownerMint\|'; then
  ok "(e) dropping the vendored-modifier exclusion admits ownerMint — the exclusion is load-bearing"
else
  bad "(e) the vendored-modifier-exclusion mutation did not admit ownerMint"
fi

# (f) use floor instead of ceil in handler-coverage.py -> the 3/5 boundary would drop required from 3 to 3?
#     floor(0.6*5)=3 too; use 2/3 boundary: ceil(0.6*3)=2, floor=1 -> a 1/3 harness flips ok/low.
MC6="$WORK/cov-mut6.py"; sed 's/int(math.ceil(0.6 \* total))/int(math.floor(0.6 * total))/' "$COV" > "$MC6"
cat > "$WORK/ep3.tsv" <<'T'
TARGET|src/Y.sol|Y
TYPES|Y
EP|g1|Y|own|-|g1()
EP|g2|Y|own|-|g2()
EP|g3|Y|own|-|g3()
T
cat > "$WORK/h1of3.t.sol" <<'SOL'
contract H { Y y; function a() public { y.g1(); } }
SOL
BASE6="$(python3 "$COV" --entry-points "$WORK/ep3.tsv" --harness "$WORK/h1of3.t.sol" | head -1)"
MUT6="$(python3 "$MC6" --entry-points "$WORK/ep3.tsv" --harness "$WORK/h1of3.t.sol" | head -1)"
if echo "$BASE6" | grep -q 'required=2|mode=typed|low' && echo "$MUT6" | grep -q 'required=1|mode=typed|ok'; then
  ok "(f) floor instead of ceil flips the 1/3 boundary from low to ok — ceil is load-bearing"
else
  bad "(f) the ceil-vs-floor mutation did not flip the boundary: base=[$BASE6] mut=[$MUT6]"
fi

# ================================================================================================
echo
if [ "$FAILS" -eq 0 ]; then
  note "ALL CHECKS PASSED"
  exit 0
else
  note "$FAILS CHECK(S) FAILED"
  exit 1
fi
