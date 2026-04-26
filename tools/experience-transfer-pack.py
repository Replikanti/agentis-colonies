#!/usr/bin/env python3
"""experience-transfer-pack.py - Pack/unpack helper for tools/experience-transfer.sh (#323).

The shell wrapper deliberately keeps zero JSON / tar parsing logic so it stays
portable on stock macOS bash 3.2 (no heredocs, no PyYAML, no GNU coreutils).
All schema-aware work — JSONL filtering / scrubbing / dedupe / row remap —
happens here.

Subcommands:

    pack <fed_dir> <out_path> [--since YYYY-MM-DD] [--tags t1,t2]
         [--max-rows-per-agent N] [--scrub] [--donor-name NAME]
        Walks <fed_dir>'s colonies, discovers each agent name from the
        `.ag` filenames under `<fed>/<colony>/agents/*.ag`, resolves the
        per-agent `agent_id` via the daemon registry (live first, falling
        back to the stored agent_id memo file under
        `<resolved-agentis>/daemon/<colony>/<agent>.json` produced by
        `agentis daemon` runs), reads `<resolved-agentis>/experience/
        <agent_id>.jsonl`, applies filters, and writes a tarball with the
        layout:

            manifest.json
            experience/<colony>/<agent_name>.jsonl

        manifest.json shape:
            {
              "schema_version": 1,
              "donor": "<donor name or fed dir basename>",
              "created_at": "<UTC ISO>",
              "agents": [
                  {"colony": "<col>", "name": "<agent>", "rows": <int>}, ...
              ],
              "filters": {
                  "since": "...", "tags": [...], "max_rows_per_agent": N,
                  "scrub": true|false
              }
            }

        Each emitted JSONL row gets a `donor=<donor>` tag appended to its
        `tags` array (created if missing) so post-import auditors can
        distinguish imported rows from native ones (issue #323's
        provenance criterion).

    unpack <fed_dir> <pack_path>
        Resolves the agentis dir on the target federation (same 3-step
        fallback as `<fed>/.agentis` → `<fed>/../.agentis` → `.agentis`),
        walks `experience/<colony>/<agent_name>.jsonl` in the tarball,
        looks up each target agent's current `agent_id` from the
        recipient daemon registry (live `agentis daemon list --json`,
        else the per-agent JSON files under
        `<resolved-agentis>/daemon/<colony>/<agent>.json`), and appends
        each unique row (by sha256 of the canonical JSON line) to
        `<resolved-agentis>/experience/<agent_id>.jsonl`. Missing target
        agents are reported on stderr and skipped (the issue's "skip
        with warning" criterion).

        Re-imports of the same pack are idempotent: dedupe set is built
        from the existing destination file before any append.

Exit codes:
    0  success
    1  bad arguments
    2  missing source / destination
    3  manifest parse / schema-version skew
"""
import argparse
import datetime
import glob
import hashlib
import io
import json
import os
import sys
import tarfile

SCHEMA_VERSION = 1


def _eprint(*args):
    print(*args, file=sys.stderr)


def _resolve_agentis_dir(fed_dir):
    """Mirror federation-dashboard's three-step `.agentis` resolver.

    Returns an absolute path. Caller is responsible for checking the
    underlying experience/daemon subdirs exist before reading them —
    a fresh federation may not have an `experience/` dir yet."""
    candidates = [
        os.path.join(fed_dir, '.agentis'),
        os.path.normpath(os.path.join(fed_dir, '..', '.agentis')),
        '.agentis',
    ]
    for p in candidates:
        if os.path.isdir(p):
            return os.path.abspath(p)
    # Default to fed-local even if missing — caller will error on read.
    return os.path.abspath(candidates[0])


def _discover_agents(fed_dir):
    """Yield (colony, agent_name) pairs by walking <fed>/<colony>/agents/*.ag.

    A "colony" is any subdir of fed_dir that contains an `agents/` dir,
    matching colony-lint.sh's discovery rule. Hidden dirs (.git etc.)
    are skipped."""
    if not os.path.isdir(fed_dir):
        return
    for entry in sorted(os.listdir(fed_dir)):
        if entry.startswith('.'):
            continue
        agents_dir = os.path.join(fed_dir, entry, 'agents')
        if not os.path.isdir(agents_dir):
            continue
        for ag in sorted(os.listdir(agents_dir)):
            if not ag.endswith('.ag'):
                continue
            yield (entry, ag[:-3])


def _live_daemon_map(fed_dir):
    """Best-effort lookup of {(colony, agent_name): agent_id} from
    `agentis daemon list --json`. Returns an empty dict on any failure
    (unparseable output, command not in PATH, federation not running).

    The shell wrapper avoids invoking `agentis` here when offline — it
    passes a pre-fetched JSON blob via the --daemons-json flag instead,
    so this code path is only reached when no override was provided."""
    import subprocess
    try:
        proc = subprocess.run(
            ['agentis', 'daemon', 'list', '--json'],
            cwd=fed_dir,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if proc.returncode != 0:
            return {}
        data = json.loads(proc.stdout or '[]')
    except Exception:
        return {}
    return _index_daemons(data)


def _index_daemons(data):
    """Extract {(colony, agent_name): agent_id} from a daemon-list JSON blob.

    Each daemon record carries `colony`, `agent_id`, and either an
    explicit `agent_name` field or a `source` path of the form
    `<...>/<colony>/agents/<name>.ag`. We support both."""
    out = {}
    if not isinstance(data, list):
        return out
    for d in data:
        if not isinstance(d, dict):
            continue
        agent_id = d.get('agent_id') or ''
        if not agent_id:
            continue
        colony = d.get('colony') or ''
        name = d.get('agent_name')
        if not name:
            source = d.get('source') or ''
            base = os.path.basename(source)
            if base.endswith('.ag'):
                name = base[:-3]
        if not name:
            continue
        out[(colony, name)] = agent_id
    return out


def _offline_daemon_map(agentis_dir):
    """Fallback resolver: walk <agentis>/daemon/<colony>/<agent>.json files.

    `agentis daemon spawn` writes a per-agent JSON sidecar containing
    `agent_id` even when the federation is currently stopped. This lets
    `tools/experience-transfer.sh export` work on an offline donor."""
    out = {}
    daemon_root = os.path.join(agentis_dir, 'daemon')
    if not os.path.isdir(daemon_root):
        return out
    for col_entry in sorted(os.listdir(daemon_root)):
        col_path = os.path.join(daemon_root, col_entry)
        if not os.path.isdir(col_path):
            continue
        for ag_entry in sorted(os.listdir(col_path)):
            if not ag_entry.endswith('.json'):
                continue
            ag_name = ag_entry[:-5]
            try:
                with open(os.path.join(col_path, ag_entry)) as f:
                    rec = json.load(f)
            except Exception:
                continue
            agent_id = rec.get('agent_id') or ''
            if agent_id:
                out[(col_entry, ag_name)] = agent_id
    return out


def _build_id_map(fed_dir, agentis_dir, daemons_json):
    """Combined live-then-offline resolver. `daemons_json` (str or None)
    overrides the live `agentis daemon list` call when the wrapper has
    already fetched it."""
    if daemons_json is not None:
        try:
            data = json.loads(daemons_json) if daemons_json else []
        except Exception:
            data = []
        live = _index_daemons(data)
    else:
        live = _live_daemon_map(fed_dir)
    offline = _offline_daemon_map(agentis_dir)
    # Live takes precedence — the running daemon's `agent_id` is the one
    # the experience JSONL is currently being written under.
    merged = {}
    merged.update(offline)
    merged.update(live)
    return merged


def _parse_since(since):
    """Parse an ISO date (YYYY-MM-DD) into ms-since-epoch UTC, or None."""
    if not since:
        return None
    try:
        d = datetime.datetime.strptime(since, '%Y-%m-%d').replace(
            tzinfo=datetime.timezone.utc
        )
    except ValueError:
        raise SystemExit('Invalid --since date (expected YYYY-MM-DD): %s' % since)
    return int(d.timestamp() * 1000)


def _row_passes_filters(row, since_ms, tag_filter):
    """Return True iff `row` (a dict) matches the active filters.

    `since_ms` is None → no time filter; otherwise we drop rows with
    `ts` strictly less than the threshold. `ts` lives in ms-since-epoch
    in the rows the live federation produces.

    `tag_filter` is a set of tag strings; a row passes when its `tags`
    array intersects the set non-emptily. Empty `tag_filter` means no
    tag filter."""
    if since_ms is not None:
        ts = row.get('ts')
        if not isinstance(ts, (int, float)):
            return False
        if int(ts) < since_ms:
            return False
    if tag_filter:
        tags = row.get('tags') or []
        if not isinstance(tags, list):
            return False
        if not any(t in tag_filter for t in tags):
            return False
    return True


# Fields the --scrub flag strips. Keys are dotted paths inside the row.
# Values matching the stripped *patterns* (e.g. tags starting with
# `forge_user=`) are removed from list-shaped fields. The list is
# deliberately conservative — see the README addition under
# "Bootstrap from another federation".
_SCRUB_KEYS = (
    'in',           # row['in'] is the issue/MR title or batch label
)
_SCRUB_NESTED = (
    ('signal', 'in_summary'),
    ('signal', 'title'),
)
_SCRUB_TAG_PREFIXES = (
    'forge_user=',
    'assignee=',
)


def _scrub_row(row):
    """Return a copy of `row` with PII-suspect fields stripped."""
    out = dict(row)
    for k in _SCRUB_KEYS:
        out.pop(k, None)
    for path in _SCRUB_NESTED:
        cur = out
        ok = True
        for step in path[:-1]:
            cur = cur.get(step) if isinstance(cur, dict) else None
            if not isinstance(cur, dict):
                ok = False
                break
        if ok and isinstance(cur, dict):
            cur.pop(path[-1], None)
    tags = out.get('tags')
    if isinstance(tags, list):
        out['tags'] = [
            t for t in tags
            if not any(
                isinstance(t, str) and t.startswith(p)
                for p in _SCRUB_TAG_PREFIXES
            )
        ]
    return out


def _stamp_donor(row, donor):
    """Append `donor=<donor>` to row['tags'] (creating if missing)."""
    tags = row.get('tags')
    if not isinstance(tags, list):
        tags = []
    marker = 'donor=%s' % donor
    if marker not in tags:
        tags = list(tags) + [marker]
    out = dict(row)
    out['tags'] = tags
    return out


def _read_jsonl(path):
    """Yield parsed JSON objects from `path`, skipping blanks / bad lines."""
    if not os.path.isfile(path):
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except (ValueError, json.JSONDecodeError):
                continue


def cmd_pack(args):
    fed_dir = os.path.abspath(args.fed_dir)
    if not os.path.isdir(fed_dir):
        _eprint('Federation directory not found: %s' % args.fed_dir)
        return 2
    agentis_dir = _resolve_agentis_dir(fed_dir)
    exp_dir = os.path.join(agentis_dir, 'experience')

    donor = args.donor_name or os.path.basename(fed_dir.rstrip('/'))
    since_ms = _parse_since(args.since)
    tag_filter = set(t.strip() for t in args.tags.split(',') if t.strip()) if args.tags else set()

    id_map = _build_id_map(fed_dir, agentis_dir, args.daemons_json)

    out_path = os.path.abspath(args.out)
    out_parent = os.path.dirname(out_path) or '.'
    if not os.path.isdir(out_parent):
        _eprint('Output parent directory missing: %s' % out_parent)
        return 2

    manifest_agents = []
    payload_files = []  # list of (arcname, bytes)

    for colony, agent_name in _discover_agents(fed_dir):
        agent_id = id_map.get((colony, agent_name))
        rows = []
        if agent_id:
            rows = list(_read_jsonl(os.path.join(exp_dir, agent_id + '.jsonl')))
        # Filter by time / tags first, then sort newest-first, then cap.
        filtered = [r for r in rows if _row_passes_filters(r, since_ms, tag_filter)]
        filtered.sort(key=lambda r: r.get('ts', 0), reverse=True)
        if args.max_rows_per_agent and args.max_rows_per_agent > 0:
            filtered = filtered[: args.max_rows_per_agent]
        # Re-sort ascending so the importer appends in chronological order
        # — auto-promote's slope window assumes oldest-first.
        filtered.sort(key=lambda r: r.get('ts', 0))
        if args.scrub:
            filtered = [_scrub_row(r) for r in filtered]
        filtered = [_stamp_donor(r, donor) for r in filtered]

        manifest_agents.append({
            'colony': colony,
            'name': agent_name,
            'rows': len(filtered),
            'agent_id_source': agent_id or '',
        })
        if not filtered:
            continue
        body_lines = [json.dumps(r, sort_keys=True, ensure_ascii=False) for r in filtered]
        body = ('\n'.join(body_lines) + '\n').encode('utf-8')
        arcname = 'experience/%s/%s.jsonl' % (colony, agent_name)
        payload_files.append((arcname, body))

    manifest = {
        'schema_version': SCHEMA_VERSION,
        'donor': donor,
        'created_at': datetime.datetime.now(datetime.timezone.utc).strftime(
            '%Y-%m-%dT%H:%M:%SZ'
        ),
        'agents': manifest_agents,
        'filters': {
            'since': args.since or None,
            'tags': sorted(tag_filter) if tag_filter else [],
            'max_rows_per_agent': args.max_rows_per_agent or None,
            'scrub': bool(args.scrub),
        },
    }
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode('utf-8')

    with tarfile.open(out_path, 'w:gz') as tar:
        info = tarfile.TarInfo(name='manifest.json')
        info.size = len(manifest_bytes)
        info.mtime = 0
        tar.addfile(info, io.BytesIO(manifest_bytes))
        for arcname, body in payload_files:
            inner = tarfile.TarInfo(name=arcname)
            inner.size = len(body)
            inner.mtime = 0
            tar.addfile(inner, io.BytesIO(body))

    total_rows = sum(a['rows'] for a in manifest_agents)
    print(
        'packed donor=%s agents=%d rows=%d -> %s'
        % (donor, len([a for a in manifest_agents if a['rows'] > 0]), total_rows, out_path)
    )
    return 0


def _read_pack(pack_path):
    """Return (manifest_dict, {arcname: bytes}) for the agents portion."""
    if not os.path.isfile(pack_path):
        raise SystemExit('Pack not found: %s' % pack_path)
    payload = {}
    manifest = None
    try:
        with tarfile.open(pack_path, 'r:gz') as tar:
            for member in tar.getmembers():
                if not member.isfile():
                    continue
                f = tar.extractfile(member)
                if f is None:
                    continue
                data = f.read()
                if member.name == 'manifest.json':
                    manifest = json.loads(data.decode('utf-8'))
                elif member.name.startswith('experience/') and member.name.endswith('.jsonl'):
                    payload[member.name] = data
    except (tarfile.TarError, OSError) as e:
        raise SystemExit('Cannot read pack: %s' % e)
    if manifest is None:
        raise SystemExit('Pack missing manifest.json')
    return manifest, payload


def _existing_dedupe_set(path):
    """sha256 set of canonicalised JSON lines already on disk."""
    out = set()
    if not os.path.isfile(path):
        return out
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                canon = json.dumps(obj, sort_keys=True, ensure_ascii=False)
            except Exception:
                canon = line
            out.add(hashlib.sha256(canon.encode('utf-8')).hexdigest())
    return out


def cmd_unpack(args):
    fed_dir = os.path.abspath(args.fed_dir)
    if not os.path.isdir(fed_dir):
        _eprint('Federation directory not found: %s' % args.fed_dir)
        return 2
    agentis_dir = _resolve_agentis_dir(fed_dir)
    exp_dir = os.path.join(agentis_dir, 'experience')
    os.makedirs(exp_dir, exist_ok=True)

    manifest, payload = _read_pack(os.path.abspath(args.pack))
    schema = manifest.get('schema_version')
    if schema != SCHEMA_VERSION:
        _eprint(
            'Pack schema_version %r unsupported (expected %d). Refusing import.'
            % (schema, SCHEMA_VERSION)
        )
        return 3

    id_map = _build_id_map(fed_dir, agentis_dir, args.daemons_json)

    appended_total = 0
    skipped_dupes = 0
    skipped_missing_agent = 0
    appended_per_agent = []  # for the JSON summary

    # The manifest dictates the roster — we walk it (not the tarball
    # entries) so an empty agent (rows=0) is reported as "no rows" not
    # "skipped". Agents with no payload entry simply have nothing to
    # append; agents whose target name is absent are reported as skipped.
    for entry in manifest.get('agents', []):
        colony = entry.get('colony') or ''
        name = entry.get('name') or ''
        if not colony or not name:
            continue
        target_id = id_map.get((colony, name))
        if not target_id:
            _eprint(
                'WARN: agent %s/%s has no daemon registration on target — skipping'
                % (colony, name)
            )
            skipped_missing_agent += 1
            continue

        arcname = 'experience/%s/%s.jsonl' % (colony, name)
        body = payload.get(arcname)
        if not body:
            appended_per_agent.append({
                'colony': colony,
                'name': name,
                'agent_id': target_id,
                'appended': 0,
                'skipped_dupes': 0,
            })
            continue

        dest_path = os.path.join(exp_dir, target_id + '.jsonl')
        seen = _existing_dedupe_set(dest_path)

        appended_here = 0
        skipped_here = 0
        with open(dest_path, 'a') as out_f:
            for line in body.decode('utf-8').splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                    canon = json.dumps(obj, sort_keys=True, ensure_ascii=False)
                except Exception:
                    canon = line
                h = hashlib.sha256(canon.encode('utf-8')).hexdigest()
                if h in seen:
                    skipped_here += 1
                    continue
                seen.add(h)
                out_f.write(canon + '\n')
                appended_here += 1

        appended_total += appended_here
        skipped_dupes += skipped_here
        appended_per_agent.append({
            'colony': colony,
            'name': name,
            'agent_id': target_id,
            'appended': appended_here,
            'skipped_dupes': skipped_here,
        })

    summary = {
        'donor': manifest.get('donor'),
        'pack_path': os.path.abspath(args.pack),
        'fed_dir': fed_dir,
        'appended_rows': appended_total,
        'skipped_duplicate_rows': skipped_dupes,
        'skipped_missing_agents': skipped_missing_agent,
        'agents': appended_per_agent,
    }
    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(
            'imported donor=%s into %s: appended=%d duplicates=%d missing_agents=%d'
            % (
                summary['donor'],
                fed_dir,
                appended_total,
                skipped_dupes,
                skipped_missing_agent,
            )
        )
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog='experience-transfer-pack')
    sub = parser.add_subparsers(dest='cmd')

    pp = sub.add_parser('pack')
    pp.add_argument('fed_dir')
    pp.add_argument('--out', required=True)
    pp.add_argument('--since', default=None)
    pp.add_argument('--tags', default=None)
    pp.add_argument('--max-rows-per-agent', type=int, default=None)
    pp.add_argument('--scrub', action='store_true')
    pp.add_argument('--donor-name', default=None)
    pp.add_argument(
        '--daemons-json',
        default=None,
        help='Pre-fetched `agentis daemon list --json` payload (shell wrapper passes this).',
    )

    up = sub.add_parser('unpack')
    up.add_argument('fed_dir')
    up.add_argument('pack')
    up.add_argument('--json', action='store_true')
    up.add_argument(
        '--daemons-json',
        default=None,
        help='Pre-fetched `agentis daemon list --json` payload (shell wrapper passes this).',
    )

    args = parser.parse_args(argv)
    if args.cmd == 'pack':
        return cmd_pack(args)
    if args.cmd == 'unpack':
        return cmd_unpack(args)
    parser.print_help()
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
