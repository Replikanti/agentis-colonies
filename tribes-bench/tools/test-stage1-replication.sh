#!/bin/bash
# test-stage1-replication.sh — pure-offline assertions for Stage 1 M2.
#
# Verifies that:
#   1. All three hunter.ag files contain a `replicate(` call.
#   2. All three hunter.ag files contain Malthusian cost arithmetic
#      (`base * n`/`/ k` form) and a max_replicas guard.
#   3. The Malthusian cost formula `cost(n) = base + (base * n) / k`
#      computes expected values for representative tribe sizes.
#   4. start-colony.sh launches add `--enable-replication` and
#      `--allow-replica-replication` to BOTH the main launch AND the
#      `--restart-agent` paths.
#   5. start-federation.sh spawns an `agentis worker` when RUN_DIR is
#      set (without depending on a live agentis binary; we grep the
#      script source).
#
# The test does not exercise replicate() at runtime: that would need a
# colony worker and a live federation. The exercise is offline so it
# stays CI-friendly.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_contains() {
    # $1 label, $2 file, $3 needle (literal substring)
    local label="$1" file="$2" needle="$3"
    if grep -Fq -- "$needle" "$file"; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       file:   $file"
        echo "       needle: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_eq() {
    # $1 label, $2 expected, $3 got
    local label="$1" exp="$2" got="$3"
    if [ "$exp" = "$got" ]; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       expected: $exp"
        echo "       got:      $got"
        FAIL=$((FAIL + 1))
    fi
}

# --- 1. replicate() calls present in all three hunters ---
for tribe in tribe-alpha tribe-beta tribe-gamma; do
    assert_contains "$tribe hunter.ag has replicate(" \
        "$FED_DIR/$tribe/agents/hunter.ag" "replicate("
done

# --- 2. Malthusian cost arithmetic + max_replicas gate ---
for tribe in tribe-alpha tribe-beta tribe-gamma; do
    assert_contains "$tribe hunter.ag computes Malthusian cost (base + base*n/k)" \
        "$FED_DIR/$tribe/agents/hunter.ag" "base + (base * n) / k"
    assert_contains "$tribe hunter.ag reads max_replicas memo" \
        "$FED_DIR/$tribe/agents/hunter.ag" ":max_replicas"
done

# --- 3. Malthusian cost formula sanity (shell arithmetic) ---
malthusian() {
    # $1 base, $2 n, $3 k
    local base="$1" n="$2" k="$3"
    echo "$((base + (base * n) / k))"
}

assert_eq "C(0, base=100, k=3) == 100" "100" "$(malthusian 100 0 3)"
assert_eq "C(1, base=100, k=3) == 133" "133" "$(malthusian 100 1 3)"
assert_eq "C(3, base=100, k=3) == 200" "200" "$(malthusian 100 3 3)"
assert_eq "C(5, base=100, k=3) == 266" "266" "$(malthusian 100 5 3)"
assert_eq "C(0, base=200, k=4) == 200" "200" "$(malthusian 200 0 4)"
assert_eq "C(2, base=200, k=4) == 300" "300" "$(malthusian 200 2 4)"

# --- 4. start-colony.sh has --enable-replication on BOTH paths ---
for tribe in tribe-alpha tribe-beta tribe-gamma; do
    cnt="$(grep -c -- '--enable-replication' "$FED_DIR/$tribe/scripts/start-colony.sh" || true)"
    assert_eq "$tribe start-colony.sh: --enable-replication on >=2 lines (main + restart)" \
        "yes" "$([ "$cnt" -ge 2 ] && echo yes || echo no)"
    cnt="$(grep -c -- '--allow-replica-replication' "$FED_DIR/$tribe/scripts/start-colony.sh" || true)"
    assert_eq "$tribe start-colony.sh: --allow-replica-replication on >=2 lines (main + restart)" \
        "yes" "$([ "$cnt" -ge 2 ] && echo yes || echo no)"
done

# --- 5. start-federation.sh spawns agentis worker when RUN_DIR set ---
assert_contains "start-federation.sh spawns agentis worker" \
    "$FED_DIR/start-federation.sh" "agentis worker"
assert_contains "start-federation.sh writes worker.pid" \
    "$FED_DIR/start-federation.sh" "worker.pid"
assert_contains "start-federation.sh seeds tribes-bench:worker_addr memo" \
    "$FED_DIR/start-federation.sh" "tribes-bench:worker_addr"
assert_contains "start-federation.sh writes colony.secret to hermetic config" \
    "$FED_DIR/start-federation.sh" "colony.secret"
assert_contains "start-federation.sh binds colony.secret to \$WORKER_SECRET" \
    "$FED_DIR/start-federation.sh" 'colony.secret = %s'

# --- 6. start-colony.sh seeds the M2+M3 economy memos ---
for tribe in tribe-alpha tribe-beta tribe-gamma; do
    for memo in pool size replication_base_cost replication_k max_replicas reward_full reward_subsequent death_threshold; do
        assert_contains "$tribe start-colony.sh seeds tribe:$memo" \
            "$FED_DIR/$tribe/scripts/start-colony.sh" ":${memo}\""
    done
done

# --- 7. Defensive replicate target check (#460 PR A) ---
# All 5 hunters must guard replicate() with a `len(target) > 0` check and
# tag a distinct `replicate-skip` failure row when the target is empty,
# so empty self_node_addr() no longer pollutes the experience log with
# phantom `replicate-nak` rows.
for tribe in tribe-alpha tribe-beta tribe-gamma tribe-delta tribe-epsilon; do
    assert_contains "$tribe hunter.ag guards replicate() with len(target) > 0" \
        "$FED_DIR/$tribe/agents/hunter.ag" "len(target) > 0"
    assert_contains "$tribe hunter.ag tags replicate-skip on empty target" \
        "$FED_DIR/$tribe/agents/hunter.ag" "replicate-skip"
done

# --- 8. Cross-node replication target selection (#460 PR B) ---
# All 5 hunters must call select_replication_target() at the replicate()
# call site (replacing the bare self_node_addr() seed) so Stage 3
# Malthusian growth crosses node boundaries. The bare line must be gone
# from the call site to prevent regressions.
for tribe in tribe-alpha tribe-beta tribe-gamma tribe-delta tribe-epsilon; do
    assert_contains "$tribe hunter.ag calls select_replication_target() at replicate site" \
        "$FED_DIR/$tribe/agents/hunter.ag" "let target = select_replication_target();"
    if grep -Fq "let target = self_node_addr();" "$FED_DIR/$tribe/agents/hunter.ag"; then
        echo "[FAIL] $tribe hunter.ag still has bare \`let target = self_node_addr();\` at call site"
        FAIL=$((FAIL + 1))
    else
        echo "[PASS] $tribe hunter.ag has no bare \`let target = self_node_addr();\` at call site"
        PASS=$((PASS + 1))
    fi
done

# Bootstrap seed memos for Stage 3 docker (write_bootstrap body).
assert_contains "run-stage3-docker.sh seeds tribes-bench:peer_worker_addr:0" \
    "$FED_DIR/tools/run-stage3-docker.sh" "tribes-bench:peer_worker_addr:0"
assert_contains "run-stage3-docker.sh seeds tribes-bench:peer_worker_count" \
    "$FED_DIR/tools/run-stage3-docker.sh" "tribes-bench:peer_worker_count"

# start-federation.sh exposes PEER_WORKER_ADDRS env var and seeds count.
assert_contains "start-federation.sh references PEER_WORKER_ADDRS env var" \
    "$FED_DIR/start-federation.sh" "PEER_WORKER_ADDRS"
assert_contains "start-federation.sh seeds tribes-bench:peer_worker_count" \
    "$FED_DIR/start-federation.sh" "tribes-bench:peer_worker_count"

# Modulus identity sanity: rr - ((rr / cnt) * cnt) for (rr=0..5, cnt=2)
# must produce [0,1,0,1,0,1] (matches the pick_sibling/pick_variant idiom
# the hunter helper relies on).
modulus_idx() {
    # $1 rr, $2 cnt
    local rr="$1" cnt="$2"
    echo "$((rr - ((rr / cnt) * cnt)))"
}
assert_eq "modulus rr=0,cnt=2 == 0" "0" "$(modulus_idx 0 2)"
assert_eq "modulus rr=1,cnt=2 == 1" "1" "$(modulus_idx 1 2)"
assert_eq "modulus rr=2,cnt=2 == 0" "0" "$(modulus_idx 2 2)"
assert_eq "modulus rr=3,cnt=2 == 1" "1" "$(modulus_idx 3 2)"
assert_eq "modulus rr=4,cnt=2 == 0" "0" "$(modulus_idx 4 2)"
assert_eq "modulus rr=5,cnt=2 == 1" "1" "$(modulus_idx 5 2)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
