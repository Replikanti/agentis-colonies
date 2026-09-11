#!/usr/bin/env bash
# list-codehawks-concluded.sh — discovery half of the CodeHawks corpus GT source (#2189; unblocks #2172).
# Lists CONCLUDED, keyless-findings CodeHawks contests eligible to become held-out corpus rows. It mirrors the
# keyless SvelteKit `data-sveltekit-fetched ...competitions.getCompetitions...` embed parse that
# ../../watch-competitions.sh already uses for LIVE-contest discovery, but with the OPPOSITE phase filter:
# instead of "submissions open", it keeps contests that have FINALISED with PUBLIC findings and ended strictly
# after a model-knowledge-cutoff bar, so the resulting targets are genuinely unseen by the hunter model (no
# contamination). It NEVER touches watch-competitions.sh's live-window filter or its ledger — the embed-parse
# block is duplicated here so this script's failure modes stay isolated from the freshness watcher's.
#
# The competition `id` this emits chains directly into extract-gt-codehawks.sh (the findings tRPC keys on it).
#
# Usage: list-codehawks-concluded.sh --cutoff-date <YYYY-MM-DD> [--codehawks-from <html>]
#                                    [--codehawks-url <url>] [--max-time <s>] [--out <file>]
#        list-codehawks-concluded.sh --self-test
#        list-codehawks-concluded.sh -h | --help
#
#   --cutoff-date <YYYY-MM-DD>  REQUIRED, no default. A contest is kept only if its `endDate` is STRICTLY AFTER
#                               this date. There is deliberately no default: a missing flag is an error, never
#                               a silent date, so a caller can never accidentally admit a pre-cutoff (possibly
#                               model-seen) target into the held-out corpus. RECOMMENDED VALUE: 2026-02-01 — the
#                               first day of the month strictly after the hunter model's Jan-2026 knowledge
#                               cutoff (a conservative one-month margin: a contest that ENDED after this date
#                               published its findings after the cutoff, so the model could not have trained on
#                               them). Raise it as the model's cutoff advances; never lower it below the cutoff.
#   --codehawks-from <html>     Offline hatch: read a saved CodeHawks `/contests` page HTML instead of the
#                               network (the ONLY mode colony-lint/CI ever invoke — see --self-test). No curl.
#   --codehawks-url <url>       Live contests page (default https://codehawks.cyfrin.io/contests). Used ONLY
#                               when --codehawks-from is absent; a plain keyless GET, opt-in by omission.
#   --max-time <s>              curl --max-time on the live path (default 30).
#   --out <file>                Write the TSV here instead of stdout.
#   --self-test                 CI-safe fixture suite (no network); byte-exact vs fixtures/codehawks/expected-*.
#
# Output TSV (TAB-separated), sorted by endDate ascending:
#   id  urlSlug  name  githubUrl  endDate
# Filter kept: finalised == true AND inviteOnly == false AND privateSubmissionsToggle == false
#   AND endDate parseable AND endDate > --cutoff-date.
# The `privateSubmissionsToggle == true` contests (their findings tRPC returns empty arrays) are dropped here as
# a clean, machine-detectable case — not an error. Parse is fail-closed: any embed/JSON drift yields zero rows,
# never a crash (mirrors watch-competitions.sh's try/except-wrapped CodeHawks block).
# Exit: 0 success (possibly 0 rows) ; 2 bad args ; 3 no python3 / unreadable --codehawks-from.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CUTOFF=""
CODEHAWKS_FROM=""
CODEHAWKS_URL="https://codehawks.cyfrin.io/contests"
MAX_TIME=30
OUT=""
SELFTEST=0

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }

nv() { [ "$1" -ge 2 ] || { echo "list-codehawks-concluded.sh: $2 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --cutoff-date)   nv "$#" "$1"; CUTOFF="$2"; shift 2;;
    --codehawks-from) nv "$#" "$1"; CODEHAWKS_FROM="$2"; shift 2;;
    --codehawks-url) nv "$#" "$1"; CODEHAWKS_URL="$2"; shift 2;;
    --max-time)      nv "$#" "$1"; MAX_TIME="$2"; shift 2;;
    --out)           nv "$#" "$1"; OUT="$2"; shift 2;;
    --self-test)     SELFTEST=1; shift;;
    -h|--help)       usage; exit 0;;
    *) echo "list-codehawks-concluded.sh: unknown arg: $1" >&2; exit 2;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "list-codehawks-concluded.sh: python3 not installed" >&2; exit 3; }

# --- self-test: drive the fixture HTML through the SAME offline path (--codehawks-from, no network), assert
# byte-exact against the expected TSV. This is the ONLY mode colony-lint/CI invoke.
if [ "$SELFTEST" -eq 1 ]; then
  FX="$SELF_DIR/fixtures/codehawks"
  got="$(bash "$0" --cutoff-date 2026-02-01 --codehawks-from "$FX/contests-sample.html" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "list-codehawks-concluded.sh: --self-test FAIL (discovery parse exited $rc)" >&2; exit 1
  fi
  exp="$(cat "$FX/expected-concluded.tsv")"
  if [ "$got" = "$exp" ]; then
    echo "list-codehawks-concluded.sh: --self-test PASS (finalised+public+post-cutoff filter, byte-exact)"
    exit 0
  fi
  echo "list-codehawks-concluded.sh: --self-test FAIL (discovery TSV drifted from expected-concluded.tsv)" >&2
  diff <(printf '%s\n' "$exp") <(printf '%s\n' "$got") >&2 || true
  exit 1
fi

[ -n "$CUTOFF" ] || { echo "list-codehawks-concluded.sh: --cutoff-date <YYYY-MM-DD> is REQUIRED (no default; a missing cutoff would risk admitting model-seen targets). See -h; recommended 2026-02-01." >&2; exit 2; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
HTML_FILE=""
if [ -n "$CODEHAWKS_FROM" ]; then
  [ -r "$CODEHAWKS_FROM" ] || { echo "list-codehawks-concluded.sh: --codehawks-from not readable: $CODEHAWKS_FROM" >&2; exit 3; }
  HTML_FILE="$CODEHAWKS_FROM"
else
  command -v curl >/dev/null 2>&1 || { echo "list-codehawks-concluded.sh: curl not installed and no --codehawks-from given" >&2; exit 3; }
  HTML_FILE="$TMPD/contests.html"
  curl -sS -A "Mozilla/5.0" --max-time "$MAX_TIME" "$CODEHAWKS_URL" -o "$HTML_FILE" 2>/dev/null || :
  [ -s "$HTML_FILE" ] || { echo "list-codehawks-concluded.sh: empty response from $CODEHAWKS_URL" >&2; exit 0; }
fi

OUT_TMP="$TMPD/out.tsv"
CODEHAWKS_HTML="$HTML_FILE" CUTOFF_DATE="$CUTOFF" python3 - "$OUT_TMP" <<'PY'
import os, sys, re, json, datetime

html_path = os.environ["CODEHAWKS_HTML"]
cutoff_s = os.environ["CUTOFF_DATE"]
out_path = sys.argv[1]

try:
    cutoff = datetime.date.fromisoformat(cutoff_s[:10])
except Exception:
    sys.stderr.write("list-codehawks-concluded.sh: bad --cutoff-date (want YYYY-MM-DD): %r\n" % cutoff_s)
    sys.exit(2)

def parse_date(v):
    if v in (None, ""):
        return None
    s = str(v).strip()
    if re.match(r"^[0-9]+$", s):
        try:
            ts = float(s)
            if ts > 1e11:
                ts /= 1000.0
            return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).date()
        except Exception:
            return None
    try:
        return datetime.date.fromisoformat(s[:10])
    except Exception:
        return None

rows = []
try:
    with open(html_path, encoding="utf-8", errors="ignore") as fh:
        html = fh.read()
    m = re.search(
        r'data-sveltekit-fetched[^>]*data-url="[^"]*competitions\.getCompetitions[^"]*"[^>]*>(.*?)</script>',
        html, re.S)
    if m:
        outer = json.loads(m.group(1).strip())
        body = json.loads(outer["body"]) if isinstance(outer, dict) else None
        contests = []
        for elem in (body if isinstance(body, list) else []):
            if isinstance(elem, dict):
                data = elem.get("result", {}).get("data") if isinstance(elem.get("result"), dict) else None
                if isinstance(data, list):
                    contests.extend(data)
        for it in contests:
            if not isinstance(it, dict):
                continue
            slug = str(it.get("urlSlug") or "").strip()
            cid = str(it.get("id") or "").strip()
            if not slug or not cid:
                continue
            if not bool(it.get("finalised")):
                continue
            if bool(it.get("inviteOnly")):
                continue
            if bool(it.get("privateSubmissionsToggle")):
                continue
            ends = parse_date(it.get("endDate"))
            if ends is None or not (ends > cutoff):
                continue
            name = str(it.get("name") or it.get("company") or slug).replace("\t", " ").strip()
            gh = str(it.get("githubUrl") or "").strip() or "-"
            rows.append((ends.isoformat(), cid, slug, name, gh))
except Exception as exc:
    sys.stderr.write("list-codehawks-concluded.sh: codehawks parse skipped (%s)\n" % exc)
    rows = []

rows.sort(key=lambda r: (r[0], r[2]))
with open(out_path, "w", encoding="utf-8") as fh:
    for ends, cid, slug, name, gh in rows:
        fh.write("%s\t%s\t%s\t%s\t%s\n" % (cid, slug, name, gh, ends))

sys.stderr.write("list-codehawks-concluded.sh: %d concluded+public+post-cutoff contest(s)\n" % len(rows))
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

if [ -n "$OUT" ]; then
  cp "$OUT_TMP" "$OUT"
else
  cat "$OUT_TMP"
fi
