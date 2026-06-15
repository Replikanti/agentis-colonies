#!/usr/bin/env bash
# recon-from-address.sh — KEYLESS auto-recon. Given a deployed contract address + chain id, fetches the
# verified ABI from Sourcify (https://sourcify.dev — free, decentralized, NO API key) and emits a target
# recon spec that run-autoharness.sh consumes via --spec. This closes the last human step before the
# autonomous harness generator: address in -> recon spec out -> LLM-generated fork-fuzz harness -> hunt.
#
# No Etherscan key required (Sourcify is keyless). Contracts not verified on Sourcify cleanly [SKIP] with a
# hint to supply a manual spec instead; coverage is partial but spans a large fraction of mainnet DeFi.
#
# Usage: recon-from-address.sh --address <0x..> [--chain <id>] [--invariant "<text>"] [--out <file>]
#   --chain     : EVM chain id (default 1 = Ethereum mainnet).
#   --invariant : the deep no-free-value / solvency property to assert (default: a solvency template).
#   --out       : write the spec here (default: stdout, so it can be piped straight into --spec /dev/stdin).
# Requires: python3 + outbound HTTPS to sourcify.dev. Exit 0 on success OR clean [SKIP]; exit 2 on bad args.
set -u
# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise
# crash on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "recon-from-address.sh: $2 requires a value" >&2; exit 2; }; }
ADDR="" ; CHAIN="1" ; INV="" ; OUT=""
while [ $# -gt 0 ]; do case "$1" in
  --address) nv "$#" "$1"; ADDR="$2"; shift 2;; --chain) nv "$#" "$1"; CHAIN="$2"; shift 2;;
  --invariant) nv "$#" "$1"; INV="$2"; shift 2;; --out) nv "$#" "$1"; OUT="$2"; shift 2;;
  -h|--help) sed -n '2,13p' "$0"; exit 0;; *) echo "recon-from-address.sh: unknown arg $1" >&2; exit 2;; esac; done
case "$ADDR" in 0x*) :;; *) echo "recon-from-address.sh: --address <0x..> required" >&2; exit 2;; esac
command -v python3 >/dev/null || { echo "[SKIP] python3 not installed" >&2; exit 0; }

DEFAULT_INV='Solvency / no-free-value: after any seed-derived SEQUENCE of the operations below, the target
must remain solvent (total collateral value >= total liability value) and no caller may extract more value
than they put in. require() that invariant; a counterexample is a finding.'
[ -n "$INV" ] || INV="$DEFAULT_INV"

SPEC="$( ADDR="$ADDR" CHAIN="$CHAIN" INV="$INV" python3 -c '
import os, json, urllib.request
addr, chain, inv = os.environ["ADDR"], os.environ["CHAIN"], os.environ["INV"]
url = "https://sourcify.dev/server/v2/contract/%s/%s?fields=abi" % (chain, addr)
try:
    with urllib.request.urlopen(url, timeout=25) as r:
        d = json.load(r)
except Exception as e:
    raise SystemExit("SKIP:%s" % e)
abi = d.get("abi")
if not abi:
    raise SystemExit("SKIP:not verified on Sourcify")
def sig(fn):
    ins = ",".join(i.get("type","") for i in fn.get("inputs",[]))
    sm  = fn.get("stateMutability","")
    return "  %s(%s) [%s]" % (fn.get("name",""), ins, sm)
fns = [f for f in abi if f.get("type")=="function"]
muts = [sig(f) for f in fns if f.get("stateMutability") not in ("view","pure")]
views= [sig(f) for f in fns if f.get("stateMutability") in ("view","pure")]
print("TARGET %s (chain %s) — ABI auto-fetched keyless from Sourcify." % (addr, chain))
print("")
print("STATE-CHANGING operations (expose each as a fuzzable try/catch action):")
print("\n".join(muts) if muts else "  (none)")
print("")
print("VIEW functions (use these to read on-chain state, discover related addresses, and check the invariant):")
print("\n".join(views) if views else "  (none)")
print("")
print("DEEP INVARIANT TO ASSERT:")
print(inv)
' 2>&1 )"

case "$SPEC" in
  SKIP:*) echo "[SKIP] $ADDR not auto-reconnable: ${SPEC#SKIP:} — supply a manual --spec instead" >&2; exit 0;;
esac

if [ -n "$OUT" ]; then printf '%s\n' "$SPEC" > "$OUT"; echo "recon-from-address: wrote spec for $ADDR -> $OUT" >&2
else printf '%s\n' "$SPEC"; fi
