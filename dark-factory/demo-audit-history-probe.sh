#!/usr/bin/env bash
# demo-audit-history-probe.sh — OFFLINE, DETERMINISTIC proof (#1609) of audit-history-probe.sh: the bounty
# `audits` field is unreliable (empty even on heavily-hardened repos); the target repo's OWN git history —
# fix-audit-N commits/branches, finding refs, auditor-firm mentions — is the real audit-density signal.
#
# Five cases, all offline:
#   1. HARDENED fixture — a throwaway `git init` repo with fix-audit-N commits, a "remaining audit fixes"
#      merge, Cantina/Sherlock finding-ref commits, and a `fix-audit-7` branch -> heavily_audited=true, a
#      density above threshold, signals.fix_audit>=2, and commits_inspected matches the fixture.
#   2. CLEAN fixture — a second `git init` repo with only mundane subjects (initial/add-feature/refactor/
#      fix-typo) -> heavily_audited=false, density==0, audit_signal_commits==0.
#   3. --bounty with no resolvable repo (addresses only, no githubUrl / github asset) -> exit 0, a [SKIP] line
#      on stderr, and NO stdout JSON.
#   4. an unreachable URL / a single-segment github ORG url -> exit 0 + [SKIP] (no real endpoint contacted).
#   5. no positional arg and no --bounty -> exit 2 (bad-args band).
#
# No network anywhere: fixtures are local `git init` repos plus an unreachable `.invalid` host. Mirrors the
# other dark-factory demo-*.sh (assert-based PASS/FAIL lines, a trap-cleaned temp dir, exit non-zero on
# failure). Dash-safe: `set -u` only, no pipefail, no `$'...'`, no arrays/[[/mapfile — runs under `sh`.
#
# Usage:  dark-factory/demo-audit-history-probe.sh
# Requires: git + python3 (the probe's floor). Exit: 0 = all assertions held; non-zero = a failure.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROBE="$HERE/audit-history-probe.sh"

FAILS=0
note() { echo "demo-audit-history-probe.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
[ -x "$PROBE" ] || { note "audit-history-probe.sh not found / not executable: $PROBE" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-audit-history-probe.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# jget: extract a field from a JSON object on stdin (deterministic, no jq dependency; the jget pattern from
# demo-immunefi-intake.sh).
jget() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get(sys.argv[1]))' "$1"; }

# ----------------------------------------------------------------------------------------------------------
# 1) HARDENED fixture: ~9 commits, two fix-audit-N commits, a "remaining audit fixes" merge subject, a
#    Cantina finding-ref commit, a Sherlock report-id commit, plus 4 mundane commits, and a fix-audit-7 branch.
# ----------------------------------------------------------------------------------------------------------
note "1) HARDENED fixture (fix-audit-N commits/branch, finding refs) ..."
HARD="$WORK/hardened"
mkdir -p "$HARD"
git -C "$HARD" init -q
git -C "$HARD" config user.email demo@example.invalid
git -C "$HARD" config user.name demo
printf 'contract Vault {}\n' > "$HARD/Vault.sol"
git -C "$HARD" add -A
git -C "$HARD" commit -qm "initial commit"
printf 'contract Vault { uint a; }\n' > "$HARD/Vault.sol"
git -C "$HARD" add -A
git -C "$HARD" commit -qm "add feature: deposit cap"
printf 'contract Vault { uint a; uint b; }\n' > "$HARD/Vault.sol"
git -C "$HARD" add -A
git -C "$HARD" commit -qm "refactor storage layout"
printf 'contract Vault { uint a; uint b; uint c; }\n' > "$HARD/Vault.sol"
git -C "$HARD" add -A
git -C "$HARD" commit -qm "fix typo in comment"
printf 'contract Vault { uint patched1; }\n' > "$HARD/Vault.sol"
git -C "$HARD" add -A
git -C "$HARD" commit -qm "fix-audit-4: reentrancy in Vault"
printf 'contract Vault { uint patched2; }\n' > "$HARD/Vault.sol"
git -C "$HARD" add -A
git -C "$HARD" commit -qm "fix-audit-5: rounding error"
printf 'contract Vault { uint patched3; }\n' > "$HARD/Vault.sol"
git -C "$HARD" add -A
git -C "$HARD" commit -qm "Merge remaining audit fixes"
printf 'contract Vault { uint patched4; }\n' > "$HARD/Vault.sol"
git -C "$HARD" add -A
git -C "$HARD" commit -qm "Cantina finding C-01: oracle staleness"
printf 'contract Vault { uint patched5; }\n' > "$HARD/Vault.sol"
git -C "$HARD" add -A
git -C "$HARD" commit -qm "Sherlock report 4821: fix withdrawal accounting"
git -C "$HARD" branch fix-audit-7

HJSON="$("$PROBE" "$HARD" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "probe exits 0 on the hardened fixture" || bad "probe exited $RC on hardened fixture (expected 0)"
[ "$(printf '%s' "$HJSON" | jget heavily_audited)" = "True" ] \
  && ok "heavily_audited==true on the hardened fixture" || bad "heavily_audited was not true: $HJSON"
HDENSITY="$(printf '%s' "$HJSON" | jget repo_audit_density)"
if [ -n "$HDENSITY" ] && [ "$HDENSITY" -ge 5 ] 2>/dev/null; then
  ok "repo_audit_density ($HDENSITY) is above the 5% threshold"
else
  bad "repo_audit_density not above threshold: $HDENSITY"
fi
FIXAUDIT_SIGNAL="$(printf '%s' "$HJSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("signals",{}).get("fix_audit"))')"
if [ -n "$FIXAUDIT_SIGNAL" ] && [ "$FIXAUDIT_SIGNAL" -ge 2 ] 2>/dev/null; then
  ok "signals.fix_audit ($FIXAUDIT_SIGNAL) >= 2"
else
  bad "signals.fix_audit not >= 2: $FIXAUDIT_SIGNAL"
fi
[ "$(printf '%s' "$HJSON" | jget commits_inspected)" = "9" ] \
  && ok "commits_inspected==9 matches the fixture" || bad "commits_inspected mismatch: $(printf '%s' "$HJSON" | jget commits_inspected)"

# ----------------------------------------------------------------------------------------------------------
# 2) CLEAN fixture: only mundane subjects, no fix-audit/finding-ref/firm/competition hits anywhere.
# ----------------------------------------------------------------------------------------------------------
note "2) CLEAN fixture (no audit-signal commits) ..."
CLEAN="$WORK/clean"
mkdir -p "$CLEAN"
git -C "$CLEAN" init -q
git -C "$CLEAN" config user.email demo@example.invalid
git -C "$CLEAN" config user.name demo
printf 'contract Token {}\n' > "$CLEAN/Token.sol"
git -C "$CLEAN" add -A
git -C "$CLEAN" commit -qm "initial commit"
printf 'contract Token { uint a; }\n' > "$CLEAN/Token.sol"
git -C "$CLEAN" add -A
git -C "$CLEAN" commit -qm "add feature: transfer cap"
printf 'contract Token { uint a; uint b; }\n' > "$CLEAN/Token.sol"
git -C "$CLEAN" add -A
git -C "$CLEAN" commit -qm "refactor naming"
printf 'contract Token { uint a; uint b; uint c; }\n' > "$CLEAN/Token.sol"
git -C "$CLEAN" add -A
git -C "$CLEAN" commit -qm "fix typo"

CJSON="$("$PROBE" "$CLEAN" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "probe exits 0 on the clean fixture" || bad "probe exited $RC on clean fixture (expected 0)"
[ "$(printf '%s' "$CJSON" | jget heavily_audited)" = "False" ] \
  && ok "heavily_audited==false on the clean fixture" || bad "heavily_audited was not false: $CJSON"
[ "$(printf '%s' "$CJSON" | jget repo_audit_density)" = "0" ] \
  && ok "repo_audit_density==0 on the clean fixture" || bad "repo_audit_density != 0: $CJSON"
[ "$(printf '%s' "$CJSON" | jget audit_signal_commits)" = "0" ] \
  && ok "audit_signal_commits==0 on the clean fixture" || bad "audit_signal_commits != 0: $CJSON"

# ----------------------------------------------------------------------------------------------------------
# 3) --bounty with no resolvable repo: addresses only, no githubUrl / github-looking assets[].url.
# ----------------------------------------------------------------------------------------------------------
note "3) --bounty with no resolvable repo degrades to a clean [SKIP], no stdout JSON ..."
NOREPO="$WORK/norepo.json"
cat > "$NOREPO" <<JSON
{"id":"deployed-only","addresses":{"ethereum":"0x0000000000000000000000000000000000dEaD"},"assets":[{"url":"https://etherscan.io/address/0xdead"}]}
JSON
OUTF="$WORK/norepo.out"
ERRF="$WORK/norepo.err"
"$PROBE" --bounty "$NOREPO" >"$OUTF" 2>"$ERRF"; RC=$?
[ "$RC" -eq 0 ] && ok "--bounty with no resolvable repo exits 0" || bad "--bounty no-repo exited $RC (expected 0)"
if grep -q '\[SKIP\]' "$ERRF"; then ok "a [SKIP] line is emitted on stderr"; else bad "no [SKIP] line on the no-repo --bounty path"; fi
if [ -s "$OUTF" ]; then bad "stdout is non-empty on the no-repo --bounty SKIP (expected none)"; else ok "no stdout JSON on the no-repo --bounty SKIP"; fi

# ----------------------------------------------------------------------------------------------------------
# 4) an unreachable URL and a single-segment github ORG url both degrade to a clean [SKIP] (no real endpoint
#    contacted, no org-repo enumeration).
# ----------------------------------------------------------------------------------------------------------
note "4) unreachable URL / github ORG url degrade to a clean [SKIP] ..."
UOUTF="$WORK/unreachable.out"
UERRF="$WORK/unreachable.err"
"$PROBE" "https://nonexistent-example-org.example.invalid/foo/bar.git" >"$UOUTF" 2>"$UERRF"; RC=$?
[ "$RC" -eq 0 ] && ok "unreachable URL exits 0 (clean degradation, not an error)" || bad "unreachable URL exited $RC (expected 0)"
if grep -q '\[SKIP\]' "$UERRF"; then ok "unreachable URL emits a [SKIP] line"; else bad "no [SKIP] line on the unreachable URL"; fi
if [ -s "$UOUTF" ]; then bad "stdout is non-empty on the unreachable-URL SKIP (expected none)"; else ok "no stdout JSON on the unreachable-URL SKIP"; fi

OOUTF="$WORK/org.out"
OERRF="$WORK/org.err"
"$PROBE" "https://github.com/example-org-invalid" >"$OOUTF" 2>"$OERRF"; RC=$?
[ "$RC" -eq 0 ] && ok "a single-segment github ORG url exits 0" || bad "org url exited $RC (expected 0)"
if grep -q '\[SKIP\]' "$OERRF"; then ok "the org url emits a [SKIP] line (no org-repo enumeration)"; else bad "no [SKIP] line on the org url"; fi
if [ -s "$OOUTF" ]; then bad "stdout is non-empty on the org-url SKIP (expected none)"; else ok "no stdout JSON on the org-url SKIP"; fi

# ----------------------------------------------------------------------------------------------------------
# 5) bad args: no positional and no --bounty -> exit 2 (bad-args band, not a SKIP).
# ----------------------------------------------------------------------------------------------------------
note "5) no positional + no --bounty -> exit 2 ..."
"$PROBE" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "missing target and --bounty -> exit 2" || bad "missing args did not exit 2 (rc=$RC)"

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the probe read git history straight (not the unreliable bounty audits field) — a hardened fixture"
  note "      (fix-audit-N commits/branch, Cantina/Sherlock finding refs) scored heavily_audited=true, a clean"
  note "      fixture scored heavily_audited=false with 0 density, an unresolvable --bounty / an unreachable URL"
  note "      / a github ORG url all degraded to a clean [SKIP] with no stdout JSON, and missing args exit 2."
  note "      Offline + deterministic; never touches a real endpoint, never submits."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
