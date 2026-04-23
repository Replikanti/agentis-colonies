#!/bin/bash
# tools/make-dashboard-bundle.sh: assemble a curated, install-ready release
# bundle for the standalone federation-dashboard component (#252).
#
# Differs from `make-federation-bundle.sh` in one important way: the dashboard
# tarball is the dashboard tree directly (no nested `federation-dashboard/`
# subdirectory). Extracting the tarball yields:
#
#     federation-dashboard-v<X.Y.Z>/
#       VERSION
#       CHANGELOG.md
#       README.md
#       install.sh
#       bin/
#       lib/
#
# Reads `federation-dashboard/BUNDLE.manifest` only as a sanity-check (every
# listed path must exist) and to surface bundle composition in CI logs. The
# actual file selection is "everything inside `federation-dashboard/` except
# `BUNDLE.manifest`".
#
# Usage:
#   tools/make-dashboard-bundle.sh <version>
#
# Example:
#   tools/make-dashboard-bundle.sh 0.1.0
#
# Exit codes:
#   0 -- bundle + .sha256 successfully written to dist/
#   1 -- argument error (usage printed)
#   2 -- federation-dashboard/ or BUNDLE.manifest missing / empty
#   3 -- a path listed in the manifest does not exist on disk
#   4 -- VERSION file mismatch with <version> argument

set -euo pipefail

usage() {
    cat <<'EOF' >&2
Usage: tools/make-dashboard-bundle.sh <version>

Assembles dist/federation-dashboard-v<version>.tar.gz (+ .sha256) from the
contents of federation-dashboard/ (excluding BUNDLE.manifest).
EOF
}

if [ "$#" -ne 1 ]; then
    usage
    exit 1
fi

VER="$1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

COMP_DIR="federation-dashboard"
if [ ! -d "$COMP_DIR" ]; then
    echo "make-dashboard-bundle: '$COMP_DIR/' not found (cwd=$REPO_ROOT)" >&2
    exit 2
fi

MANIFEST="$COMP_DIR/BUNDLE.manifest"
if [ ! -f "$MANIFEST" ]; then
    echo "make-dashboard-bundle: manifest '$MANIFEST' not found" >&2
    exit 2
fi

VERSION_FILE="$COMP_DIR/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo "make-dashboard-bundle: '$VERSION_FILE' not found" >&2
    exit 2
fi
declared="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [ "$declared" != "$VER" ]; then
    echo "make-dashboard-bundle: VERSION file says '$declared' but argument is '$VER'" >&2
    exit 4
fi

# Sanity-check manifest entries exist (mirrors make-federation-bundle.sh).
entries=0
while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"
    # shellcheck disable=SC2001
    line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    case "$line" in
        ""|"#"*) continue ;;
    esac
    src="${line%/}"
    if [ ! -e "$src" ]; then
        echo "make-dashboard-bundle: manifest entry '$src' does not exist in repo" >&2
        exit 3
    fi
    entries=$((entries + 1))
done < "$MANIFEST"

if [ "$entries" -eq 0 ]; then
    echo "make-dashboard-bundle: manifest '$MANIFEST' is empty (no non-comment lines)" >&2
    exit 2
fi

DIST="$REPO_ROOT/dist"
STAGE_NAME="federation-dashboard-v$VER"
STAGE="$DIST/$STAGE_NAME"
TARBALL="$DIST/$STAGE_NAME.tar.gz"
SHAFILE="$TARBALL.sha256"

# Fresh staging.
rm -rf "$STAGE"
mkdir -p "$STAGE"

# Copy contents of federation-dashboard/ (flattened, no nested wrapper dir).
# Skip BUNDLE.manifest (build-only artifact) and Python bytecode caches.
# nullglob makes the dotfile pattern collapse to nothing instead of
# expanding to its own literal text when there are no dotfiles (set -u
# safe). dotglob included for symmetry if a future dotfile needs to ship.
shopt -s nullglob dotglob
copied=0
for entry in "$COMP_DIR"/*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    case "$name" in
        BUNDLE.manifest|__pycache__|*.pyc) continue ;;
    esac
    cp -pR "$entry" "$STAGE/"
    copied=$((copied + 1))
done
shopt -u nullglob dotglob

# Strip nested __pycache__ that copied in via lib/ etc.
find "$STAGE" -type d -name __pycache__ -exec rm -rf {} +
find "$STAGE" -type f -name '*.pyc' -delete

if [ "$copied" -eq 0 ]; then
    echo "make-dashboard-bundle: nothing to bundle (federation-dashboard/ is empty)" >&2
    exit 2
fi

tar -C "$DIST" -czf "$TARBALL" "$STAGE_NAME"

# Portable sha256: GNU coreutils ships sha256sum; macOS ships shasum.
if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$DIST" && sha256sum "$STAGE_NAME.tar.gz" > "$STAGE_NAME.tar.gz.sha256" )
elif command -v shasum >/dev/null 2>&1; then
    ( cd "$DIST" && shasum -a 256 "$STAGE_NAME.tar.gz" > "$STAGE_NAME.tar.gz.sha256" )
else
    echo "make-dashboard-bundle: neither sha256sum nor shasum available" >&2
    exit 5
fi

echo "make-dashboard-bundle: wrote $TARBALL"
echo "make-dashboard-bundle: wrote $SHAFILE"
echo "make-dashboard-bundle: staged $copied top-level entries (manifest checked $entries)"
