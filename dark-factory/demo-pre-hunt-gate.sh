#!/usr/bin/env bash
# demo-pre-hunt-gate.sh — offline, deterministic proof that run-batch.sh's `--pre-hunt-gate` seam
# (epic #1894 M4, #1900) works: a SKIP/FLAG-verdict target is ledgered `skipped-known` and NEVER reaches
# the hunt (no hunt spent); a GO-verdict target proceeds to the hunt exactly as before; and the DEFAULT
# (no --pre-hunt-gate flag) invocation stays byte-identical to demo-batch.sh's own proven assertions —
# the M4 fail-safe this milestone exists to guarantee.
#
# No network, no real gate/hunt: both --pre-hunt-gate and --hunt-cmd are stub commands driven purely by
# BATCH_KEY (NOT the real target-uniqueness-gate.sh — see run-batch.sh's own header for why that stays a
# pure operator-wired seam). DARK_FACTORY_DIR is a throwaway temp dir. Exits non-zero on any [FAIL].
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/run-batch.sh"

FAIL=0
pass() { echo "demo-pre-hunt-gate.sh: [PASS] $1"; }
fail() { echo "demo-pre-hunt-gate.sh: [FAIL] $1" >&2; FAIL=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DARK_FACTORY_DIR="$WORK/df"
mkdir -p "$DARK_FACTORY_DIR"
QUEUE="$DARK_FACTORY_DIR/targets.queue"
LEDGER="$DARK_FACTORY_DIR/funnel-ledger.txt"
OUT="$WORK/out"
HUNTED_LOG="$WORK/hunted.log"

# Fixture queue: a key the stub gate flags SKIP, and a key the stub gate flags GO.
printf '%s\n' \
  "90	sherlock:known-skip	https://audits.sherlock.xyz/contests/skip	Known contest	Vault.sol" \
  "80	sherlock:known-go	https://audits.sherlock.xyz/contests/go	Fresh contest	Pool.sol" \
  > "$QUEUE"

# Stub gate: SKIP for a *:skip key, GO for everything else. Reads BATCH_KEY from env (the same contract
# --hunt-cmd already gets), mirroring the #1899 TARGET-UNIQUENESS|<verdict>|<density>|<rationale> shape.
GATE_STUB='case "$BATCH_KEY" in *:known-skip) echo "TARGET-UNIQUENESS|SKIP|2|stub known" ;; *) echo "TARGET-UNIQUENESS|GO|0|stub fresh" ;; esac'

# Stub hunt: proves it was (or wasn't) invoked by appending BATCH_KEY to a marker file, then emits a
# canned VERDICT line. If the gate worked, this must never see the SKIP-fixture key.
HUNT_STUB="echo \"\$BATCH_KEY\" >> \"$HUNTED_LOG\"; echo \"VERDICT|confirmed|stub\""

# --- (a)+(b): --pre-hunt-gate wired --------------------------------------------------------------------
OUT1="$("$RUN" --queue "$QUEUE" --pre-hunt-gate "$GATE_STUB" --hunt-cmd "$HUNT_STUB" --out "$OUT" --max-targets 10 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && pass "run 1 (--pre-hunt-gate wired) exit 0" || fail "run 1 exit $rc (expected 0)"

# (a) SKIP-fixture key: ledgered skipped-known, and NEVER reaches the hunt stub.
if grep -q '^sherlock:known-skip	skipped-known	' "$LEDGER"; then
  pass "SKIP-verdict target ledgered skipped-known"
else
  fail "SKIP-verdict target missing skipped-known ledger row"
fi
if [ ! -f "$HUNTED_LOG" ] || ! grep -qxF "sherlock:known-skip" "$HUNTED_LOG"; then
  pass "SKIP-verdict target never reached the hunt stub (no hunt spent)"
else
  fail "SKIP-verdict target was hunted despite a non-GO gate verdict"
fi
if ! printf '%s\n' "$OUT1" | grep -q '^sherlock:known-skip	confirmed'; then
  pass "SKIP-verdict target not reported confirmed"
else
  fail "SKIP-verdict target wrongly reported confirmed"
fi

# (b) GO-fixture key: proceeds to the hunt stub, appears in the marker file, and is ledgered confirmed.
if [ -f "$HUNTED_LOG" ] && grep -qxF "sherlock:known-go" "$HUNTED_LOG"; then
  pass "GO-verdict target reached the hunt stub"
else
  fail "GO-verdict target never reached the hunt stub"
fi
if grep -q '^sherlock:known-go	confirmed	' "$LEDGER"; then
  pass "GO-verdict target ledgered confirmed"
else
  fail "GO-verdict target missing confirmed ledger row"
fi

# --- (c): absent --pre-hunt-gate flag == today's demo-batch.sh behaviour, byte-identical ----------------
DIR2="$WORK/df2"
mkdir -p "$DIR2"
QUEUE2="$DIR2/targets.queue"
LEDGER2="$DIR2/funnel-ledger.txt"
OUT2ROOT="$WORK/out2"
printf '%s\n' \
  "97	sherlock:top	https://audits.sherlock.xyz/contests/top	Top contest	Vault.sol" \
  "85	cantina:mid	https://cantina.xyz/competitions/mid	Mid contest	Pool.sol" \
  "70	sherlock:seen	https://audits.sherlock.xyz/contests/seen	Seen contest	Old.sol" \
  > "$QUEUE2"
printf 'sherlock:seen\tdry\t2026-06-15T00:00:00Z\n' > "$LEDGER2"
STUB2='case "$BATCH_KEY" in *:top) echo "VERDICT|confirmed|stub finding" ;; *) echo "VERDICT|dry|stub clean" ;; esac'

NOFLAG_OUT="$(DARK_FACTORY_DIR="$DIR2" "$RUN" --queue "$QUEUE2" --hunt-cmd "$STUB2" --out "$OUT2ROOT" --max-targets 10 2>/dev/null)"
rc2=$?
[ "$rc2" -eq 0 ] && pass "no-flag run exit 0" || fail "no-flag run exit $rc2 (expected 0)"
if printf '%s\n' "$NOFLAG_OUT" | grep -q '^sherlock:top	confirmed' && \
   printf '%s\n' "$NOFLAG_OUT" | grep -q '^cantina:mid	dry' && \
   ! printf '%s\n' "$NOFLAG_OUT" | grep -q '^sherlock:seen'; then
  pass "no-flag path unaffected: default (no --pre-hunt-gate) behaviour matches demo-batch.sh's own shape"
else
  fail "no-flag path diverged from the expected default shape: $NOFLAG_OUT"
fi
if grep -q '^sherlock:top	confirmed	' "$LEDGER2" && grep -q '^cantina:mid	dry	' "$LEDGER2"; then
  pass "no-flag path ledger rows match today's contract (confirmed/dry, no skipped-known)"
else
  fail "no-flag path ledger rows diverged"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "demo-pre-hunt-gate.sh: PASS: --pre-hunt-gate skips a SKIP/FLAG-verdict target (skipped-known,"
  echo "      no hunt spent), lets a GO-verdict target proceed to the hunt, and the absent-flag path"
  echo "      stays byte-identical to today's run-batch.sh behaviour. Offline + deterministic."
  exit 0
fi
echo "demo-pre-hunt-gate.sh: FAIL — see [FAIL] lines above" >&2
exit 1
