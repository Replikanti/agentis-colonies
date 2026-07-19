#!/usr/bin/env bash
# demo-historical-patterns.sh — proof of the #1733 historical-exploit-class seeding wiring.
#
# Modeled directly on demo-invariant-audit-seed.sh's source-guard style: this is a SOURCE-GUARD +
# (conditionally) BEHAVIOURAL demo, always CI-safe with no live LLM/forge involved.
#
# It asserts:
#   1) the curated library (auditor/methods/historical-exploits.md) has exactly 7 real METHOD| entries, each
#      with 6 pipe-delimited fields and a class field matching C[0-9]+, and the 7 expected class ids are each
#      present EXACTLY ONCE (catches an accidental class-key collision at authoring time — a second entry for
#      an already-seeded class would silently overwrite the first when memo-set is applied).
#   2) the seeder script (seed-historical-patterns.sh) exists, is executable, and its wiring is intact: the
#      invpat:invented: memo-key prefix, the agentis memo set call, and the EXACT class-extraction pipeline
#      (cut -d'|' -f3 | cut -d',' -f1 | tr -d '[:space:]') run-autonomous-hunt.sh's --method-fixture leg
#      already uses — and that its usage-error paths (missing agentis / unreadable library / missing
#      --pattern-store) are hard, non-zero-exit failures, not silent no-ops.
#   3) BEHAVIOURAL (only if `agentis` is on PATH; SKIP that leg cleanly, exit 0 overall, if absent, mirroring
#      the demo-pattern-memory.sh / colony-lint.sh "0 failures, N skipped" convention): seeds a throwaway
#      pattern-store, asserts SEEDED-COUNT|7, and reads back `invpat:invented:C8` (the combined
#      classic+read-only reentrancy entry) verbatim via `agentis memo get`.
#
# Usage:  dark-factory/demo-historical-patterns.sh
# Exit: 0 = all assertions hold (or the behavioural leg cleanly SKIPped) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBRARY="$HERE/auditor/methods/historical-exploits.md"
SEEDER="$HERE/seed-historical-patterns.sh"

FAILS=0
note() { echo "demo-historical-patterns.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$LIBRARY" ] || { note "library not found: $LIBRARY" >&2; exit 3; }
[ -f "$SEEDER" ]  || { note "seeder script not found: $SEEDER" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) LIBRARY SOURCE-GUARD — schema shape + class coverage + collision-freedom.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1733 historical-exploits.md library ..."

METHOD_LINES="$(grep -E '^METHOD\|' "$LIBRARY" || true)"
N_LINES="$(printf '%s\n' "$METHOD_LINES" | grep -c '^METHOD\|' || true)"

if [ "$N_LINES" -eq 7 ]; then
  ok "the library has exactly 7 METHOD| entries"
else
  bad "the library has $N_LINES METHOD| entries (expected 7)"
fi

FIELD_FAIL=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  n_fields="$(printf '%s' "$line" | awk -F'|' '{print NF}')"
  if [ "$n_fields" -ne 6 ]; then
    bad "entry does not have 6 pipe-delimited fields ($n_fields): $line"
    FIELD_FAIL=1
  fi
  class_field="$(printf '%s' "$line" | cut -d'|' -f3)"
  case "$class_field" in
    C[0-9]*) : ;;
    *) bad "entry's class field does not match C[0-9]+: '$class_field' in: $line"; FIELD_FAIL=1 ;;
  esac
done <<EOF
$METHOD_LINES
EOF
[ "$FIELD_FAIL" -eq 0 ] && ok "every entry has 6 pipe-delimited fields and a class field matching C[0-9]+"

EXPECTED_CLASSES="C1 C2 C5 C6 C8 C11 C16"
CLASSES_SEEN="$(printf '%s\n' "$METHOD_LINES" | cut -d'|' -f3)"
COLLISION_FAIL=0
for c in $EXPECTED_CLASSES; do
  n="$(printf '%s\n' "$CLASSES_SEEN" | grep -c "^${c}\$" || true)"
  if [ "$n" -eq 1 ]; then
    :
  elif [ "$n" -eq 0 ]; then
    bad "expected class $c is missing from the library"; COLLISION_FAIL=1
  else
    bad "class $c appears $n times (a class-key collision — memo set would overwrite)"; COLLISION_FAIL=1
  fi
done
# any class present that ISN'T in the expected set is also worth flagging (unexpected coverage growth without
# updating this demo's expectation list).
UNEXPECTED="$(printf '%s\n' "$CLASSES_SEEN" | while IFS= read -r c; do
  [ -n "$c" ] || continue
  case " $EXPECTED_CLASSES " in *" $c "*) ;; *) echo "$c" ;; esac
done)"
if [ -n "$UNEXPECTED" ]; then
  bad "unexpected class id(s) in the library not in this demo's expectation list: $UNEXPECTED"
  COLLISION_FAIL=1
fi
[ "$COLLISION_FAIL" -eq 0 ] && ok "all 7 expected classes ($EXPECTED_CLASSES) are present exactly once, no collisions"

# ----------------------------------------------------------------------------------------------------------
# 2) SEEDER WIRING SOURCE-GUARD.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1733 seed-historical-patterns.sh wiring ..."

[ -x "$SEEDER" ] && ok "seed-historical-patterns.sh is executable" || bad "seed-historical-patterns.sh is not executable"

if grep -q 'invpat:invented:' "$SEEDER"; then
  ok "the seeder targets the invpat:invented: memo-key prefix"
else
  bad "the seeder does not reference invpat:invented:"
fi

if grep -q '"\$AGENTIS" memo set "invpat:invented:\$M_CLASS" "\$M_LINE"' "$SEEDER"; then
  ok "the seeder calls agentis memo set with the class-keyed name and the raw METHOD| line"
else
  bad "the seeder's agentis memo set call is missing or changed shape"
fi

if grep -q "cut -d'|' -f3 | cut -d',' -f1 | tr -d '\[:space:\]'" "$SEEDER"; then
  ok "the seeder uses the EXACT class-extraction pipeline run-autonomous-hunt.sh's --method-fixture leg uses"
else
  bad "the seeder's class-extraction pipeline does not match the exact cut/cut/tr chain"
fi

if grep -q -- '--pattern-store is required' "$SEEDER" \
   && grep -q -- 'agentis binary not found' "$SEEDER" \
   && grep -q -- '--library not readable' "$SEEDER"; then
  ok "missing --pattern-store / missing agentis / unreadable --library are hard usage errors in source"
else
  bad "one or more hard usage-error paths are missing from the seeder source"
fi

# ----------------------------------------------------------------------------------------------------------
# 2b) BEHAVIOURAL — hard-error exit codes, reachable OFFLINE (no agentis dependency for these).
# ----------------------------------------------------------------------------------------------------------
note "behavioural: seeder usage errors exit non-zero ..."

ec=0
"$SEEDER" >/dev/null 2>&1 || ec=$?
[ "$ec" -ne 0 ] && ok "missing --pattern-store -> exit $ec (non-zero, hard error)" || bad "missing --pattern-store did not error"

ec=0
WORK_NOAG="$(mktemp -d "${TMPDIR:-/tmp}/demo-historical-patterns-noag.XXXXXX")"
"$SEEDER" --pattern-store "$WORK_NOAG/ps" --agentis /no/such/agentis-binary >/dev/null 2>&1 || ec=$?
rm -rf "$WORK_NOAG"
[ "$ec" -ne 0 ] && ok "missing agentis binary -> exit $ec (non-zero, hard error)" || bad "missing agentis binary did not error"

ec=0
WORK_ERR="$(mktemp -d "${TMPDIR:-/tmp}/demo-historical-patterns-err.XXXXXX")"
"$SEEDER" --pattern-store "$WORK_ERR/ps" --library "$WORK_ERR/does-not-exist.md" >/dev/null 2>&1 || ec=$?
rm -rf "$WORK_ERR"
[ "$ec" -ne 0 ] && ok "unreadable --library -> exit $ec (non-zero, hard error)" || bad "unreadable --library did not error"

# ----------------------------------------------------------------------------------------------------------
# 3) BEHAVIOURAL SEEDING — gated on `agentis` being on PATH; SKIP cleanly (exit 0 overall) if absent.
# ----------------------------------------------------------------------------------------------------------
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the agentis runtime to run the behavioural seeding leg"
else
  note "behavioural: seeding a throwaway pattern-store and reading back invpat:invented:C8 ..."
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-historical-patterns.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT

  SEED_OUT="$("$SEEDER" --pattern-store "$WORK/ps" --library "$LIBRARY" 2>&1)"; SEED_RC=$?
  if [ "$SEED_RC" -eq 0 ]; then
    ok "seed-historical-patterns.sh exited 0"
  else
    bad "seed-historical-patterns.sh exited $SEED_RC"
    printf '%s\n' "$SEED_OUT"
  fi

  if printf '%s\n' "$SEED_OUT" | grep -q '^SEEDED-COUNT|7$'; then
    ok "SEEDED-COUNT|7 (all 7 classes seeded)"
  else
    bad "SEEDED-COUNT|7 not found in seeder output"
    printf '%s\n' "$SEED_OUT"
  fi

  GOT_C8="$(cd "$WORK/ps" && agentis memo get invpat:invented:C8 2>/dev/null || true)"
  EXPECT_C8="$(grep -E '^METHOD\|reentrancy-classic-readonly\|C8\|' "$LIBRARY" || true)"
  if [ -n "$EXPECT_C8" ] && [ "$GOT_C8" = "$EXPECT_C8" ]; then
    ok "agentis memo get invpat:invented:C8 returns the reentrancy line verbatim"
  else
    bad "invpat:invented:C8 read-back did not match the library line"
    note "  got:      $GOT_C8"
    note "  expected: $EXPECT_C8"
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #1733 historical-exploit-class library is schema-valid, collision-free, and its seeder"
  note "      wiring (invpat:invented: keying, the exact class-extraction pipeline, hard usage-error paths)"
  note "      holds; where agentis is available, a throwaway store was seeded end-to-end and read back."
  exit 0
fi
note "DEMO FAILED — a #1733 historical-exploit seeding assertion did not hold" >&2
exit 1
