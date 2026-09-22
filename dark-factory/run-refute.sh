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
# Env:
#   SEVERITY_RUBRIC  #2245 iteration 2 OPT-IN, default UNSET = OFF. `1` injects refuter.ag's contest-severity
#                    rubric + the CLOSED dismissal-ground list into the HOW-TO-JUDGE body and asks for one
#                    `REFUTE-GROUND|<ground-id>|<evidence>` line ahead of a REFUTED verdict. Unset / any other
#                    value leaves the prompt BYTE-IDENTICAL to the pre-#2245 one in BOTH modes, and leaves the
#                    gate below inert (it fires only on the agent's own `SEVERITY-RUBRIC|` sentinel). The SAME
#                    export covers the hunter half, so `export SEVERITY_RUBRIC=1` is ONE variable for both
#                    decision points — including through verify-findings.sh, which invokes this script as a
#                    plain subprocess and therefore needs no change of its own.
#   GROUND_EVIDENCE  #2245 iteration 3 OPT-IN, default UNSET = OFF, INDEPENDENT of SEVERITY_RUBRIC (a second
#                    knob, not a `SEVERITY_RUBRIC=2` sub-mode). `1` appends refuter.ag's per-ground EVIDENCE
#                    contract to the rubric directive — which can only happen inside a rubric-ON prompt, since
#                    the block is concatenated inside it — and arms the contract half of the gate below: a
#                    REFUTED verdict whose ground id is SUFFICIENT but whose evidence does not meet that
#                    ground's contract is treated exactly like an insufficient ground (one bounded re-ask, then
#                    `REFUTED` + the `rubric-insufficient: ` prefix + a sidecar row carrying the contract id).
#                    Unset / any other value leaves the prompt and the gate byte-identical to iteration 2 (the
#                    gate fires only on the agent's own `GROUND-EVIDENCE|` sentinel). Citations resolve against
#                    `--code-dir` + the brief, degrading to citation-SHAPE only when that is not the target
#                    tree; there is NO new flag and verify-findings.sh is untouched (STOP-1 decision 4).
#   DF_RUBRIC_MAX_REASKS  #2245 iteration 2: how many extra hostile reads a REFUTED verdict standing on an
#                    INSUFFICIENT ground gets. Default 1 (the bounded one-extra-call-per-candidate budget the
#                    #1699 C6 fallback established); 0 = gate-only (record it, never re-ask); garbage => 1.
#
# Outputs: `<out>/refute-report.md` (the verdict table, an unchanged downstream contract) and — #1887 —
# `<out>/refute-constraints.tsv`, one `<class>\t<file:fn>\t<constraint>` row per REFUTED candidate whose
# reply carried the generalisable `CONSTRAINT|` line. That file is the input of refute-to-knowledge.sh, which
# turns it into an agentis knowledge corpus a LATER target's hunter can read. Always written (empty = no
# refutation produced a constraint); nothing in this script consumes it.
#
# #2245 iteration 2 adds a THIRD output, `<out>/rubric-dismissals.tsv` (`<class>\t<file:fn>\t<ground-id>\t
# <reason>`), written LAZILY — one row per candidate whose REFUTED verdict still stood on an insufficient ground
# after the bounded re-ask, and no file at all when there is none, so a default (knob-OFF) run's output dir is
# unchanged. The verdict column deliberately STAYS `REFUTED` in that case: verify-findings.sh matches the cell
# against the exact vocabulary `REAL|REFUTED|ERROR`, so a fifth token would be read as "no verdict row" and the
# candidate would be silently dropped. The report reason is prefixed `rubric-insufficient: ` instead. There is
# NO mechanical `REFUTED -> REAL` flip anywhere (issue #2245 STOP-1 decision 1): that would put an unjudged lead
# into the CONFIRMED-only contract and would make the pre-registered gate mechanically reachable. The honest
# consequence, stated rather than hidden: a gate that holds an insufficient ground through the re-ask makes the
# arm a NO-GO, visibly.
#
# #2245 iteration 3 appends a FIFTH column to that file, `<contract-id>` — which per-ground EVIDENCE contract the
# held ground failed (`cite-missing`, `cite-unresolved`, `cite-not-a-guard`, `cite-not-validating`,
# `no-zero-delta`, `reachability-as-no-loss`, `unquantified`, `admitted-vs-deployed`), EMPTY when the ground id
# itself was insufficient and on every contract-OFF run. The file has exactly one consumer in this repository
# (demo-severity-rubric.sh, which pins its field count), so this is an additive change to an operator-only
# artefact; the verdict column and the report row are untouched.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# #2119: wide flat-cyborg PTY by default for every flat-cyborg config emission (see the helper header).
# shellcheck source=lib/flat-cyborg-env.sh
# shellcheck disable=SC1091
. "$HERE/lib/flat-cyborg-env.sh"
# #1707: shared reply-shape validation + retry for the refuter substrate call (see the helper header).
# verify-findings.sh inherits this fix transitively (it dispatches to run-refute.sh, no `agentis go` of its own).
# shellcheck source=lib/run-agent-validated.sh
# shellcheck disable=SC1091
. "$HERE/lib/run-agent-validated.sh"
DF_AGENT_MAX_ATTEMPTS="$(df_max_attempts)"
# #2245 iteration 2: the re-ask ceiling for the dismissal-GROUND gate (see the Env block above). Floor 0
# (0 = gate-only, no re-ask); garbage => 1. Irrelevant on a default run — the gate needs the agent's sentinel.
DF_RUBRIC_MAX_REASKS="${DF_RUBRIC_MAX_REASKS:-1}"
case "$DF_RUBRIC_MAX_REASKS" in ''|*[!0-9]*) DF_RUBRIC_MAX_REASKS=1 ;; esac
# agentis-core#993: pre-accept Claude Code's workspace-trust dialog for the RUN dir
# (below), so the flat-cyborg/claude backend session does not block + exit 75.
# shellcheck source=lib/ensure-claude-trust.sh
# shellcheck disable=SC1091
. "$HERE/lib/ensure-claude-trust.sh"
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
# #2125: thread the sandbox bind vars into the agentis invocation (run_flat_cyborg does not env_clear). The
# refuter reads only candidate code + brief that are STAGED into $RUN (see the code-staging below), so no repo
# bind is needed; RUN alone covers everything the sandboxed cell touches.
export HUNT_SANDBOX_REPO="" HUNT_SANDBOX_RUN="$RUN"
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
  [ "$BACKEND" = "flat-cyborg" ] && { echo "llm.cli_timeout_ms = 600000"; echo "llm.flat_cyborg.idle_ms = 12000"; echo "llm.flat_cyborg.result_file_dir = $RUN"; echo "llm.model = ${MODEL:-opus}"; }
  # #2125: sandbox the driven Claude Code session (bubblewrap view = toolchain + run dir only, web tools denied).
  [ "$BACKEND" = "flat-cyborg" ] && [ -z "${DF_NO_SANDBOX:-}" ] && command -v bwrap >/dev/null 2>&1 && echo "llm.flat_cyborg.target = $HERE/lib/claude-sandboxed.sh"
  echo "trace.level = normal"
  # The refuter reads the candidate code + brief through exec sh; pass through its whole env contract.
  # AUX_CODE_PATH (#1861) MUST be on this allowlist: getenv() reads the SANITIZED env, so an unregistered
  # knob is silently inert — the implementation appendix would be staged, never read, and the gate would keep
  # refuting abstract bases in isolation with no visible failure at all.
  # #1938: CAND_INVARIANT + INV_HARNESS_PATH MUST be on this allowlist too — getenv() reads the SANITIZED env,
  # so an unregistered knob is staged and never read (the whole invariant mode would be silently inert). Both are
  # exported EMPTY when --invariant-mode is off, so their presence on the line is a no-op for every legacy run.
  # #2245 iteration 2: SEVERITY_RUBRIC + RUBRIC_REASK_GROUNDS MUST be on this allowlist for the same reason —
  # refuter.ag gates the whole rubric on getenv("SEVERITY_RUBRIC"), which reads the SANITIZED env, so an
  # unregistered knob would make the opt-in unreachable and the feature silently inert. Both are empty on a
  # default run, so their presence on the line is a no-op there.
  # #2245 iteration 3: GROUND_EVIDENCE rides it for exactly the same reason, as its own independent knob — and
  # it can only have an effect inside a rubric-ON prompt, since its block is concatenated inside the rubric
  # directive.
  echo "exec.env_passthrough = CAND_FILE_FN,CAND_CLASS,CAND_SEVERITY,CAND_EXPLOIT,CODE_PATH,BRIEF_PATH,AUX_CODE_PATH,CAND_INVARIANT,INV_HARNESS_PATH,SEVERITY_RUBRIC,RUBRIC_REASK_GROUNDS,GROUND_EVIDENCE"
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

# #993: trust the RUN dir before the first `agentis go` so a flat-cyborg/claude
# refuter session is not blocked on the workspace-trust dialog (mock never spawns
# claude). Best-effort — never fails the refutation.
case "$BACKEND" in flat-cyborg|claude) df_ensure_claude_trust "$RUN" ;; esac

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
# #2245 iteration 2: the insufficient-ground sidecar, `<class>\t<file:fn>\t<ground-id>\t<reason>`. An additive
# FILE, never a new column or key (refute-report.md's row shape is a downstream contract), and — unlike
# refute-constraints.tsv — created LAZILY, on the first row: with the knob off no row is ever written, so a
# default run's output dir is byte-identical to a pre-#2245 one.
RUBRIC_TSV="$OUT/rubric-dismissals.tsv"

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
# opens (and replaces) the record; a blank line, an `AUX-CONTEXT|` sentinel, a `REFUTE-GROUND|` line (#2245
# iteration 2 — a stray post-verdict ground line must never be glued into the verdict reason), EOF or 12
# continuation lines close it; any other line while a record is open is appended with its leading whitespace stripped and a
# single joining space (terminal wrap breaks on column width, not on meaningful newlines).
_join_wrapped_verdict() {
  jwv_log="$1"
  awk '
    /VERDICT\|/ { rec = $0; open = 1; cont = 0; next }
    open && (/^[[:space:]]*$/ || /AUX-CONTEXT\|/ || /REFUTE-GROUND\|/ || /GROUND-EVIDENCE\|/) { open = 0; next }
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
# verdict, so the verdict line is the natural terminator and must never be glued into the sentence). A
# `REFUTE-GROUND|` line closes it too (#2245 iteration 2: the contract puts the ground FIRST, but a model that
# emits the two in the other order must not have its ground swallowed into the constraint sentence). A blank
# line, EOF or 12 continuation lines also close it. The LAST constraint record in the log wins, mirroring
# _join_wrapped_verdict's "last record" rule — and note this scraper is deliberately SEPARATE: touching
# _join_wrapped_verdict would put the verdict row (which verify-findings.sh reads with `awk -F'|'`) at risk.
_join_wrapped_constraint() {
  jwc_log="$1"
  awk '
    /CONSTRAINT\|/ { rec = $0; open = 1; cont = 0; next }
    open && (/VERDICT\|/ || /REFUTE-GROUND\|/ || /GROUND-EVIDENCE\|/ || /^[[:space:]]*$/) { open = 0; next }
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

# --- #2245 iteration 2: the dismissal-GROUND gate -----------------------------------------------------------
# The measured cause (issue #2245 iteration 1): this gate refuted a contest-accepted Medium on "owner-only
# intentional guard, no external attacker, another exit path bypasses it, so no funds are locked" — one of three
# losses that all applied that single criterion. refuter.ag now carries the contest severity rubric + a CLOSED
# ground list (BYTE-IDENTICAL to hunter.ag's) and must name the ground a REFUTED verdict stands on. This is the
# OUTPUT half: prompt text is not a gate (the #2213 lesson), so the ground is checked here.
#
# _rubric_sufficient_grounds — the closed list of ground ids a refutation may stand on, byte-identical to
# run-discovery.sh's function of the same name (demo-severity-rubric.sh diffs the two, and both against the
# prompt text). It is the single decider: anything not on it — including the four INSUFFICIENT ids, an
# unrecognised id and a missing line — is insufficient, which is exactly the rubric's own rule.
_rubric_sufficient_grounds() {
  printf '%s\n' 'guard unreachable no-loss known-issue immaterial-quantified'
}

# _join_wrapped_ground <log> — the #2245 twin of the two scrapers above, for the `REFUTE-GROUND|<ground-id>|
# <evidence>` line the refuter prints ahead of a REFUTED verdict. Same PTY-wrap problem, same joining rules,
# two boundaries: a `CONSTRAINT|` or a `VERDICT|` line closes an open ground record (both follow it under the
# contract, so either is a natural terminator and neither may be glued into the evidence). A blank line, EOF or
# 12 continuation lines also close it. The LAST ground record wins, mirroring both siblings — and this is
# deliberately a THIRD function rather than a parameter on one of them: touching _join_wrapped_verdict would put
# the verdict row (which verify-findings.sh reads with `awk -F'|'`) at risk for a best-effort diagnostic.
_join_wrapped_ground() {
  jwg_log="$1"
  awk '
    /REFUTE-GROUND\|/ { rec = $0; open = 1; cont = 0; next }
    open && (/VERDICT\|/ || /CONSTRAINT\|/ || /GROUND-EVIDENCE\|/ || /^[[:space:]]*$/) { open = 0; next }
    open {
      if (cont >= 12) { open = 0; next }
      line = $0
      sub(/^[[:space:]]+/, "", line)
      rec = rec " " line
      cont++
    }
    END { if (rec != "") print rec }
  ' "$jwg_log"
}

# --- #2245 iteration 3: the per-ground EVIDENCE contract ----------------------------------------------------
# The measured cause (issue #2245 iteration 2, held-out r1): this gate REFUTED the row on the SUFFICIENT ground
# `no-loss` and then argued REACHABILITY — no path, no zero delta, and it never engaged the state the candidate
# described. The gate above checks the ground ID; nothing checked the evidence. So the contract below is checked
# on the SAME emitted line, and a failure is folded into the EXISTING insufficient path: same one bounded
# re-ask, same `REFUTED` verdict, same sidecar row. A detector, not a second mechanism.
#
# _ground_contract_armed <log> — the ONLY gate of this layer, the twin of run-discovery.sh's: refuter.ag's
# honesty-gated `GROUND-EVIDENCE|` sentinel is in this candidate's log, so the contract really entered the
# prompt this verdict answered. Never the env var: a verdict must not be re-asked against a contract it was
# never shown, and with GROUND_EVIDENCE off every log is unarmed and this whole layer decides nothing.
_ground_contract_armed() {
  grep -qE '^[[:space:]]*GROUND-EVIDENCE\|' "$1" 2>/dev/null
}

# _dismiss_evidence_ok <line> [root] [brief] — BYTE-IDENTICAL to run-discovery.sh's copy (demo-severity-rubric.sh
# diffs the two, the same anti-drift contract _rubric_sufficient_grounds already carries). One decider, two
# decision points: the hunt side feeds it a `DISMISS|` line, this side rebuilds the same shape from its
# `REFUTE-GROUND|` record (see _refute_ground_contract below), so neither gate can accept evidence the other
# rejects. Returns 0 on pass; on failure it prints the contract id and returns 1.
_dismiss_evidence_ok() {
  de_line="$1"; de_root="${2:-}"; de_brief="${3:-}"
  # Self-contained by design: every regex lives HERE, like _uncited_dismissal_lines's do, because
  # demo-severity-rubric.sh slices this function out by line range and sources it — a decider that depended on
  # script-level state would behave differently there than in production, which is the whole point of slicing.
  de_pathline_re='[A-Za-z0-9_/.-]+\.(sol|ts|js|md|json|toml|ya?ml):[0-9]+(-[0-9]+)?'
  de_guard_re='require|revert|assert|if[[:space:]]*\(|modifier|only[A-Z]|_checkRole|msg\.sender'
  de_valid_re='require|revert|assert|if[[:space:]]*\('
  de_deploy_re='(^|/)(script|scripts|deploy|broadcast)/'
  de_reach_re='never|cannot|can not|does not occur|impossible|no such state|not reachable|would require'
  de_admit_re='ONCHAIN|@block|as deployed|currently deployed|as shipped|shipped (market|config|deployment)|mainnet|live market'
  de_fn_re='[A-Za-z_][A-Za-z0-9_]*\('
  de_g="$(printf '%s' "$de_line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
  # Fields 4..N, not field 4 alone: the measured lines merge verdict and evidence, exactly as
  # _uncited_dismissal_lines reads fields 3..N of a TRACE line for the same reason.
  de_span="$(printf '%s' "$de_line" | cut -d'|' -f4-)"
  de_cite="$(printf '%s' "$de_span" | grep -oE "$de_pathline_re" | head -1)"
  de_need=""; de_failid=""
  case "$de_g" in
    guard)
      [ -n "$de_cite" ] || { printf 'cite-missing\n'; return 1; }
      de_need="$de_guard_re"; de_failid="cite-not-a-guard" ;;
    unreachable)
      [ -n "$de_cite" ] || { printf 'cite-missing\n'; return 1; }
      # Deliberately the INVERSE of the #2225 configuration rule, which REQUIRES a deploy/test citation: that
      # rule asks what the repository SHIPS, this ground asks what the repository REFUSES. Do not harmonise.
      if printf '%s' "${de_cite%%:*}" | grep -Eq "$de_deploy_re"; then printf 'cite-not-validating\n'; return 1; fi
      de_need="$de_valid_re"; de_failid="cite-not-validating" ;;
    no-loss)
      if ! printf '%s' "$de_span" | grep -Eqi 'delta=0:[^[:space:]]'; then printf 'no-zero-delta\n'; return 1; fi
      if ! printf '%s' "$de_span" | grep -Eq "$de_pathline_re|$de_fn_re"; then printf 'cite-missing\n'; return 1; fi
      # The measured loss: a reachability argument filed under a sufficient ground. That claim is `unreachable`
      # and needs that ground's citation, so the vocabulary veto applies here and nowhere else.
      if printf '%s' "$de_span" | grep -Eqi "$de_reach_re"; then printf 'reachability-as-no-loss\n'; return 1; fi ;;
    known-issue)
      # shellcheck disable=SC2016  # a grep ERE held verbatim: nothing in it may expand
      de_q="$(printf '%s' "$de_span" | grep -oE '"[^"]{12,}"|`[^`]{12,}`' | head -1)"
      [ -n "$de_q" ] || { printf 'cite-missing\n'; return 1; }
      if [ -n "$de_brief" ] && [ -f "$de_brief" ]; then
        de_q="$(printf '%s' "$de_q" | sed 's/^.//; s/.$//')"
        grep -Fq "$de_q" "$de_brief" 2>/dev/null || { printf 'cite-unresolved\n'; return 1; }
      fi ;;
    immaterial-quantified)
      if ! printf '%s' "$de_span" | grep -Eq 'loss=[^[:space:]]*[0-9]'; then printf 'unquantified\n'; return 1; fi
      if ! printf '%s' "$de_span" | grep -Eqi '(of|out of|vs\.?|versus)[[:space:]]+[^[:space:]]*[0-9]'; then
        printf 'unquantified\n'; return 1
      fi ;;
    *) return 0 ;;
  esac
  # The citation RESOLUTION shared by the two citing grounds. EMPTY de_root is documented behaviour, not a gap:
  # with no root the check is citation-SHAPE only, exactly like _uncited_dismissal_lines's empty repo_dir.
  if [ -n "$de_need" ] && [ -n "$de_root" ]; then
    de_f="${de_cite%%:*}"
    # An absolute path or a `..` segment is refused outright rather than normalised: no file outside the one
    # root the caller owns is ever opened.
    case "$de_f" in /*|*..*) printf 'cite-unresolved\n'; return 1 ;; esac
    [ -f "$de_root/$de_f" ] || { printf 'cite-unresolved\n'; return 1; }
    de_r="${de_cite#*:}"
    case "$de_r" in *-*) de_a="${de_r%-*}"; de_b="${de_r#*-}" ;; *) de_a="$de_r"; de_b="$de_r" ;; esac
    if ! sed -n "${de_a},${de_b}p" "$de_root/$de_f" 2>/dev/null | grep -Eq "$de_need"; then
      printf '%s\n' "$de_failid"; return 1
    fi
  fi
  # ADMITTED IS NOT DEPLOYED — the veto that applies to EVERY sufficient ground. Deployed-state evidence
  # establishes what one deployment holds today; a ground answers what the code ADMITS. So such a line closes
  # nothing unless it ALSO carries a validating citation that rejects the other admitted states.
  if printf '%s' "$de_span" | grep -Eqi "$de_admit_re"; then
    de_vok=0
    for de_c in $(printf '%s' "$de_span" | grep -oE "$de_pathline_re"); do
      de_vf="${de_c%%:*}"
      case "$de_vf" in /*|*..*) continue ;; esac
      printf '%s' "$de_vf" | grep -Eq "$de_deploy_re" && continue
      if [ -z "$de_root" ]; then de_vok=1; break; fi
      [ -f "$de_root/$de_vf" ] || continue
      de_vr="${de_c#*:}"
      case "$de_vr" in *-*) de_va="${de_vr%-*}"; de_vb="${de_vr#*-}" ;; *) de_va="$de_vr"; de_vb="$de_vr" ;; esac
      if sed -n "${de_va},${de_vb}p" "$de_root/$de_vf" 2>/dev/null | grep -Eq "$de_valid_re"; then de_vok=1; break; fi
    done
    [ "$de_vok" -eq 1 ] || { printf 'admitted-vs-deployed\n'; return 1; }
  fi
  return 0
}

# _contract_requirement <contract-id> — BYTE-IDENTICAL to run-discovery.sh's table, for the same reason: the
# re-ask can never ask for something the prompt never defined, and the demo pins the two literal tokens
# (`delta=0:`, `loss=`) against the agents' ground_evidence_block() in BOTH directions.
_contract_requirement() {
  case "$1" in
    cite-missing)            printf '%s\n' 'cite the path:line this ground requires, in code you were given' ;;
    cite-unresolved)         printf '%s\n' 'the cited path:line is not in the code you were given' ;;
    cite-not-a-guard)        printf '%s\n' 'the cited line is not a check — cite the conditional or the require/revert that stops the path' ;;
    cite-not-validating)     printf '%s\n' 'cite the constructor/initializer/setter line that REJECTS the state, never a deployment script or a deployed value' ;;
    no-zero-delta)           printf '%s\n' 'write the literal token delta=0:<the quantity that is unchanged> beside the path' ;;
    reachability-as-no-loss) printf '%s\n' 'a "that state never occurs" argument is the unreachable ground, not no-loss — cite the line that validates the state away' ;;
    unquantified)            printf '%s\n' 'write the literal token loss=<amount> <unit> and compare it with a second number in the same units' ;;
    admitted-vs-deployed)    printf '%s\n' 'deployed state is not what the code ADMITS — cite the validating line that rejects every other admitted state' ;;
    *)                       printf '%s\n' 'name a sufficient ground with the evidence that ground requires' ;;
  esac
}

# _refute_ground_contract <log> [root] [brief] — the contract id this candidate's `REFUTE-GROUND|` record FAILS,
# or nothing (pass / unarmed / no record). It rebuilds the hunt-side shape `DISMISS|<loc>|<ground>|<evidence>`
# from the scraped record so both gates run literally the same decider over literally the same field layout.
#
# The root is the caller's `--code-dir`, which verify-findings.sh already sets to the target repository, so the
# refuter's citations resolve against the real tree with real line numbers. A standalone run pointed at a
# non-repo code dir degrades to citation-SHAPE only — documented behaviour, never a failure, exactly like
# _uncited_dismissal_lines's empty repo_dir on the hunt side.
_refute_ground_contract() {
  rgc_log="$1"; rgc_root="${2:-}"; rgc_brief="${3:-}"
  [ -f "$rgc_log" ] || return 0
  _ground_contract_armed "$rgc_log" || return 0
  rgc_rec="$(_join_wrapped_ground "$rgc_log" 2>/dev/null || true)"
  [ -n "$rgc_rec" ] || return 0
  rgc_rec="$(printf '%s' "$rgc_rec" | sed 's/^.*\(REFUTE-GROUND|\)/\1/')"
  rgc_g="$(printf '%s' "$rgc_rec" | cut -d'|' -f2)"
  rgc_ev="$(printf '%s' "$rgc_rec" | cut -d'|' -f3-)"
  rgc_id=""
  if rgc_id="$(_dismiss_evidence_ok "DISMISS|verdict|$rgc_g|$rgc_ev" "$rgc_root" "$rgc_brief")"; then
    return 0
  fi
  printf '%s\n' "${rgc_id:-unknown}"
}

# _scraped_ground <log> — the ground id of the last `REFUTE-GROUND|` record, trimmed and lowercased, or empty.
_scraped_ground() {
  sg_line="$(_join_wrapped_ground "$1" 2>/dev/null || true)"
  [ -n "$sg_line" ] || return 0
  printf '%s' "$sg_line" | sed 's/^.*\(REFUTE-GROUND|\)/\1/' | cut -d'|' -f2 \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]'
}

# _ground_insufficient <ground> — true when <ground> is NOT on the closed sufficient list (which covers empty,
# unrecognised and every INSUFFICIENT id in one predicate — the rubric's own rule, not a second opinion).
_ground_insufficient() {
  gi_want="$1"
  [ -n "$gi_want" ] || return 0
  for gi_ok in $(_rubric_sufficient_grounds); do
    [ "$gi_want" = "$gi_ok" ] && return 1
  done
  return 0
}

# _rubric_gate_armed <log> — the gate fires ONLY when the agent's own honesty-gated `SEVERITY-RUBRIC|` sentinel
# is in this candidate's log, never on the env var: with the knob off (the default) there is no sentinel, so the
# whole gate is inert by construction and no candidate can be re-asked, re-worded or side-filed.
_rubric_gate_armed() {
  grep -qE '^[[:space:]]*SEVERITY-RUBRIC\|' "$1" 2>/dev/null
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
  # #2245 iteration 2: the insufficient ground the bounded re-ask names. EMPTY on the first call of every
  # candidate, so that prompt is byte-identical to the pre-#2245 one whatever the knob says.
  RUBRIC_GROUNDS=""
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
        SEVERITY_RUBRIC="${SEVERITY_RUBRIC:-}" \
        RUBRIC_REASK_GROUNDS="$RUBRIC_GROUNDS" \
        GROUND_EVIDENCE="${GROUND_EVIDENCE:-}" \
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

  # #2245 iteration 2 — THE DISMISSAL-GROUND GATE. A REFUTED verdict whose named ground is missing, empty,
  # unrecognised or one of the four INSUFFICIENT ids is a verdict that has not been justified under the rubric
  # the agent was just handed, so it gets ONE more full hostile read (DF_RUBRIC_MAX_REASKS, default 1) with the
  # open ground NAMED through RUBRIC_REASK_GROUNDS. Structurally the #1699 C6 fallback — the precedent for "at
  # most one extra sequential call per candidate" — and it runs BEFORE that fallback so the two cannot stack
  # their budgets on one candidate. It reuses _rf_attempt, which is what guarantees the re-ask carries the SAME
  # appendix / brief / invariant env (the easy miss the C6 block documents).
  #
  # AFTER A FAILED RE-ASK THE VERDICT COLUMN STAYS `REFUTED` (issue #2245 STOP-1 decision 1). verify-findings.sh
  # matches the verdict cell against the exact vocabulary `REAL|REFUTED|ERROR`, so a fifth token would be read as
  # "no verdict row" and the candidate silently dropped; and escalating to REAL would make the pre-registered
  # measurement mechanically reachable rather than a test of the gate's own judgement. The outcome is made
  # LEGIBLE instead: the reason is prefixed `rubric-insufficient: ` and one row lands in rubric-dismissals.tsv.
  RUBRIC_INSUFFICIENT=""
  RUBRIC_CONTRACT=""
  RUBRIC_RECOVERED=0
  if [ "$VERD" = "REFUTED" ] && _rubric_gate_armed "$CELL_LOG"; then
    RB_GROUND="$(_scraped_ground "$CELL_LOG")"
    # #2245 iteration 3: a SUFFICIENT ground id whose evidence fails that ground's contract is treated exactly
    # like an insufficient id — the same gate, the same one bounded re-ask, the same outcomes. RB_CONTRACT is
    # always empty when the ground id itself was insufficient (there is nothing to check yet) and on every
    # contract-OFF run (no `GROUND-EVIDENCE|` sentinel => _refute_ground_contract prints nothing), so this
    # branch reproduces the iteration-2 behaviour exactly there.
    RB_CONTRACT=""
    if ! _ground_insufficient "$RB_GROUND"; then
      RB_CONTRACT="$(_refute_ground_contract "$CELL_LOG" "$CODE_DIR" "$BRIEF_IN_RUN")"
    fi
    if _ground_insufficient "$RB_GROUND" || [ -n "$RB_CONTRACT" ]; then
      RB_TRY=1
      while [ "$RB_TRY" -le "$DF_RUBRIC_MAX_REASKS" ] && [ "$VERD" = "REFUTED" ]; do
        # The re-ask NAMES what is open: the bare ground id when the id itself was insufficient, and
        # `<ground>: <requirement>` when the id was accepted but its evidence was not.
        RUBRIC_GROUNDS="${RB_GROUND:-none given}"
        if [ -n "$RB_CONTRACT" ]; then
          RUBRIC_GROUNDS="$RUBRIC_GROUNDS: $(_contract_requirement "$RB_CONTRACT")"
        fi
        RB_LOG="$RUN/refute_${SLUG}_rubric$RB_TRY.log"
        echo "run-refute.sh: $CFN refuted on the insufficient ground '$RUBRIC_GROUNDS'; re-asking under the severity rubric ($RB_TRY/$DF_RUBRIC_MAX_REASKS) ..." >&2
        if df_run_agent_validated "$DF_AGENT_MAX_ATTEMPTS" "run-refute.sh: '$CFN' (rubric re-ask $RB_TRY)" "$RB_LOG" refuter "" _rf_attempt; then
          RB_VLINE="$(_join_wrapped_verdict "$RB_LOG" || true)"
          if [ -n "$RB_VLINE" ]; then
            RB_V="$(printf '%s' "$RB_VLINE" | sed 's/^.*\(VERDICT|\)/\1/')"
            RB_VERD="$(printf '%s' "$RB_V" | cut -d'|' -f2)"
            RB_REASON="$(_clean_reason "$(printf '%s' "$RB_V" | cut -d'|' -f5-)")"
            if [ "$RB_VERD" = "REAL" ]; then
              VERD="REAL" ; RUBRIC_RECOVERED=1
              REASON="recovered under the severity rubric (first read refuted on '$RUBRIC_GROUNDS'): $RB_REASON"
            else
              RB_GROUND="$(_scraped_ground "$RB_LOG")"
              RB_CONTRACT=""
              if ! _ground_insufficient "$RB_GROUND"; then
                RB_CONTRACT="$(_refute_ground_contract "$RB_LOG" "$CODE_DIR" "$BRIEF_IN_RUN")"
              fi
              REASON="$RB_REASON"
              if ! _ground_insufficient "$RB_GROUND" && [ -z "$RB_CONTRACT" ]; then break; fi
            fi
          fi
        fi
        RB_TRY=$((RB_TRY + 1))
      done
      RUBRIC_GROUNDS=""
      if [ "$VERD" = "REFUTED" ] && { _ground_insufficient "$RB_GROUND" || [ -n "$RB_CONTRACT" ]; }; then
        RUBRIC_INSUFFICIENT="${RB_GROUND:-none given}"
        RUBRIC_CONTRACT="$RB_CONTRACT"
        REASON="rubric-insufficient: $REASON"
      fi
    fi
  fi

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
  # #2245 iteration 2: a candidate the rubric re-ask CONVERTED to REAL contributes nothing either, for exactly
  # the reason the C6 recovery does not — the gate's own second read overturned the standard the first one
  # applied, so teaching that standard forward would teach a mistake.
  if [ "$VERD" = "REFUTED" ] && [ -n "$CONSTRAINT" ] && [ "$RUBRIC_RECOVERED" -eq 0 ]; then
    printf '%s\t%s\t%s\n' "$ROW_CLS" "$CFN" "$CONSTRAINT" >> "$CONSTRAINTS"
  fi
  # #2245 iteration 2: the insufficient-ground sidecar row (lazy file creation — see RUBRIC_TSV above).
  if [ -n "$RUBRIC_INSUFFICIENT" ]; then
    RUBRIC_NOTE=""
    if [ -n "$RUBRIC_CONTRACT" ]; then RUBRIC_NOTE=", evidence contract $RUBRIC_CONTRACT"; fi
    echo "run-refute.sh: $CFN held an INSUFFICIENT ground ($RUBRIC_INSUFFICIENT$RUBRIC_NOTE) through the rubric re-ask — verdict stays REFUTED, row recorded in rubric-dismissals.tsv" >&2
    printf '%s\t%s\t%s\t%s\t%s\n' "$ROW_CLS" "$CFN" "$RUBRIC_INSUFFICIENT" "$REASON" "$RUBRIC_CONTRACT" >> "$RUBRIC_TSV"
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
