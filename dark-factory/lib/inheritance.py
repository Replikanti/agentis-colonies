#!/usr/bin/env python3
# inheritance.py — #1861 (epic #1831). THE SINGLE SOURCE OF TRUTH for "which contract actually implements
# this abstract base", consumed on BOTH reads of a target's code.
#
# WHY IT EXISTS. map-zones.sh splits a target by DIRECTORY, so on a codebase organised around abstract base
# contracts the base lands in one zone and every implementation in others. Both readers then reason about the
# base in ISOLATION: the hunter proposes an exploit against behaviour that is `virtual`/unimplemented there,
# and the refute gate correctly kills it because, in that file, the path does not exist. Measured on the
# diagnosing target's abstract-base zone: the gate discarded 21 of 22 candidates, 9 of them in the refuter's
# own "…in this contract contains no…" words, against 14-of-22 confirmed on a concrete-contract zone of the
# same target in the same run.
#
# WHAT IT DOES. Builds a regex inheritance index over the target's own Solidity sources and answers ONE
# question: given a file that declares an `abstract contract` with body-less `virtual` members, which SINGLE
# descendant is the most informative representative implementor, and which of its functions carry the base's
# virtual behaviour? Both consumers attach that ONE function-sliced file as an APPENDIX — never a whole file,
# never more than one file, never a change to zone identity:
#   map-zones.sh      appends the appendix token to the zone's `scope_files` (the hunter's payload)
#   verify-findings.sh slices the same implementor into the refute gate's per-candidate payload
#
# WHAT IT IS NOT. Not a Solidity front-end. There is no solc, no AST, no toolchain — this path must run
# offline on CI with python3 only. Parsing is regex + LOGICAL-DECLARATION accumulation (see _logical_decl),
# and EVERY named failure mode is made INERT (the edge is dropped -> no appendix -> today's behaviour
# exactly), never wrong:
#   (a) a base whose declaration lives outside the scanned set (vendored / pruned) simply ends the chain;
#   (b) C3 linearization is NOT modelled — `is A, B, C` is three flat edges, so a member actually resolved by
#       a sibling can rank a descendant slightly high (it changes WHICH implementor is picked, never whether
#       a whole file is attached);
#   (c) `interface` declares no bodies and is excluded from the trigger by keyword;
#   (d) a contract name declared in more than one SCANNED file is AMBIGUOUS and contributes no edge at all
#       (the diagnosing target really does ship two files differing only in filename case);
#   (e) the block-comment residual documented at map-zones.sh:180-186 is inherited unchanged — this is a
#       per-line scraper with no comment-state tracking, so a declaration inside a `/* ... */` block still
#       matches. Accepted and pinned there, not closed here;
#   (f) inheritance cycles are broken by a visited set keyed on the contract name.
#
# Subcommands:
#   appendix --zones <mechanical.json> --repo <dir>
#       Consumes map-zones.sh's already-filtered, already-grouped MECHANICAL zone model (so it inherits that
#       script's `find` prune list, its `--scope-hint` intersection and the #1824 path exclusion instead of
#       copying them) and prints the same JSON on stdout with, for each TRIGGERING zone:
#         - `scope_files` extended by at most ONE `path@fn+fn` appendix token, and
#         - two additive keys: `abstract_base: true` and `implementation_appendix: [ {base, contract,
#           implementor, implementor_contract, resolves[], unresolved[]} ]`.
#       `implementor: null` is the option-C fallback: the condition is RECORDED and nothing else changes.
#       `files`, `loc` and `hardening_score` are never touched, so zone identity is byte-identical.
#   implementor --repo <dir> --file <rel>
#       Prints `<implementor-rel>\t<fn1,fn2,…>` for the abstract contract declared in <rel>, or nothing.
#       Discovers sources itself with the same prune + exclusion list. NOTE: that list is a SEPARATE,
#       independently-maintained copy of map-zones.sh's (the same convention the repo already carries at
#       map-zones.sh:137-141 and :198-201) — two independently-maintained lists can drift; if you touch one,
#       check the other.
#
# Exit: 0 on success (including "nothing triggered"); 2 usage error; 3 unreadable input.
import json
import os
import re
import sys

# Mirror of map-zones.sh's `find` prune list (vendored deps + build output are never the target's own code).
PRUNE_DIRS = ("lib", "node_modules", "out", "cache", "artifacts", ".git")
# Mirror of map-zones.sh's #1824 EXCLUDED_ZONE_PREFIXES, segment-anchored exactly the same way.
EXCLUDED_ZONE_PREFIXES = ("test/", "tests/", "interfaces/", "mocks/", "script/")

# A logical declaration is accumulated over at most this many PHYSICAL lines, so a multi-line `is` list and
# the real-world `contract X layout at (2 ** 128) is Y {` shape both parse without the accumulator ever
# running away over a file that has no terminator at all.
MAX_DECL_LINES = 12

# Function-slice cap, deliberately the same flat 16 as map-zones.sh's FN_SLICE_CAP: the appendix is bounded
# by the same rule as every other slice in the pipeline, never by a private number.
FN_SLICE_CAP = 16

_CONTRACT_RE = re.compile(r"^\s*(?:(abstract)\s+)?(contract|interface|library)\s+([A-Za-z0-9_$]+)\b")
# Same anchoring as map-zones.sh's #1834 fn_names(): a line that (after only leading whitespace) STARTS with
# the `function` keyword immediately followed by a name and `(` — a real declaration, not the English word
# "function" in NatSpec prose.
_FUNCTION_RE = re.compile(r"^\s*function\s+([A-Za-z0-9_$]+)\s*\(")


def die(rc, msg):
    sys.stderr.write("inheritance.py: " + msg + "\n")
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


def is_excluded_zone_path(rel):
    """map-zones.sh's #1824 rule verbatim: a LEADING `<prefix>/` segment or a mid-path `/<prefix>/` segment,
    never a bare substring, plus the `.t.sol` suffix."""
    for p in EXCLUDED_ZONE_PREFIXES:
        if rel.startswith(p) or ("/" + p) in rel:
            return True
    return rel.endswith(".t.sol")


def discover_sources(repo):
    """Every Solidity source the target OWNS, repo-relative and sorted. Solidity only: inheritance is a
    Solidity concept, so the `.rs` half of map-zones.sh's source set is irrelevant here."""
    out = []
    for root, dirs, files in os.walk(repo):
        dirs[:] = sorted(d for d in dirs if d not in PRUNE_DIRS)
        for f in files:
            if not f.endswith(".sol"):
                continue
            rel = os.path.relpath(os.path.join(root, f), repo).replace(os.sep, "/")
            if is_excluded_zone_path(rel):
                continue
            out.append(rel)
    return sorted(out)


def _logical_decl(lines, i):
    """Accumulate the LOGICAL declaration that starts at physical line `i`: join lines up to and including the
    first `{` or `;`, bounded to MAX_DECL_LINES. Returns (text, terminator, last_index) where terminator is
    "{" (a body follows), ";" (declared without a body here) or "" (no terminator within the bound)."""
    buf = []
    last = i
    end = min(len(lines), i + MAX_DECL_LINES)
    for j in range(i, end):
        line = lines[j]
        buf.append(line.strip())
        last = j
        brace = line.find("{")
        semi = line.find(";")
        if brace >= 0 and (semi < 0 or brace < semi):
            return " ".join(buf), "{", last
        if semi >= 0:
            return " ".join(buf), ";", last
    return " ".join(buf), "", last


def _bases_of(decl_text):
    """The base list of a contract declaration: the segment after the LAST ` is ` before the terminator, with
    parenthesised constructor args stripped. Taking the LAST `is` is what makes `contract X layout at
    (2 ** 128) is Y {` parse as base Y rather than as the layout expression."""
    head = re.split(r"[{;]", decl_text, maxsplit=1)[0]
    last = None
    for m in re.finditer(r"\bis\b", head):
        last = m
    if last is None:
        return []
    seg = head[last.end():]
    prev = None
    while prev != seg:                      # strip nested `Base(arg, Inner(arg))` constructor args
        prev = seg
        seg = re.sub(r"\([^()]*\)", "", seg)
    bases = []
    for part in seg.split(","):
        m = re.match(r"^\s*([A-Za-z0-9_$]+)", part)
        if m and m.group(1) not in bases:
            bases.append(m.group(1))
    return bases


def parse_source(text):
    """Parse one Solidity source into its contract declarations.

    Returns a list of dicts {kind, abstract, name, bases, fns} where `fns` maps a declared function name to
    {"virtual": bool, "body": bool, "order": int}. A function is attributed to the most recent preceding
    contract declaration in the same file — a regex-level approximation that is exact for the one-contract-
    per-file shape the corpus actually ships and, when it is wrong, only mis-attributes a member (which can
    change WHICH implementor ranks first, never whether an appendix is attached at all)."""
    lines = text.splitlines()
    contracts = []
    current = None
    i = 0
    while i < len(lines):
        line = lines[i]
        cm = _CONTRACT_RE.match(line)
        if cm:
            decl, _term, last = _logical_decl(lines, i)
            current = {
                "kind": cm.group(2),
                "abstract": cm.group(1) is not None,
                "name": cm.group(3),
                "bases": _bases_of(decl),
                "fns": {},
            }
            contracts.append(current)
            i = last + 1
            continue
        fm = _FUNCTION_RE.match(line)
        if fm and current is not None:
            decl, term, last = _logical_decl(lines, i)
            name = fm.group(1)
            prev = current["fns"].get(name)
            entry = {
                "virtual": bool(re.search(r"\bvirtual\b", decl)),
                # A declaration that terminates in `;` has NO body in this file. An unterminated accumulation
                # (the MAX_DECL_LINES bound) is treated as "has a body": the inert direction, since it can
                # only fail to trigger, never fabricate a missing implementation.
                "body": term != ";",
                "order": len(current["fns"]),
            }
            if prev is not None:            # overload / redeclaration: OR the flags, keep the first slot
                entry["virtual"] = entry["virtual"] or prev["virtual"]
                entry["body"] = entry["body"] or prev["body"]
                entry["order"] = prev["order"]
            current["fns"][name] = entry
            i = last + 1
            continue
        i += 1
    return contracts


def _ordered_fns(contract, predicate):
    names = [n for n, m in contract["fns"].items() if predicate(m)]
    return sorted(names, key=lambda n: contract["fns"][n]["order"])


class Index(object):
    """The regex inheritance index over a fixed set of repo-relative Solidity sources."""

    def __init__(self, repo, rel_files):
        self.repo = repo
        self.by_name = {}       # contract name -> declaration (only names declared in exactly one file)
        self.ambiguous = set()  # failure mode (d): a name declared in >1 scanned file contributes no edge
        self.by_file = {}       # rel -> [declarations]
        self.children = {}      # base name -> [descendant names]
        self._loc = {}
        for rel in rel_files:
            try:
                with open(os.path.join(repo, rel), encoding="utf-8", errors="ignore") as fh:
                    text = fh.read()
            except OSError:
                continue
            self._loc[rel] = text.count("\n") + 1
            decls = parse_source(text)
            self.by_file[rel] = decls
            for d in decls:
                d["rel"] = rel
                name = d["name"]
                if name in self.ambiguous:
                    continue
                seen = self.by_name.get(name)
                if seen is None:
                    self.by_name[name] = d
                elif seen["rel"] != rel:
                    del self.by_name[name]
                    self.ambiguous.add(name)
        for name, d in self.by_name.items():
            for base in d["bases"]:
                if base in self.ambiguous:
                    continue
                self.children.setdefault(base, []).append(name)

    def loc(self, rel):
        return self._loc.get(rel, 0)

    def descendants(self, name):
        """Every transitive descendant as (name, hops), breadth-first. The visited set breaks inheritance
        cycles (failure mode (f)) and keeps the first — i.e. shortest — hop count for each name."""
        out = []
        seen = set([name])
        frontier = [name]
        hops = 0
        while frontier:
            hops += 1
            nxt = []
            for cur in frontier:
                for child in sorted(self.children.get(cur, [])):
                    if child in seen:
                        continue
                    seen.add(child)
                    out.append((child, hops))
                    nxt.append(child)
            frontier = nxt
        return out

    def abstract_bases_in(self, rel):
        """The declarations in <rel> that TRIGGER: an `abstract contract` with at least one `virtual` member
        whose logical declaration terminates in `;` (no body here). `interface` and `library` never trigger."""
        out = []
        for d in self.by_file.get(rel, []):
            if d["kind"] != "contract" or not d["abstract"]:
                continue
            if _ordered_fns(d, lambda m: m["virtual"] and not m["body"]):
                out.append(d)
        return out

    def rank_implementors(self, base):
        """Every descendant of `base` that resolves at least one of its body-less virtual members, ranked
        (resolved DESC, hops ASC, LOC ASC, path ASC) — the measured rule. It deliberately does NOT prefer
        concrete contracts: on the diagnosing target every concrete leaf resolves at most 2 of the 5 body-less
        virtuals, so "prefer concrete" would attach the LEAST informative file, while the 1-hop intermediate
        abstract subclass resolves 5 of 5. A descendant resolving NONE of them implements nothing of what the
        base is missing and is never a representative — the zone falls back to the option-C record instead."""
        bodyless = _ordered_fns(base, lambda m: m["virtual"] and not m["body"])
        bodied_virtual = _ordered_fns(base, lambda m: m["virtual"] and m["body"])
        ranked = []
        for name, hops in self.descendants(base["name"]):
            d = self.by_name.get(name)
            if d is None:
                continue
            resolves = [n for n in bodyless if d["fns"].get(n, {}).get("body")]
            if not resolves:
                continue
            # The slice also carries the base's virtual members the descendant OVERRIDES even though the base
            # DOES have a body for them — an override is exactly the behaviour the isolated base read misses.
            extra = [n for n in bodied_virtual if d["fns"].get(n, {}).get("body")]
            ranked.append({
                "key": (-len(resolves), hops, self.loc(d["rel"]), d["rel"]),
                "implementor": d["rel"],
                "implementor_contract": d["name"],
                "resolves": resolves,
                "unresolved": [n for n in bodyless if n not in resolves],
                "fns": (resolves + extra)[:FN_SLICE_CAP],
            })
        ranked.sort(key=lambda r: r["key"])
        return bodyless, ranked

    def entry_for(self, base):
        """The `implementation_appendix` entry for one triggering abstract base. `implementor: null` is the
        option-C fallback — the condition is recorded, nothing is attached."""
        bodyless, ranked = self.rank_implementors(base)
        entry = {
            "base": base["rel"],
            "contract": base["name"],
            "implementor": None,
            "implementor_contract": None,
            "resolves": [],
            "unresolved": bodyless,
        }
        if not ranked:
            return entry, None
        best = ranked[0]
        entry["implementor"] = best["implementor"]
        entry["implementor_contract"] = best["implementor_contract"]
        entry["resolves"] = best["resolves"]
        entry["unresolved"] = best["unresolved"]
        return entry, best

    def has_implementor_among(self, base, rel_files):
        """True when one of `rel_files` already declares a descendant that resolves at least one of the base's
        body-less virtual members — the same definition of "implementor" rank_implementors uses."""
        _bodyless, ranked = self.rank_implementors(base)
        wanted = set(rel_files)
        return any(r["implementor"] in wanted for r in ranked)


def read_json(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as e:
        die(3, "cannot read " + what + ": " + str(e))


def cmd_appendix(argv):
    flags = parse_flags(argv, ("--zones", "--repo"), ())
    zones_path = flags.get("--zones")
    repo = flags.get("--repo")
    if not zones_path or not repo:
        die(2, "appendix requires --zones <mechanical.json> --repo <dir>")
    if not os.path.isdir(repo):
        die(3, "--repo is not a directory: " + repo)
    zones = read_json(zones_path, "the mechanical zone model")
    if not isinstance(zones, list):
        die(3, "the mechanical zone model is not a JSON array")

    sources = []
    for z in zones:
        for f in z.get("files", []):
            if f.endswith(".sol") and f not in sources:
                sources.append(f)
    idx = Index(repo, sources)

    attached = []
    recorded = []
    for z in zones:
        zone_files = z.get("files", [])
        entries = []
        token = None
        for rel in zone_files:
            for base in idx.abstract_bases_in(rel):
                # The whole point of the appendix is the CROSS-ZONE case. A zone that already holds an
                # implementation is left completely alone — no token, no keys, a literal no-op.
                if idx.has_implementor_among(base, zone_files):
                    continue
                entry, best = idx.entry_for(base)
                entries.append(entry)
                # SIZE CEILING: at most ONE appendix token per zone, taken from the first entry that resolved
                # an implementor. Further entries stay in `implementation_appendix` so the condition is still
                # attributable, but they never add bytes to the payload.
                if best is not None and token is None:
                    token = best["implementor"] + "@" + "+".join(best["fns"])
        if not entries:
            continue
        z["abstract_base"] = True
        z["implementation_appendix"] = entries
        if token is not None:
            z["scope_files"] = list(z.get("scope_files", [])) + [token]
            attached.append(z["id"])
        else:
            recorded.append(z["id"])

    sys.stdout.write(json.dumps(zones))
    if attached or recorded:
        sys.stderr.write(
            "inheritance.py: implementation appendix attached to %d zone(s) [%s]; "
            "%d zone(s) abstract with no implementor anywhere [%s]\n"
            % (len(attached), ", ".join(attached) or "-", len(recorded), ", ".join(recorded) or "-")
        )
    return 0


def cmd_implementor(argv):
    flags = parse_flags(argv, ("--repo", "--file"), ())
    repo = flags.get("--repo")
    rel = flags.get("--file")
    if not repo or not rel:
        die(2, "implementor requires --repo <dir> --file <rel>")
    if not os.path.isdir(repo):
        die(3, "--repo is not a directory: " + repo)
    if rel.startswith("./"):
        rel = rel[2:]
    if not rel.endswith(".sol") or not os.path.isfile(os.path.join(repo, rel)):
        return 0
    # The candidate's own file may be excluded from `discover_sources` (a `mocks/` shim the operator reached
    # through --scope-hint, say), so index it explicitly: the trigger must be evaluated on the file the gate
    # actually staged, not on whether that file would have formed a zone.
    idx = Index(repo, sorted(set(discover_sources(repo)) | {rel}))
    best_overall = None
    for base in idx.abstract_bases_in(rel):
        _bodyless, ranked = idx.rank_implementors(base)
        if not ranked:
            continue
        if best_overall is None or ranked[0]["key"] < best_overall["key"]:
            best_overall = ranked[0]
    if best_overall is None:
        return 0
    sys.stdout.write(best_overall["implementor"] + "\t" + ",".join(best_overall["fns"]) + "\n")
    return 0


COMMANDS = {
    "appendix": cmd_appendix,
    "implementor": cmd_implementor,
}


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stdout.write("usage: inheritance.py <appendix|implementor> [flags]\n")
        return 0 if len(argv) >= 2 else 2
    cmd = COMMANDS.get(argv[1])
    if cmd is None:
        die(2, "unknown subcommand: " + argv[1])
    return cmd(argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
