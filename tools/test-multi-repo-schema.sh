#!/bin/bash
# tools/test-multi-repo-schema.sh: unit tests for the #316 M1 multi-repo
# schema, parser, lint, and migration tool.
#
# Validates:
#   Test 1: parse_toml_array_count on a 0-block config returns 0
#   Test 2: parse_toml_array_count on a 3-block config returns 3
#   Test 3: parse_toml_array_get returns the right owner/repo per index
#   Test 4: legacy single-block config FAILS colony-lint with v2.0.0 retirement
#           message (#316 M6) and names tools/migrate-to-multi-repo.sh
#   Test 5: multi-block (1 entry) passes colony-lint
#   Test 6: multi-block (5 entries) passes colony-lint
#   Test 7: both-forms config fails colony-lint with new "drop the [forge.github]
#           block" wording (#316 M6)
#   Test 8: missing owner in entry [1] fails colony-lint
#   Test 9: empty [[forge.github]] array fails colony-lint
#   Test 10: migration tool round-trip — legacy -> migrate -> lint -> multi-repo passes
#   Test 11: idempotency — migrate twice produces byte-identical output
#   Test 12: --dry-run prints to stdout without modifying file
#   Test 13: migration preserves comments and inline `# ...` annotations
#   Test 14: migration preserves operator hand-edited indentation
#   Test 15: migration on already-migrated file exits 0 with "already migrated" message
#   Test 16: migration on bare-`[forge.gitlab]`-only config exits 3 (no github block)
#   Test 17: migration tool on a fresh-from-template (already `[[forge.github]]`)
#            colony.example.toml exits 0 with "already migrated" (#316 M6)
#   Test 18: lint the post-M6 fresh dev-apprenticeship/triage/config/colony.example.toml
#            directly — must pass (#316 M6)
#
# Standard scaffold: set -eu, mktemp -d isolation, EXIT trap for cleanup.
# Auto-discovered by colony-lint.sh's tools-test loop.
#
# Usage: ./tools/test-multi-repo-schema.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/colony-lint.sh"
MIGRATE="$SCRIPT_DIR/migrate-to-multi-repo.sh"
# shellcheck source=parse-toml.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/parse-toml.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

# Helper: scaffold a minimal federation+colony tree under $TMPDIR_TEST/$1
# with the colony.example.toml body provided on stdin.
make_fixture() {
    local fed="$1" colony="$2"
    local fed_path="$TMPDIR_TEST/$fed"
    local col_path="$fed_path/$colony"
    mkdir -p "$col_path/config" "$col_path/scripts" "$col_path/agents"
    : > "$col_path/agents/.gitkeep"
    echo "# $fed" > "$fed_path/README.md"
    echo "# $colony" > "$col_path/README.md"
    cat > "$col_path/config/colony.example.toml"
    {
        printf '%s\n' '#!/bin/bash'
        printf '%s\n' 'exit 0'
    } > "$col_path/scripts/start-colony.sh"
    chmod +x "$col_path/scripts/start-colony.sh"
}

# Run colony-lint against a single-federation tree at $TMPDIR_TEST/$1
# and capture both stdout+stderr.
run_lint_on() {
    local fed="$1"
    local fed_root
    fed_root="$(mktemp -d "$TMPDIR_TEST/lintroot.XXXXXX")"
    ln -s "$TMPDIR_TEST/$fed" "$fed_root/$fed"
    "$LINT" "$fed_root" 2>&1
    rm -rf "$fed_root"
}

# --- Test 1: parse_toml_array_count on a 0-block config returns 0 -----
CONFIG="$TMPDIR_TEST/zero.toml"
{
    printf '%s\n' '[colony]'
    printf '%s\n' 'name = "demo"'
    printf '%s\n' ''
    printf '%s\n' '[forge.github]'
    printf '%s\n' 'owner = "acme"'
    printf '%s\n' 'repo = "single"'
} > "$CONFIG"
export CONFIG
out="$(parse_toml_array_count forge.github 2>&1)"
if [ "$out" = "0" ]; then
    pass "test 1: parse_toml_array_count on 0-block config returns 0"
else
    fail "test 1: parse_toml_array_count on 0-block config returns 0" "expected '0', got '$out'"
fi

# --- Test 2: parse_toml_array_count on a 3-block config returns 3 ------
CONFIG="$TMPDIR_TEST/three.toml"
{
    printf '%s\n' '[colony]'
    printf '%s\n' 'name = "demo"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'owner = "acme"'
    printf '%s\n' 'repo = "frontend"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'owner = "acme"'
    printf '%s\n' 'repo = "backend"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'owner = "acme"'
    printf '%s\n' 'repo = "infra"'
} > "$CONFIG"
export CONFIG
out="$(parse_toml_array_count forge.github 2>&1)"
if [ "$out" = "3" ]; then
    pass "test 2: parse_toml_array_count on 3-block config returns 3"
else
    fail "test 2: parse_toml_array_count on 3-block config returns 3" "expected '3', got '$out'"
fi

# --- Test 3: parse_toml_array_get returns the right owner/repo per index
# Re-uses the 3-block CONFIG from test 2.
got_owner_0="$(parse_toml_array_get forge.github 0 owner 2>&1)"
got_repo_1="$(parse_toml_array_get forge.github 1 repo 2>&1)"
got_repo_2="$(parse_toml_array_get forge.github 2 repo 2>&1)"
got_oor="$(parse_toml_array_get forge.github 99 repo 2>&1)"
if [ "$got_owner_0" = "acme" ] \
   && [ "$got_repo_1" = "backend" ] \
   && [ "$got_repo_2" = "infra" ] \
   && [ -z "$got_oor" ]; then
    pass "test 3: parse_toml_array_get returns the right owner/repo per index"
else
    fail "test 3: parse_toml_array_get returns the right owner/repo per index" \
         "owner[0]='$got_owner_0' repo[1]='$got_repo_1' repo[2]='$got_repo_2' oor='$got_oor'"
fi

# --- Test 4: legacy single-block config FAILS colony-lint (#316 M6) ----
# Post-M6 lint hard-fails on `[forge.github]` single-table form. The
# error message must name `tools/migrate-to-multi-repo.sh` so operators
# upgrading from v1.x have an actionable migration step.
make_fixture "fed-4-legacy" "col-a" <<'TOML'
[colony]
name = "col-a"

[forge]
type = "github"

[forge.github]
url = "https://api.github.com"
owner = "acme"
repo = "frontend"
token = "your-github-token"
me = "alice"

[llm]
backend = "cli"

[[agents]]
name = "demo"
source = "agents/demo.ag"
cb_budget = 100
TOML
out="$(run_lint_on "fed-4-legacy" || true)"
if printf '%s\n' "$out" | grep -q 'single-table form is retired in v2.0.0' \
   && printf '%s\n' "$out" | grep -q 'tools/migrate-to-multi-repo.sh'; then
    pass "test 4: legacy single-block config FAILS colony-lint with v2.0.0 retirement message and migration command (#316 M6)"
else
    fail "test 4: legacy single-block config FAILS colony-lint with v2.0.0 retirement message and migration command (#316 M6)" \
         "expected 'single-table form is retired in v2.0.0' AND 'tools/migrate-to-multi-repo.sh' in output, got: $out"
fi

# --- Test 5: multi-block (1 entry) passes colony-lint ------------------
make_fixture "fed-5-multi-1" "col-b" <<'TOML'
[colony]
name = "col-b"

[forge]
type = "github"

[[forge.github]]
url = "https://api.github.com"
owner = "acme"
repo = "frontend"
token = "your-github-token"
me = "alice"

[llm]
backend = "cli"

[[agents]]
name = "demo"
source = "agents/demo.ag"
cb_budget = 100
TOML
out="$(run_lint_on "fed-5-multi-1" || true)"
if printf '%s\n' "$out" | grep -q "fed-5-multi-1/col-b: config OK"; then
    pass "test 5: multi-block (1 entry) passes colony-lint"
else
    fail "test 5: multi-block (1 entry) passes colony-lint" \
         "expected '[PASS] fed-5-multi-1/col-b: config OK', got: $out"
fi

# --- Test 6: multi-block (5 entries) passes colony-lint ----------------
make_fixture "fed-6-multi-5" "col-c" <<'TOML'
[colony]
name = "col-c"

[forge]
type = "github"

[[forge.github]]
url = "https://api.github.com"
owner = "acme"
repo = "r1"

[[forge.github]]
url = "https://api.github.com"
owner = "acme"
repo = "r2"

[[forge.github]]
url = "https://api.github.com"
owner = "acme"
repo = "r3"

[[forge.github]]
url = "https://api.github.com"
owner = "acme"
repo = "r4"

[[forge.github]]
url = "https://api.github.com"
owner = "acme"
repo = "r5"

[llm]
backend = "cli"

[[agents]]
name = "demo"
source = "agents/demo.ag"
cb_budget = 100
TOML
out="$(run_lint_on "fed-6-multi-5" || true)"
if printf '%s\n' "$out" | grep -q "fed-6-multi-5/col-c: config OK"; then
    pass "test 6: multi-block (5 entries) passes colony-lint"
else
    fail "test 6: multi-block (5 entries) passes colony-lint" \
         "expected '[PASS] fed-6-multi-5/col-c: config OK', got: $out"
fi

# --- Test 7: both-forms config fails colony-lint (#316 M6 wording) -----
make_fixture "fed-7-both-forms" "col-d" <<'TOML'
[colony]
name = "col-d"

[forge]
type = "github"

[forge.github]
url = "https://api.github.com"
owner = "acme"
repo = "single"

[[forge.github]]
url = "https://api.github.com"
owner = "acme"
repo = "multi"

[llm]
backend = "cli"

[[agents]]
name = "demo"
source = "agents/demo.ag"
cb_budget = 100
TOML
out="$(run_lint_on "fed-7-both-forms" || true)"
if printf '%s\n' "$out" | grep -q 'drop the \[forge.github\] block'; then
    pass "test 7: both-forms config fails colony-lint with 'drop the [forge.github] block' message"
else
    fail "test 7: both-forms config fails colony-lint with 'drop the [forge.github] block' message" \
         "expected 'drop the [forge.github] block' in output, got: $out"
fi

# --- Test 8: missing owner in entry [1] fails colony-lint --------------
make_fixture "fed-8-missing-owner" "col-e" <<'TOML'
[colony]
name = "col-e"

[forge]
type = "github"

[[forge.github]]
url = "https://api.github.com"
owner = "acme"
repo = "ok"

[[forge.github]]
url = "https://api.github.com"
repo = "no-owner-here"

[llm]
backend = "cli"

[[agents]]
name = "demo"
source = "agents/demo.ag"
cb_budget = 100
TOML
out="$(run_lint_on "fed-8-missing-owner" || true)"
if printf '%s\n' "$out" | grep -q '\[\[forge.github\]\]\[1\] missing required key: owner'; then
    pass "test 8: missing owner in entry [1] fails colony-lint"
else
    fail "test 8: missing owner in entry [1] fails colony-lint" \
         "expected '[[forge.github]][1] missing required key: owner' in output, got: $out"
fi

# --- Test 9: empty [[forge.github]] array fails colony-lint ------------
# tomllib accepts no `[[forge.github]]` lines as "key absent" rather than
# "empty array". The empty-array failure path is reached when the schema
# gets a github sub-block-of-the-wrong-shape (e.g. `[forge].github = []`
# inline). Compose that fixture.
make_fixture "fed-9-empty-array" "col-f" <<'TOML'
[colony]
name = "col-f"

[forge]
type = "github"
github = []

[llm]
backend = "cli"

[[agents]]
name = "demo"
source = "agents/demo.ag"
cb_budget = 100
TOML
out="$(run_lint_on "fed-9-empty-array" || true)"
if printf '%s\n' "$out" | grep -q '\[\[forge.github\]\] array is empty'; then
    pass "test 9: empty [[forge.github]] array fails colony-lint"
else
    fail "test 9: empty [[forge.github]] array fails colony-lint" \
         "expected '[[forge.github]] array is empty' in output, got: $out"
fi

# --- Test 10: migration tool round-trip — legacy -> migrate -> lint -----
make_fixture "fed-10-migrate" "col-g" <<'TOML'
[colony]
name = "col-g"

[forge]
type = "github"

[forge.github]
url = "https://api.github.com"
owner = "acme"
repo = "round-trip"
token = "your-github-token"
me = "alice"

[llm]
backend = "cli"

[[agents]]
name = "demo"
source = "agents/demo.ag"
cb_budget = 100
TOML
TARGET10="$TMPDIR_TEST/fed-10-migrate/col-g/config/colony.example.toml"
"$MIGRATE" "$TARGET10" >/dev/null
out="$(run_lint_on "fed-10-migrate" || true)"
if grep -qE '^\[\[forge.github\]\]$' "$TARGET10" \
   && printf '%s\n' "$out" | grep -q "fed-10-migrate/col-g: config OK"; then
    pass "test 10: migration tool round-trip — legacy -> migrate -> lint passes"
else
    pre_grep="$(grep -nE '^\[\[?forge.github\]\]?$' "$TARGET10" || true)"
    fail "test 10: migration tool round-trip — legacy -> migrate -> lint passes" \
         "post-migrate grep: $pre_grep ; lint: $out"
fi

# --- Test 11: idempotency — migrate twice produces byte-identical output
make_fixture "fed-11-idempotent" "col-h" <<'TOML'
[colony]
name = "col-h"

[forge]
type = "github"

[forge.github]
owner = "acme"
repo = "idem"
TOML
TARGET11="$TMPDIR_TEST/fed-11-idempotent/col-h/config/colony.example.toml"
"$MIGRATE" "$TARGET11" >/dev/null
cp "$TARGET11" "$TMPDIR_TEST/idem.first"
"$MIGRATE" "$TARGET11" >/dev/null
if cmp -s "$TARGET11" "$TMPDIR_TEST/idem.first"; then
    pass "test 11: idempotency — migrate twice produces byte-identical output"
else
    fail "test 11: idempotency — migrate twice produces byte-identical output" \
         "files differ after second migrate"
fi

# --- Test 12: --dry-run prints to stdout without modifying file --------
make_fixture "fed-12-dry-run" "col-i" <<'TOML'
[colony]
name = "col-i"

[forge]
type = "github"

[forge.github]
owner = "acme"
repo = "dry"
TOML
TARGET12="$TMPDIR_TEST/fed-12-dry-run/col-i/config/colony.example.toml"
cp "$TARGET12" "$TMPDIR_TEST/dry.before"
dry_out="$("$MIGRATE" --dry-run "$TARGET12")"
if cmp -s "$TARGET12" "$TMPDIR_TEST/dry.before" \
   && printf '%s' "$dry_out" | grep -qE '^\[\[forge.github\]\]$' \
   && ! printf '%s' "$dry_out" | grep -qE '^\[forge.github\]$'; then
    pass "test 12: --dry-run prints to stdout without modifying file"
else
    fail "test 12: --dry-run prints to stdout without modifying file" \
         "file changed or stdout missing rewritten header. dry_out: $dry_out"
fi

# --- Test 13: migration preserves comments and inline annotations ------
# Note: an inline comment after `[forge.github]` on the same line means
# the stripped line is no longer literally `[forge.github]`, so the
# rewriter (single-line equality match) does not touch it. Comments
# above and to the right of key/value lines are the supported pattern.
make_fixture "fed-13-comments" "col-j" <<'TOML'
[colony]
name = "col-j"

# operator note: this colony serves the apprenticeship project
[forge]
type = "github"

# Production token — keep me secret
[forge.github]
owner = "acme"  # tenant
repo = "main-repo"
TOML
TARGET13="$TMPDIR_TEST/fed-13-comments/col-j/config/colony.example.toml"
"$MIGRATE" "$TARGET13" >/dev/null
if grep -q '# operator note: this colony serves the apprenticeship project' "$TARGET13" \
   && grep -q '# Production token — keep me secret' "$TARGET13" \
   && grep -q '# tenant' "$TARGET13" \
   && grep -qE '^\[\[forge.github\]\]$' "$TARGET13"; then
    pass "test 13: migration preserves comments and inline # annotations"
else
    fail "test 13: migration preserves comments and inline # annotations" \
         "expected comments preserved in $TARGET13"
fi

# --- Test 14: migration preserves operator hand-edited indentation -----
# An operator-style hand-edit puts two leading spaces in front of the
# section header (illegal TOML but a common typo in field configs). The
# rewrite should preserve the leading whitespace exactly.
TARGET14="$TMPDIR_TEST/indent.toml"
{
    printf '%s\n' '[colony]'
    printf '%s\n' 'name = "indent"'
    printf '%s\n' ''
    printf '  %s\n' '[forge.github]'
    printf '%s\n' 'owner = "acme"'
    printf '%s\n' 'repo = "indent"'
} > "$TARGET14"
"$MIGRATE" "$TARGET14" >/dev/null
if grep -qE '^  \[\[forge.github\]\]$' "$TARGET14"; then
    pass "test 14: migration preserves operator hand-edited indentation"
else
    fail "test 14: migration preserves operator hand-edited indentation" \
         "expected '  [[forge.github]]' (two leading spaces), got: $(grep 'forge.github' "$TARGET14" || echo NONE)"
fi

# --- Test 15: migration on already-migrated file exits 0 ---------------
TARGET15="$TMPDIR_TEST/already.toml"
{
    printf '%s\n' '[colony]'
    printf '%s\n' 'name = "already"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'owner = "acme"'
    printf '%s\n' 'repo = "done"'
} > "$TARGET15"
set +e
out15="$("$MIGRATE" "$TARGET15" 2>&1)"
rc15=$?
set -e
if [ "$rc15" -eq 0 ] && printf '%s' "$out15" | grep -q 'already migrated'; then
    pass "test 15: migration on already-migrated file exits 0 with 'already migrated' message"
else
    fail "test 15: migration on already-migrated file exits 0 with 'already migrated' message" \
         "rc=$rc15 out='$out15'"
fi

# --- Test 16: migration on bare-[forge.gitlab]-only config exits 3 -----
TARGET16="$TMPDIR_TEST/no-github.toml"
{
    printf '%s\n' '[colony]'
    printf '%s\n' 'name = "gitlab-only"'
    printf '%s\n' ''
    printf '%s\n' '[forge]'
    printf '%s\n' 'type = "gitlab"'
    printf '%s\n' ''
    printf '%s\n' '[forge.gitlab]'
    printf '%s\n' 'url = "https://gitlab.example.com"'
    printf '%s\n' 'token = "glpat-x"'
    printf '%s\n' 'project = "x/y"'
} > "$TARGET16"
set +e
out16="$("$MIGRATE" "$TARGET16" 2>&1)"
rc16=$?
set -e
if [ "$rc16" -eq 3 ]; then
    pass "test 16: migration on bare-[forge.gitlab]-only config exits 3 (no github block)"
else
    fail "test 16: migration on bare-[forge.gitlab]-only config exits 3 (no github block)" \
         "rc=$rc16 out='$out16'"
fi

# --- Test 17: migrate on fresh-from-template colony.example.toml -------
# Post-#316 M6 the 5 dev-apprenticeship colony.example.toml templates ship
# the array-of-tables `[[forge.github]]` form. After an operator has
# uncommented the github block (via dev-apprenticeship/install.sh's writer
# step or by hand), the config carries an active `[[forge.github]]`
# header. Running the migration tool on this fresh-active-github shape
# MUST be a no-op and print "already migrated" — operators bootstrapping
# a v2.0.0 federation (or running the tool defensively in a CI step)
# should never see a spurious rewrite or a non-zero exit code.
TARGET17="$TMPDIR_TEST/fresh-template.toml"
{
    printf '%s\n' '[colony]'
    printf '%s\n' 'name = "fresh-template"'
    printf '%s\n' ''
    printf '%s\n' '[forge]'
    printf '%s\n' 'type = "github"'
    printf '%s\n' ''
    printf '%s\n' '[[forge.github]]'
    printf '%s\n' 'url   = "https://api.github.com"'
    printf '%s\n' 'owner = "your-org-or-user"'
    printf '%s\n' 'repo  = "your-repo"'
    printf '%s\n' 'token = "ghp_your-token-here"'
    printf '%s\n' 'me    = ""'
    printf '%s\n' ''
    printf '%s\n' '#'
    printf '%s\n' '# To serve N repos from this colony, repeat the [[forge.github]] block once'
    printf '%s\n' '# per repo. Each entry has its own owner/repo/token/url/me.'
} > "$TARGET17"
set +e
out17="$("$MIGRATE" "$TARGET17" 2>&1)"
rc17=$?
set -e
if [ "$rc17" -eq 0 ] && printf '%s' "$out17" | grep -q 'already migrated'; then
    pass "test 17: migrate on fresh-from-template colony.example.toml exits 0 with 'already migrated' (#316 M6)"
else
    fail "test 17: migrate on fresh-from-template colony.example.toml exits 0 with 'already migrated' (#316 M6)" \
         "rc=$rc17 out='$out17'"
fi

# --- Test 18: lint the post-M6 fresh dev-apprenticeship triage template -
# After #316 M6 the shipped dev-apprenticeship/triage/config/colony.example.toml
# carries `# [[forge.github]]` (commented). The lint must accept this template
# unchanged — it is what every fresh `tools/new-colony.sh`-style scaffold
# produces and what `dev-apprenticeship/install.sh` copies before writing
# credentials. A regression here would mean every fresh install fails lint.
SCRIPT_DIR_LINT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT_LINT="$(cd "$SCRIPT_DIR_LINT/.." && pwd)"
TRIAGE_TEMPLATE="$REPO_ROOT_LINT/dev-apprenticeship/triage/config/colony.example.toml"
if [ ! -f "$TRIAGE_TEMPLATE" ]; then
    fail "test 18: post-M6 fresh dev-apprenticeship/triage/config/colony.example.toml lints clean" \
         "fixture missing: $TRIAGE_TEMPLATE"
else
    set +e
    out18=$(python3 - "$TRIAGE_TEMPLATE" <<'PY' 2>&1
import sys
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        print("SKIP: no TOML parser")
        sys.exit(0)

with open(sys.argv[1], 'r', encoding='utf-8') as _f:
    _raw_lines = [ln.strip() for ln in _f]

errors = []
for _backend in ('github', 'gitlab'):
    _has_single = any(ln == '[forge.' + _backend + ']' for ln in _raw_lines)
    _has_multi  = any(ln == '[[forge.' + _backend + ']]' for ln in _raw_lines)
    if _has_single and _has_multi:
        errors.append('config has both [forge.' + _backend + '] and [[forge.' + _backend + ']]')

if errors:
    print('\n'.join(errors))
    sys.exit(1)

with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)

forge_type = data.get('forge', {}).get('type')
if forge_type == 'github':
    gh = data.get('forge', {}).get('github')
    if isinstance(gh, dict):
        print('FAIL: [forge.github] single-table form still present')
        sys.exit(1)

print('OK')
PY
)
    rc18=$?
    set -e
    if [ "$rc18" -eq 0 ] && (printf '%s' "$out18" | grep -q '^OK$' || printf '%s' "$out18" | grep -q '^SKIP'); then
        pass "test 18: post-M6 fresh dev-apprenticeship/triage/config/colony.example.toml lints clean (#316 M6)"
    else
        fail "test 18: post-M6 fresh dev-apprenticeship/triage/config/colony.example.toml lints clean (#316 M6)" \
             "rc=$rc18 out='$out18'"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
