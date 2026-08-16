#!/usr/bin/env bash
# demo-invariant-multi-target.sh — proof of the #1726 (M2) MULTI-CONTRACT deep-hunt wiring on run-zone-hunt.sh.
#
# The composable-fresh multi-contract engine already ships end-to-end (run-invariant-hunt.sh --aux -> INV_AUX ->
# invariant-prover.ag compose_fresh_seed -> multi-register targetContracts() -> the #1077 both-real HARNESS_ERROR
# enforcement); it was simply never REACHED from the autonomous deep-hunt path, because run-zone-hunt.sh STAGE 4.5
# picks ONE target per zone and drops the co-custody contracts. #1726 M2 is confined to run-zone-hunt.sh: a new
# --deep-hunt-aux-max <N> flag (default 0 = OFF = byte-identical) threads a value-custody zone's SECONDARY
# co-custody .sol into the deep-hunt as --aux, REUSING the already-safety-gated engine verbatim (zero .ag / gate
# change).
#
# This is a SOURCE-GUARD demo (always CI-safe, no toolchain, no agentis, no forge, no LLM). It asserts:
#   (1) the --deep-hunt-aux-max flag, its integer validation, and the DEFAULT-0 wiring on run-zone-hunt.sh;
#   (2) STAGE 4.5 emits the AUXFILES column ONLY when aux-max > 0, and both $INVHUNT invocations build --aux from
#       it, with the aux-max=0 path byte-identical to single-target;
#   (3) M2 REUSED — did not modify — the safety-gated composable-fresh + #1077 both-real + #1471 link_args path in
#       invariant-prover.ag / run-invariant-hunt.sh (the strings are all still present);
#   (4) #1926 the composable-fresh harness imports the target AND every aux from their REAL in-repo sources
#       (GLOBAL imports of `../src/<Name>.sol`), via the 3-field @@F@@ INV_AUX encoding — not the slim staged copies.
#
# Usage:  dark-factory/demo-invariant-multi-target.sh
# Exit: 0 = all assertions hold ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ZONEHUNT="$HERE/run-zone-hunt.sh"
INVHUNT="$HERE/run-invariant-hunt.sh"
PROVER="$HERE/auditor/agents/invariant-prover.ag"

FAILS=0
note() { echo "demo-invariant-multi-target.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -f "$ZONEHUNT" ] || { note "run-zone-hunt.sh not found: $ZONEHUNT" >&2; exit 3; }
[ -f "$INVHUNT" ]  || { note "run-invariant-hunt.sh not found: $INVHUNT" >&2; exit 3; }
[ -f "$PROVER" ]   || { note "prover not found: $PROVER" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) FLAG + DEFAULT — run-zone-hunt.sh gains --deep-hunt-aux-max, integer-validated, defaulting to 0 (= OFF).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1726 (M2) --deep-hunt-aux-max flag + default ..."

if grep -q -- '--deep-hunt-aux-max) nv "$#"; DEEP_HUNT_AUX_MAX="$2"; shift 2 ;;' "$ZONEHUNT"; then
  ok "the --deep-hunt-aux-max flag is parsed"
else
  bad "the --deep-hunt-aux-max flag is not parsed"
fi

if grep -q 'DEEP_HUNT_AUX_MAX=0' "$ZONEHUNT"; then
  ok "DEEP_HUNT_AUX_MAX defaults to 0 (OFF = byte-identical single-target)"
else
  bad "DEEP_HUNT_AUX_MAX default (0) missing"
fi

if grep -q 'case "$DEEP_HUNT_AUX_MAX" in ' "$ZONEHUNT" \
   && grep -q 'must be a non-negative integer' "$ZONEHUNT"; then
  ok "--deep-hunt-aux-max is integer-validated (case ''|*[!0-9]* -> exit 2)"
else
  bad "--deep-hunt-aux-max integer validation missing"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) STAGE 4.5 ENUMERATION + INVOCATION — the AUXFILES column is emitted ONLY when aux-max > 0 (byte-identical
#    3-column row otherwise), the read loop gains the 4th field, and both $INVHUNT invocations build --aux args.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1726 (M2) STAGE 4.5 enumeration + invocation wiring ..."

if grep -q 'repo, max_targets, aux_max = sys.argv\[2\], int(sys.argv\[3\]), int(sys.argv\[4\])' "$ZONEHUNT"; then
  ok "STAGE 4.5 threads --deep-hunt-aux-max into the enumeration heredoc"
else
  bad "STAGE 4.5 does not thread the aux-max into the enumeration"
fi

if grep -q 'if aux_max > 0:' "$ZONEHUNT" \
   && grep -q 'print("%s\\t%s\\t%s\\t%s" % (zid.replace("\\t", " "), rel.replace("\\t", " "), dclass, auxcol))' "$ZONEHUNT" \
   && grep -q 'print("%s\\t%s\\t%s" % (zid.replace("\\t", " "), rel.replace("\\t", " "), dclass))' "$ZONEHUNT"; then
  ok "STAGE 4.5 emits the 4th AUXFILES column ONLY when aux_max > 0 (else a byte-identical 3-column row)"
else
  bad "STAGE 4.5 aux-column emission is not gated byte-identically on aux_max > 0"
fi

if grep -q "while IFS='	' read -r ZID RELFILE DCLASS AUXFILES" "$ZONEHUNT"; then
  ok "the deep-hunt read loop gains the 4th AUXFILES field"
else
  bad "the deep-hunt read loop does not read the 4th AUXFILES field"
fi

if grep -q 'for _auxrel in $AUXFILES; do' "$ZONEHUNT" \
   && grep -q 'set -- "$@" --aux "$_auxrel"' "$ZONEHUNT"; then
  ok "each comma-item of AUXFILES becomes a distinct --aux <rel> argv element"
else
  bad "AUXFILES is not split into distinct --aux argv elements"
fi

if [ "$(grep -c 'repair-rounds "$DEEP_HUNT_REPAIR_ROUNDS" "$@"' "$ZONEHUNT")" -eq 2 ]; then
  ok "BOTH \$INVHUNT invocations (fixture + live) append the built --aux args (\"\$@\")"
else
  bad "the built --aux args are not appended to both \$INVHUNT invocations"
fi

# The default-0 byte-identical guard: with no AUXFILES the arg list is emptied (set --) and only rebuilt when
# AUXFILES is non-empty, so an empty column yields a byte-identical invocation.
if grep -q '^      set --$' "$ZONEHUNT" \
   && grep -q 'if \[ -n "${AUXFILES:-}" \]; then' "$ZONEHUNT"; then
  ok "the aux-max=0 byte-identical guard is present (empty AUXFILES => no --aux => unchanged invocation)"
else
  bad "the aux-max=0 byte-identical guard is missing"
fi

# ----------------------------------------------------------------------------------------------------------
# 3) REUSED-NOT-MODIFIED — the safety-gated composable-fresh engine M2 threads into is byte-present in
#    invariant-prover.ag / run-invariant-hunt.sh. M2 added ZERO .ag / gate code; it only REACHES this path.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that #1726 (M2) REUSED — did not modify — the composable-fresh + #1077 + #1471 path ..."

if grep -q 'fn compose_fresh_seed(active: bool) -> string' "$PROVER" \
   && grep -q 'fn aux_entries(aux: string) -> list<string>' "$PROVER" \
   && grep -q 'regex_split("@@A@@", aux)' "$PROVER"; then
  ok "invariant-prover.ag still carries compose_fresh_seed + the INV_AUX/@@A@@ split (aux_entries)"
else
  bad "the composable-fresh multi-contract seed / INV_AUX split is missing from invariant-prover.ag"
fi

if grep -q 'requiredNames' "$PROVER" \
   && grep -q 'fn missing_real_deploys(testSrc: string, names: list<string>) -> string' "$PROVER" \
   && grep -q 'if violated { return "HARNESS_ERROR"; }' "$PROVER"; then
  ok "the #1077 both-real enforcement (requiredNames + missing_real_deploys + final_verdict override) is intact"
else
  bad "the #1077 both-real HARNESS_ERROR enforcement is missing from invariant-prover.ag"
fi

if grep -q 'fn link_args(' "$PROVER" \
   && grep -q -- '--require-import' "$PROVER" && grep -q -- '--require-contract' "$PROVER"; then
  ok "the #1471 link_args --require-import/--require-contract linkage gate is intact (fires on the PRIMARY target)"
else
  bad "the #1471 link_args linkage gate is missing from invariant-prover.ag"
fi

if grep -q -- '--aux) need "$#"; AUX_SPECS+=("$2"); shift 2 ;;' "$INVHUNT" \
   && grep -q 'INV_AUX' "$INVHUNT"; then
  ok "run-invariant-hunt.sh still exposes --aux and stages/passes INV_AUX (the reused engine entrypoint)"
else
  bad "run-invariant-hunt.sh --aux / INV_AUX staging is missing (engine entrypoint regressed)"
fi

if grep -q 'exec.env_passthrough = TARGET_FN,TARGET_CLASS,INV_REPO,INV_OUT,INV_MATCH,HANDLER_FIXTURE,CODE_PATH,INV_RUNS,INV_DEPTH,INV_SEED,FORGE_INVARIANT,FORK_URL,FORK_BLOCK,FORK_TARGET,FORK_CONTEXT,INV_REPAIR_ROUNDS,INV_AUX,INV_AUDIT_CONTEXT' "$INVHUNT"; then
  ok "run-invariant-hunt.sh's exec.env_passthrough allowlist (incl. INV_AUX) is unchanged — no new env surface"
else
  bad "run-invariant-hunt.sh's exec.env_passthrough allowlist changed unexpectedly"
fi

# ----------------------------------------------------------------------------------------------------------
# 4) #1926 SOURCE-IMPORT FIX — the composable-fresh harness imports the target AND every aux from their REAL
#    in-repo sources (GLOBAL imports of the compilable `../src/<Name>.sol`), not the slimmed staged flat copies
#    (`../../target-code.sol` / `aux-code-<n>.sol`, which are dependency-stripped and do not compile). These
#    pin the staging/import-bug fix that flips composable-fresh / complex targets from HARNESS_ERROR to a verdict.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1926 composable-fresh real-src import fix ..."

if grep -q 'fn global_import_line(rel: string) -> string' "$PROVER" \
   && grep -q 'let auxSrcAbs = resolve_in_repo_src(invRepo, aux_field(entry, 2))' "$PROVER"; then
  ok "invariant-prover.ag aux import reduce resolves each aux from its REAL in-repo src (global_import_line)"
else
  bad "the #1926 aux real-src import (resolve_in_repo_src(invRepo, aux_field(entry, 2)) + global_import_line) is missing"
fi

if grep -q 'global_import_line(targetInRepoRel)' "$PROVER"; then
  ok "invariant-prover.ag composable-fresh target import uses global_import_line(targetInRepoRel)"
else
  bad "the #1926 composable-fresh target import (global_import_line(targetInRepoRel)) is missing"
fi

if grep -q '_aentry="$_aux_in_run@@F@@$_aname@@F@@${AUX_REL_FILES\[$_aux_idx\]}"' "$INVHUNT"; then
  ok "run-invariant-hunt.sh emits the #1926 3-field @@F@@ INV_AUX entry (staged slim / Name / real repo file)"
else
  bad "run-invariant-hunt.sh's #1926 3-field @@F@@ INV_AUX entry encoding is missing"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: #1726 (M2) multi-contract deep-hunt wiring is confined to run-zone-hunt.sh — --deep-hunt-aux-max"
  note "      (default 0 = OFF = byte-identical) threads a zone's SECONDARY co-custody .sol as --aux, REUSING the"
  note "      shipped composable-fresh engine (INV_AUX -> compose_fresh_seed -> targetContracts() -> #1077"
  note "      both-real) verbatim; the #1471 linkage gate + both-real HARNESS_ERROR safety are unchanged."
  exit 0
fi
note "DEMO FAILED — a #1726 (M2) multi-contract deep-hunt wiring assertion did not hold" >&2
exit 1
