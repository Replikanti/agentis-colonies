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
# LOCATION ANCHORS (issue #2215). The `signature` is title + a TRUNCATED body, and the scorer's frozen #1697
# rule can only credit a lead when the row's signature prose happens to name BOTH the `.sol` basename and the
# function. On real reports that is often impossible: the location a watson links lives past the truncation,
# or is only ever expressed as a GitHub `#L<n>` link or a `Contract:LINE` backtick ref — neither of which
# carries a function NAME a substring matcher can see. `notional` H-9 is the canonical case: both A/B arms
# GENERATED the bug at `CurveConvex2Token.sol:_exitPool`, yet the row's prose names only the Curve-side
# symbols, so the lead was credited to the row's consensus twin and the rare row scored MISS.
# Column 6 fixes that GT-side: `<Basename.sol>:<function>` pairs resolved from the FULL issue block by three
# mechanisms — a `File:` marker followed by code, a GitHub blob link with `#L<n>[-L<m>]`, and a
# `Contract:LINE` / `Contract.sol#LNN` backtick ref. The last two need the audited source (`--code`) to turn a
# LINE into a function NAME; without it they simply resolve to nothing. Columns 1-5 are untouched (the
# truncation rule is deliberately NOT changed), so a 5-column consumer keeps reading the same bytes.
#
# Usage: extract-gt.sh <judging-readme.md> <out-truth.tsv> [--code <project-root>]
#   --code <dir>  the cloned, audited project root (`<work>/<id>/code/<project_subdir>`). Used ONLY to resolve
#                 a `#L<n>` / `Contract:LINE` reference to the function declared at (or enclosing) that line.
#                 Omitted -> those two mechanisms yield nothing and column 6 carries only `File:`-block pairs.
#   truth.tsv columns (TAB-separated): sev_id  severity  rarity  title  signature  locations
#     sev_id     e.g. H-1, M-3 (as printed by the judging repo).
#     severity   High | Medium.
#     rarity     watson-handle count on the finding's "## Found by" line.
#     title      the finding's one-line title.
#     signature  title + a truncated body snippet (Root Cause/Summary prose, minus the Found-by list and
#                Source link) — free text fed to novelty-gate.sh's overlap oracle for scoring, same idiom as
#                bench/fixtures/*/truth.tsv.
#     locations  #2215 — space-separated, sorted, deduped `<Basename.sol>:<function>` pairs resolved from the
#                FULL issue block (see above). ALWAYS present, EMPTY when nothing resolves. A basename with no
#                function is never emitted: score-match.py credits a lead only on a PAIR, so a half-anchor
#                would be an unanchored file match, which is exactly what #1697 refused to do.
# Exit: 0 on success (possibly 0 rows if the README has no accepted H/M issues) ; 2 bad args ; 3 unreadable input.
set -u

README=""; OUT=""; CODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --code)
      [ $# -ge 2 ] || { echo "extract-gt.sh: --code requires a value" >&2; exit 2; }
      CODE="$2"; shift 2 ;;
    -h|--help)
      awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    -*)
      echo "extract-gt.sh: unknown arg: $1" >&2; exit 2 ;;
    *)
      if   [ -z "$README" ]; then README="$1"
      elif [ -z "$OUT" ];    then OUT="$1"
      else echo "extract-gt.sh: unexpected extra arg: $1" >&2; exit 2
      fi
      shift ;;
  esac
done
[ -n "$README" ] && [ -n "$OUT" ] || { echo "extract-gt.sh: usage: extract-gt.sh <judging-readme.md> <out-truth.tsv> [--code <project-root>]" >&2; exit 2; }
[ -r "$README" ] || { echo "extract-gt.sh: not readable: $README" >&2; exit 3; }
[ -z "$CODE" ] || [ -d "$CODE" ] || { echo "extract-gt.sh: --code dir not found: $CODE" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "extract-gt.sh: python3 not installed" >&2; exit 3; }

python3 - "$README" "$OUT" "$CODE" <<'PY'
import sys, re, os

readme_path, out_path, code_root = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(readme_path, encoding="utf-8", errors="ignore").read()
lines = text.split("\n")

HEADER_RE = re.compile(r'^#\s+Issue\s+([HM])-(\d+):\s*(.+?)\s*$')
SEV_NAME = {"H": "High", "M": "Medium"}

# ---- #2215 location anchors -------------------------------------------------------------------------------
# A Solidity function DECLARATION at the start of a line. Deliberately narrow: a call site (`foo(` mid-line)
# is not a declaration, and crediting one would re-import the name-coincidence failure mode #1697 exists for.
FUNC_RE = re.compile(r'^\s*function\s+([A-Za-z_]\w*)\s*\(')
# `File: Foo.sol` marker that a judging report puts above a pasted snippet.
FILE_MARKER_RE = re.compile(r'^\s*File:\s*([A-Za-z0-9_]+\.sol)\s*$')
# GitHub blob permalink with a line anchor, optionally a RANGE (`#L60-L66`).
BLOB_RE = re.compile(
    r'https://github\.com/[^/\s]+/[^/\s]+/blob/[^/\s]+/(\S+?/)?([A-Za-z0-9_]+\.sol)#L(\d+)(?:-L(\d+))?')
# Backtick refs: `Strategy:207`, `Strategy.sol:207`, `Strategy.sol#L207`.
REF_RE = re.compile(r'`([A-Z][A-Za-z0-9_]*)(?:\.sol)?[:#]L?(\d+)`')

# basename -> [paths]; built once. Empty without --code, which makes the two line-number mechanisms inert.
source_index = {}
if code_root:
    for root, _dirs, files in os.walk(code_root):
        for f in files:
            if f.endswith(".sol"):
                source_index.setdefault(f, []).append(os.path.join(root, f))
_source_cache = {}


def source_lines(path):
    if path not in _source_cache:
        try:
            _source_cache[path] = open(path, encoding="utf-8", errors="ignore").read().split("\n")
        except OSError:
            _source_cache[path] = []
    return _source_cache[path]


def resolve_path(basename, hint):
    """The single source file this reference names, or None. AMBIGUITY IS A SKIP, never a guess: a basename
    present at two paths (a copy, an interface, a mock) would otherwise anchor the row on the wrong file."""
    paths = source_index.get(basename, [])
    if hint:
        narrowed = [p for p in paths if p.replace(os.sep, "/").endswith(hint)]
        if narrowed:
            paths = narrowed
    return paths[0] if len(paths) == 1 else None


def functions_at(basename, start, end, hint=""):
    """Function names a `#L<start>[-L<end>]` reference points at:
      * the ENCLOSING function of `start` (the last declaration at or before it), and
      * every function DECLARED INSIDE [start, end] — a range routinely starts on the doc comment above the
        function it is quoting (notional M-12's `#L60-L66` opens on a comment; `_getPTRate` is at L61), so
        the enclosing rule alone would credit the PREVIOUS function and nothing else.
    Returns a (possibly empty) set."""
    path = resolve_path(basename, hint)
    if not path:
        return set()
    src = source_lines(path)
    found = set()
    enclosing = None
    for i, line in enumerate(src, 1):
        m = FUNC_RE.match(line)
        if not m:
            continue
        if i <= start:
            enclosing = m.group(1)
        if end is not None and start <= i <= end:
            found.add(m.group(1))
    if enclosing:
        found.add(enclosing)
    return found


def block_locations(block):
    """`Basename.sol:function` pairs for one issue block, from the three mechanisms documented at the top."""
    pairs = set()
    # (1) `File: X.sol` marker -> every function DECLARED below it, until the next `File:` marker. Needs no
    #     --code: the report pasted the code itself.
    current = None
    for line in block:
        m = FILE_MARKER_RE.match(line)
        if m:
            current = m.group(1)
            continue
        if current:
            fm = FUNC_RE.match(line)
            if fm:
                pairs.add((current, fm.group(1)))
    # (2)+(3) line-number references, resolved against --code.
    for line in block:
        for m in BLOB_RE.finditer(line):
            subdir, basename, start, end = m.group(1), m.group(2), int(m.group(3)), m.group(4)
            hint = (subdir or "") + basename
            for fn in functions_at(basename, start, int(end) if end else None, hint):
                pairs.add((basename, fn))
        for m in REF_RE.finditer(line):
            basename = m.group(1) + ".sol"
            for fn in functions_at(basename, int(m.group(2)), None):
                pairs.add((basename, fn))
    return " ".join(sorted(b + ":" + f for b, f in pairs))


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

    # #2215: resolved over the FULL block, NOT the truncated signature — the location is usually what the
    # truncation cut off.
    locations = block_locations(block)

    rows.append((f"{sev}-{num}", SEV_NAME.get(sev, sev), rarity, title.replace("\t", " "), signature, locations))

with open(out_path, "w", encoding="utf-8") as fh:
    for sev_id, sev_name, rarity, title, signature, locations in rows:
        fh.write(f"{sev_id}\t{sev_name}\t{rarity}\t{title}\t{signature}\t{locations}\n")

anchored = sum(1 for r in rows if r[5])
sys.stderr.write(f"extract-gt.sh: {len(rows)} accepted H/M finding(s) -> {out_path} "
                 f"({anchored} with a resolved location anchor"
                 f"{'' if code_root else '; --code not given, only File: blocks resolve'})\n")
PY
