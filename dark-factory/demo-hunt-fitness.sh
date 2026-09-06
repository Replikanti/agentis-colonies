#!/usr/bin/env bash
# demo-hunt-fitness.sh — proof of the #1711 corpus-bench -> hunter fitness FEEDBACK LOOP (learn + recommend).
# The bench derives per-class REAL-BUG precision from the already-computed HIT/MISS matching and imports it as
# agentis `hunt-fitness` knowledge (LEARN); zone-mapper.ag consumes that fitness via recommend()/query_knowledge
# to reorder a zone's class CSV so historically-real-bug classes hunt first (ACT). This demo pins the whole
# mechanism WITHOUT touching the live corpus-bench run: everything functional uses --backend mock (no LLM).
#
# TWO parts:
#   1) SOURCE-GUARDS (always, CI-safe, no toolchain): the five wiring points are present in-source —
#      score-match.py's additive --per-lead, bench-to-knowledge.sh's schema tokens (hunt-fitness/success_rate/
#      --replace), zone-mapper.ag's query_knowledge/recommend("hunt-fitness")/apply_fitness_reorder, map-zones.sh's
#      knowledge.enabled + knowledge-import step, and the reorder-harness's matching query_knowledge call.
#   2) FUNCTIONAL (live only when agentis is on PATH; --backend mock throughout): (a) run bench-to-knowledge.sh
#      over fixtures/hunt-fitness/ and assert the emitted JSON carries per-class success_rate + NORMALIZED class
#      ids (no `class=`) with C6 precision > C3; (b) import into a scratch mock store and assert `knowledge list`
#      shows the entries; (c) run the reorder-harness on a fixed CSV and assert the order tracks the fitness AND
#      FLIPS when the fitness flips. [SKIP] on runners without agentis, exactly like demo-map-zones.sh.
#
# Usage:  dark-factory/demo-hunt-fitness.sh
# Requires: python3 (the floor); agentis for the functional part. Exit: 0 = all held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# #2119: wide flat-cyborg PTY by default for every flat-cyborg config emission (see the helper header).
# shellcheck source=lib/flat-cyborg-env.sh
# shellcheck disable=SC1091
. "$HERE/lib/flat-cyborg-env.sh"
CB="$HERE/bench/corpus-bench"
SCOREMATCH="$CB/score-match.py"
FEEDER="$CB/bench-to-knowledge.sh"
MAPPER="$HERE/auditor/agents/zone-mapper.ag"
MAPZONES="$HERE/map-zones.sh"
FX="$CB/fixtures/hunt-fitness"
HARNESS="$FX/reorder-harness.ag"

FAILS=0
note() { echo "demo-hunt-fitness.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
for f in "$SCOREMATCH" "$FEEDER" "$MAPPER" "$MAPZONES" "$FX/truth.tsv" "$FX/verified_findings.json" "$HARNESS"; do
  [ -f "$f" ] || { note "required file missing: $f" >&2; exit 3; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-hunt-fitness.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# PART 1 — SOURCE-GUARDS (always run; keep the wiring points from silently regressing)
# ----------------------------------------------------------------------------------------------------------
note "1) source-guarding the five wiring points ..."

if grep -q -- '--per-lead' "$SCOREMATCH"; then
  ok "score-match.py handles the additive --per-lead flag"
else
  bad "score-match.py missing the --per-lead flag"
fi

if grep -q 'hunt-fitness' "$FEEDER" && grep -q 'success_rate' "$FEEDER" && grep -q -- '--replace' "$FEEDER"; then
  ok "bench-to-knowledge.sh emits the hunt-fitness schema (action/success_rate) and imports with --replace"
else
  bad "bench-to-knowledge.sh missing hunt-fitness / success_rate / --replace"
fi

if grep -q 'query_knowledge("hunt-fitness"' "$MAPPER" \
   && grep -q 'recommend("hunt-fitness"' "$MAPPER" \
   && grep -q 'apply_fitness_reorder' "$MAPPER"; then
  ok "zone-mapper.ag consumes the fitness (query_knowledge + recommend(\"hunt-fitness\") + apply_fitness_reorder)"
else
  bad "zone-mapper.ag missing the fitness-consumption wiring"
fi

if grep -q 'knowledge.enabled = true' "$MAPZONES" && grep -q 'knowledge import' "$MAPZONES"; then
  ok "map-zones.sh enables the knowledge store and imports HUNT_FITNESS_JSON before the zone loop"
else
  bad "map-zones.sh missing knowledge.enabled / the knowledge-import step"
fi

# The harness must call the SAME imported-knowledge channel as the real agent (keeps the per-agent copy in sync).
if grep -q 'query_knowledge("hunt-fitness"' "$HARNESS" && grep -q 'apply_fitness_reorder' "$HARNESS"; then
  ok "reorder-harness.ag mirrors zone-mapper.ag's query_knowledge(\"hunt-fitness\") + apply_fitness_reorder"
else
  bad "reorder-harness.ag diverged from zone-mapper.ag's fitness channel"
fi

# ----------------------------------------------------------------------------------------------------------
# PART 2 — FUNCTIONAL (agentis-gated; --backend mock only, zero LLM contention with the live bench)
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  note "2) functional loop:"
  skip "agentis not on PATH — install the runtime to run the live feeder + import + reorder checks"
  if [ "$FAILS" -eq 0 ]; then note "PASS (source-guards only; agentis absent)"; exit 0; fi
  note "FAIL — $FAILS assertion(s) regressed" >&2; exit 1
fi

# (a) feeder: fixtures/hunt-fitness -> hunt-fitness.json with per-class precision + normalized class ids.
note "2a) bench-to-knowledge.sh over fixtures/hunt-fitness/ (per-class precision + class normalization) ..."
BWORK="$WORK/bench-work"
mkdir -p "$BWORK/demo/zone-hunt-out/verify"
cp "$FX/truth.tsv" "$BWORK/demo/truth.tsv"
cp "$FX/verified_findings.json" "$BWORK/demo/zone-hunt-out/verify/verified_findings.json"
HF_JSON="$WORK/hunt-fitness.json"
if bash "$FEEDER" --work "$BWORK" --out "$HF_JSON" >"$WORK/feeder.log" 2>&1; then
  ok "bench-to-knowledge.sh ran over the fixture (exit 0)"
else
  bad "bench-to-knowledge.sh failed:"; sed 's/^/      /' "$WORK/feeder.log" >&2
fi
if python3 - "$HF_JSON" <<'PY'
import sys, json
entries = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(entries, list) and entries, "hunt-fitness.json is not a non-empty array"
by = {}
for e in entries:
    assert e["action"] == "hunt-fitness", "entry action is not hunt-fitness"
    assert "success_rate" in e and isinstance(e["success_rate"], (int, float)), "missing/invalid success_rate"
    cond = e["condition"]
    assert cond.startswith("class "), "condition not 'class <CLS>': %r" % cond
    cls = cond[len("class "):]
    assert "class=" not in cls and "=" not in cls, "class id not normalized (still has 'class='): %r" % cls
    assert e["id"] == "hunt-fitness-%s" % cls, "id %r != hunt-fitness-%s" % (e["id"], cls)
    by[cls] = e["success_rate"]
assert "C6" in by and "C3" in by, "expected C6 and C3 entries, got %r" % sorted(by)
assert by["C6"] > by["C3"], "C6 precision %r is not > C3 precision %r" % (by["C6"], by["C3"])
PY
then ok "emitted JSON has per-class success_rate + normalized class ids (no 'class='), C6 precision > C3"
else bad "feeder output assertion failed (precision / normalization)"
fi

# Scratch mock store used by (b) and (c).
STORE="$WORK/store"
mkdir -p "$STORE"
( cd "$STORE" && agentis init >/dev/null 2>&1 ) || true
{
  echo "llm.backend = mock"
  echo "learning.enabled = true"
  echo "experience.enabled = true"
  echo "knowledge.enabled = true"
} > "$STORE/.agentis/config"

# (b) import into the mock store -> knowledge list shows the entries.
note "2b) agentis knowledge import into a scratch mock store -> knowledge list shows the entries ..."
if ( cd "$STORE" && agentis knowledge import "$HF_JSON" --replace ) >"$WORK/import.log" 2>&1; then
  ok "agentis knowledge import --replace succeeded"
else
  bad "agentis knowledge import failed:"; sed 's/^/      /' "$WORK/import.log" >&2
fi
LIST="$( cd "$STORE" && agentis knowledge list 2>/dev/null )"
if printf '%s\n' "$LIST" | grep -q 'action=hunt-fitness'; then
  ok "knowledge list shows the imported hunt-fitness entries"
else
  bad "knowledge list does not show hunt-fitness entries"; printf '%s\n' "$LIST" | sed 's/^/      /' >&2
fi

# (c) reorder-harness on a fixed CSV: order tracks the fitness, and FLIPS when the fitness flips.
note "2c) reorder-harness.ag: class order reflects the fed fitness AND changes when the fitness changes ..."
cp "$HARNESS" "$STORE/reorder-harness.ag"
# --grant-pii to satisfy the dark-factory #1690 lint convention; the harness reads only imported knowledge
# (no target source, no exec sh), so it is a harmless no-op permission grant under --backend mock.
reorder_result() { ( cd "$STORE" && agentis go reorder-harness.ag --enable-exec --grant-pii 2>/dev/null ) | grep '^REORDER|' | tail -1; }
first_class() { printf '%s\n' "$1" | sed 's/^REORDER|[^|]*|//' | cut -d, -f1; }

R1="$(reorder_result)"
F1="$(first_class "$R1")"
if [ "$F1" = "C6" ]; then
  ok "with C6 > C3 fitness, the reorder puts C6 first ($R1)"
else
  bad "expected C6 first with C6>C3 fitness, got first=$F1 ($R1)"
fi

# Flip the fitness (C3 now the high-precision class) and re-import with --replace.
cat > "$WORK/flip.json" <<FLIP
[
 {"action":"hunt-fitness","author":"corpus-bench","category":"heuristic","condition":"class C6","confidence":0.1,"created_ms":1,"id":"hunt-fitness-C6","recommendation":"C6 low","samples":10,"success_rate":0.1,"tags":["C6","real-bug"]},
 {"action":"hunt-fitness","author":"corpus-bench","category":"heuristic","condition":"class C3","confidence":0.95,"created_ms":1,"id":"hunt-fitness-C3","recommendation":"C3 high","samples":10,"success_rate":0.95,"tags":["C3","real-bug"]}
]
FLIP
( cd "$STORE" && agentis knowledge import "$WORK/flip.json" --replace ) >/dev/null 2>&1
R2="$(reorder_result)"
F2="$(first_class "$R2")"
if [ "$F2" = "C3" ]; then
  ok "after flipping the fitness (C3 > C6), the reorder puts C3 first ($R2) — ordering tracks fitness"
else
  bad "expected C3 first after the flip, got first=$F2 ($R2)"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the corpus-bench -> hunter fitness feedback loop holds (learn + recommend)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
