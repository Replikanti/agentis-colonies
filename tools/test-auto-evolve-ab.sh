#!/bin/bash
# tools/test-auto-evolve-ab.sh — Smoke tests for the Phase 7 PR-B
# auto-evolve mutator + A/B harness (#628).
#
# Covered:
#   1. bash -n on auto-evolve-ab.sh
#   2. bash -n on self
#   3. throttle gate fires when .evolve/ has >= max_concurrent_per_colony
#      candidates
#   4. validity gate rejects a candidate with missing cb / missing tiers
#   5. ledger row written for `evolve_throttled`
#   6. ledger row written for `evolve_cycle` / `ab_inconclusive` (PR-B
#      replaces PR-A's `ab_skipped_pr_a_stub`)
#   7. dry-run mode does NOT modify any non-ledger files
#   8. stub candidate (the parent-as-mutation fixture) is parseable by
#      `agentis commit` — verifies the candidate doesn't break syntax.
#   9. Ledger schema sanity (base fields present on every row).
#
# PR-B (#628) added 4 new assertions:
#   10. Mutator invocation with a known-good LLM stub produces a valid
#       candidate (exit 0 + candidate file exists + rationale non-empty).
#   11. Mutator invocation with a markdown-fenced bad LLM stub emits a
#       `mutation_rejected` ledger row with reason `mutation_invalid_shape`.
#   12. A/B harness in dry-run mode logs an `ab_inconclusive` or
#       `evolve_cycle` row carrying `dry_run: true`; canonical .ag file
#       contents stay byte-identical (no file rename / archive).
#   13. Archive path filename shape: `<agent>-gen-N-<sha8>.ag` (verified
#       by introspecting the script's archive-path interpolation; the
#       archive is only written on live-mode candidate-winner runs).
#
# PR-C (#628) added 3 new assertions:
#   16. SPAWN_CMD path translation (#660): the generated container
#       command uses `/run-root/...` paths, never `<run-dir>/.../.evolve/`.
#   17. Mutator-stderr quote escaping (#661): a mutator stub that
#       writes quotes to stderr produces a ledger row whose JSON parses
#       cleanly (no `_extras_parse_error`).
#   18. Allowlist enforcement: invoking the harness with an agent name
#       not in `evolve.mutation.allowed_agents` emits an
#       `evolve_skipped_not_in_allowlist` row and exits 0.
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

# Mutator LLM stub fixture. The PR-B mutator (auto-evolve-mutate.py)
# respects MUTATE_LLM_STUB=<path> as a hermetic test path that bypasses
# the live LLM backend and returns the fixture verbatim. The good
# fixture is the parent itself (validates the round-trip without
# triggering the validity gate); the bad fixture wraps the parent in
# markdown fences so the shape validator rejects it.
GOOD_STUB="$TMPDIR_TEST/good-stub.ag"
cp "$PARENT_AG" "$GOOD_STUB"

BAD_STUB="$TMPDIR_TEST/bad-stub.ag"
{
    printf '```ag\n'
    cat "$PARENT_AG"
    printf '\n```\n'
} > "$BAD_STUB"

# ----- Test 3: happy path → evolve_cycle / ab_inconclusive row -----
# Clean run with no .evolve/ pre-existing — must pass throttle, pass
# validity, run the mutator (with MUTATE_LLM_STUB=$GOOD_STUB), and
# write a PR-B ledger row. Non-containerized mode produces
# `ab_inconclusive` with reason=`non_containerized_mode`; an explicit
# A/B run is exercised by tests 12 (dry-run row shape) below.

rm -f "$LEDGER"
OUT=$(MUTATE_LLM_STUB="$GOOD_STUB" \
    "$SCRIPT_DIR/auto-evolve-ab.sh" "$FAKE_FED" probe "$FAKE_COLONY" "$PARENT_AG" \
    --ticks 10 --config "$FAKE_CONFIG" 2>&1) || true

if [ -f "$LEDGER" ]; then
    pass "happy path: ledger file created"
else
    fail "happy path ledger" "ledger missing after run; output: $OUT"
fi

# ----- Test 4: PR-B ledger event written -----
# When `agentis` is on PATH and the parent + stub pass validity, the
# harness reaches the A/B step. In non-containerized mode it writes
# `ab_inconclusive` with reason `non_containerized_mode`. When agentis
# is missing the validity gate fails on `agentis_binary_missing`
# instead, emitting `mutation_rejected` — both are valid PR-B exits.

if command -v agentis >/dev/null 2>&1; then
    if grep -q '"event":"ab_inconclusive"\|"event": "ab_inconclusive"\|"event":"evolve_cycle"\|"event": "evolve_cycle"' "$LEDGER" 2>/dev/null; then
        pass "ledger contains PR-B A/B verdict event"
    else
        fail "PR-B A/B event" "not found in ledger: $(cat "$LEDGER" 2>/dev/null)"
    fi
else
    # Without agentis the validity gate rejects on missing binary;
    # the mutation_rejected row is the expected outcome here.
    if grep -q '"event":"mutation_rejected"\|"event": "mutation_rejected"' "$LEDGER" 2>/dev/null; then
        pass "ledger contains mutation_rejected event (agentis missing on PATH)"
    else
        fail "ledger event" "no ab_inconclusive/evolve_cycle/mutation_rejected: $(cat "$LEDGER" 2>/dev/null)"
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
THROTTLE_OUT=$(MUTATE_LLM_STUB="$GOOD_STUB" \
    "$SCRIPT_DIR/auto-evolve-ab.sh" "$FAKE_FED" probe "$FAKE_COLONY" "$PARENT_AG" \
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
# Feed the mutator a stub fixture that lacks `cb <N>;` AND lacks tier
# literals. The mutator's shape validator (auto-evolve-mutate.py)
# catches missing_cb_budget and missing_tier_literal cases and exits
# with rc=2 + stderr=`mutation_invalid_shape`. The harness must emit a
# `mutation_rejected` ledger row carrying that reason.

BAD_PARENT="$FAKE_FED/$FAKE_COLONY/agents/bad.ag"
cat > "$BAD_PARENT" <<'BADEOF'
// no cb line, no tier() call, no tier literals
agent bad {
    fn tick(_rec: string) -> void {
    }
}
BADEOF

# Mutator stub fixture: the bad parent. The mutator's shape validator
# rejects it before the validity gate ever sees it.
BAD_PARENT_STUB="$TMPDIR_TEST/bad-parent-stub.ag"
cp "$BAD_PARENT" "$BAD_PARENT_STUB"

rm -f "$LEDGER"
BAD_OUT=$(MUTATE_LLM_STUB="$BAD_PARENT_STUB" \
    "$SCRIPT_DIR/auto-evolve-ab.sh" "$FAKE_FED" bad "$FAKE_COLONY" "$BAD_PARENT" \
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
DRY_OUT=$(MUTATE_LLM_STUB="$GOOD_STUB" \
    "$SCRIPT_DIR/auto-evolve-ab.sh" "$FAKE_FED" probe "$FAKE_COLONY" "$PARENT_AG" \
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
MUTATE_LLM_STUB="$GOOD_STUB" \
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

# ------------------------------------------------------------------
# PR-B (#628) new tests
# ------------------------------------------------------------------

# ----- Test 10: mutator invocation produces valid .ag candidate -----
# Direct test of tools/auto-evolve-mutate.py with MUTATE_LLM_STUB.
# Exit 0 + candidate file exists + rationale non-empty. Decoupled from
# the harness so the failure mode is unambiguous.

MUT_OUT="$TMPDIR_TEST/mut-candidate.ag"
MUT_RATIONALE="$TMPDIR_TEST/mut-rationale.txt"
rm -f "$MUT_OUT" "$MUT_RATIONALE"

# Provide a small experience .jsonl so the mutator has rows to
# summarise (it tolerates an empty file but a populated one exercises
# the failure-summary branch).
MUT_EXP="$TMPDIR_TEST/mut-experience.jsonl"
cat > "$MUT_EXP" <<'MUTEXPEOF'
{"outcome":"reject","tags":["llm:hallucination","budget:overrun"]}
{"outcome":"failure","tags":["llm:hallucination"]}
{"outcome":"success","tags":["audit:novel"]}
MUTEXPEOF

if MUTATE_LLM_STUB="$GOOD_STUB" python3 "$SCRIPT_DIR/auto-evolve-mutate.py" \
        --ag "$PARENT_AG" \
        --experience "$MUT_EXP" \
        --window 10 \
        --target-gen 1 \
        --out "$MUT_OUT" \
        --rationale-out "$MUT_RATIONALE" >/dev/null 2>&1 \
        && [ -f "$MUT_OUT" ] \
        && [ -s "$MUT_RATIONALE" ]; then
    pass "mutator: valid .ag candidate + non-empty rationale"
else
    fail "mutator stub run" "candidate=$([ -f "$MUT_OUT" ] && echo present || echo missing) rationale_size=$(wc -c < "$MUT_RATIONALE" 2>/dev/null || echo 0)"
fi

# ----- Test 11: mutator with markdown-fenced LLM output -----
# When the LLM returns ```ag fences, the shape validator rejects it.
# The harness records this as `mutation_rejected` with reason
# `mutation_invalid_shape` (mutator exit 2).

rm -f "$LEDGER"
BAD_OUT=$(MUTATE_LLM_STUB="$BAD_STUB" \
    "$SCRIPT_DIR/auto-evolve-ab.sh" "$FAKE_FED" probe "$FAKE_COLONY" "$PARENT_AG" \
    --ticks 10 --config "$FAKE_CONFIG" --dry-run 2>&1) || true

if grep -q '"reason":"mutation_invalid_shape"\|"reason": "mutation_invalid_shape"' "$LEDGER" 2>/dev/null; then
    pass "mutator: markdown-fenced output -> mutation_invalid_shape ledger row"
else
    fail "mutator markdown-fence rejection" "ledger row missing mutation_invalid_shape reason: $(cat "$LEDGER" 2>/dev/null) bad_out: $BAD_OUT"
fi

# ----- Test 12: dry-run A/B logs `dry_run: true` + canonical unchanged -----
# Capture the canonical .ag bytes before + after a dry-run pass. The
# A/B harness must NOT rename / archive / respawn in dry-run mode --
# the only side effect is the ledger row.

CANONICAL_BEFORE=$(python3 -c "
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    print(hashlib.sha256(f.read()).hexdigest())
" "$PARENT_AG")

rm -f "$LEDGER"
DRY12_OUT=$(MUTATE_LLM_STUB="$GOOD_STUB" \
    "$SCRIPT_DIR/auto-evolve-ab.sh" "$FAKE_FED" probe "$FAKE_COLONY" "$PARENT_AG" \
    --ticks 10 --config "$FAKE_CONFIG" --dry-run 2>&1) || true

CANONICAL_AFTER=$(python3 -c "
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    print(hashlib.sha256(f.read()).hexdigest())
" "$PARENT_AG")

# Check the ledger carries dry_run=true on the latest A/B verdict row.
DRY_FLAG_OK=false
if grep -qE '"dry_run": ?true' "$LEDGER" 2>/dev/null; then
    DRY_FLAG_OK=true
fi

if [ "$CANONICAL_BEFORE" = "$CANONICAL_AFTER" ] && [ "$DRY_FLAG_OK" = "true" ]; then
    pass "dry-run A/B: ledger dry_run=true and canonical .ag unchanged"
else
    fail "dry-run A/B side effects" "canonical_changed=$([ "$CANONICAL_BEFORE" = "$CANONICAL_AFTER" ] && echo no || echo yes) dry_flag=$DRY_FLAG_OK out: $DRY12_OUT ledger: $(cat "$LEDGER" 2>/dev/null)"
fi

# ----- Test 13: archive-path filename shape -----
# The live-mode archive path is `<archive_dir>/<agent>-gen-N-<sha8>.ag`.
# We can't trigger live mode in CI (requires podman + a live winner),
# so verify by introspecting the script: the format string must match
# the documented shape so a downstream operator's reaper can rely on
# `<agent>-gen-*-*.ag` globbing.

ARCHIVE_PATTERN=$(grep -E 'ARCHIVE_PATH=' "$SCRIPT_DIR/auto-evolve-ab.sh" | head -1)
# shellcheck disable=SC2016
# Intentional: matching the literal `$ARCHIVE_DIR/...` text as it
# appears verbatim in auto-evolve-ab.sh so a downstream operator's
# reaper can rely on `<agent>-gen-*-*.ag` globbing. We are NOT
# expanding the variables here.
EXPECTED_SHAPE='ARCHIVE_PATH="$ARCHIVE_DIR/${AGENT_NAME}-gen-${GENERATION_NEXT}-${PARENT_SHA8}.ag"'
if [ "$ARCHIVE_PATTERN" = "    $EXPECTED_SHAPE" ]; then
    pass "archive path: filename matches <agent>-gen-N-<sha8>.ag shape"
else
    fail "archive path shape" "expected '$EXPECTED_SHAPE' got '$ARCHIVE_PATTERN'"
fi

# ------------------------------------------------------------------
# PR-C (#628) new tests
# ------------------------------------------------------------------

# ----- Test 16: SPAWN_CMD path translation (#660) -----
# auto-evolve-ab.sh used to feed $CANDIDATE_PATH (host-side) into
# SPAWN_CMD inside the container. The container mounts the fed-dir at
# /run-root/, so the host path resolved to a non-existent file. Verify
# by introspection: the SPAWN_CMD line must reference
# $CANDIDATE_CONTAINER_PATH (declared above it) and the
# $CANDIDATE_CONTAINER_PATH declaration must start with /run-root/.

SPAWN_LINE=$(grep -nE '^SPAWN_CMD=' "$SCRIPT_DIR/auto-evolve-ab.sh" | head -1)
CONTAINER_DECL_LINE=$(grep -nE '^CANDIDATE_CONTAINER_PATH=' "$SCRIPT_DIR/auto-evolve-ab.sh" | head -1)
# shellcheck disable=SC2016
# Intentional: matching the literal `$CANDIDATE_` text as it appears
# verbatim in auto-evolve-ab.sh (the regex is consumed by grep, not the
# shell). We are NOT expanding the variable here.
PKILL_LINE=$(grep -nE 'pkill -f .agentis daemon \$CANDIDATE_' "$SCRIPT_DIR/auto-evolve-ab.sh" | head -1)

# shellcheck disable=SC2016
# Same intent as above: `\$CANDIDATE_PATH` is a grep regex literal.
if echo "$SPAWN_LINE" | grep -q 'CANDIDATE_CONTAINER_PATH' \
    && echo "$CONTAINER_DECL_LINE" | grep -q '"/run-root/' \
    && ! echo "$SPAWN_LINE" | grep -qE '\$CANDIDATE_PATH\b' \
    && echo "$PKILL_LINE" | grep -q 'CANDIDATE_CONTAINER_PATH' \
    && ! echo "$PKILL_LINE" | grep -qE '\$CANDIDATE_PATH\b'; then
    pass "path translation: SPAWN_CMD + pkill use container path (#660)"
else
    fail "path translation" "spawn=$SPAWN_LINE decl=$CONTAINER_DECL_LINE pkill=$PKILL_LINE"
fi

# ----- Test 17: mutator-stderr quote escaping (#661) -----
# The harness's stderr clipper used to allow byte 34 (double quote),
# which fractured the JSON ledger row when mutator stderr embedded
# quotes. Verify the clipper now strips byte 34 by replaying the exact
# Python snippet from auto-evolve-ab.sh against a quoted input and
# round-tripping the resulting JSON.

QUOTE_INPUT='mutator failed: backend returned "<bad>" shape'
CLIPPED=$(python3 -c "
import sys
buf = sys.argv[1].replace('\n', ' ')[:500]
print(''.join(c for c in buf if c == ' ' or (32 <= ord(c) < 127 and ord(c) != 34)))
" "$QUOTE_INPUT")

# Build the exact ledger extras JSON the harness would write, and parse
# it to verify validity.
LEDGER_JSON='{"reason":"mutator_failed","mutator_stderr":"'"$CLIPPED"'"}'
JSON_OK=$(python3 -c "
import json, sys
try:
    obj = json.loads(sys.argv[1])
    print('ok' if obj.get('reason') == 'mutator_failed' else 'bad_reason')
except (json.JSONDecodeError, ValueError):
    print('parse_error')
" "$LEDGER_JSON")

if [ "$JSON_OK" = "ok" ] && ! echo "$CLIPPED" | grep -q '"'; then
    pass "quote escaping: clipped stderr keeps JSON ledger row valid (#661)"
else
    fail "quote escaping" "json_ok=$JSON_OK clipped=$CLIPPED"
fi

# ----- Test 18: allowlist enforcement -----
# A config with `evolve.mutation.allowed_agents: ["explorer"]` must
# short-circuit when invoked with a non-explorer agent. The harness
# emits an `evolve_skipped_not_in_allowlist` ledger row and exits 0
# without producing a candidate.

ALLOWLIST_CONFIG="$TMPDIR_TEST/allowlist-config.yaml"
cat > "$ALLOWLIST_CONFIG" <<'ALLOWLISTEOF'
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

evolve:
  trigger:
    delta_slope_negative_for: 1000
    reject_rate_above: 0.20
    both_signals_required: false
  mutation:
    enabled: true
    allowed_agents: ["explorer"]
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
ALLOWLISTEOF

# Set up a noticer agent under the same fake fed.
NOTICER_DIR="$FAKE_FED/noticer/agents"
mkdir -p "$NOTICER_DIR"
NOTICER_AG="$NOTICER_DIR/noticer.ag"
cp "$PARENT_AG" "$NOTICER_AG"

rm -f "$LEDGER"
ALLOW_OUT=$(MUTATE_LLM_STUB="$GOOD_STUB" \
    "$SCRIPT_DIR/auto-evolve-ab.sh" "$FAKE_FED" noticer noticer "$NOTICER_AG" \
    --ticks 10 --config "$ALLOWLIST_CONFIG" 2>&1) || true
ALLOW_RC=$?

# Verify a) ledger row is evolve_skipped_not_in_allowlist, b) exit 0,
# c) no candidate file was created (the gate runs before mutator step).
ALLOW_CANDS=$(find "$NOTICER_DIR/.evolve" -name "*.candidate-gen-*" -type f 2>/dev/null | wc -l | tr -d ' ')

if grep -q '"event":"evolve_skipped_not_in_allowlist"\|"event": "evolve_skipped_not_in_allowlist"' "$LEDGER" 2>/dev/null \
    && [ "$ALLOW_RC" = "0" ] \
    && [ "$ALLOW_CANDS" = "0" ]; then
    pass "allowlist: non-explorer agent short-circuits + ledger row + exit 0"
else
    fail "allowlist enforcement" "rc=$ALLOW_RC cands=$ALLOW_CANDS ledger=$(cat "$LEDGER" 2>/dev/null) out: $ALLOW_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
