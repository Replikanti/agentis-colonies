#!/usr/bin/env bash
# generalization-bench.sh — #1763 G4 measurement harness: DOES the G1-G3 generalization TRANSFER BEYOND YEARN?
#
# G1 generalized the core-dependency (delegatecall-singleton) DETECTION; G2+G3 generalized the admin-guard and
# deferred-accounting DIRECTIVES — all keeping yearn-ybold as the worked example, and all proven not to regress
# the yearn catch. But nothing yet measures whether that generalization actually HELPS on a target that is NOT
# yearn. THIS bench is that measurement, and it is built to produce a HONEST NEGATIVE: if the generalized
# capability recalls nothing beyond yearn, the report says so in as many words — a zero/negative delta is DATA,
# never smoothed.
#
# It ORCHESTRATES the two frozen sibling harnesses (it reimplements neither):
#   * generation-recall.sh --from-work (#1730) — scores the GENERATOR's hypotheses (breadth candidates + the
#     verdict-IGNORED INVARIANT| targets) against each contest's truth.tsv, so a bug the pipeline NAMED but did
#     not confirm still counts. This is the generalized deep-hunt's reach on a non-yearn share-inflation target.
#   * deep-hunt-ab.sh --live (#1713) — the ON-vs-OFF High-recall delta the value-custody deep lens buys on one
#     isolated contest zone.
# scored, per selected contest, against that contest's own truth.tsv GT rows.
#
# SELECTION. The bench targets the corpus contests whose ground truth is share-inflation / value-conservation /
# first-depositor class — the targets where G1-G3 SHOULD transfer if it generalized at all. The candidate ids
# (verified present in corpus.tsv: see select_contests) are share-issuing value-custody vault protocols:
# yieldoor (concentrated-liquidity vault), plaza (bond/leverage vault), notional (fixed-rate lending vault),
# mellow (flexible vaults). yearn-ybold is NOT a selected target — it is the REGRESSION ANCHOR (the permanent
# worked example the generalization must never overfit-lose). The selection is a TARGETING HYPOTHESIS the bench
# then MEASURES: each contest is scored against its OWN live truth.tsv, so if a selected contest carries no
# share-inflation GT row its recall is reported honestly (possibly zero), never assumed.
#
# HARD REGRESSION GATE (--regression, also run inside --self-test and before every --live report): the yearn-ybold
# base must STILL yield a deterministic FINDING under the generalized code (no overfitting loss). It runs the two
# CI-enforced yearn source-guard demos (demo-invariant-core-dep.sh + demo-invariant-vault-first-depositor.sh),
# which pin the exact yearn TokenizedStrategy / 0xD377...9c resolution + setDoHealthCheck(false) /
# setProfitMaxUnlockTime(0) worked-example strings under the generalized detector/builders. If the yearn base
# regresses, this FAILS LOUD and the bench refuses to report a "transfer" number built on a broken base.
#
# item 10 of the G4 plan (the fitness / genome-search "evolve" driver) is OUT OF SCOPE here and NOT implemented:
# this bench is the baseline that driver would need first. Per the epic, that driver — when it lands — is the
# pattern-evolver.ag genome-search-over-a-bench-fitness-oracle idiom, NOT an `evolve_self()` runtime builtin
# (which does not exist in this substrate).
#
# TWO modes:
#   --self-test (default; CI-safe, no network / LLM / forge): exercise the bench's OWN orchestration end to end
#     over synthetic fixtures — (a) the selection reads corpus.tsv and resolves the share-inflation candidate ids;
#     (b) the HARD regression gate holds (yearn base yields its deterministic FINDING); (c) generation-recall
#     over a fixture work dir carrying a share-inflation contest (transfer) AND a zero-recall contest reports the
#     per-target + aggregate numbers VERBATIM, proving the report can show a non-zero transfer AND an honest zero.
#
#   --live --work <dir> [--id <id>]... [--backend <b>] [--agentis <bin>] [--min-overlap N] [--json]: real
#     measurement over a corpus-bench --work dir the operator has ALREADY staged (run-corpus-bench.sh --fetch
#     --gt [--hunt with the generalized capability ON]). Per selected contest it scores generation-recall from
#     the staged zone-hunt-out artifacts and runs deep-hunt-ab.sh --live on an ISOLATED scratch copy of that
#     contest's code dir for the ON-vs-OFF delta, then prints per-target + aggregate + a legible TRANSFER verdict.
#
#     CAPACITY CONSTRAINT (same discipline as deep-hunt-ab.sh --live): --live drives the real LLM/forge backend
#     and owns a claude subscription slot. Run it ONLY after freed subscription capacity, on a SINGLE
#     non-contending value-custody zone — never while a live corpus-bench run owns CPU/subscription capacity.
#     --live is NEVER the default; all deterministic/CI paths are --self-test only.
#
# Usage: generalization-bench.sh [--self-test] | --regression
#                                | --live --work <dir> [--id <id>]... [--backend <b>] [--agentis <bin>]
#                                                      [--min-overlap N] [--json] [-h]
# Exit: 0 = self-test held / live measurement completed ; 1 = self-test regressed OR regression gate failed ;
#       2 = bad args ; 3 = missing prerequisite.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DF="$(cd "$HERE/../.." && pwd)"   # dark-factory/
CORPUS="$HERE/corpus.tsv"
GENRECALL="$HERE/generation-recall.sh"
DEEPAB="$HERE/deep-hunt-ab.sh"
GENFIX="$HERE/fixtures/generation-recall"
DEMO_CORE_DEP="$DF/demo-invariant-core-dep.sh"
DEMO_FIRST_DEP="$DF/demo-invariant-vault-first-depositor.sh"

# The share-inflation / value-conservation / first-depositor candidate ids (justified in the header). yearn-ybold
# is the regression ANCHOR, deliberately NOT a selected target.
CANDIDATE_IDS="yieldoor plaza notional mellow"
REGRESSION_ANCHOR="yearn-ybold"

MODE="self-test"
WORK="" ; IDS="" ; BACKEND="flat-cyborg" ; AGENTIS="agentis" ; MINOV="2" ; JSON=0

nv() { [ "$1" -ge 2 ] || { echo "generalization-bench.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do case "$1" in
  --self-test)   MODE="self-test"; shift ;;
  --regression)  MODE="regression"; shift ;;
  --live)        MODE="live"; shift ;;
  --work)        nv "$#"; WORK="$2"; shift 2 ;;
  --id)          nv "$#"; IDS="$IDS $2"; shift 2 ;;
  --backend)     nv "$#"; BACKEND="$2"; shift 2 ;;
  --agentis)     nv "$#"; AGENTIS="$2"; shift 2 ;;
  --min-overlap) nv "$#"; MINOV="$2"; shift 2 ;;
  --json)        JSON=1; shift ;;
  -h|--help)     awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
  *) echo "generalization-bench.sh: unknown arg: $1" >&2; exit 2 ;;
esac; done

note() { echo "generalization-bench.sh: $*"; }

# select_contests — echo the share-inflation candidate ids that ACTUALLY exist as a corpus.tsv row (a non-comment
# row whose first TAB field matches). A candidate missing from corpus.tsv is a logged warning, never a silent drop.
select_contests() {
  _sel=""
  for _cand in $CANDIDATE_IDS; do
    if awk -F'\t' -v id="$_cand" '$1==id && $1 !~ /^#/ {found=1} END{exit !found}' "$CORPUS" 2>/dev/null; then
      _sel="$_sel $_cand"
    else
      note "WARN: candidate '$_cand' not found in corpus.tsv — skipped" >&2
    fi
  done
  echo "${_sel# }"
}

# corpus_field <id> <col> — echo the requested TAB column (4=project_subdir, 5=scope_hint) of a corpus.tsv row.
corpus_field() {
  awk -F'\t' -v id="$1" -v col="$2" '$1==id && $1 !~ /^#/ {print $col; exit}' "$CORPUS" 2>/dev/null
}

# regression_gate — the HARD yearn-base assertion. Runs the two CI-enforced yearn source-guard demos; both MUST
# exit 0. Returns 0 when the yearn base still yields its deterministic FINDING under the generalized code, 1 if it
# regressed, 3 if a demo is missing. Prints a one-line verdict.
regression_gate() {
  _rc=0
  for _demo in "$DEMO_CORE_DEP" "$DEMO_FIRST_DEP"; do
    [ -x "$_demo" ] || { note "regression: yearn source-guard demo missing/not executable: $_demo" >&2; return 3; }
  done
  if bash "$DEMO_CORE_DEP" >/dev/null 2>&1; then
    note "regression: [OK] yearn core-dependency (TokenizedStrategy @ 0xD377...9c) resolves under the generalized detector"
  else
    note "regression: [FAIL] yearn core-dependency source-guard REGRESSED (demo-invariant-core-dep.sh non-zero)" >&2
    _rc=1
  fi
  if bash "$DEMO_FIRST_DEP" >/dev/null 2>&1; then
    note "regression: [OK] yearn first-depositor / share-inflation guard holds under the generalized builders"
  else
    note "regression: [FAIL] yearn first-depositor source-guard REGRESSED (demo-invariant-vault-first-depositor.sh non-zero)" >&2
    _rc=1
  fi
  return "$_rc"
}

# gen_recall_json <work> <ids...> — run generation-recall.sh --from-work over a work dir for the given ids and
# echo its aggregate JSON on stdout (per-contest human lines go to that harness's stderr, surfaced to ours).
gen_recall_json() {
  _w="$1"; shift
  _idargs=""
  for _i in "$@"; do _idargs="$_idargs --id $_i"; done
  # shellcheck disable=SC2086
  bash "$GENRECALL" --from-work "$_w" $_idargs --min-overlap "$MINOV" --json
}

# report_transfer <aggregate-json> <anchor-id> — render the per-target + aggregate + TRANSFER verdict from a
# generation-recall --json blob. The TRANSFER verdict is computed over the NON-anchor (non-yearn) contests only:
# it is the honest answer to "did G1-G3 recall anything BEYOND yearn?" — a 0 is printed as NONE, never hidden.
report_transfer() {
  python3 - "$1" "$2" <<'PY'
import json, sys
blob, anchor = sys.argv[1], sys.argv[2]
try:
    d = json.loads(blob) if blob.strip() else {}
except Exception as e:
    print("generalization-bench.sh: could not parse generation-recall JSON: %s" % e)
    sys.exit(0)
contests = d.get("contests", []) or []
print("generalization-bench.sh: ---- per-target generation-recall (scored vs each contest's truth.tsv) ----")
non_anchor_hits = non_anchor_total = 0
non_anchor_rare_hits = non_anchor_rare_total = 0
non_anchor_high_hits = non_anchor_high_total = 0
n_non_anchor = 0
for c in contests:
    cid = c.get("id", "?")
    tot = c.get("gt_total", 0); hits = c.get("generation_hits", 0)
    rare = c.get("rare", {}) or {}; high = c.get("high", {}) or {}
    tag = "  (REGRESSION ANCHOR)" if cid == anchor else ""
    print("generalization-bench.sh:   [%s] generation-recall %d/%d  (High %d/%d, rare %d/%d)%s"
          % (cid, hits, tot, high.get("hits", 0), high.get("total", 0),
             rare.get("hits", 0), rare.get("total", 0), tag))
    if cid != anchor:
        n_non_anchor += 1
        non_anchor_hits += hits; non_anchor_total += tot
        non_anchor_rare_hits += rare.get("hits", 0); non_anchor_rare_total += rare.get("total", 0)
        non_anchor_high_hits += high.get("hits", 0); non_anchor_high_total += high.get("total", 0)
print("generalization-bench.sh: ---- aggregate over the %d NON-yearn share-inflation target(s) ----" % n_non_anchor)
print("generalization-bench.sh:   generation-recall %d/%d  (High %d/%d, rare %d/%d)"
      % (non_anchor_hits, non_anchor_total, non_anchor_high_hits, non_anchor_high_total,
         non_anchor_rare_hits, non_anchor_rare_total))
if non_anchor_total == 0:
    verdict = "TRANSFER: INCONCLUSIVE — no non-yearn GT rows scored (no staged artifacts / truth); re-stage the corpus"
elif non_anchor_hits == 0:
    verdict = "TRANSFER: NONE — the generalized capability recalled 0/%d GT rows on the non-yearn targets" % non_anchor_total
else:
    verdict = ("TRANSFER: %d/%d GT rows recalled on non-yearn targets (rare %d/%d) — the generalization reaches beyond yearn"
               % (non_anchor_hits, non_anchor_total, non_anchor_rare_hits, non_anchor_rare_total))
print("generalization-bench.sh: %s" % verdict)
PY
}

# ==========================================================================================================
# --regression: the standalone HARD yearn-base gate (also invoked inside --self-test and before --live).
# ==========================================================================================================
if [ "$MODE" = "regression" ]; then
  regression_gate; rc=$?
  case "$rc" in
    0) note "regression: PASS — the yearn base still yields a deterministic FINDING under the generalized code"; exit 0 ;;
    3) exit 3 ;;
    *) note "regression: FAIL — the yearn base REGRESSED (overfitting loss); refusing to trust any transfer number" >&2; exit 1 ;;
  esac
fi

# ==========================================================================================================
# --self-test (default): the offline, deterministic acceptance bar. No network / LLM / forge.
# ==========================================================================================================
if [ "$MODE" = "self-test" ]; then
  FAILS=0
  ok()  { echo "  [PASS] $*"; }
  bad() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

  command -v python3 >/dev/null 2>&1 || { echo "generalization-bench.sh: [SKIP] python3 not installed" >&2; exit 0; }
  [ -x "$GENRECALL" ] || { note "prerequisite missing/not executable: $GENRECALL" >&2; exit 3; }
  [ -x "$DEEPAB" ]    || { note "prerequisite missing/not executable: $DEEPAB" >&2; exit 3; }
  [ -f "$CORPUS" ]    || { note "prerequisite missing: $CORPUS" >&2; exit 3; }
  for f in truth.tsv discovery-results.merged.json invariant-targets.txt verified_findings.json; do
    [ -f "$GENFIX/$f" ] || { note "generation-recall fixture missing: $GENFIX/$f" >&2; exit 3; }
  done

  # (a) SELECTION: the bench resolves its share-inflation candidate ids against the REAL corpus.tsv.
  SEL="$(select_contests)"
  note "selected share-inflation targets: ${SEL:-<none>}"
  for want in yieldoor plaza notional mellow; do
    case " $SEL " in
      *" $want "*) ok "(a) selection resolves corpus contest '$want'" ;;
      *) bad "(a) selection did NOT resolve corpus contest '$want' (present in corpus.tsv?)" ;;
    esac
  done
  # The regression anchor must NOT be a selected target (it is the base, not a transfer target).
  case " $SEL " in
    *" $REGRESSION_ANCHOR "*) bad "(a) the regression anchor '$REGRESSION_ANCHOR' leaked into the selected transfer targets" ;;
    *) ok "(a) the regression anchor '$REGRESSION_ANCHOR' is correctly excluded from the transfer targets" ;;
  esac

  # (b) HARD REGRESSION GATE: the yearn base still yields its deterministic FINDING under the generalized code.
  if regression_gate; then
    ok "(b) the HARD regression gate holds — yearn base yields a deterministic FINDING (no overfitting loss)"
  else
    bad "(b) the HARD regression gate FAILED — yearn base regressed"
  fi

  # (c) ORCHESTRATION: build a synthetic work dir with a share-inflation contest (transfer) AND a zero-recall
  #     contest, then assert the per-target + aggregate report shows the numbers VERBATIM — proving the bench can
  #     surface a non-zero transfer AND an honest zero (never smoothed).
  WD="$(mktemp -d "${TMPDIR:-/tmp}/generalization-bench.XXXXXX")"
  trap 'rm -rf "$WD"' EXIT

  # A "yieldoor"-shaped share-inflation contest reusing the frozen generation-recall fixtures (2 GT rows, both
  # NAMED by a hypothesis => generation-recall 2/2 = transfer present).
  mk_contest_from_fixture() {  # $1 = id
    _cid="$1"
    mkdir -p "$WD/$_cid/zone-hunt-out/discovery" "$WD/$_cid/zone-hunt-out/deep-hunt/z1/run" "$WD/$_cid/zone-hunt-out/verify"
    cp "$GENFIX/truth.tsv" "$WD/$_cid/truth.tsv"
    cp "$GENFIX/discovery-results.merged.json" "$WD/$_cid/zone-hunt-out/discovery/discovery-results.merged.json"
    cp "$GENFIX/verified_findings.json" "$WD/$_cid/zone-hunt-out/verify/verified_findings.json"
    # the deep-hunt invariant log carries the same INVARIANT|<file:fn>|<verdict> lines the adapter reads.
    cp "$GENFIX/invariant-targets.txt" "$WD/$_cid/zone-hunt-out/deep-hunt/z1/run/invariant_1.log"
  }
  mk_contest_from_fixture yieldoor

  # A zero-recall contest: same generated hypotheses (which name Vault.sol), but a synthetic truth row naming a
  # DIFFERENT file/function => the hypotheses MISS it => generation-recall 0/1. This exercises the honest-zero path.
  mkdir -p "$WD/zerofix/zone-hunt-out/discovery" "$WD/zerofix/zone-hunt-out/deep-hunt/z1/run"
  cp "$GENFIX/discovery-results.merged.json" "$WD/zerofix/zone-hunt-out/discovery/discovery-results.merged.json"
  cp "$GENFIX/invariant-targets.txt" "$WD/zerofix/zone-hunt-out/deep-hunt/z1/run/invariant_1.log"
  printf 'Z-1\tHigh\t1\tUnrelated registry sweep\tUnrelated registry sweep -- Registry.sol:sweep() sends the whole balance to an unchecked address.\n' \
    > "$WD/zerofix/truth.tsv"

  AGG="$(gen_recall_json "$WD" yieldoor zerofix 2>/dev/null)"
  if [ -z "$AGG" ]; then
    bad "(c) generation-recall produced no aggregate JSON over the fixture work dir"
  else
    RPT="$(report_transfer "$AGG" "$REGRESSION_ANCHOR" 2>/dev/null)"
    printf '%s\n' "$RPT" | sed 's/^/      /'
    if printf '%s\n' "$RPT" | grep -q '\[yieldoor\] generation-recall 2/2'; then
      ok "(c) the share-inflation contest reports its non-zero transfer verbatim (yieldoor 2/2)"
    else
      bad "(c) expected 'yieldoor generation-recall 2/2' in the report"
    fi
    if printf '%s\n' "$RPT" | grep -q '\[zerofix\] generation-recall 0/1'; then
      ok "(c) the zero-recall contest reports an HONEST 0/1 (a negative result is not smoothed)"
    else
      bad "(c) expected an honest 'zerofix generation-recall 0/1' in the report"
    fi
    if printf '%s\n' "$RPT" | grep -q 'TRANSFER: 2/3 GT rows recalled on non-yearn targets'; then
      ok "(c) the aggregate TRANSFER verdict sums the non-yearn targets legibly (2/3)"
    else
      bad "(c) expected aggregate 'TRANSFER: 2/3 GT rows recalled on non-yearn targets'"
    fi
  fi

  echo
  if [ "$FAILS" -eq 0 ]; then
    note "PASS — selection resolves the share-inflation targets, the HARD yearn regression gate holds, and the"
    note "       orchestration reports a non-zero transfer AND an honest zero without smoothing."
    exit 0
  fi
  note "FAIL — $FAILS generalization-bench self-test assertion(s) regressed" >&2
  exit 1
fi

# ==========================================================================================================
# --live: real measurement over an already-staged corpus-bench --work dir.
# NEVER run this while a live corpus-bench run owns CPU/subscription capacity (see the header constraint).
# ==========================================================================================================
if [ "$MODE" = "live" ]; then
  command -v python3 >/dev/null 2>&1 || { echo "generalization-bench.sh: python3 not installed" >&2; exit 3; }
  [ -x "$GENRECALL" ] || { echo "generalization-bench.sh: generation-recall.sh not found/executable: $GENRECALL" >&2; exit 3; }
  [ -x "$DEEPAB" ]    || { echo "generalization-bench.sh: deep-hunt-ab.sh not found/executable: $DEEPAB" >&2; exit 3; }
  [ -n "$WORK" ] && [ -d "$WORK" ] || { echo "generalization-bench.sh: --live requires --work <staged corpus-bench work dir>" >&2; exit 2; }
  WORK="$(cd "$WORK" && pwd)"

  # HARD regression gate FIRST: refuse to report a transfer number if the yearn base regressed.
  if ! regression_gate; then
    note "live: ABORT — the yearn base regressed; a transfer number on a broken base is meaningless" >&2
    exit 1
  fi

  # The targets: the explicit --id list (intersected with the candidates), else every resolvable candidate.
  if [ -n "$IDS" ]; then SELECTED="$IDS"; else SELECTED="$(select_contests)"; fi
  [ -n "$SELECTED" ] || { note "live: no share-inflation target resolved (check corpus.tsv / --id)" >&2; exit 3; }
  note "live: share-inflation transfer targets: $SELECTED  (regression anchor: $REGRESSION_ANCHOR, backend: $BACKEND)"

  # Per-contest ON-vs-OFF deep-hunt delta on an ISOLATED scratch copy — deep-hunt-ab.sh handles the scratch/scope
  # discipline. A contest whose code / truth is not staged is a logged skip, never a false zero.
  for id in $SELECTED; do
    subdir="$(corpus_field "$id" 4)"
    scope="$(corpus_field "$id" 5)"
    code_dir="$WORK/$id/code${subdir:+/$subdir}"
    truth="$WORK/$id/truth.tsv"
    if [ ! -d "$code_dir" ] || [ ! -f "$truth" ]; then
      note "live: [$id] not staged (need $code_dir + $truth — run run-corpus-bench.sh --fetch --gt [--hunt] first); skipping A/B"
      continue
    fi
    note "live: [$id] ON-vs-OFF deep-hunt A/B (deep-hunt-ab.sh --live) ..."
    bash "$DEEPAB" --live --id "$id" --code-dir "$code_dir" --truth "$truth" \
      ${scope:+--scope-hint "$scope"} --work "$WORK/$id/deep-hunt-ab" \
      --backend "$BACKEND" --agentis "$AGENTIS" --min-overlap "$MINOV" \
      || note "live: [$id] deep-hunt-ab.sh --live exited non-zero; continuing with generation-recall"
  done

  # Aggregate generation-recall over the staged zone-hunt-out artifacts of the selected targets + the anchor, so
  # the report shows the transfer targets NEXT TO the yearn base. generation-recall.sh's per-contest HIT/MISS
  # lines flow to stderr (surfaced live); we capture only its aggregate JSON on stdout. A missing artifact is a
  # logged skip inside generation-recall.sh, never a false zero.
  note "live: scoring generation-recall over the staged artifacts of: $SELECTED $REGRESSION_ANCHOR"
  # shellcheck disable=SC2086
  AGG_JSON="$(gen_recall_json "$WORK" $SELECTED "$REGRESSION_ANCHOR")"

  note "================ GENERALIZATION TRANSFER [G4] ================"
  report_transfer "$AGG_JSON" "$REGRESSION_ANCHOR"
  note "the TRANSFER verdict above is a bench PROXY (recall on concluded, combed-over contests), NOT a live jackpot;"
  note "a zero/negative result is the HONEST answer that G1-G3 did not transfer beyond yearn on these targets."
  [ "$JSON" -eq 1 ] && printf '%s\n' "$AGG_JSON"
  exit 0
fi

echo "generalization-bench.sh: unknown mode: $MODE" >&2
exit 2
