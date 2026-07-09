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

# #1466: the shared snapshot memo has a hard value-size ceiling in the agentis
# runtime (`memo set` rejects a value over this many bytes). The publish step
# used to hit it silently once the repo grew past a handful of issues — the
# oversize `memo set` failed under `|| true` while the freshness ts kept
# refreshing, so agents trusted a stale snapshot forever. We now bound the
# envelope BEFORE it can exceed the cap, here in the compressor, via a single
# knob. This is the one place the compressor's default ceiling lives; keep it in
# sync with the `SNAPSHOT_MEMO_MAX_BYTES` default documented in start-colony.sh.
# NOTE: the runtime memo cap this mirrors is itself operator-configurable via
# `memo.max_value_bytes` (agentis-core v1.22.0+, default 10240); when an operator
# raises it, also raise SNAPSHOT_MEMO_MAX_BYTES here so the compressor stops
# truncating below the new ceiling.
DEFAULT_MEMO_MAX_BYTES = 10240

# Descending per-issue `description` length ladder tried when the full envelope
# does not fit the cap. Each rung re-compresses the item list with descriptions
# truncated to that many code points (0 = drop the field entirely) and the
# first envelope that fits wins. Mirrors the graceful-degrade idiom: keep as
# much structure as the cap allows, mark what was dropped, never emit nothing.
DESC_CAP_LADDER = (512, 300, 160, 80, 0)


def memo_max_bytes():
    # Read the snapshot memo ceiling from the environment (SNAPSHOT_MEMO_MAX_BYTES),
    # falling back to DEFAULT_MEMO_MAX_BYTES. Mirrors the env-knob idiom in
    # agentis_memo_freshness.py: an unset / non-positive / non-integer value
    # yields the default rather than raising. Runs only on the write path (the
    # `snapshot issues` verb), never on the daemon read path, so this getenv
    # read never needs to reach the sanitized-env allowlist.
    try:
        v = int(os.environ.get("SNAPSHOT_MEMO_MAX_BYTES", ""))
        return v if v > 0 else DEFAULT_MEMO_MAX_BYTES
    except (TypeError, ValueError):
        return DEFAULT_MEMO_MAX_BYTES

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
    # Parse the raw GitLab JSON blob and delegate to compress_data. Signature
    # and behaviour are unchanged (the in-file --self-test and any caller pass
    # a raw string); the parsed-list path is factored out so the size-bounding
    # code (#1466) can re-compress an already-parsed, description-truncated list
    # without re-serializing + re-parsing it at every ladder rung.
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return empty_envelope(collection)
    if not isinstance(data, list):
        return empty_envelope(collection)
    return compress_data(collection, data)


def compress_data(collection, data):
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


def _envelope_bytes(env):
    # UTF-8 length of the canonical serialized form — the exact bytes the memo
    # value carries, so the bound is measured against what `memo set` stores.
    return len(json.dumps(env, sort_keys=True, separators=(",", ":")).encode("utf-8"))


def truncate_descriptions(data, cap):
    # Return a shallow copy of the raw item list with each item's string
    # `description` bounded to `cap` code points. A truncated description keeps
    # its head and gains an explicit ` …[+<N> chars]` marker (N = dropped code
    # points) so a reader never mistakes a bounded body for the full one; a
    # `cap == 0` drops the field entirely. Non-dict items and items without a
    # string description pass through untouched. Only `description` is touched —
    # the structural fields the other triage views consume are preserved.
    out = []
    for item in data:
        if not isinstance(item, dict):
            out.append(item)
            continue
        desc = item.get("description")
        if not isinstance(desc, str) or len(desc) <= cap:
            out.append(item)
            continue
        copy = dict(item)
        if cap == 0:
            copy.pop("description", None)
        else:
            dropped = len(desc) - cap
            copy["description"] = desc[:cap] + " …[+%d chars]" % dropped
        out.append(copy)
    return out


def _items_capped(data, cap):
    # Count how many items the given cap would actually truncate (or, at
    # cap == 0, drop) — the `items_capped` figure reported in the envelope and
    # the log line. Mirrors the predicate in truncate_descriptions.
    n = 0
    for item in data:
        if not isinstance(item, dict):
            continue
        desc = item.get("description")
        if isinstance(desc, str) and len(desc) > cap:
            n += 1
    return n


def build_bounded(collection, data, max_bytes):
    # Compress `data`, and if the serialized envelope already fits `max_bytes`
    # return it unchanged with applied_cap = None (the common case — under-cap
    # output stays byte-identical to compress(), preserving the #1112
    # byte-stability DoD). Otherwise walk DESC_CAP_LADDER, re-compressing the
    # description-truncated list at each rung, and return the first envelope
    # that fits together with the cap that produced it. A bounded envelope
    # carries an additive top-level `bounded` key; readers that only consume
    # `chunks`/`items` ignore it. If even the cap == 0 rung does not fit (an
    # envelope dominated by titles/labels, not descriptions) the last-built
    # best-effort form is returned — the coupled write path still refuses to
    # publish it over the cap, so a too-big envelope degrades to direct-fetch
    # rather than corrupting the memo.
    env = compress_data(collection, data)
    if _envelope_bytes(env) <= max_bytes:
        return env, None
    best = env
    best_cap = None
    for cap in DESC_CAP_LADDER:
        truncated = truncate_descriptions(data, cap)
        env = compress_data(collection, truncated)
        env["bounded"] = {"desc_cap": cap, "items_capped": _items_capped(data, cap)}
        best = env
        best_cap = cap
        if _envelope_bytes(env) <= max_bytes:
            return env, cap
    return best, best_cap


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
    # #1466: parse once, then size-bound the envelope against the memo ceiling
    # so the shared snapshot stays storable under realistic issue load. Under
    # cap this returns the exact same envelope compress() would have (byte-
    # identical), so the #1112 byte-stability DoD and the --self-test are
    # unaffected. Malformed input falls through compress()'s total-on-failure
    # empty envelope, which trivially fits the cap.
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        data = None
    if isinstance(data, list):
        env, applied_cap = build_bounded(collection, data, memo_max_bytes())
    else:
        env, applied_cap = empty_envelope(collection), None
    if applied_cap is not None:
        # Loud, one-line note to STDERR (stdout carries the envelope) so the
        # snapshot-refresh log shows exactly when and how hard the envelope was
        # bounded. Stays off stdout to keep the memo value clean.
        info = env.get("bounded", {})
        sys.stderr.write(
            "[snapshot-compress] envelope bounded: desc_cap=%s items_capped=%s bytes=%d\n"
            % (info.get("desc_cap"), info.get("items_capped"), _envelope_bytes(env))
        )
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
