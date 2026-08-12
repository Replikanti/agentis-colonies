#!/usr/bin/env bash
# refute-corpus-coverage.sh — the OFFLINE coverage gate that decides whether a refute-constraint corpus can
# even in principle move a held-out target's rare-bug recall BEFORE any expensive derivation / A/B is spent
# (issue #1895; the precheck the #1887 notional->yieldoor null would have failed for ~7h of compute saved).
#
# It computes the TRIPLE intersection
#
#   { union of derivation-corpus classes }  ∩  { held-out hunted classes }  ∩  { held-out rare(1-2) GT classes }
#
# and prints `COVERAGE-GATE: GO` IFF that set is non-empty (and therefore, by construction, contains at least
# one class carrying a `found-by <= --rare-max` GT row on the held-out — the only classes on which the primary
# metric can actually move). Otherwise it prints `COVERAGE-GATE: NO-GO`, names the EMPTY LEG, and exits
# non-zero. A hunter injects constraints CLASS-FILTERED, so a corpus can influence a held-out target only where
# derivation-classes ∩ held-out-hunted ∩ held-out-rare-GT ≠ ∅; a single-target-derived corpus is
# class-idiosyncratic and need not overlap another target's money classes (the #1887 finding).
#
# All inputs are CHEAP and checked-in / archived — no network, no LLM:
#   * derivation classes come from the refute-derivation manifests (`cut -d'|' -f2`, `class=` prefix tolerated)
#     or, for a not-yet-hunted target, its predicted classes as a literal CSV;
#   * held-out hunted classes come from field 4 (the class-csv) of a `map-zones` scope.tsv (`ZONE|id|name|
#     class-csv|desc`);
#   * held-out rare-GT classes come from a class-tagged truth.tsv (`id<TAB>found-by<TAB>class-csv<TAB>label`),
#     keeping the rows with `found-by <= --rare-max`. The class tag is the human-checkable `bug-taxonomy.md`
#     assignment (as in bug-class-coverage.md) materialised into a column — this probe never re-derives it.
# The one non-free precheck input the CALLER must produce (outside this probe) is a single `map-zones.sh` pass
# on the held-out (one LLM call per zone, no discovery/refute/forge) — an order of magnitude cheaper than a
# hunt, and what turns the class profiles this probe compares from a guess into data.
#
# NOT an `.ag` agent (a plain contributor probe), so #1587 substrate-purity does not apply; python3 is used
# only at the TSV/set boundary, exactly like the sibling refute-to-knowledge.sh feeder.
#
# Usage: refute-corpus-coverage.sh --derivation <id>=<manifest|classes-csv> [--derivation ...]
#                                  --held-out-scope <scope.tsv> --held-out-truth <truth.tsv>
#                                  [--rare-max <N>] [--self-test] [-h]
#   --derivation <id>=<src>  A derivation source (repeatable). <src> is EITHER a path to a refute-derivation
#                            manifest (pipe-delimited, class in field 2, a leading `class=` tolerated) OR a
#                            literal comma-separated class list (e.g. `plaza=C2,C1,C6,C10,C16` for a target
#                            whose classes are predicted, not yet refuted). The <id>= prefix is a label only.
#   --held-out-scope <tsv>   The held-out target's `map-zones` scope.tsv; hunted classes = ∪ of field 4.
#   --held-out-truth <tsv>   The held-out target's class-tagged truth.tsv; rare-GT classes = ∪ of the class
#                            column over rows with `found-by <= --rare-max`.
#   --rare-max <N>           The rare-recall rarity threshold (default 2, the corpus-bench `rare(1-2)` bucket).
#   --self-test              Run the CI-safe fixture suite (no network / no LLM) and exit 0 iff all cases hold.
#   -h                       Help.
# Exit: 0 = COVERAGE-GATE: GO ; 1 = COVERAGE-GATE: NO-GO ; 2 = bad args ; 3 = missing prerequisite (python3).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

DERIVS=""          # newline-delimited `id=src` entries
SCOPE=""
TRUTH=""
RARE_MAX="2"
SELFTEST=0

die() { echo "refute-corpus-coverage.sh: $*" >&2; exit 2; }
nv()  { [ "$1" -ge 2 ] || die "$2 requires a value"; }

while [ $# -gt 0 ]; do case "$1" in
  --derivation)     nv "$#" "$1"; DERIVS="$DERIVS
$2"; shift 2;;
  --held-out-scope) nv "$#" "$1"; SCOPE="$2"; shift 2;;
  --held-out-truth) nv "$#" "$1"; TRUTH="$2"; shift 2;;
  --rare-max)       nv "$#" "$1"; RARE_MAX="$2"; shift 2;;
  --self-test)      SELFTEST=1; shift;;
  -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0;;
  *) die "unknown arg: $1";;
esac; done

command -v python3 >/dev/null 2>&1 || { echo "refute-corpus-coverage.sh: python3 not installed" >&2; exit 3; }

# --------------------------------------------------------------------------------------------------------------
# --self-test: three fixtures under fixtures/refute-corpus-coverage/ pin the exact thing that must gate compute.
# --------------------------------------------------------------------------------------------------------------
if [ "$SELFTEST" -eq 1 ]; then
  FX="$HERE/fixtures/refute-corpus-coverage"
  [ -d "$FX" ] || { echo "refute-corpus-coverage.sh: fixtures dir not found: $FX" >&2; exit 3; }
  FAILS=0
  st_ok()  { echo "  [PASS] $*"; }
  st_bad() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

  # (a) GO: a non-empty C2 intersection carrying an fb<=2 held-out row.
  out_a="$("$0" --derivation "notional=$FX/go/derivation.manifest" \
                --held-out-scope "$FX/go/scope.tsv" --held-out-truth "$FX/go/truth.tsv" 2>&1)"; rc_a=$?
  if [ "$rc_a" -eq 0 ] && printf '%s\n' "$out_a" | grep -q '^COVERAGE-GATE: GO$' \
     && printf '%s\n' "$out_a" | grep -q 'TRIPLE INTERSECTION: {C2}'; then
    st_ok "(a) GO case: non-empty C2 triple carrying an fb<=2 row -> GO, exit 0"
  else
    st_bad "(a) expected GO+exit0 with a {C2} triple (rc=$rc_a)"; printf '%s\n' "$out_a" | sed 's/^/      /'
  fi

  # (b) NO-GO reproducing #1887: notional classes vs a yieldoor C20/C19 scope. The only derivation∩hunted
  #     overlap is C15, on which yieldoor has no rare GT, so the triple is empty and the leg is named.
  out_b="$("$0" --derivation "notional=C2,C15,C21,C22,C23" \
                --held-out-scope "$FX/nogo-1887/scope.tsv" --held-out-truth "$FX/nogo-1887/truth.tsv" 2>&1)"; rc_b=$?
  if [ "$rc_b" -ne 0 ] && printf '%s\n' "$out_b" | grep -q '^COVERAGE-GATE: NO-GO$' \
     && printf '%s\n' "$out_b" | grep -q '^EMPTY LEG: '; then
    st_ok "(b) #1887 repro: notional classes vs yieldoor C20/C19 scope -> NO-GO, names the empty leg, exit $rc_b"
  else
    st_bad "(b) expected NO-GO+nonzero exit naming the empty leg (rc=$rc_b)"; printf '%s\n' "$out_b" | sed 's/^/      /'
  fi

  # (c) NO-GO hunted-but-not-rare-GT: the corpus∩hunted overlap exists but only on fb>=3 classes, so the
  #     "the triple must include an fb<=rare-max class" clause fires.
  out_c="$("$0" --derivation "corpus=C2,C6" \
                --held-out-scope "$FX/nogo-not-rare/scope.tsv" --held-out-truth "$FX/nogo-not-rare/truth.tsv" 2>&1)"; rc_c=$?
  if [ "$rc_c" -ne 0 ] && printf '%s\n' "$out_c" | grep -q '^COVERAGE-GATE: NO-GO$' \
     && printf '%s\n' "$out_c" | grep -q 'carries no found-by'; then
    st_ok "(c) hunted-but-not-rare-GT: overlap only on fb>=3 classes -> NO-GO, exit $rc_c"
  else
    st_bad "(c) expected NO-GO+nonzero exit on the fb-threshold clause (rc=$rc_c)"; printf '%s\n' "$out_c" | sed 's/^/      /'
  fi

  if [ "$FAILS" -eq 0 ]; then
    echo "refute-corpus-coverage.sh: --self-test PASS (3/3 coverage-gate cases held)"
    exit 0
  fi
  echo "refute-corpus-coverage.sh: --self-test FAIL ($FAILS case(s) regressed)" >&2
  exit 1
fi

# --------------------------------------------------------------------------------------------------------------
# Normal (gate) mode: collect the three class token streams, then decide + render in one python pass.
# --------------------------------------------------------------------------------------------------------------
[ -n "$DERIVS" ]  || die "at least one --derivation <id>=<manifest|classes-csv> is required"
[ -n "$SCOPE" ]   || die "--held-out-scope <scope.tsv> is required"
[ -n "$TRUTH" ]   || die "--held-out-truth <truth.tsv> is required"
[ -f "$SCOPE" ]   || die "held-out scope not found: $SCOPE"
[ -f "$TRUTH" ]   || die "held-out truth not found: $TRUTH"
case "$RARE_MAX" in ''|*[!0-9]*) die "--rare-max must be a non-negative integer: $RARE_MAX";; esac

DTMP="$(mktemp "${TMPDIR:-/tmp}/rcc-deriv.XXXXXX")"
trap 'rm -f "$DTMP"' EXIT

# Resolve each --derivation source into a stream of raw class tokens on $DTMP. A manifest is a file (class in
# field 2, `class=` prefix tolerated); anything else is a literal comma-separated class list. A named-but-
# missing manifest is a hard error — a silent empty derivation would flip a real NO-GO into a false GO.
printf '%s\n' "$DERIVS" | while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  src="${entry#*=}"           # strip the `id=` label
  if [ -f "$src" ]; then
    cut -d'|' -f2 "$src" >> "$DTMP"
  else
    case "$src" in
      */*) echo "refute-corpus-coverage.sh: derivation manifest not found: $src" >&2; exit 2;;
      *)   printf '%s\n' "$src" | tr ',' '\n' >> "$DTMP";;
    esac
  fi
done
# `while | read` runs in a subshell; a manifest-not-found there cannot set our exit, so re-check the guard.
printf '%s\n' "$DERIVS" | while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  src="${entry#*=}"
  case "$src" in
    */*) [ -f "$src" ] || { echo "refute-corpus-coverage.sh: derivation manifest not found: $src" >&2; exit 2; };;
  esac
done || exit 2

python3 - "$DTMP" "$SCOPE" "$TRUTH" "$RARE_MAX" <<'PY'
import sys, re

deriv_path, scope_path, truth_path, rare_max = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

CLASS_RE = re.compile(r'^C[0-9]+$')

def norm(tok):
    tok = tok.strip()
    if tok[:6].lower() == "class=":
        tok = tok[6:].strip()
    tok = tok.upper()
    return tok if CLASS_RE.match(tok) else None

def classes_from_csv(field):
    out = set()
    for t in field.split(","):
        n = norm(t)
        if n:
            out.add(n)
    return out

# 1) Derivation-corpus classes: one raw token per line (already `cut -d'|' -f2` for manifests / split for CSV).
D = set()
with open(deriv_path, encoding="utf-8") as fh:
    for line in fh:
        n = norm(line)
        if n:
            D.add(n)

# 2) Held-out hunted classes: field 4 (class-csv) of a `ZONE|id|name|class-csv|desc` scope.tsv.
H = set()
with open(scope_path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) < 4:
            continue
        H |= classes_from_csv(parts[3])

# 3) Held-out rare(<=rare_max) GT classes: class column of a `id<TAB>found-by<TAB>class-csv<TAB>label` truth.tsv,
#    keeping only rows whose found-by count is <= rare_max (the corpus-bench rare-recall bucket).
R = set()
with open(truth_path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        fb_raw = parts[1].strip()
        if not fb_raw.isdigit():
            continue
        if int(fb_raw) <= rare_max:
            R |= classes_from_csv(parts[2])

def fmt(s):
    return " ".join(sorted(s, key=lambda c: int(c[1:]))) if s else "(none)"

def braces(s):
    return "{" + ",".join(sorted(s, key=lambda c: int(c[1:]))) + "}" if s else "{}"

triple = D & H & R

# Coverage matrix over every class that appears in ANY leg.
print("COVERAGE MATRIX (class | in-corpus | held-out-hunts | held-out-rare-GT)")
for c in sorted(D | H | R, key=lambda c: int(c[1:])):
    print("  %-5s | %-3s | %-3s | %-3s" % (
        c,
        "yes" if c in D else "no",
        "yes" if c in H else "no",
        "yes" if c in R else "no",
    ))
print("DERIVATION-CORPUS CLASSES: %s" % fmt(D))
print("HELD-OUT HUNTED CLASSES: %s" % fmt(H))
print("HELD-OUT RARE(<=%d) GT CLASSES: %s" % (rare_max, fmt(R)))
print("TRIPLE INTERSECTION: %s" % braces(triple))

if triple:
    print("COVERAGE-GATE: GO")
    sys.exit(0)

# NO-GO: name the FIRST empty leg, most-specific last.
if not D:
    leg = "derivation-corpus classes (no --derivation source contributed a class)"
elif not H:
    leg = "held-out hunted classes (the scope.tsv named no class in field 4)"
elif not R:
    leg = "held-out rare(<=%d) GT classes (no truth row with found-by <= %d)" % (rare_max, rare_max)
elif not (D & H):
    leg = "derivation ∩ held-out-hunted — the corpus shares no class with what the held-out hunts %s vs %s" % (
        braces(D), braces(H))
else:
    leg = "the derivation∩hunted overlap %s carries no found-by <= %d held-out GT row (rare-GT classes are %s)" % (
        braces(D & H), rare_max, braces(R))
print("EMPTY LEG: %s" % leg)
print("COVERAGE-GATE: NO-GO")
sys.exit(1)
PY
