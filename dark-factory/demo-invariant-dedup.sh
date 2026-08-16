#!/usr/bin/env bash
# demo-invariant-dedup.sh — offline proof of the #1926 pre-compile adjacent-duplicate-line guard.
#
# The problem (#1926 residual, proven live on the plaza Distributor<-BondToken composable seam): the harness
# generator sometimes STREAMS a duplication artifact — an unbalanced statement-opener
# (`bond = BondToken(address(new InvProxy(`) emitted on two adjacent byte-identical lines, leaving the first
# unclosed so the file fails to compile (`Error (2314): Expected ',' but got ';'`). The --repair-rounds loop
# rewrites the whole ~190-line harness each round and re-exposes the artifact, so it never converges. The fix
# is a conservative mechanical pass (evm-harness/dedup-harness-lines.sh) run on the *.t.sol BEFORE compile,
# in the forge-invariant.sh gate: it strips ONLY a line whose duplication is a guaranteed syntax error
# (adjacent, byte-identical, substantive, UNBALANCED parens — imports and balanced statements are untouched).
#
# This is a pure-bash, CI-safe fixture test (no LLM, no forge, no agentis): it drives the helper over five
# canned fixtures and asserts the safe predicate, then source-guards that forge-invariant.sh invokes the guard
# before the #1471 target-linkage block.
#
# Usage:  dark-factory/demo-invariant-dedup.sh
# Exit: 0 = all assertions hold ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEDUP="$HERE/evm-harness/dedup-harness-lines.sh"
FORGE_GATE="$HERE/evm-harness/forge-invariant.sh"

FAILS=0
note() { echo "demo-invariant-dedup.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -f "$DEDUP" ] || { note "guard not found: $DEDUP" >&2; exit 3; }
[ -f "$FORGE_GATE" ] || { note "forge gate not found: $FORGE_GATE" >&2; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# count occurrences of a single char in a file (paren-balance helper)
count_char() { tr -cd "$1" < "$2" | wc -c | tr -d ' '; }

# ----------------------------------------------------------------------------------------------------------
# 1) POSITIVE — the plaza artifact: two adjacent identical unbalanced openers collapse to one, restoring balance.
# ----------------------------------------------------------------------------------------------------------
# NOTE: the two duplicated openers carry DIFFERENT leading indentation (10 spaces then 6) — the real streaming
# artifact re-indents the duplicate, so the guard must match on CODE CONTENT, not byte-identity-with-indent.
note "positive: adjacent duplicated unbalanced opener at DIFFERENT indentation (the plaza streaming artifact) ..."
POS="$WORK/pos.t.sol"
cat > "$POS" <<'EOF'
        InvProxy impl = new InvProxy();
          bond = BondToken(address(new InvProxy(
      bond = BondToken(address(new InvProxy(
            address(impl), admin, initData
        )));
EOF
sh "$DEDUP" "$POS" 2>/dev/null || true
dup_n="$(grep -c 'bond = BondToken(address(new InvProxy($' "$POS" || true)"
open_p="$(count_char '(' "$POS")"; close_p="$(count_char ')' "$POS")"
if [ "$dup_n" -eq 1 ]; then
  ok "the duplicated unbalanced opener collapsed to a single occurrence"
else
  bad "expected exactly 1 opener after dedup, got $dup_n"
fi
if [ "$open_p" -eq "$close_p" ]; then
  ok "parentheses balance after dedup ('(' = ')' = $open_p)"
else
  bad "parentheses still unbalanced after dedup ('(' = $open_p, ')' = $close_p)"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) NEGATIVE — structural punctuation (no alnum → condition 3 fails): byte-identical, never touched.
# ----------------------------------------------------------------------------------------------------------
note "negative: adjacent structural closers are never eligible (condition 3) ..."
STRUCT="$WORK/struct.t.sol"
cat > "$STRUCT" <<'EOF'
                }
                }
            )
            )
        );
        );
        ));
        ));
EOF
cp "$STRUCT" "$WORK/struct.orig"
sh "$DEDUP" "$STRUCT" 2>/dev/null || true
if cmp -s "$WORK/struct.orig" "$STRUCT"; then
  ok "adjacent }/)/);/)); lines left byte-identical (structural punctuation never stripped)"
else
  bad "structural punctuation was modified — condition 3 (substantive) not enforced"
fi

# ----------------------------------------------------------------------------------------------------------
# 3) NEGATIVE — a duplicated BALANCED complete statement (condition 4 fails): never touched.
# ----------------------------------------------------------------------------------------------------------
note "negative: a duplicated balanced complete statement is never touched (condition 4) ..."
BAL="$WORK/bal.t.sol"
cat > "$BAL" <<'EOF'
        token.mint(user, 1e18);
        token.mint(user, 1e18);
EOF
cp "$BAL" "$WORK/bal.orig"
sh "$DEDUP" "$BAL" 2>/dev/null || true
if cmp -s "$WORK/bal.orig" "$BAL"; then
  ok "a duplicated balanced statement is left byte-identical (semantic-safety case)"
else
  bad "a duplicated balanced statement was stripped — condition 4 (unbalanced parens) not enforced"
fi

# Content-identical BALANCED statements at DIFFERENT indentation: relaxing condition 2 to content-identity
# must NOT let a balanced pair through — condition 4 (unbalanced parens) still excludes it, indentation aside.
BALIND="$WORK/bal_indent.t.sol"
cat > "$BALIND" <<'EOF'
        token.mint(user, 1e18);
            token.mint(user, 1e18);
EOF
cp "$BALIND" "$WORK/bal_indent.orig"
sh "$DEDUP" "$BALIND" 2>/dev/null || true
if cmp -s "$WORK/bal_indent.orig" "$BALIND"; then
  ok "content-identical BALANCED statements at different indentation are left byte-identical (condition 4 holds)"
else
  bad "a balanced content-duplicate was stripped — content-identity relaxation weakened condition 4"
fi

# ----------------------------------------------------------------------------------------------------------
# 4) NEGATIVE — a well-formed harness with no adjacent dups: the common-case no-op is byte-identical.
# ----------------------------------------------------------------------------------------------------------
note "negative: a well-formed harness is a byte-identical no-op ..."
WELL="$WORK/well.t.sol"
cat > "$WELL" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/Distributor.sol";
import "../src/BondToken.sol";

contract InvTest {
    Distributor dist;
    BondToken bond;

    function setUp() public {
        bond = new BondToken();
        dist = new Distributor(address(bond));
    }

    function invariant_solvency() public view {
        require(bond.totalSupply() <= dist.cap());
    }
}
EOF
cp "$WELL" "$WORK/well.orig"
sh "$DEDUP" "$WELL" 2>/dev/null || true
if cmp -s "$WORK/well.orig" "$WELL"; then
  ok "a well-formed harness is left bit-for-bit identical (no-op)"
else
  bad "a well-formed harness was modified — the guard is not a no-op on clean input"
fi

# ----------------------------------------------------------------------------------------------------------
# 5) DEPLOY-MARKER SURVIVAL (#1077) — a duplicated deploy opener collapses but the `new <Name>(` marker survives.
# ----------------------------------------------------------------------------------------------------------
note "deploy-marker survival: a duplicated deploy opener collapses, the #1077 signal is retained ..."
DEPLOY="$WORK/deploy.t.sol"
cat > "$DEPLOY" <<'EOF'
        token = new Token(
        token = new Token(
            "T", "T", 18
        );
EOF
sh "$DEDUP" "$DEPLOY" 2>/dev/null || true
opener_n="$(grep -c 'token = new Token($' "$DEPLOY" || true)"
marker_n="$(grep -c 'new Token(' "$DEPLOY" || true)"
if [ "$opener_n" -eq 1 ]; then
  ok "the duplicated deploy opener collapsed to a single occurrence"
else
  bad "expected exactly 1 deploy opener after dedup, got $opener_n"
fi
if [ "$marker_n" -ge 1 ]; then
  ok "the 'new Token(' deploy marker survives (#1077 both-real signal retained)"
else
  bad "the deploy marker was erased — #1077 signal lost"
fi

# ----------------------------------------------------------------------------------------------------------
# 6) SOURCE-GUARD — forge-invariant.sh invokes the guard BEFORE the #1471 target-linkage block.
# ----------------------------------------------------------------------------------------------------------
note "source-guard: forge-invariant.sh runs the guard before the #1471 gate ..."
dedup_ln="$(grep -n 'dedup-harness-lines.sh' "$FORGE_GATE" | tail -1 | cut -d: -f1)"
gate_ln="$(grep -n '#1471 TARGET-LINKAGE GATE' "$FORGE_GATE" | tail -1 | cut -d: -f1)"
if [ -n "$dedup_ln" ] && [ -n "$gate_ln" ] && [ "$dedup_ln" -lt "$gate_ln" ]; then
  ok "forge-invariant.sh calls dedup-harness-lines.sh (line $dedup_ln) before the #1471 block (line $gate_ln)"
else
  bad "forge-invariant.sh does not call the guard before the #1471 target-linkage gate"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #1926 dedup guard strips ONLY an adjacent content-identical, substantive, unbalanced-paren line"
  note "      (a guaranteed syntax error), is a byte-identical no-op on well-formed / structural / balanced"
  note "      harnesses, preserves the #1077 deploy marker, and runs before the #1471 gate in forge-invariant.sh."
  exit 0
fi
note "DEMO FAILED — a #1926 dedup-guard assertion did not hold" >&2
exit 1
