#!/usr/bin/env bash
# tools/test-deep-hunt-composable-lens.sh -- deterministic offline guard for #1914 M1
# (dark-factory): the CLASS-AGNOSTIC general-solvency deep-hunt lens.
#
# STAGE 4.5 of run-zone-hunt.sh emits one `.deep-hunt-targets.tsv` row per (zone x
# applicable lens class). #1914 M1 adds, behind the default-OFF `--composable-lens`
# flag, ONE additional class-agnostic row per custody/composition surface -- stable
# class token `SYS-solvency`, target = the zone's primary .sol, aux = its next-largest
# co-system .sol. The row flows through the UNCHANGED while-loop into
# run-invariant-hunt.sh --class SYS-solvency --aux <co-system>, i.e. the shipped
# composable-fresh path (no prover / .ag change: class_to_keyword() passes an unknown
# token through to its generic menus).
#
# Offline by construction: the whole pipeline is driven through the --map-fixture /
# --brief-fixture / --pass-fixture / --invariant-fixture seams plus the ONE --agentis
# stub the #1713 deep-hunt fixture ships. No LLM, no forge, no network. Auto-discovered
# and run by tools/colony-lint.sh's `tools/test-*.sh` loop.
#
# The #1713 fixture's custody zone holds a SINGLE .sol, which cannot exercise a
# co-system aux, so this test builds its own throwaway target from that fixture plus one
# extra co-system contract in the SAME zone directory (map-zones groups per directory).
# The shipped fixture is consumed READ-ONLY -- deep-hunt-ab.sh's baseline is untouched.
#
# Assertions:
#   (a) SOURCE GUARD: run-zone-hunt.sh declares DEEP_HUNT_COMPOSABLE_LENS=0 (default OFF),
#       parses `--composable-lens`, and threads the flag as the 6th argv of the STAGE 4.5
#       selection python.
#   (b) CLI GUARD: `--composable-lens` without `--deep-hunt` fails fast with exit 2 and the
#       `--composable-lens requires --deep-hunt` usage error (the #1717 badval pattern).
#   (c) DEFAULT-OFF: a `--deep-hunt` run WITHOUT the flag produces exactly the pre-#1914
#       per-class TSV -- no `SYS-solvency` token anywhere.
#   (d) ADDITIVE: the same run WITH `--composable-lens` keeps every per-class row from (c)
#       and adds exactly ONE `SYS-solvency` row, whose 4th (aux) column is NON-EMPTY.
#   (e) ROUTED: that row reaches the engine as a real composable-fresh run -- a per-(zone,
#       class) out-dir `deep-hunt/<zid>-SYS-solvency/` with the aux source STAGED into its
#       rundir (`aux-code-0.sol`, which run-invariant-hunt.sh writes only when --aux is
#       non-empty, i.e. only in composable-fresh mode).
#
# Usage: bash tools/test-deep-hunt-composable-lens.sh
# Exit: 0 = held, 1 = regressed, 3 = missing prerequisite.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZONEHUNT="$REPO_ROOT/dark-factory/run-zone-hunt.sh"
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
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
for f in foundry.toml zones.fixture.txt briefs.fixture.txt handler-fixture.t.sol agentis-stub.sh; do
    [ -f "$FIX/$f" ] || { echo "[SKIP] deep-hunt fixture missing: $FIX/$f" >&2; exit 3; }
done

# ----------------------------------------------------------------------------------------------------------
# (a) source guard -- the flag is declared default-OFF, parsed, and threaded into the selection python.
# ----------------------------------------------------------------------------------------------------------
a_fail=""
grep -q '^DEEP_HUNT_COMPOSABLE_LENS=0$' "$ZONEHUNT" || a_fail="${a_fail} no-default-0"
grep -q -- '--composable-lens)  *DEEP_HUNT_COMPOSABLE_LENS=1; shift ;;' "$ZONEHUNT" || a_fail="${a_fail} no-parse-arm"
# shellcheck disable=SC2016  # matching the literal argv line, $ must not expand
# (#1930 appended "$PREFERRED_LENSES" as the next positional of the SAME argv line; the composable flag stays
# the argument immediately before it, so this still pins the 6th-argv threading it was written for.)
grep -q -- '"\$DEEP_HUNT_COMPOSABLE_LENS" "\$PREFERRED_LENSES" > "\$DEEP_TARGETS"' "$ZONEHUNT" || a_fail="${a_fail} not-threaded-as-argv"
grep -q 'composable = int(sys.argv\[6\])' "$ZONEHUNT" || a_fail="${a_fail} not-read-in-python"
if [ -z "$a_fail" ]; then
    pass "(a) run-zone-hunt.sh declares/parses --composable-lens (default 0) and threads it into STAGE 4.5"
else
    fail "(a) --composable-lens source wiring" "missing piece(s):$a_fail"
fi

# ----------------------------------------------------------------------------------------------------------
# (b) CLI guard -- the flag is only meaningful with --deep-hunt (the --deep-hunt-only precedent).
# ----------------------------------------------------------------------------------------------------------
GUARD_ERR="$(mktemp "${TMPDIR:-/tmp}/composable-lens-guard.XXXXXX")"
"$ZONEHUNT" --repo "$REPO_ROOT" --composable-lens >/dev/null 2>"$GUARD_ERR"
GUARD_RC=$?
if [ "$GUARD_RC" -eq 2 ] && grep -q -- '--composable-lens requires --deep-hunt' "$GUARD_ERR"; then
    pass "(b) --composable-lens without --deep-hunt fails fast with exit 2 + the usage error"
else
    fail "(b) --composable-lens requires --deep-hunt" "exit $GUARD_RC, stderr: $(head -3 "$GUARD_ERR" | tr '\n' ' ')"
fi
rm -f "$GUARD_ERR"

# ----------------------------------------------------------------------------------------------------------
# Offline target: the #1713 deep-hunt fixture + ONE extra co-system contract in the SAME zone directory, so the
# value-custody zone `src` holds two .sol (primary Vault.sol -- 52 lines -- plus the smaller Strategy.sol) and a
# general-solvency row can actually carry an aux. The fixture tree itself is only ever read.
# ----------------------------------------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/composable-lens.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/target"
mkdir -p "$REPO"
cp "$FIX/foundry.toml" "$REPO/foundry.toml"
cp -R "$FIX/src" "$REPO/src"
cat > "$REPO/src/Strategy.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// Co-system contract of the value-custody zone: the vault routes idle assets here, so system solvency spans
// BOTH contracts. Never compiled in this test (the --agentis stub short-circuits generation); it exists so the
// zone holds a second .sol and the general-solvency row has a co-system contract to thread as --aux.
contract Strategy {
    uint256 public deployed;
    function report(uint256 gain) external { deployed += gain; }
}
SOL
git -C "$REPO" init -q
git -C "$REPO" config user.email demo@example.invalid
git -C "$REPO" config user.name "demo"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "composable-lens fixture target"

STUB="$WORK/agentis-stub"
cp "$FIX/agentis-stub.sh" "$STUB"; chmod +x "$STUB"

# One shared breadth pass, then the STAGE 4.5 lens over two clones of it (the #1774 --deep-hunt-only seam), so
# OFF and ON differ in EXACTLY the one flag under test.
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

lens_only() {  # $1 = out dir (a clone of the breadth base), $2.. = extra flags
    _out="$1"; shift
    "$ZONEHUNT" --repo "$REPO" --out "$_out" --deep-hunt --deep-hunt-only \
        --invariant-fixture "$FIX/handler-fixture.t.sol" \
        --backend mock --agentis "$STUB" "$@" >"$_out.log" 2>&1
}

OUT_OFF="$WORK/off"; cp -R "$BASE" "$OUT_OFF"; lens_only "$OUT_OFF"; OFF_RC=$?
OUT_ON="$WORK/on";   cp -R "$BASE" "$OUT_ON";  lens_only "$OUT_ON" --composable-lens; ON_RC=$?
TSV_OFF="$OUT_OFF/.deep-hunt-targets.tsv"
TSV_ON="$OUT_ON/.deep-hunt-targets.tsv"

if [ "$OFF_RC" -ne 0 ] || [ "$ON_RC" -ne 0 ] || [ ! -f "$TSV_OFF" ] || [ ! -f "$TSV_ON" ]; then
    fail "deep-hunt lens runs" "OFF exit $OFF_RC / ON exit $ON_RC, target TSVs present: $([ -f "$TSV_OFF" ] && echo yes || echo no)/$([ -f "$TSV_ON" ] && echo yes || echo no)"
    tail -20 "$OUT_ON.log" | sed 's/^/      /' >&2
    summary_exit
fi

# ----------------------------------------------------------------------------------------------------------
# (c) DEFAULT-OFF: the selection is exactly the pre-#1914 per-class one (the golden below is what STAGE 4.5
# emitted before this change for this fixture: the custody zone's ONE dominant-class row, 3 columns because
# --deep-hunt-aux-max defaults to 0). A regression that leaks the general lens into the default path fails here.
# ----------------------------------------------------------------------------------------------------------
GOLDEN="$WORK/golden.tsv"
printf 'src\tsrc/Vault.sol\tC6\n' > "$GOLDEN"
if diff -u "$GOLDEN" "$TSV_OFF" >"$WORK/off.diff" 2>&1; then
    pass "(c) default-OFF .deep-hunt-targets.tsv is byte-identical to the pre-#1914 per-class selection"
else
    fail "(c) default-OFF selection unchanged" "TSV differs from the pre-change golden:"
    sed 's/^/      /' "$WORK/off.diff" >&2
fi
if grep -q 'SYS-solvency' "$TSV_OFF"; then
    fail "(c) no general lens by default" "the OFF run emitted a SYS-solvency row"
else
    pass "(c) the OFF run emits NO SYS-solvency row (the lens is inert by default)"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) ADDITIVE: every OFF row survives and exactly one SYS-solvency row is added, with a NON-EMPTY aux column
# (an empty aux would fall out of composable-fresh mode and make the lens vacuous).
# ----------------------------------------------------------------------------------------------------------
d_fail=""
while IFS= read -r row; do
    [ -n "$row" ] || continue
    grep -Fqx "$row" "$TSV_ON" || d_fail="${d_fail} dropped-per-class-row[$row]"
done < "$TSV_OFF"
SYS_ROWS="$(awk -F'\t' '$3 == "SYS-solvency"' "$TSV_ON")"
SYS_COUNT="$(printf '%s' "$SYS_ROWS" | grep -c . || true)"
[ "$SYS_COUNT" -eq 1 ] || d_fail="${d_fail} sys-row-count=${SYS_COUNT}-want-1"
SYS_TARGET="$(printf '%s\n' "$SYS_ROWS" | awk -F'\t' 'NR==1 {print $2}')"
SYS_AUX="$(printf '%s\n' "$SYS_ROWS" | awk -F'\t' 'NR==1 {print $4}')"
[ "$SYS_TARGET" = "src/Vault.sol" ] || d_fail="${d_fail} sys-target=${SYS_TARGET:-<none>}-want-src/Vault.sol"
[ "$SYS_AUX" = "src/Strategy.sol" ] || d_fail="${d_fail} sys-aux=${SYS_AUX:-<empty>}-want-src/Strategy.sol"
if [ -z "$d_fail" ]; then
    pass "(d) --composable-lens is ADDITIVE: every per-class row survives + exactly one SYS-solvency row with a non-empty aux (src/Vault.sol <- src/Strategy.sol)"
else
    fail "(d) additive SYS-solvency row with aux" "mismatch(es):$d_fail ; ON TSV: $(tr '\t' '|' < "$TSV_ON" | tr '\n' ' ')"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) ROUTED: the row really drove run-invariant-hunt.sh --class SYS-solvency --aux ... . The per-(zone,class)
# out-dir proves the class token routed; the STAGED aux source proves --aux was non-empty, i.e. the engine ran
# in composable-fresh mode (run-invariant-hunt.sh writes aux-code-<n>.sol only for a resolved --aux).
# ----------------------------------------------------------------------------------------------------------
e_fail=""
DZOUT="$OUT_ON/deep-hunt/src-SYS-solvency"
[ -d "$DZOUT" ] || e_fail="${e_fail} no-per-class-outdir[$DZOUT]"
AUX_STAGED="$(find "$DZOUT" -name 'aux-code-*.sol' 2>/dev/null | head -1)"
if [ -n "$AUX_STAGED" ]; then
    grep -q 'contract Strategy' "$AUX_STAGED" || e_fail="${e_fail} staged-aux-is-not-the-co-system-contract"
else
    e_fail="${e_fail} no-aux-staged-into-rundir"
fi
grep -q "target 'src/Vault.sol' (SYS-solvency)" "$OUT_ON.log" || e_fail="${e_fail} no-deep-hunt-log-line"
[ -d "$OUT_OFF/deep-hunt/src-SYS-solvency" ] && e_fail="${e_fail} off-run-produced-a-SYS-solvency-rundir"
if [ -z "$e_fail" ]; then
    pass "(e) the SYS-solvency row routes into run-invariant-hunt.sh --class SYS-solvency --aux (composable-fresh: aux source staged)"
else
    fail "(e) SYS-solvency row reaches the engine in composable-fresh mode" "problem(s):$e_fail"
fi

summary_exit
