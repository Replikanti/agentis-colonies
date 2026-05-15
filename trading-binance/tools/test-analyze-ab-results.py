#!/usr/bin/env python3
# test-analyze-ab-results.py -- unit tests for analyze-ab-results.py
# (#573 PR-5).
#
# 6 unittest cases covering:
#   1. PnL bps aggregation matches a hand-computed total.
#   2. Win rate excludes FLAT.
#   3. Max drawdown is chronological regardless of input file order.
#   4. Mutation rate is 0 on control fixture, N on treatment fixture
#      with N rewrite rows.
#   5. Missing .agentis/experience/ directory yields a zero-trade row,
#      no crash.
#   6. comparison.md is written with the run -> arm header table.
#
# All cases build hermetic fixtures under tempfile.TemporaryDirectory().
# Stdlib only.

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
import importlib.util

_spec = importlib.util.spec_from_file_location(
    "analyze_ab_results",
    os.path.join(SCRIPT_DIR, "analyze-ab-results.py"),
)
analyzer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(analyzer)


TS = "20260101T000000Z"


def _write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")


def _settle_row(tribe, classification, pnl_bps, ts):
    """Build a settle learn() row matching strategist.ag's emit shape."""
    return {
        "topic": "settle",
        "summary": "tick X " + classification,
        "details": "pnl_bps=" + str(pnl_bps),
        "outcome": "success",
        "tags": ["acted", "trading-binance", tribe, "classification:" + classification],
        "ts": ts,
    }


def _rewrite_row(tribe, gen, ts):
    """Build a `strategist_prompt_evolve` rewrite row."""
    return {
        "topic": "strategist_prompt_evolve",
        "summary": "rewrite",
        "details": "gen=" + str(gen),
        "outcome": "success",
        "tags": ["prompt-evolution", "rewritten", "trading-binance", tribe],
        "ts": ts,
    }


def _memo_row(key, value):
    return {"key": key, "value": value}


def _build_run_dir(exp_dir, ts, arm, run_idx):
    """Create the on-disk skeleton for one run, returns the run_dir
    path. Caller fills .agentis/experience/ + .agentis/memo*.jsonl."""
    name = "ab-trading-" + ts + "-" + arm + "-run-" + str(run_idx)
    run_dir = os.path.join(exp_dir, name)
    os.makedirs(os.path.join(run_dir, "laptop-node", ".agentis", "experience"), exist_ok=True)
    return run_dir


def _write_manifest(exp_dir, ts, runs):
    """runs: list of (arm, run_idx, run_dir, threshold, exit_code)"""
    manifest = {
        "experiment_ts": ts,
        "symbol": "BTCUSDT",
        "timeframe": "1h",
        "start": "2026-01-01",
        "end": "2026-03-31",
        "replay_speed": 720,
        "n_replicates_per_arm": max(r[1] for r in runs) if runs else 0,
        "llm_model": "qwen/qwen3-coder-30b-a3b-instruct",
        "arms": {
            "control": {"strategist_prompt_evolution_threshold": 999, "description": "off"},
            "treatment": {"strategist_prompt_evolution_threshold": 3, "description": "on"},
        },
        "runs": [
            {
                "arm": arm,
                "run_idx": run_idx,
                "run_dir": run_dir,
                "strategist_prompt_evolution_threshold": threshold,
                "exit_code": exit_code,
            }
            for (arm, run_idx, run_dir, threshold, exit_code) in runs
        ],
    }
    with open(os.path.join(exp_dir, "experiment-manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)


class PnlAggregationTest(unittest.TestCase):
    """Test 1 -- PnL bps aggregation matches hand-computed total."""

    def test_pnl_total_matches_hand_computed(self):
        with tempfile.TemporaryDirectory() as tmp:
            exp_dir = os.path.join(tmp, "ab-trading-" + TS)
            run_dir = _build_run_dir(exp_dir, TS, "control", 1)
            exp_jsonl = os.path.join(run_dir, "laptop-node", ".agentis", "experience", "1.jsonl")
            rows = [
                _settle_row("tribe-alpha", "WIN", 25.0, 1000),
                _settle_row("tribe-alpha", "LOSS", -15.0, 2000),
                _settle_row("tribe-alpha", "WIN", 40.0, 3000),
                # different tribe, not counted for alpha
                _settle_row("tribe-beta", "WIN", 100.0, 1500),
            ]
            _write_jsonl(exp_jsonl, rows)
            m = analyzer.compute_run_tribe_metrics(run_dir, "tribe-alpha")
            self.assertEqual(m["total_trades"], 3)
            self.assertAlmostEqual(m["pnl_bps_total"], 50.0, places=6)
            # tribe-beta isolated correctly
            mb = analyzer.compute_run_tribe_metrics(run_dir, "tribe-beta")
            self.assertEqual(mb["total_trades"], 1)
            self.assertAlmostEqual(mb["pnl_bps_total"], 100.0, places=6)


class WinRateExcludesFlatTest(unittest.TestCase):
    """Test 2 -- win rate denominator excludes FLAT rows."""

    def test_win_rate_excludes_flat(self):
        with tempfile.TemporaryDirectory() as tmp:
            exp_dir = os.path.join(tmp, "ab-trading-" + TS)
            run_dir = _build_run_dir(exp_dir, TS, "control", 1)
            exp_jsonl = os.path.join(run_dir, "laptop-node", ".agentis", "experience", "1.jsonl")
            rows = [
                _settle_row("tribe-alpha", "WIN", 10.0, 1000),
                _settle_row("tribe-alpha", "LOSS", -5.0, 2000),
                _settle_row("tribe-alpha", "FLAT", 0.0, 3000),
                _settle_row("tribe-alpha", "FLAT", 0.0, 4000),
                _settle_row("tribe-alpha", "WIN", 8.0, 5000),
            ]
            _write_jsonl(exp_jsonl, rows)
            m = analyzer.compute_run_tribe_metrics(run_dir, "tribe-alpha")
            # 2 WIN, 1 LOSS, 2 FLAT -> win_rate = 2/3
            self.assertEqual(m["wins"], 2)
            self.assertEqual(m["losses"], 1)
            self.assertEqual(m["flats"], 2)
            self.assertAlmostEqual(m["win_rate"], 2.0 / 3.0, places=6)
            self.assertEqual(m["total_trades"], 5)


class MaxDrawdownChronologicalTest(unittest.TestCase):
    """Test 3 -- max drawdown is computed in chronological order
    regardless of input row order on disk."""

    def test_drawdown_chronological(self):
        with tempfile.TemporaryDirectory() as tmp:
            exp_dir = os.path.join(tmp, "ab-trading-" + TS)
            run_dir = _build_run_dir(exp_dir, TS, "control", 1)
            exp_jsonl = os.path.join(run_dir, "laptop-node", ".agentis", "experience", "1.jsonl")
            # Chronological pnls: +100, -30, -50, +200 -> equity curve:
            # 100, 70, 20, 220 -> running max 100 at ts=1000, dip to 20
            # at ts=3000 -> max_dd = 100 - 20 = 80.
            # Write rows OUT OF ORDER on disk:
            rows = [
                _settle_row("tribe-alpha", "WIN", 200.0, 4000),
                _settle_row("tribe-alpha", "WIN", 100.0, 1000),
                _settle_row("tribe-alpha", "LOSS", -50.0, 3000),
                _settle_row("tribe-alpha", "LOSS", -30.0, 2000),
            ]
            _write_jsonl(exp_jsonl, rows)
            m = analyzer.compute_run_tribe_metrics(run_dir, "tribe-alpha")
            self.assertAlmostEqual(m["max_drawdown_bps"], 80.0, places=6)
            self.assertAlmostEqual(m["pnl_bps_total"], 220.0, places=6)


class MutationRateTest(unittest.TestCase):
    """Test 4 -- mutation surrogates are 0 on control fixture,
    N on treatment fixture with N rewrite rows + N distinct prompt-body
    memo SHAs."""

    def test_mutation_rate_control_zero_treatment_n(self):
        with tempfile.TemporaryDirectory() as tmp:
            exp_dir = os.path.join(tmp, "ab-trading-" + TS)
            control_dir = _build_run_dir(exp_dir, TS, "control", 1)
            # Control: only WIN/LOSS settle rows, no rewrite, no memo
            # dump rows.
            _write_jsonl(
                os.path.join(control_dir, "laptop-node", ".agentis", "experience", "1.jsonl"),
                [
                    _settle_row("tribe-alpha", "WIN", 10.0, 1000),
                    _settle_row("tribe-alpha", "LOSS", -5.0, 2000),
                ],
            )
            c = analyzer.compute_run_tribe_metrics(control_dir, "tribe-alpha")
            self.assertEqual(c["distinct_prompt_shas"], 0)
            self.assertEqual(c["rewrite_events"], 0)

            # Treatment: 3 rewrite rows + 3 distinct prompt-body SHAs.
            treat_dir = _build_run_dir(exp_dir, TS, "treatment", 1)
            _write_jsonl(
                os.path.join(treat_dir, "laptop-node", ".agentis", "experience", "1.jsonl"),
                [
                    _settle_row("tribe-alpha", "WIN", 10.0, 1000),
                    _rewrite_row("tribe-alpha", 1, 1100),
                    _rewrite_row("tribe-alpha", 2, 2100),
                    _rewrite_row("tribe-alpha", 3, 3100),
                ],
            )
            # Memo dump: 3 distinct prompt-body SHAs.
            memo_path = os.path.join(treat_dir, "laptop-node", ".agentis", "memo.jsonl")
            _write_jsonl(memo_path, [
                _memo_row("strategist:prompt_body:" + "a" * 64, "body1"),
                _memo_row("strategist:prompt_body:" + "b" * 64, "body2"),
                _memo_row("strategist:prompt_body:" + "c" * 64, "body3"),
                _memo_row("unrelated:key", "junk"),
            ])
            t = analyzer.compute_run_tribe_metrics(treat_dir, "tribe-alpha")
            self.assertEqual(t["distinct_prompt_shas"], 3)
            self.assertEqual(t["rewrite_events"], 3)


class MissingExperienceDirTest(unittest.TestCase):
    """Test 5 -- missing .agentis/experience/ dir yields a 0-metric row
    with no crash (e.g. run aborted before any learn() fired)."""

    def test_missing_experience_dir_yields_zero_row(self):
        with tempfile.TemporaryDirectory() as tmp:
            exp_dir = os.path.join(tmp, "ab-trading-" + TS)
            os.makedirs(exp_dir, exist_ok=True)
            run_dir = os.path.join(exp_dir, "ab-trading-" + TS + "-control-run-1")
            # Create the run dir but NOT the .agentis tree.
            os.makedirs(run_dir, exist_ok=True)
            m = analyzer.compute_run_tribe_metrics(run_dir, "tribe-alpha")
            self.assertEqual(m["total_trades"], 0)
            self.assertEqual(m["wins"], 0)
            self.assertEqual(m["losses"], 0)
            self.assertEqual(m["flats"], 0)
            self.assertEqual(m["win_rate"], 0.0)
            self.assertEqual(m["pnl_bps_total"], 0.0)
            self.assertEqual(m["max_drawdown_bps"], 0.0)
            self.assertEqual(m["sharpe"], 0.0)
            self.assertEqual(m["distinct_prompt_shas"], 0)
            self.assertEqual(m["rewrite_events"], 0)


class ReportRendersHeaderTableTest(unittest.TestCase):
    """Test 6 -- end-to-end analyze() writes comparison.md with the
    arm-labelled run -> arm header table."""

    def test_comparison_md_has_run_to_arm_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            exp_dir = os.path.join(tmp, "ab-trading-" + TS)
            os.makedirs(exp_dir, exist_ok=True)
            # 2 control runs + 2 treatment runs (small to keep test fast).
            run_dirs = []
            for arm in ("control", "treatment"):
                for run_idx in (1, 2):
                    rd = _build_run_dir(exp_dir, TS, arm, run_idx)
                    # Single settle row so the metrics block is non-empty.
                    _write_jsonl(
                        os.path.join(rd, "laptop-node", ".agentis", "experience", "1.jsonl"),
                        [_settle_row("tribe-alpha", "WIN", 7.5, 1000)],
                    )
                    threshold = 999 if arm == "control" else 3
                    run_dirs.append((arm, run_idx, rd, threshold, 0))
            _write_manifest(exp_dir, TS, run_dirs)
            out_path, report = analyzer.analyze(exp_dir)
            self.assertTrue(os.path.isfile(out_path))
            self.assertEqual(os.path.basename(out_path), "comparison.md")
            # Manifest fields surface.
            self.assertIn("BTCUSDT", report)
            self.assertIn("control", report)
            self.assertIn("treatment", report)
            self.assertIn("REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=999", report)
            self.assertIn("REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=3", report)
            # Run -> arm header table.
            self.assertIn("Run -> arm mapping", report)
            self.assertIn("ab-trading-" + TS + "-control-run-1", report)
            self.assertIn("ab-trading-" + TS + "-treatment-run-2", report)
            # Per-tribe table for tribe-alpha at minimum.
            self.assertIn("tribe-alpha", report)
            self.assertIn("pnl_bps_total", report)
            # Federation aggregate exists.
            self.assertIn("Federation aggregate", report)
            # Honest caveats section verbatim per plan H.
            self.assertIn("Honest caveats", report)

    def test_analyse_refuses_unmapped_run_dir(self):
        """Bonus assertion (still under test 6 class) -- the analyser
        must refuse to emit when a control-/treatment-named run dir is
        not in the manifest."""
        with tempfile.TemporaryDirectory() as tmp:
            exp_dir = os.path.join(tmp, "ab-trading-" + TS)
            os.makedirs(exp_dir, exist_ok=True)
            # Manifest only mentions run 1 control; physical disk has
            # an extra unmapped control-run-99.
            mapped = _build_run_dir(exp_dir, TS, "control", 1)
            _build_run_dir(exp_dir, TS, "control", 99)  # unmapped
            _write_manifest(exp_dir, TS, [("control", 1, mapped, 999, 0)])
            with self.assertRaises(SystemExit) as cm:
                analyzer.analyze(exp_dir)
            self.assertEqual(cm.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
