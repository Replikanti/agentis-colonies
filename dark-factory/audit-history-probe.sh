#!/usr/bin/env bash
# audit-history-probe.sh — the REPO-GIT-HISTORY audit-density probe (#1609): the bounty `audits` field is
# unreliable — it is empty even on heavily-hardened repos (Aera/TermMax/Twyne despite heavy fix-audit-N
# history) — so it is a poor proxy for "has this target already been picked over." The target repo's OWN git
# history — fix-audit-N commits/branches, finding refs (C-01/H-02/report 4821), auditor-firm mentions — is the
# real audit-density signal. Standalone sibling to audit-delta.sh: reads history (local dir, no network; or a
# URL via a cheap reachability probe + shallow clone) and emits repo_audit_density (0..100) + a heavily_audited
# verdict. No network write, no submission. Wiring the verdict into run-immunefi-intake.sh's ranking is a
# deferred follow-up (out of scope here — keeps the #1506/#1592/#1599 byte-identical demos untouched).
#
# Usage: audit-history-probe.sh (<repo-url-or-local-dir> | --bounty <file>) [--depth N] [-h]
#   <repo-url-or-local-dir> : a local git checkout (read in place, NO network) OR a repo URL (resolved via a
#                             cheap `git ls-remote` reachability probe, then a shallow --filter=blob:none clone).
#   --bounty <file>         : resolve the repo from a SINGLE bounty JSON object's top-level `githubUrl` OR the
#                             first github-looking in-scope `assets[].url` (checks BOTH — the #1592 mapper only
#                             reads assets[].url; this is the improvement). No resolvable repo -> [SKIP].
#   --depth N                : shallow-clone / log depth (default 500).
#
# Emits ONE JSON object to stdout (python3, no shell JSON parsing):
#   {"repo":"<arg-or-resolved>","source":"local"|"clone","commits_inspected":N,"audit_signal_commits":K,
#    "audit_signal_refs":R,"repo_audit_density":D,"heavily_audited":true|false,
#    "signals":{"fix_audit":..,"finding_ref":..,"firm":..,"competition":..}}
# plus a one-line human summary to stderr (matches run-funnel.sh's >&2 summary convention).
#
# SIGNAL (all matching case-insensitive, in the inline python3 block, over commit subjects + branch/tag
# refnames — never shell regex):
#   fix_audit   : fix-audit / audit-fix(es) / post-audit / "remaining audit fix"
#   finding_ref : Cantina/Sherlock-style C-01/H-02/M-03 finding ids, or an Immunefi "report <NNNN>" id
#   competition : an audit-competition / contest-platform mention (sherlock, cantina, code4rena, codehawks,
#                 hats.finance, ...) — reuses run-immunefi-intake.sh's COMP tuple VERBATIM
#   firm        : a named auditor firm mention (spearbit, trail of bits, certora, ...) — reuses
#                 run-immunefi-intake.sh's FIRMS tuple VERBATIM (generic public firm names only)
# A commit is an audit-signal commit if its subject matches ANY of the four categories (counted once, plus a
# per-category signals breakdown); a refname matching fix_audit/finding_ref increments audit_signal_refs.
#
# SCORING (documented here so it is auditable, computed in python):
#   repo_audit_density = round(100 * audit_signal_commits / max(1, commits_inspected))
#   heavily_audited     = (audit_signal_commits >= 3) OR (audit_signal_refs >= 2) OR (repo_audit_density >= 5)
#   An absolute-count primary trigger, so a big repo's fix-audit-N history still trips even when the ratio (vs
#   a large total commit count) is small.
#
# SKIP contract (mirrors run-funnel.sh): git/python3 not installed, --bounty yields no repo, a single-path-
# segment github ORG url (e.g. github.com/0xTwyne — do NOT enumerate org repos, out of scope), an unreachable
# ls-remote / a failed clone, or offline -> `[SKIP] <reason>` to stderr, exit 0, NO stdout JSON. Never a crash.
#
# Requires: git, python3. Network (read-only ls-remote/clone) only reached on the URL path — the local-dir and
# --bounty-no-repo paths never touch the network, and neither ever writes/submits anything. Exit 0 on success
# or a clean SKIP; 2 on bad/missing args.
set -u

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "audit-history-probe.sh: $2 requires a value" >&2; exit 2; }; }
TARGET="" ; BOUNTY="" ; DEPTH="500"
while [ $# -gt 0 ]; do case "$1" in
  --bounty)  nv "$#" "$1"; BOUNTY="$2"; shift 2;;
  --depth)   nv "$#" "$1"; DEPTH="$2"; shift 2;;
  -h|--help) sed -n '2,48p' "$0"; exit 0;;
  --) shift;;
  -*) echo "audit-history-probe.sh: unknown arg: $1" >&2; exit 2;;
  *)
    if [ -n "$TARGET" ]; then echo "audit-history-probe.sh: unexpected extra arg: $1" >&2; exit 2; fi
    TARGET="$1"; shift;;
esac; done

if [ -z "$TARGET" ] && [ -z "$BOUNTY" ]; then
  echo "audit-history-probe.sh: a <repo-url-or-local-dir> or --bounty <file> is required" >&2; exit 2
fi
if [ -n "$TARGET" ] && [ -n "$BOUNTY" ]; then
  echo "audit-history-probe.sh: give either a positional target or --bounty, not both" >&2; exit 2
fi

command -v git >/dev/null 2>&1     || { echo "[SKIP] git not installed" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

# --- --bounty resolution: top-level githubUrl OR the first github-looking in-scope assets[].url ------------
if [ -n "$BOUNTY" ]; then
  [ -r "$BOUNTY" ] || { echo "[SKIP] --bounty <file> not readable: $BOUNTY" >&2; exit 0; }
  RESOLVED="$(python3 - "$BOUNTY" <<'PY'
import sys, json


def looks_like_repo(u):
    u = str(u or "").lower()
    return any(h in u for h in ("github.com", "bitbucket.org", "sourcehut.org", "sr.ht", "git."))


try:
    d = json.load(open(sys.argv[1], encoding="utf-8", errors="ignore"))
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}

repo = ""
gh = d.get("githubUrl")
if looks_like_repo(gh):
    repo = str(gh)
if not repo:
    for a in (d.get("assets") or []):
        u = a.get("url") if isinstance(a, dict) else a
        if looks_like_repo(u):
            repo = str(u)
            break
print(repo)
PY
)"
  [ -n "$RESOLVED" ] || {
    echo "[SKIP] --bounty: no resolvable repo (no githubUrl / no github-looking assets[].url): $BOUNTY" >&2
    exit 0
  }
  TARGET="$RESOLVED"
fi

# --- resolve source: an existing git work tree is read IN PLACE (no network); else treat as a URL -----------
SOURCE="" ; REPO_ARG="" ; SUBJECTS="" ; REFNAMES=""
if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  SOURCE="local"
  REPO_ARG="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || (cd "$TARGET" && pwd))"
  SUBJECTS="$(git -C "$TARGET" log -n "$DEPTH" --pretty=%s 2>/dev/null || true)"
  REFNAMES="$(git -C "$TARGET" for-each-ref --format='%(refname:short)' 2>/dev/null || true)"
else
  URL="$TARGET"
  REPO_ARG="$URL"

  # a single-path-segment github ORG url (e.g. github.com/0xTwyne) -> SKIP, never enumerate org repos.
  ORGCHECK="$(python3 - "$URL" <<'PY'
import re, sys

u = sys.argv[1].strip()
m = re.match(r"^(?:https?://)?(?:www\.)?github\.com[:/]([^/]+)/?$", u)
print("ORG" if m else "OK")
PY
)"
  if [ "$ORGCHECK" = "ORG" ]; then
    echo "[SKIP] github org URL (no repo segment): $URL — not enumerating org repos" >&2
    exit 0
  fi

  # cheap reachability + branch/tag NAMES (catches fix-audit-N branches even when unmerged), before any clone.
  REFS_RAW="$(git ls-remote --heads --tags "$URL" 2>/dev/null)"; RC=$?
  if [ "$RC" -ne 0 ] || [ -z "$REFS_RAW" ]; then
    echo "[SKIP] git ls-remote unreachable / empty: $URL" >&2
    exit 0
  fi
  REFNAMES="$(printf '%s\n' "$REFS_RAW" | awk '{print $2}')"

  TMP="$(mktemp -d "${TMPDIR:-/tmp}/audit-history-probe.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT
  if ! git clone --bare --filter=blob:none --depth "$DEPTH" --quiet "$URL" "$TMP" >/dev/null 2>&1; then
    echo "[SKIP] git clone failed: $URL" >&2
    exit 0
  fi
  SOURCE="clone"
  SUBJECTS="$(git -C "$TMP" log --all --pretty=%s 2>/dev/null || true)"
fi

# --- signal count + score + emit (python3 only, no shell regex/JSON) -----------------------------------------
REPO_ARG="$REPO_ARG" SOURCE="$SOURCE" SUBJECTS="$SUBJECTS" REFNAMES="$REFNAMES" python3 - <<'PY'
import json
import os
import re
import sys

repo = os.environ["REPO_ARG"]
source = os.environ["SOURCE"]
subjects = [l for l in os.environ.get("SUBJECTS", "").splitlines() if l.strip()]
refnames = [l.strip() for l in os.environ.get("REFNAMES", "").splitlines() if l.strip()]

FIX_AUDIT = re.compile(r"(fix[-_ ]?audit|audit[-_ ]?fix(es)?|post[- ]?audit|remaining audit fix)", re.I)
FINDING_REF = re.compile(r"(\b[CHM]-0?\d{1,2}\b|\breport \d{4,}\b)", re.I)
# COMP/FIRMS reused VERBATIM from run-immunefi-intake.sh's #1599 mapper — generic public firm / contest-
# platform names only, no client or sensitive names.
COMP = ("audit-competition", "audit competition", "audit contest", "sherlock", "cantina", "code4rena",
        "code-423n4", "codehawks", "hats.finance", "hats finance")
FIRMS = ("spearbit", "trail of bits", "trailofbits", "yaudit", "yacademy",
         "certora", "halborn", "cyfrin", "zellic", "consensys diligence", "quantstamp",
         "sigma prime", "sigmaprime", "dedaub", "chainsecurity", "pashov", "guardian audits", "hexens",
         "0xmacro", "peckshield", "slowmist", "oak security", "ackee")

signals = {"fix_audit": 0, "finding_ref": 0, "firm": 0, "competition": 0}
audit_signal_commits = 0
for s in subjects:
    low = s.lower()
    hit = False
    if FIX_AUDIT.search(s):
        signals["fix_audit"] += 1
        hit = True
    if FINDING_REF.search(s):
        signals["finding_ref"] += 1
        hit = True
    if any(f in low for f in FIRMS):
        signals["firm"] += 1
        hit = True
    if any(c in low for c in COMP):
        signals["competition"] += 1
        hit = True
    if hit:
        audit_signal_commits += 1

audit_signal_refs = sum(1 for r in refnames if FIX_AUDIT.search(r) or FINDING_REF.search(r))

commits_inspected = len(subjects)
repo_audit_density = int(round(100 * audit_signal_commits / max(1, commits_inspected)))
heavily_audited = (audit_signal_commits >= 3) or (audit_signal_refs >= 2) or (repo_audit_density >= 5)

obj = {
    "repo": repo,
    "source": source,
    "commits_inspected": commits_inspected,
    "audit_signal_commits": audit_signal_commits,
    "audit_signal_refs": audit_signal_refs,
    "repo_audit_density": repo_audit_density,
    "heavily_audited": heavily_audited,
    "signals": signals,
}
print(json.dumps(obj))

verdict = "HEAVILY-AUDITED" if heavily_audited else "not-heavily-audited"
print("audit-history-probe: %s — density=%d%% signal_commits=%d/%d signal_refs=%d (source=%s)" %
      (verdict, repo_audit_density, audit_signal_commits, commits_inspected, audit_signal_refs, source),
      file=sys.stderr)
PY
