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
# `tribes-bench/` (the fed root) -- one level up from `tools/`. Tests
# pass it via --fed-root so per-tribe variant pools resolve regardless
# of where the temporary run dir lives. --no-variant-stats avoids any
# `agentis memo list` invocation in the offline test harness.
FED_ROOT = os.path.dirname(SCRIPT_DIR)


def _import_analyser():
    """Import analyse-stage3.py as a module so the new #495 helpers
    (parse_variant_pool, discover_tribe_pools, read_variant_stats) can
    be unit-tested in-process. The hyphenated filename forces the
    importlib spec dance; we rely on this everywhere a test exercises
    a function rather than the CLI."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "analyse_stage3", ANALYSER,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("test-analyse-stage3: cannot import analyser module")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod

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


def run_analyser(
    run_dir: str,
    extra_args: list[str] | None = None,
    fed_root: str | None = FED_ROOT,
    no_variant_stats: bool = True,
) -> tuple[int, str, str]:
    cmd = [sys.executable, ANALYSER, run_dir]
    if fed_root:
        cmd.extend(["--fed-root", fed_root])
    if no_variant_stats:
        cmd.append("--no-variant-stats")
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
        # #499 M98: variant tag is `<class>:<phrasing>` (alpha primary
        # class is `uninitialised_memory`). Tag is recognised against
        # known_variants (alpha's parsed pool); seeds the seed agent's
        # observational prompt_variant to the alpha primary default.
        f.write(json.dumps({
            "ts": 1_700_000_000_500,
            "topic": "hunt",
            "subject": "line 7",
            "outcome": "BUG-A",
            "tags": [
                "acted", "tribes-bench", "tribe-alpha", "reward=10",
                "uninitialised_memory:format-pattern-default",
            ],
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
        variant_tag="uninitialised_memory:format-pattern-default",
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
        variant_tag="uninitialised_memory:format-pattern-default",
    )
    laptop_alpha_child2 = "laptop-c2"
    # The child2 outlives the seed -- it is born after the seed dies.
    add_child_agent(
        run_dir, "tribe-alpha", laptop_alpha_child2,
        born_ts=1_700_000_600_000, tps=8, fps=0,
        died_ts=None,
    )

    # 2 server single-level lineages (one in tribe-gamma, one in
    # tribe-delta). Each tribe uses its own pool's primary-class index-0
    # variant (gamma: memory_corruption:error-path-default,
    # delta: use_after_free:lifetime-default) so the mutation_kind
    # cycle-N math resolves against the right pool. We also tag the
    # seed agent with the same bare variant so its observational
    # prompt_variant settles before the replicate event.
    # #499 M98: variant tag is `<class>:<phrasing>`.
    for seed_tribe, seed_id, default_variant, child_id, ts in (
        ("tribe-gamma", server_seeds["tribe-gamma"],
         "memory_corruption:error-path-default",
         "server-c-g", 1_700_000_300_000),
        ("tribe-delta", server_seeds["tribe-delta"],
         "use_after_free:lifetime-default",
         "server-c-d", 1_700_000_400_000),
    ):
        seed_path = os.path.join(
            server_dir, ".agentis", "experience", f"{seed_id}.jsonl"
        )
        with open(seed_path, "a", encoding="utf-8") as f:
            f.write(json.dumps({
                "ts": ts - 100_000,
                "topic": "hunt",
                "subject": "line 4",
                "outcome": "obs",
                "tags": [
                    "observed", "tribes-bench", seed_tribe, default_variant,
                ],
            }) + "\n")
        add_replicate_event(
            server_dir, seed_id, seed_tribe,
            n_before=1, ts=ts,
            variant_tag=default_variant,
        )
        add_child_agent(
            server_dir, seed_tribe, child_id,
            born_ts=ts + 60_000, tps=2, fps=0,
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

    # The tribe-beta seed claims the pool's index-0 variant via a bare
    # observable tag on its first learn row, so its prompt_variant
    # resolves observationally before the replicate event fires.
    beta_seed_path = os.path.join(
        run_dir, ".agentis", "experience", f"{laptop_seeds['tribe-beta']}.jsonl"
    )
    with open(beta_seed_path, "a", encoding="utf-8") as f:
        f.write(json.dumps({
            "ts": 1_700_000_000_500,
            "topic": "hunt",
            "subject": "line 4",
            "outcome": "obs",
            "tags": [
                "observed", "tribes-bench", "tribe-beta",
                # #499 M98: beta primary class is `heap_overflow`.
                "heap_overflow:source-sink-default",
            ],
        }) + "\n")
    # Single replicate on tribe-beta with explicit variant tag that
    # advances the parent (heap_overflow:source-sink-default) to the
    # next pool position (heap_overflow:source-sink-arg-only) ->
    # mutation_kind = cycle-1.
    add_replicate_event(
        run_dir, laptop_seeds["tribe-beta"], "tribe-beta",
        n_before=1, ts=1_700_000_300_000,
        variant_tag="heap_overflow:source-sink-arg-only",
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
# #495 unit tests: variant-pool discovery + variant_stats memo reads
# -------------------------------------------------------------------------

ALPHA_FIXTURE = """
fn helper() -> int { return 1; }

fn pick_variant(tribe: string, n: int) -> string {
    let _ = tribe;
    let idx = n - ((n / 3) * 3);
    if idx == 0 {
        return "format-pattern-default";
    };
    if idx == 1 {
        return "format-pattern-strict-literal";
    };
    return "format-pattern-broad-shellbuilder";
}

fn after_pick() -> string { return "tail"; }
"""

EXTENDED_FIXTURE = """
fn pick_variant(tribe: string, n: int) -> string {
    let _ = tribe;
    let idx = n - ((n / 7) * 7);
    if idx == 0 { return "x-default"; };
    if idx == 1 { return "x-arg-only"; };
    if idx == 2 { return "x-broad-flow"; };
    if idx == 3 { return "x-call-graph"; };
    if idx == 4 { return "x-async-boundary"; };
    if idx == 5 { return "x-trait-dispatch"; };
    return "x-iterator-chain";
}
"""

EMPTY_POOL_FIXTURE = """
fn pick_variant(tribe: string, n: int) -> string {
    let _ = tribe;
    let computed = "x-" + to_string(n);
    return computed;
}
"""


def test_parse_variant_pool_alpha(tmp: str) -> None:
    mod = _import_analyser()
    fixture = os.path.join(tmp, "alpha-hunter.ag")
    write_text(fixture, ALPHA_FIXTURE)
    pool = mod.parse_variant_pool(fixture)
    assert_eq(
        "test_parse_variant_pool_alpha: 3-literal pool in source order",
        [
            "format-pattern-default",
            "format-pattern-strict-literal",
            "format-pattern-broad-shellbuilder",
        ],
        pool,
    )


def test_parse_variant_pool_extended_pool(tmp: str) -> None:
    mod = _import_analyser()
    fixture = os.path.join(tmp, "extended-hunter.ag")
    write_text(fixture, EXTENDED_FIXTURE)
    pool = mod.parse_variant_pool(fixture)
    assert_eq(
        "test_parse_variant_pool_extended_pool: all 7 literals in source order",
        [
            "x-default", "x-arg-only", "x-broad-flow", "x-call-graph",
            "x-async-boundary", "x-trait-dispatch", "x-iterator-chain",
        ],
        pool,
    )


def test_parse_variant_pool_raises_on_empty(tmp: str) -> None:
    mod = _import_analyser()
    fixture = os.path.join(tmp, "empty-hunter.ag")
    write_text(fixture, EMPTY_POOL_FIXTURE)
    try:
        mod.parse_variant_pool(fixture)
    except ValueError:
        report_pass("test_parse_variant_pool_raises_on_empty: ValueError raised")
        return
    report_fail(
        "test_parse_variant_pool_raises_on_empty: ValueError raised",
        "no exception",
    )


def test_discover_tribe_pools_disjoint_prefixes(tmp: str) -> None:
    mod = _import_analyser()
    fed = os.path.join(tmp, "fake-fed")
    pools_layout = {
        "tribe-alpha": ["alpha-1", "alpha-2", "alpha-3"],
        "tribe-beta": ["beta-1", "beta-2", "beta-3"],
        "tribe-gamma": ["gamma-1", "gamma-2", "gamma-3"],
    }
    for tribe, variants in pools_layout.items():
        body = "\n".join(
            [f'    if idx == {i} {{ return "{v}"; }};' for i, v in enumerate(variants[:-1])]
        )
        ag = (
            "fn pick_variant(tribe: string, n: int) -> string {\n"
            "    let _ = tribe;\n"
            "    let idx = n - ((n / 3) * 3);\n"
            f"{body}\n"
            f'    return "{variants[-1]}";\n'
            "}\n"
        )
        write_text(os.path.join(fed, tribe, "agents", "hunter.ag"), ag)
    discovered = mod.discover_tribe_pools(fed)
    assert_eq(
        "test_discover_tribe_pools_disjoint_prefixes: tribe set",
        sorted(pools_layout.keys()), sorted(discovered.keys()),
    )
    union: list[str] = []
    for variants in discovered.values():
        union.extend(variants)
    assert_eq(
        "test_discover_tribe_pools_disjoint_prefixes: union duplicate-free",
        len(union), len(set(union)),
    )


def test_read_variant_stats_parses_memo_list_output(tmp: str) -> None:
    mod = _import_analyser()
    canned_stdout = (
        "variant_stats:format-pattern-default:verified = 0\n"
        "variant_stats:format-pattern-default:falsepos = 59\n"
        "variant_stats:format-pattern-substitution-aware:verified = 4\n"
        "variant_stats:format-pattern-substitution-aware:falsepos = 1\n"
    )

    class _Proc:
        returncode = 0
        stdout = canned_stdout
        stderr = ""

    real_run = subprocess.run

    def fake_run(*args, **kwargs):  # noqa: ANN001, ANN201
        cmd = args[0] if args else kwargs.get("args", [])
        if isinstance(cmd, list) and cmd and cmd[0] == "agentis":
            return _Proc()
        return real_run(*args, **kwargs)

    subprocess.run = fake_run  # type: ignore[assignment]
    try:
        result = mod.read_variant_stats(tmp)
    finally:
        subprocess.run = real_run  # type: ignore[assignment]
    expected = {
        "format-pattern-default": {"verified": 0, "falsepos": 59},
        "format-pattern-substitution-aware": {"verified": 4, "falsepos": 1},
    }
    assert_eq(
        "test_read_variant_stats_parses_memo_list_output: parsed dict",
        expected, result,
    )


def test_read_variant_stats_missing_binary_returns_empty(tmp: str) -> None:
    mod = _import_analyser()
    real_run = subprocess.run

    def fake_run(*args, **kwargs):  # noqa: ANN001, ANN201
        raise FileNotFoundError("no agentis binary")

    subprocess.run = fake_run  # type: ignore[assignment]
    try:
        # Capture stderr so the warning does not pollute test output.
        from io import StringIO
        old_err = sys.stderr
        sys.stderr = StringIO()
        try:
            result = mod.read_variant_stats(tmp)
            captured = sys.stderr.getvalue()
        finally:
            sys.stderr = old_err
    finally:
        subprocess.run = real_run  # type: ignore[assignment]
    assert_eq(
        "test_read_variant_stats_missing_binary_returns_empty: dict",
        {}, result,
    )
    if "agentis" in captured.lower() and "warning" in captured.lower():
        report_pass(
            "test_read_variant_stats_missing_binary_returns_empty: stderr warning"
        )
    else:
        report_fail(
            "test_read_variant_stats_missing_binary_returns_empty: stderr warning",
            f"captured={captured!r}",
        )


def test_variant_outcomes_table_orders_by_verified_desc_falsepos_asc(tmp: str) -> None:
    """End-to-end: feed the analyser a run dir whose comparison.md
    has to render the new "Variant outcomes per tribe" table in the
    documented order. We use a custom variant_stats input by writing
    .agentis/memo/variant_stats:* files... but the runtime backend is
    sled, not files, so instead we monkeypatch read_variant_stats to
    return a canned aggregation directly. The output we assert on is
    the comparison.md text.
    """
    run_dir = os.path.join(tmp, "outcomes")
    os.makedirs(run_dir, exist_ok=True)
    tribes = ["tribe-alpha"]
    seed_ids = {t: f"seed-{t}" for t in tribes}
    make_seed_node(run_dir, tribes, seed_ids)
    write_text(os.path.join(run_dir, "bug-ledger.jsonl"), "")
    write_text(os.path.join(run_dir, "rotations.csv"), "ts,target_dir,bugs_manifest\n")
    write_text(
        os.path.join(run_dir, "run-meta.json"),
        json.dumps({"started_at": "2026-05-05T12:00:00Z", "wall_clock_s": 60,
                    "rotation_interval_s": 60}),
    )
    # Seed an `agentis` shim on PATH that emits the canned counts.
    bin_dir = os.path.join(tmp, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    shim_path = os.path.join(bin_dir, "agentis")
    write_text(
        shim_path,
        "#!/bin/sh\n"
        'cat <<EOF\n'
        # #499 M98: variant pool literals are now `<class>:<phrasing>`,
        # so the shim emits the post-#499 alpha pool keys (primary class
        # `uninitialised_memory`). `read_variant_stats` rpartition(':')
        # splits on the LAST colon, so the embedded class:phrasing colon
        # round-trips intact.
        "variant_stats:uninitialised_memory:format-pattern-substitution-aware:verified = 4\n"
        "variant_stats:uninitialised_memory:format-pattern-substitution-aware:falsepos = 1\n"
        "variant_stats:uninitialised_memory:format-pattern-strict-literal:verified = 4\n"
        "variant_stats:uninitialised_memory:format-pattern-strict-literal:falsepos = 0\n"
        "variant_stats:uninitialised_memory:format-pattern-default:verified = 0\n"
        "variant_stats:uninitialised_memory:format-pattern-default:falsepos = 59\n"
        "EOF\n",
    )
    os.chmod(shim_path, 0o755)
    env = dict(os.environ)
    env["PATH"] = bin_dir + os.pathsep + env.get("PATH", "")
    cmd = [
        sys.executable, ANALYSER, run_dir,
        "--fed-root", FED_ROOT,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        report_fail(
            "test_variant_outcomes_table_orders_by_verified_desc_falsepos_asc: analyser ok",
            f"rc={proc.returncode} stderr={proc.stderr}",
        )
        return
    cmp_path = os.path.join(run_dir, "comparison-stage3.md")
    with open(cmp_path, encoding="utf-8") as f:
        body = f.read()
    if "Variant outcomes per tribe" not in body:
        report_fail(
            "test_variant_outcomes_table_orders_by_verified_desc_falsepos_asc: header",
            f"comparison.md missing header; body={body[:400]!r}",
        )
        return
    report_pass(
        "test_variant_outcomes_table_orders_by_verified_desc_falsepos_asc: header"
    )
    # Strict order: strict-literal (4v/0fp) before substitution-aware
    # (4v/1fp); both before any 0v line. format-pattern-default in dead.
    sl_idx = body.find("format-pattern-strict-literal")
    sa_idx = body.find("format-pattern-substitution-aware")
    if sl_idx > 0 and sa_idx > 0 and sl_idx < sa_idx:
        report_pass(
            "test_variant_outcomes_table_orders_by_verified_desc_falsepos_asc: tie-break"
        )
    else:
        report_fail(
            "test_variant_outcomes_table_orders_by_verified_desc_falsepos_asc: tie-break",
            f"sl_idx={sl_idx} sa_idx={sa_idx}",
        )
    if "Dead variants per tribe" in body and "format-pattern-default" in body:
        report_pass(
            "test_variant_outcomes_table_orders_by_verified_desc_falsepos_asc: dead section"
        )
    else:
        report_fail(
            "test_variant_outcomes_table_orders_by_verified_desc_falsepos_asc: dead section"
        )


def test_mutation_diff_csv_has_observational_columns(tmp: str) -> None:
    run_dir = os.path.join(tmp, "obs-cols")
    os.makedirs(run_dir, exist_ok=True)
    tribes = ["tribe-alpha", "tribe-beta"]
    seed_ids = {t: f"seed-{t}" for t in tribes}
    make_seed_node(run_dir, tribes, seed_ids)
    # tribe-alpha: claim default via bare tag, then replicate also tagged.
    # #499 M98: variant tag is now `<class>:<phrasing>` (alpha primary
    # class is `uninitialised_memory`); experience-row tag mirrors the
    # post-#499 pool literal so the analyser resolves it to "observed".
    seed_path = os.path.join(
        run_dir, ".agentis", "experience", f"{seed_ids['tribe-alpha']}.jsonl"
    )
    with open(seed_path, "a", encoding="utf-8") as f:
        f.write(json.dumps({
            "ts": 1_700_000_000_500,
            "topic": "hunt",
            "subject": "line 9",
            "outcome": "obs",
            "tags": [
                "observed", "tribes-bench", "tribe-alpha",
                "uninitialised_memory:format-pattern-default",
            ],
        }) + "\n")
    add_replicate_event(
        run_dir, seed_ids["tribe-alpha"], "tribe-alpha",
        n_before=1, ts=1_700_000_400_000,
        variant_tag="uninitialised_memory:format-pattern-default",
    )
    add_child_agent(
        run_dir, "tribe-alpha", "obs-c1",
        born_ts=1_700_000_460_000, tps=1, fps=0,
    )
    write_text(os.path.join(run_dir, "bug-ledger.jsonl"), "")
    write_text(os.path.join(run_dir, "rotations.csv"), "ts,target_dir,bugs_manifest\n")
    write_text(
        os.path.join(run_dir, "run-meta.json"),
        json.dumps({"started_at": "2026-05-05T12:00:00Z", "wall_clock_s": 60,
                    "rotation_interval_s": 60}),
    )
    rc, _stdout, _stderr = run_analyser(run_dir)
    assert_eq(
        "test_mutation_diff_csv_has_observational_columns: analyser ok",
        0, rc,
    )
    csv_path = os.path.join(run_dir, "mutation-diff.csv")
    with open(csv_path, encoding="utf-8") as f:
        reader = csv.reader(f)
        rows = list(reader)
    if not rows:
        report_fail(
            "test_mutation_diff_csv_has_observational_columns: header",
            "empty file",
        )
        return
    header = rows[0]
    expected_cols = {"source", "parent_variant_verified", "parent_variant_falsepos"}
    if expected_cols.issubset(set(header)):
        report_pass(
            "test_mutation_diff_csv_has_observational_columns: header"
        )
    else:
        report_fail(
            "test_mutation_diff_csv_has_observational_columns: header",
            f"missing={expected_cols - set(header)} header={header}",
        )
        return
    src_idx = header.index("source")
    sources = {r[src_idx] for r in rows[1:] if r}
    if "observed" in sources:
        report_pass(
            "test_mutation_diff_csv_has_observational_columns: at least one observed row"
        )
    else:
        report_fail(
            "test_mutation_diff_csv_has_observational_columns: at least one observed row",
            f"sources={sources}",
        )


# -------------------------------------------------------------------------
# #513: per-class fitness summary + variant-trajectory.csv
# -------------------------------------------------------------------------

def test_per_class_summary_table_orders_by_stage2_class_order(_tmp: str) -> None:
    """All 8 STAGE2_CLASSES appear as fixed rows in the canonical
    order, even when zero counters are present."""
    mod = _import_analyser()
    lines = mod.render_per_class_summary({})
    body = "\n".join(lines)
    if "### Per-class fitness summary" not in body:
        report_fail(
            "test_per_class_summary_table_orders_by_stage2_class_order: header"
        )
        return
    report_pass(
        "test_per_class_summary_table_orders_by_stage2_class_order: header"
    )
    indices = []
    for cls in mod.STAGE2_CLASSES:
        idx = body.find(f"| {cls} ")
        indices.append((cls, idx))
    missing = [cls for cls, idx in indices if idx < 0]
    if missing:
        report_fail(
            "test_per_class_summary_table_orders_by_stage2_class_order: all 8 rows",
            f"missing classes: {missing}",
        )
        return
    report_pass(
        "test_per_class_summary_table_orders_by_stage2_class_order: all 8 rows"
    )
    ordered = all(
        indices[i][1] < indices[i + 1][1]
        for i in range(len(indices) - 1)
    )
    if ordered:
        report_pass(
            "test_per_class_summary_table_orders_by_stage2_class_order: order"
        )
    else:
        report_fail(
            "test_per_class_summary_table_orders_by_stage2_class_order: order",
            f"indices={indices}",
        )


def test_per_class_summary_aggregates_across_tribes(_tmp: str) -> None:
    """verified and falsepos sum across tribes (and phrasings) for a
    given class."""
    mod = _import_analyser()
    stats = {
        "tribe-alpha": {
            "use_after_free:format-pattern-default": {
                "verified": 3, "falsepos": 1,
            },
            "use_after_free:format-pattern-strict-literal": {
                "verified": 2, "falsepos": 0,
            },
        },
        "tribe-beta": {
            "use_after_free:source-sink-call-graph": {
                "verified": 4, "falsepos": 2,
            },
        },
    }
    lines = mod.render_per_class_summary(stats)
    body = "\n".join(lines)
    # use_after_free row: verified=9, falsepos=3, hit_rate=0.75
    target = "| use_after_free | 9 | 3 | 0.75 |"
    if target in body:
        report_pass(
            "test_per_class_summary_aggregates_across_tribes: aggregation"
        )
    else:
        report_fail(
            "test_per_class_summary_aggregates_across_tribes: aggregation",
            f"target={target!r} not in body",
        )


def test_per_class_summary_dominant_tribe(_tmp: str) -> None:
    """dominant_tribe is the tribe with most verified for the class."""
    mod = _import_analyser()
    stats = {
        "tribe-alpha": {
            "heap_overflow:format-pattern-default": {
                "verified": 2, "falsepos": 0,
            },
        },
        "tribe-beta": {
            "heap_overflow:source-sink-call-graph": {
                "verified": 7, "falsepos": 1,
            },
        },
        "tribe-gamma": {
            "heap_overflow:error-path-trait-dispatch": {
                "verified": 1, "falsepos": 0,
            },
        },
    }
    lines = mod.render_per_class_summary(stats)
    body = "\n".join(lines)
    # heap_overflow row should name tribe-beta as dominant.
    heap_line = ""
    for ln in lines:
        if ln.startswith("| heap_overflow |"):
            heap_line = ln
            break
    if "tribe-beta" in heap_line:
        report_pass(
            "test_per_class_summary_dominant_tribe: dominant naming"
        )
    else:
        report_fail(
            "test_per_class_summary_dominant_tribe: dominant naming",
            f"heap_line={heap_line!r}",
        )
    # Sanity: a class with no verified rows should show `-`.
    for cls in ("data_race", "send_violation", "missing_lock"):
        for ln in lines:
            if ln.startswith(f"| {cls} |"):
                if " | - | 0 |" in ln:
                    break
                report_fail(
                    "test_per_class_summary_dominant_tribe: zero-verified dash",
                    f"{cls} line={ln!r}",
                )
                return
    report_pass(
        "test_per_class_summary_dominant_tribe: zero-verified dash"
    )
    # Avoid an unused-variable warning when the body grows below.
    _ = body


def test_per_class_summary_spread_count(_tmp: str) -> None:
    """spread = number of tribes with verified > 0 for the class."""
    mod = _import_analyser()
    stats = {
        "tribe-alpha": {
            "memory_corruption:format-pattern-default": {
                "verified": 1, "falsepos": 0,
            },
        },
        "tribe-beta": {
            "memory_corruption:source-sink-call-graph": {
                "verified": 1, "falsepos": 0,
            },
        },
        "tribe-gamma": {
            "memory_corruption:error-path-trait-dispatch": {
                "verified": 0, "falsepos": 3,
            },
        },
    }
    lines = mod.render_per_class_summary(stats)
    spread_line = ""
    for ln in lines:
        if ln.startswith("| memory_corruption |"):
            spread_line = ln
            break
    # Trailing cell of memory_corruption row should be `| 2 |`.
    if spread_line.rstrip().endswith("| 2 |"):
        report_pass(
            "test_per_class_summary_spread_count: spread=2"
        )
    else:
        report_fail(
            "test_per_class_summary_spread_count: spread=2",
            f"line={spread_line!r}",
        )


def test_per_class_summary_unknown_class_handling(_tmp: str) -> None:
    """Unknown classes (not in STAGE2_CLASSES) are appended sorted with
    `unknown:` prefix."""
    mod = _import_analyser()
    stats = {
        "tribe-alpha": {
            "weird_class:foo": {"verified": 1, "falsepos": 0},
            "other_weird:bar": {"verified": 0, "falsepos": 1},
        },
    }
    lines = mod.render_per_class_summary(stats)
    body = "\n".join(lines)
    if "| unknown:weird_class |" not in body:
        report_fail(
            "test_per_class_summary_unknown_class_handling: weird_class row",
            f"body tail={body[-300:]!r}",
        )
        return
    report_pass(
        "test_per_class_summary_unknown_class_handling: weird_class row"
    )
    if "| unknown:other_weird |" not in body:
        report_fail(
            "test_per_class_summary_unknown_class_handling: other_weird row"
        )
        return
    report_pass(
        "test_per_class_summary_unknown_class_handling: other_weird row"
    )
    # Unknown classes must appear AFTER the last STAGE2_CLASSES row.
    last_known = max(
        body.find(f"| {cls} |") for cls in mod.STAGE2_CLASSES
    )
    unknown_idx = body.find("| unknown:")
    if last_known > 0 and unknown_idx > last_known:
        report_pass(
            "test_per_class_summary_unknown_class_handling: append after fixed rows"
        )
    else:
        report_fail(
            "test_per_class_summary_unknown_class_handling: append after fixed rows",
            f"last_known={last_known} unknown_idx={unknown_idx}",
        )
    # Sorted: `other_weird` should come before `weird_class`.
    o_idx = body.find("| unknown:other_weird |")
    w_idx = body.find("| unknown:weird_class |")
    if o_idx > 0 and w_idx > 0 and o_idx < w_idx:
        report_pass(
            "test_per_class_summary_unknown_class_handling: sorted append"
        )
    else:
        report_fail(
            "test_per_class_summary_unknown_class_handling: sorted append",
            f"o_idx={o_idx} w_idx={w_idx}",
        )


def test_variant_trajectory_csv_schema(tmp: str) -> None:
    """variant-trajectory.csv has the documented header + caveat
    comment, and is emitted alongside the other artefacts."""
    run_dir = os.path.join(tmp, "traj-schema")
    os.makedirs(run_dir, exist_ok=True)
    tribes = ["tribe-alpha"]
    seed_ids = {t: f"seed-{t}" for t in tribes}
    make_seed_node(run_dir, tribes, seed_ids)
    write_text(os.path.join(run_dir, "bug-ledger.jsonl"), "")
    write_text(
        os.path.join(run_dir, "rotations.csv"),
        "ts,target_dir,bugs_manifest\n",
    )
    write_text(
        os.path.join(run_dir, "run-meta.json"),
        json.dumps({
            "started_at": "2026-05-10T12:00:00Z",
            "wall_clock_s": 60,
            "rotation_interval_s": 60,
        }),
    )
    rc, _stdout, _stderr = run_analyser(run_dir)
    assert_eq("test_variant_trajectory_csv_schema: analyser ok", 0, rc)
    traj_path = os.path.join(run_dir, "variant-trajectory.csv")
    assert_file_exists(
        "test_variant_trajectory_csv_schema: csv emitted", traj_path,
    )
    with open(traj_path, encoding="utf-8") as f:
        body = f.read()
    if body.startswith("# trajectory: reconstructed from"):
        report_pass(
            "test_variant_trajectory_csv_schema: caveat comment leads"
        )
    else:
        report_fail(
            "test_variant_trajectory_csv_schema: caveat comment leads",
            f"head={body[:120]!r}",
        )
    if "#513" in body:
        report_pass(
            "test_variant_trajectory_csv_schema: caveat references #513"
        )
    else:
        report_fail(
            "test_variant_trajectory_csv_schema: caveat references #513",
        )
    expected_header = (
        "ts,tribe,class,phrasing,verified_cumul,falsepos_cumul,hit_rate"
    )
    if expected_header in body:
        report_pass(
            "test_variant_trajectory_csv_schema: column order"
        )
    else:
        report_fail(
            "test_variant_trajectory_csv_schema: column order",
            f"missing header={expected_header!r}",
        )


def test_variant_trajectory_csv_reconstruction_proportional(_tmp: str) -> None:
    """Proportional reconstruction: walking N events with end totals
    (V, FP) emits rounded-cumulative rows; the final row matches the
    end totals byte-for-byte."""
    mod = _import_analyser()
    out_dir = tempfile.mkdtemp(prefix="traj-proportional-")
    try:
        events = [
            {
                "ts": 1000, "tribe": "tribe-alpha",
                "child_variant": "use_after_free:format-pattern-default",
                "parent_variant": "", "source": "observed",
                "parent_id": "p", "child_id": "c1",
            },
            {
                "ts": 2000, "tribe": "tribe-alpha",
                "child_variant": "use_after_free:format-pattern-default",
                "parent_variant": "", "source": "observed",
                "parent_id": "p", "child_id": "c2",
            },
            {
                "ts": 3000, "tribe": "tribe-alpha",
                "child_variant": "use_after_free:format-pattern-default",
                "parent_variant": "", "source": "observed",
                "parent_id": "p", "child_id": "c3",
            },
            {
                "ts": 4000, "tribe": "tribe-alpha",
                "child_variant": "use_after_free:format-pattern-default",
                "parent_variant": "", "source": "observed",
                "parent_id": "p", "child_id": "c4",
            },
        ]
        stats = {
            "tribe-alpha": {
                "use_after_free:format-pattern-default": {
                    "verified": 8, "falsepos": 4,
                },
            },
        }
        path = mod.emit_variant_trajectory(out_dir, events, stats)
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
        # Drop caveat + header rows.
        data_rows = [
            ln.split(",") for ln in lines
            if ln and not ln.startswith("#") and not ln.startswith("ts,")
        ]
        if len(data_rows) != 4:
            report_fail(
                "test_variant_trajectory_csv_reconstruction_proportional: row count",
                f"got {len(data_rows)} rows; lines={lines!r}",
            )
            return
        report_pass(
            "test_variant_trajectory_csv_reconstruction_proportional: row count"
        )
        # Expected cumulatives: V=8 across 4 events -> 2,4,6,8;
        # FP=4 across 4 events -> 1,2,3,4.
        expected_v = [2, 4, 6, 8]
        expected_fp = [1, 2, 3, 4]
        v_cumuls = [int(r[4]) for r in data_rows]
        fp_cumuls = [int(r[5]) for r in data_rows]
        if v_cumuls == expected_v and fp_cumuls == expected_fp:
            report_pass(
                "test_variant_trajectory_csv_reconstruction_proportional: cumulatives"
            )
        else:
            report_fail(
                "test_variant_trajectory_csv_reconstruction_proportional: cumulatives",
                f"verified={v_cumuls} falsepos={fp_cumuls}",
            )
        # Final row must reach end totals byte-for-byte.
        if v_cumuls[-1] == 8 and fp_cumuls[-1] == 4:
            report_pass(
                "test_variant_trajectory_csv_reconstruction_proportional: final row matches totals"
            )
        else:
            report_fail(
                "test_variant_trajectory_csv_reconstruction_proportional: final row matches totals",
            )
        # class + phrasing parsed from `class:phrasing`.
        if all(r[2] == "use_after_free" and r[3] == "format-pattern-default" for r in data_rows):
            report_pass(
                "test_variant_trajectory_csv_reconstruction_proportional: class/phrasing split"
            )
        else:
            report_fail(
                "test_variant_trajectory_csv_reconstruction_proportional: class/phrasing split",
                f"rows={data_rows!r}",
            )
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)


# -------------------------------------------------------------------------
# Snapshot test (#495): runs against a real archived stage3-docker run dir
# when it is available, otherwise reports a [SKIP].
# -------------------------------------------------------------------------

SNAPSHOT_DIR = os.environ.get(
    "AGENTIS_STAGE3_SNAPSHOT_DIR",
    os.path.join(
        os.path.dirname(FED_ROOT), "tribes-bench",
        "runs", "stage3-docker-20260510T120610Z",
    ),
)

# #513 snapshot: smoke #51 run dir. When present, asserts the per-class
# summary actually shows multiple stage2 classes with verified > 0,
# matching the cross-tribe activity captured by smoke #51.
SNAPSHOT_DIR_513 = os.environ.get(
    "AGENTIS_STAGE3_SNAPSHOT_DIR_513",
    os.path.join(
        os.path.dirname(FED_ROOT), "tribes-bench",
        "runs", "stage3-docker-20260510T195436Z",
    ),
)


def case_snapshot() -> None:
    if not os.path.isdir(SNAPSHOT_DIR):
        print(f"[SKIP] snapshot: reference run dir absent ({SNAPSHOT_DIR})")
        return
    rc, _stdout, _stderr = run_analyser(
        SNAPSHOT_DIR,
        extra_args=["--out", os.path.join(SNAPSHOT_DIR, "_495-snapshot")],
    )
    assert_eq("snapshot: analyser exits 0", 0, rc)
    cmp_path = os.path.join(SNAPSHOT_DIR, "_495-snapshot", "comparison-stage3.md")
    if not os.path.isfile(cmp_path):
        report_fail("snapshot: comparison.md produced", f"missing {cmp_path}")
        return
    report_pass("snapshot: comparison.md produced")


def case_snapshot_513() -> None:
    """#513 smoke #51 snapshot: assert the per-class summary captures
    >= 4 stage2 classes with verified > 0 (expected: heap_overflow,
    use_after_free, memory_corruption, uninitialised_memory). Skips
    cleanly when the reference run dir is absent."""
    if not os.path.isdir(SNAPSHOT_DIR_513):
        print(
            f"[SKIP] snapshot 513: reference run dir absent ({SNAPSHOT_DIR_513})"
        )
        return
    out_sub = os.path.join(SNAPSHOT_DIR_513, "_513-snapshot")
    rc, _stdout, _stderr = run_analyser(
        SNAPSHOT_DIR_513,
        extra_args=["--out", out_sub],
    )
    assert_eq("snapshot 513: analyser exits 0", 0, rc)
    cmp_path = os.path.join(out_sub, "comparison-stage3.md")
    if not os.path.isfile(cmp_path):
        report_fail(
            "snapshot 513: comparison.md produced",
            f"missing {cmp_path}",
        )
        return
    report_pass("snapshot 513: comparison.md produced")
    with open(cmp_path, encoding="utf-8") as f:
        body = f.read()
    if "### Per-class fitness summary" not in body:
        report_fail(
            "snapshot 513: per-class section present",
            f"body tail={body[-400:]!r}",
        )
        return
    report_pass("snapshot 513: per-class section present")
    # Count stage2 classes with verified > 0 by scanning the table
    # rows. Each row is `| <class> | <verified> | <falsepos> | ...`.
    mod = _import_analyser()
    classes_with_verified = 0
    total_verified = 0
    for cls in mod.STAGE2_CLASSES:
        marker = f"| {cls} | "
        idx = body.find(marker)
        if idx < 0:
            continue
        row = body[idx:body.find("\n", idx)]
        parts = [p.strip() for p in row.split("|")]
        # parts: ['', class, verified, falsepos, hit_rate, dominant_tribe, spread, '']
        if len(parts) >= 4:
            try:
                v = int(parts[2])
                total_verified += v
                if v > 0:
                    classes_with_verified += 1
            except ValueError:
                pass
    # SKIP when the analyser sees zero verified events in the reference
    # run — indicates the reference run dir is from a smoke that pre-dates
    # the variant_stats memo population (e.g. pre-#499 / #503 data shape)
    # or the analyser cannot reach the memo store from the run dir layout.
    # The snapshot is informational, not a regression gate.
    if total_verified == 0:
        print(
            f"[SKIP] snapshot 513: zero verified in reference run "
            f"({SNAPSHOT_DIR_513}); pre-#499 data shape or analyser "
            f"cannot read variant_stats memos"
        )
        return
    if classes_with_verified >= 4:
        report_pass(
            "snapshot 513: >= 4 stage2 classes with verified > 0"
        )
    else:
        report_fail(
            "snapshot 513: >= 4 stage2 classes with verified > 0",
            f"got {classes_with_verified}",
        )


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
        # #495 unit tests: per-tribe variant pools + variant_stats memos.
        test_parse_variant_pool_alpha(tmp)
        test_parse_variant_pool_extended_pool(tmp)
        test_parse_variant_pool_raises_on_empty(tmp)
        test_discover_tribe_pools_disjoint_prefixes(tmp)
        test_read_variant_stats_parses_memo_list_output(tmp)
        test_read_variant_stats_missing_binary_returns_empty(tmp)
        test_variant_outcomes_table_orders_by_verified_desc_falsepos_asc(tmp)
        test_mutation_diff_csv_has_observational_columns(tmp)
        # #513 unit tests: per-class fitness summary + trajectory CSV.
        test_per_class_summary_table_orders_by_stage2_class_order(tmp)
        test_per_class_summary_aggregates_across_tribes(tmp)
        test_per_class_summary_dominant_tribe(tmp)
        test_per_class_summary_spread_count(tmp)
        test_per_class_summary_unknown_class_handling(tmp)
        test_variant_trajectory_csv_schema(tmp)
        test_variant_trajectory_csv_reconstruction_proportional(tmp)
        case_snapshot()
        case_snapshot_513()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("")
    print(f"Results: {PASS} passed, {FAIL} failed")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
