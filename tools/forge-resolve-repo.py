#!/usr/bin/env python3
"""forge-resolve-repo.py - resolve `--repo owner/repo` against GITHUB_REPOS_JSON.

Companion helper for `dev-apprenticeship/*/scripts/forge-api.sh`'s `--repo`
dispatch path (#316 M3a). Reads `GITHUB_REPOS_JSON` from the environment,
finds the entry matching the (owner, repo) tuple supplied on argv, and
emits shell-quoted env exports on stdout for the dispatcher to `eval`:

    GITHUB_OWNER=...
    GITHUB_REPO=...
    GITHUB_TOKEN=...
    GITHUB_URL=...
    GITHUB_ME=...

Tokens travel through the environment, never argv — they would otherwise
appear on `ps`. The dispatcher's `eval "$(...)"` consumes the stdout
verbatim and re-exports the five vars for the duration of one wrapper
invocation. Idempotent: a second call with the same tuple emits the same
exports.

Failure modes (no token leaked on stderr):

    exit 0  resolved (5 quoted exports printed to stdout)
    exit 1  GITHUB_REPOS_JSON unset or empty (caller must check before calling)
    exit 1  no entry matched the (owner, repo) tuple
    exit 2  GITHUB_REPOS_JSON malformed (not a JSON array of objects)
    exit 2  usage error (wrong argv count)

Args (positional):
    1: owner    — case-sensitive owner / org segment of `--repo`
    2: repo     — case-sensitive repo segment of `--repo`

Environment:
    GITHUB_REPOS_JSON   — JSON array of `{url, owner, repo, token, me}` objects
                           as exported by `start-colony.sh` (#316 M2).
"""
import json
import os
import shlex
import sys


def main():
    argv = sys.argv[1:]
    if len(argv) != 2:
        sys.stderr.write(
            "Usage: %s <owner> <repo>\n" % sys.argv[0]
        )
        return 2
    owner, repo = argv
    raw = os.environ.get("GITHUB_REPOS_JSON", "")
    if not raw:
        sys.stderr.write(
            "forge-resolve-repo: GITHUB_REPOS_JSON unset or empty\n"
        )
        return 1
    try:
        entries = json.loads(raw)
    except (ValueError, TypeError) as e:
        sys.stderr.write(
            "forge-resolve-repo: GITHUB_REPOS_JSON malformed JSON: %s\n" % e
        )
        return 2
    if not isinstance(entries, list):
        sys.stderr.write(
            "forge-resolve-repo: GITHUB_REPOS_JSON must be a JSON array (got %s)\n"
            % type(entries).__name__
        )
        return 2
    for ent in entries:
        if not isinstance(ent, dict):
            sys.stderr.write(
                "forge-resolve-repo: GITHUB_REPOS_JSON entry must be an object (got %s)\n"
                % type(ent).__name__
            )
            return 2
        if ent.get("owner") == owner and ent.get("repo") == repo:
            sys.stdout.write("GITHUB_OWNER=%s\n" % shlex.quote(str(ent.get("owner", ""))))
            sys.stdout.write("GITHUB_REPO=%s\n" % shlex.quote(str(ent.get("repo", ""))))
            sys.stdout.write("GITHUB_TOKEN=%s\n" % shlex.quote(str(ent.get("token", ""))))
            sys.stdout.write("GITHUB_URL=%s\n" % shlex.quote(str(ent.get("url", "https://api.github.com"))))
            sys.stdout.write("GITHUB_ME=%s\n" % shlex.quote(str(ent.get("me", ""))))
            return 0
    sys.stderr.write(
        "forge-resolve-repo: no entry for %s/%s in GITHUB_REPOS_JSON\n" % (owner, repo)
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
