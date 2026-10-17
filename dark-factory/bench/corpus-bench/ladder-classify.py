#!/usr/bin/env python3
# ladder-classify.py — the #2311 pointed-ladder DIAGNOSTIC: the hint-leak gate before any pointed run, the per-arm
# scorer, and the mechanical cause classifier + lever decision rule after the runs. It measures; it never claims
# recall. A pointed arm is told which function to read (the exam runner's `stage --pointer`, an L0/L1/L2 pointer
# block), so a HIT there is an UPPER BOUND on what the hunter can reach, not what it would have selected. Every
# table this tool writes is headed "DIAGNOSTIC: pointed upper bound, not recall" and carries no recall percentage.
#
# python3 stdlib only, no network, no LLM of its own: every mechanism decision is the SAME judge score-match.py
# drives (`--judge <cmd>`: one canonical request JSON on stdin -> `VERDICT|` lines; mech-judge.sh in production, a
# stub in the self-test). The request builder, the reply parser and the batched judging loop are IMPORTED from
# score-match.py (read-only, the triage.py idiom), so a decision here is byte-for-byte a score-match.py decision.
#
# Subcommands:
#   hint-gate --ladder <ladder.tsv> --truth-dir <dir> --judge <cmd>
#       Before any run: every L1 and every L2 text of the ladder, judged ALONE (the text as the lead's exploit, the
#       row's first anchor as its location) against its OWN truth row (<truth-dir>/<contest>/truth.tsv). A MATCH
#       means the hint states the mechanism: it must be rewritten (or the row's L2 set to `=L1`). One
#       `<ptr_id>\t<rung>\t<CLEAN|LEAK|JUDGE-ERROR>\t<confidence>\t<reason>` line per hint. Fail closed: exit 3 on
#       any judge error (an unparseable reply or a hallucinated row id — the gate is then unmeasured), else exit 4
#       on any LEAK, else 0. `-` and `=L1` texts are not judged.
#   score --arm <arm-dir> (--row <sev_id> | --ladder <ladder.tsv>) --judge <cmd> --out <file>
#         [--judge-cache <f.jsonl>] [--exam-root <dir>]
#       One pointed arm (exam.sh's arms/<contest>/<zone>/ptr-<id>-<rung>-r<n>) -> one score file. The row comes
#       from --row or from the ladder row of the arm's pointer_id. Every PRE-REFUTE candidate of the arm (tier 1 +
#       tier 2, any location: hypotheses-to-leads.py --include-tier2) is judged against a ONE-ROW truth file; every
#       DISMISS| line of the arm's live cell logs is judged the same way (a MATCH there sets dismissed=1, never a
#       HIT); a DISMISS line citing the pointer block sets pointer_cited=1. STAGE 4.5: the INVARIANT| lines at the
#       anchor files — FINDING lines are judged (property + log as the lead), CLEAN is a MISS, a not-judged status
#       (TIMEOUT, HARNESS_ERROR, SKIPPED_*) anywhere makes a non-match UNMEASURED (beside a judged FINDING as much
#       as beside a CLEAN), and so does a deep hunt that never ran. Refute verdicts are recorded (refute_verified)
#       and never used for the cause: the refuter may read the brief, so the pointer.
#       The file leaves `breadth_confirmed=-` and `deep_confirmed=-` for the OPERATOR, who sets `yes` / `no` after
#       reading every judge MATCH against the GT text — `classify` refuses an unconfirmed MATCH.
#   classify --inventory <inventory.tsv> --scores <dir> [--table <f>] [--verdict <f>]
#       The per-row table, the cause counts, the lever counts and the verdict under the pre-registered rule below.
#       inventory.tsv: `contest\trow\tfound_by\tptr_id\tunpointed\texposure` (ptr_id `-` = UNPOINTABLE; exposure =
#       unseen | examined | out-of-map, from the unpointed evidence). Scores: <dir>/<ptr_id>.<cell>.score, cell =
#       L0r1 | L0r2 | L1 | L2 (the score files above). Without --table / --verdict both go to stdout.
#   --self-test
#       Offline: the pinned fixture table + verdict (fixtures/ladder/), one fixture row per class and sub-label,
#       the precedence conflicts, all four verdict kinds, the DIAGNOSTIC header with no `%`, the hint-gate exit
#       codes 0 / 3 / 4 and the score subcommand over a synthetic arm, all through fixtures/ladder/judge-stub.sh.
#
# CELL RESULTS. A breadth cell (L0r1 / L0r2 / L1 / L2) is HIT when the judge MATCHed a pre-refute candidate and the
# operator confirmed it, MISS when nothing matched (or the operator rejected the MATCH), UNMEASURED when the arm is
# VOID. The deep cell (from the L0r1 score) is HIT on a confirmed FINDING match, MISS on CLEAN / a rejected FINDING,
# UNMEASURED otherwise. A judge error anywhere is refused (judge errors must be 0).
#
# PRECEDENCE (first match wins; rows ordered by the least added information and machinery that recovered them):
#   1 UNPOINTABLE   no function anchor (ptr_id `-`). Reported, excluded.
#   2 LOCATION      L0 r1 or r2 HIT. Sub-label = the exposure (unseen / examined / out-of-map).
#   3 EXECUTION     the pointed deep hunt HITs and L0 does not (it ran with the function pointer only).
#   4 HINT          L1 or L2 HIT; sub-label = the lowest rung (`L2=L1` when that L2 arm rendered the L1 block).
#   5 MECHANISM     L0, L1, L2 and deep all MEASURED and MISS. Sub-label `dismissed` when the mechanism appeared
#                   only in a DISMISS line.
#   6 excluded but listed:
#     MECHANISM-or-EXECUTION  every breadth rung MISS, the deep hunt UNMEASURED;
#     UNMEASURED              no HIT anywhere and a breadth rung VOID — or (an implementation edge the plan's list
#                             does not name) a HINT / EXECUTION hit with BOTH L0 arms unmeasured or with the L0 r2
#                             replicate VOID (after its one --retry-void), which a LOCATION cannot be excluded for.
#   The replicate rule is enforced: a HINT / EXECUTION row without its L0 r2 score is refused (exit 3).
#
# DECISION RULE (pre-registered). LOCATION -> coverage/selection, EXECUTION -> execution, HINT + MECHANISM ->
# generation; N = the rows in those four classes, each weighted 1.
#   DOMINANT  one lever holds a strict majority of N AND still holds it under the WORST CASE: every excluded-but-
#             listed row joins the denominator and counts for that lever only when every class consistent with its
#             measured cells maps to it.
#   SELECTED  otherwise, when the plurality lever leads the runner-up by >= 3 rows (one flipped row moves the lead
#             by 2; a lead of 3 survives one flip).
#   SPLIT     otherwise: no lever is selected; the levers are ranked and the human decides.
# Reported alongside, never changing it: the sub-split inside the winning (or leading) lever and the verdict
# recomputed on the found-by = 1 subset.
#
# Exit: 0 ok ; 1 --self-test failed ; 2 usage ; 3 unreadable / wrong-shape input, a judge error, an unconfirmed
#       MATCH or a missing required score ; 4 hint-gate found a LEAK.
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
ADAPTER = os.path.join(HERE, "hypotheses-to-leads.py")
FIX = os.path.join(HERE, "fixtures", "ladder")
HEADER = "DIAGNOSTIC: pointed upper bound, not recall"
LADDER_COLS = ("ptr_id", "contest", "row", "anchors", "l1", "l2")
INVENTORY_COLS = ("contest", "row", "found_by", "ptr_id", "unpointed", "exposure")
EXPOSURES = ("unseen", "examined", "out-of-map")
CELLS = ("L0r1", "L0r2", "L1", "L2")
LEVER = {"LOCATION": "coverage/selection", "EXECUTION": "execution", "HINT": "generation", "MECHANISM": "generation"}
LEVERS = ("generation", "coverage/selection", "execution")   # the fixed tie order of the ranking
MEASURED = ("LOCATION", "EXECUTION", "HINT", "MECHANISM")
EXCLUDED = ("MECHANISM-or-EXECUTION", "UNMEASURED")
CAUSE_ORDER = ("UNPOINTABLE", "LOCATION", "EXECUTION", "HINT", "MECHANISM") + EXCLUDED
SELECT_LEAD = 3          # one flipped row moves the lead by 2, so 3 survives one flip
JUDGE_BATCH = 12         # score-match.py's defaults; a one-row truth file is one batch either way
JUDGE_MIN_CONF = 60
DEEP_LOG_CAP = 4000      # bytes of an invariant log handed to the judge as the FINDING's property + witness


def die(rc, msg):
    sys.stderr.write("ladder-classify.py: " + msg + "\n")
    sys.exit(rc)


def _score_match():
    spec = importlib.util.spec_from_file_location("_ladder_score_match", os.path.join(HERE, "score-match.py"))
    if spec is None or spec.loader is None:
        die(3, "cannot import score-match.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _flags(argv, single, bools=()):
    flags, i = {}, 0
    while i < len(argv):
        a = argv[i]
        if a in bools:
            flags[a] = True
            i += 1
        elif a in single:
            if i + 1 >= len(argv):
                die(2, "missing value for " + a)
            flags[a] = argv[i + 1]
            i += 2
        else:
            die(2, "unknown argument " + a)
    return flags


def read_tsv(path, cols, what):
    rows = []
    try:
        with open(path, encoding="utf-8") as fh:
            for n, raw in enumerate(fh, 1):
                line = raw.rstrip("\n")
                if not line.strip() or line.startswith("#"):
                    continue
                cells = line.split("\t")
                if len(cells) != len(cols):
                    die(3, "%s:%d: %s wants %d TAB columns (%s)" % (path, n, what, len(cols), " ".join(cols)))
                row = dict(zip(cols, (c.strip() for c in cells)))
                row["line"] = n
                rows.append(row)
    except OSError as exc:
        die(3, "cannot read %s %s: %s" % (what, path, exc))
    return rows


def read_kv(path):
    kv = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    kv.setdefault(k, v)
    except OSError:
        return None
    return kv


def truth_row(path, sev_id):
    """(sev_id, signature) of one truth.tsv row (score-match.py's column 5), or die 3."""
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                cols = line.rstrip("\n").split("\t")
                if len(cols) >= 5 and cols[0] == sev_id:
                    return cols[0], cols[4], line if line.endswith("\n") else line + "\n"
    except OSError as exc:
        die(3, "cannot read truth.tsv %s: %s" % (path, exc))
    die(3, "row %s is not in %s" % (sev_id, path))


def first_anchor(spec):
    tok = spec.split(",")[0].strip()
    f = tok.split(":", 1)[0]
    return tok, f


# ----------------------------------------------------------------------------------------------------------
# hint-gate
# ----------------------------------------------------------------------------------------------------------
def hint_gate(ladder, truth_dir, judge, sm):
    """-> (lines, judge_errors, leaks)."""
    out, errors, leaks = [], 0, 0
    for r in read_tsv(ladder, LADDER_COLS, "ladder"):
        sev, sig, _ = truth_row(os.path.join(truth_dir, r["contest"], "truth.tsv"), r["row"])
        loc, afile = first_anchor(r["anchors"])
        for rung, text in (("L1", r["l1"]), ("L2", r["l2"])):
            if text in ("-", "=L1", ""):
                continue
            lid = "%s-%s" % (r["ptr_id"], rung)
            lead = {"location": loc, "file": afile, "class": "hint", "exploit": text, "poc_sketch": ""}
            req, _key = sm.judge_request(lid, lead, [(sev, sig)])
            decisions, dropped = sm.parse_verdicts(sm.invoke_judge(judge, req), lid, {sev})
            if dropped or not decisions:
                errors += 1
                out.append("%s\t%s\tJUDGE-ERROR\t-\tno parseable verdict for this hint" % (r["ptr_id"], rung))
                continue
            match = [d for d in decisions if d[1] == "MATCH"]
            if match:
                leaks += 1
                out.append("%s\t%s\tLEAK\t%d\t%s" % (r["ptr_id"], rung, match[0][2], match[0][3]))
            else:
                out.append("%s\t%s\tCLEAN\t%d\t%s" % (r["ptr_id"], rung, decisions[0][2], decisions[0][3]))
    return out, errors, leaks


def cmd_hint_gate(argv):
    f = _flags(argv, ("--ladder", "--truth-dir", "--judge"))
    if not all(f.get(k) for k in ("--ladder", "--truth-dir", "--judge")):
        die(2, "usage: hint-gate --ladder <ladder.tsv> --truth-dir <dir> --judge <cmd>")
    lines, errors, leaks = hint_gate(f["--ladder"], f["--truth-dir"], f["--judge"], _score_match())
    for line in lines:
        sys.stdout.write(line + "\n")
    if errors:
        sys.stderr.write("ladder-classify.py: hint-gate: %d judge error(s) — the gate is unmeasured (fail closed)\n"
                         % errors)
        return 3
    if leaks:
        sys.stderr.write("ladder-classify.py: hint-gate: %d hint(s) state the mechanism — rewrite them (or set the "
                         "row's L2 to =L1)\n" % leaks)
        return 4
    return 0


# ----------------------------------------------------------------------------------------------------------
# score
# ----------------------------------------------------------------------------------------------------------
def _live_logs(disc):
    """Every live breadth cell log under discovery/<zone>/run/ (superseded `.attempt-<n>` zone dirs skipped)."""
    out = []
    if not os.path.isdir(disc):
        return out
    for zone in sorted(os.listdir(disc)):
        if re.search(r"\.attempt-[0-9]+$", zone):
            continue
        rundir = os.path.join(disc, zone, "run")
        if not os.path.isdir(rundir):
            continue
        for f in sorted(os.listdir(rundir)):
            if f.startswith("hunt_") and ".log" in f and not f.endswith((".timeout", ".novalid")):
                out.append(os.path.join(rundir, f))
    return out


def _bare(loc):
    return loc.split("~", 1)[0].split(":", 1)[0].split("@", 1)[0]


def _judge(sm, leads, rows, judge, cache):
    """-> (matched lead indices, errors, calls) via score-match.py's own judging loop (cmd mode, read-through
    cache when given)."""
    if not leads:
        return [], 0, 0
    _row_hit, lead_hit, calls, errors, _gm, _gr = sm.run_judge(leads, rows, "cmd", judge, cache or "", "",
                                                               JUDGE_BATCH, JUDGE_MIN_CONF)
    return [i for i, h in enumerate(lead_hit) if h], errors, calls


def score_arm(arm, sev_id, judge, cache, exam_root, sm):
    """-> ordered [(key, value)] for one pointed arm."""
    run = read_kv(os.path.join(arm, "run.meta"))
    stage = read_kv(os.path.join(arm, "stage.meta"))
    if run is None or stage is None or not stage.get("pointer_id"):
        die(3, "%s is not a finished pointed arm (run.meta + stage.meta with pointer_id)" % arm)
    contest = run.get("contest", "")
    out = os.path.join(arm, contest, "zone-hunt-out")
    try:
        with open(os.path.join(arm, "void.txt"), encoding="utf-8") as fh:
            vline = fh.readline().rstrip("\n")
    except OSError:
        vline = "VOID\tincomplete\tno void.txt"
    void = "VALID" if vline == "VALID" else "VOID:" + (vline.split("\t") + ["?"])[1]
    sev, sig, tline = truth_row(os.path.join(arm, "_gt", contest, "truth.tsv"), sev_id)
    rows = [(sev, sig)]
    rung = stage.get("pointer_rung", "")
    repeat = run.get("repeat", "1")
    cell = "L0r" + repeat if rung == "L0" else rung
    kv = [("ptr_id", stage["pointer_id"]), ("cell", cell), ("rung", rung), ("repeat", repeat),
          ("row", sev), ("contest", contest), ("void", void)]
    errors_total = 0
    # breadth: every pre-refute candidate (tier 1 + tier 2), any location
    merged = os.path.join(out, "discovery", "discovery-results.merged.json")
    leads = []
    if void == "VALID" and os.path.isfile(merged):
        proc = subprocess.run([sys.executable, ADAPTER, "--from-discovery", merged, "--include-tier2"],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            die(3, "hypotheses-to-leads.py failed on %s: %s" % (merged, proc.stderr.strip()))
        leads = json.loads(proc.stdout).get("verified", [])
    hit, errs, _ = _judge(sm, leads, rows, judge, cache)
    errors_total += errs
    kv += [("breadth_leads", str(len(leads))),
           ("breadth_judge", "-" if void != "VALID" else ("MATCH" if hit else "NO-MATCH")),
           ("breadth_matched", ",".join(str(leads[i].get("location", "")) for i in hit) or "-"),
           ("breadth_confirmed", "-")]
    # DISMISS lines: a judged MATCH is the `dismissed` sub-label, never a HIT
    dleads, cited = [], 0
    for path in _live_logs(os.path.join(out, "discovery")) if void == "VALID" else []:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.read().split("\n")
        except OSError:
            continue
        for line in lines:
            s = line.strip()
            if not s.startswith("DISMISS|"):
                continue
            parts = s.split("|")
            if len(parts) < 2:
                continue
            text = "|".join(parts[2:])
            if re.search(r"operator pointer|focus for this review|pointer block", text, re.I):
                cited = 1
            dleads.append({"location": parts[1], "file": _bare(parts[1]), "class": "dismiss", "exploit": text,
                           "poc_sketch": ""})
    dhit, errs, _ = _judge(sm, dleads, rows, judge, cache)
    errors_total += errs
    kv += [("dismiss_lines", str(len(dleads))), ("dismissed", "1" if dhit else "0"), ("pointer_cited", str(cited))]
    # STAGE 4.5 at the anchor files
    anchors = [a for a in stage.get("pointer_anchors", "").split(",") if a]
    abases = set(os.path.basename(a.split(":", 1)[0]) for a in anchors)
    deep_rc = run.get("deep_rc", "skip")
    deep_status = run.get("deep_status", "-")
    if run.get("deep_pass", "0") != "1":
        deep = "-"
        deep_cells = "-"
    elif void != "VALID" or deep_rc != "0" or deep_status.startswith("unmeasured"):
        deep, deep_cells = "UNMEASURED", "deep_rc=%s deep_status=%s" % (deep_rc, deep_status)
    else:
        findings, clean, notj = [], 0, 0
        dh = os.path.join(out, "deep-hunt")
        for sub in sorted(os.listdir(dh)) if os.path.isdir(dh) else []:
            rundir = os.path.join(dh, sub, "run")
            if not os.path.isdir(rundir):
                continue
            for f in sorted(os.listdir(rundir)):
                if not (f.startswith("invariant_") and f.endswith(".log")):
                    continue
                path = os.path.join(rundir, f)
                try:
                    with open(path, encoding="utf-8", errors="replace") as fh:
                        body = fh.read()
                except OSError:
                    continue
                for line in body.split("\n"):
                    idx = line.find("INVARIANT|")
                    if idx < 0:
                        continue
                    parts = line[idx:].strip().split("|")
                    if len(parts) < 3 or os.path.basename(_bare(parts[1])) not in abases:
                        continue
                    verdict = (parts[2].split() or [""])[0]
                    if verdict == "FINDING":
                        findings.append({"location": parts[1], "file": _bare(parts[1]), "class": "invariant",
                                         "exploit": body[-DEEP_LOG_CAP:], "poc_sketch": ""})
                    elif verdict == "CLEAN":
                        clean += 1
                    else:
                        notj += 1
        fhit, errs, _ = _judge(sm, findings, rows, judge, cache)
        errors_total += errs
        if fhit:
            deep = "MATCH"
        elif (findings or clean) and not notj:
            # a not-judged sibling could have held the match: any of them leaves a non-match UNMEASURED, whether
            # the judged siblings were FINDING or CLEAN
            deep = "NO-MATCH"
        else:
            deep = "UNMEASURED"
        deep_cells = "finding=%d clean=%d not_judged=%d" % (len(findings), clean, notj)
    kv += [("deep", deep), ("deep_cells", deep_cells), ("deep_confirmed", "-"), ("judge_errors", str(errors_total))]
    refute = "-"
    vf = os.path.join(out, "verify", "verified_findings.json")
    if os.path.isfile(vf):
        try:
            with open(vf, encoding="utf-8") as fh:
                refute = str(len(json.load(fh).get("verified", [])))
        except (OSError, ValueError, AttributeError):
            refute = "unreadable"
    root = exam_root
    if not root:
        parts = os.path.abspath(arm).split(os.sep)
        root = os.sep.join(parts[:-4]) if len(parts) > 4 and parts[-4] == "arms" else os.path.dirname(arm)
    kv += [("refute_verified", refute), ("model", run.get("model", "-")),
           ("checkout_commit", run.get("checkout_commit", "-")), ("ladder_sha256", stage.get("ladder_sha256", "-")),
           ("l2_eq_l1", stage.get("pointer_l2_eq_l1", "0")),
           ("evidence", os.path.relpath(os.path.abspath(arm), os.path.abspath(root)))]
    return kv


def cmd_score(argv):
    f = _flags(argv, ("--arm", "--row", "--ladder", "--judge", "--out", "--judge-cache", "--exam-root"))
    if not f.get("--arm") or not f.get("--judge") or not f.get("--out") or not (f.get("--row") or f.get("--ladder")):
        die(2, "usage: score --arm <arm-dir> (--row <sev_id> | --ladder <ladder.tsv>) --judge <cmd> --out <file> "
               "[--judge-cache <f>] [--exam-root <dir>]")
    sev_id = f.get("--row")
    if not sev_id:
        stage = read_kv(os.path.join(f["--arm"], "stage.meta")) or {}
        hit = [r for r in read_tsv(f["--ladder"], LADDER_COLS, "ladder") if r["ptr_id"] == stage.get("pointer_id")]
        if len(hit) != 1:
            die(3, "the ladder has no single row for pointer_id %r" % stage.get("pointer_id"))
        sev_id = hit[0]["row"]
    kv = score_arm(f["--arm"], sev_id, f["--judge"], f.get("--judge-cache"), f.get("--exam-root"), _score_match())
    with open(f["--out"], "w", encoding="utf-8") as fh:
        for k, v in kv:
            fh.write("%s=%s\n" % (k, v))
    d = dict(kv)
    if d["judge_errors"] != "0":
        sys.stderr.write("ladder-classify.py: score: %s judge error(s) — classify refuses this score\n"
                         % d["judge_errors"])
        return 3
    return 0


# ----------------------------------------------------------------------------------------------------------
# classify
# ----------------------------------------------------------------------------------------------------------
def _confirmed(score, field, path):
    v = score.get(field, "-")
    if v not in ("yes", "no"):
        die(3, "%s: %s is a judge MATCH the operator has not confirmed (set %s=yes|no)" % (path, field, field))
    return v == "yes"


def breadth_cell(score, path):
    """-> (HIT|MISS|UNMEASURED, dismissed, pointer_cited)."""
    if score.get("judge_errors", "0") != "0":
        die(3, "%s: judge errors must be 0 (got %s)" % (path, score.get("judge_errors")))
    if score.get("void", "") != "VALID":
        return "UNMEASURED", False, False
    res = "MISS"
    if score.get("breadth_judge") == "MATCH" and _confirmed(score, "breadth_confirmed", path):
        res = "HIT"
    return res, score.get("dismissed") == "1", score.get("pointer_cited") == "1"


def deep_cell(score, path):
    d = score.get("deep", "-")
    if d == "MATCH":
        return "HIT" if _confirmed(score, "deep_confirmed", path) else "MISS"
    if d == "NO-MATCH":
        return "MISS"
    return "UNMEASURED"


def classify_row(inv, scores_dir):
    """-> dict(cause, sub, consistent (excluded rows), cells{}, notes[], meta{})."""
    res = {"cause": "", "sub": "", "consistent": None, "cells": {}, "notes": [], "meta": {}}
    pid = inv["ptr_id"]
    if pid == "-":
        res["cause"] = "UNPOINTABLE"
        for c in CELLS + ("deep",):
            res["cells"][c] = "-"
        return res
    sc, flags = {}, {"dismissed": False, "cited": False}
    for c in CELLS:
        path = os.path.join(scores_dir, "%s.%s.score" % (pid, c))
        kv = read_kv(path) if os.path.isfile(path) else None
        if kv is None:
            continue
        if kv.get("ptr_id") != pid or kv.get("cell") != c or kv.get("row") != inv["row"]:
            die(3, "%s does not score %s %s (ptr_id/cell/row mismatch)" % (path, pid, c))
        r, dis, cited = breadth_cell(kv, path)
        sc[c] = (r, kv, path)
        flags["dismissed"] |= dis
        flags["cited"] |= cited
    if "L0r1" not in sc:
        die(3, "row %s %s: no L0r1 score (%s.L0r1.score)" % (inv["contest"], inv["row"], pid))
    l0 = sc["L0r1"]
    res["meta"] = l0[1]
    deep = deep_cell(l0[1], l0[2])
    cells = res["cells"]
    for c in CELLS:
        cells[c] = sc[c][0] if c in sc else ("-" if c == "L0r2" else "not run")
    cells["deep"] = deep
    if flags["cited"]:
        res["notes"].append("pointer-cited")
    l0_hit = any(c in sc and sc[c][0] == "HIT" for c in ("L0r1", "L0r2"))
    if l0_hit:
        res["cause"], res["sub"] = "LOCATION", inv["exposure"]
        return res
    for c in ("L1", "L2"):
        if c not in sc:
            die(3, "row %s %s: no %s score and no L0 HIT" % (inv["contest"], inv["row"], c))
    l0_measured = any(c in sc and sc[c][0] != "UNMEASURED" for c in ("L0r1", "L0r2"))
    hit_class = ""
    if deep == "HIT":
        hit_class, sub = "EXECUTION", ""
    elif sc["L1"][0] == "HIT" or sc["L2"][0] == "HIT":
        hit_class = "HINT"
        if sc["L1"][0] == "HIT":
            sub = "L1"
        else:
            sub = "L2=L1" if sc["L2"][1].get("l2_eq_l1") == "1" else "L2"
    if hit_class:
        if "L0r2" not in sc:
            die(3, "row %s %s: a %s row needs its L0 r2 replicate (%s.L0r2.score)"
                % (inv["contest"], inv["row"], hit_class, pid))
        if not l0_measured or sc["L0r2"][0] == "UNMEASURED":
            # a VOID r2 (after the protocol's one --retry-void) is no replicate: LOCATION cannot be excluded
            res["cause"], res["consistent"] = "UNMEASURED", {"LOCATION", hit_class}
            res["notes"].append("%s hit, %s" % (hit_class, "both L0 arms unmeasured" if not l0_measured
                                                 else "L0 r2 replicate VOID"))
            return res
        res["cause"], res["sub"] = hit_class, sub
        return res
    breadth = [sc[c][0] for c in CELLS if c in sc]
    if "UNMEASURED" in breadth:
        cons = {"MECHANISM"}
        if not l0_measured:
            cons.add("LOCATION")
        if sc["L1"][0] == "UNMEASURED" or sc["L2"][0] == "UNMEASURED":
            cons.add("HINT")
        if deep == "UNMEASURED":
            cons.add("EXECUTION")
        res["cause"], res["consistent"] = "UNMEASURED", cons
        return res
    if deep == "UNMEASURED":
        res["cause"], res["consistent"] = "MECHANISM-or-EXECUTION", {"MECHANISM", "EXECUTION"}
        return res
    res["cause"], res["sub"] = "MECHANISM", ("dismissed" if flags["dismissed"] else "")
    return res


def decide(rows):
    """rows: [(cause, consistent-set or None)]. -> dict(kind, lever, counts, n, worst, ranked, lead, note)."""
    counts = dict((lv, 0) for lv in LEVERS)
    excluded = []
    for cause, cons in rows:
        if cause in MEASURED:
            counts[LEVER[cause]] += 1
        elif cause in EXCLUDED:
            excluded.append(cons or set())
    n = sum(counts.values())
    ranked = sorted(LEVERS, key=lambda lv: (-counts[lv], LEVERS.index(lv)))
    lead = counts[ranked[0]] - counts[ranked[1]]
    out = {"counts": counts, "n": n, "ranked": ranked, "lead": lead, "worst": None, "note": "", "lever": ""}
    top = ranked[0]
    if n and counts[top] * 2 > n:
        wx, wn = counts[top], n + len(excluded)
        wx += sum(1 for cons in excluded if cons and all(LEVER[c] == top for c in cons))
        out["worst"] = (top, wx, wn)
        if wx * 2 > wn:
            out["kind"], out["lever"] = "DOMINANT", top
            return out
        out["note"] = "majority of N lost under the worst case"
    if n and lead >= SELECT_LEAD:
        out["kind"], out["lever"] = "SELECTED", top
        return out
    out["kind"] = "SPLIT"
    return out


def _verdict_line(d, label):
    ranked = ", ".join("%s %d" % (lv, d["counts"][lv]) for lv in d["ranked"])
    if d["kind"] == "SPLIT":
        head = "%s: SPLIT (no lever selected; ranked: %s; N=%d)" % (label, ranked, d["n"])
    elif d["kind"] == "DOMINANT":
        head = "%s: DOMINANT %s (%d of N=%d; worst case %d of %d)" % (
            label, d["lever"], d["counts"][d["lever"]], d["n"], d["worst"][1], d["worst"][2])
    else:
        head = "%s: SELECTED %s, not dominant (lead %d over %s; ranked: %s; N=%d)" % (
            label, d["lever"], d["lead"], d["ranked"][1], ranked, d["n"])
    if d["note"]:
        head += " — " + d["note"] + " (worst case %d of %d)" % (d["worst"][1], d["worst"][2])
    return head


def render(inv_rows, results):
    tbl = ["# " + HEADER, "",
           "Pointed runs bound what the hunter can REACH when told where to look; they never measure what it would "
           "have selected.", "",
           "| contest | row | found-by | unpointed | exposure | L0 | L0r2 | L1 | L2 | deep | forge | cause | model "
           "| checkout | ladder sha | evidence | notes |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for inv, r in zip(inv_rows, results):
        m = r["meta"]
        cause = r["cause"] + (" (%s)" % r["sub"] if r["sub"] else "")
        tbl.append("| %s |" % " | ".join([
            inv["contest"], inv["row"], inv["found_by"], inv["unpointed"], inv["exposure"],
            r["cells"]["L0r1"], r["cells"]["L0r2"], r["cells"]["L1"], r["cells"]["L2"], r["cells"]["deep"],
            "not run", cause, m.get("model", "-"), m.get("checkout_commit", "-")[:12],
            m.get("ladder_sha256", "-")[:12], m.get("evidence", "-"), ", ".join(r["notes"]) or "-"]))
    cc = dict((c, 0) for c in CAUSE_ORDER)
    for r in results:
        cc[r["cause"]] += 1
    tbl += ["", "## Cause counts", "", "| cause | rows | lever |", "|---|---|---|"]
    for c in CAUSE_ORDER:
        tbl.append("| %s | %d | %s |" % (c, cc[c], LEVER.get(c, "excluded")))
    d = decide([(r["cause"], r["consistent"]) for r in results])
    tbl += ["", "## Lever counts", "", "| lever | rows |", "|---|---|"]
    for lv in d["ranked"]:
        tbl.append("| %s | %d |" % (lv, d["counts"][lv]))
    verdict = [HEADER, _verdict_line(d, "VERDICT")]
    verdict.append("RULE: DOMINANT = a strict majority of N that survives the worst case; else SELECTED = a "
                   "plurality lead >= %d rows; else SPLIT" % SELECT_LEAD)
    if d["worst"]:
        verdict.append("WORST-CASE: %s %d of %d (every excluded row in the denominator)" % d["worst"])
    lv = d["lever"] or d["ranked"][0]
    subs = {}
    for r in results:
        if r["cause"] in MEASURED and LEVER[r["cause"]] == lv:
            key = r["cause"] + ":" + (r["sub"] or "none")
            subs[key] = subs.get(key, 0) + 1
    verdict.append("SUB-SPLIT %s: %s" % (lv, ", ".join("%s %d" % (k, subs[k]) for k in sorted(subs)) or "-"))
    ex = [(r["cause"], inv["row"], inv["contest"], sorted(r["consistent"] or [])) for inv, r in zip(inv_rows, results)
          if r["cause"] in EXCLUDED]
    verdict.append("EXCLUDED: %s" % ("; ".join("%s %s %s (consistent: %s)" % (c, ct, rw, ",".join(cs))
                                               for c, rw, ct, cs in ex) or "-"))
    fb1 = [(r["cause"], r["consistent"]) for inv, r in zip(inv_rows, results) if inv["found_by"] == "1"]
    verdict.append(_verdict_line(decide(fb1), "FOUND-BY=1 SUBSET"))
    verdict.append("No recall figure: a pointed HIT is reachability, not selection.")
    tbl += ["", "## Verdict", ""] + verdict[1:]
    return "\n".join(tbl) + "\n", "\n".join(verdict) + "\n"


def classify(inventory, scores_dir):
    inv_rows = read_tsv(inventory, INVENTORY_COLS, "inventory")
    for r in inv_rows:
        if r["exposure"] not in EXPOSURES:
            die(3, "%s:%d: exposure must be one of %s" % (inventory, r["line"], "/".join(EXPOSURES)))
        if r["ptr_id"] != "-" and not re.match(r"^[a-z0-9]{3,12}$", r["ptr_id"]):
            die(3, "%s:%d: bad ptr_id %r" % (inventory, r["line"], r["ptr_id"]))
    results = [classify_row(r, scores_dir) for r in inv_rows]
    return render(inv_rows, results), inv_rows, results


def cmd_classify(argv):
    f = _flags(argv, ("--inventory", "--scores", "--table", "--verdict"))
    if not f.get("--inventory") or not f.get("--scores"):
        die(2, "usage: classify --inventory <inventory.tsv> --scores <dir> [--table <f>] [--verdict <f>]")
    (table, verdict), _, _ = classify(f["--inventory"], f["--scores"])
    for key, text in (("--table", table), ("--verdict", verdict)):
        if f.get(key):
            with open(f[key], "w", encoding="utf-8") as fh:
                fh.write(text)
        else:
            sys.stdout.write(text + ("\n" if key == "--table" else ""))
    return 0


# ----------------------------------------------------------------------------------------------------------
# self-test
# ----------------------------------------------------------------------------------------------------------
def self_test():
    fails = []

    def check(ok, what):
        sys.stdout.write("  [%s] %s\n" % ("OK" if ok else "FAIL", what))
        if not ok:
            fails.append(what)
    for f in ("inventory.tsv", "expected-table.md", "expected-verdict.txt", "judge-stub.sh", "hint-ladder.tsv",
              "truth/fx/truth.tsv"):
        if not os.path.exists(os.path.join(FIX, f)):
            die(3, "fixture missing: " + os.path.join(FIX, f))
    print("ladder-classify.py self-test: classify over fixtures/ladder/")
    (table, verdict), inv, res = classify(os.path.join(FIX, "inventory.tsv"), os.path.join(FIX, "scores"))
    with open(os.path.join(FIX, "expected-table.md"), encoding="utf-8") as fh:
        check(fh.read() == table, "the per-row table + cause / lever counts reproduce expected-table.md byte for byte")
    with open(os.path.join(FIX, "expected-verdict.txt"), encoding="utf-8") as fh:
        check(fh.read() == verdict, "the verdict reproduces expected-verdict.txt byte for byte")
    labels = set(r["cause"] + (":" + r["sub"] if r["sub"] else "") for r in res)
    want = {"UNPOINTABLE", "LOCATION:unseen", "LOCATION:examined", "LOCATION:out-of-map", "EXECUTION", "HINT:L1",
            "HINT:L2", "HINT:L2=L1", "MECHANISM", "MECHANISM:dismissed", "MECHANISM-or-EXECUTION", "UNMEASURED"}
    check(want <= labels, "one fixture row per class and sub-label (missing: %s)" % (",".join(sorted(want - labels))
                                                                                      or "none"))
    by_row = dict((i["row"], r) for i, r in zip(inv, res))
    check(by_row["FX-4"]["cause"] == "LOCATION" and by_row["FX-4"]["cells"]["deep"] == "HIT",
          "precedence: L0 HIT + deep HIT -> LOCATION")
    check(by_row["FX-5"]["cause"] == "EXECUTION" and by_row["FX-5"]["cells"]["L2"] == "HIT",
          "precedence: deep HIT + L2 HIT -> EXECUTION (the deep hunt ran with the function pointer only)")
    check(by_row["FX-3"]["cause"] == "LOCATION" and by_row["FX-3"]["cells"]["L0r1"] == "MISS"
          and by_row["FX-3"]["cells"]["L0r2"] == "HIT" and by_row["FX-3"]["cells"]["L1"] == "HIT",
          "precedence: L0 r1 MISS, r2 HIT, L1 HIT -> LOCATION")
    check(HEADER in table.split("\n")[0] and verdict.startswith(HEADER) and "%" not in table and "%" not in verdict,
          "the DIAGNOSTIC header heads both outputs and no `%` recall figure appears anywhere")
    check("pointer-cited" in table, "a DISMISS citing the pointer block is flagged pointer-cited")

    print("ladder-classify.py self-test: the decision rule (all four verdicts)")
    loc, ex, hint, mech = ("LOCATION", None), ("EXECUTION", None), ("HINT", None), ("MECHANISM", None)
    moe = ("MECHANISM-or-EXECUTION", {"MECHANISM", "EXECUTION"})
    d = decide([mech] * 4 + [hint] + [loc] * 2 + [ex] + [moe])
    check(d["kind"] == "DOMINANT" and d["lever"] == "generation" and d["worst"] == ("generation", 5, 9),
          "DOMINANT: generation 5 of N=8, still 5 of 9 with the excluded row counted against it")
    d = decide([mech] * 4 + [loc] * 2 + [ex] + [moe] * 2)
    check(d["kind"] == "SPLIT" and d["note"] and d["worst"] == ("generation", 4, 9),
          "a strict majority (generation 4 of N=7) LOST under the worst case (4 of 9); lead 2 < 3 -> SPLIT")
    d = decide([mech] * 4 + [loc] + [ex] + [moe] * 3)
    check(d["kind"] == "SELECTED" and d["lever"] == "generation" and d["lead"] == 3 and d["note"],
          "SELECTED (not dominant): the majority (4 of 6) is lost under the worst case (4 of 9), the lead of 3 holds")
    d = decide([hint] * 6 + [loc] * 3 + [ex] * 3)
    check(d["kind"] == "SELECTED" and d["lever"] == "generation" and d["worst"] is None,
          "SELECTED without any majority: generation 6 of N=12 (not strict), lead 3 over coverage/selection")
    d = decide([hint] * 4 + [loc] * 3 + [ex])
    check(d["kind"] == "SPLIT" and d["lever"] == "" and d["ranked"][:2] == ["generation", "coverage/selection"],
          "SPLIT: no strict majority (4 of 8), lead 1 < 3; levers ranked, no lever selected")
    unm_all_gen = ("UNMEASURED", {"MECHANISM", "HINT"})
    d = decide([mech] * 3 + [loc] * 2 + [unm_all_gen] * 2)
    check(d["kind"] == "DOMINANT" and d["worst"] == ("generation", 5, 7),
          "worst case: an excluded row whose every consistent class maps to the lever still counts FOR it (5 of 7)")

    print("ladder-classify.py self-test: hint-gate exit codes through the judge stub")
    sm = _score_match()
    stub = os.path.join(FIX, "judge-stub.sh")
    tdir = os.path.join(FIX, "truth")
    work = tempfile.mkdtemp(prefix="ladder-classify-st.")
    try:
        full = os.path.join(FIX, "hint-ladder.tsv")
        clean = os.path.join(work, "clean.tsv")
        with open(full, encoding="utf-8") as fh, open(clean, "w", encoding="utf-8") as out:
            for line in fh:
                if "\tFX-2\t" not in line:
                    out.write(line)

        def gate(path, mode="verdict"):
            env = dict(os.environ, LADDER_JUDGE_STUB_MODE=mode)
            proc = subprocess.run([sys.executable, os.path.abspath(__file__), "hint-gate", "--ladder", path,
                                   "--truth-dir", tdir, "--judge", stub], capture_output=True, text=True, env=env)
            return proc.returncode, proc.stdout
        rc, out = gate(clean)
        check(rc == 0 and out.count("\tCLEAN\t") == 2, "hint-gate exit 0: both hints of the clean row judged CLEAN")
        rc, out = gate(full)
        check(rc == 4 and "h2b\tL1\tLEAK\t" in out and "h2b\tL2" not in out,
              "hint-gate exit 4: an L1 that states the mechanism is a LEAK (an `=L1` L2 is not judged)")
        rc, out = gate(full, "malformed")
        check(rc == 3 and "JUDGE-ERROR" in out, "hint-gate exit 3: an unparseable judge reply fails closed")

        print("ladder-classify.py self-test: score over a synthetic pointed arm")
        arm = _synthetic_arm(work)
        kv = dict(score_arm(arm, "FX-1", stub, "", "", sm))
        check(kv["cell"] == "L0r1" and kv["void"] == "VALID" and kv["breadth_leads"] == "3"
              and kv["breadth_judge"] == "MATCH" and kv["breadth_matched"] == "src/pool/Pool.sol:withdraw:17"
              and kv["breadth_confirmed"] == "-",
              "score: every pre-refute candidate (tier 1 + tier 2) is judged; the matching lead is named, the operator "
              "confirmation left open")
        check(kv["dismissed"] == "1" and kv["pointer_cited"] == "1" and kv["dismiss_lines"] == "2",
              "score: a DISMISS line naming the mechanism sets dismissed=1; one citing the pointer block sets "
              "pointer_cited=1; the superseded attempt's DISMISS is not read")
        check(kv["deep"] == "MATCH" and kv["deep_cells"] == "finding=1 clean=1 not_judged=0"
              and kv["judge_errors"] == "0" and kv["refute_verified"] == "0"
              and kv["evidence"] == "arms/fx/src_pool/ptr-k7q-L0-r1",
              "score: only INVARIANT lines at the anchor file count (FINDING judged, CLEAN counted); evidence is "
              "exam-root-relative")
        dh = os.path.join(arm, "fx", "zone-hunt-out", "deep-hunt")
        with open(os.path.join(dh, "src_pool-C1", "run", "invariant_src_pool_Pool_sol_withdraw.log"), "w",
                  encoding="utf-8") as fh:
            fh.write("INVARIANT-PROPERTY totalSupplyNonZero violated after deposit\n"
                     "INVARIANT|src/pool/Pool.sol:withdraw|FINDING\n")
        with open(os.path.join(dh, "src_pool-C6", "run", "invariant_src_pool_Pool_sol_deposit.log"), "w",
                  encoding="utf-8") as fh:
            fh.write("INVARIANT|src/pool/Pool.sol:deposit|TIMEOUT\n")
        kv = dict(score_arm(arm, "FX-1", stub, "", "", sm))
        check(kv["deep"] == "UNMEASURED" and kv["deep_cells"] == "finding=1 clean=0 not_judged=1",
              "score: a non-matching FINDING beside a TIMEOUT sibling is deep UNMEASURED (as CLEAN + TIMEOUT is), "
              "never a deep MISS")

        print("ladder-classify.py self-test: a VOID L0 r2 replicate")
        sdir = os.path.join(work, "scores-r2void")
        os.makedirs(sdir)
        for c in CELLS:
            shutil.copy(os.path.join(FIX, "scores", "a06.%s.score" % c), sdir)
        r2 = os.path.join(sdir, "a06.L0r2.score")
        with open(r2, encoding="utf-8") as fh:
            body = fh.read().replace("\nvoid=VALID\n", "\nvoid=VOID:transport\n")
        with open(r2, "w", encoding="utf-8") as fh:
            fh.write(body)
        inv6 = [i for i in inv if i["row"] == "FX-6"][0]
        r = classify_row(inv6, sdir)
        check(r["cells"]["L0r1"] == "MISS" and r["cells"]["L0r2"] == "UNMEASURED" and r["cells"]["L1"] == "HIT"
              and r["cause"] == "UNMEASURED" and r["consistent"] == {"LOCATION", "HINT"},
              "classify: L0 r1 MISS + r2 VOID + L1 HIT -> UNMEASURED (a VOID r2 is no replicate), not HINT")
        with open(os.path.join(arm, "void.txt"), "w", encoding="utf-8") as fh:
            fh.write("VOID\ttransport\tcell\n")
        kv = dict(score_arm(arm, "FX-1", stub, "", "", sm))
        check(kv["void"] == "VOID:transport" and kv["breadth_judge"] == "-" and kv["deep"] == "UNMEASURED",
              "score: a VOID arm scores UNMEASURED (no judging at all)")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return fails


def _synthetic_arm(work):
    """A finished pointed arm laid out like exam.sh's, for the score self-test."""
    arm = os.path.join(work, "arms", "fx", "src_pool", "ptr-k7q-L0-r1")
    out = os.path.join(arm, "fx", "zone-hunt-out")
    files = {
        "run.meta": "contest=fx\nrepeat=1\nrc=0\ndeep_pass=1\ndeep_rc=0\ndeep_status=ran\nmodel=claude-opus-4-8\n"
                    "checkout_commit=0123456789abcdef0123\n",
        "stage.meta": "pointer_id=k7q\npointer_rung=L0\nladder_sha256=feedfacefeedface\n"
                      "pointer_anchors=src/pool/Pool.sol:withdraw\npointer_l2_eq_l1=0\n",
        "void.txt": "VALID\n",
        "fx/zone-hunt-out/discovery/discovery-results.merged.json": json.dumps({
            "cells": [{"subsystem": "share pool", "class": "C1", "candidates": [
                "src/pool/Pool.sol:withdraw:17|C1|High|withdraw pays the exit before the share burn|skew, then withdraw",
                "src/pool/Pool.sol:deposit:10|C6|Medium|deposit rounds in the caller favour|deposit dust"]}],
            "tier2": [{"location": "src/feed/Feed.sol:read:5", "class": "C2", "check": "freshness bound unchecked"}]}),
        "fx/zone-hunt-out/discovery/src_pool/run/hunt_share_pool_C1.log":
            "DISMISS|src/pool/Pool.sol:withdraw|ordering|dismissed: the exit is paid before the burn but deemed dust\n"
            "DISMISS|src/pool/Pool.sol:deposit|scope|the operator pointer says to look elsewhere\nSAFE\n",
        "fx/zone-hunt-out/discovery/src_pool.attempt-1/run/hunt_share_pool_C1.log":
            "DISMISS|src/pool/Pool.sol:withdraw|ordering|dismissed: the exit is paid before the burn (superseded)\n",
        "fx/zone-hunt-out/deep-hunt/src_pool-C1/run/invariant_src_pool_Pool_sol_withdraw.log":
            "INVARIANT-PROPERTY sharesBackedByAssets violated after withdraw\n"
            "INVARIANT|src/pool/Pool.sol:withdraw|FINDING\n",
        "fx/zone-hunt-out/deep-hunt/src_pool-C6/run/invariant_src_pool_Pool_sol_deposit.log":
            "INVARIANT|src/pool/Pool.sol:deposit|CLEAN\n",
        "fx/zone-hunt-out/deep-hunt/src_feed-C2/run/invariant_src_feed_Feed_sol_read.log":
            "INVARIANT|src/feed/Feed.sol:read|FINDING\n",
        "fx/zone-hunt-out/verify/verified_findings.json": "{\"verified\": []}\n",
    }
    for rel, text in files.items():
        path = os.path.join(arm, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
    os.makedirs(os.path.join(arm, "_gt", "fx"), exist_ok=True)
    shutil.copy(os.path.join(FIX, "truth", "fx", "truth.tsv"), os.path.join(arm, "_gt", "fx", "truth.tsv"))
    return arm


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stdout.write("usage: ladder-classify.py <hint-gate|score|classify|--self-test> ...\n")
        return 0 if len(argv) >= 2 else 2
    if argv[1] == "--self-test":
        fails = self_test()
        print("ladder-classify.py self-test: %s" % ("PASS" if not fails else "FAILED (%d)" % len(fails)))
        return 1 if fails else 0
    cmds = {"hint-gate": cmd_hint_gate, "score": cmd_score, "classify": cmd_classify}
    if argv[1] not in cmds:
        die(2, "unknown subcommand: " + argv[1])
    return cmds[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
