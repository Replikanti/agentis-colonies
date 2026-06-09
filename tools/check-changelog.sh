#!/bin/bash
# tools/check-changelog.sh: soft check that PRs touching a versioned
# component (`dev-apprenticeship/`, `federation-dashboard/`) also update
# its CHANGELOG.md. Warning-only for feature PRs, failing for release PRs
# (detected by VERSION bump in the diff).
#
# Invoked by tools/colony-lint.sh. Runs as a no-op outside a PR context (no
# `GITHUB_BASE_REF` env var) — intended to fire in CI, not on ad-hoc local
# runs.
#
# Components are loop-driven (#252): adding a new versioned component is
# one line in the COMPONENTS array.
#
# Exit codes:
#   0  ok (either no-op, or every touched component has its CHANGELOG
#      updated, or no component touched at all)
#   1  release PR (any component's VERSION bumped) but its CHANGELOG.md
#      not updated — HARD fail
#
# When feature-PR-without-CHANGELOG is detected for a component, the
# script prints a `[WARN]` line per component and exits 0 so colony-lint
# surfaces the reminder without blocking the merge.
#
# Usage:
#   tools/check-changelog.sh [repo-root]   # default: script's ../

set -euo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# Versioned components: each line is "<prefix>/" — VERSION and CHANGELOG.md
# live directly inside that prefix.
COMPONENTS=(
    "dev-apprenticeship/"
    "federation-dashboard/"
    "tribes-bench/"
    "trading-binance/"
    "research-foundry/"
    "dark-factory/"
)

if [ -z "${GITHUB_BASE_REF:-}" ]; then
    echo "check-changelog: no PR context (GITHUB_BASE_REF unset) — skipping"
    exit 0
fi

BASE_REF="$GITHUB_BASE_REF"
git -C "$REPO_ROOT" fetch --quiet --depth=50 origin "$BASE_REF" 2>/dev/null || true

if ! CHANGED="$(git -C "$REPO_ROOT" diff --name-only "origin/$BASE_REF...HEAD" 2>/dev/null)"; then
    echo "check-changelog: could not compute diff against origin/$BASE_REF (shallow clone?) — skipping"
    exit 0
fi

hard_fail=0
all_clean=1

for prefix in "${COMPONENTS[@]}"; do
    version_file="${prefix}VERSION"
    changelog_file="${prefix}CHANGELOG.md"

    has_comp=false
    has_changelog=false
    has_version=false

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        case "$file" in
            "$version_file")    has_version=true;   has_comp=true ;;
            "$changelog_file")  has_changelog=true; has_comp=true ;;
            "$prefix"*)         has_comp=true ;;
        esac
    done <<< "$CHANGED"

    if $has_version && ! $has_changelog; then
        echo "check-changelog: $version_file bumped but $changelog_file not updated — release PR must move [Unreleased] into a dated section."
        hard_fail=1
        all_clean=0
        continue
    fi

    if $has_comp && ! $has_changelog; then
        echo "[WARN] check-changelog: ${prefix} touched without a corresponding $changelog_file entry — remember to update [Unreleased]."
        all_clean=0
        continue
    fi

    if $has_comp; then
        echo "check-changelog: CHANGELOG consistent with ${prefix} diff"
        all_clean=0
    fi
done

if [ "$all_clean" -eq 1 ]; then
    echo "check-changelog: no versioned component touched"
fi

exit "$hard_fail"
