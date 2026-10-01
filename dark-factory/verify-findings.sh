#!/usr/bin/env bash
# verify-findings.sh — #1630 (milestone M4 of epic #1611: verify integration). The M3 -> verify BRIDGE.
#
# run-discovery.sh (M3) emits discovery-results.json: a machine-readable set of UNVERIFIED candidate LEADS, one
# per (subsystem x class) cell. A candidate is worth a human's attention ONLY after a SECOND, independent gate
# fails to kill it. This script drives that gate over EVERY candidate and aggregates the survivors into
# verified_findings.json — the CONFIRMED-only input the M5 capstone hands to the submission pass.
#
# WHAT IT IS. For each candidate in discovery-results.json it derives a one-line gate manifest from the
# candidate's own fields and invokes the operator-selected gate:
#   --gate refute   (DEFAULT): run-refute.sh — a hostile skeptic re-reads the candidate against the real
#                   control-flow and defaults to REFUTED on any doubt; CONFIRMED = the `REAL` verdict.
#   --gate poc      : run-poc.sh — a concrete Foundry/Hardhat PoC; CONFIRMED = the `POC|<target>|FINDING` line.
#   --gate symbolic : run-symbolic.sh — a Halmos property; CONFIRMED = the `SYMBOLIC|<file:fn>|COUNTEREXAMPLE`.
# A candidate the gate cannot CONFIRM is DROPPED (unverified, never fatal). Per-candidate isolation: each gate
# call is wrapped so a gate that errors on one candidate is logged and SKIPPED, never aborting the batch.
#
# #1887 SIDECAR. On `--gate refute` the per-gate `refute-constraints.tsv` files are concatenated, in NUMERIC
# GATE ORDER, into `<out>/refute-constraints.tsv`: the generalisable standard each refuted claim failed, which
# refute-to-knowledge.sh turns into a knowledge corpus a LATER target's hunter can read. It is an additional
# FILE, never a new key — verified_findings.json's schema is unchanged.
#
# #2217 SECOND TIER. `--tier2 N` (default 0 = OFF) sends the N highest-ranked tier-2 records per zone through the
# SAME gate, AFTER every tier-1 candidate has been examined. A tier-2 record is a check the hunt DERIVED and did
# not settle (an UNRESOLVED trace, or a CLEAN dismissal without the citation its grounds require) — it is not a
# candidate, carries no severity, and is never a finding. Its verdicts land in a SEPARATE top-level `tier2[]`
# array, NEVER in verified[]: whatever the gate says about a tier-2 row, the CONFIRMED-only contract the
# submission pass consumes is unchanged.
#
# WHAT IT IS NOT. It is READ-ONLY over discovery-results.json (never mutates it), touches no network, and has NO
# submit verb anywhere — a CONFIRMED finding is still a LEAD a human triages. Surfacing the verified subset is
# the whole job; verification's downstream (packaging + the human-gated submission pass) is M5's capstone.
#
# Usage:
#   verify-findings.sh --results <discovery-results.json> --repo <dir> --out <dir> [options]
#
# Options:
#   --results <file>    M3 run-discovery.sh discovery-results.json (the candidate set). REQUIRED.
#   --repo <dir>        Cloned target repo root — the base for each candidate's code file. REQUIRED.
#   --out <dir>         Output dir for the per-candidate gate runs + verified_findings.json. REQUIRED.
#   --gate <refute|poc|symbolic>  Verification gate (default: refute — the best manifest-shape match + it has
#                       the offline --agentis/--backend mock stub seam).
#   --pay-floor <critical|high|medium|low>  OPTIONAL (#1962). The lowest severity this program actually pays.
#                       When set, a well-formed candidate BELOW the floor is dropped into `dropped_subfloor[]`
#                       BEFORE it ever reaches the gate — saving a refute/PoC/symbolic pass on a lead that can
#                       never pay on this program. Same closed severity vocabulary + rank as
#                       finding-payability-gate.sh's --pay-floor (low < medium < high < critical), reused
#                       verbatim so the two scripts never drift. FAIL-OPEN: a malformed candidate (#1691 blank
#                       class/severity) or one with a blank/unrecognized severity is NEVER dropped by this
#                       filter — only a well-formed, resolvable severity below the floor is. Default: unset =
#                       inert = every artifact byte-identical to a pre-#1962 run.
#   --adjudicated <file>  OPTIONAL (#2023). Operator adjudication overlay (adjudicated.tsv: loc \t class \t
#                       sev \t verdict \t reason). A candidate whose normalized location matches an adjudicated
#                       row is NOT re-refuted — a human has already ruled that location, and that ruling is
#                       authoritative. Its cell verdict is PRESERVED (a real-bug CONFIRMED/DUPLICATE stays in
#                       verified_findings.json; any other verdict is dropped), so a --rehunt-gaps pass — which
#                       rm -rf's the gates dir every run — can never silently downgrade a confirmed finding to
#                       REFUTED. Match keying is normalized-location-only (protects the location regardless of
#                       class). Default: unset/absent = inert = every artifact byte-identical to a pre-#2023 run.
#   --tier2 <N>         OPTIONAL (#2217). Examine up to N SECOND-TIER records PER ZONE through the selected
#                       gate, AFTER the tier-1 candidate loop has finished (tier 1 always gets the gate
#                       first — the second tier never displaces a candidate). Source: the top-level
#                       `tier2[]` array run-discovery.sh emits when its own second tier is on; a merged
#                       file WITHOUT that array makes this flag a silent no-op, never an error.
#                       PER ZONE = per `subsystem`: a merged discovery-results.json carries no zone key,
#                       and the subsystem name IS the zone label every record carries (map-zones.sh keys a
#                       zone on it). On a single-zone run that is exactly "the first N records".
#                       HIGHEST-RANKED = FIRST IN THE ARRAY: run-discovery.sh's _tier2_select already emits
#                       each zone's slice in rank order and the merge concatenates slices in zone order, so
#                       no rank is re-derived here — the ranking lives in exactly one place (#2217 PR A).
#                       SEPARATION IS THE POINT. A tier-2 outcome lands ONLY in the new top-level `tier2[]`
#                       array — never in verified[], never in errors[], never in dropped_subfloor[]. It is
#                       outside totals.candidates and therefore outside the counting invariant
#                       `candidates == verified + errored + refuted + dropped_subfloor`; it is outside the
#                       --pay-floor partition (a record carries no severity to floor); and its gate runs in
#                       its OWN <out>/gates-tier2/ dir, so the #1887 refute-constraints.tsv corpus — built
#                       from <out>/gates/ — is byte-identical with and without this flag. The #2023
#                       adjudication overlay is deliberately NOT consulted: it rules on FINDINGS, and a
#                       tier-2 outcome is never one.
#                       The gate needs a severity in its manifest, so `Medium` is substituted as a GATE
#                       INPUT and the exploit text is prefixed `TIER2 (severity unassessed):` — the emitted
#                       record still ships `severity: ""`, because nothing assessed one.
#                       Serial by construction (N is capped small upstream); --jobs fans out tier 1 only.
#                       Default 0 = OFF = inert: no new key, no new dir, every artifact byte-identical to a
#                       pre-#2217 run.
#   --brief <file>      Optional protocol brief handed to the refute gate (invariants + known issues).
#   --scope-docs <auto|file>  OPTIONAL (#2257). The target's DECLARED scope assumptions, extracted ONCE per run by
#                       lib/scope-assumptions.py into <out>/scope-assumptions.txt (`auto` = the repo's own SCOPE.md +
#                       README.md; a file = an operator-curated `scope-assumptions.md`, which REPLACES auto) and
#                       handed to every refute gate via run-refute.sh --scope-assumptions. It only acts inside a
#                       SEVERITY_RUBRIC=1 refuter prompt: there a REFUTED verdict that stands on a contract-passing
#                       `out-of-scope-premise` ground lands in a new top-level `out_of_scope[]` array (label
#                       `out_of_scope_premise`, the cited assumption, the quoted premise) — NEVER in verified[] —
#                       and `totals.out_of_scope` counts it. Both keys appear ONLY when non-empty; out_of_scope is a
#                       SUBSET of the implicit refuted count, so `candidates == verified + errored + refuted +
#                       dropped_subfloor` is unchanged. An empty block (nothing declared) is logged and inert; a
#                       non-empty block without SEVERITY_RUBRIC=1 is logged LOUDLY and passed nowhere (inert).
#                       Tier-2 records get the block in their prompt but no new routing (their reason carries the
#                       `out-of-scope-premise (...)` prefix). Whenever the flag is given, verified_findings.json
#                       also carries `scope_layer: {state: on|off|inert-extractor-error, reason}` (an extractor
#                       crash fails OPEN and is recorded there). Default: unset = inert = every artifact
#                       byte-identical (no scope_layer key).
#                       `auto` also reads the PARENT directory's SCOPE.md / README.md when that doc lists a source
#                       file under `<basename of --repo>/` (the contest layout: scope README one level above the
#                       code dir), cited `../<name>`. A <file> is an operator-CURATED file, never a raw README:
#                       bullets naming a source file and bullets with no category are dropped (#2292), and the
#                       extractor's one-line count of them is relayed to stderr.
#   --scope-map <file>  OPTIONAL (#2292). The zone map (map/scope.tsv) of the run that produced --results, forwarded
#                       to run-refute.sh --scope-map whenever a scope block is: it arms the decider's
#                       `scope-cite-in-scope-file` contract (an `exclusion` row naming a mapped file is never a
#                       ground). `scope_layer.reason` says whether that guard is armed. Missing file => exit 2;
#                       without --scope-docs it is ignored.
#   --cluster-findings <0|1>  ROOT-CAUSE CLUSTERING (#2278). Default: env DF_CLUSTER_FINDINGS, else 1 (ON).
#                       One bug reached by several class cells passes the gate once per cell, so verified[]
#                       carries the same root cause several times. When ON and more than one finding survived,
#                       lib/cluster-findings.py collapses duplicates that share the exact (file, function) of
#                       their `location` AND cite overlapping code identifiers in `exploit` into ONE
#                       representative (highest severity; carries `duplicates`, `also_classes`,
#                       `also_locations`). The full pre-cluster list moves to the sibling
#                       <out>/verified_findings.raw.json, and verified_findings.json gains a top-level
#                       `clustering` block (method, threshold, raw_sha256, counts) plus
#                       totals.verified_precluster, so candidates == verified_precluster + errored + refuted +
#                       dropped_subfloor. Nothing is ever lost: when no duplicate merged, the file stays
#                       byte-identical to an OFF run and no sibling is written; when the clusterer fails, the
#                       raw file is restored and a WARNING is printed (fail-open). A stale sibling from an
#                       earlier run in the same --out is always removed first. `0` = OFF = byte-identical to a
#                       pre-#2278 run. Optional env DF_CLUSTER_THRESHOLD (a decimal in (0,1]) overrides the
#                       clusterer's pinned similarity threshold; DF_CLUSTER_CMD replaces the clusterer
#                       command (a test seam). The block key is the same (file, function) pair corpus-bench's
#                       score-match.py matches on, so location-first bench recall cannot change.
#   --refute-batch <0|1>  BATCHED FIRST READ (#2284). Default: env DF_REFUTE_BATCH, else 0 (OFF). Discovery files
#                       one candidate per (subsystem x class) cell, so one function can reach the refute gate up to
#                       six times, each time in a fresh session that re-reads the same code. When ON, the candidates
#                       that would reach the gate are grouped by the SAME (file, function) key --cluster-findings
#                       uses (plus the code file), and each group of two or more gets ONE run-refute.sh
#                       --batch-first-read session in which the refuter answers one indexed block per candidate.
#                       Every member then runs the normal single-candidate gate with its own block as the first
#                       read (--first-read-log), so the rubric re-ask, the #1699 C6 fallback, the #1887 constraint
#                       harvest, the report row and the gates/<n>_<slug>/ dir are exactly the single-candidate
#                       ones and verdicts stay per candidate. A member without a clean block (dropped, class
#                       mismatch, chrome, no batch sentinel) simply gets its own first read — a bad batch costs
#                       sessions, never a candidate. Never batched: operator-adjudicated (#2023) and preflight-
#                       errored (#1691) candidates, a location with no function part, a group of one, tier-2
#                       records, and the poc/symbolic gates (ON with those gates warns and stays inert).
#                       Groups larger than env DF_REFUTE_BATCH_MAX (default 6, an integer >= 2) are split into
#                       balanced chunks (8 -> 4+4). verified_findings.json gains NO key; ON adds only
#                       <out>/gates-batch/<b>_<slug>/ (the batch manifest, members.tsv, the batch session under
#                       refute-out/run) and, in each batched member's gates/<n>_<slug>/, batch.txt
#                       (`<batch>\t<k>\t<size>`) and gate.rc; the VERIFY banner names the batched sessions. A
#                       batch is ONE job under --jobs, so it takes one slot of effective_jobs. `0` = OFF = every
#                       artifact byte-identical to a pre-#2284 run. Telemetry: env DF_REFUTE_SESSION_LOG (see
#                       run-refute.sh) records every refuter session, batched or not.
#   --backend <mock|flat-cyborg|claude>  LLM backend for the gate (default: flat-cyborg).
#   --model <id>        LLM model id for the gate's `llm.model` (default: unset, so the emitted config stays
#                       `llm.model = opus` — byte-identical to before this flag existed).
#   --agentis <bin>     agentis binary (default: `agentis` on PATH).
#   --jobs <N>          OPT-IN bounded-concurrency fan-out over the CANDIDATE gates (#1863; default N=1 =
#                       serial = today's exact statement sequence). Gate up to N candidates CONCURRENTLY:
#                       STAGE 4 is the SERIAL TAIL of a zone hunt (~4 min per refute gate x every candidate
#                       the merge produced) and each candidate's gate is independent of the others.
#                       Concurrency is HARD-CAPPED at min(N, LLM_MAX_VERIFY_GATES=4) so N concurrent
#                       `agentis go` / forge / solc processes cannot OOM-thrash a single host — the cap NEVER
#                       fails open. That env knob is deliberately SEPARATE from run-discovery.sh's
#                       LLM_MAX_DISCOVERY_CELLS: STAGE 3 and STAGE 4 are sequential stages, so their ceilings
#                       are tuned independently and never stack.
#                       STORE ISOLATION (already true serially, made explicit here): every candidate's gate
#                       runs in its OWN <out>/gates/<n>_<slug>/refute-out rundir, which run-refute.sh
#                       `rm -rf`s + `agentis init`s on every invocation, and each invocation is handed
#                       EXACTLY ONE manifest line. So the `learning.enabled` / `experience.enabled` store is
#                       created fresh for ONE candidate and never read again: there is NO cross-candidate
#                       refuter reweighting on EITHER path, and a verdict never depends on the candidate's
#                       position in the manifest. --jobs > 1 therefore loses no steering — there is none.
#                       C6 STAYS INSIDE ITS SLOT: run-refute.sh's #1699 C6 fallback is a SEQUENTIAL step of
#                       its own manifest loop, and this script backgrounds exactly ONE subshell per
#                       candidate, so peak agentis concurrency is effective_jobs, never effective_jobs x 2.
#                       The rule: fan-out lives in THIS launch loop and nothing below it backgrounds work.
#                       Aggregation is DEFERRED until the pool drains and then replayed in MANIFEST order
#                       (preflight-ERROR and gate-ERROR rows interleaved exactly as the serial path emits
#                       them), so verified[] / errors[] / totals are byte-identical to the serial run.
#                       Needs bash >= 4.3 (`wait -n`); an older bash degrades to serial with a notice.
#   -h, --help          This help.
#
# Exit: 0 on a clean run that reached its aggregate (even with zero survivors — a rigorous negative is valid);
#       2 usage error; 3 missing prerequisite.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
RESULTS="" ; REPO="" ; OUT="" ; GATE="refute" ; BRIEF="" ; BACKEND="flat-cyborg" ; MODEL=""
JOBS=1  # #1863: opt-in bounded-concurrency gate fan-out; 1 = serial, today's exact statement sequence.
PAY_FLOOR=""  # #1962: unset = inert (see the header). Validated below with the closed severity vocabulary.
ADJUDICATED=""  # #2023: unset/absent = inert; operator adjudication overlay that pre-empts the refute gate.
TIER2=0  # #2217: 0 = OFF = inert (see --tier2 in the header). N > 0 = examine N tier-2 records per zone.
SCOPE_DOCS=""  # #2257: unset = inert. `auto` or an operator file (see --scope-docs in the header).
SCOPE_MAP=""  # #2292: unset = the in-scope-file guard is not armed (see --scope-map in the header).
CLUSTER_FINDINGS="${DF_CLUSTER_FINDINGS:-1}"  # #2278: 1 = ON (default), 0 = OFF (see --cluster-findings in the header).
REFUTE_BATCH="${DF_REFUTE_BATCH:-0}"  # #2284: 0 = OFF (default), 1 = batched first read (see --refute-batch in the header).
REFUTE_BATCH_MAX="${DF_REFUTE_BATCH_MAX:-6}"  # #2284: the largest batch; a bigger group is split into balanced chunks.

nv() { [ "$1" -ge 2 ] || { echo "verify-findings.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --results) nv "$#"; RESULTS="$2"; shift 2 ;;
    --repo)    nv "$#"; REPO="$2"; shift 2 ;;
    --out)     nv "$#"; OUT="$2"; shift 2 ;;
    --gate)    nv "$#"; GATE="$2"; shift 2 ;;
    --brief)   nv "$#"; BRIEF="$2"; shift 2 ;;
    --backend) nv "$#"; BACKEND="$2"; shift 2 ;;
    --model)   nv "$#"; MODEL="$2"; shift 2 ;;
    --agentis) nv "$#"; AGENTIS="$2"; shift 2 ;;
    --jobs)    nv "$#"; JOBS="$2"; shift 2 ;;
    --pay-floor) nv "$#"; PAY_FLOOR="$2"; shift 2 ;;
    --adjudicated) nv "$#"; ADJUDICATED="$2"; shift 2 ;;
    --tier2)   nv "$#"; TIER2="$2"; shift 2 ;;
    --scope-docs) nv "$#"; SCOPE_DOCS="$2"; shift 2 ;;
    --scope-map) nv "$#"; SCOPE_MAP="$2"; shift 2 ;;
    --cluster-findings) nv "$#"; CLUSTER_FINDINGS="$2"; shift 2 ;;
    --refute-batch) nv "$#"; REFUTE_BATCH="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "verify-findings.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$RESULTS" ] && [ -f "$RESULTS" ] || { echo "verify-findings.sh: --results <discovery-results.json> required" >&2; exit 2; }
[ -n "$REPO" ]    && [ -d "$REPO" ]    || { echo "verify-findings.sh: --repo <cloned repo dir> required" >&2; exit 2; }
[ -n "$OUT" ] || { echo "verify-findings.sh: --out <output dir> required" >&2; exit 2; }
case "$GATE" in
  refute|poc|symbolic) : ;;
  *) echo "verify-findings.sh: --gate must be one of refute|poc|symbolic (got '$GATE')" >&2; exit 2 ;;
esac
# #1962: --pay-floor closed vocabulary, same shape as run-zone-hunt.sh / finding-payability-gate.sh. Unset
# (blank) is the default and means "inert" — the same as every other --pay-floor consumer in this pipeline.
case "$PAY_FLOOR" in
  ""|critical|high|medium|low) : ;;
  *) echo "verify-findings.sh: --pay-floor must be one of critical|high|medium|low (got '$PAY_FLOOR')" >&2; exit 2 ;;
esac
# #1863: --jobs is a POSITIVE integer, validated before any side effect (same shape as run-discovery.sh).
case "$JOBS" in ''|*[!0-9]*) echo "verify-findings.sh: --jobs must be a positive integer (got '$JOBS')" >&2; exit 2 ;; esac
[ "$JOBS" -ge 1 ] || { echo "verify-findings.sh: --jobs must be >= 1 (got '$JOBS')" >&2; exit 2; }
# #2217: --tier2 is a NON-NEGATIVE integer (0 = OFF = the default), validated before any side effect.
case "$TIER2" in ''|*[!0-9]*) echo "verify-findings.sh: --tier2 must be a non-negative integer (got '$TIER2')" >&2; exit 2 ;; esac
[ -z "$BRIEF" ] || [ -f "$BRIEF" ] || { echo "verify-findings.sh: --brief not found: $BRIEF" >&2; exit 2; }
# #2257: `auto` or an existing operator file; anything else is a usage error before any side effect.
[ -z "$SCOPE_DOCS" ] || [ "$SCOPE_DOCS" = "auto" ] || [ -f "$SCOPE_DOCS" ] || { echo "verify-findings.sh: --scope-docs must be 'auto' or an existing file (got '$SCOPE_DOCS')" >&2; exit 2; }
[ -z "$SCOPE_MAP" ] || [ -f "$SCOPE_MAP" ] || { echo "verify-findings.sh: --scope-map not found: $SCOPE_MAP" >&2; exit 2; }
# #2278: the clustering knobs, validated before any side effect like every other flag.
case "$CLUSTER_FINDINGS" in
  0|1) : ;;
  *) echo "verify-findings.sh: --cluster-findings (or DF_CLUSTER_FINDINGS) must be 0 or 1 (got '$CLUSTER_FINDINGS')" >&2; exit 2 ;;
esac
if [ -n "${DF_CLUSTER_THRESHOLD:-}" ]; then
  if ! printf '%s\n' "$DF_CLUSTER_THRESHOLD" | grep -Eq '^([0-9]+\.?[0-9]*|\.[0-9]+)$' \
     || ! awk -v t="$DF_CLUSTER_THRESHOLD" 'BEGIN { exit !(t + 0 > 0 && t + 0 <= 1) }'; then
    echo "verify-findings.sh: DF_CLUSTER_THRESHOLD must be a decimal in (0,1] (got '$DF_CLUSTER_THRESHOLD')" >&2; exit 2
  fi
fi
# #2284: the batching knobs, validated before any side effect like every other flag.
case "$REFUTE_BATCH" in
  0|1) : ;;
  *) echo "verify-findings.sh: --refute-batch (or DF_REFUTE_BATCH) must be 0 or 1 (got '$REFUTE_BATCH')" >&2; exit 2 ;;
esac
case "$REFUTE_BATCH_MAX" in
  ''|*[!0-9]*) echo "verify-findings.sh: DF_REFUTE_BATCH_MAX must be an integer >= 2 (got '$REFUTE_BATCH_MAX')" >&2; exit 2 ;;
esac
[ "$REFUTE_BATCH_MAX" -ge 2 ] || { echo "verify-findings.sh: DF_REFUTE_BATCH_MAX must be an integer >= 2 (got '$REFUTE_BATCH_MAX')" >&2; exit 2; }
if [ "$REFUTE_BATCH" = "1" ] && [ "$GATE" != "refute" ]; then
  echo "verify-findings.sh: WARNING: --refute-batch batches the refute gate only (--gate $GATE) — batching inert" >&2
  REFUTE_BATCH=0
fi
command -v python3 >/dev/null 2>&1 || { echo "verify-findings.sh: python3 not installed" >&2; exit 3; }

# Resolve every operator path to ABSOLUTE (the gate scripts run from throwaway cwds).
REPO="$(cd "$REPO" && pwd)"
RESULTS="$(cd "$(dirname "$RESULTS")" && pwd)/$(basename "$RESULTS")"
[ -z "$BRIEF" ] || BRIEF="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"
if [ -n "$SCOPE_DOCS" ] && [ "$SCOPE_DOCS" != "auto" ]; then
  SCOPE_DOCS="$(cd "$(dirname "$SCOPE_DOCS")" && pwd)/$(basename "$SCOPE_DOCS")"
fi
[ -z "$SCOPE_MAP" ] || SCOPE_MAP="$(cd "$(dirname "$SCOPE_MAP")" && pwd)/$(basename "$SCOPE_MAP")"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

REFUTE="$HERE/run-refute.sh"
POC="$HERE/run-poc.sh"
SYMBOLIC="$HERE/run-symbolic.sh"
case "$GATE" in
  refute)   [ -x "$REFUTE" ]   || { echo "verify-findings.sh: run-refute.sh not found/executable at $REFUTE" >&2; exit 3; } ;;
  poc)      [ -x "$POC" ]      || { echo "verify-findings.sh: run-poc.sh not found/executable at $POC" >&2; exit 3; } ;;
  symbolic) [ -x "$SYMBOLIC" ] || { echo "verify-findings.sh: run-symbolic.sh not found/executable at $SYMBOLIC" >&2; exit 3; } ;;
esac

# #1863: the concurrency ceiling. Effective parallelism = min(--jobs, GATE_CAP); the cap is HARD (never
# fail-open) so N concurrent gates — each an `agentis go` LLM session, and under --gate poc/symbolic also a
# repo copy + a build — cannot OOM-thrash a single host. Conservative default 4; tune per host via
# LLM_MAX_VERIFY_GATES, which is deliberately NOT run-discovery.sh's LLM_MAX_DISCOVERY_CELLS: STAGE 3 and
# STAGE 4 are sequential stages, so one forwarded --jobs can never stack the two ceilings.
GATE_CAP="${LLM_MAX_VERIFY_GATES:-4}"
case "$GATE_CAP" in ''|*[!0-9]*) GATE_CAP=4 ;; esac
[ "$GATE_CAP" -ge 1 ] || GATE_CAP=4
effective_jobs="$JOBS"
# --jobs > 1 uses `wait -n` (bash >= 4.3). On an older bash, degrade to the serial path rather than misbehave.
if [ "$JOBS" -gt 1 ]; then
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 3 ]; }; then
    echo "verify-findings.sh: --jobs > 1 needs bash >= 4.3 (wait -n) — running serially instead" >&2
    JOBS=1
    effective_jobs=1
  elif [ "$effective_jobs" -gt "$GATE_CAP" ]; then
    echo "verify-findings.sh: --jobs $JOBS exceeds the hard cap LLM_MAX_VERIFY_GATES=$GATE_CAP; clamping concurrency to $GATE_CAP" >&2
    effective_jobs="$GATE_CAP"
  fi
fi

REPO_NAME="$(basename "$REPO")"
# #1861: the refute gate stages exactly ONE file, so a candidate anchored in an abstract base is judged with
# no implementation of it in view — the measured "…in this contract contains no…" refutation. lib/inheritance.py
# names the representative implementor and auditor/slice-fns.sh cuts it down to the members that carry the
# base's virtual behaviour. Both are OPTIONAL: either one missing means no aux, and a byte-identical manifest.
INHERITANCE="$HERE/lib/inheritance.py"
SLICER="$HERE/auditor/slice-fns.sh"
WORK="$OUT/.verify-work"; rm -rf "$WORK"; mkdir -p "$WORK"
CELLS="$OUT/gates"; rm -rf "$CELLS"; mkdir -p "$CELLS"
# #2284: batch dirs from an EARLIER run in this --out never survive into this one (a no-op on a fresh --out; an OFF
# run leaves none behind, by contract).
BATCHES="$OUT/gates-batch"; rm -rf "$BATCHES"
CONFIRMED_TSV="$WORK/confirmed.tsv"; : > "$CONFIRMED_TSV"
# #2257: candidates the refute gate routed to a DECLARED out-of-scope premise. Created LAZILY (first row), and the
# JSON pass reads it only if it exists, so a default run gains no key.
OOS_TSV="$WORK/out-of-scope.tsv"
OUT_OF_SCOPE=0

# --- #2257: the declared-scope block, built ONCE per run and handed to every refute gate. SCOPE_BLOCK stays empty
#     (=> run_gate_refute passes nothing) when --scope-docs is unset, when nothing was declared, when the
#     extraction failed (fail-open: a broken doc must not abort STAGE 4), or when the rubric the layer is nested
#     under is off. Only the refute gate reads it.
#     SCOPE_STATE / SCOPE_REASON record WHICH of those happened, and land in verified_findings.json as
#     `scope_layer: {state, reason}` whenever --scope-docs was requested (never when it is unset, so OFF stays
#     byte-identical): `on`, `off` (nothing declared / non-refute gate / rubric off) or `inert-extractor-error` —
#     a fail-open that is visible in the artifact, not only on stderr.
SCOPE_BLOCK="" ; SCOPE_STATE="" ; SCOPE_REASON="" ; SCOPE_EXTRACT_FAILED=0
if [ -n "$SCOPE_DOCS" ]; then
  SCOPE_LIB="$HERE/lib/scope-assumptions.py"
  SCOPE_OUT="$OUT/scope-assumptions.txt"
  if [ "$SCOPE_DOCS" = "auto" ]; then
    python3 "$SCOPE_LIB" extract --repo "$REPO" > "$SCOPE_OUT" 2>"$WORK/scope-extract.err" \
      || { echo "verify-findings.sh: WARNING: scope extraction failed ($(head -1 "$WORK/scope-extract.err")) — scope layer inert" >&2; : > "$SCOPE_OUT"; SCOPE_EXTRACT_FAILED=1; }
  else
    python3 "$SCOPE_LIB" extract --repo "$REPO" --operator "$SCOPE_DOCS" > "$SCOPE_OUT" 2>"$WORK/scope-extract.err" \
      || { echo "verify-findings.sh: WARNING: scope extraction failed ($(head -1 "$WORK/scope-extract.err")) — scope layer inert" >&2; : > "$SCOPE_OUT"; SCOPE_EXTRACT_FAILED=1; }
  fi
  # #2292: on a successful extraction the helper's stderr is its count of DROPPED operator bullets (source-file
  # and unclassified). It must reach the run log: a curated file that silently lost rows is the #1426 trap.
  if [ "$SCOPE_EXTRACT_FAILED" -eq 0 ] && [ -s "$WORK/scope-extract.err" ]; then
    sed 's/^/verify-findings.sh: /' "$WORK/scope-extract.err" >&2
  fi
  if [ "$SCOPE_EXTRACT_FAILED" -eq 1 ]; then
    SCOPE_STATE="inert-extractor-error"
    SCOPE_REASON="scope extraction failed: $(head -1 "$WORK/scope-extract.err" | tr '\t' ' ')"
  elif [ ! -s "$SCOPE_OUT" ]; then
    SCOPE_STATE="off"; SCOPE_REASON="the scope docs declared no assumption"
    echo "verify-findings.sh: --scope-docs $SCOPE_DOCS declared no assumption — scope layer inert" >&2
  elif [ "$GATE" != "refute" ]; then
    SCOPE_STATE="off"; SCOPE_REASON="the scope block is read by the refute gate only (gate $GATE)"
    echo "verify-findings.sh: WARNING: --scope-docs is read by the refute gate only (--gate $GATE) — scope layer inert" >&2
  elif [ "${SEVERITY_RUBRIC:-}" != "1" ]; then
    SCOPE_STATE="off"; SCOPE_REASON="SEVERITY_RUBRIC is not 1 (the scope layer is nested under the rubric)"
    echo "verify-findings.sh: WARNING: --scope-docs extracted $(wc -l < "$SCOPE_OUT" | tr -d ' ') assumption(s) but SEVERITY_RUBRIC is not 1 — the scope layer is nested under the rubric and is INERT for this run" >&2
  else
    SCOPE_BLOCK="$SCOPE_OUT"
    SCOPE_STATE="on"; SCOPE_REASON="$(wc -l < "$SCOPE_OUT" | tr -d ' ') declared assumption(s) handed to every refute gate"
    echo "verify-findings.sh: scope layer: $(wc -l < "$SCOPE_OUT" | tr -d ' ') declared assumption(s) -> every refute gate ($SCOPE_OUT)" >&2
    # #2292: say whether the in-scope-file guard is armed — a silently inert guard is the #1426 trap.
    if [ -n "$SCOPE_MAP" ]; then
      SCOPE_REASON="$SCOPE_REASON; in-scope-file guard armed (--scope-map)"
    else
      SCOPE_REASON="$SCOPE_REASON; in-scope-file guard NOT armed (no --scope-map)"
      echo "verify-findings.sh: scope layer: no --scope-map — an exclusion row naming an in-scope file is NOT rejected by the decider" >&2
    fi
  fi
fi

# The gate-specific CONFIRMED token: refute=REAL, poc=FINDING, symbolic=COUNTEREXAMPLE.
case "$GATE" in
  refute)   CONFIRM_TOKEN="REAL" ;;
  poc)      CONFIRM_TOKEN="FINDING" ;;
  symbolic) CONFIRM_TOKEN="COUNTEREXAMPLE" ;;
esac

# --- parse discovery-results.json -> a per-candidate work manifest (python3, the read-only parse). Splits each
#     cells[].candidates[] on `|` into <file:fn:line>|<classid>|<severity>|<exploit>|<poc sketch> and derives the
#     code file via bare_codefile() — the hunter sometimes decorates the location with an `@func` compound suffix
#     or a `:~(test/File.t.sol:test_fn)` parenthetical (#1691), so a naive split(":",1)[0] yields a path that is
#     never on disk and the candidate is then silently dropped as if rigorously refuted. bare_codefile strips the
#     decorations back to a resolvable repo-relative source path. Also flags a MALFORMED candidate (blank class OR
#     severity = a truncated record) so the loop can ERROR it loudly instead of landing a content-less finding.
#     One TSV line per candidate; this NEVER writes back to discovery-results.json.
python3 - "$RESULTS" > "$WORK/candidates.tsv" <<'PY'
import sys, json


def bare_codefile(location):
    # Reduce a (possibly decorated) location to the bare repo-relative source path. Strip order is PINNED and is
    # a no-op on an already-well-formed `file:function[:line]` shape (asserted in demo-verify-findings.sh):
    s = location
    s = s.split("~", 1)[0]    # (A) drop a `:~(test/File.t.sol:test_fn)` test-reference tail (and its colons)
    s = s.split(":", 1)[0]    # (B) the file is the part before the FIRST ':' delimiter
    s = s.split("@", 1)[0]    # (C) drop a compound `@func` suffix
    s = s.strip().rstrip("(").strip()  # (D) trim whitespace and a stray trailing '('
    return s


data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = []
for cell in data.get("cells", []):
    subsystem = cell.get("subsystem", "")
    for cand in cell.get("candidates", []):
        parts = cand.split("|", 4)
        while len(parts) < 5:
            parts.append("")
        location, classid, severity, exploit, sketch = parts[0], parts[1], parts[2], parts[3], parts[4]
        codefile = bare_codefile(location)
        # A blank class OR severity is the signature of a truncated record — route it to ERROR, never a finding.
        malformed = "1" if (classid.strip() == "" or severity.strip() == "") else "0"
        # TAB-safe: candidate fields ride a single JSON string line (no tabs / newlines); scrub defensively.
        fields = [subsystem, location, codefile, classid, severity, exploit, sketch, malformed]
        fields = [f.replace("\t", " ").replace("\n", " ") for f in fields]
        rows.append("\t".join(fields))
sys.stdout.write("\n".join(rows))
if rows:
    sys.stdout.write("\n")
PY

# --- #1962: --pay-floor PARTITION. Runs BEFORE the gate loop below (and therefore before any --jobs > 1
#     PJ_* array split), so a sub-floor candidate never enters either the serial or parallel dispatch path —
#     it never reaches gate_candidate at all, saving a refute/PoC/symbolic pass on a lead that can never pay
#     on this program. SEV_RANK/rank_of mirror finding-payability-gate.sh's closed severity vocabulary
#     VERBATIM (see that file's header + rank_of()) rather than re-deriving a second, driftable definition.
#     FAIL-OPEN, in order: PAY_FLOOR unset/blank -> every candidate KEPT (this whole block is then a no-op:
#     candidates.tsv is rewritten byte-identically and dropped-subfloor.tsv stays empty). A MALFORMED
#     candidate (#1691 blank class/severity) is left untouched -> still routes to the existing ERRORED path,
#     regardless of --pay-floor; the partition only ever looks at well-formed rows with a resolvable severity.
#     A BLANK LOCATION (#1965) is likewise left untouched -> it reaches the gate loop's existing uncounted
#     skip, never entering dropped_subfloor.
#     A blank/unrecognized severity on a well-formed row -> KEPT (never dropped on missing data). Otherwise
#     rank(severity) < rank(PAY_FLOOR) -> DROPPED into dropped-subfloor.tsv (same 8 columns); else KEPT.
DROPPED_SUBFLOOR_TSV="$WORK/dropped-subfloor.tsv"; : > "$DROPPED_SUBFLOOR_TSV"
SUBFLOOR=0
if [ -n "$PAY_FLOOR" ]; then
  KEPT_TSV="$WORK/candidates-kept.tsv"
  PAY_FLOOR="$PAY_FLOOR" python3 - "$WORK/candidates.tsv" "$KEPT_TSV" "$DROPPED_SUBFLOOR_TSV" <<'PY'
import sys, os

# Closed severity rank — kept as a literal cross-referencing finding-payability-gate.sh's SEV_RANK (that
# file's rank_of()) rather than a shared lib/ helper: this is a SMALL, self-contained partition (#1962) and a
# second copy of one four-entry dict is not worth introducing a shared module for.
SEV_RANK = {"low": 1, "medium": 2, "high": 3, "critical": 4}
floor_rank = SEV_RANK[os.environ["PAY_FLOOR"].strip().lower()]

src, kept_path, dropped_path = sys.argv[1], sys.argv[2], sys.argv[3]
kept_lines, dropped_lines = [], []
with open(src, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        f = line.split("\t")
        while len(f) < 8:
            f.append("")
        location, severity, malformed = f[1], f[4], f[7]
        if malformed == "1" or location.strip() == "":
            kept_lines.append(line)  # #1691 malformed OR #1965 blank location: untouched, mirrors the
            continue                 # gate loop's line-466 uncounted skip so both stages agree on 'well-formed'.
        rank = SEV_RANK.get(severity.strip().lower())
        if rank is not None and rank < floor_rank:
            dropped_lines.append(line)
        else:
            kept_lines.append(line)  # unknown/blank severity (rank is None) fails OPEN -> kept.

with open(kept_path, "w", encoding="utf-8") as fh:
    for l in kept_lines:
        fh.write(l + "\n")
with open(dropped_path, "w", encoding="utf-8") as fh:
    for l in dropped_lines:
        fh.write(l + "\n")
PY
  mv "$KEPT_TSV" "$WORK/candidates.tsv"
  SUBFLOOR="$(wc -l < "$DROPPED_SUBFLOOR_TSV" | tr -d ' ')"
  case "$SUBFLOOR" in ''|*[!0-9]*) SUBFLOOR=0 ;; esac
  if [ "$SUBFLOOR" -gt 0 ]; then
    echo "verify-findings.sh: skipped $SUBFLOOR sub-floor candidate(s) (below pay-floor $PAY_FLOOR), saved $SUBFLOOR refute/verify pass(es)" >&2
  fi
fi

# --- #2023: OPERATOR-ADJUDICATION lookup. Normalize each row of the adjudication overlay (adjudicated.tsv:
#     loc \t class \t sev \t verdict \t reason) to the SAME slug the cell dir uses at the candidate loop
#     (tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//') so a candidate's SLUG matches an adjudicated location EXACTLY as
#     the dashboard's _normloc does — location-only keying (protect the location regardless of class). Absent,
#     blank, or unset --adjudicated leaves ADJ_KEYS empty and the whole feature inert (a byte-identical run).
ADJ_KEYS="$WORK/adjudicated-keys.tsv"; : > "$ADJ_KEYS"
if [ -n "$ADJUDICATED" ] && [ -f "$ADJUDICATED" ]; then
  while IFS= read -r ADJROW || [ -n "${ADJROW:-}" ]; do
    [ -n "$ADJROW" ] || continue
    ADJ_LOC="$(printf '%s\n' "$ADJROW" | cut -f1)"
    ADJ_V="$(printf '%s\n' "$ADJROW" | cut -f4)"
    [ -n "$ADJ_LOC" ] || continue
    ADJ_K="$(printf '%s' "$ADJ_LOC" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
    [ -n "$ADJ_K" ] || continue
    printf '%s\t%s\n' "$ADJ_K" "$ADJ_V" >> "$ADJ_KEYS"
  done < "$ADJUDICATED"
fi

# adj_lookup <slug> -> prints the operator verdict adjudicated for that normalized location, or nothing. Empty
# ADJ_KEYS (the inert default) always prints nothing, so every caller degrades to today's gate path.
adj_lookup() {
  al_key="$1"
  [ -s "$ADJ_KEYS" ] || return 0
  awk -F'\t' -v k="$al_key" '$1==k{print $2; exit}' "$ADJ_KEYS"
}

# resolve_aux_code <out> <relfile> -> prints the absolute path of a staged, function-sliced implementation
# APPENDIX for <relfile>, or nothing (#1861). Fires only when <relfile> declares an `abstract contract` with
# body-less `virtual` members AND a descendant elsewhere in the repo implements at least one of them; the
# whole helper degrades to "no aux" on every other input, so a target with no abstract bases produces a
# byte-identical gate manifest. Also writes <out>/aux.txt — the per-candidate record of WHAT was attached, so
# a verdict that turns on the appendix is attributable from the artifacts alone.
resolve_aux_code() {
  ra_out="$1"; ra_relfile="$2"
  [ -f "$INHERITANCE" ] && [ -x "$SLICER" ] || return 0
  ra_hit="$(python3 "$INHERITANCE" implementor --repo "$REPO" --file "$ra_relfile" 2>/dev/null || true)"
  [ -n "$ra_hit" ] || return 0
  ra_impl="$(printf '%s\n' "$ra_hit" | head -1 | cut -f1)"
  ra_fns="$(printf '%s\n' "$ra_hit" | head -1 | cut -f2)"
  [ -n "$ra_impl" ] && [ -n "$ra_fns" ] && [ -f "$REPO/$ra_impl" ] || return 0
  "$SLICER" "$REPO/$ra_impl" "$ra_fns" > "$ra_out/aux.sol" 2>/dev/null || { rm -f "$ra_out/aux.sol"; return 0; }
  [ -s "$ra_out/aux.sol" ] || { rm -f "$ra_out/aux.sol"; return 0; }
  printf '%s@%s\n' "$ra_impl" "$ra_fns" > "$ra_out/aux.txt"
  printf '%s' "$ra_out/aux.sol"
}

# cand_slug <location> -> the cell-dir slug of a candidate location (#2284: one copy for the candidate loop and
# the batch planning pass, so a planned member always lands in the gates/<n>_<slug>/ dir the loop derives).
cand_slug() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//'
}

# cand_preflight <malformed> <codefile> -> the #1691 preflight reason (a malformed record, or a code file that does
# not resolve), or nothing when the candidate may reach its gate. Shared by the candidate loop and the #2284
# planning pass so both agree on which candidates are gate-bound.
cand_preflight() {
  if [ "${1:-0}" = "1" ]; then
    printf '%s' "malformed candidate (blank class/severity — truncated record)"
  elif [ ! -f "$REPO/$2" ]; then
    printf '%s' "code file not found: $2"
  fi
}

# scrape_refute_report <out> -> <out>/verdict.txt ("<VERDICT>\t<reason>") and <out>/eff-class.txt from the single
# data row of <out>/refute-out/refute-report.md (`| <location> | <class> | <VERDICT> | <reason> |`; fields 4/5).
scrape_refute_report() {
  sr_out="$1"
  sr_report="$sr_out/refute-out/refute-report.md"
  [ -f "$sr_report" ] || { printf 'REFUTED\tno refute report produced (dropped as unverified)\n' > "$sr_out/verdict.txt"; return 0; }
  awk -F'|' '
    NF>=5 { v=$4; gsub(/[[:space:]]/,"",v);
      if (v=="REAL"||v=="REFUTED"||v=="ERROR") { r=$5; sub(/^[[:space:]]+/,"",r); sub(/[[:space:]]+$/,"",r);
        print v "\t" r; found=1; exit } }
    END { if (!found) print "REFUTED\tno verdict row (dropped as unverified)" }
  ' "$sr_report" > "$sr_out/verdict.txt"
  # #1699: also scrape the WINNING class from the same (first) data row. run-refute.sh's #1699 C6 fallback can
  # convert a candidate REFUTED under its assigned class into REAL under C6 and emits the report row with the
  # class it SURVIVED under — read that back so verified_findings.json records C6, not the mislabelled input.
  awk -F'|' '
    NF>=5 { v=$4; gsub(/[[:space:]]/,"",v);
      if (v=="REAL"||v=="REFUTED"||v=="ERROR") { c=$3; gsub(/[[:space:]]/,"",c); print c; exit } }
  ' "$sr_report" > "$sr_out/eff-class.txt"
  return 0
}

# The refute argv every refute call shares (#2284: built ONCE, so the batched first read and the single-candidate
# gate can never be handed a different brief, backend, model or scope block).
REFUTE_ARGS=(--code-dir "$REPO")
[ -z "$BRIEF" ] || REFUTE_ARGS+=(--brief "$BRIEF")
REFUTE_ARGS+=(--backend "$BACKEND" --agentis "$AGENTIS")
[ -z "$MODEL" ] || REFUTE_ARGS+=(--model "$MODEL")
[ -z "$SCOPE_BLOCK" ] || REFUTE_ARGS+=(--scope-assumptions "$SCOPE_BLOCK")
[ -z "$SCOPE_BLOCK" ] || [ -z "$SCOPE_MAP" ] || REFUTE_ARGS+=(--scope-map "$SCOPE_MAP")

# run_gate_refute <out> <location> <class> <severity> <exploit> <relfile> [<first-read-log>] -> writes
# <out>/verdict.txt as "<VERDICT>\t<reason>"; returns 0 when the gate RAN (any verdict, incl. no-verdict ->
# REFUTED), non-zero only when the gate itself errored (so the caller SKIPS that candidate). The refuter report row
# is `| <location> | <class> | <VERDICT> | <reason> |`; we read field 4/5 of the single data row. The optional 7th
# argument (#2284) is this candidate's block from a batched first read, forwarded as --first-read-log; empty =
# today's call.
run_gate_refute() {
  rg_out="$1"; rg_loc="$2"; rg_cls="$3"; rg_sev="$4"; rg_expl="$5"; rg_relfile="$6"; rg_frl="${7:-}"
  mkdir -p "$rg_out"
  # #1861: the OPTIONAL 6th manifest column. No hit -> the line has five fields, byte-identical to today.
  rg_aux="$(resolve_aux_code "$rg_out" "$rg_relfile")"
  if [ -n "$rg_aux" ]; then
    echo "verify-findings.sh:   + implementation appendix for the abstract base $rg_relfile: $(cat "$rg_out/aux.txt")" >&2
    printf '%s|%s|%s|%s|%s|%s\n' "$rg_loc" "$rg_cls" "$rg_sev" "$rg_expl" "$rg_relfile" "$rg_aux" > "$rg_out/candidate.manifest"
  else
    printf '%s|%s|%s|%s|%s\n' "$rg_loc" "$rg_cls" "$rg_sev" "$rg_expl" "$rg_relfile" > "$rg_out/candidate.manifest"
  fi
  "$REFUTE" --candidates "$rg_out/candidate.manifest" "${REFUTE_ARGS[@]}" ${rg_frl:+--first-read-log "$rg_frl"} \
    --out "$rg_out/refute-out" >"$rg_out/gate.log" 2>&1 || return 1
  scrape_refute_report "$rg_out"
}

# run_gate_poc <out> <class> <exploit> <relfile> -> the concrete-PoC gate. CONFIRMED = FINDING.
run_gate_poc() {
  rp_out="$1"; rp_cls="$2"; rp_expl="$3"; rp_relfile="$4"
  mkdir -p "$rp_out"
  rp_target="$(basename "$rp_relfile")"
  "$POC" --repo "$REPO" --target "$rp_target" --hypothesis "$rp_expl" --class "$rp_cls" \
    --backend "$BACKEND" --agentis "$AGENTIS" --out "$rp_out/poc-out" >"$rp_out/gate.log" 2>&1 || return 1
  rp_line="$(grep 'POC|' "$rp_out/gate.log" | tail -1 || true)"
  if [ -z "$rp_line" ]; then
    printf 'NO-POC\tno POC verdict line produced (dropped as unverified)\n' > "$rp_out/verdict.txt"; return 0
  fi
  rp_verd="$(printf '%s' "$rp_line" | sed 's/^.*\(POC|\)/\1/' | cut -d'|' -f3)"
  printf '%s\t%s\n' "$rp_verd" "concrete PoC gate over $rp_target" > "$rp_out/verdict.txt"
  return 0
}

# run_gate_symbolic <out> <location> <class> <exploit> <relfile> -> the Halmos gate. CONFIRMED = COUNTEREXAMPLE.
run_gate_symbolic() {
  rs_out="$1"; rs_loc="$2"; rs_cls="$3"; rs_expl="$4"; rs_relfile="$5"
  mkdir -p "$rs_out"
  printf '%s|%s|%s|%s|\n' "$rs_loc" "$rs_cls" "$rs_expl" "$rs_relfile" > "$rs_out/candidate.manifest"
  "$SYMBOLIC" --candidates "$rs_out/candidate.manifest" --repo "$REPO" --code-dir "$REPO" \
    --backend "$BACKEND" --agentis "$AGENTIS" --out "$rs_out/symbolic-out" >"$rs_out/gate.log" 2>&1 || return 1
  rs_line="$(grep 'SYMBOLIC|' "$rs_out/gate.log" | tail -1 || true)"
  if [ -z "$rs_line" ]; then
    printf 'INCONCLUSIVE\tno SYMBOLIC verdict line produced (dropped as unverified)\n' > "$rs_out/verdict.txt"; return 0
  fi
  rs_verd="$(printf '%s' "$rs_line" | sed 's/^.*\(SYMBOLIC|\)/\1/' | cut -d'|' -f3)"
  printf '%s\t%s\n' "$rs_verd" "symbolic (Halmos) gate over $rs_loc" > "$rs_out/verdict.txt"
  return 0
}

CANDIDATES=0 ; VERIFIED=0 ; SKIPPED=0 ; ERRORED=0
ERRORS_TSV="$WORK/errored.tsv"; : > "$ERRORS_TSV"

# --- factored per-candidate primitives (#1863). The serial loop and the deferred parallel pass call these
# IDENTICALLY; only the DISPATCH differs between the two paths, so the block that decides verified[] /
# errors[] membership and ORDER — the likeliest place for a silent serial-vs-parallel divergence — exists in
# exactly ONE copy. All shared state (the counters, confirmed.tsv, errored.tsv) is mutated by the PARENT
# shell only; a backgrounded job writes solely inside its own per-candidate gates/<n>_<slug>/ directory. ---

# gate_candidate <cell_out> <location> <class> <severity> <exploit> <codefile> — dispatch the operator-selected
# gate for ONE candidate. Returns the gate's rc: 0 = the gate RAN (any verdict), non-zero = the gate itself
# errored (the caller SKIPS that candidate). run_gate_refute / run_gate_poc / run_gate_symbolic are untouched.
gate_candidate() {
  gc_out="$1"; gc_loc="$2"; gc_cls="$3"; gc_sev="$4"; gc_expl="$5"; gc_file="$6"
  case "$GATE" in
    refute)   run_gate_refute   "$gc_out" "$gc_loc" "$gc_cls" "$gc_sev" "$gc_expl" "$gc_file" ;;
    poc)      run_gate_poc      "$gc_out" "$gc_cls" "$gc_expl" "$gc_file" ;;
    symbolic) run_gate_symbolic "$gc_out" "$gc_loc" "$gc_cls" "$gc_expl" "$gc_file" ;;
  esac
}

# record_errored <location> <codefile> <reason> <status> — the ONE place a candidate lands in errors[]: the
# TSV append, the counter bump and the `-> ERRORED (<status>)` operator line. <status> keeps the two callers'
# distinct wording (the #1691 preflight's `ERROR_MALFORMED: …` vs the gate-propagated `ERROR` token).
record_errored() {
  re_loc="$1"; re_file="$2"; re_reason="$3"; re_status="$4"
  printf '%s\t%s\t%s\n' "$re_loc" "$re_file" "$re_reason" >> "$ERRORS_TSV"
  ERRORED=$((ERRORED + 1))
  echo "verify-findings.sh:   -> ERRORED ($re_status)" >&2
}

# classify_candidate <gate_rc> <cell_out> <subsys> <location> <codefile> <class> <severity> <exploit> <sketch>
# — everything the walk does with a gated candidate that is not the gate call itself: the gate-errored SKIP,
# the verdict read, the ERROR route into errors[], the CONFIRMED append into confirmed.tsv (#1699 effective
# class included) and the dropped line. A gate_rc that is not 0 — INCLUDING a missing or empty gate.rc under
# --jobs > 1, which the caller normalises to 1 — is the SKIPPED path: a background job the OOM killer took is
# a visibly unassessed candidate, never a silent drop and never a confirmed finding.
classify_candidate() {
  cc_rc="$1"; cc_out="$2"; cc_subsys="$3"; cc_loc="$4"; cc_file="$5"
  cc_cls="$6"; cc_sev="$7"; cc_expl="$8"; cc_sketch="$9"
  if [ "$cc_rc" -ne 0 ]; then
    echo "verify-findings.sh: gate errored for $cc_loc (see $cc_out/gate.log); skipping" >&2
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  cc_verd="$(cut -f1 "$cc_out/verdict.txt")"
  cc_reason="$(cut -f2- "$cc_out/verdict.txt")"
  if [ "$cc_verd" = "ERROR" ]; then
    # A gate that PROPAGATED an ERROR token (e.g. run-refute.sh's loud unresolvable-code row) — errored, not
    # refuted (change 2 pre-validates, so this belt-and-suspenders path is rarely reached inside the pipeline).
    record_errored "$cc_loc" "$cc_file" "$cc_reason" "$cc_verd"
  elif [ "$cc_verd" = "$CONFIRM_TOKEN" ]; then
    # #1699: for the refute gate, record the class the candidate actually SURVIVED under (run-refute.sh's C6
    # fallback may differ from the originally-assigned class), so verified_findings.json is not mislabelled.
    cc_eff_class="$cc_cls"
    if [ "$GATE" = "refute" ] && [ -s "$cc_out/eff-class.txt" ]; then
      cc_eff="$(cat "$cc_out/eff-class.txt")"
      [ -n "$cc_eff" ] && [ "$cc_eff" != "$cc_cls" ] && cc_eff_class="$cc_eff"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$cc_subsys" "$cc_loc" "$cc_file" "$cc_eff_class" "$cc_sev" "$cc_expl" "$cc_sketch" "$cc_verd" "$cc_reason" >> "$CONFIRMED_TSV"
    VERIFIED=$((VERIFIED + 1))
    echo "verify-findings.sh:   -> CONFIRMED ($cc_verd)" >&2
  elif [ "$GATE" = "refute" ] && [ -s "$cc_out/refute-out/out-of-scope.tsv" ]; then
    # #2257: refuted on a CONTRACT-PASSING declared out-of-scope premise. Kept VISIBLE in out_of_scope[] (never
    # verified[]); the gate's own sidecar row carries the assumption fields (columns 3..7).
    cc_oos="$(head -1 "$cc_out/refute-out/out-of-scope.tsv" | cut -f3-)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$cc_subsys" "$cc_loc" "$cc_file" "$cc_cls" "$cc_sev" "$cc_expl" "$cc_sketch" "$cc_verd" "$cc_reason" "$cc_oos" >> "$OOS_TSV"
    OUT_OF_SCOPE=$((OUT_OF_SCOPE + 1))
    echo "verify-findings.sh:   -> OUT-OF-SCOPE (declared premise $(printf '%s' "$cc_oos" | cut -f1))" >&2
  else
    echo "verify-findings.sh:   -> dropped ($cc_verd)" >&2
  fi
  return 0
}

# --- #2284: BATCH PLANNING (refute gate + --refute-batch 1 only). A pre-pass over the FINAL candidates.tsv (after
#     --pay-floor) with the candidate loop's own counter, slug, adjudication and preflight helpers, so only the rows
#     that would really reach the gate are planned and every planned n is the n the loop will assign.
#     lib/refute-batch.py groups them by (file, function) + code file and writes one `batch \t k \t size \t n \t
#     slug` row per batched member. A planner failure is a WARNING and no batching (fail-open to today); OFF leaves
#     the plan empty, so every lookup below prints nothing and the loop is untouched.
BATCH_PLAN="$WORK/batch-plan.tsv"; : > "$BATCH_PLAN"
BATCH_FIELDS="$WORK/batch-fields.tsv"; : > "$BATCH_FIELDS"
BATCHED_N=0 ; BATCH_COUNT=0
if [ "$REFUTE_BATCH" = "1" ]; then
  BATCH_ELIGIBLE="$WORK/batch-eligible.tsv"; : > "$BATCH_ELIGIBLE"
  bp_n=0
  while IFS= read -r BPROW || [ -n "${BPROW:-}" ]; do
    [ -n "$BPROW" ] || continue
    bp_loc="$(printf '%s\n' "$BPROW" | cut -f2)"
    [ -n "$bp_loc" ] || continue
    bp_n=$((bp_n + 1))
    bp_slug="$(cand_slug "$bp_loc")"
    [ -z "$(adj_lookup "$bp_slug")" ] || continue
    bp_file="$(printf '%s\n' "$BPROW" | cut -f3)"
    [ -z "$(cand_preflight "$(printf '%s\n' "$BPROW" | cut -f8)" "$bp_file")" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$bp_n" "$bp_slug" "$bp_loc" "$bp_file" >> "$BATCH_ELIGIBLE"
    # n, location, class, severity, exploit, code file — the six values run_gate_refute takes, in its order.
    printf '%s\t%s\t%s\t%s\n' "$bp_n" "$bp_loc" "$(printf '%s\n' "$BPROW" | cut -f4-6)" "$bp_file" >> "$BATCH_FIELDS"
  done < "$WORK/candidates.tsv"
  if python3 "$HERE/lib/refute-batch.py" plan --in "$BATCH_ELIGIBLE" --max "$REFUTE_BATCH_MAX" \
       > "$BATCH_PLAN" 2> "$WORK/batch-plan.err"; then
    BATCHED_N="$(grep -c . "$BATCH_PLAN" || true)"
    BATCH_COUNT="$(cut -f1 "$BATCH_PLAN" | sort -u | grep -c . || true)"
    echo "verify-findings.sh: refute batching: $BATCHED_N candidate(s) in $BATCH_COUNT batched first-read session(s) ($(grep '^BATCHPLAN|' "$WORK/batch-plan.err" | tail -1))" >&2
  else
    echo "verify-findings.sh: WARNING: the refute batch planner failed ($(head -1 "$WORK/batch-plan.err")) — refuting every candidate individually (fail-open, #2284)" >&2
    : > "$BATCH_PLAN"
  fi
fi

# batch_of <n> -> `<batch>\t<k>\t<size>` when candidate n is a planned batch member, else nothing.
batch_of() {
  [ -s "$BATCH_PLAN" ] || return 0
  awk -F'\t' -v n="$1" '$4==n { print $1 "\t" $2 "\t" $3; exit }' "$BATCH_PLAN"
}

# batch_dir <batch> -> <out>/gates-batch/<batch>_<slug of its first member>.
batch_dir() {
  printf '%s/%s_%s' "$BATCHES" "$1" "$(awk -F'\t' -v b="$1" '$1==b { print $5; exit }' "$BATCH_PLAN")"
}

# run_refute_batch <batch> — ONE batched first read, then every member's normal single-candidate gate, IN ORDER,
# inside the caller's slot (one job under --jobs). Each member's gate gets its own block from the split when there
# is one (--first-read-log) and nothing otherwise, so a failed batch degrades to today's per-candidate gates. Writes
# each member's gates/<n>_<slug>/gate.rc + batch.txt, then <dir>/done. Every refute call reads /dev/null, so no
# child can consume the caller's candidates.tsv read.
run_refute_batch() {
  rb_b="$1"
  rb_dir="$(batch_dir "$rb_b")"
  mkdir -p "$rb_dir"
  : > "$rb_dir/batch.manifest"; : > "$rb_dir/members.tsv"
  awk -F'\t' -v b="$rb_b" '$1==b' "$BATCH_PLAN" > "$rb_dir/plan.tsv"
  rb_aux="" ; rb_first=1
  while IFS="$(printf '\t')" read -r _rb_b rb_k rb_size rb_n rb_slug || [ -n "${rb_k:-}" ]; do
    [ -n "$rb_k" ] || continue
    rb_row="$(awk -F'\t' -v n="$rb_n" '$1==n { print; exit }' "$BATCH_FIELDS")"
    rb_loc="$(printf '%s\n' "$rb_row" | cut -f2)"; rb_cls="$(printf '%s\n' "$rb_row" | cut -f3)"
    rb_sev="$(printf '%s\n' "$rb_row" | cut -f4)"; rb_expl="$(printf '%s\n' "$rb_row" | cut -f5)"
    rb_file="$(printf '%s\n' "$rb_row" | cut -f6)"
    if [ "$rb_first" -eq 1 ]; then
      # The appendix is a property of the shared code file: resolve it once, exactly as run_gate_refute does.
      rb_aux="$(resolve_aux_code "$rb_dir" "$rb_file")"
      rb_first=0
    fi
    if [ -n "$rb_aux" ]; then
      printf '%s|%s|%s|%s|%s|%s\n' "$rb_loc" "$rb_cls" "$rb_sev" "$rb_expl" "$rb_file" "$rb_aux" >> "$rb_dir/batch.manifest"
    else
      printf '%s|%s|%s|%s|%s\n' "$rb_loc" "$rb_cls" "$rb_sev" "$rb_expl" "$rb_file" >> "$rb_dir/batch.manifest"
    fi
    printf '%s\t%s\t%s\t%s\n' "$rb_k" "$rb_n" "$rb_slug" "$rb_loc" >> "$rb_dir/members.tsv"
  done < "$rb_dir/plan.tsv"
  "$REFUTE" --batch-first-read --candidates "$rb_dir/batch.manifest" "${REFUTE_ARGS[@]}" \
    --out "$rb_dir/refute-out" </dev/null >"$rb_dir/gate.log" 2>&1 \
    || echo "verify-findings.sh: WARNING: batched first read $rb_b failed (see $rb_dir/gate.log) — its members are refuted individually" >&2
  while IFS="$(printf '\t')" read -r _rb_b rb_k rb_size rb_n rb_slug || [ -n "${rb_k:-}" ]; do
    [ -n "$rb_k" ] || continue
    rb_row="$(awk -F'\t' -v n="$rb_n" '$1==n { print; exit }' "$BATCH_FIELDS")"
    rb_cell="$CELLS/${rb_n}_${rb_slug}"
    rb_split="$rb_dir/refute-out/split/$rb_k.log"
    [ -f "$rb_split" ] || rb_split=""
    rb_rc=0
    run_gate_refute "$rb_cell" "$(printf '%s\n' "$rb_row" | cut -f2)" "$(printf '%s\n' "$rb_row" | cut -f3)" \
      "$(printf '%s\n' "$rb_row" | cut -f4)" "$(printf '%s\n' "$rb_row" | cut -f5)" "$(printf '%s\n' "$rb_row" | cut -f6)" \
      "$rb_split" </dev/null || rb_rc=1
    printf '%s' "$rb_rc" > "$rb_cell/gate.rc"
    printf '%s\t%s\t%s\n' "$rb_b" "$rb_k" "$rb_size" > "$rb_cell/batch.txt"
  done < "$rb_dir/plan.tsv"
  : > "$rb_dir/done"
}

# #1863 parallel bookkeeping: ONE row per candidate, pushed in MANIFEST order by the launch loop and replayed
# by the deferred pass below. Untouched (and unread) on the serial path. PJ_PREFLIGHT carries the #1691
# preflight reason when the candidate never reached a gate — the row is NOT emitted inline, because emitting
# preflight errors during the launch loop while gate-ERROR verdicts land in the drain pass would GROUP them
# instead of interleaving them, and errors[] would then differ between --jobs 1 and --jobs > 1 on any target
# carrying both kinds.
PJ_OUT=() ; PJ_SUBSYS=() ; PJ_LOC=() ; PJ_FILE=() ; PJ_CLS=() ; PJ_SEV=() ; PJ_EXPL=() ; PJ_SKETCH=() ; PJ_PREFLIGHT=()
live=0

# Candidate loop: drive the selected gate over each candidate with per-candidate isolation. A gate that ERRORS
# is logged + SKIPPED (never fatal); an un-CONFIRMED candidate is DROPPED. Only a CONFIRMED verdict is kept.
# A candidate whose normalized code file does NOT resolve on disk, or whose required fields were lost to
# truncation (MALFORMED), is routed to a distinguishable ERRORED status BEFORE the gate runs (#1691) — it is
# never counted as a rigorous REFUTED verdict and never lands a content-less finding in verified[].
# Read one raw TSV line at a time (IFS= so leading/trailing whitespace is preserved) and split with `cut`: a
# tab-whitespace `read` COLLAPSES consecutive empty fields, which would mis-align a truncated candidate's blank
# class/severity and drop the trailing MALFORMED flag — cut preserves every field, empty ones included.
# The parse block below is shared by both paths, so CELL_OUT stays index-stable and artifact paths never move.
while IFS= read -r CANDROW || [ -n "${CANDROW:-}" ]; do
  [ -n "$CANDROW" ] || continue
  SUBSYS="$(printf '%s\n' "$CANDROW" | cut -f1)"
  LOCATION="$(printf '%s\n' "$CANDROW" | cut -f2)"
  CODEFILE="$(printf '%s\n' "$CANDROW" | cut -f3)"
  CLASS="$(printf '%s\n' "$CANDROW" | cut -f4)"
  SEVERITY="$(printf '%s\n' "$CANDROW" | cut -f5)"
  EXPLOIT="$(printf '%s\n' "$CANDROW" | cut -f6)"
  SKETCH="$(printf '%s\n' "$CANDROW" | cut -f7)"
  MALFORMED="$(printf '%s\n' "$CANDROW" | cut -f8)"
  [ -n "$LOCATION" ] || continue
  CANDIDATES=$((CANDIDATES + 1))
  SLUG="$(cand_slug "$LOCATION")"
  CELL_OUT="$CELLS/${CANDIDATES}_${SLUG}"
  # #2023: operator adjudication PRE-EMPTS the gate. If a human has already ruled this location, do NOT
  # re-refute it (waste + risk of overriding the human) — write a PRESERVED verdict.txt and route it through
  # classify_candidate so the gates dir + verified_findings.json stay self-consistent even across a
  # --rehunt-gaps pass that wipes gates/. A real-bug verdict (CONFIRMED/DUPLICATE) is preserved as the gate's
  # CONFIRMED token (kept in verified_findings.json); anything else is preserved as REFUTED (dropped). This runs
  # BEFORE the preflight so an adjudicated location is protected regardless of its class/severity fields.
  ADJ_VERD="$(adj_lookup "$SLUG")"
  if [ -n "$ADJ_VERD" ]; then
    mkdir -p "$CELL_OUT"
    ADJ_VU="$(printf '%s' "$ADJ_VERD" | tr '[:lower:]' '[:upper:]')"
    case "$ADJ_VU" in
      CONFIRMED|DUPLICATE)
        printf '%s\toperator-adjudicated (%s): refute skipped (#2023)\n' "$CONFIRM_TOKEN" "$ADJ_VERD" > "$CELL_OUT/verdict.txt" ;;
      *)
        printf 'REFUTED\toperator-adjudicated (%s): refute skipped (#2023)\n' "$ADJ_VERD" > "$CELL_OUT/verdict.txt" ;;
    esac
    echo "verify-findings.sh: [$GATE] skipping $LOCATION — operator-adjudicated ($ADJ_VERD), refute skipped (#2023)" >&2
    if [ "$JOBS" -le 1 ]; then
      classify_candidate 0 "$CELL_OUT" "$SUBSYS" "$LOCATION" "$CODEFILE" "$CLASS" "$SEVERITY" "$EXPLOIT" "$SKETCH"
      continue
    fi
    # Parallel path: pre-write the rc + verdict and record the row with an EMPTY preflight so the drain pass
    # classifies it from the pre-written verdict.txt WITHOUT launching a gate subshell (never touches `live`).
    PJ_OUT+=("$CELL_OUT") ; PJ_SUBSYS+=("$SUBSYS") ; PJ_LOC+=("$LOCATION") ; PJ_FILE+=("$CODEFILE")
    PJ_CLS+=("$CLASS") ; PJ_SEV+=("$SEVERITY") ; PJ_EXPL+=("$EXPLOIT") ; PJ_SKETCH+=("$SKETCH")
    PJ_PREFLIGHT+=("")
    printf 0 > "$CELL_OUT/gate.rc"
    continue
  fi
  EREASON="$(cand_preflight "${MALFORMED:-0}" "$CODEFILE")"
  # #2284: a planned batch member. Never an adjudicated or preflight-errored candidate (the plan excludes both).
  # SERIAL: its batch runs (once, at its first member) and it is classified from the gate dir the batch wrote —
  # the #2023 pre-write shape. PARALLEL: the whole batch is ONE job, launched at its first member; the others only
  # record their row, and the drain pass classifies every member in manifest order from its gate.rc.
  BINFO=""
  [ "$BATCHED_N" -eq 0 ] || BINFO="$(batch_of "$CANDIDATES")"
  if [ -n "$BINFO" ]; then
    B_ID="$(printf '%s
' "$BINFO" | cut -f1)"; B_K="$(printf '%s
' "$BINFO" | cut -f2)"; B_SIZE="$(printf '%s
' "$BINFO" | cut -f3)"
    if [ "$JOBS" -le 1 ]; then
      echo "verify-findings.sh: [$GATE] verifying $LOCATION ($CLASS) — batched first read $B_ID ($B_K/$B_SIZE) ..." >&2
      [ -e "$(batch_dir "$B_ID")/done" ] || run_refute_batch "$B_ID"
      GATE_RC=1
      if [ -s "$CELL_OUT/gate.rc" ]; then GATE_RC="$(cat "$CELL_OUT/gate.rc")"; fi
      case "$GATE_RC" in ''|*[!0-9]*) GATE_RC=1 ;; esac
      classify_candidate "$GATE_RC" "$CELL_OUT" "$SUBSYS" "$LOCATION" "$CODEFILE" "$CLASS" "$SEVERITY" "$EXPLOIT" "$SKETCH"
      continue
    fi
    PJ_OUT+=("$CELL_OUT") ; PJ_SUBSYS+=("$SUBSYS") ; PJ_LOC+=("$LOCATION") ; PJ_FILE+=("$CODEFILE")
    PJ_CLS+=("$CLASS") ; PJ_SEV+=("$SEVERITY") ; PJ_EXPL+=("$EXPLOIT") ; PJ_SKETCH+=("$SKETCH")
    PJ_PREFLIGHT+=("")
    if [ "$B_K" = "1" ]; then
      while [ "$live" -ge "$effective_jobs" ]; do
        wait -n 2>/dev/null || true
        live=$((live - 1))
      done
      echo "verify-findings.sh: [$GATE] verifying batch $B_ID ($B_SIZE candidates, first: $LOCATION) ..." >&2
      ( run_refute_batch "$B_ID" ) </dev/null >/dev/null &
      live=$((live + 1))
    fi
    continue
  fi
  if [ "$JOBS" -le 1 ]; then
    # SERIAL path (default): today's exact statement sequence — preflight ERROR + continue, else the
    # "verifying …" line, the gate, and the classification, inline and in manifest order. Writes NO new artifact.
    if [ -n "$EREASON" ]; then
      record_errored "$LOCATION" "$CODEFILE" "$EREASON" "ERROR_MALFORMED: $EREASON"
      continue
    fi
    echo "verify-findings.sh: [$GATE] verifying $LOCATION ($CLASS) ..." >&2
    GATE_RC=0
    gate_candidate "$CELL_OUT" "$LOCATION" "$CLASS" "$SEVERITY" "$EXPLOIT" "$CODEFILE" || GATE_RC=1
    classify_candidate "$GATE_RC" "$CELL_OUT" "$SUBSYS" "$LOCATION" "$CODEFILE" "$CLASS" "$SEVERITY" "$EXPLOIT" "$SKETCH"
    continue
  fi
  # PARALLEL path (#1863, --jobs > 1): record the candidate in manifest order, then — unless the #1691
  # preflight already disqualified it — wait for a free slot and background EXACTLY ONE gate subshell for it.
  # Nothing is classified here; the deferred pass below owns every row of verified[] and errors[].
  PJ_OUT+=("$CELL_OUT") ; PJ_SUBSYS+=("$SUBSYS") ; PJ_LOC+=("$LOCATION") ; PJ_FILE+=("$CODEFILE")
  PJ_CLS+=("$CLASS") ; PJ_SEV+=("$SEVERITY") ; PJ_EXPL+=("$EXPLOIT") ; PJ_SKETCH+=("$SKETCH")
  PJ_PREFLIGHT+=("$EREASON")
  if [ -n "$EREASON" ]; then
    continue
  fi
  while [ "$live" -ge "$effective_jobs" ]; do
    wait -n 2>/dev/null || true
    live=$((live - 1))
  done
  echo "verify-findings.sh: [$GATE] verifying $LOCATION ($CLASS) ..." >&2
  mkdir -p "$CELL_OUT"
  # The subshell's ONLY stdout is the rc byte; the gates route their own output into gates/<n>_<slug>/gate.log.
  # stdin is /dev/null so a child can never consume the parent's candidates.tsv read.
  ( gate_candidate "$CELL_OUT" "$LOCATION" "$CLASS" "$SEVERITY" "$EXPLOIT" "$CODEFILE" && printf 0 || printf 1 ) \
    > "$CELL_OUT/gate.rc" </dev/null &
  live=$((live + 1))
done < "$WORK/candidates.tsv"

if [ "$JOBS" -gt 1 ]; then
  # Drain the pool FIRST — no candidate is classified while any gate is still running.
  while [ "$live" -gt 0 ]; do
    wait -n 2>/dev/null || true
    live=$((live - 1))
  done
  # Deferred aggregation: ONE pass over the recorded rows in MANIFEST order, so verified[], errors[] (the
  # #1691 preflight rows and the gate-propagated ERROR rows INTERLEAVED exactly as serial emits them) and the
  # totals are independent of completion order. A missing or EMPTY gate.rc — the shape a killed background
  # job leaves behind, since the redirect creates the file before the gate runs — is read as rc 1.
  pidx=0 ; pn=${#PJ_OUT[@]}
  while [ "$pidx" -lt "$pn" ]; do
    if [ -n "${PJ_PREFLIGHT[$pidx]}" ]; then
      record_errored "${PJ_LOC[$pidx]}" "${PJ_FILE[$pidx]}" "${PJ_PREFLIGHT[$pidx]}" "ERROR_MALFORMED: ${PJ_PREFLIGHT[$pidx]}"
    else
      GATE_RC=1
      if [ -s "${PJ_OUT[$pidx]}/gate.rc" ]; then
        GATE_RC="$(cat "${PJ_OUT[$pidx]}/gate.rc")"
      fi
      case "$GATE_RC" in ''|*[!0-9]*) GATE_RC=1 ;; esac
      classify_candidate "$GATE_RC" "${PJ_OUT[$pidx]}" "${PJ_SUBSYS[$pidx]}" "${PJ_LOC[$pidx]}" \
        "${PJ_FILE[$pidx]}" "${PJ_CLS[$pidx]}" "${PJ_SEV[$pidx]}" "${PJ_EXPL[$pidx]}" "${PJ_SKETCH[$pidx]}"
    fi
    pidx=$((pidx + 1))
  done
fi

# #1962: fold the sub-floor drops back into the total candidate count. CANDIDATES above only counted the rows
# the loop actually walked (candidates.tsv was rewritten to KEPT-only rows before the loop ran), so the
# counting invariant candidates == verified + errored + refuted + dropped_subfloor holds; SUBFLOOR is 0 (a
# no-op add) whenever --pay-floor is unset.
CANDIDATES=$((CANDIDATES + SUBFLOOR))

# --- #1887: aggregate the per-gate `refute-constraints.tsv` files into ONE <out>/refute-constraints.tsv.
#     Concatenated in NUMERIC GATE ORDER (gates/<n>_<slug>, the manifest order the candidates were recorded
#     in), so the aggregate is byte-identical under --jobs 1 and --jobs > 1: completion order must not reach
#     an artifact that feeds a knowledge corpus, or the corpus itself would stop being reproducible. Only the
#     refute gate produces constraints; the poc/symbolic gates leave the file empty, which is a valid corpus.
#     verified_findings.json's schema is deliberately UNTOUCHED — this is a sidecar, not a new key.
CONSTRAINTS_TSV="$OUT/refute-constraints.tsv"
: > "$CONSTRAINTS_TSV"
if [ "$GATE" = "refute" ]; then
  CT_ORDER="$WORK/constraint-order.tsv"; : > "$CT_ORDER"
  for ct_dir in "$CELLS"/*/; do
    [ -d "$ct_dir" ] || continue
    ct_n="$(basename "$ct_dir" | cut -d'_' -f1)"
    case "$ct_n" in ''|*[!0-9]*) continue ;; esac
    printf '%s\t%s\n' "$ct_n" "$ct_dir" >> "$CT_ORDER"
  done
  sort -k1,1n "$CT_ORDER" | cut -f2 > "$CT_ORDER.sorted"
  while IFS= read -r ct_dir; do
    ct_file="$ct_dir/refute-out/refute-constraints.tsv"
    if [ -s "$ct_file" ]; then cat "$ct_file" >> "$CONSTRAINTS_TSV"; fi
  done < "$CT_ORDER.sorted"
fi

# --- #2217: THE SECOND TIER REACHES THE GATE ---------------------------------------------------------------
#     Runs AFTER the tier-1 candidate loop (and after the #1887 aggregation, which walks <out>/gates/ and must
#     never see a tier-2 cell). A tier-2 record is a check the hunt derived and did NOT settle; sending it
#     through the SAME gate_candidate path answers the one question the cell left open — does a hostile
#     second reader kill it? — without letting the answer pose as a finding. Every outcome goes to its own
#     accumulator, so verified[]/errors[]/dropped_subfloor[]/totals are untouched by construction, not by
#     assertion. TIER2 = 0 (the default) leaves this whole block inert: the accumulator stays empty, no
#     gates-tier2/ dir is created, and the emitted JSON below gains no key.
# t2_manifest_text <s> — <s> with the gate manifest's PIPE DELIMITER neutralised. The refute/symbolic manifest
# is `file:fn|class|sev|exploit|code-file`, and a tier-2 check text is itself an OPCHECK line whose
# `<what>|<invariant>` halves are joined by a pipe. Pasted verbatim, that pipe SPLITS the exploit column in
# two and shifts every later field: run-refute.sh then reads the INVARIANT half as the code file and ERRORs
# the record with `code file not found: <invariant text>` without ever assessing it (#2217 M5 bug 1 — the
# record's `file` never reached the file slot). Neutralised HERE, in the manifest text only: the record
# emitted into tier2[] keeps its original check/why bytes. The other two columns this block fills need no
# such guard — the location is shape-pinned upstream (_tier2_emit_loc) and the class is a `C<n>` token.
t2_manifest_text() {
  printf '%s' "${1//|/ — }"
}

TIER2_OUT_TSV="$WORK/tier2-out.tsv"; : > "$TIER2_OUT_TSV"
TIER2_EXAMINED=0
if [ "$TIER2" -gt 0 ]; then
  # Read-only parse of the merged file's top-level tier2[] -> one TSV row per record to examine. Selection is
  # "the first N of each subsystem group": the array is already in rank order within a zone (see --tier2 in
  # the header), so taking a prefix IS taking the highest-ranked, and no ranking is re-implemented here.
  TIER2_TSV="$WORK/tier2.tsv"
  TIER2_N="$TIER2" python3 - "$RESULTS" > "$TIER2_TSV" <<'PY'
import sys, os, json

n = int(os.environ["TIER2_N"])
data = json.load(open(sys.argv[1], encoding="utf-8"))
per_zone = {}
rows = []
# A merged file from a run WITHOUT the second tier simply has no `tier2` key -> zero rows -> a silent no-op.
for r in (data.get("tier2") or []):
    if not isinstance(r, dict):
        continue
    location = str(r.get("location", "")).strip()
    if not location:
        continue  # a record with no location cannot be gated; skipped BEFORE it consumes a per-zone slot.
    subsystem = str(r.get("subsystem", ""))
    taken = per_zone.get(subsystem, 0)
    if taken >= n:
        continue
    per_zone[subsystem] = taken + 1
    # The location is REGEX-PINNED upstream (run-discovery.sh's _tier2_emit_loc: `<path>.sol:<function>`, or
    # _tier2_emit_bare_loc: a bare path, for the contract-only and file-only rules), so it carries none of the
    # `@func` / `:~(test/...)` decorations that bare_codefile() exists to strip in the candidates parse above —
    # the code file is the part before the first ':', with no second, driftable copy of that stripping logic.
    codefile = location.split(":", 1)[0].strip()
    fields = [subsystem, str(r.get("class", "")), str(r.get("id", "")), str(r.get("kind", "")),
              location, codefile, str(r.get("loc_source", "")), str(r.get("loc_rule", "")),
              str(r.get("check", "")), str(r.get("why", ""))]
    rows.append("\t".join(f.replace("\t", " ").replace("\n", " ") for f in fields))
sys.stdout.write("\n".join(rows))
if rows:
    sys.stdout.write("\n")
PY
  T2CELLS="$OUT/gates-tier2"; rm -rf "$T2CELLS"; mkdir -p "$T2CELLS"
  while IFS= read -r T2ROW || [ -n "${T2ROW:-}" ]; do
    [ -n "$T2ROW" ] || continue
    T2_SUBSYS="$(printf '%s\n' "$T2ROW" | cut -f1)"
    T2_CLASS="$(printf '%s\n' "$T2ROW" | cut -f2)"
    T2_ID="$(printf '%s\n' "$T2ROW" | cut -f3)"
    T2_KIND="$(printf '%s\n' "$T2ROW" | cut -f4)"
    T2_LOC="$(printf '%s\n' "$T2ROW" | cut -f5)"
    T2_FILE="$(printf '%s\n' "$T2ROW" | cut -f6)"
    T2_SRC="$(printf '%s\n' "$T2ROW" | cut -f7)"
    T2_RULE="$(printf '%s\n' "$T2ROW" | cut -f8)"
    T2_CHECK="$(printf '%s\n' "$T2ROW" | cut -f9)"
    T2_WHY="$(printf '%s\n' "$T2ROW" | cut -f10)"
    TIER2_EXAMINED=$((TIER2_EXAMINED + 1))
    T2_SLUG="$(printf '%s' "$T2_LOC" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
    T2_REL="gates-tier2/${TIER2_EXAMINED}_${T2_SLUG}"
    T2_OUT="$OUT/$T2_REL"
    # The gate manifest needs an exploit sentence and a severity. The prefix keeps a tier-2 row from posing as
    # an assessed finding INSIDE the gate's own transcript too, not merely in the emitted JSON.
    T2_EXPL="TIER2 (severity unassessed): $(t2_manifest_text "$T2_CHECK")"
    [ -z "$T2_WHY" ] || T2_EXPL="$T2_EXPL — unsettled because: $(t2_manifest_text "$T2_WHY")"
    if [ ! -f "$REPO/$T2_FILE" ]; then
      # Same preflight as tier 1, routed to the tier-2 accumulator: a derived location that does not resolve is
      # an ERROR outcome (visible), never a REFUTED verdict the record never earned.
      T2_VERD="ERROR"; T2_REASON="code file not found: $T2_FILE"
      echo "verify-findings.sh: [$GATE] tier-2 $T2_LOC ($T2_CLASS/$T2_KIND) -> ERROR ($T2_REASON)" >&2
    else
      echo "verify-findings.sh: [$GATE] verifying TIER-2 $T2_LOC ($T2_CLASS, $T2_KIND) ..." >&2
      T2_RC=0
      gate_candidate "$T2_OUT" "$T2_LOC" "$T2_CLASS" "Medium" "$T2_EXPL" "$T2_FILE" || T2_RC=1
      if [ "$T2_RC" -ne 0 ]; then
        T2_VERD="ERROR"; T2_REASON="gate errored (see $T2_REL/gate.log)"
      else
        T2_VERD="$(cut -f1 "$T2_OUT/verdict.txt")"
        T2_REASON="$(cut -f2- "$T2_OUT/verdict.txt" | tr '\t' ' ')"
      fi
      echo "verify-findings.sh:   -> tier-2 $T2_VERD" >&2
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$T2_SUBSYS" "$T2_LOC" "$T2_FILE" "$T2_CLASS" "$T2_ID" "$T2_KIND" "$T2_SRC" "$T2_RULE" \
      "$T2_CHECK" "$T2_WHY" "$T2_VERD" "$T2_REASON" >> "$TIER2_OUT_TSV"
  done < "$TIER2_TSV"
fi

# --- aggregate CONFIRMED-only -> verified_findings.json (python3 json.dumps, the repo convention; seam-3 schema).
#     totals.errored + errors[] (#1691) make a malformed/unresolvable candidate DISTINGUISHABLE from a rigorous
#     REFUTED verdict — the true rigorous-refutation count = candidates - verified - errored. Additive only:
#     existing keys are preserved, so verified[]-reading consumers (run-zone-hunt.sh, corpus-bench) are unaffected.
#     #1962 ADDS (also additive; verified[]/errors[]/existing totals are unchanged on a floor-less run):
#     dropped_subfloor[] (the well-formed, sub-floor candidates the --pay-floor partition removed before the
#     gate loop), top-level pay_floor ("" when unset), and totals.dropped_subfloor (0 when unset).
VERIFIED_JSON="$OUT/verified_findings.json"
# #2278: a pre-cluster sibling left by an EARLIER run in this --out must never survive into this one (an OFF run,
# or a run where nothing merged, has no sibling by contract).
RAW_JSON="$OUT/verified_findings.raw.json"
rm -f "$RAW_JSON"
REPO_NAME="$REPO_NAME" GATE="$GATE" CANDIDATES="$CANDIDATES" VERIFIED="$VERIFIED" ERRORED="$ERRORED" \
PAY_FLOOR="$PAY_FLOOR" SUBFLOOR="$SUBFLOOR" SCOPE_STATE="$SCOPE_STATE" SCOPE_REASON="$SCOPE_REASON" \
python3 - "$CONFIRMED_TSV" "$ERRORS_TSV" "$DROPPED_SUBFLOOR_TSV" "$TIER2_OUT_TSV" "$OOS_TSV" > "$VERIFIED_JSON" <<'PY'
import sys, os, json
verified = []
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        f = line.split("\t")
        while len(f) < 9:
            f.append("")
        verified.append({
            "subsystem": f[0], "location": f[1], "file": f[2], "class": f[3],
            "severity": f[4], "exploit": f[5], "poc_sketch": f[6],
            "verdict": f[7], "reason": f[8],
        })
errors = []
with open(sys.argv[2], encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        f = line.split("\t")
        while len(f) < 3:
            f.append("")
        errors.append({"location": f[0], "file": f[1], "reason": f[2]})
pay_floor = os.environ.get("PAY_FLOOR", "")
dropped_subfloor = []
with open(sys.argv[3], encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        f = line.split("\t")
        while len(f) < 8:
            f.append("")
        dropped_subfloor.append({
            "subsystem": f[0], "location": f[1], "file": f[2], "class": f[3],
            "severity": f[4],
            "reason": "severity %s below pay-floor %s" % (f[4], pay_floor),
        })
out = {
    "repo": os.environ.get("REPO_NAME", ""),
    "gate": os.environ.get("GATE", ""),
    "verified": verified,
    "errors": errors,
    "dropped_subfloor": dropped_subfloor,
    "pay_floor": pay_floor,
    "totals": {
        "candidates": int(os.environ.get("CANDIDATES", "0")),
        "verified": int(os.environ.get("VERIFIED", "0")),
        "errored": int(os.environ.get("ERRORED", "0")),
        "dropped_subfloor": int(os.environ.get("SUBFLOOR", "0")),
    },
}
# #2217: the SECOND TIER, strictly additive and strictly separate. Emitted ONLY when at least one tier-2
# record was examined, so an OFF run (an empty accumulator) gains NO key and stays byte-identical to a
# pre-#2217 run — the same emit-only-when-non-empty discipline run-discovery.sh's own tier2[] rides.
# `severity` ships EMPTY by construction: the `Medium` the gate manifest carried is an INPUT the gate needs,
# never an assessment anyone made. verified[] and every pre-existing total are untouched above.
tier2 = []
with open(sys.argv[4], encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        f = line.split("\t")
        while len(f) < 12:
            f.append("")
        # `id` is the check's ordinal within its cell — emitted as a NUMBER, exactly as run-discovery.sh's
        # own tier2[] emits it, so a consumer reading both arrays never sees the same field in two types.
        rid = int(f[4]) if f[4].isdigit() else f[4]
        tier2.append({
            "subsystem": f[0], "location": f[1], "file": f[2], "class": f[3],
            "id": rid, "kind": f[5], "loc_source": f[6], "loc_rule": f[7],
            "severity": "", "check": f[8], "why": f[9],
            "verdict": f[10], "reason": f[11],
        })
if tier2:
    out["tier2"] = tier2
    out["totals"]["tier2"] = len(tier2)
# #2257: candidates refuted on a DECLARED out-of-scope premise — emitted ONLY when non-empty (the tier2 discipline),
# so a run without --scope-docs, or one that routed nothing, gains no key. Never part of verified[]; a subset of the
# implicit refuted count, so the counting invariant is untouched.
out_of_scope = []
if os.path.exists(sys.argv[5]):
    with open(sys.argv[5], encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            f = line.split("\t")
            while len(f) < 14:
                f.append("")
            out_of_scope.append({
                "subsystem": f[0], "location": f[1], "file": f[2], "class": f[3],
                "severity": f[4], "exploit": f[5], "poc_sketch": f[6],
                "verdict": f[7], "label": "out_of_scope_premise",
                "assumption": {"id": f[9], "category": f[10], "source": f[11], "text": f[12]},
                "premise": f[13], "reason": f[8],
            })
if out_of_scope:
    out["out_of_scope"] = out_of_scope
    out["totals"]["out_of_scope"] = len(out_of_scope)
# #2257: the scope layer's own state, present ONLY when --scope-docs was requested (SCOPE_STATE is empty otherwise),
# so an extractor failure that fails open is recorded in the artifact, not only on stderr.
if os.environ.get("SCOPE_STATE", ""):
    out["scope_layer"] = {"state": os.environ["SCOPE_STATE"], "reason": os.environ.get("SCOPE_REASON", "")}
print(json.dumps(out, indent=2))
PY

# --- #2278: ROOT-CAUSE CLUSTERING. Runs on the finished aggregate, so the gate loop, the counters and the VERIFY
#     banner below are untouched. The raw aggregate moves to the sibling and the clusterer writes the clustered
#     file in its place; `merged == 0` or ANY clusterer failure moves the raw file back (fail-open: a finding is
#     never lost to this step). DF_CLUSTER_CMD is the demo's seam for a failing clusterer.
cluster_cmd() {
  if [ -n "${DF_CLUSTER_CMD:-}" ]; then
    sh -c "$DF_CLUSTER_CMD \"\$@\"" cluster-cmd "$@"
  else
    python3 "$HERE/lib/cluster-findings.py" "$@"
  fi
}
CLUSTER_NOTE=""
if [ "$CLUSTER_FINDINGS" = "1" ] && [ "$VERIFIED" -gt 1 ]; then
  mv "$VERIFIED_JSON" "$RAW_JSON"
  CL_RC=0
  CL_OUT="$(cluster_cmd cluster --in "$RAW_JSON" --out "$VERIFIED_JSON" \
    ${DF_CLUSTER_THRESHOLD:+--threshold "$DF_CLUSTER_THRESHOLD"} 2>"$WORK/cluster.err")" || CL_RC=$?
  CL_LINE="$(printf '%s\n' "$CL_OUT" | grep '^CLUSTER|' | tail -1 || true)"
  CL_RAW="$(printf '%s' "$CL_LINE" | cut -d'|' -f2)"
  CL_N="$(printf '%s' "$CL_LINE" | cut -d'|' -f3)"
  CL_MERGED="$(printf '%s' "$CL_LINE" | cut -d'|' -f4)"
  case "$CL_RAW$CL_N$CL_MERGED" in ''|*[!0-9]*) [ "$CL_RC" -ne 0 ] || CL_RC=3 ;; esac
  if [ "$CL_RC" -eq 0 ] && [ "$CL_MERGED" -gt 0 ] && [ ! -s "$VERIFIED_JSON" ]; then CL_RC=3; fi
  if [ "$CL_RC" -ne 0 ]; then
    rm -f "$VERIFIED_JSON"; mv "$RAW_JSON" "$VERIFIED_JSON"
    echo "verify-findings.sh: WARNING: root-cause clustering failed (exit $CL_RC: $(head -1 "$WORK/cluster.err")) — keeping the unclustered verified_findings.json (fail-open, #2278)" >&2
  elif [ "$CL_MERGED" -eq 0 ]; then
    mv "$RAW_JSON" "$VERIFIED_JSON"
  else
    CLUSTER_NOTE="verify-findings.sh: clustering: $CL_RAW confirmed -> $CL_N distinct root cause(s) ($CL_MERGED merged); pre-cluster list at $RAW_JSON"
  fi
fi

echo >&2
SUBFLOOR_SUFFIX=""
if [ -n "$PAY_FLOOR" ] && [ "$SUBFLOOR" -gt 0 ]; then
  SUBFLOOR_SUFFIX=", $SUBFLOOR sub-floor"
fi
OOS_SUFFIX=""
if [ "$OUT_OF_SCOPE" -gt 0 ]; then
  OOS_SUFFIX=", $OUT_OF_SCOPE out-of-scope (declared premise)"
fi
# #2284: named only when a batch was planned, so an OFF run's banner is unchanged.
BATCH_SUFFIX=""
if [ "$BATCH_COUNT" -gt 0 ]; then
  BATCH_SUFFIX=", $BATCHED_N candidate(s) in $BATCH_COUNT batched first-read session(s)"
fi
echo "================ VERIFY [$GATE]: $CANDIDATES candidate(s), $VERIFIED confirmed, $ERRORED errored (malformed/unresolvable), $SKIPPED skipped$SUBFLOOR_SUFFIX$OOS_SUFFIX$BATCH_SUFFIX ================" >&2
echo "verify-findings.sh: verified findings at $VERIFIED_JSON" >&2
[ -z "$CLUSTER_NOTE" ] || echo "$CLUSTER_NOTE" >&2
if [ "$TIER2_EXAMINED" -gt 0 ]; then
  echo "verify-findings.sh: tier 2 — $TIER2_EXAMINED unsettled check(s) examined; verdicts in tier2[] of $VERIFIED_JSON (NOT findings, never in verified[])" >&2
fi
if [ "$VERIFIED" -gt 0 ]; then
  echo "verify-findings.sh: NEXT = run the human-gated submission pass over each verified finding (run-audit-pass.sh); submission stays human-gated." >&2
else
  echo "verify-findings.sh: no candidate survived the $GATE gate — a rigorous negative. Nothing to package, nothing submitted." >&2
fi
