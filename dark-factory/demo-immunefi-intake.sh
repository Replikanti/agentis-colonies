#!/usr/bin/env bash
# demo-immunefi-intake.sh — OFFLINE, DETERMINISTIC proof (#1506, epic #1505) of BOTH new discovery primitives,
# following demo-audit-hunter.sh's "two cooperating shell primitives -> one demo" precedent:
#
#   1. audit-delta.sh   — over a throwaway `git init` fixture (an "audit-covered" tag + later commits): asserts
#                         DELTA (only the post-audit-changed file surfaces, not the untouched one), NO-DELTA on
#                         the since==HEAD edge, the --paths in-scope intersection, and the exit-3 guards on a
#                         bad --repo (non-git dir) and a bad --since (nonexistent ref).
#   2. run-immunefi-intake.sh — over an operator-programs fixture JSON: asserts the paused program is dropped
#                         (freshness), the exact rank order (delta-boosted > big-reward-NO-DELTA > low-reward-
#                         bounty-only), that a NO-DELTA program earns no bonus despite a big reward, that a
#                         program with no local_repo still ranks by bounty alone, and file==stdout parity.
#
# No network, no agentis, no LLM — a pure transform over a throwaway git fixture + a fixture JSON. Mirrors the
# other dark-factory demo-*.sh (assert-based PASS/FAIL lines, temp dirs trap-cleaned, exit non-zero on failure).
#
# Usage:  dark-factory/demo-immunefi-intake.sh
# Requires: git + python3 (the floor for both primitives). Exit: 0 = all assertions held; non-zero = a failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DELTA="$HERE/audit-delta.sh"
INTAKE="$HERE/run-immunefi-intake.sh"

FAILS=0
note() { echo "demo-immunefi-intake.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
[ -x "$DELTA" ]  || { note "audit-delta.sh not found / not executable: $DELTA" >&2; exit 3; }
[ -x "$INTAKE" ] || { note "run-immunefi-intake.sh not found / not executable: $INTAKE" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-immunefi.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# jget: extract a field from a JSON object on stdin (deterministic, no jq dependency).
jget() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get(sys.argv[1]))' "$1"; }

# ----------------------------------------------------------------------------------------------------------
# Build the throwaway git fixture: an initial commit (Vault.sol + Oracle.sol) tagged `audit-commit` as the
# "audit-covered" version, then a later commit touching ONLY Vault.sol (the post-audit delta; Oracle.sol stays
# untouched). Deterministic, self-contained — no clone, no network.
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/target"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email demo@example.invalid
git -C "$REPO" config user.name "demo"
printf 'contract Vault {}\n'  > "$REPO/Vault.sol"
printf 'contract Oracle {}\n' > "$REPO/Oracle.sol"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "initial audited version"
git -C "$REPO" tag audit-commit
printf 'contract Vault { uint patched; }\n' > "$REPO/Vault.sol"   # the post-audit delta (Vault.sol only)
git -C "$REPO" add -A
git -C "$REPO" commit -qm "post-audit change to Vault"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

note "1) audit-delta.sh over the fixture (offline git diff) ..."

# DELTA: only Vault.sol changed since the audit tag; Oracle.sol untouched.
DJSON="$("$DELTA" --repo "$REPO" --since audit-commit 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "audit-delta exits 0 on a clean DELTA read" || bad "audit-delta exited $RC on DELTA (expected 0)"
[ "$(printf '%s' "$DJSON" | jget verdict)" = "DELTA" ] \
  && ok "verdict=DELTA when files changed since the audit tag" || bad "verdict was not DELTA: $DJSON"
[ "$(printf '%s' "$DJSON" | jget files_changed)" = "1" ] \
  && ok "files_changed==1 (only the post-audit file)" || bad "files_changed != 1: $DJSON"
CF="$(printf '%s' "$DJSON" | python3 -c 'import sys,json; print(",".join(json.load(sys.stdin).get("changed_files",[])))')"
[ "$CF" = "Vault.sol" ] \
  && ok "changed_files == [Vault.sol] exactly (not Oracle.sol)" || bad "changed_files mismatch: got [$CF]"

# NO-DELTA: since==HEAD is the empty-diff edge case (must not crash).
NJSON="$("$DELTA" --repo "$REPO" --since HEAD 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "audit-delta exits 0 on the since==HEAD edge (no crash)" || bad "audit-delta exited $RC on since==HEAD"
[ "$(printf '%s' "$NJSON" | jget verdict)" = "NO-DELTA" ] \
  && ok "verdict=NO-DELTA when since==HEAD" || bad "verdict was not NO-DELTA: $NJSON"
[ "$(printf '%s' "$NJSON" | jget files_changed)" = "0" ] \
  && ok "files_changed==0 on since==HEAD" || bad "files_changed != 0: $NJSON"

# --paths intersection: scope only Oracle.sol -> the Vault.sol delta filters to empty.
printf 'Oracle.sol\n' > "$WORK/scope.txt"
PJSON="$("$DELTA" --repo "$REPO" --since audit-commit --paths "$WORK/scope.txt" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "audit-delta exits 0 with a --paths filter" || bad "audit-delta exited $RC with --paths"
[ "$(printf '%s' "$PJSON" | jget verdict)" = "NO-DELTA" ] \
  && ok "--paths=Oracle.sol filters the Vault.sol delta to empty (in-scope intersection works)" \
  || bad "--paths intersection did not filter to empty: $PJSON"

# exit-3 guards: a non-git dir and a nonexistent ref must both exit 3 (loud, never a silent empty delta / crash).
"$DELTA" --repo "$WORK" --since HEAD >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && ok "bad --repo (non-git dir) -> exit 3" || bad "bad --repo did not exit 3 (rc=$RC)"
"$DELTA" --repo "$REPO" --since deadbeefnope >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && ok "bad --since (nonexistent ref) -> exit 3" || bad "bad --since did not exit 3 (rc=$RC)"
"$DELTA" --repo "$REPO" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "missing --since -> exit 2 (bad-args band)" || bad "missing --since did not exit 2 (rc=$RC)"

# ----------------------------------------------------------------------------------------------------------
# Operator-programs fixture. Designed scores (bounty_term + delta_term; see run-immunefi-intake.sh SCORE):
#   delta-boost : active, $500k, local_repo=fixture, in_scope_commit=audit-commit -> fresh 1-file DELTA -> TOP
#                 (bounty ~57 + delta ~21 = ~78)
#   no-delta    : active, $500k, local_repo=fixture, in_scope_commit=HEAD -> NO-DELTA, NO bonus despite the big
#                 reward (bounty ~57 + 0 = ~57)
#   bounty-only : active, $20k, NO local_repo -> ranks by bounty alone (bounty ~43 + 0 = ~43)
#   paused      : status=paused, the BIGGEST reward ($50M) -> DROPPED by freshness (its absence is a strong
#                 assertion: it would top the queue if the filter failed)
# ----------------------------------------------------------------------------------------------------------
note "2) run-immunefi-intake.sh over the operator-programs fixture (offline, no live fetch) ..."
PROGRAMS="$WORK/programs.json"
cat > "$PROGRAMS" <<JSON
[
  {"id":"delta-boost","name":"Delta Boost Protocol","url":"https://immunefi.com/bug-bounty/deltaboost/","chain":"ethereum","asset_repo":"https://github.com/example/deltaboost","in_scope_commit":"audit-commit","reward_max_usd":500000,"submission_fee_usd":10,"vault_usd":40000,"status":"active","local_repo":"$REPO"},
  {"id":"no-delta","name":"No Delta Protocol","url":"https://immunefi.com/bug-bounty/nodelta/","chain":"ethereum","asset_repo":"https://github.com/example/nodelta","in_scope_commit":"$HEAD_SHA","reward_max_usd":500000,"submission_fee_usd":10,"vault_usd":25000,"status":"active","local_repo":"$REPO"},
  {"id":"bounty-only","name":"Bounty Only Protocol","url":"https://immunefi.com/bug-bounty/bountyonly/","chain":"arbitrum","reward_max_usd":20000,"status":"active"},
  {"id":"paused-huge","name":"Paused Huge Protocol","url":"https://immunefi.com/bug-bounty/pausedhuge/","chain":"ethereum","reward_max_usd":50000000,"status":"paused"}
]
JSON

DFD="$WORK/dark-factory"   # temp DARK_FACTORY_DIR (immunefi.queue lives here, never the real ~/.dark-factory)
mkdir -p "$DFD"
QUEUE_OUT="$(DARK_FACTORY_DIR="$DFD" "$INTAKE" --programs "$PROGRAMS" 2>/dev/null)"; RC=$?
echo "----- ranked queue -----"
printf '%s\n' "$QUEUE_OUT" | sed 's/^/    /'
echo "------------------------"

[ "$RC" -eq 0 ] && ok "run-immunefi-intake exits 0 on the offline --programs path" || bad "intake exited $RC (expected 0)"

KEYS="$(printf '%s\n' "$QUEUE_OUT" | awk -F'\t' 'NF>=2{print $2}')"
SCORES="$(printf '%s\n' "$QUEUE_OUT" | awk -F'\t' 'NF>=1{print $1}')"
has_key() { printf '%s\n' "$KEYS" | grep -qxF "$1"; }

# FRESHNESS: the paused program (biggest reward) is dropped — its mere absence is a strong assertion.
if has_key "immunefi:paused-huge"; then bad "freshness FAILED: 'immunefi:paused-huge' (status paused) is in the queue"
else ok "freshness: the paused program 'immunefi:paused-huge' (biggest reward) is absent"; fi

# The three active programs must all survive.
ALL=1
for k in immunefi:delta-boost immunefi:no-delta immunefi:bounty-only; do
  has_key "$k" || { bad "expected active survivor '$k' missing from the queue"; ALL=0; }
done
[ "$ALL" -eq 1 ] && ok "all three active programs are present"

# Ranked by score DESCENDING (non-increasing top to bottom).
if [ -n "$SCORES" ] && printf '%s\n' "$SCORES" | awk 'NR>1 && $1>prev{exit 1} {prev=$1}'; then
  ok "queue is ranked by score descending: $(printf '%s' "$SCORES" | tr '\n' ' ')"
else
  bad "queue is NOT sorted by score descending: $(printf '%s' "$SCORES" | tr '\n' ' ')"
fi

# Exact rank order: delta-boosted > big-reward-NO-DELTA > low-reward-bounty-only.
EXPECTED=$'immunefi:delta-boost\nimmunefi:no-delta\nimmunefi:bounty-only'
if [ "$KEYS" = "$EXPECTED" ]; then
  ok "exact rank order matches the documented scoring (delta-boost > no-delta > bounty-only)"
else
  bad "rank order mismatch — got:"; printf '%s\n' "$KEYS" | sed 's/^/        /'
  note "expected:"; printf '%s\n' "$EXPECTED" | sed 's/^/        /'
fi

# NO-DELTA earns no bonus: delta-boost and no-delta carry the SAME reward, so the ONLY score gap is the delta
# bonus — assert delta-boost strictly outscores no-delta (the residual-surface signal is doing real work).
DB_SCORE="$(printf '%s\n' "$QUEUE_OUT" | awk -F'\t' '$2=="immunefi:delta-boost"{print $1}')"
ND_SCORE="$(printf '%s\n' "$QUEUE_OUT" | awk -F'\t' '$2=="immunefi:no-delta"{print $1}')"
if [ -n "$DB_SCORE" ] && [ -n "$ND_SCORE" ] && [ "$DB_SCORE" -gt "$ND_SCORE" ]; then
  ok "the fresh-delta program outscores the NO-DELTA program at equal reward ($DB_SCORE > $ND_SCORE) — no bonus for NO-DELTA"
else
  bad "delta bonus not reflected: delta-boost=$DB_SCORE vs no-delta=$ND_SCORE (expected delta-boost strictly higher)"
fi

# The bounty-only program (no local_repo) must still rank — its delta:0 packed into scope_hint, bounty-only score.
BO_SCOPE="$(printf '%s\n' "$QUEUE_OUT" | awk -F'\t' '$2=="immunefi:bounty-only"{print $5}')"
case "$BO_SCOPE" in
  *"delta:0f/-d"*) ok "a program with no local_repo ranks by bounty alone (delta:0f/-d, no crash)";;
  *) bad "bounty-only scope_hint did not carry a zero delta: [$BO_SCOPE]";;
esac

# The queue FILE must equal the stdout view (the tool writes both).
if [ "$(cat "$DFD/immunefi.queue" 2>/dev/null)" = "$QUEUE_OUT" ]; then
  ok "the immunefi.queue file equals the stdout view"
else
  bad "the immunefi.queue file differs from stdout"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: audit-delta.sh surfaced the post-audit delta (Vault.sol, not the untouched Oracle.sol), handled the"
  note "      since==HEAD / --paths / bad-repo / bad-since edges exactly, and run-immunefi-intake.sh ranked the"
  note "      operator-programs file by bounty + delta — the paused program dropped, the fresh-delta program"
  note "      outscored an equal-reward NO-DELTA one, and file==stdout. Offline + deterministic; never submits."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
