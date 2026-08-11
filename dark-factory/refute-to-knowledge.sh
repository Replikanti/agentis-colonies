#!/usr/bin/env bash
# refute-to-knowledge.sh — the LEARN half of the refuter -> hunter CONSTRAINT feedback loop (issue #1887).
# Reads the `<class>\t<file:fn>\t<constraint>` rows run-refute.sh / verify-findings.sh harvest from REFUTED
# verdicts and emits agentis `KnowledgeEntry` rows under action `refute-constraint`, which hunter.ag then
# consumes via query_knowledge() to PRE-EMPT the objection that killed the previous target's claims.
#
# It is the exact shape of the shipped #1711 hunt-fitness channel (bench-to-knowledge.sh -> `agentis
# knowledge import --replace` -> zone-mapper.ag), deliberately: a proven, lint-covered feeder pattern beats a
# new one. What TRAVELS is only the GENERALISABLE sentence, keyed by bug CLASS — never a target's own nouns.
#
# The corpus is FROZEN and READ-ONLY by design (#1866): a static file, imported ONCE into a run store before
# the cell loop, identical in every cell's copy, and never written by an agent. That is what keeps a hunt
# order-independent (`--jobs N == serial`) while still letting one target's refutations teach the next one.
# No `distill()` anywhere: it hard-requires >= 3 successful same-action experience records, each refute gate
# is a single-shot run against a freshly wiped store, and ANY runtime error makes agentis discard the cell's
# whole stdout — the #1877/#1878 false zero.
#
# NOT an `.ag` agent (a plain operator feeder), so #1587 substrate-purity does not apply; python3 is used only
# for the JSON emit, exactly like the sibling bench feeder.
#
# Usage: refute-to-knowledge.sh [--in <tsv>]... [--from-verify <dir>]... [--out <file>]
#                               [--import <store-dir>] [--store <file>] [--agentis <bin>] [-h]
#   --in <tsv>          A refute-constraints.tsv (repeatable). Rows: <class>\t<file:fn>\t<constraint>.
#   --from-verify <dir> A verify-findings.sh output dir; reads <dir>/refute-constraints.tsv (repeatable).
#   --out <file>        Where to write the KnowledgeEntry JSON array. Default ./refute-constraints.json.
#   --import <dir>      After writing, run `( cd <dir> && agentis knowledge import <out> --replace )`. The
#                       `--replace` is MANDATORY and always used: a re-import WITHOUT it ACCUMULATES samples.
#                       The full JSON is regenerated from all selected inputs each run, so it is idempotent.
#   --store <file>      OPT-IN persistent per-colony merge (default OFF): merge this run's entries INTO an
#                       accumulating JSON at <file> (same (class, constraint) key, samples summed) and write
#                       it back. The bench path never uses it — a frozen checked-in corpus is what keeps a
#                       measurement re-derivable; production hunts are where an accumulating corpus belongs.
#   --agentis <bin>     agentis binary for --import (default: `agentis` on PATH).
#   -h                  Help.
# Exit: 0 = JSON written (empty-but-valid `[]` when no input carried a constraint — that is DATA, not an
#       error); 2 = bad args; 3 = missing prerequisite (python3, or --import store/agentis).
set -u

OUT="$PWD/refute-constraints.json"
IMPORT_DIR=""
STORE=""
AGENTIS="agentis"
INPUTS=""

die() { echo "refute-to-knowledge.sh: $*" >&2; exit 2; }
say() { echo "refute-to-knowledge.sh: $*" >&2; }
nv()  { [ "$1" -ge 2 ] || die "$2 requires a value"; }

while [ $# -gt 0 ]; do case "$1" in
  --in)          nv "$#" "$1"; INPUTS="$INPUTS
$2"; shift 2;;
  --from-verify) nv "$#" "$1"; INPUTS="$INPUTS
$2/refute-constraints.tsv"; shift 2;;
  --out)         nv "$#" "$1"; OUT="$2"; shift 2;;
  --import)      nv "$#" "$1"; IMPORT_DIR="$2"; shift 2;;
  --store)       nv "$#" "$1"; STORE="$2"; shift 2;;
  --agentis)     nv "$#" "$1"; AGENTIS="$2"; shift 2;;
  -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0;;
  *) die "unknown arg: $1";;
esac; done

command -v python3 >/dev/null 2>&1 || { echo "refute-to-knowledge.sh: python3 not installed" >&2; exit 3; }

# Collect every readable input into ONE row file. A named-but-missing input is a logged skip, not a failure:
# a gate run that refuted nothing legitimately leaves no file, and the honest answer to that is an empty
# corpus. Newline-delimited accumulation (never word-splitting) so a path with spaces survives.
ROWS_TMP="$(mktemp "${TMPDIR:-/tmp}/r2k-rows.XXXXXX")"
LIST_TMP="$(mktemp "${TMPDIR:-/tmp}/r2k-list.XXXXXX")"
trap 'rm -f "$ROWS_TMP" "$LIST_TMP"' EXIT
printf '%s\n' "$INPUTS" > "$LIST_TMP"
FILES=0
while IFS= read -r src; do
  [ -n "$src" ] || continue
  if [ ! -f "$src" ]; then
    say "skipping (not found): $src"
    continue
  fi
  cat "$src" >> "$ROWS_TMP"
  FILES=$((FILES + 1))
done < "$LIST_TMP"
say "$FILES input file(s), $(wc -l < "$ROWS_TMP" | tr -d ' ') raw constraint row(s)"

# Aggregate identical (class, constraint) pairs and emit the KnowledgeEntry JSON array. python3 at the JSON
# boundary only (the emit + the sha256 id), never for logic that belongs in the shell.
NOW_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
python3 - "$ROWS_TMP" "$OUT" "$NOW_MS" <<'PY'
import sys, json, hashlib

rows_path, out_path, now_ms = sys.argv[1], sys.argv[2], int(sys.argv[3])

# (class, constraint) -> samples. Identical sentences from different candidates are ONE entry with a higher
# sample count: the hunter reads a standard, not a per-candidate log, and repetition is the only evidence of
# how load-bearing a standard is.
agg = {}
with open(rows_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        cls = parts[0].strip() or "unknown"
        constraint = parts[2].strip()
        if not constraint:
            continue
        key = (cls, constraint)
        agg[key] = agg.get(key, 0) + 1

entries = []
for (cls, constraint), samples in agg.items():
    digest = hashlib.sha256(("%s|%s" % (cls, constraint)).encode("utf-8")).hexdigest()[:12]
    entries.append({
        "action": "refute-constraint",
        "author": "refuter",
        "category": "constraint",
        "condition": "class %s" % cls,
        "confidence": 1.0,
        "created_ms": now_ms,
        "id": "refute-constraint-%s-%s" % (cls, digest),
        "recommendation": constraint,
        "samples": samples,
        "success_rate": 1.0,
        "tags": [cls, "refute-constraint"],
    })
# Sorted by (class, id): a deterministic, diffable corpus whose byte content does not depend on input order.
entries.sort(key=lambda e: (e["condition"], e["id"]))

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(entries, fh, indent=2)
    fh.write("\n")
print("refute-to-knowledge.sh: wrote %d refute-constraint entries to %s" % (len(entries), out_path), file=sys.stderr)
PY

# Optional PERSISTENT merge (default OFF). Merges this run's entries into an accumulating corpus keyed the
# same way, summing samples; created on first use. Only the merged file is touched — --out stays this run's.
if [ -n "$STORE" ]; then
  python3 - "$OUT" "$STORE" <<'PY'
import sys, json, os

run_path, store_path = sys.argv[1], sys.argv[2]
run = json.load(open(run_path, encoding="utf-8"))
prev = []
if os.path.exists(store_path):
    try:
        prev = json.load(open(store_path, encoding="utf-8"))
    except ValueError:
        print("refute-to-knowledge.sh: --store file is not valid JSON; starting a fresh corpus", file=sys.stderr)
        prev = []

merged = {}
for e in list(prev) + list(run):
    key = e.get("id")
    if key in merged:
        merged[key]["samples"] = merged[key].get("samples", 0) + e.get("samples", 0)
    else:
        merged[key] = dict(e)
out = sorted(merged.values(), key=lambda e: (e.get("condition", ""), e.get("id", "")))
with open(store_path, "w", encoding="utf-8") as fh:
    json.dump(out, fh, indent=2)
    fh.write("\n")
print("refute-to-knowledge.sh: merged %d entries into %s (%d total)" % (len(run), store_path, len(out)), file=sys.stderr)
PY
fi

# Optional import into an agentis store (idempotent via mandatory --replace).
if [ -n "$IMPORT_DIR" ]; then
  [ -d "$IMPORT_DIR" ] || { echo "refute-to-knowledge.sh: --import store dir not found: $IMPORT_DIR" >&2; exit 3; }
  command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] \
    || { echo "refute-to-knowledge.sh: agentis not found (needed for --import): $AGENTIS" >&2; exit 3; }
  ( cd "$IMPORT_DIR" && "$AGENTIS" knowledge import "$OUT" --replace ) \
    || { say "knowledge import into $IMPORT_DIR failed"; exit 3; }
  say "imported refute-constraint entries into $IMPORT_DIR (--replace)"
fi

exit 0
