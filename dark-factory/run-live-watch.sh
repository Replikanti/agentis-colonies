#!/bin/sh
# run-live-watch.sh — DERIVE-ONCE → WATCH-CONTINUOUSLY bridge for the Dark Factory federation (#1086).
#
# The monitor colony's `invariant-watcher` (#1085) evaluates ONE env-configured invariant against LIVE
# on-chain state via read-only `cast`/RPC. dark-factory already DERIVES a target's deep invariants
# (run-invariant-hunt.sh + auditor/agents/invariant-prover.ag + evm-harness/). #1086 bridges the two: derive
# the target's invariant SET ONCE, then emit a WATCH-SPEC the watcher consumes (MONITOR_INV_SPEC) so the
# WHOLE set is watched continuously — no re-derivation per tick.
#
# This script does NOT watch anything itself and is NEVER on the per-tick hot path. It runs the (heavy,
# LLM/forge-backed) derivation EXACTLY ONCE for a target and writes a small, static watch-spec file. The
# monitor colony then polls that spec read-only forever. The derivation is REUSED, not reinvented: the live
# path shells out to the sibling `run-invariant-hunt.sh` (the established invariant-prover derivation entry
# point); the offline/deterministic path takes a ready-made spec VERBATIM (the `--spec-fixture` sibling of
# run-invariant-hunt.sh's `--handler-fixture`), so the derive→spec wiring is provable with zero LLM/forge.
#
# READ-ONLY / NON-CUSTODIAL: the emitted watch-spec only ever drives `cast call` reads in the watcher; it
# carries no keys and never describes a write. A watch-spec is a set of FACTS to read + compare, never an
# action.
#
# WATCH-SPEC FORMAT (the file this script emits; the contract MONITOR_INV_SPEC consumes). A JSON array; one
# object per invariant:
#   [{"label":"...","lhs_sig":"totalSupply()","rhs_sig":"totalAssets()","rhs_const":"","rel":"le","margin_bp":0}, ...]
#   label     human label for the invariant (alert body); defaults to lhs_sig downstream when empty.
#   lhs_sig   the `cast call` view signature for the LEFT-hand quantity (REQUIRED; an entry with no lhs_sig
#             ends the set when walked). e.g. "totalSupply()".
#   rhs_sig   the view signature for the RIGHT-hand quantity, OR "" to use rhs_const instead.
#   rhs_const a literal integer RIGHT-hand bound, used only when rhs_sig is "".
#   rel       the relation that MUST hold: "le" (lhs<=rhs) | "ge" (lhs>=rhs) | "eq". Defaults to "le".
#   margin_bp margin-to-violation band in basis points (0..10000); 0 = only a hard violation flags.
#
# TARGET FINGERPRINT (#1097) — written alongside the spec at <out>.fingerprint.json:
#   {"address":"0x..","rpc_url":"...","code_hash":"<sha256 of cast code>","impl_slot":"<EIP-1967 impl slot value>"}
# A static watch-spec silently stops matching the deployed contract once the target UPGRADES (new impl, new
# selectors). monitor/scripts/check-drift.sh re-reads this fingerprint and raises a `drift` alert (severity
# high) when the deployed code / impl no longer matches — so the monitor SAYS it has gone blind rather than
# keep "watching" stale invariants. READ-ONLY: the fingerprint is captured with `cast code` / `cast storage`
# only. Re-derivation hook: re-run this script (e.g. `run-live-watch.sh --rederive ...` from cron) to derive a
# fresh spec + fingerprint and hot-swap MONITOR_INV_SPEC (operator-gated — re-derivation needs the LLM/forge path).
#
# Usage:
#   run-live-watch.sh --repo <foundry project> --target <Contract.sol[:Name]> --address <0x..> \
#                     --rpc-url <http(s)-rpc> [options]
#
# Options:
#   --repo <dir>          Foundry project root (must hold foundry.toml). REQUIRED on the LIVE path — the
#                         derivation builds its test there. Not required when --spec-fixture is supplied.
#   --target <C.sol[:Name]>  Target contract label (the lens), e.g. "Vault.sol:Vault". REQUIRED on the LIVE path.
#   --address <0x..>      The DEPLOYED contract address the emitted spec's `cast call`s read from. REQUIRED.
#                         Validated as 0x + 40 hex; surfaced in the spec metadata only — the watcher's own
#                         MONITOR_TARGET still selects the read address at watch time.
#   --rpc-url <rpc>       The read-only RPC the watcher will read from. REQUIRED; validated as an http(s) URL.
#                         Recorded as spec metadata for the operator; the watcher reads MONITOR_RPC_URL.
#   --class <id>          The bug-class lens the target is filed under (forwarded to the derivation); "" if unknown.
#   --code <file>         Target contract source the derivation reads (forwarded to run-invariant-hunt.sh --code).
#   --spec-fixture <file> A ready-made watch-spec JSON used VERBATIM — the OFFLINE/deterministic path, NO LLM
#                         and NO forge. When set the derivation is NOT run; the fixture is validated as a JSON
#                         array of watch-spec objects and emitted as the spec. The sibling of
#                         run-invariant-hunt.sh's --handler-fixture.
#   --backend <b>         LLM backend forwarded to run-invariant-hunt.sh on the live path (default flat-cyborg).
#   --runs N / --depth D / --seed S   Forge invariant budgets forwarded to the derivation (live path).
#   --out <file>          Where to write the watch-spec JSON (default: ./live-watch-out/watch-spec.json).
#   --cast <bin>          (#1097) foundry `cast` binary used to capture the target fingerprint (deployed-code
#                         hash + EIP-1967 impl slot) at <out>.fingerprint.json (default `cast` on PATH). A
#                         missing cast / unreachable RPC writes an empty fingerprint — the drift check stays quiet.
#   --rederive            (#1097) re-derivation hook: re-run the derivation and overwrite the spec + fingerprint
#                         (e.g. from cron). Behaves like a normal live run; accepted for intent / scripting.
#   --agentis <bin>       agentis binary (forwarded to run-invariant-hunt.sh; default `agentis` on PATH).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
REPO=""; TARGET=""; ADDRESS=""; RPC_URL=""; CLASS=""; CODE=""; SPEC_FIXTURE=""
BACKEND="flat-cyborg"; RUNS=""; DEPTH=""; SEED=""; OUT="$PWD/live-watch-out/watch-spec.json"
# #1097: the foundry `cast` binary used to capture the deployed-target FINGERPRINT
# (deployed-bytecode hash + EIP-1967 implementation slot) at derivation time. The
# fingerprint is written next to the spec so check-drift.sh can detect when the
# deployed contract upgraded out from under a now-stale watch-spec. "" / unreachable
# RPC => the fingerprint is written with empty fields (drift check stays quiet — it
# can only flag a CHANGE vs a captured baseline, never a false alarm).
CAST="cast"
REDERIVE=0

need() { [ "$1" -ge 2 ] || { echo "run-live-watch.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "$#"; REPO="$2"; shift 2 ;;
    --target) need "$#"; TARGET="$2"; shift 2 ;;
    --address) need "$#"; ADDRESS="$2"; shift 2 ;;
    --rpc-url) need "$#"; RPC_URL="$2"; shift 2 ;;
    --class) need "$#"; CLASS="$2"; shift 2 ;;
    --code) need "$#"; CODE="$2"; shift 2 ;;
    --spec-fixture) need "$#"; SPEC_FIXTURE="$2"; shift 2 ;;
    --backend) need "$#"; BACKEND="$2"; shift 2 ;;
    --runs) need "$#"; RUNS="$2"; shift 2 ;;
    --depth) need "$#"; DEPTH="$2"; shift 2 ;;
    --seed) need "$#"; SEED="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --cast) need "$#"; CAST="$2"; shift 2 ;;
    --rederive) REDERIVE=1; shift ;;
    --agentis) need "$#"; AGENTIS="$2"; shift 2 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "run-live-watch.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

# --address / --rpc-url anchor the spec to a deployed contract on a read-only chain; both are validated so a
# typo is a clean usage error here, never an opaque downstream failure. The watcher reads the address/RPC from
# its OWN env (MONITOR_TARGET / MONITOR_RPC_URL); these are recorded in the emitted spec's metadata so the
# operator can wire the watcher's env to the same target the spec was derived for.
case "$ADDRESS" in
  0x*) _hex="${ADDRESS#0x}"; case "$_hex" in *[!0-9a-fA-F]*) _bad=1 ;; *) [ "${#_hex}" -eq 40 ] && _bad=0 || _bad=1 ;; esac ;;
  *) _bad=1 ;;
esac
[ "${_bad:-1}" -eq 0 ] || { echo "run-live-watch.sh: --address must be 0x + 40 hex (got: $ADDRESS)" >&2; exit 2; }
case "$RPC_URL" in
  http://*|https://*) ;;
  *) echo "run-live-watch.sh: --rpc-url must be an http(s) URL (got: $RPC_URL)" >&2; exit 2 ;;
esac
for v in "$RUNS" "$DEPTH" "$SEED"; do
  case "$v" in '') ;; *[!0-9]*) echo "run-live-watch.sh: --runs/--depth/--seed must be whole numbers" >&2; exit 2 ;; esac
done
command -v python3 >/dev/null 2>&1 || { echo "run-live-watch.sh: python3 required (watch-spec JSON construction)" >&2; exit 3; }

# Output dir is created early so both paths write into a known place.
OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
OUT="$OUT_DIR/$(basename "$OUT")"

# emit_spec <derived-invariants-file> — build the final watch-spec JSON array from a newline-delimited list of
# pipe-separated derived invariant records (label|lhs_sig|rhs_sig|rhs_const|rel|margin_bp), validate/normalise
# every field in python3 (rel ∈ {le,ge,eq}; exactly one of rhs_sig/rhs_const per entry; margin_bp an int in
# 0..10000), and write it to $OUT. All string handling is python3 so no shell metachar in any signature can
# corrupt the JSON (the repo's python3-json.dumps convention). Drops malformed/empty rows; an empty result is
# a valid (empty) spec the watcher treats as "no invariant to evaluate".
emit_spec() {
  _records="$1"
  ADDRESS="$ADDRESS" RPC_URL="$RPC_URL" TARGET="$TARGET" RECORDS_FILE="$_records" OUT_FILE="$OUT" python3 - <<'PY'
import json, os
addr = os.environ["ADDRESS"]
rpc = os.environ["RPC_URL"]
target = os.environ["TARGET"]
out = os.environ["OUT_FILE"]
recs = []
try:
    with open(os.environ["RECORDS_FILE"], "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
except OSError:
    lines = []
for line in lines:
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split("|")
    while len(parts) < 6:
        parts.append("")
    label, lhs_sig, rhs_sig, rhs_const, rel, margin_bp = (p.strip() for p in parts[:6])
    if not lhs_sig:
        continue
    rel = rel if rel in ("le", "ge", "eq") else "le"
    # Exactly one right-hand source: a signature wins; else a numeric literal; else drop the row (nothing to
    # compare against on the live read).
    if rhs_sig:
        rhs_const = ""
    elif rhs_const.lstrip("-").isdigit():
        rhs_sig = ""
    else:
        continue
    try:
        mbp = int(margin_bp) if margin_bp else 0
    except ValueError:
        mbp = 0
    mbp = max(0, min(10000, mbp))
    recs.append({
        "label": label or lhs_sig,
        "lhs_sig": lhs_sig,
        "rhs_sig": rhs_sig,
        "rhs_const": rhs_const,
        "rel": rel,
        "margin_bp": mbp,
    })
with open(out, "w", encoding="utf-8") as fh:
    json.dump(recs, fh, indent=2)
    fh.write("\n")
print(len(recs))
PY
}

# The canonical EIP-1967 IMPLEMENTATION slot (same constant the governance-watcher
# watches). A proxy whose impl pointer moves is exactly an upgrade — the drift tell.
IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"

# emit_fingerprint — capture the deployed-target FINGERPRINT (#1097) next to the
# spec at <OUT>.fingerprint.json: the deployed-bytecode HASH (sha256 of `cast code
# <addr>`) and the EIP-1967 IMPLEMENTATION slot value (`cast storage <addr>
# <impl-slot>`). check-drift.sh re-reads these and raises a `drift` alert when the
# deployed contract no longer matches — so a static spec cannot silently go blind on
# an upgraded target. READ-ONLY: only `cast code` / `cast storage`. A missing `cast`
# or an unreachable RPC is NOT fatal — the fingerprint is written with empty fields
# and the drift check stays quiet (it can only flag a CHANGE vs a captured baseline).
emit_fingerprint() {
    _fp="$OUT.fingerprint.json"
    _code_hash=""
    _impl=""
    if command -v "$CAST" >/dev/null 2>&1; then
        # `cast code` prints the deployed bytecode as one 0x-hex word (no 0x on an
        # EOA / unreachable read). Hash it so the fingerprint is a small fixed digest,
        # not the whole bytecode. set +e + 2>/dev/null: a failed read leaves "".
        set +e
        _code="$("$CAST" code --rpc-url "$RPC_URL" "$ADDRESS" 2>/dev/null)"
        _impl="$("$CAST" storage --rpc-url "$RPC_URL" "$ADDRESS" "$IMPL_SLOT" 2>/dev/null)"
        set -e
        _code="$(printf '%s' "$_code" | awk 'NR==1{print $1}')"
        _impl="$(printf '%s' "$_impl" | awk 'NR==1{print $1}' | tr '[:upper:]' '[:lower:]')"
        if [ -n "$_code" ] && [ "$_code" != "0x" ]; then
            if command -v sha256sum >/dev/null 2>&1; then
                _code_hash="$(printf '%s' "$_code" | sha256sum | awk '{print $1}')"
            elif command -v shasum >/dev/null 2>&1; then
                _code_hash="$(printf '%s' "$_code" | shasum -a 256 | awk '{print $1}')"
            fi
        fi
    fi
    ADDRESS="$ADDRESS" RPC_URL="$RPC_URL" CODE_HASH="$_code_hash" IMPL="$_impl" \
        FP_FILE="$_fp" python3 - <<'PY'
import json, os
fp = {
    "address": os.environ["ADDRESS"],
    "rpc_url": os.environ["RPC_URL"],
    "code_hash": os.environ["CODE_HASH"],
    "impl_slot": os.environ["IMPL"],
}
with open(os.environ["FP_FILE"], "w", encoding="utf-8") as fh:
    json.dump(fp, fh, indent=2)
    fh.write("\n")
PY
    if [ -n "$_code_hash" ] || [ -n "$_impl" ]; then
        echo "run-live-watch.sh: captured target fingerprint -> $_fp (code_hash=${_code_hash:-none} impl=${_impl:-none})" >&2
    else
        echo "run-live-watch.sh: target fingerprint not captured (no cast / unreachable RPC) -> $_fp written empty; drift check will stay quiet" >&2
    fi
}

# extract_from_test <generated *.t.sol> — pull the live-watchable two-sided invariants OUT of the derived
# Foundry invariant test. A deep `invariant_*` assertion in that test compares two on-chain quantities, e.g.
# `require(vault.totalSupply() <= vault.totalAssets());` or `assertLe(a.debt(), a.collateral());`. We surface
# only the SIMPLE, LIVE-OBSERVABLE shape: a comparison of two zero-arg view-call signatures (or a signature vs
# a numeric literal), which is exactly what the watcher can re-check with two `cast call`s. Anything more
# complex (arithmetic, indexed reads, multi-term expressions) is NOT a live two-`cast` invariant and is left
# to the full forge derivation — we deliberately under-extract rather than emit an unwatchable spec. Portable
# awk/grep over the test text into the pipe-separated record list emit_spec() consumes; no LLM, no forge.
extract_from_test() {
  _test="$1"
  [ -f "$_test" ] || { : ; return 0; }
  # The python3 pass reads the derived test directly, narrows to the assertion lines (require/assert*), and
  # does the structural parse (regex over the simple two-view / view-vs-literal comparison shapes). Reading the
  # file in-process avoids a pipe-into-heredoc (the heredoc would otherwise override the pipe; SC2259).
  python3 - "$_test" <<'PY'
import re, sys
test_path = sys.argv[1]
sig = r'(?:[A-Za-z_][A-Za-z0-9_]*\.)?([A-Za-z_][A-Za-z0-9_]*\(\))'   # an optional `recv.` then a zero-arg call
num = r'(\d+)'
rel_map = {"<=": "le", ">=": "ge", "==": "eq"}
# A) `require(<lhsSig> <relop> <rhsSig>)` — two view calls.
re_two = re.compile(r'require\(\s*' + sig + r'\s*(<=|>=|==)\s*' + sig + r'\s*[,)]')
# B) `require(<lhsSig> <relop> <number>)` — a view call vs a literal bound.
re_const = re.compile(r'require\(\s*' + sig + r'\s*(<=|>=|==)\s*' + num + r'\s*[,)]')
# C) `assertLe(<lhsSig>, <rhsSig>)` / assertGe / assertEq — the forge-std-style two-arg form.
re_assert = re.compile(r'assert(Le|Ge|Eq)\(\s*' + sig + r'\s*,\s*' + sig + r'\s*[,)]')
assert_rel = {"Le": "le", "Ge": "ge", "Eq": "eq"}
assert_line = re.compile(r'require\(|assert(?:Eq|Le|Ge|True)?\(')
try:
    with open(test_path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
except OSError:
    lines = []
seen = set()
out = []
for line in lines:
    if not assert_line.search(line):
        continue
    for m in re_two.finditer(line):
        lhs, rel, rhs = m.group(1), rel_map[m.group(2)], m.group(3)
        key = (lhs, rel, rhs, "")
        if key in seen:
            continue
        seen.add(key)
        out.append("%s|%s|%s||%s|0" % (lhs, lhs, rhs, rel))
    for m in re_const.finditer(line):
        lhs, rel, c = m.group(1), rel_map[m.group(2)], m.group(3)
        key = (lhs, rel, "", c)
        if key in seen:
            continue
        seen.add(key)
        out.append("%s|%s||%s|%s|0" % (lhs, lhs, c, rel))
    for m in re_assert.finditer(line):
        rel, lhs, rhs = assert_rel[m.group(1)], m.group(2), m.group(3)
        key = (lhs, rel, rhs, "")
        if key in seen:
            continue
        seen.add(key)
        out.append("%s|%s|%s||%s|0" % (lhs, lhs, rhs, rel))
sys.stdout.write("\n".join(out))
if out:
    sys.stdout.write("\n")
PY
}

# --- OFFLINE / deterministic path: a ready-made watch-spec used VERBATIM (no LLM, no forge) ----------------
# The --spec-fixture sibling of run-invariant-hunt.sh's --handler-fixture. The fixture is validated as a JSON
# array of watch-spec objects, normalised through the SAME emit_spec() pipeline (so an offline spec and a
# derived spec are byte-for-byte the same shape), and emitted. The derivation is NOT run.
if [ -n "$SPEC_FIXTURE" ]; then
  [ -f "$SPEC_FIXTURE" ] || { echo "run-live-watch.sh: --spec-fixture not found: $SPEC_FIXTURE" >&2; exit 2; }
  RECORDS="$OUT_DIR/derived-invariants.txt"
  # Flatten the fixture JSON array into the pipe-separated record list emit_spec() consumes; a malformed
  # fixture is a clean usage error here, never a half-written spec.
  SPEC_FIXTURE="$SPEC_FIXTURE" python3 - "$RECORDS" <<'PY' || { echo "run-live-watch.sh: --spec-fixture is not a JSON array of watch-spec objects" >&2; exit 2; }
import json, os, sys
recs_path = sys.argv[1]
with open(os.environ["SPEC_FIXTURE"], "r", encoding="utf-8") as fh:
    data = json.load(fh)
if not isinstance(data, list):
    raise SystemExit(1)
rows = []
for o in data:
    if not isinstance(o, dict):
        raise SystemExit(1)
    rows.append("|".join(str(o.get(k, "")) for k in
                ("label", "lhs_sig", "rhs_sig", "rhs_const", "rel", "margin_bp")))
with open(recs_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(rows))
    if rows:
        fh.write("\n")
PY
  N="$(emit_spec "$RECORDS")"
  emit_fingerprint
  echo "run-live-watch.sh: wrote watch-spec ($N invariant(s)) from fixture to $OUT" >&2
  echo "$OUT"
  exit 0
fi

# --- LIVE path: DERIVE the invariant set ONCE via the existing invariant-prover derivation ----------------
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "run-live-watch.sh: --repo <foundry project root> required on the live path" >&2; exit 2; }
[ -f "$REPO/foundry.toml" ] || { echo "run-live-watch.sh: --repo is not a foundry project (no foundry.toml): $REPO" >&2; exit 2; }
[ -n "$TARGET" ] || { echo "run-live-watch.sh: --target <Contract.sol[:Name]> required on the live path" >&2; exit 2; }

HUNT="$HERE/run-invariant-hunt.sh"
[ -f "$HUNT" ] || { echo "run-live-watch.sh: run-invariant-hunt.sh not found at $HUNT" >&2; exit 3; }

# Run the established derivation EXACTLY ONCE for this target into our own rundir. We REUSE run-invariant-hunt.sh
# rather than re-driving invariant-prover.ag ourselves: it owns the rundir staging, the LLM/forge wiring, and
# the slimming, and it writes the generated invariant test to <out>/run/repo/test/Inv_<slug>.t.sol — which is
# the artifact we extract the live-watchable comparisons from. The fork address is forwarded as the FM1
# single-target --fork-target so the derived handler can reference the real deployed contract.
HUNT_OUT="$OUT_DIR/invariant-out"
if [ "$REDERIVE" -eq 1 ]; then
  echo "run-live-watch.sh: --rederive — re-running derivation; the spec + fingerprint at $OUT will be overwritten" >&2
fi
echo "run-live-watch.sh: deriving the invariant SET for $TARGET (once) via run-invariant-hunt.sh ..." >&2
set -- --repo "$REPO" --target "$TARGET" --backend "$BACKEND" --fork-url "$RPC_URL" --fork-target "$ADDRESS" \
       --out "$HUNT_OUT" --agentis "$AGENTIS"
[ -n "$CLASS" ] && set -- "$@" --class "$CLASS"
[ -n "$CODE" ] && set -- "$@" --code "$CODE"
[ -n "$RUNS" ] && set -- "$@" --runs "$RUNS"
[ -n "$DEPTH" ] && set -- "$@" --depth "$DEPTH"
[ -n "$SEED" ] && set -- "$@" --seed "$SEED"
sh "$HUNT" "$@" || echo "run-live-watch.sh: derivation reported a non-zero status (the spec is still extracted from whatever test was generated)" >&2

# The slug run-invariant-hunt.sh derives from --target (same transform), so we can locate the generated test.
SLUG="$(printf '%s' "$TARGET" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
GEN_TEST="$HUNT_OUT/run/repo/test/Inv_${SLUG}.t.sol"

RECORDS="$OUT_DIR/derived-invariants.txt"
extract_from_test "$GEN_TEST" > "$RECORDS" || : > "$RECORDS"
N="$(emit_spec "$RECORDS")"
# #1097: capture the deployed-target fingerprint next to the spec so check-drift.sh
# can tell when the target upgraded out from under this (now-stale) watch-spec.
emit_fingerprint

echo >&2
echo "================ LIVE-WATCH: $TARGET -> $N watchable invariant(s) ================" >&2
if [ "$N" -gt 0 ]; then
  echo "run-live-watch.sh: wrote watch-spec to $OUT. Point the monitor colony at it:" >&2
  echo "    export MONITOR_INV_SPEC=$OUT  MONITOR_TARGET=$ADDRESS  MONITOR_RPC_URL=$RPC_URL  MONITOR_CAST=\$(command -v cast)" >&2
  echo "    (add MONITOR_INV_SPEC to exec.env_passthrough in .agentis/config) then ./monitor/scripts/start-colony.sh" >&2
else
  echo "run-live-watch.sh: no SIMPLE two-view invariant was extractable from the derived test — the derivation" >&2
  echo "  may have produced only multi-term/arithmetic invariants (not a single live two-cast comparison). The" >&2
  echo "  watch-spec was written empty; supply --spec-fixture to hand-author the live-watchable subset." >&2
fi
echo "$OUT"
