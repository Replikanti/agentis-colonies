#!/usr/bin/env node
// #861: O(n) comment stripper for the EVM exact-match path. The in-`.ag` strip_comments builds its
// result with `reduce(lines, |acc, l| acc + ... )` — O(n^2) string allocation that overflows the
// 16 MiB per-tick string heap on a full ~1500-line real contract (the error that blocked auditing
// real targets). agentis has no `join` / `regex_replace` builtin, so an in-`.ag` O(n) rewrite is not
// possible; the EVM reconn/guard/seed/recall paths offload to this instead (the Rust path keeps the
// in-`.ag` stripper). Reuses struct-sig.js's stripComments so the exact-match path strips comments
// IDENTICALLY to the structural/fuzzy paths — and seed + match both call this, so the content hashes
// stay aligned within a run.
//
// Usage:   node strip-comments.js <file.sol>   -> stripped source on stdout (empty on any error).
'use strict';
const fs = require('fs');
const { stripComments } = require('./struct-sig.js');

function main() {
  const f = process.argv[2];
  if (!f) return;
  let src;
  try { src = fs.readFileSync(f, 'utf8'); } catch (e) { return; }
  process.stdout.write(stripComments(src));
}

main();
