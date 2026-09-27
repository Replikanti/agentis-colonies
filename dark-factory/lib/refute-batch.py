#!/usr/bin/env python3
# refute-batch.py — #2284. THE BATCH PLAN for the refute gate's FIRST READ.
#
# THE PROBLEM. Discovery files one candidate per (subsystem x class) cell, so the same function often reaches the
# refute gate several times — up to six separate sessions that each re-read the same code. Verdicts must stay
# per-candidate (refuting only a representative would drop the whole group on one false refutation), so the only
# safe saving is to share the READ: one session judges every candidate of one function, one block each, and
# run-refute.sh splits the reply back into per-candidate logs that the unchanged single-candidate path consumes.
#
# THE KEY. A group is (block_key(location), code file). block_key is IMPORTED from lib/cluster-findings.py, so
# the (file, function) pair is defined in exactly one place — the same pair corpus-bench's score-match.py
# matches on and #2278 clusters on. The code file is part of the key verbatim (case-sensitive): two files that
# differ only in case are two files. A location block_key cannot key (`File.sol:123`, a blank location) is
# refuted individually.
#
# CHUNKS. A group larger than --max is split into ceil(s/max) contiguous chunks whose sizes differ by at most one,
# larger chunks first (8 -> 4+4, 7 -> 4+3, 13 -> 5+4+4 at max 6). A group or chunk of size 1 is refuted
# individually — a one-member batch saves nothing.
#
# Subcommands:
#   plan --in <eligible.tsv> --max N
#       Input: one `n \t slug \t location \t codefile` row per gate-bound candidate (verify-findings.sh writes only
#       the rows that would really reach the refute gate). Groups are ordered by first appearance, members by n.
#       Stdout: one `batch_id \t k \t size \t n \t slug` row per BATCHED member (batch ids from 1, k from 1).
#       Stderr: `BATCHPLAN|<eligible>|<batches>|<batched>|<individual>`.
#   summary --results <discovery-results.json> [--max N]
#       A READ-ONLY session predictor over every candidate with a non-blank location (no adjudication, no
#       preflight, no pay-floor — it predicts, it does not gate). Stdout: the BATCHPLAN line plus
#       `first_read_sessions=<batches+individual> of <n> (<pct>% fewer)`.
#
# python3 stdlib only. Deterministic: the same input always yields byte-identical output.
# Exit: 0 ok; 2 usage error; 3 unreadable input.
import sys
import os
import json
import importlib.util

sys.dont_write_bytecode = True  # importing cluster-findings.py must not drop a __pycache__ into the repo

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MAX = 6


def die(rc, msg):
    sys.stderr.write("refute-batch.py: " + msg + "\n")
    sys.exit(rc)


def _load_block_key():
    path = os.path.join(HERE, "cluster-findings.py")
    spec = importlib.util.spec_from_file_location("_refute_batch_cluster", path)
    if spec is None or spec.loader is None:
        die(3, "cannot import cluster-findings.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.block_key


block_key = _load_block_key()


def bare_codefile(location):
    # The code file of a (possibly decorated) location. A COPY of verify-findings.sh's bare_codefile() (its
    # candidates parse), pinned by demo-refute-batch.sh against that copy; only `summary` uses it, because `plan`
    # is handed the code file verify-findings.sh already derived.
    s = location
    s = s.split("~", 1)[0]
    s = s.split(":", 1)[0]
    s = s.split("@", 1)[0]
    s = s.strip().rstrip("(").strip()
    return s


def chunk_sizes(s, mx):
    """Balanced contiguous chunk sizes for a group of s members at cap mx, larger chunks first."""
    if s <= mx:
        return [s]
    c = -(-s // mx)
    base, extra = divmod(s, c)
    return [base + 1] * extra + [base] * (c - extra)


def plan_rows(rows, mx):
    """rows: [(n, slug, location, codefile)] in input order. Returns (members, stats) where members is
    [(batch_id, k, size, n, slug)] and stats = (eligible, batches, batched, individual)."""
    groups = {}
    order = []
    individual = 0
    for n, slug, location, codefile in rows:
        key = block_key({"location": location})
        if key is None:
            individual += 1
            continue
        gk = (key, codefile)
        if gk not in groups:
            groups[gk] = []
            order.append(gk)
        groups[gk].append((n, slug))
    members = []
    batch_id = 0
    for gk in order:
        mem = sorted(groups[gk], key=lambda m: m[0])
        pos = 0
        for size in chunk_sizes(len(mem), mx):
            chunk = mem[pos:pos + size]
            pos += size
            if size < 2:
                individual += size
                continue
            batch_id += 1
            for k, (n, slug) in enumerate(chunk, start=1):
                members.append((batch_id, k, size, n, slug))
    return members, (len(rows), batch_id, len(members), individual)


def parse_max(argv):
    mx = DEFAULT_MAX
    if "--max" in argv:
        i = argv.index("--max")
        if i + 1 >= len(argv):
            die(2, "--max needs a value")
        v = argv[i + 1]
        if not v.isdigit() or int(v) < 2:
            die(2, "--max must be an integer >= 2 (got '%s')" % v)
        mx = int(v)
    return mx


def arg_value(argv, flag):
    if flag not in argv:
        return None
    i = argv.index(flag)
    if i + 1 >= len(argv):
        die(2, flag + " needs a value")
    return argv[i + 1]


def cmd_plan(argv):
    src = arg_value(argv, "--in")
    if not src:
        die(2, "plan needs --in <eligible.tsv>")
    mx = parse_max(argv)
    rows = []
    try:
        with open(src, encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line:
                    continue
                f = line.split("\t")
                while len(f) < 4:
                    f.append("")
                if not f[0].isdigit():
                    die(3, "malformed eligible row (n is not an integer): " + line)
                rows.append((int(f[0]), f[1], f[2], f[3]))
    except OSError as e:
        die(3, "cannot read %s: %s" % (src, e))
    members, stats = plan_rows(rows, mx)
    for m in members:
        sys.stdout.write("\t".join(str(x) for x in m) + "\n")
    sys.stderr.write("BATCHPLAN|%d|%d|%d|%d\n" % stats)
    return 0


def cmd_summary(argv):
    src = arg_value(argv, "--results")
    if not src:
        die(2, "summary needs --results <discovery-results.json>")
    mx = parse_max(argv)
    try:
        data = json.load(open(src, encoding="utf-8"))
    except (OSError, ValueError) as e:
        die(3, "cannot read %s: %s" % (src, e))
    rows = []
    n = 0
    for cell in data.get("cells", []) if isinstance(data, dict) else []:
        for cand in cell.get("candidates", []):
            location = str(cand).split("|", 1)[0]
            if not location.strip():
                continue
            n += 1
            rows.append((n, "", location, bare_codefile(location)))
    _, stats = plan_rows(rows, mx)
    eligible, batches, batched, individual = stats
    sessions = batches + individual
    pct = int(round(100.0 * (eligible - sessions) / eligible)) if eligible else 0
    sys.stdout.write("BATCHPLAN|%d|%d|%d|%d\n" % stats)
    sys.stdout.write("first_read_sessions=%d of %d (%d%% fewer)\n" % (sessions, eligible, pct))
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stderr.write("usage: refute-batch.py plan --in <eligible.tsv> --max N\n"
                         "       refute-batch.py summary --results <discovery-results.json> [--max N]\n")
        return 2 if len(argv) < 2 else 0
    if argv[1] == "plan":
        return cmd_plan(argv[2:])
    if argv[1] == "summary":
        return cmd_summary(argv[2:])
    die(2, "unknown subcommand: " + argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
