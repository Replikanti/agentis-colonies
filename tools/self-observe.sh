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
# For each finding we compute a stable fingerprint, skip it when an open issue
# already carries that fingerprint (dedup), cap new issues per run, and file a
# small tracking issue with the fingerprint embedded in the body so the next run
# dedups against it.
#
# Usage:
#   tools/self-observe.sh            # DRY RUN: print what WOULD be filed
#   tools/self-observe.sh --file     # actually create the issues
#
# Knobs (env):
#   SELF_OBSERVE_REPO     owner/repo to file into (default Replikanti/agentis-colonies)
#   SELF_OBSERVE_MAX_NEW  cap on new issues per run (default 5)
#   SELF_OBSERVE_LABELS   comma-separated labels for filed issues (default dev-apprenticeship)
#   SELF_OBSERVE_GH       gh binary (default gh; overridable for tests)
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
GH="${SELF_OBSERVE_GH:-gh}"

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

# True when an open issue already carries this fingerprint in its body/text.
issue_exists() {
    local n
    n="$("$GH" issue list --repo "$REPO" --state open --search "$1" --json number --jq 'length' 2>/dev/null || echo 0)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -gt 0 ]
}

FINDINGS="$(mktemp)"
trap 'rm -f "$FINDINGS"' EXIT

# Collect findings from every detector (each self-resolves its own repo root).
for det in "$SCRIPT_DIR"/detect-*.sh; do
    [ -x "$det" ] || continue
    "$det" 2>/dev/null >> "$FINDINGS" || true
done

filed=0
considered=0
tab="$(printf '\t')"
# Read from the file (not a pipe) so the counters survive in this shell.
while IFS="$tab" read -r tag kind loc text; do
    [ "$tag" = "DRIFT" ] || continue
    considered=$((considered + 1))
    fp="$(printf '%s|~|%s|~|%s' "$kind" "$loc" "$(normalize "$text")" | fp_of)"
    if issue_exists "$fp"; then
        echo "[self-observe] skip (open issue exists): $kind $loc [$fp]"
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
    else
        url="$("$GH" issue create --repo "$REPO" --title "$title" --body "$body" --label "$LABELS" 2>/dev/null || true)"
        echo "[self-observe] FILED: $title -> ${url:-<create-failed>}  [$fp]"
    fi
    filed=$((filed + 1))
done < "$FINDINGS"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[self-observe] done (dry-run): considered=$considered, would-file=$filed (cap $MAX_NEW). Re-run with --file to create them."
else
    echo "[self-observe] done: considered=$considered, filed=$filed (cap $MAX_NEW)."
fi
