#!/usr/bin/env bash
# demo-experience-flags.sh — regression guard for the experience/learning flags on the WHOLE hunt +
# submission path (#1881 for run-discovery/run-refute, extended by #1878 to six more scripts).
#
# MECHANISM (measured on agentis v1.28.0, #1878 — the earlier "the .ag READS experience intra-run" reading
# was wrong): what `experience.enabled` gates is the `learn()` WRITE. With `experience.enabled = false`,
# `learn()` raises `runtime error: experience not enabled (set experience.enabled = true)` — and ANY runtime
# error makes agentis DISCARD the program's whole accumulated stdout, so a cell that already `print`ed its
# verdict line emits NOTHING. Every .ag behind the eight scripts below ends its tick with `learn()`, so the
# flag is load-bearing at OUTPUT level everywhere: the sentinel the driver greps (`CANDIDATE|`, `VERDICT|`,
# `SCREENED|`, `DARK-FACTORY:BRIEF-BEGIN|`, `SYMBOLIC|`, `POC|`, the pass stage lines, a gate's verdict line)
# silently vanishes and the stage reports an empty/negative result instead of an error. That is #1877's
# silent FALSE ZERO. CI missed #1877 because the offline demos drive a STUB `agentis` (see
# demo-discovery-parallel.sh's `--agentis "$STUB"`) that never interprets the .ag — the textbook "gate the
# artifact on INPUT (config written) not OUTPUT (a real cell running)" trap. This demo closes that.
#
# `learning.enabled` is a DIFFERENT gate: it controls `recommend()` / `adapt()` / `score_options()` only.
# Measured: with `learning.enabled = false` and experience on, `learn()` still succeeds and writes the
# IDENTICAL experience row (same `delta`). None of the agents on these eight paths calls a read primitive, so
# a `learning.enabled` flip is NOT observable in any live cell here — layer 1's source guard is what catches
# it. That asymmetry is deliberate and stated, not hidden: the flag is kept paired so a future
# recommend()/adapt() call cannot make `agentis go` refuse to start.
#
# Three layers:
#   1)  SOURCE GUARD (always, CI-safe): each of the eight scripts must emit `experience.enabled = true` and
#       `learning.enabled = true`, and MUST NOT emit the `= false` form.
#   1c) KNOWLEDGE FLAG (always, CI-safe, #1887): the two scripts whose agents call an adaptive READ builtin —
#       run-discovery.sh (hunter.ag's `query_knowledge("refute-constraint", …)`) and map-zones.sh
#       (zone-mapper.ag's `recommend`/`query_knowledge("hunt-fitness", …)`) — must emit
#       `knowledge.enabled = true`. Same failure curve as above: without it the call raises `knowledge base
#       not enabled`, the cell's stdout is discarded, and the stage reports a false zero.
#   1b) NO-`= false` RATCHET (always, CI-safe): NO script in dark-factory/ or dark-factory/auditor/scripts/
#       may emit `experience.enabled = false` / `learning.enabled = false` unless the line carries the
#       annotation `# experience-flags: intentional-off (<reason>)`. Catches a flip in a script that is not
#       on the list above.
#   2)  LIVE CELLS (only when `agentis` is on PATH, [SKIP] otherwise): one REAL offline `agentis go` per
#       script (`--backend mock` or no LLM at all; ~2.5 s total). Each asserts (a) no `experience not
#       enabled` under the out-dir AND (b) a POSITIVE CONTROL — the `"action":"<name>"` row the agent's
#       `learn()` writes into `.agentis/experience/main.jsonl` (or, for the store-less gate runner, the
#       probe's verdict line on stdout). Without (b) an assertion of shape (a) passes VACUOUSLY when the
#       cell never ran — the exact #1877 trap.
#   3)  ACCRUAL PROBE (screen-leads only): the same leads screened in a 3-lead and a 2-lead manifest produce
#       byte-identical rows for the surviving leads — pinning the corrected comments' claim that NO
#       within-run accrual reaches output on the shared-store loop shape.
#
# LIMITATION (stated, not hidden): on the `--backend mock` cells the LLM reply is canned, so an accrual
# effect acting THROUGH the prompt would not be observable offline. The no-accrual claim therefore rests on
# the static builtin inventory (no agent on these paths calls recommend/adapt/score_options) plus layer 3's
# empirical result on screen-leads.
#
# Read-only, offline, never-submit. Exit 0 = guards hold (or cleanly skipped); 1 = a regression; 3 = missing script.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DISCOVERY="$HERE/run-discovery.sh"
REFUTE="$HERE/run-refute.sh"
SCREEN="$HERE/screen-leads.sh"
BRIEFS="$HERE/gen-briefs.sh"
SYMBOLIC="$HERE/run-symbolic.sh"
POC="$HERE/run-poc.sh"
PASS="$HERE/run-audit-pass.sh"
GATE="$HERE/auditor/scripts/run-gate-agent.sh"
# #1887: not on the eight-script experience list — map-zones.sh is here only for the knowledge-flag guard
# below, because zone-mapper.ag calls recommend()/query_knowledge().
MAPZONES="$HERE/map-zones.sh"

FAILS=0
note() { echo "demo-experience-flags.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

for s in "$DISCOVERY" "$REFUTE" "$SCREEN" "$BRIEFS" "$SYMBOLIC" "$POC" "$PASS" "$GATE" "$MAPZONES"; do
  [ -x "$s" ] || { note "script not found / not executable: $s" >&2; exit 3; }
done

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE GUARD (always): the flags each hunt/submission-path script emits. The guard is deliberately on
#    the emitted STRING so it fails the exact #1877 flip even where agentis is absent.
# ----------------------------------------------------------------------------------------------------------
note "1) source-guard: the 8 hunt/submission-path scripts emit experience/learning.enabled = true (not false) ..."
guard_script() {
  s="$1"; base="$(basename "$s")"
  if grep -Eq 'echo "experience\.enabled = false"' "$s" || grep -Eq 'echo "learning\.enabled = false"' "$s"; then
    bad "$base emits experience/learning.enabled = FALSE — the #1877/#1881/#1878 regression (learn() hard-errors, the cell's stdout is discarded, the sentinel vanishes)"
  elif grep -Eq 'echo "experience\.enabled = true"' "$s" && grep -Eq 'echo "learning\.enabled = true"' "$s"; then
    ok "$base emits experience.enabled = true + learning.enabled = true"
  else
    bad "$base does not emit an explicit experience/learning.enabled = true — the guard cannot confirm the flags are on"
  fi
}
guard_script "$DISCOVERY"
guard_script "$REFUTE"
guard_script "$SCREEN"
guard_script "$BRIEFS"
guard_script "$SYMBOLIC"
guard_script "$POC"
guard_script "$PASS"
guard_script "$GATE"

# 1c) KNOWLEDGE FLAG (#1887): a THIRD flag on exactly the same failure curve. `knowledge.enabled` gates the
#     adaptive READ primitives — `query_knowledge()` / `recommend()` — and with it off the call raises
#     `runtime error: knowledge base not enabled`, which (like every runtime error) makes agentis DISCARD the
#     cell's whole stdout. Two scripts run an agent that calls one: run-discovery.sh (hunter.ag's #1887
#     refute-constraint read) and map-zones.sh (zone-mapper.ag's #1711 hunt-fitness read). Dropping the flag
#     from either is a silent FALSE ZERO for that whole stage, not a lost feature.
note "1c) source-guard: the 2 scripts whose agents call an adaptive READ builtin emit knowledge.enabled = true ..."
guard_knowledge() {
  s="$1"; base="$(basename "$s")"
  if grep -Eq 'echo "knowledge\.enabled = false"' "$s"; then
    bad "$base emits knowledge.enabled = FALSE — query_knowledge()/recommend() then hard-errors and the cell's stdout is discarded (#1887, the #1877 class)"
  elif grep -Eq 'echo "knowledge\.enabled = true"' "$s"; then
    ok "$base emits knowledge.enabled = true"
  else
    bad "$base does not emit knowledge.enabled = true, but its agent calls an adaptive READ builtin — every cell would hard-error and return a false zero"
  fi
}
guard_knowledge "$DISCOVERY"
guard_knowledge "$MAPZONES"

# ----------------------------------------------------------------------------------------------------------
# 1b) NO-`= false` RATCHET (always): no script anywhere in this federation may silently flip a flag off. The
#     escape hatch is an explicit annotation on the same line, so an intentional off is a reviewed decision.
#     Globs are scoped to THIS federation's own directories — never a recursive scan from the repo root.
# ----------------------------------------------------------------------------------------------------------
note "1b) ratchet: no dark-factory script emits experience/learning.enabled = false without an annotation ..."
OFFENDERS="$(grep -n -E 'echo "(experience|learning)\.enabled = false"' \
               "$HERE"/*.sh "$HERE"/auditor/scripts/*.sh 2>/dev/null \
             | grep -v 'experience-flags: intentional-off' || true)"
if [ -n "$OFFENDERS" ]; then
  bad "a dark-factory script emits an unannotated experience/learning.enabled = false:"
  printf '%s\n' "$OFFENDERS" | sed 's/^/      /' >&2
else
  ok "no unannotated '= false' flag emission in dark-factory/*.sh or auditor/scripts/*.sh"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) LIVE CELLS (agentis-gated): one REAL offline cell per script. Each needs BOTH the error-absence check
#    and a positive control, or it passes vacuously when the cell never ran.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the 8 live output-level cells (layers 2 + 3)"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-experience-flags.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  ERR="experience not enabled"
  # #1887: the knowledge store's twin error. hunter.ag now calls query_knowledge(), so a dropped
  # `knowledge.enabled` produces the SAME output-level symptom through a DIFFERENT message — the live
  # discovery cell below is therefore the mutation-proof gate for the new read, not just for learn().
  KERR="knowledge base not enabled"

  # assert_cell <label> <out-dir> <expected-action>: (a) no runtime error under the out-dir, and (b) the
  # positive control — the experience row the agent's learn() wrote, which proves the cell REALLY ran.
  assert_cell() {
    _label="$1"; _dir="$2"; _action="$3"
    if grep -rq "$ERR" "$_dir" 2>/dev/null; then
      bad "$_label cell hit '$ERR' — the flag is off / learn() is gated"
      grep -rh "$ERR" "$_dir" 2>/dev/null | head -2 | sed 's/^/      /' >&2
      return
    fi
    if grep -rq "$KERR" "$_dir" 2>/dev/null; then
      bad "$_label cell hit '$KERR' — knowledge.enabled is off and the cell's stdout was discarded (#1887)"
      grep -rh "$KERR" "$_dir" 2>/dev/null | head -2 | sed 's/^/      /' >&2
      return
    fi
    if grep -rq "\"action\":\"$_action\"" "$_dir" 2>/dev/null; then
      ok "$_label cell ran a real agentis .ag and completed its learn() (experience row \"action\":\"$_action\")"
    else
      bad "$_label cell produced NO \"action\":\"$_action\" experience row — the learn() never completed (or the cell never ran)"
    fi
  }

  note "2) live cells: one real offline 'agentis go' per script (--backend mock / no LLM) ..."

  # --- discovery: one real hunter cell over a throwaway target -------------------------------------------
  REPO="$WORK/target"; mkdir -p "$REPO/contracts/vault"
  printf 'contract Vault { function deposit() public {} }\n' > "$REPO/contracts/vault/Vault.sol"
  printf 'vault deposits | C1 | contracts/vault/Vault.sol\n' > "$WORK/scope.tsv"
  printf '# brief\nInvariants to break: share accounting.\nKnown issues to exclude: none.\n' > "$WORK/brief.md"
  "$DISCOVERY" --repo "$REPO" --scope "$WORK/scope.tsv" --brief "$WORK/brief.md" \
    --only "vault deposits" --classes C1 --backend mock --agentis agentis --out "$WORK/disc" \
    >"$WORK/disc.out" 2>&1 || true
  assert_cell "run-discovery.sh (hunter.ag)" "$WORK/disc" "hunt"

  # --- refute: one real refuter cell over a throwaway candidate ------------------------------------------
  printf 'contract Vault { function deposit() public {} }\n' > "$WORK/vault_code.sol"
  printf 'Vault.sol:deposit | C1 | Medium | anyone can drain via deposit | vault_code.sol\n' > "$WORK/cands.tsv"
  "$REFUTE" --candidates "$WORK/cands.tsv" --code-dir "$WORK" \
    --only "Vault.sol:deposit" --backend mock --agentis agentis --out "$WORK/ref" \
    >"$WORK/ref.out" 2>&1 || true
  assert_cell "run-refute.sh (refuter.ag)" "$WORK/ref" "refute"

  # --- screen-leads: the self-contained 3-lead demo (eval_ag only, no LLM at all) ------------------------
  # Exits 1 when nothing reproduces, so `|| true`; the report row counts are the toolchain-independent
  # output-level assertion (with the flag off every lead falls to "(no verdict)" -> 0 reproduced, 0 held).
  "$SCREEN" --demo --out "$WORK/screen" >"$WORK/screen.out" 2>&1 || true
  assert_cell "screen-leads.sh (poc-screener.ag)" "$WORK/screen" "poc-screen"
  if grep -q 'reproduced: 1 *held: 1' "$WORK/screen/screen-report.md" 2>/dev/null; then
    ok "screen-leads.sh --demo report keeps its verdicts (1 reproduced, 1 held) — the SCREENED| lines survived"
  else
    bad "screen-leads.sh --demo report lost its verdicts (expected '1 reproduced, 1 held') — the SCREENED| lines were discarded"
  fi

  # --- gen-briefs: one zone through brief-writer.ag ------------------------------------------------------
  # DF_AGENT_MAX_ATTEMPTS=1: the mock reply never validates, and the default 5 retries buy no extra signal.
  GBREPO="$WORK/gb-repo"; mkdir -p "$GBREPO/contracts"
  printf 'contract Vault { function deposit() public {} }\n' > "$GBREPO/contracts/Vault.sol"
  cat > "$WORK/zones.json" <<'JSON'
[
  { "id": "z1", "name": "vault", "files": ["contracts/Vault.sol"], "loc": 10,
    "hardening_score": 50, "bug_classes_likely": ["C1"],
    "description": "vault deposits", "value_custody": true }
]
JSON
  printf 'vault | C1 | contracts/Vault.sol\n' > "$WORK/gb-scope.tsv"
  DF_AGENT_MAX_ATTEMPTS=1 "$BRIEFS" --zones "$WORK/zones.json" --scope "$WORK/gb-scope.tsv" \
    --out "$WORK/briefs" --repo "$GBREPO" --backend mock >"$WORK/briefs.out" 2>&1 || true
  assert_cell "gen-briefs.sh (brief-writer.ag)" "$WORK/briefs" "brief"

  # --- run-symbolic: one candidate with a fixture spec over a stub foundry project -----------------------
  # The VERDICT is deliberately not asserted: PROVED needs halmos, and a machine without it legitimately
  # yields HARNESS_ERROR. What must survive the flag is the SYMBOLIC| line -> a report row for the candidate.
  SYMREPO="$WORK/sym-repo"; mkdir -p "$SYMREPO/test" "$WORK/sym-fx"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\n' > "$SYMREPO/foundry.toml"
  printf 'contract SpecStub { function check() public pure {} }\n' > "$WORK/sym-fx/spec.t.sol"
  printf 'Ledger.sol:transferSafe | C1 | total value is conserved across a transfer | | spec.t.sol\n' > "$WORK/sym-cands.tsv"
  "$SYMBOLIC" --candidates "$WORK/sym-cands.tsv" --repo "$SYMREPO" --code-dir "$WORK/sym-fx" \
    --backend mock --out "$WORK/sym" >"$WORK/sym.out" 2>&1 || true
  assert_cell "run-symbolic.sh (symbolic-prover.ag)" "$WORK/sym" "symbolic-prove"
  # The REPORT row is NOT discriminating (the script writes HARNESS_ERROR when the line is missing); the cell
  # log's SYMBOLIC| line is, and it is toolchain-independent because only its PRESENCE is asserted.
  if grep -q '^SYMBOLIC|' "$WORK/sym"/run/symbolic_*.log 2>/dev/null; then
    ok "run-symbolic.sh cell log carries a SYMBOLIC| verdict line — the agent's stdout was not discarded"
  else
    bad "run-symbolic.sh cell log has NO SYMBOLIC| line at all — the agent's stdout was discarded (every candidate degrades to HARNESS_ERROR)"
  fi

  # --- run-poc: the --poc-fixture path over a stub foundry project ---------------------------------------
  # foundry.toml is REQUIRED: without it detect-toolchain.sh exits 2 before any agent runs, and the cell
  # would prove nothing. The verdict is toolchain-dependent (HARNESS_ERROR without forge) — only the
  # PRESENCE of a POC| line is flag-specific.
  POCREPO="$WORK/poc-repo"; mkdir -p "$POCREPO/src" "$POCREPO/test"
  printf '[profile.default]\nsrc = "src"\ntest = "test"\n' > "$POCREPO/foundry.toml"
  printf 'contract Vault { function deposit() public {} }\n' > "$POCREPO/src/Vault.sol"
  printf 'contract PocStub { function test_poc() public pure {} }\n' > "$WORK/poc-fixture.t.sol"
  "$POC" --repo "$POCREPO" --target "Vault.sol:Vault" --class C1 --poc-fixture "$WORK/poc-fixture.t.sol" \
    --backend mock --out "$WORK/poc" >"$WORK/poc.out" 2>&1 || true
  assert_cell "run-poc.sh (poc-writer.ag)" "$WORK/poc" "poc-write"
  if grep -q '^POC|' "$WORK/poc"/run/poc_*.log 2>/dev/null; then
    ok "run-poc.sh cell log carries a POC| verdict line — the agent's stdout was not discarded"
  else
    bad "run-poc.sh cell log has NO POC| line at all — the agent's stdout was discarded"
  fi

  # --- run-audit-pass: the offline --pass-fixture submission pass ----------------------------------------
  "$PASS" --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
    --out "$WORK/pass" >"$WORK/pass.out" 2>&1 || true
  assert_cell "run-audit-pass.sh (coordinator.ag::pass_step)" "$WORK/pass" "coordinator-pass"
  if [ "$(cat "$WORK/pass/pass-result.txt" 2>/dev/null)" = "PENDING-HUMAN-REVIEW" ]; then
    ok "run-audit-pass.sh reached PENDING-HUMAN-REVIEW — the coordinator's pass stage lines survived"
  else
    bad "run-audit-pass.sh pass-result.txt is not PENDING-HUMAN-REVIEW (got '$(cat "$WORK/pass/pass-result.txt" 2>/dev/null)') — the stage lines were discarded"
  fi

  # --- run-gate-agent: a demo-owned probe gate. This runner keeps NO store (mktemp -d + EXIT trap), so its
  #     only observable is the extracted verdict line: ON -> the line, OFF -> empty stdout.
  cat > "$WORK/probe-gate.ag" <<'AG'
cb 3000;
print("SCOPE-GATE|PAYABLE|experience-flags-probe");
learn("scope-gate", "experience-flags-probe", "probe gate run for demo-experience-flags.sh", "success", ["probe"]);
AG
  "$GATE" "$WORK/probe-gate.ag" --verdict-prefix SCOPE-GATE --backend mock \
    >"$WORK/gate.out" 2>"$WORK/gate.err" || true
  if [ "$(cat "$WORK/gate.out" 2>/dev/null)" = "SCOPE-GATE|PAYABLE|experience-flags-probe" ]; then
    ok "run-gate-agent.sh printed the probe gate's verdict line (its learn() completed; stdout not discarded)"
  else
    bad "run-gate-agent.sh printed '$(cat "$WORK/gate.out" 2>/dev/null)' instead of the probe verdict line — the gate's stdout was discarded (the coordinator reads that as 'incomplete')"
  fi

  # --------------------------------------------------------------------------------------------------------
  # 3) ACCRUAL PROBE (screen-leads): screening the same leads in a SHORTER manifest must give byte-identical
  #    rows for the surviving leads. If any within-run accrual reached output, dropping the first lead would
  #    perturb the later ones.
  # --------------------------------------------------------------------------------------------------------
  note "3) accrual probe: screen-leads rows are order-independent (no within-run accrual reaches output) ..."
  SUBSET="$WORK/subset-leads.tsv"
  grep -v 'savings:reentrancy |' "$WORK/screen/run/demo-leads.tsv" > "$SUBSET" 2>/dev/null || true
  if [ -s "$SUBSET" ]; then
    "$SCREEN" --manifest "$SUBSET" --out "$WORK/screen2" >"$WORK/screen2.out" 2>&1 || true
    ROWS_A="$(grep -E '^\| savings:reentrancy-fixed \||^\| bad-harness \|' "$WORK/screen/screen-report.md" 2>/dev/null || true)"
    ROWS_B="$(grep -E '^\| savings:reentrancy-fixed \||^\| bad-harness \|' "$WORK/screen2/screen-report.md" 2>/dev/null || true)"
    if [ -n "$ROWS_A" ] && [ "$ROWS_A" = "$ROWS_B" ]; then
      ok "the surviving leads' rows are byte-identical across the 3-lead and 2-lead manifests (no accrual)"
    else
      bad "the surviving leads' rows changed when the first lead was dropped — something DOES accrue within a run"
      printf '%s\n' "--- 3-lead:" "$ROWS_A" "--- 2-lead:" "$ROWS_B" | sed 's/^/      /' >&2
    fi
  else
    bad "could not build the 2-lead subset manifest from the screen-leads demo run"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the experience/learning flags hold on all 8 hunt + submission-path scripts (#1881, #1878)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed (see #1881, #1878)" >&2
exit 1
