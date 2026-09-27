#!/usr/bin/env bash
# demo-foundry-shim.sh — OFFLINE, DETERMINISTIC proof of #2277: a HARDHAT-ONLY target (hardhat.config.*, no
# foundry.toml) is no longer silently skipped by the stateful lenses. STAGE 4.5 (--deep-hunt) and STAGE 4.6
# (--vector-hunt) run it in a generated FOUNDRY SHIM working copy (lib/foundry_shim.py + lib/foundry-shim.sh), every
# consult lands in <out>/deep-hunt-status.tsv, the frozen target is never written, and a Foundry target stays
# byte-identical.
#
# Parts (CI floor: bash + git + python3; a stub --agentis, a fake `forge` and a fake `npm` on PATH):
#   1) HELPER        foundry_shim.py plan/build over fixtures/hardhat-shim: src=contracts, solc recorded not pinned,
#                    the OZ remapping (none for the JS-only package), no hardhat.config.* / test/*.sol / .js in the
#                    copy, README.md kept, a --dest / --exclude dir under the root never copies itself, a non-empty
#                    --dest is refused; MUTATION: without node_modules -> unresolved=@openzeppelin/contracts, exit 4.
#   2) FROZEN TARGET the sorted path list + sha256 manifest of the clone is identical before and after a full
#                    --deep-hunt --vector-hunt run; no foundry.toml appears in the clone.
#   3) RAN           ledger `deep-hunt . * ran foundry-shim` + the vector-hunt row, stderr deep_hunt_status=ran; the
#                    prover sees the marker foundry.toml and contracts/Vault.sol; forge runs once in the shim (the
#                    probe, shared by both stages) and then in the staged cell repo; the PoC runner gets
#                    --repo <out>/.foundry-shim/_root.
#   4) SHIM-FAILED   forge build fails -> `forge-build rc=1: <error line>`, no deep-hunt cell, exit 0; no node_modules
#                    + DF_FOUNDRY_SHIM_INSTALL=0 -> deps-missing (the probe never runs); npm fails -> install-failed;
#                    npm succeeds -> ran, with --ignore-scripts and a scratch dir holding only package.json + lockfile.
#   5) SKIPPED       no toolchain config -> skipped-no-foundry/no-toolchain-config; DF_FOUNDRY_SHIM=0 ->
#                    shim-disabled; a malformed knob exits 2.
#   6) FOUNDRY BYTE-IDENTITY (differential) origin/main's dark-factory/ (git archive) and this tree over the same
#                    Foundry fixture: .deep-hunt-targets.tsv, verified_findings.json, the deep-hunt/ path list and the
#                    per-call prover probe are identical; only deep-hunt-status.tsv is new; no .foundry-shim/. SKIP
#                    (not fail) when origin/main is absent or already carries this change.
#   7) REAL FORGE    (optional) a real `forge build` of the fixture's shim exits 0. SKIP when forge is not installed.
#
# Usage:  dark-factory/demo-foundry-shim.sh
# Exit: 0 = all assertions held; non-zero = a regression.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ZONEHUNT="$HERE/run-zone-hunt.sh"
SHIMPY="$HERE/lib/foundry_shim.py"
FIX="$HERE/fixtures/hardhat-shim"

FAILS=0
note() { echo "demo-foundry-shim.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
[ -x "$ZONEHUNT" ] || { note "not found / not executable: $ZONEHUNT" >&2; exit 3; }
for f in "$SHIMPY" "$HERE/lib/foundry-shim.sh" "$FIX/hardhat.config.ts" "$FIX/contracts/Vault.sol"; do
  [ -f "$f" ] || { note "not found: $f" >&2; exit 3; }
done
REAL_FORGE="$(command -v forge 2>/dev/null || true)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-foundry-shim.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export DARK_FACTORY_DIR="$WORK/df-registry"   # never register a hunt / take a forge slot in the operator's state dir

# git_tree <src> <dst>: copy a fixture tree and commit it (map-zones.sh reads git file age for hardening_score).
git_tree() {
  mkdir -p "$2"
  cp -R "$1/." "$2/"
  git -C "$2" init -q
  git -C "$2" config user.email demo@example.invalid
  git -C "$2" config user.name demo
  git -C "$2" add -A
  git -C "$2" commit -qm "fixture"
}
# manifest <dir>: sorted `sha256  path` of every file outside .git (the frozen-target fingerprint).
manifest() { ( cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
  printf '%s  %s\n' "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$f")" "$f"
done ); }
lrow() { grep -c "^$1$" "$2" 2>/dev/null || true; }

# ----------------------------------------------------------------------------------------------------------
note "1) HELPER — foundry_shim.py plan / build over fixtures/hardhat-shim ..."
H="$WORK/helper-clone"; git_tree "$FIX" "$H"
python3 "$SHIMPY" plan --root "$H" --clone "$H" > "$WORK/plan.out" 2>&1; RC=$?
if [ "$RC" -eq 0 ] && grep -qx 'config=hardhat.config.ts' "$WORK/plan.out" && grep -qx 'src=contracts' "$WORK/plan.out" \
   && grep -qx 'solc_declared=0.8.20' "$WORK/plan.out" && grep -qx 'optimizer=true' "$WORK/plan.out" \
   && grep -qx 'optimizer_runs=200' "$WORK/plan.out" \
   && grep -qx 'remap=@openzeppelin/contracts/=node_modules/@openzeppelin/contracts/' "$WORK/plan.out" \
   && ! grep -q 'js-only-pkg' "$WORK/plan.out" && ! grep -q '^unresolved=' "$WORK/plan.out" \
   && grep -qx "lockfile=$H/package-lock.json" "$WORK/plan.out" && grep -qx 'lock_tool=npm' "$WORK/plan.out"; then
  ok "plan: src=contracts (paths.sources), solc 0.8.20 + optimizer 200 read statically, OZ remapped, the JS-only package not, npm lockfile found"
else
  bad "plan output (rc=$RC):"; sed 's/^/      /' "$WORK/plan.out"
fi
if [ -z "$(cd "$H" && git status --porcelain)" ]; then ok "plan writes nothing into the root"; else bad "plan wrote into the root"; fi
S1="$WORK/shim1"
python3 "$SHIMPY" build --root "$H" --clone "$H" --dest "$S1" > "$WORK/build1.out" 2>&1; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$S1/contracts/Vault.sol" ] && [ -f "$S1/contracts/libraries/ShareMath.sol" ] && [ -f "$S1/README.md" ] \
   && [ -f "$S1/node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol" ] && [ ! -e "$S1/node_modules/js-only-pkg" ] \
   && [ -z "$(find "$S1" -name 'hardhat.config.*' -o -name '*.js' -o -name '*.ts' -o -name 'package*.json')" ] \
   && [ ! -e "$S1/test" ]; then
  ok "build: sources + README.md + the .sol-only OZ package copied; no hardhat.config.*, JS/TS, package.json, test/*.sol or JS-only package"
else
  bad "build copy wrong (rc=$RC):"; (cd "$S1" 2>/dev/null && find . -type f | sort | sed 's/^/      /')
fi
if [ "$(head -1 "$S1/foundry.toml" 2>/dev/null)" = "# generated by dark-factory lib/foundry_shim.py (#2277) — not part of the target" ] \
   && grep -qx 'src = "contracts"' "$S1/foundry.toml" && grep -qx 'libs = \["node_modules", "lib"\]' "$S1/foundry.toml" \
   && grep -q 'declared solc: 0.8.20 (recorded, NOT pinned' "$S1/foundry.toml" && ! grep -Eq '^(solc|solc_version) *=' "$S1/foundry.toml" \
   && grep -qx '    "@openzeppelin/contracts/=node_modules/@openzeppelin/contracts/",' "$S1/foundry.toml" \
   && grep -qx 'optimizer_runs = 200' "$S1/foundry.toml"; then
  ok "foundry.toml: marker line, src/libs, the OZ remapping, optimizer settings; solc recorded in a comment, not pinned"
else
  bad "foundry.toml:"; sed 's/^/      /' "$S1/foundry.toml" 2>/dev/null
fi
mkdir -p "$H/runs-out/x" && printf 'contract X {}\n' > "$H/runs-out/x/X.sol"
python3 "$SHIMPY" build --root "$H" --clone "$H" --dest "$H/under-root-shim" --exclude "$H/runs-out" > /dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$H/under-root-shim/contracts/Vault.sol" ] && [ ! -e "$H/under-root-shim/under-root-shim" ] \
   && [ ! -e "$H/under-root-shim/runs-out" ]; then
  ok "a --dest under the root never copies itself, and an --exclude dir (the caller's --out) is pruned"
else
  bad "--dest under the root / --exclude (rc=$RC)"
fi
python3 "$SHIMPY" build --root "$H" --clone "$H" --dest "$S1" > /dev/null 2>&1; RC=$?
if [ "$RC" -eq 2 ]; then ok "a non-empty --dest is refused (exit 2)"; else bad "non-empty --dest: rc=$RC (want 2)"; fi
NM="$WORK/no-nm-clone"; git_tree "$FIX" "$NM"; rm -rf "$NM/node_modules"
python3 "$SHIMPY" build --root "$NM" --clone "$NM" --dest "$WORK/shim-nonm" > "$WORK/build-nonm.out" 2>&1; RC=$?
if [ "$RC" -eq 4 ] && grep -qx 'unresolved=@openzeppelin/contracts' "$WORK/build-nonm.out" \
   && [ "$(grep -c '^unresolved=' "$WORK/build-nonm.out")" = 1 ]; then
  ok "MUTATION: without node_modules the build reports unresolved=@openzeppelin/contracts and exits 4"
else
  bad "no-node_modules build (rc=$RC):"; sed 's/^/      /' "$WORK/build-nonm.out"
fi
python3 "$SHIMPY" build --root "$H" --clone "$H" > /dev/null 2>&1; RC=$?
if [ "$RC" -eq 2 ]; then ok "build without --dest is a usage error (exit 2)"; else bad "build without --dest: rc=$RC"; fi

# ----------------------------------------------------------------------------------------------------------
# The stubs of parts 2-6. A stub --agentis answers every substrate call; the invariant prover records what it was
# staged with. A fake forge records where it ran (and fails on demand); a fake npm records its argv + scratch dir
# listing and installs the fixture's OZ package on demand. VECTOR_HUNT_POC_RUNNER records the --repo it got.
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/forge" <<'FORGEEOF'
#!/bin/sh
shim=0; grep -q 'generated by dark-factory lib/foundry_shim.py' foundry.toml 2>/dev/null && shim=1
echo "FORGE|cwd=$PWD|shim=$shim|args=$*" >> "$FS_PROBE_LOG"
if [ "${FAKE_FORGE_RC:-0}" != 0 ]; then
  echo "Compiling 3 files with Solc 0.8.20"
  echo "Error (7576): Undeclared identifier. Did you mean \"asset\"?"
  exit "$FAKE_FORGE_RC"
fi
exit 0
FORGEEOF
cat > "$FAKEBIN/npm" <<'NPMEOF'
#!/bin/sh
echo "NPM|args=$*|ls=$(LC_ALL=C ls -A | tr '\n' ',')" >> "$FS_PROBE_LOG"
[ "${FAKE_NPM_RC:-0}" = 0 ] || exit "$FAKE_NPM_RC"
mkdir -p node_modules/@openzeppelin
cp -R "$FAKE_NPM_SRC" node_modules/@openzeppelin/contracts
exit 0
NPMEOF
chmod +x "$FAKEBIN/forge" "$FAKEBIN/npm"
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
cmd="${1:-}"; sub="${2:-}"
case "$cmd" in
  init) mkdir -p .agentis; exit 0 ;;
  memo) exit 0 ;;
  go)
    case "$sub" in
      invariant-prover.ag)
        # cwd == the run dir; repo/ is the staged copy of the --repo run-invariant-hunt.sh was given.
        shim="$(grep -c 'generated by dark-factory lib/foundry_shim.py' repo/foundry.toml 2>/dev/null)"
        toml="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:16])' repo/foundry.toml 2>/dev/null)"
        vault="$( [ -f repo/contracts/Vault.sol ] && echo 1 || echo 0 )"
        echo "PROVER|target=${TARGET_FN:-}|shim=${shim:-0}|toml=$toml|vault=$vault" >> "$FS_PROBE_LOG"
        printf 'contract InvProbe {\n    function invariant_probe() public pure returns (bool) { return true; }\n}\n' > "${INV_OUT:-repo/test/Inv.t.sol}"
        bash "${FORGE_INVARIANT:-}" --repo "${INV_REPO:-}" --target "${INV_OUT:-}" --match invariant >/dev/null 2>&1 || true
        echo "INVARIANT|${TARGET_FN:-}|CLEAN"
        exit 0 ;;
      *) echo "SAFE"; exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"
POCSTUB="$WORK/poc-runner-stub"
cat > "$POCSTUB" <<'POCEOF'
#!/bin/sh
r=""; t=""
while [ $# -gt 0 ]; do
  case "$1" in --repo) r="$2"; shift 2 ;; --target) t="$2"; shift 2 ;; *) shift ;; esac
done
echo "VHPOC|repo=$r|target=$t" >> "$FS_PROBE_LOG"
echo "POC|$t|CLEAN"
exit 0
POCEOF
chmod +x "$POCSTUB"
ZFIX="$WORK/zones.fixture.txt"
printf '%s\n' 'ZONE|contracts|contracts|C1,C6|Share vault: deposit and withdraw share accounting' \
  'ZONE|contracts_libraries|libraries|C6|Share conversion helpers' 'CUSTODY|contracts|true' > "$ZFIX"
BFIX="$WORK/briefs.fixture.txt"
printf '%s\n' 'DARK-FACTORY:BRIEF-BEGIN|contracts' 'Break "withdraw never pays out more than the depositor put in".' \
  'DARK-FACTORY:BRIEF-END' 'DARK-FACTORY:BRIEF-BEGIN|contracts_libraries' 'Break the share conversion rounding.' \
  'DARK-FACTORY:BRIEF-END' > "$BFIX"
# zh <clone> <out> <probe-log> <err> [extra run-zone-hunt.sh args...]: one full offline run.
zh() {
  _c="$1"; _o="$2"; _p="$3"; _e="$4"; shift 4
  : > "$_p"
  PATH="$FAKEBIN:$PATH" FS_PROBE_LOG="$_p" FAKE_NPM_SRC="$FIX/node_modules/@openzeppelin/contracts" \
    VECTOR_HUNT_POC_RUNNER="$POCSTUB" \
    "${ZH_BIN:-$ZONEHUNT}" --repo "$_c" --out "$_o" --backend mock --agentis "$STUB" \
      --map-fixture "$ZFIX" --brief-fixture "$BFIX" \
      --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
      --in-scope "the whole in-scope program" "$@" > "$_e.out" 2> "$_e"
}
# dho <clone> <base-out> <out> <probe-log> <err>: a --deep-hunt --deep-hunt-only pass over a copy of a breadth --out.
dho() {
  rm -rf "$3"; cp -R "$2" "$3"; rm -rf "$3/deep-hunt" "$3/.foundry-shim" "$3/deep-hunt-status.tsv" "$3/vector-hunt"
  : > "$4"
  PATH="$FAKEBIN:$PATH" FS_PROBE_LOG="$4" FAKE_NPM_SRC="$FIX/node_modules/@openzeppelin/contracts" \
    "$ZONEHUNT" --repo "$1" --out "$3" --backend mock --agentis "$STUB" --deep-hunt --deep-hunt-only > "$5.out" 2> "$5"
}

# ----------------------------------------------------------------------------------------------------------
note "2) FROZEN TARGET + 3) RAN — a full --deep-hunt --vector-hunt run over the Hardhat-only clone ..."
C="$WORK/clone"; git_tree "$FIX" "$C"
manifest "$C" > "$WORK/manifest.before"
O="$WORK/out"; P="$WORK/probe.log"
zh "$C" "$O" "$P" "$WORK/run.err" --deep-hunt --vector-hunt; RC=$?
manifest "$C" > "$WORK/manifest.after"
if [ "$RC" -eq 0 ]; then
  ok "run-zone-hunt.sh --deep-hunt --vector-hunt over a Hardhat-only clone exits 0"
else
  bad "run exited $RC"; tail -20 "$WORK/run.err" | sed 's/^/      /'
fi
if cmp -s "$WORK/manifest.before" "$WORK/manifest.after" && [ ! -e "$C/foundry.toml" ] && [ -z "$(cd "$C" && git status --porcelain)" ]; then
  ok "FROZEN TARGET: path list + sha256 manifest of the clone unchanged; no foundry.toml in the clone; git status clean"
else
  bad "the clone changed:"; diff "$WORK/manifest.before" "$WORK/manifest.after" | sed 's/^/      /'
fi
L="$O/deep-hunt-status.tsv"
if [ "$(head -1 "$L" 2>/dev/null)" = "$(printf '#stage\troot\tzone\tstatus\tdetail')" ] \
   && [ "$(lrow "deep-hunt	\.	\*	ran	foundry-shim" "$L")" = 1 ] && [ "$(lrow "vector-hunt	\.	\*	ran	foundry-shim" "$L")" = 1 ] \
   && [ "$(grep -vc '^#' "$L")" = 2 ] \
   && grep -q '\[deep-hunt\] deep_hunt_status=ran (1/1 root(s) ran)' "$WORK/run.err" \
   && grep -q '\[vector-hunt\] deep_hunt_status=ran (1/1 root(s) ran)' "$WORK/run.err"; then
  ok "RAN: ledger rows deep-hunt/vector-hunt . * ran foundry-shim (one each); stderr deep_hunt_status=ran per stage"
else
  bad "ledger / status line:"; sed 's/^/      /' "$L" 2>/dev/null; grep 'deep_hunt_status' "$WORK/run.err" | sed 's/^/      /'
fi
if grep -q '^PROVER|target=contracts/Vault.sol|shim=1|toml=[0-9a-f]*|vault=1$' "$P"; then
  ok "the prover's staged repo/foundry.toml is the shim's (marker line) and the target is contracts/Vault.sol"
else
  bad "prover probe:"; grep '^PROVER' "$P" | sed 's/^/      /'
fi
N_PROBE="$(grep -c "^FORGE|cwd=$O/.foundry-shim/_root|shim=1|args=build$" "$P")"
if [ "$N_PROBE" = 1 ] && grep -q "^FORGE|cwd=$O/deep-hunt/contracts-C6/run/repo|shim=1|" "$P"; then
  ok "forge ran ONCE in the shim (the probe, shared by STAGE 4.5 and 4.6) and then in the staged cell repo"
else
  bad "forge invocations (probe count $N_PROBE):"; grep '^FORGE' "$P" | sed 's/^/      /'
fi
if grep -q "^VHPOC|repo=$O/.foundry-shim/_root|target=contracts/Vault.sol$" "$P" && ! grep -q "^VHPOC|repo=$C|" "$P"; then
  ok "STAGE 4.6: the PoC runner receives --repo <out>/.foundry-shim/_root"
else
  bad "STAGE 4.6 PoC runner routing:"; grep '^VHPOC' "$P" | sed 's/^/      /'
fi
if [ ! -e "$O/.foundry-shim/_root/out" ] && [ ! -e "$O/.foundry-shim/_root/cache" ]; then
  ok "the probe's out/ + cache/ are removed (every per-cell copy stays sources-only)"
else
  bad "shim out/ or cache/ left behind"
fi

# ----------------------------------------------------------------------------------------------------------
note "4) SHIM-FAILED — forge build failure, missing deps (install off / failing / succeeding) ..."
FAKE_FORGE_RC=1 dho "$C" "$O" "$WORK/o-ff" "$WORK/p-ff" "$WORK/ff.err"; RC=$?
if [ "$RC" -eq 0 ] && grep -q '^deep-hunt	\.	\*	shim-failed	forge-build rc=1: Error (7576): Undeclared identifier' "$WORK/o-ff/deep-hunt-status.tsv" 2>/dev/null \
   && [ -z "$(find "$WORK/o-ff/deep-hunt" -maxdepth 1 -name 'contracts*' 2>/dev/null)" ] \
   && grep -q '\[deep-hunt\] deep_hunt_status=shim-failed (0/1 root(s) ran)' "$WORK/ff.err" \
   && grep -q 'deep hunt is UNMEASURED' "$WORK/ff.err"; then
  ok "forge build fails -> shim-failed 'forge-build rc=1: <first error line>', no deep-hunt cell, exit 0, stderr deep_hunt_status=shim-failed"
else
  bad "forge-build failure (rc=$RC):"; sed 's/^/      /' "$WORK/o-ff/deep-hunt-status.tsv" 2>/dev/null; tail -5 "$WORK/ff.err" | sed 's/^/      /'
fi
CN="$WORK/clone-nonm"; git_tree "$FIX" "$CN"; rm -rf "$CN/node_modules"; printf 'registry=https://registry.example.invalid/\n' > "$CN/.npmrc"
DF_FOUNDRY_SHIM_INSTALL=0 dho "$CN" "$O" "$WORK/o-dm" "$WORK/p-dm" "$WORK/dm.err"; RC=$?
if [ "$RC" -eq 0 ] && grep -q '^deep-hunt	\.	\*	shim-failed	deps-missing:@openzeppelin/contracts$' "$WORK/o-dm/deep-hunt-status.tsv" 2>/dev/null \
   && ! grep -q '^FORGE|' "$WORK/p-dm" && ! grep -q '^NPM|' "$WORK/p-dm"; then
  ok "no node_modules + DF_FOUNDRY_SHIM_INSTALL=0 -> deps-missing:@openzeppelin/contracts; neither npm nor the forge probe ran"
else
  bad "deps-missing (rc=$RC):"; sed 's/^/      /' "$WORK/o-dm/deep-hunt-status.tsv" "$WORK/p-dm" 2>/dev/null
fi
FAKE_NPM_RC=1 dho "$CN" "$O" "$WORK/o-if" "$WORK/p-if" "$WORK/if.err"; RC=$?
if [ "$RC" -eq 0 ] && grep -q '^deep-hunt	\.	\*	shim-failed	install-failed:npm rc=1$' "$WORK/o-if/deep-hunt-status.tsv" 2>/dev/null \
   && ! grep -q '^FORGE|' "$WORK/p-if"; then
  ok "npm install fails -> shim-failed install-failed:npm rc=1; the probe never runs"
else
  bad "install-failed (rc=$RC):"; sed 's/^/      /' "$WORK/o-if/deep-hunt-status.tsv" "$WORK/p-if" 2>/dev/null
fi
manifest "$CN" > "$WORK/manifest-nonm.before"
dho "$CN" "$O" "$WORK/o-in" "$WORK/p-in" "$WORK/in.err"; RC=$?
manifest "$CN" > "$WORK/manifest-nonm.after"
if [ "$RC" -eq 0 ] && grep -q '^deep-hunt	\.	\*	ran	foundry-shim$' "$WORK/o-in/deep-hunt-status.tsv" 2>/dev/null \
   && grep -q '^NPM|args=ci --ignore-scripts --prefer-offline --no-audit --no-fund|ls=package-lock.json,package.json,$' "$WORK/p-in" \
   && [ -f "$WORK/o-in/.foundry-shim/_root/node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol" ] \
   && [ ! -e "$WORK/o-in/.foundry-shim/_root.deps/node_modules" ] && [ ! -e "$CN/node_modules" ] \
   && cmp -s "$WORK/manifest-nonm.before" "$WORK/manifest-nonm.after" \
   && grep -q '^PROVER|target=contracts/Vault.sol|shim=1|' "$WORK/p-in"; then
  ok "npm install succeeds -> ran: 'npm ci --ignore-scripts ...' in a scratch dir holding only package.json + the lockfile (no .npmrc), deps node_modules deleted after the rebuild, the clone untouched"
else
  bad "install path (rc=$RC):"; sed 's/^/      /' "$WORK/o-in/deep-hunt-status.tsv" "$WORK/p-in" 2>/dev/null
fi

# ----------------------------------------------------------------------------------------------------------
note "5) SKIPPED — no toolchain config, DF_FOUNDRY_SHIM=0, a malformed knob ..."
CX="$WORK/clone-nocfg"; git_tree "$FIX" "$CX"; git -C "$CX" rm -q hardhat.config.ts; git -C "$CX" commit -qm "no config"
dho "$CX" "$O" "$WORK/o-nc" "$WORK/p-nc" "$WORK/nc.err"; RC=$?
if [ "$RC" -eq 0 ] && grep -q '^deep-hunt	\.	\*	skipped-no-foundry	no-toolchain-config$' "$WORK/o-nc/deep-hunt-status.tsv" 2>/dev/null \
   && grep -q '\[deep-hunt\] deep_hunt_status=skipped-no-foundry (0/1 root(s) ran)' "$WORK/nc.err" && [ ! -e "$WORK/o-nc/.foundry-shim" ]; then
  ok "no toolchain config -> skipped-no-foundry/no-toolchain-config, a loud status line, no shim dir"
else
  bad "no-toolchain-config (rc=$RC):"; sed 's/^/      /' "$WORK/o-nc/deep-hunt-status.tsv" 2>/dev/null
fi
DF_FOUNDRY_SHIM=0 dho "$C" "$O" "$WORK/o-sd" "$WORK/p-sd" "$WORK/sd.err"; RC=$?
if [ "$RC" -eq 0 ] && grep -q '^deep-hunt	\.	\*	skipped-no-foundry	shim-disabled$' "$WORK/o-sd/deep-hunt-status.tsv" 2>/dev/null \
   && ! grep -q '^FORGE|' "$WORK/p-sd" && [ ! -e "$WORK/o-sd/.foundry-shim" ]; then
  ok "DF_FOUNDRY_SHIM=0 restores the old skip as a loud skipped-no-foundry/shim-disabled ledger row"
else
  bad "shim-disabled (rc=$RC):"; sed 's/^/      /' "$WORK/o-sd/deep-hunt-status.tsv" 2>/dev/null
fi
DF_FOUNDRY_SHIM=yes dho "$C" "$O" "$WORK/o-bk" "$WORK/p-bk" "$WORK/bk.err"; RC=$?
DF_FOUNDRY_SHIM_BUILD_TIMEOUT_S=01 dho "$C" "$O" "$WORK/o-bk2" "$WORK/p-bk2" "$WORK/bk2.err"; RC2=$?
if [ "$RC" -eq 2 ] && grep -q 'DF_FOUNDRY_SHIM must be unset, 0 or 1' "$WORK/bk.err" && [ "$RC2" -eq 2 ]; then
  ok "a malformed DF_FOUNDRY_SHIM / DF_FOUNDRY_SHIM_BUILD_TIMEOUT_S exits 2"
else
  bad "knob validation: rc=$RC / $RC2 (want 2 / 2)"
fi

# ----------------------------------------------------------------------------------------------------------
note "6) FOUNDRY BYTE-IDENTITY — differential against origin/main's dark-factory/ ..."
TOP="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$TOP" ] || ! git -C "$TOP" cat-file -e origin/main:dark-factory/run-zone-hunt.sh 2>/dev/null; then
  skip "origin/main not available in this checkout"
elif git -C "$TOP" cat-file -e origin/main:dark-factory/lib/foundry-shim.sh 2>/dev/null; then
  skip "origin/main already carries the Foundry shim (post-merge steady state)"
else
  MAIN="$WORK/origin-main"; mkdir -p "$MAIN"
  git -C "$TOP" archive origin/main dark-factory | tar -x -C "$MAIN"
  # A HYBRID target (foundry.toml next to hardhat.config.ts) stays on the native Foundry path.
  CF="$WORK/clone-foundry"; git_tree "$FIX" "$CF"
  printf '%s\n' '[profile.default]' 'src = "contracts"' 'libs = ["node_modules", "lib"]' \
    'remappings = ["@openzeppelin/contracts/=node_modules/@openzeppelin/contracts/"]' > "$CF/foundry.toml"
  git -C "$CF" add -A && git -C "$CF" commit -qm "foundry"
  OF="$WORK/out-foundry"
  ZH_BIN="$MAIN/dark-factory/run-zone-hunt.sh" zh "$CF" "$OF" "$WORK/p-main" "$WORK/main.err" --deep-hunt --vector-hunt; RC1=$?
  mv "$OF" "$WORK/out-main"
  zh "$CF" "$OF" "$WORK/p-this" "$WORK/this.err" --deep-hunt --vector-hunt; RC2=$?
  D=""
  for f in .deep-hunt-targets.tsv .vector-hunt-targets.tsv verify/verified_findings.json; do
    cmp -s "$WORK/out-main/$f" "$OF/$f" || D="$D $f"
  done
  ( cd "$WORK/out-main/deep-hunt" && find . | LC_ALL=C sort ) > "$WORK/tree-main" 2>/dev/null
  ( cd "$OF/deep-hunt" && find . | LC_ALL=C sort ) > "$WORK/tree-this" 2>/dev/null
  cmp -s "$WORK/tree-main" "$WORK/tree-this" || D="$D deep-hunt/(tree)"
  grep -e '^PROVER' -e '^VHPOC' "$WORK/p-main" > "$WORK/pp-main"; grep -e '^PROVER' -e '^VHPOC' "$WORK/p-this" > "$WORK/pp-this"
  cmp -s "$WORK/pp-main" "$WORK/pp-this" || D="$D prover/poc-probe"
  ( cd "$WORK/out-main" && find . -maxdepth 1 | LC_ALL=C sort ) > "$WORK/top-main"
  ( cd "$OF" && find . -maxdepth 1 | LC_ALL=C sort ) > "$WORK/top-this"
  EXTRA="$(comm -13 "$WORK/top-main" "$WORK/top-this" | tr '\n' ' ')"
  if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ -z "$D" ] && [ "$EXTRA" = "./deep-hunt-status.tsv " ] \
     && [ -s "$WORK/pp-this" ] && grep -q '^deep-hunt	\.	\*	ran	foundry$' "$OF/deep-hunt-status.tsv" && [ ! -e "$OF/.foundry-shim" ]; then
    ok "a Foundry (hybrid) target: targets, verified_findings.json, the deep-hunt/ tree and every prover/PoC call == origin/main's; only deep-hunt-status.tsv is new (ran/foundry); no .foundry-shim/"
  else
    bad "Foundry byte-identity: rc=$RC1/$RC2 differs at [$D] extra top-level [$EXTRA]"
    diff "$WORK/pp-main" "$WORK/pp-this" | head -10 | sed 's/^/      /'
  fi
fi

# ----------------------------------------------------------------------------------------------------------
note "7) REAL FORGE — forge build of the fixture's shim (optional) ..."
if [ -z "$REAL_FORGE" ]; then
  skip "forge not installed"
else
  S7="$WORK/shim-real"
  python3 "$SHIMPY" build --root "$H" --clone "$H" --dest "$S7" --exclude "$H/runs-out" --exclude "$H/under-root-shim" > /dev/null 2>&1
  if ( cd "$S7" && "$REAL_FORGE" build ) > "$WORK/real-forge.log" 2>&1; then
    ok "a real forge build of the Hardhat fixture's shim succeeds"
  else
    bad "real forge build failed:"; tail -8 "$WORK/real-forge.log" | sed 's/^/      /'
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — a Hardhat-only target is deep-hunted through its Foundry shim, every outcome is on the ledger, the target stays frozen and a Foundry target is byte-identical (#2277)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
