#!/usr/bin/env python3
# snapshot-compress.py: structural-chunk compression for a GitLab collection
# snapshot (#1112).
#
# Reads a raw GitLab JSON array (e.g. /work_items or /merge_requests, the
# full `gitlab-api.sh issues`/`merge-requests` body) on stdin, emits a
# compact, deduplicated, structurally-chunked representation on stdout. The
# shared per-colony snapshot memo (#1111) stores THIS form, not the raw
# blob, so the bytes that ultimately reach an agent's prompt() are the
# compact form (the #119 "factor 5-10x raw-JSON waste").
#
# The compression reuses the dark-factory normalized-subtree-hashing idea
# (see dark-factory/evm-harness/struct-sig.js): normalize each item to the
# role-relevant fields, hash the normalized STRUCTURE of each item to a
# content address, intern repeated structures once in a `chunks` table, and
# reference them by index from each item. Identical structure across items
# (and across ticks) is stored once and referenced, never re-serialized.
#
# Output schema (deterministic, byte-stable for identical input):
#   {
#     "v": 1,                       # format version
#     "collection": "<name>",       # e.g. "issues" | "merge_requests"
#     "count": <int>,               # number of items
#     "fields": [ ... ],            # union of normalized field names, sorted
#     "chunks": [ <structural-chunk>, ... ],  # interned, content-addressed
#     "items": [ {"k": <key>, "c": <chunk-index>}, ... ]  # key + chunk ref
#   }
#
# Each <structural-chunk> is the normalized field map for an item with the
# item key removed (so two items that differ only by iid still share a
# chunk when their other fields match). The item layer carries the per-item
# key (iid for issues, iid for MRs) plus the chunk index. A reader
# rehydrates an item as { "iid": k, **chunks[c] }.
#
# Determinism: dict keys are emitted sorted, the chunk table is ordered by
# first-appearance, and json.dumps uses sort_keys + compact separators. The
# same raw input therefore hashes to the same output on every run (the
# #1112 byte-stability DoD).
#
# Total-on-failure: any parse / shape error -> emit an empty-but-valid
# envelope ({"v":1,...,"count":0,"chunks":[],"items":[]}) on stdout and
# exit 0. The snapshot step and the agents both treat an empty envelope as
# "no snapshot" and degrade to the legacy direct-fetch path, so a malformed
# upstream payload never hard-fails a tick (#1111 backward-safe degrade).

import hashlib
import json
import os
import sys

FORMAT_VERSION = 1

# Union of every field any dev-apprenticeship role projects out of a GitLab
# item (see each colony's gitlab-api.sh project_json views). Keeping this an
# explicit allowlist is what makes the compact form small: anything not in
# the list (web_url, time_stats, references, ...) is dropped before the blob
# ever reaches a prompt(). New role fields are added here in one place.
ISSUE_FIELDS = ("iid", "title", "labels", "state", "description")
MR_FIELDS = ("iid", "title", "labels", "state", "source_branch", "target_branch")


def _str(v):
    return v if isinstance(v, str) else ("" if v is None else str(v))


def _username(obj):
    if isinstance(obj, dict):
        return _str(obj.get("username"))
    return ""


def _labels(v):
    if isinstance(v, list):
        return [_str(x) for x in v]
    return []


def normalize_issue(item):
    # iid is the item key, carried at the item layer (not in the chunk) so
    # two issues that differ only by iid still intern to the same chunk.
    out = {
        "title": _str(item.get("title")),
        "labels": _labels(item.get("labels")),
        "state": _str(item.get("state")),
        "author": _username(item.get("author")),
        "assignees": [_username(a) for a in item.get("assignees", []) if isinstance(item.get("assignees"), list)],
    }
    # description is consumed in FULL by the issue_creator view (it reads
    # `description`), so the compact form must carry the untruncated value or
    # the rehydrated issue_creator projection would silently differ from the
    # legacy direct-fetch one. We keep the full string here; the
    # labeler/router/prioritizer views drop `description` in their
    # project_json projections, so this field never reaches their prompts —
    # only the issue_creator view pays for it. Structural interning still
    # collapses two issues with identical full descriptions to one chunk.
    desc = _str(item.get("description"))
    if desc:
        out["description"] = desc
    return out


def normalize_mr(item):
    out = {
        "title": _str(item.get("title")),
        "labels": _labels(item.get("labels")),
        "state": _str(item.get("state")),
        "source_branch": _str(item.get("source_branch")),
        "target_branch": _str(item.get("target_branch")),
        "author": _username(item.get("author")),
    }
    return out


def normalize(collection, item):
    if not isinstance(item, dict):
        return None
    if collection == "merge_requests":
        chunk = normalize_mr(item)
    else:
        chunk = normalize_issue(item)
    key = item.get("iid")
    if not isinstance(key, int):
        try:
            key = int(_str(key))
        except (TypeError, ValueError):
            key = 0
    return key, chunk


def chunk_hash(chunk):
    # Content address of a normalized structural chunk. The canonical JSON
    # (sorted keys, compact separators) is what guarantees a verbatim,
    # renamed-field-order, or reformatted-but-structurally-identical item
    # collapses to the SAME hash -> stored once -> referenced. Mirrors
    # struct-sig.js's normalize()->content-hash collapse for Solidity
    # functions, applied here to GitLab item structure.
    canon = json.dumps(chunk, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()[:16]


def empty_envelope(collection):
    return {
        "v": FORMAT_VERSION,
        "collection": collection,
        "count": 0,
        "fields": [],
        "chunks": [],
        "items": [],
    }


def compress(collection, raw):
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return empty_envelope(collection)
    if not isinstance(data, list):
        return empty_envelope(collection)

    chunks = []
    chunk_index = {}  # hash -> position in chunks (first-appearance order)
    items = []
    field_set = set()

    for item in data:
        norm = normalize(collection, item)
        if norm is None:
            continue
        key, chunk = norm
        field_set.update(chunk.keys())
        h = chunk_hash(chunk)
        idx = chunk_index.get(h)
        if idx is None:
            idx = len(chunks)
            chunk_index[h] = idx
            chunks.append(chunk)
        items.append({"k": key, "c": idx})

    return {
        "v": FORMAT_VERSION,
        "collection": collection,
        "count": len(items),
        "fields": sorted(field_set),
        "chunks": chunks,
        "items": items,
    }


def rehydrate(env):
    # Expand a compact envelope back into the per-item list of normalized
    # field maps (item key folded back in as "iid"). Used by the read-side
    # `--from-snapshot` projection so an agent's view downselect operates on
    # the same field set it saw pre-#1111, just sourced from the shared
    # memo instead of a per-agent HTTP fetch.
    if not isinstance(env, dict):
        return []
    chunks = env.get("chunks")
    items = env.get("items")
    if not isinstance(chunks, list) or not isinstance(items, list):
        return []
    out = []
    for it in items:
        if not isinstance(it, dict):
            continue
        idx = it.get("c")
        if not isinstance(idx, int) or idx < 0 or idx >= len(chunks):
            continue
        chunk = chunks[idx]
        if not isinstance(chunk, dict):
            continue
        # Reconstruct the GitLab-native nested shape (author/assignees as
        # username objects) so the EXISTING project_json views in
        # gitlab-api.sh project the rehydrated item byte-for-byte the same
        # as a freshly-fetched one — no view code changes needed for the
        # snapshot read path.
        row = {
            "iid": it.get("k"),
            "title": chunk.get("title", ""),
            "labels": chunk.get("labels", []),
            "state": chunk.get("state", ""),
        }
        author = chunk.get("author", "")
        if author:
            row["author"] = {"username": author}
        assignees = chunk.get("assignees")
        if isinstance(assignees, list) and assignees:
            row["assignees"] = [{"username": a} for a in assignees]
        for opt in ("description", "source_branch", "target_branch"):
            if opt in chunk:
                # `description` is carried in full (see normalize_issue) so the
                # issue_creator view's rehydrated `description` is byte-identical
                # to the legacy direct-fetch value; branch fields pass straight
                # through for the MR views.
                row[opt] = chunk.get(opt, "")
        out.append(row)
    return out


def normalize_collection(name):
    # Map the legacy /issues spelling and the migrated /work_items spelling
    # (#1119) to the same logical collection name so the memo key + the
    # compact form's "collection" tag are stable across the rename. The MR
    # verb's hyphen spelling collapses to the underscore form too.
    if name in ("work_items", "work-items"):
        return "issues"
    if name == "merge-requests":
        return "merge_requests"
    return name


def main():
    collection = sys.argv[1] if len(sys.argv) > 1 else "issues"
    collection = normalize_collection(collection)
    try:
        raw = sys.stdin.read()
    except Exception:
        raw = ""
    env = compress(collection, raw)
    # Compact, sorted, deterministic. byte-stable for identical input.
    sys.stdout.write(json.dumps(env, sort_keys=True, separators=(",", ":")))


def main_rehydrate():
    # `--rehydrate`: read a compact envelope on stdin, emit the rehydrated
    # per-item JSON array on stdout (the shape an agent's --view projection
    # consumes). Total-on-failure -> emit `[]` and exit 0 so the agent's
    # `len(raw) < 3` early-exit treats a bad/empty snapshot as "no work".
    try:
        raw = sys.stdin.read()
    except Exception:
        raw = ""
    try:
        env = json.loads(raw)
    except (ValueError, TypeError):
        env = {}
    sys.stdout.write(json.dumps(rehydrate(env), separators=(",", ":")))


if __name__ == "__main__":
    # Allow `--self-test` for a quick local determinism/round-trip check
    # without standing up a GitLab instance. Not used at runtime.
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        # A description long enough that the legacy 200-char `desc_head` would
        # have truncated it — used below to prove the issue_creator view's
        # rehydrated `description` is now byte-identical to the source value.
        long_desc = "Steps to reproduce:\n" + ("x" * 500) + "\nExpected: no crash."
        sample = json.dumps([
            {"iid": 1, "title": "fix bug", "labels": ["bug"], "state": "opened",
             "description": long_desc,
             "author": {"username": "alice"}, "assignees": [{"username": "bob"}]},
            {"iid": 2, "title": "fix bug", "labels": ["bug"], "state": "opened",
             "description": long_desc,
             "author": {"username": "alice"}, "assignees": [{"username": "bob"}]},
            {"iid": 3, "title": "add docs", "labels": [], "state": "opened",
             "author": {"username": "carol"}, "assignees": []},
        ])
        a = json.dumps(compress("issues", sample), sort_keys=True, separators=(",", ":"))
        b = json.dumps(compress("issues", sample), sort_keys=True, separators=(",", ":"))
        assert a == b, "not byte-stable"
        env = json.loads(a)
        assert env["count"] == 3, env["count"]
        # items 1 and 2 are structurally identical -> share a chunk; item 3
        # differs -> own chunk. So exactly 2 interned chunks for 3 items.
        assert len(env["chunks"]) == 2, len(env["chunks"])
        assert env["items"][0]["c"] == env["items"][1]["c"], "dedup failed"
        assert env["items"][2]["c"] != env["items"][0]["c"], "over-merge"
        # malformed input -> empty-but-valid envelope, never a crash.
        bad = compress("issues", "{not json")
        assert bad["count"] == 0 and bad["chunks"] == [], bad
        # rehydrate round-trip: compact -> per-item list keeps iid + fields
        # in the GitLab-native nested shape the project_json views consume.
        rh = rehydrate(env)
        assert len(rh) == 3, len(rh)
        assert rh[0]["iid"] == 1 and rh[2]["iid"] == 3, rh
        assert rh[0]["title"] == "fix bug" and rh[2]["title"] == "add docs", rh
        assert rh[0]["author"] == {"username": "alice"}, rh[0]
        assert rh[0]["assignees"] == [{"username": "bob"}], rh[0]
        assert rh[2]["author"] == {"username": "carol"}, rh[2]
        assert "assignees" not in rh[2], rh[2]  # carol has no assignees
        # #2b: the issue_creator view reads `description` in full. The
        # rehydrated value must be byte-identical to the source description
        # (the legacy desc_head[:200] truncation is gone). carol's issue had
        # no description -> the field is absent (not "" — matches a
        # direct-fetch item that omits a null description from the view).
        assert rh[0]["description"] == long_desc, "description truncated/altered"
        assert "description" not in rh[2], rh[2]  # carol has no description
        # rehydrate of garbage -> [] (total-on-failure).
        assert rehydrate({}) == [] and rehydrate("nope") == [], "rehydrate degrade"
        sys.stderr.write("self-test OK: byte-stable, dedup 3->2 chunks, rehydrate round-trip, full-description fidelity, total-on-failure\n")
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "--rehydrate":
        main_rehydrate()
        sys.exit(0)
    main()
