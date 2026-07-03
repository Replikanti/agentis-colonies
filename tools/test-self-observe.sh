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
#   9.  recently-closed dedup: a fingerprint closed within the window is skipped (#1298)
#   10. stale-closed re-file: a fingerprint closed past the window is re-filed (#1298)
#   11. dismissed dedup: a self-observe-dismissed-labelled closed match is always skipped (#1298)
#   12. acceptance gate: a low-acceptance class with >= MIN_SAMPLES outcomes is suppressed + logged (#1411)
#   13. acceptance gate: a low-acceptance class BELOW MIN_SAMPLES is NOT suppressed (#1411)
#   14. acceptance gate: a high-acceptance class still files (#1411)
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

# Stub gh whose 'issue list' prints the JSON array in $1 (matching the real
# `--json number,state,closedAt,labels` shape self-observe.sh now requests), and
# whose 'issue create' appends to $WORK/create.log and prints a URL. Search args
# are ignored — the same array is returned for every fingerprint query.
write_gh_json() {
    cat > "$WORK/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then printf '%s' '$1'; exit 0; fi
if [ "\$1" = "issue" ] && [ "\$2" = "create" ]; then
    L=""
    while [ \$# -gt 0 ]; do case "\$1" in --label) L="\$2"; shift 2 ;; *) shift ;; esac; done
    echo "create label=\$L" >> "$WORK/create.log"
    echo "https://example.test/issues/1"
    exit 0
fi
exit 0
EOF
    chmod +x "$WORK/gh"
}

# Back-compat shim for the count-based tests: 0 -> no matching issue ([]),
# anything else -> a single OPEN matching issue (a dedup hit, as before).
write_gh() {
    if [ "$1" = "0" ]; then
        write_gh_json '[]'
    else
        write_gh_json '[{"number":1,"state":"OPEN","closedAt":null,"labels":[]}]'
    fi
}

# Stub rate source for the #1411 acceptance gate: emits the per-class TSV
# (signal_class success total rate) that the real track-issue-outcomes.sh
# --rates would print. Default: empty, so tests 1-11 gate nothing.
write_rates() {  # $1 = TSV body (may be empty)
    printf '%s' "$1" > "$WORK/rates.tsv"
    cat > "$WORK/rates.sh" <<EOF
#!/usr/bin/env bash
cat "$WORK/rates.tsv"
EOF
    chmod +x "$WORK/rates.sh"
}
write_rates ""

run_so() {  # args passed to self-observe
    SELF_OBSERVE_GH="$WORK/gh" SELF_OBSERVE_REPO="o/r" SELF_OBSERVE_LABELS="dev-apprenticeship" \
        SELF_OBSERVE_RATES_CMD="$WORK/rates.sh" \
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

# ---- Test 5: a failed gh issue create does NOT consume a rate-limit slot ----
write_detector 2
cat > "$WORK/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then printf '%s' '[]'; exit 0; fi
if [ "\$1" = "issue" ] && [ "\$2" = "create" ]; then exit 1; fi
exit 0
EOF
chmod +x "$WORK/gh"
OUT="$(run_so --file)"
if [ "$(printf '%s\n' "$OUT" | grep -c 'create FAILED')" = "2" ] && printf '%s\n' "$OUT" | grep -q 'filed=0'; then
    pass "create-failure: reported as FAILED and does not consume a rate-limit slot (filed=0)"
else
    fail "create-failure" "$(printf '%s\n' "$OUT" | tail -3)"
fi

# ---- Test 6: a log-only kind (todo-marker) is observed but NOT filed ----
cat > "$WORK/tools/detect-stub.sh" <<'STUB'
#!/usr/bin/env bash
printf 'DRIFT\ttodo-marker\ttools/x.sh:5\tTODO: do the thing\n'
STUB
chmod +x "$WORK/tools/detect-stub.sh"
write_gh 0; rm -f "$WORK/create.log"
OUT="$(run_so --file)"
if printf '%s\n' "$OUT" | grep -q 'log-only (todo-marker' && [ "$(creates)" = "0" ]; then
    pass "log-only: todo-marker finding is logged, not filed (NOFILE_KINDS default)"
else
    fail "log-only" "out=$(printf '%s\n' "$OUT" | tail -3) creates=$(creates)"
fi

# ---- Test 7: a FILED issue carries the implementation trigger label so the
# federation's SDLC auto-processes it (default SELF_OBSERVE_TRIGGER_LABEL) ----
write_detector 1; write_gh 0; rm -f "$WORK/create.log"
OUT="$(run_so --file)"
if grep -q 'label=.*implementation' "$WORK/create.log" 2>/dev/null; then
    pass "trigger label: filed issue gets --label including the implementation trigger"
else
    fail "trigger label" "create.log=$(cat "$WORK/create.log" 2>/dev/null)"
fi

# ---- Test 8: agent-failure findings are log-only by default (NOFILE_KINDS) ----
cat > "$WORK/tools/detect-stub.sh" <<'STUB'
#!/usr/bin/env bash
printf 'DRIFT\tagent-failure\twatchdog+restarting:14\twatchdog restart count\n'
STUB
chmod +x "$WORK/tools/detect-stub.sh"
write_gh 0; rm -f "$WORK/create.log"
OUT="$(run_so --file)"
if printf '%s\n' "$OUT" | grep -q 'log-only (agent-failure' && [ "$(creates)" = "0" ]; then
    pass "log-only: agent-failure finding is logged, not filed (NOFILE_KINDS default)"
else
    fail "agent-failure log-only" "out=$(printf '%s\n' "$OUT" | tail -3) creates=$(creates)"
fi

# Deterministic close timestamps for the #1298 closed-dedup tests: one safely
# inside the default 14-day window, one far outside it.
RECENT_CLOSED="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
STALE_CLOSED="2000-01-01T00:00:00Z"

# ---- Test 9: a CLOSED match within the dedup window is skipped, not re-filed ----
write_detector 2; rm -f "$WORK/create.log"
write_gh_json "[{\"number\":2,\"state\":\"CLOSED\",\"closedAt\":\"$RECENT_CLOSED\",\"labels\":[]}]"
OUT="$(run_so --file)"
if [ "$(creates)" = "0" ] && [ "$(printf '%s\n' "$OUT" | grep -c 'skip (recently closed)')" = "2" ]; then
    pass "closed-dedup: a recently-closed fingerprint is skipped (#1298)"
else
    fail "closed-dedup recent" "creates=$(creates) skips=$(printf '%s\n' "$OUT" | grep -c 'recently closed')"
fi

# ---- Test 10: a CLOSED match past the dedup window IS re-filed ----
write_detector 2; rm -f "$WORK/create.log"
write_gh_json "[{\"number\":3,\"state\":\"CLOSED\",\"closedAt\":\"$STALE_CLOSED\",\"labels\":[]}]"
OUT="$(run_so --file)"
if [ "$(creates)" = "2" ] && [ "$(printf '%s\n' "$OUT" | grep -c 'FILED:')" = "2" ]; then
    pass "closed-dedup: a stale-closed fingerprint past the cap is re-filed (#1298)"
else
    fail "closed-dedup stale" "creates=$(creates) filed=$(printf '%s\n' "$OUT" | grep -c 'FILED:')"
fi

# ---- Test 11: a self-observe-dismissed-labelled closed match is always skipped ----
write_detector 2; rm -f "$WORK/create.log"
write_gh_json "[{\"number\":4,\"state\":\"CLOSED\",\"closedAt\":\"$STALE_CLOSED\",\"labels\":[{\"name\":\"self-observe-dismissed\"}]}]"
OUT="$(run_so --file)"
if [ "$(creates)" = "0" ] && [ "$(printf '%s\n' "$OUT" | grep -c 'skip (dismissed)')" = "2" ]; then
    pass "closed-dedup: a self-observe-dismissed closed match is always skipped (#1298)"
else
    fail "closed-dedup dismissed" "creates=$(creates) skips=$(printf '%s\n' "$OUT" | grep -c 'dismissed')"
fi

# ---- Test 12: a low-acceptance class with enough samples is SUPPRESSED and
#      the suppression (with its rate) is logged (#1411) ----
write_detector 2; write_gh 0; rm -f "$WORK/create.log"
write_rates "$(printf 'test-kind\t1\t10\t0.1000\n')"
OUT="$(run_so --file)"
if [ "$(creates)" = "0" ] \
   && [ "$(printf '%s\n' "$OUT" | grep -c 'suppress (low acceptance: test-kind')" = "2" ] \
   && printf '%s\n' "$OUT" | grep -q 'rate=0.1000 n=10'; then
    pass "acceptance gate: low-acceptance class (0.10, n=10) suppressed + logged with rate, nothing filed"
else
    fail "acceptance gate suppress" "creates=$(creates) sup=$(printf '%s\n' "$OUT" | grep -c 'suppress')"
fi

# ---- Test 13: a class below MIN_SAMPLES is NOT suppressed (files normally) ----
write_detector 2; write_gh 0; rm -f "$WORK/create.log"
write_rates "$(printf 'test-kind\t0\t3\t0.0000\n')"
OUT="$(run_so --file)"
if [ "$(creates)" = "2" ] && ! printf '%s\n' "$OUT" | grep -q 'suppress (low acceptance'; then
    pass "acceptance gate: class below min-sample (n=3) is NOT suppressed — files normally"
else
    fail "acceptance gate min-sample" "creates=$(creates) sup=$(printf '%s\n' "$OUT" | grep -c 'suppress')"
fi

# ---- Test 14: a high-acceptance class still files (#1411) ----
write_detector 2; write_gh 0; rm -f "$WORK/create.log"
write_rates "$(printf 'test-kind\t9\t10\t0.9000\n')"
OUT="$(run_so --file)"
if [ "$(creates)" = "2" ] && ! printf '%s\n' "$OUT" | grep -q 'suppress (low acceptance'; then
    pass "acceptance gate: high-acceptance class (0.90, n=10) still files"
else
    fail "acceptance gate high-acceptance" "creates=$(creates) sup=$(printf '%s\n' "$OUT" | grep -c 'suppress')"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
