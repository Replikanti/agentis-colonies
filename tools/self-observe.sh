#!/usr/bin/env bash
# tools/self-observe.sh — the federation's self-improvement driver (#1266 M3).
#
# Runs every tools/detect-*.sh, turns each finding into a SMALL, deduplicated,
# rate-limited tracking issue, and (dry-run by default) proposes them. This is
# the robust shape of self-tuning: observation is DETERMINISTIC (a shell scan,
# no LLM — so no over-exploration or flakiness), and every finding becomes ONE
# small issue the proven small-issue pipeline (code_writer) can fix — never a
# giant epic.
#
# Each detector prints TSV findings on stdout:
#   DRIFT<TAB><kind><TAB><location><TAB><text>
# (see tools/detect-doc-drift.sh, tools/detect-todo-markers.sh, and
#  tools/detect-agent-failures.sh once it lands).
#
# For each finding we compute a stable fingerprint and skip it when an existing
# issue already carries that fingerprint (dedup). Dedup searches --state all and
# treats a match as a hit when the issue is OPEN, carries the dismiss label
# (SELF_OBSERVE_DISMISS_LABEL — permanent suppression), or was CLOSED within the
# last SELF_OBSERVE_CLOSED_DEDUP_DAYS days — so a finding closed as wontfix/resolved
# while its signal is still in the detector window is NOT re-filed (#1298). New
# issues are capped per run, and each filed issue embeds the fingerprint in its
# body so the next run dedups against it.
#
# Usage:
#   tools/self-observe.sh            # DRY RUN: print what WOULD be filed
#   tools/self-observe.sh --file     # actually create the issues
#
# Before filing, each candidate is also passed through an ACCEPTANCE GATE
# (#1411, M4 step 2 of #1266): tools/track-issue-outcomes.sh tracks the fate of
# every previously-filed self-observe issue, and this driver suppresses filing
# for any signal_class whose recorded acceptance rate has fallen below
# SELF_OBSERVE_MIN_ACCEPTANCE once it has accumulated at least
# SELF_OBSERVE_MIN_SAMPLES closed outcomes (so a class is never judged on one or
# two data points). Every suppression is logged with the class + its rate, so a
# chronically-rejected detector goes quiet on its own without touching the
# detectors themselves. Classes below the sample floor, or with no history, file
# as normal — the gate only ever removes noise that the record already proves.
#
# Knobs (env):
#   SELF_OBSERVE_REPO     owner/repo to file into (default Replikanti/agentis-colonies)
#   SELF_OBSERVE_MAX_NEW  cap on new issues per run (default 5)
#   SELF_OBSERVE_LABELS   comma-separated labels for filed issues (default dev-apprenticeship)
#   SELF_OBSERVE_GH       gh binary (default gh; overridable for tests)
#   SELF_OBSERVE_CLOSED_DEDUP_DAYS  keep deduping against a CLOSED matching issue for
#                                   this many days after it closed (default 14)
#   SELF_OBSERVE_DISMISS_LABEL      label on a matching issue that permanently
#                                   suppresses re-filing (default self-observe-dismissed)
#   SELF_OBSERVE_MIN_ACCEPTANCE     suppress a signal_class below this acceptance
#                                   rate (0..1, default 0.3) once it has samples
#   SELF_OBSERVE_MIN_SAMPLES        min closed outcomes before a class can be
#                                   gated on its rate (default 5)
#   SELF_OBSERVE_RATES_CMD          command whose stdout is the per-class rate
#                                   TSV (default: track-issue-outcomes.sh --rates)
#
# Exit: 0 on success (even when there is nothing to file).
set -eu

DRY_RUN=1
case "${1:-}" in
    --file) DRY_RUN=0 ;;
    "")     ;;
    *)      echo "usage: self-observe.sh [--file]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${SELF_OBSERVE_REPO:-Replikanti/agentis-colonies}"
MAX_NEW="${SELF_OBSERVE_MAX_NEW:-5}"
case "$MAX_NEW" in ''|*[!0-9]*) MAX_NEW=5 ;; esac
LABELS="${SELF_OBSERVE_LABELS:-dev-apprenticeship}"
# Trigger label applied to every FILED issue so the federation's own SDLC picks
# it up and processes it autonomously — the #1266 self-improving loop closing on
# itself (find -> file -> implement -> review -> merge). Defaults to the
# implementation trigger label; set SELF_OBSERVE_TRIGGER_LABEL="" to file an
# untriggered, operator-triaged issue instead.
TRIGGER_LABEL="${SELF_OBSERVE_TRIGGER_LABEL-implementation}"
if [ -n "$TRIGGER_LABEL" ]; then FILE_LABELS="$LABELS,$TRIGGER_LABEL"; else FILE_LABELS="$LABELS"; fi
GH="${SELF_OBSERVE_GH:-gh}"
# Dedup window for a CLOSED matching issue: keep treating its fingerprint as a
# dedup hit for this many days after close, so a finding closed as wontfix while
# its signal is still in the detector window is not immediately re-filed (#1298).
CLOSED_DEDUP_DAYS="${SELF_OBSERVE_CLOSED_DEDUP_DAYS:-14}"
case "$CLOSED_DEDUP_DAYS" in ''|*[!0-9]*) CLOSED_DEDUP_DAYS=14 ;; esac
# A matching issue carrying this label permanently suppresses re-filing of its
# fingerprint, regardless of close age (operator-curated "do not re-file").
DISMISS_LABEL="${SELF_OBSERVE_DISMISS_LABEL:-self-observe-dismissed}"
# Detector kinds that are observed + logged but NOT filed as issues. These are
# OBSERVATIONS, not actionable code tasks, so auto-filing them — and now
# auto-triggering the SDLC on them — would be noise: raw TODO markers are author
# notes, and agent-failure findings are cumulative health counts (a monotonic
# counter that files a fresh issue per increment). The one actionable detector,
# doc-drift, still files + triggers. Override with a comma-separated
# SELF_OBSERVE_NOFILE_KINDS (set to "" to file every kind).
NOFILE_KINDS="${SELF_OBSERVE_NOFILE_KINDS-todo-marker,agent-failure}"
# Acceptance-gate knobs (#1411). A signal_class is suppressed when its recorded
# acceptance rate is below MIN_ACCEPTANCE and it has at least MIN_SAMPLES closed
# outcomes. MIN_ACCEPTANCE is a 0..1 fraction (validated in python during the
# precompute); MIN_SAMPLES is an integer.
MIN_ACCEPTANCE="${SELF_OBSERVE_MIN_ACCEPTANCE:-0.3}"
MIN_SAMPLES="${SELF_OBSERVE_MIN_SAMPLES:-5}"
case "$MIN_SAMPLES" in ''|*[!0-9]*) MIN_SAMPLES=5 ;; esac
# Command whose stdout is the per-class rate TSV (signal_class success total
# rate). Defaults to this repo's tracker; overridable for tests. Word-split on
# purpose so the default carries its own --rates flag.
RATES_CMD="${SELF_OBSERVE_RATES_CMD:-$SCRIPT_DIR/track-issue-outcomes.sh --rates}"

# Short, portable fingerprint of stdin (first 12 hex of sha256).
fp_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -c1-12
    else
        shasum -a 256 | cut -c1-12
    fi
}

# Normalize a finding's text: lowercase, collapse whitespace, trim — so
# trivially-different wording fingerprints the same.
normalize() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

# True when an existing issue already carries this fingerprint in its body/text
# AND that match should still suppress a re-file. We search --state all (not just
# open) and count a match as a dedup hit when the issue is OPEN, carries the
# dismiss label, or was CLOSED within CLOSED_DEDUP_DAYS days (#1298). The close-age
# math runs in a deterministic inline python3 pass (already a repo dependency); on
# a hit, DEDUP_REASON is set to a human-readable reason for the skip log line.
DEDUP_REASON=""
issue_exists() {
    local raw
    raw="$("$GH" issue list --repo "$REPO" --state all --search "$1" \
        --json number,state,closedAt,labels 2>/dev/null || echo '[]')"
    DEDUP_REASON="$(printf '%s' "$raw" | python3 -c '
import sys, json, datetime
dismiss = sys.argv[1].strip().lower()
try:
    days = int(sys.argv[2])
except ValueError:
    days = 14
try:
    issues = json.load(sys.stdin)
except Exception:
    issues = []
if not isinstance(issues, list):
    issues = []
now = datetime.datetime.now(datetime.timezone.utc)
for it in issues:
    state = str(it.get("state", "")).upper()
    names = [str(l.get("name", "")).lower() for l in (it.get("labels") or [])]
    if dismiss and dismiss in names:
        print("dismissed"); sys.exit(0)
    if state == "OPEN":
        print("open issue exists"); sys.exit(0)
    if state == "CLOSED":
        ca = (it.get("closedAt") or "").replace("Z", "+00:00")
        try:
            closed = datetime.datetime.fromisoformat(ca)
        except ValueError:
            closed = None
        if closed is not None and (now - closed).days <= days:
            print("recently closed"); sys.exit(0)
sys.exit(1)
' "$DISMISS_LABEL" "$CLOSED_DEDUP_DAYS")"
}

FINDINGS="$(mktemp)"
SUPPRESSED="$(mktemp)"
trap 'rm -f "$FINDINGS" "$SUPPRESSED"' EXIT

# Precompute the SUPPRESSED signal classes from the acceptance record: one line
# `<class>\t<rate>\t<total>` per class that has >= MIN_SAMPLES closed outcomes
# AND a rate below MIN_ACCEPTANCE. An unavailable/empty rate source (no history,
# no agentis, script missing) yields an empty file and gates nothing. The rate
# source is deterministic (the tracker reads only the memo — no forge calls).
$RATES_CMD 2>/dev/null | SO_MIN_ACCEPTANCE="$MIN_ACCEPTANCE" SO_MIN_SAMPLES="$MIN_SAMPLES" python3 -c '
import os, sys
try:
    min_acc = float(os.environ.get("SO_MIN_ACCEPTANCE", "0.3"))
except ValueError:
    min_acc = 0.3
try:
    min_n = int(os.environ.get("SO_MIN_SAMPLES", "5"))
except ValueError:
    min_n = 5
for ln in sys.stdin:
    parts = ln.rstrip("\n").split("\t")
    if len(parts) < 4:
        continue
    cls, _succ, total, rate = parts[0], parts[1], parts[2], parts[3]
    try:
        total_i = int(total)
        rate_f = float(rate)
    except ValueError:
        continue
    if total_i >= min_n and rate_f < min_acc:
        print("%s\t%s\t%d" % (cls, rate, total_i))
' > "$SUPPRESSED" || true

# Print "rate=<r> n=<t>" when $1's signal_class is suppressed, empty otherwise.
suppress_reason() {
    awk -F'\t' -v k="$1" '$1 == k { printf "rate=%s n=%s", $2, $3; found=1 } END {}' "$SUPPRESSED"
}

# Collect findings from every detector (each self-resolves its own repo root).
for det in "$SCRIPT_DIR"/detect-*.sh; do
    [ -x "$det" ] || continue
    "$det" 2>/dev/null >> "$FINDINGS" || true
done

filed=0
considered=0
suppressed=0
tab="$(printf '\t')"
# Read from the file (not a pipe) so the counters survive in this shell.
while IFS="$tab" read -r tag kind loc text; do
    [ "$tag" = "DRIFT" ] || continue
    considered=$((considered + 1))
    # Some detector kinds are log-only (NOFILE_KINDS) — observe + log, never file.
    case ",$NOFILE_KINDS," in
        *",$kind,"*) echo "[self-observe] log-only ($kind, not filed): $loc"; continue ;;
    esac
    # Acceptance gate (#1411): suppress classes the record proves are chronically
    # rejected (rate < MIN_ACCEPTANCE with >= MIN_SAMPLES outcomes). Logged so the
    # decision is observable; happens before dedup/rate-limit so a dead class
    # costs no forge calls.
    gate="$(suppress_reason "$kind")"
    if [ -n "$gate" ]; then
        echo "[self-observe] suppress (low acceptance: $kind $gate < min $MIN_ACCEPTANCE): $loc"
        suppressed=$((suppressed + 1))
        continue
    fi
    fp="$(printf '%s|~|%s|~|%s' "$kind" "$loc" "$(normalize "$text")" | fp_of)"
    if issue_exists "$fp"; then
        echo "[self-observe] skip (${DEDUP_REASON:-issue exists}): $kind $loc [$fp]"
        continue
    fi
    if [ "$filed" -ge "$MAX_NEW" ]; then
        echo "[self-observe] rate-limit reached ($MAX_NEW) — deferring: $kind $loc"
        continue
    fi
    title="[self-observe] $kind: $loc"
    body="$(printf 'Auto-detected by tools/self-observe.sh (%s detector).\n\n- **finding:** %s\n- **location:** %s\n\nA small, single-purpose self-improvement task for the federation.\n\n<!-- self-observe-fingerprint: %s -->\n' "$kind" "$text" "$loc" "$fp")"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[self-observe] WOULD FILE: $title  [$fp]"
        filed=$((filed + 1))
    elif url="$("$GH" issue create --repo "$REPO" --title "$title" --body "$body" --label "$FILE_LABELS" 2>/dev/null)" && [ -n "$url" ]; then
        echo "[self-observe] FILED: $title -> $url  [$fp]"
        filed=$((filed + 1))
    else
        # A failed create does NOT consume a rate-limit slot — retried next run.
        echo "[self-observe] create FAILED (will retry next run): $title  [$fp]"
    fi
done < "$FINDINGS"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[self-observe] done (dry-run): considered=$considered, would-file=$filed, suppressed=$suppressed (cap $MAX_NEW). Re-run with --file to create them."
else
    echo "[self-observe] done: considered=$considered, filed=$filed, suppressed=$suppressed (cap $MAX_NEW)."
fi
