#!/usr/bin/env bash
# demo-hunt-dashboard-completeness.sh — OFFLINE, DETERMINISTIC proof of the #2298 hunt-dashboard COMPLETENESS
# invariant: nothing reads 100 % or DONE — not the header, not any phase, not a zone, not the overview card — while
# ANY row is unchecked. No agentis, no LLM, no forge, no network, no server: every assertion drives
# `hunt-dashboard.py --emit-model` (the JSON model), `--render` (the page) and the registry overview over the
# checked-in, scrubbed fixtures/balancer-complete snapshot copied into a mktemp $WORK.
#
#   (0) POSITIVE CONTROL — balancer-complete (every row checked: plan rows all CLEAN/FINDING, the surviving C6
#       finding carries an operator CONFIRMED verdict, every lead has a gate verdict, every M5 finding is staged)
#       IS complete: prog 100, banner DONE, FINISHED, every phase done, the page says "✅ DONE" at 100%, the overview
#       card reads 100% FINISHED. Proves the invariant below is not vacuous.
#   (1) SINGLE-ROW MUTATIONS — each mutation of that snapshot introduces exactly ONE unchecked row; for every one,
#       with HUNT_DASHBOARD_FAKE_PROC_ALIVE in {0,1}:
#         model:    complete false, banner not DONE, prog < 100, liveness not FINISHED, the mutated phase not done,
#                   and no phase with a non-empty phase_rows[p].unchecked reads done;
#         render:   barlabel < 100%, no "✅ DONE", no DONE sub-line, no "finished — verdict in chat", no ✅ on the
#                   data-phase row of an unchecked phase, no ✅ on a data-zone row that has open rows;
#         overview: the registry card with that one descriptor reads < 100% and is not FINISHED.
#       Mutations: a capped plan row; a selected row with no dir; a fresh (running) cell dir; HARNESS_ERROR,
#       TRANSIENT_ERROR and LOW_COVERAGE rows; an unplanned HARNESS_ERROR dir; plan.json deleted (legacy, M1-M4
#       complete); a plan with status skipped; a FINDING with neither an operator verdict nor a gate report; a
#       FINDING that SURVIVED the 4.6 gate (REAL) but has no operator verdict yet (stays unchecked until
#       CONFIRMED / DUPLICATE / FP is recorded); a pending breadth lead; a failed zone; a hunted_degraded zone; a
#       failed deliver row; a missing .verified-findings.tsv.
#   (2) CAPPED RENDER — the capped row renders "⏸️ capped" with the --deep-hunt-max-lenses re-run hint.
#   (3) ROUNDING GUARD — 300 DEPTH rows, 299 CLEAN + 1 capped, renders "99%" (never a rounded-up "100%").
#
# Usage:  dark-factory/demo-hunt-dashboard-completeness.sh
# Requires: python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', no process substitution, literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DASH="$HERE/hunt-dashboard/hunt-dashboard.py"
FIX="$HERE/hunt-dashboard/fixtures"

FAILS=0
note() { echo "demo-hunt-dashboard-completeness.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -f "$DASH" ] || { note "dashboard not found: $DASH" >&2; exit 3; }
[ -d "$FIX/balancer-complete" ] || { note "fixture not found: $FIX/balancer-complete" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-hunt-dashboard-completeness.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# stage <name> — copy balancer-complete into $WORK/<name> and echo the hunt dir.
stage() {
  st_dst="$WORK/$1"
  rm -rf "$st_dst"; mkdir -p "$st_dst"
  cp -R "$FIX/balancer-complete/." "$st_dst/"
  echo "$st_dst"
}

# The mutator: one python file, one named mutation per call, each adding exactly ONE unchecked row.
cat > "$WORK/mutate.py" <<'PY'
import json, os, sys, time
name, d = sys.argv[1], sys.argv[2]
out = os.path.join(d, "zone-hunt-out")
dh = os.path.join(out, "deep-hunt")
planp = os.path.join(dh, "plan.json")
def plan(): return json.load(open(planp))
def save_plan(p): json.dump(p, open(planp, "w"), indent=2)
def row(cls, state="selected"):
    r = {"slot": "pkg_vault_contracts-" + cls, "zone": "pkg_vault_contracts", "class": cls,
         "target": "pkg/vault/contracts/Vault.sol" if state == "selected" else "", "state": state, "custody": True}
    if state == "capped": r["cap"] = "max-lenses"
    return r
def add_row(cls, state="selected"):
    p = plan(); p["rows"].append(row(cls, state)); save_plan(p)
def report(cls, verdict):
    cd = os.path.join(dh, "pkg_vault_contracts-" + cls); os.makedirs(cd, exist_ok=True)
    open(os.path.join(cd, "invariant-report.md"), "w").write(
        "| Target | Class | Handler | Verdict |\n|---|---|---|---|\n"
        "| pkg/vault/contracts/Vault.sol | %s | generated(LLM) | %s |\n" % (cls, verdict))
def drop_c6_verdict():
    p = os.path.join(d, "deep-hunt-adjudicated.tsv")
    keep = [l for l in open(p).read().splitlines(True) if not l.startswith("pkg/vault/contracts/Vault.sol\tC6\t")]
    open(p, "w").write("".join(keep))
def coverage_status(st):
    p = os.path.join(out, "coverage", "zone-coverage.json")
    c = json.load(open(p)); c["zones"][0]["status"] = st; json.dump(c, open(p, "w"), indent=2)
if name == "capped":
    add_row("C5", "capped")
elif name == "selected_no_dir":
    add_row("C2")
elif name == "fresh_cell":
    add_row("C2")
    rd = os.path.join(dh, "pkg_vault_contracts-C2", "run"); os.makedirs(rd)
    open(os.path.join(rd, "llm.log"), "w").write("still waiting ... (4.0s)\n")
elif name in ("harness_error", "transient_error", "low_coverage"):
    add_row("C8"); report("C8", {"harness_error": "HARNESS_ERROR", "transient_error": "TRANSIENT_ERROR",
                                 "low_coverage": "LOW_COVERAGE"}[name])
elif name == "unplanned_dir":
    report("C8", "HARNESS_ERROR")
elif name == "legacy_no_plan":
    os.remove(planp)
elif name == "plan_skipped":
    p = plan(); p["status"] = "skipped"; p["reason"] = "skipped-no-foundry (no foundry.toml)"; p["rows"] = []
    save_plan(p)
elif name == "finding_untriaged":
    drop_c6_verdict()
    os.remove(os.path.join(dh, "pkg_vault_contracts-C6", "refute-gate", "refute-out", "refute-report.md"))
elif name == "survived_unadjudicated":
    drop_c6_verdict()   # the 4.6 gate report (REAL = survived) stays: a survivor is NOT an operator verdict
elif name == "pending_lead":
    os.remove(os.path.join(out, "verify", "gates", "3_pkg_vault_contracts_BufferRouter_sol_addLiquidityToBuffer",
                           "verdict.txt"))
elif name == "failed_zone":
    coverage_status("failed")
elif name == "degraded_zone":
    coverage_status("hunted_degraded")
elif name == "deliver_failed":
    p = os.path.join(out, "audit-pass", "deliver-status.tsv")
    ls = open(p).read().splitlines()
    ls[0] = ls[0].split("\t")[0] + "\tfailed"
    open(p, "w").write("\n".join(ls) + "\n")
elif name == "no_verified_tsv":
    os.remove(os.path.join(out, ".verified-findings.tsv"))
else:
    sys.exit("unknown mutation: " + name)
PY

# The model invariant: ONE python check over an emitted model. argv: model.json, mutated phase ("" for the positive
# control), expect ("complete" | "incomplete"), alive (0|1).
cat > "$WORK/check_model.py" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); phase = sys.argv[2]; expect = sys.argv[3]; alive = sys.argv[4]
e = []
ph = m["phases"]; pr = m["phase_rows"]
if expect == "complete":
    if not (m["complete"] and m["prog"] == 100.0 and m["banner"] == "DONE"):
        e.append("positive control not complete@100/DONE: %s/%s/%s" % (m["complete"], m["prog"], m["banner"]))
    if m["liveness"]["class"] != "FINISHED": e.append("positive control liveness=%s" % m["liveness"]["class"])
    if any(v != "done" for v in ph.values()): e.append("positive control phase not done: %s" % ph)
    if any(v["unchecked"] for v in pr.values()): e.append("positive control has unchecked rows: %s" % pr)
else:
    if m["complete"]: e.append("complete with an unchecked row")
    if m["banner"] == "DONE": e.append("banner DONE with an unchecked row")
    if not (m["prog"] < 100): e.append("prog=%s with an unchecked row" % m["prog"])
    if m["liveness"]["class"] == "FINISHED": e.append("liveness FINISHED with an unchecked row")
    if ph.get(phase) == "done": e.append("the mutated phase %r reads done: %s" % (phase, pr.get(phase)))
    if not pr.get(phase, {}).get("unchecked"): e.append("the mutated phase %r has no unchecked row: %s" % (phase, pr.get(phase)))
    n_open = sum(len(v["unchecked"]) for k, v in pr.items() if ph.get(k) != "skip")
    if alive == "0" and n_open != 1: e.append("the mutation must add exactly ONE unchecked row, got %d: %s"
                                              % (n_open, {k: v["unchecked"] for k, v in pr.items() if v["unchecked"]}))
    for k, v in pr.items():   # the generic invariant: no phase with an unchecked row is done
        if v["unchecked"] and ph.get(k) == "done": e.append("phase %r is done with unchecked rows %s" % (k, v["unchecked"]))
    for z in m["zones"]:
        if z["open"] and z["checked"]: e.append("zone %s checked with %d open rows" % (z["id"], z["open"]))
if e: print("; ".join(e)); sys.exit(1)
PY

# The render invariant over one page + its model. argv: page.html, model.json, expect.
cat > "$WORK/check_page.py" <<'PY'
import json, re, sys
h = open(sys.argv[1]).read(); m = json.load(open(sys.argv[2])); expect = sys.argv[3]
e = []
bl = re.search(r'class="barlabel">(\d+)%<', h)
if not bl: e.append("no barlabel")
pct = int(bl.group(1)) if bl else -1
phase_rows = dict(re.findall(r'<tr data-phase="([^"]*)" data-state="[^"]*"><td>([^<]*)</td>', h))
zone_rows = re.findall(r'<tr data-zone="([^"]*)" data-open="(\d+)" data-state="[^"]*"><td[^>]*>([^<]*)</td>', h)
if len(phase_rows) != 7: e.append("expected 7 data-phase rows, got %d" % len(phase_rows))
if expect == "complete":
    if pct != 100: e.append("positive control barlabel %s%%" % pct)
    if "✅ DONE" not in h or "finished — verdict in chat" not in h: e.append("positive control lacks DONE/finished")
    if any(v != "✅" for v in phase_rows.values()): e.append("positive control phase icons %s" % phase_rows)
else:
    if not (0 <= pct < 100): e.append("barlabel %s%% with an unchecked row" % pct)
    if "✅ DONE" in h: e.append("'✅ DONE' rendered with an unchecked row")
    if "· DONE</div>" in h: e.append("DONE sub-line rendered with an unchecked row")
    if "finished — verdict in chat" in h: e.append("'finished — verdict in chat' rendered with an unchecked row")
    for k, v in m["phase_rows"].items():
        if v["unchecked"] and phase_rows.get(k) == "✅": e.append("phase row %r shows ✅ with unchecked rows" % k)
for zid, n_open, icon in zone_rows:
    if int(n_open) and icon.strip() == "✅": e.append("zone row %s shows ✅ with %s open rows" % (zid, n_open))
if e: print("; ".join(e)); sys.exit(1)
PY

# The overview invariant: one registry descriptor -> its card. argv: overview.json, overview.html, expect.
cat > "$WORK/check_card.py" <<'PY'
import json, re, sys
o = json.load(open(sys.argv[1])); h = open(sys.argv[2]).read(); expect = sys.argv[3]
e = []
if o["count"] != 1: e.append("overview count=%s" % o["count"])
c = o["hunts"][0] if o["hunts"] else {}
lbl = re.search(r'class="hcbl">(\d+)%<', h)
pct = int(lbl.group(1)) if lbl else -1
if expect == "complete":
    if not (c.get("prog") == 100.0 and c.get("liveness_class") == "FINISHED" and pct == 100):
        e.append("positive control card not 100%% FINISHED: %s / %s%%" % (c, pct))
else:
    if not (c.get("prog", 100) < 100): e.append("card prog=%s with an unchecked row" % c.get("prog"))
    if c.get("liveness_class") == "FINISHED": e.append("card FINISHED with an unchecked row")
    if not (0 <= pct < 100): e.append("card label %s%% with an unchecked row" % pct)
if e: print("; ".join(e)); sys.exit(1)
PY

# check_case <name> <hunt-dir> <mutated-phase> <expect> <alive> — model + render + overview for one staged hunt.
check_case() {
  cc_name="$1"; cc_dir="$2"; cc_phase="$3"; cc_expect="$4"; cc_alive="$5"
  cc_fail=""
  cc_env="HUNT_DASHBOARD_FAKE_PROC_ALIVE=$cc_alive"
  if env "$cc_env" HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0 python3 "$DASH" --descriptor "$cc_dir/descriptor.json" \
       --emit-model > "$WORK/model.json" 2>"$WORK/err.txt"; then
    python3 "$WORK/check_model.py" "$WORK/model.json" "$cc_phase" "$cc_expect" "$cc_alive" > "$WORK/out.txt" 2>&1 \
      || cc_fail="$cc_fail [model: $(cat "$WORK/out.txt")]"
  else
    cc_fail="$cc_fail [emit-model failed: $(head -3 "$WORK/err.txt" | tr '\n' ' ')]"
  fi
  if env "$cc_env" HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0 python3 "$DASH" --descriptor "$cc_dir/descriptor.json" \
       --render > "$WORK/page.html" 2>"$WORK/err.txt"; then
    python3 "$WORK/check_page.py" "$WORK/page.html" "$WORK/model.json" "$cc_expect" > "$WORK/out.txt" 2>&1 \
      || cc_fail="$cc_fail [render: $(cat "$WORK/out.txt")]"
  else
    cc_fail="$cc_fail [render failed: $(head -3 "$WORK/err.txt" | tr '\n' ' ')]"
  fi
  cc_reg="$WORK/reg-$cc_name-$cc_alive"
  rm -rf "$cc_reg"; mkdir -p "$cc_reg"
  printf '{"id": "%s", "label": "%s", "root": "%s", "out": "%s/zone-hunt-out", "log": "%s/hunt.log"}\n' \
    "$cc_name" "$cc_name" "$cc_dir" "$cc_dir" "$cc_dir" > "$cc_reg/$cc_name.json"
  if env "$cc_env" HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0 python3 "$DASH" --registry-dir "$cc_reg" --emit-model \
       > "$WORK/overview.json" 2>"$WORK/err.txt" \
     && env "$cc_env" HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0 python3 "$DASH" --registry-dir "$cc_reg" --render \
       > "$WORK/overview.html" 2>>"$WORK/err.txt"; then
    python3 "$WORK/check_card.py" "$WORK/overview.json" "$WORK/overview.html" "$cc_expect" > "$WORK/out.txt" 2>&1 \
      || cc_fail="$cc_fail [overview: $(cat "$WORK/out.txt")]"
  else
    cc_fail="$cc_fail [overview failed: $(head -3 "$WORK/err.txt" | tr '\n' ' ')]"
  fi
  if [ -z "$cc_fail" ]; then return 0; fi
  echo "$cc_fail"
  return 1
}

# ----------------------------------------------------------------------------------------------------------
# (0) POSITIVE CONTROL
# ----------------------------------------------------------------------------------------------------------
note "0) positive control: the all-checked balancer-complete run IS complete (the invariant is not vacuous) ..."
PC_DIR="$(stage positive)"
if PC_OUT="$(check_case positive "$PC_DIR" "" complete 0)"; then
  ok "balancer-complete: complete, prog 100, DONE, FINISHED, every phase ✅, the overview card 100% FINISHED"
else
  bad "positive control:$PC_OUT"
fi

# ----------------------------------------------------------------------------------------------------------
# (1) SINGLE-ROW MUTATIONS x HUNT_DASHBOARD_FAKE_PROC_ALIVE in {0,1}
# ----------------------------------------------------------------------------------------------------------
note "1) single-row mutations: one unchecked row anywhere => never 100 % / DONE / FINISHED / a ✅ on its phase ..."
for spec in \
  "capped|4.5 · deep-hunt" \
  "selected_no_dir|4.5 · deep-hunt" \
  "fresh_cell|4.5 · deep-hunt" \
  "harness_error|4.5 · deep-hunt" \
  "transient_error|4.5 · deep-hunt" \
  "low_coverage|4.5 · deep-hunt" \
  "unplanned_dir|4.5 · deep-hunt" \
  "legacy_no_plan|4.5 · deep-hunt" \
  "plan_skipped|4.5 · deep-hunt" \
  "finding_untriaged|4.6 · refute deep-hunt" \
  "survived_unadjudicated|4.6 · refute deep-hunt" \
  "pending_lead|M4 · refute gate" \
  "failed_zone|M3 · discovery" \
  "degraded_zone|M3 · discovery" \
  "deliver_failed|deliver · stage" \
  "no_verified_tsv|deliver · stage"; do
  mname="${spec%%|*}"; mphase="${spec#*|}"
  for alive in 0 1; do
    mdir="$(stage "m-$mname-$alive")"
    if ! python3 "$WORK/mutate.py" "$mname" "$mdir" > "$WORK/mut.txt" 2>&1; then
      bad "$mname (alive=$alive): the mutation itself failed: $(head -3 "$WORK/mut.txt" | tr '\n' ' ')"
      continue
    fi
    if MOUT="$(check_case "$mname" "$mdir" "$mphase" incomplete "$alive")"; then
      ok "$mname (alive=$alive): one unchecked $mphase row => not complete, < 100%, no DONE / FINISHED / ✅ on it"
    else
      bad "$mname (alive=$alive):$MOUT"
    fi
  done
done

# ----------------------------------------------------------------------------------------------------------
# (2) CAPPED RENDER — the issue's plan-file fixture AC: plan + a capped row + an exited runner.
# ----------------------------------------------------------------------------------------------------------
note "2) a capped row renders as ⏸️ capped with the re-run hint ..."
CAP_DIR="$(stage capped-render)"
python3 "$WORK/mutate.py" capped "$CAP_DIR"
if env HUNT_DASHBOARD_FAKE_PROC_ALIVE=0 HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0 python3 "$DASH" \
     --descriptor "$CAP_DIR/descriptor.json" --render > "$WORK/cap.html" 2>"$WORK/err.txt" \
   && grep -q '⏸️ capped' "$WORK/cap.html" \
   && grep -q 'lens cut by --deep-hunt-max-lenses; re-run with a higher cap + --deep-hunt-resume' "$WORK/cap.html" \
   && grep -q 'data-phase="4.5 · deep-hunt" data-state="gap"' "$WORK/cap.html"; then
  ok "the capped C5 row renders '⏸️ capped' + the re-run hint, and the 4.5 phase row is a gap (not ✅)"
else
  bad "capped render: missing '⏸️ capped' / the re-run hint / a non-done 4.5 phase row"
fi

# ----------------------------------------------------------------------------------------------------------
# (3) ROUNDING GUARD — 299 CLEAN + 1 capped must print 99%, never a rounded 100%.
# ----------------------------------------------------------------------------------------------------------
note "3) rounding guard: 299 checked + 1 capped DEPTH row renders 99%, not 100% ..."
RND_DIR="$(stage rounding)"
python3 - "$RND_DIR" <<'PY'
import json, os, shutil, sys
out = os.path.join(sys.argv[1], "zone-hunt-out"); dh = os.path.join(out, "deep-hunt")
p = json.load(open(os.path.join(dh, "plan.json")))
for i in range(299 - len(p["rows"])):
    slot = "pkg_vault_contracts-C%d" % (100 + i)
    os.makedirs(os.path.join(dh, slot))
    open(os.path.join(dh, slot, "invariant-report.md"), "w").write(
        "| Target | Class | Handler | Verdict |\n|---|---|---|---|\n"
        "| pkg/vault/contracts/Vault.sol | C%d | generated(LLM) | CLEAN |\n" % (100 + i))
    p["rows"].append({"slot": slot, "zone": "pkg_vault_contracts", "class": "C%d" % (100 + i),
                      "target": "pkg/vault/contracts/Vault.sol", "state": "selected", "custody": True})
p["rows"].append({"slot": "pkg_vault_contracts-C5", "zone": "pkg_vault_contracts", "class": "C5", "target": "",
                  "state": "capped", "cap": "max-lenses", "custody": True})
json.dump(p, open(os.path.join(dh, "plan.json"), "w"), indent=2)
PY
if env HUNT_DASHBOARD_FAKE_PROC_ALIVE=0 HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0 python3 "$DASH" \
     --descriptor "$RND_DIR/descriptor.json" --render > "$WORK/rnd.html" 2>"$WORK/err.txt" \
   && env HUNT_DASHBOARD_FAKE_PROC_ALIVE=0 HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0 python3 "$DASH" \
     --descriptor "$RND_DIR/descriptor.json" --emit-model > "$WORK/rnd.json" 2>>"$WORK/err.txt"; then
  if grep -q 'class="barlabel">99%<' "$WORK/rnd.html" && python3 - "$WORK/rnd.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
pr = m["phase_rows"]["4.5 · deep-hunt"]
assert pr["total"] == 300 and pr["checked"] == 299, pr
assert not m["complete"] and m["prog"] <= 99, (m["complete"], m["prog"])
PY
  then ok "299/300 checked DEPTH rows: barlabel 99% (clamped + floored, never a rounded-up 100%)"
  else bad "rounding guard: barlabel $(grep -o 'class="barlabel">[0-9]*%' "$WORK/rnd.html") / model wrong"
  fi
else
  bad "rounding guard: dashboard failed: $(head -3 "$WORK/err.txt" | tr '\n' ' ')"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — no 100 % / DONE / FINISHED / phase ✅ while any row is unchecked (#2298)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
