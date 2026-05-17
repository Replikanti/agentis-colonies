# Full GAP enumeration with tab-separated output for parsing by gen_tables.py
LoadPackage("smallgrp");
n := 120;
num := NumberSmallGroups(n);
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
    Print(i, "\t", NumeratorRat(p2), "\t", DenominatorRat(p2),
          "\t", desc, "\t", Nk, "\n");
od;
QUIT;
