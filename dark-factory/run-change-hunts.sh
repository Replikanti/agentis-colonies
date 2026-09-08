#!/usr/bin/env bash
# run-change-hunts.sh — the M3 CHANGE-TRIGGERED HUNT consumer (#2133, epic #2120 M3: first-on-fresh-code). It
# ties M1 (#2128 code-change watcher) + M2 (#2131 diff-scoper) to the PROVEN hunt pipeline: for each M2 scope
# descriptor it materializes the target at the NEW code, runs the REAL adversarial hunt over the DELTA, hunts
# each change AT MOST ONCE (deduped by `(program, new)`), and stages any finding through the pipeline's own
# never-submit gate. It EDITS none of the heavy machinery — it only maps a descriptor row into an invocation:
#
#   scope-descriptors.tsv row  ->  materialize target@new  ->  run-zone-hunt.sh --repo <clone> [--scope-hint ..]
#                                                              (which itself -> map-zones/gen-briefs/discovery/
#                                                               verify -> per finding: run-audit-pass ->
#                                                               deliver-submission.sh, the baked-in never-submit
#                                                               human gate). Outcome appended to the change ledger.
#
# REUSE MAP (this script reinvents nothing):
#   run-zone-hunt.sh       — the capstone end-to-end hunt (breadth + optional --deep-hunt), invoked as-is.
#   fetch-target.sh        — the dep-aware clone for a source-repo change (head/tag).
#   recon-from-address.sh's keyless Sourcify-v2 idiom — the default impl source-pull (flat `.sol`).
#   deliver-submission.sh  — reached TRANSITIVELY through run-zone-hunt.sh; the never-submit human gate that
#                            REFUSES (exit 3) any draft lacking SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW and only
#                            STAGES marked drafts into a local drop-dir. This script adds ZERO egress path.
#
# SANDBOX (#2125) + REFUSAL-FALLBACK (#2133) — inherited STRUCTURALLY, no re-wiring here:
#   * bwrap sandbox: run-zone-hunt.sh's substrate emitters (map-zones/gen-briefs/run-discovery/run-invariant-
#     hunt) each set HUNT_SANDBOX_REPO/HUNT_SANDBOX_RUN + emit `llm.flat_cyborg.target = lib/claude-sandboxed.sh`,
#     so a change-triggered hunt is sandboxed byte-for-byte like any other `--backend flat-cyborg` hunt.
#   * CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1: run-zone-hunt.sh exports it near its top (guarded), so M3 inherits
#     fail-visible-on-refusal for free — no export is needed here.
#
# NO IMPLICIT FLEET SWEEP (limit-safety, the M3 scope guard): this script NEVER reads bounties.json and NEVER
# invokes watch-code-changes.sh/scope-changes.sh — it consumes ONLY the descriptors file it is handed. It runs
# rows SERIALLY (no backgrounding), has NO cron/scheduling, and caps work at `--max-hunts N` (DEFAULT 1 — the
# milestone proves the capability on ONE target; skips + already-ledgered rows do NOT count against the cap).
# Hunting more than one change per run requires raising `--max-hunts` explicitly. The cadence + concurrency +
# LLM budget + the live 245-program fleet sweep is M4.
#
# Usage: run-change-hunts.sh [--descriptors-from <file>] [--ledger <file>] [--max-hunts N] [--out <dir>]
#                            [--work-dir <dir>] [--drop-dir <dir>] [--backend <b>] [--agentis <bin>]
#                            [--model <id>] [--hunt-cmd "<cmd>"] [--source-cmd "<cmd>"] [-h]
#   --descriptors-from : M2's descriptor file. Default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/change-watch/
#                        scope-descriptors.tsv. Missing/empty/unreadable -> clean [SKIP] exit 0 (CI-safe,
#                        mirroring run-batch.sh). `#`/blank lines are skipped.
#   --ledger           : the change-key dedup ledger. Default <dir>/change-watch/hunted-changes.tsv. Appended
#                        (never overwritten) — it is the resumable checkpoint keyed by `(program, new)`.
#   --max-hunts N      : hunt at most N changes this run (DEFAULT 1). Alias --budget. Skips + already-ledgered
#                        rows do NOT count.
#   --out              : per-run output root (default $PWD/change-hunt-out); each hunt lands in <out>/<slug>.
#   --work-dir         : scratch root for the materialized clones (default a `mktemp -d`, trap-cleaned).
#   --drop-dir         : the never-submit drop-dir forwarded to run-zone-hunt.sh (default <out>/drop).
#   --backend          : LLM backend forwarded to run-zone-hunt.sh (default flat-cyborg).
#   --agentis / --model: forwarded to run-zone-hunt.sh when set.
#   --hunt-cmd "<cmd>" : OVERRIDE seam (the offline demo hatch, mirrors run-batch.sh --hunt-cmd). When set it
#                        REPLACES the run-zone-hunt.sh call and is invoked as `sh -c "<cmd>"` with
#                        CHANGE_PROGRAM / CHANGE_NEW / CHANGE_REPO / CHANGE_SCOPE_MODE / CHANGE_SCOPE_HINT /
#                        CHANGE_SINCE / CHANGE_OUT / CHANGE_DROP_DIR in env. Default = the real run-zone-hunt.sh.
#   --source-cmd "<cmd>" : OVERRIDE seam for target MATERIALIZATION (mirrors scope-changes.sh --probe-cmd).
#                        When set it REPLACES the default clone/source-pull and is invoked as `sh -c "<cmd>"`
#                        with MAT_KIND(clone|source) / MAT_REPO / MAT_ADDR / MAT_REF / MAT_CHAIN / MAT_DEST in
#                        env; it MUST populate MAT_DEST and exit 0 (a non-zero exit -> materialize-error). The
#                        default: head/tag -> fetch-target.sh (dep-aware clone, ref-pinned); impl -> keyless
#                        Sourcify-v2 source pull (flat `.sol`). LIMITATION (M3): an impl upgrade materializes
#                        as FLAT `.sol`, not a buildable Foundry project — breadth (map/discovery) reads it
#                        fine, but run-zone-hunt.sh's --deep-hunt self-skips a non-Foundry target. A real
#                        buildable-impl reconstruction is deferred (M4+).
#   -h/--help          : this header.
#
# descriptor SCHEMA consumed (M2's #2131 output, TAB-separated):
#   program  chain  kind(head|tag|impl)  repo_or_addr  new  scope_mode(scoped|full|skip)  scope_hint_files  since
#   - `-` is M2's "unavailable" sentinel for scope_hint_files/since; it is NEVER forwarded as a real flag value.
#
# ledger SCHEMA (TAB-separated, appended one row per processed change):
#   program  new  verdict(finding|clean|skipped-nohunt|materialize-error|hunt-error)  timestamp
#
# Requires: bash + git (default materialize path only; --source-cmd bypasses it). This script NEVER contacts a
# bounty platform to submit — a staged finding is a LEAD a human reviews + files. Exit 0 on success OR a clean
# [SKIP]; exit 2 on bad/missing args.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise
# crash on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "run-change-hunts.sh: $2 requires a value" >&2; exit 2; }; }

DESCRIPTORS="$DIR/change-watch/scope-descriptors.tsv"
LEDGER="$DIR/change-watch/hunted-changes.tsv"
MAX_HUNTS=1
OUT="$PWD/change-hunt-out"
WORK_DIR=""
DROP_DIR=""
BACKEND="flat-cyborg"
AGENTIS=""
MODEL=""
HUNT_CMD=""
SOURCE_CMD=""
while [ $# -gt 0 ]; do case "$1" in
  --descriptors-from) nv "$#" "$1"; DESCRIPTORS="$2"; shift 2;;
  --ledger)           nv "$#" "$1"; LEDGER="$2"; shift 2;;
  --max-hunts|--budget) nv "$#" "$1"; MAX_HUNTS="$2"; shift 2;;
  --out)              nv "$#" "$1"; OUT="$2"; shift 2;;
  --work-dir)         nv "$#" "$1"; WORK_DIR="$2"; shift 2;;
  --drop-dir)         nv "$#" "$1"; DROP_DIR="$2"; shift 2;;
  --backend)          nv "$#" "$1"; BACKEND="$2"; shift 2;;
  --agentis)          nv "$#" "$1"; AGENTIS="$2"; shift 2;;
  --model)            nv "$#" "$1"; MODEL="$2"; shift 2;;
  --hunt-cmd)         nv "$#" "$1"; HUNT_CMD="$2"; shift 2;;
  --source-cmd)       nv "$#" "$1"; SOURCE_CMD="$2"; shift 2;;
  -h|--help)          sed -n '2,86p' "$0"; exit 0;;
  *) echo "run-change-hunts.sh: unknown arg: $1" >&2; exit 2;;
esac; done

case "$MAX_HUNTS" in *[!0-9]*|"") echo "run-change-hunts.sh: --max-hunts must be a non-negative integer" >&2; exit 2;; esac
[ -n "$DROP_DIR" ] || DROP_DIR="$OUT/drop"

# Empty / missing / unreadable descriptors -> nothing to do (CI-safe; [SKIP] to stderr, mirroring run-batch.sh).
if [ ! -s "$DESCRIPTORS" ]; then
  echo "[SKIP] no descriptors at $DESCRIPTORS (run scope-changes.sh first) — nothing to hunt" >&2
  exit 0
fi

# scratch root for the materialized clones. A caller-supplied --work-dir is left in place; a mktemp'd one is
# trap-cleaned. (The OUT / drop-dir are deliberately NOT cleaned — they carry the run artifacts + staged leads.)
CLEAN_WORK=0
if [ -z "$WORK_DIR" ]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run-change-hunts.XXXXXX")"
  CLEAN_WORK=1
fi
mkdir -p "$WORK_DIR" "$OUT"
cleanup() { [ "$CLEAN_WORK" -eq 1 ] && rm -rf "$WORK_DIR"; }
trap cleanup EXIT

mkdir -p "$(dirname "$LEDGER")"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
LOG="$OUT/run-change-hunts.log"
now="$(ts)"
echo "[$now] run-change-hunts.sh over $DESCRIPTORS (max-hunts=$MAX_HUNTS, backend=$BACKEND)" >> "$LOG"
log() { echo "$*" >> "$LOG"; }

TAB="$(printf '\t')"

# True if `(program, new)` (cols 1,2) already has a ledger row -> already hunted OR ledgered-skip -> never
# re-hunt (resumable + dedup; the run-batch.sh ledger_has idiom, extended to the compound change key).
ledger_has() { # $1 = program, $2 = new
  [ -f "$LEDGER" ] && cut -f1,2 "$LEDGER" 2>/dev/null | grep -qxF "$1$TAB$2"
}
# Append the outcome to the change ledger (the dedup checkpoint).
record() { # $1 = program, $2 = new, $3 = verdict
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(ts)" >> "$LEDGER"
}
# Count staged submission packages under the drop-dir (a package == a manifest.json). Verdict is derived from
# the BEFORE/AFTER delta because run-zone-hunt.sh exits 0 even when it staged a finding.
pkg_count() { [ -d "$DROP_DIR" ] && find "$DROP_DIR" -name manifest.json 2>/dev/null | grep -c . || echo 0; }

# filesystem-safe slug for the per-hunt out/work dir (from program + a short new-ref tag).
slugify() { printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-*//;s/-*$//'; }

# DEFAULT materialize (the live path; --source-cmd overrides this whole block). Prints the materialized dir on
# stdout + exits 0, else non-zero. head/tag -> a dep-aware clone pinned at the new ref; impl -> a keyless
# Sourcify-v2 flat-`.sol` source pull (the recon-from-address.sh idiom, fields=source).
default_materialize() { # env: MAT_KIND MAT_REPO MAT_ADDR MAT_REF MAT_CHAIN MAT_DEST
  case "$MAT_KIND" in
    clone)
      [ -n "$MAT_REPO" ] && [ "$MAT_REPO" != "-" ] || return 1
      "$HERE/fetch-target.sh" "$MAT_REPO" "$MAT_DEST" >/dev/null 2>&1 || return 1
      # Pin the exact new ref when the cloned default tip is not already it (best-effort: a watch-time head sha
      # is normally the default-branch tip, so the shallow clone already IS `new`; a tag/older sha is fetched).
      if [ -n "$MAT_REF" ] && [ "$MAT_REF" != "-" ]; then
        if ! git -C "$MAT_DEST" cat-file -e "${MAT_REF}^{commit}" 2>/dev/null; then
          git -C "$MAT_DEST" fetch --depth 1 -q origin "$MAT_REF" 2>/dev/null || true
        fi
        git -C "$MAT_DEST" checkout -q "$MAT_REF" 2>/dev/null \
          || git -C "$MAT_DEST" checkout -q FETCH_HEAD 2>/dev/null || true
      fi
      printf '%s\n' "$MAT_DEST"
      ;;
    source)
      case "$MAT_ADDR" in 0x*) :;; *) return 1;; esac
      command -v python3 >/dev/null 2>&1 || return 1
      mkdir -p "$MAT_DEST" || return 1
      # Keyless Sourcify v2 `fields=source` -> flat `.sol` files into MAT_DEST. Non-verified / any error -> 1.
      MAT_ADDR="$MAT_ADDR" MAT_CHAIN="$MAT_CHAIN" MAT_DEST="$MAT_DEST" python3 -c '
import os, json, urllib.request, re
addr, chain, dest = os.environ["MAT_ADDR"], os.environ["MAT_CHAIN"] or "1", os.environ["MAT_DEST"]
cids = {"ethereum":"1","optimism":"10","bsc":"56","polygon":"137","base":"8453",
        "arbitrum":"42161","avalanche":"43114","gnosis":"100"}
cid = cids.get(chain, chain)
url = "https://sourcify.dev/server/v2/contract/%s/%s?fields=source" % (cid, addr)
try:
    with urllib.request.urlopen(url, timeout=25) as r:
        d = json.load(r)
except Exception as e:
    raise SystemExit("source-pull failed: %s" % e)
srcs = d.get("sources") or {}
if not srcs:
    raise SystemExit("not verified on Sourcify (no source)")
n = 0
for path, ent in srcs.items():
    content = ent.get("content") if isinstance(ent, dict) else ent
    if content is None:
        continue
    safe = re.sub(r"[^A-Za-z0-9._/-]", "_", path).lstrip("/")
    out = os.path.join(dest, safe)
    os.makedirs(os.path.dirname(out) or dest, exist_ok=True)
    with open(out, "w") as f:
        f.write(content)
    n += 1
if n == 0:
    raise SystemExit("no source files materialized")
' >/dev/null 2>&1 || return 1
      printf '%s\n' "$MAT_DEST"
      ;;
    *) return 1;;
  esac
}

# Run the materialize seam (default or --source-cmd) -> echo the materialized dir, or non-zero on failure.
materialize() { # $1=kind $2=repo_or_addr $3=new $4=chain $5=dest
  local mk mrepo maddr
  case "$1" in
    head|tag) mk=clone; mrepo="$2"; maddr="";;
    # impl: repo_or_addr ($2) is the PROXY; the source we want is the NEW IMPL address ($3, M2's `new` col).
    impl)     mk=source; mrepo=""; maddr="$3";;
    *) return 1;;
  esac
  if [ -n "$SOURCE_CMD" ]; then
    MAT_KIND="$mk" MAT_REPO="$mrepo" MAT_ADDR="$maddr" MAT_REF="$3" MAT_CHAIN="$4" MAT_DEST="$5" \
      sh -c "$SOURCE_CMD"
  else
    MAT_KIND="$mk" MAT_REPO="$mrepo" MAT_ADDR="$maddr" MAT_REF="$3" MAT_CHAIN="$4" MAT_DEST="$5" \
      default_materialize
  fi
}

hunts_done=0
skipped=0
staged=0

# Read M2's 8 descriptor columns with a TAB IFS. Skip `#`/blank lines. Every row is `|| continue`-resilient:
# one materialize/hunt failure never aborts the sweep.
while IFS="$TAB" read -r program chain kind roa new scope_mode hint since || [ -n "${program:-}" ]; do
  case "$program" in ''|'#'*) continue;; esac
  : "${chain:=-}" ; : "${kind:=}" ; : "${roa:=}" ; : "${new:=}" ; : "${scope_mode:=}" ; : "${hint:=}" ; : "${since:=}"

  # Dedup gate — the change key is (program, new). Already-ledgered (hunted OR skip-seen) -> never re-hunt.
  if ledger_has "$program" "$new"; then
    skipped=$((skipped + 1))
    echo "run-change-hunts: skip (already ledgered): $program @ $new" >&2
    log "[skip-ledgered] $program @ $new"
    continue
  fi

  # A `skip` descriptor (docs/tests-only delta) is ledgered as SEEN, never hunted.
  if [ "$scope_mode" = "skip" ]; then
    record "$program" "$new" "skipped-nohunt"
    echo "run-change-hunts: $program @ $new -> skip descriptor (nothing huntable), ledgered as seen" >&2
    log "[skipped-nohunt] $program @ $new"
    continue
  fi

  # Budget: skips + already-ledgered rows did NOT get here, so the cap counts only real hunt attempts.
  if [ "$hunts_done" -ge "$MAX_HUNTS" ]; then
    echo "run-change-hunts: reached --max-hunts $MAX_HUNTS; re-run to continue (resumable via the ledger)" >&2
    log "[budget] reached --max-hunts $MAX_HUNTS; stopping"
    break
  fi
  hunts_done=$((hunts_done + 1))

  slug="$(slugify "$program")-$(printf '%s' "$new" | tail -c 12 | tr -cs 'A-Za-z0-9._-' '-')"
  clone="$WORK_DIR/$slug"
  hunt_out="$OUT/$slug"

  # Materialize the target at the NEW code.
  target="$(materialize "$kind" "$roa" "$new" "$chain" "$clone")" || {
    record "$program" "$new" "materialize-error"
    echo "run-change-hunts: $program @ $new -> materialize failed ($kind $roa) — ledgered materialize-error" >&2
    log "[materialize-error] $program @ $new ($kind $roa)"
    continue
  }

  # Build the run-zone-hunt.sh argv. --scope-hint only for scoped; --since only when it is a real ref (never
  # forward M2's `-` sentinel as a flag value).
  hunt_args=(--repo "$target" --out "$hunt_out" --drop-dir "$DROP_DIR" --backend "$BACKEND")
  [ -n "$AGENTIS" ] && hunt_args+=(--agentis "$AGENTIS")
  [ -n "$MODEL" ] && hunt_args+=(--model "$MODEL")
  if [ "$scope_mode" = "scoped" ] && [ -n "$hint" ] && [ "$hint" != "-" ]; then
    hunt_args+=(--scope-hint "$hint")
  fi
  if [ -n "$since" ] && [ "$since" != "-" ]; then
    hunt_args+=(--since "$since")
  fi

  before="$(pkg_count)"
  echo "run-change-hunts: hunting $program @ $new ($scope_mode; $kind) -> $hunt_out ..." >&2
  log "[hunt] $program @ $new ($scope_mode $kind) repo=$target hint=${hint:-} since=${since:-}"

  rc=0
  if [ -n "$HUNT_CMD" ]; then
    # Override seam (the offline demo). The command stages any finding into CHANGE_DROP_DIR exactly as the real
    # run-zone-hunt.sh does (via deliver-submission.sh's never-submit gate) so the verdict-by-drop-delta holds.
    CHANGE_PROGRAM="$program" CHANGE_NEW="$new" CHANGE_REPO="$target" CHANGE_SCOPE_MODE="$scope_mode" \
    CHANGE_SCOPE_HINT="$hint" CHANGE_SINCE="$since" CHANGE_OUT="$hunt_out" CHANGE_DROP_DIR="$DROP_DIR" \
      sh -c "$HUNT_CMD" >>"$LOG" 2>&1 || rc=$?
  else
    # The REAL adversarial hunt. It inherits the #2125 sandbox + the #2133 refusal-fallback disable
    # STRUCTURALLY (run-zone-hunt.sh sets both), and stages any verified finding via its OWN built-in
    # deliver-submission.sh never-submit gate. It exits 0 even with findings.
    "$HERE/run-zone-hunt.sh" "${hunt_args[@]}" >>"$LOG" 2>&1 || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    record "$program" "$new" "hunt-error"
    echo "run-change-hunts: $program @ $new -> hunt exited $rc — ledgered hunt-error" >&2
    log "[hunt-error] $program @ $new (exit $rc)"
    continue
  fi

  after="$(pkg_count)"
  if [ "$after" -gt "$before" ]; then
    verdict="finding"; staged=$((staged + 1))
    echo "run-change-hunts: $program @ $new -> FINDING staged (never submitted; human reviews the drop-dir)" >&2
  else
    verdict="clean"
    echo "run-change-hunts: $program @ $new -> clean (rigorous-negative)" >&2
  fi
  record "$program" "$new" "$verdict"
  log "[$verdict] $program @ $new"
done < "$DESCRIPTORS"

echo "run-change-hunts: $hunts_done hunt(s) run, $staged finding(s) staged, $skipped already-ledgered skipped; ledger -> $LEDGER" >&2
log "[$now] done: hunts=$hunts_done staged=$staged skipped=$skipped"
exit 0
