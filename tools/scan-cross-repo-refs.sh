#!/bin/bash
# tools/scan-cross-repo-refs.sh: pure regex scanner that extracts every
# `<owner>/<repo>#<N>` cross-repo reference appearing on stdin (a PR body
# blob, a comment, a description — anything textual). One ref per line on
# stdout, deduped (first-seen order preserved), code-ref forms (`#L42`,
# `path/to/file:42`, etc.) filtered out.
#
# Thin shim around tools/scan-cross-repo-refs.py — a separate `.sh` exists
# so `.ag` agents can `exec sh "$COLONY_DIR/../../tools/scan-cross-repo-refs.sh"`
# from a path they can compose without knowing the python interpreter or
# argv layout. All logic lives in the python sibling to dodge the macOS
# bash 3.2 heredoc parser bug (#172, #245, #271).
#
# Usage:
#   printf '%s' "$body" | tools/scan-cross-repo-refs.sh
#   printf '%s' "$body" | tools/scan-cross-repo-refs.sh --self acme/backend
#
# `--self <owner>/<repo>` filters self-references (a PR in `acme/backend`
# that mentions `acme/backend#42` — that's not cross-repo, drop it).
#
# Empty stdin -> empty stdout, exit 0. No matches -> empty stdout, exit 0.
# Exit non-zero only on a malformed `--self` value.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/scan-cross-repo-refs.py" "$@"
