#!/usr/bin/env python3
# promise-gate.py — #2245 (iteration 7, deep-hunt PROMISES). The two mechanical gates around the invariant
# prover's PROMISE extraction: `gate` keeps only the promises whose citation re-opens to in-repo text that names
# the promise's subject, and `coverage` checks that every accepted promise ended up as its own asserting
# `<prefix>_p<k>_...` invariant function in the generated harness.
#
# WHAT IT IS NOT. Not a Solidity front-end and not a judge of meaning (stdlib only, runs offline on CI). The gate is
# a floor on the FORM of the evidence — the same stated limit as run-discovery.sh's _dismiss_evidence_ok /
# _param_bound_ok: whether a cited line really makes the promise is an operator read. The coverage check is
# textual: an asserting but trivially-true invariant passes it (stated, not hidden).
#
# The model writes FREE-FORM promises (issue #2245 iteration-7 STOP-1 decision 4 — no kind vocabulary in any
# prompt):
#   PROMISE|#<k>|<subject: entry point or state variable>|<one-sentence statement>|<path>:<line>[-<line>]
# The KIND column below is assigned HERE, afterwards, from the fixed KIND_MAP keyword table, for REPORTING ONLY.
# It is never shown to the model: the BEGIN-ACCEPTED block (the prompt-visible half) carries no kind.
#
# gate --raw <file> --repo <staged repo> --out <accepted.tsv> [--cap 8] [--names-in <file>]
#   --names-in (#2264, breadth PROMISES — run-discovery.sh passes it, the deep hunt never does): <file> lists
#   repo-relative paths, one per line (the scope line's own `.sol` tokens). A promise whose subject none of those
#   files names is dropped as `subject-off-payload`, checked AFTER every citation rule, so it never takes a cap
#   slot. Each path resolves under --repo with check_cite's path safety (absolute, `..`, outside --repo or not a
#   file => skipped). A whole-file grep, so it is over-inclusive by design: a subject named only outside a slice
#   is kept. Without the flag the output is byte-identical to before.
#   Strips the FCB_<hex>_BEGIN/END result-file sentinels (#2207), reads the `PROMISE|` lines, and checks each in
#   ascending #k order; the first failing rule is reported by its id:
#     bad-id               field 2 is not `#<1..99>`
#     dup-id               `#k` already seen (the first occurrence wins)
#     bad-subject          no identifier left after normalising the subject (cut at the first `(`/`[`, keep the
#                          part after the last `.`)
#     no-statement         the statement is empty
#     cite-missing         no `path:line` in the last field
#     cite-unresolved      an absolute path, a `..` segment, a file not under --repo, or a range outside the file
#                          (or a > b)
#     cite-deploy          the cited path is under script/ scripts/ deploy/ broadcast/
#     cite-out-of-scope    the cited path is under lib/ node_modules/ dependencies/ test/ tests/ mocks/ (vendored
#                          code and the staged mock library are not the target's promises)
#     cite-too-wide        the cited range is longer than CITE_MAX_LINES lines
#     cite-names-other     the cited range does not name the subject as a whole word (a leading `_` is tolerated)
#     cite-deployed-state  the statement or the citation rests on deployed-state wording
#     subject-off-payload  #2264, ONLY with --names-in: the subject is named (as a whole word, a leading `_`
#                          tolerated — the cite-names-other regex) in NONE of the files listed in <file>
#   At most --cap promises are ACCEPTED; the promises after the cap is reached are OVERCAP (recorded, never gated).
#   Stdout (always exit 0 at runtime; exit 2 only for CLI misuse):
#     PROMISES|emitted=<e>|accepted=<a>|dropped=<d>|overcap=<o>
#     BEGIN-READOUT / PROMISE-ACCEPTED|#k|subject|kind|statement|cite / PROMISE-DROPPED|#k|<id> /
#       PROMISE-OVERCAP|#k / END-READOUT
#     BEGIN-ACCEPTED / `#k | subject | statement | cite` + up to CITE_SHOW_LINES indented cited source lines /
#       END-ACCEPTED
#   --out TSV: k \t subject \t kind \t kind_keyword \t statement \t cite
#   Every echoed model-derived field maps `|` to `/` and tabs to spaces, so no output line carries `INVARIANT|`.
#
# coverage --accepted <tsv> --harness <file> [--prefix invariant]
#   A promise #k is COVERED when, after comment stripping, the harness declares `function <prefix>_p<k>_<ident>(`
#   (anchored, so `_p1_` never matches `_p10_`) whose brace-matched body contains require( / assert( / revert.
#   Stdout: PCOVERAGE|covered=<c>|total=<t>|<ok|low|n/a>, PCOVERED|#.., PUNCOVERED|#.., and a
#   BEGIN-UNCOVERED..END-UNCOVERED block holding the uncovered promises' `#k | subject | statement | cite` lines
#   verbatim (the same lines the ACCEPTED block carries). ok iff every accepted promise is covered; n/a iff there
#   is none (vacuous, treated as ok). A missing harness file covers nothing.
import os
import re
import sys

# Byte-identical copies of run-discovery.sh _param_bound_ok's citation regexes (themselves identical to
# _dismiss_evidence_ok's). demo-deep-hunt-promises.sh pins the literal equality — edit both or neither.
PB_PATHLINE_RE = r'[A-Za-z0-9_/.-]+\.(sol|ts|js|md|json|toml|ya?ml):[0-9]+(-[0-9]+)?'
PB_DEPLOY_RE = r'(^|/)(script|scripts|deploy|broadcast)/'
PB_ADMIT_RE = r'ONCHAIN|@block|as deployed|currently deployed|as shipped|shipped (market|config|deployment)|mainnet|live market'

OUT_OF_SCOPE_RE = r'(^|/)(lib|node_modules|dependencies|test|tests|mocks)/'
CITE_MAX_LINES = 40
CITE_SHOW_LINES = 6
CITE_SHOW_CHARS = 160
DEFAULT_CAP = 8

# The fixed REPORTING keyword map (first match wins, in this order). Applied to subject + statement AFTER the
# gate; never rendered into any prompt.
KIND_MAP = (
    ("time-lock", r"\b(time-?locks?|lock(s|ed|up|ups)?|unlock\w*|hold\w*|held|window|delay\w*|cooldown|wait\w*|elaps\w*|expir\w*|vest\w*|deadline|period|duration)\b"),
    ("ordering", r"\b(before|after|once|already|order|sequence|prior|first|then|until|later|earlier|again|twice)\b"),
    ("rounding", r"\b(round\w*|floor|ceil\w*|precision|dust|truncat\w*)\b"),
    ("per-user-conservation", r"\b(withdraw\w*|deposit\w*|balance\w*|tak(e|es|en|ing)|more than|claim\w*|refund\w*|pull\w*|put in|funds)\b"),
    ("bound", r"\b(cap|capped|max\w*|min\w*|limit\w*|exceed\w*|bound\w*|threshold|at most|at least)\b"),
    ("access", r"\b(only|owner|admin\w*|role\w*|authori\w*|permission\w*|whitelist\w*|allowlist\w*|caller)\b"),
)

_PROMISE_LINE_RE = re.compile(r"^\s*[-*]?\s*PROMISE\|")
_FCB_RE = re.compile(r"FCB_[0-9a-f]+_(BEGIN|END)")
_ID_RE = re.compile(r"^#([1-9][0-9]?)$")
_IDENT_RE = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")
_SUBJECT_STOP = ("function", "modifier", "event", "mapping", "contract", "state", "variable", "the", "a", "an",
                 "public", "external", "internal", "private")


def usage(msg):
    sys.stderr.write("promise-gate.py: " + msg + "\n")
    sys.exit(2)


def parse_flags(argv, valued):
    out = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in valued:
            if i + 1 >= len(argv):
                usage(a + " requires a value")
            out[a] = argv[i + 1]
            i += 2
        else:
            usage("unknown arg: " + a)
    return out


def clean(field):
    """The echo sanitiser: `|` -> `/`, tabs -> spaces, surrounding whitespace dropped."""
    return field.replace("|", "/").replace("\t", " ").strip()


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            return fh.read()
    except OSError:
        return ""


def normalise_subject(subject):
    s = subject.strip().strip("`").strip()
    for ch in "([":
        if ch in s:
            s = s[:s.index(ch)]
    if "." in s:
        s = s[s.rindex(".") + 1:]
    for tok in _IDENT_RE.findall(s.replace("`", " ")):
        if tok.lower() not in _SUBJECT_STOP:
            return tok
    return ""


def assign_kind(subject, statement):
    # camelCase subjects are split into words first, so `lockedUntil` reads as "locked until".
    text = (re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", subject) + " " + statement).lower()
    for kind, pat in KIND_MAP:
        m = re.search(pat, text)
        if m:
            return kind, m.group(0)
    return "other", "-"


def check_cite(source, subject, statement, repo):
    """Return (fail_id or None, rel, a, b, range_lines)."""
    m = re.search(PB_PATHLINE_RE, source)
    if not m:
        return "cite-missing", "", 0, 0, []
    cite = m.group(0)
    rel, rng = cite.split(":", 1)
    if rel.startswith("/") or ".." in rel:
        return "cite-unresolved", rel, 0, 0, []
    root = os.path.realpath(repo)
    path = os.path.realpath(os.path.join(repo, rel))
    if not (path == root or path.startswith(root + os.sep)) or not os.path.isfile(path):
        return "cite-unresolved", rel, 0, 0, []
    if "-" in rng:
        a_s, b_s = rng.split("-", 1)
    else:
        a_s, b_s = rng, rng
    a, b = int(a_s), int(b_s)
    lines = read_text(path).split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if a < 1 or a > b or b > len(lines):
        return "cite-unresolved", rel, a, b, []
    if re.search(PB_DEPLOY_RE, rel):
        return "cite-deploy", rel, a, b, []
    if re.search(OUT_OF_SCOPE_RE, rel):
        return "cite-out-of-scope", rel, a, b, []
    if b - a + 1 > CITE_MAX_LINES:
        return "cite-too-wide", rel, a, b, []
    rng_lines = lines[a - 1:b]
    bare = subject.lstrip("_")
    named = re.compile(r"(^|[^A-Za-z0-9_$])_*" + re.escape(bare) + r"([^A-Za-z0-9_$]|$)")
    if not bare or not any(named.search(ln) for ln in rng_lines):
        return "cite-names-other", rel, a, b, []
    if re.search(PB_ADMIT_RE, statement + " " + source, re.I):
        return "cite-deployed-state", rel, a, b, []
    return None, rel, a, b, rng_lines


def _names_in_texts(path, repo):
    """#2264: the texts of the files listed in `path` (one repo-relative path per line), each resolved under `repo`
    with check_cite's path safety. A path that is absolute, carries `..`, escapes the repo or is not a file is
    skipped; an unreadable list file lists nothing."""
    root = os.path.realpath(repo)
    texts = []
    for rel in read_text(path).splitlines():
        rel = rel.strip()
        if not rel or rel.startswith("/") or ".." in rel:
            continue
        full = os.path.realpath(os.path.join(repo, rel))
        if not (full == root or full.startswith(root + os.sep)) or not os.path.isfile(full):
            continue
        texts.append(read_text(full))
    return texts


def _named_in(subject, texts):
    """True when one of `texts` names `subject` as a whole word (a leading `_` tolerated) — the cite-names-other
    regex of check_cite, applied to whole files."""
    bare = subject.lstrip("_")
    if not bare:
        return False
    named = re.compile(r"(^|[^A-Za-z0-9_$])_*" + re.escape(bare) + r"([^A-Za-z0-9_$]|$)", re.M)
    return any(named.search(t) for t in texts)


def cmd_gate(argv):
    flags = parse_flags(argv, ("--raw", "--repo", "--out", "--cap", "--names-in"))
    if "--raw" not in flags or "--repo" not in flags or "--out" not in flags:
        usage("gate requires --raw --repo --out")
    cap_s = flags.get("--cap", str(DEFAULT_CAP))
    if not cap_s.isdigit():
        usage("--cap must be a whole number")
    cap = int(cap_s)
    raw = _FCB_RE.sub("", read_text(flags["--raw"]))
    repo = flags["--repo"]
    names_in = _names_in_texts(flags["--names-in"], repo) if "--names-in" in flags else None

    entries = []      # (k or None, raw_id, parts) in file order
    for line in raw.splitlines():
        if not _PROMISE_LINE_RE.match(line):
            continue
        body = line.strip()
        body = body[body.index("PROMISE|"):]
        parts = body.split("|")
        raw_id = parts[1].strip() if len(parts) > 1 else ""
        m = _ID_RE.match(raw_id)
        entries.append((int(m.group(1)) if m else None, raw_id, parts))

    readout = []
    accepted_rows = []
    accepted_block = []
    dropped = 0
    overcap = 0
    seen = set()
    ordered = []
    for k, raw_id, parts in entries:
        if k is None:
            readout.append((10 ** 6, "PROMISE-DROPPED|%s|bad-id" % (clean(raw_id) or "#?")))
            dropped += 1
            continue
        if k in seen:
            readout.append((k, "PROMISE-DROPPED|#%d|dup-id" % k))
            dropped += 1
            continue
        seen.add(k)
        ordered.append((k, parts))
    ordered.sort(key=lambda e: e[0])

    for k, parts in ordered:
        if len(accepted_rows) >= cap:
            readout.append((k, "PROMISE-OVERCAP|#%d" % k))
            overcap += 1
            continue
        subject = normalise_subject(parts[2] if len(parts) > 2 else "")
        source = parts[-1] if len(parts) >= 4 else ""
        statement = clean("|".join(parts[3:-1])) if len(parts) >= 5 else ""
        fail = None
        if not subject:
            fail = "bad-subject"
        elif not statement:
            fail = "no-statement"
        if fail is None:
            fail, rel, a, b, rng_lines = check_cite(source, subject, statement, repo)
        if fail is None and names_in is not None and not _named_in(subject, names_in):
            fail = "subject-off-payload"
        if fail is not None:
            readout.append((k, "PROMISE-DROPPED|#%d|%s" % (k, fail)))
            dropped += 1
            continue
        cite = "%s:%d" % (rel, a) if a == b else "%s:%d-%d" % (rel, a, b)
        kind, kw = assign_kind(subject, statement)
        readout.append((k, "PROMISE-ACCEPTED|#%d|%s|%s|%s|%s" % (k, subject, kind, statement, cite)))
        accepted_rows.append("\t".join([str(k), subject, kind, clean(kw), statement, cite]))
        accepted_block.append("#%d | %s | %s | %s" % (k, subject, statement, cite))
        shown = 0
        for ln in rng_lines:
            if not ln.strip():
                continue
            if shown >= CITE_SHOW_LINES:
                break
            accepted_block.append("    " + ln.strip()[:CITE_SHOW_CHARS])
            shown += 1

    readout.sort(key=lambda e: e[0])
    out = ["PROMISES|emitted=%d|accepted=%d|dropped=%d|overcap=%d" % (
        len(entries), len(accepted_rows), dropped, overcap)]
    out.append("BEGIN-READOUT")
    out.extend(r for _k, r in readout)
    out.append("END-READOUT")
    out.append("BEGIN-ACCEPTED")
    out.extend(accepted_block)
    out.append("END-ACCEPTED")
    sys.stdout.write("\n".join(out) + "\n")
    try:
        with open(flags["--out"], "w", encoding="utf-8") as fh:
            fh.write("".join(r + "\n" for r in accepted_rows))
    except OSError:
        pass
    return 0


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    return text


def fn_body(text, start):
    """The brace-matched body following index `start` (the end of a function header match), or ""."""
    brace = text.find("{", start)
    semi = text.find(";", start)
    if brace < 0 or (0 <= semi < brace):
        return ""
    depth = 0
    j = brace
    while j < len(text):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:j]
        j += 1
    return text[brace + 1:]


_ASSERTS_RE = re.compile(r"\brequire\s*\(|\bassert\s*\(|\brevert\b")


def cmd_coverage(argv):
    flags = parse_flags(argv, ("--accepted", "--harness", "--prefix"))
    if "--accepted" not in flags or "--harness" not in flags:
        usage("coverage requires --accepted --harness")
    prefix = flags.get("--prefix", "invariant") or "invariant"
    rows = []
    for line in read_text(flags["--accepted"]).splitlines():
        p = line.split("\t")
        if len(p) >= 6 and p[0].isdigit():
            rows.append((int(p[0]), p[1], p[4], p[5]))
    harness = strip_comments(read_text(flags["--harness"]))
    covered = []
    uncovered = []
    for k, subject, statement, cite in rows:
        hdr = re.compile(r"\bfunction\s+" + re.escape(prefix) + r"_p" + str(k) + r"_[A-Za-z0-9_$]+\s*\(")
        hit = False
        for m in hdr.finditer(harness):
            if _ASSERTS_RE.search(fn_body(harness, m.end())):
                hit = True
                break
        (covered if hit else uncovered).append((k, subject, statement, cite))
    total = len(rows)
    if total == 0:
        state = "n/a"
    elif not uncovered:
        state = "ok"
    else:
        state = "low"
    out = ["PCOVERAGE|covered=%d|total=%d|%s" % (len(covered), total, state)]
    out.append("PCOVERED|" + ",".join("#%d" % r[0] for r in covered))
    out.append("PUNCOVERED|" + ",".join("#%d" % r[0] for r in uncovered))
    out.append("BEGIN-UNCOVERED")
    out.extend("#%d | %s | %s | %s" % r for r in uncovered)
    out.append("END-UNCOVERED")
    sys.stdout.write("\n".join(out) + "\n")
    return 0


COMMANDS = {"gate": cmd_gate, "coverage": cmd_coverage}


def main(argv):
    if len(argv) < 1 or argv[0] not in COMMANDS:
        usage("usage: promise-gate.py <gate|coverage> [flags]")
    return COMMANDS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
