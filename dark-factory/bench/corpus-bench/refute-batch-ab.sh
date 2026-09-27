#!/usr/bin/env bash
# refute-batch-ab.sh — #2284 (M2) real-data replay + A/B driver for the refute gate's BATCHED FIRST READ
# (verify-findings.sh --refute-batch, default OFF). It answers two questions with real candidate sets:
#   1. OFFLINE (--self-test): on the frozen notional candidate archives, does batching change ANY verdict, any
#      artifact or any per-row HIT/MISS when every candidate gets the answer it actually got live? (It must not.)
#      And how many first-read sessions does it save on that real set? (Pinned: 29 -> 18, -38 %, both archives.)
#   2. LIVE (--live): does a real LLM, judging several candidates of one function in ONE session, keep the same
#      per-row HIT/MISS as it does judging them one by one? That is the M3 dev-twin measurement; this script only
#      drives it and writes the report. The DEFAULT flip (M4) is decided on that evidence, never here.
#
# THREE modes:
#   --reconstruct <archive> --out <results.json> --verdicts <tsv>
#       Rebuild a discovery-results.json-shaped candidate set (one `replay` cell, candidates in gate order) and the
#       recorded verdicts (`n \t location \t class \t verdict \t reason \t exploit`) from either archive shape:
#         runs/1886-notional-refute-fn     refute/<n>_<slug>/{candidate.manifest,verdict.txt}
#         runs/1887-notional-constraints   combined.manifest + refute-report.md (rows in manifest order)
#   --self-test (default; CI-safe: no network / LLM / forge). For BOTH notional archives (role `dev`): a placeholder
#       repo at the candidates' code paths and a REPLAY stub (through the --agentis seam) that answers each
#       candidate's RECORDED verdict and reason, in single and in batch mode. verify-findings.sh runs three times —
#       DF_REFUTE_BATCH=0, =1, and =1 --jobs 3 — and the self-test asserts:
#         (a) verified_findings.json and refute-constraints.tsv are byte-identical across the three runs;
#         (b) score-match.py token-mode output against runs/1886-notional-refute-fn/truth.tsv is identical per row
#             across the three runs (and, on the 1886 archive, identical to the archived verified_findings.json's);
#         (c) first-read sessions are pinned at 29 -> 18 (-38 %) on both archives, and lib/refute-batch.py summary
#             predicts the same;
#         (d) the 3-member CurveConvex2Token.sol:unstakeAndExitPool group fans out to exactly its recorded verdicts
#             (REFUTED / REAL / REFUTED on the 1886 archive) inside ONE batch.
#       It also drives --live end to end through the same stub (mock backend) and checks the refusals below.
#   --live --id <contest> --results <frozen results.json> --repo <code dir> --truth <truth.tsv> --work <dir>
#          [--jobs N] [--backend <b>] [--agentis <bin>] [--model <id>]
#       The pre-registered A/B. REFUSES any id whose corpus.tsv role is not `dev` — a held-out id, and an id that is
#       not in the manifest at all (a fresh-set row), is refused mechanically (exit 2). Arm labels are FIXED and
#       written to <work>/arms.txt before either arm runs: CONTROL = DF_REFUTE_BATCH=0, TREATMENT =
#       DF_REFUTE_BATCH=1, run SEQUENTIALLY (never concurrently) with --backend flat-cyborg by default, each with its
#       own DF_REFUTE_SESSION_LOG. An existing arm dir is never overwritten (exit 2). Writes <work>/ab-report.md:
#       per-row HIT/MISS for both arms, a per-candidate verdict diff, first-read and total sessions, and each arm's
#       STAGE 4 wall-clock. The pass rule (identical per-row HIT/MISS; one extra control replicate before judging a
#       differing row; >= 30 % fewer sessions) is stated in the report and applied by the operator.
#
# Usage: refute-batch-ab.sh [--self-test] | --reconstruct <archive> --out <f> --verdicts <f>
#        | --live --id <id> --results <f> --repo <dir> --truth <f> --work <dir> [--jobs N] [--backend <b>]
#          [--agentis <bin>] [--model <id>]
# Exit: 0 = self-test held / reconstruction or live run completed; 1 = self-test regressed; 2 = bad args or a
#       refused id; 3 = missing prerequisite or unreadable archive.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DF="$(cd "$HERE/../.." && pwd)"
VERIFY="$DF/verify-findings.sh"
PLANNER="$DF/lib/refute-batch.py"
SCOREMATCH="$HERE/score-match.py"
CORPUS="$HERE/corpus.tsv"
ARCH_1886="$HERE/runs/1886-notional-refute-fn"
ARCH_1887="$HERE/runs/1887-notional-constraints"

MODE="self-test"
ARCHIVE="" ; R_OUT="" ; R_VERDICTS=""
ID="" ; RESULTS="" ; REPO="" ; TRUTH="" ; WORK_DIR="" ; JOBS=1 ; BACKEND="flat-cyborg" ; AGENTIS="agentis" ; MODEL=""

nv() { [ "$1" -ge 2 ] || { echo "refute-batch-ab.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do case "$1" in
  --self-test)   MODE="self-test"; shift ;;
  --reconstruct) nv "$#"; MODE="reconstruct"; ARCHIVE="$2"; shift 2 ;;
  --out)         nv "$#"; R_OUT="$2"; shift 2 ;;
  --verdicts)    nv "$#"; R_VERDICTS="$2"; shift 2 ;;
  --live)        MODE="live"; shift ;;
  --id)          nv "$#"; ID="$2"; shift 2 ;;
  --results)     nv "$#"; RESULTS="$2"; shift 2 ;;
  --repo)        nv "$#"; REPO="$2"; shift 2 ;;
  --truth)       nv "$#"; TRUTH="$2"; shift 2 ;;
  --work)        nv "$#"; WORK_DIR="$2"; shift 2 ;;
  --jobs)        nv "$#"; JOBS="$2"; shift 2 ;;
  --backend)     nv "$#"; BACKEND="$2"; shift 2 ;;
  --agentis)     nv "$#"; AGENTIS="$2"; shift 2 ;;
  --model)       nv "$#"; MODEL="$2"; shift 2 ;;
  -h|--help)     awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
  *) echo "refute-batch-ab.sh: unknown arg: $1" >&2; exit 2 ;;
esac; done

note() { echo "refute-batch-ab.sh: $*"; }
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

# reconstruct <archive> <results.json> <verdicts.tsv> — see --reconstruct above. Exit 3 on an unknown shape.
reconstruct() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, os, json, re
arch, out, vout = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []  # (manifest line, verdict, reason)
ref = os.path.join(arch, "refute")
if os.path.isdir(ref):
    dirs = [d for d in os.listdir(ref) if re.match(r"^[0-9]+_", d)]
    for d in sorted(dirs, key=lambda d: int(d.split("_", 1)[0])):
        man = open(os.path.join(ref, d, "candidate.manifest"), encoding="utf-8").read().splitlines()[0]
        v = open(os.path.join(ref, d, "verdict.txt"), encoding="utf-8").read().rstrip("\n").split("\t", 1)
        rows.append((man, v[0].strip(), v[1].strip() if len(v) > 1 else ""))
elif os.path.isfile(os.path.join(arch, "combined.manifest")) and os.path.isfile(os.path.join(arch, "refute-report.md")):
    mans = [l for l in open(os.path.join(arch, "combined.manifest"), encoding="utf-8").read().splitlines()
            if l.strip() and not l.lstrip().startswith("#")]
    reps = []
    for l in open(os.path.join(arch, "refute-report.md"), encoding="utf-8"):
        if not l.startswith("| ") or l.startswith("| Candidate"):
            continue
        p = l.rstrip("\n").split("|")
        reps.append((p[3].strip(), "|".join(p[4:-1]).strip()))
    if len(mans) != len(reps):
        sys.stderr.write("refute-batch-ab.sh: %d manifest lines but %d report rows in %s\n" % (len(mans), len(reps), arch))
        sys.exit(3)
    rows = [(m, v, r) for m, (v, r) in zip(mans, reps)]
else:
    sys.stderr.write("refute-batch-ab.sh: unknown archive shape (no refute/ dir, no combined.manifest + refute-report.md): %s\n" % arch)
    sys.exit(3)
cands, vlines = [], []
for n, (man, verdict, reason) in enumerate(rows, start=1):
    f = man.split("|")
    while len(f) < 5:
        f.append("")
    loc, cls, sev, expl = f[0].strip(), f[1].strip(), f[2].strip(), f[3].strip()
    cands.append("|".join([loc, cls, sev, expl, ""]))
    vlines.append("\t".join(x.replace("\t", " ") for x in [str(n), loc, cls, verdict, reason, expl]))
d = {"repo": os.path.basename(os.path.normpath(arch)), "backend": "replay",
     "cells": [{"subsystem": "replay", "class": "", "candidates": cands}]}
open(out, "w", encoding="utf-8").write(json.dumps(d, indent=2) + "\n")
open(vout, "w", encoding="utf-8").write("\n".join(vlines) + "\n")
print("RECONSTRUCT|%s|%d" % (os.path.basename(os.path.normpath(arch)), len(rows)))
PY
}

# sessions <log> <kind> -> the number of recorded sessions of that kind.
sessions() { if [ -f "$1" ]; then awk -F'\t' -v k="$2" '$2==k' "$1" | grep -c . || true; else echo 0; fi; }
# rows_of <truth> <verified_findings.json> -> the per-row `sev_id \t HIT|MISS` lines of the token-mode scorer.
rows_of() { python3 "$SCOREMATCH" "$1" "$2" 2>/dev/null | awk -F'\t' '$2=="HIT" || $2=="MISS" {print $1 "\t" $2}'; }

# write_report <work> <id> <truth> — ab-report.md from the two finished arms.
write_report() {
  wr_w="$1"; wr_id="$2"; wr_truth="$3"
  rows_of "$wr_truth" "$wr_w/control/verified_findings.json" > "$wr_w/control.rows"
  rows_of "$wr_truth" "$wr_w/treatment/verified_findings.json" > "$wr_w/treatment.rows"
  python3 - "$wr_w" "$wr_id" <<'PY'
import sys, os, glob
w, cid = sys.argv[1], sys.argv[2]
def rows(p):
    return [l.rstrip("\n").split("\t") for l in open(p, encoding="utf-8") if l.strip()]
def verdicts(arm):
    out = {}
    for p in glob.glob(os.path.join(w, arm, "gates", "*", "verdict.txt")):
        name = os.path.basename(os.path.dirname(p))
        out[name] = open(p, encoding="utf-8").read().split("\t", 1)[0].strip()
    return out
def sess(arm):
    p = os.path.join(w, arm + ".sessions")
    kinds = {}
    if os.path.exists(p):
        for l in open(p, encoding="utf-8"):
            f = l.rstrip("\n").split("\t")
            if len(f) >= 2:
                kinds[f[1]] = kinds.get(f[1], 0) + 1
    return kinds
def wall(arm):
    p = os.path.join(w, arm + ".wall")
    return open(p).read().strip() if os.path.exists(p) else "?"
cr, tr = rows(os.path.join(w, "control.rows")), rows(os.path.join(w, "treatment.rows"))
tmap = dict((r[0], r[1]) for r in tr)
diff_rows = [r[0] for r in cr if tmap.get(r[0]) != r[1]]
cv, tv = verdicts("control"), verdicts("treatment")
vdiff = sorted((k for k in set(cv) | set(tv) if cv.get(k) != tv.get(k)), key=lambda k: int(k.split("_", 1)[0]))
cs, ts = sess("control"), sess("treatment")
cfirst = cs.get("first", 0) + cs.get("batch", 0)
tfirst = ts.get("first", 0) + ts.get("batch", 0)
pct = int(round(100.0 * (cfirst - tfirst) / cfirst)) if cfirst else 0
L = []
L.append("# Refute-batch A/B (#2284) — %s" % cid)
L.append("")
L.append(open(os.path.join(w, "arms.txt"), encoding="utf-8").read().rstrip("\n"))
L.append("")
L.append("## Verdict")
L.append("")
L.append("- per-row HIT/MISS: **%s**" % ("IDENTICAL" if not diff_rows else "DIFFERS on %d row(s): %s" % (len(diff_rows), ", ".join(diff_rows))))
L.append("- first-read sessions: control %d -> treatment %d (%d%% fewer); total sessions: control %d, treatment %d"
         % (cfirst, tfirst, pct, sum(cs.values()), sum(ts.values())))
L.append("- STAGE 4 wall-clock: control %ss, treatment %ss" % (wall("control"), wall("treatment")))
L.append("- per-candidate verdicts: %s" % ("identical" if not vdiff else "%d differ (table below)" % len(vdiff)))
L.append("")
L.append("Pass rule (pre-registered): identical per-row HIT/MISS AND >= 30% fewer first-read sessions. A row that differs")
L.append("is judged only after ONE extra control replicate (separates LLM noise from batching); a HIT lost only under the")
L.append("treatment that both control runs keep is a FAIL, and the default stays OFF.")
L.append("")
L.append("## Per-row HIT/MISS")
L.append("")
L.append("| row | control | treatment |")
L.append("|---|---|---|")
for r in cr:
    mark = "" if tmap.get(r[0]) == r[1] else " **(differs)**"
    L.append("| %s | %s | %s%s |" % (r[0], r[1], tmap.get(r[0], "?"), mark))
L.append("")
L.append("## Per-candidate verdict diff")
L.append("")
if not vdiff:
    L.append("No candidate changed verdict.")
else:
    L.append("| gate | control | treatment |")
    L.append("|---|---|---|")
    for k in vdiff:
        L.append("| %s | %s | %s |" % (k, cv.get(k, "-"), tv.get(k, "-")))
L.append("")
L.append("## Sessions by kind")
L.append("")
L.append("| kind | control | treatment |")
L.append("|---|---|---|")
for k in ("batch", "first", "reask", "c6"):
    L.append("| %s | %d | %d |" % (k, cs.get(k, 0), ts.get(k, 0)))
open(os.path.join(w, "ab-report.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")
print("AB|%s|%s|%d|%d|%d" % (cid, "IDENTICAL" if not diff_rows else "DIFFERS", cfirst, tfirst, len(vdiff)))
PY
}

# live_ab — the --live mode body (also driven by the self-test through the mock backend).
live_ab() {
  [ -n "$ID" ] && [ -n "$RESULTS" ] && [ -n "$REPO" ] && [ -n "$TRUTH" ] && [ -n "$WORK_DIR" ] \
    || { echo "refute-batch-ab.sh: --live needs --id --results --repo --truth --work" >&2; return 2; }
  case "$JOBS" in ''|*[!0-9]*) echo "refute-batch-ab.sh: --jobs must be a positive integer" >&2; return 2 ;; esac
  la_role="$(awk -F'\t' -v id="$ID" '!/^#/ && $1==id {print $5; exit}' "$CORPUS")"
  if [ -z "$la_role" ]; then
    echo "refute-batch-ab.sh: '$ID' is not in corpus.tsv — refused (live batching runs on dev twins only, never on a fresh-set row)" >&2
    return 2
  fi
  if [ "$la_role" != "dev" ]; then
    echo "refute-batch-ab.sh: '$ID' has role '$la_role' — refused (live batching runs on dev twins only, never on a held-out row)" >&2
    return 2
  fi
  [ -f "$RESULTS" ] && [ -d "$REPO" ] && [ -f "$TRUTH" ] || { echo "refute-batch-ab.sh: --results/--repo/--truth not found" >&2; return 3; }
  mkdir -p "$WORK_DIR"
  if [ -e "$WORK_DIR/control" ] || [ -e "$WORK_DIR/treatment" ]; then
    echo "refute-batch-ab.sh: $WORK_DIR already holds an arm — refusing to overwrite a measured arm" >&2
    return 2
  fi
  # The labels are FIXED here, before either arm runs.
  {
    echo "- contest: $ID (role: dev)"
    echo "- control   = DF_REFUTE_BATCH=0 (every candidate refuted in its own first-read session)"
    echo "- treatment = DF_REFUTE_BATCH=1 (batched first read, DF_REFUTE_BATCH_MAX=${DF_REFUTE_BATCH_MAX:-6})"
    echo "- backend: $BACKEND${MODEL:+ (model $MODEL)}, --jobs $JOBS, arms run sequentially (control first)"
  } > "$WORK_DIR/arms.txt"
  for la_arm in control treatment; do
    la_flag=0; [ "$la_arm" = "treatment" ] && la_flag=1
    note "$la_arm arm (DF_REFUTE_BATCH=$la_flag) ..."
    la_t0="$(date +%s)"
    DF_REFUTE_BATCH="$la_flag" DF_REFUTE_SESSION_LOG="$WORK_DIR/$la_arm.sessions" \
      "$VERIFY" --results "$RESULTS" --repo "$REPO" --out "$WORK_DIR/$la_arm" --backend "$BACKEND" \
      --agentis "$AGENTIS" ${MODEL:+--model "$MODEL"} --jobs "$JOBS" > "$WORK_DIR/$la_arm.log" 2>&1 \
      || { echo "refute-batch-ab.sh: the $la_arm arm failed (see $WORK_DIR/$la_arm.log)" >&2; return 1; }
    echo "$(( $(date +%s) - la_t0 ))" > "$WORK_DIR/$la_arm.wall"
  done
  write_report "$WORK_DIR" "$ID" "$TRUTH"
  note "report at $WORK_DIR/ab-report.md"
}

case "$MODE" in
  reconstruct)
    [ -n "$ARCHIVE" ] && [ -n "$R_OUT" ] && [ -n "$R_VERDICTS" ] \
      || { echo "refute-batch-ab.sh: --reconstruct needs <archive> --out <results.json> --verdicts <tsv>" >&2; exit 2; }
    [ -d "$ARCHIVE" ] || { echo "refute-batch-ab.sh: archive not found: $ARCHIVE" >&2; exit 3; }
    reconstruct "$ARCHIVE" "$R_OUT" "$R_VERDICTS"
    exit $?
    ;;
  live)
    live_ab
    exit $?
    ;;
esac

# ==========================================================================================================
# --self-test (default)
# ==========================================================================================================
FAILS=0
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (want '$2', got '$1')"; fi; }
for f in "$VERIFY" "$PLANNER"; do [ -x "$f" ] || { note "not found / not executable: $f" >&2; exit 3; }; done
for d in "$ARCH_1886" "$ARCH_1887"; do [ -d "$d" ] || { note "archive missing: $d" >&2; exit 3; }; done

ST="$(mktemp -d "${TMPDIR:-/tmp}/refute-batch-ab.XXXXXX")"
trap 'rm -rf "$ST"' EXIT

# The REPLAY stub: every candidate — alone or inside a batch — gets the verdict and reason it got live, looked up
# by (location, class, exploit) in STUB_VERDICTS. A REFUTED answer carries a fixed constraint so the #1887 sidecar
# is exercised too.
STUB="$ST/agentis-replay"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
answer() {
  a_row="$(A_LOC="$1" A_CLS="$2" A_EXPL="$3" awk -F'\t' \
    '$2==ENVIRON["A_LOC"] && $3==ENVIRON["A_CLS"] && $6==ENVIRON["A_EXPL"] { print $4 "\t" $5; exit }' "$STUB_VERDICTS")"
  a_v="$(printf '%s\n' "$a_row" | cut -f1)"; a_r="$(printf '%s\n' "$a_row" | cut -f2-)"
  case "$a_v" in
    REAL) echo "VERDICT|REAL|$1|$2|$a_r" ;;
    REFUTED)
      echo "CONSTRAINT|$2|a replayed refutation standard for $2"
      echo "VERDICT|REFUTED|$1|$2|$a_r" ;;
    *) echo "no recorded verdict for $1 ($2)" ;;
  esac
}
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go)
    if [ -n "${CAND_BATCH_PATH:-}" ]; then
      echo "REFUTE-BATCH|refute|$(grep -c . "$CAND_BATCH_PATH")"
      echo
      while IFS='|' read -r k fn cls sev expl; do
        [ -n "$k" ] || continue
        echo "REFUTE-ITEM|$k"
        answer "$fn" "$cls" "$expl"
      done < "$CAND_BATCH_PATH"
    else
      answer "${CAND_FILE_FN:-}" "${CAND_CLASS:-}" "${CAND_EXPLOIT:-}"
    fi
    exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB"

TRUTH_1886="$ARCH_1886/truth.tsv"
# verify_arm <dir> <results> <verdicts> <batch 0|1> <jobs>
verify_arm() {
  STUB_VERDICTS="$3" DF_REFUTE_BATCH="$4" DF_REFUTE_SESSION_LOG="$1.sessions" DF_AGENT_MAX_ATTEMPTS=1 \
    "$VERIFY" --results "$2" --repo "$ST/repo-$(basename "$3" .tsv)" --out "$1" --backend mock --agentis "$STUB" \
    --jobs "$5" > "$1.log" 2>&1
}

for ARCH in "$ARCH_1886" "$ARCH_1887"; do
  AN="$(basename "$ARCH")"
  note "$AN"
  RES="$ST/$AN.results.json"; VER="$ST/$AN.tsv"
  check "$(reconstruct "$ARCH" "$RES" "$VER")" "RECONSTRUCT|$AN|29" "$AN: reconstructed 29 candidates in gate order"
  # A placeholder repo at every candidate's code path (content is irrelevant to the replay; no abstract base, so no
  # #1861 appendix is ever attached).
  python3 - "$RES" "$ST/repo-$AN" <<'PY'
import sys, os, json
d = json.load(open(sys.argv[1]))
for c in d["cells"][0]["candidates"]:
    loc = c.split("|", 1)[0]
    f = loc.split("~", 1)[0].split(":", 1)[0].split("@", 1)[0].strip().rstrip("(").strip()
    p = os.path.join(sys.argv[2], f)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write("// placeholder for " + f + "\n")
PY
  verify_arm "$ST/$AN-off" "$RES" "$VER" 0 1
  verify_arm "$ST/$AN-on" "$RES" "$VER" 1 1
  verify_arm "$ST/$AN-on3" "$RES" "$VER" 1 3
  SAME=1
  for arm in on on3; do
    cmp -s "$ST/$AN-off/verified_findings.json" "$ST/$AN-$arm/verified_findings.json" || SAME=0
    cmp -s "$ST/$AN-off/refute-constraints.tsv" "$ST/$AN-$arm/refute-constraints.tsv" || SAME=0
  done
  if [ "$SAME" -eq 1 ] && [ -s "$ST/$AN-off/refute-constraints.tsv" ]; then
    ok "(a) $AN: verified_findings.json + refute-constraints.tsv byte-identical across OFF / ON / ON --jobs 3"
  else
    bad "(a) $AN: the three runs differ"
  fi
  rows_of "$TRUTH_1886" "$ST/$AN-off/verified_findings.json" > "$ST/$AN-off.rows"
  ROWS_SAME=1
  for arm in on on3; do
    rows_of "$TRUTH_1886" "$ST/$AN-$arm/verified_findings.json" > "$ST/$AN-$arm.rows"
    cmp -s "$ST/$AN-off.rows" "$ST/$AN-$arm.rows" || ROWS_SAME=0
  done
  if [ "$ROWS_SAME" -eq 1 ] && [ "$(grep -c . "$ST/$AN-off.rows")" = "37" ]; then
    ok "(b) $AN: token-mode HIT/MISS identical on all 37 truth rows across the three runs ($(grep -c 'HIT' "$ST/$AN-off.rows") HIT)"
  else
    bad "(b) $AN: per-row HIT/MISS differs between the arms"
  fi
  if [ "$AN" = "1886-notional-refute-fn" ]; then
    rows_of "$TRUTH_1886" "$ARCH/verified_findings.json" > "$ST/archived.rows"
    if cmp -s "$ST/archived.rows" "$ST/$AN-off.rows" && grep -q '^M-2	HIT$' "$ST/archived.rows" && grep -q '^M-10	HIT$' "$ST/archived.rows"; then
      ok "(b) $AN: the replay reproduces the archived scorecard row for row (M-2 and M-10 HIT)"
    else
      bad "(b) $AN: the replay does not reproduce the archived scorecard"
    fi
  fi
  OFF_FIRST="$(sessions "$ST/$AN-off.sessions" first)"
  ON_B="$(sessions "$ST/$AN-on.sessions" batch)"; ON_F="$(sessions "$ST/$AN-on.sessions" first)"
  J3_B="$(sessions "$ST/$AN-on3.sessions" batch)"; J3_F="$(sessions "$ST/$AN-on3.sessions" first)"
  check "$OFF_FIRST $((ON_B + ON_F)) $((J3_B + J3_F)) $ON_B" "29 18 18 7" \
    "(c) $AN: first-read sessions 29 -> 18 (7 batches + 11 individual), also under --jobs 3"
  check "$(python3 "$PLANNER" summary --results "$RES" | tail -1)" "first_read_sessions=18 of 29 (38% fewer)" \
    "(c) $AN: lib/refute-batch.py summary predicts the same 18 of 29"
  GRP="$(for g in 12 13 18; do
           gd="$(find "$ST/$AN-on/gates" -maxdepth 1 -name "${g}_*" | head -1)"
           printf '%s:%s:%s ' "$g" "$(cut -f1 "$gd/verdict.txt")" "$(cut -f1,3 "$gd/batch.txt" | tr '\t' '/')"
         done)"
  REC="$(for g in 12 13 18; do printf '%s:%s:' "$g" "$(awk -F'\t' -v n="$g" '$1==n {print $4}' "$VER")"; done)"
  GRP_V="$(printf '%s' "$GRP" | sed 's|:[0-9]*/3 |:|g')"
  B_IDS="$(printf '%s' "$GRP" | grep -o ':[0-9]*/3 ' | sort -u | grep -c .)"
  if [ "$GRP_V" = "$REC" ] && [ "$B_IDS" = "1" ]; then
    ok "(d) $AN: the 3-member unstakeAndExitPool group shares ONE batch and fans out to its recorded verdicts ($GRP)"
  else
    bad "(d) $AN: the unstakeAndExitPool group did not fan out to its recorded verdicts (got '$GRP', recorded '$REC')"
  fi
  if [ "$AN" = "1886-notional-refute-fn" ]; then
    check "$REC" "12:REFUTED:13:REAL:18:REFUTED:" "(d) $AN: the recorded group is the mixed REFUTED / REAL / REFUTED one"
  fi
done

note "--live, driven end to end through the replay stub (mock backend)"
AN="1886-notional-refute-fn"
( STUB_VERDICTS="$ST/$AN.tsv" bash "$0" --live --id notional --results "$ST/$AN.results.json" --repo "$ST/repo-$AN" \
    --truth "$TRUTH_1886" --work "$ST/live" --backend mock --agentis "$STUB" --jobs 2 > "$ST/live.out" 2>&1 )
LIVE_RC=$?
if [ "$LIVE_RC" -eq 0 ] && grep -q '^- per-row HIT/MISS: \*\*IDENTICAL\*\*' "$ST/live/ab-report.md" \
   && grep -q 'first-read sessions: control 29 -> treatment 18 (38% fewer)' "$ST/live/ab-report.md" \
   && grep -q '^- per-candidate verdicts: identical' "$ST/live/ab-report.md" \
   && grep -q '^- control   = DF_REFUTE_BATCH=0' "$ST/live/arms.txt"; then
  ok "--live on the dev twin writes ab-report.md: labels fixed first, rows IDENTICAL, 29 -> 18 first reads, verdicts identical"
else
  bad "--live did not produce the expected report (rc=$LIVE_RC)"; cat "$ST/live.out"
fi
( bash "$0" --live --id notional --results "$ST/$AN.results.json" --repo "$ST/repo-$AN" --truth "$TRUTH_1886" \
    --work "$ST/live" --backend mock --agentis "$STUB" > /dev/null 2>&1 ); check "$?" "2" "--live refuses to overwrite a measured arm (exit 2)"
HOLDOUT_ID="$(awk -F'\t' '!/^#/ && $5=="holdout" {print $1; exit}' "$CORPUS")"
( bash "$0" --live --id "$HOLDOUT_ID" --results "$ST/$AN.results.json" --repo "$ST/repo-$AN" --truth "$TRUTH_1886" \
    --work "$ST/live-h" --backend mock --agentis "$STUB" > "$ST/h.out" 2>&1 ); RC_H=$?
( bash "$0" --live --id not-a-corpus-row --results "$ST/$AN.results.json" --repo "$ST/repo-$AN" --truth "$TRUTH_1886" \
    --work "$ST/live-f" --backend mock --agentis "$STUB" > /dev/null 2>&1 ); RC_F=$?
if [ "$RC_H" = "2" ] && [ "$RC_F" = "2" ] && [ ! -e "$ST/live-h" ] && [ ! -e "$ST/live-f" ] && grep -q "role 'holdout'" "$ST/h.out"; then
  ok "--live refuses a held-out id ($HOLDOUT_ID) and an id outside corpus.tsv (exit 2, nothing run)"
else
  bad "--live did not refuse a held-out / unknown id (rc $RC_H / $RC_F)"
fi
( bash "$0" --reconstruct "$ST" --out "$ST/x.json" --verdicts "$ST/x.tsv" > /dev/null 2>&1 ); check "$?" "3" "--reconstruct on an unknown archive shape exits 3"

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS — batching is verdict-neutral on both real notional candidate sets and saves 11 of 29 first reads"
  exit 0
fi
note "FAIL — $FAILS assertion(s) failed"
exit 1
