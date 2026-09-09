#!/usr/bin/env bash
# demo-change-pipeline.sh — OFFLINE, DETERMINISTIC proof (#2135, epic #2120 M4) of change-pipeline.sh: the
# cadence entrypoint that chains M1 (watch-code-changes.sh) -> M2 (scope-changes.sh) -> M3 (run-change-hunts.sh)
# into ONE budget-bounded tick and writes a PATCH-able JSON tick-summary the hunt-dashboard renders. Mirrors
# demo-run-change-hunts.sh's assert-based [PASS]/[FAIL] accounting. The M1/M2 stages are REPLACED by canned
# `--watch-cmd`/`--scope-cmd` stubs and the M3 innermost hunt/materialize by canned `--hunt-cmd`/`--source-cmd`
# stubs, so NO network / LLM / forge / `agentis` is ever invoked and the real ~/.dark-factory is never touched.
#
# HONESTY GUARD (demo-run-change-hunts.sh precedent): M1/M2 and the M3 innermost subprocess are MOCKS proving
# M4's PLUMBING only — the stage chaining, the two-knob budget (M3 `--max-hunts` + the exported FORGE_MAX_SLOTS),
# the tick-summary derivation, and the ledger-backed resumability. The REAL M3 (run-change-hunts.sh) still runs
# in every scenario, so its `--max-hunts` budget + `(program,new)` dedup ledger are exercised for real; only its
# network/LLM/forge leaf is mocked (via M3's own seams). The real live cadence is an operator arming action (M5).
#
# Acceptance covered (issue #2135):
#   S1 — a tick WITH changes: M1 stub emits changes -> M2 stub emits descriptors -> the real M3 hunts up to N
#        (respecting the forge-slot cap it exports); the tick-summary counts (changes/descriptors/hunts/skipped/
#        ledger) are asserted and a `finding` routes through the never-submit gate (findings_staged).
#   S2 — a QUIET tick: M1 stub emits 0 changes -> 0 descriptors -> 0 hunts -> status=quiet.
#   S3 — the BUDGET CAP truncates: 3 descriptors, `--hunts-per-tick 1` -> exactly 1 hunt (rest deferred); and
#        `--hunts-per-tick 2` -> exactly 2 (the cap is forwarded to M3, not hardcoded).
#   S4 — the RESUMABLE ledger: re-running a tick over the same descriptor does NOT re-hunt the ledgered change
#        (hunts_run=0), and the ledger row count is unchanged.
#   S5 — the DASHBOARD panel: hunt-dashboard.py --emit-model over the tick-summary shows the change_pipeline
#        model; --render carries the panel; an absent summary -> a graceful None (no panel, no crash).
#   S6 — source + runtime invariants: FORGE_MAX_SLOTS is EXPORTED (a custom K reaches the mock hunt at runtime),
#        `--max-hunts` is forwarded, there is NO uncommented `crontab -` install, and the scope-guard header +
#        `armed:false` are present.
#   S7 — a materialize-error (#2154) is counted in `materialize_errors`, NOT `hunts_run`, and costs no hunt
#        budget: matfail fails to materialize, `good` still hunts this tick at --hunts-per-tick 1; status=ok.
#
# Usage:  dark-factory/demo-change-pipeline.sh
# Exit:   0 = all assertions held; 1 = a failure; 3 = a script under test is missing.
# POSIX-friendly bash: literal glyphs only (dash-safe fixtures), no $'...', no process substitution.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CP="$HERE/change-pipeline.sh"
DASH="$HERE/hunt-dashboard/hunt-dashboard.py"
DELIVER="$HERE/deliver-submission.sh"

FAILS=0
note() { echo "demo-change-pipeline.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -x "$CP" ]      || { note "change-pipeline.sh not found / not executable: $CP" >&2; exit 3; }
[ -x "$DELIVER" ] || { note "deliver-submission.sh not found / not executable: $DELIVER" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-change-pipeline.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

HUNTLOG="$WORK/hunt-capture.log"   # one line per mock hunt: program|new|repo|mode|hint|since|FORGE_MAX_SLOTS

# --- the MOCK materialize seam (M3 --source-cmd): make a stub target dir + echo it. No git/Sourcify/network.
SRC_MOCK="$WORK/src-mock.sh"
cat > "$SRC_MOCK" <<MOCK
#!/usr/bin/env bash
set -u
mkdir -p "\$MAT_DEST/src" || exit 1
echo "// mock materialized (\$MAT_KIND) at \$MAT_REF" > "\$MAT_DEST/src/Target.sol"
printf '%s\n' "\$MAT_DEST"
MOCK
chmod +x "$SRC_MOCK"

# --- the MOCK hunt seam (M3 --hunt-cmd): record the CHANGE_* env M3 derived + the EXPORTED FORGE_MAX_SLOTS
#     (proving the pipeline exported it), and for `finder` stage a MARKED finding through deliver-submission.sh's
#     never-submit gate exactly as the real run-zone-hunt.sh would (so the verdict-by-drop-delta holds).
HUNT_MOCK="$WORK/hunt-mock.sh"
cat > "$HUNT_MOCK" <<MOCK
#!/usr/bin/env bash
set -u
printf '%s|%s|%s|%s|%s|%s|%s\n' "\$CHANGE_PROGRAM" "\$CHANGE_NEW" "\$CHANGE_REPO" \
  "\$CHANGE_SCOPE_MODE" "\$CHANGE_SCOPE_HINT" "\$CHANGE_SINCE" "\${FORGE_MAX_SLOTS:-UNSET}" >> "$HUNTLOG"
if [ "\$CHANGE_PROGRAM" = "finder" ]; then
  draft="$WORK/draft-\$CHANGE_PROGRAM.md"
  { echo "SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW"; echo "# mock finding for \$CHANGE_PROGRAM"; } > "\$draft"
  "$DELIVER" --id "\$CHANGE_PROGRAM@\$CHANGE_NEW:mock-finding" --draft-file "\$draft" \
    --target "\$CHANGE_PROGRAM" --severity High --drop-dir "\$CHANGE_DROP_DIR" >/dev/null 2>&1 || exit 8
fi
exit 0
MOCK
chmod +x "$HUNT_MOCK"

# --- watch/scope stubs: builders that write the M1 changes.tsv / M2 scope-descriptors.tsv the pipeline hands
#     them via WATCH_OUT / SCOPE_OUT. `$n` rows, all `head`+`scoped` unless the caller varies it.
# watch_stub <program-list...>  -> writes an 8-col changes.tsv (a `#` header + one row per program)
make_watch() { # $1 = space-separated program names
  ws="$WORK/watch-$RANDOM.sh"; ws_progs="$1"
  {
    echo '#!/usr/bin/env bash'; echo 'set -u'
    echo 'printf "%s\n" "# date\tprogram\tchain\tkind\trepo_or_addr\told\tnew\tgithubUrl" > "$WATCH_OUT"'
    for p in $ws_progs; do
      echo "printf '2026-09-08\t$p\t-\thead\thttps://example.invalid/$p\told_$p\tnew_$p\thttps://example.invalid/$p\n' >> \"\$WATCH_OUT\""
    done
  } > "$ws"; chmod +x "$ws"; printf '%s' "$ws"
}
# scope_stub "<prog:mode:hint> ..."  -> writes an 8-col scope-descriptors.tsv (a `#` header + one row each)
make_scope() { # $1 = space-separated prog:mode:hint triples (hint may be `-`)
  ss="$WORK/scope-$RANDOM.sh"; ss_spec="$1"
  {
    echo '#!/usr/bin/env bash'; echo 'set -u'
    echo 'printf "%s\n" "# program\tchain\tkind\trepo_or_addr\tnew\tscope_mode\tscope_hint_files\tsince" > "$SCOPE_OUT"'
    for t in $ss_spec; do
      p="${t%%:*}"; rest="${t#*:}"; mode="${rest%%:*}"; hint="${rest#*:}"
      echo "printf '$p\t-\thead\thttps://example.invalid/$p\tnew_$p\t$mode\t$hint\told_$p\n' >> \"\$SCOPE_OUT\""
    done
  } > "$ss"; chmod +x "$ss"; printf '%s' "$ss"
}

# jnum FILE KEY / jstr FILE KEY — jq-free readers of the flat tick-summary JSON.
jnum() { grep -o "\"$2\"[[:space:]]*:[[:space:]]*-\{0,1\}[0-9]\{1,\}" "$1" 2>/dev/null | grep -o -- '-\{0,1\}[0-9]\{1,\}$' | tail -n1; }
jstr() { grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/' | tail -n1; }
hunt_lines() { hl="$(grep -c . "$HUNTLOG" 2>/dev/null)"; printf '%s' "${hl:-0}"; }

run_tick() { # env DARK_FACTORY_DIR set by caller; $1=watch $2=scope $3..=extra flags
  rt_watch="$1"; rt_scope="$2"; shift 2
  "$CP" --once --watch-cmd "$rt_watch" --scope-cmd "$rt_scope" \
    --source-cmd "$SRC_MOCK" --hunt-cmd "$HUNT_MOCK" "$@" >/dev/null 2>>"$WORK/cp.err"
}

# ==========================================================================================================
note "S1) a tick WITH changes: M1 stub -> M2 stub -> real M3 (mocked leaf); summary counts + a staged finding ..."
: > "$HUNTLOG"
export DARK_FACTORY_DIR="$WORK/s1"; mkdir -p "$DARK_FACTORY_DIR"
SUM="$DARK_FACTORY_DIR/change-watch/tick-summary.json"
W1="$(make_watch "finder docs")"
S1="$(make_scope "finder:scoped:src/Bug.sol docs:skip:-")"
run_tick "$W1" "$S1"; RC=$?
[ "$RC" -eq 0 ] && ok "S1: tick exits 0" || bad "S1: tick exited $RC (expected 0)"
[ "$(jstr "$SUM" status)" = "ok" ] && ok "S1: status=ok" || bad "S1: status=$(jstr "$SUM" status)"
[ "$(jnum "$SUM" changes_seen)" = "2" ] && ok "S1: changes_seen=2" || bad "S1: changes_seen=$(jnum "$SUM" changes_seen)"
[ "$(jnum "$SUM" descriptors)" = "2" ] && ok "S1: descriptors=2" || bad "S1: descriptors=$(jnum "$SUM" descriptors)"
[ "$(jnum "$SUM" hunts_run)" = "1" ] && ok "S1: hunts_run=1 (the scoped row; the skip row was not hunted)" || bad "S1: hunts_run=$(jnum "$SUM" hunts_run)"
[ "$(jnum "$SUM" skipped)" = "1" ] && ok "S1: skipped=1 (the docs skip descriptor, ledgered-seen)" || bad "S1: skipped=$(jnum "$SUM" skipped)"
[ "$(jnum "$SUM" findings_staged)" = "1" ] && ok "S1: findings_staged=1 (via the never-submit gate)" || bad "S1: findings_staged=$(jnum "$SUM" findings_staged)"
[ "$(jnum "$SUM" ledger_total)" = "2" ] && ok "S1: ledger_total=2 (hunt + skip)" || bad "S1: ledger_total=$(jnum "$SUM" ledger_total)"
[ "$(jnum "$SUM" tick_seq)" = "1" ] && ok "S1: tick_seq=1" || bad "S1: tick_seq=$(jnum "$SUM" tick_seq)"
[ "$(jstr "$SUM" armed)" = "" ] && [ "$(grep -c '"armed": false' "$SUM")" -eq 1 ] && ok "S1: armed:false in the summary" || bad "S1: armed flag not false"
[ "$(hunt_lines)" -eq 1 ] && ok "S1: exactly one hunt invoked" || bad "S1: $(hunt_lines) hunts invoked, expected 1"
STAGED="$(find "$DARK_FACTORY_DIR/change-watch/drop" -name submission-draft.md 2>/dev/null | head -n1)"
if [ -n "$STAGED" ] && grep -q "SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW" "$STAGED"; then
  ok "S1: the staged package carries the never-submit human-gate marker"
else
  bad "S1: staged draft missing the human-gate marker ($STAGED)"
fi

# ==========================================================================================================
note "S2) a QUIET tick: 0 changes -> 0 descriptors -> 0 hunts -> status=quiet ..."
: > "$HUNTLOG"
export DARK_FACTORY_DIR="$WORK/s2"; mkdir -p "$DARK_FACTORY_DIR"
SUM="$DARK_FACTORY_DIR/change-watch/tick-summary.json"
WQ="$(make_watch "")"; SQ="$(make_scope "")"
run_tick "$WQ" "$SQ"
[ "$(jstr "$SUM" status)" = "quiet" ] && ok "S2: status=quiet" || bad "S2: status=$(jstr "$SUM" status)"
[ "$(jnum "$SUM" changes_seen)" = "0" ] && ok "S2: changes_seen=0" || bad "S2: changes_seen=$(jnum "$SUM" changes_seen)"
[ "$(jnum "$SUM" hunts_run)" = "0" ] && ok "S2: hunts_run=0" || bad "S2: hunts_run=$(jnum "$SUM" hunts_run)"
[ "$(hunt_lines)" -eq 0 ] && ok "S2: no hunt invoked on a quiet tick" || bad "S2: $(hunt_lines) hunts invoked, expected 0"

# ==========================================================================================================
note "S3) the BUDGET CAP truncates: 3 descriptors, --hunts-per-tick 1 -> 1; --hunts-per-tick 2 -> 2 ..."
: > "$HUNTLOG"
export DARK_FACTORY_DIR="$WORK/s3a"; mkdir -p "$DARK_FACTORY_DIR"
SUM="$DARK_FACTORY_DIR/change-watch/tick-summary.json"
W3="$(make_watch "one two three")"
S3="$(make_scope "one:scoped:src/A.sol two:scoped:src/B.sol three:scoped:src/C.sol")"
run_tick "$W3" "$S3" --hunts-per-tick 1
[ "$(jnum "$SUM" hunts_run)" = "1" ] && ok "S3a: hunts_run=1 over 3 descriptors (--hunts-per-tick 1 held)" || bad "S3a: hunts_run=$(jnum "$SUM" hunts_run)"
[ "$(jnum "$SUM" ledger_total)" = "1" ] && ok "S3a: only the hunted change is ledgered (2 deferred, resumable)" || bad "S3a: ledger_total=$(jnum "$SUM" ledger_total)"
: > "$HUNTLOG"
export DARK_FACTORY_DIR="$WORK/s3b"; mkdir -p "$DARK_FACTORY_DIR"
SUM="$DARK_FACTORY_DIR/change-watch/tick-summary.json"
run_tick "$W3" "$S3" --budget 2
[ "$(jnum "$SUM" hunts_run)" = "2" ] && ok "S3b: hunts_run=2 with --budget 2 (the cap is FORWARDED to M3, not hardcoded)" || bad "S3b: hunts_run=$(jnum "$SUM" hunts_run)"
[ "$(jnum "$SUM" hunts_per_tick)" = "2" ] && ok "S3b: the summary records budget.hunts_per_tick=2" || bad "S3b: budget.hunts_per_tick=$(jnum "$SUM" hunts_per_tick)"

# ==========================================================================================================
note "S4) the RESUMABLE ledger: re-running a tick does NOT re-hunt the ledgered change ..."
: > "$HUNTLOG"
export DARK_FACTORY_DIR="$WORK/s4"; mkdir -p "$DARK_FACTORY_DIR"
SUM="$DARK_FACTORY_DIR/change-watch/tick-summary.json"
LED="$DARK_FACTORY_DIR/change-watch/hunted-changes.tsv"
WR="$(make_watch "solo")"; SR="$(make_scope "solo:scoped:src/S.sol")"
run_tick "$WR" "$SR" --hunts-per-tick 1
[ "$(jnum "$SUM" hunts_run)" = "1" ] && ok "S4: tick 1 hunts the change" || bad "S4: tick 1 hunts_run=$(jnum "$SUM" hunts_run)"
LED_ROWS_1="$(grep -c . "$LED" 2>/dev/null || echo 0)"
# tick 2: same descriptor (watch emits no new change row), the ledger dedups the (program,new) key.
run_tick "$(make_watch "")" "$SR" --hunts-per-tick 1
[ "$(jnum "$SUM" hunts_run)" = "0" ] && ok "S4: tick 2 re-hunts NOTHING (the change is ledgered)" || bad "S4: tick 2 hunts_run=$(jnum "$SUM" hunts_run)"
[ "$(grep -c . "$LED" 2>/dev/null || echo 0)" = "$LED_ROWS_1" ] && ok "S4: the ledger row count is unchanged after the re-run" || bad "S4: ledger grew on the re-run"
[ "$(jnum "$SUM" tick_seq)" = "2" ] && ok "S4: tick_seq incremented to 2 across the two ticks" || bad "S4: tick_seq=$(jnum "$SUM" tick_seq)"

# ==========================================================================================================
note "S5) the DASHBOARD panel: hunt-dashboard.py renders the tick-summary as the change_pipeline model ..."
if command -v python3 >/dev/null 2>&1 && [ -f "$DASH" ]; then
  export DARK_FACTORY_DIR="$WORK/s5"; mkdir -p "$DARK_FACTORY_DIR"
  SUM="$DARK_FACTORY_DIR/change-watch/tick-summary.json"
  run_tick "$(make_watch "vp")" "$(make_scope "vp:scoped:src/V.sol")" --hunts-per-tick 1
  EMPTY_REG="$WORK/empty-registry"; mkdir -p "$EMPTY_REG"
  MODEL="$WORK/model.json"
  python3 "$DASH" --registry --registry-dir "$EMPTY_REG" --change-summary "$SUM" --emit-model > "$MODEL" 2>"$WORK/dash.err"
  if grep -q '"change_pipeline"' "$MODEL" && grep -q '"hunts_run": 1' "$MODEL" && grep -q '"status": "ok"' "$MODEL"; then
    ok "S5: --emit-model overview carries the change_pipeline panel model (hunts_run=1, status=ok)"
  else
    bad "S5: change_pipeline model missing/wrong in the overview (see $MODEL)"
  fi
  grep -q '"materialize_errors"' "$MODEL" && ok "S5: the change_pipeline model carries materialize_errors (#2154)" || bad "S5: materialize_errors missing from the model"
  python3 "$DASH" --registry --registry-dir "$EMPTY_REG" --change-summary "$SUM" --render > "$WORK/page.html" 2>>"$WORK/dash.err"
  grep -q "change-cadence pipeline" "$WORK/page.html" && ok "S5: --render carries the change-cadence panel" || bad "S5: rendered page missing the panel"
  python3 "$DASH" --registry --registry-dir "$EMPTY_REG" --change-summary "$WORK/nope.json" --emit-model > "$WORK/model-absent.json" 2>>"$WORK/dash.err"
  grep -q '"change_pipeline": null' "$WORK/model-absent.json" && ok "S5: an absent summary -> change_pipeline null (graceful no-panel)" || bad "S5: absent summary did not yield a null model"
else
  ok "S5: [SKIP] python3 / dashboard unavailable — panel assertions skipped (non-fatal)"
fi

# ==========================================================================================================
note "S6) source + runtime invariants: FORGE_MAX_SLOTS exported, --max-hunts forwarded, no cron install ..."
# runtime: a custom --forge-max-slots reaches the mock hunt via the exported env (proves the export, not a grep).
: > "$HUNTLOG"
export DARK_FACTORY_DIR="$WORK/s6"; mkdir -p "$DARK_FACTORY_DIR"
run_tick "$(make_watch "fp")" "$(make_scope "fp:scoped:src/F.sol")" --hunts-per-tick 1 --forge-max-slots 4
SEEN_K="$(head -n1 "$HUNTLOG" | awk -F'|' '{print $7}')"
[ "$SEEN_K" = "4" ] && ok "S6: the mock hunt saw FORGE_MAX_SLOTS=4 (the pipeline EXPORTED the forge-slot cap)" || bad "S6: mock hunt saw FORGE_MAX_SLOTS='$SEEN_K', expected 4"
grep -q 'export FORGE_MAX_SLOTS' "$CP" && ok "S6: change-pipeline.sh exports FORGE_MAX_SLOTS (reuse lib/forge-slot.sh, no new semaphore)" || bad "S6: no FORGE_MAX_SLOTS export in the script"
grep -q -- '--max-hunts "\$MAX_HUNTS"' "$CP" && ok "S6: the per-tick budget is forwarded to M3 --max-hunts" || bad "S6: --max-hunts not forwarded to M3"
# NO uncommented crontab install (the ready-to-arm line lives ONLY in a comment / the header).
if grep -vE '^[[:space:]]*#' "$CP" | grep -q 'crontab'; then
  bad "S6: an UNCOMMENTED crontab reference exists — the cadence must NOT self-install a cron"
else
  ok "S6: NO uncommented crontab install (the cron line is comment-only, operator-armed)"
fi
grep -qi "SCOPE GUARD" "$CP" && ok "S6: the scope-guard header is present" || bad "S6: no SCOPE GUARD header"
grep -q '"armed": false' "$CP" && ok "S6: the tick-summary hardcodes armed:false (build/demo, never live)" || bad "S6: armed:false not hardcoded"
grep -qi "no daemon/loop mode\|only ever runs ONE tick\|there is no continuous" "$CP" && ok "S6: the header documents the no-loop (one-tick-per-invocation) limit-safety" || bad "S6: no no-loop guard documented"

# ==========================================================================================================
note "S7) a materialize-error is counted separately and costs NO hunt budget; status stays ok (#2154) ..."
: > "$HUNTLOG"
export DARK_FACTORY_DIR="$WORK/s7"; mkdir -p "$DARK_FACTORY_DIR"
SUM="$DARK_FACTORY_DIR/change-watch/tick-summary.json"
# a source mock that FAILS for the `matfail` program's repo (make_scope writes repo_or_addr=example.invalid/<prog>)
# but succeeds otherwise, so matfail -> materialize-error and `good` (the next row) still hunts this tick.
SRC_MOCK_S7="$WORK/src-mock-s7.sh"
cat > "$SRC_MOCK_S7" <<MOCK
#!/usr/bin/env bash
set -u
case "\$MAT_REPO" in */matfail) exit 1;; esac
mkdir -p "\$MAT_DEST/src" || exit 1
echo "// mock materialized" > "\$MAT_DEST/src/Target.sol"
printf '%s\n' "\$MAT_DEST"
MOCK
chmod +x "$SRC_MOCK_S7"
W7="$(make_watch "matfail good")"
S7="$(make_scope "matfail:scoped:src/X.sol good:scoped:src/Y.sol")"
"$CP" --once --watch-cmd "$W7" --scope-cmd "$S7" --source-cmd "$SRC_MOCK_S7" --hunt-cmd "$HUNT_MOCK" \
  --hunts-per-tick 1 >/dev/null 2>>"$WORK/cp.err"
[ "$(jnum "$SUM" hunts_run)" = "1" ] && ok "S7: hunts_run=1 (good still ran though matfail failed to materialize)" || bad "S7: hunts_run=$(jnum "$SUM" hunts_run)"
[ "$(jnum "$SUM" materialize_errors)" = "1" ] && ok "S7: materialize_errors=1 (counted separately from hunts_run)" || bad "S7: materialize_errors=$(jnum "$SUM" materialize_errors)"
[ "$(jstr "$SUM" status)" = "ok" ] && ok "S7: status=ok (a materialize-error is not a stage error)" || bad "S7: status=$(jstr "$SUM" status)"
[ "$(head -n1 "$HUNTLOG" | awk -F'|' '{print $1}')" = "good" ] && ok "S7: the hunt that ran was 'good' (the row after the failure)" || bad "S7: hunted program = $(head -n1 "$HUNTLOG" | awk -F'|' '{print $1}')"

# ==========================================================================================================
echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: change-pipeline.sh chained M1->M2->M3 into one budget-bounded tick — a tick with changes scoped +"
  note "      hunted up to the cap (a finding staged through the never-submit gate), a quiet tick reported quiet,"
  note "      the --hunts-per-tick budget truncated a 3-change tick to N (forwarded to M3, not hardcoded), the"
  note "      (program,new) ledger made a re-run re-hunt nothing (resumable), the tick-summary rendered as the"
  note "      hunt-dashboard change_pipeline panel, and FORGE_MAX_SLOTS was exported with NO cron self-install."
  note "      Offline + deterministic; M1/M2 + the M3 leaf are mocks (plumbing only); ~/.dark-factory untouched."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
