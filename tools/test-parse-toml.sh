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

# --- Test 12: #226 — dotted sub-table header ---
fixture "sub-table" '[planning]
trigger_label = "needs-planning"

[planning.labels]
incident = "incident, bug, blocker"
epic = "epic"

[triage.labels]
priority = "P1, P2, P3, P4"
'
assert_eq "#226: planning.labels.incident" "incident, bug, blocker" "$(parse_toml planning.labels incident)"
assert_eq "#226: planning.labels.epic" "epic" "$(parse_toml planning.labels epic)"
assert_eq "#226: triage.labels.priority" "P1, P2, P3, P4" "$(parse_toml triage.labels priority)"
# Parent section does not leak into sub-table scope and vice versa.
assert_eq "#226: parent planning.trigger_label unaffected" "needs-planning" "$(parse_toml planning trigger_label)"
assert_eq "#226: parent does not see sub-table key" "" "$(parse_toml planning incident)"
assert_eq "#226: sub-table does not see parent key" "" "$(parse_toml planning.labels trigger_label)"

# --- Test 13: #321 — plaintext passthrough still wins (regression) ---
# After the secret-URI dispatch landed, every TOML value goes through
# parse-toml-secret.py before reaching the caller. The passthrough path
# (no `secret://` prefix) MUST stay byte-identical to the legacy heredoc.
fixture "plaintext-321" '[forge.gitlab]
token = "glpat-plain-passthrough-321"
'
assert_eq "#321: plaintext token passes through unchanged" "glpat-plain-passthrough-321" "$(parse_toml forge.gitlab token)"

# --- Test 14: #321 — secret://env/<VAR> resolves to plaintext ---
# Lightest backend to test in CI (no system vault required). Uses the
# secret://env scheme which normalises the existing ${VAR} idiom.
fixture "secret-env-321" '[forge.gitlab]
token = "secret://env/AGENTIS_TEST_TOKEN_321"
'
AGENTIS_TEST_TOKEN_321="ghp_resolved_via_env" \
    assert_eq "#321: secret://env resolves" "ghp_resolved_via_env" "$(AGENTIS_TEST_TOKEN_321=ghp_resolved_via_env parse_toml forge.gitlab token)"

# --- Test 15: #316 M5a — parse_toml_array_get_inline round-trips ---
# Inline table values declared on per-array-entry keys must be readable
# via the new wrapper. Used by start-colony.sh per-repo trigger label
# memo seeding (`labels = { trigger = "..." }`).
fixture "inline-roundtrip" '[forge]
type = "github"

[[forge.github]]
owner = "acme"
repo = "frontend"
token = "x"
labels = { trigger = "needs-triage" }
'
assert_eq "#316 M5a: inline subkey round-trip" "needs-triage" "$(parse_toml_array_get_inline forge.github 0 labels trigger)"

# --- Test 16: #316 M5a — missing inline subkey returns empty ---
# Entry has the `labels` key declared but no `trigger` subkey inside the
# inline table. The parse must collapse to empty stdout (not error out).
fixture "inline-missing-subkey" '[forge]
type = "github"

[[forge.github]]
owner = "acme"
repo = "frontend"
token = "x"
labels = { color = "red" }
'
assert_eq "#316 M5a: missing subkey returns empty" "" "$(parse_toml_array_get_inline forge.github 0 labels trigger)"
# And missing `labels` key entirely also returns empty.
fixture "inline-missing-key" '[forge]
type = "github"

[[forge.github]]
owner = "acme"
repo = "frontend"
token = "x"
'
assert_eq "#316 M5a: missing inline-table key returns empty" "" "$(parse_toml_array_get_inline forge.github 0 labels trigger)"

# --- Test 17: #316 M5a — quoted vs unquoted subkey values ---
# Subkey value strings may carry surrounding double or single quotes; the
# helper strips matching pairs and passes plaintext through unchanged.
fixture "inline-quoted" '[forge]
type = "github"

[[forge.github]]
owner = "acme"
repo = "frontend"
token = "x"
labels = { trigger = "double-quoted-trigger" }

[[forge.github]]
owner = "acme"
repo = "backend"
token = "y"
labels = { trigger = '"'"'single-quoted-trigger'"'"' }
'
assert_eq "#316 M5a: double-quoted subkey value" "double-quoted-trigger" "$(parse_toml_array_get_inline forge.github 0 labels trigger)"
assert_eq "#316 M5a: single-quoted subkey value" "single-quoted-trigger" "$(parse_toml_array_get_inline forge.github 1 labels trigger)"

# --- Test 18: #316 M5a — interior whitespace tolerated ---
# Operators may declare inline tables with extra spaces around `=`, `,`,
# and the surrounding braces. The lookup must tolerate all three patterns.
fixture "inline-spaces" '[forge]
type = "github"

[[forge.github]]
owner = "acme"
repo = "frontend"
token = "x"
labels = {trigger="no-spaces"}

[[forge.github]]
owner = "acme"
repo = "backend"
token = "y"
labels = {   trigger   =   "lots-of-spaces"   ,   color   =   "blue"   }
'
assert_eq "#316 M5a: inline-table no spaces" "no-spaces" "$(parse_toml_array_get_inline forge.github 0 labels trigger)"
assert_eq "#316 M5a: inline-table extra spaces around tokens" "lots-of-spaces" "$(parse_toml_array_get_inline forge.github 1 labels trigger)"
assert_eq "#316 M5a: inline-table second subkey tolerates spaces" "blue" "$(parse_toml_array_get_inline forge.github 1 labels color)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
