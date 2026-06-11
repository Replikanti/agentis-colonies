#!/usr/bin/env node
// #861 M1+: parser-free STRUCTURAL signature of each Solidity function, for variant (not just
// byte-identical) bug-pattern matching. ast.js (solc) is the right abstraction level but it
// SUPPRESSES the AST on the first "Undeclared identifier" — and the seed side is always a
// harvested FRAGMENT (a function lifted out of its contract, full of undefined refs). So this
// uses a token normalizer instead, which is symmetric across seed (fragment) and match (full
// contract) and needs no compile:
//
//   - strip comments
//   - extract each `function <name>(...) <mods> { <brace-matched body> }` precisely (so the
//     signature is independent of the surrounding functions — a variant with different
//     neighbours still matches)
//   - tokenize and normalize: identifier names -> `_`, number/string literals -> `0`, but KEEP
//     Solidity keywords, type names, and structural/global members (call/delegatecall/transfer/
//     value/gas/msg/sender/balance/...). Punctuation kept verbatim.
//
// A verbatim fork, a renamed fork, a reformatted fork, and a re-littered fork (different
// constants) all collapse to the SAME normalized signature; the colony dag_put()s it to a
// content hash and looks it up in the seeded `bugpat:struct:<hash>` memo. A structurally-edited
// variant (reordered statements, different expression shape) is NOT caught — that needs a real
// AST / semantic signal and is out of scope for v1. An over-broad match can never mint a false
// finding: it only sets the candidate class; the two-sided synthesis gate stays the only truth.
//
// Usage:   node struct-sig.js <file.sol>
// Output:  one line per function on stdout: `<funcName>:::<normalized-signature>`
//          (the raw funcName is for seed-side selection only; it is NOT part of the hashed sig;
//          `:::` never occurs inside a normalized sig — `:` is always a space-padded lone token).
//          On any read error -> no output, exit 0 (caller degrades gracefully, like ast.js).
'use strict';
const fs = require('fs');

// Identifiers kept verbatim: Solidity keywords, value-type roots, and the structural/global
// members whose identity is semantically load-bearing for a vuln shape (a `.call` is not a
// `.transfer`; `msg.sender` is not an arbitrary local). Everything else is a name -> `_`.
const KEEP = new Set([
  // declarations / control flow
  'function', 'returns', 'return', 'if', 'else', 'for', 'while', 'do', 'break', 'continue',
  'require', 'assert', 'revert', 'emit', 'new', 'delete', 'try', 'catch', 'unchecked', 'assembly',
  'modifier', 'constructor', 'receive', 'fallback', 'mapping', 'struct', 'enum', 'event', 'error',
  'contract', 'library', 'interface', 'using', 'is', 'import', 'pragma', 'abstract', 'override',
  'virtual', 'return',
  // visibility / mutability / data location
  'external', 'public', 'internal', 'private', 'view', 'pure', 'payable', 'nonpayable', 'constant',
  'immutable', 'memory', 'storage', 'calldata', 'indexed', 'anonymous',
  // value types (sized variants — uint256, bytes32 — handled by sizedType() below)
  'address', 'bool', 'string', 'bytes', 'byte', 'int', 'uint', 'fixed', 'ufixed', 'true', 'false',
  // units
  'wei', 'gwei', 'ether', 'finney', 'szabo', 'seconds', 'minutes', 'hours', 'days', 'weeks', 'years',
  // globals / structural members (the load-bearing ones for vuln shapes)
  'msg', 'block', 'tx', 'abi', 'this', 'super', 'type', 'value', 'gas', 'sender', 'origin', 'data',
  'sig', 'balance', 'timestamp', 'number', 'coinbase', 'gasprice', 'gaslimit', 'chainid', 'basefee',
  'difficulty', 'blockhash', 'length', 'push', 'pop',
  // external-call kinds (the heart of a reentrancy / unchecked-call shape)
  'call', 'delegatecall', 'staticcall', 'callcode', 'transfer', 'send',
  // builtins
  'keccak256', 'sha256', 'ripemd160', 'ecrecover', 'addmod', 'mulmod', 'selfdestruct', 'suicide',
  'gasleft', 'blobhash',
]);

// uint8..uint256 / int8..int256 / bytes1..bytes32 / fixedMxN — a sized value type, kept verbatim.
function sizedType(id) {
  return /^(u?int|bytes)\d+$/.test(id) || /^u?fixed\d+x\d+$/.test(id);
}

// Strip // line comments and /* */ block comments (string-literal-naive, but seed+match run the
// SAME stripper so any edge case is symmetric and cannot desync a hash).
function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}

const TOK = /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|0x[0-9a-fA-F]+|\d[\d_.eE]*|[A-Za-z_$][\w$]*|\S/g;

function normalize(unit) {
  const toks = unit.match(TOK) || [];
  const out = [];
  for (const t of toks) {
    const c = t[0];
    if (c === '"' || c === "'") { out.push('0'); continue; }      // string literal
    if (c === '0' && (t[1] === 'x' || t[1] === 'X')) { out.push('0'); continue; } // hex number
    if (c >= '0' && c <= '9') { out.push('0'); continue; }        // number literal
    if (/[A-Za-z_$]/.test(c)) {                                    // identifier
      out.push(KEEP.has(t) || sizedType(t) ? t : '_');
      continue;
    }
    out.push(t);                                                  // punctuation / operator, verbatim
  }
  return out.join(' ');
}

// Extract each function as `function <name>(<params>) <mods> { <brace-matched body> }` (or the
// `;`-terminated declaration for an interface/abstract function with no body). Returns
// [{name, unit}] in source order.
function extractFunctions(code) {
  const out = [];
  const head = /\bfunction\s+([A-Za-z_$][\w$]*)\s*\(/g;
  let m;
  while ((m = head.exec(code)) !== null) {
    const name = m[1];
    const start = m.index;
    // find end of the parameter list (balanced parens from the '(' we just matched)
    let i = head.lastIndex - 1; // at '('
    let depth = 0, parenEnd = -1;
    for (; i < code.length; i++) {
      if (code[i] === '(') depth++;
      else if (code[i] === ')') { depth--; if (depth === 0) { parenEnd = i; break; } }
    }
    if (parenEnd < 0) continue;
    // scan past modifiers/returns to the body '{' or the declaration ';'
    let j = parenEnd + 1;
    while (j < code.length && code[j] !== '{' && code[j] !== ';') j++;
    if (j >= code.length) break;
    let end;
    if (code[j] === ';') {
      end = j + 1; // no-body declaration
    } else {
      // brace-match the body
      let bd = 0;
      let k = j;
      for (; k < code.length; k++) {
        if (code[k] === '{') bd++;
        else if (code[k] === '}') { bd--; if (bd === 0) { k++; break; } }
      }
      end = k;
    }
    out.push({ name, unit: code.slice(start, end) });
    head.lastIndex = end; // continue after this function (skip nested `function` in the body)
  }
  return out;
}

function main() {
  const file = process.argv[2];
  if (!file) return;
  let src;
  try { src = fs.readFileSync(file, 'utf8'); } catch (e) { return; }
  const code = stripComments(src);
  const fns = extractFunctions(code);
  const lines = fns.map((f) => f.name + ':::' + normalize(f.unit));
  if (lines.length) process.stdout.write(lines.join('\n') + '\n');
}

// Exported so the M3 recall harness's variant generator (make-variants.js) renames EXACTLY the
// identifiers this normalizer drops — keeping a generated fork's signature identical to its seed.
// Only run as a script when invoked directly (so `require()` doesn't trigger main()).
module.exports = { KEEP, sizedType, normalize, extractFunctions, stripComments, TOK };

if (require.main === module) main();
