#!/usr/bin/env bash
# test-qa-reviewer.sh (#1401): wiring + contract assertions for the code-review
# colony's pre-merge QA verdict agent (step 1 of #1359).
#
# qa_reviewer judges every open MR on three dimensions — completeness (does the
# diff address the whole linked issue and every site/test the description
# claims to touch), description-vs-diff (are the description's claims backed
# by the committed diff; cross-ref #1349), and adversarial (a default-skeptical
# second opinion that tries to REFUTE the change; #1405) — and posts ONE
# structured note per MR head:
#
#   QA verdict: completeness=pass|fail, description-vs-diff=pass|fail, adversarial=pass|fail
#
# The .ag has no runtime unit harness (colony-lint's per-agent `agentis commit`
# parse is its gate) and the pass/fail judgement itself is an LLM call, so —
# exactly like tools/test-approval-decider-auto-merge.sh — the four issue-#1401
# scenarios are asserted at the contract level (grep over the .ag) plus a
# fixture-driven check of the head-fingerprint dedup that scenario (d) rides on:
#
#   (a) overstated description  -> description-vs-diff=fail: the prompt must
#       define the description_vs_diff dimension, instruct that overstatements
#       (claimed-but-absent regression test) fail, and the note renderer must
#       append a reason line on the fail branch.
#   (b) partial change vs issue -> completeness=fail: the prompt must define
#       the completeness dimension against the LINKED ISSUE + claimed
#       sites/tests, instruct that partial/claim-only changes fail, and the
#       linked issue must actually be resolved + fetched into the context.
#   (c) clean MR -> both pass: the fixed verdict header renders both
#       dimensions, and reason lines are emitted ONLY on the fail branches.
#   (d) no repost on unchanged MR head: the per-head fingerprint is stable for
#       an identical diff and changes when the diff changes (fixture run of the
#       sha256[:16] property in an independent python3 harness, value-identical
#       to the agent's native sha256_hex expression, #1588 slice 3), the memo gate reads
#       qa_reviewer:verdict_head:<iid> BEFORE prompt() in the same function,
#       every tier branch writes the marker, and the autonomous/review-gated
#       branches write it only after a successful post.
#
# The #1405 adversarial dimension adds four more scenarios (labelled adv-*):
#
#   (adv-a) refutable change -> adversarial=fail with a reason: the prompt is
#       framed to REFUTE (default-skeptical, not summarize), a constructed
#       concrete refutation is 'fail', and the note renderer appends the
#       one-line reason only on the adv == "fail" branch.
#   (adv-b) sound change -> adversarial=pass: the prompt passes ONLY on a
#       genuine failed refutation attempt, and adv_parse is total — an empty /
#       junk / errored backend reply collapses to "pass" (never a false fail).
#   (adv-c) QA_ADVERSARIAL_LLM_CMD is honoured + exercised when set: the env
#       var reroutes the refutation through an alternative backend via exec sh,
#       falls back to prompt() when unset, and NEVER disables the dimension
#       (qa_one_mr computes it unconditionally). A behavioural fixture drives a
#       fake backend through the exact override pipeline + the agent's adv_parse
#       program (fence/prose-wrapped refutation -> fail with reason).
#   (adv-d) the posted verdict note carries all THREE dimensions on one header
#       line (completeness, description-vs-diff, adversarial) and qa_one_mr
#       threads the adversarial status/reason into verdict_note.
#
# Plus registration parity with test_reviewer (colony.example.toml,
# start-colony.sh AGENTS + tick case arm, install.sh ALL_AGENTS, colony README)
# and the federation lint contracts (learn/recommend topic match, exec-sh
# escaping + pragmas, tier gating via repo_tier).
#
# Matches the test style of tools/test-approval-decider-auto-merge.sh (bash,
# [PASS]/[FAIL] lines, `Results: N passed, M failed`). Exit 0 all-pass, 1 any-fail.
set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
COLONY="$REPO_ROOT/dev-apprenticeship/code-review"
AG="$COLONY/agents/qa_reviewer.ag"
PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if [ ! -f "$AG" ]; then
    echo "[FAIL] qa_reviewer.ag present: missing $AG"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# Bodies of the functions carrying the per-MR contract.
QA_ONE="$(awk '/^fn qa_one_mr\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
NOTE_FN="$(awk '/^fn verdict_note\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
# Bodies of the adversarial-dimension functions (#1405).
ADV_PROMPT="$(awk '/^fn adversarial_instruction\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
ADV_REPLY="$(awk '/^fn adversarial_reply\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
ADV_PARSE="$(awk '/^fn adv_parse\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"

# ---------------------------------------------------------------------------
# (a) Overstated description -> description-vs-diff=fail
# ---------------------------------------------------------------------------
if printf '%s' "$QA_ONE" | grep -q 'description_vs_diff' \
   && printf '%s' "$QA_ONE" | grep -qi 'Overstatements fail'; then
    pass "(a) prompt defines description_vs_diff and instructs that overstatements fail"
else
    fail "(a) description_vs_diff dimension" "prompt must define description_vs_diff and fail overstatements"
fi
if printf '%s' "$QA_ONE" | grep -q 'adds a regression test'; then
    pass "(a) prompt names the claimed-but-absent regression test as a canonical overstatement (#1349)"
else
    fail "(a) regression-test example" "prompt must call out the 'adds a regression test' overstatement"
fi
if printf '%s' "$NOTE_FN" | grep -q 'description_vs_diff == "fail"' \
   && printf '%s' "$NOTE_FN" | grep -q 'description-vs-diff: " + v.description_vs_diff_reason'; then
    pass "(a) note renderer appends a one-line description-vs-diff reason on the fail branch"
else
    fail "(a) fail-reason line" "verdict_note must append description_vs_diff_reason when the dimension fails"
fi

# ---------------------------------------------------------------------------
# (b) Partial change vs issue claims -> completeness=fail
# ---------------------------------------------------------------------------
if printf '%s' "$QA_ONE" | grep -q 'completeness' \
   && printf '%s' "$QA_ONE" | grep -qi 'Partial changes and claim-only changes'; then
    pass "(b) prompt defines completeness and fails partial / claim-only changes"
else
    fail "(b) completeness dimension" "prompt must define completeness and fail partial/claim-only changes"
fi
if printf '%s' "$QA_ONE" | grep -q 'WHOLE linked issue'; then
    pass "(b) completeness is judged against the WHOLE linked issue"
else
    fail "(b) whole-issue wording" "prompt must judge the diff against the whole linked issue"
fi
# The linked issue must actually be resolved (branch fix/issue-<n>, else the
# closing-keyword reference in the description; #1514) and fetched via the forge
# get-issue verb into the context.
if grep -Eq '^fn linked_issue_iid\(' "$AG" \
   && grep -q 'issue-(\[0-9\]+)' "$AG" \
   && printf '%s' "$QA_ONE" | grep -q 'forge-api.sh get-issue '; then
    pass "(b) linked issue resolved (fix/issue-<n> branch, else closing-keyword #<n>) and fetched via get-issue"
else
    fail "(b) linked-issue wiring" "linked_issue_iid + forge-api.sh get-issue must feed the prompt context"
fi
if printf '%s' "$QA_ONE" | grep -q 'Linked issue #'; then
    pass "(b) fetched issue is spliced into the prompt context"
else
    fail "(b) issue context splice" "the fetched issue JSON must be part of the prompt context"
fi

# ---------------------------------------------------------------------------
# (b-anchor / #1514) completeness anchors on the closing-keyword issue reference
# ---------------------------------------------------------------------------
# Regression from live PR #1513: a body whose regression-CONTEXT mention
# ("the #1500 plan-post pushed the draft tick over budget") precedes the real
# "Fixes #1512" reference must anchor completeness on #1512, not #1500. The old
# heuristic picked the FIRST `#N` anywhere in the body and judged the diff
# against the wrong issue's acceptance criteria, emitting a false status=block.
LINK_FN="$(awk '/^fn linked_issue_iid\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
# The .ag must resolve via GitHub closing keywords and must NOT keep the old
# bare-`#N`-anywhere fallback (that is the exact bug this pins).
if printf '%s' "$LINK_FN" | grep -q 'clos(?:e|es|ed)' \
   && printf '%s' "$LINK_FN" | grep -q 'fix(?:|es|ed)' \
   && printf '%s' "$LINK_FN" | grep -q 'resolv(?:e|es|ed)'; then
    pass "(#1514) linked_issue_iid resolves via GitHub closing keywords (fix/close/resolve, case-insensitive)"
else
    fail "(#1514) closing-keyword regex" "linked_issue_iid must match Fixes|Closes|Resolves #N, not a bare #N mention"
fi
if printf '%s' "$LINK_FN" | grep -Fq 're.search("#([0-9]+)", d)'; then
    fail "(#1514) no bare-#N fallback" "linked_issue_iid must NOT fall back to the first bare #N in the body"
else
    pass "(#1514) linked_issue_iid dropped the first-bare-#N-anywhere fallback"
fi
# Behavioural fixture: drive the exact resolution program the agent execs
# (kept byte-aligned with the .ag one-liner) across the pinned scenarios.
LINK_PY='import os, re
b=os.environ["B"]; d=os.environ["D"]
mb=re.search("issue-([0-9]+)", b)
mc=re.search(r"(?i)\b(?:clos(?:e|es|ed)|fix(?:|es|ed)|resolv(?:e|es|ed))\b\s*:?\s*#([0-9]+)", d)
print(mb.group(1) if mb else (mc.group(1) if mc else 0))'
link_iid() { B="$1" D="$2" python3 -c "$LINK_PY"; }
# PR #1513: context #1500 BEFORE the closing "Fixes #1512" -> must pick 1512.
BODY_1513='Bumps cb_budget 2000->3000. The #1500 plan-post pushed the draft tick over budget. Fixes #1512'
r_ctx="$(link_iid "" "$BODY_1513")"
r_none="$(link_iid "" 'caused by the #1500 plan-post; no closing keyword here')"
r_only="$(link_iid "" 'Closes #789')"
r_lc="$(link_iid "" 'resolves #42 finally')"
if [ "$r_ctx" = "1512" ]; then
    pass "(#1514) context mention #1500 before 'Fixes #1512' anchors on 1512 (the PR #1513 regression)"
else
    fail "(#1514) closing-keyword anchor" "expected 1512, got '$r_ctx'"
fi
if [ "$r_none" = "0" ]; then
    pass "(#1514) body with no closing keyword -> 0 (falls back to description-vs-diff semantics, not a guess)"
else
    fail "(#1514) no-closing fallback" "expected 0, got '$r_none'"
fi
if [ "$r_only" = "789" ] && [ "$r_lc" = "42" ]; then
    pass "(#1514) body with only a closing keyword resolves correctly (case-insensitive)"
else
    fail "(#1514) closing-only resolution" "expected 789/42, got '$r_only'/'$r_lc'"
fi
# The federation own-PR branch scheme still wins over the body.
if [ "$(link_iid 'fix/issue-1512' 'Fixes #1500')" = "1512" ]; then
    pass "(#1514) fix/issue-<n> source branch still wins over the body reference"
else
    fail "(#1514) branch precedence" "fix/issue-1512 branch must resolve to 1512"
fi
# Runtime-truth check: the fixtures above run a hand-kept COPY of the resolver
# one-liner, so they cannot catch a divergence between that copy and the string
# `qa_reviewer.ag` actually builds (shell_escape + the doubled-backslash regex
# through `exec sh`). Execute the REAL .ag `linked_issue_iid` via `agentis go`
# and assert the same anchors. Skipped when agentis is absent (CI runners).
if command -v agentis >/dev/null 2>&1; then
    AG_TMP="$(mktemp -d)"
    cat > "$AG_TMP/probe.ag" <<AGPROBE
$LINK_FN
let a = linked_issue_iid("sdlc/x", "context #1500 then Fixes #1512");
print("A=", a);
let b = linked_issue_iid("sdlc/x", "Implements #1512");
print("B=", b);
let c = linked_issue_iid("fix/issue-1512", "Fixes #1500");
print("C=", c);
AGPROBE
    (cd "$AG_TMP" && agentis init) >/dev/null 2>&1
    AG_OUT="$( (cd "$AG_TMP" && agentis go probe.ag --enable-exec) 2>/dev/null )"
    a_real="$(printf '%s\n' "$AG_OUT" | sed -n 's/^A= //p')"
    b_real="$(printf '%s\n' "$AG_OUT" | sed -n 's/^B= //p')"
    c_real="$(printf '%s\n' "$AG_OUT" | sed -n 's/^C= //p')"
    if [ "$a_real" = "1512" ] && [ "$b_real" = "0" ] && [ "$c_real" = "1512" ]; then
        pass "(#1514) the REAL .ag linked_issue_iid (agentis exec) anchors on the closing keyword, not a context #N"
    else
        fail "(#1514) real .ag resolver" "expected 1512/0/1512 from agentis exec, got '$a_real'/'$b_real'/'$c_real'"
    fi
    rm -rf "$AG_TMP"
else
    echo "[SKIP] (#1514) real .ag resolver — agentis not on PATH"
fi

# ---------------------------------------------------------------------------
# (c) Clean MR -> both pass (single header line, no reason lines)
# ---------------------------------------------------------------------------
if printf '%s' "$NOTE_FN" | grep -q '"QA verdict: completeness=" + v.completeness + ", description-vs-diff=" + v.description_vs_diff'; then
    pass "(c) fixed verdict header renders 'QA verdict: completeness=..., description-vs-diff=...'"
else
    fail "(c) verdict header" "verdict_note must render the structured one-line header"
fi
# Reason lines are guarded by == "fail" checks — a clean MR gets ONLY the header.
# Three dimensions after #1405: completeness, description-vs-diff, adversarial.
fail_guards="$(printf '%s' "$NOTE_FN" | grep -c '== "fail"')"
if [ "$fail_guards" -eq 3 ] \
   && printf '%s' "$NOTE_FN" | grep -q 'v.completeness == "fail"' \
   && printf '%s' "$NOTE_FN" | grep -q 'v.description_vs_diff == "fail"' \
   && printf '%s' "$NOTE_FN" | grep -q 'adv == "fail"'; then
    pass "(c) all three reason lines are gated on == \"fail\" — a clean MR posts the bare header"
else
    fail "(c) pass-path purity" "expected 3 fail-guards (completeness, description-vs-diff, adversarial), got $fail_guards"
fi

# ---------------------------------------------------------------------------
# (d) No repost on unchanged MR head
# ---------------------------------------------------------------------------
# Fixture: the agent fingerprints the mr-changes payload with the exact
# pipeline below. Same diff => same fingerprint (no repost); changed diff =>
# new fingerprint (fresh verdict). Run it twice on an identical fixture and
# once on a mutated one.
FP_PY='import sys, hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])'
FIX_CLEAN='{"changes": [{"old_path": "a.sh", "new_path": "a.sh", "diff": "@@ -1 +1 @@\n-old\n+new"}]}'
FIX_PUSHED='{"changes": [{"old_path": "a.sh", "new_path": "a.sh", "diff": "@@ -1 +1 @@\n-old\n+newer"}]}'
fp1="$(printf '%s' "$FIX_CLEAN" | python3 -c "$FP_PY")"
fp2="$(printf '%s' "$FIX_CLEAN" | python3 -c "$FP_PY")"
fp3="$(printf '%s' "$FIX_PUSHED" | python3 -c "$FP_PY")"
if [ -n "$fp1" ] && [ "$fp1" = "$fp2" ] && [ "$fp1" != "$fp3" ]; then
    pass "(d) head fingerprint fixture: stable on identical diff, changes on new push"
else
    fail "(d) fingerprint fixture" "fp1=$fp1 fp2=$fp2 fp3=$fp3"
fi
# The .ag hashes the diff with the native sha256_hex builtin (#1588 slice 3),
# value-identical to the FP_PY fixture above (both hash the UTF-8 bytes and
# hex-encode, no shell round-trip on the native side).
if grep -q 'substring(sha256_hex(changes_raw), 0, 16)' "$AG"; then
    pass "(d) agent fingerprints the diff with the native sha256_hex[:16] expression"
else
    fail "(d) fingerprint pipeline" "head_fingerprint must use substring(sha256_hex(changes_raw), 0, 16)"
fi
# Memo gate reads qa_reviewer:verdict_head:<iid> BEFORE prompt() in the same
# function (this recall_latest is also the check-prompt-gate.sh staleness gate).
gate_line="$(grep -n 'recall_latest(scoped_memo(owner, repo, "qa_reviewer:verdict_head:" + to_string(mr_iid)))' "$AG" | head -n1 | cut -d: -f1)"
prompt_line="$(grep -n 'let verdict = prompt(' "$AG" | head -n1 | cut -d: -f1)"
if [ -n "$gate_line" ] && [ -n "$prompt_line" ] && [ "$gate_line" -lt "$prompt_line" ]; then
    pass "(d) per-head memo gate (qa_reviewer:verdict_head:<iid>) precedes prompt() — no re-prompt on unchanged head"
else
    fail "(d) dedup gate before prompt" "gate_line=$gate_line prompt_line=$prompt_line"
fi
if [ -n "$gate_line" ] && sed -n "$((gate_line + 1)),$((gate_line + 3))p" "$AG" | grep -q 'return;'; then
    pass "(d) unchanged head returns before any LLM call or repost"
else
    fail "(d) early return" "the posted_head == head branch must return;"
fi
# Every tier branch writes the marker (autonomous, review-gated, propose,
# shadow/dormant) — the #1370 mark-at-every-tier pattern.
marker_writes="$(grep -c 'memo_write(scoped_memo(owner, repo, "qa_reviewer:verdict_head:" + to_string(mr_iid)), head)' "$AG")"
if [ "$marker_writes" -eq 4 ]; then
    pass "(d) all four tier branches write the per-head marker (#1370 pattern)"
else
    fail "(d) marker at every tier" "expected 4 marker writes, found $marker_writes"
fi
# On the posting tiers the marker is written only AFTER a successful post
# (inside `if len(result) > 0`) so a failed post retries next tick.
post_guarded="$(awk '/if len\(result\) > 0/{f=1} f && /memo_write\(scoped_memo\(owner, repo, "qa_reviewer:verdict_head:"/{c++} /};/{f=0} END{print c+0}' "$AG")"
if [ "$post_guarded" -ge 2 ]; then
    pass "(d) autonomous + review-gated markers are gated on a successful post (failed post retries)"
else
    fail "(d) post-success guard" "expected >=2 marker writes under 'if len(result) > 0', found $post_guarded"
fi

# ---------------------------------------------------------------------------
# Adversarial dimension (#1405, step 2 of #1359)
# ---------------------------------------------------------------------------
# (adv-a) refutable change -> adversarial=fail with a one-line reason.
# The prompt is framed to REFUTE (default-skeptical, not summarize) and marks a
# constructed concrete refutation as 'fail'; the note renderer appends the
# one-line reason ONLY on the adv == "fail" branch.
if printf '%s' "$ADV_PROMPT" | grep -q 'REFUTE' \
   && printf '%s' "$ADV_PROMPT" | grep -q 'Do NOT summarize' \
   && printf '%s' "$ADV_PROMPT" | grep -q 'breaks an adjacent consumer' \
   && printf '%s' "$ADV_PROMPT" | grep -q "'fail' when you constructed a concrete refutation"; then
    pass "(adv-a) adversarial prompt refutes (default-skeptical, not summarize); concrete refutation -> fail"
else
    fail "(adv-a) refute framing" "adversarial_instruction must be framed to REFUTE and fail on a concrete refutation"
fi
if printf '%s' "$ADV_PROMPT" | grep -q 'adversarial_reason'; then
    pass "(adv-a) prompt returns adversarial_reason naming the concrete input/state/sequence on fail"
else
    fail "(adv-a) reason field" "prompt must ask for a one-line adversarial_reason on fail"
fi
if printf '%s' "$NOTE_FN" | grep -q 'adv == "fail"' \
   && printf '%s' "$NOTE_FN" | grep -q 'adversarial: " + adv_reason'; then
    pass "(adv-a) note renderer appends the one-line adversarial reason on the fail branch"
else
    fail "(adv-a) fail-reason line" "verdict_note must append adv_reason when adversarial == fail"
fi

# (adv-b) sound change -> adversarial=pass. The prompt passes ONLY on a genuine
# failed refutation attempt, and adv_parse is TOTAL: an empty / junk / errored
# backend reply collapses to "pass" so a flaky or absent backend never emits a
# FALSE refutation (status normalised to exactly "fail" or "pass").
if printf '%s' "$ADV_PROMPT" | grep -q "'pass' ONLY when a genuine skeptical attempt found none"; then
    pass "(adv-b) prompt passes ONLY when a skeptical attempt found no refutation"
else
    fail "(adv-b) pass framing" "prompt must pass only when no concrete refutation was found"
fi
if printf '%s' "$ADV_PARSE" | grep -F -q 'catch e { "pass' \
   && printf '%s' "$ADV_PARSE" | grep -F -q 's=\"fail\" if s==\"fail\" else \"pass\"'; then
    pass "(adv-b) adv_parse is total: empty/junk/errored reply -> pass (never a false fail), status normalised"
else
    fail "(adv-b) total parse" "adv_parse must default to pass on any parse failure and normalise the status"
fi

# (adv-c) QA_ADVERSARIAL_LLM_CMD is honoured and exercised when set. When the
# env var is non-empty the refutation is piped through THAT command via exec sh;
# when unset it falls back to the colony default via prompt(). Either way the
# dimension is ALWAYS computed (qa_one_mr calls it unconditionally) — the env
# var only reroutes, never disables.
if printf '%s' "$ADV_REPLY" | grep -q 'getenv("QA_ADVERSARIAL_LLM_CMD")' \
   && printf '%s' "$ADV_REPLY" | grep -q 'len(alt_cmd) > 0' \
   && printf '%s' "$ADV_REPLY" | grep -q '" | " + alt_cmd' \
   && printf '%s' "$ADV_REPLY" | grep -q 'prompt(adversarial_instruction(), context)'; then
    pass "(adv-c) QA_ADVERSARIAL_LLM_CMD reroutes via exec sh when set, else falls back to prompt()"
else
    fail "(adv-c) backend override" "adversarial_reply must read QA_ADVERSARIAL_LLM_CMD and fall back to prompt()"
fi
if printf '%s' "$QA_ONE" | grep -q 'adv_parse(adversarial_reply(context))'; then
    pass "(adv-c) adversarial dimension is always computed (env var absence never disables it)"
else
    fail "(adv-c) always computed" "qa_one_mr must call adv_parse(adversarial_reply(context)) unconditionally"
fi
# Behavioural fixture: exercise the override dispatch shape end-to-end. A fake
# backend (standing in for QA_ADVERSARIAL_LLM_CMD) that emits a fence/prose-
# wrapped refutation JSON, driven through the exact `printf '%s' <prompt> | <cmd>`
# pipeline the override branch execs, then through the SAME adv_parse python
# program the agent runs, must yield fail + a non-empty reason.
FAKE_BACKEND="$(mktemp)"
cat > "$FAKE_BACKEND" <<'FAKEEOF'
#!/usr/bin/env bash
# Ignores stdin; emits a fixed refutation like an alternative LLM backend would,
# deliberately wrapped in prose + a fenced block to exercise adv_parse's
# brace-slice extraction.
cat <<'JSON'
Sure -- here is my adversarial verdict:
```json
{"adversarial": "fail", "adversarial_reason": "empty changes list makes reduce() raise on the first tick"}
```
JSON
FAKEEOF
chmod +x "$FAKE_BACKEND"
# The exact parser program from adv_parse() in the .ag (kept byte-aligned).
ADV_PARSE_PY='import os,json
r=os.environ["R"]
i=r.find("{"); j=r.rfind("}")
try:
    d=json.loads(r[i:j+1]) if i>=0 and j>i else {}
except Exception:
    d={}
s=str(d.get("adversarial","")).strip().lower()
s="fail" if s=="fail" else "pass"
print(s+chr(9)+str(d.get("adversarial_reason","")).replace(chr(10)," ").strip())'
adv_reply_fx="$(printf '%s' "REFUTE THIS CHANGE" | "$FAKE_BACKEND")"
adv_line_fx="$(R="$adv_reply_fx" python3 -c "$ADV_PARSE_PY")"
adv_status_fx="$(printf '%s' "$adv_line_fx" | cut -f1)"
adv_reason_fx="$(printf '%s' "$adv_line_fx" | cut -f2)"
if [ "$adv_status_fx" = "fail" ] && [ -n "$adv_reason_fx" ]; then
    pass "(adv-c) override backend dispatch + adv_parse: fence/prose-wrapped refutation -> fail with reason"
else
    fail "(adv-c) override fixture" "status=$adv_status_fx reason=$adv_reason_fx"
fi
# Same parser on an empty backend reply collapses to pass (total-on-failure).
adv_empty_fx="$(R="" python3 -c "$ADV_PARSE_PY")"
if [ "$(printf '%s' "$adv_empty_fx" | cut -f1)" = "pass" ]; then
    pass "(adv-c) adv_parse fixture: empty backend reply -> pass (flaky/absent backend never false-fails)"
else
    fail "(adv-c) empty-reply fixture" "empty reply did not collapse to pass: $adv_empty_fx"
fi
rm -f "$FAKE_BACKEND"

# (adv-d) the posted verdict note carries ALL THREE dimensions on one header
# line, and qa_one_mr threads the adversarial status + reason into verdict_note.
header_line="$(printf '%s' "$NOTE_FN" | grep 'QA verdict: completeness=')"
if printf '%s' "$header_line" | grep -q 'completeness=" + v.completeness' \
   && printf '%s' "$header_line" | grep -q 'description-vs-diff=" + v.description_vs_diff' \
   && printf '%s' "$header_line" | grep -q 'adversarial=" + adv'; then
    pass "(adv-d) the single verdict header line carries completeness, description-vs-diff AND adversarial"
else
    fail "(adv-d) three-dimension header" "verdict_note header must render all three dimensions"
fi
if printf '%s' "$QA_ONE" | grep -q 'verdict_note(verdict, adv_status, adv_reason)' \
   && printf '%s' "$QA_ONE" | grep -q 'repo_field(adv_line, 0)' \
   && printf '%s' "$QA_ONE" | grep -q 'repo_field(adv_line, 1)'; then
    pass "(adv-d) qa_one_mr threads the adversarial status/reason into the verdict note"
else
    fail "(adv-d) note threading" "qa_one_mr must pass adv_status/adv_reason into verdict_note"
fi

# ---------------------------------------------------------------------------
# Commit-keyed verdict marker for the #1484 merge gate
# ---------------------------------------------------------------------------
# qa_reviewer makes its verdict machine-readable for approval_decider (a
# DIFFERENT agent that cannot read this agent's memos) by appending a hidden,
# commit-keyed marker to the note it already posts — read off the durable
# mr-notes payload by the merge gate.
VERDICT_STATUS_FN="$(awk '/^fn verdict_status\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
QA_MARKER_FN="$(awk '/^fn qa_marker\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"

# The two helper functions exist.
if grep -q '^fn verdict_status(v: QaVerdict, adv: string) -> string {' "$AG" \
   && grep -q '^fn qa_marker(head: string, status: string) -> string {' "$AG"; then
    pass "(#1484) verdict_status() and qa_marker() helpers exist"
else
    fail "(#1484) marker helpers" "verdict_status() and qa_marker() must both be defined"
fi
# status=block derives from ANY failed dimension (completeness OR
# description-vs-diff OR adversarial). `.ag` has no `||`, so the disjunction is
# three nested `if`s that each return "block", with a final fall-through "pass".
block_guards="$(printf '%s' "$VERDICT_STATUS_FN" | grep -c 'return "block";')"
if [ "$block_guards" -eq 3 ] \
   && printf '%s' "$VERDICT_STATUS_FN" | grep -q 'v.completeness == "fail"' \
   && printf '%s' "$VERDICT_STATUS_FN" | grep -q 'v.description_vs_diff == "fail"' \
   && printf '%s' "$VERDICT_STATUS_FN" | grep -q 'adv == "fail"' \
   && printf '%s' "$VERDICT_STATUS_FN" | grep -q 'return "pass";'; then
    pass "(#1484) verdict_status blocks on ANY failed dimension, else pass (3 block guards + pass fallthrough)"
else
    fail "(#1484) block derivation" "expected 3 'block' returns gated on each dimension + a 'pass' fallthrough, got $block_guards block returns"
fi
# qa_marker renders the exact hidden marker the gate greps for.
if printf '%s' "$QA_MARKER_FN" | grep -qF '"\n\n<!-- qa-verdict head=" + head + " status=" + status + " -->"'; then
    pass "(#1484) qa_marker renders '<!-- qa-verdict head=<fp> status=<s> -->' (the gate's grep anchor)"
else
    fail "(#1484) marker format" "qa_marker must render the commit-keyed HTML-comment marker"
fi
# The marker is appended to the posted note body in BOTH post branches
# (autonomous + review-gated) — keyed to the SAME head fingerprint the dedup
# gate uses and derived from the SAME verdict + adversarial status.
marker_appends="$(grep -c 'qa_marker(head, verdict_status(verdict, adv_status))' "$AG")"
if [ "$marker_appends" -eq 2 ]; then
    pass "(#1484) the commit-keyed marker is appended in BOTH post branches (autonomous + review-gated)"
else
    fail "(#1484) marker in both branches" "expected 2 qa_marker(head, verdict_status(...)) appends, found $marker_appends"
fi
# It rides the same head_fingerprint(...) value (`head`) the dedup gate keys on,
# so a force-push changes the marker's head and the gate treats it as stale.
if grep -q '"\*\*QA Verdict\*\* (automated)\\n\\n" + note + qa_marker(head,' "$AG"; then
    pass "(#1484) autonomous note appends the marker AFTER the human-readable verdict note"
else
    fail "(#1484) autonomous marker placement" "the autonomous comment must be note + qa_marker(head, ...)"
fi

# ---------------------------------------------------------------------------
# Tier semantics + federation lint contracts
# ---------------------------------------------------------------------------
if printf '%s' "$QA_ONE" | grep -q 'repo_tier("qa_reviewer", owner, repo)' \
   && printf '%s' "$QA_ONE" | grep -q 'if my_tier == "autonomous"' \
   && printf '%s' "$QA_ONE" | grep -q 'if my_tier == "review-gated"' \
   && printf '%s' "$QA_ONE" | grep -q 'if my_tier == "propose"'; then
    pass "tier gating via repo_tier() with autonomous/review-gated/propose branches + shadow fallthrough"
else
    fail "tier gating" "qa_one_mr must branch on repo_tier(\"qa_reviewer\", ...) per ADR-0001"
fi
# The bus verdict is emitted at propose and above (extension point for #1359 step 3).
emits="$(printf '%s' "$QA_ONE" | grep -c 'emit("review:qa_verdict", verdict)')"
if [ "$emits" -eq 3 ]; then
    pass "review:qa_verdict emitted at propose, review-gated, and autonomous (not at shadow)"
else
    fail "bus emit" "expected 3 emit(\"review:qa_verdict\") sites, found $emits"
fi
# The autonomous note is the structured verdict, posted via the forge post-note verb.
if printf '%s' "$QA_ONE" | grep -q '"\*\*QA Verdict\*\* (automated)' \
   && printf '%s' "$QA_ONE" | grep -q 'forge-api.sh post-note " + to_string(mr_iid) + " --body " + shell_escape(comment)'; then
    pass "autonomous tier posts the verdict note via post-note with a shell_escape'd body"
else
    fail "autonomous post" "autonomous branch must post-note the QA Verdict comment"
fi
if printf '%s' "$QA_ONE" | grep -q '\[draft-review\] \*\*QA Verdict\*\* (automated, pending approval)'; then
    pass "review-gated tier posts the draft-flagged variant"
else
    fail "review-gated draft" "review-gated branch must draft-flag the note"
fi
# learn() topic matches recommend() topic (check-learn-recommend-topic-match.sh).
if printf '%s' "$QA_ONE" | grep -q 'recommend("qa_review"' \
   && ! printf '%s' "$QA_ONE" | grep 'learn(' | grep -v 'learn("qa_review"' | grep -q 'learn('; then
    pass "learn()/recommend() topics both 'qa_review'"
else
    fail "topic match" "every learn() must use the recommend() topic qa_review"
fi
# Draft MRs are skipped (reviewer-view draft flag).
if printf '%s' "$QA_ONE" | grep -q '.draft' && printf '%s' "$QA_ONE" | grep -q 'is_draft == "true"'; then
    pass "draft MRs are skipped"
else
    fail "draft skip" "qa_one_mr must skip draft == true MRs"
fi
# exec-sh safety pragmas on the concat-built commands.
for needle in 'forge-api.sh mr-changes ' 'forge-api.sh get-issue ' 'forge-api.sh post-note ' 'forge-api.sh merge-requests --view reviewer'; do
    if grep -B1 -- "$needle" "$AG" | grep -q 'colony-lint: safe-exec-concat'; then
        pass "safe-exec-concat pragma on '$needle' command build"
    else
        fail "exec-sh pragma" "missing safe-exec-concat pragma above the '$needle' line"
    fi
done
# last_check memo written at end of tick (script convention).
if grep -q 'memo_write(scoped_memo(owner, repo, "qa_reviewer:last_check"), now)' "$AG"; then
    pass "qa_reviewer:last_check memo written at end of tick"
else
    fail "last_check memo" "tick must refresh qa_reviewer:last_check"
fi

# ---------------------------------------------------------------------------
# Registration parity with test_reviewer
# ---------------------------------------------------------------------------
if awk '/name = "qa_reviewer"/{f=1} f && /source = "agents\/qa_reviewer.ag"/{print "ok"; exit}' "$COLONY/config/colony.example.toml" | grep -q ok; then
    pass "registered in colony.example.toml ([[agents]] qa_reviewer -> agents/qa_reviewer.ag)"
else
    fail "colony.example.toml registration" "missing [[agents]] block for qa_reviewer"
fi
# cb <N>; in the .ag must match cb_budget in the example config (CLAUDE.md rule).
ag_cb="$(sed -n 's/^cb \([0-9]*\);$/\1/p' "$AG" | head -n1)"
cfg_cb="$(awk '/name = "qa_reviewer"/{f=1} f && /cb_budget/{gsub(/[^0-9]/,""); print; exit}' "$COLONY/config/colony.example.toml")"
if [ -n "$ag_cb" ] && [ "$ag_cb" = "$cfg_cb" ]; then
    pass "cb $ag_cb; in qa_reviewer.ag matches cb_budget = $cfg_cb in colony.example.toml"
else
    fail "cb budget match" "ag=$ag_cb config=$cfg_cb"
fi
SC="$COLONY/scripts/start-colony.sh"
if awk '/^AGENTS=\(/,/^\)/' "$SC" | grep -q 'qa_reviewer'; then
    pass "start-colony.sh AGENTS array includes qa_reviewer"
else
    fail "start-colony.sh AGENTS" "qa_reviewer missing from the AGENTS array"
fi
if awk '/tick_interval_for\(\)/,/^}/' "$SC" | grep 'qa_reviewer' | grep -q '300000'; then
    pass "start-colony.sh tick_interval_for() puts qa_reviewer on the 300000ms reviewer cadence"
else
    fail "tick interval" "qa_reviewer must share the reviewers' 300000ms case arm"
fi
if grep -q 'test_reviewer qa_reviewer approval_decider' "$REPO_ROOT/dev-apprenticeship/install.sh"; then
    pass "install.sh ALL_AGENTS enumerates qa_reviewer (code-review line)"
else
    fail "install.sh ALL_AGENTS" "qa_reviewer missing from the code-review agent enumeration"
fi
if grep -q 'agents/qa_reviewer.ag' "$COLONY/README.md" && grep -q 'QA verdict: completeness=' "$COLONY/README.md"; then
    pass "colony README documents the agent and the verdict-note format"
else
    fail "README documentation" "code-review/README.md must document qa_reviewer + the note format"
fi

# ---------------------------------------------------------------------------
# Parse check (same as the per-agent syntax pass in colony-lint.sh). Skipped
# (not failed) when agentis is not installed.
# ---------------------------------------------------------------------------
if command -v agentis >/dev/null 2>&1; then
    LINT_TMP="$(mktemp -d)"
    (cd "$LINT_TMP" && agentis init) >/dev/null 2>&1
    if (cd "$LINT_TMP" && agentis commit "$AG") >/dev/null 2>&1; then
        pass "qa_reviewer.ag parses (agentis commit)"
    else
        fail "qa_reviewer.ag parses (agentis commit)" "syntax error in qa_reviewer.ag"
    fi
    rm -rf "$LINT_TMP"
else
    echo "[SKIP] agentis not on PATH — skipping .ag parse check"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
