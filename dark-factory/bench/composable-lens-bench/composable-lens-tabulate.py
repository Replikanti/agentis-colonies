#!/usr/bin/env python3
# composable-lens-tabulate.py — #1914 M4 (epic #1914). The PURE, side-effect-free scoring core of the
# composable-lens transfer bench. run-composable-lens-bench.sh owns the orchestration (clone corpus targets,
# run `run-zone-hunt.sh --deep-hunt --composable-lens`); THIS module owns the three decisions the bench turns
# on, isolated so the offline --self-test can drive them over synthetic inputs with NO live run:
#
#   1. per-target TABULATION — read the M3 `<out>/coverage/lens-surface-matrix.json` (schema
#      `lens-surface-matrix/v1`) and roll its SYS-solvency surfaces up to a per-target verdict count
#      {FINDING, CLEAN, HARNESS_ERROR}. HARNESS_ERROR is counted DISTINCTLY from CLEAN — a settlement seam
#      whose harness failed to compile is an un-probed GAP, never a clean negative (the whole reason M3's
#      record exists). The raw `deep-hunt/*/run/invariant_*.log` `INVARIANT|<t>|<verdict>` lines are the
#      fallback source when a matrix is absent, filtering the #1778 per-candidate `_c<N>.log` exactly as the
#      #1780 merge adapter does.
#
#   2. ADVERSARY-PATH assertion — a composable run that deploys `hooks: address(0)` produces a VACUOUS CLEAN:
#      the invariant held only because no adversarial actor ever drove the composition seam. So a CLEAN/FINDING
#      is counted as MEANINGFUL only if the generated composable test source actually instantiated a
#      NON-`address(0)` adversarial actor (a Handler/Hook/Adapter/Attacker) wired into the target set. A run
#      that did not drive the adversary path is FLAGGED and never counted as a meaningful CLEAN.
#
#   3. CATCH-COUNTING + the M4 gate — a target is a CATCH iff it has >=1 SYS-solvency FINDING that is
#      adversary-driven (meaningful). The M4 acceptance is CATCH on >=2 DISTINCT targets (transfer: the general
#      lens works beyond the single surface it was shaped on). `summarize` exits non-zero when the gate is unmet
#      so a live run's pass/fail is unambiguous.
#
# depth_per_zone: the effective per-zone depth is read from `<out>/coverage/zone-coverage.json`
# (`budget.depth_per_zone`, #1880 — present only when the sweep ceiling bit). Recorded next to every number;
# a recall figure is quoted against THAT, never the nominal flag.
#
# Subcommands:
#   eval-target --id <id> --out <zone-hunt-out-dir> [--out-record <file>]
#       Emit ONE per-target record (JSON) from a run's out dir. Reads the matrix, the raw invariant logs, the
#       generated composable test source and the coverage record. No live work — pure filesystem read.
#   adversary-scan --dir <dir> [--json]
#       Scan every *.t.sol under <dir> for a non-address(0) adversarial actor. `driven`/`vacuous` + the matched
#       actor. Exposed standalone so the self-test can pin the heuristic on synthetic sources.
#   summarize --records-dir <dir> [--json]
#       Read every *.json record in <dir>, print the human table (or --json machine summary), and CHECK the M4
#       gate (>=2 distinct catch targets). Exit 0 = gate met ; 1 = gate unmet.
#
# Exit: 0 ok / gate met ; 1 gate unmet (summarize only) ; 2 usage ; 3 unreadable/malformed input.
import sys
import os
import re
import glob
import json

VERDICTS = ("FINDING", "CLEAN", "HARNESS_ERROR")

# An adversarial actor the composable-fresh harness instantiates to DRIVE the composition seam: a Handler that
# calls hostile action space, or a permissionless Hook/Adapter/Attacker/Adversary/Actor. The composable-solvency
# invariant is vacuous without one — see the module header.
ACTOR_RE = re.compile(
    r"\bnew\s+(\w*(?:Handler|Hook|Adapter|Attacker|Adversary|Actor)\w*)\s*\(", re.IGNORECASE)
# A hook/adapter/attacker/actor wired to the ZERO address — the exact vacuous-CLEAN caveat this bench guards.
# Matches `hooks: address(0)`, `IHook(address(0))`, `hook = address(0)`, `adapter := address(0)`.
ZERO_HOOK_RE = re.compile(
    r"(?:hook|adapter|attacker|adversary|actor)\w*\s*[=:(]\s*(?:I?\w+\s*\(\s*)?address\(0\)", re.IGNORECASE)
# The #1778 ensemble writes per-candidate `invariant_<t>_c<N>.log` alongside the aggregate `invariant_<t>.log`;
# read only the aggregate (the #1780 merge adapter's own filter).
PER_CANDIDATE_RE = re.compile(r"_c[0-9]+\.log$")


def die(code, msg):
    sys.stderr.write("composable-lens-tabulate.py: " + msg + "\n")
    sys.exit(code)


def parse_flags(argv, valued, boolean):
    out = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in valued:
            if i + 1 >= len(argv):
                die(2, "missing value for " + a)
            out[a] = argv[i + 1]
            i += 2
        elif a in boolean:
            out[a] = True
            i += 1
        else:
            die(2, "unknown/misplaced arg: " + a)
    return out


def read_json(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as e:  # noqa: BLE001 — any read/parse failure is a hard input error.
        die(3, "cannot read %s (%s): %s" % (what, path, e))


# ----------------------------------------------------------------------------------------------------------
# TABULATION — per-target SYS-solvency verdict counts, HARNESS_ERROR distinct from CLEAN.
# ----------------------------------------------------------------------------------------------------------
def verdicts_from_matrix(matrix_path):
    """Roll the M3 lens-surface matrix up to {FINDING, CLEAN, HARNESS_ERROR} over its general-solvency surfaces.

    Only `lens_depth == general-solvency` surfaces carry a verdict (that is the M3 contract), so a narrow /
    discovery-only surface contributes nothing here — the count is over surfaces the SYS-solvency lens actually
    reached. Returns None when the matrix is absent/malformed so the caller can fall back to the raw logs."""
    if not os.path.isfile(matrix_path):
        return None
    try:
        with open(matrix_path, encoding="utf-8") as fh:
            rec = json.load(fh)
    except Exception:
        return None
    surfaces = rec.get("surfaces") if isinstance(rec, dict) else None
    if not isinstance(surfaces, list):
        return None
    counts = dict((v, 0) for v in VERDICTS)
    for s in surfaces:
        if not isinstance(s, dict):
            continue
        if s.get("lens_depth") != "general-solvency":
            continue
        v = s.get("verdict")
        if v in counts:
            counts[v] += 1
    return counts


def verdicts_from_logs(out_dir):
    """Fallback: read every aggregate `deep-hunt/*/run/invariant_*.log` INVARIANT| verdict. A rundir with NO
    aggregate log / no INVARIANT| line is a HARNESS_ERROR (the harness never produced a verdict — an un-probed
    GAP), pessimistically, never a CLEAN. Filters the #1778 per-candidate `_c<N>.log` like the #1780 adapter."""
    counts = dict((v, 0) for v in VERDICTS)
    rundirs = sorted(glob.glob(os.path.join(out_dir, "deep-hunt", "*", "run")))
    # Only SYS-solvency rundirs carry the general lens; a per-class rundir (…-C6/, …-C2/) is not this lens.
    sys_rundirs = [d for d in rundirs if "SYS-solvency" in os.path.basename(os.path.dirname(d))]
    for rd in sys_rundirs:
        logs = sorted(glob.glob(os.path.join(rd, "invariant_*.log")))
        logs = [p for p in logs if not PER_CANDIDATE_RE.search(os.path.basename(p))]
        verdict = "HARNESS_ERROR"
        if logs:
            with open(logs[-1], encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    if "INVARIANT|" in line:
                        cols = line.split("INVARIANT|", 1)[1].strip().split("|")
                        if len(cols) >= 2 and cols[1].strip() in VERDICTS:
                            verdict = cols[1].strip()
        counts[verdict] += 1
    return counts


# ----------------------------------------------------------------------------------------------------------
# ADVERSARY-PATH — did the generated composable test source instantiate a non-address(0) adversarial actor?
# ----------------------------------------------------------------------------------------------------------
def scan_source(text):
    """(driven, actor) for one test source. driven = an adversarial actor was instantiated AND no hook/adapter
    was wired to address(0). A `new Handler(...)` alongside `hooks: address(0)` is NOT driven — the exact
    vacuous-CLEAN caveat."""
    actor_m = ACTOR_RE.search(text)
    zero = ZERO_HOOK_RE.search(text)
    driven = bool(actor_m) and not zero
    actor = actor_m.group(1) if actor_m else None
    return driven, actor


def adversary_scan_dir(dir_path):
    """Scan every *.t.sol under dir_path. The composition seam is driven iff AT LEAST ONE generated test
    instantiated a non-address(0) adversarial actor and none nulled its hook — a single vacuous file does not
    veto a sibling that genuinely drove the seam, but a run with NO driven file is vacuous."""
    sources = sorted(glob.glob(os.path.join(dir_path, "**", "*.t.sol"), recursive=True))
    scanned = 0
    driven = False
    actor = None
    zero_seen = False
    for src in sources:
        try:
            with open(src, encoding="utf-8", errors="ignore") as fh:
                text = fh.read()
        except Exception:
            continue
        scanned += 1
        d, a = scan_source(text)
        if ZERO_HOOK_RE.search(text):
            zero_seen = True
        if d and not driven:
            driven = True
            actor = a
    return {
        "driven": driven,
        "actor": actor,
        "files_scanned": scanned,
        "zero_hook_seen": zero_seen,
    }


# ----------------------------------------------------------------------------------------------------------
# depth_per_zone — the EFFECTIVE per-zone depth from the coverage record (#1880), NOT the nominal flag.
# ----------------------------------------------------------------------------------------------------------
def depth_per_zone(out_dir):
    cov = os.path.join(out_dir, "coverage", "zone-coverage.json")
    if not os.path.isfile(cov):
        return None
    try:
        with open(cov, encoding="utf-8") as fh:
            rec = json.load(fh)
    except Exception:
        return None
    budget = rec.get("budget") if isinstance(rec, dict) else None
    if isinstance(budget, dict) and "depth_per_zone" in budget:
        return budget["depth_per_zone"]
    return None


# ----------------------------------------------------------------------------------------------------------
# eval-target — ONE per-target record.
# ----------------------------------------------------------------------------------------------------------
def cmd_eval_target(argv):
    f = parse_flags(argv, ("--id", "--out", "--out-record"), ())
    for req in ("--id", "--out"):
        if req not in f:
            die(2, "eval-target requires " + req)
    tid = f["--id"]
    out_dir = f["--out"]
    matrix_path = os.path.join(out_dir, "coverage", "lens-surface-matrix.json")
    counts = verdicts_from_matrix(matrix_path)
    source = "lens-surface-matrix"
    if counts is None:
        counts = verdicts_from_logs(out_dir)
        source = "invariant-logs"
    # Adversary-path over the SYS-solvency rundirs (where the composable test source lives).
    adv_dirs = sorted(glob.glob(os.path.join(out_dir, "deep-hunt", "*SYS-solvency*")))
    adv = {"driven": False, "actor": None, "files_scanned": 0, "zero_hook_seen": False}
    for d in adv_dirs:
        one = adversary_scan_dir(d)
        adv["files_scanned"] += one["files_scanned"]
        adv["zero_hook_seen"] = adv["zero_hook_seen"] or one["zero_hook_seen"]
        if one["driven"] and not adv["driven"]:
            adv["driven"] = True
            adv["actor"] = one["actor"]
    # A CATCH is a FINDING the adversary path actually drove — a FINDING from a vacuous run is NOT meaningful.
    meaningful = adv["driven"]
    catch = counts["FINDING"] >= 1 and meaningful
    record = {
        "schema": "composable-lens-bench-target/v1",
        "id": tid,
        "verdict_source": source,
        "verdicts": counts,
        "catch": catch,
        "meaningful": meaningful,
        "adversary_path": adv,
        "depth_per_zone": depth_per_zone(out_dir),
        "harness_error": counts["HARNESS_ERROR"] > 0,
    }
    text = json.dumps(record, indent=2) + "\n"
    if f.get("--out-record"):
        with open(f["--out-record"], "w", encoding="utf-8") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)
    return 0


def cmd_adversary_scan(argv):
    f = parse_flags(argv, ("--dir",), ("--json",))
    if "--dir" not in f:
        die(2, "adversary-scan requires --dir")
    res = adversary_scan_dir(f["--dir"])
    if f.get("--json"):
        sys.stdout.write(json.dumps(res) + "\n")
    else:
        sys.stdout.write(
            "adversary-path: %s (actor=%s, files=%d, zero_hook_seen=%s)\n"
            % ("driven" if res["driven"] else "VACUOUS",
               res["actor"] or "-", res["files_scanned"], res["zero_hook_seen"]))
    return 0


# ----------------------------------------------------------------------------------------------------------
# summarize — the human table + machine JSON + the M4 gate (>=2 distinct catch targets).
# ----------------------------------------------------------------------------------------------------------
GATE_MIN_CATCH_TARGETS = 2


def cmd_summarize(argv):
    f = parse_flags(argv, ("--records-dir",), ("--json",))
    if "--records-dir" not in f:
        die(2, "summarize requires --records-dir")
    paths = sorted(glob.glob(os.path.join(f["--records-dir"], "*.json")))
    records = []
    for p in paths:
        rec = read_json(p, "target record")
        if isinstance(rec, dict) and rec.get("schema") == "composable-lens-bench-target/v1":
            records.append(rec)
    catch_targets = [r["id"] for r in records if r.get("catch")]
    harness_error_targets = [r["id"] for r in records if r.get("harness_error")]
    vacuous_targets = [r["id"] for r in records
                       if not r.get("meaningful") and r.get("adversary_path", {}).get("files_scanned", 0) > 0]
    gate_met = len(set(catch_targets)) >= GATE_MIN_CATCH_TARGETS
    summary = {
        "schema": "composable-lens-bench/v1",
        "targets": len(records),
        "catch_targets": sorted(set(catch_targets)),
        "catch_target_count": len(set(catch_targets)),
        "gate_min_catch_targets": GATE_MIN_CATCH_TARGETS,
        "gate_met": gate_met,
        "harness_error_targets": harness_error_targets,
        "vacuous_targets": vacuous_targets,
        "per_target": [
            {
                "id": r["id"],
                "verdicts": r.get("verdicts", {}),
                "catch": r.get("catch", False),
                "meaningful": r.get("meaningful", False),
                "adversary_actor": r.get("adversary_path", {}).get("actor"),
                "depth_per_zone": r.get("depth_per_zone"),
                "harness_error": r.get("harness_error", False),
            }
            for r in records
        ],
    }
    if f.get("--json"):
        sys.stdout.write(json.dumps(summary, indent=2) + "\n")
    else:
        _print_table(summary)
    return 0 if gate_met else 1


def _print_table(summary):
    w = sys.stdout.write
    w("composable-lens transfer bench — SYS-solvency lens per target\n")
    w("  (HARNESS_ERROR is a GAP, tabulated DISTINCTLY from CLEAN; a CATCH is an adversary-DRIVEN FINDING)\n")
    hdr = "%-14s %8s %6s %13s %7s %8s %13s" % (
        "target", "FINDING", "CLEAN", "HARNESS_ERROR", "catch", "adv", "depth/zone")
    w(hdr + "\n")
    w("-" * len(hdr) + "\n")
    for r in summary["per_target"]:
        v = r["verdicts"]
        dpz = r["depth_per_zone"]
        w("%-14s %8d %6d %13d %7s %8s %13s\n" % (
            r["id"],
            int(v.get("FINDING", 0)), int(v.get("CLEAN", 0)), int(v.get("HARNESS_ERROR", 0)),
            "YES" if r["catch"] else "-",
            (r["adversary_actor"] or "-") if r["meaningful"] else "VACUOUS",
            str(dpz) if dpz is not None else "unset(nominal)"))
    w("-" * len(hdr) + "\n")
    w("catch targets: %d (%s) — gate requires >=%d\n" % (
        summary["catch_target_count"], ", ".join(summary["catch_targets"]) or "none",
        summary["gate_min_catch_targets"]))
    if summary["harness_error_targets"]:
        w("HARNESS_ERROR GAP on: %s — un-probed seams, NOT clean negatives\n"
          % ", ".join(summary["harness_error_targets"]))
    if summary["vacuous_targets"]:
        w("VACUOUS (adversary path not driven — CLEAN/FINDING NOT counted) on: %s\n"
          % ", ".join(summary["vacuous_targets"]))
    w("M4 GATE: %s\n" % ("MET" if summary["gate_met"] else "NOT MET"))


COMMANDS = {
    "eval-target": cmd_eval_target,
    "adversary-scan": cmd_adversary_scan,
    "summarize": cmd_summarize,
}


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stderr.write("usage: composable-lens-tabulate.py <eval-target|adversary-scan|summarize> [flags]\n")
        return 0 if argv else 2
    cmd = argv[0]
    if cmd not in COMMANDS:
        die(2, "unknown subcommand: " + cmd)
    return COMMANDS[cmd](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
