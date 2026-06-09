#!/usr/bin/env bash
# Dark Factory — offline Solana PoC toolchain setup.
#
# Run ONCE per operator host, network ON. Stages the solana-program-test harness
# crate into the audit working directory and warm-builds its ~711-crate dependency
# graph so every subsequent audit run compiles + runs the generated PoC FULLY
# OFFLINE inside the hardened sandbox (the harness `.cargo/config.toml` pins
# net.offline + OPENSSL_NO_VENDOR). This is the only step that needs network —
# it is the epic's "network only host-side for repo/RPC fetch" allowance.
#
# Usage:  setup-solana-toolchain.sh [WORKDIR]
#   WORKDIR  audit working directory that becomes the hardened-sandbox workspace
#            (default: current directory). The warm harness is staged at
#            $WORKDIR/.solana-harness — it MUST live under the sandbox workspace
#            because the hardened profile binds only the workspace writable
#            (`--ro-bind / /` makes everything else read-only) and cargo needs to
#            write the incremental target dir.
#
# After it finishes, point the colony at the harness by allowlisting + exporting:
#   export SOLANA_HARNESS_DIR="$WORKDIR/.solana-harness"
#   # and add SOLANA_HARNESS_DIR to exec.env_passthrough in .agentis/config
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/solana-harness"
WORKDIR="${1:-$PWD}"
DEST="$WORKDIR/.solana-harness"

if [ ! -f "$SRC/Cargo.toml" ]; then
  echo "error: harness skeleton not found at $SRC" >&2
  exit 1
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found on PATH (install the Rust stable toolchain)" >&2
  exit 1
fi
if [ ! -f /usr/include/openssl/opensslv.h ]; then
  echo "warning: system OpenSSL dev headers not found — openssl-sys links the system" >&2
  echo "         library via OPENSSL_NO_VENDOR=1; install openssl-devel/libssl-dev." >&2
fi

echo "[setup] staging harness skeleton -> $DEST"
mkdir -p "$DEST"
# Copy the committed skeleton (Cargo.toml/.lock, .cargo/config.toml, src/) but not
# any pre-existing target/ — the warm build below produces a fresh one in place.
( cd "$SRC" && tar --exclude=./target -cf - . ) | ( cd "$DEST" && tar -xf - )

echo "[setup] fetching the dependency graph (network ON, one-time) ..."
( cd "$DEST" && CARGO_NET_RETRY=3 cargo fetch --locked )

echo "[setup] warm-building the harness (compiles ~711 crates; this is the slow part) ..."
# Build the default target + PoC so the dep artifacts are cached in $DEST/target.
# Subsequent per-audit builds recompile only src/target.rs + src/bin/poc.rs.
( cd "$DEST" && cargo build --offline --bin poc )

echo "[setup] verifying the default PoC runs offline (real SVM, two-sided) ..."
OUT="$( cd "$DEST" && CARGO_NET_OFFLINE=1 cargo run --quiet --offline --bin poc 2>&1 || true )"
if printf '%s' "$OUT" | grep -q 'INVARIANT VIOLATED:' && printf '%s' "$OUT" | grep -q 'CONTROL OK:'; then
  echo "[setup] OK — default two-sided PoC fired both markers through the real SVM."
else
  echo "[setup] WARNING — default PoC did not fire both markers; output:" >&2
  printf '%s\n' "$OUT" >&2
fi

echo "[setup] done. Warm target footprint: $(du -sh "$DEST/target" 2>/dev/null | cut -f1)"
echo
echo "Next: enable the harness for the colony —"
echo "  export SOLANA_HARNESS_DIR=\"$DEST\""
echo "  # add SOLANA_HARNESS_DIR (and BOUNTY_TARGET) to exec.env_passthrough in .agentis/config"
echo "Then run the auditor colony from $WORKDIR; it builds + runs each PoC offline via this harness."
