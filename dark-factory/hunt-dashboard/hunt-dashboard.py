#!/usr/bin/env python3
# Live hunt dashboard (reusable, single-hunt). Localhost-only HTTP server that regenerates the page from a
# zone-hunt's artifacts on every request (the browser auto-refreshes), so it is always fresh with no stale
# file. Read-only: it only READS the hunt output files and serves HTML. Bound to loopback, never exposed to
# the network.
#
# This is the #1913 M1 productization of the operator-approved per-hunt dashboard: a verbatim behavioural port
# whose ONLY functional delta is CONFIG-DRIVEN PATHS — the hunt root / out dir / run log and the header chrome
# (label, reward line, bounty/repo/project links) come from a descriptor JSON or CLI flags instead of being
# hardcoded to one target. Everything the reference renders is preserved. Multi-hunt tabs / a registry / an
# overview grid are M2 (a separate follow-on), NOT here.
#
# Offline/test seams (no rendered-behaviour change): `--render` emits the HTML once to stdout (no server);
# `--emit-model` emits the computed facts as JSON (the deterministic assertion surface); the env overrides
# HUNT_DASHBOARD_FAKE_PROC_ALIVE / HUNT_DASHBOARD_FAKE_LLM_INFLIGHT replace the /proc liveness scan for
# fixtures only (unset in production => the real scan runs). The /proc glob is guarded so a non-Linux host
# degrades to freshness-only instead of crashing.
import json, os, re, glob, datetime, html, sys, argparse, threading, hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# ---- config-driven paths + chrome (the ONE functional delta vs the reference) ---------------------------
# The reference hardcoded ROOT/OUT/LOG at module scope and one target's header/reward/links in page(). Here
# they live on a single descriptor, assigned to these module globals once at startup so every reader below is
# a line-for-line port that still reads ROOT/OUT/LOG.
ROOT = ""       # hunt root (the --repo and --out are non-overlapping siblings under here)
OUT  = ""       # zone-hunt-out dir
LOG  = ""       # top-level run log
LABEL = "hunt"  # header/title display name
REWARD_LINE = ""    # optional chrome line (program · reward · KYC · surface)
BOUNTY_URL = ""     # optional program URL
REPO_URL = ""       # optional in-scope repo URL
PROJECT_URL = ""    # optional project URL
PAY_FLOOR = ""      # optional program pay-floor severity (low|medium|high|critical) — display-only sub-floor marker
HOST, PORT = "127.0.0.1", 8420

# ---- M2 multi-hunt (overview -> detail over a descriptor registry) --------------------------------------
# REGISTRY_MODE flips the server from the M1 single-hunt view to the M2 overview grid + per-hunt detail. It is
# set ONLY when the launcher gives neither a descriptor nor path flags (see main()); the M1 single-hunt path
# is otherwise byte-for-byte unchanged. REGISTRY_DIR defaults to ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/hunts
# (the opt-in dir the run-zone-hunt.sh hook writes into). CUR_HUNT_ID scopes the test-only liveness fakes to
# ONE hunt so a fixture registry can render a finished card and a live card in the SAME overview.
REGISTRY_MODE = False
REGISTRY_DIR = ""
CUR_HUNT_ID = ""

# ---- M4 change-cadence overview panel (#2135, epic #2120) -----------------------------------------------
# change-pipeline.sh writes ONE PATCH-able tick-summary JSON; the overview renders it as a single full-width
# panel above the hunt grid so an unattended cadence loop reports progress here, not just in a log. The panel
# shows changes/scoped/hunt(s)/mat-err/staged/skipped/ledger (mat-err = materialize_errors, descriptors that
# failed to materialize this tick and spent no hunt budget; a pre-#2154 summary lacks the key -> renders 0).
# CHANGE_SUMMARY defaults to ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/change-watch/tick-summary.json (the pipeline's default).
CHANGE_SUMMARY = ""

PHASES = [
    ("M1 · map zones",        3),
    ("M2 · briefs",           3),
    ("M3 · discovery",       44),
    ("M4 · refute gate",     20),
    ("4.5 · deep-hunt",      22),
    ("4.6 · refute deep-hunt", 8),
    ("deliver · stage",       8),
]
EST_MIN = {"M1 · map zones":4, "M2 · briefs":2, "M3 · discovery":110,
           "M4 · refute gate":60, "4.5 · deep-hunt":75, "4.6 · refute deep-hunt":30, "deliver · stage":10}

# Display label + logical GROUP per phase (internal keys above stay stable — only the rendering renames
# + groups). Two tracks (breadth discovery, depth deep-hunt) each end in a REFUTE gate, then delivery;
# grouping makes clear which refute belongs to which track (#1938 adds the deep-hunt refute).
PHASE_META = {
    "M1 · map zones":   ("Map zones",             "MAP · zones & briefs"),
    "M2 · briefs":      ("Zone briefs",           "MAP · zones & briefs"),
    "M3 · discovery":   ("Discovery hunt",        "BREADTH · discovery track"),
    "M4 · refute gate": ("Refute gate",           "BREADTH · discovery track"),
    "4.5 · deep-hunt":  ("Invariant fuzz",        "DEPTH · deep-hunt track"),
    "4.6 · refute deep-hunt": ("Refute gate",     "DEPTH · deep-hunt track"),
    "deliver · stage":  ("Deliver · human-gate",  "DELIVER"),
}

def read(p):
    try:
        with open(p) as f: return f.read()
    except Exception: return ""

def start_dt():
    m = re.search(r"START \w+ (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", read(LOG))
    if m:
        try: return datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
        except Exception: pass
    try: return datetime.datetime.fromtimestamp(os.path.getmtime(LOG))
    except Exception: return datetime.datetime.now()

def coverage():
    p = os.path.join(OUT, "coverage", "zone-coverage.json")
    try:
        c = json.load(open(p)); zs = c.get("zones", c)
        zs = list(zs.values()) if isinstance(zs, dict) else zs
        if zs: return zs
    except Exception: pass
    # Fallback before discovery writes coverage: surface the mapped zones (M1 output)
    # as "not_reached" so the Zones panel is populated the moment map-zones.sh finishes,
    # instead of sitting empty until the first discovery cell lands.
    try:
        mz = json.load(open(os.path.join(OUT, "map", "zones.json")))
        return [{"id": z.get("id", "?"), "name": z.get("name", ""),
                 "value_custody": z.get("value_custody", False),
                 "status": "not_reached",
                 "classes_hunted": z.get("bug_classes_likely", [])} for z in mz]
    except Exception: return []

def _gate_verdict(slot):
    # #2108(b) / #2298: the RAW automated 4.6 refute-gate verdict for a deep-hunt slot (deep-hunt-gate.sh #1938,
    # default-ON): (REAL|REFUTED|ERROR, reason), or (None, "") when the slot has no gate report. The gate writes ONE
    # verdict row to deep-hunt/<slot>/refute-gate/refute-out/refute-report.md in the format
    # `| <loc> | <class> | REFUTED|REAL|ERROR | <reason> |` — the same row deep-hunt-gate.sh:228-235 scrapes
    # (verdict at cell index 2, reason at 3 after stripping the outer `|`).
    rp = os.path.join(OUT, "deep-hunt", slot, "refute-gate", "refute-out", "refute-report.md")
    for ln in read(rp).splitlines():
        s = ln.strip()
        if not s.startswith("|"): continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if len(cells) < 4: continue
        v = cells[2].upper()
        if v not in ("REAL", "REFUTED", "ERROR"): continue   # header/separator/prose row — skip like the gate's awk
        return v, cells[3]
    return None, ""

def _gate_refute(slot):
    # #2108(b): the automated gate verdict as a FALLBACK behind the manual deep-hunt-adjudicated.tsv overlay. Return a
    # manual-TSV-shaped adj dict ONLY on a REFUTED row, so an auto-refuted finding reclassifies to a triaged FP exactly
    # as a hand-written REFUTED row would; a REAL (survived) or ERROR verdict returns None so the finding stays
    # needs-PoC (NEVER auto-refute a survivor). `source:"gate"` lets the renderer mark machine triage apart from a
    # human one. #2298: a survivor (REAL) also does NOT check phase 4.6 — only an operator verdict does.
    v, reason = _gate_verdict(slot)
    if v == "REFUTED":
        return {"verdict": "REFUTED", "reason": reason, "source": "gate"}
    return None

def deep_hunt():
    # STAGE 4.5 stateful-invariant fuzzing: one invariant-report.md per <zone>-<class> slot.
    # The FUZZER's exit code is the verdict (FINDING = a broken invariant with a shrunk witness = a
    # lead a human triages; CLEAN = held across the fuzzed budget, NOT a proof; HARNESS_ERROR = a gap,
    # not a verdict). Parsed straight from each report's markdown verdict table.
    # severity for a merged FINDING lives in verify/verified_findings.json (source=invariant-hunt),
    # keyed by file — the per-slot invariant-report.md itself carries no severity. Join on it.
    vf = {}
    try:
        data = json.load(open(os.path.join(OUT, "verify", "verified_findings.json")))
        for f in data.get("verified", []):
            if f.get("source") == "invariant-hunt" and f.get("file"):
                vf[f["file"]] = f.get("severity", "")
    except Exception:
        pass
    # manual triage overlay (ROOT/deep-hunt-adjudicated.tsv) — the human refute #1938 will automate. A
    # REFUTED row reclassifies a FINDING as a triaged false positive. Keyed by (file, class) so two
    # different findings on the SAME file (e.g. C6 settle vs SYS-solvency hook) get distinct triage;
    # a 3-column row (file, verdict, reason) applies to ANY class on that file (class "*").
    # #2298: this TSV is ALSO the operator-verdict mechanism phase 4.6 waits on — CONFIRMED / DUPLICATE / REFUTED
    # (`FP` is accepted as an alias of REFUTED). A finding with no such row stays an unchecked 4.6 row, even when the
    # automated gate let it survive (REAL).
    adj = {}
    def _v(raw):
        v = raw.strip().upper()
        return "REFUTED" if v == "FP" else v
    for line in read(os.path.join(ROOT, "deep-hunt-adjudicated.tsv")).splitlines():
        if not line.strip() or line.lstrip().startswith("#"): continue
        c = line.split("\t")
        if len(c) >= 4:
            adj[(c[0].strip(), c[1].strip())] = {"verdict": _v(c[2]), "reason": c[3].strip()}
        elif len(c) >= 2:
            adj[(c[0].strip(), "*")] = {"verdict": _v(c[1]), "reason": c[2].strip() if len(c) > 2 else ""}
    out = []
    for rp in sorted(glob.glob(os.path.join(OUT, "deep-hunt", "*", "invariant-report.md"))):
        slot = os.path.basename(os.path.dirname(rp))
        txt = read(rp)
        target = cls = handler = verdict = ""
        for ln in txt.splitlines():
            s = ln.strip()
            if not s.startswith("|"): continue
            cells = [c.strip() for c in s.strip("|").split("|")]
            if len(cells) < 4: continue
            if cells[0] in ("Target", "") or set(cells[0]) <= set("-: "): continue
            target, cls, handler, verdict = cells[0], cells[1], cells[2], cells[3].upper()
            break
        if not verdict: continue
        # count the shrunk-witness call steps (lines inside the fenced code block that look like `fn(...)`)
        steps = 0; inblk = False
        for ln in txt.splitlines():
            if ln.strip().startswith("```"): inblk = not inblk; continue
            if inblk and re.match(r"\s*[A-Za-z_]\w*\(", ln): steps += 1
        # #2108(b): the manual overlay wins when present (human override > automated gate), matching the
        # precedence note at ~274; only when there is no manual row do we fall back to the automated 4.6
        # refute-gate verdict for this slot (which fills adj only on a REFUTED — a survivor stays needs-PoC).
        manual = adj.get((target, cls)) or adj.get((target, "*"))
        out.append({"slot": slot, "target": target, "cls": cls, "handler": handler,
                    "verdict": verdict, "steps": steps, "severity": vf.get(target, ""),
                    "adj": manual or _gate_refute(slot)})
    return out

def _finding_id(loc, cls=""):
    # #1994: a short, STABLE, human-referenceable id for a lead/finding, derived deterministically from its
    # identity (location + bug class) — so the same finding keeps the same id across refreshes and runs (even
    # as the set changes) and can be cited in conversation / a submission ("what about a3f2b1?"). The CLASS is
    # part of the key so two lenses on the SAME file (a deep-hunt loc is just the file) get distinct ids; class
    # is stable (severity reconciliation #1989 changes sev, never cls). 6 hex ≈ 16.7M space -> collisions are
    # negligible for a hunt's findings. A blank/`?` loc yields "------". sha1 = a stable short digest, not security.
    loc=(loc or "").strip()
    if not loc or loc=="?": return "------"
    return hashlib.sha1((loc+"|"+(cls or "").strip()).encode("utf-8")).hexdigest()[:6]

def leads():
    out = []
    for f in glob.glob(os.path.join(OUT, "discovery", "*", "run", "results-cells.jsonl")):
        zone = os.path.basename(os.path.dirname(os.path.dirname(f)))
        for line in read(f).splitlines():
            line = line.strip()
            if not line: continue
            try: o = json.loads(line)
            except Exception: continue
            for c in (o.get("candidates") or []):
                if isinstance(c, str):
                    p = c.split("|")
                    _title = p[3] if len(p)>3 else ""
                    _claimed = _norm_sev(p[2] if len(p)>2 else "?")
                    # #1989: reconcile the hunter's self-claimed severity against the rules-based tier for the
                    # impact text, so an over-claim (e.g. a Medium griefing bug tagged High) shows — and is
                    # gated for payability — at its true tier, not the inflated claim.
                    _eff, _over = _reconcile_sev(_claimed, _title)
                    out.append({"zone": zone, "loc": p[0] if p else "?",
                                "cls": _norm_cls(p[1] if len(p)>1 else "?"),
                                "sev": _eff, "sev_claimed": _claimed, "overclaim": _over,
                                "title": _title})
    return out

def adjudicated():
    # human-adjudicated leads pulled OUT of the refute queue (ROOT/adjudicated.tsv):
    # loc \t class \t sev \t verdict \t reason
    out = []
    p = os.path.join(ROOT, "adjudicated.tsv")
    for line in read(p).splitlines():
        line = line.rstrip("\n")
        if not line.strip(): continue
        f = line.split("\t")
        out.append({"loc": f[0] if f else "?", "cls": f[1] if len(f)>1 else "",
                    "sev": f[2] if len(f)>2 else "", "verdict": f[3] if len(f)>3 else "",
                    "reason": f[4] if len(f)>4 else ""})
    return out

def verify_state():
    gd = os.path.join(OUT, "verify", "gates")
    if not os.path.isdir(gd): return None
    from collections import Counter
    verds = {}
    for d in glob.glob(os.path.join(gd, "*")):
        v = read(os.path.join(d, "verdict.txt")).split("\t")[0].strip()
        verds[os.path.basename(d)] = v or "?"
    return Counter(v for v in verds.values())

def _normloc(loc):
    # normalize a lead location to the refute-gate dir key: src/pool-bin/libraries/X.sol:fn -> src_pool_bin_libraries_X_sol_fn
    return re.sub(r'[^A-Za-z0-9]+','_',loc).strip('_')

def refute_verdicts():
    # The refute gate (M4) writes verify/gates/<n>_<normloc>/verdict.txt as "<VERDICT>\t<reason>".
    # This is the automated adversary's ruling on each discovery lead — surfaced per-lead so a
    # refuted lead is visibly struck out with its reason, not left looking un-triaged.
    out={}
    for d in glob.glob(os.path.join(OUT,"verify","gates","*")):
        raw=read(os.path.join(d,"verdict.txt")).strip()
        if not raw: continue
        parts=raw.split("\t")
        key=re.sub(r'^\d+_','',os.path.basename(d))
        # #1981: canonicalize the gate's verdict token to the dashboard's survived/refuted vocabulary. The
        # refute gate's contract emits exactly `REAL` (survived a hostile read) or `REFUTED` (killed); the
        # downstream renderers/counters only understand CONFIRMED/REFUTED, so a `REAL` lead was silently
        # falling through to PENDING and showing as un-triaged forever. `REAL` == the dashboard's "survived".
        v=parts[0].strip().upper()
        if v=="REAL": v="CONFIRMED"
        out[key]={"verdict":v,"reason":(parts[1].strip() if len(parts)>1 else "")}
    return out

def _breadth_adjudication(A):
    # #2023: the operator's breadth adjudications (adjudicated.tsv), keyed exactly like the dashboard's
    # #2005/#2007 sets — (normloc, norm_cls). CONFIRMED = a real, non-duplicate bug; DUPLICATE = a real
    # bug already reported ($0). Both are authoritative HUMAN rulings on a location.
    confirmed = {(_normloc(a["loc"]), _norm_cls(a.get("cls","")))
                 for a in A if a.get("verdict","").strip().upper() == "CONFIRMED"}
    dup = {(_normloc(a["loc"]), _norm_cls(a.get("cls",""))): a.get("reason","")
           for a in A if a.get("verdict","").strip().upper() == "DUPLICATE"}
    return confirmed, dup

def _lead_state(x, RV, confirmed_set, dup_map):
    # #2023: the SINGLE breadth verdict-selection classifier, shared by BOTH the renderer (page()) and the
    # assertion surface (emit_model()) so the two can never disagree again. An operator adjudication is
    # authoritative and is applied FIRST; the automated refute-gate verdict (RV) only decides a lead the
    # operator has NOT adjudicated. This is exactly the drift that caused #2023: the render path honoured
    # operator precedence (since #2005/#2007) but the model path tested the gate's REFUTED first, silently
    # downgrading an operator-CONFIRMED finding. Returns: op_confirmed | op_duplicate | refuted | survived | pending.
    key = (_normloc(x["loc"]), x["cls"])
    if key in confirmed_set: return "op_confirmed"
    if key in dup_map:       return "op_duplicate"
    v = (RV.get(_normloc(x["loc"])) or {}).get("verdict","")
    if v == "REFUTED":   return "refuted"
    if v == "CONFIRMED": return "survived"
    return "pending"

# #2024: precedence for folding raw breadth candidates that land at the SAME normalized location — a
# --rehunt-gaps re-find or a second lens pass re-flagging the identical seam. Most-actionable state wins;
# a location is "refuted" only when EVERY copy at that location was refuted (min-precedence selection below).
_GROUP_STATE_PREC = {"op_confirmed": 0, "op_duplicate": 1, "survived": 2, "pending": 3, "refuted": 4}

def _group_leads(L, RV, confirmed_set, dup_map):
    # #2024: fold raw discovery candidates by EXACT normalized location (_normloc) ONLY — no class in the key,
    # so a re-find/second-lens hit at the identical file:fn folds even across classes, and a location a copy of
    # which is operator-CONFIRMED never still shows "needs PoC" on its siblings. Deliberately NOT fuzzy — two
    # candidates at genuinely different locations never collapse (cf. #861/#1894 FUNNEL, out of scope here).
    # Reuses the SAME _lead_state() classifier the ungrouped path used, so render/emit_model can't drift again.
    groups = {}
    order = []
    for x in L:
        s = _lead_state(x, RV, confirmed_set, dup_map)
        key = _normloc(x["loc"])
        g = groups.get(key)
        if g is None:
            g = {"loc": x["loc"], "zone": x["zone"], "cls": x["cls"], "clss": [x["cls"]],
                 "sev": x["sev"], "sev_claimed": x.get("sev_claimed", x["sev"]),
                 "overclaim": bool(x.get("overclaim")), "title": x["title"],
                 "state": s, "n_folded": 1, "_win_cls": x["cls"]}
            groups[key] = g
            order.append(key)
        else:
            g["n_folded"] += 1
            if x["cls"] not in g["clss"]: g["clss"].append(x["cls"])
            if _GROUP_STATE_PREC[s] < _GROUP_STATE_PREC[g["state"]]:
                # a more-actionable copy wins: its sev/title/class become the group's representative facts
                g["state"] = s; g["sev"] = x["sev"]; g["sev_claimed"] = x.get("sev_claimed", x["sev"])
                g["overclaim"] = bool(x.get("overclaim")); g["title"] = x["title"]; g["_win_cls"] = x["cls"]
    out = []
    for key in order:
        g = groups[key]
        g["cls"] = "+".join(g["clss"]) if len(g["clss"]) > 1 else g["clss"][0]
        out.append(g)
    return out

# #2003: subdirs that hold a CLONED TARGET REPO or build artifacts — never a liveness heartbeat. A deep-hunt
# cell clones the whole target repo (+ forge lib/out/cache) under run/repo/, so a single cell's run/ tree can
# hold ~6k files and a full re-hunt ~120k. The freshness walks below only need the newest LLM-log / .agentis
# heartbeat, so pruning these keeps a render O(hundreds) instead of O(100k) (a 19s render dropped to <1s).
_WALK_SKIP = {"repo", "out", "cache", "lib", "node_modules", ".git", "target", "artifacts", "broadcast"}
def _prune(dirs):
    # in-place prune for os.walk (top-down) so it never descends into the heavy target/build trees
    dirs[:] = [d for d in dirs if d not in _WALK_SKIP]

def active_deep_slot():
    # The ONE deep-hunt slot being (re-)hunted RIGHT NOW: the slot whose run/ dir has the freshest write
    # (< 90s) while a hunt process / LLM child is alive. A re-run (--deep-hunt-resume) regenerates a slot
    # IN PLACE and only rewrites its invariant-report.md at the END — so without this, a re-executing slot
    # keeps showing its STALE prior verdict (e.g. "harness error") instead of "in progress".
    if not (proc_alive() or llm_child()[0]): return None
    best=None; bestm=0.0
    for d in glob.glob(os.path.join(OUT,"deep-hunt","*")):
        rd=os.path.join(d,"run")
        if not os.path.isdir(rd): continue
        for root,dirs,files in os.walk(rd):
            _prune(dirs)
            for fn in files:
                try:
                    mm=os.path.getmtime(os.path.join(root,fn))
                    if mm>bestm: bestm=mm; best=os.path.basename(d)
                except OSError: pass
    if best is None: return None
    return best if (datetime.datetime.now().timestamp()-bestm) < 90 else None

def active_deep_refute_slot():
    # #2025: active_deep_slot() only walks deep-hunt/<slot>/run/ — the FUZZER's heartbeat tree. The automated
    # invariant-mode refute gate (deep-hunt-gate.sh, #1938, default-ON) is a separate, synchronous step run
    # inline by run-zone-hunt.sh right after a fuzz FINDING; it writes to a SIBLING subtree,
    # deep-hunt/<slot>/refute-gate/{gate.log,candidate.manifest,refute-out/*}, which active_deep_slot() never
    # sees. Without this, an idle un-triaged refute backlog reads "run" merely because the fuzzer is mid-cell
    # on a DIFFERENT slot (deep_live true) — this probe is the narrow signal scoped to refute-gate/ itself, same
    # <90s-fresh-write + proc-alive liveness gate as active_deep_slot().
    if not (proc_alive() or llm_child()[0]): return None
    best=None; bestm=0.0
    for d in glob.glob(os.path.join(OUT,"deep-hunt","*")):
        rd=os.path.join(d,"refute-gate")
        if not os.path.isdir(rd): continue
        for root,dirs,files in os.walk(rd):
            _prune(dirs)
            for fn in files:
                try:
                    mm=os.path.getmtime(os.path.join(root,fn))
                    if mm>bestm: bestm=mm; best=os.path.basename(d)
                except OSError: pass
    if best is None: return None
    return best if (datetime.datetime.now().timestamp()-bestm) < 90 else None

DEEP_CELL_STALE_S = 600   # a deep-hunt cell dir silent this long is abandoned, not running (see below)
def deep_cell_status(slot):
    # State of a NON-completed deep-hunt cell from its on-disk dir. A cell that is genuinely fuzzing writes
    # into its own deep-hunt/<slot>/ tree constantly (the LLM sub-log appends a `still waiting (Xs)` heartbeat
    # every ~4s — the same pulse active_deep_slot()/freshest() rely on), so a live cell is NEVER silent for
    # even 90s. A cell whose process was killed or whose flat-cyborg session hung leaves its dir on disk but
    # goes silent. So: no dir -> "queued"; dir with a fresh write -> "running"; dir silent past the stale
    # bound (or empty) -> "abandoned" (a coverage GAP == harness_error, NOT a perpetual "running"). Without
    # this, a force-advanced / crashed cell shows "🔄 fuzzing…" forever because os.path.isdir() alone is true.
    cell = os.path.join(OUT, "deep-hunt", slot)
    if not os.path.isdir(cell): return "queued"
    newest = 0.0
    for root, dirs, files in os.walk(cell):
        _prune(dirs)
        for fn in files:
            try:
                mm = os.path.getmtime(os.path.join(root, fn))
                if mm > newest: newest = mm
            except OSError: pass
    if newest == 0.0: return "abandoned"
    return "running" if (datetime.datetime.now().timestamp() - newest) < DEEP_CELL_STALE_S else "abandoned"

def freshest():
    # The newest write across ALL hunt artifacts = the liveness pulse. The LLM sub-logs
    # append a `still waiting ... (Xs)` heartbeat every ~4s while a call is in flight, so a
    # fresh mtime here PROVES the pipeline is doing work even when the top-level log is quiet.
    best=0.0; bestp=None
    try: best,bestp=os.path.getmtime(LOG),LOG
    except OSError: pass
    # os.walk (NOT glob '**'): the gen-briefs / .agentis heartbeats live under HIDDEN dirs
    # (.gen-briefs/run/, .agentis/) that glob '**' silently skips — which made M2 look stalled
    # while briefs were actively being written. walk descends into dot-dirs, so the pulse is real.
    for root,dirs,files in os.walk(OUT):
        _prune(dirs)
        for fn in files:
            if fn.endswith((".log",".json",".jsonl")):
                try:
                    m=os.path.getmtime(os.path.join(root,fn))
                    if m>best: best,bestp=m,os.path.join(root,fn)
                except OSError: pass
    return best,bestp

def _is_wrapper(cl):
    # A shell/grep/monitor cmdline that merely MENTIONS the hunt strings (our own `bash -c` diagnostics,
    # Monitor `tail | grep run-zone-hunt.sh:` commands, pgrep) — NOT an actual hunt/LLM process. Without
    # this the liveness dot falsely pulses green because a diagnostic that contains "run-zone-hunt.sh"
    # is counted as a live hunt.
    return (" -c " in cl) or ("grep" in cl) or ("pgrep" in cl) or ("tail " in cl) or ("/cmdline" in cl)

def _fake_env(name):
    # test-only override of the /proc scan (fixtures cannot spawn a real hunt): unset => real scan. In the M2
    # overview a per-hunt suffix (`<NAME>_<ID>`) is honoured FIRST so one fixture registry can carry a finished
    # card and a live card in the same render; the un-suffixed var stays the M1 single-hunt seam.
    if CUR_HUNT_ID:
        v = os.environ.get(name + "_" + re.sub(r'[^A-Za-z0-9]+', '_', CUR_HUNT_ID).upper())
        if v is not None: return v
    return os.environ.get(name)

def _proc_glob():
    # guard the /proc scan so a non-Linux host degrades to freshness-only instead of crashing on the
    # missing /proc filesystem.
    if not os.path.isdir("/proc"): return []
    return glob.glob("/proc/[0-9]*/cmdline")

def proc_alive():
    # Is THIS hunt's process still up? (pure /proc scan — no subprocess). Distinguishes "working" from
    # "crashed": process gone + no __EXIT__ marker = it died, not finished. Scoped to this hunt by
    # matching a run-zone-hunt.sh cmdline that carries this descriptor's --repo/--out, so M2's per-hunt
    # liveness never cross-counts a sibling hunt.
    fake = _fake_env("HUNT_DASHBOARD_FAKE_PROC_ALIVE")
    if fake is not None: return fake not in ("", "0", "false", "no")
    me=str(os.getpid())
    for c in _proc_glob():
        pid=c.split("/")[2]
        if pid==me: continue
        try: cl=open(c,"rb").read().replace(b"\x00",b" ").decode("utf-8","replace")
        except OSError: continue
        if "run-zone-hunt.sh" not in cl or _is_wrapper(cl): continue
        if ("--repo %s"%ROOT in cl) or ("--out %s"%OUT in cl) or (ROOT and ROOT in cl): return True
    return False

def llm_child():
    # Is an LLM call actively in flight? During a long opus generation flat-cyborg BUFFERS its output,
    # so heartbeats flush in a batch only at "received" and file mtimes go QUIET for minutes even though
    # the model is thinking. A running `agentis go` / `flat-cyborg --tui` child is the truthful
    # "not frozen" signal — without it the file-mtime heuristic falsely screams "stalled" mid-generation.
    # Returns (in_flight, elapsed_seconds) — elapsed = runtime of the youngest such child = current call.
    fake = _fake_env("HUNT_DASHBOARD_FAKE_LLM_INFLIGHT")
    if fake is not None:
        if fake in ("", "0", "false", "no"): return (False, None)
        # "1" -> in flight, no think time; "1:156" / "156" -> in flight, think = 156s
        m = re.search(r"(\d+)\s*$", fake)
        think = int(m.group(1)) if (m and fake not in ("1", "true", "yes")) else None
        return (True, think)
    try: clk=os.sysconf('SC_CLK_TCK')
    except Exception: clk=100
    try: uptime=float(open('/proc/uptime').read().split()[0])
    except Exception: uptime=None
    # #2026: unlike proc_alive() (scoped by --repo/--out substrings on the run-zone-hunt.sh
    # cmdline itself), every stage script spawns its "agentis go"/"flat-cyborg --tui" child
    # via `cd "$RUN_OR_CELL_DIR" && ... agentis go ...` — the CHILD's own argv never carries
    # --repo/--out, so there is no descriptor substring to match here. What IS invariant is
    # that $RUN_OR_CELL_DIR is always a subdirectory of this hunt's own $OUT tree, i.e. the
    # child's CWD is filesystem-scoped even though its argv isn't. So we scope by CWD
    # containment under OUT instead — this is what keeps a concurrent/sibling hunt on the
    # same host from tripping THIS hunt's liveness (unscoped before this fix).
    out_root = os.path.realpath(OUT) if OUT else None
    best=None; found=False
    for c in _proc_glob():
        try: cl=open(c,"rb").read().replace(b"\x00",b" ").decode("utf-8","replace")
        except OSError: continue
        if _is_wrapper(cl): continue
        if ("agentis go " in cl) or ("flat-cyborg" in cl and "--tui" in cl):
            pid=c.split("/")[2]
            if out_root:
                try: cwd=os.path.realpath(os.readlink("/proc/%s/cwd"%pid))
                except OSError: continue  # gone/unreadable -> not verifiably ours, don't count it
                if cwd != out_root and not cwd.startswith(out_root+os.sep): continue
            found=True
            if uptime is None: continue
            try:
                stat=open("/proc/%s/stat"%pid,"rb").read().decode("utf-8","replace")
                starttime=float(stat.rsplit(")",1)[1].split()[19])  # field 22 (0-indexed 19 after comm ')')
                el=uptime-starttime/clk
                if best is None or el<best: best=el
            except Exception: continue
    return (found, int(best) if best is not None else None)

def sublog_activity():
    # The newest per-stage sub-log tells us WHAT is happening right now and, if an LLM call is
    # in flight, HOW LONG it has been thinking — the concrete "it's not frozen" evidence.
    logs=[]
    for root,dirs,files in os.walk(OUT):   # walk sees hidden .gen-briefs/run/ that glob '**' skips
        _prune(dirs)
        if os.path.basename(root)=="run":
            logs+=[os.path.join(root,fn) for fn in files if fn.endswith(".log")]
    if not logs: return None
    try: newest=max(logs,key=lambda p:os.path.getmtime(p))
    except ValueError: return None
    lines=[l.strip() for l in read(newest).splitlines() if l.strip()]
    last=lines[-1] if lines else ""
    m=re.search(r"still waiting \.\.\. \(([\d.]+)s\)",last)
    waited=float(m.group(1)) if m else None
    stalled=bool(re.search(r"timed out|LLM retry",last))
    parts=os.path.relpath(newest,OUT).split(os.sep)
    kind,zone="working",""
    if "discovery" in parts:
        kind="discovery"; i=parts.index("discovery"); zone=parts[i+1] if len(parts)>i+1 else ""
    elif "deep-hunt" in parts:
        kind="deep-hunt"; i=parts.index("deep-hunt"); zone=parts[i+1] if len(parts)>i+1 else ""
    elif "verify" in parts:
        kind="refute gate"
    elif "gen-briefs" in "\n".join(parts) or "briefs" in parts:
        kind="briefing"; mm=re.search(r"brief_(.+)\.log",os.path.basename(newest)); zone=mm.group(1) if mm else ""
    elif "map" in parts:
        kind="mapping"
    return {"kind":kind,"zone":zone,"waited":waited,"stalled":stalled}

# ---- #2298: ONE completeness model -------------------------------------------------------------------------
# Every %, ✅, DONE, "finished" and "verdict in chat" on the page, in --emit-model and on the overview card is derived
# from hunt_model(): one ROW SET per phase, built from the SAME row objects the Phases / Zones / LEADS tables render.
# A row is CHECKED only when its rendered state is terminal; a phase is `done` only when it has started, every row is
# checked and its upstream phase is done; the header claims DONE / 100 % / "finished — verdict in chat" only when the
# runner exited AND every phase is `done` or `skip`. Anything else is clamped to <= 99 % (rendered with int(), so a
# 99.6 can never print as 100). The STAGE 4.5 row matrix comes from the runner's <out>/deep-hunt/plan.json — the
# dashboard never re-derives the selection (planned_deep_rows(), the drifting client-side copy, is gone).
DEEP_PLAN_SCHEMA = "deep-hunt-plan/v1"
# phase -> upstream phases that must be `done` (or `skip`) before it may be `done`
PHASE_UPSTREAM = {
    "M1 · map zones": (),
    "M2 · briefs": ("M1 · map zones",),
    "M3 · discovery": ("M2 · briefs",),
    "M4 · refute gate": ("M3 · discovery",),
    "4.5 · deep-hunt": ("M1 · map zones",),        # the plan is complete at stage start
    "4.6 · refute deep-hunt": ("4.5 · deep-hunt",),
    "deliver · stage": ("M4 · refute gate", "4.6 · refute deep-hunt"),
}
# 4.6 is checked only on an OPERATOR verdict (or an automated gate REFUTED). A finding that SURVIVED the automated gate
# (REAL) stays unchecked until the operator records CONFIRMED / DUPLICATE / FP (= REFUTED) in deep-hunt-adjudicated.tsv.
DEEP_VERDICTS_CHECKED = ("REFUTED", "CONFIRMED", "DUPLICATE")
DEEP_CHECKED_STATES = ("finding", "triaged_fp", "clean")   # a terminal fuzzer verdict (4.5)

def deep_plan():
    # The runner's STAGE 4.5 plan (<out>/deep-hunt/plan.json), schema-checked. Anything else (absent, torn, unknown
    # schema) is None, which the callers treat as "plan unknown" — never as complete.
    try:
        with open(os.path.join(OUT, "deep-hunt", "plan.json")) as f: d = json.load(f)
    except Exception:
        return None
    if not isinstance(d, dict) or d.get("schema") != DEEP_PLAN_SCHEMA or not isinstance(d.get("rows"), list):
        return None
    if d.get("status") not in ("planned", "skipped"):
        return None
    return d

def _deep_mode(log, plan):
    # planned | skipped -> the runner wrote a plan (rows known); legacy -> deep-hunt evidence (a plan.json that does not
    # parse, a deep-hunt/ dir or a [deep-hunt]/STAGE 4.5 marker) but no valid plan: the row set cannot be proven;
    # off -> the runner reached M5 (.verified-findings.tsv) with no deep-hunt evidence at all (run without
    # --deep-hunt); pending -> none of the above yet (still in breadth).
    if plan is not None:
        return "skipped" if plan.get("status") == "skipped" else "planned"
    dh = os.path.join(OUT, "deep-hunt")
    if os.path.isdir(dh) or re.search(r"STAGE 4\.5|\[deep-hunt\]", log):
        return "legacy"
    if os.path.isfile(os.path.join(OUT, ".verified-findings.tsv")):
        return "off"
    return "pending"

def deep_hunt_state():
    # STAGE 4.5 state for the panel + overview card, derived from _deep_mode() (issue comment 5308547720 states kept):
    #   not_reached -> still in breadth; reached_no_lenses -> a plan with 0 rows (no lens routed); ran -> a plan with
    #   rows; skipped -> no runnable Foundry root; off -> run without --deep-hunt; legacy -> no plan, rows unprovable.
    plan = deep_plan()
    mode = _deep_mode(read(LOG), plan)
    if mode == "pending": return "not_reached"
    if mode == "planned": return "ran" if plan.get("rows") else "reached_no_lenses"
    return mode

def _zones_json():
    try:
        zs = json.load(open(os.path.join(OUT, "map", "zones.json")))
        return zs if isinstance(zs, list) else None
    except Exception:
        return None

def _deep_stage_over(exited, log, plan_mtime):
    # STAGE 4.5 is over (a selected row with no dir is `not_run`, not `queued`) once the runner exited, or the log has
    # a `[deep-hunt] merged ` line AFTER the latest plan line, or M5's .verified-findings.tsv is newer than the plan.
    if exited: return True
    i = log.rfind("[deep-hunt] merged ")
    if i >= 0 and i > log.rfind("[deep-hunt] plan: "): return True
    try:
        return plan_mtime is not None and os.path.getmtime(os.path.join(OUT, ".verified-findings.tsv")) > plan_mtime
    except OSError:
        return False

def _deep_row_state(r, completed, active, stage_over):
    # The ONE DEPTH-row classifier: (state, raw verdict token). Precedence: re-running slot > report verdict > on-disk
    # cell (running / abandoned) > plan state (capped / queued while STAGE 4.5 runs / not_run after it).
    p = r["plan"]
    if p == "deep_skipped": return "deep_skipped", "SKIPPED"
    if p == "plan_unknown": return "plan_unknown", ""
    slot = r["slot"]
    if active and slot == active: return "rerunning", ""
    d = completed.get(slot)
    if d:
        v = d["verdict"]; adj = d.get("adj") or {}
        if "FINDING" in v or "VIOLAT" in v:
            return ("triaged_fp" if adj.get("verdict") == "REFUTED" else "finding"), v
        if "CLEAN" in v: return "clean", v
        return "harness_error", v   # HARNESS_ERROR / TRANSIENT_ERROR / LOW_COVERAGE / LOW_PROMISE_COVERAGE: raw token kept
    if os.path.isdir(os.path.join(OUT, "deep-hunt", slot)):
        return ("running", "") if deep_cell_status(slot) == "running" else ("harness_error", "ABANDONED")
    if p == "capped": return "capped", ""
    return ("not_run" if stage_over else "queued"), ""

def deep_rows(mode, plan, DH, active, stage_over):
    # The DEPTH row set, in order: (1) plan rows (deduped by slot); (2) observed deep-hunt/*/ dirs the plan does not
    # name (a stale or foreign cell — shown, never hidden); (3) ONE synthetic row for a skipped deep-hunt or a legacy
    # out dir without a plan. Custody comes from the plan row; for an unplanned dir from the longest zones.json id that
    # prefixes the slot (display only).
    completed = {d["slot"]: d for d in DH}
    zj = _zones_json() or []
    zcust = {z.get("id", ""): bool(z.get("value_custody")) for z in zj if isinstance(z, dict)}
    zids = sorted((i for i in zcust if i), key=len, reverse=True)
    rows = []; seen = set()
    for pr in ((plan or {}).get("rows") or []):
        if not isinstance(pr, dict): continue
        slot = str(pr.get("slot") or "")
        if not slot or slot in seen: continue
        seen.add(slot)
        rows.append({"slot": slot, "zone": str(pr.get("zone") or ""), "cls": str(pr.get("class") or "?"),
                     "target": str(pr.get("target") or ""), "custody": bool(pr.get("custody")),
                     "plan": "capped" if pr.get("state") == "capped" else "selected",
                     "cap": str(pr.get("cap") or "")})
    dirs = sorted(os.path.basename(x) for x in glob.glob(os.path.join(OUT, "deep-hunt", "*")) if os.path.isdir(x))
    for slot in dirs + sorted(completed):
        if slot in seen: continue
        seen.add(slot)
        zone = next((z for z in zids if slot.startswith(z + "-")), "")
        d = completed.get(slot)
        rows.append({"slot": slot, "zone": zone, "cls": (d["cls"] if d else (slot[len(zone) + 1:] if zone else "?")),
                     "target": (d["target"] if d else ""), "custody": zcust.get(zone, False), "plan": "unplanned",
                     "cap": ""})
    if mode == "skipped":
        rows.append({"slot": "deep-hunt", "zone": "", "cls": "—", "target": "", "custody": False,
                     "plan": "deep_skipped", "cap": "", "reason": str((plan or {}).get("reason") or "")})
    elif mode == "legacy":
        rows.append({"slot": "deep-hunt plan", "zone": "", "cls": "—", "target": "", "custody": False,
                     "plan": "plan_unknown", "cap": ""})
    for r in rows:
        r["state"], r["verdict"] = _deep_row_state(r, completed, active, stage_over)
        d = completed.get(r["slot"])
        r["adj"] = (d.get("adj") if d else None) or {}
        r["steps"] = d["steps"] if d else 0
        r["sev_join"] = d.get("severity", "") if d else ""
        if d: r["cls"] = d["cls"] or r["cls"]; r["target"] = d["target"] or r["target"]
        r["gate"] = _gate_verdict(r["slot"])[0] if r["state"] == "finding" else None
        r["checked_45"] = r["state"] in DEEP_CHECKED_STATES
        r["needs_46"] = r["state"] in ("finding", "triaged_fp")
        r["checked_46"] = r["needs_46"] and (r["adj"].get("verdict") in DEEP_VERDICTS_CHECKED)
        r["checked"] = r["checked_45"] and (r["checked_46"] if r["needs_46"] else True)
    return rows

def _slug(loc):
    # run-zone-hunt.sh's M5 finding slug: `tr -cs 'A-Za-z0-9' '-' | sed 's/-*$//; s/^-*//'`.
    return re.sub(r"[^A-Za-z0-9]+", "-", loc or "").strip("-")

def deliver_rows():
    # One row per .verified-findings.tsv finding; checked only on a `staged` / `halted` row of the runner's
    # audit-pass/deliver-status.tsv (matched by slug, in order). No .verified-findings.tsv yet -> one synthetic open row.
    vf = os.path.join(OUT, ".verified-findings.tsv")
    if not os.path.isfile(vf):
        return [{"label": "deliver ledger (.verified-findings.tsv) not written yet", "checked": False}]
    status = {}
    for ln in read(os.path.join(OUT, "audit-pass", "deliver-status.tsv")).splitlines():
        c = ln.split("\t")
        if len(c) >= 2 and c[0].strip(): status.setdefault(c[0].strip(), []).append(c[1].strip())
    rows = []; n = 0
    for ln in read(vf).splitlines():
        loc = ln.split("\t")[0]
        if not loc: continue
        n += 1
        slug = _slug(loc) or ("finding-%d" % n)
        q = status.get(slug) or []
        st = q.pop(0) if q else ""
        rows.append({"label": "deliver %s (%s)" % (slug, st or "no deliver status"), "checked": st in ("staged", "halted")})
    return rows

def _phase_state(rows, upstream_done, started, live, skip, exited):
    # precedence: skip > wait > done > run > gap. A live hunt still waiting on an unfinished upstream phase reads
    # `wait`, not `gap` (it has nothing to do yet); after exit every started-but-open phase is a `gap`.
    if skip: return "skip"
    if not started: return "wait"
    if upstream_done and all(r["checked"] for r in rows): return "done"
    if live: return "run"
    if not upstream_done and not exited: return "wait"
    return "gap"

def hunt_model():
    # Computed ONCE per render; page(), emit_model() and hunt_card() all read it.
    log = read(LOG); zs = coverage(); L = leads(); vs = verify_state(); A = adjudicated()
    total_z = len(zs) or 4
    # #1999: "exited" = the __EXIT__ marker AND no live hunt process (a --deep-hunt-resume re-run appends after a
    # stale marker).
    hunt_live = proc_alive() or llm_child()[0]
    exited = ("__EXIT__=" in log) and not hunt_live
    covered = sum(1 for z in zs if z.get("status") in ("hunted", "hunted_empty"))
    failed = sum(1 for z in zs if z.get("status") == "failed")
    RV = refute_verdicts()
    _confirmed_breadth, _dup_breadth = _breadth_adjudication(A)
    G = _group_leads(L, RV, _confirmed_breadth, _dup_breadth)
    plan = deep_plan()
    mode = _deep_mode(log, plan)
    try: plan_mtime = os.path.getmtime(os.path.join(OUT, "deep-hunt", "plan.json")) if plan is not None else None
    except OSError: plan_mtime = None
    DH = deep_hunt()
    active = active_deep_slot()
    DR = deep_rows(mode, plan, DH, active, _deep_stage_over(exited, log, plan_mtime))
    _act = sublog_activity()
    zj = _zones_json()
    cov_status = {z.get("id", "?"): z.get("status", "") for z in zs}
    discovery_touched = any(z.get("status") != "not_reached" for z in zs)
    rows = {}
    # M1 — one row: map/zones.json parses as a non-empty list (or, #2193, discovery has already moved a zone on).
    rows["M1 · map zones"] = [{"label": "map/zones.json", "checked": bool(zj) or discovery_touched}]
    # M2 — one row per mapped zone: its brief exists, or (#2193 relocated sink) discovery already reached the zone.
    bdir = os.path.join(OUT, "briefs", "briefs")
    zone_ids = [z.get("id", "?") for z in zj if isinstance(z, dict)] if zj else [z.get("id", "?") for z in zs]
    rows["M2 · briefs"] = [{"label": "brief %s" % i,
                            "checked": os.path.isfile(os.path.join(bdir, "brief_%s.md" % i))
                                       or cov_status.get(i, "") not in ("", "not_reached", "no_brief", "unscoped")}
                           for i in zone_ids]
    # M3 — the Zones table rows: only hunted / hunted_empty is a verdict (failed / degraded / in_flight are open).
    rows["M3 · discovery"] = [{"label": "zone %s (%s)" % (z.get("id", "?"), z.get("status", "?")),
                               "checked": z.get("status") in ("hunted", "hunted_empty"), "zone": z.get("id", "?")}
                              for z in zs]
    # M4 — every grouped breadth lead (hidden sub-floor rows included): checked once it is no longer pending.
    rows["M4 · refute gate"] = [{"label": "lead %s %s (pending refute)" % (_finding_id(g["loc"], g["cls"]), g["loc"]),
                                 "checked": g["state"] != "pending", "zone": g["zone"]} for g in G]
    # 4.5 / 4.6 — the DEPTH rows (plan ∪ observed ∪ synthetic) and the subset carrying a FINDING.
    rows["4.5 · deep-hunt"] = [{"label": "%s (%s)" % (r["slot"], r["state"] if r["state"] != "harness_error"
                                                       else (r["verdict"] or "harness error").lower()),
                                "checked": r["checked_45"], "zone": r["zone"]} for r in DR]
    rows["4.6 · refute deep-hunt"] = [{"label": "%s (awaiting operator verdict)" % r["slot"],
                                       "checked": r["checked_46"], "zone": r["zone"]} for r in DR if r["needs_46"]]
    skip_deliver = bool(plan and plan.get("deep_hunt_only"))
    rows["deliver · stage"] = [] if skip_deliver else deliver_rows()
    # started / live / skip per phase (the #2001/#2020/#2025/#2193/#2200/#2205 liveness signals choose run vs gap only)
    briefs_populated = bool(glob.glob(os.path.join(bdir, "*.md")))
    _mapping_live = (_act is not None and _act.get("kind") == "mapping")
    _briefing_live = (_act is not None and _act.get("kind") == "briefing")
    _disc_started = ("[M3]" in log) or discovery_touched or (_act is not None and _act.get("kind") == "discovery")
    _disc_live = any(z.get("status") == "in_flight" for z in zs) or (_act is not None and _act.get("kind") == "discovery")
    deep_started = mode in ("planned", "skipped", "legacy") or (active is not None)
    deliver_started = os.path.isfile(os.path.join(OUT, ".verified-findings.tsv")) \
        or bool(re.search(r"deliver-submission|PENDING-HUMAN-REVIEW", log))
    m4_started = ("[M4]" in log) or vs is not None or deep_started or deliver_started \
        or os.path.isfile(os.path.join(OUT, "verify", "verified_findings.json"))
    started = {
        "M1 · map zones": ("[M1]" in log) or _mapping_live or zj is not None or discovery_touched or _disc_started,
        "M2 · briefs": ("[M2]" in log) or _briefing_live or briefs_populated or discovery_touched or _disc_started,
        "M3 · discovery": _disc_started,
        "M4 · refute gate": m4_started,
        "4.5 · deep-hunt": deep_started,
        "4.6 · refute deep-hunt": deep_started,
        "deliver · stage": deliver_started,
    }
    live = {
        "M1 · map zones": _mapping_live and not exited,
        "M2 · briefs": _briefing_live and not exited,
        "M3 · discovery": _disc_live and not exited,
        "M4 · refute gate": (not exited) and hunt_live and (("[M4]" in log) or vs is not None)
                            and not _disc_live and not deep_started and not deliver_started,
        "4.5 · deep-hunt": active is not None,
        "4.6 · refute deep-hunt": active_deep_refute_slot() is not None,
        "deliver · stage": (not exited) and hunt_live and deliver_started,
    }
    skip = {name: False for name, _ in PHASES}
    if mode == "off":
        skip["4.5 · deep-hunt"] = skip["4.6 · refute deep-hunt"] = True
    skip["deliver · stage"] = skip_deliver
    st = {}
    for name, _w in PHASES:
        up_done = all(st.get(u) in ("done", "skip") for u in PHASE_UPSTREAM[name])
        st[name] = _phase_state(rows[name], up_done, started[name], live[name], skip[name], exited)
    complete = exited and all(s in ("done", "skip") for s in st.values())
    # progress: phase-weighted checked fraction over the non-skip phases; clamped to <= 99 unless complete.
    num = den = 0.0
    for name, w in PHASES:
        if st[name] == "skip": continue
        den += w
        rs = rows[name]
        if st[name] == "done": num += w
        elif rs and started[name]: num += w * (sum(1 for r in rs if r["checked"]) / float(len(rs)))
    raw = 100.0 * num / den if den else 0.0
    prog = 100.0 if complete else min(99.0, round(raw, 1))
    phase_rows = {name: {"total": len(rows[name]), "checked": sum(1 for r in rows[name] if r["checked"]),
                         "unchecked": [r["label"] for r in rows[name] if not r["checked"]]} for name, _ in PHASES}
    n_open = sum(len(v["unchecked"]) for k, v in phase_rows.items() if st[k] != "skip")
    return {"st": st, "prog": prog, "covered": covered, "failed": failed, "total_z": total_z, "exited": exited,
            "complete": complete, "hunt_live": hunt_live, "phase_rows": phase_rows, "rows": rows, "deep_rows": DR,
            "deep_mode": mode, "plan": plan, "G": G, "L": L, "A": A, "RV": RV, "vs": vs, "zs": zs, "log": log,
            "DH": DH, "active": active, "n_open": n_open, "act": _act,
            "dup_breadth": _dup_breadth}

def zone_open_rows(M, zid):
    # the zone's unchecked rows across M3, M4, 4.5 and 4.6 — a zone reads ✅ only when this is 0.
    n = 0
    for name in ("M3 · discovery", "M4 · refute gate", "4.5 · deep-hunt", "4.6 · refute deep-hunt"):
        if M["st"].get(name) == "skip": continue
        n += sum(1 for r in M["rows"][name] if r.get("zone") == zid and not r["checked"])
    return n

def hms(td):
    s=int(td.total_seconds()); return f"{s//3600}h {s%3600//60:02d}m"

ICON={"done":"✅","run":"🔄","wait":"⬜","gap":"⚠️","skip":"➖"}
SEVCOL={"High":"#ff5c5c","Critical":"#ff2d2d","Medium":"#ffb020","Low":"#8fb8ff"}
def _norm_sev(raw):
    # Normalize an LLM-emitted severity value (#1974/#1976): remove ALL whitespace FIRST so a corruption
    # inside the prefix word ("se verity=") is handled the same as one in the value ("H igh"), then strip
    # the now-compact "severity=" prefix and canonicalize against the 4-tier set. An unrecognized value is
    # returned whitespace-collapsed but otherwise unchanged — never invent a tier.
    compact = re.sub(r'(?i)^severity=', '', re.sub(r'\s+', '', raw or ''))
    for tier in ("Critical", "High", "Medium", "Low"):
        if compact.lower() == tier.lower(): return tier
    s = re.sub(r'(?i)^\s*severity\s*=\s*', '', raw or '')
    return re.sub(r'\s+', ' ', s).strip()
def _norm_cls(raw):
    # Normalize an LLM-emitted class value (#1974/#1976/#2196): remove ALL whitespace FIRST (handles "c lass="
    # and "C 22"), drop surrounding angle brackets (some discovery candidates emit "<class=C6>" rather than
    # the compact "class=C6"), strip the now-compact "class=" prefix, uppercase. No membership validation —
    # class codes are open-ended (C1..C23, SYS-solvency, C-invariant).
    s = re.sub(r'\s+', '', raw or '').strip('<>')
    return re.sub(r'(?i)^class=', '', s).upper()
# Pay-floor marker (#1960): a display-only "$0" badge on any lead whose intrinsic severity ranks BELOW the
# program's --pay-floor (threaded in as the descriptor's `pay_floor`). The delivery-time payability gate remains
# the sole authority that actually drops sub-floor findings; this only annotates the dashboard.
SEV_RANK={"low":0,"medium":1,"high":2,"critical":3}
def _pay_floor_rank():
    # Resolve PAY_FLOOR to an integer rank; None (feature OFF) for blank/unrecognized.
    return SEV_RANK.get((PAY_FLOOR or "").strip().lower())
def _sev_rank(sev):
    # Rank of a severity string's leading token; None for em-dash/blank/unknown.
    parts=(sev or "").split()
    return SEV_RANK.get(parts[0].lower()) if parts else None
def _rules_severity(impact):
    # #1989: a Python mirror of lib/severity-classify.sh's Immunefi Smart-Contract impact->tier rules, so a
    # LEAD's severity can be reconciled against what the platform's own rules say rather than trusting the LLM
    # hunter's self-claim (which over-claims — e.g. a griefing nonce-burn tagged "High"). Returns Critical/High/
    # Medium/Low, or "" when NO in-scope keyword matches (indeterminate -> the caller keeps the claim; unlike the
    # shell, which defaults an assumed-in-scope impact to Medium). The demo pins agreement with the shell on the
    # load-bearing cases so the two never drift.
    t=(impact or "").lower()
    def h(s): return s in t
    if (h("unclaimed yield") or h("unclaimed royalt") or h("unclaimed")) and not h("than unclaimed"):
        return "High"                                   # theft/permanent-freeze of UNCLAIMED yield/royalties
    if h("temporary freez") or h("temporarily freez"):
        return "High"                                   # TEMPORARY freezing of funds/NFTs
    if (h("insolven") or h("direct theft") or h("theft of any") or h("theft of user fund")
        or h("theft of funds") or h("steal") or h("drain")
        or h("permanent freez") or h("permanently freez") or h("govern") or h("unauthorized mint")
        or h("unauthorised mint") or (h("theft") and h("fund")) or (h("theft") and h("nft"))):
        return "Critical"
    if (h("griefing") or h("grief") or h("denial of service") or h("denial-of-service")
        or h("block stuffing") or h("theft of gas") or h("unbounded gas")
        or h("unable to operate") or h("lack of token funds") or h("lack of funds")
        or (h("burn") and h("nonce")) or h("bricked") or h("brick the") or h("permanently disable")):
        return "Medium"                                 # griefing / DoS (no funds stolen or frozen)
    if h("fails to deliver") or h("promised return"):
        return "Low"
    return ""                                           # indeterminate — never override the hunter's claim
def _reconcile_sev(claimed, impact):
    # Reconcile a hunter's CLAIMED severity against the rules-based tier for its impact text. Returns
    # (effective, overclaim): only ever LOWERS (rules strictly below the claim) — an under-claim or an
    # indeterminate impact keeps the claim (conservative), so a genuine finding is never wrongly demoted.
    rules=_rules_severity(impact)
    cr=_sev_rank(claimed); rr=_sev_rank(rules)
    if rules and cr is not None and rr is not None and rr < cr:
        return rules, True
    return claimed, False
def _is_unpayable(sev, floor_rank):
    # True only when the floor is set AND the severity is a KNOWN tier strictly below it. Unknown/blank
    # severity is never marked (a coverage gap is not a sub-floor payout).
    if floor_rank is None: return False
    r=_sev_rank(sev)
    return r is not None and r < floor_rank
def _unpay_badge(floor):
    # Additive pill appended AFTER the Sev text (not a mutation): inline text-decoration:none so it survives an
    # enclosing refuted {strike}; muted red-brown palette distinct from every SEVCOL; class `payfloor-x0` is the
    # stable test sentinel.
    return (f' <span class="payfloor-x0" title="below the program pay-floor ({html.escape(floor)}) — $0 payout on '
            f'this program, dropped at delivery by the payability gate" style="text-decoration:none;'
            f'background:#3a2a2a;color:#c98a8a;font-size:10px;font-weight:600;padding:1px 4px;border-radius:3px;'
            f'vertical-align:middle">$0</span>')
TYPE_INFO={
 "BREADTH":"Breadth track — discovery hunt: the LLM proposes candidate leads across mapped zones; each is killed or promoted by the M4 refute gate.",
 "DEPTH":"Depth track — deep-hunt: a stateful-invariant fuzzer BREAKS a hypothesized property and returns a reproducible shrunk call-sequence witness.",
}
SEV_INFO={
 "Critical":"Critical — direct large-scale fund loss, insolvency, or protocol takeover.",
 "High":"High — significant fund loss or protocol-impacting bug.",
 "Medium":"Medium — limited or conditional loss / griefing.",
 "Low":"Low — minor issue, no direct fund loss.",
}
CLASS_INFO={
 "C1":"ERC4626 share-price / vault accounting","C2":"Oracle integrity","C3":"Cross-chain / LayerZero OFT + compose",
 "C4":"Withdrawal queue / NFT claim accounting","C5":"Access control / role model","C6":"Accounting / rounding direction",
 "C7":"Signature / replay","C8":"Reentrancy","C9":"Decimals / scaling","C10":"Liquidation / redemption (CDP)",
 "C11":"First-depositor / inflation","C12":"Slippage / MEV / fee-vs-protection","C13":"Pause / freeze / compliance consistency",
 "C14":"Fork-delta (DAG matcher bridge)","C15":"Integration-seam / composability","C16":"State-machine liveness / stuck-state",
 "C17":"Index / slot-overwrite","C18":"Round / auction-griefing","C19":"Narrow-integer overflow / unsafe downcast",
 "C20":"Concentrated-liquidity tick / range precision","C21":"Context-flag / transient-state valuation dispatch",
 "C22":"Cross-protocol asset / unit equivalence","C23":"Hardcoded external-integration parameter",
 "SYS-solvency":"General composable-solvency lens — class-agnostic value-conservation over the custody/composition seam.",
 "C-invariant":"Generic protocol invariant (no specific coverage-map class matched).",
}
def _title_attr(s): return html.escape(s, quote=True)  # safe for a title="" attribute
def _sev_title(sev): return SEV_INFO.get((sev or "").split()[0] if sev else "", "Bug severity (bounty tier).")
def _cls_title(cls): return CLASS_INFO.get(cls, "Bug class (coverage-map taxonomy).")
def _intrinsic_sev(custody): return "High" if custody else ""  # planned-row severity fallback (#1953): a
    # value-custody zone's queued/fuzzing DEPTH row is already known to be High-severity surface — page()
    # and emit_model() both use this single mapping so their Sev cells never disagree.
def _type_badge(t):  # BREADTH (discovery) / DEPTH (deep-hunt) pill for the unified LEADS table
    c = {"BREADTH":("#58a6ff","#1f6feb"), "DEPTH":("#a371f7","#8957e5")}.get(t, ("#8b949e","#484f58"))
    return (f'<span title="{_title_attr(TYPE_INFO.get(t,""))}" style="background:{c[1]}26;color:{c[0]};'
            f'border:1px solid {c[1]}66;border-radius:10px;padding:1px 8px;font-size:11px;font-weight:600;'
            f'letter-spacing:.04em;cursor:help">{t}</span>')

def classify_liveness(exited, complete, alive, inflight, think, age):
    # PURE liveness classifier (the one factored-out function the #1913 plan asks for): given the already-
    # computed signals, return the dot/text/colour/is_live/class. page() and emit_model() both call it, so the
    # rendered pulse and the JSON assertion surface can never disagree. `class` is a stable machine tag.
    if exited:
        # FINISHED — nothing is running. Use a calm SLATE colour + a STATIC dot; green is reserved for LIVE,
        # so a completed run never shows the pulsing green that reads as "still working".
        if complete:
            cls="FINISHED"; dot="✓"; txt="✓ finished — verdict in chat"; col="#7d8590"
        else:
            cls="STOPPED"; dot="■"; txt="■ stopped — process exited"; col="#8a94a0"
    elif not alive:
        cls="PROCESS_GONE"; dot="⚫"; txt="PROCESS GONE — run-zone-hunt.sh not running (crashed?)"; col="#ff4d4d"
    elif inflight:
        # an LLM child is actively running — the model is thinking; buffered output makes file mtimes
        # quiet, so this (NOT the mtime) is the truth. Never show "stalled" while a call is in flight.
        t = f" · this lens step {think}s" if think is not None else ""
        cls="LIVE"; dot="🟢"; txt=f"LIVE · LLM active (generating + fuzzing){t}"; col="#39d353"
    elif age < 20:
        cls="LIVE"; dot="🟢"; txt=f"LIVE · last write {int(age)}s ago"; col="#39d353"
    elif age < 90:
        cls="WORKING"; dot="🟡"; txt=f"working · last write {int(age)}s ago"; col="#f0a800"
    else:
        # no LLM child AND no fresh write for a while — a genuine quiet window (between lens rows, or a hang)
        cls="QUIET"; dot="🟡"; txt=f"quiet {int(age)}s (no LLM call in flight) — between steps or slow"; col="#f0a800"
    is_live = (not exited) and (alive or inflight)
    return dot, txt, col, is_live, cls

def _links_row():
    # descriptor-driven links row — only present links render (no broken href when a URL is absent, per the
    # offline / corpus-bench case). target=_blank + rel=noopener, read-only external anchors.
    parts=[]
    if BOUNTY_URL:  parts.append(f'<a target="_blank" rel="noopener noreferrer" href="{html.escape(BOUNTY_URL, quote=True)}">Bounty program</a>')
    if REPO_URL:    parts.append(f'<a target="_blank" rel="noopener noreferrer" href="{html.escape(REPO_URL, quote=True)}">GitHub · repo</a>')
    if PROJECT_URL: parts.append(f'<a target="_blank" rel="noopener noreferrer" href="{html.escape(PROJECT_URL, quote=True)}">Project</a>')
    if not parts: return ""
    return '<div class="sub">🔗 ' + ' &nbsp;·&nbsp; '.join(parts) + '</div>'

def page(nav=""):
    # `nav` is the M2 detail-view chrome (a `← overview` link + hunt switcher pills) injected at the top of the
    # page. It defaults to "" so the M1 single-hunt render is byte-for-byte unchanged.
    now=datetime.datetime.now(); start=start_dt(); elapsed=now-start
    # #2298: every indicator below reads the ONE completeness model. "finished" requires BOTH the log's __EXIT__ marker
    # AND no live hunt process (a --deep-hunt-resume RE-RUN must not show a calm "finished" banner while the dot
    # pulses) AND every phase done/skip — computed once in hunt_model().
    M = hunt_model()
    st=M["st"]; prog=M["prog"]; covered=M["covered"]; failed=M["failed"]; total_z=M["total_z"]
    zs=M["zs"]; L=M["L"]; vs=M["vs"]; log=M["log"]; A=M["A"]
    exited=M["exited"]; complete=M["complete"]; PR=M["phase_rows"]; DR=M["deep_rows"]
    prows=""; _cur_group=None
    for name,w in PHASES:
        label,group = PHASE_META.get(name, (name, ""))
        if group != _cur_group:   # group header row — visually separates the breadth / depth / deliver tracks
            _cur_group = group
            prows+=(f'<tr><td></td><td colspan="2" style="color:#7d8590;font-size:11px;font-weight:600;'
                    f'letter-spacing:.06em;padding-top:8px;border-top:1px solid #21262d">{html.escape(group)}</td></tr>')
        s=st.get(name,"wait"); est=EST_MIN.get(name,0); pr=PR[name]
        # #2298: the extra text is the phase's checked/total row count — the SAME rows its ✅ is computed from.
        if s=="skip":
            extra=("skipped — --deep-hunt-only (no M5)" if name=="deliver · stage" else "off — run without --deep-hunt")
        elif s=="wait" and not pr["checked"]:
            extra=f"~{est} min"
        elif name=="4.6 · refute deep-hunt" and not pr["total"]:
            extra="∅ none"
        else:
            extra=f"{pr['checked']}/{pr['total']}"
            if name=="M3 · discovery":
                # #2020: name the open coverage (a degraded zone is an incomplete sweep, failed = HARNESS_ERROR)
                _deg = sum(1 for z in zs if z.get("status")=="hunted_degraded")
                _fl  = sum(1 for z in zs if z.get("status")=="failed")
                if _deg: extra+=f" · {_deg} degraded"
                if _fl:  extra+=f" · {_fl} errored"
            elif name=="4.5 · deep-hunt":
                _cap=sum(1 for r in DR if r["state"]=="capped")
                if _cap: extra+=f" · {_cap} capped"
            elif name=="4.6 · refute deep-hunt" and pr["unchecked"]:
                extra+=f" · {len(pr['unchecked'])} awaiting operator verdict"
        col="#f0a800" if s=="gap" else ("#e8e8e8" if s not in ("wait","skip") else "#888")
        prows+=(f'<tr data-phase="{html.escape(name, quote=True)}" data-state="{s}"><td>{ICON[s]}</td>'
                f'<td style="color:{col};padding-left:10px">{html.escape(label)}</td>'
                f'<td style="color:#888;text-align:right">{extra}</td></tr>')
    zrows=""
    import collections as _cl
    # AXIS 2 inputs — the zone RESULT must agree with the panels below it:
    #  (a) discovery leads classified by their refute-gate verdict (not raw counts — a refuted lead is
    #      NOT an open lead), keyed by the zone id leads() tags (matches the coverage zid);
    #  (b) deep-hunt (4.5) FINDINGs per zone, carrying the finding's severity.
    RV=M["RV"]
    # #2023: operator adjudication wins over the gate at the zone-result site too, so an op-CONFIRMED/DUPLICATE
    # lead counts as z_surv (survived), never z_ref — keeping AXIS-2 "zone result agrees with the panels below".
    _dup_breadth = M["dup_breadth"]
    # #2024: fold same-location raw candidates into one row BEFORE every tally below — page() and emit_model()
    # both group off this single G (built once in hunt_model()), so the collapse can never drift.
    G=M["G"]
    z_surv=_cl.Counter(); z_ref=_cl.Counter(); z_pend=_cl.Counter()
    for g in G:
        s=g["state"]
        if   s=="refuted": z_ref[g["zone"]]+=1
        elif s=="pending": z_pend[g["zone"]]+=1
        else:              z_surv[g["zone"]]+=1   # op_confirmed / op_duplicate / survived
    z_dh=_cl.Counter(); z_dhsev={}; z_dhref=_cl.Counter()
    for r in DR:   # #2298: the zone comes from the DEPTH row (plan), not a slot-suffix regex
        if r["state"]=="triaged_fp": z_dhref[r["zone"]]+=1   # triaged false positive — not an open finding
        elif r["state"]=="finding": z_dh[r["zone"]]+=1; z_dhsev[r["zone"]]=r.get("sev_join","")
    # AXIS 1 — execution STATE (square icons, like the PHASES section)
    ZSTATE={"hunted":("✅","#39d353","done"),"hunted_empty":("✅","#39d353","done"),
            "in_flight":("🔄","#f0a800","running"),"not_reached":("⬜","#5a6270","queued"),
            "failed":("🟥","#ff4d4d","failed"),"hunted_degraded":("⚠️","#f0a800","degraded"),
            # #1991: a zone the hunt was mid-flight on when the run EXITED is abandoned (a coverage gap), NOT
            # running — a calm slate, like the abandoned deep-hunt cell in #1980.
            "abandoned":("⚫","#8a94a0","stopped mid-hunt")}
    for z in zs:
        s=z.get("status","?")
        if exited and s=="in_flight": s="abandoned"   # #1991: no zone renders "running" after the hunt exited
        ic,scol,slbl=ZSTATE.get(s,("⬜","#888",s))
        zid=z.get("id","?")
        # #2298: ✅ only when the zone's M3 row, its leads and its DEPTH rows are ALL checked; a hunted zone with open
        # rows says how many, 🔄 while the hunt is live / ⚠️ once it exited.
        _zopen=zone_open_rows(M, zid)
        if s in ("hunted","hunted_empty") and _zopen:
            ic,scol,slbl=(("⚠️","#f0a800") if exited else ("🔄","#f0a800"))+(f"hunted · {_zopen} open",)
        # AXIS 2 — RESULT: deep-hunt finding > surviving lead > refuted > pending > empty
        if s in ("hunted","hunted_empty","hunted_degraded"):
            if z_dh.get(zid,0):
                sev=z_dhsev.get(zid,""); rcol=SEVCOL.get(sev.split()[0] if sev else "","#ff5c5c")
                rlbl=f"◆ {z_dh[zid]} deep finding"+(f" ({sev})" if sev else "")
            elif z_dhref.get(zid,0): rlbl,rcol=f"✗ {z_dhref[zid]} deep FP (triaged)","#e5737b"
            elif z_surv.get(zid,0): rlbl,rcol=f"◆ {z_surv[zid]} lead(s)","#ffb020"
            elif z_ref.get(zid,0):  rlbl,rcol=f"✗ {z_ref[zid]} refuted","#e5737b"
            elif z_pend.get(zid,0): rlbl,rcol=f"… {z_pend[zid]} pending","#f0a800"
            else:                   rlbl,rcol="∅ empty","#8a94a0"
        elif s=="failed": rlbl,rcol="✗ no result (gap)","#c07a7a"
        elif s=="abandoned": rlbl,rcol="⚫ stopped mid-hunt (gap)","#8a94a0"   # #1991: match emit_model()'s result text
        else:             rlbl,rcol="— pending","#5a6270"
        cust=' <span title="value-custody: funds live here — deep-hunt aims its value-conservation lens here">💰</span>' if z.get("value_custody") else ""
        w="700" if s=="failed" else "400"
        zrows+=(f'<tr data-zone="{html.escape(zid, quote=True)}" data-open="{_zopen}" data-state="{html.escape(s, quote=True)}"><td style="text-align:center">{ic}</td>'
                f'<td>{html.escape(zid)}{cust}</td>'
                f'<td style="color:{scol};font-weight:{w}">{slbl}</td>'
                f'<td style="color:{rcol};font-size:12px">{rlbl}</td></tr>')
    def _rv(x): return RV.get(_normloc(x["loc"]))
    # #2023/#2024: header tally uses the shared classifier over the GROUPED (distinct-location) list, so it
    # matches the rows below AND emit_model()'s leads_summary — an operator CONFIRMED/DUPLICATE counts as
    # survived, not refuted, and a folded location counts once, not once per raw copy.
    _lstates=[g["state"] for g in G]
    n_ref=sum(1 for s in _lstates if s=="refuted")
    n_surv=sum(1 for s in _lstates if s in ("op_confirmed","op_duplicate","survived"))
    n_pend=len(G)-n_ref-n_surv
    pf_rank=_pay_floor_rank()   # #1960: resolved once; None ⇒ pay-floor marker OFF
    n_hidden=0   # #1966: sub-floor leads are hidden from the table, not badged; counted here
    # #1996: per-status tally for the LEADS filter chips — counts what is actually RENDERED (sub-floor rows
    # are skipped below, so they never inflate a chip). One shared Counter across breadth + depth so the
    # chip totals match the single unified table the operator filters. Buckets: confirmed (◆ survived a gate),
    # pending (gate undecided), refuted (✗ killed), other (clean / harness-gap — visible under "All" only).
    _stc=_cl.Counter()
    # #2005: the "Survived" bucket = operator-CONFIRMED real + NON-DUPLICATE findings ONLY. Surviving an
    # AUTOMATED gate (the refute gate for breadth, the invariant-fuzz for depth) is NOT confirmation — such a
    # lead still needs a forge PoC and a duplicate check, so it stays in Pending until the operator records a
    # `CONFIRMED` verdict in the adjudication overlay (adjudicated.tsv for breadth, deep-hunt-adjudicated.tsv
    # for depth). Nothing is confirmed by the machine alone.
    # #2007: a DUPLICATE verdict = a real, PoC-verified bug that was ALREADY REPORTED (submitted → marked a
    # duplicate → $0). It is neither Confirmed (not payable), nor Pending (fully worked), nor Refuted (it IS a
    # real bug). Its own bucket, keyed by the operator's DUPLICATE verdict + the reason (the prior report id).
    # #2023: both sets come from _breadth_adjudication(A) above (shared with the zone-result site), and the
    # per-row verdict is chosen by the shared _lead_state() so operator precedence can never drift off again.
    lrows=""
    for x in sorted(G,key=lambda a:(0 if ("High" in a["sev"] or "Crit" in a["sev"]) else 1)):
        if _is_unpayable(x["sev"], pf_rank):   # #1966: hide sub-floor rows, tally instead of rendering
            n_hidden += 1
            continue
        col=SEVCOL.get(x["sev"].split()[0] if x["sev"] else "","#ccc")
        rv=_rv(x)
        _state=x["state"]   # #2024: precomputed per group by _group_leads(), not recalled per-row
        if _state=="refuted":
            strike="text-decoration:line-through;"; rowop="opacity:.6"; st="refuted"
            vcell='<span style="color:#e5737b;font-weight:600">✗ REFUTED</span>'
            detail=f'<span style="color:#e5737b;font-size:12px">verified → not a bug: {html.escape(rv["reason"][:260])}</span>'
        elif _state=="op_confirmed":
            strike=""; rowop=""; st="confirmed"   # #2005: only an operator CONFIRMED verdict reaches Survived
            vcell='<span style="color:#39d353;font-weight:700">◆ CONFIRMED — real, non-dup</span>'
            detail=f'<span style="color:#bbb;font-size:12px">{html.escape(x["title"][:200])}</span>'
        elif _state=="op_duplicate":
            _dupr=_dup_breadth.get((_normloc(x["loc"]), x["_win_cls"]),"")
            strike=""; rowop="opacity:.8"; st="duplicate"   # #2007: real + PoC-verified, but already reported → $0
            vcell='<span style="color:#ff5c5c;font-weight:700">◆ real · DUPLICATE ($0)</span>'
            detail=f'<span style="color:#ff5c5c;font-size:12px">confirmed real bug, already reported: {html.escape(_dupr[:260])}</span>'
        elif _state=="survived":
            strike=""; rowop=""; st="pending"   # #2005: survived the refute gate, but NOT PoC-verified → Pending
            vcell='<span style="color:#f0a800">◆ survived refute · needs PoC</span>'
            detail=f'<span style="color:#bbb;font-size:12px">{html.escape(x["title"][:200])}</span>'
        else:
            strike=""; rowop=""; st="pending"
            vcell='<span style="color:#f0a800">… pending refute</span>'
            detail=f'<span style="color:#bbb;font-size:12px">{html.escape(x["title"][:200])}</span>'
        # #2024: a folded row (n_folded > 1) shows how many raw copies + which classes collapsed into it — the
        # collapse is visible, not silent.
        if x["n_folded"]>1:
            detail+=(f' <span style="color:#7d8590;font-size:11px">· folded from {x["n_folded"]} copies '
                      f'({html.escape(", ".join(x["clss"]))})</span>')
        # #1989: when the shown Sev was reclassified DOWN from the hunter's over-claim, flag it inline so the
        # operator sees the hunter said more (and why this row may now be sub-floor), not a silent rewrite.
        _ocflag=(f'<span title="hunter self-claimed {html.escape(x.get("sev_claimed",""))}; reclassified to '
                 f'{html.escape(x["sev"])} by the platform impact-&gt;tier rules" style="color:#f0a800;'
                 f'font-weight:400;font-size:11px;cursor:help">&nbsp;⚠ claimed {html.escape(x.get("sev_claimed",""))}</span>'
                 ) if x.get("overclaim") else ""
        _stc[st]+=1
        lrows+=(f'<tr data-st="{st}" style="{rowop}"><td style="white-space:nowrap">{_type_badge("BREADTH")}</td>'
                f'<td title="{_title_attr(_sev_title(x["sev"]))}" style="color:{col};font-weight:600;cursor:help;{strike}">{html.escape(x["sev"])}{_ocflag}</td>'
                f'<td title="{_title_attr(_cls_title(x["cls"]))}" style="color:#9fd;cursor:help;{strike}">{html.escape(x["cls"])}</td>'
                f'<td style="font-family:monospace;font-size:12px;{strike}"><span title="stable finding id — cite this" style="color:#8a94a0;font-weight:600">{_finding_id(x["loc"], x["cls"])}</span>&nbsp;{html.escape(x["loc"])}</td>'
                f'<td style="white-space:nowrap">{vcell}</td>'
                f'<td>{detail}</td></tr>')
    arows=""; n_arows=0
    for x in A:
        if x.get("verdict","").strip().upper() in ("CONFIRMED","DUPLICATE"): continue   # #2005/#2007: CONFIRMED + DUPLICATE are REAL bugs (own buckets), NOT "not-a-bug" adjudications
        n_arows+=1
        arows+=(f'<tr style="opacity:.55"><td style="color:#777;font-weight:600;text-decoration:line-through">{html.escape(x["sev"])}</td>'
                f'<td style="color:#678;text-decoration:line-through">{html.escape(x["cls"])}</td>'
                f'<td style="font-family:monospace;font-size:12px;text-decoration:line-through;color:#889">{html.escape(x["loc"])}</td>'
                f'<td style="color:#e5737b;font-size:12px">✗ refuted — verified, not a bug ({html.escape(x["verdict"])}): {html.escape(x["reason"][:170])}</td></tr>')
    verline=""
    if vs is not None: verline="&nbsp;·&nbsp; refute: "+" ".join(f'{k}={v}' for k,v in vs.items())
    stage=""
    for ln in reversed(log.splitlines()):
        ln=ln.strip()
        if ln and ("run-discovery.sh:" in ln or "run-zone-hunt.sh:" in ln or "verify-findings" in ln):
            stage=re.sub(r".*?\.sh:\s*","",ln); break
    if complete:
        bar_col="#39d353"; banner="✅ DONE — full coverage, verdict in chat"
    elif exited:
        bar_col="#e5737b"
        # #2298: name the open rows per phase, not only errored zones — any unchecked row blocks DONE.
        _open=" · ".join(f"{k.split(' · ')[0]} {len(v['unchecked'])}" for k,v in PR.items()
                          if v["unchecked"] and M["st"].get(k)!="skip")
        banner=(f"⚠️ STOPPED INCOMPLETE — {M['n_open']} unchecked row(s)"
                + (f" ({html.escape(_open)})" if _open else "")
                + (f"; {failed} zone(s) errored (HARNESS_ERROR, no verdict)" if failed else "")
                + f"; {covered}/{total_z} zones hunted. NOT fully covered.")
    else:
        bar_col="#f0a800"; banner=f"🔄 running · {html.escape(stage[:120])}"
    # ---- liveness: is it actually DOING something, or frozen? ----
    fm,fp = freshest()
    age = (now - datetime.datetime.fromtimestamp(fm)).total_seconds() if fm else 9e9
    alive = proc_alive()
    act = sublog_activity()
    inflight, think = llm_child()
    live_dot,live_txt,live_col,is_live,_lcls = classify_liveness(exited, complete, alive, inflight, think, age)
    # what is happening right now
    if exited:
        now_txt=""
    elif act:
        z = html.escape(act["zone"]) if act["zone"] else "—"
        now_txt = f'{html.escape(act["kind"])}<span style="color:#7d8590"> · zone </span>{z}'
        if act["waited"] is not None:
            now_txt += f'<span style="color:#7d8590"> · opus thinking </span><b style="color:#e8e8e8">{int(act["waited"])}s</b>'
    else:
        now_txt = html.escape(stage[:100]) or "starting…"
    # the dot PULSES only when something is genuinely live; when finished / crashed it is STATIC.
    _anim = "" if is_live else "animation:none;"
    pulse = f'<span class="pulse" style="background:{live_col};box-shadow:0 0 8px {live_col};{_anim}"></span>'
    livebar = (f'<div class="live" style="border-color:{live_col}">'
               f'{pulse}<span style="color:{live_col};font-weight:600">{html.escape(live_txt)}</span>'
               + (f'<span style="color:#666"> &nbsp;|&nbsp; now: </span>{now_txt}' if now_txt else "")
               + '</div>')
    # ---- deep-hunt (STAGE 4.5) — SAME 5-column shape + formatting as the Leads table ----
    # Sev | Class | Location | Refute gate | Detail. The fuzzer's verdict maps onto the Sev cell
    # (a deep-hunt FINDING is a fresh lead, ranked first like a High); a FINDING has NOT been through
    # the refute gate yet (it is merged into verified_findings straight from the fuzzer), so its gate
    # cell reads "pending" exactly like an un-refuted discovery lead.
    # #2298: the DEPTH rows come from hunt_model() (the runner's plan ∪ observed dirs ∪ a synthetic skipped/legacy
    # row), each with exactly ONE state from _deep_row_state() — never from a client-side re-derivation.
    _RANK = {"rerunning": 3, "running": 3, "harness_error": 2, "clean": 2, "not_run": 2, "capped": 4, "queued": 4,
             "plan_unknown": 5, "deep_skipped": 5}
    def _rank(r):                     # open FINDING > triaged-FP > clean/gap > running > queued/capped > synthetic
        if r["state"] == "finding": return 0
        if r["state"] == "triaged_fp": return 1
        return _RANK.get(r["state"], 2)
    _n_capped = sum(1 for r in DR if r["state"] == "capped")
    n_dh_find = 0; dhrows = ""
    for r in sorted(DR, key=_rank):
        state = r["state"]; adj = r["adj"]; v = r["verdict"]
        cls = r["cls"]; loc = r["target"] or r["zone"] or r["slot"]
        strike = ""   # set on a triaged-FP / clean row, applied to Class/Location — same look as a refuted LEAD
        # #depth-sev: EVERY DEPTH row shows a clearly-defined severity — the normalized joined severity from
        # verified_findings.json, else the zone's intrinsic custody severity, else the program pay-floor. Only a
        # floor-less program can leave a non-custody row without one (em-dash). Synthetic rows carry none.
        if state in ("plan_unknown", "deep_skipped"):
            sevtxt = ""
        else:
            sevtxt = (_norm_sev(r["sev_join"]) or _intrinsic_sev(r["custody"]) or (PAY_FLOOR.title() if PAY_FLOOR else ""))
        scol = SEVCOL.get(sevtxt.split()[0] if sevtxt else "", "#ccc")
        sev = (f'<span style="color:{scol};font-weight:600">{html.escape(sevtxt)}</span>' if sevtxt
               else '<span style="color:#5a6270">—</span>')
        if state == "rerunning":
            # this slot is re-executing RIGHT NOW — override only the VERDICT with in-progress. Sev is the TARGET's
            # severity class (intrinsic, known regardless of the re-run) — always show it, coloured.
            gate = '<span style="color:#58a6ff;font-weight:600">🔄 re-running (in progress)</span>'
            detail = '<span style="color:#8b949e;font-size:12px">re-hunting with fitted fuzz budget — verdict pending</span>'
            rowop = ""; st_ = "pending"   # #1996: verdict undecided → pending bucket
        elif state == "triaged_fp":
            # triaged false positive — IDENTICAL look to a refuted LEAD: severity in its OWN colour, struck through
            # (Sev/Class/Location), dimmed; the refuted status sits in the gate column.
            sev = f'<span style="color:{scol};font-weight:600;text-decoration:line-through">{html.escape(sevtxt or "?")}</span>'
            # #2108(b): a gate-sourced REFUTED carries a compact provenance marker.
            _auto = ' · auto (4.6 gate)' if adj.get("source") == "gate" else ''
            gate = f'<span style="color:#e5737b;font-weight:600">✗ REFUTED (triaged FP){_auto}</span>'
            detail = f'<span style="color:#e5737b;font-size:12px">verified → not a bug: {html.escape(adj.get("reason", "")[:280])}</span>'
            rowop = "opacity:.6"; strike = "text-decoration:line-through;"; st_ = "refuted"   # #1996
        elif state == "finding" and adj.get("verdict") == "CONFIRMED":
            # #2005: operator-CONFIRMED — real bug, non-duplicate (forge PoC + dedup done) → Survived
            n_dh_find += 1
            gate = '<span style="color:#39d353;font-weight:700">◆ CONFIRMED — real, non-dup</span>'
            detail = f'<span style="color:#bbb;font-size:12px">{html.escape(adj.get("reason", "")[:280])}</span>'
            rowop = ""; st_ = "confirmed"
        elif state == "finding" and adj.get("verdict") == "DUPLICATE":
            # #2007: real + PoC-verified, but already reported → $0 (its own state, not needs-PoC/refuted)
            gate = '<span style="color:#ff5c5c;font-weight:700">◆ real · DUPLICATE ($0)</span>'
            detail = f'<span style="color:#ff5c5c;font-size:12px">confirmed real bug, already reported: {html.escape(adj.get("reason", "")[:260])}</span>'
            rowop = "opacity:.8"; st_ = "duplicate"
        elif state == "finding":
            n_dh_find += 1
            # #2298: a survivor of the automated 4.6 gate (REAL) is NOT a verdict — it stays open until the operator
            # records CONFIRMED / DUPLICATE / FP, mirroring the breadth "survived refute · needs PoC" label.
            if r.get("gate") == "REAL":
                gate = '<span style="color:#f0a800">◆ survived refute gate (4.6) · needs forge PoC</span>'
            else:
                gate = '<span style="color:#f0a800">◆ FINDING · needs forge PoC + triage</span>'
            detail = (f'<span style="color:#bbb;font-size:12px">multi-step invariant broken — shrunk witness '
                      f'({r["steps"]} steps); LLM-hypothesized invariant, verify before any submit · awaiting an '
                      f'operator verdict (CONFIRMED / DUPLICATE / FP in deep-hunt-adjudicated.tsv)</span>')
            rowop = ""; st_ = "pending"   # #2005: survived the fuzz gate but NOT confirmed → Pending (needs PoC)
        elif state == "clean":
            # no bug confirmed on this High-value surface — struck through, like a refuted lead. The Sev is the
            # TARGET's severity class (intrinsic, same as a LEAD keeps its Sev when refuted).
            sev = f'<span style="color:{scol};font-weight:600;text-decoration:line-through">{html.escape(sevtxt or "?")}</span>'
            gate = '<span style="color:#8a94a0;font-size:12px">∅ clean (held in budget)</span>'
            detail = ('<span style="color:#8a94a0;font-size:12px">every deep invariant held across the fuzzed '
                      'search (not a proof of safety)</span>')
            rowop = "opacity:.6"; strike = "text-decoration:line-through;"; st_ = "other"   # #1996: clean, no open lead
        elif state == "harness_error":
            # a coverage GAP (not "no bug", so NOT struck); the target still carries its severity class. #2298: the raw
            # verdict token is kept, so TRANSIENT_ERROR / LOW_COVERAGE no longer read as "harness error".
            if v == "ABANDONED":
                # dir exists but silent — the cell was force-advanced or its session died: NOT a perpetual "fuzzing…".
                gate = '<span style="color:#f0a800;font-size:12px">⚠ harness error — no verdict</span>'
                detail = '<span style="color:#f0a800;font-size:12px">deep-hunt cell ended without a verdict — a coverage gap</span>'
            elif v in ("", "HARNESS_ERROR"):
                gate = '<span style="color:#f0a800;font-size:12px">⚠ harness error — no verdict</span>'
                detail = '<span style="color:#f0a800;font-size:12px">harness error is not a verdict — a coverage gap</span>'
            else:
                gate = f'<span style="color:#f0a800;font-size:12px">⚠ {html.escape(v)} — no trusted verdict</span>'
                detail = (f'<span style="color:#f0a800;font-size:12px">{html.escape(v)} is not a verdict — a coverage gap '
                          f'(re-hunt the row)</span>')
            rowop = "opacity:.6"; st_ = "other"   # #1996: coverage gap, not an open lead
        elif state == "running":
            gate = '<span style="color:#58a6ff">🔄 fuzzing…</span>'
            detail = '<span style="color:#8b949e;font-size:12px">opus generating handler + stateful fuzzing</span>'
            rowop = ""; st_ = "pending"   # #1996: in progress → pending
        elif state == "capped":
            gate = '<span style="color:#f0a800;font-weight:600">⏸️ capped</span>'
            detail = ('<span style="color:#8b949e;font-size:12px">lens cut by --deep-hunt-max-lenses; re-run with a '
                      'higher cap + --deep-hunt-resume</span>')
            rowop = "opacity:.5"; st_ = "other"
        elif state == "not_run":
            gate = '<span style="color:#f0a800;font-size:12px">⚠ not run</span>'
            detail = ('<span style="color:#f0a800;font-size:12px">planned lens row — STAGE 4.5 ended without running '
                      'it (a coverage gap)</span>')
            rowop = "opacity:.6"; st_ = "other"
        elif state == "plan_unknown":
            gate = '<span style="color:#f0a800;font-size:12px">❔ plan unknown</span>'
            detail = ('<span style="color:#f0a800;font-size:12px">plan unknown — out dir predates deep-hunt/plan.json; '
                      'completeness cannot be proven</span>')
            rowop = "opacity:.6"; st_ = "other"
        elif state == "deep_skipped":
            gate = '<span style="color:#f0a800;font-size:12px">⚠ deep-hunt not run</span>'
            detail = (f'<span style="color:#f0a800;font-size:12px">deep-hunt not run: '
                      f'{html.escape(r.get("reason", "") or "skipped")}</span>')
            rowop = "opacity:.6"; st_ = "other"
        else:   # queued
            gate = '<span style="color:#6e7681">⬜ queued</span>'
            detail = '<span style="color:#6e7681;font-size:12px">planned lens row — not yet run</span>'
            rowop = "opacity:.5"; st_ = "pending"   # #1996: not yet run → pending
        if _is_unpayable(sevtxt, pf_rank):   # #1960/#1966: hide sub-floor rows, tally instead of rendering
            n_hidden += 1
            continue
        _stc[st_]+=1   # #1996: count the RENDERED deep row into its filter bucket
        dhrows += (f'<tr data-st="{st_}" data-slot="{html.escape(r["slot"], quote=True)}" data-dstate="{state}" style="{rowop}"><td style="white-space:nowrap">{_type_badge("DEPTH")}</td>'
                   f'<td title="{_title_attr(_sev_title(sevtxt))}" style="white-space:nowrap;cursor:help">{sev}</td>'
                   f'<td title="{_title_attr(_cls_title(cls))}" style="color:#9fd;cursor:help;{strike}">{html.escape(cls)}</td>'
                   f'<td style="font-family:monospace;font-size:12px;{strike}"><span title="stable finding id — cite this" style="color:#8a94a0;font-weight:600">{_finding_id(loc, cls)}</span>&nbsp;{html.escape(loc)}</td>'
                   f'<td style="white-space:nowrap">{gate}</td>'
                   f'<td>{detail}</td></tr>')
    # STAGE 4.5 three-state annotation (issue comment 5308547720): distinguish "not reached yet" from "reached
    # but 0 lenses routed" so a DONE non-custody hunt never contradicts the finished banner with a false
    # "not reached". Only annotate when the depth track has NO rows to show (else the rows themselves are the state).
    _dh_mode = M["deep_mode"]
    if _dh_mode == "pending":
        _dh_note = ' &nbsp;·&nbsp; <span style="color:#8b949e">STAGE 4.5 not reached yet (still in breadth)</span>'
    elif _dh_mode == "planned" and not DR:
        _dh_note = (' &nbsp;·&nbsp; <span style="color:#f0a800" title="STAGE 4.5 ran but the zone is not '
                    'value-custody and no composition seam was detected, so no deep-hunt/composable-solvency lens '
                    'applied">STAGE 4.5 reached — 0 lenses routed (not value-custody, no composition seam)</span>')
    elif _dh_mode == "off":
        _dh_note = ' &nbsp;·&nbsp; <span style="color:#8b949e">deep-hunt off (run without --deep-hunt)</span>'
    elif _dh_mode == "legacy":
        _dh_note = (' &nbsp;·&nbsp; <span style="color:#f0a800">plan unknown — out dir predates deep-hunt/plan.json; '
                    'completeness cannot be proven</span>')
    else:
        _dh_note = ""
    # NOTE: the reference built a stand-alone `dhblock` here (a separate DEPTH LEADS card) that it NEVER
    # emitted — the live UI is the unified {lrows}{dhrows} LEADS table below. That vestigial dead block is
    # dropped in this port (plan #1913 M1); the rendered behaviour is preserved by the one unified table.
    # #1966: sub-floor rows are hidden from the LEADS table body, collapsed into one summary row instead
    # of a per-row badge; colspan=6 matches the 6-column header below (Type/Sev/Class/Location/Refute gate/Detail).
    hidden_row = (f'<tr><td colspan="6" style="color:#7d8590;font-size:12px;padding:6px 8px">'
                  f'{n_hidden} sub-floor lead{"s" if n_hidden!=1 else ""} hidden (below pay-floor '
                  f'{html.escape(PAY_FLOOR)} — $0 on this program)</td></tr>') if n_hidden else ""
    # #1996: LEADS filter chips — client-side show/hide by data-st bucket. Built as plain strings (not inside
    # the f-string template) so the JS braces need no escaping. Selection persists in localStorage and is
    # re-applied on every 5s meta-refresh; the column-header row + sub-floor summary carry no data-st so they
    # never hide. "other" (clean / harness-gap) rows are visible under "All" only — no dedicated chip.
    # #2005: the "confirmed" bucket is labelled "Confirmed" and holds ONLY operator-confirmed real + NON-dup
    # findings — a `CONFIRMED` verdict recorded in the adjudication overlay after a forge PoC + a duplicate
    # check. Surviving an automated gate (refute / invariant-fuzz) is NOT confirmation: those leads stay in
    # Pending until verified. So a deep FINDING or a survived-refute lead is Pending, never Confirmed, until
    # the operator confirms it. data-sel/data-st stays "confirmed" (internal key; the filter + test key on it).
    _chipdefs=[("all","All",sum(_stc.values()),""),
               ("confirmed","Confirmed",_stc.get("confirmed",0),
                "confirmed real bug, NOT a duplicate — appears only after an operator records a CONFIRMED "
                "verdict (forge PoC + dedup done); surviving an automated gate alone is not confirmation"),
               ("pending","Pending",_stc.get("pending",0),""),
               ("duplicate","Duplicate",_stc.get("duplicate",0),
                "confirmed real bug that was ALREADY REPORTED — PoC-verified + submitted, but marked a "
                "duplicate → $0. Real (not refuted), done (not pending), unpayable (not Confirmed)."),
               ("refuted","Refuted",_stc.get("refuted",0),"")]
    chipbar=('<div class="chips">'+''.join(
        '<span class="chip" data-sel="%s" onclick="hfilter(\'%s\')"%s>%s <b>%d</b></span>'
        %(k,k,(' title="%s"'%html.escape(t) if t else ''),lbl,n)
        for k,lbl,n,t in _chipdefs)+'</div>')
    filter_js=("<script>function hfilter(s){"
               "try{localStorage.setItem('huntLeadFilter',s);}catch(e){}"
               "var rs=document.querySelectorAll('#leadtbl tr[data-st]');"
               "for(var i=0;i<rs.length;i++){var m=(s==='all'||rs[i].getAttribute('data-st')===s);"
               "rs[i].style.display=m?'':'none';}"
               "var cs=document.querySelectorAll('.chip');"
               "for(var j=0;j<cs.length;j++){cs[j].classList.toggle('on',cs[j].getAttribute('data-sel')===s);}}"
               "(function(){var s='all';try{s=localStorage.getItem('huntLeadFilter')||'all';}catch(e){}hfilter(s);})();"
               "</script>")
    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="5">
<title>{html.escape(LABEL)}</title><style>
body{{background:#0d1117;color:#e8e8e8;font-family:-apple-system,Segoe UI,Roboto,sans-serif;margin:0;padding:24px}}
.wrap{{max-width:1000px;margin:auto}}
h1{{font-size:20px;margin:0 0 2px}} .sub{{color:#888;font-size:13px;margin-bottom:16px}}
.barwrap{{background:#21262d;border-radius:8px;height:34px;overflow:hidden;position:relative;margin:14px 0}}
.bar{{height:100%;width:{prog}%;background:{bar_col};transition:width .4s;border-radius:8px}}
.barlabel{{position:absolute;inset:0;line-height:34px;text-align:center;font-weight:700;color:#0d1117;font-size:15px}}
.grid{{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-top:8px}}
@media(max-width:760px){{.grid{{grid-template-columns:1fr}}}}
table{{width:100%;border-collapse:collapse;font-size:14px}} td{{padding:4px 6px;border-bottom:1px solid #21262d;vertical-align:top;word-break:break-word;overflow-wrap:anywhere}}
.card{{background:#161b22;border:1px solid #21262d;border-radius:10px;padding:14px;overflow:hidden}}
.card h2{{font-size:13px;text-transform:uppercase;letter-spacing:.5px;color:#7d8590;margin:0 0 8px}}
.banner{{padding:10px 14px;border-radius:8px;background:#161b22;border:1px solid #30363d;font-size:14px;margin-bottom:6px}}
.live{{padding:9px 14px;border-radius:8px;background:#0f1420;border:1px solid #30363d;border-left-width:4px;font-size:13.5px;margin-bottom:10px;display:flex;align-items:center;flex-wrap:wrap;gap:2px}}
.pulse{{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:8px;flex:0 0 auto;animation:bl 1.4s ease-in-out infinite}}
@keyframes bl{{0%,100%{{opacity:1}}50%{{opacity:.25}}}}
.meta{{color:#666;font-size:12px;margin-top:14px}}
a{{color:#58a6ff;text-decoration:none}} a:hover{{text-decoration:underline}}
.chips{{display:flex;gap:6px;flex-wrap:wrap;margin:0 0 10px}}
.chip{{cursor:pointer;user-select:none;font-size:12px;padding:3px 10px;border-radius:12px;background:#21262d;color:#9da7b1;border:1px solid #30363d}}
.chip:hover{{border-color:#484f58;color:#e8e8e8}}
.chip.on{{background:#1f6feb;color:#fff;border-color:#1f6feb;font-weight:600}}
</style></head><body><div class="wrap">
{nav}
<h1>🎯 {html.escape(LABEL)}{(' <span style="color:#666;font-weight:400;font-size:14px">· ' + html.escape(REWARD_LINE) + '</span>') if REWARD_LINE else ''}</h1>
<div class="sub">dark-factory capstone · flat-cyborg/opus · deep-hunt · composable-solvency lens · human-gated (never auto-submit)</div>
{_links_row()}
<div class="banner">{banner}{verline}</div>
{livebar}
<div class="barwrap"><div class="bar"></div><div class="barlabel">{int(prog)}%</div></div>
<div class="sub">running {hms(elapsed)} · start {start.strftime('%H:%M')} · {('DONE' if complete else f'STOPPED — {M["n_open"]} unchecked row(s), needs re-hunt or a verdict') if exited else 'ETA to verdict ~2–3h (deep-hunt is the wildcard)'}</div>
<div class="grid">
<div class="card"><h2>Phases</h2><table>{prows}</table></div>
<div class="card"><h2>Zones ({covered}/{total_z} hunted{f' · {failed} errored' if failed else ''})</h2><table><tr style="color:#7d8590;font-size:11px"><td></td><td>Zone</td><td>State</td><td>Result</td></tr>{zrows}</table></div>
</div>
<div class="card" style="margin-top:20px"><h2>LEADS &nbsp;<span style="font-weight:400;font-size:12px;color:#7d8590">breadth {len(G)} ({n_surv} survived · {n_ref} refuted · {n_pend} pending) &nbsp;·&nbsp; depth {PR["4.5 · deep-hunt"]["checked"]}/{PR["4.5 · deep-hunt"]["total"]} lens rows{f' · {_n_capped} capped' if _n_capped else ''}{f' · {n_dh_find} FINDING' if n_dh_find else ''}{_dh_note}</span></h2>{chipbar}<table id="leadtbl">
<tr style="color:#7d8590"><td>Type</td><td>Sev</td><td>Class</td><td>Location</td><td>Refute gate</td><td>Detail</td></tr>{lrows}{dhrows}{hidden_row}</table></div>
{('<div class="card" style="margin-top:16px"><h2>Adjudicated — verified, NOT a bug (' + str(n_arows) + ') · removed from refute queue</h2><table><tr style="color:#7d8590"><td>Sev</td><td>Class</td><td>Location</td><td>Verdict</td></tr>' + arows + '</table></div>') if A else ''}
<div class="meta">auto-refresh 10s · {now.strftime('%H:%M:%S')} · localhost:{PORT}</div>
</div>{filter_js}</body></html>"""

def emit_model():
    # Deterministic assertion surface (NOT rendered by the browser): the computed facts as JSON, so the
    # offline demo can pin the load-bearing model without a /proc scan or HTML scraping. #2298: it reads the SAME
    # hunt_model() as page() and hunt_card() (progress, completeness, phases, DEPTH rows), so they never disagree.
    now=datetime.datetime.now()
    M=hunt_model()
    st=M["st"]; prog=M["prog"]; covered=M["covered"]; failed=M["failed"]; total_z=M["total_z"]
    zs=M["zs"]; vs=M["vs"]; A=M["A"]; exited=M["exited"]; complete=M["complete"]; DR=M["deep_rows"]
    pf_rank=_pay_floor_rank()   # #1960: resolved once; None ⇒ every `unpayable` is False
    # breadth leads
    # #2023: dispatch on the SAME shared _lead_state() the renderer uses, so an operator CONFIRMED/DUPLICATE
    # adjudication wins over the automated refute-gate verdict here too.
    # #2024: G is folded ONCE in hunt_model() — the IDENTICAL G page() renders.
    G=M["G"]
    leads_out=[]; n_ref=n_surv=n_pend=0
    for x in G:
        s=x["state"]
        if   s=="refuted":      state="REFUTED";   struck=True;  n_ref+=1
        elif s=="op_confirmed": state="CONFIRMED"; struck=False; n_surv+=1
        elif s=="op_duplicate": state="DUPLICATE"; struck=False; n_surv+=1
        elif s=="survived":     state="CONFIRMED"; struck=False; n_surv+=1
        else:                   state="PENDING";   struck=False; n_pend+=1
        leads_out.append({"id":_finding_id(x["loc"], x["cls"]),"loc":x["loc"],"cls":x["cls"],"sev":x["sev"],
                          "sev_claimed":x.get("sev_claimed",x["sev"]),"overclaim":bool(x.get("overclaim")),
                          "verdict":state,
                          "struck":struck,"unpayable":_is_unpayable(x["sev"], pf_rank),
                          "n_folded":x["n_folded"],"classes":x["clss"]})
    # deep rows — the runner's plan ∪ observed dirs ∪ synthetic row, one state each (mirrors the render branches)
    deep_out=[]; n_dh_find=0
    for r in DR:
        state=r["state"]
        if state in ("plan_unknown","deep_skipped"):
            sev=""
        else:
            # #depth-sev: same resolution as page() — normalized join / intrinsic custody / pay-floor.
            sev=(_norm_sev(r["sev_join"]) or _intrinsic_sev(r["custody"]) or (PAY_FLOOR.title() if PAY_FLOOR else ""))
        if state=="finding": n_dh_find+=1
        loc=r["target"] or r["zone"] or r["slot"]
        deep_out.append({"id":_finding_id(loc, r["cls"]),"slot":r["slot"],"zone":r["zone"],"cls":r["cls"],"loc":loc,
                         "severity":sev,"state":state,"verdict":r["verdict"],"plan_state":r["plan"],
                         "struck":state in ("triaged_fp","clean"),
                         # #2108(b): provenance of a triaged_fp — "gate" = automated 4.6 refute gate, None = a
                         # manual deep-hunt-adjudicated.tsv row (manual wins, so a manual override reads None here).
                         "adj_source":r["adj"].get("source"),
                         "adj_verdict":(r["adj"].get("verdict") or None),"gate_verdict":r.get("gate"),
                         # #2298: checked = a terminal 4.5 verdict AND (for a FINDING) an operator 4.6 verdict.
                         "checked":r["checked"],
                         "unpayable":_is_unpayable(sev, pf_rank)})
    # zones — the Result label that must agree with the LEADS table
    import collections as _cl
    z_surv=_cl.Counter(); z_ref=_cl.Counter(); z_pend=_cl.Counter()
    for x in G:   # #2023/#2024: same operator-precedence classifier, over the same GROUPED list as page()
        s=x["state"]
        if   s=="refuted": z_ref[x["zone"]]+=1
        elif s=="pending": z_pend[x["zone"]]+=1
        else:              z_surv[x["zone"]]+=1   # op_confirmed / op_duplicate / survived
    z_dh=_cl.Counter(); z_dhsev={}; z_dhref=_cl.Counter()
    for r in DR:
        if r["state"]=="triaged_fp": z_dhref[r["zone"]]+=1
        elif r["state"]=="finding": z_dh[r["zone"]]+=1; z_dhsev[r["zone"]]=r.get("sev_join","")
    zones_out=[]
    for z in zs:
        s=z.get("status","?"); zid=z.get("id","?")
        if exited and s=="in_flight": s="abandoned"   # #1991: an exited hunt has no running zone — it's a gap
        if s in ("hunted","hunted_empty","hunted_degraded"):
            if z_dh.get(zid,0): result=f"◆ {z_dh[zid]} deep finding"+(f" ({z_dhsev.get(zid,'')})" if z_dhsev.get(zid,'') else "")
            elif z_dhref.get(zid,0): result=f"✗ {z_dhref[zid]} deep FP (triaged)"
            elif z_surv.get(zid,0): result=f"◆ {z_surv[zid]} lead(s)"
            elif z_ref.get(zid,0): result=f"✗ {z_ref[zid]} refuted"
            elif z_pend.get(zid,0): result=f"… {z_pend[zid]} pending"
            else: result="∅ empty"
        elif s=="failed": result="✗ no result (gap)"
        elif s=="abandoned": result="⚫ stopped mid-hunt (gap)"   # #1991
        else: result="— pending"
        _zopen=zone_open_rows(M, zid)
        zones_out.append({"id":zid,"status":s,"custody":bool(z.get("value_custody")),"result":result,
                          "open":_zopen,"checked":(s in ("hunted","hunted_empty") and _zopen==0)})
    # liveness — same pure classifier as page()
    fm,fp=freshest()
    age=(now-datetime.datetime.fromtimestamp(fm)).total_seconds() if fm else 9e9
    alive=proc_alive(); inflight,think=llm_child()
    dot,txt,colr,is_live,lcls=classify_liveness(exited, complete, alive, inflight, think, age)
    model={
        "label":LABEL, "prog":prog, "covered":covered, "failed":failed, "total":total_z,
        "complete":complete, "exited":exited, "pay_floor":(PAY_FLOOR or None),
        "banner":("DONE" if complete else ("STOPPED_INCOMPLETE" if exited else "RUNNING")),
        "phases":st,
        "phase_rows":M["phase_rows"],
        "open_rows":M["n_open"],
        "leads":leads_out,
        "leads_summary":{"total":len(G),"survived":n_surv,"refuted":n_ref,"pending":n_pend},
        "deep_rows":deep_out,
        "deep_mode":M["deep_mode"],
        "deep_summary":{"planned":sum(1 for r in DR if r["plan"] in ("selected","capped","unplanned")),
                        "checked":sum(1 for r in DR if r["checked"]),
                        "capped":sum(1 for r in DR if r["state"]=="capped"),
                        "findings":n_dh_find},
        "deep_state":deep_hunt_state(),
        "zones":zones_out,
        "verify_state":(dict(vs) if vs is not None else None),
        "adjudicated":len(A),
        "liveness":{"dot":dot,"text":txt,"col":colr,"is_live":is_live,"class":lcls,
                    "freshest":(os.path.relpath(fp, OUT) if fp else None),
                    "alive":alive,"inflight":inflight},
    }
    return model

# ---- M2 multi-hunt: registry discovery + overview grid -> per-hunt detail ---------------------------------
# The globals every reader above uses are re-pointed per hunt (apply_hunt); ThreadingHTTPServer would race on
# that, so the registry render path is serialized by _RENDER_LOCK. The M1 single-hunt path never mutates the
# globals after startup, so it needs no lock.
_RENDER_LOCK = threading.Lock()

def default_registry_dir():
    base = os.environ.get("DARK_FACTORY_DIR") or os.path.join(os.path.expanduser("~"), ".dark-factory")
    return os.path.join(base, "hunts")

def discover_hunts(registry_dir=None):
    # Best-effort read of the opt-in descriptor registry. Static metadata ONLY — liveness + artifacts are ALWAYS
    # re-derived live per request (never trusted from the descriptor). A missing/empty dir yields [] (a graceful
    # empty overview, never a crash); a malformed or id-less descriptor is skipped. Returns (descriptor, base-dir)
    # pairs so relative root/out/log paths resolve against each descriptor's own directory.
    rd = registry_dir or REGISTRY_DIR or default_registry_dir()
    try: names = sorted(os.listdir(rd))
    except OSError: return []
    out = []
    for name in names:
        if not name.endswith(".json"): continue
        p = os.path.join(rd, name)
        try:
            with open(p) as f: desc = json.load(f)
        except Exception: continue
        if not isinstance(desc, dict) or not desc.get("id"): continue
        out.append((desc, os.path.dirname(os.path.abspath(p))))
    return out

def apply_hunt(desc, base=None):
    # Point the module globals at one registry hunt, resetting the chrome first so a previous hunt's links/label
    # never leak into this one. Every reader (coverage/leads/deep_hunt/liveness) then works exactly as in M1.
    global ROOT, OUT, LOG, LABEL, REWARD_LINE, BOUNTY_URL, REPO_URL, PROJECT_URL, PAY_FLOOR, CUR_HUNT_ID
    ROOT = OUT = LOG = ""; LABEL = "hunt"; REWARD_LINE = BOUNTY_URL = REPO_URL = PROJECT_URL = PAY_FLOOR = ""
    CUR_HUNT_ID = desc.get("id", "")
    _apply_descriptor(desc)
    _resolve_paths(base)

def hunt_card(desc, base):
    # The compact overview-card model for one hunt — computed live from artifacts + process, reusing the SAME
    # phase/leads/deep/liveness helpers as the detail view so a card can never disagree with its own detail page.
    apply_hunt(desc, base)
    # #2298: the card's prog / FINISHED / green bar follow the SAME hunt_model() as the detail page.
    M = hunt_model()
    prog = M["prog"]; covered = M["covered"]; failed = M["failed"]; total_z = M["total_z"]
    L = M["L"]; exited = M["exited"]; complete = M["complete"]
    n_find = sum(1 for r in M["deep_rows"] if r["state"] == "finding")
    fm, _fp = freshest()
    age = (datetime.datetime.now() - datetime.datetime.fromtimestamp(fm)).total_seconds() if fm else 9e9
    alive = proc_alive(); inflight, think = llm_child()
    dot, txt, col, is_live, lcls = classify_liveness(exited, complete, alive, inflight, think, age)
    return {"id": desc.get("id", ""), "label": LABEL, "prog": prog,
            "covered": covered, "failed": failed, "total": total_z,
            "leads": len(L), "deep_findings": n_find, "complete": complete, "open_rows": M["n_open"],
            "bounty_url": BOUNTY_URL, "repo_url": REPO_URL,
            "liveness_class": lcls, "is_live": is_live, "dot": dot, "dot_col": col,
            "status_text": txt, "deep_state": deep_hunt_state()}

def default_change_summary():
    base = os.environ.get("DARK_FACTORY_DIR") or os.path.join(os.path.expanduser("~"), ".dark-factory")
    return os.path.join(base, "change-watch", "tick-summary.json")

def change_pipeline_model(path=None):
    # The M4 change-cadence panel model (#2135), read live from change-pipeline.sh's tick-summary JSON. Returns
    # None when the file is absent/unreadable/malformed (graceful no-panel, never a crash) so the overview is
    # unchanged on a host that never armed the cadence. Numeric fields are coerced defensively (a torn/partial
    # write mid-tick never raises); the nested budget block is flattened for the render. This is the SAME model
    # emit_model()/overview_model() and overview_page() both consume, so the JSON surface can't drift from the HTML.
    p = path or CHANGE_SUMMARY or default_change_summary()
    try:
        with open(p) as f: d = json.load(f)
    except Exception:
        return None
    if not isinstance(d, dict):
        return None
    def _i(k):
        try: return int(d.get(k, 0) or 0)
        except (TypeError, ValueError): return 0
    budget = d.get("budget") or {}
    if not isinstance(budget, dict): budget = {}
    def _bi(k):
        try: return int(budget.get(k, 0) or 0)
        except (TypeError, ValueError): return 0
    return {"summary_path": p,
            "last_tick": str(d.get("last_tick", "") or ""),
            "status": str(d.get("status", "") or ""),
            "changes_seen": _i("changes_seen"), "descriptors": _i("descriptors"),
            "hunts_run": _i("hunts_run"), "materialize_errors": _i("materialize_errors"),
            "findings_staged": _i("findings_staged"),
            "skipped": _i("skipped"), "ledger_total": _i("ledger_total"),
            "hunts_per_tick": _bi("hunts_per_tick"), "forge_max_slots": _bi("forge_max_slots"),
            "armed": bool(d.get("armed", False)), "tick_seq": _i("tick_seq")}

def overview_model(registry_dir=None):
    hunts = [hunt_card(d, b) for d, b in discover_hunts(registry_dir)]
    hunts.sort(key=lambda h: h["id"])
    return {"registry_dir": registry_dir or REGISTRY_DIR or default_registry_dir(),
            "count": len(hunts), "hunts": hunts,
            "change_pipeline": change_pipeline_model()}

def _card_bar_col(lcls):
    if lcls == "FINISHED": return "#39d353"
    if lcls in ("STOPPED", "PROCESS_GONE"): return "#e5737b"
    return "#f0a800"

_CP_STATUS_COL = {"ok": "#39d353", "quiet": "#8b949e", "running": "#f0a800", "error": "#e5737b"}

def _change_pipeline_panel(cp):
    # One full-width overview panel fed by the tick-summary (reuses the .hc card chrome so it "renders like a
    # hunt row"). Absent summary -> "" (no panel), matching the graceful-empty overview contract.
    if not cp:
        return ""
    col = _CP_STATUS_COL.get(cp["status"], "#8b949e")
    armed = ('<span style="color:#39d353">armed</span>' if cp["armed"]
             else '<span style="color:#8b949e" title="build/demo only — not scheduled; arm per the README">disarmed</span>')
    when = html.escape(cp["last_tick"] or "—")
    meta = (f'changes {cp["changes_seen"]} &nbsp;·&nbsp; {cp["descriptors"]} scoped &nbsp;·&nbsp; '
            f'{cp["hunts_run"]} hunt(s) &nbsp;·&nbsp; {cp["materialize_errors"]} mat-err &nbsp;·&nbsp; '
            f'{cp["findings_staged"]} staged &nbsp;·&nbsp; '
            f'{cp["skipped"]} skipped &nbsp;·&nbsp; ledger {cp["ledger_total"]}')
    budget = (f'budget {cp["hunts_per_tick"]}/tick &nbsp;·&nbsp; forge-slots {cp["forge_max_slots"]} '
              f'&nbsp;·&nbsp; tick #{cp["tick_seq"]} &nbsp;·&nbsp; {armed}')
    return (f'<div class="hc cpp" style="display:block">'
            f'<div class="hch"><span class="pulse" style="background:{col};box-shadow:0 0 8px {col};animation:none"></span>'
            f'<span class="hcl">change-cadence pipeline</span>'
            f'<span class="bl" style="cursor:default;color:{col}">{html.escape(cp["status"] or "—")}</span></div>'
            f'<div class="hcs" style="color:#8b949e">last tick {when}</div>'
            f'<div class="hcm">{meta}</div>'
            f'<div class="hcm" style="margin-top:2px">{budget}</div></div>')

def overview_page():
    m = overview_model(); hunts = m["hunts"]; now = datetime.datetime.now()
    cpanel = _change_pipeline_panel(m.get("change_pipeline"))
    if hunts:
        cardhtml = ""
        for h in hunts:
            _anim = "" if h["is_live"] else "animation:none;"
            dot = f'<span class="pulse" style="background:{h["dot_col"]};box-shadow:0 0 8px {h["dot_col"]};{_anim}"></span>'
            link = (f'<span class="bl" onclick="event.preventDefault();event.stopPropagation();window.open(this.dataset.u,\'_blank\',\'noopener\')" '
                    f'data-u="{html.escape(h["bounty_url"], quote=True)}" title="open the bounty program">🔗 bounty</span>'
                    if h["bounty_url"] else "")
            summary = (f'zones {h["covered"]}/{h["total"]} &nbsp;·&nbsp; {h["leads"]} leads'
                       + (f' &nbsp;·&nbsp; {h["deep_findings"]} deep FINDING' if h["deep_findings"] else "")
                       + (f' &nbsp;·&nbsp; <span style="color:#f0a800">{h["failed"]} errored</span>' if h["failed"] else "")
                       + (f' &nbsp;·&nbsp; <span style="color:#f0a800">{h["open_rows"]} open rows</span>'
                          if not h["complete"] and h["open_rows"] else ""))
            barcol = _card_bar_col(h["liveness_class"])
            cardhtml += (f'<a class="hc" href="?hunt={html.escape(h["id"], quote=True)}">'
                         f'<div class="hch">{dot}<span class="hcl">{html.escape(h["label"])}</span>{link}</div>'
                         f'<div class="hcbar"><div class="hcbf" style="width:{h["prog"]}%;background:{barcol}"></div>'
                         f'<div class="hcbl">{int(h["prog"])}%</div></div>'
                         f'<div class="hcs" style="color:{h["dot_col"]}">{html.escape(h["status_text"][:90])}</div>'
                         f'<div class="hcm">{summary}</div></a>')
        grid = f'<div class="hgrid">{cardhtml}</div>'
    else:
        grid = ('<div class="empty">No active hunts registered.<br><span style="color:#8b949e;font-size:13px">'
                f'Registry: <code>{html.escape(m["registry_dir"])}</code> — a hunt registers itself when this dir '
                'exists (create it to opt in); or open a single hunt with '
                '<code>hunt-dashboard.sh --descriptor &lt;file&gt;</code>.</span></div>')
    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="5">
<title>hunts · overview</title><style>
body{{background:#0d1117;color:#e8e8e8;font-family:-apple-system,Segoe UI,Roboto,sans-serif;margin:0;padding:24px}}
.wrap{{max-width:1100px;margin:auto}}
h1{{font-size:20px;margin:0 0 2px}} .sub{{color:#888;font-size:13px;margin-bottom:16px}}
.hgrid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:16px}}
@media(max-width:680px){{.hgrid{{grid-template-columns:1fr}}}}
.hc{{display:block;background:#161b22;border:1px solid #21262d;border-radius:10px;padding:14px;text-decoration:none;color:#e8e8e8;overflow:hidden}}
.hc:hover{{border-color:#30363d;background:#1a2029}}
.hch{{display:flex;align-items:center;gap:6px;margin-bottom:10px;flex-wrap:wrap}}
.hcl{{font-weight:600;font-size:15px;word-break:break-word;flex:1 1 auto}}
.bl{{color:#58a6ff;font-size:12px;cursor:pointer;white-space:nowrap}}
.hcbar{{background:#21262d;border-radius:6px;height:22px;overflow:hidden;position:relative;margin:6px 0}}
.hcbf{{height:100%;transition:width .4s;border-radius:6px}}
.hcbl{{position:absolute;inset:0;line-height:22px;text-align:center;font-weight:700;color:#0d1117;font-size:12px}}
.hcs{{font-size:12.5px;font-weight:600;margin-top:6px}}
.hcm{{color:#8b949e;font-size:12px;margin-top:4px}}
.cpp{{margin-bottom:16px}}
.empty{{background:#161b22;border:1px solid #21262d;border-radius:10px;padding:24px;color:#e8e8e8;font-size:15px}}
.pulse{{display:inline-block;width:9px;height:9px;border-radius:50%;flex:0 0 auto;animation:bl 1.4s ease-in-out infinite}}
@keyframes bl{{0%,100%{{opacity:1}}50%{{opacity:.25}}}}
code{{background:#21262d;padding:1px 5px;border-radius:4px;font-size:12px}}
a{{color:#58a6ff}}
</style></head><body><div class="wrap">
<h1>🎯 dark-factory hunts</h1>
<div class="sub">{m["count"]} registered hunt(s) · read-only · localhost:{PORT} · click a card for the full dashboard</div>
{cpanel}
{grid}
<div class="sub" style="margin-top:16px">auto-refresh 5s · {now.strftime('%H:%M:%S')} · registry {html.escape(m["registry_dir"])}</div>
</div></body></html>"""

def _detail_nav(cur_id):
    # The detail-view chrome: a `← overview` link + a compact switcher pill per registered hunt (current pill
    # highlighted). Reads only id/label from the registry (no per-hunt liveness recompute on a detail load).
    pills = ""
    for d, _b in discover_hunts():
        hid = d.get("id", ""); lbl = str(d.get("label", hid))
        style = ("background:#1f6feb33;border:1px solid #1f6feb;color:#58a6ff"
                 if hid == cur_id else "border:1px solid #30363d;color:#8b949e")
        pills += (f'<a href="?hunt={html.escape(hid, quote=True)}" style="{style};border-radius:10px;'
                  f'padding:2px 9px;font-size:12px;text-decoration:none;white-space:nowrap">{html.escape(lbl[:28])}</a>')
    return ('<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:12px">'
            '<a href="/" style="color:#58a6ff;text-decoration:none;font-size:13px;font-weight:600">← overview</a>'
            f'<span style="color:#30363d">|</span>{pills}</div>')

def _render_detail(hid):
    match = None
    for d, b in discover_hunts():
        if d.get("id") == hid: match = (d, b); break
    if match is None:
        return (f'<!doctype html><meta charset="utf-8"><body style="background:#0d1117;color:#e8e8e8;'
                f'font-family:sans-serif;padding:24px"><p><a href="/" style="color:#58a6ff">← overview</a></p>'
                f'<p>Hunt <code>{html.escape(hid)}</code> is not registered.</p></body>')
    nav = _detail_nav(hid)
    apply_hunt(match[0], match[1])
    return page(nav)

class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        try:
            if REGISTRY_MODE:
                hid = (parse_qs(urlparse(self.path).query).get("hunt") or [None])[0]
                with _RENDER_LOCK:
                    body = (_render_detail(hid) if hid else overview_page()).encode("utf-8")
            else:
                body = page().encode("utf-8")
        except Exception as e: body=f"<pre>dashboard error: {html.escape(str(e))}</pre>".encode()
        self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8")
        self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)

def _apply_descriptor(d):
    global ROOT, OUT, LOG, LABEL, REWARD_LINE, BOUNTY_URL, REPO_URL, PROJECT_URL, PAY_FLOOR
    if d.get("root"):  ROOT = d["root"]
    if d.get("out"):   OUT = d["out"]
    if d.get("log"):   LOG = d["log"]
    if d.get("label"): LABEL = d["label"]
    if d.get("reward_line"): REWARD_LINE = d["reward_line"]
    if d.get("bounty_url"):  BOUNTY_URL = d["bounty_url"]
    if d.get("repo_url"):    REPO_URL = d["repo_url"]
    if d.get("project_url"): PROJECT_URL = d["project_url"]
    if d.get("pay_floor"):   PAY_FLOOR = d["pay_floor"]

def _resolve_paths(base):
    # descriptor paths may be relative to the descriptor's own dir (the fixtures ship placeholder/relative
    # paths so no host-absolute path is ever checked in). Anchor them to `base` when not already absolute.
    global ROOT, OUT, LOG
    if base:
        if ROOT and not os.path.isabs(ROOT): ROOT = os.path.normpath(os.path.join(base, ROOT))
        if OUT  and not os.path.isabs(OUT):  OUT  = os.path.normpath(os.path.join(base, OUT))
        if LOG  and not os.path.isabs(LOG):  LOG  = os.path.normpath(os.path.join(base, LOG))
    # default OUT/LOG under ROOT when the descriptor gave only the root
    if ROOT and not OUT: OUT = os.path.join(ROOT, "zone-hunt-out")
    if ROOT and not LOG: LOG = os.path.join(ROOT, "hunt.log")

def main(argv=None):
    global ROOT, OUT, LOG, LABEL, REWARD_LINE, BOUNTY_URL, REPO_URL, PROJECT_URL, HOST, PORT
    global REGISTRY_MODE, REGISTRY_DIR, CHANGE_SUMMARY
    ap = argparse.ArgumentParser(description="Read-only, loopback-only hunt dashboard (#1913). "
                                             "Single-hunt with --descriptor/paths (M1); multi-hunt overview over "
                                             "the descriptor registry when given neither (M2).")
    ap.add_argument("--descriptor", help="hunt descriptor JSON (id/label/root/out/log + optional links/reward)")
    ap.add_argument("--root"); ap.add_argument("--out"); ap.add_argument("--log")
    ap.add_argument("--label"); ap.add_argument("--reward-line")
    ap.add_argument("--bounty-url"); ap.add_argument("--repo-url"); ap.add_argument("--project-url")
    ap.add_argument("--registry", action="store_true",
                    help="multi-hunt registry mode: serve an overview of every registered hunt (implied when no "
                         "--descriptor/--root is given)")
    ap.add_argument("--registry-dir", help="override the registry dir (default ${DARK_FACTORY_DIR:-~/.dark-factory}/hunts)")
    ap.add_argument("--change-summary", help="change-pipeline.sh tick-summary JSON for the M4 cadence panel "
                    "(default ${DARK_FACTORY_DIR:-~/.dark-factory}/change-watch/tick-summary.json)")
    ap.add_argument("--hunt", help="registry mode: render/emit ONE hunt's detail by id (offline test seam)")
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--port", type=int, default=int(os.environ.get("HUNT_DASHBOARD_PORT", PORT)))
    ap.add_argument("--render", action="store_true", help="emit the HTML once to stdout and exit (no server)")
    ap.add_argument("--emit-model", action="store_true", help="emit the computed facts as JSON and exit")
    a = ap.parse_args(argv)
    HOST = a.host; PORT = a.port
    if a.change_summary: CHANGE_SUMMARY = a.change_summary

    # Registry (multi-hunt) mode: explicit --registry/--registry-dir/--hunt, OR the bare invocation with no
    # single-hunt selector. A descriptor or --root always means the M1 single-hunt path (back-compat).
    registry = a.registry or bool(a.registry_dir) or bool(a.hunt) or (not a.descriptor and not a.root)
    if registry:
        REGISTRY_MODE = True
        REGISTRY_DIR = a.registry_dir or default_registry_dir()
        if a.emit_model:
            if a.hunt:
                m = None
                for d, b in discover_hunts():
                    if d.get("id") == a.hunt: apply_hunt(d, b); m = emit_model(); break
                if m is None: sys.stderr.write("hunt-dashboard: no such hunt id: %s\n" % a.hunt); return 4
                json.dump(m, sys.stdout, indent=2, sort_keys=True)
            else:
                json.dump(overview_model(), sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n"); return 0
        if a.render:
            sys.stdout.write(_render_detail(a.hunt) if a.hunt else overview_page()); return 0
        ThreadingHTTPServer((HOST, PORT), H).serve_forever()
        return 0

    # ---- M1 single-hunt path (unchanged) ----
    base = None
    if a.descriptor:
        with open(a.descriptor) as f: _apply_descriptor(json.load(f))
        base = os.path.dirname(os.path.abspath(a.descriptor))
    # explicit CLI flags override the descriptor
    if a.root: ROOT = a.root
    if a.out: OUT = a.out
    if a.log: LOG = a.log
    if a.label: LABEL = a.label
    if a.reward_line: REWARD_LINE = a.reward_line
    if a.bounty_url: BOUNTY_URL = a.bounty_url
    if a.repo_url: REPO_URL = a.repo_url
    if a.project_url: PROJECT_URL = a.project_url
    _resolve_paths(base)

    if a.emit_model:
        json.dump(emit_model(), sys.stdout, indent=2, sort_keys=True); sys.stdout.write("\n"); return 0
    if a.render:
        sys.stdout.write(page()); return 0
    ThreadingHTTPServer((HOST, PORT), H).serve_forever()
    return 0

if __name__ == "__main__":
    sys.exit(main())
