#!/usr/bin/env bash
# V7 (#845) — operator entrypoint for a Dark Factory audit.
#
# Runs the .ag auditor colony end-to-end against an operator-chosen scope and, on a VERIFIED
# finding, assembles a human-gated submission package on disk. It NEVER contacts a bounty
# platform, NEVER auto-submits, and NEVER auto-picks a scope — the operator supplies the
# in-scope program (and, for a live target, the RPC dump). Submission is always a separate,
# explicit human action: a reviewer reads the package and submits it manually.
#
# Usage:
#   run-audit.sh --target <program.rs> [options]
# Options:
#   --target <file>          REQUIRED. The in-scope program source to audit.
#   --harness <dir>          Native solana-program-test harness dir (SOLANA_HARNESS_DIR).
#   --anchor-harness <dir>   Anchor harness dir (SOLANA_ANCHOR_HARNESS_DIR).
#   --snapshot <file>        Frozen on-chain account dump (BOUNTY_SNAPSHOT; see snapshot-rpc.sh).
#   --poc <file>             Operator-supplied PoC candidate (BOUNTY_POC; still gated).
#   --backend <mock|claude>  LLM backend (default: claude). mock = offline-deterministic.
#   --sandbox <hardened|none> Sandbox profile (default: hardened).
#   --out <dir>              Output dir for the run + submission package (default: ./audit-out).
#   --agentis <bin>          agentis binary (default: `agentis` on PATH).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
TARGET="" ; HARNESS="" ; ANCHOR_HARNESS="" ; SNAPSHOT="" ; POC=""
BACKEND="claude" ; SANDBOX="hardened" ; OUT="$PWD/audit-out"

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --harness) HARNESS="$2"; shift 2 ;;
    --anchor-harness) ANCHOR_HARNESS="$2"; shift 2 ;;
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --poc) POC="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --sandbox) SANDBOX="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --agentis) AGENTIS="$2"; shift 2 ;;
    --help|-h) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "run-audit.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$TARGET" ] || { echo "run-audit.sh: --target <program.rs> is required (the operator picks the in-scope program; this tool never auto-picks a scope)" >&2; exit 2; }
[ -f "$TARGET" ] || { echo "run-audit.sh: target not found: $TARGET" >&2; exit 2; }
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-audit.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

COLONY="$HERE/auditor/agents/auditor.ag"
[ -f "$COLONY" ] || { echo "run-audit.sh: colony not found at $COLONY" >&2; exit 3; }

mkdir -p "$OUT"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$COLONY" "$RUN/auditor.ag"

# init the agentis store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p"; echo "llm.cli_timeout_ms = 180000"; }
  echo "trace.level = normal"
  echo "exec.env_passthrough = BOUNTY_TARGET,BOUNTY_POC,SOLANA_HARNESS_DIR,SOLANA_ANCHOR_HARNESS_DIR,BOUNTY_SNAPSHOT"
  echo "exec.default_timeout_ms = 180000"
} > "$RUN/.agentis/config"

# scope env — only what the operator supplied reaches the (env_clear'd) sandbox.
ENV=(BOUNTY_TARGET="$TARGET")
[ -n "$HARNESS" ]        && ENV+=(SOLANA_HARNESS_DIR="$HARNESS")
[ -n "$ANCHOR_HARNESS" ] && ENV+=(SOLANA_ANCHOR_HARNESS_DIR="$ANCHOR_HARNESS")
[ -n "$SNAPSHOT" ]       && ENV+=(BOUNTY_SNAPSHOT="$SNAPSHOT")
[ -n "$POC" ]            && ENV+=(BOUNTY_POC="$POC")

GO=(go auditor.ag --enable-exec --enable-messaging)
[ "$SANDBOX" = "hardened" ] && GO+=(--sandbox-profile hardened)

echo "run-audit.sh: auditing $(basename "$TARGET") (backend=$BACKEND, sandbox=$SANDBOX)" >&2
( cd "$RUN" && env "${ENV[@]}" "$AGENTIS" "${GO[@]}" ) 2>&1 | tee "$RUN/audit.log"

VERDICT="$(grep -oE 'Verdict: [A-Z()a-z: -]+' "$RUN/audit.log" | tail -1 | sed 's/^Verdict: //')"
VERDICT="${VERDICT:-UNKNOWN}"
SANDBOX_DIR="$RUN/.agentis/sandbox"
echo >&2
echo "================ VERDICT: $VERDICT ================" >&2

case "$VERDICT" in
  VERIFIED)
    PKG="$OUT/submission"
    rm -rf "$PKG"; mkdir -p "$PKG"
    cp "$TARGET" "$PKG/target.rs" 2>/dev/null || true
    [ -f "$SANDBOX_DIR/report.md" ] && cp "$SANDBOX_DIR/report.md" "$PKG/report.md"
    # the harness-generated PoC (anchor or native) or the std-only standalone PoC
    for p in "$SANDBOX_DIR/poc_standalone.rs"; do [ -f "$p" ] && cp "$p" "$PKG/poc.rs"; done
    [ -n "$ANCHOR_HARNESS" ] && [ -f "$ANCHOR_HARNESS/src/bin/poc.rs" ] && cp "$ANCHOR_HARNESS/src/bin/poc.rs" "$PKG/poc.rs"
    [ -z "$ANCHOR_HARNESS" ] && [ -n "$HARNESS" ] && [ -f "$HARNESS/src/bin/poc.rs" ] && cp "$HARNESS/src/bin/poc.rs" "$PKG/poc.rs"
    [ -n "$SNAPSHOT" ] && [ -f "$SNAPSHOT" ] && cp "$SNAPSHOT" "$PKG/snapshot.txt"
    {
      echo "Dark Factory submission package"
      echo "verdict: VERIFIED"
      echo "target: $(basename "$TARGET")"
      echo "backend: $BACKEND   sandbox: $SANDBOX"
      echo "files: report.md (Immunefi-format finding, embeds the PoC), poc.rs, target.rs$( [ -n "$SNAPSHOT" ] && echo ", snapshot.txt")"
      echo
      echo "STATUS: PENDING HUMAN REVIEW — NOT SUBMITTED."
      echo "This colony NEVER posts to a bounty platform. Submission to Immunefi /"
      echo "Code4rena / Sherlock is a SEPARATE, explicit human action: a reviewer reads"
      echo "report.md and submits it manually."
    } > "$PKG/MANIFEST.txt"
    echo "run-audit.sh: submission package staged at $PKG" >&2
    echo "run-audit.sh: SUBMISSION IS HUMAN-GATED — review $PKG/report.md and submit manually. The colony never posts to a platform." >&2
    ;;
  *)
    echo "run-audit.sh: no submission package (verdict is not VERIFIED). See $RUN/audit.log." >&2
    ;;
esac
