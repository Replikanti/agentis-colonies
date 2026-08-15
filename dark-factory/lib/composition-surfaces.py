#!/usr/bin/env python3
# composition-surfaces.py — #1914 M2 (epic #1914). THE SINGLE SOURCE OF TRUTH for "which contract in a zone
# CONSUMES value that another contract in the same zone PRODUCES", so the #1914 general-solvency (SYS-solvency)
# deep-hunt lens targets the real value-*consuming* contract A and threads the value-*producing* contract(s) B
# as --aux (the composable-fresh multi-contract engine), instead of M1's largest/next-largest BOOTSTRAP.
#
# WHY IT EXISTS. M1 emitted a SYS-solvency row per value_custody zone by picking the largest .sol as the target
# and the next-largest as the co-system aux — a size bootstrap that is right only by luck. The bug a
# composability lens is meant to find lives on the SEAM: contract A reads a value B computed by a DIFFERENT
# contract B and settles against it (a share/price it mints or transfers on), so an adversary who controls B's
# return can drain A. The target of that lens must be the CONSUMER, and B must be the aux the fresh-deploy
# harness wires as the (possibly adversarial) counterparty. This helper finds that seam by a static source scan.
#
# WHAT IT DOES. Over map-zones.sh's already-filtered, already-grouped MECHANICAL zone model, for EACH zone it
# scans the zone's own Solidity sources for a composition seam between TWO DISTINCT zone files (a cross-FILE
# seam — a self-contained single file is deployed and fuzzed whole, so it needs no aux). When it finds one it
# attaches ONE additive key, `composition_surfaces`, a list of
#   {"consumer": <rel>, "producers": [<rel>...], "adversarial_actor": <role|null>, "seam_class": <str>}
# and prints the same JSON on stdout. A zone with NO detected seam gains NO key -> byte-identical (option C),
# exactly like inheritance.py's abstract_base record. `files`, `loc`, `hardening_score`, `scope_files` and zone
# identity are NEVER touched, so scope.tsv and the #1830 coverage record are unaffected either way.
#
# HEURISTIC SEAM CLASSES (any one triggers, all require the producer to be a CONCRETE contract in a DIFFERENT
# zone file than the consumer):
#   return-sink        A assigns the return of an external call `b.foo()` and the same contract settles
#                      (transfer / mint / burn / balance-write) — the classic "price/shares from B, pay out on it".
#   hook-delta         A defines a `beforeSwap`/`afterSwap`-style hook that RETURNS a value and settles it while
#                      calling the producer — the return-delta-application shape.
#   adapter-roundtrip  A is a wrapper/adapter defining BOTH a deposit-side (`deposit`/`mint`) and a withdraw-side
#                      (`withdraw`/`redeem`) entrypoint against the external producer position.
#
# COARSE PRE-FILTER. The precise return-value-sink scan runs only on a zone whose sources carry the same
# adapter/wrapper/oracle naming + import prior that zone-mapper.ag uses for its C10/C11 lending backstop and its
# C6 accounting net (ERC4626 wrapper imports, `IStrategy`/`IVault`/`IPool*` types, oracle/router/pool/adapter
# names). A zone with none of those signals cannot host the seam this lens targets and is skipped cheaply.
#
# ADVERSARIAL ACTOR. When the producer dependency is reached through an INTERFACE type (a swappable/pluggable
# integration point — the concrete implementation is not fixed by the consumer), the trust model permits a
# permissionless INTEGRATOR to supply a malicious implementation, so `adversarial_actor` is `"integrator"` and
# the composable-fresh seed (which #1918 mandates carry a non-trivial adversary once --aux is present) models
# that. A dependency wired to a concrete contract type is fixed, so `adversarial_actor` is null.
#
# WHAT IT IS NOT. Not a Solidity front-end — no solc, no AST, regex + logical-declaration accumulation only, and
# every named failure mode is made INERT (the seam is dropped -> no key -> M1's bootstrap selection exactly),
# never wrong: a type that resolves to no concrete zone file, a library/interface producer, a same-file
# dependency, an ambiguous contract name — all simply fail to attach.
#
# Subcommands:
#   annotate --zones <mechanical.json> --repo <dir>
#       Prints the mechanical zone model on stdout with `composition_surfaces` attached to every zone that has a
#       detected seam. Absent/failing => the caller (map-zones.sh) keeps the untouched model (today's behaviour).
#
# Exit: 0 on success (including "nothing detected"); 2 usage error; 3 unreadable input.
import json
import os
import re
import sys

# Mirror of map-zones.sh's `find` prune list (vendored deps + build output are never the target's own code).
PRUNE_DIRS = ("lib", "node_modules", "out", "cache", "artifacts", ".git")
# Mirror of map-zones.sh's #1824 EXCLUDED_ZONE_PREFIXES, segment-anchored exactly the same way.
EXCLUDED_ZONE_PREFIXES = ("test/", "tests/", "interfaces/", "mocks/", "script/")

# A logical declaration is accumulated over at most this many PHYSICAL lines (a multi-line `is` list, a
# multi-line function signature). Same bound as inheritance.py's MAX_DECL_LINES.
MAX_DECL_LINES = 12

_CONTRACT_RE = re.compile(r"^\s*(?:(abstract)\s+)?(contract|interface|library)\s+([A-Za-z0-9_$]+)\b")
# A typed identifier declaration: `<Type> [visibility/mutability]* <name>` ending a declaration/parameter. The
# type must start upper-case (a contract/interface/struct name; `uint256`/`address`/`bool` are lower-case and
# never match), the name lower-case (the Solidity convention for variables and parameters).
_TYPED_ID_RE = re.compile(
    r"\b([A-Z][A-Za-z0-9_$]*)\s+(?:public\s+|private\s+|internal\s+|immutable\s+|constant\s+)*"
    r"([a-z_$][A-Za-z0-9_$]*)\s*[;=,)]"
)
_FUNCTION_RE = re.compile(r"^\s*function\s+([A-Za-z0-9_$]+)\s*\(")
# A settlement sink: an external value move OR a balance/accounting slot write.
_SINK_RE = re.compile(
    r"\.\s*(?:safeTransferFrom|safeTransfer|transferFrom|transfer|_mint|_burn|mint|burn)\s*\("
    r"|[A-Za-z_$][A-Za-z0-9_$]*\s*\[[^\]]*\]\s*(?:\+=|-=|=[^=])"
    r"|\b(?:totalSupply|totalShares|totalAssets|totalDebt|totalCollateral)\s*(?:\+=|-=)"
)
# The coarse pre-filter: the adapter/wrapper/oracle naming + import prior zone-mapper.ag keys its C10/C11 and
# C6 nets on (import/type-line signals, not just contract names). Case-insensitive.
_PRIOR_RE = re.compile(
    r"IStrategy|IVault|IERC4626|ERC4626|IPool[A-Za-z]*|ITroveManager|IStabilityPool|IComptroller|ICToken"
    r"|IAaveLendingPool|IPoolAddressesProvider|IRouter|IOracle|beforeSwap|afterSwap"
    r"|oracle|router|adapter|wrapper|strateg|vault|pool",
    re.IGNORECASE,
)
# Hook-return-delta entrypoints (Uniswap v4-style `beforeSwap`/`afterSwap` and the general before/after hook).
_HOOK_RE = re.compile(r"^\s*function\s+(?:before|after)[A-Z][A-Za-z0-9_$]*\s*\(")
_DEPOSIT_RE = re.compile(r"^\s*function\s+(?:deposit|mint)\b")
_WITHDRAW_RE = re.compile(r"^\s*function\s+(?:withdraw|redeem)\b")


def die(rc, msg):
    sys.stderr.write("composition-surfaces.py: " + msg + "\n")
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


def _logical_decl(lines, i):
    """Accumulate the LOGICAL declaration that starts at physical line `i`: join lines up to and including the
    first `{` or `;`, bounded to MAX_DECL_LINES. Mirrors inheritance.py._logical_decl."""
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
    parenthesised constructor args stripped. Same rule as inheritance.py._bases_of."""
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

    Returns a list of dicts {kind, abstract, name, bases}. Kept deliberately shallow: seam detection is at FILE
    granularity (a consumer file reaching a producer file), so per-contract body attribution — which the
    one-contract-per-file corpus shape makes fragile anyway — is not needed here."""
    lines = text.splitlines()
    contracts = []
    i = 0
    while i < len(lines):
        cm = _CONTRACT_RE.match(lines[i])
        if cm:
            decl, _term, last = _logical_decl(lines, i)
            contracts.append({
                "kind": cm.group(2),
                "abstract": cm.group(1) is not None,
                "name": cm.group(3),
                "bases": _bases_of(decl),
            })
            i = last + 1
            continue
        i += 1
    return contracts


class ZoneScan(object):
    """A source cache + declaration index over ONE zone's own Solidity files."""

    def __init__(self, repo, rel_files):
        self.repo = repo
        self.files = []                 # zone-relative .sol files, in the zone's own order
        self.text = {}                  # rel -> source text
        self.decls = {}                 # rel -> [declarations]
        self.concrete_in = {}           # contract name -> set(files declaring it as a concrete contract)
        self.interface_names = set()    # every `interface` name declared in the zone
        self.impl_files_of = {}         # base name -> set(files declaring a concrete contract that `is <base>`)
        for rel in rel_files:
            if not (isinstance(rel, str) and rel.endswith(".sol")):
                continue
            if is_excluded_zone_path(rel):
                continue
            try:
                with open(os.path.join(repo, rel), encoding="utf-8", errors="ignore") as fh:
                    text = fh.read()
            except OSError:
                continue
            self.files.append(rel)
            self.text[rel] = text
            decls = parse_source(text)
            self.decls[rel] = decls
            for d in decls:
                if d["kind"] == "interface":
                    self.interface_names.add(d["name"])
                if d["kind"] == "contract" and not d["abstract"]:
                    self.concrete_in.setdefault(d["name"], set()).add(rel)
                    for base in d["bases"]:
                        self.impl_files_of.setdefault(base, set()).add(rel)

    def has_prior(self):
        return any(_PRIOR_RE.search(self.text[f]) for f in self.files)

    def producer_files(self, type_name, consumer_rel):
        """The DIFFERENT zone files that host a concrete producer for a variable of type `type_name`, plus
        whether the resolution went through an interface. A same-file or unresolved type yields no producer."""
        via_interface = False
        producers = set()
        # Direct: the type is itself a concrete contract declared in another zone file.
        for f in self.concrete_in.get(type_name, ()):
            if f != consumer_rel:
                producers.add(f)
        # Interface: the type is an interface (or any base) implemented by a concrete contract in another file.
        if type_name in self.interface_names or type_name.startswith("I"):
            for f in self.impl_files_of.get(type_name, ()):
                if f != consumer_rel:
                    producers.add(f)
                    via_interface = True
        return producers, via_interface

    def seam_for(self, consumer_rel):
        """The composition seam this consumer file hosts, or None. `producers` are always DISTINCT zone files."""
        text = self.text[consumer_rel]
        # name -> declared Type, restricted to types that could name a producer (upper-case, contract-ish).
        typed = {}
        for m in _TYPED_ID_RE.finditer(text):
            typed.setdefault(m.group(2), m.group(1))
        # external calls `<name>.<method>(` whose receiver is a typed identifier resolving to a producer file.
        producers = set()
        via_interface = False
        called_vars = set()
        for m in re.finditer(r"\b([A-Za-z_$][A-Za-z0-9_$]*)\s*\.\s*[A-Za-z0-9_$]+\s*\(", text):
            var = m.group(1)
            t = typed.get(var)
            if not t:
                continue
            pfiles, vi = self.producer_files(t, consumer_rel)
            if pfiles:
                producers |= pfiles
                via_interface = via_interface or vi
                called_vars.add(var)
        if not producers:
            return None
        # Seam class: at least one of the three shapes must hold, all requiring a settlement sink (the value
        # the consumer moves ON the producer's return — the object of a composability drain).
        has_sink = bool(_SINK_RE.search(text))
        lines = text.splitlines()
        seam_class = None
        if has_sink:
            # return-sink: the return of a producer call is CAPTURED (assigned / declared) in the consumer.
            for var in called_vars:
                cap = re.compile(r"=\s*" + re.escape(var) + r"\s*\.\s*[A-Za-z0-9_$]+\s*\(")
                if cap.search(text):
                    seam_class = "return-sink"
                    break
            if seam_class is None and any(_HOOK_RE.match(l) for l in lines):
                seam_class = "hook-delta"
            if seam_class is None and any(_DEPOSIT_RE.match(l) for l in lines) \
                    and any(_WITHDRAW_RE.match(l) for l in lines):
                seam_class = "adapter-roundtrip"
        if seam_class is None:
            return None
        return {
            "consumer": consumer_rel,
            "producers": sorted(producers),
            "adversarial_actor": "integrator" if via_interface else None,
            "seam_class": seam_class,
        }

    def seams(self):
        """Every seam in the zone, keyed by consumer file for determinism."""
        out = []
        for rel in self.files:
            s = self.seam_for(rel)
            if s is not None:
                out.append(s)
        # Deterministic order: most producers first, then consumer path, then the joined producer list — so a
        # downstream that picks ONE seam per zone (run-zone-hunt.sh) always picks the same one.
        out.sort(key=lambda s: (-len(s["producers"]), s["consumer"], ",".join(s["producers"])))
        return out


def read_json(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as e:
        die(3, "cannot read " + what + ": " + str(e))


def cmd_annotate(argv):
    flags = parse_flags(argv, ("--zones", "--repo"), ())
    zones_path = flags.get("--zones")
    repo = flags.get("--repo")
    if not zones_path or not repo:
        die(2, "annotate requires --zones <mechanical.json> --repo <dir>")
    if not os.path.isdir(repo):
        die(3, "--repo is not a directory: " + repo)
    zones = read_json(zones_path, "the mechanical zone model")
    if not isinstance(zones, list):
        die(3, "the mechanical zone model is not a JSON array")

    attached = []
    for z in zones:
        zone_files = z.get("files", [])
        scan = ZoneScan(repo, zone_files)
        # Coarse pre-filter: only the precise scan on a zone carrying the composition naming/import prior, and
        # only a zone with at least two Solidity files (a cross-file seam is impossible with one).
        if len(scan.files) < 2 or not scan.has_prior():
            continue
        seams = scan.seams()
        if not seams:
            continue
        z["composition_surfaces"] = seams
        attached.append(z.get("id"))

    sys.stdout.write(json.dumps(zones))
    if attached:
        sys.stderr.write(
            "composition-surfaces.py: composition seam attached to %d zone(s) [%s]\n"
            % (len(attached), ", ".join(str(a) for a in attached))
        )
    return 0


COMMANDS = {
    "annotate": cmd_annotate,
}


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stdout.write("usage: composition-surfaces.py <annotate> [flags]\n")
        return 0 if len(argv) >= 2 else 2
    cmd = COMMANDS.get(argv[1])
    if cmd is None:
        die(2, "unknown subcommand: " + argv[1])
    return cmd(argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
