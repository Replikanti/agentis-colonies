#!/usr/bin/env bash
# fetch-depmap-nampt.sh — bulk, mechanical data transform ONLY.
#
# Streams the DepMap 24Q4 CRISPR gene-effect matrix (429 MB, ~1200 x ~18000)
# and emits one narrow TSV: ModelID, NAMPT, RPL5, plus an is_rms flag derived
# from Model.csv. Nothing here decides anything — the group comparison and the
# verdict live in tools/analyze-nampt.ag, per this federation's .ag-first rule.
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
import sys, csv
# Column extraction only: find the two gene columns by header name, stream rows.
model_path, out_path = sys.argv[1], sys.argv[2]
rms = set()
for r in csv.DictReader(open(model_path)):
    label = (r.get("OncotreePrimaryDisease", "") + r.get("OncotreeSubtype", "")).lower()
    if "rhabdomyosarcoma" in label:
        rms.add(r["ModelID"])
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
    fh.write("ModelID\tis_rms\tNAMPT\tRPL5\n")
    for row in reader:
        fh.write("%s\t%s\t%s\t%s\n" % (row[0], "1" if row[0] in rms else "0",
                                       row[idx["NAMPT"]], row[idx["RPL5"]]))
        n += 1
sys.stderr.write("fetch-depmap-nampt: wrote %d model rows\n" % n)
' "$CACHE/Model.csv" "$OUT"

echo "fetch-depmap-nampt: $OUT" >&2
