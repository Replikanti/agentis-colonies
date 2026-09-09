#!/usr/bin/env bash
# Fetch a real audit target repo WITH its dependencies, for a multi-file colony audit
# (phase 2 of agentis-core#859). Foundry projects vendor deps as git submodules under lib/
# (-> --recursive); Hardhat/npm projects need node_modules (-> npm ci). HOST-SIDE network —
# the operator's one allowed fetch step, like snapshot-rpc.sh; the in-sandbox build stays offline.
#
# Usage: fetch-target.sh <git-url> <dest-dir> [git-ref]
set -eu

URL="${1:-}"; DEST="${2:-}"; REF="${3:-}"
[ -n "$URL" ] && [ -n "$DEST" ] || { echo "usage: fetch-target.sh <git-url> <dest-dir> [git-ref]" >&2; exit 2; }
[ -e "$DEST" ] && { echo "fetch-target: dest exists: $DEST (remove it first)" >&2; exit 2; }

# --recursive pulls Foundry lib/ submodules (openzeppelin, forge-std, ...). --depth 1 keeps it light.
if [ -n "$REF" ]; then
  git clone --recursive --depth 1 --shallow-submodules --branch "$REF" "$URL" "$DEST"
else
  git clone --recursive --depth 1 --shallow-submodules "$URL" "$DEST"
fi

# Hardhat / npm projects: deps live in node_modules, not lib/.
if [ -f "$DEST/package.json" ] && [ ! -d "$DEST/node_modules" ]; then
  ( cd "$DEST" && { npm ci 2>/dev/null || npm install 2>/dev/null; } ) \
    || echo "fetch-target: npm install skipped/failed (pure-Foundry project, or no registry access)" >&2
fi

echo "fetch-target: $URL -> $DEST"
echo "  foundry.toml: $( [ -f "$DEST/foundry.toml" ] && echo yes || echo no )  remappings.txt: $( [ -f "$DEST/remappings.txt" ] && echo yes || echo no )  lib/: $( [ -d "$DEST/lib" ] && echo yes || echo no )  node_modules/: $( [ -d "$DEST/node_modules" ] && echo yes || echo no )"
