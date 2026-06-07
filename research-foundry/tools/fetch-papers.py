#!/usr/bin/env python3
"""fetch-papers.py -- one-time bootstrap helper to populate the cached
arxiv paper corpus consumed by `tools/run-foundry.sh` (#592).

Live arxiv calls are rate-limited and would add latency to every
foundry tick, so the orchestrator never hits arxiv at runtime. This
script populates `research-foundry/data/papers/<topic>.json` once; the
orchestrator then serves from disk.

The script uses the `arxiv` Python package (install via pip). If the
package is not installed we exit with a clear error instead of
silently degrading.

Schema of each emitted `<topic>.json`:

    {
        "topic": "...",
        "description": "...",
        "compute_hints": "...",
        "papers": [{"id": "...", "title": "...", "abstract": "..."}, ...]
    }

Usage:
    fetch-papers.py --output PATH --topics <name> [<name> ...] \\
                    [--per-topic N] [--query-overrides FILE]

Exit codes:
    0  success
    2  bad CLI args
    3  arxiv package not installed
    4  no papers returned for a topic
"""

import argparse
import json
import os
import sys
import time

TOPIC_DEFAULTS = {
    "number_theory": {
        "description": "Distribution of primes, additive combinatorics, "
                       "Diophantine equations, modular forms, L-functions.",
        "compute_hints": "sympy (isprime, factorint, nextprime, gcd, "
                         "totient), math.gcd, fractions.Fraction.",
        "query": "cat:math.NT",
    },
    "combinatorics": {
        "description": "Enumeration, generating functions, partitions, "
                       "Ramsey theory, additive combinatorics.",
        "compute_hints": "sympy (binomial, partition, fibonacci), "
                         "itertools, fractions.Fraction.",
        "query": "cat:math.CO",
    },
    "abstract_algebra": {
        "description": "Groups, rings, fields, Galois theory, "
                       "representation theory.",
        "compute_hints": "sympy.polys (Poly, GF, factor, ...), "
                         "sympy.combinatorics (PermutationGroup, ...).",
        "query": "cat:math.AC OR cat:math.RA OR cat:math.GR",
    },
    "graph_theory": {
        "description": "Spectral graph theory, extremal graph theory, "
                       "random graphs, graph minors.",
        "compute_hints": "networkx (degree, eigenvalues, "
                         "connected_components, ...).",
        "query": "cat:math.CO AND abs:graph",
    },
}


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", required=True,
        help="Output directory for <topic>.json files",
    )
    parser.add_argument(
        "--topics", nargs="+", required=True,
        help="One or more topic names (e.g. number_theory combinatorics)",
    )
    parser.add_argument(
        "--per-topic", type=int, default=25,
        help="Number of papers to fetch per topic (default: 25)",
    )
    parser.add_argument(
        "--query-overrides", default=None,
        help="Path to a JSON file of {topic: query} overrides",
    )
    return parser.parse_args(argv)


def load_overrides(path):
    if not path:
        return {}
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        sys.stderr.write("--query-overrides file must be a JSON object\n")
        sys.exit(2)
    return data


def fetch_one_topic(topic, query, per_topic):
    # Try `arxiv` package first (faster, retries, rate-limit aware). Fall back
    # to stdlib urllib + ElementTree if not installed — operator may not have
    # pip available (#956). Both paths return the same paper dicts.
    try:
        results = _fetch_via_arxiv_pkg(query, per_topic)
    except ImportError:
        results = _fetch_via_stdlib(topic, query, per_topic)
    if not results:
        sys.stderr.write(
            "fetch-papers: no papers returned for topic '" + topic
            + "' (query='" + query + "')\n"
        )
        sys.exit(4)
    return results


def _fetch_via_arxiv_pkg(query, per_topic):
    import arxiv  # type: ignore[import-not-found]

    search = arxiv.Search(
        query=query,
        max_results=per_topic,
        sort_by=arxiv.SortCriterion.SubmittedDate,
        sort_order=arxiv.SortOrder.Descending,
    )
    results = []
    # arxiv recommends a 3s delay between requests; the Client class
    # handles this internally for paginated fetches.
    client = arxiv.Client(page_size=100, delay_seconds=3.0, num_retries=3)
    for result in client.results(search):
        # arxiv ids look like "2401.12345v2"; we strip the version
        # suffix so the foundry ledger entries remain stable.
        raw_id = result.get_short_id() if hasattr(result, "get_short_id") else result.entry_id
        paper_id = raw_id.split("v")[0] if isinstance(raw_id, str) else str(raw_id)
        results.append({
            "id": paper_id,
            "title": (result.title or "").strip().replace("\n", " "),
            "abstract": (result.summary or "").strip().replace("\n", " "),
        })
    return results


def _fetch_via_stdlib(topic, query, per_topic):
    # Stdlib-only fallback: hit the arxiv export API directly + parse atom XML.
    # Mirrors the `arxiv` package's default sort (SubmittedDate, descending)
    # so the returned set is the same most-recent papers per topic.
    import urllib.parse
    import urllib.request
    import xml.etree.ElementTree as ET

    base = "http://export.arxiv.org/api/query"
    params = urllib.parse.urlencode({
        "search_query": query,
        "max_results": per_topic,
        "sortBy": "submittedDate",
        "sortOrder": "descending",
    })
    url = base + "?" + params
    req = urllib.request.Request(url, headers={"User-Agent": "research-foundry/fetch-papers (stdlib)"})
    # arxiv asks for >=3s spacing; we're firing per-topic sequentially with
    # a top-level sleep between topics, so a single request per topic stays
    # well under the rate limit.
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read()

    # arxiv atom feed namespaces
    ns = {"atom": "http://www.w3.org/2005/Atom"}
    root = ET.fromstring(body)
    results = []
    for entry in root.findall("atom:entry", ns):
        id_el = entry.find("atom:id", ns)
        title_el = entry.find("atom:title", ns)
        summary_el = entry.find("atom:summary", ns)
        raw_id = (id_el.text or "").strip() if id_el is not None else ""
        # http://arxiv.org/abs/2401.12345v2 -> 2401.12345
        paper_id = raw_id.rsplit("/", 1)[-1].split("v")[0] if raw_id else ""
        title = (title_el.text or "").strip().replace("\n", " ") if title_el is not None else ""
        abstract = (summary_el.text or "").strip().replace("\n", " ") if summary_el is not None else ""
        if paper_id:
            results.append({"id": paper_id, "title": title, "abstract": abstract})
    return results


def write_topic_file(output_dir, topic, description, compute_hints, papers):
    payload = {
        "topic": topic,
        "description": description,
        "compute_hints": compute_hints,
        "papers": papers,
    }
    path = os.path.join(output_dir, topic + ".json")
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")
    return path


def main(argv):
    args = parse_args(argv)
    if args.per_topic < 2:
        sys.stderr.write("--per-topic must be >= 2\n")
        sys.exit(2)
    if not os.path.isdir(args.output):
        os.makedirs(args.output, exist_ok=True)
    overrides = load_overrides(args.query_overrides)

    for topic in args.topics:
        defaults = TOPIC_DEFAULTS.get(topic)
        if defaults is None:
            sys.stderr.write(
                "fetch-papers: no defaults for topic '" + topic
                + "'; supply a --query-overrides file to provide a query.\n"
            )
            sys.exit(2)
        query = overrides.get(topic, defaults["query"])
        sys.stderr.write(
            "fetch-papers: topic='" + topic + "' query='" + query
            + "' per_topic=" + str(args.per_topic) + "\n"
        )
        papers = fetch_one_topic(topic, query, args.per_topic)
        path = write_topic_file(
            args.output, topic,
            defaults["description"], defaults["compute_hints"],
            papers,
        )
        sys.stderr.write(
            "fetch-papers: wrote " + str(len(papers)) + " papers to "
            + path + "\n"
        )
        # Be polite between topics even though the Client class already
        # delays between paginated requests within one topic. Tests
        # bypass via FOUNDRY_FETCH_NO_SLEEP=1.
        if not os.environ.get("FOUNDRY_FETCH_NO_SLEEP"):
            time.sleep(3.0)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
