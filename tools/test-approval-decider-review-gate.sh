#!/usr/bin/env bash
# test-approval-decider-review-gate.sh (#1484): structural wiring assertions for
# the SECOND, independent merge gate in code-review/approval_decider.ag — the
# head-keyed QA review gate layered on top of the unchanged #1317 CI chokepoint.
#
# Before #1484 an autonomous auto-merge fired on green CI alone (PRs #1481/#1483
# merged in ~7 minutes with the review colony never producing a verdict). The
# remedy: require a PASSING QA verdict for the PR's CURRENT head commit before
# merging. qa_reviewer appends a commit-keyed marker
# `<!-- qa-verdict head=<fp16> status=<pass|block> -->` to its pre-merge note;
# approval_decider.review_gate() recomputes the head fingerprint from mr-changes
# (byte-identical to qa_reviewer's helper) and reads the marker off the durable
# mr-notes payload — agents cannot read each other's memos (#1375 lesson), so the
# verdict rides the forge. No verdict = HOLD (fail SAFE, never a spurious merge).
#
# The .ag has no runtime unit harness (colony-lint's per-agent `agentis commit`
# parse is its gate), so — exactly like tools/test-approval-decider-auto-merge.sh
# — the gate wiring is asserted at the grep level plus a parse check. The SAFETY
# invariants that MUST hold (pins (a)-(i) from the plan):
#
#   (a) CI gate precedes the review gate in merge_at, and the review-gate guard
#       precedes the merge_sweep:attempts bump (a wait/block never burns a merge
#       attempt; CI is still gated FIRST).
#   (b) review_gate reads mr-notes AND recomputes head_fingerprint from mr-changes.
#   (c) a block verdict posts a one-time held note (guarded by
#       merge_sweep:held_note:<iid>) and NEVER calls the merge verb.
#   (d) a wait returns without merging.
#   (e) the timeout branch honours getenv("MERGE_REVIEW_TIMEOUT_S") /
#       MERGE_REVIEW_TIMEOUT_ACTION with the safe defaults (1800 / hold).
#   (f) force-push invalidation: merge_sweep:review_wait_since:<iid> re-stamps
#       when the stored fp != head_fp.
#   (g) approval_decider.head_fingerprint is BYTE-IDENTICAL to
#       qa_reviewer.head_fingerprint (a mismatch would silently disable the gate).
#   (h) the rare bus-decision merge site is review-gated too (no bypass).
#   (i) approval_decider.ag parses (agentis commit) with the gate inserted.
#
# Matches the test style of tools/test-approval-decider-auto-merge.sh (bash,
# [PASS]/[FAIL] lines, `Results: N passed, M failed`). Exit 0 all-pass, 1 any-fail.
set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
AG="$REPO_ROOT/dev-apprenticeship/code-review/agents/approval_decider.ag"
QA_AG="$REPO_ROOT/dev-apprenticeship/code-review/agents/qa_reviewer.ag"
PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if [ ! -f "$AG" ]; then
    echo "[FAIL] approval_decider.ag present: missing $AG"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# Bodies of the functions carrying the gate logic.
MERGE_AT="$(awk '/^fn merge_at\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
REVIEW_GATE="$(awk '/^fn review_gate\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
HELD_NOTE="$(awk '/^fn post_held_note_once\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
TIMEOUT_S="$(awk '/^fn review_timeout_s\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
TIMEOUT_ACTION="$(awk '/^fn review_timeout_action\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"

# ---------------------------------------------------------------------------
# (a) CI gate FIRST, then review gate, then the attempts bump.
# ---------------------------------------------------------------------------
ci_line="$(grep -n 'if state != "green" { return 0; }' "$AG" | head -n1 | cut -d: -f1)"
gate_guard_line="$(grep -n 'if g != "merge" { return 0; }' "$AG" | head -n1 | cut -d: -f1)"
attempts_bump_line="$(grep -n 'memo_write(scoped_memo(owner, repo, "merge_sweep:attempts:" + iid_str), to_string(next_attempt))' "$AG" | head -n1 | cut -d: -f1)"
if [ -n "$ci_line" ] && [ -n "$gate_guard_line" ] && [ "$ci_line" -lt "$gate_guard_line" ]; then
    pass "(a) CI green-gate precedes the review gate in merge_at (CI still gated FIRST)"
else
    fail "(a) CI-before-review order" "ci_line=$ci_line gate_guard_line=$gate_guard_line"
fi
if [ -n "$gate_guard_line" ] && [ -n "$attempts_bump_line" ] && [ "$gate_guard_line" -lt "$attempts_bump_line" ]; then
    pass "(a) review-gate guard precedes the merge_sweep:attempts bump (a wait/block never burns an attempt)"
else
    fail "(a) review-before-attempts order" "gate_guard_line=$gate_guard_line attempts_bump_line=$attempts_bump_line"
fi
# merge_at calls review_gate and only "merge" falls through.
if printf '%s' "$MERGE_AT" | grep -q 'let g = review_gate(owner, repo, iid_str);' \
   && printf '%s' "$MERGE_AT" | grep -q 'if g != "merge" { return 0; }'; then
    pass "(a) merge_at gates on review_gate(...) == \"merge\" — wait/block returns 0"
else
    fail "(a) merge_at gate wiring" "merge_at must call review_gate and early-return unless it returns merge"
fi

# ---------------------------------------------------------------------------
# (b) review_gate reads mr-notes AND recomputes the head fingerprint.
# ---------------------------------------------------------------------------
if printf '%s' "$REVIEW_GATE" | grep -q 'forge-api.sh mr-changes ' \
   && printf '%s' "$REVIEW_GATE" | grep -q 'head_fingerprint(changes_raw)' \
   && printf '%s' "$REVIEW_GATE" | grep -q 'forge-api.sh mr-notes ' \
   && printf '%s' "$REVIEW_GATE" | grep -q 'note_verdict(notes_raw, head_fp, bot_login())'; then
    pass "(b) review_gate recomputes head_fingerprint from mr-changes and reads the marker off mr-notes"
else
    fail "(b) review_gate reads" "review_gate must fingerprint mr-changes and scan mr-notes via note_verdict"
fi
# The note_verdict call must be fail-closed wrapped (#1629): under an adversarial
# marker flood, the pure line-walk can exhaust cb_per_tick and raise an uncaught
# CognitiveOverload; the try/catch fallback to "" scopes the failure to this one
# PR (HOLD) instead of aborting the whole tick.
if printf '%s' "$REVIEW_GATE" | grep -Fq 'let status = try { note_verdict(notes_raw, head_fp, bot_login()); } catch e { ""; };'; then
    pass "(b) note_verdict call is fail-closed wrapped (try/catch -> \"\")"
else
    fail "(b) note_verdict fail-closed wrap" "the note_verdict call in review_gate must be wrapped: let status = try { note_verdict(...); } catch e { \"\"; };"
fi
# A passing verdict releases; a fail-to-fingerprint fails SAFE (wait, never merge).
if printf '%s' "$REVIEW_GATE" | grep -q 'if status == "pass" {' \
   && printf '%s' "$REVIEW_GATE" | grep -q 'if len(changes_raw) < 10 { return "wait"; }' \
   && printf '%s' "$REVIEW_GATE" | grep -q 'if len(head_fp) == 0 { return "wait"; }'; then
    pass "(b) a passing verdict returns merge; an un-fingerprintable head fails SAFE (wait)"
else
    fail "(b) pass/safe branches" "review_gate must return merge on pass and wait when the head can't be fingerprinted"
fi

# ---------------------------------------------------------------------------
# (b2) note_verdict newest-wins precedence (#1493): mr-notes is newest-first on
# both forges, so the FIRST match in iteration order is the LATEST verdict — the
# scan must take it and STOP, not overwrite-and-continue (which would let an
# early stray/forged "pass" mask a later genuine "block" for the same head).
# ---------------------------------------------------------------------------
NOTE_VERDICT="$(awk '/^fn note_verdict\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
# Native (#1613): the shared verdict-note core. scan_verdict walks the projected
# author\tbody TSV newest-first and take-and-STOPs on the first bot-authored
# marker (`return body;` in the match branch), then recurses on the tail — never
# an overwrite-and-continue that would let an early forged pass mask a later block.
SCAN_VERDICT="$(awk '/^fn scan_verdict\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
MARKED_BODY="$(awk '/^fn marked_bot_note_body\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
if printf '%s' "$SCAN_VERDICT" | grep -Fq 'return body;' \
   && printf '%s' "$SCAN_VERDICT" | grep -Fq 'return scan_verdict(substring(rest, nl + 1, len(rest)), me_lc, mprefix, marker_rx);' \
   && printf '%s' "$NOTE_VERDICT" | grep -Fq 'let body = marked_bot_note_body(notes_raw, head_fp, me);'; then
    pass "(b2) note_verdict stops on the FIRST (newest) match — scan_verdict take-and-stop, no overwrite-and-continue"
else
    fail "(b2) newest-wins precedence" "scan_verdict must return the first match body and recurse on the tail, and note_verdict must delegate to marked_bot_note_body"
fi
# The ordering assumption is stated explicitly in the doc comment.
if grep -B14 '^fn note_verdict(' "$AG" | grep -qi 'newest-first'; then
    pass "(b2) the note_verdict ordering assumption (mr-notes newest-first) is documented"
else
    fail "(b2) ordering comment" "the note_verdict doc comment must state the newest-first ordering assumption"
fi

# ---------------------------------------------------------------------------
# (b3) AUTHOR BIND (#1573): note_verdict honors a marker ONLY on a note authored
# by the fed's own bot (author.username casefold-equal to bot_login()), so a
# quoted `pass` marker by an operator/other bot can never release the #1484 HOLD.
# An empty ME (unconfigured forge identity) honors NOTHING (fail-closed).
# ---------------------------------------------------------------------------
BOT_LOGIN="$(awk '/^fn bot_login\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
# Structural (#1613): the per-note author bind (casefold -> to_lower) + the two
# empty fail-closed guards + the whole-blob quick-reject are present in the native
# shared core.
if printf '%s' "$SCAN_VERDICT" | grep -Fq 'if to_lower(substring(line, 0, tab)) == me_lc {' \
   && printf '%s' "$MARKED_BODY" | grep -Fq 'if len(head_fp) == 0 { return ""; };' \
   && printf '%s' "$MARKED_BODY" | grep -Fq 'if len(me) == 0 { return ""; };' \
   && printf '%s' "$MARKED_BODY" | grep -Fq 'if index_of(tsv, mprefix) < 0 { return ""; };'; then
    pass "(b3) note_verdict binds author via to_lower==me_lc, fails closed on empty head/me, and quick-rejects verdict-NONE"
else
    fail "(b3) author-bind guard" "the native core must bind to_lower(author)==me_lc, guard empty head+me, and quick-reject on index_of(tsv, mprefix) < 0"
fi
# bot_login resolves the fed login from GITHUB_ME else GITLAB_ME (no FORGE_TYPE
# branch — both are GITHUB_*/GITLAB_* wildcard-allowlisted, no install.sh edit).
if printf '%s' "$BOT_LOGIN" | grep -Fq 'getenv("GITHUB_ME")' \
   && printf '%s' "$BOT_LOGIN" | grep -Fq 'getenv("GITLAB_ME")' \
   && ! printf '%s' "$BOT_LOGIN" | grep -Fq 'FORGE_TYPE'; then
    pass "(b3) bot_login reads GITHUB_ME else GITLAB_ME (first-non-empty, no FORGE_TYPE branch)"
else
    fail "(b3) bot_login source" "bot_login must read GITHUB_ME else GITLAB_ME and not branch on FORGE_TYPE"
fi
# note_verdict is now a plain-arg native reader (no off-argv ME= env threading,
# no exec sh): assert the embedded python and its env plumbing are GONE.
if ! printf '%s' "$NOTE_VERDICT" | grep -Fq 'python3 -c' \
   && ! printf '%s' "$NOTE_VERDICT" | grep -Fq 'exec sh' \
   && ! printf '%s' "$MARKED_BODY" | grep -Fq 'python3 -c'; then
    pass "(b3) note_verdict / marked_bot_note_body are native — no embedded python, no exec sh"
else
    fail "(b3) native readers" "the verdict readers must carry no python3 -c / exec sh"
fi

# Behavioral (#1613): drive the REAL native readers via `agentis go` (the
# #1514/adv_parse precedent). awk-extract scan_verdict + marked_bot_note_body +
# note_verdict verbatim into a probe, feed fixtures, assert the full #1573 +
# #1493 matrix ON THE ACTUAL .ag path (no hand-kept oracle can drift from it). No
# --enable-exec needed (the readers have no exec sh). Skipped when agentis absent.
if command -v agentis >/dev/null 2>&1; then
    NV_TMP="$(mktemp -d)"
    {
        awk '/^fn scan_verdict\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG"
        awk '/^fn marked_bot_note_body\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG"
        awk '/^fn note_verdict\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG"
        # Fixtures (quoted heredoc — literal, so a `\n` inside a body stays the
        # two-char .ag escape the lexer turns into a runtime newline; a REAL
        # newline in .ag source is a parse error). HEAD keyed to abcdef1234567890.
        # Forged/quoted, genuine, casefold, empty-me, forged-newest-masks-older,
        # author-as-string (no .username -> skipped), status=weird newest skipped,
        # verdict-NONE, and an escaped-body case (a newline in the body ->
        # json_array_project escapes it, the marker still matches, no forged line).
        cat <<'AGEOF'
let HEAD = "abcdef1234567890";
let J_FORGED = "[{\"author\":{\"username\":\"random_operator\"},\"body\":\"quoting <!-- qa-verdict head=abcdef1234567890 status=pass --> for reference\"}]";
let J_GENUINE = "[{\"author\":{\"username\":\"qa-bot\"},\"body\":\"QA passed <!-- qa-verdict head=abcdef1234567890 status=pass -->\"}]";
let J_CASE = "[{\"author\":{\"username\":\"QA-Bot\"},\"body\":\"QA passed <!-- qa-verdict head=abcdef1234567890 status=pass -->\"}]";
let J_MASK = "[{\"author\":{\"username\":\"random_operator\"},\"body\":\"<!-- qa-verdict head=abcdef1234567890 status=pass -->\"},{\"author\":{\"username\":\"qa-bot\"},\"body\":\"blocked <!-- qa-verdict head=abcdef1234567890 status=block -->\"}]";
let J_STRAUTH = "[{\"author\":\"qa-bot\",\"body\":\"strauthor <!-- qa-verdict head=abcdef1234567890 status=pass -->\"}]";
let J_WEIRD = "[{\"author\":{\"username\":\"qa-bot\"},\"body\":\"weird <!-- qa-verdict head=abcdef1234567890 status=weird -->\"},{\"author\":{\"username\":\"qa-bot\"},\"body\":\"older <!-- qa-verdict head=abcdef1234567890 status=block -->\"}]";
let J_NL = "[{\"author\":{\"username\":\"qa-bot\"},\"body\":\"line1\nline2 <!-- qa-verdict head=abcdef1234567890 status=pass -->\"}]";
print("FORGED=[", note_verdict(J_FORGED, HEAD, "qa-bot"), "]");
print("GENUINE=[", note_verdict(J_GENUINE, HEAD, "qa-bot"), "]");
print("EMPTYME=[", note_verdict(J_GENUINE, HEAD, ""), "]");
print("CASE=[", note_verdict(J_CASE, HEAD, "qa-bot"), "]");
print("MASK=[", note_verdict(J_MASK, HEAD, "qa-bot"), "]");
print("STRAUTH=[", note_verdict(J_STRAUTH, HEAD, "qa-bot"), "]");
print("WEIRD=[", note_verdict(J_WEIRD, HEAD, "qa-bot"), "]");
print("NONE=[", note_verdict("[]", HEAD, "qa-bot"), "]");
print("MALFORMED=[", note_verdict("not json", HEAD, "qa-bot"), "]");
print("NL=[", note_verdict(J_NL, HEAD, "qa-bot"), "]");
AGEOF
    } > "$NV_TMP/probe.ag"
    (cd "$NV_TMP" && agentis init) >/dev/null 2>&1
    NV_OUT="$( (cd "$NV_TMP" && agentis go probe.ag) 2>/dev/null )"
    get() { printf '%s\n' "$NV_OUT" | sed -n "s/^$1=\\[ \\(.*\\) \\]\$/\\1/p"; }
    if [ "$(get FORGED)" = "" ]; then
        pass "(b3) forged/quoted pass by non-bot author -> \"\" (gate stays HELD, no release)"
    else
        fail "(b3) forged pass release" "a quoted pass marker by a non-bot author must NOT be honored (got '$(get FORGED)')"
    fi
    if [ "$(get GENUINE)" = "pass" ]; then
        pass "(b3) genuine bot-authored pass -> \"pass\" (gate releases)"
    else
        fail "(b3) genuine pass" "a bot-authored pass marker must return pass (got '$(get GENUINE)')"
    fi
    if [ "$(get EMPTYME)" = "" ]; then
        pass "(b3) empty me -> \"\" (honor nothing; fail-closed)"
    else
        fail "(b3) empty-me fail-closed" "an empty me must honor no marker (got '$(get EMPTYME)')"
    fi
    if [ "$(get CASE)" = "pass" ]; then
        pass "(b3) author case variation (QA-Bot vs qa-bot) -> \"pass\" (casefold via to_lower)"
    else
        fail "(b3) casefold author" "author login case drift must still be honored (got '$(get CASE)')"
    fi
    if [ "$(get MASK)" = "block" ]; then
        pass "(b3) forged newest pass cannot mask a genuine older bot block -> \"block\" (#1493 newest BOT-authored)"
    else
        fail "(b3) forged-pass mask" "a forged newest pass must not mask the genuine bot block (got '$(get MASK)')"
    fi
    if [ "$(get STRAUTH)" = "" ]; then
        pass "(b3) author-as-string (no .username projection) -> skipped -> \"\" (fail-closed)"
    else
        fail "(b3) author-as-string" "a note whose author is a bare string must be skipped (got '$(get STRAUTH)')"
    fi
    if [ "$(get WEIRD)" = "block" ]; then
        pass "(b3) a bot status=weird newest marker is skipped; the scan continues to the older valid block (re.search parity)"
    else
        fail "(b3) malformed-marker skip" "a status=weird marker must be skipped, not honored (got '$(get WEIRD)')"
    fi
    if [ "$(get NONE)" = "" ] && [ "$(get MALFORMED)" = "" ]; then
        pass "(b3) empty array + malformed JSON both quick-reject to \"\" (verdict-NONE / HELD)"
    else
        fail "(b3) none/malformed" "empty array + malformed JSON must both yield \"\" (got '$(get NONE)'/'$(get MALFORMED)')"
    fi
    if [ "$(get NL)" = "pass" ]; then
        pass "(b3) escaped body cell: a real newline in the body is escaped by json_array_project, the marker still matches, no forged second line -> \"pass\""
    else
        fail "(b3) escaped-body cell" "a body with a real newline must not break the projection/marker match (got '$(get NL)')"
    fi
    rm -rf "$NV_TMP"
else
    echo "[SKIP] (b3) live note_verdict probe — agentis not on PATH"
fi

# ---------------------------------------------------------------------------
# (c) A block verdict posts a one-time held note and NEVER merges.
# ---------------------------------------------------------------------------
if printf '%s' "$REVIEW_GATE" | grep -q 'if status == "block" {' \
   && printf '%s' "$REVIEW_GATE" | grep -q 'post_held_note_once(owner, repo, iid_str, head_fp,' \
   && printf '%s' "$REVIEW_GATE" | grep -q 'return "block";'; then
    pass "(c) a blocking verdict posts a held note and returns block"
else
    fail "(c) block branch" "review_gate must post_held_note_once + return block on a blocking verdict"
fi
# The held note is guarded once-per-head by merge_sweep:held_note:<iid> == head_fp.
if printf '%s' "$HELD_NOTE" | grep -q 'recall_latest(scoped_memo(owner, repo, "merge_sweep:held_note:" + iid_str))' \
   && printf '%s' "$HELD_NOTE" | grep -q 'if guard == head_fp { return; }' \
   && printf '%s' "$HELD_NOTE" | grep -q 'memo_write(scoped_memo(owner, repo, "merge_sweep:held_note:" + iid_str), head_fp)'; then
    pass "(c) the held note is guarded once-per-head by merge_sweep:held_note:<iid> == head_fp"
else
    fail "(c) held-note guard" "post_held_note_once must guard on merge_sweep:held_note:<iid> == head_fp"
fi
# review_gate NEVER invokes the merge verb — merging stays in merge_at / the bus
# site AFTER the gate returns merge.
if ! printf '%s' "$REVIEW_GATE" | grep -q 'forge-api.sh merge '; then
    pass "(c) review_gate never calls the merge verb (the gate only decides; merge_at merges)"
else
    fail "(c) gate is decision-only" "review_gate must not call forge-api.sh merge"
fi

# ---------------------------------------------------------------------------
# (d) A wait returns without merging.
# ---------------------------------------------------------------------------
wait_returns="$(printf '%s' "$REVIEW_GATE" | grep -c 'return "wait";')"
if [ "$wait_returns" -ge 1 ] && printf '%s' "$MERGE_AT" | grep -q 'if g != "merge" { return 0; }'; then
    pass "(d) a wait verdict returns without merging (merge_at's g != merge early-returns)"
else
    fail "(d) wait branch" "review_gate must return wait and merge_at must not merge on it (wait_returns=$wait_returns)"
fi

# ---------------------------------------------------------------------------
# (e) Timeout branch honours the getenv knobs with safe defaults.
# ---------------------------------------------------------------------------
if printf '%s' "$TIMEOUT_S" | grep -q 'getenv("MERGE_REVIEW_TIMEOUT_S")' \
   && printf '%s' "$TIMEOUT_S" | grep -q 'return 1800;'; then
    pass "(e) review_timeout_s reads MERGE_REVIEW_TIMEOUT_S, default 1800 (empty/unparsable)"
else
    fail "(e) timeout-seconds knob" "review_timeout_s must getenv MERGE_REVIEW_TIMEOUT_S and default to 1800"
fi
if printf '%s' "$TIMEOUT_ACTION" | grep -q 'getenv("MERGE_REVIEW_TIMEOUT_ACTION")' \
   && printf '%s' "$TIMEOUT_ACTION" | grep -q 'if raw == "merge" { return "merge"; }' \
   && printf '%s' "$TIMEOUT_ACTION" | grep -q 'return "hold";'; then
    pass "(e) review_timeout_action reads MERGE_REVIEW_TIMEOUT_ACTION, default hold (only \"merge\" opts in)"
else
    fail "(e) timeout-action knob" "review_timeout_action must getenv MERGE_REVIEW_TIMEOUT_ACTION and default to hold"
fi
# The timeout branch: waited >= window && action == merge -> merge; else HOLD
# (post a one-time note, keep waiting).
if printf '%s' "$REVIEW_GATE" | grep -q 'if waited < review_timeout_s() {' \
   && printf '%s' "$REVIEW_GATE" | grep -q 'if review_timeout_action() == "merge" {' \
   && printf '%s' "$REVIEW_GATE" | grep -q 'return "merge";'; then
    pass "(e) elapsed window + action=merge falls back to merge; otherwise HOLD (default)"
else
    fail "(e) timeout fallback" "review_gate must merge only when the window elapsed AND action == merge"
fi

# ---------------------------------------------------------------------------
# (f) Force-push invalidation: re-stamp the wait clock when stored fp != head.
# ---------------------------------------------------------------------------
if printf '%s' "$REVIEW_GATE" | grep -q 'recall_latest(scoped_memo(owner, repo, "merge_sweep:review_wait_since:" + iid_str))' \
   && printf '%s' "$REVIEW_GATE" | grep -q 'let stored_fp = repo_field(since_raw, 0);' \
   && printf '%s' "$REVIEW_GATE" | grep -q 'if stored_fp != head_fp {'; then
    pass "(f) force-push invalidation: review_wait_since is re-checked against the current head fp"
else
    fail "(f) force-push detect" "review_gate must compare the stored fp to head_fp"
fi
# The clock stores "<fp>\t<epoch>" and re-stamps head_fp + tab + now on absence
# OR fp mismatch (two write sites).
restamp_writes="$(printf '%s' "$REVIEW_GATE" | grep -c 'memo_write(scoped_memo(owner, repo, "merge_sweep:review_wait_since:" + iid_str), head_fp + "\\t" + to_string(now))')"
if [ "$restamp_writes" -eq 2 ]; then
    pass "(f) the wait clock is (re)stamped as head_fp+\\t+now on both absence and fp mismatch"
else
    fail "(f) clock re-stamp" "expected 2 review_wait_since re-stamps (absent + mismatch), found $restamp_writes"
fi

# ---------------------------------------------------------------------------
# (g) head_fingerprint BYTE-IDENTICAL between the two agents.
# ---------------------------------------------------------------------------
if [ ! -f "$QA_AG" ]; then
    fail "(g) qa_reviewer.ag present" "missing $QA_AG"
else
    AD_FP="$(awk '/^fn head_fingerprint\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
    QA_FP="$(awk '/^fn head_fingerprint\(/{f=1} f{print} /^}/{if(f) f=0}' "$QA_AG")"
    if [ -n "$AD_FP" ] && [ "$AD_FP" = "$QA_FP" ]; then
        pass "(g) approval_decider.head_fingerprint is byte-identical to qa_reviewer.head_fingerprint"
    else
        fail "(g) fingerprint byte-identity" "the two head_fingerprint bodies differ — the gate would silently never match"
    fi
fi

# ---------------------------------------------------------------------------
# (h) The bus-decision merge site is review-gated too (no bypass).
# ---------------------------------------------------------------------------
# The bus-path autonomous merge exec is wrapped so it runs only when
# review_gate(...) for the decision's iid returns "merge".
if grep -q 'if review_gate(owner, repo, to_string(decision.mr_iid)) == "merge" {' "$AG"; then
    pass "(h) the bus-decision autonomous merge site is also gated on review_gate(...) == merge"
else
    fail "(h) bus-path gate" "the bus-decision merge exec must be wrapped in a review_gate check"
fi
# There are exactly two merge-verb exec sites, and both are downstream of a
# review gate (merge_at's g-guard + the bus wrapper). Assert the bus site logs a
# held no-op when the gate holds.
if grep -q 'Auto-merge held for MR' "$AG"; then
    pass "(h) the bus site logs a held no-op when the review gate does not release"
else
    fail "(h) bus held log" "the bus-path gate must log a held no-op on a non-merge verdict"
fi

# ---------------------------------------------------------------------------
# exec-sh safety: the gate's dynamic exec-sh values are shell_escape'd + pragma'd.
# ---------------------------------------------------------------------------
if printf '%s' "$REVIEW_GATE" | grep -q 'mr-changes " + shell_escape(iid_str) + repo_arg' \
   && printf '%s' "$REVIEW_GATE" | grep -q 'mr-notes " + shell_escape(iid_str) + repo_arg' \
   && printf '%s' "$HELD_NOTE" | grep -q 'post-note " + shell_escape(iid_str) + " --body " + shell_escape(body) + repo_arg'; then
    pass "exec-sh dynamic values are shell_escape'd (iid in mr-changes/mr-notes, iid+body in post-note)"
else
    fail "exec-sh shell_escape" "the gate exec-sh commands must shell_escape their dynamic values"
fi
if grep -B1 'forge-api.sh mr-changes " + shell_escape(iid_str)' "$AG" | grep -q 'colony-lint: safe-exec-concat' \
   && grep -B1 'forge-api.sh mr-notes " + shell_escape(iid_str)' "$AG" | grep -q 'colony-lint: safe-exec-concat' \
   && grep -B1 'forge-api.sh post-note " + shell_escape(iid_str)' "$AG" | grep -q 'colony-lint: safe-exec-concat'; then
    pass "the gate exec-sh lines carry the safe-exec-concat lint pragma"
else
    fail "safe-exec-concat pragma" "the gate exec-sh command lines need the lint pragma"
fi

# ---------------------------------------------------------------------------
# (i) Parse check (same as the per-agent syntax pass in colony-lint.sh). Skipped
# (not failed) when agentis is not installed.
# ---------------------------------------------------------------------------
if command -v agentis >/dev/null 2>&1; then
    LINT_TMP="$(mktemp -d)"
    (cd "$LINT_TMP" && agentis init) >/dev/null 2>&1
    if (cd "$LINT_TMP" && agentis commit "$AG") >/dev/null 2>&1; then
        pass "(i) approval_decider.ag parses (agentis commit) with the review gate"
    else
        fail "(i) approval_decider.ag parses (agentis commit)" "syntax error in approval_decider.ag"
    fi
    rm -rf "$LINT_TMP"
else
    echo "[SKIP] agentis not on PATH — skipping .ag parse check"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
