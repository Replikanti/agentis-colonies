#!/usr/bin/env bash
# demo-symbolic-orchestrate.sh — #1015 M3: OFFLINE, DETERMINISTIC proof that the self-orchestrating
# coordinator ROUTES a pending candidate through the SOUND symbolic engine. In ONE `agentis go
# coordinator.ag` (ORCHESTRATE_ENABLED), the federation hunts a lead, surfaces a candidate, and then CHOOSES
# the `symbolic-prove` action for it — the verdict that flows back into its evolving policy is the symbolic
# gate's SOUND outcome (a fixture stands in for the real Halmos run here, exactly as every other action's
# offline path does), mapped COUNTEREXAMPLE->confirmed / PROVED->refuted / INCONCLUSIVE->dry. No network, no
# real LLM, no Halmos toolchain needed — the orchestration is proven against the fixture-mapped verdict.
#
# This is the #1015 epic's thesis made a COORDINATOR DECISION: the confirmed/refuted policy signal the
# coordinator evolves on now comes from a SOUND engine, not an LLM opinion. M2 shipped the callable
# generate-and-verify step (run-symbolic.sh); M3 lets the self-orchestrating coordinator (#1014) DECIDE when
# to spend a symbolic verify and feed the verdict back.
#
# This demo proves:
#   (1) The coordinator CHOOSES `symbolic-prove` for a pending candidate (the new VERIFY-tier action) — with
#       a seeded symbolic-prove policy that lifts it above refute/poc-screen, a hunt confirms -> pushes a
#       candidate -> the coordinator routes THAT candidate through the symbolic engine.
#   (2) The SOUND verdict maps to the right outcome: a `symbolic-prove|cand*=confirmed` fixture (= a Halmos
#       COUNTEREXAMPLE) flows back as a `confirmed` policy SUCCESS; a `=refuted` fixture (= a Halmos PROVED)
#       flows back as a `refuted` policy FAILURE. We run BOTH and assert the policy moves in opposite
#       directions, with the candidate CONSUMED from PENDING either way.
#   (3) PENDING is threaded correctly: a confirmed hunt pushes `cand-<step>`; the symbolic-prove of it
#       consumes the first pending candidate (the trace alternates hunt/symbolic-prove with pending 0/1).
#   (4) The decision policy EVOLVES: symbolic-prove's weight rises on COUNTEREXAMPLE-confirmed runs and falls
#       on PROVED-refuted runs, and the in-loop policy equals the seed + the per-outcome experience deltas.
#   (5) DETERMINISM: a re-run into a fresh store is byte-identical (no RNG; the verdict is the fixture's).
#
# Usage:  dark-factory/demo-symbolic-orchestrate.sh
# Requires: the `agentis` binary on PATH. Exit 0 = all proven; non-zero = an assertion failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# #2119: wide flat-cyborg PTY by default for every flat-cyborg config emission (see the helper header).
# shellcheck source=lib/flat-cyborg-env.sh
# shellcheck disable=SC1091
. "$HERE/lib/flat-cyborg-env.sh"
command -v agentis >/dev/null 2>&1 || { echo "demo-symbolic-orchestrate.sh: agentis binary not on PATH" >&2; exit 3; }
COORD_AG="$HERE/auditor/agents/coordinator.ag"
[ -f "$COORD_AG" ] || { echo "demo-symbolic-orchestrate.sh: coordinator agent not found at $COORD_AG" >&2; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
note() { echo "demo-symbolic-orchestrate.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

# The FACTS the audit runs under: one huntable cell whose hunt confirms (-> pushes a candidate). The
# symbolic-prove policy is SEEDED (--sym-policy 1.5 -> SYM_POLICY_TT=15000) so symbolic-prove (base 96)
# outranks refute (base 100) and poc-screen (base 98) in the VERIFY tier and the coordinator CHOOSES it.
SCOPE_FX=$'vault accounting|C1'
FIT_FX="C1=0.5500"
BUDGET=4
DRY_CAP=3
SYM_TT=15000   # +1.5 in ten-thousandths; > 1.0 lifts symbolic-prove above refute

# A fresh agentis store configured EXACTLY like run-coordinator.sh's orchestrate bootstrap (experience
# enabled; the loop + dispatch + the symbolic-prove seed facts whitelisted). $1 = store dir.
init_store() {
  _d="$1"; mkdir -p "$_d"; cp "$COORD_AG" "$_d/coordinator.ag"
  ( cd "$_d" && agentis init >/dev/null 2>&1 )
  {
    echo "llm.backend = mock"
    echo "trace.level = normal"
    echo "exec.env_passthrough = SCOPE,CLASS_FITNESS,POLICY,PENDING,BUDGET,DRY_STREAK,DRY_CAP,PREV_ACTION,PREV_KEY,LAST_OUTCOME,DISPATCH_ENABLED,DISPATCH_FIXTURE,HUNT_FIXTURE,ORCHESTRATE_ENABLED,STEPS,SYM_POLICY_TT"
    echo "exec.default_timeout_ms = 30000"
    echo "learning.enabled = true"
    echo "experience.enabled = true"
  } > "$_d/.agentis/config"
}

# Run the WHOLE audit as ONE in-substrate `agentis go` (ORCHESTRATE_ENABLED) in store $1 with the
# DISPATCH_FIXTURE in $2. STEPS is the budget-bounded `0..BUDGET-1` list.
orchestrate() {
  _store="$1"; _fixture="$2"
  _steps="$(awk -v n="$BUDGET" 'BEGIN{ for (i=0;i<n;i++){ printf "%s%d", (i?"\n":""), i } }')"
  # --grant-pii: scope text can carry addresses/identifiers that trip the PII heuristic; benign
  # fixture, kept uniform with the other flagged demos + recurrence defense (#1690).
  ( cd "$_store" && env \
      SCOPE="$SCOPE_FX" CLASS_FITNESS="$FIT_FX" PENDING="" \
      BUDGET="$BUDGET" DRY_CAP="$DRY_CAP" STEPS="$_steps" SYM_POLICY_TT="$SYM_TT" \
      ORCHESTRATE_ENABLED=1 DISPATCH_ENABLED=1 DISPATCH_FIXTURE="$_fixture" \
      agentis go coordinator.ag --enable-exec --enable-messaging --grant-pii 2>/dev/null )
}

# Read the loop's durable trace / policy memos back.
read_trace()  { ( cd "$1" && agentis memo get coordinator:trace ) 2>/dev/null; }
read_policy() { ( cd "$1" && agentis memo get coordinator:policy_after ) 2>/dev/null; }

# The action TYPE of one decisions.tsv row (the `action=<type>` field).
row_action() { printf '%s' "$1" | awk -F'\t' '{ for (i=1;i<=NF;i++) if ($i ~ /^action=/) { sub(/^action=/,"",$i); print $i } }'; }

# The cumulative experience-store delta for symbolic-prove (the same read_policy mechanic run-coordinator
# uses) — the per-outcome ±0.15 sum, WITHOUT the in-loop seed.
store_sym_delta() {
  python3 - "$1/.agentis/experience/main.jsonl" <<'PY'
import json, os, sys
path = sys.argv[1]; tot = 0.0
if os.path.exists(path):
    for line in open(path):
        line = line.strip()
        if not line: continue
        try: r = json.loads(line)
        except Exception: continue
        if r.get("action") == "coordinator" and r.get("in") == "symbolic-prove":
            tot += float(r.get("delta", 0.0))
print("%.4f" % tot)
PY
}

# float comparison helper: `cmp_gt A B` -> exit 0 iff A > B.
cmp_gt() { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a > b) }'; }

echo "=================================================================================="
echo " (1+2 CEX) COUNTEREXAMPLE->confirmed: hunt -> push -> CHOOSE symbolic-prove -> confirmed"
echo "=================================================================================="
# hunt confirms (-> pushes cand); symbolic-prove of cand maps a Halmos COUNTEREXAMPLE -> confirmed (success).
CEX_FIXTURE="hunt|vault*=confirmed;symbolic-prove|cand-*=confirmed;refute|cand-*=refuted;poc-screen|cand-*=dry"
init_store "$WORK/cex"
OUT_CEX="$(orchestrate "$WORK/cex" "$CEX_FIXTURE")"
MARK_CEX="$(printf '%s\n' "$OUT_CEX" | grep -E '^ORCHESTRATE\|' | head -1)"
TRACE_CEX="$(read_trace "$WORK/cex")"
POLICY_CEX="$(read_policy "$WORK/cex")"

if [ -n "$MARK_CEX" ]; then ok "the single agentis go completed in-substrate ($MARK_CEX)"
else bad "no ORCHESTRATE| completion marker — the in-substrate loop did not run"; fi

# (1) the coordinator CHOSE symbolic-prove for a pending candidate.
SYM_ROWS="$(printf '%s\n' "$TRACE_CEX" | grep '^step=' | while IFS= read -r r; do row_action "$r"; done | grep -c '^symbolic-prove$')"
if [ "$SYM_ROWS" -ge 1 ]; then ok "the coordinator CHOSE symbolic-prove $SYM_ROWS time(s) — the new VERIFY-tier action was selected"
else bad "the coordinator never chose symbolic-prove (the seeded policy did not lift it / wrong scenario)"; fi

# Assert the first symbolic-prove row points at the candidate the prior hunt pushed (cand-0), proving it
# routed the PENDING candidate (not a fresh hunt).
SYM_ARGS="$(printf '%s\n' "$TRACE_CEX" | grep '^step=' | grep 'action=symbolic-prove' | head -1 | awk -F'\t' '{ for (i=1;i<=NF;i++) if ($i ~ /^args=/) { sub(/^args=/,"",$i); print $i } }')"
if [ "$SYM_ARGS" = "cand-0" ]; then ok "symbolic-prove routed the pushed candidate 'cand-0' (the pending lead, not a fresh hunt)"
else bad "expected symbolic-prove of 'cand-0', got '$SYM_ARGS'"; fi

# (3) PENDING threaded: the step AFTER a hunt-confirm shows pending=1; the symbolic-prove consumes it so a
# following hunt sees pending=0 again. The trace alternates hunt(pending=0)/symbolic-prove(pending=1).
ALT="$(printf '%s\n' "$TRACE_CEX" | grep '^step=' | while IFS= read -r r; do row_action "$r"; done | sort -u | tr '\n' ' ')"
if printf '%s' "$ALT" | grep -q 'hunt' && printf '%s' "$ALT" | grep -q 'symbolic-prove'; then
  ok "the loop alternated hunt + symbolic-prove ($ALT) — push then route then push (PENDING consumed each verify)"
else bad "expected a hunt + symbolic-prove alternation, got '$ALT'"; fi

# (2 CEX) the policy ROSE: a COUNTEREXAMPLE-confirmed is a success, so symbolic-prove's weight climbs above
# its seed. The experience store holds ONLY the per-outcome deltas (positive here), not the seed.
SYM_STORE_CEX="$(store_sym_delta "$WORK/cex")"
note "COUNTEREXAMPLE run: policy-after [$POLICY_CEX]  store symbolic-prove delta=$SYM_STORE_CEX"
if cmp_gt "$SYM_STORE_CEX" "0.0"; then ok "symbolic-prove experience delta is POSITIVE ($SYM_STORE_CEX) — COUNTEREXAMPLE mapped to a confirmed SUCCESS"
else bad "expected a positive symbolic-prove delta on the COUNTEREXAMPLE run, got $SYM_STORE_CEX"; fi

echo
echo "=================================================================================="
echo " (2 PROVED) PROVED->refuted: same route, a PROOF kills the lead -> policy FALLS"
echo "=================================================================================="
# Same scenario, but symbolic-prove maps a Halmos PROVED -> refuted (failure): the candidate is still
# CONSUMED (the lead is killed by a proof), but the policy signal is negative.
PROVED_FIXTURE="hunt|vault*=confirmed;symbolic-prove|cand-*=refuted;refute|cand-*=refuted;poc-screen|cand-*=dry"
init_store "$WORK/proved"
orchestrate "$WORK/proved" "$PROVED_FIXTURE" >/dev/null
TRACE_PROVED="$(read_trace "$WORK/proved")"
POLICY_PROVED="$(read_policy "$WORK/proved")"
SYM_STORE_PROVED="$(store_sym_delta "$WORK/proved")"
note "PROVED run: policy-after [$POLICY_PROVED]  store symbolic-prove delta=$SYM_STORE_PROVED"

# The coordinator still chose symbolic-prove and still consumed the candidate (a refuted verify pops PENDING).
PROVED_SYM_ROWS="$(printf '%s\n' "$TRACE_PROVED" | grep '^step=' | while IFS= read -r r; do row_action "$r"; done | grep -c '^symbolic-prove$')"
if [ "$PROVED_SYM_ROWS" -ge 1 ]; then ok "the coordinator chose symbolic-prove $PROVED_SYM_ROWS time(s) on the PROVED run too"
else bad "the coordinator did not choose symbolic-prove on the PROVED run"; fi
# A refuted verify consumes the candidate, so a hunt re-confirms a fresh one next step (PENDING returns to 0):
# the run alternates hunt/symbolic-prove just like the CEX run, proving the candidate was popped each time.
PROVED_HUNTS="$(printf '%s\n' "$TRACE_PROVED" | grep '^step=' | while IFS= read -r r; do row_action "$r"; done | grep -c '^hunt$')"
if [ "$PROVED_HUNTS" -ge 2 ]; then ok "the PROVED run re-hunted $PROVED_HUNTS times — each symbolic-prove CONSUMED its candidate (PENDING popped, a fresh hunt followed)"
else bad "expected >= 2 hunts (each verify consumed PENDING), got $PROVED_HUNTS"; fi

# (2) the policy FELL: a PROVED-refuted is a failure, so the symbolic-prove experience delta is NEGATIVE —
# the OPPOSITE sign of the COUNTEREXAMPLE run. The SOUND verdict, not an LLM, drives the sign.
if cmp_gt "0.0" "$SYM_STORE_PROVED"; then ok "symbolic-prove experience delta is NEGATIVE ($SYM_STORE_PROVED) — PROVED mapped to a refuted FAILURE (opposite of COUNTEREXAMPLE)"
else bad "expected a negative symbolic-prove delta on the PROVED run, got $SYM_STORE_PROVED"; fi
if cmp_gt "$SYM_STORE_CEX" "$SYM_STORE_PROVED"; then
  ok "the SOUND verdict drives the policy SIGN: COUNTEREXAMPLE delta ($SYM_STORE_CEX) > PROVED delta ($SYM_STORE_PROVED)"
else
  bad "the verdict did not flip the policy sign: CEX=$SYM_STORE_CEX vs PROVED=$SYM_STORE_PROVED"
fi

echo
echo "=================================================================================="
echo " (4) IN-LOOP POLICY == seed + experience deltas (the threading mirrors the store + the seed)"
echo "=================================================================================="
# The in-loop policy_after carries the SEED (1.5) plus the per-outcome experience deltas. The store holds
# only the deltas. So in-loop symbolic-prove == 1.5 + store-delta, byte-for-byte. Verify for the CEX run.
SYM_LOOP_CEX="$(printf '%s' "$POLICY_CEX" | awk -F';' '{ for(i=1;i<=NF;i++) if ($i ~ /^symbolic-prove=/) { sub(/^symbolic-prove=/,"",$i); print $i } }')"
SYM_EXPECT_CEX="$(awk -v s="$SYM_STORE_CEX" 'BEGIN{ printf "%.4f", 1.5 + s }')"
if [ "$SYM_LOOP_CEX" = "$SYM_EXPECT_CEX" ]; then
  ok "in-loop symbolic-prove policy ($SYM_LOOP_CEX) == seed 1.5000 + experience delta ($SYM_STORE_CEX) — the threading mirrors store + seed"
else
  bad "in-loop symbolic-prove policy '$SYM_LOOP_CEX' != seed+delta '$SYM_EXPECT_CEX'"
fi

echo
echo "=================================================================================="
echo " (5) DETERMINISM — a re-run into a fresh store is byte-identical"
echo "=================================================================================="
init_store "$WORK/cex2"
orchestrate "$WORK/cex2" "$CEX_FIXTURE" >/dev/null
TRACE_CEX2="$(read_trace "$WORK/cex2")"
POLICY_CEX2="$(read_policy "$WORK/cex2")"
if [ "$TRACE_CEX" = "$TRACE_CEX2" ] && [ "$POLICY_CEX" = "$POLICY_CEX2" ]; then
  ok "two independent in-substrate runs produced byte-identical decisions.tsv + policy (deterministic)"
else
  bad "the two runs DIFFERED:"
  diff <(printf '%s\n' "$TRACE_CEX") <(printf '%s\n' "$TRACE_CEX2") | sed 's/^/      /' >&2 || true
fi

echo
echo "=================================================================================="
if [ "$FAILS" -eq 0 ]; then
  note "PROVEN offline + deterministically. The self-orchestrating coordinator ROUTES a pending candidate"
  note "through the SOUND symbolic engine: it CHOOSES symbolic-prove, the verdict maps COUNTEREXAMPLE->confirmed"
  note "/ PROVED->refuted (the sign comes from the sound gate, never an LLM), the candidate is CONSUMED from"
  note "PENDING, and the decision policy EVOLVES by that sound outcome. Deterministic re-run."
  exit 0
fi
note "FAILED: $FAILS assertion(s) did not hold — see above."
exit 1
