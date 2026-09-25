#!/usr/bin/env bash
# demo-deep-hunt-budget.sh — proof of #2258 DEEP-HUNT TIME BUDGET: per-cell wall cap, hard zone budget, broken-target
# skip and parallel cells for STAGE 4.5 — four ENV KNOBS, all default OFF (STAGE 4.5 byte-identical when unset):
#   DEEP_HUNT_CELL_TIMEOUT_S  DEEP_HUNT_ZONE_BUDGET_S  DEEP_HUNT_SKIP_BROKEN_TARGET  DEEP_HUNT_JOBS
#
# bash + python3 only (CI-safe): no agentis, no forge, no LLM, no network. The deep engine's prover is a stub --agentis
# keyed on TARGET_FN/TARGET_CLASS (duration, verdict, tail-kill, or a forge-gate call through a FAKE `forge` that
# serves the canned diagnostics in fixtures/deep-hunt-budget/). The stub logs every invocation and keeps a mkdir-style
# max-concurrency probe. Every run uses this demo's own scratch DARK_FACTORY_DIR / FORGE_SLOTS_DIR, never ~/.claude.json
# (the mock backend never pre-trusts; the pre-trust helper is exercised under a temp HOME), and every orphan check
# looks at process PATHS under the scratch dir (ps + awk over ENVIRON, never `pgrep -f`).
#
# PARTS:
#   1  SOURCE GUARDS: knob validation (exit 2), the pass wrapper + hook + gated shim override, additions-only vs
#      origin/main while origin/main predates the scheduler (SKIP otherwise).
#   2  WATCHDOG: wall cap -> 124 in ~2 s; staleness kill still 143/137; three-arg rc preserved; TERM leaves no engine.
#   3  GATE CLASSIFIER: target / harness / mixed / unlocated / warning-in-src scopes; no diag dir or a foreign --repo
#      writes nothing; exit code + banner unchanged.
#   4  TIMEOUT: ledger TIMEOUT, nothing merged, no reach row, never CLEAN, re-run exactly once by --deep-hunt-resume;
#      tail-kill keeps + merges the verdict; a stopped run leaves no orphan engine.
#   5  SKIP: a target-scoped probe skips the target's other lens (never invoked); unset -> it runs; a harness-scoped
#      probe never skips.
#   6  BUDGET: in-flight cell TIMEOUT (zone-budget), later pairs SKIPPED_BUDGET.
#   7  EQUIVALENCE: legacy == JOBS=1 == JOBS=3 on every artifact (PROMISES on); ledger b == c; concurrency 1 vs >= 2;
#      skip under JOBS=3 == under JOBS=1.
#   8  SLOT + FORCED SERIAL: LLM_MAX_CONCURRENT=1 -> concurrency 1 (pool never exported to the engine);
#      --pattern-store -> warning + concurrency 1; legacy --deep-hunt-max-targets 2 (shared run dir) == legacy.
#   9  MUTATIONS on a copied tree: each rule is load-bearing.
#  10  HARD STOP + RESUME: a settled FINDING is merged before a stop (1 job) or merged collect-only by the next resume
#      (3 jobs); a transport-crashed probe is TRANSIENT_ERROR, never a broken target; shared run dirs under
#      --deep-hunt-resume run the sequential loop's cells; a cap never reads a previous run's verdict; a cell TERMed
#      after its verdict is merged by the resume; a TERM inside a collect step never duplicates a ledger row.
#
# Usage: dark-factory/demo-deep-hunt-budget.sh
# Exit: 0 = all assertions hold; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
RZH="$HERE/run-zone-hunt.sh"
GATE="$HERE/evm-harness/forge-invariant.sh"
FIXDIR="$HERE/fixtures/deep-hunt-budget"

FAILS=0
note() { echo "demo-deep-hunt-budget.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for f in "$RZH" "$GATE" "$HERE/lib/cell-watchdog.sh" "$HERE/lib/deep-hunt-sched.sh" "$HERE/lib/deep-hunt-cell.sh" \
         "$FIXDIR/target.stdout" "$FIXDIR/failed.stderr"; do
  [ -f "$f" ] || { note "missing prerequisite: $f" >&2; exit 3; }
done
command -v python3 >/dev/null 2>&1 || { note "python3 not installed — skipping"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-deep-hunt-budget.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
# procs_under PATTERN — pid + args of every process whose args contain PATTERN. The pattern travels through the
# environment, never argv, so the awk process can never match itself.
procs_under() { ps -eo pid=,args= 2>/dev/null | DHB_PAT="$1" awk 'index($0, ENVIRON["DHB_PAT"]) > 0'; }
cleanup() {
  procs_under "$WORK/" | awk '{print $1}' | while read -r _p; do kill -KILL "$_p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# Scratch state only — never the operator's ~/.dark-factory; no knob leaks in from the caller's environment.
export DARK_FACTORY_DIR="$WORK/dfdir" FORGE_SLOTS_DIR="$WORK/forge-slots" DEEP_CELL_POLL_S=1 FORGE_MAX_SLOTS=4
unset DEEP_HUNT_CELL_TIMEOUT_S DEEP_HUNT_ZONE_BUDGET_S DEEP_HUNT_SKIP_BROKEN_TARGET DEEP_HUNT_JOBS \
      DEEP_HUNT_REACH DEEP_HUNT_PROMISES AGENTIS_LLM_SLOTS_DIR LLM_MAX_CONCURRENT LLM_SLOT_WAIT_S

# A copy of `sleep` under the scratch dir, so a lingering sleeper is findable by PATH.
mkdir -p "$WORK/bin" "$WORK/fbin"
cp "$(command -v sleep)" "$WORK/bin/dh-sleep"
export STUB_SLEEP="$WORK/bin/dh-sleep"

# A FAKE forge: the --json run prints the canned diagnostic $FAKE_FORGE_OUT (and the terse stderr of a failed
# compile unless it is the compiled fixture); the gate's human re-run is a silent no-op.
cat > "$WORK/fbin/forge" <<'FORGE'
#!/bin/sh
is_json=0
for a in "$@"; do [ "$a" = "--json" ] && is_json=1; done
[ "$is_json" -eq 0 ] && exit 0
cat "${FAKE_FORGE_OUT:?}"
case "$FAKE_FORGE_OUT" in *compiled.stdout) exit 0 ;; esac
cat "${FAKE_FORGE_ERR:?}" >&2
exit 1
FORGE
chmod +x "$WORK/fbin/forge"
export FAKE_FORGE_ERR="$FIXDIR/failed.stderr" FIXDIR

# ================================================================================================
# The fixture repo: one value-custody zone, 3 concrete contracts (REACH picks all 3), 2 lenses (C10 + C2).
REPO="$WORK/repo"
mkdir -p "$REPO/src/vault"
printf '[profile.default]\nsrc = "src"\ntest = "test"\n' > "$REPO/foundry.toml"
{
  echo "// SPDX-License-Identifier: MIT"; echo "pragma solidity ^0.8.20;"
  i=0; while [ "$i" -lt 30 ]; do echo "// padding line $i (VaultA is the largest file)"; i=$((i + 1)); done
  echo "contract VaultA {"
  echo "    uint256 public held;"
  echo "    function depositA(uint256 a) external { held += a; }"
  echo "    function withdrawA(uint256 a) external { held -= a; }"
  echo "}"
} > "$REPO/src/vault/VaultA.sol"
for n in B C; do
  {
    echo "// SPDX-License-Identifier: MIT"; echo "pragma solidity ^0.8.20;"
    echo "contract Vault$n {"
    echo "    uint256 public held;"
    echo "    function deposit$n(uint256 a) external { held += a; }"
    echo "}"
  } > "$REPO/src/vault/Vault$n.sol"
done

# The stub --agentis. Its prover branch reads a spec line `<Contract>|<class>|<seconds>|<mode>|<verdict>` (first
# match, `*` wildcards) from $STUB_SPEC. Modes: normal (sleep, then the verdict), tail (the verdict, then sleep),
# forge-<fixture> (sleep, write a harness and run the REAL staged forge-invariant.sh through the fake forge on PATH),
# ftrans-<fixture> (the same forge attempt, then a flat-cyborg transport crash and no verdict — the #2045 shape).
STUB="$WORK/stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
cmd="${1:-}"; sub="${2:-}"
case "$cmd" in
  init) mkdir -p .agentis; exit 0 ;;
  memo) exit 0 ;;
  go)
    case "$sub" in
      zone-mapper.ag) echo "ZONE-CLASS|C10"; exit 0 ;;
      hunter.ag) echo "SAFE"; exit 0 ;;
      refuter.ag)
        [ -n "${STUB_REFUTE_FLAG:-}" ] && : > "$STUB_REFUTE_FLAG"
        [ -n "${STUB_REFUTE_SLEEP:-}" ] && "${STUB_SLEEP:-sleep}" "$STUB_REFUTE_SLEEP"
        echo "VERDICT|REAL|${CAND_FILE_FN:-}|${CAND_CLASS:-}|survived"; exit 0 ;;
      invariant-prover.ag)
        tf="${TARGET_FN:-}"; cl="${TARGET_CLASS:-}"
        name="${tf##*:}"; name="${name##*/}"; name="${name%.sol}"
        rd="${INV_REPO%/repo}"
        [ -n "${STUB_LOG:-}" ] && echo "$name|$cl" >> "$STUB_LOG"
        [ -n "${STUB_ENVLOG:-}" ] && echo "${AGENTIS_LLM_SLOTS_DIR:-unset}" >> "$STUB_ENVLOG"
        spec="$(grep -E "^($name|\*)\|($cl|\*)\|" "${STUB_SPEC:-/dev/null}" 2>/dev/null | head -1)"
        dur="$(echo "$spec" | cut -d'|' -f3)"; mode="$(echo "$spec" | cut -d'|' -f4)"; verd="$(echo "$spec" | cut -d'|' -f5)"
        [ -n "$dur" ] || dur=0.2; [ -n "$mode" ] || mode=normal; [ -n "$verd" ] || verd=CLEAN
        if [ -n "${STUB_PROBE:-}" ]; then
          : > "$STUB_PROBE/run.$$"
          ls "$STUB_PROBE"/run.* 2>/dev/null | wc -l | tr -d ' ' >> "$STUB_PROBE/counts"
        fi
        emit() {
          if [ -s "$rd/entry-points.tsv" ]; then
            echo "HANDLER-COVERAGE|$tf|covered=2|total=2|required=2|mode=typed|ok|reask=0"
          fi
          if [ -s "$rd/promise-sources.txt" ]; then
            echo "PROMISES|$tf|emitted=1|accepted=1|dropped=0|overcap=0|source=llm"
            echo "PROMISE-ACCEPTED|#1|held|conservation|held tracks every deposit|src/vault/$name.sol:4"
            echo "PROMISE-COVERAGE|$tf|covered=1|total=1|ok|reask=0"
          fi
          echo "INVARIANT|$tf|$verd"
          if [ "$verd" = FINDING ]; then echo "STEP|deposit$name(1)"; echo "STEP|withdraw$name(2)"; fi
        }
        case "$mode" in
          tail) emit; "${STUB_SLEEP:-sleep}" "$dur" ;;
          ftrans-*)
            "${STUB_SLEEP:-sleep}" "$dur"
            mkdir -p "$(dirname "$INV_OUT")"
            printf 'contract InvTest {\n    function invariant_x() public {}\n}\n' > "$INV_OUT"
            FAKE_FORGE_OUT="$FIXDIR/${mode#ftrans-}.stdout" bash "$FORGE_INVARIANT" --repo "$INV_REPO" --target "$INV_OUT" >/dev/null 2>&1
            echo "LLM transport error: flat-cyborg exited (exit status: 75)" ;;
          forge-*)
            "${STUB_SLEEP:-sleep}" "$dur"
            mkdir -p "$(dirname "$INV_OUT")"
            printf 'contract InvTest {\n    function invariant_x() public {}\n}\n' > "$INV_OUT"
            FAKE_FORGE_OUT="$FIXDIR/${mode#forge-}.stdout" bash "$FORGE_INVARIANT" --repo "$INV_REPO" --target "$INV_OUT" >/dev/null 2>&1
            echo "INVARIANT|$tf|HARNESS_ERROR" ;;
          *) "${STUB_SLEEP:-sleep}" "$dur"; emit ;;
        esac
        [ -n "${STUB_PROBE:-}" ] && rm -f "$STUB_PROBE/run.$$"
        exit 0 ;;
      coordinator.ag) exit 0 ;;
      *) echo "SAFE"; exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

MAPFIX="$WORK/mapfix.txt"
printf 'ZONE|src_vault|vault|C10,C2|value-custody vault family\nCUSTODY|src_vault|true\n' > "$MAPFIX"

# lens_only RZH OUT [flags...] — a --deep-hunt-only pass over a fresh copy of the breadth base (env from the caller).
lens_only() {
  _lo_rzh="$1"; _lo_out="$2"; shift 2
  rm -rf "$_lo_out"; cp -R "$DBASE" "$_lo_out"
  PATH="$WORK/fbin:$PATH" "$_lo_rzh" --repo "$REPO" --out "$_lo_out" --deep-hunt --deep-hunt-only \
    --backend mock --agentis "$STUB" "$@" >"$_lo_out.log" 2>&1
}
spec() { printf '%s\n' "$@" > "$WORK/spec"; }
export STUB_SPEC="$WORK/spec"
status_of() { awk -F'\t' -v t="$2" -v c="$3" '$2 == t && $3 == c { s = $4 } END { print s }' "$1/deep-hunt/cell-status.tsv" 2>/dev/null; }
reason_of() { awk -F'\t' -v t="$2" -v c="$3" '$2 == t && $3 == c { s = $5 } END { print s }' "$1/deep-hunt/cell-status.tsv" 2>/dev/null; }
maxconc() { sort -n "$1/counts" 2>/dev/null | tail -1; }
findings_of() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get("verified",d) if isinstance(d,dict) else d; print(sum(1 for f in v if isinstance(f,dict) and f.get("source")=="invariant-hunt"))' "$1/verify/verified_findings.json" 2>/dev/null; }

# ================================================================================================
note "0) building the offline breadth base ..."
DBASE="$WORK/dbase"
"$RZH" --repo "$REPO" --out "$DBASE" --drop-dir "$DBASE/drop" --scope-hint src/vault --backend mock --agentis "$STUB" \
  --map-fixture "$MAPFIX" --pass-fixture "scope=in;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" >"$WORK/dbase.log" 2>&1
if [ ! -f "$DBASE/map/zones.json" ] || [ ! -f "$DBASE/verify/verified_findings.json" ]; then
  bad "the offline breadth base did not build:"; sed -n '1,20p' "$WORK/dbase.log" | sed 's/^/      /'
  note "FAIL — cannot continue without the breadth base"; exit 1
fi
ok "breadth base built"

# ================================================================================================
note "1) SOURCE GUARDS ..."
g_fail=""
# shellcheck disable=SC2016  # literal source lines, no expansion wanted
for want in 'DEEP_HUNT_CELL_TIMEOUT_S="${DEEP_HUNT_CELL_TIMEOUT_S:-}"' 'DEEP_HUNT_ZONE_BUDGET_S="${DEEP_HUNT_ZONE_BUDGET_S:-}"' \
            'DEEP_HUNT_SKIP_BROKEN_TARGET="${DEEP_HUNT_SKIP_BROKEN_TARGET:-}"' 'DEEP_HUNT_JOBS="${DEEP_HUNT_JOBS:-}"' \
            '    while dh_pass_begin; do' '    dh_pass_end' \
            '      dh_note_row "$ZID" "$RELFILE" "$DCLASS" "${AUXFILES:-}" "$REACH_NAME" "$DZOUT"' \
            '    . "$HERE/lib/deep-hunt-sched.sh"' '    dh_sched_init'; do
  grep -qxF -- "$want" "$RZH" || g_fail="$g_fail [missing: $want]"
done
# The shim override sits in dh_sched_init AFTER the inactive early return (so a default run never swaps $INVHUNT).
awk '/^dh_sched_init\(\) \{/ {f=1} f && /return 0/ && !r {r=NR} f && /INVHUNT="\$DH_HERE\/deep-hunt-cell.sh"/ {o=NR} f && /^}/ {exit}
     END { exit !(r && o && r < o) }' "$HERE/lib/deep-hunt-sched.sh" || g_fail="$g_fail [shim override not gated]"
[ -z "$g_fail" ] && ok "knob defaults, pass wrapper, hook line and the gated shim override are present" || bad "source guards:$g_fail"

v_fail=""
knob_rc() { env "$@" "$RZH" --repo "$REPO" --out "$WORK/g" --deep-hunt --deep-hunt-only --backend mock --agentis "$STUB" >/dev/null 2>&1; echo $?; }
for kv in DEEP_HUNT_CELL_TIMEOUT_S=abc DEEP_HUNT_CELL_TIMEOUT_S=-1 DEEP_HUNT_CELL_TIMEOUT_S=05 DEEP_HUNT_ZONE_BUDGET_S=1m \
          DEEP_HUNT_SKIP_BROKEN_TARGET=2 DEEP_HUNT_JOBS=9 DEEP_HUNT_JOBS=x; do
  [ "$(knob_rc "$kv")" = 2 ] || v_fail="$v_fail [$kv not exit 2]"
done
for kv in DEEP_HUNT_CELL_TIMEOUT_S=5 DEEP_HUNT_ZONE_BUDGET_S=5 DEEP_HUNT_SKIP_BROKEN_TARGET=1 DEEP_HUNT_JOBS=2; do
  env "$kv" "$RZH" --repo "$REPO" --out "$WORK/g" --backend mock --agentis "$STUB" --map-fixture "$MAPFIX" >/dev/null 2>&1
  [ "$?" = 2 ] || v_fail="$v_fail [$kv without --deep-hunt not exit 2]"
done
[ -z "$v_fail" ] && ok "malformed values and an active knob without --deep-hunt exit 2" || bad "knob validation:$v_fail"

if git -C "$HERE" cat-file -e origin/main:dark-factory/run-zone-hunt.sh 2>/dev/null; then
  if git -C "$HERE" show origin/main:dark-factory/run-zone-hunt.sh | grep -q 'dh_pass_begin'; then
    skip "origin/main already carries the scheduler wiring (post-merge steady state) — the additions-only check is pre-merge only"
  else
    removed="$(git -C "$REPO_ROOT" diff origin/main -- dark-factory/run-zone-hunt.sh | grep -c '^-[^-]')"
    [ "$removed" = 0 ] && ok "run-zone-hunt.sh diff vs origin/main is additions only (0 removed lines)" \
      || bad "run-zone-hunt.sh removes $removed origin/main line(s) — the wiring must be additions only"
  fi
else
  skip "origin/main not fetched — additions-only check skipped"
fi

# ================================================================================================
note "2) WATCHDOG: wall cap, staleness, three-arg rc, TERM ..."
CELLWD="$HERE/lib/cell-watchdog.sh"
if ! command -v setsid >/dev/null 2>&1; then
  skip "setsid unavailable — the managed watchdog is a pass-through on this host"
else
  WC="$WORK/wdcell"; mkdir -p "$WC"
  cat > "$WORK/beat.sh" <<EOF
#!/usr/bin/env bash
for _i in 1 2 3 4 5 6 7 8 9 10; do echo beat > "$WC/hb"; "$STUB_SLEEP" 1; done
EOF
  t0=$(date +%s); bash "$CELLWD" "$WC" 900 1 2 -- bash "$WORK/beat.sh" >/dev/null 2>&1; rc=$?; el=$(( $(date +%s) - t0 ))
  [ "$rc" = 124 ] && [ "$el" -le 6 ] && ok "wall=2 on a 10 s heartbeating engine: killed after ${el}s, exit 124" \
    || bad "wall cap did not fire as expected (rc=$rc, ${el}s)"
  printf '#!/usr/bin/env bash\necho x > "%s/hb"\n"%s" 20\n' "$WC" "$STUB_SLEEP" > "$WORK/hang.sh"
  bash "$CELLWD" "$WC" 2 1 0 -- bash "$WORK/hang.sh" >/dev/null 2>&1; rc4=$?
  bash "$CELLWD" "$WC" 2 1 -- bash "$WORK/hang.sh" >/dev/null 2>&1; rc3=$?
  { [ "$rc4" = 143 ] || [ "$rc4" = 137 ]; } && { [ "$rc3" = 143 ] || [ "$rc3" = 137 ]; } \
    && ok "a staleness kill still exits 143/137 (managed: $rc4, three-arg: $rc3)" || bad "staleness kill rc drifted (managed=$rc4 three-arg=$rc3)"
  bash "$CELLWD" "$WC" 0 1 -- bash -c 'exit 7' >/dev/null 2>&1; r7=$?
  bash "$CELLWD" "$WC" 30 1 -- bash -c 'exit 5' >/dev/null 2>&1; r5=$?
  [ "$r7" = 7 ] && [ "$r5" = 5 ] && ok "three-argument calls preserve the engine's rc (7 pass-through, 5 watched)" \
    || bad "three-argument rc not preserved (got $r7 / $r5)"
  bash "$CELLWD" "$WC" 0 1 0 -- bash -c '"$0" 30 & "$0" 30; wait' "$STUB_SLEEP" >/dev/null 2>&1 &
  wdpid=$!
  for _i in $(seq 1 50); do [ "$(procs_under "$STUB_SLEEP" | grep -c .)" -ge 2 ] && break; sleep 0.1; done
  kill -TERM "$wdpid" 2>/dev/null; wait "$wdpid"; rct=$?
  sleep 0.5
  if [ "$rct" = 143 ] && [ -z "$(procs_under "$STUB_SLEEP")" ]; then
    ok "TERM to a managed watchdog exits 143 and leaves no process of the engine group"
  else
    bad "TERM to a managed watchdog (rc=$rct) left: $(procs_under "$STUB_SLEEP" | tr '\n' ';')"
  fi
fi

# ================================================================================================
note "3) GATE CLASSIFIER: forge-invariant.sh compile-scope diag row ..."
# gate_case GATE_COPY_DIR FIXTURE [REPO] -> "rc|<last compile.tsv row>" ; output captured to $WORK/gate.out
gate_setup() {  # DIR GATE_SRC WITH_DIAG
  rm -rf "$1"; mkdir -p "$1/repo/src/vault" "$1/repo/test"
  cp "$2" "$1/forge-invariant.sh"
  cp "$REPO/foundry.toml" "$1/repo/"; cp "$REPO"/src/vault/*.sol "$1/repo/src/vault/"
  printf 'contract InvTest {\n    function invariant_x() public {}\n}\n' > "$1/repo/test/Inv_harness.t.sol"
  [ "$3" = 1 ] && mkdir -p "$1/forge-diag"
  return 0
}
gate_run() {  # DIR FIXTURE [REPO]
  _gr_repo="${3:-$1/repo}"
  PATH="$WORK/fbin:$PATH" FAKE_FORGE_OUT="$FIXDIR/$2.stdout" bash "$1/forge-invariant.sh" --repo "$_gr_repo" \
    --target "$_gr_repo/test/Inv_harness.t.sol" > "$WORK/gate.out" 2>&1
  echo "$?"
}
classify_all() {  # GATE_SRC -> prints "<fixture>=<scope>/<n>/<loc>" per fixture
  gate_setup "$WORK/gd" "$1" 1
  for fx in target harness mixed warn-harness unlocated compiled; do
    gate_run "$WORK/gd" "$fx" >/dev/null
    printf '%s=%s\n' "$fx" "$(tail -1 "$WORK/gd/forge-diag/compile.tsv" 2>/dev/null | awk -F'\t' '{print $2 "/" $3 "/" $4}')"
  done
}
CLS="$(classify_all "$GATE")"
exp="target=target/1/src/vault/VaultB.sol:5:47
harness=harness/1/
mixed=mixed/2/src/vault/VaultB.sol:5:47
warn-harness=harness/1/
unlocated=unlocated/0/
compiled=compiled/0/"
[ "$CLS" = "$exp" ] && ok "scopes: target, harness (a Note into the source ignored), mixed, harness under a source warning, unlocated, compiled" \
  || { bad "compile-scope classification drifted:"; printf '%s\n' "$CLS" | sed 's/^/      /'; }
if [ "$(awk -F'\t' '{print $1}' "$WORK/gd/forge-diag/compile.tsv" | sort -u)" = "test/Inv_harness.t.sol" ]; then
  ok "every row names the harness relative to --repo"
else
  bad "harness_relpath column drifted"
fi
# No diag dir / a foreign --repo => no row; exit code + banner + output identical to the opted-in run.
gate_setup "$WORK/gn" "$GATE" 0
same=1
for fx in target harness unlocated compiled; do
  r1="$(gate_run "$WORK/gd" "$fx")"; cp "$WORK/gate.out" "$WORK/gate1.out"
  r2="$(gate_run "$WORK/gn" "$fx")"
  [ "$r1" = "$r2" ] && cmp -s "$WORK/gate1.out" "$WORK/gate.out" || same=0
done
before="$(wc -l < "$WORK/gd/forge-diag/compile.tsv")"
gate_setup "$WORK/foreign" "$GATE" 0
gate_run "$WORK/gd" target "$WORK/foreign/repo" >/dev/null
after="$(wc -l < "$WORK/gd/forge-diag/compile.tsv")"
if [ "$same" = 1 ] && [ ! -e "$WORK/gn/forge-diag" ] && [ "$before" = "$after" ]; then
  ok "no diag dir / a foreign --repo write nothing; exit codes, banners and output are unchanged"
else
  bad "diag opt-in leaked (same=$same rows $before->$after)"
fi

# ================================================================================================
note "4) TIMEOUT: ledger-only, never merged, resume re-runs it; tail-kill keeps the verdict ..."
t4_timeout() {  # RZH -> 0 when every TIMEOUT assertion holds (prints the failures otherwise)
  _t_rzh="$1"; _t_ok=0
  spec 'VaultB|C10|30|normal|FINDING' '*|*|0.2|normal|CLEAN'
  STUB_LOG="$WORK/t4.stub" DEEP_HUNT_REACH=1 DEEP_HUNT_CELL_TIMEOUT_S=2 lens_only "$_t_rzh" "$WORK/t4"
  sleep 0.5
  [ "$(status_of "$WORK/t4" VaultB C10)" = TIMEOUT ] && [ "$(reason_of "$WORK/t4" VaultB C10)" = "cell-timeout=2s" ] \
    || { echo "    ledger: $(status_of "$WORK/t4" VaultB C10)/$(reason_of "$WORK/t4" VaultB C10)"; _t_ok=1; }
  cmp -s "$DBASE/verify/verified_findings.json" "$WORK/t4/verify/verified_findings.json" || { echo "    verified_findings.json changed"; _t_ok=1; }
  awk -F'\t' '$2 == "VaultB" && $3 == "C10"' "$WORK/t4/deep-hunt/reach-coverage.tsv" 2>/dev/null | grep -q . && { echo "    reach row written"; _t_ok=1; }
  # The timed-out cell's aggregate log (never a _c<N>.log) carries no verdict at all — in particular no CLEAN.
  for _t_l in "$WORK/t4/deep-hunt/src_vault-C10-VaultB"/run/invariant_*.log; do
    [ -e "$_t_l" ] || continue
    case "$_t_l" in *_c[0-9]*.log) continue ;; esac
    grep -q 'INVARIANT|' "$_t_l" && { echo "    verdict line in the timed-out cell's aggregate log"; _t_ok=1; }
  done
  grep -q 'CLEAN' <(awk -F'\t' '$2 == "VaultB" && $3 == "C10"' "$WORK/t4/deep-hunt/cell-status.tsv") && { echo "    CLEAN in the ledger"; _t_ok=1; }
  [ -z "$(procs_under "$STUB_SLEEP")" ] || { echo "    orphan: $(procs_under "$STUB_SLEEP" | head -1)"; _t_ok=1; }
  # --deep-hunt-resume (the stub is fast now) re-runs exactly the timed-out cell and settles it.
  spec '*|*|0.2|normal|FINDING'
  : > "$WORK/t4r.stub"
  rm -rf "$WORK/t4r"; cp -R "$WORK/t4" "$WORK/t4r"
  PATH="$WORK/fbin:$PATH" STUB_LOG="$WORK/t4r.stub" DEEP_HUNT_REACH=1 DEEP_HUNT_CELL_TIMEOUT_S=2 "$_t_rzh" --repo "$REPO" \
    --out "$WORK/t4r" --deep-hunt --deep-hunt-only --deep-hunt-resume --backend mock --agentis "$STUB" >"$WORK/t4r.log" 2>&1
  [ "$(cat "$WORK/t4r.stub")" = "VaultB|C10" ] || { echo "    resume re-ran: $(tr '\n' ' ' < "$WORK/t4r.stub")"; _t_ok=1; }
  [ "$(status_of "$WORK/t4r" VaultB C10)" = FINDING ] && [ "$(findings_of "$WORK/t4r")" = 1 ] \
    || { echo "    resume did not settle + merge the cell ($(status_of "$WORK/t4r" VaultB C10), $(findings_of "$WORK/t4r") merged)"; _t_ok=1; }
  return "$_t_ok"
}
if t4_timeout "$RZH"; then
  if grep -q 'already hunted (terminal verdict), skipping' "$WORK/t4r.log" && ! grep -q 'run-invariant-hunt.sh failed' "$WORK/t4r.log" \
     && ! grep -q 'run-invariant-hunt.sh failed' "$WORK/t4.log"; then
    ok "the enqueue pass's own diagnostics (the resume skip lines) reach stderr; the shim's exit-1 artifacts do not"
  else
    bad "enqueue-pass stderr: resume skip lines missing or shim failure lines leaked"
  fi
  ok "a timed-out cell: ledger TIMEOUT (cell-timeout=2s), verified_findings.json byte-unchanged, no reach row, never CLEAN, no orphan; --deep-hunt-resume re-runs exactly it and merges its FINDING"
else
  bad "TIMEOUT contract regressed (see above)"
fi
spec 'VaultC|C2|30|tail|FINDING' '*|*|0.2|normal|CLEAN'
DEEP_HUNT_REACH=1 DEEP_HUNT_CELL_TIMEOUT_S=2 lens_only "$RZH" "$WORK/t4t"
if [ "$(status_of "$WORK/t4t" VaultC C2)" = FINDING ] && [ "$(reason_of "$WORK/t4t" VaultC C2)" = tail-killed ] \
   && [ "$(findings_of "$WORK/t4t")" = 1 ]; then
  ok "tail-kill: a verdict written before the cap fired is kept (FINDING, reason tail-killed) and merged"
else
  bad "tail-kill: $(status_of "$WORK/t4t" VaultC C2)/$(reason_of "$WORK/t4t" VaultC C2), merged=$(findings_of "$WORK/t4t")"
fi
# A hard stop mid-dispatch: TERM to run-zone-hunt.sh reaches every engine group through worker -> watchdog.
spec '*|*|30|normal|CLEAN'
rm -rf "$WORK/t4k"; cp -R "$DBASE" "$WORK/t4k"
PATH="$WORK/fbin:$PATH" DEEP_HUNT_REACH=1 DEEP_HUNT_JOBS=2 "$RZH" --repo "$REPO" --out "$WORK/t4k" --deep-hunt --deep-hunt-only \
  --backend mock --agentis "$STUB" >"$WORK/t4k.log" 2>&1 &
rzpid=$!
for _i in $(seq 1 150); do [ "$(procs_under "$STUB_SLEEP" | grep -c .)" -ge 2 ] && break; sleep 0.2; done
nrun="$(procs_under "$STUB_SLEEP" | grep -c .)"
kill -TERM "$rzpid" 2>/dev/null; wait "$rzpid"; rck=$?
sleep 1
left="$(procs_under "$STUB_SLEEP"; procs_under "$STUB"; procs_under "$WORK/t4k/")"
if [ "$nrun" -ge 2 ] && [ "$rck" = 143 ] && grep -q '__EXIT__=143' "$WORK/t4k.log" && [ -z "$left" ]; then
  ok "TERM to run-zone-hunt.sh mid-dispatch ($nrun cells running): exit 143, __EXIT__ printed, no orphan engine process"
else
  bad "hard stop: running=$nrun rc=$rck left=[$(printf '%s' "$left" | tr '\n' ';')]"
fi

# ================================================================================================
note "5) SKIP: a target-scoped probe skips the target's other lens ..."
t5_skip() {  # RZH JOBS OUT -> writes OUT (+ OUT.stub)
  # The probe (VaultB/C10, queue row 3) is the slowest cell, so under JOBS=3 its other lens (row 4) reaches the head of
  # the window while the probe still runs: only the probe-first rule keeps it waiting.
  spec 'VaultB|C10|3|forge-target|' '*|*|0.2|normal|CLEAN'
  : > "$3.stub"
  STUB_LOG="$3.stub" DEEP_HUNT_REACH=1 DEEP_HUNT_SKIP_BROKEN_TARGET=1 DEEP_HUNT_JOBS="$2" lens_only "$1" "$3"
}
t5_skip "$RZH" 1 "$WORK/t5"
if [ "$(status_of "$WORK/t5" VaultB C10)" = HARNESS_ERROR ] && [ "$(status_of "$WORK/t5" VaultB C2)" = SKIPPED_TARGET_BROKEN ] \
   && [ "$(reason_of "$WORK/t5" VaultB C2)" = "probe=C10 loc=src/vault/VaultB.sol:5:47" ] && ! grep -qx 'VaultB|C2' "$WORK/t5.stub" \
   && [ "$(grep -c . "$WORK/t5.stub")" = 5 ]; then
  ok "target-scoped probe HARNESS_ERROR -> VaultB/C2 SKIPPED_TARGET_BROKEN (probe=C10 loc=src/vault/VaultB.sol:5:47), never invoked"
else
  bad "skip: probe=$(status_of "$WORK/t5" VaultB C10) other=$(status_of "$WORK/t5" VaultB C2) reason=$(reason_of "$WORK/t5" VaultB C2) stub=[$(tr '\n' ' ' < "$WORK/t5.stub")]"
fi
spec 'VaultB|C10|0.2|forge-target|' '*|*|0.2|normal|CLEAN'
: > "$WORK/t5u.stub"; STUB_LOG="$WORK/t5u.stub" DEEP_HUNT_REACH=1 lens_only "$RZH" "$WORK/t5u"
if grep -qx 'VaultB|C2' "$WORK/t5u.stub" && [ -z "$(find "$WORK/t5u/deep-hunt" -name compile.tsv)" ]; then
  ok "knob unset: the same target's other lens runs, and no forge-diag row is written"
else
  bad "knob unset: VaultB/C2 not run or a diag row leaked"
fi
spec 'VaultB|C10|0.2|forge-harness|' '*|*|0.2|normal|CLEAN'
: > "$WORK/t5h.stub"; STUB_LOG="$WORK/t5h.stub" DEEP_HUNT_REACH=1 DEEP_HUNT_SKIP_BROKEN_TARGET=1 lens_only "$RZH" "$WORK/t5h"
if [ "$(status_of "$WORK/t5h" VaultB C10)" = HARNESS_ERROR ] && [ "$(status_of "$WORK/t5h" VaultB C2)" = CLEAN ] \
   && grep -qx 'VaultB|C2' "$WORK/t5h.stub"; then
  ok "a harness-scoped probe never skips the target"
else
  bad "harness-scoped probe: other lens $(status_of "$WORK/t5h" VaultB C2)"
fi

# ================================================================================================
note "6) BUDGET: hard zone budget ..."
spec 'VaultA|C10|0.2|normal|CLEAN' '*|*|30|normal|CLEAN'
: > "$WORK/t6.stub"; STUB_LOG="$WORK/t6.stub" DEEP_HUNT_REACH=1 DEEP_HUNT_ZONE_BUDGET_S=6 lens_only "$RZH" "$WORK/t6"
t6="$(awk -F'\t' '{printf "%s/%s:%s:%s;", $2, $3, $4, $5}' "$WORK/t6/deep-hunt/cell-status.tsv" 2>/dev/null)"
t6_exp="VaultA/C10:CLEAN:-;VaultA/C2:TIMEOUT:zone-budget;VaultB/C10:SKIPPED_BUDGET:zone-budget=6s;VaultB/C2:SKIPPED_BUDGET:zone-budget=6s;VaultC/C10:SKIPPED_BUDGET:zone-budget=6s;VaultC/C2:SKIPPED_BUDGET:zone-budget=6s;"
if [ "$t6" = "$t6_exp" ] && [ "$(grep -c . "$WORK/t6.stub")" = 2 ] && [ -z "$(procs_under "$STUB_SLEEP")" ]; then
  ok "in-flight cell capped at the zone's remaining budget (TIMEOUT, zone-budget); the 4 unlaunched pairs SKIPPED_BUDGET"
else
  bad "budget ledger: $t6 (stub calls: $(grep -c . "$WORK/t6.stub"))"
fi

# ================================================================================================
note "7) EQUIVALENCE: legacy == JOBS=1 == JOBS=3 (PROMISES on, completion order reversed) ..."
# Durations fall by more than the watchdog's 1 s poll per row, so under JOBS=3 row 3 finishes before rows 2 and 1:
# the two FINDINGs (rows 1 and 3) complete in the REVERSE of their queue order.
EQ_SPEC=('VaultA|C10|4.2|normal|FINDING' 'VaultA|C2|3.2|normal|CLEAN' 'VaultB|C10|2.2|normal|FINDING'
         'VaultB|C2|1.2|normal|CLEAN' 'VaultC|C10|0.6|normal|CLEAN' 'VaultC|C2|0.3|normal|CLEAN')
eq_run() {  # RZH OUT [KNOB=V...]  (PROMISES on; a fresh concurrency probe per run)
  _e_rzh="$1"; _e_out="$2"; shift 2
  spec "${EQ_SPEC[@]}"
  rm -rf "$_e_out.probe"; mkdir -p "$_e_out.probe"
  ( export STUB_PROBE="$_e_out.probe" DEEP_HUNT_REACH=1 DEEP_HUNT_PROMISES=1
    for _e_kv in "$@"; do export "${_e_kv?}"; done
    lens_only "$_e_rzh" "$_e_out" )
}
# artifact_sig OUT — every compared artifact, timestamps in the lens matrix normalised.
artifact_sig() {
  {
    for f in verify/verified_findings.json deep-hunt/reach-coverage.tsv deep-hunt/promise-coverage.tsv deep-hunt/promises.tsv; do
      echo "== $f"; cat "$1/$f" 2>/dev/null || echo "(missing)"
    done
    echo "== lens-surface-matrix.json"
    sed -E 's/"(started_at|updated_at)": "[^"]*"/"\1": "T"/g' "$1/coverage/lens-surface-matrix.json" 2>/dev/null
    ( cd "$1/deep-hunt" && find . -path '*/run/invariant_*.log' ! -name '*_c[0-9]*.log' | sort | while read -r l; do echo "== $l"; cat "$l"; done )
  }
}
eq_check() {  # RZH -> 0 when a == b == c and the ledgers/concurrency hold
  _q_ok=0
  eq_run "$1" "$WORK/eqa"
  eq_run "$1" "$WORK/eqb" DEEP_HUNT_JOBS=1 DEEP_HUNT_CELL_TIMEOUT_S=3600
  eq_run "$1" "$WORK/eqc" DEEP_HUNT_JOBS=3 DEEP_HUNT_CELL_TIMEOUT_S=3600
  artifact_sig "$WORK/eqa" > "$WORK/eqa.sig"; artifact_sig "$WORK/eqb" > "$WORK/eqb.sig"; artifact_sig "$WORK/eqc" > "$WORK/eqc.sig"
  cmp -s "$WORK/eqa.sig" "$WORK/eqb.sig" || { echo "    legacy != JOBS=1:"; diff "$WORK/eqa.sig" "$WORK/eqb.sig" | head -8 | sed 's/^/      /'; _q_ok=1; }
  cmp -s "$WORK/eqa.sig" "$WORK/eqc.sig" || { echo "    legacy != JOBS=3:"; diff "$WORK/eqa.sig" "$WORK/eqc.sig" | head -8 | sed 's/^/      /'; _q_ok=1; }
  cmp -s "$WORK/eqb/deep-hunt/cell-status.tsv" "$WORK/eqc/deep-hunt/cell-status.tsv" || { echo "    ledger b != c"; _q_ok=1; }
  [ -f "$WORK/eqa/deep-hunt/cell-status.tsv" ] && { echo "    legacy wrote a ledger"; _q_ok=1; }
  [ "$(findings_of "$WORK/eqa")" = 2 ] || { echo "    legacy merged $(findings_of "$WORK/eqa") finding(s), want 2"; _q_ok=1; }
  [ -z "$(find "$WORK/eqb/deep-hunt" "$WORK/eqc/deep-hunt" -name .dh-uncollected 2>/dev/null)" ] || { echo "    an uncollected marker survived a complete run"; _q_ok=1; }
  return "$_q_ok"
}
if eq_check "$RZH"; then
  ok "verified_findings.json, reach-coverage.tsv, promise-coverage.tsv, promises.tsv, lens-surface-matrix.json and every aggregate cell log are byte-identical across legacy / JOBS=1 / JOBS=3; ledgers b == c"
else
  bad "parallel output != sequential output (see above)"
fi
mb="$(maxconc "$WORK/eqb.probe")"; mc="$(maxconc "$WORK/eqc.probe")"
[ "$mb" = 1 ] && [ "${mc:-0}" -ge 2 ] && ok "max concurrency: JOBS=1 -> $mb, JOBS=3 -> $mc" || bad "max concurrency: JOBS=1 -> $mb, JOBS=3 -> $mc"
if [ "$(cut -f1 "$WORK/eqc/deep-hunt/.sched/timing.tsv" | tr '\n' ' ')" != "1 2 3 4 5 6 " ]; then
  ok "JOBS=3 completion order differed from the queue order ($(cut -f1 "$WORK/eqc/deep-hunt/.sched/timing.tsv" | tr '\n' ' '))"
else
  skip "JOBS=3 happened to finish in queue order on this host — the equivalence above is weaker evidence"
fi
t5_skip "$RZH" 3 "$WORK/t5j"
if cmp -s "$WORK/t5/deep-hunt/cell-status.tsv" "$WORK/t5j/deep-hunt/cell-status.tsv" \
   && [ "$(sort "$WORK/t5.stub")" = "$(sort "$WORK/t5j.stub")" ]; then
  ok "skip under JOBS=3 == skip under JOBS=1 (same ledger, same invocations)"
else
  bad "skip under JOBS=3 differs from JOBS=1"
fi

# ================================================================================================
note "8) SLOT + FORCED SERIAL ..."
spec '*|*|0.6|normal|CLEAN'
rm -rf "$WORK/s1.probe"; mkdir -p "$WORK/s1.probe"; : > "$WORK/s1.env"
STUB_PROBE="$WORK/s1.probe" STUB_ENVLOG="$WORK/s1.env" LLM_MAX_CONCURRENT=1 LLM_SLOT_WAIT_S=600 DEEP_HUNT_REACH=1 DEEP_HUNT_JOBS=3 \
  lens_only "$RZH" "$WORK/s1"
if [ "$(maxconc "$WORK/s1.probe")" = 1 ] && [ "$(grep -c . "$WORK/s1/deep-hunt/cell-status.tsv")" = 6 ] \
   && [ -d "$DARK_FACTORY_DIR/deep-hunt-llm-slots" ] && ! grep -qxF "$DARK_FACTORY_DIR/deep-hunt-llm-slots" "$WORK/s1.env"; then
  ok "LLM_MAX_CONCURRENT=1 + JOBS=3: max concurrency 1 on the dedicated pool, which never reaches the engine's env"
else
  bad "LLM slot pool: concurrency $(maxconc "$WORK/s1.probe"), engine saw [$(sort -u "$WORK/s1.env" | tr '\n' ' ')]"
fi
if grep -q 'DEEP_HUNT_JOBS=3 > LLM_MAX_CONCURRENT=1: .*may overrun its zone budget by up to that wait' "$WORK/s1.log" \
   && ! grep -q 'LLM_MAX_CONCURRENT' "$WORK/eqc.log"; then
  ok "JOBS > LLM_MAX_CONCURRENT prints the zone-budget overrun warning (and JOBS <= LLM_MAX_CONCURRENT does not)"
else
  bad "the JOBS > LLM_MAX_CONCURRENT warning is missing (or printed when JOBS <= the pool size)"
fi
rm -rf "$WORK/s2.probe"; mkdir -p "$WORK/s2.probe"
STUB_PROBE="$WORK/s2.probe" DEEP_HUNT_REACH=1 DEEP_HUNT_JOBS=3 lens_only "$RZH" "$WORK/s2" --pattern-store "$WORK/pstore"
if [ "$(maxconc "$WORK/s2.probe")" = 1 ] && grep -q 'pattern-store is forwarded' "$WORK/s2.log"; then
  ok "--pattern-store forwarded: warning + max concurrency 1"
else
  bad "--pattern-store did not force serial (concurrency $(maxconc "$WORK/s2.probe"))"
fi
spec 'VaultA|C2|0.2|normal|FINDING' '*|*|0.4|normal|CLEAN'
lens_only "$RZH" "$WORK/s3a" --deep-hunt-max-targets 2
DEEP_HUNT_JOBS=3 lens_only "$RZH" "$WORK/s3c" --deep-hunt-max-targets 2
sig3() { artifact_sig "$1" | grep -v '^== deep-hunt/\(reach\|promise\)'; }
if [ "$(awk -F'\t' '{print $1 "-" $3}' "$WORK/s3a/.deep-hunt-targets.tsv" | sort | uniq -d | grep -c .)" -ge 1 ] \
   && grep -q 'queued in [2-9] batch(es)' "$WORK/s3c.log" && [ "$(sig3 "$WORK/s3a")" = "$(sig3 "$WORK/s3c")" ]; then
  ok "legacy --deep-hunt-max-targets 2 (shared run dirs) under JOBS=3: split into batches, artifacts identical to legacy"
else
  bad "shared run dirs under JOBS=3 differ from legacy"
fi
# Pre-trust: ONE call over exactly the batch's run dirs, under a temp HOME (never the real ~/.claude.json).
pt_home="$WORK/home"; mkdir -p "$pt_home"
( export HOME="$pt_home"
  # shellcheck source=lib/deep-hunt-sched.sh
  . "$HERE/lib/deep-hunt-sched.sh"
  # shellcheck disable=SC2034  # read by the sourced dh_pretrust
  DH_HERE="$HERE/lib"
  # shellcheck disable=SC2034  # read by the sourced dh_pretrust
  DH_DZ=("" "$WORK/pt/a" "$WORK/pt/b" "$WORK/pt/c")
  # shellcheck disable=SC2034  # read by the sourced dh_pretrust
  DH_BACKEND=mock; dh_pretrust 1 2
  [ ! -f "$pt_home/.claude.json" ] || exit 1
  # shellcheck disable=SC2034  # read by the sourced dh_pretrust
  DH_BACKEND=claude; dh_pretrust 1 2 ) >/dev/null 2>&1
pt_keys="$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["projects"])))' "$pt_home/.claude.json" 2>/dev/null)"
if [ "$pt_keys" = "$WORK/pt/a/run $WORK/pt/b/run" ]; then
  ok "pre-trust: mock writes nothing; claude records exactly the batch's <run-dir>/run entries in one write (temp HOME)"
else
  bad "pre-trust wrote [$pt_keys]"
fi

# ================================================================================================
note "10) HARD STOP + RESUME, TRANSIENT PROBE, SHARED-DIR RESUME, STALE VERDICT ..."
# run_bg OUT [KNOB=V...] — start a lens-only pass in the background (fresh copy of the base); sets BGPID.
run_bg() {
  _b_out="$1"; shift
  rm -rf "$_b_out"; cp -R "$DBASE" "$_b_out"
  ( for _b_kv in "$@"; do export "${_b_kv?}"; done
    exec env PATH="$WORK/fbin:$PATH" "$RZH" --repo "$REPO" --out "$_b_out" --deep-hunt --deep-hunt-only \
      --backend mock --agentis "$STUB" ) >"$_b_out.log" 2>&1 &
  BGPID=$!
}
stop_bg() { kill -TERM "$BGPID" 2>/dev/null; wait "$BGPID" 2>/dev/null; sleep 1; }
resume_run() {  # OUT STUBLOG [KNOB=V...] [-- extra flags...]
  _r_out="$1"; _r_log="$2"; shift 2
  : > "$_r_log"
  ( while [ "$#" -gt 0 ] && [ "$1" != -- ]; do export "${1?}"; shift; done
    [ "${1:-}" = -- ] && shift
    STUB_LOG="$_r_log" PATH="$WORK/fbin:$PATH" "$RZH" --repo "$REPO" --out "$_r_out" --deep-hunt --deep-hunt-only \
      --deep-hunt-resume --backend mock --agentis "$STUB" "$@" ) >"$_r_out.resume.log" 2>&1
}
# (a) 1 job, a hard stop after the first cell's FINDING settled: it is already merged + in the ledger, and a resume
#     neither loses nor re-runs it.
spec 'VaultA|C10|0.2|normal|FINDING' '*|*|30|normal|CLEAN'
: > "$WORK/h1.stub"
STUB_LOG="$WORK/h1.stub" run_bg "$WORK/h1" DEEP_HUNT_REACH=1 DEEP_HUNT_CELL_TIMEOUT_S=3600
for _i in $(seq 1 150); do [ "$(grep -c . "$WORK/h1.stub" 2>/dev/null)" -ge 2 ] && break; sleep 0.2; done
stop_bg
h1_after="$(findings_of "$WORK/h1")"; h1_row="$(status_of "$WORK/h1" VaultA C10)"
spec '*|*|0.2|normal|CLEAN'
resume_run "$WORK/h1" "$WORK/h1r.stub" DEEP_HUNT_REACH=1 DEEP_HUNT_CELL_TIMEOUT_S=3600
if [ "$h1_after" = 1 ] && [ "$h1_row" = FINDING ] && [ "$(findings_of "$WORK/h1")" = 1 ] && ! grep -qx 'VaultA|C10' "$WORK/h1r.stub" \
   && [ -z "$(procs_under "$STUB_SLEEP")" ]; then
  ok "hard stop (1 job) after a FINDING settled: merged + ledgered before the stop; the resume keeps it (1 merged) and does not re-run it"
else
  bad "hard stop (1 job): merged after stop=$h1_after ledger=$h1_row, after resume=$(findings_of "$WORK/h1"), resume ran [$(tr '\n' ' ' < "$WORK/h1r.stub")]"
fi
# (b) 3 jobs, a hard stop while a FINDING that finished AFTER an earlier still-running cell waits for the queue-order
#     prefix: it stays marked, and a knob-less --deep-hunt-resume merges it without re-running it.
spec 'VaultA|C10|30|normal|CLEAN' 'VaultA|C2|0.2|normal|FINDING' '*|*|30|normal|CLEAN'
run_bg "$WORK/h3" DEEP_HUNT_REACH=1 DEEP_HUNT_JOBS=3
for _i in $(seq 1 150); do [ -f "$WORK/h3/deep-hunt/.sched/rc/2" ] && break; sleep 0.2; done
stop_bg
h3_after="$(findings_of "$WORK/h3")"; h3_mark=0; [ -f "$WORK/h3/deep-hunt/src_vault-C2-VaultA/.dh-uncollected" ] && h3_mark=1
spec '*|*|0.2|normal|CLEAN'
resume_run "$WORK/h3" "$WORK/h3r.stub" DEEP_HUNT_REACH=1
if [ "$h3_after" = 0 ] && [ "$h3_mark" = 1 ] && [ "$(findings_of "$WORK/h3")" = 1 ] && ! grep -qx 'VaultA|C2' "$WORK/h3r.stub" \
   && grep -qx 'VaultA|C10' "$WORK/h3r.stub" && grep -q 'scheduler ON (1 job, no caps)' "$WORK/h3.resume.log" \
   && [ -z "$(find "$WORK/h3/deep-hunt" -name .dh-uncollected)" ] && [ -z "$(procs_under "$STUB_SLEEP")" ]; then
  ok "hard stop (3 jobs) with a finished-but-uncollected FINDING: marked; a knob-less resume merges it (1 merged) without re-running it"
else
  bad "hard stop (3 jobs): merged=$h3_after marker=$h3_mark, after resume=$(findings_of "$WORK/h3"), resume ran [$(tr '\n' ' ' < "$WORK/h3r.stub")]"
fi
# (c) A probe whose prover crashed on a flat-cyborg TRANSPORT error after a target-scoped compile failure is a
#     TRANSIENT_ERROR, never a broken target: the target's other lens still runs.
spec 'VaultB|C10|0.2|ftrans-target|' '*|*|0.2|normal|CLEAN'
: > "$WORK/tt.stub"; STUB_LOG="$WORK/tt.stub" DEEP_HUNT_REACH=1 DEEP_HUNT_SKIP_BROKEN_TARGET=1 lens_only "$RZH" "$WORK/tt"
if [ "$(status_of "$WORK/tt" VaultB C10)" = TRANSIENT_ERROR ] && [ "$(status_of "$WORK/tt" VaultB C2)" = CLEAN ] \
   && grep -qx 'VaultB|C2' "$WORK/tt.stub"; then
  ok "a transport-crashed probe is TRANSIENT_ERROR and never skips its target's other lens"
else
  bad "transport-crashed probe: $(status_of "$WORK/tt" VaultB C10) / other lens $(status_of "$WORK/tt" VaultB C2)"
fi
# (d) --deep-hunt-max-targets 2 (shared run dirs) + --deep-hunt-resume over a HARNESS_ERROR-only prior pass: the
#     scheduler runs exactly the cells the sequential loop runs.
for arm in legacy sched; do
  rm -rf "$WORK/sr-$arm"; cp -R "$DBASE" "$WORK/sr-$arm"
  spec '*|*|0.2|normal|HARNESS_ERROR'
  PATH="$WORK/fbin:$PATH" "$RZH" --repo "$REPO" --out "$WORK/sr-$arm" --deep-hunt --deep-hunt-only --backend mock \
    --agentis "$STUB" --deep-hunt-max-targets 2 >/dev/null 2>&1
  spec '*|*|0.2|normal|CLEAN'
  if [ "$arm" = legacy ]; then
    resume_run "$WORK/sr-$arm" "$WORK/sr-$arm.stub" -- --deep-hunt-max-targets 2
  else
    resume_run "$WORK/sr-$arm" "$WORK/sr-$arm.stub" DEEP_HUNT_JOBS=1 DEEP_HUNT_CELL_TIMEOUT_S=3600 -- --deep-hunt-max-targets 2
  fi
done
if [ -s "$WORK/sr-legacy.stub" ] && cmp -s "$WORK/sr-legacy.stub" "$WORK/sr-sched.stub" \
   && [ "$(grep -c 'already hunted' "$WORK/sr-legacy.resume.log")" = "$(grep -c 'already hunted' "$WORK/sr-sched.resume.log")" ] \
   && [ "$(sig3 "$WORK/sr-legacy")" = "$(sig3 "$WORK/sr-sched")" ]; then
  ok "shared run dirs + --deep-hunt-resume: the scheduler runs exactly the sequential loop's cells ($(tr '\n' ' ' < "$WORK/sr-legacy.stub"))"
else
  bad "shared-dir resume: legacy ran [$(tr '\n' ' ' < "$WORK/sr-legacy.stub")], scheduler ran [$(tr '\n' ' ' < "$WORK/sr-sched.stub")]"
fi
# (e) A cap that fires before the engine touches its run dir never reads the previous run's verdict (worker level).
WS="$WORK/wst"; rm -rf "$WS"; mkdir -p "$WS/state/meta" "$WS/state/argv" "$WS/state/rc" "$WS/dz/run"
printf 'INVARIANT|src/vault/VaultA.sol:VaultA|CLEAN\n' > "$WS/dz/run/invariant_old.log"
printf 'src_vault\nsrc/vault/VaultA.sol\nC10\n\n\n%s\n\n' "$WS/dz" > "$WS/state/meta/1"
printf '%s\0' --out "$WS/dz" > "$WS/state/argv/1"
printf '#!/bin/sh\nexec "%s" 20\n' "$STUB_SLEEP" > "$WS/engine.sh"; chmod +x "$WS/engine.sh"
DH_STATE="$WS/state" DH_ENGINE="$WS/engine.sh" DH_STALE=0 DH_POLL=1 DH_SKIP=0 DH_LLM_SLOTS_DIR="$WS/slots" \
  bash "$HERE/lib/deep-hunt-cell.sh" --worker 1 1 cell >/dev/null 2>&1
if [ "$(cut -f2 "$WS/state/rc/1" 2>/dev/null)" = TIMEOUT ] && [ ! -e "$WS/dz/.dh-uncollected" ]; then
  ok "a cap firing before the engine rewrote its run dir -> TIMEOUT, never the previous run's CLEAN"
else
  bad "stale verdict read as this run's: $(cat "$WS/state/rc/1" 2>/dev/null)"
fi

# (f) A cell TERMed in its tail AFTER writing its verdict (1 job, no cap fired) is marked, so a resume merges it once
#     instead of skipping its terminal verdict as done.
spec 'VaultA|C10|30|tail|FINDING' '*|*|0.2|normal|CLEAN'
run_bg "$WORK/tk" DEEP_HUNT_REACH=1 DEEP_HUNT_CELL_TIMEOUT_S=3600
for _i in $(seq 1 150); do grep -qs 'INVARIANT|' "$WORK"/tk/deep-hunt/src_vault-C10-VaultA/run/invariant_*.log && break; sleep 0.2; done
sleep 0.5; stop_bg
tk_mark=0; [ -f "$WORK/tk/deep-hunt/src_vault-C10-VaultA/.dh-uncollected" ] && tk_mark=1
spec '*|*|0.2|normal|CLEAN'
resume_run "$WORK/tk" "$WORK/tkr.stub" DEEP_HUNT_REACH=1 DEEP_HUNT_CELL_TIMEOUT_S=3600
tk_rows="$(awk -F'\t' '$2 == "VaultA" && $3 == "C10"' "$WORK/tk/deep-hunt/cell-status.tsv" 2>/dev/null | grep -c .)"
if [ "$tk_mark" = 1 ] && [ "$(findings_of "$WORK/tk")" = 1 ] && ! grep -qx 'VaultA|C10' "$WORK/tkr.stub" && [ "$tk_rows" = 1 ] \
   && [ "$(status_of "$WORK/tk" VaultA C10)" = FINDING ] && [ -z "$(procs_under "$STUB_SLEEP")" ]; then
  ok "a cell TERMed in its tail after writing its verdict is marked; the resume merges it once (1 merged, 1 ledger row, not re-run)"
else
  bad "TERM in a cell's tail: marker=$tk_mark merged=$(findings_of "$WORK/tk") ledger rows=$tk_rows resume ran [$(tr '\n' ' ' < "$WORK/tkr.stub")]"
fi
# (g) A TERM while a multi-row collect step merges its first cell (a slow refute gate): the stop waits for that row,
#     every ledger row is written after its cell's merge, and the resume converges — one ledger row and one reach row
#     per cell, the FINDING merged once.
spec 'VaultA|C10|2|normal|FINDING' '*|*|0.3|normal|CLEAN'
rm -f "$WORK/refute.flag"
STUB_REFUTE_FLAG="$WORK/refute.flag" STUB_REFUTE_SLEEP=3 run_bg "$WORK/tg" DEEP_HUNT_REACH=1 DEEP_HUNT_JOBS=3
for _i in $(seq 1 150); do [ -f "$WORK/refute.flag" ] && break; sleep 0.2; done
stop_bg
tg_stop_rows="$(grep -c . "$WORK/tg/deep-hunt/cell-status.tsv" 2>/dev/null)"
resume_run "$WORK/tg" "$WORK/tgr.stub" DEEP_HUNT_REACH=1 DEEP_HUNT_JOBS=3
tg_cells="$(cut -f1-3 "$WORK/tg/deep-hunt/cell-status.tsv" 2>/dev/null | sort -u | grep -c .)"
tg_rows="$(grep -c . "$WORK/tg/deep-hunt/cell-status.tsv" 2>/dev/null)"
tg_reach="$(cut -f1-3 "$WORK/tg/deep-hunt/reach-coverage.tsv" 2>/dev/null | sort | uniq -c | awk '$1 == 1' | grep -c .)"
if [ -f "$WORK/refute.flag" ] && [ "$tg_stop_rows" = 1 ] && [ "$tg_rows" = 6 ] && [ "$tg_cells" = 6 ] && [ "$tg_reach" = 6 ] \
   && [ "$(findings_of "$WORK/tg")" = 1 ] && grep -q 'stopped at a row boundary' "$WORK/tg.log"; then
  ok "TERM during a collect step's merge: the row completes, ledger 1 row at the stop, 6 rows / 6 cells / 6 reach rows after resume, 1 FINDING"
else
  bad "TERM during a collect step: rows at stop=$tg_stop_rows, after resume rows=$tg_rows cells=$tg_cells reach=$tg_reach merged=$(findings_of "$WORK/tg")"
fi

# ================================================================================================
note "9) MUTATIONS on a copied tree ..."
MT="$WORK/tree"
mkdir -p "$MT"
( cd "$REPO_ROOT" && tar --exclude='dark-factory/bench' --exclude='dark-factory/hunt-dashboard' -cf - dark-factory tools/lib ) | ( cd "$MT" && tar -xf - )
MRZH="$MT/dark-factory/run-zone-hunt.sh"
mutate() {  # FILE PYTHON-OLD PYTHON-NEW -> 0 when applied
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if old not in s:
    sys.exit(1)
open(p, "w").write(s.replace(old, new, 1))
PY
}
mut() {  # NAME FILE OLD NEW CHECK-CMD...  (CHECK must FAIL on the mutant)
  _m_name="$1"; _m_file="$MT/dark-factory/$2"; cp "$_m_file" "$_m_file.orig"
  if ! mutate "$_m_file" "$3" "$4"; then bad "mutation '$_m_name': anchor not found"; mv "$_m_file.orig" "$_m_file"; return; fi
  shift 4
  if "$@" >/dev/null 2>&1; then bad "mutation '$_m_name' was NOT caught"; else ok "mutation '$_m_name' is caught"; fi
  mv "$_m_file.orig" "$_m_file"
}
skip_equiv() { t5_skip "$MRZH" 1 "$WORK/m1a"; t5_skip "$MRZH" 3 "$WORK/m1b"
  cmp -s "$WORK/m1a/deep-hunt/cell-status.tsv" "$WORK/m1b/deep-hunt/cell-status.tsv"; }
skip_rule() { t5_skip "$MRZH" 1 "$WORK/m3"; [ "$(status_of "$WORK/m3" VaultB C2)" = SKIPPED_TARGET_BROKEN ]; }
classifier_ok() { [ "$(classify_all "$MT/dark-factory/evm-harness/forge-invariant.sh")" = "$exp" ]; }
# shellcheck disable=SC2016  # literal source text for the mutations
mut "drop probe-first" lib/deep-hunt-sched.sh \
  'if [ -z "${DH_STATUS[$_dh_p]}" ]; then return 0; fi   # wait for the probe' '' skip_equiv
# shellcheck disable=SC2016
mut "TIMEOUT returns rc 0 / CLEAN" lib/deep-hunt-cell.sh 'STATUS=TIMEOUT' 'STATUS=CLEAN; COLLECT_RC=0' t4_timeout "$MRZH"
mut "invert the harness-tree test" evm-harness/forge-invariant.sh \
  'return hdir == "" or p == hdir or p.startswith(hdir + "/")' 'return not (hdir == "" or p == hdir or p.startswith(hdir + "/"))' classifier_ok
mut "invert the harness-tree test (skip)" evm-harness/forge-invariant.sh \
  'return hdir == "" or p == hdir or p.startswith(hdir + "/")' 'return not (hdir == "" or p == hdir or p.startswith(hdir + "/"))' skip_rule
# shellcheck disable=SC2016
mut "post-process in completion order" lib/deep-hunt-sched.sh \
  'dh_queue_order() { seq "$DH_CURSOR" "$DH_N"; }' 'dh_queue_order() { cut -f1 "$DH_STATE/timing.tsv"; }' eq_check "$MRZH"
mut "drop DEEP_HUNT_RESUME=0 in the collect pass" lib/deep-hunt-sched.sh \
  '      DEEP_HUNT_RESUME=0
' '' t4_timeout "$MRZH"

# ================================================================================================
if [ "$FAILS" -eq 0 ]; then
  note "PASS — per-cell cap, hard zone budget, broken-target skip and parallel cells hold; parallel output == sequential output; default OFF (#2258)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
