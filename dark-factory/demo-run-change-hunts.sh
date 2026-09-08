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
