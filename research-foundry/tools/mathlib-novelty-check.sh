#!/bin/bash
# research-foundry/tools/mathlib-novelty-check.sh -- fuzzy-match the
# theorem signature from a Lean source file against Mathlib's source
# tree to decide whether the theorem is a textbook duplicate of an
# existing Mathlib declaration. Output to stdout (one line):
#   MATCH:<mathlib_file>:<lineno>:<decl_name>   (a similar decl exists)
#   NOVEL                                         (no similar decl found)
# Exit 0 always -- the verdict is on stdout. Issue #955.
#
# Called from `theorist.ag::_run_lean_check` after `lean` returns
# `verified` to split the verdict into `verified_novel` vs
# `verified_duplicate`. The Mathlib pin shipped in the container
# (`/opt/mathlib-shell/.lake/packages/mathlib/Mathlib`) is ~150k
# declarations; without this gate most "verified" theorems are
# re-derivations of textbook results (Nat.add_comm, etc.).
#
# Fuzzy match strategy (first pass, intentionally over-eager on MATCH):
#   1. Extract the LAST `theorem|lemma <name> : <prop> :=` block from the
#      input Lean file (multi-line, the LLM tends to emit one main
#      theorem at the bottom after imports + helper lemmas).
#   2. Normalize <prop>: collapse whitespace, drop `[...]` typeclass
#      brackets (typeclass noise has near-zero discriminative power for
#      cross-file matching), and rename universe vars u/v/w to greek
#      placeholders so a Lean-renamed lemma still matches its Mathlib
#      counterpart.
#   3. Tokenize on whitespace + punctuation, uniq-sort.
#   4. Walk Mathlib source files; for each `theorem `/`lemma ` decl
#      compute Jaccard similarity against ours. Emit the first hit at
#      >= threshold (default 0.7), else NOVEL.
#
# Threshold 0.7 is intentionally low (over-eager on MATCH) -- for the
# first-pass detector, false positives (calling a near-trivial novel
# statement a duplicate) are preferable to false negatives (publishing
# a redundant lemma). Future work: replace text match with semantic
# Lean.Elab.Tactic.Search-style check.
#
# Env knobs:
#   MATHLIB_ROOT              Override the Mathlib source root. Default:
#                             /opt/mathlib-shell/.lake/packages/mathlib/Mathlib
#   MATHLIB_NOVELTY_THRESHOLD Jaccard floor in [0, 1]. Default 0.7.
#
# Usage: mathlib-novelty-check.sh <path-to-lean-source>

set -u

MATHLIB_ROOT="${MATHLIB_ROOT:-/opt/mathlib-shell/.lake/packages/mathlib/Mathlib}"
SRC="${1:-}"

# Defensive: empty / unreadable input. Claim NOVEL so the federation
# doesn't false-positive duplicates when the theorist tick produced
# no Lean source.
if [ -z "$SRC" ] || [ ! -r "$SRC" ]; then
    echo "NOVEL"
    exit 0
fi

# Defensive: Mathlib source not staged in the image. Claim NOVEL so the
# federation doesn't false-positive duplicates when an operator strips
# the mathlib layer (mirrors the `_run_lean_check` resilience pattern).
if [ ! -d "$MATHLIB_ROOT" ]; then
    echo "NOVEL"
    exit 0
fi

# Extract the LAST theorem|lemma block's <prop> from SRC.
# Pattern: `(theorem|lemma) <name> : <prop> := <body>`. The block can
# span multiple lines; we use a streaming state machine in awk.
PROP=$(awk '
    function flush(    p) {
        if (collecting && buf != "") {
            p = buf
            sub(/^[[:space:]]*(theorem|lemma)[[:space:]]+[A-Za-z_][A-Za-z0-9_.'"'"']*/, "", p)
            sub(/^[[:space:]]*:[[:space:]]*/, "", p)
            sub(/[[:space:]]*:=.*$/, "", p)
            last = p
        }
        collecting = 0
        buf = ""
    }
    /^[[:space:]]*(theorem|lemma)[[:space:]]+[A-Za-z_]/ {
        flush()
        collecting = 1
        buf = $0
        next
    }
    collecting {
        buf = buf " " $0
        if (index($0, ":=") > 0) {
            flush()
        }
    }
    END {
        flush()
        print last
    }
' "$SRC")

if [ -z "$PROP" ]; then
    echo "NOVEL"
    exit 0
fi

# Normalize a <prop> string into a uniq-sorted token bag.
# - drop `[...]` typeclass brackets (noise for cross-file matching)
# - rename universe-var triplet u/v/w to greek so Lean-renamed lemmas
#   still align with their Mathlib counterparts
# - collapse punctuation to whitespace; tokenize; uniq-sort
normalize() {
    printf '%s' "$1" | tr -s '[:space:]' ' ' | \
        sed -E 's/\[[^]]*\]//g' | \
        sed -E 's/(^| )u( |$)/\1\xce\xb1\2/g; s/(^| )v( |$)/\1\xce\xb2\2/g; s/(^| )w( |$)/\1\xce\xb3\2/g' | \
        sed -E 's/[[:punct:]]+/ /g' | \
        tr -s '[:space:]' '\n' | \
        grep -v '^$' | sort -u | tr '\n' ' '
}

OUR_TOKENS=$(normalize "$PROP")
OUR_COUNT=$(printf '%s' "$OUR_TOKENS" | wc -w | tr -d ' ')

# Too few tokens to fuzzy match -- a 1- or 2-token statement is too
# generic to discriminate (could match dozens of Mathlib lemmas at
# Jaccard >= 0.7 just by chance). Claim NOVEL.
if [ "$OUR_COUNT" -lt 3 ]; then
    echo "NOVEL"
    exit 0
fi

THRESHOLD="${MATHLIB_NOVELTY_THRESHOLD:-0.7}"

# Walk Mathlib files. For each theorem/lemma decl in each file, compute
# Jaccard against OUR_TOKENS via awk. Emit the first match >= THRESHOLD;
# the outer `head -1` short-circuits the find walk as soon as any awk
# process emits a MATCH line. The trailing `cat | if-empty -> NOVEL`
# wrapper turns the empty-pipeline case into the NOVEL verdict.
match_line=$(find "$MATHLIB_ROOT" -name "*.lean" -type f 2>/dev/null | while IFS= read -r mlf; do
    awk -v our_tokens="$OUR_TOKENS" -v our_count="$OUR_COUNT" -v threshold="$THRESHOLD" -v file="$mlf" '
        BEGIN {
            collecting = 0
            buf = ""
            decl_name = ""
            lineno = 0
            n_our = split(our_tokens, our_arr, /[[:space:]]+/)
            for (i = 1; i <= n_our; i++) {
                t = our_arr[i]
                if (t != "") uniq_our[t] = 1
            }
        }
        function check_buf(    prop, n_their, their_tokens, t, i, inter, union, jaccard, uniq_their, their_count) {
            prop = buf
            sub(/^[[:space:]]*(theorem|lemma)[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*/, "", prop)
            sub(/^[[:space:]]*:[[:space:]]*/, "", prop)
            sub(/[[:space:]]*:=.*$/, "", prop)
            gsub(/\[[^]]*\]/, "", prop)
            gsub(/[[:punct:]]+/, " ", prop)
            n_their = split(prop, their_tokens, /[[:space:]]+/)
            delete uniq_their
            their_count = 0
            for (i = 1; i <= n_their; i++) {
                t = their_tokens[i]
                if (t != "" && !(t in uniq_their)) {
                    uniq_their[t] = 1
                    their_count++
                }
            }
            inter = 0
            for (t in uniq_their) {
                if (t in uniq_our) inter++
            }
            union = their_count + our_count - inter
            if (union > 0) {
                jaccard = inter / union
                if (jaccard >= threshold) {
                    print "MATCH:" file ":" lineno ":" decl_name
                    exit 0
                }
            }
        }
        /^[[:space:]]*(theorem|lemma)[[:space:]]+[A-Za-z_]/ {
            if (collecting && buf != "") {
                check_buf()
            }
            collecting = 1
            buf = $0
            lineno = NR
            tmp = $0
            sub(/^[[:space:]]*(theorem|lemma)[[:space:]]+/, "", tmp)
            sub(/[[:space:]:].*$/, "", tmp)
            decl_name = tmp
            next
        }
        collecting {
            buf = buf " " $0
            if (index($0, ":=") > 0) {
                check_buf()
                collecting = 0
                buf = ""
            }
        }
        END {
            if (collecting && buf != "") {
                check_buf()
            }
        }
    ' "$mlf" 2>/dev/null
done | head -1)

if [ -n "$match_line" ]; then
    echo "$match_line"
else
    echo "NOVEL"
fi
exit 0
