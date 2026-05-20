#!/usr/bin/env bash
# research-foundry/tools/test-hot-start.sh -- regression test for the
# Phase 5 PR-B (#626) hot-start consumers: explorer specialty bias +
# per-colony confidence restore at bootstrap.
#
# Five synthetic-fixture cases (no live container required, no
# `agentis` runtime required):
#   (1) No persistent dir -> round-robin fallback. Invokes
#       persistent-load.py weighted-specialty-slots with a missing
#       dir; expects 5 specialty lines matching the colony-variants.json
#       order (group_theory, combinatorics, number_theory, probability,
#       algebra).
#   (2) persistent/fittest_specialties.json present -> biased
#       distribution. Synthetic ranking group_theory > combinatorics >
#       number_theory > algebra > probability. Expects 4 slots
#       round-robin from the top-3 (group_theory, combinatorics,
#       number_theory) and 1 slot forced mutation from the bottom-2
#       (algebra OR probability).
#   (3) persistent/memo-snapshot.json with confidence values ->
#       load-confidence returns them. Synthetic snapshot with
#       explorer:confidence = 0.85. Expects stdout = `0.85\n`.
#   (4) Missing confidence in snapshot -> empty output. Snapshot
#       file exists but lacks `explorer:confidence`. Expects empty
#       stdout (shell caller then falls back to 0.7).
#   (5) bootstrap.sh dry-run byte-identity (no persistent). Invokes
#       run-research.sh with RESEARCH_PERSISTENT_DISABLED=1 versus
#       an empty persistent dir; the textual bootstrap-generating
#       branch in run-research.sh must emit the legacy round-robin /
#       hardcoded 5-way case form. Compares the actual generated
#       bootstrap.sh between (a) clean / disabled and (b) persistent
#       dir present but snapshot files absent. Byte-identity required.
#
# Pure stdlib (no pytest, no live federation, no podman).
# Hook this in via `bash research-foundry/tools/test-hot-start.sh`.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/persistent-load.py"
VARIANTS_JSON="$SCRIPT_DIR/colony-variants.json"
RUN_RESEARCH="$SCRIPT_DIR/run-research.sh"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$HELPER" ]; then
    fail "preflight" "$HELPER not found"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if [ ! -f "$VARIANTS_JSON" ]; then
    fail "preflight" "$VARIANTS_JSON not found"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if [ ! -f "$RUN_RESEARCH" ]; then
    fail "preflight" "$RUN_RESEARCH not found"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] python3 not on PATH"
    echo "Results: 0 passed, 0 failed (skipped)"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- (1) No persistent dir -> round-robin fallback ---
T1_DIR="$WORK/t1-nopersistent/does-not-exist"
T1_OUT="$(python3 "$HELPER" weighted-specialty-slots "$T1_DIR" "$VARIANTS_JSON" 5 2>"$WORK/t1.err")"
T1_EXPECTED="$(printf 'group_theory\ncombinatorics\nnumber_theory\nprobability\nalgebra')"
if [ "$T1_OUT" = "$T1_EXPECTED" ]; then
    pass "(1) no-persistent: weighted-specialty-slots falls back to round-robin"
else
    fail "(1) no-persistent: weighted-specialty-slots falls back to round-robin" \
         "got: $(printf '%s' "$T1_OUT" | tr '\n' '|') expected: $(printf '%s' "$T1_EXPECTED" | tr '\n' '|')"
fi

# --- (2) Biased distribution ---
T2_DIR="$WORK/t2-persistent"
mkdir -p "$T2_DIR"
cat >"$T2_DIR/fittest_specialties.json" <<'EOF'
{
  "schema": 1,
  "ranked": [
    {"specialty": "group_theory", "avg_fitness": 4.2, "runs_seen": 3},
    {"specialty": "combinatorics", "avg_fitness": 3.8, "runs_seen": 3},
    {"specialty": "number_theory", "avg_fitness": 2.5, "runs_seen": 3},
    {"specialty": "algebra", "avg_fitness": 1.0, "runs_seen": 3},
    {"specialty": "probability", "avg_fitness": 0.4, "runs_seen": 3}
  ]
}
EOF
T2_OUT="$(python3 "$HELPER" weighted-specialty-slots "$T2_DIR" "$VARIANTS_JSON" 5 2>"$WORK/t2.err")"
# Validate via python: 5 lines; first 4 are all in the top-3 set
# {group_theory, combinatorics, number_theory} with at least 1 occurrence
# of each (round-robin); the 5th line is from the bottom-2 set
# {algebra, probability}.
if printf '%s' "$T2_OUT" | python3 -c '
import sys
lines = [line for line in sys.stdin.read().split("\n") if line]
assert len(lines) == 5, "expected 5 lines, got " + str(len(lines)) + ": " + repr(lines)
top_set = {"group_theory", "combinatorics", "number_theory"}
bottom_set = {"algebra", "probability"}
top_slots = lines[:4]
bottom_slots = lines[4:]
for sp in top_slots:
    assert sp in top_set, "top slot " + repr(sp) + " not in top set " + repr(top_set)
assert set(top_slots) == top_set, \
    "top 4 slots should round-robin cover all of " + repr(top_set) + " (got " + repr(top_slots) + ")"
for sp in bottom_slots:
    assert sp in bottom_set, "bottom slot " + repr(sp) + " not in bottom set " + repr(bottom_set)
' >/dev/null 2>"$WORK/t2.assert.log"; then
    pass "(2) biased: 4 round-robin from top-3 + 1 forced mutation from bottom-2"
else
    fail "(2) biased: 4 round-robin from top-3 + 1 forced mutation from bottom-2" \
         "out: $(printf '%s' "$T2_OUT" | tr '\n' '|'); asserts: $(cat "$WORK/t2.assert.log")"
fi

# --- (3) load-confidence returns snapshot value ---
T3_DIR="$WORK/t3-persistent"
mkdir -p "$T3_DIR"
cat >"$T3_DIR/memo-snapshot.json" <<'EOF'
{
  "schema": 1,
  "snapshot_ts": "2026-05-19T12:00:00Z",
  "container": "research-foundry-laptop",
  "keys": {
    "explorer:confidence": "0.85",
    "noticer:confidence": "0.72"
  }
}
EOF
T3_OUT="$(python3 "$HELPER" load-confidence "$T3_DIR" explorer 2>"$WORK/t3.err")"
if [ "$T3_OUT" = "0.85" ]; then
    pass "(3) load-confidence: returns explorer:confidence = 0.85"
else
    fail "(3) load-confidence: returns explorer:confidence = 0.85" \
         "got: $(printf %s "$T3_OUT")"
fi

# --- (4) Missing confidence in snapshot -> empty output ---
T4_DIR="$WORK/t4-persistent"
mkdir -p "$T4_DIR"
cat >"$T4_DIR/memo-snapshot.json" <<'EOF'
{
  "schema": 1,
  "snapshot_ts": "2026-05-19T12:00:00Z",
  "container": "research-foundry-laptop",
  "keys": {
    "noticer:confidence": "0.72"
  }
}
EOF
T4_OUT="$(python3 "$HELPER" load-confidence "$T4_DIR" explorer 2>"$WORK/t4.err")"
if [ -z "$T4_OUT" ]; then
    pass "(4) load-confidence: missing key -> empty stdout"
else
    fail "(4) load-confidence: missing key -> empty stdout" \
         "got: $(printf %s "$T4_OUT")"
fi

# --- (5) bootstrap.sh byte-identity (no persistent) ---
# Generate two bootstraps:
#   (a) RESEARCH_PERSISTENT_DISABLED=1 (hot-start branch skipped)
#   (b) Empty PERSISTENT_DIR with no snapshot/fittest files (-f checks miss)
# Both must take the byte-identical legacy branch. Compare.
#
# We extract write_bootstrap from run-research.sh by running it in a
# sub-shell that defines minimal stubs and invokes only that function.
# This avoids touching the production script.

mkdir -p "$WORK/t5a"
mkdir -p "$WORK/t5b"

# Stand up a copy of run-research.sh with the orchestration tail
# replaced by a one-shot call to write_bootstrap, so we can capture
# the actual bootstrap text. PR-B preserves byte-identity in two
# pathways and we verify both produce the same file.
RR_TMP_A="$WORK/run-research-a.sh"
RR_TMP_B="$WORK/run-research-b.sh"

# Strip the orchestration body (the imperative tail at EOF) and
# append a single explicit `write_bootstrap` call so the script
# generates the bootstrap and exits cleanly without spawning anything.
awk '
    BEGIN { skip = 0 }
    /^install_cleanup_trap$/ { skip = 1 }
    skip == 0 { print }
    END {
        print ""
        print "write_bootstrap"
        print "exit 0"
    }
' "$RUN_RESEARCH" >"$RR_TMP_A"
cp "$RR_TMP_A" "$RR_TMP_B"
chmod +x "$RR_TMP_A" "$RR_TMP_B"

# Stub out `command -v` for podman/python3 prereq check by setting
# DRY_RUN=0 BUT pre-creating LAPTOP_DIR. The script does prereq + mkdir
# before write_bootstrap, and we want them to succeed quickly.
T5_RR_RUN_DIR_A="$WORK/t5a/run"
T5_RR_RUN_DIR_B="$WORK/t5b/run"
mkdir -p "$T5_RR_RUN_DIR_A" "$T5_RR_RUN_DIR_B"

# Skip the bin prereq check by ensuring podman+python3 are on PATH;
# python3 already is. Stub podman.
mkdir -p "$WORK/fakebin"
cat >"$WORK/fakebin/podman" <<'FAKEPODMAN'
#!/usr/bin/env bash
exit 0
FAKEPODMAN
chmod +x "$WORK/fakebin/podman"

# Variant (a): hot-start disabled by env knob, persistent dir not even
# created. The legacy branch fires unconditionally.
PATH="$WORK/fakebin:$PATH" \
    RESEARCH_RUN_DIR="$T5_RR_RUN_DIR_A" \
    RESEARCH_PERSISTENT_DIR="$WORK/t5a/persistent" \
    RESEARCH_PERSISTENT_DISABLED=1 \
    bash "$RR_TMP_A" >"$WORK/t5a.log" 2>&1

# Variant (b): hot-start enabled but persistent dir is empty (no
# memo-snapshot.json, no fittest_specialties.json). -f tests fail and
# the legacy branch fires.
mkdir -p "$WORK/t5b/persistent"
PATH="$WORK/fakebin:$PATH" \
    RESEARCH_RUN_DIR="$T5_RR_RUN_DIR_B" \
    RESEARCH_PERSISTENT_DIR="$WORK/t5b/persistent" \
    RESEARCH_PERSISTENT_DISABLED=0 \
    bash "$RR_TMP_B" >"$WORK/t5b.log" 2>&1

T5_BOOT_A="$(find "$T5_RR_RUN_DIR_A" -name bootstrap.sh 2>/dev/null | head -1)"
T5_BOOT_B="$(find "$T5_RR_RUN_DIR_B" -name bootstrap.sh 2>/dev/null | head -1)"

if [ -z "$T5_BOOT_A" ] || [ -z "$T5_BOOT_B" ]; then
    fail "(5) byte-identity: bootstrap.sh generated in both modes" \
         "A=$T5_BOOT_A B=$T5_BOOT_B; log-A: $(tail -5 "$WORK/t5a.log" 2>/dev/null); log-B: $(tail -5 "$WORK/t5b.log" 2>/dev/null)"
elif diff -u "$T5_BOOT_A" "$T5_BOOT_B" >"$WORK/t5.diff" 2>&1; then
    # Also assert the legacy round-robin form is in the output.
    if grep -q "1) sp=group_theory ;;" "$T5_BOOT_A" \
       && grep -q "5) sp=algebra ;;" "$T5_BOOT_A" \
       && grep -q "for c in explorer noticer skeptic" "$T5_BOOT_A"; then
        pass "(5) byte-identity: persistent-disabled vs empty-persistent emit identical bootstrap.sh"
    else
        fail "(5) byte-identity: legacy form present in bootstrap.sh" \
             "case statement / for-loop confidence seed not found in $T5_BOOT_A"
    fi
else
    fail "(5) byte-identity: persistent-disabled vs empty-persistent emit identical bootstrap.sh" \
         "diff: $(cat "$WORK/t5.diff")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
