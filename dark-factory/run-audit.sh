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
#   run-audit.sh --target <program.rs|target.sol> [options]
#   run-audit.sh --repo <dir> --in-scope <path-within-repo> [options]   # real multi-file EVM target
# Options:
#   --target <file>          The in-scope program source to audit (.rs or .sol). REQUIRED unless --repo.
#   --repo <dir>             A real multi-file Foundry/Hardhat repo (clone with fetch-target.sh).
#                            The colony compiles the in-scope contract WITH its deps (#859 phases 1-4).
#   --in-scope <path>        Required with --repo: the in-scope contract, relative to <repo>.
#   --contract <Name>        With --repo: the contract name to extract (default: in-scope file basename).
#   --harness <dir>          Native solana-program-test harness dir (SOLANA_HARNESS_DIR).
#   --anchor-harness <dir>   Anchor harness dir (SOLANA_ANCHOR_HARNESS_DIR).
#   --evm-harness <dir>      EVM revm harness dir (EVM_HARNESS_DIR) for a Solidity target.
#                            With --repo this defaults to the bundled ./evm-harness when omitted.
#   --snapshot <file>        Frozen on-chain account dump (BOUNTY_SNAPSHOT; see snapshot-rpc.sh).
#   --poc <file>             Operator-supplied PoC candidate (BOUNTY_POC; still gated).
#   --seed-manifest <file>   Seed known-bug patterns from finished contests (#861): manifest lines
#                            `Class|abs-src-path|func-marker` (harvest-sherlock.js output).
#   --share-patterns         After seeding, publish each pattern to the knowledge market so other
#                            federation members can buy it (knowledge_sell; requires --seed-manifest).
#   --backend <flat-cyborg|claude|mock>  LLM backend (default: flat-cyborg). flat-cyborg = flat-rate
#                            PTY wrapper driving the interactive claude CLI ($0 subscription, via
#                            flat-cyborg-claude.sh); claude = metered `claude -p` API; mock = offline.
#   --sandbox <hardened|none> Sandbox profile (default: hardened).
#   --out <dir>              Output dir for the run + submission package (default: ./audit-out).
#   --agentis <bin>          agentis binary (default: `agentis` on PATH).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
TARGET="" ; HARNESS="" ; ANCHOR_HARNESS="" ; EVM_HARNESS="" ; SNAPSHOT="" ; POC=""
REPO="" ; IN_SCOPE="" ; CONTRACT="" ; SEED_MANIFEST="" ; SHARE_PATTERNS=""
BACKEND="flat-cyborg" ; SANDBOX="hardened" ; OUT="$PWD/audit-out" ; FUZZY_THRESHOLD="0.35" ; FUZZY_K="4" ; USE_EVOLVED=""

need() { [ "$1" -ge 2 ] || { echo "run-audit.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --target) need "$#"; TARGET="$2"; shift 2 ;;
    --repo) need "$#"; REPO="$2"; shift 2 ;;
    --in-scope) need "$#"; IN_SCOPE="$2"; shift 2 ;;
    --contract) need "$#"; CONTRACT="$2"; shift 2 ;;
    --seed-manifest) need "$#"; SEED_MANIFEST="$2"; shift 2 ;;
    --share-patterns) SHARE_PATTERNS=1; shift ;;
    --use-evolved) need "$#"; USE_EVOLVED="$2"; shift 2 ;;
    --fuzzy-threshold) need "$#"; FUZZY_THRESHOLD="$2"; shift 2 ;;
    --fuzzy-k) need "$#"; FUZZY_K="$2"; shift 2 ;;
    --harness) need "$#"; HARNESS="$2"; shift 2 ;;
    --anchor-harness) need "$#"; ANCHOR_HARNESS="$2"; shift 2 ;;
    --evm-harness) need "$#"; EVM_HARNESS="$2"; shift 2 ;;
    --snapshot) need "$#"; SNAPSHOT="$2"; shift 2 ;;
    --poc) need "$#"; POC="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --sandbox) need "$#"; SANDBOX="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-audit.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

# #861 M4: --use-evolved <evolve-out-dir> adopts the matcher granularity the pattern-evolver tuned
# against the fork-pair fitness oracle (evolved:fuzzy_threshold / evolved:fuzzy_k memos) instead of
# the hand-set default — the federation's own evolution picks the threshold/k.
if [ -n "$USE_EVOLVED" ]; then
  ET="$( ( cd "$USE_EVOLVED/run" 2>/dev/null && "$AGENTIS" memo get evolved:fuzzy_threshold 2>/dev/null ) || true )"
  EK="$( ( cd "$USE_EVOLVED/run" 2>/dev/null && "$AGENTIS" memo get evolved:fuzzy_k 2>/dev/null ) || true )"
  [ -n "$ET" ] && FUZZY_THRESHOLD="$ET"
  [ -n "$EK" ] && FUZZY_K="$EK"
  echo "run-audit.sh: adopted evolved matcher granularity threshold=$FUZZY_THRESHOLD k=$FUZZY_K" >&2
fi

# --repo mode (#859 phases 1-4): a REAL multi-file Foundry/Hardhat target. The operator points
# at the repo + the in-scope contract within it; the colony compiles that contract WITH its deps
# (remappings + lib/ submodules + node_modules) at the project's solc version. The in-scope file
# becomes the BOUNTY_TARGET (so ingest/reconn work unchanged); BOUNTY_REPO/BOUNTY_IN_SCOPE drive
# compile_run's project-compile path. --repo is EVM-only and defaults --evm-harness to the bundle.
if [ -n "$REPO" ]; then
  [ -d "$REPO" ] || { echo "run-audit.sh: --repo dir not found: $REPO (clone it first with fetch-target.sh)" >&2; exit 2; }
  REPO="$(cd "$REPO" && pwd)"
  [ -n "$IN_SCOPE" ] || { echo "run-audit.sh: --repo requires --in-scope <path-within-repo> (the operator picks the in-scope contract; this tool never auto-picks a scope)" >&2; exit 2; }
  [ -f "$REPO/$IN_SCOPE" ] || { echo "run-audit.sh: in-scope contract not found in repo: $REPO/$IN_SCOPE" >&2; exit 2; }
  [ -n "$TARGET" ] && { echo "run-audit.sh: pass either --target OR --repo/--in-scope, not both" >&2; exit 2; }
  TARGET="$REPO/$IN_SCOPE"            # the in-scope file IS the audit target (ingest/reconn read it)
  [ -n "$EVM_HARNESS" ] || EVM_HARNESS="$HERE/evm-harness"   # --repo is EVM; default to the bundled harness
fi

[ -n "$TARGET" ] || { echo "run-audit.sh: --target <program.rs|target.sol> (or --repo + --in-scope) is required (the operator picks the in-scope program; this tool never auto-picks a scope)" >&2; exit 2; }
[ -f "$TARGET" ] || { echo "run-audit.sh: target not found: $TARGET" >&2; exit 2; }
command -v "$AGENTIS" >/dev/null 2>&1 || [ -x "$AGENTIS" ] || { echo "run-audit.sh: agentis binary not found ($AGENTIS)" >&2; exit 3; }

# Resolve operator paths to ABSOLUTE — the colony runs with a different cwd, so a relative
# path would silently miss; an unreadable BOUNTY_TARGET must NEVER fall back to a built-in
# program (ingest_target() hard-fails on that, and we belt-and-suspenders it here).
TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
if [ -n "$SNAPSHOT" ]; then [ -f "$SNAPSHOT" ] || { echo "run-audit.sh: snapshot not found: $SNAPSHOT" >&2; exit 2; }; SNAPSHOT="$(cd "$(dirname "$SNAPSHOT")" && pwd)/$(basename "$SNAPSHOT")"; fi
if [ -n "$POC" ]; then [ -f "$POC" ] || { echo "run-audit.sh: poc not found: $POC" >&2; exit 2; }; POC="$(cd "$(dirname "$POC")" && pwd)/$(basename "$POC")"; fi
if [ -n "$HARNESS" ]; then [ -d "$HARNESS" ] || { echo "run-audit.sh: harness dir not found: $HARNESS" >&2; exit 2; }; HARNESS="$(cd "$HARNESS" && pwd)"; fi
if [ -n "$ANCHOR_HARNESS" ]; then [ -d "$ANCHOR_HARNESS" ] || { echo "run-audit.sh: anchor-harness dir not found: $ANCHOR_HARNESS" >&2; exit 2; }; ANCHOR_HARNESS="$(cd "$ANCHOR_HARNESS" && pwd)"; fi
if [ -n "$EVM_HARNESS" ]; then [ -d "$EVM_HARNESS" ] || { echo "run-audit.sh: evm-harness dir not found: $EVM_HARNESS" >&2; exit 2; }; EVM_HARNESS="$(cd "$EVM_HARNESS" && pwd)"; fi

# --repo: pre-compile the in-scope contract HOST-SIDE (this is the operator's one allowed network
# step, like snapshot-rpc.sh). It (1) fails fast if the imports/remappings/solc version are wrong
# — before the slow sandboxed run — and (2) warms .solc-cache with any non-pinned solc so the
# in-sandbox per-run compile (which re-runs with the anti-forgery challenge injected) stays offline.
if [ -n "$REPO" ]; then
  command -v node >/dev/null 2>&1 || { echo "run-audit.sh: node is required for --repo (the EVM project compiler runs on it)" >&2; exit 3; }
  echo "run-audit.sh: pre-compiling $IN_SCOPE against $REPO host-side (validates imports + warms solc)..." >&2
  node "$EVM_HARNESS/compile-project.js" "$REPO" "$IN_SCOPE" "$EVM_HARNESS/contracts/bin/Target.bin" "$CONTRACT" >&2 \
    || { echo "run-audit.sh: host-side compile of $IN_SCOPE failed — check --repo, --in-scope, remappings, and the solc version. Aborting before the sandboxed run." >&2; exit 4; }
fi

COLONY="$HERE/auditor/agents/auditor.ag"
[ -f "$COLONY" ] || { echo "run-audit.sh: colony not found at $COLONY" >&2; exit 3; }

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN"
cp "$COLONY" "$RUN/auditor.ag"

# init the agentis store FIRST (before any .agentis/ subdir exists), else HEAD is not set.
( cd "$RUN" && "$AGENTIS" init >/dev/null 2>&1 )
{
  echo "llm.backend = $BACKEND"
  # flat-cyborg = flat-rate PTY wrapper driving the interactive claude CLI (default, $0 subscription via
  # flat-cyborg-claude.sh); claude = metered `claude -p` API path (explicit opt-in only — do not default to it).
  [ "$BACKEND" = "claude" ] && { echo "llm.command = claude"; echo "llm.args = -p"; echo "llm.cli_timeout_ms = 180000"; }
  [ "$BACKEND" = "flat-cyborg" ] && { echo "llm.command = $HERE/flat-cyborg-claude.sh"; echo "llm.cli_timeout_ms = 180000"; }
  echo "trace.level = normal"
  echo "exec.env_passthrough = BOUNTY_TARGET,BOUNTY_POC,SOLANA_HARNESS_DIR,SOLANA_ANCHOR_HARNESS_DIR,EVM_HARNESS_DIR,BOUNTY_SNAPSHOT,BOUNTY_REPO,BOUNTY_IN_SCOPE,BOUNTY_CONTRACT,SEED_SRC,SEED_CLASS,SEED_FUNC,FUZZY_SEEDS,FUZZY_THRESHOLD,FUZZY_K"
  echo "exec.default_timeout_ms = 180000"
  # --share-patterns lists each seeded pattern on the knowledge market (knowledge_sell), so other
  # federation members can buy it. The market is gated on the learning/knowledge subsystem.
  [ -n "$SHARE_PATTERNS" ] && { echo "learning.enabled = true"; echo "experience.enabled = true"; echo "knowledge.enabled = true"; }
} > "$RUN/.agentis/config"

# #861: seed known-bug patterns into the DAG (bugpat:exact memos) BEFORE the audit, in the same
# store, so reconn matches a forked target's sub-graph and guard fires the class directly. Manifest
# lines: `Class|abs-src-path|func-marker` (e.g. `AccessControl|/.../VulnToken.sol|mint`); `#` = comment.
if [ -n "$SEED_MANIFEST" ]; then
  [ -f "$SEED_MANIFEST" ] || { echo "run-audit.sh: --seed-manifest not found: $SEED_MANIFEST" >&2; exit 2; }
  cp "$HERE/auditor/agents/seed-patterns.ag" "$RUN/seed-patterns.ag"
  echo "run-audit.sh: seeding known-bug patterns from $(basename "$SEED_MANIFEST")" >&2
  while IFS='|' read -r SCLASS SSRC SMARK || [ -n "$SCLASS" ]; do
    case "$SCLASS" in ''|\#*) continue ;; esac
    # EVM_HARNESS_DIR lets seed-patterns.ag also seed the STRUCTURAL signature (variant match) via
    # struct-sig.js; empty for non-EVM seeds, where the struct pass self-skips (len(ed)==0).
    ( cd "$RUN" && env SEED_CLASS="$SCLASS" SEED_SRC="$SSRC" SEED_FUNC="$SMARK" EVM_HARNESS_DIR="$EVM_HARNESS" "$AGENTIS" go seed-patterns.ag --enable-exec ) 2>&1 | grep -i 'seed' >&2 || true
  done < "$SEED_MANIFEST"

  # #861 M3+: build the fuzzy-match seed corpus (one `Class:::<normalized-sig>` per seed) so reconn's
  # fuzzy fallback can catch a RESTRUCTURED fork the exact + structural matchers miss. EVM-only.
  if [ -n "$EVM_HARNESS" ]; then
    : > "$RUN/fuzzy-seeds.tsv"
    while IFS='|' read -r SCLASS SSRC SMARK || [ -n "$SCLASS" ]; do
      case "$SCLASS" in ''|\#*) continue ;; esac
      sig=$(node "$EVM_HARNESS/struct-sig.js" "$SSRC" 2>/dev/null | grep "^${SMARK}:::" | head -1 | sed 's/^[^:]*::://')
      [ -n "$sig" ] && printf '%s:::%s\n' "$SCLASS" "$sig" >> "$RUN/fuzzy-seeds.tsv"
    done < "$SEED_MANIFEST"
  fi

  # #861: optionally publish every seeded pattern to the knowledge market ("DAG sdílej přes
  # knowledge market") so other federation members can buy it via knowledge_buy.
  if [ -n "$SHARE_PATTERNS" ]; then
    cp "$HERE/auditor/agents/share-patterns.ag" "$RUN/share-patterns.ag"
    ( cd "$RUN" && "$AGENTIS" go share-patterns.ag ) 2>&1 | grep -i 'share:' >&2
  fi
fi

# scope env — only what the operator supplied reaches the (env_clear'd) sandbox.
ENV=(BOUNTY_TARGET="$TARGET")
[ -n "$HARNESS" ]        && ENV+=(SOLANA_HARNESS_DIR="$HARNESS")
[ -n "$ANCHOR_HARNESS" ] && ENV+=(SOLANA_ANCHOR_HARNESS_DIR="$ANCHOR_HARNESS")
[ -n "$EVM_HARNESS" ]    && ENV+=(EVM_HARNESS_DIR="$EVM_HARNESS")
[ -f "$RUN/fuzzy-seeds.tsv" ] && ENV+=(FUZZY_SEEDS="$RUN/fuzzy-seeds.tsv" FUZZY_THRESHOLD="$FUZZY_THRESHOLD" FUZZY_K="$FUZZY_K")
[ -n "$SNAPSHOT" ]       && ENV+=(BOUNTY_SNAPSHOT="$SNAPSHOT")
[ -n "$POC" ]            && ENV+=(BOUNTY_POC="$POC")
[ -n "$REPO" ]           && ENV+=(BOUNTY_REPO="$REPO" BOUNTY_IN_SCOPE="$IN_SCOPE" BOUNTY_CONTRACT="$CONTRACT")

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
    # Preserve the target's extension in the package (.sol for an EVM target, .rs otherwise).
    case "$TARGET" in *.sol) TGT_NAME="target.sol" ;; *) TGT_NAME="target.rs" ;; esac
    cp "$TARGET" "$PKG/$TGT_NAME" 2>/dev/null || true
    [ -f "$SANDBOX_DIR/report.md" ] && cp "$SANDBOX_DIR/report.md" "$PKG/report.md"
    # the harness-generated PoC (anchor or native) or the std-only standalone PoC
    for p in "$SANDBOX_DIR/poc_standalone.rs"; do [ -f "$p" ] && cp "$p" "$PKG/poc.rs"; done
    [ -n "$ANCHOR_HARNESS" ] && [ -f "$ANCHOR_HARNESS/src/bin/poc.rs" ] && cp "$ANCHOR_HARNESS/src/bin/poc.rs" "$PKG/poc.rs"
    [ -z "$ANCHOR_HARNESS" ] && [ -n "$HARNESS" ] && [ -f "$HARNESS/src/bin/poc.rs" ] && cp "$HARNESS/src/bin/poc.rs" "$PKG/poc.rs"
    # EVM: the revm PoC the LLM wrote + the generic reentrancy attacker it was compiled against,
    # so the package reproduces against the in-scope target's bytecode.
    if [ -n "$EVM_HARNESS" ]; then
      [ -f "$EVM_HARNESS/src/bin/poc.rs" ] && cp "$EVM_HARNESS/src/bin/poc.rs" "$PKG/poc.rs"
      [ -f "$EVM_HARNESS/contracts/Attacker.sol" ] && cp "$EVM_HARNESS/contracts/Attacker.sol" "$PKG/Attacker.sol"
    fi
    [ -n "$SNAPSHOT" ] && [ -f "$SNAPSHOT" ] && cp "$SNAPSHOT" "$PKG/snapshot.txt"
    {
      echo "Dark Factory submission package"
      echo "verdict: VERIFIED"
      echo "target: $(basename "$TARGET")"
      echo "backend: $BACKEND   sandbox: $SANDBOX"
      echo "files: report.md (Immunefi-format finding, embeds the PoC), poc.rs, $TGT_NAME$( [ -n "$EVM_HARNESS" ] && echo ", Attacker.sol")$( [ -n "$SNAPSHOT" ] && echo ", snapshot.txt")"
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
