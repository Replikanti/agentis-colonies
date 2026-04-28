#!/bin/bash
# tools/test-colony-lint-no-forge.sh: unit tests for the #373 non-forge
# opt-out in tools/colony-lint.sh.
#
# Validates:
#   Test 1: positive — a colony with [forge].type = "none" and no
#           [forge.gitlab]/[forge.github] sub-block lints clean.
#   Test 2: positive — same colony with [forge].type = "none" plus a
#           leftover [forge.github] sub-block also lints clean (sub-block
#           is ignored, not validated).
#   Test 3: negative — a colony with [forge].type = "github" and no
#           [forge.github] sub-block still fails (regression for
#           dev-apprenticeship-shaped configs).
#   Test 4: negative — a colony with [forge].type = "gitlab" and no
#           [forge.gitlab] sub-block still fails (mirror of test 3).
#   Test 5: negative — a colony with a typo'd forge type (e.g. "non")
#           is rejected with the updated allowed-list message that
#           includes "none".
#   Test 6: integration — `new-federation.sh` (default, no `--no-forge`)
#           generates a `start-colony.sh` whose `case "$FORGE_TYPE"` block
#           includes a `none)` arm and an error message that lists all
#           three valid types. Guards the post-hoc-flip path: an operator
#           who scaffolds default and later edits `colony.toml` to
#           `type = "none"` does not get an "unknown [forge].type" error.
#
# Each test builds a synthetic federation tree under $TMPDIR_TEST and
# runs `tools/colony-lint.sh <tmpdir>` against it, then greps the output.
#
# Usage: ./tools/test-colony-lint-no-forge.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/colony-lint.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

# Helper: scaffold a minimal federation+colony tree under $TMPDIR_TEST/$1
# with the colony.example.toml body provided on stdin. Each invocation
# uses a unique federation name so successive tests do not collide on the
# same shared $TMPDIR_TEST root.
make_fixture() {
    local fed="$1" colony="$2"
    local fed_path="$TMPDIR_TEST/$fed"
    local col_path="$fed_path/$colony"
    mkdir -p "$col_path/config" "$col_path/scripts" "$col_path/agents"
    : > "$col_path/agents/.gitkeep"
    echo "# $fed" > "$fed_path/README.md"
    echo "# $colony" > "$col_path/README.md"
    cat > "$col_path/config/colony.example.toml"
    cat > "$col_path/scripts/start-colony.sh" <<'SH'
#!/bin/bash
exit 0
SH
    chmod +x "$col_path/scripts/start-colony.sh"
}

# Run colony-lint against a single-federation tree at $TMPDIR_TEST/$1
# and capture both stdout+stderr.
run_lint_on() {
    local fed="$1"
    local fed_root
    fed_root="$(mktemp -d "$TMPDIR_TEST/lintroot.XXXXXX")"
    # colony-lint discovers federations as sibling dirs under its arg —
    # symlink the chosen federation into a fresh root so unrelated
    # fixtures from earlier tests are not in scope.
    ln -s "$TMPDIR_TEST/$fed" "$fed_root/$fed"
    "$LINT" "$fed_root" 2>&1
    rm -rf "$fed_root"
}

# --- Test 1: positive — [forge].type = "none", no sub-block -----------
make_fixture "fed-1-none-clean" "col-a" <<'TOML'
[colony]
name = "col-a"

[forge]
type = "none"

[llm]
backend = "cli"

[[agents]]
name = "demo"
source = "agents/demo.ag"
cb_budget = 100
TOML

out="$(run_lint_on "fed-1-none-clean" || true)"
if printf '%s\n' "$out" | grep -q "fed-1-none-clean/col-a: config OK"; then
    pass "test 1: forge.type=none with no sub-block lints clean"
else
    fail "test 1: forge.type=none with no sub-block lints clean" \
         "expected '[PASS] fed-1-none-clean/col-a: config OK' in output, got: $out"
fi

# --- Test 2: positive — [forge].type = "none" with leftover sub-block --
make_fixture "fed-2-none-leftover" "col-b" <<'TOML'
[colony]
name = "col-b"

[forge]
type = "none"

[forge.github]
url = "https://api.github.invalid"
owner = "leftover"
repo = "leftover"
token = "your-leftover-token"
me = "leftover"

[llm]
backend = "cli"

[[agents]]
name = "demo"
source = "agents/demo.ag"
cb_budget = 100
TOML

out="$(run_lint_on "fed-2-none-leftover" || true)"
if printf '%s\n' "$out" | grep -q "fed-2-none-leftover/col-b: config OK"; then
    pass "test 2: forge.type=none with leftover [forge.github] still lints clean"
else
    fail "test 2: forge.type=none with leftover [forge.github] still lints clean" \
         "expected '[PASS] fed-2-none-leftover/col-b: config OK' in output, got: $out"
fi

# --- Test 3: negative — [forge].type = "github", no sub-block ----------
make_fixture "fed-3-github-missing" "col-c" <<'TOML'
[colony]
name = "col-c"

[forge]
type = "github"

[llm]
backend = "cli"

[[agents]]
name = "demo"
source = "agents/demo.ag"
cb_budget = 100
TOML

out="$(run_lint_on "fed-3-github-missing" || true)"
# #316 M1 widened the missing-block error message to mention the
# alternate `[[forge.github]]` array-of-tables shape.
if printf '%s\n' "$out" | grep -q '\[forge\].type = "github" but \[forge.github\] (or \[\[forge.github\]\]) is missing'; then
    pass "test 3: forge.type=github with no [forge.github] still fails"
else
    fail "test 3: forge.type=github with no [forge.github] still fails" \
         "expected missing-[forge.github] error in output, got: $out"
fi

# --- Test 4: negative — [forge].type = "gitlab", no sub-block ----------
make_fixture "fed-4-gitlab-missing" "col-d" <<'TOML'
[colony]
name = "col-d"

[forge]
type = "gitlab"

[llm]
backend = "cli"

[[agents]]
name = "demo"
source = "agents/demo.ag"
cb_budget = 100
TOML

out="$(run_lint_on "fed-4-gitlab-missing" || true)"
# #316 M1 widened the missing-block error message to mention the
# alternate `[[forge.gitlab]]` array-of-tables shape.
if printf '%s\n' "$out" | grep -q '\[forge\].type = "gitlab" but \[forge.gitlab\] (or \[\[forge.gitlab\]\]) is missing'; then
    pass "test 4: forge.type=gitlab with no [forge.gitlab] still fails"
else
    fail "test 4: forge.type=gitlab with no [forge.gitlab] still fails" \
         "expected missing-[forge.gitlab] error in output, got: $out"
fi

# --- Test 5: negative — typo'd forge type "non" ------------------------
make_fixture "fed-5-typo" "col-e" <<'TOML'
[colony]
name = "col-e"

[forge]
type = "non"

[llm]
backend = "cli"

[[agents]]
name = "demo"
source = "agents/demo.ag"
cb_budget = 100
TOML

out="$(run_lint_on "fed-5-typo" || true)"
# The updated allowlist message must mention all three of: gitlab, github,
# and none — so a contributor who fat-fingers "non" sees the full menu.
if printf '%s\n' "$out" | grep -q '\[forge\].type must be "gitlab", "github", or "none"'; then
    pass "test 5: typo'd forge type rejected with updated allowed-list message"
else
    fail "test 5: typo'd forge type rejected with updated allowed-list message" \
         "expected updated allowed-list message in output, got: $out"
fi

# --- Test 6: integration — default new-federation.sh emits none) arm ---
# Scaffolds a default (forge-bound) federation and inspects the generated
# start-colony.sh. The `none)` arm + updated error message let an operator
# flip `colony.toml` to `type = "none"` post-hoc without runtime breakage.
#
# new-federation.sh always writes to its REPO_ROOT (parent of tools/), so
# the test cannot redirect output to $TMPDIR_TEST. Use a unique federation
# name and clean up explicitly. PID + RANDOM disambiguates parallel runs.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST6_FED="fd-no-forge-test6-$$-${RANDOM}"
TEST6_PATH="$REPO_ROOT/$TEST6_FED"
# Add cleanup to the existing EXIT trap rather than overwriting it.
trap 'rm -rf "$TMPDIR_TEST" "$TEST6_PATH"' EXIT
(
    cd "$REPO_ROOT"
    "$SCRIPT_DIR/new-federation.sh" "$TEST6_FED" "col-default" >/dev/null 2>&1
)
gen_start_colony="$TEST6_PATH/col-default/scripts/start-colony.sh"
if [ ! -f "$gen_start_colony" ]; then
    fail "test 6: default new-federation.sh emits none) arm" \
         "scaffolded start-colony.sh not found at $gen_start_colony"
elif ! grep -qE '^[[:space:]]*none\)' "$gen_start_colony"; then
    fail "test 6: default new-federation.sh emits none) arm" \
         "no 'none)' case arm in $gen_start_colony"
elif ! grep -q 'expected: gitlab|github|none' "$gen_start_colony"; then
    fail "test 6: default new-federation.sh emits none) arm" \
         "wildcard error message did not list 'none' as a valid type"
else
    pass "test 6: default new-federation.sh emits none) arm + updated error msg"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
