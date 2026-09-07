#!/usr/bin/env bash
# watch-code-changes.sh — the code-CHANGE watcher (#2128, epic #2120 M1): a standalone (NOT sourcing
# freshness-watch/watch-competitions) READ-ONLY scan over the same Immunefi `bounties.json` the freshness-watch
# already fetches (245 programs), that surfaces a program whose CODE moved since the last run. It is the
# code-side sibling of watch-competitions.sh (which watches NEW competitions): here the targets are KNOWN
# programs and the signal is a change on one of two axes —
#   (1) GITHUB axis: the program's source repo HEAD sha and the tag set, read keyless via `git ls-remote`;
#   (2) IMPL axis:   an ERC-1967 implementation-slot pointer for a proxy address in `assets[].url`, read via
#                    `cast storage <addr> <impl-slot>` on a public RPC (with an `eth_getStorageAt` curl
#                    fallback when `cast` is absent). A moved impl pointer is exactly a proxy upgrade.
# The shell layer does all IO (the probes, the per-target state diff); ONE embedded python3 block does ALL
# JSON parse / target resolution / address+chain extraction — never shell JSON parsing (mirrors
# watch-competitions.sh). Reuse (not reinvent): the ERC-1967 IMPL_SLOT constant + first-token-lowercased read
# from run-live-watch.sh, the repo resolution (top-level githubUrl OR first github-looking assets[].url) and
# the 0x+40hex address validation idiom, the EVM ecosystem/language sets from run-immunefi-intake.sh, and the
# `--probe-cmd` mock seam from apply-audit-density.sh (so the demo drives `git ls-remote`/`cast` deterministically
# offline). Read-only / NEVER-SUBMIT: only `git ls-remote`, `cast storage`, or an `eth_getStorageAt` GET;
# no write beyond the local state dir. M2 (diff/scope-hint) and M3 (run-batch --change-triggered) consume
# `changes.tsv`.
#
# Usage: watch-code-changes.sh [--bounties-from <file>] [--state-dir <dir>] [--out <file>]
#                              [--probe-cmd "<cmd>"] [-h]
#   --bounties-from : the raw Immunefi bounties JSON (a top-level array). Default
#                      ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/freshness-watch/bounties.json. Unreadable -> exit 2.
#   --state-dir     : per-program state + outputs root (default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/
#                      change-watch). Holds state/<program-key>.state, changes.tsv, watch.log.
#   --out           : the change ledger path (default <state-dir>/changes.tsv). Append-only.
#   --probe-cmd     : the probe seam (a mock hatch for the offline demo). Invoked as
#                      `PROBE_KIND=lsremote PROBE_REPO=<repo> sh -c "<cmd>"` (must print raw `git ls-remote`
#                      lines) and `PROBE_KIND=impl PROBE_ADDR=<addr> PROBE_RPC=<rpc> PROBE_CHAIN=<chain>
#                      sh -c "<cmd>"` (must print the impl storage word). Default: the live git/cast probe.
#   -h/--help       : this header.
#
# changes.tsv SCHEMA (TAB-separated, one row per detected change; a `#` header is written on first create):
#   date  program  chain  kind(head|tag|impl)  repo_or_addr  old  new  githubUrl
#   - GITHUB-axis rows (kind head|tag) carry chain=`-`: a source change is chain-agnostic (a repo may deploy
#     to several chains), so a single chain would mislead. `-` is VALID here, not an error. When M2/M3 need a
#     chain hint for a github-triggered hunt they read program-level `ecosystem` from bounties.json keyed by
#     the row's `program` field.
#   - IMPL-axis rows (kind impl) DO carry the resolved chain (the change is on that specific chain).
#
# STATE (per program, <state-dir>/state/<program-key>.state, key `immunefi:<slug>`): TSV lines
#   kind<TAB>repo_or_addr<TAB>value — value = HEAD sha (head), sorted comma-joined tag set (tag), or the
#   impl word (impl). COLD-START at per-triple granularity: the first sight of a (kind,repo_or_addr) writes the
#   baseline and emits NOTHING; a row is emitted only when the state already holds a DIFFERENT non-empty value.
#   EMPTY/ALL-ZERO guard: a probe returning empty (unreachable RPC / dead repo) or an all-zero impl word
#   (0x000… = EOA / non-proxy) is skipped — never baselined, never an old->"" change — so a transient outage
#   cannot flap. Every item is `|| continue` so a single failure never aborts the sweep.
#
# Requires: python3 (the JSON layer). On the DEFAULT probe path: `git` for the github axis, and `cast` OR
# `curl` for the impl axis — a missing tool [SKIP]-logs THAT axis and the other proceeds. Exit 0 on success or
# a clean [SKIP]; 2 on bad/missing args.
set -u

DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "watch-code-changes.sh: $2 requires a value" >&2; exit 2; }; }

BOUNTIES_FROM="$DIR/freshness-watch/bounties.json"
STATE_DIR="$DIR/change-watch"
OUT=""
PROBE_CMD=""
while [ $# -gt 0 ]; do case "$1" in
  --bounties-from) nv "$#" "$1"; BOUNTIES_FROM="$2"; shift 2;;
  --state-dir)     nv "$#" "$1"; STATE_DIR="$2"; shift 2;;
  --out)           nv "$#" "$1"; OUT="$2"; shift 2;;
  --probe-cmd)     nv "$#" "$1"; PROBE_CMD="$2"; shift 2;;
  -h|--help)       sed -n '2,60p' "$0"; exit 0;;
  *) echo "watch-code-changes.sh: unknown arg: $1" >&2; exit 2;;
esac; done

[ -r "$BOUNTIES_FROM" ] || { echo "watch-code-changes.sh: --bounties-from <file> not readable: $BOUNTIES_FROM" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

# The canonical EIP-1967 IMPLEMENTATION slot (same constant run-live-watch.sh's fingerprint reads). A proxy
# whose impl pointer moves is exactly an upgrade — the drift tell.
IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"

# DEFAULT probe: the live git/cast reader. `--probe-cmd` (the demo) overrides this whole block, so the guards
# below only apply on this default path. `PROBE_RPC` is resolved by the shell loop from PROBE_CHAIN before the
# impl probe runs. On the impl path, prefer `cast storage`; fall back to a keyless `eth_getStorageAt` GET when
# `cast` is absent but `curl` is present.
USING_DEFAULT_PROBE=0
if [ -z "$PROBE_CMD" ]; then
  USING_DEFAULT_PROBE=1
  # shellcheck disable=SC2016  # a template: $PROBE_* expand later, inside `sh -c "$PROBE_CMD"`, not here.
  PROBE_CMD='
case "$PROBE_KIND" in
  lsremote) git ls-remote "$PROBE_REPO" ;;
  impl)
    if command -v cast >/dev/null 2>&1; then
      cast storage --rpc-url "$PROBE_RPC" "$PROBE_ADDR" "$PROBE_SLOT"
    elif command -v curl >/dev/null 2>&1; then
      _r="$(curl -sS --max-time 20 -H "content-type: application/json" \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getStorageAt\",\"params\":[\"$PROBE_ADDR\",\"$PROBE_SLOT\",\"latest\"]}" \
        "$PROBE_RPC" 2>/dev/null)"
      printf "%s" "$_r" | tr -d " \n" | sed -e "s/.*\"result\":\"//" -e "s/\".*//"
    fi
    ;;
esac'
fi

HAVE_GIT=0; command -v git >/dev/null 2>&1 && HAVE_GIT=1
HAVE_IMPL=0
{ command -v cast >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; } && HAVE_IMPL=1

[ -n "$OUT" ] || OUT="$STATE_DIR/changes.tsv"
mkdir -p "$STATE_DIR/state"
LOG="$STATE_DIR/watch.log"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[$now] watch-code-changes.sh run over $BOUNTIES_FROM" >> "$LOG"

# changes.tsv gets a one-time schema header (a `#` comment M2/M3 skip) so `-` in the chain column is documented
# in-band, next to the data.
if [ ! -e "$OUT" ]; then
  {
    echo "# watch-code-changes.sh ledger (#2128). TAB-separated. Columns:"
    echo "# date	program	chain	kind(head|tag|impl)	repo_or_addr	old	new	githubUrl"
    echo "# chain='-' on head|tag rows is VALID (a source change is chain-agnostic); M2/M3 read program"
    echo "# ecosystem from bounties.json keyed by the 'program' field for a chain hint. impl rows carry chain."
  } >> "$OUT"
fi

# --- ONE python3 block: parse bounties.json -> a per-target work-plan TSV (never shell JSON parsing) ---------
# Row: program<TAB>axis(lsremote|impl)<TAB>chain<TAB>repo_or_addr<TAB>githubUrl. Skips (no repo / no address /
# unmapped explorer domain) go to stderr, never abort. Address+chain extraction adds a most-specific-first
# explorer-domain map (optimistic.etherscan.io BEFORE etherscan.io) — neither reuse source had one.
PLAN="$(mktemp "${TMPDIR:-/tmp}/watch-code-changes-plan.XXXXXX")"
trap 'rm -f "$PLAN"' EXIT

python3 - "$BOUNTIES_FROM" "$PLAN" <<'PY'
import sys, json, re
from urllib.parse import urlparse

src, out = sys.argv[1], sys.argv[2]


def looks_like_repo(u):
    u = str(u or "").lower()
    return any(h in u for h in ("github.com", "bitbucket.org", "sourcehut.org", "sr.ht", "git."))


# EVM ecosystem/language sets, verbatim from run-immunefi-intake.sh — used only for a non-fatal cross-check
# note (ecosystem is program-level while an address is per-asset, so a mismatch is logged, never fatal).
EVM = {"ethereum", "arbitrum", "optimism", "base", "polygon", "matic", "bsc", "binance", "avalanche", "avax",
       "fantom", "gnosis", "xdai", "scroll", "linea", "zksync", "mantle", "blast", "mode", "celo", "moonbeam",
       "aurora", "metis", "fraxtal", "manta", "opbnb", "kava", "canto", "core", "sonic", "berachain"}
LANGS = {"solidity", "vyper", "yul"}

# Explorer host -> chain, MOST-SPECIFIC-FIRST: a subdomain like optimistic.etherscan.io MUST be tested before
# the bare etherscan.io, else an Optimism address would be mislabelled ethereum. Cross-checked against the
# EVM set above. A host not in this table is skipped cleanly (logged), never errored.
EXPLORERS = [
    ("optimistic.etherscan.io", "optimism"),
    ("etherscan.io", "ethereum"),
    ("bscscan.com", "bsc"),
    ("polygonscan.com", "polygon"),
    ("basescan.org", "base"),
    ("arbiscan.io", "arbitrum"),
    ("snowtrace.io", "avalanche"),
    ("snowscan.xyz", "avalanche"),
    ("gnosisscan.io", "gnosis"),
    ("lineascan.build", "linea"),
    ("scrollscan.com", "scroll"),
    ("era.zksync.network", "zksync"),
    ("explorer.zksync.io", "zksync"),
    ("celoscan.io", "celo"),
    ("moonscan.io", "moonbeam"),
    ("ftmscan.com", "fantom"),
    ("sonicscan.org", "sonic"),
]

ADDR_RE = re.compile(r"0x[0-9a-fA-F]{40}(?![0-9a-fA-F])")


def chain_for_host(host):
    host = (host or "").lower()
    for dom, chain in EXPLORERS:
        if host == dom or host.endswith("." + dom):
            return chain
    return ""


def as_list(v):
    if isinstance(v, list):
        return v
    if v in (None, ""):
        return []
    return [v]


def note(msg):
    sys.stderr.write("[SKIP] " + msg + "\n")


try:
    data = json.load(open(src, encoding="utf-8", errors="ignore"))
except Exception as e:
    sys.stderr.write("watch-code-changes.sh: cannot parse %s: %s\n" % (src, e))
    sys.exit(3)
if not isinstance(data, list):
    data = data.get("bounties") or data.get("data") or []

rows = []
for b in data:
    if not isinstance(b, dict):
        continue
    slug = str(b.get("slug") or b.get("id") or "").strip()
    if not slug:
        continue
    key = "immunefi:" + slug
    assets = as_list(b.get("assets"))
    ecos = [str(x).strip().lower() for x in as_list(b.get("ecosystem"))]
    langs = [str(x).strip().lower() for x in as_list(b.get("language"))]

    # (a) GITHUB axis: top-level githubUrl, else the first github-looking assets[].url (skip single-segment
    # org URLs handled by looks_like_repo needing a host match). chain='-' — a source change is chain-agnostic.
    repo = ""
    gh = b.get("githubUrl")
    if looks_like_repo(gh):
        repo = str(gh)
    if not repo:
        for a in assets:
            u = a.get("url") if isinstance(a, dict) else a
            if looks_like_repo(u):
                repo = str(u)
                break
    if repo:
        rows.append((key, "lsremote", "-", repo, repo))

    # (b) IMPL axis: every assets[].url carrying a 0x+40hex address on a MAPPED explorer host. Dedup per
    # (chain,address). A non-address URL (github/docs/IPFS) or an unmapped explorer domain is skipped cleanly.
    seen = set()
    is_evm = any(l in LANGS for l in langs) or any(any(e == k or k in e for k in EVM) for e in ecos)
    for a in assets:
        u = a.get("url") if isinstance(a, dict) else a
        if not u:
            continue
        u = str(u)
        # strip a #code / query fragment before matching (urlparse drops #fragment; keep the path+netloc).
        p = urlparse(u)
        m = ADDR_RE.search(p.path or "")
        if not m:
            # also tolerate an address that landed in the fragment (…/#code rarely carries it, but be safe).
            m = ADDR_RE.search(u)
            if not m:
                continue
        addr = m.group(0).lower()
        chain = chain_for_host(p.netloc)
        if not chain:
            note("%s: unmapped explorer domain for address asset: %s" % (key, u))
            continue
        tkey = (chain, addr)
        if tkey in seen:
            continue
        seen.add(tkey)
        if not is_evm:
            # non-fatal cross-check: the program declares no EVM ecosystem/language yet an EVM explorer
            # address was found. Emit it anyway (assets are per-asset, ecosystem is program-level).
            sys.stderr.write("[NOTE] %s: address on %s but program ecosystem is not EVM-tagged\n" % (key, chain))
        rows.append((key, "impl", chain, addr, repo or "-"))

    if not repo and not seen:
        note("%s: no resolvable repo and no address asset — skipped" % key)

with open(out, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write("\t".join(r) + "\n")
sys.stderr.write("[watch-code-changes] work-plan: %d target rows over %d programs\n" % (len(rows), len(data)))
PY

# publicnode RPC map (keyless public endpoints); an unmapped chain -> impl axis skipped (logged). Overridable
# per-run via --probe-cmd (the demo bypasses this entirely).
rpc_for_chain() {
  case "$1" in
    ethereum)  echo "https://ethereum-rpc.publicnode.com";;
    bsc)       echo "https://bsc-rpc.publicnode.com";;
    polygon)   echo "https://polygon-bor-rpc.publicnode.com";;
    base)      echo "https://base-rpc.publicnode.com";;
    arbitrum)  echo "https://arbitrum-one-rpc.publicnode.com";;
    optimism)  echo "https://optimism-rpc.publicnode.com";;
    avalanche) echo "https://avalanche-c-chain-rpc.publicnode.com";;
    gnosis)    echo "https://gnosis-rpc.publicnode.com";;
    linea)     echo "https://linea-rpc.publicnode.com";;
    scroll)    echo "https://scroll-rpc.publicnode.com";;
    zksync)    echo "https://zksync-rpc.publicnode.com";;
    celo)      echo "https://celo-rpc.publicnode.com";;
    fantom)    echo "https://fantom-rpc.publicnode.com";;
    sonic)     echo "https://sonic-rpc.publicnode.com";;
    *)         echo "";;
  esac
}

# state_get KEY KIND ROA -> the stored value (or empty). state_put rewrites the program's state file with the
# (KIND,ROA) line replaced/appended — small per-program files, so a full rewrite per triple stays cheap and
# order-independent.
state_file_for() { echo "$STATE_DIR/state/$1.state"; }

state_get() {
  _sf="$(state_file_for "$1")"
  [ -f "$_sf" ] || { echo ""; return; }
  awk -F'\t' -v k="$2" -v r="$3" '$1==k && $2==r {print $3; exit}' "$_sf"
}

state_put() {
  _sf="$(state_file_for "$1")"
  _tmp="$(mktemp "${TMPDIR:-/tmp}/wcc-state.XXXXXX")"
  if [ -f "$_sf" ]; then
    awk -F'\t' -v k="$2" -v r="$3" '!($1==k && $2==r)' "$_sf" > "$_tmp"
  fi
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "$_tmp"
  mv "$_tmp" "$_sf"
}

emit_change() {
  # $1 key $2 chain $3 kind $4 roa $5 old $6 new $7 githubUrl
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$OUT"
}

# apply a single (kind,roa) observation against state: baseline on first sight (emit nothing), else emit a
# change row on a DIFFERENT non-empty value. An empty new value was already guarded by the caller.
apply_obs() {
  # $1 key $2 chain $3 kind $4 roa $5 new $6 githubUrl
  _old="$(state_get "$1" "$3" "$4")"
  if [ -z "$_old" ]; then
    state_put "$1" "$3" "$4" "$5"
  elif [ "$_old" != "$5" ]; then
    emit_change "$1" "$2" "$3" "$4" "$_old" "$5" "$6"
    state_put "$1" "$3" "$4" "$5"
  fi
}

changes_before="$(grep -cv '^#' "$OUT" 2>/dev/null || true)"

while IFS="$(printf '\t')" read -r prog axis chain roa ghurl || [ -n "$prog" ]; do
  [ -n "$prog" ] || continue
  case "$axis" in
    lsremote)
      if [ "$USING_DEFAULT_PROBE" -eq 1 ] && [ "$HAVE_GIT" -ne 1 ]; then
        echo "[SKIP] git not installed — github axis for $prog ($roa)" >> "$LOG"; continue
      fi
      raw="$(PROBE_KIND=lsremote PROBE_REPO="$roa" sh -c "$PROBE_CMD" 2>/dev/null || :)"
      [ -n "$raw" ] || { echo "[SKIP] empty ls-remote for $prog ($roa)" >> "$LOG"; continue; }
      head_sha="$(printf '%s\n' "$raw" | awk -F'\t' '$2=="HEAD"{print $1; exit}' | tr '[:upper:]' '[:lower:]')"
      tags="$(printf '%s\n' "$raw" \
        | awk -F'\t' '$2 ~ /^refs\/tags\// {t=$2; sub(/\^\{\}$/,"",t); sub(/^refs\/tags\//,"",t); print t}' \
        | LC_ALL=C sort -u | paste -sd, - 2>/dev/null)"
      [ -n "$head_sha" ] && apply_obs "$prog" "-" "head" "$roa" "$head_sha" "$ghurl"
      [ -n "$tags" ] && apply_obs "$prog" "-" "tag" "$roa" "$tags" "$ghurl"
      ;;
    impl)
      if [ "$USING_DEFAULT_PROBE" -eq 1 ] && [ "$HAVE_IMPL" -ne 1 ]; then
        echo "[SKIP] no cast/curl — impl axis for $prog ($roa)" >> "$LOG"; continue
      fi
      rpc=""
      if [ "$USING_DEFAULT_PROBE" -eq 1 ]; then
        rpc="$(rpc_for_chain "$chain")"
        [ -n "$rpc" ] || { echo "[SKIP] no RPC mapped for chain $chain — impl axis for $prog ($roa)" >> "$LOG"; continue; }
      fi
      word="$(PROBE_KIND=impl PROBE_ADDR="$roa" PROBE_RPC="$rpc" PROBE_CHAIN="$chain" PROBE_SLOT="$IMPL_SLOT" \
        sh -c "$PROBE_CMD" 2>/dev/null | awk 'NR==1{print $1}' | tr '[:upper:]' '[:lower:]')"
      [ -n "$word" ] || { echo "[SKIP] empty impl read for $prog ($roa on $chain)" >> "$LOG"; continue; }
      # all-zero impl word = EOA / non-proxy: never baseline, never a change.
      _h="${word#0x}"; case "$_h" in *[!0]*) ;; *) echo "[SKIP] all-zero impl (non-proxy) for $prog ($roa)" >> "$LOG"; continue;; esac
      apply_obs "$prog" "$chain" "impl" "$roa" "$word" "$ghurl"
      ;;
  esac
done < "$PLAN"

changes_after="$(grep -cv '^#' "$OUT" 2>/dev/null || true)"
new_rows=$((changes_after - changes_before))
echo "[$now] done: $new_rows new change row(s) -> $OUT" >> "$LOG"
echo "watch-code-changes.sh: $new_rows new change row(s) -> $OUT" >&2
