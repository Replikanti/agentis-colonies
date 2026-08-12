#!/usr/bin/env bash
# bounty-payability-gate.sh — per-severity PAYABILITY filter (#1897, epic #1894 M1). A queue -> queue GATE that
# drops rows whose Medium/High reward is a CONFIRMED $0, so a program that pays $1M Critical but nothing at
# Medium/High never reaches a hunt (Critical-only findings are rare; Medium/High is where most real hunts land).
# It never re-derives severity from the 5-col TSV itself (col 5's scope_hint carries no reward numbers) —
# instead it correlates each row's `immunefi:<id>` key against a raw-bounties-array reward source (the same
# --bounties/--live shape run-immunefi-intake.sh already consumes) and reads Medium/High USD figures off it.
#
# Usage: bounty-payability-gate.sh --queue <file> [--bounties <file> | --live] [--url <endpoint>]
#                                  [--page <key>=<file>]... [--table <file>] [--pay-floor <usd>] [--out <file>] [-h]
#   --queue      : the 5-col TSV to gate (default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/immunefi.queue, the
#                  same default run-immunefi-intake.sh writes, so the two chain with zero extra flags).
#   --bounties   : offline raw bounties.json array (same file shape run-immunefi-intake.sh --bounties reads) —
#                  reward-source tier 1.
#   --live       : fetch --url and use it as tier 1 instead of --bounties. Fetch failure/empty body -> [SKIP].
#   --url        : the bounties endpoint --live fetches (default https://immunefi.com/public-api/bounties.json).
#   --page       : repeatable <key>=<file>, an offline per-program __NEXT_DATA__ HTML fixture — reward-source
#                  tier 2 for a row whose tier-1 match is missing or whose rewardsBody yields no severity hits.
#                  <key> is the FULL `immunefi:<id>` TSV key, not the bare id.
#   --table      : operator manual-paste hatch — TSV `key<TAB>medium_usd<TAB>high_usd`, `#`-prefixed and blank
#                  lines ignored — reward-source tier 3.
#   --pay-floor  : USD floor a row must clear at Medium OR High to survive (default 1000).
#   --out        : output path (default = the --queue path itself, i.e. gates in place).
#   -h/--help    : print this header.
#
# REWARD-SOURCE RESOLUTION, in order, per queue row (pid = the key with the `immunefi:` prefix stripped,
# case-insensitive match against --bounties/--live entries' slug/id):
#   1. rewardsBody text on the matching raw-bounties-array entry.
#   2. If no match / the matched entry's rewardsBody yields no severity hits: the --page <key>=<file> fixture
#      for that key, if supplied. The <script id="__NEXT_DATA__" type="application/json"> body is extracted,
#      json.loads'd, then every dict/list node is walked recursively collecting (severity, amount) pairs
#      wherever a dict has one key matching /severity|level/i with a value in {critical,high,medium,low}
#      (case-insensitive) and a sibling key matching /amount|usd|payout|reward/i.
#   3. If still unresolved: the --table <file> row for that key.
#   4. UNRESOLVED (no match in any tier) -> the row is KEPT UNCHANGED (fail-open — matches the codebase-wide
#      "missing/garbled field contributes 0 / never crashes / never false-drops" convention, e.g.
#      run-immunefi-intake.sh's delta_of()/score_of()). Only a CONFIRMED reward source (tier 1-3 matched, even
#      if it lists no Medium/High at all) can drop a row.
#
# USD PARSING mirrors run-immunefi-intake.sh's usd() verbatim: `^\s*\$?([0-9]*\.?[0-9]+)\s*([kmb]?)` with
# {"":1,"k":1e3,"m":1e6,"b":1e9} — so "$5k"/"5000"/"$5,000" all parse identically to the sibling script.
#
# DROP RULE: a row with a RESOLVED source is kept iff medium_usd >= pay_floor OR high_usd >= pay_floor; dropped
# otherwise. Row order / all 5 columns are emitted byte-identical for every kept row — the gate only removes
# lines, never rewrites scope_hint or re-sorts.
#
# SKIP contract: --queue missing/empty -> [SKIP], exit 0, --out unwritten. --queue non-empty but none of
# --bounties/--live/--page/--table given, OR --live fetch fails/returns empty -> [SKIP] to stderr, exit 0,
# --out UNWRITTEN (queue untouched). python3 missing -> [SKIP], exit 0.
# Bad args: unknown flag / a missing value / an explicitly-given --bounties/--page/--table file that is
# unreadable -> exit 2.
#
# Requires: python3; curl only on the --live path (read-only public GET). Emits the SAME 5-col TSV
# run-immunefi-intake.sh / run-batch.sh already speak: score<TAB>immunefi:<id><TAB>url<TAB>name<TAB>scope_hint.
set -u

DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "bounty-payability-gate.sh: $2 requires a value" >&2; exit 2; }; }

QUEUE="$DIR/immunefi.queue"
BOUNTIES="" ; LIVE="" ; URL="https://immunefi.com/public-api/bounties.json"
TABLE="" ; PAY_FLOOR="1000" ; OUT="" ; MAX_TIME="30"
PAGES=""   # newline-separated "key=file" pairs, accumulated verbatim (each may itself be repeated).

while [ $# -gt 0 ]; do case "$1" in
  --queue)      nv "$#" "$1"; QUEUE="$2"; shift 2;;
  --bounties)   nv "$#" "$1"; BOUNTIES="$2"; shift 2;;
  --live)       LIVE="1"; shift;;
  --url)        nv "$#" "$1"; URL="$2"; shift 2;;
  --page)       nv "$#" "$1"; PAGES="$PAGES
$2"; shift 2;;
  --table)      nv "$#" "$1"; TABLE="$2"; shift 2;;
  --pay-floor)  nv "$#" "$1"; PAY_FLOOR="$2"; shift 2;;
  --out)        nv "$#" "$1"; OUT="$2"; shift 2;;
  -h|--help)    sed -n '2,50p' "$0"; exit 0;;
  *) echo "bounty-payability-gate.sh: unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$OUT" ] || OUT="$QUEUE"

# Empty / missing queue -> nothing to gate (mirrors run-batch.sh's SKIP contract).
if [ ! -s "$QUEUE" ]; then
  echo "[SKIP] no queue at $QUEUE — nothing to gate" >&2
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

# Explicitly-given tier-1/2/3 files must be readable; a bad flag is a usage error (exit 2), not a SKIP.
if [ -n "$BOUNTIES" ] && [ ! -r "$BOUNTIES" ]; then
  echo "bounty-payability-gate.sh: --bounties <file> not readable: $BOUNTIES" >&2; exit 2
fi
if [ -n "$TABLE" ] && [ ! -r "$TABLE" ]; then
  echo "bounty-payability-gate.sh: --table <file> not readable: $TABLE" >&2; exit 2
fi
OLD_IFS="$IFS"
IFS='
'
for pair in $PAGES; do
  [ -n "$pair" ] || continue
  pfile="${pair#*=}"
  [ -r "$pfile" ] || { IFS="$OLD_IFS"; echo "bounty-payability-gate.sh: --page file not readable: $pfile" >&2; exit 2; }
done
IFS="$OLD_IFS"

# tier-1 raw bounties array: --live fetches it, --bounties reads it offline. Neither given -> RAW stays empty
# (tier-1 simply resolves nothing; tier-2/3 may still resolve rows). --live fetch failure/empty body -> [SKIP]
# ONLY when it is the sole reward source requested (matches run-immunefi-intake.sh's own --live SKIP dance).
RAW=""
if [ -n "$LIVE" ]; then
  RAW="$(mktemp "${TMPDIR:-/tmp}/bounty-gate-raw.XXXXXX")"
  trap 'rm -f "$RAW"' EXIT
  curl -sS --max-time "$MAX_TIME" "$URL" -o "$RAW" 2>/dev/null || :
  if [ ! -s "$RAW" ]; then
    rm -f "$RAW"
    if [ -z "$TABLE" ] && [ -z "$PAGES" ]; then
      echo "[SKIP] --live: no network / empty response from $URL — nothing to gate against" >&2
      exit 0
    fi
    RAW=""
  fi
elif [ -n "$BOUNTIES" ]; then
  RAW="$BOUNTIES"
fi

# No reward source at all -> nothing can be resolved, the gate would be a total no-op. [SKIP] rather than a
# silent pass-through, so the operator notices a missing flag instead of a queue that is quietly never gated.
if [ -z "$RAW" ] && [ -z "$TABLE" ] && [ -z "$PAGES" ]; then
  echo "[SKIP] no reward source (--bounties / --live / --page / --table) — nothing to gate against" >&2
  exit 0
fi

# PAGES: pass the raw "key=file" pairs to python via a temp file (one per line) — avoids arg-count limits and
# keeps the shell side free of embedded-python string building.
PAGES_FILE="$(mktemp "${TMPDIR:-/tmp}/bounty-gate-pages.XXXXXX")"
trap 'rm -f "$PAGES_FILE" "$RAW"' EXIT
printf '%s\n' "$PAGES" | grep -v '^$' > "$PAGES_FILE" || :

QUEUE="$QUEUE" RAW="$RAW" TABLE="$TABLE" PAGES_FILE="$PAGES_FILE" PAY_FLOOR="$PAY_FLOOR" OUT_DISPLAY="$OUT" python3 - > "$OUT.tmp.$$" <<'PY'
import sys, os, re, json

queue_path = os.environ["QUEUE"]
raw_path = os.environ.get("RAW", "")
table_path = os.environ.get("TABLE", "")
pages_file = os.environ.get("PAGES_FILE", "")

try:
    pay_floor = float(os.environ.get("PAY_FLOOR", "1000") or 0)
except ValueError:
    pay_floor = 1000.0


def usd(v):
    """USD figure -> float; mirrors run-immunefi-intake.sh's usd() verbatim. 0.0 when unusable."""
    if isinstance(v, (int, float)):
        return float(v)
    if not v:
        return 0.0
    m = re.match(r"^\s*\$?([0-9]*\.?[0-9]+)\s*([kmb]?)", str(v).strip().lower().replace(",", ""))
    if not m:
        return 0.0
    return float(m.group(1)) * {"": 1, "k": 1e3, "m": 1e6, "b": 1e9}[m.group(2)]


SEV_KEY = re.compile(r"severity|level", re.I)
AMT_KEY = re.compile(r"amount|usd|payout|reward", re.I)
SEV_VALUES = {"critical", "high", "medium", "low"}


def rewards_from_body(text):
    """Scan free-text rewardsBody for `<Severity>: ... $<amount>` mentions. Returns {severity: usd} for
    whichever severities are found (never invents an entry for a severity that is not mentioned)."""
    out = {}
    if not text:
        return out
    for sev in ("critical", "high", "medium", "low"):
        for m in re.finditer(sev, text, re.I):
            tail = text[m.end():m.end() + 80]
            am = re.search(r"\$?\s*([0-9][0-9,]*\.?[0-9]*)\s*([kmb]?)\b", tail, re.I)
            if am:
                val = usd(am.group(1) + am.group(2))
                if val > out.get(sev, 0.0):
                    out[sev] = val
    return out


def walk_next_data(node, found):
    """Recursively walk a __NEXT_DATA__ JSON tree collecting (severity, amount) pairs wherever a dict carries
    one key matching severity|level (value in {critical,high,medium,low}) and a sibling key matching
    amount|usd|payout|reward. Survives cosmetic JSON-shape drift better than a fixed key path."""
    if isinstance(node, dict):
        sev_val = None
        amt_val = None
        for k, v in node.items():
            if SEV_KEY.search(k) and isinstance(v, str) and v.strip().lower() in SEV_VALUES:
                sev_val = v.strip().lower()
            if AMT_KEY.search(k) and isinstance(v, (int, float, str)):
                cand = usd(v)
                if cand > 0:
                    amt_val = cand
        if sev_val is not None and amt_val is not None:
            if amt_val > found.get(sev_val, 0.0):
                found[sev_val] = amt_val
        for v in node.values():
            walk_next_data(v, found)
    elif isinstance(node, list):
        for v in node:
            walk_next_data(v, found)


def rewards_from_page(path):
    try:
        html = open(path, encoding="utf-8", errors="ignore").read()
    except Exception:
        return {}
    m = re.search(
        r'<script[^>]*id=["\']__NEXT_DATA__["\'][^>]*>(.*?)</script>', html, re.S | re.I)
    if not m:
        return {}
    try:
        data = json.loads(m.group(1))
    except Exception:
        return {}
    found = {}
    walk_next_data(data, found)
    return found


def load_raw_index(path):
    """slug/id (lowercased) -> rewardsBody text, from a raw bounties.json array (or {bounties|data|programs|
    results: [...]} wrapper). Missing/unreadable/unparseable -> empty index (tier-1 resolves nothing)."""
    idx = {}
    if not path:
        return idx
    try:
        raw = json.load(open(path, encoding="utf-8", errors="ignore"))
    except Exception:
        return idx
    if isinstance(raw, dict):
        for k in ("bounties", "data", "programs", "results"):
            if isinstance(raw.get(k), list):
                raw = raw[k]
                break
    if not isinstance(raw, list):
        return idx
    for b in raw:
        if not isinstance(b, dict):
            continue
        pid = str(b.get("slug") or b.get("id") or "").strip().lower()
        if not pid:
            continue
        idx[pid] = str(b.get("rewardsBody") or "")
    return idx


def load_page_index(pages_file):
    """`immunefi:<id>` key (lowercased) -> --page fixture file path."""
    idx = {}
    if not pages_file or not os.path.exists(pages_file):
        return idx
    try:
        with open(pages_file, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line or "=" not in line:
                    continue
                key, path = line.split("=", 1)
                idx[key.strip().lower()] = path.strip()
    except Exception:
        return {}
    return idx


def load_table_index(table_path):
    """`immunefi:<id>` key (lowercased) -> (medium_usd, high_usd) from an operator --table TSV. Blank lines
    and `#`-prefixed lines are ignored; a malformed row is skipped (never crashes)."""
    idx = {}
    if not table_path:
        return idx
    try:
        with open(table_path, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) < 3:
                    continue
                key = parts[0].strip().lower()
                idx[key] = (usd(parts[1]), usd(parts[2]))
    except Exception:
        return {}
    return idx


raw_index = load_raw_index(raw_path)
page_index = load_page_index(pages_file)
table_index = load_table_index(table_path)

kept = 0
dropped = 0
try:
    with open(queue_path, encoding="utf-8", errors="ignore") as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
except Exception:
    lines = []

for line in lines:
    cols = line.split("\t")
    if len(cols) != 5:
        # Malformed row: never crash, never silently drop — pass through unchanged (fail-open).
        print(line)
        kept += 1
        continue
    score, key, url, name, scope = cols
    pid = key[len("immunefi:"):] if key.lower().startswith("immunefi:") else key
    pid = pid.strip().lower()
    keylc = key.strip().lower()

    resolved = False
    medium_usd = 0.0
    high_usd = 0.0

    # Tier 1: rewardsBody on the matching raw-bounties-array entry.
    body = raw_index.get(pid)
    if body is not None:
        sevs = rewards_from_body(body)
        if sevs:
            resolved = True
            medium_usd = sevs.get("medium", 0.0)
            high_usd = sevs.get("high", 0.0)
        else:
            # A matched entry with an empty/no-hit rewardsBody is still a CONFIRMED tier-1 match (Medium/High
            # resolve to $0) UNLESS a richer tier (--page) is available for this key — fall through to tier 2
            # below without setting resolved yet, so a --page fixture can still win.
            pass

    # Tier 2: --page <key>=<file> __NEXT_DATA__ fixture, when tier 1 didn't resolve.
    if not resolved:
        pf = page_index.get(keylc)
        if pf:
            sevs = rewards_from_page(pf)
            if sevs:
                resolved = True
                medium_usd = sevs.get("medium", 0.0)
                high_usd = sevs.get("high", 0.0)

    # Tier 1 fallback: a matched-but-hitless rewardsBody resolves to a confirmed $0 (only if tier 2 didn't
    # already resolve above).
    if not resolved and body is not None:
        resolved = True
        medium_usd = 0.0
        high_usd = 0.0

    # Tier 3: operator --table paste hatch.
    if not resolved:
        row = table_index.get(keylc)
        if row is not None:
            resolved = True
            medium_usd, high_usd = row

    if not resolved:
        # Fail-open: no source matched at all -> keep the row unchanged.
        print(line)
        kept += 1
        continue

    if medium_usd >= pay_floor or high_usd >= pay_floor:
        print(line)
        kept += 1
    else:
        dropped += 1

sys.stderr.write("bounty-payability-gate: kept %d, dropped %d (floor=$%s) -> %s\n" % (
    kept, dropped, ("%g" % pay_floor), os.environ.get("OUT_DISPLAY", "") or queue_path))
PY
rc=$?
if [ "$rc" -ne 0 ]; then
  rm -f "$OUT.tmp.$$"
  exit "$rc"
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
mv "$OUT.tmp.$$" "$OUT"
cat "$OUT"
