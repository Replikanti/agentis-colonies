#!/usr/bin/env bash
# check-posix-portability.sh — a ratchet for BSD/macOS-divergent shell constructs.
#
# WHY
#   macOS ships a BSD userland and bash 3.2. Constructs that are unremarkable on
#   GNU either fail outright there or, worse, do something different. Three
#   examples this repository actually shipped:
#     * a Perl-regex grep flag in a runtime pipeline — BSD grep does not have
#       it at all, so the federation could not complete a run on macOS (#2080).
#     * in-place sed with no suffix in both scaffolders — BSD requires a suffix
#       argument, so the expression became the backup suffix and the target file
#       became the script. The scaffolder corrupted the file it was filling in.
#     * a `case` inside `$( … )` in colony-lint.sh itself — bash 3.2 cannot parse
#       it, so the repo's own mandatory gate was unrunnable on macOS (#2082).
#
#   None of these were caught, because nothing checked: the bash-3.2 lint covered
#   two files and CI runs ubuntu-latest only.
#
# THE RATCHET (mirrors tools/check-substrate-purity.sh)
#   Two finding classes, so the debt can only shrink:
#     [NEW-VIOLATION]   a construct not on the allowlist            -> fail
#     [STALE-ALLOWLIST] an allowlist row whose site is already fixed -> fail
#   The second is what makes it a ratchet rather than a snapshot: you cannot
#   fix a site and leave its row behind, so the list tracks reality.
#
#   Allowlist: tools/posix-portability-allowlist.txt, one `path:pattern` per line.
#   Inline waiver for a site that genuinely cannot move:
#     # posix-portability: deferred (<reason>)
#   on the line above. Prefer fixing; a waiver with no reason is not a waiver.
#
# Exit: 0 clean, 1 findings, 2 usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALLOWLIST="$SCRIPT_DIR/posix-portability-allowlist.txt"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: check-posix-portability.sh [--list]"
    echo "  --list  print current violations as allowlist rows (for seeding)"
    exit 0
fi

# The rule table lives in a sibling data file rather than inline: the patterns
# are literal instances of the constructs they match, so an inline table made
# this checker match its own source.
RULES_FILE="$SCRIPT_DIR/posix-portability-rules.txt"
if [ ! -f "$RULES_FILE" ]; then
    echo "check-posix-portability: missing rule table $RULES_FILE" >&2
    exit 2
fi
RULES="$(grep -vE '^[[:space:]]*(#|$)' "$RULES_FILE")"
if [ -z "$RULES" ]; then
    echo "check-posix-portability: rule table $RULES_FILE has no rules" >&2
    exit 2
fi

# Tracked shell scripts only — a release must not depend on untracked content,
# and worktrees are copies of the same files.
targets="$(git -C "$REPO_ROOT" ls-files '*.sh' 2>/dev/null)"
if [ -z "$targets" ]; then
    echo "check-posix-portability: no tracked *.sh found under $REPO_ROOT" >&2
    exit 2
fi

allow=""
[ -f "$ALLOWLIST" ] && allow="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" 2>/dev/null || true)"

found=""        # rows we saw, as path:id
findings=0
stale=0

for rel in $targets; do
    f="$REPO_ROOT/$rel"
    [ -f "$f" ] || continue
    # Drop comment-only lines so a rule's own documentation does not trip it.
    cleaned="$(sed -e 's/^[[:space:]]*#.*//' "$f")"
    printf '%s\n' "$RULES" | while IFS='|' read -r id pat why; do
        [ -n "$id" ] || continue
        printf '%s\n' "$cleaned" | grep -nE -- "$pat" >/dev/null 2>&1 || continue
        # An inline waiver on the preceding line exempts the site.
        if grep -B1 -E -- "$pat" "$f" 2>/dev/null | grep -q 'posix-portability: deferred'; then
            continue
        fi
        printf '%s:%s|%s\n' "$rel" "$id" "$why"
    done
done > "${TMPDIR:-/tmp}/pp.$$" 2>/dev/null

if [ "${1:-}" = "--list" ]; then
    cut -d'|' -f1 < "${TMPDIR:-/tmp}/pp.$$" | sort -u
    rm -f "${TMPDIR:-/tmp}/pp.$$"
    exit 0
fi

while IFS='|' read -r row why; do
    [ -n "$row" ] || continue
    found="$found $row"
    if ! printf '%s\n' "$allow" | grep -qxF "$row"; then
        echo "[NEW-VIOLATION] $row"
        echo "                $why"
        findings=$((findings + 1))
    fi
done < "${TMPDIR:-/tmp}/pp.$$"
rm -f "${TMPDIR:-/tmp}/pp.$$"

# The ratchet half: a row that no longer matches anything must be removed.
if [ -n "$allow" ]; then
    printf '%s\n' "$allow" | while IFS= read -r row; do
        [ -n "$row" ] || continue
        case " $found " in
            *" $row "*) ;;
            *) echo "[STALE-ALLOWLIST] $row — site is fixed; delete this row" ;;
        esac
    done > "${TMPDIR:-/tmp}/pps.$$"
    stale="$(wc -l < "${TMPDIR:-/tmp}/pps.$$" | tr -d ' ')"
    [ "$stale" -gt 0 ] && cat "${TMPDIR:-/tmp}/pps.$$"
    rm -f "${TMPDIR:-/tmp}/pps.$$"
fi

total=$((findings + stale))
if [ "$total" -gt 0 ]; then
    echo "check-posix-portability: $findings new, $stale stale — see $ALLOWLIST"
    exit 1
fi
echo "check-posix-portability: clean ($(printf '%s\n' "$allow" | grep -c . || echo 0) allowlisted)"
exit 0
