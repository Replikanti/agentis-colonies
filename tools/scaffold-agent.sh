#!/usr/bin/env bash
# scaffold-agent.sh — copy a curated `.ag` template into an existing colony
# (#322).
#
# The dedicated entry point for the pre-built agent template catalog under
# `templates/agents/`. Resolves the template, the federation, and the
# colony, then copies `templates/agents/<template>.ag` into
# `<colony>/agents/<local-name>.ag` after performing any
# `__TEMPLATE_VAR__` substitutions the template declares.
#
# Templates currently support two substitution tokens (the v1 canary
# uses neither, but the substitution path is exercised here so PR 2-3
# templates land into a working pipeline):
#     __TEMPLATE_NAME__   the template basename
#     __COLONY_NAME__     the destination colony's directory name
#
# Per CLAUDE.md and the precedent set by tools/auto-promote.sh /
# tools/cost-cap.sh:
#   - bash 3.2 portable (no heredocs, no `declare -A`, no `mapfile`).
#   - federation arg resolves against repo-root first, then as an absolute
#     path.
#   - exit codes: 0 ok, 1 destination conflict, 2 template / federation /
#     colony not found or non-conformant, 3 unknown flag.
#
# Usage:
#   tools/scaffold-agent.sh <template> <federation> <colony> \
#       [--name <local-name>] [--force]
#
# Example:
#   tools/scaffold-agent.sh stale-issue-closer dev-apprenticeship triage
#
# Output:
#   one stdout line `scaffolded <template> -> <colony>/agents/<local-name>.ag`
#   on success.

set -eu

# --- Path resolution (mirrors tools/auto-promote.sh + tools/cost-cap.sh) ---

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TEMPLATES_DIR="$REPO_ROOT/templates/agents"

usage() {
    cat >&2 <<EOF_USAGE
Usage: $0 <template> <federation> <colony> [--name <local-name>] [--force]

  <template>     resolves to $REPO_ROOT/templates/agents/<template>.ag
  <federation>   resolves against $REPO_ROOT/<federation> first, then as
                 an absolute path
  <colony>       resolves as <federation>/<colony> and must contain
                 agents/ + scripts/start-colony.sh

  --name <name>  rename the destination .ag (default: same as <template>)
  --force        overwrite an existing destination

Exit codes: 0 ok, 1 destination conflict, 2 not-found, 3 unknown flag.
EOF_USAGE
}

list_available_templates() {
    if [ ! -d "$TEMPLATES_DIR" ]; then
        echo "(no templates directory at $TEMPLATES_DIR)" >&2
        return
    fi
    found=0
    # POSIX-portable iteration; no `find -printf`, no `mapfile`.
    for f in "$TEMPLATES_DIR"/*.ag; do
        [ -f "$f" ] || continue
        base="${f##*/}"
        echo "  ${base%.ag}" >&2
        found=$((found + 1))
    done
    if [ "$found" -eq 0 ]; then
        echo "  (no templates found)" >&2
    fi
}

if [ $# -lt 3 ]; then
    usage
    exit 2
fi

TEMPLATE="$1"
FED_ARG="$2"
COLONY_ARG="$3"
shift 3

LOCAL_NAME=""
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --name)
            if [ $# -lt 2 ]; then
                echo "scaffold-agent: --name requires a value" >&2
                exit 3
            fi
            LOCAL_NAME="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "scaffold-agent: unknown flag: $1" >&2
            usage
            exit 3
            ;;
    esac
done

# --- Resolve template ---

TEMPLATE_FILE="$TEMPLATES_DIR/$TEMPLATE.ag"
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "scaffold-agent: template not found: $TEMPLATE (looked at $TEMPLATE_FILE)" >&2
    echo "available templates:" >&2
    list_available_templates
    exit 2
fi

# --- Resolve federation (repo-rel first, then absolute) ---

FED_DIR="$REPO_ROOT/$FED_ARG"
if [ ! -d "$FED_DIR" ]; then
    FED_DIR="$FED_ARG"
fi
if [ ! -d "$FED_DIR" ]; then
    echo "scaffold-agent: federation directory not found: $FED_ARG" >&2
    exit 2
fi

# --- Resolve colony (must be conformant per ADR-0003) ---

COLONY_DIR="$FED_DIR/$COLONY_ARG"
if [ ! -d "$COLONY_DIR" ]; then
    echo "scaffold-agent: colony directory not found: $COLONY_ARG (looked at $COLONY_DIR)" >&2
    exit 2
fi
if [ ! -d "$COLONY_DIR/agents" ]; then
    echo "scaffold-agent: colony missing agents/ subdirectory: $COLONY_DIR" >&2
    exit 2
fi
if [ ! -f "$COLONY_DIR/scripts/start-colony.sh" ]; then
    echo "scaffold-agent: colony missing scripts/start-colony.sh (non-conformant per ADR-0003): $COLONY_DIR" >&2
    exit 2
fi

# --- Compute destination ---

if [ -z "$LOCAL_NAME" ]; then
    LOCAL_NAME="$TEMPLATE"
fi
DEST_FILE="$COLONY_DIR/agents/$LOCAL_NAME.ag"

if [ -e "$DEST_FILE" ] && [ "$FORCE" -ne 1 ]; then
    # Repo-relative form for the operator-facing message; falls back to
    # the absolute path when the destination is outside REPO_ROOT.
    case "$DEST_FILE" in
        "$REPO_ROOT"/*) DEST_REL="${DEST_FILE#"$REPO_ROOT"/}" ;;
        *)              DEST_REL="$DEST_FILE" ;;
    esac
    echo "scaffold-agent: agent already exists at $DEST_REL — re-run with --force to overwrite" >&2
    exit 1
fi

# --- Substitution + copy ---
#
# We always pipe through the substitution path (even though the v1 canary
# template declares no tokens) so a PR 2-3 template that introduces
# __TEMPLATE_NAME__ / __COLONY_NAME__ does not need a code change here.
# Two passes via temp file + mv: bash 3.2 / BSD `sed -i ''` portable form,
# kept off the destination until the substitution succeeds so we never
# leave a half-written file in $DEST_FILE.

# Resolve effective colony name from the directory basename so the token
# matches what the operator sees in their colony layout regardless of how
# COLONY_ARG was spelled (with or without trailing slash).
COLONY_NAME="$(basename "$COLONY_DIR")"

# Use python3 for the substitution rather than `sed` so we sidestep the
# BSD-vs-GNU `sed -i` divergence on macOS — matches the precedent set in
# tools/cost-cap.sh and tools/experience-transfer.sh.
TMP_FILE="$DEST_FILE.tmp.$$"
TEMPLATE_FILE="$TEMPLATE_FILE" \
TMP_FILE="$TMP_FILE" \
COLONY_NAME="$COLONY_NAME" \
LOCAL_NAME="$LOCAL_NAME" \
python3 -c '
import os
src = os.environ["TEMPLATE_FILE"]
dst = os.environ["TMP_FILE"]
with open(src, "r", encoding="utf-8") as f:
    body = f.read()
body = body.replace("__TEMPLATE_NAME__", os.environ["LOCAL_NAME"])
body = body.replace("__COLONY_NAME__", os.environ["COLONY_NAME"])
with open(dst, "w", encoding="utf-8") as f:
    f.write(body)
'

mv "$TMP_FILE" "$DEST_FILE"

# --- Stdout: exactly one machine-friendly line ---

case "$DEST_FILE" in
    "$REPO_ROOT"/*) DEST_REL="${DEST_FILE#"$REPO_ROOT"/}" ;;
    *)              DEST_REL="$DEST_FILE" ;;
esac
echo "scaffolded $TEMPLATE -> $DEST_REL"
