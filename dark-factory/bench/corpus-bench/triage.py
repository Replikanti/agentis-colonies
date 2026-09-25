#!/usr/bin/env python3
# triage.py — per-row TRIAGE of a held-out run against ground truth (issue #2262 M1).
#
# The scoreboards (score-match.py, generation-recall.sh) answer "how many rows HIT"; they cannot answer the
# question every held-out exam actually needs per rare row: *did the pipeline FIND this bug, and if not, WHERE
# did it lose it?* That was answered by hand — read the truth row, look for candidates and verified findings at
# the same function, grep the cell logs for the function, read the DISMISS lines and the refute verdicts,
# decide HIT / MISS and the MISS cause — at hours per run and with nothing anyone else could reproduce. This
# tool mechanises the READING, never the decision: for every truth row it collects the evidence at the row's
# location and PROPOSES a class with the evidence lines next to it. The operator confirms in the
# `operator_class` column. The tool never claims a HIT on its own: its strongest class is `HIT-candidate`.
#
# WHAT "AT THE LOCATION" MEANS. Exactly the #2215 pair-exact rule the scoreboard uses: the row's anchors come
# from truth.tsv column 6 through score-match.py's OWN parse_row_locations(), and every candidate / verified /
# DISMISS / INVARIANT location is resolved with score-match.py's lead_location() + lead_matches_locations()
# and hypotheses-to-leads.py's bare_codefile(). Those three functions are IMPORTED read-only (importlib, no
# bytecode written) — neither frozen scorer is edited and the pair rule is not re-implemented here.
# When column 6 is empty or absent, a deterministic KEYWORD FALLBACK derives anchors from title + signature:
#   * `keyword-pair` — PascalCase-qualified references (`Contract::fn`, `Contract.sol::fn`, `Contract.fn(`)
#     become (Contract.sol, fn) pairs;
#   * `keyword-fn`   — otherwise, backticked `fn(` call tokens become FUNCTION-ONLY anchors (any file), minus a
#     small stoplist (require/revert/emit/abi/keccak256 and the ERC20 verbs such as transfer/approve).
# A row with neither is `unanchored` and is never guessed.
#
# WHAT IS READ — and, load-bearing, what is NOT. Every RUN dir holds source COPIES of the agents (`hunter.ag`,
# `refuter.ag`) carrying the very sentinel literals this tool looks for, so a tree-wide grep would invent
# evidence. The readers are therefore restricted to real OUTPUT files:
#   a. discovery/discovery-results.merged.json   cells[].candidates[] + top-level tier2[] (tier 2)
#   b. verify/verified_findings.json             verified[] (any source: breadth, invariant-hunt, vector-hunt),
#                                                refuted[], out_of_scope[], errors[], tier2[] verdicts
#   c. verify/gates*/<n>_*/                      candidate.manifest (field 1 = location), verdict.txt, and
#                                                `REFUTE-GROUND|` lines ONLY from refute-out/run/refute_*.log
#   d. discovery/<zone>/run/hunt_*.log*          the cell logs and their text companions
#                                                (`.untraced-attempt-<n>`, `.rubric-attempt-<n>`): DISMISS| lines
#                                                at an anchor + word-boundary mentions of the anchor function
#                                                (TRACE| / READ| / OPCHECK| / CANDIDATE| lines preferred as
#                                                evidence). Cell status comes from the `.timeout` / `.novalid`
#                                                marker files next to each log (an `.untraced` marker is a
#                                                metric, never a failure).
#   e. deep-hunt/*/run/invariant_*.log           `INVARIANT|<file:fn>|<verdict>` lines
# A superseded `discovery/<zone>.attempt-<n>/` dir (moved aside by a `--rehunt-gaps` pass) is EXCLUDED unless
# `--include-superseded` is given, and is then labelled `superseded` in every evidence line it contributes.
#
# PROPOSED CLASS — the first match wins, over the strongest evidence across all anchors of the row:
#   0. unanchored        no column-6 anchor and no keyword anchor (checked first: nothing can match it).
#   1. HIT-candidate     level=verified   a verified[] entry at an anchor;
#                        level=unassessed failing that, a tier-1 candidate at an anchor whose gate did NOT
#                                         refute it (REAL but not kept, ERROR, skipped, or no gate at all);
#                        level=tier2      failing that, an unrefuted tier-2 record at an anchor.
#   2. refuted           candidates exist at an anchor and EVERY one was refuted (a non-confirm gate verdict,
#                        refuted[] or out_of_scope[]); evidence = the verdict reason + that gate's REFUTE-GROUND|.
#   3. found-dismissed   a DISMISS| line at an anchor and no candidate.
#   4. scope-out-of-map  sub=file: no anchor basename appears in any zone's files[];
#                        sub=slice: every scope.tsv line for the anchor file is sliced (`file@fn+fn`) and none
#                        lists the function, AND an owning zone ran, AND no cell log / INVARIANT| target
#                        mentions it (the slicer's same-file callee closure, #2150, pulls unlisted internal
#                        helpers into the payload, so a mentioned function was visibly in scope — and a zone
#                        that never answered cannot show that it was not).
#   5. unmeasured        no owning zone was measured: it has no run tree, it is named by --unmeasured, or every
#                        one of its cells failed (.timeout / .novalid). A zone that did not run must never read
#                        as a generation miss.
#   6. generation        an owning zone ran and nothing above matched. sub=examined when a cell log or an
#                        INVARIANT| target (ANY verdict — a CLEAN invariant at the location is a generation
#                        examination, not a HIT) mentions the function; sub=unseen otherwise.
# Every class is a PROPOSAL and, like the #2215 anchors, MECHANISM-BLIND: a name-coincident candidate at an
# anchored location proposes HIT-candidate all the same. The markdown never prints a recall number.
#
# Usage:
#   triage.py --truth <truth.tsv> (--run [LABEL=]<zone-hunt-out> ... | --run-root <dir>) [--map|--zones-json
#             <zones.json>] [--scope <scope.tsv>] [--unmeasured <zone_id>:<reason>]... [--contest <id>
#             --corpus <corpus.tsv>] [--rare-max N] [--rows all|rare | --rare-only] [--max-evidence K]
#             [--include-superseded] [--tsv <out>] [--md <out>] [--out <dir>]
#   triage.py --self-test
#   --run [LABEL=]<dir>  one run-zone-hunt.sh output tree (the dir holding discovery/); repeatable. The label
#                        defaults to the dir's basename (its parent's for a dir named zone-hunt-out).
#   --run-root <dir>     every run tree (a dir holding discovery/) found below <dir>, e.g. an exam root's
#                        arms/<contest>/ with <zone>/<arm>-r<N>/<contest>/zone-hunt-out trees; each is labelled
#                        with its path relative to <dir> (a trailing /zone-hunt-out dropped). Symlinks are not
#                        followed. Combinable with --run.
#   --map <zones.json>   the FULL frozen zones.json (its files[]); alias --zones-json. Default: the union of the
#                        run trees' own map/zones.json, with a header note (a staged single-zone map under-
#                        reports scope-out-of-map and unmeasured).
#   --scope <scope.tsv>  field 3 may be sliced `file@fn+fn`. Default: scope.tsv next to --map when present,
#                        else the union of the run trees' own map/scope.tsv.
#   --unmeasured Z:R     force zone Z to unmeasured with reason R (e.g. a VOID run); repeatable.
#   --contest/--corpus   print the #2231 `role=` of <id> from corpus.tsv column 5 (dev = IN-DISTRIBUTION).
#   --rare-max N         rarity (watson count) at or below which a row is `rare` (default 2); mid = up to 8,
#                        consensus = 9+ (the scorer's strata).
#   --rows all|rare      which rows to emit (default all); --rare-only = --rows rare.
#   --max-evidence K     evidence lines per row in the markdown (default 5).
#   --tsv / --md <file>  write the TSV / markdown there; --out <dir> writes <dir>/triage.tsv + triage.md. With
#                        no output option the markdown goes to stdout.
# Output: TSV columns `sev_id severity rarity tier anchor_source anchors proposed sub level verified candidates
#   refuted dismissed mentions zones top_evidence operator_class` (operator_class left empty for the operator);
#   markdown = ruler line + notes + the PROPOSAL banner + per-class counts (all rows and the rare tier) + the
#   table `| row | sev | rarity | anchors | proposed | evidence | operator |`. Deterministic: rows in truth.tsv
#   order, evidence sorted by kind priority then label / path / line. Every path printed is RELATIVE to its run
#   tree; no absolute path is ever written.
# Exit: 0 ran (or --self-test held); 1 --self-test regressed; 2 bad args; 3 unreadable or wrong-shape input
#   (including the 4-column CodeHawks truth shape, which is not supported).
import sys
import os
import re
import json
import shutil
import tempfile
import importlib.util

sys.dont_write_bytecode = True  # importing the frozen scorers must not drop a __pycache__ into the repo

HERE = os.path.dirname(os.path.abspath(__file__))


def die(rc, msg):
    sys.stderr.write("triage.py: " + msg + "\n")
    sys.exit(rc)


def _load(modname, fname):
    path = os.path.join(HERE, fname)
    spec = importlib.util.spec_from_file_location(modname, path)
    if spec is None or spec.loader is None:
        die(3, "cannot import " + fname)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_SCORE = _load("_triage_score_match", "score-match.py")
_H2L = _load("_triage_hypotheses_to_leads", "hypotheses-to-leads.py")
parse_row_locations = _SCORE.parse_row_locations
lead_location = _SCORE.lead_location
lead_matches_locations = _SCORE.lead_matches_locations
bare_codefile = _H2L.bare_codefile

CLASSES = ("HIT-candidate", "refuted", "found-dismissed", "scope-out-of-map", "unmeasured", "generation",
           "unanchored")
CONFIRM_TOKENS = ("REAL", "FINDING", "COUNTEREXAMPLE")  # verify-findings.sh CONFIRM_TOKEN per gate
KIND_PRIO = {
    "verified": 0, "candidate": 1, "tier2": 2, "gate": 3, "refute-ground": 4, "out-of-scope": 5,
    "refuted": 6, "error": 7, "dismiss": 8, "invariant": 9, "mention": 10,
}
PREFERRED_MENTION = ("TRACE|", "READ|", "OPCHECK|", "CANDIDATE|")
STOP_FNS = {
    "require", "revert", "emit", "abi", "keccak256", "assert", "encode", "encodepacked", "encodewithselector",
    "decode", "type", "address", "payable", "transfer", "transferfrom", "approve", "balanceof", "allowance",
    "totalsupply", "decimals", "safetransfer", "safetransferfrom", "safeapprove", "forceapprove",
    "safeincreaseallowance", "safedecreaseallowance",
}
STOP_QUALIFIERS = {"safeerc20", "ierc20", "erc20", "math", "safemath", "safecast", "address", "strings", "ecdsa"}
TSV_COLS = ("sev_id", "severity", "rarity", "tier", "anchor_source", "anchors", "proposed", "sub", "level",
            "verified", "candidates", "refuted", "dismissed", "mentions", "zones", "top_evidence",
            "operator_class")
PRUNE_DIRS = {"code", "judging", "node_modules", "lib", "map", "briefs", ".git", ".agentis"}
TEXT_MAX = 200

_QUAL_RE = re.compile(
    r"(?<![A-Za-z0-9_])([A-Z][A-Za-z0-9_]*)(?:\.sol)?(?:::([A-Za-z_][A-Za-z0-9_]*)|\.([A-Za-z_][A-Za-z0-9_]*)\s*\()")
_TICK_RE = re.compile(r"`([^`\n]{1,300})`")
_CALL_RE = re.compile(r"(?<![A-Za-z0-9_])([a-z_][A-Za-z0-9_]*)\s*\(")
_ATTEMPT_RE = re.compile(r"\.attempt-[0-9]+$")


# ----------------------------------------------------------------------------------------------------------------
# small helpers
# ----------------------------------------------------------------------------------------------------------------
def clean(text):
    s = " ".join(str(text or "").replace("\t", " ").replace("\r", " ").split())
    if len(s) > TEXT_MAX:
        s = s[:TEXT_MAX - 3] + "..."
    return s


def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().splitlines()
    except OSError:
        return None


def read_json(path, notes, label, rel):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return json.load(fh)
    except OSError:
        return None
    except ValueError:
        notes.append("%s: %s is not valid JSON (unreadable, treated as absent)" % (label, rel))
        return None


def loc_key(location):
    """(basename_lower, function) of a location string, via the scoreboard's own lead_location()."""
    loc = str(location or "").strip()
    return lead_location({"location": loc, "file": bare_codefile(loc)})


def anchor_hit(key, anchor):
    basename, function = key
    abase, afn = anchor
    if not function:
        return False
    if abase:
        return lead_matches_locations(basename, function, {anchor})
    return function.lower() == afn  # function-only keyword anchor: any file


def hits_any(key, anchors):
    return any(anchor_hit(key, a) for a in anchors)


def tier_of(rarity, rare_max):
    try:
        r = int(rarity)
    except (TypeError, ValueError):
        return "?"
    if r <= rare_max:
        return "rare"
    if r <= 8:
        return "mid"
    return "consensus"


def natural_key(name):
    m = re.match(r"^([0-9]+)_", name)
    return (int(m.group(1)) if m else 1 << 30, name)


# ----------------------------------------------------------------------------------------------------------------
# truth + anchors
# ----------------------------------------------------------------------------------------------------------------
def read_truth(path):
    lines = read_lines(path)
    if lines is None:
        die(3, "cannot read truth file: " + os.path.basename(path))
    rows, short = [], 0
    for line in lines:
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) < 5 or not cols[0].strip():
            short += 1
            continue
        rows.append({
            "sev_id": cols[0].strip(), "severity": cols[1].strip(), "rarity": cols[2].strip(),
            "title": cols[3], "signature": cols[4], "locations": cols[5] if len(cols) >= 6 else "",
        })
    if not rows:
        if short:
            die(3, "truth file has no row of >= 5 columns -- the 4-column CodeHawks truth shape is not supported "
                   "(sev_id severity rarity title signature [locations] expected)")
        die(3, "truth file has no rows")
    return rows, short


def row_anchors(row):
    """-> (anchor_source, [(basename_lower, fn_lower)], [display])"""
    pairs = parse_row_locations(row["locations"])
    if pairs:
        disp = {}
        for token in row["locations"].split():
            b, sep, f = token.partition(":")
            if sep and b.strip() and f.strip():
                disp.setdefault((b.strip().lower(), f.strip().lower()), token)
        anchors = sorted(pairs)
        return "col6", anchors, [disp.get(a, a[0] + ":" + a[1]) for a in anchors]
    text = row["title"] + " " + row["signature"]
    kp = {}
    for m in _QUAL_RE.finditer(text):
        contract = m.group(1)
        fn = m.group(2) or m.group(3)
        if contract.lower() in STOP_QUALIFIERS or fn.lower() in STOP_FNS or fn == "sol":
            continue
        kp.setdefault((contract.lower() + ".sol", fn.lower()), contract + ".sol:" + fn)
    if kp:
        anchors = sorted(kp)
        return "keyword-pair", anchors, [kp[a] for a in anchors]
    kf = {}
    for span in _TICK_RE.findall(text):
        for m in _CALL_RE.finditer(span):
            fn = m.group(1)
            if fn.lower() in STOP_FNS:
                continue
            kf.setdefault(("", fn.lower()), "*:" + fn)
    if kf:
        anchors = sorted(kf)
        return "keyword-fn", anchors, [kf[a] for a in anchors]
    return "none", [], []


# ----------------------------------------------------------------------------------------------------------------
# map + scope
# ----------------------------------------------------------------------------------------------------------------
def load_zones(path):
    """zones.json -> {zone_id: [file, ...]} or None when unreadable."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    zones = data.get("zones", []) if isinstance(data, dict) else data
    out = {}
    if not isinstance(zones, list):
        return None
    for z in zones:
        if isinstance(z, dict) and z.get("id"):
            files = z.get("files") or []
            out[str(z["id"])] = [str(f) for f in files if f] if isinstance(files, list) else []
    return out


def load_scope(path):
    """scope.tsv -> [(file, set_of_fns_lower | None)]; None when unreadable."""
    lines = read_lines(path)
    if lines is None:
        return None
    out = []
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = line.split("|")
        if len(f) < 3:
            continue
        for entry in f[2].split(","):
            entry = entry.strip()
            if not entry:
                continue
            fpath, sep, fns = entry.partition("@")
            out.append((fpath.strip(), {x.strip().lower() for x in fns.split("+") if x.strip()} if sep else None))
    return out


# ----------------------------------------------------------------------------------------------------------------
# one run tree -> evidence records
# ----------------------------------------------------------------------------------------------------------------
class Run:
    def __init__(self, label, root, include_superseded):
        self.label = label
        self.root = root
        self.notes = []
        self.zone_status = {}     # zone -> ran | failed | no-cells
        self.candidates = []      # dicts: key, tier (1|2), outcome, ev (list of evidence tuples)
        self.verified = []        # (key, evidence)
        self.dismiss = []         # (key, zone, lineno, relpath, evidence)
        self.invariants = []      # (key, evidence)
        self.logs = []            # (zone, superseded, relpath, lines)
        self.map_zones = None
        self.scope = None
        self._read_map()
        self._read_discovery_dirs(include_superseded)
        self._read_candidates()

    def rel(self, path):
        return os.path.relpath(path, self.root).replace(os.sep, "/")

    def ev(self, kind, relpath, ref, sortnum, text, tag=""):
        k = kind + ("(" + tag + ")" if tag else "")
        return (KIND_PRIO.get(kind, 99), self.label, relpath, sortnum, "[%s] %s:%s:%s %s" % (
            k, self.label, relpath, ref, clean(text)))

    def _read_map(self):
        zp = os.path.join(self.root, "map", "zones.json")
        if os.path.isfile(zp):
            self.map_zones = load_zones(zp)
        sp = os.path.join(self.root, "map", "scope.tsv")
        if os.path.isfile(sp):
            self.scope = load_scope(sp)

    def _read_discovery_dirs(self, include_superseded):
        disc = os.path.join(self.root, "discovery")
        try:
            names = sorted(os.listdir(disc))
        except OSError:
            names = []
        for name in names:
            zdir = os.path.join(disc, name)
            if not os.path.isdir(zdir) or os.path.islink(zdir):
                continue
            superseded = bool(_ATTEMPT_RE.search(name))
            zone = _ATTEMPT_RE.sub("", name)
            if superseded and not include_superseded:
                continue
            rundir = os.path.join(zdir, "run")
            try:
                files = sorted(os.listdir(rundir))
            except OSError:
                files = []
            cells = [f for f in files if f.startswith("hunt_") and f.endswith(".log")]
            logs = [f for f in files if f.startswith("hunt_") and (
                f.endswith(".log") or ".log.untraced-attempt-" in f or ".log.rubric-attempt-" in f)]
            if not superseded:
                if not cells:
                    self.zone_status[zone] = "no-cells"
                else:
                    failed = [c for c in cells if os.path.exists(os.path.join(rundir, c + ".timeout"))
                              or os.path.exists(os.path.join(rundir, c + ".novalid"))]
                    self.zone_status[zone] = "failed" if len(failed) == len(cells) else "ran"
                    if failed and len(failed) < len(cells):
                        self.notes.append("%s: zone %s: %d of %d cell(s) failed (.timeout/.novalid)"
                                          % (self.label, zone, len(failed), len(cells)))
            for f in logs:
                path = os.path.join(rundir, f)
                lines = read_lines(path)
                if lines is None:
                    continue
                relpath = self.rel(path)
                self.logs.append((zone, superseded, relpath, lines))
                for i, line in enumerate(lines, 1):
                    s = line.strip()
                    if s.startswith("DISMISS|"):
                        parts = s.split("|")
                        if len(parts) >= 2:
                            self.dismiss.append((loc_key(parts[1]), zone, i, relpath, self.ev(
                                "dismiss", relpath, i, i, s, "superseded" if superseded else "")))
        if not os.path.isfile(os.path.join(disc, "discovery-results.merged.json")):
            self.notes.append("%s: no discovery/discovery-results.merged.json (no candidate evidence from this run)"
                              % self.label)
        # e. deep-hunt INVARIANT| lines
        dh = os.path.join(self.root, "deep-hunt")
        if os.path.isdir(dh):
            for sub in sorted(os.listdir(dh)):
                rundir = os.path.join(dh, sub, "run")
                if not os.path.isdir(rundir):
                    continue
                for f in sorted(os.listdir(rundir)):
                    if not (f.startswith("invariant_") and f.endswith(".log")):
                        continue
                    path = os.path.join(rundir, f)
                    lines = read_lines(path) or []
                    relpath = self.rel(path)
                    for i, line in enumerate(lines, 1):
                        idx = line.find("INVARIANT|")
                        if idx < 0:
                            continue
                        parts = line[idx:].strip().split("|")
                        if len(parts) >= 3:
                            self.invariants.append((loc_key(parts[1]), self.ev(
                                "invariant", relpath, i, i, line[idx:].strip())))

    def _gates(self, subdir):
        """[(location_string, verdict, reason, relpath, [ground evidence])] in gate-number order."""
        out = []
        gdir = os.path.join(self.root, "verify", subdir)
        if not os.path.isdir(gdir):
            return out
        for name in sorted(os.listdir(gdir), key=natural_key):
            cell = os.path.join(gdir, name)
            man = read_lines(os.path.join(cell, "candidate.manifest"))
            if not man:
                continue
            loc = man[0].split("|")[0].strip()
            vlines = read_lines(os.path.join(cell, "verdict.txt"))
            verdict, reason = ("", "")
            if vlines:
                v = vlines[0].split("\t", 1)
                verdict, reason = v[0].strip(), (v[1] if len(v) > 1 else "")
            grounds = []
            rrun = os.path.join(cell, "refute-out", "run")
            if os.path.isdir(rrun):
                for f in sorted(os.listdir(rrun)):
                    if not (f.startswith("refute_") and f.endswith(".log")):
                        continue
                    path = os.path.join(rrun, f)
                    relpath = self.rel(path)
                    for i, line in enumerate(read_lines(path) or [], 1):
                        idx = line.find("REFUTE-GROUND|")
                        if idx >= 0:
                            grounds.append(self.ev("refute-ground", relpath, i, i, line[idx:].strip()))
            out.append((loc, verdict, reason, self.rel(cell), grounds))
        return out

    def _read_candidates(self):
        merged_rel = "discovery/discovery-results.merged.json"
        merged = read_json(os.path.join(self.root, merged_rel), self.notes, self.label, merged_rel)
        vf_rel = "verify/verified_findings.json"
        vf = read_json(os.path.join(self.root, vf_rel), self.notes, self.label, vf_rel)
        if vf is None:
            self.notes.append("%s: no %s (no verified / refute evidence from this run)" % (self.label, vf_rel))
            vf = {}
        if not isinstance(vf, dict):
            vf = {}
        # b. verified[] (any source), refuted[], out_of_scope[], errors[]
        json_outcome = {}   # location string -> (outcome, evidence)
        for arr, kind, outcome in (("refuted", "refuted", "refuted"), ("out_of_scope", "out-of-scope", "refuted"),
                                   ("errors", "error", "error")):
            for i, rec in enumerate(vf.get(arr, []) or []):
                if not isinstance(rec, dict):
                    continue
                loc = str(rec.get("location", "") or "").strip()
                text = rec.get("reason") or rec.get("verdict") or rec.get("label") or ""
                e = self.ev(kind, vf_rel, "%s[%d]" % (arr, i), i, "%s -- %s" % (loc, text))
                json_outcome.setdefault(loc, []).append((outcome, e))
        for i, rec in enumerate(vf.get("verified", []) or []):
            if not isinstance(rec, dict):
                continue
            loc = str(rec.get("location", "") or "").strip()
            key = lead_location(rec)
            src = str(rec.get("source", "") or "breadth")
            self.verified.append((key, self.ev("verified", vf_rel, "verified[%d]" % i, i, "%s source=%s %s -- %s" % (
                loc, src, rec.get("severity", ""), rec.get("exploit", "")))))
        t2_verdicts = {}
        for rec in vf.get("tier2", []) or []:
            if isinstance(rec, dict):
                t2_verdicts.setdefault(str(rec.get("location", "") or "").strip(), []).append(
                    (str(rec.get("verdict", "") or ""), str(rec.get("reason", "") or "")))
        # c. gates (tier 1 + tier 2), paired with candidates of the same location string in order
        gates = {}
        for g in self._gates("gates"):
            gates.setdefault(g[0], []).append(g)
        gates2 = {}
        for g in self._gates("gates-tier2"):
            gates2.setdefault(g[0], []).append(g)
        if merged is None:
            return
        if not isinstance(merged, dict):
            self.notes.append("%s: %s has an unexpected shape" % (self.label, merged_rel))
            return
        n = 0
        for ci, cell in enumerate(merged.get("cells", []) or []):
            if not isinstance(cell, dict):
                continue
            for ki, cand in enumerate(cell.get("candidates", []) or []):
                loc = str(cand).split("|", 1)[0].strip()
                if not loc:
                    continue
                c = {"key": loc_key(loc), "tier": 1, "loc": loc, "ev": [self.ev(
                    "candidate", merged_rel, "cells[%d].candidates[%d]" % (ci, ki), n, cand)]}
                n += 1
                self._resolve(c, gates, json_outcome)
                self.candidates.append(c)
        for ti, rec in enumerate(merged.get("tier2", []) or []):
            if not isinstance(rec, dict):
                continue
            loc = str(rec.get("location", "") or "").strip()
            if not loc:
                continue
            c = {"key": loc_key(loc), "tier": 2, "loc": loc, "ev": [self.ev(
                "tier2", merged_rel, "tier2[%d]" % ti, ti, "%s %s -- %s" % (loc, rec.get("check", ""),
                                                                         rec.get("why", "")))]}
            verdicts = t2_verdicts.get(loc, [])
            self._resolve(c, gates2, {})
            if c["outcome"] == "no-gate" and verdicts:
                v, reason = verdicts[0]
                c["outcome"] = self._outcome_of(v)
                c["ev"].append(self.ev("gate", vf_rel, "tier2", ti, "%s %s" % (v, reason)))
            self.candidates.append(c)

    @staticmethod
    def _outcome_of(verdict):
        v = verdict.strip().upper()
        if not v:
            return "skipped"
        if v in CONFIRM_TOKENS:
            return "confirmed"
        if v == "ERROR":
            return "error"
        return "refuted"

    def _resolve(self, c, gates, json_outcome):
        queue = gates.get(c["loc"], [])
        if queue:
            loc, verdict, reason, relcell, grounds = queue.pop(0)
            c["outcome"] = self._outcome_of(verdict)
            c["ev"].append(self.ev("gate", relcell + "/verdict.txt", 1, 0,
                                   "%s %s" % (verdict or "(no verdict.txt: skipped)", reason)))
            c["ev"].extend(grounds)
            return
        for outcome, e in json_outcome.get(c["loc"], []):
            c["outcome"] = outcome
            c["ev"].append(e)
            return
        c["outcome"] = "no-gate"


# ----------------------------------------------------------------------------------------------------------------
# run discovery
# ----------------------------------------------------------------------------------------------------------------
def is_run_tree(path):
    return os.path.isdir(os.path.join(path, "discovery"))


def default_label(path):
    base = os.path.basename(os.path.normpath(path))
    if base == "zone-hunt-out":
        base = os.path.basename(os.path.dirname(os.path.normpath(path)))
    return base or "run"


def find_run_trees(root):
    root = os.path.abspath(root)
    if is_run_tree(root):
        return [(default_label(root), root)]
    found = []
    for dirpath, dirnames, _ in os.walk(root, followlinks=False):
        if dirpath != root and is_run_tree(dirpath):
            rel = os.path.relpath(dirpath, root).replace(os.sep, "/")
            if rel.endswith("/zone-hunt-out"):
                rel = rel[: -len("/zone-hunt-out")]
            found.append((rel, dirpath))
            dirnames[:] = []
            continue
        dirnames[:] = sorted(d for d in dirnames if d not in PRUNE_DIRS)
    return sorted(found)


# ----------------------------------------------------------------------------------------------------------------
# classification
# ----------------------------------------------------------------------------------------------------------------
def classify(row, runs, zones_map, scope, forced, rare_max):
    src, anchors, disp = row_anchors(row)
    out = {
        "sev_id": row["sev_id"], "severity": row["severity"], "rarity": row["rarity"],
        "tier": tier_of(row["rarity"], rare_max), "anchor_source": src, "anchors": " ".join(disp) or "-",
        "sub": "-", "level": "-", "verified": 0, "candidates": 0, "refuted": 0, "dismissed": 0,
        "mentions": 0, "zones": "-", "evidence": [],
    }
    if not anchors:
        out["proposed"] = "unanchored"
        return out
    fn_names = sorted({a[1] for a in anchors})
    pair_bases = sorted({a[0] for a in anchors if a[0]})
    fn_only = any(not a[0] for a in anchors)

    # owning zones
    if zones_map is not None:
        owning = set()
        for zid, files in zones_map.items():
            bases = {os.path.basename(f).lower() for f in files}
            if fn_only or any(b in bases for b in pair_bases):
                owning.add(zid)
    else:
        owning = set()
        for r in runs:
            owning.update(r.zone_status)
    status = {}
    for z in sorted(owning):
        best = "not-run"
        for r in runs:
            s = r.zone_status.get(z)
            if s == "ran" or (s and best == "not-run") or (s == "failed" and best == "no-cells"):
                best = s
        if z in forced:
            best = "operator:" + forced[z]
        status[z] = best
    out["zones"] = ",".join("%s=%s" % (z, status[z]) for z in sorted(status)) or "-"

    def zone_owns(zone):
        if zones_map is None or zone not in zones_map:
            return True
        bases = {os.path.basename(f).lower() for f in zones_map[zone]}
        return fn_only or any(b in bases for b in pair_bases)

    ev = []
    verified = [e for r in runs for (k, e) in r.verified if hits_any(k, anchors)]
    cands = [c for r in runs for c in r.candidates if hits_any(c["key"], anchors)]
    dismiss = [(rel, ln, e) for r in runs for (k, z, ln, rel, e) in r.dismiss if hits_any(k, anchors)]
    invs = [e for r in runs for (k, e) in r.invariants if hits_any(k, anchors)]
    dismiss_ids = {(rel, ln) for (rel, ln, _) in dismiss}
    mentions = []
    fn_res = [re.compile(r"(?<![A-Za-z0-9_])" + re.escape(f) + r"(?![A-Za-z0-9_])", re.IGNORECASE) for f in fn_names]
    for r in runs:
        for zone, superseded, relpath, lines in r.logs:
            owns = zone_owns(zone)
            for i, line in enumerate(lines, 1):
                if (relpath, i) in dismiss_ids:
                    continue
                if not any(rx.search(line) for rx in fn_res):
                    continue
                low = line.lower()
                if not owns and not any(b in low for b in pair_bases):
                    continue
                s = line.strip()
                pref = 0 if s.startswith(PREFERRED_MENTION) else 1
                e = r.ev("mention", relpath, i, i, s, "superseded" if superseded else "")
                mentions.append((e[0], pref) + e[1:])  # preferred sentinel lines sort first across all logs
    ev.extend(verified)
    for c in cands:
        ev.extend(c["ev"])
    ev.extend(e for (_, _, e) in dismiss)
    ev.extend(invs)
    ev.extend(mentions)
    out["verified"] = len(verified)
    out["candidates"] = len(cands)
    out["refuted"] = sum(1 for c in cands if c["outcome"] == "refuted")
    out["dismissed"] = len(dismiss)
    out["mentions"] = len(mentions) + len(invs)
    seen = set()
    uniq = []
    for e in sorted(ev):
        if e[-1] in seen:
            continue
        seen.add(e[-1])
        uniq.append(e[-1])
    out["evidence"] = uniq

    t1_open = [c for c in cands if c["tier"] == 1 and c["outcome"] != "refuted"]
    t2_open = [c for c in cands if c["tier"] == 2 and c["outcome"] != "refuted"]
    if verified:
        out["proposed"], out["level"] = "HIT-candidate", "verified"
    elif t1_open:
        out["proposed"], out["level"] = "HIT-candidate", "unassessed"
    elif t2_open:
        out["proposed"], out["level"] = "HIT-candidate", "tier2"
    elif cands:
        out["proposed"] = "refuted"
    elif dismiss:
        out["proposed"] = "found-dismissed"
    else:
        scope_sub = None
        if zones_map is not None and not fn_only:
            all_bases = {os.path.basename(f).lower() for files in zones_map.values() for f in files}
            file_out = [a for a in anchors if a[0] not in all_bases]
            if len(file_out) == len(anchors):
                scope_sub = "file"
            elif scope is not None and not mentions and not invs and any(v == "ran" for v in status.values()):
                # the no-mention half of the slice rule is only evidence when an owning zone actually ran
                slice_out = 0
                for a in anchors:
                    if a in file_out:
                        continue
                    entries = [fns for (fp, fns) in scope if os.path.basename(fp).lower() == a[0]]
                    if entries and all(fns is not None and a[1] not in fns for fns in entries):
                        slice_out += 1
                if slice_out and slice_out + len(file_out) == len(anchors):
                    scope_sub = "slice"
        if scope_sub:
            out["proposed"], out["sub"] = "scope-out-of-map", scope_sub
        elif owning and not any(s == "ran" for s in status.values()):
            out["proposed"] = "unmeasured"
            kinds = sorted({s.split(":", 1)[0] for s in status.values()})
            out["sub"] = "+".join(kinds)
        else:
            out["proposed"] = "generation"
            out["sub"] = "examined" if (mentions or invs) else "unseen"
    return out


# ----------------------------------------------------------------------------------------------------------------
# rendering
# ----------------------------------------------------------------------------------------------------------------
def md_cell(text):
    return str(text).replace("\\", "\\\\").replace("|", "\\|")


def render_tsv(results):
    lines = ["\t".join(TSV_COLS)]
    for r in results:
        top = r["evidence"][0] if r["evidence"] else "-"
        vals = [r["sev_id"], r["severity"], r["rarity"], r["tier"], r["anchor_source"], r["anchors"],
                r["proposed"], r["sub"], r["level"], str(r["verified"]), str(r["candidates"]), str(r["refuted"]),
                str(r["dismissed"]), str(r["mentions"]), r["zones"], top, ""]
        lines.append("\t".join(v.replace("\t", " ") for v in vals))
    return "\n".join(lines) + "\n"


def render_md(results, meta, max_ev):
    out = ["# Held-out triage (#2262)", ""]
    out.append("ruler: truth=%s rows=%d (shown %d, rows=%s) ; runs=%d [%s] ; map=%s ; rare-max=%d ; %s" % (
        meta["truth"], meta["total"], len(results), meta["rows"], len(meta["labels"]), ", ".join(meta["labels"]),
        meta["map"], meta["rare_max"], meta["role"]))
    out.append("")
    for n in meta["notes"]:
        out.append("- note: " + n)
    if meta["notes"]:
        out.append("")
    out.append("> **Every class below is a PROPOSAL.** Like the #2215 anchors it is mechanism-blind: a name-coincident "
               "candidate at an anchored location proposes `HIT-candidate` all the same. `HIT-candidate` is never a "
               "HIT until the operator column says so; no recall number is derived from this table.")
    out.append("")
    for scope_name, subset in (("all rows", results), ("rare tier", [r for r in results if r["tier"] == "rare"])):
        counts = [(c, sum(1 for r in subset if r["proposed"] == c)) for c in CLASSES]
        out.append("proposed (%s, %d): %s" % (scope_name, len(subset), ", ".join("%s %d" % (c, n) for c, n in counts)))
    out.append("")
    out.append("| row | sev | rarity | anchors | proposed | evidence | operator |")
    out.append("|---|---|---|---|---|---|---|")
    for r in results:
        prop = r["proposed"]
        if r["sub"] != "-":
            prop += "/" + r["sub"]
        if r["level"] != "-":
            prop += " (level=%s)" % r["level"]
        ev = r["evidence"][:max_ev]
        if len(r["evidence"]) > max_ev:
            ev = ev + ["(+%d more)" % (len(r["evidence"]) - max_ev)]
        counts = "v=%d c=%d r=%d d=%d m=%d zones=%s" % (r["verified"], r["candidates"], r["refuted"], r["dismissed"],
                                                         r["mentions"], r["zones"])
        out.append("| %s | %s | %s (%s) | %s | %s | %s | |" % (
            md_cell(r["sev_id"]), md_cell(r["severity"]), md_cell(r["rarity"]), r["tier"],
            md_cell("%s: %s" % (r["anchor_source"], r["anchors"])), md_cell(prop),
            "<br>".join(md_cell(x) for x in [counts] + ev)))
    return "\n".join(out) + "\n"


# ----------------------------------------------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------------------------------------------
def corpus_role(corpus, contest):
    role = "?"
    for line in read_lines(corpus) or []:
        if line.startswith("#"):
            continue
        f = line.split("\t")
        if f and f[0] == contest and len(f) >= 5 and f[4].strip() in ("dev", "holdout"):
            role = f[4].strip()
            break
    if role == "dev":
        return "role=dev, IN-DISTRIBUTION (lens designed on this contest, #2231)"
    return "role=" + role


def run(argv):
    truth = None
    run_specs = []
    run_roots = []
    map_path = scope_path = None
    forced = {}
    contest = corpus = None
    rare_max, max_ev = 2, 5
    rows_mode = "all"
    include_superseded = False
    tsv_out = md_out = out_dir = None
    i = 1

    def need(flag):
        if i + 1 >= len(argv):
            die(2, flag + " needs a value")
        return argv[i + 1]

    while i < len(argv):
        a = argv[i]
        if a == "--truth":
            truth = need(a); i += 2
        elif a == "--run":
            run_specs.append(need(a)); i += 2
        elif a == "--run-root":
            run_roots.append(need(a)); i += 2
        elif a in ("--map", "--zones-json"):
            map_path = need(a); i += 2
        elif a == "--scope":
            scope_path = need(a); i += 2
        elif a == "--unmeasured":
            z, sep, reason = need(a).partition(":")
            if not z or not sep or not reason:
                die(2, "--unmeasured needs <zone_id>:<reason>")
            forced[z] = reason; i += 2
        elif a == "--contest":
            contest = need(a); i += 2
        elif a == "--corpus":
            corpus = need(a); i += 2
        elif a in ("--rare-max", "--max-evidence"):
            v = need(a)
            if not v.isdigit():
                die(2, a + " needs a non-negative integer")
            if a == "--rare-max":
                rare_max = int(v)
            else:
                max_ev = int(v)
            i += 2
        elif a == "--rows":
            rows_mode = need(a)
            if rows_mode not in ("all", "rare"):
                die(2, "--rows must be all or rare")
            i += 2
        elif a == "--rare-only":
            rows_mode = "rare"; i += 1
        elif a == "--include-superseded":
            include_superseded = True; i += 1
        elif a == "--tsv":
            tsv_out = need(a); i += 2
        elif a == "--md":
            md_out = need(a); i += 2
        elif a == "--out":
            out_dir = need(a); i += 2
        elif a in ("-h", "--help"):
            sys.stdout.write(open(os.path.abspath(__file__), encoding="utf-8").read().split("\nimport sys")[0])
            return 0
        else:
            die(2, "unknown argument: " + a)
    if not truth:
        die(2, "--truth is required")
    if not run_specs and not run_roots:
        die(2, "at least one --run or --run-root is required")
    if (contest is None) != (corpus is None):
        die(2, "--contest and --corpus go together")

    rows, short = read_truth(truth)
    trees = []
    for spec in run_specs:
        label, sep, path = spec.partition("=")
        if not sep:
            label, path = "", spec
        if not is_run_tree(path):
            die(3, "--run %s: not a run tree (no discovery/ dir)" % (label or os.path.basename(path)))
        trees.append((label or default_label(path), os.path.abspath(path)))
    for root in run_roots:
        if not os.path.isdir(root):
            die(3, "--run-root is not a directory: " + os.path.basename(os.path.normpath(root)))
        found = find_run_trees(root)
        if not found:
            die(3, "--run-root %s: no run tree (a dir holding discovery/) found" % os.path.basename(
                os.path.normpath(root)))
        trees.extend(found)
    labels = [t[0] for t in trees]
    if len(set(labels)) != len(labels):
        die(2, "duplicate run label(s): " + ", ".join(sorted({x for x in labels if labels.count(x) > 1})))
    trees.sort()
    runs = [Run(label, path, include_superseded) for label, path in trees]

    notes = []
    if short:
        notes.append("%d truth line(s) with fewer than 5 columns skipped" % short)
    if map_path:
        zones_map = load_zones(map_path)
        if zones_map is None:
            die(3, "--map is not a readable zones.json: " + os.path.basename(map_path))
        map_desc = "--map %s (%d zones)" % (os.path.basename(map_path), len(zones_map))
        if not scope_path:
            sib = os.path.join(os.path.dirname(os.path.abspath(map_path)), "scope.tsv")
            if os.path.isfile(sib):
                scope_path = sib
    else:
        zones_map = None
        for r in runs:
            if r.map_zones is not None:
                zones_map = zones_map or {}
                for z, files in r.map_zones.items():
                    zones_map.setdefault(z, files)
        if zones_map is None:
            map_desc = "none"
            notes.append("no zones.json (no --map, no run-tree map/): zone ownership falls back to the run trees' "
                         "zones and scope-out-of-map is not evaluated")
        else:
            map_desc = "union of run-tree maps (%d zones)" % len(zones_map)
            notes.append("zone map is the union of the run trees' own map/zones.json -- a staged single-zone map "
                         "UNDER-REPORTS scope-out-of-map and unmeasured; pass --map <full zones.json>")
    if scope_path:
        scope = load_scope(scope_path)
        if scope is None:
            die(3, "--scope is not readable: " + os.path.basename(scope_path))
    else:
        scope = None
        for r in runs:
            if r.scope is not None:
                scope = (scope or []) + r.scope
        if scope is None:
            notes.append("no scope.tsv: scope-out-of-map/slice is not evaluated")
    for z in sorted(forced):
        notes.append("zone %s forced unmeasured (%s)" % (z, forced[z]))
    no_deep = []
    for r in runs:
        notes.extend(r.notes)
        if not os.path.isdir(os.path.join(r.root, "deep-hunt")):
            no_deep.append(r.label)
    if no_deep:
        notes.append("no deep-hunt/ in %d of %d run tree(s) (no STAGE 4.5 invariant evidence): %s"
                     % (len(no_deep), len(runs), ", ".join(no_deep)))

    results = [classify(row, runs, zones_map, scope, forced, rare_max) for row in rows]
    if rows_mode == "rare":
        results = [r for r in results if r["tier"] == "rare"]
    meta = {
        "truth": os.path.basename(truth), "total": len(rows), "rows": rows_mode, "labels": [r.label for r in runs],
        "map": map_desc, "rare_max": rare_max, "notes": notes,
        "role": corpus_role(corpus, contest) if contest else "role=unset (no --contest/--corpus)",
    }
    tsv = render_tsv(results)
    md = render_md(results, meta, max_ev)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        tsv_out = tsv_out or os.path.join(out_dir, "triage.tsv")
        md_out = md_out or os.path.join(out_dir, "triage.md")
    if tsv_out:
        with open(tsv_out, "w", encoding="utf-8") as fh:
            fh.write(tsv)
    if md_out:
        with open(md_out, "w", encoding="utf-8") as fh:
            fh.write(md)
    if not tsv_out and not md_out:
        sys.stdout.write(md)
    else:
        sys.stderr.write("triage.py: %d row(s) triaged over %d run tree(s)\n" % (len(results), len(runs)))
    return 0


# ----------------------------------------------------------------------------------------------------------------
# self-test — the M1 acceptance demo: a fixed triage table from fixtures/triage/
# ----------------------------------------------------------------------------------------------------------------
def self_test():
    fx = os.path.join(HERE, "fixtures", "triage")
    fails = []

    def ok(m):
        print("  [PASS] " + m)

    def bad(m):
        print("  [FAIL] " + m)
        fails.append(m)

    for f in ("truth.tsv", "map/zones.json", "map/scope.tsv", "run-core/discovery", "expected-triage.tsv",
              "expected-triage.md"):
        if not os.path.exists(os.path.join(fx, f)):
            print("triage.py: fixture missing: fixtures/triage/" + f, file=sys.stderr)
            return 3
    print("triage.py: --self-test over fixtures/triage/")
    tmp = tempfile.mkdtemp(prefix="triage-selftest.")
    me = os.path.abspath(__file__)

    def go(tag, extra):
        import subprocess
        d = os.path.join(tmp, tag)
        args = [sys.executable, me, "--truth", os.path.join(fx, "truth.tsv"), "--out", d] + extra
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        tsv = md = ""
        if p.returncode == 0:
            tsv = open(os.path.join(d, "triage.tsv"), encoding="utf-8").read()
            md = open(os.path.join(d, "triage.md"), encoding="utf-8").read()
        return p.returncode, tsv, md, p.stderr

    def rows_of(tsv):
        out = {}
        for line in tsv.splitlines()[1:]:
            f = line.split("\t")
            out[f[0]] = f
        return out

    try:
        full = ["--run-root", fx, "--map", os.path.join(fx, "map", "zones.json")]
        rc, tsv, md, err = go("base", full)
        exp_tsv = open(os.path.join(fx, "expected-triage.tsv"), encoding="utf-8").read()
        exp_md = open(os.path.join(fx, "expected-triage.md"), encoding="utf-8").read()
        if rc == 0 and tsv == exp_tsv and md == exp_md:
            ok("fixed triage table reproduced byte-for-byte (expected-triage.tsv + expected-triage.md)")
        else:
            bad("triage table drifted from the pin (rc=%d)%s" % (rc, (": " + err.strip()) if rc else ""))
            for want, got, name in ((exp_tsv, tsv, "tsv"), (exp_md, md, "md")):
                if want != got:
                    wl, gl = want.splitlines(), got.splitlines()
                    for k in range(max(len(wl), len(gl))):
                        a = wl[k] if k < len(wl) else "<none>"
                        b = gl[k] if k < len(gl) else "<none>"
                        if a != b:
                            print("         %s line %d\n           want: %s\n           got:  %s" % (name, k + 1, a, b))
                            break
        rows = rows_of(tsv)
        got_classes = {f[6] for f in rows.values()}
        missing = [c for c in CLASSES if c not in got_classes]
        if not missing:
            ok("every class of the vocabulary is exercised (%s)" % ", ".join(CLASSES))
        else:
            bad("class(es) not exercised by the fixture: " + ", ".join(missing))
        levels = {f[8] for f in rows.values() if f[6] == "HIT-candidate"}
        srcs = {f[4] for f in rows.values()}
        if {"verified", "unassessed", "tier2"} <= levels and {"col6", "keyword-pair", "keyword-fn", "none"} <= srcs:
            ok("HIT-candidate levels verified/unassessed/tier2 and anchor sources col6/keyword-pair/keyword-fn/none")
        else:
            bad("levels %s / anchor sources %s incomplete" % (sorted(levels), sorted(srcs)))

        rc2, tsv2, md2, _ = go("again", full)
        if rc2 == 0 and tsv2 == tsv and md2 == md:
            ok("byte-identical output on a second run (deterministic)")
        else:
            bad("second run differs from the first")

        rc3, tsv3, md3, _ = go("explicit", ["--run", "run-core=" + os.path.join(fx, "run-core"), "--zones-json",
                                            os.path.join(fx, "map", "zones.json")])
        if rc3 == 0 and tsv3 == tsv and md3 == md:
            ok("--run LABEL=<tree> + --zones-json is identical to --run-root + --map")
        else:
            bad("--run/--zones-json output differs from --run-root/--map")

        rc4, tsv4, _, _ = go("rare", full + ["--rare-only"])
        want_rare = "\n".join([tsv.splitlines()[0]] + [ln for ln in tsv.splitlines()[1:]
                                                       if ln.split("\t")[3] == "rare"]) + "\n"
        if rc4 == 0 and tsv4 == want_rare and len(tsv4.splitlines()) > 1:
            ok("--rare-only returns exactly the rare subset of the same rows (%d)" % (len(tsv4.splitlines()) - 1))
        else:
            bad("--rare-only is not the rare subset of the full table")

        # decoy negative controls: source copies + a superseded attempt carry DECOY literals at real anchors
        if "DECOY" not in tsv + md:
            ok("decoys unread: no line of hunter.ag / refuter.ag / the superseded attempt dir reached the output")
        else:
            bad("a DECOY line reached the output (a source copy or superseded attempt was read)")
        unseen = [k for k, f in rows.items() if f[6] == "generation" and f[7] == "unseen"]
        rc5, tsv5, _, _ = go("superseded", full + ["--include-superseded"])
        rows5 = rows_of(tsv5)
        flipped = [k for k in unseen if k in rows5 and rows5[k][6] == "found-dismissed"
                   and "dismiss(superseded)" in rows5[k][15]]
        if rc5 == 0 and unseen and flipped == unseen:
            ok("--include-superseded flips the generation/unseen row(s) %s to found-dismissed, labelled superseded "
               "(the superseded decoy is live, so its default exclusion is not vacuous)" % ",".join(unseen))
        else:
            bad("--include-superseded did not flip %s (got %s)" % (unseen, [rows5.get(k, ["?"] * 8)[6] for k in unseen]))

        abs_hits = [ln for ln in (tsv + md).splitlines() if fx in ln or HERE in ln
                    or re.search(r"(^|[\t ])/(home|Users|root|tmp)/", ln)]
        if not abs_hits:
            ok("no absolute path in any output line")
        else:
            bad("absolute path leaked: " + abs_hits[0][:160])

        # unmeasured: every cell of the hunted zone failed -> its generation rows must not read as a miss
        failed = os.path.join(tmp, "failed-tree")
        shutil.copytree(os.path.join(fx, "run-core"), os.path.join(failed, "run-core"), symlinks=True)
        rd = os.path.join(failed, "run-core", "discovery", "core", "run")
        for f in os.listdir(rd):
            if f.startswith("hunt_") and f.endswith(".log"):
                open(os.path.join(rd, f + ".novalid"), "w").close()
        gen = [k for k, f in rows.items() if f[6] == "generation"]
        sliced = [k for k, f in rows.items() if f[6] == "scope-out-of-map" and f[7] == "slice"]
        rc6, tsv6, _, _ = go("failed", ["--run-root", failed, "--map", os.path.join(fx, "map", "zones.json")])
        rows6 = rows_of(tsv6)
        if rc6 == 0 and gen and sliced and all(rows6[k][6] == "unmeasured" and "failed" in rows6[k][7]
                                               for k in gen + sliced):
            ok("a zone whose every cell failed turns its generation rows %s and its slice-only row(s) %s into "
               "unmeasured/failed (no mention is no evidence when the zone never answered)"
               % (",".join(gen), ",".join(sliced)))
        else:
            bad("all-cells-failed zone still reads as generation / slice: %s"
                % [rows6.get(k, ["?"] * 8)[6:8] for k in gen + sliced])
        rc7, tsv7, _, _ = go("forced", full + ["--unmeasured", "core:operator-void"])
        rows7 = rows_of(tsv7)
        if rc7 == 0 and gen and all(rows7[k][6] == "unmeasured" and "operator" in rows7[k][7] for k in gen) \
                and "core=operator:operator-void" in rows7[gen[0]][14]:
            ok("--unmeasured core:<reason> forces the zone's generation rows to unmeasured")
        else:
            bad("--unmeasured did not force the zone")

        # the staged single-zone map under-reports: without --map the never-run zone is invisible
        unm = [k for k, f in rows.items() if f[6] == "unmeasured"]
        rc8, tsv8, md8, _ = go("nomap", ["--run-root", fx])
        rows8 = rows_of(tsv8)
        if rc8 == 0 and unm and all(rows8[k][6] == "scope-out-of-map" for k in unm) and "UNDER-REPORTS" in md8:
            ok("without --map the staged single-zone map under-reports (%s -> scope-out-of-map) and the header "
               "says so" % ",".join(unm))
        else:
            bad("the no-map under-report note / behaviour is missing")

        # refusals
        four = os.path.join(tmp, "four.tsv")
        with open(four, "w", encoding="utf-8") as fh:
            fh.write("FX-1\t2\tC8\tsome title\n")
        import subprocess
        p = subprocess.run([sys.executable, me, "--truth", four, "--run-root", fx], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True)
        if p.returncode == 3 and "CodeHawks" in p.stderr:
            ok("the 4-column CodeHawks truth shape is refused (exit 3)")
        else:
            bad("4-column truth not refused (rc=%d)" % p.returncode)
        p = subprocess.run([sys.executable, me, "--truth", os.path.join(fx, "truth.tsv")], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True)
        if p.returncode == 2:
            ok("missing --run/--run-root is a usage error (exit 2)")
        else:
            bad("missing run tree not rejected with exit 2 (rc=%d)" % p.returncode)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print()
    if not fails:
        print("triage.py: PASS -- fixed triage table reproduced; decoys unread; unmeasured / superseded / rare "
              "subset / determinism held")
        return 0
    print("triage.py: FAIL -- %d assertion(s) regressed" % len(fails), file=sys.stderr)
    return 1


def main(argv):
    if "--self-test" in argv:
        return self_test()
    return run(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
