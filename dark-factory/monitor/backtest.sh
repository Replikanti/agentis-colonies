#!/bin/sh
# backtest.sh — monitor calibration / backtest harness for the Dark Factory monitor colony (#1101).
#
# The credibility backbone behind the Path C live-watch sample: it points the monitor's INVARIANT-WATCHER
# verdict logic at a fork pinned to HISTORICAL block heights around a KNOWN incident, replays the verdict
# tick-by-tick across a range of blocks, and reports
#   (a) that the monitor would have PAGED at or before the incident block (the true positive + its
#       LEAD-TIME in blocks before the event), and
#   (b) a quiet PRE-incident window with the FALSE-POSITIVE count and rate (the noise control).
#
# It REUSES the watcher's read path + verdict logic, not a re-derivation: each "tick" reads the same two
# on-chain quantities the live invariant-watcher reads (`lhs_sig` and `rhs_sig`/`rhs_const`) — here via
# `cast call --block <N>` against an archive RPC — and applies the SAME deterministic relation the watcher
# does (le | ge | eq, with an optional margin-to-violation band in basis points). The verdict tokens
# (`violated` / `margin` / `ok` / `no-read`) and the fuse-to-worst rule across a multi-invariant SET are
# byte-for-byte the invariant-watcher's, so a backtest PAGE is exactly the page the live colony would raise.
#
# READ-ONLY / NON-CUSTODIAL: every chain access is a `cast call` (a view read at a pinned block). The harness
# never signs a transaction, never sends one, never touches funds, and holds no key. A backtest is a replay
# of READS, never an action.
#
# The invariant(s) to replay come from the SAME watch-spec the live colony consumes (`run-live-watch.sh`
# emits it; the invariant-watcher reads it as MONITOR_INV_SPEC) via --spec, OR from the single-invariant
# flags below (the legacy MONITOR_INV_* contract). A watch-spec entry is
#   {"label","lhs_sig","rhs_sig"|"rhs_const","rel","margin_bp"}  (rel in le|ge|eq).
#
# Usage:
#   backtest.sh --rpc-url <archive-rpc> --target <0x..> --incident-block <N> \
#               (--spec <watch-spec.json> | --lhs-sig <sig> [--rhs-sig <sig> | --rhs-const <int>]) \
#               [options]
#
# Required:
#   --rpc-url <rpc>        The ARCHIVE RPC the replay reads historical state from (http(s)). An archive node
#                          is required to read state at an OLD block; without one the harness degrades
#                          gracefully (see --probe / the no-archive message) rather than crash.
#   --target <0x..>        The deployed contract the `cast call`s read from (0x + 40 hex).
#   --incident-block <N>   The block at (or just after) which the known incident landed — the replay's anchor.
#
# Invariant source (exactly one of):
#   --spec <file>          A watch-spec JSON array (what run-live-watch.sh emits / the invariant-watcher
#                          consumes). EVERY entry is replayed each block and FUSED to the worst verdict
#                          (one violated member pages the whole set), matching the live watcher's set path.
#   --lhs-sig <sig>        The single invariant's LHS view signature (e.g. "totalSupply()"). With it:
#   --rhs-sig <sig>          the RHS view signature (e.g. "totalAssets()"), OR
#   --rhs-const <int>        a literal integer RHS bound. Exactly one of the two.
#   --rel <le|ge|eq>       The relation that MUST hold (default le, matching the watcher).
#   --margin-bp <0..10000> Margin-to-violation band; a holding-but-thin gap within it flags `margin`.
#   --label <text>         Human label for the single invariant (report only).
#
# Replay window (all optional; defaults keep a run cheap):
#   --pre-window <N>       How many blocks BEFORE the incident to treat as the quiet window for the
#                          false-positive measurement (default 20). The quiet window is
#                          [incident-block - lead-window - quiet-lead - pre-window,
#                           incident-block - lead-window - quiet-lead) — strictly BELOW the lead window,
#                          so "quiet" cannot overlap the pre-exploit ramp.
#   --lead-window <N>      How many blocks BEFORE the incident the page window starts scanning, so a PAGE
#                          that fires on the pre-exploit ramp is credited with a POSITIVE lead time
#                          (default 5). The page window is [incident - lead-window, incident + post-window].
#   --quiet-lead <N>       An extra guard band (blocks) between the quiet window and the lead window
#                          (default 5).
#   --post-window <N>      How many blocks AT/AFTER the incident to keep scanning for the first PAGE
#                          (default 5).
#   --step <N>             Block stride between ticks across BOTH windows (default 1 = every block; raise it
#                          to thin a long replay against a rate-limited RPC).
#   --cast <bin>           Path to the `cast` binary (default `cast` on PATH).
#   --out <file>           Where to also write the machine-readable replay log (default: stdout only).
#   --probe                Do the archive-node capability probe + print the resolved plan, then exit 0
#                          WITHOUT replaying (a dry capability check; degrades cleanly with no archive node).
#
# Exit codes: 0 ok (replay ran, or --probe), 2 usage error, 3 missing dependency (python3 / cast),
#   4 no archive node reachable for the replay (graceful degrade, clear message, no crash).
set -eu

CAST="cast"
RPC_URL=""; TARGET=""; INCIDENT=""; SPEC=""
LHS_SIG=""; RHS_SIG=""; RHS_CONST=""; REL=""; MARGIN_BP=""; LABEL=""
PRE_WINDOW="20"; LEAD_WINDOW="5"; QUIET_LEAD="5"; POST_WINDOW="5"; STEP="1"; OUT=""; PROBE=0

err() { echo "backtest.sh: $1" >&2; }
need() { [ "$1" -ge 2 ] || { err "missing value for the preceding flag"; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rpc-url) need "$#"; RPC_URL="$2"; shift 2 ;;
    --target) need "$#"; TARGET="$2"; shift 2 ;;
    --incident-block) need "$#"; INCIDENT="$2"; shift 2 ;;
    --spec) need "$#"; SPEC="$2"; shift 2 ;;
    --lhs-sig) need "$#"; LHS_SIG="$2"; shift 2 ;;
    --rhs-sig) need "$#"; RHS_SIG="$2"; shift 2 ;;
    --rhs-const) need "$#"; RHS_CONST="$2"; shift 2 ;;
    --rel) need "$#"; REL="$2"; shift 2 ;;
    --margin-bp) need "$#"; MARGIN_BP="$2"; shift 2 ;;
    --label) need "$#"; LABEL="$2"; shift 2 ;;
    --pre-window) need "$#"; PRE_WINDOW="$2"; shift 2 ;;
    --lead-window) need "$#"; LEAD_WINDOW="$2"; shift 2 ;;
    --quiet-lead) need "$#"; QUIET_LEAD="$2"; shift 2 ;;
    --post-window) need "$#"; POST_WINDOW="$2"; shift 2 ;;
    --step) need "$#"; STEP="$2"; shift 2 ;;
    --cast) need "$#"; CAST="$2"; shift 2 ;;
    --out) need "$#"; OUT="$2"; shift 2 ;;
    --probe) PROBE=1; shift ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) err "unknown flag $1"; exit 2 ;;
  esac
done

# --- validation: a typo is a clean usage error here, never an opaque downstream failure ----------------
[ -n "$RPC_URL" ] || { err "--rpc-url <archive-rpc> required"; exit 2; }
case "$RPC_URL" in
  http://*|https://*) ;;
  *) err "--rpc-url must be an http(s) URL (got: $RPC_URL)"; exit 2 ;;
esac
[ -n "$TARGET" ] || { err "--target <0x..> required"; exit 2; }
case "$TARGET" in
  0x*) _hex="${TARGET#0x}"; case "$_hex" in *[!0-9a-fA-F]*) _bad=1 ;; *) [ "${#_hex}" -eq 40 ] && _bad=0 || _bad=1 ;; esac ;;
  *) _bad=1 ;;
esac
[ "${_bad:-1}" -eq 0 ] || { err "--target must be 0x + 40 hex (got: $TARGET)"; exit 2; }
[ -n "$INCIDENT" ] || { err "--incident-block <N> required"; exit 2; }
for v in "$INCIDENT" "$PRE_WINDOW" "$LEAD_WINDOW" "$QUIET_LEAD" "$POST_WINDOW" "$STEP"; do
  case "$v" in '' | *[!0-9]*) err "block / window / step values must be whole numbers"; exit 2 ;; esac
done
[ "$STEP" -ge 1 ] || { err "--step must be >= 1"; exit 2; }

# Exactly one invariant SOURCE: a spec file, or a single-invariant LHS (+ exactly one RHS).
if [ -n "$SPEC" ]; then
  [ -z "$LHS_SIG" ] || { err "supply EITHER --spec OR the single-invariant flags, not both"; exit 2; }
  [ -f "$SPEC" ] || { err "--spec not found: $SPEC"; exit 2; }
else
  [ -n "$LHS_SIG" ] || { err "supply --spec <watch-spec.json> OR --lhs-sig <sig> (+ --rhs-sig / --rhs-const)"; exit 2; }
  if [ -n "$RHS_SIG" ] && [ -n "$RHS_CONST" ]; then
    err "supply EITHER --rhs-sig OR --rhs-const, not both"; exit 2
  fi
  if [ -z "$RHS_SIG" ] && [ -z "$RHS_CONST" ]; then
    err "the single-invariant path needs --rhs-sig <sig> or --rhs-const <int>"; exit 2
  fi
  case "$RHS_CONST" in '' | *[!0-9]*) [ -z "$RHS_CONST" ] || { err "--rhs-const must be a whole number"; exit 2; } ;; esac
fi
REL="${REL:-le}"
case "$REL" in le|ge|eq) ;; *) err "--rel must be le | ge | eq (got: $REL)"; exit 2 ;; esac
MARGIN_BP="${MARGIN_BP:-0}"
case "$MARGIN_BP" in '' | *[!0-9]*) err "--margin-bp must be a whole number 0..10000"; exit 2 ;; esac
[ "$MARGIN_BP" -le 10000 ] || { err "--margin-bp must be 0..10000"; exit 2; }

command -v python3 >/dev/null 2>&1 || { err "python3 required (replay accounting + spec parse)"; exit 3; }
command -v "$CAST" >/dev/null 2>&1 || { err "cast not found (set --cast <path>); foundry's cast is the read tool"; exit 3; }

# --- resolved replay plan ------------------------------------------------------------------------------
# Page window: [incident - lead-window, incident + post-window] — scanning the pre-exploit ramp so a PAGE
# there earns a POSITIVE lead time. Quiet window: strictly BELOW the page window, with a quiet-lead guard,
# [incident - lead-window - quiet-lead - pre-window, incident - lead-window - quiet-lead).
PAGE_LO=$((INCIDENT - LEAD_WINDOW))
PAGE_HI=$((INCIDENT + POST_WINDOW))
QUIET_HI=$((PAGE_LO - QUIET_LEAD))
QUIET_LO=$((QUIET_HI - PRE_WINDOW))
if [ "$QUIET_LO" -lt 0 ]; then
  err "the quiet window underflows block 0 (incident=$INCIDENT, pre-window=$PRE_WINDOW, lead-window=$LEAD_WINDOW, quiet-lead=$QUIET_LEAD); lower --pre-window / --lead-window"
  exit 2
fi

SRC_DESC="single-invariant ${LABEL:-$LHS_SIG} ($REL)"
[ -n "$SPEC" ] && SRC_DESC="watch-spec $SPEC"

echo "================ MONITOR BACKTEST (#1101) ================"
echo "target        : $TARGET"
echo "rpc (archive) : $RPC_URL"
echo "invariant src : $SRC_DESC"
echo "incident block: $INCIDENT"
echo "quiet window  : [$QUIET_LO, $QUIET_HI)  (pre=$PRE_WINDOW, quiet-lead=$QUIET_LEAD, step=$STEP)"
echo "page window   : [$PAGE_LO, $PAGE_HI]    (lead=$LEAD_WINDOW, post=$POST_WINDOW, step=$STEP)"
echo "read tool     : $CAST  (read-only cast call --block <N>; non-custodial)"
echo "========================================================="

# read_uint_at <sig> <block> — the watcher's read_uint, pinned to a historical block. Emits a decimal
# integer on stdout, or "" on any failure (no reading -> no false flag, exactly as the live watcher). Every
# dynamic value flows into a single `cast`; this script is the trusted operator harness (not a sandboxed
# .ag), and the values are quoted as separate argv words so no metachar is interpolated into a shell string.
read_uint_at() {
  _sig="$1"; _blk="$2"
  [ -n "$_sig" ] || { echo ""; return 0; }
  _raw="$("$CAST" call --rpc-url "$RPC_URL" --block "$_blk" "$TARGET" "$_sig" 2>/dev/null || true)"
  [ -n "$_raw" ] || { echo ""; return 0; }
  "$CAST" --to-dec "$_raw" 2>/dev/null || true
}

# --- archive-node capability probe ---------------------------------------------------------------------
# Reading state at an OLD block needs an ARCHIVE node; a pruned node errors / returns empty. Probe by reading
# ONE quantity at the quiet-window's oldest block (the deepest read the replay will attempt). An empty probe
# => no archive node reachable => degrade gracefully (exit 4 with a clear message), never crash mid-replay.
PROBE_SIG="$LHS_SIG"
if [ -n "$SPEC" ]; then
  PROBE_SIG="$(SPEC="$SPEC" python3 -c '
import json, os, sys
try:
    with open(os.environ["SPEC"], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
if isinstance(data, list):
    for o in data:
        if isinstance(o, dict) and o.get("lhs_sig"):
            sys.stdout.write(str(o["lhs_sig"])); break
')"
fi
if [ -z "$PROBE_SIG" ]; then
  err "no readable invariant LHS signature (empty --spec or missing --lhs-sig)"; exit 2
fi

echo "[probe] archive read of $PROBE_SIG at block $QUIET_LO ..." >&2
PROBE_VAL="$(read_uint_at "$PROBE_SIG" "$QUIET_LO")"
if [ -z "$PROBE_VAL" ]; then
  err "archive read at block $QUIET_LO returned nothing — the RPC is likely NOT an archive node (or the"
  err "  target had no code at that block). Point --rpc-url at an archive endpoint and retry. No replay run."
  exit 4
fi
echo "[probe] ok — archive node reachable (read $PROBE_VAL)" >&2

if [ "$PROBE" -eq 1 ]; then
  echo "[probe] capability OK; --probe set, not replaying. Drop --probe to run the full backtest." >&2
  exit 0
fi

# verdict_at <block> — the invariant-watcher's verdict for ONE block. For the single-invariant path this is
# one read pair + relation; for the --spec path EVERY entry is replayed and FUSED to the worst verdict
# (violated > margin > ok > no-read), exactly the watcher's fuse_set rule. All comparison + margin math is in
# python3 (big on-chain integers exceed shell arithmetic), reproducing within_margin / invariant_holds /
# verdict_of / worse_verdict from invariant-watcher.ag. Emits "<verdict> <which>" where <which> names the
# member that produced the fused verdict (the single label, or the spec member, or "-").
verdict_at() {
  _blk="$1"
  if [ -n "$SPEC" ]; then
    _n="$(SPEC="$SPEC" python3 -c '
import json, os, sys
try:
    with open(os.environ["SPEC"], "r", encoding="utf-8") as fh:
        d = json.load(fh)
    print(len(d) if isinstance(d, list) else 0)
except Exception:
    print(0)
')"
    _worst="no-read"; _which="-"; _rank=0
    _i=0
    while [ "$_i" -lt "$_n" ]; do
      _entry="$(SPEC="$SPEC" IDX="$_i" python3 -c '
import json, os, sys
with open(os.environ["SPEC"], "r", encoding="utf-8") as fh:
    d = json.load(fh)
o = d[int(os.environ["IDX"])]
def g(k):
    return str(o.get(k, "") or "")
sys.stdout.write("\t".join([g("label") or g("lhs_sig"), g("lhs_sig"), g("rhs_sig"), g("rhs_const"), (g("rel") or "le"), (g("margin_bp") or "0")]))
')"
      _lbl="$(printf '%s' "$_entry" | cut -f1)"
      _ls="$(printf '%s' "$_entry" | cut -f2)"
      _rs="$(printf '%s' "$_entry" | cut -f3)"
      _rc="$(printf '%s' "$_entry" | cut -f4)"
      _rl="$(printf '%s' "$_entry" | cut -f5)"
      _mb="$(printf '%s' "$_entry" | cut -f6)"
      _lhs="$(read_uint_at "$_ls" "$_blk")"
      if [ -n "$_rs" ]; then _rhs="$(read_uint_at "$_rs" "$_blk")"; else _rhs="$_rc"; fi
      _v="$(verdict_compute "$_lhs" "$_rhs" "$_rl" "$_mb")"
      _vr="$(verdict_rank "$_v")"
      if [ "$_vr" -ge "$_rank" ]; then _rank="$_vr"; _worst="$_v"; _which="$_lbl"; fi
      _i=$((_i + 1))
    done
    echo "$_worst $_which"
  else
    _lhs="$(read_uint_at "$LHS_SIG" "$_blk")"
    if [ -n "$RHS_SIG" ]; then _rhs="$(read_uint_at "$RHS_SIG" "$_blk")"; else _rhs="$RHS_CONST"; fi
    _v="$(verdict_compute "$_lhs" "$_rhs" "$REL" "$MARGIN_BP")"
    echo "$_v ${LABEL:-$LHS_SIG}"
  fi
}

# verdict_compute <lhs> <rhs> <rel> <margin_bp> — verdict_of() from invariant-watcher.ag, in python3 so the
# big-int comparison + the margin-to-violation band are exact. Empty/non-numeric side => "no-read".
verdict_compute() {
  LHS="$1" RHS="$2" REL_IN="$3" MBP="$4" python3 -c '
import os, sys
def to_int(s):
    s = (s or "").strip()
    return int(s) if s.lstrip("-").isdigit() else None
lhs = to_int(os.environ["LHS"]); rhs = to_int(os.environ["RHS"])
rel = os.environ["REL_IN"]; mbp = to_int(os.environ["MBP"]) or 0
if lhs is None or rhs is None:
    print("no-read"); sys.exit(0)
def holds():
    if rel == "le": return lhs <= rhs
    if rel == "ge": return lhs >= rhs
    if rel == "eq": return lhs == rhs
    return lhs <= rhs
def within_margin():
    if mbp <= 0 or rhs <= 0: return False
    diff = lhs - rhs if lhs >= rhs else rhs - lhs
    return (diff * 10000) // rhs <= mbp
if not holds():
    print("violated")
elif within_margin():
    print("margin")
else:
    print("ok")
'
}

# verdict_rank <v> — severity rank (worse_verdict's order): violated 3 > margin 2 > ok 1 > no-read 0.
verdict_rank() {
  case "$1" in
    violated) echo 3 ;;
    margin) echo 2 ;;
    ok) echo 1 ;;
    *) echo 0 ;;
  esac
}

# A verdict that the live watcher would surface as an alert (its is_anomaly): violated or margin.
is_page() {
  case "$1" in violated|margin) return 0 ;; *) return 1 ;; esac
}

# Optional machine log header.
if [ -n "$OUT" ]; then
  OUT_DIR="$(dirname "$OUT")"; mkdir -p "$OUT_DIR"
  : > "$OUT"
  echo "window	block	verdict	which" >> "$OUT"
fi

log_row() {
  [ -n "$OUT" ] || return 0
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$OUT"
}

# --- (b) quiet pre-incident window: the FALSE-POSITIVE measurement -------------------------------------
echo
echo "---- quiet window [$QUIET_LO, $QUIET_HI) — false-positive measurement ----"
quiet_ticks=0; quiet_pages=0
blk="$QUIET_LO"
while [ "$blk" -lt "$QUIET_HI" ]; do
  out="$(verdict_at "$blk")"
  v="${out%% *}"; which="${out#* }"
  quiet_ticks=$((quiet_ticks + 1))
  flag="quiet"
  if is_page "$v"; then quiet_pages=$((quiet_pages + 1)); flag="FALSE-PAGE"; fi
  echo "  block $blk: $v ($which) [$flag]"
  log_row "quiet" "$blk" "$v" "$which"
  blk=$((blk + STEP))
done

# --- (a) page window: the TRUE-POSITIVE (page at/before the incident) + LEAD-TIME ----------------------
echo
echo "---- page window [$PAGE_LO, $PAGE_HI] — true-positive + lead-time ----"
first_page_block=-1; first_page_verdict=""; first_page_which=""
blk="$PAGE_LO"
while [ "$blk" -le "$PAGE_HI" ]; do
  out="$(verdict_at "$blk")"
  v="${out%% *}"; which="${out#* }"
  flag="ok"
  if is_page "$v"; then
    flag="PAGE"
    if [ "$first_page_block" -eq -1 ]; then
      first_page_block="$blk"; first_page_verdict="$v"; first_page_which="$which"
    fi
  fi
  echo "  block $blk: $v ($which) [$flag]"
  log_row "page" "$blk" "$v" "$which"
  blk=$((blk + STEP))
done

# --- verdict summary -----------------------------------------------------------------------------------
echo
echo "================ RESULT ================"
fp_rate="$(QT="$quiet_ticks" QP="$quiet_pages" python3 -c '
import os
qt = int(os.environ["QT"]); qp = int(os.environ["QP"])
print("%.4f" % (qp / qt) if qt else "0.0000")
')"
echo "quiet window  : $quiet_pages false page(s) over $quiet_ticks tick(s)  (false-positive rate $fp_rate)"

if [ "$first_page_block" -ne -1 ]; then
  lead=$((INCIDENT - first_page_block))
  if [ "$lead" -lt 0 ]; then lead=0; fi
  echo "first PAGE    : block $first_page_block ($first_page_verdict, member: $first_page_which)"
  echo "lead time     : $lead block(s) before the incident block $INCIDENT"
  TP="paged"
else
  echo "first PAGE    : none in [$PAGE_LO, $PAGE_HI] — the monitor did NOT page in this window"
  TP="missed"
fi

# PASS when the monitor paged (true positive) AND the quiet window was clean (zero false pages).
RESULT="FAIL"
if [ "$TP" = "paged" ] && [ "$quiet_pages" -eq 0 ]; then RESULT="PASS"; fi
echo "result        : $RESULT  (true-positive=$TP, false-pages=$quiet_pages)"
echo "======================================="
[ -n "$OUT" ] && echo "[backtest] replay log written to $OUT" >&2

[ "$RESULT" = "PASS" ]
