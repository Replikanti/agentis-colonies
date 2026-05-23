#!/usr/bin/env python3
"""persistent-snapshot.py - Snapshot curated memo namespaces to disk.

Phase 5 PR-A of #626 (cross-run learning). Host-side helper invoked at
run-end by `research-foundry/tools/run-research.sh` after `signal_shutdown`
and before `emit_step "run-research: done"`. Reads a fixed, hardcoded set
of memo keys from the merged research-foundry container via
`podman exec <container> agentis memo get <key>` and writes the resulting
dict to `<output_dir>/memo-snapshot.json` atomically (tmpfile + rename).

This PR scaffolds the persistent dir + write path only. PR-B will read the
snapshot at bootstrap to bias new replicas toward fit specialties; PR-C
will aggregate cross-run fitness across snapshots. Nothing in-tree reads
the snapshot yet.

KB cross-run persistence (#750): in addition to the memo snapshot, the
helper also dumps the on-disk KnowledgeBase via `agentis knowledge export`
to `<output_dir>/knowledge-snapshot.json`. The KB lives at
`<root>/.agentis/knowledge/` as one JSON-per-item (out of band of the memo
store), so the existing memo-only snapshot would otherwise leak it across
runs. Failure of the KB export is non-fatal: the file is dropped, the
memo snapshot still lands, and run-research.sh proceeds.

Schema:
    {
      "schema": 1,
      "snapshot_ts": "<UTC ISO-8601>",
      "container": "<container_name>",
      "keys": { "<memo key>": "<value>", ... }
    }

Side-effects:
- Writes `<output_dir>/SCHEMA_VERSION` (single line `1\n`) on first
  invocation. If the file exists with a value != 1 the helper logs a
  clear warning on stderr and exits non-zero without overwriting
  memo-snapshot.json (run-research.sh treats the failure as non-fatal).

Per-call resilience:
- The container may already be shutting down. Each `podman exec` is
  retried up to 3 times with a 1s sleep between attempts; non-zero
  return on the final attempt yields an empty string for that key
  (a missing or unreadable memo is not fatal).
- A completely failed run (e.g. `podman` not on PATH or container
  unreachable) exits non-zero before any tmp/final file is created so
  the orchestrator never sees a half-formed JSON.

Pattern: this is a heredoc-free Python helper following the precedent
of `tools/auto-promote-config-parser.py` and `tools/auto-promote-decisions.py`
(extracted from `auto-promote.sh` per #245 to avoid the macOS bash 3.2
parser bug).

Usage:
    persistent-snapshot.py --container <name> --output-dir <dir>
    persistent-snapshot.py --help
"""
import datetime
import json
import os
import subprocess
import sys
import time


SCHEMA_VERSION = 1

EXACT_KEYS = [
    "formulator:learned_known_topics",
    "formulator:learned_successful_topics",
    "editor:learned_pitfalls",
    "feedback:hitl_rejects",
]

PREFIX_GLOBS = [
    "feedback:hitl_reject_reason:claim-",
    "feedback:hitl_reject_class:claim-",
    # M98 v3 evolved-prompt state per explorer pid (#739). The
    # _evolve_exploration_prompt loop in research-foundry/explorer/agents/
    # explorer.ag writes `:exploration_prompt` (current variant body),
    # `:exploration_generation` (lineage step within the gen-cap window),
    # `:lineage_id` (bumped on gen-cap reset), and `:specialty` (claimed
    # at first tick from the bootstrap-seeded pool). Carrying these four
    # across runs lets the next bootstrap restore the variant pool so
    # M98 v3 fitness pressure compounds run-over-run instead of
    # restarting from the seed each container relaunch.
    "explorer:",
]

# Suffix filter for the `explorer:` prefix glob. The glob would otherwise
# catch per-tick noise like `explorer:<pid>:code:tick-N` /
# `explorer:<pid>:output:tick-N` (cb-budget bloat). Snapshot only the
# specific suffixes that make up the cross-run evolved-prompt state.
EXPLORER_PERSISTENT_SUFFIXES = (
    ":exploration_prompt",
    ":exploration_generation",
    ":lineage_id",
    ":specialty",
)

CONFIDENCE_COLONIES = [
    "explorer",
    "noticer",
    "skeptic",
    "formulator",
    "verifier",
    "novelty",
    "arxiv-search",
    "oeis-search",
    "groupprops-search",
    "scholar-search",
    "prior_advocate",
    "auditor",
    "introducer",
    "theorist",
    "computer",
    "editor",
    "reviewer",
    "submitter",
]

RETRY_ATTEMPTS = 3
RETRY_SLEEP_S = 1.0


def _print_help_and_exit():
    sys.stdout.write(__doc__ or "")
    sys.stdout.write("\n")
    sys.exit(0)


def _parse_args(argv):
    container = None
    output_dir = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            _print_help_and_exit()
        elif a == "--container":
            if i + 1 >= len(argv):
                sys.stderr.write("persistent-snapshot: --container requires a value\n")
                sys.exit(2)
            container = argv[i + 1]
            i += 2
            continue
        elif a == "--output-dir":
            if i + 1 >= len(argv):
                sys.stderr.write("persistent-snapshot: --output-dir requires a value\n")
                sys.exit(2)
            output_dir = argv[i + 1]
            i += 2
            continue
        else:
            sys.stderr.write("persistent-snapshot: unknown argument: " + a + "\n")
            sys.exit(2)
    if container is None:
        sys.stderr.write("persistent-snapshot: --container is required\n")
        sys.exit(2)
    if output_dir is None:
        sys.stderr.write("persistent-snapshot: --output-dir is required\n")
        sys.exit(2)
    return container, output_dir


def _podman_exec(container, args):
    """Run `podman exec <container> <args>`. Returns CompletedProcess.

    Returns None if podman itself is unreachable (FileNotFoundError),
    which the caller treats as a fatal pre-flight failure (no JSON written).
    """
    cmd = ["podman", "exec", container] + list(args)
    try:
        return subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except FileNotFoundError:
        return None


def _memo_get(container, key):
    """Run `agentis memo get <key>` inside the container with retry.

    Returns the stdout string with trailing CR/LF stripped, or "" if all
    attempts failed (missing memo or container shutdown).
    """
    last_rc = None
    for attempt in range(RETRY_ATTEMPTS):
        result = _podman_exec(container, ["agentis", "memo", "get", key])
        if result is None:
            return ""
        if result.returncode == 0:
            return result.stdout.decode("utf-8", errors="replace").rstrip("\r\n")
        last_rc = result.returncode
        if attempt < RETRY_ATTEMPTS - 1:
            time.sleep(RETRY_SLEEP_S)
    sys.stderr.write(
        "persistent-snapshot: memo get '" + key + "' failed after "
        + str(RETRY_ATTEMPTS) + " attempts (last rc=" + str(last_rc) + ")\n"
    )
    return ""


def _memo_list_keys(container):
    """Run `agentis memo list` and return the line-split key set.

    Used to expand prefix-globs (`feedback:hitl_reject_reason:claim-*`).
    Returns an empty list if the call fails on every attempt -- the
    helper still writes the exact-key entries so a flaky list call
    does not blank the whole snapshot.
    """
    for attempt in range(RETRY_ATTEMPTS):
        result = _podman_exec(container, ["agentis", "memo", "list"])
        if result is None:
            return []
        if result.returncode == 0:
            raw = result.stdout.decode("utf-8", errors="replace")
            keys = []
            for line in raw.splitlines():
                line = line.strip()
                if line:
                    keys.append(line)
            return keys
        if attempt < RETRY_ATTEMPTS - 1:
            time.sleep(RETRY_SLEEP_S)
    sys.stderr.write(
        "persistent-snapshot: memo list failed after "
        + str(RETRY_ATTEMPTS) + " attempts (prefix-globs will be empty)\n"
    )
    return []


def _check_schema_version_file(output_dir):
    """Validate SCHEMA_VERSION file. Write it if absent; return ok bool.

    On version mismatch (file contents != "1"), log a clear warning and
    return False. The caller exits non-zero in that case so the shell
    wrapper can surface "persistent snapshot failed (non-fatal)".
    """
    sv_path = os.path.join(output_dir, "SCHEMA_VERSION")
    if not os.path.exists(sv_path):
        try:
            with open(sv_path, "w") as f:
                f.write(str(SCHEMA_VERSION) + "\n")
        except OSError as e:
            sys.stderr.write(
                "persistent-snapshot: cannot write " + sv_path + ": " + str(e) + "\n"
            )
            return False
        return True
    try:
        with open(sv_path, "r") as f:
            existing = f.read().strip()
    except OSError as e:
        sys.stderr.write(
            "persistent-snapshot: cannot read " + sv_path + ": " + str(e) + "\n"
        )
        return False
    if existing != str(SCHEMA_VERSION):
        sys.stderr.write(
            "persistent-snapshot: SCHEMA_VERSION mismatch at " + sv_path
            + " (found '" + existing + "', expected '" + str(SCHEMA_VERSION)
            + "'). Refusing to overwrite memo-snapshot.json. Resolve manually "
            + "(operator must reconcile schema before next run).\n"
        )
        return False
    return True


def _atomic_write_json(output_path, payload):
    """Write payload as JSON via tmpfile + rename in the same dir."""
    out_dir = os.path.dirname(output_path) or "."
    tmp_path = output_path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
        f.write("\n")
        f.flush()
        try:
            os.fsync(f.fileno())
        except OSError:
            pass
    os.replace(tmp_path, output_path)
    try:
        dir_fd = os.open(out_dir, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError:
        pass


def _knowledge_export(container, output_dir):
    """Dump the on-disk KnowledgeBase via `agentis knowledge export` (#750).

    Writes raw stdout to `<output_dir>/knowledge-snapshot.json` atomically
    (tmpfile + rename). Failure is non-fatal: stderr a note and return
    False so the orchestrator's memo-snapshot exit code is unaffected.
    """
    output_path = os.path.join(output_dir, "knowledge-snapshot.json")
    tmp_path = output_path + ".tmp"
    last_rc = None
    for attempt in range(RETRY_ATTEMPTS):
        result = _podman_exec(container, ["agentis", "knowledge", "export"])
        if result is None:
            sys.stderr.write(
                "persistent-snapshot: 'podman' binary not on PATH while "
                + "exporting KB; skipping knowledge-snapshot.json.\n"
            )
            return False
        if result.returncode == 0:
            try:
                with open(tmp_path, "wb") as f:
                    f.write(result.stdout)
                    f.flush()
                    try:
                        os.fsync(f.fileno())
                    except OSError:
                        pass
                os.replace(tmp_path, output_path)
            except OSError as e:
                sys.stderr.write(
                    "persistent-snapshot: cannot write " + output_path
                    + ": " + str(e) + " (KB snapshot dropped, non-fatal)\n"
                )
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
                return False
            sys.stdout.write(
                "persistent-snapshot: wrote " + output_path
                + " (" + str(len(result.stdout)) + " bytes)\n"
            )
            return True
        last_rc = result.returncode
        if attempt < RETRY_ATTEMPTS - 1:
            time.sleep(RETRY_SLEEP_S)
    sys.stderr.write(
        "persistent-snapshot: 'agentis knowledge export' failed after "
        + str(RETRY_ATTEMPTS) + " attempts (last rc=" + str(last_rc)
        + "); KB snapshot dropped (non-fatal).\n"
    )
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    return False


def snapshot_keys(container, output_dir):
    """Snapshot the curated memo keys into <output_dir>/memo-snapshot.json.

    Pre-flight: ensure `podman exec <container> true` succeeds. Aborts
    before writing anything if podman is missing OR if the container is
    unreachable; that way the orchestrator never sees a half-formed
    JSON file.
    """
    probe = _podman_exec(container, ["true"])
    if probe is None:
        sys.stderr.write(
            "persistent-snapshot: 'podman' binary not on PATH; aborting "
            + "(no snapshot written).\n"
        )
        return 3
    if probe.returncode != 0:
        sys.stderr.write(
            "persistent-snapshot: 'podman exec " + container + " true' failed "
            + "(rc=" + str(probe.returncode) + "); aborting (no snapshot written).\n"
        )
        return 3

    try:
        os.makedirs(output_dir, exist_ok=True)
    except OSError as e:
        sys.stderr.write(
            "persistent-snapshot: cannot create " + output_dir + ": " + str(e) + "\n"
        )
        return 4

    if not _check_schema_version_file(output_dir):
        return 5

    keys_to_snapshot = list(EXACT_KEYS)
    keys_to_snapshot.extend(c + ":confidence" for c in CONFIDENCE_COLONIES)

    if PREFIX_GLOBS:
        listed = _memo_list_keys(container)
        for prefix in PREFIX_GLOBS:
            for k in listed:
                if not k.startswith(prefix):
                    continue
                # The `explorer:` prefix would otherwise catch noisy
                # per-tick keys (e.g. `explorer:<pid>:code:tick-N`).
                # Restrict it to the cross-run evolved-prompt state
                # suffixes only (#739).
                if prefix == "explorer:" and not k.endswith(EXPLORER_PERSISTENT_SUFFIXES):
                    continue
                keys_to_snapshot.append(k)

    seen = set()
    deduped = []
    for k in keys_to_snapshot:
        if k in seen:
            continue
        seen.add(k)
        deduped.append(k)

    snapshot = {}
    for key in deduped:
        snapshot[key] = _memo_get(container, key)

    payload = {
        "schema": SCHEMA_VERSION,
        "snapshot_ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "container": container,
        "keys": snapshot,
    }

    output_path = os.path.join(output_dir, "memo-snapshot.json")
    try:
        _atomic_write_json(output_path, payload)
    except OSError as e:
        sys.stderr.write(
            "persistent-snapshot: cannot write " + output_path + ": " + str(e) + "\n"
        )
        return 6

    sys.stdout.write("persistent-snapshot: wrote " + output_path + " (" + str(len(snapshot)) + " keys)\n")

    # KB cross-run persistence (#750). Dump the on-disk KnowledgeBase to
    # knowledge-snapshot.json so run-research.sh's bootstrap can import
    # it back before colony daemons spawn. Failure-isolated: a missing or
    # corrupt KB export must not flip the memo-snapshot return code.
    _knowledge_export(container, output_dir)

    return 0


def main(argv):
    container, output_dir = _parse_args(argv)
    return snapshot_keys(container, output_dir)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
