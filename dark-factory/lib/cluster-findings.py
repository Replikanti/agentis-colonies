#!/usr/bin/env python3
# cluster-findings.py — #2278. ROOT-CAUSE CLUSTERING of verified_findings.json.
#
# THE PROBLEM. Discovery runs one cell per (subsystem x bug class), and every cell that reaches the same bug
# files its own candidate. Each copy passes the refute gate on its own, so verify/verified_findings.json carries
# the same root cause several times (an inverted staleness check once per class that saw it). Recall is not
# hurt; triage, PoC work and any submission scale with the RAW count instead of the DISTINCT count.
#
# THE RULE. Findings are clustered only INSIDE a block, and the block key is the exact (file, function) pair
# bench/corpus-bench/score-match.py:lead_location() parses out of `location`:
#   file     = location.split(":")[0].strip().lower()
#   function = location.split(":")[1].strip().lower(), when that part exists and is not numeric
# Every member of a cluster therefore carries the same (file, function), and the corpus-bench location-first
# scorer's per-row HIT/MISS cannot change when duplicates collapse onto one representative
# (run-corpus-bench.sh --self-test asserts it on every in-repo findings file with ground truth).
# Never clustered, always passed through as singletons: an entry with no parseable function (`File.sol:123`), an
# empty location or file part, and an entry carrying a `source` key (a post-STAGE-4 append, #1938 / #2156).
#
# SIMILARITY. Jaccard over the CODE IDENTIFIERS the `exploit` text cites, not over prose shingles: on real
# exploit prose, word 2/3-shingles scored true duplicates as low as 0.01, while identifier sets separate the
# duplicates from distinct bugs in the same file. An identifier is a `[A-Za-z_][A-Za-z0-9_]*` token that has a
# lower-to-upper transition, an underscore or a digit, or is directly followed by `(`; lowercased. Removed from
# the set: the block's own function name, the file's contract basename, and the pinned generic STOPLIST below
# (Solidity primitive types and ubiquitous calls). An empty union scores 0, so two texts citing no identifier
# never merge. Line numbers never PROPOSE a merge: duplicates cite lines up to dozens apart and distinct bugs can
# cite the same one, so they are only a split signal (CANNOT-LINK below).
#
# LINKAGE. Agglomerative AVERAGE linkage inside each block: merge the cluster pair with the highest mean pairwise
# similarity while that mean is >= the threshold; ties go to the lowest member indices. Average linkage is the
# conservative choice — one bridging text cannot chain two different bugs together the way single linkage would.
#
# CANNOT-LINK REFINEMENT (#2306, method v2, the default). Two distinct defects in ONE function share their callers
# and consumers, so their exploit texts describe the same downstream consequence chain and the identifier Jaccard
# above merges them (the #2278 M2 held-out FAIL: J = 0.33 >= T on two different defects of one function). v2 keeps
# v1 as the only thing that PROPOSES merges and adds a deterministic veto: every v1 cluster is re-agglomerated with
# the same linkage and threshold, and two sub-clusters may merge only if no pair across them is cannot-linked. A pair
# is cannot-linked when
#   (a) both `location`s cite a line (the first leading integer of a `:`-part after the function) and the lines
#       are more than LINE_WINDOW apart, or
#   (b) both exploit texts cite identifiers in their DEFECT CLAUSE — the text before the first DEFECT_BOUNDARY_RE
#       match (a consequence connective: `so`, `which`, `allowing`, `;`, `->`, a sentence end, ...), filtered like
#       the similarity identifiers — and those two sets have Jaccard <= DEFECT_TAU.
# Each signal covers the other's blind spot: a location without a line still has its clause, a clause without
# identifiers still has its line. Every v2 cluster is a subset of a v1 cluster, so v2 can never merge a pair v1
# keeps apart; it can only split. With both vetoes disabled (LINE_WINDOW = infinity, DEFECT_TAU < 0) v2 equals v1.
# `--method v1` reproduces the #2278 clusterer byte for byte (output, `clustering.method`, no `cannot_link` key).
#
# REPRESENTATIVE. The member with, in order: the highest severity (critical > high > medium > low > unknown,
# after normalising `severity=` / `<...>` wrappers — the SEV_RANK vocabulary verify-findings.sh uses); an
# operator-adjudicated reason (#2023); the most concrete `poc_sketch` (distinct identifier count, then length);
# input order. It is copied VERBATIM and, only when it absorbed at least one member, gains three keys:
#   duplicates      int, members - 1
#   also_classes    the distinct normalised classes of the OTHER members, own class excluded, C<n> sorted
#                   numerically (any non-C<n> class after them, lexically)
#   also_locations  the distinct member `location` strings that differ from its own, in input order
# A singleton entry is byte-identical to its raw copy.
#
# Subcommands:
#   cluster --in <raw.json> --out <clustered.json> [--threshold T] [--method v1|v2]
#       --method defaults to DEFAULT_METHOD (v2). Prints `CLUSTER|<raw_n>|<clusters>|<merged>` on stdout. When
#       merged == 0, --out is NOT written (the caller keeps the raw file, byte-identical to a run without
#       clustering). The clustered file keeps every other top-level key verbatim, sets totals.verified =
#       len(verified), adds totals.verified_precluster
#       (the finding-payability-gate.sh `verified_pregate` precedent, so candidates == verified_precluster +
#       errored + refuted + dropped_subfloor still holds) and a top-level `clustering` block:
#       {method, threshold, raw_file, raw_sha256, raw_verified, clusters, merged}; a v2 run adds
#       cannot_link = {line_window, defect_tau} after threshold.
#   raw-view --verified <verified_findings.json>
#       Prints the PRE-CLUSTER view on stdout. A file without a `clustering` key is echoed byte-for-byte. Else the
#       sibling raw file is read and its sha256 must equal clustering.raw_sha256 (a stale sibling never scores
#       silently); every clustered entry at index >= clustering.clusters (a later deep-hunt / vector-hunt append)
#       is appended to the raw list and totals.verified = len(verified).
#
# python3 stdlib only. Deterministic: the same input always yields byte-identical output.
# Exit: 0 ok; 2 usage error / bad threshold / bad method / input already clustered; 3 unreadable or malformed
#       input, or a raw sibling whose sha256 does not match.
import sys
import os
import re
import json
import hashlib

METHOD = "same-function identifier-jaccard average-linkage v1"
# Calibrated on dev data only (#2278 M1), over the candidate set {0.20, 0.25, 0.30}: 0.30 is the smallest value at
# which no distinct same-function pair of fixtures/cluster-findings/same-function-distinct.json merges (the
# OracleLess `fillOrder` reentrancy vs unallowlisted-target pair scores 0.286 on its own). On the in-repo dev runs it
# reproduces every hand-labelled root-cause count but one (2213 notional treatment keeps a 0.25 pair apart: 5 vs 4),
# which is the accepted under-merge direction. Pinned counts: fixtures/cluster-findings/expected-dev-counts.tsv.
DEFAULT_THRESHOLD = 0.30
RAW_FILE = "verified_findings.raw.json"

METHOD_V2 = "same-function identifier-jaccard average-linkage + cannot-link refinement v2"
METHODS = ("v1", "v2")
DEFAULT_METHOD = "v2"
# Both cannot-link constants come from dev labels only, by the fixed #2306 rule that
# bench/corpus-bench/cluster-calibrate.py applies and pins (fixtures/cluster-findings/calibration-v2.txt; the
# held-out oku fixture is not read). LINE_WINDOW = the largest line spread among dev labelled-same pairs that both
# cite a line: the real dev duplicates cite identical lines, the M1 synthetic `withdraw` pair cites :88/:90. A
# smaller window would split that labelled duplicate; a larger one gives up line evidence the dev data never needs.
LINE_WINDOW = 2
# DEFECT_TAU = the largest value of {0.0, 0.34, 0.5} whose clause veto fires on no dev labelled-same pair; when even
# 0.0 fires (it does: two paraphrases of the 1887 yieldoor `withdraw` copy-paste bug name token1 vs token0 in their
# clauses), the rule takes 0.0 and lists the vetoed dev pairs — distinctness ranks above compression. At 0.0 the
# clause veto fires only on DISJOINT defect clauses; any higher value would veto more labelled dev duplicates.
DEFECT_TAU = 0.0
# Pinned generic consequence syntax (not tuned): the defect clause ends at the first consequence connective.
DEFECT_BOUNDARY_RE = re.compile(
    r"\b(?:so|which|thereby|allowing|letting|enabling|causing|making|resulting|leading)\b"
    "|;| -- | \u2014 |->|\u2192|\\.\\s",
    re.IGNORECASE)
_LINE_RE = re.compile(r"\s*(\d+)")

SEV_RANK = {"low": 1, "medium": 2, "high": 3, "critical": 4}

# Pinned generic stoplist. Solidity primitive types (the digit-bearing ones would otherwise count as
# identifiers) plus calls and globals that appear in almost every exploit text regardless of the bug.
STOPLIST = {
    "address", "bool", "string", "bytes", "byte", "uint", "int", "mapping", "payable", "memory", "storage",
    "calldata", "call", "delegatecall", "staticcall", "transfer", "transferfrom", "approve", "balanceof",
    "require", "revert", "keccak256", "abi", "msg", "sender", "block", "timestamp",
}
for _n in range(8, 257, 8):
    STOPLIST.add("uint%d" % _n)
    STOPLIST.add("int%d" % _n)
for _n in range(1, 33):
    STOPLIST.add("bytes%d" % _n)
STOP_PREFIXES = ("safetransfer", "encode")

_TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_LOWER_UPPER_RE = re.compile(r"[a-z][A-Z]")
_CLASS_RE = re.compile(r"^C(\d+)$", re.IGNORECASE)


def die(rc, msg):
    sys.stderr.write("cluster-findings.py: " + msg + "\n")
    sys.exit(rc)


def block_key(entry):
    """(file, function) exactly as score-match.py:lead_location() splits `location`, lowercased; None when the
    entry must pass through unclustered."""
    if not isinstance(entry, dict) or "source" in entry:
        return None
    loc = str(entry.get("location") or "").strip()
    if not loc:
        return None
    parts = loc.split(":")
    file_part = parts[0].strip().lower()
    if not file_part or len(parts) < 2:
        return None
    fn = parts[1].strip()
    if not fn or fn.isdigit():
        return None
    return (file_part, fn.lower())


def raw_identifiers(text):
    """Distinct lowercased identifiers of a text (before any block-specific removal)."""
    text = str(text or "")
    out = set()
    for m in _TOKEN_RE.finditer(text):
        tok = m.group(0)
        end = m.end()
        called = end < len(text) and text[end] == "("
        if called or "_" in tok or any(c.isdigit() for c in tok) or _LOWER_UPPER_RE.search(tok):
            out.add(tok.lower())
    return out


def block_identifiers(ids, key):
    """Drop the block's own function name, the file's contract basename and the pinned STOPLIST from `ids`."""
    file_part, fn = key
    contract = os.path.splitext(os.path.basename(file_part))[0]
    return {t for t in ids
            if t != fn and t != contract and t not in STOPLIST and not t.startswith(STOP_PREFIXES)}


def exploit_identifiers(entry, key):
    return block_identifiers(raw_identifiers(entry.get("exploit")), key)


def location_line(entry):
    """The first leading integer of a `location` part after the function (`F.sol:fn:120` -> 120), else None."""
    for part in str(entry.get("location") or "").split(":")[2:]:
        m = _LINE_RE.match(part)
        if m:
            return int(m.group(1))
    return None


def defect_clause(text):
    """The exploit text before its first consequence connective (the whole text when there is none)."""
    text = str(text or "")
    m = DEFECT_BOUNDARY_RE.search(text)
    return text[:m.start()] if m else text


def defect_identifiers(entry, key):
    return block_identifiers(raw_identifiers(defect_clause(entry.get("exploit"))), key)


def cannot_link(la, lb, da, db, line_window, defect_tau):
    """(a) both cite a line and the lines are more than line_window apart, or (b) both defect clauses cite
    identifiers and those sets have Jaccard <= defect_tau."""
    if la is not None and lb is not None and abs(la - lb) > line_window:
        return True
    return bool(da) and bool(db) and jaccard(da, db) <= defect_tau


def jaccard(a, b):
    union = a | b
    if not union:
        return 0.0
    return len(a & b) / float(len(union))


def sev_rank(entry):
    s = str(entry.get("severity") or "").strip()
    s = s.replace("<", "").replace(">", "").strip()
    if s.lower().startswith("severity="):
        s = s[len("severity="):]
    return SEV_RANK.get(s.strip().lower(), 0)


def norm_class(raw):
    s = str(raw or "").strip().replace("<", "").replace(">", "").strip()
    if s.lower().startswith("class="):
        s = s[len("class="):].strip()
    m = _CLASS_RE.match(s)
    return ("C" + str(int(m.group(1)))) if m else s


def class_sort_key(c):
    m = _CLASS_RE.match(c)
    return (0, int(m.group(1)), "") if m else (1, 0, c)


def pick_representative(members, entries):
    def score(i):
        e = entries[i]
        adjudicated = str(e.get("reason") or "").startswith("operator-adjudicated")
        sketch = str(e.get("poc_sketch") or "")
        return (-sev_rank(e), 0 if adjudicated else 1, -len(raw_identifiers(sketch)), -len(sketch), i)
    return min(members, key=score)


def cluster_block(indices, idsets, threshold, forbid=None):
    """Average-linkage agglomeration over one block. Returns a list of sorted member-index lists. `forbid` (v2) is a
    set of cannot-linked (a, b) index pairs, both orders: a cluster pair holding one across it is never merged."""
    clusters = [[i] for i in indices]
    sim = {}
    for x in range(len(indices)):
        for y in range(x + 1, len(indices)):
            a, b = indices[x], indices[y]
            sim[(a, b)] = sim[(b, a)] = jaccard(idsets[a], idsets[b])
    while len(clusters) > 1:
        best, best_pair = None, None
        for x in range(len(clusters)):
            for y in range(x + 1, len(clusters)):
                if forbid and any((a, b) in forbid for a in clusters[x] for b in clusters[y]):
                    continue
                total = sum(sim[(a, b)] for a in clusters[x] for b in clusters[y])
                mean = total / float(len(clusters[x]) * len(clusters[y]))
                # Strictly greater keeps the FIRST pair in (lowest-member) order on a tie.
                if best is None or mean > best:
                    best, best_pair = mean, (x, y)
        if best is None or best < threshold:
            break
        x, y = best_pair
        clusters[x] = sorted(clusters[x] + clusters[y])
        del clusters[y]
        clusters.sort(key=lambda c: c[0])
    return clusters


def cannot_link_pairs(members, entries, line_window=None, defect_tau=None):
    """The set of cannot-linked (a, b) pairs (both orders) among `members`, all of one block. None -> the module
    constants (an in-process caller may pass line_window = float('inf'), defect_tau = -1 to disable both vetoes)."""
    window = LINE_WINDOW if line_window is None else line_window
    tau = DEFECT_TAU if defect_tau is None else defect_tau
    lines, clauses = {}, {}
    for i in members:
        lines[i] = location_line(entries[i])
        clauses[i] = defect_identifiers(entries[i], block_key(entries[i]))
    out = set()
    for x in range(len(members)):
        for y in range(x + 1, len(members)):
            a, b = members[x], members[y]
            if cannot_link(lines[a], lines[b], clauses[a], clauses[b], window, tau):
                out.add((a, b))
                out.add((b, a))
    return out


def cluster_entries(entries, threshold, method=DEFAULT_METHOD, line_window=None, defect_tau=None):
    """-> list of (representative index, sorted member indices), ordered by first member's raw index. v2 re-runs
    the same linkage over every multi-member v1 cluster with its cannot-linked pairs forbidden."""
    if method not in METHODS:
        raise ValueError("unknown clustering method: " + str(method))
    blocks = {}
    groups = []
    idsets = {}
    for i, e in enumerate(entries):
        key = block_key(e)
        if key is None:
            groups.append([i])
            continue
        idsets[i] = exploit_identifiers(e, key)
        blocks.setdefault(key, []).append(i)
    for key in blocks:
        for g in cluster_block(blocks[key], idsets, threshold):
            if method == "v1" or len(g) == 1:
                groups.append(g)
                continue
            forbid = cannot_link_pairs(g, entries, line_window, defect_tau)
            groups.extend(cluster_block(g, idsets, threshold, forbid) if forbid else [g])
    groups.sort(key=lambda g: g[0])
    return [(pick_representative(g, entries), g) for g in groups]


def build_entry(rep, members, entries):
    e = entries[rep]
    if len(members) == 1:
        return e
    out = dict(e)
    own_class = norm_class(e.get("class"))
    also_classes = sorted({norm_class(entries[m].get("class")) for m in members if m != rep}
                          - {own_class, ""}, key=class_sort_key)
    own_loc = e.get("location")
    also_locations = []
    for m in members:
        loc = entries[m].get("location")
        if m != rep and loc != own_loc and loc not in also_locations:
            also_locations.append(loc)
    out["duplicates"] = len(members) - 1
    out["also_classes"] = also_classes
    out["also_locations"] = also_locations
    return out


def load(path):
    try:
        with open(path, "rb") as fh:
            raw_bytes = fh.read()
        data = json.loads(raw_bytes.decode("utf-8"))
    except (OSError, ValueError, UnicodeDecodeError) as e:
        die(3, "cannot read " + path + ": " + str(e))
    if not isinstance(data, dict) or not isinstance(data.get("verified", []), list):
        die(3, path + ": missing/malformed top-level 'verified' array")
    return raw_bytes, data


def parse_threshold(raw):
    try:
        t = float(raw)
    except ValueError:
        die(2, "--threshold must be a decimal in (0,1] (got '" + raw + "')")
    if not (0.0 < t <= 1.0):
        die(2, "--threshold must be a decimal in (0,1] (got '" + raw + "')")
    return t


def cmd_cluster(args):
    src = dst = None
    threshold = DEFAULT_THRESHOLD
    method = DEFAULT_METHOD
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--in", "--out", "--threshold", "--method"):
            if i + 1 >= len(args):
                die(2, a + " requires a value")
            v = args[i + 1]
            if a == "--in":
                src = v
            elif a == "--out":
                dst = v
            elif a == "--method":
                if v not in METHODS:
                    die(2, "--method must be one of " + "|".join(METHODS) + " (got '" + v + "')")
                method = v
            else:
                threshold = parse_threshold(v)
            i += 2
        else:
            die(2, "unknown argument to cluster: " + a)
    if not src or not dst:
        die(2, "usage: cluster-findings.py cluster --in <raw.json> --out <clustered.json> [--threshold T] "
               "[--method v1|v2]")
    raw_bytes, data = load(src)
    if "clustering" in data:
        die(2, src + " is already clustered (top-level 'clustering' key); refusing to cluster it twice")
    entries = data.get("verified", [])
    groups = cluster_entries(entries, threshold, method)
    raw_n, n_clusters = len(entries), len(groups)
    merged = raw_n - n_clusters
    sys.stdout.write("CLUSTER|%d|%d|%d\n" % (raw_n, n_clusters, merged))
    if merged == 0:
        return 0
    out = {}
    for k, v in data.items():
        out[k] = [build_entry(rep, members, entries) for rep, members in groups] if k == "verified" else v
    totals = dict(out.get("totals") or {})
    totals["verified"] = n_clusters
    totals["verified_precluster"] = raw_n
    out["totals"] = totals
    info = {"method": METHOD if method == "v1" else METHOD_V2, "threshold": threshold}
    if method == "v2":
        info["cannot_link"] = {"line_window": LINE_WINDOW, "defect_tau": DEFECT_TAU}
    info.update({
        "raw_file": RAW_FILE,
        "raw_sha256": hashlib.sha256(raw_bytes).hexdigest(),
        "raw_verified": raw_n,
        "clusters": n_clusters,
        "merged": merged,
    })
    out["clustering"] = info
    try:
        with open(dst, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(out, indent=2) + "\n")
    except OSError as e:
        die(3, "cannot write " + dst + ": " + str(e))
    return 0


def cmd_raw_view(args):
    if len(args) != 2 or args[0] != "--verified":
        die(2, "usage: cluster-findings.py raw-view --verified <verified_findings.json>")
    path = args[1]
    raw_bytes, data = load(path)
    info = data.get("clustering")
    if info is None:
        sys.stdout.buffer.write(raw_bytes)
        return 0
    if not isinstance(info, dict) or not isinstance(info.get("clusters"), int):
        die(3, path + ": malformed 'clustering' block")
    sib = os.path.join(os.path.dirname(os.path.abspath(path)), os.path.basename(str(info.get("raw_file") or RAW_FILE)))
    sib_bytes, sib_data = load(sib)
    if hashlib.sha256(sib_bytes).hexdigest() != info.get("raw_sha256"):
        die(3, sib + ": sha256 does not match clustering.raw_sha256 in " + path
            + " — a stale pre-cluster sibling; refusing to present it as this run's raw view")
    appended = data.get("verified", [])[info["clusters"]:]
    out = {}
    for k, v in data.items():
        if k == "clustering":
            continue
        out[k] = (sib_data.get("verified", []) + appended) if k == "verified" else v
    totals = dict(out.get("totals") or {})
    totals.pop("verified_precluster", None)
    totals["verified"] = len(out.get("verified", []))
    out["totals"] = totals
    sys.stdout.write(json.dumps(out, indent=2) + "\n")
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stderr.write("usage: cluster-findings.py cluster --in <raw.json> --out <clustered.json> [--threshold T] "
                         "[--method v1|v2]\n"
                         "       cluster-findings.py raw-view --verified <verified_findings.json>\n")
        return 2 if len(argv) < 2 else 0
    if argv[1] == "cluster":
        return cmd_cluster(argv[2:])
    if argv[1] == "raw-view":
        return cmd_raw_view(argv[2:])
    die(2, "unknown subcommand: " + argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
