#!/bin/bash
# tools/test-cross-fed-bridge.sh -- smoke tests for the cross-fed:* bridge
# sidecar (Phase 8 PR-1 of #629).
#
# Exercises the bidirectional sync, lock acquisition, sha256 dedupe,
# and pollination-ledger merge paths without spawning agents. The
# Python helper is invoked directly for the unit-level assertions
# (sync_host_to_memo / sync_memo_to_host) and the shell wrapper is
# invoked for the lock + sidecar paths.
#
# Standard library only -- no pytest, no third-party deps.
#
# Usage: bash tools/test-cross-fed-bridge.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE_SH="$SCRIPT_DIR/cross-fed-bridge.sh"
BRIDGE_PY="$SCRIPT_DIR/cross-fed-bridge.py"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -x "$BRIDGE_SH" ]; then
    fail "cross-fed-bridge.sh executable" "$BRIDGE_SH not executable"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if [ ! -f "$BRIDGE_PY" ]; then
    fail "cross-fed-bridge.py present" "$BRIDGE_PY missing"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Test 1: bash -n on the shell wrapper ---
if bash -n "$BRIDGE_SH" 2>/dev/null; then
    pass "1. bash -n clean on cross-fed-bridge.sh"
else
    fail "1. bash -n clean on cross-fed-bridge.sh" "$(bash -n "$BRIDGE_SH" 2>&1)"
fi

# --- Test 2: python3 -m ast clean on the helper ---
if python3 -m ast "$BRIDGE_PY" >/dev/null 2>&1; then
    pass "2. python3 -m ast clean on cross-fed-bridge.py"
else
    fail "2. python3 -m ast clean on cross-fed-bridge.py" \
        "$(python3 -m ast "$BRIDGE_PY" 2>&1 | head -3)"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- Test 3a: bidirectional sync, host -> memo ---
# Stage a method file in the host dir, run sync_host_to_memo via the
# helper, then assert the fed memo store has the expected key.
HOST_DIR="$WORK_DIR/host"
FED_DIR="$WORK_DIR/fed-target"
mkdir -p "$HOST_DIR/method/test-fed"
mkdir -p "$FED_DIR/.agentis/memo"

cat > "$HOST_DIR/method/test-fed/abc.json" <<'EOF'
{"id":"abc","source_fed":"test-fed","abstract":"demo method"}
EOF

H2M_OUT="$(python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR')
import importlib.util
spec = importlib.util.spec_from_file_location('cfb', '$BRIDGE_PY')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
from pathlib import Path
n = mod.sync_host_to_memo(Path('$HOST_DIR'), Path('$FED_DIR'))
print('appended=%d' % n)
" 2>&1)" || true

MEMO_FILE="$FED_DIR/.agentis/memo/cross-fed:method:test-fed:abc.jsonl"
if [ -f "$MEMO_FILE" ] && [ -s "$MEMO_FILE" ]; then
    pass "3a. sync_host_to_memo creates expected memo key"
else
    fail "3a. sync_host_to_memo creates expected memo key" \
        "expected $MEMO_FILE; out=$H2M_OUT"
fi

# --- Test 3b: bidirectional sync, memo -> host ---
# Write a different method record to the fed memo, then sync to host.
SOURCE_FED_DIR="$WORK_DIR/fed-source"
mkdir -p "$SOURCE_FED_DIR/.agentis/memo"
DEF_RECORD='{"value":{"id":"def","source_fed":"test-fed","abstract":"another method"}}'
echo "$DEF_RECORD" > "$SOURCE_FED_DIR/.agentis/memo/cross-fed:method:test-fed:def.jsonl"

M2H_OUT="$(python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR')
import importlib.util
spec = importlib.util.spec_from_file_location('cfb', '$BRIDGE_PY')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
from pathlib import Path
n = mod.sync_memo_to_host(Path('$SOURCE_FED_DIR'), Path('$HOST_DIR'))
print('written=%d' % n)
" 2>&1)" || true

HOST_FILE="$HOST_DIR/method/test-fed/def.json"
if [ -f "$HOST_FILE" ] && grep -q 'def' "$HOST_FILE"; then
    pass "3b. sync_memo_to_host creates expected host file"
else
    fail "3b. sync_memo_to_host creates expected host file" \
        "expected $HOST_FILE with payload; out=$M2H_OUT; got=$(cat "$HOST_FILE" 2>/dev/null || echo MISSING)"
fi

# --- Test 4: lock acquisition (only one sidecar at a time) ---
# Spawn two parallel `cross-fed-bridge.sh sidecar` invocations against
# the same host dir; the first holds the lock indefinitely (we cap it
# at 5s via a kill), the second must log `lock held` and exit 0.
LOCK_FED_A="$WORK_DIR/fed-locker-a"
LOCK_FED_B="$WORK_DIR/fed-locker-b"
LOCK_HOST="$WORK_DIR/lock-host"
mkdir -p "$LOCK_FED_A/.agentis/memo" "$LOCK_FED_B/.agentis/memo" "$LOCK_HOST"

# Start first sidecar in background; it owns the lock.
CROSS_FED_HOST_DIR="$LOCK_HOST" "$BRIDGE_SH" sidecar "$LOCK_FED_A" --interval 60 \
    >"$WORK_DIR/sidecar-a.log" 2>&1 &
PID_A=$!

# Wait briefly so PID_A has time to take the lock before PID_B starts.
sleep 1

# Second sidecar must observe the lock is held and bail out.
CROSS_FED_HOST_DIR="$LOCK_HOST" "$BRIDGE_SH" sidecar "$LOCK_FED_B" --interval 60 \
    >"$WORK_DIR/sidecar-b.log" 2>&1 &
PID_B=$!

# Give PID_B time to attempt the lock then exit.
sleep 1

# Reap PID_B (should already be gone); PID_A is still looping, kill it.
wait "$PID_B" 2>/dev/null || true
kill "$PID_A" 2>/dev/null || true
wait "$PID_A" 2>/dev/null || true

if grep -Fq "lock held by other process" "$WORK_DIR/sidecar-b.log"; then
    pass "4. second sidecar logs lock-held and exits 0"
else
    fail "4. second sidecar logs lock-held and exits 0" \
        "$(cat "$WORK_DIR/sidecar-b.log" 2>/dev/null | head -5)"
fi

# --- Test 5: empty host dir -> no-op ---
EMPTY_HOST="$WORK_DIR/empty-host"
EMPTY_FED="$WORK_DIR/empty-fed"
mkdir -p "$EMPTY_HOST" "$EMPTY_FED/.agentis/memo"

EMPTY_OUT="$(python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR')
import importlib.util
spec = importlib.util.spec_from_file_location('cfb', '$BRIDGE_PY')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
from pathlib import Path
n = mod.sync_host_to_memo(Path('$EMPTY_HOST'), Path('$EMPTY_FED'))
print('appended=%d' % n)
" 2>&1)"

# Memo dir must remain empty (no `.jsonl` files).
WROTE="$(find "$EMPTY_FED/.agentis/memo" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$EMPTY_OUT" = "appended=0" ] && [ "$WROTE" = "0" ]; then
    pass "5. empty host dir -> no-op (no memo writes)"
else
    fail "5. empty host dir -> no-op (no memo writes)" \
        "out=$EMPTY_OUT wrote=$WROTE"
fi

# --- Test 6: sha256 dedupe on re-sync ---
# Run sync_memo_to_host twice with identical fed memo content. After
# the first call the host file mtime is recorded; after the second
# call (no source change) the mtime must not advance.
DEDUPE_FED="$WORK_DIR/dedupe-fed"
DEDUPE_HOST="$WORK_DIR/dedupe-host"
mkdir -p "$DEDUPE_FED/.agentis/memo" "$DEDUPE_HOST"
echo '{"value":{"id":"xyz","x":1}}' > "$DEDUPE_FED/.agentis/memo/cross-fed:method:dedupe-fed:xyz.jsonl"

python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR')
import importlib.util
spec = importlib.util.spec_from_file_location('cfb', '$BRIDGE_PY')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
from pathlib import Path
mod.sync_memo_to_host(Path('$DEDUPE_FED'), Path('$DEDUPE_HOST'))
" >/dev/null 2>&1

DEDUPE_FILE="$DEDUPE_HOST/method/dedupe-fed/xyz.json"
if [ ! -f "$DEDUPE_FILE" ]; then
    fail "6. sha256 dedupe on re-sync" "first sync did not produce $DEDUPE_FILE"
else
    MTIME_BEFORE="$(stat -c %Y "$DEDUPE_FILE" 2>/dev/null || stat -f %m "$DEDUPE_FILE" 2>/dev/null)"
    # Sleep so any mtime advance would be observable.
    sleep 1
    SECOND_OUT="$(python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR')
import importlib.util
spec = importlib.util.spec_from_file_location('cfb', '$BRIDGE_PY')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
from pathlib import Path
n = mod.sync_memo_to_host(Path('$DEDUPE_FED'), Path('$DEDUPE_HOST'))
print('written=%d' % n)
")"
    MTIME_AFTER="$(stat -c %Y "$DEDUPE_FILE" 2>/dev/null || stat -f %m "$DEDUPE_FILE" 2>/dev/null)"
    if [ "$SECOND_OUT" = "written=0" ] && [ "$MTIME_BEFORE" = "$MTIME_AFTER" ]; then
        pass "6. sha256 dedupe on re-sync (no write, no mtime change)"
    else
        fail "6. sha256 dedupe on re-sync (no write, no mtime change)" \
            "second-out=$SECOND_OUT mtime_before=$MTIME_BEFORE mtime_after=$MTIME_AFTER"
    fi
fi

# --- Test 7: pollination-ledger merge ---
# Stage per-fed ledgers, invoke merge-ledgers with paths on stdin,
# assert the central ledger holds every row in timestamp order.
MERGE_HOST="$WORK_DIR/merge-host"
mkdir -p "$MERGE_HOST"
LEDGER_A="$WORK_DIR/fed-ledger-a.jsonl"
LEDGER_B="$WORK_DIR/fed-ledger-b.jsonl"
cat > "$LEDGER_A" <<'EOF'
{"ts": 1000, "event": "export", "fed": "a", "method_id": "alpha"}
{"ts": 3000, "event": "export", "fed": "a", "method_id": "gamma"}
EOF
cat > "$LEDGER_B" <<'EOF'
{"ts": 2000, "event": "export", "fed": "b", "method_id": "beta"}
{"ts": 4000, "event": "export", "fed": "b", "method_id": "delta"}
EOF

printf '%s\n%s\n' "$LEDGER_A" "$LEDGER_B" | python3 "$BRIDGE_PY" merge-ledgers "$MERGE_HOST" >/dev/null 2>&1 || true

CENTRAL="$MERGE_HOST/pollination-ledger.jsonl"
if [ ! -f "$CENTRAL" ]; then
    fail "7. pollination-ledger merge" "central ledger not at $CENTRAL"
else
    # Validate exact ordering on the `ts` field (alpha, beta, gamma, delta).
    MERGED_ORDER="$(python3 -c "
import json, sys
rows = []
with open('$CENTRAL') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line)['method_id'])
print(','.join(rows))
" 2>/dev/null)"
    if [ "$MERGED_ORDER" = "alpha,beta,gamma,delta" ]; then
        pass "7. pollination-ledger merge (correct timestamp order)"
    else
        fail "7. pollination-ledger merge (correct timestamp order)" \
            "got order: $MERGED_ORDER"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
