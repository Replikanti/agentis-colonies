#!/usr/bin/env bash
# forge-prebuild.sh — one warm forge build per viaIR project root for the deep invariant gate (#2353).
#
# WHY: on a Foundry target with viaIR enabled, one cold build of the staged repo takes about 30 min (numa-audit:
# 191 files, 1801.59 s), while every deep cell used to compile it again inside the prover's forge gate under the
# fixed 600 s agentis exec bound, so every cell ended HARNESS_ERROR. run-invariant-hunt.sh calls this shim after
# staging the repo and before `agentis go`. For a viaIR target it builds the staged repo once, publishes the
# compiler cache file + the artifacts dir as a warm record per source project, imports that record into every later
# cell's staged repo, and prints the measured facts the prover derives its gate bound from. A non-viaIR target is a
# pure no-op: no build, no file written, so its cell stays byte-identical.
#
# Usage:
#   forge-prebuild.sh --repo <staged repo> --source-repo <original --repo> --warm-dir <dir> \
#                     --heartbeat <file> --log <file>
#
# Stdout: `key=value` facts, one per line. Always exits 0; the build's rc travels in the facts.
#   via_ir=0                     not a viaIR target (or no forge / `forge config` failed): nothing else printed
#   via_ir=1                     followed by
#   cold_build_ms=<ms>           the measured cold build (the record's value on a warm import; 0 when it failed)
#   prebuild_ms=<ms>             this run's build wall time (whole seconds x 1000)
#   prebuild_rc=<rc>             forge build's rc (124 = DF_FORGE_PREBUILD_MAX_S hit)
#   warm_hit=<0|1>               1 when a warm record was imported before the build
#
# Detection goes through `forge config --json` (not a grep of foundry.toml), so profiles, FOUNDRY_PROFILE and
# FOUNDRY_VIA_IR resolve exactly the way forge resolves them.
#
# Warm record: `<warm-dir>/<key>/rec.<pid>/{solidity-files-cache.json,out/,cold-build-ms}` plus
# `<warm-dir>/<key>/complete` naming the record. The key is the first 16 hex chars of sha256 over the
# physical path of --source-repo and ${FOUNDRY_PROFILE:-default}. Only the compiler cache FILE travels, never the
# whole cache dir: forge persists invariant failures under `cache/invariant` and replays them by contract and
# invariant name, so carrying that dir could hand one cell's failure to another cell's harness as a false FINDING.
# The record is claimed by an exclusive create (`set -C`, the lib/forge-slot.sh primitive, no flock(1) because
# stock macOS ships none); a losing writer removes its own record. There is no build lock: two first-wave cells may
# both build cold, which is exactly the pre-#2353 cost.
#
# Env:
#   DF_FORGE_PREBUILD_MAX_S  bound on the build, in seconds (default 3600: about 2x the measured 1801.59 s numa
#                            cold build, the same 2x margin the pointed-l0 profile derived from 1803 s; lower and
#                            numa never warms, higher and a hung build holds its cell longer)
#   DF_FORGE_HEARTBEAT_S     heartbeat interval, in seconds (default 60: 15 beats per default 900 s
#                            DEEP_CELL_STALE_S window, so a stalled beat or two cannot trip the cell watchdog)
#   FOUNDRY_PROFILE          part of the warm key (a different profile is a different build)
#   FORGE_MAX_SLOTS / FORGE_SLOT_WAIT_S / FORGE_SLOTS_DIR / DARK_FACTORY_DIR  the #2038 forge-slot cap; only a
#                            cold build takes a slot (a warm verification build compiles nothing)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="" ; SRC_REPO="" ; WARM="" ; HB="" ; LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --source-repo) SRC_REPO="${2:-}"; shift 2 ;;
    --warm-dir) WARM="${2:-}"; shift 2 ;;
    --heartbeat) HB="${2:-}"; shift 2 ;;
    --log) LOG="${2:-}"; shift 2 ;;
    *) echo "forge-prebuild: unknown arg $1 — skipping the prebuild" >&2; echo "via_ir=0"; exit 0 ;;
  esac
done

note() { echo "forge-prebuild: $*" >&2; }
noop() { note "$1 — no prebuild (today's gate path)"; echo "via_ir=0"; exit 0; }

[ -n "$REPO" ] && [ -d "$REPO" ] && [ -f "$REPO/foundry.toml" ] || noop "--repo is not a foundry project"
[ -n "$WARM" ] && [ -n "$HB" ] && [ -n "$LOG" ] || noop "--warm-dir/--heartbeat/--log required"
REPO="$(cd "$REPO" && pwd)"
[ -n "$SRC_REPO" ] && [ -d "$SRC_REPO" ] || SRC_REPO="$REPO"
command -v forge >/dev/null 2>&1 || noop "forge not on PATH"
command -v python3 >/dev/null 2>&1 || noop "python3 not on PATH"
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"

# --- detection: three keys from `forge config --json` ------------------------------------------------------
if [ -n "$TIMEOUT_BIN" ]; then
  CFG="$(cd "$REPO" && "$TIMEOUT_BIN" 60 forge config --json 2>/dev/null)" || noop "forge config failed"
else
  CFG="$(cd "$REPO" && forge config --json 2>/dev/null)" || noop "forge config failed"
fi
# Prints `via_ir`, `cache_path`, `out` on three lines; a string that is not one line reads as empty.
KEYS="$(printf '%s' "$CFG" | python3 -c '
import json, sys
d = json.load(sys.stdin)
def s(v):
    return v if isinstance(v, str) and "\n" not in v and "\r" not in v else ""
print("1" if d.get("via_ir") is True else "0")
print(s(d.get("cache_path")))
print(s(d.get("out")))
' 2>/dev/null)" || noop "forge config did not print JSON"
VIA_IR="$(printf '%s\n' "$KEYS" | sed -n 1p)"
CACHE_PATH="$(printf '%s\n' "$KEYS" | sed -n 2p)"
OUT_DIR="$(printf '%s\n' "$KEYS" | sed -n 3p)"
[ "$VIA_IR" = 1 ] || { echo "via_ir=0"; exit 0; }

# --- viaIR: heartbeat first, before any wait or build -------------------------------------------------------
HB_S="${DF_FORGE_HEARTBEAT_S:-60}"
case "$HB_S" in ''|*[!0-9]*|0) HB_S=60 ;; esac
PB_MAX="${DF_FORGE_PREBUILD_MAX_S:-3600}"
case "$PB_MAX" in ''|*[!0-9]*|0) PB_MAX=3600 ;; esac
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/forge-prebuild.XXXXXX")" || noop "cannot create a temp dir"
SELF=$$
# kill_build: stop a build that is still running. It runs under `timeout`, its own process-group leader, so the
# whole group goes; without coreutils `timeout` only the build process itself is signalled (its group is ours).
kill_build() {
  _bp="$(cat "$TMPD/build.pid" 2>/dev/null)"
  case "$_bp" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$(ps -o pgid= -p "$_bp" 2>/dev/null | tr -d ' ')" = "$_bp" ]; then kill -TERM -- "-$_bp" 2>/dev/null
  else kill -TERM "$_bp" 2>/dev/null; fi
  return 0
}
# The loop beats while this shim lives. When the shim is gone without its cleanup (SIGKILL runs no trap) the loop
# stops the build the shim left behind and removes the temp dir. On TERM (normal cleanup) it exits at once and
# takes its own sleep with it.
(
  _sl=""
  trap '[ -n "$_sl" ] && kill "$_sl" 2>/dev/null; exit 0' TERM INT HUP
  while kill -0 "$SELF" 2>/dev/null; do
    touch "$HB" 2>/dev/null
    sleep "$HB_S" &
    _sl=$!
    wait "$_sl"
    _sl=""
  done
  kill_build
  rm -rf "$TMPD"
) >/dev/null 2>&1 &
HB_PID=$!
SLOT_LIB="$HERE/../lib/forge-slot.sh"
SLOT_HELD=0
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  kill_build
  kill "$HB_PID" 2>/dev/null
  [ "$SLOT_HELD" = 1 ] && release_forge_slot
  rm -rf "$TMPD"
}
trap cleanup EXIT
# A TERM/INT/HUP (the cell watchdog's group kill, an operator ^C) interrupts the wait below and runs cleanup, so
# the build in its own process group never outlives this shim.
trap 'exit 143' TERM INT HUP

# --- warm key + path check ---------------------------------------------------------------------------------
sane_rel() {  # $1 = a forge config path: relative, non-empty, no `..` component, not the repo root itself
  case "$1" in ''|/*) return 1 ;; esac
  case "/$1/" in */../*) return 1 ;; esac
  case "$(printf '%s' "$1" | tr -d './')" in '') return 1 ;; esac
  return 0
}
SHARE=1
if ! sane_rel "$CACHE_PATH" || ! sane_rel "$OUT_DIR"; then
  note "cache_path '$CACHE_PATH' / out '$OUT_DIR' is not a plain path inside the repo — warm sharing off"
  SHARE=0
fi
_kin="$(cd "$SRC_REPO" && pwd -P)
${FOUNDRY_PROFILE:-default}"
# sha256 through python3 (already required above): the same digest on GNU and stock macOS, where sha256sum is absent.
KEY="$(printf '%s' "$_kin" | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])' 2>/dev/null)"
case "$KEY" in *[!0-9a-f]*|'') note "could not hash the source path — warm sharing off"; SHARE=0 ;; esac
KDIR="$WARM/$KEY"

# --- import a published record ------------------------------------------------------------------------------
WARM_HIT=0
COLD_MS=0
if [ "$SHARE" = 1 ] && [ -f "$KDIR/complete" ]; then
  _rec="$(sed -n 1p "$KDIR/complete" 2>/dev/null)"
  case "$_rec" in
    '') ;;  # a claim whose name is not written yet: take the cold path, never remove it
    rec.*[!A-Za-z0-9._-]*|rec.) note "malformed warm record name — ignored" ;;
    rec.*)
      if [ -d "$KDIR/$_rec" ] && [ -f "$KDIR/$_rec/solidity-files-cache.json" ] && [ -d "$KDIR/$_rec/out" ]; then
        _cms="$(sed -n 1p "$KDIR/$_rec/cold-build-ms" 2>/dev/null)"
        case "$_cms" in ''|*[!0-9]*) _cms=0 ;; esac
        # A symlinked cache dir or out dir is replaced by a real dir: removing a link never touches its target.
        [ -L "$REPO/$CACHE_PATH" ] && rm -f "$REPO/$CACHE_PATH"
        if mkdir -p "$REPO/$CACHE_PATH" \
           && cp "$KDIR/$_rec/solidity-files-cache.json" "$REPO/$CACHE_PATH/solidity-files-cache.json" \
           && rm -rf "${REPO:?}/$OUT_DIR" && mkdir -p "$(dirname "$REPO/$OUT_DIR")" \
           && cp -R "$KDIR/$_rec/out" "$REPO/$OUT_DIR"; then
          WARM_HIT=1; COLD_MS="$_cms"
        else
          note "warm import failed — building cold"
        fi
      else
        note "warm record '$_rec' is gone — dropping the stale claim"
        rm -f "$KDIR/complete"
      fi ;;
    *) note "malformed warm record name — ignored" ;;
  esac
fi

# --- build (the gate's #1069 isolation: every other test/*.sol is skipped; no harness exists yet) -----------
SKIP_ARGS=()
if [ -d "$REPO/test" ]; then
  while IFS= read -r _tf; do
    [ -n "$_tf" ] && SKIP_ARGS+=(--skip "${_tf#"$REPO"/}")
  done < <(find "$REPO/test" -type f -name '*.sol' 2>/dev/null)
fi
if [ "$WARM_HIT" = 0 ] && [ -f "$SLOT_LIB" ]; then
  # shellcheck source=../lib/forge-slot.sh
  # shellcheck disable=SC1091
  . "$SLOT_LIB"
  acquire_forge_slot
  SLOT_HELD=1
fi
_t0="$(date +%s)"
(
  cd "$REPO" || exit 2
  if [ -n "$TIMEOUT_BIN" ]; then
    exec "$TIMEOUT_BIN" -k 30 "$PB_MAX" forge build ${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"}
  else
    exec forge build ${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"}
  fi
) >>"$LOG" 2>&1 &
_bpid=$!
printf '%s\n' "$_bpid" > "$TMPD/build.pid"
wait "$_bpid"
PB_RC=$?
rm -f "$TMPD/build.pid"
PB_MS=$(( ($(date +%s) - _t0) * 1000 ))
if [ "$SLOT_HELD" = 1 ]; then release_forge_slot; SLOT_HELD=0; fi

# --- publish (cold path, rc 0, sane paths only) --------------------------------------------------------------
if [ "$WARM_HIT" = 0 ]; then
  if [ "$PB_RC" = 0 ]; then COLD_MS="$PB_MS"; else COLD_MS=0; fi
  if [ "$PB_RC" = 0 ] && [ "$SHARE" = 1 ]; then
    if [ -f "$REPO/$CACHE_PATH/solidity-files-cache.json" ] && [ -d "$REPO/$OUT_DIR" ]; then
      _mine="rec.$$"
      if mkdir -p "$KDIR" && rm -rf "${KDIR:?}/$_mine" && mkdir "$KDIR/$_mine" \
         && cp "$REPO/$CACHE_PATH/solidity-files-cache.json" "$KDIR/$_mine/solidity-files-cache.json" \
         && cp -R "$REPO/$OUT_DIR" "$KDIR/$_mine/out" \
         && printf '%s\n' "$COLD_MS" > "$KDIR/$_mine/cold-build-ms"; then
        if ( set -C; printf '%s\n' "$_mine" > "$KDIR/complete" ) 2>/dev/null; then
          note "published warm record $_mine (cold build ${COLD_MS} ms)"
        else
          rm -rf "${KDIR:?}/$_mine"
        fi
      else
        rm -rf "${KDIR:?}/$_mine"
        note "could not write the warm record — not published"
      fi
    else
      note "the build left no compiler cache file / artifacts dir — not published"
    fi
  fi
fi

echo "via_ir=1"
echo "cold_build_ms=$COLD_MS"
echo "prebuild_ms=$PB_MS"
echo "prebuild_rc=$PB_RC"
echo "warm_hit=$WARM_HIT"
exit 0
