#!/usr/bin/env python3
# zone-coverage.py — #1830 (epic #1611 M3). THE ZONE-COVERAGE RECORD: the one place that owns
# `<out>/coverage/zone-coverage.json`, the per-run machine-readable answer to "which zones did this hunt
# actually cover, and what is each zone's outcome entitled to conclude?".
#
# WHY IT EXISTS. Before #1830 a truncated zone-hunt was INDISTINGUISHABLE from a clean sweep: STAGE 3 logged
# a per-zone `run-discovery.sh` failure and continued, and the merge glob skipped any zone dir without a
# `discovery-results.json` exactly like a zone that never existed. The merged artifact then reported a
# plausible N-cell run with NO representation of the unhunted zones at all. (Measured on the preserved
# corpus-bench work dir: one target hunted 1 of 7 zones and its merged file looked clean.)
#
# THE CONTRACT. The record is written UNCONDITIONALLY and PESSIMISTICALLY: `init` writes one entry per zone
# in `zones.json` with `status: "not_reached"` BEFORE STAGE 3 runs a single zone, and each entry is rewritten
# in place as the zone transitions. ABSENCE IS THEREFORE NOT REPRESENTABLE — a zone can never be silently
# missing, only visibly `not_reached` — and an externally-imposed kill still leaves a truthful record on disk.
#
# THE STATE VOCABULARY (closed; consumers branch on `status`):
#   not_reached       written by `init` before the loop; never updated. ZERO EVIDENCE — not a negative.
#   no_brief          STAGE 2 emitted no brief for the zone. An UPSTREAM DEFECT; a re-hunt cannot fix it.
#   unscoped          the zone ran ZERO cells: it has no line in `scope.tsv` (map-zones.sh writes one only
#                     `if not skeleton and classes and z["id"] not in failed_zones`, so an unclassified or
#                     `classification_failed` zone is in zones.json and absent from the manifest), or its
#                     zones.json name does not match any manifest subsystem. ZERO EVIDENCE — an upstream
#                     MAPPING defect, and a re-hunt against the same map cannot fix it. NEVER a negative.
#   in_flight         set immediately before `run-discovery.sh` is invoked; survives only if the process died
#                     mid-zone. Attempt started, outcome unknown (external kill / OOM). Retry as-is.
#   failed            `run-discovery.sh` exited non-zero. Attempt made, the TOOL failed — not a negative.
#   budget_exhausted  admission denied: the remaining RUN cell budget was 0 when the zone came up. The zone is
#                     hunt-able; the run declined to pay. Every zone AFTER it was denied too (the pool is
#                     spent, so the loop stops). Remedy: raise --run-cell-budget, or --rehunt-gaps.
#   budget_unenforceable  admission denied for a reason that is LOCAL TO THIS ZONE: a partial cap cannot be
#                     expressed for it, because `--classes` is a per-manifest-LINE override and the zone's
#                     subsystem name matches SEVERAL scope.tsv lines, so no class prefix lands exactly on the
#                     cap (see run-zone-hunt.sh). Deliberately NOT `budget_exhausted`: no pool was spent, the
#                     zones after it are unaffected (the sweep continues), and the remedy is different —
#                     give this zone its full planned budget, or re-map so its subsystem name is unique.
#   hunted_degraded   exit 0 AND `totals.failed > 0` — at least one cell produced no sentinel (#1707).
#                     PARTIAL coverage, not a rigorous negative.
#   hunted_empty      exit 0, no failed cells, no candidates. A RIGOROUS NEGATIVE for the classes actually
#                     hunted — read together with `budget_truncated`.
#   hunted            exit 0, no failed cells, candidates > 0. Complete coverage of the classes hunted.
#
# `budget_truncated` is a QUALIFIER, not a status: a zone whose per-zone cap shortened its class list was
# genuinely hunted, but its `hunted_empty` is not a rigorous negative. Hence the two DERIVED fields, computed
# here so no consumer re-derives policy:
#   complete   = every zone is `hunted`/`hunted_empty` AND `budget_truncated == false`
#   gap_zones  = the ids of every zone that fails that test, in priority order
#
# Subcommands:
#   init --zones <zones.json> --out <coverage.json> --zone-list <.zone-list.tsv> --repo <name> --commit <sha>
#        [--zone-cell-budget N] [--run-cell-budget N]
#        Writes the record with every zone `not_reached` AND emits `.zone-list.tsv`. The #1826 priority sort
#        key `(not value_custody, id)` lives HERE (moved verbatim out of run-zone-hunt.sh's inline heredoc)
#        so the record's order and the hunt order provably cannot drift. A full re-sweep into an --out that
#        already has a record CARRIES `attempts[]` OVER per zone: that list is the retry HISTORY (and the
#        `--rehunt-max-attempts` give-up input), not per-run state — zeroing it would both un-bound the
#        give-up counter and make the next re-hunt reuse an `.attempt-<n>` suffix that is still on disk.
#   set --file <coverage.json> --zone <zid> [--status <s>] [--exit-code N] [--cells-planned N|null]
#       [--cells-charged N] [--classes CSV] [--budget-truncated] [--results <discovery-results.json>]
#       [--detail TEXT]
#       Atomic in-place update (tmp + os.replace), recomputes totals/complete/gap_zones. With `--results` it
#       reads `totals.{cells,candidates,failed}` and DERIVES the terminal status itself — the derivation
#       exists in exactly one place. Omitted fields keep their current value.
#   budget --file <coverage.json> --depth-total N --depth-per-zone M
#       #1880: record the sweep-level DEPTH ceiling that was actually in force — `budget.depth_total` (the
#       whole sweep's admitted depth cells) and `budget.depth_per_zone` (the EFFECTIVE per-zone allowance,
#       = min(--zone-depth-cells, depth_total / zone count)). run-zone-hunt.sh calls this ONCE, right after it
#       computes the allowance, and ONLY when the ceiling is on — so a run without it keeps a byte-identical
#       `budget` object (the `totals.depth_cells` precedent: a key that exists only where it means something).
#       A depth recall figure must be quoted against `depth_per_zone`, never against the nominal flag.
#   gaps --file <coverage.json> [--include-partial] [--max-attempts N]
#       The re-hunt work list in priority order, TSV `<zid>\t<name>\t<action>` where action is
#         hunt      a plain first attempt (not_reached / budget_exhausted) — nothing to preserve
#         retry     prior artifacts exist (failed / in_flight, or a partial under --include-partial): the
#                   caller MUST move `discovery/<zid>` aside and call `retry` before re-entering
#         capped    `attempts` already has >= --max-attempts entries; leave it alone
#         no-brief  never selected — the missing prerequisite is NOT collapsed into a retryable failure
#         unscoped  never selected — the zone is absent from scope.tsv, which a re-hunt cannot change
#   retry --file <coverage.json> --zone <zid> --artifacts <relpath>
#       Push the prior terminal state into `attempts[]` and reset the zone to `not_reached` for a new attempt.
#   summary --file <coverage.json> [--counts | --json]
#       Default: the fail-loud banner lines (empty when the run IS a clean sweep). `--counts`: `<covered>
#       <total>`. `--json`: the additive `coverage` object embedded into `discovery-results.merged.json`.
#
# Paths in `results` / `attempts[].artifacts` are relative to `<out>` (the record's grandparent dir) so the
# record is portable. Exit: 0 ok ; 2 usage/unknown zone ; 3 unreadable/malformed input.
import sys
import os
import json
import datetime

# The closed status vocabulary, in the order `totals.by_status` reports it (best outcome first).
STATUSES = (
    "hunted",
    "hunted_empty",
    "hunted_degraded",
    "failed",
    "budget_exhausted",
    "budget_unenforceable",
    "in_flight",
    "no_brief",
    "unscoped",
    "not_reached",
)
# A zone is COVERED only when it was hunted to completion; everything else is a gap. `unscoped` is
# deliberately NOT here: a zone that ran zero cells is not a negative of any kind (see the header).
COVERED_STATUSES = ("hunted", "hunted_empty")
# Statuses whose remedy is "run the zone again" — the default re-hunt work set. `budget_unenforceable` is here
# because a re-hunt with no cap (or a cap >= the zone's planned cells) hunts it in full; it never ran, so it
# has nothing to preserve and is a plain first attempt.
RETRYABLE_STATUSES = ("not_reached", "budget_exhausted", "budget_unenforceable", "in_flight", "failed")
# Statuses that already produced artifacts, so a re-entry would destroy evidence unless it is moved aside.
HAS_ARTIFACTS = ("in_flight", "failed", "hunted", "hunted_empty", "hunted_degraded")

SCHEMA = "zone-coverage/v1"


def die(rc, msg):
    sys.stderr.write("zone-coverage.py: " + msg + "\n")
    sys.exit(rc)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_flags(argv, valued, boolean):
    """Manual flag walk (the repo's helper idiom — no argparse). Returns {flag: value}; a boolean flag maps to
    True. Unknown flags and missing values are usage errors, never silent."""
    out = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in valued:
            if i + 1 >= len(argv):
                die(2, a + " requires a value")
            out[a] = argv[i + 1]
            i += 2
        elif a in boolean:
            out[a] = True
            i += 1
        else:
            die(2, "unknown arg: " + a)
    return out


def read_json(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as e:
        die(3, "cannot read " + what + ": " + str(e))


def load_record(path):
    rec = read_json(path, "the coverage record")
    if not isinstance(rec, dict) or not isinstance(rec.get("zones"), list):
        die(3, "malformed coverage record: " + path)
    return rec


def out_root(coverage_path):
    """`<out>` for a record at `<out>/coverage/zone-coverage.json` — the anchor every stored relpath uses."""
    return os.path.dirname(os.path.dirname(os.path.abspath(coverage_path)))


def relative_to_out(coverage_path, path):
    try:
        return os.path.relpath(os.path.abspath(path), out_root(coverage_path))
    except ValueError:
        return path


def recompute(rec):
    """Recompute `totals`, `complete` and `gap_zones` from `zones[]`. The ONLY place that policy lives."""
    by_status = dict((s, 0) for s in STATUSES)
    planned = charged = candidates = failed_cells = 0
    gaps = []
    for z in rec["zones"]:
        st = z.get("status", "not_reached")
        by_status[st] = by_status.get(st, 0) + 1
        if isinstance(z.get("cells_planned"), int):
            planned += z["cells_planned"]
        if isinstance(z.get("cells_charged"), int):
            charged += z["cells_charged"]
        candidates += int(z.get("candidates") or 0)
        failed_cells += int(z.get("failed_cells") or 0)
        if st not in COVERED_STATUSES or z.get("budget_truncated"):
            gaps.append(z.get("id", ""))
    rec["totals"] = {
        "zones": len(rec["zones"]),
        "cells_planned": planned,
        "cells_charged": charged,
        "candidates": candidates,
        "failed_cells": failed_cells,
        "by_status": by_status,
    }
    rec["complete"] = not gaps
    rec["gap_zones"] = gaps
    rec["updated_at"] = now_iso()
    return rec


def write_record(path, rec):
    """Atomic write — a killed run must never find a half-written record."""
    d = os.path.dirname(os.path.abspath(path))
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = os.path.abspath(path) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, os.path.abspath(path))


def find_zone(rec, zid):
    for z in rec["zones"]:
        if z.get("id") == zid:
            return z
    die(2, "zone not in the coverage record: " + zid)


# ----------------------------------------------------------------------------------------------------------
# init — the record is written BEFORE any zone runs, so absence is not representable.
# ----------------------------------------------------------------------------------------------------------
def cmd_init(argv):
    f = parse_flags(
        argv,
        ("--zones", "--out", "--zone-list", "--repo", "--commit", "--zone-cell-budget", "--run-cell-budget"),
        (),
    )
    for req in ("--zones", "--out", "--zone-list"):
        if req not in f:
            die(2, "init requires " + req)
    zones = read_json(f["--zones"], "zones.json")
    if not isinstance(zones, list):
        zones = []
    # #1826 PRIORITY ORDER (moved here VERBATIM from run-zone-hunt.sh's inline heredoc): value-custody zones
    # first, tie-broken by id, so a truncated run only ever drops the lowest-priority (non-custody) zones.
    # The record's order and the hunt order are now the same list by construction.
    zones = sorted(zones, key=lambda z: (not z.get("value_custody", False), z.get("id", "")))
    # Carry the retry HISTORY across a full re-sweep into an existing --out (see the header): everything else
    # is per-run state and is deliberately reset to `not_reached`.
    prior_attempts = {}
    if os.path.isfile(f["--out"]):
        try:
            with open(f["--out"], encoding="utf-8") as fh:
                old = json.load(fh)
            for z in old.get("zones", []) if isinstance(old, dict) else []:
                if isinstance(z, dict) and z.get("id") and isinstance(z.get("attempts"), list):
                    prior_attempts[z["id"]] = z["attempts"]
        except (OSError, ValueError):
            prior_attempts = {}
    entries = []
    lines = []
    for z in zones:
        zid = z.get("id", "")
        name = z.get("name", zid)
        if not zid:
            continue
        zid = zid.replace("\t", " ")
        name = name.replace("\t", " ")
        lines.append("%s\t%s" % (zid, name))
        entries.append({
            "id": zid,
            "name": name,
            "value_custody": bool(z.get("value_custody", False)),
            "order": len(entries) + 1,
            "status": "not_reached",
            "cells_planned": None,
            "cells_charged": 0,
            "classes_hunted": [],
            "budget_truncated": False,
            "cells": 0,
            "candidates": 0,
            "failed_cells": 0,
            "exit_code": None,
            "started_at": "",
            "ended_at": "",
            "results": "",
            "detail": "",
            "attempts": prior_attempts.get(zid, []),
        })
    started = now_iso()
    rec = {
        "schema": SCHEMA,
        "repo": f.get("--repo", ""),
        "commit": f.get("--commit", ""),
        "started_at": started,
        "updated_at": started,
        "budget": {
            "unit": "cells",
            "per_zone": int(f.get("--zone-cell-budget", 0) or 0),
            "run": int(f.get("--run-cell-budget", 0) or 0),
        },
        "zones": entries,
    }
    recompute(rec)
    rec["started_at"] = started
    write_record(f["--out"], rec)
    with open(f["--zone-list"], "w", encoding="utf-8") as fh:
        for line in lines:
            fh.write(line + "\n")
    return 0


# ----------------------------------------------------------------------------------------------------------
# set — the ONLY writer of a zone's outcome. With --results it DERIVES the terminal status.
# ----------------------------------------------------------------------------------------------------------
def cmd_set(argv):
    f = parse_flags(
        argv,
        ("--file", "--zone", "--status", "--exit-code", "--cells-planned", "--cells-charged",
         "--classes", "--results", "--detail"),
        ("--budget-truncated",),
    )
    for req in ("--file", "--zone"):
        if req not in f:
            die(2, "set requires " + req)
    rec = load_record(f["--file"])
    z = find_zone(rec, f["--zone"])

    if "--cells-planned" in f:
        v = f["--cells-planned"]
        z["cells_planned"] = None if v in ("", "null") else int(v)
    if "--cells-charged" in f:
        z["cells_charged"] = int(f["--cells-charged"])
    if "--classes" in f:
        z["classes_hunted"] = [c for c in f["--classes"].split(",") if c]
    if f.get("--budget-truncated"):
        z["budget_truncated"] = True
    if "--exit-code" in f:
        z["exit_code"] = int(f["--exit-code"])
    if "--detail" in f:
        z["detail"] = f["--detail"]

    status = f.get("--status")
    if "--results" in f and f["--results"]:
        # DERIVE the terminal status from what the zone's own run-discovery.sh emitted — one place, one rule.
        # A missing/unreadable results file after a zero exit is a `failed` zone, not a silent success.
        path = f["--results"]
        data = None
        if os.path.isfile(path):
            try:
                with open(path, encoding="utf-8") as fh:
                    data = json.load(fh)
            except (OSError, ValueError):
                data = None
        if not isinstance(data, dict):
            status = "failed"
            if not z.get("detail"):
                z["detail"] = "run-discovery.sh exited 0 but emitted no readable discovery-results.json"
        else:
            t = data.get("totals", {}) if isinstance(data.get("totals"), dict) else {}
            z["cells"] = int(t.get("cells", 0) or 0)
            z["candidates"] = int(t.get("candidates", 0) or 0)
            z["failed_cells"] = int(t.get("failed", 0) or 0)
            z["results"] = relative_to_out(f["--file"], path)
            if z["cells"] == 0:
                # ZERO cells ran. run-discovery.sh exits 0 with `totals:{cells:0,...}` whenever --only matched
                # no manifest line, so `failed == 0 and candidates == 0` is NOT evidence of cleanliness here —
                # deriving `hunted_empty` would re-create, inside the record, the exact silent-absence defect
                # this record exists to remove. The guard is on the OUTCOME (zero cells ran), not on any one
                # cause, so an unclassified zone, a `classification_failed` zone and a name that map-zones.sh's
                # clean() rewrote before it reached scope.tsv all land here.
                status = "unscoped"
                if not z.get("detail"):
                    z["detail"] = "zero cells ran: the zone has no matching line in scope.tsv"
            elif z["failed_cells"] > 0:
                status = "hunted_degraded"
            elif z["candidates"] > 0:
                status = "hunted"
            else:
                status = "hunted_empty"

    if status is not None:
        if status not in STATUSES:
            die(2, "unknown status: " + status)
        z["status"] = status
        if status == "in_flight":
            z["started_at"] = now_iso()
            z["ended_at"] = ""
        elif status != "not_reached":
            z["ended_at"] = now_iso()

    recompute(rec)
    write_record(f["--file"], rec)
    return 0


# ----------------------------------------------------------------------------------------------------------
# budget — #1880: record the sweep-level depth ceiling in force. Additive, and only ever called when it is on.
# ----------------------------------------------------------------------------------------------------------
def cmd_budget(argv):
    f = parse_flags(argv, ("--file", "--depth-total", "--depth-per-zone"), ())
    for req in ("--file", "--depth-total", "--depth-per-zone"):
        if req not in f:
            die(2, "budget requires " + req)
    rec = load_record(f["--file"])
    budget = rec.get("budget")
    if not isinstance(budget, dict):
        budget = {}
        rec["budget"] = budget
    budget["depth_total"] = int(f["--depth-total"])
    budget["depth_per_zone"] = int(f["--depth-per-zone"])
    recompute(rec)
    write_record(f["--file"], rec)
    return 0


# ----------------------------------------------------------------------------------------------------------
# gaps — the re-hunt work list. `no_brief` is NEVER selected; `failed`/`in_flight` are NEVER collapsed into
# `not_reached` (their remedy differs and their artifacts must be preserved first).
# ----------------------------------------------------------------------------------------------------------
def cmd_gaps(argv):
    f = parse_flags(argv, ("--file", "--max-attempts"), ("--include-partial",))
    if "--file" not in f:
        die(2, "gaps requires --file")
    rec = load_record(f["--file"])
    max_attempts = int(f.get("--max-attempts", 0) or 0)
    include_partial = bool(f.get("--include-partial"))
    for z in rec["zones"]:
        st = z.get("status", "not_reached")
        attempts = z.get("attempts", []) or []
        partial = st == "hunted_degraded" or (st in COVERED_STATUSES and z.get("budget_truncated"))
        if st == "no_brief":
            action = "no-brief"
        elif st == "unscoped":
            action = "unscoped"
        elif st in RETRYABLE_STATUSES:
            action = "retry" if st in HAS_ARTIFACTS else "hunt"
        elif partial and include_partial:
            action = "retry"
        else:
            continue
        if action in ("hunt", "retry") and max_attempts > 0 and len(attempts) >= max_attempts:
            action = "capped"
        sys.stdout.write("%s\t%s\t%s\n" % (z.get("id", ""), z.get("name", ""), action))
    return 0


# ----------------------------------------------------------------------------------------------------------
# retry — preserve the prior terminal state as evidence, then reset for a fresh attempt.
# ----------------------------------------------------------------------------------------------------------
def cmd_retry(argv):
    f = parse_flags(argv, ("--file", "--zone", "--artifacts"), ())
    for req in ("--file", "--zone"):
        if req not in f:
            die(2, "retry requires " + req)
    rec = load_record(f["--file"])
    z = find_zone(rec, f["--zone"])
    z.setdefault("attempts", []).append({
        "n": len(z.get("attempts", [])) + 1,
        "status": z.get("status", "not_reached"),
        "exit_code": z.get("exit_code"),
        "ended_at": z.get("ended_at", ""),
        "artifacts": f.get("--artifacts", ""),
    })
    # A fresh attempt starts from ZERO evidence — the prior outcome now lives in attempts[], not in the
    # live fields, so the next `set` cannot blend two attempts into one ambiguous entry.
    z["status"] = "not_reached"
    z["cells"] = 0
    z["candidates"] = 0
    z["failed_cells"] = 0
    z["exit_code"] = None
    z["budget_truncated"] = False
    z["cells_charged"] = 0
    z["classes_hunted"] = []
    z["results"] = ""
    z["detail"] = ""
    z["started_at"] = ""
    z["ended_at"] = ""
    recompute(rec)
    write_record(f["--file"], rec)
    return 0


# ----------------------------------------------------------------------------------------------------------
# summary — the fail-loud banner, the covered/total counts, and the merged-file `coverage` fragment.
# ----------------------------------------------------------------------------------------------------------
def cmd_summary(argv):
    f = parse_flags(argv, ("--file",), ("--counts", "--json"))
    if "--file" not in f:
        die(2, "summary requires --file")
    rec = load_record(f["--file"])
    total = len(rec["zones"])
    gaps = rec.get("gap_zones", []) or []
    covered = total - len(gaps)
    if f.get("--counts"):
        sys.stdout.write("%d %d\n" % (covered, total))
        return 0
    if f.get("--json"):
        sys.stdout.write(json.dumps({
            "complete": bool(rec.get("complete")),
            "gap_zones": gaps,
            "by_status": rec.get("totals", {}).get("by_status", {}),
        }) + "\n")
        return 0
    if rec.get("complete"):
        return 0
    status_of = dict((z.get("id", ""), z.get("status", "")) for z in rec["zones"])
    detail = ", ".join("%s=%s" % (g, status_of.get(g, "")) for g in gaps)
    sys.stdout.write(
        "run-zone-hunt.sh: [M3] COVERAGE GAP: %d of %d zone(s) not fully hunted (%s) "
        "— this run is NOT a clean sweep\n" % (len(gaps), total, detail))
    by_status = rec.get("totals", {}).get("by_status", {})
    breakdown = " ".join("%s=%d" % (s, by_status.get(s, 0)) for s in STATUSES if by_status.get(s, 0))
    sys.stdout.write("run-zone-hunt.sh: [M3] coverage by status: %s\n" % breakdown)
    return 0


COMMANDS = {
    "init": cmd_init,
    "set": cmd_set,
    "budget": cmd_budget,
    "gaps": cmd_gaps,
    "retry": cmd_retry,
    "summary": cmd_summary,
}


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stdout.write("usage: zone-coverage.py <init|set|budget|gaps|retry|summary> [flags]\n")
        return 0 if len(argv) >= 2 else 2
    cmd = COMMANDS.get(argv[1])
    if cmd is None:
        die(2, "unknown subcommand: " + argv[1])
    return cmd(argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
