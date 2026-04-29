#!/bin/bash
# tools/cross-repo-cache.sh: read-with-TTL + atomic-write helper for the
# `<fed>/.agentis/cross-repo-cache/<owner>__<repo>__<N>.json` records (#317).
#
# Two verbs:
#   get  --colony-dir <dir> <owner> <repo> <number>
#        Reads the cache record. Empty stdout when missing OR when the
#        record's age exceeds TTL. Exit 0 on hit, 1 on miss/expired, 2 on
#        usage / arg error. Tokens never appear in the record (test 6
#        enforces).
#
#   put  --colony-dir <dir> <owner> <repo> <number>
#        Reads the record JSON from stdin and atomically writes it to the
#        cache key (tmp + rename, owner of caller). Caller is responsible
#        for shape validation; this helper is a dumb sink.
#
# TTL: configurable via `CROSS_REPO_CACHE_TTL_SECS` env (default 3600).
#
# Thin shim around tools/cross-repo-cache.py — all logic lives in the
# python sibling so this script stays macOS bash 3.2 portable (no
# heredocs, no GNU-only flags). Same shape as iter-repos.sh.
#
# Exit codes:
#   0  ok (record on stdout, or write succeeded)
#   1  miss or expired
#   2  usage error / malformed args

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/cross-repo-cache.py" "$@"
