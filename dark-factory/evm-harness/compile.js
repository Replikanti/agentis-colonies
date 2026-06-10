// Host-side solc compiler for the EVM PoC harness (pinned solc 0.8.26, see package.json).
// Compiles EVERY .sol file under ./contracts to creation bytecode, one ./contracts/bin/<Contract>.bin
// per top-level contract. Generic so an arbitrary in-scope target written into ./contracts by the
// colony's compile_run compiles without editing this file (mirrors the Solana RPC-snapshot host-side
// split: the in-sandbox build stays offline = cargo + revm only; solc runs host-side here).
const solc = require('solc');
const fs = require('fs');
const path = require('path');

const SRC = './contracts';
const OUT = './contracts/bin';
fs.mkdirSync(OUT, { recursive: true });

const sources = {};
for (const f of fs.readdirSync(SRC)) {
  if (f.endsWith('.sol')) sources[f] = { content: fs.readFileSync(path.join(SRC, f), 'utf8') };
}

const input = {
  language: 'Solidity',
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    outputSelection: { '*': { '*': ['evm.bytecode.object', 'abi'] } },
  },
};

const out = JSON.parse(solc.compile(JSON.stringify(input)));
if (out.errors) {
  let fatal = false;
  for (const e of out.errors) {
    console.error(e.formattedMessage);
    if (e.severity === 'error') fatal = true;
  }
  if (fatal) process.exit(1);
}

let n = 0;
for (const file of Object.keys(out.contracts || {})) {
  // Per-contract bin (by contract name) ...
  let primary = null;
  for (const [name, c] of Object.entries(out.contracts[file])) {
    const bc = c.evm.bytecode.object;
    fs.writeFileSync(path.join(OUT, name + '.bin'), bc);
    console.log(`${name}: ${bc.length / 2} bytes creation bytecode (${file})`);
    n++;
    // ... plus a per-file primary alias = the largest deployable contract in this file,
    // so callers can load <filebasename>.bin without knowing the internal contract name
    // (interfaces / abstract contracts compile to empty bytecode and are skipped).
    if (bc.length > 0 && (primary === null || bc.length > primary.bc.length)) {
      primary = { bc };
    }
  }
  if (primary) {
    const base = file.replace(/\.sol$/, '');
    fs.writeFileSync(path.join(OUT, base + '.bin'), primary.bc);
  }
}
console.log(`compiled ${n} contract(s); solc version: ` + solc.version());
