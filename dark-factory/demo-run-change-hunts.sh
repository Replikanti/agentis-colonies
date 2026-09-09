#!/usr/bin/env bash
# demo-run-change-hunts.sh — OFFLINE, DETERMINISTIC proof (#2133, epic #2120 M3) of run-change-hunts.sh: the
# change-triggered hunt consumer that maps each M2 scope descriptor into a real run-zone-hunt.sh invocation,
# deduped by `(program, new)`, findings staged through the pipeline's own never-submit gate. Mirrors
# demo-scope-changes.sh / demo-funnel-e2e.sh assert-based [PASS]/[FAIL] accounting. A hand-written descriptors
# fixture + a canned `--source-cmd` STUB (materialize) + a canned `--hunt-cmd` STUB (hunt) so NO network
# (`git`/Sourcify/`agentis`/LLM are never invoked) and the real ~/.dark-factory is never touched.
#
# HONESTY GUARD (demo-funnel-e2e.sh precedent): the materialize + the hunt are MOCKS proving M3's PLUMBING only
# — the descriptor->argv transform, the (program,new) dedup ledger, the --max-hunts budget, and the never-submit
# staging seam. The REAL hunt is flat-cyborg-only via run-zone-hunt.sh (which inherits the #2125 sandbox + the
# #2133 refusal-fallback disable STRUCTURALLY) and needs a live session; it is exercised only in an operator run.
#
# Acceptance covered (issue #2133):
#   AC1 — a `scoped` descriptor drives the hunt with the right CHANGE_SCOPE_HINT + CHANGE_SINCE + CHANGE_REPO
#         (the materialized clone) and ledgers `(program, new)`.
#   AC2 — re-running the SAME descriptor is SKIPPED (no second hunt; the mock invocation count stays put).
#   AC3 — an `impl` descriptor fires the source-pull (MAT_KIND=source) and hunts FULL (no scope-hint).
#   AC4 — a `finding` verdict routes through deliver-submission.sh's never-submit gate (the staged package
#         carries SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW; an UNMARKED draft is REFUSED exit 3); a clean run
#         ledgers a rigorous-negative.
#   AC5 — a bare run over a multi-row descriptor file honours --max-hunts (no implicit fleet sweep).
#   AC6 — the M1->M2->M3 thread: scope-changes.sh-shaped rows feed straight into run-change-hunts.sh, and the
#         sandbox / refusal-fallback / never-submit / no-fleet-sweep invariants are documented in the header.
#   AC7 — the REAL hunt_args build (NOT the --hunt-cmd mock): run against a STUB run-zone-hunt.sh that echoes
#         its argv, a `scoped` descriptor -> `--scope-hint <files>` + `--since <old>`, a `full`/`impl`
#         descriptor -> NEITHER, and M2's `-` sentinel is never forwarded as a flag value.
#   AC8 — a materialize-error costs NO --max-hunts budget (#2154): matfail fails to materialize, `good` (the
#         next row) still runs in the SAME tick under --max-hunts 1. Fails on main (the budget was charged
#         BEFORE materialize, so the failure spent the only slot and `good` never ran).
#   AC9 — real OFFLINE materialize over a LOCAL git fixture: a slashed tag ref (graft/coreth/vX.Y.Z) pins the
#         worktree to the TAG's content (not the default-branch tip), and a nonexistent ref -> materialize-error
#         with NO silent default-tip hunt. Also guards the fetch-target.sh exec bit (the #2154 rc-126 cause).
#   AC10 — --max-materialize-errors caps a broken tick: 5 failing materializes at cap 2 -> exactly 2 ledgered
#         rows + a [materialize-budget] stop, so one bad tick cannot walk the whole descriptor file.
#
# Usage:  dark-factory/demo-run-change-hunts.sh
# Exit:   0 = all assertions held; 1 = a failure; 3 = the script under test is missing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RCH="$HERE/run-change-hunts.sh"
DELIVER="$HERE/deliver-submission.sh"

FAILS=0
note() { echo "demo-run-change-hunts.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -x "$RCH" ]     || { note "run-change-hunts.sh not found / not executable: $RCH" >&2; exit 3; }
[ -x "$DELIVER" ] || { note "deliver-submission.sh not found / not executable: $DELIVER" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-run-change-hunts.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Throwaway DARK_FACTORY_DIR so the real ~/.dark-factory is never touched even by the script defaults.
export DARK_FACTORY_DIR="$WORK/df"
mkdir -p "$DARK_FACTORY_DIR"

TAB="$(printf '\t')"
CAPTURE="$WORK/hunt-capture.log"   # one line per mock hunt invocation: program|new|repo|mode|hint|since
MATLOG="$WORK/materialize.log"     # one line per mock materialize: kind|repo|addr|ref|chain

# --- the MOCK materialize seam (--source-cmd): keyed on $MAT_KIND, creates a stub target dir + echoes it. No
#     git, no Sourcify, no network. It records the kind so AC3 can prove the source-pull path fired for impl.
SRC_MOCK="$WORK/src-mock.sh"
cat > "$SRC_MOCK" <<MOCK
#!/usr/bin/env bash
set -u
printf '%s|%s|%s|%s|%s\n' "\$MAT_KIND" "\$MAT_REPO" "\$MAT_ADDR" "\$MAT_REF" "\$MAT_CHAIN" >> "$MATLOG"
mkdir -p "\$MAT_DEST/src" || exit 1
echo "// mock materialized (\$MAT_KIND) at \$MAT_REF" > "\$MAT_DEST/src/Target.sol"
printf '%s\n' "\$MAT_DEST"
MOCK
chmod +x "$SRC_MOCK"

# --- the MOCK hunt seam (--hunt-cmd): records the CHANGE_* env run-change-hunts.sh derived (the argv decision:
#     a scope-hint iff scope_mode==scoped, a --since iff since is real), asserts the materialized repo exists,
#     and — for a program named `finder` — stages a MARKED finding into CHANGE_DROP_DIR exactly as the real
#     run-zone-hunt.sh does (through deliver-submission.sh's never-submit gate), so the verdict-by-drop-delta
#     holds. `cleanprog` stages nothing (a rigorous-negative).
HUNT_MOCK="$WORK/hunt-mock.sh"
cat > "$HUNT_MOCK" <<MOCK
#!/usr/bin/env bash
set -u
printf '%s|%s|%s|%s|%s|%s\n' "\$CHANGE_PROGRAM" "\$CHANGE_NEW" "\$CHANGE_REPO" \
  "\$CHANGE_SCOPE_MODE" "\$CHANGE_SCOPE_HINT" "\$CHANGE_SINCE" >> "$CAPTURE"
[ -d "\$CHANGE_REPO" ] || { echo "MOCK-ERR: materialized repo dir missing: \$CHANGE_REPO" >&2; exit 9; }
if [ "\$CHANGE_PROGRAM" = "finder" ]; then
  draft="$WORK/draft-\$CHANGE_PROGRAM.md"
  { echo "SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW"; echo "# mock finding for \$CHANGE_PROGRAM"; } > "\$draft"
  "$DELIVER" --id "\$CHANGE_PROGRAM@\$CHANGE_NEW:mock-finding" --draft-file "\$draft" \
    --target "\$CHANGE_PROGRAM" --severity High --drop-dir "\$CHANGE_DROP_DIR" >/dev/null 2>&1 || exit 8
fi
exit 0
MOCK
chmod +x "$HUNT_MOCK"

# small extractors over the change ledger (program TAB new TAB verdict TAB ts).
ledger_rows() { grep -cv '^#' "$1" 2>/dev/null || echo 0; }
ledger_verdict() { awk -F"$TAB" -v p="$1" '$1==p{print $3; exit}' "$2"; }
capture_lines() { grep -c . "$CAPTURE" 2>/dev/null || echo 0; }

# ==========================================================================================================
note "AC1) a scoped descriptor -> hunt with the right CHANGE_SCOPE_HINT/CHANGE_SINCE/CHANGE_REPO, ledgered ..."
: > "$CAPTURE"; : > "$MATLOG"
DESC_A="$WORK/desc-a.tsv"; LED_A="$WORK/ledger-a.tsv"; DROP_A="$WORK/drop-a"
printf 'alpha\t-\thead\thttps://github.com/example/alpha\tnewsha_alpha\tscoped\tsrc/Vault.sol,src/Token.sol\toldsha_alpha\n' > "$DESC_A"
# --work-dir is caller-supplied so the materialized clone is left in place for the post-hoc dir assertion
# (a mktemp'd work-dir is trap-cleaned by run-change-hunts.sh on exit).
"$RCH" --descriptors-from "$DESC_A" --ledger "$LED_A" --drop-dir "$DROP_A" --out "$WORK/out-a" \
  --work-dir "$WORK/wk-a" --max-hunts 1 --source-cmd "$SRC_MOCK" --hunt-cmd "$HUNT_MOCK" >/dev/null 2>"$WORK/a.err"
RC=$?
[ "$RC" -eq 0 ] && ok "AC1: run exits 0" || bad "AC1: run exited $RC (expected 0)"
[ "$(capture_lines)" -eq 1 ] && ok "AC1: exactly one hunt invoked" || bad "AC1: hunt invoked $(capture_lines) time(s), expected 1"
CAP_A="$(head -n1 "$CAPTURE")"
[ "$(printf '%s' "$CAP_A" | cut -d'|' -f4)" = "scoped" ] && ok "AC1: CHANGE_SCOPE_MODE = scoped" || bad "AC1: mode = $(printf '%s' "$CAP_A" | cut -d'|' -f4)"
[ "$(printf '%s' "$CAP_A" | cut -d'|' -f5)" = "src/Vault.sol,src/Token.sol" ] \
  && ok "AC1: CHANGE_SCOPE_HINT = the changed .sol files" \
  || bad "AC1: scope_hint = '$(printf '%s' "$CAP_A" | cut -d'|' -f5)'"
[ "$(printf '%s' "$CAP_A" | cut -d'|' -f6)" = "oldsha_alpha" ] && ok "AC1: CHANGE_SINCE = old sha" || bad "AC1: since = $(printf '%s' "$CAP_A" | cut -d'|' -f6)"
CAP_REPO="$(printf '%s' "$CAP_A" | cut -d'|' -f3)"
[ -n "$CAP_REPO" ] && [ -d "$CAP_REPO" ] && ok "AC1: CHANGE_REPO = the materialized clone dir ($CAP_REPO)" || bad "AC1: repo dir '$CAP_REPO' missing"
[ "$(printf '%s' "$(head -n1 "$MATLOG")" | cut -d'|' -f1)" = "clone" ] && ok "AC1: materialize used the clone path (head)" || bad "AC1: materialize kind = $(head -n1 "$MATLOG")"
[ "$(ledger_verdict alpha "$LED_A")" = "clean" ] && ok "AC1: (alpha, newsha_alpha) ledgered clean (rigorous-negative)" || bad "AC1: alpha verdict = $(ledger_verdict alpha "$LED_A")"

# ==========================================================================================================
note "AC2) re-running the SAME descriptor is SKIPPED (no second hunt) ..."
"$RCH" --descriptors-from "$DESC_A" --ledger "$LED_A" --drop-dir "$DROP_A" --out "$WORK/out-a2" \
  --max-hunts 1 --source-cmd "$SRC_MOCK" --hunt-cmd "$HUNT_MOCK" >/dev/null 2>"$WORK/a2.err"
[ "$(capture_lines)" -eq 1 ] && ok "AC2: hunt invocation count stayed at 1 (the re-run hunted nothing)" || bad "AC2: hunt count is now $(capture_lines) (a second hunt leaked)"
grep -q "already ledgered" "$WORK/a2.err" && ok "AC2: the re-run logged an already-ledgered skip" || bad "AC2: no already-ledgered skip logged"
[ "$(ledger_rows "$LED_A")" -eq 1 ] && ok "AC2: the ledger still holds exactly one row for alpha" || bad "AC2: ledger has $(ledger_rows "$LED_A") rows"

# ==========================================================================================================
note "AC3) an impl descriptor fires the source-pull (MAT_KIND=source) and hunts FULL (no scope-hint) ..."
: > "$CAPTURE"; : > "$MATLOG"
DESC_C="$WORK/desc-c.tsv"; LED_C="$WORK/ledger-c.tsv"
printf 'gamma\tethereum\timpl\t0x1111111111111111111111111111111111111111\t0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tfull\t-\t-\n' > "$DESC_C"
"$RCH" --descriptors-from "$DESC_C" --ledger "$LED_C" --drop-dir "$WORK/drop-c" --out "$WORK/out-c" \
  --max-hunts 1 --source-cmd "$SRC_MOCK" --hunt-cmd "$HUNT_MOCK" >/dev/null 2>"$WORK/c.err"
[ "$(printf '%s' "$(head -n1 "$MATLOG")" | cut -d'|' -f1)" = "source" ] && ok "AC3: materialize used the source-pull path (impl)" || bad "AC3: materialize kind = $(head -n1 "$MATLOG")"
[ "$(printf '%s' "$(head -n1 "$MATLOG")" | cut -d'|' -f3)" = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ] \
  && ok "AC3: source-pull received the new impl address" || bad "AC3: source addr = $(printf '%s' "$(head -n1 "$MATLOG")" | cut -d'|' -f3)"
CAP_C="$(head -n1 "$CAPTURE")"
[ "$(printf '%s' "$CAP_C" | cut -d'|' -f4)" = "full" ] && ok "AC3: CHANGE_SCOPE_MODE = full" || bad "AC3: mode = $(printf '%s' "$CAP_C" | cut -d'|' -f4)"
[ "$(printf '%s' "$CAP_C" | cut -d'|' -f5)" = "-" ] && ok "AC3: no scope-hint on a full impl hunt (CHANGE_SCOPE_HINT = '-')" || bad "AC3: scope_hint = '$(printf '%s' "$CAP_C" | cut -d'|' -f5)'"

# ==========================================================================================================
note "AC4) a finding routes through deliver-submission's never-submit gate; a clean run ledgers a negative ..."
: > "$CAPTURE"; : > "$MATLOG"
DESC_D="$WORK/desc-d.tsv"; LED_D="$WORK/ledger-d.tsv"; DROP_D="$WORK/drop-d"
printf 'finder\t-\thead\thttps://github.com/example/finder\tnewsha_finder\tscoped\tsrc/Bug.sol\toldsha_finder\n' > "$DESC_D"
printf 'cleanprog\t-\thead\thttps://github.com/example/clean\tnewsha_clean\tscoped\tsrc/Ok.sol\toldsha_clean\n' >> "$DESC_D"
"$RCH" --descriptors-from "$DESC_D" --ledger "$LED_D" --drop-dir "$DROP_D" --out "$WORK/out-d" \
  --max-hunts 2 --source-cmd "$SRC_MOCK" --hunt-cmd "$HUNT_MOCK" >/dev/null 2>"$WORK/d.err"
[ "$(ledger_verdict finder "$LED_D")" = "finding" ] && ok "AC4: finder ledgered a finding (drop-dir gained a package)" || bad "AC4: finder verdict = $(ledger_verdict finder "$LED_D")"
[ "$(ledger_verdict cleanprog "$LED_D")" = "clean" ] && ok "AC4: cleanprog ledgered a rigorous-negative (clean)" || bad "AC4: cleanprog verdict = $(ledger_verdict cleanprog "$LED_D")"
STAGED_DRAFT="$(find "$DROP_D" -name submission-draft.md 2>/dev/null | head -n1)"
if [ -n "$STAGED_DRAFT" ] && grep -q "SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW" "$STAGED_DRAFT"; then
  ok "AC4: the staged package carries the SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW human-gate marker"
else
  bad "AC4: staged draft missing the human-gate marker ($STAGED_DRAFT)"
fi
# the NEGATIVE: an UNMARKED draft is refused exit 3 (the never-submit invariant deliver-submission enforces).
UNMARKED="$WORK/unmarked.md"; echo "no human-gate marker here" > "$UNMARKED"
REFUSE_DROP="$WORK/refuse-drop"
"$DELIVER" --id "x@y:z" --draft-file "$UNMARKED" --drop-dir "$REFUSE_DROP" >/dev/null 2>&1
[ "$?" -eq 3 ] && ok "AC4: an UNMARKED draft is REFUSED exit 3 (never-submit gate holds)" || bad "AC4: unmarked draft not refused with exit 3"
[ ! -d "$REFUSE_DROP" ] && ok "AC4: no drop-dir created for the refused draft" || bad "AC4: a drop-dir leaked for a refused draft"

# ==========================================================================================================
note "AC5) a bare multi-row run honours --max-hunts (no implicit fleet sweep) ..."
: > "$CAPTURE"; : > "$MATLOG"
DESC_E="$WORK/desc-e.tsv"; LED_E="$WORK/ledger-e.tsv"
printf 'one\t-\thead\thttps://github.com/example/one\tnew1\tscoped\tsrc/A.sol\told1\n' > "$DESC_E"
printf 'two\t-\thead\thttps://github.com/example/two\tnew2\tscoped\tsrc/B.sol\told2\n' >> "$DESC_E"
printf 'three\t-\thead\thttps://github.com/example/three\tnew3\tscoped\tsrc/C.sol\told3\n' >> "$DESC_E"
"$RCH" --descriptors-from "$DESC_E" --ledger "$LED_E" --drop-dir "$WORK/drop-e" --out "$WORK/out-e" \
  --max-hunts 1 --source-cmd "$SRC_MOCK" --hunt-cmd "$HUNT_MOCK" >/dev/null 2>"$WORK/e.err"
[ "$(capture_lines)" -eq 1 ] && ok "AC5: exactly ONE hunt ran over a 3-row file (--max-hunts 1 held)" || bad "AC5: $(capture_lines) hunts ran, expected 1"
[ "$(ledger_rows "$LED_E")" -eq 1 ] && ok "AC5: only the hunted row is ledgered (the other two are untouched)" || bad "AC5: ledger has $(ledger_rows "$LED_E") rows, expected 1"
grep -q "reached --max-hunts" "$WORK/e.err" && ok "AC5: the budget stop is logged (resumable via the ledger)" || bad "AC5: no --max-hunts stop logged"

# ==========================================================================================================
note "AC6) the M1->M2->M3 thread: scope-changes.sh-shaped rows feed straight in; invariants documented ..."
: > "$CAPTURE"; : > "$MATLOG"
DESC_F="$WORK/desc-f.tsv"; LED_F="$WORK/ledger-f.tsv"
# EXACTLY scope-changes.sh's output shape: a `#` header block, then one descriptor per row (a scoped head + a
# skip row). run-change-hunts.sh must consume it verbatim (the M2->M3 handoff seam).
{
  echo "# scope-changes.sh descriptors (#2131, epic #2120 M2). TAB-separated. One row per changes.tsv row."
  printf '# program\tchain\tkind(head|tag|impl)\trepo_or_addr\tnew\tscope_mode(scoped|full|skip)\tscope_hint_files\tsince\n'
  printf 'thread\t-\thead\thttps://github.com/example/thread\tnewsha_thread\tscoped\tsrc/T.sol\toldsha_thread\n'
  printf 'docsonly\t-\thead\thttps://github.com/example/docs\tnewsha_docs\tskip\t-\t-\n'
} > "$DESC_F"
"$RCH" --descriptors-from "$DESC_F" --ledger "$LED_F" --drop-dir "$WORK/drop-f" --out "$WORK/out-f" \
  --max-hunts 5 --source-cmd "$SRC_MOCK" --hunt-cmd "$HUNT_MOCK" >/dev/null 2>"$WORK/f.err"
[ "$(capture_lines)" -eq 1 ] && ok "AC6: the scoped row was hunted, the skip row was not (1 hunt)" || bad "AC6: $(capture_lines) hunts, expected 1"
[ "$(ledger_verdict thread "$LED_F")" = "clean" ] && ok "AC6: the scoped row ledgered clean" || bad "AC6: thread verdict = $(ledger_verdict thread "$LED_F")"
[ "$(ledger_verdict docsonly "$LED_F")" = "skipped-nohunt" ] && ok "AC6: the skip row ledgered skipped-nohunt (never hunted)" || bad "AC6: docsonly verdict = $(ledger_verdict docsonly "$LED_F")"
grep -q "HUNT_SANDBOX" "$RCH" && ok "AC6: the header documents the #2125 sandbox inheritance" || bad "AC6: no sandbox-inheritance note in the header"
grep -q "CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK" "$RCH" && ok "AC6: the header documents the #2133 refusal-fallback inheritance" || bad "AC6: no refusal-fallback note in the header"
grep -qi "no implicit fleet sweep\|NO IMPLICIT FLEET SWEEP" "$RCH" && ok "AC6: the header documents the no-fleet-sweep guard" || bad "AC6: no fleet-sweep guard note"
grep -qi "never contacts a bounty platform\|never-submit\|never submit" "$RCH" && ok "AC6: the header documents the never-submit invariant" || bad "AC6: no never-submit note"

# ==========================================================================================================
note "AC7) the REAL hunt_args build (no --hunt-cmd): scoped -> --scope-hint + --since; full/impl -> neither;"
note "     M2's '-' sentinel is NEVER forwarded as a flag value ..."
# Exercise the actual run-zone-hunt.sh invocation path (NOT the --hunt-cmd mock) so a regression in the
# scoped/full/impl conditional is caught. run-change-hunts.sh calls "$HERE/run-zone-hunt.sh"; drop a COPY of it
# into a temp bindir next to a STUB run-zone-hunt.sh that just echoes its argv, so $HERE resolves to the stub.
BIN="$WORK/bin"; mkdir -p "$BIN"
cp "$RCH" "$BIN/run-change-hunts.sh"; chmod +x "$BIN/run-change-hunts.sh"
ARGV_LOG="$WORK/argv.log"; : > "$ARGV_LOG"
cat > "$BIN/run-zone-hunt.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGV_LOG"
exit 0
STUB
chmod +x "$BIN/run-zone-hunt.sh"
DESC_G="$WORK/desc-g.tsv"; LED_G="$WORK/ledger-g.tsv"
printf 'scopedp\t-\thead\thttps://github.com/example/scopedp\tnewscoped\tscoped\tsrc/A.sol,src/B.sol\toldscoped\n' > "$DESC_G"
printf 'fullp\t-\thead\thttps://github.com/example/fullp\tnewfull\tfull\t-\t-\n' >> "$DESC_G"
printf 'implp\tethereum\timpl\t0x1111111111111111111111111111111111111111\t0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tfull\t-\t-\n' >> "$DESC_G"
# --source-cmd mocks materialize (offline); NO --hunt-cmd, so the real hunt_args array + the stub are used.
"$BIN/run-change-hunts.sh" --descriptors-from "$DESC_G" --ledger "$LED_G" --drop-dir "$WORK/drop-g" \
  --out "$WORK/out-g" --work-dir "$WORK/wk-g" --max-hunts 3 --source-cmd "$SRC_MOCK" >/dev/null 2>"$WORK/g.err"
[ "$(grep -c . "$ARGV_LOG")" -eq 3 ] && ok "AC7: the real path invoked run-zone-hunt.sh three times" || bad "AC7: run-zone-hunt.sh invoked $(grep -c . "$ARGV_LOG") time(s), expected 3"
SCOPED_ARGV="$(grep -- 'scopedp' "$ARGV_LOG" | head -n1)"
FULL_ARGV="$(grep -- 'fullp' "$ARGV_LOG" | head -n1)"
IMPL_ARGV="$(grep -- 'out-g/implp' "$ARGV_LOG" | head -n1)"
case "$SCOPED_ARGV" in *"--scope-hint src/A.sol,src/B.sol"*) ok "AC7: scoped argv carries --scope-hint <files>";; *) bad "AC7: scoped argv missing --scope-hint: $SCOPED_ARGV";; esac
case "$SCOPED_ARGV" in *"--since oldscoped"*) ok "AC7: scoped argv carries --since <old>";; *) bad "AC7: scoped argv missing --since: $SCOPED_ARGV";; esac
case "$FULL_ARGV" in *"--scope-hint"*|*"--since"*) bad "AC7: full argv wrongly carries --scope-hint/--since: $FULL_ARGV";; *) ok "AC7: full argv carries NEITHER --scope-hint nor --since";; esac
case "$IMPL_ARGV" in *"--scope-hint"*|*"--since"*) bad "AC7: impl argv wrongly carries --scope-hint/--since: $IMPL_ARGV";; *) ok "AC7: impl argv carries NEITHER --scope-hint nor --since";; esac
if grep -qE -- '--(scope-hint|since) -($| )' "$ARGV_LOG"; then
  bad "AC7: M2's '-' sentinel was forwarded as a flag value"
else
  ok "AC7: M2's '-' sentinel is NEVER forwarded as a --scope-hint/--since value"
fi

# ==========================================================================================================
note "AC8) a materialize-error costs NO --max-hunts budget: the next huntable row still runs this tick (#2154) ..."
: > "$CAPTURE"; : > "$MATLOG"
# A source mock that FAILS to materialize `matfail` but succeeds for `good`. With --max-hunts 1 the OLD code
# charged the budget BEFORE materialize, so matfail spent the only slot and `good` never ran; the fix charges
# the budget only AFTER a successful materialize.
SRC_MOCK_FAIL="$WORK/src-mock-fail.sh"
cat > "$SRC_MOCK_FAIL" <<MOCK
#!/usr/bin/env bash
set -u
case "\$MAT_REPO" in *example/matfail) exit 1;; esac
mkdir -p "\$MAT_DEST/src" || exit 1
echo "// mock ok" > "\$MAT_DEST/src/Target.sol"
printf '%s\n' "\$MAT_DEST"
MOCK
chmod +x "$SRC_MOCK_FAIL"
DESC_H="$WORK/desc-h.tsv"; LED_H="$WORK/ledger-h.tsv"
printf 'matfail\t-\thead\thttps://github.com/example/matfail\tnewmf\tscoped\tsrc/M.sol\toldmf\n' > "$DESC_H"
printf 'good\t-\thead\thttps://github.com/example/good\tnewgood\tscoped\tsrc/G.sol\toldgood\n' >> "$DESC_H"
"$RCH" --descriptors-from "$DESC_H" --ledger "$LED_H" --drop-dir "$WORK/drop-h" --out "$WORK/out-h" \
  --max-hunts 1 --source-cmd "$SRC_MOCK_FAIL" --hunt-cmd "$HUNT_MOCK" >/dev/null 2>"$WORK/h.err"
[ "$(capture_lines)" -eq 1 ] && ok "AC8: exactly one hunt ran despite the earlier materialize-error" || bad "AC8: $(capture_lines) hunts ran, expected 1 (budget wrongly spent on the failure?)"
[ "$(printf '%s' "$(head -n1 "$CAPTURE")" | cut -d'|' -f1)" = "good" ] && ok "AC8: the hunt that ran was 'good' (the row after the failure)" || bad "AC8: hunted program = $(printf '%s' "$(head -n1 "$CAPTURE")" | cut -d'|' -f1)"
[ "$(ledger_verdict matfail "$LED_H")" = "materialize-error" ] && ok "AC8: matfail ledgered materialize-error" || bad "AC8: matfail verdict = $(ledger_verdict matfail "$LED_H")"
[ "$(ledger_verdict good "$LED_H")" = "clean" ] && ok "AC8: good ledgered clean (it still ran in the same tick)" || bad "AC8: good verdict = $(ledger_verdict good "$LED_H")"
grep -q "materialize failed" "$WORK/h.err" && ok "AC8: the materialize-error is reported on stderr" || bad "AC8: no materialize-error on stderr"

# ==========================================================================================================
note "AC9) real offline materialize: a slashed tag ref pins the worktree to the TAG content; a bad ref errors ..."
: > "$CAPTURE"; : > "$MATLOG"
# exec-bit guard (the #2154 rc-126 root cause): the committed fetch-target.sh next to run-change-hunts.sh MUST
# be executable, else run-change-hunts.sh's direct exec of it returns 126 for every materialize.
[ -x "$HERE/fetch-target.sh" ] && ok "AC9: fetch-target.sh is executable (mode guard; the rc-126 root cause)" || bad "AC9: fetch-target.sh not executable — every materialize would rc-126"
# a LOCAL git fixture: commit1 tagged graft/coreth/v1.15.0 (file=TAGVER), commit2 on the default branch (TIPVER).
FIX="$WORK/fixture-repo"; mkdir -p "$FIX/src"
git -C "$FIX" init -q
git -C "$FIX" config user.email demo@example.invalid
git -C "$FIX" config user.name demo-fixture
echo "// TAGVER" > "$FIX/src/Pinned.sol"
git -C "$FIX" add -A; git -C "$FIX" commit -qm c1
git -C "$FIX" tag graft/coreth/v1.15.0
echo "// TIPVER" > "$FIX/src/Pinned.sol"
git -C "$FIX" add -A; git -C "$FIX" commit -qm c2
# a real-path bindir carrying run-change-hunts.sh + fetch-target.sh (so the REAL default_materialize runs) +
# a stub run-zone-hunt.sh that records the --repo dir AND the pinned file content it sees.
BIN9="$WORK/bin9"; mkdir -p "$BIN9"
cp -p "$RCH" "$BIN9/run-change-hunts.sh"
cp -p "$HERE/fetch-target.sh" "$BIN9/fetch-target.sh"
ARGV9="$WORK/argv9.log"; : > "$ARGV9"
cat > "$BIN9/run-zone-hunt.sh" <<STUB
#!/usr/bin/env bash
repo=""; while [ \$# -gt 0 ]; do [ "\$1" = "--repo" ] && repo="\$2"; shift; done
printf '%s\t%s\n' "\$repo" "\$(cat "\$repo/src/Pinned.sol" 2>/dev/null)" >> "$ARGV9"
exit 0
STUB
chmod +x "$BIN9/run-zone-hunt.sh"
DESC_I="$WORK/desc-i.tsv"; LED_I="$WORK/ledger-i.tsv"
printf 'pinned\t-\ttag\t%s\tgraft/coreth/v1.15.0\tscoped\tsrc/Pinned.sol\tgraft/coreth/v1.14.0\n' "$FIX" > "$DESC_I"
printf 'badref\t-\ttag\t%s\tv9.9.9-does-not-exist\tscoped\tsrc/Pinned.sol\tv1.0.0\n' "$FIX" >> "$DESC_I"
"$BIN9/run-change-hunts.sh" --descriptors-from "$DESC_I" --ledger "$LED_I" --drop-dir "$WORK/drop-i" \
  --out "$WORK/out-i" --work-dir "$WORK/wk-i" --max-hunts 5 >/dev/null 2>"$WORK/i.err"
[ "$(ledger_verdict pinned "$LED_I")" = "clean" ] && ok "AC9: the slashed tag row materialized + hunted (clean)" || bad "AC9: pinned verdict = $(ledger_verdict pinned "$LED_I") (see $WORK/out-i/materialize.log)"
[ "$(grep -c 'TAGVER' "$ARGV9" || true)" -eq 1 ] && ok "AC9: the hunted worktree holds the TAG content (slashed-ref pin), not the tip" || bad "AC9: worktree not pinned to the tag ($(cat "$ARGV9"))"
if grep -q 'TIPVER' "$ARGV9"; then bad "AC9: the default-branch tip content leaked into the hunt (pin failed)"; else ok "AC9: no default-branch-tip content leaked (authoritative pin)"; fi
[ "$(ledger_verdict badref "$LED_I")" = "materialize-error" ] && ok "AC9: a nonexistent tag ref -> materialize-error (never a silent default-tip hunt)" || bad "AC9: badref verdict = $(ledger_verdict badref "$LED_I")"
[ "$(grep -c . "$ARGV9")" -eq 1 ] && ok "AC9: the bad-ref row ran NO hunt (no silent default-tip hunt)" || bad "AC9: $(grep -c . "$ARGV9") hunts ran, expected 1"

# ==========================================================================================================
note "AC10) --max-materialize-errors caps a broken tick: 5 failing rows, cap 2 -> 2 ledgered + a budget stop ..."
: > "$CAPTURE"; : > "$MATLOG"
DESC_J="$WORK/desc-j.tsv"; LED_J="$WORK/ledger-j.tsv"
: > "$DESC_J"; j=1
while [ "$j" -le 5 ]; do
  printf 'mf%s\t-\thead\thttps://github.com/example/mf%s\tnew%s\tscoped\tsrc/X.sol\told%s\n' "$j" "$j" "$j" "$j" >> "$DESC_J"
  j=$((j + 1))
done
"$RCH" --descriptors-from "$DESC_J" --ledger "$LED_J" --drop-dir "$WORK/drop-j" --out "$WORK/out-j" \
  --max-hunts 9 --max-materialize-errors 2 --source-cmd 'exit 1' --hunt-cmd "$HUNT_MOCK" >/dev/null 2>"$WORK/j.err"
[ "$(ledger_rows "$LED_J")" -eq 2 ] && ok "AC10: exactly 2 materialize-error rows ledgered (the cap stopped the tick)" || bad "AC10: ledger has $(ledger_rows "$LED_J") rows, expected 2"
grep -q "reached --max-materialize-errors" "$WORK/j.err" && ok "AC10: the [materialize-budget] stop is logged" || bad "AC10: no materialize-budget stop logged"
[ ! -s "$CAPTURE" ] && ok "AC10: no hunt ran (every materialize failed)" || bad "AC10: a hunt ran though every materialize failed"

# ==========================================================================================================
echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: run-change-hunts.sh mapped each M2 descriptor into the right hunt — a scoped change into a"
  note "      scope-hinted/since-pinned hunt over the materialized clone, an impl upgrade into a full hunt of"
  note "      the source-pulled impl, an already-ledgered change into a SKIP (deduped by (program,new)), a"
  note "      finding through deliver-submission's never-submit human gate (an unmarked draft refused), a clean"
  note "      run into a rigorous-negative, and honoured --max-hunts with NO implicit fleet sweep. Offline +"
  note "      deterministic; materialize + hunt are mocks (plumbing only); the real ~/.dark-factory is untouched."
  exit 0
fi
note "DEMO FAILED: $FAILS assertion(s) did not hold — see above." >&2
exit 1
