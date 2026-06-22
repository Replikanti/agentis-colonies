#!/bin/bash
# tools/detect-todo-markers.sh: in-tree TODO/FIXME/XXX marker detector (M1 of #1266).
#
# Walks the repo tree and prints one TSV line per marker on stdout, then exits
# 0. It is a DETECTOR, not a gate: it prints nothing when there are no markers
# and never fails the build.
#
# Vendored and generated directories are skipped so third-party / build output
# does not surface as noise: .git, node_modules, .solc-cache, dist, build,
# target, __pycache__, vendor (#1283).
#
# For every TODO, FIXME, or XXX marker it prints:
#
#   DRIFT<TAB>todo-marker<TAB><file>:<line><TAB><trimmed marker text>
#
# where <file> is relative to the scanned root and <trimmed marker text> is the
# matched source line with leading/trailing whitespace stripped.
#
# Dependency-free (bash + grep/sed only). The repo root is resolved relative to
# this script's location so it runs from anywhere. Set DETECT_TODO_ROOT to scan
# a different tree (used by the test harness with fixtures).
#
# Usage: ./tools/detect-todo-markers.sh
# Exit code: always 0.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Allow overriding the scanned root (used by the test harness with fixtures).
ROOT="${DETECT_TODO_ROOT:-$REPO_ROOT}"

[ -d "$ROOT" ] || exit 0

# Scan from inside the root so grep emits paths relative to it. -I skips binary
# files, -n adds line numbers, -E enables the alternation. Vendored/generated
# directories are excluded so third-party / build output is not reported.
cd "$ROOT" || exit 0
grep -rInE 'TODO|FIXME|XXX' \
    --exclude-dir=.git \
    --exclude-dir=node_modules \
    --exclude-dir=.solc-cache \
    --exclude-dir=dist \
    --exclude-dir=build \
    --exclude-dir=target \
    --exclude-dir=__pycache__ \
    --exclude-dir=vendor \
    --exclude-dir=.agentis \
    --exclude-dir=targets \
    --exclude='test-*.sh' \
    --exclude='*.md' \
    . 2>/dev/null | while IFS= read -r hit; do
    # grep output is "<file>:<line>:<content>"; peel the first two colon fields.
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"
    text="${rest#*:}"
    file="${file#./}"
    text="$(printf '%s' "$text" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf 'DRIFT\ttodo-marker\t%s:%s\t%s\n' "$file" "$line" "$text"
done

exit 0
