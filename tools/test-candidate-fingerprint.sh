#!/bin/bash
# tools/test-candidate-fingerprint.sh: unit test for
# tools/lib/candidate-fingerprint.sh (M2 of #1266). Covers the stable dedup
# key the issue_creator gate consumes:
#
#   1. Stability    — same (source, location, title) twice → identical hash.
#   2. Sensitivity  — changing source, location, or title each changes it.
#   3. Normalization — extra/leading/trailing whitespace, internal whitespace
#      runs (incl. tabs/newlines), and case differences in the title all
#      fingerprint the same.
#   4. Output shape — exactly 12 lowercase hex characters.
#
# Dependency-free: only bash + the sha256 tool the lib itself needs (no
# agentis binary, no python3), so it runs on the CI runners unchanged.
#
# Usage: ./tools/test-candidate-fingerprint.sh
# Exit 0 on full pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/candidate-fingerprint.sh"

# --- 1. Stability: identical inputs yield identical output. ---
a="$(candidate_fingerprint "router" "src/foo.rs:42" "Null deref in parser")"
b="$(candidate_fingerprint "router" "src/foo.rs:42" "Null deref in parser")"
if [ "$a" = "$b" ]; then
    pass "1: stable — same inputs twice produce the same fingerprint ($a)"
else
    fail "1: stability" "$a != $b"
fi

# --- 2. Sensitivity: changing each field in turn changes the hash. ---
base="$(candidate_fingerprint "router" "src/foo.rs:42" "Null deref in parser")"
diff_src="$(candidate_fingerprint "labeler" "src/foo.rs:42" "Null deref in parser")"
diff_loc="$(candidate_fingerprint "router" "src/foo.rs:43" "Null deref in parser")"
diff_title="$(candidate_fingerprint "router" "src/foo.rs:42" "Use-after-free in parser")"
if [ "$base" != "$diff_src" ] && [ "$base" != "$diff_loc" ] && [ "$base" != "$diff_title" ]; then
    pass "2: sensitive — changing source, location, or title each changes the fingerprint"
else
    fail "2: sensitivity" "src=$diff_src loc=$diff_loc title=$diff_title vs base=$base"
fi

# --- 3. Normalization: whitespace + case variants of the title collapse. ---
canon="$(candidate_fingerprint "router" "src/foo.rs:42" "Null deref in parser")"
spaced="$(candidate_fingerprint "router" "src/foo.rs:42" "  Null   deref  in parser  ")"
cased="$(candidate_fingerprint "router" "src/foo.rs:42" "NULL DEREF IN PARSER")"
tabbed="$(candidate_fingerprint "router" "src/foo.rs:42" "$(printf 'Null\tderef\nin   parser')")"
if [ "$canon" = "$spaced" ] && [ "$canon" = "$cased" ] && [ "$canon" = "$tabbed" ]; then
    pass "3: normalized — extra/leading/trailing/internal whitespace + case fold to one key"
else
    fail "3: normalization" "canon=$canon spaced=$spaced cased=$cased tabbed=$tabbed"
fi

# --- 4. A genuinely different title must NOT collide after normalization. ---
other="$(candidate_fingerprint "router" "src/foo.rs:42" "null   deref  in lexer")"
if [ "$canon" != "$other" ]; then
    pass "4: normalization is not lossy — a different title stays distinct"
else
    fail "4: normalization over-collapse" "canon=$canon == other=$other"
fi

# --- 5. Output shape: exactly 12 lowercase hex characters. ---
shape="$(candidate_fingerprint "router" "src/foo.rs:42" "Null deref in parser")"
if printf '%s' "$shape" | grep -Eq '^[0-9a-f]{12}$'; then
    pass "5: output is exactly 12 lowercase hex chars ($shape)"
else
    fail "5: output shape" "got '$shape'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
