#!/bin/bash
# tools/check-changelog.sh: soft check that PRs touching dev-apprenticeship/
# also update dev-apprenticeship/CHANGELOG.md. Warning-only for feature PRs,
# failing for release PRs (detected by VERSION bump in the diff).
#
# Invoked by tools/colony-lint.sh. Runs as a no-op outside a PR context (no
# `GITHUB_BASE_REF` env var) — intended to fire in CI, not on ad-hoc local
# runs.
#
# Exit codes:
#   0  ok (either no-op, or CHANGELOG updated, or no dev-apprenticeship/
#      change to begin with)
#   1  release PR (VERSION bumped) but CHANGELOG.md not updated — HARD fail
#
# When feature-PR-without-CHANGELOG is detected, the script prints a
# `[WARN]` line to stdout and exits 0 so colony-lint surfaces the reminder
# without blocking the merge.
#
# Usage:
#   tools/check-changelog.sh [repo-root]   # default: script's ../

set -euo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
FED_PREFIX="dev-apprenticeship/"
VERSION_FILE="${FED_PREFIX}VERSION"
CHANGELOG_FILE="${FED_PREFIX}CHANGELOG.md"

if [ -z "${GITHUB_BASE_REF:-}" ]; then
    # Local run without PR context. Nothing to diff against.
    echo "check-changelog: no PR context (GITHUB_BASE_REF unset) — skipping"
    exit 0
fi

BASE_REF="$GITHUB_BASE_REF"
# CI checkouts are often shallow; try to fetch the base branch so the
# three-dot diff can resolve. Swallow errors — if we can't fetch, fall
# through and let the diff fail cleanly below.
git -C "$REPO_ROOT" fetch --quiet --depth=50 origin "$BASE_REF" 2>/dev/null || true

if ! CHANGED="$(git -C "$REPO_ROOT" diff --name-only "origin/$BASE_REF...HEAD" 2>/dev/null)"; then
    echo "check-changelog: could not compute diff against origin/$BASE_REF (shallow clone?) — skipping"
    exit 0
fi

has_dev_app=false
has_changelog=false
has_version=false

while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$file" in
        "$VERSION_FILE")   has_version=true;   has_dev_app=true ;;
        "$CHANGELOG_FILE") has_changelog=true; has_dev_app=true ;;
        "$FED_PREFIX"*)    has_dev_app=true ;;
    esac
done <<< "$CHANGED"

if $has_version && ! $has_changelog; then
    echo "check-changelog: $VERSION_FILE bumped but $CHANGELOG_FILE not updated — release PR must move [Unreleased] into a dated section."
    exit 1
fi

if $has_dev_app && ! $has_changelog; then
    echo "[WARN] check-changelog: ${FED_PREFIX} touched without a corresponding $CHANGELOG_FILE entry — remember to update [Unreleased]."
    exit 0
fi

echo "check-changelog: CHANGELOG consistent with ${FED_PREFIX} diff"
exit 0
