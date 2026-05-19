#!/usr/bin/env bash
# research-foundry/tools/test-replicate-gates.sh -- regression test for
# the Phase 9 PR-C (#663) per-`.ag` replicate-gate boilerplate.
#
# For each of 3 representative colonies (one discovery non-explorer,
# one audit, one preprint) assert:
#   (a) `.ag` syntax clean via `agentis commit`
#   (b) `_publish_<role>` contains the M2-Malthusian replicate call
#       (`replicate(target_r, my_fit_r, variant_wrapped)`)
#   (c) `_specialty_overlay_suffix` reads from memo correctly
#       (matches `recall_latest(<colony>:` + `:specialty_overlay")`)
#   (d) first-tick claim block reads `$DAEMON_ID`
#
# Standard library only -- no pytest, no live federation.
#
# Usage: bash research-foundry/tools/test-replicate-gates.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
SKIP=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1: $2"; SKIP=$((SKIP + 1)); }

# Three representative colonies span the three pipeline sides.
REP_COLONIES=("noticer" "auditor" "editor")

# (a) Syntax-clean via agentis commit. Skip cleanly when agentis is
# not on PATH (CI runners without the binary).
if command -v agentis >/dev/null 2>&1; then
    AG_TMP="$(mktemp -d)"
    trap 'rm -rf "$AG_TMP"' EXIT
    (cd "$AG_TMP" && agentis init >/dev/null 2>&1) || true
    for c in "${REP_COLONIES[@]}"; do
        ag_file="$FED_DIR/$c/agents/$c.ag"
        if [ ! -f "$ag_file" ]; then
            fail "(a) $c.ag exists" "$ag_file not found"
            continue
        fi
        if (cd "$AG_TMP" && agentis commit "$ag_file") >/dev/null 2>&1; then
            pass "(a) $c.ag syntax clean"
        else
            fail "(a) $c.ag syntax clean" "$(cd "$AG_TMP" && agentis commit "$ag_file" 2>&1 | tail -5)"
        fi
    done
else
    for c in "${REP_COLONIES[@]}"; do
        skip "(a) $c.ag syntax clean" "agentis binary not on PATH"
    done
fi

# (b) _publish_<role> contains the M2-Malthusian replicate call.
for c in "${REP_COLONIES[@]}"; do
    ag_file="$FED_DIR/$c/agents/$c.ag"
    if [ ! -f "$ag_file" ]; then
        fail "(b) $c.ag _publish_<role> replicate call" "$ag_file not found"
        continue
    fi
    if grep -q "fn _publish_$c" "$ag_file" && \
       grep -q "replicate(target_r, my_fit_r, variant_wrapped)" "$ag_file"; then
        pass "(b) $c.ag _publish_$c contains M2-Malthusian replicate() call"
    else
        fail "(b) $c.ag _publish_$c contains M2-Malthusian replicate() call" \
             "missing replicate(target_r, my_fit_r, variant_wrapped) call"
    fi
done

# (c) _specialty_overlay_suffix reads from memo with the colony-prefixed
# specialty_overlay key.
for c in "${REP_COLONIES[@]}"; do
    ag_file="$FED_DIR/$c/agents/$c.ag"
    if [ ! -f "$ag_file" ]; then
        fail "(c) $c.ag _specialty_overlay_suffix memo read" "$ag_file not found"
        continue
    fi
    if grep -q "fn _specialty_overlay_suffix" "$ag_file" && \
       grep -q "recall_latest(\"$c:\" + self_pid + \":specialty_overlay\")" "$ag_file"; then
        pass "(c) $c.ag _specialty_overlay_suffix reads memo correctly"
    else
        fail "(c) $c.ag _specialty_overlay_suffix reads memo correctly" \
             "missing recall_latest(\"$c:\" + self_pid + \":specialty_overlay\")"
    fi
done

# (d) first-tick claim block reads $DAEMON_ID env var.
for c in "${REP_COLONIES[@]}"; do
    ag_file="$FED_DIR/$c/agents/$c.ag"
    if [ ! -f "$ag_file" ]; then
        fail "(d) $c.ag first-tick claim reads DAEMON_ID" "$ag_file not found"
        continue
    fi
    if grep -q "exec sh \"printenv DAEMON_ID\"" "$ag_file" && \
       grep -q "recall_latest(\"$c:pool:specialty:\" + _daemon_id)" "$ag_file"; then
        pass "(d) $c.ag first-tick claim block reads \$DAEMON_ID"
    else
        fail "(d) $c.ag first-tick claim block reads \$DAEMON_ID" \
             "missing exec sh printenv DAEMON_ID + $c:pool:specialty:<daemon_id> read"
    fi
done

# (e) Coverage check: all 17 non-explorer colonies have the four
# required helpers + replicate path. Catches accidental skip of a
# colony when the boilerplate is added piecemeal.
NON_EXPLORER=(noticer formulator verifier novelty skeptic
              arxiv-search oeis-search groupprops-search scholar-search prior_advocate auditor
              introducer theorist computer editor reviewer submitter)
for c in "${NON_EXPLORER[@]}"; do
    ag_file="$FED_DIR/$c/agents/$c.ag"
    if [ ! -f "$ag_file" ]; then
        fail "(e) $c.ag exists for coverage check" "$ag_file not found"
        continue
    fi
    missing=""
    grep -q "fn _variant_overlay_suffix" "$ag_file" || missing="$missing _variant_overlay_suffix"
    grep -q "fn _specialty_overlay_suffix" "$ag_file" || missing="$missing _specialty_overlay_suffix"
    grep -q "fn _extract_pp_hash" "$ag_file" || missing="$missing _extract_pp_hash"
    grep -q "fn _publish_prompt_body_and_wrap_variant" "$ag_file" || missing="$missing _publish_prompt_body_and_wrap_variant"
    grep -q "fn pick_variant" "$ag_file" || missing="$missing pick_variant"
    grep -q "replicate(target_r, my_fit_r, variant_wrapped)" "$ag_file" || missing="$missing replicate-call"
    if [ -z "$missing" ]; then
        pass "(e) $c.ag has all required helpers + replicate path"
    else
        fail "(e) $c.ag has all required helpers + replicate path" "missing:$missing"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
