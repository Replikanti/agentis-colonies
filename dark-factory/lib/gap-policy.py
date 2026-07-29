#!/usr/bin/env python3
# gap-policy.py — #1828 (M1/M2 of the self-tuning-breadth issue). THE GAP-REMEDIATION DECISION LAYER: given a
# #1830 coverage record (and the history of what has already been tried), it answers ONE question — "what
# should be done about the gaps this run left?" — with one of exactly four verbs.
#
# WHY IT IS A SEPARATE LAYER. #1830 shipped the RECORD (`lib/zone-coverage.py`, `<out>/coverage/zone-coverage.json`)
# and the MECHANICS (`run-zone-hunt.sh --rehunt-gaps`), and deliberately decides nothing: `zone-coverage.py gaps`
# emits a work list, `run-zone-hunt.sh` executes exactly one pass over it. The missing piece was the POLICY, and
# it does not belong inside `run-zone-hunt.sh` — that capstone is TACTICAL (execute M1..M5 and report what
# happened); folding "how much may I spend, and should I try again" into the loop that spends it would make a
# 1000-line capstone self-recursive. So the policy lives HERE and the driver (`run-zone-sweep.sh`) sits one
# layer ABOVE the capstone. `run-zone-hunt.sh` is not modified by this issue at all.
#
# IT NEVER RE-DERIVES CLASSIFICATION. Which statuses are retryable is #1830's contract and lives in exactly one
# place (`zone-coverage.py`'s RETRYABLE_STATUSES / cmd_gaps). This file SHELLS OUT to the sibling helper
# (`gaps`, `summary --json`) rather than re-implementing the rule, so the two can never drift.
#
# TWO PROPERTIES OF THE INPUT THE RULE IS BUILT AROUND (both verified against the shipped helper, both pinned
# by demo-gap-policy.sh):
#
#   1. `--max-attempts` BOUNDS ONLY THE ARTIFACT-BEARING STATUSES. `attempts[]` is appended only by
#      `zone-coverage.py retry`, which `run-zone-hunt.sh` calls only on the `retry` action — i.e. only for
#      statuses that left artifacts behind (`failed`, `in_flight`, an included partial). A zone DENIED ON
#      ADMISSION is recorded `budget_exhausted` with NO attempt entry, so `gaps --max-attempts N` keeps
#      emitting `hunt` for it forever and it never becomes `capped`. THE LOOP BOUND THEREFORE CANNOT COME FROM
#      THE RECORD ALONE: any autonomous loop over the gap set must carry its own pass ceiling, plus a
#      no-progress rule for the case where a pass legitimately runs and closes nothing.
#   2. `summary --json`.`gap_zones` IS A SUPERSET OF THE `gaps` TSV. Partial zones (`hunted_degraded`, or
#      covered-but-`budget_truncated`) are gaps, but they are emitted by `gaps` only under `--include-partial`.
#      Actionability is therefore read from the TSV ONLY; `gap_zones` is used for reporting, never for
#      deciding. A policy that acted on `gap_zones` would try to re-hunt something it was not asked to.
#
# THE VERBS (closed set; policy LEARNING over them is #1828 M4 and is explicitly out of scope here — the rule
# below is deterministic and has no state beyond the record and the ledger):
#   rehunt_now              actionable gaps exist and a plain re-hunt can close them.
#   raise_budget_and_rehunt the gaps are budget denials and an operator-authorized ceiling has headroom. The
#                           raise goes STRAIGHT to the ceiling, so at most one raise per sweep is possible.
#   remap_target            the only gaps left are UPSTREAM defects (`unscoped` / `no_brief`). This is a
#                           REPORTED decision, never an action: a re-map invalidates the briefs and the record
#                           the policy is reasoning over, so the driver never re-runs STAGE 1/2 by itself.
#   give_up                 nothing further is worth trying; `reason=` names which bound stopped it.
#
# Subcommands:
#   decide --coverage <zone-coverage.json> [--ledger <gap-remediation.json>] [--max-passes N] [--max-attempts N]
#          [--include-partial] [--run-cell-budget N] [--budget-ceiling N] [--zone-coverage <helper>] [--json]
#       Prints one line `DECISION|<verb>|<k=v;...>|<rationale>` (or the same as JSON). Exit 0 always — a
#       decision is never an error; a broken input is (exit 3).
#   ledger init --file <gap-remediation.json> [--coverage <f>]
#   ledger append --file <f> --decision <verb> [--run-cell-budget N] [--zone-cell-budget N]
#                 [--gaps-before CSV] [--gaps-after CSV] [--exit-code N] [--detail TEXT]
#   ledger finish --file <f> --terminal-reason <r> [--coverage <f>]
#       Maintains `schema: gap-remediation/v1` with `passes[]` and the derived `closed[]` / `remaining[]` /
#       `terminal_reason`. Atomic tmp + os.replace write (the same idiom as zone-coverage.py) so a sweep that
#       dies mid-loop never leaves a half-written ledger.
#   report --coverage <f> --ledger <f> [--zone-coverage <helper>] [--max-attempts N]
#       The honest end-of-sweep report (markdown to stdout): per closed gap the pass that closed it, per
#       remaining gap its status and the reason a re-hunt cannot close it.
#
# Exit: 0 ok ; 2 usage ; 3 unreadable/malformed input or a failing sibling helper call.
import sys
import os
import json
import datetime
import subprocess

SCHEMA = "gap-remediation/v1"
VERBS = ("rehunt_now", "raise_budget_and_rehunt", "remap_target", "give_up")
# The pass entry the driver writes for the FIRST (breadth) pass. It is not a re-hunt, so it does not count
# against --max-passes; keeping it in `passes[]` is what makes the ledger a complete account of the sweep.
INITIAL = "initial"

# Actions `zone-coverage.py gaps` can emit, grouped by what the policy may do with them.
ACTIONABLE_ACTIONS = ("hunt", "retry")
DEFECT_ACTIONS = ("no-brief", "unscoped")
# Statuses whose remedy is MORE BUDGET rather than another attempt at the same budget.
BUDGET_STATUSES = ("budget_exhausted", "budget_unenforceable")


def die(rc, msg):
    sys.stderr.write("gap-policy.py: " + msg + "\n")
    sys.exit(rc)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_flags(argv, valued, boolean):
    """Manual flag walk (the repo's helper idiom — no argparse). Unknown flags and missing values are usage
    errors, never silent."""
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


def write_json(path, obj):
    """Atomic write — a sweep killed mid-loop must never find a half-written ledger."""
    d = os.path.dirname(os.path.abspath(path))
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = os.path.abspath(path) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, os.path.abspath(path))


def non_negative(f, flag, default):
    v = f.get(flag, default)
    try:
        n = int(v)
    except (TypeError, ValueError):
        die(2, flag + " must be a non-negative integer (got '" + str(v) + "')")
    if n < 0:
        die(2, flag + " must be a non-negative integer (got '" + str(v) + "')")
    return n


def helper_path(f):
    """The sibling zone-coverage.py — the SOLE owner of the classification rule this file must not restate."""
    p = f.get("--zone-coverage") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "zone-coverage.py")
    if not os.path.isfile(p):
        die(3, "required helper not found: " + p)
    return p


def run_helper(helper, args):
    try:
        proc = subprocess.run([sys.executable, helper] + args, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True)
    except OSError as e:
        die(3, "cannot run " + helper + ": " + str(e))
    if proc.returncode != 0:
        die(3, "zone-coverage.py " + " ".join(args) + " failed (exit %d): %s"
            % (proc.returncode, proc.stderr.strip()))
    return proc.stdout


def gaps_tsv(helper, coverage, max_attempts, include_partial):
    """The work list, verbatim from the helper: [(zid, name, action), ...] in the record's priority order."""
    args = ["gaps", "--file", coverage]
    if max_attempts > 0:
        args += ["--max-attempts", str(max_attempts)]
    if include_partial:
        args.append("--include-partial")
    rows = []
    for line in run_helper(helper, args).splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        while len(parts) < 3:
            parts.append("")
        rows.append((parts[0], parts[1], parts[2]))
    return rows


def summary_json(helper, coverage):
    out = run_helper(helper, ["summary", "--file", coverage, "--json"])
    try:
        return json.loads(out)
    except ValueError as e:
        die(3, "zone-coverage.py summary --json emitted no JSON: " + str(e))


def csv(ids):
    return ",".join(ids)


def split_csv(s):
    return [x for x in (s or "").split(",") if x]


# ----------------------------------------------------------------------------------------------------------
# decide — the rule. Evaluation order is fixed and exhaustive; every path names a reason.
# ----------------------------------------------------------------------------------------------------------
def cmd_decide(argv):
    f = parse_flags(
        argv,
        ("--coverage", "--ledger", "--max-passes", "--max-attempts", "--run-cell-budget", "--budget-ceiling",
         "--zone-coverage"),
        ("--include-partial", "--json"),
    )
    if "--coverage" not in f:
        die(2, "decide requires --coverage")
    coverage = f["--coverage"]
    if not os.path.isfile(coverage):
        die(3, "coverage record not found: " + coverage)
    helper = helper_path(f)
    max_passes = non_negative(f, "--max-passes", 2)
    max_attempts = non_negative(f, "--max-attempts", 2)
    ceiling = non_negative(f, "--budget-ceiling", 0)
    include_partial = bool(f.get("--include-partial"))

    rec = read_json(coverage, "the coverage record")
    summary = summary_json(helper, coverage)
    rows = gaps_tsv(helper, coverage, max_attempts, include_partial)
    status_of = dict((z.get("id", ""), z.get("status", "")) for z in rec.get("zones", []) or [])

    actionable = [(zid, act) for zid, _n, act in rows if act in ACTIONABLE_ACTIONS]
    capped = [zid for zid, _n, act in rows if act == "capped"]
    defect = [zid for zid, _n, act in rows if act in DEFECT_ACTIONS]
    # A gap that is neither actionable, nor capped, nor an upstream defect can only be a PARTIAL the caller
    # did not ask for — see property 2 in the header. Naming it explicitly is what stops the driver from
    # silently reporting "nothing actionable" when one flag would have made it actionable.
    partial_only = bool(summary.get("gap_zones")) and not rows

    ledger = None
    if f.get("--ledger") and os.path.isfile(f["--ledger"]):
        ledger = read_json(f["--ledger"], "the remediation ledger")
    passes = (ledger or {}).get("passes", []) or []
    rehunt_passes = [p for p in passes if p.get("decision") != INITIAL]
    passes_done = len(rehunt_passes)
    last = passes[-1] if passes else None

    # The budget the NEXT pass would run under: the flag wins, else the highest budget any pass has already
    # run under (the record's `budget.run` is written by `init` and is NOT rewritten by a --rehunt-gaps pass,
    # so a raise would otherwise be invisible to the next decision and could repeat).
    record_budget = int(((rec.get("budget") or {}).get("run")) or 0)
    ledger_budget = max([int(p.get("run_cell_budget") or 0) for p in passes] or [0])
    run_budget = non_negative(f, "--run-cell-budget", max(record_budget, ledger_budget))

    def emit(verb, args, rationale):
        if f.get("--json"):
            payload = {
                "verb": verb,
                "args": dict(args),
                "rationale": rationale,
                "actionable": [z for z, _a in actionable],
                "capped": capped,
                "defect": defect,
                "partial_only": partial_only,
                "passes_done": passes_done,
                "run_cell_budget": run_budget,
                "budget_ceiling": ceiling,
                "complete": bool(summary.get("complete")),
            }
            sys.stdout.write(json.dumps(payload) + "\n")
        else:
            kv = ";".join("%s=%s" % (k, v) for k, v in args)
            sys.stdout.write("DECISION|%s|%s|%s\n" % (verb, kv, rationale))
        return 0

    def budget_branch(why, deny_reason, because):
        """4c — the ONLY path that may raise a budget. The raise goes straight to the authorized ceiling, so a
        sweep can raise AT MOST ONCE: the next decision sees run_budget == ceiling and falls through here.
        `why` labels the RAISE (what escalated here); `deny_reason` labels the give_up (which bound stopped
        it) — they differ, because "the gaps are budget denials" and "no raise is authorized" are two facts."""
        zones_arg = csv([z for z, _a in actionable])
        if ceiling > run_budget:
            args = [("reason", why), ("run_cell_budget", str(ceiling))]
            # `--zone-cell-budget 0` is emitted ONLY for a `budget_unenforceable` zone: the PER-ZONE cap is
            # precisely what could not be expressed for it (run-zone-hunt.sh's --classes probe), so dropping
            # that cap is the remedy. The RUN budget stays the hard bound either way.
            if any(status_of.get(z) == "budget_unenforceable" for z, _a in actionable):
                args.append(("zone_cell_budget", "0"))
            args.append(("zones", zones_arg))
            return emit("raise_budget_and_rehunt", args,
                        "%s; raising the run cell budget from %d to the authorized ceiling %d and re-hunting "
                        "%s" % (because, run_budget, ceiling, zones_arg))
        return emit("give_up", [("reason", deny_reason), ("zones", zones_arg)],
                    "%s, and no raise is authorized (run cell budget %d, --budget-ceiling %d): stopping — "
                    "repeating the same pass at the same budget cannot close %s"
                    % (because, run_budget, ceiling, zones_arg))

    # 1. Nothing to decide — the driver short-circuits before asking, but the rule is total on its own.
    if summary.get("complete"):
        return emit("give_up", [("reason", "nothing_actionable")],
                    "the coverage record is complete: every zone was hunted and nothing is truncated")

    # 2. The pass ceiling. This bound does NOT read the record (see property 1 in the header) — it is the
    #    driver's own, and it is the one that makes a `budget_exhausted` zone terminate at all.
    if passes_done >= max_passes:
        return emit("give_up", [("reason", "pass_ceiling"), ("passes_done", str(passes_done))],
                    "%d re-hunt pass(es) already ran and --max-rehunt-passes is %d: stopping and reporting "
                    "the remaining gaps rather than looping" % (passes_done, max_passes))

    # 3. No actionable row: name WHICH kind of dead end this is — the remedies are different.
    if not actionable:
        if capped:
            return emit("give_up", [("reason", "attempt_ceiling"), ("zones", csv(capped))],
                        "every remaining gap has reached the per-zone attempt ceiling (%d attempt(s)): a "
                        "further re-hunt would only repeat an attempt that already failed" % max_attempts)
        if defect:
            return emit("remap_target", [("reason", "upstream_defect"), ("zones", csv(defect))],
                        "the remaining gaps are upstream mapping/brief defects (%s) — a re-hunt against the "
                        "same map cannot fix them; re-map the target and run a full pass" % csv(defect))
        if partial_only:
            return emit("give_up", [("reason", "partial_only"), ("zones", csv(summary.get("gap_zones") or []))],
                        "the remaining gaps are PARTIAL hunts (degraded or budget-truncated), which are not "
                        "in the default work list: re-run with --rehunt-include-partial to act on them")
        return emit("give_up", [("reason", "nothing_actionable")],
                    "the record reports gaps but the work list is empty — nothing a re-hunt can act on")

    # 4. There is work. Decide whether repeating it can plausibly help.
    #    a. NO-PROGRESS GUARD. The previous pass was a plain re-hunt and closed nothing, so the identical
    #       action provably repeats. This is the second independent bound (property 1): a `budget_exhausted`
    #       zone never gains an `attempts[]` entry, so the record's own ceiling would never stop this.
    if last is not None and last.get("decision") == "rehunt_now" and not (last.get("closed") or []):
        return budget_branch("no_progress", "no_progress", "the previous re-hunt pass closed no gap at all")
    #    b. Every actionable gap is a budget denial — another attempt at the SAME budget is the same denial.
    if all(status_of.get(z) in BUDGET_STATUSES for z, _a in actionable):
        return budget_branch("budget_denied", "budget_ceiling", "every actionable gap is a budget denial")
    #    d. A plain re-hunt.
    return emit("rehunt_now", [("reason", "actionable_gaps"), ("zones", csv([z for z, _a in actionable]))],
                "%d zone(s) are actionable at the current budget (%s): re-hunting them"
                % (len(actionable), csv([z for z, _a in actionable])))


# ----------------------------------------------------------------------------------------------------------
# ledger — the durable account of the sweep. Written after EVERY pass so a killed sweep is still readable.
# ----------------------------------------------------------------------------------------------------------
def load_ledger(path):
    led = read_json(path, "the remediation ledger")
    if not isinstance(led, dict) or not isinstance(led.get("passes"), list):
        die(3, "malformed remediation ledger: " + path)
    return led


def recompute_ledger(led):
    closed, seen = [], set()
    for p in led["passes"]:
        for z in p.get("closed", []) or []:
            if z not in seen:
                seen.add(z)
                closed.append(z)
    led["closed"] = closed
    led["remaining"] = list(led["passes"][-1].get("gaps_after", []) or []) if led["passes"] else []
    led["passes_done"] = len([p for p in led["passes"] if p.get("decision") != INITIAL])
    led["updated_at"] = now_iso()
    return led


def cmd_ledger(argv):
    if not argv:
        die(2, "ledger requires init|append|finish")
    sub, rest = argv[0], argv[1:]
    if sub == "init":
        f = parse_flags(rest, ("--file", "--coverage", "--repo", "--commit"), ())
        if "--file" not in f:
            die(2, "ledger init requires --file")
        started = now_iso()
        write_json(f["--file"], {
            "schema": SCHEMA,
            "repo": f.get("--repo", ""),
            "commit": f.get("--commit", ""),
            "coverage": os.path.basename(f.get("--coverage", "zone-coverage.json")),
            "started_at": started,
            "updated_at": started,
            "passes": [],
            "closed": [],
            "remaining": [],
            "passes_done": 0,
            "terminal_reason": "",
        })
        return 0
    if sub == "append":
        f = parse_flags(
            rest,
            ("--file", "--decision", "--run-cell-budget", "--zone-cell-budget", "--gaps-before", "--gaps-after",
             "--exit-code", "--detail"),
            (),
        )
        for req in ("--file", "--decision"):
            if req not in f:
                die(2, "ledger append requires " + req)
        if f["--decision"] not in VERBS and f["--decision"] != INITIAL:
            die(2, "unknown decision: " + f["--decision"])
        led = load_ledger(f["--file"])
        before = split_csv(f.get("--gaps-before"))
        after = split_csv(f.get("--gaps-after"))
        after_set = set(after)
        led["passes"].append({
            "n": len(led["passes"]) + 1,
            "decision": f["--decision"],
            "run_cell_budget": int(f.get("--run-cell-budget", 0) or 0),
            "zone_cell_budget": int(f.get("--zone-cell-budget", 0) or 0),
            "exit_code": int(f["--exit-code"]) if "--exit-code" in f else None,
            "gaps_before": before,
            "gaps_after": after,
            # A gap is CLOSED by this pass when it left the gap set. Derived here, never asserted by the
            # caller, so the no-progress guard cannot be fed an optimistic claim.
            "closed": [z for z in before if z not in after_set],
            "detail": f.get("--detail", ""),
            "ended_at": now_iso(),
        })
        recompute_ledger(led)
        write_json(f["--file"], led)
        return 0
    if sub == "finish":
        f = parse_flags(rest, ("--file", "--terminal-reason", "--coverage"), ())
        for req in ("--file", "--terminal-reason"):
            if req not in f:
                die(2, "ledger finish requires " + req)
        led = load_ledger(f["--file"])
        led["terminal_reason"] = f["--terminal-reason"]
        if "--coverage" in f and os.path.isfile(f["--coverage"]):
            rec = read_json(f["--coverage"], "the coverage record")
            led["complete"] = bool(rec.get("complete"))
            led["remaining"] = list(rec.get("gap_zones", []) or [])
        recompute_ledger(led)
        led["terminal_reason"] = f["--terminal-reason"]
        write_json(f["--file"], led)
        return 0
    die(2, "unknown ledger subcommand: " + sub)


# ----------------------------------------------------------------------------------------------------------
# report — the honest end-of-sweep markdown. Never claims more than the record says.
# ----------------------------------------------------------------------------------------------------------
WHY_NOT_CLOSED = {
    "no-brief": "STAGE 2 emitted no brief — an upstream defect; a re-hunt cannot fix it (re-run the full pass)",
    "unscoped": "no line in map/scope.tsv — an upstream MAPPING defect; re-map the target",
    "capped": "the per-zone attempt ceiling was reached; a further attempt would repeat a failed one",
}
WHY_BY_STATUS = {
    "budget_exhausted": "denied on admission — the run cell budget was spent; raise --budget-ceiling (or "
                        "--run-cell-budget) and re-hunt",
    "budget_unenforceable": "a partial cap cannot be expressed for this zone; give it its full planned budget "
                            "or re-map so its subsystem name is unique",
    "hunted_degraded": "a PARTIAL hunt (a cell produced no verdict) — re-run the sweep with "
                       "--rehunt-include-partial",
    "not_reached": "never attempted at the bound this sweep ran under",
    "in_flight": "the process died mid-zone (external kill / OOM)",
    "failed": "run-discovery.sh exited non-zero",
}


def cmd_report(argv):
    f = parse_flags(argv, ("--coverage", "--ledger", "--zone-coverage", "--max-attempts"), ())
    if "--ledger" not in f:
        die(2, "report requires --ledger")
    led = load_ledger(f["--ledger"])
    max_attempts = non_negative(f, "--max-attempts", 2)
    # --coverage is OPTIONAL on purpose: an aborted sweep (the breadth pass died before STAGE 3 wrote the
    # record) must still get a report saying so. A report is never skipped just because the news is bad.
    if "--coverage" in f and os.path.isfile(f["--coverage"]):
        rec = read_json(f["--coverage"], "the coverage record")
        helper = helper_path(f)
        # --include-partial so the report can EXPLAIN a partial; the DECISION never reads this list.
        actions = dict((zid, act) for zid, _n, act in
                       gaps_tsv(helper, f["--coverage"], max_attempts, True))
    else:
        rec = {"repo": led.get("repo", ""), "commit": "", "zones": [], "gap_zones": [], "complete": False}
        actions = {}
    zones = dict((z.get("id", ""), z) for z in rec.get("zones", []) or [])
    closed_in = {}
    for p in led["passes"]:
        for z in p.get("closed", []) or []:
            closed_in.setdefault(z, p.get("n"))
    remaining = [z for z in (rec.get("gap_zones") or [])]
    rehunts = len([p for p in led["passes"] if p.get("decision") != INITIAL])

    out = []
    out.append("# Gap remediation report (#1828)")
    out.append("")
    out.append("- target: `%s` @ `%s`" % (rec.get("repo", ""), rec.get("commit", "")))
    out.append("- passes: %d (1 breadth + %d re-hunt)" % (len(led["passes"]), rehunts))
    out.append("- coverage: **%s**" % ("complete" if rec.get("complete") else "INCOMPLETE"))
    out.append("- terminal reason: `%s`" % (led.get("terminal_reason") or "unset"))
    out.append("- gaps closed: %d / gaps remaining: %d" % (len(led.get("closed", [])), len(remaining)))
    if not zones:
        out.append("")
        out.append("> **No coverage record was written** — the breadth pass aborted before STAGE 3 could write "
                   "`coverage/zone-coverage.json`. Nothing below is a statement about coverage.")
    out.append("")
    out.append("## Passes")
    out.append("")
    out.append("| # | decision | run cell budget | gaps before | gaps after | closed |")
    out.append("|---|---|---|---|---|---|")
    for p in led["passes"]:
        out.append("| %s | `%s` | %s | %d | %d | %s |" % (
            p.get("n"), p.get("decision"), p.get("run_cell_budget") or "-",
            len(p.get("gaps_before") or []), len(p.get("gaps_after") or []),
            csv(p.get("closed") or []) or "-"))
    out.append("")
    out.append("## Closed gaps (%d)" % len(led.get("closed", [])))
    out.append("")
    if led.get("closed"):
        out.append("| zone | status now | closed in pass |")
        out.append("|---|---|---|")
        for z in led["closed"]:
            out.append("| `%s` | `%s` | %s |" % (z, zones.get(z, {}).get("status", "?"), closed_in.get(z, "?")))
    else:
        out.append("_None._")
    out.append("")
    out.append("## Remaining gaps (%d)" % len(remaining))
    out.append("")
    if remaining:
        out.append("| zone | status | why it is still a gap |")
        out.append("|---|---|---|")
        for z in remaining:
            st = zones.get(z, {}).get("status", "?")
            act = actions.get(z, "")
            why = WHY_NOT_CLOSED.get(act) or WHY_BY_STATUS.get(st)
            if why is None:
                why = ("a partial hunt (budget_truncated): the class list was shortened, so its result is not "
                       "a rigorous negative" if zones.get(z, {}).get("budget_truncated")
                       else "still a gap after the sweep exhausted its options")
            out.append("| `%s` | `%s` | %s |" % (z, st, why))
    else:
        out.append("_None — the sweep closed every gap._")
    out.append("")
    sys.stdout.write("\n".join(out) + "\n")
    return 0


COMMANDS = {
    "decide": cmd_decide,
    "ledger": cmd_ledger,
    "report": cmd_report,
}


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stdout.write("usage: gap-policy.py <decide|ledger|report> [flags]\n")
        return 0 if len(argv) >= 2 else 2
    cmd = COMMANDS.get(argv[1])
    if cmd is None:
        die(2, "unknown subcommand: " + argv[1])
    return cmd(argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
