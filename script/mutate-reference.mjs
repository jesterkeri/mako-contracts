// Mutation run for the reference implementation, per PROOF_STANDARD.md Version 3 §4.
//
//   node script/mutate-reference.mjs
//
// A corpus that every implementation passes might still be a corpus with no teeth. §4 requires each
// rule clause to be deliberately broken, one at a time, and EVERY mutation to make at least one row
// fail. The review of the Version 3 draft asked specifically for mutations that break the Solidity
// and the JavaScript evaluators INDEPENDENTLY, with the corpus unchanged, so a corpus that can
// absorb a mutation is caught.
//
// This is the JavaScript half. The Solidity half comes with src/RoundSettlement.sol.
//
// Mutations are applied to a COPY in a temp directory. The original file is never edited and
// `git checkout` is never used, per the standing rule about undoing uncommitted work.

import { mkdtempSync, writeFileSync, readFileSync, cpSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, '..');
const SRC = join(HERE, 'rule-reference.mjs');

// Each mutation names the spec clause it breaks and the rows that must then fail.
const MUTATIONS = [
  {
    name: 'step 1: delete the fee-manager gate',
    clause: 'SPEC 5.2 step 1',
    from: `  if (feeManager.toLowerCase() !== ZERO_ADDRESS) {`,
    to: `  if (false) {`,
    mustFail: ['reject-fee-manager-present'],
  },
  {
    name: 'step 3: accept any payload length',
    clause: 'SPEC 5.2 step 3',
    from: `  if (payload.length !== 288) {`,
    to: `  if (false) {`,
    mustFail: ['reject-short-return-287', 'reject-long-return-289'],
  },
  {
    name: 'step 3: drop the 0x0003 prefix check',
    clause: 'SPEC 5.2 step 3',
    from: `  if (payload.subarray(0, 2).toString('hex') !== '0003') {`,
    to: `  if (false) {`,
    mustFail: ['reject-v8-shaped-return', 'reject-v11-shaped-return'],
    note: 'These rows still REJECT with the prefix check gone, as WrongFeed, because the prefix is part of the feed id. Only asserting the exact error name detects this mutation. If this mutation ever survives, the corpus has stopped checking selectors.',
  },
  {
    name: 'step 4: skip the feed comparison',
    clause: 'SPEC 5.2 step 4',
    from: `  if (r.feedId.toLowerCase() !== FEED_ID.toLowerCase()) {`,
    to: `  if (false) {`,
    mustFail: ['reject-other-feed', 'reject-decodes-verified-not-input'],
  },
  {
    name: 'step 5: allow observationsTimestamp != B',
    clause: 'SPEC 5.2 step 5',
    from: `  if (r.observationsTimestamp !== BigInt(boundary)) {`,
    to: `  if (false) {`,
    mustFail: ['reject-one-second-early', 'reject-one-second-late'],
  },
  {
    name: 'step 5: allow validFrom after the observation',
    clause: 'SPEC 5.2 step 5',
    from: `  if (r.validFromTimestamp > r.observationsTimestamp) {`,
    to: `  if (false) {`,
    mustFail: ['reject-validfrom-after-observation'],
  },
  {
    name: 'step 6: accept a non-positive price',
    clause: 'SPEC 5.2 step 6',
    from: `  if (r.price <= 0n) {`,
    to: `  if (false) {`,
    mustFail: ['reject-price-zero', 'reject-price-negative', 'reject-price-int192-min'],
  },
  {
    name: 'step 6: drop bid <= price <= ask',
    clause: 'SPEC 5.2 step 6',
    from: `  if (!(r.bid <= r.price && r.price <= r.ask)) {`,
    to: `  if (false) {`,
    mustFail: ['reject-bid-above-price', 'reject-ask-below-price'],
  },
  {
    name: 'step 6: compare the spread with >= instead of >',
    clause: 'SPEC 5.2 step 6',
    from: `  if (spread * 10000n > r.price * MAX_SPREAD_BPS) {`,
    to: `  if (spread * 10000n >= r.price * MAX_SPREAD_BPS) {`,
    mustFail: ['accept-spread-exactly-at-limit'],
    note: 'The boundary row is what catches an off-by-one on an inequality. Without it the mutation survives.',
  },
  {
    name: 'step 6: widen MAX_SPREAD_BPS',
    clause: 'SPEC 5.2 step 6',
    from: `const MAX_SPREAD_BPS = 50n;`,
    to: `const MAX_SPREAD_BPS = 51n;`,
    mustFail: ['reject-spread-one-bps-over'],
  },
  {
    name: 'step 7: use >= for expiry instead of >',
    clause: 'SPEC 5.2 step 7',
    from: `  if (BigInt(blockTimestamp) > r.expiresAt) {`,
    to: `  if (BigInt(blockTimestamp) >= r.expiresAt) {`,
    mustFail: ['accept-at-expiry-boundary'],
    note: 'This is the load-bearing one. VerifierProxy.verify does not check expiry at all, measured 2026-09-22, so step 7 is the only expiry defence anywhere in this system.',
  },
  {
    name: 'step 7: delete the expiry check',
    clause: 'SPEC 5.2 step 7',
    from: `  if (BigInt(blockTimestamp) > r.expiresAt) {`,
    to: `  if (false) {`,
    mustFail: ['reject-expired-by-one-second', 'reject-expired-at-uint32-max-boundary'],
  },
  {
    name: 'step 6: take the spread difference in a 192-bit window',
    clause: 'SPEC 5.2 step 6',
    from: `  const spread = r.ask - r.bid;`,
    to: `  const spread = BigInt.asIntN(192, r.ask - r.bid);`,
    mustFail: ['reject-spread-max-integer-must-not-panic'],
    note: 'The Solidity analogue of int192 truncation. Taking the difference in 192 bits wraps INT192_MAX - INT192_MIN to -1, which then compares as inside the limit and the row is wrongly accepted. In Solidity the same mistake panics with 0x11 instead. Either way the mandated maximum-integer row is what catches it.',
  },
];

const original = readFileSync(SRC, 'utf8');
const results = [];
let survived = 0;

console.log(`Mutation run: ${MUTATIONS.length} mutations against ${MUTATIONS.length ? 'script/rule-reference.mjs' : ''}\n`);

for (const m of MUTATIONS) {
  const count = original.split(m.from).length - 1;
  if (count !== 1) {
    console.log(`  [SKIP] ${m.name}`);
    console.log(`         anchor matched ${count} times, expected exactly 1. The mutation is not applied, so the clause is UNPROVEN.`);
    results.push({ ...m, status: 'ANCHOR_STALE', matched: count });
    survived++;
    continue;
  }

  const dir = mkdtempSync(join(tmpdir(), 'mako-mut-'));
  try {
    cpSync(join(REPO, 'script'), join(dir, 'script'), { recursive: true });
    cpSync(join(REPO, 'test'), join(dir, 'test'), { recursive: true });
    writeFileSync(join(dir, 'script/rule-reference.mjs'), original.replace(m.from, m.to));

    let out = '', code = 0;
    try { out = execFileSync('node', [join(dir, 'script/rule-reference.mjs'), '--json'], { encoding: 'utf8' }); }
    catch (e) { out = e.stdout || ''; code = e.status ?? 1; }

    let failedIds = [];
    try { failedIds = JSON.parse(out).rows.filter((r) => r.status === 'DISAGREES').map((r) => r.id); }
    catch { failedIds = []; }

    const missed = m.mustFail.filter((id) => !failedIds.includes(id));
    const killed = failedIds.length > 0;
    const status = !killed ? 'SURVIVED' : missed.length ? 'PARTIAL' : 'KILLED';
    if (status !== 'KILLED') survived++;

    console.log(`  [${status === 'KILLED' ? ' ok ' : 'FAIL'}] ${m.name}`);
    console.log(`         ${m.clause}   ${killed ? `${failedIds.length} row(s) failed: ${failedIds.join(', ')}` : 'NO ROW FAILED'}`);
    if (missed.length) console.log(`         expected these to fail and they did not: ${missed.join(', ')}`);
    if (m.note && status !== 'KILLED') console.log(`         note: ${m.note}`);
    results.push({ ...m, status, failedIds, missed, exitCode: code });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

console.log(`\n  ${results.filter((r) => r.status === 'KILLED').length} killed, ${survived} not killed`);
console.log(`\n  A surviving mutation is a missing row in CASES.json, not a passing run.`);
console.log(`  The original script/rule-reference.mjs was never modified: every mutation ran on a copy`);
console.log(`  in a temp directory, which is then removed.`);

if (survived > 0) process.exit(1);
console.log(`\n  Every clause of SPEC 5.2 is load-bearing in the reference implementation.`);
