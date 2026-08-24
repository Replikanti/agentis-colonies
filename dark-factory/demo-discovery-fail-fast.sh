#!/usr/bin/env bash
# demo-discovery-fail-fast.sh — regression guard for the #2017 discovery fail-fast: a hunter cell whose
# generation runs away (busts llm.cli_timeout_ms with ZERO output) must consume ONE budget, not three.
#
# ROOT CAUSE (#2017): a non-terminating value-seam read on a logic-free struct file (the storage C15 case)
# blows through the per-cell llm.cli_timeout_ms; agentis-core then re-runs a `[llm.timeout]` `1 + llm.max_retries`
# times (src/llm.rs `attempts = 1 + max_retries`, default max_retries = 2 => 3 attempts), so a single hang costs
# ~3x the budget — up to ~90 min on an 1800s-capped dense zone. run-discovery.sh never set llm.max_retries, so
# every hunter cell inherited the default 3 attempts. Setting `llm.max_retries = 0` in the per-cell
# `.agentis/config` caps a timed-out cell at ONE attempt — entirely colonies-side, no core change.
#
# Two layers (mirrors demo-experience-flags.sh / demo-cell-watchdog.sh):
#   1) SOURCE GUARD (always, CI-safe, pure grep): run-discovery.sh must emit `llm.max_retries = 0` and MUST NOT
#      emit any `llm.max_retries = <1-9…>` form. This fails the exact regression even where agentis is absent.
#   2) END-TO-END MUTATION (agentis-gated, [SKIP] without agentis): drive a REAL offline `agentis go` TWICE over
#      a trivial `prompt()` probe whose backend is a `sleep` stub that never returns before the (tiny) budget,
#      so the runtime ALWAYS hits `[llm.timeout]`. With `llm.max_retries = 2` the run emits two `[LLM retry N/2`
#      lines and burns ~3x the budget; with `llm.max_retries = 0` it emits NONE and burns ~1x. This proves the
#      fail-fast at OUTPUT level (attempts actually taken), with NO live LLM — closing the "green stub proves
#      nothing" gap. Generous timing bounds (like demo-cell-watchdog.sh) keep it non-flaky.
#
# Read-only, offline, never-submit. Exit 0 = guard holds (or cleanly skipped); 1 = a regression; 3 = missing script.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DISCOVERY="$HERE/run-discovery.sh"

FAILS=0
note() { echo "demo-discovery-fail-fast.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -x "$DISCOVERY" ] || { note "run-discovery.sh not found / not executable: $DISCOVERY" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE GUARD (always): run-discovery.sh emits `llm.max_retries = 0` and nothing that re-enables retries.
# ----------------------------------------------------------------------------------------------------------
note "1) source-guard: run-discovery.sh emits llm.max_retries = 0 (one attempt per cell) ..."
if grep -Eq 'echo "llm\.max_retries = [1-9]' "$DISCOVERY"; then
  bad "run-discovery.sh emits a NON-ZERO llm.max_retries — a timed-out cell would re-run the same hang N extra times (#2017)"
  grep -nE 'echo "llm\.max_retries = [1-9]' "$DISCOVERY" | sed 's/^/      /' >&2
elif grep -Eq 'echo "llm\.max_retries = 0"' "$DISCOVERY"; then
  ok "run-discovery.sh emits llm.max_retries = 0 — a runaway cell fails after ONE budget, not three"
else
  bad "run-discovery.sh emits NO explicit llm.max_retries — the per-cell config inherits the default 3 attempts (#2017)"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) END-TO-END MUTATION (agentis-gated): the 1-vs-3 attempt effect over a real `agentis go`, sleep-stub LLM.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the live 1-vs-3 attempt mutation (layer 2)"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-discovery-fail-fast.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  ( cd "$WORK" && agentis init >/dev/null 2>&1 )

  # A trivial one-shot probe: a single prompt() whose backend never returns in time -> always `[llm.timeout]`.
  cat > "$WORK/probe.ag" <<'AG'
cb 3000;
let r = prompt("say hi", "") -> string;
print("REPLY|" + r);
AG

  # Backend stub = `sleep 30` (prompt is piped to stdin and ignored): the child outlives the tiny
  # llm.cli_timeout_ms every time, so the completion loop always raises LlmError::Timeout — the retryable path.
  BUDGET_MS=1500
  gen_cfg() {
    {
      echo "llm.backend = claude"
      echo "llm.command = sleep"
      echo "llm.args = 30"
      echo "llm.cli_timeout_ms = $BUDGET_MS"
      echo "llm.max_retries = $1"
      echo "trace.level = normal"
    } > "$WORK/.agentis/config"
  }

  run_probe() {   # run_probe <max_retries> <log> -> echoes elapsed seconds
    gen_cfg "$1"
    _t0=$(date +%s)
    ( cd "$WORK" && agentis go probe.ag ) > "$2" 2>&1 || true
    _t1=$(date +%s)
    echo $(( _t1 - _t0 ))
  }

  note "2) live mutation: a runaway (timing-out) cell consumes ONE attempt with max_retries=0, three with =2 ..."

  # --- default-style: max_retries = 2 -> 3 attempts, two retry lines, ~3x the budget ---------------------
  EL2="$(run_probe 2 "$WORK/retry2.log")"
  RETRIES2="$(grep -c '\[LLM retry' "$WORK/retry2.log" 2>/dev/null || true)"
  if grep -q '\[llm.timeout\]\|timed out' "$WORK/retry2.log" 2>/dev/null && [ "$RETRIES2" -eq 2 ]; then
    ok "max_retries=2: the timed-out cell was retried twice ($RETRIES2 '[LLM retry N/2' lines), ~3x the budget (${EL2}s)"
  else
    bad "max_retries=2: expected 2 '[LLM retry' lines on the timeout path, saw $RETRIES2 (elapsed ${EL2}s)"
    grep -n '\[LLM retry\|timed out\|Error' "$WORK/retry2.log" 2>/dev/null | head -4 | sed 's/^/      /' >&2
  fi

  # --- the fix: max_retries = 0 -> 1 attempt, zero retry lines, ~1x the budget ---------------------------
  EL0="$(run_probe 0 "$WORK/retry0.log")"
  RETRIES0="$(grep -c '\[LLM retry' "$WORK/retry0.log" 2>/dev/null || true)"
  if grep -q '\[llm.timeout\]\|timed out' "$WORK/retry0.log" 2>/dev/null && [ "$RETRIES0" -eq 0 ]; then
    ok "max_retries=0: the timed-out cell failed after ONE attempt (no '[LLM retry' line), ~1x the budget (${EL0}s)"
  else
    bad "max_retries=0: expected 0 '[LLM retry' lines (single attempt), saw $RETRIES0 (elapsed ${EL0}s)"
    grep -n '\[LLM retry\|timed out\|Error' "$WORK/retry0.log" 2>/dev/null | head -4 | sed 's/^/      /' >&2
  fi

  # --- the load-bearing contrast: fewer attempts => strictly less wall-time on the SAME hang ------------
  if [ "$RETRIES0" -eq 0 ] && [ "$RETRIES2" -eq 2 ] && [ "$EL0" -lt "$EL2" ]; then
    ok "the same runaway hang cost ${EL0}s at max_retries=0 vs ${EL2}s at max_retries=2 — the fix bounds the waste"
  else
    bad "the fail-fast did not shorten the timeout path (max_retries=0 ${EL0}s vs max_retries=2 ${EL2}s)"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — run-discovery.sh caps a runaway hunter cell at one budget (#2017 fail-fast)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed (see #2017)" >&2
exit 1
