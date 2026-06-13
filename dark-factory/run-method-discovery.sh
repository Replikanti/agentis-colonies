#!/usr/bin/env bash
# Method-discovery meta-loop: INVENT -> VALIDATE-on-known-bug-control -> ADOPT.
#
# The federation's self-improvement layer. When the current method-set plateaus, the
# method-inventor proposes a NEW method; it is adopted into the registry ONLY if it
# DISCRIMINATES on a known-bug control corpus: it must catch the planted bug (Buggy suite
# FAILS) AND stay clean on the paired safe twin (Safe suite PASSES). That two-sided gate
# is what makes method invention empirical rather than speculation.
#
# Usage: ./run-method-discovery.sh [control-corpus-dir]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="${REGISTRY:-$HERE/auditor/methods/registry.md}"
GAP="${GAP:-$HERE/auditor/methods/gap-stateful.md}"
CORPUS="${1:-${CORPUS:-/tmp/mdctl}}"
MODEL="${MODEL:-claude-opus-4-8}"
INVENTOR="$HERE/auditor/agents/method-inventor.ag"
FORGE="${FORGE:-$HOME/.foundry/bin/forge}"

echo "== method-discovery: INVENT -> VALIDATE -> ADOPT =="
echo "registry=$REGISTRY  gap=$GAP  corpus=$CORPUS"

# --- 1. INVENT (substrate-native by default; direct-LLM only as a fallback) --
proposal=""
if [ -z "${NO_AGENTIS:-}" ] && command -v agentis >/dev/null 2>&1; then
  # Substrate-native path: mirror run-discovery.sh's hunter invocation
  # (`agentis go ... --enable-exec --enable-messaging`). The sandboxed `exec sh`
  # CANNOT read files under $HOME, so the registry/gap are copied into the /tmp
  # rundir (sandbox-readable) and the agent reads those local copies — same
  # reason run-discovery copies slice-fns.sh into $RUN and clones the target to /tmp.
  rd="$(mktemp -d)"; cp "$INVENTOR" "$rd/method-inventor.ag"
  cp "$REGISTRY" "$rd/registry.md"; cp "$GAP" "$rd/gap.md"
  ( cd "$rd" && agentis init >/dev/null 2>&1
    { echo "llm.backend = claude"; echo "llm.command = claude"; echo "llm.args = -p --model $MODEL"
      echo "exec.env_passthrough = REGISTRY,GAP"; echo "llm.cli_timeout_ms = 300000"; echo "exec.default_timeout_ms = 30000"; } >> .agentis/config
    REGISTRY="$rd/registry.md" GAP="$rd/gap.md" agentis go method-inventor.ag --enable-exec --enable-messaging ) > "$rd/out" 2>"$rd/err"
  proposal="$(grep -m1 '^METHOD|' "$rd/out" 2>/dev/null || true)"
  if [ -n "$proposal" ]; then echo "[invent] via agentis go (substrate-native)"; else echo "[invent] agentis go produced no METHOD| line (see $rd/err); falling back" >&2; fi
fi
if [ -z "$proposal" ]; then
  # direct-LLM fallback (same reasoning the .ag prompt() performs)
  pr="$(printf 'You are the METHOD-INVENTOR for an autonomous smart-contract audit federation.\n\nCurrent methods:\n%s\n\nGAP (a bug class the current methods keep MISSING):\n%s\n\nPropose EXACTLY ONE new, distinct, concretely-runnable audit method that catches this class. Reason briefly then output EXACTLY one final line:\nMETHOD|<name>|<bug-classes>|<one-sentence technique>|<how-to-invoke>|<what a known-bug control asserts>' "$(cat "$REGISTRY")" "$(cat "$GAP")")"
  proposal="$(claude -p --model "$MODEL" "$pr" 2>/dev/null | grep -m1 '^METHOD|' || true)"
  [ -n "$proposal" ] && echo "[invent] via direct LLM fallback"
fi
[ -z "$proposal" ] && { echo "FAIL: inventor produced no METHOD| line"; exit 1; }
name="$(printf '%s' "$proposal" | cut -d'|' -f2)"
echo "INVENTED: $proposal"

# --- 2. VALIDATE on the known-bug control corpus (two-sided gate) -----------
echo "== validate '$name' on control corpus =="
buggy="$(cd "$CORPUS" && "$FORGE" test --match-contract BuggyInvariantTest 2>&1)"
safe="$(cd "$CORPUS"  && "$FORGE" test --match-contract SafeInvariantTest  2>&1)"
caught=0; clean=0
printf '%s' "$buggy" | grep -q 'Suite result: FAILED' && caught=1
printf '%s' "$safe"  | grep -q 'Suite result: ok'     && clean=1
echo "   buggy-control caught (suite FAILED): $caught   safe-twin clean (suite ok): $clean"

# --- 3. ADOPT (only on two-sided discrimination) ----------------------------
if [ "$caught" = 1 ] && [ "$clean" = 1 ]; then
  if ! grep -q "^METHOD|$name|" "$REGISTRY"; then
    printf 'METHOD|%s|invented|0.50\n' "$(printf '%s' "$proposal" | sed 's/^METHOD|//')" >> "$REGISTRY"
    echo "ADOPTED: '$name' appended to registry (status=invented, fitness=0.50)"
  else
    echo "ADOPTED: '$name' already present in registry"
  fi
  echo "== method-discovery OK: invented + validated + adopted '$name' =="
  exit 0
else
  echo "REJECTED: '$name' did not discriminate on the control corpus (no adoption)"
  exit 2
fi
