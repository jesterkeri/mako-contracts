// T1.4: check that the invariant coverage map is TRUE.
//
//   node script/check-invariants.mjs
//
// Reads test/fixtures/invariant-coverage.json and fails unless:
//   - every contract-enforced invariant in its `expected` list has an entry, and no entry is unexpected;
//   - every entry has evidence: at least one test, corpus row or script, or a deferral naming its owner task;
//   - every named test exists as a function in test/*.sol;
//   - every corpus row exists in test/fixtures/rule-cases/CASES.json;
//   - every named script exists.
// It proves the map points at real evidence. That each test can FAIL for its invariant is the mutation
// sweep's job (script/mutate-solidity.mjs). Dependency-free.

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const map = JSON.parse(readFileSync(join(REPO, 'test/fixtures/invariant-coverage.json'), 'utf8'));
const corpus = JSON.parse(readFileSync(join(REPO, 'test/fixtures/rule-cases/CASES.json'), 'utf8'));

const tests = new Set();
for (const f of readdirSync(join(REPO, 'test')).filter((n) => n.endsWith('.sol'))) {
  for (const m of readFileSync(join(REPO, 'test', f), 'utf8').matchAll(/function\s+(test[A-Za-z0-9_]*)\s*\(/g)) tests.add(m[1]);
}
const rows = new Set(corpus.cases.map((c) => c.id));

const problems = [];
const ids = Object.keys(map.invariants);
for (const id of map.expected) if (!ids.includes(id)) problems.push(`${id}: expected but has no entry`);
for (const id of ids) if (!map.expected.includes(id)) problems.push(`${id}: has an entry but is not an expected invariant`);

let testRefs = 0, rowRefs = 0, scriptRefs = 0;
const deferred = [];
for (const [id, e] of Object.entries(map.invariants)) {
  const t = e.tests || [], r = e.corpusRows || [], s = e.scripts || [];
  if (!t.length && !r.length && !s.length && !e.deferred) problems.push(`${id}: no evidence and no deferral`);
  if (e.deferred && !(e.deferred.owner && e.deferred.reason)) problems.push(`${id}: a deferral must name its owner task and reason`);
  if (e.deferred) deferred.push(`${id} -> ${e.deferred.owner}`);
  for (const name of t) { testRefs++; if (!tests.has(name)) problems.push(`${id}: test ${name} does not exist in test/*.sol`); }
  for (const row of r) { rowRefs++; if (!rows.has(row)) problems.push(`${id}: corpus row ${row} does not exist in CASES.json`); }
  for (const p of s) { scriptRefs++; if (!existsSync(join(REPO, p))) problems.push(`${id}: script ${p} does not exist`); }
}

if (problems.length) {
  console.error('INVARIANT COVERAGE MAP IS WRONG:');
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log(`invariant coverage: ${ids.length} contract-enforced invariants, ${testRefs} test, ${rowRefs} corpus-row and ${scriptRefs} script references, all real.`);
console.log(`  deferred with an owner: ${deferred.join(', ') || 'none'}`);
