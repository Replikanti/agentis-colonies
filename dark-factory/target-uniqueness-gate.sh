#!/usr/bin/env bash
# target-uniqueness-gate.sh — PRE-HUNT TARGET-LEVEL UNIQUENESS GATE (#1899, epic #1894 M3). Distinct from the
# finding-level novelty-gate.sh (#1485): BEFORE a hunt is spent, decide whether this TARGET is worth hunting at
# all given how known/audited its surface already is — and, in the same pass, PRODUCE the exclusion set the
# downstream finding-level gate needs. This script is the PRODUCER; novelty-gate.sh stays the untouched
# CONSUMER (reused VERBATIM, as are fetch-audits.sh and audit-history-probe.sh).
#
# Usage: target-uniqueness-gate.sh [--repo <owner/name|github-url>] [--scope-hint "<5-col scope_hint>"]
#                                  [--local-dir <dir>] [--audit-manifest <file>] [--audits-dir <dir>]
#                                  [--exclusion-out <file>] [--gh-cmd "<cmd>"] [--probe-cmd "<cmd>"]
#                                  [--density-skip N] [--density-hot N] [--density-cold N]
#                                  [--known-hot N] [--known-cold N] [--max-signatures N] [-h]
#   --repo          : the target repo. Accepts `owner/name`, `github.com/owner/name`,
#                     `https://github.com/owner/name[.git]`; anything else is operator error -> exit 2.
#   --scope-hint    : a run-immunefi-intake.sh scope_hint (col 5). The first `repo:<value>` token is extracted
#                     with the SAME one-liner apply-audit-density.sh uses. `repo:-` (the no-repo sentinel) or
#                     no token at all resolves to NO repo — a DATA condition, never exit 2 (see below).
#                     `--repo` wins when both are given.
#   --local-dir     : a local git checkout -> the NO-NETWORK density leg (audit-history-probe.sh's local-dir
#                     path). Preferred over the repo URL as the probe target when present.
#   --audit-manifest: newline-separated audit-report URLs for THIS target, passed straight to
#                     `fetch-audits.sh --manifest <file> --out <audits-dir>` (that script's own contract:
#                     `#` comments supported, clean [SKIP] with exit 0 when curl/network/pdftotext are down).
#                     Unreadable file -> exit 2.
#   --audits-dir    : where audit text lives (default <DIR>/uniqueness/<slug>/audits). When it already holds
#                     `*.txt` it is read AS-IS and fetch-audits.sh is NOT invoked — the OFFLINE seam for leg (b).
#   --exclusion-out : the produced exclusion file (default <DIR>/uniqueness/<slug>/exclusion.txt). ALWAYS
#                     written, on EVERY verdict including SKIP and the no-signal path, so a caller can rely on
#                     its existence. <DIR> = ${DARK_FACTORY_DIR:-$HOME/.dark-factory};
#                     <slug> = `owner__name` (or the --local-dir basename) via `tr -c 'A-Za-z0-9._-' '_'`.
#   --gh-cmd        : the seam for legs (a)+(c), mirroring apply-audit-density.sh's --probe-cmd idiom:
#                     UQ_ENDPOINT=<REST path> is set in env, then `sh -c "$GH_CMD"` runs and stdout is
#                     captured. Default: `gh api -H "Accept: application/vnd.github+json" "$UQ_ENDPOINT"`.
#                     Endpoints, in this fixed order: `repos/<owner>/<name>/issues?state=all&per_page=100`,
#                     then `repos/<owner>/<name>/security-advisories?per_page=100`. Non-JSON / empty / failing
#                     -> that endpoint contributes nothing, never a crash. `gh` absent and no --gh-cmd -> a
#                     per-leg `[SKIP]` on stderr and the run CONTINUES.
#   --probe-cmd     : the density seam, byte-for-byte the apply-audit-density.sh idiom: PROBE_REPO=<--local-dir,
#                     else https://github.com/<owner>/<name>> is set in env, then `sh -c "$PROBE_CMD"` runs and
#                     its FIRST stdout line is parsed as the probe's JSON verdict for `repo_audit_density` +
#                     `heavily_audited`. Default: `"<here>/audit-history-probe.sh" "$PROBE_REPO"` — invoked
#                     VERBATIM, unmodified.
#   Thresholds (all non-negative integers, else exit 2): --density-skip (40), --density-hot (15),
#   --density-cold (4), --known-hot (20), --known-cold (4), --max-signatures (500).
#
# THREE UNIQUENESS LEGS, each degrading INDEPENDENTLY (a dead leg never blocks the run):
#   (a) known issues + PRs in the target repo — the `issues` endpoint through --gh-cmd. An entry is a candidate
#       when it is SECURITY-RELEVANT: a label matching /security|audit|vuln|bounty|finding|exploit/i, OR a
#       title matching audit-history-probe.sh's FINDING_REF regex (reused VERBATIM), OR a title/body carrying a
#       term from novelty-gate.sh's VULN set (copied VERBATIM). PRs count too — a merged fix is a disclosed issue.
#   (b) prior audit reports for this target — `*.txt` under <audits-dir> (fetched by fetch-audits.sh from
#       --audit-manifest, or pre-populated). Sherlock/Cantina/C4 judge reports are frequently auth-gated or
#       export-only, so this leg NEVER assumes they are reachable: no text -> it degrades silently.
#   (c) public disclosures — the `security-advisories` endpoint (every entry counts; advisories are security by
#       construction) PLUS the --probe-cmd audit-density signal (`-1` = unknown, MUST NOT be read as 0).
#
# SIGNATURE-QUALITY INVARIANT (guards the consumer): a candidate line yielding NO function/CamelCase identifier
# AND no VULN term under novelty-gate.sh's own salient() logic is DROPPED — such a line can only ever produce
# false-KNOWN matches downstream, silently killing real findings. Exact duplicates are deduped (first-seen
# order preserved) and the total is capped at --max-signatures.
#
# VERDICT (first match wins; ALL of it in ONE python3 block — no shell JSON/regex, mirroring
# audit-history-probe.sh). known_total = known + advisories + audit_findings; `sources` = which of
# gh / audits / density actually returned parseable data:
#   1. density >= --density-skip                                          -> SKIP  picked-over
#   2. audited-hot (heavily_audited OR density >= --density-hot)
#      AND disclosed-hot (known_total >= --known-hot)                     -> SKIP  picked-over
#   3. no sources at all                                                  -> FLAG  no-signal
#   4. fewer than 2 sources                                               -> FLAG  partial-signal
#   5. disclosed-hot only                                                 -> FLAG  disclosed
#   6. audited-hot only                                                   -> FLAG  audited
#   7. heavily_audited=false AND density <= --density-cold AND
#      known_total <= --known-cold AND advisories == 0 AND >= 2 sources   -> GO    fresh
#   8. anything else                                                      -> FLAG  partial-signal
# Rule 7's cold cutoff is deliberately the complement of audit-history-probe.sh's own `repo_audit_density >= 5`
# heavy trigger — one scale, two consumers. Rules 3/4/8 are the "missing signals push toward FLAG" clause: a GO
# is STRUCTURALLY IMPOSSIBLE without at least two independent sources of real data, so no-data can never
# produce a silent GO. The gate errs toward FLAG (hold for a human) over a false GO, exactly like novelty-gate.sh.
#
# STDOUT — exactly ONE line, everything else on stderr (the M4 #1900 pin; splits into exactly 4 `|` fields,
# the rationale is sanitized pipe-free):
#   TARGET-UNIQUENESS|<GO|FLAG|SKIP>|<density|-1>|<reason>: density=<d|unknown> heavily_audited=<true|false|
#   unknown> known=<n> advisories=<n> audit_findings=<n> sources=<csv|none>
#
# EXIT CODES: 0 = GO, 1 = FLAG, 3 = SKIP, 2 = bad args. A NON-ZERO EXIT IS A VERDICT, NOT AN ERROR. Bad-args
# band: unknown flag, a value-less flag, a malformed --repo, an unreadable --audit-manifest, a non-integer
# threshold, and giving NONE of --repo/--scope-hint/--local-dir. A --scope-hint that RESOLVES to no repo is
# NOT an arg error — it is a data condition yielding FLAG/no-signal, so the M4 seam never sees exit 2 for an
# ordinary queue row.
#
# DELIBERATE DEVIATION from the sibling [SKIP]+exit-0 idiom: the ONLY whole-run [SKIP] + exit 0 + NO stdout
# line is `python3` missing (the hard dependency, mirroring apply-audit-density.sh). No network / no auth / no
# audit sources is NOT a silent exit 0 — the gate still emits an explicit FLAG verdict carrying whatever
# density it has, because a gate that stays silent on missing data is exactly the false-GO risk this exists to
# remove. A caller that sees NO verdict line MUST treat it as FLAG, never GO.
#
# READ-ONLY: public GETs through the two seams only; never authenticates a write, never posts, never submits.
# Requires: python3. `gh`, `curl`, `git` are optional per-leg (each degrades to a [SKIP] line + FLAG pressure).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "target-uniqueness-gate.sh: $2 requires a value" >&2; exit 2; }; }

REPO_ARG="" ; SCOPE_HINT="" ; LOCAL_DIR="" ; AUDIT_MANIFEST="" ; AUDITS_DIR="" ; EXCL_OUT=""
GH_CMD="" ; GH_CMD_DEFAULT=1 ; PROBE_CMD=""
DENSITY_SKIP="40" ; DENSITY_HOT="15" ; DENSITY_COLD="4" ; KNOWN_HOT="20" ; KNOWN_COLD="4"
MAX_SIGNATURES="500"

# int_or_die: the shared non-negative-integer guard for every threshold knob (apply-audit-density.sh's
# --penalty idiom). A silently-swallowed bad value would yield a confident-looking verdict off wrong thresholds.
int_or_die() {
  case "$2" in
    ''|*[!0-9]*) echo "target-uniqueness-gate.sh: $1 must be a non-negative integer: $2" >&2; exit 2;;
  esac
}

while [ $# -gt 0 ]; do case "$1" in
  --repo)           nv "$#" "$1"; REPO_ARG="$2"; shift 2;;
  --scope-hint)     nv "$#" "$1"; SCOPE_HINT="$2"; shift 2;;
  --local-dir)      nv "$#" "$1"; LOCAL_DIR="$2"; shift 2;;
  --audit-manifest) nv "$#" "$1"; AUDIT_MANIFEST="$2"; shift 2;;
  --audits-dir)     nv "$#" "$1"; AUDITS_DIR="$2"; shift 2;;
  --exclusion-out)  nv "$#" "$1"; EXCL_OUT="$2"; shift 2;;
  --gh-cmd)         nv "$#" "$1"; GH_CMD="$2"; GH_CMD_DEFAULT=0; shift 2;;
  --probe-cmd)      nv "$#" "$1"; PROBE_CMD="$2"; shift 2;;
  --density-skip)   nv "$#" "$1"; int_or_die "$1" "$2"; DENSITY_SKIP="$2"; shift 2;;
  --density-hot)    nv "$#" "$1"; int_or_die "$1" "$2"; DENSITY_HOT="$2"; shift 2;;
  --density-cold)   nv "$#" "$1"; int_or_die "$1" "$2"; DENSITY_COLD="$2"; shift 2;;
  --known-hot)      nv "$#" "$1"; int_or_die "$1" "$2"; KNOWN_HOT="$2"; shift 2;;
  --known-cold)     nv "$#" "$1"; int_or_die "$1" "$2"; KNOWN_COLD="$2"; shift 2;;
  --max-signatures) nv "$#" "$1"; int_or_die "$1" "$2"; MAX_SIGNATURES="$2"; shift 2;;
  -h|--help)        sed -n '2,98p' "$0"; exit 0;;
  *) echo "target-uniqueness-gate.sh: unknown arg: $1" >&2; exit 2;;
esac; done

if [ -z "$REPO_ARG" ] && [ -z "$SCOPE_HINT" ] && [ -z "$LOCAL_DIR" ]; then
  echo "target-uniqueness-gate.sh: one of --repo / --scope-hint / --local-dir is required" >&2; exit 2
fi

# normalize_repo: `owner/name` | `github.com/owner/name` | `https://github.com/owner/name[.git]` -> owner/name.
# Prints the normalized value and returns 0; returns 1 on anything else (the caller decides whether that is
# operator error (--repo -> exit 2) or an ordinary data condition (--scope-hint -> no repo resolved)).
normalize_repo() {
  nr_v="$1"
  nr_v="${nr_v#https://}"; nr_v="${nr_v#http://}"
  nr_v="${nr_v#www.}"
  nr_v="${nr_v#github.com/}"; nr_v="${nr_v#github.com:}"
  nr_v="${nr_v%.git}"
  nr_v="${nr_v%/}"
  case "$nr_v" in
    */*/*) return 1;;
    */*)   ;;
    *)     return 1;;
  esac
  case "$nr_v" in
    *[!A-Za-z0-9._/-]*) return 1;;
  esac
  [ -n "${nr_v%%/*}" ] && [ -n "${nr_v##*/}" ] || return 1
  printf '%s' "$nr_v"
}

REPO=""
if [ -n "$REPO_ARG" ]; then
  REPO="$(normalize_repo "$REPO_ARG")" || {
    echo "target-uniqueness-gate.sh: --repo must be owner/name or a github repo URL: $REPO_ARG" >&2; exit 2
  }
elif [ -n "$SCOPE_HINT" ]; then
  # The same `repo:` extraction apply-audit-density.sh uses over run-immunefi-intake.sh's scope_hint shape.
  hint_repo="$(printf '%s' "$SCOPE_HINT" | grep -oE 'repo:[^ ]+' | head -1)"
  hint_repo="${hint_repo#repo:}"
  if [ -n "$hint_repo" ] && [ "$hint_repo" != "-" ]; then
    # A queue row is DATA, not operator input: an unnormalizable value resolves to no repo, never exit 2.
    REPO="$(normalize_repo "$hint_repo")" || REPO=""
  fi
fi

# <slug> = owner__name (or the --local-dir basename, else "unknown"), sanitized for the filesystem.
if [ -n "$REPO" ]; then
  SLUG="$(printf '%s__%s' "${REPO%%/*}" "${REPO##*/}" | tr -c 'A-Za-z0-9._-' '_')"
elif [ -n "$LOCAL_DIR" ]; then
  ld_base="${LOCAL_DIR%/}"; ld_base="${ld_base##*/}"
  SLUG="$(printf '%s' "$ld_base" | tr -c 'A-Za-z0-9._-' '_')"
  [ -n "$SLUG" ] || SLUG="local"
else
  SLUG="unknown"
fi

[ -n "$AUDITS_DIR" ] || AUDITS_DIR="$DIR/uniqueness/$SLUG/audits"
[ -n "$EXCL_OUT" ]   || EXCL_OUT="$DIR/uniqueness/$SLUG/exclusion.txt"

if [ -n "$AUDIT_MANIFEST" ] && [ ! -r "$AUDIT_MANIFEST" ]; then
  echo "target-uniqueness-gate.sh: --audit-manifest not readable: $AUDIT_MANIFEST" >&2; exit 2
fi

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/target-uniqueness-gate.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT
ISSUES_FILE="$TMPD/issues.json"
ADVISORIES_FILE="$TMPD/advisories.json"
DENSITY_FILE="$TMPD/density.json"
VERDICT_FILE="$TMPD/verdict"
: > "$ISSUES_FILE"; : > "$ADVISORIES_FILE"; : > "$DENSITY_FILE"; : > "$VERDICT_FILE"

# --- legs (a) + (c): the gh seam ---------------------------------------------------------------------------
if [ "$GH_CMD_DEFAULT" -eq 1 ]; then
  if command -v gh >/dev/null 2>&1; then
    # Escaped-double-quote form (the apply-audit-density.sh --probe-cmd default idiom): $UQ_ENDPOINT is
    # deliberately left for the inner `sh -c` to expand, not for this shell.
    GH_CMD="gh api -H \"Accept: application/vnd.github+json\" \"\$UQ_ENDPOINT\""
  else
    echo "[SKIP] gh not installed — known-issue/advisory legs unavailable" >&2
    GH_CMD=""
  fi
fi

# run_gh: $1 = the REST path -> prints the seam's raw stdout (JSON, or nothing on any failure).
run_gh() { UQ_ENDPOINT="$1" sh -c "$GH_CMD" 2>/dev/null || :; }

if [ -n "$GH_CMD" ] && [ -n "$REPO" ]; then
  run_gh "repos/$REPO/issues?state=all&per_page=100" > "$ISSUES_FILE" 2>/dev/null || :
  run_gh "repos/$REPO/security-advisories?per_page=100" > "$ADVISORIES_FILE" 2>/dev/null || :
elif [ -z "$REPO" ]; then
  echo "[SKIP] no resolvable repo — known-issue/advisory legs unavailable" >&2
fi

# --- leg (b): prior audit reports --------------------------------------------------------------------------
if [ -n "$AUDIT_MANIFEST" ]; then
  if [ -x "$HERE/fetch-audits.sh" ]; then
    mkdir -p "$AUDITS_DIR" 2>/dev/null || true
    # fetch-audits.sh owns its own [SKIP] contract (no curl / no network / all URLs failed -> exit 0, no docs).
    "$HERE/fetch-audits.sh" --manifest "$AUDIT_MANIFEST" --out "$AUDITS_DIR" >/dev/null 2>&1 || :
  else
    echo "[SKIP] fetch-audits.sh not executable — audit-report leg unavailable" >&2
  fi
fi

# --- leg (c): the density seam -----------------------------------------------------------------------------
[ -n "$PROBE_CMD" ] || PROBE_CMD="\"$HERE/audit-history-probe.sh\" \"\$PROBE_REPO\""
PROBE_TARGET=""
if [ -n "$LOCAL_DIR" ]; then
  PROBE_TARGET="$LOCAL_DIR"
elif [ -n "$REPO" ]; then
  PROBE_TARGET="https://github.com/$REPO"
fi
if [ -n "$PROBE_TARGET" ]; then
  PROBE_REPO="$PROBE_TARGET" sh -c "$PROBE_CMD" > "$DENSITY_FILE" 2>/dev/null || :
else
  echo "[SKIP] no repo and no --local-dir — density leg unavailable" >&2
fi

# --- verdict + exclusion-file production (one python3 block; .get() with total fallbacks everywhere) --------
UQ_REPO="$REPO" \
UQ_ISSUES_FILE="$ISSUES_FILE" \
UQ_ADVISORIES_FILE="$ADVISORIES_FILE" \
UQ_DENSITY_FILE="$DENSITY_FILE" \
UQ_AUDITS_DIR="$AUDITS_DIR" \
UQ_EXCL_OUT="$EXCL_OUT" \
UQ_VERDICT_FILE="$VERDICT_FILE" \
UQ_DENSITY_SKIP="$DENSITY_SKIP" \
UQ_DENSITY_HOT="$DENSITY_HOT" \
UQ_DENSITY_COLD="$DENSITY_COLD" \
UQ_KNOWN_HOT="$KNOWN_HOT" \
UQ_KNOWN_COLD="$KNOWN_COLD" \
UQ_MAX_SIGNATURES="$MAX_SIGNATURES" \
python3 - <<'PY'
import datetime
import glob
import json
import os
import re
import sys

# VULN copied VERBATIM from novelty-gate.sh (the consumer) — the producer must speak the consumer's dialect.
VULN = {"reentrancy", "reentrant", "rounding", "overflow", "underflow", "oracle", "stale", "staleness",
        "deviation", "slippage", "frontrun", "frontrunning", "sandwich", "donation", "inflation", "solvency",
        "liquidation", "liquidate", "cursor", "drift", "band", "clip", "anchor", "velocity", "fee", "griefing",
        "dos", "precision", "sequencer", "callback", "allowance", "approval", "share", "shares", "bindebt",
        "baddebt", "insolvency"}

# FINDING_REF reused VERBATIM from audit-history-probe.sh.
FINDING_REF = re.compile(r"(\b[CHM]-0?\d{1,2}\b|\breport \d{4,}\b)", re.I)
SEC_LABEL = re.compile(r"security|audit|vuln|bounty|finding|exploit", re.I)
AUDIT_FINDING_LINE = re.compile(r"^\s*(?:\[?[CHM]-0?\d{1,2}\]?\b|(?:Issue|Finding)\s+\d+\b|\d+\.\d+\s+\S)", re.I)
HEADING = re.compile(r"^\s*#{1,6}\s+(.+?)\s*$")


def envs(key, default=""):
    return os.environ.get(key, default)


def envi(key, default):
    try:
        return int(os.environ.get(key, ""))
    except (TypeError, ValueError):
        return default


def salient(text):
    """novelty-gate.sh's own salient() logic, so the drop rule speaks the consumer's dialect exactly."""
    funcs = set(m.group(1).lower() for m in re.finditer(r'\b([A-Za-z_][A-Za-z0-9_]{2,})\s*\(', text))
    camel = set(m.group(0).lower() for m in re.finditer(r'\b[A-Za-z][a-z0-9]*(?:[A-Z][A-Za-z0-9]*)+\b', text))
    vk = set(w for w in re.findall(r'[a-z]+', text.lower()) if w in VULN)
    return (funcs | camel), vk


def has_vuln_term(text):
    return any(w in VULN for w in re.findall(r'[a-z]+', str(text or "").lower()))


def squeeze(text):
    return re.sub(r'\s+', ' ', str(text or "").replace("|", "/")).strip()


def signature(title, body):
    t = squeeze(title)
    b = squeeze(body)[:300]
    line = (t + " ; " + b) if (t and b) else (t or b)
    return squeeze(line)[:400]


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            return fh.read()
    except Exception:
        return ""


def load_json(path):
    raw = read_text(path).strip()
    if not raw:
        return None
    try:
        return json.loads(raw)
    except Exception:
        return None


def label_names(entry):
    out = []
    for lab in (entry.get("labels") or []):
        if isinstance(lab, dict):
            out.append(str(lab.get("name") or ""))
        else:
            out.append(str(lab))
    return " ".join(out)


repo = envs("UQ_REPO")
audits_dir = envs("UQ_AUDITS_DIR")
excl_out = envs("UQ_EXCL_OUT")
max_signatures = max(0, envi("UQ_MAX_SIGNATURES", 500))

seen = set()


def accept(line, bucket):
    """Signature-quality invariant + dedup + cap. Returns True when the line lands in the exclusion set."""
    if not line or len(seen) >= max_signatures:
        return False
    ident, vk = salient(line)
    if not ident and not vk:
        return False          # no identifier AND no vuln term -> can only ever produce false-KNOWN downstream
    if line in seen:
        return False
    seen.add(line)
    bucket.append(line)
    return True


# --- leg (a): known issues + PRs ---------------------------------------------------------------------------
issue_sigs = []
known_issues = 0
issues = load_json(envs("UQ_ISSUES_FILE"))
gh_ok = isinstance(issues, list)
if isinstance(issues, list):
    for entry in issues:
        if not isinstance(entry, dict):
            continue
        title = str(entry.get("title") or "")
        body = str(entry.get("body") or "")
        labels = label_names(entry)
        relevant = (bool(SEC_LABEL.search(labels)) or bool(FINDING_REF.search(title))
                    or has_vuln_term(title) or has_vuln_term(body[:2000]))
        if not relevant:
            continue
        known_issues += 1
        accept(signature(title, body), issue_sigs)

# --- leg (c1): security advisories (every entry counts — security by construction) --------------------------
adv_sigs = []
advisories = 0
adv = load_json(envs("UQ_ADVISORIES_FILE"))
if isinstance(adv, list):
    gh_ok = True
    for entry in adv:
        if not isinstance(entry, dict):
            continue
        advisories += 1
        accept(signature(entry.get("summary") or entry.get("title") or "",
                         entry.get("description") or entry.get("body") or ""), adv_sigs)

# --- leg (b): prior audit reports --------------------------------------------------------------------------
audit_sigs = []
audit_findings = 0
audits_ok = False
if audits_dir and os.path.isdir(audits_dir):
    for path in sorted(glob.glob(os.path.join(audits_dir, "*.txt"))):
        text = read_text(path)
        if not text:
            continue
        audits_ok = True
        for raw in text.splitlines():
            line = raw.rstrip()
            candidate = ""
            if AUDIT_FINDING_LINE.match(line):
                candidate = line
            else:
                m = HEADING.match(line)
                if m and (FINDING_REF.search(m.group(1)) or has_vuln_term(m.group(1))):
                    candidate = m.group(1)
            if not candidate:
                continue
            audit_findings += 1
            accept(squeeze(candidate)[:400], audit_sigs)

# --- leg (c2): audit density -------------------------------------------------------------------------------
density = -1
heavily = "unknown"
density_ok = False
draw = read_text(envs("UQ_DENSITY_FILE")).strip()
if draw:
    first = draw.splitlines()[0]
    try:
        dobj = json.loads(first)
    except Exception:
        dobj = None
    if isinstance(dobj, dict) and "repo_audit_density" in dobj:
        try:
            density = int(dobj.get("repo_audit_density"))
        except (TypeError, ValueError):
            density = -1
        if density < 0:
            density = -1
        else:
            density_ok = True
        hv = dobj.get("heavily_audited")
        heavily = "true" if hv is True else ("false" if hv is False else "unknown")

# --- verdict -----------------------------------------------------------------------------------------------
sources = []
if gh_ok:
    sources.append("gh")
if audits_ok:
    sources.append("audits")
if density_ok:
    sources.append("density")

known_total = known_issues + advisories + audit_findings
density_skip = envi("UQ_DENSITY_SKIP", 40)
density_hot = envi("UQ_DENSITY_HOT", 15)
density_cold = envi("UQ_DENSITY_COLD", 4)
known_hot = envi("UQ_KNOWN_HOT", 20)
known_cold = envi("UQ_KNOWN_COLD", 4)

audited_hot = (heavily == "true") or (density >= 0 and density >= density_hot)
disclosed_hot = known_total >= known_hot

if density >= 0 and density >= density_skip:
    verdict, reason = "SKIP", "picked-over"
elif audited_hot and disclosed_hot:
    verdict, reason = "SKIP", "picked-over"
elif not sources:
    verdict, reason = "FLAG", "no-signal"
elif len(sources) < 2:
    verdict, reason = "FLAG", "partial-signal"
elif disclosed_hot:
    verdict, reason = "FLAG", "disclosed"
elif audited_hot:
    verdict, reason = "FLAG", "audited"
elif (heavily == "false" and 0 <= density <= density_cold and known_total <= known_cold
      and advisories == 0 and len(sources) >= 2):
    verdict, reason = "GO", "fresh"
else:
    verdict, reason = "FLAG", "partial-signal"

# --- the exclusion file: ALWAYS written, ALWAYS a valid `novelty-gate.sh --exclusion` input ----------------
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
lines = [
    "# target-uniqueness-gate.sh — known-issue exclusion set for %s" % (repo or "-"),
    "# generated %s · verdict=%s · sources=%s" % (stamp, verdict, ",".join(sources) or "none"),
]
if issue_sigs:
    lines.append("# --- known issues + PRs (gh: repos/%s/issues) ---" % (repo or "-"))
    lines.extend(issue_sigs)
if adv_sigs:
    lines.append("# --- security advisories (gh: repos/%s/security-advisories) ---" % (repo or "-"))
    lines.extend(adv_sigs)
if audit_sigs:
    lines.append("# --- prior audit findings (%s) ---" % (audits_dir or "-"))
    lines.extend(audit_sigs)

parent = os.path.dirname(excl_out)
if parent:
    try:
        os.makedirs(parent, exist_ok=True)
    except Exception:
        pass
try:
    with open(excl_out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    excl_written = True
except Exception as exc:                                   # never crash a verdict on a write failure
    excl_written = False
    print("target-uniqueness-gate: could not write %s (%s)" % (excl_out, exc), file=sys.stderr)

try:
    with open(envs("UQ_VERDICT_FILE"), "w", encoding="utf-8") as fh:
        fh.write(verdict + "\n")
except Exception:
    pass

dstr = str(density) if density >= 0 else "unknown"
rationale = squeeze("%s: density=%s heavily_audited=%s known=%d advisories=%d audit_findings=%d sources=%s"
                    % (reason, dstr, heavily, known_issues, advisories, audit_findings,
                       ",".join(sources) or "none"))
print("TARGET-UNIQUENESS|%s|%d|%s" % (verdict, density, rationale))
print("target-uniqueness-gate: %s — %s -> exclusion %s (%d signature(s)%s)"
      % (verdict, rationale, excl_out, len(seen), "" if excl_written else ", NOT WRITTEN"), file=sys.stderr)
PY
rc=$?

VERDICT="$(head -1 "$VERDICT_FILE" 2>/dev/null || true)"
if [ "$rc" -ne 0 ] || [ -z "$VERDICT" ]; then
  # Err toward FLAG: a caller must never read a computation failure as GO (the M4 fail-safe, stated up top).
  echo "TARGET-UNIQUENESS|FLAG|-1|internal-error: verdict computation failed"
  echo "target-uniqueness-gate: FLAG — verdict computation failed (rc=$rc)" >&2
  exit 1
fi

case "$VERDICT" in
  GO)   exit 0;;
  SKIP) exit 3;;
  *)    exit 1;;
esac
