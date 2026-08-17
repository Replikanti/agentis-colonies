#!/usr/bin/env bash
# extract-solidity-symbols.sh -- deterministic, network-free Solidity SYMBOL INVENTORY extractor.
#
# FM-B (#1939 M2, dark-factory): the symbol-grounding source for run-invariant-hunt.sh --ground-symbols. Given
# one or more STAGED .sol sources (the target + every --aux auxiliary), print a BOUNDED, SORTED inventory of the
# identifiers that actually exist in scope:
#   - `contract` / `interface` / `library` NAMES  (emitted as `contract <Name>` etc.)
#   - `struct` / `enum` type NAMES                 (emitted as `struct <Name>` / `enum <Name>`)
#   - `external` / `public` function SIGNATURES    (emitted as `function <name>(<type>,<type>,...)`)
#
# The generated invariant harness that fails on the composable-fresh multi-contract shape does so with
# solc `Error (7920): Identifier not found or not unique` -- it references a contract/function name that is NOT
# in scope. Feeding the model the REAL inventory grounds generation + every repair round against names that
# exist, instead of hallucinating a plausible-but-absent identifier.
#
# This is a STANDALONE tools-style script (grep/awk/sed) -- the #1587 substrate-purity ratchet governs only NEW
# embedded interpreters inside `.ag` `exec sh` strings, NOT standalone shell tools like this one.
#
# Contract:
#   - Empty input (no args, or no arg is an existing file) => EMPTY output.
#   - Deterministic: the inventory is `LC_ALL=C sort -u`ed, so the SAME sources always yield the SAME bytes.
#   - Source-parsing only: no `forge build`, no network, no artifacts required (the CI-testable primary path).
#     A live `forge out/` ABI augmentation is intentionally NOT done here -- it needs a build and cannot be
#     pinned deterministically in CI.
#
# Usage: extract-solidity-symbols.sh <file.sol> [<file.sol> ...]
# Exit: 0 always (a missing/unreadable file is skipped, never a hard error -- absent grounding degrades to the
#       un-grounded prompt, never worse).

set -eu

# Cap the inventory so a huge multi-contract system cannot blow up the generation prompt (bounded grounding).
MAX_SYMBOLS="${SYMBOL_INVENTORY_MAX:-500}"

[ "$#" -gt 0 ] || exit 0

emit() {
  for _f in "$@"; do
    [ -f "$_f" ] || continue
    # Strip line comments first so a decl inside `// ...` is never captured. awk does the rest so the whole
    # per-file parse is one pass with no shell-per-line cost.
    awk '
      {
        line = $0
        sub(/\/\/.*/, "", line)   # drop line comments
      }
      # contract / interface / library <Name>
      {
        s = line
        while (match(s, /(^|[^A-Za-z0-9_$])(contract|interface|library)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/)) {
          tok = substr(s, RSTART, RLENGTH)
          # normalize leading separator + internal whitespace, then split keyword / name
          sub(/^[^A-Za-z]*/, "", tok)
          gsub(/[ \t]+/, " ", tok)
          print tok
          s = substr(s, RSTART + RLENGTH)
        }
      }
      # struct / enum <Name>  (type names)
      {
        s = line
        while (match(s, /(^|[^A-Za-z0-9_$])(struct|enum)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/)) {
          tok = substr(s, RSTART, RLENGTH)
          sub(/^[^A-Za-z]*/, "", tok)
          gsub(/[ \t]+/, " ", tok)
          print tok
          s = substr(s, RSTART + RLENGTH)
        }
      }
      # external / public function signatures -> function <name>(<type>,<type>,...)
      line ~ /function[ \t]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]*\(/ && (line ~ /external/ || line ~ /public/) {
        rest = line
        sub(/.*function[ \t]+/, "", rest)      # rest now starts with `<name>(...`
        name = rest
        sub(/[ \t]*\(.*/, "", name)            # `<name>`
        params = rest
        sub(/^[^(]*\(/, "", params)            # drop up to and including the first (
        sub(/\).*/, "", params)                # drop from the first ) onwards
        gsub(/[ \t]+/, " ", params)
        gsub(/^ +| +$/, "", params)
        sig = ""
        if (params != "") {
          n = split(params, arr, ",")
          for (i = 1; i <= n; i++) {
            seg = arr[i]
            gsub(/^ +| +$/, "", seg)
            split(seg, tk, " ")
            t = tk[1]                           # the TYPE is the first token of each param segment
            if (t != "") { sig = sig (sig == "" ? "" : ",") t }
          }
        }
        print "function " name "(" sig ")"
      }
    ' "$_f"
  done
}

emit "$@" | LC_ALL=C sort -u | head -n "$MAX_SYMBOLS"
