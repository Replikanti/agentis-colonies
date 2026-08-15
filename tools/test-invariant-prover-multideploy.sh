#!/usr/bin/env bash
# tools/test-invariant-prover-multideploy.sh -- deterministic regression
# guard for #1075 (dark-factory, FM2). The fresh-deploy invariant-prover used
# to deploy ONE real target (single-contract) + mock its externals, so the
# highest-value CROSS-contract stablecoin bugs (oracle manipulation -> manager
# mispricing; reward accrual -> vault share inflation) were structurally out
# of reach. #1075 lets the operator pass AUXILIARY in-scope contracts via a
# repeatable `--aux <Contract.sol[:Name]>` flag; the runner stages each, names
# it, and threads the set to the prover as INV_AUX (a sentinel-joined
# `<abs_path>:<Name>` list, sentinel `@@A@@`, also in exec.env_passthrough).
# When INV_AUX is non-empty (composable-fresh mode) the prover EXTENDS the
# generation prompt: it injects every aux source (delimited
# `=== AUX CONTRACT (<name>) ===`), an import line per aux, and a directive to
# DEPLOY + WIRE the whole system in setUp() + write EXACTLY ONE deep
# cross-contract invariant (NO free value extraction / system solvency). When
# INV_AUX is EMPTY the single-target prompt is byte-identical to #1070-B1.
#
# This test pins the --aux threading + the composable-fresh directive so they
# cannot silently regress, and asserts the no-aux prompt path is unchanged
# (the composable extension is gated behind a `composableFresh`/INV_AUX flag,
# never injected unconditionally). Pure grep/awk over the .ag source + the
# runner -- no agentis runtime, no LLM, no forge required. Auto-discovered and
# run by tools/colony-lint.sh's `tools/test-*.sh` loop.
#
# Assertions:
#   (a) run-invariant-hunt.sh parses a repeatable `--aux` flag, validates each
#       value like --target (exists / is a *.sol), and threads the set as
#       INV_AUX with the `@@A@@` sentinel.
#   (b) run-invariant-hunt.sh adds INV_AUX to exec.env_passthrough AND to the
#       `env ... INV_AUX=...` go invocation.
#   (c) The prover reads INV_AUX, gates composable-fresh on a non-empty value,
#       and reuses the existing import_line / rel_import_path / cat_file
#       helpers over the aux entries (no duplicated import/deploy machinery).
#   (d) The composable-fresh directive is emitted when INV_AUX is set: the
#       deploy + WIRE the WHOLE system framing, the EXACTLY ONE deep
#       cross-contract invariant, the NO free value extraction property, the
#       `=== AUX CONTRACT (` source delimiter, and the grown (still bounded)
#       ~180-line budget all live in `compose_fresh_seed()`.
#   (e) The no-aux prompt is unchanged: the compose_fresh_seed/auxBlock/
#       auxImportLines are gated behind the composableFresh flag (so they are
#       "" when INV_AUX is empty), and the #1067/#1070-B1 single-target
#       anchors (the ~120-line budget, the REAL-target directive) survive.
#
# Usage: bash tools/test-invariant-prover-multideploy.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AG="$REPO_ROOT/dark-factory/auditor/agents/invariant-prover.ag"
RUNNER="$REPO_ROOT/dark-factory/run-invariant-hunt.sh"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

for f in "$AG" "$RUNNER"; do
    if [ ! -f "$f" ]; then
        fail "source exists" "$f not found"
        echo ""
        echo "Results: $PASS passed, $FAIL failed"
        exit 1
    fi
done

ag_src="$(cat "$AG")"
run_src="$(cat "$RUNNER")"

# (a) The runner parses a repeatable --aux, validates it like --target, and
# encodes the set into INV_AUX with the @@A@@ sentinel.
a_fail=""
# shellcheck disable=SC2016  # matching the literal source line, $ must not expand
printf '%s\n' "$run_src" | grep -Fq -- '--aux) need "$#"; AUX_SPECS+=("$2")' \
    || a_fail="${a_fail} no-aux-flag"
printf '%s\n' "$run_src" | grep -Fq -- '--aux must be a *.sol file' \
    || a_fail="${a_fail} no-sol-validation"
printf '%s\n' "$run_src" | grep -Fq -- '--aux not found under --repo' \
    || a_fail="${a_fail} no-exists-validation"
# shellcheck disable=SC2016  # matching the literal source line, $ must not expand
printf '%s\n' "$run_src" | grep -Fq 'INV_AUX="$INV_AUX@@A@@' \
    || a_fail="${a_fail} no-sentinel-join"

if [ -z "$a_fail" ]; then
    pass "(a) run-invariant-hunt.sh parses + validates a repeatable --aux and joins it into INV_AUX (@@A@@ sentinel)"
else
    fail "(a) run-invariant-hunt.sh parses + validates --aux into INV_AUX" \
         "missing piece(s):$a_fail"
fi

# (b) The runner threads INV_AUX: both into exec.env_passthrough and the env
# go-invocation.
b_fail=""
printf '%s\n' "$run_src" | grep -Eq 'env_passthrough = .*,INV_AUX' \
    || b_fail="${b_fail} no-env-passthrough"
# shellcheck disable=SC2016  # matching the literal env-invocation line, $ must not expand
printf '%s\n' "$run_src" | grep -Fq 'INV_AUX="$INV_AUX"' \
    || b_fail="${b_fail} no-go-invocation"

if [ -z "$b_fail" ]; then
    pass "(b) INV_AUX is added to exec.env_passthrough AND the env go-invocation"
else
    fail "(b) INV_AUX is threaded through env_passthrough + the go invocation" \
         "missing piece(s):$b_fail"
fi

# (c) The prover reads INV_AUX, gates composable-fresh on a non-empty value,
# and reuses the existing import/deploy helpers (no duplication).
c_fail=""
printf '%s\n' "$ag_src" | grep -Fq 'let invAux = getenv("INV_AUX");' \
    || c_fail="${c_fail} no-env-read"
printf '%s\n' "$ag_src" | grep -Eq 'fn[[:space:]]+composable_fresh\(' \
    || c_fail="${c_fail} no-gate-fn"
printf '%s\n' "$ag_src" | grep -Fq 'let composableFresh = composable_fresh(invAux);' \
    || c_fail="${c_fail} no-gate-binding"
# The aux import lines must reuse import_line + rel_import_path (the #1070-B1
# helpers), not a fresh copy.
printf '%s\n' "$ag_src" | grep -Fq 'import_line(aux_field(entry, 1), rel_import_path(invOut, aux_field(entry, 0)))' \
    || c_fail="${c_fail} no-helper-reuse"
# The aux sources must be read through the same sandboxed cat_file reader.
printf '%s\n' "$ag_src" | grep -Fq 'cat_file(aux_field(entry, 0))' \
    || c_fail="${c_fail} no-cat_file-reuse"

if [ -z "$c_fail" ]; then
    pass "(c) the prover reads INV_AUX, gates composable-fresh, and reuses the import_line/rel_import_path/cat_file helpers"
else
    fail "(c) the prover reads INV_AUX + reuses the existing import/deploy helpers" \
         "missing piece(s):$c_fail"
fi

# (d) The composable-fresh directive (deploy + WIRE the system + the EXACTLY
# ONE cross-contract invariant) lives in compose_fresh_seed().
seed_body="$(awk '/^fn compose_fresh_seed\(/{f=1} f{print} f&&/^}/{exit}' "$AG")"
d_fail=""
[ -n "$seed_body" ] || d_fail="${d_fail} no-compose_fresh_seed"
printf '%s\n' "$seed_body" | grep -Fq 'Deploy + WIRE the WHOLE system' \
    || d_fail="${d_fail} no-deploy-wire"
printf '%s\n' "$seed_body" | grep -Fq 'EXACTLY ONE deep CROSS-CONTRACT invariant' \
    || d_fail="${d_fail} no-cross-contract-invariant"
printf '%s\n' "$seed_body" | grep -Fq 'NO free value extraction' \
    || d_fail="${d_fail} no-free-value-extraction"
printf '%s\n' "$seed_body" | grep -Fq '=== AUX CONTRACT (' \
    || d_fail="${d_fail} no-aux-delimiter"
printf '%s\n' "$seed_body" | grep -Eq 'budget grows to ~?180 lines' \
    || d_fail="${d_fail} no-grown-budget"
printf '%s\n' "$seed_body" | grep -Fq 'adversarial implementation of it' \
    || d_fail="${d_fail} no-adversarial-actor-mandate"

if [ -z "$d_fail" ]; then
    pass "(d) compose_fresh_seed() emits the deploy+wire directive + the cross-contract invariant + the ~180-line budget"
else
    fail "(d) compose_fresh_seed() emits the composable-fresh directive" \
         "missing piece(s):$d_fail"
fi

# (e) The no-aux prompt is unchanged: the composable extension is gated behind
# the composableFresh flag (so it is "" when INV_AUX is empty), and the
# single-target anchors survive.
e_fail=""
# compose_fresh_seed returns "" when inactive (the additive-only contract).
printf '%s\n' "$seed_body" | grep -Fq 'if !active { return ""; }' \
    || e_fail="${e_fail} no-inactive-empty"
# The seed/auxBlock/auxImportLines are threaded into generate_test (so the
# extension is conditional, never inlined unconditionally).
printf '%s\n' "$ag_src" | grep -Fq 'compose_fresh_seed(composeFresh)' \
    || e_fail="${e_fail} no-conditional-seed"
# The #1067 single-target budget anchor must survive on the base path.
printf '%s\n' "$ag_src" | grep -Eq 'under ~?120 lines' \
    || e_fail="${e_fail} no-120-budget"
# The #1070-B1 REAL-target directive must survive on the base path.
printf '%s\n' "$ag_src" | grep -Fq 'IMPORT and DEPLOY the REAL target' \
    || e_fail="${e_fail} no-real-target"

if [ -z "$e_fail" ]; then
    pass "(e) the no-aux prompt is unchanged (composable-fresh is flag-gated; the #1067/#1070-B1 anchors survive)"
else
    fail "(e) the no-aux prompt is unchanged" \
         "missing piece(s):$e_fail"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
