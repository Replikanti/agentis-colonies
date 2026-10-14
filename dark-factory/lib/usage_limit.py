#!/usr/bin/env python3
# usage_limit.py — #2291. THE SINGLE DEFINITION of the Claude Code usage-limit notice regex.
#
# WHY IT EXISTS. When the driven Claude session hits its usage quota it prints a notice ("You've hit your weekly
# limit · resets <when>", "<kind> limit reached") instead of an answer. Before #2291 the live hunt path read that
# reply as TUI chrome: it retried it, then recorded a FAILED cell and a `hunted_degraded` zone — a quota outage
# that looked like a tool failure, and every later call burned the same quota for nothing. The exam runner
# (#2262 M3) and model-attribution.py each carried their own copy of the regex; this module is now the only one,
# and every consumer resolves to it:
#   lib/run-agent-validated.sh            `usage_limit.py match <log>` on every sentinel-less reply
#   bench/corpus-bench/model-attribution.py   imports USAGE_LIMIT_RE (sys.path, the fresh-set.py precedent)
#   bench/corpus-bench/exam/void-patterns.tsv the `@usage-limit` regex cell, resolved by exam-helper.py
#
# THE PATTERN matches the WORDS of a notice, never its glyphs: the separator and the apostrophe of a CLI notice
# change between versions and terminals. It must NOT match a generic HTTP `rate limit exceeded` (an API error
# agentis already retries) or prose that merely mentions a limit.
#
# Subcommands (python3 stdlib only; no argparse):
#   match <file>   exit 0 + print `<lineno>\t<line>` for the FIRST matching line (the line is whitespace-trimmed
#                  and cut to MAX_LINE chars: the notice is under 80, anything longer is TUI chrome around it,
#                  and the coverage `detail` that quotes it must stay one line) ; exit 1 = no match ;
#                  exit 2 = usage error or unreadable file.
#   --self-test    pins the positives / negatives below. Exit 0 = held, 1 = regressed.
import os
import re
import sys

USAGE_LIMIT_PATTERN = (
    r"(?i)\b(hit your (weekly |usage |session |5-hour )?limit|(weekly|usage|session|5-hour) limit reached)\b")
USAGE_LIMIT_RE = re.compile(USAGE_LIMIT_PATTERN)

MAX_LINE = 200

HERE = os.path.dirname(os.path.abspath(__file__))
NOTICE_FIXTURE = os.path.join(HERE, "..", "bench", "corpus-bench", "fixtures", "exam-void",
                              "weekly-limit-notice.txt")


def first_match(lines):
    """(1-based line number, trimmed line) of the first line carrying the notice, or None."""
    for n, line in enumerate(lines, 1):
        if USAGE_LIMIT_RE.search(line):
            return n, line.strip()[:MAX_LINE]
    return None


def cmd_match(argv):
    if len(argv) != 1:
        sys.stderr.write("usage: usage_limit.py match <file>\n")
        return 2
    try:
        with open(argv[0], encoding="utf-8", errors="replace") as fh:
            hit = first_match(fh.read().split("\n"))
    except OSError as exc:
        sys.stderr.write("usage_limit.py: cannot read %s: %s\n" % (argv[0], exc))
        return 2
    if hit is None:
        return 1
    sys.stdout.write("%d\t%s\n" % hit)
    return 0


def self_test():
    try:
        with open(NOTICE_FIXTURE, encoding="utf-8") as fh:
            notice = fh.read().strip()
    except OSError as exc:
        sys.stderr.write("usage_limit.py --self-test: cannot read the notice fixture: %s\n" % exc)
        return 1
    positives = [notice, "You've hit your usage limit", "Session limit reached", "5-hour limit reached"]
    negatives = ["rate limit exceeded", "the weekly limit was raised",
                 "CANDIDATE|reentrancy|withdraw()|the cap is a limit on deposits|high"]
    bad = 0
    for p in positives:
        if not USAGE_LIMIT_RE.search(p):
            sys.stderr.write("usage_limit.py --self-test: positive NOT matched: %r\n" % p)
            bad += 1
    for n in negatives:
        if USAGE_LIMIT_RE.search(n):
            sys.stderr.write("usage_limit.py --self-test: negative matched: %r\n" % n)
            bad += 1
    hit = first_match(["chrome", "  " + notice + "  ", "tail"])
    if hit != (2, notice):
        sys.stderr.write("usage_limit.py --self-test: first_match returned %r\n" % (hit,))
        bad += 1
    if first_match(["x" * 300 + " weekly limit reached"]) is None or \
            len(first_match(["x" * 300 + " weekly limit reached"])[1]) != MAX_LINE:
        sys.stderr.write("usage_limit.py --self-test: a long line is not cut to %d chars\n" % MAX_LINE)
        bad += 1
    if bad:
        return 1
    sys.stdout.write("usage_limit.py --self-test: %d positives, %d negatives OK\n" % (len(positives), len(negatives)))
    return 0


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] == ["match"]:
        return cmd_match(argv[1:])
    sys.stderr.write("usage: usage_limit.py match <file> | --self-test\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
