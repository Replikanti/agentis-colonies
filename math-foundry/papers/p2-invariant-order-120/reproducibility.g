# GAP script: reproducibility for "The element-order collision probability
# distinguishes the 47 groups of order 120"
#
# Run: gap -q reproducibility.g
# Expected output (last 4 lines):
#   Distinct P_2 count: 47
#   Total non-isomorphic groups of order 120: 47
#   Single-bucket-swap pair count: 27
#   P_2(S_5) - P_2(SL(2,5)) = 1/300

LoadPackage("smallgrp");

n := 120;
num := NumberSmallGroups(n);
results := [];

for i in [1..num] do
    G := SmallGroup(n, i);
    desc := StructureDescription(G);
    ccs := ConjugacyClasses(G);
    orders := List(ccs, c -> Order(Representative(c)));
    sizes  := List(ccs, Size);
    distinct_orders := Set(orders);
    Nk := [];
    for k in distinct_orders do
        nk := Sum(Filtered([1..Length(orders)], j -> orders[j] = k),
                  j -> sizes[j]);
        Add(Nk, [k, nk]);
    od;
    p2 := Sum(Nk, x -> (x[2]/n)^2);
    Add(results, rec(id := i, desc := desc, Nk := Nk, p2 := p2));
od;

# Theorem 1.1: P_2 distinguishes all 47 groups of order 120
distinct_p2 := Set(List(results, r -> r.p2));
Print("Distinct P_2 count: ", Length(distinct_p2), "\n");
Print("Total non-isomorphic groups of order 120: ", num, "\n");

# Proposition 1.2: 27 single-bucket-swap pairs
swap := 0;
for i in [1..num] do
    for j in [(i+1)..num] do
        a := results[i].Nk;
        b := results[j].Nk;
        all_k := Union(List(a, x -> x[1]), List(b, x -> x[1]));
        diff := [];
        for k in all_k do
            na := First(a, x -> x[1] = k);
            if na = fail then na := [k, 0]; fi;
            nb := First(b, x -> x[1] = k);
            if nb = fail then nb := [k, 0]; fi;
            if na[2] <> nb[2] then Add(diff, [k, nb[2] - na[2]]); fi;
        od;
        if Length(diff) = 2 and diff[1][2] + diff[2][2] = 0 then
            swap := swap + 1;
        fi;
    od;
od;
Print("Single-bucket-swap pair count: ", swap, "\n");

# Example 3.3: P_2(S_5) - P_2(SL(2,5)) = 1/300
s5_rec := First(results, r -> r.desc = "S5");
sl25_rec := First(results, r -> r.desc = "SL(2,5)");
gap_p2 := s5_rec.p2 - sl25_rec.p2;
Print("P_2(S_5) - P_2(SL(2,5)) = ",
      NumeratorRat(gap_p2), "/", DenominatorRat(gap_p2), "\n");

QUIT;
