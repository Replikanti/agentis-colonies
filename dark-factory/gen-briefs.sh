#!/usr/bin/env bash
# gen-briefs.sh — #1619 (milestone M2 of epic #1611: brief-generation). Turn M1's zones.json + scope.tsv into
# a per-zone HUNT BRIEF that primes the discovery hunt. For EACH zone it emits `briefs/brief_<zone_id>.md`, a
# plain-text markdown brief in the EXACT format hunter.ag consumes via SCOPE_BRIEF (run-discovery.sh --brief):
# a header + the zone's bug-class list, the DEPTH body (per-class invariants-to-break + folded audit residual
# + prior-pattern hints), the in/out-of-scope boundaries, and the honesty mandate. It is the epic's DEPTH lever.
#
# The shell does only MECHANICAL plumbing (read zones.json/scope.tsv, gather the code refs, match the audit
# residual, assemble the deterministic scaffold around the body, write the files); the ONE semantic step — the
# DEPTH body — is authored by the substrate agent auditor/agents/brief-writer.ag, invoked once per zone with
# `agentis go`, exactly as run-discovery.sh invokes hunter.ag and map-zones.sh invokes zone-mapper.ag. Offline/
# CI determinism comes from --fixture, a file of canned BRIEF-BEGIN|..|BRIEF-END bodies that stubs the substrate.
# READ-ONLY: no network, no bounty platform, no submit path — priming the hunt is the whole job.
#
# Usage:
#   gen-briefs.sh --zones <zones.json> --scope <scope.tsv> --out <dir> [options]
#
# Options:
#   --zones <file>      M1 map-zones.sh zones.json (the structured zone model). REQUIRED.
#   --scope <file>      M1 map-zones.sh scope.tsv (the pipe-delimited manifest; supplies the sliced file tokens
#                       + the per-subsystem class list). REQUIRED.
#   --out <dir>         Output dir; briefs land in <dir>/briefs/. REQUIRED.
#   --repo <dir>        Cloned target repo root — the code payload the substrate reasons over (TARGET_DIR).
#                       Optional; only the live/mock substrate path reads code. --fixture needs no repo.
#   --audit-residuals <file>  audit-scout.ag output (BOUNDARY|<known> + RESIDUAL|<subsystem>|<class>|<why>|
#                       <sketch> lines). Optional; per zone, matched RESIDUAL leads are folded into the body and
#                       the BOUNDARY set seeds the out-of-scope section. Absent -> no residual folding (briefs
#                       still emit; residual folding is an OPTIONAL enrichment).
#   --fixture <file>    Canned BRIEF-BEGIN|<zone_id>..BRIEF-END bodies (the offline/CI stub). When present the
#                       substrate step is skipped entirely (deterministic, no LLM).
#   --backend <mock|flat-cyborg|claude>  LLM backend for the live substrate step (default: flat-cyborg).
#   --agentis <bin>     agentis binary (default: `agentis` on PATH).
#   -h, --help          This help.
#
# Body-source resolution order: --fixture -> `agentis go brief-writer.ag` per zone (when agentis is present) ->
# a mechanical fallback body (the zone's class titles only) with `[SKIP] substrate unavailable — emitting
# mechanical briefs only` on stderr. `[SKIP] <reason>` + exit 0 (no partial garbage) when zones.json is missing,
# the model has zero zones, or python3 is absent.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# #1707: shared reply-shape validation + retry for the brief-writer substrate call (see the helper header).
# shellcheck source=lib/run-agent-validated.sh
# shellcheck disable=SC1091
. "$HERE/lib/run-agent-validated.sh"
DF_AGENT_MAX_ATTEMPTS="$(df_max_attempts)"
AGENTIS="agentis"
ZONES="" ; SCOPE="" ; OUT="" ; REPO="" ; RESIDUALS="" ; FIXTURE="" ; BACKEND="flat-cyborg"

need() { [ "$1" -ge 2 ] || { echo "gen-briefs.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --zones) need "$#"; ZONES="$2"; shift 2 ;;
    --scope) need "$#"; SCOPE="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --repo) need "$#"; REPO="$2"; shift 2 ;;
    --audit-residuals) need "$#"; RESIDUALS="$2"; shift 2 ;;
    --fixture) need "$#"; FIXTURE="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "gen-briefs.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$SCOPE" ] && [ -f "$SCOPE" ] || { echo "gen-briefs.sh: --scope <scope.tsv> required" >&2; exit 2; }
[ -n "$OUT" ] || { echo "gen-briefs.sh: --out <output dir> required" >&2; exit 2; }
[ -z "$FIXTURE" ]   || [ -f "$FIXTURE" ]   || { echo "gen-briefs.sh: --fixture not found: $FIXTURE" >&2; exit 2; }
[ -z "$RESIDUALS" ] || [ -f "$RESIDUALS" ] || { echo "gen-briefs.sh: --audit-residuals not found: $RESIDUALS" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -n "$ZONES" ] && [ -f "$ZONES" ] || { echo "[SKIP] gen-briefs.sh: --zones <zones.json> not found (run map-zones.sh first)" >&2; exit 0; }
[ -z "$REPO" ] || REPO="$(cd "$REPO" && pwd)"

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
BRIEFS="$OUT/briefs"; mkdir -p "$BRIEFS"
TAXONOMY="$HERE/auditor/bug-taxonomy.md"
WORK="$OUT/.gen-briefs"; rm -rf "$WORK"; mkdir -p "$WORK/bodies" "$WORK/res"

# --- prepass (python3): join zones.json + scope.tsv, match the audit residual per zone, and emit the per-zone
#     work model. Writes res/<id>.residual (matched RESIDUAL lines) + res/boundary.txt (the global BOUNDARY set)
#     for the substrate env, and prints one `id \t name \t classes_csv \t files_csv` line per zone for the loop.
ZONE_LIST="$(ZONES="$ZONES" SCOPE="$SCOPE" TAXO="$TAXONOMY" RESIDUALS="$RESIDUALS" RESDIR="$WORK/res" \
  MODEL="$WORK/model.json" python3 - <<'PY'
import os, re, json

zones = json.load(open(os.environ["ZONES"], encoding="utf-8"))
if not isinstance(zones, list):
    zones = []

# scope.tsv: subsystem | class-csv | file-token-csv (the sliced tokens the hunter reads). Key by subsystem name.
scope_by_name = {}
for line in open(os.environ["SCOPE"], encoding="utf-8"):
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    parts = [p.strip() for p in line.split("|")]
    if len(parts) >= 3:
        scope_by_name[parts[0]] = {"classes": parts[1], "files": parts[2]}

# audit-scout output (optional): the global BOUNDARY exclusion set + per-line RESIDUAL leads.
boundary_lines, residual_lines = [], []
rf = os.environ.get("RESIDUALS", "")
if rf and os.path.exists(rf):
    for line in open(rf, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("BOUNDARY|"):
            boundary_lines.append(line)
        elif line.startswith("RESIDUAL|"):
            residual_lines.append(line)

resdir = os.environ["RESDIR"]
with open(os.path.join(resdir, "boundary.txt"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(boundary_lines))

def clean_classes(csv):
    # space-free comma list of class ids (brief-writer.ag splits ZONE_CLASSES on "," with no trim).
    return ",".join(c.strip() for c in csv.split(",") if c.strip())

model, listing = [], []
for z in zones:
    zid = z.get("id", "")
    name = z.get("name", zid)
    if not zid:
        continue
    srow = scope_by_name.get(name)
    classes_csv = clean_classes(srow["classes"]) if srow else clean_classes(",".join(z.get("bug_classes_likely", [])))
    files_csv = srow["files"] if srow else ",".join(z.get("files", []))
    classes = [c for c in classes_csv.split(",") if c]
    # match residual leads to this zone: same bug class OR the residual's subsystem label == the zone name.
    matched = []
    for rl in residual_lines:
        f = rl.split("|")
        if len(f) >= 3 and (f[2].strip() in classes or f[1].strip().lower() == name.lower()):
            matched.append(rl)
    with open(os.path.join(resdir, zid + ".residual"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(matched))
    model.append({"id": zid, "name": name, "classes": classes, "files": files_csv,
                  "residual": matched, "boundary": boundary_lines})
    listing.append(zid + "\t" + name + "\t" + classes_csv + "\t" + files_csv)

with open(os.environ["MODEL"], "w", encoding="utf-8") as fh:
    json.dump(model, fh)
print("\n".join(listing))
PY
)"

if [ -z "$ZONE_LIST" ]; then
  echo "[SKIP] gen-briefs.sh: zones.json holds zero zones — nothing to brief" >&2
  exit 0
fi

# --- body source: --fixture -> substrate (agentis) -> mechanical fallback --------------------------------
# slice_block <src-file> <zone-id> -> the verbatim body BETWEEN the BRIEF-BEGIN|<id> and BRIEF-END sentinels
# (both sentinels excluded — the scaffold owns them). The report-writer.ag / persist_draft awk-slice idiom,
# keyed to this zone id and stopping at its first closing sentinel. Identical extraction over a fixture or a
# live agentis log (the run-gate-agent.sh --classify-log precedent).
slice_block() {
  # WHITESPACE-TOLERANT sentinel match: the LLM formats its reply non-deterministically and sometimes indents
  # the whole answer, so an exact `$0=="...BEGIN|"z` comparison would miss an indented sentinel and the brief
  # would silently fall back to the mechanical stub (same failure mode as map-zones.sh's ZONE| scrape). Compare
  # a whitespace-stripped copy of the line to the sentinel, but PRINT the raw body lines verbatim.
  awk -v z="$2" '
    { s=$0; sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s) }
    s=="DARK-FACTORY:BRIEF-BEGIN|" z {f=1; next}
    s=="DARK-FACTORY:BRIEF-END" && f {f=0; exit}
    f {print}
  ' "$1"
}

# is_placeholder_echo <file> — the LLM sometimes answers the brief-writer prompt by echoing its OWN bracketed
# template instead of a real brief (observed live: a whole body of literally "<the markdown body: ...>"). A
# real brief never legitimately looks like that, so treat it the same as a failed brief-writer run rather than
# accepting a template as a valid, non-empty body.
is_placeholder_echo() {
  body="$(cat "$1" 2>/dev/null)"
  trimmed="$(printf '%s' "$body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$trimmed" in
    '<'*'>') return 0 ;;
    *) return 1 ;;
  esac
}

SRC_LABEL=""
RUN=""
if [ -n "$FIXTURE" ]; then
  SRC_LABEL="fixture"
elif command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ]; then
  # Substrate authoring: one brief-writer.ag run per zone against a shared agentis store (mirrors
  # run-discovery.sh's hunter fan-out / map-zones.sh's zone-mapper fan-out — copy the agent + slicer,
  # init the store, write the config).
  RUN="$WORK/run"; rm -rf "$RUN"; mkdir -p "$RUN"
  cp "$HERE/auditor/agents/brief-writer.ag" "$RUN/brief-writer.ag"
  cp "$HERE/auditor/slice-fns.sh" "$RUN/slice-fns.sh"
  ( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 ) || true
  {
    echo "llm.backend = $BACKEND"
    if [ "$BACKEND" = "claude" ]; then
      echo "llm.command = claude"; echo "llm.args = -p"; echo "llm.cli_timeout_ms = 600000"
    elif [ "$BACKEND" = "flat-cyborg" ]; then
      # idle_ms above the native backend's 4000 default: with 4000, flat-cyborg declares IDLE after
      # only 4s of screen silence, which fires DURING claude's think-pause on a large prompt and scrapes
      # the pre-answer TUI footer as a chrome "reply" (#1707). A/B-proven: idle 4000 -> chrome, idle
      # >=8000 -> real reply. 12000 matches flat-cyborg's "agentic runs need 12000+".
      echo "llm.cli_timeout_ms = 600000"; echo "llm.flat_cyborg.idle_ms = 12000"; echo "llm.model = opus"
    fi
    echo "trace.level = normal"
    echo "exec.env_passthrough = TARGET_DIR,ZONE_ID,ZONE_NAME,ZONE_FILES,ZONE_CLASSES,TAXONOMY,AUDIT_RESIDUAL,AUDIT_BOUNDARY,SLICER"
    echo "exec.default_timeout_ms = 30000"
    # Experience is ENABLED because `learn()` is a WRITE this flag GATES (#1878, measured on agentis v1.28.0):
    # brief-writer.ag ends every zone with learn("brief", ...), and with `experience.enabled = false` agentis
    # raises `runtime error: experience not enabled` on that call — and a runtime error DISCARDS the cell's
    # whole accumulated stdout, so the `DARK-FACTORY:BRIEF-BEGIN|<zone>` block this script scrapes never
    # appears; every zone then looks like TUI chrome, burns its retries and falls back to the mechanical body,
    # i.e. the DEPTH lever silently goes to zero (#1877's shape). This block previously carried NO comment,
    # which is exactly how #1877 re-derived the wrong "structurally inert" conclusion. `learning.enabled` gates
    # recommend()/adapt()/score_options() only — nothing on this path calls them — and is kept paired so a
    # future adaptive call cannot make `agentis go` refuse to start. Guard: demo-experience-flags.sh.
    echo "learning.enabled = true"
    echo "experience.enabled = true"
  } > "$RUN/.agentis/config"
  SRC_LABEL="substrate"
else
  SRC_LABEL="mechanical"
  echo "[SKIP] substrate unavailable (no --fixture, no agentis) — emitting mechanical briefs only" >&2
fi

BOUNDARY_TXT="$(cat "$WORK/res/boundary.txt" 2>/dev/null || true)"
# #1707: count of zones whose brief-writer reply never carried a BRIEF-BEGIN|/SKIP sentinel after retries
# (TUI chrome / no answer). Such a zone still falls back to the mechanical brief (a softer stage — a
# mechanical brief keeps the hunt alive) but is now COUNTED + reported, not a silent degrade.
FAILED=0
# --grant-pii: TARGET_DIR + AUDIT_RESIDUAL/AUDIT_BOUNDARY carry contract source and audit-scope text that
# can embed addresses/identifiers tripping the PII heuristic; input is benign public contract/scope text.
# Sibling of map-zones in the same live map->brief->hunt chain (#1690). Dynamic scope: _gb_attempt reads
# ZID/ZNAME/ZFILES_NL/ZCLASSES/RESIDUAL_TXT from the loop below.
# shellcheck disable=SC2317  # invoked by name through df_run_agent_validated
_gb_attempt() {
  ( cd "$RUN" && env \
      TARGET_DIR="$REPO" \
      ZONE_ID="$ZID" \
      ZONE_NAME="$ZNAME" \
      ZONE_FILES="$ZFILES_NL" \
      ZONE_CLASSES="$ZCLASSES" \
      TAXONOMY="$TAXONOMY" \
      AUDIT_RESIDUAL="$RESIDUAL_TXT" \
      AUDIT_BOUNDARY="$BOUNDARY_TXT" \
      SLICER="$RUN/slice-fns.sh" \
      "$AGENTIS" go brief-writer.ag --enable-exec --enable-messaging --grant-pii ) > "$1" 2>&1 \
    || echo "gen-briefs.sh: brief-writer run failed for zone '$ZID' (see $1)" >&2
}
TAB="$(printf '\t')"
while IFS="$TAB" read -r ZID ZNAME ZCLASSES ZFILES || [ -n "${ZID:-}" ]; do
  [ -n "$ZID" ] || continue
  BODY_OUT="$WORK/bodies/$ZID.body"
  RESIDUAL_TXT="$(cat "$WORK/res/$ZID.residual" 2>/dev/null || true)"
  if [ "$SRC_LABEL" = "fixture" ]; then
    slice_block "$FIXTURE" "$ZID" > "$BODY_OUT" || true
  elif [ "$SRC_LABEL" = "substrate" ]; then
    ZFILES_NL="$(printf '%s' "$ZFILES" | tr ',' '\n')"
    LOG="$RUN/brief_${ZID}.log"
    # #1707: validate the brief-writer reply carries a BRIEF-BEGIN|<id> block OR a legit bare SKIP, and
    # RETRY on TUI chrome / no answer. A legit SKIP passes on attempt 1 (no retry) and continues to the
    # existing mechanical/empty-body fallback exactly as before; chrome retries, then on final failure
    # logs loudly + counts the degrade instead of silently falling back.
    df_run_agent_validated "$DF_AGENT_MAX_ATTEMPTS" "gen-briefs.sh: zone '$ZID'" "$LOG" brief-writer "$ZID" _gb_attempt \
      || FAILED=$((FAILED + 1))
    slice_block "$LOG" "$ZID" > "$BODY_OUT" || true
  fi
  if [ -s "$BODY_OUT" ] && is_placeholder_echo "$BODY_OUT"; then
    echo "gen-briefs.sh: brief-writer returned an unfilled template for zone '$ZID' (echoed the prompt's own placeholder instead of a real brief) -- falling back to mechanical brief" >&2
    rm -f "$BODY_OUT"
  fi
  # SRC_LABEL=mechanical (or an empty slice) leaves no body file -> the assembly uses the mechanical fallback.
  [ -s "$BODY_OUT" ] || rm -f "$BODY_OUT"
done <<EOF
$ZONE_LIST
EOF

# --- assembly (python3): wrap each zone's body in the deterministic scaffold + fold the residual + seed the
#     out-of-scope boundary -> briefs/brief_<id>.md, and write briefs/zone_briefs.json (the index). The body is
#     sanitised (no NUL, no bare CANDIDATE|/BLACKBOARD- token, no leaked sentinel) and the whole brief capped at
#     the sed -n '1,2000p' window hunter.ag reads.
COUNT="$(MODEL="$WORK/model.json" TAXO="$TAXONOMY" BODIES="$WORK/bodies" BRIEFS="$BRIEFS" python3 - <<'PY'
import os, re, json

model = json.load(open(os.environ["MODEL"], encoding="utf-8"))
briefs = os.environ["BRIEFS"]

# taxonomy titles: `## Cn — <title>` -> {"Cn": "<title>"} for the class list line + the mechanical fallback.
titles = {}
for line in open(os.environ["TAXO"], encoding="utf-8"):
    m = re.match(r"^##\s+(C\d+)\s+[—-]\s+(.+?)\s*$", line)
    if m:
        titles[m.group(1)] = m.group(2)

def title_of(cls):
    return "%s (%s)" % (cls, titles[cls]) if cls in titles else cls

def sanitize(body):
    # markdown-safe for verbatim injection into hunter.ag's prompt: drop NUL, never let a line masquerade as a
    # hunter output token run-discovery.sh scrapes (CANDIDATE| / BLACKBOARD-), and strip any leaked sentinel.
    body = body.replace("\x00", "")
    out = []
    for l in body.split("\n"):
        if l.startswith("DARK-FACTORY:BRIEF-BEGIN|") or l == "DARK-FACTORY:BRIEF-END":
            continue
        l = re.sub(r"CANDIDATE\|", "CANDIDATE:", l)
        l = l.replace("BLACKBOARD-", "BLACKBOARD ")
        out.append(l)
    return "\n".join(out).strip("\n")

def mechanical_body(classes):
    lines = ["Probe each applicable bug class against this zone's in-scope functions and try to BREAK its core invariant:"]
    for c in classes:
        lines.append("- %s: trace the invariant this class breaks in this zone's functions and the external attack that violates it." % title_of(c))
    lines.append("")
    lines.append("(Mechanical fallback — no substrate body available. Run gen-briefs.sh with a live --backend or --fixture for the depth body.)")
    return "\n".join(lines)

index = {}
count = 0
for z in model:
    zid, name, classes = z["id"], z["name"], z["classes"]
    files = [t for t in z["files"].split(",") if t]
    residual = z.get("residual", [])
    boundary = z.get("boundary", [])

    body_path = os.path.join(os.environ["BODIES"], zid + ".body")
    body = ""
    if os.path.exists(body_path):
        body = sanitize(open(body_path, encoding="utf-8").read())
    if not body.strip():
        body = mechanical_body(classes)

    out = []
    out.append("# %s — hunt brief   (zone: %s)" % (name, zid))
    out.append("In-scope files: %s" % (", ".join(files) if files else "(none listed)"))
    out.append("Bug classes to hunt: %s" % (", ".join(title_of(c) for c in classes) if classes else "(none classified)"))
    out.append("")
    out.append("## Invariants to break / attack surface")
    out.append(body)
    if residual:
        out.append("")
        out.append("### Audit-residual leads (surface prior auditors missed)")
        for rl in residual:
            f = rl.split("|")
            why = f[3].strip() if len(f) > 3 else ""
            sketch = f[4].strip() if len(f) > 4 else ""
            hint = " — ".join(x for x in (why, sketch) if x)
            out.append("- %s" % hint)
    out.append("")
    out.append("## In scope — a valid finding")
    out.append("Only Medium/High severity, exploitable by an external attacker holding NO privileged role. A "
               "trusted role acting WITHIN its documented permissions is OUT OF SCOPE; a role EXCEEDING its "
               "permissions, or any unprivileged user, IS in scope.")
    out.append("")
    out.append("## Out of scope — NEVER report")
    if boundary:
        out.append("Anything already documented in the target's audits is out of scope. Known findings to EXCLUDE:")
        for bl in boundary:
            out.append("- %s" % bl.split("|", 1)[1].strip())
    else:
        out.append("Anything already documented in the target's audits is out of scope — never re-report a "
                   "known or previously-disclosed issue.")
    out.append("")
    out.append("## Honesty mandate")
    out.append("Trace the actual control/data flow yourself — assume nothing is safe until a guard in the code "
               "provably stops it. Write and RUN a real Foundry PoC: a candidate is an UNVERIFIED lead until it "
               "reproduces through forge-verify. A rigorous SAFE on audited code is a valid outcome. Never "
               "fabricate a finding.")

    text = "\n".join(out).replace("\x00", "")
    lines = text.split("\n")
    if len(lines) > 2000:
        lines = lines[:2000]
    text = "\n".join(lines).rstrip("\n") + "\n"

    fname = "brief_%s.md" % zid
    with open(os.path.join(briefs, fname), "w", encoding="utf-8") as fh:
        fh.write(text)
    index[zid] = {"brief": fname, "classes": classes}
    count += 1

with open(os.path.join(briefs, "zone_briefs.json"), "w", encoding="utf-8") as fh:
    json.dump(index, fh, indent=2)
    fh.write("\n")
print(count)
PY
)"

GB_SUMMARY="gen-briefs.sh: $COUNT brief(s) -> $BRIEFS/brief_<zone_id>.md (bodies via $SRC_LABEL); feed one to run-discovery.sh --brief"
# #1707: surface a chrome/no-answer brief failure loudly (still a mechanical fallback, but counted).
[ "${FAILED:-0}" -gt 0 ] && GB_SUMMARY="$GB_SUMMARY — $FAILED brief(s) FAILED validation (retried ${DF_AGENT_MAX_ATTEMPTS}x, still chrome; mechanical fallback used)"
echo "$GB_SUMMARY" >&2
