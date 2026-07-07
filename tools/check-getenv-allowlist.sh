#!/bin/bash
# tools/check-getenv-allowlist.sh: Flag getenv() operator knobs that the
# install.sh exec.env_passthrough allowlist does not register.
#
# getenv() in a `.ag` reads the SANITIZED env: the daemon strips every var
# not on the `exec.env_passthrough` allowlist before the runtime sees it,
# while `/proc/<pid>/environ` still shows the full exec-time env — so the
# gap is invisible to inspection. A getenv-read operator knob that is not
# on the allowlist written by dev-apprenticeship/install.sh is silently
# inert: the export is accepted, nothing errors, and the default applies.
# Proven live on the #1424 burn-in (AG_DRIVEN_EDIT_LOOP, fixed in #1426);
# the same class hit QA_ADVERSARIAL_LLM_CMD and CODE_EDIT_MAX_ATTEMPTS
# (audited and fixed in #1428). This lint keeps the class closed: the next
# getenv-read knob cannot ship unregistered.
#
# Rules (scope: dev-apprenticeship only — other federations own their
# config story; extend per-federation when they grow an allowlist):
#   1. Every `getenv("X")` in `dev-apprenticeship/*/agents/*.ag` must have
#      X either (a) named on the `write_key 'exec.env_passthrough' '...'`
#      literal in dev-apprenticeship/install.sh, (b) covered by a
#      trailing-`*` glob entry on that literal (e.g. GITLAB_*), or
#      (c) explicitly waived with `// colony-lint: getenv-unregistered-ok`
#      on the getenv line or the preceding line. Prefer registration; use
#      the waiver only for a var that is deliberately NOT an operator knob
#      (e.g. set programmatically by another allowlisted mechanism).
#   2. Every named (non-glob, non-waived) getenv var must also appear in
#      the #1437 residue-check `for knob in ...` list in install.sh, so
#      the loud warning on hand-customized allowlists can never lag the
#      real getenv surface.
#
# This is a grep/awk-level check, not a full parser. `//` line comments
# are stripped before matching; getenv calls with a non-literal argument
# (none exist today) are not seen.
#
# Usage: ./tools/check-getenv-allowlist.sh [repo-root]
# Exit 0 if clean, 1 if one or more findings, 2 on usage error.

set -euo pipefail

SCAN_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ ! -d "$SCAN_ROOT" ]; then
    echo "check-getenv-allowlist: scan root does not exist: $SCAN_ROOT" >&2
    exit 2
fi

FED_DIR="$SCAN_ROOT/dev-apprenticeship"
INSTALL_SH="$FED_DIR/install.sh"

if [ ! -f "$INSTALL_SH" ]; then
    echo "check-getenv-allowlist: $INSTALL_SH not found" >&2
    exit 2
fi

FAIL=0

# --- Extract the allowlist literal from the write_key line -----------------
# Single source of truth: the fresh-install default install.sh writes. The
# migration-chain literals above it are historical and deliberately ignored.
ALLOWLIST="$(sed -nE "s/^[[:space:]]*write_key 'exec\.env_passthrough'[[:space:]]+'([^']*)'.*$/\1/p" "$INSTALL_SH" | tail -1)"

if [ -z "$ALLOWLIST" ]; then
    echo "check-getenv-allowlist: no \"write_key 'exec.env_passthrough' '...'\" line found in $INSTALL_SH" >&2
    exit 2
fi

# --- Extract the #1437 residue-check knob list ------------------------------
# The `for knob in A B C \ ... Z; do` list (may span continuation lines).
RESIDUE_LIST="$(awk '
    /for knob in/ { collecting = 1 }
    collecting {
        line = $0
        sub(/;[[:space:]]*do.*$/, "", line)
        n = split(line, w, /[[:space:]\\]+/)
        for (i = 1; i <= n; i++) {
            if (w[i] ~ /^[A-Z][A-Z0-9_]*$/) print w[i]
        }
        if ($0 ~ /;[[:space:]]*do/) exit
    }
' "$INSTALL_SH")"

# in_allowlist <var>: 0 if var is named on the allowlist or matched by a
# trailing-* glob entry, 1 otherwise.
in_allowlist() {
    local var="$1" entry prefix
    local IFS=','
    for entry in $ALLOWLIST; do
        case "$entry" in
            *\*)
                prefix="${entry%\*}"
                if [ "${var#"$prefix"}" != "$var" ]; then return 0; fi
                ;;
            "$var") return 0 ;;
        esac
    done
    return 1
}

# named_in_allowlist <var>: 0 only on an exact-name allowlist entry. A
# glob-covered var (e.g. GITLAB_FOO under GITLAB_*) is registered but has
# no static name to keep in the residue list, so rule 2 skips it.
named_in_allowlist() {
    local var="$1" entry
    local IFS=','
    for entry in $ALLOWLIST; do
        [ "$entry" = "$var" ] && return 0
    done
    return 1
}

in_residue_list() {
    local var="$1"
    printf '%s\n' "$RESIDUE_LIST" | grep -qxF "$var"
}

# --- Scan the .ag files -----------------------------------------------------
# Emits `file:line:VAR` per non-waived getenv() read.
scan_file() {
    awk -v file="$1" '
    {
        clean = $0
        sub(/\/\/.*$/, "", clean)
        rest = clean
        while (match(rest, /getenv[[:space:]]*\("[A-Za-z_][A-Za-z_0-9]*"\)/)) {
            tok = substr(rest, RSTART, RLENGTH)
            var = tok
            sub(/^getenv[[:space:]]*\("/, "", var)
            sub(/"\)$/, "", var)
            waived = 0
            # Waiver check uses the ORIGINAL lines so the annotation is
            # visible. The trailing boundary class blocks typo-suffixes
            # (e.g. `getenv-unregistered-okey`) from suppressing the check.
            if ($0 ~ /colony-lint:[[:space:]]*getenv-unregistered-ok($|[[:space:]]|[^a-z0-9-])/) waived = 1
            else if (prev ~ /colony-lint:[[:space:]]*getenv-unregistered-ok($|[[:space:]]|[^a-z0-9-])/) waived = 1
            if (!waived) printf "%s:%d:%s\n", file, NR, var
            rest = substr(rest, RSTART + RLENGTH)
        }
        prev = $0
    }
    ' "$1"
}

# Track vars already reported for the residue-list rule so a knob read by
# several agents is reported once, not per read site.
RESIDUE_REPORTED=""

while IFS= read -r -d '' f; do
    while IFS= read -r finding; do
        [ -n "$finding" ] || continue
        file="${finding%%:*}"
        rest="${finding#*:}"
        line="${rest%%:*}"
        var="${rest#*:}"

        if ! in_allowlist "$var"; then
            printf '[UNREGISTERED] %s:%s: getenv("%s") is not on the install.sh exec.env_passthrough allowlist — the knob is silently inert (register it in dev-apprenticeship/install.sh or annotate with `// colony-lint: getenv-unregistered-ok`)\n' "$file" "$line" "$var"
            FAIL=$((FAIL + 1))
        elif named_in_allowlist "$var" && ! in_residue_list "$var"; then
            case " $RESIDUE_REPORTED " in
                *" $var "*) ;;
                *)
                    printf '[RESIDUE-DRIFT] %s: getenv knob "%s" is allowlisted but missing from the install.sh #1437 residue-check `for knob in ...` list — hand-customized allowlists would miss the loud warning\n' "$INSTALL_SH" "$var"
                    RESIDUE_REPORTED="$RESIDUE_REPORTED $var"
                    FAIL=$((FAIL + 1))
                    ;;
            esac
        fi
    done < <(scan_file "$f")
done < <(find "$FED_DIR" -type f -path '*/agents/*.ag' -print0)

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "check-getenv-allowlist: $FAIL finding(s)"
    exit 1
fi

exit 0
