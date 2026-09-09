#!/usr/bin/env bash
# demo-scope-changes.sh — OFFLINE, DETERMINISTIC proof (#2131, epic #2120 M2) of scope-changes.sh: the
# stateless diff-scoper that turns each M1 `changes.tsv` row into ONE scope descriptor. Mirrors
# demo-watch-code-changes.sh's assert-based [PASS]/[FAIL] accounting — a hand-written `changes.tsv` fixture +
# a canned `--probe-cmd` STUB keyed on $PROBE_KIND / $PROBE_REPO / $PROBE_ADDR, so NO network (`git`/Sourcify
# are never invoked) and the real ~/.dark-factory is never touched. One row per fixture case:
#
#   AC1 (scoped)            — a head row + a small `.sol`-only diff -> `scoped`, scope_hint_files = EXACTLY the
#                             changed .sol files (vendor/test/docs pruned), since = old sha.
#   AC2 (full-by-size)      — a head row whose filtered diff exceeds --max-files -> `full`, no scope-hint,
#                             since = old sha (the advisory hardening signal is kept).
#   AC3 (full-by-missing)   — a head row with an empty/`-` old sha -> `full`, no scope-hint, since = `-`.
#   AC4 (impl)              — an impl row -> `full` targeting the extracted new impl address (0x + last 40 hex
#                             of the storage word) + the carried chain; an advisory src note on the log.
#   AC5 (skip)              — a head row whose diff touches only docs/ + test/ + script/ (no huntable .sol) ->
#                             `skip` (no spurious hunt).
#   AC6 (tag fan-out)       — a tag row adding TWO tags -> EXACTLY two descriptors, each `new` a single tag.
#   AC7 (last-elem regr.)   — a tag row whose ONLY added tag is the C-sort-LAST of the new set -> one
#                             descriptor with that tag as `new` (the firedancer `new='-'` bug, #2154).
#   AC8 (tag skips)         — removal-only / first-sight tag rows emit NO descriptor + a [skip] line; and no
#                             kind=tag descriptor ever carries new='-'.
#   AC9 (family base)       — a tag row adding graft/coreth/v1.15.0 diffs against the same-family predecessor
#                             graft/coreth/v1.14.0, not the greater flat tag.
#   AC10 (cap)              — --max-added-tags 2 over a row adding four tags -> the 2 greatest descriptors +
#                             2 [skip] capped log lines.
#
# Usage:  dark-factory/demo-scope-changes.sh
# Exit:   0 = all assertions held; non-zero = a failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCOPER="$HERE/scope-changes.sh"

FAILS=0
note() { echo "demo-scope-changes.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -x "$SCOPER" ] || { note "scope-changes.sh not found / not executable: $SCOPER" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-scope-changes.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

TAB="$(printf '\t')"

# ----------------------------------------------------------------------------------------------------------
# Fixture changes.tsv (M1's 8-column shape: date program chain kind repo_or_addr old new githubUrl):
#   alpha   : head, small .sol-only diff              -> scoped (AC1)
#   beta    : head, 3 .sol diff, run with --max-files 2 -> full-by-size (AC2)
#   gamma   : head, old sha = `-`                     -> full-by-missing-sha (AC3)
#   delta   : impl, storage word -> new impl address  -> full targeting the new impl (AC4)
#   epsilon : head, docs/test/script-only diff        -> skip (AC5)
# ----------------------------------------------------------------------------------------------------------
CH="$WORK/changes.tsv"
{
  echo "# fixture ledger — TAB-separated, M1 columns."
  printf 'date\tprogram\tchain\tkind\trepo_or_addr\told\tnew\tgithubUrl\n' | sed 's/^/#/'
  printf '2026-09-07T00:00:00Z\talpha\t-\thead\thttps://github.com/example/alpha\toldsha_alpha\tnewsha_alpha\thttps://github.com/example/alpha\n'
  printf '2026-09-07T00:00:00Z\tbeta\t-\thead\thttps://github.com/example/beta\toldsha_beta\tnewsha_beta\thttps://github.com/example/beta\n'
  printf '2026-09-07T00:00:00Z\tgamma\t-\thead\thttps://github.com/example/gamma\t-\tnewsha_gamma\thttps://github.com/example/gamma\n'
  printf '2026-09-07T00:00:00Z\tdelta\tethereum\timpl\t0x1111111111111111111111111111111111111111\t0x000000000000000000000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t0x000000000000000000000000bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\t-\n'
  printf '2026-09-07T00:00:00Z\tepsilon\t-\thead\thttps://github.com/example/epsilon\toldsha_eps\tnewsha_eps\thttps://github.com/example/epsilon\n'
  # tag rows (#2154). old/new are the WHOLE sorted comma-joined tag SETS (M1's shape); M2 fans out per ADDED tag.
  #   zeta  : adds TWO tags                                   -> 2 descriptors (AC6)
  #   eta   : the ONLY added tag is the C-sort-LAST element   -> 1 descriptor, new = that tag (AC7 regression)
  #   theta : new is a SUBSET of old (removal only)           -> NO descriptor + [skip] no added tag (AC8)
  #   iota  : old = `-` (first-sight)                         -> NO descriptor + [skip] first-sight (AC8)
  #   kappa : adds graft/coreth/v1.15.0 (family base)         -> since = graft/coreth/v1.14.0 (AC9)
  #   lambda: adds FOUR tags, run at --max-added-tags 2       -> 2 descriptors + 2 [skip] capped (AC10)
  printf '2026-09-07T00:00:00Z\tzeta\t-\ttag\thttps://github.com/example/zeta\tv1.0.0\tv1.0.0,v1.1.0,v1.2.0\t-\n'
  printf '2026-09-07T00:00:00Z\teta\t-\ttag\thttps://github.com/example/eta\tv1.0.0,v2.0.0\tv1.0.0,v2.0.0,v9.9.9\t-\n'
  printf '2026-09-07T00:00:00Z\ttheta\t-\ttag\thttps://github.com/example/theta\tv1.0.0,v2.0.0\tv1.0.0\t-\n'
  printf '2026-09-07T00:00:00Z\tiota\t-\ttag\thttps://github.com/example/iota\t-\tv1.0.0\t-\n'
  printf '2026-09-07T00:00:00Z\tkappa\t-\ttag\thttps://github.com/example/kappa\tgraft/coreth/v1.14.0,v1.9.9-rc.4\tgraft/coreth/v1.14.0,v1.9.9-rc.4,graft/coreth/v1.15.0\t-\n'
  printf '2026-09-07T00:00:00Z\tlambda\t-\ttag\thttps://github.com/example/lambda\tv1.0.0\tv1.0.0,v1.1.0,v1.2.0,v1.3.0,v1.4.0\t-\n'
} > "$CH"

# The --probe-cmd STUB: keyed on $PROBE_KIND then $PROBE_REPO (diff) / $PROBE_ADDR (source). Canned changed
# file lists (pre-.sol-filter) and a canned source note; NO network, NO real git/Sourcify. gamma is never
# probed (its old sha is `-`, so scope-changes.sh short-circuits to full-by-missing before the probe).
STUB='case "$PROBE_KIND" in
  diff)
    case "$PROBE_REPO" in
      *example/alpha)   printf "src/Vault.sol\nsrc/Token.sol\nREADME.md\nlib/openzeppelin/ERC20.sol\n" ;;
      *example/beta)    printf "src/A.sol\nsrc/B.sol\nsrc/C.sol\n" ;;
      *example/epsilon) printf "docs/spec.md\ntest/Vault.t.sol\nscript/Deploy.s.sol\n" ;;
      *example/zeta|*example/eta|*example/kappa|*example/lambda) printf "src/Changed.sol\n" ;;
      *) exit 4 ;;
    esac
    ;;
  source) echo verified ;;
esac'

OUT="$WORK/scope-descriptors.tsv"
ERR="$WORK/run.err"
"$SCOPER" --changes-from "$CH" --out "$OUT" --max-files 2 --max-added-tags 2 --probe-cmd "$STUB" \
  >/dev/null 2>"$ERR"
RC=$?
[ "$RC" -eq 0 ] && ok "run exits 0" || bad "run exited $RC (expected 0)"

# a small extractor: the descriptor row for a program, field N (1-based, TAB).
field() { grep -v '^#' "$OUT" | awk -F"$TAB" -v p="$1" -v n="$2" '$1==p{print $n; exit}'; }
row_count() { grep -cv '^#' "$OUT" 2>/dev/null || true; }
# fan-out helpers (#2154): all rows for a program (a `tag` row can fan out to several).
prog_rows()  { grep -v '^#' "$OUT" | awk -F"$TAB" -v p="$1" '$1==p'; }
prog_count() { prog_rows "$1" | grep -c . || true; }
prog_news()  { prog_rows "$1" | cut -f5 | paste -sd, - ; }   # the `new` column of every row, comma-joined
LOGF="$(dirname "$OUT")/scope-changes.log"

TOTAL="$(row_count)"
[ "$TOTAL" -eq 11 ] && ok "exactly 11 descriptors (head/impl/skip 1:1; tag rows fan out per added tag)" \
  || bad "got $TOTAL descriptors, expected 11"

# ----------------------------------------------------------------------------------------------------------
note "AC1) head + small .sol-only diff -> scoped, exact scope_hint_files, since = old sha ..."
[ "$(field alpha 6)" = "scoped" ] && ok "AC1: alpha scope_mode = scoped" || bad "AC1 FAILED: alpha mode = $(field alpha 6)"
[ "$(field alpha 3)" = "head" ] && ok "AC1: alpha kind = head" || bad "AC1 FAILED: alpha kind = $(field alpha 3)"
[ "$(field alpha 7)" = "src/Vault.sol,src/Token.sol" ] \
  && ok "AC1: alpha scope_hint_files = exactly the changed .sol (README + lib/ pruned)" \
  || bad "AC1 FAILED: alpha scope_hint_files = '$(field alpha 7)' (want src/Vault.sol,src/Token.sol)"
[ "$(field alpha 8)" = "oldsha_alpha" ] && ok "AC1: alpha since = old sha" || bad "AC1 FAILED: alpha since = $(field alpha 8)"
[ "$(field alpha 5)" = "newsha_alpha" ] && ok "AC1: alpha new = new sha" || bad "AC1 FAILED: alpha new = $(field alpha 5)"

# ----------------------------------------------------------------------------------------------------------
note "AC2) head diff > --max-files (2) -> full-by-size, no scope-hint, since kept ..."
[ "$(field beta 6)" = "full" ] && ok "AC2: beta scope_mode = full" || bad "AC2 FAILED: beta mode = $(field beta 6)"
[ "$(field beta 7)" = "-" ] && ok "AC2: beta scope_hint_files = '-' (no scope-hint on a full hunt)" || bad "AC2 FAILED: beta hint = $(field beta 7)"
[ "$(field beta 8)" = "oldsha_beta" ] && ok "AC2: beta since = old sha (full-by-size keeps the hardening signal)" || bad "AC2 FAILED: beta since = $(field beta 8)"

# ----------------------------------------------------------------------------------------------------------
note "AC3) head row with empty/'-' old sha -> full-by-missing-sha, since = '-' ..."
[ "$(field gamma 6)" = "full" ] && ok "AC3: gamma scope_mode = full" || bad "AC3 FAILED: gamma mode = $(field gamma 6)"
[ "$(field gamma 7)" = "-" ] && ok "AC3: gamma scope_hint_files = '-'" || bad "AC3 FAILED: gamma hint = $(field gamma 7)"
[ "$(field gamma 8)" = "-" ] && ok "AC3: gamma since = '-' (missing old sha)" || bad "AC3 FAILED: gamma since = $(field gamma 8)"

# ----------------------------------------------------------------------------------------------------------
note "AC4) impl row -> full targeting the extracted new impl address + carried chain, advisory src note ..."
[ "$(field delta 6)" = "full" ] && ok "AC4: delta scope_mode = full" || bad "AC4 FAILED: delta mode = $(field delta 6)"
[ "$(field delta 3)" = "impl" ] && ok "AC4: delta kind = impl" || bad "AC4 FAILED: delta kind = $(field delta 3)"
[ "$(field delta 2)" = "ethereum" ] && ok "AC4: delta chain = ethereum (carried)" || bad "AC4 FAILED: delta chain = $(field delta 2)"
[ "$(field delta 4)" = "0x1111111111111111111111111111111111111111" ] \
  && ok "AC4: delta repo_or_addr = the proxy address" || bad "AC4 FAILED: delta repo_or_addr = $(field delta 4)"
[ "$(field delta 5)" = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ] \
  && ok "AC4: delta new = new impl address (0x + last 40 hex of the storage word)" \
  || bad "AC4 FAILED: delta new = '$(field delta 5)' (want 0xbbbb...bbbb)"
[ "$(field delta 8)" = "-" ] && ok "AC4: delta since = '-' (source-pull deferred to M3)" || bad "AC4 FAILED: delta since = $(field delta 8)"
if grep -q "src:verified" "$(dirname "$OUT")/scope-changes.log" 2>/dev/null; then
  ok "AC4: advisory src note (src:verified) recorded on the log"
else
  bad "AC4 FAILED: no advisory src note on the log"
fi

# ----------------------------------------------------------------------------------------------------------
note "AC5) head diff of docs/test/script only -> skip (no huntable .sol) ..."
[ "$(field epsilon 6)" = "skip" ] && ok "AC5: epsilon scope_mode = skip" || bad "AC5 FAILED: epsilon mode = $(field epsilon 6)"
[ "$(field epsilon 7)" = "-" ] && ok "AC5: epsilon scope_hint_files = '-'" || bad "AC5 FAILED: epsilon hint = $(field epsilon 7)"
[ "$(field epsilon 8)" = "-" ] && ok "AC5: epsilon since = '-'" || bad "AC5 FAILED: epsilon since = $(field epsilon 8)"

# ----------------------------------------------------------------------------------------------------------
note "AC6) tag row adding TWO tags -> EXACTLY two descriptors, each a single real tag as new ..."
[ "$(prog_count zeta)" -eq 2 ] && ok "AC6: zeta fans out to exactly 2 descriptors" || bad "AC6 FAILED: zeta rows = $(prog_count zeta) (want 2)"
[ "$(prog_news zeta)" = "v1.1.0,v1.2.0" ] \
  && ok "AC6: zeta descriptors carry new=v1.1.0 and new=v1.2.0 (the two ADDED tags)" \
  || bad "AC6 FAILED: zeta news = '$(prog_news zeta)' (want v1.1.0,v1.2.0)"
if prog_rows zeta | awk -F"$TAB" '$3!="tag"{bad=1} END{exit bad+0}'; then
  ok "AC6: every zeta descriptor kind = tag"
else
  bad "AC6 FAILED: a zeta descriptor kind != tag"
fi

# ----------------------------------------------------------------------------------------------------------
note "AC7) the ONLY added tag is the C-sort-LAST element of the new set -> new = that tag, never '-' ..."
[ "$(prog_count eta)" -eq 1 ] && ok "AC7: eta -> exactly 1 descriptor" || bad "AC7 FAILED: eta rows = $(prog_count eta) (want 1)"
[ "$(field eta 5)" = "v9.9.9" ] \
  && ok "AC7: eta new = v9.9.9 (the last-element regression is fixed; was '-' before #2154)" \
  || bad "AC7 FAILED: eta new = '$(field eta 5)' (want v9.9.9)"
[ "$(field eta 6)" != "full" ] || bad "AC7 FAILED: eta degraded to full (the added tag was dropped)"

# ----------------------------------------------------------------------------------------------------------
note "AC8) removal-only + first-sight tag rows emit NO descriptor + a [skip] line; NO tag row has new='-' ..."
[ "$(prog_count theta)" -eq 0 ] && ok "AC8: theta (removal only) -> no descriptor" || bad "AC8 FAILED: theta rows = $(prog_count theta) (want 0)"
grep -q "\[skip\] theta (tag .*): no added tag" "$LOGF" && ok "AC8: theta logged [skip] no added tag" || bad "AC8 FAILED: no theta 'no added tag' skip line"
[ "$(prog_count iota)" -eq 0 ] && ok "AC8: iota (first-sight) -> no descriptor" || bad "AC8 FAILED: iota rows = $(prog_count iota) (want 0)"
grep -q "\[skip\] iota (tag .*): first-sight tag baseline" "$LOGF" && ok "AC8: iota logged [skip] first-sight tag baseline" || bad "AC8 FAILED: no iota first-sight skip line"
if grep -v '^#' "$OUT" | awk -F"$TAB" '$3=="tag" && $5=="-"{n++} END{exit (n>0)}'; then
  ok "AC8: no kind=tag descriptor has new='-' (the invariant holds globally)"
else
  bad "AC8 FAILED: a kind=tag descriptor has new='-'"
fi

# ----------------------------------------------------------------------------------------------------------
note "AC9) family-aware base: adding graft/coreth/v1.15.0 -> since = graft/coreth/v1.14.0 (same family) ..."
[ "$(field kappa 5)" = "graft/coreth/v1.15.0" ] && ok "AC9: kappa new = graft/coreth/v1.15.0" || bad "AC9 FAILED: kappa new = $(field kappa 5)"
[ "$(field kappa 8)" = "graft/coreth/v1.14.0" ] \
  && ok "AC9: kappa since = graft/coreth/v1.14.0 (family base, NOT the greater flat tag v1.9.9-rc.4)" \
  || bad "AC9 FAILED: kappa since = '$(field kappa 8)' (want graft/coreth/v1.14.0)"

# ----------------------------------------------------------------------------------------------------------
note "AC10) --max-added-tags 2 over a row adding FOUR tags -> 2 greatest descriptors + 2 [skip] capped ..."
[ "$(prog_count lambda)" -eq 2 ] && ok "AC10: lambda capped to exactly 2 descriptors" || bad "AC10 FAILED: lambda rows = $(prog_count lambda) (want 2)"
[ "$(prog_news lambda)" = "v1.3.0,v1.4.0" ] \
  && ok "AC10: lambda kept the C-sort-greatest 2 (v1.3.0, v1.4.0)" \
  || bad "AC10 FAILED: lambda news = '$(prog_news lambda)' (want v1.3.0,v1.4.0)"
CAPPED="$(grep -c "\[skip\] lambda (tag .*): --max-added-tags 2 capped" "$LOGF" || true)"
[ "$CAPPED" -eq 2 ] && ok "AC10: exactly 2 [skip] capped log lines for lambda" || bad "AC10 FAILED: $CAPPED capped lines (want 2)"

# ----------------------------------------------------------------------------------------------------------
echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: scope-changes.sh turned each changes.tsv row into the right descriptor — a small .sol-only diff"
  note "      into a SCOPED hunt (exact changed .sol, vendor/test/docs pruned, since=old), an over-threshold"
  note "      diff and a missing old sha into FULL (by-size keeps since; by-missing drops it), an impl upgrade"
  note "      into a FULL hunt of the extracted new impl address with an advisory source note, and a"
  note "      docs/tests-only diff into SKIP. Offline + deterministic; the real ~/.dark-factory is untouched."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
