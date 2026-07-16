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
#   --out <dir>         Output dir for zones.json + scope.tsv. REQUIRED.
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
AGENTIS="agentis"
REPO="" ; OUT="" ; SCOPE_HINT="" ; SINCE="" ; FIXTURE="" ; BACKEND="flat-cyborg"
# A contract above this many lines is emitted function-sliced (`file@fn1+fn2`, slice-fns.sh format) in
# scope.tsv so a deep per-cell read fits the hunter's per-call budget (mirrors run-discovery.sh's guidance).
LOC_SLICE_THRESHOLD=120

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
  LOC_SLICE_THRESHOLD="$LOC_SLICE_THRESHOLD" MECH_JSON="$MECH_JSON" python3 - <<'PY'
import os, re, json, time, subprocess
from collections import OrderedDict

repo = os.environ["REPO_ABS"]
sources = [l for l in os.environ.get("SOURCES", "").splitlines() if l.strip()]
hint_raw = os.environ.get("SCOPE_HINT", "").strip()
delta_json = os.environ.get("DELTA_JSON", "").strip()
thr = int(os.environ.get("LOC_SLICE_THRESHOLD", "120"))
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
                m = re.search(r"\bfunction\s+([A-Za-z0-9_]+)", line)
                if m and m.group(1) not in names:
                    names.append(m.group(1))
    except Exception:
        pass
    return names

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

def prioritize_fn_names(names, cap):
    # Reorder (never drop/rename) `names` — already in file-declaration order, deduplicated — so a
    # value-moving/recovery name survives an [:cap] slice ahead of admin/setter noise. Partition into
    # (a) keyword match, no leading `_` (Solidity's internal/private convention -> not directly
    # attacker-reachable, so ranked below public matches), (b) keyword match, leading `_`, (c) everything
    # else -- each partition keeping its original declaration order -- then take the first `cap` names of
    # (a + b + c). A small/simple contract whose whole function list already fits under `cap` is unaffected
    # (the reordering only matters once truncation actually happens).
    matched_public = [n for n in names if VALUE_MOVING_KEYWORDS.search(n) and not n.startswith("_")]
    matched_private = [n for n in names if VALUE_MOVING_KEYWORDS.search(n) and n.startswith("_")]
    rest = [n for n in names if not VALUE_MOVING_KEYWORDS.search(n)]
    return (matched_public + matched_private + rest)[:cap]

def age_days(f):
    try:
        out = subprocess.run(["git", "-C", repo, "log", "-1", "--format=%ct", "--", f],
                             capture_output=True, text=True, timeout=15).stdout.strip()
        if out.isdigit():
            return max(0, int((time.time() - int(out)) / 86400))
    except Exception:
        pass
    return None

zones = []
listing = []
for d, files in groups.items():
    zid = slug(d)
    zloc = sum(loc(f) for f in files)
    # scope tokens: function-slice a contract above the threshold, else feed the whole file
    scope_tokens = []
    for f in files:
        if loc(f) > thr:
            fns = prioritize_fn_names(fn_names(f), 8)
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
    zones.append({
        "id": zid, "name": os.path.basename(d) or zid,
        "files": files, "scope_files": scope_tokens,
        "loc": zloc, "hardening_score": hardening,
    })
    listing.append(zid + "\t" + ",".join(scope_tokens))

with open(mech_json, "w", encoding="utf-8") as fh:
    json.dump(zones, fh)
print("\n".join(listing))
PY
)"

# --- classification: --fixture -> substrate (agentis) -> mechanical skeleton --------------------------
CLASS_LINES="$OUT/.zone-classes.txt"
: > "$CLASS_LINES"
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
      # idle_ms above the native backend's 4000 default: with 4000, flat-cyborg declares IDLE after
      # only 4s of screen silence, which fires DURING claude's think-pause on a large (taxonomy-sized)
      # prompt and scrapes the pre-answer TUI footer ("high · /effort") as a chrome "reply" — the whole
      # zone/cell then fails validation (#1707). A/B-proven: idle 4000 -> chrome, idle >=8000 -> real
      # ZONE| line (same model, same prompt). 12000 matches flat-cyborg's "agentic runs need 12000+".
      echo "llm.cli_timeout_ms = 600000"; echo "llm.flat_cyborg.idle_ms = 12000"
    fi
    echo "trace.level = normal"
    echo "exec.env_passthrough = TARGET_DIR,ZONE_ID,ZONE_FILES,TAXONOMY,SLICER"
    echo "exec.default_timeout_ms = 30000"
    echo "learning.enabled = true"
    echo "experience.enabled = true"
  } > "$RUN/.agentis/config"
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
  FAILED_ZONES="$FAILED_ZONES" python3 - <<'PY'
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

# scope.tsv field-safety: no `|`, newline, or backtick may appear inside any pipe-delimited field.
def clean(s):
    return re.sub(r"[|`\r\n]", " ", s).strip()

zones = []
scope_lines = []
for z in mech:
    c = classmap.get(z["id"], {})
    name = c.get("name") or z["name"]
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
    }
    if z["id"] in failed_zones:
        z_out["classification_failed"] = True
    zones.append(z_out)
    if not skeleton and classes and z["id"] not in failed_zones:
        subsystem = clean(name)
        cls_csv = ",".join(clean(x) for x in classes)
        files_csv = ",".join(clean(t) for t in z["scope_files"])
        scope_lines.append("%s | %s | %s" % (subsystem, cls_csv, files_csv))

with open(os.path.join(out_dir, "zones.json"), "w", encoding="utf-8") as fh:
    json.dump(zones, fh, indent=2)
    fh.write("\n")

if not skeleton:
    with open(os.path.join(out_dir, "scope.tsv"), "w", encoding="utf-8") as fh:
        fh.write("# auto-generated by map-zones.sh (#1612): <subsystem> | <class-csv> | <file[,file...]>"
                 " — run-discovery.sh --scope reads this verbatim\n")
        for l in scope_lines:
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
