#!/usr/bin/env python3
"""Fixture-driven assertions for analyse-stage3.py (#439).

Pure stdlib + a temp dir. Fabricates the .agentis/experience/<id>.jsonl,
.agentis/daemon/<id>.colony, bug-ledger.jsonl, knowledge-market.csv,
rotations.csv and run-meta.json shape that `run-stage3-multinode.sh`
emits, then runs the analyser and asserts the 5 outputs match the
documented schema.

Cases:
  1. Single-node, no replicates: lineage.json has 5 root nodes with
     empty children, telemetry-combined.csv has only `laptop` rows,
     comparison-stage3.md has all 6 sections.
  2. Two-node, 3 replicates (1 lineage 2 levels deep on laptop, 2
     single-level lineages on server, all variants `same`):
     lineage.json reflects the parent-child structure and
     survivor-analysis flags one lineage as outlived_parent when a
     descendant outlives its parent.
  3. Two-node, 1 replicate with a `cycle-1` mutation: mutation-diff.csv
     has exactly 1 row with mutation_kind=cycle-1.
  4. Missing server-runs dir: emits a warning to stderr, still
     produces all 5 outputs from laptop-only data.

Exit codes:
  0  all assertions pass
  1  one or more assertions failed
"""

from __future__ import annotations

import csv
import json
import os
import shutil
import subprocess
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ANALYSER = os.path.join(SCRIPT_DIR, "analyse-stage3.py")

PASS = 0
FAIL = 0


def report_pass(label: str) -> None:
    global PASS
    print(f"[PASS] {label}")
    PASS += 1


def report_fail(label: str, detail: str = "") -> None:
    global FAIL
    print(f"[FAIL] {label}")
    if detail:
        print(f"       {detail}")
    FAIL += 1


def assert_eq(label: str, expected: object, got: object) -> None:
    if expected == got:
        report_pass(label)
    else:
        report_fail(label, f"expected: {expected!r}\n       got:      {got!r}")


def assert_contains(label: str, path: str, needle: str) -> None:
    if not os.path.isfile(path):
        report_fail(label, f"file missing: {path}")
        return
    with open(path, encoding="utf-8") as f:
        body = f.read()
    if needle in body:
        report_pass(label)
    else:
        report_fail(label, f"needle not found in {path}: {needle!r}")


def assert_file_exists(label: str, path: str) -> None:
    if os.path.isfile(path):
        report_pass(label)
    else:
        report_fail(label, f"missing file: {path}")


def write_jsonl(path: str, rows: list[dict[str, object]]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r))
            f.write("\n")


def write_text(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def make_seed_node(
    root: str,
    tribes: list[str],
    seed_ids: dict[str, str],
    base_ts: int = 1_700_000_000_000,
) -> None:
    """Lay down .agentis/{daemon,experience,spend}/ for a node with
    one seed agent per tribe in `tribes`. seed_ids[tribe] -> agent_id.
    """
    daemon = os.path.join(root, ".agentis", "daemon")
    exp = os.path.join(root, ".agentis", "experience")
    spend = os.path.join(root, ".agentis", "spend")
    os.makedirs(daemon, exist_ok=True)
    os.makedirs(exp, exist_ok=True)
    os.makedirs(spend, exist_ok=True)
    for i, tribe in enumerate(tribes):
        agent_id = seed_ids[tribe]
        with open(os.path.join(daemon, f"{agent_id}.colony"), "w", encoding="utf-8") as f:
            f.write(tribe)
        write_jsonl(
            os.path.join(exp, f"{agent_id}.jsonl"),
            [
                {
                    "ts": base_ts + i * 60_000,
                    "topic": "hunt",
                    "subject": "line 1",
                    "outcome": "obs",
                    "tags": ["observed", "tribes-bench", tribe],
                },
            ],
        )
        write_jsonl(
            os.path.join(spend, f"{agent_id}.jsonl"),
            [{"ts": base_ts + i * 60_000, "cb": 5, "colony": tribe}],
        )


def add_replicate_event(
    root: str,
    parent_id: str,
    tribe: str,
    n_before: int,
    ts: int,
    variant_tag: str | None = None,
) -> None:
    exp = os.path.join(root, ".agentis", "experience")
    rec = {
        "ts": ts,
        "topic": "replicate",
        "subject": f"n={n_before}",
        "outcome": "cost=100",
        "tags": ["replicated", "tribes-bench", tribe],
    }
    if variant_tag is not None:
        rec["tags"].append(variant_tag)  # type: ignore[attr-defined]
    path = os.path.join(exp, f"{parent_id}.jsonl")
    if os.path.isfile(path):
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
    else:
        write_jsonl(path, [rec])


def add_child_agent(
    root: str,
    tribe: str,
    agent_id: str,
    born_ts: int,
    tps: int = 0,
    fps: int = 0,
    died_ts: int | None = None,
) -> None:
    daemon = os.path.join(root, ".agentis", "daemon")
    exp = os.path.join(root, ".agentis", "experience")
    os.makedirs(daemon, exist_ok=True)
    os.makedirs(exp, exist_ok=True)
    with open(os.path.join(daemon, f"{agent_id}.colony"), "w", encoding="utf-8") as f:
        f.write(tribe)
    rows: list[dict[str, object]] = [
        {
            "ts": born_ts,
            "topic": "hunt",
            "subject": "line 1",
            "outcome": "obs",
            "tags": ["observed", "tribes-bench", tribe],
        }
    ]
    for i in range(tps):
        rows.append({
            "ts": born_ts + 1000 + i,
            "topic": "hunt",
            "subject": f"line {10 + i}",
            "outcome": f"BUG-{i}",
            "tags": ["acted", "tribes-bench", tribe, f"reward={50 + i}"],
        })
    for i in range(fps):
        rows.append({
            "ts": born_ts + 2000 + i,
            "topic": "hunt",
            "subject": f"line {20 + i}",
            "outcome": "fp",
            "tags": ["false-positive", "tribes-bench", tribe],
        })
    if died_ts is not None:
        rows.append({
            "ts": died_ts,
            "topic": "die",
            "subject": "tribe culled",
            "outcome": "death_threshold",
            "tags": ["died", "tribes-bench", tribe],
        })
    write_jsonl(os.path.join(exp, f"{agent_id}.jsonl"), rows)


def run_analyser(run_dir: str, extra_args: list[str] | None = None) -> tuple[int, str, str]:
    cmd = [sys.executable, ANALYSER, run_dir]
    if extra_args:
        cmd.extend(extra_args)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


# -------------------------------------------------------------------------
# Case 1: Single-node, no replicates
# -------------------------------------------------------------------------

def case_1(tmp: str) -> None:
    run_dir = os.path.join(tmp, "case1")
    os.makedirs(run_dir, exist_ok=True)
    tribes = [f"tribe-{n}" for n in ("alpha", "beta", "gamma", "delta", "epsilon")]
    seed_ids = {t: f"seed-{t}" for t in tribes}
    make_seed_node(run_dir, tribes, seed_ids)
    write_text(os.path.join(run_dir, "bug-ledger.jsonl"), "")
    write_text(os.path.join(run_dir, "rotations.csv"), "ts,target_dir,bugs_manifest\n")
    write_text(
        os.path.join(run_dir, "run-meta.json"),
        json.dumps({"started_at": "2026-05-05T12:00:00Z", "wall_clock_s": 1800,
                    "rotation_interval_s": 600}),
    )

    rc, _stdout, stderr = run_analyser(run_dir)
    assert_eq("case 1: analyser exits 0", 0, rc)

    # All 5 outputs present.
    for name in (
        "telemetry-combined.csv", "lineage.json",
        "survivor-analysis.csv", "mutation-diff.csv",
        "comparison-stage3.md",
    ):
        assert_file_exists(f"case 1: {name} produced", os.path.join(run_dir, name))

    # lineage.json: 5 roots, all with empty children.
    with open(os.path.join(run_dir, "lineage.json"), encoding="utf-8") as f:
        data = json.load(f)
    roots = data.get("roots", [])
    assert_eq("case 1: lineage has 5 root nodes", 5, len(roots))
    empty_kids = all(r.get("children") == [] for r in roots)
    assert_eq("case 1: every root has empty children", True, empty_kids)
    tribe_set = sorted(r.get("tribe") for r in roots)
    assert_eq(
        "case 1: roots cover all 5 seed tribes",
        sorted(tribes),
        tribe_set,
    )

    # telemetry-combined.csv: only laptop node (no server rows).
    with open(os.path.join(run_dir, "telemetry-combined.csv"), encoding="utf-8") as f:
        reader = csv.reader(f)
        rows = list(reader)
    assert_eq("case 1: telemetry has node header", "node", rows[0][0])
    laptop_rows = [r for r in rows[1:] if r and r[0] == "laptop"]
    server_rows = [r for r in rows[1:] if r and r[0] == "server"]
    assert_eq("case 1: telemetry has zero server rows", 0, len(server_rows))
    if not laptop_rows:
        report_fail("case 1: telemetry has at least one laptop row")
    else:
        report_pass("case 1: telemetry has at least one laptop row")

    # comparison-stage3.md: every section heading present.
    cmp_path = os.path.join(run_dir, "comparison-stage3.md")
    for heading in (
        "## 1. Run shape",
        "## 2. Findings volume",
        "## 3. Cost per verified bug",
        "## 4. Replication dynamics",
        "## 5. Mutation outcomes",
        "## 6. Knowledge market activity",
    ):
        assert_contains(f"case 1: comparison.md has '{heading}'", cmp_path, heading)


# -------------------------------------------------------------------------
# Case 2: Two-node, 3 replicates, all variants `same`
# -------------------------------------------------------------------------

def case_2(tmp: str) -> None:
    run_dir = os.path.join(tmp, "case2")
    os.makedirs(run_dir, exist_ok=True)
    server_dir = os.path.join(run_dir, "server-runs", "20260505T120000Z")
    os.makedirs(server_dir, exist_ok=True)

    laptop_tribes = ["tribe-alpha", "tribe-beta"]
    server_tribes = ["tribe-gamma", "tribe-delta", "tribe-epsilon"]

    laptop_seeds = {t: f"laptop-seed-{t}" for t in laptop_tribes}
    server_seeds = {t: f"server-seed-{t}" for t in server_tribes}

    # Laptop seeds with low TPs on the root (so descendants can outscore).
    make_seed_node(run_dir, laptop_tribes, laptop_seeds, base_ts=1_700_000_000_000)
    make_seed_node(server_dir, server_tribes, server_seeds, base_ts=1_700_000_000_000)

    # The seed ts assignment in make_seed_node bumps base_ts +60_000 per
    # tribe. To make the seed agent in tribe-alpha clearly outranked by
    # its descendants we add a single TP row to the seed via a manual
    # rewrite — easier than changing the helper signature.
    laptop_alpha_seed = laptop_seeds["tribe-alpha"]
    seed_path = os.path.join(run_dir, ".agentis", "experience", f"{laptop_alpha_seed}.jsonl")
    with open(seed_path, "a", encoding="utf-8") as f:
        f.write(json.dumps({
            "ts": 1_700_000_000_500,
            "topic": "hunt",
            "subject": "line 7",
            "outcome": "BUG-A",
            "tags": ["acted", "tribes-bench", "tribe-alpha", "reward=10"],
        }) + "\n")
        # Death of the seed at a fixed ts so a descendant can outlive it.
        f.write(json.dumps({
            "ts": 1_700_000_500_000,
            "topic": "die",
            "subject": "culled",
            "outcome": "death_threshold",
            "tags": ["died", "tribes-bench", "tribe-alpha"],
        }) + "\n")

    # 1 laptop chain in tribe-alpha: seed -> child1 -> child2 (depth 2)
    # Both replicate events use the legacy hunter.ag tag shape (no
    # variant tag) so the pick_variant() rotation produces `same` for
    # the cycle of size 3 only when the index mod 3 lands on 0; for
    # this case we tag the events with explicit variant tags so all
    # three lineage members carry the SAME variant -> mutation_kind
    # `same`.
    add_replicate_event(
        run_dir, laptop_alpha_seed, "tribe-alpha",
        n_before=1, ts=1_700_000_120_000,
        variant_tag="format-pattern-default",
    )
    laptop_alpha_child1 = "laptop-c1"
    add_child_agent(
        run_dir, "tribe-alpha", laptop_alpha_child1,
        born_ts=1_700_000_180_000, tps=5, fps=0,
        died_ts=None,
    )
    add_replicate_event(
        run_dir, laptop_alpha_child1, "tribe-alpha",
        n_before=2, ts=1_700_000_240_000,
        variant_tag="format-pattern-default",
    )
    laptop_alpha_child2 = "laptop-c2"
    # The child2 outlives the seed -- it is born after the seed dies.
    add_child_agent(
        run_dir, "tribe-alpha", laptop_alpha_child2,
        born_ts=1_700_000_600_000, tps=8, fps=0,
        died_ts=None,
    )

    # 2 server single-level lineages (one in tribe-gamma, one in
    # tribe-delta).
    server_gamma_seed = server_seeds["tribe-gamma"]
    add_replicate_event(
        server_dir, server_gamma_seed, "tribe-gamma",
        n_before=1, ts=1_700_000_300_000,
        variant_tag="format-pattern-default",
    )
    add_child_agent(
        server_dir, "tribe-gamma", "server-c-g",
        born_ts=1_700_000_360_000, tps=2, fps=0,
    )
    server_delta_seed = server_seeds["tribe-delta"]
    add_replicate_event(
        server_dir, server_delta_seed, "tribe-delta",
        n_before=1, ts=1_700_000_400_000,
        variant_tag="format-pattern-default",
    )
    add_child_agent(
        server_dir, "tribe-delta", "server-c-d",
        born_ts=1_700_000_460_000, tps=2, fps=0,
    )

    write_text(os.path.join(run_dir, "bug-ledger.jsonl"), "")
    write_text(os.path.join(server_dir, "bug-ledger.jsonl"), "")
    write_text(os.path.join(run_dir, "rotations.csv"), "ts,target_dir,bugs_manifest\n")
    write_text(
        os.path.join(run_dir, "run-meta.json"),
        json.dumps({"started_at": "2026-05-05T12:00:00Z", "wall_clock_s": 1800,
                    "rotation_interval_s": 600}),
    )

    rc, _stdout, _stderr = run_analyser(run_dir)
    assert_eq("case 2: analyser exits 0", 0, rc)

    with open(os.path.join(run_dir, "lineage.json"), encoding="utf-8") as f:
        data = json.load(f)
    roots = data.get("roots", [])
    # 5 roots total (one per tribe).
    assert_eq("case 2: lineage has 5 roots", 5, len(roots))

    # Find tribe-alpha root and verify chain depth = 2.
    alpha_root = next((r for r in roots if r["tribe"] == "tribe-alpha"), None)
    if alpha_root is None:
        report_fail("case 2: tribe-alpha root present")
    else:
        report_pass("case 2: tribe-alpha root present")
        assert_eq("case 2: tribe-alpha root has 1 child", 1, len(alpha_root["children"]))
        if alpha_root["children"]:
            assert_eq(
                "case 2: tribe-alpha grand-child present",
                1,
                len(alpha_root["children"][0]["children"]),
            )

    # 2 server single-level lineages: gamma + delta each have 1 child.
    gamma_root = next((r for r in roots if r["tribe"] == "tribe-gamma"), None)
    delta_root = next((r for r in roots if r["tribe"] == "tribe-delta"), None)
    if gamma_root and delta_root:
        report_pass("case 2: server roots present")
        assert_eq("case 2: gamma has 1 child", 1, len(gamma_root["children"]))
        assert_eq("case 2: delta has 1 child", 1, len(delta_root["children"]))
    else:
        report_fail("case 2: server roots present")

    # mutation-diff.csv: 4 rows (alpha seed->c1, c1->c2, gamma->cg,
    # delta->cd), all kind=same. Note: a "2 levels deep" lineage
    # contributes 2 replicate events (seed->c1, c1->c2), plus the 2
    # single-level server lineages = 4 total events.
    with open(os.path.join(run_dir, "mutation-diff.csv"), encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    assert_eq("case 2: mutation-diff has 4 events", 4, len(rows))
    same_count = sum(1 for r in rows if r["mutation_kind"] == "same")
    assert_eq("case 2: all mutations are same", 4, same_count)

    # survivor-analysis: tribe-alpha lineage outlived_parent must be true
    # (seed dies at ts=500_000, child2 born at ts=600_000 with no died_ts).
    with open(os.path.join(run_dir, "survivor-analysis.csv"), encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    alpha_row = next((r for r in rows if r["tribe"] == "tribe-alpha"), None)
    if alpha_row is None:
        report_fail("case 2: survivor-analysis has tribe-alpha row")
    else:
        report_pass("case 2: survivor-analysis has tribe-alpha row")
        assert_eq(
            "case 2: tribe-alpha outlived_parent=true",
            "true", alpha_row["outlived_parent"],
        )

    # telemetry-combined.csv has both laptop and server rows.
    with open(os.path.join(run_dir, "telemetry-combined.csv"), encoding="utf-8") as f:
        reader = csv.reader(f)
        rows = list(reader)
    laptop_rows = [r for r in rows[1:] if r and r[0] == "laptop"]
    server_rows = [r for r in rows[1:] if r and r[0] == "server"]
    if laptop_rows and server_rows:
        report_pass("case 2: combined telemetry has laptop + server rows")
    else:
        report_fail(
            "case 2: combined telemetry has laptop + server rows",
            f"laptop={len(laptop_rows)} server={len(server_rows)}",
        )


# -------------------------------------------------------------------------
# Case 3: Two-node, 1 replicate with cycle-1 mutation
# -------------------------------------------------------------------------

def case_3(tmp: str) -> None:
    run_dir = os.path.join(tmp, "case3")
    os.makedirs(run_dir, exist_ok=True)
    server_dir = os.path.join(run_dir, "server-runs", "20260505T120000Z")
    os.makedirs(server_dir, exist_ok=True)

    laptop_tribes = ["tribe-alpha", "tribe-beta"]
    server_tribes = ["tribe-gamma", "tribe-delta", "tribe-epsilon"]
    laptop_seeds = {t: f"laptop-seed-{t}" for t in laptop_tribes}
    server_seeds = {t: f"server-seed-{t}" for t in server_tribes}
    make_seed_node(run_dir, laptop_tribes, laptop_seeds)
    make_seed_node(server_dir, server_tribes, server_seeds)

    # Single replicate on tribe-beta with explicit variant tag that
    # advances the parent (default) to the next cycle position
    # (strict-literal) -> mutation_kind = cycle-1.
    add_replicate_event(
        run_dir, laptop_seeds["tribe-beta"], "tribe-beta",
        n_before=1, ts=1_700_000_300_000,
        variant_tag="format-pattern-strict-literal",
    )
    add_child_agent(
        run_dir, "tribe-beta", "laptop-c-beta",
        born_ts=1_700_000_360_000, tps=1, fps=0,
    )

    write_text(os.path.join(run_dir, "bug-ledger.jsonl"), "")
    write_text(os.path.join(server_dir, "bug-ledger.jsonl"), "")
    write_text(os.path.join(run_dir, "rotations.csv"), "ts,target_dir,bugs_manifest\n")
    write_text(
        os.path.join(run_dir, "run-meta.json"),
        json.dumps({"started_at": "2026-05-05T12:00:00Z", "wall_clock_s": 1800,
                    "rotation_interval_s": 600}),
    )

    rc, _stdout, _stderr = run_analyser(run_dir)
    assert_eq("case 3: analyser exits 0", 0, rc)

    with open(os.path.join(run_dir, "mutation-diff.csv"), encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    assert_eq("case 3: mutation-diff has exactly 1 row", 1, len(rows))
    if rows:
        assert_eq(
            "case 3: mutation_kind=cycle-1",
            "cycle-1", rows[0]["mutation_kind"],
        )
        assert_eq("case 3: tribe=tribe-beta", "tribe-beta", rows[0]["tribe"])


# -------------------------------------------------------------------------
# Case 4: Missing server-runs dir produces stderr warning + 5 outputs
# -------------------------------------------------------------------------

def case_4(tmp: str) -> None:
    run_dir = os.path.join(tmp, "case4")
    os.makedirs(run_dir, exist_ok=True)
    tribes = ["tribe-alpha"]
    seed_ids = {t: f"seed-{t}" for t in tribes}
    make_seed_node(run_dir, tribes, seed_ids)
    write_text(os.path.join(run_dir, "bug-ledger.jsonl"), "")
    write_text(os.path.join(run_dir, "rotations.csv"), "ts,target_dir,bugs_manifest\n")
    write_text(
        os.path.join(run_dir, "run-meta.json"),
        json.dumps({"started_at": "2026-05-05T12:00:00Z", "wall_clock_s": 1800,
                    "rotation_interval_s": 600}),
    )
    # Deliberately do NOT create server-runs/ to exercise the
    # warning path.
    if os.path.isdir(os.path.join(run_dir, "server-runs")):
        shutil.rmtree(os.path.join(run_dir, "server-runs"))

    rc, _stdout, stderr = run_analyser(run_dir)
    assert_eq("case 4: analyser exits 0 even without server-runs", 0, rc)
    if "warning" in stderr.lower() and "server-runs" in stderr:
        report_pass("case 4: stderr carries server-runs warning")
    else:
        report_fail("case 4: stderr carries server-runs warning", f"stderr={stderr!r}")
    for name in (
        "telemetry-combined.csv", "lineage.json",
        "survivor-analysis.csv", "mutation-diff.csv",
        "comparison-stage3.md",
    ):
        assert_file_exists(f"case 4: {name} produced", os.path.join(run_dir, name))


# -------------------------------------------------------------------------
# Driver
# -------------------------------------------------------------------------

def main() -> int:
    if not os.path.isfile(ANALYSER):
        print(f"[FAIL] analyser missing: {ANALYSER}")
        return 1
    tmp = tempfile.mkdtemp(prefix="test-analyse-stage3-")
    try:
        case_1(tmp)
        case_2(tmp)
        case_3(tmp)
        case_4(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("")
    print(f"Results: {PASS} passed, {FAIL} failed")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
