#!/usr/bin/env bash
# check-no-replay-current-pid.sh: fail if any research-foundry .ag file
# reads or writes `replay:current_<role>_pid` after Phase 9 PR-A landed.
#
# Phase 9 PR-A (#663) replaced the replica-unsafe `replay:current_<role>_pid`
# LWW handoff with a tick-keyed fan-in + winner-by-confidence picker
# (`_pick_upstream_by_confidence(role, output_key, tick)`). The picker
# enumerates `<role>:*:<decision_key>:tick-<N>` memos, ranks by an embedded
# `confidence*` field, and returns the chosen PID. Downstream agents must
# NOT regress to the LWW pattern; this check enforces that invariant.
#
# Usage: ./tools/check-no-replay-current-pid.sh [path-to-repo-root]
# Exit 0 if clean, 1 if a violation is found.
#
# Runs on bash 3.2+ (stock macOS /bin/bash) and bash 4+.

set -euo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TARGET_DIR="$REPO_ROOT/research-foundry"

if [ ! -d "$TARGET_DIR" ]; then
    # No research-foundry tree to scan -- treat as clean.
    exit 0
fi

violations=0
while IFS= read -r -d '' ag_file; do
    # Match only `recall_latest("replay:current_<role>_pid")` (consumer side).
    # Producer-side `memo_write("replay:current_<role>_pid", self_pid)` writes
    # are out of scope for PR-A and left in place so any external probes
    # the orchestrator might keep continue to work; PR-B/PR-C may retire
    # them once the broader replica machinery lands.
    if grep -nE 'recall_latest\("replay:current_[a-z_]+_pid"\)' "$ag_file" >/dev/null 2>&1; then
        echo "[FAIL] $ag_file reads replay:current_<role>_pid (Phase 9 PR-A regression)"
        grep -nE 'recall_latest\("replay:current_[a-z_]+_pid"\)' "$ag_file"
        violations=$((violations + 1))
    fi
done < <(find "$TARGET_DIR" -type f -name "*.ag" -print0 2>/dev/null)

if [ "$violations" -eq 0 ]; then
    exit 0
fi

echo ""
echo "Phase 9 PR-A (#663) removed all replay:current_<role>_pid reads in"
echo "research-foundry/. Use _pick_upstream_by_confidence(role, output_key,"
echo "tick) instead. See research-foundry/CHANGELOG.md for the rationale."
exit 1
