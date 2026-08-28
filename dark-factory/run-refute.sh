#!/usr/bin/env bash
# run-refute.sh — adversarial-REFUTATION entrypoint for the Dark Factory federation (#999).
#
# After run-discovery.sh (hunter.ag) surfaces CANDIDATE leads and BEFORE the operator spends a Foundry
# PoC on one, a SECOND, independent skeptic must fail to break it. This script drives that gate on the
# agentis substrate: it runs `auditor/agents/refuter.ag` once per candidate — env-in the candidate
# (file:fn + claimed exploit + class) and the relevant code, `prompt()` a hostile reader that tries to
# REFUTE it against the actual control-flow (defaulting to REFUTED on any doubt), `emit` the verdict, and
# `print` a `VERDICT|REAL|...` / `VERDICT|REFUTED|...` line. It runs ENTIRELY through the substrate
# (prompt/emit/learn). Learning/experience are ENABLED below: refuter.ag ends its tick with
# `learn("refute", ...)`, and it is that WRITE the flag gates — agentis hard-errors `experience not enabled`
# on the call and then DISCARDS the cell's whole stdout, so the VERDICT| sentinel vanishes (#1881/#1878) —
# even though the per-run store is wiped fresh on every invocation and so carries no CROSS-candidate
# reweighting (#1866). This is the colony-native form of the `adversarial-refute` step (auditor/methods/registry.md) that previously ran as
# an externally-orchestrated subagent. This is the proven pattern (#999) for porting the colony's other
# deep capabilities (deep cross-function audit, build-and-run PoC, fork-differential) onto the substrate.
#
# A REAL verdict is still a LEAD, not a finding: it only means a hostile read could not kill it, so it is
# worth a Foundry PoC. Only a PASSING evm-harness/forge-verify.sh PoC makes a lead a finding, and
# submission stays an explicit, human-gated action. This tool NEVER contacts a bounty platform.
#
# Usage:
#   run-refute.sh --candidates <cands.tsv> [options]
#
# Candidate manifest (one candidate per line; `#` and blank lines ignored). Columns are `|`-separated:
#   <file:fn> | <classid> | <severity> | <claimed exploit sentence> | <code-file> [| <aux-code-file>]
# where <code-file> is a path (absolute, or relative to --code-dir) to a file holding the RELEVANT code
# the skeptic judges against, and the OPTIONAL 6th column <aux-code-file> is a path to a SECOND file holding
# the derived contract that implements the first file's `virtual` members (#1861 — the implementation
# appendix verify-findings.sh attaches when the candidate is anchored in an abstract base). A five-column
# manifest behaves exactly as before: no aux is staged and the refuter prompt is byte-identical. e.g.
#   Vault.sol:liquidate | C10 | High   | anyone can self-liquidate at a stale price to seize collateral | vault_liquidate.sol
#   Token.sol:transfer  | C5  | Medium | transfer() lacks an owner check so anyone can move funds        | token_transfer.sol
#
# Options:
#   --candidates <file>  Candidate manifest (see above). REQUIRED.
#   --code-dir <dir>     Base dir for a candidate's relative <code-file> (default: dir of --candidates).
#   --brief <file>       Optional protocol brief (invariants + known issues to exclude). Default: none.
#   --only <file:fn>     Refute only the candidate whose file:fn matches (re-run / smoke one).
#   --backend <mock|flat-cyborg|claude>  LLM backend (default: flat-cyborg = flat-rate PTY wrapper;
#                       claude = metered -p API; mock = offline-deterministic wiring smoke).
#   --model <id>         Optional model id (claude: passed to the CLI; flat-cyborg: set as llm.model).
#   --out <dir>          Output dir for the run + verdicts (default: ./refute-out).
#   --agentis <bin>      agentis binary (default: `agentis` on PATH).
#   --invariant-mode     #1938: judge each candidate as a fuzzer-WITNESSED broken STATEFUL invariant (deep-hunt
#                        STAGE 4.5) rather than an unproven discovery lead — a two-axis rubric (invariant
#                        VALIDITY + witness REACHABILITY) with an INVERTED tie-break (default REAL on genuine
#                        uncertainty, since the witness is already reproduced). Sets CAND_INVARIANT to the
#                        candidate's exploit/broken-invariant sentence. Absent => byte-identical to before.
#   --invariant-harness <file>  #1938: optional generated invariant *.t.sol (the actual asserted predicate),
#                        staged into the rundir and appended to the payload for axis (a). Absent => no change.
#
# Outputs: `<out>/refute-report.md` (the verdict table, an unchanged downstream contract) and — #1887 —
# `<out>/refute-constraints.tsv`, one `<class>\t<file:fn>\t<constraint>` row per REFUTED candidate whose
# reply carried the generalisable `CONSTRAINT|` line. That file is the input of refute-to-knowledge.sh, which
# turns it into an agentis knowledge corpus a LATER target's hunter can read. Always written (empty = no
# refutation produced a constraint); nothing in this script consumes it.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# #1707: shared reply-shape validation + retry for the refuter substrate call (see the helper header).
# verify-findings.sh inherits this fix transitively (it dispatches to run-refute.sh, no `agentis go` of its own).
# shellcheck source=lib/run-agent-validated.sh
# shellcheck disable=SC1091
. "$HERE/lib/run-agent-validated.sh"
DF_AGENT_MAX_ATTEMPTS="$(df_max_attempts)"
AGENTIS="agentis"
CANDS="" ; CODE_DIR="" ; BRIEF="" ; ONLY=""
BACKEND="flat-cyborg" ; MODEL="" ; OUT="$PWD/refute-out"
# #1938: invariant-hunt judgment mode. OFF (default) => CAND_INVARIANT/INV_HARNESS_PATH are exported EMPTY, and
# refuter.ag reproduces the discovery-lead prompt byte-for-byte, so every existing manifest/fixture is unchanged.
INVARIANT_MODE=0 ; INV_HARNESS=""

need() { [ "$1" -ge 2 ] || { echo "run-refute.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --candidates) need "$#"; CANDS="$2"; shift 2 ;;
    --code-dir) need "$#"; CODE_DIR="$2"; shift 2 ;;
    --brief) need "$#"; BRIEF="$2"; shift 2 ;;
    --only) need "$#"; ONLY="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --model) need "$#"; MODEL="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --invariant-mode) INVARIANT_MODE=1; shift ;;
    --invariant-harness) need "$#"; INV_HARNESS="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-refute.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$CANDS" ] && [ -f "$CANDS" ] || { echo "run-refute.sh: --candidates <file:fn|class|sev|exploit|code-file manifest> required" >&2; exit 2; }
[ -n "$CODE_DIR" ] || CODE_DIR="$(cd "$(dirname "$CANDS")" && pwd)"
[ -d "$CODE_DIR" ] || { echo "run-refute.sh: --code-dir not a directory: $CODE_DIR" >&2; exit 2; }
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-refute.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

# Resolve operator paths to ABSOLUTE — the colony runs from the rundir (a different cwd), and the exec
# sandbox cannot read $HOME, so a relative or home-rooted CODE_PATH would silently read empty. We stage
# every code file into the rundir below so the sandbox can always reach it.
CODE_DIR="$(cd "$CODE_DIR" && pwd)"
if [ -n "$BRIEF" ]; then
  [ -f "$BRIEF" ] || { echo "run-refute.sh: --brief not found: $BRIEF" >&2; exit 2; }
  BRIEF="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"
fi
# #1938: the optional invariant harness, resolved to ABSOLUTE and staged like --brief below (the sandbox cannot
# read $HOME). Empty => no harness is staged and INV_HARNESS_PATH is exported empty (a provable no-op).
if [ -n "$INV_HARNESS" ]; then
  [ -f "$INV_HARNESS" ] || { echo "run-refute.sh: --invariant-harness not found: $INV_HARNESS" >&2; exit 2; }
  INV_HARNESS="$(cd "$(dirname "$INV_HARNESS")" && pwd)/$(basename "$INV_HARNESS")"
fi

REFUTER="$HERE/auditor/agents/refuter.ag"
[ -f "$REFUTER" ] || { echo "run-refute.sh: refuter agent not found at $REFUTER" >&2; exit 3; }

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$REFUTER" "$RUN/refuter.ag"
# Stage the brief into the rundir so the sandboxed exec sh can read it (it cannot read $HOME).
BRIEF_IN_RUN=""
if [ -n "$BRIEF" ]; then
  cp "$BRIEF" "$RUN/brief.md"
  BRIEF_IN_RUN="$RUN/brief.md"
fi
# #1938: stage the invariant harness into the rundir (same reason as the brief). Empty => nothing staged.
INV_HARNESS_IN_RUN=""
if [ -n "$INV_HARNESS" ]; then
  cp "$INV_HARNESS" "$RUN/invariant-harness.t.sol"
  INV_HARNESS_IN_RUN="$RUN/invariant-harness.t.sol"
fi

# init the agentis store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  # 600s: a hostile cross-function trace of a candidate is the same order of cost as a discovery read.
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p${MODEL:+ --model $MODEL}"; echo "llm.cli_timeout_ms = 600000"; }
  # idle_ms 12000 (> native 4000 default): kept as a latency knob only (#1925) -- do NOT ratchet it further.
  # Completion is gated on the wrapper's closing sentinel from flat-cyborg >= 0.13.0 (idle_gate_open()); idle_ms
  # only bounds how fast a marker-less (sentinel-less) reply is accepted once the screen goes quiet. If a stage
  # looks flaky, file it against the completion path, not this value.
  [ "$BACKEND" = "flat-cyborg" ] && { echo "llm.cli_timeout_ms = 600000"; echo "llm.flat_cyborg.idle_ms = 12000"; echo "llm.model = ${MODEL:-opus}"; }
  echo "trace.level = normal"
  # The refuter reads the candidate code + brief through exec sh; pass through its whole env contract.
  # AUX_CODE_PATH (#1861) MUST be on this allowlist: getenv() reads the SANITIZED env, so an unregistered
  # knob is silently inert — the implementation appendix would be staged, never read, and the gate would keep
  # refuting abstract bases in isolation with no visible failure at all.
  # #1938: CAND_INVARIANT + INV_HARNESS_PATH MUST be on this allowlist too — getenv() reads the SANITIZED env,
  # so an unregistered knob is staged and never read (the whole invariant mode would be silently inert). Both are
  # exported EMPTY when --invariant-mode is off, so their presence on the line is a no-op for every legacy run.
  echo "exec.env_passthrough = CAND_FILE_FN,CAND_CLASS,CAND_SEVERITY,CAND_EXPLOIT,CODE_PATH,BRIEF_PATH,AUX_CODE_PATH,CAND_INVARIANT,INV_HARNESS_PATH"
  echo "exec.default_timeout_ms = 30000"
  # Learning/experience are ENABLED: refuter.ag ends its tick with `learn("refute", ...)`, and it is that
  # WRITE the flag gates (#1878, agentis v1.28.0: learn() raises `runtime error: experience not enabled`, and
  # ANY runtime error discards the program's whole accumulated stdout). So #1866/#1877's "proven inert"
  # premise was wrong for this script too (same as run-discovery.sh): disabling them makes every refute cell
  # fail (no VERDICT| sentinel -> 5 attempts -> ERROR), so nothing survives the gate and
  # verified_findings.json is empty regardless of the candidates. Regression restored here.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

REPORT="$OUT/refute-report.md"
{
  echo "# Dark Factory — adversarial refutation verdicts"
  echo
  echo "- backend: $BACKEND"
  echo "- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through"
  echo "  \`evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>\` (PoC PASSES = exploit fires)"
  echo "  before it counts; submission stays a separate, explicit human action. This colony never posts."
  echo
  echo "| Candidate (file:fn) | Class | Verdict | Reason |"
  echo "|---|---|---|---|"
} > "$REPORT"

# #1887: the harvested generalisable constraints, one `<class>\t<file:fn>\t<constraint>` row per REFUTED
# candidate whose reply carried a CONSTRAINT| line. A SEPARATE artifact on purpose: refute-report.md's row
# shape is a downstream contract (verify-findings.sh reads field 4/5 of its first data row with `awk -F'|'`),
# so the channel adds a file rather than a column. Always created — an empty file is the honest record of
# "no candidate was refuted with a constraint", and refute-to-knowledge.sh turns it into a valid empty corpus.
CONSTRAINTS="$OUT/refute-constraints.tsv"
: > "$CONSTRAINTS"

# --- #1699 bounded single-class C6 fallback -------------------------------------------------------------
# A candidate REFUTED under its ASSIGNED class is not dropped outright when its own code file trips a
# conservative accounting signal. The hunter routinely mislabels a value-moving-function accounting bug (the
# real nature is a missing/short fee deduction before a transfer = C6) as an integration/composability seam
# (e.g. C15), so the assigned-class refutation attacks the wrong thesis and legitimately "refutes" a claim
# that was never the bug's true nature — the real finding is buried as a false negative. fallback_class_for()
# gates a SINGLE C6 retry on a compound-AND signal over the candidate's staged code: a value-moving function
# DECLARATION *and* an amount-deduction idiom. Both must fire, and the assigned class must not already be C6
# (never re-run a class against itself). Returns `C6` when it should retry, empty otherwise.
#
# The signal vocabulary is deliberately SHARED with zone-mapper.ag's #1698 contains_accounting_signal()
# (has_value_moving_function / has_amount_deduction, ~L101-130): the SAME value-moving keyword set
# (withdraw|deposit|mint(|burn(|redeem|swap) AND the SAME deduction idioms (`-=`, `.sub(`). The two lists can
# drift independently — when you touch one, check the other (and any future map-zones.sh mechanical mirror).
fallback_class_for() {
  fc_src="$1"; fc_assigned="$2"
  [ "$fc_assigned" = "C6" ] && { printf ''; return 0; }
  grep -qE 'function[[:space:]]+(withdraw|deposit|mint\(|burn\(|redeem|swap)' "$fc_src" || { printf ''; return 0; }
  grep -qE '(-=|\.sub\()' "$fc_src" || { printf ''; return 0; }
  printf 'C6'
}

# _join_wrapped_verdict <log> — reconstruct the LAST logical `VERDICT|...` record from a refuter log, undoing
# flat-cyborg's PTY-capture line wrap. Modelled directly on run-discovery.sh's _join_wrapped_candidates()
# (#1705, the same defect on the hunter side): the verdict's one-sentence reason routinely exceeds one physical
# line, the raw log then carries the tail as continuation lines with no `VERDICT|` prefix, and a bare
# `grep 'VERDICT|' | tail -1` silently truncates the reason mid-sentence — which is exactly what made
# `verdict.txt` and `refute-report.md` unreadable to an operator (#1861's secondary item). A `VERDICT|` line
# opens (and replaces) the record; a blank line, an `AUX-CONTEXT|` sentinel, EOF or 12 continuation lines
# close it; any other line while a record is open is appended with its leading whitespace stripped and a
# single joining space (terminal wrap breaks on column width, not on meaningful newlines).
_join_wrapped_verdict() {
  jwv_log="$1"
  awk '
    /VERDICT\|/ { rec = $0; open = 1; cont = 0; next }
    open && (/^[[:space:]]*$/ || /AUX-CONTEXT\|/) { open = 0; next }
    open {
      if (cont >= 12) { open = 0; next }
      line = $0
      sub(/^[[:space:]]+/, "", line)
      rec = rec " " line
      cont++
    }
    END { if (rec != "") print rec }
  ' "$jwv_log"
}

# _join_wrapped_constraint <log> — the #1887 twin of the above, for the `CONSTRAINT|<class>|<sentence>` line
# the refuter prints IMMEDIATELY BEFORE a REFUTED verdict. Same PTY-wrap problem, same joining rules, one
# extra boundary: a `VERDICT|` line CLOSES an open constraint record (the constraint always precedes the
# verdict, so the verdict line is the natural terminator and must never be glued into the sentence). A blank
# line, EOF or 12 continuation lines also close it. The LAST constraint record in the log wins, mirroring
# _join_wrapped_verdict's "last record" rule — and note this scraper is deliberately SEPARATE: touching
# _join_wrapped_verdict would put the verdict row (which verify-findings.sh reads with `awk -F'|'`) at risk.
_join_wrapped_constraint() {
  jwc_log="$1"
  awk '
    /CONSTRAINT\|/ { rec = $0; open = 1; cont = 0; next }
    open && (/VERDICT\|/ || /^[[:space:]]*$/) { open = 0; next }
    open {
      if (cont >= 12) { open = 0; next }
      line = $0
      sub(/^[[:space:]]+/, "", line)
      rec = rec " " line
      cont++
    }
    END { if (rec != "") print rec }
  ' "$jwc_log"
}

# _clean_reason <reason> — normalise a scraped verdict reason for the pipe-delimited report row. A literal `|`
# in the reason breaks the four-cell markdown row AND re-truncates the reason at verify-findings.sh's
# `awk -F'|' ... $5`, so map it to `/`; squeeze the whitespace the wrap-join introduces. Nothing else consumes
# the reason, so this is the whole contract.
_clean_reason() {
  printf '%s' "$1" | tr '|' '/' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ *//; s/ *$//'
}

CHECKED=0 ; REAL=0 ; REFUTED=0 ; ERRORED=0
# Manifest loop: one candidate per line, `file:fn | class | sev | exploit | code-file [| aux-code-file]`.
# AUXF is EMPTY on a five-column line, so every existing manifest (and every existing fixture) is unaffected.
while IFS='|' read -r CFN CLS SEV EXPL CODEF AUXF || [ -n "${CFN:-}" ]; do
  CFN="$(printf '%s' "$CFN" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$CFN" in ''|\#*) continue ;; esac
  CLS="$(printf '%s' "$CLS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  SEV="$(printf '%s' "$SEV" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  EXPL="$(printf '%s' "$EXPL" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  CODEF="$(printf '%s' "$CODEF" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  AUXF="$(printf '%s' "${AUXF:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  # #1938: under --invariant-mode the skeptic judges the BROKEN INVARIANT (the exploit column carries it); OFF
  # => CAND_INV stays empty and the refuter reproduces the discovery-lead prompt byte-for-byte.
  CAND_INV=""
  [ "$INVARIANT_MODE" = 1 ] && CAND_INV="$EXPL"
  [ -n "$ONLY" ] && [ "$CFN" != "$ONLY" ] && continue
  # A candidate whose code file cannot be resolved is ERRORED, not silently dropped: an unresolvable candidate
  # was never assessed, so it must be DISTINGUISHABLE from a rigorous REFUTED verdict in the report (#1691).
  if [ -z "$CODEF" ]; then
    echo "run-refute.sh: candidate '$CFN' has no code-file; recording as ERROR (not assessed)" >&2
    printf '| %s | %s | ERROR | no code-file provided |\n' "$CFN" "$CLS" >> "$REPORT"
    ERRORED=$((ERRORED + 1))
    continue
  fi

  # Resolve the code file (absolute as-is, else relative to --code-dir) and stage it into the rundir so
  # the sandboxed exec sh — which cannot read $HOME — can always read it by an in-rundir path.
  case "$CODEF" in
    /*) SRC="$CODEF" ;;
    *)  SRC="$CODE_DIR/$CODEF" ;;
  esac
  if [ ! -f "$SRC" ]; then
    echo "run-refute.sh: code file not found for '$CFN': $SRC; recording as ERROR (not assessed)" >&2
    printf '| %s | %s | ERROR | code file not found: %s |\n' "$CFN" "$CLS" "$CODEF" >> "$REPORT"
    ERRORED=$((ERRORED + 1))
    continue
  fi
  CHECKED=$((CHECKED + 1))
  SLUG="$(printf '%s' "$CFN" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
  STAGED="$RUN/code_${SLUG}.txt"
  cp "$SRC" "$STAGED"
  # #1861: stage the optional implementation appendix next to the candidate code, resolved EXACTLY like
  # <code-file>. An aux that cannot be resolved is a logged WARNING that degrades to no-aux — never an ERROR
  # row: the candidate itself is still fully assessable against its own file, which is today's behaviour.
  AUX_STAGED=""
  if [ -n "$AUXF" ]; then
    case "$AUXF" in
      /*) AUX_SRC="$AUXF" ;;
      *)  AUX_SRC="$CODE_DIR/$AUXF" ;;
    esac
    if [ -f "$AUX_SRC" ]; then
      AUX_STAGED="$RUN/aux_${SLUG}.txt"
      cp "$AUX_SRC" "$AUX_STAGED"
    else
      echo "run-refute.sh: aux code file not found for '$CFN': $AUX_SRC; continuing WITHOUT the implementation appendix" >&2
    fi
  fi
  CELL_LOG="$RUN/refute_${SLUG}.log"
  echo "run-refute.sh: refuting $CFN ($CLS) ..." >&2
  # --grant-pii: candidate/exploit text + staged contract source can carry addresses/identifiers that
  # trip the PII heuristic; input is benign public contract/finding text (#1690). Dynamic scope:
  # _rf_attempt reads CFN/CLS/SEV/EXPL/STAGED/AUX_STAGED/BRIEF_IN_RUN from the loop.
  # shellcheck disable=SC2317  # invoked by name through df_run_agent_validated
  _rf_attempt() {
    ( cd "$RUN" && env \
        CAND_FILE_FN="$CFN" \
        CAND_CLASS="$CLS" \
        CAND_SEVERITY="$SEV" \
        CAND_EXPLOIT="$EXPL" \
        CAND_INVARIANT="$CAND_INV" \
        INV_HARNESS_PATH="$INV_HARNESS_IN_RUN" \
        CODE_PATH="$STAGED" \
        AUX_CODE_PATH="$AUX_STAGED" \
        BRIEF_PATH="$BRIEF_IN_RUN" \
        "$AGENTIS" go refuter.ag --enable-exec --enable-messaging --grant-pii ) >"$1" 2>&1 || \
        echo "run-refute.sh: refuter run failed for '$CFN' (see $1)" >&2
  }
  # #1707: validate the refuter reply carries a VERDICT| line and RETRY on TUI chrome / no answer. This
  # REPLACES the old silent "no VERDICT| ⇒ REFUTED" default, which killed a possibly-real candidate on a
  # render/timing flake. Only if N attempts STILL yield no VERDICT| is the candidate marked as a
  # DISTINGUISHABLE failure — reuse the ERRORED category (UNASSESSED, not refuted) — so a chrome reply can
  # never silently kill a candidate. The genuine `VERDICT|REFUTED` path (a real hostile-read kill) is below.
  if df_run_agent_validated "$DF_AGENT_MAX_ATTEMPTS" "run-refute.sh: '$CFN'" "$CELL_LOG" refuter "" _rf_attempt; then
    # The refuter's contract: exactly one `VERDICT|REAL|...` or `VERDICT|REFUTED|...` line. Take the LAST
    # match (the agent prints its verdict after free-form reasoning); validation guarantees one is present.
    VLINE="$(_join_wrapped_verdict "$CELL_LOG" || true)"
    V="$(printf '%s' "$VLINE" | sed 's/^.*\(VERDICT|\)/\1/')"
    VERD="$(printf '%s' "$V" | cut -d'|' -f2)"
    REASON="$(_clean_reason "$(printf '%s' "$V" | cut -d'|' -f5-)")"
    # #1887: the generalisable constraint that rode ahead of this verdict (empty on a REAL verdict, and on a
    # REFUTED one whose reply omitted the line — the channel is best-effort, never a gate on the verdict).
    CLINE="$(_join_wrapped_constraint "$CELL_LOG" || true)"
    CONSTRAINT=""
    if [ -n "$CLINE" ]; then
      C="$(printf '%s' "$CLINE" | sed 's/^.*\(CONSTRAINT|\)/\1/')"
      CONSTRAINT="$(_clean_reason "$(printf '%s' "$C" | cut -d'|' -f3-)")"
    fi
  elif [ -f "$CELL_LOG.transient" ]; then
    # #2045: the refuter never produced a VERDICT| because flat-cyborg TRANSPORT-crashed on every attempt and the
    # bounded fresh-session retries (df_run_agent_validated, DF_AGENT_TRANSPORT_RETRIES) were exhausted — this is
    # INFRA instability, NOT an assessment. Emit a DISTINGUISHABLE row so the operator (and verify-findings.sh
    # --rehunt-gaps) can tell a re-runnable transport flake apart from a genuine chrome/no-answer miss. The
    # verdict cell stays ERROR (UNASSESSED, non-settled) so verify-findings.sh's field-4 contract is untouched.
    echo "run-refute.sh: '$CFN' hit a persistent flat-cyborg LLM transport error (backend crashed mid-call) — recording as ERROR (TRANSIENT, RE-RUNNABLE — not assessed)" >&2
    printf '| %s | %s | ERROR | LLM transport error (flat-cyborg exited) after %s attempts — TRANSIENT, RE-RUNNABLE (not assessed) |\n' \
      "$CFN" "$CLS" "$DF_AGENT_MAX_ATTEMPTS" >> "$REPORT"
    ERRORED=$((ERRORED + 1))
    continue
  else
    echo "run-refute.sh: '$CFN' produced no VERDICT| reply after $DF_AGENT_MAX_ATTEMPTS attempts; recording as ERROR (UNASSESSED — not refuted)" >&2
    printf '| %s | %s | ERROR | no VERDICT| reply after %s attempts (UNASSESSED — not refuted) |\n' \
      "$CFN" "$CLS" "$DF_AGENT_MAX_ATTEMPTS" >> "$REPORT"
    ERRORED=$((ERRORED + 1))
    continue
  fi
  ROW_CLS="$CLS"

  # #1699 bounded single-class C6 fallback: a candidate REFUTED under its assigned class gets ONE more full
  # hostile read under C6 when its code trips the compound-AND accounting signal (see fallback_class_for).
  # The retry can only convert REFUTED -> REAL (never the reverse), costs at most ONE extra refuter.ag call
  # per candidate, and keeps the candidate only if it INDEPENDENTLY survives the C6 lens (the same conservative
  # single-thesis refuter, so a candidate with no real accounting bug is REFUTED under C6 too — precision holds).
  if [ "$VERD" = "REFUTED" ]; then
    FB="$(fallback_class_for "$SRC" "$CLS")"
    if [ -n "$FB" ]; then
      FB_LOG="$RUN/refute_${SLUG}_c6.log"
      echo "run-refute.sh: $CFN refuted under $CLS; accounting signal fired, retrying under $FB ..." >&2
      # #1861: the fallback re-run carries the SAME implementation appendix. Forgetting it here is the easy
      # miss — the candidate would be judged with the derived contract in view on attempt 1 and without it on
      # the C6 retry, i.e. two different questions answered under one verdict.
      ( cd "$RUN" && env \
          CAND_FILE_FN="$CFN" \
          CAND_CLASS="$FB" \
          CAND_SEVERITY="$SEV" \
          CAND_EXPLOIT="$EXPL" \
          CAND_INVARIANT="$CAND_INV" \
          INV_HARNESS_PATH="$INV_HARNESS_IN_RUN" \
          CODE_PATH="$STAGED" \
          AUX_CODE_PATH="$AUX_STAGED" \
          BRIEF_PATH="$BRIEF_IN_RUN" \
          "$AGENTIS" go refuter.ag --enable-exec --enable-messaging --grant-pii ) >"$FB_LOG" 2>&1 || \
          echo "run-refute.sh: fallback refuter run failed for '$CFN' (see $FB_LOG)" >&2
      FB_VLINE="$(_join_wrapped_verdict "$FB_LOG" || true)"
      if [ -n "$FB_VLINE" ]; then
        FB_V="$(printf '%s' "$FB_VLINE" | sed 's/^.*\(VERDICT|\)/\1/')"
        FB_VERD="$(printf '%s' "$FB_V" | cut -d'|' -f2)"
        FB_REASON="$(_clean_reason "$(printf '%s' "$FB_V" | cut -d'|' -f5-)")"
        if [ "$FB_VERD" = "REAL" ]; then
          VERD="REAL" ; ROW_CLS="$FB"
          REASON="recovered under $FB fallback (assigned $CLS refuted): $FB_REASON"
        fi
      fi
    fi
  fi

  # Tally AFTER the fallback decision so the counters reflect the FINAL verdict, and emit exactly ONE report
  # row per candidate carrying the WINNING class (ROW_CLS) — verify-findings.sh reads the first data row + exits.
  if [ "$VERD" = "REAL" ]; then REAL=$((REAL + 1)); else REFUTED=$((REFUTED + 1)); fi
  printf '| %s | %s | %s | %s |\n' "$CFN" "$ROW_CLS" "$VERD" "$REASON" >> "$REPORT"
  # #1887: harvest the constraint of the call that produced the FINAL verdict. A candidate the #1699 C6
  # fallback RECOVERED to REAL contributes nothing — the gate's own second read overturned the standard the
  # first one applied, so teaching that standard forward would teach a mistake. A candidate whose fallback
  # also refuted keeps the ASSIGNED-class constraint, because that is the verdict the report row carries.
  if [ "$VERD" = "REFUTED" ] && [ -n "$CONSTRAINT" ]; then
    printf '%s\t%s\t%s\n' "$ROW_CLS" "$CFN" "$CONSTRAINT" >> "$CONSTRAINTS"
  fi
done < "$CANDS"

{
  echo
  echo "---"
  echo "Checked: $CHECKED    REAL (survived, verify with forge): $REAL    REFUTED (killed): $REFUTED    ERRORED (unresolvable code file / unassessed no-verdict): $ERRORED"
} >> "$REPORT"

echo >&2
echo "================ REFUTE: $CHECKED checked, $REAL survived, $REFUTED refuted, $ERRORED errored ================" >&2
echo "run-refute.sh: verdicts at $REPORT" >&2
if [ "$REAL" -gt 0 ]; then
  echo "run-refute.sh: NEXT = forge-verify each REAL lead with evm-harness/forge-verify.sh; only a PASSING PoC is a finding. Submission stays human-gated." >&2
else
  echo "run-refute.sh: every candidate refuted — nothing survived the hostile read. Nothing to verify, nothing submitted." >&2
fi
