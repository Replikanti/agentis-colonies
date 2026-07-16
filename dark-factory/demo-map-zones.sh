#!/usr/bin/env bash
# demo-map-zones.sh — OFFLINE, DETERMINISTIC proof of M1 zone-mapping (#1612, epic #1611): map-zones.sh
# (shell plumbing) + auditor/agents/zone-mapper.ag (substrate classification) auto-derive a target's
# DISCOVERY manifest and emit zones.json + scope.tsv, the pipe-delimited manifest run-discovery.sh --scope
# already parses byte-for-byte — closing the auto-map -> hunt loop.
#
# TWO parts:
#   1) MAP + ROUND-TRIP (always, CI-safe, no toolchain): over a throwaway `git init` copy of
#      fixtures/zone-map/ (an "audited" baseline + a post-audit-churn commit), runs map-zones.sh with
#      --since + --fixture (the offline substrate stub) and asserts the emitted zones.json (valid, 7 keys),
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
need = {"id", "name", "files", "loc", "hardening_score", "bug_classes_likely", "description"}
for z in zones:
    assert set(z.keys()) == need, "zone %r keys %r != %r" % (z.get("id"), set(z.keys()), need)
    assert isinstance(z["files"], list) and z["files"], "zone %r has no files" % z.get("id")
    assert isinstance(z["bug_classes_likely"], list), "bug_classes_likely not a list"
    assert isinstance(z["loc"], int) and isinstance(z["hardening_score"], int), "loc/hardening not ints"
PY
then ok "zones.json is a valid JSON array; every zone has exactly the 7 keys (id/name/files/loc/hardening_score/bug_classes_likely/description)"
else bad "zones.json schema assertion failed"
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
# (d2) REGRESSION (#1701): fn_names()[:8] used to truncate a big contract's function-slice by pure
#      declaration order, so a value-moving/recovery function declared AFTER 8 admin/setter functions never
#      made the slice (reproduced live against dodo's Gateway* files). The liquidation fixture now declares
#      4 admin setters ahead of liquidate/redeem specifically to reproduce that shape; assert the emitted
#      scope.tsv slice for the liquidation zone still surfaces `liquidate` (and `redeem`) despite them.
# ----------------------------------------------------------------------------------------------------------
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
assert "liquidate" in fn_names, "liquidate missing from the liquidation zone's function slice: %r" % sorted(fn_names)
assert "redeem" in fn_names, "redeem missing from the liquidation zone's function slice: %r" % sorted(fn_names)
PY
then ok "liquidation zone's function-slice surfaces liquidate + redeem despite 8+ admin setters preceding them in the file (#1701)"
else bad "fn-slice priority regression: liquidate/redeem dropped from the liquidation zone's function slice"
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
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — M1 zone-mapping (map-zones.sh + zone-mapper.ag) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
