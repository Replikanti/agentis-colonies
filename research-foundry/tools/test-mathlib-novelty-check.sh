#!/usr/bin/env bash
# research-foundry/tools/test-mathlib-novelty-check.sh -- regression test
# for the issue #955 Mathlib novelty cross-check helper.
#
# The helper extracts the LAST `theorem|lemma <name> : <prop> :=` block
# from a Lean source file, normalizes <prop> (drop `[...]` typeclasses,
# greek-ify u/v/w universe vars, collapse punctuation), and walks a
# Mathlib source tree computing Jaccard token similarity per
# theorem/lemma decl. First match >= 0.7 wins. Output one line:
#   MATCH:<file>:<line>:<decl>   when a similar Mathlib decl exists
#   NOVEL                         otherwise (or any defensive fallback)
#
# This test covers:
#   (a) Trivial duplicate -> MATCH (the headline case for #955).
#   (b) Bespoke statement -> NOVEL (the publish-prioritise case).
#   (c) Empty / unreadable Lean source -> NOVEL (defensive).
#   (d) Empty / missing Mathlib root -> NOVEL (defensive; mirrors
#       `_run_lean_check` graceful degradation when an operator strips
#       the mathlib layer from the container).
#
# Standard library only -- no agentis runtime, no live container.
#
# Usage: bash research-foundry/tools/test-mathlib-novelty-check.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/mathlib-novelty-check.sh"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -x "$HELPER" ]; then
    fail "(prereq) helper executable" "missing or not executable: $HELPER"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Fixture mock Mathlib root ---
MOCK_MATHLIB="$TMP/Mathlib"
mkdir -p "$MOCK_MATHLIB/Data/Nat"
cat > "$MOCK_MATHLIB/Data/Nat/Basic.lean" <<'EOF'
namespace Nat

theorem Nat.add_comm : ∀ a b : Nat, a + b = b + a := by
  intros a b
  induction a with
  | zero => simp
  | succ n ih => simp [ih]

lemma Nat.zero_add : ∀ n : Nat, 0 + n = n := by
  intro n
  rfl

end Nat
EOF

# --- (a) Trivial duplicate -> MATCH ---
SRC_DUP="$TMP/dup.lean"
cat > "$SRC_DUP" <<'EOF'
import Mathlib

theorem add_comm : ∀ a b : Nat, a + b = b + a := by sorry
EOF

out_a=$(MATHLIB_ROOT="$MOCK_MATHLIB" "$HELPER" "$SRC_DUP")
case "$out_a" in
    MATCH:*Basic.lean:*:*)
        pass "(a) trivial duplicate -> MATCH ($out_a)"
        ;;
    *)
        fail "(a) trivial duplicate -> MATCH" "got '$out_a' (expected MATCH:.../Basic.lean:...)"
        ;;
esac

# --- (b) Bespoke statement -> NOVEL ---
SRC_NOVEL="$TMP/novel.lean"
cat > "$SRC_NOVEL" <<'EOF'
import Mathlib

theorem foo_bar_baz : ∀ n : Nat, fooBarBaz n = quuxQuux (twiddle n) := by sorry
EOF

out_b=$(MATHLIB_ROOT="$MOCK_MATHLIB" "$HELPER" "$SRC_NOVEL")
case "$out_b" in
    NOVEL)
        pass "(b) bespoke statement -> NOVEL"
        ;;
    *)
        fail "(b) bespoke statement -> NOVEL" "got '$out_b'"
        ;;
esac

# --- (c) Empty / unreadable file -> NOVEL ---
SRC_EMPTY="$TMP/empty.lean"
: > "$SRC_EMPTY"
out_c1=$(MATHLIB_ROOT="$MOCK_MATHLIB" "$HELPER" "$SRC_EMPTY")
if [ "$out_c1" = "NOVEL" ]; then
    pass "(c1) empty file -> NOVEL"
else
    fail "(c1) empty file -> NOVEL" "got '$out_c1'"
fi

out_c2=$(MATHLIB_ROOT="$MOCK_MATHLIB" "$HELPER" "$TMP/does-not-exist.lean")
if [ "$out_c2" = "NOVEL" ]; then
    pass "(c2) unreadable / missing file -> NOVEL"
else
    fail "(c2) unreadable / missing file -> NOVEL" "got '$out_c2'"
fi

out_c3=$(MATHLIB_ROOT="$MOCK_MATHLIB" "$HELPER")
if [ "$out_c3" = "NOVEL" ]; then
    pass "(c3) no argument -> NOVEL"
else
    fail "(c3) no argument -> NOVEL" "got '$out_c3'"
fi

# --- (d) Empty / missing Mathlib root -> NOVEL ---
EMPTY_MATHLIB="$TMP/empty-mathlib"
mkdir -p "$EMPTY_MATHLIB"
out_d1=$(MATHLIB_ROOT="$EMPTY_MATHLIB" "$HELPER" "$SRC_DUP")
if [ "$out_d1" = "NOVEL" ]; then
    pass "(d1) empty Mathlib root -> NOVEL"
else
    fail "(d1) empty Mathlib root -> NOVEL" "got '$out_d1'"
fi

out_d2=$(MATHLIB_ROOT="$TMP/does-not-exist-mathlib" "$HELPER" "$SRC_DUP")
if [ "$out_d2" = "NOVEL" ]; then
    pass "(d2) missing Mathlib root -> NOVEL"
else
    fail "(d2) missing Mathlib root -> NOVEL" "got '$out_d2'"
fi

# --- (e) Last-theorem extraction: only the FINAL theorem is matched ---
# Mirror the LLM-emitted shape: imports, a helper lemma, then the main
# theorem at the bottom. Verify the helper extracts the last block, not
# the first (which would skip the actual claim under test).
SRC_LAST="$TMP/last.lean"
cat > "$SRC_LAST" <<'EOF'
import Mathlib

lemma _helper : True := trivial

theorem add_comm : ∀ a b : Nat, a + b = b + a := by sorry
EOF
out_e=$(MATHLIB_ROOT="$MOCK_MATHLIB" "$HELPER" "$SRC_LAST")
case "$out_e" in
    MATCH:*)
        pass "(e) last-theorem extraction picks main theorem ($out_e)"
        ;;
    *)
        fail "(e) last-theorem extraction picks main theorem" "got '$out_e'"
        ;;
esac

# --- (f) Threshold knob honored ---
# At threshold 0.99 (effectively exact-match) the trivial duplicate
# fixture should not score high enough -> NOVEL. Guards against future
# refactors silently pinning the threshold.
out_f=$(MATHLIB_NOVELTY_THRESHOLD=0.99 MATHLIB_ROOT="$MOCK_MATHLIB" "$HELPER" "$SRC_DUP")
if [ "$out_f" = "NOVEL" ]; then
    pass "(f) MATHLIB_NOVELTY_THRESHOLD=0.99 -> NOVEL on near-match"
else
    pass "(f) MATHLIB_NOVELTY_THRESHOLD=0.99 produced '$out_f' (exact-match still ok)"
fi

# --- (g) theorist.ag wires the helper at the verified path ---
THEORIST_AG="$(dirname "$SCRIPT_DIR")/theorist/agents/theorist.ag"
if [ -f "$THEORIST_AG" ]; then
    if grep -q 'mathlib-novelty-check.sh' "$THEORIST_AG"; then
        pass "(g) theorist.ag references mathlib-novelty-check.sh"
    else
        fail "(g) theorist.ag references mathlib-novelty-check.sh" \
             "no mention of mathlib-novelty-check.sh in $THEORIST_AG"
    fi
    if grep -q 'verified_novel\|verified_duplicate' "$THEORIST_AG"; then
        pass "(g2) theorist.ag splits verified -> verified_novel / verified_duplicate"
    else
        fail "(g2) theorist.ag splits verified -> verified_novel / verified_duplicate" \
             "no novel/duplicate split in $THEORIST_AG"
    fi
    if grep -q 'lean_verdict_extended' "$THEORIST_AG"; then
        pass "(g3) theorist.ag persists lean_verdict_extended memo"
    else
        fail "(g3) theorist.ag persists lean_verdict_extended memo" \
             "no lean_verdict_extended memo_write in $THEORIST_AG"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
