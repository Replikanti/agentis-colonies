#!/usr/bin/env bash
# demo-owner-assert.sh — proof (#1457) that the snapshot-replay harness closes the owner-rebind gap:
# it reads the account's REAL on-chain owner from the dump, emits an EXPLICIT machine-checkable
# OWNER REBIND / OWNER MATCH / OWNER MISMATCH marker instead of a silent mismatch, and — when the
# operator supplies EXPECT_PROGRAM_OWNER (run-audit's --expect-owner) — HARD-ASSERTS owner-match,
# refusing a mismatch as INCONCLUSIVE (exit 3) so a re-owned copy is never reported VERIFIED.
#
# Two layers, so CI (no Solana toolchain) still gates the behaviour:
#   1. SOURCE GUARD (always, CI-safe): the harness + run-audit wiring contain the required logic.
#   2. LIVE RUN (only when the compiled poc_snapshot binary is present): exercise the 3 modes for real.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SNAP_RS="$HERE/solana-harness/src/bin/poc_snapshot.rs"
RUN_AUDIT="$HERE/run-audit.sh"

FAIL=0
pass() { echo "demo-owner-assert.sh: [PASS] $1"; }
fail() { echo "demo-owner-assert.sh: [FAIL] $1" >&2; FAIL=1; }

# --- 1. SOURCE GUARD (CI-safe) ---------------------------------------------------------------------------
[ -f "$SNAP_RS" ] || { echo "demo-owner-assert.sh: [FAIL] poc_snapshot.rs missing at $SNAP_RS" >&2; exit 1; }

grep -q 'field_str(&snap, "account.owner")' "$SNAP_RS" \
  && pass "harness reads the snapshot's real on-chain owner (account.owner)" \
  || fail "harness does not read account.owner from the snapshot"

grep -q 'OWNER REBIND:' "$SNAP_RS" \
  && pass "harness emits an explicit OWNER REBIND disclosure marker" \
  || fail "harness missing OWNER REBIND marker"

grep -q 'OWNER MATCH:' "$SNAP_RS" && grep -q 'OWNER MISMATCH:' "$SNAP_RS" \
  && pass "harness emits OWNER MATCH / OWNER MISMATCH under EXPECT_PROGRAM_OWNER" \
  || fail "harness missing OWNER MATCH / OWNER MISMATCH markers"

# The mismatch branch must exit 3 (INCONCLUSIVE) — assert the exit lives in the MISMATCH path.
if awk '/OWNER MISMATCH:/{m=1} m&&/std::process::exit\(3\)/{print "ok"; exit}' "$SNAP_RS" | grep -q ok; then
  pass "owner mismatch refuses the replay with exit 3 (INCONCLUSIVE), before the exploit"
else
  fail "owner mismatch does not exit 3 in the MISMATCH branch"
fi

grep -q 'EXPECT_PROGRAM_OWNER' "$SNAP_RS" \
  && pass "harness gates the hard-assert on EXPECT_PROGRAM_OWNER" \
  || fail "harness missing EXPECT_PROGRAM_OWNER gate"

# run-audit wiring: the --expect-owner flag reaches the harness (env + passthrough allowlist).
if [ -f "$RUN_AUDIT" ]; then
  grep -q -- '--expect-owner' "$RUN_AUDIT" \
    && pass "run-audit exposes --expect-owner" || fail "run-audit missing --expect-owner flag"
  grep -q 'ENV+=(EXPECT_PROGRAM_OWNER=' "$RUN_AUDIT" \
    && pass "run-audit passes EXPECT_PROGRAM_OWNER into the audit env" \
    || fail "run-audit does not set EXPECT_PROGRAM_OWNER in ENV"
  grep -q 'env_passthrough = .*EXPECT_PROGRAM_OWNER' "$RUN_AUDIT" \
    && pass "run-audit allowlists EXPECT_PROGRAM_OWNER on exec.env_passthrough" \
    || fail "EXPECT_PROGRAM_OWNER not on run-audit's exec.env_passthrough (would be silently stripped)"
fi

# --- 2. LIVE RUN (only when the harness binary is already built) ------------------------------------------
BIN=""
for cand in "$HERE/solana-harness/target/debug/poc_snapshot" "$HERE/solana-harness/target/release/poc_snapshot"; do
  [ -x "$cand" ] && BIN="$cand" && break
done

if [ -z "$BIN" ]; then
  echo "demo-owner-assert.sh: [SKIP] poc_snapshot not built (no Solana toolchain here) — source guard only" >&2
else
  WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
  OWNER='So11111111111111111111111111111111111111112'
  cat > "$WORK/snapshot.txt" <<EOF
account.owner=$OWNER
account.lamports=1000000000
account.data_first8_le=500000
EOF
  # Mode 1: default -> OWNER REBIND marker + proceeds to the two-sided verdict (exit 101).
  out1="$(cd "$WORK" && "$BIN" 2>&1)"; ec1=$?
  { printf '%s' "$out1" | grep -q "OWNER REBIND: snapshot account owner $OWNER"; } && [ "$ec1" -eq 101 ] \
    && pass "live: default run discloses OWNER REBIND with the real owner and reaches the verdict" \
    || fail "live: default run wrong (exit $ec1)"
  # Mode 2: EXPECT matches -> OWNER MATCH + proceeds.
  out2="$(cd "$WORK" && EXPECT_PROGRAM_OWNER="$OWNER" "$BIN" 2>&1)"; ec2=$?
  { printf '%s' "$out2" | grep -q 'OWNER MATCH:'; } && [ "$ec2" -eq 101 ] \
    && pass "live: EXPECT_PROGRAM_OWNER match -> OWNER MATCH, proceeds" \
    || fail "live: match run wrong (exit $ec2)"
  # Mode 3: EXPECT mismatches -> OWNER MISMATCH + exit 3, and the exploit must NOT have run.
  out3="$(cd "$WORK" && EXPECT_PROGRAM_OWNER='DifferentOwner11111111111111111111111111111' "$BIN" 2>&1)"; ec3=$?
  if printf '%s' "$out3" | grep -q 'OWNER MISMATCH:' && [ "$ec3" -eq 3 ] \
     && ! printf '%s' "$out3" | grep -q 'INVARIANT VIOLATED'; then
    pass "live: EXPECT_PROGRAM_OWNER mismatch -> OWNER MISMATCH, exit 3, exploit NOT run"
  else
    fail "live: mismatch run wrong (exit $ec3; must be 3 with no INVARIANT VIOLATED)"
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "demo-owner-assert.sh: ALL CHECKS PASSED"
  exit 0
else
  echo "demo-owner-assert.sh: FAILURES ABOVE" >&2
  exit 1
fi
