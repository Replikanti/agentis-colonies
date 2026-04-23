#!/bin/bash
# install.sh — federation-dashboard installer (#252)
#
# XDG-aware install:
#   data: ${XDG_DATA_HOME:-$HOME/.local/share}/federation-dashboard/
#   bin:  ${XDG_BIN_HOME:-$HOME/.local/bin}/federation-dashboard  (symlink)
#
# Usage:
#   ./install.sh                  # install into XDG defaults
#   ./install.sh --uninstall      # remove the install + symlink
#   ./install.sh --prefix /opt/x  # override data dir; bin still XDG (or /opt/x/bin if no XDG_BIN_HOME)

set -e

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
BIN_HOME="${XDG_BIN_HOME:-$HOME/.local/bin}"
DATA_DIR=""
MODE="install"

show_help() {
    cat <<'EOF'
install.sh — federation-dashboard installer (#252)

XDG-aware install:
  data: ${XDG_DATA_HOME:-$HOME/.local/share}/federation-dashboard/
  bin:  ${XDG_BIN_HOME:-$HOME/.local/bin}/federation-dashboard  (symlink)

Usage:
  ./install.sh                  # install into XDG defaults
  ./install.sh --uninstall      # remove the install + symlink
  ./install.sh --prefix /opt/x  # override data dir; bin still XDG
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) MODE="uninstall"; shift ;;
        --prefix)    DATA_DIR="$2"; shift 2 ;;
        --prefix=*)  DATA_DIR="${1#--prefix=}"; shift ;;
        -h|--help)   show_help; exit 0 ;;
        *) echo "install.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$DATA_DIR" ]; then
    DATA_DIR="$DATA_HOME/federation-dashboard"
fi
SYMLINK="$BIN_HOME/federation-dashboard"

uninstall() {
    if [ -L "$SYMLINK" ]; then
        echo "Removing symlink: $SYMLINK"
        rm -f "$SYMLINK"
    fi
    if [ -d "$DATA_DIR" ]; then
        echo "Removing install dir: $DATA_DIR"
        rm -rf "$DATA_DIR"
    fi
    echo "federation-dashboard: uninstalled"
}

if [ "$MODE" = "uninstall" ]; then
    uninstall
    exit 0
fi

# --- Install ---

# Sanity: required source layout
for required in VERSION bin/federation-dashboard lib/federation-dashboard.html.template; do
    if [ ! -e "$SCRIPT_DIR/$required" ]; then
        echo "install.sh: missing required file in source: $required" >&2
        echo "Are you running install.sh from the extracted tarball root?" >&2
        exit 1
    fi
done

VERSION="$(cat "$SCRIPT_DIR/VERSION")"
echo "Installing federation-dashboard v$VERSION"
echo "  data: $DATA_DIR"
echo "  bin:  $SYMLINK"
echo ""

# Fresh install: nuke old install dir if present (single-operator project,
# no persistent state lives here — state goes into <fed-dir>/.dashboard/).
if [ -d "$DATA_DIR" ]; then
    echo "Removing previous install at $DATA_DIR"
    rm -rf "$DATA_DIR"
fi

mkdir -p "$DATA_DIR"
# Copy everything except install.sh itself and BUNDLE.manifest (build artifacts,
# not runtime needs).
for entry in "$SCRIPT_DIR"/*; do
    name="$(basename "$entry")"
    case "$name" in
        install.sh|BUNDLE.manifest) continue ;;
    esac
    cp -R "$entry" "$DATA_DIR/"
done

chmod +x "$DATA_DIR/bin/federation-dashboard"

mkdir -p "$BIN_HOME"
ln -sfn "$DATA_DIR/bin/federation-dashboard" "$SYMLINK"

echo ""
echo "Installed."
echo ""

# PATH check
case ":$PATH:" in
    *":$BIN_HOME:"*) ;;
    *)
        echo "WARNING: $BIN_HOME is not on \$PATH." >&2
        echo "         Add it to your shell rc, e.g.:" >&2
        echo "         export PATH=\"$BIN_HOME:\$PATH\"" >&2
        echo "" >&2
        ;;
esac

echo "Run with:"
echo "  federation-dashboard <federation-dir> [port]"
