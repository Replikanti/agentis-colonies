#!/usr/bin/env bash
# bench-to-knowledge.sh — the LEARN half of the corpus-bench -> hunter fitness feedback loop (issue #1711).
# Reads already-scored corpus-bench contests, derives per-bug-class REAL-BUG PRECISION from score-match.py's
# HIT/MISS matching (reusing the ONE source of truth for "what counts as a real-bug hit", never re-implementing
# it), and emits agentis KnowledgeEntry rows under action `hunt-fitness` — the fitness zone-mapper.ag then
# consumes via recommend()/query_knowledge() to hunt historically-real-bug classes first. This REPLACES the
# weak "surfaced-a-candidate = success" signal (fitness-driver.ag's SYNTHETIC-yield experience channel) with a
# ground-truth-anchored one, kept in the SEPARATE, inspectable (`agentis knowledge list`) knowledge store.
#
# Per class it aggregates GLOBALLY across the selected contests:
#   hits    = that class's leads that matched a real Sherlock GT row (score-match.py --per-lead `LEAD ... HIT`)
#   misses  = that class's unmatched leads (noise)                    (`LEAD ... MISS`)
#   precision = hits / (hits + misses)   -> the entry's confidence AND success_rate
# The class field is normalized inside score-match.py (`class=C3` and `C3` collapse to `C3`; empty -> `unknown`).
#
# NOT an `.ag` agent (a plain operator feeder), so #1587 substrate-purity does not apply; python3 is used only
# for the JSON emit + integer/precision arithmetic, exactly like the sibling bench scripts.
#
# Usage: bench-to-knowledge.sh [--work <dir>] [--id <id>]... [--out <file>] [--import <store-dir>] [-h]
#   --work <dir>      Dir of already-scored contests (each <dir>/<id>/truth.tsv +
#                     <dir>/<id>/zone-hunt-out/verify/verified_findings.json). Default ./corpus-bench-work.
#   --id <id>         Restrict to one contest sub-dir (repeatable). Default: every sub-dir that has both files.
#   --out <file>      Where to write the KnowledgeEntry JSON array. Default ./hunt-fitness.json.
#   --import <dir>    After writing, run `( cd <dir> && agentis knowledge import <out> --replace )`. The
#                     `--replace` is MANDATORY and always used: re-import WITHOUT it ACCUMULATES samples. The
#                     full JSON is regenerated from all selected contests each run, so --replace is idempotent.
#   -h                Help.
# Exit: 0 = JSON written (empty-but-valid `[]` when no contest had scorable leads — that is DATA, not an error);
#       2 = bad args; 3 = missing prerequisite (python3, score-match.py, or --import store/agentis).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCOREMATCH="$HERE/score-match.py"

WORK="$PWD/corpus-bench-work"
OUT="$PWD/hunt-fitness.json"
IMPORT_DIR=""
AGENTIS="agentis"
IDS=""

die() { echo "bench-to-knowledge.sh: $*" >&2; exit 2; }
say() { echo "bench-to-knowledge.sh: $*" >&2; }
nv()  { [ "$1" -ge 2 ] || die "$2 requires a value"; }

while [ $# -gt 0 ]; do case "$1" in
  --work)    nv "$#" "$1"; WORK="$2"; shift 2;;
  --id)      nv "$#" "$1"; IDS="$IDS $2"; shift 2;;
  --out)     nv "$#" "$1"; OUT="$2"; shift 2;;
  --import)  nv "$#" "$1"; IMPORT_DIR="$2"; shift 2;;
  --agentis) nv "$#" "$1"; AGENTIS="$2"; shift 2;;
  -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0;;
  *) die "unknown arg: $1";;
esac; done

command -v python3 >/dev/null 2>&1 || { echo "bench-to-knowledge.sh: python3 not installed" >&2; exit 3; }
[ -f "$SCOREMATCH" ] || { echo "bench-to-knowledge.sh: score-match.py not found at $SCOREMATCH" >&2; exit 3; }
[ -d "$WORK" ] || die "work dir not found: $WORK"

# Discover contest ids: explicit --id list, else every immediate sub-dir of $WORK.
CANDIDATES=""
if [ -n "$IDS" ]; then
  CANDIDATES="$IDS"
else
  for d in "$WORK"/*/; do
    [ -d "$d" ] || continue
    CANDIDATES="$CANDIDATES $(basename "$d")"
  done
fi

# Accumulate every scored lead across the selected contests as `<class>\t<HIT|MISS>` lines, and count the
# contests that actually contributed data (for the recommendation string's "across N contests").
LEADS_TMP="$(mktemp "${TMPDIR:-/tmp}/b2k-leads.XXXXXX")"
trap 'rm -f "$LEADS_TMP"' EXIT
CONTESTS=0
for id in $CANDIDATES; do
  [ -n "$id" ] || continue
  truth="$WORK/$id/truth.tsv"
  verified="$WORK/$id/zone-hunt-out/verify/verified_findings.json"
  if [ ! -f "$truth" ] || [ ! -f "$verified" ]; then
    say "[$id] skipping (missing truth.tsv or verified_findings.json)"
    continue
  fi
  SCORE_OUT="$(python3 "$SCOREMATCH" "$truth" "$verified" --per-lead)" \
    || { say "[$id] score-match.py failed; skipping"; continue; }
  # Keep only the per-lead lines (drop the per-row HIT/MISS + LEADS trailer): `LEAD\t<class>\t<HIT|MISS>`.
  n_before="$(wc -l < "$LEADS_TMP")"
  printf '%s\n' "$SCORE_OUT" | while IFS="$(printf '\t')" read -r tag cls verdict; do
    [ "$tag" = "LEAD" ] || continue
    printf '%s\t%s\n' "$cls" "$verdict"
  done >> "$LEADS_TMP"
  n_after="$(wc -l < "$LEADS_TMP")"
  if [ "$n_after" -gt "$n_before" ]; then
    CONTESTS=$((CONTESTS + 1))
    say "[$id] $((n_after - n_before)) verified leads scored"
  else
    say "[$id] no verified leads to score"
  fi
done

# Aggregate per class -> precision and emit the KnowledgeEntry JSON array. python3 for the JSON + arithmetic
# (the JSON emit boundary, not agent logic). now_ms is the entry created_ms.
NOW_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
python3 - "$LEADS_TMP" "$OUT" "$CONTESTS" "$NOW_MS" <<'PY'
import sys, json

leads_path, out_path, contests, now_ms = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
hits, misses = {}, {}
with open(leads_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        cls, verdict = parts[0], parts[1]
        if verdict == "HIT":
            hits[cls] = hits.get(cls, 0) + 1
        elif verdict == "MISS":
            misses[cls] = misses.get(cls, 0) + 1

entries = []
for cls in sorted(set(hits) | set(misses)):
    h = hits.get(cls, 0)
    m = misses.get(cls, 0)
    samples = h + m
    precision = h / samples if samples else 0.0
    hit_word = "hit" if h == 1 else "hits"
    entries.append({
        "action": "hunt-fitness",
        "author": "corpus-bench",
        "category": "heuristic",
        "condition": "class %s" % cls,
        "confidence": precision,
        "created_ms": now_ms,
        "id": "hunt-fitness-%s" % cls,
        "recommendation": "%s: %d real-bug %s / %d noise across %d contests (precision %s)"
                          % (cls, h, hit_word, m, contests, ("%.4f" % precision)),
        "samples": samples,
        "success_rate": precision,
        "tags": [cls, "real-bug"],
    })

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(entries, fh, indent=2)
    fh.write("\n")
print("bench-to-knowledge.sh: wrote %d hunt-fitness entries to %s" % (len(entries), out_path), file=sys.stderr)
PY

# Optional import into an agentis store (idempotent via mandatory --replace).
if [ -n "$IMPORT_DIR" ]; then
  [ -d "$IMPORT_DIR" ] || { echo "bench-to-knowledge.sh: --import store dir not found: $IMPORT_DIR" >&2; exit 3; }
  command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] \
    || { echo "bench-to-knowledge.sh: agentis not found (needed for --import): $AGENTIS" >&2; exit 3; }
  ( cd "$IMPORT_DIR" && "$AGENTIS" knowledge import "$OUT" --replace ) \
    || { say "knowledge import into $IMPORT_DIR failed"; exit 3; }
  say "imported hunt-fitness into $IMPORT_DIR (--replace)"
fi

exit 0
