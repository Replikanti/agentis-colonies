// Host-side Solidity AST -> canonical node-stream extractor for the colony's EVM reconn
// ingest (M2 of #858). Reuses the pinned solc 0.8.26 (see package.json) — the SAME compiler
// compile.js uses for creation bytecode. Mirrors the Rust path's reference node-extractor
// (auditor.ag::node_extractor): it walks the parsed program and emits a single-line JSON
// array of {"kind","name"} nodes, the EVM peer of the Rust fn/struct/impl node stream.
//
// Usage:   node ast.js <target.sol> [project-root]
//   With a [project-root] the target's imports are resolved (remappings + lib/ + node_modules,
//   via the shared solc-resolve) and the project's solc version is selected — so a REAL
//   multi-file repo target yields a non-empty node stream instead of degrading to "[]" on the
//   first unresolved import (phases 1+3 of agentis-core#859). Without it, the legacy
//   single-self-contained-file behaviour is unchanged.
// Output:  one line, a JSON array on stdout, e.g.
//   [{"kind":"function","name":"ReentrancyVaultInsecure.withdraw"},
//    {"kind":"call","name":"ReentrancyVaultInsecure.withdraw.call"},
//    {"kind":"sink","name":"ReentrancyVaultInsecure.withdraw:balanceOf"}]
// On any error (missing arg, solc fatal, unreadable file) it prints "[]" and exits 0 so the
// colony's reconn degrades gracefully exactly like the Rust ingest (rustc failure -> "[]").
//
// Node kinds (the EVM peer of the Rust fn/struct/impl stream):
//   function — every FunctionDefinition (named fn, or the receive/fallback/constructor kind),
//              scoped <contract>.<name> so the same handler across contracts/repos dedups.
//   call     — every external/low-level value-or-control call sink: a `.call` / `.transfer`
//              / `.send` / `.delegatecall` / `.callcode` member call, or any cross-contract
//              FunctionCall through a MemberAccess (the EVM analog of a Solana CPI sink).
//   sink     — every storage-write effect: an Assignment whose LHS is an IndexAccess or a
//              MemberAccess (state mapping / struct-field mutation, e.g. `balanceOf[..] = 0`).
// Deterministic: nodes are emitted in source/AST traversal order, no clocks, no randomness.

'use strict';

const solc = require('solc');
const fs = require('fs');
const path = require('path');

function emit(nodes) {
  process.stdout.write('[' + nodes.join(',') + ']\n');
}

function node(kind, name) {
  // Match the Rust extractor's exact field shape: {"kind":"..","name":".."}.
  return '{"kind":"' + kind + '","name":"' + name + '"}';
}

// JSON-safe an identifier fragment for embedding inside the manual {"name":".."} string
// above (the only chars Solidity identifiers + our separators can contain are already
// JSON-safe, but a defensive escape keeps the one-line array valid no matter what).
function safe(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

// The low-level / value-bearing call members that are external-call sinks.
const CALL_MEMBERS = { call: 1, delegatecall: 1, callcode: 1, staticcall: 1, transfer: 1, send: 1 };

// A human-readable label for a function definition node (named fn, else its kind).
function fnLabel(fn) {
  if (fn.name && fn.name.length > 0) return fn.name;
  return fn.kind || 'function'; // receive / fallback / constructor have empty name
}

// Best-effort base name of an LHS expression for a storage-write sink label.
function lhsName(lhs) {
  if (!lhs) return 'state';
  // balanceOf[msg.sender] -> IndexAccess over a base expression; walk to the base ident.
  let cur = lhs;
  while (cur && cur.nodeType === 'IndexAccess') cur = cur.baseExpression;
  if (cur && cur.nodeType === 'MemberAccess') return cur.memberName || 'state';
  if (cur && cur.nodeType === 'Identifier') return cur.name || 'state';
  return 'state';
}

// Walk a function body, appending call / sink nodes scoped to `<contract>.<fn>`.
function walkBody(n, scope, nodes) {
  if (!n || typeof n !== 'object') return;
  if (Array.isArray(n)) {
    for (const x of n) walkBody(x, scope, nodes);
    return;
  }
  if (n.nodeType === 'FunctionCall') {
    // The callee is either a direct MemberAccess (a.call / a.transfer / lib.foo()) or a
    // FunctionCallOptions wrapping one (`a.call{value: v}(..)`). Reach through both.
    let callee = n.expression;
    if (callee && callee.nodeType === 'FunctionCallOptions') callee = callee.expression;
    if (callee && callee.nodeType === 'MemberAccess') {
      const m = callee.memberName || '';
      if (CALL_MEMBERS[m]) {
        nodes.push(node('call', safe(scope + '.' + m)));
      } else {
        // A cross-contract / external method call (e.g. vault.withdraw()) — the EVM analog
        // of a CPI sink. Record it so reconn sees the external-interaction surface.
        nodes.push(node('call', safe(scope + '.' + m)));
      }
    }
  } else if (n.nodeType === 'Assignment') {
    const lhs = n.leftHandSide;
    if (lhs && (lhs.nodeType === 'IndexAccess' || lhs.nodeType === 'MemberAccess')) {
      nodes.push(node('sink', safe(scope + ':' + lhsName(lhs))));
    }
  }
  for (const k of Object.keys(n)) {
    if (k === 'nodeType') continue;
    walkBody(n[k], scope, nodes);
  }
}

async function main() {
  const file = process.argv[2];
  const root = process.argv[3]; // optional project root -> resolve imports + pick the project solc
  if (!file) {
    emit([]);
    return;
  }
  let src;
  try {
    src = fs.readFileSync(file, 'utf8');
  } catch (e) {
    emit([]);
    return;
  }

  // Repo target: key the source by its project-relative path (so relative imports normalize
  // correctly), resolve imports via the shared callback, and use the project's solc version.
  // Single-file (no root): the legacy `target.sol` / pinned-solc path.
  let compiler = solc;
  let srcKey = 'target.sol';
  let importCb;
  if (root) {
    try {
      const R = require('./solc-resolve');
      const maps = R.readRemappings(root);
      srcKey = path.relative(root, path.resolve(file)) || path.basename(file);
      importCb = { import: R.makeResolver(root, maps) };
      compiler = await R.getSolc(R.detectVersion(root, file)); // disk-cached / pinned; offline in-sandbox
    } catch (e) {
      // fall back to the pinned single-file path (still graceful -> may degrade to "[]")
      srcKey = 'target.sol';
      importCb = undefined;
      compiler = solc;
    }
  }

  const input = {
    language: 'Solidity',
    sources: { [srcKey]: { content: src } },
    settings: { outputSelection: { '*': { '': ['ast'] } } },
  };

  let out;
  try {
    out = JSON.parse(compiler.compile(JSON.stringify(input), importCb));
  } catch (e) {
    emit([]);
    return;
  }
  if (out.errors) {
    for (const e of out.errors) {
      // AST extraction tolerates warnings; only a hard parse/type error aborts (-> "[]").
      if (e.severity === 'error') {
        process.stderr.write((e.formattedMessage || e.message || 'solc error') + '\n');
        emit([]);
        return;
      }
    }
  }

  const srcUnit = out.sources && out.sources[srcKey] && out.sources[srcKey].ast;
  if (!srcUnit || !Array.isArray(srcUnit.nodes)) {
    emit([]);
    return;
  }

  const nodes = [];
  for (const c of srcUnit.nodes) {
    if (c.nodeType !== 'ContractDefinition' || !Array.isArray(c.nodes)) continue;
    const contract = c.name || '(contract)';
    for (const m of c.nodes) {
      if (m.nodeType !== 'FunctionDefinition') continue;
      const label = fnLabel(m);
      const scope = contract + '.' + label;
      nodes.push(node('function', safe(scope)));
      // External-call + storage-write sinks live inside the function body.
      if (m.body) walkBody(m.body, scope, nodes);
    }
  }

  emit(nodes);
}

main().catch(() => emit([]));
