#!/usr/bin/env python3
"""tools/cross-fed-bridge.py -- Bidirectional memo <-> host-dir sync for
the `cross-fed:*` namespace defined in doc/cross-fed-memo.md.

Phase 8 PR-1 of #629. PR-1 is the foundation layer: no federation reads
or writes `cross-fed:*` keys yet -- that's PR-2 (exporter from
research-foundry) and PR-3 (importer scaffold). The sidecar this script
backs is therefore a no-op against an empty host dir and against every
existing federation. PR-1 only ships the contract + storage.

Commands:

    cross-fed-bridge.py sync <fed_dir> <host_dir> [--lock-mode MODE]
        Run one bidirectional sync pass between a federation's memo
        store and the shared host dir. --lock-mode is one of:
            acquire       -- block until the .lock is held (default)
            nonblocking   -- try once; exit 0 if held by another process
            release       -- no-op placeholder for symmetry; the lock is
                             released when the process exits
        sync exits 0 on a clean pass, non-zero only on an unrecoverable
        I/O error (the wrapper shell script treats both fed_dir and
        host_dir as creatable on demand).

    cross-fed-bridge.py merge-ledgers <host_dir>
        Concatenate every <host_dir>/../<fed>/.agentis/pollination-ledger.jsonl
        into <host_dir>/pollination-ledger.jsonl, preserving timestamp
        order. Per-fed ledger paths are passed via stdin (one path per
        line) for testability; if stdin is a tty the helper falls back
        to globbing <host_dir>'s parent for `*/.agentis/pollination-ledger.jsonl`.

The script is pure stdlib: no PyYAML, no third-party deps. Targets the
same Python floor as the rest of `tools/` (3.9+).
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Iterable

# --- Constants -------------------------------------------------------

# Memo files in `.agentis/memo/` carry a `.jsonl` suffix in the agentis
# runtime layout. The bridge mirrors one host file per memo key; the
# memo-side filename always ends in `.jsonl`, the host-side filename
# uses a kind-specific extension (`.json` for structured records,
# `.txt` for raw bodies).
MEMO_SUFFIX = ".jsonl"
KEY_PREFIX = "cross-fed:"

# Memo subdir under `<fed_dir>/.agentis/memo/`.
MEMO_SUBDIR = Path(".agentis") / "memo"

# Host-dir subdir per kind. Keys flatten `cross-fed:<kind>:...` into
# `<host_dir>/<kind>/...`.
KIND_TO_DIR = {
    "method": "method",
    "method-body": "method-body",
    "fitness": "fitness",
    "applicable-to": "applicable-to",
    "import-log": "import-log",
    "export-suppress": "export-suppress",
    "opt-out": "opt-out",
    "adopt-queue": "adopt-queue",
}

# File extension on the host side. `method-body` carries raw prompt
# text; everything else is structured JSON.
KIND_TO_EXT = {
    "method": ".json",
    "method-body": ".txt",
    "fitness": ".json",
    "applicable-to": ".json",
    "import-log": ".json",
    "export-suppress": ".json",
    "opt-out": ".json",
    "adopt-queue": ".json",
}

# Filenames written under <host_dir>/ that are NOT mirrored memo keys.
HOST_DIR_RESERVED = frozenset({".lock", ".gitkeep", "README.md", "pollination-ledger.jsonl"})


# --- Lock ------------------------------------------------------------


def acquire_lock(host_dir: Path, mode: str = "acquire"):
    """Acquire an advisory flock on <host_dir>/.lock.

    Returns the open file handle on success (caller MUST keep it alive
    for the duration of the work to hold the lock). Returns None when
    mode='nonblocking' and the lock is held by another process.

    The lock is per open-file-description: when the caller process
    exits, the kernel releases the lock automatically. No explicit
    release path is required (and the 'release' mode is a no-op
    placeholder for shell symmetry).
    """
    host_dir.mkdir(parents=True, exist_ok=True)
    lock_path = host_dir / ".lock"
    handle = open(lock_path, "w")
    flags = fcntl.LOCK_EX
    if mode == "nonblocking":
        flags |= fcntl.LOCK_NB
    try:
        fcntl.flock(handle.fileno(), flags)
    except BlockingIOError:
        handle.close()
        return None
    return handle


# --- Key/path helpers -----------------------------------------------


def _split_key(key: str) -> tuple[str, list[str]] | None:
    """Parse a cross-fed:<kind>:<...> memo key into (kind, parts).

    Returns None when the key shape is unrecognised. The bridge skips
    unrecognised keys rather than crashing so an operator can stage
    experimental kinds without taking the sidecar down.
    """
    if not key.startswith(KEY_PREFIX):
        return None
    rest = key[len(KEY_PREFIX):]
    parts = rest.split(":")
    if len(parts) < 2:
        return None
    kind = parts[0]
    if kind not in KIND_TO_DIR:
        return None
    return kind, parts[1:]


def _memo_key_to_host_path(host_dir: Path, key: str) -> Path | None:
    parsed = _split_key(key)
    if parsed is None:
        return None
    kind, parts = parsed
    ext = KIND_TO_EXT[kind]
    sub = KIND_TO_DIR[kind]
    # Last component carries the file basename; everything before it is
    # a nested directory path. `cross-fed:method:<source-fed>:<method-id>`
    # therefore maps to `<host_dir>/method/<source-fed>/<method-id>.json`.
    *dirs, leaf = parts
    target_dir = host_dir / sub
    for d in dirs:
        target_dir = target_dir / d
    return target_dir / (leaf + ext)


def _host_path_to_memo_key(host_dir: Path, host_path: Path) -> str | None:
    try:
        rel = host_path.relative_to(host_dir)
    except ValueError:
        return None
    parts = rel.parts
    if not parts:
        return None
    if parts[0] in HOST_DIR_RESERVED:
        return None
    if parts[0] not in KIND_TO_DIR.values():
        return None
    # Strip the extension off the leaf component.
    leaf = parts[-1]
    stem = leaf
    for ext in (".json", ".txt", ".jsonl"):
        if leaf.endswith(ext):
            stem = leaf[: -len(ext)]
            break
    components = [parts[0], *parts[1:-1], stem]
    return KEY_PREFIX + ":".join(components)


def _memo_path_to_key(memo_path: Path) -> str | None:
    name = memo_path.name
    if not name.endswith(MEMO_SUFFIX):
        return None
    key = name[: -len(MEMO_SUFFIX)]
    if not key.startswith(KEY_PREFIX):
        return None
    return key


def _key_to_memo_path(memo_dir: Path, key: str) -> Path:
    return memo_dir / (key + MEMO_SUFFIX)


# --- Read / write primitives ----------------------------------------


def _read_memo_value(memo_path: Path) -> str:
    """Return the latest value for a memo key.

    agentis memo store appends one JSON record per write to
    `<key>.jsonl`. The bridge reads the last non-empty line; its
    `value` field holds the payload. Falls back to the raw file
    content when the line shape is not the expected
    `{"value": ..., ...}` record.
    """
    try:
        raw = memo_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    last = ""
    for line in raw.splitlines():
        if line.strip():
            last = line
    if not last:
        return ""
    try:
        rec = json.loads(last)
        if isinstance(rec, dict) and "value" in rec:
            v = rec["value"]
            if isinstance(v, str):
                return v
            return json.dumps(v, sort_keys=True, separators=(",", ":"))
    except json.JSONDecodeError:
        pass
    return last


def _write_memo_value(memo_path: Path, value: str) -> None:
    """Append a new JSON record to a memo key's `.jsonl` file.

    The format mirrors what `agentis memo set` writes: a single-line
    `{"value": <payload>}` object. PR-1 uses the bridge as a
    file-level data channel and never runs `agentis memo set`
    from inside the sidecar -- that would require the agentis CLI on
    every host, which is not a contract this script can enforce.
    Direct append keeps the bridge self-contained.
    """
    memo_path.parent.mkdir(parents=True, exist_ok=True)
    # Try to parse the incoming value as structured JSON so the memo
    # record carries the native type the writer intended; fall back to
    # a string value.
    parsed_value: object
    try:
        parsed_value = json.loads(value)
    except (json.JSONDecodeError, TypeError):
        parsed_value = value
    record = {"value": parsed_value}
    serialised = json.dumps(record, sort_keys=True, separators=(",", ":"))
    with memo_path.open("a", encoding="utf-8") as f:
        f.write(serialised + "\n")


def _read_host_value(host_path: Path) -> str:
    try:
        return host_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _write_host_atomic(host_path: Path, value: str) -> bool:
    """Write `value` to `host_path` if the on-disk content differs.

    Returns True when a write happened, False when the file already
    matched (sha256 dedupe). The dedupe keeps a re-sync no-op on the
    host filesystem so cron-style invocations do not churn mtimes.
    """
    host_path.parent.mkdir(parents=True, exist_ok=True)
    new_bytes = value.encode("utf-8")
    new_sha = hashlib.sha256(new_bytes).hexdigest()
    if host_path.exists():
        try:
            existing = host_path.read_bytes()
            if hashlib.sha256(existing).hexdigest() == new_sha:
                return False
        except OSError:
            pass
    tmp = host_path.with_suffix(host_path.suffix + ".tmp")
    tmp.write_bytes(new_bytes)
    os.replace(tmp, host_path)
    return True


# --- Sync passes -----------------------------------------------------


def _iter_memo_keys(memo_dir: Path) -> Iterable[Path]:
    if not memo_dir.is_dir():
        return []
    out = []
    for entry in memo_dir.iterdir():
        if not entry.is_file():
            continue
        if not entry.name.endswith(MEMO_SUFFIX):
            continue
        if not entry.name.startswith(KEY_PREFIX):
            continue
        out.append(entry)
    out.sort()
    return out


def _iter_host_files(host_dir: Path) -> Iterable[Path]:
    if not host_dir.is_dir():
        return []
    out = []
    for kind_dir_name in sorted(KIND_TO_DIR.values()):
        kind_dir = host_dir / kind_dir_name
        if not kind_dir.is_dir():
            continue
        for path in sorted(kind_dir.rglob("*")):
            if not path.is_file():
                continue
            if path.name in HOST_DIR_RESERVED:
                continue
            out.append(path)
    return out


def sync_memo_to_host(fed_dir: Path, host_dir: Path) -> int:
    """Mirror every cross-fed:* memo key in fed_dir to host_dir.

    Returns the number of host files written (excluding dedupe no-ops).
    """
    memo_dir = fed_dir / MEMO_SUBDIR
    written = 0
    for memo_path in _iter_memo_keys(memo_dir):
        key = _memo_path_to_key(memo_path)
        if key is None:
            continue
        host_path = _memo_key_to_host_path(host_dir, key)
        if host_path is None:
            continue
        value = _read_memo_value(memo_path)
        if _write_host_atomic(host_path, value):
            written += 1
    return written


def sync_host_to_memo(host_dir: Path, fed_dir: Path) -> int:
    """Mirror every file under host_dir into fed_dir's memo store.

    Returns the number of memo records appended (one per changed
    host file).
    """
    memo_dir = fed_dir / MEMO_SUBDIR
    appended = 0
    for host_path in _iter_host_files(host_dir):
        key = _host_path_to_memo_key(host_dir, host_path)
        if key is None:
            continue
        memo_path = _key_to_memo_path(memo_dir, key)
        host_value = _read_host_value(host_path)
        existing_value = _read_memo_value(memo_path) if memo_path.exists() else None
        # Dedupe by comparing the canonical-JSON form of both sides so
        # whitespace + key ordering differences in the host file don't
        # trigger redundant appends.
        if existing_value is not None:
            try:
                left = json.loads(existing_value)
                right = json.loads(host_value)
                if json.dumps(left, sort_keys=True) == json.dumps(right, sort_keys=True):
                    continue
            except (json.JSONDecodeError, TypeError):
                if existing_value == host_value:
                    continue
        _write_memo_value(memo_path, host_value)
        appended += 1
    return appended


# --- Pollination ledger merge ---------------------------------------


def _ledger_sources_from_stdin() -> list[Path]:
    paths: list[Path] = []
    if sys.stdin.isatty():
        return paths
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        p = Path(line)
        if p.is_file():
            paths.append(p)
    return paths


def _ledger_sources_from_disk(host_dir: Path) -> list[Path]:
    parent = host_dir.parent
    sources: list[Path] = []
    if not parent.is_dir():
        return sources
    for fed_root in sorted(parent.iterdir()):
        if not fed_root.is_dir():
            continue
        if fed_root == host_dir:
            continue
        candidate = fed_root / ".agentis" / "pollination-ledger.jsonl"
        if candidate.is_file():
            sources.append(candidate)
    return sources


def pollination_ledger_merge(host_dir: Path) -> int:
    """Concatenate per-fed pollination ledgers into the central one.

    Rows are ordered by their `ts` (or `timestamp`) field when present,
    falling back to the order in which they were read. The central
    ledger is rewritten on every merge -- the source rows are the
    authoritative copy.

    Returns the number of rows written to the central ledger.
    """
    host_dir.mkdir(parents=True, exist_ok=True)
    sources = _ledger_sources_from_stdin()
    if not sources:
        sources = _ledger_sources_from_disk(host_dir)
    rows: list[tuple[float, int, str]] = []
    seq = 0
    for src in sources:
        try:
            with src.open("r", encoding="utf-8", errors="replace") as f:
                for raw_line in f:
                    line = raw_line.rstrip("\n").rstrip("\r")
                    if not line.strip():
                        continue
                    ts_val: float = 0.0
                    try:
                        rec = json.loads(line)
                        if isinstance(rec, dict):
                            for k in ("ts", "timestamp", "created_at"):
                                v = rec.get(k)
                                if isinstance(v, (int, float)):
                                    ts_val = float(v)
                                    break
                    except json.JSONDecodeError:
                        pass
                    rows.append((ts_val, seq, line))
                    seq += 1
        except OSError:
            continue
    rows.sort(key=lambda r: (r[0], r[1]))
    central = host_dir / "pollination-ledger.jsonl"
    tmp = central.with_suffix(central.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as out:
        for _ts, _seq, line in rows:
            out.write(line + "\n")
    os.replace(tmp, central)
    return len(rows)


# --- CLI -------------------------------------------------------------


def _cmd_sync(args: argparse.Namespace) -> int:
    fed_dir = Path(args.fed_dir).resolve()
    host_dir = Path(args.host_dir).resolve()
    if not fed_dir.is_dir():
        print(f"cross-fed-bridge: fed_dir not a directory: {fed_dir}", file=sys.stderr)
        return 2
    lock_mode = args.lock_mode or "acquire"
    if lock_mode == "release":
        return 0
    handle = acquire_lock(host_dir, mode=lock_mode)
    if handle is None:
        print("cross-fed-bridge: lock held by other process; no-op")
        return 0
    try:
        written = sync_memo_to_host(fed_dir, host_dir)
        appended = sync_host_to_memo(host_dir, fed_dir)
        print(
            f"cross-fed-bridge: sync ok fed={fed_dir.name} host={host_dir} "
            f"memo_to_host={written} host_to_memo={appended}"
        )
        return 0
    finally:
        handle.close()


def _cmd_merge_ledgers(args: argparse.Namespace) -> int:
    host_dir = Path(args.host_dir).resolve()
    rows = pollination_ledger_merge(host_dir)
    print(f"cross-fed-bridge: merge-ledgers ok host={host_dir} rows={rows}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="cross-fed-bridge.py",
        description="Bidirectional cross-fed:* memo <-> host-dir sync.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_sync = sub.add_parser("sync", help="Run one bidirectional sync pass.")
    p_sync.add_argument("fed_dir")
    p_sync.add_argument("host_dir")
    p_sync.add_argument(
        "--lock-mode",
        choices=("acquire", "nonblocking", "release"),
        default="acquire",
    )
    p_sync.set_defaults(func=_cmd_sync)

    p_merge = sub.add_parser("merge-ledgers", help="Merge per-fed pollination ledgers.")
    p_merge.add_argument("host_dir")
    p_merge.set_defaults(func=_cmd_merge_ledgers)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
