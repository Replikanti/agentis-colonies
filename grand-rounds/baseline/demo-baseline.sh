#!/bin/bash
# demo-baseline.sh — offline, CI-safe checks for the grand-rounds baseline
# colony. Pure bash over fixtures/ + source-guards on agents/pipeline.ag. No
# agentis, no network, no gated data. Exercised by tools/colony-lint.sh.
#
# What CI cannot do is EXECUTE the .ag (no agentis binary on runners), so this
# demo pins structure, the leak guard, and .ag source-shape; the .ag BEHAVIOUR
# is pinned by the operator-run demo-baseline-live.sh mutation test.
#
# Exit 0 all checks pass, 1 otherwise.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BASE_DIR/../.." && pwd)"
AG="$BASE_DIR/agents/pipeline.ag"
TMPL="$BASE_DIR/settings/exomiser-analysis.template.yml"
TOML="$BASE_DIR/config/colony.example.toml"
GUARD="$REPO_ROOT/tools/check-no-gated-data.sh"

# An exported GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE retargets every git command
# in this suite AND inside the guard it invokes: the tree scan would report
# another repository clean while claiming it was this one. Unset once, here,
# rather than per-subshell.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

pass=0
fail=0
skipped=0
ok() { echo "  [ok] $1"; pass=$((pass + 1)); }
bad() { echo "  [FAIL] $1" >&2; fail=$((fail + 1)); }
skip() { echo "  [skip] $1"; skipped=$((skipped + 1)); }

echo "grand-rounds/baseline: offline demo"

# --- 1. Leak guard is not vacuous (mutation test) --------------------------
echo "1. leak guard"
# The guard walks $ROOT's GIT INDEX, so its real-tree pass is meaningful only in
# a checkout. A released bundle is an unpacked tarball with no index: running it
# there reported a spurious failure in the privacy guard — the worst thing to
# look broken on a clinical-genomics submission — while the mutation half below
# passed vacuously because the script was not shipped at all. Skip the tree scan
# when there is no index, and say so; the mutation test still runs, because it
# builds its own git tree.
if [ ! -f "$GUARD" ]; then
    skip "leak guard: $GUARD not present (not a checkout); repo-CI enforces it"
elif [ ! -e "$REPO_ROOT/.git" ]; then
    # Test for the .git entry itself, NOT `git rev-parse --is-inside-work-tree`.
    # That command also fails when git REFUSES a directory it distrusts
    # (safe.directory / "dubious ownership" — a bind-mounted checkout owned by
    # another uid, a shared machine, a run under sudo) and for a linked worktree
    # copied away from its parent. Any of those would have silently skipped a
    # real checkout's own leak guard and still exited 0, which is a worse bug
    # than the one this block was added to fix. A `.git` entry (dir OR gitfile)
    # separates every checkout shape from an unpacked tarball, which has none.
    skip "leak guard tree scan: no .git in $REPO_ROOT (unpacked bundle); repo-CI enforces it"
else
    tree_rc=0
    bash "$GUARD" --static >/dev/null 2>&1 || tree_rc=$?
    if [ "$tree_rc" -eq 0 ]; then
        ok "check-no-gated-data --static clean on the real tracked tree"
    elif [ "$tree_rc" -eq 1 ]; then
        bad "leak guard flags the real tree (should be clean)"
    else
        # exit 2 is the guard REFUSING to scan (git distrusts the directory, a
        # bare repo, an empty index). Telling a clinical operator "you have a
        # leak" when the guard simply could not look is its own kind of harm.
        bad "leak guard could not scan the tree (exit $tree_rc) — resolve that before trusting this run"
    fi
fi

MUT="$(mktemp -d)"
trap 'rm -rf "$MUT"' EXIT
(
    cd "$MUT"
    git init -q
    git config user.email t@t; git config user.name t
    # Plant a concrete HPO id and a gated .vcf outside any fixtures/ allowlist.
    # The id is assembled at runtime (fragments) so this SOURCE file carries no
    # concrete HP:<7 digits> literal — only the planted temp tree does.
    printf 'note: HP:%s seizure\n' '0001250' > leaked-notes.txt
    printf '##fileformat=VCFv4.2\n' > proband.vcf
    # A derived artifact of the shape the pipeline itself writes: a genomic
    # coordinate in a .tsv, carrying no forbidden extension and therefore
    # invisible to the guard until the coordinate needle was added.
    printf 'gene\tchrom\tpos\nBUB1B\tchr15\t40209701\n' > refuted.tsv
    # And a file dropped into the fixtures directory, which used to be a
    # BLANKET allowlist rather than a named one.
    mkdir -p grand-rounds/baseline/fixtures
    printf '##fileformat=VCFv4.2\n' > grand-rounds/baseline/fixtures/clinical.docx
    git add -A >/dev/null 2>&1
)
# A MISSING guard must not read as a working one. `bash <nonexistent>` exits
# 127, which is non-zero, so the naive "did it fail?" form below passed
# vacuously in a bundle that never shipped the script — the exact way this
# assertion was dead for the whole life of the released tarball. Require the
# script to exist, and treat 127 as "did not run" rather than "detected a leak".
if [ ! -f "$GUARD" ]; then
    skip "leak guard mutation test: $GUARD not present (not a checkout); repo-CI enforces it"
else
    # `|| guard_rc=$?` and not a bare call: this script runs under `set -e`,
    # where a non-zero exit from the guard — the very thing being asserted —
    # would abort the whole suite.
    guard_rc=0
    bash "$GUARD" --static --root "$MUT" >/dev/null 2>&1 || guard_rc=$?
    # A CLEAN tree is the negative control. Without it "non-zero on a dirty
    # tree" is satisfied by a guard that fails on everything — a stub of
    # `exit 1`, or a real guard whose --root support broke — and in a bundle,
    # where the tree scan is skipped, nothing else would notice.
    CLEAN="$(mktemp -d)"
    ( cd "$CLEAN" && git init -q && git config user.email t@t && git config user.name t \
        && printf 'nothing to see\n' > ok.txt && git add -A >/dev/null 2>&1 )
    clean_rc=0
    bash "$GUARD" --static --root "$CLEAN" >/dev/null 2>&1 || clean_rc=$?
    rm -rf "$CLEAN"
    if [ "$guard_rc" -eq 0 ]; then
        bad "leak guard did NOT fail on a planted HP id + .vcf (a guard that cannot fail is not a guard)"
    elif [ "$guard_rc" -eq 127 ]; then
        bad "leak guard could not be executed (exit 127) — the mutation test proves nothing"
    elif [ "$guard_rc" -ne 1 ]; then
        bad "leak guard exited $guard_rc on a planted leak (expected 1) — it errored rather than detecting"
    elif [ "$clean_rc" -ne 0 ]; then
        bad "leak guard also fails on a CLEAN tree (exit $clean_rc) — it flags everything, so it proves nothing"
    else
        ok "check-no-gated-data --static fails on a planted leak and passes a clean tree"
    fi

    # Per-needle assertions. A single "it failed" cannot say WHICH rule bit, so
    # a needle that quietly stopped working would hide behind the others.
    guard_out="$(bash "$GUARD" --static --root "$MUT" 2>&1 || true)"
    if printf '%s' "$guard_out" | grep -q 'concrete HPO id'; then
        ok "leak guard: the HPO-id needle bites"
    else
        bad "leak guard: the HPO-id needle did not fire on a planted HP id"
    fi
    if printf '%s' "$guard_out" | grep -q 'genomic coordinate'; then
        ok "leak guard: the coordinate needle bites on a derived .tsv"
    else
        bad "leak guard: a chr<N> coordinate in a tracked .tsv was not flagged"
    fi
    if printf '%s' "$guard_out" | grep -q 'fixtures/clinical.docx'; then
        ok "leak guard: fixtures/ is a named allowlist, not a blanket one"
    else
        bad "leak guard: a file planted in fixtures/ bypassed the extension check"
    fi
fi

# --- 2. Fixture purity -----------------------------------------------------
echo "2. fixture purity"
for vcf in "$BASE_DIR"/fixtures/*.vcf; do
    [ -f "$vcf" ] || continue
    b="$(basename "$vcf")"
    if grep -qE '^#CHROM' "$vcf" && grep -qE '\bSAMPLE_SYNTH\b' "$vcf"; then
        ok "$b carries the synthetic sample name SAMPLE_SYNTH"
    else
        bad "$b missing synthetic sample name"
    fi
    records="$(grep -cvE '^#' "$vcf" || true)"
    if [ "$records" -lt 100 ]; then
        ok "$b has $records records (< 100)"
    else
        bad "$b has $records records (>= 100)"
    fi
    if grep -qE 'HP:[0-9]{7}' "$vcf"; then
        bad "$b contains a concrete HP: literal"
    else
        ok "$b has no HP: literal"
    fi
done
if grep -qE '^>chr' "$BASE_DIR/fixtures/mini.fa"; then
    ok "mini.fa is a synthetic mini-contig FASTA"
else
    bad "mini.fa is not a chr-prefixed synthetic FASTA"
fi

# --- 3. Source-guards on agents/pipeline.ag --------------------------------
echo "3. .ag source-guards"
for a in coordinator preprocessor phenotyper exomiser_runner panel_reviewer reconciler emitter; do
    if grep -qE "^agent $a\(\) -> void" "$AG"; then
        ok "agent $a defined"
    else
        bad "agent $a missing"
    fi
done
# Bus-wired: each stage listens and emits. Consumers read via bus_read(), the
# Void-normalizing listen() wrapper (#2044 — a raw listen() dies on the void an
# aborted producer leaves and takes the whole run's print buffer with it).
for ev in "baseline:normalized_vcf" "baseline:hpo_ids" "baseline:panel_hits" "baseline:candidates" "baseline:exomiser_tsv"; do
    if grep -qF "emit(\"$ev\"" "$AG" && grep -qF "bus_read(\"$ev\"" "$AG"; then
        ok "bus event $ev is both emitted and bus_read-consumed"
    else
        bad "bus event $ev not fully wired (emit + bus_read)"
    fi
done
# Schema validator enforces all rules.
for rule in "column-count" "chrom_1-not-chr-primary" "epcr-out-of-range" "pair-partial" "finding_type"; do
    if grep -qF "\"$rule\"" "$AG"; then
        ok "schema rule '$rule' enforced"
    else
        bad "schema rule '$rule' absent from validator"
    fi
done
for rule in "too-many-rows" "dup-key"; do
    if grep -qF "\"$rule\"" "$AG"; then
        ok "emit-stage rule '$rule' enforced"
    else
        bad "emit-stage rule '$rule' absent"
    fi
done
# failedVariantFilter is rendered EMPTY (D4) and is not an active template step.
if grep -qF '"{{FAILED_VARIANT_FILTER}}", ""' "$AG"; then
    ok "failedVariantFilter placeholder is rendered empty (D4)"
else
    bad "failedVariantFilter is not rendered empty"
fi
if grep -qE '^\s*failedVariantFilter\s*:' "$TMPL"; then
    bad "template has an ACTIVE failedVariantFilter step (must be a placeholder only)"
else
    ok "template has no active failedVariantFilter step"
fi
# #2054: the Exomiser merge is wired end-to-end — the runner emits the TSV,
# the reconciler consumes it, and the min-score knob routes the tier.
for tok in 'exomiser_tsv_path' 'exomiser_candidates(' 'phenotype_novel_gene_min_score'; do
    if grep -qF "$tok" "$AG"; then
        ok "Exomiser merge marker '$tok' present (#2054)"
    else
        bad "Exomiser merge marker '$tok' missing from the .ag (#2054 regression)"
    fi
done
# #2056: the benign axis must read a POPULATION-semantics tag, never caller AF.
if grep -qF 'benign_af_info_tag' "$AG" && ! grep -qF '%INFO/AF' "$AG"; then
    ok "benign axis reads the configurable population tag, not caller INFO/AF (#2056)"
else
    bad "benign axis reads caller INFO/AF again (#2056 regression)"
fi
# #2059: representative selection is Exomiser-evidence-driven and never
# suppresses a representation; the alt tier must exist in the ladder.
for tok in 'pick_rep(' 'first_by_exo(' 'alt_representation'; do
    if grep -qF "$tok" "$AG"; then
        ok "representative-selection marker '$tok' present (#2059)"
    else
        bad "representative-selection marker '$tok' missing (#2059 regression)"
    fi
done
if grep -qF 'id: alt_representation' "$BASE_DIR/settings/epcr.yml"; then
    ok "epcr.yml ships the alt_representation tier (#2059)"
else
    bad "epcr.yml lost the alt_representation tier (#2059 regression)"
fi
# #2062: fetch must provision Exomiser's application.properties (data dir +
# hg38/phenotype versions, hg19 disabled) and a runnable wrapper with the CLI
# dir as the working directory — without these the stage dies at startup.
FETCH2="$BASE_DIR/scripts/fetch-reference-data.sh"
# shellcheck disable=SC2016  # grep -F matches the fetch script's SOURCE verbatim, $ must not expand
if grep -qF 'exomiser.data-directory=$DATA_DIR' "$FETCH2" \
   && grep -qF 'exomiser.phenotype.data-version=${MVA_EXOMISER_DATA_VERSION}' "$FETCH2" \
   && grep -qF 'sed "s/^exomiser\.${OTHER_ASSEMBLY}\./#&/"' "$FETCH2" \
   && grep -qF -e '-w "$CLI_DIR"' "$FETCH2" \
   && grep -qF -e '-jar "$CLI_DIR/exomiser-cli-' "$FETCH2" \
   && grep -qF 'chmod +x "$BIN/exomiser"' "$FETCH2"; then
    ok "fetch provisions Exomiser properties + CLI-dir wrapper (#2062)"
else
    bad "Exomiser provisioning regressed in fetch-reference-data.sh (#2062)"
fi
# #2066/#2067: the proband-id knob and the tie-separation emit path.
for tok in 'MVA_PROBAND_ID' 'separate_epcr_rec(' 'zpad_epcr_milli('; do
    if grep -qF "$tok" "$AG"; then
        ok "submission-hardening marker '$tok' present (#2066/#2067)"
    else
        bad "submission-hardening marker '$tok' missing (#2066/#2067 regression)"
    fi
done
# D6 gate compares a stored hash, not mere file presence.
if grep -qF 'approved_hash != draft_hash' "$AG"; then
    ok "D6 gate compares a stored sha256 (not file presence)"
else
    bad "D6 gate does not compare a stored hash"
fi
# No embedded interpreters (substrate-purity spirit). Comment-only lines are
# stripped first: the check used to fire on a comment that merely NAMED one of
# these tools, e.g. one explaining why an awk pipe had been removed. A lint
# that cannot tell code from prose teaches people not to write the prose.
# Counted, not short-circuited: `grep -q` exits on its first match, which
# SIGPIPEs the upstream grep to status 141, and under `set -o pipefail` that
# makes the whole pipeline non-zero — so a REAL finding took the else branch
# and reported clean. Only matches near end-of-file survived long enough to be
# reported, which is exactly why hand-checking it looked fine.
_embedded="$(grep -v '^[[:space:]]*//' "$AG" | grep -cE 'python3 -c|[^a-z]awk |[^a-z]sed ' || true)"
if [ "$_embedded" -gt 0 ]; then
    bad "embedded python3 -c / awk / sed logic found in the .ag"
else
    ok "no embedded python3 -c / awk / sed logic"
fi
# Every exec sh with a dynamic concat carries a safe-exec-concat annotation.
concat_lines="$(grep -cE 'exec sh .*\+ ' "$AG" || true)"
anno_lines="$(grep -cF '// colony-lint: safe-exec-concat' "$AG" || true)"
if [ "$anno_lines" -ge "$concat_lines" ]; then
    ok "exec sh dynamic concats are shell_escape-annotated ($anno_lines >= $concat_lines)"
else
    bad "an exec sh dynamic concat is not shell_escape-annotated ($anno_lines < $concat_lines)"
fi
# #2046 drift guard (CI-visible): the installer must keep WRITING both
# lens-viable LLM timeout keys (matched on the printf write lines, not mere
# comments), and the launcher must keep asserting the key + its lens floor
# (the real-backend behaviour itself is only testable operator-side, via
# demo-lens-smoke-real.sh).
INSTALL_SH="$BASE_DIR/../install.sh"
START_SH="$BASE_DIR/scripts/start-colony.sh"
if grep -qF "printf 'llm.cli_timeout_ms = %s" "$INSTALL_SH" \
   && grep -qF "printf 'llm.flat_cyborg.idle_ms = %s" "$INSTALL_SH"; then
    ok "install.sh writes llm.cli_timeout_ms + llm.flat_cyborg.idle_ms (#2046)"
else
    bad "install.sh no longer writes both LLM timeout keys (#2046 regression)"
fi
if grep -qF 'llm\.cli_timeout_ms[[:space:]]*=' "$START_SH" \
   && grep -qE -- '-lt 600000' "$START_SH"; then
    ok "start-colony.sh asserts llm.cli_timeout_ms + the 600000 lens floor (#2046)"
else
    bad "start-colony.sh no longer asserts llm.cli_timeout_ms / its lens floor (#2046 regression)"
fi
# #2044 drift guard (CI-visible): the fetch script must keep provisioning the
# GTF DECOMPRESSED and the launcher must keep defaulting MVA_GTF to the plain
# .gtf + refusing a .gz — the exact shipped-defaults trap behind #2044.
FETCH_SH="$BASE_DIR/scripts/fetch-reference-data.sh"
# shellcheck disable=SC2016  # grep -F matches the fetch script's SOURCE verbatim, $ must not expand
if grep -qF 'gzip -dc "$REFDATA/gencode.gtf.gz"' "$FETCH_SH" \
   && grep -qF 'MVA_GTF=${GTF}' "$FETCH_SH"; then
    ok "fetch-reference-data.sh provisions the decompressed GTF (#2044)"
else
    bad "fetch-reference-data.sh no longer decompresses the GTF / RESOLVED.env points elsewhere (#2044 regression)"
fi
if grep -qF 'refdata/gencode.gtf}' "$START_SH" \
   && grep -qF '*.gz)' "$START_SH"; then
    ok "start-colony.sh defaults MVA_GTF to the plain .gtf and refuses a .gz (#2044)"
else
    bad "start-colony.sh GTF default/.gz refusal regressed (#2044)"
fi

# --- 4. cb_budget matches the cb <N> declaration ---------------------------
echo "4. cb_budget consistency"
cb_ag="$(grep -oE '^cb [0-9]+;' "$AG" | grep -oE '[0-9]+')"
cb_toml="$(grep -oE 'cb_budget = [0-9]+' "$TOML" | grep -oE '[0-9]+')"
if [ -n "$cb_ag" ] && [ "$cb_ag" = "$cb_toml" ]; then
    ok "cb $cb_ag; == cb_budget $cb_toml"
else
    bad "cb ($cb_ag) != cb_budget ($cb_toml)"
fi

# --- 5. Exomiser idempotency manifest pins CONTENT, not path (#2069) --------
# The normalized VCF path is a constant, so a manifest built from the path
# alone matched across runs with genuinely different variants and the stage
# idempotent-skipped, serving rankings computed from a superseded VCF.
echo "5. exomiser manifest content pinning (#2069)"

# Static half — always runs, including on a runner with no agentis binary.
if grep -qF 'fn exomiser_manifest_hash(' "$AG" \
   && grep -qF 'let digest = vcf_content_digest(nvcf);' "$AG" \
   && grep -qF 'sha256_hex(nvcf + "|" + digest + "|" + hpo + "|" + assembly)' "$AG"; then
    ok "manifest hashes the nvcf record content, not its path or its bytes"
else
    bad "manifest no longer pins nvcf CONTENT (#2069 regression)"
fi

# Both the writer and the reader must derive it from the one helper, or they
# drift apart and the reader trusts a marker the writer never meant.
if [ "$(grep -cF 'exomiser_manifest_hash(nvcf, hpo, assembly)' "$AG")" = "2" ]; then
    ok "runner and fallback reader share one manifest helper"
else
    bad "manifest is derived in $(grep -cF 'exomiser_manifest_hash(nvcf, hpo, assembly)' "$AG") place(s), expected 2"
fi

# An unfingerprintable input must FORCE a re-run, never a skip — and the marker
# write must be guarded too, or a re-run leaves a marker it cannot have earned.
if grep -qF 'if len(marker) == 0 {' "$AG" \
   && grep -qF 'refusing the canonical TSV fallback' "$AG" \
   && grep -qF 'if len(marker) > 0 {' "$AG"; then
    ok "unfingerprintable input re-runs the stage and writes no marker"
else
    bad "missing the cannot-pin fail-safe (#2069)"
fi

# Exactly one marker may exist: the TSV path is constant, so a surviving older
# marker means a match that does not describe the TSV beside it (A -> B -> A).
# And it must hash RECORDS: bcftools stamps a wall-clock Date into the header,
# so hashing file bytes changes the manifest every run and disables the skip.
if grep -qF "grep -v '^##'" "$AG"; then
    ok "digest strips ## meta lines, so re-normalisation does not change it"
else
    bad "digest hashes raw bytes; bcftools Date headers make it change every run"
fi

if grep -qF 'rm -f' "$AG" && grep -qF '/.done.*' "$AG"; then
    ok "stale markers are cleared before a new one is written (A->B->A)"
else
    bad "markers accumulate; a marker match no longer implies the TSV matches"
fi

# The digest must be validated, not taken as the first whitespace-delimited
# field — an unvalidated token can be a content-independent constant.
if grep -qF 'regex_capture("^([0-9a-f]{64})$"' "$AG" \
   && grep -qF 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' "$AG"; then
    ok "vcf_content_digest validates the token and rejects the empty-stream digest"
else
    bad "vcf_content_digest trusts an unvalidated or empty-stream token (fail-open)"
fi

# Behavioural half — needs the binary, so it is skipped rather than faked.
if ! command -v agentis >/dev/null 2>&1; then
    echo "  [skip] manifest behaviour (no agentis binary on PATH)"
    skipped=$((skipped + 1))
else
    _mfdir="$(mktemp -d "${TMPDIR:-/tmp}/mf.XXXXXX")"
    (
        cd "$_mfdir" || exit 1
        agentis init >/dev/null 2>&1 || true
        awk '/^fn vcf_content_digest\(/,/^}/' "$AG"            >  probe.ag
        awk '/^fn exomiser_manifest_hash\(/,/^}/' "$AG" >> probe.ag
        printf 'print(exomiser_manifest_hash("%s/v.vcf", "HP:1", "hg38"));\n' "$_mfdir" >> probe.ag
        printf 'chr1\t100\tA\tG\n' > v.vcf
        agentis go probe.ag --enable-exec 2>/dev/null | tail -1 > h1 || true
        printf 'chr1\t100\tA\tT\n' > v.vcf
        agentis go probe.ag --enable-exec 2>/dev/null | tail -1 > h2 || true
        # Two cannot-pin shapes: no file at all, and a file whose records are
        # empty — the latter digests to a well-formed CONSTANT if unguarded.
        printf '##fileformat=VCFv4.2\n' > headonly.vcf
        { printf 'print("[" + exomiser_manifest_hash("%s/absent.vcf", "HP:1", "hg38") + "]");\n' "$_mfdir"
          printf 'print("[" + exomiser_manifest_hash("%s/headonly.vcf", "HP:1", "hg38") + "]");\n' "$_mfdir"
        } > probe2.ag
        awk '/^fn vcf_content_digest\(/,/^}/' "$AG"            >  probe2.tmp
        awk '/^fn exomiser_manifest_hash\(/,/^}/' "$AG" >> probe2.tmp
        cat probe2.ag >> probe2.tmp && mv probe2.tmp probe2.ag
        agentis go probe2.ag --enable-exec 2>/dev/null | grep -c '^\[\]$' > h3 || true
    )
    _h1="$(cat "$_mfdir/h1" 2>/dev/null || true)"
    _h2="$(cat "$_mfdir/h2" 2>/dev/null || true)"
    _h3="$(cat "$_mfdir/h3" 2>/dev/null || echo 0)"
    if [ -n "$_h1" ] && [ "$_h1" != "$_h2" ]; then
        ok "same path + changed content -> different manifest (stage re-runs)"
    else
        bad "manifest did not change when the VCF content did (#2069)"
    fi
    if [ "$_h3" = "2" ]; then
        ok "absent AND record-less inputs both yield an empty manifest, not a constant"
    else
        bad "missing file did not yield an empty manifest"
    fi
    rm -rf "$_mfdir"
fi

if [ "$skipped" -gt 0 ]; then
    echo "grand-rounds/baseline demo: $pass ok, $fail failed, $skipped skipped"
else
    echo "grand-rounds/baseline demo: $pass ok, $fail failed"
fi
[ "$fail" -eq 0 ]
