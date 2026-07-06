#!/bin/bash
# tools/test-bm25-recall-gates.sh: source-asserts the #1429 Stage 1b BM25
# recall wiring in the triage crystallizer pilots (labeler + router).
#
# The BM25 recall path has four load-bearing properties that a refactor
# could silently regress without any runtime error on a quiet project:
#   1. crystallizer_search is knob-guarded (<AGENT>_BM25_RECALL) and
#      subordinate to <AGENT>_RULE_FIRST (the one rollback switch), and
#      wrapped in try/catch so a pre-v1.20.0 host degrades to the LLM
#      path instead of erroring the tick.
#   2. Every BM25 candidate is CLASS-CONFIRMED through the class-scoped,
#      confidence-gated point lookup before firing (bm25_pick_at calls
#      crystallizer_lookup_with_confidence) — crystallizer_search ranks
#      the whole pool across action types and its JSON carries no
#      expected_outcome, so firing an unconfirmed candidate could replay
#      another agent's rule.
#   3. Both fire paths (Stage 1 "prefix-hit", Stage 1b "bm25-hit") go
#      through the shared fire_<agent>_rule helper and `return` before the
#      decide prompt(); the hit_kind discriminator is tagged IN ADDITION
#      to "rule-hit" so the auto-promote efficiency bonus (#823) counts
#      both replay paths.
#   4. The RAG fallback grounds the decide prompt (grounded_context) and
#      every knob is on the install.sh exec.env_passthrough allowlist
#      (getenv() reads the SANITIZED env — an unregistered knob is
#      silently inert, #1426/#1428).
#
# Usage: ./tools/test-bm25-recall-gates.sh
# Exit code 0 if all assertions pass, 1 otherwise.

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FED="$REPO_ROOT/dev-apprenticeship"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

assert_grep() {
    local file="$1" pattern="$2" desc="$3"
    if grep -qF "$pattern" "$file"; then
        pass "$desc"
    else
        fail "$desc — pattern not found: $pattern"
    fi
}

assert_count() {
    local file="$1" pattern="$2" expected="$3" desc="$4"
    local got
    got=$(grep -cF "$pattern" "$file" || true)
    if [ "$got" -eq "$expected" ]; then
        pass "$desc"
    else
        fail "$desc — expected $expected occurrences of '$pattern', got $got"
    fi
}

check_agent() {
    local agent="$1" file="$2" knob="$3" fire_fn="$4"

    # 1. Knob-guarded, rule-first-subordinate, try/catch-degradable search.
    assert_grep "$file" "getenv(\"$knob\")" "$agent: reads $knob knob"
    assert_grep "$file" 'getenv("TRIAGE_BM25_K")' "$agent: reads TRIAGE_BM25_K knob"
    assert_grep "$file" 'if rule_first_enabled { bm25_flag != "0"; } else { false; }' \
        "$agent: BM25 recall is subordinate to the RULE_FIRST rollback switch"
    assert_grep "$file" 'try { crystallizer_search(bm25_query, bm25_k); } catch e { []; }' \
        "$agent: crystallizer_search is try/catch-wrapped (pre-v1.20.0 host degrades)"

    # 2. Class confirmation before firing.
    assert_grep "$file" 'fn bm25_pick_at(action_type: string, cands: list<string>, pos: int, min_conf: float) -> string' \
        "$agent: bm25_pick_at helper present"
    assert_grep "$file" 'let confirmed = crystallizer_lookup_with_confidence(action_type, cond, min_conf);' \
        "$agent: candidates are class-confirmed via the confidence-gated point lookup"

    # 3. Shared fire helper on both stages, return-before-prompt, hit_kind tags.
    assert_grep "$file" "$fire_fn" "$agent: shared fire helper present"
    assert_grep "$file" '"prefix-hit", cur_hash' "$agent: Stage 1 fires with hit_kind=prefix-hit"
    assert_grep "$file" '"bm25-hit", cur_hash' "$agent: Stage 1b fires with hit_kind=bm25-hit"
    assert_count "$file" '"rule-hit", hit_kind, "distilled"' 8 \
        "$agent: all 8 rule-hit learn rows carry rule-hit + hit_kind + distilled"

    # 4. RAG fallback grounds the decide prompt.
    assert_grep "$file" 'let rag_block = bm25_grounding_at(bm25_cands, 0, "");' \
        "$agent: RAG grounding block built from BM25 candidates"
    assert_grep "$file" 'grounded_context' "$agent: decide prompt consumes grounded_context"
}

check_agent "labeler" "$FED/triage/agents/labeler.ag" "LABELER_BM25_RECALL" \
    'fn fire_label_rule(owner: string, repo: string, my_tier: string, issue_id: int, author: string, rule_id: string, rule_action: string, rule_conf_str: string, hit_ctx: string, hit_kind: string, cur_hash: string) -> string'
check_agent "router" "$FED/triage/agents/router.ag" "ROUTER_BM25_RECALL" \
    'fn fire_route_rule(owner: string, repo: string, my_tier: string, issue_id: int, rule_id: string, rule_action: string, rule_conf_str: string, hit_ctx: string, hit_kind: string, cur_hash: string) -> string'
check_agent "prioritizer" "$FED/triage/agents/prioritizer.ag" "PRIORITIZER_BM25_RECALL" \
    'fn fire_priority_rule(owner: string, repo: string, my_tier: string, issue_id: int, rule_id: string, rule_action: string, rule_conf_str: string, hit_ctx: string, hit_kind: string, cur_hash: string) -> string'

# #1430: the prioritizer autonomous rule-hit branch must NOT record a
# single-slot verdict — the agent just wrote the label, so the next tick's
# reality-check would read it back as signal 1 (self-fulfilling
# reinforcement, not an operator signal). Assert the recorder appears
# exactly twice (review-gated + propose branches only).
PRI_AG="$FED/triage/agents/prioritizer.ag"
PRI_RECORDS=$(grep -cF 'record_priority_verdict(owner, repo, issue_id, priority, rule_id);' "$PRI_AG" || true)
if [ "$PRI_RECORDS" -eq 2 ]; then
    pass "prioritizer: rule-hit verdict recorded only at review-gated + propose (not autonomous)"
else
    fail "prioritizer: expected exactly 2 rule-hit verdict recordings (review-gated + propose), got $PRI_RECORDS"
fi

# Allowlist: every getenv-read knob of the pilot + Stage 1b must be on the
# install.sh exec.env_passthrough default (fresh install) literal.
for var in LABELER_RULE_FIRST LABELER_RULE_CONFIDENCE ROUTER_RULE_FIRST \
           ROUTER_RULE_CONFIDENCE LABELER_BM25_RECALL ROUTER_BM25_RECALL \
           TRIAGE_BM25_K PRIORITIZER_RULE_FIRST PRIORITIZER_RULE_CONFIDENCE \
           PRIORITIZER_BM25_RECALL; do
    if grep "^    write_key 'exec.env_passthrough'" "$FED/install.sh" | grep -q "$var"; then
        pass "install.sh: $var on the exec.env_passthrough fresh-install default"
    else
        fail "install.sh: $var missing from the exec.env_passthrough fresh-install default"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
