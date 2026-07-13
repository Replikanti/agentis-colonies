#!/usr/bin/env bash
# extract-gt.sh — parse a concluded Sherlock judging-repo README.md (the compiled report) into a ground-truth
# truth.tsv for the corpus-bench. The README compiles every ACCEPTED High/Medium finding as:
#   # Issue H-1: <title>
#   Source: <link>
#   ## Found by
#   <comma-separated watson handles>
#   ### Summary / Root Cause / ... (free-form body)
# The watson-handle count on "## Found by" is the RARITY signal (1-2 = rare, 3-8 = mid, 9+ = consensus) used
# to stratify recall — a bench that only reports flat recall hides that consensus bugs are easy and rare bugs
# are what actually separates an elite hunter from the crowd (see dark-factory hunt-bench calibration).
#
# Usage: extract-gt.sh <judging-readme.md> <out-truth.tsv>
#   truth.tsv columns (TAB-separated): sev_id  severity  rarity  title  signature
#     sev_id     e.g. H-1, M-3 (as printed by the judging repo).
#     severity   High | Medium.
#     rarity     watson-handle count on the finding's "## Found by" line.
#     title      the finding's one-line title.
#     signature  title + a truncated body snippet (Root Cause/Summary prose, minus the Found-by list and
#                Source link) — free text fed to novelty-gate.sh's overlap oracle for scoring, same idiom as
#                bench/fixtures/*/truth.tsv.
# Exit: 0 on success (possibly 0 rows if the README has no accepted H/M issues) ; 2 bad args ; 3 unreadable input.
set -u

README="${1:-}"; OUT="${2:-}"
[ -n "$README" ] && [ -n "$OUT" ] || { echo "extract-gt.sh: usage: extract-gt.sh <judging-readme.md> <out-truth.tsv>" >&2; exit 2; }
[ -r "$README" ] || { echo "extract-gt.sh: not readable: $README" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "extract-gt.sh: python3 not installed" >&2; exit 3; }

python3 - "$README" "$OUT" <<'PY'
import sys, re

readme_path, out_path = sys.argv[1], sys.argv[2]
text = open(readme_path, encoding="utf-8", errors="ignore").read()
lines = text.split("\n")

HEADER_RE = re.compile(r'^#\s+Issue\s+([HM])-(\d+):\s*(.+?)\s*$')
SEV_NAME = {"H": "High", "M": "Medium"}

# Find every "# Issue H-N: title" header line -> (line_index, sev_letter, num, title).
headers = []
for i, line in enumerate(lines):
    m = HEADER_RE.match(line)
    if m:
        headers.append((i, m.group(1), m.group(2), m.group(3).strip()))

rows = []
for idx, (start, sev, num, title) in enumerate(headers):
    end = headers[idx + 1][0] if idx + 1 < len(headers) else len(lines)
    block = lines[start:end]

    # rarity: the non-empty line right after "## Found by" is a comma-separated watson list.
    rarity = 0
    for j, bl in enumerate(block):
        if bl.strip().startswith("## Found by"):
            for k in range(j + 1, len(block)):
                cand = block[k].strip()
                if cand:
                    rarity = len([w for w in cand.split(",") if w.strip()])
                    break
            break

    # signature body: everything after the title, EXCLUDING the "Source:" link line and the "## Found by" +
    # watson-list lines (they're metadata, not vuln-descriptive prose) — truncated so the oracle sees the
    # highest-signal prose (Summary/Root Cause) without an unbounded PoC/code dump.
    body_lines = []
    skip_next_nonblank = False
    for bl in block[1:]:
        stripped = bl.strip()
        if stripped.startswith("Source:"):
            continue
        if stripped.startswith("## Found by"):
            skip_next_nonblank = True
            continue
        if skip_next_nonblank:
            if stripped:
                skip_next_nonblank = False
            continue
        body_lines.append(bl)
    body = "\n".join(body_lines).strip()
    body = re.sub(r'\s+', ' ', body)[:1500]
    signature = (title + " -- " + body).strip()
    signature = signature.replace("\t", " ")

    rows.append((f"{sev}-{num}", SEV_NAME.get(sev, sev), rarity, title.replace("\t", " "), signature))

with open(out_path, "w", encoding="utf-8") as fh:
    for sev_id, sev_name, rarity, title, signature in rows:
        fh.write(f"{sev_id}\t{sev_name}\t{rarity}\t{title}\t{signature}\n")

sys.stderr.write(f"extract-gt.sh: {len(rows)} accepted H/M finding(s) -> {out_path}\n")
PY
