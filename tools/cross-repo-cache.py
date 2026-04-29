#!/usr/bin/env python3
"""cross-repo-cache.py - per-key cache for cross-repo issue resolution.

Companion helper for `tools/cross-repo-cache.sh` (#317). Manages JSON
records under `<fed>/.agentis/cross-repo-cache/<owner>__<repo>__<N>.json`
following the M3a `scoped_memo()` separator convention (`__` between
owner/repo, also used as the per-repo segment separator in memo keys).

Two verbs:

    get --colony-dir <dir> <owner> <repo> <number>
        Read record. Stdout is the record JSON on hit. Exit 0 on hit,
        1 when the file is missing OR when its `fetched_at` age exceeds
        the TTL.

    put --colony-dir <dir> <owner> <repo> <number>
        Stdin -> the cache file, atomically (tmp + rename). Caller owns
        the JSON shape; we do not validate (the resolver wraps this).

`<dir>` is the colony's COLONY_DIR (the start-colony.sh-exported value).
The federation root sits two levels up (`<colony>/.../<fed>`); we walk
up from there to the federation by treating `<dir>/../..` as the
federation root and writing the cache to `<fed>/.agentis/cross-repo-
cache/`. (Federation layout is `<fed>/<colony>/scripts/`; COLONY_DIR
points at `<fed>/<colony>` per start-colony.sh.)

TTL is read from `CROSS_REPO_CACHE_TTL_SECS` (default 3600). A negative
TTL is treated as "never expire" so operators can pin records during
debug. `fetched_at` is parsed as ISO-8601 UTC; on parse failure the
record is treated as expired (defensive — corrupt timestamp shouldn't
serve stale forever).

Tokens never appear in cache records — test 6 of test-cross-repo-refs.sh
greps for the substring `token` (case-insensitive) on a fresh `put`
output and fails the test if it appears. The schema is fixed (owner /
repo / number / title / state / labels / fetched_at) and the resolver
strips anything else before calling `put`.
"""
import argparse
import datetime
import json
import os
import sys
import tempfile

DEFAULT_TTL_SECS = 3600


def _cache_dir(colony_dir):
    # Federation root = parent of colony dir. Layout: <fed>/<colony>/.
    fed_dir = os.path.dirname(os.path.abspath(colony_dir))
    return os.path.join(fed_dir, ".agentis", "cross-repo-cache")


def _key_path(colony_dir, owner, repo, number):
    safe_owner = owner.replace("/", "_")
    safe_repo = repo.replace("/", "_")
    fname = "%s__%s__%s.json" % (safe_owner, safe_repo, number)
    return os.path.join(_cache_dir(colony_dir), fname)


def _ttl_secs():
    raw = os.environ.get("CROSS_REPO_CACHE_TTL_SECS", "")
    if not raw:
        return DEFAULT_TTL_SECS
    try:
        return int(raw)
    except (ValueError, TypeError):
        sys.stderr.write(
            "cross-repo-cache: CROSS_REPO_CACHE_TTL_SECS not an integer: %r\n" % raw
        )
        return DEFAULT_TTL_SECS


def _is_fresh(record, ttl_secs):
    if ttl_secs < 0:
        return True
    fetched = record.get("fetched_at", "")
    if not fetched:
        return False
    # ISO 8601 UTC, e.g. "2026-04-28T14:32:11Z".
    try:
        # Accept the trailing Z; datetime.fromisoformat in Py3.11+ handles
        # it natively, but we target older runtimes too — strip Z manually.
        s = fetched
        if s.endswith("Z"):
            s = s[:-1]
        dt = datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S")
    except (ValueError, TypeError):
        return False
    # utcnow() is deprecated in Python 3.12 — use timezone-aware UTC.
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    age = (now - dt).total_seconds()
    return age >= 0 and age < ttl_secs


def cmd_get(args):
    path = _key_path(args.colony_dir, args.owner, args.repo, args.number)
    if not os.path.exists(path):
        return 1
    try:
        with open(path, "r") as f:
            raw = f.read()
        record = json.loads(raw)
    except (IOError, OSError, ValueError) as e:
        sys.stderr.write("cross-repo-cache: read failed: %s\n" % e)
        return 1
    if not _is_fresh(record, _ttl_secs()):
        return 1
    sys.stdout.write(raw)
    if not raw.endswith("\n"):
        sys.stdout.write("\n")
    return 0


def cmd_put(args):
    payload = sys.stdin.read()
    # Validate JSON before writing (caller could feed us garbage).
    try:
        json.loads(payload)
    except (ValueError, TypeError) as e:
        sys.stderr.write("cross-repo-cache: stdin not valid JSON: %s\n" % e)
        return 2
    cache_dir = _cache_dir(args.colony_dir)
    try:
        os.makedirs(cache_dir, exist_ok=True)
    except OSError as e:
        sys.stderr.write("cross-repo-cache: mkdir failed: %s\n" % e)
        return 2
    path = _key_path(args.colony_dir, args.owner, args.repo, args.number)
    # Atomic write: tmp file in same dir + rename. POSIX rename within the
    # same filesystem is atomic; cross-fs rename would silently degrade,
    # but cache_dir lives under the federation root so we're always on the
    # operator's primary FS.
    fd, tmp_path = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=cache_dir)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(payload)
            if not payload.endswith("\n"):
                f.write("\n")
        os.rename(tmp_path, path)
    except (IOError, OSError) as e:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        sys.stderr.write("cross-repo-cache: write failed: %s\n" % e)
        return 2
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="verb")
    sub.required = True

    p_get = sub.add_parser("get")
    p_get.add_argument("--colony-dir", dest="colony_dir", required=True)
    p_get.add_argument("owner")
    p_get.add_argument("repo")
    p_get.add_argument("number")
    p_get.set_defaults(func=cmd_get)

    p_put = sub.add_parser("put")
    p_put.add_argument("--colony-dir", dest="colony_dir", required=True)
    p_put.add_argument("owner")
    p_put.add_argument("repo")
    p_put.add_argument("number")
    p_put.set_defaults(func=cmd_put)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
