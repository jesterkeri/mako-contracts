// T0.1 archive probe. Read-only.
//
//   node script/probe-archive.mjs                 diagnostic run
//   node script/probe-archive.mjs --as-proof      proof run, exits non-zero unless the claim is met
//
// Answers the question T0.1 is blocked on: can the providers this project intends to use serve
// `eth_call` at a pinned historical block, and do two of them, with DIFFERENT OPERATORS, return
// byte-identical results? Until that holds, T0.1's historical fixture proof cannot be made.
//
// This emits a PROOF_STANDARD.md Version 3 **Type B1** record (§0, §13): provider identities, chain
// id, the block number, hash and timestamp, the exact call, and hashes of the raw request and
// response. No transaction is sent and nothing is written to any chain.
//
// Terminal statuses, per the plan:
//   VERIFIED_MATCH          both providers returned identical bytes. The only green result.
//   VERIFICATION_MISMATCH   both answered and disagreed. A finding.
//   ARCHIVE_UNAVAILABLE     a provider could not serve the block within its retry budget. Version 3
//                           §11: the affected Type B claim is UNMET. Never a bypass, and it can
//                           never retire a mandatory fixture.
// and orthogonally:
//   NOT_INDEPENDENT         the pair is not two distinct operators, so proofLevel is "one-domain".
//
// Dependency-free on purpose: Node built-ins only. The plan pins a `script/package.json` with viem
// for the two proof scripts; this probe predates them and needs no decoder beyond nine 32-byte
// words, so it is reproducible from a clean checkout with no install step at all, which is strictly
// stronger than a pinned lockfile. If it ever needs ABI encoding beyond two `bytes` arguments, move
// it into that package rather than hand-rolling more.
//
// URLs come from the environment so a key-bearing endpoint is never committed. See providers.json.

import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, '..');
const AS_PROOF = process.argv.includes('--as-proof');

// ---- pinned constants, from blueprint/SPEC.md ----
const CHAIN_ID = 10143;
const VERIFIER = '0x72790f9eb82db492a7ddb6d2af22a270dcc3db64';
const VERIFIER_CODE_HASH = '0x4bd86e898b2952f6f0d20fee037accf52490dbdd9279345cd4b0a7161b5c022b'; // keccak256, SPEC.md:78
const VERIFIER_CODE_BYTES = 7009;

// SHA-256 of the SAME runtime bytes whose keccak256 is `VERIFIER_CODE_HASH`. This script carries no
// keccak implementation, so it gates on SHA-256 instead; the two are tied together by computing both
// from identical bytes, served by both QuickNode and Monad Foundation at block 62922075 on 2026-09-24
// (keccak256 matched SPEC.md:78 on both). The keccak equality itself is asserted in Solidity by
// test/RoundSettlementFork.t.sol, where keccak256 is a builtin.
//
// The first version checked only the code LENGTH and recorded a hash it never compared, so any other
// 7,009-byte contract returning the right strings would have passed. The Codex diff review caught it.
const VERIFIER_CODE_SHA256 = '246be742ffcc522f72309f1f42c77817af4d6f823969ce9e5763f2a9327ca231';
const VERIFIER_TYPE_AND_VERSION = 'VerifierProxy 2.0.0';
const FEED_ID = '0x00037da06d56d083fe599397a4769a042d63aa73dc4ef57709d31e9971a5b439';
const CONFIG_DIGEST = '0x00090d9e8d96765a0c49e03a6ae05c82e8f8de70cf179baa632f18313e54bd69';

// Selectors derived with `cast sig`, not guessed.
const SEL_VERIFY = '0xf7e83aee'; // verify(bytes,bytes)
const SEL_FEE_MANAGER = '0x38416b5b'; // s_feeManager()
const SEL_ACCESS_CONTROLLER = '0x94ba2846'; // s_accessController()
const SEL_TYPE_AND_VERSION = '0x181f5a77'; // typeAndVersion()

// The report INVARIANTS.md:12 names, captured 2026-09-23, and the block whose timestamp is its
// observation second exactly. See mako-design/bench/datastreams-retention/.
const DEFAULT_TARGET = {
  label: 'mandatory widened-window fixture, BTC/USD 2026-09-16 03:26:00 UTC',
  block: 62922075,
  blockHash: '0x73f54743b7db644c8f010e74f422107337b586b59fed5a91916f98b384a722d6',
  blockTimestamp: 1789529160,
  observationsTimestamp: 1789529160,
  validFromTimestamp: 1789529157,
  reportPath: 'test/fixtures/datastreams/pending/btcusd-1789529160.json',
};

const RETRY_ATTEMPTS = 5;
const RETRY_BASE_MS = 500;
const RETRY_CAP_MS = 8000;

const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hex = (n) => '0x' + n.toString(16);

// ---- minimal ABI encoding for verify(bytes payload, bytes parameterPayload) ----
function pad32(h) { return h.replace(/^0x/, '').padStart(64, '0'); }
function encodeBytes(hexStr) {
  const body = hexStr.replace(/^0x/, '');
  const len = body.length / 2;
  const padded = body.padEnd(Math.ceil(len / 32) * 64, '0');
  return pad32(len.toString(16)) + padded;
}
function encodeVerifyCall(fullReport) {
  // two dynamic args: head is two offsets, then each arg's length-prefixed data
  const a = encodeBytes(fullReport);
  const offsetA = 64; // 2 words of head
  const offsetB = offsetA + a.length / 2;
  return SEL_VERIFY + pad32(offsetA.toString(16)) + pad32(offsetB.toString(16)) + a + encodeBytes('0x');
}

// ---- JSON-RPC ----
async function rpc(url, method, params) {
  const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method, params });
  const res = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body });
  const text = await res.text();
  let parsed; try { parsed = JSON.parse(text); } catch { parsed = null; }
  return { httpStatus: res.status, body: parsed, raw: text, requestHash: sha256(body), responseHash: sha256(text) };
}

// A not-served answer is retried to a budget. A revert is NOT retried: it is data.
async function rpcWithRetry(url, method, params) {
  let delay = RETRY_BASE_MS;
  const attempts = [];
  for (let i = 1; i <= RETRY_ATTEMPTS; i++) {
    let r;
    try { r = await rpc(url, method, params); }
    catch (e) { attempts.push({ attempt: i, transport: String(e.message || e) }); await sleep(delay); delay = Math.min(delay * 2, RETRY_CAP_MS); continue; }
    const err = r.body?.error;
    const served = r.httpStatus === 200 && (r.body?.result !== undefined || isRevert(err));
    attempts.push({ attempt: i, httpStatus: r.httpStatus, error: err ? { code: err.code, message: err.message } : null, served });
    if (served) return { ...r, attempts, served: true };
    if (i < RETRY_ATTEMPTS) { await sleep(delay); delay = Math.min(delay * 2, RETRY_CAP_MS); }
  }
  return { attempts, served: false };
}

// A revert carries execution data; "missing trie node", a gas-limit refusal or a 429 do not.
function isRevert(err) {
  if (!err) return false;
  const m = (err.message || '').toLowerCase();
  if (m.includes('missing trie node') || m.includes('not found') || m.includes('pruned')) return false;
  if (m.includes('exceeds provider limit') || m.includes('capacity') || m.includes('rate limit')) return false;
  return err.code === 3 || m.includes('execution reverted') || m.includes('revert');
}

// ---- decode the 288-byte v3 payload out of the 352-byte ABI envelope ----
function decodeVerifyReturn(resultHex) {
  const b = Buffer.from(resultHex.replace(/^0x/, ''), 'hex');
  if (b.length < 64) return { ok: false, reason: `raw return is ${b.length} bytes, too short for an ABI envelope` };
  const offset = Number(BigInt('0x' + b.subarray(0, 32).toString('hex')));
  const length = Number(BigInt('0x' + b.subarray(32, 64).toString('hex')));
  const payload = b.subarray(64, 64 + length);
  // A payload that is not a full v3 report is RECORDED as malformed, not decoded. Decoding a short
  // payload used to throw on `BigInt('0x')`, crashing the probe with no evidence written and no
  // classification. Found by script/test-probe-redaction.mjs, whose mock returns an empty payload.
  if (payload.length !== 288) {
    return { ok: false, reason: `verified payload is ${payload.length} bytes, not 288`, rawBytes: b.length, envelopeLength: length, payloadBytes: payload.length };
  }
  const w = (i) => payload.subarray(i * 32, (i + 1) * 32);
  const u = (i) => BigInt('0x' + w(i).toString('hex'));
  const s = (i) => { const v = u(i); return v >> 255n ? v - (1n << 256n) : v; };
  return {
    ok: true,
    rawBytes: b.length,
    envelopeOffset: offset,
    envelopeLength: length,
    payloadBytes: payload.length,
    payloadSha256: sha256(payload),
    schemaPrefix: '0x' + payload.subarray(0, 2).toString('hex'),
    feedId: '0x' + w(0).toString('hex'),
    validFromTimestamp: Number(u(1)),
    observationsTimestamp: Number(u(2)),
    nativeFee: u(3).toString(),
    linkFee: u(4).toString(),
    expiresAt: Number(u(5)),
    price: s(6).toString(),
    bid: s(7).toString(),
    ask: s(8).toString(),
  };
}

// ---- providers ----
const record = JSON.parse(readFileSync(join(HERE, 'providers.json'), 'utf8'));
function resolveProvider(id) {
  const p = record.providers.find((x) => x.id === id);
  if (!p) return { id, error: `no provider with id "${id}" in providers.json` };
  const url = process.env[p.urlEnv];
  if (!url) return { id, error: `environment variable ${p.urlEnv} is not set` };
  let host; try { host = new URL(url).host; } catch { return { id, error: `${p.urlEnv} is not a URL` }; }
  if (host !== p.host) return { id, error: `resolved host "${host}" is not the approved host "${p.host}" for provider "${id}"` };
  // THE URL NEVER ENTERS THE PROVIDER OBJECT. It goes into a private map that nothing serializes, and
  // the object returned here, which IS written into evidence, carries only non-secret fields.
  //
  // 2026-09-24: the first version returned `{ id, url, ... }` and stored that object in the results as
  // `provider: p`, so RESULT.json contained the full URL. A run with a credentialed Alchemy endpoint wrote
  // Joshua's key into a tracked evidence file, which was committed to a PUBLIC repository. The key must
  // be rotated. Redacting at each write site would leave the next new write site to leak it again, so the
  // secret is kept out of the object entirely, and `writeEvidence` refuses to write anything containing
  // a configured URL's path or query as a last line of defence.
  URLS.set(id, url);
  return { id, host, operator: p.operator, credentialed: p.credentialed, endpointConfigSha256: sha256(`${id}|${host}`) };
}

/// id -> full URL, possibly key-bearing. Module-private and NEVER serialized.
const URLS = new Map();
const urlOf = (p) => URLS.get(p.id);

/// The only function that writes evidence. Before writing, it checks the serialized text for every
/// configured URL, and for each URL's path and query on their own, and refuses to write if any appears.
/// A key hidden in a path segment or query parameter is caught even if the host was stripped elsewhere.
function writeEvidence(dir, name, obj) {
  const text = JSON.stringify(obj, null, 2);
  for (const url of URLS.values()) {
    const u = new URL(url);
    const secretish = [url, u.pathname !== '/' ? u.pathname : null, u.search || null].filter(Boolean);
    for (const frag of secretish) {
      if (frag.length >= 4 && text.includes(frag)) {
        console.error(`REFUSING TO WRITE EVIDENCE: it would contain part of a configured RPC URL. Nothing was written.`);
        process.exit(5);
      }
    }
  }
  writeFileSync(join(dir, name), text);
}

function proofLevel(a, b) {
  const known = (o) => o && o !== 'unknown';
  return known(a.operator) && known(b.operator) && a.operator !== b.operator
    ? 'two-distinct-operators' : 'one-domain';
}

// ---- identity, asserted before any answer is trusted ----
async function identity(p, block) {
  const at = hex(block);
  const call = async (data) => rpcWithRetry(urlOf(p), 'eth_call', [{ to: VERIFIER, data }, at]);
  const [cid, code, fm, ac, tv, blk] = await Promise.all([
    rpcWithRetry(urlOf(p), 'eth_chainId', []),
    rpcWithRetry(urlOf(p), 'eth_getCode', [VERIFIER, at]),
    call(SEL_FEE_MANAGER),
    call(SEL_ACCESS_CONTROLLER),
    call(SEL_TYPE_AND_VERSION),
    rpcWithRetry(urlOf(p), 'eth_getBlockByNumber', [at, false]),
  ]);
  const notServed = [cid, code, fm, ac, tv, blk].some((r) => !r.served);
  if (notServed) return { served: false, reason: 'one or more identity reads were not served within the retry budget' };
  const addrOf = (r) => '0x' + String(r.body.result).slice(-40);
  const codeHex = code.body.result || '0x';
  const tvBytes = Buffer.from(String(tv.body.result || '').replace(/^0x/, ''), 'hex');
  const tvString = tvBytes.length > 64 ? tvBytes.subarray(64).toString('utf8').replace(/\0+$/, '') : '';
  const b = blk.body.result;
  return {
    served: true,
    chainId: Number(BigInt(cid.body.result)),
    codeBytes: (codeHex.length - 2) / 2,
    codeSha256: sha256(Buffer.from(codeHex.replace(/^0x/, ''), 'hex')),
    feeManager: addrOf(fm),
    accessController: addrOf(ac),
    typeAndVersion: tvString,
    block: { number: Number(BigInt(b.number)), hash: b.hash, timestamp: Number(BigInt(b.timestamp)) },
  };
}

// ---- main ----
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const OUT = join(REPO, 'test/fixtures/datastreams/evidence', `archive-probe-${stamp}`);
mkdirSync(OUT, { recursive: true });

const idA = process.env.MAKO_PROVIDER_A || 'monad-public';
const idB = process.env.MAKO_PROVIDER_B || 'monadinfra';
const A = resolveProvider(idA);
const B = resolveProvider(idB);

console.log(`T0.1 archive probe   ${new Date().toISOString()}`);
console.log(`mode: ${AS_PROOF ? 'PROOF' : 'diagnostic'}`);
console.log(`provider A: ${A.error ? `UNAVAILABLE (${A.error})` : `${A.host}  operator=${A.operator}`}`);
console.log(`provider B: ${B.error ? `UNAVAILABLE (${B.error})` : `${B.host}  operator=${B.operator}`}`);

if (A.error || B.error) {
  const out = { checkedAt: new Date().toISOString(), status: 'ARCHIVE_UNAVAILABLE', reason: 'a provider could not be resolved', providerA: A, providerB: B };
  writeEvidence(OUT, 'RESULT.json', out);
  console.error(`\nARCHIVE_UNAVAILABLE: a provider could not be resolved. Set the URL env vars named in script/providers.json.`);
  console.error(`evidence: ${OUT}`);
  process.exit(2);
}

const level = proofLevel(A, B);
console.log(`proofLevel: ${level}`);

let report;
try {
  const f = JSON.parse(readFileSync(join(REPO, DEFAULT_TARGET.reportPath), 'utf8'));
  report = f.fullReport;
} catch (e) {
  console.error(`\ncannot read the report at ${DEFAULT_TARGET.reportPath}: ${e.message}`);
  console.error(`Vendor the captured fixture there first. Its bytes are the only copy: the Data Streams`);
  console.error(`REST endpoint serves a measured 30 days and this report was observed 2026-09-16.`);
  process.exit(2);
}

const calldata = encodeVerifyCall(report);
console.log(`\ntarget: ${DEFAULT_TARGET.label}`);
console.log(`block ${DEFAULT_TARGET.block}, calldata ${(calldata.length - 2) / 2} bytes\n`);

const results = {};
for (const p of [A, B]) {
  console.log(`--- ${p.id} (${p.host}) ---`);
  const ident = await identity(p, DEFAULT_TARGET.block);
  if (!ident.served) { console.log(`  identity: NOT SERVED`); results[p.id] = { provider: p, identity: ident, status: 'ARCHIVE_UNAVAILABLE' }; continue; }

  // The runtime code is identified by its HASH, not merely its length: PROOF_STANDARD §9 requires
  // the contract whose answers are trusted to be identified by its code, and a length check alone
  // accepts any other contract of the same size.
  const idOk =
    ident.chainId === CHAIN_ID &&
    ident.codeBytes === VERIFIER_CODE_BYTES &&
    ident.codeSha256 === VERIFIER_CODE_SHA256 &&
    ident.feeManager === '0x0000000000000000000000000000000000000000' &&
    ident.accessController === '0x0000000000000000000000000000000000000000' &&
    ident.typeAndVersion === VERIFIER_TYPE_AND_VERSION &&
    ident.block.hash === DEFAULT_TARGET.blockHash &&
    ident.block.timestamp === DEFAULT_TARGET.blockTimestamp;

  console.log(`  chainId ${ident.chainId}   typeAndVersion "${ident.typeAndVersion}"   code ${ident.codeBytes} bytes`);
  console.log(`  s_feeManager ${ident.feeManager}   s_accessController ${ident.accessController}`);
  console.log(`  block ${ident.block.number} ${ident.block.hash} ts ${ident.block.timestamp}`);
  console.log(`  code sha256 ${ident.codeSha256.slice(0, 16)}... ${ident.codeSha256 === VERIFIER_CODE_SHA256 ? 'matches the pin' : 'DOES NOT MATCH THE PIN'}`);
  console.log(`  identity: ${idOk ? 'MATCHES the pinned record' : 'MISMATCH'}`);

  const call = await rpcWithRetry(urlOf(p), 'eth_call', [{ to: VERIFIER, data: calldata }, hex(DEFAULT_TARGET.block)]);
  if (!call.served) { console.log(`  verify: NOT SERVED after ${call.attempts.length} attempts`); results[p.id] = { provider: p, identity: ident, identityOk: idOk, status: 'ARCHIVE_UNAVAILABLE', attempts: call.attempts }; continue; }
  if (call.body?.error) { console.log(`  verify: REVERTED  ${call.body.error.message}`); results[p.id] = { provider: p, identity: ident, identityOk: idOk, status: 'REVERTED', error: call.body.error, attempts: call.attempts, requestHash: call.requestHash, responseHash: call.responseHash }; continue; }

  const dec = decodeVerifyReturn(call.body.result);
  if (dec.ok) {
    console.log(`  verify: ${dec.rawBytes} raw / ${dec.payloadBytes} decoded, prefix ${dec.schemaPrefix}`);
    console.log(`  payload sha256 ${dec.payloadSha256.slice(0, 32)}...`);
  } else {
    console.log(`  verify: MALFORMED RETURN, ${dec.reason}`);
  }
  results[p.id] = {
    provider: p, identity: ident, identityOk: idOk, status: 'SERVED',
    attempts: call.attempts, requestHash: call.requestHash, responseHash: call.responseHash,
    rawResult: call.body.result, decoded: dec,
  };
  console.log('');
}

// ---- classify ----
const rA = results[A.id], rB = results[B.id];
let status;
if (rA.status === 'ARCHIVE_UNAVAILABLE' || rB.status === 'ARCHIVE_UNAVAILABLE') status = 'ARCHIVE_UNAVAILABLE';
else if (rA.status === 'REVERTED' || rB.status === 'REVERTED') status = 'VERIFICATION_MISMATCH';
else if (rA.rawResult !== rB.rawResult) status = 'VERIFICATION_MISMATCH';
else if (!rA.decoded?.ok || !rB.decoded?.ok) status = 'VERIFICATION_MISMATCH'; // a served but malformed return
else if (!rA.identityOk || !rB.identityOk) status = 'VERIFICATION_MISMATCH';
else status = 'VERIFIED_MATCH';

const out = {
  checkedAt: new Date().toISOString(),
  proofType: 'B1',
  mode: AS_PROOF ? 'proof' : 'diagnostic',
  status,
  proofLevel: level,
  chainId: CHAIN_ID,
  verifier: VERIFIER,
  pinned: { codeHashKeccak256: VERIFIER_CODE_HASH, codeSha256: VERIFIER_CODE_SHA256, typeAndVersion: VERIFIER_TYPE_AND_VERSION, feedId: FEED_ID, configDigest: CONFIG_DIGEST },
  target: DEFAULT_TARGET,
  calldataSha256: sha256(calldata),
  providers: { [A.id]: rA, [B.id]: rB },
  bytesIdentical: rA.rawResult !== undefined && rA.rawResult === rB.rawResult,
};
writeEvidence(OUT, 'RESULT.json', out);

console.log(`STATUS: ${status}`);
console.log(`proofLevel: ${level}`);
console.log(`evidence: ${OUT}`);

if (status !== 'VERIFIED_MATCH') {
  if (status === 'ARCHIVE_UNAVAILABLE') {
    console.error(`\nARCHIVE_UNAVAILABLE. Per PROOF_STANDARD.md Version 3 §11 the affected Type B claim is`);
    console.error(`UNMET. This is not a verifier failure and not a pass, and it can never retire a`);
    console.error(`mandatory fixture.`);
  }
  process.exit(3);
}
if (AS_PROOF && level !== 'two-distinct-operators') {
  console.error(`\nNOT_INDEPENDENT. Both providers verified and agreed byte for byte, which is a real`);
  console.error(`result, but "${A.operator}" and "${B.operator}" are not two established distinct`);
  console.error(`operators, so this is proofLevel "one-domain". PROOF_STANDARD.md Version 3 §1b: that`);
  console.error(`does not satisfy the section. Record a second operator in script/providers.json and`);
  console.error(`re-run before claiming the historical proof.`);
  process.exit(4);
}
console.log(`\nVERIFIED_MATCH${AS_PROOF ? ' as proof' : ''}.`);
