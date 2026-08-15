#!/usr/bin/env bash
# tools/test-composition-surfaces.sh -- deterministic offline guard for #1914 M2 (dark-factory):
# composition-surface detection that aims the general-solvency (SYS-solvency) deep-hunt lens at the REAL
# value-consuming contract A and threads the value-producing contract(s) B as --aux, instead of M1's
# largest/next-largest BOOTSTRAP.
#
# lib/composition-surfaces.py (invoked by map-zones.sh, exactly like lib/inheritance.py) statically scans each
# zone's own Solidity sources for a cross-FILE seam: a contract A that assigns the return of an external call
# `b.foo()` into a settlement sink (transfer/mint/burn/balance-write), a before/after-hook return-delta, or a
# deposit/withdraw adapter round-trip against a producer contract B in a DIFFERENT zone file. It attaches an
# additive `composition_surfaces` list {consumer, producers, adversarial_actor, seam_class} -- option C: a zone
# with NO detected seam gains NO key (byte-identical). run-zone-hunt.sh's STAGE 4.5 reads it: when a zone
# carries a seam it targets the CONSUMER and auxes the PRODUCER(s); with no seam it falls through to the EXACT
# M1 bootstrap.
#
# Offline by construction: the whole pipeline is driven through the --map-fixture / --brief-fixture /
# --pass-fixture / --invariant-fixture seams plus the ONE --agentis stub the #1713 deep-hunt fixture ships. No
# LLM, no forge, no network. Auto-discovered and run by tools/colony-lint.sh's `tools/test-*.sh` loop.
#
# Assertions:
#   (u) UNIT: lib/composition-surfaces.py annotate fires on an A-consumes-B fixture (composition_surfaces with
#       the right consumer/producers/adversarial_actor) and does NOT fire on a zero-seam fixture (no key).
#   (a) MAP: the full map-zones.sh --fixture offline path over the seam fixture emits a zones.json whose seam
#       zone carries a composition_surfaces entry (consumer A, producer B).
#   (b) ROUTED: run-zone-hunt.sh --deep-hunt --composable-lens over the seam fixture emits ONE SYS-solvency row
#       whose TARGET is the CONSUMER A (NOT the largest .sol the bootstrap would pick) and whose aux column is
#       the PRODUCER B, and that row routes into run-invariant-hunt.sh (per-(zone,class) out-dir + staged aux).
#   (c) ZERO-SEAM: over a value-custody fixture with NO seam, zones.json gains NO composition_surfaces key AND
#       the SYS-solvency row uses the UNCHANGED M1 bootstrap (target = the zone's largest .sol).
#   (d) OFF: --composable-lens OFF over the SAME seam fixture yields a .deep-hunt-targets.tsv with NO
#       SYS-solvency row -- byte-identical to the M1 default-off behaviour.
#
# Usage: bash tools/test-composition-surfaces.sh
# Exit: 0 = held, 1 = regressed, 3 = missing prerequisite.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DF="$REPO_ROOT/dark-factory"
ZONEHUNT="$DF/run-zone-hunt.sh"
MAPZONES="$DF/map-zones.sh"
HELPER="$DF/lib/composition-surfaces.py"
FIX="$DF/bench/corpus-bench/fixtures/deep-hunt"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

summary_exit() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
}

[ -x "$ZONEHUNT" ] || { echo "[SKIP] run-zone-hunt.sh not found/executable: $ZONEHUNT" >&2; exit 3; }
[ -x "$MAPZONES" ] || { echo "[SKIP] map-zones.sh not found/executable: $MAPZONES" >&2; exit 3; }
[ -f "$HELPER" ]   || { echo "[SKIP] composition-surfaces.py not found: $HELPER" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
for f in foundry.toml briefs.fixture.txt handler-fixture.t.sol agentis-stub.sh src/Vault.sol; do
    [ -f "$FIX/$f" ] || { echo "[SKIP] deep-hunt fixture missing: $FIX/$f" >&2; exit 3; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/composition-surfaces.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# The seam fixture. A CONSUMER (PoolManager) reads a per-share price PRODUCED by a DIFFERENT zone file
# (Strategy) through an interface (IStrategy) and settles on it (a balance-write on the returned amount) -- the
# return-sink seam class, adversarial_actor "integrator" (the producer is pluggable via the interface). The
# PRODUCER is deliberately the LARGER .sol, so M1's largest-first bootstrap would pick Strategy as the target;
# a SYS-solvency row that targets PoolManager instead proves the seam detection overrode the bootstrap. Both
# carry the adapter/wrapper/oracle naming prior (Strategy/Vault/pool) the coarse pre-filter keys on.
# ----------------------------------------------------------------------------------------------------------
SEAM="$WORK/seam-target"
mkdir -p "$SEAM/src"
cp "$FIX/foundry.toml" "$SEAM/foundry.toml"
cat > "$SEAM/src/PoolManager.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// Value-CONSUMING contract of the pool: it reads a per-share price the Strategy PRODUCES and settles user
// balances against it. An adversary controlling the Strategy return can skew what a withdraw pays out.
interface IStrategy {
    function pricePerShare() external view returns (uint256);
}
contract PoolManager {
    IStrategy public strategy;
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    constructor(IStrategy s) { strategy = s; }
    function withdraw(uint256 amt) external returns (uint256 assets) {
        uint256 pps = strategy.pricePerShare(); // external producer read, captured...
        assets = amt * pps / 1e18;
        shares[msg.sender] -= amt;              // ...then settled on a balance write (the sink)
        totalShares -= amt;
    }
}
SOL
cat > "$SEAM/src/Strategy.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// Value-PRODUCING contract: the external position whose pricePerShare the pool trusts. Deliberately the LARGER
// .sol so the M1 largest-first bootstrap would pick IT as the SYS-solvency target -- the seam detection must
// override that and target the consumer instead.
interface IStrategy {
    function pricePerShare() external view returns (uint256);
}
contract Strategy is IStrategy {
    uint256 public managedAssets;
    uint256 public issuedShares;
    address public keeper;
    constructor() { keeper = msg.sender; }
    function pricePerShare() external view returns (uint256) {
        if (issuedShares == 0) return 1e18;
        return managedAssets * 1e18 / issuedShares;
    }
    function harvest(uint256 gain) external {
        require(msg.sender == keeper, "not keeper");
        managedAssets += gain;
    }
    function issue(uint256 s) external {
        require(msg.sender == keeper, "not keeper");
        issuedShares += s;
    }
    function retire(uint256 s) external {
        require(msg.sender == keeper, "not keeper");
        issuedShares -= s;
    }
}
SOL
git -C "$SEAM" init -q
git -C "$SEAM" config user.email demo@example.invalid
git -C "$SEAM" config user.name "demo"
git -C "$SEAM" add -A
git -C "$SEAM" commit -qm "composition seam fixture target"

# The map fixture: ONE value-custody zone `src` classified C6 (so run-zone-hunt selects it AND leaves lens
# headroom under the default max-lenses=2). Subsystem name is deliberately NOT "value vault", so the deep-hunt
# fixture's hunter stub emits SAFE (a clean breadth -- this test asserts selection, not breadth findings).
SEAM_MAP="$WORK/seam-zones.fixture.txt"
{
    echo "ZONE|src|composition seam|C6,C10|A consumes a value B produces"
    echo "CUSTODY|src|true"
} > "$SEAM_MAP"

# The zero-seam fixture: the deep-hunt Vault (Token+Vault in ONE file -> no cross-file seam) plus an INDEPENDENT
# co-system contract Vault never calls, so the zone is value-custody with two .sol but NO composition seam.
ZERO="$WORK/zero-target"
mkdir -p "$ZERO/src"
cp "$FIX/foundry.toml" "$ZERO/foundry.toml"
cp "$FIX/src/Vault.sol" "$ZERO/src/Vault.sol"
cat > "$ZERO/src/Ledger.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// A co-system contract in the SAME zone that the Vault neither calls nor is called by -- there is no seam, so
// the zone must fall through to the M1 largest/next-largest bootstrap. Named `Ledger` (no adapter/oracle
// naming prior), and smaller than Vault.sol, so the bootstrap target stays src/Vault.sol.
contract Ledger {
    mapping(address => uint256) public entries;
    function record(address who, uint256 v) external { entries[who] = v; }
}
SOL
git -C "$ZERO" init -q
git -C "$ZERO" config user.email demo@example.invalid
git -C "$ZERO" config user.name "demo"
git -C "$ZERO" add -A
git -C "$ZERO" commit -qm "zero-seam fixture target"

ZERO_MAP="$WORK/zero-zones.fixture.txt"
{
    echo "ZONE|src|value ledger|C6|value custody with no composition seam"
    echo "CUSTODY|src|true"
} > "$ZERO_MAP"

STUB="$WORK/agentis-stub"
cp "$FIX/agentis-stub.sh" "$STUB"; chmod +x "$STUB"

# ----------------------------------------------------------------------------------------------------------
# (u) UNIT: the helper fires on the seam fixture and is silent on the zero-seam fixture.
# ----------------------------------------------------------------------------------------------------------
cat > "$WORK/seam-mech.json" <<'JSON'
[{"id":"src","name":"src","files":["src/PoolManager.sol","src/Strategy.sol"],"scope_files":["src/PoolManager.sol","src/Strategy.sol"],"loc":40,"hardening_score":50}]
JSON
python3 "$HELPER" annotate --zones "$WORK/seam-mech.json" --repo "$SEAM" >"$WORK/seam-annot.json" 2>/dev/null
cat > "$WORK/zero-mech.json" <<'JSON'
[{"id":"src","name":"src","files":["src/Vault.sol","src/Ledger.sol"],"scope_files":["src/Vault.sol","src/Ledger.sol"],"loc":60,"hardening_score":50}]
JSON
python3 "$HELPER" annotate --zones "$WORK/zero-mech.json" --repo "$ZERO" >"$WORK/zero-annot.json" 2>/dev/null
if python3 - "$WORK/seam-annot.json" "$WORK/zero-annot.json" <<'PY'
import sys, json
seam = json.load(open(sys.argv[1], encoding="utf-8"))
zero = json.load(open(sys.argv[2], encoding="utf-8"))
z = {x["id"]: x for x in seam}["src"]
cs = z.get("composition_surfaces")
assert isinstance(cs, list) and len(cs) == 1, "seam zone did not get exactly one composition surface: %r" % cs
e = cs[0]
assert e["consumer"] == "src/PoolManager.sol", "wrong consumer: %r" % e["consumer"]
assert e["producers"] == ["src/Strategy.sol"], "wrong producers: %r" % e["producers"]
assert e["adversarial_actor"] == "integrator", "interface-typed producer must mark an integrator adversary: %r" % e["adversarial_actor"]
assert e["seam_class"] == "return-sink", "wrong seam class: %r" % e["seam_class"]
zz = {x["id"]: x for x in zero}["src"]
assert "composition_surfaces" not in zz, "zero-seam zone wrongly gained a composition_surfaces key: %r" % zz.get("composition_surfaces")
PY
then pass "(u) composition-surfaces.py fires on the A-consumes-B fixture (consumer PoolManager, producer Strategy, integrator adversary) and is silent (no key) on the zero-seam fixture"
else fail "(u) unit detection" "the helper's fire/no-fire behaviour is wrong"
fi

# ----------------------------------------------------------------------------------------------------------
# (a) MAP: the full map-zones.sh --fixture offline path attaches composition_surfaces to zones.json.
# ----------------------------------------------------------------------------------------------------------
MAP_OUT="$WORK/map-out"
"$MAPZONES" --repo "$SEAM" --out "$MAP_OUT" --fixture "$SEAM_MAP" >/dev/null 2>"$WORK/map.err"
MAP_RC=$?
if [ "$MAP_RC" -eq 0 ] && [ -f "$MAP_OUT/zones.json" ] && python3 - "$MAP_OUT/zones.json" <<'PY'
import sys, json
zones = {z["id"]: z for z in json.load(open(sys.argv[1], encoding="utf-8"))}
z = zones["src"]
cs = z.get("composition_surfaces")
assert isinstance(cs, list) and cs, "zones.json seam zone missing composition_surfaces: %r" % z.get("composition_surfaces")
assert cs[0]["consumer"] == "src/PoolManager.sol", "wrong consumer in zones.json: %r" % cs[0]["consumer"]
assert cs[0]["producers"] == ["src/Strategy.sol"], "wrong producers in zones.json: %r" % cs[0]["producers"]
# scope.tsv must be untouched by the additive key: the seam zone still ships with both files.
PY
then pass "(a) map-zones.sh --fixture attaches composition_surfaces (consumer src/PoolManager.sol, producer src/Strategy.sol) to zones.json"
else fail "(a) map-zones composition_surfaces" "map exit $MAP_RC; $(tail -3 "$WORK/map.err" | tr '\n' ' ')"
fi

# ----------------------------------------------------------------------------------------------------------
# Shared breadth base, then the STAGE 4.5 lens over clones of it (the #1774 --deep-hunt-only seam), so ON and
# OFF differ in EXACTLY the one flag under test. Same driving idiom as the M1 composable-lens test.
# ----------------------------------------------------------------------------------------------------------
breadth() {  # $1 = out dir, $2 = target repo, $3 = map fixture
    "$ZONEHUNT" --repo "$2" --out "$1" --drop-dir "$1/drop" --scope-hint src \
        --backend mock --agentis "$STUB" \
        --map-fixture "$3" --brief-fixture "$FIX/briefs.fixture.txt" \
        --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
        --in-scope "the whole in-scope program" >"$1.log" 2>&1
}
lens_only() {  # $1 = out dir (clone of a breadth base), $2 = target repo, $3.. = extra flags
    _o="$1"; _r="$2"; shift 2
    "$ZONEHUNT" --repo "$_r" --out "$_o" --deep-hunt --deep-hunt-only \
        --invariant-fixture "$FIX/handler-fixture.t.sol" \
        --backend mock --agentis "$STUB" "$@" >"$_o.log" 2>&1
}

SEAM_BASE="$WORK/seam-base"
breadth "$SEAM_BASE" "$SEAM" "$SEAM_MAP"; SEAM_BASE_RC=$?
if [ "$SEAM_BASE_RC" -ne 0 ]; then
    fail "seam breadth baseline" "run-zone-hunt.sh breadth run failed"
    tail -20 "$SEAM_BASE.log" | sed 's/^/      /' >&2
    summary_exit
fi

SEAM_ON="$WORK/seam-on"; cp -R "$SEAM_BASE" "$SEAM_ON"; lens_only "$SEAM_ON" "$SEAM" --composable-lens
SEAM_OFF="$WORK/seam-off"; cp -R "$SEAM_BASE" "$SEAM_OFF"; lens_only "$SEAM_OFF" "$SEAM"
TSV_ON="$SEAM_ON/.deep-hunt-targets.tsv"
TSV_OFF="$SEAM_OFF/.deep-hunt-targets.tsv"
if [ ! -f "$TSV_ON" ] || [ ! -f "$TSV_OFF" ]; then
    fail "seam lens runs" "target TSVs present: ON=$([ -f "$TSV_ON" ] && echo yes || echo no) OFF=$([ -f "$TSV_OFF" ] && echo yes || echo no)"
    tail -20 "$SEAM_ON.log" | sed 's/^/      /' >&2
    summary_exit
fi

# ----------------------------------------------------------------------------------------------------------
# (b) ROUTED: exactly one SYS-solvency row, target = the CONSUMER (not the larger Strategy the bootstrap would
# pick), aux = the PRODUCER, and it routes into run-invariant-hunt.sh in composable-fresh mode.
# ----------------------------------------------------------------------------------------------------------
b_fail=""
SYS_ROWS="$(awk -F'\t' '$3 == "SYS-solvency"' "$TSV_ON")"
SYS_COUNT="$(printf '%s' "$SYS_ROWS" | grep -c . || true)"
[ "$SYS_COUNT" -eq 1 ] || b_fail="${b_fail} sys-row-count=${SYS_COUNT}-want-1"
SYS_TARGET="$(printf '%s\n' "$SYS_ROWS" | awk -F'\t' 'NR==1 {print $2}')"
SYS_AUX="$(printf '%s\n' "$SYS_ROWS" | awk -F'\t' 'NR==1 {print $4}')"
[ "$SYS_TARGET" = "src/PoolManager.sol" ] || b_fail="${b_fail} sys-target=${SYS_TARGET:-<none>}-want-src/PoolManager.sol"
[ "$SYS_AUX" = "src/Strategy.sol" ] || b_fail="${b_fail} sys-aux=${SYS_AUX:-<empty>}-want-src/Strategy.sol"
# and prove the seam OVERRODE the bootstrap: the per-class C6 row still targets the LARGER Strategy.sol, so a
# SYS row on PoolManager cannot be the bootstrap accidentally agreeing.
PER_CLASS_TARGET="$(awk -F'\t' '$3 == "C6" {print $2; exit}' "$TSV_ON")"
[ "$PER_CLASS_TARGET" = "src/Strategy.sol" ] || b_fail="${b_fail} per-class-target=${PER_CLASS_TARGET:-<none>}-want-src/Strategy.sol(bootstrap-largest)"
DZOUT="$SEAM_ON/deep-hunt/src-SYS-solvency"
[ -d "$DZOUT" ] || b_fail="${b_fail} no-per-class-outdir[$DZOUT]"
AUX_STAGED="$(find "$DZOUT" -name 'aux-code-*.sol' 2>/dev/null | head -1)"
if [ -n "$AUX_STAGED" ]; then
    grep -q 'contract Strategy' "$AUX_STAGED" || b_fail="${b_fail} staged-aux-is-not-the-producer"
else
    b_fail="${b_fail} no-aux-staged-into-rundir"
fi
grep -q "target 'src/PoolManager.sol' (SYS-solvency)" "$SEAM_ON.log" || b_fail="${b_fail} no-deep-hunt-log-line-for-consumer"
if [ -z "$b_fail" ]; then
    pass "(b) the seam routes the SYS-solvency lens onto the CONSUMER src/PoolManager.sol with aux src/Strategy.sol (while the per-class C6 row still targets the larger Strategy.sol -- the bootstrap was overridden), and it reaches run-invariant-hunt.sh in composable-fresh mode"
else
    fail "(b) seam-routed SYS-solvency row" "problem(s):$b_fail ; ON TSV: $(tr '\t' '|' < "$TSV_ON" | tr '\n' ' ')"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) OFF over the SAME seam fixture: no SYS-solvency row at all (byte-identical to M1 default-off).
# ----------------------------------------------------------------------------------------------------------
if grep -q 'SYS-solvency' "$TSV_OFF"; then
    fail "(d) no general lens by default" "the OFF run over the seam fixture emitted a SYS-solvency row"
else
    pass "(d) --composable-lens OFF over the seam fixture emits NO SYS-solvency row (the composition-surface enrichment is inert without the flag)"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) ZERO-SEAM: zones.json gains NO composition_surfaces key, and the SYS-solvency row uses the M1 bootstrap
# (target = the zone's largest .sol = src/Vault.sol, aux = src/Ledger.sol).
# ----------------------------------------------------------------------------------------------------------
ZERO_BASE="$WORK/zero-base"
breadth "$ZERO_BASE" "$ZERO" "$ZERO_MAP"; ZERO_BASE_RC=$?
if [ "$ZERO_BASE_RC" -ne 0 ]; then
    fail "zero-seam breadth baseline" "run-zone-hunt.sh breadth run failed"
    tail -20 "$ZERO_BASE.log" | sed 's/^/      /' >&2
    summary_exit
fi
ZERO_ON="$WORK/zero-on"; cp -R "$ZERO_BASE" "$ZERO_ON"; lens_only "$ZERO_ON" "$ZERO" --composable-lens
ZTSV="$ZERO_ON/.deep-hunt-targets.tsv"
c_fail=""
if python3 - "$ZERO_ON/map/zones.json" <<'PY'
import sys, json
zones = json.load(open(sys.argv[1], encoding="utf-8"))
for z in zones:
    assert "composition_surfaces" not in z, "zero-seam zone %r gained a composition_surfaces key" % z.get("id")
PY
then :; else c_fail="${c_fail} zones.json-gained-a-key"; fi
if [ -f "$ZTSV" ]; then
    ZSYS="$(awk -F'\t' '$3 == "SYS-solvency"' "$ZTSV")"
    ZTARGET="$(printf '%s\n' "$ZSYS" | awk -F'\t' 'NR==1 {print $2}')"
    ZAUX="$(printf '%s\n' "$ZSYS" | awk -F'\t' 'NR==1 {print $4}')"
    [ "$ZTARGET" = "src/Vault.sol" ] || c_fail="${c_fail} bootstrap-target=${ZTARGET:-<none>}-want-src/Vault.sol"
    [ "$ZAUX" = "src/Ledger.sol" ] || c_fail="${c_fail} bootstrap-aux=${ZAUX:-<empty>}-want-src/Ledger.sol"
else
    c_fail="${c_fail} no-tsv"
fi
if [ -z "$c_fail" ]; then
    pass "(c) zero-seam fixture: zones.json gains NO composition_surfaces key (option C byte-identity) AND the SYS-solvency row uses the unchanged M1 bootstrap (target src/Vault.sol, aux src/Ledger.sol)"
else
    fail "(c) zero-seam bootstrap preserved" "problem(s):$c_fail ; ZERO TSV: $([ -f "$ZTSV" ] && tr '\t' '|' < "$ZTSV" | tr '\n' ' ')"
fi

summary_exit
