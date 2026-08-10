#!/usr/bin/env bash
# demo-experience-flags.sh — regression guard for #1881 (the #1866/#1877 experience/learning flag flip).
#
# #1877 set `experience.enabled = false` (+ `learning.enabled = false`) in the per-cell `.agentis/config`
# that run-discovery.sh (the STAGE 3 hunter) and run-refute.sh (the STAGE 4 refute gate) write, on the
# premise the flags were "structurally inert". THEY ARE NOT: the hunter AND the refuter READ experience
# WITHIN a run, and agentis hard-errors `runtime error: experience not enabled` on that read when the
# feature is off. Every hunt cell then FAILED (no CANDIDATE|/SAFE sentinel after 5 attempts) and every
# refute gate ERRORED — so discovery produces 0 candidates and verify confirms 0 findings, a silent FALSE
# ZERO across the whole pipeline. CI missed it because the offline demos drive a STUB `agentis` (see
# demo-discovery-parallel.sh's `--agentis "$STUB"`) that never interprets the .ag, so the runtime read
# never fires — the textbook "gate the artifact on INPUT (config written) not OUTPUT (a real cell running)"
# trap. This demo closes that: it asserts on the OUTPUT of a REAL agentis cell.
#
# Two layers:
#   1) SOURCE GUARD (always, CI-safe): both scripts must emit `experience.enabled = true` and MUST NOT emit
#      `... = false` in their config block — a cheap tripwire that fails the flip even where agentis is absent.
#   2) LIVE MUTATION CHECK (only when `agentis` is on PATH, [SKIP] otherwise, like demo-seam-lens.sh): run ONE
#      real hunter cell and ONE real refute cell through `--backend mock` (offline, deterministic — the mock
#      LLM returns instantly, so no flat-cyborg/network) and assert neither run's log contains
#      `experience not enabled`. Flip either flag back to `false` and this run reproduces the FAILED/ERROR.
#
# Read-only, offline, never-submit. Exit 0 = guards hold (or cleanly skipped); 1 = a regression; 3 = missing script.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DISCOVERY="$HERE/run-discovery.sh"
REFUTE="$HERE/run-refute.sh"

FAILS=0
note() { echo "demo-experience-flags.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -x "$DISCOVERY" ] || { note "run-discovery.sh not found / not executable: $DISCOVERY" >&2; exit 3; }
[ -x "$REFUTE" ]    || { note "run-refute.sh not found / not executable: $REFUTE" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE GUARD (always): the flags the config block emits. `-A2` picks up the two echo lines under the
#    comment; the guard is deliberately on the emitted STRING so it fails the exact #1877 flip.
# ----------------------------------------------------------------------------------------------------------
note "1) source-guard: run-discovery.sh + run-refute.sh emit experience/learning.enabled = true (not false) ..."
guard_script() {
  s="$1"; base="$(basename "$s")"
  if grep -Eq 'echo "experience\.enabled = false"' "$s" || grep -Eq 'echo "learning\.enabled = false"' "$s"; then
    bad "$base emits experience/learning.enabled = FALSE — the #1877/#1881 regression (the .ag reads experience intra-run; false => runtime error)"
  elif grep -Eq 'echo "experience\.enabled = true"' "$s" && grep -Eq 'echo "learning\.enabled = true"' "$s"; then
    ok "$base emits experience.enabled = true + learning.enabled = true"
  else
    bad "$base does not emit an explicit experience/learning.enabled = true — the guard cannot confirm the flags are on"
  fi
}
guard_script "$DISCOVERY"
guard_script "$REFUTE"

# ----------------------------------------------------------------------------------------------------------
# 2) LIVE MUTATION CHECK (agentis-gated): a real cell must NOT hit `experience not enabled`.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the runtime to run the live hunter/refuter experience-read check"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-experience-flags.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  ERR="experience not enabled"

  # --- discovery: one real hunter cell over a throwaway target -------------------------------------------
  REPO="$WORK/target"; mkdir -p "$REPO/contracts/vault"
  printf 'contract Vault { function deposit() public {} }\n' > "$REPO/contracts/vault/Vault.sol"
  printf 'vault deposits | C1 | contracts/vault/Vault.sol\n' > "$WORK/scope.tsv"
  printf '# brief\nInvariants to break: share accounting.\nKnown issues to exclude: none.\n' > "$WORK/brief.md"
  "$DISCOVERY" --repo "$REPO" --scope "$WORK/scope.tsv" --brief "$WORK/brief.md" \
    --only "vault deposits" --classes C1 --backend mock --agentis agentis --out "$WORK/disc" \
    >"$WORK/disc.out" 2>&1 || true
  if grep -rq "$ERR" "$WORK/disc" "$WORK/disc.out" 2>/dev/null; then
    bad "run-discovery.sh hunter cell hit '$ERR' under --backend mock — the flag is off / read is broken"
    grep -rh "$ERR" "$WORK/disc" 2>/dev/null | head -2 | sed 's/^/      /' >&2
  else
    ok "run-discovery.sh hunter cell ran through the real agentis .ag with no '$ERR' (experience read OK)"
  fi

  # --- refute: one real refuter cell over a throwaway candidate ------------------------------------------
  printf 'contract Vault { function deposit() public {} }\n' > "$WORK/vault_code.sol"
  printf 'Vault.sol:deposit | C1 | Medium | anyone can drain via deposit | vault_code.sol\n' > "$WORK/cands.tsv"
  "$REFUTE" --candidates "$WORK/cands.tsv" --code-dir "$WORK" \
    --only "Vault.sol:deposit" --backend mock --agentis agentis --out "$WORK/ref" \
    >"$WORK/ref.out" 2>&1 || true
  if grep -rq "$ERR" "$WORK/ref" "$WORK/ref.out" 2>/dev/null; then
    bad "run-refute.sh refuter cell hit '$ERR' under --backend mock — the flag is off / read is broken"
    grep -rh "$ERR" "$WORK/ref" 2>/dev/null | head -2 | sed 's/^/      /' >&2
  else
    ok "run-refute.sh refuter cell ran through the real agentis .ag with no '$ERR' (experience read OK)"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the #1881 experience/learning flags hold on both hunt and refute paths"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed (see #1881)" >&2
exit 1
