// Builds test/fixtures/rule-cases/CASES.json, the shared rule-case corpus.
//
//   node script/build-cases.mjs            write the corpus
//   node script/build-cases.mjs --check    verify the committed corpus matches this generator
//
// PROOF_STANDARD.md Version 3 §3 requires the rule to be written as a case table BEFORE the
// implementation, each row naming its expected result, its error selector and the spec clause it
// comes from. §2 requires two independent implementations driven from that table as DATA, each
// asserting against the expected result before the two are compared.
//
// THE DIVISION OF LABOUR HERE IS THE WHOLE POINT, so it is stated plainly:
//
//   - Every expected verdict and selector below is **authored by hand** from SPEC §5.2. This
//     generator NEVER computes an expected result. If it did, the corpus would be one
//     implementation's output and the "independent" second evaluation would be circular.
//   - This generator only **encodes declared field values into bytes**. That is mechanical work a
//     human transcribing 352-byte hex strings would get wrong.
//
// The encoder is validated against reality, not against itself: ENCODER_GROUND_TRUTH re-encodes the
// real verifier's return for the mandatory fixture from its decoded field values and asserts the
// bytes are identical to what Monad testnet actually returned. If the encoder is wrong, that fails.

import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, '..');
const OUT = join(REPO, 'test/fixtures/rule-cases/CASES.json');
const CHECK = process.argv.includes('--check');

const FEED_ID = '0x00037da06d56d083fe599397a4769a042d63aa73dc4ef57709d31e9971a5b439';
const OTHER_FEED = '0x0003aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const V8_FEED = '0x0008b8bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const V11_FEED = '0x000bcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const MAX_SPREAD_BPS = 50n;
const INT192_MAX = (1n << 191n) - 1n;
const INT192_MIN = -(1n << 191n);

// The real fixture's verified fields. Baseline for every mock case, so each row differs from a
// known-good report by exactly one thing.
const REAL = {
  feedId: FEED_ID,
  validFromTimestamp: 1789529157n,
  observationsTimestamp: 1789529160n,
  nativeFee: 132915204253287n,
  linkFee: 29384890485513791n,
  expiresAt: 1792121160n,
  price: 75938791787880000000000n,
  bid: 75935199000000000000000n,
  ask: 75944083700820000000000n,
};
const B = Number(REAL.observationsTimestamp); // the boundary second
const P = REAL.price;

// ---- encoding ----
const sha256 = (b) => createHash('sha256').update(b).digest('hex');
function word(v) {
  if (typeof v === 'string') return v.replace(/^0x/, '').padStart(64, '0');
  let x = BigInt(v);
  if (x < 0n) x += 1n << 256n; // two's complement, sign-extended to 256 bits
  return x.toString(16).padStart(64, '0');
}
function payload(f) {
  return '0x' + [f.feedId, f.validFromTimestamp, f.observationsTimestamp, f.nativeFee,
    f.linkFee, f.expiresAt, f.price, f.bid, f.ask].map(word).join('');
}
// The mock returns the ABI encoding of a single `bytes`: offset, length, then the padded payload.
function abiWrapBytes(hexStr) {
  const body = hexStr.replace(/^0x/, '');
  const len = body.length / 2;
  return '0x' + word(32) + word(len) + body.padEnd(Math.ceil(len / 32) * 64, '0');
}
function resize(payloadHex, bytes) {
  const body = payloadHex.replace(/^0x/, '');
  return '0x' + (bytes * 2 <= body.length ? body.slice(0, bytes * 2) : body.padEnd(bytes * 2, '0'));
}

// ---- the corpus. EXPECTED VERDICTS ARE AUTHORED, NOT COMPUTED. ----
const ZERO = '0x0000000000000000000000000000000000000000';
const NONZERO_FM = '0x000000000000000000000000000000000000BEEF';

const cases = [
  // ---------- accept ----------
  {
    id: 'accept-real-widened-window',
    specClauses: ['SPEC 5.2 step 5', 'N1'],
    requiredTestName: 'test_AcceptsWindowEndingAtBoundary',
    source: 'real',
    realFixture: 'test/fixtures/datastreams/pending/btcusd-1789529160.json',
    note: 'The only captured report with validFromTimestamp < observationsTimestamp. Runs on the fork against the real verifier, never against a mock.',
    feeManager: ZERO, boundary: B, warpTo: B,
    expect: { verdict: 'accept' },
  },
  {
    id: 'accept-zero-width-window',
    specClauses: ['SPEC 5.2 step 5'],
    fields: { ...REAL, validFromTimestamp: REAL.observationsTimestamp },
    feeManager: ZERO, boundary: B, warpTo: B,
    note: 'validFrom == observations, the ordinary shape. Measured: 6 of 6 sampled historical reports have a zero-width window.',
    expect: { verdict: 'accept' },
  },
  {
    id: 'accept-at-expiry-boundary',
    specClauses: ['SPEC 5.2 step 7', 'N11'],
    fields: { ...REAL },
    feeManager: ZERO, boundary: B, warpTo: Number(REAL.expiresAt),
    note: 'block.timestamp == expiresAt is accepted; step 7 rejects only ">".',
    expect: { verdict: 'accept' },
  },
  {
    id: 'accept-spread-exactly-at-limit',
    specClauses: ['SPEC 5.2 step 6', 'N11'],
    fields: { ...REAL, bid: P - P / 400n, ask: P + P / 400n },
    feeManager: ZERO, boundary: B, warpTo: B,
    note: '(ask-bid)*10000 == price*50 exactly. Accepted; the rule rejects only ">".',
    expect: { verdict: 'accept' },
  },

  // ---------- N1 rejections ----------
  {
    id: 'reject-verifier-reverts',
    specClauses: ['SPEC 5.2 step 2', 'N1'],
    requiredTestName: 'test_RejectsReportTheVerifierRejects',
    verifierBehaviour: 'revert',
    feeManager: ZERO, boundary: B, warpTo: B,
    note: 'The verifier itself rejects. The library must not swallow it.',
    expect: { verdict: 'reject', bubbles: 'verifier', errorName: null, selector: null },
  },
  {
    id: 'reject-v8-shaped-return',
    specClauses: ['SPEC 5.2 step 3', 'N1'],
    requiredTestName: 'test_RejectsV8ShapedReturn',
    fields: { ...REAL, feedId: V8_FEED },
    feeManager: ZERO, boundary: B, warpTo: B,
    note: 'A v8 report is also 288 bytes, so length cannot separate it. It must be rejected on the schema prefix, and the test must assert WrongSchema specifically: with the prefix check deleted this row still reverts, as WrongFeed, so only the exact selector detects that mutation.',
    expect: { verdict: 'reject', errorName: 'WrongSchema', selector: '0x21b8eeb9' },
  },
  {
    id: 'reject-v11-shaped-return',
    specClauses: ['SPEC 5.2 step 3', 'N1'],
    requiredTestName: 'test_RejectsV11ShapedReturn',
    fields: { ...REAL, feedId: V11_FEED },
    feeManager: ZERO, boundary: B, warpTo: B,
    expect: { verdict: 'reject', errorName: 'WrongSchema', selector: '0x21b8eeb9' },
  },
  {
    id: 'reject-short-return-287',
    specClauses: ['SPEC 5.2 step 3', 'N1'],
    requiredTestName: 'test_RejectsShortOrLongReturn',
    fields: { ...REAL }, resizeTo: 287,
    feeManager: ZERO, boundary: B, warpTo: B,
    expect: { verdict: 'reject', errorName: 'WrongSchema', selector: '0x21b8eeb9' },
  },
  {
    id: 'reject-long-return-289',
    specClauses: ['SPEC 5.2 step 3', 'N1'],
    requiredTestName: 'test_RejectsShortOrLongReturn',
    fields: { ...REAL }, resizeTo: 289,
    feeManager: ZERO, boundary: B, warpTo: B,
    expect: { verdict: 'reject', errorName: 'WrongSchema', selector: '0x21b8eeb9' },
  },
  {
    id: 'reject-other-feed',
    specClauses: ['SPEC 5.2 step 4', 'N1'],
    requiredTestName: 'test_RejectsOtherFeed',
    fields: { ...REAL, feedId: OTHER_FEED },
    feeManager: ZERO, boundary: B, warpTo: B,
    note: 'Another v3 feed: prefix 0x0003 passes, feed id does not. This is the row that isolates step 4 from step 3.',
    expect: { verdict: 'reject', errorName: 'WrongFeed', selector: '0x9ae97d9b' },
  },
  {
    id: 'reject-one-second-early',
    specClauses: ['SPEC 5.2 step 5', 'N1'],
    requiredTestName: 'test_RejectsOneSecondEarlyAndLate',
    fields: { ...REAL, observationsTimestamp: REAL.observationsTimestamp - 1n },
    feeManager: ZERO, boundary: B, warpTo: B,
    expect: { verdict: 'reject', errorName: 'WrongObservationTime', selector: '0xfecd62a4' },
  },
  {
    id: 'reject-one-second-late',
    specClauses: ['SPEC 5.2 step 5', 'N1'],
    requiredTestName: 'test_RejectsOneSecondEarlyAndLate',
    fields: { ...REAL, observationsTimestamp: REAL.observationsTimestamp + 1n },
    feeManager: ZERO, boundary: B, warpTo: B,
    expect: { verdict: 'reject', errorName: 'WrongObservationTime', selector: '0xfecd62a4' },
  },
  {
    id: 'reject-validfrom-after-observation',
    specClauses: ['SPEC 5.2 step 5', 'N1'],
    requiredTestName: 'test_RejectsValidFromAfterObservation',
    fields: { ...REAL, validFromTimestamp: REAL.observationsTimestamp + 1n },
    feeManager: ZERO, boundary: B, warpTo: B,
    note: 'Step 5 permits a window that starts early, never one that starts after the observation.',
    expect: { verdict: 'reject', errorName: 'ValidFromAfterObservation', selector: '0xbb3c6d04' },
  },
  {
    id: 'reject-decodes-verified-not-input',
    specClauses: ['SPEC 5.2 step 3', 'N1'],
    requiredTestName: 'test_DecodesVerifiedBytesNotInput',
    fields: { ...REAL, feedId: OTHER_FEED },
    submittedDiffers: true,
    feeManager: ZERO, boundary: B, warpTo: B,
    note: 'The submitted bytes are a perfectly good FEED_ID report; the verifier returns a different feed. The library must decode the RETURN and reject. A library reading the input would accept.',
    expect: { verdict: 'reject', errorName: 'WrongFeed', selector: '0x9ae97d9b' },
  },
  {
    id: 'reject-fee-manager-present',
    specClauses: ['SPEC 5.2 step 1', 'N11'],
    fields: { ...REAL },
    feeManager: NONZERO_FM, boundary: B, warpTo: B,
    note: 'Step 1 runs BEFORE verify. The mock reverts if verify is reached while the fee manager is non-zero, so ordering is proven rather than assumed.',
    expect: { verdict: 'reject', errorName: 'FeeManagerEnabled', selector: '0x47d64799', mustNotReachVerify: true },
  },

  // ---------- N11 rejections ----------
  {
    id: 'reject-price-zero',
    specClauses: ['SPEC 5.2 step 6', 'N11'],
    fields: { ...REAL, price: 0n, bid: 0n, ask: 0n },
    feeManager: ZERO, boundary: B, warpTo: B,
    expect: { verdict: 'reject', errorName: 'NonPositivePrice', selector: '0x13caeeae' },
  },
  {
    id: 'reject-price-negative',
    specClauses: ['SPEC 5.2 step 6', 'N11'],
    fields: { ...REAL, price: -1n, bid: -2n, ask: 0n },
    feeManager: ZERO, boundary: B, warpTo: B,
    expect: { verdict: 'reject', errorName: 'NonPositivePrice', selector: '0x13caeeae' },
  },
  {
    id: 'reject-price-int192-min',
    specClauses: ['SPEC 5.2 step 6', 'N11'],
    fields: { ...REAL, price: INT192_MIN, bid: INT192_MIN, ask: INT192_MIN },
    feeManager: ZERO, boundary: B, warpTo: B,
    note: 'Maximum-integer case for step 6a.',
    expect: { verdict: 'reject', errorName: 'NonPositivePrice', selector: '0x13caeeae' },
  },
  {
    id: 'reject-bid-above-price',
    specClauses: ['SPEC 5.2 step 6', 'N11'],
    fields: { ...REAL, bid: REAL.price + 1n },
    feeManager: ZERO, boundary: B, warpTo: B,
    expect: { verdict: 'reject', errorName: 'BidAskOutOfOrder', selector: '0xb937a957' },
  },
  {
    id: 'reject-ask-below-price',
    specClauses: ['SPEC 5.2 step 6', 'N11'],
    fields: { ...REAL, ask: REAL.price - 1n },
    feeManager: ZERO, boundary: B, warpTo: B,
    expect: { verdict: 'reject', errorName: 'BidAskOutOfOrder', selector: '0xb937a957' },
  },
  {
    id: 'reject-spread-one-bps-over',
    specClauses: ['SPEC 5.2 step 6', 'N11'],
    fields: { ...REAL, bid: P - (P * 51n) / 20000n, ask: P + (P * 51n) / 20000n },
    feeManager: ZERO, boundary: B, warpTo: B,
    note: '(ask-bid)*10000 == price*51, one basis point over the 50 bps limit.',
    expect: { verdict: 'reject', errorName: 'SpreadTooWide', selector: '0xa4f46d5d' },
  },
  {
    id: 'reject-spread-max-integer-must-not-panic',
    specClauses: ['SPEC 5.2 step 6', 'N11'],
    fields: { ...REAL, price: 1n, bid: INT192_MIN, ask: INT192_MAX },
    feeManager: ZERO, boundary: B, warpTo: B,
    note: 'THE row N11 mandates and the one the plan warns about. price > 0 passes and bid <= price <= ask passes, so step 6c is reached with ask - bid overflowing int192. Taken as int192 this panics with 0x11 and the test would pass for the wrong reason, never reaching the spread check. Step 6 specifies uint256 for exactly this. Required failure is SpreadTooWide, NOT Panic(0x11).',
    expect: { verdict: 'reject', errorName: 'SpreadTooWide', selector: '0xa4f46d5d', mustNotPanic: true },
  },
  {
    id: 'reject-expired-by-one-second',
    specClauses: ['SPEC 5.2 step 7', 'N11'],
    fields: { ...REAL },
    feeManager: ZERO, boundary: B, warpTo: Number(REAL.expiresAt) + 1,
    note: 'Paired with accept-at-expiry-boundary. Step 7 is the ONLY expiry defence in this system: VerifierProxy.verify does not check expiry, measured 2026-09-22.',
    expect: { verdict: 'reject', errorName: 'ReportExpired', selector: '0x69458111' },
  },
  {
    id: 'reject-expired-at-uint32-max-boundary',
    specClauses: ['SPEC 5.2 step 7', 'N11'],
    fields: { ...REAL, expiresAt: 0n },
    feeManager: ZERO, boundary: B, warpTo: B,
    note: 'Maximum-integer case for step 7 from the other side: expiresAt 0 against any real block timestamp.',
    expect: { verdict: 'reject', errorName: 'ReportExpired', selector: '0x69458111' },
  },
];

// ---- what CANNOT be built, recorded so nobody tries ----
const impossibleCases = [{
  describedIn: 'build plan r11 mutation table',
  asked: 'a mock returning a blob with the correct feedId and a wrong schema prefix, to exercise ADMISSION by the 0x0003 check',
  why: 'The schema prefix IS the first two bytes of feedId. The payload\'s word 0 is the feed id, FEED_ID begins 0x0003, and step 3 reads those same two bytes. So feedId == FEED_ID logically implies prefix == 0x0003, and a blob with the correct feed id and a wrong prefix is not a byte string that exists. Verified against the real verified payload on 2026-09-23: feedId 0x00037da0... and schemaPrefix 0x0003 are the same bytes.',
  consequence: 'The 0x0003 check can only ever be proven as ORDERING and SELECTOR SPECIFICITY, never as admission. That is what reject-v8-shaped-return and reject-v11-shaped-return do: deleting the prefix check leaves them reverting as WrongFeed, so only asserting the exact selector detects the mutation. The mutation table must claim nothing stronger.',
}];

// ---- build ----
function build(c) {
  const row = {
    id: c.id,
    specClauses: c.specClauses,
    ...(c.requiredTestName ? { requiredTestName: c.requiredTestName } : {}),
    source: c.source || 'mock',
    ...(c.note ? { note: c.note } : {}),
    boundary: c.boundary,
    warpTo: c.warpTo,
    verifier: { feeManager: c.feeManager, behaviour: c.verifierBehaviour || 'return' },
    expect: c.expect,
  };
  if (c.source === 'real') { row.realFixture = c.realFixture; return row; }
  if (c.verifierBehaviour === 'revert') return row;
  const p = c.resizeTo ? resize(payload(c.fields), c.resizeTo) : payload(c.fields);
  row.verifier.returnData = abiWrapBytes(p);
  row.verifier.payloadBytes = (p.length - 2) / 2;
  row.decodedFields = Object.fromEntries(Object.entries(c.fields).map(([k, v]) => [k, typeof v === 'string' ? v : v.toString()]));
  if (c.submittedDiffers) row.submittedIsValidFeedReport = true;
  return row;
}

// ---- the encoder is validated against the chain, not against itself ----
function groundTruth() {
  const ev = join(REPO, 'test/fixtures/datastreams/evidence/archive-probe-2026-09-23T10-05-57-924Z/RESULT.json');
  if (!existsSync(ev)) return { checked: false, reason: 'archive-probe evidence not present' };
  const dec = JSON.parse(readFileSync(ev, 'utf8')).providers['monad-public'];
  const mine = abiWrapBytes(payload({
    feedId: dec.decoded.feedId,
    validFromTimestamp: BigInt(dec.decoded.validFromTimestamp),
    observationsTimestamp: BigInt(dec.decoded.observationsTimestamp),
    nativeFee: BigInt(dec.decoded.nativeFee),
    linkFee: BigInt(dec.decoded.linkFee),
    expiresAt: BigInt(dec.decoded.expiresAt),
    price: BigInt(dec.decoded.price),
    bid: BigInt(dec.decoded.bid),
    ask: BigInt(dec.decoded.ask),
  }));
  const identical = mine.toLowerCase() === dec.rawResult.toLowerCase();
  if (!identical) throw new Error(`ENCODER IS WRONG: re-encoding the real verified return does not reproduce it.\n  mine  ${mine}\n  chain ${dec.rawResult}`);
  return { checked: true, identical, source: 'archive-probe-2026-09-23T10-05-57-924Z', reEncodedSha256: sha256(Buffer.from(mine.slice(2), 'hex')) };
}

const built = cases.map(build);

// Flat parallel arrays, because forge-std's JSON reader takes one value per path and rejects
// wildcards like `.cases[*].id`. Generated, never hand-edited, and `--check` compares the whole
// file against this generator, so the index cannot drift from the rows it indexes.
const index = {
  ids: built.map((c) => c.id),
  sources: built.map((c) => c.source),
  verdicts: built.map((c) => c.expect.verdict),
  requiredTestNames: built.filter((c) => c.requiredTestName).map((c) => c.requiredTestName),
  mustNotPanicIds: built.filter((c) => c.expect.mustNotPanic).map((c) => c.id),
};

// ---- the B1 record the real row is evaluated against, PINNED rather than discovered ----
// The reference used to take whichever archive-probe directory sorted last. The Codex diff review showed
// that a later FAILED probe run, or a missing evidence directory, then turned the mandatory real row into
// a skip while the gate still exited 0. So the record is named here, by path and checksum, and the
// reference refuses anything else.
// Re-pinned 2026-09-24 to the first record written by the probe after its URL-redaction fix: it holds
// no endpoint URL at all, public or credentialed. The earlier pinned record held public URLs only.
const PINNED_B1 = 'test/fixtures/datastreams/evidence/archive-probe-2026-09-24T21-28-43-466Z/RESULT.json';
const PINNED_FIXTURE = 'test/fixtures/datastreams/pending/btcusd-1789529160.json';
function pinFile(rel) {
  const abs = join(REPO, rel);
  if (!existsSync(abs)) throw new Error(`pinned evidence missing: ${rel}`);
  return { path: rel, sha256: sha256(readFileSync(abs)) };
}
const realEvidence = { record: pinFile(PINNED_B1), fixture: pinFile(PINNED_FIXTURE) };

const corpus = {
  _version: 1,
  _generatedBy: 'script/build-cases.mjs',
  _authorship: 'Every expected verdict and selector is authored by hand from SPEC 5.2. The generator encodes declared field values into bytes and never computes an expected result.',
  _encoderGroundTruth: groundTruth(),
  _constants: { FEED_ID, MAX_SPREAD_BPS: Number(MAX_SPREAD_BPS), INT192_MAX: INT192_MAX.toString(), INT192_MIN: INT192_MIN.toString() },
  _realEvidence: realEvidence,
  _impossibleCases: impossibleCases,
  _index: index,
  cases: built,
};

const text = JSON.stringify(corpus, null, 2) + '\n';

if (CHECK) {
  if (!existsSync(OUT)) { console.error(`missing ${OUT}`); process.exit(1); }
  const on = readFileSync(OUT, 'utf8');
  if (on !== text) { console.error(`CASES.json does not match the generator. Run: node script/build-cases.mjs`); process.exit(1); }
  console.log(`CASES.json matches the generator (${corpus.cases.length} cases)`);
  process.exit(0);
}

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, text);
const accepts = corpus.cases.filter((c) => c.expect.verdict === 'accept').length;
console.log(`wrote ${OUT}`);
console.log(`  ${corpus.cases.length} cases: ${accepts} accept, ${corpus.cases.length - accepts} reject`);
console.log(`  encoder ground truth: ${corpus._encoderGroundTruth.checked ? 're-encoded the real verified return byte-identically' : corpus._encoderGroundTruth.reason}`);
console.log(`  ${impossibleCases.length} impossible case recorded so it is not attempted`);
