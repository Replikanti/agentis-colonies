#!/usr/bin/env bash
# extract-gt-codehawks.sh — extraction half of the CodeHawks corpus GT source (#2189; unblocks #2172). Turns
# ONE concluded CodeHawks contest's findings tRPC payload into a class-tagged ground-truth truth.tsv (the exact
# 4-column shape refute-corpus-coverage.sh consumes) plus one row in a CodeHawks-only manifest
# (codehawks-corpus.tsv). It NEVER touches corpus.tsv or its Sherlock readers (fetch-corpus.sh / extract-gt.sh
# / run-corpus-bench.sh) — the CodeHawks GT lives behind a tRPC call, not a git-clonable judging repo, so it
# gets its own manifest; wiring that manifest into the bench is #2172's job.
#
# The findings endpoint (keyless GET, HTTP 200, no auth — see the #2189 feasibility probe):
#   https://codehawks.cyfrin.io/trpc/findings.getFindingOverviewsForCompetition?batch=1
#     &input=<urlencode {"0":{"competitionId":"<id>"}}>
# The <competition-id> is the `id` column emitted by list-codehawks-concluded.sh (the two scripts chain).
#
# Usage: extract-gt-codehawks.sh [--from <findings.json>] [--needs-tagging <out.tsv>] [--keywords <file>]
#                                [--max-time <s>] <competition-id> <github-url> <out-truth.tsv> <out-corpus.tsv>
#        extract-gt-codehawks.sh --self-test
#        extract-gt-codehawks.sh -h | --help
#
#   <competition-id>  CodeHawks competition id (findings tRPC key; from list-codehawks-concluded.sh col 1).
#   <github-url>      the contest's audited-code repo URL (list-codehawks-concluded.sh col 4); recorded as the
#                     corpus row's code_repo (normalised to "<org>/<repo>").
#   <out-truth.tsv>   written: one row per accepted High/Medium finding, columns (TAB):
#                       sev_id  found-by  class-csv  label
#                       sev_id    H-<n>/M-<n>, sequential per severity in payload order.
#                       found-by  DISTINCT-reporter count for the finding cluster (see RARITY below).
#                       class-csv the auto-tagged taxonomy class, or BLANK on ambiguity (see CLASS TAGGING).
#                       label     the judge-selected canonical issue's title.
#   <out-corpus.tsv>  appended (created with a header if absent): one manifest row, columns (TAB):
#                       id  code_repo  competition_id  project_subdir  scope_hint
#                     id/project_subdir/scope_hint are left for a human/#2172 to curate (project_subdir and
#                     scope_hint blank; id = the payload's urlSlug).
#   --from <json>     Offline hatch: read a saved findings tRPC response instead of the network (the ONLY mode
#                     colony-lint/CI invoke — see --self-test). No curl.
#   --needs-tagging <out>  Append every finding left class-BLANK (0 or 2+ keyword matches) here for human
#                     classification, columns (TAB): competition_id  sev_id  n_matches  matched-classes  label.
#   --keywords <file> class-keyword table (default ./codehawks-class-keywords.tsv).
#   --max-time <s>    curl --max-time on the live path (default 60; payloads are large — RAAC ~73MB).
#   --self-test       CI-safe fixture suite (no network); byte-exact vs fixtures/codehawks/expected-*.
#
# RARITY (found-by): the CodeHawks payload nests, per judged finding cluster, an `issues[]` array of EVERY raw
# submission — and a live inspection (#2189) showed the same reporter can appear MORE THAN ONCE in one cluster
# (20 of 38 clusters on the inspected contest had raw len(issues) > distinct reporters). So raw len(issues)
# OVER-counts and is NOT the rarity signal. We count DISTINCT reporters (issue.User.id, falling back to
# .username, then .Team) per cluster — the analog of Sherlock's "Found by" watson list. Fewer distinct
# reporters = rarer = the recall bucket that separates an elite hunter (refute-corpus-coverage.sh keeps rows
# with found-by <= --rare-max).
#
# CLASS TAGGING (conservative, auditable, never guessed): the finding's (title + description + content) text is
# matched against every class regex in the keyword table. A class is auto-assigned ONLY when EXACTLY ONE class
# matches; on 0 or 2+ matches the class-csv is left BLANK (a safe no-op downstream: refute-corpus-coverage.sh's
# class parser yields no C-token for an empty field, so an untagged row simply never enters the rare-GT class
# set until a human fills it in) and the finding is logged to --needs-tagging. A wrong class poisons GT, so
# ambiguity is deferred to a human, never resolved by the parser.
#
# MEMORY: the payload is large (RAAC ~73MB). The parser stream-decodes the findings array element-by-element
# (json.JSONDecoder.raw_decode per cluster) so it never materialises all clusters + their issues[] at once.
#
# A contest whose findings response is empty (privateSubmissionsToggle drift since discovery) is a clean skip:
# 0 truth rows, exit 0, with a log line — matches the discovery filter, defense in depth.
# Exit: 0 success (possibly 0 rows) ; 2 bad args ; 3 no python3 / unreadable input.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
FROM=""
NEEDS_TAGGING=""
KEYWORDS=""
MAX_TIME=60
SELFTEST=0

usage() { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; }
nv() { [ "$1" -ge 2 ] || { echo "extract-gt-codehawks.sh: $2 needs a value" >&2; exit 2; }; }

POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --from)          nv "$#" "$1"; FROM="$2"; shift 2;;
    --needs-tagging) nv "$#" "$1"; NEEDS_TAGGING="$2"; shift 2;;
    --keywords)      nv "$#" "$1"; KEYWORDS="$2"; shift 2;;
    --max-time)      nv "$#" "$1"; MAX_TIME="$2"; shift 2;;
    --self-test)     SELFTEST=1; shift;;
    -h|--help)       usage; exit 0;;
    --*)             echo "extract-gt-codehawks.sh: unknown arg: $1" >&2; exit 2;;
    *)               POS+=("$1"); shift;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "extract-gt-codehawks.sh: python3 not installed" >&2; exit 3; }
[ -n "$KEYWORDS" ] || KEYWORDS="$SELF_DIR/codehawks-class-keywords.tsv"

if [ "$SELFTEST" -eq 1 ]; then
  FX="$SELF_DIR/fixtures/codehawks"
  TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
  fails=0
  # Case 1: a normal public contest — stream-decode, dedup found-by, single-match auto-tag vs blank+needs-tag,
  # H/M only, one corpus row. Byte-exact vs the pinned expected files.
  bash "$0" --from "$FX/findings-sample.json" --needs-tagging "$TD/needs.tsv" --keywords "$FX/keywords-sample.tsv" \
       samplecompid example-org/sample-vault "$TD/truth.tsv" "$TD/corpus.tsv" >/dev/null 2>&1 || fails=$((fails+1))
  for pair in "truth.tsv:expected-truth.tsv" "corpus.tsv:expected-corpus.tsv" "needs.tsv:expected-needs-tagging.tsv"; do
    got="${pair%%:*}"; exp="${pair##*:}"
    if ! diff -q "$TD/$got" "$FX/$exp" >/dev/null 2>&1; then
      echo "extract-gt-codehawks.sh: --self-test FAIL ($got != $exp)" >&2
      diff "$FX/$exp" "$TD/$got" >&2 || true
      fails=$((fails+1))
    fi
  done
  # Case 2: a private-toggle contest (empty findings arrays) is a clean skip -> 0 truth rows, exit 0.
  bash "$0" --from "$FX/findings-private.json" --keywords "$FX/keywords-sample.tsv" \
       privcompid example-org/priv-vault "$TD/ptruth.tsv" "$TD/pcorpus.tsv" >/dev/null 2>&1 || fails=$((fails+1))
  if [ -s "$TD/ptruth.tsv" ]; then
    echo "extract-gt-codehawks.sh: --self-test FAIL (private contest produced truth rows)" >&2; fails=$((fails+1))
  fi
  if [ "$fails" -eq 0 ]; then
    echo "extract-gt-codehawks.sh: --self-test PASS (stream-decode, distinct-reporter rarity, single-match tag, private-skip)"
    exit 0
  fi
  echo "extract-gt-codehawks.sh: --self-test FAIL ($fails case(s))" >&2
  exit 1
fi

[ "${#POS[@]}" -eq 4 ] || { echo "extract-gt-codehawks.sh: usage: extract-gt-codehawks.sh [opts] <competition-id> <github-url> <out-truth.tsv> <out-corpus.tsv>" >&2; exit 2; }
CID="${POS[0]}"; GHURL="${POS[1]}"; OUT_TRUTH="${POS[2]}"; OUT_CORPUS="${POS[3]}"
[ -r "$KEYWORDS" ] || { echo "extract-gt-codehawks.sh: keyword table not readable: $KEYWORDS" >&2; exit 3; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
JSON_FILE=""
if [ -n "$FROM" ]; then
  [ -r "$FROM" ] || { echo "extract-gt-codehawks.sh: --from not readable: $FROM" >&2; exit 3; }
  JSON_FILE="$FROM"
else
  command -v curl >/dev/null 2>&1 || { echo "extract-gt-codehawks.sh: curl not installed and no --from given" >&2; exit 3; }
  JSON_FILE="$TMPD/findings.json"
  input="$(python3 -c 'import urllib.parse,json,sys; print(urllib.parse.quote(json.dumps({"0":{"competitionId":sys.argv[1]}})))' "$CID")"
  url="https://codehawks.cyfrin.io/trpc/findings.getFindingOverviewsForCompetition?batch=1&input=${input}"
  curl -sS -A "Mozilla/5.0" --max-time "$MAX_TIME" "$url" -o "$JSON_FILE" 2>/dev/null || :
  [ -s "$JSON_FILE" ] || { echo "extract-gt-codehawks.sh: empty response for competition $CID" >&2; exit 0; }
fi

CH_JSON="$JSON_FILE" CH_CID="$CID" CH_GHURL="$GHURL" CH_KEYWORDS="$KEYWORDS" \
CH_TRUTH="$OUT_TRUTH" CH_CORPUS="$OUT_CORPUS" CH_NEEDS="$NEEDS_TAGGING" python3 - <<'PY'
import os, sys, re, json

json_path = os.environ["CH_JSON"]
cid       = os.environ["CH_CID"]
ghurl     = os.environ["CH_GHURL"]
kw_path   = os.environ["CH_KEYWORDS"]
truth_out = os.environ["CH_TRUTH"]
corpus_out= os.environ["CH_CORPUS"]
needs_out = os.environ.get("CH_NEEDS", "").strip()

# code_repo := "<org>/<repo>" from the github URL (or "-" if unparseable).
def norm_repo(u):
    u = (u or "").strip()
    m = re.search(r'github\.com[:/]+([^/\s]+/[^/\s#]+)', u)
    if m:
        return re.sub(r'\.git$', '', m.group(1))
    m = re.match(r'^([^/\s]+/[^/\s#]+)$', u)
    return m.group(1) if m else "-"

# keyword table: class_id \t regex ; skip comment/blank lines.
classes = []
with open(kw_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        cls = parts[0].strip()
        rx = parts[1].strip()
        if not re.match(r'^C[0-9]+$', cls) or not rx:
            continue
        try:
            classes.append((cls, re.compile(rx, re.I)))
        except re.error:
            continue

text = open(json_path, encoding="utf-8", errors="ignore").read()
dec = json.JSONDecoder()

def find_value_start(key, after=0):
    """Index of the first '{' or '[' of the value of `key` at/after `after`, or -1."""
    k = text.find('"%s"' % key, after)
    if k < 0:
        return -1
    c = text.find(':', k + len(key) + 2)
    if c < 0:
        return -1
    i = c + 1
    while i < len(text) and text[i] in ' \t\r\n':
        i += 1
    return i

# competitionDetails is small and appears before the (large) findings array; decode it in isolation.
url_slug = ""
cd_start = find_value_start("competitionDetails")
cd_end = 0
if cd_start >= 0 and text[cd_start] == '{':
    try:
        comp, cd_end = dec.raw_decode(text, cd_start)
        url_slug = str(comp.get("urlSlug") or "").strip()
    except Exception:
        comp, cd_end = {}, 0

# findings array: locate its '[' AFTER competitionDetails' end so a stray "findings" inside earlier prose
# cannot be mistaken for the structural key. Stream-decode one cluster at a time (bounded memory).
f_start = find_value_start("findings", cd_end)
truth_rows = []
needs_rows = []
sev_counts = {"H": 0, "M": 0}

def reporter(issue):
    u = issue.get("User")
    if isinstance(u, dict):
        rid = u.get("id") or u.get("username")
        if rid:
            return ("u", str(rid))
    t = issue.get("Team")
    if isinstance(t, dict):
        rid = t.get("id") or t.get("name")
        if rid:
            return ("t", str(rid))
    return None

if f_start >= 0 and text[f_start] == '[':
    i = f_start + 1
    n = len(text)
    while True:
        while i < n and text[i] in ' \t\r\n,':
            i += 1
        if i >= n or text[i] == ']':
            break
        try:
            cluster, end = dec.raw_decode(text, i)
        except ValueError:
            break
        i = end
        if not isinstance(cluster, dict):
            continue
        sev = str(cluster.get("severity") or "").strip().lower()
        letter = {"high": "H", "medium": "M"}.get(sev)
        if letter is None:
            continue  # only accepted High/Medium enter GT (mirrors the Sherlock extractor)
        issues = cluster.get("issues") or []
        if not isinstance(issues, list):
            issues = []
        # distinct reporters = rarity
        reps = set()
        for iss in issues:
            if isinstance(iss, dict):
                r = reporter(iss)
                if r:
                    reps.add(r)
        found_by = len(reps) if reps else len(issues)
        # canonical judged issue (selectedIssueId) for the label + class text
        sid = cluster.get("selectedIssueId")
        canon = None
        for iss in issues:
            if isinstance(iss, dict) and iss.get("id") == sid:
                canon = iss
                break
        if canon is None and issues and isinstance(issues[0], dict):
            canon = issues[0]
        canon = canon or {}
        title = str(canon.get("title") or "").replace("\t", " ").replace("\n", " ").strip()
        blob = " ".join(str(canon.get(k) or "") for k in ("title", "description", "content"))
        matched = [c for (c, rx) in classes if rx.search(blob)]
        sev_counts[letter] += 1
        sev_id = "%s-%d" % (letter, sev_counts[letter])
        if len(matched) == 1:
            class_csv = matched[0]
        else:
            class_csv = ""
            needs_rows.append((cid, sev_id, str(len(matched)), ",".join(matched), title))
        truth_rows.append((sev_id, str(found_by), class_csv, title))

with open(truth_out, "w", encoding="utf-8") as fh:
    for sev_id, fb, cls, title in truth_rows:
        fh.write("%s\t%s\t%s\t%s\n" % (sev_id, fb, cls, title))

# corpus manifest: append (create with header if absent). NEVER corpus.tsv.
corpus_id = url_slug or cid
new_file = not os.path.exists(corpus_out) or os.path.getsize(corpus_out) == 0
with open(corpus_out, "a", encoding="utf-8") as fh:
    if new_file:
        fh.write("# codehawks-corpus.tsv — CodeHawks-only GT manifest (#2189; separate from corpus.tsv, which is\n")
        fh.write("# Sherlock-only). Columns (TAB): id  code_repo  competition_id  project_subdir  scope_hint\n")
        fh.write("#   id             urlSlug of the concluded contest (work-dir naming / --id selection).\n")
        fh.write("#   code_repo      GitHub \"<org>/<repo>\" of the audited code (from list-codehawks-concluded.sh).\n")
        fh.write("#   competition_id CodeHawks competition id (findings tRPC key; extract-gt-codehawks.sh input).\n")
        fh.write("#   project_subdir REQUIRED by #2172's fetch/run wiring; left BLANK here for a human to fill.\n")
        fh.write("#   scope_hint     optional map-zones.sh restriction; BLANK = auto-discover. Left for #2172.\n")
    fh.write("%s\t%s\t%s\t%s\t%s\n" % (corpus_id, norm_repo(ghurl), cid, "", ""))

if needs_out:
    new_needs = not os.path.exists(needs_out) or os.path.getsize(needs_out) == 0
    with open(needs_out, "a", encoding="utf-8") as fh:
        if new_needs:
            fh.write("# findings left class-BLANK (0 or 2+ keyword matches) — human classification required.\n")
            fh.write("# Columns (TAB): competition_id  sev_id  n_matches  matched-classes  label\n")
        for row in needs_rows:
            fh.write("\t".join(row) + "\n")

sys.stderr.write("extract-gt-codehawks.sh: %d High/Medium GT row(s) (%d auto-tagged, %d need human class) -> %s\n"
                 % (len(truth_rows), len(truth_rows) - len(needs_rows), len(needs_rows), truth_out))
PY
