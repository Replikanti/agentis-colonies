#!/usr/bin/env bash
# fetch-depmap-nampt.sh — bulk, mechanical data transform ONLY.
#
# Streams the DepMap 24Q4 CRISPR gene-effect matrix (429 MB, ~1200 x ~18000)
# and emits one narrow TSV: ModelID, the model's Oncotree label, NAMPT, RPL5.
#
# Nothing here decides anything. In particular this script does NOT decide which
# lines are rhabdomyosarcoma — it passes the Oncotree label through verbatim
# (lowercased, which is normalization, not judgement) and tools/analyze-nampt.ag
# owns the classification rule, the group split, the threshold and the verdict.
# An earlier revision matched "rhabdomyosarcoma" here, which put the decision
# that determines the whole result in a shell script, against the federation's
# .ag-first contract.
# The matrix must be narrowed out here because no bulk record stream may enter
# .ag (the same boundary the Track 1 pipeline draws around bcftools).
#
# Files are the public figshare mirrors of DepMap 24Q4 — open, no registration.
# Later releases (25Q2+) are Cloudflare-gated with no stable public URL, which
# is why this pins 24Q4.
#
# Usage: tools/fetch-depmap-nampt.sh [outfile]     (default: doc/depmap-nampt.tsv)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GR="$(dirname "$HERE")"
OUT="${1:-$GR/doc/depmap-nampt.tsv}"
# Written via .part + mv: a killed stream must not leave a short but well-formed
# table behind, because that analyses cleanly and gives a wrong answer.
OUT_PART="$OUT.part"
CACHE="${DEPMAP_CACHE:-${TMPDIR:-/tmp}/depmap-24q4}"

MODEL_URL="https://ndownloader.figshare.com/files/51065297"   # Model.csv, ~646 KB
EFFECT_URL="https://ndownloader.figshare.com/files/51064667"  # CRISPRGeneEffect.csv, ~429 MB

mkdir -p "$CACHE"

if [ ! -s "$CACHE/Model.csv" ]; then
    echo "fetch-depmap-nampt: downloading Model.csv" >&2
    curl -fsSL "$MODEL_URL" -o "$CACHE/Model.csv.part"
    mv "$CACHE/Model.csv.part" "$CACHE/Model.csv"
fi

echo "fetch-depmap-nampt: streaming the gene-effect matrix (429 MB, no local copy kept)" >&2
curl -fsSL "$EFFECT_URL" | python3 -c '
import sys, csv, re
# Column extraction only: find the two gene columns by header name, stream rows.
model_path, out_path = sys.argv[1], sys.argv[2]
labels = {}
for r in csv.DictReader(open(model_path)):
    # Passed through verbatim; no classification happens here.
    # Collapse ALL whitespace: CSV fields may contain embedded newlines, and a
    # split row would silently shift every tab-delimited field the agent reads.
    labels[r["ModelID"]] = re.sub(r"\s+", " ",
                                  (r.get("OncotreePrimaryDisease", "") + " " +
                                   r.get("OncotreeSubtype", "")).lower()).strip()
reader = csv.reader(sys.stdin)
hdr = next(reader)
idx = {}
for name in ("NAMPT", "RPL5"):
    for i, c in enumerate(hdr):
        if c.split(" (")[0] == name:
            idx[name] = i
            break
missing = [n for n in ("NAMPT", "RPL5") if n not in idx]
if missing:
    sys.exit("fetch-depmap-nampt: gene column(s) not found in matrix: %s" % ", ".join(missing))
n = 0
with open(out_path, "w") as fh:
    fh.write("ModelID\toncotree_label\tNAMPT\tRPL5\n")
    for row in reader:
        fh.write("%s\t%s\t%s\t%s\n" % (row[0], labels.get(row[0], ""),
                                       row[idx["NAMPT"]], row[idx["RPL5"]]))
        n += 1
sys.stderr.write("fetch-depmap-nampt: wrote %d model rows\n" % n)
' "$CACHE/Model.csv" "$OUT_PART"

rows="$(( $(wc -l < "$OUT_PART") - 1 ))"
if [ "$rows" -lt 1000 ]; then
    rm -f "$OUT_PART"
    echo "fetch-depmap-nampt: only $rows model rows — truncated download, refusing to install" >&2
    exit 3
fi
mv "$OUT_PART" "$OUT"
echo "fetch-depmap-nampt: $OUT ($rows model rows)" >&2
