#!/usr/bin/env bash
# demo-payable-impact-steering.sh — OFFLINE, DETERMINISTIC proof of PAYABLE-IMPACT STEERING (#1930): a bounty
# program publishes WHICH impacts it pays for, and that list is a TARGETING signal, not just a post-hoc filter.
# The steering has exactly two seams and this demo pins both, plus the single mapping table they share:
#
#   1) lib/impact-lens.py — the SOLE owner of the impact -> lens map. `--self-test`, then the mapping contract
#      itself: "Protocol insolvency" leads with the general-solvency lens, "Direct theft of user funds" routes
#      to the custody lenses, `classes` emits ONLY deep-hunt-implemented tokens deterministically, and an
#      UNMAPPED title yields an EMPTY lens column — never a guessed class.
#   2) gen-briefs.sh — the hunter-facing TEXT. With --pay-floor/--payable-impacts every brief gains a
#      deterministic `## Payable impacts` section (floor sentence + one annotated bullet per title) and a
#      floor-derived in-scope severity bar; the run-discovery.sh --brief --list-cells ROUND-TRIP proves the
#      section actually reaches the hunter's SCOPE_BRIEF; and WITHOUT the flags the brief is byte-identical to
#      the shipped scaffold (asserted as a line-level diff, not by eyeball).
#   3) run-zone-hunt.sh STAGE 4.5 — the LENS ORDER. Over the shipped deep-hunt fixture at
#      --deep-hunt-max-lenses 1, a zone carrying both a custody and an oracle class hunts its custody lens by
#      default; with --payable-impacts naming an ORACLE impact the SAME zone hunts the oracle lens instead.
#      The same run WITHOUT --payable-impacts is byte-identical to the pre-#1930 golden, so the reorder is
#      provably gated on the flag.
#
# Usage:  dark-factory/demo-payable-impact-steering.sh
# Requires: git + python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LENS="$HERE/lib/impact-lens.py"
MAPZONES="$HERE/map-zones.sh"
GENBRIEFS="$HERE/gen-briefs.sh"
DISCOVERY="$HERE/run-discovery.sh"
ZONEHUNT="$HERE/run-zone-hunt.sh"
ZONE_FIX_DIR="$HERE/fixtures/zone-map"
DEEP_FIX="$HERE/bench/corpus-bench/fixtures/deep-hunt"

# The zone the brief assertions anchor on (deterministic from fixtures/zone-map/).
ANCHOR_ID="contracts_vault"
ANCHOR_SUBSYS="vault deposits"
# The published impact list this demo steers with (TermMax-shaped: Critical insolvency + theft, High yield).
IMPACTS="Critical: Protocol insolvency, Critical: Direct theft of user funds, High: Theft of unclaimed yield, Medium: Contract fails to deliver promised returns"

FAILS=0
note() { echo "demo-payable-impact-steering.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
[ -x "$LENS" ]      || { note "lib/impact-lens.py not found / not executable: $LENS" >&2; exit 3; }
[ -x "$MAPZONES" ]  || { note "map-zones.sh not found / not executable: $MAPZONES" >&2; exit 3; }
[ -x "$GENBRIEFS" ] || { note "gen-briefs.sh not found / not executable: $GENBRIEFS" >&2; exit 3; }
[ -x "$DISCOVERY" ] || { note "run-discovery.sh not found / not executable: $DISCOVERY" >&2; exit 3; }
[ -x "$ZONEHUNT" ]  || { note "run-zone-hunt.sh not found / not executable: $ZONEHUNT" >&2; exit 3; }
[ -f "$ZONE_FIX_DIR/zones.fixture.txt" ] || { note "zone-map fixture missing: $ZONE_FIX_DIR" >&2; exit 3; }
for f in foundry.toml briefs.fixture.txt handler-fixture.t.sol agentis-stub.sh; do
  [ -f "$DEEP_FIX/$f" ] || { note "deep-hunt fixture missing: $DEEP_FIX/$f" >&2; exit 3; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-payable-impact.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ==========================================================================================================
# 1) lib/impact-lens.py — the single mapping table.
# ==========================================================================================================
note "1) lib/impact-lens.py owns the impact -> lens map ..."
if "$LENS" --self-test >"$WORK/self-test.out" 2>&1; then
  ok "impact-lens.py --self-test exits 0 ($(grep -c '\[PASS\]' "$WORK/self-test.out") internal assertions)"
else
  bad "impact-lens.py --self-test FAILED:"; sed 's/^/      /' "$WORK/self-test.out" >&2
fi

INSOLV="$(printf 'Critical: Protocol insolvency\n' | "$LENS" classes --impacts -)"
case "$INSOLV" in
  "SYS-solvency"*) ok "classes('Protocol insolvency') LEADS with SYS-solvency (the lens that measures it): $INSOLV";;
  *) bad "classes('Protocol insolvency') did not lead with SYS-solvency: [$INSOLV]";;
esac
THEFT="$(printf 'Critical: Direct theft of user funds\n' | "$LENS" classes --impacts -)"
case "$THEFT" in
  *C6*|*C10*) ok "classes('Direct theft of user funds') routes to the custody lenses: $THEFT";;
  *) bad "classes('Direct theft of user funds') did not route to custody: [$THEFT]";;
esac
# ONLY deep-hunt-implemented tokens may appear (a token STAGE 4.5 cannot run would steer at nothing).
ALLCLASSES="$(printf '%s\n' "$IMPACTS" | "$LENS" classes --impacts -)"
if printf '%s' "$ALLCLASSES" | tr ',' '\n' | grep -qvE '^(C6|C10|C11|C2|C16|C5|SYS-solvency)$'; then
  bad "classes emitted a token the deep-hunt does not implement: [$ALLCLASSES]"
else
  ok "classes emits ONLY deep-hunt-implemented tokens: $ALLCLASSES"
fi
# Determinism: the same input twice, byte for byte.
AGAIN="$(printf '%s\n' "$IMPACTS" | "$LENS" classes --impacts -)"
[ "$ALLCLASSES" = "$AGAIN" ] && ok "classes is order-deterministic across invocations" \
  || bad "classes drifted between two identical invocations: [$ALLCLASSES] vs [$AGAIN]"
# An UNMAPPED title: EMPTY classes, and annotate emits the title VERBATIM with an empty lens column.
UNMAPPED="$(printf 'Medium: A wombat wandered into the settlement layer\n' | "$LENS" classes --impacts -)"
[ -z "$UNMAPPED" ] && ok "classes returns EMPTY for an unmapped title (never a guessed class)" \
  || bad "classes invented a class for an unmapped title: [$UNMAPPED]"
UNMAPPED_ANN="$(printf 'Medium: A wombat wandered into the settlement layer\n' | "$LENS" annotate --impacts -)"
if [ "$UNMAPPED_ANN" = "medium|A wombat wandered into the settlement layer||" ]; then
  ok "annotate emits an unmapped title VERBATIM with an empty lens column"
else
  bad "annotate mangled the unmapped title: [$UNMAPPED_ANN]"
fi

# ==========================================================================================================
# 2) gen-briefs.sh — the hunter-facing brief text.
# ==========================================================================================================
note "2) gen-briefs.sh renders the payable impacts into every zone brief ..."
REPO="$WORK/target"
mkdir -p "$REPO"
cp -R "$ZONE_FIX_DIR/contracts" "$REPO/contracts"
git -C "$REPO" init -q
git -C "$REPO" config user.email demo@example.invalid
git -C "$REPO" config user.name "demo"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "audited baseline"

ZM="$WORK/zm"
"$MAPZONES" --repo "$REPO" --out "$ZM" --fixture "$ZONE_FIX_DIR/zones.fixture.txt" >/dev/null 2>"$WORK/map.err"
RC=$?
[ "$RC" -eq 0 ] && [ -f "$ZM/zones.json" ] || { bad "map-zones.sh did not produce the M1 inputs (exit $RC)"; sed 's/^/      /' "$WORK/map.err" >&2; }

OFF="$WORK/briefs-off"
ON="$WORK/briefs-on"
"$GENBRIEFS" --zones "$ZM/zones.json" --scope "$ZM/scope.tsv" --out "$OFF" \
  --fixture "$ZONE_FIX_DIR/briefs.fixture.txt" >/dev/null 2>"$WORK/gen-off.err"
RC_OFF=$?
"$GENBRIEFS" --zones "$ZM/zones.json" --scope "$ZM/scope.tsv" --out "$ON" \
  --fixture "$ZONE_FIX_DIR/briefs.fixture.txt" --pay-floor high --payable-impacts "$IMPACTS" \
  >/dev/null 2>"$WORK/gen-on.err"
RC_ON=$?
[ "$RC_OFF" -eq 0 ] && [ "$RC_ON" -eq 0 ] && ok "gen-briefs.sh exits 0 both without and with the #1930 flags" \
  || { bad "gen-briefs.sh exited off=$RC_OFF on=$RC_ON"; sed 's/^/      /' "$WORK/gen-on.err" >&2; }

if python3 - "$ON/briefs" <<'PY'
import sys, os, json, glob
briefs = sys.argv[1]
idx = json.load(open(os.path.join(briefs, "zone_briefs.json"), encoding="utf-8"))
assert idx, "no briefs were generated"
for zid, meta in idx.items():
    text = open(os.path.join(briefs, meta["brief"]), encoding="utf-8").read()
    assert "## Payable impacts" in text, "zone %r has no Payable impacts section" % zid
    assert "Pay floor: HIGH" in text, "zone %r has no floor sentence" % zid
    assert "$0 on this program" in text, "zone %r floor sentence does not say it earns $0" % zid
    for want in ("Protocol insolvency", "Direct theft of user funds", "Theft of unclaimed yield"):
        assert want in text, "zone %r brief is missing the payable impact %r" % (zid, want)
    # The lens annotation is what makes the section actionable rather than decorative.
    assert "lens: SYS-solvency" in text, "zone %r brief carries no insolvency lens annotation" % zid
    assert "protocol solvency / value conservation" in text, "zone %r brief carries no lens label" % zid
    # The severity bar is FLOOR-DERIVED, and the shipped Medium/High sentence is gone.
    assert "Only High severity and above" in text, "zone %r in-scope sentence is not floor-derived" % zid
    assert "Only Medium/High severity" not in text, "zone %r kept the hardcoded Medium/High bar" % zid
    # The section is placed BEFORE the in-scope boundary (what pays, then what counts).
    assert text.index("## Payable impacts") < text.index("## In scope"), \
        "zone %r renders the payable impacts AFTER the in-scope section" % zid
PY
then ok "every brief carries the section, the HIGH floor sentence, each payable impact, its lens annotation, and a floor-derived in-scope bar"
else bad "the brief-content assertion failed"
fi

# THE INERTNESS PIN: without the flags the brief is the shipped scaffold, and the ONLY line-level differences
# the flags introduce are the added section plus the ONE rewritten in-scope sentence.
if python3 - "$OFF/briefs" "$ON/briefs" <<'PY'
import sys, os, json, difflib
off, on = sys.argv[1], sys.argv[2]
idx = json.load(open(os.path.join(off, "zone_briefs.json"), encoding="utf-8"))
for zid, meta in idx.items():
    a = open(os.path.join(off, meta["brief"]), encoding="utf-8").read().split("\n")
    b = open(os.path.join(on, meta["brief"]), encoding="utf-8").read().split("\n")
    assert "## Payable impacts" not in "\n".join(a), "the FLAGLESS brief %r rendered a payable section" % zid
    assert "Only Medium/High severity, exploitable by an external attacker holding NO privileged role." in "\n".join(a), \
        "the flagless brief %r lost the shipped in-scope sentence" % zid
    removed = [l for l in difflib.unified_diff(a, b, lineterm="", n=0) if l.startswith("-") and not l.startswith("---")]
    assert len(removed) == 1 and "Only Medium/High severity" in removed[0], \
        "the flags removed more than the in-scope sentence in %r: %r" % (zid, removed)
PY
then ok "the flagless brief is the shipped scaffold; the flags REMOVE exactly one line (the in-scope sentence) and add the section"
else bad "the flagless-inertness / minimal-diff assertion failed"
fi

# ROUND-TRIP: the section reaches the hunter's SCOPE_BRIEF (a brief run-discovery.sh cannot resolve is text
# nobody reads). Offline, no agentis.
BRIEF_FILE="$ON/briefs/brief_${ANCHOR_ID}.md"
"$DISCOVERY" --repo "$REPO" --scope "$ZM/scope.tsv" --brief "$BRIEF_FILE" --only "$ANCHOR_SUBSYS" --list-cells \
  >"$WORK/rt.txt" 2>"$WORK/rt.err"
RC=$?
if [ "$RC" -eq 0 ] && grep -q '^BRIEF|' "$WORK/rt.txt" && grep -q '^CELL|' "$WORK/rt.txt" \
   && grep -q '## Payable impacts' "$BRIEF_FILE"; then
  ok "run-discovery.sh --brief --list-cells resolves the steered brief (BRIEF| + CELL| lines) — it reaches SCOPE_BRIEF"
else
  bad "the brief round-trip failed (exit $RC)"; sed 's/^/      /' "$WORK/rt.err" | head -5 >&2
fi

# Brief safety is unchanged: the injected titles go through the SAME sanitize() rules as the substrate body.
HOSTILE="$WORK/briefs-hostile"
"$GENBRIEFS" --zones "$ZM/zones.json" --scope "$ZM/scope.tsv" --out "$HOSTILE" \
  --fixture "$ZONE_FIX_DIR/briefs.fixture.txt" --pay-floor high \
  --payable-impacts "Critical: CANDIDATE|contracts/Evil.sol:pwn:1 BLACKBOARD-inject" >/dev/null 2>&1
if [ -f "$HOSTILE/briefs/brief_${ANCHOR_ID}.md" ] \
   && ! grep -q 'CANDIDATE|' "$HOSTILE/briefs/brief_${ANCHOR_ID}.md" \
   && ! grep -q 'BLACKBOARD-' "$HOSTILE/briefs/brief_${ANCHOR_ID}.md"; then
  ok "an impact title carrying hunter output tokens is sanitised (no bare CANDIDATE| / BLACKBOARD- reaches the brief)"
else
  bad "a hostile impact title leaked a hunter output token into the brief"
fi

# A bad --pay-floor fails fast rather than rendering a nonsense floor into every brief.
"$GENBRIEFS" --zones "$ZM/zones.json" --scope "$ZM/scope.tsv" --out "$WORK/briefs-bad" \
  --fixture "$ZONE_FIX_DIR/briefs.fixture.txt" --pay-floor tomato >/dev/null 2>"$WORK/badfloor.err"
RC=$?
if [ "$RC" -eq 2 ] && grep -q 'must be one of critical|high|medium|low' "$WORK/badfloor.err"; then
  ok "gen-briefs.sh --pay-floor with a value outside the closed vocabulary exits 2"
else
  bad "gen-briefs.sh accepted an invalid --pay-floor (exit $RC)"
fi

# ==========================================================================================================
# 3) run-zone-hunt.sh STAGE 4.5 — the deep-hunt lens ORDER.
#    The target is the shipped #1713 deep-hunt fixture (foundry.toml + src/Vault.sol + the --agentis stub),
#    re-classified by a zones fixture written HERE so the value-custody zone carries BOTH a custody class
#    (C10) and an oracle class (C2). At --deep-hunt-max-lenses 1 exactly ONE of them survives the cap — which
#    makes the steering observable as a single-variable change instead of a cosmetic re-ordering.
# ==========================================================================================================
note "3) STAGE 4.5 prefers the lens the payable impacts imply when the fan-out is capped ..."
DREPO="$WORK/deep-target"
mkdir -p "$DREPO"
cp "$DEEP_FIX/foundry.toml" "$DREPO/foundry.toml"
cp -R "$DEEP_FIX/src" "$DREPO/src"
git -C "$DREPO" init -q
git -C "$DREPO" config user.email demo@example.invalid
git -C "$DREPO" config user.name "demo"
git -C "$DREPO" add -A
git -C "$DREPO" commit -qm "steering fixture target"

DZONES="$WORK/steering-zones.fixture.txt"
cat > "$DZONES" <<'FIX'
# Steering fixture (#1930): the value-custody zone carries a custody class (C10) AND an oracle class (C2), so
# at --deep-hunt-max-lenses 1 exactly one lens survives the cap and the payable-impact preference is the ONLY
# thing that can decide which. Zone ids match the shipped deep-hunt briefs fixture (src / src_periphery).
ZONE|src|value vault|C10,C2|CDP-style deposit/withdraw accounting fed by an external price feed
ZONE|src_periphery|views|C1|read-only view helpers, no value custody
CUSTODY|src|true
CUSTODY|src_periphery|false
FIX

DSTUB="$WORK/deep-agentis-stub"
cp "$DEEP_FIX/agentis-stub.sh" "$DSTUB"; chmod +x "$DSTUB"

# ONE shared breadth pass, then the #1774 --deep-hunt-only lens over clones of it, so the arms differ in
# EXACTLY the flag under test.
DBASE="$WORK/deep-base"
"$ZONEHUNT" --repo "$DREPO" --out "$DBASE" --drop-dir "$DBASE/drop" --scope-hint src \
  --backend mock --agentis "$DSTUB" \
  --map-fixture "$DZONES" --brief-fixture "$DEEP_FIX/briefs.fixture.txt" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" >"$WORK/deep-base.log" 2>&1
DBASE_RC=$?
if [ "$DBASE_RC" -ne 0 ]; then
  bad "the breadth baseline for the steering arms exited $DBASE_RC"
  tail -15 "$WORK/deep-base.log" | sed 's/^/      /' >&2
fi

lens_only() {  # $1 = out dir (a clone of the breadth base), $2.. = extra flags
  lo_out="$1"; shift
  "$ZONEHUNT" --repo "$DREPO" --out "$lo_out" --deep-hunt --deep-hunt-only --deep-hunt-max-lenses 1 \
    --invariant-fixture "$DEEP_FIX/handler-fixture.t.sol" \
    --backend mock --agentis "$DSTUB" "$@" >"$lo_out.log" 2>&1
}

if [ "$DBASE_RC" -eq 0 ]; then
  S_OFF="$WORK/steer-off"; cp -R "$DBASE" "$S_OFF"; lens_only "$S_OFF"; OFF_RC=$?
  S_ON="$WORK/steer-on";   cp -R "$DBASE" "$S_ON"
  lens_only "$S_ON" --payable-impacts "Critical: Oracle price manipulation"; ON_RC=$?
  S_CUST="$WORK/steer-custody"; cp -R "$DBASE" "$S_CUST"
  lens_only "$S_CUST" --payable-impacts "Critical: Protocol insolvency"; CUST_RC=$?
  TSV_OFF="$S_OFF/.deep-hunt-targets.tsv"
  TSV_ON="$S_ON/.deep-hunt-targets.tsv"
  TSV_CUST="$S_CUST/.deep-hunt-targets.tsv"

  if [ "$OFF_RC" -eq 0 ] && [ "$ON_RC" -eq 0 ] && [ "$CUST_RC" -eq 0 ] \
     && [ -f "$TSV_OFF" ] && [ -f "$TSV_ON" ] && [ -f "$TSV_CUST" ]; then
    ok "all three lens-only arms exit 0 and emit a .deep-hunt-targets.tsv"
  else
    bad "a lens-only arm failed (off=$OFF_RC on=$ON_RC custody=$CUST_RC)"
    tail -15 "$S_ON.log" | sed 's/^/      /' >&2
  fi

  # (a) INERTNESS: without --payable-impacts the selection is the pre-#1930 golden, byte for byte.
  GOLDEN="$WORK/golden-targets.tsv"
  printf 'src\tsrc/Vault.sol\tC10\n' > "$GOLDEN"
  if [ -f "$TSV_OFF" ] && diff -u "$GOLDEN" "$TSV_OFF" >"$WORK/off.diff" 2>&1; then
    ok "a) without --payable-impacts the .deep-hunt-targets.tsv is byte-identical to the pre-#1930 selection (custody lens C10)"
  else
    bad "a) the flagless selection drifted from the pre-#1930 golden:"; sed 's/^/      /' "$WORK/off.diff" >&2
  fi

  # (b) STEERED: an ORACLE payable impact makes the SAME zone hunt C2 instead — the row count, zone and target
  #     are unchanged, so only the LENS moved.
  if [ -f "$TSV_ON" ] && [ "$(awk -F'\t' '$1=="src"{print $3}' "$TSV_ON")" = "C2" ] \
     && [ "$(awk -F'\t' '$1=="src"{print $2}' "$TSV_ON")" = "src/Vault.sol" ] \
     && [ "$(grep -c . "$TSV_ON")" = "$(grep -c . "$TSV_OFF")" ]; then
    ok "b) --payable-impacts 'Oracle price manipulation' moves the surviving lens C10 -> C2 (same zone, same target, same row count)"
  else
    bad "b) the oracle steering did not take effect; TSV was:"; sed 's/^/      /' "$TSV_ON" >&2
  fi

  # (c) NOT A BLIND REORDER: an insolvency impact prefers the custody lens, which is ALREADY first — so the
  #     selection is unchanged. A partition that merely shuffled rows would fail this.
  if [ -f "$TSV_CUST" ] && diff -q "$TSV_OFF" "$TSV_CUST" >/dev/null 2>&1; then
    ok "c) --payable-impacts 'Protocol insolvency' leaves the custody-first selection unchanged (a stable partition, not a shuffle)"
  else
    bad "c) an already-preferred lens set changed the selection:"; sed 's/^/      /' "$TSV_CUST" >&2
  fi

  # (d) The preference is REPORTED, so an operator can see why a lens was chosen.
  if grep -q 'payable-impact lens preference: C2' "$S_ON.log"; then
    ok "d) the run names its payable-impact lens preference on stderr"
  else
    bad "d) no payable-impact lens preference line on stderr"
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: one mapping table (lib/impact-lens.py) drives both steering seams — the brief text names the"
  note "      program's payable impacts with their lenses and a floor-derived severity bar, and the deep-hunt"
  note "      prefers the lens those impacts imply when the fan-out is capped. Both are provably inert with the"
  note "      flags absent, and no class is ever invented for an unmapped impact. Offline; never submits."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
