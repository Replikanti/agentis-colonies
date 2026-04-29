#!/bin/bash
# tools/cross-repo-grep.sh: cross-repo reference detection for code-review.
#
# Thin shim around tools/cross-repo-grep.py — a separate `.sh` exists so
# `.ag` agents can `exec sh "$COLONY_DIR/../../tools/cross-repo-grep.sh"`
# from a path they can compose without knowing the python interpreter or
# argv layout. All logic lives in the python sibling to dodge the macOS
# bash 3.2 heredoc parser bug (#172, #245, #271) and to keep the regex
# batching + capping in one place.
#
# Inputs (env, NOT argv — argv is reserved for future expansion):
#   DIFF_INPUT_FILE       Diff JSON spool to scan. Stdin when unset.
#   CROSS_REPO_REPOS      CSV of `<owner>/<repo>` allowlist entries.
#   CROSS_REPO_REPO_PATHS CSV of absolute checkout paths, parallel
#                         to CROSS_REPO_REPOS.
#   CROSS_REPO_ACTIVE     `<owner>/<repo>` of the active repo (filtered
#                         out of the sibling list).
#   CROSS_REPO_MAX_REFS   Cap on emitted match blocks. Default 10.
#   CROSS_REPO_MAX_LINES  Cap on total emitted context lines. Default 200.
#
# Output (stdout): empty when disabled / no refs / on degrade-to-empty
# error paths. Otherwise a `Cross-repo references (N refs, M repos):`
# header followed by one block per match.
#
# Exit codes:
#   0 ok (including the empty-stdout no-refs case — caller treats as no context)
#   2 CROSS_REPO_REPO_PATHS / CROSS_REPO_REPOS length mismatch (operator config bug)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/cross-repo-grep.py" "$@"
