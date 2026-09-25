#!/usr/bin/env python3
# exam-helper.py — the python half of the #2262 held-out exam runner (exam.sh). exam.sh carries no heredoc
# python: every structured read or rewrite it needs is one subcommand here. python3 stdlib only, no argparse
# (the lib/ manual-flag idiom), no network, no LLM, never writes bytecode.
#
# Subcommands:
#   profile <file>                     parse + validate a knob profile; stdout = NUL-separated records
#                                      `<kind>\0<name>\0<value>\0` (kind R = runner key with its default
#                                      applied, E = env.<NAME>, D = deep.<NAME>, P = pass.<NAME> with an empty
#                                      value). Exit 2 on any grammar error (message on stderr).
#   profile-summary <file>             the same parse, human-readable `R|E|D|P NAME=VALUE` lines (self-test,
#                                      `exam.sh plan` validation).
#   knob-registry <profiles-dir> [<profile>...]
#                                      every knob NAME the runner clears before it applies a profile: the
#                                      env./deep./pass. names of every shipped `<dir>/*.env`, plus
#                                      `<dir>/KNOBS`, plus those of each extra profile given. One per line,
#                                      sorted. exam.sh `unset`s them all (except the running profile's own
#                                      pass.<NAME>s), so a knob exported in the operator's shell never leaks
#                                      into an arm that does not set it ("pass nothing when off").
#   zone-ids <zones.json>              the zone ids of a frozen map, one per line, in file order.
#   zone-filter <zones.json> <id>      rewrite <zones.json> in place to exactly the zone <id>; print its name.
#                                      Exit 3 unless exactly one zone carries that id.
#   inject-classes <scope.tsv> <zones.json> <C1,C2,...>
#                                      append each class, ONCE, to field 2 of every scope.tsv line whose field 1
#                                      is the name of a zone in <zones.json>; idempotent (membership-checked).
#                                      Exit 3 when a zone has no scope.tsv line. Prints the rewritten lines.
#   contam-scan <checkout>             the #2231 prompt-visibility pre-flight over a tool checkout: every
#                                      prompt-visible file (fresh-set.py's prompt_visible(), itself mirrored
#                                      from the colony-lint guard) scanned for the literal `corpus-bench` and a
#                                      delimited `[HM]-<1-2 digits>` id. Prints `<rel>:<line>:<rule>`; exit 1
#                                      when anything hit, 0 when clean.
#   zone-roots <zones.json>            the distinct `root` keys of a (#2255 multi-root) map, comma-joined, or
#                                      `-` for a single-root map.
#
# Exit: 0 ok ; 1 contam-scan found a violation ; 2 usage / profile grammar error ; 3 unreadable or
#       wrong-shape input.
import importlib.util
import json
import os
import re
import sys
import tempfile

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))

# Runner keys: the fixed set a profile may set with a bare KEY=VALUE. Every other bare key is exit 2.
# M3 of #2262 adds REHUNT_TRANSPORT / ATTRIB_FAMILY here.
RUNNER_DEFAULTS = (
    ("BACKEND", "flat-cyborg"),
    ("MODEL", ""),
    ("JOBS", "1"),
    ("DEEP_JOBS", ""),          # empty = JOBS
    ("HARD_STOP_S", "14400"),
    ("DEEP_PASS", "0"),
    ("INJECT_CLASSES", ""),
    ("SCOPE_DOCS", ""),         # empty = off ; `auto` ; `code:<path relative to the contest's code/ dir>`
)
RUNNER_KEYS = tuple(k for k, _ in RUNNER_DEFAULTS)
NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
BAD_VALUE_CHARS = ("$", "`", "'", '"', "\\")
GT_ID_RE = re.compile(r"(^|[^A-Za-z0-9_])[HM]-[0-9]{1,2}([^A-Za-z0-9_]|$)")


def die(rc, msg):
    sys.stderr.write("exam-helper.py: " + msg + "\n")
    sys.exit(rc)


def write_atomic(path, text):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


# ----------------------------------------------------------------------------------------------------------
# profile grammar
# ----------------------------------------------------------------------------------------------------------
def _check_runner(key, val, where):
    def bad(why):
        die(2, "%s: %s=%r %s" % (where, key, val, why))
    if key == "BACKEND":
        if val not in ("mock", "flat-cyborg", "claude"):
            bad("must be mock, flat-cyborg or claude")
    elif key == "MODEL":
        if val and not re.match(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$", val):
            bad("is not a model id")
    elif key in ("JOBS", "DEEP_JOBS"):
        if not (key == "DEEP_JOBS" and val == "") and not re.match(r"^[1-9][0-9]*$", val):
            bad("must be a positive integer")
    elif key == "HARD_STOP_S":
        if not re.match(r"^[1-9][0-9]*$", val):
            bad("must be a positive integer (seconds)")
    elif key == "DEEP_PASS":
        if val not in ("0", "1"):
            bad("must be 0 or 1")
    elif key == "INJECT_CLASSES":
        if val and not re.match(r"^C[0-9]+(,C[0-9]+)*$", val):
            bad("must be a comma list of class tokens (C<n>)")
    elif key == "SCOPE_DOCS":
        if val and val != "auto":
            if not val.startswith("code:"):
                bad("must be empty, `auto` or `code:<relative path>`")
            rel = val[len("code:"):]
            parts = rel.split("/")
            if not rel or rel.startswith("/") or ".." in parts or "" in parts:
                bad("needs a relative path without `..` under the contest's code/ dir")


def parse_profile(path):
    """-> (runner dict with defaults, [(kind, name, value)] for E/D/P in file order)."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        die(3, "cannot read profile %s: %s" % (path, exc))
    where = os.path.basename(path)
    runner = {}
    knobs = []
    seen = set()
    for n, raw in enumerate(text.split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        loc = "%s:%d" % (where, n)
        if line.startswith("pass."):
            name = line[len("pass."):]
            if "=" in name:
                die(2, "%s: pass.<NAME> takes no value (it is inherited from the caller's environment)" % loc)
            if not NAME_RE.match(name):
                die(2, "%s: bad knob name %r" % (loc, name))
            ident = ("P", name)
            if ident in seen:
                die(2, "%s: duplicate pass.%s" % (loc, name))
            seen.add(ident)
            knobs.append(("P", name, ""))
            continue
        if "=" not in line:
            die(2, "%s: expected KEY=VALUE, env.<NAME>=<v>, deep.<NAME>=<v> or pass.<NAME>" % loc)
        key, val = line.split("=", 1)
        key, val = key.strip(), val.strip()
        for ch in BAD_VALUE_CHARS:
            if ch in val:
                die(2, "%s: value of %s carries a forbidden character %r (no $, backticks, quotes or "
                       "backslashes)" % (loc, key, ch))
        if key.startswith("env.") or key.startswith("deep."):
            kind = "E" if key.startswith("env.") else "D"
            name = key.split(".", 1)[1]
            if not NAME_RE.match(name):
                die(2, "%s: bad knob name %r" % (loc, name))
            if val == "":
                die(2, "%s: %s has an empty value (an empty knob is still SET for getenv(); omit the line "
                       "instead)" % (loc, key))
            ident = (kind, name)
            if ident in seen:
                die(2, "%s: duplicate %s" % (loc, key))
            seen.add(ident)
            knobs.append((kind, name, val))
            continue
        if key not in RUNNER_KEYS:
            die(2, "%s: unknown runner key %r (known: %s; knobs are env.<NAME> / deep.<NAME> / pass.<NAME>)"
                % (loc, key, " ".join(RUNNER_KEYS)))
        if key in runner:
            die(2, "%s: duplicate runner key %s" % (loc, key))
        _check_runner(key, val, loc)
        runner[key] = val
    full = {}
    for k, default in RUNNER_DEFAULTS:
        full[k] = runner.get(k, default)
    if full["BACKEND"] != "mock" and not full["MODEL"]:
        die(2, "%s: MODEL is required for a live backend (the pinned model is part of the ruler)" % where)
    pass_names = set(n for k, n, _ in knobs if k == "P")
    for k, n, _ in knobs:
        if k in ("E", "D") and n in pass_names:
            die(2, "%s: %s is both set (env./deep.) and inherited (pass.)" % (where, n))
    return full, knobs


def cmd_profile(argv):
    if len(argv) != 1:
        die(2, "usage: profile <file>")
    runner, knobs = parse_profile(argv[0])
    out = []
    for k in RUNNER_KEYS:
        out.extend(("R", k, runner[k]))
    for kind, name, val in knobs:
        out.extend((kind, name, val))
    sys.stdout.write("".join(x + "\0" for x in out))
    return 0


def cmd_profile_summary(argv):
    if len(argv) != 1:
        die(2, "usage: profile-summary <file>")
    runner, knobs = parse_profile(argv[0])
    for k in RUNNER_KEYS:
        sys.stdout.write("R %s=%s\n" % (k, runner[k]))
    for kind, name, val in knobs:
        sys.stdout.write("%s %s=%s\n" % (kind, name, val))
    return 0


def cmd_knob_registry(argv):
    if not argv:
        die(2, "usage: knob-registry <profiles-dir> [<profile>...]")
    pdir, extra = argv[0], argv[1:]
    if not os.path.isdir(pdir):
        die(3, "profiles dir not found: " + pdir)
    names = set()
    files = sorted(os.path.join(pdir, f) for f in os.listdir(pdir) if f.endswith(".env"))
    for path in files + list(extra):
        _, knobs = parse_profile(path)
        names.update(n for _, n, _ in knobs)
    kpath = os.path.join(pdir, "KNOBS")
    if os.path.isfile(kpath):
        with open(kpath, encoding="utf-8") as fh:
            for n, raw in enumerate(fh, 1):
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                for tok in line.split():
                    if not NAME_RE.match(tok):
                        die(2, "KNOBS:%d: bad knob name %r" % (n, tok))
                    names.add(tok)
    for n in sorted(names):
        sys.stdout.write(n + "\n")
    return 0


# ----------------------------------------------------------------------------------------------------------
# map helpers
# ----------------------------------------------------------------------------------------------------------
def load_zones(path):
    try:
        with open(path, encoding="utf-8") as fh:
            zones = json.load(fh)
    except (OSError, ValueError) as exc:
        die(3, "cannot read zones.json %s: %s" % (path, exc))
    if not isinstance(zones, list):
        die(3, "zones.json is not a JSON list: " + path)
    return [z for z in zones if isinstance(z, dict)]


def cmd_zone_ids(argv):
    if len(argv) != 1:
        die(2, "usage: zone-ids <zones.json>")
    for z in load_zones(argv[0]):
        if z.get("id"):
            sys.stdout.write(str(z["id"]) + "\n")
    return 0


def cmd_zone_roots(argv):
    if len(argv) != 1:
        die(2, "usage: zone-roots <zones.json>")
    roots = sorted(set(str(z["root"]) for z in load_zones(argv[0]) if z.get("root")))
    sys.stdout.write((",".join(roots) if roots else "-") + "\n")
    return 0


def cmd_zone_filter(argv):
    if len(argv) != 2:
        die(2, "usage: zone-filter <zones.json> <zone_id>")
    path, zid = argv
    zones = load_zones(path)
    matched = [z for z in zones if z.get("id") == zid]
    if len(matched) != 1:
        die(3, "expected exactly 1 zone with id=%r in %s, found %d" % (zid, path, len(matched)))
    name = matched[0].get("name", "")
    if not name:
        die(3, "zone %r has no name" % zid)
    write_atomic(path, json.dumps(matched, indent=2) + "\n")
    sys.stdout.write(name + "\n")
    return 0


def cmd_inject_classes(argv):
    if len(argv) != 3:
        die(2, "usage: inject-classes <scope.tsv> <zones.json> <C1,C2,...>")
    scope, zpath, csv = argv
    if not re.match(r"^C[0-9]+(,C[0-9]+)*$", csv):
        die(2, "bad class list: %r" % csv)
    add = [c for c in csv.split(",") if c]
    names = [z.get("name", "") for z in load_zones(zpath) if z.get("name")]
    try:
        with open(scope, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError as exc:
        die(3, "cannot read scope.tsv %s: %s" % (scope, exc))
    hits = dict((n, 0) for n in names)
    out, changed = [], []
    for line in lines:
        if line.startswith("#") or " | " not in line:
            out.append(line)
            continue
        fields = line.split(" | ")
        if fields[0] in hits:
            hits[fields[0]] += 1
            classes = [c for c in fields[1].split(",") if c]
            for c in add:
                if c not in classes:
                    classes.append(c)
            fields[1] = ",".join(classes)
            line = " | ".join(fields)
            changed.append(line)
        out.append(line)
    missing = [n for n, c in hits.items() if c == 0]
    if missing:
        die(3, "no scope.tsv line for zone name(s): " + ", ".join(sorted(missing)))
    new = "\n".join(out)
    with open(scope, encoding="utf-8") as fh:
        if fh.read() != new:
            write_atomic(scope, new)
    for line in changed:
        sys.stdout.write(line + "\n")
    return 0


# ----------------------------------------------------------------------------------------------------------
# #2231 pre-flight
# ----------------------------------------------------------------------------------------------------------
def _prompt_visible():
    path = os.path.join(os.path.dirname(HERE), "fresh-set.py")
    spec = importlib.util.spec_from_file_location("_exam_fresh_set", path)
    if spec is None or spec.loader is None:
        die(3, "cannot import fresh-set.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.prompt_visible


def cmd_contam_scan(argv):
    if len(argv) != 1:
        die(2, "usage: contam-scan <checkout>")
    root = argv[0]
    if not os.path.isdir(os.path.join(root, "dark-factory")):
        die(3, "not a tool checkout (no dark-factory/): " + root)
    prompt_visible = _prompt_visible()
    hits = []
    seen_real = set()
    # followlinks: a checkout may carry dark-factory/ as a symlink (the self-test does); the realpath set keeps a
    # link cycle from looping.
    for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
        real = os.path.realpath(dirpath)
        if real in seen_real:
            dirnames[:] = []
            continue
        seen_real.add(real)
        dirnames[:] = sorted(d for d in dirnames if d != ".git")
        for f in sorted(filenames):
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            if not prompt_visible(rel):
                continue
            try:
                with open(full, encoding="utf-8", errors="replace") as fh:
                    for n, line in enumerate(fh, 1):
                        if "corpus-bench" in line:
                            hits.append("%s:%d:corpus-bench" % (rel, n))
                        if GT_ID_RE.search(line):
                            hits.append("%s:%d:gt-id" % (rel, n))
            except OSError:
                continue
    for h in hits:
        sys.stdout.write(h + "\n")
    return 1 if hits else 0


COMMANDS = {
    "profile": cmd_profile,
    "profile-summary": cmd_profile_summary,
    "knob-registry": cmd_knob_registry,
    "zone-ids": cmd_zone_ids,
    "zone-roots": cmd_zone_roots,
    "zone-filter": cmd_zone_filter,
    "inject-classes": cmd_inject_classes,
    "contam-scan": cmd_contam_scan,
}


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stdout.write("usage: exam-helper.py <%s> ...\n" % "|".join(sorted(COMMANDS)))
        return 0 if len(argv) >= 2 else 2
    cmd = COMMANDS.get(argv[1])
    if cmd is None:
        die(2, "unknown subcommand: " + argv[1])
    return cmd(argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
