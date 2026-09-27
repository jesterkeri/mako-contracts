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
// KEYLESS BY CONSTRUCTION (2026-09-27). The probe talks only to the fixed, public 'url' of each provider in
// script/providers.json and reads no URL from the environment, so the process that writes public evidence
// never holds a secret. Codex diff review round 6 showed the previous design, which read URLs from
// environment variables and redacted them, still let a key into a "keyless" proof run; before that, twelve
// adversary passes had grown ~2,500 lines of redaction around that environment input. That machinery is
// gone (it is in git history up to 56d307b). What remains protects the PROOF: https only, certificate
// trust equal to Node's bundled CA set, no redirects, bounded requests, and evidence that records a
// provider-chosen value only when it equals its pin. Credentialed endpoints are checked by hand with
// mako-design/scripts/check-alchemy-key.sh, which writes no evidence.

import { createHash } from 'node:crypto';
import tls from 'node:tls';
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, '..');
const AS_PROOF = process.argv.includes('--as-proof');

// A PROOF run starts from a stripped environment, and refuses otherwise, before anything else happens.
// Codex diff review round 7: Node INHERITS the caller's whole environment before this file runs, so a
// credential left in a shell (an old MAKO_RPC_ALCHEMY) sat in the proof process, where a native diagnostic
// report could print it. Round 8: a Bash launcher cannot fix that either, because Bash runs the inherited
// BASH_ENV hook before its first line, and every interpreter has such a hook (NODE_OPTIONS, BASH_ENV,
// LD_PRELOAD). So the clean environment must exist BEFORE the first interpreter starts: the documented
// proof command itself begins with `env -i` (PROOF_COMMAND below). This check makes any other --as-proof
// run refuse, naming the extra variables but never their values. What runs before `env -i` is the
// operator's own shell and the `env` binary: that is the trust root, out of scope like any code the
// operator chooses to run.
const PROOF_COMMAND = 'env -i PATH="$(dirname "$(command -v node)")" node script/probe-archive.mjs --as-proof';
if (AS_PROOF) {
  const allowed = new Set(['PATH', 'MAKO_PROVIDER_A', 'MAKO_PROVIDER_B', 'MAKO_PROBE_RPC_TIMEOUT_MS']);
  const extra = Object.keys(process.env).filter((k) => !allowed.has(k)).sort();
  if (extra.length) {
    process.stderr.write(`REFUSING TO RUN A PROOF: the environment carries ${extra.length} variable(s) a proof does not use `
      + `(${extra.join(', ')}). Run the proof from a stripped environment, exactly:\n  ${PROOF_COMMAND}\n`);
    process.exit(2);
  }
}

// ---- pinned constants, from blueprint/SPEC.md ----
const CHAIN_ID = 10143;
const VERIFIER = '0x72790f9eb82db492a7ddb6d2af22a270dcc3db64';
const VERIFIER_CODE_HASH = '0x4bd86e898b2952f6f0d20fee037accf52490dbdd9279345cd4b0a7161b5c022b'; // keccak256, SPEC.md:78

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
// Even-length 0x-hex, checked without a repeated capture group: `/^0x([0-9a-fA-F]{2})*$/` overflowed the
// regex stack on a multi-megabyte provider value and crashed the run with no evidence (third adversary pass).
const isHex = (s) => typeof s === 'string' && s.length % 2 === 0 && /^0x[0-9a-fA-F]*$/.test(s);
/// A provider JSON value as text for HASHING only. Never coerces through a provider-chosen `toString`.
function textOf(v) {
  if (typeof v === 'string') return v;
  try { return JSON.stringify(v) ?? 'undefined'; } catch { return 'unserializable'; }
}
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
//
// Every request is BOUNDED, because the provider is untrusted (fourth adversary pass on round 5): with no
// deadline, a provider sending HTTP 200 and then one byte a second held the run forever, so no evidence and
// no classification were ever written; undici's own idle timer restarts on every byte. So:
//   - one total deadline per request, headers and body together (RPC_TIMEOUT_MS);
//   - the body is read to at most MAX_RESPONSE_BYTES, then abandoned;
//   - redirects are refused. A provider answering 3xx would otherwise have the call served by whoever it
//     points at, and the "two distinct operators" of the proof would not be the ones answering.
// Each failure is a retried, categorised attempt; after the budget the call is not served, and the run
// is classified ARCHIVE_UNAVAILABLE with evidence written.
const RPC_TIMEOUT_MS = Math.min(Math.max(Number(process.env.MAKO_PROBE_RPC_TIMEOUT_MS) || 20_000, 500), 60_000);
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024; // a Monad block's hash list and the 7 KB verifier code fit many times over
class Oversized extends Error {}
class TrustChanged extends Error {}

async function rpc(url, method, params) {
  // Trust is re-checked before EVERY https request, not only at startup: the eighth adversary pass had a
  // preload change the trust store one second after the startup check, and the impostor then answered.
  // Decided from the PARSED scheme, which is what fetch uses: the ninth adversary pass showed `HTTPS://`,
  // a leading space, or a tab inside the scheme skipping a raw `startsWith('https:')` test.
  if (new URL(url).protocol === 'https:' && tlsWeakening().length) throw new TrustChanged();
  const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method, params });
  // The deadline is enforced by RACING every await against it, not by trusting fetch to honour its signal:
  // against a dripping provider (fourth adversary pass), undici left a pending body read unresolved after
  // abort() on the fourth retry, and the run hung. Reproduced outside the probe on Node 22.23. An explicit
  // timer is used rather than `AbortSignal.timeout()`, and the stream is cancelled when the deadline wins.
  const controller = new AbortController();
  const deadline = new Promise((_, reject) => controller.signal.addEventListener('abort', () => reject(controller.signal.reason), { once: true }));
  deadline.catch(() => {});
  const timer = setTimeout(() => controller.abort(new DOMException('deadline', 'TimeoutError')), RPC_TIMEOUT_MS);
  let res, text, reader;
  try {
    res = await Promise.race([
      fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body, redirect: 'error', signal: controller.signal }),
      deadline,
    ]);
    const chunks = [];
    let size = 0;
    reader = res.body.getReader();
    for (;;) {
      const { done, value } = await Promise.race([reader.read(), deadline]);
      if (done) break;
      size += value.length;
      if (size > MAX_RESPONSE_BYTES) throw new Oversized();
      chunks.push(value);
    }
    text = Buffer.concat(chunks).toString('utf8');
  } catch (e) {
    reader?.cancel().catch(() => {});
    controller.abort();
    throw e;
  } finally {
    clearTimeout(timer);
  }
  let parsed; try { parsed = JSON.parse(text); } catch { parsed = null; }
  // The raw response text is not returned, only its hash for correlation: evidence carries parsed, checked
  // values, never provider prose.
  return { httpStatus: res.status, body: parsed, requestHash: sha256(body), responseHash: sha256(text) };
}

// A not-served answer is retried to a budget. A revert is NOT retried: it is data.
async function rpcWithRetry(url, method, params) {
  let delay = RETRY_BASE_MS;
  const attempts = [];
  for (let i = 1; i <= RETRY_ATTEMPTS; i++) {
    let r;
    try { r = await rpc(url, method, params); }
    // A transport error's message can carry the URL (and its cause can), so only a fixed category is kept.
    // Only the error's TYPE is used, never its message.
    catch (e) {
      const category = e instanceof Oversized ? 'oversized' : e instanceof TrustChanged ? 'trust-store-changed'
        : e?.name === 'TimeoutError' || e?.name === 'AbortError' ? 'timeout' : 'transport';
      attempts.push({ attempt: i, category });
      if (i < RETRY_ATTEMPTS) { await sleep(delay); delay = Math.min(delay * 2, RETRY_CAP_MS); }
      continue;
    }
    const err = r.body?.error;
    const served = r.httpStatus === 200 && (r.body?.result !== undefined || isRevert(err));
    attempts.push({ attempt: i, httpStatus: r.httpStatus, rpcCode: rpcCodeOf(err), category: categorize(err, r.httpStatus), served });
    if (served) return { ...r, attempts, served: true };
    if (i < RETRY_ATTEMPTS) { await sleep(delay); delay = Math.min(delay * 2, RETRY_CAP_MS); }
  }
  return { attempts, served: false };
}

// Provider error text is untrusted prose, so it is inspected transiently by `isRevert` and `categorize` and
// never stored or logged: only a locally derived category and a standard numeric code survive.
function categorize(err, httpStatus) {
  if (!err) return httpStatus === 200 ? 'ok' : `http-${Number(httpStatus) || 0}`;
  const m = msgOf(err);
  if (m.includes('missing trie node') || m.includes('pruned') || m.includes('not found')) return 'not-served';
  if (m.includes('rate limit') || m.includes('capacity') || httpStatus === 429) return 'rate-limited';
  if (m.includes('exceeds provider limit')) return 'provider-gas-limit';
  if (isRevert(err)) return 'revert';
  return 'rpc-error';
}
// Only a STANDARD JSON-RPC code is kept: 3 (execution reverted) and the reserved -32768..-32000 range. Any
// other integer is provider-chosen data.
// A message that is not a string is ignored rather than coerced: `String()` on a provider object can run
// or fail on provider-chosen `toString`, and either way the text would be provider data.
const msgOf = (err) => (typeof err?.message === 'string' ? err.message.toLowerCase() : '');
const rpcCodeOf = (err) => (err && Number.isInteger(err.code) && (err.code === 3 || (err.code >= -32768 && err.code <= -32000)) ? err.code : null);

// A revert carries execution data; "missing trie node", a gas-limit refusal or a 429 do not.
function isRevert(err) {
  if (!err) return false;
  const m = msgOf(err);
  if (m.includes('missing trie node') || m.includes('not found') || m.includes('pruned')) return false;
  if (m.includes('exceeds provider limit') || m.includes('capacity') || m.includes('rate limit')) return false;
  return err.code === 3 || m.includes('execution reverted') || m.includes('revert');
}

// ---- decode the 288-byte v3 payload out of the 352-byte ABI envelope ----
//
// A return is well-formed only if it is EXACTLY the envelope a v3 report produces: 352 bytes, offset 32,
// length 288. Anything else is malformed, and a malformed return is described by a fixed reason code
// alone: no lengths and no bytes, since every one of those is provider-chosen.
function decodeVerifyReturn(resultHex) {
  if (!isHex(resultHex)) return { ok: false, reason: 'not-hex' };
  const b = Buffer.from(resultHex.slice(2), 'hex');
  if (b.length !== 352) return { ok: false, reason: 'not-352-bytes' };
  const offset = Number(BigInt('0x' + b.subarray(0, 32).toString('hex')));
  const length = Number(BigInt('0x' + b.subarray(32, 64).toString('hex')));
  if (offset !== 32 || length !== 288) return { ok: false, reason: 'not-a-288-byte-envelope' };
  const payload = b.subarray(64, 352);
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
/// A provider selected by id (MAKO_PROVIDER_A/B, ids only, never URLs). Its URL is the fixed public one in
/// providers.json. Refused unless that URL is exactly https://<recorded host>/ (plain http only to a
/// loopback test server) and certificate checking is intact.
function resolveProvider(id) {
  const p = record.providers.find((x) => x.id === id);
  // An unknown id is never quoted back: someone could paste a URL into MAKO_PROVIDER_A by mistake.
  if (!p) return { id: 'unknown', error: 'the selected provider id is not listed in providers.json (it is not quoted here)' };
  let u; try { u = new URL(p.url); } catch { return { id, error: `providers.json gives provider "${id}" no valid url` }; }
  const loopback = /^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/.test(u.host);
  const exact = u.href === p.url && u.pathname === '/' && !u.search && !u.hash && !u.username && !u.password && u.host === p.host;
  if (!exact) return { id, error: `provider "${id}" url must be exactly <scheme>://${p.host}/ with no path, query, userinfo or fragment` };
  // HTTPS only: over plain HTTP anything on the path, or a proxy, could answer in the operator's place.
  if (u.protocol !== 'https:' && !(u.protocol === 'http:' && loopback)) return { id, error: `provider "${id}" url must be https://` };
  const weakened = u.protocol === 'https:' ? tlsWeakening() : [];
  if (weakened.length) {
    return { id, error: `TLS certificate checking is weakened in this environment: ${weakened.join('; ')}. No certificate can then prove which operator answers; remove the setting and re-run` };
  }
  return { id, url: p.url, host: p.host, operator: p.operator };
}
const urlOf = (p) => p.url;

process.on('uncaughtException', (e) => { console.error(`uncaught: ${e?.message ?? e}`); process.exit(1); });
process.on('unhandledRejection', (e) => { console.error(`unhandled: ${e?.message ?? e}`); process.exit(1); });

function writeEvidence(dir, name, obj) {
  writeFileSync(join(dir, name), JSON.stringify(obj, null, 2));
}

function proofLevel(a, b) {
  const known = (o) => o && o !== 'unknown';
  return known(a.operator) && known(b.operator) && a.operator !== b.operator
    ? 'two-distinct-operators' : 'one-domain';
}

/// Why certificate checking in THIS process cannot be trusted to name the operator who answers, or [].
///
/// A POSITIVE check of the result, not a list of setting names. The sixth adversary pass showed two
/// settings that let an impostor answer for both operators; a name list for them was then bypassed six more
/// ways (NODE_USE_SYSTEM_CA, a quoted or underscore spelling in NODE_OPTIONS, two config-file flags, a
/// preload calling tls.setDefaultCACertificates). Every one of them changes the trust store Node actually
/// uses, so the rule is: that store must be EXACTLY Node's bundled CA set. Measured on Node 22.23.2: 145
/// bundled; NODE_EXTRA_CA_CERTS makes it 146, NODE_USE_SYSTEM_CA 509, --use-openssl-ca 0 (OpenSSL's store is
/// not enumerable, which is still not equal). NODE_TLS_REJECT_UNAUTHORIZED=0 turns checking off without
/// touching the store, so it is checked by its exact value, the one Node honours.
///
/// It is checked when each provider is resolved AND before every https request.
///
/// Out of scope, stated rather than implied: code the operator chose to run inside this process (a
/// --require or --import preload) can replace fetch itself, change the trust store between a check and the
/// connection it guards, or write any evidence it likes; no check made from inside the same process can
/// bound that. The checks close every CONFIGURATION route to widened trust and any in-process change made
/// before a request is sent; they do not claim to defeat code execution.
function tlsWeakening() {
  const found = [];
  if (process.env.NODE_TLS_REJECT_UNAUTHORIZED === '0') found.push('NODE_TLS_REJECT_UNAUTHORIZED=0 disables certificate checking');
  if (typeof tls.getCACertificates !== 'function') {
    found.push('this Node version cannot report its trust store, so it cannot be shown to be the bundled one');
  } else {
    const effective = tls.getCACertificates('default');
    const bundled = new Set(tls.getCACertificates('bundled'));
    const same = effective.length === bundled.size && effective.every((c) => bundled.has(c));
    if (!same) found.push(`the trust store is not Node's bundled CA set (${effective.length} certificates in use, ${bundled.size} bundled)`);
  }
  return found;
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
  const reads = { eth_chainId: cid, eth_getCode: code, s_feeManager: fm, s_accessController: ac, typeAndVersion: tv, eth_getBlockByNumber: blk };
  const unserved = Object.entries(reads).filter(([, r]) => !r.served);
  if (unserved.length) {
    // WHICH read failed and how, as local categories and codes only. Without this, a mistyped key (401 on
    // every attempt) and a pruned block looked identical in the evidence.
    return {
      served: false,
      reason: 'one or more identity reads were not served within the retry budget',
      unserved: Object.fromEntries(unserved.map(([name, r]) => [name, r.attempts])),
    };
  }
  // EVERY VALUE BELOW IS PROVIDER-CHOSEN, so none is recorded verbatim unless it equals its pin; any other
  // value becomes `MISMATCH sha256:<hash>`, which keeps provider-chosen bulk out of the evidence. The
  // comparison (`ok`) uses the raw values.
  const raw = {
    chainId: toNumber(cid.body.result),
    codeHex: typeof code.body.result === 'string' ? code.body.result : '',
    feeManager: code32(fm.body.result),
    accessController: code32(ac.body.result),
    typeAndVersion: abiString(tv.body.result),
    blockNumber: toNumber(blk.body.result?.number),
    blockHash: blk.body.result?.hash,
    blockTimestamp: toNumber(blk.body.result?.timestamp),
  };
  const codeSha256 = sha256(Buffer.from(isHex(raw.codeHex) ? raw.codeHex.slice(2) : '', 'hex'));
  const ZERO = '0x0000000000000000000000000000000000000000';
  const ok = {
    chainId: raw.chainId === CHAIN_ID,
    code: codeSha256 === VERIFIER_CODE_SHA256,
    feeManager: raw.feeManager === ZERO,
    accessController: raw.accessController === ZERO,
    typeAndVersion: raw.typeAndVersion === VERIFIER_TYPE_AND_VERSION,
    blockNumber: raw.blockNumber === block,
    blockHash: raw.blockHash === DEFAULT_TARGET.blockHash,
    blockTimestamp: raw.blockTimestamp === DEFAULT_TARGET.blockTimestamp,
  };
  return {
    served: true,
    ok,
    chainId: pinnedOrHash(raw.chainId, ok.chainId),
    codeSha256, // a hash already
    feeManager: pinnedOrHash(raw.feeManager, ok.feeManager),
    accessController: pinnedOrHash(raw.accessController, ok.accessController),
    typeAndVersion: pinnedOrHash(raw.typeAndVersion, ok.typeAndVersion),
    block: {
      number: pinnedOrHash(raw.blockNumber, ok.blockNumber),
      hash: pinnedOrHash(raw.blockHash, ok.blockHash),
      timestamp: pinnedOrHash(raw.blockTimestamp, ok.blockTimestamp),
    },
  };
}

const pinnedOrHash = (v, matches) => (matches ? v : `MISMATCH sha256:${sha256(textOf(v))}`);
/// A hex quantity as a safe integer, or null. Never throws, so provider text never reaches an error message.
function toNumber(q) {
  if (typeof q !== 'string' || !/^0x[0-9a-fA-F]{1,13}$/.test(q)) return null;
  return Number(BigInt(q));
}
/// An address from a 32-byte ABI word, or null unless the word is exactly a left-padded address.
function code32(w) {
  return typeof w === 'string' && /^0x0{24}[0-9a-fA-F]{40}$/.test(w) ? ('0x' + w.slice(-40)).toLowerCase() : null;
}
/// The string an ABI `string` return carries, or null. Only compared, never recorded unless it matches.
//
// Decoded STRICTLY from the ABI head (offset 32, a length word, then that many bytes), with no regex on
// provider bytes: the fourth adversary pass showed `.replace(/\0+$/, '')` over ~2 MB of NULs followed by
// one other byte running in quadratic time, about 18 minutes per provider, which no request deadline can
// interrupt because it runs after the response has arrived. Anything longer than 256 bytes cannot be the
// pinned string, so it is not decoded at all.
function abiString(w) {
  if (!isHex(w) || w.length > 2 + 2 * (64 + 256 + 32)) return null;
  const b = Buffer.from(w.slice(2), 'hex');
  if (b.length < 64) return null;
  const offset = Number(BigInt('0x' + b.subarray(0, 32).toString('hex')));
  const length = Number(BigInt('0x' + b.subarray(32, 64).toString('hex')));
  // EXACTLY what a contract returns: offset 32, length, the bytes, then ZERO padding to a 32-byte boundary,
  // and nothing after. The sixth adversary pass had non-zero padding and a trailing extra word accepted.
  if (offset !== 32 || length > 256 || b.length !== 64 + Math.ceil(length / 32) * 32) return null;
  if (b.subarray(64 + length).some((x) => x !== 0)) return null;
  return b.subarray(64, 64 + length).toString('utf8');
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
  console.error(`\nARCHIVE_UNAVAILABLE: a provider could not be resolved (see the reason above).`);
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
const resultHashes = {};
for (const p of [A, B]) {
  console.log(`--- ${p.id} (${p.host}) ---`);
  const ident = await identity(p, DEFAULT_TARGET.block);
  if (!ident.served) {
    for (const [name, attempts] of Object.entries(ident.unserved)) {
      const last = attempts[attempts.length - 1] || {};
      console.log(`  ${name}: not served after ${attempts.length} attempt(s), last: ${last.category}${last.httpStatus ? `, HTTP ${last.httpStatus}` : ''}`);
    }
    console.log(`  identity: NOT SERVED`); results[p.id] = { provider: p, identity: ident, status: 'ARCHIVE_UNAVAILABLE' }; continue; }

  // The runtime code is identified by its HASH, not merely its length: PROOF_STANDARD §9 requires
  // the contract whose answers are trusted to be identified by its code, and a length check alone
  // accepts any other contract of the same size.
  const idOk = Object.values(ident.ok).every(Boolean);

  console.log(`  chainId ${ident.chainId}   typeAndVersion "${ident.typeAndVersion}"`);
  console.log(`  s_feeManager ${ident.feeManager}   s_accessController ${ident.accessController}`);
  console.log(`  block ${ident.block.number} ${ident.block.hash} ts ${ident.block.timestamp}`);
  console.log(`  code sha256 ${ident.codeSha256.slice(0, 16)}... ${ident.codeSha256 === VERIFIER_CODE_SHA256 ? 'matches the pin' : 'DOES NOT MATCH THE PIN'}`);
  console.log(`  identity: ${idOk ? 'MATCHES the pinned record' : 'MISMATCH'}`);

  const call = await rpcWithRetry(urlOf(p), 'eth_call', [{ to: VERIFIER, data: calldata }, hex(DEFAULT_TARGET.block)]);
  if (!call.served) { console.log(`  verify: NOT SERVED after ${call.attempts.length} attempts`); results[p.id] = { provider: p, identity: ident, identityOk: idOk, status: 'ARCHIVE_UNAVAILABLE', attempts: call.attempts }; continue; }
  if (call.body?.error) {
    const e = { rpcCode: rpcCodeOf(call.body.error), category: categorize(call.body.error, call.httpStatus) };
    console.log(`  verify: REVERTED (${e.category}, rpc code ${e.rpcCode})`);
    results[p.id] = { provider: p, identity: ident, identityOk: idOk, status: 'REVERTED', error: e, attempts: call.attempts, requestHash: call.requestHash, responseHash: call.responseHash };
    continue;
  }

  const dec = decodeVerifyReturn(call.body.result);
  if (dec.ok) {
    console.log(`  verify: ${dec.rawBytes} raw / ${dec.payloadBytes} decoded, prefix ${dec.schemaPrefix}`);
    console.log(`  payload sha256 ${dec.payloadSha256.slice(0, 32)}...`);
  } else {
    console.log(`  verify: MALFORMED RETURN, ${dec.reason}`);
  }
  // A well-formed return (exactly 352 bytes) is recorded in full; a malformed one by hash and reason code,
  // which keeps provider-chosen bulk out of the evidence.
  resultHashes[p.id] = sha256(textOf(call.body.result));
  results[p.id] = {
    provider: p, identity: ident, identityOk: idOk, status: 'SERVED',
    attempts: call.attempts, requestHash: call.requestHash, responseHash: call.responseHash,
    rawResultSha256: resultHashes[p.id],
    ...(dec.ok ? { rawResult: call.body.result } : {}),
    decoded: dec,
  };
  console.log('');
}

// ---- classify ----
const rA = results[A.id], rB = results[B.id];
let status;
if (rA.status === 'ARCHIVE_UNAVAILABLE' || rB.status === 'ARCHIVE_UNAVAILABLE') status = 'ARCHIVE_UNAVAILABLE';
else if (rA.status === 'REVERTED' || rB.status === 'REVERTED') status = 'VERIFICATION_MISMATCH';
else if (resultHashes[A.id] !== resultHashes[B.id]) status = 'VERIFICATION_MISMATCH';
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
  bytesIdentical: resultHashes[A.id] !== undefined && resultHashes[A.id] === resultHashes[B.id],
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
