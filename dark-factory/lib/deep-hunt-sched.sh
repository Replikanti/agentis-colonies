# shellcheck shell=bash
# dark-factory/lib/deep-hunt-sched.sh — the deep-hunt TIME-BUDGET scheduler (#2258). SOURCED (functions only, no
# top-level side effect) by run-zone-hunt.sh's STAGE 4.5 and by lib/deep-hunt-cell.sh's worker.
#
# WHY. STAGE 4.5 runs one (target, lens) CELL after another and a live cell takes 35-60 min, so a zone with 3 REACH
# targets x 2 lenses ran for over 4 h and the run hit its hard stop with the zone half-done. Four ENV KNOBS bound
# that, each inert when unset/0:
#   DEEP_HUNT_CELL_TIMEOUT_S=<N>       wall-clock cap per cell                         -> TIMEOUT
#   DEEP_HUNT_ZONE_BUDGET_S=<N>        per-zone budget from the zone's first launch    -> SKIPPED_BUDGET / TIMEOUT
#   DEEP_HUNT_SKIP_BROKEN_TARGET=1     skip a target that does not compile            -> SKIPPED_TARGET_BROKEN
#   DEEP_HUNT_JOBS=<1..8>              max concurrent cells (default 1)
#
# HOW (the loop body in run-zone-hunt.sh is NOT modified — only wrapped). With every knob unset, dh_pass_begin
# succeeds exactly once and every other function is a no-op, so the loop runs once exactly as before. With a knob
# set, the SAME loop source runs as ordered passes:
#   1. ENQUEUE. $INVHUNT points at lib/deep-hunt-cell.sh, which records each row's exact engine argv
#      (.sched/argv/<seq>, NUL-separated) and exits 1, so the loop's own `|| continue` skips the post-processing.
#      --deep-hunt-resume filters rows exactly as it always does. The pass's stderr goes to .sched/enqueue.log and is
#      re-emitted afterwards MINUS the shim's own artifacts (the `run-invariant-hunt.sh failed ...` line its exit 1
#      provokes, and the per-row `stateful-invariant lens on zone` line the collect pass prints again), so a row's
#      pre-engine diagnostics (the resume `already hunted` skip, a #2255 per-row root skip) still reach the operator.
#      dh_note_row (the loop's one hook line) records each row.
#   2. SCHEDULE. The queue is cut into BATCHES — maximal contiguous runs of rows with distinct run dirs (legacy
#      --deep-hunt-max-targets > 1 rows share `<zone>-<class>`, and a later row would overwrite an earlier one's
#      run dir before it was collected). Per batch the cells are dispatched FIFO in queue order under the job window,
#      the probe-first rule and the zone budget; each worker runs the real engine under lib/cell-watchdog.sh.
#   3. COLLECT. The loop runs again over the batch's rc-0 cells only, in QUEUE order, with the shim exiting 0 at once
#      and --deep-hunt-resume forced off (the cells it just settled would otherwise be skipped as terminal). So the
#      gate merge, reach-coverage.tsv, the promise TSVs and the lens-surface matrix are written in the sequential
#      order whatever order the cells finished in: parallel output equals sequential output by construction.
#
# DEFINITIONS (normative — docs/invariant-hunt.md "Deep-hunt time budget (#2258)"):
#   TIMEOUT   the wall bound fired (watchdog exit 124) and the cell's AGGREGATE invariant_*.log (never a _c<N>.log)
#             has no INVARIANT| line. Ledger only: never merged, never CLEAN, not terminal on --deep-hunt-resume. When
#             the bound fires AFTER the verdict was written (the engine was killed in its post-verdict tail) the cell
#             keeps its verdict, reason `tail-killed`, and is collected as usual.
#   TARGET_BROKEN  the cell's aggregate verdict is HARNESS_ERROR (no INVARIANT| line counts as HARNESS_ERROR) AND
#             the rows of <run>/forge-diag/compile.tsv minus the CorpusReplay.t.sol rows are non-empty AND every one
#             of them has scope `target`. Only a target's PROBE (its first queued lens) decides; its remaining lenses
#             are then SKIPPED_TARGET_BROKEN and never launched.
#   LEDGER    $DEEP/cell-status.tsv, scheduler mode only, one row per queued cell in QUEUE order:
#             zone \t target \t class \t status \t reason. Timings go to .sched/timing.tsv only.
#
# ERROR HANDLING. dh_pass_begin runs as a `while` condition, where `set -e` is suspended for everything it calls
# (dispatch included), so every step here checks itself and fails LOUDLY (exit 3) on a broken state dir or queue.
#
# Compatibility: bash 3.2+ (no associative arrays); DEEP_HUNT_JOBS > 1 needs bash >= 4.3 (`wait -n`).

DH_ACTIVE=0

# dh_sched_init — decide activation (called once, right after $DEEP is created). No output, no file, no variable
# change visible to the loop when every knob is unset.
dh_sched_init() {
  DH_ACTIVE=0
  DH_PHASE=""
  DH_CT="${DEEP_HUNT_CELL_TIMEOUT_S:-0}"
  DH_ZB="${DEEP_HUNT_ZONE_BUDGET_S:-0}"
  DH_SKIP="${DEEP_HUNT_SKIP_BROKEN_TARGET:-0}"
  DH_J="${DEEP_HUNT_JOBS:-1}"
  [ "$DH_J" -ge 1 ] 2>/dev/null || DH_J=1
  if [ "$DH_CT" -gt 0 ] || [ "$DH_ZB" -gt 0 ] || [ "$DH_SKIP" = 1 ] || [ "$DH_J" -gt 1 ]; then
    DH_ACTIVE=1
  else
    return 0
  fi
  # `wait -n` (the parallel window) needs bash >= 4.3 — the run-discovery.sh precedent: warn and run serially.
  if [ "$DH_J" -gt 1 ] && { [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 3 ]; }; }; then
    echo "run-zone-hunt.sh: [deep-hunt] WARNING: DEEP_HUNT_JOBS=$DH_J needs bash >= 4.3 (wait -n); running the cells one at a time (#2258)" >&2
    DH_J=1
  fi
  # The prover holds a forge slot for its whole run, so cells beyond FORGE_MAX_SLOTS wait FORGE_SLOT_WAIT_S for one
  # and then fail open (run unbounded) — the window still works, but say so.
  if [ "$DH_J" -gt "${FORGE_MAX_SLOTS:-2}" ] 2>/dev/null; then
    echo "run-zone-hunt.sh: [deep-hunt] WARNING: DEEP_HUNT_JOBS=$DH_J > FORGE_MAX_SLOTS=${FORGE_MAX_SLOTS:-2}: each cell holds a forge slot for its whole run, so the extra cells wait FORGE_SLOT_WAIT_S and then run without one; set FORGE_MAX_SLOTS >= DEEP_HUNT_JOBS (#2258)" >&2
  fi
  DH_HERE="$HERE/lib"
  DH_STATE="$DEEP/.sched"
  rm -rf "$DH_STATE" && mkdir -p "$DH_STATE/argv" "$DH_STATE/meta" "$DH_STATE/rc" \
    || { echo "run-zone-hunt.sh: [deep-hunt] cannot create the scheduler state dir $DH_STATE (#2258)" >&2; exit 3; }
  DH_ENGINE="$INVHUNT"
  INVHUNT="$DH_HERE/deep-hunt-cell.sh"
  DH_STALE="$DEEP_CELL_STALE_S"
  DH_POLL="$DEEP_CELL_POLL_S"
  DH_BACKEND="$BACKEND"
  # STOP-1 decision 2: a DEDICATED dark-factory LLM-session pool (dev-apprenticeship's fed pool is the wrong scope for
  # hunts — #2135), K = LLM_MAX_CONCURRENT (default 3), soft: a worker fails open after LLM_SLOT_WAIT_S.
  DH_LLM_SLOTS_DIR="${DARK_FACTORY_DIR:-${HOME:-.}/.dark-factory}/deep-hunt-llm-slots"
  DH_CLOCK_BASE=0
  DH_ZONE_NAMES=()
  DH_ZONE_T0=()
  export DH_STATE DH_ENGINE DH_STALE DH_POLL DH_SKIP DH_LLM_SLOTS_DIR
  echo "run-zone-hunt.sh: [deep-hunt] time-budget scheduler ON: jobs=$DH_J cell-timeout=${DH_CT}s zone-budget=${DH_ZB}s skip-broken-target=$DH_SKIP (#2258)" >&2
  return 0
}

# dh_pass_begin — the `while` condition wrapped around the STAGE 4.5 row loop. Legacy: true once. Scheduler: the
# enqueue pass, then (dispatching each batch first) one collect pass per batch.
dh_pass_begin() {
  if [ "$DH_ACTIVE" != 1 ]; then
    if [ -z "$DH_PHASE" ]; then DH_PHASE=run; return 0; fi
    return 1
  fi
  case "$DH_PHASE" in
    "")
      DH_PHASE=enqueue
      DH_SEQ=0
      DH_MODE=enqueue; export DH_MODE
      # The shim must answer at once: a staleness-watchdog wrapper with stale=0 is a plain `exec` pass-through.
      DH_SAVED_STALE="$DEEP_CELL_STALE_S"; DEEP_CELL_STALE_S=0
      exec 3>&2 2>>"$DH_STATE/enqueue.log"
      return 0 ;;
    between)
      if [ "$DH_BATCH_IDX" -ge "$DH_NBATCH" ]; then
        DEEP_CELL_STALE_S="$DH_SAVED_STALE"
        INVHUNT="$DH_ENGINE"
        DH_MODE=""; export DH_MODE
        DH_PHASE=finished
        return 1
      fi
      dh_dispatch_batch "$DH_BATCH_IDX"
      DH_SAVED_TARGETS="$DEEP_TARGETS"; DH_SAVED_RESUME="$DEEP_HUNT_RESUME"
      DEEP_TARGETS="$DH_STATE/batch-$DH_BATCH_IDX.tsv"
      DEEP_HUNT_RESUME=0
      DH_MODE=collect; export DH_MODE
      DH_COLLECT_I=0
      DH_PHASE=collect
      return 0 ;;
    *) return 1 ;;
  esac
}

# dh_pass_end — called right after the row loop's `done`, inside the pass wrapper. Always returns 0.
dh_pass_end() {
  [ "$DH_ACTIVE" = 1 ] || return 0
  case "$DH_PHASE" in
    enqueue)
      exec 2>&3 3>&-
      grep -v -F -e '[deep-hunt] run-invariant-hunt.sh failed' -e '[deep-hunt] stateful-invariant lens on zone' \
        "$DH_STATE/enqueue.log" >&2 2>/dev/null || true
      dh_build_queue
      DH_BATCH_IDX=0
      DH_PHASE=between ;;
    collect)
      DEEP_TARGETS="$DH_SAVED_TARGETS"; DEEP_HUNT_RESUME="$DH_SAVED_RESUME"
      if [ "$DH_COLLECT_I" -ne "$DH_BATCH_NCOLLECT" ]; then
        echo "run-zone-hunt.sh: [deep-hunt] scheduler: batch $DH_BATCH_IDX collected $DH_COLLECT_I row(s), expected $DH_BATCH_NCOLLECT (#2258)" >&2
        exit 3
      fi
      DH_BATCH_IDX=$((DH_BATCH_IDX + 1))
      DH_PHASE=between ;;
  esac
  return 0
}

# dh_note_row ZID RELFILE DCLASS AUXFILES REACH_NAME DZOUT — the loop's hook, right before the engine call. Enqueue:
# records the row (one field per line: a TSV read would collapse the empty aux / reach fields) and hands the shim its
# sequence number. Collect: checks the row against the queue. Legacy: no-op.
dh_note_row() {
  [ "$DH_ACTIVE" = 1 ] || return 0
  case "$DH_PHASE" in
    enqueue)
      DH_SEQ=$((DH_SEQ + 1))
      printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" "$5" "$6" > "$DH_STATE/meta/$DH_SEQ" \
        || { echo "run-zone-hunt.sh: [deep-hunt] scheduler: cannot write $DH_STATE/meta/$DH_SEQ (#2258)" >&3; exit 3; }
      DH_CUR_SEQ="$DH_SEQ"; export DH_CUR_SEQ ;;
    collect)
      _dh_s="${DH_BATCH_COLLECT[$DH_COLLECT_I]:-}"
      DH_COLLECT_I=$((DH_COLLECT_I + 1))
      if [ -z "$_dh_s" ] || [ "${DH_DZ[$_dh_s]}" != "$6" ]; then
        echo "run-zone-hunt.sh: [deep-hunt] scheduler: collect row $DH_COLLECT_I ('$1' $3 -> $6) does not match the queue (#2258)" >&2
        exit 3
      fi
      DH_CUR_SEQ="$_dh_s"; export DH_CUR_SEQ ;;
  esac
  return 0
}

# dh_agg_log DZOUT — the cell's AGGREGATE invariant log (the last `invariant_*.log` that is not a per-candidate
# `_c<N>.log` — the same selection as the loop's own readers), or nothing.
dh_agg_log() {
  _dh_al=""
  for _dh_c in "$1"/run/invariant_*.log; do
    [ -e "$_dh_c" ] || continue
    case "$_dh_c" in *_c[0-9]*.log) continue ;; esac
    _dh_al="$_dh_c"
  done
  printf '%s' "$_dh_al"
}

# dh_agg_verdict DZOUT — the verdict of the aggregate log's last INVARIANT| line, or nothing.
dh_agg_verdict() {
  _dh_l="$(dh_agg_log "$1")"
  [ -n "$_dh_l" ] || return 0
  grep 'INVARIANT|' "$_dh_l" 2>/dev/null | tail -1 | sed 's/.*INVARIANT|//' | cut -d'|' -f2 | tr -d '[:space:]'
}

# dh_target_broken DZOUT — prints `1<TAB><first_non_harness_loc>` when the cell is TARGET_BROKEN (see the header),
# else `0`.
dh_target_broken() {
  _dh_v="$(dh_agg_verdict "$1")"
  [ -n "$_dh_v" ] || _dh_v=HARNESS_ERROR
  if [ "$_dh_v" != HARNESS_ERROR ] || [ ! -f "$1/run/forge-diag/compile.tsv" ]; then
    printf '0\n'; return 0
  fi
  awk -F'\t' '
    { n = split($1, parts, "/"); if (parts[n] == "CorpusReplay.t.sol") next }
    { rows++; if ($2 != "target") other++; else if (loc == "") loc = $4 }
    END { if (rows > 0 && other == 0) printf "1\t%s\n", loc; else printf "0\n" }
  ' "$1/run/forge-diag/compile.tsv" 2>/dev/null || printf '0\n'
}

# dh_build_queue — after the enqueue pass: load every recorded row, pair it with its argv, cut the batches and find
# each target's probe. Fails loudly on a row without an argv (the shim was not reached) or an unreadable record.
dh_build_queue() {
  DH_N="$DH_SEQ"
  DH_Z=(); DH_REL=(); DH_C=(); DH_AUX=(); DH_REACH=(); DH_DZ=(); DH_T=(); DH_KEY=()
  DH_BATCH=(); DH_PROBE=(); DH_STATUS=(); DH_REASON=(); DH_COLLECT=(); DH_BROKEN=(); DH_BLOC=()
  DH_NBATCH=0
  _dh_batch_dz=""
  _dh_s=1
  while [ "$_dh_s" -le "$DH_N" ]; do
    [ -f "$DH_STATE/meta/$_dh_s" ] && [ -f "$DH_STATE/argv/$_dh_s" ] || {
      echo "run-zone-hunt.sh: [deep-hunt] scheduler: queue entry $_dh_s is incomplete (meta/argv missing under $DH_STATE) (#2258)" >&2
      exit 3; }
    { IFS= read -r "DH_Z[$_dh_s]"; IFS= read -r "DH_REL[$_dh_s]"; IFS= read -r "DH_C[$_dh_s]"; IFS= read -r "DH_AUX[$_dh_s]"
      IFS= read -r "DH_REACH[$_dh_s]"; IFS= read -r "DH_DZ[$_dh_s]"; } < "$DH_STATE/meta/$_dh_s"
    [ -n "${DH_Z[$_dh_s]}" ] && [ -n "${DH_DZ[$_dh_s]}" ] || {
      echo "run-zone-hunt.sh: [deep-hunt] scheduler: queue entry $_dh_s is unreadable (#2258)" >&2; exit 3; }
    if [ -n "${DH_REACH[$_dh_s]}" ]; then DH_T[_dh_s]="${DH_REACH[$_dh_s]}"; else DH_T[_dh_s]="$(basename "${DH_REL[$_dh_s]}" .sol)"; fi
    DH_KEY[_dh_s]="${DH_Z[$_dh_s]}|${DH_REL[$_dh_s]}:${DH_REACH[$_dh_s]}"
    # Batches: a new one starts when this row's run dir is already used in the current batch.
    case "$_dh_batch_dz" in
      *"
${DH_DZ[$_dh_s]}
"*) DH_NBATCH=$((DH_NBATCH + 1)); _dh_batch_dz="" ;;
    esac
    [ -n "$_dh_batch_dz" ] || _dh_batch_dz="
"
    _dh_batch_dz="$_dh_batch_dz${DH_DZ[$_dh_s]}
"
    DH_BATCH[_dh_s]="$DH_NBATCH"
    # Probe: the target's first queued lens (same zone + rel[:Name]).
    DH_PROBE[_dh_s]="$_dh_s"
    _dh_p=1
    while [ "$_dh_p" -lt "$_dh_s" ]; do
      if [ "${DH_KEY[$_dh_p]}" = "${DH_KEY[$_dh_s]}" ]; then DH_PROBE[_dh_s]="$_dh_p"; break; fi
      _dh_p=$((_dh_p + 1))
    done
    DH_STATUS[_dh_s]=""; DH_REASON[_dh_s]=""; DH_COLLECT[_dh_s]=0; DH_BROKEN[_dh_s]=0; DH_BLOC[_dh_s]=""
    _dh_s=$((_dh_s + 1))
  done
  [ "$DH_N" -eq 0 ] || DH_NBATCH=$((DH_NBATCH + 1))
  # Cross-cell pattern recall (--pattern-store) depends on the serial order: one cell reads what the previous wrote.
  if [ "$DH_J" -gt 1 ]; then
    for _dh_af in "$DH_STATE"/argv/*; do
      [ -f "$_dh_af" ] || continue
      if tr '\0' '\n' < "$_dh_af" | grep -qx -- '--pattern-store'; then
        echo "run-zone-hunt.sh: [deep-hunt] WARNING: --pattern-store is forwarded — cross-cell pattern recall depends on the serial order, so DEEP_HUNT_JOBS=$DH_J is forced to 1 (#2258)" >&2
        DH_J=1
        break
      fi
    done
  fi
  echo "run-zone-hunt.sh: [deep-hunt] scheduler: $DH_N cell(s) queued in $DH_NBATCH batch(es) (#2258)" >&2
}

# dh_queue_order — the order the collect pass and the ledger walk the cells in: QUEUE order, never completion order
# (the whole point: the artifacts are written in the sequential order). demo-deep-hunt-budget.sh mutates this line.
dh_queue_order() { seq 1 "$DH_N"; }

# dh_now — the scheduler clock: seconds spent DISPATCHING (the collect passes, incl. the refute gate, do not count
# against a zone budget).
dh_now() {
  printf '%s' "$(( DH_CLOCK_BASE + $(date +%s) - DH_DISPATCH_T0 ))"
}

# dh_settle SEQ STATUS REASON — record a cell's final status and print its status line.
dh_settle() {
  DH_STATUS[$1]="$2"; DH_REASON[$1]="$3"
  echo "run-zone-hunt.sh: [deep-hunt] zone '${DH_Z[$1]}' (${DH_C[$1]}) target '${DH_T[$1]}' -> $2 (${3:--}) (#2258)" >&2
}

# dh_zone_start ZONE NOW — echo the zone's budget start (set to NOW on its first launch).
dh_zone_start() {
  _dh_i=0
  while [ "$_dh_i" -lt "${#DH_ZONE_NAMES[@]}" ]; do
    if [ "${DH_ZONE_NAMES[$_dh_i]}" = "$1" ]; then printf '%s' "${DH_ZONE_T0[$_dh_i]}"; return 0; fi
    _dh_i=$((_dh_i + 1))
  done
  printf ''
}

# dh_reap SEQ — read a finished worker's result file into the queue.
dh_reap() {
  _dh_rf="$DH_STATE/rc/$1"
  if [ -f "$_dh_rf" ]; then
    IFS='	' read -r _dh_rc _dh_st _dh_rs _dh_br _dh_bl < "$_dh_rf" || true
  else
    _dh_rc=255; _dh_st=ENGINE_FAILED; _dh_rs=worker-died; _dh_br=0; _dh_bl=""
  fi
  [ "$_dh_rs" != "-" ] || _dh_rs=""
  [ "$_dh_bl" != "-" ] || _dh_bl=""
  DH_BROKEN[$1]="${_dh_br:-0}"; DH_BLOC[$1]="$_dh_bl"
  [ "$_dh_rc" = 0 ] && DH_COLLECT[$1]=1
  dh_settle "$1" "${_dh_st:-ENGINE_FAILED}" "$_dh_rs"
}

# dh_on_term — TERM/INT during dispatch: forward TERM to every live worker (each forwards it to its watchdog, which
# kills its engine group), wait for them, exit 143. The run's own EXIT trap (#1981 __EXIT__ marker) still fires.
dh_on_term() {
  echo "run-zone-hunt.sh: [deep-hunt] scheduler: stop signal — terminating ${#DH_RUN_PIDS[@]} running cell(s) (#2258)" >&2
  for _dh_pid in ${DH_RUN_PIDS[@]+"${DH_RUN_PIDS[@]}"}; do kill -TERM "$_dh_pid" 2>/dev/null || true; done
  for _dh_pid in ${DH_RUN_PIDS[@]+"${DH_RUN_PIDS[@]}"}; do wait "$_dh_pid" 2>/dev/null || true; done
  exit 143
}

# dh_pretrust SEQ... — ONE foreground df_ensure_claude_trust call over the batch's <DZOUT>/run dirs (its whole-file
# read-modify-write of ~/.claude.json is not safe to run concurrently; after this, each engine's own call is an
# idempotent no-write). Only for a backend that spawns claude; scoped to exactly these run dirs.
dh_pretrust() {
  case "$DH_BACKEND" in flat-cyborg|claude) ;; *) return 0 ;; esac
  _dh_dirs=()
  for _dh_q in "$@"; do
    mkdir -p "${DH_DZ[$_dh_q]}" 2>/dev/null || continue
    _dh_dirs+=("$(cd "${DH_DZ[$_dh_q]}" && pwd)/run")
  done
  [ "${#_dh_dirs[@]}" -gt 0 ] || return 0
  # shellcheck source=ensure-claude-trust.sh
  . "$DH_HERE/ensure-claude-trust.sh"
  df_ensure_claude_trust "${_dh_dirs[@]}"
}

# dh_dispatch_batch K — run every cell of batch K, then write the batch's collect file + ledger rows.
dh_dispatch_batch() {
  _dh_k="$1"
  _dh_pending=()
  _dh_s=1
  while [ "$_dh_s" -le "$DH_N" ]; do
    [ "${DH_BATCH[$_dh_s]}" = "$_dh_k" ] && _dh_pending+=("$_dh_s")
    _dh_s=$((_dh_s + 1))
  done
  [ "${#_dh_pending[@]}" -gt 0 ] || { echo "run-zone-hunt.sh: [deep-hunt] scheduler: batch $_dh_k is empty (#2258)" >&2; exit 3; }
  dh_pretrust "${_dh_pending[@]}"
  DH_RUN_PIDS=(); DH_RUN_SEQS=()
  DH_DISPATCH_T0="$(date +%s)"
  trap dh_on_term TERM INT
  while [ "${#_dh_pending[@]}" -gt 0 ] || [ "${#DH_RUN_SEQS[@]}" -gt 0 ]; do
    # Launch every eligible pending cell, in queue order, while the window has room.
    _dh_left=()
    for _dh_s in ${_dh_pending[@]+"${_dh_pending[@]}"}; do
      if [ "${#DH_RUN_SEQS[@]}" -ge "$DH_J" ]; then _dh_left+=("$_dh_s"); continue; fi
      _dh_p="${DH_PROBE[$_dh_s]}"
      if [ "$DH_SKIP" = 1 ] && [ "$_dh_p" != "$_dh_s" ]; then
        if [ -z "${DH_STATUS[$_dh_p]}" ]; then _dh_left+=("$_dh_s"); continue; fi   # wait for the probe
        if [ "${DH_BROKEN[$_dh_p]}" = 1 ]; then
          dh_settle "$_dh_s" SKIPPED_TARGET_BROKEN "probe=${DH_C[$_dh_p]} loc=${DH_BLOC[$_dh_p]}"
          continue
        fi
      fi
      _dh_cap="$DH_CT"; _dh_kind=cell
      if [ "$DH_ZB" -gt 0 ]; then
        _dh_now="$(dh_now)"
        _dh_t0="$(dh_zone_start "${DH_Z[$_dh_s]}")"
        if [ -z "$_dh_t0" ]; then
          DH_ZONE_NAMES+=("${DH_Z[$_dh_s]}"); DH_ZONE_T0+=("$_dh_now"); _dh_t0="$_dh_now"
        fi
        _dh_rem=$(( DH_ZB - (_dh_now - _dh_t0) ))
        if [ "$_dh_rem" -le 0 ]; then
          dh_settle "$_dh_s" SKIPPED_BUDGET "zone-budget=${DH_ZB}s"
          continue
        fi
        if [ "$_dh_cap" -eq 0 ] || [ "$_dh_rem" -lt "$_dh_cap" ]; then _dh_cap="$_dh_rem"; _dh_kind=zone; fi
      fi
      "$DH_HERE/deep-hunt-cell.sh" --worker "$_dh_s" "$_dh_cap" "$_dh_kind" &
      DH_RUN_PIDS+=("$!"); DH_RUN_SEQS+=("$_dh_s")
    done
    _dh_pending=(${_dh_left[@]+"${_dh_left[@]}"})
    if [ "${#DH_RUN_SEQS[@]}" -eq 0 ]; then
      [ "${#_dh_pending[@]}" -eq 0 ] && break
      echo "run-zone-hunt.sh: [deep-hunt] scheduler: ${#_dh_pending[@]} cell(s) can never launch (probe not in the batch) (#2258)" >&2
      exit 3
    fi
    # Wait for a worker to finish (one running: wait for it; several: `wait -n`, bash >= 4.3 is guaranteed then), then
    # reap every finished one. A worker is finished once its result file exists or its pid is gone.
    if [ "${#DH_RUN_PIDS[@]}" -eq 1 ]; then
      wait "${DH_RUN_PIDS[0]}" 2>/dev/null || true
    else
      _dh_any=0
      for _dh_q in "${DH_RUN_SEQS[@]}"; do [ -f "$DH_STATE/rc/$_dh_q" ] && _dh_any=1; done
      [ "$_dh_any" = 1 ] || wait -n 2>/dev/null || true
    fi
    _dh_keep_p=(); _dh_keep_s=()
    _dh_i=0
    while [ "$_dh_i" -lt "${#DH_RUN_SEQS[@]}" ]; do
      _dh_pid="${DH_RUN_PIDS[$_dh_i]}"; _dh_q="${DH_RUN_SEQS[$_dh_i]}"
      if [ -f "$DH_STATE/rc/$_dh_q" ] || ! kill -0 "$_dh_pid" 2>/dev/null; then
        wait "$_dh_pid" 2>/dev/null || true
        dh_reap "$_dh_q"
      else
        _dh_keep_p+=("$_dh_pid"); _dh_keep_s+=("$_dh_q")
      fi
      _dh_i=$((_dh_i + 1))
    done
    DH_RUN_PIDS=(${_dh_keep_p[@]+"${_dh_keep_p[@]}"}); DH_RUN_SEQS=(${_dh_keep_s[@]+"${_dh_keep_s[@]}"})
  done
  trap - TERM INT
  DH_CLOCK_BASE=$(( DH_CLOCK_BASE + $(date +%s) - DH_DISPATCH_T0 ))
  # The collect file (the rc-0 cells' raw rows, queue order) and the ledger rows (every cell, queue order).
  : > "$DH_STATE/batch-$_dh_k.tsv" || { echo "run-zone-hunt.sh: [deep-hunt] scheduler: cannot write the batch file (#2258)" >&2; exit 3; }
  DH_BATCH_COLLECT=(); DH_BATCH_NCOLLECT=0
  for _dh_s in $(dh_queue_order); do
    if [ "${DH_BATCH[$_dh_s]}" = "$_dh_k" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "${DH_Z[$_dh_s]}" "${DH_T[$_dh_s]}" "${DH_C[$_dh_s]}" "${DH_STATUS[$_dh_s]}" \
        "${DH_REASON[$_dh_s]:--}" >> "$DEEP/cell-status.tsv"
      if [ "${DH_COLLECT[$_dh_s]}" = 1 ]; then
        _dh_tgt="${DH_REL[$_dh_s]}${DH_REACH[$_dh_s]:+:${DH_REACH[$_dh_s]}}"
        if [ -n "${DH_AUX[$_dh_s]}" ]; then
          printf '%s\t%s\t%s\t%s\n' "${DH_Z[$_dh_s]}" "$_dh_tgt" "${DH_C[$_dh_s]}" "${DH_AUX[$_dh_s]}" >> "$DH_STATE/batch-$_dh_k.tsv"
        else
          printf '%s\t%s\t%s\n' "${DH_Z[$_dh_s]}" "$_dh_tgt" "${DH_C[$_dh_s]}" >> "$DH_STATE/batch-$_dh_k.tsv"
        fi
        DH_BATCH_COLLECT+=("$_dh_s"); DH_BATCH_NCOLLECT=$((DH_BATCH_NCOLLECT + 1))
      fi
    fi
  done
  return 0
}
