#!/usr/bin/env node
// Assemble a decomposed EVM PoC: splice the LLM's two small slot-fills (CONTROL, EXPLOIT) into
// the fixed poc-skeleton.rs at its `// <<CONTROL>>` / `// <<EXPLOIT>>` markers (#982). Each fill
// is a small Rust fragment; the LLM tends to wrap it in a ```rust fence + prose, so we extract the
// fenced code (or strip stray fences) before splicing. Prints the assembled poc.rs to stdout.
//
// Usage: node assemble-poc.js <skeleton.rs> <control-fill> <exploit-fill>
'use strict';
const fs = require('fs');

// Pull the Rust out of an LLM fill: prefer the first ```...``` block (dropping an optional
// `rust`/`rs` language tag), else drop any stray ``` lines and surrounding prose. Total on any shape.
function extractCode(raw) {
  const fence = raw.match(/```(?:rust|rs)?\s*\n([\s\S]*?)```/);
  if (fence) return fence[1].replace(/\s+$/, '');
  // no fenced block — drop bare ``` lines and trim
  return raw.split('\n').filter((l) => l.trim() !== '```' && !/^```/.test(l.trim())).join('\n').replace(/\s+$/, '');
}

function main() {
  const [skelPath, ctrlPath, explPath] = process.argv.slice(2);
  if (!skelPath || !ctrlPath || !explPath) {
    console.error('usage: assemble-poc.js <skeleton.rs> <control-fill> <exploit-fill>');
    process.exit(2);
  }
  let skel = fs.readFileSync(skelPath, 'utf8');
  const control = extractCode(fs.readFileSync(ctrlPath, 'utf8'));
  const exploit = extractCode(fs.readFileSync(explPath, 'utf8'));
  if (skel.indexOf('// <<CONTROL>>') < 0 || skel.indexOf('// <<EXPLOIT>>') < 0) {
    console.error('skeleton missing // <<CONTROL>> or // <<EXPLOIT>> marker');
    process.exit(1);
  }
  // indent the fills to match the marker (4 spaces inside main) for readable output; not required to compile
  const indent = (code) => code.split('\n').map((l) => (l.length ? '    ' + l : l)).join('\n');
  // Replace the marker as a STANDALONE line (anchored, `m` flag) so a prose mention of the marker
  // elsewhere (e.g. a doc comment) is never hit; a FUNCTION replacement keeps `$` in the fill literal.
  const splice = (s, name, label, fill) =>
    s.replace(new RegExp('^[ \\t]*// <<' + name + '>>[ \\t]*$', 'm'), () => '    // ---- ' + label + ' (generated) ----\n' + indent(fill));
  skel = splice(skel, 'CONTROL', 'CONTROL', control);
  skel = splice(skel, 'EXPLOIT', 'EXPLOIT', exploit);
  process.stdout.write(skel);
}

main();
