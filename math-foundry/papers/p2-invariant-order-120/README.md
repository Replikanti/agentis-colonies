# Element-order collision probability on groups of order 120

A short note that grew out of `math-foundry/` run `20260517T024932Z`. The federation's novelty colony flagged the observation `P_2(S_5) - P_2(SL(2,5)) = 1/300` as `NOVEL` on tick 82. A follow-up brute-force enumeration over all 47 non-isomorphic groups of order 120 (GAP `SmallGroups` library) shows that `P_2` takes 47 distinct values on this order, and that 27 of the 1081 unordered pairs are "single-bucket-swap" pairs (their order-type distributions differ in exactly two orders by the same count).

## Files

| File | Purpose |
|---|---|
| `main.tex` | LaTeX source for the preprint (amsart class) |
| `main.pdf` | Compiled preprint (6 pages) |
| `reproducibility.g` | GAP script that reproduces all numerical claims in under 1 second |

## Status

Draft. Authorship, affiliation, and email fields are placeholder. Tables 1 and 2 contain abbreviated rows in the current draft; the full 47-row and 27-row tables are produced by `reproducibility.g`.

## Reproducing the numerical claims

```
podman run --rm -v "$PWD:/work:ro" gapsystem/gap-docker:latest \
    gap -q /work/reproducibility.g
```

Expected output:

```
Distinct P_2 count: 47
Total non-isomorphic groups of order 120: 47
Single-bucket-swap pair count: 27
P_2(S_5) - P_2(SL(2,5)) = 1/300
```

These four lines are the central claims of the note.

## Compiling the PDF

```
podman run --rm -v "$PWD:/work" -w /work docker.io/texlive/texlive:latest \
    pdflatex -interaction=nonstopmode main.tex
```

Run twice for cross-references to settle.

## Prior-work check

Before drafting, ~25 minutes of literature search across arXiv, Springer, OEIS, groupprops, MathOverflow-adjacent results, and Cameron's blog produced no direct match for:

- The scalar `P_2(G) = sum_k (N_k(G) / |G|)^2` under any name (the underlying order-type distribution is well-studied — Thompson 1987, Cameron-Dey 2023, Piwek 2024 — but the Renyi-2 / collision-probability variant was not found);
- The claim that `P_2` distinguishes all 47 groups of order 120;
- The "single-bucket-swap" structural pattern.

This is "could not find in 25 minutes," not "confirmed not to exist." MathSciNet (paywalled) was not directly queried; Russian-language Mazurov-school literature was not exhaustively searched.
