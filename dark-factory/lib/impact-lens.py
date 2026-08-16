#!/usr/bin/env python3
# impact-lens.py — #1930. THE IMPACT -> LENS MAP: the ONE place that translates a bounty program's published
# PAYABLE IMPACT titles (Immunefi's `impacts[]`, surfaced by run-immunefi-intake.sh) into this repo's bug-class
# lenses. Two consumers need the same answer — gen-briefs.sh renders it as brief TEXT (so the hunter looks for
# the impacts that actually pay) and run-zone-hunt.sh's STAGE 4.5 uses it to ORDER the deep-hunt lens fan-out —
# and a duplicated keyword table in two scripts would drift, so the table lives here and nowhere else.
#
# WHAT IT IS NOT. It does not invent an impact taxonomy: the ONLY source of impact titles is the program's own
# published list. An UNMAPPED title is emitted VERBATIM with an EMPTY lens column — never a guessed class.
# Read-only, deterministic, no network, no LLM.
#
# THE TABLE (keyword regex -> bug classes -> label). Class ids are the checked-in `auditor/bug-taxonomy.md`
# codes plus `SYS-solvency`, the class-agnostic general-solvency lens token run-zone-hunt.sh's #1914 lens
# already speaks. Rows are ordered so the SPECIFIC disambiguating row wins: "Temporary freezing" must not be
# read by the permanent-freeze row, so the liveness row is matched first. The FIRST matching row wins (a single
# deterministic verdict per title; a union of rows would make "Theft of unclaimed yield" mean five lenses).
#
# DEEP-HUNT SUBSET. `classes` emits only the classes the STAGE 4.5 deep-hunt actually implements a lens for —
# derived HERE from one tuple (DEEP_HUNT_LENS_CLASSES), never restated by a caller. The emitted order is the
# matched row's DECLARED order (which follows the coverage-map precedence within the row), first-seen wins
# across several impacts — so "Protocol insolvency" leads with `SYS-solvency`, the lens that measures it.
# run-zone-hunt.sh only tests MEMBERSHIP of this set, so the order is informational there.
#
# Subcommands:
#   annotate --impacts <file|->   one line per input impact: `<severity>|<title>|<classes csv>|<label>`.
#                                 `<classes csv>` is the FULL mapped class list (the brief primes the hunter on
#                                 every taxonomy class the impact implies, not only the deep-hunt subset);
#                                 an unmapped title yields empty class + label columns.
#   classes  --impacts <file|->   comma-joined DEEP-HUNT-implemented classes only, deduped, order as above.
#                                 Empty output when nothing maps (a provable no-op for the caller).
#   --self-test                   fixture-driven assertions over the table + both subcommands (the
#                                 bench/corpus-bench/refute-corpus-coverage.sh --self-test precedent).
#
# INPUT SHAPE: newline- and/or comma-separated titles, each optionally prefixed `"<Severity>: <title>"` (the
# shape run-immunefi-intake.sh emits into its payinfo sidecar). A prefix that is not one of
# critical/high/medium/low is NOT a severity — the whole entry stays the title.
#
# Exit: 0 ok ; 1 a --self-test assertion failed ; 2 usage ; 3 unreadable input.
import sys
import re

# The closed severity vocabulary (shared with run-immunefi-intake.sh + finding-payability-gate.sh).
SEVERITIES = ("critical", "high", "medium", "low")

# The deep-hunt lens classes STAGE 4.5 actually implements, in run-zone-hunt.sh's coverage-map precedence order
# (custody-primary, then the non-custody lenses, then the #1914 class-agnostic general-solvency lens). SINGLE
# SOURCE for "is this class reachable by the deep-hunt?" — `classes` filters against it.
DEEP_HUNT_LENS_CLASSES = ("C6", "C10", "C11", "C2", "C16", "C5", "SYS-solvency")

# (keyword regex fragments, classes, label). FIRST match wins; see the header for the ordering rule.
IMPACT_LENS_TABLE = (
    ((r"insolven", r"bad debt", r"under-?collateral"),
     ("SYS-solvency", "C10", "C6"), "protocol solvency / value conservation"),
    ((r"\btheft", r"\bsteal", r"\bstolen", r"\bdrain", r"unauthori[sz]ed"),
     ("C6", "C10", "C11", "C5"), "custody / unauthorized value transfer"),
    # BEFORE the permanent-freeze row: "Temporary freezing of funds" must not be read as a permanent freeze.
    ((r"temporary freez", r"denial of service", r"\bdos\b", r"\bgriefing", r"\bstuck"),
     ("C16", "C18"), "liveness / denial of service"),
    ((r"permanent freez", r"\bfreez", r"\bfrozen", r"\block"),
     ("C13", "C16"), "permanent freeze / stuck funds"),
    ((r"\boracle", r"price manipulation"),
     ("C2",), "oracle integrity"),
    ((r"\bgovernance", r"\bvoting", r"\bvote\b", r"takeover", r"\bprivileg"),
     ("C5",), "governance / privilege escalation"),
    ((r"unclaimed yield", r"\byield"),
     ("C6", "C1"), "yield accounting"),
    ((r"inflation", r"first depositor", r"share price"),
     ("C11", "C1"), "share-price inflation"),
    ((r"\bmint", r"\bsupply"),
     ("C6", "C17"), "supply / mint accounting"),
    ((r"\bbridge", r"cross-?chain"),
     ("C3", "C15"), "cross-chain / integration seam"),
)

MAX_TITLE = 200


def die(rc, msg):
    sys.stderr.write("impact-lens.py: " + msg + "\n")
    sys.exit(rc)


def clean_title(s):
    """A pipe/TSV-safe title: no NUL, no tab/newline, no bare `|` (it is this tool's own column separator)."""
    s = str(s or "").replace("\x00", "")
    s = re.sub(r"[\t\r\n]+", " ", s).replace("|", "/")
    return s.strip()[:MAX_TITLE].strip()


def split_impacts(text):
    """Newline- and comma-separated titles -> a list of raw entries, order-preserving, blanks dropped."""
    out = []
    for line in str(text or "").split("\n"):
        for part in line.split(","):
            part = part.strip()
            if part:
                out.append(part)
    return out


def parse_entry(entry):
    """`"<Severity>: <title>"` -> (severity, title). A prefix that is not a known severity is NOT stripped."""
    entry = clean_title(entry)
    if ":" in entry:
        head, tail = entry.split(":", 1)
        if head.strip().lower() in SEVERITIES and tail.strip():
            return head.strip().lower(), tail.strip()
    return "", entry


def lens_of(title):
    """(classes tuple, label) for a title — the FIRST matching table row, else ((), "") for an unmapped one."""
    low = str(title or "").lower()
    for patterns, classes, label in IMPACT_LENS_TABLE:
        for pat in patterns:
            if re.search(pat, low):
                return classes, label
    return (), ""


def read_impacts(path):
    if path == "-":
        return sys.stdin.read()
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            return fh.read()
    except Exception:
        die(3, "--impacts <file> not readable: " + path)


def parse_flags(argv, valued, boolean):
    """Manual flag walk (the lib/ helper idiom — no argparse). Unknown flags / missing values are usage errors."""
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


def annotated_rows(text):
    """[(severity, title, classes tuple, label)] for every impact in `text`, deduped on (severity, title)."""
    rows = []
    seen = set()
    for entry in split_impacts(text):
        sev, title = parse_entry(entry)
        if not title:
            continue
        key = (sev, title.lower())
        if key in seen:
            continue
        seen.add(key)
        classes, label = lens_of(title)
        rows.append((sev, title, classes, label))
    return rows


def cmd_annotate(argv):
    flags = parse_flags(argv, ("--impacts",), ())
    if "--impacts" not in flags:
        die(2, "annotate requires --impacts <file|->")
    for sev, title, classes, label in annotated_rows(read_impacts(flags["--impacts"])):
        sys.stdout.write("%s|%s|%s|%s\n" % (sev, title, ",".join(classes), label))
    return 0


def cmd_classes(argv):
    flags = parse_flags(argv, ("--impacts",), ())
    if "--impacts" not in flags:
        die(2, "classes requires --impacts <file|->")
    out = []
    for _sev, _title, classes, _label in annotated_rows(read_impacts(flags["--impacts"])):
        for c in classes:
            if c in DEEP_HUNT_LENS_CLASSES and c not in out:
                out.append(c)
    sys.stdout.write(",".join(out) + "\n" if out else "")
    return 0


# ------------------------------------------------------------------------------------------------------------
# --self-test: fixtures over the table + both subcommands. Every assertion is a CONTRACT a consumer relies on.
# ------------------------------------------------------------------------------------------------------------
def self_test():
    fails = []

    def check(cond, what):
        if cond:
            sys.stdout.write("  [PASS] %s\n" % what)
        else:
            sys.stdout.write("  [FAIL] %s\n" % what)
            fails.append(what)

    # 1) The live TermMax-shaped impact set: insolvency leads with the general-solvency lens, theft routes to
    #    custody, and the two freezing flavours stay distinguishable.
    c, _l = lens_of("Protocol insolvency")
    check(c and c[0] == "SYS-solvency", "'Protocol insolvency' leads with the SYS-solvency lens")
    c, _l = lens_of("Direct theft of user funds")
    check("C6" in c and "C10" in c, "'Direct theft of user funds' routes to the custody lenses")
    c, _l = lens_of("Permanent freezing of funds")
    check("C13" in c and "C16" in c, "'Permanent freezing of funds' routes to the freeze lenses")
    c, _l = lens_of("Temporary freezing of funds")
    check("C18" in c and "C13" not in c, "'Temporary freezing of funds' is liveness, NOT a permanent freeze")
    c, _l = lens_of("Theft of unclaimed yield")
    check("C6" in c and "C11" in c, "'Theft of unclaimed yield' routes to custody (theft wins over yield)")

    # 2) An UNMAPPED title is never guessed at.
    c, label = lens_of("Something entirely unrelated to any known class")
    check(c == () and label == "", "an unmapped title yields NO class and NO label (never a guess)")

    # 3) `classes` emits only deep-hunt-implemented tokens, deduped, order-deterministic.
    got = []
    for _s, _t, cl, _lb in annotated_rows("Critical: Protocol insolvency\nCritical: Direct theft of user funds"):
        for x in cl:
            if x in DEEP_HUNT_LENS_CLASSES and x not in got:
                got.append(x)
    check(got == ["SYS-solvency", "C10", "C6", "C11", "C5"],
          "classes dedupes across impacts in first-seen order: %s" % ",".join(got))
    check(all(x in DEEP_HUNT_LENS_CLASSES for x in got),
          "classes emits ONLY deep-hunt-implemented tokens (no C13/C18/C1/C17/C3/C15)")
    unmapped = [x for _s, _t, cl, _lb in annotated_rows("An impact nobody mapped") for x in cl]
    check(unmapped == [], "classes returns EMPTY for an unmapped title")

    # 4) Entry parsing: the `<Severity>: <title>` prefix, comma/newline splitting, and a non-severity prefix.
    rows = annotated_rows("High: Permanent freezing of funds, Critical: Protocol insolvency")
    check(len(rows) == 2 and rows[0][0] == "high" and rows[1][0] == "critical",
          "comma-separated `<Severity>: <title>` entries parse into per-impact severities")
    sev, title = parse_entry("Note: something happened")
    check(sev == "" and title == "Note: something happened",
          "a non-severity prefix is NOT stripped (the whole entry stays the title)")
    sev, title = parse_entry("Protocol insolvency")
    check(sev == "" and title == "Protocol insolvency", "a bare title parses with an empty severity")

    # 5) Sanitisation: no tab/newline/NUL/pipe can leak into the pipe-separated annotate output.
    _s, title = parse_entry("High: a\ttitle\nwith|separators\x00")
    check("\t" not in title and "\n" not in title and "|" not in title and "\x00" not in title,
          "titles are scrubbed of tabs, newlines, NUL and the `|` column separator")
    check(len(parse_entry("High: " + ("x" * 500))[1]) <= MAX_TITLE, "titles are capped at %d chars" % MAX_TITLE)

    # 6) Determinism: the same input twice yields the same rows.
    a = annotated_rows("Critical: Protocol insolvency, High: Theft of unclaimed yield")
    b = annotated_rows("Critical: Protocol insolvency, High: Theft of unclaimed yield")
    check(a == b, "annotate is deterministic across runs")

    if fails:
        sys.stderr.write("impact-lens.py --self-test: %d assertion(s) FAILED\n" % len(fails))
        return 1
    sys.stdout.write("impact-lens.py --self-test: all assertions held\n")
    return 0


COMMANDS = {
    "annotate": cmd_annotate,
    "classes": cmd_classes,
}


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: impact-lens.py <annotate|classes> --impacts <file|-> | --self-test\n")
        return 2
    if argv[1] in ("-h", "--help"):
        sys.stdout.write("usage: impact-lens.py <annotate|classes> --impacts <file|-> | --self-test\n")
        return 0
    if argv[1] == "--self-test":
        return self_test()
    cmd = COMMANDS.get(argv[1])
    if cmd is None:
        die(2, "unknown subcommand: " + argv[1])
    return cmd(argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
