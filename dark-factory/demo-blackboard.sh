#!/usr/bin/env bash
# demo-blackboard.sh — reproducible, OFFLINE demo of the #1001 inter-agent coordination primitive.
#
# The discovery colony used to fan out independent one-shot audits: each (subsystem x class) cell was an
# island, so the run was exactly the sum of its cells. #1001 adds a shared in-run BLACKBOARD over the
# agentis memo store: a cell that surfaces a CANDIDATE posts a one-line lead (`memo_write` +
# `emit dark-factory:lead`), and every LATER cell reads the board (`recall_latest`) and is STEERED to
# corroborate a sibling's hit or pivot to a related surface. One cell's finding now changes what a
# later cell does — the point of the issue.
#
# This demo proves that loop end-to-end with NO network and NO real LLM, by standing up a deterministic
# fake `claude` on PATH. It runs the REAL `run-discovery.sh` against a 2-subsystem fixture:
#   cell 1  oracle / C2       -> finds a stale-price CANDIDATE, posts it to the blackboard
#   cell 2  liquidation / C2  -> reads the board; its prompt now carries the oracle lead, so it is steered
# The fake LLM ASSERTS on cell 2 that the prompt it received contains the oracle lead (the steer is real,
# not cosmetic), then returns a corroborating CANDIDATE. The demo asserts the coordination shows up in
# the run log + the discovery report, and exits non-zero if the steer did not happen.
#
# Usage:  dark-factory/demo-blackboard.sh
# Requires: the `agentis` binary on PATH. Exit 0 = the blackboard steered cell 2 from cell 1's finding.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
command -v agentis >/dev/null 2>&1 || { echo "demo-blackboard.sh: agentis binary not on PATH" >&2; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/target"; BIN="$WORK/bin"; OUT="$WORK/discovery-out"
mkdir -p "$REPO/contracts" "$BIN"

# --- fixture: an oracle lib + a liquidation engine that PRICES collateral through that oracle ---------
# (The shared dependency is the whole point: a lead in `oracle` is a prior for the `liquidation` cell.)
cat > "$REPO/contracts/OracleLib.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
interface IFeed { function latestRoundData() external view returns (uint80,int256,uint256,uint256,uint80); }
library OracleLib {
    // NOTE (planted lead): no staleness / updatedAt check — returns whatever the feed last reported.
    function getPrice(IFeed feed) internal view returns (uint256) {
        (, int256 answer,,,) = feed.latestRoundData();
        return uint256(answer);
    }
}
SOL
cat > "$REPO/contracts/LiquidationEngine.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {OracleLib, IFeed} from "./OracleLib.sol";
contract LiquidationEngine {
    using OracleLib for IFeed;
    IFeed public feed;
    mapping(address => uint256) public debt;
    mapping(address => uint256) public collateral;
    // Prices collateral via OracleLib.getPrice — inherits any oracle weakness on the liquidation path.
    function liquidate(address user) external {
        uint256 px = feed.getPrice();
        require(collateral[user] * px < debt[user] * 1e18, "healthy");
        collateral[user] = 0;
        debt[user] = 0;
    }
}
SOL

cat > "$WORK/brief.md" <<'MD'
# Demo protocol brief
Invariants: a position may be liquidated ONLY when genuinely under-collateralized at a FRESH price.
Known issues (do not report): none.
Trust model: the keeper role is trusted; all other callers are untrusted external attackers.
MD

# scope: oracle FIRST (it will post the lead), liquidation SECOND (it will read + be steered). Same class
# C2 keeps the demo focused; the steer is cross-SUBSYSTEM (oracle -> liquidation), the interesting case.
cat > "$WORK/scope.tsv" <<'TSV'
oracle      | C2 | contracts/OracleLib.sol
liquidation | C2 | contracts/LiquidationEngine.sol
TSV

# --- deterministic fake `claude`: the LLM the hunter shells out to (run-discovery sets llm.command=claude)
# It reads instruction+payload on stdin. For the liquidation cell it ASSERTS the blackboard FOCUS block
# (carrying the oracle lead) is present, writing a marker the demo checks — that assertion IS the proof
# the earlier cell steered the later one. Each cell gets a CANDIDATE so both post/observe the board.
cat > "$BIN/claude" <<EOF
#!/usr/bin/env bash
set -eu
PROMPT="\$(cat)"
if printf '%s' "\$PROMPT" | grep -q 'LiquidationEngine.sol'; then
  # cell 2: it MUST have received the oracle lead via the blackboard FOCUS block injected by hunter.ag.
  if printf '%s' "\$PROMPT" | grep -q 'BLACKBOARD'; then
    if printf '%s' "\$PROMPT" | grep -q 'oracle|C2'; then
      : > "$WORK/STEER_CONFIRMED"
    fi
  fi
  echo "Traced liquidate(): it prices collateral via OracleLib.getPrice, so the oracle lead applies here."
  echo "CANDIDATE|LiquidationEngine.sol:liquidate:11|C2|High|stale oracle price (sibling lead) lets a healthy position be liquidated|deploy a stale feed, call liquidate, assert seize succeeds"
  exit 0
fi
# cell 1 (oracle): surface the stale-price lead. No blackboard yet — it is the FIRST cell.
echo "Traced OracleLib.getPrice: no updatedAt/staleness guard, so a stale answer is accepted."
echo "CANDIDATE|OracleLib.sol:getPrice:7|C2|High|missing staleness check accepts a stale price|deploy a feed, let updatedAt go stale, read getPrice, assert it returns the stale value"
exit 0
EOF
chmod +x "$BIN/claude"

echo "demo-blackboard.sh: running run-discovery.sh (offline, fake LLM) ..." >&2
RUN_LOG="$WORK/run.log"
set +e
PATH="$BIN:$PATH" "$HERE/run-discovery.sh" \
  --repo "$REPO" --scope "$WORK/scope.tsv" --brief "$WORK/brief.md" \
  --backend claude --out "$OUT" >"$RUN_LOG" 2>&1
RC=$?
set -e

REPORT="$OUT/discovery-report.md"
echo
echo "================= run-discovery.sh log (coordination lines) ================="
grep -E 'hunting|COORDINATION|posted a lead|DISCOVERY:' "$RUN_LOG" || true
echo
echo "================= discovery-report.md ================="
cat "$REPORT" 2>/dev/null || echo "(no report)"
echo "======================================================="
echo

# --- assertions: the steer must be real (cell 2's prompt carried cell 1's lead) and visible ----------
FAIL=0
[ "$RC" -eq 0 ] || { echo "FAIL: run-discovery.sh exited $RC" >&2; FAIL=1; }
[ -f "$WORK/STEER_CONFIRMED" ] || { echo "FAIL: cell 2's prompt did NOT contain cell 1's blackboard lead (no steer)" >&2; FAIL=1; }
grep -q '^BLACKBOARD-POST|oracle|C2|' "$OUT"/run/hunt_oracle_C2.log 2>/dev/null \
  || { echo "FAIL: oracle cell did not POST its lead to the blackboard" >&2; FAIL=1; }
grep -q '^BLACKBOARD-FOCUS|liquidation|C2|' "$OUT"/run/hunt_liquidation_C2.log 2>/dev/null \
  || { echo "FAIL: liquidation cell did not log being steered by the blackboard" >&2; FAIL=1; }
grep -q 'Inter-agent coordination (blackboard' "$REPORT" 2>/dev/null \
  || { echo "FAIL: report is missing the coordination section" >&2; FAIL=1; }

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: cell 1 (oracle/C2) posted a lead; cell 2 (liquidation/C2) READ it from the blackboard and"
  echo "      was steered to corroborate it — one cell's finding changed what a later cell did. (#1001)"
  exit 0
fi
echo "DEMO FAILED — see $RUN_LOG" >&2
exit 1
