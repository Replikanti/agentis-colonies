#!/bin/bash
# tools/test-parse-toml.sh: unit tests for tools/parse-toml.sh.
#
# Self-contained. Creates temporary fixture files, sources parse-toml.sh,
# asserts each function behavior, cleans up on exit.
#
# Usage: ./tools/test-parse-toml.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=parse-toml.sh
# shellcheck disable=SC1091  # colony-lint runs shellcheck without -x
. "$SCRIPT_DIR/parse-toml.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: expected <$2>, got <$3>"; FAIL=$((FAIL + 1)); }

fixture() {
    local name="$1"
    local content="$2"
    CONFIG="$TMPDIR_TEST/$name.toml"
    printf '%s' "$content" > "$CONFIG"
    export CONFIG
}

assert_eq() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "$name" "$expected" "$actual"
    fi
}

# --- Test 1: regression — plain key/value still works ---
fixture "regression" '[gitlab]
url = "https://gitlab.example.com"
token = "glpat-plain"
project = "my-org/my-proj"
'
assert_eq "regression: url" "https://gitlab.example.com" "$(parse_toml gitlab url)"
assert_eq "regression: token" "glpat-plain" "$(parse_toml gitlab token)"
assert_eq "regression: project" "my-org/my-proj" "$(parse_toml gitlab project)"

# --- Test 2: #26 — `#` inside quoted value is preserved ---
fixture "hash-in-value" '[gitlab]
token = "glpat-abc#def"
project = "foo#bar/baz"
'
assert_eq "#26: hash in token" "glpat-abc#def" "$(parse_toml gitlab token)"
assert_eq "#26: hash in project" "foo#bar/baz" "$(parse_toml gitlab project)"

# --- Test 3: #26 — inline comment still stripped when value has no `#` ---
fixture "inline-comment" '[gitlab]
url = "https://example.com" # inline comment here
token = "abc#def" # comment after quoted hash
'
assert_eq "#26: inline comment stripped" "https://example.com" "$(parse_toml gitlab url)"
assert_eq "#26: inline comment after quoted hash" "abc#def" "$(parse_toml gitlab token)"

# --- Test 4: #32 — section header with interior whitespace ---
fixture "spaced-section" '[ gitlab ]
url = "https://spaced.example.com"
[  llm  ]
backend = "cli"
'
assert_eq "#32: spaced [ gitlab ]" "https://spaced.example.com" "$(parse_toml gitlab url)"
assert_eq "#32: double-spaced [  llm  ]" "cli" "$(parse_toml llm backend)"

# --- Test 5: #33 — missing KEY argument fails loudly ---
fixture "any" '[gitlab]
url = "x"
'
# Disable set -e for the failing-call check so the whole script does not abort.
set +e
out="$(parse_toml gitlab 2>&1 >/dev/null)"
rc=$?
set -e
if [ "$rc" -eq 2 ] && [ -n "$out" ]; then
    pass "#33: missing KEY exits 2 with stderr message"
else
    fail "#33: missing KEY" "rc=2 + stderr msg" "rc=$rc out=$out"
fi

# Zero-arg call must also fail loudly.
set +e
out="$(parse_toml 2>&1 >/dev/null)"
rc=$?
set -e
if [ "$rc" -eq 2 ] && [ -n "$out" ]; then
    pass "#33: zero args exits 2 with stderr message"
else
    fail "#33: zero args" "rc=2 + stderr msg" "rc=$rc out=$out"
fi

# Also verify the too-many-args path.
set +e
out="$(parse_toml gitlab url extra 2>&1 >/dev/null)"
rc=$?
set -e
if [ "$rc" -eq 2 ] && [ -n "$out" ]; then
    pass "#33: extra args exits 2 with stderr message"
else
    fail "#33: extra args" "rc=2 + stderr msg" "rc=$rc out=$out"
fi

# --- Test 6: combined — all four fixes active on one multi-section fixture ---
fixture "combined" '# top-of-file comment
[ gitlab ]
url = "https://combo.example.com" # trailing
token = "glpat-has#hash"
project = "my-org/my-proj"

[llm]
backend = "cli"
'
assert_eq "combined: url (spaced section + trailing comment)" "https://combo.example.com" "$(parse_toml gitlab url)"
assert_eq "combined: token (hash in value)" "glpat-has#hash" "$(parse_toml gitlab token)"
assert_eq "combined: project" "my-org/my-proj" "$(parse_toml gitlab project)"
assert_eq "combined: backend (different section)" "cli" "$(parse_toml llm backend)"

# --- Test 7: regression — unknown section returns empty ---
fixture "unknown" '[gitlab]
url = "x"
'
assert_eq "regression: unknown section" "" "$(parse_toml nope url)"
assert_eq "regression: unknown key" "" "$(parse_toml gitlab nope)"

# --- Test 8: single-quoted values — `#` inside `'...'` is preserved ---
fixture "single-quoted" "[gitlab]
token = 'glpat-single#quoted'
project = 'org/proj'
"
assert_eq "#26: single-quoted hash preserved" "glpat-single#quoted" "$(parse_toml gitlab token)"
assert_eq "#26: single-quoted plain" "org/proj" "$(parse_toml gitlab project)"

# --- Test 9: tab-separated section brackets ---
printf '[\tgitlab\t]\nurl = "https://tabbed.example.com"\n' > "$TMPDIR_TEST/tabbed.toml"
CONFIG="$TMPDIR_TEST/tabbed.toml"
export CONFIG
assert_eq "#32: tab-padded section header" "https://tabbed.example.com" "$(parse_toml gitlab url)"

# --- Test 10: empty value ---
fixture "empty-value" '[gitlab]
url = ""
token = "non-empty"
'
assert_eq "empty quoted value returns empty" "" "$(parse_toml gitlab url)"
assert_eq "empty value does not break next key" "non-empty" "$(parse_toml gitlab token)"

# --- Test 11: same-name key in sibling section is ignored ---
fixture "sibling-same-name" '[gitlab]
url = "gitlab-url"

[llm]
url = "llm-url"
'
assert_eq "gitlab.url resolves to gitlab section" "gitlab-url" "$(parse_toml gitlab url)"
assert_eq "llm.url resolves to llm section" "llm-url" "$(parse_toml llm url)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
