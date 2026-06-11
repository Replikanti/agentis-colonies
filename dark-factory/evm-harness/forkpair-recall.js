#!/usr/bin/env node
// #861 M3: REAL fork-pair recall — the honest real-world measurement that the synthetic recall
// harness (recall.sh) only proxies. Synthetic variants (rename/reformat/reliteral) are what
// struct-sig was BUILT to be invariant to, so the 94% there partly measures self-invariance. This
// instead takes two protocols that actually forked a common base — e.g. Compound's CToken.sol and
// its Venus VToken.sol fork — and measures, per shared function, whether the matcher catches the
// fork's ACTUALLY-DEPLOYED (restructured) version.
//
// Result on Compound CToken <-> Venus VToken (48 shared functions): exact-signature recall 17%
// (only near-verbatim getters), fuzzy shingle-Jaccard recall ~60-69% incl. the vuln-bearing
// functions (a real fork ~2x-rewrites redeemFresh/accrueInterest, which exact-equality can't
// absorb but shingle overlap can). The cost is precision (~52-67%): structurally-similar-but-
// different functions also match — but every candidate still has to clear the two-sided synthesis
// gate, so a false match costs one inconclusive synthesis, never a false finding.
//
// Usage:   node forkpair-recall.js <base.sol> <fork.sol> [threshold=0.35]
'use strict';
const fs = require('fs');
const { extractFunctions, normalize, stripComments } = require('./struct-sig.js');

let K = 4;
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
function sigMap(file) {
  let src = '';
  try { src = fs.readFileSync(file, 'utf8'); } catch (e) { return {}; }
  const m = {};
  for (const f of extractFunctions(stripComments(src))) if (!(f.name in m)) m[f.name] = normalize(f.unit);
  return m;
}

function main() {
  const base = process.argv[2];
  const fork = process.argv[3];
  const th = process.argv[4] ? parseFloat(process.argv[4]) : 0.35;
  if (process.argv[5]) { const kv = parseInt(process.argv[5], 10); if (kv >= 1) K = kv; }
  if (!base || !fork) { console.error('usage: forkpair-recall.js <base.sol> <fork.sol> [threshold] [shingle-k]'); process.exit(2); }
  const B = sigMap(base);
  const F = sigMap(fork);
  const SB = {}; for (const k of Object.keys(B)) SB[k] = shingles(B[k]);
  const SF = {}; for (const k of Object.keys(F)) SF[k] = shingles(F[k]);
  const shared = Object.keys(B).filter((k) => k in F);

  let exact = 0, fuzzy = 0;
  for (const k of shared) {
    if (B[k] === F[k]) exact++;
    if (jaccard(SB[k], SF[k]) >= th) fuzzy++;
  }
  // precision probe: different-name base x fork pairs that the fuzzy matcher wrongly fires on.
  let fp = 0;
  for (const a of Object.keys(B)) for (const b of Object.keys(F)) {
    if (a === b || SB[a].size < 2 || SF[b].size < 2) continue;
    if (jaccard(SB[a], SF[b]) >= th) fp++;
  }
  const prec = fuzzy + fp > 0 ? fuzzy / (fuzzy + fp) : 0;
  const recall = shared.length ? fuzzy / shared.length : 0;
  const exrec = shared.length ? exact / shared.length : 0;
  const p = (n) => shared.length ? Math.round((100 * n) / shared.length) + '%' : 'n/a';
  console.log('fork-pair recall  (threshold ' + th + ', shingle-k ' + K + ')');
  console.log('  base: ' + base);
  console.log('  fork: ' + fork);
  console.log('  shared functions: ' + shared.length);
  console.log('  exact-signature recall: ' + exact + '/' + shared.length + ' (' + p(exact) + ')');
  console.log('  fuzzy (shingle-Jaccard) recall: ' + fuzzy + '/' + shared.length + ' (' + p(fuzzy) + ')');
  console.log('  fuzzy precision (vs different-name pairs): ' + Math.round(100 * prec) + '% (' + fp + ' false-matches)');
  // machine-readable line for the pattern-evolver (M4 fitness oracle): all 0..1 decimals.
  console.log('EVAL|threshold=' + th + '|k=' + K + '|recall=' + recall.toFixed(4) +
    '|precision=' + prec.toFixed(4) + '|exact=' + exrec.toFixed(4) + '|shared=' + shared.length);
}

main();
