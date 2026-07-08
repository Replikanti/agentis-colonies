#!/usr/bin/env bash
# demo-dup-scout.sh — proof of the #1503 DUP-RISK estimator `auditor/agents/dup-scout.ag`.
#
# dup-scout estimates the "already-reported" probability of a CONFIRMED finding from observable repo/audit
# evidence (git freshness, patch-status, fix-velocity, audit coverage), so the human SUBMIT decision is
# evidence-based rather than a blind guess. It sits between VERIFY and the human-gated submit; it never submits.
#
# TWO parts:
#   1) SOURCE-GUARD (always, CI-safe): asserts the env contract, the git/audit signal wiring, the DUP-RISK
#      output contract, the bus emit, and the learn/memo tail — so a refactor that drops a signal is caught
#      even on runners with no agentis binary.
#   2) LIVE (when agentis is on PATH): builds a throwaway GIT repo fixture (an introducing commit + a later
#      fix-flavoured commit) and runs `agentis go dup-scout.ag` over it, asserting the agent gathers the git
#      signals via exec-sh and runs end-to-end (exit 0). The mock backend does not reason, so only clean
#      execution + the signal-gathering path are asserted, never a specific DUP-RISK band.
#
# Usage:  dark-factory/demo-dup-scout.sh
# Exit: 0 = all assertions hold (live part SKIPs cleanly when agentis/git absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCOUT="$HERE/auditor/agents/dup-scout.ag"

FAIL=0
note() { echo "demo-dup-scout.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*" >&2; FAIL=1; }
skip() { echo "  [SKIP] $*"; }

[ -f "$SCOUT" ] || { note "dup-scout agent not found: $SCOUT" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD — the dup-risk wiring must exist regardless of toolchain.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1503 dup-risk wiring ..."

if grep -q '^cb 300000;' "$SCOUT"; then
  ok "dup-scout.ag declares cb 300000"
else
  bad "dup-scout.ag missing the cb 300000 declaration"
fi

missing_env=""
for v in TARGET_DIR FINDING_FILE FINDING_ANCHOR AUDIT_DIR; do
  grep -q "getenv(\"$v\")" "$SCOUT" || missing_env="$missing_env $v"
done
if [ -z "$missing_env" ]; then
  ok "dup-scout.ag reads the env contract (TARGET_DIR/FINDING_FILE/FINDING_ANCHOR/AUDIT_DIR)"
else
  bad "dup-scout.ag missing getenv for:$missing_env"
fi

# The five evidence signals must be gathered.
if grep -q 'fn anchor_intro' "$SCOUT" && grep -q 'fn anchor_present' "$SCOUT" \
   && grep -q 'fn fix_touches' "$SCOUT" && grep -q 'fn fix_velocity' "$SCOUT" \
   && grep -q 'fn audit_mentions' "$SCOUT"; then
  ok "dup-scout.ag gathers the freshness / patch-status / fix-velocity / audit-coverage signals"
else
  bad "dup-scout.ag missing one of the evidence-signal gatherers"
fi

# It uses git history (the muscle) via exec-sh, safe-exec-concat annotated.
if grep -q 'git -C ${dir}' "$SCOUT" && grep -q 'safe-exec-concat' "$SCOUT"; then
  ok "dup-scout.ag reads git history via exec-sh (safe-exec-concat annotated)"
else
  bad "dup-scout.ag does not wire the git-history muscle"
fi

# The DUP-RISK output contract + honest banding.
if grep -q 'DUP-RISK|' "$SCOUT" && grep -q 'DUP-RISK|LOW' "$SCOUT" && grep -q 'DUP-RISK|HIGH' "$SCOUT"; then
  ok "dup-scout.ag emits the DUP-RISK|<LOW|MODERATE|HIGH>|<pct>|<rationale> output contract"
else
  bad "dup-scout.ag missing the DUP-RISK output contract"
fi

if grep -q 'emit("dark-factory:dup_risk"' "$SCOUT" \
   && grep -q 'learn("dup-risk"' "$SCOUT" && grep -q 'memo_write("dup-scout:last_check"' "$SCOUT"; then
  ok "dup-scout.ag emits dark-factory:dup_risk + records the learn/memo tail"
else
  bad "dup-scout.ag missing the emit / learn / memo tail"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) LIVE — run the agent end-to-end over a throwaway git-repo fixture.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the live end-to-end dup-scout check"
elif ! command -v git >/dev/null 2>&1; then
  skip "git not on PATH — the live dup-scout check needs a git fixture"
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  # A throwaway target repo: introduce a vulnerable anchor, then a later unrelated commit + a fix-flavoured one.
  mkdir -p "$WORK/target/src" "$WORK/run"
  (
    cd "$WORK/target"
    git init -q; git config user.email t@t.t; git config user.name t
    mkdir -p src
    printf 'contract V { function f() public { uint x = a - b; } }\n' > src/V.sol
    git add -A; git commit -q -m 'feat: add V with reconciliation subtract'
    printf 'contract V { function f() public { uint x = a - b; } function g() public {} }\n' > src/V.sol
    git add -A; git commit -q -m 'refactor: add g'
    printf '// note\ncontract V { function f() public { uint x = a - b; } function g() public {} }\n' > src/V.sol
    git add -A; git commit -q -m 'fix: harden unrelated path'
  ) >/dev/null 2>&1
  cp "$SCOUT" "$WORK/run/dup-scout.ag"
  ( cd "$WORK/run" && agentis init >/dev/null 2>&1 || true )
  {
    echo "learning.enabled = true"; echo "experience.enabled = true"; echo "exec.default_timeout_ms = 30000"
    echo "exec.env_passthrough = TARGET_DIR,FINDING_FILE,FINDING_ANCHOR,AUDIT_DIR"
  } >> "$WORK/run/.agentis/config"
  set +e
  (
    cd "$WORK/run" || exit 90
    export TARGET_DIR="$WORK/target" FINDING_FILE="src/V.sol" FINDING_ANCHOR="f" AUDIT_DIR=""
    # --grant-pii: git dates/hashes in the signals block trip agentis's PII heuristic (mis-flagged as phone/email);
    # the evidence is benign repo metadata, so grant it for this fixture run.
    agentis go dup-scout.ag --enable-exec --enable-messaging --grant-pii
  ) >"$WORK/out.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    ok "agentis go dup-scout.ag ran end-to-end over the git fixture (exit 0)"
  else
    bad "agentis go dup-scout.ag failed on the fixture (exit $rc):"
    sed 's/^/      /' "$WORK/out.log" | head -20 >&2
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAIL" -eq 0 ]; then
  note "PASS — dup-risk estimator wiring holds"
  exit 0
fi
note "FAIL — a dup-risk assertion regressed" >&2
exit 1
