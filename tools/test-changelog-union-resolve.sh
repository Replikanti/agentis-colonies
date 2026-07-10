#!/usr/bin/env bash
# test-changelog-union-resolve.sh (#1518): unit tests for the deterministic
# CHANGELOG [Unreleased] union-merge helper (tools/changelog-union-resolve.py).
# NO git, NO network — pure fixture-in / exit-code + content-out assertions.
#
# The helper resolves exactly ONE conflict class: two-sided additive bullet
# inserts under `## [Unreleased]`. Everything else fail-closes (exit 3), a parse
# error is exit 2, a clean resolve is exit 0. During a `git rebase origin/<def>`,
# the `<<<<<<< HEAD` side is the DEFAULT-BRANCH content and the `>>>>>>>` side is
# OUR commit, so the union keeps HEAD (main) bullets FIRST.
#
# Asserts:
#   U1. two-sided [Unreleased] insert union-merges, main bullet first, markers gone (exit 0)
#   U2. conflict touching a RELEASED `## [x.y.z]` heading is NOT auto-resolved (exit 3)
#   U3. a conflict hunk whose side carries a `## [` version heading is NOT resolved (exit 3)
#   U4. a non-additive (prose) side is NOT auto-resolved (exit 3)
#   U5. a non-CHANGELOG.md basename is NOT auto-resolved (exit 3)
#   U6. no `## [Unreleased]` heading -> guard fail (exit 3)
#   U7. a file with no conflict markers -> parse error (exit 2)
#   U8. wrong argv count -> usage error (exit 2)
#   U9. zdiff3 hunk with a NON-EMPTY base region (a side edited/deleted a base
#       bullet — both sides still bullet-shaped) is NOT unioned (exit 3). This is
#       the adversarial-review corruption case: line shape is not additivity.
#   U10. zdiff3 hunk with an EMPTY base region (pure two-sided add) still unions (exit 0)
#
# Auto-discovered by tools/colony-lint.sh's tools-test loop. Exit 0 if all pass.
set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
RESOLVER="$REPO_ROOT/tools/changelog-union-resolve.py"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] test-changelog-union-resolve.sh: python3 not on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi
if [ ! -f "$RESOLVER" ]; then
    fail "resolver missing" "$RESOLVER"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run_resolver() {
    # $1 = file path; sets RC (exit code)
    python3 "$RESOLVER" "$1" >"$WORK/out.txt" 2>"$WORK/err.txt"
    RC=$?
}

# ---------------------------------------------------------------------------
# U1: two-sided [Unreleased] insert union-merges (exit 0), main bullet first,
# both bullets kept, all three conflict markers dropped.
# ---------------------------------------------------------------------------
F1="$WORK/CHANGELOG.md"
cat > "$F1" <<'EOF'
# Changelog

## [Unreleased]
<<<<<<< HEAD
- Main landed feature X
=======
- Our added feature Y
>>>>>>> our-commit

## [1.0.0] - 2024-01-01
- Initial release
EOF
run_resolver "$F1"
if [ "$RC" -eq 0 ]; then
    pass "U1: two-sided Unreleased insert resolves (exit 0)"
else
    fail "U1: exit 0" "rc=$RC err=$(cat "$WORK/err.txt")"
fi
if ! grep -qE '^(<<<<<<<|=======|>>>>>>>)' "$F1"; then
    pass "U1: all conflict markers removed"
else
    fail "U1: markers must be gone" "$(cat "$F1")"
fi
if grep -q '^- Main landed feature X$' "$F1" && grep -q '^- Our added feature Y$' "$F1"; then
    pass "U1: both bullets kept (union)"
else
    fail "U1: both bullets kept" "$(cat "$F1")"
fi
# Order: HEAD (main) bullet must come BEFORE ours.
MAIN_LN="$(grep -n '^- Main landed feature X$' "$F1" | head -1 | cut -d: -f1)"
OUR_LN="$(grep -n '^- Our added feature Y$' "$F1" | head -1 | cut -d: -f1)"
if [ -n "$MAIN_LN" ] && [ -n "$OUR_LN" ] && [ "$MAIN_LN" -lt "$OUR_LN" ]; then
    pass "U1: HEAD (main) bullet ordered before ours"
else
    fail "U1: main-first order" "main=$MAIN_LN our=$OUR_LN"
fi
# The released section is untouched.
if grep -q '^- Initial release$' "$F1"; then
    pass "U1: released section preserved untouched"
else
    fail "U1: released section preserved" "$(cat "$F1")"
fi

# ---------------------------------------------------------------------------
# U2: a conflict INSIDE a released section (not [Unreleased]) is NOT resolved.
# ---------------------------------------------------------------------------
F2="$WORK/CHANGELOG.md"
cat > "$F2" <<'EOF'
# Changelog

## [Unreleased]
- An untouched unreleased bullet

## [1.0.0] - 2024-01-01
<<<<<<< HEAD
- Main rewrote a released bullet
=======
- Our rewrote a released bullet
>>>>>>> our-commit
EOF
run_resolver "$F2"
if [ "$RC" -eq 3 ]; then
    pass "U2: released-section conflict refused (exit 3, containment guard)"
else
    fail "U2: exit 3" "rc=$RC out=$(cat "$WORK/out.txt") err=$(cat "$WORK/err.txt")"
fi
if grep -qE '^(<<<<<<<|=======|>>>>>>>)' "$F2"; then
    pass "U2: file left untouched (markers still present)"
else
    fail "U2: file must be left untouched"
fi

# ---------------------------------------------------------------------------
# U3: a hunk whose side introduces a `## [x.y.z]` heading breaks containment.
# ---------------------------------------------------------------------------
F3="$WORK/CHANGELOG.md"
cat > "$F3" <<'EOF'
# Changelog

## [Unreleased]
<<<<<<< HEAD
- Main unreleased bullet
=======
- Our unreleased bullet

## [2.0.0] - 2024-02-01
- Our released bullet
>>>>>>> our-commit
EOF
run_resolver "$F3"
if [ "$RC" -eq 3 ]; then
    pass "U3: hunk carrying a version heading refused (exit 3)"
else
    fail "U3: exit 3" "rc=$RC err=$(cat "$WORK/err.txt")"
fi

# ---------------------------------------------------------------------------
# U4: a non-additive (prose, non-bullet) side is NOT auto-resolved.
# ---------------------------------------------------------------------------
F4="$WORK/CHANGELOG.md"
cat > "$F4" <<'EOF'
# Changelog

## [Unreleased]
<<<<<<< HEAD
- Main bullet
=======
This line is prose, not a bullet.
>>>>>>> our-commit

## [1.0.0] - 2024-01-01
- Initial
EOF
run_resolver "$F4"
if [ "$RC" -eq 3 ]; then
    pass "U4: non-additive side refused (exit 3)"
else
    fail "U4: exit 3" "rc=$RC err=$(cat "$WORK/err.txt")"
fi

# ---------------------------------------------------------------------------
# U5: a non-CHANGELOG.md basename is refused even with a perfect union shape.
# ---------------------------------------------------------------------------
F5="$WORK/NOTES.md"
cat > "$F5" <<'EOF'
## [Unreleased]
<<<<<<< HEAD
- Main bullet
=======
- Our bullet
>>>>>>> our-commit
EOF
run_resolver "$F5"
if [ "$RC" -eq 3 ]; then
    pass "U5: non-CHANGELOG.md basename refused (exit 3)"
else
    fail "U5: exit 3" "rc=$RC err=$(cat "$WORK/err.txt")"
fi

# ---------------------------------------------------------------------------
# U6: no [Unreleased] heading -> guard fail (exit 3).
# ---------------------------------------------------------------------------
F6="$WORK/CHANGELOG.md"
cat > "$F6" <<'EOF'
# Changelog

## [1.0.0] - 2024-01-01
<<<<<<< HEAD
- Main bullet
=======
- Our bullet
>>>>>>> our-commit
EOF
run_resolver "$F6"
if [ "$RC" -eq 3 ]; then
    pass "U6: missing [Unreleased] heading refused (exit 3)"
else
    fail "U6: exit 3" "rc=$RC err=$(cat "$WORK/err.txt")"
fi

# ---------------------------------------------------------------------------
# U7: no conflict markers at all -> parse error (exit 2).
# ---------------------------------------------------------------------------
F7="$WORK/CHANGELOG.md"
cat > "$F7" <<'EOF'
# Changelog

## [Unreleased]
- A bullet, no conflict here
EOF
run_resolver "$F7"
if [ "$RC" -eq 2 ]; then
    pass "U7: no conflict markers -> parse error (exit 2)"
else
    fail "U7: exit 2" "rc=$RC err=$(cat "$WORK/err.txt")"
fi

# ---------------------------------------------------------------------------
# U8: wrong argv count -> usage error (exit 2).
# ---------------------------------------------------------------------------
python3 "$RESOLVER" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then
    pass "U8: no argument -> usage error (exit 2)"
else
    fail "U8: exit 2 on no arg"
fi

# ---------------------------------------------------------------------------
# U9: zdiff3 hunk with a NON-EMPTY base region — one side edited a base bullet
# and deleted another; BOTH sides are still all-`- `-bullet-shaped, so the old
# shape-only guard would have unioned (resurrecting the deleted bullet +
# duplicating the edited one — a valid-markdown CORRUPTED CHANGELOG). The base
# region makes the non-additivity visible -> REFUSE (exit 3).
# ---------------------------------------------------------------------------
F9="$WORK/CHANGELOG.md"
cat > "$F9" <<'EOF'
# Changelog

## [Unreleased]
<<<<<<< HEAD
- alpha main-edit
- beta
||||||| parent of abc123 (ours)
- alpha
- beta
=======
- alpha our-edit
>>>>>>> abc123 (ours)
- gamma

## [1.0.0] - 2024-01-01
- Initial
EOF
run_resolver "$F9"
if [ "$RC" -eq 3 ]; then
    pass "U9: non-empty zdiff3 base (edit/delete of a base bullet) refused (exit 3)"
else
    fail "U9: exit 3" "rc=$RC out=$(cat "$WORK/out.txt") err=$(cat "$WORK/err.txt")"
fi
if grep -qE '^(<<<<<<<|\|\|\|\|\|\|\||=======|>>>>>>>)' "$F9"; then
    pass "U9: file left untouched (markers still present, no corrupting union)"
else
    fail "U9: file must be left untouched"
fi

# ---------------------------------------------------------------------------
# U10: zdiff3 hunk with an EMPTY base region (pure two-sided add — nothing
# pre-existed at the conflict point) still unions, main bullet first (exit 0).
# ---------------------------------------------------------------------------
F10="$WORK/CHANGELOG.md"
cat > "$F10" <<'EOF'
# Changelog

## [Unreleased]
<<<<<<< HEAD
- Main bullet X
||||||| parent of def456 (ours)
=======
- Our bullet Y
>>>>>>> def456 (ours)

## [1.0.0] - 2024-01-01
- Initial
EOF
run_resolver "$F10"
if [ "$RC" -eq 0 ]; then
    pass "U10: empty zdiff3 base (pure two-sided add) unions (exit 0)"
else
    fail "U10: exit 0" "rc=$RC err=$(cat "$WORK/err.txt")"
fi
if grep -q '^- Main bullet X$' "$F10" && grep -q '^- Our bullet Y$' "$F10" \
   && ! grep -qE '^(<<<<<<<|\|\|\|\|\|\|\||=======|>>>>>>>)' "$F10"; then
    pass "U10: both bullets kept, all markers (incl. base) dropped"
else
    fail "U10: union output" "$(cat "$F10")"
fi
M10="$(grep -n '^- Main bullet X$' "$F10" | head -1 | cut -d: -f1)"
O10="$(grep -n '^- Our bullet Y$' "$F10" | head -1 | cut -d: -f1)"
if [ -n "$M10" ] && [ -n "$O10" ] && [ "$M10" -lt "$O10" ]; then
    pass "U10: HEAD (main) bullet ordered before ours"
else
    fail "U10: main-first order" "main=$M10 our=$O10"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
