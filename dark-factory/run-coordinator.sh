#!/usr/bin/env bash
# run-coordinator.sh — #1014: the thin DISPATCHER for the self-orchestrating discovery loop.
#
# WHAT IT IS (and is NOT). This script does NOT decide the audit workflow. Each step it asks
# auditor/agents/coordinator.ag for ONE decision — `coordinator.ag` reads the current FACTS (scope,
# per-class lens fitness, the shared blackboard, pending unverified candidates, remaining budget, the
# previous action's gate OUTCOME) and the evolving POLICY, and emits exactly one
#   ACTION|<type>|<args>|<rationale citing the facts>
# line (type in {hunt, refute, poc-screen, symbolic-prove, invent-method, stop}). This loop then DISPATCHES
# that action,
# captures its OUTCOME (a FACT from a gate, never an LLM judgement), feeds the outcome back, and repeats
# until the coordinator says `stop` or the step budget is spent. The DECISION + its evolution are the
# coordinator's; the loop only executes the chosen action and carries state between steps.
#
# This replaces the DECISION-MAKING that run-discovery.sh's fixed (subsystem x class) fan-out + an
# operator used to do — fixed order, externally chosen target/method/when-to-stop. The fan-out scripts
# remain valid executors; what moves into the substrate here is the CHOICE of what to run next, from
# facts + a policy that improves by outcome.
#
# #1014 M2 — EVERY action's DISPATCH is now in the substrate. The coordinator no longer just DECIDES; when
# DISPATCH_ENABLED is set it also DISPATCHES the chosen action: for ANY real action (hunt / refute /
# poc-screen / symbolic-prove / invent-method) coordinator.ag emits `dark-factory:dispatch` and runs dispatch()
# (auditor/agents/dispatcher.ag's fn, inlined gated in coordinator.ag) in the SAME `agentis go`, deriving
# the gate verdict from DISPATCH_FIXTURE and writing it to the durable `coordinator:last_outcome` memo.
# This loop READS that memo for every non-`stop` action's outcome (the emit/listen bus is in-process only;
# the memo is the substrate-native cross-process channel) instead of a shell `case` — the shell computes
# NO action's outcome. `stop` is terminal and never dispatched.
# (Follow-up, still tracked on epic #1014: wire each action type to its real executor agent on the LIVE
# path; the coordinator pruning the live cell manifest; multi-target portfolio decisions.)
#
# HOW THE POLICY EVOLVES (mirrors evolve-fitness.sh). coordinator.ag records the previous action's
# outcome with the SAME learn() call hunter.ag/fitness-driver.ag use:
#   learn("coordinator", "<action-type>", ..., success|failure, [...])
# (+0.15 per confirmed-finding success, -0.15 per dry/refuted failure). The CUMULATIVE delta per
# action-type key IS `coordinator:policy:<action-type>` — this script reads it back from
# .agentis/experience/*.jsonl exactly as evolve-fitness.sh's read_fitness does, and passes it in as the
# POLICY fact on the next call. So the policy that ranks the options is DATA that improves across steps.
#
# DISPATCH MODES.
#   --executor real   (default) EVERY action is dispatched IN the substrate (coordinator.ag's dispatch()).
#                     With no DISPATCH_FIXTURE the agent takes its live honest per-type stub path, which
#                     names the real wiring each action still needs (hunt: TARGET_DIR/IN_SCOPE/...;
#                     refute->run-refute.sh; poc-screen->screen-leads.sh; symbolic-prove->run-symbolic.sh
#                     (SOUND verdict: COUNTEREXAMPLE->confirmed, PROVED->refuted, INCONCLUSIVE->dry);
#                     invent-method->run-method-discovery.sh) and returns a benign `dry` — it does NOT
#                     attempt a real action. This
#                     mode is the integration surface for a live audit and needs a reasoning backend
#                     (--backend flat-cyborg, flat-rate default; or --backend claude, metered) for the
#                     agents to actually reason. (The decision is still offline-deterministic.)
#   --executor stub --fixture <f>   OFFLINE + DETERMINISTIC: each chosen action's verdict is read from a
#                     fixture (`<action-type> <args-glob> -> confirmed|dry|refuted`), in the substrate
#                     (the fixture is passed to dispatch() as DISPATCH_FIXTURE; the shell only reads the
#                     resulting memo). No LLM, no network — used by demo-coordinator.sh to prove the loop
#                     reproducibly.
#
# Usage:
#   run-coordinator.sh --scope <file> [--class-fitness <file>] [--budget N] [--dry-cap K]
#                      [--executor real|stub] [--fixture <f>] [--sym-policy <float>]
#                      [--sym-repo <foundry-dir> --sym-spec <Spec.t.sol> [--sym-function <prefix>]]
#                      [--backend mock|flat-cyborg|claude] [--out <dir>] [--agentis <bin>]
#
# Scope manifest (one huntable cell per line; `#` and blank lines ignored), pipe-delimited:
#   <subsystem label> | <class id>          e.g.  vault accounting | C1
# Class-fitness file (optional; one per line) seeds the per-lens fitness fact:
#   <class id> | <fitness float>            e.g.  C1 | 0.45
# Fixture (stub mode; one rule per line, first match wins; `*` glob on args):
#   <action-type> | <args-glob> | <confirmed|dry|refuted>   e.g.  hunt | vault* | confirmed
#   <action-type> is one of {hunt, refute, poc-screen, symbolic-prove, invent-method}. For symbolic-prove
#   the fixture verdict stands in for the SOUND symbolic engine's mapped outcome (a `symbolic-prove | cand* |
#   confirmed` rule = a Halmos COUNTEREXAMPLE; `... | refuted` = a PROVED; `... | dry` = INCONCLUSIVE).
#   NB: the rule is split on `|`, so <args-glob> must NOT contain a literal `|`. A hunt's args are
#   `subsystem|class`; match them with a subsystem-prefix glob (`vault*`) whose trailing `*` spans the
#   `|class` suffix — `vault accounting|C1` would be mis-split (the class read as the outcome field).
#
# --sym-policy <float> seeds the in-substrate loop's INITIAL symbolic-prove policy weight (e.g. 1.5), so the
#   coordinator can CHOOSE to route a pending candidate through the SOUND symbolic engine from step 0. The
#   default verify ordering is refute > poc-screen > symbolic-prove; a seed >= 1.0 lifts symbolic-prove above
#   refute. The verdict then comes from the symbolic gate (run-symbolic.sh) — never an LLM opinion.
#
# --sym-repo <dir> --sym-spec <Spec.t.sol> (#1032) supply the LIVE single-candidate symbolic context: when
#   the coordinator CHOOSES symbolic-prove (typically combined with --sym-policy to lift it from step 0), it
#   runs REAL Halmos END-TO-END inside the loop — `halmos-verify.sh --repo <SYM_REPO> --target <SYM_SPEC>
#   [--function <prefix>]` — and maps the gate's SOUND exit code to the coordinator outcome:
#     exit 1 = COUNTEREXAMPLE -> confirmed   (a concrete input is a real bug, CONFIRMED with a witness)
#     exit 0 = PROVED         -> refuted     (the invariant holds for ALL inputs — the lead is killed by a proof)
#     exit 3/2/other = INCONCLUSIVE/harness -> dry  (no verdict; a non-productive step)
#   The verdict is HALMOS's exit code, NEVER an LLM opinion. --sym-repo must be a foundry project (hold a
#   foundry.toml); --sym-spec must be a readable `*.t.sol` whose `--function`-prefixed (default `check`)
#   symbolic test asserts the invariant. Both must be supplied together. halmos-verify.sh is resolved to an
#   absolute path and passed as HALMOS_VERIFY; forge + halmos must be on PATH (the gate does NOT hardcode any
#   install location). The flags are PURELY ADDITIVE: without them symbolic-prove falls through to the honest
#   stub (-> dry) and the offline/fixture orchestration is unchanged. The single-candidate context is the
#   minimum live slice; multi-candidate code-carrying (a discovered lead auto-carrying its contract+invariant
#   through PENDING) remains a broader follow-up (epic #1015 / #1014). --sym-function <prefix> overrides the
#   spec's symbolic-test name prefix (default `check`).
#
# Exit: 0 on a clean run that reached `stop`/budget; 2 on usage error; 3 on missing prerequisite.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
SCOPE_FILE=""
CLASSFIT_FILE=""
BUDGET=12
DRY_CAP=3
EXECUTOR="real"
FIXTURE=""
BACKEND="mock"
OUT="$PWD/coordinator-out"
SYM_POLICY=""
SYM_REPO=""
SYM_SPEC=""
SYM_FUNCTION=""

need() { [ "$1" -ge 2 ] || { echo "run-coordinator.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --scope)         need "$#"; SCOPE_FILE="$2"; shift 2 ;;
    --class-fitness) need "$#"; CLASSFIT_FILE="$2"; shift 2 ;;
    --budget)        need "$#"; BUDGET="$2"; shift 2 ;;
    --dry-cap)       need "$#"; DRY_CAP="$2"; shift 2 ;;
    --executor)      need "$#"; EXECUTOR="$2"; shift 2 ;;
    --fixture)       need "$#"; FIXTURE="$2"; shift 2 ;;
    --backend)       need "$#"; BACKEND="$2"; shift 2 ;;
    --sym-policy)    need "$#"; SYM_POLICY="$2"; shift 2 ;;
    --sym-repo)      need "$#"; SYM_REPO="$2"; shift 2 ;;
    --sym-spec)      need "$#"; SYM_SPEC="$2"; shift 2 ;;
    --sym-function)  need "$#"; SYM_FUNCTION="$2"; shift 2 ;;
    --out)           need "$#"; OUT="$2"; shift 2 ;;
    --agentis)       need "$#"; AGENTIS="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-coordinator.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$SCOPE_FILE" ] || { echo "run-coordinator.sh: --scope <file> is required" >&2; exit 2; }
[ -f "$SCOPE_FILE" ] || { echo "run-coordinator.sh: --scope not found: $SCOPE_FILE" >&2; exit 2; }
case "$BUDGET"  in (*[!0-9]*|'') echo "run-coordinator.sh: --budget must be a non-negative integer" >&2; exit 2 ;; esac
case "$DRY_CAP" in (*[!0-9]*|'') echo "run-coordinator.sh: --dry-cap must be a non-negative integer" >&2; exit 2 ;; esac
case "$EXECUTOR" in real|stub) : ;; *) echo "run-coordinator.sh: --executor must be real|stub" >&2; exit 2 ;; esac
[ "$EXECUTOR" = "stub" ] && { [ -n "$FIXTURE" ] || { echo "run-coordinator.sh: --executor stub needs --fixture <f>" >&2; exit 2; }; [ -f "$FIXTURE" ] || { echo "run-coordinator.sh: --fixture not found: $FIXTURE" >&2; exit 2; }; }
# --sym-policy <float>: SEED the in-substrate loop's initial symbolic-prove policy weight so the coordinator
# can CHOOSE symbolic-prove from step 0 (default ordering refute > poc-screen > symbolic-prove; a weight
# >= 1.0 lifts symbolic-prove above refute). Convert the float to the loop's ten-thousandths int SYM_POLICY_TT
# (agentis has no float->int builtin, so the integer is computed here). "" = no seed (the engine has to earn
# its weight by outcome).
SYM_POLICY_TT=""
if [ -n "$SYM_POLICY" ]; then
  case "$SYM_POLICY" in (-*[!0-9.]*|*[!0-9.-]*|''|*.*.*) echo "run-coordinator.sh: --sym-policy must be a decimal number (e.g. 1.5 or -0.15)" >&2; exit 2 ;; esac
  # Require at least one digit so a bare `-`, `.`, or `-.` (which the metachar globs above let through and
  # awk would silently coerce to 0) is rejected, not treated as a no-op seed.
  case "$SYM_POLICY" in (*[0-9]*) : ;; (*) echo "run-coordinator.sh: --sym-policy must be a decimal number (e.g. 1.5 or -0.15)" >&2; exit 2 ;; esac
  SYM_POLICY_TT="$(awk -v v="$SYM_POLICY" 'BEGIN{ printf "%d", (v>=0 ? v*10000+0.5 : v*10000-0.5) }')"
fi
# --sym-repo / --sym-spec: the LIVE single-candidate symbolic context (#1032). When BOTH are supplied the
# coordinator's chosen symbolic-prove action runs REAL Halmos end-to-end (halmos-verify.sh --repo <SYM_REPO>
# --target <SYM_SPEC>) inside the loop and maps its SOUND exit code to the gate outcome (1=COUNTEREXAMPLE ->
# confirmed, 0=PROVED -> refuted, 3/2/other=INCONCLUSIVE/harness -> dry). The verdict is Halmos's, never an
# LLM opinion. Without the live env the symbolic-prove action falls through to the honest stub (-> dry), so
# the flags are PURELY ADDITIVE. They must be supplied together; SYM_REPO must be a foundry project (hold a
# foundry.toml) and SYM_SPEC must be a readable file. Both are resolved to ABSOLUTE paths (the colony runs
# from the rundir, a different cwd) and exported into the in-substrate run.
HALMOS_VERIFY=""
if [ -n "$SYM_REPO" ] || [ -n "$SYM_SPEC" ]; then
  [ -n "$SYM_REPO" ] && [ -n "$SYM_SPEC" ] || { echo "run-coordinator.sh: --sym-repo and --sym-spec must be supplied together (the LIVE symbolic context)" >&2; exit 2; }
  [ -d "$SYM_REPO" ] || { echo "run-coordinator.sh: --sym-repo is not a directory: $SYM_REPO" >&2; exit 2; }
  [ -f "$SYM_REPO/foundry.toml" ] || { echo "run-coordinator.sh: --sym-repo is not a foundry project (no foundry.toml): $SYM_REPO" >&2; exit 2; }
  [ -f "$SYM_SPEC" ] || { echo "run-coordinator.sh: --sym-spec not found: $SYM_SPEC" >&2; exit 2; }
  SYM_REPO="$(cd "$SYM_REPO" && pwd)"
  SYM_SPEC="$(cd "$(dirname "$SYM_SPEC")" && pwd)/$(basename "$SYM_SPEC")"
  # Resolve halmos-verify.sh to an ABSOLUTE path and pass it as HALMOS_VERIFY (the same env path
  # symbolic-prover.ag / run-symbolic.sh use). No hardcoded install location — the toolchain (forge/halmos)
  # is the caller's PATH responsibility, exactly as halmos-verify.sh requires.
  HALMOS_VERIFY="$HERE/evm-harness/halmos-verify.sh"
  [ -f "$HALMOS_VERIFY" ] || { echo "run-coordinator.sh: halmos-verify gate not found at $HALMOS_VERIFY" >&2; exit 3; }
fi
# The in-substrate orchestrate loop (coordinator.ag) encodes its carried state as fields joined by the
# `@@F@@` sentinel; an input cell that literally contains it would corrupt that encoding. Reject it loudly
# (operator-controlled input; never legitimate in a subsystem label / class id / glob).
if grep -qF '@@F@@' "$SCOPE_FILE" 2>/dev/null || { [ -n "$FIXTURE" ] && grep -qF '@@F@@' "$FIXTURE" 2>/dev/null; }; then
  echo "run-coordinator.sh: --scope/--fixture must not contain the reserved '@@F@@' field sentinel" >&2; exit 2
fi
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-coordinator.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

COORD_AG="$HERE/auditor/agents/coordinator.ag"
[ -f "$COORD_AG" ] || { echo "run-coordinator.sh: coordinator agent not found at $COORD_AG" >&2; exit 3; }

mkdir -p "$OUT" || { echo "run-coordinator.sh: cannot create --out dir: $OUT" >&2; exit 1; }
OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN" || { echo "run-coordinator.sh: cannot create run dir: $RUN" >&2; exit 1; }
cp "$COORD_AG" "$RUN/coordinator.ag"

# Single shared agentis store for the WHOLE loop: the policy experience the coordinator writes one step
# must be visible to the next step's policy read (and to the blackboard the coordinator consults). init
# FIRST (before any .agentis/ subdir), else HEAD is unset.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p"; echo "llm.cli_timeout_ms = 600000"; }
  [ "$BACKEND" = "flat-cyborg" ] && echo "llm.cli_timeout_ms = 600000"
  echo "trace.level = normal"
  echo "exec.env_passthrough = SCOPE,CLASS_FITNESS,POLICY,PENDING,BUDGET,DRY_STREAK,DRY_CAP,PREV_ACTION,PREV_KEY,LAST_OUTCOME,DISPATCH_ENABLED,DISPATCH_FIXTURE,HUNT_FIXTURE,ORCHESTRATE_ENABLED,STEPS,SYM_POLICY_TT,SYM_REPO,SYM_SPEC,SYM_FUNCTION,HALMOS_VERIFY"
  # The LIVE symbolic-prove route (#1032) runs forge build + halmos + z3 over the supplied spec inside the
  # loop — tens of seconds, well past the 10s/30s defaults — so the per-step exec timeout is raised to 180s
  # when a live symbolic context is supplied (matches run-symbolic.sh's 180000ms). The offline/fixture path
  # never runs the gate, so its timeout is unchanged at 30s.
  if [ -n "$HALMOS_VERIFY" ]; then echo "exec.default_timeout_ms = 180000"; else echo "exec.default_timeout_ms = 30000"; fi
  # The whole point: every decision is recorded as experience so coordinator:policy:<type> reweights.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

EXP="$RUN/.agentis/experience/main.jsonl"

# --- policy reader: cumulative delta per action-type from the experience store. The coordinator's
# evolving POLICY. Mirrors evolve-fitness.sh::read_fitness (and tools/colony-fitness.py) exactly: sum the
# experience `delta` per `in` key for action=="coordinator". Emits `type=delta;type2=delta2` for the
# POLICY env fact (one line; "" when the store is cold). -------------------------------------------
read_policy() {
  [ -f "$EXP" ] || { printf '%s' ""; return 0; }
  python3 - "$EXP" <<'PY'
import json, os, sys
path = sys.argv[1]
agg = {}
if os.path.exists(path):
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("action") != "coordinator":
                continue
            k = r.get("in", "")
            if not k:
                continue
            agg[k] = agg.get(k, 0.0) + float(r.get("delta", 0.0))
print(";".join("%s=%.4f" % (k, agg[k]) for k in sorted(agg)))
PY
}

# Seed the per-lens CLASS_FITNESS fact from --class-fitness (`class|float` -> `class=float;...`). Static
# for the run (a fuller integration would read it live from the hunt experience like read_policy does).
CLASS_FITNESS=""
if [ -n "$CLASSFIT_FILE" ]; then
  [ -f "$CLASSFIT_FILE" ] || { echo "run-coordinator.sh: --class-fitness not found: $CLASSFIT_FILE" >&2; exit 2; }
  CLASS_FITNESS="$(awk -F'|' '
    { c=$1; v=$2; gsub(/^[ \t]+|[ \t]+$/,"",c); gsub(/^[ \t]+|[ \t]+$/,"",v); }
    c=="" || c ~ /^#/ { next }
    { printf "%s%s=%s", sep, c, v; sep=";" }
  ' "$CLASSFIT_FILE")"
fi

# SCOPE fact: the huntable cells as newline-joined `subsystem|class`, from the scope manifest.
SCOPE="$(awk -F'|' '
  { s=$1; c=$2; gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/^[ \t]+|[ \t]+$/,"",c); }
  s=="" || s ~ /^#/ { next }
  { printf "%s%s|%s", sep, s, c; sep="\n" }
' "$SCOPE_FILE")"

# DISPATCH_FIXTURE fact (#1014 M2): EVERY action's dispatch now lives in the substrate (coordinator.ag
# emits `dark-factory:dispatch` and calls dispatch() in-process for any real action; the verdict crosses
# back via the durable `coordinator:last_outcome` memo). The dispatcher derives each action's OFFLINE
# verdict from this fact — the SAME `<type>|<glob>|<outcome>` rules --fixture holds, projected to the
# `type|glob=verdict;type2|glob2=verdict2` env shape the agent parses (PREFIX glob matched against the
# action ARGS, first match wins, default `dry`). Built from ALL rows of --fixture in stub mode; empty
# otherwise (the agent's live honest per-type stub path). The shell no longer computes any outcome.
DISPATCH_FIXTURE=""
if [ "$EXECUTOR" = "stub" ] && [ -n "$FIXTURE" ]; then
  DISPATCH_FIXTURE="$(awk -F'|' '
    function trim(x){ gsub(/^[ \t]+|[ \t]+$/,"",x); return x }
    { t=trim($1); g=trim($2); o=trim($3) }
    t=="" || t ~ /^#/ { next }
    { printf "%s%s|%s=%s", sep, t, g, o; sep=";" }
  ' "$FIXTURE")"
fi

# --- #1014 M3: the shell LOOP is DISSOLVED. The whole multi-step audit now self-orchestrates INSIDE the
# substrate: ONE `agentis go coordinator.ag` with ORCHESTRATE_ENABLED runs the entire decide -> dispatch ->
# read-verdict -> update-PENDING/DRY_STREAK/BUDGET -> evolve-policy -> append-trace loop as a `reduce` over a
# budget-bounded STEPS list. This script is now a BOOTSTRAP: it seeds the FACTS + a STEPS budget list, fires
# the single in-substrate run, and reads the final `decisions.tsv` + evolved policy back from the durable
# memos the loop writes (`coordinator:trace`, `coordinator:policy_after`). NO per-step shell loop, NO
# shell-side PENDING/DRY_STREAK/BUDGET threading, NO shell-derived outcome — the federation drives the audit.
# (Follow-up, still on epic #1014: a long-lived daemon-tick reflex so the loop runs continuously, not once
# per bootstrap; the per-action LIVE executors.)
TRACE="$OUT/decisions.tsv"
: > "$TRACE"

# STEPS is a BOUND, not a sequence authority: a `0\n1\n…\n<BUDGET-1>` list whose LENGTH caps the loop at
# BUDGET iterations (agentis has no range(); a `reduce` over this string is the bounded-iteration idiom).
# The coordinator stops the moment its carried budget/dry-cap fires — the list only bounds the worst case.
STEPS=""
if [ "$BUDGET" -gt 0 ]; then
  STEPS="$(awk -v n="$BUDGET" 'BEGIN{ for (i=0;i<n;i++){ printf "%s%d", (i?"\n":""), i } }')"
fi

echo "run-coordinator.sh: policy BEFORE the run: [$(read_policy)]" >&2

# ONE in-substrate run drives the ENTIRE audit. ORCHESTRATE_ENABLED selects the loop mode; DISPATCH_ENABLED
# keeps every action's dispatch in-substrate (#1014 M2); DISPATCH_FIXTURE carries the offline verdict rules.
RUN_LOG="$RUN/orchestrate.log"
# --grant-pii: scope + target/spec repo paths and contract source can carry addresses/identifiers that
# trip the PII heuristic; input is benign public contract/scope text (#1690).
( cd "$RUN" && env \
    SCOPE="$SCOPE" \
    CLASS_FITNESS="$CLASS_FITNESS" \
    PENDING="" \
    BUDGET="$BUDGET" \
    DRY_CAP="$DRY_CAP" \
    STEPS="$STEPS" \
    SYM_POLICY_TT="$SYM_POLICY_TT" \
    SYM_REPO="$SYM_REPO" \
    SYM_SPEC="$SYM_SPEC" \
    SYM_FUNCTION="$SYM_FUNCTION" \
    HALMOS_VERIFY="$HALMOS_VERIFY" \
    ORCHESTRATE_ENABLED=1 \
    DISPATCH_ENABLED=1 \
    DISPATCH_FIXTURE="$DISPATCH_FIXTURE" \
    "$AGENTIS" go coordinator.ag --enable-exec --enable-messaging --grant-pii ) >"$RUN_LOG" 2>&1 \
  || { echo "run-coordinator.sh: in-substrate orchestration failed (see $RUN_LOG)" >&2; exit 1; }

grep -E '^ORCHESTRATE\|' "$RUN_LOG" >/dev/null 2>&1 \
  || { echo "run-coordinator.sh: orchestration did not complete (no ORCHESTRATE| marker; see $RUN_LOG)" >&2; exit 1; }

# Read the decisions.tsv body + the evolved policy back from the durable memos the loop wrote (the only
# substrate-native cross-process channel). The trace memo is the full TSV body; policy_after is the
# read_policy()-shaped `type=delta;…` string the in-loop policy threading produced.
( cd "$RUN" && "$AGENTIS" memo get coordinator:trace ) 2>/dev/null > "$TRACE" || true

# Echo each decision to stderr (the operator feed the per-step loop used to print live).
while IFS= read -r row; do
  [ -n "$row" ] || continue
  echo "run-coordinator.sh: $row" >&2
done < "$TRACE"

# The evolved policy: prefer the loop's in-process result (memo), cross-checked against the experience-store
# read_policy() (they are byte-identical by construction — the in-loop threading mirrors the store sum). The
# cross-check holds ONLY when the loop started cold: --sym-policy seeds the in-loop symbolic-prove weight with
# an initial offset that is NOT written to the experience store (only the per-outcome ±0.15 learn() deltas
# are), so a seeded run's in-loop policy intentionally exceeds the store sum by the seed. Skip the equality
# cross-check when a seed was supplied.
POLICY_LOOP="$( ( cd "$RUN" && "$AGENTIS" memo get coordinator:policy_after ) 2>/dev/null )"
POLICY_STORE="$(read_policy)"
if [ -z "$SYM_POLICY_TT" ] && [ "$POLICY_LOOP" != "$POLICY_STORE" ]; then
  echo "run-coordinator.sh: WARNING in-loop policy [$POLICY_LOOP] != experience-store policy [$POLICY_STORE]" >&2
fi
POLICY_AFTER="$POLICY_LOOP"
echo "run-coordinator.sh: policy AFTER the run:  [$POLICY_AFTER]" >&2
echo "run-coordinator.sh: decision trace -> $TRACE" >&2
printf '%s' "$POLICY_AFTER" > "$OUT/policy-after.txt"
exit 0
