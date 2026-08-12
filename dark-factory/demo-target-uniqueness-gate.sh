#!/usr/bin/env bash
# demo-target-uniqueness-gate.sh — OFFLINE, DETERMINISTIC proof (#1899, epic #1894 M3) of
# target-uniqueness-gate.sh: the PRE-HUNT target-level uniqueness gate that decides GO/FLAG/SKIP for a target
# and PRODUCES the exclusion set novelty-gate.sh (the untouched CONSUMER) needs. Mirrors
# demo-apply-audit-density.sh's assert-based [PASS]/[FAIL] accounting: a throwaway temp DARK_FACTORY_DIR, a
# --gh-cmd stub keyed on $UQ_ENDPOINT that cats JSON fixtures, and a --probe-cmd stub keyed on $PROBE_REPO —
# so the whole run needs NO network, NO `gh` auth and NO real audit-history-probe.sh clone path (except the
# ONE deliberate AC5 block that runs the probe's real local-dir, no-network path over a `git init` fixture).
#
# Asserts:
#   AC1  — a fresh un-audited fixture -> GO (exit 0), density field 0, reason `fresh`, and the exclusion file
#          exists with ZERO non-comment lines.
#   AC2  — a heavily-audited fixture (26 security-relevant issues + 3 advisories + density 31) -> SKIP
#          (exit 3), density field 31, reason `picked-over`, exclusion file >= 20 non-comment lines.
#   AC2b — the middle band (6 issues, density 8) -> FLAG (exit 1), and the SAME fixture under
#          `--known-hot 2 --density-hot 5` flips to SKIP — a mutation proving the thresholds DRIVE the verdict.
#   AC3  — THE HANDSHAKE: the exclusion file the AC2 run emitted, fed to `novelty-gate.sh --exclusion`, marks
#          a KNOWN candidate KNOWN (exit 1) and a NOVEL one NOVEL (exit 0) — the proven text pair from
#          demo-audit-hunter.sh. Plus: AC1's comments-only file is a VALID --exclusion input (exit 0, never 2).
#   AC3b — a junk issue (security label, no identifier and no vuln term) is DROPPED from the exclusion file —
#          the signature-quality invariant that keeps the consumer from false-KNOWN.
#   AC4  — a pre-populated --audits-dir is read AS-IS (its H-01/M-03/Finding/2.4/## finding lines land in the
#          exclusion file, audit_findings=5 in the rationale) and fetch-audits.sh is NEVER invoked (no
#          index.tsv appears). Plus an --audit-manifest pointing at an unreachable URL -> fetch-audits SKIPs,
#          the audit leg stays unavailable, the gate still emits a verdict and never crashes.
#   AC5  — fallback: (a) a real throwaway `git init` fixture as --local-dir with the DEFAULT --probe-cmd, so
#          audit-history-probe.sh really runs its no-network local path -> a real integer density,
#          `sources=density`, reason `partial-signal`, exit 1 (guarded by `command -v git`); (b) everything
#          unavailable -> `TARGET-UNIQUENESS|FLAG|-1|no-signal`, exit 1, exclusion file STILL written, no crash.
#   AC6  — arg band: no target flag / an unknown flag / a negative threshold / an unreadable --audit-manifest
#          -> exit 2; but `--scope-hint "chain:ethereum repo:- commit:-"` -> a FLAG/no-signal VERDICT, never
#          exit 2 (the M4 #1900 seam must not see an arg error for an ordinary queue row).
#   AC7  — the M4 stdout pin: EVERY run above emits exactly ONE stdout line, starting with
#          `TARGET-UNIQUENESS|` and splitting into exactly 4 `|` fields; all chatter is on stderr.
#
# Usage:  dark-factory/demo-target-uniqueness-gate.sh
# Requires: python3 (git only for the AC5(a) block, which skips itself without it).
# Exit: 0 = all assertions held; 1 = a failure; 3 = the gate is missing / not executable.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/target-uniqueness-gate.sh"
NOVELTY="$HERE/novelty-gate.sh"

FAILS=0
note() { echo "demo-target-uniqueness-gate.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$GATE" ] || { note "target-uniqueness-gate.sh not found / not executable: $GATE" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-target-uniqueness-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export DARK_FACTORY_DIR="$WORK/dark-factory-home"   # never touch the real ~/.dark-factory
export FX="$WORK/fx"                                # the stubs below cat their fixtures from here
mkdir -p "$FX"

# fld: field <n> of a `|`-delimited verdict line.
fld() { printf '%s' "$1" | cut -d'|' -f"$2"; }
# noncomment_count: exclusion-file lines novelty-gate.sh would actually match against.
noncomment_count() { awk '!/^#/ && NF { n++ } END { print n + 0 }' "$1"; }
# check_line: the AC7 stdout pin, applied to every single run.
check_line() {
  cl_n="$(wc -l < "$1" | tr -d ' ')"
  if [ "$cl_n" != "1" ]; then bad "AC7 ($2): stdout had $cl_n line(s), want exactly 1"; return 1; fi
  cl_first="$(head -1 "$1")"
  case "$cl_first" in
    TARGET-UNIQUENESS\|*) ;;
    *) bad "AC7 ($2): stdout line is not TARGET-UNIQUENESS-prefixed: $cl_first"; return 1;;
  esac
  cl_fields="$(printf '%s' "$cl_first" | awk -F'|' '{ print NF }')"
  if [ "$cl_fields" != "4" ]; then bad "AC7 ($2): line splits into $cl_fields fields, want 4"; return 1; fi
  ok "AC7 ($2): exactly one TARGET-UNIQUENESS stdout line, 4 pipe-fields"
}

# ----------------------------------------------------------------------------------------------------------
# Fixtures. Generic names only (example/fresh, example/audited, example.invalid) — no real target is named.
# ----------------------------------------------------------------------------------------------------------
printf '[]\n' > "$FX/empty.json"

# The heavily-audited target: 1 crafted issue (the AC3 KNOWN anchor, a paraphrase of demo-audit-hunter.sh's
# proven value-leak exclusion line), 24 synthetic security-relevant issues, 1 junk issue (AC3b).
{
  printf '[{"number":1,"title":"Bin value leak: token0 and token1 distributed equally due to rounding down","body":"calculatePriceAtBinPosition treats both tokens as distributed equally; token0BalanceScaled round trip loses value.","labels":[{"name":"security"}]}'
  i=1
  while [ "$i" -le 24 ]; do
    printf ',{"number":%d,"title":"H-%02d rounding drift in redeemShares%d during a partial withdrawal","body":"The vault helper redeemShares%d rounds the share price down, leaking value on every partial withdrawal.","labels":[{"name":"audit"}]}' \
      "$((i + 1))" "$i" "$i" "$i"
    i=$((i + 1))
  done
  printf ',{"number":99,"title":"Update the readme file","body":"adds a short intro paragraph to the project docs","labels":[{"name":"security"}]}'
  printf ']\n'
} > "$FX/audited-issues.json"

{
  printf '[{"summary":"Sequencer grace period lets the price provider skip the deviation check","description":"During an L2 sequencer restart the deviation band is not enforced."}'
  printf ',{"summary":"Unbounded loop in harvestRewards enables a griefing DoS on the vault keeper","description":"A large reward array makes harvestRewards exceed the block gas limit."}'
  printf ',{"summary":"Rounding in previewRedeem lets a first depositor inflate the share price","description":"An attacker donates assets before the first deposit and inflates shares."}'
  printf ']\n'
} > "$FX/audited-advisories.json"

# The middle band: 6 security-relevant issues, nothing else.
{
  printf '['
  i=1
  while [ "$i" -le 6 ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"number":%d,"title":"M-%02d slippage bound missing in swapExactIn%d on the router path","body":"swapExactIn%d accepts a zero minimum output, so a sandwich can extract the whole trade.","labels":[{"name":"security"}]}' \
      "$i" "$i" "$i" "$i"
    i=$((i + 1))
  done
  printf ']\n'
} > "$FX/mid-issues.json"

# A pre-populated audit report (leg (b)'s OFFLINE seam): 5 finding-shaped lines in the four accepted shapes.
AUDITS_DIR="$WORK/audits"
mkdir -p "$AUDITS_DIR"
{
  printf 'Example Protocol audit report (public)\n\n'
  printf 'H-01 Oracle staleness check skipped during the sequencer grace period\n'
  printf 'The provider contract does not re-check the deviation band on resume.\n\n'
  printf 'M-03 redeemCollateral rounds the share price up, leaking dust on every redeem\n'
  printf 'Finding 7 Missing allowance reset in approveRouter before a re-approval\n'
  printf '2.4 Reentrancy in withdrawAll() lets a malicious receiver re-enter\n'
  printf '## H-09 Fee accrual drift in accrueFees during a paused epoch\n'
  printf 'Some prose that is not a finding line at all.\n'
} > "$AUDITS_DIR/01-report.txt"

# The --gh-cmd stub: keyed on $UQ_ENDPOINT, cats a JSON fixture (the demo-apply-audit-density.sh STUB idiom).
GH_STUB='case "$UQ_ENDPOINT" in
  *example/audited/issues*)              cat "$FX/audited-issues.json";;
  *example/audited/security-advisories*) cat "$FX/audited-advisories.json";;
  *example/mid/issues*)                  cat "$FX/mid-issues.json";;
  *example/mid/security-advisories*)     cat "$FX/empty.json";;
  *example/fresh/*)                      cat "$FX/empty.json";;
  *example/audits/*)                     cat "$FX/empty.json";;
  *example/manifest/*)                   cat "$FX/empty.json";;
  *) ;;
esac'

# The --probe-cmd stub: keyed on $PROBE_REPO, prints a canned audit-history-probe.sh JSON verdict (or nothing).
PROBE_STUB='case "$PROBE_REPO" in
  *example/audited) printf "%s" "{\"heavily_audited\":true,\"repo_audit_density\":31}";;
  *example/fresh)   printf "%s" "{\"heavily_audited\":false,\"repo_audit_density\":0}";;
  *example/mid)     printf "%s" "{\"heavily_audited\":false,\"repo_audit_density\":8}";;
  *example/audits)  printf "%s" "{\"heavily_audited\":false,\"repo_audit_density\":2}";;
  *) ;;
esac'

# ----------------------------------------------------------------------------------------------------------
note "1) AC1 — a fresh un-audited target (no issues, no advisories, density 0) ..."
EXCL1="$WORK/excl-fresh.txt"
"$GATE" --repo example/fresh --gh-cmd "$GH_STUB" --probe-cmd "$PROBE_STUB" --exclusion-out "$EXCL1" \
  > "$WORK/out1.txt" 2> "$WORK/err1.txt"
RC=$?
LINE1="$(head -1 "$WORK/out1.txt")"
check_line "$WORK/out1.txt" "AC1"
[ "$RC" -eq 0 ] && ok "AC1: exit 0 (GO)" || bad "AC1 FAILED: exit $RC (want 0 = GO)"
[ "$(fld "$LINE1" 2)" = "GO" ] && ok "AC1: verdict field is GO" || bad "AC1 FAILED: verdict is $(fld "$LINE1" 2)"
[ "$(fld "$LINE1" 3)" = "0" ] && ok "AC1: density field is 0" || bad "AC1 FAILED: density is $(fld "$LINE1" 3)"
case "$(fld "$LINE1" 4)" in
  fresh:*) ok "AC1: reason token is 'fresh'";;
  *)       bad "AC1 FAILED: reason is $(fld "$LINE1" 4)";;
esac
if [ -f "$EXCL1" ]; then
  ok "AC1: the exclusion file was written even on a GO"
  [ "$(noncomment_count "$EXCL1")" = "0" ] && ok "AC1: the exclusion set is empty (0 non-comment lines)" \
    || bad "AC1 FAILED: exclusion set is not empty ($(noncomment_count "$EXCL1") lines)"
else
  bad "AC1 FAILED: no exclusion file at $EXCL1"
fi

# ----------------------------------------------------------------------------------------------------------
note "2) AC2 — a heavily-audited target (26 security issues + 3 advisories + density 31) ..."
EXCL2="$WORK/excl-audited.txt"
"$GATE" --repo example/audited --gh-cmd "$GH_STUB" --probe-cmd "$PROBE_STUB" --exclusion-out "$EXCL2" \
  > "$WORK/out2.txt" 2> "$WORK/err2.txt"
RC=$?
LINE2="$(head -1 "$WORK/out2.txt")"
check_line "$WORK/out2.txt" "AC2"
[ "$RC" -eq 3 ] && ok "AC2: exit 3 (SKIP)" || bad "AC2 FAILED: exit $RC (want 3 = SKIP)"
[ "$(fld "$LINE2" 2)" = "SKIP" ] && ok "AC2: verdict field is SKIP" || bad "AC2 FAILED: verdict is $(fld "$LINE2" 2)"
[ "$(fld "$LINE2" 3)" = "31" ] && ok "AC2: density field carries the probe's 31" \
  || bad "AC2 FAILED: density is $(fld "$LINE2" 3), want 31"
case "$(fld "$LINE2" 4)" in
  picked-over:*) ok "AC2: reason token is 'picked-over'";;
  *)             bad "AC2 FAILED: reason is $(fld "$LINE2" 4)";;
esac
case "$LINE2" in
  *"known=26 advisories=3"*) ok "AC2: the rationale reports known=26 advisories=3";;
  *)                         bad "AC2 FAILED: unexpected counts in $LINE2";;
esac
N2="$(noncomment_count "$EXCL2")"
[ "$N2" -ge 20 ] && ok "AC2: the exclusion set carries $N2 signatures (>= 20)" \
  || bad "AC2 FAILED: only $N2 exclusion signatures (want >= 20)"

# ----------------------------------------------------------------------------------------------------------
note "3) AC3b — the junk issue (security label, no identifier, no vuln term) is DROPPED ..."
if grep -q "Update the readme file" "$EXCL2"; then
  bad "AC3b FAILED: the junk issue leaked into the exclusion set (false-KNOWN risk downstream)"
else
  ok "AC3b: the junk issue is absent from the exclusion set (signature-quality invariant holds)"
fi
grep -q "calculatePriceAtBinPosition" "$EXCL2" \
  && ok "AC3b: a genuine security issue's signature IS present (the drop rule is not over-broad)" \
  || bad "AC3b FAILED: the crafted security issue is missing from the exclusion set"

# ----------------------------------------------------------------------------------------------------------
note "4) AC3 — the end-to-end handshake: the emitted exclusion file drives novelty-gate.sh ..."
if [ -x "$NOVELTY" ]; then
  printf '%s' 'Partial swaps return the bin to zero token0 but the pool loses token1 because calculatePriceAtBinPosition treats both tokens as distributed equally, rounding down instead of crediting the actual balance.' \
    | "$NOVELTY" --exclusion "$EXCL2" > "$WORK/nov-known.txt" 2>&1
  RC=$?
  [ "$RC" -eq 1 ] && ok "AC3: a KNOWN candidate is rejected by novelty-gate (exit 1 = KNOWN)" \
    || bad "AC3 FAILED: the KNOWN candidate exited $RC (want 1): $(head -1 "$WORK/nov-known.txt")"

  printf '%s' 'selfPermit in the router lets a griefer replay an EIP-2612 signature across CREATE3-identical addresses on different chains.' \
    | "$NOVELTY" --exclusion "$EXCL2" > "$WORK/nov-novel.txt" 2>&1
  RC=$?
  [ "$RC" -eq 0 ] && ok "AC3: a genuinely-novel candidate still passes (exit 0 = NOVEL)" \
    || bad "AC3 FAILED: the NOVEL candidate exited $RC (want 0): $(head -1 "$WORK/nov-novel.txt")"

  printf '%s' 'selfPermit in the router lets a griefer replay an EIP-2612 signature across CREATE3-identical addresses on different chains.' \
    | "$NOVELTY" --exclusion "$EXCL1" > /dev/null 2>&1
  RC=$?
  [ "$RC" -eq 0 ] && ok "AC3: the comments-only (GO) exclusion file is a VALID --exclusion input (exit 0)" \
    || bad "AC3 FAILED: the comments-only exclusion file exited $RC (want 0, never 2)"
else
  bad "AC3 FAILED: novelty-gate.sh not executable: $NOVELTY"
fi

# ----------------------------------------------------------------------------------------------------------
note "5) AC2b — the middle band is FLAG, and flips to SKIP under tightened thresholds ..."
"$GATE" --repo example/mid --gh-cmd "$GH_STUB" --probe-cmd "$PROBE_STUB" \
  --exclusion-out "$WORK/excl-mid.txt" > "$WORK/out3.txt" 2> "$WORK/err3.txt"
RC=$?
LINE3="$(head -1 "$WORK/out3.txt")"
check_line "$WORK/out3.txt" "AC2b-default"
[ "$RC" -eq 1 ] && ok "AC2b: exit 1 (FLAG) on the default thresholds" \
  || bad "AC2b FAILED: exit $RC (want 1 = FLAG)"
[ "$(fld "$LINE3" 2)" = "FLAG" ] && ok "AC2b: verdict field is FLAG (neither GO nor SKIP)" \
  || bad "AC2b FAILED: verdict is $(fld "$LINE3" 2)"
[ "$(fld "$LINE3" 3)" = "8" ] && ok "AC2b: density field carries the probe's 8" \
  || bad "AC2b FAILED: density is $(fld "$LINE3" 3), want 8"

"$GATE" --repo example/mid --gh-cmd "$GH_STUB" --probe-cmd "$PROBE_STUB" --known-hot 2 --density-hot 5 \
  --exclusion-out "$WORK/excl-mid2.txt" > "$WORK/out4.txt" 2> "$WORK/err4.txt"
RC=$?
LINE4="$(head -1 "$WORK/out4.txt")"
check_line "$WORK/out4.txt" "AC2b-mutated"
[ "$RC" -eq 3 ] && ok "AC2b MUTATION: the SAME fixture flips to exit 3 (SKIP) under --known-hot 2 --density-hot 5" \
  || bad "AC2b MUTATION FAILED: exit $RC (want 3 = SKIP)"
[ "$(fld "$LINE4" 2)" = "SKIP" ] && ok "AC2b MUTATION: the thresholds DRIVE the verdict, they do not decorate it" \
  || bad "AC2b MUTATION FAILED: verdict is $(fld "$LINE4" 2)"

# ----------------------------------------------------------------------------------------------------------
note "6) AC4 — a pre-populated --audits-dir is read AS-IS; fetch-audits.sh is never invoked ..."
EXCL5="$WORK/excl-audits.txt"
"$GATE" --repo example/audits --gh-cmd "$GH_STUB" --probe-cmd "$PROBE_STUB" --audits-dir "$AUDITS_DIR" \
  --exclusion-out "$EXCL5" > "$WORK/out5.txt" 2> "$WORK/err5.txt"
RC=$?
LINE5="$(head -1 "$WORK/out5.txt")"
check_line "$WORK/out5.txt" "AC4-audits-dir"
[ "$RC" -eq 1 ] && ok "AC4: exit 1 (FLAG) — prior audit findings are not a fresh target" \
  || bad "AC4 FAILED: exit $RC (want 1 = FLAG)"
case "$LINE5" in
  *"audit_findings=5"*) ok "AC4: all 5 finding-shaped lines were counted (audit_findings=5)";;
  *)                    bad "AC4 FAILED: unexpected audit_findings in $LINE5";;
esac
case "$LINE5" in
  *audits*) ok "AC4: 'audits' is listed among the sources";;
  *)        bad "AC4 FAILED: the audits leg is missing from sources in $LINE5";;
esac
grep -q "Oracle staleness check skipped during the sequencer grace period" "$EXCL5" \
  && ok "AC4: the H-01 finding line landed in the exclusion set" \
  || bad "AC4 FAILED: the H-01 finding line is missing from the exclusion set"
grep -q "accrueFees" "$EXCL5" \
  && ok "AC4: the markdown-heading finding (## H-09) landed in the exclusion set" \
  || bad "AC4 FAILED: the heading finding is missing from the exclusion set"
[ -e "$AUDITS_DIR/index.tsv" ] \
  && bad "AC4 FAILED: fetch-audits.sh was invoked (index.tsv appeared) despite a pre-populated --audits-dir" \
  || ok "AC4: fetch-audits.sh was NOT invoked (no index.tsv) — the dir was read as-is"

note "7) AC4 — an --audit-manifest with an unreachable URL: fetch-audits SKIPs, the gate still verdicts ..."
MANIFEST="$WORK/audits.manifest"
printf '# operator-supplied audit report URLs\nhttps://127.0.0.1:1/nope.pdf\n' > "$MANIFEST"
"$GATE" --repo example/manifest --gh-cmd "$GH_STUB" --probe-cmd "$PROBE_STUB" --audit-manifest "$MANIFEST" \
  --audits-dir "$WORK/audits-empty" --exclusion-out "$WORK/excl-manifest.txt" \
  > "$WORK/out6.txt" 2> "$WORK/err6.txt"
RC=$?
LINE6="$(head -1 "$WORK/out6.txt")"
check_line "$WORK/out6.txt" "AC4-manifest"
[ "$RC" -eq 1 ] && ok "AC4: an unreachable audit manifest still yields a FLAG verdict (exit 1), never a crash" \
  || bad "AC4 FAILED: exit $RC (want 1 = FLAG)"
case "$LINE6" in
  *"audit_findings=0"*) ok "AC4: the audit leg degraded to 0 findings without blocking the run";;
  *)                    bad "AC4 FAILED: unexpected audit_findings in $LINE6";;
esac
[ -f "$WORK/excl-manifest.txt" ] && ok "AC4: the exclusion file is written even when every leg is thin" \
  || bad "AC4 FAILED: no exclusion file on the manifest run"

# ----------------------------------------------------------------------------------------------------------
note "8) AC5(a) — the no-network density fallback over a REAL git fixture (default --probe-cmd) ..."
if command -v git >/dev/null 2>&1; then
  LOCAL="$WORK/local-target"
  mkdir -p "$LOCAL"
  git -C "$LOCAL" init -q
  git -C "$LOCAL" config user.email demo@example.invalid
  git -C "$LOCAL" config user.name demo
  printf 'contract Vault {}\n' > "$LOCAL/Vault.sol"
  git -C "$LOCAL" add -A && git -C "$LOCAL" commit -qm "initial commit"
  printf 'contract Vault { uint a; }\n' > "$LOCAL/Vault.sol"
  git -C "$LOCAL" add -A && git -C "$LOCAL" commit -qm "add feature: deposit cap"
  printf 'contract Vault { uint a; uint b; }\n' > "$LOCAL/Vault.sol"
  git -C "$LOCAL" add -A && git -C "$LOCAL" commit -qm "refactor storage layout"
  printf 'contract Vault { uint a; uint b; uint c; }\n' > "$LOCAL/Vault.sol"
  git -C "$LOCAL" add -A && git -C "$LOCAL" commit -qm "fix typo in comment"
  printf 'contract Vault { uint patched; }\n' > "$LOCAL/Vault.sol"
  git -C "$LOCAL" add -A && git -C "$LOCAL" commit -qm "fix-audit-2: rounding in the withdraw path"

  # No --probe-cmd: audit-history-probe.sh really runs, on its local-dir (NO NETWORK) path.
  "$GATE" --local-dir "$LOCAL" --gh-cmd 'true' --exclusion-out "$WORK/excl-local.txt" \
    > "$WORK/out7.txt" 2> "$WORK/err7.txt"
  RC=$?
  LINE7="$(head -1 "$WORK/out7.txt")"
  check_line "$WORK/out7.txt" "AC5-local-dir"
  [ "$RC" -eq 1 ] && ok "AC5(a): exit 1 (FLAG) — one source is never enough for a GO" \
    || bad "AC5(a) FAILED: exit $RC (want 1 = FLAG)"
  [ "$(fld "$LINE7" 3)" = "20" ] \
    && ok "AC5(a): the real local-path probe reported density 20 (1 audit-signal commit of 5)" \
    || bad "AC5(a) FAILED: density is $(fld "$LINE7" 3), want 20"
  case "$(fld "$LINE7" 4)" in
    partial-signal:*sources=density) ok "AC5(a): reason 'partial-signal' with sources=density only";;
    *)                               bad "AC5(a) FAILED: unexpected rationale $(fld "$LINE7" 4)";;
  esac
else
  note "  [SKIP] git not installed — the real-probe local-dir block is not exercised"
fi

note "9) AC5(b) — everything unavailable -> FLAG/no-signal, density -1, exclusion file still written ..."
EXCL8="$WORK/excl-unavailable.txt"
"$GATE" --repo example/unavailable --gh-cmd 'true' --probe-cmd 'true' --exclusion-out "$EXCL8" \
  > "$WORK/out8.txt" 2> "$WORK/err8.txt"
RC=$?
LINE8="$(head -1 "$WORK/out8.txt")"
check_line "$WORK/out8.txt" "AC5-no-signal"
[ "$RC" -eq 1 ] && ok "AC5(b): exit 1 (FLAG) with no sources at all — never a silent GO" \
  || bad "AC5(b) FAILED: exit $RC (want 1 = FLAG)"
[ "$(fld "$LINE8" 2)" = "FLAG" ] && ok "AC5(b): verdict field is FLAG" \
  || bad "AC5(b) FAILED: verdict is $(fld "$LINE8" 2)"
[ "$(fld "$LINE8" 3)" = "-1" ] && ok "AC5(b): density field is -1 (unknown, NOT 0)" \
  || bad "AC5(b) FAILED: density is $(fld "$LINE8" 3), want -1"
case "$(fld "$LINE8" 4)" in
  no-signal:*) ok "AC5(b): reason token is 'no-signal'";;
  *)           bad "AC5(b) FAILED: reason is $(fld "$LINE8" 4)";;
esac
[ -f "$EXCL8" ] && ok "AC5(b): the exclusion file is written even on the no-signal path" \
  || bad "AC5(b) FAILED: no exclusion file at $EXCL8"

# ----------------------------------------------------------------------------------------------------------
note "10) AC6 — the arg band (exit 2) vs an ordinary no-repo queue row (a verdict, never exit 2) ..."
"$GATE" > /dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "AC6: no target flag at all -> exit 2" || bad "AC6 FAILED: no-target exited $RC (want 2)"

"$GATE" --repo example/fresh --nope > /dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "AC6: an unknown flag -> exit 2" || bad "AC6 FAILED: unknown flag exited $RC (want 2)"

"$GATE" --repo example/fresh --density-hot -5 > /dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "AC6: a negative threshold -> exit 2" || bad "AC6 FAILED: bad threshold exited $RC (want 2)"

"$GATE" --repo example/fresh --audit-manifest "$WORK/does-not-exist.manifest" > /dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "AC6: an unreadable --audit-manifest -> exit 2" \
  || bad "AC6 FAILED: unreadable manifest exited $RC (want 2)"

"$GATE" --repo "not a repo at all" > /dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "AC6: a malformed --repo -> exit 2" || bad "AC6 FAILED: malformed --repo exited $RC (want 2)"

"$GATE" --scope-hint "chain:ethereum repo:- commit:-" --gh-cmd 'true' --probe-cmd 'true' \
  --exclusion-out "$WORK/excl-norepo.txt" > "$WORK/out9.txt" 2> "$WORK/err9.txt"
RC=$?
LINE9="$(head -1 "$WORK/out9.txt")"
check_line "$WORK/out9.txt" "AC6-scope-hint"
[ "$RC" -eq 1 ] && ok "AC6: a 'repo:-' scope_hint yields a FLAG VERDICT (exit 1), never an arg error" \
  || bad "AC6 FAILED: the repo:- scope_hint exited $RC (want 1 = FLAG, never 2)"
case "$(fld "$LINE9" 4)" in
  no-signal:*) ok "AC6: the no-repo queue row reports 'no-signal' — the M4 seam stays on the verdict path";;
  *)           bad "AC6 FAILED: reason is $(fld "$LINE9" 4)";;
esac

# ----------------------------------------------------------------------------------------------------------
echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: target-uniqueness-gate.sh GO'd a fresh target, SKIP'd a picked-over one, held the middle band at"
  note "      FLAG (and flipped it to SKIP purely by moving the thresholds), produced an exclusion set that"
  note "      novelty-gate.sh reads back to KNOWN/NOVEL correctly, dropped a junk signature, read a"
  note "      pre-populated audits dir without touching the network, fell back to the real no-network density"
  note "      probe, and never turned missing data into a GO. Offline + deterministic; the real"
  note "      ~/.dark-factory is never touched."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
