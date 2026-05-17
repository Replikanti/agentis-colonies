#!/usr/bin/env python3
"""
Generate the two full LaTeX tables for main.tex from GAP output.

Usage:
  podman run --rm -v "$PWD:/work:ro" gapsystem/gap-docker:latest \
      gap -q /work/reproducibility_full.g > full_out.txt
  python3 gen_tables.py full_out.txt
"""
from fractions import Fraction
from itertools import combinations
import re
import sys

src = sys.argv[1] if len(sys.argv) > 1 else "full_out.txt"
with open(src) as f:
    text = f.read()


def push(buf, sink):
    m = re.match(r"^(\d+)\t(\d+)\t(\d+)\t([^\t]+)\t(.*)$", buf)
    if not m:
        return
    gid = int(m.group(1))
    num = int(m.group(2))
    den = int(m.group(3))
    desc = m.group(4).strip()
    distr = m.group(5)
    pairs = re.findall(r"\[\s*(\d+)\s*,\s*(\d+)\s*\]", distr)
    nk = {int(o): int(c) for o, c in pairs}
    sink.append({
        "id": gid,
        "desc": desc,
        "p2": Fraction(num, den),
        "p2_num": num,
        "p2_den": den,
        "nk": nk,
    })


groups = []
buf = ""
for line in text.splitlines():
    if re.match(r"^\d+\t\d+\t\d+\t", line):
        if buf:
            push(buf, groups)
        buf = line
    elif buf and (line.startswith("  ") or line.strip().endswith("]")):
        buf += " " + line.strip()
    else:
        if buf:
            push(buf, groups)
            buf = ""
if buf:
    push(buf, groups)

assert len(groups) == 47, f"expected 47 groups, got {len(groups)}"


def fmt_struct(s):
    """Convert plain GAP StructureDescription to LaTeX math-mode markup."""
    # families like C5, D10, Q8, S5, A5, SL(2,5)
    s = re.sub(r"\bSL\(2,5\)", r"\\mathrm{SL}(2,5)", s)
    s = re.sub(r"\bC(\d+)", lambda m: f"C_{{{m.group(1)}}}", s)
    s = re.sub(r"\bD(\d+)", lambda m: f"D_{{{m.group(1)}}}", s)
    s = re.sub(r"\bQ(\d+)", lambda m: f"Q_{{{m.group(1)}}}", s)
    s = re.sub(r"\bS(\d+)", lambda m: f"S_{{{m.group(1)}}}", s)
    s = re.sub(r"\bA(\d+)", lambda m: f"A_{{{m.group(1)}}}", s)
    # operators
    s = s.replace(" x ", r" \times ")
    s = s.replace(" : ", r" \rtimes ")
    return f"${s}$"


# --- Table 1: 47 groups sorted by P_2 ascending ---
groups_sorted = sorted(groups, key=lambda g: g["p2"])
with open("table1_body.tex", "w") as out:
    for g in groups_sorted:
        out.write(f"{g['id']} & {fmt_struct(g['desc'])} & "
                  f"{g['p2_num']} & {g['p2_den']} \\\\\n")

# --- Table 2: 27 single-bucket-swap pairs ---
swap_pairs = []
for g1, g2 in combinations(groups, 2):
    all_k = set(g1["nk"]) | set(g2["nk"])
    diff = {k: g2["nk"].get(k, 0) - g1["nk"].get(k, 0) for k in all_k}
    nz = [(k, d) for k, d in diff.items() if d != 0]
    if len(nz) != 2:
        continue
    (k1, d1), (k2, d2) = nz
    if d1 + d2 != 0:
        continue
    if d1 > 0:
        from_o, to_o, n = k2, k1, abs(d1)
    else:
        from_o, to_o, n = k1, k2, abs(d2)
    gap = abs(g2["p2"] - g1["p2"])
    swap_pairs.append({
        "g1_id": g1["id"],
        "g2_id": g2["id"],
        "n_moved": n,
        "from_order": from_o,
        "to_order": to_o,
        "gap_num": gap.numerator,
        "gap_den": gap.denominator,
        "gap": gap,
    })

assert len(swap_pairs) == 27, f"expected 27 swap pairs, got {len(swap_pairs)}"
swap_pairs.sort(key=lambda x: (x["n_moved"], x["gap"].denominator))

with open("table2_body.tex", "w") as out:
    for sp in swap_pairs:
        out.write(f"{sp['g1_id']} & {sp['g2_id']} & {sp['n_moved']} & "
                  f"{sp['from_order']} & {sp['to_order']} & "
                  f"{sp['gap_num']} & {sp['gap_den']} \\\\\n")

print(f"wrote table1_body.tex ({len(groups_sorted)} rows)")
print(f"wrote table2_body.tex ({len(swap_pairs)} rows)")
