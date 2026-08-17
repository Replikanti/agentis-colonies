#!/usr/bin/env python3
# test-write-ab-manifest.py -- unit tests for write-ab-manifest.py
# (#1947).
#
# 6 unittest cases covering the manifest writer's contract with
# run-ab-experiment.sh:
#   1. A two-record NUL stream round-trips into `runs[]` in stream order
#      with the exact key names + value types analyze-ab-results.py reads.
#   2. A run_dir containing a space survives intact (the reason the
#      record stream is NUL-separated rather than newline-separated).
#   3. Empty stdin yields `runs: []`, exit 0, metadata header intact.
#   4. A stream whose element count is not a multiple of 5 exits 1 with
#      `malformed RUNS_RECORD stream` on stderr and writes nothing.
#   5. An out_path whose parent dir does not exist is created.
#   6. The argv -> header mapping and the fixed `arms` block (control 999
#      / treatment 3) are pinned in order -- this is the contract the
#      harness call site must keep.
#
# The writer's surface IS its stdin/argv/exit-code behaviour, so every
# case drives it through subprocess rather than importing it.
#
# Stdlib only -- no pytest, no live LLM, no podman.
#
# Usage: python3 trading-binance/tools/test-write-ab-manifest.py

import json
import os
import subprocess
import sys
import tempfile
import unittest


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
WRITER = os.path.join(SCRIPT_DIR, "write-ab-manifest.py")

TS = "20260101T000000Z"
# argv 2..9 as run-ab-experiment.sh passes them.
HEADER_ARGV = [TS, "BTCUSDT", "1h", "2026-01-01", "2026-01-31", "720", "2", "opus-4.8"]


def record(arm, run_idx, run_dir, threshold, exit_code):
    """One flattened 5-tuple, NUL-separated and NUL-terminated."""
    fields = [arm, str(run_idx), run_dir, str(threshold), str(exit_code)]
    return b"".join(f.encode("utf-8") + b"\x00" for f in fields)


def run_writer(out_path, stdin_bytes, header_argv=None):
    """Invoke the writer; return (returncode, stderr_text)."""
    argv = [sys.executable, WRITER, out_path] + list(header_argv or HEADER_ARGV)
    proc = subprocess.run(
        argv,
        input=stdin_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return proc.returncode, proc.stderr.decode("utf-8", "replace")


class WriteAbManifestTest(unittest.TestCase):

    def test_1_two_records_round_trip(self):
        """(a) Both records land in `runs[]`, in stream order, typed."""
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "experiment-manifest.json")
            stream = (
                record("control", 1, "/exp/ab-trading-" + TS + "-control-run-1", 999, 0)
                + record("treatment", 2, "/exp/ab-trading-" + TS + "-treatment-run-2", 3, 7)
            )
            rc, err = run_writer(out, stream)
            self.assertEqual(0, rc, err)
            with open(out, "r", encoding="utf-8") as f:
                manifest = json.load(f)
            self.assertEqual(2, len(manifest["runs"]))
            first, second = manifest["runs"]
            self.assertEqual("control", first["arm"])
            self.assertEqual(1, first["run_idx"])
            self.assertEqual(
                "/exp/ab-trading-" + TS + "-control-run-1", first["run_dir"])
            self.assertEqual(
                999, first["strategist_prompt_evolution_threshold"])
            self.assertEqual(0, first["exit_code"])
            self.assertEqual("treatment", second["arm"])
            self.assertEqual(2, second["run_idx"])
            self.assertEqual(
                "/exp/ab-trading-" + TS + "-treatment-run-2", second["run_dir"])
            self.assertEqual(3, second["strategist_prompt_evolution_threshold"])
            self.assertEqual(7, second["exit_code"])
            # Types, not just values: the analyser formats these directly.
            self.assertIsInstance(first["run_idx"], int)
            self.assertIsInstance(
                first["strategist_prompt_evolution_threshold"], int)
            self.assertIsInstance(first["exit_code"], int)
            self.assertIsInstance(first["run_dir"], str)

    def test_2_run_dir_with_space_survives(self):
        """(b) NUL separation keeps a spaced run_dir in one piece."""
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "experiment-manifest.json")
            spaced = "/exp dir/ab-trading-" + TS + "-control-run-1"
            rc, err = run_writer(out, record("control", 1, spaced, 999, 0))
            self.assertEqual(0, rc, err)
            with open(out, "r", encoding="utf-8") as f:
                manifest = json.load(f)
            self.assertEqual(1, len(manifest["runs"]))
            self.assertEqual(spaced, manifest["runs"][0]["run_dir"])

    def test_3_empty_stdin_is_legal(self):
        """(c) Zero records -> `runs: []`, exit 0, header still written."""
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "experiment-manifest.json")
            rc, err = run_writer(out, b"")
            self.assertEqual(0, rc, err)
            with open(out, "r", encoding="utf-8") as f:
                manifest = json.load(f)
            self.assertEqual([], manifest["runs"])
            self.assertEqual(TS, manifest["experiment_ts"])
            self.assertEqual("BTCUSDT", manifest["symbol"])

    def test_4_malformed_stream_exits_1(self):
        """(d) Element count not a multiple of 5 -> exit 1, no output."""
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "experiment-manifest.json")
            truncated = b"control\x001\x00/exp/run-1\x00"
            rc, err = run_writer(out, truncated)
            self.assertEqual(1, rc)
            self.assertIn("malformed RUNS_RECORD stream", err)
            self.assertFalse(os.path.exists(out))

    def test_5_missing_parent_dir_is_created(self):
        """(e) The writer creates the manifest's parent directory."""
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "runs", "ab-trading-" + TS,
                               "experiment-manifest.json")
            rc, err = run_writer(out, record("control", 1, "/exp/run-1", 999, 0))
            self.assertEqual(0, rc, err)
            self.assertTrue(os.path.isfile(out))

    def test_6_argv_header_and_arms_block(self):
        """(f) argv order -> header keys, plus the fixed arms block."""
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "experiment-manifest.json")
            rc, err = run_writer(out, b"")
            self.assertEqual(0, rc, err)
            with open(out, "r", encoding="utf-8") as f:
                manifest = json.load(f)
            self.assertEqual(TS, manifest["experiment_ts"])
            self.assertEqual("BTCUSDT", manifest["symbol"])
            self.assertEqual("1h", manifest["timeframe"])
            self.assertEqual("2026-01-01", manifest["start"])
            self.assertEqual("2026-01-31", manifest["end"])
            self.assertEqual(720, manifest["replay_speed"])
            self.assertEqual(2, manifest["n_replicates_per_arm"])
            self.assertEqual("opus-4.8", manifest["llm_model"])
            self.assertIsInstance(manifest["replay_speed"], int)
            self.assertIsInstance(manifest["n_replicates_per_arm"], int)
            self.assertEqual(
                999,
                manifest["arms"]["control"]["strategist_prompt_evolution_threshold"])
            self.assertEqual(
                3,
                manifest["arms"]["treatment"]["strategist_prompt_evolution_threshold"])
            self.assertIn("baseline", manifest["arms"]["control"]["description"])
            self.assertIn("emergence", manifest["arms"]["treatment"]["description"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
