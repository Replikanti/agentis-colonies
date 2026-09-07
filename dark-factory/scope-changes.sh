#!/usr/bin/env bash
# scope-changes.sh — the M2 DIFF-SCOPER (#2131, epic #2120 M2): a STATELESS transform that reads M1's
# `changes.tsv` (produced by watch-code-changes.sh, #2128) and emits ONE scope descriptor per change row —
# the args a scoped hunt needs so M3 hunts only the DELTA (the unaudited surface), not the whole protocol
# every time. It changes nothing downstream: the `--scope-hint`/`--since` seams already exist in
# run-zone-hunt.sh / map-zones.sh; M2 only PRODUCES the args.
#
# Per input row, branch on `kind`:
#   head : source-repo delta. base=`old` sha, head=`new` sha. A DIRECT two-ref diff (STOP-1 decision, #2131):
#          shallow-fetch BOTH refs into a scratch clone and run `git diff --name-only <old> <new>` directly —
#          no checkout, no HEAD-relative state (avoids the checkout-state risk audit-delta.sh's HEAD=new
#          contract carries; the empty-diff guard is replicated inline, it is trivial). The changed set is
#          filtered to Solidity (`*.sol` NOT under vendor/build/test dirs) and the mode decided:
#            scoped           — 1..N changed .sol files -> scope_hint_files = those files, since = old sha.
#            full  (by size)  — filtered count > --max-files (a big refactor is effectively new code); since = old.
#            full  (missing)  — old sha empty/`-` (first-seen / shallow gap) or a ref unfetchable; since = `-`.
#            skip             — the delta is docs/tests-only (no huntable .sol) -> nothing to hunt.
#   tag  : same source-repo-delta shape using the newest ADDED tag (set-diff new\old, first) as the head ref
#          and the most-recent prior tag (last of `old`) as the base ref. Either unresolvable -> full.
#   impl : an on-chain proxy upgrade. ALWAYS `full` (#2131 STOP-1): emit a full descriptor carrying the proxy
#          address + resolved chain + the NEW impl address (0x + last 40 hex of the impl storage word in the
#          `new` column). The new-impl source-pull (Sourcify/Blockscout) is DEFERRED to M3 (the stage that
#          runs the hunt); here the source probe is ADVISORY only (a `src:verified|src:unverified` log note,
#          NEVER gating — a full descriptor is emitted regardless).
# Unknown `kind` -> a [SKIP] log line. Every row is `|| continue`-resilient: one fetch/probe failure never
# aborts the sweep. NO LLM calls anywhere (so no #2125 sandbox wiring).
#
# Usage: scope-changes.sh [--changes-from <file>] [--out <file>] [--work-dir <dir>]
#                         [--max-files N] [--probe-cmd "<cmd>"] [-h]
#   --changes-from : M1's change ledger. Default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/change-watch/
#                     changes.tsv. Unreadable -> exit 2. `#`/blank lines are skipped.
#   --out          : the descriptor file. Default <dir>/change-watch/scope-descriptors.tsv. OVERWRITTEN each
#                     run (a pure function of the input, NOT an append ledger); descriptors also go to stdout.
#   --work-dir     : scratch root for the shallow clones (default a `mktemp -d`, trap-cleaned).
#   --max-files N  : the full-by-size threshold (default 25). A filtered .sol count above it -> `full`.
#   --probe-cmd    : the probe seam (a mock hatch for the offline demo; mirrors watch-code-changes.sh). When
#                     set it REPLACES the live fetch/diff and the source probe. Invoked as
#                       PROBE_KIND=diff   PROBE_REPO=<url> PROBE_OLD=<old> PROBE_NEW=<new> sh -c "<cmd>"
#                         -> must print the raw changed-file list (one path per line, pre-`.sol`-filter) and
#                            exit 0; a NON-ZERO exit signals the delta is unavailable (old/new unfetchable),
#                            degrading the row to `full`.
#                       PROBE_KIND=source PROBE_ADDR=<addr> PROBE_CHAIN=<chain> sh -c "<cmd>"
#                         -> must print `verified`/`unverified` (advisory only, never gates).
#   -h/--help      : this header.
#
# descriptor SCHEMA (TAB-separated, one row per input row; a `#` header is written on each create):
#   program  chain  kind(head|tag|impl)  repo_or_addr  new  scope_mode(scoped|full|skip)  scope_hint_files  since
#   - chain=`-` passes through for head/tag (a source change is chain-agnostic — M3 resolves it from
#     bounties.json `ecosystem` keyed by `program`, per M1's contract); impl carries the resolved chain.
#   - `new` = the new HEAD sha (head), the added tag (tag), or the new impl address (impl).
#   - `full` rows: scope_hint_files=`-`, since=old sha (full-by-size, keeps map-zones' advisory hardening
#     signal) OR `-` (full-by-missing-sha). `skip`/`impl` rows: scope_hint_files=`-`, since=`-`.
#
# Requires: git (default probe path only; --probe-cmd bypasses it). Read-only except the scratch clone. Exit
# 0 on success; 2 on bad/missing args.
set -u

DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise
# crash on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "scope-changes.sh: $2 requires a value" >&2; exit 2; }; }

CHANGES_FROM="$DIR/change-watch/changes.tsv"
OUT=""
WORK_DIR=""
MAX_FILES=25
PROBE_CMD=""
while [ $# -gt 0 ]; do case "$1" in
  --changes-from) nv "$#" "$1"; CHANGES_FROM="$2"; shift 2;;
  --out)          nv "$#" "$1"; OUT="$2"; shift 2;;
  --work-dir)     nv "$#" "$1"; WORK_DIR="$2"; shift 2;;
  --max-files)    nv "$#" "$1"; MAX_FILES="$2"; shift 2;;
  --probe-cmd)    nv "$#" "$1"; PROBE_CMD="$2"; shift 2;;
  -h|--help)      sed -n '2,74p' "$0"; exit 0;;
  *) echo "scope-changes.sh: unknown arg: $1" >&2; exit 2;;
esac; done

[ -r "$CHANGES_FROM" ] || { echo "scope-changes.sh: --changes-from <file> not readable: $CHANGES_FROM" >&2; exit 2; }
case "$MAX_FILES" in *[!0-9]*|"") echo "scope-changes.sh: --max-files must be a non-negative integer" >&2; exit 2;; esac

[ -n "$OUT" ] || OUT="$DIR/change-watch/scope-descriptors.tsv"

# scratch root for shallow clones (default probe path). A caller-supplied --work-dir is left in place; a
# mktemp'd one is trap-cleaned. The clones themselves live in per-row subdirs the default probe removes.
CLEAN_WORK=0
if [ -z "$WORK_DIR" ]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scope-changes.XXXXXX")"
  CLEAN_WORK=1
fi
mkdir -p "$WORK_DIR"

LOG_DIR="$(dirname "$OUT")"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/scope-changes.log"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[$now] scope-changes.sh run over $CHANGES_FROM (max-files=$MAX_FILES)" >> "$LOG"
log() { echo "$*" >> "$LOG"; }

cleanup() { [ "$CLEAN_WORK" -eq 1 ] && rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# DEFAULT probe: the live git reader (diff) + a keyless Sourcify availability check (source). `--probe-cmd`
# (the demo) overrides this whole block. The diff branch does the STOP-1 DIRECT two-ref diff: shallow-fetch
# BOTH refs into a scratch clone, capture the NEW sha before the OLD fetch overwrites FETCH_HEAD, then
# `git diff --name-only <old> <new>` (two arbitrary commits — no merge-base, no checkout). Exit codes signal
# the caller: 0 = a clean diff (possibly empty), 3 = old unfetchable, 4 = new unfetchable, 5 = setup failure.
if [ -z "$PROBE_CMD" ]; then
  # shellcheck disable=SC2016  # a template: $PROBE_* expand later, inside `sh -c "$PROBE_CMD"`, not here.
  PROBE_CMD='
case "$PROBE_KIND" in
  diff)
    _d="$(mktemp -d "${PROBE_WORK:-${TMPDIR:-/tmp}}/scope-diff.XXXXXX")" || exit 5
    git -C "$_d" init -q 2>/dev/null || { rm -rf "$_d"; exit 5; }
    git -C "$_d" remote add origin "$PROBE_REPO" 2>/dev/null || { rm -rf "$_d"; exit 5; }
    if ! git -C "$_d" fetch --depth 1 -q origin "$PROBE_NEW" 2>/dev/null; then rm -rf "$_d"; exit 4; fi
    _new="$(git -C "$_d" rev-parse FETCH_HEAD 2>/dev/null)"
    if ! git -C "$_d" fetch --depth 1 -q origin "$PROBE_OLD" 2>/dev/null; then rm -rf "$_d"; exit 3; fi
    _old="$(git -C "$_d" rev-parse FETCH_HEAD 2>/dev/null)"
    git -C "$_d" diff --name-only "$_old" "$_new" 2>/dev/null
    _rc=$?
    rm -rf "$_d"
    exit $_rc
    ;;
  source)
    _cid=""
    case "$PROBE_CHAIN" in
      ethereum) _cid=1;;   optimism) _cid=10;;    bsc) _cid=56;;      polygon) _cid=137;;
      base) _cid=8453;;    arbitrum) _cid=42161;; avalanche) _cid=43114;; gnosis) _cid=100;;
      *) _cid="";;
    esac
    [ -n "$_cid" ] || { echo unverified; exit 0; }
    if command -v curl >/dev/null 2>&1 \
       && curl -sS --max-time 15 "https://sourcify.dev/server/v2/contract/$_cid/$PROBE_ADDR?fields=abi" 2>/dev/null \
          | grep -q "\"abi\""; then
      echo verified
    else
      echo unverified
    fi
    ;;
esac'
fi

# The Solidity + scope filter (NEW): keep only `*.sol` NOT under a vendor/build/test directory. Extends
# map-zones.sh's prune list (lib/node_modules/out/cache/artifacts) with test/tests/script/mocks so a
# tests-only diff drops out to `skip` rather than spawning a spurious hunt.
filter_sol() {
  grep -E '\.sol$' 2>/dev/null \
    | grep -Ev '(^|/)(lib|node_modules|out|cache|artifacts|test|tests|script|mocks)/' 2>/dev/null || true
}

# descriptor emitter: the 8-column schema, to $OUT (append after the run's header) AND stdout.
emit_desc() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" | tee -a "$OUT"
}

# added_tag OLDSET NEWSET -> the first tag present in NEWSET but not in OLDSET (comma-joined sets, M1's shape).
added_tag() {
  _old=",$1,"
  printf '%s' "$2" | tr ',' '\n' | while IFS= read -r _t; do
    [ -n "$_t" ] || continue
    case "$_old" in *",$_t,"*) ;; *) printf '%s\n' "$_t";; esac
  done | head -n1
}

# last_tag OLDSET -> the most-recent prior tag (last comma element), or empty for an empty/`-` set.
last_tag() {
  case "$1" in ""|"-") return;; esac
  printf '%s' "$1" | tr ',' '\n' | grep -v '^$' | tail -n1
}

# scope_row PROGRAM CHAIN KIND ROA NEWCOL BASE HEADREF — the shared source-repo-delta path (head + tag).
# Decides scoped / full-by-size / full-by-missing-sha / skip from the DIRECT two-ref diff (via the seam).
scope_row() {
  _prog="$1"; _chain="$2"; _kind="$3"; _roa="$4"; _newcol="$5"; _base="$6"; _headref="$7"
  if [ -z "$_base" ] || [ "$_base" = "-" ]; then
    emit_desc "$_prog" "$_chain" "$_kind" "$_roa" "$_newcol" full - -
    log "[full] $_prog ($_kind $_roa): base ref unavailable -> full-scope hunt (full-by-missing-sha)"
    return
  fi
  if [ -z "$_headref" ] || [ "$_headref" = "-" ]; then
    emit_desc "$_prog" "$_chain" "$_kind" "$_roa" "$_newcol" full - -
    log "[full] $_prog ($_kind $_roa): head ref unavailable -> full-scope hunt (full-by-missing-sha)"
    return
  fi
  _files="$(PROBE_KIND=diff PROBE_REPO="$_roa" PROBE_OLD="$_base" PROBE_NEW="$_headref" \
            PROBE_WORK="$WORK_DIR" sh -c "$PROBE_CMD")" ; _prc=$?
  if [ "$_prc" -ne 0 ]; then
    emit_desc "$_prog" "$_chain" "$_kind" "$_roa" "$_newcol" full - -
    log "[full] $_prog ($_kind $_roa): diff unavailable (probe rc $_prc) -> full-scope hunt (full-by-missing-sha)"
    return
  fi
  _sols="$(printf '%s\n' "$_files" | filter_sol)"
  _n="$(printf '%s\n' "$_sols" | grep -c . || true)"
  if [ "$_n" -eq 0 ]; then
    emit_desc "$_prog" "$_chain" "$_kind" "$_roa" "$_newcol" skip - -
    log "[skip] $_prog ($_kind $_roa): no huntable .sol in the delta (docs/tests only)"
  elif [ "$_n" -gt "$MAX_FILES" ]; then
    emit_desc "$_prog" "$_chain" "$_kind" "$_roa" "$_newcol" full - "$_base"
    log "[full] $_prog ($_kind $_roa): $_n changed .sol > $MAX_FILES -> full-scope hunt (full-by-size, since=$_base)"
  else
    _hint="$(printf '%s\n' "$_sols" | grep -v '^$' | paste -sd, -)"
    emit_desc "$_prog" "$_chain" "$_kind" "$_roa" "$_newcol" scoped "$_hint" "$_base"
    log "[scoped] $_prog ($_kind $_roa): $_n changed .sol -> scoped hunt (since=$_base)"
  fi
}

# --- write the descriptor file header (OVERWRITE each run — a pure function of the input) -------------------
{
  echo "# scope-changes.sh descriptors (#2131, epic #2120 M2). TAB-separated. One row per changes.tsv row."
  printf '# program\tchain\tkind(head|tag|impl)\trepo_or_addr\tnew\tscope_mode(scoped|full|skip)\tscope_hint_files\tsince\n'
  echo "# chain='-' passes through for head|tag (source change is chain-agnostic; M3 resolves it from"
  echo "# bounties.json ecosystem keyed by program). full-by-size keeps since=old; full-by-missing-sha/skip/impl"
  echo "# carry since='-'. impl: repo_or_addr=proxy, new=new impl address; source-pull is deferred to M3."
} > "$OUT"

rows_before=0

# Read M1's 8 columns (date program chain kind repo_or_addr old new githubUrl) with a TAB IFS (per
# watch-code-changes.sh). Skip `#`/blank lines. Every row is `|| continue`-resilient.
# shellcheck disable=SC2034  # ghurl (M1 col 8) is captured only to keep the field split correct; unused here.
while IFS="$(printf '\t')" read -r _date prog chain kind roa old new ghurl || [ -n "$_date" ]; do
  case "$_date" in ''|'#'*) continue;; esac
  [ -n "$prog" ] || continue
  : "${chain:=-}" ; : "${kind:=}" ; : "${roa:=}" ; : "${old:=}" ; : "${new:=}"
  case "$kind" in
    head)
      scope_row "$prog" "$chain" head "$roa" "$new" "$old" "$new" || continue
      ;;
    tag)
      _added="$(added_tag "$old" "$new")"
      _base="$(last_tag "$old")"
      scope_row "$prog" "$chain" tag "$roa" "${_added:--}" "${_base:--}" "${_added:--}" || continue
      ;;
    impl)
      # New impl ADDRESS = 0x + last 40 hex of the impl storage word (M1's `new` for an impl row). An
      # all-zero / short word degrades cleanly to a bare `-` address (still a `full` descriptor).
      _hex="$(printf '%s' "${new#0x}" | tr -cd '0-9a-fA-F' | tr 'A-F' 'a-f')"
      _addr40="$(printf '%s' "$_hex" | tail -c 40)"
      case "$_addr40" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
          _impl="0x$_addr40";;
        *) _impl="-";;
      esac
      # ADVISORY source-availability note (never gates; a full descriptor is emitted regardless). The actual
      # new-impl source-pull is DEFERRED to M3.
      _src="$(PROBE_KIND=source PROBE_ADDR="$_impl" PROBE_CHAIN="$chain" sh -c "$PROBE_CMD" 2>/dev/null \
              | awk 'NR==1{print $1}')"
      case "$_src" in verified) _srcnote="src:verified";; *) _srcnote="src:unverified";; esac
      emit_desc "$prog" "$chain" impl "$roa" "$_impl" full - -
      log "[full] $prog (impl $roa on $chain): new impl $_impl $_srcnote -> full-scope hunt of new impl source (source-pull deferred to M3)"
      ;;
    *)
      log "[SKIP] $prog: unknown kind '$kind' ($roa)"
      continue
      ;;
  esac
done < "$CHANGES_FROM"

rows_after="$(grep -cv '^#' "$OUT" 2>/dev/null || true)"
emitted=$((rows_after - rows_before))
echo "[$now] done: $emitted descriptor(s) -> $OUT" >> "$LOG"
echo "scope-changes.sh: $emitted descriptor(s) -> $OUT" >&2
