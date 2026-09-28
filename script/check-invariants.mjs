// T1.4: check that the invariant coverage map is TRUE.
//
//   node script/check-invariants.mjs
//
// Reads test/fixtures/invariant-coverage.json and fails unless:
//   - its invariants are exactly EXPECTED below, and, where the design repository is checked out beside this
//     one, EXPECTED is exactly the id column of INVARIANTS.md's "Enforced by the contract" table;
//   - every invariant has evidence that RUNS IN CI (a test outside the fork suite, a corpus row, or a
//     script), or a deferral naming its owner task;
//   - every named test is a real public or external `test...` function, outside comments, in one of the
//     rounds and settlement SUITES below (not merely any .sol file);
//   - every corpus row exists in test/fixtures/rule-cases/CASES.json, and every script exists.
// The adversary pass on T1.4 showed the first version accepting a test name that existed only in a comment,
// a test from another contract's suite, and an invariant deleted from both lists at once. It proves the map
// points at real evidence; that each test can FAIL for its invariant is script/mutate-solidity.mjs's job.

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');

// The contract-enforced invariants of mako-design/blueprint/INVARIANTS.md r8. Held HERE, not in the JSON
// being checked, so dropping an invariant from the map cannot also drop it from the expectation.
const EXPECTED = ['N1', 'N1b', 'N1c', 'N2', 'N3', 'N5', 'N6', 'N7', 'N8', 'N9', 'N10', 'N11', 'N12', 'N13', 'N14',
  'N16', 'N17', 'N18', 'N19', 'N22', 'N25', 'N26', 'N27'];

// The suites that test MakoRoundsV1 and RoundSettlement. The fork suite skips offline, so its tests count as
// evidence but not as CI evidence.
const SUITES = ['test/MakoRoundsV1.t.sol', 'test/Adversary.t.sol', 'test/InvariantGaps.t.sol', 'test/RoundSettlement.t.sol',
  'test/RuleCorpus.t.sol', 'test/RoundSettlementFork.t.sol'];
const FORK_SUITE = 'test/RoundSettlementFork.t.sol';

const map = JSON.parse(readFileSync(join(REPO, 'test/fixtures/invariant-coverage.json'), 'utf8'));
const corpus = JSON.parse(readFileSync(join(REPO, 'test/fixtures/rule-cases/CASES.json'), 'utf8'));
const problems = [];

// ---- the tests that really exist ----
const stripComments = (src) => src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
const tests = new Map(); // name -> suite
for (const f of SUITES) {
  const code = stripComments(readFileSync(join(REPO, f), 'utf8'));
  for (const m of code.matchAll(/function\s+(test[A-Za-z0-9_]*)\s*\([^)]*\)\s*(?:public|external)\b/g)) tests.set(m[1], f);
}
const rows = new Set(corpus.cases.map((c) => c.id));

// ---- the expected set, and INVARIANTS.md when it is available ----
const ids = Object.keys(map.invariants);
for (const id of EXPECTED) if (!ids.includes(id)) problems.push(`${id}: expected but has no entry`);
for (const id of ids) if (!EXPECTED.includes(id)) problems.push(`${id}: has an entry but is not an expected invariant`);
const design = join(REPO, '..', 'mako-design', 'blueprint', 'INVARIANTS.md');
let designNote = 'INVARIANTS.md not checked out beside this repository; checked against the pinned list only';
if (existsSync(design)) {
  const text = readFileSync(design, 'utf8');
  const section = text.split(/^## /m).find((s) => s.startsWith('Enforced by the contract')) || '';
  const tableIds = [...section.matchAll(/^\|\s*(N\d+[a-z]?)\s*\|/gm)].map((m) => m[1]);
  const missing = tableIds.filter((i) => !EXPECTED.includes(i));
  const stale = EXPECTED.filter((i) => !tableIds.includes(i));
  if (missing.length) problems.push(`INVARIANTS.md lists ${missing.join(', ')}, which EXPECTED does not`);
  if (stale.length) problems.push(`EXPECTED lists ${stale.join(', ')}, which INVARIANTS.md does not`);
  designNote = `EXPECTED equals INVARIANTS.md's contract table (${tableIds.length} ids)`;
}

// ---- every entry ----
let testRefs = 0, rowRefs = 0, scriptRefs = 0;
const deferred = [];
for (const [id, e] of Object.entries(map.invariants)) {
  const t = e.tests || [], r = e.corpusRows || [], s = e.scripts || [];
  if (e.deferred && !(e.deferred.owner && e.deferred.reason)) problems.push(`${id}: a deferral must name its owner task and reason`);
  if (e.deferred) deferred.push(`${id} -> ${e.deferred.owner}`);
  for (const name of t) {
    testRefs++;
    if (!tests.has(name)) problems.push(`${id}: ${name} is not a public test function in the rounds and settlement suites`);
  }
  for (const row of r) { rowRefs++; if (!rows.has(row)) problems.push(`${id}: corpus row ${row} does not exist in CASES.json`); }
  for (const p of s) { scriptRefs++; if (!existsSync(join(REPO, p))) problems.push(`${id}: script ${p} does not exist`); }
  const runsInCi = t.some((n) => tests.has(n) && tests.get(n) !== FORK_SUITE) || r.length > 0 || s.length > 0;
  if (!runsInCi && !e.deferred) problems.push(`${id}: no evidence that runs in CI (fork tests skip offline) and no deferral`);
}

if (problems.length) {
  console.error('INVARIANT COVERAGE MAP IS WRONG:');
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log(`invariant coverage: ${ids.length} contract-enforced invariants, ${testRefs} test, ${rowRefs} corpus-row and ${scriptRefs} script references, all real.`);
console.log(`  ${designNote}.`);
console.log(`  deferred with an owner: ${deferred.join(', ') || 'none'}`);
