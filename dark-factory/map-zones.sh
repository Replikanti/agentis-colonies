#!/usr/bin/env bash
# map-zones.sh — #1612 (milestone M1 of epic #1611: zone-mapping). Auto-derive a target's DISCOVERY
# manifest from the code itself: locate in-scope Solidity/Anchor sources, group them into candidate
# ZONES by directory, and delegate the ONE semantic step — deciding each zone's applicable bug classes
# (subset of the taxonomy's C1..C14) plus a human name/description — to the substrate agent
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
SOURCES="$(cd "$REPO" && find . -type f \( -name '*.sol' -o -name '*.rs' \) 2>/dev/null | sed 's#^\./##' | LC_ALL=C sort || true)"
[ -n "$SOURCES" ] || { echo "map-zones.sh: no Solidity/Anchor sources found under $REPO" >&2; exit 2; }

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
            fns = fn_names(f)[:8]
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
SKELETON=""
SRC_LABEL=""
if [ -n "$FIXTURE" ]; then
  grep '^ZONE|' "$FIXTURE" > "$CLASS_LINES" || true
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
      echo "llm.cli_timeout_ms = 600000"
    fi
    echo "trace.level = normal"
    echo "exec.env_passthrough = TARGET_DIR,ZONE_ID,ZONE_FILES,TAXONOMY,SLICER"
    echo "exec.default_timeout_ms = 30000"
    echo "learning.enabled = true"
    echo "experience.enabled = true"
  } > "$RUN/.agentis/config"
  TAB="$(printf '\t')"
  while IFS="$TAB" read -r ZID ZFILES || [ -n "${ZID:-}" ]; do
    [ -n "$ZID" ] || continue
    ZFILES_NL="$(printf '%s' "$ZFILES" | tr ',' '\n')"
    ( cd "$RUN" && env \
        TARGET_DIR="$REPO" \
        ZONE_ID="$ZID" \
        ZONE_FILES="$ZFILES_NL" \
        TAXONOMY="$TAXONOMY" \
        SLICER="$RUN/slice-fns.sh" \
        "$AGENTIS" go zone-mapper.ag --enable-exec --enable-messaging ) > "$RUN/zone_${ZID}.log" 2>&1 \
      || echo "map-zones.sh: zone-mapper run failed for zone '$ZID' (see $RUN/zone_${ZID}.log)" >&2
    grep '^ZONE|' "$RUN/zone_${ZID}.log" | head -1 >> "$CLASS_LINES" || true
  done <<EOF
$ZONE_LIST
EOF
  SRC_LABEL="substrate"
else
  SKELETON="1"
  echo "[SKIP] semantic classification unavailable (no --fixture, no agentis) — emitting the mechanical zones.json skeleton only" >&2
fi

# --- merge mechanical model + classification -> zones.json (+ scope.tsv unless skeleton) ---------------
COUNT="$(MECH_JSON="$MECH_JSON" CLASS_LINES="$CLASS_LINES" OUT_DIR="$OUT" SKELETON="$SKELETON" python3 - <<'PY'
import os, re, json

mech = json.load(open(os.environ["MECH_JSON"], encoding="utf-8"))
skeleton = os.environ.get("SKELETON", "") == "1"
out_dir = os.environ["OUT_DIR"]

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
            classmap[parts[1].strip()] = {
                "name": parts[2].strip(),
                "classes": parts[3].strip(),
                "desc": parts[4].strip(),
            }

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
    zones.append({
        "id": z["id"],
        "name": name,
        "files": z["files"],
        "loc": z["loc"],
        "hardening_score": z["hardening_score"],
        "bug_classes_likely": classes,
        "description": desc,
    })
    if not skeleton and classes:
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
  echo "map-zones.sh: $COUNT zone(s) -> $OUT/zones.json + $OUT/scope.tsv (classified via $SRC_LABEL); feed scope.tsv to run-discovery.sh --scope" >&2
fi
