#!/usr/bin/env python3
# handler-coverage.py — #2245 (iteration 6, deep-hunt REACH). The HANDLER-COVERAGE matcher: compare a generated
# invariant harness's ACTIONS against the target's full entry-point list (entry-points.tsv, produced by
# `inheritance.py reach-inventory`) and report how many listed entry points the harness actually exercises.
#
# WHAT IT IS NOT. Not a Solidity front-end and not an executed-coverage tool — there is no solc, no forge, no
# call/revert metrics. It is a TEXTUAL matcher (stdlib only) that runs offline on CI. An action that always
# reverts still counts as textually covered here (stated + accepted; executed coverage is the follow-up).
#
# CONTRACT (always exit 0 — the .ag caller fails OPEN on any tool error, counting it as a mechanics FAIL):
#   COVERAGE|covered=<c>|total=<t>|required=<r>|mode=<typed|registered|name-only|none|n/a>|<ok|low>
#   COVERED|<a,b,...>
#   UNCOVERED|<x,y,...>
# required = ceil(0.6 * total) (total is already capped at 20 by reach-inventory). ok iff total == 0 (vacuous)
# or covered >= required; so zero coverage is always low.
import math
import re
import sys


def parse_flags(argv):
    out = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--entry-points", "--harness"):
            if i + 1 >= len(argv):
                sys.stderr.write("handler-coverage.py: " + a + " requires a value\n")
                return None
            out[a] = argv[i + 1]
            i += 2
        else:
            sys.stderr.write("handler-coverage.py: unknown arg: " + a + "\n")
            return None
    return out


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    return text


def remove_block_body(text, header_re):
    """Brace-match and delete the body of each declaration whose header matches header_re (setUp / constructor):
    wiring calls in setUp/constructors are NOT actions."""
    out = []
    idx = 0
    for m in header_re.finditer(text):
        brace = text.find("{", m.end())
        if brace < 0:
            continue
        depth = 0
        j = brace
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out.append((brace + 1, j))
    if not out:
        return text
    res = []
    prev = 0
    for a, b in out:
        res.append(text[prev:a])
        prev = b
    res.append(text[prev:])
    return "".join(res)


_SETUP_RE = re.compile(r"\bfunction\s+setUp\s*\(")
_CTOR_RE = re.compile(r"\bconstructor\s*\(")


def read_entry_points(path):
    types = []
    eps = []
    target = ""
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            data = fh.read()
    except OSError:
        return target, types, eps
    for line in data.splitlines():
        if line.startswith("TARGET|"):
            parts = line.split("|")
            if len(parts) >= 3:
                target = parts[2]
        elif line.startswith("TYPES|"):
            types = [t for t in line[len("TYPES|"):].split(",") if t]
        elif line.startswith("EP|"):
            parts = line.split("|")
            if len(parts) >= 2 and parts[1]:
                eps.append(parts[1])
        # OVERCAP| lines are recorded by reach-inventory and never gated here.
    # dedupe entry points preserving order (overloads already share one name upstream)
    seen = set()
    uniq = []
    for n in eps:
        if n not in seen:
            seen.add(n)
            uniq.append(n)
    return target, types, uniq


def find_receivers(text, types):
    """Variables declared with a TYPES name -> receiver identifiers, plus the set of TYPES names used as a cast
    `<Type>(...)`. A receiver is a variable whose declared type is the target or one of its bases."""
    receivers = {}
    if types:
        type_alt = "|".join(re.escape(t) for t in types)
        decl_re = re.compile(r"\b(" + type_alt + r")\s+(?:memory\s+|storage\s+|calldata\s+)?([A-Za-z_$][A-Za-z0-9_$]*)\s*[;=,)]")
        for m in decl_re.finditer(text):
            receivers[m.group(2)] = m.group(1)
        cast_re = re.compile(r"\b(" + type_alt + r")\s*\(")
        cast_types = set(m.group(1) for m in cast_re.finditer(text))
    else:
        cast_types = set()
    return receivers, cast_types


def main(argv):
    flags = parse_flags(argv)
    if flags is None or "--entry-points" not in flags or "--harness" not in flags:
        # No parse -> no COVERAGE line -> the .ag caller treats it as mode=unmeasured (fail open, mechanics FAIL).
        return 0
    target, types, eps = read_entry_points(flags["--entry-points"])
    try:
        with open(flags["--harness"], encoding="utf-8", errors="ignore") as fh:
            raw = fh.read()
    except OSError:
        return 0
    # Receiver DECLARATIONS (state vars) and the target REGISTRATION live in setUp/constructors, so they are
    # detected on the comment-stripped FULL text. ACTIONS (the .fn() calls the fuzzer drives) are counted only
    # on the body-stripped text — wiring calls inside setUp/constructor are not actions.
    clean = strip_comments(raw)
    body = remove_block_body(remove_block_body(clean, _SETUP_RE), _CTOR_RE)

    total = len(eps)
    if total == 0:
        sys.stdout.write("COVERAGE|covered=0|total=0|required=0|mode=n/a|ok\n")
        sys.stdout.write("COVERED|\n")
        sys.stdout.write("UNCOVERED|\n")
        return 0

    receivers, cast_types = find_receivers(clean, types)
    typed_exists = bool(receivers) or bool(cast_types)

    # Registered mode: a typed receiver is registered directly as a fuzz target -> the fuzzer calls all of its
    # externals, so every entry point counts. Detected on the FULL text (registration is a setUp call).
    registered = False
    for var in receivers:
        if re.search(r"(?:_target|targetContract)\(\s*address\(\s*" + re.escape(var) + r"\s*\)", clean):
            registered = True
            break

    covered = []
    if registered:
        mode = "registered"
        covered = list(eps)
    elif typed_exists:
        mode = "typed"
        type_alt = "|".join(re.escape(t) for t in types) if types else "$^"
        for n in eps:
            hit = False
            for var in receivers:
                if re.search(re.escape(var) + r"\.\s*" + re.escape(n) + r"\s*[({]", body):
                    hit = True
                    break
            if not hit:
                if re.search(r"\b(?:" + type_alt + r")\s*\([^;{}]*\)\s*\.\s*" + re.escape(n) + r"\s*\(", body):
                    hit = True
                elif re.search(r"abi\.encodeCall\(\s*(?:" + type_alt + r")\s*\.\s*" + re.escape(n) + r"\b", body):
                    hit = True
                elif re.search(r"\b(?:" + type_alt + r")\s*\.\s*" + re.escape(n) + r"\s*\.selector", body):
                    hit = True
            if hit:
                covered.append(n)
    else:
        mode = "none"
        for n in eps:
            if re.search(r"\.\s*" + re.escape(n) + r"\s*\(", body):
                covered.append(n)
        if covered:
            mode = "name-only"

    c = len(covered)
    required = int(math.ceil(0.6 * total))
    ok = c >= required
    uncovered = [n for n in eps if n not in covered]
    sys.stdout.write("COVERAGE|covered=%d|total=%d|required=%d|mode=%s|%s\n" % (
        c, total, required, mode, "ok" if ok else "low"))
    sys.stdout.write("COVERED|" + ",".join(covered) + "\n")
    sys.stdout.write("UNCOVERED|" + ",".join(uncovered) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
