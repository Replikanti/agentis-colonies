#!/bin/bash
# tools/migrate-to-multi-repo.sh: rewrite a legacy [forge.github] block
# into a single [[forge.github]] entry. Idempotent. Preserves comments
# and operator hand-edits.
#
# Re-runs on an already-migrated file print "already migrated" and exit
# 0 without modifying the file. Refuses to touch a config that contains
# both forms (`colony-lint.sh` lints that case first).
#
# Usage: ./tools/migrate-to-multi-repo.sh <path/to/colony.toml>
#        ./tools/migrate-to-multi-repo.sh --dry-run <path>   # print to stdout
#        ./tools/migrate-to-multi-repo.sh --backup  <path>   # write .bak first
#
# Exit codes:
#   0  migrated (or already migrated; idempotent no-op)
#   1  config has both [forge.github] and [[forge.github]] — manual fix needed
#   2  usage error (incl. file not found)
#   3  no [forge.github] block found at all (config predates ADR-0002)
#
# Implementation: pure-Python sibling helper invoked via `exec python3`.
# No inline heredocs (#172 / #245 / #271 macOS bash 3.2 parser bug, same
# precedent as parse-toml.sh delegating to parse-toml-secret.py).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/migrate-to-multi-repo.py"

if [ ! -f "$HELPER" ]; then
    echo "migrate-to-multi-repo: helper not found: $HELPER" >&2
    exit 2
fi

exec python3 "$HELPER" "$@"
