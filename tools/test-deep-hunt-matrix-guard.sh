#!/usr/bin/env bash
# tools/test-deep-hunt-matrix-guard.sh -- deterministic regression guard for #1936 (dark-factory).
#
# The STAGE 4.5 deep-hunt records each hunted zone's verdict into the lens-surface matrix via
# `"$LENSMATRIX" set --surface "$ZID" ...`. That matrix only tracks custody/composition SURFACES
# (lens-surface-matrix.py's is_surface), so a NON-custody zone (which the deep-hunt also targets since
# #1790) hits `die(2, "surface not in the matrix")`. Under run-zone-hunt.sh's `set -e`, an UNGUARDED
# `set` call there aborted the WHOLE deep-hunt loop -- every later zone lost. The fix guards both
# `set` call sites so a non-surface record is skipped (logged) and the loop continues.
#
# Pure bash/grep over the runner + one behavioral probe of the matrix helper -- no agentis runtime,
# no LLM, no forge. Auto-discovered by tools/colony-lint.sh's tools/test-*.sh loop.
#
# Assertions:
#   (a) BOTH `"$LENSMATRIX" set --file "$MATRIX_JSON" --surface "$ZID"` call sites are GUARDED
#       (`if ! "$LENSMATRIX" set ...`), never a bare unguarded invocation that `set -e` would abort on.
#   (b) The guard logs a skip note referencing #1936 and continues.
#   (c) Load-bearing check: lens-surface-matrix.py `set` on an unknown surface still exits NON-ZERO
#       (so the guard is genuinely what prevents the abort, not a silently-succeeding call).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$REPO_ROOT/dark-factory/run-zone-hunt.sh"
MATRIX="$REPO_ROOT/dark-factory/lib/lens-surface-matrix.py"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }
summary_exit() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
}

[ -f "$RUNNER" ] || { fail "runner exists" "$RUNNER not found"; summary_exit; }
[ -f "$MATRIX" ] || { fail "matrix helper exists" "$MATRIX not found"; summary_exit; }

run_src="$(cat "$RUNNER")"

# (a) both set call sites guarded with `if ! "$LENSMATRIX" set ... --surface "$ZID"`
# shellcheck disable=SC2016  # matching the literal source line; $vars must NOT expand
guarded="$(printf '%s\n' "$run_src" | grep -Fc 'if ! "$LENSMATRIX" set --file "$MATRIX_JSON" --surface "$ZID"' || true)"
if [ "${guarded:-0}" -ge 2 ]; then
    pass "(a) both lens-surface-matrix 'set' call sites are guarded (if ! ...) -- found $guarded"
else
    fail "(a) both matrix 'set' calls guarded" "expected >=2 'if ! \"\$LENSMATRIX\" set ... --surface \"\$ZID\"', found ${guarded:-0}"
fi

# no BARE (unguarded, start-of-statement) `"$LENSMATRIX" set` may remain -- a line whose first token is
# the invocation (not preceded by `if ! `) is exactly the pre-fix abort hazard.
# shellcheck disable=SC2016  # matching the literal source line; $LENSMATRIX must NOT expand
bare="$(printf '%s\n' "$run_src" | grep -nE '^[[:space:]]*"\$LENSMATRIX" set ' || true)"
if [ -z "$bare" ]; then
    pass "(a2) no bare/unguarded '\"\$LENSMATRIX\" set' invocation remains"
else
    fail "(a2) no bare matrix 'set'" "found unguarded invocation(s): $bare"
fi

# (b) guard logs a #1936 skip note and continues
if printf '%s\n' "$run_src" | grep -Fq 'matrix record skipped for zone' \
   && printf '%s\n' "$run_src" | grep -Fq '#1936'; then
    pass "(b) guard logs a #1936 'matrix record skipped' note and continues"
else
    fail "(b) guard logs a skip note" "missing 'matrix record skipped for zone' / '#1936' note"
fi

# (c) load-bearing: matrix.py `set` on an unknown surface still exits non-zero
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
MJSON="$TMPD/matrix.json"
# minimal well-formed matrix with a single KNOWN surface, no unknown one
cat > "$MJSON" <<'JSON'
{
  "surfaces": [
    { "id": "known_surface", "verdict": "", "lens_depth": "narrow-per-class" }
  ],
  "totals": {}
}
JSON
set +e
python3 "$MATRIX" set --file "$MJSON" --surface "definitely_not_a_surface" --lens-depth narrow-per-class >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    pass "(c) lens-surface-matrix.py 'set' on an unknown surface exits non-zero (rc=$rc) -- guard is load-bearing"
else
    fail "(c) matrix 'set' unknown-surface non-zero" "expected non-zero exit, got 0 (guard would be a no-op)"
fi

summary_exit
