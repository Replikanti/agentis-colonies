#!/usr/bin/env bash
# demo-invariant-corpus-replay.sh — proof of the #1731 CROSS-RUN ENSEMBLE / UNION replay wiring.
#
# The gap this closes: run-to-run variance (#1716) means a class that produced a good invariant on one run may
# produce nothing on the next, and today only the WINNER's descriptor survives — every non-winning (yet valid)
# hypothesis is discarded. #1731 accumulates EVERY generated invariant (on a FINDING OR a CLEAN, not only the
# winners) and REPLAYS that accumulated UNION against a fresh target — cheaply, with NO extra LLM. The split is:
#   - SEED (invariant-prover.ag): a NEW persist_corpus() sibling of persist_teeth() writes the just-generated
#     invariant's descriptor into a NEW lowest-precedence invpat:corpus:<class> recall tier (ONE O(1) memo_write
#     per generation — no growing-set walk, no per-element .ag loop). recall_pattern() consults it as its WEAKEST
#     tier (FINDING > teeth > invented > corpus). Gated OFF by default (empty INV_CORPUS => early return).
#   - REPLAY (run-invariant-hunt.sh, SHELL): keeps the full generated test SOURCE per class under
#     --pattern-store/corpus/<class>/ and, under a default-off --replay-corpus flag, loops that BOUNDED set
#     (--corpus-max, content-addressed dedup + most-recent eviction) and re-runs the SAME staged fuzzer gate per
#     file — pure shell, NO agentis spawn per replay — re-using the #1471 link gate so a foreign-import replay is
#     HARNESS_ERROR, never a false verdict.
# The FUZZER stays the SOLE verdict throughout; the #1471 --require-import/--require-contract gate is untouched.
#
# This is a SOURCE-GUARD + offline-behavioural demo (always CI-safe, no LLM; the LIVE replay assertions run only
# when forge AND agentis are present and SKIP cleanly otherwise). It pins:
#   (a) persist_corpus() is defined, sits strictly AFTER the INVARIANT| marker AND after persist_pattern/
#       persist_teeth, persists on FINDING AND CLEAN, writes invpat:corpus:<class>, and is ONE memo_write per
#       verdict (no growing-set walk / no reduce / no recursion);
#   (b) the slice from persist_corpus to EOF references NONE of verdict_of / final_verdict / --require-import /
#       --require-contract (fuzzer stays sole verdict; #1471 gate untouched);
#   (c) recall_pattern consults invpat:corpus: as the LOWEST tier (latest > teeth > invented > corpus);
#   (d) persist_pattern (FINDING->invpat:latest:) and persist_teeth (credible->invpat:teeth:) are byte-unchanged;
#       the INVARIANT| marker, verdict_of, final_verdict, and the #1471 gate are all still present;
#   (e) persist_corpus early-returns on empty INV_CORPUS; the runner defaults --replay-corpus OFF and guards the
#       whole accumulate/replay block on $REPLAY_CORPUS + $PATTERN_STORE (replay-off => byte-identical); the
#       replay loop invokes the STAGED gate (not a fresh agentis) and reuses the #1471 link args; accumulation is
#       cp-into-<sha256>.t.sol + prune-to-CORPUS_MAX;
#   (f) INV_CORPUS is on exec.env_passthrough and threaded into the agentis go env block; bridge_invpat's
#       ^invpat: matcher already carries invpat:corpus: (no bridge change needed);
#   (g) LIVE (forge + agentis present): pre-accumulate >=2 distinct fixture invariants into a temp
#       --pattern-store, run once with --replay-corpus + a small --corpus-max, and assert >=2 `## Corpus replay`
#       rows appear AND the --corpus-max cap is enforced (<=N files kept after prune).
#
# Usage:  dark-factory/demo-invariant-corpus-replay.sh
# Exit: 0 = all assertions hold (live part SKIPs cleanly when the toolchain is absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
RUNNER="$HERE/run-invariant-hunt.sh"

FAILS=0
note() { echo "demo-invariant-corpus-replay.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$PROVER" ] || { note "prover not found: $PROVER" >&2; exit 3; }
[ -f "$RUNNER" ] || { note "runner not found: $RUNNER" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# (a) persist_corpus() — defined, AFTER the marker + persist_pattern/persist_teeth, FINDING AND CLEAN, ONE memo.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1731 persist_corpus seed ..."

if grep -q 'fn persist_corpus(corpusOn: string, verd: string, klass: string, target: string, matchPrefix: string) -> void' "$PROVER"; then
  ok "persist_corpus() is defined on the prover"
else
  bad "persist_corpus() missing from the prover"
fi

_marker_ln="$(grep -n 'print("INVARIANT|"' "$PROVER" | head -1 | cut -d: -f1)"
_pc_ln="$(grep -n 'fn persist_corpus(' "$PROVER" | head -1 | cut -d: -f1)"
_pp_ln="$(grep -n 'fn persist_pattern(' "$PROVER" | head -1 | cut -d: -f1)"
_pt_ln="$(grep -n 'fn persist_teeth(' "$PROVER" | head -1 | cut -d: -f1)"
if [ -n "$_marker_ln" ] && [ -n "$_pc_ln" ] && [ -n "$_pp_ln" ] && [ -n "$_pt_ln" ] \
   && [ "$_pc_ln" -gt "$_marker_ln" ] && [ "$_pc_ln" -gt "$_pp_ln" ] && [ "$_pc_ln" -gt "$_pt_ln" ]; then
  ok "persist_corpus sits strictly AFTER the INVARIANT| marker, persist_pattern, and persist_teeth"
else
  bad "persist_corpus is NOT after the marker + persist_pattern + persist_teeth (verdict must finalize first)"
fi

_pc_body="$(awk '/fn persist_corpus\(/{f=1} f{print} f&&/^}/{exit}' "$PROVER")"
if printf '%s\n' "$_pc_body" | grep -q 'if verd == "FINDING"' \
   && printf '%s\n' "$_pc_body" | grep -q 'if verd == "CLEAN"'; then
  ok "persist_corpus accumulates on a FINDING AND a CLEAN (every generated invariant, not only winners)"
else
  bad "persist_corpus does not persist on BOTH FINDING and CLEAN"
fi

if printf '%s\n' "$_pc_body" | grep -q 'memo_write("invpat:corpus:" + klass, psig);'; then
  ok "persist_corpus writes the NEW invpat:corpus:<class> namespace"
else
  bad "persist_corpus does not write invpat:corpus:<class>"
fi

# ONE O(1) memo_write per verdict branch — no growing-set walk, no reduce, no recursion in the .ag side. The
# body carries exactly two invpat:corpus: writes (FINDING + CLEAN), no reduce/recall walk, and `persist_corpus(`
# appears ONCE (the definition itself — a recursive call would make it appear twice).
_pc_corpus_writes="$(printf '%s\n' "$_pc_body" | grep -c 'memo_write("invpat:corpus:" + klass, psig);')"
_pc_selfrefs="$(printf '%s\n' "$_pc_body" | grep -c 'persist_corpus(')"
if [ "$_pc_corpus_writes" -eq 2 ] && [ "$_pc_selfrefs" -eq 1 ] && ! printf '%s\n' "$_pc_body" | grep -Eq 'reduce\(|recall_'; then
  ok "persist_corpus is ONE memo_write per verdict branch (no growing-set walk / reduce / recursion)"
else
  bad "persist_corpus has a growing-set walk / reduce / recursion (expected one O(1) memo_write per branch)"
fi

# ----------------------------------------------------------------------------------------------------------
# (b) FUZZER STAYS SOLE VERDICT — the slice from persist_corpus to EOF never touches the verdict machinery.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that persist_corpus never touches the verdict / #1471 gate ..."

_corpus_slice="$(awk -v s="$_pc_ln" 'NR>=s' "$PROVER" | grep -v '^[[:space:]]*//')"
if printf '%s\n' "$_corpus_slice" | grep -Eq 'verdict_of|final_verdict|--require-import|--require-contract'; then
  bad "the persist_corpus slice references verdict_of / final_verdict / the #1471 gate (must stay untouched)"
  printf '%s\n' "$_corpus_slice" | grep -En 'verdict_of|final_verdict|--require-import|--require-contract' | sed 's/^/         | /'
else
  ok "no persist_corpus code references verdict_of / final_verdict / --require-import / --require-contract"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) recall_pattern consults invpat:corpus: as the LOWEST tier (latest > teeth > invented > corpus).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the invpat:corpus: recall tier ordering ..."

if grep -q 'recall_latest("invpat:corpus:" + klass)' "$PROVER"; then
  ok "recall_pattern consults the invpat:corpus:<class> tier"
else
  bad "recall_pattern does not consult invpat:corpus:<class>"
fi

_latest_ln="$(grep -n 'recall_latest("invpat:latest:" + klass)' "$PROVER" | head -1 | cut -d: -f1)"
_teeth_ln="$(grep -n 'recall_latest("invpat:teeth:" + klass)' "$PROVER" | head -1 | cut -d: -f1)"
_invented_ln="$(grep -n 'recall_latest("invpat:invented:" + klass)' "$PROVER" | head -1 | cut -d: -f1)"
_corpus_ln="$(grep -n 'recall_latest("invpat:corpus:" + klass)' "$PROVER" | head -1 | cut -d: -f1)"
if [ -n "$_latest_ln" ] && [ -n "$_teeth_ln" ] && [ -n "$_invented_ln" ] && [ -n "$_corpus_ln" ] \
   && [ "$_latest_ln" -lt "$_teeth_ln" ] && [ "$_teeth_ln" -lt "$_invented_ln" ] && [ "$_invented_ln" -lt "$_corpus_ln" ]; then
  ok "recall precedence is FINDING (latest) > teeth > invented > corpus (a FINDING is never overridden)"
else
  bad "recall precedence is not latest > teeth > invented > corpus (a stronger tier could be overridden)"
fi

# ----------------------------------------------------------------------------------------------------------
# (d) persist_pattern (FINDING) + persist_teeth (credible) byte-unchanged; verdict/marker/#1471 anchors present.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the untouched FINDING / teeth paths + the verdict anchors ..."

if grep -q 'fn persist_pattern(verd: string, klass: string, target: string, matchPrefix: string) -> void' "$PROVER" \
   && awk '/fn persist_pattern\(/{f=1} f{print} f&&/^}/{exit}' "$PROVER" | grep -q 'if verd == "FINDING"' \
   && awk '/fn persist_pattern\(/{f=1} f{print} f&&/^}/{exit}' "$PROVER" | grep -q 'memo_write("invpat:latest:" + klass, psig);'; then
  ok "persist_pattern still guards FINDING and writes invpat:latest: (the FINDING learning path is intact)"
else
  bad "the FINDING -> invpat:latest: persist path changed (it must stay byte-untouched)"
fi

if awk '/fn persist_teeth\(/{f=1} f{print} f&&/^}/{exit}' "$PROVER" | grep -q 'memo_write("invpat:teeth:" + klass, psig);'; then
  ok "persist_teeth still writes invpat:teeth: (the #1728 credible-clean tier is intact)"
else
  bad "the credible-clean -> invpat:teeth: persist path changed (it must stay byte-untouched)"
fi

if grep -q 'print("INVARIANT|" + targetFn + "|" + verdict);' "$PROVER" \
   && grep -q 'fn verdict_of(rc: int) -> string' "$PROVER" \
   && grep -q 'fn final_verdict(rc: int, violated: bool) -> string' "$PROVER" \
   && grep -q -- '--require-import ' "$PROVER"; then
  ok "the INVARIANT| marker, verdict_of, final_verdict, and the #1471 --require-import gate are all still present"
else
  bad "a verdict/marker/#1471-gate anchor is missing (the fuzzer-sole-verdict contract must be intact)"
fi

# ----------------------------------------------------------------------------------------------------------
# (e) DEFAULT-OFF byte-identical + the runner replay/accumulate/prune wiring.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the default-off guard + the runner replay/accumulate/prune wiring ..."

if printf '%s\n' "$_pc_body" | grep -q 'if len(corpusOn) == 0 { return; }'; then
  ok "persist_corpus early-returns (no-op) when INV_CORPUS is empty (default-off => byte-identical)"
else
  bad "persist_corpus missing the empty-INV_CORPUS early-return guard"
fi

if grep -q 'REPLAY_CORPUS=""' "$RUNNER"; then
  ok "run-invariant-hunt.sh defaults --replay-corpus OFF (REPLAY_CORPUS=\"\")"
else
  bad "run-invariant-hunt.sh does not default --replay-corpus OFF"
fi

if grep -q 'if \[ -n "$REPLAY_CORPUS" \] && \[ -n "$PATTERN_STORE" \]; then' "$RUNNER"; then
  ok "the accumulate/replay block is gated on \$REPLAY_CORPUS + \$PATTERN_STORE (off => byte-identical)"
else
  bad "the accumulate/replay block is not gated on \$REPLAY_CORPUS + \$PATTERN_STORE"
fi

# replay_corpus invokes the STAGED gate, NOT a fresh agentis spawn (pure shell, no per-element .ag).
_rc_body="$(awk '/^replay_corpus\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$RUNNER")"
if printf '%s\n' "$_rc_body" | grep -q 'sh "$RUN/forge-invariant.sh" --repo "$REPO_IN_RUN"' \
   && ! printf '%s\n' "$_rc_body" | grep -Eq '"\$AGENTIS" go|agentis go'; then
  ok "replay_corpus runs the STAGED forge-invariant gate per file (NO agentis spawn, NO per-element .ag loop)"
else
  bad "replay_corpus does not run the staged gate / spawns agentis (the replay must be pure shell)"
fi

if printf '%s\n' "$_rc_body" | grep -q 'CORPUS_LINK_ARGS\[@\]' \
   && grep -q 'CORPUS_LINK_ARGS=(--require-import "$CODE_IN_RUN")' "$RUNNER"; then
  ok "replay reuses the #1471 link args (--require-import [+ --require-contract]) in pure fresh-deploy mode"
else
  bad "replay does not reuse the #1471 link args"
fi

if grep -q 'cp "$THIS_INV" "$CORPUS_DIR/$_sha.t.sol"' "$RUNNER" \
   && grep -q 'sha256sum "$THIS_INV"' "$RUNNER"; then
  ok "accumulation is content-addressed: cp INV_OUT -> <sha256>.t.sol (identical hypothesis stored once = dedup)"
else
  bad "accumulation is not content-addressed into <sha256>.t.sol"
fi

if grep -q 'tail -n +"$((CORPUS_MAX + 1))"' "$RUNNER"; then
  ok "the corpus is pruned to CORPUS_MAX most-recent (bounds BOTH storage and replay cost)"
else
  bad "the corpus is not pruned to CORPUS_MAX (unbounded growth risk)"
fi

if grep -q 'case "$CORPUS_MAX" in' "$RUNNER"; then
  ok "--corpus-max is whole-number validated"
else
  bad "--corpus-max is not whole-number validated"
fi

# ----------------------------------------------------------------------------------------------------------
# (f) ENV WIRING — INV_CORPUS on exec.env_passthrough + threaded into the env block; bridge already carries it.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the INV_CORPUS env wiring ..."

if grep -q 'exec.env_passthrough = .*,INV_CORPUS"' "$RUNNER"; then
  ok "INV_CORPUS is on the exec.env_passthrough allowlist (else getenv would read empty)"
else
  bad "INV_CORPUS is not on exec.env_passthrough (the getenv read would be silently inert)"
fi

if grep -q 'INV_CORPUS="$INV_CORPUS_VAL" \\' "$RUNNER" \
   && grep -q 'if \[ -n "$REPLAY_CORPUS" \] && \[ -n "$PATTERN_STORE" \]; then INV_CORPUS_VAL=1; fi' "$RUNNER"; then
  ok "INV_CORPUS_VAL=1 is threaded ONLY under --replay-corpus + --pattern-store (else \"\" => byte-identical)"
else
  bad "INV_CORPUS is not threaded into the env block gated on --replay-corpus + --pattern-store"
fi

# bridge_invpat's ^invpat: matcher already carries invpat:corpus: — no bridge change needed.
if awk '/^bridge_invpat\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$RUNNER" | grep -q "grep -E '\^invpat:'"; then
  ok "bridge_invpat's ^invpat: matcher already ferries invpat:corpus: across stores (no bridge change needed)"
else
  bad "bridge_invpat's ^invpat: matcher is missing (invpat:corpus: would not persist across runs)"
fi

# run-zone-hunt.sh forwards the three flags verbatim to both deep-hunt invocations (thin pass-through).
ZONE="$HERE/run-zone-hunt.sh"
if [ -f "$ZONE" ]; then
  _fwd_count="$(grep -c '${DEEP_FWD\[@\]+"${DEEP_FWD\[@\]}"}' "$ZONE")"
  if grep -q 'DEEP_FWD+=(--replay-corpus)' "$ZONE" \
     && grep -q 'DEEP_FWD+=(--pattern-store "$2")' "$ZONE" \
     && grep -q 'DEEP_FWD+=(--corpus-max "$2")' "$ZONE" \
     && [ "$_fwd_count" -eq 2 ]; then
    ok "run-zone-hunt.sh forwards --pattern-store/--replay-corpus/--corpus-max verbatim to BOTH \$INVHUNT calls"
  else
    bad "run-zone-hunt.sh does not forward the three flags to both deep-hunt invocations"
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# (g) LIVE — pre-accumulate >=2 fixtures, replay once, assert >=2 rows + the --corpus-max cap is enforced.
# ----------------------------------------------------------------------------------------------------------
if ! command -v forge >/dev/null 2>&1; then
  skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run the live replay assertions"
elif ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the agentis runtime to run the live replay assertions"
else
  note "running the live cross-run replay assertions under forge + agentis ..."
  [ -x "$RUNNER" ] || { note "runner not executable: $RUNNER" >&2; exit 3; }
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT

  # A tiny VULNERABLE ERC4626-style vault (no virtual offset) — the same shape demo-invariant-hunt.sh uses. The
  # victim_not_robbed invariant breaks on it (FINDING), so the primary run accumulates and the replays surface.
  mkdir -p "$WORK/repo/src" "$WORK/repo/test"
  printf '[profile.default]\nsrc = "src"\nout = "out"\n\n[invariant]\nruns = 64\ndepth = 32\nfail_on_revert = false\n' > "$WORK/repo/foundry.toml"
  cat > "$WORK/repo/src/Vault.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Token {
  mapping(address=>uint) public balanceOf; uint public totalSupply;
  function mint(address to,uint a) external { balanceOf[to]+=a; totalSupply+=a; }
  function transfer(address to,uint a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[to]+=a; return true; }
  function transferFrom(address f,address t,uint a) external returns(bool){ balanceOf[f]-=a; balanceOf[t]+=a; return true; }
}
contract Vault {
  Token public asset; uint public totalShares; mapping(address=>uint) public shares;
  constructor(Token a){ asset=a; }
  function deposit(uint assets) external returns(uint s){
    uint ta = asset.balanceOf(address(this));
    s = totalShares==0 ? assets : assets*totalShares/ta;
    asset.transferFrom(msg.sender,address(this),assets);
    shares[msg.sender]+=s; totalShares+=s;
  }
  function withdraw(uint s) external returns(uint assets){
    uint ta = asset.balanceOf(address(this));
    assets = s*ta/totalShares;
    shares[msg.sender]-=s; totalShares-=s;
    asset.transfer(msg.sender,assets);
  }
}
SOL

  # The proven fixture handler+invariant (verbatim from demo-invariant-hunt.sh). Used as the primary run's
  # --handler-fixture AND as the corpus seed content (distinct copies below give distinct sha => distinct rows).
  cat > "$WORK/fixture.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Vault, Token} from "../src/Vault.sol";
contract Handler {
    Vault public v; Token public t;
    uint public victimDeposited;
    uint public victimShares;
    constructor(Vault _v, Token _t){ v=_v; t=_t; }
    function _bound(uint x, uint lo, uint hi) internal pure returns (uint) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
    function attackerSeed() public { t.mint(address(this), 1); v.deposit(1); }
    function attackerDonate(uint a) public { a = _bound(a, 1, 1e24); t.mint(address(v), a); }
    function victimDeposit(uint a) public {
        a = _bound(a, 1e6, 1e18);
        t.mint(address(this), a);
        uint s = v.deposit(a);
        victimDeposited += a; victimShares += s;
    }
}
abstract contract InvBase {
    address[] private _targets;
    function targetContracts() public view returns (address[] memory) { return _targets; }
    function _target(address a) internal { _targets.push(a); }
}
contract VaultInvariantTest is InvBase {
    Vault v; Token t; Handler h;
    function setUp() public { t=new Token(); v=new Vault(t); h=new Handler(v,t); _target(address(h)); }
    function invariant_victim_not_robbed() public view {
        uint vd = h.victimDeposited();
        if (vd == 0) return;
        uint ts = v.totalShares();
        uint claim = ts == 0 ? 0 : h.victimShares() * t.balanceOf(address(v)) / ts;
        require(claim + 1e6 >= vd, "victim robbed");
    }
}
SOL

  # Pre-accumulate 3 DISTINCT corpus hypotheses (each a valid copy with a unique trailing comment => unique
  # sha256 => a distinct corpus file + a distinct replay row) into the pattern-store's corpus dir, so the replay
  # sees a prior UNION independent of this run. --corpus-max 2 bounds BOTH the replay (head -n 2) and the prune.
  STORE="$WORK/store"
  CLASS_SLUG="C-erc4626"
  mkdir -p "$STORE/corpus/$CLASS_SLUG"
  for i in 1 2 3; do
    { cat "$WORK/fixture.t.sol"; printf '// corpus variant %s\n' "$i"; } > "$STORE/corpus/$CLASS_SLUG/variant-$i.t.sol"
  done
  _seeded="$(ls "$STORE/corpus/$CLASS_SLUG"/*.t.sol 2>/dev/null | wc -l | tr -d ' ')"

  OUTDIR="$WORK/out"
  note "  running run-invariant-hunt.sh --replay-corpus --corpus-max 2 over the pre-seeded union ..."
  "$RUNNER" --repo "$WORK/repo" --target "Vault.sol:Vault" --class "C-erc4626" \
            --handler-fixture "$WORK/fixture.t.sol" --backend mock \
            --runs 64 --depth 32 --seed 1 --out "$OUTDIR" \
            --pattern-store "$STORE" --replay-corpus --corpus-max 2 >"$WORK/run.log" 2>&1
  _rc=$?
  REPORT="$OUTDIR/invariant-report.md"

  if [ "$_rc" -ne 0 ] || [ ! -f "$REPORT" ]; then
    bad "run-invariant-hunt.sh --replay-corpus did not complete (exit $_rc); log tail:"
    sed 's/^/         | /' "$WORK/run.log" 2>/dev/null | tail -20
  else
    if grep -q '## Corpus replay (union of prior hypotheses)' "$REPORT"; then
      ok "the report carries the ## Corpus replay (union of prior hypotheses) section"
    else
      bad "the report is missing the ## Corpus replay section"
    fi
    # Count the replay rows (table rows for a corpus entry, i.e. a *.t.sol filename in the first cell).
    _rows="$(grep -cE '^\| .*\.t\.sol \|' "$REPORT" || true)"
    if [ "${_rows:-0}" -ge 2 ]; then
      ok "the replay produced >=2 corpus rows (seeded $_seeded, --corpus-max 2 => 2 replayed): $_rows rows"
      note "  the corpus-replay section:"
      sed -n '/## Corpus replay/,$p' "$REPORT" | sed 's/^/         | /'
    else
      bad "expected >=2 corpus replay rows, got ${_rows:-0}"
      sed 's/^/         | /' "$WORK/run.log" 2>/dev/null | tail -20
    fi
    # Cap enforcement: after accumulate (this run's FINDING) + prune, <= --corpus-max files remain.
    _kept="$(ls "$STORE/corpus/$CLASS_SLUG"/*.t.sol 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${_kept:-99}" -le 2 ]; then
      ok "the --corpus-max cap is enforced: $_kept file(s) kept after accumulate + prune (<= 2)"
    else
      bad "the --corpus-max cap was NOT enforced: $_kept files kept (expected <= 2)"
    fi
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #1731 cross-run ensemble/union replay is wired — invariant-prover.ag accumulates EVERY generated"
  note "      invariant (FINDING OR CLEAN) into the NEW lowest-precedence invpat:corpus: recall tier in ONE O(1)"
  note "      memo_write (no per-element .ag loop), strictly AFTER the fuzzer's INVARIANT| marker + persist_pattern"
  note "      + persist_teeth; recall precedence stays FINDING > teeth > invented > corpus; the FINDING/teeth paths,"
  note "      the verdict/marker, and the #1471 gate are byte-untouched. run-invariant-hunt.sh replays the BOUNDED"
  note "      (content-addressed dedup + --corpus-max) union through the SAME staged gate in pure shell (no agentis"
  note "      spawn per replay), and the whole path is default-off byte-identical. (Live replay rows are the"
  note "      fuzzer's — run under forge + agentis.)"
  exit 0
fi
note "DEMO FAILED — a #1731 corpus-replay assertion did not hold" >&2
exit 1
