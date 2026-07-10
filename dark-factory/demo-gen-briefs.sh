#!/usr/bin/env bash
# demo-gen-briefs.sh — OFFLINE, DETERMINISTIC proof of M2 brief-generation (#1619, epic #1611): gen-briefs.sh
# (shell plumbing) + auditor/agents/brief-writer.ag (substrate authoring) turn M1's zones.json + scope.tsv into
# a per-zone HUNT BRIEF in the EXACT format hunter.ag consumes via SCOPE_BRIEF, and the round-trip proves a
# generated brief resolves + would be handed to the hunter.
#
# TWO parts:
#   1) MAP -> BRIEF -> ROUND-TRIP (always, CI-safe, no toolchain): over a throwaway `git init` copy of
#      fixtures/zone-map/, chains map-zones.sh --fixture (M1 -> zones.json + scope.tsv) into gen-briefs.sh
#      --fixture (the offline brief-body stub) and asserts one non-empty brief_<zone_id>.md per zone + a
#      zone_briefs.json index; each brief carries all four elements (>=1 of its zone's bug classes cross-checked
#      against scope.tsv, in-scope language, out-of-scope language, the honesty mandate); brief-safety (no NUL,
#      <= 2000 lines, no bare CANDIDATE|/BLACKBOARD- token, no leaked sentinel); the run-discovery.sh --brief
#      --list-cells ROUND-TRIP (a BRIEF| line + the zone's CELL| line, offline, no agentis); residual folding
#      with --audit-residuals; and the read-only/never-submit brief path.
#   2) SUBSTRATE (source-guard always; live only when agentis is on PATH): asserts brief-writer.ag's cb decl,
#      env contract, BRIEF-BEGIN/BRIEF-END + SKIP tokens, one prompt(), and learn/memo tail, then runs
#      gen-briefs.sh --backend mock over the fixture (mock does not reason, so only clean end-to-end execution
#      is asserted), [SKIP] otherwise.
#
# Usage:  dark-factory/demo-gen-briefs.sh
# Requires: git + python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MAPZONES="$HERE/map-zones.sh"
GENBRIEFS="$HERE/gen-briefs.sh"
DISCOVERY="$HERE/run-discovery.sh"
WRITER="$HERE/auditor/agents/brief-writer.ag"
FIXTURE_DIR="$HERE/fixtures/zone-map"
ZONES_FIXTURE="$FIXTURE_DIR/zones.fixture.txt"
BRIEFS_FIXTURE="$FIXTURE_DIR/briefs.fixture.txt"
RESIDUALS_FIXTURE="$FIXTURE_DIR/residuals.fixture.txt"

# The zone we anchor the round-trip + residual-fold assertions to (deterministic from the fixtures).
ANCHOR_ID="contracts_vault"
ANCHOR_SUBSYS="vault deposits"

FAILS=0
note() { echo "demo-gen-briefs.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
[ -x "$MAPZONES" ]  || { note "map-zones.sh not found / not executable: $MAPZONES" >&2; exit 3; }
[ -x "$GENBRIEFS" ] || { note "gen-briefs.sh not found / not executable: $GENBRIEFS" >&2; exit 3; }
[ -x "$DISCOVERY" ] || { note "run-discovery.sh not found / not executable: $DISCOVERY" >&2; exit 3; }
[ -f "$WRITER" ]    || { note "brief-writer.ag not found: $WRITER" >&2; exit 3; }
[ -f "$ZONES_FIXTURE" ]   || { note "zones.fixture.txt not found: $ZONES_FIXTURE" >&2; exit 3; }
[ -f "$BRIEFS_FIXTURE" ]  || { note "briefs.fixture.txt not found: $BRIEFS_FIXTURE" >&2; exit 3; }
[ -f "$RESIDUALS_FIXTURE" ] || { note "residuals.fixture.txt not found: $RESIDUALS_FIXTURE" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-gen-briefs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# (a) Build the throwaway git fixture and run map-zones.sh --fixture -> zones.json + scope.tsv (M1 -> M2 chain).
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/target"
mkdir -p "$REPO"
cp -R "$FIXTURE_DIR/contracts" "$REPO/contracts"
git -C "$REPO" init -q
git -C "$REPO" config user.email demo@example.invalid
git -C "$REPO" config user.name "demo"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "audited baseline"

ZM="$WORK/zm"
note "1) map-zones.sh --fixture -> zones.json + scope.tsv (M1 chain, no agentis) ..."
"$MAPZONES" --repo "$REPO" --out "$ZM" --fixture "$ZONES_FIXTURE" >/dev/null 2>"$WORK/map.err"
RC=$?
[ "$RC" -eq 0 ] && [ -f "$ZM/zones.json" ] && [ -f "$ZM/scope.tsv" ] \
  && ok "map-zones.sh emitted zones.json + scope.tsv" \
  || { bad "map-zones.sh did not produce the M1 inputs (exit $RC)"; sed 's/^/      /' "$WORK/map.err" >&2; }

# ----------------------------------------------------------------------------------------------------------
# (b) gen-briefs.sh --fixture over the M1 outputs -> one non-empty brief per zone + zone_briefs.json index.
# ----------------------------------------------------------------------------------------------------------
OUT="$WORK/out"
note "2) gen-briefs.sh --fixture -> per-zone briefs (offline, no LLM) ..."
"$GENBRIEFS" --zones "$ZM/zones.json" --scope "$ZM/scope.tsv" --out "$OUT" --fixture "$BRIEFS_FIXTURE" \
  >/dev/null 2>"$WORK/gen.err"
RC=$?
[ "$RC" -eq 0 ] && ok "gen-briefs.sh exits 0 on the fixture" \
  || { bad "gen-briefs.sh exited $RC"; sed 's/^/      /' "$WORK/gen.err" >&2; }
[ -f "$OUT/briefs/zone_briefs.json" ] && ok "emitted briefs/zone_briefs.json index" || bad "zone_briefs.json not emitted"

if python3 - "$ZM/zones.json" "$OUT/briefs" <<'PY'
import sys, os, json
zones = json.load(open(sys.argv[1], encoding="utf-8"))
briefs = sys.argv[2]
idx = json.load(open(os.path.join(briefs, "zone_briefs.json"), encoding="utf-8"))
assert len(idx) == len(zones), "index has %d entries != %d zones" % (len(idx), len(zones))
for z in zones:
    zid = z["id"]
    assert zid in idx, "zone %r missing from the index" % zid
    p = os.path.join(briefs, idx[zid]["brief"])
    assert os.path.exists(p), "brief file %r missing" % p
    assert os.path.getsize(p) > 0, "brief %r is empty" % p
    assert idx[zid]["brief"] == "brief_%s.md" % zid, "brief filename %r != brief_%s.md" % (idx[zid]["brief"], zid)
PY
then ok "one non-empty brief_<zone_id>.md per zone, indexed in zone_briefs.json"
else bad "per-zone brief / index assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) Each brief carries all four elements: >=1 of its zone's bug classes (cross-checked against scope.tsv),
#     in-scope language, out-of-scope language, the honesty mandate.
# ----------------------------------------------------------------------------------------------------------
note "3) each brief carries classes + in/out-of-scope + honesty mandate ..."
if python3 - "$ZM/scope.tsv" "$ZM/zones.json" "$OUT/briefs" <<'PY'
import sys, os, json
scope, zonesf, briefs = sys.argv[1], sys.argv[2], sys.argv[3]
classes_by_subsys = {}
for l in open(scope, encoding="utf-8"):
    l = l.rstrip("\n")
    if not l.strip() or l.lstrip().startswith("#"):
        continue
    subsys, cls, _files = [p.strip() for p in l.split("|")]
    classes_by_subsys[subsys] = [c.strip() for c in cls.split(",") if c.strip()]
zones = json.load(open(zonesf, encoding="utf-8"))
idx = json.load(open(os.path.join(briefs, "zone_briefs.json"), encoding="utf-8"))
for z in zones:
    zid, name = z["id"], z["name"]
    text = open(os.path.join(briefs, idx[zid]["brief"]), encoding="utf-8").read()
    classes = classes_by_subsys.get(name, [])
    assert any(c in text for c in classes), "brief %r names none of its scope.tsv classes %r" % (zid, classes)
    assert "## In scope" in text and "Medium/High" in text, "brief %r missing in-scope language" % zid
    assert "## Out of scope" in text, "brief %r missing out-of-scope language" % zid
    assert "## Honesty mandate" in text and "forge-verify" in text, "brief %r missing the honesty mandate" % zid
PY
then ok "every brief names >=1 scope.tsv class + carries in-scope, out-of-scope, and the honesty mandate"
else bad "brief-content (four-element) assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) Brief-safety: no NUL, <= 2000 lines, no bare CANDIDATE|/BLACKBOARD- token, no leaked sentinel (a brief is
#     injected verbatim into hunter.ag's prompt and must never masquerade as a scraped hunter output line).
# ----------------------------------------------------------------------------------------------------------
note "4) brief-safety (markdown-safe, no scraped-token masquerade) ..."
if python3 - "$OUT/briefs" <<'PY'
import sys, os, json
briefs = sys.argv[1]
idx = json.load(open(os.path.join(briefs, "zone_briefs.json"), encoding="utf-8"))
for zid, meta in idx.items():
    raw = open(os.path.join(briefs, meta["brief"]), "rb").read()
    assert b"\x00" not in raw, "NUL byte in brief %r" % zid
    text = raw.decode("utf-8", "replace")
    lines = text.split("\n")
    assert len(lines) <= 2000, "brief %r exceeds the 2000-line SCOPE_BRIEF window (%d)" % (zid, len(lines))
    assert not any(l.startswith("CANDIDATE|") for l in lines), "brief %r has a bare CANDIDATE| line" % zid
    assert "BLACKBOARD-" not in text, "brief %r carries a BLACKBOARD- token" % zid
    assert "DARK-FACTORY:BRIEF-BEGIN" not in text and "DARK-FACTORY:BRIEF-END" not in text, \
        "brief %r leaked a sentinel" % zid
PY
then ok "every brief is markdown-safe: no NUL, <= 2000 lines, no bare CANDIDATE|/BLACKBOARD- token, no sentinel"
else bad "brief-safety assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) ROUND-TRIP: run-discovery.sh --brief <generated> --only <subsystem> --list-cells prints a BRIEF| line
#     (the brief resolved + is consumable as SCOPE_BRIEF) AND the zone's CELL| line(s) — offline, no agentis.
# ----------------------------------------------------------------------------------------------------------
note "5) round-trip: run-discovery.sh --brief --list-cells acknowledges the generated brief ..."
BRIEF_FILE="$OUT/briefs/brief_${ANCHOR_ID}.md"
[ -f "$BRIEF_FILE" ] || bad "anchor brief not found: $BRIEF_FILE"
"$DISCOVERY" --repo "$REPO" --scope "$ZM/scope.tsv" --brief "$BRIEF_FILE" --only "$ANCHOR_SUBSYS" --list-cells \
  >"$WORK/rt.txt" 2>"$WORK/rt.err"
RC=$?
[ "$RC" -eq 0 ] && ok "run-discovery.sh --brief --list-cells exits 0 (offline, no agentis)" \
  || { bad "run-discovery.sh --brief --list-cells exited $RC"; sed 's/^/      /' "$WORK/rt.err" >&2; }
if python3 - "$WORK/rt.txt" "$BRIEF_FILE" "$ANCHOR_SUBSYS" <<'PY'
import sys, os
out, brief, subsys = sys.argv[1], sys.argv[2], sys.argv[3]
lines = [l.rstrip("\n") for l in open(out, encoding="utf-8")]
briefline = [l for l in lines if l.startswith("BRIEF|")]
assert len(briefline) == 1, "expected exactly one BRIEF| line, got %d" % len(briefline)
_, abspath, nlines = briefline[0].split("|")
assert os.path.isabs(abspath), "BRIEF| path is not absolute: %r" % abspath
assert os.path.samefile(abspath, brief), "BRIEF| path %r != the generated brief" % abspath
assert nlines.isdigit() and int(nlines) > 0, "BRIEF| line-count is not a positive int: %r" % nlines
cells = [l for l in lines if l.startswith("CELL|" + subsys + "|")]
assert cells, "no CELL| line for the anchored subsystem %r" % subsys
PY
then ok "prints one BRIEF|<abs>|<lines> (resolved to the generated brief) AND the anchored zone's CELL| line(s)"
else bad "the --brief round-trip assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (f) Residual folding: re-run gen-briefs.sh with --audit-residuals; the matched zone's brief now mentions a
#     residual hint and its out-of-scope section names a BOUNDARY item.
# ----------------------------------------------------------------------------------------------------------
note "6) residual folding: --audit-residuals folds RESIDUAL leads + seeds out-of-scope from BOUNDARY ..."
OUT2="$WORK/out-res"
"$GENBRIEFS" --zones "$ZM/zones.json" --scope "$ZM/scope.tsv" --out "$OUT2" --fixture "$BRIEFS_FIXTURE" \
  --audit-residuals "$RESIDUALS_FIXTURE" >/dev/null 2>"$WORK/gen2.err"
RC=$?
[ "$RC" -eq 0 ] && ok "gen-briefs.sh --audit-residuals exits 0" \
  || { bad "gen-briefs.sh --audit-residuals exited $RC"; sed 's/^/      /' "$WORK/gen2.err" >&2; }
if python3 - "$OUT2/briefs/brief_${ANCHOR_ID}.md" "$RESIDUALS_FIXTURE" <<'PY'
import sys
brief, resf = sys.argv[1], sys.argv[2]
text = open(brief, encoding="utf-8").read()
residuals = [l.rstrip("\n") for l in open(resf, encoding="utf-8") if l.startswith("RESIDUAL|")]
boundaries = [l.rstrip("\n") for l in open(resf, encoding="utf-8") if l.startswith("BOUNDARY|")]
assert "Audit-residual leads" in text, "the matched brief has no residual-leads section"
# a fragment of the vault residual's why/sketch must appear in the folded brief
assert "withdraw-path rounding" in text, "the matched RESIDUAL lead was not folded into the brief"
assert "## Out of scope" in text
# a BOUNDARY summary must seed the out-of-scope section
oos = text.split("## Out of scope", 1)[1]
assert any(b.split("|", 1)[1].strip() in oos for b in boundaries), "no BOUNDARY item seeds the out-of-scope section"
PY
then ok "the matched zone's brief folds a RESIDUAL hint and names a BOUNDARY item in out-of-scope"
else bad "residual folding assertion failed"
fi

# ----------------------------------------------------------------------------------------------------------
# (g) READ-ONLY / NEVER-SUBMIT: no network or submission verb anywhere on the brief path.
# ----------------------------------------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$GENBRIEFS" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
  bad "gen-briefs.sh invokes a network/submission verb on the brief path"
else
  ok "gen-briefs.sh has no network / no submission verb on the brief path (read-only, never submits)"
fi

# ----------------------------------------------------------------------------------------------------------
# SECOND PART — substrate: source-guard brief-writer.ag always; run live via --backend mock when agentis on PATH.
# ----------------------------------------------------------------------------------------------------------
note "7) source-guarding auditor/agents/brief-writer.ag ..."
if grep -q '^cb 300000;' "$WRITER"; then
  ok "brief-writer.ag declares cb 300000 (matches the sibling batch agents)"
else
  bad "brief-writer.ag missing the cb 300000 declaration"
fi
missing_env=""
for v in TARGET_DIR ZONE_ID ZONE_CLASSES TAXONOMY; do
  grep -q "getenv(\"$v\")" "$WRITER" || missing_env="$missing_env $v"
done
if [ -z "$missing_env" ]; then
  ok "brief-writer.ag reads the env contract (TARGET_DIR/ZONE_ID/ZONE_CLASSES/TAXONOMY)"
else
  bad "brief-writer.ag missing getenv for:$missing_env"
fi
if grep -q 'DARK-FACTORY:BRIEF-BEGIN|' "$WRITER" && grep -q 'DARK-FACTORY:BRIEF-END' "$WRITER" \
   && grep -q '"SKIP"\|: SKIP' "$WRITER" && grep -q 'prompt(' "$WRITER"; then
  ok "brief-writer.ag emits the BRIEF-BEGIN/BRIEF-END block (or SKIP) via one prompt()"
else
  bad "brief-writer.ag missing the BRIEF-BEGIN/BRIEF-END + SKIP tokens / prompt()"
fi
if grep -q 'learn("brief"' "$WRITER" && grep -q 'memo_write("brief-writer:last_check"' "$WRITER"; then
  ok "brief-writer.ag records the authoring (learn) + writes its last_check memo"
else
  bad "brief-writer.ag missing the learn/memo tail"
fi

if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the live end-to-end brief-writer check"
else
  OUT3="$WORK/out-mock"
  "$GENBRIEFS" --zones "$ZM/zones.json" --scope "$ZM/scope.tsv" --out "$OUT3" --repo "$REPO" --backend mock \
    >/dev/null 2>"$WORK/mock.err"
  RC=$?
  if [ "$RC" -eq 0 ] && [ -f "$OUT3/briefs/zone_briefs.json" ]; then
    ok "gen-briefs.sh --backend mock ran brief-writer.ag end-to-end over the fixture (exit 0, briefs emitted)"
  else
    bad "gen-briefs.sh --backend mock failed (exit $RC):"
    sed 's/^/      /' "$WORK/mock.err" | head -20 >&2
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — M2 brief-generation (gen-briefs.sh + brief-writer.ag) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
