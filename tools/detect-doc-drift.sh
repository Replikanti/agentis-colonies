#!/bin/bash
# tools/detect-doc-drift.sh: documentation drift detector (M1 of #1266, step 1).
#
# Compares ONE documented fact against reality and prints a TSV line per drift
# on stdout, then exits 0. It is a DETECTOR, not a gate: it prints nothing when
# there is no drift and never fails the build.
#
# Check: the `version-X.Y.Z` shields badge in dev-apprenticeship/README.md vs
# the version in dev-apprenticeship/VERSION. On mismatch it prints:
#
#   DRIFT<TAB>version-badge<TAB><documented><TAB><actual>
#
# where documented = the badge value and actual = the VERSION value.
#
# Dependency-free (bash + grep/sed only). The repo root is resolved relative to
# this script's location so it runs from anywhere.
#
# Usage: ./tools/detect-doc-drift.sh
# Exit code: always 0.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

README="$REPO_ROOT/dev-apprenticeship/README.md"
VERSION_FILE="$REPO_ROOT/dev-apprenticeship/VERSION"

# Allow overriding the inputs (used by the test harness with fixtures).
README="${DETECT_DOC_DRIFT_README:-$README}"
VERSION_FILE="${DETECT_DOC_DRIFT_VERSION:-$VERSION_FILE}"

# Extract the first `version-X.Y.Z` shields badge value from the README.
badge_version=""
if [ -f "$README" ]; then
    badge_version="$(grep -oE 'badge/version-[0-9]+\.[0-9]+\.[0-9]+' "$README" \
        | head -n1 \
        | sed -E 's#badge/version-##')"
fi

# Read the declared version (first non-empty line, trimmed).
actual_version=""
if [ -f "$VERSION_FILE" ]; then
    actual_version="$(sed -e 's/[[:space:]]//g' "$VERSION_FILE" | grep -m1 '.' || true)"
fi

# Only report a drift when both facts are present and they disagree.
if [ -n "$badge_version" ] && [ -n "$actual_version" ] && \
   [ "$badge_version" != "$actual_version" ]; then
    printf 'DRIFT\tversion-badge\t%s\t%s\n' "$badge_version" "$actual_version"
fi

exit 0
