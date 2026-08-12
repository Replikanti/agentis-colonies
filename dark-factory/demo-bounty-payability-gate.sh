#!/usr/bin/env bash
# demo-bounty-payability-gate.sh — OFFLINE, DETERMINISTIC proof (#1897, epic #1894 M1) of bounty-payability-gate.sh:
# a queue -> queue filter that drops rows whose Medium/High reward is a CONFIRMED $0. Mirrors demo-immunefi-
# intake.sh's assert-based [PASS]/[FAIL] accounting; a throwaway fixture queue + a fixture raw-bounties array +
# a fixture __NEXT_DATA__ page, never touching the real ~/.dark-factory. No network, no agentis, no LLM.
#
# Asserts:
#   AC1 — a program whose rewardsBody confirms Medium/High == $0 (only Critical mentioned) is DROPPED; a
#         program with a real Medium/High >= the floor is KEPT.
#   AC2 — a program with NO rewardsBody hits but a --page __NEXT_DATA__ fixture carrying a Medium reward is
#         resolved from that fixture and kept/dropped correctly against the floor.
#   AC3 — a queue row with no reward source at all (no matching --bounties entry, no --page, no --table) is
#         fail-open KEPT UNCHANGED.
#   AC4 — with no reward source supplied at all, the script [SKIP]s, exits 0, and leaves --out unwritten.
#   AC5 — surviving rows stay a valid 5-col TSV; columns 1/3/4/5 are byte-identical to the input queue (only
#         whole lines are ever removed, never rewritten).
#
# Usage:  dark-factory/demo-bounty-payability-gate.sh
# Requires: python3. Exit: 0 = all assertions held; non-zero = a failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/bounty-payability-gate.sh"

FAILS=0
note() { echo "demo-bounty-payability-gate.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
[ -x "$GATE" ] || { note "bounty-payability-gate.sh not found / not executable: $GATE" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-bounty-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# Fixture queue: 4 rows, the SAME 5-col shape run-immunefi-intake.sh emits.
#   zero-medium : rewardsBody mentions ONLY Critical -> Medium/High resolve to a CONFIRMED $0 -> DROP.
#   real-medium : rewardsBody mentions Medium $5,000 / High $25,000 -> both clear the $1000 floor -> KEEP.
#   page-only   : --bounties entry has an EMPTY rewardsBody, but a --page __NEXT_DATA__ fixture supplies
#                 Medium $6,000 -> KEEP (tier-2 resolution).
#   unresolved  : no matching --bounties entry at all, no --page, no --table -> fail-open KEEP unchanged.
# ----------------------------------------------------------------------------------------------------------
QUEUE="$WORK/queue.tsv"
{
  printf '80\timmunefi:zero-medium\thttps://immunefi.com/bug-bounty/zero-medium/\tZero Medium Co\tchain:ethereum repo:- commit:- delta:0f/-d fee:- vault:-\n'
  printf '70\timmunefi:real-medium\thttps://immunefi.com/bug-bounty/real-medium/\tReal Medium Co\tchain:ethereum repo:- commit:- delta:0f/-d fee:- vault:-\n'
  printf '65\timmunefi:page-only\thttps://immunefi.com/bug-bounty/page-only/\tPage Only Co\tchain:ethereum repo:- commit:- delta:0f/-d fee:- vault:-\n'
  printf '60\timmunefi:unresolved\thttps://immunefi.com/bug-bounty/unresolved/\tUnresolved Co\tchain:ethereum repo:- commit:- delta:0f/-d fee:- vault:-\n'
} > "$QUEUE"

BOUNTIES="$WORK/bounties.json"
python3 - "$BOUNTIES" <<'PY'
import json, sys
data = [
    {"slug": "zero-medium", "rewardsBody": "Critical: Up to USD $500,000. All other severities are out of scope."},
    {"slug": "real-medium", "rewardsBody": "Medium: Up to USD $5,000. High: Up to USD $25,000."},
    {"slug": "page-only", "rewardsBody": ""},
]
json.dump(data, open(sys.argv[1], "w"))
PY

PAGE="$WORK/page-only.html"
cat > "$PAGE" <<'HTML'
<html><head></head><body>
<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"bounty":{"rewards":[{"severity":"Medium","usdEquivalent":6000},{"severity":"High","usdEquivalent":0}]}}}}</script>
</body></html>
HTML

# ----------------------------------------------------------------------------------------------------------
note "1) --bounties + --page, floor=1000 (default) ..."
OUT1="$WORK/out1.tsv"
GATE_STDOUT="$("$GATE" --queue "$QUEUE" --bounties "$BOUNTIES" --page "immunefi:page-only=$PAGE" --out "$OUT1" 2>"$WORK/stderr1.txt")"
RC=$?
[ "$RC" -eq 0 ] && ok "exits 0 on a resolved gate run" || bad "exited $RC (expected 0)"

KEYS="$(printf '%s\n' "$GATE_STDOUT" | awk -F'\t' 'NF==5{print $2}')"
has_key() { printf '%s\n' "$KEYS" | grep -qxF "$1"; }

# AC1: zero-medium (confirmed $0 Medium/High) dropped; real-medium (real Medium/High) kept.
if has_key "immunefi:zero-medium"; then bad "AC1 FAILED: 'immunefi:zero-medium' (confirmed \$0 Medium/High) survived"
else ok "AC1: confirmed-\$0-Medium/High program 'immunefi:zero-medium' is dropped"; fi
if has_key "immunefi:real-medium"; then ok "AC1: real-Medium/High program 'immunefi:real-medium' is kept"
else bad "AC1 FAILED: 'immunefi:real-medium' (real Medium \$5k / High \$25k) was dropped"; fi

# AC2: page-only resolved via the --page __NEXT_DATA__ fixture (Medium $6,000 >= floor) -> kept.
if has_key "immunefi:page-only"; then ok "AC2: --page __NEXT_DATA__ fixture resolved Medium \$6,000 -> kept"
else bad "AC2 FAILED: 'immunefi:page-only' (Medium \$6,000 via --page) was dropped"; fi

# AC3: unresolved (no --bounties match, no --page, no --table) fail-open kept, row byte-unchanged.
if has_key "immunefi:unresolved"; then ok "AC3: unresolved row (no reward source matched) fail-open kept"
else bad "AC3 FAILED: 'immunefi:unresolved' (no reward source) was dropped — fail-open violated"; fi

ORIG_UNRESOLVED="$(awk -F'\t' '$2=="immunefi:unresolved"' "$QUEUE")"
OUT_UNRESOLVED="$(printf '%s\n' "$GATE_STDOUT" | awk -F'\t' '$2=="immunefi:unresolved"')"
[ "$ORIG_UNRESOLVED" = "$OUT_UNRESOLVED" ] \
  && ok "AC3: the unresolved row is byte-identical to its queue input" \
  || bad "AC3 FAILED: unresolved row was rewritten — got [$OUT_UNRESOLVED] want [$ORIG_UNRESOLVED]"

# Summary line lands on stderr (kept/dropped counts).
grep -q "kept" "$WORK/stderr1.txt" && ok "a kept/dropped summary is printed to stderr" \
  || bad "no kept/dropped summary found on stderr: $(cat "$WORK/stderr1.txt")"

# AC5: the OUT file equals the stdout view, and surviving rows keep the 5-col TSV shape unchanged: cols
# 1/3/4/5 for every SURVIVING key equal the corresponding column in the original queue (whole lines removed,
# never rewritten).
if [ "$(cat "$OUT1" 2>/dev/null)" = "$GATE_STDOUT" ]; then
  ok "the --out file equals the stdout view"
else
  bad "the --out file differs from stdout"
fi
FIELD_OK=1
if ! printf '%s\n' "$GATE_STDOUT" | awk -F'\t' 'NF!=5{exit 1}'; then FIELD_OK=0; fi
[ "$FIELD_OK" -eq 1 ] && ok "AC5: every surviving row is a valid 5-col TSV" \
  || bad "AC5 FAILED: a surviving row does not have exactly 5 columns"
UNCHANGED=1
while IFS=$'\t' read -r s key url name scope; do
  [ -n "$key" ] || continue
  orig="$(awk -F'\t' -v k="$key" '$2==k{print $1"\t"$3"\t"$4"\t"$5}' "$QUEUE")"
  got="$s	$url	$name	$scope"
  if [ "$orig" != "$got" ]; then UNCHANGED=0; note "row rewritten for $key: got [$got] want [$orig]"; fi
done <<EOF
$GATE_STDOUT
EOF
[ "$UNCHANGED" -eq 1 ] && ok "AC5: surviving rows' columns 1/3/4/5 are byte-identical to the input queue" \
  || bad "AC5 FAILED: at least one surviving row's non-key columns were rewritten"

# ----------------------------------------------------------------------------------------------------------
note "2) no reward source at all -> [SKIP], exit 0, --out unwritten ..."
OUT2="$WORK/out2.tsv"
SKIP_ERR="$("$GATE" --queue "$QUEUE" --out "$OUT2" 2>&1 1>/dev/null)"
RC=$?
[ "$RC" -eq 0 ] && ok "AC4: no-reward-source run exits 0" || bad "AC4 FAILED: exited $RC (expected 0)"
case "$SKIP_ERR" in
  *"[SKIP]"*) ok "AC4: a [SKIP] line is printed when no reward source is given";;
  *) bad "AC4 FAILED: no [SKIP] line found: $SKIP_ERR";;
esac
[ -e "$OUT2" ] && bad "AC4 FAILED: --out was written despite the [SKIP]" \
  || ok "AC4: --out is left unwritten on [SKIP]"

# ----------------------------------------------------------------------------------------------------------
note "3) empty / missing queue -> [SKIP], exit 0 (mirrors run-batch.sh's own SKIP contract) ..."
EMPTY_QUEUE="$WORK/empty.tsv"
: > "$EMPTY_QUEUE"
"$GATE" --queue "$EMPTY_QUEUE" --bounties "$BOUNTIES" >/dev/null 2>"$WORK/stderr3.txt"
RC=$?
[ "$RC" -eq 0 ] && ok "empty-queue run exits 0" || bad "empty-queue run exited $RC (expected 0)"
grep -q "\[SKIP\]" "$WORK/stderr3.txt" && ok "empty queue -> a [SKIP] line" || bad "no [SKIP] on an empty queue"

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: bounty-payability-gate.sh dropped the confirmed-\$0-Medium/High program, kept the real-Medium"
  note "      program and the --page-resolved program, fail-open kept the unresolved program byte-identical,"
  note "      [SKIP]'d cleanly with no reward source and on an empty queue, and every surviving row stayed a"
  note "      valid unchanged 5-col TSV. Offline + deterministic; never touches the real ~/.dark-factory."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
