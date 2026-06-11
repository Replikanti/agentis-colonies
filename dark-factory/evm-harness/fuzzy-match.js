#!/usr/bin/env node
// #861 M3+: FUZZY structural match — the recall lift for REAL forks. Exact-hash matching (M1) and
// exact-signature matching (M1+) only fire when a fork's function is byte- or token-identical to a
// seed. Fork-pair validation (Compound CToken -> its Venus VToken fork) showed that's ~0% on the
// vuln-bearing functions: a real fork ROUGHLY DOUBLES redeemFresh / accrueInterest / mintFresh
// (adds error codes, fees, params, reorders), so exact-signature equality never hits them.
//
// This matches on SIMILARITY instead of equality: each function's normalized structural signature
// (struct-sig.js) is cut into k-token shingles, and two functions match when their shingle-set
// Jaccard similarity clears a threshold. On the Compound<->Venus fork pair this lifts real-fork
// recall from 17% (exact) to ~60-69% incl. the vuln functions (threshold 0.30-0.35). Precision is
// ~52-67% — about half the candidate matches are structurally-similar-but-different functions — but
// every match still has to clear the two-sided synthesis gate, so a false candidate only costs one
// inconclusive synthesis, never a false finding.
//
// Usage:   node fuzzy-match.js <target.sol> <seeds-file> [threshold=0.35]
//   <seeds-file> is one `Class:::<normalized-sig>` per line (written by seed-patterns.ag).
// Output:  the matched Class of the FIRST target function that clears the threshold against any
//          seed (mirrors reconn's first-hit short-circuit), or nothing. Exit 0 always (graceful).
'use strict';
const fs = require('fs');
const { extractFunctions, normalize, stripComments } = require('./struct-sig.js');

const K = 4; // shingle width (tokens). 4 balances structural specificity vs fork-drift tolerance.

function shingles(sig) {
  const t = sig.split(' ').filter(Boolean);
  const s = new Set();
  for (let i = 0; i + K <= t.length; i++) s.add(t.slice(i, i + K).join(' '));
  return s;
}

function jaccard(a, b) {
  let inter = 0;
  for (const x of a) if (b.has(x)) inter++;
  return inter / (a.size + b.size - inter || 1);
}

function targetSigs(file) {
  let src = '';
  try { src = fs.readFileSync(file, 'utf8'); } catch (e) { return []; }
  return extractFunctions(stripComments(src)).map((f) => normalize(f.unit));
}

function main() {
  const target = process.argv[2];
  const seedsFile = process.argv[3];
  const threshold = process.argv[4] ? parseFloat(process.argv[4]) : 0.35;
  if (!target || !seedsFile) return;
  let seedLines = [];
  try { seedLines = fs.readFileSync(seedsFile, 'utf8').split('\n').filter(Boolean); } catch (e) { return; }
  const seeds = seedLines
    .map((l) => { const i = l.indexOf(':::'); return i < 0 ? null : { cls: l.slice(0, i), sh: shingles(l.slice(i + 3)) }; })
    .filter((s) => s && s.sh.size >= 2);
  if (!seeds.length) return;
  for (const ts of targetSigs(target)) {
    const tsh = shingles(ts);
    if (tsh.size < 2) continue;
    let best = 0, bestCls = '';
    for (const s of seeds) {
      const j = jaccard(tsh, s.sh);
      if (j > best) { best = j; bestCls = s.cls; }
    }
    if (best >= threshold) { process.stdout.write(bestCls + '\n'); return; }
  }
}

main();
