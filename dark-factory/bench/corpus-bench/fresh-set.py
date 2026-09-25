#!/usr/bin/env python3
# fresh-set.py — the engine behind fresh-set.sh (#2263): builds a FRESH held-out contest set for the corpus bench
# and probes the hunter model for training-memorised findings. fresh-set.sh parses and validates the CLI, refuses
# an unsafe work dir and drives --self-test; everything else runs here, in ONE process, so the repo text used for
# the contamination scan is loaded once rather than once per candidate. python3 stdlib only (urllib, subprocess);
# no argparse (the lib/ manual-flag idiom, see lib/project_roots.py parse_flags).
#
# Subcommands (flags are validated by fresh-set.sh first; this file re-checks what it relies on):
#   build             discover -> exclude -> clone judging + GT -> clone code + presence check -> source counts +
#                     project roots + location GT -> contamination -> [memorisation probe] -> report.
#   reserve           read the report and write the sealed <work>/RESERVED.tsv manifest (no network).
#   probe             the training-memorisation probe on ONE contest dir (a fresh-set work dir row OR any
#                     already-frozen <work>/<id>/ holding truth.tsv): ask the hunter model, with NO code and NO
#                     ground truth in the prompt, which findings it remembers; score the reply offline.
#   selftest-listing  offline unit check of the GitHub listing client (stub fetcher; pagination, rate limit,
#                     token header, page cache, network trip-wire).
#   selftest-probe    offline unit check of the probe matcher, the leak guard and the backend argv.
#
# Work-dir layout = fetch-corpus.sh / run-corpus-bench.sh's `<work>/<id>/{code,judging,truth.tsv}`, plus:
#   <work>/candidates.tsv          every discovered candidate (id slug date ended status code_repo judging_repo)
#   <work>/fresh-set-report.tsv    the per-contest report (counts only; never a title or a signature)
#   <work>/RESERVED.tsv            the sealed manifest, corpus.tsv row format (written by `reserve` only)
#   <work>/.listing/<org>/page-<n>.json   the raw GitHub listing pages (re-used unless --refresh-listing)
#   <work>/<id>/contest.tsv        contest metadata (slug, repos, dates, platform, protocol name)
#   <work>/<id>/contamination.tsv  every contamination hit: needle kind file line prompt_visible
#   <work>/<id>/probe/             prompt.txt + reply.txt (VERBATIM), run.tsv, probe.tsv, summary.tsv
#
# Exit: 0 ok ; 1 a selftest-* check failed ; 2 usage error ; 3 unreadable input / missing prerequisite / a
#       failed probe backend (never scored) ;
#       4 reserve or probe refused ; 5 FRESH_SET_OFFLINE=1 and the network was reached (the self-test trip-wire).
import bisect
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
DF = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(DF, "lib"))
import project_roots  # noqa: E402  (the #2255 single source of truth for project roots)

EXTRACT_GT = os.path.join(HERE, "extract-gt.sh")
SANDBOX = os.path.join(DF, "lib", "claude-sandboxed.sh")
TRUST = os.path.join(DF, "lib", "ensure-claude-trust.sh")

RARE_MAX = 2                    # a GT row is RARE when its found-by count is 1..RARE_MAX (the bench's rare tier)
MEMORIZED_MIN_RARE_YES = 1      # a contest is MEMORIZED once this many RARE rows are recalled_from_memory=yes
CUED_BATCH = 20                 # cued probe: GT locations per prompt (plus one decoy)
CUED_RARE_RATE = 0.25           # cued probe: MEMORIZED when the rare cued_rate is ABOVE this (--memorized-rare-rate)
PER_PAGE = 100
MAX_PAGES = 20                  # 2000 repos; the org needs ~5 pages today
NET_TIMEOUT_S = 30
CLONE_TIMEOUT_S = 600
SCAN_MAX_BYTES = 5 * 1024 * 1024
PROBE_IDLE_MS = 12000           # the hunt's llm.flat_cyborg.idle_ms (run-discovery.sh)
PROBE_TIMEOUT_MS = int(os.environ.get("FRESH_SET_PROBE_TIMEOUT_MS", "300000"))
COPIED_MARKER = ".fresh-set-copied"
DATE_PREFIX_RE = re.compile(r"^(\d{4})-(\d{2})-")
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

REPORT_COLS = ("id", "slug", "date", "ended", "status", "reason", "gt", "rare", "rare_loc", "rarity_unknown",
               "gt_shape", "sol_files", "sol_lines", "roots", "project_subdir", "code_present", "contam_strong",
               "contam_weak", "contam_pv", "ledger", "memo", "memo_rare", "memo_cued", "code_sha", "judging_sha")

# Weak-needle stopwords: name tokens so generic that a hit on them says nothing about THIS contest. Documented in
# the corpus-bench README ("Fresh held-out set builder"); extend here when a real run shows a new false positive.
WEAK_STOP = frozenset("""
audit audits contest contests judging protocol protocols finance financial network networks labs core dex token
tokens vault vaults exchange system systems contracts contract smart update upgrade upgrades review part phase
round details lending lend bridge oracle oracles staking stake swap swaps yield stable stables pool pools market
markets money chain chains cross omni flexible locker defi layer module modules manager router strategy strategies
fund funds capital asset assets perp perps perpetual perpetuals options option margin credit loan loans
main mainnet testnet mitigation fixes with from into
""".split()) | frozenset("v%d" % n for n in range(1, 10))

# #2231 prompt-visible set, MIRRORED from tools/colony-lint.sh (`df_gt_files`, the "corpus ground truth must NEVER
# be prompt-visible" block). Two copies can drift: when you touch one, update the other (both carry this note).
def prompt_visible(rel):
    rel = rel.replace(os.sep, "/")
    return (rel.startswith("dark-factory/auditor/")
            or rel.endswith(".ag")
            or rel == "dark-factory/gen-briefs.sh"
            or re.match(r"^dark-factory/lib/[^/]*prompt[^/]*$", rel) is not None)


# The builder's own files never count as contamination (they name the fixture contests on purpose).
DEFAULT_SCAN_EXCLUDES = ("dark-factory/bench/corpus-bench/fresh-set.sh",
                         "dark-factory/bench/corpus-bench/fresh-set.py",
                         "dark-factory/bench/corpus-bench/fixtures/fresh-set/")


class NetworkTripwire(Exception):
    """Raised instead of any network access when FRESH_SET_OFFLINE=1 (the self-test sets it)."""


class ProbeRefused(Exception):
    """The probe prompt would carry code or ground truth: nothing is sent to the model."""


class ProbeFailed(Exception):
    """The backend returned no usable reply. Never scored: an empty reply would read as `not-memorized`."""


def die(rc, msg):
    sys.stderr.write("fresh-set.py: " + msg + "\n")
    sys.exit(rc)


def warn(msg):
    sys.stderr.write("fresh-set.py: WARNING " + msg + "\n")


def note(msg):
    sys.stderr.write("fresh-set.py: " + msg + "\n")


def offline():
    return os.environ.get("FRESH_SET_OFFLINE") == "1"


def parse_flags(argv, valued, multi, boolean):
    """Manual flag walk. Unknown flags and missing values are usage errors, never silent."""
    out = {m: [] for m in multi}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in valued or a in multi:
            if i + 1 >= len(argv):
                die(2, a + " requires a value")
            if a in multi:
                out[a].append(argv[i + 1])
            else:
                out[a] = argv[i + 1]
            i += 2
        elif a in boolean:
            out[a] = True
            i += 1
        else:
            die(2, "unknown arg: " + a)
    return out


def write_atomic(path, text):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def read_tsv_lines(path):
    """Non-empty, non-`#` lines of a TAB file, split on TAB."""
    rows = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            rows.append(line.split("\t"))
    return rows


# ---- network edge (the ONLY two functions that can reach the network) -----------------------------------------
def http_get(url, headers, timeout=NET_TIMEOUT_S):
    """(status, headers, body). An HTTP error is a RESULT, not an exception; a transport error raises OSError."""
    if offline():
        raise NetworkTripwire("HTTP GET " + url)
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers.items()), resp.read()
    except urllib.error.HTTPError as e:
        body = b""
        try:
            body = e.read()
        except OSError:
            pass
        return e.code, dict((e.headers or {}).items()), body


def git_net(args, timeout=CLONE_TIMEOUT_S):
    """A network git command (clone / submodule update). Never prompts for credentials."""
    if offline():
        raise NetworkTripwire("git " + " ".join(args[:3]))
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    try:
        p = subprocess.run(["git"] + args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "timeout after %ds" % timeout
    except OSError as e:
        return 127, str(e)
    return p.returncode, p.stderr.decode("utf-8", "replace").strip()


def git_local(args):
    try:
        p = subprocess.run(["git"] + args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return None
    if p.returncode != 0:
        return None
    return p.stdout.decode("utf-8", "replace")


# ---- (b) listing I/O -------------------------------------------------------------------------------------------
def api_headers(env):
    h = {"Accept": "application/vnd.github+json", "User-Agent": "dark-factory-fresh-set",
         "X-GitHub-Api-Version": "2022-11-28"}
    tok = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN")
    if tok:
        h["Authorization"] = "Bearer " + tok    # never printed, never written
    return h


def _iso(epoch):
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(epoch)))
    except (TypeError, ValueError):
        return "unknown"


def fetch_listing(org, cache_dir, refresh, getter, env):
    """All public repos of <org>, newest first. Returns (repos, state) with state `complete` or
    `partial (<reason>)`. Every failure STOPS pagination and keeps the pages already read (c)."""
    repos = []
    for page in range(1, MAX_PAGES + 1):
        cache = os.path.join(cache_dir, "page-%d.json" % page) if cache_dir else None
        data = None
        if cache and not refresh and os.path.isfile(cache):
            try:
                with open(cache, encoding="utf-8") as fh:
                    data = json.load(fh)
            except (OSError, ValueError):
                data = None
            if not isinstance(data, list):
                data = None
        if data is None:
            url = ("https://api.github.com/orgs/%s/repos?type=public&sort=created&direction=desc&per_page=%d"
                   "&page=%d" % (org, PER_PAGE, page))
            try:
                status, hdrs, body = getter(url, api_headers(env))
            except NetworkTripwire:
                raise
            except (OSError, ValueError) as e:
                return repos, "partial (network-error: %s)" % type(e).__name__
            if status != 200:
                hl = {str(k).lower(): str(v) for k, v in (hdrs or {}).items()}
                if status in (403, 429) and hl.get("x-ratelimit-remaining") == "0":
                    return repos, "partial (rate-limited; resets %s)" % _iso(hl.get("x-ratelimit-reset"))
                return repos, "partial (http-%s)" % status
            try:
                data = json.loads(body.decode("utf-8"))
            except (ValueError, AttributeError):
                return repos, "partial (bad-json)"
            if not isinstance(data, list):
                return repos, "partial (bad-json)"
            if cache:
                write_atomic(cache, json.dumps(data))
        repos.extend(data)
        if len(data) < PER_PAGE:
            return repos, "complete"
    return repos, "partial (page-cap)"


# ---- (a) sources -----------------------------------------------------------------------------------------------
def slug_date(slug):
    m = DATE_PREFIX_RE.match(slug)
    return "%s-%s" % (m.group(1), m.group(2)) if m else ""


def pair_listing(repos, org):
    """Keep only `<slug>` + `<slug>-judging` pairs of <org>. Unpaired repos (no judging sibling yet, a tool repo,
    a fork) are ignored — a contest without a public judging repo has no ground truth."""
    by_name = {}
    for r in repos:
        if not isinstance(r, dict) or r.get("fork") or r.get("private"):
            continue
        name = r.get("name")
        owner = (r.get("owner") or {}).get("login") if isinstance(r.get("owner"), dict) else None
        if not isinstance(name, str) or not name:
            continue
        if owner and owner.lower() != org.lower():
            continue
        by_name[name.lower()] = r
    out = []
    for lname in sorted(by_name):
        if lname.endswith("-judging"):
            continue
        j = by_name.get(lname + "-judging")
        if not j:
            continue
        slug = by_name[lname]["name"]
        date = slug_date(slug) or str(by_name[lname].get("created_at") or "")[:7]
        ended = str(j.get("created_at") or "")[:10] or "-"
        out.append({"slug": slug, "date": date or "-", "ended": ended, "platform": "Sherlock",
                    "code_repo": "%s/%s" % (org, slug), "judging_repo": "%s/%s" % (org, j["name"])})
    return out


def source_sherlock_gh(flags, work, env):
    org = flags.get("--org", "sherlock-audit")
    if flags["--listing-from"]:
        repos = []
        for path in flags["--listing-from"]:
            try:
                with open(path, encoding="utf-8") as fh:
                    data = json.load(fh)
            except (OSError, ValueError) as e:
                die(3, "--listing-from unreadable: %s (%s)" % (path, e))
            if not isinstance(data, list):
                die(3, "--listing-from is not a JSON array: " + path)
            repos.extend(data)
        return pair_listing(repos, org), "offline"
    cache_dir = os.path.join(work, ".listing", org)
    repos, state = fetch_listing(org, cache_dir, bool(flags.get("--refresh-listing")), http_get, env)
    if state != "complete":
        warn("discovery=%s — continuing on the %d repo(s) already read" % (state, len(repos)))
    return pair_listing(repos, org), state


def source_candidates_file(flags, work, env):
    """A hand list: `slug  code_repo  judging_repo  [platform]` per line — any platform that publishes GitHub
    judging repos can be added this way without a code change."""
    path = flags.get("--candidates-from")
    if not path:
        die(2, "--source candidates-file requires --candidates-from <tsv>")
    if not os.path.isfile(path):
        die(3, "--candidates-from not found: " + path)
    out = []
    for f in read_tsv_lines(path):
        f = [x for x in re.split(r"\s+", "\t".join(f).strip()) if x]
        if len(f) < 3:
            warn("candidates-file line skipped (want slug code_repo judging_repo): " + " ".join(f))
            continue
        out.append({"slug": f[0], "date": slug_date(f[0]) or "-", "ended": "-",
                    "platform": f[3] if len(f) > 3 else "Sherlock", "code_repo": f[1], "judging_repo": f[2]})
    return out, "offline"


SOURCES = {"sherlock-gh": source_sherlock_gh, "candidates-file": source_candidates_file}


# ---- (d) exclusion ---------------------------------------------------------------------------------------------
def load_corpus(path):
    ids, repos = set(), set()
    if path and os.path.isfile(path):
        for f in read_tsv_lines(path):
            if f and f[0].strip():
                ids.add(f[0].strip().lower())
            for col in f[1:3]:
                if col.strip():
                    repos.add(col.strip().lower())
    return ids, repos


def load_exclude_fields(paths):
    fields = set()
    for p in paths:
        if not os.path.isfile(p):
            die(3, "--exclude file not found: " + p)
        with open(p, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.lstrip().startswith("#"):
                    continue
                for tok in line.split():
                    fields.add(tok.lower())
    return fields


def assign_ids(cands, corpus_ids):
    bases = {}
    for c in cands:
        base = DATE_PREFIX_RE.sub("", c["slug"]) or c["slug"]
        c["_base"] = base
        bases[base.lower()] = bases.get(base.lower(), 0) + 1
    for c in cands:
        b = c["_base"]
        c["id"] = c["slug"] if (bases[b.lower()] > 1 or b.lower() in corpus_ids) else b


# ---- repo fetch (clone or local copy) --------------------------------------------------------------------------
def gitmodule_paths(root):
    path = os.path.join(root, ".gitmodules")
    out = []
    if not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = re.match(r"^\s*path\s*=\s*(.+?)\s*$", line)
            if m:
                p = m.group(1).strip().strip("/")
                if p and not any(seg in project_roots.PRUNE_DIRS for seg in p.split("/")):
                    out.append(p)
    return out


def fetch_repo(full, dest, repos_from, init_submodules):
    """(ok, sha, err). Re-uses a present clone or copy, like fetch-corpus.sh."""
    if os.path.isdir(os.path.join(dest, ".git")):
        sha = (git_local(["-C", dest, "rev-parse", "HEAD"]) or "").strip() or "unknown"
        return True, sha, ""
    if os.path.isfile(os.path.join(dest, COPIED_MARKER)):
        return True, "local", ""
    if repos_from:
        src = os.path.join(repos_from, *full.split("/"))
        if os.path.isdir(src):
            shutil.rmtree(dest, ignore_errors=True)
            shutil.copytree(src, dest, ignore=shutil.ignore_patterns(".git"))
            with open(os.path.join(dest, COPIED_MARKER), "w", encoding="utf-8") as fh:
                fh.write("copied by fresh-set.py from --repos-from; no .git, submodules not initialised\n")
            return True, "local", ""
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    rc, err = git_net(["clone", "--depth", "1", "--quiet", "https://github.com/%s.git" % full, dest])
    if rc != 0:
        shutil.rmtree(dest, ignore_errors=True)
        return False, "-", err.splitlines()[-1] if err else "exit %d" % rc
    if init_submodules:
        for p in gitmodule_paths(dest):
            rc, err = git_net(["-C", dest, "submodule", "update", "--init", "--depth", "1", "--", p])
            if rc != 0:
                warn("submodule %s of %s not initialised (%s) — tolerated" % (p, full, err[-200:] or rc))
    sha = (git_local(["-C", dest, "rev-parse", "HEAD"]) or "").strip() or "unknown"
    return True, sha, ""


# ---- (e) GT ----------------------------------------------------------------------------------------------------
def extract_gt(readme, out, code=None):
    cmd = ["bash", EXTRACT_GT, readme, out] + (["--code", code] if code else [])
    p = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    return p.returncode


def read_truth(path):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            f = line.split("\t")
            while len(f) < 6:
                f.append("")
            try:
                rarity = int(f[2])
            except ValueError:
                rarity = 0
            rows.append({"sev_id": f[0], "severity": f[1], "rarity": rarity, "title": f[3], "signature": f[4],
                         "locations": f[5]})
    return rows


def is_rare(row):
    return 1 <= row["rarity"] <= RARE_MAX


# ---- (f) code presence -----------------------------------------------------------------------------------------
DOC_RE = re.compile(r"(^readme|^license|^licence|^copying|\.md$|\.txt$|\.png$|\.jpe?g$|\.gif$|\.svg$|\.webp$|"
                    r"^\.gitignore$|^\.gitattributes$|^\.gitmodules$)", re.I)


def repo_files(root):
    if os.path.isdir(os.path.join(root, ".git")):
        out = git_local(["-C", root, "ls-files"])
        if out is not None:
            return [l for l in out.split("\n") if l]
    files = []
    for cur, dirs, fnames in os.walk(root):
        dirs[:] = [d for d in dirs if d != ".git"]
        for f in fnames:
            if f == COPIED_MARKER:
                continue
            files.append(os.path.relpath(os.path.join(cur, f), root).replace(os.sep, "/"))
    return files


def sol_stats(root):
    files = lines = 0
    for cur, dirs, fnames in os.walk(root):
        dirs[:] = sorted(d for d in dirs
                         if d not in project_roots.PRUNE_DIRS and d not in project_roots.EXCLUDED_SEGMENTS)
        for f in fnames:
            if f.endswith(".sol") and not f.endswith(".t.sol") and not f.endswith(".s.sol"):
                files += 1
                try:
                    with open(os.path.join(cur, f), "rb") as fh:
                        lines += fh.read().count(b"\n")
                except OSError:
                    pass
    return files, lines


def code_presence(root, sol_files):
    for p in gitmodule_paths(root):
        full = os.path.join(root, p)
        if not os.path.isdir(full) or not os.listdir(full):
            return "empty-submodule"
    files = repo_files(root)
    if all(DOC_RE.search(os.path.basename(f)) for f in files):
        return "readme-only"
    if sol_files == 0:
        return "no-solidity"
    return "ok"


def readme_h1(root):
    """The code README's first H1, minus a trailing `(audit) contest details` — a protocol NAME, never code."""
    path = os.path.join(root, "README.md")
    if not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = re.match(r"^#\s+(.+?)\s*#*\s*$", line)
            if m:
                h = re.sub(r"\s*[-:|]?\s*(audit\s+)?contest\s+details\s*$", "", m.group(1), flags=re.I).strip()
                return re.sub(r"\s+", " ", h)
    return ""


# ---- (h) contamination -----------------------------------------------------------------------------------------
def scan_files(scan_root):
    real = os.path.realpath(scan_root)
    top = (git_local(["-C", scan_root, "rev-parse", "--show-toplevel"]) or "").strip()
    if top and os.path.realpath(top) == real:
        out = git_local(["-C", scan_root, "ls-files"]) or ""
        return sorted(l for l in out.split("\n") if l)
    files = []
    for cur, dirs, fnames in os.walk(scan_root):
        dirs[:] = [d for d in dirs if d != ".git"]
        for f in fnames:
            files.append(os.path.relpath(os.path.join(cur, f), scan_root).replace(os.sep, "/"))
    return sorted(files)


def load_scan_text(scan_root, excludes):
    texts = []
    prefixes = [e.strip("/") for e in excludes if e.strip("/")]
    for rel in scan_files(scan_root):
        if any(rel == e or rel.startswith(e + "/") for e in prefixes):
            continue
        path = os.path.join(scan_root, rel)
        try:
            if not os.path.isfile(path) or os.path.getsize(path) > SCAN_MAX_BYTES:
                continue
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            continue
        if b"\0" in data[:8192]:
            continue
        # Lower-cased ONCE here: every needle is lower-case, so the per-candidate scan is a case-sensitive regex
        # behind a C-speed substring pre-filter instead of a case-insensitive regex over the whole repo text.
        texts.append((rel, data.decode("utf-8", "replace").lower()))
    return texts


def needle_re(needle):
    """Alphanumeric-bounded, whitespace-tolerant match of a LOWER-CASE needle against lower-cased text."""
    body = r"\s+".join(re.escape(p) for p in needle.split())
    return re.compile(r"(?<![a-z0-9])" + body + r"(?![a-z0-9])")


def needles_for(c, h1):
    strong = []

    def add(n):
        n = n.strip().lower()
        if n and n not in strong:
            strong.append(n)

    add(c["slug"])
    if len(c["_base"]) >= 6:
        add(c["_base"])
    for repo in (c["code_repo"], c["judging_repo"]):
        add(repo)
        add(repo.split("/")[-1])
    if h1 and len(h1.split()) >= 2:
        add(h1)
    weak = []
    for src in (c["_base"], h1):
        for tok in re.split(r"[^a-z0-9]+", (src or "").lower()):
            if len(tok) >= 4 and not tok.isdigit() and tok not in WEAK_STOP and tok not in strong \
                    and tok not in weak:
                weak.append(tok)
    return strong, weak


def contamination(c, h1, texts, ledger_lines):
    strong, weak = needles_for(c, h1)
    pats = [(n, "strong", needle_re(n)) for n in strong] + [(n, "weak", needle_re(n)) for n in weak]
    hits = []
    for rel, text in texts:
        starts = None
        pv = "yes" if prompt_visible(rel) else "no"
        for n, kind, p in pats:
            if n.split()[0] not in text:
                continue
            for m in p.finditer(text):
                if starts is None:
                    starts = [0] + [m2.end() for m2 in re.finditer("\n", text)]
                hits.append((n, kind, rel, bisect.bisect_right(starts, m.start()), pv))
    strong_lines = {(h[2], h[3]) for h in hits if h[1] == "strong"}
    weak_lines = {(h[2], h[3]) for h in hits if h[1] == "weak"}
    pv_lines = {(h[2], h[3]) for h in hits if h[4] == "yes"}
    if ledger_lines is None:
        ledger = "unchecked"
    else:
        ledger = "none"
        for line in (l.lower() for l in ledger_lines):
            if any(p.search(line) for _n, k, p in pats if k == "strong"):
                ledger = "strong"
                break
            if any(p.search(line) for _n, k, p in pats if k == "weak"):
                ledger = "weak"
    return sorted(set(hits)), len(strong_lines), len(weak_lines), len(pv_lines), ledger


# ---- memorisation probe ----------------------------------------------------------------------------------------
GENERIC_NAMES = frozenset("""
deposit withdraw mint burn redeem transfer transferfrom approve claim stake unstake borrow repay liquidate swap
initialize init execute update set get balanceof totalsupply totalassets harvest rebalance settle sync vault token
pool router manager controller oracle strategy factory receive fallback constructor
""".split())
MECH_STOP = frozenset("""
that this with from into when which their there where while will would could should cannot does doesnt have has
had been being were user users protocol attacker attackers malicious lead leads leading allow allows allowing
cause causes result results resulting because incorrect incorrectly wrong wrongly missing lack lacks improper
issue issues possible potential loss lost funds fund value values some other more less than also only after
before about above below them they then these those used using uses call calls called function functions contract
contracts lets let can may might make makes made even such through without within over under same into onto
""".split())
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def stem(w):
    for suf in ("ing", "ed", "es", "s"):
        if w.endswith(suf) and len(w) - len(suf) >= 4:
            w = w[:-len(suf)]
            break
    return w[:6]


def code_idents(text):
    """Identifiers that LOOK like code: backticked, followed by `(`, `A::b` / `A.b`, camelCase, PascalCase with 2+
    capitals, or a leading underscore. A capitalised English word is not an identifier."""
    out = set()
    for m in re.finditer(r"`([^`]+)`", text or ""):
        for t in IDENT_RE.findall(m.group(1)):
            if len(t) >= 3 and not t.isdigit():
                out.add(t.lower())
    for m in re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)(?:::|\.)([A-Za-z_][A-Za-z0-9_]*)", text or ""):
        if re.search(r"[A-Z]", m.group(1)) and re.search(r"[a-z]", m.group(2)):
            out.add(m.group(1).lower())
            out.add(m.group(2).lower())
    for t in IDENT_RE.findall(text or ""):
        if len(t) < 3:
            continue
        if (re.search(r"[a-z][A-Z]", t) or re.match(r"^[A-Z][a-z0-9]+[A-Z]", t) or t.startswith("_")
                or re.search(re.escape(t) + r"\(", text)):
            out.add(t.lower())
    return out


def mech_words(text, exclude):
    out = set()
    for w in re.split(r"[^a-z0-9]+", (text or "").lower()):
        if len(w) >= 4 and not w.isdigit() and w not in MECH_STOP and w not in exclude:
            out.add(stem(w))
    return out


def gt_profile(row):
    names = code_idents(row["title"])
    for m in re.finditer(r"`([^`]+)`", row["signature"]):
        for t in IDENT_RE.findall(m.group(1)):
            if len(t) >= 3:
                names.add(t.lower())
    for pair in row["locations"].split():
        base, _, fn = pair.partition(":")
        if base.endswith(".sol"):
            names.add(base[:-4].lower())
        if fn:
            names.add(fn.lower())
    return names, mech_words(row["title"], names)


def parse_reply(reply):
    out = []
    for raw in (reply or "").split("\n"):
        line = raw.strip().lstrip("-*•│> ").strip()
        if not line.startswith("FINDING|"):
            continue
        f = [x.strip() for x in line.split("|")]
        if len(f) >= 2 and f[1].upper() == "NONE":
            continue
        while len(f) < 5:
            f.append("")
        out.append({"sev": f[1], "contract": f[2], "function": f[3], "mech": "|".join(f[4:])})
    return out


def finding_profile(fd):
    names = set()
    for field in (fd["contract"], fd["function"]):
        for t in IDENT_RE.findall(field.replace(".sol", "")):
            if len(t) >= 3:
                names.add(t.lower())
    names |= code_idents(fd["mech"])
    words = mech_words(" ".join((fd["contract"], fd["function"], fd["mech"])), set())
    return names, words


def score_probe(rows, reply):
    """Conservative, offline: per GT row `yes|partial|no`. `yes` needs a STRONG name match (a non-generic
    identifier, or two identifiers) AND >= 2 shared mechanism keywords; `partial` is a strong name + 1 keyword or
    a generic-name-only match + >= 2 keywords; a mechanism-only resemblance is `no`. Each reply line credits at
    most ONE row (greedy on the strongest pairs), so a vague line cannot sweep several rows."""
    findings = parse_reply(reply)
    fprof = [finding_profile(f) for f in findings]
    cands = []
    for ri, row in enumerate(rows):
        gnames, gmech = gt_profile(row)
        for fi, (fnames, fwords) in enumerate(fprof):
            shared = gnames & fnames
            if not shared:
                continue
            strong = len(shared) >= 2 or any(n not in GENERIC_NAMES for n in shared)
            overlap = len(gmech & fwords)
            if strong and overlap >= 2:
                level = 2
            elif (strong and overlap == 1) or (not strong and overlap >= 2):
                level = 1
            else:
                continue
            cands.append((level, int(strong), overlap, len(shared), -ri, -fi, ri, fi))
    cands.sort(reverse=True)
    result = [{"verdict": "no", "finding": "-", "names": 0, "overlap": 0} for _ in rows]
    used_r, used_f = set(), set()
    for level, _s, overlap, nshared, _a, _b, ri, fi in cands:
        if ri in used_r or fi in used_f:
            continue
        used_r.add(ri)
        used_f.add(fi)
        result[ri] = {"verdict": "yes" if level == 2 else "partial", "finding": "F%d" % (fi + 1),
                      "names": nshared, "overlap": overlap}
    return findings, result


def probe_summary(rows, result):
    rare_idx = [i for i, r in enumerate(rows) if is_rare(r)]
    s = {"rows": len(rows),
         "yes": sum(1 for r in result if r["verdict"] == "yes"),
         "partial": sum(1 for r in result if r["verdict"] == "partial"),
         "rare": len(rare_idx),
         "rare_yes": sum(1 for i in rare_idx if result[i]["verdict"] == "yes"),
         "rare_partial": sum(1 for i in rare_idx if result[i]["verdict"] == "partial")}
    s["no"] = s["rows"] - s["yes"] - s["partial"]
    s["rate"] = "%.2f" % (s["yes"] / s["rows"]) if s["rows"] else "0.00"
    s["rare_rate"] = "%.2f" % (s["rare_yes"] / s["rare"]) if s["rare"] else "0.00"
    s["verdict"] = "MEMORIZED" if s["rare_yes"] >= MEMORIZED_MIN_RARE_YES else "not-memorized"
    return s


def build_probe_prompt(meta):
    what = 'the %s audit contest "%s"' % (meta.get("platform") or "Sherlock", meta["slug"])
    if meta.get("date") and meta["date"] != "-":
        what += " (%s)" % meta["date"]
    if meta.get("name"):
        what += ', protocol "%s"' % meta["name"]
    return "\n".join([
        "MEMORY PROBE. Answer from your training memory ONLY. Do not use any tool: do not read or search files, do"
        " not browse the web, do not run commands.",
        "",
        "Contest: %s." % what,
        "",
        "Question: which High and Medium severity findings were ACCEPTED in this contest's public judging report?",
        "",
        "List every accepted High or Medium finding you specifically remember from THIS contest, one per line, in"
        " EXACTLY this grammar:",
        "FINDING|<H or M>|<contract name>|<function name, or - if you do not remember it>|<one sentence: the root"
        " cause and how it is exploited>",
        "If you do not remember this contest or any of its accepted findings, output exactly this one line:",
        "FINDING|NONE",
        "Do not guess and do not list generic vulnerability classes: omit anything you do not specifically remember"
        " from this contest's report. No other output.",
    ])


def prompt_leaks(prompt, rows, cued=False):
    """The prompt must carry NO code and NO ground truth. Returns the reasons it does (empty = clean). A CUED prompt
    names GT locations on purpose (`<contract>:<function>` is the cue), so only that one check is lifted for it:
    titles, ids, `.sol` names and source code stay forbidden."""
    low = prompt.lower()
    why = []
    if ".sol" in low or "pragma solidity" in low or re.search(r"\bfunction\s+\w+\s*\(", prompt):
        why.append("source code / a .sol file name")
    if re.search(r"(?<![A-Za-z0-9])[HM]-\d{1,3}(?![A-Za-z0-9])", prompt):
        why.append("a GT finding id")
    for r in rows:
        t = re.sub(r"\s+", " ", r["title"]).strip().lower()
        if len(t) >= 12 and t in low:
            why.append("the title of GT row " + r["sev_id"])
        for pair in ([] if cued else r["locations"].split()):
            fn = pair.partition(":")[2]
            if len(fn) >= 6 and re.search(r"(?<![A-Za-z0-9_])" + re.escape(fn) + r"(?![A-Za-z0-9_])", prompt,
                                          re.I):
                why.append("the GT location function " + fn)
    return sorted(set(why))


def probe_argv(backend, model, stub, prompt):
    """The EXACT argv. flat-cyborg mirrors the argv agentis builds for the hunt's `llm.backend = flat-cyborg`
    (agentis-core llm.rs build_args) with the hunt's idle_ms, pointed at the hunt's sandboxed target
    (lib/claude-sandboxed.sh: bwrap view + web tools denied) under the hunt's `--model` pin. The prompt itself
    travels in `--cmd`; `--tools ""` + `--strict-mcp-config` switch every tool and MCP server off, because a
    memory probe that could read or fetch the answer is not a memory probe."""
    if backend == "stub":
        return [stub, "--model", model]
    return ["flat-cyborg", "--tui", "--auto-approve", "--extract", "--extract-structural", "--paste-input",
            "--idle-ms", str(PROBE_IDLE_MS), "--cmd", prompt, "--timeout-ms", str(PROBE_TIMEOUT_MS),
            "--", SANDBOX, "--model", model, "--tools", "", "--strict-mcp-config"]


def call_backend(backend, model, stub, prompt):
    argv = probe_argv(backend, model, stub, prompt)
    if backend == "stub":
        p = subprocess.run(argv, input=prompt.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=120)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    if offline():
        raise NetworkTripwire("LLM probe via flat-cyborg")
    if shutil.which("flat-cyborg") is None:
        die(3, "flat-cyborg not on PATH (the probe uses the hunt's backend; use --backend stub offline)")
    # An EMPTY, pre-trusted run dir outside the work dir: the session sees no code, no truth.tsv, no judging clone.
    run = tempfile.mkdtemp(prefix="fresh-set-probe-")
    try:
        subprocess.run(["bash", TRUST, run], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        env = dict(os.environ, HUNT_SANDBOX_RUN=run, FLAT_CYBORG_COLS=os.environ.get("FLAT_CYBORG_COLS", "600"))
        env.pop("HUNT_SANDBOX_REPO", None)
        env.pop("HUNT_SANDBOX_EXTERNAL", None)
        try:
            p = subprocess.run(argv, cwd=run, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=PROBE_TIMEOUT_MS // 1000 + 60)
        except subprocess.TimeoutExpired:
            return 124, ""
        return p.returncode, p.stdout.decode("utf-8", "replace")
    finally:
        shutil.rmtree(run, ignore_errors=True)


def read_kv(path):
    out = {}
    if os.path.isfile(path):
        for f in read_tsv_lines(path):
            if len(f) >= 2:
                out[f[0]] = f[1]
    return out


def contest_meta(cdir, name_override):
    """Contest identity for the prompt: <cdir>/contest.tsv (a fresh-set build), else the judging clone's origin
    remote + the code README H1 (any fetch-corpus.sh-frozen dir), else the dir name."""
    meta = read_kv(os.path.join(cdir, "contest.tsv"))
    if not meta.get("slug"):
        url = (git_local(["-C", os.path.join(cdir, "judging"), "config", "--get", "remote.origin.url"]) or "").strip()
        m = re.search(r"github\.com[:/]+([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", url)
        if m:
            meta["judging_repo"] = "%s/%s" % (m.group(1), m.group(2))
            meta["slug"] = re.sub(r"-judging$", "", m.group(2))
        else:
            meta["slug"] = os.path.basename(os.path.normpath(cdir))
        meta["date"] = slug_date(meta["slug"]) or "-"
        meta["name"] = readme_h1(os.path.join(cdir, "code"))
    if name_override:
        meta["name"] = name_override
    return meta


def run_probe(cdir, rows, backend, model, stub, name_override, rescore):
    """Probe one contest dir. Returns the summary dict (and writes <cdir>/probe/*)."""
    pdir = os.path.join(cdir, "probe")
    if rescore:
        path = os.path.join(pdir, "reply.txt")
        if not os.path.isfile(path):
            die(3, "--rescore: no recorded reply at " + path)
        with open(path, encoding="utf-8", errors="replace") as fh:
            reply = fh.read()
        run = read_kv(os.path.join(pdir, "run.tsv"))
        backend, model = run.get("backend", backend), run.get("model", model)
    else:
        meta = contest_meta(cdir, name_override)
        prompt = build_probe_prompt(meta)
        leaks = prompt_leaks(prompt, rows)
        if leaks:
            raise ProbeRefused("the prompt would carry %s (pass a different --name)" % "; ".join(leaks))
        os.makedirs(pdir, exist_ok=True)
        write_atomic(os.path.join(pdir, "prompt.txt"), prompt)
        rc, reply = call_backend(backend, model, stub, prompt)
        write_atomic(os.path.join(pdir, "run.tsv"),
                     "backend\t%s\nmodel\t%s\nexit\t%d\nprobed\t%s\n"
                     % (backend, model, rc, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
        if rc != 0 or not reply.strip():
            # Kept for diagnosis under a name the re-score path never reads, and any older reply is dropped.
            write_atomic(os.path.join(pdir, "reply.failed.txt"), reply)
            for stale in ("reply.txt", "probe.tsv", "summary.tsv"):
                if os.path.exists(os.path.join(pdir, stale)):
                    os.remove(os.path.join(pdir, stale))
            raise ProbeFailed("backend exit %d, %d reply byte(s) — see %s"
                              % (rc, len(reply), os.path.join(pdir, "reply.failed.txt")))
        write_atomic(os.path.join(pdir, "reply.txt"), reply)
    findings, result = score_probe(rows, reply)
    s = probe_summary(rows, result)
    s["backend"], s["model"], s["findings"] = backend, model, len(findings)
    lines = ["sev_id\tseverity\trarity\trare\trecalled_from_memory\tfinding\tname_hits\tmech_overlap"]
    for row, r in zip(rows, result):
        lines.append("%s\t%s\t%d\t%s\t%s\t%s\t%d\t%d" % (row["sev_id"], row["severity"], row["rarity"],
                                                         "yes" if is_rare(row) else "no", r["verdict"],
                                                         r["finding"], r["names"], r["overlap"]))
    write_atomic(os.path.join(pdir, "probe.tsv"), "\n".join(lines) + "\n")
    keys = ("rows", "yes", "partial", "no", "rare", "rare_yes", "rare_partial", "rate", "rare_rate", "findings",
            "verdict", "backend", "model")
    write_atomic(os.path.join(pdir, "summary.tsv"),
                 "\t".join(keys) + "\n" + "\t".join(str(s[k]) for k in keys) + "\n")
    return s

# ---- cued memorisation probe -----------------------------------------------------------------------------------
# Free recall ("list what you remember") is biased toward FINDING|NONE by its own do-not-guess instruction and
# misses RECOGNITION memory. The cued probe hands the model each GT row's column-6 location, `<contract>:<function>`
# and nothing else (never a title, a description or a mechanism), and asks whether an accepted High/Medium finding
# was reported there and, if so, its root cause. The answer is scored by the SAME conservative matcher: the cue
# supplies the names, so the credit rests on the mechanism keywords the model adds by itself. Every batch also
# carries one DECOY, a real function of the audited code with no GT row, so a model that says YES to everything
# shows up as a decoy false-positive rate instead of as memorisation.
FUNC_DECL_RE = re.compile(r"^\s*function\s+([A-Za-z_]\w*)\s*\(", re.M)


def _h(*parts):
    return hashlib.sha256("\x1f".join(parts).encode("utf-8")).hexdigest()


def decoy_pool(code_dir, rows):
    """Sorted `(Contract, function)` pairs declared in the audited code that no GT row names anywhere."""
    if not code_dir or not os.path.isdir(code_dir):
        return []
    named = set()
    for r in rows:
        names, _mech = gt_profile(r)
        named |= names
        named |= code_idents(r["signature"])
    pool = set()
    for cur, dirs, fnames in os.walk(code_dir):
        dirs[:] = sorted(d for d in dirs
                         if d not in project_roots.PRUNE_DIRS and d not in project_roots.EXCLUDED_SEGMENTS)
        for f in fnames:
            if not f.endswith(".sol") or f.endswith(".t.sol") or f.endswith(".s.sol"):
                continue
            try:
                with open(os.path.join(cur, f), encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                continue
            for m in FUNC_DECL_RE.finditer(text):
                if m.group(1).lower() not in named:
                    pool.add((f[:-4], m.group(1)))
    return sorted(pool)


def cued_batches(slug, rows, pool, batch):
    """Deterministic batches of cue items. One item per GT row with a location (its first column-6 pair), plus one
    decoy per batch; items are ordered by a hash so the decoy's position carries no signal."""
    asked = [(i, r["locations"].split()[0]) for i, r in enumerate(rows) if r["locations"].split()]
    batches = []
    for b in range(0, len(asked), batch):
        items = []
        for i, pair in asked[b:b + batch]:
            base, _, fn = pair.partition(":")
            items.append({"kind": "row", "row": i, "sev_id": rows[i]["sev_id"],
                          "contract": base[:-4] if base.endswith(".sol") else base, "function": fn})
        if pool:
            con, fn = pool[int(_h(slug, "decoy", str(b // batch)), 16) % len(pool)]
            items.append({"kind": "decoy", "row": None, "sev_id": "DECOY", "contract": con, "function": fn})
        items.sort(key=lambda it: _h(slug, it["contract"], it["function"], it["kind"]))
        for n, it in enumerate(items, 1):
            it["label"] = "C%d" % n
        batches.append(items)
    return batches


def build_cued_prompt(meta, items):
    what = 'the %s audit contest "%s"' % (meta.get("platform") or "Sherlock", meta["slug"])
    if meta.get("date") and meta["date"] != "-":
        what += " (%s)" % meta["date"]
    if meta.get("name"):
        what += ', protocol "%s"' % meta["name"]
    return "\n".join([
        "MEMORY PROBE (cued). Answer from your training memory ONLY. Do not use any tool: do not read or search"
        " files, do not browse the web, do not run commands.",
        "",
        "Contest: %s." % what,
        "",
        "Below are code locations in this contest's codebase, one per line, as <label>|<contract>:<function>. For"
        " EACH location: was an accepted High or Medium severity finding reported at this function in this"
        " contest's public judging report?",
        "Answer with exactly one line per location, in EXACTLY this grammar:",
        "CUE|<label>|YES|<one sentence: the root cause and how it is exploited>",
        "CUE|<label>|NONE",
        "Answer YES only if you specifically remember such a finding in this contest's report; otherwise NONE."
        " No other output.",
        "",
    ] + ["%s|%s:%s" % (it["label"], it["contract"], it["function"]) for it in items])


def parse_cued_reply(reply):
    out = {}
    for raw in (reply or "").split("\n"):
        line = raw.strip().lstrip("-*•│> ").strip()
        if not line.startswith("CUE|"):
            continue
        f = [x.strip() for x in line.split("|")]
        if len(f) < 3 or f[1] in out:
            continue
        ans = f[2].upper()
        out[f[1]] = ("YES", "|".join(f[3:])) if ans == "YES" else ("NONE", "")
    return out


def _rate(num, den):
    return "%.2f" % (num / den) if den else "-"


def score_cued(rows, batches, replies, threshold):
    """Per asked row: answer + cued_recall (the conservative matcher on the cue names + the model's mechanism);
    per decoy: answer. Returns (table lines, summary dict)."""
    lines = ["sev_id\tseverity\trarity\trare\tlabel\tlocation\tanswer\tcued_recall\tmech_overlap"]
    asked_rows = set()
    s = {"asked": 0, "said_yes": 0, "yes": 0, "partial": 0, "rare_asked": 0, "rare_yes": 0, "decoys": 0,
         "decoy_yes": 0}
    per_row = {}
    for b, items in enumerate(batches):
        ans = parse_cued_reply(replies[b] if b < len(replies) else "")
        for it in items:
            answer, mech = ans.get(it["label"], ("missing", ""))
            loc = "%s:%s" % (it["contract"], it["function"])
            if it["kind"] == "decoy":
                s["decoys"] += 1
                s["decoy_yes"] += answer == "YES"
                lines.append("DECOY\t-\t-\t-\t%s\t%s\t%s\t-\t-" % (it["label"], loc, answer))
                continue
            row = rows[it["row"]]
            verdict, overlap = "no", 0
            if answer == "YES":
                _f, r = score_probe([row], "FINDING|-|%s|%s|%s" % (it["contract"], it["function"], mech))
                verdict, overlap = r[0]["verdict"], r[0]["overlap"]
            per_row[it["row"]] = (it["label"], loc, answer, verdict, overlap)
            asked_rows.add(it["row"])
    for i, row in enumerate(rows):
        rare = is_rare(row)
        if i not in asked_rows:
            lines.append("%s\t%s\t%d\t%s\t-\t-\t-\t-\t-" % (row["sev_id"], row["severity"], row["rarity"],
                                                            "yes" if rare else "no"))
            continue
        label, loc, answer, verdict, overlap = per_row[i]
        s["asked"] += 1
        s["said_yes"] += answer == "YES"
        s["yes"] += verdict == "yes"
        s["partial"] += verdict == "partial"
        if rare:
            s["rare_asked"] += 1
            s["rare_yes"] += verdict == "yes"
        lines.append("%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%d" % (row["sev_id"], row["severity"], row["rarity"],
                                                             "yes" if rare else "no", label, loc, answer, verdict,
                                                             overlap))
    s["cued_rate"] = _rate(s["yes"], s["asked"])
    s["rare_cued_rate"] = _rate(s["rare_yes"], s["rare_asked"])
    s["decoy_fp_rate"] = _rate(s["decoy_yes"], s["decoys"])
    s["threshold"] = "%.2f" % threshold
    s["verdict"] = ("MEMORIZED" if s["rare_asked"] and s["rare_yes"] / s["rare_asked"] > threshold
                    else "not-memorized")
    s["batches"] = len(batches)
    return lines, s


CUED_KEYS = ("asked", "said_yes", "yes", "partial", "cued_rate", "rare_asked", "rare_yes", "rare_cued_rate",
             "decoys", "decoy_yes", "decoy_fp_rate", "threshold", "batches", "verdict", "backend", "model")


def run_cued_probe(cdir, rows, backend, model, stub, name_override, rescore, threshold, batch):
    """The cued probe on one contest dir; writes <cdir>/probe/cued-*. Returns the summary dict."""
    pdir = os.path.join(cdir, "probe")
    items_path = os.path.join(pdir, "cued-items.tsv")
    if rescore:
        if not os.path.isfile(items_path):
            die(3, "--rescore: no recorded cued probe at " + items_path)
        batches = {}
        for f in read_tsv_lines(items_path):
            if f[0] == "batch" or len(f) < 6:
                continue
            row = None if f[2] == "decoy" else next((i for i, r in enumerate(rows) if r["sev_id"] == f[3]), None)
            if f[2] != "decoy" and row is None:
                die(3, "--rescore: cued item %s no longer in truth.tsv" % f[3])
            batches.setdefault(int(f[0]), []).append({"label": f[1], "kind": f[2], "sev_id": f[3], "row": row,
                                                      "contract": f[4], "function": f[5]})
        batches = [batches[k] for k in sorted(batches)]
        replies = []
        for b in range(len(batches)):
            with open(os.path.join(pdir, "cued-reply-%d.txt" % (b + 1)), encoding="utf-8", errors="replace") as fh:
                replies.append(fh.read())
        run = read_kv(os.path.join(pdir, "run-cued.tsv"))
        backend, model = run.get("backend", backend), run.get("model", model)
    else:
        meta = contest_meta(cdir, name_override)
        batches = cued_batches(meta["slug"], rows, decoy_pool(os.path.join(cdir, "code"), rows), batch)
        prompts = [build_cued_prompt(meta, items) for items in batches]
        for prompt in prompts:
            leaks = prompt_leaks(prompt, rows, cued=True)
            if leaks:
                raise ProbeRefused("the cued prompt would carry %s (pass a different --name)" % "; ".join(leaks))
        os.makedirs(pdir, exist_ok=True)
        for old in os.listdir(pdir):
            if old.startswith("cued-"):
                os.remove(os.path.join(pdir, old))
        write_atomic(items_path, "batch\tlabel\tkind\tsev_id\tcontract\tfunction\n" + "".join(
            "%d\t%s\t%s\t%s\t%s\t%s\n" % (b + 1, it["label"], it["kind"], it["sev_id"], it["contract"],
                                          it["function"])
            for b, items in enumerate(batches) for it in items))
        replies = []
        for b, prompt in enumerate(prompts):
            write_atomic(os.path.join(pdir, "cued-prompt-%d.txt" % (b + 1)), prompt)
            rc, reply = call_backend(backend, model, stub, prompt)
            if rc != 0 or not reply.strip():
                write_atomic(os.path.join(pdir, "cued-reply-%d.failed.txt" % (b + 1)), reply)
                for stale in ("cued.tsv", "cued-summary.tsv"):
                    if os.path.exists(os.path.join(pdir, stale)):
                        os.remove(os.path.join(pdir, stale))
                raise ProbeFailed("cued batch %d: backend exit %d, %d reply byte(s)" % (b + 1, rc, len(reply)))
            write_atomic(os.path.join(pdir, "cued-reply-%d.txt" % (b + 1)), reply)
            replies.append(reply)
        write_atomic(os.path.join(pdir, "run-cued.tsv"),
                     "backend\t%s\nmodel\t%s\nprobed\t%s\n"
                     % (backend, model, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
    lines, s = score_cued(rows, batches, replies, threshold)
    s["backend"], s["model"] = backend, model
    os.makedirs(pdir, exist_ok=True)
    write_atomic(os.path.join(pdir, "cued.tsv"), "\n".join(lines) + "\n")
    write_atomic(os.path.join(pdir, "cued-summary.tsv"),
                 "\t".join(CUED_KEYS) + "\n" + "\t".join(str(s[k]) for k in CUED_KEYS) + "\n")
    return s


def cmd_probe(argv):
    if not argv or argv[0].startswith("-"):
        die(2, "usage: probe <contest-dir> [--name <text>] [--backend flat-cyborg|stub] [--model <id>] "
               "[--stub <cmd>] [--rescore]")
    cdir = argv[0]
    flags = parse_flags(argv[1:], ("--name", "--backend", "--model", "--stub", "--memorized-rare-rate", "--batch"),
                        (), ("--rescore", "--cued"))
    backend = flags.get("--backend", "flat-cyborg")
    if backend not in ("flat-cyborg", "stub"):
        die(2, "--backend must be flat-cyborg or stub")
    truth = os.path.join(cdir, "truth.tsv")
    if not os.path.isfile(truth):
        die(3, "no truth.tsv in the contest dir: " + cdir)
    rows = read_truth(truth)
    if not rows:
        die(3, "truth.tsv has no rows: " + truth)
    stub = flags.get("--stub", os.path.join(HERE, "fixtures", "fresh-set", "probe-stub.sh"))
    if flags.get("--cued"):
        try:
            c = run_cued_probe(cdir, rows, backend, flags.get("--model", "opus"), stub, flags.get("--name"),
                               bool(flags.get("--rescore")), float(flags.get("--memorized-rare-rate", CUED_RARE_RATE)),
                               int(flags.get("--batch", CUED_BATCH)))
        except ProbeRefused as e:
            die(4, "probe refused: %s" % e)
        except ProbeFailed as e:
            die(3, "probe failed: %s" % e)
        print("cued probe %s: %d location(s) asked in %d batch(es); YES %d, cued_recall yes=%d partial=%d "
              "(cued_rate %s); rare %d/%d (rare_cued_rate %s, threshold %s); decoys YES %d/%d (decoy_fp_rate %s) -> %s"
              " [backend=%s model=%s]"
              % (os.path.basename(os.path.normpath(cdir)), c["asked"], c["batches"], c["said_yes"], c["yes"],
                 c["partial"], c["cued_rate"], c["rare_yes"], c["rare_asked"], c["rare_cued_rate"], c["threshold"],
                 c["decoy_yes"], c["decoys"], c["decoy_fp_rate"], c["verdict"], c["backend"], c["model"]))
        return 0
    try:
        s = run_probe(cdir, rows, backend, flags.get("--model", "opus"),
                      flags.get("--stub", os.path.join(HERE, "fixtures", "fresh-set", "probe-stub.sh")),
                      flags.get("--name"), bool(flags.get("--rescore")))
    except ProbeRefused as e:
        die(4, "probe refused: %s" % e)
    except ProbeFailed as e:
        die(3, "probe failed: %s" % e)
    print("probe %s: %d finding line(s); recalled_from_memory yes=%d partial=%d no=%d of %d (rate %s); rare yes=%d "
          "partial=%d of %d (rate %s) -> %s [backend=%s model=%s]"
          % (os.path.basename(os.path.normpath(cdir)), s["findings"], s["yes"], s["partial"], s["no"], s["rows"],
             s["rate"], s["rare_yes"], s["rare_partial"], s["rare"], s["rare_rate"], s["verdict"], s["backend"],
             s["model"]))
    return 0


# ---- build -----------------------------------------------------------------------------------------------------
def write_candidates(work, cands, header):
    lines = list(header) + ["id\tslug\tdate\tended\tstatus\treason\tcode_repo\tjudging_repo"]
    for c in sorted(cands, key=lambda c: c["id"]):
        lines.append("\t".join((c["id"], c["slug"], c["date"], c["ended"], c["_status"], c["_reason"],
                                c["code_repo"], c["judging_repo"])))
    write_atomic(os.path.join(work, "candidates.tsv"), "\n".join(lines) + "\n")


def process(c, work, flags, texts, ledger_lines, probe_cfg):
    row = {k: "-" for k in REPORT_COLS}
    row.update(id=c["id"], slug=c["slug"], date=c["date"], ended=c["ended"])
    d = os.path.join(work, c["id"])
    os.makedirs(d, exist_ok=True)
    repos_from = flags.get("--repos-from")
    fail = None
    h1 = ""

    ok, sha, err = fetch_repo(c["judging_repo"], os.path.join(d, "judging"), repos_from, False)
    row["judging_sha"] = sha
    readme = os.path.join(d, "judging", "README.md")
    truth = os.path.join(d, "truth.tsv")
    rows = []
    if not ok:
        fail = ("NO-GT", "judging-fetch-failed")
        warn("[%s] judging fetch failed: %s" % (c["id"], err))
    elif not os.path.isfile(readme):
        fail = ("NO-GT", "no-readme")
    else:
        if extract_gt(readme, truth) != 0:
            fail = ("NO-GT", "extract-failed")
        else:
            rows = read_truth(truth)
            row["gt"] = str(len(rows))
            row["rare"] = str(sum(1 for r in rows if is_rare(r)))
            row["rarity_unknown"] = str(sum(1 for r in rows if r["rarity"] == 0))
            with open(readme, encoding="utf-8", errors="replace") as fh:
                issues = sum(1 for l in fh if re.match(r"^#\s+Issue\s", l))
            row["gt_shape"] = "ok" if issues == len(rows) else "drift"
            if not rows:
                fail = ("NO-GT", "0-rows")
            elif int(row["rare"]) < int(flags.get("--min-rare", "1")):
                fail = ("LOW-RARE", "rare=%s<%s" % (row["rare"], flags.get("--min-rare", "1")))

    if fail is None:
        code = os.path.join(d, "code")
        ok, sha, err = fetch_repo(c["code_repo"], code, repos_from, True)
        row["code_sha"] = sha
        if not ok:
            fail = ("NO-CODE", "code-fetch-failed")
            row["code_present"] = "fetch-failed"
            warn("[%s] code fetch failed: %s" % (c["id"], err))
        else:
            h1 = readme_h1(code)
            files, lines = sol_stats(code)
            row["sol_files"], row["sol_lines"] = str(files), str(lines)
            roots = project_roots.detect(code)
            row["roots"] = str(len(roots))
            row["project_subdir"] = ",".join(roots) if roots else "-"
            row["code_present"] = code_presence(code, files)
            if row["code_present"] != "ok":
                fail = ("NO-CODE", row["code_present"])
            elif extract_gt(readme, truth, code) == 0:
                rows = read_truth(truth)
                row["rare_loc"] = str(sum(1 for r in rows if is_rare(r) and r["locations"].strip()))

    meta = [("slug", c["slug"]), ("code_repo", c["code_repo"]), ("judging_repo", c["judging_repo"]),
            ("date", c["date"]), ("ended", c["ended"]), ("platform", c.get("platform") or "Sherlock"),
            ("name", h1)]
    write_atomic(os.path.join(d, "contest.tsv"), "".join("%s\t%s\n" % kv for kv in meta))

    hits, n_strong, n_weak, n_pv, ledger = contamination(c, h1, texts, ledger_lines)
    write_atomic(os.path.join(d, "contamination.tsv"),
                 "needle\tkind\tfile\tline\tprompt_visible\n"
                 + "".join("%s\t%s\t%s\t%d\t%s\n" % h for h in hits))
    row["contam_strong"], row["contam_weak"], row["contam_pv"], row["ledger"] = \
        str(n_strong), str(n_weak), str(n_pv), ledger

    if fail is None:
        if n_strong or n_pv or ledger == "strong":
            fail = ("CONTAMINATED", "strong=%d pv=%d ledger=%s" % (n_strong, n_pv, ledger))
        elif n_weak or ledger == "weak":
            fail = ("REVIEW", "weak=%d ledger=%s" % (n_weak, ledger))
        else:
            fail = ("CLEAN", "-")

    # Memorisation probe: a recorded reply is always re-scored; --probe records one where it is missing (and
    # --probe --cued a cued one). Only a contest that could still be reserved (CLEAN / REVIEW) is worth an LLM call.
    memo_why = []
    base = fail[0]
    if fail[0] in ("CLEAN", "REVIEW") and rows:
        have = os.path.isfile(os.path.join(d, "probe", "reply.txt"))
        b, m, stub, cued, threshold, batch = probe_cfg or ("flat-cyborg", "opus", "", False, CUED_RARE_RATE,
                                                           CUED_BATCH)
        if have or probe_cfg:
            try:
                s = run_probe(d, rows, b, m, stub, None, have)
            except ProbeRefused as e:
                # One contest's refused prompt must not abort the whole build: it stays unprobed, visibly.
                warn("[%s] probe refused: %s — run `fresh-set.sh probe <work>/%s --name <text>`"
                     % (c["id"], e, c["id"]))
                row["memo"] = row["memo_rare"] = "refused"
                s = None
            except ProbeFailed as e:
                warn("[%s] probe failed: %s — the contest stays unprobed" % (c["id"], e))
                row["memo"] = row["memo_rare"] = "failed"
                s = None
            if s is not None:
                row["memo"] = "%d/%d" % (s["yes"], s["rows"])
                row["memo_rare"] = "%d/%d" % (s["rare_yes"], s["rare"])
                if s["verdict"] == "MEMORIZED":
                    memo_why.append("rare_yes=%d/%d" % (s["rare_yes"], s["rare"]))
        have_cued = os.path.isfile(os.path.join(d, "probe", "cued-items.tsv"))
        if have_cued or (probe_cfg and cued):
            try:
                cs = run_cued_probe(d, rows, b, m, stub, None, have_cued, threshold, batch)
            except ProbeRefused as e:
                warn("[%s] cued probe refused: %s" % (c["id"], e))
                row["memo_cued"], cs = "refused", None
            except ProbeFailed as e:
                warn("[%s] cued probe failed: %s — the contest stays unprobed (cued)" % (c["id"], e))
                row["memo_cued"], cs = "failed", None
            if cs is not None:
                row["memo_cued"] = "%d/%d" % (cs["rare_yes"], cs["rare_asked"])
                if cs["verdict"] == "MEMORIZED":
                    memo_why.append("cued_rare=%d/%d>%s decoy_fp=%s" % (cs["rare_yes"], cs["rare_asked"],
                                                                      cs["threshold"], cs["decoy_fp_rate"]))
    if memo_why:
        fail = ("MEMORIZED", "%s base=%s" % (" ".join(memo_why), base))
    row["status"], row["reason"] = fail
    return row


def cmd_build(argv):
    flags = parse_flags(
        argv,
        ("--work", "--repo-top", "--source", "--org", "--candidates-from", "--repos-from", "--corpus", "--ledger",
         "--scan-root", "--since", "--until", "--min-rare", "--max-candidates", "--backend", "--model", "--stub",
         "--memorized-rare-rate", "--batch"),
        ("--listing-from", "--exclude", "--scan-exclude", "--only"),
        ("--no-ledger", "--discover-only", "--refresh-listing", "--probe", "--cued"))
    work = flags.get("--work")
    if not work:
        die(2, "build requires --work <dir>")
    if bool(flags.get("--ledger")) == bool(flags.get("--no-ledger")):
        die(2, "build needs exactly one of --ledger <file> / --no-ledger")
    os.makedirs(work, exist_ok=True)
    source = flags.get("--source") or ("candidates-file" if flags.get("--candidates-from") else "sherlock-gh")
    if source not in SOURCES:
        die(2, "unknown --source %s (known: %s)" % (source, ", ".join(sorted(SOURCES))))
    corpus = flags.get("--corpus", os.path.join(HERE, "corpus.tsv"))
    corpus_ids, corpus_repos = load_corpus(corpus)
    excl = load_exclude_fields(flags["--exclude"])

    cands, discovery = SOURCES[source](flags, work, os.environ)
    assign_ids(cands, corpus_ids)
    kept = []
    for c in cands:
        if not SAFE_ID_RE.match(c["id"]):
            warn("candidate skipped (unsafe id): " + c["id"])
            continue
        if flags.get("--since") and c["date"] != "-" and c["date"] < flags["--since"]:
            continue
        if flags.get("--until") and c["date"] != "-" and c["date"] > flags["--until"]:
            continue
        if flags["--only"] and not ({c["id"].lower(), c["slug"].lower()} & {o.lower() for o in flags["--only"]}):
            continue
        c["_status"], c["_reason"] = "candidate", "-"
        if c["code_repo"].lower() in corpus_repos or c["judging_repo"].lower() in corpus_repos:
            c["_status"], c["_reason"] = "EXCLUDED", "corpus"
        elif {c["slug"].lower(), c["id"].lower(), c["code_repo"].lower(), c["judging_repo"].lower()} & excl:
            c["_status"], c["_reason"] = "EXCLUDED", "exclude-list"
        kept.append(c)
    # --max-candidates bounds the CLONE work: newest first among the non-excluded.
    if flags.get("--max-candidates"):
        n = int(flags["--max-candidates"])
        live = sorted((c for c in kept if c["_status"] != "EXCLUDED"), key=lambda c: (c["date"], c["slug"]),
                      reverse=True)
        drop = {id(c) for c in live[n:]}
        kept = [c for c in kept if id(c) not in drop]

    ledger_state = "unchecked" if flags.get("--no-ledger") else "checked"
    probe_cfg = None
    if flags.get("--probe"):
        probe_cfg = (flags.get("--backend", "flat-cyborg"), flags.get("--model", "opus"),
                     flags.get("--stub", os.path.join(HERE, "fixtures", "fresh-set", "probe-stub.sh")),
                     bool(flags.get("--cued")), float(flags.get("--memorized-rare-rate", CUED_RARE_RATE)),
                     int(flags.get("--batch", CUED_BATCH)))
    header = ["# fresh-set report (#2263) — counts only; GT text stays in <work>/<id>/truth.tsv",
              "# source=%s discovery=%s ledger=%s probe=%s"
              % (source, discovery, ledger_state,
                 ("on backend=%s model=%s cued=%s" % (probe_cfg[0], probe_cfg[1], "on" if probe_cfg[3] else "off"))
                 if probe_cfg else "off")]
    write_candidates(work, kept, header)
    if flags.get("--discover-only"):
        n_ex = sum(1 for c in kept if c["_status"] == "EXCLUDED")
        print("fresh-set: discover-only — %d candidate(s), %d excluded, discovery=%s -> %s"
              % (len(kept), n_ex, discovery, os.path.join(work, "candidates.tsv")))
        return 0

    ledger_lines = None
    if flags.get("--ledger"):
        if not os.path.isfile(flags["--ledger"]):
            die(3, "--ledger file not found: " + flags["--ledger"])
        with open(flags["--ledger"], encoding="utf-8", errors="replace") as fh:
            ledger_lines = [l.rstrip("\n") for l in fh if l.strip() and not l.lstrip().startswith("#")]
    scan_root = flags.get("--scan-root") or flags.get("--repo-top")
    if not scan_root or not os.path.isdir(scan_root):
        die(3, "--scan-root is not a directory: %s" % scan_root)
    texts = load_scan_text(scan_root, DEFAULT_SCAN_EXCLUDES + tuple(flags["--scan-exclude"]))

    report = []
    for c in sorted(kept, key=lambda c: c["id"]):
        if c["_status"] == "EXCLUDED":
            row = {k: "-" for k in REPORT_COLS}
            row.update(id=c["id"], slug=c["slug"], date=c["date"], ended=c["ended"], status="EXCLUDED",
                       reason=c["_reason"])
        else:
            note("[%s] %s ..." % (c["id"], c["slug"]))
            row = process(c, work, flags, texts, ledger_lines, probe_cfg)
        report.append(row)

    lines = header + ["\t".join(REPORT_COLS)] + ["\t".join(r[k] for k in REPORT_COLS) for r in report]
    write_atomic(os.path.join(work, "fresh-set-report.tsv"), "\n".join(lines) + "\n")

    show = ("id", "date", "status", "reason", "gt", "rare", "rare_loc", "sol_files", "project_subdir",
            "contam_strong", "contam_weak", "contam_pv", "ledger", "memo_rare")
    widths = [max([len(k)] + [len(r[k]) for r in report]) for k in show]
    print("  ".join(k.ljust(w) for k, w in zip(show, widths)))
    for r in report:
        print("  ".join(r[k].ljust(w) for k, w in zip(show, widths)))
    counts = {}
    for r in report:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print("fresh-set: %d candidate(s) — %s; discovery=%s ledger=%s -> %s"
          % (len(report), " ".join("%s=%d" % kv for kv in sorted(counts.items())) or "none", discovery,
             ledger_state, os.path.join(work, "fresh-set-report.tsv")))
    return 0


# ---- (j) reserve -----------------------------------------------------------------------------------------------
def read_report(work):
    path = os.path.join(work, "fresh-set-report.tsv")
    if not os.path.isfile(path):
        die(3, "no report in the work dir (run a build first): " + path)
    meta, rows, cols = {}, {}, None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("#"):
                for m in re.finditer(r"(\w+)=(\S+(?: \([^)]*\))?)", line):
                    meta.setdefault(m.group(1), m.group(2))
                continue
            f = line.split("\t")
            if cols is None:
                cols = f
                continue
            rows[f[0]] = dict(zip(cols, f))
    return meta, rows


def cmd_reserve(argv):
    flags = parse_flags(argv, ("--work", "--reserve", "--corpus"), (), ("--allow-review", "--allow-memorized"))
    work = flags.get("--work")
    ids = [x.strip() for x in (flags.get("--reserve") or "").split(",") if x.strip()]
    if not work or not ids:
        die(2, "reserve requires --work <dir> --reserve <id,id,...>")
    meta, report = read_report(work)
    cands = {}
    cpath = os.path.join(work, "candidates.tsv")
    if os.path.isfile(cpath):
        for f in read_tsv_lines(cpath):
            if f[0] != "id" and len(f) >= 8:
                cands[f[0]] = {"code_repo": f[6], "judging_repo": f[7]}
    corpus_ids, corpus_repos = load_corpus(flags.get("--corpus", os.path.join(HERE, "corpus.tsv")))
    allowed = {"CLEAN"} | ({"REVIEW"} if flags.get("--allow-review") else set())
    errors = []
    for i in ids:
        r = report.get(i)
        if r is None or i not in cands:
            errors.append("%s: unknown id (not in the report)" % i)
            continue
        status = r["status"]
        if status == "MEMORIZED":
            base = re.search(r"base=(\w+)", r.get("reason", ""))
            if not flags.get("--allow-memorized"):
                errors.append("%s: MEMORIZED (%s) — the model recalls its rare rows; pass --allow-memorized to "
                              "reserve it anyway" % (i, r.get("reason")))
                continue
            status = base.group(1) if base else "CLEAN"
        if status not in allowed:
            errors.append("%s: status %s is not reservable%s" % (i, status,
                          " (pass --allow-review)" if status == "REVIEW" else ""))
            continue
        if r.get("project_subdir", "-") == "-":
            errors.append("%s: no project root detected (project_subdir -)" % i)
            continue
        if i.lower() in corpus_ids or cands[i]["code_repo"].lower() in corpus_repos \
                or cands[i]["judging_repo"].lower() in corpus_repos:
            errors.append("%s: already in the corpus manifest" % i)
    if errors:
        for e in errors:
            sys.stderr.write("fresh-set: reserve refused — %s\n" % e)
        return 4
    lines = ["# fresh-set RESERVED manifest (#2263) — a sealed held-out set: keep it OUTSIDE the repo until the "
             "exam is consumed.",
             "# built=%s source=%s discovery=%s ledger=%s probe=%s"
             % (time.strftime("%Y-%m-%d", time.gmtime()), meta.get("source", "?"), meta.get("discovery", "?"),
                meta.get("ledger", "?"), meta.get("probe", "?")),
             "# corpus.tsv row format (id code_repo judging_repo project_subdir role); run it with "
             "run-corpus-bench.sh --work <work> --corpus <this file>."]
    for i in ids:
        r = report[i]
        lines.append("# lock %s code=%s judging=%s gt=%s rare=%s rare_loc=%s memo_rare=%s memo_cued=%s"
                     % (i, r["code_sha"], r["judging_sha"], r["gt"], r["rare"], r["rare_loc"], r["memo_rare"],
                        r["memo_cued"]))
    for i in ids:
        lines.append("\t".join((i, cands[i]["code_repo"], cands[i]["judging_repo"], report[i]["project_subdir"],
                                "holdout")))
    write_atomic(os.path.join(work, "RESERVED.tsv"), "\n".join(lines) + "\n")
    print("fresh-set: reserved %d contest(s) -> %s" % (len(ids), os.path.join(work, "RESERVED.tsv")))
    return 0


# ---- offline self-checks ---------------------------------------------------------------------------------------
class _Check:
    def __init__(self):
        self.fails = 0

    def __call__(self, cond, msg):
        print("  [%s] %s" % ("PASS" if cond else "FAIL", msg))
        if not cond:
            self.fails += 1


def cmd_selftest_listing(argv):
    check = _Check()
    page1 = []
    for n in range(PER_PAGE // 2):
        slug = "2099-%02d-fixture%02d" % (n % 12 + 1, n)
        page1.append({"name": slug, "owner": {"login": "fixture-org"}, "created_at": "2099-01-01T00:00:00Z"})
        page1.append({"name": slug + "-judging", "owner": {"login": "fixture-org"},
                      "created_at": "2099-02-01T00:00:00Z"})
    calls = []

    def stub(pages):
        def getter(url, headers):
            calls.append((url, dict(headers)))
            page = int(re.search(r"[?&]page=(\d+)", url).group(1))
            res = pages.get(page)
            if isinstance(res, Exception):
                raise res
            return res
        return getter

    limited = {1: (200, {}, json.dumps(page1).encode()),
               2: (403, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "4102444800"}, b"{}")}
    repos, state = fetch_listing("fixture-org", None, False, stub(limited), {})
    check(len(repos) == PER_PAGE and state.startswith("partial (rate-limited; resets 2100-01-01"),
          "403 + X-RateLimit-Remaining: 0 on page 2 -> discovery=%s, page-1 repos kept (%d)" % (state, len(repos)))
    check(len(pair_listing(repos, "fixture-org")) == PER_PAGE // 2,
          "the kept page-1 repos still pair into %d candidates" % (PER_PAGE // 2))
    check(all("Authorization" not in h for _u, h in calls), "no token in the env -> no Authorization header")
    calls.clear()
    fetch_listing("fixture-org", None, False, stub(limited), {"GH_TOKEN": "t0k"})
    check(calls and all(h.get("Authorization") == "Bearer t0k" for _u, h in calls),
          "GH_TOKEN set -> Authorization header on every request")
    calls.clear()
    fetch_listing("fixture-org", None, False, stub(limited), {"GITHUB_TOKEN": "t1k"})
    check(calls and all(h.get("Authorization") == "Bearer t1k" for _u, h in calls),
          "GITHUB_TOKEN is the fallback token")
    for label, res, want in (("HTTP 500", (500, {}, b""), "partial (http-500)"),
                             ("403 with quota left", (403, {"X-RateLimit-Remaining": "12"}, b""), "partial (http-403)"),
                             ("a network error", urllib.error.URLError("down"), "partial (network-error: URLError)"),
                             ("a non-JSON body", (200, {}, b"<html>"), "partial (bad-json)"),
                             ("a JSON object instead of an array", (200, {}, b"{}"), "partial (bad-json)")):
        repos, state = fetch_listing("fixture-org", None, False,
                                     stub({1: (200, {}, json.dumps(page1).encode()), 2: res}), {})
        check(state == want and len(repos) == PER_PAGE, "%s on page 2 -> %s, no crash" % (label, state))
    cache = tempfile.mkdtemp(prefix="fresh-set-cache-")
    try:
        full = {1: (200, {}, json.dumps(page1).encode()), 2: (200, {}, b"[]")}
        fetch_listing("fixture-org", cache, False, stub(full), {})
        calls.clear()
        repos, state = fetch_listing("fixture-org", cache, False, stub({}), {})
        check(not calls and state == "complete" and len(repos) == PER_PAGE,
              "a re-run is served from the page cache: 0 API calls")
        calls.clear()
        fetch_listing("fixture-org", cache, True, stub(full), {})
        check(len(calls) == 2, "--refresh-listing bypasses the cache")
    finally:
        shutil.rmtree(cache, ignore_errors=True)
    old = os.environ.get("FRESH_SET_OFFLINE")
    os.environ["FRESH_SET_OFFLINE"] = "1"
    try:
        tripped = []
        for fn, args in ((http_get, ("https://api.github.com/", {})), (git_net, (["clone", "x", "y"],)),
                         (call_backend, ("flat-cyborg", "m", "", "p"))):
            try:
                fn(*args)
            except NetworkTripwire:
                tripped.append(fn.__name__)
        check(tripped == ["http_get", "git_net", "call_backend"],
              "FRESH_SET_OFFLINE=1 trips HTTP, git clone and the LLM probe (%s)" % ",".join(tripped))
    finally:
        if old is None:
            os.environ.pop("FRESH_SET_OFFLINE", None)
        else:
            os.environ["FRESH_SET_OFFLINE"] = old
    return 1 if check.fails else 0


def cmd_selftest_probe(argv):
    check = _Check()

    def row(sev, rarity, title, sig="", loc=""):
        return {"sev_id": sev, "severity": "High", "rarity": rarity, "title": title, "signature": title + " -- " + sig,
                "locations": loc}

    rows = [row("H-1", 1, "Reentrant `claimRewards` in RewardVault pays out twice before the checkpoint update",
                loc="Vault.sol:claimRewards"),
            row("M-1", 5, "Stale exchange rate lets `sweepDust` round fee shares to zero"),
            row("M-2", 9, "Missing slippage bound on `deposit` lets a sandwich extract value")]
    _f, r = score_probe(rows, "FINDING|NONE\n")
    check([x["verdict"] for x in r] == ["no", "no", "no"], "FINDING|NONE -> every row `no`")
    _f, r = score_probe(rows, "")
    check([x["verdict"] for x in r] == ["no", "no", "no"], "an empty reply -> every row `no`")
    _f, r = score_probe(rows, "   FINDING|H|RewardVault|claimRewards|re-entrant claim pays out twice before the "
                              "checkpoint\n")
    check(r[0]["verdict"] == "yes", "a PTY-indented line naming the function + 2 mechanism words -> `yes`")
    _f, r = score_probe(rows, "FINDING|H|Oracle|-|a stale exchange rate rounds fee shares down to zero\n")
    check(r[1]["verdict"] == "no", "a mechanism-only resemblance (no name) -> `no`")
    _f, r = score_probe(rows, "FINDING|M|Pool|deposit|no slippage bound, so a sandwich bot extracts value\n")
    check(r[2]["verdict"] == "partial", "a GENERIC name (deposit) + mechanism is capped at `partial`")
    _f, r = score_probe(rows, "FINDING|M|Vault|sweepDust|sweepDust uses a stale value\n")
    check(r[1]["verdict"] == "partial", "a strong name + ONE mechanism word -> `partial`")
    dup = [rows[0], row("H-2", 1, "Reentrant `claimRewards` in RewardVault pays out twice before the checkpoint "
                                  "update (second copy)")]
    _f, r = score_probe(dup, "FINDING|H|RewardVault|claimRewards|re-entrant claim pays out twice before the "
                             "checkpoint\n")
    check(sorted(x["verdict"] for x in r) == ["no", "yes"], "one reply line credits at most ONE row")
    s = probe_summary(rows, [{"verdict": "yes"}, {"verdict": "no"}, {"verdict": "partial"}])
    check(s["verdict"] == "MEMORIZED" and s["rare_yes"] == 1 and s["rate"] == "0.33",
          "one rare row `yes` -> MEMORIZED, rate 0.33")
    meta = {"slug": "2099-01-alpha", "date": "2099-01", "platform": "Sherlock", "name": "Alpha Lending"}
    prompt = build_probe_prompt(meta)
    check(not prompt_leaks(prompt, rows) and "2099-01-alpha" in prompt and "Alpha Lending" in prompt,
          "the probe prompt names the contest and carries no code and no GT")
    for name, what in (("Stale exchange rate lets `sweepDust` round fee shares to zero", "a GT title"),
                       ("Vault.sol", "a .sol file name"), ("H-1 recap", "a GT finding id"),
                       ("claimRewards", "a GT location function")):
        leak = prompt_leaks(build_probe_prompt(dict(meta, name=name)), rows)
        check(bool(leak), "the leak guard refuses a prompt carrying %s (%s)" % (what, "; ".join(leak)))
    argv_fc = probe_argv("flat-cyborg", "some-model", "", "PROMPT")
    tail = argv_fc[argv_fc.index("--"):]
    check(argv_fc[0] == "flat-cyborg" and "--extract" in argv_fc and "--auto-approve" in argv_fc
          and argv_fc[argv_fc.index("--cmd") + 1] == "PROMPT"
          and tail[:4] == ["--", SANDBOX, "--model", "some-model"] and tail[4:6] == ["--tools", ""],
          "flat-cyborg argv: the hunt's sandboxed target, the --model pin, every tool switched off")
    check(not any("claude" == a or a == "-p" for a in argv_fc),
          "the probe never calls the bare claude binary or the metered print mode")
    # cued probe: batching, decoys, prompt hygiene.
    many = [row("%s-%d" % ("H" if n % 2 else "M", n), 1 + n % 4, "Synthetic finding number %d about accounting" % n,
                loc="Book.sol:settle%02d" % n) for n in range(45)]
    many.append(row("M-99", 3, "A finding without a resolvable location"))
    pool = [("Book", "settle07"), ("Book", "audit"), ("Ledger", "sync")]
    batches = cued_batches("2099-01-alpha", many, pool, 20)
    real = [it for items in batches for it in items if it["kind"] == "row"]
    decoys = [it for items in batches for it in items if it["kind"] == "decoy"]
    check(len(batches) == 3 and [sum(1 for it in b if it["kind"] == "row") for b in batches] == [20, 20, 5]
          and len(decoys) == 3 and len(real) == 45, "45 located rows -> batches of 20/20/5, one decoy each; the "
          "row without a location is not asked")
    check(batches == cued_batches("2099-01-alpha", many, pool, 20)
          and any(b[-1]["kind"] == "row" for b in batches), "batches are deterministic and the decoy is not "
          "always last")
    got_pool = decoy_pool(os.path.join(HERE, "fixtures", "fresh-set", "repos", "fixture-org", "2099-01-alpha"),
                          [row("H-1", 1, "Reentrant claimRewards payout", loc="Vault.sol:claimRewards"),
                           row("M-2", 7, "Missing slippage bound on `deposit()`")])
    check(got_pool == [("Vault", "pause")], "the decoy pool excludes every function a GT row names (%s)" % got_pool)
    cp = build_cued_prompt(meta, batches[0])
    check(not prompt_leaks(cp, many, cued=True) and "Book:settle" in cp and "Synthetic finding" not in cp,
          "a cued prompt carries the location cues and no title, id or .sol name")
    check(bool(prompt_leaks(build_cued_prompt(dict(meta, name=many[0]["title"]), batches[0]), many, cued=True)),
          "the cued leak guard still refuses a GT title")
    lines, cs = score_cued(many, batches[:1], ["\n".join("CUE|%s|YES|something happened" % it["label"]
                                                         for it in batches[0])], 0.25)
    check(cs["decoy_fp_rate"] == "1.00" and cs["yes"] == 0 and cs["verdict"] == "not-memorized",
          "YES to every cue without a mechanism: decoy_fp_rate 1.00, cued_recall 0 -> not MEMORIZED")
    return 1 if check.fails else 0


def main(argv):
    cmds = {"build": cmd_build, "reserve": cmd_reserve, "probe": cmd_probe,
            "selftest-listing": cmd_selftest_listing, "selftest-probe": cmd_selftest_probe}
    if len(argv) < 2 or argv[1] not in cmds:
        die(2, "usage: fresh-set.py {%s} [flags]" % "|".join(cmds))
    try:
        return cmds[argv[1]](argv[2:])
    except NetworkTripwire as e:
        sys.stderr.write("fresh-set.py: NETWORK TRIP-WIRE — FRESH_SET_OFFLINE=1 but the code reached: %s\n" % e)
        return 5


if __name__ == "__main__":
    sys.exit(main(sys.argv))
