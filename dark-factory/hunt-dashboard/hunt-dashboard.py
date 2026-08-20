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

def _dh_refute_state(started):
    # Refute over the deep-hunt FINDINGs (human-triaged today via deep-hunt-adjudicated.tsv; #1938 automates
    # it). done = every deep-hunt finding is adjudicated-refuted (or there were none); run = an un-triaged
    # finding is still open; wait = the deep-hunt phase hasn't produced anything yet.
    dhall = deep_hunt()
    if not dhall: return "wait" if not started else "done"
    opens = [d for d in dhall if "FINDING" in d["verdict"] and (d.get("adj") or {}).get("verdict") != "REFUTED"]
    return "run" if opens else "done"

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
    adj = {}
    for line in read(os.path.join(ROOT, "deep-hunt-adjudicated.tsv")).splitlines():
        if not line.strip() or line.lstrip().startswith("#"): continue
        c = line.split("\t")
        if len(c) >= 4:
            adj[(c[0].strip(), c[1].strip())] = {"verdict": c[2].strip().upper(), "reason": c[3].strip()}
        elif len(c) >= 2:
            adj[(c[0].strip(), "*")] = {"verdict": c[1].strip().upper(), "reason": c[2].strip() if len(c) > 2 else ""}
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
        out.append({"slot": slot, "target": target, "cls": cls, "handler": handler,
                    "verdict": verdict, "steps": steps, "severity": vf.get(target, ""),
                    "adj": adj.get((target, cls)) or adj.get((target, "*"))})
    return out

def deep_hunt_state():
    # STAGE 4.5 has THREE distinct states the panel must not conflate (issue comment 5308547720): a DONE hunt on
    # a non-custody target with no composition seam REACHES 4.5 but routes 0 lenses (empty .deep-hunt-targets.tsv),
    # producing no invariant logs — which must NOT read as "not reached yet".
    #   not_reached       -> no deep-hunt/ dir (still in breadth).
    #   reached_no_lenses -> deep-hunt/ dir exists but no lens was routed (no slot dir, no non-empty targets tsv).
    #   ran               -> at least one lens slot exists (running/queued/verdict).
    dh = os.path.join(OUT, "deep-hunt")
    if not os.path.isdir(dh): return "not_reached"
    slot_dirs = [d for d in glob.glob(os.path.join(dh, "*")) if os.path.isdir(d)]
    tgt = os.path.join(OUT, ".deep-hunt-targets.tsv")
    targets_routed = any(l.strip() and not l.lstrip().startswith("#")
                         for l in read(tgt).splitlines()) if os.path.isfile(tgt) else False
    if not slot_dirs and not targets_routed: return "reached_no_lenses"
    return "ran"

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

def planned_deep_rows():
    # Client-side reconstruction of the STAGE 4.5 lens matrix (mirrors run-zone-hunt.sh lens_classes
    # gating) so the deep-hunt table can list PENDING/queued rows, not only completed slots. Best-effort:
    # the real gate owns the truth; this predicts the (zone, class) rows from map/zones.json.
    CUSTODY=("C6","C10","C11"); NONCUST=("C2","C16","C5"); IMPL=CUSTODY+NONCUST; MAXL=3
    try: zs=json.load(open(os.path.join(OUT,"map","zones.json")))
    except Exception: return []
    rows=[]
    for z in zs:
        classes=z.get("bug_classes_likely") or []
        dom=next((c for c in IMPL if c in classes),"C-invariant")
        lenses=[]
        if z.get("value_custody") or dom in NONCUST: lenses.append(dom)
        for c in NONCUST:
            if c in classes and c not in lenses: lenses.append(c)
        lenses=lenses[:MAXL]
        for c in lenses: rows.append((z.get("id"), c, z.get("value_custody", False)))
        if z.get("value_custody") and len(lenses)<MAXL and len([f for f in z.get("files",[]) if str(f).endswith(".sol")])>1:
            rows.append((z.get("id"), "SYS-solvency", True))
    return rows

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
        for root,_dirs,files in os.walk(rd):
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
    for root, _dirs, files in os.walk(cell):
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
    for root,_dirs,files in os.walk(OUT):
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
    best=None; found=False
    for c in _proc_glob():
        try: cl=open(c,"rb").read().replace(b"\x00",b" ").decode("utf-8","replace")
        except OSError: continue
        if _is_wrapper(cl): continue
        if ("agentis go " in cl) or ("flat-cyborg" in cl and "--tui" in cl):
            found=True
            if uptime is None: continue
            pid=c.split("/")[2]
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
    for root,_dirs,files in os.walk(OUT):   # walk sees hidden .gen-briefs/run/ that glob '**' skips
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
    return {"kind":kind,"zone":zone,"waited":waited,"stalled":stalled}

def phase_status():
    log = read(LOG); zs = coverage()
    total_z = len(zs) or 4
    # #1999: "exited" must mean the SAME thing here as in page() — the __EXIT__ marker AND no live hunt
    # process. A re-hunt appends fresh [M3] lines AFTER an earlier run's stale __EXIT__ marker, so keying
    # off the marker's mere presence would wrongly show the discovery phase as a "gap" while Zones (which
    # go through proc_alive) correctly show a zone in_flight. Gate both exit branches on liveness.
    hunt_live = proc_alive() or llm_child()[0]
    # covered = a zone that actually produced a verdict (clean or with leads).
    # failed  = HARNESS_ERROR: no verdict at all — a GAP, not a result. Never counts as hunted.
    covered = sum(1 for z in zs if z.get("status") in ("hunted","hunted_empty"))
    failed  = sum(1 for z in zs if z.get("status") == "failed")
    reached = covered + failed
    # DEEP-HUNT-ONLY mode (#1774): this run's log carries only [deep-hunt] lines — M1..M4 ran in the
    # PRIOR breadth run whose out we are layered on. Mark the breadth phases done from the prereq
    # artifacts (they must exist for --deep-hunt-only to start), and drive progress off the 4.5 slots.
    if ("[deep-hunt]" in log) and ("[M1]" not in log) and ("[M3]" not in log):
        exited = ("__EXIT__=" in log) and not hunt_live
        st = {"M1 · map zones":"done","M2 · briefs":"done","M3 · discovery":"done",
              "M4 · refute gate":"done",
              "4.5 · deep-hunt": "done" if exited else "run",
              "4.6 · refute deep-hunt": _dh_refute_state(True),
              "deliver · stage": "done" if exited else "wait"}
        dh_dirs = len([d for d in glob.glob(os.path.join(OUT,"deep-hunt","*")) if os.path.isdir(d)])
        dh_done = len(deep_hunt())
        prog = 100.0 if exited else round(100.0 * dh_done / max(1, dh_dirs), 1)
        return st, prog, covered, failed, total_z
    st = {}
    # A stage is "done" only once the NEXT stage's marker appears; while it is the latest marker
    # it is the one actually running (M2 briefs take minutes of LLM per zone, so this is the window
    # where nothing else has a marker yet — show 🔄 on it instead of a premature ✅ + no running row).
    st["M1 · map zones"] = "done" if "[M2]" in log else ("run" if "[M1]" in log else "wait")
    st["M2 · briefs"]    = "done" if "[M3]" in log else ("run" if "[M2]" in log else "wait")
    if ("__EXIT__=" in log) and not hunt_live:
        # The process exited — but "exited" is NOT "fully hunted". Only call the run
        # complete when every zone produced a verdict and none errored out. Otherwise
        # the coverage has holes and the bar must reflect them, not a green 100 %.
        complete = total_z > 0 and covered == total_z and failed == 0
        for name,_ in PHASES: st[name] = "done"
        if not complete:
            st["M3 · discovery"]  = "gap"
            st["4.5 · deep-hunt"] = "gap"
            st["deliver · stage"] = "gap"
        prog = 100.0 if complete else round(100.0 * covered / max(1, total_z), 1)
        return st, prog, covered, failed, total_z
    st["M3 · discovery"] = ("done" if reached>=total_z else "run") if "[M3]" in log else "wait"
    vs = verify_state()
    deep = bool(re.search(r"STAGE 4\.5|\[deep-hunt\]", log))
    # #2001: a phase shows "run" only when its work is LIVE right now — not merely because its marker appeared
    # once in the append-only log. A re-hunt re-enters discovery after a prior full pass, so the deep-hunt +
    # refute-deep markers persist while the actual deep-hunt cells sit idle (hours-stale) and only discovery is
    # working. Key the deep-hunt "run" state on active_deep_slot() (a deep cell writing within 90s AND a live
    # process), NOT on the mere presence of `deep`. Idle-but-ran => "done" (findings are listed below); the
    # normal live deep-hunt keeps active_deep_slot() truthy (cells heartbeat every ~4s) so it still reads "run".
    deep_live = active_deep_slot() is not None
    st["M4 · refute gate"] = ("done" if deep else ("run" if vs is not None else "wait"))
    st["4.5 · deep-hunt"]  = "run" if deep_live else ("done" if deep else "wait")
    _rf = _dh_refute_state(deep)
    # an idle backlog of un-triaged deep findings is NOT "running triage" — only call refute-deep "run" while
    # deep-hunt is genuinely live; otherwise its "run" (open findings) reads as "wait" (awaiting triage).
    st["4.6 · refute deep-hunt"] = _rf if deep_live else ("wait" if _rf == "run" else _rf)
    st["deliver · stage"]  = "run" if re.search(r"deliver-submission|PENDING-HUMAN-REVIEW", log) else "wait"
    prog = 0.0
    for name,w in PHASES:
        s = st.get(name,"wait")
        if s=="done": prog += w
        elif s=="run":
            if name=="M3 · discovery": prog += w*(reached/total_z)
            elif name=="M4 · refute gate" and vs is not None:
                prog += w*min(1.0, sum(vs.values())/max(1,len(leads())))
            else: prog += w*0.4
    return st, round(prog,1), covered, failed, total_z

def hms(td):
    s=int(td.total_seconds()); return f"{s//3600}h {s%3600//60:02d}m"

ICON={"done":"✅","run":"🔄","wait":"⬜","gap":"⚠️"}
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
    # Normalize an LLM-emitted class value (#1974/#1976): remove ALL whitespace FIRST (handles "c lass="
    # and "C 22"), strip the now-compact "class=" prefix, uppercase. No membership validation — class codes
    # are open-ended (C1..C23, SYS-solvency, C-invariant).
    return re.sub(r'(?i)^class=', '', re.sub(r'\s+', '', raw or '')).upper()
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
    st,prog,covered,failed,total_z = phase_status()
    zs=coverage(); L=leads(); vs=verify_state(); log=read(LOG); A=adjudicated()
    # "finished" requires BOTH the log's __EXIT__ marker AND no live hunt process — otherwise a --deep-hunt-resume
    # RE-RUN (its own log, but a real live process) would show a calm "finished" banner while the green dot pulses.
    hunt_live = proc_alive() or llm_child()[0]
    exited   = ("__EXIT__=" in log) and not hunt_live
    complete = exited and failed==0 and covered==total_z
    prows=""; _cur_group=None
    for name,w in PHASES:
        label,group = PHASE_META.get(name, (name, ""))
        if group != _cur_group:   # group header row — visually separates the breadth / depth / deliver tracks
            _cur_group = group
            prows+=(f'<tr><td></td><td colspan="2" style="color:#7d8590;font-size:11px;font-weight:600;'
                    f'letter-spacing:.06em;padding-top:8px;border-top:1px solid #21262d">{html.escape(group)}</td></tr>')
        s=st.get(name,"wait"); est=EST_MIN.get(name,0)
        if s=="gap": extra=f"{failed} zone(s) errored — not hunted"
        elif name=="M3 · discovery" and s=="run": extra=f"zone {covered}/{total_z}"
        elif name=="M4 · refute gate" and vs is not None: extra=f"{sum(vs.values())}/{len(L)} gate"
        elif name=="4.6 · refute deep-hunt":
            _dhf=[d for d in deep_hunt() if "FINDING" in d["verdict"]]
            _ref=sum(1 for d in _dhf if (d.get("adj") or {}).get("verdict")=="REFUTED")
            extra=(f"{_ref}/{len(_dhf)} triaged" if _dhf else ("∅ none" if s=="done" else f"~{est} min"))
        elif s=="done": extra="done"
        elif s=="run": extra="running"
        else: extra=f"~{est} min"
        col="#f0a800" if s=="gap" else ("#e8e8e8" if s!="wait" else "#888")
        prows+=f'<tr><td>{ICON[s]}</td><td style="color:{col};padding-left:10px">{html.escape(label)}</td><td style="color:#888;text-align:right">{extra}</td></tr>'
    zrows=""
    import collections as _cl
    # AXIS 2 inputs — the zone RESULT must agree with the panels below it:
    #  (a) discovery leads classified by their refute-gate verdict (not raw counts — a refuted lead is
    #      NOT an open lead), keyed by the zone id leads() tags (matches the coverage zid);
    #  (b) deep-hunt (4.5) FINDINGs per zone, carrying the finding's severity.
    RV=refute_verdicts()
    z_surv=_cl.Counter(); z_ref=_cl.Counter(); z_pend=_cl.Counter()
    for x in L:
        v=(RV.get(_normloc(x["loc"])) or {}).get("verdict","")
        if   v=="REFUTED":   z_ref[x["zone"]]+=1
        elif v=="CONFIRMED": z_surv[x["zone"]]+=1
        else:                z_pend[x["zone"]]+=1
    z_dh=_cl.Counter(); z_dhsev={}; z_dhref=_cl.Counter()
    for d in deep_hunt():
        if "FINDING" in d["verdict"]:
            zn=re.sub(r'-(C\d+|SYS-solvency)$','',d["slot"])
            if (d.get("adj") or {}).get("verdict")=="REFUTED":
                z_dhref[zn]+=1   # triaged false positive — not an open finding
            else:
                z_dh[zn]+=1; z_dhsev[zn]=d.get("severity","")
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
        zrows+=(f'<tr><td style="text-align:center">{ic}</td>'
                f'<td>{html.escape(zid)}{cust}</td>'
                f'<td style="color:{scol};font-weight:{w}">{slbl}</td>'
                f'<td style="color:{rcol};font-size:12px">{rlbl}</td></tr>')
    RV=refute_verdicts()
    def _rv(x): return RV.get(_normloc(x["loc"]))
    n_ref=sum(1 for x in L if (_rv(x) or {}).get("verdict")=="REFUTED")
    n_surv=sum(1 for x in L if (_rv(x) or {}).get("verdict")=="CONFIRMED")
    n_pend=len(L)-n_ref-n_surv
    pf_rank=_pay_floor_rank()   # #1960: resolved once; None ⇒ pay-floor marker OFF
    n_hidden=0   # #1966: sub-floor leads are hidden from the table, not badged; counted here
    # #1996: per-status tally for the LEADS filter chips — counts what is actually RENDERED (sub-floor rows
    # are skipped below, so they never inflate a chip). One shared Counter across breadth + depth so the
    # chip totals match the single unified table the operator filters. Buckets: confirmed (◆ survived a gate),
    # pending (gate undecided), refuted (✗ killed), other (clean / harness-gap — visible under "All" only).
    _stc=_cl.Counter()
    lrows=""
    for x in sorted(L,key=lambda a:(0 if ("High" in a["sev"] or "Crit" in a["sev"]) else 1)):
        if _is_unpayable(x["sev"], pf_rank):   # #1966: hide sub-floor rows, tally instead of rendering
            n_hidden += 1
            continue
        col=SEVCOL.get(x["sev"].split()[0] if x["sev"] else "","#ccc")
        rv=_rv(x); v=(rv or {}).get("verdict","")
        if v=="REFUTED":
            strike="text-decoration:line-through;"; rowop="opacity:.6"; st="refuted"
            vcell='<span style="color:#e5737b;font-weight:600">✗ REFUTED</span>'
            detail=f'<span style="color:#e5737b;font-size:12px">verified → not a bug: {html.escape(rv["reason"][:260])}</span>'
        elif v=="CONFIRMED":
            strike=""; rowop=""; st="confirmed"
            vcell='<span style="color:#39d353;font-weight:700">◆ SURVIVED → PoC</span>'
            detail=f'<span style="color:#bbb;font-size:12px">{html.escape(x["title"][:200])}</span>'
        else:
            strike=""; rowop=""; st="pending"
            vcell='<span style="color:#f0a800">… pending refute</span>'
            detail=f'<span style="color:#bbb;font-size:12px">{html.escape(x["title"][:200])}</span>'
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
    arows=""
    for x in A:
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
        banner=(f"⚠️ STOPPED INCOMPLETE — {failed} zone(s) errored (HARNESS_ERROR, no verdict); "
                f"only {covered}/{total_z} zones actually hunted. NOT fully covered.")
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
    DH = deep_hunt(); dh_dir = os.path.join(OUT, "deep-hunt")
    completed = {d["slot"]: d for d in DH}
    # full planned lens matrix (reconstructed) so pending/queued rows show too, not only completed slots
    order = []; seen = set(); slot_custody = {}
    for zone, cls, cust in planned_deep_rows():
        slot = f"{zone}-{cls}"
        slot_custody[slot] = cust
        if slot not in seen: order.append(slot); seen.add(slot)
    for slot in completed:            # safety: any completed slot the reconstruction didn't predict
        if slot not in seen: order.append(slot); seen.add(slot)
    def _rank(slot):                  # open FINDING > triaged-FP > clean/other > running > queued
        d = completed.get(slot)
        if d:
            if "FINDING" in d["verdict"] and (d.get("adj") or {}).get("verdict") != "REFUTED": return 0
            if "FINDING" in d["verdict"]: return 1
            return 2
        cs = deep_cell_status(slot)                # an abandoned cell ranks with the harness-error gaps (2),
        return {"running": 3, "abandoned": 2}.get(cs, 4)   # a live cell above queued (3), queued last (4)
    active = active_deep_slot()
    n_dh_find = 0; dhrows = ""
    for slot in sorted(order, key=_rank):
        d = completed.get(slot)
        m = re.match(r'^(.*)-(C\d+|SYS-solvency)$', slot)
        zid = m.group(1) if m else slot; clsname = m.group(2) if m else "?"
        strike = ""   # set on a triaged-FP row, applied to Sev/Class/Location — same look as a refuted LEAD
        # #depth-sev: a deep-hunt result row (FINDING/CLEAN/HARNESS/refuted) must ALWAYS show a severity.
        # Resolve it: (1) the normalized joined severity from verified_findings.json (drops any "severity="
        # prefix/whitespace); else (2) the zone's intrinsic custody severity; else (3) the program pay-floor
        # (a confirmed finding is at least payable-floor severity). A not-yet-run row (no d) keeps the queued
        # behaviour below (intrinsic custody or the em-dash) — never coerced to the floor.
        # Operator directive: EVERY DEPTH row shows a clearly-defined severity — the normalized joined
        # severity, else the zone's intrinsic custody severity, else the program pay-floor. Only a floor-less
        # program (no pay_floor in the descriptor) can leave a non-custody row without one (em-dash).
        sevtxt = (_norm_sev(d.get("severity", "") if d else "") or _intrinsic_sev(slot_custody.get(slot, False))
                  or (PAY_FLOOR.title() if PAY_FLOOR else ""))
        if slot == active:
            # this slot is re-executing RIGHT NOW — override only the VERDICT with in-progress. Sev is the
            # TARGET's severity class (intrinsic, known regardless of the re-run) — always show it, coloured.
            cls = d["cls"] if d else clsname
            loc = d["target"] if d else zid
            scol = SEVCOL.get(sevtxt.split()[0] if sevtxt else "", "#58a6ff")
            sev = (f'<span style="color:{scol};font-weight:600">{html.escape(sevtxt)}</span>' if sevtxt
                   else '<span style="color:#58a6ff">…</span>')
            gate = '<span style="color:#58a6ff;font-weight:600">🔄 re-running (in progress)</span>'
            detail = '<span style="color:#8b949e;font-size:12px">re-hunting with fitted fuzz budget — verdict pending</span>'
            rowop = ""; st = "pending"   # #1996: verdict undecided → pending bucket
        elif d:
            v = d["verdict"]; adj = d.get("adj") or {}
            cls = d["cls"]; loc = d["target"]
            scol = SEVCOL.get(sevtxt.split()[0] if sevtxt else "", "#ccc")
            if ("FINDING" in v or "VIOLAT" in v) and adj.get("verdict") == "REFUTED":
                # triaged false positive — IDENTICAL look to a refuted LEAD: severity in its OWN colour,
                # struck through (Sev/Class/Location), dimmed; the refuted status sits in the gate column.
                sev = f'<span style="color:{scol};font-weight:600;text-decoration:line-through">{html.escape(sevtxt or "?")}</span>'
                gate = '<span style="color:#e5737b;font-weight:600">✗ REFUTED (triaged FP)</span>'
                detail = f'<span style="color:#e5737b;font-size:12px">verified → not a bug: {html.escape(adj.get("reason", "")[:280])}</span>'
                rowop = "opacity:.6"; strike = "text-decoration:line-through;"; st = "refuted"   # #1996
            elif "FINDING" in v or "VIOLAT" in v:
                n_dh_find += 1
                sev = f'<span style="color:{scol};font-weight:600">{html.escape(sevtxt or "?")}</span>'
                gate = '<span style="color:#f0a800">◆ FINDING · pending forge PoC + triage</span>'
                detail = (f'<span style="color:#bbb;font-size:12px">multi-step invariant broken — shrunk witness '
                          f'({d["steps"]} steps); LLM-hypothesized invariant, verify before any submit</span>')
                rowop = ""; st = "confirmed"   # #1996: ◆ survived the fuzz gate → confirmed lead bucket
            elif "CLEAN" in v:
                # no bug confirmed on this High-value surface — struck through, like a refuted lead. The Sev
                # is the TARGET's severity class (intrinsic, same as a LEAD keeps its Sev when refuted).
                sev = f'<span style="color:{scol};font-weight:600;text-decoration:line-through">{html.escape(sevtxt or "?")}</span>'
                gate = '<span style="color:#8a94a0;font-size:12px">∅ clean (held in budget)</span>'
                detail = ('<span style="color:#8a94a0;font-size:12px">every deep invariant held across the fuzzed '
                          'search (not a proof of safety)</span>')
                rowop = "opacity:.6"; strike = "text-decoration:line-through;"; st = "other"   # #1996: clean, no open lead
            else:
                # HARNESS_ERROR — a coverage GAP (not "no bug", so NOT struck), but the target still carries
                # its severity class; the gap is flagged amber in the gate column.
                sev = f'<span style="color:{scol};font-weight:600">{html.escape(sevtxt or "?")}</span>'
                gate = '<span style="color:#f0a800;font-size:12px">⚠ harness error — no verdict</span>'
                detail = '<span style="color:#f0a800;font-size:12px">harness error is not a verdict — a coverage gap</span>'
                rowop = "opacity:.6"; st = "other"   # #1996: coverage gap, not an open lead
        else:
            cls = clsname; loc = zid   # exact target file is only known once the row runs
            sevtxt = _intrinsic_sev(slot_custody.get(slot, False)) or (PAY_FLOOR.title() if PAY_FLOOR else "")
            if sevtxt:
                scol = SEVCOL.get(sevtxt, "#5a6270")
                sev = f'<span style="color:{scol};font-weight:600">{html.escape(sevtxt)}</span>'
            else:
                sev = '<span style="color:#5a6270">—</span>'
            _cs = deep_cell_status(slot)
            if _cs == "running":
                gate = '<span style="color:#58a6ff">🔄 fuzzing…</span>'
                detail = '<span style="color:#8b949e;font-size:12px">opus generating handler + stateful fuzzing</span>'
                rowop = ""; st = "pending"   # #1996: in progress → pending
            elif _cs == "abandoned":
                # dir exists but silent — the cell was force-advanced or its session died: a coverage GAP,
                # rendered like a harness_error (amber, dimmed), NOT a perpetual "fuzzing…".
                gate = '<span style="color:#f0a800;font-size:12px">⚠ harness error — no verdict</span>'
                detail = '<span style="color:#f0a800;font-size:12px">deep-hunt cell ended without a verdict — a coverage gap</span>'
                rowop = "opacity:.6"; st = "other"   # #1996: coverage gap
            else:
                gate = '<span style="color:#6e7681">⬜ queued</span>'
                detail = '<span style="color:#6e7681;font-size:12px">planned lens row — not yet run</span>'
                rowop = "opacity:.5"; st = "pending"   # #1996: not yet run → pending
        dh_unpay = _is_unpayable(sevtxt, pf_rank)   # #1960: sevtxt is defined in every branch above
        if dh_unpay:   # #1966: hide sub-floor rows, tally instead of rendering
            n_hidden += 1
            continue
        _stc[st]+=1   # #1996: count the RENDERED deep row into its filter bucket
        dhrows += (f'<tr data-st="{st}" style="{rowop}"><td style="white-space:nowrap">{_type_badge("DEPTH")}</td>'
                   f'<td title="{_title_attr(_sev_title(sevtxt))}" style="white-space:nowrap;cursor:help">{sev}</td>'
                   f'<td title="{_title_attr(_cls_title(cls))}" style="color:#9fd;cursor:help;{strike}">{html.escape(cls)}</td>'
                   f'<td style="font-family:monospace;font-size:12px;{strike}"><span title="stable finding id — cite this" style="color:#8a94a0;font-weight:600">{_finding_id(loc, cls)}</span>&nbsp;{html.escape(loc)}</td>'
                   f'<td style="white-space:nowrap">{gate}</td>'
                   f'<td>{detail}</td></tr>')
    # STAGE 4.5 three-state annotation (issue comment 5308547720): distinguish "not reached yet" from "reached
    # but 0 lenses routed" so a DONE non-custody hunt never contradicts the finished banner with a false
    # "not reached". Only annotate when the depth track has NO rows to show (else the rows themselves are the state).
    _dh_state = deep_hunt_state()
    if not order and _dh_state == "not_reached":
        _dh_note = ' &nbsp;·&nbsp; <span style="color:#8b949e">STAGE 4.5 not reached yet (still in breadth)</span>'
    elif not order and _dh_state == "reached_no_lenses":
        _dh_note = (' &nbsp;·&nbsp; <span style="color:#f0a800" title="STAGE 4.5 ran but the zone is not '
                    'value-custody and no composition seam was detected, so no deep-hunt/composable-solvency lens '
                    'applied">STAGE 4.5 reached — 0 lenses routed (not value-custody, no composition seam)</span>')
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
    # #1999: the "confirmed" bucket is labelled "Survived", NOT "Confirmed" — a lead here has SURVIVED its
    # gate (refute for breadth, invariant-fuzz for depth) but is still PENDING a forge PoC + triage; it is
    # NOT PoC-verified. Only a hand-written PoC (tracked off-dashboard) confirms exploitability. The tuple's
    # 4th field is an optional chip tooltip. data-sel/data-st stays "confirmed" (internal key; the filter and
    # test key on it) — only the human-facing label changed.
    _chipdefs=[("all","All",sum(_stc.values()),""),
               ("confirmed","Survived",_stc.get("confirmed",0),
                "survived its gate (refute / invariant-fuzz) — pending forge PoC + triage; NOT yet PoC-verified"),
               ("pending","Pending",_stc.get("pending",0),""),
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
<div class="barwrap"><div class="bar"></div><div class="barlabel">{prog:.0f}%</div></div>
<div class="sub">running {hms(elapsed)} · start {start.strftime('%H:%M')} · {('DONE' if complete else f'STOPPED — {failed} gap(s), needs re-hunt') if exited else 'ETA to verdict ~2–3h (deep-hunt is the wildcard)'}</div>
<div class="grid">
<div class="card"><h2>Phases</h2><table>{prows}</table></div>
<div class="card"><h2>Zones ({covered}/{total_z} hunted{f' · {failed} errored' if failed else ''})</h2><table><tr style="color:#7d8590;font-size:11px"><td></td><td>Zone</td><td>State</td><td>Result</td></tr>{zrows}</table></div>
</div>
<div class="card" style="margin-top:20px"><h2>LEADS &nbsp;<span style="font-weight:400;font-size:12px;color:#7d8590">breadth {len(L)} ({n_surv} survived · {n_ref} refuted · {n_pend} pending) &nbsp;·&nbsp; depth {len(completed)}/{len(order)} lens rows{f' · {n_dh_find} FINDING' if n_dh_find else ''}{_dh_note}</span></h2>{chipbar}<table id="leadtbl">
<tr style="color:#7d8590"><td>Type</td><td>Sev</td><td>Class</td><td>Location</td><td>Refute gate</td><td>Detail</td></tr>{lrows}{dhrows}{hidden_row}</table></div>
{('<div class="card" style="margin-top:16px"><h2>Adjudicated — verified, NOT a bug (' + str(len(A)) + ') · removed from refute queue</h2><table><tr style="color:#7d8590"><td>Sev</td><td>Class</td><td>Location</td><td>Verdict</td></tr>' + arows + '</table></div>') if A else ''}
<div class="meta">auto-refresh 10s · {now.strftime('%H:%M:%S')} · localhost:{PORT}</div>
</div>{filter_js}</body></html>"""

def emit_model():
    # Deterministic assertion surface (NOT rendered by the browser): the computed facts as JSON, so the
    # offline demo can pin the load-bearing model without a /proc scan or HTML scraping. Uses the SAME helper
    # functions + the SAME pure liveness classifier as page(), so the two never disagree.
    now=datetime.datetime.now()
    st,prog,covered,failed,total_z = phase_status()
    zs=coverage(); L=leads(); vs=verify_state(); log=read(LOG); A=adjudicated()
    hunt_live = proc_alive() or llm_child()[0]
    exited   = ("__EXIT__=" in log) and not hunt_live
    complete = exited and failed==0 and covered==total_z
    RV=refute_verdicts()
    def _rv(x): return RV.get(_normloc(x["loc"]))
    pf_rank=_pay_floor_rank()   # #1960: resolved once; None ⇒ every `unpayable` is False
    # breadth leads
    leads_out=[]; n_ref=n_surv=n_pend=0
    for x in L:
        v=(_rv(x) or {}).get("verdict","")
        if   v=="REFUTED":   state="REFUTED"; n_ref+=1
        elif v=="CONFIRMED": state="CONFIRMED"; n_surv+=1
        else:                state="PENDING"; n_pend+=1
        leads_out.append({"id":_finding_id(x["loc"], x["cls"]),"loc":x["loc"],"cls":x["cls"],"sev":x["sev"],
                          "sev_claimed":x.get("sev_claimed",x["sev"]),"overclaim":bool(x.get("overclaim")),
                          "verdict":state,
                          "struck":state=="REFUTED","unpayable":_is_unpayable(x["sev"], pf_rank)})
    # deep rows — the reconstructed matrix + verdict per slot (mirrors the render branches)
    DH=deep_hunt(); dh_dir=os.path.join(OUT,"deep-hunt")
    completed={d["slot"]:d for d in DH}
    order=[]; seen=set(); slot_custody={}
    for zone,cls,cust in planned_deep_rows():
        slot=f"{zone}-{cls}"
        slot_custody[slot]=cust
        if slot not in seen: order.append(slot); seen.add(slot)
    for slot in completed:
        if slot not in seen: order.append(slot); seen.add(slot)
    active=active_deep_slot()
    deep_out=[]; n_dh_find=0
    for slot in order:
        d=completed.get(slot); adj=(d.get("adj") if d else None) or {}
        # #depth-sev: same resolution as page() — a result row (has d) resolves normalized-join / intrinsic
        # custody / pay-floor so it never emits an empty severity; a not-yet-run row keeps intrinsic-or-empty.
        _sv = (_norm_sev(d.get("severity","") if d else "") or _intrinsic_sev(slot_custody.get(slot, False))
               or (PAY_FLOOR.title() if PAY_FLOOR else ""))
        if slot==active:
            state="rerunning"; struck=False; sev=_sv
        elif d:
            v=d["verdict"]; sev=_sv
            if ("FINDING" in v or "VIOLAT" in v) and adj.get("verdict")=="REFUTED":
                state="triaged_fp"; struck=True
            elif "FINDING" in v or "VIOLAT" in v:
                state="finding"; struck=False; n_dh_find+=1
            elif "CLEAN" in v:
                state="clean"; struck=True
            else:
                state="harness_error"; struck=False
        else:
            sev=_sv
            # #deep-cell-stale: a dir alone is not "running" — a killed/hung cell leaves a silent dir behind.
            _cs = deep_cell_status(slot)
            if _cs == "running": state="running"; struck=False
            elif _cs == "abandoned": state="harness_error"; struck=False   # coverage gap, not perpetual running
            else: state="queued"; struck=False
        m=re.match(r'^(.*)-(C\d+|SYS-solvency)$', slot)
        cls=(d["cls"] if d else (m.group(2) if m else "?"))
        loc=(d["target"] if d else (m.group(1) if m else slot))
        deep_out.append({"id":_finding_id(loc, cls),"slot":slot,"cls":cls,"loc":loc,"severity":sev,"state":state,"struck":struck,
                         "unpayable":_is_unpayable(sev, pf_rank)})
    # zones — the Result label that must agree with the LEADS table
    import collections as _cl
    z_surv=_cl.Counter(); z_ref=_cl.Counter(); z_pend=_cl.Counter()
    for x in L:
        v=(_rv(x) or {}).get("verdict","")
        if   v=="REFUTED":   z_ref[x["zone"]]+=1
        elif v=="CONFIRMED": z_surv[x["zone"]]+=1
        else:                z_pend[x["zone"]]+=1
    z_dh=_cl.Counter(); z_dhsev={}; z_dhref=_cl.Counter()
    for d in DH:
        if "FINDING" in d["verdict"]:
            zn=re.sub(r'-(C\d+|SYS-solvency)$','',d["slot"])
            if (d.get("adj") or {}).get("verdict")=="REFUTED": z_dhref[zn]+=1
            else: z_dh[zn]+=1; z_dhsev[zn]=d.get("severity","")
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
        zones_out.append({"id":zid,"status":s,"custody":bool(z.get("value_custody")),"result":result})
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
        "leads":leads_out,
        "leads_summary":{"total":len(L),"survived":n_surv,"refuted":n_ref,"pending":n_pend},
        "deep_rows":deep_out,
        "deep_summary":{"planned":len(order),"completed":len(completed),"findings":n_dh_find},
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
    st, prog, covered, failed, total_z = phase_status()
    L = leads(); DH = deep_hunt(); log = read(LOG)
    n_find = sum(1 for d in DH if "FINDING" in d["verdict"] and (d.get("adj") or {}).get("verdict") != "REFUTED")
    hunt_live = proc_alive() or llm_child()[0]
    exited = ("__EXIT__=" in log) and not hunt_live
    complete = exited and failed == 0 and covered == total_z
    fm, _fp = freshest()
    age = (datetime.datetime.now() - datetime.datetime.fromtimestamp(fm)).total_seconds() if fm else 9e9
    alive = proc_alive(); inflight, think = llm_child()
    dot, txt, col, is_live, lcls = classify_liveness(exited, complete, alive, inflight, think, age)
    return {"id": desc.get("id", ""), "label": LABEL, "prog": prog,
            "covered": covered, "failed": failed, "total": total_z,
            "leads": len(L), "deep_findings": n_find,
            "bounty_url": BOUNTY_URL, "repo_url": REPO_URL,
            "liveness_class": lcls, "is_live": is_live, "dot": dot, "dot_col": col,
            "status_text": txt, "deep_state": deep_hunt_state()}

def overview_model(registry_dir=None):
    hunts = [hunt_card(d, b) for d, b in discover_hunts(registry_dir)]
    hunts.sort(key=lambda h: h["id"])
    return {"registry_dir": registry_dir or REGISTRY_DIR or default_registry_dir(),
            "count": len(hunts), "hunts": hunts}

def _card_bar_col(lcls):
    if lcls == "FINISHED": return "#39d353"
    if lcls in ("STOPPED", "PROCESS_GONE"): return "#e5737b"
    return "#f0a800"

def overview_page():
    m = overview_model(); hunts = m["hunts"]; now = datetime.datetime.now()
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
                       + (f' &nbsp;·&nbsp; <span style="color:#f0a800">{h["failed"]} errored</span>' if h["failed"] else ""))
            barcol = _card_bar_col(h["liveness_class"])
            cardhtml += (f'<a class="hc" href="?hunt={html.escape(h["id"], quote=True)}">'
                         f'<div class="hch">{dot}<span class="hcl">{html.escape(h["label"])}</span>{link}</div>'
                         f'<div class="hcbar"><div class="hcbf" style="width:{h["prog"]}%;background:{barcol}"></div>'
                         f'<div class="hcbl">{h["prog"]:.0f}%</div></div>'
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
.empty{{background:#161b22;border:1px solid #21262d;border-radius:10px;padding:24px;color:#e8e8e8;font-size:15px}}
.pulse{{display:inline-block;width:9px;height:9px;border-radius:50%;flex:0 0 auto;animation:bl 1.4s ease-in-out infinite}}
@keyframes bl{{0%,100%{{opacity:1}}50%{{opacity:.25}}}}
code{{background:#21262d;padding:1px 5px;border-radius:4px;font-size:12px}}
a{{color:#58a6ff}}
</style></head><body><div class="wrap">
<h1>🎯 dark-factory hunts</h1>
<div class="sub">{m["count"]} registered hunt(s) · read-only · localhost:{PORT} · click a card for the full dashboard</div>
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
    global REGISTRY_MODE, REGISTRY_DIR
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
    ap.add_argument("--hunt", help="registry mode: render/emit ONE hunt's detail by id (offline test seam)")
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--port", type=int, default=int(os.environ.get("HUNT_DASHBOARD_PORT", PORT)))
    ap.add_argument("--render", action="store_true", help="emit the HTML once to stdout and exit (no server)")
    ap.add_argument("--emit-model", action="store_true", help="emit the computed facts as JSON and exit")
    a = ap.parse_args(argv)
    HOST = a.host; PORT = a.port

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
