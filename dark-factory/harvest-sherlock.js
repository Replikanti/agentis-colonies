#!/usr/bin/env node
// #861 M2: harvest real findings from a Sherlock judging repo into a seed manifest for the colony's
// DAG bug-pattern matcher. A Sherlock judging repo has valid findings in `NNN-H` / `NNN-M` folders
// (severity encoded); each finding markdown has a `# Title` and a ```solidity code block in the
// "Vulnerability Detail" section = the vulnerable function. We map the title to one of the colony's
// verifiable classes (else skip) and write the function source + a `Class|path|func-marker` manifest
// line that run-audit.sh --seed-manifest feeds to seed-patterns.ag. Only findings whose root cause is
// one of the 5 classes are seeded — subtle/multi-contract logic bugs are out of scope (the harness
// can't verify them anyway).
//
// Usage: node harvest-sherlock.js <judging-repo-dir> <seed-out-dir>
//   emits <seed-out-dir>/<NNN>.sol files + <seed-out-dir>/seed-manifest.txt
'use strict';
const fs = require('fs');
const path = require('path');

// Map a finding title/body to a colony class via keyword cues, or null to skip.
function classify(text) {
  const t = text.toLowerCase();
  if (/\breentran|checks?-?effects?-?interactions?|cei\b/.test(t)) return 'Reentrancy';
  if (/\boracle|chainlink|stale price|sequencer|latestrounddata|getreserves|spot price|twap\b/.test(t)) return 'OracleManipulation';
  if (/access control|onlyowner|unauthor|missing (the )?(modifier|access|permission|owner|role)|anyone can (call|mint|set|withdraw|burn)|privileged|lacks? (an? )?(owner|role|access)/.test(t)) return 'AccessControl';
  if (/unchecked (return|call|low-level)|return value (is )?(not )?(ignored|checked)|low-level call.*not checked|ignores? the return/.test(t)) return 'UncheckedCall';
  if (/\boverflow|underflow|narrowing cast|unsafe cast|truncat|unchecked\s*\{/.test(t)) return 'IntegerOverflow';
  return null;
}

// First ```solidity ... ``` block (the quoted vulnerable code).
function firstSolidityBlock(md) {
  const m = md.match(/```(?:solidity|sol)?\s*\n([\s\S]*?)```/);
  return m ? m[1] : null;
}

function firstFunctionName(code) {
  const m = code.match(/function\s+([A-Za-z_]\w*)/);
  return m ? m[1] : null;
}

function canonicalFinding(dir) {
  const mds = fs.readdirSync(dir).filter((f) => f.endsWith('.md'));
  return mds.find((f) => /best/i.test(f)) || mds[0];
}

function main() {
  const repo = process.argv[2];
  const out = process.argv[3];
  if (!repo || !out) { console.error('usage: harvest-sherlock.js <judging-repo-dir> <seed-out-dir>'); process.exit(2); }
  fs.mkdirSync(out, { recursive: true });
  const folders = fs.readdirSync(repo).filter((d) => /^\d+-[HM]$/.test(d) && fs.statSync(path.join(repo, d)).isDirectory());
  const manifest = [];
  let seeded = 0, skipped = 0;
  for (const folder of folders.sort()) {
    const dir = path.join(repo, folder);
    const mdName = canonicalFinding(dir);
    if (!mdName) { skipped++; continue; }
    const md = fs.readFileSync(path.join(dir, mdName), 'utf8');
    const titleM = md.match(/^#\s+(.+)$/m);
    const title = titleM ? titleM[1].trim() : '';
    const cls = classify(title) || classify(md.slice(0, 1200)); // title first, then the lead
    const code = firstSolidityBlock(md);
    if (!cls || !code) { skipped++; continue; }
    const fn = firstFunctionName(code);
    if (!fn) { skipped++; continue; }
    const id = folder;
    const solPath = path.join(out, id + '.sol');
    fs.writeFileSync(solPath, code.replace(/\s+$/, '') + '\n');
    manifest.push(cls + '|' + path.resolve(solPath) + '|' + fn);
    console.log('seeded ' + id + ' -> ' + cls + ' (fn ' + fn + ') "' + title.slice(0, 60) + '"');
    seeded++;
  }
  const manPath = path.join(out, 'seed-manifest.txt');
  fs.writeFileSync(manPath, manifest.join('\n') + (manifest.length ? '\n' : ''));
  console.log('\nharvest: ' + seeded + ' seeded, ' + skipped + ' skipped (no class/code/fn) -> ' + manPath);
}

main();
