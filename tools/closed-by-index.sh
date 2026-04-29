#!/bin/bash
# tools/closed-by-index.sh: federation-shared closed-by index for the
# cross-repo bidirectional surface (#317).
#
# Tracks which PR(s) close which target issue, keyed by
# `<owner>__<repo>__<N>` for the target. Used by router.ag to surface
# "closed by PR ..." hints on unassigned issues.
#
# Two verbs:
#   record --colony-dir <dir> --src-owner <o> --src-repo <r> --src-iid <N>
#                              --tgt-owner <o> --tgt-repo <r> --tgt-iid <N>
#       Idempotent insert on (src, tgt) tuple. flock-protected
#       read-modify-write of `<fed>/.agentis/cross-repo-cache/closed-
#       by-index.json`. Atomic write via tmp+rename.
#
#   lookup --colony-dir <dir> --tgt-owner <o> --tgt-repo <r> --tgt-iid <N>
#       Echo the JSON array of closing-PR objects for the given target.
#       Empty array `[]` if no PRs close it. Exit 0 always (lookup is
#       observational, not a bus probe).
#
# Thin shim around tools/closed-by-index.py — all logic lives in the
# python sibling so this script stays macOS bash 3.2 portable. Same
# shape as iter-repos.sh and cross-repo-cache.sh.
#
# Exit codes:
#   0  ok
#   2  usage error / malformed args

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/closed-by-index.py" "$@"
