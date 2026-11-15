#!/usr/bin/env bash
# tools/test-deep-cell-scope.sh -- regression guard for #2374 (dark-factory): the deep invariant cell's compile scope.
#
# Before #2374 run-invariant-hunt.sh dropped only the top level of test/*.t.sol from the staged copy, and
# evm-harness/forge-prebuild.sh skipped every *.sol under test/. A stray PoC elsewhere (numa: contracts/Test/,
# Fraxlend: src/test/) stayed in the copy, broke the viaIR prebuild, and every deep cell of the arm ended
# HARNESS_ERROR. Now one agent, dark-factory/auditor/agents/cell-scope.ag, owns the rule: it removes every *.t.sol
# outside the dependency dirs, proves none is left, and writes the prebuild's skip list; forge-prebuild.sh only
# turns that list into --skip arguments.
#
# How every case runs (the live-agent test of the .ag change):
#   * the REAL cell-scope.ag through a REAL agentis (DF_CELL_SCOPE_AGENTIS, else agentis on PATH);
#   * run-invariant-hunt.sh end to end with --handler-fixture and --backend mock; a stub --agentis stands in for
#     the prover only;
#   * a stub `forge` on PATH serves `config --json` (via_ir: true), `build` and `test`, writes every argv
#     NUL-separated to its own call file, and emulates compilation: the compile scope is every .sol outside the
#     dependency dirs minus the exact --skip values, and a file in scope that carries `// STUB-COMPILE-ERROR`
#     fails the way solc does (Error (7576), rc 1). That over-approximates forge's scope, so a stub pass implies
#     a real pass.
# An optional real-forge leg builds F1 and F2 with a real viaIR `forge build` (offline, cached solc 0.8.24); it
# SKIPs without them. On CI (GITHUB_ACTIONS=true) a missing agentis or another prerequisite of the stub leg is a
# FAIL, never a SKIP. The last line prints `agent runs=<n>`.
#
# Usage: bash tools/test-deep-cell-scope.sh
# Exit: 0 = held, 1 = regressed.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DF="$REPO_ROOT/dark-factory"
RIH="$DF/run-invariant-hunt.sh"
SHIM="$DF/evm-harness/forge-prebuild.sh"
AGENT="$DF/auditor/agents/cell-scope.ag"
MOCKS="$DF/auditor/harness-mocks"
INH="$DF/lib/inheritance.py"

PASS=0
FAIL=0
SKIPN=0
AGENT_RUNS=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1"; SKIPN=$((SKIPN + 1)); }
summary_exit() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIPN skipped; agent runs=$AGENT_RUNS"
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/deep-cell-scope.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
    chmod -R u+w "$WORK" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# Scratch state only: never the operator's forge-slot pool or warm records; no knob leaks in from the caller.
export FORGE_SLOTS_DIR="$WORK/forge-slots" FORGE_MAX_SLOTS=4 FORGE_SLOT_WAIT_S=2 DARK_FACTORY_DIR="$WORK/dfdir"
export DF_FORGE_WARM_DIR="$WORK/warm"
unset DF_INV_GATE_TIMEOUT_MS DF_FORGE_PREBUILD_MAX_S DF_FORGE_HEARTBEAT_S FOUNDRY_PROFILE FOUNDRY_VIA_IR 2>/dev/null || true

ON_CI=0
[ "${GITHUB_ACTIONS:-}" = "true" ] && ON_CI=1
SCOPE_BIN="${DF_CELL_SCOPE_AGENTIS:-$(command -v agentis 2>/dev/null || true)}"
prereq_missing=""
{ [ -n "$SCOPE_BIN" ] && [ -x "$SCOPE_BIN" ]; } || prereq_missing="$prereq_missing agentis(DF_CELL_SCOPE_AGENTIS='${DF_CELL_SCOPE_AGENTIS:-}')"
command -v python3 >/dev/null 2>&1 || prereq_missing="$prereq_missing python3"
[ -f "$AGENT" ] || prereq_missing="$prereq_missing cell-scope.ag"
if [ -n "$prereq_missing" ]; then
    if [ "$ON_CI" = 1 ]; then
        fail "prerequisites" "missing on CI:$prereq_missing (ci.yml exports DF_CELL_SCOPE_AGENTIS)"
    else
        skip "every case (missing:$prereq_missing)"
    fi
    summary_exit
fi
export DF_CELL_SCOPE_AGENTIS="$SCOPE_BIN"
M="$(find "$MOCKS" -maxdepth 1 -name '*.sol' -type f | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------------------------------------
# the stub forge and the prover stub
# ---------------------------------------------------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/calls"
{
  echo '#!/usr/bin/env bash'
  printf 'CALLS=%q\n' "$WORK/calls"
} > "$WORK/bin/forge"
cat >> "$WORK/bin/forge" <<'STUB'
# Stub forge for test-deep-cell-scope.sh. Each call writes its argv NUL-separated to $CALLS/<seq>.<sub> and, for
# build/test, its compile scope (NUL-separated, sorted) to $CALLS/<seq>.<sub>.scope.
sub="${1:-}"
seq=$(( $(find "$CALLS" -maxdepth 1 -type f ! -name '*.scope' | wc -l) + 1 ))
rec="$CALLS/$(printf '%04d' "$seq").$sub"
printf '%s\0' "$@" > "$rec"
compile() {  # "$@" = the forge argv; the over-approximated scope, then the solc emulation
  local a prev="" f s skipped bad
  local -a skips=()
  for a in "$@"; do [ "$prev" = "--skip" ] && skips+=("$a"); prev="$a"; done
  while IFS= read -r -d '' f; do
    f="${f#./}"
    skipped=0
    for s in ${skips[@]+"${skips[@]}"}; do [ "$f" = "$s" ] && { skipped=1; break; }; done
    [ "$skipped" = 1 ] && continue
    printf '%s\0' "$f"
  done < <(find . \( -path ./lib -o -path ./dependencies -o -path ./out -o -name node_modules -o -name .git \) -prune \
             -o -type f -name '*.sol' -print0) | LC_ALL=C sort -z > "$rec.scope"
  bad="$(tr '\0' '\n' < "$rec.scope" | while IFS= read -r f; do grep -q 'STUB-COMPILE-ERROR' "$f" 2>/dev/null && printf '%s' "$f" && break; done)"
  if [ -n "$bad" ]; then
    printf 'Compiler run failed:\nError (7576): Undeclared identifier.\n  --> %s:87:62:\n' "$bad" >&2
    return 1
  fi
  return 0
}
case "$sub" in
  config) printf '{"src": "src", "via_ir": true, "cache": true, "cache_path": "cache_stub", "out": "out_stub"}\n'; exit 0 ;;
  build) compile "$@"; exit $? ;;
  test)
    compile "$@" || exit 1
    printf '%s\n' '{"test/Inv.t.sol:InvTest":{"test_results":{"invariant_property()":{"status":"Success"}}}}'
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/forge"
cat > "$WORK/prover-stub" <<'PSTUB'
#!/bin/sh
# The --agentis stub: stands in for invariant-prover.ag only (cell-scope.ag runs through DF_CELL_SCOPE_AGENTIS).
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go) echo "INVARIANT|Vault.sol:Vault|CLEAN"; exit 0 ;;
esac
exit 0
PSTUB
chmod +x "$WORK/prover-stub"
printf '%s\n' '// SPDX-License-Identifier: MIT' 'pragma solidity ^0.8.20;' \
    'contract InvTest { function invariant_property() public pure {} }' > "$WORK/fixture.t.sol"
STUBPATH="$WORK/bin:$PATH"

# ---------------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------------
sol() {  # sol <path> [extra line]: a small valid Solidity file (plus an optional line)
    mkdir -p "$(dirname "$1")"
    { printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n'
      printf 'contract C%s { function f() public pure returns (uint256) { return 1; } }\n' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
      [ -n "${2:-}" ] && printf '%s\n' "$2"; } > "$1"
}
bad_sol() {  # bad_sol <path>: a test that does not compile (solc 7576), marked for the stub
    mkdir -p "$(dirname "$1")"
    printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\n// STUB-COMPILE-ERROR\ncontract BadPoc { function t() public { undeclaredThing = 1; } }\n' > "$1"
}
toml() {  # toml <dir> <src> [test]
    mkdir -p "$1"
    { printf '[profile.default]\nsrc = "%s"\nout = "out"\nlibs = ["lib"]\nvia_ir = true\nsolc_version = "0.8.24"\noffline = true\n' "$2"
      [ -n "${3:-}" ] && printf 'test = "%s"\n' "$3"; } > "$1/foundry.toml"
}
# run_cell <name> <project> [VAR=value ...]: the runner end to end; sets RC, OUTD (= <out>), CALLD, LOG
run_cell() {
    _rc_name="$1"; _rc_src="$2"; shift 2
    OUTD="$WORK/out-$_rc_name"; LOG="$WORK/$_rc_name.log"; CALLD="$WORK/calls"
    rm -rf "$OUTD" "$WORK/calls"; mkdir -p "$WORK/calls"
    RC=0
    env PATH="$STUBPATH" "$@" bash "$RIH" --repo "$_rc_src" --target Vault.sol:Vault --backend mock \
        --handler-fixture "$WORK/fixture.t.sol" --agentis "$WORK/prover-stub" --out "$OUTD" > "$LOG" 2>&1 || RC=$?
    grep -q '^run-invariant-hunt.sh: \[cell-scope\] dropped ' "$LOG" && AGENT_RUNS=$((AGENT_RUNS + 1))
    grep -q 'the scope agent refused or failed' "$LOG" && AGENT_RUNS=$((AGENT_RUNS + 1))
    return 0
}
call_of() { find "$CALLD" -maxdepth 1 -type f -name "*.$1" | sort | head -1; }
n_calls() { find "$CALLD" -maxdepth 1 -type f -name "*.$1" | wc -l | tr -d ' '; }
skips_of() {  # skips_of <call file>: the --skip values, NUL-separated, in argv order
    _so_prev=""
    while IFS= read -r -d '' _so_a; do
        [ "$_so_prev" = "--skip" ] && printf '%s\0' "$_so_a"
        _so_prev="$_so_a"
    done < "$1"
}
lst() { tr '\0' '\n' < "$1"; }
sorted_nul() { LC_ALL=C sort -z; }
fact() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }
# old_stage <project> <dst>: the pre-#2374 staging (copy, top-level test/*.t.sol drop, mocks)
old_stage() {
    rm -rf "$2"; cp -R "$1" "$2"
    rm -f "$2/test/"*.t.sol 2>/dev/null || true
    mkdir -p "$2/test/mocks"
    for _m in "$MOCKS"/*.sol; do [ -f "$2/test/mocks/$(basename "$_m")" ] || cp "$_m" "$2/test/mocks/"; done
}
# old_skips <staged repo>: the pre-#2374 prebuild enumeration, NUL-separated, find order
old_skips() {
    _os_repo="$(cd "$1" && pwd)"
    find "$_os_repo/test" -type f -name '*.sol' -print0 2>/dev/null | while IFS= read -r -d '' _os_f; do
        printf '%s\0' "${_os_f#"$_os_repo"/}"
    done
}
# tree <dir>: every non-directory entry, ./-relative, NUL-separated, sorted (names with a newline stay whole)
tree() { ( cd "$1" && find . ! -type d -print0 ) | sorted_nul; }
removed() {  # removed <before dir> <after dir>: entries in before but not in after, newline-listed (sorted)
    python3 -I -c '
import sys
a = set(open(sys.argv[1], "rb").read().split(b"\0")) - {b""}
b = set(open(sys.argv[2], "rb").read().split(b"\0")) - {b""}
for p in sorted(a - b): sys.stdout.buffer.write(p.replace(b"\n", b"<NL>") + b"\n")
' <(tree "$1") <(tree "$2")
}
dropped_listing() { python3 -I -c '
import sys
for p in sorted(set(open(sys.argv[1], "rb").read().split(b"\0")) - {b""}): sys.stdout.buffer.write(p.replace(b"\n", b"<NL>") + b"\n")
' "$1"; }
sha_of() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# ---------------------------------------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------------------------------------
# F1, numa-shaped: src = contracts, the project's own tests + a stray non-compiling PoC under contracts/Test/.
F1="$WORK/f1"
toml "$F1" contracts
sol "$F1/contracts/Vault.sol" 'contract Vault { uint256 public total; function deposit(uint256 a) external { total += a; } }'
sol "$F1/contracts/Test/Lending.t.sol"
bad_sol "$F1/contracts/Test/LeverageCollateralPoc.t.sol"
sol "$F1/contracts/Test/mocks/VaultMockOracle.sol"
sol "$F1/contracts/Test/utils/SetupBase.sol"
sol "$F1/contracts/deployment/Deployer.sol" 'import "../Test/mocks/VaultMockOracle.sol";'
mkdir -p "$F1/test"; printf 'describe("numa", () => {});\n' > "$F1/test/Numa.js"
sol "$F1/lib/forge-std/test/StdAssertions.t.sol"
sol "$F1/node_modules/@oz/test/Oz.t.sol"
sol "$F1/dependencies/solady/test/Solady.t.sol"
mkdir -p "$F1/out/LeverageCollateralPoc.t.sol"; printf '{}\n' > "$F1/out/LeverageCollateralPoc.t.sol/LeverageCollateralPocTest.json"

# F2, Fraxlend-shaped: src = src/contracts, test = src/test; a stray non-compiling PoC + a kept helper.
F2="$WORK/f2"
toml "$F2" src/contracts src/test
sol "$F2/src/contracts/Vault.sol" 'contract Vault { function deposit() external {} }'
bad_sol "$F2/src/test/C19Poc.t.sol"
sol "$F2/src/test/e2e/BasePairTest.sol"

# F3, flat test/ (AC5): two tests + two helpers, one with glob metacharacters in its name.
F3="$WORK/f3"
toml "$F3" src
sol "$F3/src/Vault.sol" 'contract Vault {}'
sol "$F3/test/Vault.t.sol"
sol "$F3/test/Other.t.sol"
sol "$F3/test/utils/Helper.sol"
sol "$F3/test/utils/H[1].sol"

# F4, nested test/: a top-level and a nested test + a nested helper.
F4="$WORK/f4"
toml "$F4" src
sol "$F4/src/Vault.sol" 'contract Vault {}'
sol "$F4/test/A.t.sol"
sol "$F4/test/unit/A.t.sol"
sol "$F4/test/invariant/handlers/H.sol"

# =========================================================================================================
# the cases
# =========================================================================================================

# --- cell_scope_numa_layout ------------------------------------------------------------------------------
run_cell numa "$F1"
R="$OUTD/run/repo"
c_fail=""
[ "$RC" = 0 ] || c_fail="$c_fail rc=$RC"
[ "$(dropped_listing "$OUTD/run/dropped-tests.lst" | tr '\n' ' ')" = "./contracts/Test/Lending.t.sol ./contracts/Test/LeverageCollateralPoc.t.sol " ] \
    || c_fail="$c_fail dropped=[$(dropped_listing "$OUTD/run/dropped-tests.lst" | tr '\n' ' ')]"
[ "$(removed "$F1" "$R" | tr '\n' ' ')" = "./contracts/Test/Lending.t.sol ./contracts/Test/LeverageCollateralPoc.t.sol " ] \
    || c_fail="$c_fail removed=[$(removed "$F1" "$R" | tr '\n' ' ')]"
for _k in contracts/Test/mocks/VaultMockOracle.sol contracts/Test/utils/SetupBase.sol contracts/deployment/Deployer.sol \
          test/Numa.js lib/forge-std/test/StdAssertions.t.sol node_modules/@oz/test/Oz.t.sol \
          dependencies/solady/test/Solady.t.sol out/LeverageCollateralPoc.t.sol/LeverageCollateralPocTest.json; do
    cmp -s "$F1/$_k" "$R/$_k" || c_fail="$c_fail changed:$_k"
done
[ "$(fact "$OUTD/run/gate-budget.txt" prebuild_rc)" = 0 ] || c_fail="$c_fail prebuild_rc=$(fact "$OUTD/run/gate-budget.txt" prebuild_rc)"
grep -q '^run-invariant-hunt.sh: \[cell-scope\] dropped 2, prebuild skip '"$M"'$' "$LOG" || c_fail="$c_fail no-stderr-line"
if [ -z "$c_fail" ]; then
    pass "cell_scope_numa_layout: contracts/Test/ tests dropped (2), helpers / importer / deps byte-identical, prebuild_rc=0"
else
    fail "cell_scope_numa_layout" "$c_fail"; tail -5 "$LOG" | sed 's/^/      /'
fi
# saved for cell_scope_reach_inventory_unchanged
NUMA_OUT="$WORK/numa-run"; rm -rf "$NUMA_OUT"; cp -R "$OUTD/run" "$NUMA_OUT"

# --- cell_scope_fraxlend_layout --------------------------------------------------------------------------
run_cell frax "$F2"
R="$OUTD/run/repo"
c_fail=""
[ "$RC" = 0 ] || c_fail="$c_fail rc=$RC"
[ "$(removed "$F2" "$R" | tr '\n' ' ')" = "./src/test/C19Poc.t.sol " ] || c_fail="$c_fail removed=[$(removed "$F2" "$R" | tr '\n' ' ')]"
cmp -s "$F2/src/test/e2e/BasePairTest.sol" "$R/src/test/e2e/BasePairTest.sol" || c_fail="$c_fail helper-changed"
[ "$(fact "$OUTD/run/gate-budget.txt" prebuild_rc)" = 0 ] || c_fail="$c_fail prebuild_rc=$(fact "$OUTD/run/gate-budget.txt" prebuild_rc)"
cp "$WORK/fixture.t.sol" "$R/test/Inv.t.sol"
rm -rf "$WORK/calls"; mkdir -p "$WORK/calls"; CALLD="$WORK/calls"
PATH="$STUBPATH" bash "$OUTD/run/forge-invariant.sh" --repo "$R" --target test/Inv.t.sol > "$WORK/frax-gate.log" 2>&1
grc=$?
# rc 0 = CLEAN: every `forge test` call of the gate compiled its scope (the stub fails a scope holding the PoC)
{ [ "$grc" = 0 ] && [ "$(n_calls test)" -ge 1 ] && ! grep -q 'Error (7576)' "$WORK/frax-gate.log"; } || c_fail="$c_fail gate rc=$grc"
if [ -z "$c_fail" ]; then
    pass "cell_scope_fraxlend_layout: src/test/C19Poc.t.sol dropped, src/test helper kept, prebuild_rc=0, the staged gate compiles clean"
else
    fail "cell_scope_fraxlend_layout" "$c_fail"; tail -5 "$LOG" | sed 's/^/      /'
fi

# --- cell_scope_flat_test_dir_unchanged (AC5) -------------------------------------------------------------
run_cell flat "$F3"
R="$OUTD/run/repo"
old_stage "$F3" "$WORK/ref-flat"
c_fail=""
[ "$RC" = 0 ] || c_fail="$c_fail rc=$RC"
[ "$(removed "$WORK/ref-flat" "$R")" = "" ] && [ "$(removed "$R" "$WORK/ref-flat")" = "" ] || c_fail="$c_fail tree!=old"
[ "$(dropped_listing "$OUTD/run/dropped-tests.lst" | tr '\n' ' ')" = "./test/Other.t.sol ./test/Vault.t.sol " ] || c_fail="$c_fail dropped"
pb="$(call_of build)"
if [ -z "$pb" ]; then c_fail="$c_fail no-build"; else
    skips_of "$pb" > "$WORK/flat-new.skips"
    old_skips "$R" > "$WORK/flat-old.skips"
    cmp -s "$WORK/flat-new.skips" "$WORK/flat-old.skips" || c_fail="$c_fail skip-argv-differs"
    [ "$(tr -cd '\0' < "$WORK/flat-new.skips" | wc -c | tr -d ' ')" = "$((M + 2))" ] || c_fail="$c_fail n-skips"
    lst "$WORK/flat-new.skips" | grep -qx 'test/utils/H\[1\].sol' || c_fail="$c_fail glob-name"
fi
if [ -z "$c_fail" ]; then
    pass "cell_scope_flat_test_dir_unchanged: the old test/*.t.sol set dropped, prebuild --skip argv byte-identical (M+2=$((M + 2)) entries)"
else
    fail "cell_scope_flat_test_dir_unchanged" "$c_fail"; tail -5 "$LOG" | sed 's/^/      /'
fi
FLAT_OUT="$WORK/flat-run"; rm -rf "$FLAT_OUT"; cp -R "$OUTD/run" "$FLAT_OUT"

# --- cell_scope_nested_test_dir ---------------------------------------------------------------------------
run_cell nested "$F4"
R="$OUTD/run/repo"
old_stage "$F4" "$WORK/ref-nested"
c_fail=""
[ "$RC" = 0 ] || c_fail="$c_fail rc=$RC"
[ "$(dropped_listing "$OUTD/run/dropped-tests.lst" | tr '\n' ' ')" = "./test/A.t.sol ./test/unit/A.t.sol " ] || c_fail="$c_fail dropped"
pb="$(call_of build)"
if [ -z "$pb" ]; then c_fail="$c_fail no-build"; else
    skips_of "$pb" | sorted_nul > "$WORK/nested-new.skips"
    old_skips "$WORK/ref-nested" | lst /dev/stdin | grep -vx 'test/unit/A.t.sol' | tr '\n' '\0' | sorted_nul > "$WORK/nested-old.skips"
    cmp -s "$WORK/nested-new.skips" "$WORK/nested-old.skips" || c_fail="$c_fail skips!=old-minus-unit"
    [ "$(tr -cd '\0' < "$WORK/nested-new.skips" | wc -c | tr -d ' ')" = "$((M + 1))" ] || c_fail="$c_fail n-skips"
    cp "$pb.scope" "$WORK/nested-new.scope"
    # today's compiled set: the old staged copy built by the same stub with the old skip argv
    _old_args=(build); while IFS= read -r -d '' _x; do _old_args+=(--skip "$_x"); done < <(old_skips "$WORK/ref-nested")
    rm -rf "$WORK/calls"; mkdir -p "$WORK/calls"; CALLD="$WORK/calls"
    ( cd "$WORK/ref-nested" && PATH="$STUBPATH" forge "${_old_args[@]}" ) >/dev/null 2>&1
    cmp -s "$WORK/nested-new.scope" "$(call_of build).scope" || c_fail="$c_fail compiled-set-differs"
fi
if [ -z "$c_fail" ]; then
    pass "cell_scope_nested_test_dir: test/unit/A.t.sol now dropped, skips = today's minus it (M+1=$((M + 1))), same compiled set"
else
    fail "cell_scope_nested_test_dir" "$c_fail"; tail -5 "$LOG" | sed 's/^/      /'
fi

# --- cell_scope_no_tests ----------------------------------------------------------------------------------
F5="$WORK/f5"; toml "$F5" src; sol "$F5/src/Vault.sol" 'contract Vault {}'
F5b="$WORK/f5b"; toml "$F5b" src; sol "$F5b/src/Vault.sol" 'contract Vault {}'; mkdir -p "$F5b/test"
c_fail=""
for _f in "$F5" "$F5b"; do
    run_cell notests "$_f"
    [ "$RC" = 0 ] || c_fail="$c_fail $(basename "$_f"):rc=$RC"
    [ ! -s "$OUTD/run/dropped-tests.lst" ] && [ -f "$OUTD/run/dropped-tests.lst" ] || c_fail="$c_fail $(basename "$_f"):dropped"
    pb="$(call_of build)"
    if [ -z "$pb" ]; then c_fail="$c_fail $(basename "$_f"):no-build"; else
        skips_of "$pb" > "$WORK/nt-new.skips"; old_skips "$OUTD/run/repo" > "$WORK/nt-old.skips"
        cmp -s "$WORK/nt-new.skips" "$WORK/nt-old.skips" || c_fail="$c_fail $(basename "$_f"):skips"
        [ "$(tr -cd '\0' < "$WORK/nt-new.skips" | wc -c | tr -d ' ')" = "$M" ] || c_fail="$c_fail $(basename "$_f"):n-skips"
    fi
done
if [ -z "$c_fail" ]; then
    pass "cell_scope_no_tests: no test/ or an empty test/ => nothing dropped, S = the $M mocks, args as today"
else
    fail "cell_scope_no_tests" "$c_fail"
fi

# --- cell_scope_root_level_test ---------------------------------------------------------------------------
F6="$WORK/f6"; toml "$F6" src; sol "$F6/src/Vault.sol" 'contract Vault {}'
sol "$F6/Root.t.sol"; sol "$F6/a/A.t.sol"; sol "$F6/zz/deep/er/Last.t.sol"; sol "$F6/src/Mid.t.sol"
run_cell root "$F6"
c_fail=""
[ "$RC" = 0 ] || c_fail="$c_fail rc=$RC"
[ "$(dropped_listing "$OUTD/run/dropped-tests.lst" | tr '\n' ' ')" = "./Root.t.sol ./a/A.t.sol ./src/Mid.t.sol ./zz/deep/er/Last.t.sol " ] \
    || c_fail="$c_fail list=[$(dropped_listing "$OUTD/run/dropped-tests.lst" | tr '\n' ' ')]"
[ "$(removed "$F6" "$OUTD/run/repo" | wc -l | tr -d ' ')" = 4 ] || c_fail="$c_fail removed"
grep -q '\[cell-scope\] dropped 4, ' "$LOG" || c_fail="$c_fail count"
if [ -z "$c_fail" ]; then
    pass "cell_scope_root_level_test: the first and last walk records are dropped whole, dropped= matches (4)"
else
    fail "cell_scope_root_level_test" "$c_fail"
fi

# --- cell_scope_deps_untouched ----------------------------------------------------------------------------
F7="$WORK/f7"; toml "$F7" src; sol "$F7/src/Vault.sol" 'contract Vault {}'
DEPS="lib/forge-std/test/Std.t.sol dependencies/x/test/X.t.sol node_modules/@x/test/Z.t.sol pkg/a/node_modules/y/Z.t.sol"
for _d in $DEPS; do sol "$F7/$_d"; done
sol "$F7/pkg/a/P.t.sol"
run_cell deps "$F7"
c_fail=""
[ "$RC" = 0 ] || c_fail="$c_fail rc=$RC"
for _d in $DEPS; do [ -f "$OUTD/run/repo/$_d" ] && [ "$(sha_of "$F7/$_d")" = "$(sha_of "$OUTD/run/repo/$_d")" ] || c_fail="$c_fail $_d"; done
[ "$(removed "$F7" "$OUTD/run/repo" | tr '\n' ' ')" = "./pkg/a/P.t.sol " ] || c_fail="$c_fail removed"
if [ -z "$c_fail" ]; then
    pass "cell_scope_deps_untouched: ./lib, ./dependencies and node_modules at any depth keep their tests (sha256 equal)"
else
    fail "cell_scope_deps_untouched" "$c_fail"
fi

# --- cell_scope_nested_lib_is_project_code ----------------------------------------------------------------
F8="$WORK/f8"; toml "$F8" src; sol "$F8/src/Vault.sol" 'contract Vault {}'
sol "$F8/test/hook/lib/TickLinkedList.t.sol"; sol "$F8/src/lib/Inner.t.sol"
run_cell nlib "$F8"
if [ "$RC" = 0 ] && [ "$(removed "$F8" "$OUTD/run/repo" | tr '\n' ' ')" = "./src/lib/Inner.t.sol ./test/hook/lib/TickLinkedList.t.sol " ]; then
    pass "cell_scope_nested_lib_is_project_code: a nested lib/ is project code, its tests are dropped"
else
    fail "cell_scope_nested_lib_is_project_code" "rc=$RC removed=[$(removed "$F8" "$OUTD/run/repo" | tr '\n' ' ')]"
fi

# --- cell_scope_git_dir_untouched -------------------------------------------------------------------------
F9="$WORK/f9"; toml "$F9" src; sol "$F9/src/Vault.sol" 'contract Vault {}'
mkdir -p "$F9/.git/refs/heads"; printf 'deadbeef\n' > "$F9/.git/refs/heads/poc.t.sol"
mkdir -p "$F9/sub/.git"; printf 'x\n' > "$F9/sub/.git/y.t.sol"
run_cell git "$F9"
if [ "$RC" = 0 ] && [ "$(removed "$F9" "$OUTD/run/repo")" = "" ] && cmp -s "$F9/.git/refs/heads/poc.t.sol" "$OUTD/run/repo/.git/refs/heads/poc.t.sol"; then
    pass "cell_scope_git_dir_untouched: .git/ at any depth is never pruned"
else
    fail "cell_scope_git_dir_untouched" "rc=$RC removed=[$(removed "$F9" "$OUTD/run/repo" | tr '\n' ' ')]"
fi

# --- cell_scope_hostile_names -----------------------------------------------------------------------------
# Every byte below is written literally (no \xHH), so the fixture is the same under bash and dash.
NL='
'
F10="$WORK/f10"; toml "$F10" src; sol "$F10/src/Vault.sol" 'contract Vault {}'
sol "$F10/contracts/Test/sp ace.t.sol"
sol "$F10/contracts/Test/new${NL}line.t.sol"
sol "$F10/contracts/Test/-rf.t.sol"
sol "$F10/contracts/Tést/X.t.sol"
sol "$F10/contracts/Test/Zw​.t.sol"
sol "$F10/contracts/Test/Lead․t.sol"
sol "$F10/contracts/Test/Full.ｔ.sol"
sol "$F10/contracts/Test/Up.T.SOL"
sol "$F10/contracts/Test/Mix.t.SOL"
sol "$F10/contracts/Test/Keep.sol"
run_cell hostile "$F10"
got="$(removed "$F10" "$OUTD/run/repo" | tr '\n' '|')"
want="./contracts/Test/-rf.t.sol|./contracts/Test/Zw​.t.sol|./contracts/Test/new<NL>line.t.sol|./contracts/Test/sp ace.t.sol|./contracts/Tést/X.t.sol|"
want_sorted="$(printf '%s' "$want" | tr '|' '\n' | LC_ALL=C sort | tr '\n' '|')"
got_sorted="$(printf '%s' "$got" | tr '|' '\n' | LC_ALL=C sort | tr '\n' '|')"
if [ "$RC" = 0 ] && [ "$got_sorted" = "$want_sorted" ] && grep -q '\[cell-scope\] dropped 5, ' "$LOG"; then
    pass "cell_scope_hostile_names: space / newline / leading dash / non-ASCII dir / zero-width space dropped; look-alikes and case variants kept"
else
    fail "cell_scope_hostile_names" "rc=$RC removed=[$got]"
fi

# --- cell_scope_non_utf8_fails_closed ---------------------------------------------------------------------
BADB="$(printf '\377')"
c_fail=""
for _where in "contracts/Test/bad${BADB}.t.sol" "test/helper${BADB}.sol"; do
    F11="$WORK/f11"; rm -rf "$F11"; toml "$F11" src; sol "$F11/src/Vault.sol" 'contract Vault {}'
    sol "$F11/$_where"
    run_cell nonutf8 "$F11"
    [ "$RC" = 3 ] || c_fail="$c_fail rc=$RC"
    [ "$(n_calls build)" = 0 ] || c_fail="$c_fail built"
    grep -q 'the scope agent refused or failed' "$LOG" || c_fail="$c_fail no-refusal"
done
if [ -z "$c_fail" ]; then
    pass "cell_scope_non_utf8_fails_closed: a non-UTF-8 *.t.sol name or test/ *.sol name => refusal, exit 3, no build"
else
    fail "cell_scope_non_utf8_fails_closed" "$c_fail"
fi

# --- cell_scope_symlink_test_file -------------------------------------------------------------------------
F12="$WORK/f12"; toml "$F12" src; sol "$F12/src/Vault.sol" 'contract Vault {}'
sol "$F12/contracts/Vault.sol"
mkdir -p "$F12/contracts/Test"
ln -s ../Vault.sol "$F12/contracts/Test/Link.t.sol"
ln -s ../nowhere.sol "$F12/contracts/Test/Dangling.t.sol"
run_cell symfile "$F12"
R="$OUTD/run/repo"
if [ "$RC" = 0 ] && [ ! -L "$R/contracts/Test/Link.t.sol" ] && [ ! -L "$R/contracts/Test/Dangling.t.sol" ] \
   && [ -f "$R/contracts/Vault.sol" ] && cmp -s "$F12/contracts/Vault.sol" "$R/contracts/Vault.sol"; then
    pass "cell_scope_symlink_test_file: a symlinked and a dangling *.t.sol are dropped, the link target stays"
else
    fail "cell_scope_symlink_test_file" "rc=$RC removed=[$(removed "$F12" "$R" | tr '\n' ' ')]"
fi

# --- cell_scope_never_writes_outside_copy -----------------------------------------------------------------
OUTSIDE="$WORK/outside"; mkdir -p "$OUTSIDE"; sol "$OUTSIDE/Out.t.sol"; _osha="$(sha_of "$OUTSIDE/Out.t.sol")"
F13="$WORK/f13"; toml "$F13" src; sol "$F13/src/Vault.sol" 'contract Vault {}'
mkdir -p "$F13/contracts"; ln -s "$OUTSIDE" "$F13/contracts/ext"
run_cell outside "$F13"
if [ "$RC" = 0 ] && [ -f "$OUTSIDE/Out.t.sol" ] && [ "$(sha_of "$OUTSIDE/Out.t.sol")" = "$_osha" ] \
   && [ -L "$OUTD/run/repo/contracts/ext" ] && [ ! -s "$OUTD/run/dropped-tests.lst" ]; then
    pass "cell_scope_never_writes_outside_copy: a symlinked dir pointing outside is not followed, the outside file is byte-identical"
else
    fail "cell_scope_never_writes_outside_copy" "rc=$RC outside=$(ls "$OUTSIDE")"
fi

# --- cell_scope_dir_named_like_test -----------------------------------------------------------------------
F14="$WORK/f14"; toml "$F14" src; sol "$F14/src/Vault.sol" 'contract Vault {}'
sol "$F14/contracts/Weird.t.sol/Inner.t.sol"; sol "$F14/contracts/Weird.t.sol/Keep.sol"
mkdir -p "$F14/out/X.t.sol"; printf '{}\n' > "$F14/out/X.t.sol/X.json"
run_cell dirlike "$F14"
R="$OUTD/run/repo"
if [ "$RC" = 0 ] && [ -d "$R/contracts/Weird.t.sol" ] && [ -f "$R/contracts/Weird.t.sol/Keep.sol" ] && [ -f "$R/out/X.t.sol/X.json" ] \
   && [ "$(removed "$F14" "$R" | tr '\n' ' ')" = "./contracts/Weird.t.sol/Inner.t.sol " ]; then
    pass "cell_scope_dir_named_like_test: dirs named *.t.sol (and out/ artifact dirs) kept, a *.t.sol file inside one dropped"
else
    fail "cell_scope_dir_named_like_test" "rc=$RC removed=[$(removed "$F14" "$R" | tr '\n' ' ')]"
fi

# --- cell_scope_readonly_dir_fails_closed -----------------------------------------------------------------
if [ "$(id -u)" = 0 ]; then
    skip "cell_scope_readonly_dir_fails_closed (running as root, which ignores the mode)"
else
    F15="$WORK/f15"; toml "$F15" src; sol "$F15/src/Vault.sol" 'contract Vault {}'
    sol "$F15/contracts/Test/Ro.t.sol"; chmod 555 "$F15/contracts/Test"
    run_cell readonly "$F15"
    if [ "$RC" = 3 ] && [ "$(n_calls build)" = 0 ] && grep -q 'still in .* after the drop' "$LOG"; then
        pass "cell_scope_readonly_dir_fails_closed: rm fails, the verify walk refuses, exit 3, no prebuild"
    else
        fail "cell_scope_readonly_dir_fails_closed" "rc=$RC builds=$(n_calls build)"; tail -5 "$LOG" | sed 's/^/      /'
    fi
    chmod -R u+w "$F15" "$OUTD" 2>/dev/null
fi

# --- cell_scope_missing_binary_fails_closed ---------------------------------------------------------------
run_cell nobin "$F1" DF_CELL_SCOPE_AGENTIS="$WORK/no-such-agentis"
if [ "$RC" = 3 ] && [ "$(find "$CALLD" -maxdepth 1 -type f | wc -l | tr -d ' ')" = 0 ] && grep -q 'no agentis binary' "$LOG"; then
    pass "cell_scope_missing_binary_fails_closed: DF_CELL_SCOPE_AGENTIS missing => exit 3 before any forge call"
else
    fail "cell_scope_missing_binary_fails_closed" "rc=$RC forge-calls=$(find "$CALLD" -maxdepth 1 -type f | wc -l)"
fi

# --- cell_scope_stub_cannot_fake --------------------------------------------------------------------------
cat > "$WORK/scope-stub" <<'SSTUB'
#!/bin/sh
case "${1:-}" in
  init) mkdir -p .agentis/sandbox; exit 0 ;;
  go) echo SAFE; exit 0 ;;
esac
exit 0
SSTUB
chmod +x "$WORK/scope-stub"
run_cell fake "$F1" DF_CELL_SCOPE_AGENTIS="$WORK/scope-stub"
if [ "$RC" = 3 ] && [ "$(n_calls build)" = 0 ] && [ ! -e "$OUTD/run/prebuild-skip.lst" ]; then
    pass "cell_scope_stub_cannot_fake: a stub agentis writes no lists => exit 3, no build"
else
    fail "cell_scope_stub_cannot_fake" "rc=$RC builds=$(n_calls build)"
fi

# --- prebuild_skip_list_roundtrip -------------------------------------------------------------------------
RT="$WORK/rt"; toml "$RT" src; sol "$RT/src/Vault.sol" 'contract Vault {}'
printf '%s\0' "test/a b.sol" "test/new${NL}line.sol" "test/[x].sol" "test/*.sol" "test/-dash.sol" > "$WORK/rt.lst"
rm -rf "$WORK/calls"; mkdir -p "$WORK/calls"; CALLD="$WORK/calls"
PATH="$STUBPATH" bash "$SHIM" --repo "$RT" --source-repo "$RT" --warm-dir "$WORK/rt-warm" --heartbeat "$WORK/rt.hb" \
    --log "$WORK/rt.log" --skip-list "$WORK/rt.lst" > "$WORK/rt.out" 2>&1
pb="$(call_of build)"
if [ -n "$pb" ] && skips_of "$pb" | cmp -s - "$WORK/rt.lst" \
   && [ "$(tr -cd '\0' < "$pb" | wc -c | tr -d ' ')" = "$((1 + 2 * 5))" ]; then
    pass "prebuild_skip_list_roundtrip: space / newline / [ / * / leading dash reach forge as one --skip each, byte-equal"
else
    fail "prebuild_skip_list_roundtrip" "build=$pb out=$(tr '\n' ' ' < "$WORK/rt.out")"
fi

# --- cell_scope_gate_parity -------------------------------------------------------------------------------
R="$FLAT_OUT/repo"
cp "$WORK/fixture.t.sol" "$R/test/Inv.t.sol"
rm -rf "$WORK/calls"; mkdir -p "$WORK/calls"; CALLD="$WORK/calls"
PATH="$STUBPATH" bash "$FLAT_OUT/forge-invariant.sh" --repo "$R" --target test/Inv.t.sol > "$WORK/parity.log" 2>&1
gt="$(call_of test)"
if [ -n "$gt" ]; then
    skips_of "$gt" | sorted_nul > "$WORK/parity-gate.skips"
    sorted_nul < "$FLAT_OUT/prebuild-skip.lst" > "$WORK/parity-pb.skips"
fi
if [ -n "$gt" ] && cmp -s "$WORK/parity-gate.skips" "$WORK/parity-pb.skips" && ! lst "$WORK/parity-gate.skips" | grep -qx 'test/Inv.t.sol'; then
    pass "cell_scope_gate_parity: the staged gate skips exactly the prebuild's S on a pruned copy, never the harness"
else
    fail "cell_scope_gate_parity" "gate-call=$gt"
fi

# --- cell_scope_reach_inventory_unchanged (AC6) -----------------------------------------------------------
old_stage "$F1" "$WORK/ref-numa"
_ri() { python3 "$INH" reach-inventory --repo "$1" --target contracts/Vault.sol:Vault --out-tsv "$2.tsv" --out-inventory "$2.inv" >/dev/null 2>&1; }
if [ ! -f "$INH" ]; then
    fail "cell_scope_reach_inventory_unchanged" "lib/inheritance.py missing"
elif _ri "$WORK/ref-numa" "$WORK/ri-before" && _ri "$NUMA_OUT/repo" "$WORK/ri-after" \
     && [ -s "$WORK/ri-before.tsv" ] && cmp -s "$WORK/ri-before.tsv" "$WORK/ri-after.tsv" && cmp -s "$WORK/ri-before.inv" "$WORK/ri-after.inv"; then
    pass "cell_scope_reach_inventory_unchanged: reach-inventory over the numa copy is byte-identical before and after the drop"
else
    fail "cell_scope_reach_inventory_unchanged" "tsv/inventory differ or empty"
    diff "$WORK/ri-before.tsv" "$WORK/ri-after.tsv" 2>&1 | head -5 | sed 's/^/      /'
fi

# --- real-forge leg (optional; SKIPs without forge or a cached solc 0.8.24) ---------------------------------
SOLC_OK=0
for _s in "${XDG_DATA_HOME:-$HOME/.local/share}/svm/0.8.24/solc-0.8.24" "$HOME/.svm/0.8.24/solc-0.8.24"; do [ -x "$_s" ] && SOLC_OK=1; done
if ! command -v forge >/dev/null 2>&1 || [ "$SOLC_OK" = 0 ]; then
    skip "real_forge_numa_fraxlend (no forge or no cached solc 0.8.24)"
else
    r_fail=""
    for _p in "$F1" "$F2"; do
        _o="$WORK/real-$(basename "$_p")"; rm -rf "$_o"
        RC=0
        bash "$RIH" --repo "$_p" --target Vault.sol:Vault --backend mock --handler-fixture "$WORK/fixture.t.sol" \
            --agentis "$WORK/prover-stub" --out "$_o" > "$_o.log" 2>&1 || RC=$?
        AGENT_RUNS=$((AGENT_RUNS + 1))
        [ "$RC" = 0 ] && [ "$(fact "$_o/run/gate-budget.txt" prebuild_rc)" = 0 ] \
            || r_fail="$r_fail $(basename "$_p"):rc=$RC,prebuild_rc=$(fact "$_o/run/gate-budget.txt" prebuild_rc)"
    done
    if [ -z "$r_fail" ]; then
        pass "real_forge_numa_fraxlend: a real viaIR forge build of both pruned copies => prebuild_rc=0"
    else
        fail "real_forge_numa_fraxlend" "$r_fail"
    fi
fi

summary_exit
