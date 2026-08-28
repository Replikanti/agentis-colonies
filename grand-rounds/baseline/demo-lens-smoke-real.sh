#!/bin/bash
# demo-lens-smoke-real.sh — REAL-backend smoke test for the M3 lens federation
# (#2046).
#
# demo-baseline-live.sh runs the real agents but with NO LLM backend wired, so
# every prompt() returns near-instantly and it can NEVER catch a real-backend
# latency regression. That fidelity gap let #2046 (llm.cli_timeout_ms too low —
# every heavy lens prompt aborted with [llm.timeout] on flat-cyborg) pass a
# green live test. This script is the missing gate: it runs MVA_LENS_MODE=1
# end-to-end against the OPERATOR'S OWN baseline/.agentis/config (i.e. the real
# backend install.sh + the operator wired), with the candidate pool restricted
# to a SINGLE gene, and FAILS on any [llm.timeout] abort or missing lens CSV.
#
# Operator-run ONLY — never CI, never network-fetching. Prerequisites (SKIPs
# loudly when missing): agentis + zip, bcftools (native or the pinned local
# biocontainer), and a real LLM backend wired in baseline/.agentis/config
# (llm.backend / llm.command; llm.backend = mock does not count). Even with a
# single candidate this makes ~8 real LLM calls (phenotype + panel + 5 lenses +
# refute), so expect ~10–60+ minutes wall time on flat-cyborg.
#
# Exit 0 all pass (or SKIP), 1 a check failed.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="$BASE_DIR/fixtures"
FED_CONFIG="$BASE_DIR/.agentis/config"

# agentis + zip are hard prerequisites (no container substitute).
missing=""
for t in agentis zip; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
    echo "[SKIP] demo-lens-smoke-real: missing prerequisite(s):$missing — operator-run only."
    exit 0
fi

# A real backend must be wired by the operator: install.sh writes the timeout
# keys, but the backend choice (flat-cyborg / claude wrapper) is the
# operator's. Without one this smoke would just re-run the mock path the live
# test already covers, proving nothing.
if [ ! -f "$FED_CONFIG" ]; then
    echo "[SKIP] demo-lens-smoke-real: $FED_CONFIG not found — run ../install.sh and wire an LLM backend (doc/llm-backend.md)."
    exit 0
fi
backend_line="$(grep -E '^[[:space:]]*llm\.(backend|command)[[:space:]]*=' "$FED_CONFIG" | grep -v '=[[:space:]]*mock[[:space:]]*$' | head -1 || true)"
if [ -z "$backend_line" ]; then
    echo "[SKIP] demo-lens-smoke-real: no real LLM backend in $FED_CONFIG (llm.backend/llm.command absent or mock) — wire flat-cyborg first (doc/llm-backend.md)."
    exit 0
fi
if ! grep -qE '^[[:space:]]*exec\.env_passthrough[[:space:]]*=.*MVA_DATA_DIR' "$FED_CONFIG"; then
    echo "[SKIP] demo-lens-smoke-real: exec.env_passthrough allowlist not wired in $FED_CONFIG — run ../install.sh."
    exit 0
fi
if ! grep -qE '^[[:space:]]*llm\.cli_timeout_ms[[:space:]]*=' "$FED_CONFIG"; then
    # Deliberately NOT a skip: an unwired timeout is exactly the #2046
    # regression this smoke exists to catch — proceed and let it fail.
    echo "  (warning: llm.cli_timeout_ms missing from $FED_CONFIG — expect [llm.timeout] failures; run ../install.sh)"
fi
# A RELATIVE llm.command resolves against the run copy's cwd in /tmp and would
# fail for reasons that have nothing to do with the backend under test.
cmd_path="$(grep -E '^[[:space:]]*llm\.command[[:space:]]*=' "$FED_CONFIG" | head -1 | sed 's/^[^=]*=[[:space:]]*//' || true)"
if [ -n "$cmd_path" ]; then
    case "$cmd_path" in
        /*) : ;;
        *)
            echo "[SKIP] demo-lens-smoke-real: llm.command is a relative path ($cmd_path) — it breaks in this test's run copy; use an absolute path in $FED_CONFIG."
            exit 0
            ;;
    esac
fi
echo "  (backend: ${backend_line# })"

WORKROOT="$(mktemp -d)"
# On failure the run tree (logs, memos, CSVs) is KEPT for inspection — after a
# potentially hour-long real run, 20 tail lines are not enough post-mortem.
KEEP_WORKROOT=0
trap '[ "$KEEP_WORKROOT" = "1" ] && echo "  (run artifacts kept for inspection: $WORKROOT)" || rm -rf "$WORKROOT"' EXIT

# Resolve bcftools exactly like demo-baseline-live.sh: native, else the PINNED
# local biocontainer (never pulled over the network here).
BCFTOOLS_BIN="bcftools"
if command -v bcftools >/dev/null 2>&1; then
    :
else
    CIMG="${MVA_BCFTOOLS_IMAGE:-quay.io/biocontainers/bcftools:1.19--h8b25389_0}"
    CRUN="${MVA_CONTAINER_CMD:-}"
    if [ -z "$CRUN" ]; then
        if command -v podman >/dev/null 2>&1; then CRUN="podman"
        elif command -v docker >/dev/null 2>&1; then CRUN="docker"; fi
    fi
    if [ -z "$CRUN" ] || ! "$CRUN" image exists "$CIMG" >/dev/null 2>&1; then
        echo "[SKIP] demo-lens-smoke-real: no native bcftools and no local biocontainer ($CIMG)."
        exit 0
    fi
    TOOLBIN="$WORKROOT/toolbin"
    mkdir -p "$TOOLBIN"
    {
        printf '#!/bin/sh\n'
        printf 'exec %s run --rm -i -v "%s:%s:z" %s bcftools "$@"\n' "$CRUN" "$WORKROOT" "$WORKROOT" "$CIMG"
    } > "$TOOLBIN/bcftools"
    chmod +x "$TOOLBIN/bcftools"
    PATH="$TOOLBIN:$PATH"
    BCFTOOLS_BIN="$TOOLBIN/bcftools"
    echo "  (using containerized bcftools: $CRUN $CIMG)"
fi

pass=0; fail=0
ok() { echo "  [ok] $1"; pass=$((pass + 1)); }
bad() { echo "  [FAIL] $1" >&2; fail=$((fail + 1)); }

echo "grand-rounds/baseline: REAL-backend single-candidate lens smoke (#2046)"
echo "  (this drives ~8 real LLM prompts — expect ~10-60+ minutes)"

# --- Build a SINGLE-candidate synthetic data dir ----------------------------
# Keep only contig 15 (BUB1B, the hom-alt biallelic candidate) from the
# fixture VCF: one gene -> a pool of one -> one refute prompt, the minimum
# real-latency lens pass the #2046 gate calls for.
grep -P '^#|^15\t' "$FIX/proband.vcf" > "$WORKROOT/single.vcf"
DD="$WORKROOT/data"
mkdir -p "$DD"
cp "$WORKROOT/single.vcf" "$DD/src.vcf"
"$BCFTOOLS_BIN" view -Oz -o "$DD/proband.vcf.gz" "$DD/src.vcf" >/dev/null 2>&1
"$BCFTOOLS_BIN" index -t "$DD/proband.vcf.gz" >/dev/null 2>&1
ddoc="$WORKROOT/docx"; mkdir -p "$ddoc/word"
{
    printf '<?xml version="1.0"?><w:document xmlns:w="x"><w:body>'
    while IFS= read -r linetext; do
        printf '<w:p><w:r><w:t>%s</w:t></w:r></w:p>' "$linetext"
    done < "$FIX/phenotype-source.txt"
    printf '</w:body></w:document>'
} > "$ddoc/word/document.xml"
( cd "$ddoc" && zip -q -r "$DD/phenotype.docx" word )

# --- Build the run copy on the OPERATOR'S config ----------------------------
RUN="$WORKROOT/run"
cp -r "$BASE_DIR" "$RUN"
rm -rf "$RUN/.agentis"
OUTDIR="$RUN/out"; WORKDIR="$RUN/work"
mkdir -p "$OUTDIR" "$WORKDIR/refdata"
cp "$FIX/mini.fa" "$WORKDIR/refdata/ref.fa"
if command -v samtools >/dev/null 2>&1; then
    samtools faidx "$WORKDIR/refdata/ref.fa" >/dev/null 2>&1 || true
fi
cp "$FIX/panel.gtf" "$WORKDIR/refdata/panel.gtf"
{
    printf 'format-version: 1.2\n'
    printf '[Term]\nid: HP:%s\nname: Microcephaly\n' '0000252'
    printf '[Term]\nid: HP:%s\nname: Short stature\n' '0004322'
} > "$WORKDIR/refdata/hp.obo"
( cd "$RUN" && agentis init >/dev/null 2>&1 )
# The operator's real config — backend, llm.cli_timeout_ms, allowlist — is the
# thing under test; copy it verbatim (memos are NOT copied: fresh agentis init).
cp "$FED_CONFIG" "$RUN/.agentis/config"

export MVA_DATA_DIR="$DD" MVA_WORK_DIR="$WORKDIR" MVA_OUT_DIR="$OUTDIR"
export MVA_REF_FASTA="$WORKDIR/refdata/ref.fa" MVA_HPO_OBO="$WORKDIR/refdata/hp.obo"
export MVA_GTF="$WORKDIR/refdata/panel.gtf" MVA_BCFTOOLS="$BCFTOOLS_BIN"
export MVA_APPROVAL_FILE="$WORKDIR/phenotype/hpo-approved.txt"
export MVA_APPROACH="baseline" PANEL_PAD="10" EXOMISER_TIMEOUT_MS="1000"
export MVA_LENS_MODE="1"
export COLONY_DIR="$RUN"
# GATED-DATA HYGIENE: the operator's shell may export MVA_VCF /
# MVA_PHENOTYPE_DOC pointing at REAL clinical data, pipeline.ag PREFERS them
# over the data-dir scan, and the operator's copied config allowlists them —
# left inherited, this "synthetic-only" smoke would push real clinical content
# into LLM prompts. Neutralize everything not pinned to the fixtures above.
unset MVA_VCF MVA_PHENOTYPE_DOC MVA_PRIMARY_CONTIGS || true
export MVA_RUN_EXOMISER=0
# Reproduce start-colony.sh's real-run wrapper knobs (#2046): without them the
# tools/flat-cyborg-claude.sh defaults (idle 30 s / total 240 s) abort a heavy
# prompt long before llm.cli_timeout_ms even matters, so the gate would not be
# exercising the path the real run uses. Operator exports win.
: "${FLAT_CYBORG_TIMEOUT_MS:=1800000}"
: "${FLAT_CYBORG_IDLE_MS:=600000}"
export FLAT_CYBORG_TIMEOUT_MS FLAT_CYBORG_IDLE_MS

start_ts="$(date +%s)"
( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run1.log" 2>&1 ) || true
if [ -f "$WORKDIR/phenotype/hpo-draft.txt" ]; then
    sha256sum "$WORKDIR/phenotype/hpo-draft.txt" | cut -d' ' -f1 > "$MVA_APPROVAL_FILE"
else
    bad "no HPO draft after the first pass — tail of run1.log:"
    tail -20 "$RUN/run1.log" >&2 || true
fi
( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run2.log" 2>&1 ) || true
elapsed=$(( "$(date +%s)" - start_ts ))
echo "  (both passes done in ${elapsed}s)"

LENSCSV="$OUTDIR/agentis-federation_lens.csv"

# --- The #2046 gate: no LLM subprocess timeout anywhere ---------------------
if grep -hq 'llm\.timeout' "$RUN/run1.log" "$RUN/run2.log"; then
    bad "an LLM call timed out on the real backend (the #2046 regression):"
    grep -h 'llm\.timeout' "$RUN/run1.log" "$RUN/run2.log" | head -3 >&2
else
    ok "no [llm.timeout] across both passes"
fi

# --- No OTHER LLM failure either --------------------------------------------
# lens_score() silently falls back to its deterministic prior on an empty or
# failed reply, so the chain "completing" proves nothing by itself: a wrapper
# abort, auth failure, or empty reply still yields a schema-valid CSV — green
# while degraded to baseline-only, the exact #2046 class.
if grep -hEi 'llm' "$RUN/run1.log" "$RUN/run2.log" | grep -Eiq 'error|fail|abort'; then
    bad "an LLM call failed (non-timeout) on the real backend:"
    grep -hEi 'llm' "$RUN/run1.log" "$RUN/run2.log" | grep -Ei 'error|fail|abort' | head -3 >&2
else
    ok "no other LLM error/failure across both passes"
fi

# --- Real-latency floor -----------------------------------------------------
# ~8 real prompts cannot come back in seconds; a run this fast means a mock or
# no-op backend answered, and this gate exists precisely to not be fooled by
# that. Override the floor via GR_SMOKE_MIN_ELAPSED_S if a future backend is
# legitimately faster.
MIN_S="${GR_SMOKE_MIN_ELAPSED_S:-60}"
if [ "$elapsed" -lt "$MIN_S" ]; then
    bad "backend answered implausibly fast (${elapsed}s < ${MIN_S}s for ~8 real prompts) — mock/no-op backend? This gate requires the real one."
else
    ok "elapsed ${elapsed}s clears the real-latency floor (${MIN_S}s)"
fi

# --- The lens+refute chain actually completed on the real backend -----------
chain_ok=1
for a in lens_inheritance lens_mosaicism lens_hpo lens_known_gene lens_pathway; do
    grep -q "$a: scored" "$RUN/run2.log" || chain_ok=0
done
grep -q 'refuter:' "$RUN/run2.log" || chain_ok=0
grep -q 'lens_reconciler:' "$RUN/run2.log" || chain_ok=0
grep -q 'Verdict: LENS-EMITTED' "$RUN/run2.log" || chain_ok=0
if [ "$chain_ok" -eq 1 ]; then
    ok "five lenses + refuter + reconciler completed on the real backend"
else
    bad "the lens+refute chain did not complete — tail of run2.log:"
    tail -20 "$RUN/run2.log" >&2 || true
fi

# --- A lens-refined CSV was emitted -----------------------------------------
hdr="proband_id,chrom_1,pos_1,ref_1,alt_1,chrom_2,pos_2,ref_2,alt_2,epcr,finding_type,notes"
if [ -f "$LENSCSV" ] && [ "$(head -1 "$LENSCSV")" = "$hdr" ] \
   && [ "$(tail -n +2 "$LENSCSV" | grep -c . || true)" -ge 1 ]; then
    ok "schema-valid lens CSV emitted ($(tail -n +2 "$LENSCSV" | grep -c .) row(s))"
else
    bad "no schema-valid lens CSV at \$MVA_OUT_DIR/agentis-federation_lens.csv"
fi

echo "grand-rounds/baseline real-backend smoke: $pass ok, $fail failed"
[ "$fail" -eq 0 ] || KEEP_WORKROOT=1
[ "$fail" -eq 0 ]
