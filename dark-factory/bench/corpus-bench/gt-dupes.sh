#!/usr/bin/env bash
# gt-dupes.sh — build a per-contest GT-EQUIVALENCE artifact (issue #1840). A concluded judging repo routinely
# accepts TWO rows for the SAME underlying bug, written up differently and found by very different watson
# counts. The scoring judge (#1829) is asked for at most one MATCH per candidate and only ever sees one
# `--judge-batch` slice of the rows at a time, so a lead that finds such a bug credits whichever twin the
# model happened to name — and since the bench headline is stratified by rarity, the RARE twin is the one
# silently lost. Detecting the duplicates GT-side, once per contest, removes that dependence entirely: the
# corpus knows all its rows up front.
#
# WHAT IT DOES: judges every truth row against the rows AFTER it (upper triangle — no self-pairs, half the
# calls), batched, through the UNCHANGED mech-judge.sh driver and its unchanged request/reply grammar. The row
# under test is sent in the `lead` slot with `id = R-<sev_id>` and its signature in `exploit`; the reply is the
# usual `VERDICT|<lead_id>|<sev_id>|MATCH|<confidence>|<reason>`. So the same driver, the same decision rule
# and the same flat-cyborg billing path decide "same bug?" here as during scoring.
#
# OUTPUT (`<out.tsv>`, archived next to truth.tsv and read by score-match.py --gt-dupes):
#   # gt-dupes/v1 contest=<id> source=judge driver=<driver> built=<iso8601>
#   DUP <TAB> <sev_a> <TAB> <sev_b> <TAB> <confidence 0-100> <TAB> <one-line reason>
# `source=judge` marks a machine-built artifact; a hand-curated one must say `source=manual` so a reader can
# tell curation from judgement. The MERGE BAR is applied by the SCORER (`--gt-dupes-min-confidence`, default
# 85), not here: this file records what the judge decided, so one archived artifact re-derives the expanded
# number, the unexpanded number and any threshold in between. `--min-confidence` is only the RECORDING floor.
#
# FAIL-CLOSED: an unparseable reply, a verdict about another row, or a MATCH naming a sev_id that was not in
# the request produces NO pair (no pair = no expansion = the old behaviour) and is counted in a summary line
# on stderr. This script never fabricates a pairing to fill a gap.
#
# COST: about N/2 x ceil(N/batch) calls per contest — for a 30-row contest roughly 55 calls, comparable to one
# scoring pass — but paid ONCE per contest, independent of the lead count, and persisted as a file.
#
# Usage: gt-dupes.sh <truth.tsv> <out.tsv> [--judge-cmd <path>] [--batch N] [--min-confidence N]
#                    [--log <file.jsonl>] [--force] | gt-dupes.sh --self-test | -h
#   --judge-cmd <p>   judge driver (default: mech-judge.sh next to this script, which drives the flat-cyborg
#                     PTY wrapper — judging bills against the flat-rate subscription, never the metered API).
#   --batch N         truth rows shown per judging call (default 12, same as the scorer's --judge-batch).
#   --min-confidence N  RECORDING floor: a MATCH below this confidence is not written (default 70, the same
#                     gate the scorer applies to judge MATCHes). The merge bar is the scorer's, and higher.
#   --log <f>         JSONL append-only record of every judging call (request + raw reply + accepted pairs).
#   --force           overwrite an existing <out.tsv> (without it an existing artifact is never clobbered).
#   --self-test       offline contract check (no LLM, no network): the builder reproduces the committed
#                     fixtures/gt-dupes/gt-dupes.tsv over the offline stub, a non-duplicate pair is NOT
#                     merged, an unparseable reply yields no pair, and the LLM path goes through mech-judge.sh.
# Exit: 0 = artifact written (zero pairs is a valid answer) ; 1 = --self-test regressed ; 2 = bad args ;
#       3 = missing prerequisite / unwritable output / existing artifact without --force.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/fixtures/gt-dupes"

# The #1829 driver, reused VERBATIM: same prompt, same request/reply grammar, same flat-cyborg billing path.
# Kept on its own line so the source-guards (here and in demo-mech-judge.sh) can anchor on the assignment.
JUDGE_CMD="$HERE/mech-judge.sh"
TRUTH="" ; OUT="" ; BATCH="12" ; MINCONF="70" ; LOG="" ; FORCE=0 ; SELFTEST=0

nv() { [ "$1" -ge 2 ] || { echo "gt-dupes.sh: $2 requires a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do case "$1" in
  --judge-cmd)      nv "$#" "$1"; JUDGE_CMD="$2"; shift 2 ;;
  --batch)          nv "$#" "$1"; BATCH="$2"; shift 2 ;;
  --min-confidence) nv "$#" "$1"; MINCONF="$2"; shift 2 ;;
  --log)            nv "$#" "$1"; LOG="$2"; shift 2 ;;
  --force)          FORCE=1; shift ;;
  --self-test)      SELFTEST=1; shift ;;
  -h|--help)        awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
  -*) echo "gt-dupes.sh: unknown arg: $1" >&2; exit 2 ;;
  *) if   [ -z "$TRUTH" ]; then TRUTH="$1"
     elif [ -z "$OUT" ];   then OUT="$1"
     else echo "gt-dupes.sh: unexpected extra arg: $1" >&2; exit 2; fi; shift ;;
esac; done

command -v python3 >/dev/null 2>&1 || { echo "gt-dupes.sh: python3 not installed" >&2; exit 3; }

# ---- the builder itself (one python3 heredoc, same idiom as extract-gt.sh) -----------------------------------
# Args: <truth.tsv> <out.tsv> <judge-cmd> <batch> <min-confidence> <log|"">
build() {
  python3 - "$@" <<'PY'
import sys, os, json, subprocess, datetime

truth_path, out_path, judge_cmd, batch_s, minconf_s, log_path = sys.argv[1:7]
batch = max(1, int(batch_s))
min_conf = int(minconf_s)

rows = []
try:
    with open(truth_path, encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 5 or not cols[0]:
                continue
            rows.append((cols[0], cols[4]))          # (sev_id, signature)
except OSError as e:
    sys.stderr.write("gt-dupes.sh: cannot read %s: %s\n" % (truth_path, e))
    sys.exit(3)

# The contest id is the work-dir directory holding truth.tsv (<work>/<id>/truth.tsv) — provenance only.
contest = os.path.basename(os.path.dirname(os.path.abspath(truth_path))) or "unknown"


def log(entry):
    if not log_path:
        return
    try:
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n")
    except OSError as e:
        sys.stderr.write("gt-dupes.sh: cannot append to %s: %s\n" % (log_path, e))
        sys.exit(3)


def judge(request_text):
    """Run the driver with the request on stdin; return its stdout verbatim. A non-zero exit or an empty
    reply is not fatal — it simply yields no parseable verdict, i.e. no pair."""
    try:
        proc = subprocess.run([judge_cmd], input=request_text, capture_output=True, text=True)
    except OSError as e:
        sys.stderr.write("gt-dupes.sh: cannot run --judge-cmd %s: %s\n" % (judge_cmd, e))
        sys.exit(3)
    return proc.stdout or ""


pairs = []            # (sev_a, sev_b, confidence, reason) in upper-triangle order
calls = 0
errors = 0
for i, (sev_id, signature) in enumerate(rows):
    lid = "R-" + sev_id
    rest = rows[i + 1:]
    for start in range(0, len(rest), batch):
        chunk = rest[start:start + batch]
        # The UNCHANGED mech-judge.sh request shape: the row under test occupies the `lead` slot, its prose in
        # `exploit`. The remaining lead fields stay empty — a GT row has no hunter-side location or PoC.
        req = {
            "lead": {"id": lid, "location": "", "file": "", "class": "", "exploit": signature,
                     "poc_sketch": ""},
            "rows": [{"sev_id": s, "signature": g} for s, g in chunk],
        }
        text = json.dumps(req, sort_keys=True, separators=(",", ":"))
        calls += 1
        raw = judge(text)
        shown = {s for s, _g in chunk}
        accepted = []
        parsed_any = False
        for line in raw.splitlines():
            line = line.strip()
            if not line.startswith("VERDICT|"):
                continue
            parts = line.split("|")
            if len(parts) < 5 or parts[1].strip() != lid:
                continue
            decision = parts[3].strip().upper()
            if decision not in ("MATCH", "NO-MATCH"):
                continue
            try:
                confidence = int(float(parts[4].strip()))
            except ValueError:
                continue
            parsed_any = True
            if decision != "MATCH":
                continue
            other = parts[2].strip()
            if other not in shown:      # hallucinated row id -> never a pair
                errors += 1
                continue
            if confidence < min_conf:
                continue
            reason = parts[5].strip().replace("\t", " ") if len(parts) >= 6 else ""
            accepted.append((sev_id, other, confidence, reason))
        if not parsed_any:
            # Fail-closed: no verdict is never read as "these rows are distinct" beyond the no-pair default.
            errors += 1
        pairs.extend(accepted)
        log({"lead_id": lid, "request": text, "raw_reply": raw,
             "pairs": [{"sev_a": a, "sev_b": b, "confidence": c, "reason": r} for a, b, c, r in accepted]})

built = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
try:
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write("# gt-dupes/v1 contest=%s source=judge driver=%s built=%s\n"
                 % (contest, os.path.basename(judge_cmd), built))
        fh.write("# %d judged duplicate pair(s) from %d call(s) over %d truth row(s); recording floor %d.\n"
                 % (len(pairs), calls, len(rows), min_conf))
        for sev_a, sev_b, confidence, reason in pairs:
            fh.write("DUP\t%s\t%s\t%d\t%s\n" % (sev_a, sev_b, confidence, reason))
except OSError as e:
    sys.stderr.write("gt-dupes.sh: cannot write %s: %s\n" % (out_path, e))
    sys.exit(3)

sys.stderr.write("gt-dupes.sh: %d pair(s) from %d judging call(s) over %d row(s), %d unusable reply/replies "
                 "-> %s\n" % (len(pairs), calls, len(rows), errors, out_path))
PY
}

# ---- --self-test (offline; no LLM, no network) ----------------------------------------------------------------
if [ "$SELFTEST" -eq 1 ]; then
  FAILS=0
  ok()  { echo "  [PASS] $*"; }
  bad() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

  for f in truth.tsv gt-dupes.tsv dupes-stub.sh; do
    [ -f "$FIX/$f" ] || { echo "gt-dupes.sh: fixture missing: $FIX/$f" >&2; exit 3; }
  done
  TMPD="$(mktemp -d)"
  trap 'rm -rf "$TMPD"' EXIT

  # (a) the builder reproduces the committed artifact body over the offline stub: it pairs the two twins and
  #     does NOT pair the two rows that merely share a function name.
  build "$FIX/truth.tsv" "$TMPD/gt-dupes.tsv" "$FIX/dupes-stub.sh" 12 70 "" >/dev/null 2>&1
  if diff <(grep -v '^#' "$TMPD/gt-dupes.tsv") <(grep -v '^#' "$FIX/gt-dupes.tsv") >/dev/null 2>&1; then
    ok "(a) the builder reproduces fixtures/gt-dupes/gt-dupes.tsv (pairs the twins, leaves the name-sharing rows apart)"
  else
    bad "(a) the built artifact body differs from the committed fixture"
    diff <(grep -v '^#' "$TMPD/gt-dupes.tsv") <(grep -v '^#' "$FIX/gt-dupes.tsv") >&2 || true
  fi

  # (b) an unparseable reply produces NO pair — fail-closed: no pair = no expansion = the old behaviour.
  printf '#!/bin/sh\necho "these two look related but I would rather not commit to a structured verdict"\n' \
    > "$TMPD/mute.sh"
  chmod +x "$TMPD/mute.sh"
  build "$FIX/truth.tsv" "$TMPD/gt-dupes.mute.tsv" "$TMPD/mute.sh" 12 70 "" >/dev/null 2>&1
  if ! grep -qv '^#' "$TMPD/gt-dupes.mute.tsv"; then
    ok "(b) an unparseable judge reply yields NO pair (no pair = no expansion = the pre-#1840 behaviour)"
  else
    bad "(b) an unparseable judge reply produced a pairing"
    grep -v '^#' "$TMPD/gt-dupes.mute.tsv" | sed 's/^/         | /' | head -5
  fi

  # (c) the LLM path is mech-judge.sh (hence the flat-cyborg wrapper) and the metered print-mode API is never
  #     invoked — only NON-COMMENT lines are inspected, the header legitimately discusses it.
  if grep -qE '^JUDGE_CMD=.*mech-judge\.sh' "$0"; then
    ok "(c1) the default judge driver is mech-judge.sh (the flat-cyborg subscription path, unchanged grammar)"
  else
    bad "(c1) mech-judge.sh is not wired as the default judge driver"
  fi
  if grep -vE '^[[:space:]]*#' "$0" | grep -qE 'claude[[:space:]]+-p'; then
    bad "(c2) this builder shells out to the metered print-mode API instead of mech-judge.sh"
  else
    ok "(c2) no metered print-mode API invocation — pairing goes through mech-judge.sh like scoring does"
  fi

  echo
  if [ "$FAILS" -eq 0 ]; then
    echo "gt-dupes.sh: PASS — upper-triangle pairing over the offline stub reproduces the committed artifact,"
    echo "gt-dupes.sh:        a garbled reply yields no pair, and the LLM path is mech-judge.sh only."
    exit 0
  fi
  echo "gt-dupes.sh: FAIL — $FAILS builder-contract assertion(s) regressed" >&2
  exit 1
fi

# ---- build one contest's artifact -----------------------------------------------------------------------------
[ -n "$TRUTH" ] && [ -n "$OUT" ] || { echo "gt-dupes.sh: usage: gt-dupes.sh <truth.tsv> <out.tsv> [options]" >&2; exit 2; }
[ -r "$TRUTH" ] || { echo "gt-dupes.sh: not readable: $TRUTH" >&2; exit 3; }
[ -x "$JUDGE_CMD" ] || { echo "gt-dupes.sh: judge driver not found/executable: $JUDGE_CMD" >&2; exit 3; }
if [ -e "$OUT" ] && [ "$FORCE" -ne 1 ]; then
  echo "gt-dupes.sh: $OUT already exists; pass --force to rebuild it (an archived artifact is never clobbered)" >&2
  exit 3
fi

build "$TRUTH" "$OUT" "$JUDGE_CMD" "$BATCH" "$MINCONF" "$LOG"
