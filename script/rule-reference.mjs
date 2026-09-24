// The independent reference implementation of SPEC §5.2, for PROOF_STANDARD.md Version 3 §2.
//
//   node script/rule-reference.mjs            evaluate the corpus, print a table
//   node script/rule-reference.mjs --json     emit the verdicts for the Foundry side to compare
//
// §2 requires the rule to be computed twice by independent code, both driven from the same corpus
// as DATA, each asserting its own result against the corpus's expected value FIRST, and only then
// compared with each other. This is the second implementation. The first is
// src/RoundSettlement.sol, which does not exist yet: §3 and INVARIANTS.md:45 both require the case
// table and the rule test to come before it.
//
// INDEPENDENCE, stated so a reviewer can check it rather than take it on trust:
//   - This file shares no code with script/build-cases.mjs. It has its own decoder and does not
//     import anything from the generator. The generator encodes; this decodes; neither calls the
//     other. An error in one is not mirrored by the other.
//   - It never reads `expect` before computing. `evaluate()` takes bytes and a boundary and returns
//     a verdict. The comparison against `expect` happens afterwards, in the caller.
//   - It is deliberately written as a flat list of seven checks in spec order, with no abstraction,
//     because the point is to be obviously correct rather than elegant.
//
// A row where this implementation and the corpus disagree is a finding in one of them, and which
// one is a question for review, not for whichever is more convenient.

import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, '..');
const JSON_OUT = process.argv.includes('--json');

// Pinned from blueprint/SPEC.md, independently of the generator's copy.
const FEED_ID = '0x00037da06d56d083fe599397a4769a042d63aa73dc4ef57709d31e9971a5b439';
const MAX_SPREAD_BPS = 50n;
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';

// ---- its own decoder. Nine 32-byte words out of a dynamic-bytes ABI envelope. ----
function unwrapAbiBytes(hexStr) {
  const raw = Buffer.from(hexStr.replace(/^0x/, ''), 'hex');
  if (raw.length < 64) return { error: `raw return ${raw.length} bytes, shorter than an ABI envelope` };
  const len = Number(BigInt('0x' + raw.subarray(32, 64).toString('hex')));
  return { payload: raw.subarray(64, 64 + len), rawLength: raw.length, declaredLength: len };
}

function readInt192(buf) {
  // The word is a 256-bit two's complement sign extension of an int192.
  let v = BigInt('0x' + buf.toString('hex'));
  if (v >> 255n) v -= 1n << 256n;
  return v;
}

function decodePayload(payload) {
  const at = (i) => payload.subarray(i * 32, (i + 1) * 32);
  const uint = (i) => BigInt('0x' + at(i).toString('hex'));
  return {
    feedId: '0x' + at(0).toString('hex'),
    validFromTimestamp: uint(1),
    observationsTimestamp: uint(2),
    nativeFee: uint(3),
    linkFee: uint(4),
    expiresAt: uint(5),
    price: readInt192(at(6)),
    bid: readInt192(at(7)),
    ask: readInt192(at(8)),
  };
}

// ---- SPEC §5.2, seven checks, in order, computed with no knowledge of the expected result ----
function evaluate({ feeManager, verifierBehaviour, returnData, boundary, blockTimestamp }) {
  // step 1: the fee manager, BEFORE verify
  if (feeManager.toLowerCase() !== ZERO_ADDRESS) {
    return { verdict: 'reject', errorName: 'FeeManagerEnabled', reachedVerify: false, atStep: 1 };
  }

  // step 2: verify
  if (verifierBehaviour === 'revert') {
    return { verdict: 'reject', errorName: null, bubbles: 'verifier', reachedVerify: true, atStep: 2 };
  }

  // step 3: exactly 288 bytes with prefix 0x0003, and only the RETURN is decoded
  const un = unwrapAbiBytes(returnData);
  if (un.error) return { verdict: 'reject', errorName: 'WrongSchema', reachedVerify: true, atStep: 3, why: un.error };
  const payload = un.payload;
  if (payload.length !== 288) {
    return { verdict: 'reject', errorName: 'WrongSchema', reachedVerify: true, atStep: 3, why: `payload is ${payload.length} bytes, not 288` };
  }
  if (payload.subarray(0, 2).toString('hex') !== '0003') {
    return { verdict: 'reject', errorName: 'WrongSchema', reachedVerify: true, atStep: 3, why: `prefix is 0x${payload.subarray(0, 2).toString('hex')}, not 0x0003` };
  }
  const r = decodePayload(payload);

  // step 4: the feed
  if (r.feedId.toLowerCase() !== FEED_ID.toLowerCase()) {
    return { verdict: 'reject', errorName: 'WrongFeed', reachedVerify: true, atStep: 4 };
  }

  // step 5: the observation second, and a window that may start early but never late
  if (r.observationsTimestamp !== BigInt(boundary)) {
    return { verdict: 'reject', errorName: 'WrongObservationTime', reachedVerify: true, atStep: 5 };
  }
  if (r.validFromTimestamp > r.observationsTimestamp) {
    return { verdict: 'reject', errorName: 'ValidFromAfterObservation', reachedVerify: true, atStep: 5 };
  }

  // step 6: sanity. The spread is compared in uint256, which is why nothing here panics.
  if (r.price <= 0n) {
    return { verdict: 'reject', errorName: 'NonPositivePrice', reachedVerify: true, atStep: 6 };
  }
  if (!(r.bid <= r.price && r.price <= r.ask)) {
    return { verdict: 'reject', errorName: 'BidAskOutOfOrder', reachedVerify: true, atStep: 6 };
  }
  // BigInt is arbitrary precision, so this cannot overflow here. In Solidity the difference must be
  // taken as int256 and widened to uint256 before the multiply, or the mandated maximum-integer row
  // panics with 0x11 instead of rejecting. That is the whole reason step 6 names uint256.
  const spread = r.ask - r.bid;
  if (spread * 10000n > r.price * MAX_SPREAD_BPS) {
    return { verdict: 'reject', errorName: 'SpreadTooWide', reachedVerify: true, atStep: 6 };
  }

  // step 7: expiry, which VerifierProxy.verify does NOT check. Measured 2026-09-22.
  if (BigInt(blockTimestamp) > r.expiresAt) {
    return { verdict: 'reject', errorName: 'ReportExpired', reachedVerify: true, atStep: 7 };
  }

  return { verdict: 'accept', report: r, reachedVerify: true, atStep: 7 };
}

// ---- the real row's verified return comes from ONE PINNED Type B1 record ----
// The corpus cannot carry a verified return for the real fixture: producing one needs the real verifier.
// So the real row is evaluated against a B1 record, and that record is PINNED by path and checksum in the
// corpus. The FIRST version took whichever archive-probe directory sorted last, so a later failed run, or
// no evidence at all, turned the mandatory row into a skip while this gate still exited 0. The Codex diff
// review caught it: unavailable evidence is an UNMET claim, never a bypass (PROOF_STANDARD §11).
//
// What the record must say is hardcoded HERE, independently of the generator, so the corpus cannot
// quietly relax it:
const REQUIRED = {
  status: 'VERIFIED_MATCH',
  proofLevel: 'two-distinct-operators',
  block: 62922075,
  blockHash: '0x73f54743b7db644c8f010e74f422107337b586b59fed5a91916f98b384a722d6',
  blockTimestamp: 1789529160,
};

function sha256File(abs) {
  return createHash('sha256').update(readFileSync(abs)).digest('hex');
}

function realVerifiedReturn(corpus) {
  const pin = corpus._realEvidence;
  if (!pin || !pin.record || !pin.fixture) return { failed: 'the corpus pins no B1 record' };
  for (const f of [pin.record, pin.fixture]) {
    const abs = join(REPO, f.path);
    if (!existsSync(abs)) return { failed: `pinned file missing: ${f.path}` };
    const got = sha256File(abs);
    if (got !== f.sha256) return { failed: `pinned file changed: ${f.path} sha256 ${got.slice(0, 12)}... != pinned ${f.sha256.slice(0, 12)}...` };
  }
  const res = JSON.parse(readFileSync(join(REPO, pin.record.path), 'utf8'));
  if (res.status !== REQUIRED.status) return { failed: `pinned record status is ${res.status}, not ${REQUIRED.status}` };
  if (res.proofLevel !== REQUIRED.proofLevel) return { failed: `pinned record proofLevel is ${res.proofLevel}, not ${REQUIRED.proofLevel}` };
  if (res.target?.block !== REQUIRED.block || res.target?.blockHash !== REQUIRED.blockHash || res.target?.blockTimestamp !== REQUIRED.blockTimestamp) {
    return { failed: 'pinned record is not for the pinned block, hash and timestamp' };
  }
  const returns = Object.values(res.providers || {}).map((p) => p.rawResult);
  if (returns.length !== 2 || !returns[0] || returns[0] !== returns[1]) return { failed: 'pinned record lacks two byte-identical verified returns' };
  return { returnData: returns[0], run: pin.record.path, proofLevel: res.proofLevel };
}

// ---- run the corpus ----
const corpus = JSON.parse(readFileSync(join(REPO, 'test/fixtures/rule-cases/CASES.json'), 'utf8'));
const real = realVerifiedReturn(corpus);

const rows = [];
let agreed = 0, disagreed = 0, failed = 0;

for (const c of corpus.cases) {
  let input;
  if (c.source === 'real') {
    if (real.failed) {
      // A FAILURE, never a skip. The mandatory real row cannot be silently dropped from this half of §2.
      rows.push({ id: c.id, status: 'FAILED', why: real.failed });
      failed++;
      continue;
    }
    input = { feeManager: c.verifier.feeManager, verifierBehaviour: 'return', returnData: real.returnData, boundary: c.boundary, blockTimestamp: c.warpTo };
  } else {
    input = { feeManager: c.verifier.feeManager, verifierBehaviour: c.verifier.behaviour, returnData: c.verifier.returnData, boundary: c.boundary, blockTimestamp: c.warpTo };
  }

  // compute first, compare after
  const got = evaluate(input);

  const verdictOk = got.verdict === c.expect.verdict;
  const errorOk = c.expect.verdict === 'accept'
    ? true
    : (c.expect.errorName === null ? got.errorName === null : got.errorName === c.expect.errorName);
  const ok = verdictOk && errorOk;
  if (ok) agreed++; else disagreed++;

  rows.push({
    id: c.id,
    status: ok ? 'AGREES' : 'DISAGREES',
    expected: c.expect.verdict === 'accept' ? 'accept' : (c.expect.errorName || 'reject (verifier)'),
    got: got.verdict === 'accept' ? 'accept' : (got.errorName || 'reject (verifier)'),
    atStep: got.atStep,
    ...(got.why ? { why: got.why } : {}),
    specClauses: c.specClauses,
    ...(c.requiredTestName ? { requiredTestName: c.requiredTestName } : {}),
  });
}

if (JSON_OUT) {
  console.log(JSON.stringify({
    evaluatedAt: new Date().toISOString(),
    implementation: 'script/rule-reference.mjs',
    corpusVersion: corpus._version,
    realRowEvidence: !real.failed ? { run: real.run, proofLevel: real.proofLevel } : null,
    totals: { agreed, disagreed, failed },
    rows,
  }, null, 2));
  process.exit(disagreed === 0 && failed === 0 ? 0 : 1);
}

console.log(`SPEC 5.2 reference implementation against CASES.json v${corpus._version}\n`);
for (const r of rows) {
  const mark = r.status === 'AGREES' ? ' ok ' : 'FAIL';
  console.log(`  [${mark}] ${r.id.padEnd(42)} ${r.status === 'FAILED' ? r.why : `expected ${String(r.expected).padEnd(26)} got ${r.got}`}`);
  if (r.status === 'DISAGREES' && r.why) console.log(`         why: ${r.why}`);
}
console.log(`\n  ${agreed} agree, ${disagreed} disagree, ${failed} failed`);
if (!real.failed) console.log(`  real row evaluated from ${real.run} (proofLevel: ${real.proofLevel})`);
console.log(`\n  This is ONE of the two implementations PROOF_STANDARD.md Version 3 section 2 requires.`);
console.log(`  The other is src/RoundSettlement.sol, evaluated on the same rows by test/RoundSettlement.t.sol`);
console.log(`  (mock rows) and test/RoundSettlementFork.t.sol (the real row, against the real verifier).`);
process.exit(disagreed === 0 && failed === 0 ? 0 : 1);
