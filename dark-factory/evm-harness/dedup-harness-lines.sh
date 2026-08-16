#!/bin/sh
# dedup-harness-lines.sh — pre-compile adjacent-duplicate-line guard for a generated invariant harness (#1926).
#
# The problem (proven live on the plaza Distributor<-BondToken composable seam): the harness generator
# occasionally STREAMS a duplication artifact — it emits an unbalanced statement-opener such as
#     bond = BondToken(address(new InvProxy(
# on two adjacent, byte-identical lines. The first opener is then left unclosed, so the downstream `)));`
# no longer balances and the file fails to compile (`Error (2314): Expected ',' but got ';'`). The
# --repair-rounds loop hands the model a full ~190-line rewrite each round, which re-exposes it to the same
# streaming artifact and thrashes instead of converging. Deleting the single duplicated line was proven to
# flip the harness to `Compiler run successful`, exit 0 — so a mechanical pre-compile pass fixes the artifact
# class deterministically, before the compiler (and the #1471 linkage grep) ever see the file.
#
# THE SAFE DEDUP PREDICATE — strip the current line L iff ALL FOUR hold:
#   1. L is non-blank.
#   2. L (with trailing whitespace trimmed, LEADING indentation preserved and compared) is byte-identical to
#      the immediately preceding NON-BLANK line. Blank lines are kept, are never themselves stripped, and do
#      NOT reset the "preceding non-blank" adjacency (so a blank line can't hide a duplicate).
#   3. L is SUBSTANTIVE — it contains at least one alphanumeric char. Pure structural / closing punctuation
#      (`}`, `)`, `);`, `));`, `{`, `,`) is therefore NEVER eligible; those legitimately repeat in nested code.
#   4. L has UNBALANCED parentheses — count('(') != count(')') within L.
#
# WHY THIS CAN ONLY REMOVE A COMPILE ERROR, NEVER VALID CODE (condition 4 is the load-bearing safety):
#   A duplicated line that is a BALANCED complete statement (`token.mint(user, 1e18);`) or an import
#   (`import "../src/BondToken.sol";` — zero parens, balanced) compiles fine when duplicated, so it is left
#   untouched. Only an UNBALANCED fragment is eligible, and a duplicated unbalanced fragment at the same
#   indentation is a guaranteed syntax error EVERY time it appears. Imports carry no parens, so they are
#   provably never stripped → the #1471 target-linkage gate is untouched by construction.
#
# STRING/COMMENT-LITERAL CAVEAT: the paren balance in condition 4 is a naive character count and does not
# skip parens inside string or comment literals (e.g. `require(x, "(")`). This is negligible here: the guard
# only fires on ADJACENT BYTE-IDENTICAL lines — the artifact signature — so at worst it would collapse an
# intentional pair of identical unbalanced-literal lines, which itself would already be a syntax error.
#
# The pass is a single linear scan, idempotent (a second run drops nothing), and O(lines) with no growth.
#
# FAIL-OPEN: any awk/mktemp error leaves the target byte-for-byte untouched and exits 0, so the guard can
# never break the gate — a missing/broken guard degrades to today's behaviour, never a spurious failure.
#
# Usage:  dedup-harness-lines.sh <file.t.sol>
# The file is normalized IN PLACE. When >=1 line is dropped a note is emitted to stderr; otherwise the target
# is left bit-for-bit identical (the temp is discarded, never moved over the original).
set -u

TARGET="${1:-}"
if [ -z "$TARGET" ] || [ ! -f "$TARGET" ]; then
  echo "Usage: dedup-harness-lines.sh <file.t.sol>" >&2
  exit 2
fi

# mktemp failure => fail-open (target untouched).
tmp="$(mktemp 2>/dev/null)" || exit 0

# awk writes the deduped body to $tmp and prints the dropped-line COUNT to stdout. Any awk error => fail-open.
count="$(awk -v out="$tmp" '
  {
    line = $0
    if (line ~ /^[ \t]*$/) {          # blank: keep, but do NOT reset the preceding-non-blank adjacency
      print line > out
      next
    }
    t = line
    sub(/[ \t]+$/, "", t)             # trim trailing whitespace only; leading indentation preserved/compared
    substantive = (t ~ /[A-Za-z0-9]/)
    s = t; no = gsub(/[(]/, "", s)    # gsub returns the substitution count
    s = t; nc = gsub(/[)]/, "", s)
    unbalanced = (no != nc)
    if (haveprev && substantive && unbalanced && t == prev) {
      dropped++
      next                            # strip: skip line, keep prev (so a run of dups collapses to one)
    }
    print line > out
    prev = t
    haveprev = 1
  }
  END { print dropped + 0 }
' "$TARGET" 2>/dev/null)" || { rm -f "$tmp"; exit 0; }

# A non-numeric count means awk misbehaved => fail-open.
case "$count" in
  ''|*[!0-9]*) rm -f "$tmp"; exit 0 ;;
esac

if [ "$count" -gt 0 ]; then
  mv "$tmp" "$TARGET" 2>/dev/null || { rm -f "$tmp"; exit 0; }
  echo "dedup-harness-lines: removed $count adjacent-duplicate line(s)" >&2
else
  rm -f "$tmp"
fi
exit 0
