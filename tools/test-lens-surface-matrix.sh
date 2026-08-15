#!/usr/bin/env bash
# tools/test-lens-surface-matrix.sh -- deterministic offline guard for #1914 M3
# (dark-factory): the LENS x SURFACE COVERAGE MATRIX.
#
# STAGE 4.5 of run-zone-hunt.sh now emits `<out>/coverage/lens-surface-matrix.json`
# (schema `lens-surface-matrix/v1`, owned by dark-factory/lib/lens-surface-matrix.py):
# one entry per custody/composition surface recording the DEEPEST lens that reached it
# and -- for the class-agnostic SYS-solvency (general) lens -- that lens's raw verdict.
# The whole point is that HARNESS_ERROR (a harness that failed to compile/generate -- an
# UN-PROBED seam) is recorded DISTINCT from CLEAN (a real negative): the #1780 merge
# adapter collapses both into one no-op branch, so without this record they are lost
# together.
#
# Offline by construction: the pipeline is driven through the --map-fixture /
# --brief-fixture / --pass-fixture / --invariant-fixture seams plus the ONE --agentis
# stub the #1713 deep-hunt fixture ships. That stub PARAMETRIZES the invariant verdict
# via DEEP_HUNT_VERDICT (#1774) -- FINDING (default), CLEAN, or HARNESS_ERROR -- which is
# exactly the offline seam this test forces each verdict through: the stub emits
# `INVARIANT|<target>|<verdict>`, run-zone-hunt.sh reads that raw verdict itself, and the
# matrix records it. No LLM, no forge, no network. Auto-discovered by colony-lint.sh.
#
# The #1713 fixture's custody zone holds a SINGLE .sol, which cannot carry a co-system
# aux, so this test builds a throwaway target from that fixture plus one extra co-system
# contract in the SAME zone directory (map-zones groups per directory). The shipped
# fixture is consumed READ-ONLY.
#
# Assertions:
#   (a) A --composable-lens deep-hunt run emits lens-surface-matrix.json (schema
#       lens-surface-matrix/v1) listing the custody surface with a lens-depth + verdict.
#   (b) A SYS-solvency HARNESS_ERROR surface reads as an explicit GAP (in
#       harness_error_surfaces), DISTINCT from a SYS-solvency CLEAN surface -- the two do
#       NOT collapse to one state.
#   (c) With --composable-lens OFF the custody surface -- which only saw its per-class
#       (C6) lens -- reads `narrow-per-class`.
#   (d) With --composable-lens OFF the matrix contains only narrow-per-class/discovery-only
#       rows and NO general-solvency rows.
#
# Usage: bash tools/test-lens-surface-matrix.sh
# Exit: 0 = held, 1 = regressed, 3 = missing prerequisite.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZONEHUNT="$REPO_ROOT/dark-factory/run-zone-hunt.sh"
LENSMATRIX="$REPO_ROOT/dark-factory/lib/lens-surface-matrix.py"
FIX="$REPO_ROOT/dark-factory/bench/corpus-bench/fixtures/deep-hunt"

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

[ -x "$ZONEHUNT" ] || { echo "[SKIP] run-zone-hunt.sh not found/executable: $ZONEHUNT" >&2; exit 3; }
[ -f "$LENSMATRIX" ] || { echo "[SKIP] lens-surface-matrix.py not found: $LENSMATRIX" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
for f in foundry.toml zones.fixture.txt briefs.fixture.txt handler-fixture.t.sol agentis-stub.sh; do
    [ -f "$FIX/$f" ] || { echo "[SKIP] deep-hunt fixture missing: $FIX/$f" >&2; exit 3; }
done

# jq-free JSON reader: the matrix field extractors below all funnel through one python one-liner.
mval() {  # $1 = matrix.json, $2 = python expression over `d` (the loaded record) -> printed
    python3 - "$1" "$2" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
try:
    v = eval(sys.argv[2], {"d": d})
except Exception as e:
    v = "ERR:" + str(e)
sys.stdout.write(str(v))
PY
}

# ----------------------------------------------------------------------------------------------------------
# Offline target: the #1713 deep-hunt fixture + ONE extra co-system contract in the SAME zone directory, so the
# value-custody zone `src` holds two .sol and a general-solvency row can carry an aux. The fixture is read-only.
# ----------------------------------------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lens-surface-matrix.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/target"
mkdir -p "$REPO"
cp "$FIX/foundry.toml" "$REPO/foundry.toml"
cp -R "$FIX/src" "$REPO/src"
cat > "$REPO/src/Strategy.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// Co-system contract of the value-custody zone -- gives the zone a second .sol so the general-solvency row has a
// co-system contract to thread as --aux. Never compiled here (the --agentis stub short-circuits generation).
contract Strategy {
    uint256 public deployed;
    function report(uint256 gain) external { deployed += gain; }
}
SOL
git -C "$REPO" init -q
git -C "$REPO" config user.email demo@example.invalid
git -C "$REPO" config user.name "demo"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "lens-surface-matrix fixture target"

STUB="$WORK/agentis-stub"
cp "$FIX/agentis-stub.sh" "$STUB"; chmod +x "$STUB"

# One shared breadth pass, then the STAGE 4.5 lens over clones of it (the #1774 --deep-hunt-only seam), so the
# runs differ only in the one flag / DEEP_HUNT_VERDICT under test.
BASE="$WORK/base"
"$ZONEHUNT" --repo "$REPO" --out "$BASE" --drop-dir "$BASE/drop" --scope-hint src \
    --backend mock --agentis "$STUB" \
    --map-fixture "$FIX/zones.fixture.txt" --brief-fixture "$FIX/briefs.fixture.txt" \
    --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
    --in-scope "the whole in-scope program" >"$WORK/base.log" 2>&1
BASE_RC=$?
if [ "$BASE_RC" -ne 0 ]; then
    fail "breadth baseline" "run-zone-hunt.sh breadth run exited $BASE_RC (see log tail below)"
    tail -20 "$WORK/base.log" | sed 's/^/      /' >&2
    summary_exit
fi

lens_run() {  # $1 = out dir, $2 = DEEP_HUNT_VERDICT, $3.. = extra flags
    _out="$1"; _verd="$2"; shift 2
    cp -R "$BASE" "$_out"
    ( export DEEP_HUNT_VERDICT="$_verd"
      "$ZONEHUNT" --repo "$REPO" --out "$_out" --deep-hunt --deep-hunt-only \
        --invariant-fixture "$FIX/handler-fixture.t.sol" \
        --backend mock --agentis "$STUB" "$@" >"$_out.log" 2>&1 )
}

lens_run "$WORK/finding" FINDING       --composable-lens ; RC_FIND=$?
lens_run "$WORK/clean"   CLEAN         --composable-lens ; RC_CLEAN=$?
lens_run "$WORK/harness" HARNESS_ERROR --composable-lens ; RC_HARN=$?
lens_run "$WORK/off"     FINDING                          ; RC_OFF=$?

M_FIND="$WORK/finding/coverage/lens-surface-matrix.json"
M_CLEAN="$WORK/clean/coverage/lens-surface-matrix.json"
M_HARN="$WORK/harness/coverage/lens-surface-matrix.json"
M_OFF="$WORK/off/coverage/lens-surface-matrix.json"

if [ "$RC_FIND" -ne 0 ] || [ "$RC_CLEAN" -ne 0 ] || [ "$RC_HARN" -ne 0 ] || [ "$RC_OFF" -ne 0 ]; then
    fail "deep-hunt lens runs" "exit codes find=$RC_FIND clean=$RC_CLEAN harness=$RC_HARN off=$RC_OFF"
    tail -20 "$WORK/harness.log" | sed 's/^/      /' >&2
    summary_exit
fi

# ----------------------------------------------------------------------------------------------------------
# (a) a --composable-lens run emits the matrix with schema + a per-surface lens-depth + verdict.
# ----------------------------------------------------------------------------------------------------------
a_fail=""
[ -f "$M_FIND" ] || a_fail="${a_fail} no-matrix-json"
if [ -f "$M_FIND" ]; then
    [ "$(mval "$M_FIND" "d['schema']")" = "lens-surface-matrix/v1" ] || a_fail="${a_fail} wrong-schema"
    [ "$(mval "$M_FIND" "len(d['surfaces'])")" -ge 1 ] 2>/dev/null || a_fail="${a_fail} no-surfaces"
    [ "$(mval "$M_FIND" "'src' in [s['id'] for s in d['surfaces']]")" = "True" ] || a_fail="${a_fail} src-surface-missing"
    [ "$(mval "$M_FIND" "[s for s in d['surfaces'] if s['id']=='src'][0]['lens_depth']")" = "general-solvency" ] \
        || a_fail="${a_fail} src-not-general-solvency"
    [ "$(mval "$M_FIND" "[s for s in d['surfaces'] if s['id']=='src'][0]['verdict']")" = "FINDING" ] \
        || a_fail="${a_fail} src-verdict-not-FINDING"
fi
if [ -z "$a_fail" ]; then
    pass "(a) --composable-lens emits lens-surface-matrix.json (schema lens-surface-matrix/v1) with the src surface at lens-depth general-solvency + verdict FINDING"
else
    fail "(a) matrix emitted per surface with lens-depth + verdict" "problem(s):$a_fail"
fi

# ----------------------------------------------------------------------------------------------------------
# (b) HARNESS_ERROR is a GAP, DISTINCT from CLEAN -- the whole point of the matrix. Both surfaces reached the
# general lens; their VERDICTS must differ and the HARNESS_ERROR one must be enumerated in harness_error_surfaces.
# ----------------------------------------------------------------------------------------------------------
b_fail=""
V_CLEAN="$(mval "$M_CLEAN" "[s for s in d['surfaces'] if s['id']=='src'][0]['verdict']")"
V_HARN="$(mval "$M_HARN" "[s for s in d['surfaces'] if s['id']=='src'][0]['verdict']")"
[ "$V_CLEAN" = "CLEAN" ] || b_fail="${b_fail} clean-verdict=${V_CLEAN}-want-CLEAN"
[ "$V_HARN" = "HARNESS_ERROR" ] || b_fail="${b_fail} harness-verdict=${V_HARN}-want-HARNESS_ERROR"
[ "$V_CLEAN" != "$V_HARN" ] || b_fail="${b_fail} CLEAN-and-HARNESS_ERROR-collapsed-to-one-state"
HE_HARN="$(mval "$M_HARN" "d['totals']['harness_error_surfaces']")"
HE_CLEAN="$(mval "$M_CLEAN" "d['totals']['harness_error_surfaces']")"
[ "$HE_HARN" = "['src']" ] || b_fail="${b_fail} harness-gap-list=${HE_HARN}-want-['src']"
[ "$HE_CLEAN" = "[]" ] || b_fail="${b_fail} clean-run-wrongly-listed-a-gap=${HE_CLEAN}"
if [ -z "$b_fail" ]; then
    pass "(b) SYS-solvency HARNESS_ERROR reads as an explicit GAP (harness_error_surfaces=['src']), DISTINCT from a SYS-solvency CLEAN surface -- the two do NOT collapse"
else
    fail "(b) HARNESS_ERROR distinct from CLEAN" "mismatch(es):$b_fail"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) a surface that only ever saw a per-class lens reads narrow-per-class (the OFF run: the custody zone got its
# C6 per-class row but never the general lens).
# ----------------------------------------------------------------------------------------------------------
D_OFF="$(mval "$M_OFF" "[s for s in d['surfaces'] if s['id']=='src'][0]['lens_depth']")"
V_OFF="$(mval "$M_OFF" "[s for s in d['surfaces'] if s['id']=='src'][0]['verdict']")"
if [ "$D_OFF" = "narrow-per-class" ] && [ "$V_OFF" = "None" ]; then
    pass "(c) with --composable-lens OFF the per-class-only src surface reads narrow-per-class (verdict None)"
else
    fail "(c) per-class-only surface = narrow-per-class" "lens_depth=$D_OFF verdict=$V_OFF (want narrow-per-class / None)"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) with --composable-lens OFF the matrix has ONLY narrow-per-class/discovery-only rows and NO general-solvency
# rows (the general lens is inert without the flag, so no surface can carry a verdict).
# ----------------------------------------------------------------------------------------------------------
d_fail=""
DEPTHS_OFF="$(mval "$M_OFF" "sorted(set(s['lens_depth'] for s in d['surfaces']))")"
GS_OFF="$(mval "$M_OFF" "d['totals']['by_depth']['general-solvency']")"
BAD_OFF="$(mval "$M_OFF" "[s['lens_depth'] for s in d['surfaces'] if s['lens_depth'] not in ('narrow-per-class','discovery-only')]")"
[ "$GS_OFF" = "0" ] || d_fail="${d_fail} general-solvency-count=${GS_OFF}-want-0"
[ "$BAD_OFF" = "[]" ] || d_fail="${d_fail} out-of-set-depths=${BAD_OFF}"
if [ -z "$d_fail" ]; then
    pass "(d) --composable-lens OFF: matrix carries only narrow-per-class/discovery-only rows (depths=$DEPTHS_OFF) and ZERO general-solvency rows"
else
    fail "(d) OFF matrix has no general-solvency rows" "problem(s):$d_fail"
fi

summary_exit
