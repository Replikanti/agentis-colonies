#!/usr/bin/env python3
"""write-ab-manifest.py -- experiment-manifest.json writer for
run-ab-experiment.sh (trading-binance, #1947).

Extracted from the `PYMANIFEST` heredoc that used to live inside
run-ab-experiment.sh: a heredoc supplies python's stdin, so the piped
5-tuple record stream was discarded and `runs` was always `[]`
(shellcheck SC2259). As a standalone helper the record stream reaches
stdin unobstructed.

Argv (all required, in this order):

    1 out_path              manifest path to write
    2 experiment_ts         UTC stamp shared by every run dir
    3 symbol                Binance futures symbol
    4 timeframe             candle interval (30m | 1h | 1d)
    5 start                 UTC YYYY-MM-DD lower bound ("" = first shard)
    6 end                   UTC YYYY-MM-DD upper bound ("" = last shard)
    7 replay_speed          replay multiplier (int)
    8 n_replicates_per_arm  replicates per arm (int)
    9 llm_model             REPLAY_OPENAI_MODEL or ""

Stdin: the flattened RUNS_RECORD stream -- NUL-separated 5-tuples
(NUL-separated so run-dir paths containing spaces survive intact):

    arm \\0 run_idx \\0 run_dir \\0 threshold \\0 exit_code \\0 ...

Each tuple becomes one `runs[]` entry with the keys
`arm` / `run_idx` / `run_dir` / `strategist_prompt_evolution_threshold` /
`exit_code` -- the shape analyze-ab-results.py's load_manifest() and
render_report() consume. An element count that is not a multiple of 5 is
a malformed stream: nothing is written and the exit code is 1. Empty
stdin is legal and yields `runs: []` with the metadata header intact.

Stdlib only.

Usage: run-ab-experiment.sh internal; not intended for direct operator use.
"""

import json
import os
import sys

out_path = sys.argv[1]
manifest = {
    "experiment_ts": sys.argv[2],
    "symbol": sys.argv[3],
    "timeframe": sys.argv[4],
    "start": sys.argv[5],
    "end": sys.argv[6],
    "replay_speed": int(sys.argv[7]),
    "n_replicates_per_arm": int(sys.argv[8]),
    "llm_model": sys.argv[9],
    "arms": {
        "control": {
            "strategist_prompt_evolution_threshold": 999,
            "description": "prompt evolution effectively off (baseline)",
        },
        "treatment": {
            "strategist_prompt_evolution_threshold": 3,
            "description": "prompt evolution armed (emergence)",
        },
    },
    "runs": [],
}
data = sys.stdin.buffer.read()
if data:
    parts = data.split(b"\x00")
    # Trailing empty element from final NUL.
    if parts and parts[-1] == b"":
        parts = parts[:-1]
    if len(parts) % 5 != 0:
        sys.stderr.write(
            "run-ab-experiment: malformed RUNS_RECORD stream "
            "(len=" + str(len(parts)) + ", expected multiple of 5)\n"
        )
        sys.exit(1)
    for i in range(0, len(parts), 5):
        arm = parts[i].decode("utf-8")
        run_idx = int(parts[i + 1])
        run_dir = parts[i + 2].decode("utf-8")
        threshold = int(parts[i + 3])
        exit_code = int(parts[i + 4])
        manifest["runs"].append({
            "arm": arm,
            "run_idx": run_idx,
            "run_dir": run_dir,
            "strategist_prompt_evolution_threshold": threshold,
            "exit_code": exit_code,
        })
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
