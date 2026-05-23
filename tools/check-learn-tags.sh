#!/bin/bash
# tools/check-learn-tags.sh: Validate `learn()` tag streams in tribes-bench
# hunter agents against a per-call-site schema (#492).
#
# Background — Loose category (b)
# ===============================
# `tribes-bench/` fitness aggregation reads free-form `learn()` tags as
# authoritative. The auto-promote / selection-fitness path classifies
# experience rows by tag (`acted`, `replicated`, `false-positive`,
# `reward=<int>`, ...). Once Stage 4 lineage variation lands, an evolved
# hunter could emit `learn("hunt", ..., "success", ["acted", "reward=999"])`
# without producing a verified finding and harvest selection reward.
#
# This is a **static lint-time** guardrail. For every literal tag list
# present in `tribes-bench/tribe-*/agents/hunter.ag`, every tag must be
# in the allowlist for the (topic, outcome) pair it belongs to. Unknown
# (topic, outcome) pairs always FAIL — adding a new call site forces an
# explicit schema update in this file.
#
# Known gap — dynamic tag evasion
# -------------------------------
# A tag list built from a variable or with `+`-concatenation cannot be
# proven correct statically. The default mode WARNs on every such call
# site (no failure); set `COLONY_LINT_STRICT_LEARN_TAGS=1` to upgrade to
# a hard FAIL. A core-side runtime validator is the long-term fix
# (follow-up to #492).
#
# Suppression
# -----------
# Add `// colony-lint: learn-tags-ok` on the `learn(` line itself or on
# the immediately preceding line to silence a specific intentional
# violation (e.g. a deliberate experimental tag during development).
#
# Usage: ./tools/check-learn-tags.sh [path]
# Exit 0 on clean, 2 on schema violations, 3 on usage error.

set -euo pipefail

SCAN_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ ! -e "$SCAN_ROOT" ]; then
    echo "check-learn-tags: scan root does not exist: $SCAN_ROOT" >&2
    exit 3
fi

STRICT="${COLONY_LINT_STRICT_LEARN_TAGS:-0}"

FAIL=0
WARN=0

# Per (topic, outcome) literal-tag allowlist + parametric-tag patterns.
# `<tn>` denotes a tribe-name placeholder accepted as either the literal
# `tribe-{alpha,beta,gamma,delta,epsilon}` or the bareword `_tribe_name`
# variable reference.
#
# Schema is derived from `grep -hn 'learn(' tribes-bench/tribe-*/agents/hunter.ag`
# as of #492 (19 call sites per hunter, identical across 5 tribes).
#
# An unknown (topic, outcome) pair is a hard schema violation. New call
# sites MUST update this table.
check_pair_schema() {
    # Inputs: $1 = topic, $2 = outcome
    # Sets globals: ALLOWED_LITERALS (newline-separated), ALLOWED_PARAMS,
    #   PAIR_KNOWN (0/1).
    ALLOWED_LITERALS=""
    ALLOWED_PARAMS=""
    PAIR_KNOWN=0

    case "$1:$2" in
        "hunt:success")
            ALLOWED_LITERALS="acted
tribes-bench
<tn>"
            ALLOWED_PARAMS="reward=<int>"
            PAIR_KNOWN=1
            ;;
        "hunt:partial")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
tribes-bench"
            PAIR_KNOWN=1
            ;;
        "hunt:failure")
            ALLOWED_LITERALS="false-positive
tribes-bench"
            PAIR_KNOWN=1
            ;;
        "replicate:success")
            # Shared between tribes-bench hunters, math-foundry
            # explorer (#622 PR-3), and Phase 9 PR-C (#663) where the
            # remaining 17 research-foundry colonies light up the same
            # M2-Malthusian replicate path. The federation-name
            # literals (`tribes-bench` / `math-foundry` /
            # `claim-auditor` / `preprint-foundry`) disambiguate the
            # call site at lint time.
            ALLOWED_LITERALS="replicated
tribes-bench
math-foundry
claim-auditor
preprint-foundry
<tn>
<cn>"
            PAIR_KNOWN=1
            ;;
        "replicate:failure")
            # Shared between tribes-bench hunters, math-foundry
            # explorer (#622 PR-3), and Phase 9 PR-C (#663) audit /
            # preprint colonies.
            ALLOWED_LITERALS="replicate-skip
replicate-error
replicate-nak
tribes-bench
math-foundry
claim-auditor
preprint-foundry
<tn>
<cn>"
            PAIR_KNOWN=1
            ;;
        "reproductive_replicate:success")
            ALLOWED_LITERALS="replicated
reproductive
tribes-bench
<tn>"
            PAIR_KNOWN=1
            ;;
        "self_death:failure")
            ALLOWED_LITERALS="died
self-aged
tribes-bench
<tn>"
            PAIR_KNOWN=1
            ;;
        "selection_death:failure")
            ALLOWED_LITERALS="died
low-fitness
tribes-bench
<tn>"
            PAIR_KNOWN=1
            ;;
        "death:failure")
            ALLOWED_LITERALS="died
tribes-bench
<tn>"
            PAIR_KNOWN=1
            ;;
        "knowledge_sell:failure")
            # Shared between tribes-bench hunters and research-foundry
            # novelty (#741). novelty.ag's knowledge market sells two
            # topic kinds (`permutation_order_facts:<topic>` on
            # NOVEL/BORDERLINE, `known_priors:<topic>` on NOT_NOVEL with
            # non-empty classical_identifier) and emits this learn() row
            # only on sell failure, mirroring hunter.ag::L1335.
            ALLOWED_LITERALS="sell-failed
tribes-bench
math-foundry"
            PAIR_KNOWN=1
            ;;
        "market:cache_hit")
            # Shared between tribes-bench hunters and research-foundry
            # buyers (#741). explorer.ag buys
            # `permutation_order_facts:<topic>` (cb=5) and
            # prior_advocate.ag buys `known_priors:<topic>` (cb=2);
            # both emit this learn() row on cognitive.cache_hit.
            ALLOWED_LITERALS="tribes-bench
math-foundry
claim-auditor"
            ALLOWED_PARAMS="buyer:<tn>
buyer:explorer
buyer:prior_advocate
topic_kind:finding
topic_kind:bundle
topic_kind:permutation_order_facts
topic_kind:known_priors"
            PAIR_KNOWN=1
            ;;
        "market:rejected")
            # #493 Loose category (c): consumer-side knowledge_sell validation
            # rejects answers whose claimed bug_id is not in the seller's
            # verifier-stamped bug-ledger.jsonl. Emits this learn() with
            # reason:unverifiable so downstream telemetry can distinguish
            # rejections from cache hits.
            #
            # research-foundry (#741): explorer.ag + prior_advocate.ag
            # emit on `cognitive.rejected` from the knowledge_buy
            # lifecycle stream. Federation literal disambiguates the
            # call site at lint time.
            ALLOWED_LITERALS="tribes-bench
math-foundry
claim-auditor"
            ALLOWED_PARAMS="buyer:<tn>
buyer:explorer
buyer:prior_advocate
topic_kind:finding
topic_kind:bundle
topic_kind:permutation_order_facts
topic_kind:known_priors
reason:unverifiable"
            PAIR_KNOWN=1
            ;;
        "hunter_prompt_evolve:partial")
            # #520 M98 v3 PR 2/3: emitted when the evolution path runs but
            # the new prompt body is not committed. Two sub-cases:
            # no-op (Levenshtein floor rejected the rewrite as
            # too similar to the prior prompt) and lineage-reset
            # (generation cap reached; hunting prompt reset to the
            # tribe's seed and lineage_id bumped).
            ALLOWED_LITERALS="prompt-evolution
no-op
lineage-reset
tribes-bench"
            PAIR_KNOWN=1
            ;;
        "hunter_prompt_evolve:failure")
            # #520 M98 v3 PR 2/3: schema-sanity ping rejected the
            # candidate prompt. Colony reverts to prior working prompt;
            # generation not bumped.
            ALLOWED_LITERALS="prompt-evolution
schema-revert
tribes-bench"
            PAIR_KNOWN=1
            ;;
        "hunter_prompt_evolve:success")
            # #520 M98 v3 PR 2/3: rewrite passed all guards (length,
            # Levenshtein floor, schema-sanity); the new prompt is now
            # the active hunting prompt and generation is incremented.
            ALLOWED_LITERALS="prompt-evolution
rewritten
tribes-bench"
            PAIR_KNOWN=1
            ;;
        "hunter_prompt_inherit:success")
            # #520 M98 v3 PR 3/3: child's first-tick bootstrap found a
            # valid `pp:<sha>` prefix in its variant_tag AND the body
            # memo at `hunter:prompt_body:<sha>` was populated. The
            # parent's evolved prompt is now this child's hunting
            # prompt; generation reset to "0" for a fresh K-window.
            ALLOWED_LITERALS="prompt-inheritance
adopted
tribes-bench"
            PAIR_KNOWN=1
            ;;
        "hunter_prompt_inherit:failure")
            # #520 M98 v3 PR 3/3: child's first-tick bootstrap saw a
            # `pp:<sha>` prefix but the body memo at
            # `hunter:prompt_body:<sha>` was empty (cache miss / race
            # / content-addressed write hadn't propagated). Falls
            # through to seed; emitted so `analyse-stage3.py` can
            # surface inheritance misses without scraping logs.
            ALLOWED_LITERALS="prompt-inheritance
miss
tribes-bench"
            PAIR_KNOWN=1
            ;;

        # ----------------------------------------------------------------
        # math-foundry research federation (#622 PR-3)
        # ----------------------------------------------------------------
        # `<cn>` placeholder: math-foundry colony-name (literal one of
        # explorer|formulator|noticer|novelty|verifier) or the bareword
        # `_colony_name` variable reference. `verdict:<verdict>` allows
        # the four ACCEPT-side verdict_raw literals (NOVEL, BORDERLINE,
        # NOT_NOVEL, REJECT) and the parametric `verdict:` + bareword
        # shape used at the call site.
        "explore:partial")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
math-foundry"
            PAIR_KNOWN=1
            ;;
        # #740: AdaptiveEngine activation in research-foundry/explorer.
        # The explorer emits `learn("topic_selection", topic_label, ...,
        # outcome, [tier, "math-foundry"])` alongside the existing
        # `explore:*` rows so the AdaptiveEngine can rank topics by
        # the `novelty` fitness signal.
        "topic_selection:success")
            ALLOWED_LITERALS="acted
math-foundry"
            PAIR_KNOWN=1
            ;;
        "topic_selection:partial")
            ALLOWED_LITERALS="review-gated
emitted
observed
math-foundry"
            PAIR_KNOWN=1
            ;;
        "settle:success")
            ALLOWED_LITERALS="acted
math-foundry
<cn>"
            ALLOWED_PARAMS="verdict:<verdict>"
            PAIR_KNOWN=1
            ;;
        # NOTE: `replicate:success` and `replicate:failure` are shared
        # between tribes-bench hunters and math-foundry explorer; see
        # the tribes-bench entries above (case statement merges both).
        "explorer_prompt_evolve:partial")
            # Mirrors tribes-bench hunter_prompt_evolve:partial.
            ALLOWED_LITERALS="prompt-evolution
no-op
lineage-reset
math-foundry"
            PAIR_KNOWN=1
            ;;
        "explorer_prompt_evolve:failure")
            # Mirrors tribes-bench hunter_prompt_evolve:failure.
            ALLOWED_LITERALS="prompt-evolution
schema-revert
math-foundry"
            PAIR_KNOWN=1
            ;;
        "explorer_prompt_evolve:success")
            # Mirrors tribes-bench hunter_prompt_evolve:success.
            ALLOWED_LITERALS="prompt-evolution
rewritten
math-foundry"
            PAIR_KNOWN=1
            ;;
        "explorer_prompt_inherit:success")
            # Mirrors tribes-bench hunter_prompt_inherit:success.
            ALLOWED_LITERALS="prompt-inheritance
adopted
math-foundry"
            PAIR_KNOWN=1
            ;;
        "explorer_prompt_inherit:failure")
            # Mirrors tribes-bench hunter_prompt_inherit:failure.
            ALLOWED_LITERALS="prompt-inheritance
miss
math-foundry"
            PAIR_KNOWN=1
            ;;
        "explorer_prompt_inherit:partial")
            # Reserved for future parity with tribes-bench
            # hunter_prompt_inherit:partial (no current emit site).
            ALLOWED_LITERALS="prompt-inheritance
math-foundry"
            PAIR_KNOWN=1
            ;;
        "formulate:partial")
            ALLOWED_LITERALS="acted
review-gated
observed
math-foundry"
            PAIR_KNOWN=1
            ;;
        "formulate:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
math-foundry"
            PAIR_KNOWN=1
            ;;
        "notice:partial")
            ALLOWED_LITERALS="acted
review-gated
observed
math-foundry"
            PAIR_KNOWN=1
            ;;
        "notice:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
math-foundry"
            PAIR_KNOWN=1
            ;;
        "novelty:partial")
            ALLOWED_LITERALS="acted
review-gated
observed
math-foundry"
            PAIR_KNOWN=1
            ;;
        "novelty:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
math-foundry"
            PAIR_KNOWN=1
            ;;
        "verify:partial")
            ALLOWED_LITERALS="acted
review-gated
observed
math-foundry"
            PAIR_KNOWN=1
            ;;
        "verify:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
math-foundry"
            PAIR_KNOWN=1
            ;;
        "verify:failure")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
math-foundry"
            PAIR_KNOWN=1
            ;;
        "skeptic_dismiss:partial")
            # Phase 4 PR-A (#625): skeptic gates the formulator on the
            # noticer's surprise. `partial` outcome covers `upheld` and
            # `unsure` verdicts (noticer's surprise resists or cannot
            # be ruled out as a classical match).
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
math-foundry"
            PAIR_KNOWN=1
            ;;
        "skeptic_dismiss:success")
            # Phase 4 PR-A (#625): skeptic gates the formulator on the
            # noticer's surprise. `success` outcome covers the
            # `dismissed` verdict (skeptic matched the surprise to a
            # classical result, blocking the formulator).
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
math-foundry"
            PAIR_KNOWN=1
            ;;

        # ----------------------------------------------------------------
        # claim-auditor research federation (#622 PR-3)
        # ----------------------------------------------------------------
        "arxiv-search:partial")
            ALLOWED_LITERALS="acted
review-gated
observed
claim-auditor"
            PAIR_KNOWN=1
            ;;
        "arxiv-search:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
claim-auditor"
            PAIR_KNOWN=1
            ;;
        "oeis-search:partial")
            ALLOWED_LITERALS="acted
review-gated
observed
claim-auditor"
            PAIR_KNOWN=1
            ;;
        "oeis-search:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
claim-auditor"
            PAIR_KNOWN=1
            ;;
        "groupprops-search:partial")
            ALLOWED_LITERALS="acted
review-gated
observed
claim-auditor"
            PAIR_KNOWN=1
            ;;
        "groupprops-search:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
claim-auditor"
            PAIR_KNOWN=1
            ;;
        "scholar-search:partial")
            ALLOWED_LITERALS="acted
review-gated
observed
claim-auditor"
            PAIR_KNOWN=1
            ;;
        "scholar-search:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
claim-auditor"
            PAIR_KNOWN=1
            ;;
        "audit:partial")
            ALLOWED_LITERALS="acted
review-gated
observed
claim-auditor"
            PAIR_KNOWN=1
            ;;
        "audit:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
claim-auditor"
            PAIR_KNOWN=1
            ;;
        "prior_match:partial")
            # Phase 4 PR-B (#625): prior_advocate runs an adversarial-
            # reviewer prompt that argues the claim is already known.
            # `partial` outcome covers acted / review-gated / observed
            # branches.
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
claim-auditor"
            PAIR_KNOWN=1
            ;;
        "prior_match:success")
            # Phase 4 PR-B (#625): prior_advocate `success` outcome
            # covers the propose-tier emitted branch.
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
claim-auditor"
            PAIR_KNOWN=1
            ;;

        # ----------------------------------------------------------------
        # preprint-foundry research federation (#622 PR-3)
        # ----------------------------------------------------------------
        # `submit` is HITL-gated end-to-end; `hitl-gated` is a literal
        # marker tag emitted by the HITL branches in submitter.ag.
        "introduce:partial")
            ALLOWED_LITERALS="acted
review-gated
observed
preprint-foundry"
            PAIR_KNOWN=1
            ;;
        "introduce:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
preprint-foundry"
            PAIR_KNOWN=1
            ;;
        "theorise:partial")
            ALLOWED_LITERALS="acted
review-gated
observed
preprint-foundry"
            PAIR_KNOWN=1
            ;;
        "theorise:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
preprint-foundry"
            PAIR_KNOWN=1
            ;;
        # #740: AdaptiveEngine activation in research-foundry/theorist.
        # The theorist emits `learn("proof_approach", draft.proof_kind,
        # ..., outcome, [tier, "preprint-foundry"])` alongside the
        # existing `theorise:*` rows so the AdaptiveEngine can rank
        # proof styles (sketch / full / computational) by the
        # `accuracy` fitness signal.
        "proof_approach:success")
            ALLOWED_LITERALS="acted
preprint-foundry"
            PAIR_KNOWN=1
            ;;
        "proof_approach:partial")
            ALLOWED_LITERALS="review-gated
emitted
observed
preprint-foundry"
            PAIR_KNOWN=1
            ;;
        # #745: Lean 4 verifier activation in research-foundry/theorist.
        # The theorist runs `lean <file>` against an LLM-rendered Lean
        # source body and emits one of three learn() rows per tick:
        #   verified  : closed proof accepted by lean, no `sorry`
        #   incomplete: lean accepted file but body contained `sorry`
        #   failed    : lean rejected file (timeout or `error:`)
        # The outcome doubles as the fitness signal for the
        # AdaptiveEngine + downstream auditor's VERIFIED_BY_LEAN
        # verdict label.
        "lean_check:verified")
            ALLOWED_LITERALS="lean
verification"
            PAIR_KNOWN=1
            ;;
        "lean_check:incomplete")
            ALLOWED_LITERALS="lean
verification"
            PAIR_KNOWN=1
            ;;
        "lean_check:failed")
            ALLOWED_LITERALS="lean
verification"
            PAIR_KNOWN=1
            ;;
        "compute:partial")
            ALLOWED_LITERALS="acted
review-gated
observed
preprint-foundry"
            PAIR_KNOWN=1
            ;;
        "compute:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
preprint-foundry"
            PAIR_KNOWN=1
            ;;
        "edit:partial")
            ALLOWED_LITERALS="acted
review-gated
observed
preprint-foundry"
            PAIR_KNOWN=1
            ;;
        "edit:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
preprint-foundry"
            PAIR_KNOWN=1
            ;;
        "review:partial")
            # Phase 4 PR-C (#625): reviewer cross-checks every numerical /
            # symbolic claim in the editor's final main.tex against the
            # computer's reproducibility stdout. `partial` outcome covers
            # acted / review-gated / observed branches.
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
preprint-foundry"
            PAIR_KNOWN=1
            ;;
        "review:success")
            # Phase 4 PR-C (#625): reviewer `success` outcome covers the
            # propose-tier approved branch (verdict == approved; writes
            # reviewer:<claim>:approved = "true").
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
preprint-foundry"
            PAIR_KNOWN=1
            ;;
        "review:failure")
            # Phase 4 PR-C (#625): reviewer `failure` outcome covers the
            # propose-tier rejected branch (verdict != approved; writes
            # reviewer:<claim>:hallucinated_payload for a future
            # editor-repair cycle).
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
preprint-foundry"
            PAIR_KNOWN=1
            ;;
        "submit:partial")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
preprint-foundry
hitl-gated"
            PAIR_KNOWN=1
            ;;
        "submit:success")
            ALLOWED_LITERALS="acted
review-gated
emitted
observed
preprint-foundry
hitl-gated"
            PAIR_KNOWN=1
            ;;
        # #740: AdaptiveEngine activation in research-foundry/submitter.
        # The submitter emits `learn("submission_decision",
        # meta.arxiv_category, ..., "success", ["emitted",
        # "preprint-foundry", "hitl-gated"])` alongside the existing
        # `submit:*` rows so the AdaptiveEngine can rank
        # metadata-quality choices by the `accuracy` fitness signal.
        # NOTE: this is a metadata-classification helper -- the
        # terminal arXiv-send decision still belongs to the #596 HITL
        # gate downstream.
        "submission_decision:success")
            ALLOWED_LITERALS="emitted
preprint-foundry
hitl-gated"
            PAIR_KNOWN=1
            ;;
        # #742: TaskBoard cognitive-market delegation in research-foundry.
        # explorer.ag offers compute-heavy claims on
        # `research-foundry:compute`; computer.ag accepts + completes
        # those offers. theorist.ag accepts on `research-foundry:theory`
        # (currently dormant — substrate ready for a follow-up that
        # adds theory producers). Each colony emits three (topic, outcome)
        # combinations:
        #   - explorer: ("taskboard", "success") with "offered" tag
        #     on `_offer_compute_task` success and "completed" tag on
        #     `_readback_task_result` success.
        #   - computer: ("taskboard", "success") with "accepted" tag on
        #     `_try_accept_compute_task` success and "completed" tag on
        #     `_complete_compute_task` success.
        #   - theorist: same shape as computer but on the theory channel.
        # Partial outcome captures the agentis-core `complete()` failure
        # path (escrow returned, claim still recorded for forensics).
        "taskboard:success")
            ALLOWED_LITERALS="taskboard
explorer
computer
theorist
offered
accepted
completed"
            PAIR_KNOWN=1
            ;;
        "taskboard:partial")
            ALLOWED_LITERALS="taskboard
explorer
computer
theorist
offered
accepted
completed"
            PAIR_KNOWN=1
            ;;
    esac
}

# Test a single token against ALLOWED_LITERALS + ALLOWED_PARAMS.
# Returns 0 (match) or 1 (no match) via $?.
token_allowed() {
    local tok="$1"
    local lit
    while IFS= read -r lit; do
        [ -z "$lit" ] && continue
        if [ "$tok" = "$lit" ]; then return 0; fi
    done <<EOF
$ALLOWED_LITERALS
EOF
    # Tribe-name placeholder: literal tribe-* or `_tribe_name` bareword.
    case "$tok" in
        tribe-alpha|tribe-beta|tribe-gamma|tribe-delta|tribe-epsilon|_tribe_name)
            # `<tn>` is only allowed when the schema explicitly lists it.
            case "$ALLOWED_LITERALS" in
                *"<tn>"*) return 0 ;;
            esac
            ;;
    esac
    # Colony-name placeholder: math-foundry colony literals, the 17
    # research-foundry non-explorer colony literals lit up in Phase 9
    # PR-C (#663), or one of the bareword variable references the .ag
    # files actually use today.
    case "$tok" in
        explorer|formulator|noticer|novelty|verifier|skeptic|\
arxiv-search|oeis-search|groupprops-search|scholar-search|prior_advocate|auditor|\
introducer|theorist|computer|editor|reviewer|submitter|\
_colony_name|colony_name_str)
            # `<cn>` is only allowed when the schema explicitly lists it.
            case "$ALLOWED_LITERALS" in
                *"<cn>"*) return 0 ;;
            esac
            ;;
    esac
    local pat
    while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        case "$pat" in
            "reward=<int>")
                case "$tok" in
                    reward=*)
                        local n="${tok#reward=}"
                        case "$n" in
                            ""|*[!0-9]*) ;;
                            *) return 0 ;;
                        esac
                        ;;
                esac
                ;;
            "buyer:<tn>")
                case "$tok" in
                    buyer:tribe-alpha|buyer:tribe-beta|buyer:tribe-gamma|buyer:tribe-delta|buyer:tribe-epsilon|buyer:_tribe_name)
                        return 0
                        ;;
                esac
                ;;
            "buyer:explorer")
                [ "$tok" = "buyer:explorer" ] && return 0
                ;;
            "buyer:prior_advocate")
                [ "$tok" = "buyer:prior_advocate" ] && return 0
                ;;
            "topic_kind:finding")
                [ "$tok" = "topic_kind:finding" ] && return 0
                ;;
            "topic_kind:bundle")
                [ "$tok" = "topic_kind:bundle" ] && return 0
                ;;
            "topic_kind:permutation_order_facts")
                [ "$tok" = "topic_kind:permutation_order_facts" ] && return 0
                ;;
            "topic_kind:known_priors")
                [ "$tok" = "topic_kind:known_priors" ] && return 0
                ;;
            "reason:unverifiable")
                [ "$tok" = "reason:unverifiable" ] && return 0
                ;;
            "verdict:<verdict>")
                # math-foundry explorer settle path emits
                # `"verdict:" + verdict_raw`. Allowed verdicts at lint
                # time: the four ACCEPT-side literals, the bareword
                # variable reference `_verdict_raw`, and the literal
                # placeholder `<verdict>` that `extract_token`
                # collapses any `"verdict:" + <bareword>` shape to
                # (#622 PR-3).
                case "$tok" in
                    verdict:NOVEL|verdict:BORDERLINE|verdict:NOT_NOVEL|verdict:REJECT)
                        return 0
                        ;;
                    verdict:_verdict_raw|verdict:verdict_raw|verdict:_verdict|verdict:verdict|verdict:'<verdict>')
                        return 0
                        ;;
                esac
                ;;
        esac
    done <<EOF
$ALLOWED_PARAMS
EOF
    return 1
}

# Resolve a literal-only tag token from a single comma-separated tag
# expression. Returns the literal via stdout, or an empty string when
# the expression is non-literal (variable / `+`-concatenated runtime
# value). Recognised literal shapes:
#   - "<bareword>"                                -> bareword
#   - "<prefix>" + <bareword-var>                 -> non-literal (returns "")
#   - "reward=" + to_string(...) etc              -> reward=<int>  (parametric)
#   - "buyer:" + _tribe_name                      -> buyer:<tn>    (parametric)
extract_token() {
    local expr="$1"
    # Strip leading + trailing whitespace.
    expr="${expr#"${expr%%[![:space:]]*}"}"
    expr="${expr%"${expr##*[![:space:]]}"}"
    [ -z "$expr" ] && { echo ""; return 0; }

    # Pure quoted literal: "..."
    case "$expr" in
        \"*\")
            local inner="${expr#\"}"
            inner="${inner%\"}"
            # Reject if it still contains a quote (means it was already a
            # concat). Belt-and-suspenders — the caller's tokeniser
            # already split on commas at depth 0.
            case "$inner" in
                *\"*) echo ""; return 0 ;;
            esac
            echo "$inner"
            return 0
            ;;
    esac

    # Bareword identifier (e.g. `_tribe_name`).
    case "$expr" in
        [a-zA-Z_]*)
            local rest="$expr"
            local clean=1
            local c
            local i=0
            while [ "$i" -lt "${#rest}" ]; do
                c="${rest:$i:1}"
                case "$c" in
                    [a-zA-Z0-9_]) ;;
                    *) clean=0; break ;;
                esac
                i=$((i + 1))
            done
            if [ "$clean" = "1" ]; then
                echo "$expr"
                return 0
            fi
            ;;
    esac

    # `"prefix" + <rhs>` -> parametric. Used to recognise the well-known
    # `"buyer:" + _tribe_name` and `"reward=" + to_string(...)` shapes.
    # We open-code the parse so leading/trailing whitespace around `+`
    # does not defeat us (the `case` glob `\"*\"*+*` would match even
    # when `+` is inside the closing quote, so do it manually).
    if [ "${expr:0:1}" = "\"" ]; then
        # Find the next un-escaped `"` (we already rejected embedded
        # quotes in the pure-literal branch above, so a second `"`
        # always closes the prefix string).
        local rest="${expr:1}"
        local close="${rest%%\"*}"
        if [ "$close" != "$rest" ]; then
            local prefix="$close"
            local after="${rest#"$close"\"}"
            # Strip whitespace around the `+`.
            after="${after#"${after%%[![:space:]]*}"}"
            if [ "${after:0:1}" = "+" ]; then
                local tail="${after#+}"
                tail="${tail#"${tail%%[![:space:]]*}"}"
                tail="${tail%"${tail##*[![:space:]]}"}"
                case "$prefix" in
                    "buyer:")
                        if [ "$tail" = "_tribe_name" ]; then
                            echo "buyer:_tribe_name"
                            return 0
                        fi
                        ;;
                    "reward=")
                        case "$tail" in
                            to_string\(*)
                                echo "reward=0"
                                return 0
                                ;;
                        esac
                        ;;
                    "verdict:")
                        # math-foundry explorer emits
                        # `"verdict:" + verdict_raw`. Collapse any
                        # bareword tail to the parametric placeholder
                        # so `token_allowed` matches via
                        # `verdict:<verdict>` (#622 PR-3).
                        case "$tail" in
                            [a-zA-Z_]*)
                                local tclean=1
                                local tc
                                local ti=0
                                while [ "$ti" -lt "${#tail}" ]; do
                                    tc="${tail:$ti:1}"
                                    case "$tc" in
                                        [a-zA-Z0-9_]) ;;
                                        *) tclean=0; break ;;
                                    esac
                                    ti=$((ti + 1))
                                done
                                if [ "$tclean" = "1" ]; then
                                    echo "verdict:$tail"
                                    return 0
                                fi
                                ;;
                        esac
                        ;;
                esac
            fi
        fi
    fi

    # Anything else: dynamic. Signal to caller via empty string.
    echo ""
    return 0
}

# Split a top-level argument string `s` on commas at parenthesis/bracket
# depth 0. Emits one token per line.
split_top_level_commas() {
    local s="$1"
    local depth=0
    local cur=""
    local i=0
    local c
    local in_str=0
    local esc=0
    while [ "$i" -lt "${#s}" ]; do
        c="${s:$i:1}"
        if [ "$in_str" = "1" ]; then
            cur="$cur$c"
            if [ "$esc" = "1" ]; then
                esc=0
            elif [ "$c" = "\\" ]; then
                esc=1
            elif [ "$c" = "\"" ]; then
                in_str=0
            fi
            i=$((i + 1))
            continue
        fi
        case "$c" in
            \")
                in_str=1
                cur="$cur$c"
                ;;
            \(|\[)
                depth=$((depth + 1))
                cur="$cur$c"
                ;;
            \)|\])
                depth=$((depth - 1))
                cur="$cur$c"
                ;;
            ,)
                if [ "$depth" -le 0 ]; then
                    printf '%s\n' "$cur"
                    cur=""
                else
                    cur="$cur$c"
                fi
                ;;
            *)
                cur="$cur$c"
                ;;
        esac
        i=$((i + 1))
    done
    if [ -n "$cur" ]; then
        printf '%s\n' "$cur"
    fi
}

check_file() {
    local ag_file="$1"
    local prev_line=""
    local nr=0
    local line clean

    while IFS= read -r line || [ -n "$line" ]; do
        nr=$((nr + 1))
        # Strip `//` line comment (everything from `//` onward) before
        # matching; suppression check uses the ORIGINAL line so the
        # `// colony-lint: learn-tags-ok` marker still works.
        clean="$line"
        case "$clean" in
            *"//"*) clean="${clean%%//*}" ;;
        esac

        # Skip lines that don't begin a learn( call.
        case "$clean" in
            *learn\(*) ;;
            *) prev_line="$line"; continue ;;
        esac

        # Suppression marker on this or previous line.
        local suppressed=0
        case "$line" in
            *"colony-lint: learn-tags-ok"*) suppressed=1 ;;
        esac
        case "$prev_line" in
            *"colony-lint: learn-tags-ok"*)
                # If prev_line ALSO contains a learn( call, the marker was
                # inline-paired with prev's learn() and must not propagate
                # suppression forward to the current line (issue #510).
                # Only above-line markers (sitting on their own line) silence
                # the next learn() call.
                case "$prev_line" in
                    *learn\(*) ;;
                    *) suppressed=1 ;;
                esac
                ;;
        esac
        if [ "$suppressed" = "1" ]; then
            prev_line="$line"
            continue
        fi

        # Strip up to and including `learn(`, then balance parens to find
        # the matching `)`. Multi-line `learn(` would require a buffered
        # read; current hunters always one-line so we stop at end-of-line.
        local body="${clean#*learn\(}"

        # Walk `body` until parens balance back to zero. Track strings so
        # `(` / `)` inside `"..."` are not counted.
        local depth=1
        local arg=""
        local i=0
        local c esc=0 in_str=0
        while [ "$i" -lt "${#body}" ]; do
            c="${body:$i:1}"
            if [ "$in_str" = "1" ]; then
                arg="$arg$c"
                if [ "$esc" = "1" ]; then
                    esc=0
                elif [ "$c" = "\\" ]; then
                    esc=1
                elif [ "$c" = "\"" ]; then
                    in_str=0
                fi
                i=$((i + 1))
                continue
            fi
            case "$c" in
                \")
                    in_str=1
                    arg="$arg$c"
                    ;;
                \()
                    depth=$((depth + 1))
                    arg="$arg$c"
                    ;;
                \))
                    depth=$((depth - 1))
                    if [ "$depth" -le 0 ]; then break; fi
                    arg="$arg$c"
                    ;;
                *)
                    arg="$arg$c"
                    ;;
            esac
            i=$((i + 1))
        done

        if [ "$depth" -gt 0 ]; then
            # Multi-line learn() — out of scope, warn + skip.
            printf 'check-learn-tags: %s:%d: WARN: multi-line learn() call skipped\n' "$ag_file" "$nr" >&2
            WARN=$((WARN + 1))
            prev_line="$line"
            continue
        fi

        # `arg` now holds the comma-separated argument list (top-level).
        # Split on top-level commas into 5 args:
        # learn(topic, key, value, outcome, [tags...]).
        local args
        args="$(split_top_level_commas "$arg")"

        local arg1 arg4 arg5
        # shellcheck disable=SC2034
        arg1="$(printf '%s\n' "$args" | sed -n '1p')"
        arg4="$(printf '%s\n' "$args" | sed -n '4p')"
        arg5="$(printf '%s\n' "$args" | sed -n '5p')"

        local topic outcome
        topic="$(extract_token "$arg1")"
        outcome="$(extract_token "$arg4")"

        if [ -z "$topic" ] || [ -z "$outcome" ]; then
            printf 'check-learn-tags: %s:%d: WARN: dynamic topic/outcome (topic=%s outcome=%s) — cannot validate statically\n' "$ag_file" "$nr" "${topic:-<dyn>}" "${outcome:-<dyn>}" >&2
            WARN=$((WARN + 1))
            prev_line="$line"
            continue
        fi

        check_pair_schema "$topic" "$outcome"
        if [ "$PAIR_KNOWN" = "0" ]; then
            # shellcheck disable=SC2016
            printf '%s:%d — VIOLATION: unknown (topic=%s, outcome=%s) — extend tools/check-learn-tags.sh schema or annotate with `// colony-lint: learn-tags-ok`\n' "$ag_file" "$nr" "$topic" "$outcome"
            FAIL=$((FAIL + 1))
            prev_line="$line"
            continue
        fi

        # Extract the tag list (5th arg). Expect shape: `[ a, b, c ]`.
        local tag_body="$arg5"
        # Strip leading/trailing whitespace.
        tag_body="${tag_body#"${tag_body%%[![:space:]]*}"}"
        tag_body="${tag_body%"${tag_body##*[![:space:]]}"}"
        case "$tag_body" in
            \[*\])
                tag_body="${tag_body#\[}"
                tag_body="${tag_body%\]}"
                ;;
            *)
                # Tag list is a variable reference, not a literal list.
                if [ "$STRICT" = "1" ]; then
                    printf '%s:%d — VIOLATION: non-literal tag list (topic=%s outcome=%s) under COLONY_LINT_STRICT_LEARN_TAGS=1\n' "$ag_file" "$nr" "$topic" "$outcome"
                    FAIL=$((FAIL + 1))
                else
                    printf 'check-learn-tags: %s:%d: WARN: non-literal tag list (topic=%s outcome=%s) — runtime evasion gap; rerun with COLONY_LINT_STRICT_LEARN_TAGS=1 to fail\n' "$ag_file" "$nr" "$topic" "$outcome" >&2
                    WARN=$((WARN + 1))
                fi
                prev_line="$line"
                continue
                ;;
        esac

        # Tokenize tags on top-level commas.
        local tag_list
        tag_list="$(split_top_level_commas "$tag_body")"

        local raw tok any_dynamic=0
        while IFS= read -r raw; do
            [ -z "${raw// /}" ] && continue
            tok="$(extract_token "$raw")"
            if [ -z "$tok" ]; then
                any_dynamic=1
                continue
            fi
            if ! token_allowed "$tok"; then
                printf '%s:%d — VIOLATION: topic=%s outcome=%s unexpected tag %s\n' "$ag_file" "$nr" "$topic" "$outcome" "$tok"
                FAIL=$((FAIL + 1))
            fi
        done <<EOF
$tag_list
EOF

        if [ "$any_dynamic" = "1" ]; then
            if [ "$STRICT" = "1" ]; then
                printf '%s:%d — VIOLATION: dynamic tag token in (topic=%s outcome=%s) under COLONY_LINT_STRICT_LEARN_TAGS=1\n' "$ag_file" "$nr" "$topic" "$outcome"
                FAIL=$((FAIL + 1))
            else
                printf 'check-learn-tags: %s:%d: WARN: dynamic tag token (topic=%s outcome=%s) — runtime evasion gap; rerun with COLONY_LINT_STRICT_LEARN_TAGS=1 to fail\n' "$ag_file" "$nr" "$topic" "$outcome" >&2
                WARN=$((WARN + 1))
            fi
        fi

        prev_line="$line"
    done < "$ag_file"
}

# Main: walk per-federation agent trees and skip per-run snapshots.
# Covers tribes-bench (hunter today; glob is one level broader so a
# future scout.ag / verifier.ag picks up coverage automatically) plus
# the three research federations math-foundry / claim-auditor /
# preprint-foundry added in #622 PR-3.
if [ -f "$SCAN_ROOT" ]; then
    check_file "$SCAN_ROOT"
else
    while IFS= read -r -d '' f; do
        case "$f" in
            */runs/*) continue ;;
        esac
        check_file "$f"
    done < <(find "$SCAN_ROOT" -type f \( \
        -path '*/tribes-bench/tribe-*/agents/*.ag' -o \
        -path '*/research-foundry/*/agents/*.ag' \
        \) -print0)
fi

if [ "$FAIL" -gt 0 ]; then
    echo "" >&2
    echo "check-learn-tags: $FAIL violation(s), $WARN warning(s)" >&2
    exit 2
fi

if [ "$WARN" -gt 0 ]; then
    echo "check-learn-tags: $WARN warning(s) (dynamic tag construction — known evasion gap)" >&2
fi

exit 0
