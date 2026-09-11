#!/usr/bin/env bash
# integration-lens-ab.sh — #2191 A/B measurement harness for the EXTERNAL-INTEGRATION / ORACLE-ASSUMPTION
# directive's rare-recall contribution. It runs the zone-hunt pipeline (run-zone-hunt.sh) OVER THE SAME target
# TWICE — a CONTROL arm (INTEGRATION_LENS=0: the pre-#2191 pipeline, the directive forced OFF even where the
# detector fires) and a TREATMENT arm (INTEGRATION_LENS unset = default ON: the directive injected) — and
# scores each arm's GENERATION hypotheses against ground truth, so the RARE-tier GENERATION-recall DELTA the
# directive buys is measured directly, ON vs OFF.
#
# HEADLINE METRIC: rare(1-2) GENERATION-recall via generation-recall.sh (scored from the breadth hunter's
# PRE-REFUTE candidates in discovery-results.merged.json). #2191 is a GENERATION directive — it changes which
# assumptions the model NAMES, not whether a fuzzer CONFIRMS them — so generation-recall (not verified-recall)
# is the correct ruler. The two arms differ ONLY in the INTEGRATION_LENS toggle, so a positive Δ is the
# directive's isolated contribution.
#
# HONEST MODEL ROUTING (the live gate, mirroring callee-trust-ab.sh): run the analysis/enumeration stages
# (map-zones / gen-briefs / run-discovery+hunter.ag) on the mandatory flat-cyborg backend with the
# refusal-fallback + model-fallback killswitches on (CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1 +
# CLAUDE_CODE_NO_MODEL_FALLBACK=1), and prove it afterwards with model-attribution.py; a silent fallback voids
# the capability claim. This harness needs NO PoC-authoring stage (generation-recall ignores the fuzzer
# verdict), so it is single-backend end to end.
#
# This is a capability-frontier ATTEMPT measured by a bench PROXY (rare-tier generation-recall delta on a
# scored contest), NOT a guaranteed jackpot: the real test is fresh live targets the bench cannot measure. The
# --self-test proves the MECHANISM end to end offline; --live measures a real contest.
#
# TWO modes:
#   --self-test (default; CI-safe, no network / LLM / forge): drive run-zone-hunt.sh over
#     fixtures/integration-lens-ab/ TWICE through one --agentis stub — CONTROL (INTEGRATION_LENS=0) and
#     TREATMENT (INTEGRATION_LENS unset) — and assert:
#       (a) the CONTROL cell log LACKS the INTEGRATION-LENS sentinel AND its discovery merge carries no
#           integration CANDIDATE, so generation-recall scores the rare truth row a MISS,
#       (b) the TREATMENT cell log CARRIES the INTEGRATION-LENS sentinel AND its discovery merge carries the
#           integration CANDIDATE, so generation-recall scores the rare truth row a HIT,
#       (c) rare GENERATION-recall Δ = TREATMENT − CONTROL = +1 (the ON-vs-OFF rare-recall delta, proven
#           offline via generation-recall.sh, the SAME ruler the live run uses),
#       (d) the run labels control / treatment are FIXED (below, before any run) — never assigned after the
#           numbers are seen.
#     A mock backend never reasons, so this proves MACHINERY only — capability is the live A/B below.
#
#   --live --id <id> --code-dir <dir> --truth <truth.tsv> [--scope-hint <t>]: real rare-tier measurement on a
#     SCRATCH COPY of one already-fetched contest's code dir in an ISOLATED --work dir (NEVER the live
#     corpus-bench run's work directory), --backend flat-cyborg. Scores CONTROL vs TREATMENT with
#     generation-recall.sh and prints the rare(1-2) generation-recall Δ.
#
#     PREFERRED OPERATOR RECIPE (isolates the single variable best): instead of re-mapping per arm, re-hunt the
#     SAME zones from a FROZEN map/scope.tsv + per-zone briefs so the ONLY difference between arms is the
#     directive (removes zone-mapper stochasticity AND the "frozen predates the lens" confound). Per zone:
#       CONTROL:   INTEGRATION_LENS=0 run-discovery.sh --repo <code> --scope <frozen scope.tsv> \
#                    --brief <frozen per-zone brief> --only <zone> --backend flat-cyborg --out <ctrl>/<zone>
#       TREATMENT: (INTEGRATION_LENS unset) run-discovery.sh ... --out <treat>/<zone>
#     then merge each arm's per-zone discovery into <arm>/<id>/zone-hunt-out/discovery/discovery-results.merged.json
#     and score with:  generation-recall.sh --from-work <arm> --id <id> --min-overlap <N> --judge off
#     Quote `rare X/14 (control) -> Y/14 (treatment)` and `overall .../35 -> .../35`. The --live mode below is
#     the re-map fallback when per-zone frozen reuse is impractical (note the added zone-mapper variance).
#
#     CAPACITY CONSTRAINT: the live measurement runs the real LLM backend and owns a claude subscription slot.
#     Run it ONLY after the live corpus-bench run frees capacity, OR on a single isolated non-contending zone.
#     All deterministic/CI paths use --backend mock.
#
#     OVERFITTING / TRANSFER GATE: the gain counts ONLY if rare-recall Δ is positive on the measurement contest
#     AND holds under the no-regression sweep (generation-recall.sh --from-work CONTROL vs TREATMENT over ALL
#     frozen contests: no contest's rare/overall drops, no currently-named bug lost). A gain that vanishes on
#     transfer, or that costs a regression elsewhere, is reachability, not capability.
#
# Usage: integration-lens-ab.sh [--self-test] | [--live --id <id> --code-dir <dir> --truth <f>
#                               [--scope-hint <t>] [--work <dir>] [--backend <b>] [--agentis <bin>]
#                               [--min-overlap <N>]] [-h]
# Exit: 0 = self-test held / live measurement completed ; 1 = self-test regressed ; 2 = bad args ;
#       3 = missing prerequisite.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DF="$(cd "$HERE/../.." && pwd)"   # dark-factory/
ZONEHUNT="$DF/run-zone-hunt.sh"
GENRECALL="$HERE/generation-recall.sh"
FIX="$HERE/fixtures/integration-lens-ab"

# (d) The A/B labels are FIXED here, before any run — never assigned after the numbers are seen.
LABEL_CONTROL="control"
LABEL_TREATMENT="treatment"

MODE="self-test"
ID="" ; CODE_DIR="" ; TRUTH="" ; SCOPE_HINT="" ; WORK="" ; BACKEND="flat-cyborg" ; AGENTIS="agentis" ; MINOV="2"

nv() { [ "$1" -ge 2 ] || { echo "integration-lens-ab.sh: missing value for the preceding flag" >&2; exit 2; }; }
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
  *) echo "integration-lens-ab.sh: unknown arg: $1" >&2; exit 2 ;;
esac; done

note() { echo "integration-lens-ab.sh: $*"; }

# gen_rare_recall <work-arm-dir> <id> -> prints the rare(1-2) GENERATION-recall HIT count for that arm, scored
# by generation-recall.sh (the SAME ruler the live headline uses). generation-recall.sh --json prints the JSON
# aggregate on stdout; its own progress goes to stderr, so capturing stdout is clean.
gen_rare_recall() {
  _grr_json="$("$GENRECALL" --from-work "$1" --id "$2" --min-overlap "$MINOV" --json 2>/dev/null)"
  printf '%s' "$_grr_json" | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
    print(d["aggregate"]["rare"]["hits"])
except Exception:
    print("ERR")'
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
  [ -x "$GENRECALL" ] || { note "generation-recall.sh not found / not executable: $GENRECALL" >&2; exit 3; }
  for f in foundry.toml zones.fixture.txt briefs.fixture.txt agentis-stub.sh truth.tsv src/Vault.sol; do
    [ -f "$FIX/$f" ] || { note "fixture missing: $FIX/$f" >&2; exit 3; }
  done

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/integration-lens-ab.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT

  ID="integration-lens"

  # Throwaway Foundry target: the external-integration Vault, under git.
  REPO="$WORK/target"
  mkdir -p "$REPO"
  cp "$FIX/foundry.toml" "$REPO/foundry.toml"
  cp -R "$FIX/src" "$REPO/src"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email demo@example.invalid
  git -C "$REPO" config user.name "demo"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "integration-lens A/B fixture target"

  STUB="$WORK/agentis-stub"
  cp "$FIX/agentis-stub.sh" "$STUB"; chmod +x "$STUB"

  PASS_FIXTURE="scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted"

  # run_arm <arm-label> <integration-lens 0|1>: one run-zone-hunt.sh breadth pass over the SAME fixture, its
  # --out laid out as <work>/<arm>/<id>/zone-hunt-out so generation-recall.sh --from-work <work>/<arm> --id
  # <id> finds discovery-results.merged.json + truth.tsv. The forge-slot pool is isolated per arm.
  run_arm() {
    _arm="$1"; _il="$2"
    _out="$WORK/$_arm/$ID/zone-hunt-out"
    mkdir -p "$WORK/$_arm/$ID"
    cp "$FIX/truth.tsv" "$WORK/$_arm/$ID/truth.tsv"
    INTEGRATION_LENS="$_il" \
    FORGE_SLOTS_DIR="$WORK/$_arm.forge-slots" \
      "$ZONEHUNT" --repo "$REPO" --out "$_out" --drop-dir "$_out/drop" --scope-hint src \
        --backend mock --agentis "$STUB" \
        --map-fixture "$FIX/zones.fixture.txt" --brief-fixture "$FIX/briefs.fixture.txt" \
        --pass-fixture "$PASS_FIXTURE" --in-scope "the whole in-scope program" \
        >"$WORK/$_arm.log" 2>&1
  }

  note "running the CONTROL arm (INTEGRATION_LENS=0 = the pre-#2191 pipeline) ..."
  run_arm "$LABEL_CONTROL" 0; RC_CTRL=$?
  [ "$RC_CTRL" -eq 0 ] && ok "control run exits 0" || { bad "control run exited $RC_CTRL"; sed 's/^/      /' "$WORK/$LABEL_CONTROL.log" | tail -30 >&2; }

  note "running the TREATMENT arm (INTEGRATION_LENS unset = default ON, the #2191 directive injected) ..."
  run_arm "$LABEL_TREATMENT" 1; RC_TREAT=$?
  [ "$RC_TREAT" -eq 0 ] && ok "treatment run exits 0" || { bad "treatment run exited $RC_TREAT"; sed 's/^/      /' "$WORK/$LABEL_TREATMENT.log" | tail -30 >&2; }

  DISC_CTRL="$WORK/$LABEL_CONTROL/$ID/zone-hunt-out/discovery/discovery-results.merged.json"
  DISC_TREAT="$WORK/$LABEL_TREATMENT/$ID/zone-hunt-out/discovery/discovery-results.merged.json"
  [ -f "$DISC_CTRL" ]  || bad "control discovery-results.merged.json missing"
  [ -f "$DISC_TREAT" ] || bad "treatment discovery-results.merged.json missing"

  # (a) the CONTROL cell log lacks the INTEGRATION-LENS sentinel (INTEGRATION_LENS=0 suppressed the directive).
  if grep -rhE '^INTEGRATION-LENS\|' "$WORK/$LABEL_CONTROL/$ID/zone-hunt-out"/discovery/*/run/ >/dev/null 2>&1; then
    bad "(a) the control cell log carries an INTEGRATION-LENS sentinel — INTEGRATION_LENS=0 did not suppress the directive"
  else
    ok "(a) the control cell log carries NO INTEGRATION-LENS sentinel (INTEGRATION_LENS=0 suppressed the directive)"
  fi

  # (b) the TREATMENT cell log carries the INTEGRATION-LENS sentinel and an integration CANDIDATE.
  if grep -rhE '^INTEGRATION-LENS\|' "$WORK/$LABEL_TREATMENT/$ID/zone-hunt-out"/discovery/*/run/ >/dev/null 2>&1; then
    ok "(b) the treatment cell log carries the INTEGRATION-LENS sentinel (the directive fired under default ON)"
  else
    bad "(b) the treatment cell log is missing the INTEGRATION-LENS sentinel — the directive did not fire under default ON"
  fi

  # (c) rare GENERATION-recall via generation-recall.sh: MISS in control, HIT in treatment, Δ=+1.
  RCTRL="$(gen_rare_recall "$WORK/$LABEL_CONTROL" "$ID")"
  RTREAT="$(gen_rare_recall "$WORK/$LABEL_TREATMENT" "$ID")"
  note "  rare GENERATION-recall: $LABEL_CONTROL=$RCTRL $LABEL_TREATMENT=$RTREAT"
  case "$RCTRL" in ''|*[!0-9]*) bad "control rare generation-recall did not score (got '$RCTRL')"; RCTRL=0 ;; esac
  case "$RTREAT" in ''|*[!0-9]*) bad "treatment rare generation-recall did not score (got '$RTREAT')"; RTREAT=0 ;; esac
  if [ "$RCTRL" -eq 0 ] && [ "$RTREAT" -eq 1 ]; then
    ok "(c) the rare truth row is MISS in control (0), HIT in treatment (1) — the rare generation-recall delta holds"
  else
    bad "(c) expected control=0 treatment=1 rare generation-recall, got control=$RCTRL treatment=$RTREAT"
  fi
  DELTA=$((RTREAT - RCTRL))
  note "  rare generation-recall Δ = $LABEL_TREATMENT − $LABEL_CONTROL = $DELTA"
  if [ "$DELTA" -eq 1 ]; then
    ok "(c2) Δ = treatment − control rare generation-recall = +1 (the #2191 directive added exactly one rare row)"
  else
    bad "(c2) expected Δ=+1 on the fixture, got Δ=$DELTA (control=$RCTRL treatment=$RTREAT)"
  fi

  # (d) the labels were fixed BEFORE any run.
  if [ "$LABEL_CONTROL" = "control" ] && [ "$LABEL_TREATMENT" = "treatment" ]; then
    ok "(d) the run labels control/treatment are FIXED constants (assigned before scoring, never after the numbers)"
  else
    bad "(d) the run labels are not the fixed control/treatment constants"
  fi

  echo
  if [ "$FAILS" -eq 0 ]; then
    note "PASS — CONTROL (INTEGRATION_LENS=0) misses the rare integration row; TREATMENT (default ON) catches it; rare generation-recall Δ=+1 offline"
    exit 0
  fi
  note "FAIL — $FAILS assertion(s) regressed" >&2
  exit 1
fi

# ==========================================================================================================
# --live: real CONTROL-vs-TREATMENT rare GENERATION-recall measurement on an ISOLATED scratch copy of one
# contest. NEVER run this while the live corpus-bench run owns CPU/subscription capacity (see the header).
# ==========================================================================================================
if [ "$MODE" = "live" ]; then
  command -v python3 >/dev/null 2>&1 || { echo "integration-lens-ab.sh: python3 not installed" >&2; exit 3; }
  [ -x "$ZONEHUNT" ] || { echo "integration-lens-ab.sh: run-zone-hunt.sh not found/executable: $ZONEHUNT" >&2; exit 3; }
  [ -x "$GENRECALL" ] || { echo "integration-lens-ab.sh: generation-recall.sh not found/executable: $GENRECALL" >&2; exit 3; }
  [ -n "$ID" ] || { echo "integration-lens-ab.sh: --live requires --id <id>" >&2; exit 2; }
  [ -n "$CODE_DIR" ] && [ -d "$CODE_DIR" ] || { echo "integration-lens-ab.sh: --live requires --code-dir <already-fetched contest code dir>" >&2; exit 2; }
  [ -n "$TRUTH" ] && [ -f "$TRUTH" ] || { echo "integration-lens-ab.sh: --live requires --truth <truth.tsv>" >&2; exit 2; }
  [ -n "$WORK" ] || WORK="$PWD/integration-lens-ab-work"
  mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"

  # SCRATCH COPY: never touch the source contest dir (which may belong to the live corpus-bench run).
  SCRATCH="$WORK/$ID/code"
  rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
  cp -R "$CODE_DIR/." "$SCRATCH/"
  note "live A/B on an isolated scratch copy: $SCRATCH (scope-hint: ${SCOPE_HINT:-<none>}, backend: $BACKEND)"
  note "REMINDER: run with CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1 + CLAUDE_CODE_NO_MODEL_FALLBACK=1 (flat-cyborg) and prove per-stage purity afterwards with model-attribution.py; the headline is rare GENERATION-recall (generation-recall.sh), not verified-recall."

  # run_live_arm <arm-label> <integration-lens 0|1>: the SAME target under each arm's toggle. --out laid out so
  # generation-recall.sh --from-work <work>/<arm> --id <id> resolves the discovery merge + truth.tsv.
  run_live_arm() {
    _arm="$1"; _il="$2"
    _out="$WORK/$_arm/$ID/zone-hunt-out"
    mkdir -p "$WORK/$_arm/$ID"
    cp "$TRUTH" "$WORK/$_arm/$ID/truth.tsv"
    INTEGRATION_LENS="$_il" \
      "$ZONEHUNT" --repo "$SCRATCH" --out "$_out" --backend "$BACKEND" --agentis "$AGENTIS" \
        ${SCOPE_HINT:+--scope-hint "$SCOPE_HINT"} \
      || note "  [$ID] run-zone-hunt.sh (INTEGRATION_LENS=$_il) exited non-zero; scoring whatever it produced"
  }

  note "[$ID] $LABEL_CONTROL (INTEGRATION_LENS=0) ..."; run_live_arm "$LABEL_CONTROL" 0
  note "[$ID] $LABEL_TREATMENT (INTEGRATION_LENS unset = default ON) ..."; run_live_arm "$LABEL_TREATMENT" 1

  note "================ INTEGRATION-LENS A/B [$ID] ================"
  RCTRL="$(gen_rare_recall "$WORK/$LABEL_CONTROL" "$ID")"
  RTREAT="$(gen_rare_recall "$WORK/$LABEL_TREATMENT" "$ID")"
  note "  [$ID] $LABEL_CONTROL:   rare(1-2) GENERATION-recall = $RCTRL"
  note "  [$ID] $LABEL_TREATMENT: rare(1-2) GENERATION-recall = $RTREAT"
  case "$RCTRL$RTREAT" in
    *ERR*|*[!0-9]*) note "  [$ID] Δ not computed — an arm produced no scoreable generation artifact" ;;
    *) note "  [$ID] Δ = $LABEL_TREATMENT − $LABEL_CONTROL rare generation-recall = $RTREAT − $RCTRL = $((RTREAT - RCTRL))" ;;
  esac
  note "the treatment-vs-control rare generation-recall delta is the #2191 directive's measured contribution on this contest (a bench proxy). Gate the default flip on this Δ being positive AND the no-regression sweep (generation-recall.sh --from-work over ALL frozen contests) losing no currently-named bug, and on model-attribution.py proving the analysis stages ran flat-cyborg."
  exit 0
fi

echo "integration-lens-ab.sh: unknown mode: $MODE" >&2
exit 2
