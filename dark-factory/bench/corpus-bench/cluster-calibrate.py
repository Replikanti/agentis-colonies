#!/usr/bin/env python3
# cluster-calibrate.py — #2306. Derives the two cannot-link constants of lib/cluster-findings.py (method v2) from
# DEV labels only, by the fixed rule the #2306 plan pre-registered, and prints the record that is pinned as
# fixtures/cluster-findings/calibration-v2.txt (run-corpus-bench.sh --self-test diffs it and checks that the chosen
# values equal the module's LINE_WINDOW / DEFECT_TAU).
#
# SOURCES. fixtures/cluster-findings/dev-root-causes.tsv: one hand label per finding of the 12 in-repo dev findings
# files (expected-dev-counts.tsv) and the two #2278 M1 synthetic fixtures. A labelled-SAME pair is two entries of one
# file with the same block key and the same rc; a labelled-DISTINCT pair has the same block key and different rcs.
# The held-out oku fixture (bench/corpus-bench/fixtures/cluster/oku/) is never opened, and no held-out candidate
# contest is in the label file.
#
# RULE.
#   W   = the largest |line_a - line_b| over dev labelled-same pairs where both locations cite a line.
#   tau = the largest value of TAU_GRID whose defect-clause veto (both clause identifier sets non-empty and
#         Jaccard <= tau) fires on no dev labelled-same pair. If even 0.0 fires, tau = 0.0 and the vetoed dev pairs
#         are listed (`CAL|vetoed_same|...`): distinctness ranks above compression.
#   CONSTRAINT: with the chosen (W, tau), every labelled-distinct pair of same-function-distinct.json and of
#         same-function-shared-consequence.json (labels: expected-clusters-v2.tsv) lands in separate v2 clusters.
#         The shared-consequence fixture is a constraint check only, never a derivation source, so its author
#         cannot steer W or tau. A violated constraint prints `|FAIL` and exits 1: the grid is not extended
#         without a plan amendment.
#
# python3 stdlib only. Deterministic and offline. Exit: 0 record printed, constraint held; 1 constraint violated;
# 2 usage; 3 malformed or missing label / fixture file.
import sys
import os
import json
import hashlib
import importlib.util

sys.dont_write_bytecode = True  # importing cluster-findings.py must not drop a __pycache__ into the repo

HERE = os.path.dirname(os.path.abspath(__file__))
DF = os.path.normpath(os.path.join(HERE, "..", ".."))
CLUSTER_PY = os.path.join(DF, "lib", "cluster-findings.py")
LABELS = "fixtures/cluster-findings/dev-root-causes.tsv"
LABEL_HEADER = ["file", "idx", "block", "rc", "note"]
DISTINCT_FIXTURE = "fixtures/cluster-findings/same-function-distinct.json"
SHARED_FIXTURE = "fixtures/cluster-findings/same-function-shared-consequence.json"
SHARED_LABELS = "fixtures/cluster-findings/expected-clusters-v2.tsv"
TAU_GRID = (0.0, 0.34, 0.5)


def die(rc, msg):
    sys.stderr.write("cluster-calibrate.py: " + msg + "\n")
    sys.exit(rc)


def _load_cluster():
    spec = importlib.util.spec_from_file_location("_calibrate_cluster_findings", CLUSTER_PY)
    if spec is None or spec.loader is None:
        die(3, "cannot import " + CLUSTER_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


CL = _load_cluster()


def read_bytes(rel):
    try:
        with open(os.path.join(DF, rel), "rb") as fh:
            return fh.read()
    except OSError as e:
        die(3, "cannot read " + rel + ": " + str(e))


def read_verified(rel):
    try:
        data = json.loads(read_bytes(rel).decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as e:
        die(3, rel + ": " + str(e))
    verified = data.get("verified") if isinstance(data, dict) else None
    if not isinstance(verified, list) or any(not isinstance(e, dict) for e in verified):
        die(3, rel + ": missing/malformed 'verified' array")
    return verified


def block_str(entry):
    key = CL.block_key(entry)
    return "-" if key is None else key[0] + ":" + key[1]


def read_dev_labels():
    """-> ordered {file: {idx: (block, rc)}}; every entry of every named file labelled exactly once with its real
    block key."""
    labels = {}
    header_seen = False
    for n, line in enumerate(read_bytes(LABELS).decode("utf-8").split("\n"), 1):
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if not header_seen:
            if cols != LABEL_HEADER:
                die(3, LABELS + ": first non-comment line must be the header " + "\\t".join(LABEL_HEADER))
            header_seen = True
            continue
        if len(cols) != len(LABEL_HEADER) or not all(c.strip() for c in cols[:4]):
            die(3, "%s:%d: expected %d TAB-separated columns with non-empty file/idx/block/rc"
                % (LABELS, n, len(LABEL_HEADER)))
        try:
            idx = int(cols[1])
        except ValueError:
            die(3, "%s:%d: idx '%s' is not an integer" % (LABELS, n, cols[1]))
        per = labels.setdefault(cols[0], {})
        if idx in per:
            die(3, "%s:%d: %s idx %d is labelled twice" % (LABELS, n, cols[0], idx))
        per[idx] = (cols[2], cols[3])
    if not header_seen:
        die(3, LABELS + ": no header line")
    for rel, per in labels.items():
        verified = read_verified(rel)
        if sorted(per) != list(range(len(verified))):
            die(3, "%s: %s labels idx set is not exactly 0..%d" % (LABELS, rel, len(verified) - 1))
        for i, e in enumerate(verified):
            if per[i][0] != block_str(e):
                die(3, "%s: %s idx %d block '%s' != block_key '%s'" % (LABELS, rel, i, per[i][0], block_str(e)))
    return labels


def read_shared_labels():
    """-> {idx: rc} from expected-clusters-v2.tsv (header `idx location rc v2_cluster`)."""
    out = {}
    header_seen = False
    for n, line in enumerate(read_bytes(SHARED_LABELS).decode("utf-8").split("\n"), 1):
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if not header_seen:
            if cols != ["idx", "location", "rc", "v2_cluster"]:
                die(3, SHARED_LABELS + ": bad header")
            header_seen = True
            continue
        if len(cols) != 4:
            die(3, "%s:%d: expected 4 TAB-separated columns" % (SHARED_LABELS, n))
        try:
            out[int(cols[0])] = cols[2]
        except ValueError:
            die(3, "%s:%d: idx is not an integer" % (SHARED_LABELS, n))
    return out


def pairs(verified, rcs, same):
    """Same-block pairs (i < j) whose rcs are equal (same=True) or differ (same=False)."""
    by_block = {}
    for i, e in enumerate(verified):
        key = CL.block_key(e)
        if key is not None:
            by_block.setdefault(key, []).append(i)
    out = []
    for members in by_block.values():
        for x in range(len(members)):
            for y in range(x + 1, len(members)):
                a, b = members[x], members[y]
                if (rcs[a] == rcs[b]) == same:
                    out.append((a, b))
    return sorted(out)


def main(argv):
    if len(argv) > 1:
        if argv[1] in ("-h", "--help"):
            sys.stderr.write("usage: cluster-calibrate.py   (no arguments; prints the #2306 calibration record)\n")
            return 0
        die(2, "takes no arguments")
    labels = read_dev_labels()
    same_rows = []  # (file, a, b, line_a, line_b, clause_a, clause_b)
    for rel, per in labels.items():
        verified = read_verified(rel)
        rcs = {i: per[i][1] for i in per}
        for a, b in pairs(verified, rcs, True):
            key = CL.block_key(verified[a])
            same_rows.append((rel, a, b, CL.location_line(verified[a]), CL.location_line(verified[b]),
                              CL.defect_identifiers(verified[a], key), CL.defect_identifiers(verified[b], key)))

    both_lines = [r for r in same_rows if r[3] is not None and r[4] is not None]
    both_clause = [r for r in same_rows if r[5] and r[6]]
    w = max([abs(r[3] - r[4]) for r in both_lines] or [0])
    w_from = [r for r in both_lines if abs(r[3] - r[4]) == w]
    out = ["CAL|rule|W=max line spread over dev labelled-same pairs citing two lines"
           "|tau=max of {%s} vetoing no dev labelled-same pair, else 0.00"
           % ",".join("%.2f" % t for t in TAU_GRID),
           "CAL|data|files=%d|labelled_same_pairs=%d|both_lines=%d|both_clause_ids=%d"
           % (len(labels), len(same_rows), len(both_lines), len(both_clause)),
           "CAL|W|%d|from=%s" % (w, ",".join("%s:%d/%d" % (r[0], r[1], r[2]) for r in w_from) or "-")]
    vetoed = {}
    for t in TAU_GRID:
        vetoed[t] = [r for r in both_clause if CL.jaccard(r[5], r[6]) <= t]
        out.append("CAL|tau|%.2f|vetoes_same=%d" % (t, len(vetoed[t])))
    clean = [t for t in TAU_GRID if not vetoed[t]]
    tau = max(clean) if clean else 0.0
    for r in vetoed[tau]:
        out.append("CAL|vetoed_same|%s|%d,%d|J=%.2f" % (r[0], r[1], r[2], CL.jaccard(r[5], r[6])))

    ok = True
    shared_rc = read_shared_labels()
    for rel, rcs in ((DISTINCT_FIXTURE, {i: labels[DISTINCT_FIXTURE][i][1] for i in labels[DISTINCT_FIXTURE]}),
                     (SHARED_FIXTURE, shared_rc)):
        verified = read_verified(rel)
        if sorted(rcs) != list(range(len(verified))):
            die(3, rel + ": labels do not cover every entry exactly once")
        dist = pairs(verified, rcs, False)
        cluster_of = {}
        for method in ("v1", "v2"):
            groups = CL.cluster_entries(verified, CL.DEFAULT_THRESHOLD, method, line_window=w, defect_tau=tau)
            cluster_of[method] = {m: gi for gi, (_rep, members) in enumerate(groups) for m in members}
        v1_merged = sum(1 for a, b in dist if cluster_of["v1"][a] == cluster_of["v1"][b])
        separated = sum(1 for a, b in dist if cluster_of["v2"][a] != cluster_of["v2"][b])
        held = separated == len(dist)
        ok = ok and held
        out.append("CAL|constraint|%s|distinct_pairs=%d|v1_merged=%d|v2_separated=%d|%s"
                   % (rel, len(dist), v1_merged, separated, "OK" if held else "FAIL"))
    out.append("CAL|chosen|W=%d|tau=%.2f" % (w, tau))
    out.append("CAL|sources|" + "|".join("%s=%s" % (rel, hashlib.sha256(read_bytes(rel)).hexdigest())
                                         for rel in [LABELS] + list(labels)))
    out.append("CAL|constraint_sources|" + "|".join("%s=%s" % (rel, hashlib.sha256(read_bytes(rel)).hexdigest())
                                                    for rel in (SHARED_FIXTURE, SHARED_LABELS)))
    out.append("CAL|oku|not-consulted")
    sys.stdout.write("".join(line + "\n" for line in out))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
