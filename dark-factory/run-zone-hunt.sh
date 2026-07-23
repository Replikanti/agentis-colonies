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
#   --drop-dir <dir>    deliver-submission.sh drop-dir (default: <out>/drop).
#   -h, --help          This help.
#
# Exit: 0 after the batch (a clean halt on every finding, incl. per-finding failures that were skipped); 2 usage
#       error; 3 missing prerequisite (an upstream stage — map/brief/discovery/verify — failed to produce output).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
REPO="" ; OUT="$PWD/zone-hunt-out" ; JOBS=1 ; BACKEND="flat-cyborg"
SCOPE_HINT="" ; SINCE="" ; RESIDUALS=""
IN_SCOPE="" ; ASSET_CONTRACTS="" ; IMPACT_THRESHOLD=""
MAP_FIXTURE="" ; BRIEF_FIXTURE="" ; PASS_FIXTURE="" ; DROP_DIR=""
DEEP_HUNT=0 ; INV_FIXTURE="" ; DEEP_HUNT_MAX_TARGETS=1 ; DEEP_HUNT_REPAIR_ROUNDS=4 ; DEEP_HUNT_AUX_MAX=0
DEEP_HUNT_ONLY=0  # #1774: apply ONLY the STAGE 4.5 lens over an existing breadth --out (requires --deep-hunt).
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
    --deep-hunt-repair-rounds) nv "$#"; DEEP_HUNT_REPAIR_ROUNDS="$2"; shift 2 ;;
    --pattern-store)    nv "$#"; DEEP_FWD+=(--pattern-store "$2"); shift 2 ;;
    --replay-corpus)    DEEP_FWD+=(--replay-corpus); shift ;;
    --corpus-max)       nv "$#"; DEEP_FWD+=(--corpus-max "$2"); shift 2 ;;
    --symbolic-oracle)  DEEP_FWD+=(--symbolic-oracle); shift ;;
    --symbolic-timeout) nv "$#"; DEEP_FWD+=(--symbolic-timeout "$2"); shift 2 ;;
    --core-dep-harness) DEEP_FWD+=(--core-dep-harness); shift ;;
    --ensemble-candidates) nv "$#"; DEEP_FWD+=(--ensemble-candidates "$2"); shift 2 ;;
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
case "$DEEP_HUNT_REPAIR_ROUNDS" in ''|*[!0-9]*) echo "run-zone-hunt.sh: --deep-hunt-repair-rounds must be a positive integer (got '$DEEP_HUNT_REPAIR_ROUNDS')" >&2; exit 2 ;; esac
[ "$DEEP_HUNT_REPAIR_ROUNDS" -ge 1 ] || { echo "run-zone-hunt.sh: --deep-hunt-repair-rounds must be >= 1 (got '$DEEP_HUNT_REPAIR_ROUNDS')" >&2; exit 2; }
[ "$DEEP_HUNT_ONLY" -eq 0 ] || [ "$DEEP_HUNT" -eq 1 ] || { echo "run-zone-hunt.sh: --deep-hunt-only requires --deep-hunt" >&2; exit 2; }
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
BRIEFS="$OUT/briefs"
echo "run-zone-hunt.sh: [M2] generating per-zone briefs -> $BRIEFS ..." >&2
if [ -n "$BRIEF_FIXTURE" ]; then
  "$GENBRIEFS" --zones "$MAP/zones.json" --scope "$MAP/scope.tsv" --out "$BRIEFS" --repo "$REPO" \
    ${RESIDUALS:+--audit-residuals "$RESIDUALS"} --fixture "$BRIEF_FIXTURE"
else
  "$GENBRIEFS" --zones "$MAP/zones.json" --scope "$MAP/scope.tsv" --out "$BRIEFS" --repo "$REPO" \
    ${RESIDUALS:+--audit-residuals "$RESIDUALS"} --backend "$BACKEND" --agentis "$AGENTIS"
fi
[ -f "$BRIEFS/briefs/zone_briefs.json" ] || { echo "run-zone-hunt.sh: gen-briefs.sh did not emit zone_briefs.json" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# STAGE 3 (M3): per-zone run-discovery.sh, each with its OWN zone brief; merge into discovery-results.merged.json.
# Zones loop SERIALLY (the intra-zone --jobs is the only parallelism — the M3 OOM cap is not stacked across zones).
# ----------------------------------------------------------------------------------------------------------
DISC="$OUT/discovery"; mkdir -p "$DISC"
ZONE_LIST="$OUT/.zone-list.tsv"
python3 - "$MAP/zones.json" > "$ZONE_LIST" <<'PY'
import sys, json
zones = json.load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(zones, list):
    zones = []
for z in zones:
    zid = z.get("id", "")
    name = z.get("name", zid)
    if not zid:
        continue
    print("%s\t%s" % (zid.replace("\t", " "), name.replace("\t", " ")))
PY

ZONES_HUNTED=0
while IFS='	' read -r ZID ZNAME || [ -n "${ZID:-}" ]; do
  [ -n "$ZID" ] || continue
  ZBRIEF="$BRIEFS/briefs/brief_${ZID}.md"
  if [ ! -f "$ZBRIEF" ]; then
    echo "run-zone-hunt.sh: [M3] zone '$ZNAME' ($ZID) has no brief at $ZBRIEF; skipping" >&2
    continue
  fi
  echo "run-zone-hunt.sh: [M3] hunting zone '$ZNAME' ($ZID) with its brief ..." >&2
  ZONES_HUNTED=$((ZONES_HUNTED + 1))
  "$DISCOVERY" --repo "$REPO" --scope "$MAP/scope.tsv" --only "$ZNAME" --brief "$ZBRIEF" \
    --jobs "$JOBS" --backend "$BACKEND" --agentis "$AGENTIS" --out "$DISC/$ZID" \
    || echo "run-zone-hunt.sh: [M3] discovery failed for zone '$ZNAME' ($ZID); continuing" >&2
done < "$ZONE_LIST"

MERGED="$DISC/discovery-results.merged.json"
python3 - "$MERGED" "$DISC" "$REPO_NAME" "$BACKEND" "$JOBS" <<'PY'
import sys, os, json, glob
merged_path, disc_dir, repo, backend, jobs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
cells, tc, tcand, ts = [], 0, 0, 0
for zid in sorted(os.listdir(disc_dir)):
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
out = {"repo": repo, "backend": backend, "jobs": jobs, "cells": cells,
       "totals": {"cells": tc, "candidates": tcand, "steers": ts}}
json.dump(out, open(merged_path, "w", encoding="utf-8"), indent=2)
open(merged_path, "a", encoding="utf-8").write("\n")
print("run-zone-hunt.sh: [M3] merged %d cell(s), %d candidate(s) from %d zone(s)" % (tc, tcand, len(cells)), file=sys.stderr)
PY
[ -f "$MERGED" ] || { echo "run-zone-hunt.sh: merge produced no discovery-results.merged.json" >&2; exit 3; }

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
    DEEP_TARGETS="$OUT/.deep-hunt-targets.tsv"
    python3 - "$MAP/zones.json" "$REPO" "$DEEP_HUNT_MAX_TARGETS" "$DEEP_HUNT_AUX_MAX" > "$DEEP_TARGETS" <<'PY'
import sys, os, json
zones = json.load(open(sys.argv[1], encoding="utf-8"))
repo, max_targets, aux_max = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
if not isinstance(zones, list):
    zones = []
def loc(rel):
    try:
        with open(os.path.join(repo, rel), encoding="utf-8", errors="ignore") as fh:
            return sum(1 for _ in fh)
    except Exception:
        return 0
def dominant_class(classes):
    # #1783: C2 (Oracle integrity) is appended AFTER the C6/C10/C11 value-custody-primary codes, so it wins
    # only when no value-custody-primary class is present — byte-identical routing for every zone that has
    # C6/C10/C11, and an oracle-dependent zone (C2 but no custody-primary code) now routes to the oracle lens
    # (--class C2 -> prover class_to_keyword "oracle" -> is_oracle_dependent) instead of the generic C-invariant.
    # #1784: C16 (State-machine liveness / stuck-state) is appended AFTER C2, so a liveness-only zone (C16 but no
    # value-custody-primary or oracle code) routes to the arithmetic-overflow / liveness (DoS) lens
    # (--class C16 -> prover class_to_keyword "liveness" -> is_liveness_sensitive); byte-identical routing for
    # every zone that has C6/C10/C11/C2.
    for c in ("C6", "C10", "C11", "C2", "C16"):
        if c in classes:
            return c
    return "C-invariant"
for z in zones:
    if not z.get("value_custody"):
        continue
    zid = z.get("id", "")
    if not zid:
        continue
    sols = [f for f in z.get("files", []) if isinstance(f, str) and f.endswith(".sol")]
    if not sols:
        continue
    # largest by line count; lexicographic tie-break (smallest name wins on equal loc)
    ranked = sorted(sols, key=lambda f: (-loc(f), f))
    dclass = dominant_class(z.get("bug_classes_likely", []))
    for rel in ranked[:max_targets]:
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
      DZOUT="$DEEP/$ZID"
      if [ -n "$INV_FIXTURE" ]; then
        "$INVHUNT" --repo "$REPO" --target "$RELFILE" --class "$DCLASS" \
          --handler-fixture "$INV_FIXTURE" --backend "$BACKEND" --agentis "$AGENTIS" --out "$DZOUT" \
          --repair-rounds "$DEEP_HUNT_REPAIR_ROUNDS" "$@" ${DEEP_FWD[@]+"${DEEP_FWD[@]}"} \
          || { echo "run-zone-hunt.sh: [deep-hunt] run-invariant-hunt.sh failed for zone '$ZID'; continuing" >&2; continue; }
      else
        "$INVHUNT" --repo "$REPO" --target "$RELFILE" --class "$DCLASS" \
          --backend "$BACKEND" --agentis "$AGENTIS" --out "$DZOUT" \
          --repair-rounds "$DEEP_HUNT_REPAIR_ROUNDS" "$@" ${DEEP_FWD[@]+"${DEEP_FWD[@]}"} \
          || { echo "run-zone-hunt.sh: [deep-hunt] run-invariant-hunt.sh failed for zone '$ZID'; continuing" >&2; continue; }
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
        echo "run-zone-hunt.sh: [deep-hunt] zone '$ZID' -> FINDING merged into verified_findings.json (source=invariant-hunt)" >&2
      else
        echo "run-zone-hunt.sh: [deep-hunt] zone '$ZID' -> no FINDING to merge (CLEAN / HARNESS_ERROR)" >&2
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
      --severity-band "$pf_sev" --in-scope "$SCOPE_CONTEXT" \
      --pass-fixture "$PASS_FIXTURE" --backend "$BACKEND" --agentis "$AGENTIS" --out "$pf_out" || return 1
  else
    "$AUDITPASS" --finding-location "$pf_loc" --finding-impact "$pf_expl" \
      --poc-repo "$REPO" --poc-target "$pf_target" --poc-hypothesis "$pf_expl" --poc-class "$pf_class" \
      --severity-band "$pf_sev" --in-scope "$IN_SCOPE" \
      --live --backend "$BACKEND" --agentis "$AGENTIS" --out "$pf_out" || return 1
  fi
  pf_result=""
  [ -f "$pf_out/pass-result.txt" ] && pf_result="$(cat "$pf_out/pass-result.txt")"
  if [ "$pf_result" = "PENDING-HUMAN-REVIEW" ] && [ -f "$pf_out/submission-draft.md" ]; then
    echo "run-zone-hunt.sh:   finding '$pf_slug' reached PENDING-HUMAN-REVIEW — staging the draft (human-gated) ..." >&2
    "$DELIVER" --id "${REPO_NAME}@${COMMIT}:${pf_slug}" --draft-file "$pf_out/submission-draft.md" \
      --target "$REPO_NAME" --target-dir "$REPO" --commit "$COMMIT" --finding-slug "$pf_slug" \
      --title "${pf_class} finding: ${pf_loc}" --location "$pf_loc" --impact "$pf_expl" --severity "$pf_sev" \
      --scope-verdict payable --impact-verdict substantiated --dup-risk low --drop-dir "$DROP_DIR" || return 1
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
echo "================ ZONE-HUNT: $ZONES_HUNTED zone(s) hunted, $FINDINGS verified finding(s) ================" >&2
echo "run-zone-hunt.sh: delivered (staged, PENDING HUMAN REVIEW): $DELIVERED" >&2
echo "run-zone-hunt.sh: halted before a draft (nothing staged): $HALTED_NODRAFT" >&2
echo "run-zone-hunt.sh: per-finding failures (skipped): $FAILED" >&2
if [ "$DELIVERED" -gt 0 ]; then
  echo "run-zone-hunt.sh: $DELIVERED draft(s) staged in $DROP_DIR — a human reviews each and files it manually. This never submits." >&2
else
  echo "run-zone-hunt.sh: no finding reached a human-gate draft — nothing staged, nothing submitted." >&2
fi
exit 0
