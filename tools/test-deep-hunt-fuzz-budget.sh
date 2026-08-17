#!/usr/bin/env bash
# tools/test-deep-hunt-fuzz-budget.sh -- deterministic offline guard for the FM-A milestone
# (dark-factory, agentis-colonies#1939 M1): operator-settable Forge invariant fuzz budget
# forwarded through run-zone-hunt.sh's deep-hunt engine.
#
# run-zone-hunt.sh's DEEP_FWD is a THIN pass-through: flags collected verbatim into an array
# and spliced onto BOTH --deep-hunt run-invariant-hunt.sh invocations. This adds two more
# entries to that array -- `--deep-hunt-runs <N>` -> `--runs <N>` and `--deep-hunt-depth <N>`
# -> `--depth <N>` -- so an operator can FIT a gas-heavy target's fuzz campaign inside the
# existing gate ceiling (exec.default_timeout_ms, run-invariant-hunt.sh:573, deliberately left
# untouched) instead of raising the ceiling itself. run-invariant-hunt.sh already accepts
# --runs/--depth and exports them as INV_RUNS/INV_DEPTH into the prover's env.
#
# Offline by construction: the pipeline is driven through the --map-fixture / --brief-fixture
# / --pass-fixture / --invariant-fixture seams plus the #1713 deep-hunt fixture's --agentis
# stub (wrapped here to capture the env the prover actually sees). No LLM, no forge, no
# network. Auto-discovered and run by tools/colony-lint.sh's `tools/test-*.sh` loop.
#
# Assertions:
#   (a) SOURCE GUARD: both DEEP_FWD parse cases exist in run-zone-hunt.sh, and
#       ${DEEP_FWD[@]+"${DEEP_FWD[@]}"} still appears at exactly 2 call sites (both
#       --deep-hunt $INVHUNT invocations).
#   (b) BEHAVIOURAL FORWARDING: --deep-hunt-runs 32 --deep-hunt-depth 8 reaches the prover's
#       env as INV_RUNS=32 / INV_DEPTH=8 -- captured via a wrapper --agentis stub that, on the
#       `go invariant-prover.ag` branch, records "${INV_RUNS:-}|${INV_DEPTH:-}" before
#       delegating to the real fixture stub.
#   (c) BYTE-IDENTICAL DEFAULT: the same run WITHOUT the two flags captures "|" (both empty),
#       proving no --runs/--depth is injected into $INVHUNT when the flags are absent.
#
# Usage: bash tools/test-deep-hunt-fuzz-budget.sh
# Exit: 0 = held, 1 = regressed, 3 = missing prerequisite.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZONEHUNT="$REPO_ROOT/dark-factory/run-zone-hunt.sh"
FIX="$REPO_ROOT/dark-factory/bench/corpus-bench/fixtures/deep-hunt"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

summary_exit() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
}

[ -x "$ZONEHUNT" ] || { echo "[SKIP] run-zone-hunt.sh not found/executable: $ZONEHUNT" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "[SKIP] git not installed" >&2; exit 0; }
for f in foundry.toml zones.fixture.txt briefs.fixture.txt handler-fixture.t.sol agentis-stub.sh; do
    [ -f "$FIX/$f" ] || { echo "[SKIP] deep-hunt fixture missing: $FIX/$f" >&2; exit 3; }
done

# ----------------------------------------------------------------------------------------------------------
# (a) source guard -- the two DEEP_FWD parse cases exist, and the splice point is still exactly 2 call sites.
# ----------------------------------------------------------------------------------------------------------
a_fail=""
# shellcheck disable=SC2016  # matching the literal argv lines below, $ must not expand
grep -q -- 'DEEP_FWD+=(--runs "\$2")' "$ZONEHUNT" || a_fail="${a_fail} no-runs-parse-arm"
# shellcheck disable=SC2016
grep -q -- 'DEEP_FWD+=(--depth "\$2")' "$ZONEHUNT" || a_fail="${a_fail} no-depth-parse-arm"
# shellcheck disable=SC2016
SPLICE_COUNT="$(grep -c -- '${DEEP_FWD\[@\]+"${DEEP_FWD\[@\]}"}' "$ZONEHUNT")"
[ "$SPLICE_COUNT" -eq 2 ] || a_fail="${a_fail} splice-count=${SPLICE_COUNT}-want-2"
if [ -z "$a_fail" ]; then
    pass "(a) run-zone-hunt.sh parses --deep-hunt-runs/--deep-hunt-depth into DEEP_FWD, spliced at exactly 2 call sites"
else
    fail "(a) --deep-hunt-runs/--deep-hunt-depth source wiring" "missing piece(s):$a_fail"
fi

# ----------------------------------------------------------------------------------------------------------
# Offline target: the #1713 deep-hunt fixture, consumed READ-ONLY.
# ----------------------------------------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/deep-hunt-fuzz-budget.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/target"
mkdir -p "$REPO"
cp "$FIX/foundry.toml" "$REPO/foundry.toml"
cp -R "$FIX/src" "$REPO/src"
git -C "$REPO" init -q
git -C "$REPO" config user.email demo@example.invalid
git -C "$REPO" config user.name "demo"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "deep-hunt-fuzz-budget fixture target"

STUB="$WORK/agentis-stub"
cp "$FIX/agentis-stub.sh" "$STUB"; chmod +x "$STUB"

# A wrapper --agentis stub: on the `go invariant-prover.ag` branch it appends the env the prover would see
# ("${INV_RUNS:-}|${INV_DEPTH:-}") to CAPTURE_FILE (set per-run below), then execs the real fixture stub for
# every subcommand (breadth, refuter, coordinator, memo, init, AND invariant-prover.ag itself) -- so the
# fuzzer verdict / merge behaviour is unchanged from the composable-lens fixture path.
WRAPPER="$WORK/agentis-wrapper"
cat > "$WRAPPER" <<WRAPEOF
#!/bin/sh
set -u
if [ "\${1:-}" = "go" ] && [ "\${2:-}" = "invariant-prover.ag" ] && [ -n "\${CAPTURE_FILE:-}" ]; then
  printf '%s\n' "\${INV_RUNS:-}|\${INV_DEPTH:-}" >> "\$CAPTURE_FILE"
fi
exec "$STUB" "\$@"
WRAPEOF
chmod +x "$WRAPPER"

# One shared breadth pass, then the STAGE 4.5 lens over two clones of it (the #1774 --deep-hunt-only seam), so
# the WITH-flags and WITHOUT-flags runs differ in EXACTLY the two flags under test.
BASE="$WORK/base"
"$ZONEHUNT" --repo "$REPO" --out "$BASE" --drop-dir "$BASE/drop" --scope-hint src \
    --backend mock --agentis "$STUB" \
    --map-fixture "$FIX/zones.fixture.txt" --brief-fixture "$FIX/briefs.fixture.txt" \
    --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
    --in-scope "the whole in-scope program" >"$WORK/base.log" 2>&1
BASE_RC=$?
if [ "$BASE_RC" -ne 0 ]; then
    fail "breadth baseline" "run-zone-hunt.sh breadth run exited $BASE_RC (see log tail below)"
    tail -20 "$WORK/base.log" | sed 's/^/      /' >&2
    summary_exit
fi

deep_hunt_only() {  # $1 = out dir (a clone of the breadth base), $2 = capture file, $3.. = extra flags
    _out="$1"; _capture="$2"; shift 2
    CAPTURE_FILE="$_capture" "$ZONEHUNT" --repo "$REPO" --out "$_out" --deep-hunt --deep-hunt-only \
        --invariant-fixture "$FIX/handler-fixture.t.sol" \
        --backend mock --agentis "$WRAPPER" "$@" >"$_out.log" 2>&1
}

# ----------------------------------------------------------------------------------------------------------
# (b) BEHAVIOURAL FORWARDING: --deep-hunt-runs 32 --deep-hunt-depth 8 reaches the prover as INV_RUNS=32/INV_DEPTH=8.
# ----------------------------------------------------------------------------------------------------------
OUT_WITH="$WORK/with"; cp -R "$BASE" "$OUT_WITH"
CAP_WITH="$WORK/capture-with.txt"
deep_hunt_only "$OUT_WITH" "$CAP_WITH" --deep-hunt-runs 32 --deep-hunt-depth 8
WITH_RC=$?
if [ "$WITH_RC" -ne 0 ] || [ ! -f "$CAP_WITH" ]; then
    fail "(b) --deep-hunt-runs/--deep-hunt-depth run" "exit $WITH_RC, capture present: $([ -f "$CAP_WITH" ] && echo yes || echo no)"
    tail -20 "$OUT_WITH.log" | sed 's/^/      /' >&2
else
    CAP_WITH_VAL="$(cat "$CAP_WITH")"
    if [ "$CAP_WITH_VAL" = "32|8" ]; then
        pass "(b) --deep-hunt-runs 32 --deep-hunt-depth 8 reaches the prover's env as INV_RUNS=32/INV_DEPTH=8"
    else
        fail "(b) fuzz budget forwarded to the prover env" "captured '$CAP_WITH_VAL', want '32|8'"
    fi
fi

# ----------------------------------------------------------------------------------------------------------
# (c) BYTE-IDENTICAL DEFAULT: the same run WITHOUT the two flags captures "|" -- no --runs/--depth injected.
# ----------------------------------------------------------------------------------------------------------
OUT_WITHOUT="$WORK/without"; cp -R "$BASE" "$OUT_WITHOUT"
CAP_WITHOUT="$WORK/capture-without.txt"
deep_hunt_only "$OUT_WITHOUT" "$CAP_WITHOUT"
WITHOUT_RC=$?
if [ "$WITHOUT_RC" -ne 0 ] || [ ! -f "$CAP_WITHOUT" ]; then
    fail "(c) default (no fuzz-budget flags) run" "exit $WITHOUT_RC, capture present: $([ -f "$CAP_WITHOUT" ] && echo yes || echo no)"
    tail -20 "$OUT_WITHOUT.log" | sed 's/^/      /' >&2
else
    CAP_WITHOUT_VAL="$(cat "$CAP_WITHOUT")"
    if [ "$CAP_WITHOUT_VAL" = "|" ]; then
        pass "(c) absent --deep-hunt-runs/--deep-hunt-depth => the prover env is INV_RUNS=/INV_DEPTH= (byte-identical to today)"
    else
        fail "(c) default-OFF byte-identity" "captured '$CAP_WITHOUT_VAL', want '|'"
    fi
fi

summary_exit
