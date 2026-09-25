#!/usr/bin/env bash
# demo-multi-root.sh — OFFLINE, DETERMINISTIC proof of #2255: a multi-project code repo (several nested
# Foundry/Hardhat project roots) gets EVERY root mapped, briefed and hunt-ready, with every path relative to the clone
# root and one additive `root` key per zone, and the deep hunt / vector hunt / PoC stages run each row in its zone's
# OWN Foundry root — while a single-root target stays byte-identical.
#
# Parts (CI floor: bash + git + python3; never needs agentis or forge — part 7 fakes both):
#   1) DETECT       lib/project_roots.py detect/resolve/root_of/zone-roots/of over fixtures/multi-root/: exactly
#                   core, legacy, market (configs under lib/, test/, mocks/, node_modules/ are never roots).
#   2) MAP auto     map-zones.sh over the clone root: zones from all 3 roots, `root` == path prefix, a rootless
#                   docs zone, unique ids + names qualified `<root>/<name>`, no lib/ or test/ token, every token
#                   exists under the clone root.
#   3) MAP explicit --project-roots core,market (and DF_PROJECT_ROOTS) drops legacy + docs; `.` is the opt-out
#                   (no `root` key, unqualified names); an invalid list exits 2.
#   4) INHERITANCE  the market abstract base gets market/src/Pair.sol as its implementor although core/src/Pair.sol
#                   declares the same contract name; `implementor` agrees; MUTATION: without `root` the name is
#                   ambiguous and the implementor becomes null (the per-root partition is load-bearing).
#   5) ROUND-TRIP   run-discovery.sh --list-cells --only "<qualified name>" yields cells for a core AND a market
#                   zone; gen-briefs.sh --fixture renders `Project root: market/`; zone-coverage init carries
#                   `root`; run-zone-hunt.sh --rehunt-gaps with --repo <clone>/core exits 3 (map needs the clone).
#   6) SINGLE-ROOT BYTE-IDENTITY
#                   (a) CI-safe: over fixtures/zone-map (no toolchain file), the same tree + a root foundry.toml,
#                       and a wrapper with ONE nested root, the default run == the `--project-roots .` run under
#                       cmp for zones.json, scope.tsv, appendix.tsv and every brief; no `root` key anywhere.
#                   (b) differential: origin/main's map-zones.sh / gen-briefs.sh / lib/zone-coverage.py over the
#                       same trees (and over the multi-root clone vs `--project-roots .`) == this tree's, byte for
#                       byte. SKIP (not fail) when origin/main is absent or already carries this code (post-merge).
#                       Includes lib/inheritance.py reach-targets (the deep-hunt REACH selection) over the same maps.
#   7) OFFLINE E2E  (#2255 PR 2) run-zone-hunt.sh --deep-hunt --vector-hunt (DEEP_HUNT_REACH=1) over the clone with a
#                   stub --agentis, a fake `forge` on PATH and the VECTOR_HUNT_POC_RUNNER seam: STAGE 4.5 target
#                   selection picks market/src/Pair.sol:Pair per root; the prover sees market's staged foundry.toml,
#                   a root-relative target and market's entry points; forge-invariant.sh runs forge inside the staged
#                   market root; the Hardhat-only legacy row and the rootless docs row are skipped per row; a merged
#                   finding keeps a clone-relative file; STAGE 4.6's PoC runner and M5's POC_REPO get <clone>/<root>;
#                   --deep-hunt-only with --repo <clone>/core exits 3.
#
# Usage:  dark-factory/demo-multi-root.sh
# Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe style: no pipefail, no arrays, no $'...', literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MAPZONES="$HERE/map-zones.sh"
GENBRIEFS="$HERE/gen-briefs.sh"
DISCOVERY="$HERE/run-discovery.sh"
ZONEHUNT="$HERE/run-zone-hunt.sh"
ROOTS="$HERE/lib/project_roots.py"
INH="$HERE/lib/inheritance.py"
ZONECOV="$HERE/lib/zone-coverage.py"
FIX="$HERE/fixtures/multi-root"
ZM_FIX="$HERE/fixtures/zone-map"

FAILS=0
note() { echo "demo-multi-root.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
for f in "$MAPZONES" "$GENBRIEFS" "$DISCOVERY" "$ZONEHUNT"; do
  [ -x "$f" ] || { note "not found / not executable: $f" >&2; exit 3; }
done
for f in "$ROOTS" "$INH" "$ZONECOV" "$FIX/zones.fixture.txt" "$FIX/briefs.fixture.txt" "$ZM_FIX/zones.fixture.txt"; do
  [ -f "$f" ] || { note "not found: $f" >&2; exit 3; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-multi-root.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# git_tree <src> <dst>: copy a fixture tree and commit it (map-zones.sh reads git file age for hardening_score).
git_tree() {
  mkdir -p "$2"
  cp -R "$1/." "$2/"
  rm -f "$2/zones.fixture.txt" "$2/briefs.fixture.txt" "$2/residuals.fixture.txt" "$2/discovery-report.golden.md"
  git -C "$2" init -q
  git -C "$2" config user.email demo@example.invalid
  git -C "$2" config user.name demo
  git -C "$2" add -A
  git -C "$2" commit -qm "fixture"
}

# jq-free JSON probes over a zones.json
zjs() { python3 - "$@"; }

CLONE="$WORK/clone"
git_tree "$FIX" "$CLONE"

# ----------------------------------------------------------------------------------------------------------
note "1) DETECT — lib/project_roots.py over fixtures/multi-root ..."
GOT="$(python3 "$ROOTS" detect --repo "$CLONE" | paste -sd, -)"
[ "$GOT" = "core,legacy,market" ] && ok "detect -> core,legacy,market (lib/, test/, mocks/, node_modules/ configs excluded)" \
  || bad "detect returned '$GOT' (want core,legacy,market)"
if RO="$(DF_LIB="$HERE/lib" python3 -B - <<'PY'
import os, sys
sys.path.insert(0, os.environ["DF_LIB"])
from project_roots import root_of
cases = [
    ("core/src/Vault.sol", ["core", "legacy", "market"], "core"),
    ("docs/Example.sol", ["core", "legacy", "market"], None),
    ("core/sub/X.sol", ["core", "core/sub"], "core/sub"),
    ("core/X.sol", ["core", "core/sub"], "core"),
    ("docs/X.sol", [".", "core"], "."),
    ("core/X.sol", [".", "core"], "core"),
    ("core2/X.sol", ["core", "market"], None),
]
bad = [c for c in cases if root_of(c[0], c[1]) != c[2]]
print("OK" if not bad else "BAD %r" % bad)
PY
)" && [ "$RO" = "OK" ]; then
  ok "root_of: segment-anchored longest prefix, '.' matches last, rootless -> None"
else
  bad "root_of regressed: $RO"
fi
python3 "$ROOTS" resolve --repo "$CLONE" --roots core >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "resolve rejects a single non-'.' root (exit 2: pass --repo <repo>/<root> instead)" || bad "resolve --roots core exited $RC (want 2)"
python3 "$ROOTS" resolve --repo "$CLONE" --roots nope,core >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "resolve rejects a missing root (exit 2)" || bad "resolve --roots nope,core exited $RC (want 2)"
python3 "$ROOTS" resolve --repo "$CLONE" --roots ../x,core >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "resolve rejects '..' (exit 2)" || bad "resolve --roots ../x,core exited $RC (want 2)"
GOT="$(python3 "$ROOTS" resolve --repo "$CLONE" --roots .)"
[ "$GOT" = "." ] && ok "resolve --roots . -> '.' (single-root opt-out)" || bad "resolve --roots . returned '$GOT'"
GOT="$(python3 "$ROOTS" resolve --repo "$CLONE" --roots ./market/,core, | paste -sd, -)"
[ "$GOT" = "core,market" ] && ok "resolve normalises + sorts + dedups an explicit list" || bad "resolve normalisation returned '$GOT'"

# ----------------------------------------------------------------------------------------------------------
note "2) MAP auto — map-zones.sh over the clone root ..."
AUTO="$WORK/map-auto"
"$MAPZONES" --repo "$CLONE" --out "$AUTO" --fixture "$FIX/zones.fixture.txt" >/dev/null 2>"$WORK/auto.err"; RC=$?
[ "$RC" -eq 0 ] && ok "map-zones.sh exits 0 over a multi-root clone" || { bad "map-zones.sh exited $RC"; sed 's/^/      /' "$WORK/auto.err"; }
grep -Fq 'map-zones.sh: multi-root target (#2255): 3 project roots [core, legacy, market] (auto)' "$WORK/auto.err" \
  && ok "one stderr line announces the multi-root mode (auto)" || bad "multi-root stderr line missing"
MSG="$(zjs "$AUTO/zones.json" "$AUTO/scope.tsv" "$CLONE" <<'PY'
import json, os, sys
zones = json.load(open(sys.argv[1]))
errs = []
ids = [z["id"] for z in zones]
want = {"core_src", "core_src_libraries", "market_src", "market_src_base", "market_src_libraries",
        "legacy_contracts", "docs"}
if set(ids) != want:
    errs.append("zone ids %r" % sorted(ids))
if len(set(ids)) != len(ids):
    errs.append("duplicate ids")
names = [z["name"] for z in zones]
if len(set(names)) != len(names):
    errs.append("duplicate names %r" % names)
by = dict((z["id"], z) for z in zones)
for zid, z in by.items():
    r = z.get("root")
    if zid == "docs":
        if r is not None:
            errs.append("docs zone carries root %r" % r)
        continue
    if not r or not all(f.startswith(r + "/") for f in z["files"]):
        errs.append("%s root %r does not prefix its files" % (zid, r))
if by.get("core_src", {}).get("name") != "core/src" or by.get("market_src", {}).get("name") != "market/src":
    errs.append("names not qualified: %r / %r" % (by.get("core_src", {}).get("name"), by.get("market_src", {}).get("name")))
if by.get("docs", {}).get("name") != "docs":
    errs.append("rootless name changed: %r" % by.get("docs", {}).get("name"))
repo = sys.argv[3]
for line in open(sys.argv[2]):
    if line.startswith("#") or not line.strip():
        continue
    for tok in line.split("|")[2].split(","):
        f = tok.strip().split("@", 1)[0]
        segs = f.split("/")
        if "lib" in segs or "test" in segs:
            errs.append("token under lib/ or test/: " + f)
        if not os.path.isfile(os.path.join(repo, f)):
            errs.append("token not under the clone root: " + f)
print("OK" if not errs else "; ".join(errs))
PY
)"
[ "$MSG" = "OK" ] && ok "zones from all 3 roots; root == path prefix; docs rootless; unique ids; names qualified core/src vs market/src; tokens clone-relative, none under lib/ or test/" \
  || bad "auto map: $MSG"

# ----------------------------------------------------------------------------------------------------------
note "3) MAP explicit — --project-roots core,market / DF_PROJECT_ROOTS / the '.' opt-out ..."
EXPL="$WORK/map-expl"
"$MAPZONES" --repo "$CLONE" --out "$EXPL" --project-roots core,market --fixture "$FIX/zones.fixture.txt" >/dev/null 2>"$WORK/expl.err"; RC=$?
GOT="$(zjs "$EXPL/zones.json" <<'PY'
import json, sys
print(",".join(sorted(set(z.get("root", "-") for z in json.load(open(sys.argv[1]))))))
PY
)"
[ "$RC" -eq 0 ] && [ "$GOT" = "core,market" ] && ok "--project-roots core,market maps only core + market (no legacy, no rootless docs zone)" \
  || bad "explicit map rc=$RC roots=$GOT"
grep -Fq '(explicit)' "$WORK/expl.err" && ok "stderr says (explicit)" || bad "explicit mode not announced"
ENVM="$WORK/map-env"
DF_PROJECT_ROOTS=core,market "$MAPZONES" --repo "$CLONE" --out "$ENVM" --fixture "$FIX/zones.fixture.txt" >/dev/null 2>&1
cmp -s "$EXPL/zones.json" "$ENVM/zones.json" && cmp -s "$EXPL/scope.tsv" "$ENVM/scope.tsv" \
  && ok "DF_PROJECT_ROOTS=core,market == --project-roots core,market (zones.json + scope.tsv)" || bad "env form differs from the flag form"
WINS="$WORK/map-wins"
DF_PROJECT_ROOTS=nope "$MAPZONES" --repo "$CLONE" --out "$WINS" --project-roots core,market --fixture "$FIX/zones.fixture.txt" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && cmp -s "$EXPL/zones.json" "$WINS/zones.json" && ok "the flag wins over DF_PROJECT_ROOTS" || bad "flag did not win over the env (rc=$RC)"
"$MAPZONES" --repo "$CLONE" --out "$WORK/map-badroot" --project-roots core --fixture "$FIX/zones.fixture.txt" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "--project-roots core (single non-'.' root) exits 2" || bad "--project-roots core exited $RC (want 2)"
DOT="$WORK/map-dot"
"$MAPZONES" --repo "$CLONE" --out "$DOT" --project-roots . --fixture "$FIX/zones.fixture.txt" >/dev/null 2>"$WORK/dot.err"
MSG="$(zjs "$DOT/zones.json" <<'PY'
import json, sys
zones = json.load(open(sys.argv[1]))
roots = [z for z in zones if "root" in z]
qual = [z["name"] for z in zones if "/" in z["name"]]
print("OK" if not roots and not qual and len(zones) == 7 else "roots=%d qualified=%r n=%d" % (len(roots), qual, len(zones)))
PY
)"
[ "$MSG" = "OK" ] && ! grep -q 'multi-root target' "$WORK/dot.err" && ok "--project-roots . -> zero root keys, unqualified names, no multi-root line (the opt-out)" \
  || bad "'.' opt-out: $MSG"

# ----------------------------------------------------------------------------------------------------------
note "4) INHERITANCE — per-root partitions (failure mode (d) across roots) ..."
GOT="$(zjs "$AUTO/zones.json" <<'PY'
import json, sys
for z in json.load(open(sys.argv[1])):
    if z["id"] == "market_src_base":
        print(",".join(str(e.get("implementor")) for e in z.get("implementation_appendix", [])))
PY
)"
[ "$GOT" = "market/src/Pair.sol" ] && ok "market/src/base's appendix implementor is market/src/Pair.sol (core/src/Pair.sol declares the same name)" \
  || bad "market base implementor = '$GOT' (want market/src/Pair.sol)"
if [ -f "$AUTO/appendix.tsv" ] && grep -q '^market/base	market/src/Pair.sol@' "$AUTO/appendix.tsv"; then
  ok "appendix.tsv row keyed by the qualified subsystem market/base"
else
  bad "appendix.tsv has no market/base -> market/src/Pair.sol row"
fi
GOT="$(python3 "$INH" implementor --repo "$CLONE" --file market/src/base/PairCore.sol | cut -f1)"
[ "$GOT" = "market/src/Pair.sol" ] && ok "inheritance.py implementor --file market/src/base/PairCore.sol agrees (clone-relative)" \
  || bad "implementor returned '$GOT'"
# MUTATION: the same mechanical model without `root` -> one partition -> `Pair` is ambiguous -> implementor null.
zjs "$AUTO/zones.json" "$WORK/mech-root.json" "$WORK/mech-noroot.json" <<'PY'
import json, sys
zones = json.load(open(sys.argv[1]))
mech = []
for z in zones:
    m = {"id": z["id"], "name": z["id"], "files": z["files"], "scope_files": list(z["files"])}
    if z.get("root"):
        m["root"] = z["root"]
    mech.append(m)
json.dump(mech, open(sys.argv[2], "w"))
for m in mech:
    m.pop("root", None)
json.dump(mech, open(sys.argv[3], "w"))
PY
probe_impl() {
  python3 "$INH" appendix --zones "$1" --repo "$CLONE" > "$1.appended" 2>/dev/null
  zjs "$1.appended" <<'PY'
import json, sys
for z in json.load(open(sys.argv[1])):
    if z["id"] == "market_src_base":
        print(",".join(str(e.get("implementor")) for e in z.get("implementation_appendix", [])))
PY
}
WITH="$(probe_impl "$WORK/mech-root.json")"
WITHOUT="$(probe_impl "$WORK/mech-noroot.json")"
if [ "$WITH" = "market/src/Pair.sol" ] && [ "$WITHOUT" = "None" ]; then
  ok "MUTATION: stripping root makes the implementor null — the per-root partition is load-bearing"
else
  bad "mutation check: with root='$WITH' (want market/src/Pair.sol), without root='$WITHOUT' (want None)"
fi

# ----------------------------------------------------------------------------------------------------------
note "5) ROUND-TRIP — run-discovery --only, gen-briefs, zone-coverage, project_roots of/zone-roots, the re-use guard ..."
for Q in core/src market/src; do
  N="$("$DISCOVERY" --repo "$CLONE" --scope "$AUTO/scope.tsv" --only "$Q" --list-cells 2>/dev/null | grep -c '^CELL|')"
  [ "${N:-0}" -ge 1 ] && ok "run-discovery.sh --list-cells --only '$Q' -> $N cell(s)" || bad "--only '$Q' yielded ${N:-0} cells"
done
BR="$WORK/briefs"
"$GENBRIEFS" --zones "$AUTO/zones.json" --scope "$AUTO/scope.tsv" --out "$BR" --repo "$CLONE" --fixture "$FIX/briefs.fixture.txt" >/dev/null 2>&1
if grep -Fqx 'Project root: market/ — a separate Foundry/Hardhat project inside this repository; its imports and remappings resolve against that directory. Paths above are relative to the repository root.' "$BR/briefs/brief_market_src.md" 2>/dev/null \
   && ! grep -q '^Project root:' "$BR/briefs/brief_docs.md" 2>/dev/null; then
  ok "gen-briefs: the market brief carries 'Project root: market/'; the rootless docs brief has no such line"
else
  bad "gen-briefs Project root line missing/misplaced"
fi
python3 "$ZONECOV" init --zones "$AUTO/zones.json" --out "$WORK/cov.json" --zone-list "$WORK/zone-list.tsv" --repo clone --commit x >/dev/null 2>&1
MSG="$(zjs "$WORK/cov.json" <<'PY'
import json, sys
zs = dict((z["id"], z) for z in json.load(open(sys.argv[1]))["zones"])
ok = zs["core_src"].get("root") == "core" and zs["market_src_base"].get("root") == "market" and "root" not in zs["docs"]
print("OK" if ok else "BAD")
PY
)"
[ "$MSG" = "OK" ] && grep -q '^market_src	market/src$' "$WORK/zone-list.tsv" \
  && ok "zone-coverage init carries root (not on the rootless zone); .zone-list.tsv names are qualified" || bad "zone-coverage root/zone-list: $MSG"
GOT="$(python3 "$ROOTS" zone-roots --zones "$AUTO/zones.json" | grep -c .)"
[ "$GOT" -eq 6 ] && ok "project_roots.py zone-roots lists the 6 rooted zones" || bad "zone-roots listed $GOT rows (want 6)"
GOT="$(python3 "$ROOTS" of --zones "$AUTO/zones.json" --repo "$CLONE" --path market/src/Pair.sol)"
[ "$GOT" = "market	src/Pair.sol" ] && ok "of: clone-relative path -> <root> + path within root" || bad "of (prefixed) returned '$GOT'"
GOT="$(python3 "$ROOTS" of --zones "$AUTO/zones.json" --repo "$CLONE" --path src/base/PairCore.sol)"
[ "$GOT" = "market	src/base/PairCore.sol" ] && ok "of: a root-relative path resolves when exactly one root holds it" || bad "of (fallback) returned '$GOT'"
GOT="$(python3 "$ROOTS" of --zones "$AUTO/zones.json" --repo "$CLONE" --path src/Pair.sol)"
[ -z "$GOT" ] && ok "of: an ambiguous root-relative path (both roots hold it) prints nothing" || bad "of (ambiguous) returned '$GOT'"
# --rehunt-gaps re-uses a frozen multi-root map: --repo must be the clone root it was made against.
RH="$WORK/rehunt-out"
mkdir -p "$RH/map" "$RH/briefs" "$RH/coverage"
cp "$AUTO/zones.json" "$AUTO/scope.tsv" "$RH/map/"
cp -R "$BR/briefs" "$RH/briefs/"
cp "$WORK/cov.json" "$RH/coverage/zone-coverage.json"
DARK_FACTORY_DIR="$WORK/df-registry" "$ZONEHUNT" --repo "$CLONE/core" --out "$RH" --rehunt-gaps --backend mock \
  --agentis "$WORK/no-such-agentis" >/dev/null 2>"$WORK/rehunt.err"; RC=$?
[ "$RC" -eq 3 ] && grep -q 'a multi-root map needs the clone root' "$WORK/rehunt.err" \
  && ok "run-zone-hunt.sh --rehunt-gaps --repo <clone>/core over a multi-root map exits 3 (map needs the clone root)" \
  || { bad "rehunt guard: rc=$RC (want 3)"; sed 's/^/      /' "$WORK/rehunt.err" | tail -5; }

# ----------------------------------------------------------------------------------------------------------
note "6a) SINGLE-ROOT BYTE-IDENTITY — default run == '--project-roots .' run ..."
T1="$WORK/t1"; git_tree "$ZM_FIX" "$T1"
T2="$WORK/t2"; git_tree "$ZM_FIX" "$T2"; printf '[profile.default]\nsrc = "contracts"\n' > "$T2/foundry.toml"
git -C "$T2" add -A; git -C "$T2" commit -qm "root foundry.toml"
T3="$WORK/t3"; mkdir -p "$T3/proj"; cp -R "$ZM_FIX/." "$T3/proj/"; rm -f "$T3/proj/"*.txt "$T3/proj/"*.md
printf '[profile.default]\nsrc = "contracts"\n' > "$T3/proj/foundry.toml"
git -C "$T3" init -q; git -C "$T3" config user.email demo@example.invalid; git -C "$T3" config user.name demo
git -C "$T3" add -A; git -C "$T3" commit -qm "wrapper with one nested root"
ZMFX="$ZM_FIX/zones.fixture.txt"
[ "$(python3 "$ROOTS" detect --repo "$T3" | paste -sd, -)" = "proj" ] && ok "t3 is a wrapper with exactly ONE nested root (proj)" || bad "t3 detection drifted"

# run_pair <map-zones> <gen-briefs> <tree> <out> [extra map-zones args...]
run_pair() {
  _mz="$1"; _gb="$2"; _tree="$3"; _out="$4"; shift 4
  "$_mz" --repo "$_tree" --out "$_out/map" --fixture "$ZMFX" "$@" >/dev/null 2>&1 || return 1
  "$_gb" --zones "$_out/map/zones.json" --scope "$_out/map/scope.tsv" --out "$_out/briefs" --repo "$_tree" \
    --fixture "$ZM_FIX/briefs.fixture.txt" >/dev/null 2>&1 || return 1
}
# same_tree <out-a> <out-b>: zones.json, scope.tsv, appendix.tsv (when either has it) and every brief file.
same_tree() {
  for _f in map/zones.json map/scope.tsv; do cmp -s "$1/$_f" "$2/$_f" || { echo "$_f"; return 1; }; done
  if [ -f "$1/map/appendix.tsv" ] || [ -f "$2/map/appendix.tsv" ]; then
    cmp -s "$1/map/appendix.tsv" "$2/map/appendix.tsv" || { echo "map/appendix.tsv"; return 1; }
  fi
  _la="$(cd "$1/briefs/briefs" && ls | paste -sd, -)"; _lb="$(cd "$2/briefs/briefs" && ls | paste -sd, -)"
  [ "$_la" = "$_lb" ] || { echo "brief set ($_la vs $_lb)"; return 1; }
  for _b in $(cd "$1/briefs/briefs" && ls); do cmp -s "$1/briefs/briefs/$_b" "$2/briefs/briefs/$_b" || { echo "briefs/$_b"; return 1; }; done
  return 0
}
for T in t1 t2 t3; do
  run_pair "$MAPZONES" "$GENBRIEFS" "$WORK/$T" "$WORK/$T-def" && run_pair "$MAPZONES" "$GENBRIEFS" "$WORK/$T" "$WORK/$T-dot" --project-roots .
  if D="$(same_tree "$WORK/$T-def" "$WORK/$T-dot")" && ! grep -q '"root"' "$WORK/$T-def/map/zones.json"; then
    ok "$T: default == --project-roots . (zones.json, scope.tsv, appendix.tsv, every brief) and no root key"
  else
    bad "$T: default run differs from the '.' run (${D:-root key present})"
  fi
done

# ----------------------------------------------------------------------------------------------------------
note "6b) SINGLE-ROOT BYTE-IDENTITY — differential against origin/main ..."
TOP="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$TOP" ] || ! git -C "$TOP" cat-file -e origin/main:dark-factory/map-zones.sh 2>/dev/null; then
  skip "origin/main not available in this checkout — part 6a's in-tree identity stands in"
else
  SAME=1
  for P in map-zones.sh gen-briefs.sh lib/inheritance.py lib/zone-coverage.py; do
    git -C "$TOP" show "origin/main:dark-factory/$P" 2>/dev/null | cmp -s - "$HERE/$P" || SAME=0
  done
  if [ "$SAME" -eq 1 ]; then
    skip "origin/main already carries this code (post-merge steady state) — part 6a stands in"
  else
    MAIN="$WORK/main"; mkdir -p "$MAIN"
    git -C "$TOP" archive origin/main:dark-factory map-zones.sh gen-briefs.sh audit-delta.sh lib auditor | tar -x -C "$MAIN"
    for T in t1 t2 t3; do
      run_pair "$MAIN/map-zones.sh" "$MAIN/gen-briefs.sh" "$WORK/$T" "$WORK/$T-main"
      if D="$(same_tree "$WORK/$T-main" "$WORK/$T-def")"; then
        ok "$T: this tree's default run == origin/main's (zones.json, scope.tsv, appendix.tsv, every brief)"
      else
        bad "$T: differs from origin/main at $D"
      fi
      # #2255 PR 2: the deep-hunt REACH selection over a single-root map (no `root` key) is origin/main's, byte for byte.
      python3 "$MAIN/lib/inheritance.py" reach-targets --zones "$WORK/$T-def/map/zones.json" --repo "$WORK/$T" --max 3 > "$WORK/$T-reach-main.tsv" 2>&1
      python3 "$INH" reach-targets --zones "$WORK/$T-def/map/zones.json" --repo "$WORK/$T" --max 3 > "$WORK/$T-reach-new.tsv" 2>&1
      if cmp -s "$WORK/$T-reach-main.tsv" "$WORK/$T-reach-new.tsv"; then
        ok "$T: inheritance.py reach-targets == origin/main's ($(grep -c . "$WORK/$T-reach-new.tsv") row(s))"
      else
        bad "$T: reach-targets differs from origin/main"
      fi
    done
    # The multi-root clone: origin/main's view is exactly this tree's '.' opt-out view — but only while origin/main
    # PREDATES the multi-root layer. Once it carries lib/project_roots.py its default view of the clone is itself
    # multi-root, so a later PR that touches one of the four files above must not be compared against it here.
    if git -C "$TOP" cat-file -e origin/main:dark-factory/lib/project_roots.py 2>/dev/null; then
      skip "multi-root clone: origin/main already maps every root, so its default view is not the '.' view — part 6a stands in"
    else
    "$MAIN/map-zones.sh" --repo "$CLONE" --out "$WORK/clone-main/map" --fixture "$FIX/zones.fixture.txt" >/dev/null 2>&1
    "$MAIN/gen-briefs.sh" --zones "$WORK/clone-main/map/zones.json" --scope "$WORK/clone-main/map/scope.tsv" \
      --out "$WORK/clone-main/briefs" --repo "$CLONE" --fixture "$FIX/briefs.fixture.txt" >/dev/null 2>&1
    mkdir -p "$WORK/clone-dot"; cp -R "$DOT" "$WORK/clone-dot/map"
    "$GENBRIEFS" --zones "$DOT/zones.json" --scope "$DOT/scope.tsv" --out "$WORK/clone-dot/briefs" --repo "$CLONE" \
      --fixture "$FIX/briefs.fixture.txt" >/dev/null 2>&1
    if D="$(same_tree "$WORK/clone-main" "$WORK/clone-dot")"; then
      ok "multi-root clone: '--project-roots .' == origin/main's single-root view, byte for byte"
    else
      bad "multi-root clone: the '.' opt-out differs from origin/main at $D"
    fi
    fi
    # zone-coverage init: identical record (timestamps normalised) + identical .zone-list.tsv.
    python3 "$MAIN/lib/zone-coverage.py" init --zones "$WORK/t1-def/map/zones.json" --out "$WORK/cov-main.json" \
      --zone-list "$WORK/zl-main.tsv" --repo r --commit c --zone-cell-budget 0 --run-cell-budget 0 >/dev/null 2>&1
    python3 "$ZONECOV" init --zones "$WORK/t1-def/map/zones.json" --out "$WORK/cov-new.json" \
      --zone-list "$WORK/zl-new.tsv" --repo r --commit c --zone-cell-budget 0 --run-cell-budget 0 >/dev/null 2>&1
    norm() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("started_at",None); d.pop("updated_at",None); print(json.dumps(d, sort_keys=True))' "$1"; }
    if [ "$(norm "$WORK/cov-main.json")" = "$(norm "$WORK/cov-new.json")" ] && cmp -s "$WORK/zl-main.tsv" "$WORK/zl-new.tsv"; then
      ok "zone-coverage init: the single-root record + .zone-list.tsv equal origin/main's"
    else
      bad "zone-coverage init differs from origin/main on a single-root map"
    fi
  fi
fi

# ----------------------------------------------------------------------------------------------------------
note "7) OFFLINE E2E — STAGE 4.5 / 4.6 / M5 stage each row in its zone's OWN Foundry root ..."
# One run-zone-hunt.sh pass over a fresh clone of the fixture: --map-fixture / --brief-fixture / --pass-fixture, a
# stub --agentis for every substrate call (hunter, refuter, invariant prover, coordinator), a fake `forge` first on
# PATH (so the REAL evm-harness/forge-invariant.sh runs and its forge invocation is observable without Foundry), and
# the VECTOR_HUNT_POC_RUNNER seam. DEEP_HUNT_REACH=1 so the per-root reach selection and entry-point enumeration
# are exercised. The map fixture adds custody to market/src/base, legacy and docs, so a Hardhat-only root and a
# rootless zone each reach the deep-hunt / vector-hunt row loops and are skipped there.
E2E="$WORK/e2e-clone"; git_tree "$FIX" "$E2E"
E2E_OUT="$WORK/e2e-out"
PROBE="$WORK/e2e-probe.log"; : > "$PROBE"
E2E_FIX="$WORK/e2e-zones.fixture.txt"
cat "$FIX/zones.fixture.txt" > "$E2E_FIX"
printf 'CUSTODY|market_src_base|true\nCUSTODY|legacy_contracts|true\nCUSTODY|docs|true\n' >> "$E2E_FIX"
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/forge" <<'FORGEEOF'
#!/bin/sh
# fake forge: record WHERE forge-invariant.sh ran it (cwd = the staged project root) and WHICH foundry.toml it saw.
echo "FORGE|cwd=$PWD|root=$(sed -n 's/^# fixture-root: //p' foundry.toml 2>/dev/null)" >> "$MR_PROBE_LOG"
exit 0
FORGEEOF
chmod +x "$FAKEBIN/forge"
STUB="$WORK/agentis-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
set -u
cmd="${1:-}"; sub="${2:-}"
case "$cmd" in
  init) mkdir -p .agentis; exit 0 ;;
  memo)
    if [ "$sub" = "get" ] && [ "${3:-}" = "coordinator:pass_result" ] && [ -f .agentis/pass_result ]; then
      cat .agentis/pass_result
    fi
    exit 0 ;;
  go)
    case "$sub" in
      hunter.ag)
        if [ -z "${DEPTH_TARGET:-}" ] && [ "${SUBSYSTEM:-}" = "market/src" ] && [ "${HUNT_CLASS:-}" = "C1" ]; then
          echo "CANDIDATE|market/src/Pair.sol:_settle:8|C1|High|settle pays out without a balance check|call settle with more than the balance"
        else
          echo "SAFE"
        fi
        exit 0 ;;
      refuter.ag)
        echo "VERDICT|REAL|${CAND_FILE_FN:-}|${CAND_CLASS:-}|survived a hostile read"
        exit 0 ;;
      invariant-prover.ag)
        # cwd == the run dir; repo/ is the staged copy of the project root run-invariant-hunt.sh was given.
        tf="${TARGET_FN:-}"
        eps="$(grep '^EP|' entry-points.tsv 2>/dev/null | cut -d'|' -f2 | paste -sd, -)"
        rt="$(sed -n 's/^# fixture-root: //p' repo/foundry.toml 2>/dev/null)"
        echo "PROVER|target=$tf|root=$rt|eps=$eps" >> "$MR_PROBE_LOG"
        printf 'contract InvProbe {\n    function invariant_probe() public pure returns (bool) { return true; }\n}\n' > "${INV_OUT:-repo/test/Inv.t.sol}"
        bash "${FORGE_INVARIANT:-}" --repo "${INV_REPO:-}" --target "${INV_OUT:-}" --match invariant >/dev/null 2>&1 || true
        # Only market's Pair breaks (core also has a src/Pair.sol: the root, not the path, decides).
        case "$rt:$tf" in
          market:src/Pair.sol*) echo "INVARIANT|$tf|FINDING"; echo "STEP|settle(1)" ;;
          *) echo "INVARIANT|$tf|CLEAN" ;;
        esac
        exit 0 ;;
      coordinator.ag)
        echo "COORD|loc=${FINDING_LOCATION:-}|poc_repo=${POC_REPO:-}|poc_target=${POC_TARGET:-}" >> "$MR_PROBE_LOG"
        printf '%s' "HALTED-TEST" > .agentis/pass_result
        echo "PASS|HALTED-TEST"
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
# VECTOR_HUNT_POC_RUNNER seam: record the --repo / --target the vector-hunt engine handed the PoC stage.
r=""; t=""
while [ $# -gt 0 ]; do
  case "$1" in --repo) r="$2"; shift 2 ;; --target) t="$2"; shift 2 ;; *) shift ;; esac
done
echo "VHPOC|repo=$r|target=$t" >> "$MR_PROBE_LOG"
echo "POC|$t|CLEAN"
exit 0
POCEOF
chmod +x "$POCSTUB"
PATH="$FAKEBIN:$PATH" MR_PROBE_LOG="$PROBE" DEEP_HUNT_REACH=1 VECTOR_HUNT_POC_RUNNER="$POCSTUB" \
  DARK_FACTORY_DIR="$WORK/df-registry" \
  "$ZONEHUNT" --repo "$E2E" --out "$E2E_OUT" --backend mock --agentis "$STUB" \
    --map-fixture "$E2E_FIX" --brief-fixture "$FIX/briefs.fixture.txt" \
    --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
    --in-scope "the whole in-scope program" --deep-hunt --vector-hunt >"$WORK/e2e.out" 2>"$WORK/e2e.err"; RC=$?
if [ "$RC" -eq 0 ]; then
  ok "run-zone-hunt.sh --deep-hunt --vector-hunt over the multi-root clone exits 0"
else
  bad "run-zone-hunt.sh exited $RC"; tail -30 "$WORK/e2e.err" | sed 's/^/      /'
fi
if [ "$(grep -c . "$E2E_OUT/.deep-hunt-roots.tsv" 2>/dev/null)" = "6" ] && grep -q 'multi-root target (#2255): project roots \[core legacy market\]' "$WORK/e2e.err"; then
  ok "STAGE 4.5: .deep-hunt-roots.tsv lists the 6 rooted zones; the multi-root mode is announced"
else
  bad ".deep-hunt-roots.tsv / multi-root line missing"
fi
# TARGET SELECTION: the per-root reach pick for the market base is market's concrete Pair, clone-relative.
if grep -q '^market_src_base	market/src/Pair.sol:Pair	C6$' "$E2E_OUT/.deep-hunt-targets.tsv" 2>/dev/null \
   && grep -q '^core_src	core/src/Vault.sol:Vault	C6$' "$E2E_OUT/.deep-hunt-targets.tsv"; then
  ok "STAGE 4.5 target selection: market/src/base -> market/src/Pair.sol:Pair (per-root reach; core also declares Pair), core -> core/src/Vault.sol:Vault — clone-relative rows"
else
  bad "STAGE 4.5 target rows:"; sed 's/^/      /' "$E2E_OUT/.deep-hunt-targets.tsv" 2>/dev/null
fi
# ENTRY POINTS: the prover ran over market's OWN staged root, with a root-relative target and market's settle.
if grep -q '^PROVER|target=src/Pair.sol:Pair|root=market|eps=.*settle' "$PROBE"; then
  ok "STAGE 4.5 entry points: the prover saw repo/foundry.toml of root 'market', target src/Pair.sol:Pair and the settle entry point"
else
  bad "market prover probe missing:"; grep '^PROVER' "$PROBE" | sed 's/^/      /'
fi
grep -q '^PROVER|target=src/Vault.sol:Vault|root=core|' "$PROBE" \
  && ok "a core row stages core (target src/Vault.sol:Vault)" || bad "core prover probe missing"
# FORGE: forge-invariant.sh ran forge INSIDE the staged market root, against market's foundry.toml.
if grep -q '^FORGE|cwd=.*/deep-hunt/market_src_base-C6-Pair/run/repo|root=market$' "$PROBE"; then
  ok "STAGE 4.5 forge invocation: cwd = the staged copy of market/, foundry.toml = market's"
else
  bad "no forge invocation in the market root:"; grep '^FORGE' "$PROBE" | sed 's/^/      /'
fi
[ ! -e "$E2E_OUT/deep-hunt/market_src_base-C6-Pair/run/repo/core" ] && [ ! -e "$E2E_OUT/deep-hunt/market_src_base-C6-Pair/run/repo/market" ] \
  && ok "only the market root was staged (no sibling root in the run dir)" || bad "the run dir staged more than the market root"
if grep -q "zone 'legacy_contracts' root 'legacy' is not a Foundry project — row skipped (#2255)" "$WORK/e2e.err" \
   && grep -q "\[deep-hunt\] zone 'docs' lies outside every project root" "$WORK/e2e.err" \
   && [ -z "$(find "$E2E_OUT/deep-hunt" -maxdepth 1 \( -name 'legacy_contracts-*' -o -name 'docs-*' \) 2>/dev/null)" ]; then
  ok "the Hardhat-only legacy row and the rootless docs row are skipped per row, with a log line"
else
  bad "legacy/docs per-row skips missing"
fi
MSG="$(zjs "$E2E_OUT/verify/verified_findings.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])).get("verified", [])
inv = [f for f in v if f.get("source") == "invariant-hunt"]
ok = inv and all(f.get("file") == "market/src/Pair.sol" and str(f.get("location", "")).startswith("market/src/Pair.sol:") for f in inv)
print("OK" if ok else "BAD %r" % [(f.get("source"), f.get("file"), f.get("location")) for f in v])
PY
)"
[ "$MSG" = "OK" ] && ok "the merged deep-hunt finding keeps a CLONE-relative file/location (market/src/Pair.sol)" || bad "merged deep-hunt entry: $MSG"
# STAGE 4.6: the vector-hunt engine and its PoC runner get the zone's root + a root-relative target.
if grep -q "^VHPOC|repo=$E2E/market|target=src/" "$PROBE" && grep -q "^VHPOC|repo=$E2E/core|target=src/" "$PROBE" \
   && ! grep -q "^VHPOC|repo=$E2E|" "$PROBE" \
   && grep -q "\[vector-hunt\] zone 'legacy_contracts' root 'legacy' is not a Foundry project" "$WORK/e2e.err"; then
  ok "STAGE 4.6: the PoC runner receives --repo <clone>/market and <clone>/core with root-relative targets; legacy skipped"
else
  bad "STAGE 4.6 routing:"; grep '^VHPOC' "$PROBE" | sort -u | sed 's/^/      /'
fi
# M5: the PoC stage of a market finding builds in <clone>/market.
if grep -q "^COORD|loc=market/src/Pair.sol:[^|]*|poc_repo=$E2E/market|poc_target=Pair.sol$" "$PROBE" \
   && ! grep -q "^COORD|.*|poc_repo=$E2E|" "$PROBE"; then
  ok "M5: every market finding reaches the PoC stage with POC_REPO=<clone>/market"
else
  bad "M5 POC_REPO:"; grep '^COORD' "$PROBE" | sed 's/^/      /'
fi
DARK_FACTORY_DIR="$WORK/df-registry" "$ZONEHUNT" --repo "$E2E/core" --out "$E2E_OUT" --deep-hunt --deep-hunt-only \
  --backend mock --agentis "$STUB" >/dev/null 2>"$WORK/dho.err"; RC=$?
[ "$RC" -eq 3 ] && grep -q 'a multi-root map needs the clone root' "$WORK/dho.err" \
  && ok "--deep-hunt-only --repo <clone>/core over the multi-root out exits 3 (the map needs the clone root)" \
  || bad "--deep-hunt-only guard: rc=$RC (want 3)"

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — every project root of a multi-project repo is mapped and deep-hunted in its own root; single-root output is byte-identical (#2255)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
