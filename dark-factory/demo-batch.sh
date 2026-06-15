#!/usr/bin/env bash
# demo-batch.sh — offline, deterministic proof that run-batch.sh consumes the funnel queue, hunts each
# fresh target via a pluggable hunt-cmd, stages a confirmed finding (NEVER submitting), records every
# outcome to the dedup ledger, and is resumable (a re-run skips everything already in the ledger).
#
# No network, no real hunt: the hunt is a stub --hunt-cmd that returns canned VERDICT lines, and
# DARK_FACTORY_DIR is a throwaway temp dir. Exits non-zero on any failed assertion.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/run-batch.sh"

FAIL=0
pass() { echo "demo-batch.sh: [PASS] $1"; }
fail() { echo "demo-batch.sh: [FAIL] $1" >&2; FAIL=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DARK_FACTORY_DIR="$WORK/df"
mkdir -p "$DARK_FACTORY_DIR"
QUEUE="$DARK_FACTORY_DIR/targets.queue"
LEDGER="$DARK_FACTORY_DIR/funnel-ledger.txt"
OUT="$WORK/out"

# Fixture queue (already score-desc, as the funnel emits): a confirmed lead on top, a dry one, and a
# candidate whose key is pre-seeded in the ledger (must be skipped as already-processed).
printf '%s\n' \
  "97	sherlock:top	https://audits.sherlock.xyz/contests/top	Top contest	Vault.sol" \
  "85	cantina:mid	https://cantina.xyz/competitions/mid	Mid contest	Pool.sol" \
  "70	sherlock:seen	https://audits.sherlock.xyz/contests/seen	Seen contest	Old.sol" \
  > "$QUEUE"
printf 'sherlock:seen\tdry\t2026-06-15T00:00:00Z\n' > "$LEDGER"

# Stub hunt: confirmed for the *top* key, dry for everything else. Reads BATCH_KEY from env.
STUB='case "$BATCH_KEY" in *:top) echo "VERDICT|confirmed|stub finding" ;; *) echo "VERDICT|dry|stub clean" ;; esac'

OUT1="$("$RUN" --queue "$QUEUE" --hunt-cmd "$STUB" --out "$OUT" --max-targets 10 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && pass "run 1 exit 0" || fail "run 1 exit $rc (expected 0)"

# (a) processed highest-score-first: top before mid in the stdout report.
top_ln="$(printf '%s\n' "$OUT1" | grep -n '^sherlock:top' | head -1 | cut -d: -f1)"
mid_ln="$(printf '%s\n' "$OUT1" | grep -n '^cantina:mid' | head -1 | cut -d: -f1)"
if [ -n "$top_ln" ] && [ -n "$mid_ln" ] && [ "$top_ln" -lt "$mid_ln" ]; then
  pass "processed highest-score-first (sherlock:top before cantina:mid)"
else
  fail "score order wrong (top line=$top_ln mid line=$mid_ln)"
fi

# (b) the pre-ledgered key was skipped (never hunted / never re-recorded).
if ! printf '%s\n' "$OUT1" | grep -q '^sherlock:seen'; then
  pass "pre-ledgered sherlock:seen skipped (resumable dedup)"
else
  fail "sherlock:seen was processed despite being in the ledger"
fi
if [ "$(grep -c '^sherlock:seen	' "$LEDGER")" -eq 1 ]; then
  pass "sherlock:seen not duplicated in the ledger"
else
  fail "sherlock:seen ledger rows != 1"
fi

# (c) ledger gained the right key->verdict rows.
if grep -q '^sherlock:top	confirmed	' "$LEDGER"; then pass "ledger records sherlock:top -> confirmed"; else fail "missing sherlock:top confirmed row"; fi
if grep -q '^cantina:mid	dry	' "$LEDGER"; then pass "ledger records cantina:mid -> dry"; else fail "missing cantina:mid dry row"; fi

# (d) the confirmed finding was staged (and marked NOT submitted), the dry one was not.
if [ -f "$OUT/submission/sherlock:top/report.md" ] && grep -q 'NOT SUBMITTED' "$OUT/submission/sherlock:top/report.md"; then
  pass "confirmed finding staged under submission/ + marked NOT SUBMITTED"
else
  fail "confirmed finding not staged (or missing NOT-SUBMITTED marker)"
fi
if [ ! -d "$OUT/submission/cantina:mid" ]; then pass "dry target was not staged"; else fail "dry target wrongly staged"; fi

# (e) resumable: a second run skips everything now in the ledger (processes 0).
OUT2="$("$RUN" --queue "$QUEUE" --hunt-cmd "$STUB" --out "$OUT" --max-targets 10 2>/dev/null)"
rc2=$?
if [ "$rc2" -eq 0 ] && [ -z "$(printf '%s' "$OUT2" | tr -d '[:space:]')" ]; then
  pass "re-run processes 0 targets (all now in the ledger) — resumable"
else
  fail "re-run was not a clean no-op (exit $rc2, out: $OUT2)"
fi

# (f) never-submit: the runner has no platform-egress (no curl/POST in its source).
if ! grep -nE 'curl|wget|-X[[:space:]]*POST|--data' "$RUN" >/dev/null 2>&1; then
  pass "run-batch.sh has no network-egress (never submits)"
else
  fail "run-batch.sh contains an egress call — must never submit"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "demo-batch.sh: PASS: the batch runner consumed a ranked queue, hunted each fresh target via the"
  echo "      pluggable hunt-cmd, staged the confirmed finding (NOT submitted), recorded every outcome to"
  echo "      the dedup ledger, and a re-run was a clean resumable no-op. Offline + deterministic."
  exit 0
fi
echo "demo-batch.sh: FAIL — see [FAIL] lines above" >&2
exit 1
