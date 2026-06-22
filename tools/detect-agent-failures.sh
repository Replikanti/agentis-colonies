#!/bin/bash
# tools/detect-agent-failures.sh: recurring federation self-failure detector (M3 of #1266).
#
# The self-observation detector: the federation watches its OWN agent logs for
# recurring failure-pattern lines and prints one TSV line per pattern that
# recurs at least REPEAT_THRESHOLD (default 3) times on stdout, then exits 0. It
# is a DETECTOR, not a gate: it prints nothing when nothing recurs and never
# fails the build.
#
# For each recurring pattern it prints:
#
#   DRIFT<TAB>agent-failure<TAB><pattern>:<count><TAB><a sample matching line>
#
# Fixed, case-sensitive substring patterns counted across the logs:
#   produced no edits, ERROR job-failed, create-mr failed, monolithic fallback,
#   memo write limit, and lines containing both `watchdog` and `restarting`.
#
# Dependency-free (bash + grep/sed only). The repo root is resolved relative to
# this script's location so it runs from anywhere. Scans
# ${AGENT_LOG_DIR:-<repo-root>/.agentis/logs} (env override used by the test).
#
# Usage: ./tools/detect-agent-failures.sh
# Exit code: always 0.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_DIR="${AGENT_LOG_DIR:-$REPO_ROOT/.agentis/logs}"
REPEAT_THRESHOLD="${REPEAT_THRESHOLD:-3}"

[ -d "$LOG_DIR" ] || exit 0

# Emit a DRIFT line for <pattern> only when its count clears the threshold.
report() {
    pattern="$1"
    count="$2"
    sample="$3"
    if [ "$count" -ge "$REPEAT_THRESHOLD" ]; then
        sample="$(printf '%s' "$sample" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        printf 'DRIFT\tagent-failure\t%s:%s\t%s\n' "$pattern" "$count" "$sample"
    fi
}

# Simple fixed-string substring patterns (case-sensitive).
for pattern in 'produced no edits' 'ERROR job-failed' 'create-mr failed' \
               'monolithic fallback' 'memo write limit'; do
    matches="$(grep -rhF -- "$pattern" "$LOG_DIR" 2>/dev/null || true)"
    [ -n "$matches" ] || continue
    count="$(printf '%s\n' "$matches" | grep -cF -- "$pattern")"
    sample="$(printf '%s\n' "$matches" | head -n1)"
    report "$pattern" "$count" "$sample"
done

# Combined pattern: lines containing BOTH `watchdog` and `restarting`.
matches="$(grep -rhF -- 'watchdog' "$LOG_DIR" 2>/dev/null | grep -F -- 'restarting' || true)"
if [ -n "$matches" ]; then
    count="$(printf '%s\n' "$matches" | grep -c .)"
    sample="$(printf '%s\n' "$matches" | head -n1)"
    report 'watchdog+restarting' "$count" "$sample"
fi

exit 0
