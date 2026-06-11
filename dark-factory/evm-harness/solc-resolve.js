// Shared Solidity project-resolution helpers for the colony's real-target (multi-file
// Foundry/Hardhat) support — phases 1+3 of agentis-core#859. Both compile-project.js
// (creation bytecode) and ast.js (reconn node stream) require this so a repo target's
// imports + solc version resolve identically in the compile path and the recon path.
//
//   readRemappings(root)        parse remappings.txt + foundry.toml `remappings = [...]`
//   makeResolver(root, maps)    solc import callback (remap longest-prefix -> rel -> node_modules/lib)
//   detectVersion(root, src)    project solc version (foundry.toml solc/solc_version, else exact pragma)
//   getSolc(version, cacheDir)  the matching solcjs, loaded OFFLINE from an on-disk soljson cache
//                               (a host-side --warm step downloads it once; the in-sandbox build reads disk)
'use strict';
const fs = require('fs');
const path = require('path');
const https = require('https');
const solcMod = require('solc'); // the harness's pinned solcjs (resolved from ./node_modules)

function readRemappings(root) {
  const maps = [];
  const add = (e) => {
    const i = e.indexOf('=');
    if (i > 0) maps.push([e.slice(0, i).trim(), e.slice(i + 1).trim()]);
  };
  const rf = path.join(root, 'remappings.txt');
  if (fs.existsSync(rf)) {
    for (const line of fs.readFileSync(rf, 'utf8').split('\n')) {
      const t = line.trim();
      if (t && !t.startsWith('#')) add(t);
    }
  }
  const ft = path.join(root, 'foundry.toml');
  if (fs.existsSync(ft)) {
    const m = fs.readFileSync(ft, 'utf8').match(/remappings\s*=\s*\[([\s\S]*?)\]/);
    if (m) for (const q of m[1].matchAll(/["']([^"']+=[^"']+)["']/g)) add(q[1]);
  }
  // longest prefix first so the most specific remapping wins
  maps.sort((a, b) => b[0].length - a[0].length);
  return maps;
}

function makeResolver(root, maps) {
  return function (importPath) {
    const tries = [];
    for (const [pre, tgt] of maps) {
      if (importPath.startsWith(pre)) {
        tries.push(path.resolve(root, tgt, importPath.slice(pre.length)));
      }
    }
    // common dependency roots + project-relative (solcjs normalizes relative imports
    // against the importer, so by the time we get here the path is project-anchored)
    tries.push(path.resolve(root, importPath));
    tries.push(path.resolve(root, 'node_modules', importPath));
    tries.push(path.resolve(root, 'lib', importPath));
    for (const c of tries) {
      try {
        return { contents: fs.readFileSync(c, 'utf8') };
      } catch (e) { /* try next */ }
    }
    return { error: 'import not found: ' + importPath + ' (tried ' + tries.length + ' paths)' };
  };
}

function detectVersion(root, srcPath) {
  const ft = path.join(root, 'foundry.toml');
  if (fs.existsSync(ft)) {
    const m = fs.readFileSync(ft, 'utf8').match(/solc(?:_version)?\s*=\s*["']([0-9]+\.[0-9]+\.[0-9]+)["']/);
    if (m) return m[1];
  }
  // exact-pinned pragma (e.g. `pragma solidity 0.8.18;`) — a caret/range pragma returns null (use local)
  const src = fs.readFileSync(srcPath, 'utf8');
  const m = src.match(/pragma\s+solidity\s+(?:=\s*)?([0-9]+\.[0-9]+\.[0-9]+)\s*;/);
  if (m) return m[1];
  return null;
}

// GET that follows the soliditylang redirect (binaries.soliditylang.org -> github releases),
// resolving to a Buffer of the body. Used host-side only (the --warm step); the in-sandbox
// build never reaches here because the soljson is already on disk.
function httpGet(url) {
  return new Promise((res, rej) => {
    https.get(url, (r) => {
      if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) {
        r.resume();
        return httpGet(r.headers.location).then(res, rej);
      }
      if (r.statusCode !== 200) { r.resume(); return rej(new Error('HTTP ' + r.statusCode + ' for ' + url)); }
      const d = [];
      r.on('data', (c) => d.push(c));
      r.on('end', () => res(Buffer.concat(d)));
    }).on('error', rej);
  });
}

// Return the solcjs matching `version`. The pinned local build is used when it already
// matches (no fetch). Otherwise the versioned soljson is loaded from the on-disk cache
// (OFFLINE — the in-sandbox build path); only when it is absent do we fetch + persist it
// (the host-side --warm step run-audit.sh performs before the sandboxed run, like
// snapshot-rpc.sh). This keeps the in-sandbox build network-free even for a non-pinned solc.
async function getSolc(version, cacheDir) {
  const local = solcMod.version().split('+')[0];
  if (!version || version === local) return solcMod;
  cacheDir = cacheDir || path.join(__dirname, '.solc-cache');
  fs.mkdirSync(cacheDir, { recursive: true });
  // already cached? load it offline via the wrapper (full versioned filename = soljson-v<ver>+commit.*.js)
  let full = fs.readdirSync(cacheDir).find((f) => f.startsWith('soljson-v' + version + '+') && f.endsWith('.js'));
  if (!full) {
    // not cached — resolve the full name + download once (host-side, network)
    const list = JSON.parse((await httpGet('https://binaries.soliditylang.org/bin/list.json')).toString());
    full = list.releases && list.releases[version]; // e.g. "soljson-v0.8.18+commit.87f61d96.js"
    if (!full) throw new Error('no solc release for ' + version);
    const buf = await httpGet('https://binaries.soliditylang.org/bin/' + full);
    fs.writeFileSync(path.join(cacheDir, full), buf);
  }
  // wrap the on-disk soljson (require() resolves solc/wrapper from this dir's node_modules)
  return require('solc/wrapper')(require(path.join(cacheDir, full)));
}

module.exports = { readRemappings, makeResolver, detectVersion, getSolc, httpGet };
