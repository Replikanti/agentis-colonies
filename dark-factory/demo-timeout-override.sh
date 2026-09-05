#!/usr/bin/env bash
# demo-timeout-override.sh — regression guard for #2103: the per-cell/per-generation LLM timeout
# floor+cap in run-discovery.sh and run-invariant-hunt.sh are now env-overridable
# (DF_HUNT_TIMEOUT_{FLOOR,CAP}_MS / DF_GEN_TIMEOUT_{BASE,CAP}_MS) instead of hardcoded literals, so an
# operator whose lens cells need more than the 1800000ms (30 min) default can raise it without a source edit.
#
# Approved product decisions this guard pins (issue #2103 plan comment):
#   1) the FLOOR/BASE is overridable too, not just the cap;
#   2) a cap override MAY exceed the 1800000ms default UNRESTRICTED (no upper sanity ceiling — the
#      watchdog/exec_timeout stays the real backstop);
#   3) an invalid override (non-numeric, empty, or 0) FALLS BACK to the default with a `>&2` warning —
#      it does NOT abort the run (this is a safety-relevant env knob, not a CLI flag).
#
# Two layers (mirrors demo-discovery-fail-fast.sh):
#   1) SOURCE GUARD (always, CI-safe, pure grep): both scripts must read the four env vars via the
#      `${VAR:-default}` idiom with the documented defaults — pins the var names and defaults against drift.
#   2) ARITHMETIC GUARD (offline, no agentis/repo checkout needed — same "extracted BY LINE RANGE, never
#      copy-pasted" idiom demo-discovery-parallel.sh uses for hunter.ag blocks): the constant+validation
#      block and the timeout-computation block are extracted from each script BY CONTENT-ANCHORED LINE
#      RANGE (awk start/end pattern, not a hardcoded line number — survives unrelated edits above the
#      block) and `eval`'d in a subshell under controlled env + `HUNT_SRC_LOC`/`INV_AUX`/`_aux_idx`
#      combinations, asserting the resulting HUNT_TIMEOUT_MS / GEN_TIMEOUT_MS at VALUE level.
#
# NOTE on the floor/base-vs-cap clamp: the approved code clamps unconditionally — "$FLOOR -gt $CAP" raises
# the cap to the floor regardless of whether the floor or the cap is the one that moved. This means a cap
# override set BELOW the (possibly still-default) floor does not shrink the effective budget below the
# floor; the floor is a documented MINIMUM per-cell budget, so this is the safe interpretation, and the
# guard below asserts that value (this differs from the plan comment's own illustrative worked example,
# which glossed over the clamp firing on a cap-only override — see PR discussion).
#
# Read-only, offline, never-submit. Exit 0 = guard holds; 1 = a regression; 3 = missing script.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DISCOVERY="$HERE/run-discovery.sh"
INVARIANT="$HERE/run-invariant-hunt.sh"

FAILS=0
note() { echo "demo-timeout-override.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -x "$DISCOVERY" ] || { note "run-discovery.sh not found / not executable: $DISCOVERY" >&2; exit 3; }
[ -x "$INVARIANT" ] || { note "run-invariant-hunt.sh not found / not executable: $INVARIANT" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE GUARD (always): pin the four env-var names + their default values against drift.
# ----------------------------------------------------------------------------------------------------------
note "1) source-guard: env-override idiom + defaults pinned in both scripts ..."

check_pattern() {  # check_pattern <file> <label> <fixed-string pattern>
  if grep -qF "$3" "$1"; then
    ok "$2: found \`$3\`"
  else
    bad "$2: expected \`$3\` not found in $1"
  fi
}

check_pattern "$DISCOVERY" "run-discovery.sh HUNT_TIMEOUT_FLOOR" 'HUNT_TIMEOUT_FLOOR="${DF_HUNT_TIMEOUT_FLOOR_MS:-1200000}"'
check_pattern "$DISCOVERY" "run-discovery.sh HUNT_TIMEOUT_CAP"   'HUNT_TIMEOUT_CAP="${DF_HUNT_TIMEOUT_CAP_MS:-1800000}"'
check_pattern "$INVARIANT" "run-invariant-hunt.sh GEN_TIMEOUT_BASE" 'GEN_TIMEOUT_BASE="${DF_GEN_TIMEOUT_BASE_MS:-1200000}"'
check_pattern "$INVARIANT" "run-invariant-hunt.sh GEN_TIMEOUT_CAP"  'GEN_TIMEOUT_CAP="${DF_GEN_TIMEOUT_CAP_MS:-1800000}"'

# ----------------------------------------------------------------------------------------------------------
# 2) ARITHMETIC GUARD (offline): extract the live blocks BY CONTENT-ANCHORED LINE RANGE and eval them under
#    controlled env, asserting the resulting timeout value.
# ----------------------------------------------------------------------------------------------------------
note "2) arithmetic-guard: extracted blocks evaluated under controlled env + HUNT_SRC_LOC/INV_AUX ..."

extract_block() {  # extract_block <file> <start_regex> <end_regex>
  awk -v s="$2" -v e="$3" 'BEGIN{f=0} $0 ~ s {f=1} f{print} f && $0 ~ e {exit}' "$1"
}

DISCOVERY_BLOCK_A="$(extract_block "$DISCOVERY" '^HUNT_TIMEOUT_FLOOR=' 'raising the cap to the floor')"
DISCOVERY_BLOCK_B="$(extract_block "$DISCOVERY" '^HUNT_TIMEOUT_MS=\\$\\(\\(' 'HUNT_TIMEOUT_MS=\\$HUNT_TIMEOUT_CAP')"
INVARIANT_BLOCK_A="$(extract_block "$INVARIANT" '^GEN_TIMEOUT_BASE=' 'raising the cap to the base')"
INVARIANT_BLOCK_B="$(extract_block "$INVARIANT" '^GEN_TIMEOUT_MS=\\$GEN_TIMEOUT_BASE' '^fi$')"

if [ -z "$DISCOVERY_BLOCK_A" ] || [ -z "$DISCOVERY_BLOCK_B" ]; then
  bad "could not extract the timeout blocks from run-discovery.sh by content anchor (renamed/reshaped?)"
fi
if [ -z "$INVARIANT_BLOCK_A" ] || [ -z "$INVARIANT_BLOCK_B" ]; then
  bad "could not extract the timeout blocks from run-invariant-hunt.sh by content anchor (renamed/reshaped?)"
fi

# calc_discovery <floor override|-> <cap override|-> <HUNT_SRC_LOC> <warn-file>
calc_discovery() {
  (
    if [ "$1" = "-" ]; then unset DF_HUNT_TIMEOUT_FLOOR_MS 2>/dev/null || true; else DF_HUNT_TIMEOUT_FLOOR_MS="$1"; export DF_HUNT_TIMEOUT_FLOOR_MS; fi
    if [ "$2" = "-" ]; then unset DF_HUNT_TIMEOUT_CAP_MS 2>/dev/null || true; else DF_HUNT_TIMEOUT_CAP_MS="$2"; export DF_HUNT_TIMEOUT_CAP_MS; fi
    # shellcheck disable=SC2034  # consumed by DISCOVERY_BLOCK_B, which is eval'd (not statically visible)
    HUNT_SRC_LOC="$3"
    eval "$DISCOVERY_BLOCK_A"
    eval "$DISCOVERY_BLOCK_B"
    echo "$HUNT_TIMEOUT_MS"
  ) 2>"$4"
}

# calc_invariant <base override|-> <cap override|-> <INV_AUX non-empty?:0/1> <_aux_idx> <warn-file>
calc_invariant() {
  (
    if [ "$1" = "-" ]; then unset DF_GEN_TIMEOUT_BASE_MS 2>/dev/null || true; else DF_GEN_TIMEOUT_BASE_MS="$1"; export DF_GEN_TIMEOUT_BASE_MS; fi
    if [ "$2" = "-" ]; then unset DF_GEN_TIMEOUT_CAP_MS 2>/dev/null || true; else DF_GEN_TIMEOUT_CAP_MS="$2"; export DF_GEN_TIMEOUT_CAP_MS; fi
    # shellcheck disable=SC2034  # consumed by INVARIANT_BLOCK_B, which is eval'd (not statically visible)
    if [ "$3" = "1" ]; then INV_AUX="present"; else INV_AUX=""; fi
    _aux_idx="$4"
    eval "$INVARIANT_BLOCK_A"
    eval "$INVARIANT_BLOCK_B"
    echo "$GEN_TIMEOUT_MS"
  ) 2>"$5"
}

WARN="$(mktemp "${TMPDIR:-/tmp}/demo-timeout-override.warn.XXXXXX")"
trap 'rm -f "$WARN"' EXIT

assert_eq() {  # assert_eq <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    ok "$1 -> $3"
  else
    bad "$1 -> expected $2, got $3"
  fi
}

assert_warns() {  # assert_warns <label> <pattern>
  if grep -q "$2" "$WARN"; then
    ok "$1: warned on stderr (fell back, did not abort)"
  else
    bad "$1: expected a stderr warning matching '$2', none found"
    sed 's/^/      /' "$WARN" >&2
  fi
}

if [ -n "$DISCOVERY_BLOCK_A" ] && [ -n "$DISCOVERY_BLOCK_B" ]; then
  # D1: regression pin, unset env, LOC=400 -> 1200000 + 300000*1 = 1500000 (today's formula, unchanged).
  assert_eq "D1 unset env, LOC=400 (regression pin)" 1500000 "$(calc_discovery - - 400 "$WARN")"

  # D2: cap override MAY exceed the 1800000 default, unrestricted (decision 2). LOC=8000 -> raw 7200000,
  # clamped to the override 2400000 (not the old default 1800000).
  assert_eq "D2 DF_HUNT_TIMEOUT_CAP_MS=2400000, LOC=8000 (cap raised past default, unrestricted)" 2400000 "$(calc_discovery - 2400000 8000 "$WARN")"

  # D3: invalid cap (non-numeric) falls back to the default 1800000 + warns, does not abort (decision 3).
  : > "$WARN"
  assert_eq "D3 DF_HUNT_TIMEOUT_CAP_MS=abc, LOC=4000 (falls back to default cap 1800000)" 1800000 "$(calc_discovery - abc 4000 "$WARN")"
  assert_warns "D3 invalid cap 'abc'" "DF_HUNT_TIMEOUT_CAP_MS must be a positive integer"

  # D4: invalid cap (0) falls back to the default 1800000 + warns.
  : > "$WARN"
  assert_eq "D4 DF_HUNT_TIMEOUT_CAP_MS=0, LOC=4000 (falls back to default cap 1800000)" 1800000 "$(calc_discovery - 0 4000 "$WARN")"
  assert_warns "D4 invalid cap '0'" "must be >= 1"

  # D5: floor override above the default cap raises the cap to the floor (decision 1: floor overridable too).
  assert_eq "D5 DF_HUNT_TIMEOUT_FLOOR_MS=2000000, LOC=0 (cap raised to floor)" 2000000 "$(calc_discovery 2000000 - 0 "$WARN")"

  # D6: cap override BELOW the (still-default) floor never drops the effective budget below the floor -- the
  # floor-vs-cap clamp fires unconditionally, so the floor (a documented MINIMUM) wins over a too-low cap.
  assert_eq "D6 DF_HUNT_TIMEOUT_CAP_MS=300000 (below default floor), LOC=8000 (floor wins, not 300000)" 1200000 "$(calc_discovery - 300000 8000 "$WARN")"
else
  bad "D1-D6 skipped: run-discovery.sh blocks failed to extract"
fi

if [ -n "$INVARIANT_BLOCK_A" ] && [ -n "$INVARIANT_BLOCK_B" ]; then
  # I1: regression pin, unset env, no --aux -> flat base 1200000.
  assert_eq "I1 unset env, INV_AUX empty (regression pin)" 1200000 "$(calc_invariant - - 0 0 "$WARN")"

  # I2: regression pin, unset env, --aux with 2 entries -> 1200000 + 600000*2 = 2400000, clamped to the
  # default cap 1800000 (today's formula, unchanged).
  assert_eq "I2 unset env, INV_AUX idx=2 (regression pin, clamps to default cap)" 1800000 "$(calc_invariant - - 1 2 "$WARN")"

  # I3: cap override MAY exceed the default 1800000 unrestricted -- idx=5 raw 4200000 would have clamped to
  # 1800000 before #2103; with the override it stays at the raw value.
  assert_eq "I3 DF_GEN_TIMEOUT_CAP_MS=5000000, INV_AUX idx=5 (cap raised past default, unrestricted)" 4200000 "$(calc_invariant - 5000000 1 5 "$WARN")"

  # I4: invalid base (non-numeric) falls back to the default 1200000 + warns.
  : > "$WARN"
  assert_eq "I4 DF_GEN_TIMEOUT_BASE_MS=abc, INV_AUX empty (falls back to default base 1200000)" 1200000 "$(calc_invariant abc - 0 0 "$WARN")"
  assert_warns "I4 invalid base 'abc'" "DF_GEN_TIMEOUT_BASE_MS must be a positive integer"

  # I5: invalid cap (0) falls back to the default 1800000 + warns.
  : > "$WARN"
  assert_eq "I5 DF_GEN_TIMEOUT_CAP_MS=0, INV_AUX idx=5 (falls back to default cap 1800000)" 1800000 "$(calc_invariant - 0 1 5 "$WARN")"
  assert_warns "I5 invalid cap '0'" "must be >= 1"

  # I6: base override above the default cap raises the cap to the base (decision 1: base overridable too).
  assert_eq "I6 DF_GEN_TIMEOUT_BASE_MS=2000000, INV_AUX empty (cap raised to base)" 2000000 "$(calc_invariant 2000000 - 0 0 "$WARN")"

  # I7: cap override BELOW the (still-default) base never drops the effective budget below the base --
  # mirrors D6, the base is the MINIMUM generation budget.
  assert_eq "I7 DF_GEN_TIMEOUT_CAP_MS=300000 (below default base), INV_AUX idx=5 (base wins, not 300000)" 1200000 "$(calc_invariant - 300000 1 5 "$WARN")"
else
  bad "I1-I7 skipped: run-invariant-hunt.sh blocks failed to extract"
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — DF_HUNT_TIMEOUT_{FLOOR,CAP}_MS / DF_GEN_TIMEOUT_{BASE,CAP}_MS override the per-cell/per-generation LLM timeout as approved (#2103)"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed (see #2103)" >&2
exit 1
