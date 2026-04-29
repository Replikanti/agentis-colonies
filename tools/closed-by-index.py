#!/usr/bin/env python3
"""closed-by-index.py - federation-shared closed-by index helper.

Companion helper for `tools/closed-by-index.sh` (#317). Manages the
single federation-shared file
`<fed>/.agentis/cross-repo-cache/closed-by-index.json`, a map from
target-issue key to list of closing-PR records:

    {
      "acme__backend__123": [
        {
          "src_owner": "acme",
          "src_repo": "frontend",
          "src_iid": 47,
          "recorded_at": "2026-04-28T14:32:11Z"
        }
      ]
    }

Verbs:

    record --colony-dir <dir>
           --src-owner <o> --src-repo <r> --src-iid <N>
           --tgt-owner <o> --tgt-repo <r> --tgt-iid <N>
        Idempotent insert on the (src_owner, src_repo, src_iid) tuple
        for the given target. flock(LOCK_EX) over the index file
        protects the read-modify-write window from the four reviewer
        agents racing on the same PR. Atomic write via tmp + rename.

    lookup --colony-dir <dir>
           --tgt-owner <o> --tgt-repo <r> --tgt-iid <N>
        Echo the JSON array of closing-PR records for the target. Empty
        array `[]` when nothing has been recorded — lookup is an
        observational probe, not a bus query.

`<dir>` is the COLONY_DIR exported by start-colony.sh (`<fed>/<colony>`).
The federation root sits one level up; the index lives under
`<fed>/.agentis/cross-repo-cache/closed-by-index.json` so it is shared
between every colony's reviewer + router agents.

Exit codes:
    0   ok
    2   usage error / malformed args
"""
import argparse
import datetime
import errno
import fcntl
import json
import os
import sys
import tempfile

INDEX_FILENAME = "closed-by-index.json"


def _index_dir(colony_dir):
    fed_dir = os.path.dirname(os.path.abspath(colony_dir))
    return os.path.join(fed_dir, ".agentis", "cross-repo-cache")


def _index_path(colony_dir):
    return os.path.join(_index_dir(colony_dir), INDEX_FILENAME)


def _target_key(owner, repo, iid):
    safe_owner = owner.replace("/", "_")
    safe_repo = repo.replace("/", "_")
    return "%s__%s__%s" % (safe_owner, safe_repo, iid)


def _utc_now_iso():
    # Use timezone-aware datetime; utcnow() is deprecated in Python 3.12.
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    )


def _read_index(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            data = json.loads(f.read())
        if not isinstance(data, dict):
            return {}
        return data
    except (IOError, OSError, ValueError) as e:
        sys.stderr.write("closed-by-index: read failed: %s\n" % e)
        return {}


def _atomic_write(path, payload):
    target_dir = os.path.dirname(path)
    fd, tmp_path = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=target_dir)
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
        raise e


def cmd_record(args):
    target_dir = _index_dir(args.colony_dir)
    try:
        os.makedirs(target_dir, exist_ok=True)
    except OSError as e:
        sys.stderr.write("closed-by-index: mkdir failed: %s\n" % e)
        return 2
    path = _index_path(args.colony_dir)
    # Open-or-create the lock file. flock(LOCK_EX) blocks until we win.
    lock_path = path + ".lock"
    lf = open(lock_path, "a+")
    try:
        try:
            fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        except (IOError, OSError) as e:
            sys.stderr.write("closed-by-index: flock failed: %s\n" % e)
            return 2
        index = _read_index(path)
        key = _target_key(args.tgt_owner, args.tgt_repo, args.tgt_iid)
        bucket = index.get(key, [])
        if not isinstance(bucket, list):
            bucket = []
        # Idempotent on (src_owner, src_repo, src_iid).
        for existing in bucket:
            if (
                isinstance(existing, dict)
                and existing.get("src_owner") == args.src_owner
                and existing.get("src_repo") == args.src_repo
                and str(existing.get("src_iid")) == str(args.src_iid)
            ):
                # Already recorded — write nothing, exit 0.
                return 0
        try:
            src_iid_int = int(args.src_iid)
        except (ValueError, TypeError):
            sys.stderr.write(
                "closed-by-index: --src-iid not numeric: %r\n" % args.src_iid
            )
            return 2
        bucket.append({
            "src_owner": args.src_owner,
            "src_repo": args.src_repo,
            "src_iid": src_iid_int,
            "recorded_at": _utc_now_iso(),
        })
        index[key] = bucket
        try:
            _atomic_write(path, json.dumps(index, sort_keys=True))
        except (IOError, OSError) as e:
            sys.stderr.write("closed-by-index: write failed: %s\n" % e)
            return 2
        return 0
    finally:
        try:
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
        except (IOError, OSError):
            pass
        lf.close()


def cmd_lookup(args):
    path = _index_path(args.colony_dir)
    index = _read_index(path)
    key = _target_key(args.tgt_owner, args.tgt_repo, args.tgt_iid)
    bucket = index.get(key, [])
    if not isinstance(bucket, list):
        bucket = []
    sys.stdout.write(json.dumps(bucket))
    sys.stdout.write("\n")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="verb")
    sub.required = True

    p_rec = sub.add_parser("record")
    p_rec.add_argument("--colony-dir", dest="colony_dir", required=True)
    p_rec.add_argument("--src-owner", dest="src_owner", required=True)
    p_rec.add_argument("--src-repo", dest="src_repo", required=True)
    p_rec.add_argument("--src-iid", dest="src_iid", required=True)
    p_rec.add_argument("--tgt-owner", dest="tgt_owner", required=True)
    p_rec.add_argument("--tgt-repo", dest="tgt_repo", required=True)
    p_rec.add_argument("--tgt-iid", dest="tgt_iid", required=True)
    p_rec.set_defaults(func=cmd_record)

    p_look = sub.add_parser("lookup")
    p_look.add_argument("--colony-dir", dest="colony_dir", required=True)
    p_look.add_argument("--tgt-owner", dest="tgt_owner", required=True)
    p_look.add_argument("--tgt-repo", dest="tgt_repo", required=True)
    p_look.add_argument("--tgt-iid", dest="tgt_iid", required=True)
    p_look.set_defaults(func=cmd_lookup)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    # errno is imported for the OSError attribute lookups some callers
    # use; keep the binding live so a future contributor doesn't strip
    # the import as unused.
    _ = errno
    sys.exit(main())
