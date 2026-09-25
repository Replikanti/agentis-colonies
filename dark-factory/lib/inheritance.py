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
#       #2255: on a MULTI-ROOT model (zones carrying a `root` key) ONE Index is built per root partition, over
#       the sources of that root's zones only, so a contract name declared in two project roots is no longer
#       ambiguous (failure mode (d)). Zones without `root` form one partition — the single-root path, unchanged.
#   implementor --repo <dir> --file <rel>
#       Prints `<implementor-rel>\t<fn1,fn2,…>` for the abstract contract declared in <rel>, or nothing.
#       #2255: when lib/project_roots.py detects >= 2 project roots under <dir> and <rel> lies under a root R
#       other than `.`, sources are discovered under <dir>/R only and the implementor is printed re-prefixed
#       with `R/` (still relative to <dir>). Otherwise the output is byte-identical to before.
#       Discovers sources itself with the same prune + exclusion list. NOTE: that list is a SEPARATE,
#       independently-maintained copy of map-zones.sh's (the same convention the repo already carries at
#       map-zones.sh:137-141 and :198-201) — two independently-maintained lists can drift; if you touch one,
#       check the other.
#   reach-targets / reach-inventory — #2245 iteration 6 (deep-hunt REACH), documented at their block below.
#   promise-sources --repo <dir> --target <rel[:Name]> --out <file>
#       #2245 iteration 7 (deep-hunt PROMISES): the line-numbered source listing the invariant prover reads to
#       extract the target's user-facing promises. Documented at its block below.
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

    # #2255: one Index per project-root partition. Zones without a `root` key (every zone of a single-root map)
    # share the `None` partition, whose source list is built exactly as before this issue.
    part_sources = {}
    for z in zones:
        sources = part_sources.setdefault(z.get("root"), [])
        for f in z.get("files", []):
            if f.endswith(".sol") and f not in sources:
                sources.append(f)
    indexes = dict((key, Index(repo, sources)) for key, sources in part_sources.items())

    attached = []
    recorded = []
    for z in zones:
        idx = indexes[z.get("root")]
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
    # #2255: on a multi-root clone, index only the project root holding <rel> and re-prefix the answer with it.
    # A single-root clone (0 or 1 detected root), a file under `.` / outside every root, and an absent helper all
    # take today's path.
    prefix = ""
    try:
        pr = _project_roots()
    except ImportError:
        pr = None
    roots = pr.detect(repo) if pr is not None else []
    if len(roots) >= 2:
        root = pr.root_of(rel, roots)
        if root is not None and root != ".":
            repo = os.path.join(repo, root)
            rel = rel[len(root) + 1:]
            prefix = root + "/"
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
    sys.stdout.write(prefix + best_overall["implementor"] + "\t" + ",".join(best_overall["fns"]) + "\n")
    return 0


def _project_roots():
    """lib/project_roots.py (#2255), imported lazily from this file's own directory."""
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    sys.dont_write_bytecode = True      # never leave a __pycache__/ next to the shipped helpers
    import project_roots
    return project_roots


# ================================================================================================
# #2245 (iteration 6) — DEEP-HUNT REACH. Two ADDITIVE subcommands that extend the same regex index this file
# already owns; parse_source / Index / discover_sources / PRUNE_DIRS and the appendix/implementor output above
# are byte-for-byte UNCHANGED (demo-map-zones.sh + demo-verify-findings.sh pin them). Every REACH failure mode
# is INERT the same way the appendix's are: fewer entry points / collaborators, never fabricated ones.
#
#   reach-targets --zones <zones.json> --repo <dir> --max <N>
#       Up to N concrete deploy targets per zone, greedy by the zone's state-changing entry points a candidate
#       owns or inherits. An abstract base is never emitted when it has a concrete subclass. TSV:
#         zid \t rel:ContractName \t new_covered \t total \t in_zone|out_zone
#   reach-inventory --repo <staged repo> --target <rel[:Name]> --out-tsv <f> --out-inventory <f> [--fork] [--aux <rel[:Name]>]...
#       The per-target entry-point denominator (own state-changing fns + vendored no-modifier fns, inherited
#       included) + the deployment inventory (constructor/initializer signatures + resolved collaborators).

# Own-source set for the inventory INCLUDES interfaces/ (a collaborator is often typed by its interface) but
# still excludes generated / non-shipping code. discover_sources()'s EXCLUDED_ZONE_PREFIXES drops interfaces/,
# so the inventory uses its OWN discovery list (a separate, independently-maintained copy — the same convention
# the appendix/implementor split already carries).
INVENTORY_EXCLUDED_PREFIXES = ("test/", "tests/", "mocks/", "script/")
# Vendored dependency roots, scanned lazily only when a base name is NOT own-source (the ERC-20 transfer path,
# a messaging receiver, ...). PRUNE_DIRS keeps these OUT of the own-source walk; here they are the fallback.
VENDORED_DIRS = ("lib", "node_modules", "dependencies")
# The cap precedent from iteration 5: at most this many entry points are gated; names past it are recorded as
# OVERCAP| and never counted against coverage.
REACH_EP_CAP = 20
# The initializer family never counts as a deployable action (it runs once in setUp).
_INITIALIZER_MODS = ("initializer", "reinitializer", "onlyInitializing")
# Tokens in a function header tail that are NOT modifiers.
_FN_RESERVED = ("external", "public", "internal", "private", "view", "pure", "payable",
                "virtual", "override", "returns", "constant")
_CTOR_RE = re.compile(r"^\s*constructor\s*\(")
_IDENT_RE = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")
# A state variable typed as a PascalCase identifier (a contract/interface type — the only ones we resolve as a
# collaborator). Deliberately conservative: a lowercase primitive (uint256/address/bool) is not a collaborator.
_STATEVAR_RE = re.compile(
    r"^\s*([A-Z][A-Za-z0-9_$]*)\s+(?:public\s+|private\s+|internal\s+|immutable\s+|constant\s+|override\s+)*"
    r"([A-Za-z_$][A-Za-z0-9_$]*)\s*[;=]")


def _clean_decl(decl):
    """Collapse a logical declaration to its header (up to the first `{`/`;`), single-spaced."""
    head = re.split(r"[{;]", decl, maxsplit=1)[0]
    return re.sub(r"\s+", " ", head).strip()


def _match_paren(text, open_idx):
    """Return (inner, tail) where inner is the text between the paren at open_idx and its match, tail is the
    rest. Returns (None, None) when unbalanced within the string."""
    depth = 0
    i = open_idx
    while i < len(text):
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i], text[i + 1:]
        i += 1
    return None, None


def _split_params(params):
    """A Solidity parameter list -> [(type, name)]. Top-level comma split (parens/brackets are balanced), then
    type = first token, name = last token (dropping a lone data-location keyword)."""
    segs = []
    depth = 0
    cur = ""
    for ch in params:
        if ch in "([{":
            depth += 1
            cur += ch
        elif ch in ")]}":
            depth -= 1
            cur += ch
        elif ch == "," and depth == 0:
            segs.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        segs.append(cur)
    out = []
    for s in segs:
        toks = s.split()
        if not toks:
            continue
        typ = toks[0]
        name = toks[-1] if len(toks) >= 2 else ""
        if name in ("memory", "calldata", "storage"):
            name = ""
        out.append((typ, name))
    return out


def _split_fn_header(decl):
    """A logical `function` declaration -> (name, [(type,name)], tail_kw) or None. tail_kw is the text AFTER the
    parameter list with every parenthesised group removed, so a keyword scan sees only bare tokens (visibility,
    mutability, `returns`, modifier names)."""
    m = re.search(r"\bfunction\s+([A-Za-z0-9_$]+)\s*\(", decl)
    if not m:
        return None
    name = m.group(1)
    inner, tail = _match_paren(decl, m.end() - 1)
    if inner is None:
        return None
    tail = re.split(r"[{;]", tail, maxsplit=1)[0]
    prev = None
    while prev != tail:
        prev = tail
        tail = re.sub(r"\([^()]*\)", "", tail)
    return name, _split_params(inner), tail


def _visibility(tail_kw):
    for tok in _IDENT_RE.findall(tail_kw):
        if tok in ("external", "public", "internal", "private"):
            return tok
    return "internal"


def _mutability(tail_kw):
    for tok in _IDENT_RE.findall(tail_kw):
        if tok in ("view", "pure", "payable"):
            return tok
    return "nonpayable"


def _modifiers(tail_kw):
    return [tok for tok in _IDENT_RE.findall(tail_kw) if tok not in _FN_RESERVED]


def parse_entry_points(text):
    """Parse one Solidity source into contract declarations carrying full entry-point detail. Reuses the SAME
    _CONTRACT_RE / _FUNCTION_RE / _logical_decl / _bases_of primitives parse_source uses, so a multi-line header
    (the held-out router's 7-line `liquidateCrossChain(`) parses the same way its `is` list does. Returns a list
    of dicts {kind, abstract, name, bases, functions[], constructor, initializers[], state_vars[]}."""
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
                "functions": [],
                "constructor": None,
                "initializers": [],
                "state_vars": [],
            }
            contracts.append(current)
            i = last + 1
            continue
        if current is not None:
            if _CTOR_RE.match(line):
                decl, _term, last = _logical_decl(lines, i)
                m = re.search(r"\bconstructor\s*\(", decl)
                inner, _tail = _match_paren(decl, m.end() - 1) if m else (None, None)
                current["constructor"] = {
                    "params": _split_params(inner) if inner is not None else [],
                    "raw": _clean_decl(decl),
                }
                i = last + 1
                continue
            fm = _FUNCTION_RE.match(line)
            if fm:
                decl, term, last = _logical_decl(lines, i)
                parsed = _split_fn_header(decl)
                if parsed is not None:
                    name, plist, tail_kw = parsed
                    vis = _visibility(tail_kw)
                    mut = _mutability(tail_kw)
                    mods = _modifiers(tail_kw)
                    is_init = name.startswith("initialize") or any(x in _INITIALIZER_MODS for x in mods)
                    fn = {
                        "name": name,
                        "visibility": vis,
                        "mutability": mut,
                        "modifiers": mods,
                        "params": plist,
                        "signature": name + "(" + ",".join(t for t, _n in plist) + ")",
                        "body": term != ";",
                        "is_initializer": is_init,
                        "state_changing": vis in ("external", "public") and mut not in ("view", "pure"),
                    }
                    current["functions"].append(fn)
                    if is_init:
                        current["initializers"].append(fn)
                i = last + 1
                continue
            sv = _STATEVAR_RE.match(line)
            if sv and sv.group(1) not in _FN_RESERVED:
                current["state_vars"].append((sv.group(1), sv.group(2)))
                i += 1
                continue
        i += 1
    return contracts


def discover_inventory_sources(repo):
    """Own-source Solidity for the inventory: like discover_sources but INCLUDING interfaces/, EXCLUDING
    test/mocks/script (a collaborator is often typed by its interface, which discover_sources prunes)."""
    out = []
    for root, dirs, files in os.walk(repo):
        dirs[:] = sorted(d for d in dirs if d not in PRUNE_DIRS)
        for f in files:
            if not f.endswith(".sol"):
                continue
            rel = os.path.relpath(os.path.join(root, f), repo).replace(os.sep, "/")
            skip = False
            for p in INVENTORY_EXCLUDED_PREFIXES:
                if rel.startswith(p) or ("/" + p) in rel:
                    skip = True
                    break
            if skip or rel.endswith(".t.sol"):
                continue
            out.append(rel)
    return sorted(out)


class OwnInventory(object):
    """Own-source contract/interface declarations parsed for entry-point detail, keyed by name (ambiguous names
    — declared in >1 file — are dropped, the same inert rule Index uses)."""

    def __init__(self, repo, rel_files):
        self.repo = repo
        self.by_name = {}       # name -> (rel, decl)
        self.ambiguous = set()
        for rel in rel_files:
            try:
                with open(os.path.join(repo, rel), encoding="utf-8", errors="ignore") as fh:
                    text = fh.read()
            except OSError:
                continue
            for d in parse_entry_points(text):
                nm = d["name"]
                if nm in self.ambiguous:
                    continue
                if nm in self.by_name:
                    if self.by_name[nm][0] != rel:
                        del self.by_name[nm]
                        self.ambiguous.add(nm)
                else:
                    self.by_name[nm] = (rel, d)

    def get(self, name):
        return self.by_name.get(name)

    def implementors_of(self, iface):
        """Own-source non-abstract contracts whose transitive base set includes `iface`."""
        out = []
        for nm, (rel, d) in self.by_name.items():
            if d["kind"] != "contract" or d["abstract"]:
                continue
            if iface in self._all_bases(nm):
                out.append(nm)
        return sorted(out)

    def _all_bases(self, name):
        seen = set()
        frontier = [name]
        while frontier:
            nxt = []
            for cur in frontier:
                got = self.by_name.get(cur)
                if got is None:
                    continue
                for b in got[1]["bases"]:
                    if b not in seen:
                        seen.add(b)
                        nxt.append(b)
            frontier = nxt
        return seen


class VendoredIndex(object):
    """Lazily built name -> [(rel, decl)] index over the vendored dependency roots. Only consulted for a base
    name that is NOT own-source (the ERC-20 transfer family, a messaging receiver, ...)."""

    def __init__(self, repo):
        self.repo = repo
        self._built = False
        self.by_name = {}

    def _build(self):
        if self._built:
            return
        self._built = True
        for vd in VENDORED_DIRS:
            base = os.path.join(self.repo, vd)
            if not os.path.isdir(base):
                continue
            for root, dirs, files in os.walk(base):
                dirs[:] = sorted(d for d in dirs if d not in (".git", "out", "cache", "artifacts"))
                for f in files:
                    if not f.endswith(".sol") or f.endswith(".t.sol"):
                        continue
                    rel = os.path.relpath(os.path.join(root, f), self.repo).replace(os.sep, "/")
                    try:
                        with open(os.path.join(self.repo, rel), encoding="utf-8", errors="ignore") as fh:
                            text = fh.read()
                    except OSError:
                        continue
                    for d in parse_entry_points(text):
                        self.by_name.setdefault(d["name"], []).append((rel, d))

    def pick(self, name, import_paths):
        """Resolve a vendored base name to one (rel, decl). Tie-break: (1) a path the referencing file imports,
        (2) shortest path, (3) lexicographic."""
        self._build()
        cands = self.by_name.get(name)
        if not cands:
            return None
        imported = [c for c in cands if any(c[0].endswith(p) or p.endswith(c[0].rsplit("/", 1)[-1]) for p in import_paths)]
        pool = imported if imported else cands
        return sorted(pool, key=lambda c: (len(c[0]), c[0]))[0]


def _import_targets(text):
    """The import path tails a file references, e.g. `.../ERC20/ERC20Upgradeable.sol` — used only as a vendored
    tie-break hint, never a hard requirement."""
    return [m.group(1) for m in re.finditer(r'import[^"\']*["\']([^"\']+)["\']', text)]


def zone_entry_points(inv, zone_files):
    """The state-changing external/public entry-point NAMES declared in a zone's OWN files (initializer family
    excluded), plus a map name -> set(declaring contract names)."""
    names = set()
    declared_by = {}
    # Re-parse per file so a multi-contract file attributes each entry point to its declaring contract.
    for rel in zone_files:
        if not (isinstance(rel, str) and rel.endswith(".sol")):
            continue
        try:
            with open(os.path.join(inv.repo, rel), encoding="utf-8", errors="ignore") as fh:
                text = fh.read()
        except OSError:
            continue
        for d in parse_entry_points(text):
            if d["kind"] != "contract":
                continue
            for fn in d["functions"]:
                if fn["state_changing"] and not fn["is_initializer"]:
                    names.add(fn["name"])
                    declared_by.setdefault(fn["name"], set()).add(d["name"])
    return names, declared_by


def _own_ancestors(inv, name):
    """The own-source ancestor closure of `name` (itself excluded), transitive."""
    seen = set()
    frontier = [name]
    while frontier:
        nxt = []
        for cur in frontier:
            got = inv.get(cur)
            if got is None:
                continue
            for b in got[1]["bases"]:
                if b not in seen and b != name:
                    seen.add(b)
                    nxt.append(b)
        frontier = nxt
    return seen


def _contract_state_changing_names(decl):
    return set(fn["name"] for fn in decl["functions"] if fn["state_changing"] and not fn["is_initializer"])


def _target_total_eps(inv, vendored, name):
    """The size of the full entry-point list (own + vendored inherited, deduped by name) — the reach-inventory
    denominator, used as a greedy tie-break. Bounded, so computing it per candidate is cheap."""
    eps, _types, _over = _collect_entry_points(inv, vendored, name, [])
    return len(eps)


def cmd_reach_targets(argv):
    flags = parse_flags(argv, ("--zones", "--repo", "--max"), ())
    zones_path = flags.get("--zones")
    repo = flags.get("--repo")
    if not zones_path or not repo:
        die(2, "reach-targets requires --zones <zones.json> --repo <dir> [--max N]")
    if not os.path.isdir(repo):
        die(3, "--repo is not a directory: " + repo)
    try:
        max_n = int(flags.get("--max", "3"))
    except ValueError:
        die(2, "--max must be an integer")
    if max_n < 1:
        max_n = 1
    zones = read_json(zones_path, "the zone model")
    if not isinstance(zones, list):
        die(3, "the zone model is not a JSON array")

    inv = OwnInventory(repo, discover_inventory_sources(repo))
    vendored = VendoredIndex(repo)
    idx = Index(repo, discover_sources(repo))

    for z in zones:
        zone_files = [f for f in z.get("files", []) if isinstance(f, str) and f.endswith(".sol")]
        zid = z.get("id", "")
        if not zid or not zone_files:
            continue
        zone_eps, _declared = zone_entry_points(inv, zone_files)
        if not zone_eps:
            continue
        zone_file_set = set(zone_files)
        # Candidates: non-abstract contracts declared in the zone, plus non-abstract own-source descendants of
        # any abstract contract declared in the zone (the concrete subclass that replaces an abstract base).
        candidate_names = set()
        for rel in zone_files:
            try:
                with open(os.path.join(repo, rel), encoding="utf-8", errors="ignore") as fh:
                    decls = parse_entry_points(fh.read())
            except OSError:
                decls = []
            for d in decls:
                if d["kind"] == "contract" and not d["abstract"]:
                    candidate_names.add(d["name"])
                if d["kind"] == "contract" and d["abstract"]:
                    for desc, _hops in idx.descendants(d["name"]):
                        dd = inv.get(desc)
                        if dd is not None and dd[1]["kind"] == "contract" and not dd[1]["abstract"]:
                            candidate_names.add(desc)
        # Precompute per-candidate coverage set (zone eps declared by the candidate or its own ancestors).
        cand = []
        for nm in candidate_names:
            got = inv.get(nm)
            if got is None:
                continue
            rel, decl = got
            covers = set(_contract_state_changing_names(decl))
            for anc in _own_ancestors(inv, nm):
                ag = inv.get(anc)
                if ag is not None:
                    covers |= _contract_state_changing_names(ag[1])
            covers &= zone_eps
            in_zone = rel in zone_file_set
            total = _target_total_eps(inv, vendored, nm)
            cand.append({"name": nm, "rel": rel, "covers": covers, "in_zone": in_zone,
                         "total": total, "loc": idx.loc(rel)})
        # Greedy: repeatedly take the candidate adding the most still-uncovered zone entry points.
        covered = set()
        picked = []
        chosen = set()
        while len(picked) < max_n:
            best = None
            for c in cand:
                if c["name"] in chosen:
                    continue
                new_covered = len(c["covers"] - covered)
                if new_covered <= 0:
                    continue
                key = (-new_covered, 0 if c["in_zone"] else 1, -c["total"], -c["loc"], c["rel"], c["name"])
                if best is None or key < best[0]:
                    best = (key, c, new_covered)
            if best is None:
                break
            _key, c, new_covered = best
            chosen.add(c["name"])
            covered |= c["covers"]
            picked.append((c, new_covered))
        for c, new_covered in picked:
            sys.stdout.write("%s\t%s:%s\t%d\t%d\t%s\n" % (
                zid.replace("\t", " "), c["rel"], c["name"], new_covered, c["total"],
                "in_zone" if c["in_zone"] else "out_zone"))
    return 0


def _resolve_target(inv, repo, target):
    """Resolve --target <rel[:Name]> to (rel, decl). With :Name it is authoritative; else the contract named
    after the file, else the largest non-abstract contract, else the first contract."""
    rel = target
    name = None
    if ":" in target:
        rel, name = target.rsplit(":", 1)
    if rel.startswith("./"):
        rel = rel[2:]
    path = os.path.join(repo, rel)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            decls = parse_entry_points(fh.read())
    except OSError:
        return None
    if not decls:
        return None
    if name is not None:
        for d in decls:
            if d["name"] == name:
                return rel, d
        return None
    base = os.path.basename(rel)[:-4]
    for d in decls:
        if d["name"] == base and d["kind"] == "contract" and not d["abstract"]:
            return rel, d
    concrete = [d for d in decls if d["kind"] == "contract" and not d["abstract"]]
    if concrete:
        return rel, sorted(concrete, key=lambda d: -len(d["functions"]))[0]
    return rel, decls[0]


def _collect_entry_points(inv, vendored, target_name, import_paths):
    """BFS the target's base graph most-derived first. Returns (eps, type_names, overcap). Each ep entry is
    {name, declarer, kind(own|vendored), modifier, signature}. Own state-changing fns count whatever their
    modifiers (a role-gated one is marked); vendored ones count ONLY with no modifier. Deduped by name; capped
    at REACH_EP_CAP with the rest recorded as overcap."""
    eps = []
    seen_names = set()
    type_names = [target_name]
    overcap = []
    visited = set()
    frontier = [target_name]
    while frontier:
        nxt = []
        for nm in frontier:
            if nm in visited:
                continue
            visited.add(nm)
            got = inv.get(nm)
            is_own = got is not None
            if got is None:
                got = vendored.pick(nm, import_paths)
                if got is None:
                    continue
            rel, decl = got
            for b in decl["bases"]:
                if b not in type_names:
                    type_names.append(b)
                if b not in visited:
                    nxt.append(b)
            for fn in decl["functions"]:
                if not fn["state_changing"] or fn["is_initializer"]:
                    continue
                if not is_own and fn["modifiers"]:
                    continue
                if fn["name"] in seen_names:
                    continue
                seen_names.add(fn["name"])
                modifier = fn["modifiers"][0] if fn["modifiers"] else "-"
                entry = {"name": fn["name"], "declarer": nm,
                         "kind": "own" if is_own else "vendored",
                         "modifier": modifier, "signature": fn["signature"]}
                if len(eps) < REACH_EP_CAP:
                    eps.append(entry)
                else:
                    overcap.append(fn["name"])
        frontier = nxt
    return eps, type_names, overcap


def _rel_import(rel):
    """The GLOBAL import line relative to the test dir (test/ is one level under the repo root)."""
    return 'import "../' + rel + '";'


def cmd_reach_inventory(argv):
    flags = {}
    aux = []
    i = 0
    valued = ("--repo", "--target", "--out-tsv", "--out-inventory")
    while i < len(argv):
        a = argv[i]
        if a == "--fork":
            flags["--fork"] = True
            i += 1
        elif a == "--aux":
            if i + 1 >= len(argv):
                die(2, "--aux requires a value")
            aux.append(argv[i + 1])
            i += 2
        elif a in valued:
            if i + 1 >= len(argv):
                die(2, a + " requires a value")
            flags[a] = argv[i + 1]
            i += 2
        else:
            die(2, "unknown arg: " + a)
    repo = flags.get("--repo")
    target = flags.get("--target")
    out_tsv = flags.get("--out-tsv")
    out_inv = flags.get("--out-inventory")
    if not repo or not target or not out_tsv or not out_inv:
        die(2, "reach-inventory requires --repo --target --out-tsv --out-inventory")
    if not os.path.isdir(repo):
        die(3, "--repo is not a directory: " + repo)

    inv = OwnInventory(repo, discover_inventory_sources(repo))
    vendored = VendoredIndex(repo)
    resolved = _resolve_target(inv, repo, target)
    if resolved is None:
        # Inert: no target -> empty files -> the prover's reachOn is false -> today's behaviour.
        _write_files(out_tsv, out_inv, "", "")
        return 0
    rel, decl = resolved
    try:
        with open(os.path.join(repo, rel), encoding="utf-8", errors="ignore") as fh:
            target_text = fh.read()
    except OSError:
        target_text = ""
    import_paths = _import_targets(target_text)
    eps, type_names, overcap = _collect_entry_points(inv, vendored, decl["name"], import_paths)

    tsv = []
    tsv.append("TARGET|%s|%s" % (rel, decl["name"]))
    tsv.append("TYPES|%s" % ",".join(type_names))
    for e in eps:
        tsv.append("EP|%s|%s|%s|%s|%s" % (e["name"], e["declarer"], e["kind"], e["modifier"], e["signature"]))
    for nm in overcap:
        tsv.append("OVERCAP|%s" % nm)

    fork = bool(flags.get("--fork"))
    inventory_text = _render_inventory(inv, vendored, repo, rel, decl, eps, aux, fork)
    _write_files(out_tsv, out_inv, "\n".join(tsv) + "\n", inventory_text)
    return 0


def _write_files(out_tsv, out_inv, tsv_text, inv_text):
    with open(out_tsv, "w", encoding="utf-8") as fh:
        fh.write(tsv_text)
    with open(out_inv, "w", encoding="utf-8") as fh:
        fh.write(inv_text)


def _collaborators(inv, repo, decl):
    """Resolve up to 8 one-hop collaborators of the target from constructor/initializer params typed as an
    own-source contract/interface, address params named after an own-source contract, and typed state vars.
    Returns an ORDERED list of (id_hint, resolved_name_or_None, kind)."""
    seen = []
    order = []

    def consider(hint, typ):
        typ = typ.rstrip("[]")
        got = inv.get(typ)
        if got is not None and got[1]["kind"] == "contract":
            return typ
        if got is not None and got[1]["kind"] == "interface":
            impls = inv.implementors_of(typ)
            if len(impls) == 1:
                return impls[0]
            return None
        return None

    def add(hint, resolved):
        key = resolved or hint
        if key in seen:
            return
        seen.append(key)
        order.append((hint, resolved))

    params = []
    if decl["constructor"]:
        params += decl["constructor"]["params"]
    for fn in decl["initializers"]:
        params += fn["params"]
    for typ, nm in params:
        r = consider(nm, typ)
        if r is not None:
            add(nm or typ, r)
        elif typ == "address" and nm:
            stripped = nm.strip("_")
            for cnm in inv.by_name:
                if cnm.lower() == stripped.lower():
                    add(nm, cnm)
                    break
            else:
                add(nm, None)
    for typ, nm in decl["state_vars"]:
        r = consider(nm, typ)
        if r is not None:
            add(nm or typ, r)
    return order[:8]


def _calls_on(target_text, id_hint):
    """Up to 12 distinct call shapes the target makes on a collaborator id: `<id>.<fn>(` and `<Type>(...<id>...).<fn>(`."""
    calls = []
    for m in re.finditer(re.escape(id_hint) + r"\.([A-Za-z0-9_$]+)\s*\(", target_text):
        c = id_hint + "." + m.group(1) + "("
        if c not in calls:
            calls.append(c)
        if len(calls) >= 12:
            break
    return calls


def _render_inventory(inv, vendored, repo, target_rel, decl, eps, aux, fork):
    """The prompt-visible deployment inventory. GENERIC template text only (no domain nouns) — the SIGNATURES it
    renders are real source data, like symbol-inventory.txt. In fork mode only the entry-point half renders."""
    try:
        with open(os.path.join(repo, target_rel), encoding="utf-8", errors="ignore") as fh:
            target_text = fh.read()
    except OSError:
        target_text = ""
    lines = []
    lines.append("=== ENTRY POINTS (the coverage denominator: expose ONE bounded action per listed name) ===")
    lines.append("TARGET: %s (%s)" % (decl["name"], target_rel))
    for e in eps:
        gate = " [gated: %s]" % e["modifier"] if e["modifier"] != "-" else ""
        lines.append("  - %s  (%s)%s" % (e["signature"], e["kind"], gate))
    if fork:
        return _cap12kb("\n".join(lines) + "\n")

    lines.append("")
    lines.append("=== DEPLOYMENT INVENTORY ===")
    aux_names = set()
    for a in aux:
        ar = _resolve_target(inv, repo, a)
        if ar is not None:
            aux_names.add(ar[1]["name"])
    lines += _render_one(inv, repo, target_rel, decl, target_text, is_target=True, aux_names=aux_names)
    for hint, resolved in _collaborators(inv, repo, decl):
        if resolved is None:
            lines.append("")
            lines.append("COLLABORATOR '%s': unresolved — deploy a minimal mock implementing every function the "
                         "target calls on it, including calls made inside a base constructor." % hint)
            continue
        got = inv.get(resolved)
        if got is None:
            continue
        crel, cdecl = got
        lines.append("")
        lines.append("COLLABORATOR '%s' -> %s (%s)" % (hint, resolved, crel))
        deployed = "deployed REAL (required)" if resolved in aux_names else "prefer the real contract, else a minimal mock"
        lines.append("  %s" % deployed)
        lines += _render_one(inv, repo, crel, cdecl, target_text, is_target=False, aux_names=aux_names, id_hint=hint)
    return _cap12kb("\n".join(lines) + "\n")


def _render_one(inv, repo, rel, decl, target_text, is_target, aux_names, id_hint=None):
    lines = []
    lines.append("  %s" % _rel_import(rel))
    if decl["constructor"]:
        lines.append("  constructor: %s" % decl["constructor"]["raw"])
    for fn in decl["initializers"][:4]:
        lines.append("  initializer: %s" % fn["signature"])
    if not is_target:
        calls = _calls_on(target_text, id_hint) if id_hint else []
        if calls:
            lines.append("  calls the target makes on it: %s" % ", ".join(calls))
        else:
            lines.append("  used as an address only — an actor address you control is enough (indirect calls "
                         "through a storage struct may be missed).")
    shown = 0
    for fn in decl["functions"]:
        if fn["visibility"] in ("external", "public") and shown < 25:
            lines.append("    %s" % fn["signature"])
            shown += 1
    return lines


def _cap12kb(text):
    if len(text) <= 12000:
        return text
    return text[:12000] + "\n... [inventory truncated at 12 KB] ...\n"


# ================================================================================================
# #2245 (iteration 7) — DEEP-HUNT PROMISES. One ADDITIVE subcommand; everything above is byte-for-byte UNCHANGED.
#
#   promise-sources --repo <staged repo> --target <rel[:Name]> --out <file>
#       The line-numbered source listing the invariant prover reads to list the target's USER-FACING PROMISES
#       (run-invariant-hunt.sh --promises writes it to the fixed rundir file promise-sources.txt). Order:
#         1. the target's own file;
#         2. the files declaring its own-source ancestor CONTRACTS (abstract or not; libraries count here),
#            breadth-first, most-derived first;
#         3. the files declaring its own-source ancestor INTERFACES;
#         4. up to PROMISE_DOC_MAX in-repo *.md files that name the target contract as a whole word (ranked by
#            mention count, then path), each ONE window of <= PROMISE_DOC_WINDOW lines starting
#            PROMISE_DOC_LEAD lines above its first mention.
#       Every file is listed once. Rendering: a `=== <repo-relative path> ===` header, then `<n>| <text>` for
#       every NON-BLANK line, where <n> is the REAL file line — so `sed -n <n>p <repo>/<path>` returns <text>
#       and a citation re-opens exactly. Capped at PROMISE_SOURCES_CAP bytes, cut at a line boundary with the
#       PROMISE_TRUNC_MARK line and nothing after it; contracts come first, so interfaces and docs are the first
#       thing cut. An unresolvable target writes an EMPTY file (the prover's promisesOn is then false).
#       Vendored code (lib/ node_modules/ ...) is never listed: its ancestors end the chain, like the appendix.
PROMISE_SOURCES_CAP = 160 * 1024
PROMISE_TRUNC_MARK = "... [promise sources truncated at 160 KB] ..."
PROMISE_DOC_MAX = 2
PROMISE_DOC_WINDOW = 200
PROMISE_DOC_LEAD = 20
PROMISE_DOC_EXCLUDED_PREFIXES = ("test/", "tests/", "mocks/", "script/")


def _own_ancestor_files(inv, decl):
    """The files declaring the own-source ancestors of `decl`, breadth-first, most-derived first, split into
    (contract_files, interface_files). A base that is not own-source (vendored / ambiguous / unscanned) ends its
    branch. A file is recorded once, in the first bucket that reaches it (contracts win, see the caller)."""
    contracts = []
    interfaces = []
    seen = set([decl["name"]])
    frontier = list(decl["bases"])
    while frontier:
        nxt = []
        for b in frontier:
            if b in seen:
                continue
            seen.add(b)
            got = inv.get(b)
            if got is None:
                continue
            rel, d = got
            if d["kind"] == "interface":
                if rel not in interfaces:
                    interfaces.append(rel)
            elif rel not in contracts:
                contracts.append(rel)
            for bb in d["bases"]:
                if bb not in seen:
                    nxt.append(bb)
        frontier = nxt
    return contracts, interfaces


def _promise_doc_windows(repo, name):
    """Up to PROMISE_DOC_MAX (rel, first_line_1based, last_line_1based) doc windows for the in-repo *.md files
    that name `name` as a whole word, ranked by mention count (desc) then path."""
    word = re.compile(r"(^|[^A-Za-z0-9_$])" + re.escape(name) + r"([^A-Za-z0-9_$]|$)")
    ranked = []
    for root, dirs, files in os.walk(repo):
        dirs[:] = sorted(d for d in dirs if d not in PRUNE_DIRS)
        for f in files:
            if not f.lower().endswith(".md"):
                continue
            rel = os.path.relpath(os.path.join(root, f), repo).replace(os.sep, "/")
            if any(rel.startswith(p) or ("/" + p) in rel for p in PROMISE_DOC_EXCLUDED_PREFIXES):
                continue
            try:
                with open(os.path.join(repo, rel), encoding="utf-8", errors="ignore") as fh:
                    lines = fh.read().splitlines()
            except OSError:
                continue
            hits = [i for i, ln in enumerate(lines) if word.search(ln)]
            if not hits:
                continue
            count = sum(len(word.findall(lines[i])) for i in hits)
            start = max(0, hits[0] - PROMISE_DOC_LEAD)
            end = min(len(lines), start + PROMISE_DOC_WINDOW)
            ranked.append((-count, rel, start + 1, end))
    ranked.sort()
    return [(rel, a, b) for _c, rel, a, b in ranked[:PROMISE_DOC_MAX]]


def _render_listing(repo, rel, first=1, last=None):
    """`=== rel ===` + `<n>| <text>` for every non-blank line in [first, last] (1-based, inclusive)."""
    try:
        with open(os.path.join(repo, rel), encoding="utf-8", errors="ignore") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return []
    if lines and lines[-1] == "":
        lines.pop()
    if last is None or last > len(lines):
        last = len(lines)
    out = ["=== " + rel + " ==="]
    n = first
    while n <= last:
        text = lines[n - 1].rstrip("\r")
        if text.strip():
            out.append("%d| %s" % (n, text))
        n += 1
    return out


def cmd_promise_sources(argv):
    flags = parse_flags(argv, ("--repo", "--target", "--out"), ())
    repo = flags.get("--repo")
    target = flags.get("--target")
    out = flags.get("--out")
    if not repo or not target or not out:
        die(2, "promise-sources requires --repo --target --out")
    if not os.path.isdir(repo):
        die(3, "--repo is not a directory: " + repo)
    inv = OwnInventory(repo, discover_inventory_sources(repo))
    resolved = _resolve_target(inv, repo, target)
    if resolved is None:
        # Inert: no target -> empty file -> the prover's promisesOn is false -> the REACH-only prompt.
        with open(out, "w", encoding="utf-8") as fh:
            fh.write("")
        return 0
    rel, decl = resolved
    contracts, interfaces = _own_ancestor_files(inv, decl)
    listed = [rel]
    for f in contracts + interfaces:
        if f not in listed:
            listed.append(f)
    blocks = [_render_listing(repo, f) for f in listed]
    for drel, a, b in _promise_doc_windows(repo, decl["name"]):
        if drel not in listed:
            listed.append(drel)
            blocks.append(_render_listing(repo, drel, a, b))
    text_lines = []
    size = 0
    cut = False
    for block in blocks:
        for ln in block:
            add = len(ln.encode("utf-8")) + 1
            if size + add > PROMISE_SOURCES_CAP:
                cut = True
                break
            text_lines.append(ln)
            size += add
        if cut:
            break
    if cut:
        text_lines.append(PROMISE_TRUNC_MARK)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(text_lines) + ("\n" if text_lines else ""))
    return 0


COMMANDS = {
    "appendix": cmd_appendix,
    "implementor": cmd_implementor,
    "reach-targets": cmd_reach_targets,
    "reach-inventory": cmd_reach_inventory,
    "promise-sources": cmd_promise_sources,
}


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stdout.write("usage: inheritance.py <appendix|implementor|reach-targets|reach-inventory|promise-sources> [flags]\n")
        return 0 if len(argv) >= 2 else 2
    cmd = COMMANDS.get(argv[1])
    if cmd is None:
        die(2, "unknown subcommand: " + argv[1])
    return cmd(argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
