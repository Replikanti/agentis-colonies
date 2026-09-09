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
#
# #2150 — SAME-FILE CALLEE CLOSURE. A requested function is rarely where the interesting code lives: an
# `external` entry point delegates the actual state writes and external calls to same-file `internal`
# helpers, so a slice of the entry point alone showed the hunter (and every deterministic detector that
# reads the assembled payload, e.g. hunter.ag's #2145 attacker-controlled-callee net) a call site that
# simply was not there. The requested names are therefore expanded, BEFORE extraction, with the
# `internal`/`private` same-file functions transitively reachable from them, bounded by:
#   SLICE_MAX_DEPTH  (default 3)     how many call-graph hops to follow; 0 disables the closure entirely
#                                    and reproduces the pre-#2150 output byte for byte.
#   SLICE_MAX_LINES  (default 2000)  ceiling on the slice's line count (header + everything kept), the
#                                    same 2000 the whole-file fallback below already uses.
# Only closure-DISCOVERED callees are visibility-filtered; a requested name is always kept, whatever its
# visibility. Cross-file callees (interfaces, libraries, inherited members) are deliberately NOT followed.
# When a cap stops the closure short of a fixpoint, ONE note goes to stderr naming the cap that stopped it
# and how many callees had been discovered but not taken; the slice on stdout is unaffected.
# Same best-effort caveat as the brace matcher: visibility is read off the declaration lines, so an exotic
# multi-line signature can be mis-classified — again only ever over/under-sizing a slice.
set -eu

F="${1:?slice-fns.sh: <file.sol> required}"
FNS="${2:-}"
SLICE_MAX_DEPTH="${SLICE_MAX_DEPTH:-3}"
SLICE_MAX_LINES="${SLICE_MAX_LINES:-2000}"
[ -f "$F" ] || exit 0
[ -n "$FNS" ] || { sed -n '1,2000p' "$F"; exit 0; }

# --- closure pre-pass: expand $FNS with the reachable same-file internal/private callees ------------------
# Prints exactly two lines: the expanded comma-joined name list, then the truncation note ("" when the
# closure reached a fixpoint). Nothing here prints code — the untouched extraction awk below still does all
# header handling, brace matching and printing, over a merely LARGER set of wanted names.
if [ "$SLICE_MAX_DEPTH" -gt 0 ] 2>/dev/null; then
  CLOSURE="$(awk -v fns="$FNS" -v maxdepth="$SLICE_MAX_DEPTH" -v maxlines="$SLICE_MAX_LINES" '
BEGIN {
  n = split(fns, A, /[,+]/)
  for (i = 1; i <= n; i++) {
    gsub(/^[ \t]+|[ \t]+$/, "", A[i])
    if (A[i] != "" && !(A[i] in want)) { want[A[i]] = 1; ord[++nw] = A[i] }
  }
  header = 1; infn = 0; d = 0; started = 0; nf = 0; hdr = 0
}
# Header runs to the FIRST function definition — the same rule the printer below uses, so `hdr` is the exact
# number of lines the header will cost, not an estimate.
header && /(^|[^[:alnum:]_])function[ \t(]/ { header = 0; hdr = NR - 1 }
header { next }
# Every function is tabled (not only the wanted ones): start line, end line, body text and whether its
# signature declares it internal/private.
!infn && /(^|[^[:alnum:]_])function[ \t]+[A-Za-z0-9_]+/ {
  s = $0; sub(/.*function[ \t]+/, "", s); sub(/[ \t(].*/, "", s)
  nf++; fname[nf] = s; fstart[nf] = NR; fend[nf] = NR; fbody[nf] = ""; fvis[nf] = 0
  infn = 1; d = 0; started = 0
}
infn {
  fbody[nf] = fbody[nf] "\n" $0
  # Visibility is accumulated over the signature (up to the opening brace) so a multi-line parameter list
  # still classifies correctly.
  if (!started && $0 ~ /(^|[^[:alnum:]_])(internal|private)([^[:alnum:]_]|$)/) fvis[nf] = 1
  t = $0; o = gsub(/{/, "x", t); u = $0; c = gsub(/}/, "x", u); d += o - c
  if (o > 0) started = 1
  if (started && d <= 0) { infn = 0; fend[nf] = NR }
  else if (!started && index($0, ";") > 0) { infn = 0; fend[nf] = NR }   # bodyless decl (interface/abstract)
  next
}
END {
  if (header) hdr = NR
  if (nw == 0) { print ""; print ""; exit }
  # Fold the per-definition table into per-NAME maps (an overloaded name is one closure node carrying the
  # cost of all its overloads, which is what the printer will actually emit).
  for (i = 1; i <= nf; i++) {
    sp = fend[i] - fstart[i] + 2                       # +1 for the blank line the printer emits after each fn
    if (fname[i] in span) span[fname[i]] += sp; else span[fname[i]] = sp
    if (fname[i] in bodies) bodies[fname[i]] = bodies[fname[i]] fbody[i]; else bodies[fname[i]] = fbody[i]
    if (fvis[i]) vis[fname[i]] = 1
  }
  total = hdr
  for (k = 1; k <= nw; k++) if (ord[k] in span) total += span[ord[k]]
  nfr = 0
  for (k = 1; k <= nw; k++) fr[++nfr] = ord[k]         # round-0 frontier = the requested names

  capped = 0; omitted = 0; reason = ""; capn = 0
  for (r = 1; r <= maxdepth && nfr > 0; r++) {
    nnx = 0
    for (k = 1; k <= nfr; k++) {
      b = (fr[k] in bodies) ? bodies[fr[k]] : ""
      while (match(b, /[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/)) {
        cand = substr(b, RSTART, RLENGTH); b = substr(b, RSTART + RLENGTH)
        sub(/[ \t]*\($/, "", cand)
        if (cand in want) continue                      # already kept (incl. the requested names themselves)
        if (!(cand in vis)) continue                    # not a same-file internal/private function
        if (capped || total + span[cand] > maxlines) {
          if (!capped) { capped = 1; reason = "line-cap"; capn = maxlines }
          if (!(cand in omit)) { omit[cand] = 1; omitted++ }
          continue
        }
        want[cand] = 1; ord[++nw] = cand; total += span[cand]; nx[++nnx] = cand
      }
    }
    nfr = nnx
    for (k = 1; k <= nfr; k++) fr[k] = nx[k]
    if (capped) break
  }
  # Depth cap: the rounds ran out while the last frontier still had un-taken callees.
  if (!capped && nfr > 0) {
    for (k = 1; k <= nfr; k++) {
      b = (fr[k] in bodies) ? bodies[fr[k]] : ""
      while (match(b, /[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/)) {
        cand = substr(b, RSTART, RLENGTH); b = substr(b, RSTART + RLENGTH)
        sub(/[ \t]*\($/, "", cand)
        if (cand in want) continue
        if (!(cand in vis)) continue
        if (!(cand in omit)) { omit[cand] = 1; omitted++ }
      }
    }
    if (omitted > 0) { reason = "depth-cap"; capn = maxdepth }
  }

  out = ord[1]
  for (k = 2; k <= nw; k++) out = out "," ord[k]
  print out
  # <M> counts the callees the closure had DISCOVERED when a cap stopped it, not the unexplored tail beyond
  # them — an honest floor, since the tail is exactly what was never walked.
  if (reason != "") printf "slice-fns: closure truncated (%s %d) — %d callee(s) omitted\n", reason, capn, omitted
  else print ""
}
' "$F")" || CLOSURE=""
  EXPANDED="$(printf '%s\n' "$CLOSURE" | sed -n '1p')"
  NOTE="$(printf '%s\n' "$CLOSURE" | sed -n '2p')"
  [ -z "$EXPANDED" ] || FNS="$EXPANDED"
  [ -z "$NOTE" ] || printf '%s\n' "$NOTE" >&2
fi

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
