#!/usr/bin/env bash
# demo-invariant-audit-seed.sh — proof of the #1722 AUDIT-INFORMED invariant seeding wiring on the deep-hunt path.
#
# The #1716 A/B isolated invariant EXPRESSIVENESS (not plumbing) as the deep-hunt limit: the fuzzer is the sole
# judge, but the LLM keeps reaching for the generic per-lens conservation property auditors already check. #1722
# lets an operator supply a target's spec / audit-scope doc via `run-invariant-hunt.sh --audit-context <file>`;
# the runner stages it and threads its path as INV_AUDIT_CONTEXT; `invariant-prover.ag` reads it via the sandboxed
# cat_file and prepends a new `audit_seed()` block to the SAME generation seed chain that carries recall/fork/
# compose, steering the model to formalize a protocol-SPECIFIC value-conservation property. Purely additive: no
# --audit-context => empty seed => byte-identical prompt. The FUZZER stays the sole verdict; the INVARIANT| marker
# and the #1471 target-linkage gate are untouched.
#
# This is a SOURCE-GUARD + offline-behavioural demo (always CI-safe, no toolchain, no agentis, no forge, no LLM):
# it asserts the prover + runner wiring is present, that the seed is additive (empty-string early return), that
# the verdict/marker/linkage contract is unchanged, and — behaviourally — that an unreadable --audit-context is a
# hard usage error (exit 2) reachable OFFLINE (before any agentis/forge dependency). A refactor that drops the
# seed, un-threads INV_AUDIT_CONTEXT from either the passthrough allowlist or the env invocation, or makes the
# seed non-additive is caught here.
#
# Usage:  dark-factory/demo-invariant-audit-seed.sh
# Exit: 0 = all assertions hold ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
RUNNER="$HERE/run-invariant-hunt.sh"

FAILS=0
note() { echo "demo-invariant-audit-seed.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$PROVER" ] || { note "prover not found: $PROVER" >&2; exit 3; }
[ -f "$RUNNER" ] || { note "runner not found: $RUNNER" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) PROVER WIRING — audit_seed exists, reads INV_AUDIT_CONTEXT via cat_file, carries the seed header, and is
#    prepended into generate_test's instruction chain.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1722 prover audit_seed wiring ..."

if grep -q 'fn audit_seed(auditText: string) -> string' "$PROVER"; then
  ok "audit_seed() is defined on the prover"
else
  bad "audit_seed() missing from the prover"
fi

if grep -q 'let auditPath = getenv("INV_AUDIT_CONTEXT");' "$PROVER" \
   && grep -q 'let auditText = cat_file(auditPath);' "$PROVER"; then
  ok "the prover reads INV_AUDIT_CONTEXT via the sandboxed cat_file (same reader as CODE_PATH)"
else
  bad "the prover does not read INV_AUDIT_CONTEXT via cat_file"
fi

if grep -q 'AUDIT-INFORMED INVARIANT SEEDING' "$PROVER"; then
  ok "audit_seed carries the AUDIT-INFORMED INVARIANT SEEDING steering header"
else
  bad "audit_seed missing the AUDIT-INFORMED INVARIANT SEEDING header"
fi

if grep -q 'TARGET SPEC / AUDIT-SCOPE PROPERTIES' "$PROVER"; then
  ok "audit_seed appends the supplied spec/audit-scope doc verbatim"
else
  bad "audit_seed does not append the spec/audit-scope doc"
fi

if grep -q 'audit_seed(auditText)' "$PROVER"; then
  ok "audit_seed(auditText) is wired into generate_test's instruction chain"
else
  bad "audit_seed(auditText) not referenced in generate_test's instruction chain"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) ADDITIVE GUARD — empty context => "" => byte-identical prompt (the early-return that keeps non-audit runs
#    unchanged, exactly like recall_seed/fork_seed/compose_seed).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1722 additive (empty-context) guard ..."

if grep -q 'fn audit_seed' "$PROVER" \
   && grep -A2 'fn audit_seed' "$PROVER" | grep -q 'if len(auditText) == 0 { return ""; }'; then
  ok "audit_seed returns \"\" on empty context (non-audit runs stay byte-identical)"
else
  bad "audit_seed missing the empty-context early return (would break the additive guarantee)"
fi

# ----------------------------------------------------------------------------------------------------------
# 3) VERDICT CONTRACT UNTOUCHED — the INVARIANT| marker + the #1471 target-linkage gate strings are still there.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that the #1722 change left the verdict/marker/linkage contract intact ..."

if grep -q 'print("INVARIANT|" + targetFn + "|" + verdict);' "$PROVER"; then
  ok "the INVARIANT|<target>|<verdict> marker emission is unchanged (fuzzer stays the sole verdict)"
else
  bad "the INVARIANT| marker emission changed unexpectedly"
fi

if grep -q -- '--require-import' "$PROVER" && grep -q -- '--require-contract' "$PROVER"; then
  ok "the #1471 --require-import/--require-contract target-linkage gate strings are intact"
else
  bad "the #1471 target-linkage gate strings changed unexpectedly"
fi

# ----------------------------------------------------------------------------------------------------------
# 4) RUNNER WIRING — the --audit-context case arm, INV_AUDIT_CONTEXT on BOTH the passthrough allowlist AND the
#    env invocation (getenv reads the SANITIZED env — miss either and it's silently inert), and the staged cp.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1722 runner wiring ..."

if grep -q -- '--audit-context) need "$#"; AUDIT_CONTEXT="$2"; shift 2 ;;' "$RUNNER"; then
  ok "run-invariant-hunt.sh has the --audit-context case arm"
else
  bad "run-invariant-hunt.sh missing the --audit-context case arm"
fi

if grep -q 'exec.env_passthrough = .*INV_AUDIT_CONTEXT' "$RUNNER"; then
  ok "INV_AUDIT_CONTEXT is on the exec.env_passthrough allowlist"
else
  bad "INV_AUDIT_CONTEXT missing from the exec.env_passthrough allowlist (would be silently inert)"
fi

if grep -q 'INV_AUDIT_CONTEXT="$AUDIT_IN_RUN" \\' "$RUNNER"; then
  ok "INV_AUDIT_CONTEXT is threaded on the env invocation"
else
  bad "INV_AUDIT_CONTEXT missing from the env invocation (would be silently inert)"
fi

if grep -q 'cp "$AUDIT_CONTEXT" "$RUN/audit-context.txt"' "$RUNNER"; then
  ok "the audit-context doc is staged into the rundir (plain cp — text doc, not slimmed as Solidity)"
else
  bad "the audit-context staging cp is missing"
fi

# ----------------------------------------------------------------------------------------------------------
# 5) OFFLINE BEHAVIOURAL — an unreadable --audit-context is a hard usage error (exit 2) reachable WITHOUT
#    agentis/forge (the validation fires before the agentis-binary check).
# ----------------------------------------------------------------------------------------------------------
note "behavioural: an unreadable --audit-context errors loudly (exit 2) offline ..."

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo"
printf '%s\n' '[invariant]' 'runs = 8' > "$WORK/repo/foundry.toml"

ec=0
"$RUNNER" --repo "$WORK/repo" --target Vault.sol:Vault --audit-context "$WORK/does-not-exist.txt" --backend mock \
  >/dev/null 2>&1 || ec=$?
if [ "$ec" -eq 2 ]; then
  ok "unreadable --audit-context -> exit 2 (hard error, reachable offline before agentis/forge)"
else
  bad "unreadable --audit-context gave exit $ec (expected 2)"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: #1722 audit-informed invariant seeding is wired — audit_seed() reads INV_AUDIT_CONTEXT via cat_file"
  note "      and prepends the seed to generate_test's chain; it is additive (empty-context early return keeps"
  note "      non-audit runs byte-identical); the INVARIANT| marker + #1471 linkage gate are untouched; the runner"
  note "      threads INV_AUDIT_CONTEXT on BOTH the passthrough allowlist and the env invocation; and an unreadable"
  note "      --audit-context is a hard exit-2 usage error reachable offline. (The invariant-quality uplift is the"
  note "      LLM's; this proves the deterministic wiring.)"
  exit 0
fi
note "DEMO FAILED — a #1722 audit-seed wiring assertion did not hold" >&2
exit 1
