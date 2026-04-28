#!/bin/bash
# tools/iter-repos.sh: per-tick fan-out helper that emits one TSV line per repo.
#
# Thin shim around tools/iter-repos.py — a separate `.sh` exists so `.ag`
# agents can `exec sh "$COLONY_DIR/../../tools/iter-repos.sh"` from a path
# they can compose without knowing the python interpreter or argv layout.
# All logic lives in the python sibling to dodge the macOS bash 3.2 heredoc
# parser bug (#172, #245, #271).
#
# Output (stdout): one tab-separated <owner>\t<repo>\t<url>\t<me> line per
# repo, in source order. Empty stdout = no repos to iterate (caller treats
# as no-op tick). Exit 0 always — empty fan-out is not an error.
#
# Sources of truth, in order of precedence:
#   1. GITHUB_REPOS_JSON env (set by start-colony.sh on multi-block configs).
#   2. Legacy GITHUB_OWNER/GITHUB_REPO/GITHUB_URL/GITHUB_ME env (set by
#      start-colony.sh on single-block configs and by the multi-block path
#      back-compat-export of entry [0]).
#
# Tokens are intentionally NOT in the spool; the forge-api.sh dispatcher
# resolves them via forge-resolve-repo.py when an agent passes --repo.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/iter-repos.py" "$@"
