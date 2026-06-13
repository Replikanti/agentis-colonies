#!/usr/bin/env bash
# screen-leads.sh — substrate-native LEAD PRE-SCREEN for the Dark Factory discovery track (#997).
#
# The discovery hunter (run-discovery.sh + hunter.ag) surfaces a CANDIDATE as a PROSE PoC sketch — an
# UNVERIFIED lead. The heavyweight gate is evm-harness/forge-verify.sh: a full Foundry deploy + attacker
# tx + invariant assertion, which needs the cloned repo + foundryup and runs slowly. This tool is the
# CHEAP gate that runs FIRST: for each lead it evaluates a self-contained `.ag` PoC harness through the
# agentis substrate's `eval_ag` primitive (a metered sub-interpreter with its OWN CB budget), and
# reports whether the lead's machine-checkable invariant REPRODUCED — so the operator only spends
# forge-verify time on leads that survive the screen. A runaway / malformed harness is CB-exhaustion-
# CONTAINED by the sub-interpreter's CB metering (surfaced as `inner_cb_exhausted` / `parse_error`), so a
# runaway harness cannot starve or crash the screener. NOTE: `eval_ag` does NOT sandbox `exec` in agentis
# v1.18.27 — a harness calling `exec sh` reaches the host, so harnesses must be operator-trusted. This
# tool NEVER contacts a bounty platform.
#
# Harness contract (mirrors the colony's exit-101 two-sided gate): a self-contained `.ag` program whose
# FINAL expression is an int — 101 = INVARIANT VIOLATED (lead reproduced), 0 = invariant HELD (refuted),
# anything else = indeterminate. Two-sided is encouraged: assert the CONTROL (legit path accepted) AND
# the EXPLOIT (attacker path breaks the invariant), returning 101 only when control held AND exploit fired.
#
# Usage:
#   screen-leads.sh --manifest <leads.tsv> [--out <dir>] [--agentis <bin>]
#   screen-leads.sh --demo [--out <dir>]            # self-contained demo (writes + screens 3 leads)
#
# Manifest (one lead per line; `#` and blank lines ignored):
#   <lead-id> | <path-to-harness.ag>                (harness path relative to CWD or absolute)
#
# Exit: 0 if at least one lead REPRODUCED ; 1 if none reproduced ; 2 usage/harness error.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
MANIFEST="" ; OUT="$PWD/screen-out" ; DEMO=0

need() { [ "$1" -ge 2 ] || { echo "screen-leads.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) need "$#"; MANIFEST="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --demo) DEMO=1; shift ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "screen-leads.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "screen-leads.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

SCREENER="$HERE/auditor/agents/poc-screener.ag"
[ -f "$SCREENER" ] || { echo "screen-leads.sh: screener agent not found at $SCREENER" >&2; exit 3; }

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$SCREENER" "$RUN/poc-screener.ag"

# --demo: write three illustrative harnesses (a reproduced vuln, a held secure variant, a junk harness)
# into the rundir and screen them — zero external prerequisites, proves the eval_ag gate end-to-end.
if [ "$DEMO" -eq 1 ]; then
  MANIFEST="$RUN/demo-leads.tsv"
  # Reproduced: a withdraw() that updates the recorded balance AFTER the external call (CEI violation),
  # so a re-entrant second withdraw drains the un-zeroed balance -> pooled TVL below the honest floor.
  cat > "$RUN/lead_reentrancy_vuln.ag" <<'AG'
fn withdraw_vuln(pool: int, my_recorded: int) -> int {
    let after_first = pool - my_recorded;
    let after_reentry = after_first - my_recorded;   // 2nd withdraw on the SAME un-zeroed balance
    return after_reentry;
}
let stake = 100; let pool = 1000;
let control_ok = (pool - stake) == 900;              // CONTROL: honest single withdraw conserves
let drained = withdraw_vuln(pool, stake);            // EXPLOIT: re-entrant double withdraw
let invariant_violated = drained < (pool - stake);
if control_ok { if invariant_violated { 101; } else { 0; } } else { 2; }
AG
  # Held: the secure variant zeroes the balance BEFORE the external call -> re-entry withdraws 0.
  cat > "$RUN/lead_reentrancy_fixed.ag" <<'AG'
fn withdraw_secure(pool: int, my_recorded: int) -> int {
    let after_first = pool - my_recorded;
    let after_reentry = after_first - 0;             // balance zeroed before the call -> re-entry takes 0
    return after_reentry;
}
let stake = 100; let pool = 1000;
let control_ok = (pool - stake) == 900;
let drained = withdraw_secure(pool, stake);
let invariant_violated = drained < (pool - stake);
if control_ok { if invariant_violated { 101; } else { 0; } } else { 2; }
AG
  # Junk: not valid agentis source -> eval_ag's stable `parse_error` discriminator catches it.
  cat > "$RUN/lead_junk.ag" <<'AG'
this is not @@ valid agentis source !!!
AG
  {
    printf '%s | %s\n' "savings:reentrancy"       "$RUN/lead_reentrancy_vuln.ag"
    printf '%s | %s\n' "savings:reentrancy-fixed" "$RUN/lead_reentrancy_fixed.ag"
    printf '%s | %s\n' "bad-harness"              "$RUN/lead_junk.ag"
  } > "$MANIFEST"
  echo "screen-leads.sh: --demo wrote 3 leads to $MANIFEST" >&2
fi

[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || { echo "screen-leads.sh: --manifest <leads.tsv> required (or --demo)" >&2; exit 2; }

# init the agentis store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "trace.level = normal"
  # The screener reads the harness via exec sh (sandbox-resolved) and runs it via eval_ag.
  echo "exec.env_passthrough = POC_HARNESS,LEAD_ID"
  echo "exec.default_timeout_ms = 30000"
  # eval_ag is a metered sub-interpreter; allow it without granting the inner program new caps.
  echo "eval_ag = allow"
  # Record every screen as substrate experience so screen fitness (reproduced/held/junk) accrues.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

REPORT="$OUT/screen-report.md"
{
  echo "# Dark Factory — substrate-native lead pre-screen (eval_ag)"
  echo
  echo "- Each lead's self-contained \`.ag\` PoC harness is evaluated through the substrate's \`eval_ag\`"
  echo "  primitive (a metered sub-interpreter with its own CB budget; CB-exhaustion containment only,"
  echo "  NOT an exec sandbox — feed it operator-trusted harnesses)."
  echo "- A REPRODUCED lead is still UNVERIFIED for submission — it is a finding ONLY after the full"
  echo "  \`evm-harness/forge-verify.sh\` Foundry repro passes. This screen just decides what is WORTH that."
  echo
  echo "| Lead | Verdict | eval_ag outcome | Return |"
  echo "|---|---|---|---|"
} > "$REPORT"

LEADS=0 ; REPRODUCED=0 ; HELD=0 ; INDET=0
# Manifest loop: screen one lead per line through the substrate screener.
while IFS='|' read -r LEAD HARNESS || [ -n "${LEAD:-}" ]; do
  LEAD="$(printf '%s' "$LEAD" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$LEAD" in ''|\#*) continue ;; esac
  HARNESS="$(printf '%s' "$HARNESS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$HARNESS" ] || { echo "screen-leads.sh: lead '$LEAD' has no harness path; skipping" >&2; continue; }
  # Resolve to absolute — the screener runs from $RUN, so a relative path would miss.
  case "$HARNESS" in /*) : ;; *) HARNESS="$PWD/$HARNESS" ;; esac
  LEADS=$((LEADS + 1))
  CELL_LOG="$RUN/screen_$(printf '%s' "$LEAD" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//').log"
  echo "screen-leads.sh: screening lead '$LEAD' ..." >&2
  ( cd "$RUN" && env LEAD_ID="$LEAD" POC_HARNESS="$HARNESS" \
      "$AGENTIS" go poc-screener.ag --enable-exec --enable-eval-ag --enable-messaging ) >"$CELL_LOG" 2>&1 || \
      echo "screen-leads.sh: screener run failed for '$LEAD' (see $CELL_LOG)" >&2
  # The screener's contract: a single `SCREENED|<lead>|<class>|<outcome>|<ret>` line.
  LINE="$(grep -m1 'SCREENED|' "$CELL_LOG" || true)"
  if [ -z "$LINE" ]; then
    printf '| %s | (no verdict) | — | — |\n' "$LEAD" >> "$REPORT"
    INDET=$((INDET + 1)); continue
  fi
  KLASS="$(printf '%s' "$LINE" | cut -d'|' -f3)"
  OUTCOME="$(printf '%s' "$LINE" | cut -d'|' -f4)"
  RET="$(printf '%s' "$LINE" | cut -d'|' -f5)"
  printf '| %s | %s | %s | %s |\n' "$LEAD" "$KLASS" "$OUTCOME" "$RET" >> "$REPORT"
  case "$KLASS" in
    reproduced) REPRODUCED=$((REPRODUCED + 1)) ;;
    held)       HELD=$((HELD + 1)) ;;
    *)          INDET=$((INDET + 1)) ;;
  esac
done < "$MANIFEST"

{
  echo
  echo "---"
  echo "Leads screened: $LEADS    reproduced: $REPRODUCED    held: $HELD    indeterminate: $INDET"
  echo
  echo "NEXT: forge-verify each REPRODUCED lead (\`evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>\`)."
  echo "A reproduced screen is a LEAD worth that cost, not a finding. Submission stays human-gated."
} >> "$REPORT"

echo >&2
echo "================ SCREEN: $LEADS leads — $REPRODUCED reproduced, $HELD held, $INDET indeterminate ================" >&2
echo "screen-leads.sh: report at $REPORT" >&2
[ "$REPRODUCED" -gt 0 ]