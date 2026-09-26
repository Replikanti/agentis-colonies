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
#   env-reads <dark-factory-dir>       every env NAME the pipeline under <dark-factory-dir> reads: `${NAME:-}`
#                                      style shell expansions, python os.environ / os.getenv, `.ag` getenv()
#                                      (fixtures, demos and this runner excluded). A superset — shell locals
#                                      with a default expansion are in it too, which is harmless to clear.
#   clear-list <dark-factory-dir> <profiles-dir> [<profile>]
#                                      the names the runner CLEARS (`env -u`) from every pipeline call it
#                                      starts: env-reads(<dark-factory-dir>) + every env./deep./pass. name of
#                                      the shipped profiles + the NAME lines of `<profiles-dir>/KNOBS` + every
#                                      variable of THIS process's environment matching a `PREFIX*` line of
#                                      KNOBS; minus the `!NAME` lines of KNOBS (host plumbing / auth), the three
#                                      Claude Code killswitches, and the running profile's own pass.<NAME>s.
#                                      So a knob exported in the operator's shell never reaches an arm that
#                                      does not set it, whether or not anyone remembered to list it.
#   effective-env <clear-list-file> <mask-name>...
#                                      reads `env -0` output on stdin; prints `NAME=VALUE` (sorted) for every
#                                      variable that is a knob candidate (on the clear list, a KNOBS name or
#                                      prefix match, a killswitch) — i.e. exactly the knob state a call ran
#                                      with. A <mask-name> (a pass.<NAME>) is printed as `NAME=<inherited>`.
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
#   project-slug <abs-path>            Claude Code's per-cwd transcript store dir name for <abs-path> (M3; the
#                                      same encoding lib/claude-sandboxed.sh binds).
#   attrib --root <dir> --transcripts-root <dir> --model <id> [--family <fam>] --tsv <out>
#          (--stage <name>=<since>,<until>)... [--other <since>,<until>] [--exclude <name>]...
#                                      M3 run-window model attribution. Enumerates the RUN dirs actually on disk
#                                      under <dir> (every dir named `run` + its `cell-*` children, grouped by the
#                                      top-level dir = the stage), maps each to its transcript store dir by exact
#                                      name, keeps a transcript only when its records' `cwd` confirms it (or it
#                                      carries none), and runs model-attribution.py --json --stage --since --until
#                                      per stage (--split-synthetic). A `--stage` is REQUIRED: RUN dirs with no
#                                      in-window transcript = attribution-missing. A refusal in the window = gate
#                                      `refusal`; a <synthetic> usage-limit record = gate `usage-limit`; a
#                                      <synthetic> API-error record alone is counted (transient_synthetic) and
#                                      never fails the gate. `--other` covers every other top-level dir (a stage
#                                      that made no model call there is not-run); `--exclude` skips one. Gate per
#                                      stage: PURE-<family of --model, or --family> -> ok. `--model -` (the mock
#                                      backend) writes one skipped-mock row. Writes <out> (TSV); exit 0.
#   rehunt-check <zone-hunt-out> <void-patterns.tsv>
#                                      M3 one-shot re-hunt trigger: exit 0 (and a reason line) when a final-attempt
#                                      discovery cell carries .timeout / .novalid or a `transport` pattern match;
#                                      exit 4 when a `weekly-limit` pattern matched anywhere (a re-hunt would void
#                                      too); exit 1 when nothing needs a re-hunt. Also triggered by a failed
#                                      promise-lister call and a zone-incomplete zone (the coverage record's
#                                      `failed` / `in_flight`, ...). An .untraced cell is a METRIC.
#   void-check <arm-dir> <void-patterns.tsv>
#                                      M3 arm verdict: writes <arm-dir>/void.txt = `VALID` or
#                                      `VOID<TAB><class><TAB><evidence ref>` and prints it. First match wins:
#                                      hard-stop (rc / rehunt_rc / deep_rc 124), killed (a call or run itself
#                                      signalled), the pattern rows in file order, all-cells-failed (a staged
#                                      zone whose final cells ALL failed), transport (a final cell still failed
#                                      after the re-hunt), promise-lister (a failed run/promises/*.lister call),
#                                      zone-incomplete (the coverage record says a staged zone's run-discovery.sh
#                                      died / never finished — `failed`, `in_flight`, ... —, fewer cells than
#                                      planned, or an empty final cell log with no marker), deep-incomplete (a
#                                      STAGE 4.5 engine that died mid-way: the `run-invariant-hunt.sh failed`
#                                      line, or ENGINE_FAILED in deep-hunt/cell-status.tsv), no-cells (a staged
#                                      zone with no cell log at all), weekly-limit from attrib.tsv (a <synthetic>
#                                      usage-limit record), attribution (MIXED / CONTAMINATED / wrong family /
#                                      refusal / missing), operator (void.operator, `exam.sh void-mark`).
#                                      Also writes <arm-dir>/void.zones: EVERY zone-scoped defect
#                                      (`zone<TAB>class<TAB>ref`), so a whole-contest arm's triage can mark
#                                      exactly those zones unmeasured.
#
# Exit: 0 ok ; 1 contam-scan found a violation ; 2 usage / profile grammar error ; 3 unreadable or
#       wrong-shape input.
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))

# Runner keys: the fixed set a profile may set with a bare KEY=VALUE. Every other bare key is exit 2.
RUNNER_DEFAULTS = (
    ("BACKEND", "flat-cyborg"),
    ("MODEL", ""),
    ("JOBS", "1"),
    ("DEEP_JOBS", ""),          # empty = JOBS
    ("HARD_STOP_S", "14400"),
    ("DEEP_PASS", "0"),
    ("INJECT_CLASSES", ""),
    ("SCOPE_DOCS", ""),         # empty = off ; `auto` ; `code:<path relative to the contest's code/ dir>`
    ("REHUNT_TRANSPORT", "1"),  # M3: 1 = one in-arm re-hunt pass over failed / transport-failed cells ; 0 = off
    ("ATTRIB_FAMILY", ""),      # M3: the family the attribution gate wants; empty = the family of MODEL
)
FAMILIES = ("opus", "fable", "sonnet", "haiku")
RUNNER_KEYS = tuple(k for k, _ in RUNNER_DEFAULTS)
NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
BAD_VALUE_CHARS = ("$", "`", "'", '"', "\\")
NEVER_KNOBS = ("DF_NO_SANDBOX",)
SECRET_RE = re.compile(r"TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL")
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
        # `claude` is refused: that backend runs `claude -p` UNSANDBOXED (no llm.flat_cyborg.target), with the
        # whole host readable — ground truth included.
        if val not in ("mock", "flat-cyborg"):
            bad("must be flat-cyborg (the sandboxed live backend) or mock")
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
    elif key == "REHUNT_TRANSPORT":
        if val not in ("0", "1"):
            bad("must be 0 or 1")
    elif key == "ATTRIB_FAMILY":
        if val and val not in FAMILIES:
            bad("must be empty or one of " + "/".join(FAMILIES))
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
    for _, n, _ in knobs:
        if n in NEVER_KNOBS:
            die(2, "%s: %s is never allowed in a held-out run (it disables the hunt sandbox)" % (where, n))
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


KILLSWITCHES = ("CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK", "CLAUDE_CODE_NO_MODEL_FALLBACK",
                "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE")
READ_RES = (
    re.compile(r"\$\{([A-Z][A-Z0-9_]*):?[-=+?]"),
    re.compile(r"os\.environ(?:\.get)?\s*[\(\[]\s*['\"]([A-Z][A-Z0-9_]*)['\"]"),
    re.compile(r"os\.getenv\(\s*['\"]([A-Z][A-Z0-9_]*)['\"]"),
    re.compile(r"getenv\(\"([A-Z][A-Z0-9_]*)\"\)"),
)


def env_reads(df):
    if not os.path.isdir(df):
        die(3, "not a dark-factory dir: " + df)
    names = set()
    for dirpath, dirnames, filenames in os.walk(df):
        rel = os.path.relpath(dirpath, df).replace(os.sep, "/")
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d not in ("fixtures", "node_modules")
                             and not (rel == "bench/corpus-bench" and d == "exam"))
        for f in sorted(filenames):
            if not f.endswith((".sh", ".py", ".ag")) or f.startswith(("demo-", "test-")):
                continue
            try:
                with open(os.path.join(dirpath, f), encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                continue
            for rx in READ_RES:
                names.update(rx.findall(text))
    return names


def read_knobs(pdir):
    """-> (names, prefixes, allow) from <pdir>/KNOBS."""
    names, prefixes, allow = set(), set(), set()
    kpath = os.path.join(pdir, "KNOBS")
    if not os.path.isfile(kpath):
        die(3, "knob registry not found: " + kpath)
    with open(kpath, encoding="utf-8") as fh:
        for n, raw in enumerate(fh, 1):
            for tok in raw.split("#", 1)[0].split():
                if tok.startswith("!") and NAME_RE.match(tok[1:]):
                    allow.add(tok[1:])
                elif tok.endswith("*") and re.match(r"^[A-Z][A-Z0-9_]*$", tok[:-1]):
                    prefixes.add(tok[:-1])
                elif NAME_RE.match(tok):
                    names.add(tok)
                else:
                    die(2, "KNOBS:%d: bad entry %r (NAME, PREFIX* or !NAME)" % (n, tok))
    return names, prefixes, allow


def clear_list(df, pdir, profile):
    names, prefixes, allow = read_knobs(pdir)
    cand = set(names) | env_reads(df)
    for f in sorted(os.listdir(pdir)):
        if f.endswith(".env"):
            _, knobs = parse_profile(os.path.join(pdir, f))
            cand.update(n for _, n, _ in knobs)
    keep = set(allow) | set(KILLSWITCHES)
    if profile:
        _, knobs = parse_profile(profile)
        cand.update(n for k, n, _ in knobs if k != "P")
        keep.update(n for k, n, _ in knobs if k == "P")
    cand.update(n for n in os.environ if any(n.startswith(p) for p in prefixes))
    return sorted(n for n in cand if n not in keep and NAME_RE.match(n)), prefixes


def cmd_env_reads(argv):
    if len(argv) != 1:
        die(2, "usage: env-reads <dark-factory-dir>")
    for n in sorted(env_reads(argv[0])):
        sys.stdout.write(n + "\n")
    return 0


def cmd_clear_list(argv):
    if len(argv) not in (2, 3):
        die(2, "usage: clear-list <dark-factory-dir> <profiles-dir> [<profile>]")
    names, _ = clear_list(argv[0], argv[1], argv[2] if len(argv) == 3 else "")
    for n in names:
        sys.stdout.write(n + "\n")
    return 0


def cmd_effective_env(argv):
    if not argv:
        die(2, "usage: effective-env <clear-list-file> [<mask-name>...]")
    try:
        with open(argv[0], encoding="utf-8") as fh:
            cleared = set(l.strip() for l in fh if l.strip())
    except OSError as exc:
        die(3, "cannot read clear list: %s" % exc)
    mask = set(argv[1:])
    pdir = os.path.join(HERE, "profiles")
    names, prefixes, _ = read_knobs(pdir)
    knobish = cleared | names | set(KILLSWITCHES) | mask
    out = []
    for rec in sys.stdin.buffer.read().split(b"\0"):
        if b"=" not in rec:
            continue
        k, v = rec.split(b"=", 1)
        k = k.decode("utf-8", "replace")
        if k in knobish or any(k.startswith(p) for p in prefixes):
            if k in mask:
                val = "<inherited>"
            elif SECRET_RE.search(k):
                val = "<set>"
            else:
                val = v.decode("utf-8", "replace").replace("\n", " ")
            out.append("%s=%s" % (k, val))
    for line in sorted(out):
        sys.stdout.write(line + "\n")
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


# ----------------------------------------------------------------------------------------------------------
# M3: run-window model attribution
# ----------------------------------------------------------------------------------------------------------
def claude_project_slug(path):
    """Claude Code's transcript store dir name for a cwd: every char outside [A-Za-z0-9] becomes '-'; past 200
    chars the name is cut to 200 and suffixed '-' + base36(|h|), h = the 32-bit signed djb2 `(h << 5) - h + c`
    over the path. Mirrors lib/claude-sandboxed.sh's claude_project_slug (the demo pins both to known answers)."""
    s = re.sub(r"[^A-Za-z0-9]", "-", path)
    if len(s) <= 200:
        return s
    h = 0
    for ch in path:
        h = (h * 31 + ord(ch)) & 0xFFFFFFFF
    if h >= 0x80000000:
        h = 0x100000000 - h
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = ""
    while h > 0:
        out = digits[h % 36] + out
        h //= 36
    return "%s-%s" % (s[:200], out or "0")


def cmd_project_slug(argv):
    if len(argv) != 1:
        die(2, "usage: project-slug <abs-path>")
    sys.stdout.write(claude_project_slug(argv[0]) + "\n")
    return 0


def _attribution_module():
    path = os.path.join(os.path.dirname(HERE), "model-attribution.py")
    spec = importlib.util.spec_from_file_location("_exam_model_attribution", path)
    if spec is None or spec.loader is None or not os.path.isfile(path):
        die(3, "cannot import model-attribution.py next to exam/")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod, path


def run_dirs(root):
    """{stage: [RUN dir, ...]} — every dir named `run` under <root> (plus its `cell-*` children, where the
    parallel cells run), grouped by its top-level dir under <root>. Never descends into a RUN dir any further (an
    invariant RUN dir holds a copy of the target repo) and never follows a symlink."""
    out = {}
    try:
        tops = sorted(os.listdir(root))
    except OSError:
        return out
    for top in tops:
        base = os.path.join(root, top)
        if top == ".git" or os.path.islink(base) or not os.path.isdir(base):
            continue
        for dirpath, dirnames, _ in os.walk(base):
            keep = []
            for d in sorted(dirnames):
                full = os.path.join(dirpath, d)
                if d == ".git" or os.path.islink(full):
                    continue
                if d == "run":
                    out.setdefault(top, []).append(full)
                    try:
                        cells = sorted(c for c in os.listdir(full) if c.startswith("cell-"))
                    except OSError:
                        cells = []
                    for c in cells:
                        cp = os.path.join(full, c)
                        if os.path.isdir(cp) and not os.path.islink(cp):
                            out[top].append(cp)
                    continue
                keep.append(d)
            dirnames[:] = keep
    return out


def _transcript_cwds(path):
    cwds = set()
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"cwd"' not in line:
                    continue
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if isinstance(ev, dict) and isinstance(ev.get("cwd"), str):
                    cwds.add(ev["cwd"])
    except OSError:
        pass
    return cwds


def stage_transcripts(dirs, troot):
    """The transcripts of a stage: for each RUN dir (as given and physical), the store dir of exactly that name;
    a *.jsonl in it counts only when its records' cwd names one of the stage's RUN dirs, or it carries no cwd at
    all (conservative). The name encoding is lossy (`a_b` and `a-b` share a store dir), the cwd is not."""
    want = set()
    for d in dirs:
        want.add(d)
        want.add(os.path.realpath(d))
    found, dropped = [], 0
    seen = set()
    for cwd in sorted(want):
        sd = os.path.join(troot, claude_project_slug(cwd))
        if sd in seen or not os.path.isdir(sd):
            continue
        seen.add(sd)
        for dirpath, dirnames, filenames in os.walk(sd):
            dirnames.sort()
            for f in sorted(filenames):
                if not f.endswith(".jsonl"):
                    continue
                p = os.path.join(dirpath, f)
                cw = _transcript_cwds(p)
                if cw and not (cw & want):
                    dropped += 1
                    continue
                found.append(p)
    return sorted(set(found)), dropped


def _parse_window(spec, what):
    if "," not in spec:
        die(2, "%s: expected <since>,<until>, got %r" % (what, spec))
    since, until = spec.split(",", 1)
    return (since if since not in ("", "-") else ""), (until if until not in ("", "-") else "")


ATTRIB_HEADER = ("stage\trun_dirs\ttranscripts\tdropped\trequests\tfallback\tverdict\twant\tgate\tsince\tuntil"
                 "\trefusal\ttransient_synthetic\tsynthetic_limit")


def cmd_attrib(argv):
    root = troot = model = family = tsv = ""
    stages, excludes, other = {}, set(), None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--root", "--transcripts-root", "--model", "--family", "--tsv", "--stage", "--other", "--exclude"):
            if i + 1 >= len(argv):
                die(2, "attrib: %s needs a value" % a)
            v = argv[i + 1]
            if a == "--root":
                root = v
            elif a == "--transcripts-root":
                troot = v
            elif a == "--model":
                model = v
            elif a == "--family":
                family = v
            elif a == "--tsv":
                tsv = v
            elif a == "--stage":
                if "=" not in v:
                    die(2, "attrib: --stage takes <name>=<since>,<until>")
                name, win = v.split("=", 1)
                stages[name] = _parse_window(win, "--stage " + name)
            elif a == "--other":
                other = _parse_window(v, "--other")
            else:
                excludes.add(v)
            i += 2
            continue
        die(2, "attrib: unknown flag " + a)
    if not root or not tsv or not model:
        die(2, "usage: attrib --root <dir> --transcripts-root <dir> --model <id|-> --tsv <out> --stage <n>=<s>,<u>...")
    rows = [ATTRIB_HEADER]
    if model == "-":
        rows.append("*\t-\t-\t-\t-\t-\t-\t-\tskipped-mock\t-\t-\t-\t-\t-")
        write_atomic(tsv, "\n".join(rows) + "\n")
        return 0
    mod, mpath = _attribution_module()
    fam = family or mod.model_family(model)
    want = "PURE-" + fam.upper()
    found = run_dirs(root)
    names = sorted(set(stages) | set(n for n in found if other is not None and n not in excludes))
    for name in names:
        if name in excludes:
            continue
        required = name in stages
        since, until = stages[name] if required else other
        dirs = found.get(name, [])
        if not dirs:
            if required:
                rows.append("%s\t0\t0\t0\t0\t0\t-\t%s\tnot-run\t%s\t%s\t0\t0\t0" % (name, want, since or "-", until or "-"))
            continue
        paths, dropped = stage_transcripts(dirs, troot)
        req = fb = refusal = synth = synth_limit = 0
        verdict = "-"
        if paths:
            cmd = [sys.executable, mpath, "--json", "--split-synthetic", "--stage", name]
            if since:
                cmd += ["--since", since]
            if until:
                cmd += ["--until", until]
            res = subprocess.run(cmd + paths, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 universal_newlines=True)
            if res.returncode != 0:
                die(3, "attrib: model-attribution.py failed for stage %s: %s" % (name, res.stderr.strip()))
            agg = json.loads(res.stdout).get(name, {})
            req, fb, verdict = agg.get("requests", 0), agg.get("fallback", 0), agg.get("verdict", "-")
            refusal = agg.get("refusal", 0)
            synth, synth_limit = agg.get("transient_synthetic", 0), agg.get("synthetic_limit", 0)
        # A <synthetic> usage-limit notice in the window: the run hit the limit (void-check -> weekly-limit). A
        # refusal is an ERROR, never a pass (the killswitches make it one), even when a retry then answered.
        # A <synthetic> API-error record alone is transient (the cell's own retry answered): counted, not failed.
        if synth_limit > 0:
            gate = "usage-limit"
        elif req == 0:
            gate = "attribution-missing" if required else "not-run"
        elif refusal > 0:
            gate = "refusal"
        elif verdict == want:
            gate = "ok"
        else:
            gate = "fail"
        rows.append("%s\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d" % (
            name, len(dirs), len(paths), dropped, req, fb, verdict, want, gate, since or "-", until or "-",
            refusal, synth, synth_limit))
    write_atomic(tsv, "\n".join(rows) + "\n")
    return 0


# ----------------------------------------------------------------------------------------------------------
# M3: VOID detection
# ----------------------------------------------------------------------------------------------------------
PATTERN_WHERE = ("failed", "final-failed", "cells")
HALT_CLASS = "weekly-limit"
FAIL_MARKERS = (".timeout", ".novalid")
_ATTEMPT_DIR_RE = re.compile(r"\.attempt-[0-9]+$")


def load_patterns(path):
    """void-patterns.tsv -> [(class, compiled regex, where, line no)] in file order."""
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError as exc:
        die(3, "cannot read void patterns %s: %s" % (path, exc))
    out = []
    for n, raw in enumerate(lines, 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 3:
            die(2, "%s:%d: expected class<TAB>regex<TAB>where" % (os.path.basename(path), n))
        cls, rx, where = parts
        if not re.match(r"^[a-z][a-z0-9-]*$", cls):
            die(2, "%s:%d: bad class %r" % (os.path.basename(path), n, cls))
        if where not in PATTERN_WHERE:
            die(2, "%s:%d: where must be one of %s" % (os.path.basename(path), n, "/".join(PATTERN_WHERE)))
        try:
            out.append((cls, re.compile(rx), where, n))
        except re.error as exc:
            die(2, "%s:%d: bad regex: %s" % (os.path.basename(path), n, exc))
    return out


def _failed(log):
    return any(os.path.exists(log + m) for m in FAIL_MARKERS)


class ArmLogs(object):
    """The model-call logs of one zone-hunt-out tree, by scope. Only real output logs are read (hunt_*.log*,
    refute_*.log*, deep-hunt RUN dir *.log) — never the .ag source copies every RUN dir holds."""

    def __init__(self, out):
        self.out = out
        self.final_cells = {}      # zone -> [final-attempt hunt_*.log]
        self.listers = {}          # zone -> [final-attempt promises/*.lister] (#2264 BREADTH_PROMISES lister calls)
        self.all_logs = []         # every model-call log (final + superseded + companions + listers + refute + deep)
        disc = os.path.join(out, "discovery")
        try:
            names = sorted(os.listdir(disc))
        except OSError:
            names = []
        for name in names:
            rd = os.path.join(disc, name, "run")
            if not os.path.isdir(rd) or os.path.islink(os.path.join(disc, name)):
                continue
            superseded = bool(_ATTEMPT_DIR_RE.search(name))
            try:
                files = sorted(os.listdir(rd))
            except OSError:
                files = []
            for f in files:
                if not f.startswith("hunt_"):
                    continue
                p = os.path.join(rd, f)
                if f.endswith(".log"):
                    self.all_logs.append(p)
                    if not superseded:
                        self.final_cells.setdefault(name, []).append(p)
                elif ".log." in f and "-attempt-" in f:
                    self.all_logs.append(p)     # a re-asked attempt kept aside (.untraced-attempt-<n>, ...)
            # The once-per-line promise lister (run/promises/<slug>.lister, validated like a cell: .novalid /
            # .timeout on failure). A failed lister call means the line hunted WITHOUT the promises its profile set.
            pd = os.path.join(rd, "promises")
            for f in (sorted(os.listdir(pd)) if os.path.isdir(pd) else []):
                if f.endswith(".lister"):
                    lp = os.path.join(pd, f)
                    self.all_logs.append(lp)
                    if not superseded:
                        self.listers.setdefault(name, []).append(lp)
        vdir = os.path.join(out, "verify")
        for gates in (sorted(os.listdir(vdir)) if os.path.isdir(vdir) else []):
            gd = os.path.join(vdir, gates)
            if not gates.startswith("gates") or not os.path.isdir(gd):
                continue
            for g in sorted(os.listdir(gd)):
                rd = os.path.join(gd, g, "refute-out", "run")
                if os.path.isdir(rd):
                    self.all_logs.extend(os.path.join(rd, f) for f in sorted(os.listdir(rd))
                                         if f.startswith("refute_") and f.endswith(".log"))
        dh = os.path.join(out, "deep-hunt")
        if os.path.isdir(dh):
            for c in sorted(os.listdir(dh)):
                rd = os.path.join(dh, c, "run")
                if os.path.isdir(rd):
                    self.all_logs.extend(os.path.join(rd, f) for f in sorted(os.listdir(rd)) if f.endswith(".log"))

    def scope(self, where):
        cells = [p for z in sorted(self.final_cells) for p in self.final_cells[z]]
        if where == "cells":
            return cells
        if where == "final-failed":
            return [p for p in cells if _failed(p)]
        return [p for p in self.all_logs if _failed(p)]

    def failed_cells(self):
        return [p for z in sorted(self.final_cells) for p in self.final_cells[z] if _failed(p)]

    def failed_listers(self):
        return [p for z in sorted(self.listers) for p in self.listers[z] if _failed(p)]

    def empty_unmarked(self):
        """Final cell logs that are EMPTY and carry no failure marker: the cell was cut off mid-call (its
        run-discovery.sh died), so it neither answered nor was recorded as failed."""
        out = []
        for z in sorted(self.final_cells):
            for p in self.final_cells[z]:
                try:
                    empty = os.path.getsize(p) == 0
                except OSError:
                    empty = False
                if empty and not _failed(p):
                    out.append((z, p))
        return out

    def incomplete_zones(self, staged):
        """[(zone, reason)] for staged zones whose discovery did not COMPLETE: the coverage record says the zone's
        run-discovery.sh died or never finished (`failed` — run-zone-hunt.sh records it and carries on with exit 0
        —, `in_flight`, or any status that is not hunted / hunted_empty / hunted_degraded), it recorded fewer cells
        than it planned, or a final cell log is empty without a failure marker."""
        out = []
        cov = os.path.join(self.out, "coverage", "zone-coverage.json")
        rec = None
        if os.path.isfile(cov):
            try:
                with open(cov, encoding="utf-8") as fh:
                    rec = json.load(fh)
            except (OSError, ValueError):
                out.append(("-", "coverage/zone-coverage.json unreadable"))
        zones = dict((str(z.get("id")), z) for z in (rec or {}).get("zones", []) if isinstance(z, dict))
        for zid in staged:
            z = zones.get(zid)
            if z is None:
                continue
            st = z.get("status")
            planned, cells = z.get("cells_planned"), z.get("cells")
            if st not in ("hunted", "hunted_empty", "hunted_degraded"):
                out.append((zid, "coverage/zone-coverage.json:%s=%s%s" % (
                    zid, st, (" exit=%s" % z.get("exit_code")) if z.get("exit_code") not in (None, 0) else "")))
            elif isinstance(planned, int) and isinstance(cells, int) and 0 < cells < planned:
                out.append((zid, "coverage/zone-coverage.json:%s cells=%d<planned=%d" % (zid, cells, planned)))
        seen = set(z for z, _ in out)
        for z, p in self.empty_unmarked():
            if z not in seen:
                seen.add(z)
                out.append((z, os.path.relpath(p, self.out) + " (empty, no marker)"))
        return out


# STAGE 4.5 rows whose engine died mid-way: run-zone-hunt.sh prints this and CONTINUES (exit 0) on the legacy
# path; the #2258 scheduler records ENGINE_FAILED in deep-hunt/cell-status.tsv. A budget outcome the profile asked
# for (TIMEOUT, SKIPPED_BUDGET, SKIPPED_TARGET_BROKEN) is a measured result, not a void.
_DEEP_FAIL_RE = re.compile(r"\[deep-hunt\] run-invariant-hunt\.sh failed.* for zone '([^']*)'")


def deep_failures(arm, out):
    """[(zone, evidence ref)] of STAGE 4.5 rows that failed mid-way."""
    res = []
    for log in ("deep.log", "run.log", "rehunt.log"):
        p = os.path.join(arm, log)
        if not os.path.isfile(p):
            continue
        with open(p, encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                m = _DEEP_FAIL_RE.search(line)
                if m:
                    res.append((m.group(1), "%s:%d" % (log, n)))
    cs = os.path.join(out, "deep-hunt", "cell-status.tsv") if out else ""
    if cs and os.path.isfile(cs):
        with open(cs, encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                f = line.rstrip("\n").split("\t")
                if len(f) >= 4 and f[3] == "ENGINE_FAILED":
                    res.append((f[0], "%s:%d" % (os.path.relpath(cs, arm), n)))
    return res


def match_pattern(logs, rx):
    """-> (path, line no) of the first line matching rx over logs, else None."""
    for p in logs:
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                for n, line in enumerate(fh, 1):
                    if rx.search(line.rstrip("\n")):
                        return p, n
        except OSError:
            continue
    return None


def _zone_hunt_out(arm, meta):
    c = meta.get("contest", "")
    out = os.path.join(arm, c, "zone-hunt-out") if c else ""
    if out and os.path.isdir(out):
        return out
    for d in sorted(os.listdir(arm)) if os.path.isdir(arm) else []:
        cand = os.path.join(arm, d, "zone-hunt-out")
        if d != "_gt" and os.path.isdir(cand):
            return cand
    return ""


def read_meta(path):
    meta = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    meta.setdefault(k, v)
    except OSError:
        return None
    return meta


def cmd_rehunt_check(argv):
    if len(argv) != 2:
        die(2, "usage: rehunt-check <zone-hunt-out> <void-patterns.tsv>")
    out, pfile = argv
    pats = load_patterns(pfile)
    logs = ArmLogs(out)
    for cls, rx, where, _ in pats:
        if cls == HALT_CLASS:
            hit = match_pattern(logs.scope(where), rx)
            if hit:
                sys.stdout.write("blocked: %s at %s:%d\n" % (cls, os.path.relpath(hit[0], out), hit[1]))
                return 4
    failed = logs.failed_cells() + logs.failed_listers()
    transport = [p for cls, rx, where, _ in pats if cls == "transport"
                 for p in logs.scope(where) if match_pattern([p], rx)]
    zj = os.path.join(out, "map", "zones.json")
    staged = [str(z.get("id")) for z in load_zones(zj) if z.get("id")] if os.path.isfile(zj) else []
    incomplete = logs.incomplete_zones(staged)
    need = sorted(set(failed) | set(transport))
    if not need and not incomplete:
        return 1
    first = os.path.relpath(need[0], out) if need else incomplete[0][1]
    sys.stdout.write("failed=%d transport=%d incomplete=%d first=%s\n" % (
        len(failed), len(set(transport)), len(incomplete), first))
    return 0


def _is_int(v):
    return bool(re.match(r"^[0-9]+$", v or ""))


def void_zones(arm, pfile):
    """[(zone, class, ref)] — EVERY zone-scoped defect of an arm (not first-match), so a whole-contest arm's
    triage can mark exactly those zones unmeasured."""
    meta = read_meta(os.path.join(arm, "run.meta")) or {}
    out = _zone_hunt_out(arm, meta)
    if not out:
        return []
    logs = ArmLogs(out)
    res = []
    for z in sorted(logs.final_cells):
        rel = lambda p: os.path.relpath(p, arm)  # noqa: E731
        failed = [p for p in logs.final_cells[z] if _failed(p)]
        if failed:
            res.append((z, "transport", rel(failed[0])))
    for p in logs.failed_listers():
        z = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(p))))
        res.append((z, "promise-lister", os.path.relpath(p, arm)))
    zj = os.path.join(out, "map", "zones.json")
    staged = [str(z.get("id")) for z in load_zones(zj) if z.get("id")] if os.path.isfile(zj) else []
    for z, ref in logs.incomplete_zones(staged):
        res.append((z, "zone-incomplete", "%s/%s" % (os.path.relpath(out, arm), ref)))
    for z, ref in deep_failures(arm, out):
        res.append((z, "deep-incomplete", ref))
    for z in staged:
        if not logs.final_cells.get(z):
            res.append((z, "no-cells", "discovery/%s/run" % z))
    return res


def void_verdict(arm, pfile):
    meta = read_meta(os.path.join(arm, "run.meta"))
    if meta is None:
        return ("VOID", "incomplete", "run.meta")
    rel = lambda p: os.path.relpath(p, arm)  # noqa: E731
    for k in ("rc", "rehunt_rc", "deep_rc"):
        if meta.get(k) == "124":
            return ("VOID", "hard-stop", "run.meta:%s=124" % k)
    for k in ("rc", "rehunt_rc", "deep_rc"):
        v = meta.get(k, "")
        if (_is_int(v) and int(v) >= 128) or v == "skip-killed":
            return ("VOID", "killed", "run.meta:%s=%s" % (k, v))
    out = _zone_hunt_out(arm, meta)
    logs = ArmLogs(out) if out else None
    if logs is not None:
        for cls, rx, where, _ in load_patterns(pfile):
            hit = match_pattern(logs.scope(where), rx)
            if hit:
                return ("VOID", cls, "%s:%d" % (rel(hit[0]), hit[1]))
        for z in sorted(logs.final_cells):
            cells = logs.final_cells[z]
            if cells and all(_failed(p) for p in cells):
                return ("VOID", "all-cells-failed", "%s (%d cells)" % (rel(os.path.dirname(cells[0])), len(cells)))
        failed = logs.failed_cells()
        if failed:
            m = [x for x in FAIL_MARKERS if os.path.exists(failed[0] + x)][0]
            return ("VOID", "transport", rel(failed[0] + m))
        flist = logs.failed_listers()
        if flist:
            m = [x for x in FAIL_MARKERS if os.path.exists(flist[0] + x)][0]
            return ("VOID", "promise-lister", rel(flist[0] + m))
        zj = os.path.join(out, "map", "zones.json")
        staged = [str(z.get("id")) for z in load_zones(zj) if z.get("id")] if os.path.isfile(zj) else []
        inc = logs.incomplete_zones(staged)
        if inc:
            return ("VOID", "zone-incomplete", "%s/%s" % (rel(out), inc[0][1]))
        dfail = deep_failures(arm, out)
        if dfail:
            return ("VOID", "deep-incomplete", "%s (zone %s)" % (dfail[0][1], dfail[0][0]))
        for z in staged:
            if not logs.final_cells.get(z):
                return ("VOID", "no-cells", "%s/discovery/%s/run" % (rel(out), z))
    at = os.path.join(arm, "attrib.tsv")
    if os.path.isfile(at):
        with open(at, encoding="utf-8") as fh:
            for line in fh.read().split("\n")[1:]:
                f = line.split("\t")
                if len(f) >= 9 and f[8] == "usage-limit":
                    return ("VOID", HALT_CLASS, "attrib.tsv:%s=synthetic-usage-limit" % f[0])
                if len(f) >= 9 and f[8] not in ("ok", "not-run", "skipped-mock"):
                    return ("VOID", "attribution", "attrib.tsv:%s=%s(%s)" % (f[0], f[6], f[8]))
    elif meta.get("backend", "") != "mock":
        return ("VOID", "attribution", "attrib.tsv:missing")
    op = os.path.join(arm, "void.operator")
    if os.path.isfile(op):
        with open(op, encoding="utf-8", errors="replace") as fh:
            reason = (fh.readline().strip() or "operator").replace("\t", " ")
        return ("VOID", "operator", "void.operator:" + reason)
    return ("VALID", "", "")


def cmd_void_check(argv):
    if len(argv) != 2:
        die(2, "usage: void-check <arm-dir> <void-patterns.tsv>")
    arm, pfile = argv
    if not os.path.isdir(arm):
        die(3, "not an arm dir: " + arm)
    v = void_verdict(arm, pfile)
    line = "VALID" if v[0] == "VALID" else "VOID\t%s\t%s" % (v[1], v[2])
    write_atomic(os.path.join(arm, "void.txt"), line + "\n")
    zones = void_zones(arm, pfile) if v[0] != "VALID" else []
    write_atomic(os.path.join(arm, "void.zones"), "".join("%s\t%s\t%s\n" % z for z in zones))
    sys.stdout.write(line + "\n")
    return 0


COMMANDS = {
    "profile": cmd_profile,
    "profile-summary": cmd_profile_summary,
    "env-reads": cmd_env_reads,
    "clear-list": cmd_clear_list,
    "effective-env": cmd_effective_env,
    "zone-ids": cmd_zone_ids,
    "zone-roots": cmd_zone_roots,
    "zone-filter": cmd_zone_filter,
    "inject-classes": cmd_inject_classes,
    "contam-scan": cmd_contam_scan,
    "project-slug": cmd_project_slug,
    "attrib": cmd_attrib,
    "rehunt-check": cmd_rehunt_check,
    "void-check": cmd_void_check,
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
