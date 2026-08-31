#!/bin/bash
# tools/make-federation-bundle.sh: assemble a curated, install-ready release
# bundle for a single federation (#220).
#
# Reads `<federation>/BUNDLE.manifest`, stages every listed path into
# `dist/<federation>-v<version>/` (preserving repo-relative layout), then tars
# and sha256-seals the result.
#
# The output tarball is what end-users download via
#   curl -LO https://.../releases/download/<fed>-v<X.Y.Z>/<fed>-v<X.Y.Z>.tar.gz
# The tag-triggered `.github/workflows/release.yml` invokes this script in CI.
#
# Usage:
#   tools/make-federation-bundle.sh <federation> <version>
#
# Example:
#   tools/make-federation-bundle.sh dev-apprenticeship 0.1.1
#
# Exit codes:
#   0 -- bundle + .sha256 successfully written to dist/
#   1 -- argument error (usage printed)
#   2 -- federation directory missing, or BUNDLE.manifest missing / empty
#   3 -- a path listed in the manifest does not exist on disk

set -euo pipefail

usage() {
    cat <<'EOF' >&2
Usage: tools/make-federation-bundle.sh <federation> <version>

Assembles dist/<federation>-v<version>.tar.gz (+ .sha256) from the paths listed
in <federation>/BUNDLE.manifest.
EOF
}

if [ "$#" -ne 2 ]; then
    usage
    exit 1
fi

FED="$1"
VER="$2"

# Locate repo root as the script's grandparent (tools/../).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if [ ! -d "$FED" ]; then
    echo "make-federation-bundle: federation directory '$FED' not found (cwd=$REPO_ROOT)" >&2
    exit 2
fi

MANIFEST="$FED/BUNDLE.manifest"
if [ ! -f "$MANIFEST" ]; then
    echo "make-federation-bundle: manifest '$MANIFEST' not found" >&2
    exit 2
fi

# Staging is driven by the git index (see the loop below), so a release cannot
# be built from an unversioned directory: there would be no way to tell shipped
# content from whatever happens to sit on disk. Refuse rather than fall back to
# a plain copy, which is the behaviour that shipped an operator's private key.
if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "make-federation-bundle: $REPO_ROOT is not a git repository." >&2
    echo "  A bundle is staged from the index, so it must be built from a checkout." >&2
    exit 2
fi

DIST="$REPO_ROOT/dist"
STAGE_NAME="$FED-v$VER"
STAGE="$DIST/$STAGE_NAME"
TARBALL="$DIST/$STAGE_NAME.tar.gz"
SHAFILE="$TARBALL.sha256"

# Fresh staging: drop any leftover from a previous run of the same version.
rm -rf "$STAGE"
mkdir -p "$STAGE"

entries=0
while IFS= read -r raw || [ -n "$raw" ]; do
    # Strip trailing CR (if manifest was edited on Windows), leading/trailing
    # whitespace, and ignore comments + blanks.
    line="${raw%$'\r'}"
    # shellcheck disable=SC2001  # sed is clearer than a bash parameter expansion here.
    line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    case "$line" in
        ""|"#"*) continue ;;
    esac

    # Normalize trailing slash so both "doc/adr/" and "tools/parse-toml.sh" work.
    src="${line%/}"
    if [ ! -e "$src" ]; then
        echo "make-federation-bundle: manifest entry '$src' does not exist in repo" >&2
        exit 3
    fi

    # Stage TRACKED files only, never `cp -pR` of the path as it sits on disk.
    # cp does not honour .gitignore, so a directory entry packaged whatever the
    # operator's working tree happened to hold: a locally built grand-rounds
    # tarball shipped baseline/.agentis/ (an Ed25519 private key), a real
    # config/colony.toml, gated work/*.vcf and derived out/*.csv, with every
    # bundle test green. Enumerating paths in each manifest only narrowed that;
    # it did not close it, because the remaining directory entries have exactly
    # the same property. Driving the copy from the index closes it for every
    # federation at once: if a file is not committed, it cannot ship.
    if [ -n "$(git -C "$REPO_ROOT" ls-files -- "$src" | head -1)" ]; then
        while IFS= read -r -d '' tracked_file; do
            mkdir -p "$STAGE/$(dirname "$tracked_file")"
            cp -p "$REPO_ROOT/$tracked_file" "$STAGE/$tracked_file"
        done < <(git -C "$REPO_ROOT" ls-files -z -- "$src")
    else
        echo "make-federation-bundle: manifest entry '$src' matches no TRACKED file" >&2
        echo "  (it exists on disk but is not committed; a release must ship only" >&2
        echo "   committed content, so this is refused rather than packaged)" >&2
        exit 3
    fi
    entries=$((entries + 1))
done < "$MANIFEST"

if [ "$entries" -eq 0 ]; then
    echo "make-federation-bundle: manifest '$MANIFEST' is empty (no non-comment lines)" >&2
    exit 2
fi

# Tar from dist/ so the archive's top-level is the versioned dir.
tar -C "$DIST" -czf "$TARBALL" "$STAGE_NAME"

# sha256 file format matches `sha256sum -c` expectations.
( cd "$DIST" && sha256sum "$STAGE_NAME.tar.gz" > "$STAGE_NAME.tar.gz.sha256" )

echo "make-federation-bundle: wrote $TARBALL"
echo "make-federation-bundle: wrote $SHAFILE"
echo "make-federation-bundle: staged $entries manifest entries"
