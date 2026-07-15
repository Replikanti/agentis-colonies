#!/usr/bin/env bash
# run-capability-bench.sh — the dark-factory CAPABILITY bench (#1490). It measures the thing that actually
# gates earnings on an audited target: does the discover -> evaluate -> DEVISE -> attack -> novelty-gate
# pipeline surface a bug N prior auditors MISSED, and never re-surface one they already found?
#
# A fixture under bench/fixtures/<name>/ carries: `src/` code with an audit-SURVIVING (residual) bug,
# `audit.txt` (the provided audit = the KNOWN-issue exclusion boundary), and `truth.tsv` (ground truth:
# `boundary` rows = known findings that MUST stay excluded, `residual` rows = the audit-surviving bug the
# DEVISE stage should surface). The bench scores a run against that truth in two stages:
#
#   STAGE 1 — NOVELTY DISCRIMINATION (deterministic, CI-safe, no LLM). For each `boundary` row a restatement
#     fed to novelty-gate.sh MUST return KNOWN; for each `residual` row it MUST return NOVEL. This is the
#     safety property (never re-report a known bug, never suppress a real one) and needs no backend, so it
#     gates the bench exit code on CI.
#   STAGE 2 — DEVISE RECALL (live; only with --live AND agentis on PATH AND a real backend). Runs
#     audit-scout.ag over the fixture through a REAL backend, extracts its RESIDUAL leads, and scores by
#     RESIDUAL RECALL (the PASS metric): each `residual` truth signature is a HIT when some lead overlaps it
#     (overlap judged by novelty-gate.sh). BOUNDARY coverage (how many known findings devise re-listed) and
#     boundary-overlap (leads that touch a boundary function) are reported as ADVISORY, never gated — a real
#     residual legitimately references a boundary function, so boundary overlap over-counts "restatements"
#     (#1496). This measures the LLM-limited capability model routing calibrates against — a weak model
#     legitimately scores low; that is the bench telling the truth, not a regression.
#     The backend defaults to bench/lib/claude-p-backend.sh (a reliable `claude -p` adapter, no flat-cyborg
#     PTY). Validated reference: audit-scout on opus over `rounding-residual` = recall 1/1, boundary 2/2.
#
# Usage: run-capability-bench.sh [--fixture <dir>] [--live] [--json] [--min-overlap N] [-h]
#   --fixture <dir>  fixture dir (default: bench/fixtures/rounding-residual, resolved next to this script).
#   --live           also run STAGE 2 (needs agentis + a real backend; set BENCH_LIVE=1 as an alias).
#   --json           emit the scorecard as one JSON object on stdout (human table still goes to stderr).
#   --min-overlap N  salient-term overlap threshold passed to novelty-gate.sh (default 2).
# Env (STAGE 2 only): BENCH_LLM_COMMAND (llm.command; default bench/lib/claude-p-backend.sh), BENCH_LLM_MODEL
#   (default opus; sonnet for the routing tier), BENCH_CLAUDE_BIN (claude binary; default `claude`).
# Exit: 0 = all RUN stages passed ; 1 = a stage failed ; 2 = bad args / missing fixture.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DF="$(cd "$HERE/.." && pwd)"                 # dark-factory/
GATE="$DF/novelty-gate.sh"
SCOUT="$DF/auditor/agents/audit-scout.ag"
FETCH="$DF/fetch-audits.sh"

nv() { [ "$1" -ge 2 ] || { echo "run-capability-bench.sh: $2 requires a value" >&2; exit 2; }; }
FIXTURE="$HERE/fixtures/rounding-residual" ; LIVE=0 ; JSON=0 ; MINOV=2
[ "${BENCH_LIVE:-0}" = "1" ] && LIVE=1
while [ $# -gt 0 ]; do case "$1" in
  --fixture)     nv "$#" "$1"; FIXTURE="$2"; shift 2;;
  --live)        LIVE=1; shift;;
  --json)        JSON=1; shift;;
  --min-overlap) nv "$#" "$1"; MINOV="$2"; shift 2;;
  -h|--help)     sed -n '2,30p' "$0"; exit 0;;
  *) echo "run-capability-bench.sh: unknown arg: $1" >&2; exit 2;;
esac; done

[ -f "$GATE" ]           || { echo "run-capability-bench.sh: novelty-gate.sh not found at $GATE" >&2; exit 2; }
[ -d "$FIXTURE" ]        || { echo "run-capability-bench.sh: fixture dir not found: $FIXTURE" >&2; exit 2; }
[ -f "$FIXTURE/audit.txt" ] || { echo "run-capability-bench.sh: fixture missing audit.txt: $FIXTURE" >&2; exit 2; }
[ -f "$FIXTURE/truth.tsv" ] || { echo "run-capability-bench.sh: fixture missing truth.tsv: $FIXTURE" >&2; exit 2; }
AUDIT="$FIXTURE/audit.txt"
command -v python3 >/dev/null 2>&1 || { echo "run-capability-bench.sh: [SKIP] python3 not installed (novelty-gate needs it)" >&2; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
say() { echo "run-capability-bench.sh: $*" >&2; }

# novelty-gate as an oracle: is `text` KNOWN (overlaps) w.r.t. exclusion file `$1`? echo 1 if KNOWN else 0.
# The finding is fed on STDIN (novelty-gate reads stdin when given no finding-file positional).
overlaps() { # $1 = exclusion file, stdin = text
  local rc
  "$GATE" --exclusion "$1" --min-overlap "$MINOV" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && echo 1 || echo 0
}

# ---- STAGE 1 — NOVELTY DISCRIMINATION (deterministic) -------------------------------------------------
say "STAGE 1 — novelty discrimination (deterministic, no backend) on $(basename "$FIXTURE")"
s1_total=0 ; s1_pass=0
while IFS=$'\t' read -r typ sig _cls; do
  case "$typ" in boundary|residual) : ;; *) continue;; esac
  [ -n "${sig:-}" ] || continue
  s1_total=$((s1_total+1))
  km="$(printf '%s' "$sig" | overlaps "$AUDIT")"
  if [ "$typ" = "boundary" ]; then
    if [ "$km" = "1" ]; then s1_pass=$((s1_pass+1)); say "  [OK]   boundary -> KNOWN (correctly excluded)"
    else say "  [FAIL] boundary -> NOVEL (would re-report a known bug): $sig"; fi
  else
    if [ "$km" = "0" ]; then s1_pass=$((s1_pass+1)); say "  [OK]   residual -> NOVEL (correctly passed)"
    else say "  [FAIL] residual -> KNOWN (would suppress a real bug): $sig"; fi
  fi
done < "$FIXTURE/truth.tsv"
s1_ok=0; [ "$s1_total" -gt 0 ] && [ "$s1_pass" -eq "$s1_total" ] && s1_ok=1
say "STAGE 1: $s1_pass/$s1_total correct -> $([ "$s1_ok" = 1 ] && echo PASS || echo FAIL)"

# ---- STAGE 2 — DEVISE RECALL (live) ------------------------------------------------------------------
s2_run=0 ; s2_hits=0 ; s2_residuals=0 ; s2_fp=0 ; s2_leads=0 ; s2_boundary=0 ; s2_ok=1
# The real backend: agentis's `llm.command` "cli" contract is `claude -p`-shaped (`-p --output-format json`
# + prompt on stdin), so the reliable default is bench/lib/claude-p-backend.sh (a thin `claude -p` adapter,
# no flat-cyborg PTY — whose one-shot cold-start proved flaky). BENCH_LLM_COMMAND overrides it (e.g. point at
# the federation's flat-cyborg-claude.sh for flat-rate); BENCH_LLM_MODEL (default opus) picks the model.
BENCH_LLM_COMMAND="${BENCH_LLM_COMMAND:-$HERE/lib/claude-p-backend.sh}"
_backend_bin="${BENCH_CLAUDE_BIN:-claude}"
if [ "$LIVE" = "1" ]; then
  if ! command -v agentis >/dev/null 2>&1; then
    say "STAGE 2 — [SKIP] --live set but agentis not on PATH"
  elif [ "$BENCH_LLM_COMMAND" = "$HERE/lib/claude-p-backend.sh" ] && ! command -v "$_backend_bin" >/dev/null 2>&1; then
    say "STAGE 2 — [SKIP] --live set but no real backend ('$_backend_bin' not on PATH; set BENCH_LLM_COMMAND to override)"
  else
    s2_run=1
    mkdir -p "$WORK/audits" "$WORK/run"
    cp "$AUDIT" "$WORK/audits/01-audit.txt"
    cp "$SCOUT" "$WORK/run/audit-scout.ag"
    ( cd "$WORK/run" && agentis init >/dev/null 2>&1 || true )
    {
      echo "llm.backend = claude"; echo "llm.command = $BENCH_LLM_COMMAND"
      echo "learning.enabled = true"; echo "experience.enabled = true"; echo "exec.default_timeout_ms = 60000"
      echo "exec.env_passthrough = TARGET_DIR,IN_SCOPE,AUDIT_DIR,AUDIT_URLS,FETCH_AUDITS,SCOPE_BRIEF"
    } >> "$WORK/run/.agentis/config"
    say "STAGE 2 — devise recall: running audit-scout.ag on $(basename "$FIXTURE") ..."
    (
      cd "$WORK/run" || exit 90
      export TARGET_DIR="$FIXTURE" IN_SCOPE="src/ShareVault.sol" \
             AUDIT_DIR="$WORK/audits" FETCH_AUDITS="$FETCH" SCOPE_BRIEF=""
      # --grant-pii: TARGET_DIR + fetched audits carry contract source/addresses that trip the PII
      # heuristic; the fixture is benign public contract text, backend is LIVE claude (#1690).
      agentis go audit-scout.ag --enable-exec --enable-messaging --grant-pii
    ) >"$WORK/scout.out" 2>&1 || say "  (audit-scout exited non-zero; scoring whatever RESIDUAL leads it printed)"
    grep '^RESIDUAL|' "$WORK/scout.out" > "$WORK/leads.txt" 2>/dev/null || true
    s2_leads="$(wc -l < "$WORK/leads.txt" | tr -d ' ')"
    s2_boundary="$(grep -c '^BOUNDARY|' "$WORK/scout.out" 2>/dev/null || echo 0)"
    say "  audit-scout produced $s2_leads RESIDUAL lead(s) + $s2_boundary BOUNDARY line(s)"
    # RECALL (the PASS metric): each `residual` truth row is a HIT if some lead overlaps its signature.
    while IFS=$'\t' read -r typ sig _cls; do
      [ "$typ" = "residual" ] || continue
      [ -n "${sig:-}" ] || continue
      s2_residuals=$((s2_residuals+1))
      printf '%s\n' "$sig" > "$WORK/res.sig"
      hit=0
      while IFS= read -r lead; do
        [ -n "$lead" ] || continue
        [ "$(printf '%s' "$lead" | overlaps "$WORK/res.sig")" = "1" ] && { hit=1; break; }
      done < "$WORK/leads.txt"
      if [ "$hit" = 1 ]; then s2_hits=$((s2_hits+1)); say "  [HIT]  residual surfaced by a devise lead"
      else say "  [MISS] residual not surfaced: $sig"; fi
    done < "$FIXTURE/truth.tsv"
    # ADVISORY (not a PASS gate): leads that overlap the audit boundary. This over-counts — a genuine residual
    # legitimately references a boundary function (e.g. "the reentrancy-focused audit never modelled the share
    # path"), and function-token overlap alone then reads as a restatement (see #1496). Reported, never failed on.
    while IFS= read -r lead; do
      [ -n "$lead" ] || continue
      [ "$(printf '%s' "$lead" | overlaps "$AUDIT")" = "1" ] && s2_fp=$((s2_fp+1))
    done < "$WORK/leads.txt"
    # PASS = full residual recall (DEVISE surfaced every audit-surviving bug). BOUNDARY coverage + boundary-
    # overlap count are reported for insight, not gated.
    { [ "$s2_residuals" -gt 0 ] && [ "$s2_hits" -eq "$s2_residuals" ]; } || s2_ok=0
    say "STAGE 2: recall $s2_hits/$s2_residuals, boundary-lines $s2_boundary, boundary-overlap(advisory) $s2_fp -> $([ "$s2_ok" = 1 ] && echo PASS || echo FAIL)"
  fi
else
  say "STAGE 2 — devise recall not run (pass --live with agentis + a real backend to measure capability)"
fi

# ---- scorecard + exit --------------------------------------------------------------------------------
overall=0; [ "$s1_ok" = 1 ] || overall=1
[ "$s2_run" = 1 ] && { [ "$s2_ok" = 1 ] || overall=1; }
if [ "$JSON" = 1 ]; then
  printf '{"fixture":"%s","stage1":{"pass":%d,"total":%d,"ok":%s},"stage2":{"run":%s,"leads":%d,"boundary_lines":%d,"recall_hits":%d,"residuals":%d,"boundary_overlap_advisory":%d,"ok":%s},"overall_pass":%s}\n' \
    "$(basename "$FIXTURE")" "$s1_pass" "$s1_total" "$([ "$s1_ok" = 1 ] && echo true || echo false)" \
    "$([ "$s2_run" = 1 ] && echo true || echo false)" "${s2_leads:-0}" "${s2_boundary:-0}" "$s2_hits" "$s2_residuals" "$s2_fp" \
    "$([ "$s2_ok" = 1 ] && echo true || echo false)" "$([ "$overall" = 0 ] && echo true || echo false)"
fi
say "OVERALL -> $([ "$overall" = 0 ] && echo PASS || echo FAIL)"
exit "$overall"
