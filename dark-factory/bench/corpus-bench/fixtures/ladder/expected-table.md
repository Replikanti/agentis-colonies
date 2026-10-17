# DIAGNOSTIC: pointed upper bound, not recall

Pointed runs bound what the hunter can REACH when told where to look; they never measure what it would have selected.

| contest | row | found-by | unpointed | exposure | L0 | L0r2 | L1 | L2 | deep | forge | cause | model | checkout | ladder sha | evidence | notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fx | FX-1 | 1 | MISS | unseen | HIT | - | not run | not run | MISS | not run | LOCATION (unseen) | claude-opus-4-8 | 0123456789ab | 5e1f0c0ffee0 | arms/fx/z_a01/ptr-a01-L0-r1 | - |
| fx | FX-2 | 2 | MISS | unseen | - | - | - | - | - | not run | UNPOINTABLE | - | - | - | - | - |
| fx | FX-3 | 1 | MISS | examined | MISS | HIT | HIT | MISS | MISS | not run | LOCATION (examined) | claude-opus-4-8 | 0123456789ab | 5e1f0c0ffee0 | arms/fx/z_a03/ptr-a03-L0-r1 | - |
| fx | FX-4 | 2 | MISS | out-of-map | HIT | - | MISS | MISS | HIT | not run | LOCATION (out-of-map) | claude-opus-4-8 | 0123456789ab | 5e1f0c0ffee0 | arms/fx/z_a04/ptr-a04-L0-r1 | - |
| fx | FX-5 | 1 | MISS | unseen | MISS | MISS | MISS | HIT | HIT | not run | EXECUTION | claude-opus-4-8 | 0123456789ab | 5e1f0c0ffee0 | arms/fx/z_a05/ptr-a05-L0-r1 | - |
| fx | FX-6 | 1 | MISS | examined | MISS | MISS | HIT | HIT | MISS | not run | HINT (L1) | claude-opus-4-8 | 0123456789ab | 5e1f0c0ffee0 | arms/fx/z_a06/ptr-a06-L0-r1 | - |
| fx | FX-7 | 2 | MISS | unseen | MISS | MISS | MISS | HIT | MISS | not run | HINT (L2) | claude-opus-4-8 | 0123456789ab | 5e1f0c0ffee0 | arms/fx/z_a07/ptr-a07-L0-r1 | - |
| fx | FX-8 | 1 | MISS | unseen | MISS | MISS | MISS | HIT | MISS | not run | HINT (L2=L1) | claude-opus-4-8 | 0123456789ab | 5e1f0c0ffee0 | arms/fx/z_a08/ptr-a08-L0-r1 | - |
| fx | FX-9 | 1 | MISS | examined | MISS | - | MISS | MISS | MISS | not run | MECHANISM | claude-opus-4-8 | 0123456789ab | 5e1f0c0ffee0 | arms/fx/z_a09/ptr-a09-L0-r1 | - |
| fx | FX-10 | 1 | MISS | examined | MISS | - | MISS | MISS | MISS | not run | MECHANISM (dismissed) | claude-opus-4-8 | 0123456789ab | 5e1f0c0ffee0 | arms/fx/z_a10/ptr-a10-L0-r1 | pointer-cited |
| fx | FX-11 | 2 | MISS | unseen | MISS | - | MISS | MISS | UNMEASURED | not run | MECHANISM-or-EXECUTION | claude-opus-4-8 | 0123456789ab | 5e1f0c0ffee0 | arms/fx/z_a11/ptr-a11-L0-r1 | - |
| fx | FX-12 | 1 | MISS | unseen | MISS | - | UNMEASURED | MISS | MISS | not run | UNMEASURED | claude-opus-4-8 | 0123456789ab | 5e1f0c0ffee0 | arms/fx/z_a12/ptr-a12-L0-r1 | - |

## Cause counts

| cause | rows | lever |
|---|---|---|
| UNPOINTABLE | 1 | excluded |
| LOCATION | 3 | coverage/selection |
| EXECUTION | 1 | execution |
| HINT | 3 | generation |
| MECHANISM | 2 | generation |
| MECHANISM-or-EXECUTION | 1 | excluded |
| UNMEASURED | 1 | excluded |

## Lever counts

| lever | rows |
|---|---|
| generation | 5 |
| coverage/selection | 3 |
| execution | 1 |

## Verdict

VERDICT: DOMINANT generation (5 of N=9; worst case 6 of 11)
RULE: DOMINANT = a strict majority of N that survives the worst case; else SELECTED = a plurality lead >= 3 rows; else SPLIT
WORST-CASE: generation 6 of 11 (every excluded row in the denominator)
SUB-SPLIT generation: HINT:L1 1, HINT:L2 1, HINT:L2=L1 1, MECHANISM:dismissed 1, MECHANISM:none 1
EXCLUDED: MECHANISM-or-EXECUTION fx FX-11 (consistent: EXECUTION,MECHANISM); UNMEASURED fx FX-12 (consistent: HINT,MECHANISM)
FOUND-BY=1 SUBSET: DOMINANT generation (4 of N=7; worst case 5 of 8)
No recall figure: a pointed HIT is reachability, not selection.
