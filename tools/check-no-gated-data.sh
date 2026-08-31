#!/bin/bash
# check-no-gated-data.sh — repo-level leak guard for the grand-rounds federation.
#
# The one unrecoverable failure mode for grand-rounds is committing gated
# clinical data (or anything derived from it: a VCF/FASTQ, the clinical .docx,
# an HPO id, a proband/sample name). This guard runs on CI (where the agentis
# runtime is absent by design) and greps the TRACKED tree for anything that
# must never be committed.
#
#   --static   scan the tracked tree only: forbidden extensions, any concrete
#              `HP:<7 digits>` literal, absolute home paths, and the SDLC
#              content-rule needles (internal paths / customer names).
#   (default)  --static PLUS, only when $MVA_DATA_DIR exists, runtime needles
#              built from the actual gated inputs (gated file basenames, the
#              VCF sample name, the approved HPO ids).
#
#   --root DIR scan DIR instead of this script's repo (used by the mutation
#              test, which plants a leak into a temp git tree and asserts a
#              non-zero exit — a guard that cannot fail is not a guard).
#
# Exit codes: 0 clean, 1 leak found, 2 usage.
#
# The synthetic, gated-data-free fixtures under grand-rounds/baseline/fixtures/
# are the one allowlisted exception; their purity is asserted separately by
# grand-rounds/baseline/demo-baseline.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="full"
ROOT="$DEFAULT_ROOT"
while [ $# -gt 0 ]; do
    case "$1" in
        --static) MODE="static"; shift ;;
        --root) ROOT="${2:?--root needs a directory}"; shift 2 ;;
        -h|--help)
            echo "Usage: check-no-gated-data.sh [--static] [--root DIR]"
            exit 0
            ;;
        *) echo "check-no-gated-data.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# An exported GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE retargets every git
# command below at ANOTHER repository: the guard then scans that one and
# pronounces THIS tree clean. demo-baseline.sh unsets these for itself and this
# script did not, so invoking it directly under such an environment reported a
# tree carrying a planted HP id as clean, rc 0.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(cd "$ROOT" && pwd)"
# The fixtures allowlist is now expressed ONLY as the `case` in the extension
# loop below. The pathspec variables that used to exempt them from the content
# needles are gone: those needles deliberately scan the fixtures, because a real
# HP id in phenotype-source.txt or a coordinate in README.md used to pass, and
# demo-baseline.sh's purity check covers only *.vcf and mini.fa.
leaks=0
report() { echo "[LEAK] $1" >&2; leaks=$((leaks + 1)); }

# Tracked files, NUL-safe, honouring the git index of $ROOT.
tracked() { git -C "$ROOT" ls-files -z; }

# A guard that cannot READ the tree must refuse, not reassure. `git ls-files`
# exits non-zero (or returns nothing) when git declines the directory —
# safe.directory / "dubious ownership" on a bind-mounted or shared checkout, a
# linked worktree whose gitfile dangles, a missing index. Every scan below is
# driven by that listing, so in those cases the guard previously walked ZERO
# files and printed "clean" over a tree containing a real leak. Verified: a
# planted HP id under GIT_TEST_ASSUME_DIFFERENT_OWNER=1 reported clean, exit 0.
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "check-no-gated-data: FATAL — git will not open a repository at $ROOT," >&2
    echo "  so no file can be scanned. Refusing to report a tree clean that was" >&2
    echo "  never read. If this is an ownership refusal, add it to safe.directory." >&2
    exit 2
fi
if ! git -C "$ROOT" ls-files >/dev/null 2>&1; then
    echo "check-no-gated-data: FATAL — cannot list tracked files in $ROOT." >&2
    exit 2
fi
# Erroring is not the only way to scan nothing. A BARE repository answers both
# checks above successfully and lists zero files, so the guard would walk an
# empty set and pronounce a full history clean — the same false pass, reached a
# different way. Any tree worth guarding has tracked files.
if [ -z "$(git -C "$ROOT" ls-files | head -1)" ]; then
    echo "check-no-gated-data: FATAL — $ROOT has no tracked files (bare repo, or" >&2
    echo "  an empty index). Nothing would be scanned, so reporting it clean would" >&2
    echo "  be meaningless." >&2
    exit 2
fi

# --- 1. Forbidden extensions (outside the fixtures allowlist) ----------------
# Gated data file types that must never be committed anywhere but fixtures/.
forbidden_re='\.(vcf|bcf|fastq|fq|bam|cram|docx|gtf|fa|fna|fai|obo)(\.[A-Za-z0-9]+)?$'
while IFS= read -r -d '' f; do
    case "$f" in
        # The fixtures exemption is a NAMED allowlist, not a blanket one. It
        # used to be `fixtures/*`, so anything dropped in that directory —
        # exactly where a test input naturally lands — bypassed the extension
        # check entirely: a planted clinical.docx, proband.bam and an .obo
        # carrying a real HP id all passed as clean. These five files are the
        # synthetic set whose purity demo-baseline.sh asserts separately; a
        # sixth must be added here deliberately, with the same scrutiny.
        grand-rounds/baseline/fixtures/README.md) continue ;;
        grand-rounds/baseline/fixtures/mini.fa) continue ;;
        grand-rounds/baseline/fixtures/panel.gtf) continue ;;
        grand-rounds/baseline/fixtures/phenotype-source.txt) continue ;;
        grand-rounds/baseline/fixtures/proband.vcf) continue ;;
    esac
    if printf '%s\n' "$f" | grep -qiE "$forbidden_re"; then
        report "forbidden gated-data extension tracked: $f"
    fi
done < <(tracked)

# --- 2. Concrete HPO id literal (HP: followed by exactly 7 digits) -----------
# A real HPO id in a tracked file is a derived-from-gated-data leak. The
# synthetic fixtures carry none; source files reference the PATTERN
# `HP:[0-9]{7}`, which is not a concrete id and does not match.
# --- genomic coordinates -----------------------------------------------
# Derived artifacts the pipeline itself writes (refuted.tsv, panel-review.tsv,
# a renamed submission CSV) carry GRCh38 coordinates and no forbidden
# extension, so nothing here caught them: staged into a checkout they scanned
# as clean. The repo's own rule is "never a variant, a coordinate, an HPO id",
# and coordinates had no needle at all. Measured against the tracked tree at
# the time of writing this matches nothing, so it costs no false positives.
#
# The separator class MUST include the comma: the pipeline's primary deliverable
# is a CSV (`proband_id,chrom_1,pos_1,...`, i.e. a chr token and a position in
# adjacent comma-separated fields), so a needle without the comma missed the
# single most likely artifact to be committed by accident. Digits allow embedded
# commas too, for the thousands-separated form a genome-browser copy-paste
# produces, and the chr prefix is matched case-insensitively.
#
# NOTE: this comment deliberately carries no literal coordinate. The needle
# scans this file too, and an example here would flag the guard itself — the
# same reason demo-baseline.sh assembles its planted HP id from fragments.
if git -C "$ROOT" grep -nIE '\b[Cc][Hh][Rr][0-9XYMxym]{1,2}[:_,;|[:space:]-][0-9][0-9,]{3,}' -- . >/dev/null 2>&1; then
    git -C "$ROOT" grep -nIE '\b[Cc][Hh][Rr][0-9XYMxym]{1,2}[:_,;|[:space:]-][0-9][0-9,]{3,}' -- . >&2 || true
    report "a genomic coordinate (chr<N>:<pos>) appears in a tracked file"
fi

if git -C "$ROOT" grep -nIE 'HP:[0-9]{7}' -- . >/dev/null 2>&1; then
    git -C "$ROOT" grep -nIE 'HP:[0-9]{7}' -- . >&2 || true
    report "concrete HPO id (HP:<7 digits>) found in a tracked file"
fi

# --- 3. Absolute home paths --------------------------------------------------
# This guard and its callers use \$HOME, never a literal home path.
if git -C "$ROOT" grep -nIE '(/home/[a-z]|/Users/[A-Za-z])' -- . ':!tools/check-no-gated-data.sh' >/dev/null 2>&1; then
    git -C "$ROOT" grep -nIE '(/home/[a-z]|/Users/[A-Za-z])' -- . ':!tools/check-no-gated-data.sh' >&2 || true
    report "absolute home path found in a tracked file"
fi

# --- 4. SDLC content-rule needles (internal paths / customer names) ----------
# The needles are assembled from fragments so the literal strings never appear
# in this file (avoiding self-match and a false positive in the staged-diff
# content check).
n1="$(printf '%s' 'avv')$(printf '%s' 'oka')"
n2="$(printf '%s' 'the_')$(printf '%s' 'factory')"
for needle in "$n1" "$n2" 'gitlab.'"$n1"; do
    if git -C "$ROOT" grep -niF "$needle" -- . ':!tools/check-no-gated-data.sh' >/dev/null 2>&1; then
        report "SDLC content-rule needle found in a tracked file: <redacted>"
    fi
done

# --- 5. Runtime needles from the actual gated inputs (full mode only) --------
if [ "$MODE" = "full" ] && [ -n "${MVA_DATA_DIR:-}" ] && [ -d "${MVA_DATA_DIR:-/nonexistent}" ]; then
    # Gated file basenames.
    while IFS= read -r base; do
        [ -n "$base" ] || continue
        if git -C "$ROOT" grep -nIF "$base" -- . >/dev/null 2>&1; then
            report "gated input basename appears in a tracked file"
        fi
    done < <(ls -1 "$MVA_DATA_DIR" 2>/dev/null)

    # VCF sample name(s).
    bcftools_bin="${MVA_BCFTOOLS:-bcftools}"
    for vcf in "$MVA_DATA_DIR"/*.vcf.gz; do
        [ -f "$vcf" ] || continue
        while IFS= read -r sample; do
            [ -n "$sample" ] || continue
            if git -C "$ROOT" grep -nIF "$sample" -- . >/dev/null 2>&1; then
                report "proband/sample name appears in a tracked file"
            fi
        done < <("$bcftools_bin" query -l "$vcf" 2>/dev/null || true)
    done

    # Approved HPO ids.
    approval="${MVA_APPROVAL_FILE:-${MVA_WORK_DIR:-$HOME/.mva-hackathon/work}/phenotype/hpo-draft.txt}"
    if [ -f "$approval" ]; then
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            if git -C "$ROOT" grep -nIF "$id" -- . >/dev/null 2>&1; then
                report "approved HPO id appears in a tracked file"
            fi
        done < <(grep -oE 'HP:[0-9]{7}' "$approval" 2>/dev/null || true)
    fi
fi

if [ "$leaks" -ne 0 ]; then
    echo "check-no-gated-data: $leaks leak(s) found" >&2
    exit 1
fi
echo "check-no-gated-data: clean ($MODE mode, root $ROOT)"
exit 0
