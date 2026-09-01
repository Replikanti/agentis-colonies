#!/usr/bin/env bash
# check-posix-portability.sh — a ratchet for BSD/macOS-divergent shell constructs.
#
# WHY
#   macOS ships a BSD userland and bash 3.2. Constructs that are unremarkable on
#   GNU either fail outright there or, worse, do something different. Four
#   examples this repository actually shipped:
#     * a Perl-regex grep flag in a runtime pipeline — BSD grep does not have
#       it at all, so the federation could not complete a run on macOS (#2080).
#     * in-place sed with no suffix in both scaffolders — BSD requires a suffix
#       argument, so the expression became the backup suffix and the target file
#       became the script. The scaffolder corrupted the file it was filling in.
#     * a `case` inside a command substitution in colony-lint.sh itself — bash
#       3.2 cannot parse it, so the repo's own mandatory gate was unrunnable on
#       macOS (#2082).
#     * GNU-only case-conversion escapes in new-colony.sh, which silently
#       produced "code review" instead of "Code Review" on BSD.
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
#   Waiver for a site that genuinely cannot move, on the SAME line or the line
#   immediately above it:
#     # posix-portability: deferred (<reason>)
#   The reason is mandatory and must be non-empty — a bare `deferred` waives
#   nothing. A waiver silences ONE line, not every other match in the file.
#
# FAILURE POSTURE
#   Every path that cannot complete the check exits non-zero. This tool guards a
#   platform CI does not run, so a version of it that quietly passed when it
#   could not do its job would be worse than not having it at all.
#
# Exit: 0 clean, 1 findings, 2 cannot run (usage, missing rule table, no targets).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALLOWLIST="$SCRIPT_DIR/posix-portability-allowlist.txt"

MODE=check
case "${1:-}" in
    ("") ;;
    (-h|--help)
        echo "Usage: check-posix-portability.sh [--list]"
        echo "  --list  print current violations as allowlist rows (for seeding)"
        exit 0
        ;;
    (--list) MODE=list ;;
    (*)
        echo "check-posix-portability: unknown option '$1'" >&2
        echo "Usage: check-posix-portability.sh [--list]" >&2
        exit 2
        ;;
esac

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

# Prefer the git index — a release must not depend on untracked content — but
# fall back to the filesystem outside a git tree (an extracted bundle) rather
# than reporting a failure that really means "wrong directory".
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    targets="$(git -C "$REPO_ROOT" ls-files '*.sh')"
    source_desc="git index"
else
    targets="$(cd "$REPO_ROOT" && find . -name '*.sh' -type f | sed 's|^\./||')"
    source_desc="filesystem, not a git tree"
fi
if [ -z "$targets" ]; then
    echo "check-posix-portability: no *.sh found under $REPO_ROOT ($source_desc)" >&2
    exit 2
fi

allow=""
[ -f "$ALLOWLIST" ] && allow="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" 2>/dev/null || true)"

# Is the construct on line $2 of file $1 waived? The waiver must carry a
# non-empty reason, and it silences only this line.
is_waived() {
    _f="$1"; _n="$2"
    _ctx="$(sed -n "${_n}p" "$_f")"
    if [ "$_n" -gt 1 ]; then
        _ctx="$_ctx
$(sed -n "$((_n - 1))p" "$_f")"
    fi
    printf '%s\n' "$_ctx" | grep -qE 'posix-portability: deferred \([^)]+\)'
}

# One alternation of every rule pattern, used only to decide whether a file is
# worth the per-rule pass. Without it this walks ~700 files x 12 rules and the
# mandatory lint gets minutes slower for nothing, since almost every file
# matches no rule at all.
ANY_RULE="$(
    printf '%s\n' "$RULES" | while IFS= read -r _l; do
        _p="${_l#*|}"; _p="${_p%|*}"
        [ -n "$_p" ] && printf '(%s)|' "$_p"
    done
)"
ANY_RULE="${ANY_RULE%|}"

# Emit `path:id|why` for each rule with at least one UNWAIVED match in the file.
scan_file() {
    _rel="$1"; _f="$2"
    grep -qE -- "$ANY_RULE" "$_f" 2>/dev/null || return 0
    # Only pay for per-line waiver lookups in files that actually carry one.
    _has_waiver=no
    grep -q 'posix-portability: deferred' "$_f" 2>/dev/null && _has_waiver=yes
    # Blank comment-only lines so a rule's own prose does not trip it. Blanking
    # rather than deleting keeps line numbers aligned with the real file, which
    # the per-line waiver lookup depends on.
    _cleaned="$(sed 's/^[[:space:]]*#.*//' "$_f")"
    printf '%s\n' "$RULES" | while IFS= read -r _line; do
        # Split on the FIRST and LAST separator, not every one: the pattern
        # field routinely contains `|` as regex alternation, and a plain
        # `IFS='|' read` would truncate it mid-pattern. Ids and reasons carry
        # no `|`, so the outer two boundaries are unambiguous.
        _id="${_line%%|*}"
        _why="${_line##*|}"
        _pat="${_line#*|}"
        _pat="${_pat%|*}"
        [ -n "$_id" ] || continue
        _hits="$(printf '%s\n' "$_cleaned" | grep -nE -- "$_pat" 2>/dev/null | cut -d: -f1)"
        [ -n "$_hits" ] || continue
        if [ "$_has_waiver" = no ]; then
            printf '%s:%s|%s\n' "$_rel" "$_id" "$_why"
            continue
        fi
        for _n in $_hits; do
            if is_waived "$_f" "$_n"; then continue; fi
            printf '%s:%s|%s\n' "$_rel" "$_id" "$_why"
            break
        done
    done
}

# No temp files. A checker that keeps its findings in a file under $TMPDIR
# reports "clean" when that directory is not writable, which is the one answer
# it must never give by accident.
all_findings="$(
    printf '%s\n' "$targets" | while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        f="$REPO_ROOT/$rel"
        [ -f "$f" ] || continue
        scan_file "$rel" "$f"
    done
)"

if [ "$MODE" = list ]; then
    printf '%s\n' "$all_findings" | grep -v '^$' | cut -d'|' -f1 | sort -u
    exit 0
fi

found=""
findings=0
# A heredoc, not a pipe: the loop must run in this shell, or the counters are
# incremented in a subshell and lost.
while IFS='|' read -r row why; do
    [ -n "$row" ] || continue
    found="$found $row"
    if ! printf '%s\n' "$allow" | grep -qxF "$row"; then
        echo "[NEW-VIOLATION] $row"
        echo "                $why"
        findings=$((findings + 1))
    fi
done <<FINDINGS
$all_findings
FINDINGS

# The ratchet half: a row that no longer matches anything must be removed.
stale=0
while IFS= read -r row; do
    [ -n "$row" ] || continue
    case " $found " in
        (*" $row "*) ;;
        (*)
            echo "[STALE-ALLOWLIST] $row — site is fixed; delete this row"
            stale=$((stale + 1))
            ;;
    esac
done <<STALEROWS
$allow
STALEROWS

allow_count=0
if [ -n "$allow" ]; then
    allow_count="$(printf '%s\n' "$allow" | grep -c .)"
fi

total=$((findings + stale))
if [ "$total" -gt 0 ]; then
    echo "check-posix-portability: $findings new, $stale stale — see $ALLOWLIST"
    exit 1
fi
echo "check-posix-portability: clean ($allow_count allowlisted, scanned $source_desc)"
exit 0
