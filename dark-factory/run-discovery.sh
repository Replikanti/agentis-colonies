#!/usr/bin/env bash
# run-discovery.sh — custom-code DISCOVERY entrypoint for the Dark Factory federation.
#
# run-audit.sh drives the DAG fork-MATCHER (auditor.ag): it fires only where in-scope code RECURS a
# known-bug pattern, so it returns nothing on a bespoke protocol. run-discovery.sh drives the colony's
# DISCOVERY agent (auditor/agents/hunter.ag): a taxonomy-driven, adversarial, per-(subsystem x bug-class)
# audit of CUSTOM multi-contract code — the colony-native, substrate-driven version of a hand-run
# multi-agent pass. The hunter runs ENTIRELY through the agentis substrate (prompt/emit/learn). Learning/
# experience are ENABLED below: hunter.ag ends its tick with `learn("hunt", ...)`, and it is that WRITE the
# flag gates — agentis hard-errors `experience not enabled` on the call and then DISCARDS the cell's whole
# stdout, so the CANDIDATE|/SAFE sentinel vanishes (#1881/#1878) — even though the per-run store is wiped
# fresh on every invocation and so carries no CROSS-run reweighting (#1866).
#
# A surfaced CANDIDATE is a LEAD, not a finding. It is UNVERIFIED until the operator reproduces it through
# evm-harness/forge-verify.sh (a real Foundry PoC that PASSES only if the exploit fires). Only a forge-
# VERIFIED candidate is a finding worth a human-gated submission. This tool NEVER contacts a bounty
# platform and NEVER auto-submits — surfacing harness-checkable leads is the whole job.
#
# Usage:
#   run-discovery.sh --repo <dir> --scope <scope.tsv> --brief <brief.md> [options]
#
# Scope manifest (one subsystem per line; `#` and blank lines ignored):
#   <subsystem label> | <classid,classid,...> | <file[,file...]>     (files relative to --repo)
# A file may be FUNCTION-SLICED as `file@fn1+fn2+...` to feed ONLY those functions (+ the contract
# header) instead of the whole file. Use it for big/complex contracts whose whole-file payload
# overflows the LLM per-call budget — without it the deep liquidation/redeem cells time out.
# e.g.
#   savings + rewards | C1,C6,C11 | contracts/SavingsVault.sol,contracts/RewardsDistributor.sol
#   vault liquidation | C10       | contracts/Vault.sol@liquidate+seize+_redeem
#
# Options:
#   --repo <dir>        Cloned target repo root (clone with fetch-target.sh). REQUIRED.
#   --scope <file>      Subsystem x class x files manifest (see above). REQUIRED.
#   --brief <file>      Protocol brief: invariants-to-break + known-issues-to-exclude + trust model. REQUIRED.
#   --appendix <file>   #1865 OPTIONAL sidecar written by map-zones.sh (`<subsystem>\t<token>\t<base>`, TAB-
#                       delimited). It names, per manifest line, the ONE #1861 inheritance-appendix token in
#                       that line's file list and the abstract base it implements — a fact the manifest itself
#                       cannot carry, since the token has the same `file@fn+fn` shape as any other slice. The
#                       hunter then LABELS that payload section and gains the resolved-behaviour + anchoring
#                       rules. Absent (the default) => the whole path is inert and the prompt is byte-identical.
#                       A row is used only if its token literally appears in that line's file list.
#   --taxonomy <file>   bug-taxonomy.md (default: bundled ./auditor/bug-taxonomy.md).
#   --only <subsystem>  Hunt only the line whose subsystem label matches (smoke test / re-run one slice).
#   --classes <ids>     Override EVERY line's class list with this comma list (e.g. C1,C2 for a cheap probe).
#   --backend <mock|flat-cyborg|claude>  LLM backend (default: flat-cyborg = flat-rate PTY wrapper;
#                       claude = metered -p API; mock = offline-deterministic wiring smoke).
#   --out <dir>         Output dir for the run + leads (default: ./discovery-out).
#   --agentis <bin>     agentis binary (default: `agentis` on PATH).
#   --jobs <N>, -j <N>  OPT-IN bounded-concurrency fan-out (#1625, epic #1611 M3). Hunt up to N
#                       (subsystem x class) cells CONCURRENTLY instead of serially (default N=1 = serial).
#                       Concurrency is HARD-CAPPED at min(N, LLM_MAX_DISCOVERY_CELLS=4) so N concurrent
#                       agentis go / forge / solc processes cannot OOM-thrash a single host — the cap never
#                       fails open. Under --jobs > 1 each cell gets its OWN isolated agentis store/workdir
#                       (a `cp -r` of the initialised $RUN template), so concurrent memo/build writes never
#                       race; a consequence is that the #1001 shared-blackboard cross-cell steering is
#                       DISABLED under parallelism (every cell's board starts empty) — a documented
#                       throughput-vs-steering trade. Results are aggregated AFTER the pool drains in
#                       MANIFEST order, so the finding set is deterministic + independent of completion
#                       order. --jobs 1 (the default) keeps the ONE shared store WITH live #1001 steering
#                       and is BYTE-FOR-BYTE identical to the pre-M3 hunt.
#   --depth-max-cells <N>  #1827 WITHIN-CONTRACT DEPTH PASS. 0 (default) = OFF = the run is byte-identical
#                       to before. With N > 0, AFTER every breadth cell has run, re-hunt the functions a
#                       breadth candidate already flagged: one EXTRA cell per (flagged function x alternative
#                       lens), payload narrowed to that single function (`file@fn` through slice-fns.sh) and
#                       the already-known lead(s) injected VERBATIM as an exclusion, so the model must find a
#                       mechanistically DIFFERENT bug or answer SAFE. Class order per location = the zone's
#                       OTHER classes first (in manifest order), the producing class LAST; locations are
#                       ranked High-before-Medium, then by candidate count, then by first appearance, and the
#                       cap is spread by the QUOTA-ROUND-ROBIN below so it never burns entirely on the first
#                       flagged function. Depth cells are REAL cells: counted in the run total,
#                       present in `cells[]` (tagged `"phase":"depth"`), and charged by run-zone-hunt.sh's
#                       admission rule — never a hidden second prompt inside an existing cell. ONE pass, never
#                       a loop: the target list is computed once from the breadth set, so a depth candidate can
#                       never spawn further depth cells.
#   --depth-lens-quota <N>  #1850 ALLOCATION of the --depth-max-cells cap across the flagged locations.
#                       N (default 1, must be >= 1) = how many CONSECUTIVE lenses one location gets before the
#                       plan moves to the next one; after every location has had N the rounds repeat (positions
#                       N+1..2N, and so on) until the cap is spent. N=1 degenerates to the shipped
#                       one-class-per-location-per-pass spread BYTE-FOR-BYTE, which is why the old allocation
#                       needs no second code path. #1827's breadth-first spread never gave any location more
#                       than 1-2 lenses, so the mechanism the depth pass exists for — hunting ONE function
#                       under several lenses — was never exercised; N=3 is the smallest quota that clears
#                       "hunted under >= 3 distinct lenses" while still reaching the rank-4 location at the
#                       caps we measure with. Per-location spend is naturally bounded by the number of classes
#                       the ZONE advertises (a location's lens list IS the zone's class list), so this can
#                       never burn a whole cap on one function. Ranking, the pair multiset and the cap
#                       semantics (min(cap, planned pairs)) are UNCHANGED — only the emission order moves.
#   --depth-from <file>  #1857 DEPTH-ONLY RE-ENTRY. Consume a RECORDED run's `discovery-results.json` (NOT the
#                       raw `run/results-cells.jsonl`, which carries no provenance), seed this run's cell
#                       accumulator with that run's BREADTH cells, and run ONLY the depth pass over them. The
#                       breadth pass is NOT re-hunted: two arms that differ only in `--depth-lens-quota` then
#                       share ONE breadth sample, so the difference between them is the allocation and not
#                       breadth variance — which is the confound that made #1850's A/B unreadable. Requires
#                       `--depth-max-cells > 0` (a depth-only run with no depth budget is a no-op) and
#                       `--brief`; REFUSES `--scope`, `--only`, `--classes` and `--list-cells` (exit 2) because
#                       none of them can affect a plan derived from recorded cells — the zone class order comes
#                       from the recorded `class` fields, not from the manifest. Needs python3 (exit 3).
#                       Exit 2 = the operator typed something that cannot be honoured (bad flag combo, missing
#                       file, cap 0); exit 3 = the artifact does not match this target (recorded `repo` or
#                       `commit` mismatch, a depth target that no longer exists, an input with no breadth cell).
#                       HONESTY: an input recorded BEFORE this flag existed carries no `commit`, so a stale
#                       checkout of the SAME repo at a DIFFERENT commit is UNDETECTABLE — such a run prints an
#                       UNVERIFIED banner and continues. Re-entering against the checkout that produced the
#                       input is the OPERATOR's responsibility; `depth_from.commit` puts it on the record.
#   --list-cells, -n    DRY RUN (#1612): print one `CELL|<subsystem>|<class>|<files>` line per cell this
#                       manifest WOULD hunt, then exit 0 — BEFORE any agentis init / config / report side
#                       effect. Needs neither --brief nor an agentis binary; the round-trip check for
#                       map-zones.sh's auto-generated scope.tsv. The shipped hunt path is byte-identical.
#                       #1619: when --brief is ALSO given, --list-cells first validates it, resolves it to an
#                       absolute path, and prints `BRIEF|<abs>|<line-count>` — the offline proof that a
#                       generated brief resolves + is what would be handed to the hunter as SCOPE_BRIEF.
#                       #1827: depth cells are NOT enumerable ex ante (they depend on the breadth RESULTS),
#                       so --list-cells still prints the breadth cells only; run-zone-hunt.sh charges the
#                       depth CAP up front instead — the conservative choice.
#
# Env:
#   REFUTE_CONSTRAINTS_JSON  #1887 OPT-IN, default UNSET = OFF = byte-identical behaviour. Path to a
#                       refute-to-knowledge.sh corpus (`refute-constraint` KnowledgeEntry rows distilled from
#                       an EARLIER target's REFUTED verdicts). When set and readable it is imported into the
#                       run store ONCE, before the cell loop, so every cell's isolated copy carries the SAME
#                       frozen, read-only corpus; hunter.ag then prepends the constraints filed under that
#                       cell's class. Nothing writes knowledge, so `--jobs N` stays equal to serial. A shell
#                       env read here — deliberately NOT an exec.env_passthrough entry (mirrors
#                       map-zones.sh's HUNT_FITNESS_JSON). An import failure is logged and the hunt continues.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# #1707: shared reply-shape validation + retry for the hunter substrate call (see the helper header).
# shellcheck source=lib/run-agent-validated.sh
# shellcheck disable=SC1091
. "$HERE/lib/run-agent-validated.sh"
DF_AGENT_MAX_ATTEMPTS="$(df_max_attempts)"
AGENTIS="agentis"
REPO="" ; SCOPE="" ; BRIEF="" ; TAXONOMY="" ; ONLY="" ; CLASSES_OVERRIDE=""
# #1865: opt-in inheritance-appendix sidecar; empty = OFF, every code path below is inert.
APPENDIX_TSV=""
BACKEND="flat-cyborg" ; MODEL="" ; OUT="$PWD/discovery-out"
LIST_CELLS=""   # #1612: opt-in dry-run; empty = the shipped hunt path, byte-identical.
JOBS=1          # #1625: opt-in bounded-concurrency fan-out; 1 = serial, byte-identical to the pre-M3 hunt.
DEPTH_MAX_CELLS=0  # #1827: opt-in within-contract depth pass; 0 = OFF, the whole path is inert.
# #1850: consecutive lenses per location per round. Default 1 = the #1827 spread, byte-for-byte.
# 3 concentrates the budget and DID produce the first rare row depth has ever found (plaza M-12, via a
# second lens on exitBalancerPool), but the run that showed it also lost four mid/consensus rows whose loss
# is NOT attributable — both arms re-hunted the stochastic breadth pass, so that A/B cannot separate an
# allocation effect from breadth variance. The default stays at the measured-safe value until a
# breadth-fixed A/B justifies moving it; `--depth-lens-quota 3` is available for that experiment.
DEPTH_LENS_QUOTA=1
# #1857: opt-in depth-only re-entry; empty = OFF, every code path below is inert and the shipped hunt is unchanged.
DEPTH_FROM=""

need() { [ "$1" -ge 2 ] || { echo "run-discovery.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "$#"; REPO="$2"; shift 2 ;;
    --scope) need "$#"; SCOPE="$2"; shift 2 ;;
    --brief) need "$#"; BRIEF="$2"; shift 2 ;;
    --appendix) need "$#"; APPENDIX_TSV="$2"; shift 2 ;;
    --taxonomy) need "$#"; TAXONOMY="$2"; shift 2 ;;
    --only) need "$#"; ONLY="$2"; shift 2 ;;
    --classes) need "$#"; CLASSES_OVERRIDE="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --model) need "$#"; MODEL="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --jobs|-j) need "$#"; JOBS="$2"; shift 2 ;;
    --depth-max-cells) need "$#"; DEPTH_MAX_CELLS="$2"; shift 2 ;;
    --depth-lens-quota) need "$#"; DEPTH_LENS_QUOTA="$2"; shift 2 ;;
    --depth-from) need "$#"; DEPTH_FROM="$2"; shift 2 ;;
    --list-cells|-n) LIST_CELLS=1; shift ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-discovery.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

# #1625: --jobs must be a positive integer (validated even under --list-cells, which then ignores it).
case "$JOBS" in ''|*[!0-9]*) echo "run-discovery.sh: --jobs must be a positive integer (got '$JOBS')" >&2; exit 2 ;; esac
[ "$JOBS" -ge 1 ] || { echo "run-discovery.sh: --jobs must be >= 1 (got '$JOBS')" >&2; exit 2; }
# #1827: --depth-max-cells uses the same integer validation + exit-2 shape (also validated under --list-cells,
# which then ignores it — depth cells are not enumerable ex ante).
case "$DEPTH_MAX_CELLS" in ''|*[!0-9]*) echo "run-discovery.sh: --depth-max-cells must be a non-negative integer (got '$DEPTH_MAX_CELLS')" >&2; exit 2 ;; esac
# #1850: --depth-lens-quota is a POSITIVE integer — 0 lenses per location would emit an empty plan at a
# non-zero cap, i.e. silently disable a depth pass the operator asked for. Same fail-fast shape as --jobs.
case "$DEPTH_LENS_QUOTA" in ''|*[!0-9]*) echo "run-discovery.sh: --depth-lens-quota must be a positive integer (got '$DEPTH_LENS_QUOTA')" >&2; exit 2 ;; esac
[ "$DEPTH_LENS_QUOTA" -ge 1 ] || { echo "run-discovery.sh: --depth-lens-quota must be >= 1 (got '$DEPTH_LENS_QUOTA')" >&2; exit 2; }
# #1857: the depth-only re-entry's ARGV contract. Everything here is an exit 2 — the operator asked for
# something that cannot be honoured — and it is checked BEFORE the --repo/--scope/--brief requirements below,
# so a refused flag combination is named rather than reported as a missing manifest. The refused flags are
# refused rather than validated: a plan derived from RECORDED cells takes its zone class order from those
# cells' own `class` fields, so --scope/--only/--classes could not change it and accepting them would be a
# silent lie. --list-cells is refused for the same reason (depth cells are not enumerable ex ante).
if [ -n "$DEPTH_FROM" ]; then
  [ -f "$DEPTH_FROM" ] || { echo "run-discovery.sh: --depth-from file not found: $DEPTH_FROM" >&2; exit 2; }
  [ -z "$LIST_CELLS" ]       || { echo "run-discovery.sh: --depth-from cannot be combined with --list-cells (depth cells are not enumerable ex ante)" >&2; exit 2; }
  [ -z "$ONLY" ]             || { echo "run-discovery.sh: --depth-from cannot be combined with --only (the plan comes from the recorded cells, not from a manifest)" >&2; exit 2; }
  [ -z "$CLASSES_OVERRIDE" ] || { echo "run-discovery.sh: --depth-from cannot be combined with --classes (the plan comes from the recorded cells, not from a manifest)" >&2; exit 2; }
  [ -z "$SCOPE" ]            || { echo "run-discovery.sh: --depth-from cannot be combined with --scope (the plan comes from the recorded cells, not from a manifest)" >&2; exit 2; }
  [ "$DEPTH_MAX_CELLS" -gt 0 ] || { echo "run-discovery.sh: --depth-from needs --depth-max-cells > 0 (a depth-only run with no depth budget is a no-op)" >&2; exit 2; }
  command -v python3 >/dev/null 2>&1 || { echo "run-discovery.sh: --depth-from needs python3 to read the recorded run" >&2; exit 3; }
fi

[ -n "$REPO" ]  && [ -d "$REPO" ]  || { echo "run-discovery.sh: --repo <cloned repo dir> required (clone it with fetch-target.sh)" >&2; exit 2; }
# #1857: --scope is the manifest the BREADTH pass walks; a depth-only re-entry hunts no breadth cell, so it is
# required only on the shipped path (and refused above on the re-entry one).
if [ -z "$DEPTH_FROM" ]; then
  [ -n "$SCOPE" ] && [ -f "$SCOPE" ] || { echo "run-discovery.sh: --scope <subsystem|classes|files manifest> required" >&2; exit 2; }
fi
# #1865: the sidecar is OPTIONAL, but a path the operator typed and that does not exist is a typo, not an
# opt-out — fail fast rather than run the whole hunt with the framing silently off.
if [ -n "$APPENDIX_TSV" ]; then
  [ -f "$APPENDIX_TSV" ] || { echo "run-discovery.sh: --appendix file not found: $APPENDIX_TSV" >&2; exit 2; }
fi
# #1612: --list-cells needs no --brief (it never hunts) — guard the brief requirement behind it.
if [ -z "$LIST_CELLS" ]; then
  [ -n "$BRIEF" ] && [ -f "$BRIEF" ] || { echo "run-discovery.sh: --brief <invariants + known-issues + trust model> required (this anchors the hunt and excludes known issues)" >&2; exit 2; }
fi

# #1612 dry-run short-circuit: enumerate the (subsystem x class) cells this manifest WOULD hunt and exit,
# BEFORE any agentis init / config / report side effect. Runs the SAME normalization as the hunt loop below
# (trim + `''|\#*` skip + --only/--classes + comma class split), so the enumerated cells match the manifest
# byte-for-byte. Needs neither --brief nor an agentis binary — the offline round-trip for map-zones.sh's
# auto-generated scope.tsv. With no --list-cells every guard above is inert and the hunt path is unchanged.
if [ -n "$LIST_CELLS" ]; then
  # #1619 (epic #1611 M2): opt-in, byte-identical-default brief acknowledgement. When --brief is ALSO given,
  # validate + resolve it to absolute (the same idiom as the hunt path's line ~111) and print BRIEF|<abs>|<lines>
  # BEFORE the cell enumeration — the offline (no-agentis) proof that a generated brief resolves and is what
  # would be handed to every cell as SCOPE_BRIEF. With no --brief, BRIEF="" so this block is skipped and the
  # M1 --list-cells output is unchanged.
  if [ -n "$BRIEF" ]; then
    [ -f "$BRIEF" ] || { echo "run-discovery.sh: --brief file not found: $BRIEF" >&2; exit 2; }
    BRIEF_ABS="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"
    BRIEF_LINES="$(wc -l < "$BRIEF" | tr -d ' ')"
    printf 'BRIEF|%s|%s\n' "$BRIEF_ABS" "$BRIEF_LINES"
  fi
  while IFS='|' read -r SUBSYS CLS_CSV FILES_CSV || [ -n "${SUBSYS:-}" ]; do
    SUBSYS="$(printf '%s' "$SUBSYS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$SUBSYS" in ''|\#*) continue ;; esac
    CLS_CSV="$(printf '%s' "$CLS_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    FILES_CSV="$(printf '%s' "$FILES_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$ONLY" ] && [ "$SUBSYS" != "$ONLY" ] && continue
    [ -n "$CLASSES_OVERRIDE" ] && CLS_CSV="$CLASSES_OVERRIDE"
    [ -n "$FILES_CSV" ] || continue
    OLDIFS="$IFS"; IFS=','
    for CLS in $CLS_CSV; do
      IFS="$OLDIFS"
      CLS="$(printf '%s' "$CLS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$CLS" ] || { IFS=','; continue; }
      printf 'CELL|%s|%s|%s\n' "$SUBSYS" "$CLS" "$FILES_CSV"
      IFS=','
    done
    IFS="$OLDIFS"
  done < "$SCOPE"
  exit 0
fi

[ -n "$TAXONOMY" ] || TAXONOMY="$HERE/auditor/bug-taxonomy.md"
[ -f "$TAXONOMY" ] || { echo "run-discovery.sh: taxonomy not found: $TAXONOMY" >&2; exit 2; }
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-discovery.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

# Resolve every operator path to ABSOLUTE — the colony runs from a different cwd, so a relative path
# would silently miss (the hunter reads files via absolute TARGET_DIR/<rel>).
REPO="$(cd "$REPO" && pwd)"
BRIEF="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"
TAXONOMY="$(cd "$(dirname "$TAXONOMY")" && pwd)/$(basename "$TAXONOMY")"
[ -z "$DEPTH_FROM" ] || DEPTH_FROM="$(cd "$(dirname "$DEPTH_FROM")" && pwd)/$(basename "$DEPTH_FROM")"
# #1857: the commit this run actually read, recorded in discovery-results.json so a LATER --depth-from can
# refuse a stale checkout. A SOFT dependency: a non-git target (or no git at all) degrades to "unknown" and
# never fails the run. It pins the commit, not the content — an uncommitted edit is invisible to rev-parse.
COMMIT="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"

HUNTER="$HERE/auditor/agents/hunter.ag"
[ -f "$HUNTER" ] || { echo "run-discovery.sh: hunter agent not found at $HUNTER" >&2; exit 3; }

# #1857 PROVENANCE GUARD — every refusal that can be decided from the recorded artifact ALONE fires HERE,
# before the output dir exists, so a refused re-entry leaves nothing behind. Exit 3 throughout: the artifact
# does not match this target (the #1840 fail-closed precedent), as opposed to the exit-2 argv refusals above.
# What it CANNOT detect is stated in the header and printed as a banner: an input recorded before `commit`
# existed cannot pin the source tree, so a stale checkout of the SAME repo is the operator's responsibility.
_probe_recorded_run() {
  python3 - "$1" <<'PY'
import sys, json
p = sys.argv[1]
try:
    with open(p, encoding="utf-8") as fh:
        d = json.load(fh)
except Exception as exc:                    # any read/parse failure is fatal - never a silently empty replay
    sys.stderr.write("run-discovery.sh: --depth-from: %s is not readable JSON (%s)\n" % (p, exc))
    raise SystemExit(3)
if not isinstance(d, dict) or not isinstance(d.get("cells"), list):
    sys.stderr.write("run-discovery.sh: --depth-from: %s is not a discovery-results.json object with a cells[] array\n" % p)
    raise SystemExit(3)
# The depth filter is a CORRECTNESS requirement, not hygiene: a depth candidate fed back into the ranking
# moves both the location order and the per-location lens order, so replaying an unfiltered file computes a
# DIFFERENT plan than the run it claims to re-enter.
breadth = [c for c in d["cells"] if isinstance(c, dict) and c.get("phase") != "depth"]
if not breadth:
    sys.stderr.write("run-discovery.sh: --depth-from: %s records 0 breadth cell(s) - nothing to plan a depth pass from\n" % p)
    raise SystemExit(3)
# ONE FACT PER LINE, never a TSV: `commit` is absent on every artifact recorded before it existed, and a tab
# IFS collapses runs of tabs (tab is IFS whitespace), which would silently shift an empty field's successor
# into it — i.e. read the CELL COUNT as the recorded commit.
sys.stdout.write("\n".join([
    str(d.get("repo") or ""),
    str(d.get("commit") or ""),
    str(len(breadth)),
    str(sum(len(c.get("candidates") or []) for c in breadth)),
]) + "\n")
PY
}
DF_REPO="" ; DF_COMMIT="" ; DF_CELLS=0 ; DF_CANDIDATES=0
if [ -n "$DEPTH_FROM" ]; then
  DF_FACTS="$(_probe_recorded_run "$DEPTH_FROM")" || exit 3
  {
    read -r DF_REPO
    read -r DF_COMMIT
    read -r DF_CELLS
    read -r DF_CANDIDATES
  } <<EOF
$DF_FACTS
EOF
  [ "$DF_REPO" = "$(basename "$REPO")" ] || {
    echo "run-discovery.sh: --depth-from: the input was recorded against repo '$DF_REPO', but --repo is '$(basename "$REPO")'" >&2; exit 3; }
  if [ -z "$DF_COMMIT" ]; then
    echo "run-discovery.sh: --depth-from: the input records no commit; re-entry provenance is UNVERIFIED" >&2
    echo "run-discovery.sh:   ↳ a stale checkout of '$DF_REPO' at a DIFFERENT commit cannot be detected from this artifact — re-entering against the checkout that produced it is YOUR responsibility" >&2
  elif [ "$DF_COMMIT" != "$COMMIT" ]; then
    echo "run-discovery.sh: --depth-from: the input was recorded at commit $DF_COMMIT, but --repo is at $COMMIT" >&2; exit 3
  fi
fi

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$HUNTER" "$RUN/hunter.ag"
cp "$HERE/auditor/slice-fns.sh" "$RUN/slice-fns.sh"   # function-level slicer (scope `file@fn1+fn2`)

# init the agentis store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )

# #1955 Lever 1a: SCALE the per-cell LLM timeout with the zone's SOURCE WEIGHT. A thin zone keeps the
# 1200s floor; a dense one (multi-contract market/order logic) gets proportionally more time, hard-capped at
# 1800s. HUNT_SRC_LOC = sum of `wc -l` over the DISTINCT in-scope files this run will hunt — walked from
# $SCOPE with the SAME filter the --list-cells path uses (trim SUBSYS, skip blank/comment, honour --only,
# split FILES_CSV on commas, drop any `@fn` slice suffix, dedup). This is a side-effect-free WEIGHT PROBE:
# a missing/unreadable file contributes 0 and never fails the hunt. Constants inline (no new env knob, the
# #1915 style): floor 1200000, +300000 ms per 400 LOC step, capped at 1800000 (mirrors run-invariant-hunt.sh).
HUNT_TIMEOUT_FLOOR=1200000
HUNT_TIMEOUT_STEP_MS=300000
HUNT_TIMEOUT_STEP_LOC=400
HUNT_TIMEOUT_CAP=1800000
HUNT_SCOPE_FILES=""
# A --depth-from re-entry forbids --scope (line ~196): the plan comes from the recorded cells, so $SCOPE is
# empty. Skip the probe then (HUNT_SRC_LOC stays 0 -> the floor timeout), never `< ""` (a crash). `_` discards
# the class field (SC2034: it is deliberately unused — the weight is per FILE, independent of the lens).
if [ -n "$SCOPE" ] && [ -f "$SCOPE" ]; then
  while IFS='|' read -r WS_SUBSYS _ WS_FILES || [ -n "${WS_SUBSYS:-}" ]; do
    WS_SUBSYS="$(printf '%s' "$WS_SUBSYS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$WS_SUBSYS" in ''|\#*) continue ;; esac
    [ -n "$ONLY" ] && [ "$WS_SUBSYS" != "$ONLY" ] && continue
    WS_FILES="$(printf '%s' "$WS_FILES" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$WS_FILES" ] || continue
    WS_OLDIFS="$IFS"; IFS=','
    for WS_F in $WS_FILES; do
      IFS="$WS_OLDIFS"
      WS_F="$(printf '%s' "$WS_F" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      WS_F="${WS_F%%@*}"                                 # strip any `file@fn1+fn2` slice suffix to the path
      [ -n "$WS_F" ] || { IFS=','; continue; }
      HUNT_SCOPE_FILES="$HUNT_SCOPE_FILES$WS_F
"
      IFS=','
    done
    IFS="$WS_OLDIFS"
  done < "$SCOPE"
fi
HUNT_SRC_LOC=0
while IFS= read -r WS_F; do
  [ -n "$WS_F" ] || continue
  WS_LOC=0
  if [ -r "$REPO/$WS_F" ]; then WS_LOC="$(wc -l < "$REPO/$WS_F" 2>/dev/null | tr -d ' ')"; fi
  case "$WS_LOC" in ''|*[!0-9]*) WS_LOC=0 ;; esac
  HUNT_SRC_LOC=$((HUNT_SRC_LOC + WS_LOC))
done <<EOF
$(printf '%s' "$HUNT_SCOPE_FILES" | sort -u)
EOF
HUNT_TIMEOUT_MS=$(( HUNT_TIMEOUT_FLOOR + HUNT_TIMEOUT_STEP_MS * (HUNT_SRC_LOC / HUNT_TIMEOUT_STEP_LOC) ))
[ "$HUNT_TIMEOUT_MS" -gt "$HUNT_TIMEOUT_CAP" ] && HUNT_TIMEOUT_MS=$HUNT_TIMEOUT_CAP

{
  echo "llm.backend = $BACKEND"
  # #1955: ONE attempt, now SIZED to the zone. A deep adversarial read of complex liquidation/redemption
  # logic legitimately runs 4-8 min even on a function-level slice (the reasoning, not the payload, is the
  # cost); 300s made the hard cells time out 3x and return nothing, so one longer attempt beats wasted
  # retries. That attempt is scaled to $HUNT_SRC_LOC LOC of in-scope source (floor 1200s, +300s / 400 LOC,
  # hard-capped 1800s) so a dense zone gets proportionally more head-room while a thin one keeps a tight
  # budget — and, per Lever 1b, a genuine [llm.timeout] now fails FAST + distinguishably instead of costing
  # N wasted outer retries. Keep cells focused with `file@fn` slicing so the common case stays fast.
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p${MODEL:+ --model $MODEL}"; echo "llm.cli_timeout_ms = $HUNT_TIMEOUT_MS"; }
  # idle_ms 12000 (> native 4000 default): kept as a latency knob only (#1925) -- do NOT ratchet it further.
  # Completion is gated on the wrapper's closing sentinel from flat-cyborg >= 0.13.0 (idle_gate_open()); idle_ms
  # only bounds how fast a marker-less (sentinel-less) reply is accepted once the screen goes quiet. If a stage
  # looks flaky, file it against the completion path, not this value.
  [ "$BACKEND" = "flat-cyborg" ] && { echo "llm.cli_timeout_ms = $HUNT_TIMEOUT_MS"; echo "llm.flat_cyborg.idle_ms = 12000"; echo "llm.model = ${MODEL:-opus}"; }
  echo "trace.level = normal"
  # The hunter reads source + the brief/taxonomy through exec sh; pass through its whole env contract.
  # #1827 DEPTH_TARGET/DEPTH_KNOWN MUST be on this allowlist: getenv() reads the SANITIZED env, so an
  # unregistered knob silently returns "" and the whole depth pass would be inert (the #1426/#1428 failure
  # mode). demo-discovery-parallel.sh asserts the stub actually receives them.
  # #1865 APPENDIX_FILE/APPENDIX_BASE ride the same rule for the same reason: unregistered => "" => the
  # hunter would concatenate the derived slice with no label and no judging rule, exactly as before the fix.
  echo "exec.env_passthrough = TARGET_DIR,IN_SCOPE,SCOPE_BRIEF,TAXONOMY,HUNT_CLASS,SUBSYSTEM,SLICER,DEPTH_TARGET,DEPTH_KNOWN,APPENDIX_FILE,APPENDIX_BASE"
  echo "exec.default_timeout_ms = 30000"
  # Learning/experience are ENABLED: hunter.ag ends its tick with `learn("hunt", ...)`, and it is that WRITE
  # the flag gates (#1878 measured it on agentis v1.28.0 — `experience.enabled = false` makes learn() raise
  # `runtime error: experience not enabled`, and ANY runtime error makes agentis discard the program's whole
  # accumulated stdout). So #1866/#1877's "structurally inert, safe to disable" premise was wrong for this
  # script: disabling them breaks every hunt cell (no CANDIDATE|/SAFE sentinel -> 5 failed attempts ->
  # FAILED), even though the cp -r isolation means nothing is ever read back. Regression restored here.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
  # #1887: the knowledge store must be enabled for hunter.ag's query_knowledge("refute-constraint", …) read.
  # This is MANDATORY, not a nicety: without it the call raises `knowledge base not enabled`, and — exactly
  # like the experience flag above — a runtime error makes agentis DISCARD the cell's whole stdout, so every
  # cell would report a false SAFE/FAILED (#1877's silent zero). It therefore ships in the SAME change as the
  # query_knowledge call. Harmless with no corpus imported: query_knowledge returns [] and the block is "".
  # (map-zones.sh:knowledge.enabled does the same for zone-mapper.ag's #1711 read.)
  echo "knowledge.enabled = true"
} > "$RUN/.agentis/config"

# #1887 LEARN->ACT bridge: if the operator points REFUTE_CONSTRAINTS_JSON at a refute-to-knowledge.sh output,
# import it into THIS run's store (just wiped + re-init'd above) BEFORE the cell loop — and therefore before
# the per-cell `cp -r "$RUN/.agentis"`, so every cell gets the SAME corpus and no cell can accumulate into a
# sibling's. Unset/unreadable -> skipped -> today's behaviour exactly. --replace is mandatory (a re-import
# without it accumulates samples). Not an exec.env_passthrough entry: this is a shell-level env read here,
# not an `.ag` getenv() — the same wiring as map-zones.sh's HUNT_FITNESS_JSON.
if [ -n "${REFUTE_CONSTRAINTS_JSON:-}" ] && [ -r "${REFUTE_CONSTRAINTS_JSON:-}" ]; then
  ( cd "$RUN" && "$AGENTIS" knowledge import "$REFUTE_CONSTRAINTS_JSON" --replace ) \
    || echo "run-discovery.sh: refute-constraint import failed (continuing)" >&2
fi

REPORT="$OUT/discovery-report.md"
{
  echo "# Dark Factory — custom-code discovery leads"
  echo
  echo "- repo: \`$(basename "$REPO")\`   backend: $BACKEND"
  # #1857: a depth-only re-entry hunted NO breadth cell — say so on the record, next to the provenance of the
  # breadth sample it reused, so the table below is never read as "this run found these leads".
  [ -n "$DEPTH_FROM" ] && echo "- depth-only re-entry (#1857): $DF_CELLS breadth cell(s) carried from \`$DEPTH_FROM\`; recorded commit ${DF_COMMIT:-none (UNVERIFIED)}, current HEAD $COMMIT"
  echo "- Each CANDIDATE below is an UNVERIFIED LEAD. It is a finding ONLY after it reproduces through"
  echo "  \`evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>\` (PoC PASSES = exploit fires)."
  echo "- Submission is a separate, explicit human action. This colony never posts to a platform."
  echo
  echo "| Subsystem | Class | Lead (file:fn:line / severity / exploit / PoC sketch) |"
  echo "|---|---|---|"
} > "$REPORT"

CELLS=0 ; CANDIDATES=0 ; STEERS=0 ; FAILED_CELLS=0
# #1707: FAILED_CELLS counts cells whose hunter reply never carried a CANDIDATE|/SAFE sentinel after
# DF_AGENT_MAX_ATTEMPTS retries (TUI chrome / no answer). Such a cell is NOT a rigorous negative — it is
# surfaced as a distinct FAILED row + a "status":"failed" JSON record, never silently folded into "0 candidates".
# #1001: rows recording where one cell's lead STEERED a later cell (the blackboard coordination loop),
# folded into the report at the end. Kept separate from $REPORT so it can be appended as its own table.
COORD="$RUN/coordination.tsv"; : > "$COORD"
# #1625: per-cell JSON accumulator for the additive discovery-results.json (written on BOTH the serial and
# the parallel path). One object per cell, appended in MANIFEST order; it never mutates $REPORT's bytes.
CELLS_JSONL="$RUN/results-cells.jsonl"; : > "$CELLS_JSONL"

# #1625 (epic #1611 M3): concurrency ceiling. The effective parallelism is min(--jobs, CELL_CAP); the cap is
# a HARD limit (never fail-open) so N concurrent agentis go / forge / solc processes cannot OOM-thrash a
# single host. Conservative default 4; tune per host via LLM_MAX_DISCOVERY_CELLS.
CELL_CAP="${LLM_MAX_DISCOVERY_CELLS:-4}"
case "$CELL_CAP" in ''|*[!0-9]*) CELL_CAP=4 ;; esac
[ "$CELL_CAP" -ge 1 ] || CELL_CAP=4
# --jobs > 1 uses `wait -n` (bash >= 4.3). On an older bash, degrade to the serial path rather than misbehave.
if [ "$JOBS" -gt 1 ]; then
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 3 ]; }; then
    echo "run-discovery.sh: --jobs > 1 needs bash >= 4.3 (wait -n) — running serially instead" >&2
    JOBS=1
  fi
fi

# --- factored cell primitives: run_cell + scrape_cell_log are called IDENTICALLY by the serial loop and the
# deferred parallel-aggregation pass, so --jobs 1 stays byte-for-byte identical to the pre-M3 hunt (#1625). ---

# _json_str <s> — emit <s> as a JSON string literal (escape backslash + double-quote; cell output is single-line).
_json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# _join_wrapped_candidates <log> — reconstruct one logical line per `CANDIDATE|...` record from a hunt log,
# undoing flat-cyborg's PTY-capture line wrap (#1705). A `CANDIDATE|file:fn:line|class|severity|exploit|poc`
# record's exploit/poc_sketch prose routinely exceeds one physical line; the raw log then carries the tail
# as continuation lines with no `CANDIDATE|` prefix, which a bare `grep 'CANDIDATE|'` silently drops. Here a
# `CANDIDATE|` line opens/flushes a record; a `BLACKBOARD-*` line, a `DEPTH-CELL|` line (#1827), an
# `APPENDIX-CONTEXT|` line (#1865), a `REFUTE-CONSTRAINTS|` line (#1887) or a blank line closes the current
# record without starting a new one
# (these are the only meaningful boundary tokens in a hunt log — see hunter.ag's own framing); any other line
# while a record is open is a continuation, appended with a single space (terminal wrap breaks on column
# width, not on meaningful newlines — a stray space is a cosmetic artifact, not data loss). Emits one
# reconstructed line per record, in log order.
_join_wrapped_candidates() {
  jwc_log="$1"
  awk '
    /^[[:space:]]*CANDIDATE\|/ {
      if (rec != "") print rec
      rec = $0
      next
    }
    /^[[:space:]]*BLACKBOARD-/ || /^[[:space:]]*DEPTH-CELL\|/ || /^[[:space:]]*APPENDIX-CONTEXT\|/ || /^[[:space:]]*REFUTE-CONSTRAINTS\|/ || /^[[:space:]]*$/ {
      if (rec != "") { print rec; rec = "" }
      next
    }
    {
      if (rec != "") {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        rec = rec " " line
      }
    }
    END { if (rec != "") print rec }
  ' "$jwc_log"
}

# _accumulate_cell <subsys> <cls> <files> <log> [status] [phase] — append ONE JSON object for this cell to
# $CELLS_JSONL (additive; feeds discovery-results.json). Never touches $REPORT. [status] defaults to "ok";
# a #1707 no-sentinel-after-retries cell is recorded as "failed" so the JSON distinguishes it from a clean
# (0-candidate) negative. [phase] (#1827) is "depth" ONLY on a depth cell — a breadth cell's object gains no
# key at all, so the depth-off JSON is byte-identical to the pre-#1827 one.
# #1865: `appendix` is derived from the LOG (the hunter's own APPENDIX-CONTEXT| sentinel), not from a new
# parameter — the same idiom as `coordination` below, and it records what the AGENT actually framed rather
# than what the shell intended to stage. It is appended LAST in the printf, after `phase`, so
# _plan_depth_cells's forward key scan (subsystem -> class -> files -> status -> candidates) is untouched and
# a cell with no appendix keeps its exact key set.
_accumulate_cell() {
  ac_subsys="$1"; ac_cls="$2"; ac_files="$3"; ac_log="$4"; ac_status="${5:-ok}"; ac_phase="${6:-}"
  ac_phase_json=""
  if [ "$ac_phase" = "depth" ]; then ac_phase_json=',"phase":"depth"'; fi
  ac_cands=""
  while IFS= read -r ac_line; do
    [ -n "$ac_line" ] || continue
    ac_c="$(printf '%s' "$ac_line" | sed 's/^.*\(CANDIDATE|\)/\1/; s/^CANDIDATE|//')"
    ac_c="$(_json_str "$ac_c")"
    if [ -z "$ac_cands" ]; then ac_cands="$ac_c"; else ac_cands="$ac_cands,$ac_c"; fi
  done < <(_join_wrapped_candidates "$ac_log" 2>/dev/null || true)
  ac_coord=""
  if grep -q '^BLACKBOARD-FOCUS|' "$ac_log" 2>/dev/null; then
    ac_f="$(grep '^BLACKBOARD-FOCUS|' "$ac_log" | head -1 | sed 's/^BLACKBOARD-FOCUS|//')"
    ac_coord="$(_json_str "$ac_f")"
  fi
  ac_appendix_json=""
  if grep -q '^APPENDIX-CONTEXT|' "$ac_log" 2>/dev/null; then
    ac_a="$(grep '^APPENDIX-CONTEXT|' "$ac_log" | head -1 | sed 's/^APPENDIX-CONTEXT|//')"
    ac_appendix_json=",\"appendix\":$(_json_str "$ac_a")"
  fi
  printf '{"subsystem":%s,"class":%s,"files":%s,"status":%s,"candidates":[%s],"coordination":[%s]%s%s}\n' \
    "$(_json_str "$ac_subsys")" "$(_json_str "$ac_cls")" "$(_json_str "$ac_files")" \
    "$(_json_str "$ac_status")" "$ac_cands" "$ac_coord" "$ac_phase_json" "$ac_appendix_json" >> "$CELLS_JSONL"
}

# _appendix_for <subsystem> <files_csv> — #1865: the (token, base) pair the --appendix sidecar records for
# THIS manifest line, printed as `<token>\t<base>`, or nothing. Two guards make the sidecar advisory-and-safe:
#   * no --appendix (or no row for this subsystem) => nothing, i.e. the framing is simply off for this cell;
#   * SELF-CHECK: the row is used only when its token literally appears in this line's FILES_CSV. map-zones.sh
#     keys scope.tsv lines on clean(name) with no dedup, so a subsystem name can match SEVERAL manifest lines
#     (the ambiguity run-zone-hunt.sh already documents at its per-zone cap probe). Framing a line that does
#     not carry the token would tell the hunter its contract is abstract about a payload that has no
#     appendix section at all — the check makes that impossible.
_appendix_for() {
  [ -n "$APPENDIX_TSV" ] || return 0
  af_row="$(awk -F'	' -v s="$1" '$1 == s { print $2 "	" $3; exit }' "$APPENDIX_TSV" 2>/dev/null || true)"
  [ -n "$af_row" ] || return 0
  af_tok="${af_row%%	*}"
  [ -n "$af_tok" ] || return 0
  case ",$2," in
    *",$af_tok,"*) printf '%s\n' "$af_row" ;;
  esac
}

# run_cell <dir> <subsys> <cls> <in_scope> <log> [depth_target] [depth_known] [appendix_file] [appendix_base]
# — invoke the hunter for ONE
# (subsystem x class) cell into <log>. Serial passes dir=$RUN (the shared store); parallel passes an isolated
# per-cell store. Never trips set -e (the invocation ends `|| echo …`), so a failed cell degrades (its log is
# still scraped), not aborts. #1827: the two trailing params are EMPTY on every breadth cell (the hunter's
# depth block is then "" and its prompt is byte-identical); a depth cell passes the `file@fn` under review and
# the already-known lead(s) that must not be re-reported.
# #1865: params 8/9 carry the appendix pair for a BREADTH cell whose payload holds the derived implementor.
# They are EMPTY on every depth cell by construction: a depth payload IS the narrowed function, so framing it
# as "your contract is abstract, the last section implements it" would be a lie about that payload.
run_cell() {
  rc_dir="$1"; rc_subsys="$2"; rc_cls="$3"; rc_in_scope="$4"; rc_log="$5"
  rc_depth_target="${6:-}"; rc_depth_known="${7:-}"
  rc_appendix_file="${8:-}"; rc_appendix_base="${9:-}"
  echo "run-discovery.sh: hunting $rc_cls on '$rc_subsys' ..." >&2
  # shellcheck disable=SC2317  # invoked by name through df_run_agent_validated
  _rc_attempt() {
    ( cd "$rc_dir" && env \
        TARGET_DIR="$REPO" \
        IN_SCOPE="$rc_in_scope" \
        SCOPE_BRIEF="$BRIEF" \
        TAXONOMY="$TAXONOMY" \
        HUNT_CLASS="$rc_cls" \
        SUBSYSTEM="$rc_subsys" \
        SLICER="$rc_dir/slice-fns.sh" \
        DEPTH_TARGET="$rc_depth_target" \
        DEPTH_KNOWN="$rc_depth_known" \
        APPENDIX_FILE="$rc_appendix_file" \
        APPENDIX_BASE="$rc_appendix_base" \
        "$AGENTIS" go hunter.ag --enable-exec --enable-messaging --grant-pii ) >"$1" 2>&1 || \
        echo "run-discovery.sh: hunter run failed for $rc_cls/'$rc_subsys' (see $1)" >&2
  }
  # #1707: validate the hunter reply carries a CANDIDATE|/SAFE sentinel and RETRY on TUI chrome / no answer,
  # instead of scraping an empty log as a rigorous negative. The retry lives INSIDE run_cell (called by both
  # the serial and parallel paths) and failure is signalled via a "$rc_log.novalid" MARKER FILE, not an exit
  # code — a backgrounded `run_cell &` loses its return across `wait -n`, but the marker survives for the
  # deferred manifest-order aggregation in scrape_cell_log. Never trips set -e (|| true).
  df_run_agent_validated "$DF_AGENT_MAX_ATTEMPTS" "run-discovery.sh: $rc_cls/'$rc_subsys'" "$rc_log" hunter "" _rc_attempt || true
}

# scrape_cell_log <subsys> <cls> <log> <files> [phase] — the (byte-identical) post-cell scrape: surface the
# #1001 BLACKBOARD-FOCUS coordination row (+ $COORD, STEERS), scrape CANDIDATE| rows into $REPORT
# (+ CANDIDATES), and accumulate the cell into the additive JSON. Called in MANIFEST order on both paths
# (deterministic). [phase] (#1827) is "depth" only for a depth cell and is forwarded to _accumulate_cell.
scrape_cell_log() {
  sc_subsys="$1"; sc_cls="$2"; sc_log="$3"; sc_files="$4"; sc_phase="${5:-}"
  # #1707: a cell whose reply never produced a CANDIDATE|/SAFE sentinel after DF_AGENT_MAX_ATTEMPTS retries
  # (TUI chrome / no answer) carries a "$sc_log.novalid" marker. Do NOT treat its empty log as a rigorous
  # negative: surface it as a DISTINCT FAILED row + counter so it is visible, not silently folded into
  # "0 candidates". Recorded as "status":"failed" in the additive JSON.
  # #1955 Lever 1b: a cell whose reply was a genuine `[llm.timeout]` (the per-cell prompt exceeded the scaled
  # timeout budget) carries a "$sc_log.timeout" marker dropped by df_run_agent_validated. Surface it as a
  # DISTINCT FAILED reason BEFORE the generic .novalid branch below — the timeout marker rides alongside
  # .novalid (a timeout IS a no-valid-sentinel failure), so this ordering is what makes it distinguishable
  # from TUI chrome. The JSON "status":"failed" is UNCHANGED (byte-compatible with zone-coverage derivation);
  # the discriminator lives only in the row text + stderr line, and --rehunt-gaps is the recovery path.
  if [ -f "$sc_log.timeout" ]; then
    echo "run-discovery.sh:   ↳ FAILED: $sc_cls/'$sc_subsys' LLM call timed out (per-cell prompt exceeded the timeout budget; re-hunt with --rehunt-gaps)" >&2
    printf '| %s | %s | FAILED — LLM call timed out (per-cell prompt exceeded the timeout budget; re-hunt with --rehunt-gaps) |\n' \
      "$sc_subsys" "$sc_cls" >> "$REPORT"
    FAILED_CELLS=$((FAILED_CELLS + 1))
    _accumulate_cell "$sc_subsys" "$sc_cls" "$sc_files" "$sc_log" failed "$sc_phase"
    return 0
  fi
  if [ -f "$sc_log.novalid" ]; then
    echo "run-discovery.sh:   ↳ FAILED: $sc_cls/'$sc_subsys' produced no CANDIDATE|/SAFE reply after $DF_AGENT_MAX_ATTEMPTS attempts (NOT a rigorous negative)" >&2
    printf '| %s | %s | FAILED — no CANDIDATE|/SAFE reply after %s attempts (NOT a rigorous negative) |\n' \
      "$sc_subsys" "$sc_cls" "$DF_AGENT_MAX_ATTEMPTS" >> "$REPORT"
    FAILED_CELLS=$((FAILED_CELLS + 1))
    _accumulate_cell "$sc_subsys" "$sc_cls" "$sc_files" "$sc_log" failed "$sc_phase"
    return 0
  fi
  # #1001 coordination: the hunter reads a shared BLACKBOARD before it prompts and posts every
  # CANDIDATE back to it, so a lead an EARLIER cell found steers later cells (corroborate / pivot).
  # Surface both halves of that loop to the operator and the report: BLACKBOARD-FOCUS| = THIS cell was
  # steered by a sibling's lead; BLACKBOARD-POST| = this cell posted a lead for later cells.
  if grep -q '^BLACKBOARD-FOCUS|' "$sc_log"; then
    FOCUS_LINE="$(grep '^BLACKBOARD-FOCUS|' "$sc_log" | head -1 | sed 's/^BLACKBOARD-FOCUS|//')"
    echo "run-discovery.sh:   ↳ COORDINATION: $sc_cls/'$sc_subsys' steered by the blackboard ($FOCUS_LINE)" >&2
    printf '| %s | %s | steered by blackboard — %s |\n' "$sc_subsys" "$sc_cls" "$FOCUS_LINE" >> "$COORD"
    STEERS=$((STEERS + 1))
  fi
  # #1865: the hunter prints APPENDIX-CONTEXT|<token> when it FRAMED a payload section as the derived
  # implementor of an abstract base. Surface it to the operator (the twin of verify-findings.sh's gate-side
  # line), so a candidate located in a file the zone does not own is attributable while the run is happening.
  if grep -q '^APPENDIX-CONTEXT|' "$sc_log"; then
    APX_LINE="$(grep '^APPENDIX-CONTEXT|' "$sc_log" | head -1 | sed 's/^APPENDIX-CONTEXT|//')"
    echo "run-discovery.sh:   ↳ implementation appendix attached: $APX_LINE" >&2
  fi
  # The hunter's contract: a `CANDIDATE|file:fn:line|class|severity|exploit|poc` line, or `SAFE`.
  # Exclude the hunter's own `BLACKBOARD-*` diagnostic lines: they echo a lead summary (which no longer
  # carries a bare `CANDIDATE|` token, but stay defensive) and must never be scraped as findings.
  if grep -v '^BLACKBOARD-' "$sc_log" | grep -q 'CANDIDATE|'; then
    while IFS= read -r LINE; do
      CAND="$(printf '%s' "$LINE" | sed 's/^.*\(CANDIDATE|\)/\1/')"
      BODY="$(printf '%s' "$CAND" | sed 's/^CANDIDATE|//; s/|/ \/ /g')"
      printf '| %s | %s | %s |\n' "$sc_subsys" "$sc_cls" "$BODY" >> "$REPORT"
      CANDIDATES=$((CANDIDATES + 1))
    done < <(_join_wrapped_candidates "$sc_log")
    if grep -q '^BLACKBOARD-POST|' "$sc_log"; then
      echo "run-discovery.sh:   ↳ posted a lead to the blackboard for later cells to focus on" >&2
    fi
  fi
  _accumulate_cell "$sc_subsys" "$sc_cls" "$sc_files" "$sc_log" ok "$sc_phase"
}

# _plan_depth_cells <cap> <known-dir> — #1827: read the ACCUMULATED breadth cells in $CELLS_JSONL and print
# the depth plan, one TSV row per depth cell: `<subsystem>\t<class>\t<file@fn>\t<known-leads file>`. Also
# writes each flagged location's already-known lead block to <known-dir>/known-<rank>.txt (multi-line, so it
# cannot ride on the TSV row). Prints nothing when no breadth cell surfaced a usable location.
#
# It reads $CELLS_JSONL — NOT the blackboard memo — precisely because that accumulator is written in MANIFEST
# order on BOTH the serial and the --jobs > 1 path (under parallelism every cell's board is empty, so a
# memo-derived target list would differ per path). One code path, one order, one depth set.
#
# Ranking (deterministic, no ties left to the shell): (a) severity High before Medium before other, (b) more
# breadth candidates first, (c) first appearance in manifest order. Per location the class order is the zone's
# classes that did NOT produce a lead there (in manifest order) FIRST, then the producing one(s) LAST — at both
# diagnosing sites the co-located miss lives under a DIFFERENT taxonomy class than the hit, so a cross-lens
# re-read is the higher-yield draw and same-class exhaustion is the fallback. The cap is then spent by the
# #1850 QUOTA-ROUND-ROBIN: `quota` consecutive lenses per location, in rounds, so the budget CONCENTRATES on
# the top-ranked functions without ever burning entirely on the first one (quota = 1 is the #1827 spread).
#
# The JSON scan is a real (tiny) string scanner rather than a `,`-split: _json_str escapes `\` and `"`, and a
# hunter's exploit prose routinely contains quotes — splitting on `","` would mis-slice such a record.
_plan_depth_cells() {
  awk -v cap="$1" -v kdir="$2" -v quota="$3" '
    # Index of the value opening-quote for <key> at or after <from>; 0 when absent.
    function nextkey(s, from, key,   q) {
      q = index(substr(s, from), key)
      if (q == 0) return 0
      return from + q - 1 + length(key)
    }
    # Decode the JSON string whose opening quote is at s[p]; sets G_STR + G_POS (just past the close quote).
    function jsread(s, p,   out, c) {
      out = ""; p = p + 1
      while (p <= length(s)) {
        c = substr(s, p, 1)
        if (c == "\\") { out = out substr(s, p + 1, 1); p = p + 2; continue }
        if (c == "\"") { G_STR = out; G_POS = p + 1; return }
        out = out c; p = p + 1
      }
      G_STR = out; G_POS = p
    }
    # Should location a be ranked AFTER location b?
    function worse(a, b) {
      if (loc_sev[a] != loc_sev[b]) return (loc_sev[a] > loc_sev[b])
      if (loc_count[a] != loc_count[b]) return (loc_count[a] < loc_count[b])
      return (loc_first[a] > loc_first[b])
    }
    BEGIN { ci = 0; nloc = 0 }
    {
      line = $0; pos = 1
      k = nextkey(line, pos, "\"subsystem\":"); if (k == 0) next
      jsread(line, k); subsys = G_STR; pos = G_POS
      k = nextkey(line, pos, "\"class\":");     if (k == 0) next
      jsread(line, k); cls = G_STR; pos = G_POS
      k = nextkey(line, pos, "\"files\":");     if (k == 0) next
      jsread(line, k); pos = G_POS
      k = nextkey(line, pos, "\"status\":");    if (k == 0) next
      jsread(line, k); status = G_STR; pos = G_POS
      ci++
      # The zone class order IS the manifest (scope.tsv) order: first appearance wins. A cell that FAILED
      # still contributes its class here — the class was hunted, it just produced no usable reply.
      if (!((subsys SUBSEP cls) in zcls_seen)) {
        zcls_seen[subsys SUBSEP cls] = 1
        zn[subsys]++
        zcls[subsys, zn[subsys]] = cls
      }
      if (status != "ok") next
      k = index(substr(line, pos), "\"candidates\":[")
      if (k == 0) next
      pos = pos + k - 1 + length("\"candidates\":[")
      while (1) {
        c = substr(line, pos, 1)
        if (c == "" || c == "]") break
        if (c != "\"") { pos++; continue }
        jsread(line, pos); cand = G_STR; pos = G_POS
        # `file:fn[:line]|class|severity|exploit|poc` — the location is the head field.
        b = index(cand, "|")
        if (b > 0) head = substr(cand, 1, b - 1); else head = cand
        i1 = index(head, ":")
        if (i1 < 2) continue                       # no `file:fn` -> nothing to narrow the payload to
        file = substr(head, 1, i1 - 1)
        rest = substr(head, i1 + 1)
        i2 = index(rest, ":")
        if (i2 > 0) fn = substr(rest, 1, i2 - 1); else fn = rest
        if (fn == "") continue
        # SECURITY: file/fn come from the LOCATION field of a hunter-written CANDIDATE line -- LLM output,
        # NOT operator-curated scope.tsv content. loc_target (file@fn) becomes the IN_SCOPE of a depth cell,
        # and cat_file() in hunter.ag concatenates IN_SCOPE UNESCAPED into an exec sh command (pre-#1827
        # code, safe only while IN_SCOPE was always trusted config). A prompt-injected or hostile target
        # could make the hunter emit a location carrying shell metacharacters or a dot-dot traversal, so
        # reject anything that is not a plain repo-relative path / identifier BEFORE it becomes a target.
        if (file !~ /^[A-Za-z0-9_.\/-]+$/) continue
        if (file ~ /(^|\/)\.\.(\/|$)/) continue
        if (file ~ /^\//) continue
        if (fn !~ /^[A-Za-z0-9_$]+$/) continue
        sev = 2
        nf = split(cand, F, "|")
        if (nf >= 3) {
          s3 = tolower(F[3])
          if (index(s3, "high") > 0) sev = 0
          else if (index(s3, "medium") > 0) sev = 1
        }
        key = subsys SUBSEP file SUBSEP fn
        if (!(key in loc_seen)) {
          loc_seen[key] = 1
          nloc++
          loc_key[nloc] = key
          loc_subsys[key] = subsys
          loc_target[key] = file "@" fn
          loc_first[key] = ci
          loc_sev[key] = sev
          loc_count[key] = 0
          loc_known[key] = ""
        }
        if (sev < loc_sev[key]) loc_sev[key] = sev
        loc_count[key]++
        loc_prod[key, cls] = 1
        if (loc_known[key] == "") loc_known[key] = "- " cand
        else loc_known[key] = loc_known[key] "\n- " cand
      }
    }
    END {
      if (nloc == 0) exit 0
      for (i = 1; i <= nloc; i++) ord[i] = loc_key[i]
      for (i = 2; i <= nloc; i++) {                 # insertion sort: n is the flagged-location count
        v = ord[i]; j = i - 1
        while (j >= 1 && worse(ord[j], v)) { ord[j + 1] = ord[j]; j-- }
        ord[j + 1] = v
      }
      maxn = 0
      for (i = 1; i <= nloc; i++) {
        key = ord[i]; s = loc_subsys[key]; m = 0
        for (j = 1; j <= zn[s]; j++) { c = zcls[s, j]; if (!((key, c) in loc_prod)) { m++; clsl[key, m] = c } }
        for (j = 1; j <= zn[s]; j++) { c = zcls[s, j]; if ((key, c) in loc_prod)  { m++; clsl[key, m] = c } }
        clsn[key] = m
        if (m > maxn) maxn = m
        kf = kdir "/known-" i ".txt"
        print loc_known[key] > kf
        close(kf)
        loc_kf[key] = kf
      }
      # #1850 QUOTA-ROUND-ROBIN. Each location gets `quota` CONSECUTIVE lenses before the plan moves on;
      # after every location has had its quota the rounds repeat (positions quota+1..2*quota, and so on)
      # until the cap is spent. At quota == 1 this degenerates to the #1827 `for pass { for location }`
      # spread BYTE-FOR-BYTE, which is why that allocation needs no second code path. A location with fewer
      # remaining lenses than the quota emits all it has and the stream continues — no reserved-but-unspent
      # quota, so the plan is one ordered stream truncated at `cap`, work-conserving by construction.
      emitted = 0
      for (rnd = 0; rnd * quota < maxn; rnd++) {
        progressed = 0
        for (i = 1; i <= nloc; i++) {
          key = ord[i]
          for (q = 1; q <= quota; q++) {
            p = rnd * quota + q
            if (p > clsn[key]) break            # the lens list of this location is exhausted for this round
            if (emitted >= cap) exit 0
            printf "%s\t%s\t%s\t%s\n", loc_subsys[key], clsl[key, p], loc_target[key], loc_kf[key]
            emitted++
            progressed = 1
          }
        }
        if (!progressed) break
      }
    }
  ' "$CELLS_JSONL"
}

# _seed_from_recorded_run — #1857: the DEPTH-ONLY RE-ENTRY. Instead of hunting the breadth pass, seed
# $CELLS_JSONL with the BREADTH cells of a recorded `discovery-results.json` and let the run fall straight
# into the unchanged #1827 depth block below: _plan_depth_cells + run_cell + scrape_cell_log are reused
# VERBATIM, so the plan a re-entry computes is the plan the original run computed. That is the whole property
# this exists to buy, and it is why the re-entry is not a second script.
#
# The cells are re-emitted with `separators=(",",":")` + `ensure_ascii=False`, which reproduces _json_str's
# output byte-for-byte on both preserved plaza arms — the carried records are the SOURCE records, not an
# approximation, so verify-findings.sh -> score-match.py score a depth-only arm exactly like a full run.
#
# The carried breadth cells are ALSO re-rendered into $REPORT/$COORD with the same transformations
# scrape_cell_log uses, and the counters are seeded from the recorded run, so a depth-only report is not
# misleadingly empty of the breadth leads its depth plan was derived from.
_seed_from_recorded_run() {
  sr_rows="$RUN/depth-from-rows.tsv"
  python3 - "$DEPTH_FROM" "$CELLS_JSONL" "$sr_rows" <<'PY'
import sys, json
src, jsonl, rows = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, encoding="utf-8") as fh:
    d = json.load(fh)
breadth = [c for c in d["cells"] if isinstance(c, dict) and c.get("phase") != "depth"]
with open(jsonl, "w", encoding="utf-8") as out:
    for c in breadth:
        out.write(json.dumps(c, ensure_ascii=False, separators=(",", ":")) + "\n")
def flat(s):
    # The row file is TSV read back by the shell; a tab/newline inside a hunter-written string would split it.
    return str(s).replace("\t", " ").replace("\r", " ").replace("\n", " ")
with open(rows, "w", encoding="utf-8") as out:
    for c in breadth:
        sub, cls = flat(c.get("subsystem", "")), flat(c.get("class", ""))
        if c.get("status") != "ok":
            # Mirrors scrape_cell_log's early return: a #1707 failed cell contributes its FAILED row and
            # nothing else — never silently folded into "0 candidates".
            out.write("\t".join(["failed", sub, cls, ""]) + "\n")
            continue
        for cand in (c.get("candidates") or []):
            out.write("\t".join(["cand", sub, cls, flat(cand)]) + "\n")
        for co in (c.get("coordination") or []):
            out.write("\t".join(["steer", sub, cls, flat(co)]) + "\n")
PY
  CELLS="$DF_CELLS"
  while IFS='	' read -r SR_KIND SR_SUBSYS SR_CLS SR_BODY || [ -n "${SR_KIND:-}" ]; do
    case "$SR_KIND" in
      cand)
        SR_RENDERED="$(printf '%s' "$SR_BODY" | sed 's/|/ \/ /g')"
        printf '| %s | %s | %s |\n' "$SR_SUBSYS" "$SR_CLS" "$SR_RENDERED" >> "$REPORT"
        CANDIDATES=$((CANDIDATES + 1)) ;;
      steer)
        printf '| %s | %s | steered by blackboard — %s |\n' "$SR_SUBSYS" "$SR_CLS" "$SR_BODY" >> "$COORD"
        STEERS=$((STEERS + 1)) ;;
      failed)
        printf '| %s | %s | FAILED — carried from the recorded run, no CANDIDATE|/SAFE reply (NOT a rigorous negative) |\n' \
          "$SR_SUBSYS" "$SR_CLS" >> "$REPORT"
        FAILED_CELLS=$((FAILED_CELLS + 1)) ;;
    esac
  done < "$sr_rows"
  echo "run-discovery.sh: depth-only re-entry — carried $CELLS breadth cell(s) / $CANDIDATES candidate(s) from $DEPTH_FROM; NO breadth cell is re-hunted" >&2
}

# Manifest loop: one subsystem per line, `subsystem | classes | files`. Run the hunter once per
# (subsystem x class) — that cell is the colony-native analogue of one focused audit agent.
# #1857: --depth-from replaces the whole breadth pass with the recorded one; the serial and parallel blocks
# below are textually untouched, so the shipped path cannot be reached by the re-entry and vice versa.
if [ -n "$DEPTH_FROM" ]; then
  _seed_from_recorded_run
elif [ "$JOBS" -le 1 ]; then
  # SERIAL path (default): the current loop, byte-for-byte identical to the pre-M3 hunt — run_cell then
  # scrape_cell_log inline in manifest order against the ONE shared $RUN store (live #1001 steering).
  while IFS='|' read -r SUBSYS CLS_CSV FILES_CSV || [ -n "${SUBSYS:-}" ]; do
    # trim + skip blanks/comments
    SUBSYS="$(printf '%s' "$SUBSYS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$SUBSYS" in ''|\#*) continue ;; esac
    CLS_CSV="$(printf '%s' "$CLS_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    FILES_CSV="$(printf '%s' "$FILES_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$ONLY" ] && [ "$SUBSYS" != "$ONLY" ] && continue
    [ -n "$CLASSES_OVERRIDE" ] && CLS_CSV="$CLASSES_OVERRIDE"
    [ -n "$FILES_CSV" ] || { echo "run-discovery.sh: subsystem '$SUBSYS' has no files; skipping" >&2; continue; }

    # IN_SCOPE is newline-separated (hunter splits on \n); convert the manifest's comma list.
    IN_SCOPE="$(printf '%s' "$FILES_CSV" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)"
    SLUG="$(printf '%s' "$SUBSYS" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
    # #1865: resolve the appendix pair ONCE per manifest line (every class cell of a line shares the payload).
    APXF="" ; APXB=""
    APX_ROW="$(_appendix_for "$SUBSYS" "$FILES_CSV")"
    if [ -n "$APX_ROW" ]; then APXF="${APX_ROW%%	*}"; APXB="${APX_ROW#*	}"; fi

    OLDIFS="$IFS"; IFS=','
    for CLS in $CLS_CSV; do
      IFS="$OLDIFS"
      CLS="$(printf '%s' "$CLS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$CLS" ] || { IFS=','; continue; }
      CELLS=$((CELLS + 1))
      CELL_LOG="$RUN/hunt_${SLUG}_${CLS}.log"
      run_cell "$RUN" "$SUBSYS" "$CLS" "$IN_SCOPE" "$CELL_LOG" "" "" "$APXF" "$APXB"
      scrape_cell_log "$SUBSYS" "$CLS" "$CELL_LOG" "$FILES_CSV"
      IFS=','
    done
    IFS="$OLDIFS"
  done < "$SCOPE"
else
  # PARALLEL path (#1625, --jobs > 1): expand the manifest into an ORDERED cell list, give EACH cell its OWN
  # isolated agentis store (a cp -r of the initialised $RUN template) so concurrent memo/build writes never
  # race — which means every cell's blackboard is EMPTY and #1001 cross-cell steering is disabled here (the
  # documented throughput-vs-steering trade). Launch under a HARD `wait -n` slot capped at effective_jobs =
  # min(--jobs, CELL_CAP); after the pool drains, scrape each cell in MANIFEST order (the SAME scrape_cell_log)
  # so the aggregated finding set is identical + independent of completion order.
  CELL_SUBSYS=() ; CELL_CLS=() ; CELL_INSCOPE=() ; CELL_FILES=() ; CELL_DIR=() ; CELL_LOGP=()
  CELL_APXF=() ; CELL_APXB=()   # #1865: the per-line appendix pair, resolved with the manifest line itself
  while IFS='|' read -r SUBSYS CLS_CSV FILES_CSV || [ -n "${SUBSYS:-}" ]; do
    SUBSYS="$(printf '%s' "$SUBSYS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$SUBSYS" in ''|\#*) continue ;; esac
    CLS_CSV="$(printf '%s' "$CLS_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    FILES_CSV="$(printf '%s' "$FILES_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$ONLY" ] && [ "$SUBSYS" != "$ONLY" ] && continue
    [ -n "$CLASSES_OVERRIDE" ] && CLS_CSV="$CLASSES_OVERRIDE"
    [ -n "$FILES_CSV" ] || { echo "run-discovery.sh: subsystem '$SUBSYS' has no files; skipping" >&2; continue; }
    IN_SCOPE="$(printf '%s' "$FILES_CSV" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)"
    SLUG="$(printf '%s' "$SUBSYS" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
    APXF="" ; APXB=""
    APX_ROW="$(_appendix_for "$SUBSYS" "$FILES_CSV")"
    if [ -n "$APX_ROW" ]; then APXF="${APX_ROW%%	*}"; APXB="${APX_ROW#*	}"; fi
    OLDIFS="$IFS"; IFS=','
    for CLS in $CLS_CSV; do
      IFS="$OLDIFS"
      CLS="$(printf '%s' "$CLS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$CLS" ] || { IFS=','; continue; }
      CELLS=$((CELLS + 1))
      CELL_SUBSYS+=("$SUBSYS") ; CELL_CLS+=("$CLS") ; CELL_INSCOPE+=("$IN_SCOPE")
      CELL_FILES+=("$FILES_CSV") ; CELL_DIR+=("$RUN/cell-${SLUG}_${CLS}") ; CELL_LOGP+=("$RUN/hunt_${SLUG}_${CLS}.log")
      CELL_APXF+=("$APXF") ; CELL_APXB+=("$APXB")
      IFS=','
    done
    IFS="$OLDIFS"
  done < "$SCOPE"

  effective_jobs="$JOBS"
  if [ "$effective_jobs" -gt "$CELL_CAP" ]; then
    echo "run-discovery.sh: --jobs $JOBS exceeds the hard cap LLM_MAX_DISCOVERY_CELLS=$CELL_CAP; clamping concurrency to $CELL_CAP" >&2
    effective_jobs="$CELL_CAP"
  fi
  echo "run-discovery.sh: parallel fan-out over ${#CELL_SUBSYS[@]} cell(s), up to $effective_jobs concurrent (isolated per-cell stores; #1001 cross-cell steering off under --jobs > 1)" >&2

  # Launch under a hard job-slot: keep at most effective_jobs run_cell processes live at any instant.
  live=0 ; idx=0 ; ncells=${#CELL_SUBSYS[@]}
  while [ "$idx" -lt "$ncells" ]; do
    while [ "$live" -ge "$effective_jobs" ]; do
      wait -n 2>/dev/null || true
      live=$((live - 1))
    done
    cdir="${CELL_DIR[$idx]}"
    rm -rf "$cdir"; mkdir -p "$cdir"
    cp -r "$RUN/.agentis" "$cdir/.agentis"        # isolated store: an empty blackboard, no cross-cell race
    cp "$RUN/hunter.ag" "$cdir/hunter.ag"
    cp "$RUN/slice-fns.sh" "$cdir/slice-fns.sh"
    run_cell "$cdir" "${CELL_SUBSYS[$idx]}" "${CELL_CLS[$idx]}" "${CELL_INSCOPE[$idx]}" "${CELL_LOGP[$idx]}" \
      "" "" "${CELL_APXF[$idx]}" "${CELL_APXB[$idx]}" &
    live=$((live + 1))
    idx=$((idx + 1))
  done
  while [ "$live" -gt 0 ]; do
    wait -n 2>/dev/null || true
    live=$((live - 1))
  done

  # Deferred aggregation: scrape every cell's log in MANIFEST order (order-independent of finish order).
  idx=0
  while [ "$idx" -lt "$ncells" ]; do
    scrape_cell_log "${CELL_SUBSYS[$idx]}" "${CELL_CLS[$idx]}" "${CELL_LOGP[$idx]}" "${CELL_FILES[$idx]}"
    idx=$((idx + 1))
  done
fi

# #1827 DEPTH PASS — ONE pass, after ALL breadth cells, on BOTH the serial and the parallel path (the plan is
# derived from the same manifest-ordered $CELLS_JSONL, so the depth set is identical either way). Each depth
# cell is a FULL cell: it increments $CELLS, runs through the unchanged run_cell + scrape_cell_log, and lands
# in cells[] tagged "phase":"depth". Targets are computed ONCE, BEFORE the first depth cell runs, so a depth
# candidate can never spawn further depth cells (the #1830 --rehunt-gaps rule: one pass, never a loop).
DEPTH_CELLS=0
if [ "$DEPTH_MAX_CELLS" -gt 0 ]; then
  DEPTH_KNOWN_DIR="$RUN/depth-known"; mkdir -p "$DEPTH_KNOWN_DIR"
  DEPTH_PLAN="$RUN/depth-plan.tsv"
  _plan_depth_cells "$DEPTH_MAX_CELLS" "$DEPTH_KNOWN_DIR" "$DEPTH_LENS_QUOTA" > "$DEPTH_PLAN"
  DEPTH_PLANNED="$(grep -c . "$DEPTH_PLAN" 2>/dev/null || true)"
  # #1857: the ONE provenance guard that reaches the WORKING TREE. Every other refusal is decided from the
  # artifact alone (before the output dir exists); this one needs the computed plan, so it fires here — still
  # BEFORE the first depth cell runs. A target the checkout no longer carries means the tree moved under the
  # recorded run, which is exactly the stale-checkout case the commit key cannot catch on an old artifact.
  if [ -n "$DEPTH_FROM" ]; then
    while IFS= read -r DG_TARGET; do
      [ -n "$DG_TARGET" ] || continue
      DG_FILE="${DG_TARGET%%@*}"
      [ -f "$REPO/$DG_FILE" ] || { echo "run-discovery.sh: --depth-from: the depth plan targets '$DG_FILE', which does not exist under $REPO — the checkout moved under the recorded run" >&2; exit 3; }
    done < <(cut -f3 "$DEPTH_PLAN" | sort -u)
  fi
  echo "run-discovery.sh: depth pass — ${DEPTH_PLANNED:-0} extra cell(s) over the flagged functions (cap $DEPTH_MAX_CELLS, lens quota $DEPTH_LENS_QUOTA per location per round)" >&2
  while IFS='	' read -r D_SUBSYS D_CLS D_TARGET D_KNOWNF || [ -n "${D_SUBSYS:-}" ]; do
    [ -n "$D_SUBSYS" ] || continue
    CELLS=$((CELLS + 1))
    DEPTH_CELLS=$((DEPTH_CELLS + 1))
    D_SLUG="$(printf '%s' "$D_SUBSYS" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
    D_LOG="$RUN/depth_${D_SLUG}_${D_CLS}_${DEPTH_CELLS}.log"
    D_KNOWN="$(cat "$D_KNOWNF" 2>/dev/null || true)"
    echo "run-discovery.sh:   ↳ DEPTH: re-reading $D_TARGET under $D_CLS (excluding the known lead(s))" >&2
    # IN_SCOPE is the NARROWED `file@fn` — cat_file() routes it through the existing slice-fns.sh slicer, so
    # the payload is that one function plus its contract header. It also keeps the depth cell's (subsystem,
    # class, files) key DISTINCT from the breadth cell's, which is what run-zone-hunt.sh's merge dedupes on.
    run_cell "$RUN" "$D_SUBSYS" "$D_CLS" "$D_TARGET" "$D_LOG" "$D_TARGET" "$D_KNOWN"
    scrape_cell_log "$D_SUBSYS" "$D_CLS" "$D_LOG" "$D_TARGET" depth
  done < "$DEPTH_PLAN"
fi

# #1707: only a run with ZERO candidates AND ZERO failed cells is a rigorous NEGATIVE. A cell that FAILED
# validation (chrome / no answer) is NOT evidence of cleanliness, so its presence suppresses this line —
# the FAILED rows above already make those cells visible as unassessed, not clean.
if [ "$CANDIDATES" -eq 0 ] && [ "$FAILED_CELLS" -eq 0 ]; then
  echo "| _(none)_ | — | rigorous NEGATIVE — no candidate of any hunted class survived. A clean result on audited code is a valid outcome; nothing is submitted. |" >> "$REPORT"
fi
{
  echo
  echo "---"
  echo "Cells run: $CELLS    Candidates surfaced: $CANDIDATES (all UNVERIFIED — forge-verify each before it counts)."
  # #1857: without this line `Cells run: N` reads as "N cells were hunted", which a depth-only re-entry did not do.
  [ -n "$DEPTH_FROM" ] && echo "Of those, $DF_CELLS breadth cell(s) were CARRIED from \`$DEPTH_FROM\` (NOT re-hunted); $DEPTH_CELLS depth cell(s) were hunted by this run."
} >> "$REPORT"

# #1001: append the coordination table — where a lead from one cell STEERED a later cell via the shared
# blackboard. This is what makes the run more than a sum of independent audits: emit it whenever any
# cell was steered, so the operator can see the inter-agent influence (and audit it).
if [ "$STEERS" -gt 0 ]; then
  {
    echo
    echo "## Inter-agent coordination (blackboard, #1001)"
    echo
    echo "A cell that surfaces a CANDIDATE posts it to a shared in-run blackboard; every later cell reads"
    echo "the board and is steered to corroborate a sibling's hit or pivot to a related surface. Cells"
    echo "steered this run:"
    echo
    echo "| Subsystem | Class | Steer |"
    echo "|---|---|---|"
    cat "$COORD"
  } >> "$REPORT"
fi

# #1625: additive machine-readable sibling of discovery-report.md — the same accumulator, emitted on BOTH
# paths. It does not affect discovery-report.md's bytes (the byte-identical invariant targets the report).
RESULTS_JSON="$OUT/discovery-results.json"
CELLS_ARR="$(paste -sd, "$CELLS_JSONL" 2>/dev/null || true)"
# #1827: totals.depth_cells appears ONLY when --depth-max-cells > 0, so a depth-off run's JSON keys are
# byte-identical to the pre-#1827 ones. `cells` is the TOTAL (breadth + depth) — depth never hides.
# #1850: totals.depth_lens_quota rides the SAME gate and records WHICH allocation produced these cells, so no
# future reader can compare two depth arms without seeing that they were spent differently.
DEPTH_TOTAL_JSON=""
if [ "$DEPTH_MAX_CELLS" -gt 0 ]; then DEPTH_TOTAL_JSON=",\"depth_cells\":$DEPTH_CELLS,\"depth_lens_quota\":$DEPTH_LENS_QUOTA"; fi
# #1857: `commit` is recorded on EVERY run (a soft git dependency that degrades to "unknown"), so a LATER
# --depth-from can refuse a stale checkout; `depth_from` rides the same emit-only-when-set gate as the depth
# totals, so a run without the flag keeps its exact key set.
DEPTH_FROM_JSON=""
if [ -n "$DEPTH_FROM" ]; then
  DEPTH_FROM_JSON=",\"depth_from\":{\"source\":$(_json_str "$DEPTH_FROM"),\"repo\":$(_json_str "$DF_REPO"),\"commit\":$(_json_str "$DF_COMMIT"),\"carried_cells\":$DF_CELLS,\"carried_candidates\":$DF_CANDIDATES}"
fi
printf '{"repo":%s,"commit":%s,"backend":%s,"jobs":%s%s,"cells":[%s],"totals":{"cells":%s,"candidates":%s,"steers":%s,"failed":%s%s}}\n' \
  "$(_json_str "$(basename "$REPO")")" "$(_json_str "$COMMIT")" "$(_json_str "$BACKEND")" "$JOBS" "$DEPTH_FROM_JSON" "$CELLS_ARR" \
  "$CELLS" "$CANDIDATES" "$STEERS" "$FAILED_CELLS" "$DEPTH_TOTAL_JSON" > "$RESULTS_JSON"

echo >&2
DEPTH_BANNER=""
if [ "$DEPTH_MAX_CELLS" -gt 0 ]; then DEPTH_BANNER=" ($DEPTH_CELLS depth)"; fi
echo "================ DISCOVERY: $CELLS cells$DEPTH_BANNER, $CANDIDATES candidate(s), $STEERS blackboard-steered, $FAILED_CELLS failed ================" >&2
echo "run-discovery.sh: leads at $REPORT" >&2
if [ "$CANDIDATES" -gt 0 ]; then
  echo "run-discovery.sh: NEXT = verify each lead with evm-harness/forge-verify.sh; only a PASSING PoC is a finding. Submission stays human-gated." >&2
else
  echo "run-discovery.sh: no candidates — rigorous negative. Nothing to verify, nothing submitted." >&2
fi
