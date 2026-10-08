#!/usr/bin/env bash
# demo-deep-hunt-audit-context.sh — run-zone-hunt.sh --deep-hunt-audit-context <file> reaches EVERY STAGE 4.5
# cell as run-invariant-hunt.sh --audit-context (#1722), so an operator can steer the deep prover with
# target-specific audit leads (prior-audit fix list, design invariants) instead of only the per-lens defaults.
#
# Offline (mock backend + the shipped #1713 deep-hunt fixture + --invariant-fixture). Asserts:
#   a) with the flag, the cell's rundir holds audit-context.txt byte-identical to the operator file;
#   b) without the flag, no audit-context.txt is staged (absent => byte-identical to before);
#   c) a missing file is a usage error (exit 2) before any stage runs;
#   d) a RELATIVE path still resolves (the cell runs from another cwd).
# Never submits anything.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ZONEHUNT="$HERE/run-zone-hunt.sh"
DEEP_FIX="$HERE/bench/corpus-bench/fixtures/deep-hunt"

FAILS=0
note() { echo "demo-deep-hunt-audit-context.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
[ -x "$ZONEHUNT" ] || { note "run-zone-hunt.sh not found / not executable: $ZONEHUNT" >&2; exit 3; }
for f in foundry.toml briefs.fixture.txt handler-fixture.t.sol agentis-stub.sh; do
  [ -f "$DEEP_FIX/$f" ] || { note "deep-hunt fixture missing: $DEEP_FIX/$f" >&2; exit 3; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-deep-audit-ctx.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Isolate the hunt registry so this demo never writes into a live operator's ~/.dark-factory/hunts.
export DARK_FACTORY_DIR="$WORK"

DREPO="$WORK/deep-target"
mkdir -p "$DREPO"
cp "$DEEP_FIX/foundry.toml" "$DREPO/foundry.toml"
cp -R "$DEEP_FIX/src" "$DREPO/src"
git -C "$DREPO" init -q
git -C "$DREPO" config user.email demo@example.invalid
git -C "$DREPO" config user.name "demo"
git -C "$DREPO" add -A
git -C "$DREPO" commit -qm "audit-context fixture target"

DZONES="$WORK/zones.fixture.txt"
cat > "$DZONES" <<'FIX'
ZONE|src|value vault|C10|deposit/withdraw accounting
ZONE|src_periphery|views|C1|read-only view helpers, no value custody
CUSTODY|src|true
CUSTODY|src_periphery|false
FIX

DSTUB="$WORK/deep-agentis-stub"
cp "$DEEP_FIX/agentis-stub.sh" "$DSTUB"; chmod +x "$DSTUB"

CTX="$WORK/leads.txt"
printf 'RESIDUAL|vault|C10|fix may be bypassable via liquidate()|sketch: a second entry point skips the new check\n' > "$CTX"

# c) a missing file fails fast.
"$ZONEHUNT" --repo "$DREPO" --out "$WORK/missing" --deep-hunt --deep-hunt-audit-context "$WORK/nope.txt" \
  >"$WORK/missing.log" 2>&1
rc=$?
if [ "$rc" -eq 2 ] && grep -q -- "--deep-hunt-audit-context not found" "$WORK/missing.log"; then
  ok "c) a missing --deep-hunt-audit-context file is a usage error (exit 2)"
else
  bad "c) a missing file exited $rc (want 2 + 'not found')"
fi

DBASE="$WORK/deep-base"
"$ZONEHUNT" --repo "$DREPO" --out "$DBASE" --drop-dir "$DBASE/drop" --scope-hint src \
  --backend mock --agentis "$DSTUB" \
  --map-fixture "$DZONES" --brief-fixture "$DEEP_FIX/briefs.fixture.txt" \
  --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
  --in-scope "the whole in-scope program" >"$WORK/deep-base.log" 2>&1 \
  || { bad "the breadth baseline exited non-zero"; tail -15 "$WORK/deep-base.log" | sed 's/^/      /' >&2; }

lens_only() {  # $1 = out dir (a clone of the breadth base), $2.. = extra flags
  lo_out="$1"; shift
  cp -R "$DBASE" "$lo_out"
  "$ZONEHUNT" --repo "$DREPO" --out "$lo_out" --deep-hunt --deep-hunt-only \
    --invariant-fixture "$DEEP_FIX/handler-fixture.t.sol" \
    --backend mock --agentis "$DSTUB" "$@" >"$lo_out.log" 2>&1
}

staged() { find "$1/deep-hunt" -path '*/run/audit-context.txt' 2>/dev/null | head -1; }

# a) flag present -> staged verbatim.
lens_only "$WORK/on" --deep-hunt-audit-context "$CTX"; ON_RC=$?
S="$(staged "$WORK/on")"
if [ "$ON_RC" -eq 0 ] && [ -n "$S" ] && cmp -s "$S" "$CTX"; then
  ok "a) the cell rundir holds audit-context.txt byte-identical to the operator file"
else
  bad "a) audit context not staged (rc=$ON_RC, staged='${S:-none}')"; tail -15 "$WORK/on.log" | sed 's/^/      /' >&2
fi

# b) flag absent -> nothing staged.
lens_only "$WORK/off"; OFF_RC=$?
if [ "$OFF_RC" -eq 0 ] && [ -z "$(staged "$WORK/off")" ]; then
  ok "b) without the flag no audit-context.txt is staged"
else
  bad "b) flagless run rc=$OFF_RC or staged an audit context"
fi

# d) a relative path resolves.
( cd "$WORK" && lens_only "$WORK/rel" --deep-hunt-audit-context "leads.txt" ); REL_RC=$?
S="$(staged "$WORK/rel")"
if [ "$REL_RC" -eq 0 ] && [ -n "$S" ] && cmp -s "$S" "$CTX"; then
  ok "d) a relative --deep-hunt-audit-context path is resolved before the cell runs"
else
  bad "d) relative path not staged (rc=$REL_RC)"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: --deep-hunt-audit-context reaches every deep-hunt cell; absent it is inert. Offline; never submits."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
