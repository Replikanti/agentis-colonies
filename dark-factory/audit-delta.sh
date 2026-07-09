#!/usr/bin/env bash
# audit-delta.sh — the POST-AUDIT-DELTA detector (#1506, epic #1505): given a target's local git checkout and
# the commit/tag an audit covered, surface the files that changed SINCE that audit as the priority hunt surface.
# The premise (borne out by the confirmed Lombard finding): a professionally-audited protocol's residual bug
# almost never lives in the fortified, N-times-reviewed core — it lives in the DELTA that landed AFTER the audit
# froze, in code no auditor ever saw. This is a pure `git diff` primitive: no network, no LLM, no submission. A
# general muscle other callers (e.g. run-immunefi-intake.sh's delta scoring term, or audit-scout.ag) reuse.
#
# Usage: audit-delta.sh --repo <dir> --since <commit-ish> [--paths <file>] [-h]
#   --repo   : the target's local git checkout (REQUIRED).
#   --since  : the audit-covered commit / tag / ref (REQUIRED). Everything changed on <since>..HEAD is the delta.
#   --paths  : optional file of newline-separated in-scope relative paths (exact file or a directory prefix) to
#              intersect the changed set against; only changed files under an in-scope path survive (else ALL
#              changed files count). Blank lines and `#` comments are ignored (a plain path list, like
#              run-coordinator.sh's --scope file — no glob engine).
#
# Emits ONE JSON object to stdout (python3, matching the sibling scripts' python-for-JSON convention):
#   {"repo":"<abs>","since":"<arg>","since_commit":"<sha>","head_commit":"<sha>","files_changed":N,
#    "changed_files":[...],"latest_change_days_ago":D|null,"verdict":"DELTA"|"NO-DELTA"}
# files_changed==0 (since==HEAD, or nothing survives the --paths filter) -> verdict "NO-DELTA",
# latest_change_days_ago null — never a crash on the empty-diff edge cases. A one-line human summary goes to
# stderr (matching run-funnel.sh's >&2 summary convention).
#
# Requires: git, python3. No network. Exit 0 on a clean DELTA or NO-DELTA read; 2 on bad/missing args; 3 on
# not-a-git-repo / an unresolvable --since / git not installed.
set -u

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "audit-delta.sh: $2 requires a value" >&2; exit 2; }; }
REPO="" ; SINCE="" ; PATHS_FILE=""
while [ $# -gt 0 ]; do case "$1" in
  --repo)  nv "$#" "$1"; REPO="$2"; shift 2;;
  --since) nv "$#" "$1"; SINCE="$2"; shift 2;;
  --paths) nv "$#" "$1"; PATHS_FILE="$2"; shift 2;;
  -h|--help) sed -n '2,26p' "$0"; exit 0;;
  *) echo "audit-delta.sh: unknown arg: $1" >&2; exit 2;;
esac; done

[ -n "$REPO" ]  || { echo "audit-delta.sh: --repo <dir> is required" >&2; exit 2; }
[ -n "$SINCE" ] || { echo "audit-delta.sh: --since <commit-ish> is required" >&2; exit 2; }
if [ -n "$PATHS_FILE" ] && [ ! -r "$PATHS_FILE" ]; then
  echo "audit-delta.sh: --paths <file> not readable: $PATHS_FILE" >&2; exit 2
fi

command -v git >/dev/null 2>&1 || { echo "audit-delta.sh: git not installed" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

# --- resolve the repo + refs; any failure here is a loud exit 3 (never a silent empty delta) ----------------
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "audit-delta.sh: not a git work tree: $REPO" >&2; exit 3; }
REPO_ABS="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || (cd "$REPO" && pwd))"
SINCE_SHA="$(git -C "$REPO" rev-parse --verify "${SINCE}^{commit}" 2>/dev/null)" \
  || { echo "audit-delta.sh: --since does not resolve to a commit in $REPO: $SINCE" >&2; exit 3; }
HEAD_SHA="$(git -C "$REPO" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
  || { echo "audit-delta.sh: HEAD does not resolve to a commit in $REPO" >&2; exit 3; }

# The raw changed-file set on <since>..HEAD (name-only). since==HEAD yields an empty set -> NO-DELTA below.
CHANGED="$(git -C "$REPO" diff --name-only "${SINCE_SHA}..${HEAD_SHA}" 2>/dev/null || true)"

# --- filter by --paths (if given), compute recency + verdict, emit the JSON object (python3, JSON only) ------
REPO_ABS="$REPO_ABS" SINCE_ARG="$SINCE" SINCE_SHA="$SINCE_SHA" HEAD_SHA="$HEAD_SHA" \
CHANGED="$CHANGED" PATHS_FILE="$PATHS_FILE" python3 - <<'PY'
import os, sys, json, subprocess, time

repo = os.environ["REPO_ABS"]
since_arg = os.environ["SINCE_ARG"]
since_sha = os.environ["SINCE_SHA"]
head_sha = os.environ["HEAD_SHA"]
changed = [l.strip() for l in os.environ.get("CHANGED", "").splitlines() if l.strip()]
paths_file = os.environ.get("PATHS_FILE", "")

# In-scope path filter: a changed file survives if it exactly equals an in-scope entry OR sits under one as a
# directory prefix. A plain newline-separated list (blank lines + `#` comments skipped) — no glob engine, to
# match run-coordinator.sh's --scope file convention.
scope = []
if paths_file:
    try:
        for line in open(paths_file, encoding="utf-8", errors="ignore"):
            p = line.strip()
            if p and not p.startswith("#"):
                scope.append(p.rstrip("/"))
    except Exception:
        scope = []

if scope:
    def in_scope(cf):
        return any(cf == p or cf.startswith(p + "/") for p in scope)
    survivors = [cf for cf in changed if in_scope(cf)]
else:
    survivors = list(changed)

survivors = sorted(set(survivors))

# latest_change_days_ago: whole days since the most recent commit on <since>..HEAD touching ANY survivor. None
# when nothing survives (NO-DELTA). A git hiccup -> None, never a crash.
days = None
if survivors:
    try:
        out = subprocess.run(
            ["git", "-C", repo, "log", "-1", "--format=%ct",
             "%s..%s" % (since_sha, head_sha), "--"] + survivors,
            capture_output=True, text=True, timeout=30,
        ).stdout.strip()
        if out.isdigit():
            days = max(0, int((time.time() - int(out)) / 86400))
    except Exception:
        days = None

verdict = "DELTA" if survivors else "NO-DELTA"
obj = {
    "repo": repo,
    "since": since_arg,
    "since_commit": since_sha,
    "head_commit": head_sha,
    "files_changed": len(survivors),
    "changed_files": survivors,
    "latest_change_days_ago": days,
    "verdict": verdict,
}
print(json.dumps(obj))

# one-line human summary to stderr (matches run-funnel.sh's >&2 convention).
if survivors:
    d = ("%dd" % days) if days is not None else "?d"
    print("audit-delta: DELTA — %d file(s) changed since %s (latest %s ago)" % (len(survivors), since_arg, d),
          file=sys.stderr)
else:
    print("audit-delta: NO-DELTA — nothing changed since %s (or filtered out of scope)" % since_arg,
          file=sys.stderr)
PY
