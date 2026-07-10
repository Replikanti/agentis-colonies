#!/usr/bin/env bash
# demo-immunefi-live.sh — OFFLINE, DETERMINISTIC proof (#1592) of run-immunefi-intake.sh's --live DISCOVERY mode:
# the public-bounties MAPPER + the backward-compatible ranking hooks (discovery_bonus, the kyc scope carry, and
# the #1599 audit-density penalty). No network: the fixture is a tiny canned bounties.json array (single-quoted
# heredoc), fed via the --bounties offline hatch; the SKIP assertion drives --live at an unreachable --url so no
# real endpoint is ever contacted.
#
# It asserts the mapper's live filter (EVM/Solidity survives; Solana/Rust, Move, inviteOnly, past-endDate and
# below-floor are dropped — each a strong absence assertion), that a kyc:true high-bounty program is SURFACED as
# `kyc:yes` in the scope_hint but NOT filtered out, that survivors rank by score DESC in an exact key order, that
# the emit is a clean 5-column TSV, that the --out file equals the stdout view, and that an unreachable --live
# fetch degrades to `[SKIP]` + exit 0 with the queue file UNTOUCHED. Section 3 (#1599) adds a controlled PAIR —
# two EVM Solidity programs with EQUAL bounty + EQUAL freshness, one clean and one citing a finished audit
# competition + Sherlock/Cantina reviews — and asserts the competition-hardened one ranks BELOW the clean one and
# surfaces `comp:yes`/`aud:<n>` while the clean one surfaces `comp:no`/`aud:0`. Mirrors the other dark-factory
# demo-*.sh (assert-based PASS/FAIL lines, a trap-cleaned temp dir, exit non-zero on failure). Dash-safe: `sh`.
#
# Usage:  dark-factory/demo-immunefi-live.sh
# Requires: python3 (the mapper's floor). Exit: 0 = all assertions held; non-zero = a failure.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INTAKE="$HERE/run-immunefi-intake.sh"

FAILS=0
note() { echo "demo-immunefi-live.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$INTAKE" ] || { note "run-immunefi-intake.sh not found / not executable: $INTAKE" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-immunefi-live.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# The canned public bounties.json array (a tiny slice of the real schema). Designed drops + designed rank:
#   evm-vault   : Solidity/ethereum, $1M, 0 audits, "vault" keyword -> discovery 15 -> TOP (score ~75)
#   evm-lending : Solidity/arbitrum, $500k, 2 audits, "lending" keyword, kyc:true -> discovery 11 -> MID (~68);
#                 the kyc:true high-bounty program that must be SURFACED, never filtered
#   evm-vyper   : Vyper (NO ecosystem -> language survival path), $100k, 4 audits, "swap/amm" -> discovery 7 (~57)
#   sol-prog    : Rust/solana, $9M (would top if not dropped) -> DROPPED (not EVM)
#   move-prog   : Move/aptos, $8M -> DROPPED (not EVM)
#   invite      : Solidity/ethereum, $5M, inviteOnly:true -> DROPPED
#   past        : Solidity/ethereum, $3M, endDate in the past -> DROPPED
#   low         : Solidity/ethereum, $5k (below --floor 10000) -> DROPPED
# No launchDate/updatedDate anywhere -> freshness term is a deterministic 0, so the ranks never drift with time.
# ----------------------------------------------------------------------------------------------------------
BOUNTIES="$WORK/bounties.json"
cat > "$BOUNTIES" <<'JSON'
[
  {"slug":"evm-vault","project":"Vault Finance","language":["Solidity"],"ecosystem":["Ethereum"],"maxBounty":1000000,"audits":[],"kyc":false,"assets":[{"url":"https://github.com/example/vault"}]},
  {"slug":"evm-lending","project":"Lending Protocol","language":["Solidity"],"ecosystem":["Arbitrum"],"maxBounty":500000,"audits":[{"id":1},{"id":2}],"kyc":true},
  {"slug":"evm-vyper","project":"Swap AMM","language":["Vyper"],"maxBounty":100000,"audits":[1,2,3,4],"kyc":false},
  {"slug":"sol-prog","project":"Solana Vault","language":["Rust"],"ecosystem":["Solana"],"maxBounty":9000000},
  {"slug":"move-prog","project":"Move Vault","language":["Move"],"ecosystem":["Aptos"],"maxBounty":8000000},
  {"slug":"invite","project":"Secret Vault","language":["Solidity"],"ecosystem":["Ethereum"],"maxBounty":5000000,"inviteOnly":true},
  {"slug":"past","project":"Old Vault","language":["Solidity"],"ecosystem":["Ethereum"],"maxBounty":3000000,"endDate":"2020-01-01"},
  {"slug":"low","project":"Tiny Vault","language":["Solidity"],"ecosystem":["Ethereum"],"maxBounty":5000}
]
JSON

DFD="$WORK/dark-factory"   # temp DARK_FACTORY_DIR (the queue lives here, never the real ~/.dark-factory)
mkdir -p "$DFD"
QUEUE="$DFD/immunefi.queue"

note "1) run-immunefi-intake.sh --bounties (offline discovery map + rank) ..."
OUT="$(DARK_FACTORY_DIR="$DFD" "$INTAKE" --bounties "$BOUNTIES" --floor 10000 --out "$QUEUE" 2>/dev/null)"; RC=$?
echo "----- ranked queue -----"
printf '%s\n' "$OUT" | sed 's/^/    /'
echo "------------------------"

[ "$RC" -eq 0 ] && ok "run-immunefi-intake exits 0 on the offline --bounties discovery path" || bad "intake exited $RC (expected 0)"

KEYS="$(printf '%s\n' "$OUT" | awk -F'\t' 'NF>=2{print $2}')"
SCORES="$(printf '%s\n' "$OUT" | awk -F'\t' 'NF>=1{print $1}')"
has_key() { printf '%s\n' "$KEYS" | grep -qxF "$1"; }

# The three EVM survivors are present; every dropped program is ABSENT (each absence is a strong assertion — the
# Solana/Move/inviteOnly ones carry the BIGGEST rewards and would top the queue if the mapper filter failed).
SURV=1
for k in immunefi:evm-vault immunefi:evm-lending immunefi:evm-vyper; do
  has_key "$k" || { bad "expected EVM survivor '$k' missing from the queue"; SURV=0; }
done
[ "$SURV" -eq 1 ] && ok "the three EVM programs (Solidity + Vyper) survive"

for k in immunefi:sol-prog immunefi:move-prog immunefi:invite immunefi:past immunefi:low; do
  if has_key "$k"; then bad "filter FAILED: '$k' should have been dropped but is in the queue"; fi
done
has_key immunefi:sol-prog  || ok "a Solana/Rust program is dropped (not EVM) despite a \$9M reward"
has_key immunefi:move-prog || ok "a Move program is dropped (not EVM) despite an \$8M reward"
has_key immunefi:invite    || ok "an inviteOnly:true program is dropped despite a \$5M reward"
has_key immunefi:past      || ok "a past-endDate program is dropped (freshness) despite a \$3M reward"
has_key immunefi:low       || ok "a below-floor program (\$5k < floor 10000) is dropped"

# Ranked by score DESCENDING (non-increasing top to bottom).
if [ -n "$SCORES" ] && printf '%s\n' "$SCORES" | awk 'NR>1 && $1>prev{exit 1} {prev=$1}'; then
  ok "queue is ranked by score descending: $(printf '%s' "$SCORES" | tr '\n' ' ')"
else
  bad "queue is NOT sorted by score descending: $(printf '%s' "$SCORES" | tr '\n' ' ')"
fi

# Exact rank order: vault (0 audits + accounting) > lending (2 audits) > vyper (4 audits).
EXPECTED="$(printf '%s\n%s\n%s' immunefi:evm-vault immunefi:evm-lending immunefi:evm-vyper)"
if [ "$KEYS" = "$EXPECTED" ]; then
  ok "exact rank order matches the documented discovery scoring (evm-vault > evm-lending > evm-vyper)"
else
  bad "rank order mismatch — got:"; printf '%s\n' "$KEYS" | sed 's/^/        /'
  note "expected:"; printf '%s\n' "$EXPECTED" | sed 's/^/        /'
fi

# kyc SURFACED, not filtered: the kyc:true program survives AND its scope_hint (col 5) carries kyc:yes; a kyc:no
# survivor carries kyc:no. The flag rides INSIDE the scope_hint, so the row stays 5 columns.
LEND_SCOPE="$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="immunefi:evm-lending"{print $5}')"
case "$LEND_SCOPE" in
  *"kyc:yes"*) ok "a kyc:true high-bounty program is SURFACED (kyc:yes) but NOT filtered out";;
  *) bad "kyc:true program did not surface kyc:yes in scope_hint: [$LEND_SCOPE]";;
esac
VAULT_SCOPE="$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="immunefi:evm-vault"{print $5}')"
case "$VAULT_SCOPE" in
  *"kyc:no"*) ok "a kyc:false program surfaces kyc:no in scope_hint";;
  *) bad "kyc:false program did not surface kyc:no: [$VAULT_SCOPE]";;
esac

# The emit is a clean 5-column TSV (run-batch.sh reads exactly `_score key url title scope`).
if [ -n "$OUT" ] && printf '%s\n' "$OUT" | awk -F'\t' 'NF!=5{exit 1}'; then
  ok "every emitted row is a 5-column TSV (matches run-batch.sh's IFS read)"
else
  bad "a row is not exactly 5 tab-separated columns"
fi

# The queue FILE equals the stdout view (the tool writes both).
if [ "$(cat "$QUEUE" 2>/dev/null)" = "$OUT" ]; then
  ok "the immunefi.queue file equals the stdout view"
else
  bad "the immunefi.queue file differs from stdout"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) --live at an UNREACHABLE --url: clean [SKIP] + exit 0 + the queue file UNTOUCHED (offline degradation).
#    A sentinel is written first so "untouched" is a byte-for-byte assertion, not merely "not created".
# ----------------------------------------------------------------------------------------------------------
note "2) --live at an unreachable --url degrades cleanly (offline SKIP) ..."
SENTINEL="sentinel-queue-must-not-be-touched"
printf '%s\n' "$SENTINEL" > "$QUEUE"
ERRF="$WORK/skip.err"
DARK_FACTORY_DIR="$DFD" "$INTAKE" --live --url "https://nonexistent.example.invalid/bounties.json" \
  --out "$QUEUE" >/dev/null 2>"$ERRF"; RC=$?
[ "$RC" -eq 0 ] && ok "unreachable --live -> exit 0 (clean degradation, not an error)" || bad "unreachable --live exited $RC (expected 0)"
if grep -q '\[SKIP\]' "$ERRF"; then ok "unreachable --live emits a [SKIP] line"; else bad "no [SKIP] line on the unreachable --live path"; fi
if [ "$(cat "$QUEUE" 2>/dev/null)" = "$SENTINEL" ]; then
  ok "the queue file is UNTOUCHED on the SKIP (no false-empty queue written)"
else
  bad "the queue file was modified on the SKIP path"
fi

# ----------------------------------------------------------------------------------------------------------
# 3) AUDIT-DENSITY penalty (#1599): a controlled PAIR — two EVM Solidity programs with EQUAL maxBounty and EQUAL
#    freshness (no launchDate/updatedDate anywhere -> freshness 0 for both), same "vault" accounting keyword and
#    an EMPTY structured `audits` array on both, so the ONLY score gap is the folded competition/firm penalty:
#      clean-fresh    : knownIssues has no competition/firm text            -> audit_penalty 0
#      comp-hardened  : knownIssues cites a finished audit competition +    -> comp_hits>=2 -> audit_penalty 15
#                       Sherlock + Cantina reviews (competition-hardened)
#    Asserts the clean program ranks strictly ABOVE the competition-hardened one, and the surfaced markers.
# ----------------------------------------------------------------------------------------------------------
note "3) audit-density penalty ranks a competition-hardened target BELOW an equal-bounty clean one (#1599) ..."
PAIR="$WORK/pair.json"
cat > "$PAIR" <<'JSON'
[
  {"slug":"clean-fresh","project":"Clean Vault","language":["Solidity"],"ecosystem":["Ethereum"],"maxBounty":200000,"audits":[],"impacts":["vault"],"knownIssues":"No known issues at this time."},
  {"slug":"comp-hardened","project":"Hardened Vault","language":["Solidity"],"ecosystem":["Ethereum"],"maxBounty":200000,"audits":[],"impacts":["vault"],"knownIssues":"See the finished audit competition at https://immunefi.com/audit-competition/foo and the Sherlock + Cantina reviews."}
]
JSON
PQUEUE="$DFD/pair.queue"
POUT="$(DARK_FACTORY_DIR="$DFD" "$INTAKE" --bounties "$PAIR" --floor 10000 --out "$PQUEUE" 2>/dev/null)"; RC=$?
echo "----- pair queue -----"
printf '%s\n' "$POUT" | sed 's/^/    /'
echo "----------------------"
[ "$RC" -eq 0 ] && ok "intake exits 0 on the audit-density pair" || bad "intake exited $RC on the pair (expected 0)"

PKEYS="$(printf '%s\n' "$POUT" | awk -F'\t' 'NF>=2{print $2}')"
# Both survive the EVM filter.
PSURV=1
for k in immunefi:clean-fresh immunefi:comp-hardened; do
  printf '%s\n' "$PKEYS" | grep -qxF "$k" || { bad "pair survivor '$k' missing from the queue"; PSURV=0; }
done
[ "$PSURV" -eq 1 ] && ok "both EVM Solidity programs survive the filter"

# clean-fresh ranks STRICTLY ABOVE comp-hardened (equal bounty + equal freshness -> only the folded penalty differs).
CLEAN_SCORE="$(printf '%s\n' "$POUT" | awk -F'\t' '$2=="immunefi:clean-fresh"{print $1}')"
COMP_SCORE="$(printf '%s\n' "$POUT" | awk -F'\t' '$2=="immunefi:comp-hardened"{print $1}')"
PEXPECTED="$(printf '%s\n%s' immunefi:clean-fresh immunefi:comp-hardened)"
if [ "$PKEYS" = "$PEXPECTED" ] && [ -n "$CLEAN_SCORE" ] && [ -n "$COMP_SCORE" ] && [ "$CLEAN_SCORE" -gt "$COMP_SCORE" ]; then
  ok "the clean program outranks the competition-hardened one ($CLEAN_SCORE > $COMP_SCORE) at equal bounty+freshness"
else
  bad "expected clean-fresh > comp-hardened; got clean=$CLEAN_SCORE comp=$COMP_SCORE order=[$(printf '%s' "$PKEYS" | tr '\n' ' ')]"
fi

# The competition-hardened row surfaces comp:yes and aud:>=1; the clean row surfaces comp:no and aud:0.
COMP_SCOPE="$(printf '%s\n' "$POUT" | awk -F'\t' '$2=="immunefi:comp-hardened"{print $5}')"
case "$COMP_SCOPE" in
  *"comp:yes"*) ok "the competition-hardened row surfaces comp:yes in scope_hint";;
  *) bad "comp-hardened row did not surface comp:yes: [$COMP_SCOPE]";;
esac
case "$COMP_SCOPE" in
  *"aud:0"*) bad "comp-hardened row shows aud:0 (expected aud:>=1): [$COMP_SCOPE]";;
  *"aud:"*) ok "the competition-hardened row surfaces a non-zero aud:<n> density";;
  *) bad "comp-hardened row carries no aud:<n> marker: [$COMP_SCOPE]";;
esac
CLEAN_SCOPE="$(printf '%s\n' "$POUT" | awk -F'\t' '$2=="immunefi:clean-fresh"{print $5}')"
case "$CLEAN_SCOPE" in
  *"comp:no"*) ok "the clean row surfaces comp:no in scope_hint";;
  *) bad "clean-fresh row did not surface comp:no: [$CLEAN_SCOPE]";;
esac
case "$CLEAN_SCOPE" in
  *"aud:0"*) ok "the clean row surfaces aud:0 (no competition/firm hits)";;
  *) bad "clean-fresh row did not surface aud:0: [$CLEAN_SCOPE]";;
esac

# The pair emit is still a clean 5-column TSV.
if [ -n "$POUT" ] && printf '%s\n' "$POUT" | awk -F'\t' 'NF!=5{exit 1}'; then
  ok "every pair row is a 5-column TSV (marker rides inside scope_hint col 5)"
else
  bad "a pair row is not exactly 5 tab-separated columns"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the --live/--bounties mapper kept only EVM programs (dropping Solana/Rust, Move, inviteOnly, a"
  note "      past-endDate and a below-floor one), surfaced kyc without filtering it, penalized a competition-"
  note "      hardened target below an equal-bounty clean one (aud:/comp: surfaced, #1599), ranked survivors by"
  note "      the discovery-bonus-adjusted score DESC as a 5-column TSV with file==stdout parity, and degraded an"
  note "      unreachable --live to a clean [SKIP] + exit 0 with the queue untouched. Offline; never submits."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
