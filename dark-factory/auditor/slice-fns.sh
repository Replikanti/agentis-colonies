#!/usr/bin/env bash
# slice-fns.sh — extract a Solidity contract's HEADER + named functions (brace-matched), so the
# discovery hunter can feed FUNCTION-LEVEL slices of large/complex contracts instead of whole files.
# A whole-file concat of a 1000-2000 line contract overflows the LLM per-call budget on a deep
# adversarial read (the liquidation/seize cells time out); a header + the 2-3 relevant functions fits.
#
# Usage:  slice-fns.sh <file.sol> "<fn1,fn2,...>"
# Prints: the file's leading context (pragma / imports / contract decl / state vars / structs / events /
#         modifiers — everything before the first function) followed by each named function in full
#         (from its `function <name>` line to the matching close brace). If none of the requested names
#         match, falls back to the first 2000 lines (so a typo never yields an empty payload).
# Brace counting is line-based and best-effort: braces inside strings/comments can miscount (acceptable
# for a discovery prompt — the worst case is a slightly over/under-sized slice, never a wrong verdict).
set -eu

F="${1:?slice-fns.sh: <file.sol> required}"
FNS="${2:-}"
[ -f "$F" ] || exit 0
[ -n "$FNS" ] || { sed -n '1,2000p' "$F"; exit 0; }

OUT="$(awk -v fns="$FNS" '
BEGIN {
  n = split(fns, A, /[,+]/)
  for (i = 1; i <= n; i++) { gsub(/^[ \t]+|[ \t]+$/, "", A[i]); if (A[i] != "") want[A[i]] = 1 }
  header = 1; infn = 0; depth = 0; started = 0; matched = 0
}
# Header: print every line up to the FIRST function definition (pragma/imports/state/structs/modifiers).
header && /(^|[^[:alnum:]_])function[ \t(]/ { header = 0 }
header { print; next }
# Function start: capture the name; if wanted, enter capture mode (fall through to the infn block so
# this very line is printed + brace-counted).
!infn && /(^|[^[:alnum:]_])function[ \t]+[A-Za-z0-9_]+/ {
  s = $0; sub(/.*function[ \t]+/, "", s); sub(/[ \t(].*/, "", s)
  if (s in want) { infn = 1; depth = 0; started = 0; matched = 1 }
}
infn {
  print
  t = $0; o = gsub(/{/, "x", t); u = $0; c = gsub(/}/, "x", u); depth += o - c
  if (o > 0) started = 1
  if (started && depth <= 0) { infn = 0; print "" }
  next
}
END { if (!matched) exit 3 }
' "$F")" && rc=0 || rc=$?

if [ "${rc:-0}" -eq 3 ]; then
  sed -n '1,2000p' "$F"      # no requested function matched → whole-file fallback
else
  printf '%s\n' "$OUT"
fi
