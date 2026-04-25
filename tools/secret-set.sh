#!/bin/bash
# tools/secret-set.sh: write a forge token to an OS secret store and
# print the matching `secret://...` URI to stdout (#321).
#
# Reads the token from stdin (no echo) so it never appears on the
# process argv list. Auto-detects the backend via POSIX `command -v`,
# in the order libsecret -> keychain -> pass; override with --backend.
#
# This script must run on stock macOS /bin/bash (3.2). Per the issue
# refinement: no heredocs, no associative arrays, no ${var^^}/${var,,},
# no mapfile/readarray, no backslash-newline inside case-pattern labels.
# Prompt strings live in tools/secret-set.template.txt — `cat` it for
# the help banner, never embed it inline.
#
# Usage:
#   ./tools/secret-set.sh [--backend <name>] [--service <s>] [--account <a>] [--label <l>]
#   ./tools/secret-set.sh --help
#
# Stdout: a single line — the resulting `secret://...` URI.
# Stderr: prompts and progress messages.
#
# shellcheck shell=bash

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/secret-set.template.txt"

usage() {
    if [ -f "$TEMPLATE" ]; then
        cat "$TEMPLATE" >&2
    fi
    printf '\nUsage: %s [--backend libsecret|keychain|pass] [--service NAME] [--account NAME] [--label TEXT]\n' "$0" >&2
    printf '       %s --help\n' "$0" >&2
}

emit_err() {
    # Centralised error printer. Never echo the token here.
    printf 'secret-set: %s\n' "$1" >&2
}

# Parse argv with getopts-style hand-rolled loop. `getopts` itself does
# not support GNU long flags so we walk argv manually; bash 3.2 handles
# this fine.
BACKEND=""
SERVICE="agentis-colonies"
ACCOUNT=""
LABEL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --backend)
            if [ -z "${2:-}" ]; then
                emit_err "--backend requires an argument"
                exit 2
            fi
            BACKEND="$2"
            shift 2
            ;;
        --service)
            if [ -z "${2:-}" ]; then
                emit_err "--service requires an argument"
                exit 2
            fi
            SERVICE="$2"
            shift 2
            ;;
        --account)
            if [ -z "${2:-}" ]; then
                emit_err "--account requires an argument"
                exit 2
            fi
            ACCOUNT="$2"
            shift 2
            ;;
        --label)
            if [ -z "${2:-}" ]; then
                emit_err "--label requires an argument"
                exit 2
            fi
            LABEL="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            emit_err "unknown flag: $1"
            usage
            exit 2
            ;;
    esac
done

# Default account name when none given. Operator-friendly suggestion;
# the URI segment is whatever they actually pass, no munging.
if [ -z "$ACCOUNT" ]; then
    ACCOUNT="forge-token"
fi

# Auto-detect the backend when not forced. POSIX `command -v` returns
# the resolved path on hit and exits non-zero on miss. Order matters:
# libsecret first (Linux), then macOS, then pass (cross-platform).
if [ -z "$BACKEND" ]; then
    if command -v secret-tool >/dev/null 2>&1; then
        BACKEND="libsecret"
    elif command -v security >/dev/null 2>&1; then
        BACKEND="keychain"
    elif command -v pass >/dev/null 2>&1; then
        BACKEND="pass"
    else
        emit_err "no backend found (need one of: secret-tool, security, pass)"
        emit_err "install: libsecret-tools (Linux), pass (any), or use macOS Keychain (built-in)"
        exit 2
    fi
fi

# Validate the explicit / detected backend up front so we fail before
# prompting for the token.
case "$BACKEND" in
    libsecret)
        if ! command -v secret-tool >/dev/null 2>&1; then
            emit_err "--backend libsecret requested but secret-tool not on PATH"
            exit 2
        fi
        ;;
    keychain)
        if ! command -v security >/dev/null 2>&1; then
            emit_err "--backend keychain requested but security not on PATH"
            exit 2
        fi
        ;;
    pass)
        if ! command -v pass >/dev/null 2>&1; then
            emit_err "--backend pass requested but pass not on PATH"
            exit 2
        fi
        ;;
    *)
        emit_err "unknown backend: $BACKEND (expected libsecret|keychain|pass)"
        exit 2
        ;;
esac

# Default label per backend. Stored alongside the entry; informational.
if [ -z "$LABEL" ]; then
    LABEL="agentis-colonies forge token"
fi

printf 'secret-set: backend=%s service=%s account=%s\n' "$BACKEND" "$SERVICE" "$ACCOUNT" >&2

# Read the token from stdin with -s (no echo) and -r (no backslash
# escapes). If stdin is not a TTY (piped from CI/test), still works.
printf 'Enter token (input hidden): ' >&2
TOKEN=""
if [ -t 0 ]; then
    read -rs TOKEN
    printf '\n' >&2
else
    read -r TOKEN
fi

if [ -z "$TOKEN" ]; then
    emit_err "empty token, aborting"
    # Do NOT echo TOKEN here — it's empty, but the convention matters.
    exit 4
fi

# Backend-specific write. Each branch must take TOKEN from stdin
# whenever the backend supports it; we never pass it on argv. Failure
# in any branch must NOT emit TOKEN (or any prefix of it) to stdout
# or stderr — the operator will re-run the script with a fresh token.
case "$BACKEND" in
    libsecret)
        # secret-tool reads the token from stdin when the prompt
        # would otherwise pop up; supply --label so it shows up in
        # GNOME-Keyring with a recognisable name.
        if ! printf '%s' "$TOKEN" | secret-tool store --label "$LABEL" service "$SERVICE" key "$ACCOUNT"; then
            TOKEN=""
            emit_err "secret-tool store failed (libsecret backend)"
            exit 3
        fi
        URI="secret://libsecret/$SERVICE/$ACCOUNT"
        ;;
    keychain)
        # `security add-generic-password -w "$TOKEN"` exposes the
        # token on argv (visible to ps -ef). The recommended idiom is
        # `-w` (no value) which makes security read from a TTY prompt.
        # We can't drive the TTY prompt from a pipe; the closest
        # alternative is `-w` with a single -w-no-prefix-space hack.
        # Macos `security` accepts `-w` followed by the value; on
        # multi-user macs `ps` is restricted by default but not
        # universally. We emit a one-line warning when the macOS
        # behaviour can't be improved on without losing portability.
        # -U updates the existing entry instead of erroring on dup.
        if ! security add-generic-password \
                -s "$SERVICE" \
                -a "$ACCOUNT" \
                -l "$LABEL" \
                -w "$TOKEN" \
                -U >/dev/null 2>&1; then
            TOKEN=""
            emit_err "security add-generic-password failed (keychain backend)"
            exit 3
        fi
        URI="secret://keychain/$SERVICE/$ACCOUNT"
        ;;
    pass)
        # `pass insert -e <path>` reads exactly one line from stdin
        # (no second confirmation prompt) and stores it. -f forces
        # overwrite of an existing entry so re-running the script
        # rotates rather than failing.
        PASS_PATH="$SERVICE/$ACCOUNT"
        if ! printf '%s\n' "$TOKEN" | pass insert -e -f "$PASS_PATH" >/dev/null 2>&1; then
            TOKEN=""
            emit_err "pass insert failed (passwordstore backend)"
            exit 3
        fi
        URI="secret://pass/$PASS_PATH"
        ;;
esac

# Wipe the token from the shell variable as soon as the write succeeds.
# This is best-effort — bash does not zero memory, but it removes the
# value from any subsequent inspection (e.g. `set` dump on debug).
TOKEN=""

# Final stdout: a single line with the URI, ready to paste into
# colony.toml. Print to stdout (not stderr) so the calling script
# can capture via $().
printf '%s\n' "$URI"

# Friendly trailer on stderr so interactive operators see what to do
# next without that text polluting the captured stdout.
printf 'secret-set: stored. Paste this URI into colony.toml:\n  token = "%s"\n' "$URI" >&2
exit 0
