#!/usr/bin/env node
// Project-aware Solidity compiler for REAL multi-file targets (Foundry/Hardhat).
// Unlike compile.js (single self-contained file), this resolves a target contract's
// imports via the project's remappings + layout (lib/ submodules, node_modules), selects
// the project's solc version (loading it from the on-disk cache), and emits the in-scope
// contract's creation bytecode. The colony's compile_run uses this when auditing a real
// repo target (phases 1+3 of agentis-core#859). The in-sandbox build stays offline: a
// host-side `--warm` step (run-audit.sh) pre-downloads any non-pinned solc into .solc-cache,
// so the sandboxed compile reads the compiler from disk (cargo + revm + solc, all offline).
//
// Usage: node compile-project.js <project-root> <in-scope-contract-path> [out.bin] [ContractName] [content-override.sol]
//   <in-scope-contract-path> is relative to <project-root> (or absolute).
//   ContractName defaults to the in-scope file's basename (Foundry one-contract-per-file).
//   content-override.sol  compile THIS content as the in-scope source (keeping its project
//                         path, so relative imports still resolve) — used to inject the colony's
//                         per-run anti-forgery challenge fn without mutating the operator's repo.
//   --warm                host-side: select + download the project's solc into .solc-cache, then
//                         exit 0 WITHOUT compiling (pre-flight so the sandboxed build is offline).
'use strict';
const fs = require('fs');
const path = require('path');
const { readRemappings, makeResolver, detectVersion, getSolc } = require('./solc-resolve');

async function main() {
  const argv = process.argv.slice(2).filter((a) => a !== '--warm');
  const warm = process.argv.includes('--warm');
  const root = path.resolve(argv[0] || '.');
  const inRel = argv[1];
  if (!inRel) {
    console.error('usage: compile-project.js <project-root> <in-scope-contract-path> [out.bin] [ContractName] [content-override.sol] [--warm]');
    process.exit(2);
  }
  const srcAbs = path.isAbsolute(inRel) ? inRel : path.resolve(root, inRel);
  const srcKey = path.relative(root, srcAbs); // keep the project-relative key so relative imports normalize right
  const contractName = argv[3] || path.basename(inRel, '.sol');
  const outBin = argv[2] || path.join(root, contractName + '.bin');
  const overrideFile = argv[4]; // optional: compile this content as the in-scope source

  const maps = readRemappings(root);
  const version = detectVersion(root, srcAbs);
  let solc;
  try {
    solc = await getSolc(version);
  } catch (e) {
    if (warm) { console.error('warm: solc ' + version + ' fetch failed (' + e.message + ')'); process.exit(1); }
    console.error('solc ' + version + ' load failed (' + e.message + '); falling back to local');
    solc = require('solc');
  }

  // --warm: the solc version is now on disk (or already pinned) — pre-flight done, don't compile.
  if (warm) {
    console.log('warmed: solc ' + solc.version().split('+')[0] + ' ready for ' + srcKey + ' (' + maps.length + ' remappings)');
    return;
  }

  let content;
  try {
    content = overrideFile ? fs.readFileSync(overrideFile, 'utf8') : fs.readFileSync(srcAbs, 'utf8');
  } catch (e) {
    console.error('in-scope source not readable: ' + (overrideFile || srcAbs) + ' (' + (e.code || e.message) + ')');
    process.exit(1);
  }
  const input = {
    language: 'Solidity',
    sources: { [srcKey]: { content } },
    settings: { optimizer: { enabled: true, runs: 200 }, outputSelection: { '*': { '*': ['evm.bytecode.object'] } } },
  };
  const out = JSON.parse(solc.compile(JSON.stringify(input), { import: makeResolver(root, maps) }));
  const errs = (out.errors || []).filter((e) => e.severity === 'error');
  if (errs.length) {
    console.error('COMPILE ERRORS (' + errs.length + '):');
    errs.slice(0, 8).forEach((e) => console.error('  ' + (e.formattedMessage || e.message).split('\n')[0]));
    process.exit(1);
  }
  const file = out.contracts[srcKey];
  // Use the requested contract when present, else the first deployable contract in the file
  // (Foundry is one-contract-per-file). Track which key actually built so the log never claims
  // success for a name that wasn't compiled (a typo'd --contract must be visible, not masked).
  const builtKey = file && (file[contractName] ? contractName : Object.keys(file).find((k) => file[k].evm && file[k].evm.bytecode.object));
  const c = builtKey && file[builtKey];
  if (!c || !c.evm.bytecode.object) {
    console.error('no deployable bytecode for ' + contractName + ' in ' + srcKey + ' (contracts: ' + Object.keys(file || {}).join(', ') + ')');
    process.exit(1);
  }
  fs.mkdirSync(path.dirname(outBin), { recursive: true });
  fs.writeFileSync(outBin, c.evm.bytecode.object);
  const label = builtKey === contractName ? contractName : builtKey + ' (requested ' + contractName + ' not found; used first deployable)';
  console.log('OK: ' + label + ' -> ' + c.evm.bytecode.object.length / 2 + ' bytes (solc ' + (solc.version().split('+')[0]) + ', ' + maps.length + ' remappings) -> ' + outBin);
}

main().catch((e) => { console.error('compile-project failed: ' + e.stack); process.exit(1); });
