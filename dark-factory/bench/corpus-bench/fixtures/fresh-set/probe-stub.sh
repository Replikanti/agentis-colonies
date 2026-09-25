#!/bin/sh
# probe-stub.sh — the offline stand-in for the hunter model in fresh-set.sh's training-memorisation probe (#2263).
# Contract (the same one fresh-set.py drives the stub backend with): `probe-stub.sh --model <id>`, the probe
# prompt on stdin, the reply on stdout. Deterministic, no LLM / network.
#
# The first reply line echoes the model pin, so the self-test can prove `--model` reached the backend (the
# parser ignores any line that is not a FINDING| line). For the synthetic alpha contest it "remembers":
#   F1  the rare H-1 by its function + mechanism          -> recalled_from_memory yes
#   F2  the rare M-1 by its function, one mechanism word  -> partial
#   F3  the consensus M-2 by a GENERIC function name only -> partial (a generic name never reaches yes)
#   F4  a generic mechanism with no name                  -> credits nothing
# Every other contest gets `FINDING|NONE`. FRESH_SET_PROBE_STUB_MODE=fail answers nothing and exits 1 (a dead
# backend), for the "a failed probe is never scored" assertion.
#
# A CUED prompt (`MEMORY PROBE (cued)`, one `C<n>|<contract>:<function>` line per location) gets one CUE| line per
# location: YES + the right mechanism at `claimRewards` (the alpha rare row), NONE everywhere else (the decoy
# included). FRESH_SET_PROBE_STUB_MODE=yes-all answers YES with a content-free sentence to EVERY cue, the
# say-yes-to-everything model the decoy exists to expose.
#
# dash-safe: no arrays, no $'...', literal glyphs only.
set -u

model="-"
if [ "${1:-}" = "--model" ] && [ $# -ge 2 ]; then
  model="$2"
fi
prompt="$(cat)"

if [ "${FRESH_SET_PROBE_STUB_MODE:-reply}" = "fail" ]; then
  exit 1
fi

echo "stub model=$model"
case "$prompt" in
  'MEMORY PROBE (cued)'*)
    printf '%s\n' "$prompt" | while IFS='|' read -r label loc; do
      case "$label" in C[0-9]*) ;; *) continue ;; esac
      if [ "${FRESH_SET_PROBE_STUB_MODE:-reply}" = "yes-all" ]; then
        echo "CUE|$label|YES|an accepted finding was reported at this function"
      else
        case "$loc" in
          *:claimRewards) echo "CUE|$label|YES|claimRewards pays out before clearing the balance, so a reentrant claimer drains the reward balance" ;;
          *) echo "CUE|$label|NONE" ;;
        esac
      fi
    done
    ;;
  *'"2099-01-alpha"'*)
    echo "FINDING|H|Vault|claimRewards|claimRewards pays out before clearing the balance, so a reentrant claimer drains the reward balance"
    echo "FINDING|M|Vault|sweepDust|sweepDust uses a stale value"
    echo "  FINDING|M|Pool|deposit|no slippage bound, so a sandwich bot extracts value"
    echo "FINDING|H|Oracle|-|price oracle manipulation"
    ;;
  *)
    echo "FINDING|NONE"
    ;;
esac
