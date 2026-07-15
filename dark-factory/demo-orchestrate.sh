#!/usr/bin/env bash
# demo-orchestrate.sh — #1014 M3: OFFLINE, DETERMINISTIC proof that the SHELL LOOP IS DISSOLVED — the whole
# multi-step audit self-orchestrates INSIDE the substrate, in ONE `agentis go coordinator.ag`, with NO
# network and NO real LLM.
#
# Through M2 the decision and each action's dispatch lived in the substrate, but a thin shell while-loop
# (run-coordinator.sh) still DROVE the loop: per step it ran one `agentis go`, read the verdict memo, pushed
# /popped PENDING, advanced DRY_STREAK / BUDGET, re-read the policy, and appended a decisions.tsv row. M3
# moves that ENTIRE loop into the substrate: with ORCHESTRATE_ENABLED set, `coordinator.ag` runs the loop as
# a `reduce` over a budget-bounded STEPS list — deciding, dispatching, reading the verdict, threading
# PENDING / DRY_STREAK / BUDGET / the evolving policy, and accumulating the trace — and writes the final
# decisions.tsv body + evolved policy to durable memos. The shell is now a BOOTSTRAP only.
#
# This demo proves:
#   (1) ONE `agentis go` (ORCHESTRATE_ENABLED) runs a >=3-step audit and CHOOSES DIFFERENT ACTIONS across
#       the steps (hunt then refute then hunt …) — a genuine multi-step self-orchestration, not one decision.
#   (2) The resulting decisions.tsv + evolved policy are BYTE-IDENTICAL to what the M2 shell-loop
#       (origin/main's run-coordinator.sh) produced for the SAME facts + fixture — captured below as the
#       GOLDEN reference. Same decisions, same policy deltas; only the DRIVER moved into the substrate.
#   (3) A re-run into a fresh store is byte-identical (deterministic, no RNG).
#   (5) #1026 REGRESSION GUARD: a `stop`/dry-cap-terminated run attributes the LAST executed action EXACTLY
#       ONCE. N executed hunts (all dry) -> policy hunt = N x -0.15, NOT (N+1) x -0.15. The prior in-substrate
#       loop double-counted the last action on a stop (the stop step's decide_once attributed it AND the
#       post-loop final block attributed it again); the fix makes attribution idempotent across all
#       termination paths. `stop` is a decision, never an executed action, so it is never attributed.
#
# The GOLDEN reference (decisions.tsv + policy-after) was captured from `origin/main`'s shell-loop
# `run-coordinator.sh` with the scope/class-fitness/fixture facts mirrored below (budget 8, dry-cap 3,
# stub executor). This GOLDEN scenario terminates on BUDGET-EXHAUSTION (8 actions, never a `stop`), where the
# old shell loop's final attribution was already CORRECT — so the GOLDEN_POLICY below is the once-per-action
# value and stays byte-identical to the M2 shell loop. The #1026 double-count was specific to the `stop`/dry-
# cap path, which is exercised + asserted separately in proof (5). After #1026 the in-substrate policy is the
# CORRECT once-per-action attribution on EVERY path (no longer reproducing the shell loop's stop-path
# double-count — that was the bug).
#
# Everything is deterministic and offline: the coordinator's choice is a fact+policy argmax (no RNG), the
# dispatch verdicts come from a fixture (no LLM, no prompt()), and the backend is `mock` (zero cost).
#
# Usage:  dark-factory/demo-orchestrate.sh
# Requires: the `agentis` binary on PATH. Exit 0 = all proven; non-zero = an assertion failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
command -v agentis >/dev/null 2>&1 || { echo "demo-orchestrate.sh: agentis binary not on PATH" >&2; exit 3; }
COORD_AG="$HERE/auditor/agents/coordinator.ag"
[ -f "$COORD_AG" ] || { echo "demo-orchestrate.sh: coordinator agent not found at $COORD_AG" >&2; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
note() { echo "demo-orchestrate.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

# The FACTS the audit runs under (the same scope/class-fitness/fixture the GOLDEN reference was captured
# with). SCOPE = newline-joined `subsystem|class`; CLASS_FITNESS / DISPATCH_FIXTURE are the env-shaped facts
# run-coordinator.sh builds from its --class-fitness / --fixture files.
SCOPE_FX=$'vault accounting|C1\nreentrancy|C8\ncross-chain|C3'
FIT_FX="C1=0.5500;C8=0.1000;C3=-0.2000"
# Hunt of vault* confirms (-> pushes a candidate); refute of that candidate is refuted (-> pops it); so the
# audit alternates hunt/refute as the policy evolves — a multi-step, fact-driven sequence.
FIXTURE_FX="hunt|vault*=confirmed;refute|cand-*=refuted;poc-screen|cand-*=dry;hunt|reentr*=dry;invent-method|*=dry"
BUDGET=8
DRY_CAP=3

# GOLDEN decisions.tsv — the M2 shell-loop (origin/main run-coordinator.sh) output for the facts above.
read -r -d '' GOLDEN_TRACE <<'GOLDEN' || true
step=0	action=hunt	args=vault accounting|C1	policy=[]	rationale=hunt highest-scored lens 'vault accounting|C1' (lens_fitness=0.55, hunt_policy=0, score=55.5; budget=8 dry=0/3 pending=0 scope_cells=3)
step=1	action=refute	args=cand-0	policy=[]	rationale=pending unverified candidate 'cand-0' -> verify via refute before more hunting (policy hunt=0, refute=0; budget=7 dry=0/3 pending=1 scope_cells=3)
step=2	action=hunt	args=vault accounting|C1	policy=[hunt=0.1500]	rationale=hunt highest-scored lens 'vault accounting|C1' (lens_fitness=0.55, hunt_policy=0.15, score=55.65; budget=6 dry=1/3 pending=0 scope_cells=3)
step=3	action=refute	args=cand-2	policy=[hunt=0.1500;refute=-0.1500]	rationale=pending unverified candidate 'cand-2' -> verify via refute before more hunting (policy hunt=0.15, refute=-0.15; budget=5 dry=0/3 pending=1 scope_cells=3)
step=4	action=hunt	args=vault accounting|C1	policy=[hunt=0.3000;refute=-0.1500]	rationale=hunt highest-scored lens 'vault accounting|C1' (lens_fitness=0.55, hunt_policy=0.3, score=55.8; budget=4 dry=1/3 pending=0 scope_cells=3)
step=5	action=refute	args=cand-4	policy=[hunt=0.3000;refute=-0.3000]	rationale=pending unverified candidate 'cand-4' -> verify via refute before more hunting (policy hunt=0.3, refute=-0.3; budget=3 dry=0/3 pending=1 scope_cells=3)
step=6	action=hunt	args=vault accounting|C1	policy=[hunt=0.4500;refute=-0.3000]	rationale=hunt highest-scored lens 'vault accounting|C1' (lens_fitness=0.55, hunt_policy=0.45, score=55.95; budget=2 dry=1/3 pending=0 scope_cells=3)
step=7	action=refute	args=cand-6	policy=[hunt=0.4500;refute=-0.4500]	rationale=pending unverified candidate 'cand-6' -> verify via refute before more hunting (policy hunt=0.45, refute=-0.45; budget=1 dry=0/3 pending=1 scope_cells=3)
GOLDEN
GOLDEN_POLICY="hunt=0.6000;refute=-0.6000"

# A fresh agentis store configured EXACTLY like run-coordinator.sh's bootstrap (experience enabled so the
# loop can learn()/decide(); the loop + dispatch facts whitelisted). $1 = store dir.
init_store() {
  _d="$1"; mkdir -p "$_d"; cp "$COORD_AG" "$_d/coordinator.ag"
  ( cd "$_d" && agentis init >/dev/null 2>&1 )
  {
    echo "llm.backend = mock"
    echo "trace.level = normal"
    echo "exec.env_passthrough = SCOPE,CLASS_FITNESS,POLICY,PENDING,BUDGET,DRY_STREAK,DRY_CAP,PREV_ACTION,PREV_KEY,LAST_OUTCOME,DISPATCH_ENABLED,DISPATCH_FIXTURE,HUNT_FIXTURE,ORCHESTRATE_ENABLED,STEPS"
    echo "exec.default_timeout_ms = 30000"
    echo "learning.enabled = true"
    echo "experience.enabled = true"
  } > "$_d/.agentis/config"
}

# Run the WHOLE audit as ONE in-substrate `agentis go` (ORCHESTRATE_ENABLED) in store $1; echo the run's
# stdout (we assert on the ORCHESTRATE| marker). STEPS is the budget-bounded `0..BUDGET-1` list.
orchestrate() {
  _store="$1"
  _steps="$(awk -v n="$BUDGET" 'BEGIN{ for (i=0;i<n;i++){ printf "%s%d", (i?"\n":""), i } }')"
  # --grant-pii: scope text can carry addresses/identifiers that trip the PII heuristic; benign
  # fixture, kept uniform with the other flagged demos + recurrence defense (#1690).
  ( cd "$_store" && env \
      SCOPE="$SCOPE_FX" CLASS_FITNESS="$FIT_FX" PENDING="" \
      BUDGET="$BUDGET" DRY_CAP="$DRY_CAP" STEPS="$_steps" \
      ORCHESTRATE_ENABLED=1 DISPATCH_ENABLED=1 DISPATCH_FIXTURE="$FIXTURE_FX" \
      agentis go coordinator.ag --enable-exec --enable-messaging --grant-pii 2>/dev/null )
}

# Read the loop's durable trace / policy memos back (the cross-process channel the bootstrap reads).
read_trace()  { ( cd "$1" && agentis memo get coordinator:trace ) 2>/dev/null; }
read_policy() { ( cd "$1" && agentis memo get coordinator:policy_after ) 2>/dev/null; }

# The action TYPE of one decisions.tsv row (the `action=<type>` field).
row_action() { printf '%s' "$1" | awk -F'\t' '{ for (i=1;i<=NF;i++) if ($i ~ /^action=/) { sub(/^action=/,"",$i); print $i } }'; }

echo "=================================================================================="
echo " (1) ONE agentis go runs a >=3-step audit and CHOOSES DIFFERENT ACTIONS across steps"
echo "=================================================================================="
init_store "$WORK/run1"
OUT1="$(orchestrate "$WORK/run1")"
MARK="$(printf '%s\n' "$OUT1" | grep -E '^ORCHESTRATE\|' | head -1)"
TRACE1="$(read_trace "$WORK/run1")"
POLICY1="$(read_policy "$WORK/run1")"

if [ -n "$MARK" ]; then ok "the single agentis go completed in-substrate ($MARK)"
else bad "no ORCHESTRATE| completion marker — the in-substrate loop did not run"; fi

NSTEPS="$(printf '%s\n' "$TRACE1" | grep -c '^step=')"
if [ "$NSTEPS" -ge 3 ]; then ok "the audit ran $NSTEPS steps in ONE process (>= 3 — a real multi-step loop)"
else bad "expected >= 3 steps from one agentis go, got $NSTEPS"; fi

# Distinct action types across the steps (not one repeated decision).
ACTIONS="$(printf '%s\n' "$TRACE1" | grep '^step=' | while IFS= read -r r; do row_action "$r"; done | sort -u)"
NDISTINCT="$(printf '%s\n' "$ACTIONS" | grep -c .)"
if [ "$NDISTINCT" -ge 2 ]; then ok "the loop chose $NDISTINCT DISTINCT action types ($(printf '%s' "$ACTIONS" | tr '\n' ' ')) — fact-driven, not a fixed single decision"
else bad "expected >= 2 distinct action types across the steps, got $NDISTINCT ($ACTIONS)"; fi

echo
echo "=================================================================================="
echo " (2) BYTE-IDENTICAL to the M2 shell-loop output (decisions.tsv + evolved policy)"
echo "=================================================================================="
if [ "$TRACE1" = "$GOLDEN_TRACE" ]; then
  ok "decisions.tsv is BYTE-IDENTICAL to the M2 shell-loop golden (only the driver moved into the substrate)"
else
  bad "decisions.tsv DIFFERS from the M2 shell-loop golden:"
  diff <(printf '%s\n' "$GOLDEN_TRACE") <(printf '%s\n' "$TRACE1") | sed 's/^/      /' >&2 || true
fi
if [ "$POLICY1" = "$GOLDEN_POLICY" ]; then
  ok "evolved policy is BYTE-IDENTICAL to the M2 shell-loop golden ($POLICY1)"
else
  bad "evolved policy DIFFERS: golden '$GOLDEN_POLICY' vs in-substrate '$POLICY1'"
fi

# Cross-check: the in-loop policy must equal the experience-store read_policy() sum (the same mechanic the
# shell read between calls) — proves the in-process policy threading mirrors the durable store byte-for-byte.
STORE_POLICY="$(python3 - "$WORK/run1/.agentis/experience/main.jsonl" <<'PY'
import json, os, sys
path = sys.argv[1]; agg = {}
if os.path.exists(path):
    for line in open(path):
        line = line.strip()
        if not line: continue
        try: r = json.loads(line)
        except Exception: continue
        if r.get("action") != "coordinator": continue
        k = r.get("in", "")
        if not k: continue
        agg[k] = agg.get(k, 0.0) + float(r.get("delta", 0.0))
print(";".join("%s=%.4f" % (k, agg[k]) for k in sorted(agg)))
PY
)"
if [ "$POLICY1" = "$STORE_POLICY" ]; then
  ok "in-loop policy == experience-store read_policy() sum ($STORE_POLICY) — the threading mirrors the store"
else
  bad "in-loop policy '$POLICY1' != experience-store sum '$STORE_POLICY' — the in-process threading drifted"
fi

echo
echo "=================================================================================="
echo " (3) DETERMINISM — a re-run into a fresh store is byte-identical"
echo "=================================================================================="
init_store "$WORK/run2"
orchestrate "$WORK/run2" >/dev/null
TRACE2="$(read_trace "$WORK/run2")"
POLICY2="$(read_policy "$WORK/run2")"
if [ "$TRACE1" = "$TRACE2" ] && [ "$POLICY1" = "$POLICY2" ]; then
  ok "two independent in-substrate runs produced byte-identical decisions.tsv + policy (deterministic)"
else
  bad "the two runs DIFFERED:"
  diff <(printf '%s\n' "$TRACE1") <(printf '%s\n' "$TRACE2") | sed 's/^/      /' >&2 || true
fi

echo
echo "=================================================================================="
echo " (4) CB-CLIFF GUARD — the whole loop runs in ONE agentis go, so the cb header must cover the budget"
echo "=================================================================================="
# The loop runs every step in ONE process, so coordinator.ag's `cb` budget must cover ALL steps (unlike the
# old per-step agentis go). A budget that exceeds the cb cliff returns an empty trace. Run at the DEFAULT
# budget (12 — above the old cb-300000 cliff at ~10) and assert a full, non-empty trace. Guards the cb header.
GUARD_BUDGET=12
init_store "$WORK/guard"
GUARD_STEPS="$(awk -v n="$GUARD_BUDGET" 'BEGIN{ for (i=0;i<n;i++){ printf "%s%d", (i?"\n":""), i } }')"
# --grant-pii: scope text can carry addresses/identifiers that trip the PII heuristic; benign
# fixture, kept uniform with the other flagged demos + recurrence defense (#1690).
( cd "$WORK/guard" && env \
    SCOPE="$SCOPE_FX" CLASS_FITNESS="$FIT_FX" PENDING="" \
    BUDGET="$GUARD_BUDGET" DRY_CAP="$DRY_CAP" STEPS="$GUARD_STEPS" \
    ORCHESTRATE_ENABLED=1 DISPATCH_ENABLED=1 DISPATCH_FIXTURE="$FIXTURE_FX" \
    agentis go coordinator.ag --enable-exec --enable-messaging --grant-pii >/dev/null 2>&1 )
GUARD_TRACE="$(read_trace "$WORK/guard")"
GUARD_STEPN="$(printf '%s\n' "$GUARD_TRACE" | grep -c '^step=')"
if [ "$GUARD_STEPN" -eq "$GUARD_BUDGET" ]; then
  ok "budget=$GUARD_BUDGET ran all $GUARD_STEPN steps in one process (cb header covers the loop — no CB cliff)"
else
  bad "budget=$GUARD_BUDGET produced $GUARD_STEPN/$GUARD_BUDGET trace rows — coordinator.ag cb header too low for the loop (CB cliff)"
fi

echo
echo "=================================================================================="
echo " (5) #1026 ONCE-PER-ACTION — a stop/dry-cap-terminated run attributes the last action EXACTLY ONCE"
echo "=================================================================================="
# Regression guard for #1026: before the fix the in-substrate loop double-counted the last EXECUTED action on
# a `stop`/dry-cap termination (the stop step's decide_once attributed it AND the post-loop final block
# attributed it again). Scenario: a single hunt cell that always comes back `dry`, dry-cap K=2. The loop hunts
# twice (both dry -> dry-streak hits 2), then the 3rd decision is `stop`. Two EXECUTED hunts, each a failure
# (-0.15). CORRECT once-per-action policy: hunt = 2 x -0.15 = -0.3000. The pre-fix double-count was -0.4500
# (3 x -0.15). We assert BOTH the in-loop policy memo AND the experience-store sum equal -0.3000, AND that the
# store holds EXACTLY 2 hunt attribution rows (N, not N+1). `stop` is a decision, not an executed action, so it
# is never attributed.
STOP_SCOPE=$'vault accounting|C1'
STOP_FIT="C1=0.5500"
STOP_FIXTURE="hunt|vault*=dry;refute|cand-*=refuted;poc-screen|cand-*=dry;invent-method|*=dry"
STOP_BUDGET=8
STOP_DRY_CAP=2
EXPECT_HUNTS=2
EXPECT_POLICY="hunt=-0.3000"
init_store "$WORK/stop"
STOP_STEPS="$(awk -v n="$STOP_BUDGET" 'BEGIN{ for (i=0;i<n;i++){ printf "%s%d", (i?"\n":""), i } }')"
# --grant-pii: scope text can carry addresses/identifiers that trip the PII heuristic; benign
# fixture, kept uniform with the other flagged demos + recurrence defense (#1690).
( cd "$WORK/stop" && env \
    SCOPE="$STOP_SCOPE" CLASS_FITNESS="$STOP_FIT" PENDING="" \
    BUDGET="$STOP_BUDGET" DRY_CAP="$STOP_DRY_CAP" STEPS="$STOP_STEPS" \
    ORCHESTRATE_ENABLED=1 DISPATCH_ENABLED=1 DISPATCH_FIXTURE="$STOP_FIXTURE" \
    agentis go coordinator.ag --enable-exec --enable-messaging --grant-pii >/dev/null 2>&1 )
STOP_TRACE="$(read_trace "$WORK/stop")"
STOP_POLICY="$(read_policy "$WORK/stop")"
# The number of hunt actions actually EXECUTED (non-stop hunt rows in the trace).
STOP_HUNTS="$(printf '%s\n' "$STOP_TRACE" | grep '^step=' | while IFS= read -r r; do row_action "$r"; done | grep -c '^hunt$')"
# The number of hunt ATTRIBUTION rows in the durable experience store (must equal the executed hunts, not +1).
STOP_HUNT_ROWS="$(python3 - "$WORK/stop/.agentis/experience/main.jsonl" <<'PY'
import json, os, sys
path = sys.argv[1]; n = 0
if os.path.exists(path):
    for line in open(path):
        line = line.strip()
        if not line: continue
        try: r = json.loads(line)
        except Exception: continue
        if r.get("action") == "coordinator" and r.get("in") == "hunt": n += 1
print(n)
PY
)"
# The experience-store policy sum (the same read_policy() mechanic the shell uses) for the cross-check.
STOP_STORE_POLICY="$(python3 - "$WORK/stop/.agentis/experience/main.jsonl" <<'PY'
import json, os, sys
path = sys.argv[1]; agg = {}
if os.path.exists(path):
    for line in open(path):
        line = line.strip()
        if not line: continue
        try: r = json.loads(line)
        except Exception: continue
        if r.get("action") != "coordinator": continue
        k = r.get("in", "")
        if not k: continue
        agg[k] = agg.get(k, 0.0) + float(r.get("delta", 0.0))
print(";".join("%s=%.4f" % (k, agg[k]) for k in sorted(agg)))
PY
)"
if [ "$STOP_HUNTS" -eq "$EXPECT_HUNTS" ]; then
  ok "the run executed $STOP_HUNTS hunts then stopped (dry-cap) — the stop-terminated scenario under test"
else
  bad "expected $EXPECT_HUNTS executed hunts before the stop, got $STOP_HUNTS — wrong scenario"
fi
if [ "$STOP_POLICY" = "$EXPECT_POLICY" ]; then
  ok "in-loop policy is $STOP_POLICY ($STOP_HUNTS hunts x -0.15) — last action attributed EXACTLY ONCE (not $((EXPECT_HUNTS + 1))x; #1026 fixed)"
else
  bad "in-loop policy '$STOP_POLICY' != expected '$EXPECT_POLICY' — the last action is double-counted (#1026 regressed)"
fi
if [ "$STOP_HUNT_ROWS" -eq "$EXPECT_HUNTS" ]; then
  ok "the experience store holds EXACTLY $STOP_HUNT_ROWS hunt attribution rows (== executed hunts, not +1)"
else
  bad "the experience store holds $STOP_HUNT_ROWS hunt attribution rows, expected $EXPECT_HUNTS (the last action is double-attributed)"
fi
if [ "$STOP_POLICY" = "$STOP_STORE_POLICY" ]; then
  ok "in-loop policy == experience-store read_policy() sum ($STOP_STORE_POLICY) on the stop path — both drop the double-count"
else
  bad "in-loop policy '$STOP_POLICY' != experience-store sum '$STOP_STORE_POLICY' on the stop path — the two sides disagree"
fi

echo
echo "=================================================================================="
if [ "$FAILS" -eq 0 ]; then
  note "PROVEN offline + deterministically. The shell loop is DISSOLVED: ONE agentis go self-orchestrates"
  note "the whole multi-step audit in the substrate (decide -> dispatch -> read verdict -> thread PENDING /"
  note "DRY_STREAK / BUDGET / evolving policy -> accumulate the trace), and the resulting decisions.tsv +"
  note "evolved policy are BYTE-IDENTICAL to the M2 shell-loop output — only the driver moved."
  exit 0
fi
note "FAILED: $FAILS assertion(s) did not hold — see above."
exit 1
