#!/usr/bin/env bash
# tools/test-invariant-viair-gate.sh -- regression guard for #2353 (dark-factory): the deep invariant gate on a
# Foundry target with viaIR enabled.
#
# Before #2353 every viaIR deep cell ended HARNESS_ERROR: the prover's forge gate ran under the fixed
# `exec.default_timeout_ms = 600000` agentis bound while one cold viaIR build of the staged repo took ~30 min, and
# every cell paid that cold build again. The fix has three parts, all pinned here:
#   * evm-harness/forge-prebuild.sh: for a viaIR target (as `forge config --json` reports it), prebuild the staged
#     repo once per project root, publish the compiler cache file + the artifacts dir as a warm record, import that
#     record into every later cell, and print the measured facts (via_ir, cold_build_ms, prebuild_ms, prebuild_rc,
#     warm_hit). A non-viaIR target is a pure no-op.
#   * run-invariant-hunt.sh writes those facts (+ the validated DF_INV_GATE_TIMEOUT_MS override) to
#     `$RUN/gate-budget.txt`; invariant-prover.ag bounds its gate at `base + max(cold_build_ms, prebuild_ms)` (or
#     the override) with coreutils `timeout` inside an inline agentis exec backstop, and prints GATE-BOUND| /
#     GATE-TIMEOUT| diagnostics. No facts file => today's exact exec string.
#   * forge-invariant.sh touches `.gate-heartbeat` while forge runs, only when its staged rundir holds
#     gate-budget.txt, so the per-cell staleness watchdog does not kill a cell during a long compile.
#
# Part A is CI-safe: a stub `forge` on PATH serves `config --json`, `build` and `test`, and logs every call (with
# whether a forge slot is held and whether a `timeout` process is among its ancestors). Part B needs `agentis` on
# PATH (else [SKIP]) and runs the REAL run-invariant-hunt.sh -> `agentis go invariant-prover.ag` path with the
# stub forge, so the changed .ag is interpreted by the real runtime. Part C (STAGE 4.5 export) drives
# run-zone-hunt.sh over the #1713 deep-hunt fixture with a wrapper --agentis stub (CI-safe).
#
# Usage: bash tools/test-invariant-viair-gate.sh
# Exit: 0 = held, 1 = regressed.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DF="$REPO_ROOT/dark-factory"
SHIM="$DF/evm-harness/forge-prebuild.sh"
GATE="$DF/evm-harness/forge-invariant.sh"
RIH="$DF/run-invariant-hunt.sh"
ZONEHUNT="$DF/run-zone-hunt.sh"
FIX="$DF/bench/corpus-bench/fixtures/deep-hunt"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1"; }

summary_exit() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/viair-gate.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
procs_under() { ps -eo pid=,args= 2>/dev/null | VG_PAT="$1" awk 'index($0, ENVIRON["VG_PAT"]) > 0'; }
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
    procs_under "$WORK/" | awk '{print $1}' | while read -r _p; do kill -KILL "$_p" 2>/dev/null || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT

# Scratch state only: never the operator's forge-slot pool, no knob leaks in from the caller's environment.
export FORGE_SLOTS_DIR="$WORK/forge-slots" FORGE_MAX_SLOTS=4 FORGE_SLOT_WAIT_S=2 DARK_FACTORY_DIR="$WORK/dfdir"
unset DF_INV_GATE_TIMEOUT_MS DF_FORGE_WARM_DIR DF_FORGE_PREBUILD_MAX_S DF_FORGE_HEARTBEAT_S FOUNDRY_PROFILE \
      FOUNDRY_VIA_IR STUB_VIA_IR STUB_CONFIG_FAIL STUB_CONFIG_RAW STUB_CACHE_PATH STUB_OUT STUB_BUILD_S \
      STUB_BUILD_RC STUB_NO_WRITE STUB_TEST_S STUB_TEST_MODE 2>/dev/null || true

# A copy of `sleep` under the scratch dir, so a lingering stub child is findable by its path.
mkdir -p "$WORK/bin" "$WORK/sb"
cp "$(command -v sleep)" "$WORK/sb/vg-sleep"
export STUB_SLEEP="$WORK/sb/vg-sleep"
# The ancestor walk in the stub stops at this test's own PID (colony-lint runs the test under `timeout`).
export STUB_STOP_PID="$$"
export STUB_LOG="$WORK/forge-calls.log"

# The agentis exec sandbox passes only PATH and the exec.env_passthrough allowlist, so the stub reads its fixed
# settings from a baked header and the per-run knobs from $WORK/stub.env (written by run_e2e below).
: > "$WORK/stub.env"
{
  echo '#!/usr/bin/env bash'
  printf 'STUB_LOG=%q\nSTUB_SLEEP=%q\nSTUB_STOP_PID=%q\nSTUB_SLOTS_DIR=%q\n' \
    "$STUB_LOG" "$STUB_SLEEP" "$STUB_STOP_PID" "$FORGE_SLOTS_DIR"
  printf '. %q\n' "$WORK/stub.env"
} > "$WORK/bin/forge"
cat >> "$WORK/bin/forge" <<'STUB'
# Stub forge for test-invariant-viair-gate.sh. Logs `<sub>|slots=<held slots>|anc=<timeout|none>|<argv>`.
sub="${1:-}"
slots=0
for _p in "$STUB_SLOTS_DIR"/slot-*/pid; do [ -s "$_p" ] && slots=$((slots + 1)); done
anc="none"
_p="$PPID"
while [ -n "$_p" ] && [ "$_p" -gt 1 ] && [ "$_p" != "${STUB_STOP_PID:-1}" ]; do
  case "$(ps -o comm= -p "$_p" 2>/dev/null)" in timeout) anc="timeout" ;; esac
  _p="$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')"
done
printf '%s|slots=%s|anc=%s|%s\n' "$sub" "$slots" "$anc" "$*" >> "$STUB_LOG"
cp_dir="${STUB_CACHE_PATH:-cache_forge}"
out_dir="${STUB_OUT:-out}"
case "$sub" in
  config)
    [ -n "${STUB_CONFIG_FAIL:-}" ] && { echo "stub: config failed" >&2; exit 1; }
    [ -n "${STUB_CONFIG_RAW:-}" ] && { printf '%s\n' "$STUB_CONFIG_RAW"; exit 0; }
    printf '{"src": "src", "via_ir": %s, "cache": true, "cache_path": "%s", "out": "%s"}\n' \
      "${STUB_VIA_IR:-false}" "$cp_dir" "$out_dir"
    exit 0 ;;
  build)
    # A warm cache (the stub's own marker) compiles nothing.
    if [ -f "$cp_dir/solidity-files-cache.json" ] && [ "$(cat "$cp_dir/solidity-files-cache.json")" = "stub-cache" ]; then
      exit 0
    fi
    "$STUB_SLEEP" "${STUB_BUILD_S:-0}"
    if [ -z "${STUB_NO_WRITE:-}" ]; then
      mkdir -p "$cp_dir" "$out_dir"
      printf 'stub-cache' > "$cp_dir/solidity-files-cache.json"
      printf 'artifact' > "$out_dir/A.json"
    fi
    exit "${STUB_BUILD_RC:-0}" ;;
  test)
    is_json=0
    for _a in "$@"; do [ "$_a" = "--json" ] && is_json=1; done
    [ "$is_json" -eq 0 ] && exit 0
    # A scratch dir left in the run dir, as a gate SIGKILLed at its bound leaves it (cwd = the staged repo).
    [ -n "${STUB_PLANT:-}" ] && mkdir -p "../.gate-tmp.planted" && : > "../.gate-tmp.planted/out.json"
    "$STUB_SLEEP" "${STUB_TEST_S:-0}"
    if [ "${STUB_TEST_MODE:-clean}" = "compilefail" ]; then
      printf 'Compiler run failed\nError (7920): Identifier not found or not unique.\n' >&2
      exit 1
    fi
    printf '%s\n' '{"test/Inv.t.sol:InvTest":{"test_results":{"invariant_property()":{"status":"Success"}}}}'
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/forge"
STUBPATH="$WORK/bin:$PATH"

# A minimal foundry project used as the --source-repo / staged-repo template.
SRC="$WORK/src-project"
mkdir -p "$SRC/src" "$SRC/test"
printf '[profile.default]\nsrc = "src"\nout = "out"\n' > "$SRC/foundry.toml"
printf 'contract Vault {}\n' > "$SRC/src/Vault.sol"
printf 'contract OldTest {}\n' > "$SRC/test/Old.t.sol"

mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
fact() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1; }
# stage <name> [template]: a fresh copy of the template project (the per-cell staged repo).
stage() { rm -rf "${WORK:?}/$1"; cp -R "${2:-$SRC}" "$WORK/$1"; }
# prebuild <repo> <warm-dir> [extra shim args...]: run the shim with the stub forge, stdout = facts.
prebuild() {
    _pr_repo="$1"; _pr_warm="$2"; shift 2
    PATH="$STUBPATH" bash "$SHIM" --repo "$_pr_repo" --source-repo "$SRC" --warm-dir "$_pr_warm" \
        --heartbeat "$_pr_repo.hb" --log "$_pr_repo.log" "$@"
}

# ==========================================================================================================
# Part A -- the prebuild shim (stub forge, CI-safe). A missing shim is a FAIL, never a skip.
# ==========================================================================================================
if [ ! -f "$SHIM" ]; then
    fail "part A prerequisites" "dark-factory/evm-harness/forge-prebuild.sh does not exist (#2353)"
else
    # --- prebuild_nonviair_noop -------------------------------------------------------------------------------
    stage a1; : > "$STUB_LOG"
    out="$(STUB_VIA_IR=false prebuild "$WORK/a1" "$WORK/warm-a1" 2>/dev/null)"
    if [ "$out" = "via_ir=0" ] && ! grep -q '^build|' "$STUB_LOG" && grep -q '^config|' "$STUB_LOG" \
       && [ ! -e "$WORK/warm-a1" ] && [ ! -e "$WORK/a1.hb" ] && [ ! -e "$WORK/a1.log" ]; then
        pass "prebuild_nonviair_noop: via_ir=0, no build, no warm dir / heartbeat / log"
    else
        fail "prebuild_nonviair_noop" "out='$out' calls=$(tr '\n' ';' < "$STUB_LOG")"
    fi

    # --- prebuild_detection_uses_forge_config -----------------------------------------------------------------
    stage a2; : > "$STUB_LOG"
    printf '# via_ir = true\n[profile.ci]\nvia_ir = true\n' >> "$WORK/a2/foundry.toml"
    out="$(STUB_VIA_IR=false prebuild "$WORK/a2" "$WORK/warm-a2" 2>/dev/null)"
    if [ "$out" = "via_ir=0" ] && ! grep -q '^build|' "$STUB_LOG" && [ ! -e "$WORK/warm-a2" ]; then
        pass "prebuild_detection_uses_forge_config: a via_ir mention in a comment / other profile is a no-op"
    else
        fail "prebuild_detection_uses_forge_config" "out='$out'"
    fi

    # --- prebuild_config_failure_is_noop ----------------------------------------------------------------------
    c_fail=""
    stage a3
    out="$(STUB_CONFIG_FAIL=1 prebuild "$WORK/a3" "$WORK/warm-a3" 2>"$WORK/a3.err")"
    { [ "$out" = "via_ir=0" ] && [ -s "$WORK/a3.err" ]; } || c_fail="$c_fail config-rc($out)"
    out="$(STUB_CONFIG_RAW='not json at all' prebuild "$WORK/a3" "$WORK/warm-a3" 2>"$WORK/a3.err")"
    { [ "$out" = "via_ir=0" ] && [ -s "$WORK/a3.err" ]; } || c_fail="$c_fail non-json($out)"
    mkdir -p "$WORK/emptybin"
    if [ -z "$(PATH="$WORK/emptybin:/usr/bin:/bin" command -v forge 2>/dev/null)" ]; then
        out="$(PATH="$WORK/emptybin:/usr/bin:/bin" bash "$SHIM" --repo "$WORK/a3" --source-repo "$SRC" \
            --warm-dir "$WORK/warm-a3" --heartbeat "$WORK/a3.hb" --log "$WORK/a3.log" 2>"$WORK/a3.err")"
        { [ "$out" = "via_ir=0" ] && [ -s "$WORK/a3.err" ]; } || c_fail="$c_fail no-forge($out)"
    fi
    [ ! -e "$WORK/warm-a3" ] || c_fail="$c_fail warm-dir-created"
    if [ -z "$c_fail" ]; then
        pass "prebuild_config_failure_is_noop: failing / non-JSON forge config and no forge => via_ir=0 + stderr note"
    else
        fail "prebuild_config_failure_is_noop" "$c_fail"
    fi

    # --- prebuild_cold_publishes_record -----------------------------------------------------------------------
    stage a4; : > "$STUB_LOG"
    W4="$WORK/warm-a4"
    out="$(STUB_VIA_IR=true STUB_BUILD_S=2 prebuild "$WORK/a4" "$W4" 2>/dev/null)"
    cold="$(fact "$out" cold_build_ms)"
    rec_name="$(cat "$W4"/*/complete 2>/dev/null | head -1)"
    rec_dir="$(dirname "$(find "$W4" -name complete 2>/dev/null | head -1)")/$rec_name"
    rec_ls="$( (cd "$rec_dir" 2>/dev/null && find . -mindepth 1 -maxdepth 1 | sort | tr '\n' ' ') )"
    if [ "$(fact "$out" via_ir)" = 1 ] && [ "$(fact "$out" warm_hit)" = 0 ] && [ "$(fact "$out" prebuild_rc)" = 0 ] \
       && [ "${cold:-0}" -ge 2000 ] && [ "${cold:-0}" -lt 4000 ] \
       && [ "$rec_ls" = "./cold-build-ms ./out ./solidity-files-cache.json " ] \
       && [ "$(cat "$rec_dir/cold-build-ms")" = "$cold" ] \
       && grep -q '^build|slots=1|anc=timeout|.*--skip test/Old.t.sol' "$STUB_LOG" \
       && [ -e "$WORK/a4.log" ]; then
        pass "prebuild_cold_publishes_record: warm_hit=0, cold_build_ms=$cold, record = cache json + out/ + cold-build-ms"
    else
        fail "prebuild_cold_publishes_record" "out='$(printf '%s' "$out" | tr '\n' ' ')' rec='$rec_ls' calls=$(tr '\n' ';' < "$STUB_LOG")"
    fi

    # --- prebuild_warm_import ---------------------------------------------------------------------------------
    stage a5; : > "$STUB_LOG"
    out="$(STUB_VIA_IR=true STUB_BUILD_S=2 prebuild "$WORK/a5" "$W4" 2>/dev/null)"
    if [ "$(fact "$out" warm_hit)" = 1 ] && [ "$(fact "$out" cold_build_ms)" = "$cold" ] \
       && [ "$(fact "$out" prebuild_ms)" -lt 2000 ] && [ "$(fact "$out" prebuild_rc)" = 0 ] \
       && grep -q '^build|slots=0|' "$STUB_LOG" && [ "$(cat "$WORK/a5/out/A.json")" = "artifact" ]; then
        pass "prebuild_warm_import: warm_hit=1, recorded cold_build_ms kept, fast verification build without a forge slot"
    else
        fail "prebuild_warm_import" "out='$(printf '%s' "$out" | tr '\n' ' ')' calls=$(tr '\n' ';' < "$STUB_LOG")"
    fi

    # --- prebuild_excludes_invariant_failures -----------------------------------------------------------------
    stage a6
    mkdir -p "$WORK/a6/cache/invariant/failures/InvariantTest"
    printf 'stale failure\n' > "$WORK/a6/cache/invariant/failures/InvariantTest/invariant_x"
    STUB_VIA_IR=true STUB_CACHE_PATH=cache prebuild "$WORK/a6" "$WORK/warm-a6" >/dev/null 2>&1
    stage a6b
    out="$(STUB_VIA_IR=true STUB_CACHE_PATH=cache prebuild "$WORK/a6b" "$WORK/warm-a6" 2>/dev/null)"
    if [ "$(fact "$out" warm_hit)" = 1 ] && [ -f "$WORK/a6b/cache/solidity-files-cache.json" ] \
       && [ ! -e "$WORK/a6b/cache/invariant" ] && [ -z "$(find "$WORK/warm-a6" -path '*invariant*' 2>/dev/null)" ]; then
        pass "prebuild_excludes_invariant_failures: the warm transfer never carries cache/invariant"
    else
        fail "prebuild_excludes_invariant_failures" "out='$(printf '%s' "$out" | tr '\n' ' ')' imported=$(find "$WORK/a6b/cache" | tr '\n' ' ')"
    fi

    # --- prebuild_concurrent_publish --------------------------------------------------------------------------
    stage a7a; stage a7b
    ( STUB_VIA_IR=true STUB_BUILD_S=1 prebuild "$WORK/a7a" "$WORK/warm-a7" > "$WORK/a7a.out" 2>/dev/null ) &
    _j1=$!
    ( STUB_VIA_IR=true STUB_BUILD_S=1 prebuild "$WORK/a7b" "$WORK/warm-a7" > "$WORK/a7b.out" 2>/dev/null ) &
    _j2=$!
    wait "$_j1" "$_j2"
    n_complete="$(find "$WORK/warm-a7" -name complete | wc -l | tr -d ' ')"
    n_rec="$(find "$WORK/warm-a7" -mindepth 2 -maxdepth 2 -name 'rec.*' | wc -l | tr -d ' ')"
    stage a7c
    out="$(STUB_VIA_IR=true prebuild "$WORK/a7c" "$WORK/warm-a7" 2>/dev/null)"
    named="$(cat "$(find "$WORK/warm-a7" -name complete | head -1)" 2>/dev/null)"
    if [ "$n_complete" = 1 ] && [ "$n_rec" = 1 ] && [ -d "$(dirname "$(find "$WORK/warm-a7" -name complete | head -1)")/$named" ] \
       && [ "$(fact "$out" warm_hit)" = 1 ]; then
        pass "prebuild_concurrent_publish: one complete claim wins, the loser's record is removed, a third run is warm"
    else
        fail "prebuild_concurrent_publish" "complete=$n_complete rec=$n_rec third='$(printf '%s' "$out" | tr '\n' ' ')'"
    fi

    # --- prebuild_dangling_record -----------------------------------------------------------------------------
    stage a8
    _kdir="$(dirname "$(find "$W4" -name complete | head -1)")"
    printf 'rec.999999999\n' > "$_kdir/complete.tmp" && mv "$_kdir/complete.tmp" "$_kdir/complete"
    out="$(STUB_VIA_IR=true prebuild "$WORK/a8" "$W4" 2>/dev/null)"
    named="$(cat "$_kdir/complete" 2>/dev/null)"
    if [ "$(fact "$out" warm_hit)" = 0 ] && [ "$named" != "rec.999999999" ] && [ -n "$named" ] && [ -d "$_kdir/$named" ]; then
        pass "prebuild_dangling_record: a complete naming a deleted record is removed, the cell builds cold and republishes"
    else
        fail "prebuild_dangling_record" "out='$(printf '%s' "$out" | tr '\n' ' ')' complete='$named'"
    fi

    # --- prebuild_bounded -------------------------------------------------------------------------------------
    if command -v timeout >/dev/null 2>&1; then
        stage a9
        _t0="$(date +%s)"
        out="$(DF_FORGE_PREBUILD_MAX_S=1 STUB_VIA_IR=true STUB_BUILD_S=5 prebuild "$WORK/a9" "$WORK/warm-a9" 2>/dev/null)"
        _el=$(( $(date +%s) - _t0 ))
        if [ "$_el" -lt 4 ] && [ "$(fact "$out" prebuild_rc)" = 124 ] && [ "$(fact "$out" cold_build_ms)" = 0 ] \
           && [ -z "$(find "$WORK/warm-a9" -name complete 2>/dev/null)" ]; then
            pass "prebuild_bounded: DF_FORGE_PREBUILD_MAX_S=1 stops a 5 s build within ${_el}s, rc 124, nothing published"
        else
            fail "prebuild_bounded" "elapsed=${_el}s out='$(printf '%s' "$out" | tr '\n' ' ')'"
        fi
    else
        skip "prebuild_bounded (no coreutils timeout on PATH)"
    fi

    # --- prebuild_heartbeat -----------------------------------------------------------------------------------
    stage a10
    ( DF_FORGE_HEARTBEAT_S=1 STUB_VIA_IR=true STUB_BUILD_S=3 prebuild "$WORK/a10" "$WORK/warm-a10" >/dev/null 2>&1 ) &
    _j=$!
    : > "$WORK/a10.mt"
    while kill -0 "$_j" 2>/dev/null; do
        [ -e "$WORK/a10.hb" ] && mtime_of "$WORK/a10.hb" >> "$WORK/a10.mt"
        "$STUB_SLEEP" 0.2
    done
    wait "$_j"
    n_mt="$(sort -u "$WORK/a10.mt" | grep -c . || true)"
    if [ "${n_mt:-0}" -ge 3 ]; then
        pass "prebuild_heartbeat: the heartbeat mtime advanced $((n_mt - 1)) times during a 3 s build"
    else
        fail "prebuild_heartbeat" "distinct heartbeat mtimes=${n_mt:-0} (want >= 3)"
    fi

    # --- prebuild_heartbeat_dies_with_parent ------------------------------------------------------------------
    if command -v timeout >/dev/null 2>&1; then
        mkdir -p "$WORK/hbk"
        stage hbk/repo
        DF_FORGE_HEARTBEAT_S=1 STUB_VIA_IR=true STUB_BUILD_S=30 PATH="$STUBPATH" bash "$SHIM" \
            --repo "$WORK/hbk/repo" --source-repo "$SRC" --warm-dir "$WORK/hbk/warm" \
            --heartbeat "$WORK/hbk/hb" --log "$WORK/hbk/log" >/dev/null 2>&1 &
        _sp=$!
        for _i in $(seq 1 50); do [ -n "$(procs_under "$STUB_SLEEP 30")" ] && break; "$STUB_SLEEP" 0.1; done
        kill -KILL "$_sp" 2>/dev/null
        wait "$_sp" 2>/dev/null
        "$STUB_SLEEP" 3
        left="$(procs_under "$STUB_SLEEP 30"; procs_under "$WORK/hbk/")"
        if [ -z "$left" ]; then
            pass "prebuild_heartbeat_dies_with_parent: after SIGKILL no heartbeat loop and no build child survive 3 s"
        else
            fail "prebuild_heartbeat_dies_with_parent" "left: $(printf '%s' "$left" | tr '\n' ';')"
        fi
    else
        skip "prebuild_heartbeat_dies_with_parent (no coreutils timeout on PATH)"
    fi

    # --- prebuild_rejects_outside_paths (+ out = "." ) --------------------------------------------------------
    o_fail=""
    n_rec_before="$(find "$W4" -mindepth 2 -maxdepth 2 -name 'rec.*' | wc -l | tr -d ' ')"
    for spec in "../escape-cache|out" "cache_forge|/$WORK/abs-out" "cache_forge|sub/../../escape-out" "cache_forge|." "cache_forge|./"; do
        _cp="${spec%%|*}"; _od="${spec#*|}"
        stage a11
        # A valid record for this key exists (from a4/a8), so only the path check can stop the import.
        out="$(STUB_VIA_IR=true STUB_NO_WRITE=1 STUB_CACHE_PATH="$_cp" STUB_OUT="$_od" prebuild "$WORK/a11" "$W4" 2>"$WORK/a11.err")"
        [ "$(fact "$out" warm_hit)" = 0 ] || o_fail="$o_fail import($spec)"
        [ "$(fact "$out" prebuild_rc)" = 0 ] || o_fail="$o_fail no-build($spec)"
        grep -q '^build|' "$STUB_LOG" || o_fail="$o_fail no-build-call($spec)"
        [ -s "$WORK/a11.err" ] || o_fail="$o_fail no-note($spec)"
        [ ! -e "$WORK/escape-cache" ] && [ ! -e "$WORK/abs-out" ] && [ ! -e "$WORK/escape-out" ] || o_fail="$o_fail escaped($spec)"
        [ -f "$WORK/a11/foundry.toml" ] && [ -f "$WORK/a11/src/Vault.sol" ] || o_fail="$o_fail repo-damaged($spec)"
    done
    n_rec_after="$(find "$W4" -mindepth 2 -maxdepth 2 -name 'rec.*' | wc -l | tr -d ' ')"
    [ "$n_rec_after" = "$n_rec_before" ] || o_fail="$o_fail published($n_rec_before->$n_rec_after)"
    if [ -z "$o_fail" ]; then
        pass "prebuild_rejects_outside_paths: absolute / '..' / '.' cache_path or out => build only, no import, no record"
    else
        fail "prebuild_rejects_outside_paths" "$o_fail"
    fi

    # --- prebuild_symlinked_out -------------------------------------------------------------------------------
    stage a12
    mkdir -p "$WORK/link-target"
    printf 'keep\n' > "$WORK/link-target/keep.txt"
    rm -rf "$WORK/a12/out"; ln -s "$WORK/link-target" "$WORK/a12/out"
    out="$(STUB_VIA_IR=true prebuild "$WORK/a12" "$W4" 2>/dev/null)"
    if [ "$(fact "$out" warm_hit)" = 1 ] && [ ! -L "$WORK/a12/out" ] && [ -f "$WORK/a12/out/A.json" ] \
       && [ "$(find "$WORK/link-target" -mindepth 1)" = "$WORK/link-target/keep.txt" ] && [ "$(cat "$WORK/link-target/keep.txt")" = "keep" ]; then
        pass "prebuild_symlinked_out: a symlinked staged out/ becomes a real dir, the link target is untouched"
    else
        fail "prebuild_symlinked_out" "out='$(printf '%s' "$out" | tr '\n' ' ')' target=$(find "$WORK/link-target" -mindepth 1 | tr '\n' ' ')"
    fi

    # --- prebuild_key_symlink_stable --------------------------------------------------------------------------
    ln -s "$SRC" "$WORK/src-link"
    stage a13
    out="$(STUB_VIA_IR=true PATH="$STUBPATH" bash "$SHIM" --repo "$WORK/a13" --source-repo "$WORK/src-link" \
        --warm-dir "$W4" --heartbeat "$WORK/a13.hb" --log "$WORK/a13.log" 2>/dev/null)"
    n_keys="$(find "$W4" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
    if [ "$(fact "$out" warm_hit)" = 1 ] && [ "$n_keys" = 1 ]; then
        pass "prebuild_key_symlink_stable: a symlinked --source-repo maps to the same warm key"
    else
        fail "prebuild_key_symlink_stable" "warm_hit=$(fact "$out" warm_hit) keys=$n_keys"
    fi

    # --- prebuild_no_test_dir ---------------------------------------------------------------------------------
    stage a14; rm -rf "$WORK/a14/test"; : > "$STUB_LOG"
    out="$(STUB_VIA_IR=true prebuild "$WORK/a14" "$WORK/warm-a14" 2>"$WORK/a14.err")"
    if [ "$(fact "$out" prebuild_rc)" = 0 ] && ! grep -q 'unbound' "$WORK/a14.err" \
       && grep -q '^build|' "$STUB_LOG" && ! grep -q -- '--skip' "$STUB_LOG"; then
        pass "prebuild_no_test_dir: no test/ dir => empty skip set, clean build"
    else
        fail "prebuild_no_test_dir" "out='$(printf '%s' "$out" | tr '\n' ' ')' err=$(head -3 "$WORK/a14.err" | tr '\n' ';')"
    fi
fi

# ==========================================================================================================
# Part A -- the gate heartbeat (forge-invariant.sh staged next to gate-budget.txt), stub forge.
# ==========================================================================================================
gate_layout() {  # $1 = rundir; stages the gate + a repo with one invariant harness
    rm -rf "$1"; mkdir -p "$1/repo/test" "$1/repo/src"
    cp "$GATE" "$1/forge-invariant.sh"
    printf '[profile.default]\nsrc = "src"\nout = "out"\n' > "$1/repo/foundry.toml"
    printf 'contract InvTest { function invariant_property() public pure {} }\n' > "$1/repo/test/Inv.t.sol"
}
gate_layout "$WORK/g1"
printf 'via_ir=1\nbase_ms=600000\n' > "$WORK/g1/gate-budget.txt"
( DF_FORGE_HEARTBEAT_S=1 STUB_TEST_S=3 PATH="$STUBPATH" bash "$WORK/g1/forge-invariant.sh" --repo "$WORK/g1/repo" \
    --target "$WORK/g1/repo/test/Inv.t.sol" > "$WORK/g1.out" 2>&1; echo "$?" > "$WORK/g1.rc" ) &
_j=$!
: > "$WORK/g1.mt"
while kill -0 "$_j" 2>/dev/null; do
    [ -e "$WORK/g1/.gate-heartbeat" ] && mtime_of "$WORK/g1/.gate-heartbeat" >> "$WORK/g1.mt"
    "$STUB_SLEEP" 0.2
done
wait "$_j"
n_mt="$(sort -u "$WORK/g1.mt" | grep -c . || true)"
if [ "$(cat "$WORK/g1.rc")" = 0 ] && [ "${n_mt:-0}" -ge 2 ]; then
    pass "gate_heartbeat_optin: .gate-heartbeat advanced during a 3 s stub test (CLEAN kept)"
else
    fail "gate_heartbeat_optin" "rc=$(cat "$WORK/g1.rc") distinct mtimes=${n_mt:-0}; $(tail -3 "$WORK/g1.out" | tr '\n' ';')"
fi

gate_layout "$WORK/g2"
mkdir -p "$WORK/g2tmp"
DF_FORGE_HEARTBEAT_S=1 STUB_TEST_S=2 TMPDIR="$WORK/g2tmp" PATH="$STUBPATH" bash "$WORK/g2/forge-invariant.sh" \
    --repo "$WORK/g2/repo" --target "$WORK/g2/repo/test/Inv.t.sol" > "$WORK/g2.out" 2>&1
g2rc=$?
if [ "$g2rc" = 0 ] && [ ! -e "$WORK/g2/.gate-heartbeat" ] && [ -z "$(find "$WORK/g2tmp" -mindepth 1)" ]; then
    pass "gate_heartbeat_absent_by_default: no gate-budget.txt => no heartbeat file, temp dir still removed on exit"
else
    fail "gate_heartbeat_absent_by_default" "rc=$g2rc hb=$([ -e "$WORK/g2/.gate-heartbeat" ] && echo yes || echo no) tmp=$(find "$WORK/g2tmp" -mindepth 1 | tr '\n' ' ')"
fi

# --- gate_tmpdir_removed_on_timeout: a gate stopped at its bound (coreutils timeout TERMs its process group, the
# prover's graceful path) still removes its scratch dir instead of leaving one behind per stopped attempt.
if command -v timeout >/dev/null 2>&1; then
    gate_layout "$WORK/g3"
    printf 'via_ir=1\nbase_ms=600000\n' > "$WORK/g3/gate-budget.txt"
    mkdir -p "$WORK/g3tmp"
    DF_FORGE_HEARTBEAT_S=1 STUB_TEST_S=30 TMPDIR="$WORK/g3tmp" PATH="$STUBPATH" timeout -k 10 2 bash "$WORK/g3/forge-invariant.sh" \
        --repo "$WORK/g3/repo" --target "$WORK/g3/repo/test/Inv.t.sol" > "$WORK/g3.out" 2>&1
    g3rc=$?
    "$STUB_SLEEP" 1
    if [ "$g3rc" = 124 ] && [ -z "$(find "$WORK/g3tmp" -mindepth 1)" ] && [ -z "$(procs_under "$STUB_SLEEP 30")" ]; then
        pass "gate_tmpdir_removed_on_timeout: a gate stopped by timeout (rc 124) leaves no temp dir and no forge child"
    else
        fail "gate_tmpdir_removed_on_timeout" "rc=$g3rc tmp=$(find "$WORK/g3tmp" -mindepth 1 | tr '\n' ' ') left=$(procs_under "$STUB_SLEEP 30" | tr '\n' ';')"
    fi
else
    skip "gate_tmpdir_removed_on_timeout (no coreutils timeout on PATH)"
fi

# --- gate_tmpdir_in_rundir_when_bounded: a bounded gate keeps its scratch dir in the run dir (`.gate-tmp.*`, swept by
# the runner), so even a SIGKILL at its bound, which runs no trap, leaves nothing in the shared $TMPDIR.
if command -v setsid >/dev/null 2>&1; then
    gate_layout "$WORK/g4"
    printf 'via_ir=1\nbase_ms=600000\n' > "$WORK/g4/gate-budget.txt"
    mkdir -p "$WORK/g4tmp"
    DF_FORGE_HEARTBEAT_S=1 STUB_TEST_S=30 TMPDIR="$WORK/g4tmp" PATH="$STUBPATH" setsid bash "$WORK/g4/forge-invariant.sh" \
        --repo "$WORK/g4/repo" --target "$WORK/g4/repo/test/Inv.t.sol" > "$WORK/g4.out" 2>&1 &
    _gp=$!
    for _i in $(seq 1 50); do [ -n "$(procs_under "$STUB_SLEEP 30")" ] && break; "$STUB_SLEEP" 0.1; done
    in_run="$(find "$WORK/g4" -maxdepth 1 -name '.gate-tmp.*' -type d | grep -c . || true)"
    kill -KILL -- "-$_gp" 2>/dev/null
    wait "$_gp" 2>/dev/null
    if [ "$in_run" = 1 ] && [ -z "$(find "$WORK/g4tmp" -mindepth 1)" ]; then
        pass "gate_tmpdir_in_rundir_when_bounded: the bounded gate's scratch dir is <run>/.gate-tmp.*, a SIGKILL leaves nothing in \$TMPDIR"
    else
        fail "gate_tmpdir_in_rundir_when_bounded" "in-run=$in_run tmpdir=$(find "$WORK/g4tmp" -mindepth 1 | tr '\n' ' ')"
    fi
else
    skip "gate_tmpdir_in_rundir_when_bounded (no setsid)"
fi

# --- prebuild_default_max: the DF_FORGE_PREBUILD_MAX_S default is 7200 s (derivation in the shim header).
# shellcheck disable=SC2016  # matching the literal assignment line, $ must not expand
if grep -Fq 'PB_MAX="${DF_FORGE_PREBUILD_MAX_S:-7200}"' "$SHIM" 2>/dev/null \
   && grep -Fq "case \"\$PB_MAX\" in ''|*[!0-9]*|0) PB_MAX=7200 ;; esac" "$SHIM" 2>/dev/null; then
    pass "prebuild_default_max: DF_FORGE_PREBUILD_MAX_S defaults (and falls back) to 7200 s"
else
    fail "prebuild_default_max" "the shim's DF_FORGE_PREBUILD_MAX_S default/fallback is not 7200"
fi

# ==========================================================================================================
# Part A -- DF_INV_GATE_TIMEOUT_MS validation (the runner's block, extracted by its content anchors and eval'd).
# ==========================================================================================================
OVR_BLOCK="$(awk '/^# #2353-GATE-OVERRIDE-BEGIN/{f=1} f{print} /^# #2353-GATE-OVERRIDE-END/{exit}' "$RIH")"
if [ -z "$OVR_BLOCK" ]; then
    fail "override_validation" "no '#2353-GATE-OVERRIDE-BEGIN/END' block in run-invariant-hunt.sh"
else
    ovr() {  # $1 = value (or the literal word UNSET) -> "<GATE_OVERRIDE_MS>|<warned 0/1>"
        (
          if [ "$1" = UNSET ]; then unset DF_INV_GATE_TIMEOUT_MS; else export DF_INV_GATE_TIMEOUT_MS="$1"; fi
          eval "$OVR_BLOCK" 2>"$WORK/ovr.err"
          printf '%s|%s' "${GATE_OVERRIDE_MS:-}" "$([ -s "$WORK/ovr.err" ] && echo 1 || echo 0)"
        )
    }
    v_fail=""
    nl='
'
    for bad in abc -1 05000 " 5000" "5000 " "5000$nl" "５０００" "٥٠٠٠" 12345678901 "1e3" "+5"; do
        got="$(ovr "$bad")"
        [ "$got" = "|1" ] || v_fail="$v_fail [$bad]->$got"
    done
    got="$(ovr 0)";          [ "$got" = "|0" ] || v_fail="$v_fail [0]->$got"
    got="$(ovr "")";         [ "$got" = "|0" ] || v_fail="$v_fail [empty]->$got"
    got="$(ovr UNSET)";      [ "$got" = "|0" ] || v_fail="$v_fail [unset]->$got"
    got="$(ovr 1)";          [ "$got" = "1|0" ] || v_fail="$v_fail [1]->$got"
    got="$(ovr 9999999999)"; [ "$got" = "9999999999|0" ] || v_fail="$v_fail [9999999999]->$got"
    if [ -z "$v_fail" ]; then
        pass "override_validation: ASCII 1-10 digits without a leading zero accepted; 0/empty = off; everything else warned + ignored"
    else
        fail "override_validation" "$v_fail"
    fi
fi

# ==========================================================================================================
# Part B -- the REAL runner -> agentis go invariant-prover.ag path with the stub forge (needs agentis).
# ==========================================================================================================
if ! command -v agentis >/dev/null 2>&1; then
    skip "part B (agentis not on PATH): e2e_override_kills_gate, e2e_override_generous_clean, e2e_viair_derived_bound, e2e_nonviair_byte_identical, e2e_runner_sweeps_gate_tmp, e2e_repair_rounds_bounded"
else
    E2E_SRC="$WORK/e2e-src"
    mkdir -p "$E2E_SRC/src"
    printf '[profile.default]\nsrc = "src"\nout = "out"\n' > "$E2E_SRC/foundry.toml"
    printf 'contract Vault {}\n' > "$E2E_SRC/src/Vault.sol"
    # The fixture imports the in-scope target: the prover arms the #1471 link gate with its basename.
    printf '%s\n' '// SPDX-License-Identifier: MIT' 'pragma solidity ^0.8.20;' 'import {Vault} from "../src/Vault.sol";' \
        'contract InvTest { function invariant_property() public pure {} }' > "$WORK/e2e-fixture.t.sol"
    # run_e2e <out> [VAR=value ...] -- [runner flags...]; the runner's stdout+stderr land in <out>.log.
    run_e2e() {
        _e_out="$1"; shift
        _e_env=()
        while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do _e_env+=("$1"); shift; done
        [ "${1:-}" = "--" ] && shift
        rm -rf "$_e_out"
        : > "$WORK/stub.env"
        for _kv in ${_e_env[@]+"${_e_env[@]}"}; do printf 'export %s\n' "$_kv" >> "$WORK/stub.env"; done
        env PATH="$STUBPATH" ${_e_env[@]+"${_e_env[@]}"} bash "$RIH" --repo "$E2E_SRC" --target Vault.sol:Vault \
            --backend mock --out "$_e_out" --seed 1 "$@" > "$_e_out.log" 2>&1
    }
    cell_log() { cat "$1"/run/invariant_*.log 2>/dev/null; }
    last_marker() { cell_log "$1" | grep 'INVARIANT|' | tail -1; }

    # --- e2e_override_kills_gate ------------------------------------------------------------------------------
    : > "$STUB_LOG"
    run_e2e "$WORK/b1" DF_INV_GATE_TIMEOUT_MS=1500 STUB_TEST_S=4 -- --handler-fixture "$WORK/e2e-fixture.t.sol"
    b1rc=$?
    "$STUB_SLEEP" 1
    if [ "$b1rc" = 0 ] && cell_log "$WORK/b1" | grep -q '^GATE-BOUND|Vault.sol:Vault|1500|override|' \
       && cell_log "$WORK/b1" | grep -q '^GATE-TIMEOUT|Vault.sol:Vault|1500$' \
       && [ "$(last_marker "$WORK/b1")" = "INVARIANT|Vault.sol:Vault|HARNESS_ERROR" ] \
       && [ -z "$(procs_under "$STUB_SLEEP 4")" ]; then
        pass "e2e_override_kills_gate: DF_INV_GATE_TIMEOUT_MS=1500 stops a 4 s gate => GATE-BOUND, GATE-TIMEOUT, HARNESS_ERROR, no orphan"
    else
        fail "e2e_override_kills_gate" "rc=$b1rc marker='$(last_marker "$WORK/b1")' gate-lines=$(cell_log "$WORK/b1" | grep '^GATE-' | tr '\n' ';') left=$(procs_under "$STUB_SLEEP 4" | tr '\n' ';')"
    fi

    # --- e2e_override_generous_clean --------------------------------------------------------------------------
    run_e2e "$WORK/b2" DF_INV_GATE_TIMEOUT_MS=20000 STUB_TEST_S=4 -- --handler-fixture "$WORK/e2e-fixture.t.sol"
    if [ "$(last_marker "$WORK/b2")" = "INVARIANT|Vault.sol:Vault|CLEAN" ] \
       && cell_log "$WORK/b2" | grep -q '^GATE-BOUND|Vault.sol:Vault|20000|override|' \
       && ! cell_log "$WORK/b2" | grep -q '^GATE-TIMEOUT|'; then
        pass "e2e_override_generous_clean: DF_INV_GATE_TIMEOUT_MS=20000 admits the 4 s gate => CLEAN"
    else
        fail "e2e_override_generous_clean" "marker='$(last_marker "$WORK/b2")' gate-lines=$(cell_log "$WORK/b2" | grep '^GATE-' | tr '\n' ';')"
    fi

    # --- e2e_viair_derived_bound ------------------------------------------------------------------------------
    : > "$STUB_LOG"
    run_e2e "$WORK/b3" STUB_VIA_IR=true STUB_BUILD_S=2 -- --handler-fixture "$WORK/e2e-fixture.t.sol"
    GB="$WORK/b3/run/gate-budget.txt"
    _base="$(sed -n 's/^base_ms=//p' "$GB" 2>/dev/null)"
    _cold="$(sed -n 's/^cold_build_ms=//p' "$GB" 2>/dev/null)"
    _pre="$(sed -n 's/^prebuild_ms=//p' "$GB" 2>/dev/null)"
    _max="${_cold:-0}"; [ "${_pre:-0}" -gt "$_max" ] && _max="$_pre"
    _want=$(( ${_base:-0} + _max ))
    _got="$(cell_log "$WORK/b3" | sed -n 's/^GATE-BOUND|Vault.sol:Vault|\([0-9]*\)|viair|.*/\1/p' | tail -1)"
    _order="$(cut -d'|' -f1 "$STUB_LOG" | awk '!seen[$0]++' | tr '\n' ' ')"
    if [ -n "$_got" ] && [ "$_got" = "$_want" ] && [ "$_got" -gt 600000 ] \
       && [ "$(last_marker "$WORK/b3")" = "INVARIANT|Vault.sol:Vault|CLEAN" ] \
       && [ "$_order" = "config build test " ] && grep -q '^test|slots=.*|anc=timeout|.*--json' "$STUB_LOG"; then
        pass "e2e_viair_derived_bound: GATE-BOUND $_got = base_ms + max(cold_build_ms, prebuild_ms) from gate-budget.txt, CLEAN"
    else
        fail "e2e_viair_derived_bound" "got='$_got' want='$_want' order='$_order' marker='$(last_marker "$WORK/b3")'"
    fi

    # --- e2e_nonviair_byte_identical --------------------------------------------------------------------------
    : > "$STUB_LOG"
    run_e2e "$WORK/b4" STUB_VIA_IR=false -- --handler-fixture "$WORK/e2e-fixture.t.sol"
    if [ ! -e "$WORK/b4/run/gate-budget.txt" ] && ! cell_log "$WORK/b4" | grep -q '^GATE-' \
       && grep -qx 'exec.default_timeout_ms = 600000' "$WORK/b4/run/.agentis/config" \
       && grep -q '^test|slots=.*|anc=none|.*--json' "$STUB_LOG" && ! grep -q '^test|.*anc=timeout' "$STUB_LOG" \
       && [ "$(last_marker "$WORK/b4")" = "INVARIANT|Vault.sol:Vault|CLEAN" ]; then
        pass "e2e_nonviair_byte_identical: no facts file, no GATE- line, config 600000, unbounded gate, CLEAN"
    else
        fail "e2e_nonviair_byte_identical" "facts=$([ -e "$WORK/b4/run/gate-budget.txt" ] && echo yes || echo no) marker='$(last_marker "$WORK/b4")' calls=$(grep '^test' "$STUB_LOG" | cut -d'|' -f1-3 | tr '\n' ';')"
    fi

    # --- e2e_runner_sweeps_gate_tmp ---------------------------------------------------------------------------
    # The stub plants <run>/.gate-tmp.planted while the bounded gate runs (what a gate SIGKILLed at its bound leaves
    # behind); the runner must sweep it once the prover returns.
    run_e2e "$WORK/b6" DF_INV_GATE_TIMEOUT_MS=20000 STUB_PLANT=1 -- --handler-fixture "$WORK/e2e-fixture.t.sol"
    if [ "$(last_marker "$WORK/b6")" = "INVARIANT|Vault.sol:Vault|CLEAN" ] \
       && [ -z "$(find "$WORK/b6/run" -maxdepth 1 -name '.gate-tmp.*')" ]; then
        pass "e2e_runner_sweeps_gate_tmp: a scratch dir left in <run>/.gate-tmp.* is removed after the prover run"
    else
        fail "e2e_runner_sweeps_gate_tmp" "marker='$(last_marker "$WORK/b6")' left=$(find "$WORK/b6/run" -maxdepth 1 -name '.gate-tmp.*' | tr '\n' ' ')"
    fi

    # --- e2e_repair_rounds_bounded ----------------------------------------------------------------------------
    # LLM path (mock backend, no fixture). `--fork-target` without --fork-url leaves the #1471 link gate inert, so
    # the mock's non-Solidity reply reaches forge, which answers `Compiler run failed` every attempt.
    : > "$STUB_LOG"
    run_e2e "$WORK/b5" STUB_VIA_IR=true STUB_TEST_MODE=compilefail -- --repair-rounds 1 \
        --fork-target 0x1111111111111111111111111111111111111111
    n_json="$(grep -c '^test|.*--json' "$STUB_LOG" || true)"
    n_bounded="$(grep -c '^test|slots=[0-9]*|anc=timeout|.*--json' "$STUB_LOG" || true)"
    if [ "$n_json" = 2 ] && [ "$n_bounded" = 2 ] \
       && [ "$(last_marker "$WORK/b5")" = "INVARIANT|Vault.sol:Vault|HARNESS_ERROR" ]; then
        pass "e2e_repair_rounds_bounded: --repair-rounds 1 => exactly 2 gate runs, each under timeout, HARNESS_ERROR"
    else
        fail "e2e_repair_rounds_bounded" "json-runs=$n_json bounded=$n_bounded marker='$(last_marker "$WORK/b5")'"
    fi
fi

: > "$WORK/stub.env"

# ==========================================================================================================
# Part C -- STAGE 4.5 exports DF_FORGE_WARM_DIR=<out>/deep-hunt/.forge-warm (wrapper --agentis stub, CI-safe).
# ==========================================================================================================
if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || [ ! -f "$FIX/agentis-stub.sh" ]; then
    skip "zonehunt_exports_warm_dir (git / python3 / deep-hunt fixture missing)"
else
    ZT="$WORK/zt-target"
    mkdir -p "$ZT"
    cp "$FIX/foundry.toml" "$ZT/foundry.toml"
    cp -R "$FIX/src" "$ZT/src"
    git -C "$ZT" init -q
    git -C "$ZT" config user.email demo@example.invalid
    git -C "$ZT" config user.name "demo"
    git -C "$ZT" add -A
    git -C "$ZT" commit -qm "viair-gate fixture target"
    ZSTUB="$WORK/agentis-stub"
    cp "$FIX/agentis-stub.sh" "$ZSTUB"; chmod +x "$ZSTUB"
    ZWRAP="$WORK/agentis-wrapper"
    cat > "$ZWRAP" <<WRAPEOF
#!/bin/sh
if [ "\${1:-}" = "go" ] && [ "\${2:-}" = "invariant-prover.ag" ]; then
  printf '%s\n' "\${DF_FORGE_WARM_DIR:-unset}" >> "$WORK/zt-capture.txt"
fi
exec "$ZSTUB" "\$@"
WRAPEOF
    chmod +x "$ZWRAP"
    ZB="$WORK/zt-out"
    PATH="$STUBPATH" "$ZONEHUNT" --repo "$ZT" --out "$ZB" --drop-dir "$ZB/drop" --scope-hint src \
        --backend mock --agentis "$ZSTUB" \
        --map-fixture "$FIX/zones.fixture.txt" --brief-fixture "$FIX/briefs.fixture.txt" \
        --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
        --in-scope "the whole in-scope program" > "$WORK/zt-base.log" 2>&1
    zbrc=$?
    PATH="$STUBPATH" "$ZONEHUNT" --repo "$ZT" --out "$ZB" --deep-hunt --deep-hunt-only \
        --invariant-fixture "$FIX/handler-fixture.t.sol" --backend mock --agentis "$ZWRAP" > "$WORK/zt-deep.log" 2>&1
    zdrc=$?
    cap="$(sort -u "$WORK/zt-capture.txt" 2>/dev/null | tr '\n' ' ')"
    if [ "$zbrc" = 0 ] && [ "$zdrc" = 0 ] && [ "$cap" = "$ZB/deep-hunt/.forge-warm " ] && [ ! -e "$ZB/deep-hunt/.forge-warm" ]; then
        pass "zonehunt_exports_warm_dir: STAGE 4.5 exports DF_FORGE_WARM_DIR=<out>/deep-hunt/.forge-warm (not created for a non-viaIR fixture)"
    else
        fail "zonehunt_exports_warm_dir" "base rc=$zbrc deep rc=$zdrc captured='$cap'"
        tail -5 "$WORK/zt-deep.log" | sed 's/^/      /'
    fi
fi

summary_exit
