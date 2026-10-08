#!/usr/bin/env bash
# tools/test-deep-hunt-plan.sh -- deterministic offline guard for #2298 (dark-factory): the STAGE 4.5 PLAN FILE.
#
# run-zone-hunt.sh writes <out>/deep-hunt/plan.json (schema deep-hunt-plan/v1) BEFORE the first deep-hunt cell
# runs: one `selected` row per cell it will run (slot = the exact dir under deep-hunt/) and one `capped` row per
# routable lens the --deep-hunt-max-lenses cap cut. hunt-dashboard.py reads that file as the ONLY source of its DEPTH
# rows (planned_deep_rows(), the client-side copy of the selection that drifted in #1953/#2108/#2113, is gone), so
# the plan and the cells it names must agree exactly. The default cap is 3 (was 2).
#
# Offline by construction, same harness as tools/test-deep-hunt-composable-lens.sh: the #1713 deep-hunt fixture
# (bench/corpus-bench/fixtures/deep-hunt, consumed READ-ONLY) driven through the --map-fixture / --brief-fixture /
# --pass-fixture / --invariant-fixture seams plus its --agentis stub. No LLM, no forge, no network. The fixture's
# custody zone ranks only C6,C10 (ONE routable lens), so this test maps it with its own zones fixture ranking
# C6,C2,C5 — three routable lenses — to exercise the cap. Auto-discovered by tools/colony-lint.sh's
# `tools/test-*.sh` loop.
#
# Assertions:
#   (a) SOURCE GUARDS: DEEP_HUNT_MAX_LENSES=3 is the default; the `dh_write_plan planned` call precedes the
#       `    while dh_pass_begin; do` loop; every `DZOUT=` assignment lives inside dh_row_cell (ONE slot naming).
#   (b) DEFAULT RUN: plan.json is schema v1, status planned, max_lenses 3, no capped row; the selected slot set ==
#       the deep-hunt/*/ dir set == the .deep-hunt-targets.tsv (zone-class) set.
#   (c) --deep-hunt-max-lenses 1 on the 3-lens zone: the ranked leader is selected, the other two are `capped`
#       rows (cap max-lenses) and NO dir exists for them.
#   (d) SIDE-CHANNEL ISOLATION: the extracted selection python prints byte-identical stdout with and without
#       DEEP_HUNT_CAPPED_TSV, and writes the capped side file only when the variable is set.
#   (e) SKIP: a non-Foundry target with DF_FOUNDRY_SHIM=0 writes status skipped, a non-empty reason and rows [].
#   (f) ROUND TRIP: hunt-dashboard.py --emit-model over the real capped out dir lists DEPTH rows == plan rows, and
#       the exited capped run is never complete and never 100 %.
#
# Usage: bash tools/test-deep-hunt-plan.sh
# Exit: 0 = held, 1 = regressed, 3 = missing prerequisite.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZONEHUNT="$REPO_ROOT/dark-factory/run-zone-hunt.sh"
DASH="$REPO_ROOT/dark-factory/hunt-dashboard/hunt-dashboard.py"
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
[ -f "$DASH" ] || { echo "[SKIP] hunt-dashboard.py not found: $DASH" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
for f in foundry.toml briefs.fixture.txt handler-fixture.t.sol agentis-stub.sh; do
    [ -f "$FIX/$f" ] || { echo "[SKIP] deep-hunt fixture missing: $FIX/$f" >&2; exit 3; }
done

# ----------------------------------------------------------------------------------------------------------
# (a) source guards
# ----------------------------------------------------------------------------------------------------------
a_fail=""
grep -q '^DEEP_HUNT_MAX_LENSES=3 ' "$ZONEHUNT" || a_fail="${a_fail} default-not-3"
PLAN_LN="$(grep -n '^    dh_write_plan planned ' "$ZONEHUNT" | head -1 | cut -d: -f1)"
LOOP_LN="$(grep -nx '    while dh_pass_begin; do' "$ZONEHUNT" | head -1 | cut -d: -f1)"
if [ -z "$PLAN_LN" ] || [ -z "$LOOP_LN" ] || [ "$PLAN_LN" -ge "$LOOP_LN" ]; then
    a_fail="${a_fail} plan-write-not-before-loop[plan=${PLAN_LN:-none},loop=${LOOP_LN:-none}]"
fi
# every DZOUT= assignment must sit inside the dh_row_cell() body (the ONE slot-naming implementation)
STRAY="$(awk '/^dh_row_cell\(\) \{/ {f=1} /DZOUT=/ && !f {print NR} f && /^}/ {f=0}' "$ZONEHUNT")"
[ -z "$STRAY" ] || a_fail="${a_fail} DZOUT-assigned-outside-dh_row_cell[lines:$(echo "$STRAY" | tr '\n' ' ')]"
INFN="$(awk '/^dh_row_cell\(\) \{/ {f=1} /DZOUT=/ && f {n++} f && /^}/ {f=0} END {print n+0}' "$ZONEHUNT")"
[ "$INFN" -ge 1 ] || a_fail="${a_fail} no-DZOUT-in-dh_row_cell"
if [ -z "$a_fail" ]; then
    pass "(a) default max-lenses 3, plan written before the cell loop, DZOUT named only inside dh_row_cell"
else
    fail "(a) source guards" "missing piece(s):$a_fail"
fi

# ----------------------------------------------------------------------------------------------------------
# Offline target: the #1713 fixture tree + a zones fixture whose custody zone ranks THREE routable lenses.
# ----------------------------------------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/deep-hunt-plan.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# A private forge-slot pool: the host-wide pool may be held by a live hunt, and this test must not wait on it.
export FORGE_SLOTS_DIR="$WORK/forge-slots"

REPO="$WORK/target"
mkdir -p "$REPO"
cp "$FIX/foundry.toml" "$REPO/foundry.toml"
cp -R "$FIX/src" "$REPO/src"
git -C "$REPO" init -q
git -C "$REPO" config user.email demo@example.invalid
git -C "$REPO" config user.name "demo"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "deep-hunt plan fixture target"

ZFIX="$WORK/zones.fixture.txt"
cat > "$ZFIX" <<'TXT'
ZONE|src|value vault|C6,C2,C5|ERC4626-style vault with an oracle read and an admin role
ZONE|src_periphery|views|C1|read-only view helpers, no value custody
CUSTODY|src|true
CUSTODY|src_periphery|false
TXT

STUB="$WORK/agentis-stub"
cp "$FIX/agentis-stub.sh" "$STUB"; chmod +x "$STUB"

BASE="$WORK/base"
"$ZONEHUNT" --repo "$REPO" --out "$BASE" --drop-dir "$BASE/drop" --scope-hint src \
    --backend mock --agentis "$STUB" \
    --map-fixture "$ZFIX" --brief-fixture "$FIX/briefs.fixture.txt" \
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

# plan_check <out-dir> <py-body-file> — run a python assertion block over <out>/deep-hunt/plan.json + the out dir.
plan_py() { python3 - "$1" <<'PY'
import sys, os, json
out = sys.argv[1]
p = json.load(open(os.path.join(out, "deep-hunt", "plan.json")))
dirs = sorted(d for d in os.listdir(os.path.join(out, "deep-hunt"))
              if os.path.isdir(os.path.join(out, "deep-hunt", d)) and not d.startswith("."))
tsv = sorted({"%s-%s" % (l.split("\t")[0], l.split("\t")[2])
              for l in open(os.path.join(out, ".deep-hunt-targets.tsv")).read().splitlines() if l.strip()})
sel = sorted(r["slot"] for r in p["rows"] if r["state"] == "selected")
cap = sorted(r["slot"] for r in p["rows"] if r["state"] == "capped")
caps = sorted(r.get("cap", "") for r in p["rows"] if r["state"] == "capped")
print(json.dumps({"schema": p.get("schema"), "status": p.get("status"), "max_lenses": p.get("max_lenses"),
                  "sel": sel, "cap": cap, "caps": caps, "dirs": dirs, "tsv": tsv}, sort_keys=True))
PY
}

# ----------------------------------------------------------------------------------------------------------
# (b) default run — plan == dirs == targets TSV, max_lenses 3, all three ranked lenses selected
# ----------------------------------------------------------------------------------------------------------
OUT_D="$WORK/default"; cp -R "$BASE" "$OUT_D"; lens_only "$OUT_D"; D_RC=$?
if [ "$D_RC" -ne 0 ] || [ ! -f "$OUT_D/deep-hunt/plan.json" ]; then
    fail "(b) default lens run" "exit $D_RC, plan.json present: $([ -f "$OUT_D/deep-hunt/plan.json" ] && echo yes || echo no)"
    tail -20 "$OUT_D.log" | sed 's/^/      /' >&2
else
    B_JSON="$(plan_py "$OUT_D")"
    if printf '%s' "$B_JSON" | python3 -c '
import sys, json
m = json.load(sys.stdin); e = []
if m["schema"] != "deep-hunt-plan/v1": e.append("schema=%s" % m["schema"])
if m["status"] != "planned": e.append("status=%s" % m["status"])
if m["max_lenses"] != 3: e.append("max_lenses=%s" % m["max_lenses"])
if m["cap"]: e.append("unexpected capped rows %s" % m["cap"])
if not (m["sel"] == m["dirs"] == m["tsv"]): e.append("sel %s / dirs %s / tsv %s differ" % (m["sel"], m["dirs"], m["tsv"]))
if m["sel"] != ["src-C2", "src-C5", "src-C6"]: e.append("selected %s (want the 3 ranked lenses)" % m["sel"])
if e: print("; ".join(e)); sys.exit(1)
' >"$WORK/b.err" 2>&1; then
        pass "(b) default run: plan v1/planned/max_lenses 3; selected slots == deep-hunt dirs == targets TSV (src-C6, src-C2, src-C5)"
    else
        fail "(b) default plan matches the cells" "$(cat "$WORK/b.err")"
    fi
    if grep -q '\[deep-hunt\] plan: 3 selected + 0 capped row(s) -> ' "$OUT_D.log"; then
        pass "(b) the runner logs the plan summary line"
    else
        fail "(b) plan log line" "no '[deep-hunt] plan: 3 selected + 0 capped' line in the lens log"
    fi
    if ls "$OUT_D/deep-hunt"/.plan-*.tsv >/dev/null 2>&1; then
        fail "(b) intermediates removed" "a .plan-*.tsv intermediate was left behind"
    else
        pass "(b) the .plan-*.tsv intermediates are removed after the write"
    fi
fi

# ----------------------------------------------------------------------------------------------------------
# (c) --deep-hunt-max-lenses 1 — the ranked leader runs, the cut lenses are capped rows with no dir
# ----------------------------------------------------------------------------------------------------------
OUT_C="$WORK/capped"; cp -R "$BASE" "$OUT_C"; lens_only "$OUT_C" --deep-hunt-max-lenses 1; C_RC=$?
if [ "$C_RC" -ne 0 ] || [ ! -f "$OUT_C/deep-hunt/plan.json" ]; then
    fail "(c) capped lens run" "exit $C_RC"
    tail -20 "$OUT_C.log" | sed 's/^/      /' >&2
else
    C_JSON="$(plan_py "$OUT_C")"
    if printf '%s' "$C_JSON" | python3 -c '
import sys, json
m = json.load(sys.stdin); e = []
if m["max_lenses"] != 1: e.append("max_lenses=%s" % m["max_lenses"])
if m["sel"] != ["src-C6"]: e.append("selected=%s (want only the ranked leader src-C6)" % m["sel"])
if m["cap"] != ["src-C2", "src-C5"]: e.append("capped=%s (want src-C2, src-C5)" % m["cap"])
if m["caps"] != ["max-lenses", "max-lenses"]: e.append("cap reasons=%s" % m["caps"])
if set(m["cap"]) & set(m["dirs"]): e.append("a capped row has a cell dir: %s" % m["dirs"])
if not (m["sel"] == m["dirs"] == m["tsv"]): e.append("sel %s / dirs %s / tsv %s differ" % (m["sel"], m["dirs"], m["tsv"]))
if e: print("; ".join(e)); sys.exit(1)
' >"$WORK/c.err" 2>&1; then
        pass "(c) --deep-hunt-max-lenses 1: src-C6 selected, src-C2 + src-C5 recorded as capped (max-lenses), no dir for them"
    else
        fail "(c) capped rows recorded" "$(cat "$WORK/c.err")"
    fi
fi

# ----------------------------------------------------------------------------------------------------------
# (d) side-channel isolation over the REAL selection python, extracted verbatim from the heredoc
# ----------------------------------------------------------------------------------------------------------
awk '/> "\$DEEP_TARGETS" <</{f=1;next} f&&/^PY$/{exit} f{print}' "$ZONEHUNT" > "$WORK/select.py"
d_fail=""
if [ ! -s "$WORK/select.py" ]; then
    d_fail=" selection-heredoc-not-extracted"
else
    env -u DEEP_HUNT_CAPPED_TSV python3 "$WORK/select.py" "$BASE/map/zones.json" "$REPO" 1 0 1 0 "" > "$WORK/sel-off.tsv" 2>&1 \
        || d_fail="${d_fail} off-run-failed"
    DEEP_HUNT_CAPPED_TSV="$WORK/side.tsv" python3 "$WORK/select.py" "$BASE/map/zones.json" "$REPO" 1 0 1 0 "" > "$WORK/sel-on.tsv" 2>&1 \
        || d_fail="${d_fail} on-run-failed"
    cmp -s "$WORK/sel-off.tsv" "$WORK/sel-on.tsv" || d_fail="${d_fail} stdout-differs"
    [ -s "$WORK/sel-off.tsv" ] || d_fail="${d_fail} empty-selection"
    printf 'src\tC2\tmax-lenses\nsrc\tC5\tmax-lenses\n' > "$WORK/side.want"
    cmp -s "$WORK/side.want" "$WORK/side.tsv" || d_fail="${d_fail} side-file-wrong[$(tr '\t\n' '| ' < "$WORK/side.tsv" 2>/dev/null)]"
fi
if [ -z "$d_fail" ]; then
    pass "(d) the capped side channel is env-gated: identical selection stdout with and without DEEP_HUNT_CAPPED_TSV"
else
    fail "(d) side-channel isolation" "problem(s):$d_fail"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) a non-Foundry target with the shim off -> plan status skipped, non-empty reason, rows []
# ----------------------------------------------------------------------------------------------------------
NF_REPO="$WORK/nofoundry"
cp -R "$REPO" "$NF_REPO"; rm -f "$NF_REPO/foundry.toml"
OUT_E="$WORK/skipped"; cp -R "$BASE" "$OUT_E"
DF_FOUNDRY_SHIM=0 "$ZONEHUNT" --repo "$NF_REPO" --out "$OUT_E" --deep-hunt --deep-hunt-only \
    --invariant-fixture "$FIX/handler-fixture.t.sol" --backend mock --agentis "$STUB" >"$OUT_E.log" 2>&1
E_RC=$?
if [ ! -f "$OUT_E/deep-hunt/plan.json" ]; then
    fail "(e) skip plan written" "exit $E_RC, no plan.json"
    tail -10 "$OUT_E.log" | sed 's/^/      /' >&2
elif python3 - "$OUT_E/deep-hunt/plan.json" >"$WORK/e.err" 2>&1 <<'PY'
import sys, json
p = json.load(open(sys.argv[1])); e = []
if p.get("schema") != "deep-hunt-plan/v1": e.append("schema=%s" % p.get("schema"))
if p.get("status") != "skipped": e.append("status=%s" % p.get("status"))
if not str(p.get("reason", "")).strip(): e.append("empty reason")
if p.get("rows") != []: e.append("rows=%s" % p.get("rows"))
if e: print("; ".join(e)); sys.exit(1)
PY
then
    pass "(e) no runnable Foundry root (DF_FOUNDRY_SHIM=0): plan status skipped with a reason and rows []"
else
    fail "(e) skip plan content" "$(cat "$WORK/e.err")"
fi

# ----------------------------------------------------------------------------------------------------------
# (f) runner -> dashboard round trip over the real capped out dir (exited: an __EXIT__ marker appended)
# ----------------------------------------------------------------------------------------------------------
if [ -f "$OUT_C/deep-hunt/plan.json" ]; then
    cp "$OUT_C.log" "$WORK/capped-hunt.log"; echo "__EXIT__=0" >> "$WORK/capped-hunt.log"
    if HUNT_DASHBOARD_FAKE_PROC_ALIVE=0 HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0 \
        python3 "$DASH" --root "$WORK" --out "$OUT_C" --log "$WORK/capped-hunt.log" --emit-model > "$WORK/model.json" 2>"$WORK/model.err"; then
        if python3 - "$WORK/model.json" "$OUT_C/deep-hunt/plan.json" >"$WORK/f.err" 2>&1 <<'PY'
import sys, json
m = json.load(open(sys.argv[1])); p = json.load(open(sys.argv[2])); e = []
rows = sorted(d["slot"] for d in m["deep_rows"])
want = sorted(r["slot"] for r in p["rows"])
if rows != want: e.append("DEPTH rows %s != plan rows %s" % (rows, want))
if m["complete"]: e.append("a run with capped rows reads complete")
if m["prog"] >= 100: e.append("prog=%s" % m["prog"])
if m["banner"] == "DONE": e.append("banner DONE")
st = {d["slot"]: d["state"] for d in m["deep_rows"]}
if st.get("src-C2") != "capped" or st.get("src-C5") != "capped": e.append("capped states %s" % st)
if m["phases"].get("4.5 · deep-hunt") == "done": e.append("4.5 done with capped rows")
if e: print("; ".join(e)); sys.exit(1)
PY
        then
            pass "(f) dashboard DEPTH rows == plan rows; the exited capped run is not complete, prog < 100, 4.5 not done"
        else
            fail "(f) runner -> dashboard round trip" "$(cat "$WORK/f.err")"
        fi
    else
        fail "(f) emit-model over the real out dir" "$(head -5 "$WORK/model.err" | tr '\n' ' ')"
    fi
else
    fail "(f) runner -> dashboard round trip" "no capped plan to read (see (c))"
fi

summary_exit
