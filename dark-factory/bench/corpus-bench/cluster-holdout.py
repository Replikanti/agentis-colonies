#!/usr/bin/env python3
# cluster-holdout.py — #2278 M2. HELD-OUT VALIDATION of lib/cluster-findings.py against pre-registered labels.
#
# THE QUESTION. M1 calibrated the root-cause clusterer on dev data only. M2 measures it, unchanged, on the real
# data that motivated it: the #2245 oku arm outputs under fixtures/cluster/oku/. The ruler is a per-finding
# root-cause label set (root-causes.tsv) written by a separate labeller and committed, with its sha256 anchored
# in an issue comment, BEFORE the clusterer ever ran on this data. Nothing here tunes anything: the threshold is
# the module's own DEFAULT_THRESHOLD, and both lib/cluster-findings.py and score-match.py are imported read-only
# (importlib), so neither file changes.
#
# Subcommands:
#   judge-project --arm <name> --truth <tsv> --verified <json> --judge-cache <jsonl> [--batch 12]
#                 [--min-confidence 60]
#       Replays the RECORDED mechanism-judge decisions for one raw arm file exactly the way score-match.py's
#       run_judge() walks them (lead x truth-row batch, same request key, same reply parser) and prints one
#       `<arm>\t<raw idx>\t<sev_id>\t<confidence>` line per MATCH at or above the gate. A cache miss or a
#       JUDGE-ERROR exits 4 (the `--judge cache` fail-closed rule). Batch 12 and gate 60 are the values the #2245
#       cache was recorded with: another batch changes every request key (all lookups miss), another gate
#       changes which MATCHes credit a row. Operator-side only — the self-test never needs the cache.
#   derive --labels <root-causes.tsv>
#       Prints expected-distinct.tsv: every same-block pair of raw entries whose labelled root causes differ,
#       plus the derived per-arm bound as `# M2|bound|<arm>|<n>` lines. Mechanical; never hand-edit its output.
#   check --fixture <dir>
#       The self-test engine (run-corpus-bench.sh --self-test diffs its stdout against expected-check.txt).
#
# LABEL FILE (root-causes.tsv): a header line `arm idx block rc mechanism evidence`, then one TAB-separated row per
# raw verified entry of every arm. idx = 0-based position in the arm's `verified` list; block = the clusterer's
# block key `file:function` (lowercased, `-` when the entry has none); rc = a root-cause id (same rc = one
# minimal fix at one site removes both exploit paths). Only rc distinctness WITHIN a block feeds any assertion.
#
# BOUND. bound(arm) = sum over blocks of |distinct rc in the block| + entries with no block key. Because the
# clusterer never merges across blocks, "0 labelled-distinct merges" forces clusters >= bound; clusters == bound
# with 0 distinct merges therefore means the labelled same-function partition was recovered exactly.
#
# check, per arm (stable one-line records; the verdict is DATA, not the exit code):
#   M2|threshold|<T>                     the module's DEFAULT_THRESHOLD (a change fails the pin visibly)
#   M2|labels|<sha256 root-causes>|<sha256 expected-distinct>
#   M2|<arm>|raw=|clusters=|bound=|distinct_pairs=|distinct_merged=|token_changed=|judge_rows=|judge_kept=
#   M2|<arm>|judge|<sev_id>|rep_match=<0|1>|reps=<idx,...>   one per raw judge-HIT row: the representative of
#                                        every cluster holding a matching member, and whether any of them is
#                                        itself a recorded MATCH for the row
#   M2|mutations|ok                      the distinct-merge counter and the public-content scrub both fire on
#                                        in-memory mutations of the real fixture (no check can pass vacuously)
#   M2|verdict|<PASS|FAIL>|<gating failures or ->|reported:<non-gating findings or ->>
# GATING (STOP 1 decisions 1 + 3): a labelled-distinct merge (`distinct-merge:<arm>`), a token-mode GT change
# (`token-gt:<arm>`), a CLI/in-process partition disagreement (`cli-partition:<arm>`) or a public-content hit
# (`scrub`). REPORTED only: clusters > bound (`under-merge:<arm>`, the benign direction) and a raw judge-HIT row
# none of whose representatives is a recorded MATCH (`judge-loss:<arm>`, routed to the operator spot-check).
#
# python3 stdlib only. Deterministic and offline (no judge, no network).
# Exit: 0 the command ran (any verdict); 2 usage; 3 malformed fixture / labels / judge-matches, or a mutation
#       self-check that did not fire; 4 judge-project cache miss or JUDGE-ERROR.
import sys
import os
import json
import hashlib
import subprocess
import tempfile
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
CLUSTER_PY = os.path.join(HERE, "..", "..", "lib", "cluster-findings.py")
SCORE_PY = os.path.join(HERE, "score-match.py")
LABEL_HEADER = ["arm", "idx", "block", "rc", "mechanism", "evidence"]
DISTINCT_HEADER = "arm\tidx_i\tidx_j\tblock\trc_i\trc_j"
# Absolute host-path shapes that must never ride a public fixture. Client names are deliberately NOT encoded in
# the repo; they stay in the commit-time staged-diff grep.
SCRUB_PATTERNS = ("/home/", "/Users/", "/root/", "/tmp/", "worktrees/")


def die(rc, msg):
    sys.stderr.write("cluster-holdout.py: " + msg + "\n")
    sys.exit(rc)


def _load(modname, path):
    spec = importlib.util.spec_from_file_location(modname, path)
    if spec is None or spec.loader is None:
        die(3, "cannot import " + path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


CL = _load("_holdout_cluster_findings", CLUSTER_PY)
SM = _load("_holdout_score_match", SCORE_PY)


def sha256_file(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as e:
        die(3, "cannot read " + path + ": " + str(e))
    verified = data.get("verified") if isinstance(data, dict) else None
    if not isinstance(verified, list) or any(not isinstance(e, dict) for e in verified):
        die(3, path + ": missing/malformed 'verified' array (every entry must be an object)")
    return data


def read_truth_rows(path):
    """(sev_id, signature) rows exactly as score-match.py:main() keeps them (>= 5 columns, non-empty id)."""
    rows = []
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                cols = line.rstrip("\n").split("\t")
                if len(cols) < 5 or not cols[0]:
                    continue
                if cols[0] == "NONE":
                    die(3, path + ": reserved sev_id 'NONE'")
                rows.append((cols[0], cols[4]))
    except OSError as e:
        die(3, "cannot read " + path + ": " + str(e))
    return rows


def block_str(entry):
    key = CL.block_key(entry)
    return "-" if key is None else key[0] + ":" + key[1]


def parse_args(args, spec):
    """--flag value pairs only; `spec` maps flag -> default (None = required)."""
    out = dict(spec)
    i = 0
    while i < len(args):
        a = args[i]
        if a not in spec:
            die(2, "unknown argument: " + a)
        if i + 1 >= len(args):
            die(2, a + " requires a value")
        out[a] = args[i + 1]
        i += 2
    missing = [k for k, v in out.items() if v is None]
    if missing:
        die(2, "missing required argument(s): " + " ".join(missing))
    return out


# ---- judge-project -------------------------------------------------------------------------------------------
def cmd_judge_project(args):
    a = parse_args(args, {"--arm": None, "--truth": None, "--verified": None, "--judge-cache": None,
                          "--batch": "12", "--min-confidence": "60"})
    try:
        batch = int(a["--batch"])
        min_conf = int(a["--min-confidence"])
    except ValueError:
        die(2, "--batch / --min-confidence must be integers")
    if batch < 1:
        die(2, "--batch must be >= 1")
    rows = read_truth_rows(a["--truth"])
    leads = read_json(a["--verified"])["verified"]
    cache = SM.load_judge_cache(a["--judge-cache"])
    valid = {sev_id for sev_id, _sig in rows}
    order = {sev_id: ri for ri, (sev_id, _sig) in enumerate(rows)}
    errors = 0
    out = []
    for li, lead in enumerate(leads):
        lid = SM.lead_id(li)
        found = []
        for start in range(0, len(rows), batch):
            _text, key = SM.judge_request(lid, lead, rows[start:start + batch])
            entry = cache.get(key)
            if entry is None:
                die(4, "judge-project: no recorded decision for lead " + lid + " (request key " + key + ")")
            decisions, dropped = SM.parse_verdicts(entry.get("raw_reply", ""), lid, valid)
            errors += dropped + (0 if decisions else 1)
            for sev_id, decision, confidence, _reason in decisions:
                if decision == "MATCH" and confidence >= min_conf:
                    found.append((order[sev_id], sev_id, confidence))
        for _ri, sev_id, confidence in sorted(found):
            out.append("%s\t%d\t%s\t%d" % (a["--arm"], li, sev_id, confidence))
    if errors:
        die(4, "judge-project: %d JUDGE-ERROR(s) in the recorded replies; refusing a partial projection" % errors)
    sys.stdout.write("".join(line + "\n" for line in out))
    return 0


# ---- labels + derive -------------------------------------------------------------------------------------------
def read_labels(path):
    """-> list of dicts (arm, idx, block, rc). Malformed -> exit 3."""
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError as e:
        die(3, "cannot read " + path + ": " + str(e))
    labels = []
    seen = set()
    header_seen = False
    for n, line in enumerate(lines, 1):
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if not header_seen:
            if cols != LABEL_HEADER:
                die(3, path + ": first non-comment line must be the header " + "\\t".join(LABEL_HEADER))
            header_seen = True
            continue
        if len(cols) != len(LABEL_HEADER) or not all(c.strip() for c in cols[:4]):
            die(3, "%s:%d: expected %d TAB-separated columns with non-empty arm/idx/block/rc"
                % (path, n, len(LABEL_HEADER)))
        try:
            idx = int(cols[1])
        except ValueError:
            die(3, "%s:%d: idx '%s' is not an integer" % (path, n, cols[1]))
        if (cols[0], idx) in seen:
            die(3, "%s:%d: %s idx %d is labelled twice" % (path, n, cols[0], idx))
        seen.add((cols[0], idx))
        labels.append({"arm": cols[0], "idx": idx, "block": cols[2], "rc": cols[3]})
    if not header_seen:
        die(3, path + ": no header line")
    return labels


def derive(labels):
    """-> (pairs, bounds): pairs = sorted (arm, i, j, block, rc_i, rc_j) for same-block different-rc entries;
    bounds = {arm: bound}."""
    by_block = {}
    bounds = {}
    for lab in labels:
        bounds.setdefault(lab["arm"], 0)
        if lab["block"] == "-":
            bounds[lab["arm"]] += 1
            continue
        by_block.setdefault((lab["arm"], lab["block"]), []).append(lab)
    pairs = []
    for (arm, block), members in by_block.items():
        bounds[arm] += len({m["rc"] for m in members})
        members = sorted(members, key=lambda m: m["idx"])
        for x in range(len(members)):
            for y in range(x + 1, len(members)):
                if members[x]["rc"] != members[y]["rc"]:
                    pairs.append((arm, members[x]["idx"], members[y]["idx"], block,
                                  members[x]["rc"], members[y]["rc"]))
    pairs.sort()
    return pairs, bounds


def render_distinct(pairs, bounds):
    out = [
        "# expected-distinct.tsv — #2278 M2. DERIVED from root-causes.tsv by `cluster-holdout.py derive`; never",
        "# hand-edit (`check` fails when this file differs from the derivation). One row per same-block pair of raw",
        "# entries whose pre-registered root causes differ; idx = 0-based position in the arm's `verified` list.",
        "# bound(arm) = sum over (file, function) blocks of the distinct rc in the block + entries with no block key.",
    ]
    for arm in sorted(bounds):
        out.append("# M2|bound|%s|%d" % (arm, bounds[arm]))
        out.append("# M2|distinct_pairs|%s|%d" % (arm, sum(1 for p in pairs if p[0] == arm)))
    out.append(DISTINCT_HEADER)
    for p in pairs:
        out.append("%s\t%d\t%d\t%s\t%s\t%s" % p)
    return "".join(line + "\n" for line in out)


def cmd_derive(args):
    a = parse_args(args, {"--labels": None})
    pairs, bounds = derive(read_labels(a["--labels"]))
    sys.stdout.write(render_distinct(pairs, bounds))
    return 0


# ---- check -----------------------------------------------------------------------------------------------------
def read_judge_matches(path, arms, truth_ids):
    """-> (matches {arm: {sev_id: set(idx)}}, readout {arm: set(sev_id)}). The `# readout\t<arm>\t<ids>` header
    lines name the rows the #2245 readout credits; each arm's match union must equal them."""
    matches = {arm: {} for arm in arms}
    readout = {}
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError as e:
        die(3, "cannot read " + path + ": " + str(e))
    for n, line in enumerate(lines, 1):
        if not line:
            continue
        cols = line.split("\t")
        if line.startswith("#"):
            if cols[0] == "# readout" and len(cols) == 3:
                readout[cols[1]] = set(cols[2].split(","))
            continue
        if len(cols) != 4 or cols[0] not in matches or cols[2] not in truth_ids:
            die(3, "%s:%d: malformed judge-match line" % (path, n))
        try:
            idx = int(cols[1])
        except ValueError:
            die(3, "%s:%d: idx is not an integer" % (path, n))
        matches[cols[0]].setdefault(cols[2], set()).add(idx)
    for arm in arms:
        if set(matches[arm]) != readout.get(arm):
            die(3, "%s: arm %s judge-match rows %s differ from its '# readout' rows %s"
                % (path, arm, ",".join(sorted(matches[arm])), ",".join(sorted(readout.get(arm) or []))))
    return matches, readout


def scrub_hits(value):
    """Count string values (recursively) carrying an absolute host-path shape."""
    if isinstance(value, str):
        return 1 if any(p in value for p in SCRUB_PATTERNS) else 0
    if isinstance(value, dict):
        return sum(scrub_hits(v) for v in value.values())
    if isinstance(value, list):
        return sum(scrub_hits(v) for v in value)
    return 0


def token_norm(scorecard):
    """run-corpus-bench.sh's cl_norm: drop LEADS; compare LOCHIT on sev_id + the lead's (file, function)."""
    out = []
    for line in scorecard.split("\n"):
        cols = line.split("\t")
        if cols[0] == "LEADS":
            continue
        if cols[0] == "LOCHIT" and len(cols) >= 3:
            p = cols[2].split(":")
            out.append("LOCHIT\t%s\t%s" % (cols[1], (p[0] + ":" + (p[1] if len(p) > 1 else "")).lower()))
            continue
        out.append(line)
    return out


def score_token(truth, verified):
    proc = subprocess.run([sys.executable, SCORE_PY, truth, verified], capture_output=True, text=True)
    if proc.returncode != 0:
        die(3, "score-match.py failed on " + verified + ": " + proc.stderr.strip())
    return proc.stdout


def distinct_merged(pairs, arm, cluster_of):
    return sum(1 for p in pairs if p[0] == arm and cluster_of[p[1]] == cluster_of[p[2]])


def assess(results):
    """-> (gating failures, reported findings), both lists of `<kind>:<arm>` / `scrub` strings."""
    fails, reported = [], []
    for r in results:
        if r["cli_mismatch"]:
            fails.append("cli-partition:" + r["arm"])
        if r["distinct_merged"]:
            fails.append("distinct-merge:" + r["arm"])
        if r["token_changed"]:
            fails.append("token-gt:" + r["arm"])
        if r["clusters"] > r["bound"]:
            reported.append("under-merge:" + r["arm"])
        if r["judge_kept"] < r["judge_rows"]:
            reported.append("judge-loss:" + r["arm"])
    return fails, reported


def cmd_check(args):
    a = parse_args(args, {"--fixture": None})
    fx = a["--fixture"]
    truth = os.path.join(fx, "truth.tsv")
    labels_path = os.path.join(fx, "root-causes.tsv")
    distinct_path = os.path.join(fx, "expected-distinct.tsv")
    arms = sorted(d for d in os.listdir(fx) if os.path.isfile(os.path.join(fx, d, "verified_findings.json")))
    if not arms:
        die(3, fx + ": no <arm>/verified_findings.json")
    rows = read_truth_rows(truth)
    truth_ids = {sev_id for sev_id, _sig in rows}
    data = {arm: read_json(os.path.join(fx, arm, "verified_findings.json")) for arm in arms}

    # Label integrity: every raw entry labelled exactly once with its real block key, and the committed
    # expected-distinct.tsv equal to the derivation.
    labels = read_labels(labels_path)
    by_arm = {arm: {} for arm in arms}
    for lab in labels:
        if lab["arm"] not in by_arm:
            die(3, labels_path + ": unknown arm '" + lab["arm"] + "'")
        by_arm[lab["arm"]][lab["idx"]] = lab
    for arm in arms:
        entries = data[arm]["verified"]
        if sorted(by_arm[arm]) != list(range(len(entries))):
            die(3, "%s: arm %s labels idx set is not exactly 0..%d" % (labels_path, arm, len(entries) - 1))
        for i, e in enumerate(entries):
            if by_arm[arm][i]["block"] != block_str(e):
                die(3, "%s: %s idx %d block '%s' != block_key '%s'"
                    % (labels_path, arm, i, by_arm[arm][i]["block"], block_str(e)))
    pairs, bounds = derive(labels)
    try:
        with open(distinct_path, encoding="utf-8") as fh:
            committed = fh.read()
    except OSError as e:
        die(3, "cannot read " + distinct_path + ": " + str(e))
    if committed != render_distinct(pairs, bounds):
        die(3, distinct_path + " differs from `derive --labels root-causes.tsv`")
    matches, _readout = read_judge_matches(os.path.join(fx, "judge-matches.tsv"), arms, truth_ids)

    out = ["M2|threshold|%.2f" % CL.DEFAULT_THRESHOLD,
           "M2|labels|%s|%s" % (sha256_file(labels_path), sha256_file(distinct_path))]
    results = []
    partitions = {}
    tmp = tempfile.mkdtemp(prefix="cluster-holdout.")
    try:
        for arm in arms:
            src = os.path.join(fx, arm, "verified_findings.json")
            entries = data[arm]["verified"]
            groups = CL.cluster_entries(entries, CL.DEFAULT_THRESHOLD)
            cluster_of = {}
            for gi, (_rep, members) in enumerate(groups):
                for m in members:
                    cluster_of[m] = gi
            partitions[arm] = (groups, cluster_of)
            # The shipped CLI path must agree with the in-process partition; its output is the clustered file
            # the token-mode scorer reads (merged == 0 writes no file: the raw file IS the clustered view).
            dst = os.path.join(tmp, arm + ".json")
            proc = subprocess.run([sys.executable, CLUSTER_PY, "cluster", "--in", src, "--out", dst],
                                  capture_output=True, text=True)
            want = "CLUSTER|%d|%d|%d" % (len(entries), len(groups), len(entries) - len(groups))
            cli_mismatch = proc.returncode != 0 or proc.stdout.strip() != want
            clustered = dst if os.path.isfile(dst) else src
            token_changed = token_norm(score_token(truth, src)) != token_norm(score_token(truth, clustered))
            reps = {gi: rep for gi, (rep, _m) in enumerate(groups)}
            judge_lines = []
            kept = 0
            for sev_id, _sig in rows:
                hit_idx = matches[arm].get(sev_id)
                if not hit_idx:
                    continue
                row_reps = sorted({reps[cluster_of[i]] for i in hit_idx})
                rep_match = 1 if any(r in hit_idx for r in row_reps) else 0
                kept += rep_match
                judge_lines.append("M2|%s|judge|%s|rep_match=%d|reps=%s"
                                   % (arm, sev_id, rep_match, ",".join(str(r) for r in row_reps)))
            r = {"arm": arm, "raw": len(entries), "clusters": len(groups), "bound": bounds.get(arm, 0),
                 "distinct_pairs": sum(1 for p in pairs if p[0] == arm),
                 "distinct_merged": distinct_merged(pairs, arm, cluster_of),
                 "token_changed": 1 if token_changed else 0, "cli_mismatch": cli_mismatch,
                 "judge_rows": len(matches[arm]), "judge_kept": kept}
            results.append(r)
            out.append("M2|%s|raw=%d|clusters=%d|bound=%d|distinct_pairs=%d|distinct_merged=%d|token_changed=%d"
                       "|judge_rows=%d|judge_kept=%d"
                       % (arm, r["raw"], r["clusters"], r["bound"], r["distinct_pairs"], r["distinct_merged"],
                          r["token_changed"], r["judge_rows"], r["judge_kept"]))
            out.extend(judge_lines)
    finally:
        for name in os.listdir(tmp):
            os.unlink(os.path.join(tmp, name))
        os.rmdir(tmp)

    scrub = sum(scrub_hits(data[arm]) for arm in arms)
    try:
        with open(truth, encoding="utf-8", errors="ignore") as fh:
            scrub += scrub_hits(fh.read().split("\n"))
    except OSError as e:
        die(3, "cannot read " + truth + ": " + str(e))

    # Mutation self-checks on in-memory copies. (1) Relabel one member of the first multi-member cluster with a
    # fresh rc: the distinct-merge counter must fire and the verdict must FAIL. (2) Plant a host path in one
    # exploit text: the scrub must fire. The path is assembled from fragments so this file never carries one.
    mut_fail = []
    target = None
    for arm in arms:
        for _rep, members in partitions[arm][0]:
            if len(members) > 1:
                target = (arm, members[-1])
                break
        if target:
            break
    if target is None:
        mut_fail.append("relabel(no multi-member cluster)")
    else:
        mutated = [dict(lab) for lab in labels]
        for lab in mutated:
            if (lab["arm"], lab["idx"]) == target:
                lab["rc"] = "MUTATION-FRESH-RC"
        m_pairs, _m_bounds = derive(mutated)
        m_results = [dict(r) for r in results]
        for r in m_results:
            r["distinct_merged"] = distinct_merged(m_pairs, r["arm"], partitions[r["arm"]][1])
        m_fails, _rep = assess(m_results)
        if not any(f == "distinct-merge:" + target[0] for f in m_fails):
            mut_fail.append("relabel")
    planted = json.loads(json.dumps(data[arms[0]]))
    if planted["verified"]:
        planted["verified"][0]["exploit"] = str(planted["verified"][0].get("exploit") or "") + " /" + "home" + "/x/"
    if scrub_hits(planted) <= scrub_hits(data[arms[0]]):
        mut_fail.append("scrub")

    fails, reported = assess(results)
    if scrub:
        fails.append("scrub")
    out.append("M2|mutations|" + ("ok" if not mut_fail else "FAIL:" + ",".join(mut_fail)))
    out.append("M2|verdict|%s|%s|reported:%s" % ("FAIL" if fails else "PASS", ",".join(fails) or "-",
                                                ",".join(reported) or "-"))
    sys.stdout.write("".join(line + "\n" for line in out))
    return 3 if mut_fail else 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stderr.write("usage: cluster-holdout.py judge-project --arm <name> --truth <tsv> --verified <json> "
                         "--judge-cache <jsonl> [--batch 12] [--min-confidence 60]\n"
                         "       cluster-holdout.py derive --labels <root-causes.tsv>\n"
                         "       cluster-holdout.py check --fixture <dir>\n")
        return 2 if len(argv) < 2 else 0
    if argv[1] == "judge-project":
        return cmd_judge_project(argv[2:])
    if argv[1] == "derive":
        return cmd_derive(argv[2:])
    if argv[1] == "check":
        return cmd_check(argv[2:])
    die(2, "unknown subcommand: " + argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
