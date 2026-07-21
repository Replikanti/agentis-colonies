#!/usr/bin/env bash
# deep-hunt-ab.sh — #1713 A/B measurement harness for the SEVERITY-FIRST DEEP-HUNT mode. It runs the
# zone-hunt pipeline (run-zone-hunt.sh) OVER THE SAME target TWICE — once breadth-only (baseline) and once
# with --deep-hunt (the value-custody stateful-invariant lens) — and scores both against ground truth, so the
# High-severity recall DELTA the deep lens buys is measured directly, ON vs OFF.
#
# This is a capability-frontier ATTEMPT measured by a bench PROXY (High-severity recall delta on scored
# contests), NOT a guaranteed jackpot: the real test is fresh live targets the bench cannot measure. The
# --self-test proves the MECHANISM end to end offline; --live measures a real contest.
#
# TWO modes:
#   --self-test (default; CI-safe, no network / LLM / forge): drive run-zone-hunt.sh over
#     fixtures/deep-hunt/ TWICE through one --agentis stub — once WITHOUT --deep-hunt, once WITH
#     --deep-hunt --invariant-fixture — and assert:
#       (a) the OFF verified_findings.json LACKS the invariant-sourced finding,
#       (b) the ON one CONTAINS it with source=invariant-hunt AND a bench-parseable `location`,
#       (c) score-match.py scores the ON run's extra High finding a HIT against fixtures/deep-hunt/truth.tsv
#           while the OFF run MISSES it — the ON-vs-OFF High-recall delta, proven offline.
#
#   --live --id <id> --code-dir <dir> --truth <truth.tsv> [--scope-hint <zone-dir>]: real measurement on a
#     SCRATCH COPY of one already-fetched contest's code dir in an ISOLATED --work dir (NEVER the live
#     corpus-bench run's work directory), restricted to a SINGLE value-custody zone via --scope-hint so it
#     does not contend for the whole subscription, --backend flat-cyborg. Prints High recall + matched /
#     unmatched-lead precision for OFF vs ON and the delta.
#
#     CAPACITY CONSTRAINT: the live measurement runs the real LLM/forge backend and owns a claude
#     subscription slot. Run it ONLY after the live corpus-bench run frees CPU/subscription capacity, OR on a
#     single isolated non-contending value-custody zone. All deterministic/CI paths use --backend mock.
#
# Usage: deep-hunt-ab.sh [--self-test] | [--live --id <id> --code-dir <dir> --truth <f> [--scope-hint <t>]
#                          [--work <dir>] [--backend <b>] [--agentis <bin>] [--min-overlap <N>]] [-h]
# Exit: 0 = self-test held / live measurement completed ; 1 = self-test regressed ; 2 = bad args ;
#       3 = missing prerequisite.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DF="$(cd "$HERE/../.." && pwd)"   # dark-factory/
ZONEHUNT="$DF/run-zone-hunt.sh"
SCOREMATCH="$HERE/score-match.py"
FIX="$HERE/fixtures/deep-hunt"

MODE="self-test"
ID="" ; CODE_DIR="" ; TRUTH="" ; SCOPE_HINT="" ; WORK="" ; BACKEND="flat-cyborg" ; AGENTIS="agentis" ; MINOV="2"

nv() { [ "$1" -ge 2 ] || { echo "deep-hunt-ab.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do case "$1" in
  --self-test)   MODE="self-test"; shift ;;
  --live)        MODE="live"; shift ;;
  --id)          nv "$#"; ID="$2"; shift 2 ;;
  --code-dir)    nv "$#"; CODE_DIR="$2"; shift 2 ;;
  --truth)       nv "$#"; TRUTH="$2"; shift 2 ;;
  --scope-hint)  nv "$#"; SCOPE_HINT="$2"; shift 2 ;;
  --work)        nv "$#"; WORK="$2"; shift 2 ;;
  --backend)     nv "$#"; BACKEND="$2"; shift 2 ;;
  --agentis)     nv "$#"; AGENTIS="$2"; shift 2 ;;
  --min-overlap) nv "$#"; MINOV="$2"; shift 2 ;;
  -h|--help)     awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
  *) echo "deep-hunt-ab.sh: unknown arg: $1" >&2; exit 2 ;;
esac; done

note() { echo "deep-hunt-ab.sh: $*"; }

# high_hit_of <truth.tsv> <verified_findings.json> <sev_id> -> prints HIT|MISS for that truth row.
high_hit_of() {
  python3 "$SCOREMATCH" "$1" "$2" --min-overlap "$MINOV" 2>/dev/null \
    | awk -F'\t' -v id="$3" '$1==id {print $2; found=1} END{ if(!found) print "MISS" }'
}

# high_recall_count <truth.tsv> <verified_findings.json> -> prints the count of High truth rows scored HIT.
# Used to compute the ON-vs-OFF High-recall delta Δ deterministically in the self-test (#1774). score-match's
# output is captured to a temp file (not piped) so the python reader takes truth + scorecard as file argv —
# same idiom as report_side, no scorecard text ever interpolated into the shell.
high_recall_count() {
  _hrc_scf="$(mktemp "${TMPDIR:-/tmp}/deep-hunt-ab-hrc.XXXXXX")"
  python3 "$SCOREMATCH" "$1" "$2" --min-overlap "$MINOV" > "$_hrc_scf" 2>/dev/null || true
  python3 - "$1" "$_hrc_scf" <<'PY'
import sys
truth, scf = sys.argv[1], sys.argv[2]
high = set()
for line in open(truth, encoding="utf-8", errors="ignore"):
    c = line.rstrip("\n").split("\t")
    if len(c) >= 5 and c[1] == "High":
        high.add(c[0])
n = 0
for line in open(scf, encoding="utf-8", errors="ignore"):
    c = line.rstrip("\n").split("\t")
    if len(c) >= 2 and c[0] in high and c[1] == "HIT":
        n += 1
print(n)
PY
  rm -f "$_hrc_scf"
}

# ==========================================================================================================
# --self-test (default): the offline, deterministic acceptance bar.
# ==========================================================================================================
if [ "$MODE" = "self-test" ]; then
  FAILS=0
  ok()  { echo "  [PASS] $*"; }
  bad() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

  command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
  command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
  [ -x "$ZONEHUNT" ] || { note "run-zone-hunt.sh not found / not executable: $ZONEHUNT" >&2; exit 3; }
  for f in foundry.toml zones.fixture.txt briefs.fixture.txt handler-fixture.t.sol agentis-stub.sh truth.tsv; do
    [ -f "$FIX/$f" ] || { note "fixture missing: $FIX/$f" >&2; exit 3; }
  done

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/deep-hunt-ab.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT

  # Throwaway Foundry target: the value-custody Vault + the non-custody Views helper zone, under git.
  REPO="$WORK/target"
  mkdir -p "$REPO"
  cp "$FIX/foundry.toml" "$REPO/foundry.toml"
  cp -R "$FIX/src" "$REPO/src"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email demo@example.invalid
  git -C "$REPO" config user.name "demo"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "deep-hunt fixture target"

  STUB="$WORK/agentis-stub"
  cp "$FIX/agentis-stub.sh" "$STUB"; chmod +x "$STUB"

  PASS_FIXTURE="scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted"

  # #1774: mirror the --live SHARED-breadth structure — run breadth once (NO --deep-hunt), clone it, then apply
  # ONLY the STAGE 4.5 lens over the clone. So ON is a superset of OFF by construction and Δ isolates the lens.
  run_breadth() {  # $1 = out dir — breadth-only baseline (the shared base for OFF and the ON clone).
    _out="$1"
    "$ZONEHUNT" --repo "$REPO" --out "$_out" --drop-dir "$_out/drop" --scope-hint src \
      --backend mock --agentis "$STUB" \
      --map-fixture "$FIX/zones.fixture.txt" --brief-fixture "$FIX/briefs.fixture.txt" \
      --pass-fixture "$PASS_FIXTURE" --in-scope "the whole in-scope program" \
      >"$_out.log" 2>&1
  }

  run_lens_only() {  # $1 = out dir (a CLONE of a breadth --out) — apply ONLY the deep-hunt STAGE 4.5 lens.
    _out="$1"
    "$ZONEHUNT" --repo "$REPO" --out "$_out" --deep-hunt --deep-hunt-only \
      --invariant-fixture "$FIX/handler-fixture.t.sol" \
      --backend mock --agentis "$STUB" \
      >"$_out.log" 2>&1
  }

  OUT_OFF="$WORK/off"
  OUT_ON="$WORK/on"

  note "running the shared breadth baseline (deep-hunt OFF) ..."
  run_breadth "$OUT_OFF"; RC_OFF=$?
  [ "$RC_OFF" -eq 0 ] && ok "OFF (shared breadth) run exits 0" || { bad "OFF run exited $RC_OFF"; sed 's/^/      /' "$OUT_OFF.log" | tail -30 >&2; }

  note "cloning the shared breadth base OFF -> ON, then applying ONLY the deep-hunt lens over the clone ..."
  rm -rf "$OUT_ON"; cp -R "$OUT_OFF" "$OUT_ON"
  run_lens_only "$OUT_ON"; RC_ON=$?
  [ "$RC_ON" -eq 0 ] && ok "ON (breadth clone + deep-hunt lens) run exits 0" || { bad "ON run exited $RC_ON"; sed 's/^/      /' "$OUT_ON.log" | tail -30 >&2; }

  VJ_OFF="$OUT_OFF/verify/verified_findings.json"
  VJ_ON="$OUT_ON/verify/verified_findings.json"
  [ -f "$VJ_OFF" ] || bad "OFF verified_findings.json missing"
  [ -f "$VJ_ON" ]  || bad "ON verified_findings.json missing"

  # (a) OFF LACKS the invariant-sourced finding.
  if [ -f "$VJ_OFF" ] && python3 - "$VJ_OFF" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = d.get("verified", []) if isinstance(d, dict) else []
assert not any((f or {}).get("source") == "invariant-hunt" for f in v), "OFF run carries an invariant-hunt finding"
PY
  then ok "(a) the breadth-only OFF run has NO source=invariant-hunt finding"
  else bad "(a) the OFF run unexpectedly carries an invariant-hunt finding"
  fi

  # (b) ON CONTAINS it with source=invariant-hunt AND a bench-parseable location.
  if [ -f "$VJ_ON" ] && python3 - "$VJ_ON" <<'PY'
import sys, os, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = d.get("verified", []) if isinstance(d, dict) else []
inv = [f for f in v if (f or {}).get("source") == "invariant-hunt"]
assert inv, "ON run has no source=invariant-hunt finding"
f = inv[0]
loc = (f.get("location") or "")
assert ":" in loc, "invariant finding location is not bench-parseable (no file:fn): %r" % loc
fpath, fn = loc.split(":", 1)
assert fpath.endswith(".sol"), "location file part is not a .sol: %r" % loc
assert fn and not fn.isdigit(), "location has no function name: %r" % loc
assert f.get("severity") == "High", "invariant finding is not High severity: %r" % f.get("severity")
PY
  then ok "(b) the ON run CONTAINS a source=invariant-hunt High finding with a bench-parseable file:fn location"
  else bad "(b) the ON run is missing a well-formed invariant-hunt finding"
  fi

  # (c) score-match: ON scores the High row S-D1 a HIT; OFF MISSES it (the ON-vs-OFF High-recall delta).
  HIT_OFF="$(high_hit_of "$FIX/truth.tsv" "$VJ_OFF" S-D1)"
  HIT_ON="$(high_hit_of "$FIX/truth.tsv" "$VJ_ON" S-D1)"
  note "  score-match High row S-D1: OFF=$HIT_OFF  ON=$HIT_ON"
  if [ "$HIT_OFF" = "MISS" ] && [ "$HIT_ON" = "HIT" ]; then
    ok "(c) deep-hunt turns the High S-D1 truth row from MISS (breadth) to HIT (deep) — the recall delta holds"
  else
    bad "(c) expected OFF=MISS ON=HIT for the High truth row, got OFF=$HIT_OFF ON=$HIT_ON"
  fi

  # (d) SUPERSET: ON verified[] locations ⊇ OFF verified[] locations — the shared-breadth union invariant, proven
  #     directly. Because ON is a clone of OFF's breadth base plus the append-only lens, it can never LOSE a row.
  if [ -f "$VJ_OFF" ] && [ -f "$VJ_ON" ] && python3 - "$VJ_OFF" "$VJ_ON" <<'PY'
import sys, json
def locs(p):
    d = json.load(open(p, encoding="utf-8"))
    v = d.get("verified", []) if isinstance(d, dict) else []
    return set((f or {}).get("location", "") for f in v)
off, on = locs(sys.argv[1]), locs(sys.argv[2])
assert off <= on, "ON is not a superset of OFF: OFF-only locations = %r" % sorted(off - on)
PY
  then ok "(d) ON verified[] locations ⊇ OFF verified[] locations (the shared-breadth union invariant holds)"
  else bad "(d) ON is NOT a superset of OFF — the shared-breadth union invariant regressed"
  fi

  # (e) Δ = ON − OFF High recall = +1 on the FINDING fixture: the lens added exactly the S-D1 truth row.
  DOFF="$(high_recall_count "$FIX/truth.tsv" "$VJ_OFF")"
  DON="$(high_recall_count "$FIX/truth.tsv" "$VJ_ON")"
  DELTA=$((DON - DOFF))
  note "  High recall: OFF=$DOFF ON=$DON Δ=$DELTA"
  if [ "$DELTA" -eq 1 ]; then
    ok "(e) Δ = ON − OFF High recall = +1 (the deep-hunt lens added exactly one truth-row hit; Δ ≥ 0 holds)"
  else
    bad "(e) expected Δ=+1 on the FINDING fixture, got Δ=$DELTA (OFF=$DOFF ON=$DON)"
  fi

  # (f) Δ = 0 when the lens merges NOTHING: a SECOND breadth clone whose lens-only call sees DEEP_HUNT_VERDICT=CLEAN
  #     emits an INVARIANT|...|CLEAN verdict, so STAGE 4.5's adapter merges 0 (models the live yieldoor "lens ran
  #     but merged 0" evidence). ON2 must then equal OFF2 recall, carry NO invariant-hunt finding, and Δ = 0 —
  #     the whole point of sharing one breadth pass: Δ can never go negative.
  OUT_OFF2="$WORK/off2"
  OUT_ON2="$WORK/on2"
  note "running a second breadth baseline + a CLEAN (merges-0) lens to pin Δ = 0 ..."
  run_breadth "$OUT_OFF2"; RC_OFF2=$?
  [ "$RC_OFF2" -eq 0 ] || { bad "OFF2 run exited $RC_OFF2"; sed 's/^/      /' "$OUT_OFF2.log" | tail -30 >&2; }
  rm -rf "$OUT_ON2"; cp -R "$OUT_OFF2" "$OUT_ON2"
  ( export DEEP_HUNT_VERDICT=CLEAN; run_lens_only "$OUT_ON2" ); RC_ON2=$?
  [ "$RC_ON2" -eq 0 ] || { bad "ON2 (CLEAN lens) run exited $RC_ON2"; sed 's/^/      /' "$OUT_ON2.log" | tail -30 >&2; }
  VJ_OFF2="$OUT_OFF2/verify/verified_findings.json"
  VJ_ON2="$OUT_ON2/verify/verified_findings.json"

  if [ -f "$VJ_ON2" ] && python3 - "$VJ_ON2" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = d.get("verified", []) if isinstance(d, dict) else []
assert not any((f or {}).get("source") == "invariant-hunt" for f in v), "ON2 carries an invariant-hunt finding despite the CLEAN verdict"
PY
  then ok "(f1) the CLEAN lens merged 0 findings — ON2 has NO source=invariant-hunt finding"
  else bad "(f1) ON2 unexpectedly carries an invariant-hunt finding under DEEP_HUNT_VERDICT=CLEAN"
  fi

  D2OFF="$(high_recall_count "$FIX/truth.tsv" "$VJ_OFF2")"
  D2ON="$(high_recall_count "$FIX/truth.tsv" "$VJ_ON2")"
  DELTA2=$((D2ON - D2OFF))
  note "  CLEAN-lens High recall: OFF2=$D2OFF ON2=$D2ON Δ=$DELTA2"
  if [ "$D2ON" -eq "$D2OFF" ] && [ "$DELTA2" -eq 0 ]; then
    ok "(f2) ON2 == OFF2 High recall and Δ = 0 — a lens that merges 0 never drives Δ negative"
  else
    bad "(f2) expected ON2==OFF2 and Δ=0 under the CLEAN lens, got OFF2=$D2OFF ON2=$D2ON Δ=$DELTA2"
  fi

  echo
  if [ "$FAILS" -eq 0 ]; then
    note "PASS — shared breadth: ON ⊇ OFF, Δ=+1 on the FINDING fixture, Δ=0 when the lens merges 0 (Δ ≥ 0 by construction)"
    exit 0
  fi
  note "FAIL — $FAILS assertion(s) regressed" >&2
  exit 1
fi

# ==========================================================================================================
# --live: real ON-vs-OFF measurement on an ISOLATED scratch copy of one already-fetched contest zone.
# NEVER run this while the live corpus-bench run owns CPU/subscription capacity (see the header constraint).
# ==========================================================================================================
if [ "$MODE" = "live" ]; then
  command -v python3 >/dev/null 2>&1 || { echo "deep-hunt-ab.sh: python3 not installed" >&2; exit 3; }
  [ -x "$ZONEHUNT" ] || { echo "deep-hunt-ab.sh: run-zone-hunt.sh not found/executable: $ZONEHUNT" >&2; exit 3; }
  [ -n "$ID" ] || { echo "deep-hunt-ab.sh: --live requires --id <id>" >&2; exit 2; }
  [ -n "$CODE_DIR" ] && [ -d "$CODE_DIR" ] || { echo "deep-hunt-ab.sh: --live requires --code-dir <already-fetched contest code dir>" >&2; exit 2; }
  [ -n "$TRUTH" ] && [ -f "$TRUTH" ] || { echo "deep-hunt-ab.sh: --live requires --truth <truth.tsv>" >&2; exit 2; }
  [ -n "$WORK" ] || WORK="$PWD/deep-hunt-ab-work"
  mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"

  # SCRATCH COPY: never touch the source contest dir (which may belong to the live corpus-bench run).
  SCRATCH="$WORK/$ID/code"
  rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
  cp -R "$CODE_DIR/." "$SCRATCH/"
  note "live A/B on an isolated scratch copy: $SCRATCH (scope-hint: ${SCOPE_HINT:-<none>}, backend: $BACKEND)"

  # #1774: SHARE one breadth pass across OFF and ON so ON ⊇ OFF and Δ isolates the lens (not breadth run-to-run
  # noise). Breadth runs ONCE (NO --deep-hunt) -> OFF; ON is a CLONE of that breadth base with ONLY the deep-hunt
  # STAGE 4.5 lens applied over it (--deep-hunt-only). ON can therefore only ADD the lens's findings.
  run_breadth() {  # $1 = out dir — the single shared breadth pass (NO --deep-hunt).
    _out="$1"
    "$ZONEHUNT" --repo "$SCRATCH" --out "$_out" --backend "$BACKEND" --agentis "$AGENTIS" \
      ${SCOPE_HINT:+--scope-hint "$SCOPE_HINT"} \
      || note "  [$ID] run-zone-hunt.sh (breadth) exited non-zero; scoring whatever it produced"
  }

  run_lens_only() {  # $1 = out dir (a CLONE of the breadth --out) — apply ONLY the deep-hunt STAGE 4.5 lens.
    _out="$1"
    "$ZONEHUNT" --repo "$SCRATCH" --out "$_out" --deep-hunt --deep-hunt-only \
      --backend "$BACKEND" --agentis "$AGENTIS" \
      || note "  [$ID] run-zone-hunt.sh (deep-hunt-only) exited non-zero; scoring whatever it produced"
  }

  OUT_OFF="$WORK/$ID/off"
  OUT_ON="$WORK/$ID/on"
  note "[$ID] breadth (the shared baseline) ..."; run_breadth "$OUT_OFF"
  if [ -f "$OUT_OFF/verify/verified_findings.json" ] && [ -f "$OUT_OFF/map/zones.json" ]; then
    note "[$ID] cloning the breadth base OFF -> ON, then applying ONLY the deep-hunt lens ..."
    rm -rf "$OUT_ON"; cp -R "$OUT_OFF" "$OUT_ON"
    run_lens_only "$OUT_ON"
    AB_ON=1
  else
    note "[$ID] breadth produced no verify/verified_findings.json + map/zones.json — skipping ON honestly (Δ undefined, NOT a false negative)"
    AB_ON=0
  fi

  report_side() {  # $1 = out dir, $2 = label
    _vj="$1/verify/verified_findings.json"
    if [ ! -f "$_vj" ]; then note "  [$ID] $2: no verified_findings.json produced"; return; fi
    _scf="$1.scorecard.txt"
    python3 "$SCOREMATCH" "$TRUTH" "$_vj" --min-overlap "$MINOV" > "$_scf" 2>/dev/null || true
    # Cross the score output (sev_id\tHIT|MISS + a LEADS trailer) with the truth's High rows in ONE clean
    # python call over two files, so no scorecard text is ever interpolated into shell/heredoc.
    python3 - "$TRUTH" "$_scf" "$ID" "$2" <<'PY'
import sys
truth, scf, cid, label = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
high = set()
for line in open(truth, encoding="utf-8", errors="ignore"):
    c = line.rstrip("\n").split("\t")
    if len(c) >= 5 and c[1] == "High":
        high.add(c[0])
hits = 0
verified_n = matched = 0
for line in open(scf, encoding="utf-8", errors="ignore"):
    c = line.rstrip("\n").split("\t")
    if c and c[0] == "LEADS" and len(c) >= 3:
        try:
            verified_n, matched = int(c[1]), int(c[2])
        except ValueError:
            pass
        continue
    if len(c) >= 2 and c[0] in high and c[1] == "HIT":
        hits += 1
print("deep-hunt-ab.sh:   [%s] %s: High recall %d/%d, verified-leads %d (matched %d, unmatched %d)"
      % (cid, label, hits, len(high), verified_n, matched, verified_n - matched))
PY
  }

  note "================ DEEP-HUNT A/B [$ID] ================"
  report_side "$OUT_OFF" "OFF (breadth)"
  if [ "$AB_ON" -eq 1 ]; then
    report_side "$OUT_ON" "ON  (breadth + deep-hunt lens)"
    # Δ = ON − OFF High recall. ON is a superset CLONE of OFF's breadth base plus the append-only lens, so
    # Δ ≥ 0 BY CONSTRUCTION — it equals the count of truth rows the deep-hunt lens ADDED on the shared breadth.
    # report_side already wrote each side's scorecard to <out>.scorecard.txt; cross them in one clean python call.
    python3 - "$TRUTH" "$OUT_OFF.scorecard.txt" "$OUT_ON.scorecard.txt" "$ID" <<'PY'
import sys
truth, scf_off, scf_on, cid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
high = set()
for line in open(truth, encoding="utf-8", errors="ignore"):
    c = line.rstrip("\n").split("\t")
    if len(c) >= 5 and c[1] == "High":
        high.add(c[0])
def recall(path):
    n = 0
    try:
        fh = open(path, encoding="utf-8", errors="ignore")
    except OSError:
        return 0
    for line in fh:
        c = line.rstrip("\n").split("\t")
        if len(c) >= 2 and c[0] in high and c[1] == "HIT":
            n += 1
    return n
off, on = recall(scf_off), recall(scf_on)
print("deep-hunt-ab.sh:   [%s] Δ = ON − OFF High recall = %d − %d = %+d (≥ 0 by construction: ON ⊇ OFF)"
      % (cid, on, off, on - off))
PY
  else
    note "  [$ID] ON skipped — Δ not computed (the shared breadth base was unavailable)"
  fi
  note "the ON-vs-OFF High recall delta is the deep-hunt lens's measured contribution on this zone (Δ ≥ 0 by construction — a bench proxy, not a jackpot)."
  exit 0
fi

echo "deep-hunt-ab.sh: unknown mode: $MODE" >&2
exit 2
