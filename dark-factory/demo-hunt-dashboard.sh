#!/usr/bin/env bash
# demo-hunt-dashboard.sh — OFFLINE, DETERMINISTIC proof of the #1913 M1 hunt-dashboard port. No agentis, no
# LLM, no forge, no network, no server: every assertion drives `hunt-dashboard.py --emit-model` (the JSON
# assertion surface) and `--render` (an HTML smoke parse) over a checked-in, SCRUBBED zone-hunt-out/ snapshot
# copied into a mktemp $WORK, and pins the load-bearing model. The reference is the contract — these
# assertions are the machine-checkable half of the reference-fidelity checklist.
#
# Assertions (over fixtures/balancer = a COMPLETE run, unless noted):
#   (1) PHASE TRACKS + honest progress — 7 phases all done, prog 100, covered/failed/total = 1/0/1.
#   (2) UNIFIED LEADS — breadth REFUTED(struck) / CONFIRMED / PENDING with the right summary.
#   (3) DEEP-HUNT MATRIX — planned lens rows listed (done/queued): C6 open FINDING, SYS-solvency triaged-FP
#       (struck, via the (file,class) deep-hunt-adjudicated.tsv REFUTED overlay), C10 CLEAN (struck), C8
#       HARNESS_ERROR (amber, NOT struck), C5 queued; severity joined from verified_findings.json onto EVERY
#       row incl. CLEAN/HARNESS_ERROR.
#   (4) ZONE RESULT agrees with the LEADS table (deep finding > survived > refuted > pending).
#   (5) LIVENESS — the four classes via HUNT_DASHBOARD_FAKE_* (finished static-slate; __EXIT__+fake-alive =>
#       running LIVE pulse; no-exit+proc-gone => PROCESS_GONE; fresh HIDDEN-dir heartbeat+fake-alive => LIVE,
#       not QUIET — the .gen-briefs traversal fix).
#   (6) HONEST COMPLETION — over fixtures/balancer-incomplete: STOPPED_INCOMPLETE, failed zone excluded from
#       covered, prog < 100, a HARNESS_ERROR deep row rendered as a gap.
#   (7) HTML smoke — --render emits a parseable page carrying the unified LEADS header and the descriptor label.
#
# Usage:  dark-factory/demo-hunt-dashboard.sh
# Requires: python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression.
# POSIX sh / dash-safe: no pipefail, no arrays, no $'...', no process substitution, literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DASH="$HERE/hunt-dashboard/hunt-dashboard.py"
FIX="$HERE/hunt-dashboard/fixtures"

FAILS=0
note() { echo "demo-hunt-dashboard.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -f "$DASH" ] || { note "dashboard not found: $DASH" >&2; exit 3; }
[ -d "$FIX/balancer" ] || { note "fixture not found: $FIX/balancer" >&2; exit 3; }
[ -d "$FIX/balancer-incomplete" ] || { note "fixture not found: $FIX/balancer-incomplete" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-hunt-dashboard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# stage_as <src-fixture> <dst-name> — copy a fixture into $WORK/<dst-name> and echo its descriptor path.
stage_as() {
  st_src="$1"; st_dst="$WORK/$2"
  rm -rf "$st_dst"; mkdir -p "$st_dst"
  cp -R "$FIX/$st_src/." "$st_dst/"
  echo "$st_dst/descriptor.json"
}
# stage <fixture> — copy a fixture into $WORK/<fixture> and echo its descriptor path.
stage() { stage_as "$1" "$1"; }

# emit_model <descriptor> [env assignments...] -> writes JSON to $WORK/model.json, returns the exit code.
emit_model() {
  em_desc="$1"; shift
  env "$@" python3 "$DASH" --descriptor "$em_desc" --emit-model > "$WORK/model.json" 2>"$WORK/model.err"
}

# assert_model <desc> <python-assertion-body-file-marker...> — run a python block over $WORK/model.json.
# Convention: the caller pipes the assertion body via a heredoc to python3 with the model path as argv[1].

MAIN_DESC="$(stage balancer)"

# ----------------------------------------------------------------------------------------------------------
# (1)-(4) the COMPLETE run: phases, unified leads, deep matrix, zone-result agreement.
# ----------------------------------------------------------------------------------------------------------
note "1) complete run: phase tracks + unified LEADS + deep-hunt matrix + zone agreement ..."
if emit_model "$MAIN_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
e = []
# (1) honest progress on a genuinely complete run
if not (m["complete"] and m["prog"] == 100.0): e.append("not complete@100: %s/%s" % (m["complete"], m["prog"]))
if (m["covered"], m["failed"], m["total"]) != (1, 0, 1): e.append("covered/failed/total=%s" % ((m["covered"], m["failed"], m["total"]),))
if any(v != "done" for v in m["phases"].values()): e.append("a phase is not done: %s" % m["phases"])
# (2) unified LEADS — breadth verdicts + struck + summary
byloc = {l["loc"]: l for l in m["leads"]}
ref = byloc.get("pkg/vault/contracts/BatchRouterHooks.sol:_erc4626BufferWrapOrUnwrapExactOut")
con = byloc.get("pkg/vault/contracts/Vault.sol:settle")
pen = byloc.get("pkg/vault/contracts/BufferRouter.sol:addLiquidityToBuffer")
if not (ref and ref["verdict"] == "REFUTED" and ref["struck"]): e.append("breadth REFUTED/struck wrong: %s" % ref)
if ref["sev"] != "High": e.append("breadth sev prefix leak: %r (want bare 'High')" % ref["sev"])
if ref["cls"] != "C6": e.append("breadth cls prefix leak: %r (want bare 'C6')" % ref["cls"])
if not (con and con["verdict"] == "CONFIRMED" and not con["struck"]): e.append("breadth CONFIRMED wrong: %s" % con)
if not (pen and pen["verdict"] == "PENDING" and not pen["struck"]): e.append("breadth PENDING wrong: %s" % pen)
if m["leads_summary"] != {"total": 3, "survived": 1, "refuted": 1, "pending": 1}: e.append("leads_summary=%s" % m["leads_summary"])
# (3) deep-hunt matrix — one row per planned/completed slot, correct state + struck + severity join
ds = {d["slot"]: d for d in m["deep_rows"]}
def chk(slot, state, struck, sev):
    d = ds.get(slot)
    if not d: return "missing deep slot %s" % slot
    if d["state"] != state: return "%s state=%s want %s" % (slot, d["state"], state)
    if d["struck"] != struck: return "%s struck=%s want %s" % (slot, d["struck"], struck)
    if sev is not None and d["severity"] != sev: return "%s sev=%r want %r" % (slot, d["severity"], sev)
    return None
for slot, state, struck, sev in [
    ("pkg_vault_contracts-C6", "finding", False, "High"),
    ("pkg_vault_contracts-SYS-solvency", "triaged_fp", True, "High"),
    ("pkg_vault_contracts-C10", "clean", True, "High"),           # CLEAN struck, Sev still shown (intrinsic)
    ("pkg_vault_contracts-C8", "harness_error", False, "High"),   # GAP, NOT struck, amber; Sev shown
    ("pkg_vault_contracts-C5", "queued", False, "High"),           # planned lens, not run — intrinsic
                                                                    # High from the zone's value_custody:true
]:
    r = chk(slot, state, struck, sev)
    if r: e.append(r)
# a planned row carrying an intrinsic severity must still read as "queued" (not "finding"/"running") in the
# machine-readable state field — the JSON model keeps a planned row distinct from a real verdict (#1953).
c5 = ds.get("pkg_vault_contracts-C5")
if not (c5 and c5["state"] == "queued"): e.append("C5 state should stay queued (distinct from finding/running): %s" % c5)
if m["deep_summary"] != {"planned": 5, "completed": 4, "findings": 1}: e.append("deep_summary=%s" % m["deep_summary"])
# (4) zone RESULT agrees with the panels (deep finding wins the precedence)
z = m["zones"][0]
if not (z["custody"] and z["result"].startswith("◆ 1 deep finding")): e.append("zone result disagrees: %s" % z)
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "phases all done@100, unified breadth+depth verdicts, deep matrix (finding/triaged-FP/clean/gap/queued), zone agreement"
  else bad "the complete-run model assertion failed"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "emit-model failed on the complete fixture"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (5) LIVENESS — the four classes, driven by HUNT_DASHBOARD_FAKE_* (no /proc dependence).
# ----------------------------------------------------------------------------------------------------------
note "2) liveness classification (fake-proc overrides) ..."
LIVE_DESC="$(stage_as balancer balancer-live)"
# strip the __EXIT__ marker (this staged copy is a RUNNING hunt) and make the HIDDEN-dir heartbeat the
# freshest artifact LAST, so a fresh mtime under .gen-briefs/ is what the scan must see (the false-"stalled" fix).
LIVE_DIR="$(dirname "$LIVE_DESC")"
grep -v '__EXIT__' "$LIVE_DIR/hunt.log" > "$LIVE_DIR/hunt.log.tmp" && mv "$LIVE_DIR/hunt.log.tmp" "$LIVE_DIR/hunt.log"
HB="$LIVE_DIR/zone-hunt-out/briefs/.gen-briefs/run/brief_pkg_vault_contracts.log"
touch "$HB"

# (5a) exited + no live process -> FINISHED, static slate (is_live false)
emit_model "$MAIN_DESC" HUNT_DASHBOARD_FAKE_PROC_ALIVE=0
if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
assert m["exited"] and m["liveness"]["class"] == "FINISHED" and m["liveness"]["is_live"] is False, m["liveness"]
PY
then ok "5a: exited + no live process -> FINISHED static slate (pulse off)"; else bad "5a: finished-slate classification wrong"; fi

# (5b) __EXIT__ present but a live process is detected -> NOT finished; running + LIVE pulse
emit_model "$MAIN_DESC" HUNT_DASHBOARD_FAKE_PROC_ALIVE=1
if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
assert m["exited"] is False and m["liveness"]["is_live"] is True and m["liveness"]["class"] == "LIVE", m["liveness"]
PY
then ok "5b: __EXIT__ + live process -> running + LIVE pulse (deep-hunt-resume case, no calm 'finished')"; else bad "5b: exit+live-process classification wrong"; fi

# (5c) no __EXIT__ + process gone -> PROCESS_GONE (crash, not finish)
emit_model "$LIVE_DESC" HUNT_DASHBOARD_FAKE_PROC_ALIVE=0
if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
assert m["exited"] is False and m["liveness"]["class"] == "PROCESS_GONE" and m["liveness"]["is_live"] is False, m["liveness"]
PY
then ok "5c: no __EXIT__ + process gone -> PROCESS_GONE (crashed, not finished)"; else bad "5c: process-gone classification wrong"; fi

# (5d) fresh HIDDEN-dir heartbeat + live process -> LIVE, and the freshest artifact is the .gen-briefs sublog
emit_model "$LIVE_DESC" HUNT_DASHBOARD_FAKE_PROC_ALIVE=1
if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
assert m["liveness"]["class"] == "LIVE" and m["liveness"]["is_live"] is True, m["liveness"]
assert m["liveness"]["freshest"] and ".gen-briefs" in m["liveness"]["freshest"], "freshest not the hidden-dir heartbeat: %s" % m["liveness"]["freshest"]
PY
then ok "5d: fresh HIDDEN .gen-briefs heartbeat + live -> LIVE (os.walk traversal, not false QUIET)"; else bad "5d: hidden-dir freshness/LIVE classification wrong"; fi

# ----------------------------------------------------------------------------------------------------------
# (6) HONEST COMPLETION — the exited-but-incomplete run must be visibly distinct from full coverage.
# ----------------------------------------------------------------------------------------------------------
note "3) honest completion (exited != fully hunted) ..."
INC_DESC="$(stage balancer-incomplete)"
if emit_model "$INC_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
e = []
if m["complete"]: e.append("an errored run must never be complete")
if m["banner"] != "STOPPED_INCOMPLETE": e.append("banner=%s" % m["banner"])
if (m["covered"], m["failed"], m["total"]) != (1, 1, 2): e.append("covered/failed/total=%s (failed must be excluded from covered)" % ((m["covered"], m["failed"], m["total"]),))
if not (0 < m["prog"] < 100): e.append("prog=%s (must be partial, not 100)" % m["prog"])
gap = [z for z in m["zones"] if z["status"] == "failed"]
if not (gap and gap[0]["result"].startswith("✗")): e.append("failed zone result not a gap: %s" % gap)
he = [d for d in m["deep_rows"] if d["state"] == "harness_error"]
if not (he and he[0]["struck"] is False): e.append("HARNESS_ERROR deep row must render as a gap, not struck: %s" % he)
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "STOPPED_INCOMPLETE, failed zone excluded from covered, prog partial, HARNESS_ERROR = gap (not struck)"
  else bad "the honest-completion model assertion failed"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "emit-model failed on the incomplete fixture"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (7) HTML SMOKE — --render emits a parseable page carrying the unified LEADS header + the descriptor label.
# ----------------------------------------------------------------------------------------------------------
note "4) HTML render smoke ..."
if python3 "$DASH" --descriptor "$MAIN_DESC" --render > "$WORK/page.html" 2>"$WORK/render.err"; then
  if grep -q "Vault V3 (pkg/vault)" "$WORK/page.html" \
     && grep -q "<td>Type</td><td>Sev</td><td>Class</td><td>Location</td><td>Refute gate</td>" "$WORK/page.html" \
     && grep -q 'meta http-equiv="refresh"' "$WORK/page.html" \
     && grep -q 'rel="noopener noreferrer"' "$WORK/page.html"; then
    ok "rendered page carries the label, the unified 6-column LEADS header, self-refresh + noopener links"
  else
    bad "rendered HTML is missing a load-bearing element (label / unified header / refresh / noopener)"
  fi
  # (#1953) the queued C5 row's Sev cell must show the intrinsic-severity fallback (High, from the zone's
  # value_custody:true), but visibly lighter than a confirmed FINDING's bold Sev cell — never font-weight:600.
  if python3 - "$WORK/page.html" <<'PY'
import sys
html = open(sys.argv[1]).read()
marker = "planned lens row — not yet run"
i = html.find(marker)
if i < 0:
    print("marker not found: %r" % marker); sys.exit(1)
row_start = html.rfind("<tr", 0, i)
row_end = html.find("</tr>", i)
if row_start < 0 or row_end < 0:
    print("could not locate the enclosing <tr> for the queued row"); sys.exit(1)
row = html[row_start:row_end]
sev_end = row.find(">High<")
if sev_end < 0:
    print("queued row missing intrinsic High severity: %r" % row); sys.exit(1)
sev_span_start = row.rfind("<span", 0, sev_end)  # the Sev cell's own span, not the DEPTH type-badge span
sev_span = row[sev_span_start:sev_end]
if "font-weight:600" in sev_span:
    print("queued row's Sev cell must not be bold like a confirmed FINDING: %r" % sev_span); sys.exit(1)
PY
  then ok "queued row shows intrinsic High severity, styled lighter (no font-weight:600) than a real FINDING"
  else bad "queued-row intrinsic-severity styling regressed"
  fi
  # (#1958) breadth LEADS row must render bare severity, not the raw 'severity=High' parse artifact.
  if python3 - "$WORK/page.html" <<'PY'
import sys
html = open(sys.argv[1]).read()
if "severity=" in html:
    print("page-wide severity= prefix leak found"); sys.exit(1)
marker = "pkg/vault/contracts/BatchRouterHooks.sol:_erc4626BufferWrapOrUnwrapExactOut"
i = html.find(marker)
if i < 0:
    print("marker not found: %r" % marker); sys.exit(1)
row_start = html.rfind("<tr", 0, i)
row_end = html.find("</tr>", i)
if row_start < 0 or row_end < 0:
    print("could not locate the enclosing <tr> for the breadth REFUTED row"); sys.exit(1)
row = html[row_start:row_end]
if "severity=" in row:
    print("breadth row still carries a raw severity= token: %r" % row); sys.exit(1)
if ">High<" not in row:
    print("breadth row missing bare High severity: %r" % row); sys.exit(1)
if "color:#ff5c5c" not in row:
    print("breadth row missing the High SEVCOL colour: %r" % row); sys.exit(1)
PY
  then ok "breadth REFUTED row renders bare High severity with the correct SEVCOL colour, no severity= leak"
  else bad "breadth-sev prefix leak in the rendered LEADS row"
  fi
else
  bad "--render failed"; sed 's/^/      /' "$WORK/render.err" | head -5 >&2
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the #1913 M1 hunt-dashboard reference-fidelity model holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
