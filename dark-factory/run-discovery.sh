#!/usr/bin/env bash
# run-discovery.sh — custom-code DISCOVERY entrypoint for the Dark Factory federation.
#
# run-audit.sh drives the DAG fork-MATCHER (auditor.ag): it fires only where in-scope code RECURS a
# known-bug pattern, so it returns nothing on a bespoke protocol. run-discovery.sh drives the colony's
# DISCOVERY agent (auditor/agents/hunter.ag): a taxonomy-driven, adversarial, per-(subsystem x bug-class)
# audit of CUSTOM multi-contract code — the colony-native, substrate-driven version of a hand-run
# multi-agent pass. The hunter runs ENTIRELY through the agentis substrate (prompt/emit/learn), so every
# attempt is recorded as experience and the taxonomy's per-class fitness reweights over time.
#
# A surfaced CANDIDATE is a LEAD, not a finding. It is UNVERIFIED until the operator reproduces it through
# evm-harness/forge-verify.sh (a real Foundry PoC that PASSES only if the exploit fires). Only a forge-
# VERIFIED candidate is a finding worth a human-gated submission. This tool NEVER contacts a bounty
# platform and NEVER auto-submits — surfacing harness-checkable leads is the whole job.
#
# Usage:
#   run-discovery.sh --repo <dir> --scope <scope.tsv> --brief <brief.md> [options]
#
# Scope manifest (one subsystem per line; `#` and blank lines ignored):
#   <subsystem label> | <classid,classid,...> | <file[,file...]>     (files relative to --repo)
# A file may be FUNCTION-SLICED as `file@fn1+fn2+...` to feed ONLY those functions (+ the contract
# header) instead of the whole file. Use it for big/complex contracts whose whole-file payload
# overflows the LLM per-call budget — without it the deep liquidation/redeem cells time out.
# e.g.
#   savings + rewards | C1,C6,C11 | contracts/SavingsVault.sol,contracts/RewardsDistributor.sol
#   vault liquidation | C10       | contracts/Vault.sol@liquidate+seize+_redeem
#
# Options:
#   --repo <dir>        Cloned target repo root (clone with fetch-target.sh). REQUIRED.
#   --scope <file>      Subsystem x class x files manifest (see above). REQUIRED.
#   --brief <file>      Protocol brief: invariants-to-break + known-issues-to-exclude + trust model. REQUIRED.
#   --taxonomy <file>   bug-taxonomy.md (default: bundled ./auditor/bug-taxonomy.md).
#   --only <subsystem>  Hunt only the line whose subsystem label matches (smoke test / re-run one slice).
#   --classes <ids>     Override EVERY line's class list with this comma list (e.g. C1,C2 for a cheap probe).
#   --backend <mock|flat-cyborg|claude>  LLM backend (default: flat-cyborg = flat-rate PTY wrapper;
#                       claude = metered -p API; mock = offline-deterministic wiring smoke).
#   --out <dir>         Output dir for the run + leads (default: ./discovery-out).
#   --agentis <bin>     agentis binary (default: `agentis` on PATH).
#   --jobs <N>, -j <N>  OPT-IN bounded-concurrency fan-out (#1625, epic #1611 M3). Hunt up to N
#                       (subsystem x class) cells CONCURRENTLY instead of serially (default N=1 = serial).
#                       Concurrency is HARD-CAPPED at min(N, LLM_MAX_DISCOVERY_CELLS=4) so N concurrent
#                       agentis go / forge / solc processes cannot OOM-thrash a single host — the cap never
#                       fails open. Under --jobs > 1 each cell gets its OWN isolated agentis store/workdir
#                       (a `cp -r` of the initialised $RUN template), so concurrent memo/build writes never
#                       race; a consequence is that the #1001 shared-blackboard cross-cell steering is
#                       DISABLED under parallelism (every cell's board starts empty) — a documented
#                       throughput-vs-steering trade. Results are aggregated AFTER the pool drains in
#                       MANIFEST order, so the finding set is deterministic + independent of completion
#                       order. --jobs 1 (the default) keeps the ONE shared store WITH live #1001 steering
#                       and is BYTE-FOR-BYTE identical to the pre-M3 hunt.
#   --list-cells, -n    DRY RUN (#1612): print one `CELL|<subsystem>|<class>|<files>` line per cell this
#                       manifest WOULD hunt, then exit 0 — BEFORE any agentis init / config / report side
#                       effect. Needs neither --brief nor an agentis binary; the round-trip check for
#                       map-zones.sh's auto-generated scope.tsv. The shipped hunt path is byte-identical.
#                       #1619: when --brief is ALSO given, --list-cells first validates it, resolves it to an
#                       absolute path, and prints `BRIEF|<abs>|<line-count>` — the offline proof that a
#                       generated brief resolves + is what would be handed to the hunter as SCOPE_BRIEF.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# #1707: shared reply-shape validation + retry for the hunter substrate call (see the helper header).
# shellcheck source=lib/run-agent-validated.sh
# shellcheck disable=SC1091
. "$HERE/lib/run-agent-validated.sh"
DF_AGENT_MAX_ATTEMPTS="$(df_max_attempts)"
AGENTIS="agentis"
REPO="" ; SCOPE="" ; BRIEF="" ; TAXONOMY="" ; ONLY="" ; CLASSES_OVERRIDE=""
BACKEND="flat-cyborg" ; MODEL="" ; OUT="$PWD/discovery-out"
LIST_CELLS=""   # #1612: opt-in dry-run; empty = the shipped hunt path, byte-identical.
JOBS=1          # #1625: opt-in bounded-concurrency fan-out; 1 = serial, byte-identical to the pre-M3 hunt.

need() { [ "$1" -ge 2 ] || { echo "run-discovery.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "$#"; REPO="$2"; shift 2 ;;
    --scope) need "$#"; SCOPE="$2"; shift 2 ;;
    --brief) need "$#"; BRIEF="$2"; shift 2 ;;
    --taxonomy) need "$#"; TAXONOMY="$2"; shift 2 ;;
    --only) need "$#"; ONLY="$2"; shift 2 ;;
    --classes) need "$#"; CLASSES_OVERRIDE="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --model) need "$#"; MODEL="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --jobs|-j) need "$#"; JOBS="$2"; shift 2 ;;
    --list-cells|-n) LIST_CELLS=1; shift ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-discovery.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

# #1625: --jobs must be a positive integer (validated even under --list-cells, which then ignores it).
case "$JOBS" in ''|*[!0-9]*) echo "run-discovery.sh: --jobs must be a positive integer (got '$JOBS')" >&2; exit 2 ;; esac
[ "$JOBS" -ge 1 ] || { echo "run-discovery.sh: --jobs must be >= 1 (got '$JOBS')" >&2; exit 2; }

[ -n "$REPO" ]  && [ -d "$REPO" ]  || { echo "run-discovery.sh: --repo <cloned repo dir> required (clone it with fetch-target.sh)" >&2; exit 2; }
[ -n "$SCOPE" ] && [ -f "$SCOPE" ] || { echo "run-discovery.sh: --scope <subsystem|classes|files manifest> required" >&2; exit 2; }
# #1612: --list-cells needs no --brief (it never hunts) — guard the brief requirement behind it.
if [ -z "$LIST_CELLS" ]; then
  [ -n "$BRIEF" ] && [ -f "$BRIEF" ] || { echo "run-discovery.sh: --brief <invariants + known-issues + trust model> required (this anchors the hunt and excludes known issues)" >&2; exit 2; }
fi

# #1612 dry-run short-circuit: enumerate the (subsystem x class) cells this manifest WOULD hunt and exit,
# BEFORE any agentis init / config / report side effect. Runs the SAME normalization as the hunt loop below
# (trim + `''|\#*` skip + --only/--classes + comma class split), so the enumerated cells match the manifest
# byte-for-byte. Needs neither --brief nor an agentis binary — the offline round-trip for map-zones.sh's
# auto-generated scope.tsv. With no --list-cells every guard above is inert and the hunt path is unchanged.
if [ -n "$LIST_CELLS" ]; then
  # #1619 (epic #1611 M2): opt-in, byte-identical-default brief acknowledgement. When --brief is ALSO given,
  # validate + resolve it to absolute (the same idiom as the hunt path's line ~111) and print BRIEF|<abs>|<lines>
  # BEFORE the cell enumeration — the offline (no-agentis) proof that a generated brief resolves and is what
  # would be handed to every cell as SCOPE_BRIEF. With no --brief, BRIEF="" so this block is skipped and the
  # M1 --list-cells output is unchanged.
  if [ -n "$BRIEF" ]; then
    [ -f "$BRIEF" ] || { echo "run-discovery.sh: --brief file not found: $BRIEF" >&2; exit 2; }
    BRIEF_ABS="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"
    BRIEF_LINES="$(wc -l < "$BRIEF" | tr -d ' ')"
    printf 'BRIEF|%s|%s\n' "$BRIEF_ABS" "$BRIEF_LINES"
  fi
  while IFS='|' read -r SUBSYS CLS_CSV FILES_CSV || [ -n "${SUBSYS:-}" ]; do
    SUBSYS="$(printf '%s' "$SUBSYS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$SUBSYS" in ''|\#*) continue ;; esac
    CLS_CSV="$(printf '%s' "$CLS_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    FILES_CSV="$(printf '%s' "$FILES_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$ONLY" ] && [ "$SUBSYS" != "$ONLY" ] && continue
    [ -n "$CLASSES_OVERRIDE" ] && CLS_CSV="$CLASSES_OVERRIDE"
    [ -n "$FILES_CSV" ] || continue
    OLDIFS="$IFS"; IFS=','
    for CLS in $CLS_CSV; do
      IFS="$OLDIFS"
      CLS="$(printf '%s' "$CLS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$CLS" ] || { IFS=','; continue; }
      printf 'CELL|%s|%s|%s\n' "$SUBSYS" "$CLS" "$FILES_CSV"
      IFS=','
    done
    IFS="$OLDIFS"
  done < "$SCOPE"
  exit 0
fi

[ -n "$TAXONOMY" ] || TAXONOMY="$HERE/auditor/bug-taxonomy.md"
[ -f "$TAXONOMY" ] || { echo "run-discovery.sh: taxonomy not found: $TAXONOMY" >&2; exit 2; }
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-discovery.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

# Resolve every operator path to ABSOLUTE — the colony runs from a different cwd, so a relative path
# would silently miss (the hunter reads files via absolute TARGET_DIR/<rel>).
REPO="$(cd "$REPO" && pwd)"
BRIEF="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"
TAXONOMY="$(cd "$(dirname "$TAXONOMY")" && pwd)/$(basename "$TAXONOMY")"

HUNTER="$HERE/auditor/agents/hunter.ag"
[ -f "$HUNTER" ] || { echo "run-discovery.sh: hunter agent not found at $HUNTER" >&2; exit 3; }

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$HUNTER" "$RUN/hunter.ag"
cp "$HERE/auditor/slice-fns.sh" "$RUN/slice-fns.sh"   # function-level slicer (scope `file@fn1+fn2`)

# init the agentis store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  # 600s: a deep adversarial read of complex liquidation/redemption logic legitimately runs 4-8 min
  # even on a function-level slice (the reasoning, not the payload, is the cost). 300s made the hard
  # cells time out 3x and return nothing; one 600s attempt beats three wasted 300s retries. Keep
  # cells focused with `file@fn` slicing so the common case stays fast.
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p${MODEL:+ --model $MODEL}"; echo "llm.cli_timeout_ms = 600000"; }
  [ "$BACKEND" = "flat-cyborg" ] && { echo "llm.cli_timeout_ms = 600000"; [ -n "$MODEL" ] && echo "llm.model = $MODEL"; }
  echo "trace.level = normal"
  # The hunter reads source + the brief/taxonomy through exec sh; pass through its whole env contract.
  echo "exec.env_passthrough = TARGET_DIR,IN_SCOPE,SCOPE_BRIEF,TAXONOMY,HUNT_CLASS,SUBSYSTEM,SLICER"
  echo "exec.default_timeout_ms = 30000"
  # Discovery records every attempt as experience and reweights taxonomy fitness over time.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

REPORT="$OUT/discovery-report.md"
{
  echo "# Dark Factory — custom-code discovery leads"
  echo
  echo "- repo: \`$(basename "$REPO")\`   backend: $BACKEND"
  echo "- Each CANDIDATE below is an UNVERIFIED LEAD. It is a finding ONLY after it reproduces through"
  echo "  \`evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>\` (PoC PASSES = exploit fires)."
  echo "- Submission is a separate, explicit human action. This colony never posts to a platform."
  echo
  echo "| Subsystem | Class | Lead (file:fn:line / severity / exploit / PoC sketch) |"
  echo "|---|---|---|"
} > "$REPORT"

CELLS=0 ; CANDIDATES=0 ; STEERS=0 ; FAILED_CELLS=0
# #1707: FAILED_CELLS counts cells whose hunter reply never carried a CANDIDATE|/SAFE sentinel after
# DF_AGENT_MAX_ATTEMPTS retries (TUI chrome / no answer). Such a cell is NOT a rigorous negative — it is
# surfaced as a distinct FAILED row + a "status":"failed" JSON record, never silently folded into "0 candidates".
# #1001: rows recording where one cell's lead STEERED a later cell (the blackboard coordination loop),
# folded into the report at the end. Kept separate from $REPORT so it can be appended as its own table.
COORD="$RUN/coordination.tsv"; : > "$COORD"
# #1625: per-cell JSON accumulator for the additive discovery-results.json (written on BOTH the serial and
# the parallel path). One object per cell, appended in MANIFEST order; it never mutates $REPORT's bytes.
CELLS_JSONL="$RUN/results-cells.jsonl"; : > "$CELLS_JSONL"

# #1625 (epic #1611 M3): concurrency ceiling. The effective parallelism is min(--jobs, CELL_CAP); the cap is
# a HARD limit (never fail-open) so N concurrent agentis go / forge / solc processes cannot OOM-thrash a
# single host. Conservative default 4; tune per host via LLM_MAX_DISCOVERY_CELLS.
CELL_CAP="${LLM_MAX_DISCOVERY_CELLS:-4}"
case "$CELL_CAP" in ''|*[!0-9]*) CELL_CAP=4 ;; esac
[ "$CELL_CAP" -ge 1 ] || CELL_CAP=4
# --jobs > 1 uses `wait -n` (bash >= 4.3). On an older bash, degrade to the serial path rather than misbehave.
if [ "$JOBS" -gt 1 ]; then
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 3 ]; }; then
    echo "run-discovery.sh: --jobs > 1 needs bash >= 4.3 (wait -n) — running serially instead" >&2
    JOBS=1
  fi
fi

# --- factored cell primitives: run_cell + scrape_cell_log are called IDENTICALLY by the serial loop and the
# deferred parallel-aggregation pass, so --jobs 1 stays byte-for-byte identical to the pre-M3 hunt (#1625). ---

# _json_str <s> — emit <s> as a JSON string literal (escape backslash + double-quote; cell output is single-line).
_json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# _join_wrapped_candidates <log> — reconstruct one logical line per `CANDIDATE|...` record from a hunt log,
# undoing flat-cyborg's PTY-capture line wrap (#1705). A `CANDIDATE|file:fn:line|class|severity|exploit|poc`
# record's exploit/poc_sketch prose routinely exceeds one physical line; the raw log then carries the tail
# as continuation lines with no `CANDIDATE|` prefix, which a bare `grep 'CANDIDATE|'` silently drops. Here a
# `CANDIDATE|` line opens/flushes a record; a `BLACKBOARD-*` line or a blank line closes the current record
# without starting a new one (these are the only meaningful boundary tokens in a hunt log — see hunter.ag's
# own framing); any other line while a record is open is a continuation, appended with a single space
# (terminal wrap breaks on column width, not on meaningful newlines — a stray space is a cosmetic artifact,
# not data loss). Emits one reconstructed line per record, in log order.
_join_wrapped_candidates() {
  jwc_log="$1"
  awk '
    /^[[:space:]]*CANDIDATE\|/ {
      if (rec != "") print rec
      rec = $0
      next
    }
    /^[[:space:]]*BLACKBOARD-/ || /^[[:space:]]*$/ {
      if (rec != "") { print rec; rec = "" }
      next
    }
    {
      if (rec != "") {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        rec = rec " " line
      }
    }
    END { if (rec != "") print rec }
  ' "$jwc_log"
}

# _accumulate_cell <subsys> <cls> <files> <log> [status] — append ONE JSON object for this cell to
# $CELLS_JSONL (additive; feeds discovery-results.json). Never touches $REPORT. [status] defaults to "ok";
# a #1707 no-sentinel-after-retries cell is recorded as "failed" so the JSON distinguishes it from a clean
# (0-candidate) negative.
_accumulate_cell() {
  ac_subsys="$1"; ac_cls="$2"; ac_files="$3"; ac_log="$4"; ac_status="${5:-ok}"
  ac_cands=""
  while IFS= read -r ac_line; do
    [ -n "$ac_line" ] || continue
    ac_c="$(printf '%s' "$ac_line" | sed 's/^.*\(CANDIDATE|\)/\1/; s/^CANDIDATE|//')"
    ac_c="$(_json_str "$ac_c")"
    if [ -z "$ac_cands" ]; then ac_cands="$ac_c"; else ac_cands="$ac_cands,$ac_c"; fi
  done < <(_join_wrapped_candidates "$ac_log" 2>/dev/null || true)
  ac_coord=""
  if grep -q '^BLACKBOARD-FOCUS|' "$ac_log" 2>/dev/null; then
    ac_f="$(grep '^BLACKBOARD-FOCUS|' "$ac_log" | head -1 | sed 's/^BLACKBOARD-FOCUS|//')"
    ac_coord="$(_json_str "$ac_f")"
  fi
  printf '{"subsystem":%s,"class":%s,"files":%s,"status":%s,"candidates":[%s],"coordination":[%s]}\n' \
    "$(_json_str "$ac_subsys")" "$(_json_str "$ac_cls")" "$(_json_str "$ac_files")" \
    "$(_json_str "$ac_status")" "$ac_cands" "$ac_coord" >> "$CELLS_JSONL"
}

# run_cell <dir> <subsys> <cls> <in_scope> <log> — invoke the hunter for ONE (subsystem x class) cell into
# <log>. Serial passes dir=$RUN (the shared store); parallel passes an isolated per-cell store. Never trips
# set -e (the invocation ends `|| echo …`), so a failed cell degrades (its log is still scraped), not aborts.
run_cell() {
  rc_dir="$1"; rc_subsys="$2"; rc_cls="$3"; rc_in_scope="$4"; rc_log="$5"
  echo "run-discovery.sh: hunting $rc_cls on '$rc_subsys' ..." >&2
  # shellcheck disable=SC2317  # invoked by name through df_run_agent_validated
  _rc_attempt() {
    ( cd "$rc_dir" && env \
        TARGET_DIR="$REPO" \
        IN_SCOPE="$rc_in_scope" \
        SCOPE_BRIEF="$BRIEF" \
        TAXONOMY="$TAXONOMY" \
        HUNT_CLASS="$rc_cls" \
        SUBSYSTEM="$rc_subsys" \
        SLICER="$rc_dir/slice-fns.sh" \
        "$AGENTIS" go hunter.ag --enable-exec --enable-messaging --grant-pii ) >"$1" 2>&1 || \
        echo "run-discovery.sh: hunter run failed for $rc_cls/'$rc_subsys' (see $1)" >&2
  }
  # #1707: validate the hunter reply carries a CANDIDATE|/SAFE sentinel and RETRY on TUI chrome / no answer,
  # instead of scraping an empty log as a rigorous negative. The retry lives INSIDE run_cell (called by both
  # the serial and parallel paths) and failure is signalled via a "$rc_log.novalid" MARKER FILE, not an exit
  # code — a backgrounded `run_cell &` loses its return across `wait -n`, but the marker survives for the
  # deferred manifest-order aggregation in scrape_cell_log. Never trips set -e (|| true).
  df_run_agent_validated "$DF_AGENT_MAX_ATTEMPTS" "run-discovery.sh: $rc_cls/'$rc_subsys'" "$rc_log" hunter "" _rc_attempt || true
}

# scrape_cell_log <subsys> <cls> <log> <files> — the (byte-identical) post-cell scrape: surface the #1001
# BLACKBOARD-FOCUS coordination row (+ $COORD, STEERS), scrape CANDIDATE| rows into $REPORT (+ CANDIDATES),
# and accumulate the cell into the additive JSON. Called in MANIFEST order on both paths (deterministic).
scrape_cell_log() {
  sc_subsys="$1"; sc_cls="$2"; sc_log="$3"; sc_files="$4"
  # #1707: a cell whose reply never produced a CANDIDATE|/SAFE sentinel after DF_AGENT_MAX_ATTEMPTS retries
  # (TUI chrome / no answer) carries a "$sc_log.novalid" marker. Do NOT treat its empty log as a rigorous
  # negative: surface it as a DISTINCT FAILED row + counter so it is visible, not silently folded into
  # "0 candidates". Recorded as "status":"failed" in the additive JSON.
  if [ -f "$sc_log.novalid" ]; then
    echo "run-discovery.sh:   ↳ FAILED: $sc_cls/'$sc_subsys' produced no CANDIDATE|/SAFE reply after $DF_AGENT_MAX_ATTEMPTS attempts (NOT a rigorous negative)" >&2
    printf '| %s | %s | FAILED — no CANDIDATE|/SAFE reply after %s attempts (NOT a rigorous negative) |\n' \
      "$sc_subsys" "$sc_cls" "$DF_AGENT_MAX_ATTEMPTS" >> "$REPORT"
    FAILED_CELLS=$((FAILED_CELLS + 1))
    _accumulate_cell "$sc_subsys" "$sc_cls" "$sc_files" "$sc_log" failed
    return 0
  fi
  # #1001 coordination: the hunter reads a shared BLACKBOARD before it prompts and posts every
  # CANDIDATE back to it, so a lead an EARLIER cell found steers later cells (corroborate / pivot).
  # Surface both halves of that loop to the operator and the report: BLACKBOARD-FOCUS| = THIS cell was
  # steered by a sibling's lead; BLACKBOARD-POST| = this cell posted a lead for later cells.
  if grep -q '^BLACKBOARD-FOCUS|' "$sc_log"; then
    FOCUS_LINE="$(grep '^BLACKBOARD-FOCUS|' "$sc_log" | head -1 | sed 's/^BLACKBOARD-FOCUS|//')"
    echo "run-discovery.sh:   ↳ COORDINATION: $sc_cls/'$sc_subsys' steered by the blackboard ($FOCUS_LINE)" >&2
    printf '| %s | %s | steered by blackboard — %s |\n' "$sc_subsys" "$sc_cls" "$FOCUS_LINE" >> "$COORD"
    STEERS=$((STEERS + 1))
  fi
  # The hunter's contract: a `CANDIDATE|file:fn:line|class|severity|exploit|poc` line, or `SAFE`.
  # Exclude the hunter's own `BLACKBOARD-*` diagnostic lines: they echo a lead summary (which no longer
  # carries a bare `CANDIDATE|` token, but stay defensive) and must never be scraped as findings.
  if grep -v '^BLACKBOARD-' "$sc_log" | grep -q 'CANDIDATE|'; then
    while IFS= read -r LINE; do
      CAND="$(printf '%s' "$LINE" | sed 's/^.*\(CANDIDATE|\)/\1/')"
      BODY="$(printf '%s' "$CAND" | sed 's/^CANDIDATE|//; s/|/ \/ /g')"
      printf '| %s | %s | %s |\n' "$sc_subsys" "$sc_cls" "$BODY" >> "$REPORT"
      CANDIDATES=$((CANDIDATES + 1))
    done < <(_join_wrapped_candidates "$sc_log")
    if grep -q '^BLACKBOARD-POST|' "$sc_log"; then
      echo "run-discovery.sh:   ↳ posted a lead to the blackboard for later cells to focus on" >&2
    fi
  fi
  _accumulate_cell "$sc_subsys" "$sc_cls" "$sc_files" "$sc_log"
}

# Manifest loop: one subsystem per line, `subsystem | classes | files`. Run the hunter once per
# (subsystem x class) — that cell is the colony-native analogue of one focused audit agent.
if [ "$JOBS" -le 1 ]; then
  # SERIAL path (default): the current loop, byte-for-byte identical to the pre-M3 hunt — run_cell then
  # scrape_cell_log inline in manifest order against the ONE shared $RUN store (live #1001 steering).
  while IFS='|' read -r SUBSYS CLS_CSV FILES_CSV || [ -n "${SUBSYS:-}" ]; do
    # trim + skip blanks/comments
    SUBSYS="$(printf '%s' "$SUBSYS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$SUBSYS" in ''|\#*) continue ;; esac
    CLS_CSV="$(printf '%s' "$CLS_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    FILES_CSV="$(printf '%s' "$FILES_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$ONLY" ] && [ "$SUBSYS" != "$ONLY" ] && continue
    [ -n "$CLASSES_OVERRIDE" ] && CLS_CSV="$CLASSES_OVERRIDE"
    [ -n "$FILES_CSV" ] || { echo "run-discovery.sh: subsystem '$SUBSYS' has no files; skipping" >&2; continue; }

    # IN_SCOPE is newline-separated (hunter splits on \n); convert the manifest's comma list.
    IN_SCOPE="$(printf '%s' "$FILES_CSV" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)"
    SLUG="$(printf '%s' "$SUBSYS" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"

    OLDIFS="$IFS"; IFS=','
    for CLS in $CLS_CSV; do
      IFS="$OLDIFS"
      CLS="$(printf '%s' "$CLS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$CLS" ] || { IFS=','; continue; }
      CELLS=$((CELLS + 1))
      CELL_LOG="$RUN/hunt_${SLUG}_${CLS}.log"
      run_cell "$RUN" "$SUBSYS" "$CLS" "$IN_SCOPE" "$CELL_LOG"
      scrape_cell_log "$SUBSYS" "$CLS" "$CELL_LOG" "$FILES_CSV"
      IFS=','
    done
    IFS="$OLDIFS"
  done < "$SCOPE"
else
  # PARALLEL path (#1625, --jobs > 1): expand the manifest into an ORDERED cell list, give EACH cell its OWN
  # isolated agentis store (a cp -r of the initialised $RUN template) so concurrent memo/build writes never
  # race — which means every cell's blackboard is EMPTY and #1001 cross-cell steering is disabled here (the
  # documented throughput-vs-steering trade). Launch under a HARD `wait -n` slot capped at effective_jobs =
  # min(--jobs, CELL_CAP); after the pool drains, scrape each cell in MANIFEST order (the SAME scrape_cell_log)
  # so the aggregated finding set is identical + independent of completion order.
  CELL_SUBSYS=() ; CELL_CLS=() ; CELL_INSCOPE=() ; CELL_FILES=() ; CELL_DIR=() ; CELL_LOGP=()
  while IFS='|' read -r SUBSYS CLS_CSV FILES_CSV || [ -n "${SUBSYS:-}" ]; do
    SUBSYS="$(printf '%s' "$SUBSYS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$SUBSYS" in ''|\#*) continue ;; esac
    CLS_CSV="$(printf '%s' "$CLS_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    FILES_CSV="$(printf '%s' "$FILES_CSV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$ONLY" ] && [ "$SUBSYS" != "$ONLY" ] && continue
    [ -n "$CLASSES_OVERRIDE" ] && CLS_CSV="$CLASSES_OVERRIDE"
    [ -n "$FILES_CSV" ] || { echo "run-discovery.sh: subsystem '$SUBSYS' has no files; skipping" >&2; continue; }
    IN_SCOPE="$(printf '%s' "$FILES_CSV" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)"
    SLUG="$(printf '%s' "$SUBSYS" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
    OLDIFS="$IFS"; IFS=','
    for CLS in $CLS_CSV; do
      IFS="$OLDIFS"
      CLS="$(printf '%s' "$CLS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$CLS" ] || { IFS=','; continue; }
      CELLS=$((CELLS + 1))
      CELL_SUBSYS+=("$SUBSYS") ; CELL_CLS+=("$CLS") ; CELL_INSCOPE+=("$IN_SCOPE")
      CELL_FILES+=("$FILES_CSV") ; CELL_DIR+=("$RUN/cell-${SLUG}_${CLS}") ; CELL_LOGP+=("$RUN/hunt_${SLUG}_${CLS}.log")
      IFS=','
    done
    IFS="$OLDIFS"
  done < "$SCOPE"

  effective_jobs="$JOBS"
  if [ "$effective_jobs" -gt "$CELL_CAP" ]; then
    echo "run-discovery.sh: --jobs $JOBS exceeds the hard cap LLM_MAX_DISCOVERY_CELLS=$CELL_CAP; clamping concurrency to $CELL_CAP" >&2
    effective_jobs="$CELL_CAP"
  fi
  echo "run-discovery.sh: parallel fan-out over ${#CELL_SUBSYS[@]} cell(s), up to $effective_jobs concurrent (isolated per-cell stores; #1001 cross-cell steering off under --jobs > 1)" >&2

  # Launch under a hard job-slot: keep at most effective_jobs run_cell processes live at any instant.
  live=0 ; idx=0 ; ncells=${#CELL_SUBSYS[@]}
  while [ "$idx" -lt "$ncells" ]; do
    while [ "$live" -ge "$effective_jobs" ]; do
      wait -n 2>/dev/null || true
      live=$((live - 1))
    done
    cdir="${CELL_DIR[$idx]}"
    rm -rf "$cdir"; mkdir -p "$cdir"
    cp -r "$RUN/.agentis" "$cdir/.agentis"        # isolated store: an empty blackboard, no cross-cell race
    cp "$RUN/hunter.ag" "$cdir/hunter.ag"
    cp "$RUN/slice-fns.sh" "$cdir/slice-fns.sh"
    run_cell "$cdir" "${CELL_SUBSYS[$idx]}" "${CELL_CLS[$idx]}" "${CELL_INSCOPE[$idx]}" "${CELL_LOGP[$idx]}" &
    live=$((live + 1))
    idx=$((idx + 1))
  done
  while [ "$live" -gt 0 ]; do
    wait -n 2>/dev/null || true
    live=$((live - 1))
  done

  # Deferred aggregation: scrape every cell's log in MANIFEST order (order-independent of finish order).
  idx=0
  while [ "$idx" -lt "$ncells" ]; do
    scrape_cell_log "${CELL_SUBSYS[$idx]}" "${CELL_CLS[$idx]}" "${CELL_LOGP[$idx]}" "${CELL_FILES[$idx]}"
    idx=$((idx + 1))
  done
fi

# #1707: only a run with ZERO candidates AND ZERO failed cells is a rigorous NEGATIVE. A cell that FAILED
# validation (chrome / no answer) is NOT evidence of cleanliness, so its presence suppresses this line —
# the FAILED rows above already make those cells visible as unassessed, not clean.
if [ "$CANDIDATES" -eq 0 ] && [ "$FAILED_CELLS" -eq 0 ]; then
  echo "| _(none)_ | — | rigorous NEGATIVE — no candidate of any hunted class survived. A clean result on audited code is a valid outcome; nothing is submitted. |" >> "$REPORT"
fi
{
  echo
  echo "---"
  echo "Cells run: $CELLS    Candidates surfaced: $CANDIDATES (all UNVERIFIED — forge-verify each before it counts)."
} >> "$REPORT"

# #1001: append the coordination table — where a lead from one cell STEERED a later cell via the shared
# blackboard. This is what makes the run more than a sum of independent audits: emit it whenever any
# cell was steered, so the operator can see the inter-agent influence (and audit it).
if [ "$STEERS" -gt 0 ]; then
  {
    echo
    echo "## Inter-agent coordination (blackboard, #1001)"
    echo
    echo "A cell that surfaces a CANDIDATE posts it to a shared in-run blackboard; every later cell reads"
    echo "the board and is steered to corroborate a sibling's hit or pivot to a related surface. Cells"
    echo "steered this run:"
    echo
    echo "| Subsystem | Class | Steer |"
    echo "|---|---|---|"
    cat "$COORD"
  } >> "$REPORT"
fi

# #1625: additive machine-readable sibling of discovery-report.md — the same accumulator, emitted on BOTH
# paths. It does not affect discovery-report.md's bytes (the byte-identical invariant targets the report).
RESULTS_JSON="$OUT/discovery-results.json"
CELLS_ARR="$(paste -sd, "$CELLS_JSONL" 2>/dev/null || true)"
printf '{"repo":%s,"backend":%s,"jobs":%s,"cells":[%s],"totals":{"cells":%s,"candidates":%s,"steers":%s,"failed":%s}}\n' \
  "$(_json_str "$(basename "$REPO")")" "$(_json_str "$BACKEND")" "$JOBS" "$CELLS_ARR" \
  "$CELLS" "$CANDIDATES" "$STEERS" "$FAILED_CELLS" > "$RESULTS_JSON"

echo >&2
echo "================ DISCOVERY: $CELLS cells, $CANDIDATES candidate(s), $STEERS blackboard-steered, $FAILED_CELLS failed ================" >&2
echo "run-discovery.sh: leads at $REPORT" >&2
if [ "$CANDIDATES" -gt 0 ]; then
  echo "run-discovery.sh: NEXT = verify each lead with evm-harness/forge-verify.sh; only a PASSING PoC is a finding. Submission stays human-gated." >&2
else
  echo "run-discovery.sh: no candidates — rigorous negative. Nothing to verify, nothing submitted." >&2
fi
