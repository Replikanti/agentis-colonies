#!/usr/bin/env bash
# detect-toolchain.sh — pick the PoC toolchain for a target project by file presence (#1507).
#
# The single point where a caller (run-poc.sh, and later #1509's coordinator) chooses hardhat-vs-forge and sets
# POC_KIND / POC_HARNESS / POC_OUT accordingly. Pure file-presence, offline, deterministic — no npm, no forge.
#
#   hardhat.config.{js,ts,cjs,mjs} present  -> echo "hardhat"  exit 0
#   else foundry.toml present               -> echo "foundry"  exit 0
#   else                                     -> echo "unknown"  exit 3
#
# hardhat is checked FIRST: a project may carry BOTH (a hardhat+foundry hybrid) and the concrete-PoC hardhat path
# is the one this class of target uses. Usage:  detect-toolchain.sh <repo>
set -uo pipefail

REPO="${1:-}"
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "detect-toolchain: usage: detect-toolchain.sh <project-root>" >&2; exit 2; }

for _c in hardhat.config.js hardhat.config.ts hardhat.config.cjs hardhat.config.mjs; do
  if [ -f "$REPO/$_c" ]; then echo "hardhat"; exit 0; fi
done
if [ -f "$REPO/foundry.toml" ]; then echo "foundry"; exit 0; fi
echo "unknown"; exit 3
