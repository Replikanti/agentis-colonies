#!/bin/bash
# test-stage2-rewrite-cb-decl.sh — fixture-based regression test for the
# `tools/run-stage2-rewrite-cb-decl.py` helper introduced in #407.
#
# Mirrors the PASS/FAIL/SKIP pattern from `test-stage2-cognitive-market.sh`.
# Pure file-fixture; no live agentis spawn.
#
# Coverage:
#   1. Missing file → exit 1.
#   2. File without `cb <N>;` line → exit 2.
#   3. Bad new_cb arg (non-int, negative, zero) → exit 2.
#   4. Successful rewrite: fixture with `cb 800;` rewritten to `cb 16000;`,
#      rest of file byte-identical.
#   5. Idempotent: running twice produces byte-identical output.
#   6. First-line-only: a fixture with two `cb <N>;` lines has only the
#      first rewritten.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/run-stage2-rewrite-cb-decl.py"

PASS=0
FAIL=0
SKIP=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
    label="$1"; exp="$2"; got="$3"
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

assert_exit() {
    label="$1"; expected_code="$2"; shift 2
    set +e
    "$@" >/dev/null 2>&1
    actual_code=$?
    set -e
    assert_eq "$label" "$expected_code" "$actual_code"
}

if [ ! -f "$HELPER" ]; then
    echo "[SKIP] helper not found: $HELPER"
    SKIP=$((SKIP + 1))
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] python3 not on PATH"
    SKIP=$((SKIP + 1))
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- 1. Missing file → exit 1 ---
assert_exit "missing file → exit 1" 1 \
    python3 "$HELPER" "$TMP/does-not-exist.ag" 16000

# --- 2. File without `cb <N>;` line → exit 2 ---
no_cb_fixture="$TMP/no-cb.ag"
printf 'fn tick() { }\n' > "$no_cb_fixture"
assert_exit "file without cb decl → exit 2" 2 \
    python3 "$HELPER" "$no_cb_fixture" 16000

# --- 3. Bad new_cb arg → exit 2 ---
good_fixture="$TMP/good.ag"
printf 'cb 800;\nfn tick() { }\n' > "$good_fixture"

assert_exit "non-int new_cb → exit 2" 2 \
    python3 "$HELPER" "$good_fixture" "abc"
assert_exit "negative new_cb → exit 2" 2 \
    python3 "$HELPER" "$good_fixture" "-5"
assert_exit "zero new_cb → exit 2" 2 \
    python3 "$HELPER" "$good_fixture" "0"
assert_exit "missing new_cb arg → exit 2" 2 \
    python3 "$HELPER" "$good_fixture"

# --- 4. Successful rewrite ---
rewrite_fixture="$TMP/rewrite.ag"
printf '// header line\ncb 800;\nfn tick() {\n    // body\n}\n' > "$rewrite_fixture"

set +e
python3 "$HELPER" "$rewrite_fixture" "16000" >/dev/null 2>&1
rc=$?
set -e
assert_eq "rewrite cb 800; → cb 16000; exits 0" "0" "$rc"

new_cb_line="$(sed -n '2p' "$rewrite_fixture")"
assert_eq "rewritten line == 'cb 16000;'" "cb 16000;" "$new_cb_line"

# Rest of file byte-identical: rebuild expected and diff.
expected_rewritten="$TMP/expected-rewritten.ag"
printf '// header line\ncb 16000;\nfn tick() {\n    // body\n}\n' > "$expected_rewritten"
if cmp -s "$rewrite_fixture" "$expected_rewritten"; then
    echo "[PASS] rest of file byte-identical after rewrite"
    PASS=$((PASS + 1))
else
    echo "[FAIL] rest of file not byte-identical after rewrite"
    diff "$rewrite_fixture" "$expected_rewritten" || true
    FAIL=$((FAIL + 1))
fi

# --- 5. Idempotent: running twice produces byte-identical output ---
idempotent_fixture="$TMP/idempotent.ag"
printf '// hdr\ncb 8000;\nfn tick() {}\n' > "$idempotent_fixture"

python3 "$HELPER" "$idempotent_fixture" "8000" >/dev/null 2>&1
hash1="$(sha256sum "$idempotent_fixture" | cut -d' ' -f1)"
python3 "$HELPER" "$idempotent_fixture" "8000" >/dev/null 2>&1
hash2="$(sha256sum "$idempotent_fixture" | cut -d' ' -f1)"
assert_eq "idempotent: two cb 8000; → cb 8000; rewrites are byte-identical" \
    "$hash1" "$hash2"

# Also check that rewriting `cb 8000;` to `cb 8000;` is a no-op vs the
# pre-rewrite content (the regex preserves the line shape `cb <N>;\n`).
expected_idempotent="$TMP/expected-idempotent.ag"
printf '// hdr\ncb 8000;\nfn tick() {}\n' > "$expected_idempotent"
if cmp -s "$idempotent_fixture" "$expected_idempotent"; then
    echo "[PASS] cb 8000; → cb 8000; is a true no-op vs original"
    PASS=$((PASS + 1))
else
    echo "[FAIL] cb 8000; → cb 8000; mutated the file"
    diff "$idempotent_fixture" "$expected_idempotent" || true
    FAIL=$((FAIL + 1))
fi

# --- 6. First-line-only: two cb <N>; lines, only first rewritten ---
double_fixture="$TMP/double.ag"
printf 'cb 100;\n// gap\ncb 200;\n' > "$double_fixture"
python3 "$HELPER" "$double_fixture" "9999" >/dev/null 2>&1

first_line="$(sed -n '1p' "$double_fixture")"
third_line="$(sed -n '3p' "$double_fixture")"
assert_eq "first cb line rewritten" "cb 9999;" "$first_line"
assert_eq "second cb line untouched" "cb 200;" "$third_line"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
