const solc = require('solc');
const fs = require('fs');
const path = require('path');

const SRC = './contracts';
const OUT = './contracts/bin';
fs.mkdirSync(OUT, { recursive: true });

const files = ['ReentrancyVaultInsecure.sol', 'ReentrancyVaultSecure.sol', 'Attacker.sol'];
const sources = {};
for (const f of files) sources[f] = { content: fs.readFileSync(path.join(SRC, f), 'utf8') };

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

const want = {
  'ReentrancyVaultInsecure.sol': 'ReentrancyVaultInsecure',
  'ReentrancyVaultSecure.sol': 'ReentrancyVaultSecure',
  'Attacker.sol': 'Attacker',
};
for (const [file, name] of Object.entries(want)) {
  const bc = out.contracts[file][name].evm.bytecode.object;
  fs.writeFileSync(path.join(OUT, name + '.bin'), bc);
  console.log(`${name}: ${bc.length / 2} bytes creation bytecode`);
}
console.log('solc version: ' + solc.version());
