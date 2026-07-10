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
#   --list-cells, -n    DRY RUN (#1612): print one `CELL|<subsystem>|<class>|<files>` line per cell this
#                       manifest WOULD hunt, then exit 0 — BEFORE any agentis init / config / report side
#                       effect. Needs neither --brief nor an agentis binary; the round-trip check for
#                       map-zones.sh's auto-generated scope.tsv. The shipped hunt path is byte-identical.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
REPO="" ; SCOPE="" ; BRIEF="" ; TAXONOMY="" ; ONLY="" ; CLASSES_OVERRIDE=""
BACKEND="flat-cyborg" ; MODEL="" ; OUT="$PWD/discovery-out"
LIST_CELLS=""   # #1612: opt-in dry-run; empty = the shipped hunt path, byte-identical.

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
    --list-cells|-n) LIST_CELLS=1; shift ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-discovery.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

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

CELLS=0 ; CANDIDATES=0 ; STEERS=0
# #1001: rows recording where one cell's lead STEERED a later cell (the blackboard coordination loop),
# folded into the report at the end. Kept separate from $REPORT so it can be appended as its own table.
COORD="$RUN/coordination.tsv"; : > "$COORD"
# Manifest loop: one subsystem per line, `subsystem | classes | files`. Run the hunter once per
# (subsystem x class) — that cell is the colony-native analogue of one focused audit agent.
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
    echo "run-discovery.sh: hunting $CLS on '$SUBSYS' ..." >&2
    ( cd "$RUN" && env \
        TARGET_DIR="$REPO" \
        IN_SCOPE="$IN_SCOPE" \
        SCOPE_BRIEF="$BRIEF" \
        TAXONOMY="$TAXONOMY" \
        HUNT_CLASS="$CLS" \
        SUBSYSTEM="$SUBSYS" \
        SLICER="$RUN/slice-fns.sh" \
        "$AGENTIS" go hunter.ag --enable-exec --enable-messaging ) >"$CELL_LOG" 2>&1 || \
        echo "run-discovery.sh: hunter run failed for $CLS/'$SUBSYS' (see $CELL_LOG)" >&2
    # #1001 coordination: the hunter reads a shared BLACKBOARD before it prompts and posts every
    # CANDIDATE back to it, so a lead an EARLIER cell found steers later cells (corroborate / pivot).
    # Surface both halves of that loop to the operator and the report: BLACKBOARD-FOCUS| = THIS cell was
    # steered by a sibling's lead; BLACKBOARD-POST| = this cell posted a lead for later cells.
    if grep -q '^BLACKBOARD-FOCUS|' "$CELL_LOG"; then
      FOCUS_LINE="$(grep '^BLACKBOARD-FOCUS|' "$CELL_LOG" | head -1 | sed 's/^BLACKBOARD-FOCUS|//')"
      echo "run-discovery.sh:   ↳ COORDINATION: $CLS/'$SUBSYS' steered by the blackboard ($FOCUS_LINE)" >&2
      printf '| %s | %s | steered by blackboard — %s |\n' "$SUBSYS" "$CLS" "$FOCUS_LINE" >> "$COORD"
      STEERS=$((STEERS + 1))
    fi
    # The hunter's contract: a `CANDIDATE|file:fn:line|class|severity|exploit|poc` line, or `SAFE`.
    # Exclude the hunter's own `BLACKBOARD-*` diagnostic lines: they echo a lead summary (which no longer
    # carries a bare `CANDIDATE|` token, but stay defensive) and must never be scraped as findings.
    if grep -v '^BLACKBOARD-' "$CELL_LOG" | grep -q 'CANDIDATE|'; then
      while IFS= read -r LINE; do
        CAND="$(printf '%s' "$LINE" | sed 's/^.*\(CANDIDATE|\)/\1/')"
        BODY="$(printf '%s' "$CAND" | sed 's/^CANDIDATE|//; s/|/ \/ /g')"
        printf '| %s | %s | %s |\n' "$SUBSYS" "$CLS" "$BODY" >> "$REPORT"
        CANDIDATES=$((CANDIDATES + 1))
      done < <(grep -v '^BLACKBOARD-' "$CELL_LOG" | grep 'CANDIDATE|')
      if grep -q '^BLACKBOARD-POST|' "$CELL_LOG"; then
        echo "run-discovery.sh:   ↳ posted a lead to the blackboard for later cells to focus on" >&2
      fi
    fi
    IFS=','
  done
  IFS="$OLDIFS"
done < "$SCOPE"

if [ "$CANDIDATES" -eq 0 ]; then
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

echo >&2
echo "================ DISCOVERY: $CELLS cells, $CANDIDATES candidate(s), $STEERS blackboard-steered ================" >&2
echo "run-discovery.sh: leads at $REPORT" >&2
if [ "$CANDIDATES" -gt 0 ]; then
  echo "run-discovery.sh: NEXT = verify each lead with evm-harness/forge-verify.sh; only a PASSING PoC is a finding. Submission stays human-gated." >&2
else
  echo "run-discovery.sh: no candidates — rigorous negative. Nothing to verify, nothing submitted." >&2
fi
