#!/usr/bin/env python3
# project_roots.py — #2255. THE SINGLE SOURCE OF TRUTH for "which directories of this clone are separate
# Foundry/Hardhat projects", consumed by map-zones.sh (zone `root` keys), lib/inheritance.py (per-root
# inheritance partitions) and, later, the toolchain-root consumers of run-zone-hunt.sh.
#
# WHY IT EXISTS. A multi-project code repo (several nested project roots, each with its own foundry.toml or
# hardhat.config.*) used to be mapped through ONE of those roots only (the corpus row's single project_subdir),
# so every other root was never mapped, briefed or hunted. The fix keeps `--repo` = the CLONE ROOT and every
# path clone-root-relative; each zone of a multi-root target gains ONE additive key, `root` (its project root,
# relative to the clone root). Multi-root mode starts only when >= 2 roots are in effect, so a single-root
# target (0 or 1 root) takes no new code path and stays byte-identical.
#
# Subcommands (python3 stdlib only; the lib/ manual-flag idiom, no argparse):
#   detect --repo <dir>
#       Prints the sorted repo-relative dirs (`.` allowed) that hold foundry.toml or hardhat.config.{js,ts,cjs,
#       mjs}, one per line. The walk PRUNES map-zones.sh's `find` prune list (lib node_modules out cache
#       artifacts .git) and the #1824 segments (test tests mocks script interfaces), so a vendored, test or mock
#       config is never a root.
#   resolve --repo <dir> [--roots <csv>]
#       With --roots: the validated explicit list (relative, no `..`, an existing dir under --repo,
#       deduplicated, sorted). A single entry other than `.` is an error (pass --repo <repo>/<root> instead);
#       `.` alone gives `.`, i.e. single-root — the opt-out that turns detection off. Without --roots (or with
#       an empty value): detect. Exit 2 on an invalid list.
#   zone-roots --zones <zones.json>
#       Prints `<zone id>\t<root>` for every zone that carries a `root` key (nothing for a single-root map).
#   of --zones <zones.json> --repo <dir> --path <rel>
#       Prints `<root>\t<path within that root>` for a clone-relative path, using the distinct roots of the
#       map. When no root prefix matches, falls back to the ONE root R for which <repo>/R/<path> exists (so a
#       root-relative path still resolves). Prints nothing when the path cannot be resolved.
#
# Exit: 0 on success; 2 usage error / invalid explicit list; 3 unreadable input.
import json
import os
import re
import sys

# Mirror of map-zones.sh's `find` prune list (vendored deps + build output) — the same list lib/inheritance.py
# carries. Two independently-maintained lists can drift; if you touch one, check the others.
PRUNE_DIRS = ("lib", "node_modules", "out", "cache", "artifacts", ".git")
# The #1824 directory segments (map-zones.sh's EXCLUDED_ZONE_PREFIXES without the trailing `/`): a config under
# one of them belongs to a test/mock/script fixture, never to a project root of the target.
EXCLUDED_SEGMENTS = ("test", "tests", "mocks", "script", "interfaces")
CONFIG_FILES = ("foundry.toml", "hardhat.config.js", "hardhat.config.ts", "hardhat.config.cjs",
                "hardhat.config.mjs")


def die(rc, msg):
    sys.stderr.write("project_roots.py: " + msg + "\n")
    sys.exit(rc)


def parse_flags(argv, valued, boolean):
    """Manual flag walk (the repo's helper idiom — no argparse; see lib/zone-coverage.py). Unknown flags and
    missing values are usage errors, never silent."""
    out = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in valued:
            if i + 1 >= len(argv):
                die(2, a + " requires a value")
            out[a] = argv[i + 1]
            i += 2
        elif a in boolean:
            out[a] = True
            i += 1
        else:
            die(2, "unknown arg: " + a)
    return out


def detect(repo):
    """The sorted repo-relative project-root dirs of <repo> (`.` = the repo itself)."""
    roots = []
    for cur, dirs, files in os.walk(repo):
        dirs[:] = sorted(d for d in dirs if d not in PRUNE_DIRS and d not in EXCLUDED_SEGMENTS)
        if any(f in CONFIG_FILES for f in files):
            rel = os.path.relpath(cur, repo).replace(os.sep, "/")
            roots.append(rel)
    return sorted(roots)


def _normalise(entry):
    p = entry.strip().replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    p = p.rstrip("/")
    return p or "."


def resolve(repo, explicit):
    """The roots in effect: the validated explicit list, else detect(). Raises ValueError on an invalid list."""
    if explicit is None or not explicit.strip():
        return detect(repo)
    out = []
    for raw in re.split(r"[,\s]+", explicit):
        if not raw.strip():
            continue
        p = _normalise(raw)
        if p.startswith("/") or ".." in p.split("/"):
            raise ValueError("project root '%s' must be relative to --repo and must not contain '..'" % raw)
        if not os.path.isdir(os.path.join(repo, p)):
            raise ValueError("project root '%s' is not a directory under --repo" % raw)
        if p not in out:
            out.append(p)
    out.sort()
    if not out:
        return detect(repo)
    if len(out) == 1 and out[0] != ".":
        raise ValueError("a single project root '%s' is not a multi-root target: pass --repo <repo>/%s instead"
                         % (out[0], out[0]))
    return out


def root_of(rel, roots):
    """The project root holding the clone-relative path <rel>: a segment-anchored longest-prefix match, with
    `.` matching last. None when no root contains the path."""
    best = None
    for r in roots:
        if r == ".":
            continue
        if rel == r or rel.startswith(r + "/"):
            if best is None or len(r) > len(best):
                best = r
    if best is None and "." in roots:
        return "."
    return best


def _read_zones(path):
    try:
        with open(path, encoding="utf-8") as fh:
            zones = json.load(fh)
    except (OSError, ValueError) as e:
        die(3, "cannot read zones.json: " + str(e))
    return zones if isinstance(zones, list) else []


def _zone_roots(zones):
    out = []
    for z in zones:
        if isinstance(z, dict) and z.get("id") and z.get("root"):
            out.append((z["id"], z["root"]))
    return out


def cmd_detect(argv):
    flags = parse_flags(argv, ("--repo",), ())
    repo = flags.get("--repo")
    if not repo:
        die(2, "detect requires --repo <dir>")
    if not os.path.isdir(repo):
        die(3, "--repo is not a directory: " + repo)
    for r in detect(repo):
        sys.stdout.write(r + "\n")
    return 0


def cmd_resolve(argv):
    flags = parse_flags(argv, ("--repo", "--roots"), ())
    repo = flags.get("--repo")
    if not repo:
        die(2, "resolve requires --repo <dir> [--roots <csv>]")
    if not os.path.isdir(repo):
        die(3, "--repo is not a directory: " + repo)
    try:
        roots = resolve(repo, flags.get("--roots"))
    except ValueError as e:
        die(2, str(e))
    for r in roots:
        sys.stdout.write(r + "\n")
    return 0


def cmd_zone_roots(argv):
    flags = parse_flags(argv, ("--zones",), ())
    if not flags.get("--zones"):
        die(2, "zone-roots requires --zones <zones.json>")
    for zid, root in _zone_roots(_read_zones(flags["--zones"])):
        sys.stdout.write("%s\t%s\n" % (zid, root))
    return 0


def cmd_of(argv):
    flags = parse_flags(argv, ("--zones", "--repo", "--path"), ())
    for req in ("--zones", "--repo", "--path"):
        if not flags.get(req):
            die(2, "of requires --zones <zones.json> --repo <dir> --path <rel>")
    repo = flags["--repo"]
    rel = _normalise(flags["--path"])
    roots = sorted(set(r for _zid, r in _zone_roots(_read_zones(flags["--zones"]))))
    if not roots:
        return 0
    root = root_of(rel, roots)
    if root is not None:
        within = rel if root == "." else (rel[len(root) + 1:] if rel != root else "")
        sys.stdout.write("%s\t%s\n" % (root, within))
        return 0
    # A root-relative path (no root prefix): resolve it only when exactly ONE root holds it.
    hits = [r for r in roots if os.path.exists(os.path.join(repo, r, rel))]
    if len(hits) == 1:
        sys.stdout.write("%s\t%s\n" % (hits[0], rel))
    return 0


def main(argv):
    cmds = {"detect": cmd_detect, "resolve": cmd_resolve, "zone-roots": cmd_zone_roots, "of": cmd_of}
    if len(argv) < 2 or argv[1] not in cmds:
        die(2, "usage: project_roots.py {detect|resolve|zone-roots|of} [flags]")
    return cmds[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
