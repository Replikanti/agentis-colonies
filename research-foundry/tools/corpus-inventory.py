#!/usr/bin/env python3
"""corpus-inventory.py -- classify the cached arxiv paper corpus through
the same 5-bucket heuristic that novelty.ag's ``_classify_bucket`` uses
for loss-shaping (#765).

Purpose: confirm or refute the hypothesis (issue #768) that the runtime
sym_n-attractor bias originates from the LLM prior rather than the seed
corpus. The novelty loss-shaping path only fires when ``_classify_bucket``
returns a non-empty label, so any abstract that the keyword heuristic
fails to match silently exits the shaping logic.

Reads every ``<topic>.json`` under ``research-foundry/data/papers/``,
applies the classifier to ``title + " " + abstract`` (mirroring the
``index_of`` semantics of the .ag helper), and emits a histogram + a
per-paper breakdown. Use ``--json`` for CI consumption.

Classifier parity contract: this script must remain byte-identical to
novelty.ag::_classify_bucket. Five buckets, substring-match, priority
order ``group_theory > combinatorics > number_theory > probability >
algebra``, empty string when no bucket matches.

Usage:
    corpus-inventory.py [--papers-dir PATH] [--json]

Exit codes:
    0  success
    2  bad CLI args
    3  papers dir missing or empty
"""

import argparse
import json
import os
import sys
from collections import Counter
from glob import glob

# Mirror of novelty.ag::_classify_bucket (research-foundry/novelty/agents/
# novelty.ag L436). Priority order is load-bearing: the first match wins,
# so any reshuffle here will diverge from the runtime classifier.
BUCKETS = [
    "group_theory",
    "combinatorics",
    "number_theory",
    "probability",
    "algebra",
]

# Per-bucket keyword vocabulary (#768 PR-2). The literal bucket name is
# the first entry so any pre-PR-2 substring match still wins. Vocabulary
# is case-insensitive (haystack is lowercased once at classify time); all
# keywords are already lowercase. Must stay byte-for-byte synchronised
# with novelty.ag::_classify_bucket and explorer.ag::_classify_bucket_explorer
# -- test-run-research.sh block 39 cross-greps each (bucket, sample keyword)
# pair across all three sites.
BUCKET_KEYWORDS = {
    "group_theory": [
        "group_theory", "sylow", "cayley", "monoid", "semigroup",
        "permutation", "symmetric_group", "sym_n", "schur", "lattice",
        "coset", "conjugacy", "abelian", "nilpotent", "solvable",
        "simple group", "presentation", "free group",
    ],
    "combinatorics": [
        "combinatorics", "hamiltonicity", "hamilton cycle", "latin square",
        "hypergraph", "catalan", "partition", "generating function",
        "matroid", "turan", "ramsey", "enumeration", "bijection",
        "set system", "design theory",
        "graph", "chromatic", "planar", "coloring", "colouring",
        "clique", "matching", "bipartite", "domination", "spanning tree",
        "tournament", "vertex", "minor",
    ],
    "number_theory": [
        "number_theory", "hecke", "l-function", "zeta", "modular form",
        "diophantine", "frobenius", "p-adic", "elliptic curve", "galois",
        "class field", "automorphic", "prime", "sieve", "riemann",
    ],
    "probability": [
        "probability", "martingale", "random walk", "mixing time",
        "stationary distribution", "markov chain", "percolation",
        "branching process", "brownian", "stochastic", "renyi", "entropy",
    ],
    "algebra": [
        "algebra", "cohomology", "sheaf", "ring spectrum", "module",
        "derived category", "witt", "lie algebra", "hopf", "tensor",
        "homotopy", "scheme", "variety", "ideal", "polynomial ring",
    ],
}


def classify_bucket(text):
    """Return the first bucket with a keyword hit in ``text``, or ``""``.

    Priority order follows ``BUCKETS``. Case-insensitive: the haystack is
    lowercased once before scanning, and ``BUCKET_KEYWORDS`` is already
    lowercase. Mirrors novelty.ag::_classify_bucket post-#768 PR-2.
    """
    if not text:
        return ""
    haystack = text.lower()
    for bucket in BUCKETS:
        for kw in BUCKET_KEYWORDS[bucket]:
            if kw in haystack:
                return bucket
    return ""


def classify_buckets_all(text):
    """Return a list of every bucket with at least one keyword hit, in
    priority order. Mirrors novelty.ag::_classify_buckets_all post-#768
    PR-2 (observational multi-bucket tag stream, not consumed by the
    inventory itself but used by sibling tooling)."""
    if not text:
        return []
    haystack = text.lower()
    hits = []
    for bucket in BUCKETS:
        for kw in BUCKET_KEYWORDS[bucket]:
            if kw in haystack:
                hits.append(bucket)
                break
    return hits


def load_corpus(papers_dir):
    """Yield ``(file_topic, paper_id, title, abstract)`` from every JSON."""
    files = sorted(glob(os.path.join(papers_dir, "*.json")))
    if not files:
        return []
    rows = []
    for fp in files:
        with open(fp) as f:
            data = json.load(f)
        file_topic = data.get("topic", os.path.basename(fp).removesuffix(".json"))
        for paper in data.get("papers", []):
            rows.append((
                file_topic,
                paper.get("id", ""),
                paper.get("title", ""),
                paper.get("abstract", ""),
            ))
    return rows


def build_inventory(rows):
    """Classify every paper and return a dict-shaped report."""
    per_paper = []
    bucket_counts = Counter()
    for file_topic, pid, title, abstract in rows:
        haystack = title + " " + abstract
        bucket = classify_bucket(haystack)
        per_paper.append({
            "id": pid,
            "title": title,
            "source_file_topic": file_topic,
            "bucket": bucket or "unclassified",
        })
        bucket_counts[bucket or "unclassified"] += 1
    total = len(per_paper)
    return {
        "total": total,
        "buckets": {b: bucket_counts.get(b, 0) for b in BUCKETS},
        "unclassified": bucket_counts.get("unclassified", 0),
        "per_paper": per_paper,
    }


def render_text(papers_dir, report):
    """Stdout-friendly histogram + table, matching the format documented
    in the issue plan."""
    total = report["total"]
    lines = []
    lines.append("Corpus inventory for " + papers_dir)
    lines.append("=" * 60)
    lines.append("Total papers: " + str(total))
    lines.append("By bucket:")
    classified_total = 0
    for bucket in BUCKETS:
        count = report["buckets"][bucket]
        classified_total += count
        pct = (100.0 * count / total) if total else 0.0
        lines.append("  {0:18}{1:>4} ({2:5.1f}%)".format(bucket, count, pct))
    unclassified = report["unclassified"]
    unclassified_pct = (100.0 * unclassified / total) if total else 0.0
    lines.append("  {0:18}{1:>4} ({2:5.1f}%)".format(
        "unclassified", unclassified, unclassified_pct))
    lines.append("")
    lines.append("Per-paper breakdown:")
    for entry in report["per_paper"]:
        title = entry["title"]
        title_trunc = title if len(title) <= 60 else title[:57] + "..."
        lines.append("  {0:14}  {1:14}  {2}".format(
            entry["id"], entry["bucket"], title_trunc))
    lines.append("")
    if total > 0:
        match_pct = 100.0 * classified_total / total
        unclassified_pct = 100.0 * report["unclassified"] / total
        lines.append(
            "Classifier matches {0}/{1} papers ({2:.1f}%); {3} unclassified ({4:.1f}%).".format(
                classified_total, total, match_pct,
                report["unclassified"], unclassified_pct))
        if unclassified_pct >= 30.0:
            lines.append(
                "WARNING: unclassified >= 30% -- expand bucket keyword"
                " vocabulary or hand-tag via --token-set.")
    return "\n".join(lines)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    here = os.path.abspath(os.path.dirname(__file__))
    default_dir = os.path.normpath(os.path.join(here, "..", "data", "papers"))
    parser.add_argument(
        "--papers-dir",
        default=default_dir,
        help="path to data/papers/ (default: %(default)s)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit the full report as a JSON document on stdout (CI-friendly)",
    )
    args = parser.parse_args(argv)

    if not os.path.isdir(args.papers_dir):
        print("corpus-inventory: papers dir not found: " + args.papers_dir,
              file=sys.stderr)
        return 3
    rows = load_corpus(args.papers_dir)
    if not rows:
        print("corpus-inventory: no papers found under " + args.papers_dir,
              file=sys.stderr)
        return 3
    report = build_inventory(rows)
    if args.json:
        report["papers_dir"] = args.papers_dir
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(render_text(args.papers_dir, report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
