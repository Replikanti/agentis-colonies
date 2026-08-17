#!/bin/bash
# tools/test-colony-lint-component-shellcheck.sh: unit tests for the #1945
# component-subdir extension of the #1554 federation-root shellcheck sweep
# in tools/colony-lint.sh.
#
# A "component" is a federation subdirectory that is NOT a colony (it has no
# config/ dir), e.g. dark-factory/hunt-dashboard/. Before #1945 neither the
# per-colony sweep (walks colonies only) nor the federation-root sweep
# (-maxdepth 1) reached its shell scripts.
#
# Validates:
#   Test 1: negative — a warning-level finding in <fed>/<component>/bad.sh
#           reddens the federation-level line (the regression #1945 reports).
#   Test 2: positive — a clean component subdir keeps the federation-level
#           line green, with the widened PASS label.
#   Test 3: depth — a finding in <fed>/<component>/nested/tools/deep.sh is
#           caught too (any future component gets coverage automatically).
#   Test 4: ownership — colony files stay owned by the per-colony sweep: a
#           dirty colony fails under its own prefix while the federation-level
#           line (clean component) still passes. No double-linting.
#   Test 5: prune — a finding under a dot-dir (<component>/.agentis/) does NOT
#           redden the lint, so local runtime state cannot break an operator.
#
# Each test builds a synthetic federation tree under its OWN real directory
# below $TMPDIR_TEST and runs `tools/colony-lint.sh <root>` against it. The
# roots are real dirs on purpose: `find` does not descend a symlinked
# federation without -H/-L, so a symlinked fixture would make the sweep see
# nothing and every case would false-pass.
#
# Usage: ./tools/test-colony-lint-component-shellcheck.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/colony-lint.sh"

# Mirrors how the lint itself degrades: CI installs shellcheck
# unconditionally, local machines may not have it.
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "[SKIP] shellcheck not installed — component-sweep tests need it"
    exit 0
fi

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

# Create a fresh lint root holding exactly one federation and echo the root
# path. A federation is any top-level dir with a README.md; it does NOT need
# a colony (a colonyless federation is merely [SKIP]ped by colony discovery,
# the root/component sweep runs regardless).
make_fed() {
    local fed="$1"
    local root="$TMPDIR_TEST/root-$fed"
    mkdir -p "$root/$fed"
    echo "# $fed" > "$root/$fed/README.md"
    echo "$root"
}

# A script carrying exactly one warning-level finding (SC2034, assigned but
# never used) — the severity band the sweep runs at.
write_dirty_script() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'SH'
#!/bin/bash
# Fixture: SC2034 — assigned but never read (warning severity).
unused_var="never read"
echo "fixture"
SH
}

write_clean_script() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'SH'
#!/bin/bash
echo "fixture"
SH
}

# Scaffold a minimal, structurally valid colony under $1/$2.
#
# The per-colony start-colony.sh flag check reads
# tools/colony-lint-flag-allowlist.awk relative to the lint root, and awk
# aborts the whole run under set -e if it is missing — so seed a tools/ dir
# with just that file. It stays free of *.sh / test-*.sh, so neither the
# tools shellcheck sweep nor the unit-test runner picks anything up from it.
make_colony() {
    local fed_path="$1" colony="$2"
    local col_path="$fed_path/$colony"
    local root
    root="$(dirname "$fed_path")"
    mkdir -p "$root/tools"
    cp "$SCRIPT_DIR/colony-lint-flag-allowlist.awk" "$root/tools/"
    mkdir -p "$col_path/config" "$col_path/scripts" "$col_path/agents"
    : > "$col_path/agents/.gitkeep"
    echo "# $colony" > "$col_path/README.md"
    cat > "$col_path/config/colony.example.toml" <<'TOML'
[colony]
name = "col-x"

[forge]
type = "none"

[llm]
backend = "cli"

[[agents]]
name = "demo"
source = "agents/demo.ag"
cb_budget = 100
TOML
    cat > "$col_path/scripts/start-colony.sh" <<'SH'
#!/bin/bash
exit 0
SH
    chmod +x "$col_path/scripts/start-colony.sh"
}

run_lint_on() {
    "$LINT" "$1" 2>&1
}

# --- Test 1: negative — dirty component subdir reddens the federation ---
root="$(make_fed "fed-comp-dirty")"
write_dirty_script "$root/fed-comp-dirty/component/bad.sh"
out="$(run_lint_on "$root" || true)"
if printf '%s\n' "$out" | grep -q "\[FAIL\] fed-comp-dirty: shellcheck errors"; then
    pass "test 1: finding in <fed>/<component>/*.sh fails the lint"
else
    fail "test 1: finding in <fed>/<component>/*.sh fails the lint" \
         "expected '[FAIL] fed-comp-dirty: shellcheck errors' in output, got: $out"
fi

# --- Test 2: positive — clean component subdir stays green --------------
root="$(make_fed "fed-comp-clean")"
write_clean_script "$root/fed-comp-clean/component/good.sh"
out="$(run_lint_on "$root" || true)"
if printf '%s\n' "$out" | grep -q "\[PASS\] fed-comp-clean: shellcheck OK (root + components, -S warning)"; then
    pass "test 2: clean component subdir passes with the widened label"
else
    fail "test 2: clean component subdir passes with the widened label" \
         "expected '[PASS] fed-comp-clean: shellcheck OK (root + components, -S warning)' in output, got: $out"
fi

# --- Test 3: depth — nested component tree is covered -------------------
root="$(make_fed "fed-comp-deep")"
write_dirty_script "$root/fed-comp-deep/component/nested/tools/deep.sh"
out="$(run_lint_on "$root" || true)"
if printf '%s\n' "$out" | grep -q "\[FAIL\] fed-comp-deep: shellcheck errors"; then
    pass "test 3: component subdirs are walked at unbounded depth"
else
    fail "test 3: component subdirs are walked at unbounded depth" \
         "expected '[FAIL] fed-comp-deep: shellcheck errors' in output, got: $out"
fi

# --- Test 4: ownership — colony files are not pulled into the fed line --
root="$(make_fed "fed-comp-colony")"
make_colony "$root/fed-comp-colony" "col-x"
write_dirty_script "$root/fed-comp-colony/col-x/scripts/dirty.sh"
write_clean_script "$root/fed-comp-colony/component/good.sh"
out="$(run_lint_on "$root" || true)"
if ! printf '%s\n' "$out" | grep -q "\[FAIL\] fed-comp-colony/col-x: shellcheck errors"; then
    fail "test 4: colony dirs stay owned by the per-colony sweep" \
         "expected '[FAIL] fed-comp-colony/col-x: shellcheck errors' in output, got: $out"
elif ! printf '%s\n' "$out" | grep -q "\[PASS\] fed-comp-colony: shellcheck OK (root + components, -S warning)"; then
    fail "test 4: colony dirs stay owned by the per-colony sweep" \
         "expected the federation-level line to still PASS, got: $out"
else
    pass "test 4: colony dirs stay owned by the per-colony sweep (no double-lint)"
fi

# --- Test 5: prune — dot-dirs inside a component are ignored ------------
root="$(make_fed "fed-comp-dot")"
write_dirty_script "$root/fed-comp-dot/component/.agentis/state.sh"
# One real (clean) component script so the federation has a verdict line at
# all — the sweep only reports when it collected at least one file.
write_clean_script "$root/fed-comp-dot/component/good.sh"
out="$(run_lint_on "$root" || true)"
if printf '%s\n' "$out" | grep -q "\[PASS\] fed-comp-dot: shellcheck OK (root + components, -S warning)"; then
    pass "test 5: dot-dirs inside a component are pruned"
else
    fail "test 5: dot-dirs inside a component are pruned" \
         "expected '[PASS] fed-comp-dot: shellcheck OK (root + components, -S warning)' in output, got: $out"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
