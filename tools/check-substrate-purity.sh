#!/bin/bash
# tools/check-substrate-purity.sh: Flag NEW embedded-interpreter one-liners in
# dev-apprenticeship `.ag` agents (the #1587 substrate-purity ratchet).
#
# Agent logic belongs in `.ag`, not inside an embedded `python3 -c` / awk / sed
# one-liner shelled out through `exec sh`. Phase 0 (#1588) purged ~148 legacy
# escapes; the remaining sites are inventoried on the #1587 epic (Phases 1-3,
# rewritten incrementally). This check is the regression-prevention half of the
# ratchet (#1608): it fails the lint the moment a NEW embedded interpreter
# appears in `dev-apprenticeship/*/agents/*.ag` that is neither an existing
# allowlisted site nor annotated with a `// substrate-purity: deferred (<reason>)`
# waiver — so a completed rewrite can only shrink the debt, never silently grow.
#
# Two enforcement directions (the "shrinking-debt" property):
#   [NEW-ESCAPE]      a finding that is neither allowlisted nor waived -> a new
#                     escape slipped in; rewrite it natively or add a waiver.
#   [STALE-ALLOWLIST] an allowlist entry whose file:function no longer produces
#                     a finding -> the site was rewritten; prune its allowlist
#                     row (forces a Phase 2/3 slice to edit this script rather
#                     than leave dead debt behind).
#
# Positive pattern (applied to the comment-stripped line):
#   * `python3 -c '...'`, `python3 - <<'PY'` / `python3 -<<PY` (heredoc)
#   * inline `awk '...'`, `sed '...'` / `sed -E '...'`
# It deliberately does NOT match `python3 "$PATH/apply-edits.py"` or
# `python3 tools/apply-edits.py` (the character after `python3<ws>` is `"` or a
# bareword, not `-`): the LOGIC there lives in a `.py` file, the `.ag` only
# invokes it as a pipe target, which is fine. `exec sh` calls to forge verbs,
# tools/ scripts, and git are likewise out of scope — the rule is about LOGIC
# embedded as an interpreter one-liner, not about invoking mechanical tooling.
#
# Comment stripping is REQUIRED, not polish: ~70 doc-comment lines across the 22
# agents mention `python3 -c` in prose. `//` line comments are stripped before
# any matching (URL-safe form, matching check-getenv-allowlist.sh).
#
# Waiver (`// substrate-purity: deferred (<reason>)`) is honoured when it appears
# either (a) on the line immediately above the finding, or (b) anywhere in the
# contiguous `//`-comment block directly above the enclosing `fn` declaration.
# Rule (b) is required because the one remaining waived Phase-1 site
# (closed_by_context in router.ag) sits above `fn`, several lines before the
# actual `python3 -c` line. (A second waived site, code_writer.ag:numbered_view,
# was deleted outright as dead code in #1607 rather than rewritten.)
#
# KNOWN LIMITATION (grep-level, not a full parser; matches check-exec-sh.sh's
# own documented `+`-splitting caveat): a token deliberately split across a `+`
# concatenation boundary on SEPARATE physical lines (e.g. `"python" + \n "3 -c"`)
# is not caught by this line-level scanner. Flag it in review if seen.
#
# Scope: EVERY */agents/*.ag in the repository, plus templates/agents/*.ag.
#
# It was dev-apprenticeship-only until #2083. That scoping is why the campaign
# looked finished: the one federation the lint could see was clean, while dozens
# of embedded-interpreter lines ran on in tribes-bench and trading-binance, and
# more sat in templates/agents/ — copied into a new colony by
# tools/scaffold-agent.sh on request (NOT by new-colony.sh, which creates an
# empty agents/ directory; an earlier version of this comment said otherwise).
# A lint scoped to one federation does not prevent the mistake; it only stops
# that federation repeating it. Paths are repo-relative.
#
# Usage: ./tools/check-substrate-purity.sh [repo-root]
# Exit 0 if clean, 1 if one or more findings ([NEW-ESCAPE]/[STALE-ALLOWLIST]),
# 2 on usage/infra error.

set -euo pipefail

SCAN_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ ! -d "$SCAN_ROOT" ]; then
    echo "check-substrate-purity: scan root does not exist: $SCAN_ROOT" >&2
    exit 2
fi
# Normalise: `${path#"$SCAN_ROOT"/}` silently fails to strip when the caller
# passes a trailing slash, every relative path stays absolute, the worktree
# exclusion below stops matching, and the scan reports hundreds of spurious
# findings. colony-lint reaches this through its own `${1:-…}`.
SCAN_ROOT="$(cd "$SCAN_ROOT" && pwd)"

# Worktrees are checkouts of the same tracked files; scanning them double-counts
# every finding and makes the allowlist unstable.
# The exclusion must be applied to the path RELATIVE to the scan root: an
# absolute `-not -path '*/worktrees/*'` also excludes every file when the scan
# root is itself inside a worktree, which silently reduces the lint to nothing.
# NUL-delimited throughout: a newline in a path must not be able to split one
# entry into two, which is how the previous newline-delimited version skipped
# such a file silently and still exited 0.
AG_FILES="$(find "$SCAN_ROOT" -type f -path '*/agents/*.ag' -print0 | tr '\0' '\n' | sort | head -1)"

if [ -z "$AG_FILES" ]; then
    echo "check-substrate-purity: no */agents/*.ag found under $SCAN_ROOT" >&2
    exit 2
fi

# --- Allowlist ---------------------------------------------------------------
# Known remaining embedded-interpreter sites, keyed `relpath:function` (relpath
# under dev-apprenticeship/). Enumerated by scanning every finding on the
# #1587-epic baseline and excluding the one remaining inline-waived Phase-1
# site (router.ag:closed_by_context; the other, code_writer.ag:numbered_view,
# was dead code and was deleted in #1607 instead of being carried as debt).
# Prune a row when its Phase 2/3 rewrite lands — the [STALE-ALLOWLIST]
# direction will fail the lint until you do.
#
# SUBSTRATE_PURITY_ALLOWLIST_FILE (test-only override): when set to a readable
# file, the allowlist is loaded from it (one `relpath:function` per line, blank
# and `#`-comment lines ignored) instead of the baked-in literal, and the
# fixed-count assertion is derived rather than pinned to 15. The self-test uses
# this to drive small mktemp fixtures — exactly as check-getenv-allowlist.sh's
# tests drive their allowlist through a fixture install.sh. Unset in production;
# the baked-in literal is the single source of truth for the real corpus.
if [ -n "${SUBSTRATE_PURITY_ALLOWLIST_FILE:-}" ]; then
    if [ ! -f "$SUBSTRATE_PURITY_ALLOWLIST_FILE" ]; then
        echo "check-substrate-purity: SUBSTRATE_PURITY_ALLOWLIST_FILE not found: $SUBSTRATE_PURITY_ALLOWLIST_FILE" >&2
        exit 2
    fi
    ALLOWLIST="$(grep -vE '^[[:space:]]*(#|$)' "$SUBSTRATE_PURITY_ALLOWLIST_FILE" || true)"
    ALLOWLIST_COUNT_EXPECTED="$(printf '%s\n' "$ALLOWLIST" | grep -c . || true)"
else
    # #1587 closed dev-apprenticeship (#1638 Phase 3 cluster B2) and its rows are
    # gone. What follows is the debt #2083 exposed when the scope widened beyond
    # that one federation: sites that were always there and that no lint could
    # see. It is a to-do list with a guard rail, not an endorsement — the
    # [STALE-ALLOWLIST] direction means a row cannot outlive its fix, so this
    # list can only shrink.
    #
    # Not on it: templates/agents/, cleared in #2085. Two sites remain there,
    # both inline-waived with reasons that still hold — checked against the
    # running binary rather than assumed: now_iso()/now_ms() resolve, while
    # weekday, epoch_to_iso, iso_to_epoch, date_add, strftime and every other
    # candidate return "undefined function".
    ALLOWLIST="dark-factory/auditor/agents/audit-scout.ag:cat_file
dark-factory/auditor/agents/audit-scout.ag:scoped_code
dark-factory/auditor/agents/brief-writer.ag:cat_file
dark-factory/auditor/agents/dup-scout.ag:audit_mentions
dark-factory/auditor/agents/feedback-intake.ag:manifest_field
dark-factory/auditor/agents/feedback-intake.ag:manifest_text
dark-factory/auditor/agents/feedback-intake.ag:outcome_reason
dark-factory/auditor/agents/feedback-intake.ag:outcome_text
dark-factory/auditor/agents/feedback-intake.ag:outcome_verdict
dark-factory/auditor/agents/hunter.ag:cat_file
dark-factory/auditor/agents/impact-gate.ag:poc_text
dark-factory/auditor/agents/invariant-prover.ag:cat_file
dark-factory/auditor/agents/invariant-prover.ag:steps_of
dark-factory/auditor/agents/method-inventor.ag:cat
dark-factory/auditor/agents/poc-screener.ag:read_harness
dark-factory/auditor/agents/poc-writer.ag:cat_file
dark-factory/auditor/agents/poc-writer.ag:first_fixture
dark-factory/auditor/agents/refuter.ag:cat_file
dark-factory/auditor/agents/report-writer.ag:poc_text
dark-factory/auditor/agents/scope-gate.ag:scope_text
dark-factory/auditor/agents/stateful-invariant-fuzz.ag:cat_file
dark-factory/auditor/agents/symbolic-prover.ag:cat_file
dark-factory/auditor/agents/zone-mapper.ag:cat_file
dark-factory/auditor/agents/zone-mapper.ag:read_taxonomy
trading-binance/tribe-alpha/agents/strategist.ag:_levenshtein_ratio_pct
trading-binance/tribe-alpha/agents/strategist.ag:_publish_prompt_body_and_wrap_variant
trading-binance/tribe-alpha/agents/strategist.ag:_push_settled_trade
trading-binance/tribe-beta/agents/strategist.ag:_levenshtein_ratio_pct
trading-binance/tribe-beta/agents/strategist.ag:_publish_prompt_body_and_wrap_variant
trading-binance/tribe-beta/agents/strategist.ag:_push_settled_trade
trading-binance/tribe-delta/agents/strategist.ag:_levenshtein_ratio_pct
trading-binance/tribe-delta/agents/strategist.ag:_publish_prompt_body_and_wrap_variant
trading-binance/tribe-delta/agents/strategist.ag:_push_settled_trade
trading-binance/tribe-epsilon/agents/strategist.ag:_levenshtein_ratio_pct
trading-binance/tribe-epsilon/agents/strategist.ag:_publish_prompt_body_and_wrap_variant
trading-binance/tribe-epsilon/agents/strategist.ag:_push_settled_trade
trading-binance/tribe-gamma/agents/strategist.ag:_levenshtein_ratio_pct
trading-binance/tribe-gamma/agents/strategist.ag:_publish_prompt_body_and_wrap_variant
trading-binance/tribe-gamma/agents/strategist.ag:_push_settled_trade
trading-binance/tribe-zeta/agents/strategist.ag:_levenshtein_ratio_pct
trading-binance/tribe-zeta/agents/strategist.ag:_publish_prompt_body_and_wrap_variant
trading-binance/tribe-zeta/agents/strategist.ag:_push_settled_trade
tribes-bench/tribe-alpha/agents/hunter.ag:_levenshtein_ratio_pct
tribes-bench/tribe-alpha/agents/hunter.ag:_publish_prompt_body_and_wrap_variant
tribes-bench/tribe-alpha/agents/hunter.ag:_push_verified_finding
tribes-bench/tribe-alpha/agents/hunter.ag:rep_bucket
tribes-bench/tribe-beta/agents/hunter.ag:_levenshtein_ratio_pct
tribes-bench/tribe-beta/agents/hunter.ag:_publish_prompt_body_and_wrap_variant
tribes-bench/tribe-beta/agents/hunter.ag:_push_verified_finding
tribes-bench/tribe-beta/agents/hunter.ag:rep_bucket
tribes-bench/tribe-delta/agents/hunter.ag:_levenshtein_ratio_pct
tribes-bench/tribe-delta/agents/hunter.ag:_publish_prompt_body_and_wrap_variant
tribes-bench/tribe-delta/agents/hunter.ag:_push_verified_finding
tribes-bench/tribe-delta/agents/hunter.ag:rep_bucket
tribes-bench/tribe-epsilon/agents/hunter.ag:_levenshtein_ratio_pct
tribes-bench/tribe-epsilon/agents/hunter.ag:_publish_prompt_body_and_wrap_variant
tribes-bench/tribe-epsilon/agents/hunter.ag:_push_verified_finding
tribes-bench/tribe-epsilon/agents/hunter.ag:rep_bucket
tribes-bench/tribe-gamma/agents/hunter.ag:_levenshtein_ratio_pct
tribes-bench/tribe-gamma/agents/hunter.ag:_publish_prompt_body_and_wrap_variant
tribes-bench/tribe-gamma/agents/hunter.ag:_push_verified_finding
tribes-bench/tribe-gamma/agents/hunter.ag:rep_bucket"
    ALLOWLIST_COUNT_EXPECTED=62
fi

# Guard against an accidental edit silently changing the debt size.
ALLOWLIST_COUNT_ACTUAL="$(printf '%s\n' "$ALLOWLIST" | grep -c . || true)"
if [ "$ALLOWLIST_COUNT_ACTUAL" -ne "$ALLOWLIST_COUNT_EXPECTED" ]; then
    echo "check-substrate-purity: allowlist has $ALLOWLIST_COUNT_ACTUAL entries, expected $ALLOWLIST_COUNT_EXPECTED (update ALLOWLIST_COUNT_EXPECTED deliberately)" >&2
    exit 2
fi

# in_allowlist <relpath:fn>: 0 if the key is an allowlist entry, 1 otherwise.
in_allowlist() {
    local key="$1" entry
    while IFS= read -r entry; do
        [ "$entry" = "$key" ] && return 0
    done <<EOF
$ALLOWLIST
EOF
    return 1
}

# --- Scan one .ag file -------------------------------------------------------
# Emits `relpath:line:function:waived` per positive-pattern match. `waived` is
# 1 when a `// substrate-purity: deferred (` annotation covers the finding.
# The single-quote patterns are built in the shell (awk regex literals cannot
# hold a bare `'` under single-quoted shell) and passed via exported env vars
# read through ENVIRON[] — NOT -v, because -v performs backslash escape
# processing and PY_PAT needs a literal `\\?` (optional backslash) to catch
# the `python3 \-c` evasion; ENVIRON delivers the strings verbatim.
#
# PY_PAT catches: `python3 -c`, `python3 -` (stdin script), `python3 \-c`
# (backslash-escaped dash), and a bare `python3 <<EOF` heredoc (program on
# stdin). It deliberately does NOT match `python3 <script.py> <<EOF` — a
# heredoc feeding DATA to a script file (the apply-edits shape) is a
# mechanical tool invocation, not embedded logic.
# AWK_PAT/SED_PAT tolerate any number of flag tokens (`awk -F: '...'`,
# `sed -n -e '...'`) before the quoted inline program.
SQ="'"
PY_PAT='python3[[:space:]]+(\\?-(c([^A-Za-z0-9_]|$)|[[:space:]]|<)|<<)'
AWK_PAT="awk[[:space:]]+(-[^[:space:]$SQ]+[[:space:]]+)*$SQ"
SED_PAT="sed[[:space:]]+(-[^[:space:]$SQ]+[[:space:]]+)*$SQ"

scan_file() {
    local ag_file="$1" rel="$2"
    PY_PAT="$PY_PAT" AWK_PAT="$AWK_PAT" SED_PAT="$SED_PAT" \
    awk -v rel="$rel" '
    BEGIN { depth = 0; in_fn = 0; fn_name = ""; fn_block_waiver = 0; block_accum = 0; comment_run_deferred = 0 }
    {
        clean = $0
        # Strip `//` line comments (line start or whitespace-preceded), so the
        # ~70 prose mentions of the pattern do not trip the scanner. A `//`
        # inside a string literal (URL) stays imperfect but realistic.
        sub(/(^|[[:space:]])\/\/.*$/, "", clean)

        is_comment_only = ($0 ~ /^[[:space:]]*\/\//)
        has_deferred    = ($0 ~ /substrate-purity:[[:space:]]*deferred[[:space:]]*\(/)

        # Enter a top-level `fn NAME(`; capture the comment block just above it.
        if (!in_fn && depth == 0 && match(clean, /^[[:space:]]*fn[[:space:]]+[a-zA-Z_][a-zA-Z_0-9]*/)) {
            s = substr(clean, RSTART, RLENGTH)
            sub(/^[[:space:]]*fn[[:space:]]+/, "", s)
            fn_name = s
            in_fn = 1
            fn_block_waiver = block_accum
        }

        # Finding detection on the comment-stripped line.
        if (clean ~ ENVIRON["PY_PAT"] || clean ~ ENVIRON["AWK_PAT"] || clean ~ ENVIRON["SED_PAT"]) {
            waived = 0
            # Rule (a): waiver on the finding line itself, or anywhere in the
            # contiguous comment block directly above it. Consulting only the
            # single line above lost every waiver whose reason ran onto a second
            # or third comment line — which is the normal shape for a reason
            # worth writing down.
            if (has_deferred || comment_run_deferred) waived = 1
            # Rule (b): waiver in the leading comment block above the enclosing fn.
            else if (in_fn && fn_block_waiver) waived = 1
            printf "%s:%d:%s:%d\n", rel, NR, (in_fn ? fn_name : "(toplevel)"), waived
        }

        # Track the contiguous leading `//`-comment run for the NEXT `fn`.
        if (is_comment_only) {
            if (has_deferred) { block_accum = 1; comment_run_deferred = 1 }
        } else {
            block_accum = 0
            comment_run_deferred = 0
        }

        opens = gsub(/\{/, "", clean)
        closes = gsub(/\}/, "", clean)
        depth += opens - closes
        if (in_fn && depth <= 0) {
            in_fn = 0; fn_name = ""; fn_block_waiver = 0
            if (depth < 0) depth = 0
        }
    }
    ' "$ag_file"
}

FAIL=0
HIT_KEYS=""   # allowlist entries confirmed present this scan (space-delimited)

while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    rel="${f#"$SCAN_ROOT"/}"
    # The exclusion is applied to the path RELATIVE to the scan root. An
    # absolute `-not -path '*/worktrees/*'` also excludes every file when the
    # scan root is itself inside a worktree, which reduces the lint to nothing.
    case "$rel" in
        (worktrees/*|.git/*) continue ;;
    esac
    while IFS= read -r finding; do
        [ -n "$finding" ] || continue
        # finding = relpath:line:function:waived
        waived="${finding##*:}"
        rest="${finding%:*}"
        fn="${rest##*:}"
        rest="${rest%:*}"
        line="${rest##*:}"
        relf="${rest%:*}"

        [ "$waived" = "1" ] && continue

        key="$relf:$fn"
        if in_allowlist "$key"; then
            case " $HIT_KEYS " in
                *" $key "*) ;;
                *) HIT_KEYS="$HIT_KEYS $key" ;;
            esac
        else
            # shellcheck disable=SC2016
            printf '[NEW-ESCAPE] %s:%s: embedded interpreter one-liner in fn `%s` is not on the #1587 allowlist and not waived — rewrite it with native builtins or annotate `// substrate-purity: deferred (<reason>)`\n' "$relf" "$line" "$fn"
            FAIL=$((FAIL + 1))
        fi
    done < <(scan_file "$f" "$rel")
done < <(find "$SCAN_ROOT" -type f -path '*/agents/*.ag' -print0)

# [STALE-ALLOWLIST]: any allowlisted site that produced no finding this scan was
# rewritten — its row is dead debt and must be pruned.
while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case " $HIT_KEYS " in
        *" $entry "*) ;;
        *)
            # shellcheck disable=SC2016
            printf '[STALE-ALLOWLIST] %s: allowlisted site no longer produces an embedded-interpreter finding — the rewrite landed; delete this row from tools/check-substrate-purity.sh (and decrement ALLOWLIST_COUNT_EXPECTED)\n' "$entry"
            FAIL=$((FAIL + 1))
            ;;
    esac
done <<EOF
$ALLOWLIST
EOF

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "check-substrate-purity: $FAIL finding(s)"
    exit 1
fi

exit 0
