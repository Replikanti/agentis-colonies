#!/usr/bin/env bash
# demo-prospector-queue.sh — offline, deterministic proof (#1459) that prospector-queue.sh turns the
# prospector colony's QUALIFIED, bounty-annotated dossiers into an audit queue RANKED BY EXPECTED PAYOUT
# that run-batch.sh consumes, keeps the boolean qualification gates as the FLOOR (a huge bounty on a
# non-qualifying target never enters the queue), carries the in-scope commit + address into each row, and
# NEVER submits / has no platform egress. No network, no agentis; throwaway temp staging.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/prospector-queue.sh"
RUN_BATCH="$HERE/run-batch.sh"

FAIL=0
pass() { echo "demo-prospector-queue.sh: [PASS] $1"; }
fail() { echo "demo-prospector-queue.sh: [FAIL] $1" >&2; FAIL=1; }

command -v python3 >/dev/null || { echo "demo-prospector-queue.sh: [SKIP] python3 not installed" >&2; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DOSS="$WORK/dossiers.jsonl"
QUEUE="$WORK/prospector.queue"

BIG='0x1111111111111111111111111111111111111111'
MID='0x2222222222222222222222222222222222222222'
SMALL='0x3333333333333333333333333333333333333333'
NOBTY='0x4444444444444444444444444444444444444444'
NOTQ='0x5555555555555555555555555555555555555555'

# Qualified dossiers with descending bounties, a qualified no-bounty target, and a NON-qualifying target
# carrying the biggest bounty of all (must be excluded — the gates are the floor, bounty only orders).
{
  printf '{"agent":"coordinator","target":"%s","chain":"1","label":"Mid Vault","qualifies":true,"family":"vault-4626","value":"above","why":"all gates pass","watch":"totalAssets() ge totalSupply() (share solvency)","bounty":"2250000","commit":"c-mid"}\n' "$MID"
  printf '{"agent":"coordinator","target":"%s","chain":"1","label":"Big Lend","qualifies":true,"family":"lending","value":"above","why":"all gates pass","watch":"collateral ge borrowed","bounty":"5000000","commit":"c-big"}\n' "$BIG"
  printf '{"agent":"coordinator","target":"%s","chain":"10","label":"Small AMM","qualifies":true,"family":"amm","value":"above","why":"all gates pass","watch":"k non-decreasing","bounty":"900000","commit":"c-small"}\n' "$SMALL"
  printf '{"agent":"coordinator","target":"%s","chain":"1","label":"No Bounty Vault","qualifies":true,"family":"vault-4626","value":"above","why":"all gates pass","watch":"totalAssets() ge totalSupply()","bounty":"","commit":""}\n' "$NOBTY"
  printf '{"agent":"coordinator","target":"%s","chain":"1","label":"Huge Bounty But Unqualified","qualifies":false,"family":"no-invariant","value":"above","why":"failed gate: value-invariant","watch":"","bounty":"9999999","commit":"c-notq"}\n' "$NOTQ"
} > "$DOSS"

"$RUN" --dossiers "$DOSS" --out "$QUEUE" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "ranks a dossier file, exits 0" || fail "exit $rc"

# --- 1. Ranked by bounty DESC; no-bounty qualified target lands last at score 0 --------------------------
keys="$(cut -f2 "$QUEUE")"
expected="prospector:$BIG
prospector:$MID
prospector:$SMALL
prospector:$NOBTY"
if [ "$keys" = "$expected" ]; then
  pass "queue ordered by bounty DESC (5M > 2.25M > 900k > 0), no-bounty target last"
else
  fail "wrong order; got:$(printf '\n%s' "$keys")"
fi

scores="$(cut -f1 "$QUEUE" | tr '\n' ' ')"
[ "$scores" = "5000000 2250000 900000 0 " ] \
  && pass "score column = bounty USD (expected-payout proxy): $scores" \
  || fail "score column wrong: [$scores]"

# --- 2. Boolean gates are the FLOOR: the non-qualifying target is absent despite the biggest bounty -------
if grep -q "$NOTQ" "$QUEUE"; then
  fail "non-qualifying target ($NOTQ) leaked into the queue — bounty must NOT override the gates"
else
  pass "non-qualifying target excluded despite a 9.99M bounty (gates remain the floor)"
fi

# --- 3. scope_hint carries the address (run-batch resolver) + the in-scope commit ------------------------
row1_scope="$(head -1 "$QUEUE" | cut -f5)"
case "$row1_scope" in
  *"addr:$BIG"*"commit:c-big"*) pass "scope_hint carries addr + in-scope commit ($row1_scope)";;
  *) fail "scope_hint missing addr/commit: [$row1_scope]";;
esac

# --- 4. min-bounty floor drops the no-bounty (and only the no-bounty) target -----------------------------
Q2="$WORK/min.queue"
"$RUN" --dossiers "$DOSS" --out "$Q2" --min-bounty 1000000 >/dev/null 2>&1
m_keys="$(cut -f2 "$Q2" | tr '\n' ' ')"
[ "$m_keys" = "prospector:$BIG prospector:$MID " ] \
  && pass "--min-bounty 1000000 keeps only >=1M targets ($m_keys)" \
  || fail "--min-bounty floor wrong: [$m_keys]"

# --- 5. run-batch.sh consumes the queue in payout order and stages NOTHING on a dry hunt -----------------
if [ -x "$RUN_BATCH" ] || [ -f "$RUN_BATCH" ]; then
  BOUT="$WORK/bout"
  batch_out="$(DARK_FACTORY_DIR="$WORK/dfd" bash "$RUN_BATCH" --queue "$QUEUE" \
      --hunt-cmd 'printf "VERDICT|dry|%s\n" "$BATCH_KEY"' --max-targets 10 --out "$BOUT" 2>/dev/null)"; brc=$?
  first_processed="$(printf '%s\n' "$batch_out" | head -1 | cut -f1)"
  if [ "$brc" -eq 0 ] && [ "$first_processed" = "prospector:$BIG" ]; then
    pass "run-batch consumes the queue highest-payout-first (first hunted = $first_processed)"
  else
    fail "run-batch round-trip: exit $brc, first processed [$first_processed] (expected prospector:$BIG)"
  fi
  if [ -d "$BOUT/submission" ] && [ -n "$(ls -A "$BOUT/submission" 2>/dev/null)" ]; then
    fail "run-batch staged a submission on an all-dry run — nothing should be staged"
  else
    pass "no submission staged on a dry hunt (submission stays human-gated)"
  fi
else
  echo "demo-prospector-queue.sh: [SKIP] run-batch.sh not found — skipping consumption round-trip" >&2
fi

# --- 6. No platform egress: the bridge never curls / wgets / posts (source guard on non-comment lines) ---
if grep -vE '^[[:space:]]*#' "$RUN" | grep -Eq '\b(curl|wget|nc|POST)\b'; then
  fail "prospector-queue.sh has an egress command (curl/wget/nc/POST) — it must be read-only, no egress"
else
  pass "no egress command in prospector-queue.sh (read-only; never contacts a platform)"
fi

# --- 7. Empty / no-dossier input is a clean SKIP (exit 0), CI-safe ----------------------------------------
: > "$WORK/empty.jsonl"
"$RUN" --dossiers "$WORK/empty.jsonl" --out "$WORK/empty.queue" >/dev/null 2>&1
erc=$?; ecount="$(grep -c . "$WORK/empty.queue" 2>/dev/null || true)"
[ "$erc" -eq 0 ] && [ "${ecount:-0}" -eq 0 ] \
  && pass "empty dossier input -> empty queue, exit 0 (CI-safe)" \
  || fail "empty input: exit $erc, $ecount rows"

# --- 8. --limit caps to the top-ranked N ------------------------------------------------------------------
QL="$WORK/limit.queue"
"$RUN" --dossiers "$DOSS" --out "$QL" --limit 2 >/dev/null 2>&1
l_keys="$(cut -f2 "$QL" | tr '\n' ' ')"
[ "$l_keys" = "prospector:$BIG prospector:$MID " ] \
  && pass "--limit 2 keeps the top 2 by payout ($l_keys)" \
  || fail "--limit 2 wrong: [$l_keys]"

# --- 9. A malformed (non-JSON) dossier line is skipped, never crashes the rank ----------------------------
MAL="$WORK/malformed.jsonl"
{ echo 'not json at all'; echo '{"target": "0xBROKEN", oops'; cat "$DOSS"; } > "$MAL"
"$RUN" --dossiers "$MAL" --out "$WORK/mal.queue" >/dev/null 2>&1; mrc=$?
mal_keys="$(cut -f2 "$WORK/mal.queue" | tr '\n' ' ')"
if [ "$mrc" -eq 0 ] && [ "$mal_keys" = "prospector:$BIG prospector:$MID prospector:$SMALL prospector:$NOBTY " ]; then
  pass "malformed dossier lines skipped, valid targets still ranked (exit 0)"
else
  fail "malformed handling: exit $mrc, keys [$mal_keys]"
fi

# --- 10. A target listed twice is deduped, keeping the highest-bounty row ---------------------------------
DUP="$WORK/dup.jsonl"
{
  printf '{"target":"%s","chain":"1","label":"Big Lend","qualifies":true,"family":"lending","value":"above","why":"all gates pass","watch":"x","bounty":"5000000","commit":"c-big"}\n' "$BIG"
  printf '{"target":"%s","chain":"1","label":"Big Lend (stale)","qualifies":true,"family":"lending","value":"above","why":"all gates pass","watch":"x","bounty":"3000000","commit":"c-old"}\n' "$BIG"
} > "$DUP"
"$RUN" --dossiers "$DUP" --out "$WORK/dup.queue" >/dev/null 2>&1
dup_rows="$(grep -c "prospector:$BIG" "$WORK/dup.queue" 2>/dev/null || true)"
dup_score="$(head -1 "$WORK/dup.queue" | cut -f1)"
if [ "${dup_rows:-0}" -eq 1 ] && [ "$dup_score" = "5000000" ]; then
  pass "duplicate target deduped to one row, highest bounty kept (score=$dup_score)"
else
  fail "dedup wrong: $dup_rows row(s), score [$dup_score]"
fi

# --- 11. CLI guards: unknown flag + missing flag value both exit 2 ----------------------------------------
"$RUN" --bogus >/dev/null 2>&1; [ "$?" -eq 2 ] \
  && pass "unknown flag -> exit 2" || fail "unknown flag did not exit 2"
"$RUN" --dossiers >/dev/null 2>&1; [ "$?" -eq 2 ] \
  && pass "flag missing its value -> exit 2" || fail "missing flag value did not exit 2"

# --- 12. Dedup is CASE-INSENSITIVE (matches the coordinator's join): same address, two casings -> one row -
CIADDR_UP='0xAB00000000000000000000000000000000000099'
CIADDR_LO='0xab00000000000000000000000000000000000099'
CIDUP="$WORK/ci-dup.jsonl"
{
  printf '{"target":"%s","chain":"1","label":"Upper","qualifies":true,"family":"amm","value":"above","why":"ok","watch":"w","bounty":"4000000","commit":"c-up"}\n' "$CIADDR_UP"
  printf '{"target":"%s","chain":"1","label":"lower","qualifies":true,"family":"amm","value":"above","why":"ok","watch":"w","bounty":"1000000","commit":"c-lo"}\n' "$CIADDR_LO"
} > "$CIDUP"
"$RUN" --dossiers "$CIDUP" --out "$WORK/ci.queue" >/dev/null 2>&1
ci_rows="$(grep -ic "0xab00000000000000000000000000000000000099" "$WORK/ci.queue" 2>/dev/null || true)"
ci_score="$(head -1 "$WORK/ci.queue" | cut -f1)"
if [ "${ci_rows:-0}" -eq 1 ] && [ "$ci_score" = "4000000" ]; then
  pass "same address under two casings deduped to one row, highest bounty kept (score=$ci_score)"
else
  fail "case-insensitive dedup wrong: $ci_rows row(s), score [$ci_score]"
fi

# --- 13. Equal bounty -> deterministic tie-break by key ASC -----------------------------------------------
TA='0x6000000000000000000000000000000000000000'
TB='0x7000000000000000000000000000000000000000'
TIE="$WORK/tie.jsonl"
{
  printf '{"target":"%s","chain":"1","label":"B","qualifies":true,"family":"amm","value":"above","why":"ok","watch":"w","bounty":"1000000","commit":"cb"}\n' "$TB"
  printf '{"target":"%s","chain":"1","label":"A","qualifies":true,"family":"amm","value":"above","why":"ok","watch":"w","bounty":"1000000","commit":"ca"}\n' "$TA"
} > "$TIE"
"$RUN" --dossiers "$TIE" --out "$WORK/tie.queue" >/dev/null 2>&1
tie_keys="$(cut -f2 "$WORK/tie.queue" | tr '\n' ' ')"
[ "$tie_keys" = "prospector:$TA prospector:$TB " ] \
  && pass "equal bounty -> deterministic tie-break by key ASC ($tie_keys)" \
  || fail "tie-break wrong: [$tie_keys]"

# --- 14. Non-numeric / negative bounty -> treated as 0 (still listed, ranked last) ------------------------
TN='0x9000000000000000000000000000000000000000'
TG='0x9a00000000000000000000000000000000000000'
NUM="$WORK/nonnum.jsonl"
{
  printf '{"target":"%s","chain":"1","label":"Garbled","qualifies":true,"family":"amm","value":"above","why":"ok","watch":"w","bounty":"not-a-number","commit":"cg"}\n' "$TN"
  printf '{"target":"%s","chain":"1","label":"Good","qualifies":true,"family":"amm","value":"above","why":"ok","watch":"w","bounty":"500000","commit":"cok"}\n' "$TG"
} > "$NUM"
"$RUN" --dossiers "$NUM" --out "$WORK/num.queue" >/dev/null 2>&1
last_line="$(tail -1 "$WORK/num.queue")"
if [ "$(printf '%s' "$last_line" | cut -f1)" = "0" ] && [ "$(printf '%s' "$last_line" | cut -f2)" = "prospector:$TN" ]; then
  pass "non-numeric bounty -> score 0, still listed and ranked last"
else
  fail "non-numeric bounty handling wrong; last row: [$last_line]"
fi

# --- 15. TSV field-safety: an embedded newline/tab in a field never breaks the 5-column layout ------------
TSVADDR='0x8000000000000000000000000000000000000000'
TSV="$WORK/tsv.jsonl"
printf '{"target":"%s","chain":"1","label":"Multi\\nLine Vault","qualifies":true,"family":"amm","value":"above","why":"ok","watch":"w","bounty":"700000","commit":"c\\tsafe"}\n' "$TSVADDR" > "$TSV"
"$RUN" --dossiers "$TSV" --out "$WORK/tsv.queue" >/dev/null 2>&1
bad_cols="$(awk -F'\t' 'NF!=5{c++} END{print c+0}' "$WORK/tsv.queue")"
tsv_rows="$(grep -c . "$WORK/tsv.queue" 2>/dev/null || true)"
if [ "$bad_cols" = "0" ] && [ "${tsv_rows:-0}" -eq 1 ]; then
  pass "embedded newline/tab scrubbed -> exactly 5 TSV columns, one row"
else
  fail "TSV field-safety wrong: $bad_cols malformed rows, $tsv_rows total"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "demo-prospector-queue.sh: ALL CHECKS PASSED"
  exit 0
else
  echo "demo-prospector-queue.sh: FAILURES ABOVE" >&2
  exit 1
fi
