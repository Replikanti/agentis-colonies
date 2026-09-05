#!/usr/bin/env bash
# map-zones.sh — #1612 (milestone M1 of epic #1611: zone-mapping). Auto-derive a target's DISCOVERY
# manifest from the code itself: locate in-scope Solidity/Anchor sources, group them into candidate
# ZONES by directory, and delegate the ONE semantic step — deciding each zone's applicable bug classes
# (subset of the taxonomy's C1..C15) plus a human name/description — to the substrate agent
# auditor/agents/zone-mapper.ag (invoked once per zone with `agentis go`, exactly as run-discovery.sh
# invokes hunter.ag). It emits zones.json (the structured model) and scope.tsv (the pipe-delimited
# manifest that run-discovery.sh --scope already parses byte-for-byte), closing the auto-map -> hunt loop.
#
# The shell does only MECHANICAL plumbing (locate, group, LOC, an advisory hardening_score, big-contract
# function-slicing, formatting); the substrate owns the CLASSIFICATION. Offline/CI determinism comes from
# --fixture, a file of canned `ZONE|id|name|classes|description` lines that stubs the substrate output.
# READ-ONLY: no network, no bounty platform, no submit path anywhere — surfacing a starting manifest is all.
#
# Usage:
#   map-zones.sh --repo <dir> --out <dir> [options]
#
# Options:
#   --repo <dir>        Target repo root (clone with fetch-target.sh). REQUIRED.
#   --out <dir>         Output dir for zones.json + scope.tsv (+ appendix.tsv, see below). REQUIRED.
#   --scope-hint <files>  Comma/space list of files or dir-prefixes to restrict the source set (e.g. the
#                       run-immunefi-intake.sh scope_hint). Optional; default = every source under --repo.
#   --since <commit-ish>  Audit-covered ref; feeds audit-delta.sh so post-audit-churned zones score LESS
#                       hardened. Optional; the hardening_score is ADVISORY, never a gate.
#   --fixture <file>    Canned `ZONE|id|name|classes|description` classification (the offline/CI stub). When
#                       present the substrate step is skipped entirely (deterministic, no LLM).
#   --backend <mock|flat-cyborg|claude>  LLM backend for the live substrate step (default: flat-cyborg).
#   --agentis <bin>     agentis binary (default: `agentis` on PATH).
#   -h, --help          This help.
#
# #1865 appendix.tsv: the SIDECAR naming, per subsystem, the ONE #1861 appendix token this run attached and
# the abstract base it implements (`<subsystem>\t<token>\t<base>`, TAB-delimited). It is written ONLY when
# some zone actually attached a token, so a target with no cross-zone abstract base emits the same file set
# as before. run-discovery.sh --appendix reads it to FRAME that payload section for the hunter; without it
# the token is byte-indistinguishable from any other function slice.
#
# Classification resolution order: --fixture -> `agentis go zone-mapper.ag` per zone (when agentis is
# present) -> `[SKIP] semantic classification unavailable` (stderr) + exit 0 emitting the mechanical
# zones.json skeleton only (no scope.tsv, no partial garbage).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# #1707: shared reply-shape validation + retry for the zone-mapper substrate call (see the helper header).
# shellcheck source=lib/run-agent-validated.sh
# shellcheck disable=SC1091
. "$HERE/lib/run-agent-validated.sh"
DF_AGENT_MAX_ATTEMPTS="$(df_max_attempts)"
# agentis-core#993: pre-accept Claude Code's workspace-trust dialog for the RUN dir
# (below), so the flat-cyborg/claude backend session does not block + exit 75.
# shellcheck source=lib/ensure-claude-trust.sh
# shellcheck disable=SC1091
. "$HERE/lib/ensure-claude-trust.sh"
AGENTIS="agentis"
REPO="" ; OUT="" ; SCOPE_HINT="" ; SINCE="" ; FIXTURE="" ; BACKEND="flat-cyborg"
# A contract above this many lines is emitted function-sliced (`file@fn1+fn2`, slice-fns.sh format) in
# scope.tsv so a deep per-cell read fits the hunter's per-call budget (mirrors run-discovery.sh's guidance).
LOC_SLICE_THRESHOLD=120
# #1957 (Lever 2 of the #1955 dense-zone timeout work): a directory zone whose AGGREGATE in-scope LOC exceeds
# this cap is split into deterministic sub-zones each under it, so each sub-zone's #1955 per-cell hunt timeout
# lands in the LINEAR region of run-discovery.sh's weight-scaled budget instead of saturating (and relying on)
# its 1800000 ms ceiling. Default 1600 = the LOC at which that budget hits the cap: run-discovery.sh uses
# FLOOR=600000 + STEP_MS=300000 per STEP_LOC=400 LOC, CAP=1800000, so saturation LOC = 400 * (1800000-600000)
# / 300000 = 1600. These are two INDEPENDENTLY-MAINTAINED values that can drift; if you change run-discovery.sh's
# HUNT_TIMEOUT_* constants, recompute this default (same keep-in-sync convention as VALUE_MOVING_KEYWORDS /
# zone-mapper.ag). Below the cap the split is a NO-OP: an un-split zone's zones.json/scope.tsv output is
# byte-identical to before this issue. Operator override via the ZONE_SPLIT_LOC env — a shell-level read here,
# NOT an `.ag` getenv(), so it needs no exec.env_passthrough entry (same style as HUNT_FITNESS_JSON below); set
# 0 to disable splitting entirely.
ZONE_SPLIT_LOC="${ZONE_SPLIT_LOC:-1600}"

need() { [ "$1" -ge 2 ] || { echo "map-zones.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "$#"; REPO="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --scope-hint) need "$#"; SCOPE_HINT="$2"; shift 2 ;;
    --since) need "$#"; SINCE="$2"; shift 2 ;;
    --fixture) need "$#"; FIXTURE="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "map-zones.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "map-zones.sh: --repo <target repo dir> required" >&2; exit 2; }
[ -n "$OUT" ] || { echo "map-zones.sh: --out <output dir> required" >&2; exit 2; }
[ -z "$FIXTURE" ] || [ -f "$FIXTURE" ] || { echo "map-zones.sh: --fixture not found: $FIXTURE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

REPO="$(cd "$REPO" && pwd)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
TAXONOMY="$HERE/auditor/bug-taxonomy.md"

# --- locate in-scope Solidity/Anchor sources (relative to --repo) -------------------------------------
# PRUNE vendored dependencies and build artifacts. A Foundry/Hardhat target's OWN auditable code lives in
# src/ or contracts/; lib/ (Foundry submodules), node_modules/ (npm), out/ + cache/ + artifacts/ (build
# output), and .git/ are third-party or generated, never the target's own zones — grouping openzeppelin or
# forge-std into "zones" is both wrong (you audit the target, not its deps) and, on a big dep tree (e.g. a
# yearn strategy vendors ~5.5k .sol under lib/), it overflows the mechanical pass's single SOURCES env
# string past MAX_ARG_STRLEN (~128 KB) -> `Argument list too long`. NOTE: `--scope-hint` below only ever
# NARROWS this already-pruned SOURCES list (it intersects, it cannot resurrect a file whose directory was
# pruned here) — if a target genuinely keeps its own in-scope code under one of these names, edit the
# `-name` list in this `find` instead.
SOURCES="$(cd "$REPO" && find . \
  \( -type d \( -name lib -o -name node_modules -o -name out -o -name cache -o -name artifacts -o -name .git \) -prune \) -o \
  \( -type f \( -name '*.sol' -o -name '*.rs' \) -print \) 2>/dev/null | sed 's#^\./##' | LC_ALL=C sort || true)"
[ -n "$SOURCES" ] || { echo "map-zones.sh: no Solidity/Anchor sources found under $REPO (own code only; lib/node_modules/out/cache/artifacts/.git are pruned — --scope-hint narrows this list, it cannot restore a pruned path; edit the find's -name list above if this target's own code lives under one of them)" >&2; exit 2; }

# --- advisory hardening input: the post-audit churn signal (never a gate) -----------------------------
# audit-delta.sh reports the files that changed SINCE the audit ref; a zone with more churned files is
# LESS battle-tested -> a lower hardening_score. No --since -> empty delta -> hardening from file age only.
DELTA_JSON=""
if [ -n "$SINCE" ]; then
  DELTA_JSON="$("$HERE/audit-delta.sh" --repo "$REPO" --since "$SINCE" 2>/dev/null || true)"
fi

# --- mechanical pass: group by directory, LOC, hardening_score, slice tokens (python3, per convention) --
MECH_JSON="$OUT/.zones-mechanical.json"
ZONE_LIST="$(REPO_ABS="$REPO" SOURCES="$SOURCES" SCOPE_HINT="$SCOPE_HINT" DELTA_JSON="$DELTA_JSON" \
  LOC_SLICE_THRESHOLD="$LOC_SLICE_THRESHOLD" ZONE_SPLIT_LOC="$ZONE_SPLIT_LOC" MECH_JSON="$MECH_JSON" python3 - <<'PY'
import os, re, json, time, subprocess, sys
from collections import OrderedDict

repo = os.environ["REPO_ABS"]
sources = [l for l in os.environ.get("SOURCES", "").splitlines() if l.strip()]
hint_raw = os.environ.get("SCOPE_HINT", "").strip()
delta_json = os.environ.get("DELTA_JSON", "").strip()
thr = int(os.environ.get("LOC_SLICE_THRESHOLD", "120"))
# #1957: aggregate-LOC split cap (default 1600, 0 disables). A malformed override degrades to the default
# rather than crashing the whole map.
try:
    split_cap = int(os.environ.get("ZONE_SPLIT_LOC", "1600"))
except ValueError:
    split_cap = 1600
mech_json = os.environ["MECH_JSON"]

# --scope-hint intersection: keep a source that equals a hint or sits under one as a directory prefix
# (the audit-delta.sh --paths convention — a plain list, no glob engine).
if hint_raw:
    hints = [h.rstrip("/") for h in re.split(r"[,\s]+", hint_raw) if h.strip()]
    sources = [f for f in sources if any(f == h or f.startswith(h + "/") for h in hints)]

# post-audit churn set (advisory hardening input)
churn = set()
if delta_json:
    try:
        churn = set(json.loads(delta_json).get("changed_files", []))
    except Exception:
        churn = set()

# #1824: drop directory/suffix conventions that can never hold a real bug (test/tests/interfaces/mocks/
# script + the .t.sol suffix) from `sources` BEFORE grouping, so an excluded file never forms a zone at
# all -- it disappears from BOTH zones.json and scope.tsv. There is no timeout anywhere in this pipeline
# (run-zone-hunt.sh's zone loop is an unbounded serial `for`); the cost this removes is wasted hunter
# effort classifying and hunting zones that cannot contain a real bug, not a consumed budget.
#
# PATH-based, NOT value_custody-based -- do NOT fold this into a custody check. `libraries/`, `types/`,
# and every other directory name are left completely untouched and MUST keep flowing into zones (e.g.
# yieldoor's rare M-2 finding, ReserveLogic._updateIndexes, lives under a `libraries/` dir).
#
# Segment-anchored (never a bare substring): each prefix only matches a LEADING `<prefix>/` segment or a
# mid-path `/<prefix>/` segment, so a real dir named `scripts_core/` or a file `src/testing_utils.sol` is
# not swept up by an over-broad match.
#
# This mirrors -- but is a SEPARATE, independently-maintained copy of -- zone-mapper.ag's #1717
# is_test_or_interface_path() (auditor/agents/zone-mapper.ag:260-269), which only recognizes
# test/tests/interfaces/.t.sol; this list is extended with mocks/ and script/, which #1717 does NOT
# cover. Two independently-maintained lists can drift; if you touch one, check the other (same
# convention already used for VALUE_MOVING_KEYWORDS above).
EXCLUDED_ZONE_PREFIXES = ("test/", "tests/", "interfaces/", "mocks/", "script/")


def is_excluded_zone_path(f):
    for p in EXCLUDED_ZONE_PREFIXES:
        if f.startswith(p) or ("/" + p) in f:
            return True
    return f.endswith(".t.sol")


# Escape hatch = the existing --scope-hint flag, not a new flag: when the operator passed --scope-hint,
# `sources` above is already intersected down to their explicit list -- trust that narrowing and skip
# this filter, so an operator who knows their target can force an atypically-named real dir (e.g. a
# `mocks/` dir that is actually a compatibility shim) back in by hinting it, with zero new CLI surface.
if not hint_raw:
    sources = [f for f in sources if not is_excluded_zone_path(f)]

# group by immediate directory
groups = OrderedDict()
for f in sorted(sources):
    d = os.path.dirname(f) or "."
    groups.setdefault(d, []).append(f)

def slug(s):
    return re.sub(r"[^A-Za-z0-9]+", "_", s).strip("_") or "root"

def loc(f):
    try:
        with open(os.path.join(repo, f), encoding="utf-8", errors="ignore") as fh:
            return sum(1 for _ in fh)
    except Exception:
        return 0

def fn_names(f):
    names = []
    try:
        with open(os.path.join(repo, f), encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                # #1834: anchored on a line that (after only leading whitespace) STARTS with the `function` keyword
                # immediately followed by `(` -- a real declaration, not the English word "function" appearing anywhere
                # in NatSpec prose or a `//` comment describing one (the old `\bfunction\s+NAME` scraped the WORD
                # FOLLOWING "function" off those as a phantom name, e.g. "This function is called..." -> "is"). NOTE:
                # this is a per-LINE scraper with no comment-state tracking, so a declaration living inside a
                # `/* ... */` block comment still matches -- an accepted, documented residual (see
                # fixtures/zone-map/contracts/registry/Registry.sol), not something this fix claims to close.
                m = re.search(r"^\s*function\s+([A-Za-z0-9_]+)\s*\(", line)
                if m and m.group(1) not in names:
                    names.append(m.group(1))
    except Exception:
        pass
    return names

# #2108(a): a mechanical "is there deployable logic in this zone?" signal, written per-zone into zones.json
# so the dashboard's planned deep-hunt matrix (hunt-dashboard.py::planned_deep_rows) can DROP a zone that is
# all interface/events/abstract-signature -- nothing a stateful-invariant fuzzer can deploy or call -- instead
# of rendering it as a permanent  queued DEPTH row that never clears. STOP-1 decision: scan .sol files ONLY
# (a zone with no .sol file stays UNKNOWN -> huntable), strip comments first, and treat a file as having an
# implementation iff a function/constructor/receive/fallback/modifier declaration TERMINATES in a body `{`
# (not a `;`-terminated interface/abstract signature). Conservative by construction: any body => huntable, so a
# regex miss keeps a zone VISIBLE and never hides a real coverage gap.
_IMPL_BODY_RE = re.compile(
    r"\b(?:function\s+\w+|constructor|receive|fallback|modifier\s+\w+)\b[^;{}]*\{",
    re.DOTALL,
)

def _strip_sol_comments(txt):
    # Naive, conservative strip: block comments first (DOTALL), then line comments. Does NOT model a string
    # literal that contains `//` or `/* */` -- an accepted residual (this is a huntability heuristic, not a
    # parser), and it can only ever ADD a body match back, i.e. keep a zone visible.
    txt = re.sub(r"/\*.*?\*/", "", txt, flags=re.DOTALL)
    txt = re.sub(r"//[^\n]*", "", txt)
    return txt

def has_implementation(f):
    try:
        with open(os.path.join(repo, f), encoding="utf-8", errors="ignore") as fh:
            txt = fh.read()
    except Exception:
        return False
    return bool(_IMPL_BODY_RE.search(_strip_sol_comments(txt)))

# Value-moving / recovery vocabulary (#1701): a large contract's first 8 DECLARED function names are
# frequently all admin/init setters (e.g. dodo's Gateway* files), so truncating fn_names() by pure
# declaration order starves the per-zone classification prompt of every function that actually moves
# value or recovers from a failed cross-chain call — the ones a hunt most needs to see. This vocabulary
# intentionally mirrors auditor/agents/zone-mapper.ag's #1698 C6 (has_value_moving_function, lines ~102-107)
# and C17 (has_revert_handler, lines ~143-147) backstop nets, plus a few extra terms (`transfer`, `onCall`,
# `claim`, `liquidate`) needed to also prioritize non-Gateway shapes (e.g. the liquidation-engine fixture
# below). Two independently-maintained lists can drift; if you touch one, check the other.
VALUE_MOVING_KEYWORDS = re.compile(
    r"(withdraw|deposit|mint|burn|redeem|swap|transfer|onrevert|onabort|oncall|cancel|refund|claim|liquidate)",
    re.IGNORECASE,
)

# Value-READING / valuation vocabulary (#1799): the share/asset conversion + pricing path where an entire
# rare-bug family lives (ERC4626 convertToAssets/convertToShares/preview*/totalAssets, oracle price/getValue/
# exchangeRate, pricePerShare, quote). These are DISTINCT from the value-MOVING verbs above — a vault's many
# deposit/withdraw/redeem functions routinely fill the whole [:cap] slice by themselves and truncate out its
# convert/price functions (measured live: notional's AbstractSingleSidedLP had 11 value-moving matches, so its
# convertToAssets — the fb=2 H-4 mispricing surface — never reached scope.tsv). prioritize_fn_names() below
# RESERVES a small quota for this class so the read/pricing path is always represented, not just the move path.
VALUATION_KEYWORDS = re.compile(
    r"(convert|previewredeem|previewdeposit|previewmint|previewwithdraw|price|totalassets"
    r"|pricepershare|exchangerate|sharestoassets|assetstoshares|getvalue|valueof|quote|spotprice)",
    re.IGNORECASE,
)

# Function-slice cap (#1825): raising this from 8 to 16 is the smallest uniform cap that recovers three
# rare-bug functions the old cap truncated out of scope.tsv on the corpus targets -- yieldoor's
# Strategy.checkPoolActivity (rank 16 of 35 declared names), yieldoor's ReserveLogic._updateIndexes (rank
# 12 of 18), and plaza's Pool.startAuction (rank 13 of 24). FLAT, not adaptive: every percentile-style rule
# measured against both targets either overshoots one or undershoots the other (the rank distribution is
# not a function of declared-name count), and a flat cap costs nothing on a contract with <= FN_SLICE_CAP
# declared names -- it is simply no longer truncated.
#
# ZERO-MARGIN WARNING: at cap 16, Strategy.checkPoolActivity lands at EXACTLY rank 16 of 16 -- it falls in
# the `rest` partition below (neither `moving` nor `valuation` has claim on it), so nothing protects its
# slot. Any future addition to VALUE_MOVING_KEYWORDS or VALUATION_KEYWORDS promotes other names ahead of it
# in the slice and can push it back out past the cap. If you extend either keyword list and this margin
# breaks, raise FN_SLICE_CAP in that same PR -- do not pre-inflate it now on speculation.
FN_SLICE_CAP = 16

def prioritize_fn_names(names, cap):
    # Reorder (never drop/rename) `names` — already in file-declaration order, deduplicated — so the
    # functions a hunt most needs to see survive an [:cap] slice ahead of admin/setter noise. Partition into
    # three families, each keeping declaration order and ranking public (no leading `_`, attacker-reachable)
    # ahead of leading-`_` internal names:
    #   moving    — VALUE_MOVING_KEYWORDS: token movement / cross-chain recovery (#1701).
    #   valuation — VALUATION_KEYWORDS and NOT value-moving: the share/asset conversion + pricing path (#1799).
    #   rest      — everything else.
    # Then reserve up to cap//3 slots (>=1 whenever any valuation fn exists) for `valuation`, fill the balance
    # with `moving`, and backfill spare capacity from the leftovers. A contract whose whole function list
    # already fits under `cap` is unaffected (both the reordering and the reservation only bite once
    # truncation actually happens). cap//3 keeps the move path dominant (it is where most exploits act) while
    # guaranteeing the read/pricing path is never fully crowded out.
    def pub_first(xs):
        return [n for n in xs if not n.startswith("_")] + [n for n in xs if n.startswith("_")]
    moving = pub_first([n for n in names if VALUE_MOVING_KEYWORDS.search(n)])
    valuation = pub_first([n for n in names
                           if VALUATION_KEYWORDS.search(n) and not VALUE_MOVING_KEYWORDS.search(n)])
    rest = [n for n in names
            if not VALUE_MOVING_KEYWORDS.search(n) and not VALUATION_KEYWORDS.search(n)]
    reserve = min(len(valuation), max(1, cap // 3)) if valuation else 0
    picked = moving[:cap - reserve] + valuation[:reserve]
    for n in moving[cap - reserve:] + valuation[reserve:] + rest:
        if len(picked) >= cap:
            break
        if n not in picked:
            picked.append(n)
    return picked[:cap]

def age_days(f):
    try:
        out = subprocess.run(["git", "-C", repo, "log", "-1", "--format=%ct", "--", f],
                             capture_output=True, text=True, timeout=15).stdout.strip()
        if out.isdigit():
            return max(0, int((time.time() - int(out)) / 86400))
    except Exception:
        pass
    return None

def build_zone(zid, name, files):
    # Build ONE zone dict (mechanical fields only) from an id/name and a file list. Factored out of the
    # per-group loop so both an un-split directory zone and a #1957 sub-zone are built identically -- an
    # un-split zone's output is therefore byte-identical to before #1957. The key order is pinned so
    # zones.json diffs stay stable.
    zloc = sum(loc(f) for f in files)
    # scope tokens: function-slice a contract above the threshold, else feed the whole file
    scope_tokens = []
    for f in files:
        if loc(f) > thr:
            fns = prioritize_fn_names(fn_names(f), FN_SLICE_CAP)
            scope_tokens.append(f + "@" + "+".join(fns) if fns else f)
        else:
            scope_tokens.append(f)
    n = len(files)
    churn_ratio = (sum(1 for f in files if f in churn) / n) if n else 0.0
    ages = [a for a in (age_days(f) for f in files) if a is not None]
    age = max(0, min(min(ages) if ages else 0, 30))
    # ADVISORY hardening_score in [0,100]: monotone-decreasing in post-audit churn, monotone-increasing in
    # file age. Pinned formula; a hunt NEVER branches on it (a low score is a hint, not a skip).
    hardening = round((1.0 - churn_ratio) * 60 + (age / 30.0) * 40)
    hardening = max(0, min(hardening, 100))
    # #2108(a): huntability signal (see has_implementation above), computed over THIS zone's own files so a
    # #1957 split sub-zone is scored on its own bin. code_files = .sol only (STOP-1); a zone with zero .sol
    # files is UNKNOWN, not empty, so it defaults True (never suppress the unknown).
    code_files = [f for f in files if str(f).endswith(".sol")]
    has_impl = (not code_files) or any(has_implementation(f) for f in code_files)
    return {
        "id": zid, "name": name,
        "files": files, "scope_files": scope_tokens,
        "loc": zloc, "hardening_score": hardening,
        "has_implementation": has_impl,
    }


def split_bins(files, flocs, cap):
    # #1957: deterministic NEXT-FIT bin-packing over the group's already-lexically-sorted files. Walk in
    # order, accumulate LOC into the current bin until adding the next file would exceed `cap`, then open a
    # new bin. A SINGLE file already above the cap cannot be packed smaller -- it starts its own bin and the
    # next file always flushes it, so it ends up alone (its prompt is separately bounded by FN_SLICE_CAP
    # function-slicing). Lexical order keeps related files (Vault.sol + VaultStorage.sol) together, and every
    # file in a group shares one directory so a bin stays subsystem-coherent. NO file is ever dropped.
    bins = []
    cur = []
    cur_loc = 0
    for f in files:
        fl = flocs[f]
        if cur and cur_loc + fl > cap:
            bins.append(cur)
            cur = []
            cur_loc = 0
        cur.append(f)
        cur_loc += fl
    if cur:
        bins.append(cur)
    return bins


zones = []
listing = []
for d, files in groups.items():
    zid = slug(d)
    flocs = {f: loc(f) for f in files}
    zloc = sum(flocs.values())
    if split_cap > 0 and zloc > split_cap:
        # #1957: this directory zone's aggregate prompt would saturate the #1955 timeout budget -> split it
        # into sub-zones, each a first-class zones.json entry carrying `split_of` = the parent zone id so
        # classification/custody inherit and the dashboard can group later (deferred). Log the split (and any
        # single over-cap file) to stderr -- no silent truncation, mirroring the exclusion-logging convention.
        base_name = os.path.basename(d) or zid
        bins = split_bins(files, flocs, split_cap)
        total = len(bins)
        for k, bfiles in enumerate(bins, 1):
            sub_id = "%s__p%d" % (zid, k)
            sub_name = "%s (part %d/%d)" % (base_name, k, total)
            z = build_zone(sub_id, sub_name, bfiles)
            z["split_of"] = zid
            zones.append(z)
            listing.append(sub_id + "\t" + ",".join(z["scope_files"]))
        print("map-zones.sh: zone '%s' (%d LOC) exceeds ZONE_SPLIT_LOC=%d -> split into %d sub-zone(s) "
              "%s; no in-scope file dropped"
              % (zid, zloc, split_cap, total,
                 ",".join("%s__p%d" % (zid, k) for k in range(1, total + 1))), file=sys.stderr)
        for f in files:
            if flocs[f] > split_cap:
                print("map-zones.sh: single file %s (%d LOC) is above ZONE_SPLIT_LOC=%d and cannot be packed "
                      "smaller -> its own sub-zone (FN_SLICE_CAP function-slicing still bounds its per-cell "
                      "prompt)" % (f, flocs[f], split_cap), file=sys.stderr)
    else:
        z = build_zone(zid, os.path.basename(d) or zid, files)
        zones.append(z)
        listing.append(zid + "\t" + ",".join(z["scope_files"]))

with open(mech_json, "w", encoding="utf-8") as fh:
    json.dump(zones, fh)
print("\n".join(listing))
PY
)"

# --- #1861 inheritance appendix: reach the implementation a directory split severed -------------------
# A zone whose file declares an `abstract contract` with body-less `virtual` members, and which holds NO
# implementation of it, is hunted against a base class and none of its behaviour. lib/inheritance.py appends
# ONE function-sliced representative implementor to that zone's scope_files and records the condition in the
# additive `abstract_base` / `implementation_appendix` keys the merge below copies through. Follows the
# DELTA_JSON precedent above for a helper that degrades to a no-op: an absent or failing helper logs one
# stderr line and the run continues with the UNTOUCHED mechanical model (today's behaviour exactly).
# `files`, `loc` and `hardening_score` are never touched, so zone identity — and with it the #1830 coverage
# record, the brief filenames, `--only` and STAGE 4.5 deep-hunt selection — is byte-identical either way.
# NOTE: ZONE_LIST above is deliberately NOT rewritten. It feeds zone-mapper.ag's CLASSIFICATION, which must
# keep judging the zone on its OWN files; the appendix is extra payload for the HUNT, not evidence for the map.
INHERITANCE="$HERE/lib/inheritance.py"
INHERIT_LOG="$OUT/.inheritance.log"
: > "$INHERIT_LOG"
if [ -f "$INHERITANCE" ]; then
  if MECH_APPENDED="$(python3 "$INHERITANCE" appendix --zones "$MECH_JSON" --repo "$REPO" 2>"$INHERIT_LOG")" \
     && [ -n "$MECH_APPENDED" ]; then
    printf '%s' "$MECH_APPENDED" > "$MECH_JSON"
    if [ -s "$INHERIT_LOG" ]; then cat "$INHERIT_LOG" >&2; fi
  else
    echo "map-zones.sh: inheritance appendix helper failed (continuing with the untouched zone model; see $INHERIT_LOG)" >&2
  fi
else
  echo "map-zones.sh: lib/inheritance.py not found (continuing without the inheritance appendix)" >&2
fi

# --- #1914 M2 composition surfaces: route the general-solvency lens onto the real consumer->producer seam ---
# A value_custody zone's SYS-solvency deep-hunt row (run-zone-hunt.sh --composable-lens) targets the largest
# .sol by BOOTSTRAP (M1). lib/composition-surfaces.py replaces that with a static seam scan: when the zone holds
# a contract A that consumes a value another zone contract B produces (an external call return settled through a
# transfer/mint/burn/balance-write, a hook-return delta, or a deposit/withdraw adapter round-trip), it attaches
# an additive `composition_surfaces` record naming A (consumer) + B (producer[s]) that the merge below copies
# through and run-zone-hunt.sh reads to aim the lens. Follows the inheritance-appendix precedent for a degrade-
# to-no-op helper: absent or failing => one stderr line + the UNTOUCHED zone model (M1's bootstrap, exactly).
# Option C: a zone with NO detected seam gains NO key, so a target without a composition seam is byte-identical.
# `files`, `loc`, `hardening_score` and `scope_files` are never touched, so zone identity — and scope.tsv — is
# byte-identical either way.
COMPOSITION="$HERE/lib/composition-surfaces.py"
COMPOSITION_LOG="$OUT/.composition-surfaces.log"
: > "$COMPOSITION_LOG"
if [ -f "$COMPOSITION" ]; then
  if MECH_COMPOSED="$(python3 "$COMPOSITION" annotate --zones "$MECH_JSON" --repo "$REPO" 2>"$COMPOSITION_LOG")" \
     && [ -n "$MECH_COMPOSED" ]; then
    printf '%s' "$MECH_COMPOSED" > "$MECH_JSON"
    if [ -s "$COMPOSITION_LOG" ]; then cat "$COMPOSITION_LOG" >&2; fi
  else
    echo "map-zones.sh: composition-surfaces helper failed (continuing with the untouched zone model; see $COMPOSITION_LOG)" >&2
  fi
else
  echo "map-zones.sh: lib/composition-surfaces.py not found (continuing without composition-surface detection)" >&2
fi

# --- classification: --fixture -> substrate (agentis) -> mechanical skeleton --------------------------
CLASS_LINES="$OUT/.zone-classes.txt"
: > "$CLASS_LINES"
# #1713: value-custody flags scraped from zone-mapper.ag's `CUSTODY|<id>|<true|false>` diagnostic line
# (the severity-first deep-hunt gate). Additive to zones.json only; scope.tsv is untouched. Always
# initialised (empty on the skeleton path) so the merge below reads it unconditionally.
CUSTODY_LINES="$OUT/.custody-flags.txt"
: > "$CUSTODY_LINES"
# #1707: zone ids whose zone-mapper reply never carried a ZONE| sentinel after retries (TUI chrome / no
# answer). A failed zone is flagged classification_failed in zones.json and EXCLUDED from scope.tsv — visibly
# a failure, not the silent empty-classes drop it used to become. Always initialised (empty on non-substrate
# paths) so the merge below can read it unconditionally.
FAILED_ZONES="$OUT/.failed-zones.txt"
: > "$FAILED_ZONES"
FAILED=0
SKELETON=""
SRC_LABEL=""
if [ -n "$FIXTURE" ]; then
  grep -E '^[[:space:]]*ZONE\|' "$FIXTURE" | sed 's/^[[:space:]]*//' > "$CLASS_LINES" || true
  # #1713: an offline fixture DECLARES value-custody zones with `CUSTODY|<id>|<true|false>` lines (the .ag
  # is not run on the fixture path, so the flag rides the fixture like the ZONE| classification does).
  grep -E '^[[:space:]]*CUSTODY\|' "$FIXTURE" | sed 's/^[[:space:]]*//' >> "$CUSTODY_LINES" || true
  SRC_LABEL="fixture"
elif command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ]; then
  # Substrate classification: one zone-mapper.ag run per zone, against a shared agentis store (mirrors
  # run-discovery.sh's hunter fan-out — copy the agent + slicer, init the store, write the config).
  RUN="$OUT/run"; rm -rf "$RUN"; mkdir -p "$RUN"
  cp "$HERE/auditor/agents/zone-mapper.ag" "$RUN/zone-mapper.ag"
  cp "$HERE/auditor/slice-fns.sh" "$RUN/slice-fns.sh"
  ( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 ) || true
  {
    echo "llm.backend = $BACKEND"
    if [ "$BACKEND" = "claude" ]; then
      echo "llm.command = claude"; echo "llm.args = -p"; echo "llm.cli_timeout_ms = 600000"
    elif [ "$BACKEND" = "flat-cyborg" ]; then
      # idle_ms 12000 (> native 4000 default): kept as a latency knob only (#1925) -- do NOT ratchet it
      # further. Completion is gated on the wrapper's closing sentinel from flat-cyborg >= 0.13.0
      # (idle_gate_open()); idle_ms only bounds how fast a marker-less (sentinel-less) reply is accepted
      # once the screen goes quiet, so it no longer risks scraping the pre-answer TUI footer
      # ("high · /effort") as a chrome "reply" and failing zone/cell validation (#1707). If a zone looks
      # flaky, file it against the completion path, not this value.
      echo "llm.cli_timeout_ms = 600000"; echo "llm.flat_cyborg.idle_ms = 12000"; echo "llm.model = opus"
    fi
    echo "trace.level = normal"
    echo "exec.env_passthrough = TARGET_DIR,ZONE_ID,ZONE_FILES,TAXONOMY,SLICER"
    echo "exec.default_timeout_ms = 30000"
    echo "learning.enabled = true"
    echo "experience.enabled = true"
    # #1711: knowledge store must be enabled for zone-mapper.ag's recommend()/query_knowledge("hunt-fitness")
    # to read the bench-fed real-bug fitness (also fixes the latent learning.enabled-without-knowledge.enabled
    # gap). Harmless when no fitness is imported: query_knowledge returns empty -> the reorder is an identity.
    echo "knowledge.enabled = true"
  } > "$RUN/.agentis/config"
  # #1711 LEARN->ACT bridge: if the operator points HUNT_FITNESS_JSON at a bench-to-knowledge.sh output, import
  # it into THIS run's store (which was just wiped + re-init'd above) BEFORE the zone loop, so every zone-mapper
  # run sees the learned real-bug fitness. --replace is mandatory (re-import without it accumulates samples).
  # Unset/unreadable -> skipped -> today's behaviour exactly. Not an exec.env_passthrough entry: this is a
  # shell-level env read here, not an `.ag` getenv().
  if [ -n "${HUNT_FITNESS_JSON:-}" ] && [ -r "${HUNT_FITNESS_JSON:-}" ]; then
    ( cd "$RUN" && "$AGENTIS" knowledge import "$HUNT_FITNESS_JSON" --replace ) \
      || echo "map-zones.sh: hunt-fitness import failed (continuing)" >&2
  fi
  # --grant-pii: TARGET_DIR carries the target's contract source, which routinely embeds hex
  # addresses/hashes that trip the PII heuristic; input is benign public contract text. Without it,
  # prompt() gets blocked, the zone stays unclassified, and the whole DISCOVERY hunt stalls (#1690,
  # mirrors the hunter.ag fix in #1676). Dynamic scope: _mz_attempt reads ZID/ZFILES_NL from the loop.
  # shellcheck disable=SC2317  # invoked by name through df_run_agent_validated
  _mz_attempt() {
    ( cd "$RUN" && env \
        TARGET_DIR="$REPO" \
        ZONE_ID="$ZID" \
        ZONE_FILES="$ZFILES_NL" \
        TAXONOMY="$TAXONOMY" \
        SLICER="$RUN/slice-fns.sh" \
        "$AGENTIS" go zone-mapper.ag --enable-exec --enable-messaging --grant-pii ) > "$1" 2>&1 \
      || echo "map-zones.sh: zone-mapper run failed for zone '$ZID' (see $1)" >&2
  }
  # #993: trust the RUN dir before the first `agentis go` so the interactive
  # flat-cyborg/claude session is not blocked on the workspace-trust dialog (mock
  # never spawns claude, so skip it). Best-effort — never fails the mapping.
  case "$BACKEND" in flat-cyborg|claude) df_ensure_claude_trust "$RUN" ;; esac
  TAB="$(printf '\t')"
  while IFS="$TAB" read -r ZID ZFILES || [ -n "${ZID:-}" ]; do
    [ -n "$ZID" ] || continue
    ZFILES_NL="$(printf '%s' "$ZFILES" | tr ',' '\n')"
    ZLOG="$RUN/zone_${ZID}.log"
    # #1707: validate the zone-mapper reply carries a ZONE| sentinel and RETRY on TUI chrome / no answer,
    # instead of silently leaving the zone unclassified (0 cells -> never hunted, no trace).
    if df_run_agent_validated "$DF_AGENT_MAX_ATTEMPTS" "map-zones.sh: zone '$ZID'" "$ZLOG" zone-mapper "$ZID" _mz_attempt; then
      # Scrape the zone-mapper's ZONE| emission WHITESPACE-TOLERANTLY: the LLM formats its reply
      # non-deterministically and sometimes indents the whole answer (observed live: the core `src` zone's
      # ZONE| line came back indented 2 spaces), so an anchored `^ZONE|` silently misses it -> the zone is
      # left unclassified -> 0 cells -> the zone is NEVER hunted. Match leading whitespace, strip it, and take
      # the LAST emission (the agent reasons first and emits the ZONE| line at the end). The python parser
      # below still drops any placeholder/template echo, so feeding it the real last line is safe.
      grep -E '^[[:space:]]*ZONE\|' "$ZLOG" | sed 's/^[[:space:]]*//' | tail -1 >> "$CLASS_LINES" || true
      # #1713: scrape the value-custody flag off the same trailing-line channel (whitespace-tolerant, LAST
      # emission), exactly like the ZONE| scrape above. A zone whose reply carries no CUSTODY| line stays
      # value_custody=false by the merge's default.
      grep -E '^[[:space:]]*CUSTODY\|' "$ZLOG" | sed 's/^[[:space:]]*//' | tail -1 >> "$CUSTODY_LINES" || true
    else
      printf '%s\n' "$ZID" >> "$FAILED_ZONES"
      FAILED=$((FAILED + 1))
    fi
  done <<EOF
$ZONE_LIST
EOF
  SRC_LABEL="substrate"
else
  SKELETON="1"
  echo "[SKIP] semantic classification unavailable (no --fixture, no agentis) — emitting the mechanical zones.json skeleton only" >&2
fi

# --- merge mechanical model + classification -> zones.json (+ scope.tsv unless skeleton) ---------------
COUNT="$(MECH_JSON="$MECH_JSON" CLASS_LINES="$CLASS_LINES" OUT_DIR="$OUT" SKELETON="$SKELETON" \
  FAILED_ZONES="$FAILED_ZONES" CUSTODY_LINES="$CUSTODY_LINES" python3 - <<'PY'
import os, re, json, sys

mech = json.load(open(os.environ["MECH_JSON"], encoding="utf-8"))
skeleton = os.environ.get("SKELETON", "") == "1"
out_dir = os.environ["OUT_DIR"]

# #1707: zones whose zone-mapper reply never carried a ZONE| sentinel after retries. Such a zone is written
# to zones.json with "classification_failed": true and EXCLUDED from scope.tsv — a visible failure, not the
# silent unclassified-and-dropped zone it used to become.
failed_zones = set()
fz = os.environ.get("FAILED_ZONES", "")
if fz and os.path.exists(fz):
    for line in open(fz, encoding="utf-8"):
        z = line.strip()
        if z:
            failed_zones.add(z)

# is_placeholder_echo: the LLM sometimes answers a fill-in-the-blank prompt by echoing the prompt's OWN
# bracketed template instead of real content (observed live: name="<short subsystem name>",
# classes="<class1,class2,...>", desc="<one-line why these classes apply>"). A real zone name/class-list/
# description never legitimately looks like that, so treat a bracket-wrapped value the same as a failed
# zone-mapper run (dropped from classmap -> unclassified, same downstream handling as any other failure)
# instead of silently propagating a template into zones.json.
def is_placeholder_echo(s):
    t = s.strip()
    return t.startswith("<") and t.endswith(">")

# classification lines: `ZONE|id|name|class-csv|description` (the zone-mapper.ag / --fixture contract).
classmap = {}
cl = os.environ.get("CLASS_LINES", "")
if cl and os.path.exists(cl):
    for line in open(cl, encoding="utf-8", errors="ignore"):
        line = line.rstrip("\n")
        if not line.startswith("ZONE|"):
            continue
        parts = line.split("|")
        if len(parts) >= 5:
            zid, name, classes, desc = parts[1].strip(), parts[2].strip(), parts[3].strip(), parts[4].strip()
            if is_placeholder_echo(name) or is_placeholder_echo(classes) or is_placeholder_echo(desc):
                print("map-zones.sh: zone-mapper returned an unfilled template for zone '%s' (echoed the "
                      "prompt's own placeholder instead of real content) -- treating as unclassified" % zid,
                      file=sys.stderr)
                continue
            classmap[zid] = {"name": name, "classes": classes, "desc": desc}

# #1713: value-custody flags: `CUSTODY|<zid>|<true|false>` (zone-mapper.ag's diagnostic line, or a fixture
# declaration). Parsed into custodymap[zid]; every zone gets value_custody set below (default False when a
# zone has no CUSTODY| line). ADDITIVE to zones.json only — scope.tsv is untouched.
custodymap = {}
cf = os.environ.get("CUSTODY_LINES", "")
if cf and os.path.exists(cf):
    for line in open(cf, encoding="utf-8", errors="ignore"):
        line = line.rstrip("\n")
        if not line.startswith("CUSTODY|"):
            continue
        parts = line.split("|")
        if len(parts) >= 3:
            custodymap[parts[1].strip()] = parts[2].strip().lower() == "true"

# scope.tsv field-safety: no `|`, newline, or backtick may appear inside any pipe-delimited field.
def clean(s):
    return re.sub(r"[|`\r\n]", " ", s).strip()

# #1865: the appendix SIDECAR row for one zone -> (token, base rel path), or None when nothing was attached.
# The fact is only knowable HERE: by the time run-discovery.sh reads scope.tsv the appendix token is
# byte-indistinguishable from any other `path@fn1+fn2` slice (every oversized zone file is written that way),
# so the hunt side cannot re-derive which token is the derived implementor. lib/inheritance.py appends at most
# ONE such token, and `has_implementor_among()` guarantees it is never one of the zone's own files — hence the
# `in the appendix implementors AND not in z["files"]` test picks exactly it. A zone recorded with
# `implementor: null` (option C) attached nothing, so it yields no row: there is no payload section to frame.
def appendix_row(z):
    implementors = {e["implementor"]: e.get("base", "")
                    for e in (z.get("implementation_appendix") or []) if e.get("implementor")}
    if not implementors:
        return None
    own = set(z.get("files") or [])
    for t in (z.get("scope_files") or []):
        f = t.split("@", 1)[0]
        if f in implementors and f not in own:
            return t, implementors[f]
    return None

zones = []
scope_lines = []
appendix_lines = []
for z in mech:
    # #1957: a split sub-zone inherits the PARENT's classification. On the --fixture path the operator
    # declares ONE parent-keyed `ZONE|`/`CUSTODY|` line and every sub-zone falls back to it via `split_of`;
    # on the live substrate path each sub-zone is classified directly (its own smaller-prompt `ZONE|` id) and
    # the fallback is simply never taken. An un-split zone has no `split_of`, so this is a no-op for it.
    c = classmap.get(z["id"]) or classmap.get(z.get("split_of")) or {}
    # #1957: a split sub-zone KEEPS its distinct mechanical `<basename> (part k/N)` name and never adopts the
    # classification name -- run-zone-hunt.sh maps zone -> hunt via `--only "$ZNAME"` and DENIES the per-zone
    # cap (budget_unenforceable) when a name matches several scope.tsv lines, so a parent-inherited (fixture
    # path) or LLM-returned (substrate path) name shared across sub-zones would break cap enforcement. The
    # classification still supplies classes/desc/custody; only the NAME is pinned to stay unique. An un-split
    # zone has no `split_of`, so its name resolution is byte-identical to before #1957.
    name = z["name"] if z.get("split_of") else (c.get("name") or z["name"])
    classes = [x.strip() for x in c.get("classes", "").split(",") if x.strip()]
    desc = c.get("desc", "")
    z_out = {
        "id": z["id"],
        "name": name,
        "files": z["files"],
        "loc": z["loc"],
        "hardening_score": z["hardening_score"],
        "bug_classes_likely": classes,
        "description": desc,
        # #1713: the severity-first deep-hunt gate. run-zone-hunt.sh --deep-hunt runs the stateful-invariant
        # engine only on value_custody zones. Default False for any zone with no CUSTODY| line. #1957: a split
        # sub-zone inherits the parent's flag via `split_of` (fixture path keys the parent; substrate path
        # keys each sub-zone) so a value-custody parent's sub-zones stay deep-hunt-eligible.
        "value_custody": custodymap.get(z["id"], custodymap.get(z.get("split_of"), False)),
        # #2108(a): mechanical huntability, computed per-zone in build_zone over the zone's OWN .sol files
        # (incl. #1957 split sub-zones). hunt-dashboard.py excludes a zone from the planned deep-hunt matrix
        # ONLY on an explicit False, so a legacy zones.json that predates this key renders exactly as today.
        "has_implementation": bool(z.get("has_implementation")),
    }
    # #1861: the inheritance-appendix record, copied through ONLY when lib/inheritance.py actually set it —
    # a target with no cross-zone abstract base emits a byte-identical zones.json. `implementor: null` inside
    # an entry is the option-C fallback: the condition is visible in the artifact even when nothing was
    # attached, so a low confirmation rate on such a zone is attributable rather than read as a hunting miss.
    if z.get("abstract_base"):
        z_out["abstract_base"] = True
        z_out["implementation_appendix"] = z.get("implementation_appendix", [])
    # #1914 M2: the composition-surface record, copied through ONLY when lib/composition-surfaces.py actually
    # detected a consumer->producer seam. A target with no seam emits a byte-identical zones.json (option C).
    # run-zone-hunt.sh --composable-lens reads it to target the CONSUMER and thread the PRODUCER(s) as --aux.
    if z.get("composition_surfaces"):
        z_out["composition_surfaces"] = z["composition_surfaces"]
    # #1957: the sub-zone -> parent link, copied through ADDITIVELY for split sub-zones only. An un-split zone
    # has no `split_of` key, so its zones.json entry is byte-identical to before #1957. Downstream consumers
    # read it generically (dashboard parent-grouping is deferred/out of scope); it exists so the sub-zone
    # carries its parent for that future grouping.
    if z.get("split_of"):
        z_out["split_of"] = z["split_of"]
    if z["id"] in failed_zones:
        z_out["classification_failed"] = True
    zones.append(z_out)
    if not skeleton and classes and z["id"] not in failed_zones:
        subsystem = clean(name)
        cls_csv = ",".join(clean(x) for x in classes)
        files_csv = ",".join(clean(t) for t in z["scope_files"])
        scope_lines.append("%s | %s | %s" % (subsystem, cls_csv, files_csv))
        apx = appendix_row(z)
        if apx is not None:
            appendix_lines.append("%s\t%s\t%s" % (subsystem, clean(apx[0]), clean(apx[1])))

with open(os.path.join(out_dir, "zones.json"), "w", encoding="utf-8") as fh:
    json.dump(zones, fh, indent=2)
    fh.write("\n")

if not skeleton:
    with open(os.path.join(out_dir, "scope.tsv"), "w", encoding="utf-8") as fh:
        fh.write("# auto-generated by map-zones.sh (#1612): <subsystem> | <class-csv> | <file[,file...]>"
                 " — run-discovery.sh --scope reads this verbatim\n")
        for l in scope_lines:
            fh.write(l + "\n")

# #1865: the appendix sidecar, written ONLY when at least one zone actually attached a token — a target with
# no cross-zone abstract base produces a byte-identical output tree (no empty file to diff against), and
# run-zone-hunt.sh's `[ -f ]` probe then passes no --appendix at all. Same skeleton guard as scope.tsv.
if not skeleton and appendix_lines:
    with open(os.path.join(out_dir, "appendix.tsv"), "w", encoding="utf-8") as fh:
        fh.write("# auto-generated by map-zones.sh (#1865): TAB-delimited <subsystem> <appendix token>"
                 " <abstract base> — run-discovery.sh --appendix reads this verbatim\n")
        for l in appendix_lines:
            fh.write(l + "\n")

print(len(zones))
PY
)"

if [ -n "$SKELETON" ]; then
  echo "map-zones.sh: $COUNT zone(s) mapped (skeleton, unclassified) -> $OUT/zones.json" >&2
else
  SUMMARY="map-zones.sh: $COUNT zone(s) -> $OUT/zones.json + $OUT/scope.tsv (classified via $SRC_LABEL); feed scope.tsv to run-discovery.sh --scope"
  # #1707: surface a chrome/no-answer classification failure loudly in the summary, never a silent drop.
  [ "${FAILED:-0}" -gt 0 ] && SUMMARY="$SUMMARY — $FAILED zone(s) FAILED classification (retried ${DF_AGENT_MAX_ATTEMPTS}x, still chrome; NOT hunted)"
  echo "$SUMMARY" >&2
fi
