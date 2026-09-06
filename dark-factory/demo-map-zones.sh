#!/usr/bin/env bash
# demo-map-zones.sh — OFFLINE, DETERMINISTIC proof of M1 zone-mapping (#1612, epic #1611): map-zones.sh
# (shell plumbing) + auditor/agents/zone-mapper.ag (substrate classification) auto-derive a target's
# DISCOVERY manifest and emit zones.json + scope.tsv, the pipe-delimited manifest run-discovery.sh --scope
# already parses byte-for-byte — closing the auto-map -> hunt loop.
#
# TWO parts:
#   1) MAP + ROUND-TRIP (always, CI-safe, no toolchain): over a throwaway `git init` copy of
#      fixtures/zone-map/ (an "audited" baseline + a post-audit-churn commit), runs map-zones.sh with
#      --since + --fixture (the offline substrate stub) and asserts the emitted zones.json (valid, 9 keys),
#      scope.tsv (pipe-delimited, a function-slice for the oversized contract, no `|`/newline/backtick in
#      any field), the run-discovery.sh --list-cells ROUND-TRIP (>=1 CELL, cells match the manifest), the
#      advisory-and-never-a-gate hardening_score, and the read-only/never-submit map path.
#   2) SUBSTRATE (source-guard always; live only when agentis is on PATH): asserts zone-mapper.ag's cb decl,
#      env contract, ZONE| output token, and learn/memo tail, then runs map-zones.sh --backend mock over the
#      fixture (mock does not reason, so only clean end-to-end execution is asserted), [SKIP] otherwise.
#
# Usage:  dark-factory/demo-map-zones.sh
# Requires: git + python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MAPZONES="$HERE/map-zones.sh"
DISCOVERY="$HERE/run-discovery.sh"
MAPPER="$HERE/auditor/agents/zone-mapper.ag"
FIXTURE_DIR="$HERE/fixtures/zone-map"
FIXTURE_TXT="$FIXTURE_DIR/zones.fixture.txt"

FAILS=0
note() { echo "demo-map-zones.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
[ -x "$MAPZONES" ]  || { note "map-zones.sh not found / not executable: $MAPZONES" >&2; exit 3; }
[ -x "$DISCOVERY" ] || { note "run-discovery.sh not found / not executable: $DISCOVERY" >&2; exit 3; }
[ -f "$MAPPER" ]    || { note "zone-mapper.ag not found: $MAPPER" >&2; exit 3; }
[ -f "$FIXTURE_TXT" ] || { note "zones.fixture.txt not found: $FIXTURE_TXT" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-map-zones.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# (a) Build the throwaway git fixture: commit the whole fixtures/zone-map/ tree as the "audited" baseline
#     (capture the ref), then a post-audit commit touching ONLY the liquidation contract — so
#     audit-delta.sh --since <baseline> sees a real delta in exactly one zone.
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/target"
mkdir -p "$REPO"
cp -R "$FIXTURE_DIR/contracts" "$REPO/contracts"
# #1824: excluded-path fixtures (test/mocks/interfaces/script, plus the libraries/ + scripts_core/
# regression dirs) — see the (c4) assertion block below for what these prove.
cp -R "$FIXTURE_DIR/test" "$REPO/test"
cp -R "$FIXTURE_DIR/mocks" "$REPO/mocks"
cp -R "$FIXTURE_DIR/interfaces" "$REPO/interfaces"
cp -R "$FIXTURE_DIR/script" "$REPO/script"
cp -R "$FIXTURE_DIR/libraries" "$REPO/libraries"
cp -R "$FIXTURE_DIR/scripts_core" "$REPO/scripts_core"
git -C "$REPO" init -q
git -C "$REPO" config user.email demo@example.invalid
git -C "$REPO" config user.name "demo"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "initial audited version"
BASE="$(git -C "$REPO" rev-parse HEAD)"
printf '\n// post-audit tweak (churn signal for the liquidation zone)\n' >> "$REPO/contracts/liquidation/Liquidation.sol"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "post-audit change to the liquidation engine"

OUT="$WORK/out"

# ----------------------------------------------------------------------------------------------------------
# (b) Run map-zones.sh over the fixture with --since (hardening) + --fixture (offline substrate stub).
# ----------------------------------------------------------------------------------------------------------
note "1) map-zones.sh over the git fixture (--since + --fixture, no network / no LLM) ..."
"$MAPZONES" --repo "$REPO" --out "$OUT" --since "$BASE" --fixture "$FIXTURE_TXT" >/dev/null 2>"$WORK/map.err"
RC=$?
[ "$RC" -eq 0 ] && ok "map-zones.sh exits 0 on the fixture" || { bad "map-zones.sh exited $RC"; sed 's/^/      /' "$WORK/map.err" >&2; }
[ -f "$OUT/zones.json" ] && ok "emitted zones.json" || bad "zones.json not emitted"
[ -f "$OUT/scope.tsv" ]  && ok "emitted scope.tsv"  || bad "scope.tsv not emitted"

# ----------------------------------------------------------------------------------------------------------
# (c) zones.json is valid JSON, an array, every zone carrying ALL seven keys (issue AC #1).
# ----------------------------------------------------------------------------------------------------------
if python3 - "$OUT/zones.json" <<'PY'
import sys, json
zones = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(zones, list) and zones, "zones.json is not a non-empty array"
need = {"id", "name", "files", "loc", "hardening_score", "bug_classes_likely", "description", "value_custody", "has_implementation"}
# #1957 relaxed the strict `== need` to `need.issubset(...)`: a zone MAY carry additive keys (`split_of` for a
# split sub-zone, plus the pre-existing #1861/#1914/#1707 optionals). The upper bound still pins that no STRAY
# key leaks in. The shipped fixture is small (every zone under the default 1600-LOC cap), so the default-cap run
# must produce NO split_of at all -- proof that splitting is a no-op below the cap (un-split == byte-identical).
optional = {"split_of", "abstract_base", "implementation_appendix", "composition_surfaces", "classification_failed"}
for z in zones:
    keys = set(z.keys())
    assert need.issubset(keys), "zone %r missing required keys %r" % (z.get("id"), need - keys)
    assert keys.issubset(need | optional), "zone %r has unexpected keys %r" % (z.get("id"), keys - (need | optional))
    assert "split_of" not in z, "default-cap run split a zone %r -- splitting must be a no-op below the cap" % z.get("id")
    assert isinstance(z["files"], list) and z["files"], "zone %r has no files" % z.get("id")
    assert isinstance(z["bug_classes_likely"], list), "bug_classes_likely not a list"
    assert isinstance(z["loc"], int) and isinstance(z["hardening_score"], int), "loc/hardening not ints"
    assert isinstance(z["value_custody"], bool), "value_custody not a bool"
    assert isinstance(z["has_implementation"], bool), "has_implementation not a bool"   # #2108(a)
PY
then ok "zones.json is a valid JSON array; every zone has the 9 required keys (id/name/files/loc/hardening_score/bug_classes_likely/description/value_custody/has_implementation) + no stray key, and the default-cap run carries no split_of (splitting is a no-op below the cap)"
else bad "zones.json schema assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (c3) #1713 VALUE-CUSTODY FLAG: the accounting/lending zones are flagged value_custody:true, the read-only
#      oracle/governance zones value_custody:false (the fixture DECLARES the flags via CUSTODY| lines, since
#      the .ag is not run on the --fixture path). This gates run-zone-hunt.sh's severity-first --deep-hunt.
# ----------------------------------------------------------------------------------------------------------
note "1c) #1713: value_custody flag round-trips from the fixture CUSTODY| lines into zones.json ..."
if python3 - "$OUT/zones.json" <<'PY'
import sys, json
zones = {z["id"]: z for z in json.load(open(sys.argv[1], encoding="utf-8"))}
assert zones["contracts_vault"]["value_custody"] is True, "accounting vault zone not flagged value_custody"
assert zones["contracts_liquidation"]["value_custody"] is True, "lending/CDP liquidation zone not flagged value_custody"
assert zones["contracts_oracle"]["value_custody"] is False, "read-only oracle zone wrongly flagged value_custody"
assert zones["contracts_governance"]["value_custody"] is False, "governance role zone wrongly flagged value_custody"
# #2108(a): the accounting vault is a deployable contract (real function bodies) -> has_implementation:true.
assert zones["contracts_vault"]["has_implementation"] is True, "accounting vault zone not flagged has_implementation"
PY
then ok "value_custody is true for the accounting vault + lending/CDP zones, false for the oracle + governance zones"
else bad "value_custody flag did not round-trip as expected"
fi

# ----------------------------------------------------------------------------------------------------------
# (c4) #1824: mechanical-pass PATH exclusion. test/mocks/interfaces/script zones are dropped from BOTH
#      zones.json and scope.tsv before the fixture is even reached (the fixture's ZONE| lines for those
#      dirs are REAL, non-empty classifications, so this proves the filter actually fires — not just that
#      "unclassified zones don't ship", which is already true today). `libraries/` (a value_custody zone,
#      NOT test/mocks/interfaces/script) and `scripts_core/` (a real dir name, not the excluded `script/`
#      prefix) MUST both survive with their classification intact — proving the match is path-based (not
#      value_custody-based) and segment-anchored (not a bare substring of "script").
# ----------------------------------------------------------------------------------------------------------
note "1d) #1824: test/mocks/interfaces/script zones are excluded from zones.json + scope.tsv; libraries/ + scripts_core/ survive ..."
if python3 - "$OUT/zones.json" "$OUT/scope.tsv" <<'PY'
import sys, json

EXCLUDED_IDS = {"test", "tests", "mocks", "interfaces", "script"}
EXCLUDED_SEGMENTS = ("test/", "mocks/", "interfaces/", "script/")

zones = json.load(open(sys.argv[1], encoding="utf-8"))
zone_ids = {z["id"] for z in zones}
assert not (zone_ids & EXCLUDED_IDS), "an excluded zone id leaked into zones.json: %r" % (zone_ids & EXCLUDED_IDS)

rows = [l.rstrip("\n") for l in open(sys.argv[2], encoding="utf-8") if l.strip() and not l.lstrip().startswith("#")]
for l in rows:
    subsys, cls, files = [p.strip() for p in l.split("|")]
    assert subsys not in EXCLUDED_IDS, "excluded zone %r leaked into scope.tsv" % subsys
    for tok in files.split(","):
        f = tok.split("@", 1)[0].strip()
        assert not any(f.startswith(seg) or ("/" + seg) in f for seg in EXCLUDED_SEGMENTS), \
            "excluded path segment leaked into scope.tsv: %r" % f

by_id = {z["id"]: z for z in zones}
assert "libraries" in by_id, "libraries/ zone missing from zones.json -- the path filter over-excluded it"
assert by_id["libraries"]["bug_classes_likely"], "libraries/ zone's classification was dropped"
assert by_id["libraries"]["value_custody"] is True, "libraries/ zone lost its value_custody flag"
assert any(l.split("|")[0].strip() == "reserve logic" for l in rows), "libraries/ zone missing from scope.tsv"

assert "scripts_core" in by_id, "scripts_core/ (real dir, not the excluded script/ prefix) was wrongly dropped"
assert by_id["scripts_core"]["bug_classes_likely"], "scripts_core/ zone's classification was dropped"
assert any(l.split("|")[0].strip() == "keeper" for l in rows), \
    "scripts_core/ zone missing from scope.tsv -- an over-broad match on 'script' would cause this"
PY
then ok "test/mocks/interfaces/script zones excluded from zones.json + scope.tsv; libraries/ (value_custody) and scripts_core/ (segment-anchored non-match) both survive intact"
else bad "#1824 path-exclusion assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (1e) #1825: the fn-slice cap was raised from 8 to 16 (map-zones.sh's FN_SLICE_CAP) because the old cap
#      truncated out mid-ranked, non-value-moving, non-valuation rare-bug functions on the corpus targets
#      (Strategy.checkPoolActivity, ReserveLogic._updateIndexes, Pool.startAuction). The liquidation fixture
#      (17 declared names) reproduces that shape: `accrue`, `seize` and `_healthFactor` are ranks 14/15/16
#      under prioritize_fn_names() at cap 16 -- truncated at the old cap 8, present at cap 16. Assert all
#      three survive the slice AND that `setOracle` (rank 17) is still absent -- a two-sided pin: the first
#      half fails if the cap drops below 16, the second fails if the cap is removed entirely.
# ----------------------------------------------------------------------------------------------------------
note "1e) #1825: fn-slice cap raise to 16 recovers accrue/seize/_healthFactor without uncapping the slice ..."
if python3 - "$OUT/scope.tsv" <<'PY'
import sys
rows = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8") if l.strip() and not l.lstrip().startswith("#")]
liq_rows = [l for l in rows if l.startswith("liquidation engine |")]
assert liq_rows, "no scope.tsv row for the liquidation engine zone"
files_field = liq_rows[0].split("|")[2]
fn_names = set()
for tok in files_field.split(","):
    tok = tok.strip()
    if "@" in tok:
        fn_names.update(tok.split("@", 1)[1].split("+"))
for needed in ("accrue", "seize", "_healthFactor"):
    assert needed in fn_names, "%s missing from the liquidation zone's function slice at cap 16: %r" % (needed, sorted(fn_names))
assert "setOracle" not in fn_names, "setOracle (rank 17) leaked into the slice -- the cap is no longer bounded at 16: %r" % sorted(fn_names)
PY
then ok "liquidation zone's slice surfaces accrue/seize/_healthFactor (ranks 14-16, recovered by the cap raise) and still excludes setOracle (rank 17)"
else bad "fn-slice cap-16 assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (1f) #1834: fn_names() no longer scrapes the English word "function" out of NatSpec prose or a
#      commented-out declaration as a phantom function name -- only a real `function NAME(` declaration
#      line counts. contracts/registry/Registry.sol carries all three shapes from the issue: NatSpec
#      prose, a commented-out OLD declaration, and a declaration inside a `/* ... */` block comment. The
#      first two must produce ZERO phantom names; the third is an ACCEPTED, DOCUMENTED residual
#      (fn_names() has no comment-state tracking) and is asserted PRESENT, not absent, so the gap stays
#      a conscious, pinned decision rather than a silent assumption.
# ----------------------------------------------------------------------------------------------------------
note "1f) #1834: fn_names() extracts only real declarations, not NatSpec/commented-out prose (block-comment residual pinned as accepted) ..."
if python3 - "$OUT/scope.tsv" <<'PY'
import sys
rows = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8") if l.strip() and not l.lstrip().startswith("#")]
reg_rows = [l for l in rows if l.startswith("allowlist registry |")]
assert reg_rows, "no scope.tsv row for the allowlist registry zone"
files_field = reg_rows[0].split("|")[2]
fn_names = set()
for tok in files_field.split(","):
    tok = tok.strip()
    if "@" in tok:
        fn_names.update(tok.split("@", 1)[1].split("+"))
expected = {"setAllowed", "isAllowed", "renounceOwnership", "oldSetAllowedBatch"}
assert fn_names == expected, (
    "allowlist registry function-slice does not match exactly the real + accepted-residual "
    "declarations: got %r, want %r" % (sorted(fn_names), sorted(expected))
)
PY
then ok "allowlist registry slice is exactly {setAllowed, isAllowed, renounceOwnership, oldSetAllowedBatch} -- no NatSpec/commented-out-line phantom leaked in, and the accepted block-comment residual (oldSetAllowedBatch) is present and pinned"
else bad "#1834 fn_names() scrape-accuracy assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (c2) REGRESSION (#1664): an INDENTED ZONE| marker line must still be classified — proving #1663's
#      whitespace-tolerant scrape (`grep -E '^[[:space:]]*ZONE\|' ... | sed 's/^[[:space:]]*//'`) stays in
#      place. Derive the indented fixture at runtime from the checked-in FIXTURE_TXT (indent only the ZONE|
#      lines 2 spaces; comments are untouched), run map-zones.sh over it into a fresh out dir, and assert
#      every zone's bug_classes_likely is still non-empty (not silently dropped to the empty fallback).
# ----------------------------------------------------------------------------------------------------------
note "1b) regression: an indented ZONE| marker line is still classified (#1663 whitespace-tolerant scrape) ..."
INDENTED_FIXTURE="$WORK/zones-indented.fixture.txt"
sed -E 's/^(ZONE\|)/  \1/' "$FIXTURE_TXT" > "$INDENTED_FIXTURE"
OUT_INDENTED="$WORK/out-indented"
"$MAPZONES" --repo "$REPO" --out "$OUT_INDENTED" --since "$BASE" --fixture "$INDENTED_FIXTURE" \
  >/dev/null 2>"$WORK/map-indented.err"
RC=$?
[ "$RC" -eq 0 ] && ok "map-zones.sh exits 0 on the indented fixture" \
  || { bad "map-zones.sh exited $RC on the indented fixture"; sed 's/^/      /' "$WORK/map-indented.err" >&2; }
[ -f "$OUT_INDENTED/zones.json" ] && ok "emitted zones.json for the indented fixture" || bad "zones.json not emitted for the indented fixture"
if python3 - "$OUT_INDENTED/zones.json" <<'PY'
import sys, json
zones = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(zones, list) and zones, "zones.json is not a non-empty array"
for z in zones:
    assert isinstance(z.get("bug_classes_likely"), list) and z["bug_classes_likely"], \
        "zone %r has empty bug_classes_likely -- the indented ZONE| line was dropped" % z.get("id")
PY
then ok "every zone's bug_classes_likely is still non-empty despite the indented ZONE| marker"
else bad "indented-marker regression: a zone's classification was dropped"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) scope.tsv is pipe-delimited `subsystem | classes | files`, carries a `file@fn+fn` slice for the
#     oversized contract, and contains NO `|`/newline/backtick inside any field (shell-safety, AC #7).
# ----------------------------------------------------------------------------------------------------------
if python3 - "$OUT/scope.tsv" <<'PY'
import sys
lines = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8")]
rows = [l for l in lines if l.strip() and not l.lstrip().startswith("#")]
assert rows, "scope.tsv has no data rows"
saw_slice = False
for l in rows:
    parts = l.split("|")
    assert len(parts) == 3, "row is not exactly 3 pipe-delimited fields: %r" % l
    for f in parts:
        assert "`" not in f, "backtick in a field: %r" % l
        assert "\n" not in f and "\r" not in f, "newline in a field: %r" % l
    if "@" in parts[2]:
        saw_slice = True
assert saw_slice, "no function-slice (file@fn+fn) for the oversized contract"
PY
then ok "scope.tsv is pipe-delimited (subsystem | classes | files), slices the oversized contract, no |/newline/backtick in any field"
else bad "scope.tsv format/safety assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (d2) REGRESSION (#1701): fn_names()[:cap] used to truncate a big contract's function-slice by pure
#      declaration order, so a value-moving/recovery function declared AFTER several admin/setter functions
#      never made the slice (reproduced live against dodo's Gateway* files). The liquidation fixture now
#      declares 4 admin setters ahead of liquidate/redeem specifically to reproduce that shape; assert the
#      emitted scope.tsv slice for the liquidation zone still surfaces `liquidate` (and `redeem`) despite
#      them.
#
#      #1825 NOTE: at the raised cap (16 of 17 declared names), a naive declaration-order slice would ALSO
#      contain `liquidate` (declared 12th) and `redeem` (declared 14th) -- only `setOracle` (17th) falls
#      out -- so plain membership has gone vacuous as a regression guard for the #1701 reorder. Restore its
#      teeth with an ORDERING assertion instead: map-zones.sh emits names in prioritized order, so
#      `liquidate` must sort ahead of `setFeeBps` under the reorder (rank 3 < rank 8) while declaration
#      order would put it behind (declared 12th > declared 5th).
# ----------------------------------------------------------------------------------------------------------
if python3 - "$OUT/scope.tsv" <<'PY'
import sys
rows = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8") if l.strip() and not l.lstrip().startswith("#")]
liq_rows = [l for l in rows if l.startswith("liquidation engine |")]
assert liq_rows, "no scope.tsv row for the liquidation engine zone"
files_field = liq_rows[0].split("|")[2]
fn_names = []
for tok in files_field.split(","):
    tok = tok.strip()
    if "@" in tok:
        fn_names.extend(tok.split("@", 1)[1].split("+"))
assert "liquidate" in fn_names, "liquidate missing from the liquidation zone's function slice: %r" % fn_names
assert "redeem" in fn_names, "redeem missing from the liquidation zone's function slice: %r" % fn_names
assert "setFeeBps" in fn_names, "setFeeBps missing -- cannot assert ordering: %r" % fn_names
assert fn_names.index("liquidate") < fn_names.index("setFeeBps"), \
    "liquidate does not precede setFeeBps in the emitted slice order -- the #1701 reorder has gone vacuous: %r" % fn_names
PY
then ok "liquidation zone's function-slice surfaces liquidate + redeem ahead of admin setters in emitted order (#1701, ordering-pinned post-#1825)"
else bad "fn-slice priority regression: liquidate/redeem dropped, or no longer ordered ahead of admin setters"
fi

# ----------------------------------------------------------------------------------------------------------
# (d3) REGRESSION (#1799): the value-MOVING functions of a big vault/CDP contract used to fill the whole
#      fn-slice by themselves and truncate out its value-READING (valuation/pricing) functions — so an entire
#      rare-bug family (share/asset mispricing, e.g. notional's AbstractSingleSidedLP.convertToAssets, fb=2
#      H-4) never reached scope.tsv and was never hunted. map-zones.sh now RESERVES a valuation-slot quota
#      (VALUATION_KEYWORDS). The liquidation fixture declares `convertToAssets` LAST (after every admin setter
#      AND every value-moving fn); assert it survives the slice WITHOUT displacing liquidate/redeem.
#
#      #1825 NOTE: unlike (d2)'s guard, this one is NOT yet vacuous at cap 16 -- `convertToAssets` is
#      declared LAST of the fixture's 17 names, so an unprioritised `[:16]` still drops it and the membership
#      assert below would still fire. The ordering guard is added PRE-EMPTIVELY, for the cap raise after this
#      one: at cap 17+ membership becomes satisfiable by declaration order alone and stops proving anything.
#      `convertToAssets` (a reserved valuation slot) must sort ahead of `setPaused` (rest partition) in the
#      emitted order (rank 6 < rank 9).
# ----------------------------------------------------------------------------------------------------------
if python3 - "$OUT/scope.tsv" <<'PY'
import sys
rows = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8") if l.strip() and not l.lstrip().startswith("#")]
liq_rows = [l for l in rows if l.startswith("liquidation engine |")]
assert liq_rows, "no scope.tsv row for the liquidation engine zone"
files_field = liq_rows[0].split("|")[2]
fn_names = []
for tok in files_field.split(","):
    tok = tok.strip()
    if "@" in tok:
        fn_names.extend(tok.split("@", 1)[1].split("+"))
assert "convertToAssets" in fn_names, \
    "convertToAssets (last-declared valuation fn) truncated out of the slice: %r" % fn_names
# the reservation must NOT come at the cost of the value-moving path the #1701 test guards
assert "liquidate" in fn_names and "redeem" in fn_names, \
    "valuation reservation displaced a value-moving fn: %r" % fn_names
assert "setPaused" in fn_names, "setPaused missing -- cannot assert ordering: %r" % fn_names
assert fn_names.index("convertToAssets") < fn_names.index("setPaused"), \
    "convertToAssets does not precede setPaused in the emitted slice order -- the #1799 reservation has gone vacuous: %r" % fn_names
PY
then ok "liquidation zone's slice surfaces the LAST-declared valuation fn convertToAssets ahead of admin setters, and keeps liquidate + redeem (#1799 valuation-slot reservation, ordering-pinned post-#1825)"
else bad "fn-slice valuation regression: convertToAssets truncated out, displaced a value-moving fn, or no longer ordered ahead of admin setters"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) ROUND-TRIP: run-discovery.sh --list-cells over the emitted scope.tsv prints >=1 CELL| and the
#     enumerated (subsystem x class) cells match the manifest exactly (AC #3; offline, no agentis).
# ----------------------------------------------------------------------------------------------------------
note "2) round-trip: run-discovery.sh --list-cells over the auto-generated scope.tsv ..."
"$DISCOVERY" --repo "$REPO" --scope "$OUT/scope.tsv" --list-cells >"$WORK/cells.txt" 2>"$WORK/cells.err"
RC=$?
[ "$RC" -eq 0 ] && ok "run-discovery.sh --list-cells exits 0 (needs neither --brief nor agentis)" \
  || { bad "run-discovery.sh --list-cells exited $RC"; sed 's/^/      /' "$WORK/cells.err" >&2; }
if grep -q '^CELL|' "$WORK/cells.txt"; then
  ok "prints >=1 CELL| line ($(grep -c '^CELL|' "$WORK/cells.txt") cells)"
else
  bad "no CELL| line emitted"
fi
if python3 - "$OUT/scope.tsv" "$WORK/cells.txt" <<'PY'
import sys
scope, cells = sys.argv[1], sys.argv[2]
expected = 0
manifest = set()
for l in open(scope, encoding="utf-8"):
    l = l.rstrip("\n")
    if not l.strip() or l.lstrip().startswith("#"):
        continue
    subsys, cls, files = [p.strip() for p in l.split("|")]
    classes = [c.strip() for c in cls.split(",") if c.strip()]
    expected += len(classes)
    for c in classes:
        manifest.add("CELL|%s|%s|%s" % (subsys, c, files))
got = [l.rstrip("\n") for l in open(cells, encoding="utf-8") if l.startswith("CELL|")]
assert len(got) == expected, "cell count %d != expected %d" % (len(got), expected)
assert set(got) == manifest, "enumerated cells do not match the manifest"
PY
then ok "the enumerated cells match the manifest byte-for-byte (subsystem x class round-trip holds)"
else bad "the --list-cells enumeration diverged from the manifest"
fi

# ----------------------------------------------------------------------------------------------------------
# (f) hardening_score is monotone vs the fixture's audit density (post-audit-churned liquidation zone is
#     LESS hardened than an unchurned zone) AND is never a gate (the low-score zone still ships in scope.tsv).
# ----------------------------------------------------------------------------------------------------------
note "3) hardening_score is advisory (monotone vs churn) and never a gate ..."
if python3 - "$OUT/zones.json" "$OUT/scope.tsv" <<'PY'
import sys, json
zones = {z["name"]: z for z in json.load(open(sys.argv[1], encoding="utf-8"))}
liq = zones["liquidation engine"]["hardening_score"]
vault = zones["vault deposits"]["hardening_score"]
assert liq < vault, "post-audit-churned liquidation (%d) is not less hardened than the unchurned vault (%d)" % (liq, vault)
# never a gate: the low-hardening churned zone still appears in scope.tsv (nothing is filtered out).
rows = [l for l in open(sys.argv[2], encoding="utf-8") if l.strip() and not l.lstrip().startswith("#")]
assert any(l.startswith("liquidation engine |") for l in rows), "the low-hardening zone was gated out of scope.tsv"
PY
then ok "churned zone is less hardened than an unchurned one, yet still ships in scope.tsv (advisory, not a gate)"
else bad "hardening_score monotonicity / not-a-gate assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (g) READ-ONLY / NEVER-SUBMIT: no network or submission verb anywhere on the map path.
# ----------------------------------------------------------------------------------------------------------
# Grep only EXECUTABLE lines (strip `#`-prefixed shell/python comments, which legitimately DESCRIBE the
# never-submit posture) for an actual network/submission verb.
if grep -vE '^[[:space:]]*#' "$MAPZONES" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
  bad "map-zones.sh invokes a network/submission verb on the map path"
else
  ok "map-zones.sh has no network / no submission verb on the map path (read-only, never submits)"
fi

# ----------------------------------------------------------------------------------------------------------
# (h) #1707 SENTINEL VALIDATION + RETRY (substrate path, offline via a stub --agentis): a zone-mapper reply
#     that is TUI chrome (no ZONE| sentinel) is RETRIED, not silently left unclassified. (a) chrome-then-ZONE|
#     recovers (real classes + zone in scope.tsv); (b) chrome-on-all marks the zone classification_failed +
#     excludes it from scope.tsv + counts + logs it — never a silent unclassified-and-dropped zone.
# ----------------------------------------------------------------------------------------------------------
# Fast offline stub through the --agentis seam (drives the SUBSTRATE path, NOT --fixture). dash-safe.
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
cmd="${1:-}"
case "$cmd" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    key="${ZONE_ID:-z}"
    # #1707: emit chrome (no ZONE| sentinel) for the first STUB_CHROME_ATTEMPTS attempts of each zone.
    if [ -n "${STUB_CHROME_CTR:-}" ]; then
      ckey="$(printf '%s' "$key" | tr -cs 'A-Za-z0-9' '_')"
      cf="$STUB_CHROME_CTR/$ckey"
      cn=0; [ -f "$cf" ] && cn="$(cat "$cf")"
      cn=$((cn + 1)); printf '%s' "$cn" > "$cf"
      if [ "$cn" -le "${STUB_CHROME_ATTEMPTS:-0}" ]; then
        printf 'high · /effort\n'
        printf 'esc to interrupt\n'
        exit 0
      fi
    fi
    printf 'ZONE|%s|core subsystem|C1,C6|deposit accounting invariants under external attack\n' "$key"
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

note "3c) #1707: a zone-mapper reply of chrome-then-ZONE| is RETRIED and classified (not left unclassified) ..."
OUT_CHROME="$WORK/out-chrome"
STUB_CHROME_CTR="$WORK/ctr-chrome"; mkdir -p "$STUB_CHROME_CTR"
DF_AGENT_MAX_ATTEMPTS=2 STUB_CHROME_CTR="$STUB_CHROME_CTR" STUB_CHROME_ATTEMPTS=1 \
  "$MAPZONES" --repo "$REPO" --out "$OUT_CHROME" --agentis "$STUB" >/dev/null 2>"$WORK/map-chrome.err"
RC=$?
[ "$RC" -eq 0 ] && ok "map-zones.sh exits 0 on the chrome-then-ZONE| substrate stub" \
  || { bad "map-zones.sh exited $RC on the chrome stub"; sed 's/^/      /' "$WORK/map-chrome.err" >&2; }
if grep -q 'valid zone-mapper sentinel on attempt 2/2' "$WORK/map-chrome.err"; then
  ok "the scraper logged a successful retry (valid on attempt 2/2)"
else
  bad "no retry was logged — the chrome reply was not actually retried"
fi
if python3 - "$OUT_CHROME/zones.json" <<'PY'
import sys, json
zones = json.load(open(sys.argv[1], encoding="utf-8"))
assert zones, "no zones emitted"
for z in zones:
    assert z.get("bug_classes_likely"), "zone %r left unclassified despite the retry" % z.get("id")
    assert "classification_failed" not in z, "a recovered zone was wrongly flagged classification_failed"
PY
then ok "every zone was classified after the retry (non-empty bug_classes_likely, no classification_failed flag)"
else bad "a zone was left unclassified despite chrome-then-ZONE| recovery"
fi
if [ -s "$OUT_CHROME/scope.tsv" ] && grep -qv '^#' "$OUT_CHROME/scope.tsv"; then
  ok "the recovered zones ship in scope.tsv (hunted)"
else
  bad "scope.tsv has no data rows after the retry"
fi

note "3d) #1707: a zone-mapper reply of chrome on ALL attempts is FAILED (classification_failed, excluded, logged) ..."
OUT_FAIL="$WORK/out-mapfail"
STUB_CHROME_CTR="$WORK/ctr-mapfail"; mkdir -p "$STUB_CHROME_CTR"
DF_AGENT_MAX_ATTEMPTS=2 STUB_CHROME_CTR="$STUB_CHROME_CTR" STUB_CHROME_ATTEMPTS=99 \
  "$MAPZONES" --repo "$REPO" --out "$OUT_FAIL" --agentis "$STUB" >/dev/null 2>"$WORK/map-fail.err"
RC=$?
[ "$RC" -eq 0 ] && ok "map-zones.sh still exits 0 with all-chrome zones (visibility via flag/counter/log)" \
  || { bad "map-zones.sh exited $RC on the all-chrome stub"; sed 's/^/      /' "$WORK/map-fail.err" >&2; }
if python3 - "$OUT_FAIL/zones.json" <<'PY'
import sys, json
zones = json.load(open(sys.argv[1], encoding="utf-8"))
assert zones, "no zones emitted"
for z in zones:
    assert z.get("classification_failed") is True, "zone %r not flagged classification_failed" % z.get("id")
    assert not z.get("bug_classes_likely"), "a failed zone kept a classification"
PY
then ok "every all-chrome zone is flagged classification_failed:true in zones.json (a visible failure, not a silent drop)"
else bad "an all-chrome zone was not flagged classification_failed"
fi
# excluded from scope.tsv (no data rows) — a failed zone is not silently hunted with empty classes
if [ -f "$OUT_FAIL/scope.tsv" ] && grep -q '^[^#]' "$OUT_FAIL/scope.tsv"; then
  bad "a failed zone leaked into scope.tsv"
else
  ok "the failed zones are excluded from scope.tsv (never hunted with no trace)"
fi
if grep -q 'FAILED classification' "$WORK/map-fail.err"; then
  ok "the summary loudly reports the FAILED classification count (retried, still chrome; NOT hunted)"
else
  bad "no loud FAILED-classification summary was logged"
fi
if [ -s "$OUT_FAIL/.failed-zones.txt" ]; then
  ok "the failed zone ids are recorded in .failed-zones.txt"
else
  bad ".failed-zones.txt is empty despite all-chrome zones"
fi

# ----------------------------------------------------------------------------------------------------------
# (h2) #2114: --model threads into the emitted substrate config's `llm.model`; unset stays `opus` (additive,
#      byte-identical to before this flag existed). Same STUB seam as (h)/(3d), no LLM/network involved.
# ----------------------------------------------------------------------------------------------------------
note "3e) #2114: --model <id> lands as llm.model = <id>; omitted stays llm.model = opus ..."
OUT_MODEL="$WORK/out-model"
"$MAPZONES" --repo "$REPO" --out "$OUT_MODEL" --agentis "$STUB" --model claude-fable-5-1 \
  >/dev/null 2>"$WORK/map-model.err"
if grep -qx 'llm.model = claude-fable-5-1' "$OUT_MODEL/run/.agentis/config" 2>/dev/null; then
  ok "--model claude-fable-5-1 lands as llm.model = claude-fable-5-1 in the emitted config"
else
  bad "--model claude-fable-5-1 did not land in $OUT_MODEL/run/.agentis/config"
fi
OUT_NOMODEL="$WORK/out-nomodel"
"$MAPZONES" --repo "$REPO" --out "$OUT_NOMODEL" --agentis "$STUB" >/dev/null 2>"$WORK/map-nomodel.err"
if grep -qx 'llm.model = opus' "$OUT_NOMODEL/run/.agentis/config" 2>/dev/null; then
  ok "omitting --model still emits llm.model = opus (byte-identical to before this flag existed)"
else
  bad "omitting --model did not emit llm.model = opus in $OUT_NOMODEL/run/.agentis/config"
fi

# ----------------------------------------------------------------------------------------------------------
# (i) #1861 INHERITANCE APPENDIX. A zone whose file declares an `abstract contract` with body-less `virtual`
#     members, and which holds no implementation of it, is hunted against a base class and none of its
#     behaviour — measured on the diagnosing target as a 1-in-22 refute-gate confirmation rate against 14-in-22
#     on a concrete-contract zone of the same target in the same run. map-zones.sh now appends ONE
#     function-sliced representative implementor to such a zone's scope_files and records the condition in the
#     additive `abstract_base` / `implementation_appendix` keys.
#
#     SELF-CONTAINED: its own throwaway repo and its own inline ZONE| fixture. fixtures/zone-map/ is read by
#     SIX demos, so a new directory there would ripple through all of them — this block touches none of it
#     (and the (c) 8-key schema assertion above still holds precisely because the shipped fixture declares no
#     abstract contract at all, i.e. the shipped path is a literal no-op).
#
#     The CONTROL run is the same map-zones.sh executed from a shadow dir that deliberately does NOT carry
#     lib/inheritance.py — so it doubles as the proof that an absent helper degrades to a no-op instead of
#     failing the run.
# ----------------------------------------------------------------------------------------------------------
note "5) #1861: inheritance appendix (abstract base + cross-zone implementor) ..."
INH_REPO="$WORK/target-inheritance"
mkdir -p "$INH_REPO/base" "$INH_REPO/staking" "$INH_REPO/orphan" "$INH_REPO/iface" "$INH_REPO/ifaceimpl" \
         "$INH_REPO/ml" "$INH_REPO/mlimpl" "$INH_REPO/lay" "$INH_REPO/layimpl" \
         "$INH_REPO/dup" "$INH_REPO/dupa" "$INH_REPO/dupb" \
         "$INH_REPO/gp" "$INH_REPO/mid" "$INH_REPO/leaf" \
         "$INH_REPO/cyc" "$INH_REPO/cyc2" "$INH_REPO/together"

# The diagnosing shape: an abstract base with body-less virtuals (`_initiateWithdraw`, `_mintYieldTokens` —
# the latter declared across three physical lines) plus a virtual member that DOES have a body here
# (`convertToAssets`, which the implementor overrides), and a plain non-virtual function that must never
# reach the slice. The `is Ownable(msg.sender)` clause pins the constructor-arg strip.
cat > "$INH_REPO/base/AbstractYield.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract AbstractYield is Ownable(msg.sender) {
    function _initiateWithdraw(uint256 shares) internal virtual returns (uint256);
    function _mintYieldTokens(
        uint256 amount,
        address to
    ) internal virtual;
    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        return shares;
    }
    function totalAssets() public view returns (uint256) {
        return 0;
    }
}
SOL
cat > "$INH_REPO/staking/StakingStrategy.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract StakingStrategy is AbstractYield {
    function _initiateWithdraw(uint256 shares) internal override returns (uint256) {
        return shares;
    }
    function _mintYieldTokens(uint256 amount, address to) internal override {
    }
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return shares * 2;
    }
}
SOL
# A4: an abstract base with NO descendant anywhere -> the option-C record, nothing attached.
cat > "$INH_REPO/orphan/AbstractOrphan.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract AbstractOrphan {
    function orphanWork(uint256 amount) internal virtual returns (uint256);
}
SOL
# A5: an `interface` in a NON-excluded directory, with a descendant that would resolve its member. The
# `virtual` keyword is written out deliberately so the ONLY thing keeping this inert is the kind check.
cat > "$INH_REPO/iface/IThing.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IThing {
    function ping(uint256 amount) external virtual returns (uint256);
}
SOL
cat > "$INH_REPO/ifaceimpl/Thing.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract Thing is IThing {
    function ping(uint256 amount) external override returns (uint256) {
        return amount;
    }
}
SOL
# A6: two real-world declaration shapes a single-line `contract A is B {` regex cannot see.
cat > "$INH_REPO/ml/AbstractML.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract AbstractML {
    function mlWork(uint256 amount) internal virtual returns (uint256);
}
SOL
cat > "$INH_REPO/mlimpl/MLImpl.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract MLImpl
    is
    AbstractML
{
    function mlWork(uint256 amount) internal override returns (uint256) {
        return amount;
    }
}
SOL
cat > "$INH_REPO/lay/AbstractLay.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract AbstractLay {
    function layWork(uint256 amount) internal virtual returns (uint256);
}
SOL
cat > "$INH_REPO/layimpl/LayImpl.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract LayImpl layout at (2 ** 128) is AbstractLay {
    function layWork(uint256 amount) internal override returns (uint256) {
        return amount;
    }
}
SOL
# A7: the same contract NAME declared in two scanned files -> ambiguous -> no edge at all.
cat > "$INH_REPO/dup/AbstractDup.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract AbstractDup {
    function dupWork(uint256 amount) internal virtual returns (uint256);
}
SOL
cat > "$INH_REPO/dupa/DupImpl.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract DupImpl is AbstractDup {
    function dupWork(uint256 amount) internal override returns (uint256) {
        return amount;
    }
}
SOL
cp "$INH_REPO/dupa/DupImpl.sol" "$INH_REPO/dupb/DupImpl.sol"
# A8a: the implementation is a GRANDCHILD (the intermediate resolves nothing and is itself abstract).
cat > "$INH_REPO/gp/AbstractGrand.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract AbstractGrand {
    function grandWork(uint256 amount) internal virtual returns (uint256);
}
SOL
cat > "$INH_REPO/mid/MidAbstract.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract MidAbstract is AbstractGrand {
    uint256 public midState;
}
SOL
cat > "$INH_REPO/leaf/GrandImpl.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract GrandImpl is MidAbstract {
    function grandWork(uint256 amount) internal override returns (uint256) {
        return amount;
    }
}
SOL
# A8b: an inheritance CYCLE (CycA is CycB, CycB is CycA) must terminate, not spin.
cat > "$INH_REPO/cyc/CycA.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract CycA is CycB {
    function cycWork(uint256 amount) internal virtual returns (uint256);
}
SOL
cat > "$INH_REPO/cyc2/CycB.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract CycB is CycA {
    function cycWork(uint256 amount) internal override returns (uint256) {
        return amount;
    }
}
SOL
# A3 control: an abstract base whose implementor is ALREADY in the same zone -> a literal no-op.
cat > "$INH_REPO/together/AbstractTog.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract AbstractTog {
    function togWork(uint256 amount) internal virtual returns (uint256);
}
SOL
cat > "$INH_REPO/together/TogImpl.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract TogImpl is AbstractTog {
    function togWork(uint256 amount) internal override returns (uint256) {
        return amount;
    }
}
SOL
git -C "$INH_REPO" init -q
git -C "$INH_REPO" config user.email demo@example.invalid
git -C "$INH_REPO" config user.name "demo"
git -C "$INH_REPO" add -A
git -C "$INH_REPO" commit -qm "inheritance fixture"

# Inline ZONE| fixture (one line per zone id = the slug of each immediate directory).
INH_FIXTURE="$WORK/inheritance.fixture.txt"
: > "$INH_FIXTURE"
for z in base staking orphan iface ifaceimpl ml mlimpl lay layimpl dup dupa dupb gp mid leaf cyc cyc2 together; do
  printf 'ZONE|%s|%s|C1,C6|inheritance fixture zone\n' "$z" "$z" >> "$INH_FIXTURE"
done

# The CONTROL: the very same map-zones.sh run from a shadow dir WITHOUT lib/inheritance.py.
NOINH="$WORK/df-noinherit"
mkdir -p "$NOINH/lib" "$NOINH/auditor"
cp "$MAPZONES" "$NOINH/map-zones.sh"
cp "$HERE/lib/run-agent-validated.sh" "$NOINH/lib/run-agent-validated.sh"
cp "$HERE/lib/ensure-claude-trust.sh" "$NOINH/lib/ensure-claude-trust.sh"  # #993: map-zones now sources this
cp "$HERE/lib/flat-cyborg-env.sh" "$NOINH/lib/flat-cyborg-env.sh"  # #2119: map-zones now sources this too
cp "$HERE/auditor/slice-fns.sh" "$NOINH/auditor/slice-fns.sh"
cp "$HERE/auditor/bug-taxonomy.md" "$NOINH/auditor/bug-taxonomy.md" 2>/dev/null || true

OUT_INH="$WORK/out-inheritance"
OUT_CTRL="$WORK/out-inheritance-control"
"$MAPZONES" --repo "$INH_REPO" --out "$OUT_INH" --fixture "$INH_FIXTURE" >/dev/null 2>"$WORK/inh.err"
RC=$?
[ "$RC" -eq 0 ] && ok "map-zones.sh exits 0 on the inheritance fixture (incl. the CycA/CycB cycle)" \
  || { bad "map-zones.sh exited $RC on the inheritance fixture"; sed 's/^/      /' "$WORK/inh.err" >&2; }
"$NOINH/map-zones.sh" --repo "$INH_REPO" --out "$OUT_CTRL" --fixture "$INH_FIXTURE" \
  >/dev/null 2>"$WORK/inh-ctrl.err"
RC=$?
[ "$RC" -eq 0 ] && ok "map-zones.sh degrades to a no-op (exit 0) when lib/inheritance.py is absent" \
  || { bad "map-zones.sh exited $RC without lib/inheritance.py"; sed 's/^/      /' "$WORK/inh-ctrl.err" >&2; }

# --- A1: the triggering zone carries the record naming the cross-zone implementor + its resolved members.
if python3 - "$OUT_INH/zones.json" <<'PY'
import sys, json
zones = {z["id"]: z for z in json.load(open(sys.argv[1], encoding="utf-8"))}
z = zones["base"]
assert z.get("abstract_base") is True, "the abstract-base zone is not flagged abstract_base"
app = z.get("implementation_appendix")
assert isinstance(app, list) and len(app) == 1, "implementation_appendix missing / not a 1-entry list: %r" % app
e = app[0]
assert set(e.keys()) == {"base", "contract", "implementor", "implementor_contract", "resolves", "unresolved"}, \
    "appendix entry keys %r" % sorted(e.keys())
assert e["base"] == "base/AbstractYield.sol", "wrong base file: %r" % e["base"]
assert e["contract"] == "AbstractYield", "wrong base contract: %r" % e["contract"]
assert e["implementor"] == "staking/StakingStrategy.sol", "wrong implementor: %r" % e["implementor"]
assert e["implementor_contract"] == "StakingStrategy", "wrong implementor contract: %r" % e["implementor_contract"]
assert e["resolves"] == ["_initiateWithdraw", "_mintYieldTokens"], "wrong resolved members: %r" % e["resolves"]
assert e["unresolved"] == [], "unexpected unresolved members: %r" % e["unresolved"]
PY
then ok "A1: the abstract-base zone records abstract_base + an implementation_appendix naming staking/StakingStrategy.sol and the 2 body-less virtuals it resolves"
else bad "A1: the cross-zone implementation_appendix record is wrong or missing"
fi

# --- A2: the zone's scope.tsv line gains EXACTLY ONE `path@fn+fn` token — always sliced, never a whole file.
if python3 - "$OUT_INH/scope.tsv" "$OUT_CTRL/scope.tsv" <<'PY'
import sys


def files_field(path, subsys):
    for l in open(path, encoding="utf-8"):
        if not l.strip() or l.lstrip().startswith("#"):
            continue
        parts = [p.strip() for p in l.split("|")]
        if parts[0] == subsys:
            return [t.strip() for t in parts[2].split(",") if t.strip()]
    raise AssertionError("no scope.tsv row for %r in %s" % (subsys, path))


got = files_field(sys.argv[1], "base")
ctrl = files_field(sys.argv[2], "base")
assert got[:len(ctrl)] == ctrl, "the pre-existing tokens changed: %r vs %r" % (got, ctrl)
extra = got[len(ctrl):]
assert len(extra) == 1, "expected exactly one appendix token, got %r" % extra
tok = extra[0]
assert "@" in tok, "the appendix was appended as a BARE path (whole file), not a function slice: %r" % tok
path, fns = tok.split("@", 1)
assert path == "staking/StakingStrategy.sol", "wrong appendix path: %r" % path
assert fns.split("+") == ["_initiateWithdraw", "_mintYieldTokens", "convertToAssets"], \
    "wrong appendix slice (the overridden bodied virtual must ride along): %r" % fns
PY
then ok "A2: the abstract-base zone's scope.tsv line gains exactly one path@fn+fn token (staking/StakingStrategy.sol@_initiateWithdraw+_mintYieldTokens+convertToAssets) -- always sliced, never a whole file"
else bad "A2: the appendix token is missing, duplicated, or a bare whole-file path"
fi

# --- A3: everything else is byte-identical to the no-appendix control (incl. the in-zone-implementor zone).
if python3 - "$OUT_INH/zones.json" "$OUT_CTRL/zones.json" "$OUT_INH/scope.tsv" "$OUT_CTRL/scope.tsv" <<'PY'
import sys, json

TRIGGER = {"base", "orphan", "dup", "ml", "lay", "gp", "cyc"}

got = {z["id"]: z for z in json.load(open(sys.argv[1], encoding="utf-8"))}
ctrl = {z["id"]: z for z in json.load(open(sys.argv[2], encoding="utf-8"))}
assert set(got) == set(ctrl), "the zone SET changed: %r" % (set(got) ^ set(ctrl))
for zid in got:
    for k in ("files", "loc", "hardening_score", "name", "bug_classes_likely", "value_custody"):
        assert got[zid][k] == ctrl[zid][k], "zone %r key %r changed: %r vs %r" % (zid, k, got[zid][k], ctrl[zid][k])
    if zid not in TRIGGER:
        assert "abstract_base" not in got[zid], "non-triggering zone %r gained abstract_base" % zid
        assert "implementation_appendix" not in got[zid], "non-triggering zone %r gained an appendix" % zid
# the in-zone-implementor zone is the sharp control: it HOLDS an abstract base and must still be untouched
assert "abstract_base" not in got["together"], "a zone whose implementor is already in-zone was given an appendix"


def rows(path):
    out = {}
    for l in open(path, encoding="utf-8"):
        if not l.strip() or l.lstrip().startswith("#"):
            continue
        out[l.split("|")[0].strip()] = l.rstrip("\n")
    return out


g, c = rows(sys.argv[3]), rows(sys.argv[4])
assert set(g) == set(c), "the scope.tsv subsystem set changed"
changed = sorted(k for k in g if g[k] != c[k])
assert changed == sorted(["base", "ml", "lay", "gp", "cyc"]), \
    "exactly the 5 attaching zones' scope.tsv lines may change, got %r" % changed
PY
then ok "A3: every zones.json files/loc/hardening_score and every non-attaching scope.tsv line is byte-identical to the no-appendix control (incl. the in-zone-implementor zone, which stays a literal no-op)"
else bad "A3: the appendix perturbed zone identity or a control zone's manifest line"
fi

# --- A4: an abstract base with no descendant anywhere -> the option-C record, scope.tsv line unchanged.
if python3 - "$OUT_INH/zones.json" "$OUT_INH/scope.tsv" "$OUT_CTRL/scope.tsv" <<'PY'
import sys, json
zones = {z["id"]: z for z in json.load(open(sys.argv[1], encoding="utf-8"))}
z = zones["orphan"]
assert z.get("abstract_base") is True, "the descendant-less abstract base is not recorded at all"
app = z["implementation_appendix"]
assert len(app) == 1 and app[0]["implementor"] is None, "expected the option-C implementor:null fallback: %r" % app
assert app[0]["implementor_contract"] is None, "implementor_contract must be null too: %r" % app[0]
assert app[0]["unresolved"] == ["orphanWork"], "the unresolved member is not recorded: %r" % app[0]["unresolved"]


def row(path, subsys):
    for l in open(path, encoding="utf-8"):
        if l.split("|")[0].strip() == subsys:
            return l.rstrip("\n")
    raise AssertionError("no row for %r" % subsys)


assert row(sys.argv[2], "orphan") == row(sys.argv[3], "orphan"), \
    "the descendant-less zone's scope.tsv line changed -- a same-named/nearest contract was attached"
PY
then ok "A4: an abstract base with no descendant anywhere records abstract_base + implementor:null and leaves its scope.tsv line untouched (the option-C inert fallback)"
else bad "A4: the descendant-less abstract base was not handled as the inert option-C record"
fi

# --- A5: an `interface` never triggers, even with a resolving descendant one zone away.
if python3 - "$OUT_INH/zones.json" <<'PY'
import sys, json
zones = {z["id"]: z for z in json.load(open(sys.argv[1], encoding="utf-8"))}
assert "abstract_base" not in zones["iface"], "an `interface` was treated as an abstract base"
assert "implementation_appendix" not in zones["iface"], "an `interface` zone gained an appendix"
PY
then ok "A5: an interface in a non-excluded directory never triggers, even though its member is body-less, virtual, and implemented one zone away"
else bad "A5: an interface was treated as an abstract base"
fi

# --- A6: a multi-line `is` list and a `layout at (...) is` clause are both parsed.
if python3 - "$OUT_INH/zones.json" <<'PY'
import sys, json
zones = {z["id"]: z for z in json.load(open(sys.argv[1], encoding="utf-8"))}
ml = zones["ml"]["implementation_appendix"][0]
assert ml["implementor"] == "mlimpl/MLImpl.sol", "the multi-line `is` descendant was not found: %r" % ml
lay = zones["lay"]["implementation_appendix"][0]
assert lay["implementor"] == "layimpl/LayImpl.sol", "the `layout at (...) is` descendant was not found: %r" % lay
PY
then ok "A6: a descendant declared with a multi-line is-list AND one declared 'contract X layout at (2 ** 128) is Y' are both reached (a single-line regex finds neither)"
else bad "A6: a multi-line / layout-clause descendant declaration was not parsed"
fi

# --- A7: a contract name declared in two scanned files contributes NO edge.
if python3 - "$OUT_INH/zones.json" "$OUT_INH/scope.tsv" "$OUT_CTRL/scope.tsv" <<'PY'
import sys, json
zones = {z["id"]: z for z in json.load(open(sys.argv[1], encoding="utf-8"))}
app = zones["dup"]["implementation_appendix"][0]
assert app["implementor"] is None, \
    "an AMBIGUOUS contract name (declared in dupa/ and dupb/) still produced an edge: %r" % app["implementor"]


def row(path, subsys):
    for l in open(path, encoding="utf-8"):
        if l.split("|")[0].strip() == subsys:
            return l.rstrip("\n")
    raise AssertionError("no row for %r" % subsys)


assert row(sys.argv[2], "dup") == row(sys.argv[3], "dup"), "an ambiguous-name implementor was attached anyway"
PY
then ok "A7: a contract name declared in two scanned files is ambiguous and contributes no edge (no appendix, scope.tsv line untouched) -- taking the first declaration would attach one"
else bad "A7: an ambiguous contract name still produced an inheritance edge"
fi

# --- A8: a transitive (grandchild) implementor is reachable, and an inheritance cycle terminates.
if python3 - "$OUT_INH/zones.json" <<'PY'
import sys, json
zones = {z["id"]: z for z in json.load(open(sys.argv[1], encoding="utf-8"))}
gp = zones["gp"]["implementation_appendix"][0]
assert gp["implementor"] == "leaf/GrandImpl.sol", \
    "the GRANDCHILD implementor was not reached (direct edges only?): %r" % gp["implementor"]
assert gp["resolves"] == ["grandWork"], "the grandchild's resolved member is wrong: %r" % gp["resolves"]
cyc = zones["cyc"]["implementation_appendix"][0]
assert cyc["implementor"] == "cyc2/CycB.sol", "the cyclic descendant was not resolved: %r" % cyc["implementor"]
PY
then ok "A8: a grandchild implementor is reachable through an intermediate abstract contract that resolves nothing, and a CycA-is-CycB-is-CycA cycle terminates with the right implementor"
else bad "A8: the transitive walk missed the grandchild or did not terminate correctly on a cycle"
fi

# --- A9 (#1865): the appendix SIDECAR — appendix.tsv names, per subsystem, WHICH token is the derived
#     implementor and WHICH abstract base it implements. That fact is unrecoverable downstream: A2 pins that
#     the token has the same `path@fn+fn` shape every oversized zone file gets, so run-discovery.sh cannot
#     tell it apart from an ordinary slice. Rows exist for exactly the zones that ATTACHED a token (the same
#     five whose scope.tsv lines A3 allows to change) — never for `together` (in-zone implementor, a literal
#     no-op) and never for `orphan`/`dup` (recorded with implementor: null, nothing reached the payload) —
#     and the control tree, whose map-zones.sh has no lib/inheritance.py, writes no appendix.tsv AT ALL.
if [ -f "$OUT_CTRL/appendix.tsv" ]; then
  bad "A9: the no-inheritance.py control run wrote an appendix.tsv (a target with no cross-zone abstract base must emit the pre-#1865 file set)"
elif python3 - "$OUT_INH/appendix.tsv" "$OUT_INH/scope.tsv" <<'PY'
import sys

rows = []
for l in open(sys.argv[1], encoding="utf-8"):
    if not l.strip() or l.lstrip().startswith("#"):
        continue
    parts = l.rstrip("\n").split("\t")
    assert len(parts) == 3, "a sidecar row is not 3 TAB-delimited fields: %r" % l
    rows.append(parts)

by_sub = {}
for sub, tok, base in rows:
    assert sub not in by_sub, "subsystem %r has more than one sidecar row" % sub
    by_sub[sub] = (tok, base)

# Exactly the zones that ATTACHED a token get a row (A3's `changed` set), and nothing else.
assert set(by_sub) == {"base", "ml", "lay", "gp", "cyc"}, \
    "the sidecar row set is not the attaching-zone set: %r" % sorted(by_sub)
assert "together" not in by_sub, "the in-zone-implementor zone got a sidecar row (nothing was attached to it)"
assert "orphan" not in by_sub, "the descendant-less zone got a sidecar row (implementor: null attaches nothing)"
assert "dup" not in by_sub, "the ambiguous-name zone got a sidecar row (no edge, nothing attached)"

tok, base = by_sub["base"]
assert tok == "staking/StakingStrategy.sol@_initiateWithdraw+_mintYieldTokens+convertToAssets", \
    "the sidecar token is not the A2 token: %r" % tok
assert base == "base/AbstractYield.sol", "the sidecar base column is wrong: %r" % base

# Coherence with the manifest: every recorded token must literally be in THAT subsystem's scope.tsv file
# list — this is what run-discovery.sh's self-check tests, so a sidecar that cannot pass it is inert.
manifest = {}
for l in open(sys.argv[2], encoding="utf-8"):
    if not l.strip() or l.lstrip().startswith("#"):
        continue
    parts = [p.strip() for p in l.split("|")]
    manifest[parts[0]] = [t.strip() for t in parts[2].split(",") if t.strip()]
for sub, (tok, base) in by_sub.items():
    assert sub in manifest, "sidecar names subsystem %r, which has no scope.tsv line" % sub
    assert tok in manifest[sub], "sidecar token %r is not in %r's scope.tsv file list" % (tok, sub)
    assert tok.split("@", 1)[0] != base, "the sidecar points the token at its own base: %r" % tok
PY
then ok "A9: appendix.tsv records <subsystem>TAB<token>TAB<base> for exactly the 5 attaching zones (base -> staking/StakingStrategy.sol@... / base/AbstractYield.sol), no row for the in-zone-implementor / descendant-less / ambiguous zones, every token present in that subsystem's own scope.tsv line, and the no-helper control writes no appendix.tsv at all"
else bad "A9: the #1865 appendix sidecar is missing, mis-keyed, or names a zone that attached nothing"
fi

# ----------------------------------------------------------------------------------------------------------
# (6) #1957 (Lever 2): a directory zone whose AGGREGATE in-scope LOC exceeds ZONE_SPLIT_LOC is split into
#     deterministic next-fit sub-zones each within the cap, so each sub-zone's #1955 per-cell hunt timeout
#     stays in the linear region of run-discovery.sh's weight-scaled budget instead of saturating its
#     1800000 ms ceiling. SELF-CONTAINED (its own throwaway repo + inline ZONE|/CUSTODY| fixture, so
#     fixtures/zone-map/ and every other demo that reads it are untouched). Proves: (a) an over-cap
#     value-custody zone splits into <basename> (part k/N) sub-zones each <= cap, ids <parent>__pK, each
#     carrying split_of=<parent> and INHERITING the parent's classification + value_custody; (b) sub-zone ids
#     are stable + collision-free; (c) each sub-zone is a distinct scope.tsv row (so run-zone-hunt.sh's
#     `--only "$ZNAME"` cap stays enforceable); (d) a thin under-cap zone in the SAME run is untouched (no
#     split_of); (e) the split zones.json round-trips through lib/zone-coverage.py init as one coverage entry
#     per sub-zone (the downstream contract does not break on sub-zones).
# ----------------------------------------------------------------------------------------------------------
note "6) #1957: an over-cap zone splits into per-cap sub-zones inheriting the parent classification ..."
SPLIT_REPO="$WORK/target-split"
mkdir -p "$SPLIT_REPO/market" "$SPLIT_REPO/tiny"
# Deterministic line counts drive the next-fit packing (loc = line count). At ZONE_SPLIT_LOC=80: market/
# aggregates 90 LOC (Aaa 20 + Bbb 20 + Ccc 50) -> Aaa+Bbb pack into p1 (40), Ccc opens p2 (50); tiny/ is
# 10 LOC and stays a single un-split zone. Every file is individually under the cap (no over-cap single file).
python3 - "$SPLIT_REPO" <<'PY'
import os, sys
root = sys.argv[1]


def write(rel, nlines):
    with open(os.path.join(root, rel), "w", encoding="utf-8") as fh:
        fh.write("// SPDX-License-Identifier: MIT\n")
        fh.write("pragma solidity ^0.8.19;\n")
        for i in range(nlines - 2):
            fh.write("// filler line %d\n" % i)


write("market/Aaa.sol", 20)
write("market/Bbb.sol", 20)
write("market/Ccc.sol", 50)
write("tiny/Tiny.sol", 10)
PY
git -C "$SPLIT_REPO" init -q
git -C "$SPLIT_REPO" config user.email demo@example.invalid
git -C "$SPLIT_REPO" config user.name "demo"
git -C "$SPLIT_REPO" add -A
git -C "$SPLIT_REPO" commit -qm "split fixture"

# One parent-keyed ZONE|/CUSTODY| line per directory zone (the sub-zones inherit market's via split_of).
SPLIT_FIXTURE="$WORK/split.fixture.txt"
printf 'ZONE|market|market subsystem|C1,C6|value-custody market accounting\n' > "$SPLIT_FIXTURE"
printf 'CUSTODY|market|true\n' >> "$SPLIT_FIXTURE"
printf 'ZONE|tiny|tiny helper|C5|read-only helper\n' >> "$SPLIT_FIXTURE"
printf 'CUSTODY|tiny|false\n' >> "$SPLIT_FIXTURE"

OUT_SPLIT="$WORK/out-split"
ZONE_SPLIT_LOC=80 "$MAPZONES" --repo "$SPLIT_REPO" --out "$OUT_SPLIT" --fixture "$SPLIT_FIXTURE" \
  >/dev/null 2>"$WORK/split.err"
RC=$?
[ "$RC" -eq 0 ] && ok "map-zones.sh exits 0 with ZONE_SPLIT_LOC=80 on the over-cap fixture" \
  || { bad "map-zones.sh exited $RC on the split fixture"; sed 's/^/      /' "$WORK/split.err" >&2; }
if grep -q "zone 'market'.*exceeds ZONE_SPLIT_LOC=80 -> split into 2 sub-zone(s)" "$WORK/split.err"; then
  ok "the split is logged to stderr (no silent truncation)"
else
  bad "the split was not logged to stderr"
fi
if python3 - "$OUT_SPLIT/zones.json" "$OUT_SPLIT/scope.tsv" <<'PY'
import sys, json
zones = json.load(open(sys.argv[1], encoding="utf-8"))
by_id = {z["id"]: z for z in zones}
cap = 80

# market/ split into exactly market__p1 + market__p2, each <= cap, split_of=market, inheriting classification.
subs = sorted(zid for zid in by_id if zid.startswith("market__p"))
assert subs == ["market__p1", "market__p2"], "expected market__p1/__p2, got %r" % subs
assert "market" not in by_id, "the parent zone id survived alongside its sub-zones"
seen_names = set()
for k, zid in enumerate(subs, 1):
    z = by_id[zid]
    assert z["loc"] <= cap, "sub-zone %r loc %d exceeds the cap %d" % (zid, z["loc"], cap)
    assert z.get("split_of") == "market", "sub-zone %r missing/ wrong split_of: %r" % (zid, z.get("split_of"))
    assert z["name"] == "market (part %d/2)" % k, "sub-zone %r name is not distinct part-k/N: %r" % (zid, z["name"])
    assert z["bug_classes_likely"] == ["C1", "C6"], "sub-zone %r did not inherit parent classes: %r" % (zid, z["bug_classes_likely"])
    assert z["value_custody"] is True, "sub-zone %r did not inherit parent value_custody" % zid
    seen_names.add(z["name"])
assert len(seen_names) == 2, "sub-zone names are not collision-free: %r" % seen_names
# No file is dropped: the two sub-zones together hold all three market files.
allfiles = sorted(f for zid in subs for f in by_id[zid]["files"])
assert allfiles == ["market/Aaa.sol", "market/Bbb.sol", "market/Ccc.sol"], "a market file was dropped: %r" % allfiles

# The thin under-cap zone is UNTOUCHED: single zone, no split_of.
assert "tiny" in by_id, "the under-cap tiny zone disappeared"
assert "split_of" not in by_id["tiny"], "the under-cap zone was wrongly split"
assert by_id["tiny"]["value_custody"] is False, "the tiny zone's own custody flag was clobbered"

# Each sub-zone is a DISTINCT scope.tsv row (unique subsystem name -> --only cap stays enforceable).
subsys = [l.split("|")[0].strip() for l in open(sys.argv[2], encoding="utf-8")
          if l.strip() and not l.lstrip().startswith("#")]
assert "market (part 1/2)" in subsys and "market (part 2/2)" in subsys, "sub-zone rows missing from scope.tsv: %r" % subsys
assert len({s for s in subsys if s.startswith("market (part")}) == 2, "sub-zone scope.tsv rows are not distinct: %r" % subsys
PY
then ok "market/ (90 LOC) split into market__p1/__p2 (<=80 LOC each), distinct 'market (part k/2)' names + scope.tsv rows, split_of=market, inheriting C1,C6 + value_custody; no file dropped; tiny/ untouched"
else bad "#1957 split assertion failed"
fi

# (6b) the split zones.json round-trips through lib/zone-coverage.py init as one entry per sub-zone.
if [ -f "$HERE/lib/zone-coverage.py" ]; then
  python3 "$HERE/lib/zone-coverage.py" init --zones "$OUT_SPLIT/zones.json" --out "$WORK/split-cov.json" \
    --zone-list "$WORK/split-zonelist.tsv" --repo split-fixture --commit deadbeef >/dev/null 2>"$WORK/split-cov.err"
  RC=$?
  if [ "$RC" -eq 0 ] && python3 - "$WORK/split-cov.json" <<'PY'
import sys, json
rec = json.load(open(sys.argv[1], encoding="utf-8"))
ids = {z["id"]: z for z in rec.get("zones", [])}
for zid in ("market__p1", "market__p2", "tiny"):
    assert zid in ids, "sub-zone %r is not its own coverage entry: %r" % (zid, sorted(ids))
assert ids["market__p1"]["value_custody"] is True and ids["market__p2"]["value_custody"] is True, "sub-zone lost custody in the coverage record"
assert ids["tiny"]["value_custody"] is False, "the un-split zone's custody flag changed in the coverage record"
PY
  then ok "the split zones.json round-trips through zone-coverage.py init: market__p1/__p2/tiny are each a separate coverage entry (downstream contract holds)"
  else bad "#1957: the split zones.json broke the zone-coverage.py init round-trip"; sed 's/^/      /' "$WORK/split-cov.err" >&2
  fi
else
  skip "lib/zone-coverage.py not found -- skipping the coverage round-trip"
fi

# ----------------------------------------------------------------------------------------------------------
# (7) #2108(a): the has_implementation content signal. A deployable contract (a real function body) resolves
#     TRUE; a body-less declaration-only file (pure interface + events, plus a function-with-body that lives
#     only inside comments) resolves FALSE — even under a NON-excluded directory (the mETH case: the #1824
#     path filter only drops interfaces/-DIR zones, and is blind to a declaration-only file under src/). The
#     dashboard reads this to drop such a zone from the planned deep-hunt matrix instead of showing a phantom
#     queued DEPTH row. SELF-CONTAINED (own throwaway repo + inline ZONE| fixture, so fixtures/zone-map/ and
#     every demo that reads it are untouched, and the (c) 9-key schema count above is unaffected).
# ----------------------------------------------------------------------------------------------------------
note "7) #2108(a): has_implementation is true for a deployable contract, false for a declaration-only file ..."
IMPL_REPO="$WORK/target-has-impl"
mkdir -p "$IMPL_REPO/core" "$IMPL_REPO/events"
# A real, deployable contract: a function that terminates in a body `{`.
cat > "$IMPL_REPO/core/Vault.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract Vault {
    mapping(address => uint256) public balances;

    function withdraw(uint256 amount) external {
        balances[msg.sender] -= amount;
    }
}
SOL
# A declaration-only file under a NON-excluded dir: an interface (all `;`-terminated signatures) + events, with
# a function-WITH-body appearing ONLY inside a line comment and a block comment (must be stripped -> still FALSE).
cat > "$IMPL_REPO/events/Protocol.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// function commentedOut() external { balances[msg.sender] = 0; }
/* legacy note:
   function alsoCommented(uint256 x) internal { return x; }
*/
interface IProtocol {
    event Deposited(address indexed who, uint256 amount);
    function deposit(uint256 amount) external;
    function totalAssets() external view returns (uint256);
}
SOL
git -C "$IMPL_REPO" init -q
git -C "$IMPL_REPO" config user.email demo@example.invalid
git -C "$IMPL_REPO" config user.name "demo"
git -C "$IMPL_REPO" add -A
git -C "$IMPL_REPO" commit -qm "has_implementation fixture"

IMPL_FIXTURE="$WORK/has-impl.fixture.txt"
printf 'ZONE|core|core vault|C6|deployable accounting contract\n'  > "$IMPL_FIXTURE"
printf 'ZONE|events|protocol interface|C2|interface + events only\n' >> "$IMPL_FIXTURE"

OUT_IMPL="$WORK/out-has-impl"
"$MAPZONES" --repo "$IMPL_REPO" --out "$OUT_IMPL" --fixture "$IMPL_FIXTURE" >/dev/null 2>"$WORK/has-impl.err"
RC=$?
[ "$RC" -eq 0 ] && ok "map-zones.sh exits 0 on the has_implementation fixture" \
  || { bad "map-zones.sh exited $RC on the has_implementation fixture"; sed 's/^/      /' "$WORK/has-impl.err" >&2; }
if python3 - "$OUT_IMPL/zones.json" <<'PY'
import sys, json
zones = {z["id"]: z for z in json.load(open(sys.argv[1], encoding="utf-8"))}
assert zones["core"]["has_implementation"] is True, \
    "a deployable contract (real function body) was not flagged has_implementation:true"
assert zones["events"]["has_implementation"] is False, \
    "a declaration-only file (interface + events, bodies only in comments) was not flagged has_implementation:false"
PY
then ok "has_implementation is true for the deployable core/Vault.sol zone and false for the declaration-only events/Protocol.sol zone (comment-embedded bodies stripped)"
else bad "#2108(a) has_implementation content-signal assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# SECOND PART — substrate: source-guard zone-mapper.ag always; run live via --backend mock when agentis on PATH.
# ----------------------------------------------------------------------------------------------------------
note "4) source-guarding auditor/agents/zone-mapper.ag ..."
if grep -q '^cb 300000;' "$MAPPER"; then
  ok "zone-mapper.ag declares cb 300000 (matches the auditor colony cb_budget)"
else
  bad "zone-mapper.ag missing the cb 300000 declaration"
fi
missing_env=""
for v in TARGET_DIR ZONE_ID ZONE_FILES TAXONOMY; do
  grep -q "getenv(\"$v\")" "$MAPPER" || missing_env="$missing_env $v"
done
if [ -z "$missing_env" ]; then
  ok "zone-mapper.ag reads the env contract (TARGET_DIR/ZONE_ID/ZONE_FILES/TAXONOMY)"
else
  bad "zone-mapper.ag missing getenv for:$missing_env"
fi
if grep -q 'ZONE|' "$MAPPER" && grep -q 'prompt(' "$MAPPER"; then
  ok "zone-mapper.ag emits the ZONE| classification via one prompt()"
else
  bad "zone-mapper.ag missing the ZONE| output token / prompt()"
fi
# #1713: the value-custody flag reuses the shipped #1698/#1681 nets (no new detection logic) and emits a
# NON-ZONE| CUSTODY| diagnostic line map-zones.sh scrapes.
if grep -q 'fn is_value_custody' "$MAPPER" \
   && grep -q 'contains_accounting_signal' "$MAPPER" && grep -q 'contains_lending_signal' "$MAPPER" \
   && grep -q '"CUSTODY|"' "$MAPPER"; then
  ok "zone-mapper.ag defines is_value_custody (reusing contains_accounting_signal/contains_lending_signal) + emits the CUSTODY| line"
else
  bad "zone-mapper.ag missing the #1713 is_value_custody / CUSTODY| emission"
fi
# #1717: the path-level test/interface exclusion runs BEFORE the content signals in is_value_custody.
if grep -q 'fn zone_is_test_or_interface' "$MAPPER" && grep -q 'fn is_test_or_interface_path' "$MAPPER"; then
  ok "zone-mapper.ag defines the #1717 path-level test/interface exclusion"
else
  bad "zone-mapper.ag missing the #1717 zone_is_test_or_interface / is_test_or_interface_path helpers"
fi
# #1729: the C5 access-control/init-upgrade/proxy backstop net exists, is chained into apply_backstop (so C5
# reaches scope.tsv -> is hunted -> can be NAMED), carries its classification rule, and emits the ACCESS-CTRL|
# diagnostic (mirrors the #1698/#1681 net idiom + the #1713/#1717 diagnostic-line convention).
if grep -q 'fn contains_access_control_signal' "$MAPPER" \
   && grep -q 'fn apply_access_control_backstop' "$MAPPER" \
   && grep -q 'apply_access_control_backstop(' "$MAPPER" \
   && grep -q 'ACCESS-CONTROL / INIT-UPGRADE / PROXY DETECTION RULE (C5)' "$MAPPER" \
   && grep -q '"ACCESS-CTRL|"' "$MAPPER"; then
  ok "zone-mapper.ag defines the #1729 C5 net (contains_access_control_signal + apply_access_control_backstop), chains it into apply_backstop, carries the C5 rule, and emits the ACCESS-CTRL| line"
else
  bad "zone-mapper.ag missing the #1729 C5 access-control/init-upgrade/proxy backstop wiring"
fi
# #2111: the C19 narrow-integer overflow / unsafe downcast backstop net exists, is chained into apply_backstop
# (so C19 reaches scope.tsv -> is hunted -> can be NAMED), carries its classification rule, and emits the
# NARROW-INT| diagnostic (mirrors the #1729 C5 net idiom + the #1713/#1717 diagnostic-line convention).
if grep -q 'fn contains_narrow_int_signal' "$MAPPER" \
   && grep -q 'fn apply_narrow_int_backstop' "$MAPPER" \
   && grep -q 'apply_narrow_int_backstop(' "$MAPPER" \
   && grep -q 'NARROW-INTEGER OVERFLOW / UNSAFE DOWNCAST DETECTION RULE (C19)' "$MAPPER" \
   && grep -q '"NARROW-INT|"' "$MAPPER"; then
  ok "zone-mapper.ag defines the #2111 C19 net (contains_narrow_int_signal + apply_narrow_int_backstop), chains it into apply_backstop, carries the C19 rule, and emits the NARROW-INT| line"
else
  bad "zone-mapper.ag missing the #2111 C19 narrow-integer overflow / unsafe downcast backstop wiring"
fi
# #2121: the C8 reentrancy backstop net exists, is chained into apply_backstop (so C8 reaches scope.tsv ->
# is hunted -> can be NAMED), carries its classification rule, and emits the REENTRANCY| diagnostic (mirrors
# the #1729/#2111 net idiom + the #1713/#1717 diagnostic-line convention).
if grep -q 'fn contains_reentrancy_surface' "$MAPPER" \
   && grep -q 'fn apply_reentrancy_backstop' "$MAPPER" \
   && grep -q 'apply_reentrancy_backstop(' "$MAPPER" \
   && grep -q 'REENTRANCY (EXTERNAL-CALL-BEFORE-STATE-WRITE) DETECTION RULE (C8)' "$MAPPER" \
   && grep -q '"REENTRANCY|"' "$MAPPER"; then
  ok "zone-mapper.ag defines the #2121 C8 net (contains_reentrancy_surface + apply_reentrancy_backstop), chains it into apply_backstop, carries the C8 rule, and emits the REENTRANCY| line"
else
  bad "zone-mapper.ag missing the #2121 C8 reentrancy backstop wiring"
fi
if grep -q 'learn("zone-map"' "$MAPPER" && grep -q 'memo_write("zone-mapper:last_check"' "$MAPPER"; then
  ok "zone-mapper.ag records the mapping (learn) + writes its last_check memo"
else
  bad "zone-mapper.ag missing the learn/memo tail"
fi

if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the live end-to-end zone-mapper check"
else
  OUT2="$WORK/out-mock"
  "$MAPZONES" --repo "$REPO" --out "$OUT2" --since "$BASE" --backend mock >/dev/null 2>"$WORK/mock.err"
  RC=$?
  if [ "$RC" -eq 0 ] && [ -f "$OUT2/zones.json" ]; then
    ok "map-zones.sh --backend mock ran zone-mapper.ag end-to-end over the fixture (exit 0, zones.json emitted)"
  else
    bad "map-zones.sh --backend mock failed (exit $RC):"
    sed 's/^/      /' "$WORK/mock.err" | head -20 >&2
  fi

  # ----------------------------------------------------------------------------------------------------
  # #1717: path-level test/interface exclusion regression. A SECOND throwaway micro-repo (kept separate
  # from $REPO above so the offline --fixture assertions are untouched) with three zones (src/,
  # interfaces/, test/), each reproducing one of the issue's false-positive classes: a real custody
  # contract (must stay value_custody=true), a pure interface that merely references a lending type
  # (must now resolve false), and a Foundry test mock that redefines withdraw with real arithmetic (must
  # now resolve false). mock backend still runs is_value_custody()'s real, non-LLM logic — only prompt()
  # is stubbed — so this exercises the actual #1717 fix, not a fixture-declared CUSTODY| line.
  # ----------------------------------------------------------------------------------------------------
  CUSTODY_REPO="$WORK/target-custody-paths"
  mkdir -p "$CUSTODY_REPO/src" "$CUSTODY_REPO/interfaces" "$CUSTODY_REPO/test"
  cat > "$CUSTODY_REPO/src/Vault.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract Vault {
    mapping(address => uint256) public balances;

    function withdraw(uint256 amount) external {
        balances[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
}
SOL
  cat > "$CUSTODY_REPO/interfaces/IVault.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IVault {
    function withdraw(uint256 amount) external;
    function stabilityPool() external view returns (IStabilityPool);
}
SOL
  cat > "$CUSTODY_REPO/test/VaultTest.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract VaultTestMock {
    mapping(address => uint256) public balances;

    function withdraw(uint256 amount) external {
        balances[msg.sender] -= amount;
    }
}
SOL
  git -C "$CUSTODY_REPO" init -q
  git -C "$CUSTODY_REPO" config user.email demo@example.invalid
  git -C "$CUSTODY_REPO" config user.name "demo"
  git -C "$CUSTODY_REPO" add -A
  git -C "$CUSTODY_REPO" commit -qm "custody-path fixture"

  OUT3="$WORK/out-custody-paths"
  # #1824: the mechanical-pass path filter now drops interfaces/ and test/ zones BEFORE zone-mapper.ag ever
  # runs on them, so this test needs the documented escape hatch (--scope-hint) to keep exercising
  # zone-mapper.ag's OWN content-level is_value_custody() logic for those paths (the thing this block is
  # actually regression-testing) rather than having #1824's earlier, stronger filter make the zones
  # disappear before reaching the substrate at all.
  "$MAPZONES" --repo "$CUSTODY_REPO" --out "$OUT3" --backend mock --scope-hint "src,interfaces,test" \
    >/dev/null 2>"$WORK/mock-custody.err"
  RC3=$?
  # NOTE (deviation from the plan's literal read-zones.json mechanism, same intent): mock backend always
  # replies with the literal string "mock" (agentis-core's MockBackend, deterministic-by-design), which
  # never carries a ZONE| sentinel — map-zones.sh's df_run_agent_validated therefore treats every zone as
  # a FAILED classification and never runs the ZONE|/CUSTODY| scrape into zones.json (this is pre-existing,
  # unrelated to #1717: the SAME gate is why the existing block above only asserts exit-0 + zones.json
  # presence, never its classification content). The zone-mapper.ag run itself still executes to completion
  # and writes its raw CUSTODY|<id>|<bool> diagnostic line to $OUT3/run/zone_<id>.log regardless of that
  # gate (verified live) — reading it there exercises the exact same is_value_custody(code, files) call
  # this fix changed, without depending on the unrelated ZONE| classification-retry machinery.
  if [ "$RC3" -eq 0 ] && [ -d "$OUT3/run" ]; then
    CUSTODY_SRC="$(grep -h '^CUSTODY|src|' "$OUT3/run/zone_src.log" 2>/dev/null | tail -1)"
    CUSTODY_IFACE="$(grep -h '^CUSTODY|interfaces|' "$OUT3/run/zone_interfaces.log" 2>/dev/null | tail -1)"
    CUSTODY_TEST="$(grep -h '^CUSTODY|test|' "$OUT3/run/zone_test.log" 2>/dev/null | tail -1)"
    if [ "$CUSTODY_SRC" = "CUSTODY|src|true" ] && [ "$CUSTODY_IFACE" = "CUSTODY|interfaces|false" ] \
       && [ "$CUSTODY_TEST" = "CUSTODY|test|false" ]; then
      ok "#1717: is_value_custody() true for a real custody contract (src/), false for a pure interface (interfaces/) and a test mock (test/)"
    else
      bad "#1717: unexpected CUSTODY| lines (want src=true interfaces=false test=false, got src='$CUSTODY_SRC' interfaces='$CUSTODY_IFACE' test='$CUSTODY_TEST')"
    fi
  else
    bad "map-zones.sh --backend mock failed on the #1717 custody-path fixture (exit $RC3):"
    sed 's/^/      /' "$WORK/mock-custody.err" | head -20 >&2
  fi

  # ----------------------------------------------------------------------------------------------------
  # #1729: C5 access-control/init-upgrade/proxy signal regression. A THIRD throwaway micro-repo with two
  # zones (separate directories, since map-zones.sh groups by immediate dir): access/UpgradeableVault.sol
  # OWNS privileged/upgrade surface (onlyOwner + _authorizeUpgrade + initializer), math/PlainMath.sol owns
  # none. mock backend still runs contains_access_control_signal()'s real, non-LLM logic — only prompt() is
  # stubbed — so this exercises the actual #1729 signal offline via the unconditional ACCESS-CTRL| diagnostic
  # line (the mock reply carries no ZONE| sentinel, so the apply_backstop append itself is unreachable here —
  # the same constraint #1713/#1717 read via CUSTODY|).
  # ----------------------------------------------------------------------------------------------------
  AC_REPO="$WORK/target-access-control"
  mkdir -p "$AC_REPO/access" "$AC_REPO/math"
  cat > "$AC_REPO/access/UpgradeableVault.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract UpgradeableVault {
    address public owner;
    bool private _initialized;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function initialize(address owner_) external initializer {
        owner = owner_;
    }

    function _authorizeUpgrade(address newImpl) internal onlyOwner {}
}
SOL
  cat > "$AC_REPO/math/PlainMath.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library PlainMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }
}
SOL
  # #1740: two narrowing-regression zones added to the SAME repo (map-zones.sh groups by immediate dir, so
  # each gets its own zone) — a plain non-upgradeable pool with a private `_init(` helper (must resolve
  # false, distinct from the OZ-upgradeable `__Xxx_init(` chain) and a read-only adapter that QUERIES another
  # contract's AccessControl role via `hasRole(` without owning any AccessControl surface itself (must also
  # resolve false, distinct from an `is AccessControl` inheritance declaration).
  mkdir -p "$AC_REPO/plainamm" "$AC_REPO/reader"
  cat > "$AC_REPO/plainamm/Pool.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract Pool {
    uint256 public reserve0;
    uint256 public reserve1;

    constructor(uint256 r0, uint256 r1) { _init(r0, r1); }

    function _init(uint256 r0, uint256 r1) internal {
        reserve0 = r0;
        reserve1 = r1;
    }

    function swap(uint256 amountIn, bool zeroForOne) external returns (uint256 amountOut) {
        amountOut = amountIn;
    }
}
SOL
  cat > "$AC_REPO/reader/RoleReader.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract RoleReader {
    function isAdmin(address target, address who) external view returns (bool) {
        return IAccessControl(target).hasRole(bytes32(0), who);
    }
}
SOL
  # #2111: two C19 narrow-integer regression zones in the SAME repo — narrow/ObservationOverflow.sol owns a
  # `uint16` observation cardinality/index it increments toward a wrap PLUS an unchecked `uint16(` downcast on a
  # critical path (must resolve NARROW-INT|narrow|true, mirroring yieldoor H-3's mechanic), and wide/PlainMath.sol
  # does only `uint256` math with no narrow cast or counter (must resolve NARROW-INT|wide|false — proving the net
  # does not trip on ordinary wide-int arithmetic).
  mkdir -p "$AC_REPO/narrow" "$AC_REPO/wide"
  cat > "$AC_REPO/narrow/ObservationOverflow.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract ObservationOverflow {
    uint16 public observationCardinality;
    uint16 public observationIndex;

    function grow(uint256 next) external {
        // unchecked narrow downcast on the critical path: a value above 2**16-1 truncates and bricks reads
        observationCardinality = uint16(next);
        observationIndex = observationIndex + 1;
    }

    function checkPoolActivity() external view returns (uint16) {
        return observationCardinality;
    }
}
SOL
  cat > "$AC_REPO/wide/PlainMath.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract WideMath {
    uint256 public total;

    function add(uint256 a, uint256 b) external {
        total = a + b;
    }
}
SOL
  # #2121 (plan-review amendment): a THIRD pair of zones in the SAME repo for the C8 reentrancy net. The
  # positive uses ONLY the amendment's interface-typed-call form (Royco-Day-shaped: read a pending request
  # into memory, call out through `IOracle(oracle).poke()` — never `.call`/`safeTransfer` — then `delete`
  # the request slot), with NO guard anywhere in the file (must resolve REENTRANCY|reentrancy|true). The
  # negative makes the identical interface call but CEI-correct (write BEFORE the external call) AND
  # `nonReentrant` AND `is ReentrancyGuard` — a double-negative proving the net doesn't fire on either
  # signal alone (must resolve REENTRANCY|safeguard|false).
  mkdir -p "$AC_REPO/reentrancy" "$AC_REPO/safeguard"
  cat > "$AC_REPO/reentrancy/RoycoEntryPointLike.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IOracle {
    function poke() external;
}

contract RoycoEntryPointLike {
    struct DepositRequest {
        address asset;
        uint256 amount;
    }

    mapping(address => mapping(uint256 => DepositRequest)) public requests;
    mapping(address => uint256) public escrow;

    function settle(address oracle, address user, uint256 nonce) external {
        DepositRequest memory r = requests[user][nonce];
        IOracle(oracle).poke();
        delete requests[user][nonce];
        escrow[r.asset] -= r.amount;
    }
}
SOL
  cat > "$AC_REPO/safeguard/GuardedSettle.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IOracle {
    function poke() external;
}

contract GuardedSettle is ReentrancyGuard {
    struct DepositRequest {
        address asset;
        uint256 amount;
    }

    mapping(address => mapping(uint256 => DepositRequest)) public requests;
    mapping(address => uint256) public escrow;

    function settle(address oracle, address user, uint256 nonce) external nonReentrant {
        DepositRequest memory r = requests[user][nonce];
        delete requests[user][nonce];
        escrow[r.asset] -= r.amount;
        IOracle(oracle).poke();
    }
}
SOL

  git -C "$AC_REPO" init -q
  git -C "$AC_REPO" config user.email demo@example.invalid
  git -C "$AC_REPO" config user.name "demo"
  git -C "$AC_REPO" add -A
  git -C "$AC_REPO" commit -qm "access-control fixture"

  OUT4="$WORK/out-access-control"
  "$MAPZONES" --repo "$AC_REPO" --out "$OUT4" --backend mock >/dev/null 2>"$WORK/mock-ac.err"
  RC4=$?
  # Same diagnostic-line read as the #1717 block: zone-mapper.ag writes ACCESS-CTRL|<id>|<bool> to
  # $OUT4/run/zone_<id>.log regardless of the mock's no-ZONE| classification gate.
  if [ "$RC4" -eq 0 ] && [ -d "$OUT4/run" ]; then
    AC_VAULT="$(grep -h '^ACCESS-CTRL|access|' "$OUT4/run/zone_access.log" 2>/dev/null | tail -1)"
    AC_MATH="$(grep -h '^ACCESS-CTRL|math|' "$OUT4/run/zone_math.log" 2>/dev/null | tail -1)"
    AC_PLAINAMM="$(grep -h '^ACCESS-CTRL|plainamm|' "$OUT4/run/zone_plainamm.log" 2>/dev/null | tail -1)"
    AC_READER="$(grep -h '^ACCESS-CTRL|reader|' "$OUT4/run/zone_reader.log" 2>/dev/null | tail -1)"
    if [ "$AC_VAULT" = "ACCESS-CTRL|access|true" ] && [ "$AC_MATH" = "ACCESS-CTRL|math|false" ]; then
      ok "#1729: contains_access_control_signal() true for an onlyOwner/_authorizeUpgrade/initializer vault, false for plain math"
    else
      bad "#1729: unexpected ACCESS-CTRL| lines (want UpgradeableVault=true PlainMath=false, got vault='$AC_VAULT' math='$AC_MATH')"
    fi
    if [ "$AC_PLAINAMM" = "ACCESS-CTRL|plainamm|false" ]; then
      ok "#1740: contains_access_control_signal() false for a plain non-upgradeable pool's private _init( helper (no OZ-upgradeable base)"
    else
      bad "#1740: plainamm regression (want ACCESS-CTRL|plainamm|false, got '$AC_PLAINAMM')"
    fi
    if [ "$AC_READER" = "ACCESS-CTRL|reader|false" ]; then
      ok "#1740: contains_access_control_signal() false for a read-only adapter that queries IAccessControl(target).hasRole(...) without owning AccessControl surface"
    else
      bad "#1740: reader regression (want ACCESS-CTRL|reader|false, got '$AC_READER')"
    fi
    # #2111: same diagnostic-line read for the C19 narrow-integer overflow / unsafe downcast net — the mock
    # backend still runs contains_narrow_int_signal()'s real, non-LLM logic, so this exercises the actual net
    # offline via the unconditional NARROW-INT| diagnostic line.
    NI_NARROW="$(grep -h '^NARROW-INT|narrow|' "$OUT4/run/zone_narrow.log" 2>/dev/null | tail -1)"
    NI_WIDE="$(grep -h '^NARROW-INT|wide|' "$OUT4/run/zone_wide.log" 2>/dev/null | tail -1)"
    if [ "$NI_NARROW" = "NARROW-INT|narrow|true" ] && [ "$NI_WIDE" = "NARROW-INT|wide|false" ]; then
      ok "#2111: contains_narrow_int_signal() true for a uint16 observation-counter + uint16( downcast zone (yieldoor H-3 mechanic), false for plain uint256 math"
    else
      bad "#2111: unexpected NARROW-INT| lines (want narrow=true wide=false, got narrow='$NI_NARROW' wide='$NI_WIDE')"
    fi
    # #2121: same diagnostic-line read for the C8 reentrancy net — the mock backend still runs
    # contains_reentrancy_surface()'s real, non-LLM logic (incl. the regex_find_all/regex_capture
    # interface-typed-call detection), so this exercises the actual net offline via the unconditional
    # REENTRANCY| diagnostic line.
    RE_HOT="$(grep -h '^REENTRANCY|reentrancy|' "$OUT4/run/zone_reentrancy.log" 2>/dev/null | tail -1)"
    RE_SAFE="$(grep -h '^REENTRANCY|safeguard|' "$OUT4/run/zone_safeguard.log" 2>/dev/null | tail -1)"
    if [ "$RE_HOT" = "REENTRANCY|reentrancy|true" ] && [ "$RE_SAFE" = "REENTRANCY|safeguard|false" ]; then
      ok "#2121: contains_reentrancy_surface() true for an unguarded interface-typed-call-then-delete zone (Royco Day mechanic), false for the CEI-correct + nonReentrant + is ReentrancyGuard sibling"
    else
      bad "#2121: unexpected REENTRANCY| lines (want reentrancy=true safeguard=false, got reentrancy='$RE_HOT' safeguard='$RE_SAFE')"
    fi
  else
    bad "map-zones.sh --backend mock failed on the #1729/#1740 access-control fixture (exit $RC4):"
    sed 's/^/      /' "$WORK/mock-ac.err" | head -20 >&2
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — M1 zone-mapping (map-zones.sh + zone-mapper.ag) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
