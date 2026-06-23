#!/usr/bin/env python3
"""iter-repos.py - per-tick fan-out helper that emits one TSV line per repo.

Companion helper for `tools/iter-repos.sh` (#316 M3a). Reads
`GITHUB_REPOS_JSON` from the environment when set, falls back to the
legacy `GITHUB_OWNER` / `GITHUB_REPO` / `GITHUB_URL` / `GITHUB_ME`
single-block env when unset, then to a GitLab single-project source
(`GITLAB_PROJECT` / `GITLAB_URL` / `GITLAB_ME`) when no `GITHUB_*` is
configured (#1301), and emits one tab-separated record per repository
on stdout:

    <owner>\\t<repo>\\t<url>\\t<me>\\n

`.ag` agents read the spool, recurse over each line, and call
`tick_for_repo(owner, repo)` once per record. Empty stdout = no repos to
iterate (the caller treats this as a no-op tick); empty fan-out is not
an error so this script always exits 0.

Byte-identity rule (plan §9 of #316 M3): the legacy fallback path AND a
single-entry GITHUB_REPOS_JSON both emit exactly one line with EMPTY
owner / repo fields (the sentinel that disables `--repo`, `repo:` tag,
and memo scoping in agents). Per-repo scoping kicks in only when the
JSON carries 2+ entries — at that point the operator has explicitly
opted into multi-repo and the per-repo experience rows / memo keys are
the desired new shape. The url + me fields are still forwarded on the
sentinel line so agents that consume them stay informed; only the
agent's `repo_arg() / repo_tag() / scoped_memo()` helpers branch on the
empty-owner sentinel.

When `GITHUB_OWNER` is empty in the legacy fallback (no forge configured
at all) we emit nothing rather than a line of empty fields, so an agent
with no forge config simply ticks no work. Tokens are intentionally NOT
emitted — the dispatcher resolves them on demand via
`forge-resolve-repo.py` when `--repo` lands.
"""
import json
import os
import sys


def main():
    raw = os.environ.get("GITHUB_REPOS_JSON", "")
    if raw:
        try:
            entries = json.loads(raw)
        except (ValueError, TypeError) as e:
            sys.stderr.write(
                "iter-repos: GITHUB_REPOS_JSON malformed JSON: %s\n" % e
            )
            return 0
        if not isinstance(entries, list):
            sys.stderr.write(
                "iter-repos: GITHUB_REPOS_JSON must be a JSON array (got %s)\n"
                % type(entries).__name__
            )
            return 0
        # Validate entries up front so single-entry collapse is robust to
        # a single malformed entry (skip + warn matches legacy behaviour).
        valid = []
        for ent in entries:
            if not isinstance(ent, dict):
                sys.stderr.write(
                    "iter-repos: GITHUB_REPOS_JSON entry must be an object (got %s)\n"
                    % type(ent).__name__
                )
                continue
            owner = str(ent.get("owner", ""))
            repo = str(ent.get("repo", ""))
            if not owner or not repo:
                sys.stderr.write(
                    "iter-repos: skipping entry missing owner or repo\n"
                )
                continue
            url = str(ent.get("url", "https://api.github.com"))
            me = str(ent.get("me", ""))
            valid.append((owner, repo, url, me))
        # Byte-identity rule: a single valid entry collapses to the
        # sentinel line — same shape as the legacy fallback below — so
        # agents see no per-repo scoping for an operator who hasn't
        # opted into multi-repo yet (only one repo declared). 2+ entries
        # = real multi-repo, emit each owner/repo verbatim.
        if len(valid) == 1:
            _, _, url, me = valid[0]
            sys.stdout.write("\t\t%s\t%s\n" % (url, me))
            return 0
        for owner, repo, url, me in valid:
            sys.stdout.write("%s\t%s\t%s\t%s\n" % (owner, repo, url, me))
        return 0
    owner = os.environ.get("GITHUB_OWNER", "")
    repo = os.environ.get("GITHUB_REPO", "")
    if owner and repo:
        url = os.environ.get("GITHUB_URL", "https://api.github.com") or "https://api.github.com"
        me = os.environ.get("GITHUB_ME", "")
        # Legacy fallback: emit the sentinel (empty owner/repo) line so the
        # agent runs with `tick_for_repo("", "")` — no `--repo` flag, no
        # `repo:` tag, no memo scoping. github-api.sh consumes the env-
        # exported GITHUB_OWNER/REPO directly so no information is lost.
        sys.stdout.write("\t\t%s\t%s\n" % (url, me))
        return 0
    # GitLab single-project: no GITHUB_* but a GITLAB_PROJECT is configured.
    # Emit the same empty-owner sentinel so the agent ticks the one GitLab
    # project via tick_for_repo("", ""). gitlab-api.sh reads GITLAB_PROJECT /
    # GITLAB_URL from the env directly so no information is lost. Key on
    # GITLAB_PROJECT (it matches the GITLAB_* glob in exec.env_passthrough and
    # therefore reaches the agent's exec sh); FORGE_TYPE is not passed through.
    if os.environ.get("GITLAB_PROJECT", ""):
        url = os.environ.get("GITLAB_URL", "")
        me = os.environ.get("GITLAB_ME", "")
        sys.stdout.write("\t\t%s\t%s\n" % (url, me))
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
