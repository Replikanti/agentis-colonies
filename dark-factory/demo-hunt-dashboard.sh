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
if emit_model "$MAIN_DESC" HUNT_DASHBOARD_FAKE_PROC_ALIVE=0 HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0; then
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
emit_model "$MAIN_DESC" HUNT_DASHBOARD_FAKE_PROC_ALIVE=0 HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0
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
emit_model "$LIVE_DESC" HUNT_DASHBOARD_FAKE_PROC_ALIVE=0 HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0
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
if emit_model "$INC_DESC" HUNT_DASHBOARD_FAKE_PROC_ALIVE=0 HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0; then
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
  # (#1972) the queued C5 row's Sev cell must show the intrinsic-severity fallback (High, from the zone's
  # value_custody:true) styled UNIFORMLY with a confirmed FINDING's Sev cell (color:{SEVCOL}, font-weight:600,
  # no span-level opacity) — the "this row is not a live result" cue now lives entirely at the row level
  # (the enclosing <tr>'s opacity:.5), not on the Sev span itself.
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
tr_tag_end = row.find(">")
tr_tag = row[:tr_tag_end]
if "opacity:.5" not in tr_tag:
    print("queued row's <tr> must still carry opacity:.5 (row-level dimming cue): %r" % tr_tag); sys.exit(1)
sev_end = row.find(">High<")
if sev_end < 0:
    print("queued row missing intrinsic High severity: %r" % row); sys.exit(1)
sev_span_start = row.rfind("<span", 0, sev_end)  # the Sev cell's own span, not the DEPTH type-badge span
sev_span = row[sev_span_start:sev_end]
if "font-weight:600" not in sev_span:
    print("queued row's Sev cell must be bold like a confirmed FINDING: %r" % sev_span); sys.exit(1)
if "opacity:" in sev_span:
    print("queued row's Sev cell must not carry span-level opacity (row-level only): %r" % sev_span); sys.exit(1)
PY
  then ok "queued row shows intrinsic High severity, styled uniformly (font-weight:600, no span opacity); row-level opacity:.5 preserved"
  else bad "queued-row intrinsic-severity styling regressed"
  fi
  # (#1972) companion: the C8 HARNESS_ERROR row's Sev cell must ALSO read uniformly bold (no span-level
  # opacity); the "this is a coverage gap, not a live result" cue lives at the row level (<tr opacity:.6>).
  if python3 - "$WORK/page.html" <<'PY'
import sys
html = open(sys.argv[1]).read()
marker = "harness error is not a verdict &#x2014; a coverage gap"
i = html.find(marker)
if i < 0:
    marker = "harness error is not a verdict"
    i = html.find(marker)
if i < 0:
    print("marker not found (harness-error detail text)"); sys.exit(1)
row_start = html.rfind("<tr", 0, i)
row_end = html.find("</tr>", i)
if row_start < 0 or row_end < 0:
    print("could not locate the enclosing <tr> for the HARNESS_ERROR row"); sys.exit(1)
row = html[row_start:row_end]
tr_tag_end = row.find(">")
tr_tag = row[:tr_tag_end]
if "opacity:.6" not in tr_tag:
    print("HARNESS_ERROR row's <tr> must still carry opacity:.6 (row-level dimming cue): %r" % tr_tag); sys.exit(1)
sev_end = row.find(">High<")
if sev_end < 0:
    print("HARNESS_ERROR row missing High severity: %r" % row); sys.exit(1)
sev_span_start = row.rfind("<span", 0, sev_end)
sev_span = row[sev_span_start:sev_end]
if "font-weight:600" not in sev_span:
    print("HARNESS_ERROR row's Sev cell must be bold like a confirmed FINDING: %r" % sev_span); sys.exit(1)
if "opacity:" in sev_span:
    print("HARNESS_ERROR row's Sev cell must not carry span-level opacity (row-level only): %r" % sev_span); sys.exit(1)
PY
  then ok "HARNESS_ERROR row shows High severity, styled uniformly (font-weight:600, no span opacity); row-level opacity:.6 preserved"
  else bad "HARNESS_ERROR-row severity styling regressed"
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
# (8) PAY-FLOOR MARKER (#1960) + HIDE (#1966) — a lead whose intrinsic severity ranks BELOW the program's
# pay-floor is unpayable (threaded in as the descriptor's `pay_floor`). Model-level assertions are on the
# machine-readable `unpayable` flags (leads[]/deep_rows[]) and top-level `pay_floor` — emit_model()'s output
# is unchanged by #1966. Render behaviour changed: #1960 originally annotated sub-floor rows in place with a
# `payfloor-x0` "$0" badge; #1966 instead OMITS sub-floor rows from the rendered table entirely and collapses
# them into one "N sub-floor leads hidden" summary line, so `payfloor-x0` is now a dead sentinel (never
# rendered) and the render assertions below check row absence + the summary count instead. Never
# complete/banner/liveness, so these hold regardless of any concurrent live hunt on the host.
# ----------------------------------------------------------------------------------------------------------
note "5) pay-floor marker (sub-floor '\$0' annotation) ..."

# stage_floor <src-fixture> <dst-name> <floor> — stage a fixture, then patch `pay_floor` into its STAGED
# descriptor (this doubles as proof a MANUALLY-written descriptor carries the field); echo the descriptor path.
stage_floor() {
  sf_desc="$(stage_as "$1" "$2")"
  python3 - "$sf_desc" "$3" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["pay_floor"] = sys.argv[2]
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
  echo "$sf_desc"
}

# (8a) floor=high over balancer: High payable, Medium+Low sub-floor; every intrinsic-High DEPTH row payable.
HIGH_DESC="$(stage_floor balancer balancer-payfloor-high high)"
if emit_model "$HIGH_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
e = []
if m["pay_floor"] != "high": e.append("pay_floor=%r want 'high'" % m["pay_floor"])
byloc = {l["loc"]: l for l in m["leads"]}
hi  = byloc.get("pkg/vault/contracts/BatchRouterHooks.sol:_erc4626BufferWrapOrUnwrapExactOut")  # High
med = byloc.get("pkg/vault/contracts/Vault.sol:settle")                                          # Medium
lo  = byloc.get("pkg/vault/contracts/BufferRouter.sol:addLiquidityToBuffer")                     # Low
if not (hi and hi["unpayable"] is False): e.append("High breadth lead must be payable at floor=high: %s" % hi)
if not (med and med["unpayable"] is True): e.append("Medium breadth lead must be sub-floor at floor=high: %s" % med)
if not (lo and lo["unpayable"] is True): e.append("Low breadth lead must be sub-floor at floor=high: %s" % lo)
sub = [d["slot"] for d in m["deep_rows"] if d["unpayable"]]
if sub: e.append("no intrinsic-High DEPTH row may be sub-floor at floor=high: %s" % sub)
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "8a: floor=high — High payable, Medium+Low sub-floor(unpayable), all intrinsic-High DEPTH payable, pay_floor=='high'"
  else bad "8a: floor=high unpayable flags wrong"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "8a: emit-model failed on the floor=high descriptor"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

# (8a-render) #1966: Medium+Low breadth rows are HIDDEN (absent) at floor=high, not badged in place; the High
# row still renders; `payfloor-x0` (the superseded #1960 badge sentinel) appears nowhere on the page; and a
# "N sub-floor leads hidden" summary line is present whose count is derived from the (8a) model JSON, not
# hand-hardcoded — robust to fixture edits.
if python3 "$DASH" --descriptor "$HIGH_DESC" --render > "$WORK/page.html" 2>"$WORK/render.err"; then
  if python3 - "$WORK/page.html" "$WORK/model.json" <<'PY'
import sys, re, json
html = open(sys.argv[1]).read()
m = json.load(open(sys.argv[2]))
def row_for(marker):
    i = html.find(marker)
    if i < 0: return None
    s = html.rfind("<tr", 0, i); en = html.find("</tr>", i)
    return html[s:en] if s >= 0 and en >= 0 else None
e = []
hi = row_for("pkg/vault/contracts/BatchRouterHooks.sol:_erc4626BufferWrapOrUnwrapExactOut")
med = row_for("pkg/vault/contracts/Vault.sol:settle")
lo = row_for("pkg/vault/contracts/BufferRouter.sol:addLiquidityToBuffer")
if hi is None: e.append("High breadth row must still render at floor=high")
if med is not None: e.append("Medium breadth row must be HIDDEN (absent) at floor=high, not badged")
if lo is not None: e.append("Low breadth row must be HIDDEN (absent) at floor=high, not badged")
if "payfloor-x0" in html: e.append("payfloor-x0 badge sentinel must not appear anywhere (superseded by hide+count)")
want = sum(1 for l in m["leads"] if l["unpayable"]) + sum(1 for d in m["deep_rows"] if d["unpayable"])
match = re.search(r"(\d+) sub-floor leads? hidden", html)
if not match: e.append("expected a 'N sub-floor lead(s) hidden' summary line, found none")
elif int(match.group(1)) != want:
    e.append("summary line count %s != model-derived unpayable total %d" % (match.group(1), want))
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "8a-render: Medium+Low breadth rows hidden, High still renders, summary count matches model (#1966)"
  else bad "8a-render: sub-floor hide+count rendering wrong"; sed 's/^/      /' "$WORK/render.err" | head -3 >&2
  fi
else
  bad "8a-render: --render failed on the floor=high descriptor"; sed 's/^/      /' "$WORK/render.err" | head -5 >&2
fi

# (8b) floor=critical over balancer: the DEPTH track marks too (C6 High FINDING sub-floor) and the refuted High
# breadth lead is sub-floor; render proves the $0 badge COEXISTS with the refuted line-through (no collision).
CRIT_DESC="$(stage_floor balancer balancer-payfloor-crit critical)"
if emit_model "$CRIT_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
e = []
if m["pay_floor"] != "critical": e.append("pay_floor=%r want 'critical'" % m["pay_floor"])
c6 = next((d for d in m["deep_rows"] if d["slot"] == "pkg_vault_contracts-C6"), None)
if not (c6 and c6["state"] == "finding" and c6["unpayable"] is True):
    e.append("DEPTH C6 High FINDING must be sub-floor at floor=critical: %s" % c6)
ref = next((l for l in m["leads"] if l["verdict"] == "REFUTED"), None)
if not (ref and ref["struck"] and ref["unpayable"] is True):
    e.append("refuted High breadth lead must be sub-floor AND struck at floor=critical: %s" % ref)
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "8b: floor=critical — DEPTH C6 High FINDING sub-floor AND breadth High REFUTED sub-floor"
  else bad "8b: floor=critical DEPTH/breadth unpayable flags wrong"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "8b: emit-model failed on the floor=critical descriptor"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

# (8b-render) #1966: at floor=critical EVERY row in this fixture is sub-floor (even High), so both the C6
# DEPTH FINDING row and the refuted High breadth row are now HIDDEN (absent), not badged — the old "strike +
# $0 badge coexistence" assertion no longer applies since neither row renders at all. The summary line's
# count is derived from the (8b) model JSON and covers ALL unpayable rows at this floor (breadth + DEPTH),
# not just these two.
if python3 "$DASH" --descriptor "$CRIT_DESC" --render > "$WORK/page.html" 2>"$WORK/render.err"; then
  if python3 - "$WORK/page.html" "$WORK/model.json" <<'PY'
import sys, re, json
html = open(sys.argv[1]).read()
m = json.load(open(sys.argv[2]))
def row_for(marker):
    i = html.find(marker)
    if i < 0: return None
    s = html.rfind("<tr", 0, i); en = html.find("</tr>", i)
    return html[s:en] if s >= 0 and en >= 0 else None
e = []
c6 = row_for("◆ FINDING · pending forge PoC + triage")   # unique to the single C6 DEPTH finding row
ref = row_for("pkg/vault/contracts/BatchRouterHooks.sol:_erc4626BufferWrapOrUnwrapExactOut")
if c6 is not None: e.append("C6 DEPTH finding row must be HIDDEN (absent) at floor=critical, not badged")
if ref is not None: e.append("refuted High breadth row must be HIDDEN (absent) at floor=critical, not badged")
if "payfloor-x0" in html: e.append("payfloor-x0 badge sentinel must not appear anywhere (superseded by hide+count)")
want = sum(1 for l in m["leads"] if l["unpayable"]) + sum(1 for d in m["deep_rows"] if d["unpayable"])
match = re.search(r"(\d+) sub-floor leads? hidden", html)
if not match: e.append("expected a 'N sub-floor lead(s) hidden' summary line, found none")
elif int(match.group(1)) != want:
    e.append("summary line count %s != model-derived unpayable total %d" % (match.group(1), want))
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "8b-render: C6 DEPTH + refuted High breadth rows both hidden at floor=critical, summary count matches model (#1966)"
  else bad "8b-render: sub-floor hide+count rendering wrong at floor=critical"; sed 's/^/      /' "$WORK/render.err" | head -3 >&2
  fi
else
  bad "8b-render: --render failed on the floor=critical descriptor"; sed 's/^/      /' "$WORK/render.err" | head -5 >&2
fi

# (8c) floor=high over balancer-incomplete: C6 is HARNESS_ERROR. #depth-sev: every DEPTH row now resolves a
# severity (intrinsic custody / pay-floor) -> C6 reads 'High' and, being AT the floor, stays PAYABLE.
INCH_DESC="$(stage_floor balancer-incomplete balancer-incomplete-payfloor-high high)"
if emit_model "$INCH_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
e = []
c6 = next((d for d in m["deep_rows"] if d["slot"] == "pkg_vault_contracts-C6"), None)
# #depth-sev: every DEPTH row now resolves a severity (intrinsic custody / pay-floor), so a HARNESS_ERROR row
# reads "High" — and, being AT the high floor, it stays PAYABLE (a coverage gap on a High surface is not $0).
if not (c6 and c6["state"] == "harness_error" and c6["severity"] == "High" and c6["unpayable"] is False):
    e.append("HARNESS_ERROR row must show a resolved severity and stay payable at floor=high: %s" % c6)
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "8c: floor=high over incomplete — HARNESS_ERROR C6 row resolves to High severity and stays payable (#depth-sev)"
  else bad "8c: HARNESS_ERROR severity/payability wrong"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "8c: emit-model failed on the incomplete floor=high descriptor"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

# (8d) default (no pay_floor over MAIN_DESC): pay_floor is null, no row is unpayable, and the render carries no
# payfloor-x0 sentinel anywhere — the feature is behaviourally identical to today when no floor is set.
if emit_model "$MAIN_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
e = []
if m["pay_floor"] is not None: e.append("pay_floor must be null with no floor set: %r" % m["pay_floor"])
if any(l["unpayable"] for l in m["leads"]): e.append("no breadth lead may be unpayable with no floor")
if any(d["unpayable"] for d in m["deep_rows"]): e.append("no DEPTH row may be unpayable with no floor")
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "8d: no floor — pay_floor null, no unpayable rows (model identical to today)"
  else bad "8d: default (no floor) model regressed"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "8d: emit-model failed on the floor-less descriptor"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi
# #1966: fold in the no-floor render case for the "N sub-floor leads hidden" summary line — with pay_floor
# unset, all three (High/Medium/Low) breadth rows must still render and no summary line may appear.
if python3 "$DASH" --descriptor "$MAIN_DESC" --render > "$WORK/page.html" 2>"$WORK/render.err"; then
  if python3 - "$WORK/page.html" <<'PY'
import sys, re
html = open(sys.argv[1]).read()
e = []
if "payfloor-x0" in html: e.append("a floor-less render must carry no payfloor-x0 sentinel")
if re.search(r"\d+ sub-floor leads? hidden", html):
    e.append("a floor-less render must carry no 'sub-floor ... hidden' summary line")
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "8d-render: floor-less render carries no payfloor-x0 sentinel and no sub-floor-hidden line (byte-behaviour identical to today, #1966)"
  else bad "8d-render: default (no floor) render regressed"; sed 's/^/      /' "$WORK/render.err" | head -3 >&2
  fi
else
  bad "8d-render: --render failed on the floor-less descriptor"; sed 's/^/      /' "$WORK/render.err" | head -5 >&2
fi

# (8e) #depth-sev boundary — a NON-CUSTODY, not-yet-run (queued) DEPTH row is the exact pair this PR turns on:
#   - over a pay-floor program it has no join and no intrinsic custody severity, so it falls back to the
#     program floor (previously it was BLANK — the behaviour this PR ADDS); at the floor it stays PAYABLE.
#   - over a FLOOR-LESS program there is nothing to fall back to, so it stays BLANK (em-dash) — the pre-#depth-sev
#     boundary this PR preserves. Both halves get explicit coverage since the PR reverses the earlier gating.
# stage_noncustody <dst-name> <floor-or-empty> — stage balancer, optionally patch pay_floor, and APPEND a
# value_custody:false zone whose dominant class (C2, in the NONCUST lens set) yields one queued `oracle_pricing-C2`
# row; echo the staged descriptor path.
stage_noncustody() {
  snc_desc="$(stage_as balancer "$1")"
  python3 - "$snc_desc" "$2" <<'PY'
import json, os, sys
desc = sys.argv[1]; floor = sys.argv[2]
d = json.load(open(desc))
if floor: d["pay_floor"] = floor
json.dump(d, open(desc, "w"), indent=2, sort_keys=True)
zp = os.path.join(os.path.dirname(desc), "zone-hunt-out", "map", "zones.json")
zs = json.load(open(zp))
zs.append({
    "id": "oracle_pricing", "name": "Oracle pricing adapters",
    "files": ["contracts/oracle/PriceAdapter.sol", "contracts/oracle/Feed.sol"],
    "loc": 800, "hardening_score": 60, "bug_classes_likely": ["C2"],
    "description": "Read-only price oracle adapters; no funds held.",
    "value_custody": False,
})
json.dump(zs, open(zp, "w"), indent=2)
PY
  echo "$snc_desc"
}

NC_HIGH_DESC="$(stage_noncustody balancer-noncustody-high high)"
if emit_model "$NC_HIGH_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
e = []
q = next((d for d in m["deep_rows"] if d["slot"] == "oracle_pricing-C2"), None)
# NEW #depth-sev path: no join + no custody + a program floor -> falls back to the floor ("High"), still a
# queued (not-yet-run) row, and being AT the floor it is payable.
if not (q and q["state"] == "queued"):
    e.append("expected a queued oracle_pricing-C2 row over floor=high: %s" % q)
elif not (q["severity"] == "High" and q["unpayable"] is False):
    e.append("non-custody queued row over floor=high must resolve the pay-floor 'High' and stay payable: %s" % q)
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "8e: non-custody queued row over floor=high resolves the pay-floor severity (High) and stays payable (#depth-sev NEW path)"
  else bad "8e: non-custody queued pay-floor fallback wrong"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "8e: emit-model failed on the non-custody floor=high descriptor"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

NC_NONE_DESC="$(stage_noncustody balancer-noncustody-none "")"
if emit_model "$NC_NONE_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
e = []
q = next((d for d in m["deep_rows"] if d["slot"] == "oracle_pricing-C2"), None)
# BOUNDARY the PR preserves: no floor + no custody -> nothing to fall back to -> the queued row stays blank.
if not (q and q["state"] == "queued"):
    e.append("expected a queued oracle_pricing-C2 row over a floor-less program: %s" % q)
elif not (q["severity"] == "" and q["unpayable"] is False):
    e.append("non-custody queued row over a FLOOR-LESS program must stay blank and payable: %s" % q)
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "8e-boundary: non-custody queued row over a floor-less program stays blank (em-dash), payable — pre-#depth-sev boundary preserved"
  else bad "8e-boundary: floor-less non-custody queued row not blank"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "8e-boundary: emit-model failed on the non-custody floor-less descriptor"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

# (8f) #deep-cell-stale: a deep-hunt cell DIR alone must NOT read "running" forever. A cell that was
# force-advanced (watchdog) or whose flat-cyborg session hung leaves a SILENT dir on disk; `os.path.isdir()`
# alone would keep rendering it "🔄 fuzzing…" indefinitely. The fix: a live cell writes an LLM heartbeat into
# its dir every ~4s, so a dir silent past the stale bound (default 600s) is ABANDONED -> harness_error (a
# coverage gap); a freshly-written dir is genuinely running. The balancer fixture has no C5 cell dir (C5 is
# the queued lens), so plant one with a controllable mtime to exercise both arms.
# plant_c5 <dst-name> <age-seconds> -> stage balancer, create a pkg_vault_contracts-C5/run/ dir whose newest
# write is <age>s old; echo the staged descriptor.
plant_c5() {
  p5_desc="$(stage_as balancer "$1")"
  p5_run="$WORK/$1/zone-hunt-out/deep-hunt/pkg_vault_contracts-C5/run"
  mkdir -p "$p5_run"
  printf 'still waiting (heartbeat)\n' > "$p5_run/llm.log"
  p5_t=$(( $(date +%s) - $2 ))
  touch -d "@$p5_t" "$p5_run/llm.log" "$p5_run" "$WORK/$1/zone-hunt-out/deep-hunt/pkg_vault_contracts-C5"
  echo "$p5_desc"
}

STALE_C5_DESC="$(plant_c5 balancer-cell-stale 1200)"   # 20 min silent => abandoned
if emit_model "$STALE_C5_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
d = next((x for x in m["deep_rows"] if x["slot"] == "pkg_vault_contracts-C5"), None)
e = []
if not d: e.append("planted C5 row missing")
elif d["state"] != "harness_error":
    e.append("a silent (20-min-stale) deep-hunt cell dir must read harness_error (coverage gap), not running: %s" % d)
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "8f: a stale/silent deep-hunt cell dir reads harness_error (coverage gap), not a perpetual 'running' (#deep-cell-stale)"
  else bad "8f: stale deep-hunt cell not classified as harness_error"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "8f: emit-model failed on the stale-cell descriptor"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

FRESH_C5_DESC="$(plant_c5 balancer-cell-fresh 5)"      # 5 s ago => genuinely live (running)
if emit_model "$FRESH_C5_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
d = next((x for x in m["deep_rows"] if x["slot"] == "pkg_vault_contracts-C5"), None)
e = []
if not d:
    e.append("planted C5 row missing")
# The point: a FRESH dir is LIVE, never the abandoned/harness_error the stale case is, and never queued.
# In a clean env active_deep_slot() is None (no live hunt proc) so deep_cell_status() -> "running"; on a
# host that happens to be running an UNRELATED live hunt, active_deep_slot() may instead claim the freshest
# slot as "rerunning". Both are the correct "cell is live" outcome, so accept either (keeps this host-robust,
# unlike the 4 liveness assertions above which are known to be perturbed by a concurrent host hunt).
elif d["state"] not in ("running", "rerunning"):
    e.append("a freshly-written deep-hunt cell dir must read live (running/rerunning), not queued/harness_error: %s" % d)
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "8f-fresh: a freshly-written deep-hunt cell dir reads live (running/rerunning), never abandoned (#deep-cell-stale)"
  else bad "8f-fresh: fresh deep-hunt cell not classified as live"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "8f-fresh: emit-model failed on the fresh-cell descriptor"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (9) SEVERITY/CLASS NORMALIZATION (#1974) — an LLM-emitted candidate carrying whitespace-mangled severity
# ("H igh") and class ("C 22") tokens must normalize to the canonical "High"/"C22" at parse time (leads()),
# not leak through raw. Staged into a SEPARATE copy of the balancer fixture (balancer-sevnorm) so the
# count-exact assertions in (1)-(8) above, which run against the shared MAIN_DESC/HIGH_DESC/CRIT_DESC
# staged dirs, are unaffected.
# ----------------------------------------------------------------------------------------------------------
note "6) severity/class normalization (#1974: whitespace + prefix mangling) ..."
SEVNORM_DESC="$(stage_as balancer balancer-sevnorm)"
SEVNORM_DIR="$(dirname "$SEVNORM_DESC")"
SEVNORM_CELLS="$SEVNORM_DIR/zone-hunt-out/discovery/pkg_vault_contracts/run/results-cells.jsonl"
cat >>"$SEVNORM_CELLS" <<'EOF'
{"subsystem":"Vault core and routers","class":"C22","files":"pkg/vault/contracts/SevNormExample.sol","status":"ok","candidates":["pkg/vault/contracts/SevNormExample.sol:sevNormProbe|class=C 22|severity=H igh|Whitespace/prefix normalization probe candidate exercising #1974.","pkg/vault/contracts/SevNormExample.sol:prefixWsProbe|class=C22|se verity=High|#1976 probe: whitespace INSIDE the severity= prefix word must still normalize."],"coordination":[]}
EOF

if emit_model "$SEVNORM_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
e = []
byloc = {l["loc"]: l for l in m["leads"]}
probe = byloc.get("pkg/vault/contracts/SevNormExample.sol:sevNormProbe")
if not probe: e.append("normalization probe lead not found in leads[]")
else:
    if probe["sev"] != "High": e.append("mangled 'H igh' severity did not normalize: %r (want 'High')" % probe["sev"])
    if probe["cls"] != "C22": e.append("mangled 'C 22' class did not normalize: %r (want 'C22')" % probe["cls"])
pfx = byloc.get("pkg/vault/contracts/SevNormExample.sol:prefixWsProbe")
if not pfx: e.append("#1976 prefix-whitespace probe lead not found in leads[]")
elif pfx["sev"] != "High": e.append("#1976 'se verity=High' (whitespace in prefix word) did not normalize: %r (want 'High')" % pfx["sev"])
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "6a: mangled 'severity=H igh'/'class=C 22' normalize to canonical 'High'/'C22' in the model"
  else bad "6a: severity/class normalization model assertion failed"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "6a: emit-model failed on the severity-normalization descriptor"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

if python3 "$DASH" --descriptor "$SEVNORM_DESC" --render > "$WORK/page.html" 2>"$WORK/render.err"; then
  if python3 - "$WORK/page.html" <<'PY'
import sys
html = open(sys.argv[1]).read()
marker = "pkg/vault/contracts/SevNormExample.sol:sevNormProbe"
i = html.find(marker)
if i < 0:
    print("normalization probe row not found in rendered HTML: %r" % marker); sys.exit(1)
row_start = html.rfind("<tr", 0, i)
row_end = html.find("</tr>", i)
if row_start < 0 or row_end < 0:
    print("could not locate the enclosing <tr> for the normalization probe row"); sys.exit(1)
row = html[row_start:row_end]
sev_end = row.find(">High<")
if sev_end < 0:
    print("normalization probe row missing bare 'High' severity text: %r" % row); sys.exit(1)
sev_td_start = row.rfind("<td", 0, sev_end)
sev_td = row[sev_td_start:sev_end]
if "color:#ff5c5c" not in sev_td: e = "normalization probe Sev cell missing SEVCOL High colour (#ff5c5c): %r" % sev_td; print(e); sys.exit(1)
if "font-weight:600" not in sev_td: print("normalization probe Sev cell missing font-weight:600: %r" % sev_td); sys.exit(1)
if "#ccc" in sev_td: print("normalization probe Sev cell fell back to the grey SEVCOL-miss colour (#ccc) — normalization not applied at render time: %r" % sev_td); sys.exit(1)
PY
  then ok "6b: normalization probe row renders with the canonical High SEVCOL colour (#ff5c5c) + font-weight:600, no grey #ccc fallback"
  else bad "6b: severity/class normalization render assertion failed"
  fi
else
  bad "6b: --render failed on the severity-normalization descriptor"; sed 's/^/      /' "$WORK/render.err" | head -5 >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (10) #1981: the refute gate's verdict contract emits `REAL` for a lead that survived the hostile read; the
# dashboard must canonicalize that to its survived/CONFIRMED verdict. Before the fix a `REAL` verdict fell
# through to PENDING, so a genuinely-confirmed breadth lead showed as un-triaged forever. Stage balancer, rewrite
# the settle gate's verdict.txt from CONFIRMED to REAL, and assert the settle lead STILL reads CONFIRMED.
REAL_DESC="$(stage_as balancer balancer-real-verdict)"
echo "REAL	survived a hostile read" > "$WORK/balancer-real-verdict/zone-hunt-out/verify/gates/2_pkg_vault_contracts_Vault_sol_settle/verdict.txt"
if emit_model "$REAL_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
con = next((l for l in m["leads"] if l["loc"] == "pkg/vault/contracts/Vault.sol:settle"), None)
e = []
if not con:
    e.append("settle lead missing")
elif con["verdict"] != "CONFIRMED":
    e.append("a `REAL` gate verdict must canonicalize to CONFIRMED (survived), not fall through to PENDING: %s" % con)
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "10: a gate 'REAL' verdict canonicalizes to CONFIRMED/survived — never stuck at PENDING (#1981)"
  else bad "10: REAL-verdict lead not confirmed"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "10: emit-model failed on the REAL-verdict descriptor"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

# (11) #1989: a breadth lead's severity is RECONCILED down from the LLM hunter's over-claim to the rules-based
# tier for its impact text, so an over-claimed sub-floor finding stops looking payable. Inject a candidate
# claimed `High` whose impact is a griefing nonce-burn (rules => Medium) into a pay-floor=high staged copy, and
# assert emit-model shows it at Medium, preserves the claim, flags the over-claim, and marks it sub-floor —
# the exact TermMax UniversalFactory:deploy:28 case.
OC_DESC="$(stage_floor balancer balancer-overclaim high)"
_zc="$(ls "$WORK/balancer-overclaim/zone-hunt-out/discovery/"*/run/results-cells.jsonl 2>/dev/null | head -1)"
if [ -n "$_zc" ]; then
  printf '%s\n' '{"candidates":["contracts/X.sol:deploy:1|class=C5|severity=High|any zero-privilege address can burn the factory mined nonce, permanently destroying the canonical deploy address; no funds are stolen or frozen|PoC recipe here"]}' >> "$_zc"
fi
if emit_model "$OC_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
oc = next((l for l in m["leads"] if l["loc"] == "contracts/X.sol:deploy:1"), None)
e = []
if not oc:
    e.append("injected over-claim lead missing from the model")
else:
    if oc["sev"] != "Medium": e.append("over-claimed High should reconcile to Medium (griefing rules), got %r" % oc["sev"])
    if oc.get("sev_claimed") != "High": e.append("hunter's claim not preserved in sev_claimed: %r" % oc.get("sev_claimed"))
    if not oc.get("overclaim"): e.append("overclaim flag not set on a reclassified-down lead")
    if not oc.get("unpayable"): e.append("reconciled Medium not marked sub-floor at floor=high")
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "11: an over-claimed High lead (griefing impact) reconciles to Medium, preserves+flags the claim, and is sub-floor at floor=high (#1989)"
  else bad "11: severity reconciliation wrong"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "11: emit-model failed on the over-claim descriptor"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

# (12) #1989: an INDETERMINATE impact (no in-scope keyword) must KEEP the hunter's claim — the reconciler only
# LOWERS on a POSITIVE lower-tier classification, never on absence of a match (the Python `_rules_severity`
# returns "" here, unlike the shell's assumed-in-scope Medium default). Pins that a genuine High whose prose the
# keyword matcher can't classify is never wrongly demoted. Reuse the (11) staged copy + append an indeterminate
# High candidate.
if [ -n "$_zc" ]; then
  printf '%s\n' '{"candidates":["contracts/Y.sol:f:9|class=C6|severity=High|an unusual interaction in the accounting path produces an inconsistent internal counter under a specific ordering|PoC recipe"]}' >> "$_zc"
fi
if emit_model "$OC_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
ind = next((l for l in m["leads"] if l["loc"] == "contracts/Y.sol:f:9"), None)
e = []
if not ind:
    e.append("injected indeterminate lead missing from the model")
else:
    if ind["sev"] != "High": e.append("an indeterminate impact must KEEP the High claim, got %r" % ind["sev"])
    if ind.get("overclaim"): e.append("indeterminate impact wrongly flagged as an over-claim")
if e:
    print("\n".join(e)); sys.exit(1)
PY
  then ok "12: an indeterminate impact keeps the hunter's claim (High), no demotion, no over-claim flag (#1989)"
  else bad "12: indeterminate-impact reconciliation wrong"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "12: emit-model failed on the indeterminate descriptor"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

# (13) #1991: a zone left 'in_flight' when the hunt EXITED must render as ABANDONED (a coverage gap), never
# 'running' — the zone-level twin of the #1980 abandoned-cell fix. Stage the exited fixture (balancer-incomplete
# carries the __EXIT__ marker), flip a zone's coverage status to in_flight, and force proc-gone so `exited` is
# deterministic regardless of any live hunt on the host; assert no zone stays in_flight/running and the one
# reads 'abandoned'.
AB_DESC="$(stage_as balancer-incomplete balancer-abandoned)"
python3 - "$WORK/balancer-abandoned/zone-hunt-out/coverage/zone-coverage.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
zs = c.get("zones", c)
lst = list(zs.values()) if isinstance(zs, dict) else zs
lst[0]["status"] = "in_flight"     # simulate a zone the hunt was mid-flight on when it exited
json.dump(c, open(p, "w"))
PY
if emit_model "$AB_DESC" HUNT_DASHBOARD_FAKE_PROC_ALIVE=0 HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
e = []
if not m.get("exited"): e.append("fixture with __EXIT__ + proc-gone should read exited=True")
running = [z["id"] for z in m["zones"] if z["status"] == "in_flight"]
if running: e.append("an exited hunt still has in_flight/running zones: %s" % running)
if not any(z["status"] == "abandoned" for z in m["zones"]): e.append("the mid-flight zone was not reclassified to 'abandoned'")
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "13: a zone left in_flight when the hunt exited renders as abandoned (gap), never running (#1991)"
  else bad "13: exited in_flight zone not reclassified"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "13: emit-model failed on the abandoned descriptor"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

# (14) #1994: every lead + deep-hunt finding carries a short, STABLE, referenceable id derived deterministically
# from its identity (loc + class). Two emits over the same fixture must yield IDENTICAL ids per (loc,class)
# (refresh-stable), every id is 6-hex (or the blank sentinel), and DISTINCT (loc,class) never collide.
emit_model "$MAIN_DESC" && cp "$WORK/model.json" "$WORK/model-a.json"
emit_model "$MAIN_DESC" && cp "$WORK/model.json" "$WORK/model-b.json"
if python3 - "$WORK/model-a.json" "$WORK/model-b.json" <<'PY'
import sys, json, re
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
ra = a["leads"] + a["deep_rows"]; rb = b["leads"] + b["deep_rows"]
e = []
for r in ra:
    if not re.fullmatch(r"[0-9a-f]{6}|-{6}", r.get("id", "") or ""):
        e.append("bad id %r on %s" % (r.get("id"), r.get("loc")))
km = lambda rows: {(r["loc"], r.get("cls", "")): r["id"] for r in rows}
ka, kb = km(ra), km(rb)
for k in ka:
    if ka[k] != kb.get(k): e.append("id not refresh-stable for %s: %r vs %r" % (k, ka[k], kb.get(k)))
seen = {}
for k, i in ka.items():
    if i != "------" and i in seen and seen[i] != k:
        e.append("hash collision: %s and %s share id %s" % (seen[i], k, i))
    seen[i] = k
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "14: every lead/finding has a stable 6-hex id — refresh-stable per (loc,class), no collision on distinct surfaces (#1994)"
  else bad "14: finding-id contract wrong"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi

# (15) #1996: the LEADS table carries a client-side filter. Every rendered lead/deep row is tagged with a
# data-st bucket (confirmed / pending / refuted / other); a chip bar exposes All/Confirmed/Pending/Refuted
# with per-bucket counts; the filter JS + table id are present; and the column-header row is NOT tagged (so
# it never hides). Assertions are CONSISTENCY-based (chip counts must equal the actual rendered bucket
# counts) so they hold regardless of the fixture's exact numbers.
if python3 "$DASH" --descriptor "$MAIN_DESC" --render > "$WORK/page.html" 2>"$WORK/render.err"; then
  if python3 - "$WORK/page.html" <<'PY'
import sys, re, collections
html = open(sys.argv[1]).read()
e = []
# chip bar: sel -> count
chips = dict((m.group(1), int(m.group(2))) for m in
             re.finditer(r'data-sel="(\w+)"[^>]*>[^<]*<b>(\d+)</b>', html))
for want in ("all", "confirmed", "pending", "duplicate", "refuted"):
    if want not in chips: e.append("missing filter chip %r" % want)
# rendered row buckets
rows = re.findall(r'<tr data-st="(\w+)"', html)
buckets = collections.Counter(rows)
if not rows: e.append("no data-st rows rendered — filter would be vacuous")
VOCAB = {"confirmed", "pending", "duplicate", "refuted", "other"}
bad = set(buckets) - VOCAB
if bad: e.append("data-st outside vocabulary: %r" % sorted(bad))
# consistency: All == total rows; each named chip == its bucket count
if chips.get("all") != len(rows):
    e.append("chip All=%r != rendered rows=%d" % (chips.get("all"), len(rows)))
for k in ("confirmed", "pending", "duplicate", "refuted"):
    if chips.get(k) != buckets.get(k, 0):
        e.append("chip %s=%r != bucket count %d" % (k, chips.get(k), buckets.get(k, 0)))
# plumbing present
if "function hfilter" not in html: e.append("filter JS (hfilter) missing")
if '<table id="leadtbl">' not in html: e.append('table id="leadtbl" missing (JS could not scope)')
# the column-header row must NOT be filterable (else the header hides under a chip)
hdr = re.search(r'(<tr[^>]*>\s*<td>Type</td>)', html)
if not hdr: e.append("LEADS column-header row not found")
elif "data-st" in hdr.group(1): e.append("column-header row is data-st tagged — it would hide under a filter")
if e: print("\n".join(e)); sys.exit(1)
PY
    then ok "15: LEADS filter — every row bucketed (confirmed/pending/refuted/other), chip counts match rendered buckets, header untagged, JS+table-id present (#1996)"
    else bad "15: lead-filter contract wrong"; sed 's/^/      /' "$WORK/render.err" | head -3 >&2
    fi
else
  bad "15: --render failed on the lead-filter descriptor"; sed 's/^/      /' "$WORK/render.err" | head -5 >&2
fi

# (16) #1999: two dashboard-honesty fixes.
#  (a) phase_status must treat "exited" the SAME way page() does — __EXIT__ marker AND no live hunt process.
#      A re-hunt appends fresh [M3] lines after a prior run's stale __EXIT__ marker; keying off the marker
#      alone wrongly paints the discovery phase a "gap" while Zones (via proc_alive) show a zone in_flight.
#      Same exited+incomplete fixture: fake-alive=0 => discovery "gap" + STOPPED_INCOMPLETE (preserved);
#      fake-alive=1 => discovery NOT "gap" + banner RUNNING (the fix).
#  (b) the "confirmed" chip is labelled "Confirmed" — honest under #2005 because membership is now gated on an
#      operator CONFIRMED verdict (real + non-dup), so the label no longer over-claims (superseded the #1999
#      "Survived" label once the bucket stopped auto-including survived-a-gate leads).
# Fake BOTH liveness sources (proc scan AND llm-inflight) so the assertion is host-independent — otherwise a
# real hunt's claude/flat-cyborg children on the same host leak into llm_child() and perturb hunt_live.
emit_model "$INC_DESC" HUNT_DASHBOARD_FAKE_PROC_ALIVE=0 HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0 && cp "$WORK/model.json" "$WORK/m-dead.json"
emit_model "$INC_DESC" HUNT_DASHBOARD_FAKE_PROC_ALIVE=1 HUNT_DASHBOARD_FAKE_LLM_INFLIGHT=0 && cp "$WORK/model.json" "$WORK/m-live.json"
if python3 - "$WORK/m-dead.json" "$WORK/m-live.json" <<'PY'
import sys, json
dead = json.load(open(sys.argv[1])); live = json.load(open(sys.argv[2]))
e = []
dph = dead["phases"].get("M3 · discovery"); lph = live["phases"].get("M3 · discovery")
# dead (no live process, __EXIT__, incomplete): the preserved "gap" behaviour
if dph != "gap": e.append('exited+incomplete+process-gone: discovery phase should be "gap", got %r' % dph)
if dead["banner"] != "STOPPED_INCOMPLETE": e.append("process-gone banner=%r (want STOPPED_INCOMPLETE)" % dead["banner"])
# live (same fixture, but a hunt process is detected): NOT a gap, and the banner reflects a running hunt
if lph == "gap": e.append('__EXIT__ + LIVE process: discovery phase must NOT be "gap" (that is the #1999 bug)')
if live["banner"] != "RUNNING": e.append("live banner=%r (want RUNNING — a detected process is not 'exited')" % live["banner"])
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "16a: phase_status keys 'exited' on __EXIT__ AND no-live-process — a re-hunt over a stale marker shows discovery running, not a false gap (#1999)"
  else bad "16a: phase-live guard wrong"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
# (16b) the confirmed chip is labelled "Confirmed" (honest under #2005 — membership is gated, see test 19)
if python3 "$DASH" --descriptor "$MAIN_DESC" --render > "$WORK/page.html" 2>"$WORK/render.err"; then
  if python3 - "$WORK/page.html" <<'PY'
import sys, re
html = open(sys.argv[1]).read()
e = []
m = re.search(r'data-sel="confirmed"[^>]*>\s*([A-Za-z]+)\s*<b>', html)
if not m: e.append("could not find the confirmed chip label")
elif m.group(1) != "Confirmed": e.append('confirmed chip label is %r, must be "Confirmed"' % m.group(1))
if e: print("\n".join(e)); sys.exit(1)
PY
    then ok "16b: the confirmed chip is labelled 'Confirmed' — honest now that membership is gated on an operator CONFIRMED verdict (#2005 supersedes #1999)"
    else bad "16b: chip label not honest"; sed 's/^/      /' "$WORK/render.err" | head -3 >&2
    fi
else
  bad "16b: --render failed"; sed 's/^/      /' "$WORK/render.err" | head -5 >&2
fi

# (17) #2001: the deep-hunt (4.5) + refute-deep (4.6) phases show "run" only when deep-hunt is LIVE right now
# (an active_deep_slot: a deep cell writing within 90s), NOT merely because a `STAGE 4.5`/`[deep-hunt]` marker
# appeared once in the append-only log. A re-hunt re-enters discovery after a full prior pass, so those markers
# persist while the deep cells sit hours-stale and only discovery is working — the phase panel must not then
# claim the fuzzer is running. Both fixtures force the RUNNING branch (fake-alive=1); they differ ONLY in the
# planted deep cell's freshness, isolating the live signal.
DLIVE_DESC="$(plant_c5 phase-deep-live 5)"      # deep cell written 5s ago  => deep-hunt IS live
DIDLE_DESC="$(plant_c5 phase-deep-idle 1200)"   # deep cell 20-min stale    => deep-hunt idle (markers persist)
emit_model "$DLIVE_DESC" HUNT_DASHBOARD_FAKE_PROC_ALIVE=1 && cp "$WORK/model.json" "$WORK/m-dlive.json"
emit_model "$DIDLE_DESC" HUNT_DASHBOARD_FAKE_PROC_ALIVE=1 && cp "$WORK/model.json" "$WORK/m-didle.json"
if python3 - "$WORK/m-dlive.json" "$WORK/m-didle.json" <<'PY'
import sys, json
live = json.load(open(sys.argv[1])); idle = json.load(open(sys.argv[2]))
e = []
# a genuinely live deep cell => deep-hunt reads "run"
if live["phases"].get("4.5 · deep-hunt") != "run":
    e.append('fresh deep cell: 4.5 deep-hunt should be "run", got %r' % live["phases"].get("4.5 · deep-hunt"))
# an idle (stale) deep cell, markers still in the log => must NOT read "run" (that is the #2001 bug); "done"
if idle["phases"].get("4.5 · deep-hunt") == "run":
    e.append('idle deep-hunt still reads "run" — log-presence is forcing a false running state (#2001)')
if idle["phases"].get("4.5 · deep-hunt") != "done":
    e.append('idle-but-ran deep-hunt should be "done", got %r' % idle["phases"].get("4.5 · deep-hunt"))
# refute-deep must not claim active triage while deep-hunt is idle
if idle["phases"].get("4.6 · refute deep-hunt") == "run":
    e.append('idle refute-deep still reads "run" — an un-triaged backlog is not active triage (#2001)')
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "17: deep-hunt/refute-deep read 'run' only when a deep cell is LIVE now, not from a stale log marker — a re-hunt in discovery no longer shows a phantom running fuzzer (#2001)"
  else bad "17: deep-live phase signal wrong"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi

# (18) #2003: the deep-hunt freshness walk must SKIP the cloned-target/build subtrees (run/repo/, out/, cache/,
# lib/ ...). A deep cell clones the whole target repo under run/repo/ (~6k files/cell, ~120k on a full re-hunt),
# and walking it made a render take ~19s. Correctness guard: a cell whose ONLY fresh write is under run/repo/
# while its LLM heartbeat (run/llm.log) is 20-min stale must still read abandoned (harness_error) — i.e. the
# fresh repo/ file is ignored. Without the prune, repo/ freshness would flip it to a false "running".
REPO_DESC="$(plant_c5 phase-repo-prune 1200)"   # heartbeat (run/llm.log) 20-min stale => cell is abandoned
REPO_CELL="$WORK/phase-repo-prune/zone-hunt-out/deep-hunt/pkg_vault_contracts-C5/run/repo"
mkdir -p "$REPO_CELL"
printf 'pragma solidity ^0.8.0;\ncontract Target {}\n' > "$REPO_CELL/Target.sol"   # FRESH write, but under repo/
if emit_model "$REPO_DESC"; then
  if python3 - "$WORK/model.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
d = next((x for x in m["deep_rows"] if x["slot"] == "pkg_vault_contracts-C5"), None)
e = []
if not d: e.append("planted C5 row missing")
elif d["state"] != "harness_error":
    e.append('a cell with a fresh file only under run/repo/ (heartbeat stale) must read harness_error — '
             'the freshness walk is descending the pruned target clone: %s' % d)
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "18: the freshness walk skips run/repo/ (cloned target) — a fresh repo/ file does not resurrect a heartbeat-stale cell (#2003 perf prune, correctness-preserving)"
  else bad "18: repo/ prune changed liveness verdict"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "18: emit-model failed on the repo-prune fixture"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi

# (19) #2005: the "Confirmed" bucket holds ONLY operator-confirmed real + non-duplicate findings. Surviving an
# automated gate is NOT confirmation, so by default nothing is Confirmed — a deep FINDING and a survived-refute
# lead both sit in Pending. A `CONFIRMED` verdict in the adjudication overlay is the ONLY path into Confirmed.
# (19a) default: nothing auto-confirmed
if python3 "$DASH" --descriptor "$MAIN_DESC" --render > "$WORK/page.html" 2>"$WORK/render.err"; then
  if python3 - "$WORK/page.html" <<'PY'
import sys, re
html = open(sys.argv[1]).read()
e = []
n_conf = html.count('data-st="confirmed"')
if n_conf != 0:
    e.append("default fixture has %d confirmed rows — surviving a gate must NOT auto-confirm" % n_conf)
m = re.search(r'data-sel="confirmed"[^>]*>\s*(\w+)\s*<b>(\d+)</b>', html)
if not m: e.append("confirmed chip missing")
else:
    if m.group(1) != "Confirmed": e.append('chip label is %r, must be "Confirmed"' % m.group(1))
    if m.group(2) != "0": e.append("confirmed chip count is %s, must be 0 by default" % m.group(2))
if "needs forge PoC + triage" not in html:
    e.append("a deep FINDING should render as a Pending 'needs forge PoC + triage' row")
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "19a: nothing is Confirmed by default — surviving a gate is not confirmation; deep FINDINGs + survived-refute leads sit in Pending (#2005)"
  else bad "19a: confirmed-bucket default wrong"; sed 's/^/      /' "$WORK/render.err" | head -3 >&2
  fi
else
  bad "19a: --render failed"; sed 's/^/      /' "$WORK/render.err" | head -5 >&2
fi
# (19b) an operator CONFIRMED adjudication promotes exactly that finding into Confirmed
CONF_DESC="$(stage_as balancer balancer-confirmed)"
printf 'pkg/vault/contracts/Vault.sol\tC6\tCONFIRMED\treal bug, not a duplicate\n' >> "$WORK/balancer-confirmed/deep-hunt-adjudicated.tsv"
if python3 "$DASH" --descriptor "$CONF_DESC" --render > "$WORK/page2.html" 2>"$WORK/render.err"; then
  if python3 - "$WORK/page2.html" <<'PY'
import sys, re
html = open(sys.argv[1]).read()
e = []
if html.count('data-st="confirmed"') < 1:
    e.append("a CONFIRMED adjudication did not promote any row into Confirmed")
m = re.search(r'data-sel="confirmed"[^>]*>\s*\w+\s*<b>(\d+)</b>', html)
if not m or int(m.group(1)) < 1:
    e.append("confirmed chip count did not rise after a CONFIRMED adjudication")
if "◆ CONFIRMED — real, non-dup" not in html:
    e.append("expected the confirmed gate label on the promoted row")
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "19b: an operator CONFIRMED verdict (deep-hunt-adjudicated.tsv) is the only path that promotes a finding into Confirmed (#2005)"
  else bad "19b: CONFIRMED adjudication not honoured"; sed 's/^/      /' "$WORK/render.err" | head -3 >&2
  fi
else
  bad "19b: --render failed on the confirmed fixture"; sed 's/^/      /' "$WORK/render.err" | head -5 >&2
fi

# (20) #2007: a DUPLICATE verdict = a real, PoC-verified bug that was ALREADY REPORTED ($0). It gets its OWN
# bucket + "Duplicate" chip — it is NOT Confirmed (unpayable), NOT Pending (fully worked: PoC done + triaged),
# and NOT Refuted (it IS a real bug, so never struck-through as "not a bug" nor double-listed there).
DUP_DESC="$(stage_as balancer balancer-duplicate)"
printf 'pkg/vault/contracts/Vault.sol\tC6\tDUPLICATE\treal + PoC-verified; already reported as #12345 -> $0\n' >> "$WORK/balancer-duplicate/deep-hunt-adjudicated.tsv"
if python3 "$DASH" --descriptor "$DUP_DESC" --render > "$WORK/pagedup.html" 2>"$WORK/render.err"; then
  if python3 - "$WORK/pagedup.html" <<'PY'
import sys, re
html = open(sys.argv[1]).read()
e = []
if html.count('data-st="duplicate"') < 1:
    e.append("a DUPLICATE adjudication produced no duplicate-bucket row")
m = re.search(r'data-sel="duplicate"[^>]*>\s*(\w+)\s*<b>(\d+)</b>', html)
if not m: e.append("Duplicate chip missing")
else:
    if m.group(1) != "Duplicate": e.append('duplicate chip label %r, must be "Duplicate"' % m.group(1))
    if int(m.group(2)) < 1: e.append("Duplicate chip count did not rise after a DUPLICATE adjudication")
if "◆ real · DUPLICATE ($0)" not in html: e.append("expected the duplicate gate label with the $0 marker")
# the promoted duplicate must NOT be struck-through (it is a REAL bug, not a refuted 'not a bug')
row = re.search(r'<tr data-st="duplicate".*?</tr>', html, re.S)
if row and "line-through" in row.group(0):
    e.append("a duplicate row is struck-through like a refuted row — a duplicate is a REAL bug")
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "20: a DUPLICATE verdict lands in its own Duplicate bucket — real + PoC-verified but already reported (\$0), not struck like a refuted row, never Confirmed/Pending (#2007)"
  else bad "20: duplicate-state wrong"; sed 's/^/      /' "$WORK/render.err" | head -3 >&2
  fi
else
  bad "20: --render failed on the duplicate fixture"; sed 's/^/      /' "$WORK/render.err" | head -5 >&2
fi

# (21) #2009: the "Adjudicated — verified, NOT a bug (N)" header badge must count only rows actually rendered
# in that card's table body. The arows-building loop already skips CONFIRMED/DUPLICATE breadth adjudications
# (#2005/#2007 gave those their own buckets), but before this fix the header badge counted len(A) — the
# pre-filter total — so a DUPLICATE row inflated the header past the actual row count. Append a DUPLICATE row
# (keyed to the fixture's real C8 lead) to the BREADTH adjudicated.tsv (NOT deep-hunt-adjudicated.tsv — that
# overlay feeds the DEPTH matrix, not A/arows), so A holds 2 rows (the fixture's pre-existing REFUTED
# VaultAdmin.sol row + this new DUPLICATE one) of which only the REFUTED one should render.
ADJN_DESC="$(stage_as balancer balancer-adjudicated-count)"
printf 'pkg/vault/contracts/BufferRouter.sol:addLiquidityToBuffer\tC8\tLow\tDUPLICATE\treal + PoC-verified; already reported as #6789 -> $0\n' >> "$WORK/balancer-adjudicated-count/adjudicated.tsv"
if python3 "$DASH" --descriptor "$ADJN_DESC" --render > "$WORK/pageadjn.html" 2>"$WORK/render.err"; then
  if python3 - "$WORK/pageadjn.html" "$WORK/page.html" <<'PY'
import sys, re
html = open(sys.argv[1]).read()
baseline = open(sys.argv[2]).read()
e = []
m = re.search(r'Adjudicated — verified, NOT a bug \((\d+)\)', html)
if not m:
    e.append("Adjudicated header badge not found")
else:
    n = int(m.group(1))
    tm = re.search(r'Adjudicated — verified, NOT a bug \(\d+\)[^<]*</h2><table>(.*?)</table>', html, re.S)
    if not tm:
        e.append("Adjudicated card table not found")
    else:
        actual = tm.group(1).count("<tr") - 1   # minus the column-label row
        if n != actual:
            e.append("header badge says (%d) but the table body actually renders %d row(s) — a "
                     "CONFIRMED/DUPLICATE-skipped row inflated the header" % (n, actual))
        if actual != 1:
            e.append("expected exactly 1 rendered adjudicated row (the pre-existing REFUTED one), got %d" % actual)
base_dup = baseline.count('data-st="duplicate"')
new_dup = html.count('data-st="duplicate"')
if new_dup != base_dup + 1:
    e.append("duplicate-bucket row count did not rise by 1 relative to (19a)'s baseline (baseline=%d, now=%d) "
             "— the DUPLICATE-keyed lead was not routed into the Duplicate bucket" % (base_dup, new_dup))
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "21: the Adjudicated header (N) badge counts only rows actually rendered in its table — a DUPLICATE row (own bucket, #2007) no longer inflates it (#2009)"
  else bad "21: Adjudicated header count wrong"; sed 's/^/      /' "$WORK/render.err" | head -3 >&2
  fi
else
  bad "21: --render failed on the adjudicated-count fixture"; sed 's/^/      /' "$WORK/render.err" | head -5 >&2
fi

# ----------------------------------------------------------------------------------------------------------
# (22) #2023: an operator adjudication MUST win over an automated refute-gate verdict at BOTH verdict-selection
# surfaces — --emit-model (the JSON model) AND --render (the HTML). The fixture's C6 breadth lead
# BatchRouterHooks.sol:_erc4626BufferWrapOrUnwrapExactOut carries a gate REFUTED verdict (asserted struck in
# (1)/(2)). Append a CONFIRMED row for THAT SAME location to the breadth adjudicated.tsv and assert the gate
# REFUTED is overridden everywhere: the model reads CONFIRMED/not-struck with survived↑ refuted↓, and the row
# renders ◆ CONFIRMED — real, non-dup, never ✗ REFUTED. This is the exact regression #2005/#2007 left on the
# emit_model path (render honoured operator precedence; the model did not).
C2023_LOC="pkg/vault/contracts/BatchRouterHooks.sol:_erc4626BufferWrapOrUnwrapExactOut"
note "22) #2023: operator CONFIRMED/DUPLICATE overrides a gate REFUTED at both emit-model and render ..."
C2023_DESC="$(stage_as balancer balancer-2023-confirmed)"
printf '%s\tC6\tHigh\tCONFIRMED\treal bug, operator PoC-verified\n' "$C2023_LOC" >> "$WORK/balancer-2023-confirmed/adjudicated.tsv"
if emit_model "$C2023_DESC"; then
  if C2023_LOC="$C2023_LOC" python3 - "$WORK/model.json" <<'PY'
import sys, os, json
m = json.load(open(sys.argv[1]))
loc = os.environ["C2023_LOC"]
e = []
byloc = {l["loc"]: l for l in m["leads"]}
lead = byloc.get(loc)
if not lead:
    e.append("C6 lead not in model")
elif not (lead["verdict"] == "CONFIRMED" and not lead["struck"]):
    e.append("emit-model did NOT honour the operator CONFIRMED over the gate REFUTED: %s" % lead)
# survived rose to 2, refuted fell to 0 (the gate REFUTED no longer counts against the operator's ruling).
if m["leads_summary"] != {"total": 3, "survived": 2, "refuted": 0, "pending": 1}:
    e.append("leads_summary did not shift refuted->survived: %s" % m["leads_summary"])
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "22a: emit-model — operator CONFIRMED wins over the gate REFUTED (verdict CONFIRMED, not struck, survived↑/refuted↓)"
  else bad "22a: emit-model still shows the gate REFUTED for an operator-CONFIRMED location"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "22a: emit-model failed on the #2023 confirmed fixture"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi
if python3 "$DASH" --descriptor "$C2023_DESC" --render > "$WORK/page2023c.html" 2>"$WORK/render.err"; then
  if C2023_LOC="$C2023_LOC" python3 - "$WORK/page2023c.html" <<'PY'
import sys, os
html = open(sys.argv[1]).read()
loc = os.environ["C2023_LOC"]
e = []
i = html.find(loc)
if i < 0:
    print("C6 lead location not found in the rendered page"); sys.exit(1)
row = html[html.rfind("<tr", 0, i):html.find("</tr>", i)]
if "◆ CONFIRMED — real, non-dup" not in row:
    e.append("render did NOT show ◆ CONFIRMED for the operator-adjudicated location: %r" % row)
if "✗ REFUTED" in row:
    e.append("render still shows ✗ REFUTED for an operator-CONFIRMED location: %r" % row)
if 'data-st="confirmed"' not in row:
    e.append("row is not bucketed as confirmed: %r" % row)
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "22b: render — the operator-CONFIRMED location shows ◆ CONFIRMED, never ✗ REFUTED (bucketed confirmed)"
  else bad "22b: render still strikes the operator-CONFIRMED location as REFUTED"; sed 's/^/      /' "$WORK/render.err" | head -3 >&2
  fi
else
  bad "22b: --render failed on the #2023 confirmed fixture"; sed 's/^/      /' "$WORK/render.err" | head -5 >&2
fi
# DUPLICATE variant — a real, already-reported bug also overrides the gate REFUTED (its own bucket, $0).
C2023_DDESC="$(stage_as balancer balancer-2023-duplicate)"
printf '%s\tC6\tHigh\tDUPLICATE\treal + PoC-verified; already reported as #99999 -> $0\n' "$C2023_LOC" >> "$WORK/balancer-2023-duplicate/adjudicated.tsv"
if emit_model "$C2023_DDESC"; then
  if C2023_LOC="$C2023_LOC" python3 - "$WORK/model.json" <<'PY'
import sys, os, json
m = json.load(open(sys.argv[1]))
loc = os.environ["C2023_LOC"]
e = []
lead = {l["loc"]: l for l in m["leads"]}.get(loc)
if not (lead and lead["verdict"] == "DUPLICATE" and not lead["struck"]):
    e.append("emit-model did NOT honour the operator DUPLICATE over the gate REFUTED: %s" % lead)
if m["leads_summary"] != {"total": 3, "survived": 2, "refuted": 0, "pending": 1}:
    e.append("leads_summary did not count the DUPLICATE as survived: %s" % m["leads_summary"])
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "22c: emit-model — operator DUPLICATE wins over the gate REFUTED (verdict DUPLICATE, not struck)"
  else bad "22c: emit-model still shows the gate REFUTED for an operator-DUPLICATE location"; sed 's/^/      /' "$WORK/model.err" | head -3 >&2
  fi
else
  bad "22c: emit-model failed on the #2023 duplicate fixture"; sed 's/^/      /' "$WORK/model.err" | head -5 >&2
fi
if python3 "$DASH" --descriptor "$C2023_DDESC" --render > "$WORK/page2023d.html" 2>"$WORK/render.err"; then
  if C2023_LOC="$C2023_LOC" python3 - "$WORK/page2023d.html" <<'PY'
import sys, os
html = open(sys.argv[1]).read()
loc = os.environ["C2023_LOC"]
i = html.find(loc)
if i < 0:
    print("C6 lead location not found in the rendered page"); sys.exit(1)
row = html[html.rfind("<tr", 0, i):html.find("</tr>", i)]
e = []
if "◆ real · DUPLICATE ($0)" not in row:
    e.append("render did NOT show the DUPLICATE bucket for the operator-adjudicated location: %r" % row)
if "✗ REFUTED" in row:
    e.append("render still shows ✗ REFUTED for an operator-DUPLICATE location: %r" % row)
if 'data-st="duplicate"' not in row:
    e.append("row is not bucketed as duplicate: %r" % row)
if e: print("\n".join(e)); sys.exit(1)
PY
  then ok "22d: render — the operator-DUPLICATE location shows the DUPLICATE bucket, never ✗ REFUTED"
  else bad "22d: render still strikes the operator-DUPLICATE location as REFUTED"; sed 's/^/      /' "$WORK/render.err" | head -3 >&2
  fi
else
  bad "22d: --render failed on the #2023 duplicate fixture"; sed 's/^/      /' "$WORK/render.err" | head -5 >&2
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the #1913 M1 hunt-dashboard reference-fidelity model holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
