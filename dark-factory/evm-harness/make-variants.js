#!/usr/bin/env node
// #861 M3: generate realistic FORK variants of a seeded vulnerable function, to measure the
// matcher's recall on held-out forks (exact-only ~0 vs structural) and its precision (false match
// on structurally-different negatives). A real N-day fork is overwhelmingly a rename + reformat +
// re-literal of the original — never a byte-identical copy — so these transforms model the real
// thing. The negative controls are genuine STRUCTURAL edits that SHOULD NOT match (a different call
// kind, an added guard); a matcher that fires on them is over-broad.
//
// Reuses struct-sig.js's exported KEEP set so `rename` renames EXACTLY the identifiers the matcher
// normalizes away — keeping a renamed fork's signature identical to its seed (and only its bytes
// different, so exact-match misses while structural matches).
//
// Usage:   node make-variants.js <seed.sol> <out-dir> <Class> <id-prefix>
// Output:  writes <out-dir>/<id-prefix>-<transform>.sol and prints manifest lines to stdout:
//          `<Class>|<abs-path>|<id-prefix>-<transform>|<transform>|<expect match|miss>`
'use strict';
const fs = require('fs');
const path = require('path');
const { KEEP, sizedType } = require('./struct-sig');

// Consistently rename every non-keyword/non-type identifier to a fresh name. Same shape, new bytes.
function rename(src) {
  const map = {};
  let n = 0;
  return src.replace(/[A-Za-z_$][\w$]*/g, (id) =>
    (KEEP.has(id) || sizedType(id)) ? id : (map[id] || (map[id] = 'r' + (++n))));
}

// Change literal VALUES (numbers, hex, strings) — a fork tuning constants. Shape unchanged.
function reliteral(src) {
  return src
    .replace(/\b0x[0-9a-fA-F]+\b/g, '0xC0FFEE')
    .replace(/\b\d[\d_]*\b/g, (m) => String((parseInt(m.replace(/_/g, ''), 10) || 0) + 13))
    .replace(/"(?:\\.|[^"\\])*"/g, '"_v"')
    .replace(/'(?:\\.|[^'\\])*'/g, "'_v'");
}

// Reflow whitespace/indentation — a fork reformatted by a different team's linter. Shape unchanged.
function reformat(src) {
  return src.replace(/[ \t]+/g, ' ').replace(/\s*\n\s*/g, '\n        ').replace(/\{\s*/g, ' {\n        ');
}

// NEGATIVE: swap the external-call KIND (.call -> .delegatecall). A genuine structural difference —
// must NOT match. Only meaningful when the seed actually makes a low-level .call.
function negCallKind(src) {
  return /\.call\b/.test(src) ? src.replace(/\.call\b/g, '.delegatecall') : null;
}

// NEGATIVE: inject an access guard as the first body statement. A guarded function is a DIFFERENT
// (safer) shape than the unguarded vulnerable seed — must NOT match.
function negGuard(src) {
  let injected = false;
  const out = src.replace(/\{/, (m) => {
    if (injected) return m;
    injected = true;
    return '{\n        require(msg.sender == _guardOwner, "auth");';
  });
  return injected ? out : null;
}

function main() {
  const [seed, outDir, cls, idPrefix] = process.argv.slice(2);
  if (!seed || !outDir || !cls || !idPrefix) {
    console.error('usage: make-variants.js <seed.sol> <out-dir> <Class> <id-prefix>');
    process.exit(2);
  }
  let src;
  try { src = fs.readFileSync(seed, 'utf8'); } catch (e) {
    console.error('make-variants: cannot read seed ' + seed); process.exit(2);
  }
  fs.mkdirSync(outDir, { recursive: true });
  const transforms = [
    ['rename', rename(src), 'match'],
    ['reformat', reformat(src), 'match'],
    ['reliteral', reliteral(src), 'match'],
    ['combo', reformat(reliteral(rename(src))), 'match'], // the realistic fork: all three
    ['neg-callkind', negCallKind(src), 'miss'],
    ['neg-guard', negGuard(src), 'miss'],
  ];
  for (const [name, body, expect] of transforms) {
    if (body == null) continue; // transform not applicable to this seed
    const p = path.resolve(outDir, idPrefix + '-' + name + '.sol');
    fs.writeFileSync(p, body.replace(/\s+$/, '') + '\n');
    process.stdout.write(cls + '|' + p + '|' + idPrefix + '-' + name + '|' + name + '|' + expect + '\n');
  }
}

main();
