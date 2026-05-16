#!/usr/bin/env python3
"""test-fetch-papers.py -- Python unittest harness for fetch-papers.py
(#592).

Validates the JSON output structure with synthetic arxiv responses
injected via a fake arxiv module placed on sys.modules. No network,
no `arxiv` install required.

Run: python3 math-foundry/tools/test-fetch-papers.py
"""

import json
import os
import sys
import tempfile
import types
import unittest

HERE = os.path.abspath(os.path.dirname(__file__))


def _install_fake_arxiv(papers_by_query):
    """Install a minimal fake `arxiv` module mapping query -> [papers].

    Each paper is a dict {id, title, abstract}.
    """
    fake = types.ModuleType("arxiv")

    class _Result:
        def __init__(self, paper_id, title, abstract):
            self.entry_id = paper_id
            self.title = title
            self.summary = abstract

        def get_short_id(self):
            return self.entry_id

    class _Search:
        def __init__(self, query=None, max_results=None,
                     sort_by=None, sort_order=None):
            self.query = query
            self.max_results = max_results

    class _Client:
        def __init__(self, page_size=None, delay_seconds=None, num_retries=None):
            self.delay_seconds = delay_seconds

        def results(self, search):
            items = papers_by_query.get(search.query, [])
            for paper in items[: (search.max_results or len(items))]:
                yield _Result(paper["id"], paper["title"], paper["abstract"])

    class _SortCriterion:
        SubmittedDate = "submitted_date"

    class _SortOrder:
        Descending = "desc"

    fake.Search = _Search
    fake.Client = _Client
    fake.SortCriterion = _SortCriterion
    fake.SortOrder = _SortOrder
    sys.modules["arxiv"] = fake


def _import_fetch_papers():
    if "fetch_papers" in sys.modules:
        del sys.modules["fetch_papers"]
    # Load fetch-papers.py as a module via importlib. The source file
    # name has a dash so we can't `import fetch-papers` directly.
    import importlib.util
    src = os.path.join(HERE, "fetch-papers.py")
    spec = importlib.util.spec_from_file_location("fetch_papers", src)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FetchPapersTests(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="foundry-fetch-")
        os.environ["FOUNDRY_FETCH_NO_SLEEP"] = "1"

    def tearDown(self):
        # cleanup tmpdir contents
        for root, dirs, files in os.walk(self.tmpdir, topdown=False):
            for name in files:
                os.unlink(os.path.join(root, name))
            for name in dirs:
                os.rmdir(os.path.join(root, name))
        os.rmdir(self.tmpdir)

    def test_emits_topic_json_with_required_keys(self):
        _install_fake_arxiv({
            "cat:math.NT": [
                {"id": "2401.00001v1", "title": "Test A",
                 "abstract": "Abstract A."},
                {"id": "2401.00002v2", "title": "Test B",
                 "abstract": "Abstract B."},
            ],
        })
        fetch_papers = _import_fetch_papers()
        rc = fetch_papers.main([
            "--output", self.tmpdir,
            "--topics", "number_theory",
            "--per-topic", "2",
        ])
        self.assertEqual(rc, 0)
        out_path = os.path.join(self.tmpdir, "number_theory.json")
        self.assertTrue(os.path.isfile(out_path))
        with open(out_path) as f:
            data = json.load(f)
        for key in ("topic", "description", "compute_hints", "papers"):
            self.assertIn(key, data, msg="missing key: " + key)
        self.assertEqual(data["topic"], "number_theory")
        self.assertEqual(len(data["papers"]), 2)
        for paper in data["papers"]:
            for field in ("id", "title", "abstract"):
                self.assertIn(field, paper)

    def test_strips_version_suffix_from_paper_id(self):
        _install_fake_arxiv({
            "cat:math.NT": [
                {"id": "2401.12345v7", "title": "Test",
                 "abstract": "Abstract."},
                {"id": "2402.99999v1", "title": "Test2",
                 "abstract": "Abstract2."},
            ],
        })
        fetch_papers = _import_fetch_papers()
        rc = fetch_papers.main([
            "--output", self.tmpdir,
            "--topics", "number_theory",
            "--per-topic", "2",
        ])
        self.assertEqual(rc, 0)
        with open(os.path.join(self.tmpdir, "number_theory.json")) as f:
            data = json.load(f)
        ids = sorted(p["id"] for p in data["papers"])
        self.assertEqual(ids, ["2401.12345", "2402.99999"])

    def test_rejects_per_topic_below_two(self):
        fetch_papers = _import_fetch_papers()
        with self.assertRaises(SystemExit) as cm:
            fetch_papers.main([
                "--output", self.tmpdir,
                "--topics", "number_theory",
                "--per-topic", "1",
            ])
        self.assertEqual(cm.exception.code, 2)

    def test_rejects_unknown_topic_without_override(self):
        fetch_papers = _import_fetch_papers()
        with self.assertRaises(SystemExit) as cm:
            fetch_papers.main([
                "--output", self.tmpdir,
                "--topics", "not_a_real_topic",
                "--per-topic", "5",
            ])
        self.assertEqual(cm.exception.code, 2)

    def test_query_overrides_redirect_search(self):
        _install_fake_arxiv({
            "my:custom:query": [
                {"id": "9999.00001", "title": "Override hit",
                 "abstract": "From override."},
                {"id": "9999.00002", "title": "Override hit 2",
                 "abstract": "Also from override."},
            ],
        })
        overrides_path = os.path.join(self.tmpdir, "overrides.json")
        with open(overrides_path, "w") as f:
            json.dump({"number_theory": "my:custom:query"}, f)
        fetch_papers = _import_fetch_papers()
        rc = fetch_papers.main([
            "--output", self.tmpdir,
            "--topics", "number_theory",
            "--per-topic", "2",
            "--query-overrides", overrides_path,
        ])
        self.assertEqual(rc, 0)
        with open(os.path.join(self.tmpdir, "number_theory.json")) as f:
            data = json.load(f)
        ids = sorted(p["id"] for p in data["papers"])
        self.assertEqual(ids, ["9999.00001", "9999.00002"])

    def test_exit_code_when_no_papers_returned(self):
        _install_fake_arxiv({"cat:math.NT": []})
        fetch_papers = _import_fetch_papers()
        with self.assertRaises(SystemExit) as cm:
            fetch_papers.main([
                "--output", self.tmpdir,
                "--topics", "number_theory",
                "--per-topic", "5",
            ])
        self.assertEqual(cm.exception.code, 4)


if __name__ == "__main__":
    unittest.main()
