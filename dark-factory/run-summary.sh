#!/usr/bin/env bash
# run-summary.sh — emit a dashboard-/monitor-consumable JSON summary of a one-shot dark-factory run.
#
# dark-factory runs ONE-SHOT via `agentis go` (run-discovery.sh / run-audit.sh): no long-lived
# daemons, no per-agent `*:confidence` memos. The standalone `federation-dashboard` component, by
# contrast, assumes daemon-tick agents with confidence-tier memos (the dev-apprenticeship model), so a
# one-shot run leaves nothing it can poll (#995). This script closes that gap on the DARK-FACTORY SIDE:
# after a run it distills the run's on-disk artifacts (the agentis experience log + the run report)
# into a single stable JSON file at `<out>/run-summary.json` that a monitor or dashboard can poll.
#
# It NEVER mutates the run store and NEVER talks to a bounty platform — it only READS what the run
# already wrote. Run it after run-discovery.sh / run-audit.sh against the SAME --out dir.
#
# Usage:
#   run-summary.sh --out <run-out-dir> [options]
#
# Options:
#   --out <dir>        The output dir a run wrote to (run-discovery.sh / run-audit.sh `--out`). REQUIRED.
#   --kind <discovery|audit|auto>  Which run shape to summarize (default: auto-detect from <out>).
#   --emit-event       Also append the summary as one `dark-factory:run_summary` line to <out>/events.jsonl
#                      (a monitor that tails per-run event files picks it up without re-reading JSON).
#   --json             Print the summary JSON to stdout too (it is always written to <out>/run-summary.json).
#
# Output JSON (schema v1): see dark-factory/docs/run-observability.md for the consumer contract.
#   { schema, kind, out, generated_at, last_run_at, verdict,
#     cells_run, candidates_found,
#     learn: { total, by_outcome:{success,failure,partial,timeout,error}, outcomes:[...] },
#     classes: [ {class, attempts, success, failure, fitness}... ],   # per-(bug)class, fitness = success/attempts
#     report }
set -uo pipefail

OUT=""
KIND="auto"
EMIT_EVENT=""
PRINT_JSON=""

need() { [ "$1" -ge 2 ] || { echo "run-summary.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --kind) need "$#"; KIND="$2"; shift 2 ;;
    --emit-event) EMIT_EVENT=1; shift ;;
    --json) PRINT_JSON=1; shift ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-summary.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$OUT" ] && [ -d "$OUT" ] || { echo "run-summary.sh: --out <run-out-dir> required (the dir run-discovery.sh / run-audit.sh wrote to)" >&2; exit 2; }
OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
[ -d "$RUN" ] || { echo "run-summary.sh: no run store at $RUN — is this a dark-factory --out dir?" >&2; exit 2; }

case "$KIND" in
  discovery|audit) : ;;
  auto)
    # discovery writes discovery-report.md; audit writes run/audit.log + (on a finding) submission/.
    if [ -f "$OUT/discovery-report.md" ]; then KIND="discovery"
    elif [ -f "$RUN/audit.log" ]; then KIND="audit"
    else KIND="discovery"; fi
    ;;
  *) echo "run-summary.sh: --kind must be discovery|audit|auto" >&2; exit 2 ;;
esac

# The experience log is the ground truth for learn() outcomes + per-class fitness. The runtime keys
# it by agent IDENTITY (the branch, e.g. `main`), NOT the literal agent name, so `agentis experience
# summary hunter` finds nothing — we read the raw JSONL the run already wrote directly. Glob over the
# dir so we do not hardcode the branch name; an absent dir (learning disabled) degrades to empty.
EXP_DIR="$RUN/.agentis/experience"
EXP_FILES=""
[ -d "$EXP_DIR" ] && EXP_FILES="$(find "$EXP_DIR" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null | sort | tr '\n' ' ')"

# Report file the run wrote (free-text human report); discovery's is parsed for cells/candidates below.
REPORT=""
[ "$KIND" = "discovery" ] && [ -f "$OUT/discovery-report.md" ] && REPORT="$OUT/discovery-report.md"
[ "$KIND" = "audit" ] && [ -f "$RUN/audit.log" ] && REPORT="$RUN/audit.log"

# Cells-run + candidates-found come from discovery-report's footer line ("Cells run: N  Candidates
# surfaced: M"); the audit shape reports a single VERDICT instead. Verdict for audit = the run's
# `Verdict: <X>` line (same parse run-audit.sh uses); discovery's verdict is candidates>0 ? LEADS : SAFE.
CELLS=""
CANDIDATES=""
VERDICT=""
if [ "$KIND" = "discovery" ] && [ -n "$REPORT" ]; then
  CELLS="$(grep -oE 'Cells run: [0-9]+' "$REPORT" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)"
  CANDIDATES="$(grep -oE 'Candidates surfaced: [0-9]+' "$REPORT" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)"
elif [ "$KIND" = "audit" ] && [ -n "$REPORT" ]; then
  VERDICT="$(grep -oE 'Verdict: [A-Z()a-z: -]+' "$REPORT" 2>/dev/null | tail -1 | sed 's/^Verdict: //' || true)"
fi

# last-run timestamp: prefer the experience log's newest row ts (epoch ms); else the report mtime.
# We pass the candidate sources to python, which picks the freshest available.
REPORT_MTIME=""
if [ -n "$REPORT" ]; then
  REPORT_MTIME="$(date -u -r "$REPORT" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
fi
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

SUMMARY="$OUT/run-summary.json"

# Build the JSON with python3 (json.dumps), per repo convention — never hand-string JSON. The python
# program is passed on stdin (heredoc); every dynamic value goes through argv, so there is no
# pipe-vs-heredoc stdin clash and no shell-quoting of values into the program text (SC2259-safe, the
# contest-watch.sh / snapshot-rpc.sh precedent). Experience JSONL paths are positional args 11..N.
# shellcheck disable=SC2086  # EXP_FILES is intentionally word-split — each jsonl path is its own argv.
python3 - \
  "$SUMMARY" \
  "$KIND" \
  "$OUT" \
  "$GENERATED_AT" \
  "${VERDICT:-}" \
  "${CELLS:-}" \
  "${CANDIDATES:-}" \
  "${REPORT:-}" \
  "${REPORT_MTIME:-}" \
  "${EMIT_EVENT:-}" \
  $EXP_FILES <<'PY'
import json, os, sys

(summary_path, kind, out, generated_at, verdict, cells, candidates,
 report, report_mtime, emit_event) = sys.argv[1:11]
exp_files = sys.argv[11:]

OUTCOMES = ["success", "failure", "partial", "timeout", "error"]

# --- read learn() outcomes from the run's experience JSONL (ground truth) -----------------------
rows = []
for p in exp_files:
    try:
        with open(p, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        continue

by_outcome = {o: 0 for o in OUTCOMES}
outcomes_list = []          # one compact record per learn() row, for a monitor's event feed
# Per-(bug)class tallies. The first tag on a discovery hunt row is the class id (hunter.ag:
# learn("hunt", cls+":"+subsystem, ..., [cls, subsystem, outcome])). We fall back to splitting the
# `in` field ("C8:vault core") when tags are absent, so the summary stays robust to agent-tag drift.
classes = {}
last_run_ms = 0

for r in rows:
    outcome = str(r.get("outcome", "")) or "unknown"
    if outcome in by_outcome:
        by_outcome[outcome] += 1
    else:
        by_outcome[outcome] = by_outcome.get(outcome, 0) + 1
    ts = r.get("ts")
    if isinstance(ts, (int, float)) and ts > last_run_ms:
        last_run_ms = int(ts)

    tags = r.get("tags") if isinstance(r.get("tags"), list) else []
    cls = None
    if tags and isinstance(tags[0], str) and tags[0]:
        cls = tags[0]
    else:
        in_field = str(r.get("in", ""))
        if ":" in in_field:
            cls = in_field.split(":", 1)[0]
    subsystem = tags[1] if len(tags) > 1 and isinstance(tags[1], str) else None

    outcomes_list.append({
        "action": r.get("action"),
        "class": cls,
        "subsystem": subsystem,
        "in": r.get("in"),
        "outcome": outcome,
        "ts": ts,
    })

    if cls:
        c = classes.setdefault(cls, {"class": cls, "attempts": 0, "success": 0, "failure": 0})
        c["attempts"] += 1
        if outcome == "success":
            c["success"] += 1
        elif outcome == "failure":
            c["failure"] += 1

# Per-class fitness = success / attempts (the observable yield of a hunt class on this run), rounded
# to 4dp. This mirrors auto-promote.sh's "fitness on acting rows" — a class that surfaces leads scores
# high, a class that only ever returns SAFE scores 0. A monitor reweights / ranks classes on this.
class_list = []
for cls in sorted(classes):
    c = classes[cls]
    c["fitness"] = round(c["success"] / c["attempts"], 4) if c["attempts"] else 0.0
    class_list.append(c)

# --- last-run timestamp: freshest experience-row ts, else the report mtime, else generated_at ----
if last_run_ms:
    import datetime
    last_run_at = datetime.datetime.fromtimestamp(
        last_run_ms / 1000.0, tz=datetime.timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
elif report_mtime:
    last_run_at = report_mtime
else:
    last_run_at = generated_at

# --- verdict: audit carries an explicit Verdict; discovery's verdict is derived from candidates ---
def to_int(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        return None

cells_n = to_int(cells)
candidates_n = to_int(candidates)

if kind == "discovery":
    if candidates_n is None:
        verdict_final = "UNKNOWN"
    elif candidates_n > 0:
        verdict_final = "LEADS"          # unverified leads surfaced — forge-verify each before it counts
    else:
        verdict_final = "SAFE"           # rigorous negative; nothing submitted
else:
    verdict_final = verdict or "UNKNOWN"

summary = {
    "schema": "dark-factory/run-summary@1",
    "kind": kind,
    "out": out,
    "generated_at": generated_at,
    "last_run_at": last_run_at,
    "verdict": verdict_final,
    "cells_run": cells_n,
    "candidates_found": candidates_n,
    "learn": {
        "total": len(rows),
        "by_outcome": by_outcome,
        "outcomes": outcomes_list,
    },
    "classes": class_list,
    "report": report or None,
}

text = json.dumps(summary, indent=2, sort_keys=True)
with open(summary_path, "w", encoding="utf-8") as fh:
    fh.write(text + "\n")

# --emit-event: append a single compact NDJSON line a tailing monitor can consume without re-reading
# the whole summary. One event per run (idempotent file, append).
if emit_event:
    event = {
        "event": "dark-factory:run_summary",
        "ts": generated_at,
        "kind": kind,
        "verdict": verdict_final,
        "cells_run": cells_n,
        "candidates_found": candidates_n,
        "learn_total": len(rows),
    }
    with open(os.path.join(out, "events.jsonl"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(event, sort_keys=True) + "\n")
PY
rc=$?
[ "$rc" -eq 0 ] || { echo "run-summary.sh: failed to build summary JSON (python3 exit $rc)" >&2; exit 1; }

echo "run-summary.sh: wrote $SUMMARY (kind=$KIND)" >&2
[ -n "$EMIT_EVENT" ] && echo "run-summary.sh: appended dark-factory:run_summary event to $OUT/events.jsonl" >&2

if [ -n "$PRINT_JSON" ]; then
  cat "$SUMMARY"
fi
