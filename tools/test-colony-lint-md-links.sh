#!/bin/bash
# tools/test-colony-lint-md-links.sh: regression test for #1910 — the
# per-federation markdown-link check in tools/colony-lint.sh must cover
# ALL top-level federation *.md files (README, CHANGELOG, runbooks,
# scorecards, ...), not just README.md.
#
# Validates:
#   Test 1: negative — a deliberately-broken relative link in a top-level
#           federation *.md file OTHER than README.md (e.g. a runbook)
#           makes colony-lint fail with a "broken link" report naming it.
#   Test 2: positive — the same fixture with a valid relative link instead
#           lints clean, proving the check does not false-positive on a
#           correct top-level doc.
#
# Each test builds a synthetic federation tree under $TMPDIR_TEST and runs
# tools/colony-lint.sh against it, then greps the output.
#
# Usage: ./tools/test-colony-lint-md-links.sh
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

# Helper: scaffold a minimal federation+colony tree, with a single-agent
# colony.example.toml plus a top-level RUNBOOK.md whose one relative link
# is the caller-provided target (relative to the federation root,
# mirroring how e.g. dark-factory/FUNNEL-RUNBOOK.md links to sibling
# docs). Built directly under a fresh, non-symlinked lintroot (each test
# gets its own): colony-lint's top-level-*.md discovery uses
# `find "$fed_path" -maxdepth 1 ...` where $fed_path is the literal
# argument passed to find — GNU find does NOT descend into a search root
# that is itself a symlink (only through symlinks reached via a deeper
# path component), so the older `ln -s` isolation trick used by
# test-colony-lint-no-forge.sh silently starves this specific check.
make_fixture() {
    local fed="$1" colony="$2" link_target="$3"
    local fed_root
    fed_root="$(mktemp -d "$TMPDIR_TEST/lintroot.XXXXXX")"
    local fed_path="$fed_root/$fed"
    local col_path="$fed_path/$colony"
    mkdir -p "$col_path/config" "$col_path/scripts" "$col_path/agents"
    : > "$col_path/agents/.gitkeep"
    echo "# $fed" > "$fed_path/README.md"
    echo "# $colony" > "$col_path/README.md"
    cat > "$fed_path/RUNBOOK.md" <<EOF
# $fed runbook

See [details]($link_target) for more.
EOF
    cat > "$col_path/config/colony.example.toml" <<'TOML'
[colony]
name = "col-fixture"

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
    # The daemon-flag-allowlist check unconditionally reads
    # $REPO_ROOT/tools/colony-lint-flag-allowlist.awk (no existence guard)
    # once a colony's start-colony.sh is present; under `set -euo pipefail`
    # a missing file there aborts the whole lint run before it ever reaches
    # the markdown-link check this test cares about. Mirror just that one
    # file into the isolated root (not the whole tools/ dir — that would
    # make colony-lint re-discover and re-run every tools/test-*.sh here).
    mkdir -p "$fed_root/tools"
    cp "$SCRIPT_DIR/colony-lint-flag-allowlist.awk" "$fed_root/tools/"
    echo "$fed_root"
}

# Run colony-lint against a lintroot produced by make_fixture and capture
# both stdout+stderr.
run_lint_on() {
    local fed_root="$1"
    "$LINT" "$fed_root" 2>&1
    rm -rf "$fed_root"
}

# --- Test 1: negative — broken relative link in top-level RUNBOOK.md ---
fed_root_1="$(make_fixture "fed-1-runbook-broken" "col-a" "./doc/does-not-exist.md")"

out="$(run_lint_on "$fed_root_1" || true)"
if printf '%s\n' "$out" | grep -q "broken link in RUNBOOK.md: ./doc/does-not-exist.md"; then
    pass "test 1: broken link in top-level federation RUNBOOK.md fails colony-lint"
else
    fail "test 1: broken link in top-level federation RUNBOOK.md fails colony-lint" \
         "expected a 'broken link in RUNBOOK.md' failure in output, got: $out"
fi

# --- Test 2: positive — valid relative link in top-level RUNBOOK.md -----
fed_root_2="$(make_fixture "fed-2-runbook-ok" "col-b" "./README.md")"

out="$(run_lint_on "$fed_root_2" || true)"
if printf '%s\n' "$out" | grep -q "fed-2-runbook-ok/col-b: markdown links OK" \
    && ! printf '%s\n' "$out" | grep -q "broken link in RUNBOOK.md"; then
    pass "test 2: valid link in top-level federation RUNBOOK.md lints clean"
else
    fail "test 2: valid link in top-level federation RUNBOOK.md lints clean" \
         "expected clean markdown-links pass with no RUNBOOK.md failure, got: $out"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
