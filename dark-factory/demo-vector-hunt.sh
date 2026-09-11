#!/usr/bin/env bash
# demo-vector-hunt.sh — OFFLINE, DETERMINISTIC proof of the #2156 (milestone D2, epic #2130) invariant-driven
# VECTOR-ENUMERATION deep-hunt loop: run-vector-hunt.sh crosses a GENERIC economic-invariant catalog with D1's
# code-derived `CALLEE-VECTOR|` candidates, drives EACH enumerated vector through the concrete-PoC gate, and
# merges ONLY reproduced (PoC-PASS) vectors into verified_findings.json (source=vector-hunt). The PoC gate is
# driven by a FAST offline stub wired through the EXISTING --poc-runner seam — NO live agentis, NO forge, NO
# network.
#
# Assertions:
#   Part 1 SOURCE-GUARD (no forge/agentis):
#     1) run-vector-hunt.sh exists + is executable.
#     2) the GENERIC economic-invariant catalog + the hazard->invariant map + the --max-vectors cap +
#        source=vector-hunt + the --poc-runner / --resume seams are all present in the engine.
#     3) forge-slot OWNERSHIP: the engine sources lib/forge-slot.sh and brackets each PoC run with
#        acquire_forge_slot / release_forge_slot (run-poc.sh does NOT self-acquire).
#     4) READ-ONLY / never-submit: no network / submission verb on any executable line.
#   Part 2 LIVE-UNDER-STUB (pure shell):
#     5) the emitted VECTOR| set == expected-vectors.golden (cap respected, content-hash dedup holds, a
#        `dismissed:` CALLEE-VECTOR never seeds a vector).
#     6) every enumerated (CANDIDATE) vector routed to the PoC runner (a per-vector poc.log exists per hash).
#     7) exactly the ONE PoC-PASS vector merged into verified_findings.json == verified.golden.json.
#     8) a 2nd --resume run is a BYTE-IDENTICAL no-op (resumability / dedup).
#     9) the cap truncates: --max-vectors 2 emits exactly 2 VECTOR| lines.
#   Part 3 RUN-ZONE-HUNT WIRING (#2156 PR2 — STAGE 4.6):
#    10) run-zone-hunt.sh present; VECTOR_HUNT defaults 0 (OFF); the STAGE 4.6 block is gated on VECTOR_HUNT=1;
#        the relaxed --deep-hunt-only guard is OFF-preserving when --vector-hunt is absent.
#    11) OFF BYTE-IDENTITY: every origin/main line OUTSIDE the STAGE 4.6 `VECTOR_HUNT` block is byte-preserved
#        in the wired run-zone-hunt.sh, except the --deep-hunt-only guard (replaced by the OFF-equivalent) —
#        every behaviour line the OFF path runs is unchanged, no matter how the gated block's own body (D2's
#        depth-harvest widening, #2160) evolves (git-guarded: SKIP when origin/main is not fetched, where
#        assertion 10 stands in).
#    12) ON ROUTING: run-zone-hunt.sh --deep-hunt-only --vector-hunt over a staged breadth --out harvests the
#        zone's CALLEE-VECTOR candidates, invokes run-vector-hunt.sh (same stub via the VECTOR_HUNT_POC_RUNNER
#        seam), and merges EXACTLY the one PoC-PASS vector (source=vector-hunt) — dismissed vectors never route.
#    13) DEPTH HARVEST (#2160): the STAGE 4.6 harvest glob ALSO reads depth_*.log (D2 depth/refute cells), not
#        just breadth hunt_*.log — a depth-only CALLEE-VECTOR candidate is harvested and enumerated too.
#    14) #2170 ESCROW D2 CHAIN: a custody-true escrow/withdraw-request zone (the state is_value_custody now
#        emits for escrow shapes) flows end-to-end through STAGE 4.6 — its CALLEE-VECTOR markers are harvested
#        and run-vector-hunt.sh is invoked, proving the D2 chain fires once the escrow zone is flagged custody.
#    15) #2170 ESCAPE HATCH: a value_custody=false zone is SKIPPED by STAGE 4.6 by default (the bug's symptom:
#        a misdetected custody zone silently enumerates 0) but IS enumerated with --vector-hunt-all-zones —
#        the OFF-by-default recovery knob (fail-before default OFF / pass-after with the flag).
#
# Usage:  dark-factory/demo-vector-hunt.sh   (GENERATE_GOLDEN=1 rewrites the checked-in goldens)
# Requires: python3 (the floor). Exit: 0 = all assertions held; non-zero = a regression / the engine is absent
# (the fail-before source-guard). POSIX sh / dash-safe: no pipefail, no arrays, no $'...', literal ASCII only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/run-vector-hunt.sh"
FX="$HERE/fixtures/vector-hunt"
CALLEE_VECTORS="$FX/callee-vectors.txt"
STUB="$FX/poc-runner-stub.sh"
GOLDEN_VEC="$FX/expected-vectors.golden"
GOLDEN_VJ="$FX/verified.golden.json"

FAILS=0
note() { echo "demo-vector-hunt.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

# ==========================================================================================================
# PART 1 — SOURCE-GUARD (no forge / no agentis / no network).
# ==========================================================================================================
note "1) run-vector-hunt.sh exists + is executable ..."
if [ -x "$ENGINE" ]; then
  ok "run-vector-hunt.sh is present and executable"
else
  bad "run-vector-hunt.sh not found / not executable: $ENGINE (fail-before: the engine does not exist yet)"
  note "FAIL — the vector-hunt engine is absent" >&2
  exit 3
fi

note "2) the generic invariant catalog + hazard->invariant map + cap + source tag + seams are present ..."
MISS=""
for anchor in \
  'solvency' 'share-price-monotonicity' 'no-unauthorized-mint' \
  'reentrancy-state-consistency' 'return-value-trust' 'gas-liveness' \
  'HAZARD_INVARIANT' '--max-vectors' 'source=vector-hunt' '"source": "vector-hunt"' \
  '--poc-runner' '--resume' 'VECTOR-HUNT|' 'vector_hash' \
  '--cli-timeout-ms' '--cli-timeout-max-ms' '--timeout-retries' 'DF_POC_CLI_TIMEOUT_MAX_MS' \
  'DF_POC_TIMEOUT_RETRIES' 'TIMEOUT escalation'
do
  grep -F -q -e "$anchor" "$ENGINE" || MISS="$MISS $anchor"
done
if [ -z "$MISS" ]; then
  ok "the catalog rows, the hazard->invariant map, the cap flag, the source=vector-hunt tag, and the --poc-runner/--resume seams are all present"
else
  bad "the engine is missing load-bearing anchors:$MISS"
fi

note "3) forge-slot OWNERSHIP: the engine sources lib/forge-slot.sh and brackets each PoC run ..."
if grep -Fq 'lib/forge-slot.sh' "$ENGINE" \
   && grep -Fq 'acquire_forge_slot' "$ENGINE" \
   && grep -Fq 'release_forge_slot' "$ENGINE"; then
  ok "run-vector-hunt.sh owns the forge slot (acquire/release around each PoC run — run-poc.sh does not self-acquire, so FORGE_MAX_SLOTS is respected)"
else
  bad "the engine does not source lib/forge-slot.sh or does not bracket the PoC run with acquire/release"
fi

note "4) read-only / never-submit posture ..."
if grep -vE '^[[:space:]]*#' "$ENGINE" | grep -Eiq '(^|[^a-z])(curl|wget|submit)([^a-z]|$)'; then
  bad "run-vector-hunt.sh invokes a network / submission verb on an executable line"
else
  ok "run-vector-hunt.sh has no network / no submission verb on any executable line (read-only, never submits)"
fi

# ==========================================================================================================
# PART 2 — LIVE-UNDER-STUB (pure shell: the whole loop under the offline --poc-runner seam).
# ==========================================================================================================
[ -x "$STUB" ] || { bad "the offline poc-runner stub is missing / not executable: $STUB"; }
[ -f "$CALLEE_VECTORS" ] || { bad "the callee-vectors fixture is missing: $CALLEE_VECTORS"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-vector-hunt.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Isolate the forge-slot pool to this run — never touch the host-wide pool a live hunt shares.
export FORGE_SLOTS_DIR="$WORK/forge-slots"
mkdir -p "$WORK/target"

run_engine() {
  # run_engine <out-dir> <max-vectors> [extra-args...]
  re_out="$1"; re_max="$2"; shift 2
  "$ENGINE" \
    --repo "$WORK/target" --target "Vault.sol:Vault" --class "C-erc4626" \
    --callee-vectors "$CALLEE_VECTORS" --poc-runner "$STUB" \
    --max-vectors "$re_max" --out "$re_out" --backend mock --agentis /bin/true "$@"
}

note "5) the emitted VECTOR| set == expected-vectors.golden (cap / dedup / dismissed-exclusion) ..."
OUT1="$WORK/out1"
run_engine "$OUT1" 6 > "$WORK/run1.out" 2> "$WORK/run1.err"
grep '^VECTOR|' "$WORK/run1.out" > "$WORK/vectors.emitted"

if [ "${GENERATE_GOLDEN:-0}" = "1" ]; then
  mkdir -p "$FX"
  cp "$WORK/vectors.emitted" "$GOLDEN_VEC"
  cp "$OUT1/verified_findings.json" "$GOLDEN_VJ"
  note "GENERATE_GOLDEN=1 -> rewrote $GOLDEN_VEC and $GOLDEN_VJ"
fi

if [ -f "$GOLDEN_VEC" ] && cmp -s "$WORK/vectors.emitted" "$GOLDEN_VEC"; then
  ok "the enumerated VECTOR| set is byte-identical to expected-vectors.golden (the duplicate CANDIDATE collapsed, the dismissed vector was excluded, the cap held)"
else
  bad "the enumerated VECTOR| set drifted from the golden:"
  [ -f "$GOLDEN_VEC" ] && diff "$GOLDEN_VEC" "$WORK/vectors.emitted" | sed 's/^/      /' >&2
fi
# A dismissed CALLEE-VECTOR (setFee) must NEVER appear as an enumerated vector.
if grep -Fq 'setFee' "$WORK/vectors.emitted"; then
  bad "a dismissed: CALLEE-VECTOR (setFee) leaked into the enumerated set"
else
  ok "the dismissed: CALLEE-VECTOR (setFee) never seeded a vector (contamination + budget discipline)"
fi

note "6) every enumerated vector routed to the PoC runner (a per-vector poc.log exists per hash) ..."
ROUTE_OK=1
while IFS='|' read -r _p vh _rest; do
  [ "$_p" = "VECTOR" ] || continue
  [ -f "$OUT1/vector-hunt/$vh/poc.log" ] || { ROUTE_OK=0; bad "no PoC log for enumerated vector $vh"; }
done < "$WORK/vectors.emitted"
[ "$ROUTE_OK" -eq 1 ] && ok "each enumerated vector was routed through the --poc-runner seam (a per-vector poc.log was captured)"

note "7) exactly the ONE PoC-PASS vector merged into verified_findings.json == verified.golden.json ..."
if [ -f "$GOLDEN_VJ" ] && cmp -s "$OUT1/verified_findings.json" "$GOLDEN_VJ"; then
  ok "verified_findings.json holds exactly the one PoC-PASS vector (source=vector-hunt), byte-identical to the golden — CLEAN vectors merged nothing"
else
  bad "the merged verified_findings.json drifted from the golden:"
  [ -f "$GOLDEN_VJ" ] && diff "$GOLDEN_VJ" "$OUT1/verified_findings.json" | sed 's/^/      /' >&2
fi
# Independent structural check: exactly one verified entry, tagged source=vector-hunt, PASS-only.
if python3 - "$OUT1/verified_findings.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = d.get("verified", [])
assert len(v) == 1, "verified[] len != 1: %d" % len(v)
e = v[0]
assert e["source"] == "vector-hunt", "wrong source tag: %r" % e.get("source")
assert e["verdict"] == "FINDING", "not a FINDING: %r" % e.get("verdict")
assert e["location"] == "Vault.sol:executeDeposit", "wrong location: %r" % e.get("location")
assert e.get("vector_hash"), "missing vector_hash"
assert d["totals"]["verified"] == 1, "totals.verified != 1"
PY
then ok "the merged entry is exactly one PoC-PASS vector tagged source=vector-hunt on the reentrant executeDeposit vector"
else bad "the merged entry shape is wrong"
fi

note "8) a 2nd --resume run is a BYTE-IDENTICAL no-op (resumability / dedup) ..."
cp "$OUT1/verified_findings.json" "$WORK/vj.before"
run_engine "$OUT1" 6 --resume > "$WORK/run2.out" 2> "$WORK/run2.err"
if cmp -s "$WORK/vj.before" "$OUT1/verified_findings.json"; then
  ok "the --resume re-run left verified_findings.json byte-identical (no vector re-verified, no finding re-merged)"
else
  bad "the --resume re-run mutated verified_findings.json:"
  diff "$WORK/vj.before" "$OUT1/verified_findings.json" | sed 's/^/      /' >&2
fi

note "9) the cap truncates: --max-vectors 2 emits exactly 2 VECTOR| lines ..."
OUT3="$WORK/out3"
run_engine "$OUT3" 2 > "$WORK/run3.out" 2> "$WORK/run3.err"
N_CAP="$(grep -c '^VECTOR|' "$WORK/run3.out" 2>/dev/null || echo 0)"
if [ "$N_CAP" -eq 2 ]; then
  ok "--max-vectors 2 bounded the enumerated set to exactly 2 vectors (the explicit cap)"
else
  bad "--max-vectors 2 emitted $N_CAP vectors (expected 2)"
fi

# ==========================================================================================================
# PART 2.5 — #2178 TIMEOUT ESCALATION (pure shell): a terminal LlmTimeout (exit 75 / `[llm.timeout]`) becomes a
# distinct TIMEOUT verdict that the engine escalates by RAISING llm.cli_timeout_ms toward a hard cap — bounded,
# monotone, never an unbounded loop, and merging nothing. Driven by the offline stub's `__timeout__` branch.
# ==========================================================================================================
# A dedicated single-CANDIDATE callee-vectors file whose templated hypothesis carries the `__timeout__` token the
# stub keys on — kept OUT of the shared callee-vectors.txt so the checked-in goldens stay byte-identical.
TO_CV="$WORK/timeout-callee-vectors.txt"
printf '%s\n' 'CALLEE-VECTOR|escalateProbe|__timeout__oracle()|reentrant|CANDIDATE' > "$TO_CV"

run_timeout_engine() {
  # run_timeout_engine <out-dir> <timeout-retries> [extra-args...]
  rte_out="$1"; rte_retries="$2"; shift 2
  "$ENGINE" \
    --repo "$WORK/target" --target "Vault.sol:Vault" --class "C-erc4626" \
    --callee-vectors "$TO_CV" --poc-runner "$STUB" \
    --max-vectors 6 --out "$rte_out" --backend mock --agentis /bin/true \
    --cli-timeout-ms 600000 --cli-timeout-max-ms 1200000 --timeout-retries "$rte_retries" "$@"
}

note "9b) a TIMEOUT vector escalates exactly DF_POC_TIMEOUT_RETRIES times with a monotonically-RAISED ceiling, then records a terminal TIMEOUT and merges nothing ..."
TOUT1="$WORK/tout1"
run_timeout_engine "$TOUT1" 1 > "$WORK/tout1.out" 2> "$WORK/tout1.err"
TO_VH="$(grep '^VECTOR|' "$WORK/tout1.out" | head -1 | cut -d'|' -f2)"
TO_SEEN="$TOUT1/vector-hunt/$TO_VH/cli-timeout.seen"
TO_MARK="$TOUT1/vector-hunt/$TO_VH.verdict"
if [ -n "$TO_VH" ] && [ -f "$TO_SEEN" ]; then
  TO_N="$(grep -c . "$TO_SEEN")"
  TO_FIRST="$(sed -n '1p' "$TO_SEEN")"
  TO_LAST="$(sed -n "${TO_N}p" "$TO_SEEN")"
  # timeout-retries 1 => 1 initial run + 1 escalation = exactly 2 invocations; ceiling raised 600000 -> 1200000.
  if [ "$TO_N" -eq 2 ] && [ "$TO_FIRST" = "600000" ] && [ "$TO_LAST" = "1200000" ] && [ "$TO_LAST" -gt "$TO_FIRST" ]; then
    ok "the TIMEOUT vector ran twice (1 initial + 1 escalation) with a monotonically-raised --cli-timeout-ms 600000 -> 1200000"
  else
    bad "TIMEOUT escalation trail wrong: $TO_N invocation(s), first=$TO_FIRST last=$TO_LAST (expected 2, 600000 -> 1200000)"
  fi
else
  bad "no cli-timeout.seen trail for the TIMEOUT vector (hash='$TO_VH') — the escalation did not thread --cli-timeout-ms"
fi
if [ -f "$TO_MARK" ] && [ "$(cat "$TO_MARK")" = "TIMEOUT" ]; then
  ok "the vector's terminal verdict marker is TIMEOUT (stamped for --resume, distinct from HARNESS_ERROR)"
else
  bad "the TIMEOUT vector's verdict marker is not TIMEOUT (got '$([ -f "$TO_MARK" ] && cat "$TO_MARK")')"
fi
# Merges nothing: no verified entry, totals.verified == 0 (a TIMEOUT is NOT a reproduced finding).
if python3 - "$TOUT1/verified_findings.json" <<'PY'
import sys, json, os
p = sys.argv[1]
if not os.path.exists(p):
    sys.exit(0)   # never created == nothing merged
d = json.load(open(p, encoding="utf-8"))
assert not d.get("verified"), "TIMEOUT merged a verified[] entry"
assert int(d.get("totals", {}).get("verified", 0)) == 0, "totals.verified != 0 after a TIMEOUT"
PY
then ok "a terminal TIMEOUT merged nothing into verified_findings.json (not counted as a verified finding)"
else bad "a TIMEOUT vector wrongly merged into verified_findings.json"
fi

note "9c) RUNAWAY guard: even with a HIGH --timeout-retries, the monotone ceiling cap bounds the escalation (never an unbounded loop) ..."
TOUT2="$WORK/tout2"
run_timeout_engine "$TOUT2" 5 > "$WORK/tout2.out" 2> "$WORK/tout2.err"
TO2_VH="$(grep '^VECTOR|' "$WORK/tout2.out" | head -1 | cut -d'|' -f2)"
TO2_SEEN="$TOUT2/vector-hunt/$TO2_VH/cli-timeout.seen"
if [ -f "$TO2_SEEN" ]; then
  TO2_N="$(grep -c . "$TO2_SEEN")"
  TO2_LAST="$(sed -n "${TO2_N}p" "$TO2_SEEN")"
  # --timeout-retries 5 but cap 1200000: 600000 -> 1200000 hits the cap after ONE raise, so the loop stops at 2
  # invocations regardless of the retry count, and never exceeds the cap.
  if [ "$TO2_N" -eq 2 ] && [ "$TO2_LAST" = "1200000" ]; then
    ok "the ceiling cap bounded the escalation to 2 invocations even with --timeout-retries 5 (RUNAWAY guard: monotone ceiling stops the loop, never unbounded)"
  else
    bad "RUNAWAY guard failed: $TO2_N invocation(s), last=$TO2_LAST (a high retry count blew through the cap or looped)"
  fi
else
  bad "no cli-timeout.seen for the RUNAWAY-guard vector (hash='$TO2_VH')"
fi

note "9d) --timeout-retries 0 disables escalation: exactly ONE invocation, terminal TIMEOUT, no raise ..."
TOUT3="$WORK/tout3"
run_timeout_engine "$TOUT3" 0 > "$WORK/tout3.out" 2> "$WORK/tout3.err"
TO3_VH="$(grep '^VECTOR|' "$WORK/tout3.out" | head -1 | cut -d'|' -f2)"
TO3_SEEN="$TOUT3/vector-hunt/$TO3_VH/cli-timeout.seen"
if [ -f "$TO3_SEEN" ] && [ "$(grep -c . "$TO3_SEEN")" -eq 1 ] && [ "$(cat "$TO3_SEEN")" = "600000" ]; then
  ok "--timeout-retries 0 ran the vector exactly once at the floor ceiling with no escalation (classify-only)"
else
  bad "--timeout-retries 0 did not run exactly once at 600000 (got '$([ -f "$TO3_SEEN" ] && tr '\n' ',' < "$TO3_SEEN")')"
fi

# ==========================================================================================================
# PART 3 — run-zone-hunt.sh STAGE 4.6 WIRING (#2156 PR2): OFF byte-identity + ON per-zone routing + depth harvest.
# ==========================================================================================================
RZH="$HERE/run-zone-hunt.sh"

note "10) run-zone-hunt.sh STAGE 4.6 is OPT-IN + fully gated (source guard) ..."
if [ -x "$RZH" ]; then
  ok "run-zone-hunt.sh is present + executable"
else
  bad "run-zone-hunt.sh not found / not executable: $RZH"
fi
# The load-bearing OFF safety property: --vector-hunt defaults OFF and the STAGE 4.6 block is gated on it.
if grep -Eq '^VECTOR_HUNT=0( |;|$)|VECTOR_HUNT=0 ; VECTOR_HUNT_MAX_VECTORS=6' "$RZH"; then
  ok "VECTOR_HUNT defaults to 0 (OFF)"
else
  bad "VECTOR_HUNT does not default to 0 — the OFF path is not the default"
fi
# shellcheck disable=SC2016  # matching the literal source line, $VECTOR_HUNT must not expand
if grep -Fq 'if [ "$VECTOR_HUNT" -eq 1 ]; then' "$RZH"; then
  ok "the STAGE 4.6 block is gated on [ \"\$VECTOR_HUNT\" -eq 1 ] (skipped entirely when OFF)"
else
  bad "the STAGE 4.6 block is not gated on VECTOR_HUNT=1"
fi
# The relaxed --deep-hunt-only guard still errors when --vector-hunt is absent (OFF-preserving): it keeps the
# `[ "$DEEP_HUNT" -eq 1 ]` clause, so a pre-#2156 `--deep-hunt-only` (no --deep-hunt, no --vector-hunt) still exits 2.
# shellcheck disable=SC2016  # matching the literal guard line, the $-vars must not expand
if grep -Fq 'requires --deep-hunt or --vector-hunt' "$RZH" \
   && grep -Fq '[ "$DEEP_HUNT_ONLY" -eq 0 ] || [ "$DEEP_HUNT" -eq 1 ] || [ "$VECTOR_HUNT" -eq 1 ]' "$RZH"; then
  ok "the --deep-hunt-only guard admits --vector-hunt as a consuming stage but stays OFF-preserving when it is absent"
else
  bad "the --deep-hunt-only guard was not extended OFF-preservingly for --vector-hunt"
fi

note "11) run-zone-hunt.sh OFF byte-identity vs origin/main (every OFF-path line preserved except the guard) ..."
# The STRONG proof: every line of origin/main's run-zone-hunt.sh that the OFF path (--vector-hunt absent)
# actually executes is byte-preserved, so `--vector-hunt` absent == today. Two kinds of change are permitted:
# (a) the --deep-hunt-only guard, replaced by an OFF-equivalent (asserted above), and (b) any line INSIDE the
# STAGE 4.6 `VECTOR_HUNT` block itself (#2160's depth-harvest glob/comment widening lives entirely there) — the
# OFF run never enters that block, so edits confined to it cannot change OFF-path behaviour no matter how many
# lines they touch. The block is excluded by POSITION, via the `# >>> STAGE-4.6-VECTOR-HUNT ... >>>` /
# `# <<< STAGE-4.6-VECTOR-HUNT <<<` sentinel comments bracketing it — NOT by subtracting its content as a
# multiset — because a content-based subtraction is fooled the moment an OFF-path line happens to be
# byte-identical to a line inside the block (e.g. a shared `fi`/`continue`/heredoc line elsewhere in the file):
# breaking that OFF-path line would then be silently absorbed into the block's own multiset and never show up
# as "removed", false-passing a real regression (caught in review on #2167). A removed line found OUTSIDE the
# sentinel-delimited span is a real OFF-path regression. Skipped (not failed) when origin/main is not fetched
# (a shallow CI checkout), where assertion 10's gating proof still holds.
VH_BLOCK_START='^# >>> STAGE-4\.6-VECTOR-HUNT \(OFF-path excludes this block\) >>>$'
VH_BLOCK_END='^# <<< STAGE-4\.6-VECTOR-HUNT <<<$'
if git -C "$HERE" cat-file -e origin/main:dark-factory/run-zone-hunt.sh 2>/dev/null; then
  git -C "$HERE" show origin/main:dark-factory/run-zone-hunt.sh > "$WORK/rz-origin.sh"
  if cmp -s "$WORK/rz-origin.sh" "$RZH"; then
    # Post-merge steady state: origin/main IS the wired version (the guard-replacement diff below is only
    # meaningful pre-merge, comparing the wired branch against the still-unwired origin/main).
    note "  [SKIP] origin/main == working tree run-zone-hunt.sh — post-merge steady state; assertion 10's gating proof stands in"
  else
    # Strip the STAGE 4.6 block (inclusive) from BOTH files BEFORE comparing, by POSITION. The wired file always
    # carries the sentinel comments (this PR introduces them), so it always strips via the sentinel range. origin
    # may or may not have the sentinels yet: this PR's own origin/main (post-#2156, pre-#2160) does NOT, so fall
    # back to the structural `if [ "$VECTOR_HUNT" -eq 1 ]; then ... fi` anchor there (present since #2156) — the
    # SAME logical span the sentinels bracket in the wired file, so both sides strip the identical block region.
    # A pre-#2156 origin/main (neither sentinels nor the if/fi) is left untouched by both deletes (no matching
    # range -> no-op), degrading safely to a plain byte-diff.
    if grep -Eq "$VH_BLOCK_START" "$WORK/rz-origin.sh"; then
      sed -E "/${VH_BLOCK_START}/,/${VH_BLOCK_END}/d" "$WORK/rz-origin.sh" > "$WORK/rz-origin-noblock.sh"
    else
      sed '/^if \[ "\$VECTOR_HUNT" -eq 1 \]; then$/,/^fi$/d' "$WORK/rz-origin.sh" > "$WORK/rz-origin-noblock.sh"
    fi
    sed -E "/${VH_BLOCK_START}/,/${VH_BLOCK_END}/d" "$RZH" > "$WORK/rz-wired-noblock.sh"
    # multiset of origin (block-stripped) lines NOT present in the wired (block-stripped) version == the only
    # candidate OFF-path regressions, now immune to any content collision with the (already-removed) block.
    comm -23 <(sort "$WORK/rz-origin-noblock.sh") <(sort "$WORK/rz-wired-noblock.sh") > "$WORK/rz-removed-outside.txt"
    OUTSIDE_N="$(awk 'END{print NR}' "$WORK/rz-removed-outside.txt")"
    # shellcheck disable=SC2016  # the literal origin/main guard line, compared verbatim — no expansion
    EXPECT_GUARD='[ "$DEEP_HUNT_ONLY" -eq 0 ] || [ "$DEEP_HUNT" -eq 1 ] || { echo "run-zone-hunt.sh: --deep-hunt-only requires --deep-hunt" >&2; exit 2; }'
    if [ "$OUTSIDE_N" -eq 0 ] || { [ "$OUTSIDE_N" -eq 1 ] && [ "$(cat "$WORK/rz-removed-outside.txt")" = "$EXPECT_GUARD" ]; }; then
      ok "every run-zone-hunt.sh line OUTSIDE the sentinel-delimited STAGE 4.6 block is byte-preserved (at most the one OFF-equivalent guard replacement) — the OFF path is byte-identical to origin/main"
    else
      bad "run-zone-hunt.sh changed $OUTSIDE_N original line(s) OUTSIDE the STAGE 4.6 block beyond the guard (OFF path may have drifted):"
      sed 's/^/      /' "$WORK/rz-removed-outside.txt" >&2
    fi
  fi
else
  note "  [SKIP] origin/main not available in this checkout — assertion 10's gating proof stands in"
fi

note "11b) assertion 11 self-check (independent of origin/main availability): an OFF-path line break byte-identical to block content (the #2167 review finding) IS caught; an in-block-only edit is still ignored ..."
# Self-contained against the WIRED tree ($RZH) itself, exercising the SAME sentinel-strip mechanism assertion 11
# uses — independent of whether origin/main is fetched or already carries the sentinels.
# (a) break the OFF-path occurrence of a line that is a byte-for-byte DUPLICATE of a line inside the STAGE 4.6
# block (the exact #2167 review repro: run-zone-hunt.sh's STAGE 4.5 python classifier's `return "C-invariant"`
# also appears, verbatim, inside the STAGE 4.6 block) — a content-based (non-positional) exclusion would
# silently absorb this break into the block's own multiset and never flag it; the positional exclusion must not.
DUP_LINE='    return "C-invariant"'
DUP_COUNT="$(grep -Fxc "$DUP_LINE" "$RZH" 2>/dev/null || echo 0)"
if [ "$DUP_COUNT" -ge 2 ]; then
  awk -v dup="$DUP_LINE" -v n=0 '
    { if ($0 == dup) { n++; if (n == 1) { print "    return \"C-BROKEN\""; next } } print }
  ' "$RZH" > "$WORK/rz-brokenoff.sh"
  sed -E "/${VH_BLOCK_START}/,/${VH_BLOCK_END}/d" "$RZH" > "$WORK/rz-pristine-noblock.sh"
  sed -E "/${VH_BLOCK_START}/,/${VH_BLOCK_END}/d" "$WORK/rz-brokenoff.sh" > "$WORK/rz-brokenoff-noblock.sh"
  comm -23 <(sort "$WORK/rz-pristine-noblock.sh") <(sort "$WORK/rz-brokenoff-noblock.sh") > "$WORK/rz-selfcheck-a.txt"
  if [ -s "$WORK/rz-selfcheck-a.txt" ]; then
    ok "self-check (a): breaking the OFF-path line that duplicates block content IS flagged as a removed line (positional exclusion holds; a content-based exclusion would have hidden this)"
  else
    bad "self-check (a) REGRESSED: breaking an OFF-path line byte-identical to block content was NOT flagged — assertion 11 would false-pass this exact review finding"
  fi
else
  note "  [SKIP] self-check (a): the known OFF-path/in-block duplicate line text was not found >= twice verbatim (source drifted) — assertion 11's positional logic still holds structurally"
fi
# (b) an edit confined strictly INSIDE the sentinel block must still be ignored (no false failure). Plain
# substring matching (index(), not regex) avoids any awk-dialect escaping ambiguity over the literal markers.
awk -v startpat='# >>> STAGE-4.6-VECTOR-HUNT (OFF-path excludes this block) >>>' \
    -v endpat='# <<< STAGE-4.6-VECTOR-HUNT <<<' -v ins=0 '
  { if (index($0, startpat) == 1) ins=1
    if (ins==1 && index($0, "VECTOR_HUNT_MAX_VECTORS") > 0) { print "  # #2160 self-check in-block no-op edit"; print; next }
    print
    if (index($0, endpat) == 1) ins=0
  }
' "$RZH" > "$WORK/rz-inblockedit.sh"
sed -E "/${VH_BLOCK_START}/,/${VH_BLOCK_END}/d" "$WORK/rz-inblockedit.sh" > "$WORK/rz-inblockedit-noblock.sh"
sed -E "/${VH_BLOCK_START}/,/${VH_BLOCK_END}/d" "$RZH" > "$WORK/rz-pristine-noblock2.sh"
if cmp -s "$WORK/rz-pristine-noblock2.sh" "$WORK/rz-inblockedit-noblock.sh"; then
  ok "self-check (b): an edit confined inside the sentinel block leaves the block-stripped comparison unchanged (in-block edits never false-fail assertion 11)"
else
  bad "self-check (b) REGRESSED: an in-block-only edit changed the block-stripped comparison"
fi

note "12) STAGE 4.6 ON: run-zone-hunt.sh --deep-hunt-only --vector-hunt routes each zone to the engine + merges only PASS ..."
# Stage a MINIMAL breadth --out (--deep-hunt-only reuses it: map/zones.json + verify/verified_findings.json), a
# Foundry target repo, and one zone's breadth cell log carrying the D1 CALLEE-VECTOR lines. The engine is driven
# by the SAME offline poc-runner stub, threaded through the VECTOR_HUNT_POC_RUNNER seam. NO agentis / forge / network.
ZRUN="$WORK/zrun"; ZREPO="$WORK/zrepo"
mkdir -p "$ZRUN/map" "$ZRUN/verify" "$ZRUN/discovery/core/run" "$ZREPO"
printf 'Vault.sol\n' > "$ZREPO/Vault.sol"          # a body so the primary-target loc() picks it
printf '[profile.default]\nsrc = "."\n' > "$ZREPO/foundry.toml"
printf '%s\n' '[{"id": "core", "value_custody": true, "files": ["Vault.sol"], "bug_classes_likely": ["C6"]}]' > "$ZRUN/map/zones.json"
printf '%s\n' '{"verified": [], "totals": {"verified": 0}}' > "$ZRUN/verify/verified_findings.json"
# Split the SAME zone-'core' CALLEE-VECTOR fixture across a BREADTH cell log (hunt_core_C6.log: the
# executeDeposit CANDIDATE dup + the dismissed setFee) and a DEPTH cell log (depth_core_C6_1.log, naming
# mirrors run-discovery.sh:1105's depth_<slug>_<class>_<n>.log: the withdraw + claim CANDIDATEs) — proving
# STAGE 4.6 harvests BOTH hunt_*.log and depth_*.log into the same per-zone $VH_CV, not just breadth (#2160).
grep -E '\|executeDeposit\||\|setFee\|' "$CALLEE_VECTORS" > "$ZRUN/discovery/core/run/hunt_core_C6.log"
grep -E '\|withdraw\||\|claim\|' "$CALLEE_VECTORS" > "$ZRUN/discovery/core/run/depth_core_C6_1.log"

if VECTOR_HUNT_POC_RUNNER="$STUB" FORGE_SLOTS_DIR="$WORK/forge-slots-z" \
   "$RZH" --repo "$ZREPO" --out "$ZRUN" --deep-hunt-only --vector-hunt --vector-hunt-max-vectors 6 \
   --backend mock --agentis /bin/true > "$WORK/zrun.out" 2> "$WORK/zrun.err"; then
  ok "run-zone-hunt.sh --deep-hunt-only --vector-hunt exited 0 over the reused breadth --out"
else
  bad "run-zone-hunt.sh --deep-hunt-only --vector-hunt exited non-zero:"
  tail -5 "$WORK/zrun.err" | sed 's/^/      /' >&2
fi
# (i) the engine was invoked per value-custody zone (the per-zone vector-hunt output + verdict markers exist).
if [ -f "$ZRUN/vector-hunt/core/vector-hunt.out" ] && grep -q '^VECTOR|' "$ZRUN/vector-hunt/core/vector-hunt.out"; then
  ok "STAGE 4.6 harvested zone 'core' CALLEE-VECTOR candidates and invoked run-vector-hunt.sh (VECTOR| set emitted)"
else
  bad "STAGE 4.6 did not invoke run-vector-hunt.sh for the value-custody zone 'core'"
fi
# (ii) exactly the ONE PoC-PASS vector merged into the reused verified_findings.json, tagged source=vector-hunt.
if python3 - "$ZRUN/verify/verified_findings.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = [e for e in d.get("verified", []) if e.get("source") == "vector-hunt"]
assert len(v) == 1, "source=vector-hunt entries != 1: %d" % len(v)
e = v[0]
assert e["verdict"] == "FINDING", "not a FINDING: %r" % e.get("verdict")
assert e["location"] == "Vault.sol:executeDeposit", "wrong location: %r" % e.get("location")
assert e.get("vector_hash"), "missing vector_hash"
PY
then ok "STAGE 4.6 merged exactly the one PoC-PASS vector (source=vector-hunt) into the reused verified_findings.json — CLEAN vectors merged nothing"
else bad "STAGE 4.6 merge is wrong (expected exactly one source=vector-hunt PoC-PASS entry on Vault.sol:executeDeposit)"
fi
# (iii) the dismissed CALLEE-VECTOR never seeded a vector even through the full wiring.
if grep -q 'setFee' "$ZRUN/vector-hunt/core/vector-hunt.out" 2>/dev/null; then
  bad "a dismissed: CALLEE-VECTOR (setFee) leaked through STAGE 4.6"
else
  ok "the dismissed: CALLEE-VECTOR (setFee) never seeded a vector through STAGE 4.6"
fi

note "13) STAGE 4.6 DEPTH HARVEST (#2160): depth-only CALLEE-VECTOR candidates (withdraw/claim, staged ONLY in depth_core_C6_1.log, no breadth hunt_*.log line) are harvested and enumerated too ..."
DEPTH_OK=1
for _fn in withdraw claim; do
  _vline="$(grep "|$_fn|" "$ZRUN/vector-hunt/core/vector-hunt.out" 2>/dev/null | head -1)"
  if [ -z "$_vline" ]; then
    DEPTH_OK=0
    bad "depth-only CALLEE-VECTOR candidate '$_fn' (staged in depth_core_C6_1.log) was never enumerated by STAGE 4.6 (fail-before: the harvest glob only reads hunt_*.log)"
    continue
  fi
  _vh="$(printf '%s\n' "$_vline" | cut -d'|' -f2)"
  if [ -f "$ZRUN/vector-hunt/core/vector-hunt/$_vh/poc.log" ]; then
    :
  else
    DEPTH_OK=0
    bad "depth-only candidate '$_fn' was enumerated but has no poc.log at $ZRUN/vector-hunt/core/vector-hunt/$_vh/poc.log (never routed to the PoC runner)"
  fi
done
[ "$DEPTH_OK" -eq 1 ] && ok "STAGE 4.6 harvested depth_*.log too: both depth-only candidates (withdraw, claim) were enumerated and routed through the PoC runner"

note "14) #2170 ESCROW D2 CHAIN: a custody-true escrow/withdraw-request zone flows end-to-end through STAGE 4.6 (harvest + engine invoke) ..."
# The #2170 fix makes is_value_custody() emit value_custody=true for escrow/withdraw-request/cooldown zones
# (proven at the .ag level by demo-map-zones.sh's agentis-gated withdraws=true/router=false pair). Here, CI-safe
# and agentis-free, we stage the STATE that fix produces (a "withdraws" zone value_custody=true) and prove the
# D2 chain fires for it — the escrow zone is harvested and driven through run-vector-hunt.sh, exactly as the
# accounting zone in assertion 12 is. Same offline stub via the VECTOR_HUNT_POC_RUNNER seam. NO agentis/forge/net.
ZRUN2="$WORK/zrun-escrow"; ZREPO2="$WORK/zrepo-escrow"
mkdir -p "$ZRUN2/map" "$ZRUN2/verify" "$ZRUN2/discovery/withdraws/run" "$ZREPO2"
printf 'WithdrawRequestManager.sol\n' > "$ZREPO2/WithdrawRequestManager.sol"   # a body so loc() picks it
printf '[profile.default]\nsrc = "."\n' > "$ZREPO2/foundry.toml"
printf '%s\n' '[{"id": "withdraws", "value_custody": true, "files": ["WithdrawRequestManager.sol"], "bug_classes_likely": ["C6"]}]' > "$ZRUN2/map/zones.json"
printf '%s\n' '{"verified": [], "totals": {"verified": 0}}' > "$ZRUN2/verify/verified_findings.json"
grep -E '\|withdraw\||\|claim\|' "$CALLEE_VECTORS" > "$ZRUN2/discovery/withdraws/run/hunt_withdraws_C6.log"
if VECTOR_HUNT_POC_RUNNER="$STUB" FORGE_SLOTS_DIR="$WORK/forge-slots-escrow" \
   "$RZH" --repo "$ZREPO2" --out "$ZRUN2" --deep-hunt-only --vector-hunt --vector-hunt-max-vectors 6 \
   --backend mock --agentis /bin/true > "$WORK/zrun-escrow.out" 2> "$WORK/zrun-escrow.err"; then
  if [ -f "$ZRUN2/vector-hunt/withdraws/vector-hunt.out" ] && grep -q '^VECTOR|' "$ZRUN2/vector-hunt/withdraws/vector-hunt.out"; then
    ok "#2170: STAGE 4.6 harvested the custody-true escrow zone 'withdraws' CALLEE-VECTOR candidates and invoked run-vector-hunt.sh (D2 chain fires end-to-end)"
  else
    bad "#2170: STAGE 4.6 did not harvest/route the custody-true escrow zone 'withdraws'"
  fi
else
  bad "#2170: run-zone-hunt.sh --deep-hunt-only --vector-hunt exited non-zero over the escrow zone:"
  tail -5 "$WORK/zrun-escrow.err" | sed 's/^/      /' >&2
fi

note "15) #2170 ESCAPE HATCH: a value_custody=false zone is SKIPPED by default but enumerated with --vector-hunt-all-zones ..."
# The #2170 bug is that a misdetected custody zone silently enumerates 0 in STAGE 4.6. The OFF-by-default
# --vector-hunt-all-zones recovery knob lets an operator force enumeration over EVERY zone. Fail-before (default
# OFF: the false zone is skipped, the bug's symptom) / pass-after (flag ON: the false zone is enumerated).
ZRUN3="$WORK/zrun-allzones"; ZREPO3="$WORK/zrepo-allzones"
mkdir -p "$ZRUN3/map" "$ZRUN3/verify" "$ZRUN3/discovery/misdetect/run" "$ZREPO3"
printf 'Holder.sol\n' > "$ZREPO3/Holder.sol"
printf '[profile.default]\nsrc = "."\n' > "$ZREPO3/foundry.toml"
printf '%s\n' '[{"id": "misdetect", "value_custody": false, "files": ["Holder.sol"], "bug_classes_likely": ["C6"]}]' > "$ZRUN3/map/zones.json"
printf '%s\n' '{"verified": [], "totals": {"verified": 0}}' > "$ZRUN3/verify/verified_findings.json"
grep -E '\|withdraw\||\|claim\|' "$CALLEE_VECTORS" > "$ZRUN3/discovery/misdetect/run/hunt_misdetect_C6.log"
# Fail-before: default OFF => the value_custody=false zone is skipped, so its vector-hunt dir is never created.
VECTOR_HUNT_POC_RUNNER="$STUB" FORGE_SLOTS_DIR="$WORK/forge-slots-off" \
  "$RZH" --repo "$ZREPO3" --out "$ZRUN3" --deep-hunt-only --vector-hunt --vector-hunt-max-vectors 6 \
  --backend mock --agentis /bin/true > "$WORK/zrun-off.out" 2> "$WORK/zrun-off.err" || true
if [ ! -e "$ZRUN3/vector-hunt/misdetect/vector-hunt.out" ]; then
  ok "#2170: default OFF — the value_custody=false zone 'misdetect' was skipped by STAGE 4.6 (the bug's symptom, byte-identical pre-#2170 behaviour)"
else
  bad "#2170: default OFF should skip a value_custody=false zone, but STAGE 4.6 enumerated 'misdetect'"
fi
# Pass-after: --vector-hunt-all-zones => the same false zone IS enumerated and routed.
if VECTOR_HUNT_POC_RUNNER="$STUB" FORGE_SLOTS_DIR="$WORK/forge-slots-on" \
   "$RZH" --repo "$ZREPO3" --out "$ZRUN3" --deep-hunt-only --vector-hunt --vector-hunt-all-zones --vector-hunt-max-vectors 6 \
   --backend mock --agentis /bin/true > "$WORK/zrun-on.out" 2> "$WORK/zrun-on.err"; then
  if [ -f "$ZRUN3/vector-hunt/misdetect/vector-hunt.out" ] && grep -q '^VECTOR|' "$ZRUN3/vector-hunt/misdetect/vector-hunt.out"; then
    ok "#2170: --vector-hunt-all-zones enumerated the value_custody=false zone 'misdetect' too (the recovery knob against a future custody misdetection)"
  else
    bad "#2170: --vector-hunt-all-zones did not enumerate the value_custody=false zone 'misdetect'"
  fi
else
  bad "#2170: run-zone-hunt.sh --vector-hunt-all-zones exited non-zero:"
  tail -5 "$WORK/zrun-on.err" | sed 's/^/      /' >&2
fi

# ----------------------------------------------------------------------------------------------------------
if [ "$FAILS" -eq 0 ]; then
  note "PASS — the invariant-driven vector-enumeration loop (run-vector-hunt.sh: enumerate -> per-vector forge-verify -> only-PoC-PASS merged, deduped + resumable) holds"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
