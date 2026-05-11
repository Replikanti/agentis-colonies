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
            ALLOWED_LITERALS="replicated
tribes-bench
<tn>"
            PAIR_KNOWN=1
            ;;
        "replicate:failure")
            ALLOWED_LITERALS="replicate-skip
replicate-error
replicate-nak
tribes-bench
<tn>"
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
            ALLOWED_LITERALS="sell-failed
tribes-bench"
            PAIR_KNOWN=1
            ;;
        "market:cache_hit")
            ALLOWED_LITERALS="tribes-bench"
            ALLOWED_PARAMS="buyer:<tn>
topic_kind:finding
topic_kind:bundle"
            PAIR_KNOWN=1
            ;;
        "market:rejected")
            # #493 Loose category (c): consumer-side knowledge_sell validation
            # rejects answers whose claimed bug_id is not in the seller's
            # verifier-stamped bug-ledger.jsonl. Emits this learn() with
            # reason:unverifiable so downstream telemetry can distinguish
            # rejections from cache hits.
            ALLOWED_LITERALS="tribes-bench"
            ALLOWED_PARAMS="buyer:<tn>
topic_kind:finding
topic_kind:bundle
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
            "topic_kind:finding")
                [ "$tok" = "topic_kind:finding" ] && return 0
                ;;
            "topic_kind:bundle")
                [ "$tok" = "topic_kind:bundle" ] && return 0
                ;;
            "reason:unverifiable")
                [ "$tok" = "reason:unverifiable" ] && return 0
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

# Main: walk tribes-bench/tribe-*/agents/*.ag (hunter agents today; the
# glob is intentionally one level broader so a future scout.ag /
# verifier.ag picks up coverage automatically). Skip `runs/` snapshots.
if [ -f "$SCAN_ROOT" ]; then
    check_file "$SCAN_ROOT"
else
    while IFS= read -r -d '' f; do
        case "$f" in
            */runs/*) continue ;;
        esac
        check_file "$f"
    done < <(find "$SCAN_ROOT" -type f -path '*/tribes-bench/tribe-*/agents/*.ag' -print0)
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
