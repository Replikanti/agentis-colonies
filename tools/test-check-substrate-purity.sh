#!/bin/bash
# tools/test-check-substrate-purity.sh: unit tests for
# check-substrate-purity.sh (#1587 ratchet / #1608 guard-rail).
#
# Validates:
#   Test 1:  clean file (no embedded interpreter) passes
#   Test 2:  NEW escape, no waiver, not allowlisted -> [NEW-ESCAPE], exit 1
#   Test 3:  waiver on the line directly above the finding -> passes (rule a)
#   Test 4:  waiver in the leading comment block above `fn` -> passes (rule b,
#            the real closed_by_context shape)
#   Test 5:  a file:function matching an allowlist entry passes (no waiver)
#   Test 6:  a comment-only prose mention of `python3 -c` passes (the ~70
#            doc-comment lines in the real corpus must not trip the scanner)
#   Test 7:  `python3 "$PATH/apply-edits.py"` script-path invocation passes
#            (pipe-target exemption — logic lives in the .py, not the .ag)
#   Test 8:  full Phase-1 wrapper `printf %s | python3 tools/apply-edits.py`
#            passes
#   Test 9:  documented limitation — `"python" + "3 -c ..."` split across the
#            `+` boundary on the SAME line is NOT caught (asserted to pass; a
#            grep-level scanner cannot reassemble the token)
#   Test 10: allowlist entry whose file no longer reproduces the finding ->
#            [STALE-ALLOWLIST], exit 1 (shrinking-debt direction)
#   Test 11: the REAL repo passes clean under the baked-in 15-entry allowlist
#   Test 12: flagged awk (`awk -F: '...'`) is caught — flag-tolerant AWK_PAT
#            (a QA-found evasion of the original quote-adjacent pattern)
#   Test 13: bare `python3 <<EOF` heredoc (program on stdin) is caught, while
#            `python3 script.py <<EOF` (heredoc feeding DATA to a script file)
#            passes — the QA-found heredoc evasion + its legitimate twin
#   Test 14: backslash-escaped `python3 \-c` is caught (QA-found evasion;
#            needs ENVIRON pattern delivery, -v would mangle the backslash)
#            (end-to-end; the concrete acceptance bar)
#
# Fixture tests drive the allowlist via SUBSTRATE_PURITY_ALLOWLIST_FILE so a
# minimal mktemp tree does not spuriously trip the [STALE-ALLOWLIST] direction
# for the 15 real sites it cannot reproduce — the same way
# test-check-getenv-allowlist.sh drives its allowlist through a fixture
# install.sh. Test 11 uses the real baked-in allowlist (no override).
#
# Usage: ./tools/test-check-substrate-purity.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -e

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TOOLS_DIR/.." && pwd)"
CHECK="$TOOLS_DIR/check-substrate-purity.sh"

# Early self-test: both scripts must parse (shellcheck-lint precedent).
bash -n "$CHECK"
bash -n "$TOOLS_DIR/test-check-substrate-purity.sh"

FAKE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FAKE_ROOT"' EXIT

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# make_tree <root> [allowlist-entries...]: build a fake dev-apprenticeship tree
# and an allowlist file. With no entries the allowlist is empty (only a comment
# line), so no [STALE-ALLOWLIST] can fire.
make_tree() {
    local root="$1"; shift
    mkdir -p "$root/dev-apprenticeship/triage/agents" \
             "$root/dev-apprenticeship/implementation/agents"
    {
        printf '# test allowlist\n'
        local e
        for e in "$@"; do printf '%s\n' "$e"; done
    } > "$root/allowlist.txt"
}

run_check() {
    local root="$1"
    SUBSTRATE_PURITY_ALLOWLIST_FILE="$root/allowlist.txt" "$CHECK" "$root" 2>&1
}

# ----- Test 1: clean file passes -----
T1="$FAKE_ROOT/t1"; make_tree "$T1"
cat > "$T1/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn tick() -> void {
    let x = now_iso();
    let cmd = "git status";
    exec_sh(cmd);
}
EOF
if run_check "$T1" >/dev/null 2>&1; then
    pass "clean file (no embedded interpreter) passes"
else
    fail "clean file — expected exit 0, got: $(run_check "$T1" || true)"
fi

# ----- Test 2: NEW escape, no waiver, not allowlisted -----
T2="$FAKE_ROOT/t2"; make_tree "$T2"
cat > "$T2/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn brand_new() -> string {
    let cmd = "X=" + shell_escape(v) +
        " python3 -c 'import os; print(os.environ[\"X\"])'";
    return exec_sh(cmd);
}
EOF
T2_OUT="$(run_check "$T2")" && T2_RC=0 || T2_RC=$?
if [ "$T2_RC" -eq 1 ] && printf '%s' "$T2_OUT" | grep -q '\[NEW-ESCAPE\].*brand_new'; then
    pass "NEW escape (no waiver, not allowlisted) fails with [NEW-ESCAPE]"
else
    fail "NEW escape — expected exit 1 + [NEW-ESCAPE], got rc=$T2_RC: $T2_OUT"
fi

# ----- Test 3: waiver on the line directly above the finding (rule a) -----
T3="$FAKE_ROOT/t3"; make_tree "$T3"
cat > "$T3/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn line_waived() -> string {
    let cmd = "X=" + shell_escape(v) +
        // substrate-purity: deferred (test: single-line-style waiver)
        " python3 -c 'print(1)'";
    return exec_sh(cmd);
}
EOF
if run_check "$T3" >/dev/null 2>&1; then
    pass "waiver on the line directly above the finding passes (rule a)"
else
    fail "line-above waiver — expected exit 0, got: $(run_check "$T3" || true)"
fi

# ----- Test 4: waiver in the leading comment block above `fn` (rule b) -----
# The real closed_by_context shape: the `deferred` marker sits in the comment
# block above the `fn`, several lines before the python3 line.
T4="$FAKE_ROOT/t4"; make_tree "$T4"
cat > "$T4/dev-apprenticeship/implementation/agents/a.ag" <<'EOF'
// numbered view of a blob; rides an env var off-argv so ARG_MAX never bites.
// substrate-purity: deferred (CB: native recursion would exhaust cb_per_tick)
fn block_waived(content: string) -> string {
    if len(content) == 0 { return ""; };
    let cmd = "C=" + shell_escape(content) +
        " python3 -c 'import os,sys" +
        "\ntext=os.environ[\"C\"]" +
        "\nprint(text)'";
    return exec_sh(cmd);
}
EOF
if run_check "$T4" >/dev/null 2>&1; then
    pass "waiver in the leading comment block above fn passes (rule b)"
else
    fail "block waiver — expected exit 0, got: $(run_check "$T4" || true)"
fi

# ----- Test 5: file:function matching an allowlist entry passes -----
T5="$FAKE_ROOT/t5"; make_tree "$T5" 'triage/agents/labeler.ag:normalize_labels_csv'
cat > "$T5/dev-apprenticeship/triage/agents/labeler.ag" <<'EOF'
fn normalize_labels_csv(raw: string) -> string {
    let cmd = "CSV=" + shell_escape(raw) +
        " python3 -c 'import os; print(os.environ[\"CSV\"].strip())'";
    return exec_sh(cmd);
}
EOF
if run_check "$T5" >/dev/null 2>&1; then
    pass "allowlisted file:function passes without a waiver"
else
    fail "allowlisted site — expected exit 0, got: $(run_check "$T5" || true)"
fi

# ----- Test 6: comment-only prose mention passes -----
T6="$FAKE_ROOT/t6"; make_tree "$T6"
cat > "$T6/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn native_now() -> string {
    // was an inline python3 -c timestamp; now uses the native builtin.
    // Note: awk 'BEGIN{...}' and sed 's/x/y/' were removed here too.
    return now_iso();
}
EOF
if run_check "$T6" >/dev/null 2>&1; then
    pass "comment-only prose mention of python3 -c / awk / sed passes"
else
    fail "prose mention — expected exit 0, got: $(run_check "$T6" || true)"
fi

# ----- Test 7: python3 "$PATH/apply-edits.py" script-path invocation passes ---
T7="$FAKE_ROOT/t7"; make_tree "$T7"
cat > "$T7/dev-apprenticeship/implementation/agents/a.ag" <<'EOF'
fn apply_edits() -> string {
    let cmd = "python3 \"$COLONY_DIR/../../tools/apply-edits.py\"";
    return exec_sh(cmd);
}
EOF
if run_check "$T7" >/dev/null 2>&1; then
    pass "python3 <script-path> invocation is exempt (pipe-target, not -c)"
else
    fail "script-path python3 — expected exit 0, got: $(run_check "$T7" || true)"
fi

# ----- Test 8: full Phase-1 wrapper shape passes -----
T8="$FAKE_ROOT/t8"; make_tree "$T8"
cat > "$T8/dev-apprenticeship/implementation/agents/a.ag" <<'EOF'
fn apply_line_edits() -> string {
    let cmd = "printf %s " + shell_escape(orig) +
        " | python3 tools/apply-edits.py";
    return exec_sh(cmd);
}
EOF
if run_check "$T8" >/dev/null 2>&1; then
    pass "printf | python3 tools/apply-edits.py wrapper passes"
else
    fail "wrapper shape — expected exit 0, got: $(run_check "$T8" || true)"
fi

# ----- Test 9: documented `+`-split limitation (deliberately permissive) -----
# A token split across the `+` boundary on the SAME line reads as `"python" +
# "3 -c ..."` — there is no contiguous `python3<ws>-` substring, so the
# line-level scanner cannot see it. This asserts the KNOWN limitation (matching
# check-exec-sh.sh's own `+`-splitting caveat), not a missed requirement; a full
# concatenation normalizer is explicitly out of scope for #1608.
T9="$FAKE_ROOT/t9"; make_tree "$T9"
cat > "$T9/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn split_evasion() -> string {
    let cmd = "python" + "3 -c 'print(1)'";
    return exec_sh(cmd);
}
EOF
if run_check "$T9" >/dev/null 2>&1; then
    pass "documented limitation: same-line +-split token is not caught (permissive by design)"
else
    fail "split evasion — expected exit 0 (documented gap), got: $(run_check "$T9" || true)"
fi

# ----- Test 10: allowlist entry no longer reproduced -> [STALE-ALLOWLIST] -----
T10="$FAKE_ROOT/t10"; make_tree "$T10" 'triage/agents/labeler.ag:normalize_labels_csv'
cat > "$T10/dev-apprenticeship/triage/agents/labeler.ag" <<'EOF'
fn normalize_labels_csv(raw: string) -> string {
    // rewrite landed: now native, the python3 -c escape is gone.
    return regex_replace(raw, "[[:space:]]+", "");
}
EOF
T10_OUT="$(run_check "$T10")" && T10_RC=0 || T10_RC=$?
if [ "$T10_RC" -eq 1 ] && printf '%s' "$T10_OUT" | grep -q '\[STALE-ALLOWLIST\].*normalize_labels_csv'; then
    pass "rewritten-but-still-allowlisted site fails with [STALE-ALLOWLIST]"
else
    fail "stale allowlist — expected exit 1 + [STALE-ALLOWLIST], got rc=$T10_RC: $T10_OUT"
fi

# ----- Test 12: flagged awk evasion (QA finding) -----
T12="$FAKE_ROOT/t12"; make_tree "$T12"
cat > "$T12/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn awk_flagged() -> string {
    let cmd = "printf %s " + shell_escape(v) + " | awk -F: '{print $2}'";
    return exec_sh(cmd);
}
EOF
T12_OUT="$(run_check "$T12")" && T12_RC=0 || T12_RC=$?
if [ "$T12_RC" -eq 1 ] && printf '%s' "$T12_OUT" | grep -q '\[NEW-ESCAPE\].*awk_flagged'; then
    pass "flag-carrying awk one-liner (awk -F: '...') is caught"
else
    fail "awk-flag evasion — expected exit 1 + [NEW-ESCAPE], got rc=$T12_RC: $T12_OUT"
fi

# ----- Test 13: bare python3 heredoc caught; script-file heredoc passes (QA finding) -----
T13="$FAKE_ROOT/t13"; make_tree "$T13"
cat > "$T13/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn heredoc_prog() -> string {
    let cmd = "python3 <<PYEOF
print(1)
PYEOF";
    return exec_sh(cmd);
}
EOF
cat > "$T13/dev-apprenticeship/triage/agents/b.ag" <<'EOF'
fn heredoc_data() -> string {
    let cmd = "python3 \"$COLONY_DIR/../../tools/apply-edits.py\" <<DATA
payload
DATA";
    return exec_sh(cmd);
}
EOF
T13_OUT="$(run_check "$T13")" && T13_RC=0 || T13_RC=$?
if [ "$T13_RC" -eq 1 ] \
   && printf '%s' "$T13_OUT" | grep -q '\[NEW-ESCAPE\].*heredoc_prog' \
   && ! printf '%s' "$T13_OUT" | grep -q 'heredoc_data'; then
    pass "bare python3 heredoc caught; script-file heredoc (data) passes"
else
    fail "heredoc pair — expected only heredoc_prog flagged, got rc=$T13_RC: $T13_OUT"
fi

# ----- Test 14: backslash-escaped dash evasion (QA finding) -----
T14="$FAKE_ROOT/t14"; make_tree "$T14"
cat > "$T14/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn backslash_dash() -> string {
    let cmd = "python3 \-c 'print(2)'";
    return exec_sh(cmd);
}
EOF
T14_OUT="$(run_check "$T14")" && T14_RC=0 || T14_RC=$?
if [ "$T14_RC" -eq 1 ] && printf '%s' "$T14_OUT" | grep -q '\[NEW-ESCAPE\].*backslash_dash'; then
    pass "backslash-escaped python3 \\-c is caught"
else
    fail "backslash-dash evasion — expected exit 1 + [NEW-ESCAPE], got rc=$T14_RC: $T14_OUT"
fi

# ----- Test 11: real repo passes clean (baked allowlist, no override) -----
T11_OUT="$("$CHECK" "$REPO_ROOT" 2>&1)" && T11_RC=0 || T11_RC=$?
if [ "$T11_RC" -eq 0 ]; then
    pass "real repo: 12 allowlisted + 1 waived site, zero findings"
else
    fail "real repo — expected exit 0, got rc=$T11_RC: $T11_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
