#!/usr/bin/env bash
# run-autonomous-hunt.sh — Integration M1 + M2 (#1037): the self-orchestrating coordinator AUTONOMOUSLY
# chooses and LIVE-runs the stateful-invariant fuzzer on one or more targets, end-to-end. M2 adds the
# repeatable --candidate flag so each lead carries its OWN context and verifies on the RIGHT target.
#
# WHAT IT IS. This is the integration entrypoint that closes the loop between the #1014 self-orchestrating
# coordinator and the #1035 stateful-invariant fuzzer (`evm-harness/forge-invariant.sh`). It drives ONE
# `agentis go coordinator.ag` in ORCHESTRATE mode: the coordinator reads the FACTS (a pending candidate
# representing the target, the evolving policy) and DECIDES — by a policy-weighted argmax, never a fixed
# sequence — to route the candidate through the `invariant-hunt` VERIFY action. That action runs the REAL
# forge invariant fuzzer over the target test via `forge-invariant.sh` and maps its exit code to the gate
# outcome: 1=FINDING -> confirmed, 0=CLEAN -> refuted, 2/else=HARNESS_ERROR -> dry. The CHOICE of engine is
# the coordinator's evolving policy; the FINDING/CLEAN VERDICT is the FUZZER's shrunk witness — NEVER the LLM.
#
# This mirrors how `symbolic-prove` was given a live route (#1032 / demo-symbolic-orchestrate-live.sh): the
# coordinator CHOOSES the engine, the gate's exit code is the sound verdict, and the outcome evolves the
# policy. Submission stays human-gated; this colony never posts to a bounty platform.
#
# Int M2 (#1037): MULTI-CANDIDATE. Each discovered lead carries its OWN target context so the coordinator's
# live invariant-hunt verifies the RIGHT lead — not one shared operator env. A repeatable `--candidate` seeds
# the per-candidate `candidate:<id>:{repo,target,match}` memos (the durable cross-process channel the
# coordinator reads via recall_latest), and the coordinator resolves each fact PER-CANDIDATE-FIRST,
# env-fallback. The single `--repo/--target` stays as the one-candidate `cand-0` shorthand (full M1
# back-compat: with no --candidate the flat INV_REPO/INV_TARGET env path is byte-identical to M1).
#
# Usage:
#   run-autonomous-hunt.sh --repo <foundry-root> --target <Invariant.t.sol>
#                          [--match <prefix>] [--backend mock|flat-cyborg|claude]
#                          [--runs N] [--depth D] [--seed S] [--steps N] [--out <dir>]
#                          [--agentis <bin>]
#   run-autonomous-hunt.sh --candidate '<id>|<repo>|<target>[|<match>]' [--candidate ...] [flags...]
#
#   --repo <dir>      Foundry project root (must hold foundry.toml) the fuzzer runs in. REQUIRED unless one or
#                     more --candidate are supplied.
#   --target <file>   The invariant `*.t.sol` the fuzzer scopes to (absolute or relative to --repo). REQUIRED
#                     unless one or more --candidate are supplied.
#   --candidate '<id>|<repo>|<target>[|<match>]'
#                     A pending lead carrying its OWN context (repeatable). <id> is the candidate id (e.g.
#                     cand-0), <repo> a foundry root, <target> its invariant `*.t.sol`, optional <match> the
#                     invariant prefix (default "invariant"). The flat INV_REPO/INV_TARGET env is NOT required
#                     when candidates are supplied — each carries its target via its memo. BUDGET/STEPS auto-
#                     scale to >= 2 x candidate-count so every candidate is both routed and attributed.
#   --match <prefix>  Invariant function-name prefix forge runs (default "invariant").
#   --backend <b>     LLM backend for the agentis store (default mock — the DECISION is offline-deterministic;
#                     the verdict is the fuzzer's, so no LLM is needed for the integration loop).
#   --runs N          Optional forge invariant runs budget (search width); forwarded to the gate.
#   --depth D         Optional forge invariant depth budget (calls per sequence); forwarded to the gate.
#   --seed S          Optional forge --fuzz-seed for a reproducible search; forwarded to the gate.
#   --steps N         Loop step bound (default 2): one decision routes the candidate to invariant-hunt; the
#                     next attributes its outcome to the policy (proving outcome -> policy evolution).
#   --out <dir>       Output dir for the run (default: ./autonomous-hunt-out). A fresh agentis store is built
#                     under <out>/run.
#   --pattern-store <dir>  Int M3 (#1037): a PERSISTENT pattern-DAG store reused ACROSS runs. When set, the
#                     coordinator's chosen invariant-hunt is routed through invariant-prover.ag (not the bare
#                     gate) so a winning invariant pattern is PERSISTED on a FINDING (`invpat:*` memos in this
#                     store) and RECALLED to seed a LATER run on the same bug class (the prover prints
#                     `RECALL-INVPAT|<class>|<pattern>` + `INVPAT-LEARNED|<class>|<pattern>` into the run log).
#                     The verdict stays the fuzzer's exit code; persist/recall steer GENERATION only. Absent
#                     the flag the coordinator calls the gate directly -> no cross-run memory (M1/M2 byte-
#                     identical).
#   --method-fixture <file>  Int M3 (#1037) Part B: a deterministic method-inventor proposal (a `METHOD|...`
#                     line) the coordinator's invent-method action consults OFFLINE (no LLM) to propose a NEW
#                     invariant class. When set, its proposed class is seeded as `invpat:invented:<class>` in
#                     the pattern store so the NEXT invariant-hunt generation reads it as a hint. Absent the
#                     flag the invent-method stub behaviour is unchanged.
#   --agentis <bin>   agentis binary (default: `agentis` on PATH).
#
# Exit: 0 on a clean run that reached ORCHESTRATE|done; 2 on usage error; 3 on a missing prerequisite; 1 on a
# run failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
REPO=""
TARGET=""
MATCH="invariant"
BACKEND="mock"
RUNS=""
DEPTH=""
SEED=""
STEPS_N=2
STEPS_SET=0
OUT="$PWD/autonomous-hunt-out"
PATTERN_STORE=""
METHOD_FIXTURE=""
# Int M3 (#1037): the run-level bug class the prover keys its invpat:latest:<class> recall/persist on. This
# driver scopes the loop to a single class (matches SCOPE/CLASS_FITNESS below); the pattern memory is keyed on
# it so a later run on the SAME class recalls the earlier run's confirmed invariant shape.
PATTERN_CLASS="C1"
# Int M2 (#1037): accumulated --candidate specs, one per array slot (`<id>|<repo>|<target>[|<match>]`).
CANDIDATES=()

need() { [ "$1" -ge 2 ] || { echo "run-autonomous-hunt.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      need "$#"; REPO="$2"; shift 2 ;;
    --target)    need "$#"; TARGET="$2"; shift 2 ;;
    --candidate) need "$#"; CANDIDATES+=("$2"); shift 2 ;;
    --match)     need "$#"; MATCH="$2"; shift 2 ;;
    --backend)   need "$#"; BACKEND="$2"; shift 2 ;;
    --runs)      need "$#"; RUNS="$2"; shift 2 ;;
    --depth)     need "$#"; DEPTH="$2"; shift 2 ;;
    --seed)      need "$#"; SEED="$2"; shift 2 ;;
    --steps)     need "$#"; STEPS_N="$2"; STEPS_SET=1; shift 2 ;;
    --out)       need "$#"; OUT="$2"; shift 2 ;;
    --pattern-store) need "$#"; PATTERN_STORE="$2"; shift 2 ;;
    --method-fixture) need "$#"; METHOD_FIXTURE="$2"; shift 2 ;;
    --agentis)   need "$#"; AGENTIS="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-autonomous-hunt.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$MATCH" ] || { echo "run-autonomous-hunt.sh: --match prefix must be non-empty" >&2; exit 2; }
case "$STEPS_N" in (*[!0-9]*|'') echo "run-autonomous-hunt.sh: --steps must be a non-negative integer" >&2; exit 2 ;; esac
[ "$STEPS_N" -ge 1 ] || { echo "run-autonomous-hunt.sh: --steps must be >= 1 (one decision routes the candidate, the next attributes its outcome)" >&2; exit 2; }
for v in "$RUNS" "$DEPTH" "$SEED"; do
  case "$v" in '') ;; *[!0-9]*) echo "run-autonomous-hunt.sh: --runs/--depth/--seed must be whole numbers" >&2; exit 2 ;; esac
done

# The single --repo/--target is the one-candidate `cand-0` shorthand (full M1 back-compat). It is folded into
# the SAME candidate list the repeatable --candidate populates, so the seeding loop below treats both uniformly.
if [ -n "$REPO" ] || [ -n "$TARGET" ]; then
  [ -n "$REPO" ]   || { echo "run-autonomous-hunt.sh: --repo required alongside --target" >&2; exit 2; }
  [ -n "$TARGET" ] || { echo "run-autonomous-hunt.sh: --target required alongside --repo" >&2; exit 2; }
  CANDIDATES=("cand-0|$REPO|$TARGET|$MATCH" "${CANDIDATES[@]}")
fi
[ "${#CANDIDATES[@]}" -ge 1 ] || { echo "run-autonomous-hunt.sh: supply --repo/--target or at least one --candidate '<id>|<repo>|<target>[|<match>]'" >&2; exit 2; }

# Validate + ABSOLUTE-resolve every candidate's repo/target (the colony runs from the rundir, a different cwd;
# the exec sandbox cannot read a relative/home-rooted path). Each parsed candidate is stored back as
# `<id>|<repoAbs>|<targetAbs>|<matchPrefix>` in C_RESOLVED for the memo-seeding + PENDING loops below.
C_RESOLVED=()
for spec in "${CANDIDATES[@]}"; do
  c_id="${spec%%|*}"; rest="${spec#*|}"
  c_repo="${rest%%|*}"; rest="${rest#*|}"
  c_target="${rest%%|*}"
  if [ "$rest" = "$c_target" ]; then c_match="$MATCH"; else c_match="${rest#*|}"; fi
  [ -n "$c_id" ]     || { echo "run-autonomous-hunt.sh: --candidate '$spec' has an empty id" >&2; exit 2; }
  # The id becomes part of a `candidate:<id>:*` memo key (agentis memo keys reject whitespace and other
  # special chars). Reject anything outside [A-Za-z0-9_:.-] up front so a malformed id is a clean error
  # instead of a silenced `memo set` failure that would later degrade the candidate to the safe `dry` stub.
  case "$c_id" in *[!A-Za-z0-9_:.-]*) echo "run-autonomous-hunt.sh: --candidate id '$c_id' must match [A-Za-z0-9_:.-] (no spaces/special chars — it is a memo key)" >&2; exit 2 ;; esac
  [ -n "$c_repo" ]   || { echo "run-autonomous-hunt.sh: --candidate '$c_id' has an empty repo" >&2; exit 2; }
  [ -n "$c_target" ] || { echo "run-autonomous-hunt.sh: --candidate '$c_id' has an empty target" >&2; exit 2; }
  [ -n "$c_match" ]  || c_match="$MATCH"
  [ -d "$c_repo" ]   || { echo "run-autonomous-hunt.sh: --candidate '$c_id' repo is not a directory: $c_repo" >&2; exit 2; }
  [ -f "$c_repo/foundry.toml" ] || { echo "run-autonomous-hunt.sh: --candidate '$c_id' repo is not a foundry project (no foundry.toml): $c_repo" >&2; exit 2; }
  if [ -f "$c_target" ]; then
    c_target="$(cd "$(dirname "$c_target")" && pwd)/$(basename "$c_target")"
  elif [ -f "$c_repo/$c_target" ]; then
    c_target="$(cd "$c_repo" && pwd)/$c_target"
  else
    echo "run-autonomous-hunt.sh: --candidate '$c_id' target test not found: $c_target" >&2; exit 2
  fi
  c_repo="$(cd "$c_repo" && pwd)"
  C_RESOLVED+=("$c_id|$c_repo|$c_target|$c_match")
done
N_CAND="${#C_RESOLVED[@]}"

command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-autonomous-hunt.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

COORD_AG="$HERE/auditor/agents/coordinator.ag"
# Resolve the stateful-fuzzing gate to an ABSOLUTE path (relative to this script's own location) and pass it
# as FORGE_INVARIANT — the same env path invariant-prover.ag / run-invariant-hunt.sh use. No install location
# is hardcoded; forge is the caller's PATH responsibility, exactly as forge-invariant.sh requires.
FORGE_INVARIANT="$HERE/evm-harness/forge-invariant.sh"
PROVER_AG="$HERE/auditor/agents/invariant-prover.ag"
[ -f "$COORD_AG" ]        || { echo "run-autonomous-hunt.sh: coordinator agent not found at $COORD_AG" >&2; exit 3; }
[ -f "$FORGE_INVARIANT" ] || { echo "run-autonomous-hunt.sh: forge-invariant gate not found at $FORGE_INVARIANT" >&2; exit 3; }

# Int M3 (#1037): resolve the PERSISTENT pattern-DAG store and validate the optional method-fixture. Both are
# only consulted on the --pattern-store path; absent --pattern-store the whole M3 layer is skipped and the
# coordinator calls the bare gate (M1/M2 byte-identical).
if [ -n "$PATTERN_STORE" ]; then
  [ -f "$PROVER_AG" ] || { echo "run-autonomous-hunt.sh: invariant-prover agent not found at $PROVER_AG (needed for --pattern-store)" >&2; exit 3; }
  mkdir -p "$PATTERN_STORE" || { echo "run-autonomous-hunt.sh: cannot create --pattern-store dir: $PATTERN_STORE" >&2; exit 1; }
  PATTERN_STORE="$(cd "$PATTERN_STORE" && pwd)"
  [ -d "$PATTERN_STORE/.agentis" ] || ( cd "$PATTERN_STORE" && "$AGENTIS" init >/dev/null 2>&1 )
fi
if [ -n "$METHOD_FIXTURE" ]; then
  [ -f "$METHOD_FIXTURE" ] || { echo "run-autonomous-hunt.sh: --method-fixture not found: $METHOD_FIXTURE" >&2; exit 2; }
  [ -n "$PATTERN_STORE" ] || { echo "run-autonomous-hunt.sh: --method-fixture requires --pattern-store (the invented class is seeded there)" >&2; exit 2; }
  METHOD_FIXTURE="$(cd "$(dirname "$METHOD_FIXTURE")" && pwd)/$(basename "$METHOD_FIXTURE")"
fi

mkdir -p "$OUT" || { echo "run-autonomous-hunt.sh: cannot create --out dir: $OUT" >&2; exit 1; }
OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN" || { echo "run-autonomous-hunt.sh: cannot create run dir: $RUN" >&2; exit 1; }
cp "$COORD_AG" "$RUN/coordinator.ag"

# Int M3 (#1037): when --pattern-store is set, route the coordinator's chosen invariant-hunt through the
# PROVER (which PERSISTS/RECALLS the winning invariant pattern) instead of the bare gate — WITHOUT touching
# coordinator.ag. We do this by handing the coordinator a thin WRAPPER as FORGE_INVARIANT: it speaks the gate's
# exact CLI (--repo/--target/--match[/--runs/--depth/--seed]) and exit contract (1=FINDING,0=CLEAN,2=error), so
# the coordinator's run_invariant_live + sym_rc_of/sym_outcome_of mapping is byte-identical. Internally the
# wrapper runs invariant-prover.ag in the PERSISTENT store with the candidate's class as TARGET_CLASS, so a
# prior run's `invpat:latest:<class>` is RECALLED (the prover prints `RECALL-INVPAT|...`) before generation and
# a FINDING is PERSISTED (`INVPAT-LEARNED|...`). The wrapper delegates the actual fuzzing to the real gate. The
# prover's stdout (incl. RECALL-INVPAT/INVPAT-LEARNED) is teed to stderr so it lands in the orchestrate log.
GATE_FOR_COORD="$FORGE_INVARIANT"
if [ -n "$PATTERN_STORE" ]; then
  cp "$PROVER_AG"       "$RUN/invariant-prover.ag"
  cp "$FORGE_INVARIANT" "$RUN/forge-invariant.sh"
  WRAP="$RUN/prover-gate.sh"
  {
    echo '#!/usr/bin/env bash'
    echo '# Int M3 (#1037) prover-gate wrapper — auto-generated by run-autonomous-hunt.sh. Speaks the'
    echo '# forge-invariant.sh CLI + exit contract but routes through invariant-prover.ag so the winning'
    echo '# invariant pattern is persisted/recalled in the persistent pattern store. NOT for direct operator use.'
    echo 'set -uo pipefail'
    echo "RUNDIR=$(printf '%q' "$RUN")"
    echo "AGENTIS=$(printf '%q' "$AGENTIS")"
    echo "PATTERN_STORE=$(printf '%q' "$PATTERN_STORE")"
    echo "REAL_GATE=$(printf '%q' "$RUN/forge-invariant.sh")"
    # A stable trail file (the coordinator captures the wrapper's stdout/stderr into a string it discards, so
    # the prover's RECALL-INVPAT/INVPAT-LEARNED lines are persisted here for the driver to surface afterwards).
    echo "TRAIL=$(printf '%q' "$RUN/pattern-trail.log")"
    echo 'REPO=""; TARGET=""; MATCH="invariant"; RUNS=""; DEPTH=""; SEED=""'
    echo 'while [ $# -gt 0 ]; do case "$1" in'
    echo '  --repo) REPO="${2:-}"; shift 2 ;; --target) TARGET="${2:-}"; shift 2 ;;'
    echo '  --match) MATCH="${2:-}"; shift 2 ;; --runs) RUNS="${2:-}"; shift 2 ;;'
    echo '  --depth) DEPTH="${2:-}"; shift 2 ;; --seed) SEED="${2:-}"; shift 2 ;;'
    echo '  *) shift ;; esac; done'
    # The candidate class the coordinator routes. The orchestrate loop's PENDING cells all carry the run-level
    # class (the SCOPE class, C1), so the prover keys its invpat:latest:<class> recall/persist on it across runs.
    # Baked as a literal here (the gate CLI has no class field) — set via --pattern-store's run class below.
    echo "CLASS=$(printf '%q' "$PATTERN_CLASS")"
    echo 'WORK="$(mktemp -d "${TMPDIR:-/tmp}/prover-gate.XXXXXX")"'
    echo 'trap '"'"'rm -rf "$WORK"'"'"' EXIT'
    echo 'cp "$RUNDIR/invariant-prover.ag" "$WORK/invariant-prover.ag"'
    echo 'cp "$REAL_GATE" "$WORK/forge-invariant.sh"'
    echo '( cd "$WORK" && "$AGENTIS" init >/dev/null 2>&1 )'
    echo '{'
    echo '  echo "llm.backend = mock"'
    echo '  echo "trace.level = normal"'
    echo '  echo "exec.env_passthrough = TARGET_FN,TARGET_CLASS,INV_REPO,INV_OUT,INV_MATCH,HANDLER_FIXTURE,CODE_PATH,INV_RUNS,INV_DEPTH,INV_SEED,FORGE_INVARIANT"'
    echo '  echo "exec.default_timeout_ms = 600000"'
    echo '  echo "learning.enabled = true"'
    echo '  echo "experience.enabled = true"'
    echo '} > "$WORK/.agentis/config"'
    # RECALL: bridge prior invpat:* from the persistent store into the prover work store so recall_pattern() sees them.
    echo 'bridge() { _s="$1"; _d="$2"; ( cd "$_s" && "$AGENTIS" memo list 2>/dev/null ) | awk '"'"'{print $1}'"'"' | grep -E '"'"'^invpat:'"'"' | while IFS= read -r k; do v="$( ( cd "$_s" && "$AGENTIS" memo get "$k" ) 2>/dev/null )"; [ -n "$v" ] && ( cd "$_d" && "$AGENTIS" memo set "$k" "$v" >/dev/null 2>&1 ); done; }'
    echo 'bridge "$PATTERN_STORE" "$WORK"'
    # The prover writes the test into INV_REPO/test; stage a copy of the candidate repo so it can.
    echo 'REPO_IN_WORK="$WORK/repo"; cp -R "$REPO" "$REPO_IN_WORK"; rm -f "$REPO_IN_WORK/test/"*.t.sol 2>/dev/null || true; mkdir -p "$REPO_IN_WORK/test"'
    # Use the candidate's OWN target as the handler fixture (verbatim) so the verdict is the fuzzer's over the
    # SAME test the live route would run — the prover's job here is the persist/recall, not regenerating the test.
    echo 'cp "$TARGET" "$WORK/handler-fixture.t.sol"'
    echo 'INV_OUT="$REPO_IN_WORK/test/Inv_gate.t.sol"'
    echo 'OPT=""; [ -n "$RUNS" ] && OPT="$OPT --runs $RUNS"; [ -n "$DEPTH" ] && OPT="$OPT --depth $DEPTH"; [ -n "$SEED" ] && OPT="$OPT --seed $SEED"'
    echo 'LOG="$WORK/prover.log"'
    echo '( cd "$WORK" && env TARGET_FN="$TARGET" TARGET_CLASS="$CLASS" INV_REPO="$REPO_IN_WORK" INV_OUT="$INV_OUT" INV_MATCH="$MATCH" HANDLER_FIXTURE="$WORK/handler-fixture.t.sol" CODE_PATH="" INV_RUNS="$RUNS" INV_DEPTH="$DEPTH" INV_SEED="$SEED" FORGE_INVARIANT="$WORK/forge-invariant.sh" "$AGENTIS" go invariant-prover.ag --enable-exec --enable-messaging ) >"$LOG" 2>&1 || true'
    # Surface the prover trail (incl. RECALL-INVPAT / INVPAT-LEARNED) to stderr AND append it to the stable
    # trail file the driver reads back (the coordinator discards the captured exec output, so the trail file is
    # the durable channel for the prover's recall/persist evidence).
    echo 'grep -E "^(RECALL-INVPAT|INVPAT-LEARNED|INVARIANT)\|" "$LOG" | tee -a "$TRAIL" >&2 || true'
    # PERSIST: bridge any invpat:* the prover wrote back OUT to the persistent store for the next run.
    echo 'bridge "$WORK" "$PATTERN_STORE"'
    # Map the prover verdict to the gate exit contract the coordinator expects (1=FINDING,0=CLEAN,2=error).
    echo 'VL="$(grep "INVARIANT|" "$LOG" | tail -1 || true)"'
    echo 'VERD="$(printf "%s" "$VL" | sed "s/.*INVARIANT|//" | cut -d"|" -f2)"'
    echo 'case "$VERD" in FINDING) exit 1 ;; CLEAN) exit 0 ;; *) exit 2 ;; esac'
  } > "$WRAP"
  chmod +x "$WRAP"
  GATE_FOR_COORD="$WRAP"
fi

# Int M3 (#1037) Part B: the invent-method feed. A --method-fixture is a deterministic method-inventor proposal
# (a `METHOD|<name>|<bug-classes>|<technique>|<how-to-invoke>|<control-assert>` line — the same shape
# method-inventor.ag emits, used OFFLINE so the wiring is provable without an LLM). We parse the proposed bug
# class (field 3, the first comma-separated class) and seed it as `invpat:invented:<class>` in the PERSISTENT
# pattern store, so the NEXT invariant-hunt generation's recall_pattern() reads it as a generation hint (the
# prover checks `invpat:invented:<class>` when no persisted FINDING pattern exists yet). This is the
# self-invents feed: a NEW invariant class the federation proposed steers a later hunt's GENERATE.
if [ -n "$METHOD_FIXTURE" ]; then
  M_LINE="$(grep -E '^METHOD\|' "$METHOD_FIXTURE" | head -1 || true)"
  if [ -n "$M_LINE" ]; then
    M_CLASSES="$(printf '%s' "$M_LINE" | cut -d'|' -f3)"
    M_CLASS="$(printf '%s' "$M_CLASSES" | cut -d',' -f1 | tr -d '[:space:]')"
    if [ -n "$M_CLASS" ]; then
      ( cd "$PATTERN_STORE" && "$AGENTIS" memo set "invpat:invented:$M_CLASS" "$M_LINE" >/dev/null 2>&1 )
      echo "run-autonomous-hunt.sh: invent-method seeded invpat:invented:$M_CLASS from $METHOD_FIXTURE" >&2
    fi
  fi
fi

# A single shared agentis store for the whole orchestrate run (the policy the coordinator writes one step
# must be visible to the next). init FIRST (before any .agentis/ subdir), else HEAD is unset.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p"; echo "llm.cli_timeout_ms = 600000"; }
  [ "$BACKEND" = "flat-cyborg" ] && echo "llm.cli_timeout_ms = 600000"
  echo "trace.level = normal"
  echo "exec.env_passthrough = SCOPE,CLASS_FITNESS,POLICY,PENDING,BUDGET,DRY_STREAK,DRY_CAP,PREV_ACTION,PREV_KEY,LAST_OUTCOME,DISPATCH_ENABLED,DISPATCH_FIXTURE,HUNT_FIXTURE,ORCHESTRATE_ENABLED,STEPS,SYM_POLICY_TT,INV_POLICY_TT,SYM_REPO,SYM_SPEC,SYM_FUNCTION,HALMOS_VERIFY,FORGE_INVARIANT,INV_REPO,INV_TARGET,INV_MATCH,INV_RUNS,INV_DEPTH,INV_SEED"
  # A forge invariant run (build + a few hundred fuzzed sequences) far exceeds the 10s/30s defaults — match
  # run-invariant-hunt.sh's 600s budget so the live fuzzer has room to run inside the loop.
  echo "exec.default_timeout_ms = 600000"
  # The whole point: every decision is recorded as experience so coordinator:policy:<type> reweights.
  echo "learning.enabled = true"
  echo "experience.enabled = true"
} > "$RUN/.agentis/config"

# Int M2 (#1037): seed each candidate's OWN context into the SHARED store the coordinator reads from via
# recall_latest("candidate:<id>:..."). MUST run AFTER `agentis init` (the store exists) and BEFORE `agentis go`
# (the loop reads them). These keys are NOT in exec.env_passthrough — they cross via the durable memo channel,
# not env — so each pending lead verifies its OWN repo/target, env-fallback only when a memo is empty.
for spec in "${C_RESOLVED[@]}"; do
  c_id="${spec%%|*}"; rest="${spec#*|}"
  c_repo="${rest%%|*}"; rest="${rest#*|}"
  c_target="${rest%%|*}"; c_match="${rest#*|}"
  ( cd "$RUN" && "$AGENTIS" memo set "candidate:$c_id:repo" "$c_repo" >/dev/null 2>&1 )
  ( cd "$RUN" && "$AGENTIS" memo set "candidate:$c_id:target" "$c_target" >/dev/null 2>&1 )
  ( cd "$RUN" && "$AGENTIS" memo set "candidate:$c_id:match" "$c_match" >/dev/null 2>&1 )
done

# SEED the in-substrate loop's INITIAL invariant-hunt policy weight high enough that score_invariant
# (94 + 4x lead) beats score_refute (100): lead >= ~1.6 lifts invariant-hunt above refute. We use 2.0
# (= INV_POLICY_TT 20000 ten-thousandths) so the coordinator AUTONOMOUSLY chooses invariant-hunt from step 0.
# This stands in for the policy a PRIOR run would have evolved — the fuzzer's witnesses paying off and the
# colony having learned to lean on the stateful engine for this candidate. (agentis offers no float->int
# builtin, so the integer is supplied directly, exactly like run-coordinator.sh's SYM_POLICY_TT.)
INV_POLICY_TT=20000

# Int M2 (#1037): one PENDING cell PER candidate (`<id>|<subsystem>|<class>`) in submission order — the
# orchestrate loop pops the first pending lead each VERIFY step, routes it through invariant-hunt, and the
# per-candidate memo seeded above makes that lead verify its OWN target. The SCOPE/CLASS_FITNESS carry one
# cell so the post-verify fallback (after the last candidate is consumed) has a lens to fall back to.
SCOPE="vault accounting|C1"
CLASS_FITNESS="C1=0.5500"
PENDING=""
for spec in "${C_RESOLVED[@]}"; do
  c_id="${spec%%|*}"
  cell="$c_id|vault accounting|C1"
  if [ -z "$PENDING" ]; then PENDING="$cell"; else PENDING="$PENDING
$cell"; fi
done

# Int M2 (#1037): scale the loop budget to >= 2 x candidate-count so EVERY candidate is both routed (one step)
# AND its outcome attributed to the policy (the next step), never starved by the bound. A larger explicit
# --steps wins; otherwise STEPS_N climbs to 2*N. BUDGET tracks STEPS_N so the loop runs that many decisions.
MIN_STEPS=$((2 * N_CAND))
if [ "$STEPS_SET" -eq 0 ] && [ "$STEPS_N" -lt "$MIN_STEPS" ]; then
  STEPS_N="$MIN_STEPS"
elif [ "$STEPS_SET" -eq 1 ] && [ "$STEPS_N" -lt "$MIN_STEPS" ]; then
  echo "run-autonomous-hunt.sh: --steps $STEPS_N < 2 x candidates ($MIN_STEPS); each candidate needs a route + an attribute step" >&2
  exit 2
fi

# STEPS is a BOUND, not a sequence authority (agentis has no range(); a reduce over this list bounds the loop
# at <steps> iterations). BUDGET matches so the loop runs exactly <steps> decisions worst-case.
STEPS=""
if [ "$STEPS_N" -gt 0 ]; then
  STEPS="$(awk -v n="$STEPS_N" 'BEGIN{ for (i=0;i<n;i++){ printf "%s%d", (i?"\n":""), i } }')"
fi

RUN_LOG="$RUN/orchestrate.log"
# ONE in-substrate run drives the autonomous hunt. ORCHESTRATE_ENABLED selects the loop; DISPATCH_ENABLED keeps
# each action's dispatch in-substrate; DISPATCH_FIXTURE is EMPTY so invariant-hunt takes its LIVE route. Int M2
# (#1037): the per-candidate `candidate:<id>:*` memos (seeded into the store above) carry each lead's repo/
# target; the flat INV_REPO/INV_TARGET/INV_MATCH below are only the env-FALLBACK (set by the --repo/--target
# shorthand, EMPTY in the multi-candidate path so each lead resolves purely from its carried memo). INV_POLICY_TT
# seeds the policy so the engine is chosen.
( cd "$RUN" && env \
    SCOPE="$SCOPE" \
    CLASS_FITNESS="$CLASS_FITNESS" \
    PENDING="$PENDING" \
    BUDGET="$STEPS_N" \
    DRY_CAP=3 \
    STEPS="$STEPS" \
    INV_POLICY_TT="$INV_POLICY_TT" \
    ORCHESTRATE_ENABLED=1 \
    DISPATCH_ENABLED=1 \
    DISPATCH_FIXTURE="" \
    FORGE_INVARIANT="$GATE_FOR_COORD" \
    INV_REPO="$REPO" \
    INV_TARGET="$TARGET" \
    INV_MATCH="$MATCH" \
    INV_RUNS="$RUNS" \
    INV_DEPTH="$DEPTH" \
    INV_SEED="$SEED" \
    "$AGENTIS" go coordinator.ag --enable-exec --enable-messaging ) >"$RUN_LOG" 2>&1 \
  || { echo "run-autonomous-hunt.sh: in-substrate autonomous hunt failed (see $RUN_LOG)" >&2; exit 1; }

grep -E '^ORCHESTRATE\|' "$RUN_LOG" >/dev/null 2>&1 \
  || { echo "run-autonomous-hunt.sh: orchestration did not complete (no ORCHESTRATE| marker; see $RUN_LOG)" >&2; exit 1; }

# Int M3 (#1037): the prover-gate wrapper persists its RECALL-INVPAT / INVPAT-LEARNED evidence to the trail
# file (the coordinator discards the captured exec output). Fold the trail INTO the orchestrate log so the
# pattern-memory loop is observable in the run log the rest of the pipeline reads, and surface it on stderr.
# Skipped (no-op) when --pattern-store was not supplied (the trail file does not exist).
PATTERN_TRAIL="$RUN/pattern-trail.log"
if [ -s "$PATTERN_TRAIL" ]; then
  cat "$PATTERN_TRAIL" >> "$RUN_LOG"
  echo "run-autonomous-hunt.sh: pattern-memory trail:" >&2
  grep -E '^(RECALL-INVPAT|INVPAT-LEARNED)\|' "$PATTERN_TRAIL" | while IFS= read -r line; do
    echo "run-autonomous-hunt.sh: $line" >&2
  done
fi

# Surface the AUTONOMOUS DECISION TRAIL: the coordinator's ACTION| lines (what it chose + why) and the
# DISPATCH| lines (the fuzzer's verdict for each). The full run log (incl. the LIVE-route message + any
# shrunk witness) is at $RUN_LOG.
echo "run-autonomous-hunt.sh: autonomous decision trail:" >&2
grep -E '^(ACTION|DISPATCH)\|' "$RUN_LOG" | while IFS= read -r line; do
  echo "run-autonomous-hunt.sh: $line" >&2
done

# The FINAL VERDICT for the routed candidate is the durable coordinator:last_outcome memo (the substrate-native
# cross-process channel): `<type>|<args>|<verdict>`. The verdict is the fuzzer's shrunk witness, never the LLM.
OUTCOME="$( ( cd "$RUN" && "$AGENTIS" memo get coordinator:last_outcome ) 2>/dev/null | tail -1 )"
POLICY_AFTER="$( ( cd "$RUN" && "$AGENTIS" memo get coordinator:policy_after ) 2>/dev/null )"
echo "run-autonomous-hunt.sh: final coordinator:last_outcome = [$OUTCOME]" >&2
echo "run-autonomous-hunt.sh: policy AFTER the run        = [$POLICY_AFTER]" >&2
echo "run-autonomous-hunt.sh: full run log -> $RUN_LOG" >&2
exit 0
