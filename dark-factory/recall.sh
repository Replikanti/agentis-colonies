#!/usr/bin/env bash
# #861 M3 — held-out recall harness for the DAG bug-pattern matcher.
#
# Measures the matcher's RECALL on a held-out set (does a seeded pattern catch a fork/variant it did
# NOT see seeded?) and its PRECISION (does it wrongly fire on a structurally-different negative?). It
# seeds with the REAL seed-patterns.ag (zero seed-side drift) and matches with recall-match.ag, which
# mirrors reconn's match functions exactly — so the number reflects production.
#
# Manifests are pipe-delimited; `#` lines and blank lines are ignored.
#   --seed-manifest  lines: `Class|abs-src-path|func-marker`            (patterns to seed; from harvest-sherlock.js)
#   --test-manifest  lines: `Class|abs-src-path|id|transform|expect`    (held-out targets; expect = match|miss; from make-variants.js)
#
# Usage:
#   recall.sh --seed-manifest <m> --test-manifest <m> --evm-harness <dir> [--agentis <bin>] [--out <dir>]
# Emits a markdown recall/precision table to stdout and to <out>/recall-report.md.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"; SEED_MANIFEST=""; TEST_MANIFEST=""; EVM_HARNESS=""; OUT="$PWD/recall-out"; FUZZY_THRESHOLD="0.35"
need() { [ "$1" -ge 2 ] || { echo "recall.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --seed-manifest) need "$#"; SEED_MANIFEST="$2"; shift 2 ;;
    --test-manifest) need "$#"; TEST_MANIFEST="$2"; shift 2 ;;
    --evm-harness) need "$#"; EVM_HARNESS="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --threshold) need "$#"; FUZZY_THRESHOLD="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "recall.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done
[ -f "$SEED_MANIFEST" ] || { echo "recall.sh: --seed-manifest not found: $SEED_MANIFEST" >&2; exit 2; }
[ -f "$TEST_MANIFEST" ] || { echo "recall.sh: --test-manifest not found: $TEST_MANIFEST" >&2; exit 2; }
[ -n "$EVM_HARNESS" ] || { echo "recall.sh: --evm-harness <dir> required" >&2; exit 2; }
EVM_HARNESS="$(cd "$EVM_HARNESS" && pwd)"

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"; rm -rf "$RUN"; mkdir -p "$RUN"
cp "$HERE/auditor/agents/seed-patterns.ag" "$RUN/seed-patterns.ag"
cp "$HERE/auditor/agents/recall-match.ag" "$RUN/recall-match.ag"

# init the store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "trace.level = normal"
  echo "exec.env_passthrough = EVM_HARNESS_DIR,SEED_SRC,SEED_CLASS,SEED_FUNC,TEST_SRC,TEST_CLASS,TEST_ID,TEST_TRANSFORM,FUZZY_SEEDS,FUZZY_THRESHOLD"
  echo "exec.default_timeout_ms = 180000"
} > "$RUN/.agentis/config"

# ---- seed (real seed-patterns.ag, exact + structural) -------------------------------------------
echo "recall: seeding from $(basename "$SEED_MANIFEST") ..." >&2
nseed=0
while IFS='|' read -r C S M || [ -n "$C" ]; do
  case "$C" in ''|\#*) continue ;; esac
  # --grant-pii: SEED_SRC contract source can embed addresses/identifiers that trip the PII
  # heuristic; input is benign public contract text (#1690).
  ( cd "$RUN" && env SEED_CLASS="$C" SEED_SRC="$S" SEED_FUNC="$M" EVM_HARNESS_DIR="$EVM_HARNESS" \
      "$AGENTIS" go seed-patterns.ag --enable-exec --grant-pii ) >/dev/null 2>&1 || true
  nseed=$((nseed + 1))
done < "$SEED_MANIFEST"
echo "recall: seeded $nseed pattern(s)" >&2

# build the fuzzy-match seed corpus: one `Class:::<normalized-sig>` per seed (its marker function),
# consumed by fuzzy-match.js for shingle-Jaccard similarity matching.
FUZZY_SEEDS="$OUT/fuzzy-seeds.tsv"; : > "$FUZZY_SEEDS"
while IFS='|' read -r C S M || [ -n "$C" ]; do
  case "$C" in ''|\#*) continue ;; esac
  sig=$(node "$EVM_HARNESS/struct-sig.js" "$S" 2>/dev/null | grep "^${M}:::" | head -1 | sed 's/^[^:]*::://')
  [ -n "$sig" ] && printf '%s:::%s\n' "$C" "$sig" >> "$FUZZY_SEEDS"
done < "$SEED_MANIFEST"

# ---- match each held-out target (exact + structural + fuzzy) -------------------------------------
RAW="$OUT/recall-raw.txt"; : > "$RAW"
ntest=0
while IFS='|' read -r C S ID TR EXPECT || [ -n "$C" ]; do
  case "$C" in ''|\#*) continue ;; esac
  # --grant-pii: TEST_SRC contract source can embed addresses/identifiers that trip the PII
  # heuristic; input is benign public contract text (#1690).
  line=$( cd "$RUN" && env TEST_SRC="$S" TEST_CLASS="$C" TEST_ID="$ID" TEST_TRANSFORM="$TR" EVM_HARNESS_DIR="$EVM_HARNESS" \
      FUZZY_SEEDS="$FUZZY_SEEDS" FUZZY_THRESHOLD="$FUZZY_THRESHOLD" \
      "$AGENTIS" go recall-match.ag --enable-exec --grant-pii 2>/dev/null | grep '^RECALL|' || true )
  [ -n "$line" ] && echo "${line}|expect=${EXPECT}" >> "$RAW"
  ntest=$((ntest + 1))
done < "$TEST_MANIFEST"
echo "recall: matched $ntest held-out target(s) (fuzzy threshold $FUZZY_THRESHOLD)" >&2

# ---- tally -> markdown --------------------------------------------------------------------------
REPORT="$OUT/recall-report.md"
awk -F'|' '
function pct(n, d) { return d == 0 ? "n/a" : sprintf("%.0f%% (%d/%d)", 100*n/d, n, d); }
{
  split($5, a, "="); ex = a[2];
  split($6, b, "="); st = b[2];
  split($7, c, "="); fz = c[2];
  split($8, d, "="); expect = d[2];
  cls = $2;
  if (expect == "match") {
    mt[cls]++; MT++;
    if (ex == cls) { me[cls]++; ME++; }
    if (st == cls) { ms[cls]++; MS++; }
    if (fz == cls) { mf[cls]++; MF++; }
  } else {
    NT++;
    if (ex != "MISS") NE++;
    if (st != "MISS") NS++;
    if (fz != "MISS") NFZ++;
  }
  seen[cls] = 1;
}
END {
  print "## M3 — held-out recall (DAG bug-pattern matcher)";
  print "";
  print "Recall = a seeded pattern catching a held-out target it did not see seeded.";
  print "exact = byte-identical sub-graph; structural = exact normalized signature; fuzzy =";
  print "shingle-Jaccard similarity (the lift for REAL forks where the function is restructured).";
  print "";
  print "| Class | held-out | exact | structural | **fuzzy** |";
  print "|-------|----------|-------|------------|-----------|";
  for (k in seen) if (mt[k] > 0)
    printf("| %s | %d | %s | %s | **%s** |\n", k, mt[k], pct(me[k], mt[k]), pct(ms[k], mt[k]), pct(mf[k], mt[k]));
  printf("| **ALL** | %d | %s | %s | **%s** |\n", MT, pct(ME, MT), pct(MS, MT), pct(MF, MT));
  print "";
  print "### Precision (negatives / unrelated — MUST NOT match; false-match rate)";
  print "";
  printf("| targets | exact | structural | fuzzy |\n");
  printf("|---------|-------|------------|-------|\n");
  printf("| %d | %s | %s | %s |\n", NT, pct(NE, NT), pct(NS, NT), pct(NFZ, NT));
}
' "$RAW" | tee "$REPORT"

echo "" >&2
echo "recall: report -> $REPORT (raw -> $RAW)" >&2
