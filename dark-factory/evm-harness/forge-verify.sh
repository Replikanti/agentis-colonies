#!/usr/bin/env bash
# forge-verify.sh — the custom-protocol verification gate for the discovery track.
#
# The DAG/synthesis path (run-audit.sh + the revm two-sided gate) verifies ISOLATED function-level
# vulns. Custom multi-contract protocols (a stablecoin: manager + vault + oracle + ovault + ...) need a
# full deployment + an attacker tx + an invariant assertion — i.e. a real Foundry PoC. This gate
# runs a candidate's PoC test against the in-scope code and reports VERIFIED only if the exploit
# test PASSES (the invariant is broken / funds move). A candidate that does not compile+pass is
# NOT a finding (no junk submitted).
#
# Usage:
#   forge-verify.sh --repo <foundry-project-root> --poc <path/to/Exploit.t.sol> [--match <testFn>]
#                   [--lz-symlink] [--skip 'script/**']
# Exit: 0 = VERIFIED (PoC passed = exploit reproduced) ; 1 = NOT VERIFIED ; 2 = harness/usage error.
set -euo pipefail

REPO=""; POC=""; MATCH=""; LZ_SYMLINK=0; SKIP="script/**"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  REPO="$2"; shift 2 ;;
    --poc)   POC="$2"; shift 2 ;;
    --match) MATCH="$2"; shift 2 ;;
    --lz-symlink) LZ_SYMLINK=1; shift ;;
    --skip)  SKIP="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "forge-verify: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "forge-verify: --repo <foundry project root> required" >&2; exit 2; }
[ -n "$POC" ]  && [ -f "$POC" ]  || { echo "forge-verify: --poc <Exploit.t.sol> required" >&2; exit 2; }

export PATH="$HOME/.foundry/bin:$PATH"
command -v forge >/dev/null 2>&1 || { echo "forge-verify: forge not installed (run foundryup)" >&2; exit 2; }

# Populate submodules + the LayerZero-v2 monorepo casing symlink some OFT projects need.
( cd "$REPO" && git submodule update --init --recursive --depth 1 >/dev/null 2>&1 || true )
if [ "$LZ_SYMLINK" -eq 1 ] && [ -d "$REPO/lib/LayerZero-v2" ] && [ ! -e "$REPO/lib/layerzero-v2" ]; then
  ln -sfn LayerZero-v2 "$REPO/lib/layerzero-v2" || true
fi

# Drop the candidate PoC into the project's test tree so its remappings resolve.
POC_DST="$REPO/test/_dfverify_$(basename "$POC")"
cp "$POC" "$POC_DST"
trap 'rm -f "$POC_DST"' EXIT

echo "== forge-verify: running PoC $(basename "$POC") against $REPO ==" >&2
ARGS=(test --skip "$SKIP" --match-path "$(basename "$POC_DST")")
[ -n "$MATCH" ] && ARGS+=(--match-test "$MATCH")

# The PoC is written to PASS iff the exploit succeeds (assert the broken invariant). So forge test
# exit 0 == exploit reproduced == VERIFIED. A failing/non-compiling PoC == NOT verified.
if ( cd "$REPO" && forge "${ARGS[@]}" ) ; then
  echo "================ FORGE-VERIFY: VERIFIED (exploit PoC passed) ================" >&2
  exit 0
else
  echo "================ FORGE-VERIFY: NOT VERIFIED (PoC failed/did not compile) ================" >&2
  exit 1
fi
