#!/usr/bin/env bash
# V4 / #842 — host-side on-chain account snapshot for the Dark Factory auditor.
#
# Fetches accounts from a Solana RPC (getAccountInfo, base64) and freezes them to a
# content-addressed snapshot file. Network is host-side + one-time; the frozen snapshot is
# then mounted read-only into the hardened sandbox and replayed offline through the real
# SVM (zero network inside the sandbox). The snapshot is the real account model — owner,
# lamports, data (base64) — not a hand-written stub.
#
# Usage:
#   snapshot-rpc.sh --rpc <url> --out <file> <pubkey> [<pubkey> ...]
#   snapshot-rpc.sh --out snap.txt <pubkey>            # default RPC = mainnet-beta
#
# Output format (one block per account, blocks separated by a line "---"):
#   account.pubkey=<base58>
#   account.owner=<base58>
#   account.lamports=<u64>
#   account.executable=<true|false>
#   account.rent_epoch=<u64>
#   account.data_b64=<base64 of the full account data>
#   account.data_first8_le=<u64>   # first 8 data bytes as little-endian u64 (replay convenience)
# plus a trailing `snapshot.sha256=<hex>` over the canonical (non-hash) lines.
set -eu

RPC="https://api.mainnet-beta.solana.com"
OUT=""
PUBKEYS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rpc) RPC="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --help|-h) sed -n '2,18p' "$0"; exit 0 ;;
    -*) echo "snapshot-rpc.sh: unknown flag $1" >&2; exit 2 ;;
    *) PUBKEYS+=("$1"); shift ;;
  esac
done

if [ -z "$OUT" ] || [ "${#PUBKEYS[@]}" -eq 0 ]; then
  echo "snapshot-rpc.sh: need --out <file> and at least one <pubkey>" >&2
  exit 2
fi

command -v curl >/dev/null || { echo "snapshot-rpc.sh: curl required" >&2; exit 3; }
command -v python3 >/dev/null || { echo "snapshot-rpc.sh: python3 required" >&2; exit 3; }

: > "$OUT"
first=1
for pk in "${PUBKEYS[@]}"; do
  [ "$first" -eq 1 ] || printf '%s\n' "---" >> "$OUT"
  first=0
  req=$(python3 -c 'import json,sys; print(json.dumps({"jsonrpc":"2.0","id":1,"method":"getAccountInfo","params":[sys.argv[1],{"encoding":"base64"}]}))' "$pk")
  resp=$(curl -sS -X POST "$RPC" -H 'Content-Type: application/json' -d "$req")
  # parse + emit the account block (python keeps base64 + u64 handling honest)
  printf '%s' "$resp" | python3 -c '
import json,sys,base64
pk=sys.argv[1]
d=json.load(sys.stdin)
v=(d.get("result") or {}).get("value")
if v is None:
    sys.stderr.write("snapshot-rpc.sh: account %s not found on chain\n"%pk); sys.exit(4)
data_b64=v["data"][0] if isinstance(v.get("data"),list) else ""
raw=base64.b64decode(data_b64) if data_b64 else b""
first8=int.from_bytes(raw[:8].ljust(8,b"\0"),"little")
print("account.pubkey=%s"%pk)
print("account.owner=%s"%v["owner"])
print("account.lamports=%d"%v["lamports"])
print("account.executable=%s"%("true" if v.get("executable") else "false"))
print("account.rent_epoch=%d"%v.get("rentEpoch",0))
print("account.data_b64=%s"%data_b64)
print("account.data_first8_le=%d"%first8)
' "$pk" >> "$OUT"
done

# content-address the frozen snapshot (sha256 over the account lines)
if command -v sha256sum >/dev/null; then
  h=$(sha256sum "$OUT" | awk '{print $1}')
else
  h=$(shasum -a 256 "$OUT" | awk '{print $1}')
fi
printf 'snapshot.sha256=%s\n' "$h" >> "$OUT"
echo "snapshot-rpc.sh: wrote $OUT (${#PUBKEYS[@]} account(s), sha256=${h:0:12})" >&2
