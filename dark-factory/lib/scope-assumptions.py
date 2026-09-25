#!/usr/bin/env python3
# scope-assumptions.py — #2257. THE DECLARED-SCOPE BLOCK: the one place that turns a target's OWN scope docs into
# a short, line-cited list of the assumptions it declares (token behaviour, deployment chains, trusted roles,
# explicit exclusions, known issues), and the one place that decides whether a refutation citing one of them
# meets its evidence contract.
#
# WHY. The refute gate never saw what a target declares out of scope, so a finding whose exploit only works with
# a token the docs exclude ("standard tokens only, no fee-on-transfer") could survive to verified[] — a precision
# cost today and a submission-quality risk on a paid target. The gate can only reject such a premise if it is
# SHOWN the declaration, and a rejection is only trustworthy if the declaration it rests on is QUOTED from the
# target's own docs. So this helper is deterministic (no network, no LLM), cites every row by file and line, and
# owns BOTH halves of the block grammar: `extract` writes it, `check` reads it. run-refute.sh never re-parses the
# block itself, so the grammar is defined exactly once.
#
# BLOCK GRAMMAR (one row per line, source order, at most 40 rows, text at most 300 characters):
#   A<n>|<category>|<source>:<first>[-<last>]|<text>
# <category> is one of token, chain, trust, exclusion, known-issue. <source> is repo-relative (an operator file is
# cited by its BASENAME only, so no host path ever reaches an artifact). An EMPTY stdout means nothing was
# declared, and every caller treats that as OFF.
#
# Subcommands:
#   extract --repo <dir> [--operator <file>]
#       Sources: --operator REPLACES auto-extraction (explicit curation wins). Otherwise the repo-root SCOPE.md is
#       read first, then README.md (file names matched case-insensitively).
#       Auto mode reads only lines under a heading matching SECTION_GATE_RE (a heading stack: a sub-heading
#       inherits its parent's gate), plus `Q:`-style question lines anywhere. A question line and its answer
#       paragraph become ONE row `Q: … — A: …` cited first-last and categorised by the QUESTION text; a
#       markdown table row becomes `cell1: cell2` (header and separator rows skipped); every other qualifying
#       line becomes one row. Skipped: fenced code, lines naming a source file (SOURCE_FILE_RE — this keeps the
#       in-scope file list out), and fragments shorter than 12 characters.
#       Operator mode reads bullets only; a `## <category>` heading sets the category of the bullets under it,
#       any other bullet is classified by keyword and falls back to `exclusion` (the operator wrote it down on
#       purpose, so it is never silently dropped).
#   check --block <file> --claim <text> --evidence <text>
#       The contract decider for refuter.ag's `out-of-scope-premise` ground. <evidence> is fields 3..N of the
#       scraped `REFUTE-GROUND|` record. Normalisation: lowercase, ALL whitespace dropped (a PTY wrap can split a
#       quote anywhere), `|` -> `/`. Checks, in order:
#         1. `A<n>:"<quote>"` present, normalised quote >= 12 chars       else scope-cite-missing
#         2. A<n> exists in the block and the quote is inside THAT row     else scope-cite-unresolved
#         3. the row's category is not `trust` (context only)              else scope-not-citable
#         4. `premise:"<quote>"` present, normalised quote >= 8 chars      else scope-premise-missing
#         5. the premise is inside the candidate's claim                   else scope-premise-unresolved
#       Prints `ok\t<id>\t<category>\t<source>\t<text>\t<premise>` or `fail\t<contract-id>`.
#
# Exit: 0 ok (for `check`, both `ok` and `fail` are exit 0 — a failed contract is an answer, not an error);
#       2 usage; 3 unreadable input.
import os
import re
import sys

MAX_ROWS = 40
MAX_TEXT = 300
MIN_FRAGMENT = 12
MIN_ASSUMPTION_QUOTE = 12
MIN_PREMISE_QUOTE = 8

# Which headings open a section worth reading. Case-insensitive; a heading that does not match closes the gate
# for its own level and everything below it.
SECTION_GATE_RE = re.compile(
    r"q ?& ?a|scop|assumption|known issue|publicly known|acceptable risk|trust|role|privilege|token|erc|chain"
    r"|deploy|out of scope|limitation", re.I)
# A section whose heading declares known issues puts every row under it in `known-issue`, whatever it says.
KNOWN_ISSUE_HEADING_RE = re.compile(r"known issue|publicly known|acceptable risk", re.I)
# The keyword table, in PRIORITY order (known-issue by heading comes first, above). It lives only here.
CATEGORY_KEYWORDS = (
    ("trust", re.compile(
        r"\btrust|\badmin|\bowner|\bgovernance|\bprivileg|\broles?\b|\bmultisig|\bkeepers?\b|\bguardians?\b",
        re.I)),
    ("token", re.compile(
        r"\btokens?\b|\berc-?\d+|fee.?on.?transfer|\brebas|\bweird\b|deflationar|inflationar|\bdecimals\b"
        r"|\bblock ?list|\bblack ?list|non-?standard", re.I)),
    ("chain", re.compile(r"\bchains?\b|\bmainnet|\bl2s?\b|layer.?2|\brollups?\b|\bnetworks?\b|\bevm\b", re.I)),
    ("exclusion", re.compile(
        r"out.of.scope|not in scope|\bexclud|\bnot (?:be )?considered|\binvalid\b|\bwill not\b|\bwon.t\b"
        r"|\bignored?\b|\blimitations?\b|not (?:a )?valid", re.I)),
)
CATEGORIES = ("token", "chain", "trust", "exclusion", "known-issue")
SOURCE_FILE_RE = re.compile(r"\.(sol|vy|rs|move|cairo|ts|js)\b", re.I)
HEADING_RE = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
QUESTION_RE = re.compile(r"^\s*(?:[-*+]\s+)?(?:#{1,6}\s+)?(?:\*\*|__)?Q(?:\*\*|__)?\s*[:.]\s*(?:\*\*|__)?\s*")
ANSWER_PREFIX_RE = re.compile(r"^\s*(?:[-*+]\s+)?(?:\*\*|__)?A(?:\*\*|__)?\s*[:.]\s*(?:\*\*|__)?\s*")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
RULE_RE = re.compile(r"^\s*([-*_])(\s*\1){2,}\s*$")
TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$")
BULLET_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+")
ROW_RE = re.compile(r"^A(\d+)\|([a-z-]+)\|([^|]*)\|(.*)$")
CITE_RE = re.compile(r"\bA\s*(\d+)\s*:\s*[\"“”]([^\"“”]*)[\"“”]")
PREMISE_RE = re.compile(r"premise\s*:\s*[\"“”]([^\"“”]*)[\"“”]", re.I)
LINK_RE = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")


def die(msg, code):
    sys.stderr.write("scope-assumptions.py: %s\n" % msg)
    sys.exit(code)


def clean(text):
    """One markdown line -> plain row text. The SAME function renders every row, so a quote copied from the
    rendered block is always comparable with the row it came from."""
    s = text
    s = LINK_RE.sub(r"\1", s)
    s = BULLET_RE.sub("", s)
    s = re.sub(r"^\s*>\s?", "", s)
    s = s.replace("**", "").replace("__", "").replace("`", "")
    s = s.replace("|", "/").replace("\t", " ")
    s = re.sub(r"\s+", " ", s).strip()
    return s


def classify(text):
    for cat, rx in CATEGORY_KEYWORDS:
        if rx.search(text):
            return cat
    return None


def norm(text):
    return re.sub(r"\s+", "", text.lower()).replace("|", "/")


def cite(source, first, last):
    return "%s:%d" % (source, first) if first == last else "%s:%d-%d" % (source, first, last)


def table_cells(line):
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    return [c for c in cells if c != ""]


def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().split("\n")
    except OSError as exc:
        die("cannot read %s: %s" % (path, exc), 3)


def extract_auto(lines, source):
    """Rows of one repo doc, in source order: (category, source, first, last, text)."""
    rows = []
    stack = []          # [(level, heading text)]
    in_fence = False
    i, n = 0, len(lines)

    def gated():
        return any(SECTION_GATE_RE.search(h) for _, h in stack)

    def heading_category():
        if any(KNOWN_ISSUE_HEADING_RE.search(h) for _, h in stack):
            return "known-issue"
        return None

    def heading_fallback():
        for _, h in reversed(stack):
            cat = classify(h)
            if cat:
                return cat
        return None

    while i < n:
        raw = lines[i]
        if FENCE_RE.match(raw):
            in_fence = not in_fence
            i += 1
            continue
        if in_fence:
            i += 1
            continue
        if QUESTION_RE.match(raw):
            q_first = i + 1
            question = clean(QUESTION_RE.sub("", raw, count=1))
            question = re.sub(r"^#+\s*", "", question).strip()
            answer, last = [], q_first
            j = i + 1
            while j < n and lines[j].strip() == "":
                j += 1
            while j < n:
                nxt = lines[j]
                if (nxt.strip() == "" or HEADING_RE.match(nxt) or QUESTION_RE.match(nxt) or RULE_RE.match(nxt)
                        or FENCE_RE.match(nxt)):
                    break
                if not SOURCE_FILE_RE.search(clean(nxt)):
                    part = clean(ANSWER_PREFIX_RE.sub("", nxt, count=1))
                    if part:
                        answer.append(part)
                        last = j + 1
                j += 1
            # A question heading is a heading too: it keeps the stack honest for the lines after the answer.
            hm = HEADING_RE.match(raw)
            if hm:
                level = len(hm.group(1))
                while stack and stack[-1][0] >= level:
                    stack.pop()
                stack.append((level, hm.group(2)))
            text = "Q: %s — A: %s" % (question, " ".join(answer)) if answer else "Q: %s" % question
            cat = heading_category() or classify(question) or heading_fallback()
            if cat and answer and len(text) >= MIN_FRAGMENT:
                rows.append((cat, source, q_first, last, text[:MAX_TEXT]))
            i = j
            continue
        hm = HEADING_RE.match(raw)
        if hm:
            level = len(hm.group(1))
            while stack and stack[-1][0] >= level:
                stack.pop()
            stack.append((level, hm.group(2)))
            i += 1
            continue
        if raw.strip() == "" or RULE_RE.match(raw) or not gated():
            i += 1
            continue
        if raw.lstrip().startswith("|"):
            if TABLE_SEP_RE.match(raw):
                i += 1
                continue
            # A row followed by a separator row is the table's HEADER, not a declaration.
            if i + 1 < n and TABLE_SEP_RE.match(lines[i + 1]):
                i += 1
                continue
            cells = [clean(c) for c in table_cells(raw)]
            cells = [c for c in cells if c]
            text = "%s: %s" % (cells[0], cells[1]) if len(cells) >= 2 else (cells[0] if cells else "")
        else:
            text = clean(raw)
        if SOURCE_FILE_RE.search(text) or len(text) < MIN_FRAGMENT:
            i += 1
            continue
        cat = heading_category() or classify(text) or heading_fallback()
        if cat:
            rows.append((cat, source, i + 1, i + 1, text[:MAX_TEXT]))
        i += 1
    return rows


def extract_operator(lines, source):
    rows = []
    section = None
    in_fence = False
    for idx, raw in enumerate(lines):
        if FENCE_RE.match(raw):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        hm = HEADING_RE.match(raw)
        if hm:
            h = hm.group(2).lower()
            section = None
            for cat, rx in (("known-issue", r"known"), ("trust", r"trust"), ("token", r"token"),
                            ("chain", r"chain"), ("exclusion", r"exclu|out.of.scope")):
                if re.search(rx, h):
                    section = cat
                    break
            continue
        if not BULLET_RE.match(raw):
            continue
        text = clean(raw)
        if len(text) < MIN_FRAGMENT:
            continue
        cat = section or classify(text) or "exclusion"
        rows.append((cat, source, idx + 1, idx + 1, text[:MAX_TEXT]))
    return rows


def find_doc(repo, name):
    try:
        entries = sorted(os.listdir(repo))
    except OSError as exc:
        die("cannot list --repo %s: %s" % (repo, exc), 3)
    for e in entries:
        if e.lower() == name.lower() and os.path.isfile(os.path.join(repo, e)):
            return e
    return None


def cmd_extract(args):
    repo, operator = None, None
    it = iter(args)
    for a in it:
        if a == "--repo":
            repo = next(it, None)
        elif a == "--operator":
            operator = next(it, None)
        else:
            die("extract: unknown argument %s" % a, 2)
    if not repo or not os.path.isdir(repo):
        die("extract: --repo <dir> required", 2)
    rows = []
    if operator:
        if not os.path.isfile(operator):
            die("extract: --operator not found: %s" % operator, 2)
        rows = extract_operator(read_lines(operator), os.path.basename(operator))
    else:
        for name in ("SCOPE.md", "README.md"):
            found = find_doc(repo, name)
            if found:
                rows.extend(extract_auto(read_lines(os.path.join(repo, found)), found))
    out = []
    for n, (cat, source, first, last, text) in enumerate(rows[:MAX_ROWS], 1):
        out.append("A%d|%s|%s|%s" % (n, cat, cite(source, first, last), text))
    if out:
        sys.stdout.write("\n".join(out) + "\n")
    return 0


def load_block(path):
    rows = {}
    for line in read_lines(path):
        m = ROW_RE.match(line.rstrip("\r"))
        if m:
            rows["A" + m.group(1)] = (m.group(2), m.group(3), m.group(4))
    return rows


def cmd_check(args):
    block, claim, evidence = None, None, None
    it = iter(args)
    for a in it:
        if a == "--block":
            block = next(it, None)
        elif a == "--claim":
            claim = next(it, None)
        elif a == "--evidence":
            evidence = next(it, None)
        else:
            die("check: unknown argument %s" % a, 2)
    if block is None or claim is None or evidence is None:
        die("check: --block <file> --claim <text> --evidence <text> required", 2)
    if not os.path.isfile(block):
        die("check: --block not found: %s" % block, 3)
    rows = load_block(block)

    def fail(cid):
        sys.stdout.write("fail\t%s\n" % cid)
        return 0

    m = CITE_RE.search(evidence)
    if not m or len(norm(m.group(2))) < MIN_ASSUMPTION_QUOTE:
        return fail("scope-cite-missing")
    rid = "A" + m.group(1)
    if rid not in rows or norm(m.group(2)) not in norm(rows[rid][2]):
        return fail("scope-cite-unresolved")
    cat, source, text = rows[rid]
    if cat == "trust":
        return fail("scope-not-citable")
    p = PREMISE_RE.search(evidence)
    if not p or len(norm(p.group(1))) < MIN_PREMISE_QUOTE:
        return fail("scope-premise-missing")
    if norm(p.group(1)) not in norm(claim):
        return fail("scope-premise-unresolved")
    premise = re.sub(r"\s+", " ", p.group(1)).strip()
    sys.stdout.write("ok\t%s\t%s\t%s\t%s\t%s\n" % (rid, cat, source, text.replace("\t", " "), premise))
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stdout.write("usage: scope-assumptions.py extract --repo <dir> [--operator <file>]\n"
                         "       scope-assumptions.py check --block <file> --claim <text> --evidence <text>\n")
        return 0 if len(argv) >= 2 else 2
    if argv[1] == "extract":
        return cmd_extract(argv[2:])
    if argv[1] == "check":
        return cmd_check(argv[2:])
    die("unknown subcommand %s" % argv[1], 2)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
