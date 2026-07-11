#!/usr/bin/env bash
# demo-seam-lens.sh — OFFLINE, DETERMINISTIC proof of the INTEGRATION-SEAM / COMPOSABILITY hunt LENS (#1644):
# a first-class C15 bug-class that the zone-mapper auto-tags on integration/adapter zones and the brief-writer
# turns into a dedicated seam-focused hunt subsection. Formalizes the ad-hoc lens validated on recent hunts.
#
# The lens is THREE additive pieces over the shipped M1/M2 machinery (no new agent):
#   1) bug-taxonomy.md gains a `## C15 — Integration-seam / composability` class (the 6 heuristics).
#   2) zone-mapper.ag gains a PROMPT-ONLY detection rule: include C15 when a zone's contracts are named
#      *Adapter/*Guard/*Bridge/*Oracle/*Wrapper/*Router/*Strategy OR import/call an external protocol.
#   3) brief-writer.ag gains a conditional `seamClause` (mirrors residualClause/boundaryClause): when the
#      zone carries the comma-bounded token `,C15,` it appends the seam hunt guide; ABSENT -> "" -> the brief
#      is BYTE-IDENTICAL to today (the load-bearing zero-regression guarantee, pinned by demo-gen-briefs.sh).
#
# TWO parts:
#   1) MAP -> BRIEF (always, CI-safe, no toolchain): over a throwaway `git init` copy of fixtures/seam-lens/
#      (integration-pattern contracts + a plain-token negative control), chains map-zones.sh --fixture into
#      gen-briefs.sh --fixture and asserts: the two integration zones (adapter vault / oracle wrapper) carry
#      C15 in scope.tsv and their briefs carry the `## Integration-seam hunt guide` subsection with all 6
#      heuristics, while the plain-token zone is C15-free AND its brief carries NO seam subsection (the
#      negative control / no-C15 byte-clean); detection-semantics consistency (integration-named/importing
#      zones == the C15 set); and read-only/never-submit on the map/brief path.
#   2) SUBSTRATE source-guard (always; live via --backend mock only when agentis is on PATH): asserts the C15
#      taxonomy class + the 6 heuristic anchors, the zone-mapper detection rule, and the brief-writer
#      conditional seamClause keyed on `,C15,`; then runs map-zones.sh + gen-briefs.sh --backend mock
#      end-to-end over the fixture (mock does not reason, so only clean execution is asserted), [SKIP] else.
#
# Usage:  dark-factory/demo-seam-lens.sh
# Requires: git + python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MAPZONES="$HERE/map-zones.sh"
GENBRIEFS="$HERE/gen-briefs.sh"
MAPPER="$HERE/auditor/agents/zone-mapper.ag"
WRITER="$HERE/auditor/agents/brief-writer.ag"
TAXONOMY="$HERE/auditor/bug-taxonomy.md"
FIXTURE_DIR="$HERE/fixtures/seam-lens"
ZONES_FIXTURE="$FIXTURE_DIR/zones.fixture.txt"
BRIEFS_FIXTURE="$FIXTURE_DIR/briefs.fixture.txt"

FAILS=0
note() { echo "demo-seam-lens.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
[ -x "$MAPZONES" ]  || { note "map-zones.sh not found / not executable: $MAPZONES" >&2; exit 3; }
[ -x "$GENBRIEFS" ] || { note "gen-briefs.sh not found / not executable: $GENBRIEFS" >&2; exit 3; }
[ -f "$MAPPER" ]    || { note "zone-mapper.ag not found: $MAPPER" >&2; exit 3; }
[ -f "$WRITER" ]    || { note "brief-writer.ag not found: $WRITER" >&2; exit 3; }
[ -f "$TAXONOMY" ]  || { note "bug-taxonomy.md not found: $TAXONOMY" >&2; exit 3; }
[ -f "$ZONES_FIXTURE" ]  || { note "zones.fixture.txt not found: $ZONES_FIXTURE" >&2; exit 3; }
[ -f "$BRIEFS_FIXTURE" ] || { note "briefs.fixture.txt not found: $BRIEFS_FIXTURE" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-seam-lens.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# (a) Build the throwaway git fixture and run map-zones.sh --fixture -> zones.json + scope.tsv.
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/target"
mkdir -p "$REPO"
cp -R "$FIXTURE_DIR/contracts" "$REPO/contracts"
git -C "$REPO" init -q
git -C "$REPO" config user.email demo@example.invalid
git -C "$REPO" config user.name "demo"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "seam-lens fixture baseline"

ZM="$WORK/zm"
note "1) map-zones.sh --fixture over the integration-pattern fixture -> zones.json + scope.tsv ..."
"$MAPZONES" --repo "$REPO" --out "$ZM" --fixture "$ZONES_FIXTURE" >/dev/null 2>"$WORK/map.err"
RC=$?
[ "$RC" -eq 0 ] && [ -f "$ZM/zones.json" ] && [ -f "$ZM/scope.tsv" ] \
  && ok "map-zones.sh emitted zones.json + scope.tsv" \
  || { bad "map-zones.sh did not produce the map (exit $RC)"; sed 's/^/      /' "$WORK/map.err" >&2; }

# ----------------------------------------------------------------------------------------------------------
# (b) The two integration zones carry C15 in scope.tsv; the plain-token negative-control zone does NOT — the
#     C15 tag round-trips through map-zones.sh into the manifest exactly, and only on integration zones.
# ----------------------------------------------------------------------------------------------------------
note "2) scope.tsv tags the integration zones C15 and the plain-token zone NOT ..."
if python3 - "$ZM/scope.tsv" <<'PY'
import sys
classes_by_subsys = {}
for l in open(sys.argv[1], encoding="utf-8"):
    l = l.rstrip("\n")
    if not l.strip() or l.lstrip().startswith("#"):
        continue
    subsys, cls, _files = [p.strip() for p in l.split("|")]
    classes_by_subsys[subsys] = [c.strip() for c in cls.split(",") if c.strip()]
assert "C15" in classes_by_subsys.get("multi-adapter vault", []), "adapter vault zone is not tagged C15"
assert "C15" in classes_by_subsys.get("chainlink oracle wrapper", []), "oracle wrapper zone is not tagged C15"
assert "C15" not in classes_by_subsys.get("plain token", []), "the plain-token negative control was tagged C15"
PY
then ok "the adapter-vault and oracle-wrapper zones carry C15; the plain-token zone does NOT (negative control)"
else bad "scope.tsv C15 tagging assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) Detection-semantics consistency: every zone whose contract file NAMES match an integration pattern
#     (*Adapter/*Guard/*Bridge/*Oracle/*Wrapper/*Router/*Strategy) OR whose files IMPORT an external protocol
#     is in the C15 set; the plain zone (no pattern name, no external import) is not.
# ----------------------------------------------------------------------------------------------------------
note "3) detection-semantics: integration-named / external-importing zones == the C15 set ..."
if python3 - "$ZM/zones.json" "$REPO" <<'PY'
import sys, os, re, json
zones = json.load(open(sys.argv[1], encoding="utf-8"))
repo = sys.argv[2]
suffix = re.compile(r"(Adapter|Guard|Bridge|Oracle|Wrapper|Router|Strategy)\b")
def integrates(z):
    for f in z["files"]:
        base = os.path.basename(f)
        if suffix.search(base):
            return True
        try:
            txt = open(os.path.join(repo, f), encoding="utf-8", errors="ignore").read()
        except Exception:
            txt = ""
        # an import of an external protocol's interface (a package path, not a local relative import)
        for m in re.findall(r'import\s+.*?["\']([^"\']+)["\']', txt):
            if not m.startswith("."):
                return True
    return False
for z in zones:
    has = "C15" in z["bug_classes_likely"]
    want = integrates(z)
    assert has == want, "zone %r: C15=%s but integration-pattern=%s" % (z["id"], has, want)
# and at least one of each polarity is present (a meaningful test, not vacuously true)
polarities = set("C15" in z["bug_classes_likely"] for z in zones)
assert polarities == {True, False}, "fixture must exercise BOTH an integration zone and a non-integration zone"
PY
then ok "C15 presence matches integration-pattern detection for every zone (both polarities exercised)"
else bad "detection-semantics consistency assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) gen-briefs.sh --fixture -> per-zone briefs; the C15 zones' briefs carry the seam hunt guide + all 6
#     heuristics, and the plain-token zone's brief carries NO seam subsection (no-C15 byte-clean).
# ----------------------------------------------------------------------------------------------------------
OUT="$WORK/out"
note "4) gen-briefs.sh --fixture -> briefs; C15 zones carry the seam guide, the plain zone does NOT ..."
"$GENBRIEFS" --zones "$ZM/zones.json" --scope "$ZM/scope.tsv" --out "$OUT" --fixture "$BRIEFS_FIXTURE" \
  >/dev/null 2>"$WORK/gen.err"
RC=$?
[ "$RC" -eq 0 ] && [ -f "$OUT/briefs/zone_briefs.json" ] \
  && ok "gen-briefs.sh emitted per-zone briefs + index" \
  || { bad "gen-briefs.sh exited $RC / no index"; sed 's/^/      /' "$WORK/gen.err" >&2; }

if python3 - "$OUT/briefs" <<'PY'
import sys, os
briefs = sys.argv[1]
heuristics = [
    "ASSET/BALANCE MIS-ACCOUNTING",
    "NEW/EXOTIC ADAPTER BIAS",
    "GLOBAL VALUE-CONSERVATION BACKSTOP",
    "CROSS-INTEGRATION COMPOSITION",
    "SCOPE DISCIPLINE",
    "FRESHNESS SYNERGY",
]
def read(zid):
    return open(os.path.join(briefs, "brief_%s.md" % zid), encoding="utf-8").read()
for zid in ("contracts_adapters", "contracts_oracle"):
    t = read(zid)
    assert "## Integration-seam hunt guide" in t, "C15 brief %r missing the seam hunt-guide subsection" % zid
    missing = [h for h in heuristics if h not in t]
    assert not missing, "C15 brief %r missing heuristics: %r" % (zid, missing)
tok = read("contracts_token")
assert "Integration-seam hunt guide" not in tok, "the non-C15 token brief leaked a seam subsection"
assert not any(h in tok for h in heuristics), "the non-C15 token brief leaked a seam heuristic"
PY
then ok "C15 zones' briefs carry the seam hunt guide + all 6 heuristics; the plain-token brief is seam-free"
else bad "brief seam-subsection / negative-control assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) READ-ONLY / NEVER-SUBMIT: no network or submission verb on the map/brief path this demo drives.
# ----------------------------------------------------------------------------------------------------------
note "5) read-only / never-submit on the map + brief path ..."
seam_egress=0
for s in "$MAPZONES" "$GENBRIEFS"; do
  if grep -vE '^[[:space:]]*#' "$s" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
    seam_egress=1
  fi
done
if [ "$seam_egress" -eq 0 ]; then
  ok "no network / no submission verb on the seam-lens map/brief path (read-only, never submits)"
else
  bad "a network/submission verb appears on the seam-lens map/brief path"
fi

# ----------------------------------------------------------------------------------------------------------
# SECOND PART — substrate source-guard: the C15 class + the detection rule + the conditional seamClause.
# ----------------------------------------------------------------------------------------------------------
note "6) source-guarding the C15 taxonomy class + the 6 heuristics ..."
if grep -q '^## C15 ' "$TAXONOMY"; then
  ok "bug-taxonomy.md declares the '## C15 ' Integration-seam class (bounds C14, feeds class_section)"
else
  bad "bug-taxonomy.md missing the '## C15 ' class header"
fi
tax_missing=""
for h in "MIS-ACCOUNTING" "ADAPTER BIAS" "VALUE-CONSERVATION BACKSTOP" "CROSS-INTEGRATION COMPOSITION" "SCOPE DISCIPLINE" "FRESHNESS SYNERGY"; do
  grep -q "$h" "$TAXONOMY" || tax_missing="$tax_missing [$h]"
done
if [ -z "$tax_missing" ]; then
  ok "the C15 taxonomy section carries all 6 hunt heuristics"
else
  bad "bug-taxonomy.md C15 section missing heuristics:$tax_missing"
fi

note "7) source-guarding the zone-mapper C15 detection rule ..."
if grep -q 'INTEGRATION-SEAM DETECTION RULE' "$MAPPER" && grep -q 'C15' "$MAPPER" \
   && grep -q 'Adapter' "$MAPPER" && grep -q 'Wrapper' "$MAPPER"; then
  ok "zone-mapper.ag carries the prompt-only integration-pattern C15 detection rule"
else
  bad "zone-mapper.ag missing the C15 integration-seam detection rule"
fi

note "8) source-guarding the brief-writer conditional seamClause (no-C15 byte-identical) ..."
if grep -q 'seamClause' "$WRITER" && grep -q ',C15,' "$WRITER" && grep -q 'hasSeam' "$WRITER" \
   && grep -q 'seamClause' "$WRITER" && grep -q '{ "" }' "$WRITER"; then
  ok "brief-writer.ag has the conditional seamClause keyed on the comma-bounded ,C15, token (empty when absent)"
else
  bad "brief-writer.ag missing the conditional seamClause / the ,C15, key / the empty-when-absent branch"
fi

if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the live end-to-end map+brief seam check"
else
  OUTM="$WORK/out-mock"
  "$MAPZONES" --repo "$REPO" --out "$OUTM/zm" --backend mock >/dev/null 2>"$WORK/mock-map.err"
  RC1=$?
  "$GENBRIEFS" --zones "$OUTM/zm/zones.json" --scope "$OUTM/zm/scope.tsv" --out "$OUTM/out" --repo "$REPO" \
    --backend mock >/dev/null 2>"$WORK/mock-gen.err"
  RC2=$?
  if [ "$RC1" -eq 0 ] && [ -f "$OUTM/zm/zones.json" ] && [ "$RC2" -eq 0 ] && [ -f "$OUTM/out/briefs/zone_briefs.json" ]; then
    ok "map-zones.sh + gen-briefs.sh --backend mock ran zone-mapper.ag + brief-writer.ag end-to-end (exit 0)"
  else
    bad "the --backend mock end-to-end run failed (map $RC1 / gen $RC2):"
    sed 's/^/      /' "$WORK/mock-map.err" | head -10 >&2
    sed 's/^/      /' "$WORK/mock-gen.err" | head -10 >&2
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the C15 integration-seam / composability lens (taxonomy + zone-mapper + brief-writer) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
