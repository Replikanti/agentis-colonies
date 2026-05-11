#!/bin/bash
# check-agentis-version.sh — refuses install or start when the agentis
# runtime is older than v1.7.10 (the floor where prompt() accepts a
# non-literal string expression as first argument — required by M98 v3
# memo-stored hunting prompts in #520; agentis-core #638).
#
# Earlier floors:
#   v1.5.0 — knowledge_buy / knowledge_sell ship as .ag builtins (#393)
#   v1.7.10 — prompt() first-arg parser accepts non-literal expressions (#520, agentis-core #638)
#
# Usage: check-agentis-version.sh
#
# Exit 0  : version >= 1.7.10
# Exit 78 : EX_CONFIG, version too low or unparseable
#
# Bash 3.2 portable (no mapfile, no `${var,,}`, no GNU-only sed). The
# SemVer comparison is delegated to a python3 one-liner so we do not
# need to depend on `sort -V`.

set -eu

REQUIRED="1.7.10"
RELEASE_URL="https://github.com/Replikanti/agentis/releases/tag/v1.7.10"
RUNTIME_DOWNLOAD_URL="https://github.com/Replikanti/agentis"

if ! command -v agentis >/dev/null 2>&1; then
    echo "check-agentis-version: agentis CLI not on PATH" >&2
    echo "" >&2
    echo "  The agentis runtime is a proprietary closed source binary" >&2
    echo "  distributed for free for Linux and macOS at:" >&2
    echo "" >&2
    echo "    ${RUNTIME_DOWNLOAD_URL}" >&2
    echo "" >&2
    echo "  Download the binary for your platform, place it on your PATH," >&2
    echo "  then re-run this command. tribes-bench requires agentis >= ${REQUIRED}." >&2
    echo "" >&2
    exit 1
fi

raw="$(agentis --version 2>/dev/null || true)"
ver="$(printf '%s' "$raw" | sed -n 's/^agentis v\([0-9][0-9.]*\).*$/\1/p' | head -1)"

if [ -z "$ver" ]; then
    echo "check-agentis-version: could not parse 'agentis --version' output: ${raw}" >&2
    echo "                       require agentis >= ${REQUIRED}: ${RELEASE_URL}" >&2
    exit 78
fi

if ! python3 -c "
import sys
def parse(v):
    return tuple(int(x) for x in v.split('.'))
sys.exit(0 if parse('${ver}') >= parse('${REQUIRED}') else 1)
" 2>/dev/null; then
    echo "check-agentis-version: agentis v${ver} is too old (require >= ${REQUIRED})" >&2
    echo "                       upgrade: ${RELEASE_URL}" >&2
    exit 78
fi

exit 0
