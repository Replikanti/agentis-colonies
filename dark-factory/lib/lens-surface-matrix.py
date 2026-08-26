#!/usr/bin/env python3
# lens-surface-matrix.py — #1914 M3 (epic #1914). THE LENS x SURFACE COVERAGE MATRIX: the one place that owns
# `<out>/coverage/lens-surface-matrix.json`, the per-run machine-readable answer to "for every custody/composition
# surface, what is the DEEPEST lens that actually reached it, and — for the general-solvency lens — what did it
# conclude?".
#
# WHY IT EXISTS. STAGE 4.5's #1780 merge adapter (run-zone-hunt.sh) collapses CLEAN and HARNESS_ERROR into a
# SINGLE no-op branch: only a FINDING verdict is merged into verified_findings.json, so a settlement seam whose
# harness failed to compile/generate (HARNESS_ERROR — un-probed) is INDISTINGUISHABLE from a seam the lens ran
# clean over (CLEAN — a real negative). A run then looks like it covered every custody surface when a general
# lens may never have executed on some of them. This record makes the distinction durable and per-surface.
#
# THE CONTRACT. The record is written UNCONDITIONALLY and PESSIMISTICALLY: `init` writes one entry per surface
# BEFORE the deep-hunt loop runs a single lens, and each entry is rewritten in place — MONOTONICALLY, deepest
# lens wins — as a lens reaches the surface. ABSENCE IS THEREFORE NOT REPRESENTABLE: a surface can never be
# silently missing, only visibly at its seed floor, and an externally-imposed kill still leaves a truthful record.
#
# THE LENS-DEPTH VOCABULARY (closed; consumers branch on `lens_depth`, deepest first):
#   general-solvency  the class-agnostic SYS-solvency lens (#1914 M1) RAN on the surface. THE ONLY depth that
#                     carries a `verdict` — and the whole reason this record exists:
#                       FINDING        the fuzzer reproduced a shrunk exploit sequence. A real positive.
#                       CLEAN          the lens ran to completion and the invariant held. A rigorous NEGATIVE.
#                       HARNESS_ERROR  the harness failed to compile/generate — the seam stayed UN-PROBED. A
#                                      GAP, NOT a clean negative. It MUST read distinct from CLEAN: the #1780
#                                      adapter merges neither, so without this record the two are lost together.
#                       TRANSIENT_ERROR (#2033) the forge run was STARVED/killed/timed out under concurrent batch
#                                      load AFTER the gate's retries — the harness is VALID and the seam is
#                                      RE-RUNNABLE. Recorded in its OWN by_verdict bucket, distinct from a
#                                      permanent HARNESS_ERROR; NOT enrolled in the permanent
#                                      `harness_error_surfaces` GAP list (a transient is re-hunted, not un-probed).
#   narrow-per-class  the surface only ever saw a per-class lens (C6/C2/C16/...), never the general lens. The
#                     custody seam was probed for a SPECIFIC bug class, not for system solvency. NOT a verdict.
#   discovery-only    the surface was seen at STAGE 3 breadth but NO deep lens reached it (single-.sol zone,
#                     unresolvable seam, or the cap left it no headroom). Breadth-only evidence. NOT a verdict.
#   not_reached       written by `init` before the loop; never updated. ZERO EVIDENCE — not a negative.
#                     run-zone-hunt.sh seeds AFTER STAGE 3 breadth (`--seed-state discovery-only`), so in that
#                     wiring the floor is `discovery-only`; `not_reached` is the module's absolute default for a
#                     caller that seeds before breadth, and the deepest-lens precedence rank below it.
#
# The DEPTH PRECEDENCE is total (general-solvency > narrow-per-class > discovery-only > not_reached): `set` NEVER
# downgrades a surface, so the per-class rows and the general-solvency row of one zone can arrive in any order and
# the record always ends at the deepest lens that reached the surface.
#
# Subcommands:
#   init --zones <zones.json> --out <matrix.json> [--seed-state <lens-depth>] [--repo <name>] [--commit <sha>]
#        The SURFACE SET is derived HERE (one place, one rule): every zone with `value_custody` true OR a non-empty
#        `composition_surfaces` field (#1914 M2). Priority order mirrors zone-coverage.py: value-custody first,
#        tie-broken by id. `--seed-state` (default `not_reached`) is the floor every surface starts at.
#   set --file <matrix.json> --surface <id> --lens-depth <general-solvency|narrow-per-class|discovery-only>
#       [--verdict <FINDING|CLEAN|HARNESS_ERROR|TRANSIENT_ERROR>]
#       Update ONE surface, in place (tmp + os.replace). `general-solvency` REQUIRES `--verdict`; the other depths
#       REJECT one. A `set` shallower-or-equal to the surface's current depth is a NO-OP (never downgrades).
#   summary --file <matrix.json> [--counts | --json]
#       `--counts`: `<general-solvency-count> <total>`. `--json`: the additive fragment for embedding — by_depth /
#       by_verdict counts, the `harness_error_surfaces` GAP list, and a `harness_error` bool.
#
# Exit: 0 ok ; 2 usage/unknown surface ; 3 unreadable/malformed input.
import sys
import os
import json
import datetime

# The closed lens-depth vocabulary, DEEPEST first (the order `totals.by_depth` reports it).
LENS_DEPTHS = (
    "general-solvency",
    "narrow-per-class",
    "discovery-only",
    "not_reached",
)
# The total depth precedence: `set` applies a new depth only when it is STRICTLY deeper (never downgrades).
DEPTH_RANK = {
    "not_reached": 0,
    "discovery-only": 1,
    "narrow-per-class": 2,
    "general-solvency": 3,
}
# The depths a `set` may write — `not_reached` is init-only (the seed floor, never a transition target).
SETTABLE_DEPTHS = ("general-solvency", "narrow-per-class", "discovery-only")
# The closed verdict vocabulary — carried ONLY by a `general-solvency` surface. HARNESS_ERROR is a GAP, not a
# negative: it is recorded DISTINCT from CLEAN precisely because the STAGE 4.5 merge adapter drops both.
# #2033: TRANSIENT_ERROR is a re-runnable run failure (forge starved/killed/timed out under load) — a distinct
# by_verdict bucket, DISTINCT from a permanent HARNESS_ERROR, and (by the recompute_totals guard) NOT enrolled
# in the permanent harness_error_surfaces GAP list.
VERDICTS = ("FINDING", "CLEAN", "HARNESS_ERROR", "TRANSIENT_ERROR")

SCHEMA = "lens-surface-matrix/v1"


def die(rc, msg):
    sys.stderr.write("lens-surface-matrix.py: " + msg + "\n")
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
    rec = read_json(path, "the lens-surface matrix")
    if not isinstance(rec, dict) or not isinstance(rec.get("surfaces"), list):
        die(3, "malformed lens-surface matrix: " + path)
    return rec


def recompute(rec):
    """Recompute `totals` from `surfaces[]`. The ONLY place that policy lives — HARNESS_ERROR surfaces are
    surfaced as an explicit GAP list so no consumer re-derives the CLEAN-vs-HARNESS_ERROR distinction."""
    by_depth = dict((d, 0) for d in LENS_DEPTHS)
    by_verdict = dict((v, 0) for v in VERDICTS)
    harness_errors = []
    for s in rec["surfaces"]:
        d = s.get("lens_depth", "not_reached")
        by_depth[d] = by_depth.get(d, 0) + 1
        v = s.get("verdict")
        if d == "general-solvency" and v in VERDICTS:
            by_verdict[v] = by_verdict.get(v, 0) + 1
            if v == "HARNESS_ERROR":
                harness_errors.append(s.get("id", ""))
    rec["totals"] = {
        "surfaces": len(rec["surfaces"]),
        "by_depth": by_depth,
        "by_verdict": by_verdict,
        "harness_error_surfaces": harness_errors,
    }
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


def find_surface(rec, sid):
    for s in rec["surfaces"]:
        if s.get("id") == sid:
            return s
    die(2, "surface not in the matrix: " + sid)


def is_surface(z):
    """A custody/composition surface: a value-custody zone OR one carrying a non-empty composition_surfaces
    field (#1914 M2). The SINGLE definition of the surface set — the seed loop and its meaning share it."""
    if not isinstance(z, dict):
        return False
    if z.get("value_custody"):
        return True
    cs = z.get("composition_surfaces")
    return isinstance(cs, list) and len(cs) > 0


# ----------------------------------------------------------------------------------------------------------
# init — the record is written BEFORE any lens runs, so absence is not representable.
# ----------------------------------------------------------------------------------------------------------
def cmd_init(argv):
    f = parse_flags(argv, ("--zones", "--out", "--seed-state", "--repo", "--commit"), ())
    for req in ("--zones", "--out"):
        if req not in f:
            die(2, "init requires " + req)
    seed = f.get("--seed-state", "not_reached")
    if seed not in LENS_DEPTHS:
        die(2, "unknown seed state: " + seed)
    zones = read_json(f["--zones"], "zones.json")
    if not isinstance(zones, list):
        zones = []
    surfaces = [z for z in zones if is_surface(z)]
    # Priority order mirrors zone-coverage.py (#1826): value-custody surfaces first, tie-broken by id, so a
    # truncated run only ever drops the lowest-priority surfaces.
    surfaces = sorted(surfaces, key=lambda z: (not z.get("value_custody", False), z.get("id", "")))
    entries = []
    for z in surfaces:
        sid = z.get("id", "")
        if not sid:
            continue
        name = z.get("name", sid)
        cs = z.get("composition_surfaces")
        entries.append({
            "id": sid,
            "name": name,
            "value_custody": bool(z.get("value_custody", False)),
            "composition": isinstance(cs, list) and len(cs) > 0,
            "order": len(entries) + 1,
            "lens_depth": seed,
            "verdict": None,
        })
    started = now_iso()
    rec = {
        "schema": SCHEMA,
        "repo": f.get("--repo", ""),
        "commit": f.get("--commit", ""),
        "started_at": started,
        "updated_at": started,
        "surfaces": entries,
    }
    recompute(rec)
    rec["started_at"] = started
    write_record(f["--out"], rec)
    return 0


# ----------------------------------------------------------------------------------------------------------
# set — the ONLY writer of a surface's lens depth. Monotonic: never downgrades.
# ----------------------------------------------------------------------------------------------------------
def cmd_set(argv):
    f = parse_flags(argv, ("--file", "--surface", "--lens-depth", "--verdict"), ())
    for req in ("--file", "--surface", "--lens-depth"):
        if req not in f:
            die(2, "set requires " + req)
    depth = f["--lens-depth"]
    if depth not in SETTABLE_DEPTHS:
        die(2, "set --lens-depth must be one of " + "|".join(SETTABLE_DEPTHS) + " (got: " + depth + ")")
    verdict = f.get("--verdict")
    if depth == "general-solvency":
        if verdict is None:
            die(2, "general-solvency requires --verdict")
        if verdict not in VERDICTS:
            die(2, "unknown verdict: " + verdict)
    elif verdict is not None:
        die(2, "--verdict is only valid with --lens-depth general-solvency")

    rec = load_record(f["--file"])
    s = find_surface(rec, f["--surface"])
    cur = s.get("lens_depth", "not_reached")
    # NEVER DOWNGRADE — a shallower-or-equal lens is a no-op, so per-class and general rows of one zone can
    # arrive in any order and the record always ends at the deepest lens that reached the surface.
    if DEPTH_RANK.get(depth, 0) <= DEPTH_RANK.get(cur, 0):
        return 0
    s["lens_depth"] = depth
    s["verdict"] = verdict if depth == "general-solvency" else None
    recompute(rec)
    write_record(f["--file"], rec)
    return 0


# ----------------------------------------------------------------------------------------------------------
# summary — the covered/total counts and the merged-file coverage fragment.
# ----------------------------------------------------------------------------------------------------------
def cmd_summary(argv):
    f = parse_flags(argv, ("--file",), ("--counts", "--json"))
    if "--file" not in f:
        die(2, "summary requires --file")
    rec = load_record(f["--file"])
    totals = rec.get("totals", {}) if isinstance(rec.get("totals"), dict) else {}
    by_depth = totals.get("by_depth", {})
    total = len(rec["surfaces"])
    if f.get("--counts"):
        sys.stdout.write("%d %d\n" % (by_depth.get("general-solvency", 0), total))
        return 0
    if f.get("--json"):
        harness_errors = totals.get("harness_error_surfaces", []) or []
        sys.stdout.write(json.dumps({
            "schema": SCHEMA,
            "surfaces": total,
            "by_depth": by_depth,
            "by_verdict": totals.get("by_verdict", {}),
            "harness_error_surfaces": harness_errors,
            "harness_error": bool(harness_errors),
        }) + "\n")
        return 0
    # Default human banner: the general-lens coverage line plus a loud HARNESS_ERROR gap callout.
    gs = by_depth.get("general-solvency", 0)
    sys.stdout.write(
        "lens-surface-matrix.py: [M3] general-solvency lens reached %d of %d surface(s)\n" % (gs, total))
    harness_errors = totals.get("harness_error_surfaces", []) or []
    if harness_errors:
        sys.stdout.write(
            "lens-surface-matrix.py: [M3] HARNESS_ERROR GAP: %d surface(s) left un-probed (%s) "
            "— a settlement seam that failed to compile/generate is NOT a clean negative\n"
            % (len(harness_errors), ", ".join(harness_errors)))
    return 0


COMMANDS = {
    "init": cmd_init,
    "set": cmd_set,
    "summary": cmd_summary,
}


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stdout.write("usage: lens-surface-matrix.py <init|set|summary> [flags]\n")
        return 0 if len(argv) >= 2 else 2
    cmd = COMMANDS.get(argv[1])
    if cmd is None:
        die(2, "unknown subcommand: " + argv[1])
    return cmd(argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
