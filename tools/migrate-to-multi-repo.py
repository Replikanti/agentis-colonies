#!/usr/bin/env python3
"""migrate-to-multi-repo.py: rewrite a legacy [forge.github] block into
a single [[forge.github]] entry.

Idempotent. Preserves comments and operator hand-edits. Re-runs on an
already-migrated file print "already migrated" and exit 0 without
modifying the file. Refuses to touch a config that contains both forms
(`colony-lint.sh` lints that case first).

The structural mutation is a single-line rewrite: any line whose
stripped content equals `[forge.github]` becomes `[[forge.github]]`,
preserving leading whitespace. Every other line is passed through
verbatim (comments, blank lines, key/value pairs, sibling sections).
This guarantees byte-perfect preservation of operator hand-edits with
no `tomllib` round-trip and no `sed -i` portability tax — see
`tools/parse-toml-secret.py` for the same line-pass-through pattern.

Invoked from `tools/migrate-to-multi-repo.sh` (one-line `exec` wrapper);
flags are parsed here so the wrapper stays heredoc-free under bash 3.2.

Exit codes:
    0  migrated (or already migrated; idempotent no-op)
    1  config has both [forge.github] and [[forge.github]] — manual fix needed
    2  usage error (incl. file not found)
    3  no [forge.github] block found at all (config predates ADR-0002)

Usage:
    migrate-to-multi-repo.py [--dry-run|--backup] <path/to/colony.toml>
"""
import os
import sys


SINGLE_HDR = '[forge.github]'
MULTI_HDR = '[[forge.github]]'


def has_block(lines, header):
    return any(ln.strip() == header for ln in lines)


def main():
    args = sys.argv[1:]
    dry_run = False
    backup = False
    while args and args[0].startswith('--'):
        flag = args.pop(0)
        if flag == '--dry-run':
            dry_run = True
        elif flag == '--backup':
            backup = True
        else:
            sys.stderr.write('migrate-to-multi-repo: unknown flag: ' + flag + '\n')
            return 2
    if len(args) != 1:
        sys.stderr.write('usage: migrate-to-multi-repo.py [--dry-run|--backup] <path>\n')
        return 2
    path = args[0]
    if not os.path.isfile(path):
        sys.stderr.write('migrate-to-multi-repo: file not found: ' + path + '\n')
        return 2
    with open(path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    has_single = has_block(lines, SINGLE_HDR)
    has_multi = has_block(lines, MULTI_HDR)
    if has_single and has_multi:
        sys.stderr.write(path + ': both [forge.github] and [[forge.github]] present — manual fix needed\n')
        return 1
    if has_multi and not has_single:
        sys.stdout.write(path + ': already migrated (no-op)\n')
        return 0
    if not has_single:
        sys.stderr.write(path + ': no [forge.github] block found (nothing to migrate)\n')
        return 3
    out = []
    for ln in lines:
        if ln.strip() == SINGLE_HDR:
            lead = ln[:len(ln) - len(ln.lstrip())]
            out.append(lead + MULTI_HDR + '\n')
        else:
            out.append(ln)
    new_text = ''.join(out)
    if dry_run:
        sys.stdout.write(new_text)
        return 0
    if backup:
        os.replace(path, path + '.bak')
        with open(path, 'w', encoding='utf-8') as f:
            f.write(new_text)
    else:
        tmp = path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(new_text)
        os.replace(tmp, path)
    sys.stdout.write(path + ': migrated [forge.github] -> [[forge.github]] (1 entry preserved)\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
