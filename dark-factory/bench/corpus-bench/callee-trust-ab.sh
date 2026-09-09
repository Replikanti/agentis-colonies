#!/usr/bin/env bash
# callee-trust-ab.sh — #2157 (milestone D3, epic #2130) A/B measurement harness for the CALLEE-TRUST /
# vector-hunt rare-recall contribution. It runs the zone-hunt pipeline (run-zone-hunt.sh) OVER THE SAME target
# TWICE — a CONTROL arm (CALLEE_TRUST=0, no --vector-hunt: the pre-D1/D2 pipeline) and a TREATMENT arm
# (CALLEE_TRUST=1, --vector-hunt: D1 surfaces the attacker-controlled-callee vector and D2 forge-verifies it) —
# and scores both against ground truth, so the RARE-tier recall DELTA the two milestones buy is measured
# directly, ON vs OFF.
#
# HONEST MODEL ROUTING (the D2 live-gate finding): Fable 5.1 refuses weaponized-PoC authoring under its
# [cyber] safeguard, so NO arm is single-model end to end. The ANALYSIS/ENUMERATION stages (map-zones /
# gen-briefs / run-discovery+hunter.ag / vector enumeration / run-refute) run on Fable 5.1 with the
# refusal-fallback + model-fallback killswitches on; the PoC-AUTHORING / forge-verify stages (run-poc.sh,
# run-vector-hunt.sh's per-vector PoC) run on Opus 4.8. The HEADLINE metric is therefore rare(1-2)
# GENERATION-recall (via generation-recall.sh, scored from pre-refute candidates — D1's clean, pure-Fable
# number); the SECONDARY is rare(1-2) VERIFIED-recall (via run-corpus-bench.sh --score — D1+D2 end to end,
# "Fable analysis + Opus PoC-verify"). model-attribution.py over the persisted transcripts PROVES the per-stage
# split held; a Fable stage that silently fell back to Opus voids the D1 capability claim.
#
# This is a capability-frontier ATTEMPT measured by a bench PROXY (rare-tier recall delta on scored contests),
# NOT a guaranteed jackpot: the real test is fresh live targets the bench cannot measure. The --self-test
# proves the MECHANISM end to end offline; --live measures a real contest.
#
# TWO modes:
#   --self-test (default; CI-safe, no network / LLM / forge): drive run-zone-hunt.sh over
#     fixtures/callee-trust-ab/ TWICE through one --agentis stub — CONTROL (CALLEE_TRUST=0, no --vector-hunt)
#     and TREATMENT (CALLEE_TRUST=1, --vector-hunt, vector-hunt PoC via the shared poc-runner-stub.sh) — and
#     assert:
#       (a) the CONTROL cell log LACKS the D1 CALLEE-VECTOR directive candidate AND its verified_findings.json
#           LACKS the source=vector-hunt finding,
#       (b) the TREATMENT cell log CARRIES the CALLEE-VECTOR candidate AND its verified_findings.json CONTAINS
#           the source=vector-hunt finding with a bench-parseable `location`,
#       (c) score-match.py scores the TREATMENT's extra RARE finding a HIT the CONTROL MISSES (the ON-vs-OFF
#           rare-recall delta, proven offline),
#       (d) the run labels control / treatment are FIXED (below, before any run) — never assigned after the
#           numbers are seen.
#
#   --live --id <id> --code-dir <dir> --truth <truth.tsv> [--scope-hint <zone-dir>]: real rare-tier measurement
#     on a SCRATCH COPY of one already-fetched contest's code dir in an ISOLATED --work dir (NEVER the live
#     corpus-bench run's work directory), --backend flat-cyborg. Prints rare recall for CONTROL vs TREATMENT and
#     the delta. RUN THE ANALYSIS STAGES with CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1 +
#     CLAUDE_CODE_NO_MODEL_FALLBACK=1 (Fable) and prove it afterwards with model-attribution.py; the headline
#     rare-GENERATION-recall comes from generation-recall.sh, the secondary rare-VERIFIED-recall from
#     run-corpus-bench.sh --score. This harness measures verified-recall; pair it with generation-recall.sh for
#     the headline.
#
#     CAPACITY CONSTRAINT: the live measurement runs the real LLM/forge backend and owns a claude subscription
#     slot. Run it ONLY after the live corpus-bench run frees CPU/subscription capacity, OR on a single isolated
#     non-contending value-custody zone. All deterministic/CI paths use --backend mock.
#
#     TRANSFER GATE: the gain counts ONLY if the rare-recall Δ is positive on the pre-registered MEASUREMENT
#     contest AND independently positive on a DIFFERENT pre-registered TRANSFER contest (see
#     refute-corpus-coverage.sh for picking two GO contests whose rare(1-2) GT class intersects the
#     attacker-controlled-callee class set). A gain that vanishes on transfer = reachability, not capability.
#
# Usage: callee-trust-ab.sh [--self-test] | [--live --id <id> --code-dir <dir> --truth <f> [--scope-hint <t>]
#                            [--work <dir>] [--backend <b>] [--agentis <bin>] [--min-overlap <N>]
#                            [--vector-hunt-max-vectors <N>]] [-h]
# Exit: 0 = self-test held / live measurement completed ; 1 = self-test regressed ; 2 = bad args ;
#       3 = missing prerequisite.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DF="$(cd "$HERE/../.." && pwd)"   # dark-factory/
ZONEHUNT="$DF/run-zone-hunt.sh"
SCOREMATCH="$HERE/score-match.py"
FIX="$HERE/fixtures/callee-trust-ab"
# The vector-hunt PoC runner + its fixture live with the D2 demo (reused UNCHANGED, never re-authored here).
POC_RUNNER="$DF/fixtures/vector-hunt/poc-runner-stub.sh"

# (d) The A/B labels are FIXED here, before any run — never assigned after the numbers are seen.
LABEL_CONTROL="control"
LABEL_TREATMENT="treatment"

MODE="self-test"
ID="" ; CODE_DIR="" ; TRUTH="" ; SCOPE_HINT="" ; WORK="" ; BACKEND="flat-cyborg" ; AGENTIS="agentis" ; MINOV="2"
VEC_MAX="6"  # --vector-hunt-max-vectors forwarded to the TREATMENT arm's STAGE 4.6 (default matches the engine)

nv() { [ "$1" -ge 2 ] || { echo "callee-trust-ab.sh: missing value for the preceding flag" >&2; exit 2; }; }
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
  --vector-hunt-max-vectors) nv "$#"; VEC_MAX="$2"; shift 2 ;;
  -h|--help)     awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
  *) echo "callee-trust-ab.sh: unknown arg: $1" >&2; exit 2 ;;
esac; done

note() { echo "callee-trust-ab.sh: $*"; }

# rare_hit_of <truth.tsv> <verified_findings.json> <sev_id> -> prints HIT|MISS for that truth row.
rare_hit_of() {
  python3 "$SCOREMATCH" "$1" "$2" --min-overlap "$MINOV" 2>/dev/null \
    | awk -F'\t' -v id="$3" '$1==id {print $2; found=1} END{ if(!found) print "MISS" }'
}

# rare_recall_count <truth.tsv> <verified_findings.json> -> prints the count of RARE (Found-by 1-2) truth rows
# scored HIT. RARE is the D3 headline stratum (col 3 of extract-gt.sh's truth.tsv, the watson "Found by" count).
# score-match's output is captured to a temp file (not piped) so the python reader takes truth + scorecard as
# file argv — no scorecard text ever interpolated into the shell (same idiom as deep-hunt-ab.sh).
rare_recall_count() {
  _rrc_scf="$(mktemp "${TMPDIR:-/tmp}/callee-trust-ab-rrc.XXXXXX")"
  python3 "$SCOREMATCH" "$1" "$2" --min-overlap "$MINOV" > "$_rrc_scf" 2>/dev/null || true
  python3 - "$1" "$_rrc_scf" <<'PY'
import sys
truth, scf = sys.argv[1], sys.argv[2]
rare = set()
for line in open(truth, encoding="utf-8", errors="ignore"):
    c = line.rstrip("\n").split("\t")
    if len(c) >= 5:
        try:
            found_by = int(c[2])
        except ValueError:
            continue
        if 1 <= found_by <= 2:
            rare.add(c[0])
n = 0
for line in open(scf, encoding="utf-8", errors="ignore"):
    c = line.rstrip("\n").split("\t")
    if len(c) >= 2 and c[0] in rare and c[1] == "HIT":
        n += 1
print(n)
PY
  rm -f "$_rrc_scf"
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
  [ -x "$POC_RUNNER" ] || { note "vector-hunt poc-runner-stub not found / not executable: $POC_RUNNER" >&2; exit 3; }
  for f in foundry.toml zones.fixture.txt briefs.fixture.txt agentis-stub.sh truth.tsv src/Vault.sol; do
    [ -f "$FIX/$f" ] || { note "fixture missing: $FIX/$f" >&2; exit 3; }
  done

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/callee-trust-ab.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT

  # Throwaway Foundry target: the settable-oracle value-custody Vault, under git.
  REPO="$WORK/target"
  mkdir -p "$REPO"
  cp "$FIX/foundry.toml" "$REPO/foundry.toml"
  cp -R "$FIX/src" "$REPO/src"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email demo@example.invalid
  git -C "$REPO" config user.name "demo"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "callee-trust A/B fixture target"

  STUB="$WORK/agentis-stub"
  cp "$FIX/agentis-stub.sh" "$STUB"; chmod +x "$STUB"

  PASS_FIXTURE="scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted"

  # run_arm <out-dir> <callee-trust 0|1> <vector-hunt 0|1>: one run-zone-hunt.sh breadth pass over the SAME
  # fixture. CALLEE_TRUST toggles the D1 directive in the stub hunter; --vector-hunt turns on STAGE 4.6, whose
  # per-vector PoC is driven by the shared offline poc-runner-stub.sh through the VECTOR_HUNT_POC_RUNNER seam.
  # The forge-slot pool is isolated per arm so the self-test never touches the host-wide pool a live hunt shares.
  run_arm() {
    _out="$1"; _ct="$2"; _vh="$3"
    _vh_args=""
    [ "$_vh" = "1" ] && _vh_args="--vector-hunt --vector-hunt-max-vectors $VEC_MAX"
    # shellcheck disable=SC2086  # $_vh_args is an intentional word-split flag pair (empty on the control arm)
    CALLEE_TRUST="$_ct" \
    VECTOR_HUNT_POC_RUNNER="$POC_RUNNER" \
    FORGE_SLOTS_DIR="$_out.forge-slots" \
      "$ZONEHUNT" --repo "$REPO" --out "$_out" --drop-dir "$_out/drop" --scope-hint src \
        --backend mock --agentis "$STUB" \
        --map-fixture "$FIX/zones.fixture.txt" --brief-fixture "$FIX/briefs.fixture.txt" \
        --pass-fixture "$PASS_FIXTURE" --in-scope "the whole in-scope program" \
        $_vh_args >"$_out.log" 2>&1
  }

  OUT_CTRL="$WORK/$LABEL_CONTROL"
  OUT_TREAT="$WORK/$LABEL_TREATMENT"

  note "running the CONTROL arm (CALLEE_TRUST=0, no --vector-hunt = the pre-D1/D2 pipeline) ..."
  run_arm "$OUT_CTRL" 0 0; RC_CTRL=$?
  [ "$RC_CTRL" -eq 0 ] && ok "control run exits 0" || { bad "control run exited $RC_CTRL"; sed 's/^/      /' "$OUT_CTRL.log" | tail -30 >&2; }

  note "running the TREATMENT arm (CALLEE_TRUST=1, --vector-hunt = D1 surfaces the vector, D2 forge-verifies it) ..."
  run_arm "$OUT_TREAT" 1 1; RC_TREAT=$?
  [ "$RC_TREAT" -eq 0 ] && ok "treatment run exits 0" || { bad "treatment run exited $RC_TREAT"; sed 's/^/      /' "$OUT_TREAT.log" | tail -30 >&2; }

  VJ_CTRL="$OUT_CTRL/verify/verified_findings.json"
  VJ_TREAT="$OUT_TREAT/verify/verified_findings.json"
  [ -f "$VJ_CTRL" ]  || bad "control verified_findings.json missing"
  [ -f "$VJ_TREAT" ] || bad "treatment verified_findings.json missing"

  # (a1) the CONTROL cell log lacks the D1 CALLEE-VECTOR directive candidate (a `^CALLEE-VECTOR|` DATA line, not
  #      a comment): CALLEE_TRUST=0 suppressed the directive, so nothing seeds STAGE 4.6.
  if grep -rhE '^CALLEE-VECTOR\|' "$OUT_CTRL"/discovery/*/run/ >/dev/null 2>&1; then
    bad "(a1) the control cell log carries a CALLEE-VECTOR| candidate — CALLEE_TRUST=0 did not suppress the directive"
  else
    ok "(a1) the control cell log carries NO CALLEE-VECTOR| candidate (CALLEE_TRUST=0 suppressed the D1 directive)"
  fi

  # (a2) the CONTROL verified_findings.json has NO source=vector-hunt finding.
  if [ -f "$VJ_CTRL" ] && python3 - "$VJ_CTRL" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = d.get("verified", []) if isinstance(d, dict) else []
assert not any((f or {}).get("source") == "vector-hunt" for f in v), "control run carries a vector-hunt finding"
PY
  then ok "(a2) the control run has NO source=vector-hunt finding (no --vector-hunt, no D1 candidate to harvest)"
  else bad "(a2) the control run unexpectedly carries a source=vector-hunt finding"
  fi

  # (b1) the TREATMENT cell log carries the D1 CALLEE-VECTOR directive candidate.
  if grep -rhE '^CALLEE-VECTOR\|executeDeposit\|' "$OUT_TREAT"/discovery/*/run/ >/dev/null 2>&1; then
    ok "(b1) the treatment cell log carries the CALLEE-VECTOR|executeDeposit candidate (CALLEE_TRUST=1 fired the D1 directive)"
  else
    bad "(b1) the treatment cell log is missing the CALLEE-VECTOR|executeDeposit candidate — D1 did not fire under CALLEE_TRUST=1"
  fi

  # (b2) the TREATMENT verified_findings.json CONTAINS the source=vector-hunt finding with a bench-parseable location.
  if [ -f "$VJ_TREAT" ] && python3 - "$VJ_TREAT" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = d.get("verified", []) if isinstance(d, dict) else []
vh = [f for f in v if (f or {}).get("source") == "vector-hunt"]
assert vh, "treatment run has no source=vector-hunt finding"
f = vh[0]
loc = (f.get("location") or "")
assert ":" in loc, "vector-hunt finding location is not bench-parseable (no file:fn): %r" % loc
fpath, fn = loc.rsplit(":", 1)
assert fpath.endswith(".sol"), "location file part is not a .sol: %r" % loc
assert fn and not fn.isdigit(), "location has no function name: %r" % loc
assert f.get("verdict") == "FINDING", "vector-hunt finding is not a FINDING: %r" % f.get("verdict")
PY
  then ok "(b2) the treatment run CONTAINS a source=vector-hunt FINDING with a bench-parseable file:fn location"
  else bad "(b2) the treatment run is missing a well-formed source=vector-hunt finding"
  fi

  # (c) score-match: the RARE truth row S-CT1 is a HIT in TREATMENT and a MISS in CONTROL (the rare-recall Δ).
  HIT_CTRL="$(rare_hit_of "$FIX/truth.tsv" "$VJ_CTRL" S-CT1)"
  HIT_TREAT="$(rare_hit_of "$FIX/truth.tsv" "$VJ_TREAT" S-CT1)"
  note "  score-match rare row S-CT1: $LABEL_CONTROL=$HIT_CTRL  $LABEL_TREATMENT=$HIT_TREAT"
  if [ "$HIT_CTRL" = "MISS" ] && [ "$HIT_TREAT" = "HIT" ]; then
    ok "(c) the rare S-CT1 truth row is MISS in control, HIT in treatment — the rare-recall delta holds"
  else
    bad "(c) expected control=MISS treatment=HIT for the rare truth row, got control=$HIT_CTRL treatment=$HIT_TREAT"
  fi

  # (c2) Δ = TREATMENT − CONTROL rare recall = +1: D1+D2 added exactly the one rare truth-row hit.
  RCTRL="$(rare_recall_count "$FIX/truth.tsv" "$VJ_CTRL")"
  RTREAT="$(rare_recall_count "$FIX/truth.tsv" "$VJ_TREAT")"
  DELTA=$((RTREAT - RCTRL))
  note "  rare recall: $LABEL_CONTROL=$RCTRL $LABEL_TREATMENT=$RTREAT Δ=$DELTA"
  if [ "$DELTA" -eq 1 ]; then
    ok "(c2) Δ = treatment − control rare recall = +1 (D1+D2 added exactly one rare truth-row hit)"
  else
    bad "(c2) expected Δ=+1 on the fixture, got Δ=$DELTA (control=$RCTRL treatment=$RTREAT)"
  fi

  # (d) the labels were fixed BEFORE any run — assert they are the constants defined at the top, not derived
  #     from which arm scored higher (the #1887-template discipline: arm mapping fixed before the numbers).
  if [ "$LABEL_CONTROL" = "control" ] && [ "$LABEL_TREATMENT" = "treatment" ]; then
    ok "(d) the run labels control/treatment are FIXED constants (assigned before scoring, never after the numbers)"
  else
    bad "(d) the run labels are not the fixed control/treatment constants"
  fi

  echo
  if [ "$FAILS" -eq 0 ]; then
    note "PASS — CONTROL (CALLEE_TRUST=0, no vector-hunt) misses the rare vector; TREATMENT (CALLEE_TRUST=1, --vector-hunt) catches it; rare-recall Δ=+1 offline"
    exit 0
  fi
  note "FAIL — $FAILS assertion(s) regressed" >&2
  exit 1
fi

# ==========================================================================================================
# --live: real CONTROL-vs-TREATMENT rare-recall measurement on an ISOLATED scratch copy of one contest.
# NEVER run this while the live corpus-bench run owns CPU/subscription capacity (see the header constraint).
# ==========================================================================================================
if [ "$MODE" = "live" ]; then
  command -v python3 >/dev/null 2>&1 || { echo "callee-trust-ab.sh: python3 not installed" >&2; exit 3; }
  [ -x "$ZONEHUNT" ] || { echo "callee-trust-ab.sh: run-zone-hunt.sh not found/executable: $ZONEHUNT" >&2; exit 3; }
  [ -n "$ID" ] || { echo "callee-trust-ab.sh: --live requires --id <id>" >&2; exit 2; }
  [ -n "$CODE_DIR" ] && [ -d "$CODE_DIR" ] || { echo "callee-trust-ab.sh: --live requires --code-dir <already-fetched contest code dir>" >&2; exit 2; }
  [ -n "$TRUTH" ] && [ -f "$TRUTH" ] || { echo "callee-trust-ab.sh: --live requires --truth <truth.tsv>" >&2; exit 2; }
  [ -n "$WORK" ] || WORK="$PWD/callee-trust-ab-work"
  mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"

  # SCRATCH COPY: never touch the source contest dir (which may belong to the live corpus-bench run).
  SCRATCH="$WORK/$ID/code"
  rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
  cp -R "$CODE_DIR/." "$SCRATCH/"
  note "live A/B on an isolated scratch copy: $SCRATCH (scope-hint: ${SCOPE_HINT:-<none>}, backend: $BACKEND)"
  note "REMINDER: run the analysis stages with CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1 + CLAUDE_CODE_NO_MODEL_FALLBACK=1 (Fable) and prove per-stage purity afterwards with model-attribution.py; this harness measures VERIFIED recall — pair it with generation-recall.sh for the headline generation number."

  # run_live_arm <out-dir> <callee-trust 0|1> <vector-hunt 0|1>: the SAME target under each arm's toggles.
  run_live_arm() {
    _out="$1"; _ct="$2"; _vh="$3"
    _vh_args=""
    [ "$_vh" = "1" ] && _vh_args="--vector-hunt --vector-hunt-max-vectors $VEC_MAX"
    # shellcheck disable=SC2086  # $_vh_args is an intentional word-split flag pair (empty on the control arm)
    CALLEE_TRUST="$_ct" \
      "$ZONEHUNT" --repo "$SCRATCH" --out "$_out" --backend "$BACKEND" --agentis "$AGENTIS" \
        ${SCOPE_HINT:+--scope-hint "$SCOPE_HINT"} $_vh_args \
      || note "  [$ID] run-zone-hunt.sh ($_ct/$_vh) exited non-zero; scoring whatever it produced"
  }

  OUT_CTRL="$WORK/$ID/$LABEL_CONTROL"
  OUT_TREAT="$WORK/$ID/$LABEL_TREATMENT"
  note "[$ID] $LABEL_CONTROL (CALLEE_TRUST=0, no --vector-hunt) ..."; run_live_arm "$OUT_CTRL" 0 0
  note "[$ID] $LABEL_TREATMENT (CALLEE_TRUST=1, --vector-hunt) ..."; run_live_arm "$OUT_TREAT" 1 1

  report_side() {  # $1 = out dir, $2 = label
    _vj="$1/verify/verified_findings.json"
    if [ ! -f "$_vj" ]; then note "  [$ID] $2: no verified_findings.json produced"; return; fi
    _rr="$(rare_recall_count "$TRUTH" "$_vj")"
    note "  [$ID] $2: rare(1-2) VERIFIED recall = $_rr"
  }

  note "================ CALLEE-TRUST A/B [$ID] ================"
  report_side "$OUT_CTRL" "$LABEL_CONTROL"
  report_side "$OUT_TREAT" "$LABEL_TREATMENT"
  VJ_CTRL="$OUT_CTRL/verify/verified_findings.json"
  VJ_TREAT="$OUT_TREAT/verify/verified_findings.json"
  if [ -f "$VJ_CTRL" ] && [ -f "$VJ_TREAT" ]; then
    RCTRL="$(rare_recall_count "$TRUTH" "$VJ_CTRL")"
    RTREAT="$(rare_recall_count "$TRUTH" "$VJ_TREAT")"
    note "  [$ID] Δ = $LABEL_TREATMENT − $LABEL_CONTROL rare recall = $RTREAT − $RCTRL = $((RTREAT - RCTRL))"
  else
    note "  [$ID] Δ not computed — one arm produced no verified_findings.json"
  fi
  note "the treatment-vs-control rare recall delta is D1+D2's measured VERIFIED contribution on this contest (a bench proxy). Gate the default flip on this Δ being positive on BOTH the measurement AND a pre-registered transfer contest, and on model-attribution.py proving the analysis stages ran Fable."
  exit 0
fi

echo "callee-trust-ab.sh: unknown mode: $MODE" >&2
exit 2
