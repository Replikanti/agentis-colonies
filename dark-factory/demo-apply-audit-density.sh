#!/usr/bin/env bash
# demo-apply-audit-density.sh — OFFLINE, DETERMINISTIC proof (#1898, epic #1894 M2) of apply-audit-density.sh:
# a queue -> queue RE-RANK that de-ranks (never drops) rows whose target is heavily audited. Mirrors demo-
# bounty-payability-gate.sh's assert-based [PASS]/[FAIL] accounting; a throwaway fixture queue + a canned
# --probe-cmd stub keyed on $PROBE_REPO (mirroring demo-batch.sh's $BATCH_KEY-keyed STUB idiom), never
# touching the real ~/.dark-factory, never a real audit-history-probe.sh network/clone path.
#
# Asserts:
#   AC1 — a heavily-audited target and an equally-scored fresh target start at the SAME score; after the run
#         the audited one's new score is strictly LOWER and it sorts BELOW the fresh one.
#   AC2 — a row with a repo the stub probe reports empty/no-JSON for (simulating unreachable/offline), and a
#         row with the `repo:-` no-repo sentinel, both keep their EXACT original score.
#   AC3 — output row COUNT equals input row count, and the row SET (by key) is identical — a permutation,
#         nothing added or dropped (asserted via a sorted-key-list diff, not just a count).
#   Bonus — a malformed row (only 3 columns) survives unchanged in the output — fail-open on garbage input.
#   AC4 — the tie-break (score DESC, key ASC) holds on rows whose post-penalty scores land EQUAL.
#
# Usage:  dark-factory/demo-apply-audit-density.sh
# Requires: python3. Exit: 0 = all assertions held; non-zero = a failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APPLY="$HERE/apply-audit-density.sh"

FAILS=0
note() { echo "demo-apply-audit-density.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$APPLY" ] || { note "apply-audit-density.sh not found / not executable: $APPLY" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-apply-audit-density.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export DARK_FACTORY_DIR="$WORK/dark-factory-home"   # never touch the real ~/.dark-factory

# ----------------------------------------------------------------------------------------------------------
# Fixture queue: 5 well-formed rows + 1 malformed (3-col) row.
#   audited     : score 50, repo the stub reports heavily_audited=true -> should sink below 'fresh' (same
#                 starting score) after the run.
#   fresh       : score 50, repo the stub reports heavily_audited=false -> unchanged, should sort ABOVE
#                 'audited' post-run (equal starting scores, tie-break would otherwise put 'audited' first
#                 on key ASC alone: "immunefi:audited" < "immunefi:fresh").
#   unreachable : score 40, repo the stub prints NOTHING for (simulates an unreachable/offline probe) ->
#                 score must stay exactly 40.
#   norepo      : score 30, scope_hint carries `repo:-` (the no-repo sentinel) -> score must stay exactly 30.
#   tieable     : score 41, repo the stub reports heavily_audited=true, penalty=1 -> new score 40, lands on
#                 an EXACT tie with 'unreachable' (also 40) -> tie-break must resolve by key ASC
#                 ("immunefi:tieable" < "immunefi:unreachable").
#   (malformed) : only 3 columns -> must survive unchanged, unrepositioned by the malformed-row rule.
# ----------------------------------------------------------------------------------------------------------
QUEUE="$WORK/queue.tsv"
{
  printf '50\timmunefi:audited\thttps://immunefi.com/bug-bounty/audited/\tAudited Co\tchain:ethereum repo:https://github.com/example/audited commit:- delta:0f/-d fee:- vault:-\n'
  printf '50\timmunefi:fresh\thttps://immunefi.com/bug-bounty/fresh/\tFresh Co\tchain:ethereum repo:https://github.com/example/fresh commit:- delta:0f/-d fee:- vault:-\n'
  printf '40\timmunefi:unreachable\thttps://immunefi.com/bug-bounty/unreachable/\tUnreachable Co\tchain:ethereum repo:https://github.com/example/unreachable commit:- delta:0f/-d fee:- vault:-\n'
  printf '30\timmunefi:norepo\thttps://immunefi.com/bug-bounty/norepo/\tNo Repo Co\tchain:ethereum repo:- commit:- delta:0f/-d fee:- vault:-\n'
  printf '41\timmunefi:tieable\thttps://immunefi.com/bug-bounty/tieable/\tTieable Co\tchain:ethereum repo:https://github.com/example/tieable commit:- delta:0f/-d fee:- vault:-\n'
  printf 'onlythree\tcolumns\there\n'
} > "$QUEUE"

# The --probe-cmd stub: keyed on $PROBE_REPO, prints a canned JSON verdict (or nothing, for 'unreachable').
STUB='case "$PROBE_REPO" in
  *example/audited) printf "%s" "{\"heavily_audited\":true,\"repo_audit_density\":42}";;
  *example/fresh)   printf "%s" "{\"heavily_audited\":false,\"repo_audit_density\":1}";;
  *example/tieable) printf "%s" "{\"heavily_audited\":true,\"repo_audit_density\":37}";;
  *) ;;
esac'

# ----------------------------------------------------------------------------------------------------------
note "1) --probe-cmd stub, --penalty 1 (tieable: 41 -> 40, ties 'unreachable' at 40) ..."
OUT1="$WORK/out1.tsv"
APPLY_STDOUT="$("$APPLY" --queue "$QUEUE" --probe-cmd "$STUB" --penalty 1 --out "$OUT1" 2>"$WORK/stderr1.txt")"
RC=$?
[ "$RC" -eq 0 ] && ok "exits 0 on a re-rank run" || bad "exited $RC (expected 0)"

score_of() { printf '%s\n' "$APPLY_STDOUT" | awk -F'\t' -v k="$1" '$2==k{print $1}'; }
rank_of()  { printf '%s\n' "$APPLY_STDOUT" | awk -F'\t' -v k="$1" '{n++} $2==k{print n; exit}'; }

# AC1: 'audited' sinks strictly below 'fresh' (equal starting score, audited de-ranked).
AUD_SCORE="$(score_of "immunefi:audited")"
FRESH_SCORE="$(score_of "immunefi:fresh")"
if [ "$AUD_SCORE" -lt 50 ]; then ok "AC1: heavily-audited row's score dropped below its original 50 (got $AUD_SCORE)"
else bad "AC1 FAILED: heavily-audited row's score did not drop (got $AUD_SCORE, want < 50)"; fi
[ "$FRESH_SCORE" -eq 50 ] && ok "AC1: the equally-scored fresh row's score stayed 50" \
  || bad "AC1 FAILED: fresh row's score changed (got $FRESH_SCORE, want 50)"
AUD_RANK="$(rank_of "immunefi:audited")"
FRESH_RANK="$(rank_of "immunefi:fresh")"
if [ "$AUD_RANK" -gt "$FRESH_RANK" ]; then ok "AC1: 'audited' (rank $AUD_RANK) sorts below 'fresh' (rank $FRESH_RANK)"
else bad "AC1 FAILED: 'audited' (rank $AUD_RANK) did not sort below 'fresh' (rank $FRESH_RANK)"; fi

# AC2: 'unreachable' (stub prints nothing) and 'norepo' (repo:-) keep their EXACT original score.
UNREACH_SCORE="$(score_of "immunefi:unreachable")"
[ "$UNREACH_SCORE" -eq 40 ] && ok "AC2: unreachable-probe row's score is untouched (40)" \
  || bad "AC2 FAILED: unreachable-probe row's score changed (got $UNREACH_SCORE, want 40)"
NOREPO_SCORE="$(score_of "immunefi:norepo")"
[ "$NOREPO_SCORE" -eq 30 ] && ok "AC2: repo:- (no-repo sentinel) row's score is untouched (30)" \
  || bad "AC2 FAILED: repo:- row's score changed (got $NOREPO_SCORE, want 30)"

# AC4: 'tieable' (41 - penalty 1 = 40) exact-ties 'unreachable' (40) -> tie-break resolves by key ASC.
TIE_SCORE="$(score_of "immunefi:tieable")"
[ "$TIE_SCORE" -eq 40 ] && ok "AC4 setup: 'tieable' penalized to an exact tie (40) with 'unreachable'" \
  || bad "AC4 FAILED setup: 'tieable' score is $TIE_SCORE, expected 40 (penalty math)"
TIE_RANK="$(rank_of "immunefi:tieable")"
UNREACH_RANK="$(rank_of "immunefi:unreachable")"
if [ "$TIE_SCORE" -eq "$UNREACH_SCORE" ]; then
  if [ "$TIE_RANK" -lt "$UNREACH_RANK" ]; then
    ok "AC4: on an exact score tie (40=40), 'immunefi:tieable' sorts before 'immunefi:unreachable' (key ASC)"
  else
    bad "AC4 FAILED: tie-break did not resolve by key ASC (tieable rank $TIE_RANK, unreachable rank $UNREACH_RANK)"
  fi
fi

# AC3: row count in == row count out, and the row SET (by key, col 2) is identical (permutation, nothing
# added/dropped). The malformed 3-col row has no col-2 "key" in the TSV sense, so it is checked separately.
IN_COUNT="$(wc -l < "$QUEUE" | tr -d ' ')"
OUT_COUNT="$(printf '%s\n' "$APPLY_STDOUT" | grep -c .)"
[ "$IN_COUNT" -eq "$OUT_COUNT" ] && ok "AC3: row count preserved ($IN_COUNT in == $OUT_COUNT out)" \
  || bad "AC3 FAILED: row count changed ($IN_COUNT in != $OUT_COUNT out)"

IN_KEYS="$(awk -F'\t' 'NF==5{print $2}' "$QUEUE" | LC_ALL=C sort)"
OUT_KEYS="$(printf '%s\n' "$APPLY_STDOUT" | awk -F'\t' 'NF==5{print $2}' | LC_ALL=C sort)"
if [ "$IN_KEYS" = "$OUT_KEYS" ]; then
  ok "AC3: the row SET (by key) is identical between input and output — a pure permutation"
else
  bad "AC3 FAILED: row set differs — got [$OUT_KEYS] want [$IN_KEYS]"
fi

# Bonus: the malformed (3-col) row survives unchanged in the output.
if printf '%s\n' "$APPLY_STDOUT" | grep -qxF "$(printf 'onlythree\tcolumns\there')"; then
  ok "Bonus: the malformed 3-col row survives byte-identical (fail-open on garbage input)"
else
  bad "Bonus FAILED: the malformed 3-col row was dropped or rewritten"
fi

# Summary line lands on stderr (penalized/kept counts).
grep -q "penalized" "$WORK/stderr1.txt" && ok "a penalized/kept summary is printed to stderr" \
  || bad "no penalized/kept summary found on stderr: $(cat "$WORK/stderr1.txt")"

# --out file equals the stdout view.
if [ "$(cat "$OUT1" 2>/dev/null)" = "$APPLY_STDOUT" ]; then
  ok "the --out file equals the stdout view"
else
  bad "the --out file differs from stdout"
fi

# ----------------------------------------------------------------------------------------------------------
note "2) empty / missing queue -> [SKIP], exit 0, --out unwritten ..."
EMPTY_QUEUE="$WORK/empty.tsv"
: > "$EMPTY_QUEUE"
OUT2="$WORK/out2.tsv"
"$APPLY" --queue "$EMPTY_QUEUE" --probe-cmd "$STUB" --out "$OUT2" >/dev/null 2>"$WORK/stderr2.txt"
RC=$?
[ "$RC" -eq 0 ] && ok "empty-queue run exits 0" || bad "empty-queue run exited $RC (expected 0)"
grep -q "\[SKIP\]" "$WORK/stderr2.txt" && ok "empty queue -> a [SKIP] line" || bad "no [SKIP] on an empty queue"
[ -e "$OUT2" ] && bad "--out was written despite the [SKIP]" || ok "--out is left unwritten on [SKIP]"

# ----------------------------------------------------------------------------------------------------------
note "3) --penalty must be a non-negative integer -> bad args exit 2 ..."
"$APPLY" --queue "$QUEUE" --penalty "-5" >/dev/null 2>/dev/null
RC=$?
[ "$RC" -eq 2 ] && ok "a negative --penalty is rejected with exit 2" \
  || bad "a negative --penalty exited $RC (expected 2)"

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: apply-audit-density.sh de-ranked the heavily-audited target below its equally-scored fresh"
  note "      peer, left unreachable/no-repo rows' scores untouched, resolved an exact post-penalty tie by"
  note "      key ASC, preserved row count AND row set as a pure permutation, and fail-open passed a"
  note "      malformed row through unchanged. Offline + deterministic; never touches the real ~/.dark-factory."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
