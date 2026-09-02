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
# agentis-core#993: pre-accept Claude Code's workspace-trust dialog for the /tmp rundir
# below, so the (hardcoded flat-cyborg) method-inventor session does not block + exit 75.
# shellcheck source=lib/ensure-claude-trust.sh
# shellcheck disable=SC1091
. "$HERE/lib/ensure-claude-trust.sh"

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
    { echo "llm.backend = flat-cyborg"; [ -n "$MODEL" ] && echo "llm.model = $MODEL"
      echo "exec.env_passthrough = REGISTRY,GAP"; echo "llm.cli_timeout_ms = 300000"; echo "exec.default_timeout_ms = 30000"; } >> .agentis/config
    # #993: trust this rundir before `agentis go` (backend is flat-cyborg) so the
    # session is not blocked on the workspace-trust dialog. Best-effort.
    df_ensure_claude_trust "$rd"
    # --grant-pii: REGISTRY/GAP method text can carry addresses/identifiers that trip the PII
    # heuristic; input is benign operator-authored method text (#1690).
    REGISTRY="$rd/registry.md" GAP="$rd/gap.md" agentis go method-inventor.ag --enable-exec --enable-messaging --grant-pii ) > "$rd/out" 2>"$rd/err"
  proposal="$(grep -m1 '^METHOD|' "$rd/out" 2>/dev/null || true)"
  if [ -n "$proposal" ]; then echo "[invent] via agentis go (substrate-native)"; else echo "[invent] agentis go produced no METHOD| line (see $rd/err); falling back" >&2; fi
fi
if [ -z "$proposal" ]; then
  # direct-LLM fallback (same reasoning the .ag prompt() performs), routed through
  # the flat-cyborg PTY wrapper so this stays on the flat-rate subscription session
  # rather than the metered `claude -p` API — same backend the substrate path above
  # uses. LLM_WRAP overrides the wrapper path. (No --model: the wrapper drives the
  # interactive claude session, which has no per-call model arg; the substrate path
  # keeps llm.model = $MODEL.)
  WRAP="${LLM_WRAP:-$HERE/flat-cyborg-claude.sh}"
  pr="$(printf 'You are the METHOD-INVENTOR for an autonomous smart-contract audit federation.\n\nCurrent methods:\n%s\n\nGAP (a bug class the current methods keep MISSING):\n%s\n\nPropose EXACTLY ONE new, distinct, concretely-runnable audit method that catches this class. Reason briefly then output EXACTLY one final line:\nMETHOD|<name>|<bug-classes>|<one-sentence technique>|<how-to-invoke>|<what a known-bug control asserts>' "$(cat "$REGISTRY")" "$(cat "$GAP")")"
  proposal="$("$WRAP" "$pr" 2>/dev/null | grep -m1 '^METHOD|' || true)"
  [ -n "$proposal" ] && echo "[invent] via direct LLM fallback (flat-cyborg)"
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
# The same-name dedupe guard below is INTENTIONAL: the registry is operator-curated, so a
# re-invented method with an existing name is a no-op rather than a duplicate row. Distinct
# near-duplicate names can still accumulate over many runs — that is left to operator pruning
# by design (the meta-loop proposes; the human curates the registry).
#
# Row shape is INTENTIONAL too: an `invented` row keeps the proposal's trailing <control-assert>
# field, so it is METHOD|name|classes|technique|invoke|<control-assert>|invented|fitness (8 fields,
# one more than a `builtin` 7-field row). That extra field is consumed by gen-agent.sh (#1000) to
# wire the method's known-bug control assertion into the generated agent's two-sided gate — see the
# `invented` shape documented in auditor/methods/registry.md. Do NOT strip it to 7 fields.
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
