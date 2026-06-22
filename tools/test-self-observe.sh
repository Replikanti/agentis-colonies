#!/usr/bin/env bash
# tools/test-self-observe.sh: unit tests for tools/self-observe.sh (#1266 M3).
#
# Hermetic: runs self-observe.sh from a sandbox tools dir containing a single
# stub detector, and points SELF_OBSERVE_GH at a stub `gh` whose search count
# and create-log are controllable. No real gh / network / agentis needed.
#
#   1. dry-run: findings are reported as WOULD FILE; gh issue create is NOT called
#   2. --file: each new finding triggers exactly one gh issue create
#   3. dedup: when an open issue already carries the fingerprint, the finding is skipped
#   4. rate-limit: no more than SELF_OBSERVE_MAX_NEW issues created per run
#
# Usage: ./tools/test-self-observe.sh   (exit 0 = all pass, 1 = failure)
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_OBSERVE="$SCRIPT_DIR/self-observe.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tools"
cp "$SELF_OBSERVE" "$WORK/tools/self-observe.sh"
chmod +x "$WORK/tools/self-observe.sh"
SO="$WORK/tools/self-observe.sh"

# Stub detector emitting $1 TSV findings. Lives alongside the copied
# self-observe.sh so its detect-*.sh glob picks up only this one.
write_detector() {
    cat > "$WORK/tools/detect-stub.sh" <<EOF
#!/usr/bin/env bash
for i in \$(seq 1 $1); do
    printf 'DRIFT\ttest-kind\tloc-%s\tsome finding text %s\n' "\$i" "\$i"
done
EOF
    chmod +x "$WORK/tools/detect-stub.sh"
}

# Stub gh whose 'issue list' search returns the count baked in $1, and whose
# 'issue create' appends to $WORK/create.log and prints a URL.
write_gh() {
    cat > "$WORK/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then echo "$1"; exit 0; fi
if [ "\$1" = "issue" ] && [ "\$2" = "create" ]; then echo "create" >> "$WORK/create.log"; echo "https://example.test/issues/1"; exit 0; fi
exit 0
EOF
    chmod +x "$WORK/gh"
}

run_so() {  # args passed to self-observe
    SELF_OBSERVE_GH="$WORK/gh" SELF_OBSERVE_REPO="o/r" SELF_OBSERVE_LABELS="dev-apprenticeship" \
        "$SO" "$@" 2>&1
}
creates() { [ -f "$WORK/create.log" ] && wc -l < "$WORK/create.log" | tr -d ' ' || echo 0; }

# ---- Test 1: dry-run reports WOULD FILE and creates nothing ----
write_detector 2; write_gh 0; rm -f "$WORK/create.log"
OUT="$(run_so)"
if [ "$(printf '%s\n' "$OUT" | grep -c 'WOULD FILE')" = "2" ] && [ "$(creates)" = "0" ]; then
    pass "dry-run: 2 findings reported as WOULD FILE, gh create not called"
else
    fail "dry-run" "would=$(printf '%s\n' "$OUT" | grep -c 'WOULD FILE') creates=$(creates)"
fi

# ---- Test 2: --file creates one issue per new finding ----
write_detector 2; write_gh 0; rm -f "$WORK/create.log"
OUT="$(run_so --file)"
if [ "$(creates)" = "2" ] && [ "$(printf '%s\n' "$OUT" | grep -c 'FILED:')" = "2" ]; then
    pass "--file: 2 new findings -> 2 gh issue create calls"
else
    fail "--file create count" "creates=$(creates) filed=$(printf '%s\n' "$OUT" | grep -c 'FILED:')"
fi

# ---- Test 3: dedup skips findings whose fingerprint already has an open issue ----
write_detector 2; write_gh 1; rm -f "$WORK/create.log"
OUT="$(run_so --file)"
if [ "$(creates)" = "0" ] && [ "$(printf '%s\n' "$OUT" | grep -c 'skip (open issue exists)')" = "2" ]; then
    pass "dedup: existing-fingerprint findings are skipped, nothing created"
else
    fail "dedup" "creates=$(creates) skips=$(printf '%s\n' "$OUT" | grep -c 'skip')"
fi

# ---- Test 4: rate-limit caps creations at SELF_OBSERVE_MAX_NEW ----
write_detector 5; write_gh 0; rm -f "$WORK/create.log"
OUT="$(SELF_OBSERVE_MAX_NEW=2 run_so --file)"
if [ "$(creates)" = "2" ] && printf '%s\n' "$OUT" | grep -q 'rate-limit reached'; then
    pass "rate-limit: 5 findings, cap 2 -> exactly 2 created + rate-limit notice"
else
    fail "rate-limit" "creates=$(creates)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
