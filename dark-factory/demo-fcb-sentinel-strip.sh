#!/usr/bin/env bash
# demo-fcb-sentinel-strip.sh — proof of the #2245 flat-cyborg result-file sentinel fix on the deep-hunt path.
#
# The bug: since the native flat-cyborg result-file channel was wired into the hunt emitters
# (llm.flat_cyborg.result_file_dir, #2207; run-invariant-hunt.sh / run-poc.sh), the driven model's reply
# carries a leading `FCB_<hex>_BEGIN` line and a trailing `FCB_<hex>_END` (own line, or appended to the last
# content line after a space). Harmless in hunter/refuter TEXT, but invariant-prover.ag and poc-writer.ag write
# the reply out as a `*.t.sol` FILE — the leading sentinel becomes the first byte solc sees and the harness
# fails to compile (`Error (2314): Expected identifier but got 'pragma'`). A second bug compounded it:
# forge-invariant.sh's `_compile_error_sig()` only scanned forge's STDERR, but forge --json puts the rich
# diagnostic on STDOUT (stderr gets only the terse "Error: Compilation failed" stub) — so the compile error was
# invisible to the signature check and the run was misclassified as a re-runnable TRANSIENT_ERROR instead of a
# genuine HARNESS_ERROR, hiding the defect.
#
# The fix strips the sentinels NATIVELY (regex_match/regex_capture, no exec sh escape — required by the
# repo-wide #1587/#2083 substrate-purity ratchet, which check-substrate-purity.sh enforces on every */agents/
# *.ag file): strip_fcb_begin/strip_fcb_end/strip_fcb_sentinel, byte-identical between the two code-writing
# sinks, marked with `#2245-FCB-STRIP-BEGIN`/`-END` comments for extraction.
#
# This demo has FOUR parts:
#   1) SOURCE-GUARD (always, CI-safe): the shared strip block's CODE (comments excluded — the prose legitimately
#      differs) is byte-identical in both sinks and is actually called from both write_test() pipelines — the
#      MUTATION CHECK: drop either wiring line and this assertion fails.
#   2) LIVE FUNCTIONAL PROBE (skipped without agentis): the REAL, shipped strip_fcb_begin/strip_fcb_end/
#      strip_fcb_sentinel functions — extracted verbatim from invariant-prover.ag via the BEGIN/END markers,
#      never hand-copied — driven over 7 fixtures through `agentis go` (no LLM: llm.backend = mock).
#   3) forge-invariant.sh's `_compile_error_sig()` must scan BOTH stdout and stderr and recognise the terse +
#      rich compile-error markers (always, CI-safe, source-guard).
#   4) LIVE GATE (skipped without forge): a real forge-invariant.sh run over a sentinel-PREFIXED harness proves
#      exit 2 (HARNESS_ERROR), never exit 3 (TRANSIENT_ERROR); the SAME harness run through the shipped native
#      filter (via the same agentis probe as part 2) compiles and reaches a real verdict.
#
# Usage:  dark-factory/demo-fcb-sentinel-strip.sh
# Exit: 0 = all assertions hold (LIVE parts SKIP cleanly when agentis/forge are absent); non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
POCWRITER="$HERE/auditor/agents/poc-writer.ag"
GATE="$HERE/evm-harness/forge-invariant.sh"

FAILS=0
note() { echo "demo-fcb-sentinel-strip.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$PROVER" ]    || { note "invariant-prover.ag not found: $PROVER" >&2; exit 3; }
[ -f "$POCWRITER" ] || { note "poc-writer.ag not found: $POCWRITER" >&2; exit 3; }
[ -f "$GATE" ]      || { note "forge-invariant.sh not found: $GATE" >&2; exit 3; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

extract_block() {
  awk '/^\/\/ #2245-FCB-STRIP-BEGIN$/{f=1} f{print} /^\/\/ #2245-FCB-STRIP-END$/{exit}' "$1"
}
code_only() { grep -v '^[[:space:]]*//'; }

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD — the shared strip block's CODE is byte-identical between the two sinks (the prose comments
#    legitimately differ per-file) and is actually wired into BOTH write_test() pipelines (the mutation check).
# ----------------------------------------------------------------------------------------------------------
note "1) sentinel-strip block code is byte-identical across invariant-prover.ag and poc-writer.ag and is wired into write_test() ..."

extract_block "$PROVER"    | code_only > "$WORK/code-prover.ag"
extract_block "$POCWRITER" | code_only > "$WORK/code-poc.ag"

if [ -s "$WORK/code-prover.ag" ] && cmp -s "$WORK/code-prover.ag" "$WORK/code-poc.ag"; then
  ok "strip_fcb_begin/strip_fcb_end/strip_fcb_sentinel are present and byte-identical (code) in both agents"
else
  bad "the #2245 sentinel-strip block is missing or has DRIFTED (code) between invariant-prover.ag and poc-writer.ag"
fi

if grep -q 'return exec sh "printf .%s. " + shell_escape(strip_fcb_sentinel(src)) + " > " + shell_escape(out)' "$PROVER"; then
  ok "invariant-prover.ag write_test() strips the sentinel via strip_fcb_sentinel() before shell_escape()"
else
  bad "invariant-prover.ag write_test() no longer calls strip_fcb_sentinel() — the sentinel would reach solc unstripped"
fi
if grep -q 'return exec sh "printf .%s. " + shell_escape(strip_fcb_sentinel(src)) + " > " + shell_escape(out)' "$POCWRITER"; then
  ok "poc-writer.ag write_test() strips the sentinel via strip_fcb_sentinel() before shell_escape()"
else
  bad "poc-writer.ag write_test() no longer calls strip_fcb_sentinel() — the sentinel would reach solc unstripped"
fi

# ----------------------------------------------------------------------------------------------------------
# 3) forge-invariant.sh's _compile_error_sig() must see the RICH diagnostic (forge puts it on STDOUT, not
#    stderr) and the terse stderr stub, and its call site must scan both files.
# ----------------------------------------------------------------------------------------------------------
note "2) _compile_error_sig() scans both stdout and stderr and recognises the terse + rich compile-error markers ..."

if grep -Fq "Compilation failed" "$GATE" && grep -Fq 'Error \([0-9]+\):' "$GATE"; then
  ok "forge-invariant.sh's compile-error signature covers both the terse stderr stub and the rich Error (NNNN): marker"
else
  bad "forge-invariant.sh's compile-error signature is missing the terse or rich marker"
fi
if grep -q '_compile_error_sig "\$TMPD/err.txt" "\$TMPD/out.json"' "$GATE"; then
  ok "forge-invariant.sh's _transient_candidate scans BOTH stdout and stderr for a compile-error signature"
else
  bad "forge-invariant.sh's _transient_candidate still scans stderr ONLY — a stdout-only diagnostic is invisible to it"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) LIVE FUNCTIONAL PROBE — drive the REAL, shipped strip_fcb_sentinel() (extracted verbatim, never hand-
#    copied) over 7 fixtures through a real `agentis go` (no LLM). Also builds the sentinel-stripped harness
#    file part 4's live forge check compiles.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — skipping the live strip_fcb_sentinel() functional probe (source guards above still ran)"
else
  note "3) strip_fcb_sentinel() behaviour probe (real .ag functions extracted from invariant-prover.ag, no LLM) ..."
  PROBE="$WORK/probe"
  mkdir -p "$PROBE"
  extract_block "$PROVER" > "$PROBE/fcb-probe.ag"
  # The sentinel-prefixed harness fixture reused by part 4's live forge check — written to a PLAIN file and
  # read back with the SAME cat_file() idiom the real agents use (invariant-prover.ag:43), so no shell-escaping
  # acrobatics are needed to turn it into an .ag string literal.
  cat > "$WORK/harness-raw.sol" <<'SOL'
FCB_1bacc818d7c9b2fcfadf940_BEGIN
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Counter} from "../src/Counter.sol";
abstract contract InvBase {
  address[] private _t;
  function targetContracts() public view returns (address[] memory){ return _t; }
  function _target(address a) internal { _t.push(a); }
}
contract InvOkTest is InvBase {
  Counter c;
  function setUp() public { c = new Counter(); _target(address(c)); }
  function invariant_total_nonneg() public view { require(c.total() >= 0, "x"); }
}
SOL
  # Trim the trailing newline the heredoc added, so harnessRaw matches printf '%s'-shaped LLM replies exactly
  # (no dependence on a trailing newline either way — case A/D/G above already prove that path is a no-op).
  printf '%s' "$(cat "$WORK/harness-raw.sol")" > "$WORK/harness-raw-trimmed.sol"
  cat >> "$PROBE/fcb-probe.ag" <<AG
fn cat_file(path: string) -> string {
    if len(path) == 0 { return ""; }
    return exec sh "sed -n '1,4000p' \${path} 2>/dev/null || true";
}
let harnessRaw = cat_file("$WORK/harness-raw-trimmed.sol");
print("CASE_A|" + strip_fcb_sentinel("FCB_1bacc818d7c9b2fcfadf940_BEGIN\n// SPDX-License-Identifier: MIT\npragma solidity ^0.8.19;\ncontract Foo {}"));
print("CASE_B|" + strip_fcb_sentinel("FCB_1bacc818d7c9b2fcfadf940_BEGIN\ncontract Foo {}\nFCB_1bacc818d7c9b2fcfadf940_END"));
print("CASE_C|" + strip_fcb_sentinel("FCB_1bacc818d7c9b2fcfadf940_BEGIN\ncontract Foo {} FCB_1bacc818d7c9b2fcfadf940_END"));
print("CASE_D|" + strip_fcb_sentinel("contract Foo {}\nfunction bar() public {}"));
print("CASE_E|" + strip_fcb_sentinel("FCB_1bacc818d7c9b2fcfadf940_BEGIN\nFCB_1bacc818d7c9b2fcfadf940_END"));
print("CASE_F|" + strip_fcb_sentinel(""));
print("CASE_G|" + strip_fcb_sentinel("no sentinel at all, single line"));
print("###HARNESS_BEGIN###");
print(strip_fcb_sentinel(harnessRaw));
print("###HARNESS_END###");
AG
  ( cd "$PROBE" && agentis init >/dev/null 2>&1 ) || true
  printf 'llm.backend = mock\n' > "$PROBE/.agentis/config"
  ( cd "$PROBE" && agentis go fcb-probe.ag --enable-exec ) > "$PROBE/probe.log" 2>&1  # no-pii: the probe never calls prompt() — --enable-exec is used only by cat_file() to read a checked-in Solidity fixture and by strip_fcb_sentinel() fixtures, all string literals
  PROBE_RC=$?
  if [ "$PROBE_RC" -ne 0 ]; then
    bad "the strip_fcb_sentinel() probe did not run cleanly (exit $PROBE_RC)"
    sed 's/^/        | /' "$PROBE/probe.log" | tail -15
  else
    check_case() {
      # $1=tag $2=expected
      got="$(grep "^$1|" "$PROBE/probe.log" | head -1 | sed "s/^$1|//")"
      if [ "$got" = "$2" ]; then
        ok "$1: strip_fcb_sentinel() -> '$2'"
      else
        bad "$1: expected '$2', got '$got'"
      fi
    }
    check_case "CASE_A" "// SPDX-License-Identifier: MIT"
    check_case "CASE_D" "contract Foo {}"
    check_case "CASE_F" ""
    check_case "CASE_G" "no sentinel at all, single line"
    B_FULL="$(awk '/^CASE_B\|/{print; getline; while ($0 !~ /^CASE_C\|/) { print; getline } exit}' "$PROBE/probe.log")"
    case "$B_FULL" in
      "CASE_B|contract Foo {}") ok "CASE_B (END own line): strips to exactly 'contract Foo {}'" ;;
      *) bad "CASE_B (END own line): unexpected '$B_FULL'" ;;
    esac
    C_LINE="$(grep '^CASE_C|' "$PROBE/probe.log" | head -1)"
    if [ "$C_LINE" = "CASE_C|contract Foo {}" ]; then
      ok "CASE_C (END appended suffix): strips to exactly 'contract Foo {}'"
    else
      bad "CASE_C (END appended suffix): unexpected '$C_LINE'"
    fi
    E_LINE="$(grep '^CASE_E|' "$PROBE/probe.log" | head -1)"
    if [ "$E_LINE" = "CASE_E|" ]; then
      ok "CASE_E (sentinel-only body): strips to empty"
    else
      bad "CASE_E (sentinel-only body): unexpected '$E_LINE'"
    fi
    awk '/^###HARNESS_BEGIN###$/{f=1;next} /^###HARNESS_END###$/{f=0} f' "$PROBE/probe.log" > "$WORK/filtered.t.sol"
    if [ -s "$WORK/filtered.t.sol" ] && head -1 "$WORK/filtered.t.sol" | grep -q '^// SPDX-License-Identifier'; then
      ok "sentinel-prefixed harness fixture: filtered first line is the SPDX header (sentinel gone)"
    else
      bad "sentinel-prefixed harness fixture: filtered output does not start with the SPDX header"
    fi
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# 4) LIVE GATE — exercise the real gate against a real forge project (skip cleanly when forge is absent).
# ----------------------------------------------------------------------------------------------------------
if ! command -v forge >/dev/null 2>&1; then
  skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run the live gate checks"
else
  note "4) live forge-invariant.sh gate: sentinel-prefixed -> HARNESS_ERROR, filtered -> CLEAN ..."
  PROJ="$WORK/proj"
  mkdir -p "$PROJ/src" "$PROJ/test"
  printf '[profile.default]\nsrc = "src"\nout = "out"\n\n[invariant]\nruns = 4\ndepth = 2\nfail_on_revert = false\n' \
    > "$PROJ/foundry.toml"
  cat > "$PROJ/src/Counter.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Counter {
  uint public total;
  function add(uint a) external { total += a; }
}
SOL

  # (a) sentinel-PREFIXED harness, exactly as an unfixed write_test() would have produced it: the gate must
  #     classify it as HARNESS_ERROR (2), never TRANSIENT_ERROR (3) — the #2245 bug 2 reproduction.
  printf 'FCB_1bacc818d7c9b2fcfadf940_BEGIN\n// SPDX-License-Identifier: MIT\npragma solidity ^0.8.20;\nimport {Counter} from "../src/Counter.sol";\nabstract contract InvBase {\n  address[] private _t;\n  function targetContracts() public view returns (address[] memory){ return _t; }\n  function _target(address a) internal { _t.push(a); }\n}\ncontract InvOkTest is InvBase {\n  Counter c;\n  function setUp() public { c = new Counter(); _target(address(c)); }\n  function invariant_total_nonneg() public view { require(c.total() >= 0, "x"); }\n}\n' \
    > "$PROJ/test/Inv_bad.t.sol"
  bad_out="$(sh "$GATE" --repo "$PROJ" --target test/Inv_bad.t.sol --match invariant 2>&1)"; bad_rc=$?
  if [ "$bad_rc" -eq 2 ]; then
    ok "sentinel-prefixed harness -> HARNESS_ERROR (2), never the misleading TRANSIENT_ERROR (3)"
  else
    bad "sentinel-prefixed harness should be HARNESS_ERROR (2), got rc=$bad_rc"
    printf '%s\n' "$bad_out" | sed 's/^/        | /' | tail -6
  fi

  # (b) the SAME source, stripped by the shipped native filter (part 2's agentis probe, when it ran) -> the
  #     sentinel is gone, the harness compiles, and the gate reaches a real verdict (CLEAN).
  if [ -s "$WORK/filtered.t.sol" ]; then
    cp "$WORK/filtered.t.sol" "$PROJ/test/Inv_good.t.sol"
    good_out="$(sh "$GATE" --repo "$PROJ" --target test/Inv_good.t.sol --match invariant 2>&1)"; good_rc=$?
    if [ "$good_rc" -eq 0 ]; then
      ok "filtered harness (strip_fcb_sentinel() output) compiles and reaches a real CLEAN verdict (0)"
    else
      bad "filtered harness should reach CLEAN (0), got rc=$good_rc"
      printf '%s\n' "$good_out" | sed 's/^/        | /' | tail -6
    fi
  else
    skip "no filtered harness available (agentis absent or the part-2 probe failed) — skipping the CLEAN-verdict check"
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "ALL CHECKS PASSED"
  exit 0
else
  note "$FAILS CHECK(S) FAILED"
  exit 1
fi
