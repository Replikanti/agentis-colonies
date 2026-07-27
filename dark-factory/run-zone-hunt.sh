#!/usr/bin/env bash
# run-zone-hunt.sh — #1630 (milestone M5 of epic #1611: gate + deliver). The CAPSTONE that closes the loop.
#
# It chains the shipped M1..M4 + delivery entrypoints into ONE end-to-end autonomous zone-hunt and EDITS none of
# them — it only invokes them as-is:
#   map-zones.sh (M1)  -> gen-briefs.sh (M2)  -> per-zone run-discovery.sh (M3)  -> merge  ->
#   verify-findings.sh (M4)  -> per verified finding: run-audit-pass.sh  -> deliver-submission.sh
#
# THE HALT (load-bearing, never-submit). The capstone contains NO curl/wget/submit/egress verb on any executable
# line. The never-submit invariant is enforced by the TWO baked-in gates it reuses per finding:
#   1. run-audit-pass.sh terminates at PENDING-HUMAN-REVIEW — it NEVER emits a submit; the best case is a draft.
#   2. deliver-submission.sh REFUSES (exit 3) any draft lacking SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW and only
#      STAGES it into a local drop-dir (+ pages the operator's OWN Slack, never a bounty platform).
# The capstone deliberately does NOT call notify-submission.sh itself (deliver-submission already pages
# internally — calling it here would double-page). It adds ZERO new egress path.
#
# PER-FINDING ERROR PROPAGATION. Each finding's audit-pass -> deliver body is wrapped so a single bad finding is
# LOGGED and SKIPPED; the batch finishes over every remaining finding and the capstone exits 0.
#
# TWO PATHS. Offline (deterministic, CI): pass --map-fixture / --brief-fixture (the M1/M2 substrate stubs) +
# --pass-fixture (the run-audit-pass stub) and drive every substrate call through the --agentis stub seam — no
# LLM, no forge, no network. Live (operator): omit the fixtures; map-zones/gen-briefs/run-discovery/run-audit-pass
# reason through the real backend and run-audit-pass runs --live. Submission is ALWAYS a separate human action.
#
# Usage:
#   run-zone-hunt.sh --repo <dir> [--out <dir>] [options]
#
# Options:
#   --repo <dir>        Cloned target repo root (clone with fetch-target.sh). REQUIRED.
#   --out <dir>         Output dir for the whole run (default: ./zone-hunt-out).
#   --jobs <N>          run-discovery.sh intra-zone bounded concurrency (default 1; zones loop SERIALLY).
#   --backend <mock|flat-cyborg|claude>  LLM backend for every substrate step (default: flat-cyborg).
#   --agentis <bin>     agentis binary (default: `agentis` on PATH).
#   --scope-hint <t>    map-zones.sh source restriction (comma/space list of files or dir-prefixes).
#   --since <ref>       Audit-covered ref (feeds map-zones.sh's advisory hardening_score).
#   --audit-residuals <f>  audit-scout.ag output folded into gen-briefs.sh's per-zone briefs (optional).
#   --in-scope <t>      The in-scope program facts handed to run-audit-pass.sh's scope gate.
#   --asset-contracts <t>  Optional in-scope asset/contract facts (recorded for the scope gate context).
#   --impact-threshold <t>  Optional impact bar handed through to the audit-pass context.
#   --map-fixture <f>   map-zones.sh --fixture (OFFLINE M1); when present the M1 substrate step is stubbed.
#   --brief-fixture <f> gen-briefs.sh --fixture (OFFLINE M2); when present the M2 substrate step is stubbed.
#   --pass-fixture <PF> run-audit-pass.sh --pass-fixture (OFFLINE M5); absent => run-audit-pass runs --live.
#   --deep-hunt         #1713: enable STAGE 4.5 — a SECOND, severity-first lens that runs the stateful-
#                       invariant engine (run-invariant-hunt.sh) on the VALUE-CUSTODY zones (zones.json's
#                       value_custody flag) and merges each fuzzer-reproduced FINDING into
#                       verified_findings.json (tagged source=invariant-hunt) so M5 + corpus-bench see it.
#                       DEFAULT OFF — without it every run is byte-identical to before. Requires the target
#                       to be a Foundry project ($REPO/foundry.toml); a non-Foundry target logs + skips it.
#   --deep-hunt-only    #1774: skip M1..M4 (breadth) AND M5 (delivery) and apply ONLY the UNCHANGED STAGE 4.5
#                       lens over an EXISTING breadth --out (its map/zones.json + verify/verified_findings.json
#                       must already exist, else exit 3). Requires --deep-hunt. This is the seam deep-hunt-ab.sh
#                       --live uses to SHARE one breadth pass across OFF and ON: breadth once -> OFF, clone ->
#                       ON, lens-only over the clone, so ON is a superset of OFF and the A/B delta isolates the
#                       lens. DEFAULT OFF => the full M1..M4 -> (4.5) -> M5 path is byte-identical to before.
#   --invariant-fixture <f>  run-invariant-hunt.sh --handler-fixture (the OFFLINE/deterministic deep-hunt
#                       path — no LLM). Only meaningful with --deep-hunt.
#   --deep-hunt-max-targets <N>  Max primary targets per value-custody zone (default 1 — the largest .sol).
#   --deep-hunt-aux-max <N>  #1726 (M2): max SECONDARY co-custody contracts fed to the deep-hunt as
#                       run-invariant-hunt.sh --aux (the shipped composable-fresh multi-contract engine —
#                       INV_AUX -> compose_fresh_seed -> multi-register targetContracts() -> #1077 both-real
#                       enforcement, REUSED verbatim). For each value-custody zone the up-to-N largest
#                       co-custody .sol AFTER the primary target are threaded as --aux, so a SYSTEM invariant
#                       spanning >1 contract can be reached. DEFAULT 0 = OFF = byte-identical single-target
#                       behaviour (STAGE 4.5 emits an empty aux column and neither $INVHUNT invocation gains a
#                       --aux arg). The #1471 linkage gate still fires on the PRIMARY target; aux contracts are
#                       protected by the existing #1077 both-real HARNESS_ERROR safety.
#   --deep-hunt-max-lenses <N>  #1795: max lens classes run per deep-hunt zone (default 2). The STAGE 4.5
#                       selection emits one row per (zone x APPLICABLE implemented lens class) instead of the
#                       single dominant class, so a non-custody lens (oracle C2, liveness C16, access C5) is no
#                       longer shadowed by the custody-first routing on a value-custody zone. Rows are ordered
#                       custody-primary first, then C2, C16, C5 (the coverage-map rarity order) and truncated to
#                       N — so N=1 reproduces the pre-#1795 single-lens fan-out.
#   --deep-hunt-repair-rounds <N>  #1717: run-invariant-hunt.sh --repair-rounds for every deep-hunt target
#                       (default 4 — a value-custody zone whose first harness draft doesn't compile gets
#                       more bounded compile-repair attempts before HARNESS_ERROR; the loop still
#                       short-circuits on the first successful verdict, so a clean-compiling harness pays
#                       nothing extra). Threaded into both --deep-hunt $INVHUNT invocations.
#   --pattern-store <dir>  #1731 (also #1037): PERSISTENT cross-run pattern-DAG + corpus store. Forwarded
#                       verbatim to both --deep-hunt run-invariant-hunt.sh invocations. Absent => byte-identical.
#   --replay-corpus     #1731: enable the CROSS-RUN ENSEMBLE / UNION replay in the deep-hunt (accumulate every
#                       generated invariant + replay the accumulated union against the fresh target). Requires
#                       --pattern-store. Forwarded verbatim to both $INVHUNT invocations; absent => byte-identical.
#   --corpus-max <N>    #1731: cap the cross-run corpus at N most-recent entries per class (default in the engine
#                       is 16). Forwarded verbatim to both $INVHUNT invocations; absent => byte-identical.
#   --symbolic-oracle   #1732: run the COMPLEMENTARY symbolic/BMC (Halmos) oracle over each deep-hunt target's
#                       generated invariant AFTER the fuzzer verdict — a SEPARATE report section + SYMBOLIC|
#                       marker; the fuzzer stays the SOLE verdict. Forwarded verbatim to both $INVHUNT
#                       invocations; absent => byte-identical.
#   --symbolic-timeout <S>  #1732: per-assertion Halmos solver timeout (seconds) for --symbolic-oracle.
#                       Forwarded verbatim to both $INVHUNT invocations; absent => byte-identical.
#   --core-dep-harness  #1755: for yearn-v3 delegatecall-singleton targets, make the deep-hunt harness deploy +
#                       `vm.etch` the REAL TokenizedStrategy singleton (instead of a zero stub) so the ERC4626
#                       share path is fuzzable. Forwarded verbatim to both $INVHUNT invocations; absent =>
#                       byte-identical.
#   --ensemble-candidates <N>  #1778: run the SINGLE-RUN METAMORPHIC ENSEMBLE per deep-hunt target — steer N
#                       distinct relational-invariant VARIANTS through the unchanged gate and take an ensemble
#                       vote (any break => FINDING). Forwarded verbatim to both $INVHUNT invocations; default 0
#                       (= OFF) / N < 2 => byte-identical to today's single-draw deep-hunt.
#   --zone-cell-budget <N>  #1830: max CELLS admitted for ONE zone. 0 (default) = OFF = unbounded, and the
#                       run-discovery.sh invocation gains NO argument (byte-identical to before). A zone whose
#                       planned cell count exceeds the cap is hunted with `--classes <first N classes>` and
#                       recorded `budget_truncated: true`. NOTE: cells are the unit the pipeline enumerates
#                       and controls — this bounds the number of hunter substrate calls and NOTHING ELSE. It
#                       is NOT a wall-clock, token or memory cap (per-cell cost varies ~20 % on its own).
#   --run-cell-budget <N>  #1830: max CELLS across ALL of STAGE 3. 0 (default) = OFF. The effective cap for a
#                       zone is min(zone budget, run budget - spent). The FIRST denial STOPS the loop and every
#                       remaining zone is recorded `budget_exhausted` — never best-effort packing, which would
#                       silently invert the #1826 value-custody-first order.
#   --require-coverage <pct>  #1830: after STAGE 3, exit 4 BEFORE STAGE 4/5 when the covered fraction is below
#                       <pct> (0-100). Default empty = OFF. A degraded run must not be able to publish a
#                       plausible-looking result; the coverage record is already on disk when it aborts.
#   --rehunt-gaps       #1830: TARGETED RE-HUNT. SKIP STAGE 1/2 and re-enter STAGE 3 against ONLY the zones the
#                       existing <out>/coverage/zone-coverage.json records as gaps (not_reached /
#                       budget_exhausted / in_flight / failed), then merge (the merge globs every zone dir, so
#                       it naturally produces the UNION) and run STAGE 4/5 over that union. Requires an existing
#                       --out with map/zones.json, map/scope.tsv, briefs/briefs/ and the coverage record, else
#                       exit 3. Mutually exclusive with --deep-hunt-only (exit 2). DEFAULT OFF.
#   --rehunt-include-partial  #1830: also re-hunt PARTIAL zones (hunted_degraded, or budget_truncated) — off by
#                       default because a re-hunt would redo cells that already produced results. Requires
#                       --rehunt-gaps (exit 2).
#   --rehunt-max-attempts <N>  #1830: leave a zone alone once its coverage record carries >= N attempts
#                       (default 2). ONE --rehunt-gaps pass is exactly ONE pass over the gap set, never a loop.
#   --drop-dir <dir>    deliver-submission.sh drop-dir (default: <out>/drop).
#   -h, --help          This help.
#
# COVERAGE (#1830, ALWAYS ON — the deliberate exception to every other knob's default-inertness). STAGE 3 writes
# <out>/coverage/zone-coverage.json BEFORE it hunts a single zone, with EVERY zone in zones.json present as
# `not_reached`, and rewrites each entry as the zone transitions. Absence is therefore not representable: a
# truncated run cannot look like a clean sweep. When the record is incomplete STAGE 3 prints a COVERAGE GAP
# banner to stderr and discovery-results.merged.json carries an additive `coverage` object. Schema + the
# eight-state vocabulary: lib/zone-coverage.py and docs/zone-split-orchestration.md.
#
# Exit: 0 after the batch (a clean halt on every finding, incl. per-finding failures that were skipped); 2 usage
#       error; 3 missing prerequisite (an upstream stage — map/brief/discovery/verify — failed to produce output);
#       4 --require-coverage was set and STAGE 3 covered less than that fraction of the zones (#1830).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
REPO="" ; OUT="$PWD/zone-hunt-out" ; JOBS=1 ; BACKEND="flat-cyborg"
SCOPE_HINT="" ; SINCE="" ; RESIDUALS=""
IN_SCOPE="" ; ASSET_CONTRACTS="" ; IMPACT_THRESHOLD=""
MAP_FIXTURE="" ; BRIEF_FIXTURE="" ; PASS_FIXTURE="" ; DROP_DIR=""
DEEP_HUNT=0 ; INV_FIXTURE="" ; DEEP_HUNT_MAX_TARGETS=1 ; DEEP_HUNT_REPAIR_ROUNDS=4 ; DEEP_HUNT_AUX_MAX=0
DEEP_HUNT_MAX_LENSES=2  # #1795: max lens classes per deep-hunt zone (custody-primary first, then C2/C16/C5).
DEEP_HUNT_ONLY=0  # #1774: apply ONLY the STAGE 4.5 lens over an existing breadth --out (requires --deep-hunt).
# #1830: per-zone hunt budget + targeted re-hunt. Every knob here defaults OFF/inert — with them off STAGE 3's
# run-discovery.sh invocation gains no argument. The COVERAGE RECORD itself is NOT gated on any of them.
ZONE_CELL_BUDGET=0 ; RUN_CELL_BUDGET=0 ; REQUIRE_COVERAGE=""
REHUNT_GAPS=0 ; REHUNT_INCLUDE_PARTIAL=0 ; REHUNT_MAX_ATTEMPTS=2
# #1731: cross-run ensemble/union flags — a THIN pass-through: collected verbatim into DEEP_FWD and appended to
# both --deep-hunt run-invariant-hunt.sh invocations. Empty (the default) => the arg lists are byte-identical.
DEEP_FWD=()

nv() { [ "$1" -ge 2 ] || { echo "run-zone-hunt.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)             nv "$#"; REPO="$2"; shift 2 ;;
    --out)              nv "$#"; OUT="$2"; shift 2 ;;
    --jobs)             nv "$#"; JOBS="$2"; shift 2 ;;
    --backend)          nv "$#"; BACKEND="$2"; shift 2 ;;
    --agentis)          nv "$#"; AGENTIS="$2"; shift 2 ;;
    --scope-hint)       nv "$#"; SCOPE_HINT="$2"; shift 2 ;;
    --since)            nv "$#"; SINCE="$2"; shift 2 ;;
    --audit-residuals)  nv "$#"; RESIDUALS="$2"; shift 2 ;;
    --in-scope)         nv "$#"; IN_SCOPE="$2"; shift 2 ;;
    --asset-contracts)  nv "$#"; ASSET_CONTRACTS="$2"; shift 2 ;;
    --impact-threshold) nv "$#"; IMPACT_THRESHOLD="$2"; shift 2 ;;
    --map-fixture)      nv "$#"; MAP_FIXTURE="$2"; shift 2 ;;
    --brief-fixture)    nv "$#"; BRIEF_FIXTURE="$2"; shift 2 ;;
    --pass-fixture)     nv "$#"; PASS_FIXTURE="$2"; shift 2 ;;
    --deep-hunt)        DEEP_HUNT=1; shift ;;
    --deep-hunt-only)   DEEP_HUNT_ONLY=1; shift ;;
    --invariant-fixture) nv "$#"; INV_FIXTURE="$2"; shift 2 ;;
    --deep-hunt-max-targets) nv "$#"; DEEP_HUNT_MAX_TARGETS="$2"; shift 2 ;;
    --deep-hunt-aux-max) nv "$#"; DEEP_HUNT_AUX_MAX="$2"; shift 2 ;;
    --deep-hunt-max-lenses) nv "$#"; DEEP_HUNT_MAX_LENSES="$2"; shift 2 ;;
    --deep-hunt-repair-rounds) nv "$#"; DEEP_HUNT_REPAIR_ROUNDS="$2"; shift 2 ;;
    --pattern-store)    nv "$#"; DEEP_FWD+=(--pattern-store "$2"); shift 2 ;;
    --replay-corpus)    DEEP_FWD+=(--replay-corpus); shift ;;
    --corpus-max)       nv "$#"; DEEP_FWD+=(--corpus-max "$2"); shift 2 ;;
    --symbolic-oracle)  DEEP_FWD+=(--symbolic-oracle); shift ;;
    --symbolic-timeout) nv "$#"; DEEP_FWD+=(--symbolic-timeout "$2"); shift 2 ;;
    --core-dep-harness) DEEP_FWD+=(--core-dep-harness); shift ;;
    --ensemble-candidates) nv "$#"; DEEP_FWD+=(--ensemble-candidates "$2"); shift 2 ;;
    --zone-cell-budget) nv "$#"; ZONE_CELL_BUDGET="$2"; shift 2 ;;
    --run-cell-budget)  nv "$#"; RUN_CELL_BUDGET="$2"; shift 2 ;;
    --require-coverage) nv "$#"; REQUIRE_COVERAGE="$2"; shift 2 ;;
    --rehunt-gaps)      REHUNT_GAPS=1; shift ;;
    --rehunt-include-partial) REHUNT_INCLUDE_PARTIAL=1; shift ;;
    --rehunt-max-attempts) nv "$#"; REHUNT_MAX_ATTEMPTS="$2"; shift 2 ;;
    --drop-dir)         nv "$#"; DROP_DIR="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-zone-hunt.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "run-zone-hunt.sh: --repo <cloned repo dir> required (clone it with fetch-target.sh)" >&2; exit 2; }
case "$JOBS" in ''|*[!0-9]*) echo "run-zone-hunt.sh: --jobs must be a positive integer (got '$JOBS')" >&2; exit 2 ;; esac
[ "$JOBS" -ge 1 ] || { echo "run-zone-hunt.sh: --jobs must be >= 1 (got '$JOBS')" >&2; exit 2; }
[ -z "$MAP_FIXTURE" ]   || [ -f "$MAP_FIXTURE" ]   || { echo "run-zone-hunt.sh: --map-fixture not found: $MAP_FIXTURE" >&2; exit 2; }
[ -z "$BRIEF_FIXTURE" ] || [ -f "$BRIEF_FIXTURE" ] || { echo "run-zone-hunt.sh: --brief-fixture not found: $BRIEF_FIXTURE" >&2; exit 2; }
[ -z "$RESIDUALS" ]     || [ -f "$RESIDUALS" ]     || { echo "run-zone-hunt.sh: --audit-residuals not found: $RESIDUALS" >&2; exit 2; }
[ -z "$INV_FIXTURE" ]   || [ -f "$INV_FIXTURE" ]   || { echo "run-zone-hunt.sh: --invariant-fixture not found: $INV_FIXTURE" >&2; exit 2; }
case "$DEEP_HUNT_MAX_TARGETS" in ''|*[!0-9]*) echo "run-zone-hunt.sh: --deep-hunt-max-targets must be a positive integer (got '$DEEP_HUNT_MAX_TARGETS')" >&2; exit 2 ;; esac
[ "$DEEP_HUNT_MAX_TARGETS" -ge 1 ] || { echo "run-zone-hunt.sh: --deep-hunt-max-targets must be >= 1 (got '$DEEP_HUNT_MAX_TARGETS')" >&2; exit 2; }
case "$DEEP_HUNT_AUX_MAX" in ''|*[!0-9]*) echo "run-zone-hunt.sh: --deep-hunt-aux-max must be a non-negative integer (got '$DEEP_HUNT_AUX_MAX')" >&2; exit 2 ;; esac
case "$DEEP_HUNT_MAX_LENSES" in ''|*[!0-9]*) echo "run-zone-hunt.sh: --deep-hunt-max-lenses must be a positive integer (got '$DEEP_HUNT_MAX_LENSES')" >&2; exit 2 ;; esac
[ "$DEEP_HUNT_MAX_LENSES" -ge 1 ] || { echo "run-zone-hunt.sh: --deep-hunt-max-lenses must be >= 1 (got '$DEEP_HUNT_MAX_LENSES')" >&2; exit 2; }
case "$DEEP_HUNT_REPAIR_ROUNDS" in ''|*[!0-9]*) echo "run-zone-hunt.sh: --deep-hunt-repair-rounds must be a positive integer (got '$DEEP_HUNT_REPAIR_ROUNDS')" >&2; exit 2 ;; esac
[ "$DEEP_HUNT_REPAIR_ROUNDS" -ge 1 ] || { echo "run-zone-hunt.sh: --deep-hunt-repair-rounds must be >= 1 (got '$DEEP_HUNT_REPAIR_ROUNDS')" >&2; exit 2; }
[ "$DEEP_HUNT_ONLY" -eq 0 ] || [ "$DEEP_HUNT" -eq 1 ] || { echo "run-zone-hunt.sh: --deep-hunt-only requires --deep-hunt" >&2; exit 2; }
# #1830: the budget/re-hunt knobs use the same integer validation + exit-2 shape as every flag above.
case "$ZONE_CELL_BUDGET" in ''|*[!0-9]*) echo "run-zone-hunt.sh: --zone-cell-budget must be a non-negative integer (got '$ZONE_CELL_BUDGET')" >&2; exit 2 ;; esac
case "$RUN_CELL_BUDGET" in ''|*[!0-9]*) echo "run-zone-hunt.sh: --run-cell-budget must be a non-negative integer (got '$RUN_CELL_BUDGET')" >&2; exit 2 ;; esac
case "$REHUNT_MAX_ATTEMPTS" in ''|*[!0-9]*) echo "run-zone-hunt.sh: --rehunt-max-attempts must be a positive integer (got '$REHUNT_MAX_ATTEMPTS')" >&2; exit 2 ;; esac
[ "$REHUNT_MAX_ATTEMPTS" -ge 1 ] || { echo "run-zone-hunt.sh: --rehunt-max-attempts must be >= 1 (got '$REHUNT_MAX_ATTEMPTS')" >&2; exit 2; }
if [ -n "$REQUIRE_COVERAGE" ]; then
  case "$REQUIRE_COVERAGE" in ''|*[!0-9]*) echo "run-zone-hunt.sh: --require-coverage must be an integer percentage 0-100 (got '$REQUIRE_COVERAGE')" >&2; exit 2 ;; esac
  [ "$REQUIRE_COVERAGE" -le 100 ] || { echo "run-zone-hunt.sh: --require-coverage must be an integer percentage 0-100 (got '$REQUIRE_COVERAGE')" >&2; exit 2; }
fi
[ "$REHUNT_INCLUDE_PARTIAL" -eq 0 ] || [ "$REHUNT_GAPS" -eq 1 ] || { echo "run-zone-hunt.sh: --rehunt-include-partial requires --rehunt-gaps" >&2; exit 2; }
# The two re-use modes are deliberately NOT combinable: --deep-hunt-only re-applies the lens over a breadth
# --out while --rehunt-gaps re-enters breadth itself, and STAGE 4 would overwrite the lens's merged findings.
[ "$REHUNT_GAPS" -eq 0 ] || [ "$DEEP_HUNT_ONLY" -eq 0 ] || { echo "run-zone-hunt.sh: --rehunt-gaps cannot be combined with --deep-hunt-only" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "run-zone-hunt.sh: python3 not installed" >&2; exit 3; }

MAPZONES="$HERE/map-zones.sh"
GENBRIEFS="$HERE/gen-briefs.sh"
DISCOVERY="$HERE/run-discovery.sh"
VERIFY="$HERE/verify-findings.sh"
AUDITPASS="$HERE/run-audit-pass.sh"
DELIVER="$HERE/deliver-submission.sh"
for tool in "$MAPZONES" "$GENBRIEFS" "$DISCOVERY" "$VERIFY" "$AUDITPASS" "$DELIVER"; do
  [ -x "$tool" ] || { echo "run-zone-hunt.sh: required entrypoint not found/executable: $tool" >&2; exit 3; }
done
# #1830: the coverage record's sole owner (schema, the eight-state vocabulary, the #1826 priority sort).
ZONECOV="$HERE/lib/zone-coverage.py"
[ -f "$ZONECOV" ] || { echo "run-zone-hunt.sh: required helper not found: $ZONECOV" >&2; exit 3; }

REPO="$(cd "$REPO" && pwd)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
[ -n "$DROP_DIR" ] || DROP_DIR="$OUT/drop"
[ -z "$MAP_FIXTURE" ]   || MAP_FIXTURE="$(cd "$(dirname "$MAP_FIXTURE")" && pwd)/$(basename "$MAP_FIXTURE")"
[ -z "$BRIEF_FIXTURE" ] || BRIEF_FIXTURE="$(cd "$(dirname "$BRIEF_FIXTURE")" && pwd)/$(basename "$BRIEF_FIXTURE")"
[ -z "$RESIDUALS" ]     || RESIDUALS="$(cd "$(dirname "$RESIDUALS")" && pwd)/$(basename "$RESIDUALS")"
[ -z "$INV_FIXTURE" ]   || INV_FIXTURE="$(cd "$(dirname "$INV_FIXTURE")" && pwd)/$(basename "$INV_FIXTURE")"

REPO_NAME="$(basename "$REPO")"
COMMIT="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# The scope context handed to run-audit-pass.sh's scope gate (--in-scope): the in-scope program facts, plus the
# optional asset-contract and impact-threshold intake facts when supplied (they inform the scope decision).
SCOPE_CONTEXT="$IN_SCOPE"
if [ -n "$ASSET_CONTRACTS" ]; then
  SCOPE_CONTEXT="${SCOPE_CONTEXT}${SCOPE_CONTEXT:+ | }asset contracts: $ASSET_CONTRACTS"
fi
if [ -n "$IMPACT_THRESHOLD" ]; then
  SCOPE_CONTEXT="${SCOPE_CONTEXT}${SCOPE_CONTEXT:+ | }impact threshold: $IMPACT_THRESHOLD"
fi

# ----------------------------------------------------------------------------------------------------------
# STAGE 1 (M1): map-zones.sh -> <out>/map/zones.json + scope.tsv. --map-fixture => offline; else live substrate.
#
# #1774: the whole breadth block (M1..M4) is gated on --deep-hunt-only being OFF (the default). When
# --deep-hunt-only is set we SKIP M1..M4 entirely and instead REUSE an existing breadth --out — deriving the
# same MAP/VER/VERIFIED_JSON paths STAGE 4.5 reads/appends and asserting the two artifacts already exist —
# then fall straight through to the UNCHANGED STAGE 4.5 lens. Default (off) => M1..M4 run exactly as before.
# ----------------------------------------------------------------------------------------------------------
if [ "$DEEP_HUNT_ONLY" -eq 0 ]; then
MAP="$OUT/map"
BRIEFS="$OUT/briefs"
# #1830: the coverage record is a CONTRACT, so its path is fixed (no flag). <out>/coverage/zone-coverage.json.
COVERAGE_DIR="$OUT/coverage"; COVERAGE_JSON="$COVERAGE_DIR/zone-coverage.json"
if [ "$REHUNT_GAPS" -eq 1 ]; then
  # #1830 --rehunt-gaps: STAGE 1/2 are SKIPPED — the map, the scope manifest, the per-zone briefs and the
  # coverage record all come from the existing --out. Assert each one by name (the #1774 prerequisite-guard
  # shape) so a re-hunt against the wrong --out fails loud instead of silently re-mapping.
  for _pre in "$MAP/zones.json" "$MAP/scope.tsv" "$BRIEFS/briefs" "$COVERAGE_JSON"; do
    [ -e "$_pre" ] || { echo "run-zone-hunt.sh: --rehunt-gaps requires an existing $_pre (run the full breadth pass first)" >&2; exit 3; }
  done
  echo "run-zone-hunt.sh: [M3] --rehunt-gaps: reusing $MAP + $BRIEFS; STAGE 1/2 skipped" >&2
else
echo "run-zone-hunt.sh: [M1] mapping zones -> $MAP ..." >&2
if [ -n "$MAP_FIXTURE" ]; then
  "$MAPZONES" --repo "$REPO" --out "$MAP" ${SCOPE_HINT:+--scope-hint "$SCOPE_HINT"} ${SINCE:+--since "$SINCE"} \
    --fixture "$MAP_FIXTURE"
else
  "$MAPZONES" --repo "$REPO" --out "$MAP" ${SCOPE_HINT:+--scope-hint "$SCOPE_HINT"} ${SINCE:+--since "$SINCE"} \
    --backend "$BACKEND" --agentis "$AGENTIS"
fi
[ -f "$MAP/zones.json" ] && [ -f "$MAP/scope.tsv" ] || { echo "run-zone-hunt.sh: map-zones.sh did not emit zones.json + scope.tsv" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# STAGE 2 (M2): gen-briefs.sh -> <out>/briefs/briefs/brief_<id>.md per zone. --brief-fixture => offline.
# ----------------------------------------------------------------------------------------------------------
echo "run-zone-hunt.sh: [M2] generating per-zone briefs -> $BRIEFS ..." >&2
if [ -n "$BRIEF_FIXTURE" ]; then
  "$GENBRIEFS" --zones "$MAP/zones.json" --scope "$MAP/scope.tsv" --out "$BRIEFS" --repo "$REPO" \
    ${RESIDUALS:+--audit-residuals "$RESIDUALS"} --fixture "$BRIEF_FIXTURE"
else
  "$GENBRIEFS" --zones "$MAP/zones.json" --scope "$MAP/scope.tsv" --out "$BRIEFS" --repo "$REPO" \
    ${RESIDUALS:+--audit-residuals "$RESIDUALS"} --backend "$BACKEND" --agentis "$AGENTIS"
fi
[ -f "$BRIEFS/briefs/zone_briefs.json" ] || { echo "run-zone-hunt.sh: gen-briefs.sh did not emit zone_briefs.json" >&2; exit 3; }
fi

# ----------------------------------------------------------------------------------------------------------
# STAGE 3 (M3): per-zone run-discovery.sh, each with its OWN zone brief; merge into discovery-results.merged.json.
# Zones loop SERIALLY (the intra-zone --jobs is the only parallelism — the M3 OOM cap is not stacked across zones).
# Priority order: value-custody zones first (tie-broken by zone id), then everything else, so a truncated run
# only ever drops the lowest-priority (non-custody) zones (#1826).
#
# #1830: the loop is now driven by, and reports into, the COVERAGE RECORD (lib/zone-coverage.py). `init` writes
# <out>/coverage/zone-coverage.json with EVERY zone `not_reached` — and emits the #1826-ordered .zone-list.tsv
# from the same sorted list, so record order and hunt order cannot drift — BEFORE the first zone runs. Each
# zone is then set `in_flight` immediately before its run-discovery.sh call and rewritten to its terminal state
# after, so absence is never representable: an externally-killed run still leaves a truthful record on disk.
# Under --rehunt-gaps the work list comes from the record (`gaps`) instead, and STAGE 1/2 were skipped above.
# ----------------------------------------------------------------------------------------------------------
DISC="$OUT/discovery"; mkdir -p "$DISC"
ZONE_LIST="$OUT/.zone-list.tsv"
mkdir -p "$COVERAGE_DIR"
ZONE_WORK="$OUT/.zone-work.tsv"
if [ "$REHUNT_GAPS" -eq 1 ]; then
  # TSV `<zid> <name> <action> <next-attempt>`; actions: hunt | retry | capped | no-brief (see the helper).
  if [ "$REHUNT_INCLUDE_PARTIAL" -eq 1 ]; then
    "$ZONECOV" gaps --file "$COVERAGE_JSON" --max-attempts "$REHUNT_MAX_ATTEMPTS" --include-partial > "$ZONE_WORK"
  else
    "$ZONECOV" gaps --file "$COVERAGE_JSON" --max-attempts "$REHUNT_MAX_ATTEMPTS" > "$ZONE_WORK"
  fi
else
  "$ZONECOV" init --zones "$MAP/zones.json" --out "$COVERAGE_JSON" --zone-list "$ZONE_LIST" \
    --repo "$REPO_NAME" --commit "$COMMIT" \
    --zone-cell-budget "$ZONE_CELL_BUDGET" --run-cell-budget "$RUN_CELL_BUDGET"
  # The full sweep's work list IS the priority order; the missing 3rd/4th columns default to a plain `hunt`.
  cp "$ZONE_LIST" "$ZONE_WORK"
fi

CELL_PROBE="$OUT/.zone-cell-probe.txt"
RUN_SPENT=0 ; BUDGET_STOP=0
while IFS='	' read -r ZID ZNAME ZACTION ZATTEMPT || [ -n "${ZID:-}" ]; do
  [ -n "$ZID" ] || continue
  [ -n "${ZACTION:-}" ] || ZACTION="hunt"
  # `no_brief` is an UPSTREAM defect, never collapsed into a retryable failure; a capped zone is left alone so
  # one --rehunt-gaps pass is exactly one pass over the gap set, never a loop. Both stay in gap_zones.
  if [ "$ZACTION" = "no-brief" ]; then
    echo "run-zone-hunt.sh: [M3] zone '$ZID' has no brief — a re-hunt cannot fix this (re-run without --rehunt-gaps)" >&2
    continue
  fi
  if [ "$ZACTION" = "capped" ]; then
    echo "run-zone-hunt.sh: [M3] zone '$ZID' already has >= $REHUNT_MAX_ATTEMPTS attempt(s); leaving it alone" >&2
    "$ZONECOV" set --file "$COVERAGE_JSON" --zone "$ZID" --detail "attempt cap reached"
    continue
  fi
  if [ "$BUDGET_STOP" -eq 1 ]; then
    "$ZONECOV" set --file "$COVERAGE_JSON" --zone "$ZID" --status budget_exhausted --cells-charged 0 \
      --detail "admission denied: the run cell budget was already exhausted"
    continue
  fi
  ZBRIEF="$BRIEFS/briefs/brief_${ZID}.md"
  if [ ! -f "$ZBRIEF" ]; then
    echo "run-zone-hunt.sh: [M3] zone '$ZNAME' ($ZID) has no brief at $ZBRIEF; skipping" >&2
    "$ZONECOV" set --file "$COVERAGE_JSON" --zone "$ZID" --status no_brief \
      --detail "STAGE 2 emitted no briefs/briefs/brief_${ZID}.md"
    continue
  fi
  # The zone's PLANNED cell count comes from the shipped #1612 dry run — a pure manifest parse that returns
  # before the agentis-binary check, so it needs no binary, no LLM and no network. A probe failure degrades to
  # cells_planned: null + a detail string; it never blocks the hunt.
  CELLS_PLANNED="" ; CLASSES_ALL=""
  if "$DISCOVERY" --repo "$REPO" --scope "$MAP/scope.tsv" --only "$ZNAME" --list-cells > "$CELL_PROBE" 2>/dev/null; then
    CELLS_PLANNED="$(grep -c '^CELL|' "$CELL_PROBE" || true)"
    CLASSES_ALL="$(grep '^CELL|' "$CELL_PROBE" | cut -d'|' -f3 | tr '\n' ',' | sed 's/,$//')"
  fi
  # ADMISSION (one uniform rule): effective cap = min(zone budget or inf, run budget - spent or inf). Both
  # budgets 0 (the default) => ZCAP stays empty = unbounded => the invocation below gains NO argument.
  ZCAP=""
  if [ "$ZONE_CELL_BUDGET" -gt 0 ]; then ZCAP="$ZONE_CELL_BUDGET"; fi
  if [ "$RUN_CELL_BUDGET" -gt 0 ]; then
    ZREMAIN=$((RUN_CELL_BUDGET - RUN_SPENT))
    [ "$ZREMAIN" -ge 0 ] || ZREMAIN=0
    if [ -z "$ZCAP" ] || [ "$ZREMAIN" -lt "$ZCAP" ]; then ZCAP="$ZREMAIN"; fi
  fi
  if [ -n "$ZCAP" ] && [ "$ZCAP" -eq 0 ]; then
    # The FIRST denial STOPS the loop: best-effort packing (skip an expensive high-priority zone, admit a
    # cheap low-priority one) would silently invert the #1826 value-custody-first order. Explicit non-goal.
    echo "run-zone-hunt.sh: [M3] zone '$ZNAME' ($ZID) DENIED — the cell budget is spent; it and every remaining zone are recorded budget_exhausted" >&2
    "$ZONECOV" set --file "$COVERAGE_JSON" --zone "$ZID" --status budget_exhausted \
      --cells-planned "${CELLS_PLANNED:-null}" --cells-charged 0 --classes "$CLASSES_ALL" \
      --detail "admission denied: 0 cells of budget remaining"
    BUDGET_STOP=1
    continue
  fi
  ZCHARGE="${CELLS_PLANNED:-0}" ; ZCLASSES_ARG="" ; ZTRUNC="" ; ZDETAIL=""
  if [ -z "$CELLS_PLANNED" ]; then
    ZDETAIL="--list-cells probe failed; planned cell count unknown"
    if [ "$RUN_CELL_BUDGET" -gt 0 ]; then
      # Conservative: an unmeasurable zone is admitted, charged the WHOLE remaining run budget, and is the
      # last zone admitted — an unknown cost may not silently eat the zones behind it.
      ZCHARGE=$((RUN_CELL_BUDGET - RUN_SPENT))
      [ "$ZCHARGE" -ge 0 ] || ZCHARGE=0
      BUDGET_STOP=1
    else
      ZCHARGE=0
    fi
  elif [ -n "$ZCAP" ] && [ "$ZCAP" -lt "$CELLS_PLANNED" ]; then
    # Shorten the class list to the first ZCAP classes. scope.tsv order IS the mapper's relevance order, so
    # the classes dropped are the least likely ones.
    ZCLASSES_ARG="$(printf '%s' "$CLASSES_ALL" | cut -d',' -f1-"$ZCAP")"
    ZCHARGE="$ZCAP"
    ZTRUNC="1"
    ZDETAIL="per-zone cap $ZCAP < $CELLS_PLANNED planned cell(s); class list shortened"
  fi
  if [ "$ZACTION" = "retry" ]; then
    # failed / in_flight (and an --rehunt-include-partial partial) carry PRIOR ARTIFACTS that run-discovery.sh
    # destroys on re-entry (`rm -rf $RUN`, `> $REPORT`). Move them aside FIRST, then push the prior terminal
    # state into attempts[] — the failure evidence survives and attempts[] is the give-up input.
    if [ -d "$DISC/$ZID" ]; then
      rm -rf "$DISC/$ZID.attempt-${ZATTEMPT:-1}"
      mv "$DISC/$ZID" "$DISC/$ZID.attempt-${ZATTEMPT:-1}"
    fi
    "$ZONECOV" retry --file "$COVERAGE_JSON" --zone "$ZID" --artifacts "discovery/$ZID.attempt-${ZATTEMPT:-1}"
  fi
  echo "run-zone-hunt.sh: [M3] hunting zone '$ZNAME' ($ZID) with its brief ..." >&2
  ZCLASSES_REC="$CLASSES_ALL"
  if [ -n "$ZTRUNC" ]; then
    ZCLASSES_REC="$ZCLASSES_ARG"
    "$ZONECOV" set --file "$COVERAGE_JSON" --zone "$ZID" --status in_flight \
      --cells-planned "${CELLS_PLANNED:-null}" --cells-charged "$ZCHARGE" --classes "$ZCLASSES_REC" \
      --budget-truncated --detail "$ZDETAIL"
  else
    "$ZONECOV" set --file "$COVERAGE_JSON" --zone "$ZID" --status in_flight \
      --cells-planned "${CELLS_PLANNED:-null}" --cells-charged "$ZCHARGE" --classes "$ZCLASSES_REC" \
      --detail "$ZDETAIL"
  fi
  RUN_SPENT=$((RUN_SPENT + ZCHARGE))
  ZRC=0
  "$DISCOVERY" --repo "$REPO" --scope "$MAP/scope.tsv" --only "$ZNAME" --brief "$ZBRIEF" \
    --jobs "$JOBS" --backend "$BACKEND" --agentis "$AGENTIS" --out "$DISC/$ZID" \
    ${ZCLASSES_ARG:+--classes "$ZCLASSES_ARG"} \
    || ZRC=$?
  if [ "$ZRC" -eq 0 ]; then
    # The terminal status (hunted / hunted_empty / hunted_degraded) is DERIVED in the helper from this zone's
    # own totals — the derivation exists in exactly one place, so no consumer re-implements the policy.
    "$ZONECOV" set --file "$COVERAGE_JSON" --zone "$ZID" --exit-code 0 --results "$DISC/$ZID/discovery-results.json"
  else
    echo "run-zone-hunt.sh: [M3] discovery failed for zone '$ZNAME' ($ZID); continuing" >&2
    "$ZONECOV" set --file "$COVERAGE_JSON" --zone "$ZID" --status failed --exit-code "$ZRC" \
      --detail "run-discovery.sh exited $ZRC"
  fi
done < "$ZONE_WORK"

MERGED="$DISC/discovery-results.merged.json"
# #1830: the merge embeds the record's ALREADY-DERIVED coverage fields (it never re-derives them) so a consumer
# that reads only the merged file can see a truncation, and propagates the per-zone totals.failed the merge
# used to drop (#1707 degraded cells vanished with it).
COVERAGE_FRAGMENT="$("$ZONECOV" summary --file "$COVERAGE_JSON" --json)"
python3 - "$MERGED" "$DISC" "$REPO_NAME" "$BACKEND" "$JOBS" "$COVERAGE_FRAGMENT" <<'PY'
import sys, os, json, glob
merged_path, disc_dir, repo, backend, jobs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
coverage = json.loads(sys.argv[6])
cells, tc, tcand, ts, tf = [], 0, 0, 0, 0
for zid in sorted(os.listdir(disc_dir)):
    # #1830: `<zid>.attempt-<n>` dirs are PRESERVED EVIDENCE from a prior attempt, not a zone — counting them
    # would double-count a re-hunt. Zone ids are `[^A-Za-z0-9]+ -> _` slugs, so they never contain a dot.
    if ".attempt-" in zid:
        continue
    p = os.path.join(disc_dir, zid, "discovery-results.json")
    if not os.path.isfile(p):
        continue
    try:
        d = json.load(open(p, encoding="utf-8"))
    except Exception:
        continue
    cells.extend(d.get("cells", []))
    t = d.get("totals", {})
    tc += int(t.get("cells", 0)); tcand += int(t.get("candidates", 0)); ts += int(t.get("steers", 0))
    tf += int(t.get("failed", 0))
out = {"repo": repo, "backend": backend, "jobs": jobs, "cells": cells,
       "totals": {"cells": tc, "candidates": tcand, "steers": ts, "failed": tf},
       "coverage": coverage}
json.dump(out, open(merged_path, "w", encoding="utf-8"), indent=2)
open(merged_path, "a", encoding="utf-8").write("\n")
print("run-zone-hunt.sh: [M3] merged %d cell(s), %d candidate(s) from %d zone(s)" % (tc, tcand, len(cells)), file=sys.stderr)
PY
[ -f "$MERGED" ] || { echo "run-zone-hunt.sh: merge produced no discovery-results.merged.json" >&2; exit 3; }

# FAIL-LOUD (#1830, always on): an incomplete record prints the COVERAGE GAP banner + a per-status breakdown.
# A clean sweep prints nothing here, so the banner is signal, not noise.
"$ZONECOV" summary --file "$COVERAGE_JSON" >&2
COVERAGE_COUNTS="$("$ZONECOV" summary --file "$COVERAGE_JSON" --counts)"
ZONES_COVERED="${COVERAGE_COUNTS%% *}" ; ZONES_TOTAL="${COVERAGE_COUNTS##* }"
echo "run-zone-hunt.sh: [M3] coverage: $ZONES_COVERED/$ZONES_TOTAL zone(s) covered — record: $COVERAGE_JSON" >&2

# Opt-in gate (default OFF): halt BEFORE verify/deliver when the run covered too little, so a degraded run
# cannot produce a plausible-looking result set. The record is already on disk when this aborts.
if [ -n "$REQUIRE_COVERAGE" ] && [ "$ZONES_TOTAL" -gt 0 ] \
   && [ $((ZONES_COVERED * 100)) -lt $((REQUIRE_COVERAGE * ZONES_TOTAL)) ]; then
  echo "run-zone-hunt.sh: [M3] --require-coverage $REQUIRE_COVERAGE not met ($ZONES_COVERED/$ZONES_TOTAL zone(s) covered); halting before STAGE 4/5" >&2
  exit 4
fi

# ----------------------------------------------------------------------------------------------------------
# STAGE 4 (M4): verify-findings.sh over the merged candidates -> <out>/verify/verified_findings.json (CONFIRMED only).
# ----------------------------------------------------------------------------------------------------------
VER="$OUT/verify"
echo "run-zone-hunt.sh: [M4] verifying candidates (refute gate) -> $VER ..." >&2
"$VERIFY" --results "$MERGED" --repo "$REPO" --gate refute --backend "$BACKEND" --agentis "$AGENTIS" --out "$VER"
VERIFIED_JSON="$VER/verified_findings.json"
[ -f "$VERIFIED_JSON" ] || { echo "run-zone-hunt.sh: verify-findings.sh did not emit verified_findings.json" >&2; exit 3; }
else
  # #1774 --deep-hunt-only: M1..M4 were skipped — REUSE the existing breadth --out. Derive the exact paths the
  # UNCHANGED STAGE 4.5 lens reads ($MAP/zones.json) and appends to ($VERIFIED_JSON), and assert they exist.
  MAP="$OUT/map"; VER="$OUT/verify"; VERIFIED_JSON="$VER/verified_findings.json"
  [ -f "$MAP/zones.json" ] || { echo "run-zone-hunt.sh: --deep-hunt-only requires an existing $MAP/zones.json (run breadth first)" >&2; exit 3; }
  [ -f "$VERIFIED_JSON" ] || { echo "run-zone-hunt.sh: --deep-hunt-only requires an existing $VERIFIED_JSON (run breadth first)" >&2; exit 3; }
fi

# ----------------------------------------------------------------------------------------------------------
# STAGE 4.5 (#1713): SEVERITY-FIRST DEEP-HUNT — a SECOND lens on the VALUE-CUSTODY zones. Default OFF (no
# --deep-hunt => this whole block is skipped and the run is byte-identical to before). It runs the shipped
# stateful-invariant engine (run-invariant-hunt.sh, UNCHANGED) on each value_custody zone's primary target
# and MERGES every fuzzer-reproduced FINDING into verified_findings.json — tagged source=invariant-hunt —
# so M5 below and corpus-bench score the deep finding alongside the breadth findings. Gated on a Foundry
# target ($REPO/foundry.toml): EVM invariant-fuzzing is Foundry-specific; a non-Foundry target logs + skips.
# ZERO new egress — run-invariant-hunt.sh never submits and the merge is a local file read/write.
# ----------------------------------------------------------------------------------------------------------
if [ "$DEEP_HUNT" -eq 1 ]; then
  if [ ! -f "$REPO/foundry.toml" ]; then
    echo "run-zone-hunt.sh: [deep-hunt] --deep-hunt set but $REPO has no foundry.toml (EVM invariant-fuzzing is Foundry-specific) — skipping deep-hunt" >&2
  else
    INVHUNT="$HERE/run-invariant-hunt.sh"
    [ -x "$INVHUNT" ] || { echo "run-zone-hunt.sh: [deep-hunt] required entrypoint not found/executable: $INVHUNT" >&2; exit 3; }
    DEEP="$OUT/deep-hunt"; mkdir -p "$DEEP"
    # Enumerate the value-custody zones + their ONE primary target (the largest-by-line-count .sol in the
    # zone's files, lexicographic tie-break; bounded to --deep-hunt-max-targets per zone) + the zone's
    # dominant custody class (prefer C6/C10/C11, else the literal C-invariant). TSV: zid \t relfile \t class.
    # #1726 (M2): when --deep-hunt-aux-max > 0, a 4th column carries the comma-joined next up-to-N largest
    # co-custody .sol (the secondary contracts for a SYSTEM invariant). When 0 (default) NO 4th column is
    # emitted — every row is byte-identical to before, so single-target deep-hunt runs are unchanged.
    # #1795: a zone now emits ONE ROW PER APPLICABLE LENS CLASS (bounded by --deep-hunt-max-lenses), not one row
    # for its single dominant class — see lens_classes() below.
    DEEP_TARGETS="$OUT/.deep-hunt-targets.tsv"
    python3 - "$MAP/zones.json" "$REPO" "$DEEP_HUNT_MAX_TARGETS" "$DEEP_HUNT_AUX_MAX" "$DEEP_HUNT_MAX_LENSES" > "$DEEP_TARGETS" <<'PY'
import sys, os, json
zones = json.load(open(sys.argv[1], encoding="utf-8"))
repo, max_targets, aux_max = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
max_lenses = int(sys.argv[5])
if not isinstance(zones, list):
    zones = []
def loc(rel):
    try:
        with open(os.path.join(repo, rel), encoding="utf-8", errors="ignore") as fh:
            return sum(1 for _ in fh)
    except Exception:
        return 0
# #1795: SINGLE SOURCE OF TRUTH for the implemented lens classes — the custody-primary codes and the
# non-value-custody codes, in coverage-map rarity/precedence order. dominant_class(), the non-custody selection
# gate and the multi-lens fan-out below all derive from these two tuples; never restate the literals.
CUSTODY_PRIMARY_CLASSES = ("C6", "C10", "C11")
# #1790: IMPLEMENTED non-value-custody lens classes — a zone that is NOT value_custody is still a deep-hunt
# target when one of these applies (the lens has templates for it). Without this, the gate below dropped every
# non-custody zone BEFORE class routing, so #1786's oracle (C2) lens — and every future class lens — never fired
# on a non-custody zone. Grow this tuple as class lenses land: C16 (liveness #1789) and C5 (access-control
# #1785) join C2 here so their zones are actually selected and hunted.
IMPLEMENTED_NONCUSTODY = ("C2", "C16", "C5")
IMPLEMENTED_LENS_CLASSES = CUSTODY_PRIMARY_CLASSES + IMPLEMENTED_NONCUSTODY
def dominant_class(classes):
    # #1783: C2 (Oracle integrity) is appended AFTER the C6/C10/C11 value-custody-primary codes, so it wins
    # only when no value-custody-primary class is present — byte-identical routing for every zone that has
    # C6/C10/C11, and an oracle-dependent zone (C2 but no custody-primary code) now routes to the oracle lens
    # (--class C2 -> prover class_to_keyword "oracle" -> is_oracle_dependent) instead of the generic C-invariant.
    # #1784: C16 (State-machine liveness / stuck-state) is appended AFTER C2, so a liveness-only zone (C16 but no
    # value-custody-primary or oracle code) routes to the arithmetic-overflow / liveness (DoS) lens
    # (--class C16 -> prover class_to_keyword "liveness" -> is_liveness_sensitive); byte-identical routing for
    # every zone that has C6/C10/C11/C2.
    # #1785: C5 (Access control / role model) is appended AFTER C16, so an access-only zone (C5 but no
    # value-custody-primary, oracle or liveness code) routes to the access-control / privilege lens
    # (--class C5 -> prover class_to_keyword "access" -> is_access_sensitive); byte-identical routing for
    # every zone that has C6/C10/C11/C2/C16.
    for c in IMPLEMENTED_LENS_CLASSES:
        if c in classes:
            return c
    return "C-invariant"
def lens_classes(z):
    # #1795: EVERY applicable implemented lens for the zone, most-precedent first, capped at max_lenses.
    # Before #1795 a zone got exactly ONE lens — its dominant_class — so on a value-custody zone the
    # custody-first precedence SHADOWED the non-custody lenses: yieldoor/plaza `src` are value_custody AND
    # carry C2, yet only the custody lens ever ran, making their oracle bugs structurally unreachable.
    # Row 1 is UNCHANGED (the dominant_class the zone got before, under the same custody/non-custody gate), so
    # nothing regresses; the extra rows are the applicable non-custody lenses that used to be dropped.
    classes = z.get("bug_classes_likely", [])
    dclass = dominant_class(classes)
    out = []
    if z.get("value_custody"):
        # a value-custody zone always keeps its custody-primary row (or the generic C-invariant) FIRST
        out.append(dclass)
    elif dclass in IMPLEMENTED_NONCUSTODY:
        # #1790 non-custody gate: unchanged first row for a zone whose dominant class is an implemented lens
        out.append(dclass)
    for c in IMPLEMENTED_NONCUSTODY:
        if c in classes and c not in out:
            out.append(c)
    return out[:max_lenses]
def has_impl_sol(z):
    # a fuzzable IMPLEMENTATION contract exists in the zone — not an interface-only zone. Interface .sol
    # (under an interfaces/ dir, or the `IName` convention) has no body to deploy/fuzz => a guaranteed
    # HARNESS_ERROR, so an interface-only non-custody zone is not a useful deep-hunt target.
    for f in z.get("files", []):
        if not (isinstance(f, str) and f.endswith(".sol")):
            continue
        base = f.rsplit("/", 1)[-1]
        if "/interfaces/" in f or "/interface/" in f:
            continue
        if len(base) >= 2 and base[0] == "I" and base[1].isupper():
            continue
        return True
    return False
for z in zones:
    lenses = lens_classes(z)
    if not lenses:
        continue
    if not z.get("value_custody") and not has_impl_sol(z):
        continue
    zid = z.get("id", "")
    if not zid:
        continue
    sols = [f for f in z.get("files", []) if isinstance(f, str) and f.endswith(".sol")]
    if not sols:
        continue
    # largest by line count; lexicographic tie-break (smallest name wins on equal loc)
    ranked = sorted(sols, key=lambda f: (-loc(f), f))
    for rel in ranked[:max_targets]:
        # #1795: one row per applicable lens class — the FIRST is the class this zone got before #1795.
        for dclass in lenses:
            # #1726 (M2): aux-max == 0 => byte-identical 3-column row (single-target). aux-max > 0 => append a 4th
            # column with the next up-to-aux_max largest co-custody .sol (this zone's secondary contracts).
            if aux_max > 0:
                aux = [f for f in ranked if f != rel][:aux_max]
                auxcol = ",".join(a.replace("\t", " ") for a in aux)
                print("%s\t%s\t%s\t%s" % (zid.replace("\t", " "), rel.replace("\t", " "), dclass, auxcol))
            else:
                print("%s\t%s\t%s" % (zid.replace("\t", " "), rel.replace("\t", " "), dclass))
PY
    DEEP_FINDINGS=0
    while IFS='	' read -r ZID RELFILE DCLASS AUXFILES || [ -n "${ZID:-}" ]; do
      [ -n "$ZID" ] || continue
      # #1726 (M2): split the comma-joined AUXFILES column (present only when --deep-hunt-aux-max > 0) into
      # distinct `--aux <rel>` argv elements — one per SECONDARY co-custody contract — reusing the shipped
      # composable-fresh multi-contract engine (run-invariant-hunt.sh --aux -> INV_AUX -> compose_fresh_seed
      # -> multi-register targetContracts() -> #1077 both-real enforcement). Empty AUXFILES (the default
      # aux-max=0 path) leaves the arg list empty, so both $INVHUNT invocations are byte-identical to the
      # single-target path. All contract iteration stays here in the shell runner (never a per-element .ag loop).
      set --
      if [ -n "${AUXFILES:-}" ]; then
        _aux_old_ifs="$IFS"; IFS=','
        # shellcheck disable=SC2086  # intentional word-split of the comma-joined aux list into distinct args
        for _auxrel in $AUXFILES; do
          [ -n "$_auxrel" ] || continue
          set -- "$@" --aux "$_auxrel"
        done
        IFS="$_aux_old_ifs"
      fi
      echo "run-zone-hunt.sh: [deep-hunt] stateful-invariant lens on zone '$ZID' target '$RELFILE' ($DCLASS) ..." >&2
      # #1795: the out-dir is keyed per (ZONE, CLASS), not per zone — with the multi-lens fan-out two rows of
      # one zone would otherwise SHARE a run dir and their per-target `invariant_<t>.log` would collide, so the
      # #1780 merge adapter below (globs `invariant_*.log` under $DZOUT/run, filters the per-candidate
      # `_c<N>.log`) would read the wrong lens's verdict. The `deep-hunt/*/run/invariant_*.log` consumers
      # (generation-recall.sh, generalization-bench.sh) glob the zone level, so the suffix is transparent to them.
      DZOUT="$DEEP/$ZID-$DCLASS"
      if [ -n "$INV_FIXTURE" ]; then
        "$INVHUNT" --repo "$REPO" --target "$RELFILE" --class "$DCLASS" \
          --handler-fixture "$INV_FIXTURE" --backend "$BACKEND" --agentis "$AGENTIS" --out "$DZOUT" \
          --repair-rounds "$DEEP_HUNT_REPAIR_ROUNDS" "$@" ${DEEP_FWD[@]+"${DEEP_FWD[@]}"} \
          || { echo "run-zone-hunt.sh: [deep-hunt] run-invariant-hunt.sh failed for zone '$ZID' ($DCLASS); continuing" >&2; continue; }
      else
        "$INVHUNT" --repo "$REPO" --target "$RELFILE" --class "$DCLASS" \
          --backend "$BACKEND" --agentis "$AGENTIS" --out "$DZOUT" \
          --repair-rounds "$DEEP_HUNT_REPAIR_ROUNDS" "$@" ${DEEP_FWD[@]+"${DEEP_FWD[@]}"} \
          || { echo "run-zone-hunt.sh: [deep-hunt] run-invariant-hunt.sh failed for zone '$ZID' ($DCLASS); continuing" >&2; continue; }
      fi
      # Adapter: convert the engine's INVARIANT|<target>|FINDING + STEP| witness into a schema-compatible
      # verified[] entry (source=invariant-hunt) and APPEND it to verified_findings.json. Only a FINDING
      # verdict merges; CLEAN/HARNESS_ERROR is a logged no-op. score-match.py keys on verified[].location,
      # so location = <relfile>:<fn> (fn = first identifier-before-( in the STEP| sequence).
      MERGED_ADD="$(python3 - "$VERIFIED_JSON" "$DZOUT" "$RELFILE" "$DCLASS" <<'PY'
import sys, os, json, glob, re
verified_json, dzout, relfile, dclass = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
logs = sorted(glob.glob(os.path.join(dzout, "run", "invariant_*.log")))
# #1778 ensemble writes per-candidate logs `invariant_<t>_c<N>.log` ALONGSIDE the canonical
# aggregate `invariant_<t>.log` (which carries the ensemble-VOTE verdict + the winning candidate's
# STEP| witness). Read the AGGREGATE, never a per-candidate: `sorted()` is codepoint order, where
# `_` (0x5F) > `.` (0x2E), so `sorted()[-1]` would otherwise land on the last `_c<N>` CLEAN log and
# silently drop a real ensemble FINDING. Single-candidate/OFF runs emit only the aggregate, so this
# filter is a no-op there.
logs = [p for p in logs if not re.search(r"_c[0-9]+\.log$", os.path.basename(p))]
if not logs:
    print("0"); sys.exit(0)
verdict = None
inv_target = ""
steps = []
with open(logs[-1], encoding="utf-8", errors="ignore") as fh:
    for line in fh:
        if "INVARIANT|" in line:
            seg = line.split("INVARIANT|", 1)[1].strip()
            cols = seg.split("|")
            inv_target = cols[0].strip()
            if len(cols) >= 2:
                verdict = cols[1].strip()
        if line.startswith("STEP|"):
            steps.append(line[len("STEP|"):].rstrip("\n"))
if verdict != "FINDING":
    print("0"); sys.exit(0)
# fn = first identifier-before-( in the shrunk STEP| sequence; fall back to the contract-file stem.
fn = ""
for s in steps:
    m = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*\(", s)
    if m:
        fn = m.group(1); break
if not fn:
    fn = os.path.splitext(os.path.basename(relfile))[0]
steps_joined = " ; ".join(steps)
broken = "stateful invariant broken on " + (inv_target or relfile)
entry = {
    "location": "%s:%s" % (relfile, fn),
    "file": relfile,
    "class": dclass,
    "severity": "High",
    # exploit carries the broken-invariant text AND the joined STEP| names so score-match's technical-token
    # FALLBACK still matches when the primary location fn is imperfect.
    "exploit": (broken + " | " + steps_joined) if steps_joined else broken,
    "poc_sketch": steps_joined,
    "verdict": "FINDING",
    "reason": "stateful-invariant fuzzer reproduced a shrunk exploit sequence",
    "source": "invariant-hunt",
}
try:
    data = json.load(open(verified_json, encoding="utf-8"))
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
data.setdefault("verified", []).append(entry)
totals = data.setdefault("totals", {})
totals["verified"] = int(totals.get("verified", 0)) + 1
with open(verified_json, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
print("1")
PY
)"
      if [ "$MERGED_ADD" = "1" ]; then
        DEEP_FINDINGS=$((DEEP_FINDINGS + 1))
        echo "run-zone-hunt.sh: [deep-hunt] zone '$ZID' ($DCLASS) -> FINDING merged into verified_findings.json (source=invariant-hunt)" >&2
      else
        echo "run-zone-hunt.sh: [deep-hunt] zone '$ZID' ($DCLASS) -> no FINDING to merge (CLEAN / HARNESS_ERROR)" >&2
      fi
    done < "$DEEP_TARGETS"
    echo "run-zone-hunt.sh: [deep-hunt] merged $DEEP_FINDINGS invariant-hunt finding(s) into verified_findings.json" >&2
  fi
fi

# #1774: --deep-hunt-only halts here — the lens has been applied over the reused breadth --out; M5 delivery is
# the breadth path's job (it already ran when OFF was produced) and is deliberately skipped for the lens clone.
if [ "$DEEP_HUNT_ONLY" -eq 1 ]; then
  echo "run-zone-hunt.sh: [deep-hunt-only] lens applied over the reused breadth --out; skipping M5 delivery" >&2
  exit 0
fi

# ----------------------------------------------------------------------------------------------------------
# STAGE 5 (M5): per verified finding -> run-audit-pass.sh (HALTS at PENDING-HUMAN-REVIEW) -> deliver-submission.sh
# (stages the marked draft into the drop-dir). Per-finding body is wrapped so one bad finding is skipped, not fatal.
# ----------------------------------------------------------------------------------------------------------
FINDING_TSV="$OUT/.verified-findings.tsv"
python3 - "$VERIFIED_JSON" > "$FINDING_TSV" <<'PY'
import sys, json
data = json.load(open(sys.argv[1], encoding="utf-8"))
for f in data.get("verified", []):
    row = [f.get("location", ""), f.get("file", ""), f.get("class", ""),
           f.get("severity", ""), f.get("exploit", "")]
    row = [c.replace("\t", " ").replace("\n", " ") for c in row]
    print("\t".join(row))
PY

APOUT="$OUT/audit-pass"; mkdir -p "$APOUT"
FINDINGS=0 ; DELIVERED=0 ; HALTED_NODRAFT=0 ; FAILED=0

# process_finding <slug> <location> <file> <class> <severity> <exploit> — run-audit-pass then, on a marked draft,
# deliver-submission. Every external call is explicitly guarded with `|| return 1` so a failure propagates to the
# caller's per-finding wrapper (set -e is disabled inside a function called under `||`).
process_finding() {
  pf_slug="$1"; pf_loc="$2"; pf_file="$3"; pf_class="$4"; pf_sev="$5"; pf_expl="$6"
  pf_out="$APOUT/$pf_slug"; rm -rf "$pf_out"; mkdir -p "$pf_out"
  pf_target="$(basename "$pf_file")"
  if [ -n "$PASS_FIXTURE" ]; then
    "$AUDITPASS" --finding-location "$pf_loc" --finding-impact "$pf_expl" \
      --poc-repo "$REPO" --poc-target "$pf_target" --poc-hypothesis "$pf_expl" --poc-class "$pf_class" \
      --finding-verified \
      --severity-band "$pf_sev" --in-scope "$SCOPE_CONTEXT" \
      --pass-fixture "$PASS_FIXTURE" --backend "$BACKEND" --agentis "$AGENTIS" --out "$pf_out" || return 1
  else
    "$AUDITPASS" --finding-location "$pf_loc" --finding-impact "$pf_expl" \
      --poc-repo "$REPO" --poc-target "$pf_target" --poc-hypothesis "$pf_expl" --poc-class "$pf_class" \
      --finding-verified \
      --severity-band "$pf_sev" --in-scope "$IN_SCOPE" \
      --live --backend "$BACKEND" --agentis "$AGENTIS" --out "$pf_out" || return 1
  fi
  pf_result=""
  [ -f "$pf_out/pass-result.txt" ] && pf_result="$(cat "$pf_out/pass-result.txt")"
  if [ "$pf_result" = "PENDING-HUMAN-REVIEW" ] && [ -f "$pf_out/submission-draft.md" ]; then
    echo "run-zone-hunt.sh:   finding '$pf_slug' reached PENDING-HUMAN-REVIEW — staging the draft (human-gated) ..." >&2
    # #1802 — bundle the runnable concrete PoC the pass generated (run-audit-pass.sh surfaced its paths from the
    # coordinator memo) so the drop-dir package carries poc/Poc_*.t.sol + REPRODUCE.md + poc-run.txt, not just the
    # draft text. Empty (no FINDING poc / offline fixture) -> pf_poc_args stays empty and the deliver call is
    # byte-identical to today.
    pf_poc_args=()
    if [ -f "$pf_out/poc-file-path.txt" ]; then
      pf_pocfile="$(cat "$pf_out/poc-file-path.txt")"
      if [ -n "$pf_pocfile" ] && [ -f "$pf_pocfile" ]; then
        pf_poc_args+=(--poc-file "$pf_pocfile" --poc-target "$pf_target" --poc-kind foundry)
      fi
    fi
    if [ -f "$pf_out/poc-run-path.txt" ]; then
      pf_pocrun="$(cat "$pf_out/poc-run-path.txt")"
      [ -n "$pf_pocrun" ] && [ -f "$pf_pocrun" ] && pf_poc_args+=(--poc-run "$pf_pocrun")
    fi
    "$DELIVER" --id "${REPO_NAME}@${COMMIT}:${pf_slug}" --draft-file "$pf_out/submission-draft.md" \
      --target "$REPO_NAME" --target-dir "$REPO" --commit "$COMMIT" --finding-slug "$pf_slug" \
      --title "${pf_class} finding: ${pf_loc}" --location "$pf_loc" --impact "$pf_expl" --severity "$pf_sev" \
      --scope-verdict payable --impact-verdict substantiated --dup-risk low --drop-dir "$DROP_DIR" \
      ${pf_poc_args[@]+"${pf_poc_args[@]}"} || return 1
    PF_STAGED=1
  else
    echo "run-zone-hunt.sh:   finding '$pf_slug' halted before a draft ($pf_result) — nothing staged (no submission)." >&2
    PF_STAGED=0
  fi
  return 0
}

while IFS='	' read -r LOCATION CODEFILE CLASS SEVERITY EXPLOIT || [ -n "${LOCATION:-}" ]; do
  [ -n "$LOCATION" ] || continue
  FINDINGS=$((FINDINGS + 1))
  SLUG="$(printf '%s' "$LOCATION" | tr -cs 'A-Za-z0-9' '-' | sed 's/-*$//; s/^-*//')"
  [ -n "$SLUG" ] || SLUG="finding-$FINDINGS"
  PF_STAGED=0
  if process_finding "$SLUG" "$LOCATION" "$CODEFILE" "$CLASS" "$SEVERITY" "$EXPLOIT"; then
    if [ "$PF_STAGED" -eq 1 ]; then DELIVERED=$((DELIVERED + 1)); else HALTED_NODRAFT=$((HALTED_NODRAFT + 1)); fi
  else
    echo "run-zone-hunt.sh: finding '$SLUG' failed (see $APOUT/$SLUG); continuing" >&2
    FAILED=$((FAILED + 1))
  fi
done < "$FINDING_TSV"

echo >&2
# #1830: the banner reports COVERAGE (covered/total), not the old "zones hunted" count — that counted only the
# zones that started, so a truncated run's banner was indistinguishable from a clean sweep's.
echo "================ ZONE-HUNT: $ZONES_COVERED/$ZONES_TOTAL zone(s) covered, $FINDINGS verified finding(s) ================" >&2
echo "run-zone-hunt.sh: delivered (staged, PENDING HUMAN REVIEW): $DELIVERED" >&2
echo "run-zone-hunt.sh: halted before a draft (nothing staged): $HALTED_NODRAFT" >&2
echo "run-zone-hunt.sh: per-finding failures (skipped): $FAILED" >&2
if [ "$DELIVERED" -gt 0 ]; then
  echo "run-zone-hunt.sh: $DELIVERED draft(s) staged in $DROP_DIR — a human reviews each and files it manually. This never submits." >&2
else
  echo "run-zone-hunt.sh: no finding reached a human-gate draft — nothing staged, nothing submitted." >&2
fi
exit 0
