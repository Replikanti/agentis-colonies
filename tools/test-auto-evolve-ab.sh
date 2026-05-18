#!/bin/bash
# tools/test-auto-evolve-ab.sh — Smoke tests for the Phase 7 PR-A
# auto-evolve plumbing harness (#628).
#
# Covered:
#   1. bash -n on auto-evolve-ab.sh
#   2. bash -n on self
#   3. throttle gate fires when .evolve/ has >= max_concurrent_per_colony
#      candidates
#   4. validity gate rejects a candidate with missing cb / missing tiers
#   5. ledger row written for `evolve_throttled`
#   6. ledger row written for `ab_skipped_pr_a_stub`
#   7. dry-run mode does NOT modify any non-ledger files
#   8. stub candidate (the cosmetic-comment placeholder PR-A generates)
#      is parseable by `agentis commit` when called against a clean
#      parent — verifies the appended comment doesn't break syntax.
#
# Out of scope (deferred to PR-B / PR-C tests):
#   - real LLM mutation (PR-B `auto-evolve-mutate.py`)
#   - A/B score comparison (PR-B)
#   - live evolve with dry_run=false (PR-C)
#
# Usage: ./tools/test-auto-evolve-ab.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

# ----- Test 1: bash -n on auto-evolve-ab.sh -----
if bash -n "$SCRIPT_DIR/auto-evolve-ab.sh"; then
    pass "bash -n: tools/auto-evolve-ab.sh"
else
    fail "bash -n auto-evolve-ab.sh" "syntax error"
fi

# ----- Test 2: bash -n on self -----
if bash -n "$SCRIPT_DIR/test-auto-evolve-ab.sh"; then
    pass "bash -n: tools/test-auto-evolve-ab.sh (self)"
else
    fail "bash -n self" "syntax error"
fi

# ----- Setup: synthetic federation tree -----
# Mirror the shape the script consumes: <fed>/<colony>/agents/<agent>.ag.
# Use a research-foundry style config so `evolve.mutation.enabled=true`
# kicks in even when the default config keeps mutation off.
FAKE_FED="$TMPDIR_TEST/fake-fed"
FAKE_COLONY="explorer"
mkdir -p "$FAKE_FED/$FAKE_COLONY/agents"
PARENT_AG="$FAKE_FED/$FAKE_COLONY/agents/probe.ag"

cat > "$PARENT_AG" <<'AGEOF'
// probe.ag -- Synthetic fixture for tools/test-auto-evolve-ab.sh.
// Hand-written to pass the harness's three validity-gate checks:
// cb budget present, tier(...) call present, all three non-shadow
// tier literals ("propose", "review-gated", "autonomous") present.

cb 200;

fn tick(_rec: string) -> void {
    let my_tier = tier("probe");
    if my_tier == "autonomous" {
        // direct external write
    } else {
        if my_tier == "review-gated" {
            // draft external write
        } else {
            if my_tier == "propose" {
                // emit on bus
            } else {
                // shadow / dormant: observe only
            };
        };
    };
}
AGEOF

# Write a minimal config that flips mutation on so the harness actually
# runs through the pipeline. Defaults to dry_run=true so no files are
# mutated outside the ledger.
FAKE_CONFIG="$TMPDIR_TEST/fake-config.yaml"
cat > "$FAKE_CONFIG" <<'YAMLEOF'
promote:
  prerequisites:
    min_entries: 30
    min_acting_entries: 10
    min_runtime_hours: 1.5
    reject_rate_threshold: 0.10
    delta_slope_window: 20
    delta_slope_min: 0
  steps:
    - from: 0.4
      to: 0.6
      min_acting_entries_override: 0
    - from: 0.6
      to: 0.8
    - from: 0.8
      to: 0.95

evolve:
  trigger:
    delta_slope_negative_for: 1000
    reject_rate_above: 0.20
    both_signals_required: false
  mutation:
    enabled: true
    max_concurrent_per_colony: 1
    max_generations: 10
    skip_tiers: ["autonomous"]
  ab:
    ticks: 50
    min_acting_for_decision: 10
    min_delta: 0.05
    fast_mode_ticks: 10
  archive_dir: "evolution-archive"
  ledger_path: "evolution-ledger.jsonl"
  dry_run: true

dry_run: true
YAMLEOF

LEDGER="$FAKE_FED/evolution-ledger.jsonl"

# ----- Test 3: happy path → ab_skipped_pr_a_stub row -----
# Clean run with no .evolve/ pre-existing — must pass throttle, pass
# validity (parent template above is hand-written to satisfy all
# 3 checks, modulo `agentis commit` which we tolerate failing when
# the binary is missing), and write an `ab_skipped_pr_a_stub` row.

rm -f "$LEDGER"
OUT=$("$SCRIPT_DIR/auto-evolve-ab.sh" "$FAKE_FED" probe "$FAKE_COLONY" "$PARENT_AG" \
    --ticks 10 --config "$FAKE_CONFIG" 2>&1) || true

if [ -f "$LEDGER" ]; then
    pass "happy path: ledger file created"
else
    fail "happy path ledger" "ledger missing after run; output: $OUT"
fi

# ----- Test 4: ab_skipped_pr_a_stub event written -----
# When `agentis` is on PATH and the parent passes commit + tier
# coverage + cb budget, the run must reach the PR-A stub skip step.
# When `agentis` is missing, the validity gate fails on
# `agentis_binary_missing` instead — still a valid PR-A pipeline
# exit, but emits `mutation_rejected` not `ab_skipped_pr_a_stub`.

if command -v agentis >/dev/null 2>&1; then
    if grep -q '"event":"ab_skipped_pr_a_stub"\|"event": "ab_skipped_pr_a_stub"' "$LEDGER" 2>/dev/null; then
        pass "ledger contains ab_skipped_pr_a_stub event"
    else
        fail "ab_skipped_pr_a_stub event" "not found in ledger: $(cat "$LEDGER" 2>/dev/null)"
    fi
else
    # Without agentis the validity gate rejects on missing binary;
    # the mutation_rejected row is the expected outcome here.
    if grep -q '"event":"mutation_rejected"\|"event": "mutation_rejected"' "$LEDGER" 2>/dev/null; then
        pass "ledger contains mutation_rejected event (agentis missing on PATH)"
    else
        fail "ledger event" "no ab_skipped_pr_a_stub or mutation_rejected: $(cat "$LEDGER" 2>/dev/null)"
    fi
fi

# ----- Test 5: throttle gate fires when .evolve/ is full -----
# Pre-create one candidate file in .evolve/ to hit the cap (config sets
# max_concurrent_per_colony: 1). A second invocation MUST exit early
# with an `evolve_throttled` row and MUST NOT touch a new candidate.

EVOLVE_DIR="$FAKE_FED/$FAKE_COLONY/agents/.evolve"
mkdir -p "$EVOLVE_DIR"
touch "$EVOLVE_DIR/probe.ag.candidate-gen-99"

# Reset ledger to isolate this event.
rm -f "$LEDGER"
THROTTLE_OUT=$("$SCRIPT_DIR/auto-evolve-ab.sh" "$FAKE_FED" probe "$FAKE_COLONY" "$PARENT_AG" \
    --ticks 10 --config "$FAKE_CONFIG" 2>&1) || true

if grep -q '"event":"evolve_throttled"\|"event": "evolve_throttled"' "$LEDGER" 2>/dev/null; then
    pass "throttle gate: ledger row written when cap hit"
else
    fail "throttle gate ledger" "no evolve_throttled row; ledger: $(cat "$LEDGER" 2>/dev/null) out: $THROTTLE_OUT"
fi

# Confirm no new candidate-gen-N file (other than the pre-seeded one)
# was created — the throttle must short-circuit before stub generation.
NEW_CANDIDATES=$(find "$EVOLVE_DIR" -name "*.candidate-gen-*" -type f | wc -l | tr -d ' ')
if [ "$NEW_CANDIDATES" = "1" ]; then
    pass "throttle gate: no new candidate generated"
else
    fail "throttle gate side effect" "expected 1 candidate (the seed), found $NEW_CANDIDATES"
fi

# Cleanup throttle seed.
rm -f "$EVOLVE_DIR/probe.ag.candidate-gen-99"

# ----- Test 6: validity gate rejection -----
# Mutate the parent so it lacks `cb <N>;` AND lacks tier literals — the
# stub-mutation step copies the parent verbatim (plus an appended
# cosmetic comment), so an invalid parent produces an invalid
# candidate. The harness must emit `mutation_rejected`.

BAD_PARENT="$FAKE_FED/$FAKE_COLONY/agents/bad.ag"
cat > "$BAD_PARENT" <<'BADEOF'
// no cb line, no tier() call, no tier literals
agent bad {
    fn tick(_rec: string) -> void {
    }
}
BADEOF

rm -f "$LEDGER"
BAD_OUT=$("$SCRIPT_DIR/auto-evolve-ab.sh" "$FAKE_FED" bad "$FAKE_COLONY" "$BAD_PARENT" \
    --ticks 10 --config "$FAKE_CONFIG" 2>&1) || true

if grep -q '"event":"mutation_rejected"\|"event": "mutation_rejected"' "$LEDGER" 2>/dev/null; then
    pass "validity gate: mutation_rejected row written on bad candidate"
else
    fail "validity gate ledger" "no mutation_rejected row; ledger: $(cat "$LEDGER" 2>/dev/null) out: $BAD_OUT"
fi

# The rejected candidate must be cleaned up so a re-run doesn't see
# itself in the .evolve/ throttle count.
REMAINING_CANDS=$(find "$EVOLVE_DIR" -name "bad.ag.candidate-gen-*" -type f | wc -l | tr -d ' ')
if [ "$REMAINING_CANDS" = "0" ]; then
    pass "validity gate: rejected candidate cleaned up"
else
    fail "validity gate cleanup" "expected 0 remaining bad candidates, found $REMAINING_CANDS"
fi

# ----- Test 7: dry-run mode does NOT mutate non-ledger files -----
# Snapshot the parent + the colony before a dry-run pass, run, and
# compare. The ledger is excluded from the comparison (that's the one
# file the harness IS allowed to write under dry-run).

SNAPSHOT_DIR="$TMPDIR_TEST/snapshot"
rm -rf "$SNAPSHOT_DIR"
mkdir -p "$SNAPSHOT_DIR"
cp -R "$FAKE_FED" "$SNAPSHOT_DIR/before"
rm -f "$SNAPSHOT_DIR/before/evolution-ledger.jsonl"

rm -f "$LEDGER"
DRY_OUT=$("$SCRIPT_DIR/auto-evolve-ab.sh" "$FAKE_FED" probe "$FAKE_COLONY" "$PARENT_AG" \
    --ticks 10 --config "$FAKE_CONFIG" --dry-run 2>&1) || true

cp -R "$FAKE_FED" "$SNAPSHOT_DIR/after"
rm -f "$SNAPSHOT_DIR/after/evolution-ledger.jsonl"
# .evolve/ may be created (and emptied) but should be empty at end.
# Compare directory contents excluding ledger and .evolve/.
DIFF_OUT=$(diff -r "$SNAPSHOT_DIR/before" "$SNAPSHOT_DIR/after" 2>&1 | grep -v '\.evolve' || true)
# Allow .evolve/ to exist as long as no candidates remain inside.
LINGERING=$(find "$EVOLVE_DIR" -name "*.candidate-gen-*" -type f 2>/dev/null | wc -l | tr -d ' ')

if [ -z "$DIFF_OUT" ] && [ "$LINGERING" = "0" ]; then
    pass "dry-run: no non-ledger file changes (LINGERING=0)"
else
    fail "dry-run side effects" "diff: $DIFF_OUT lingering candidates: $LINGERING out: $DRY_OUT"
fi

# ----- Test 8: stub candidate parseable by agentis commit -----
# Generate a stub manually (same logic as the script) and verify
# `agentis commit` on it succeeds. Skipped when agentis is not on PATH.

if command -v agentis >/dev/null 2>&1; then
    STUB_DIR="$TMPDIR_TEST/stub-parse"
    mkdir -p "$STUB_DIR"
    # `agentis commit` requires an .agentis/ in CWD — same bootstrap
    # pattern as colony-lint.sh:387-396 and the validity gate in
    # tools/auto-evolve-ab.sh.
    (cd "$STUB_DIR" && agentis init >/dev/null 2>&1) || true
    STUB_PATH="$STUB_DIR/probe.ag.candidate-gen-1"
    cp "$PARENT_AG" "$STUB_PATH"
    printf '\n// Stub mutation generated by PR-A (#628)\n' >> "$STUB_PATH"
    if (cd "$STUB_DIR" && agentis commit "$STUB_PATH") >/dev/null 2>&1; then
        pass "stub candidate parseable by agentis commit"
    else
        fail "stub parseability" "agentis commit failed on stub candidate"
    fi
else
    pass "stub candidate parseability (skipped: agentis not on PATH)"
fi

# ----- Test 9: ledger schema sanity -----
# Every row must carry the base fields (ts, event, agent, colony,
# generation, parent_sha, parent_sha8, ab_ticks, dry_run). Verifies
# the ledger writer helper isn't drifting from the schema downstream
# tooling will consume.

rm -f "$LEDGER"
"$SCRIPT_DIR/auto-evolve-ab.sh" "$FAKE_FED" probe "$FAKE_COLONY" "$PARENT_AG" \
    --ticks 10 --config "$FAKE_CONFIG" --dry-run >/dev/null 2>&1 || true

if [ -s "$LEDGER" ]; then
    SCHEMA_OK=$(python3 -c "
import json, sys
required = {'ts', 'event', 'agent', 'colony', 'generation', 'parent_sha',
            'parent_sha8', 'ab_ticks', 'dry_run'}
rows = 0
bad = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        rows += 1
        try:
            r = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            bad.append('parse_error')
            continue
        missing = required - set(r.keys())
        if missing:
            bad.append(','.join(sorted(missing)))
if rows == 0:
    print('no_rows')
elif bad:
    print('bad:' + ';'.join(bad))
else:
    print('ok:%d' % rows)
" "$LEDGER")
    case "$SCHEMA_OK" in
        ok:*)
            pass "ledger schema: required fields present on every row"
            ;;
        *)
            fail "ledger schema" "$SCHEMA_OK (ledger: $(cat "$LEDGER"))"
            ;;
    esac
else
    fail "ledger schema setup" "ledger empty after dry-run pass"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
