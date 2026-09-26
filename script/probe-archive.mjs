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

async function rpc(url, method, params) {
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
  // The raw response text is NOT returned: it is provider-controlled and may echo the request URL. Only its
  // hash leaves this function, for correlation.
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
      const category = e instanceof Oversized ? 'oversized' : e?.name === 'TimeoutError' || e?.name === 'AbortError' ? 'timeout' : 'transport';
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

// PROVIDER ERROR TEXT IS UNTRUSTED AND MAY BE SECRET-BEARING. A provider, gateway or proxy is free to
// echo the request URL, credential included, in a JSON-RPC error message. The Codex diff review (round 4)
// showed the previous version printing that message verbatim to stdout, where a CI run publishes it,
// BEFORE the evidence guard ever ran. So a message is inspected transiently by `isRevert` and `categorize`
// and NEVER returned, stored or logged: only a locally derived category and the numeric code survive.
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
// other integer is provider-chosen data, and the adversary pass showed a digits-only credential minus one
// digit returned as `code` reaching both stdout and evidence.
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
// alone: no lengths and no bytes, since every one of those is provider-chosen (round 5 of the Codex diff
// review showed a malformed result carrying a hex-encoded credential into evidence).
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
// A provider id comes from MAKO_PROVIDER_A/B, and a URL pasted there by mistake would be printed and
// recorded as the id. So an id is recorded only if providers.json lists it, and an unknown one is never
// quoted back (third adversary pass).
function resolveProvider(id) {
  const p = record.providers.find((x) => x.id === id);
  if (!p) return { id: 'unknown', error: 'the selected provider id is not listed in providers.json (it is not quoted here, in case it was a URL)' };
  const url = process.env[p.urlEnv];
  if (!url) return { id, error: `environment variable ${p.urlEnv} is not set` };
  let host, scheme; try { ({ host, protocol: scheme } = new URL(url)); } catch { return { id, error: `${p.urlEnv} is not a URL` }; }
  // HTTPS only (plain HTTP to a loopback test server excepted). Over plain HTTP, anything on the network
  // path, or a proxy Node is configured to use (NODE_USE_ENV_PROXY with HTTP_PROXY), can answer in the
  // endpoint's place and the evidence would name an operator that never answered (fourth adversary pass).
  // Over HTTPS a proxy only tunnels, and the endpoint's certificate authenticates who answered.
  const loopback = /^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/.test(host);
  if (scheme !== 'https:' && !(scheme === 'http:' && loopback)) return { id, error: `${p.urlEnv} must be an https:// URL` };
  if (host !== p.host) return { id, error: `resolved host "${host}" is not the approved host "${p.host}" for provider "${id}"` };
  const refused = refuseUrlShape(url);
  if (refused) return { id, error: `${p.urlEnv} ${refused}` };
  // THE URL NEVER ENTERS THE PROVIDER OBJECT. It goes into a private map that nothing serializes, and
  // the object returned here, which IS written into evidence, carries only non-secret fields.
  //
  // 2026-09-24: the first version returned `{ id, url, ... }` and stored that object in the results as
  // `provider: p`, so RESULT.json contained the full URL. A run with a credentialed Alchemy endpoint wrote
  // Joshua's key into a tracked evidence file, which was committed to a PUBLIC repository. The key must
  // be rotated. Redacting at each write site would leave the next new write site to leak it again, so the
  // secret is kept out of the object entirely, and `writeEvidence` refuses to write anything containing
  // any secret form of a configured URL (see `secretFragments`) as a last line of defence.
  URLS.set(id, url);
  return { id, host, operator: p.operator, credentialed: p.credentialed, endpointConfigSha256: sha256(`${id}|${host}`) };
}

/// id -> full URL, possibly key-bearing. Module-private and NEVER serialized.
const URLS = new Map();
const urlOf = (p) => URLS.get(p.id);

// ---- what counts as secret in a configured URL ----
//
// The Codex diff review (round 5) showed the guard knew only COMPOUND forms: the whole URL, its path and
// its query. A provider holds the credential already, so it can echo the token ON ITS OWN ("invalid key
// Qx7...") or hex-encoded in a result, and neither contains "/v2/" or "?apikey=". The adversary pass on
// that fix then showed that matching whole atoms is not enough either: the key minus ONE character,
// hex-encoded in a result, matched nothing, and one missing character is trivial to brute-force.
//
// So the unit of secrecy is any WINDOW of WINDOW bytes of any credential atom, not the atom. An atom is
// every path segment and every query key and value, in each spelling: as written, and percent-decoded
// BYTEWISE (so an escape that is not valid UTF-8 still decodes) with `+` kept and with `+` as a space.
// Each window is matched as latin1 and UTF-8 text, hex and percent-encoded, and every 6-byte window as
// base64 and base64url, which covers a base64 echo of any WINDOW consecutive credential bytes at any
// alignment. Matching is case-insensitive, and the evidence guard also matches JSON-escaped forms.
//
// An atom shorter than MIN_ATOM bytes cannot be windowed without redacting ordinary text, so a URL
// component is either a known generic part of an endpoint (`v2`, `rpc`, `apikey`...) or at least
// MIN_ATOM bytes, in every spelling. A short non-generic component is REFUSED at configuration time: a
// short credential is still a credential. User:password credentials and #fragments are refused outright.
const MIN_ATOM = 8;
const WINDOW = 10;
// `v` + AT MOST three digits: an unbounded `v\d+` let a credential shaped `v31415926535...` count as a
// version label, so it was neither refused nor redacted (second adversary pass on round 5).
const GENERIC_COMPONENT = /^(v\d{1,3}|rpc|api|apikey|api_key|api-key|key|token|auth)$/i;

/// Percent-decodes to BYTES, never failing: `%XX` becomes that byte, anything else its UTF-8 bytes.
function pctBytes(c) {
  const out = [];
  for (let i = 0; i < c.length; i++) {
    if (c[i] === '%' && /^[0-9a-fA-F]{2}$/.test(c.slice(i + 1, i + 3))) { out.push(parseInt(c.slice(i + 1, i + 3), 16)); i += 2; }
    else out.push(...Buffer.from(c[i]));
  }
  return Buffer.from(out);
}

/// Each non-generic path segment and query key or value, as { raw, bytes }.
function urlAtoms(u) {
  const out = [];
  for (const seg of u.pathname.split('/')) if (seg) out.push(seg);
  for (const part of u.search.replace(/^\?/, '').split('&')) {
    if (!part) continue;
    const eq = part.indexOf('=');
    for (const c of eq < 0 ? [part] : [part.slice(0, eq), part.slice(eq + 1)]) if (c) out.push(c);
  }
  // `+` means a space in a query but a literal `+` in a path, so both decodings are kept as spellings.
  return out
    .map((raw) => ({ raw, spellings: [Buffer.from(raw), pctBytes(raw), pctBytes(raw.replace(/\+/g, ' '))] }))
    .filter((a) => a.spellings.every((b) => !GENERIC_COMPONENT.test(b.toString('latin1'))));
}

/// Returns why a URL's shape is refused, or null. The reason never quotes the URL or any part of it.
function refuseUrlShape(url) {
  const u = new URL(url);
  if (u.username || u.password) return 'carries user:password credentials, which this probe refuses';
  if (u.hash) return 'has a #fragment, which this probe refuses';
  for (const a of urlAtoms(u)) {
    if (a.spellings.some((b) => b.length < MIN_ATOM)) {
      return `has a path segment or query component shorter than ${MIN_ATOM} characters that is not a known generic part; it could not be redacted reliably, so the probe refuses it`;
    }
  }
  return null;
}

/// Every window of `n` bytes of `b`, or `b` itself when shorter.
function windows(b, n) {
  if (b.length <= n) return [b];
  const out = [];
  for (let i = 0; i + n <= b.length; i++) out.push(b.subarray(i, i + n));
  return out;
}

/// Every secret-bearing form of every configured URL, longest first. Hosts are not secret.
function secretFragments() {
  const out = new Set();
  for (const url of URLS.values()) {
    const u = new URL(url);
    for (const whole of [url, u.pathname !== '/' ? u.pathname : '', u.search]) if (whole.length >= MIN_ATOM) out.add(whole);
    for (const a of urlAtoms(u)) {
      for (const b of a.spellings) {
        // A credential made of multi-byte characters: every WINDOW consecutive CHARACTERS, when it is valid UTF-8.
        const chars = Array.from(b.toString('utf8'));
        if (!chars.includes('\uFFFD')) {
          for (let i = 0; i + WINDOW <= chars.length; i++) out.add(chars.slice(i, i + WINDOW).join(''));
        }
        for (const w of windows(b, WINDOW)) {
          out.add(w.toString('latin1'));
          out.add(w.toString('utf8')); // a non-ASCII credential echoed as text
          out.add(w.toString('hex'));
          out.add(encodeURIComponent(w.toString('utf8')));
          out.add([...w].map((x) => '%' + x.toString(16).padStart(2, '0')).join('')); // every byte escaped
        }
        // Base64 in whole 3-byte groups, so each fragment's characters do not depend on the next byte. Any
        // echo of WINDOW consecutive credential bytes contains a 6-byte run on a 3-byte boundary.
        for (const w of windows(b, 6)) {
          out.add(w.toString('base64'));
          out.add(w.toString('base64url'));
        }
      }
    }
  }
  return [...out].filter(Boolean).sort((x, y) => y.length - x.length);
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/// Redacts every secret form from a string, case-insensitively (hex can come back in either case). Used
/// on ALL console output, so a provider string that slips through some future code path still cannot put
/// a credential in a log. It is the stdout counterpart of `writeEvidence`'s refusal. A single alternation,
/// longest first, so overlapping windows leave no run of WINDOW credential characters behind.
function scrub(text) {
  const frags = secretFragments();
  if (!frags.length) return String(text);
  return String(text).replace(new RegExp(frags.map(escapeRe).join('|'), 'gi'), '[redacted]');
}
{
  const log = console.log.bind(console);
  const err = console.error.bind(console);
  console.log = (...a) => log(...a.map(scrub));
  console.error = (...a) => err(...a.map(scrub));
  // An uncaught error's message can quote provider data too. Print it scrubbed, then fail.
  process.on('uncaughtException', (e) => { err(scrub(`uncaught: ${e?.message ?? e}`)); process.exit(1); });
  process.on('unhandledRejection', (e) => { err(scrub(`unhandled: ${e?.message ?? e}`)); process.exit(1); });
}

/// The only function that writes evidence. Before writing, it checks the serialized text for every secret
/// form of every configured URL (see `secretFragments`: compound forms AND each credential on its own,
/// raw, percent-encoded, hex and base64) and refuses to write if any appears.
function writeEvidence(dir, name, obj) {
  const text = JSON.stringify(obj, null, 2);
  const lower = text.toLowerCase();
  for (const f of secretFragments()) {
    // A fragment with a quote, backslash or control byte appears JSON-escaped in the serialized text.
    const frag = JSON.stringify(f).slice(1, -1);
    if (text.includes(f) || lower.includes(f.toLowerCase()) || lower.includes(frag.toLowerCase())) {
      console.error(`REFUSING TO WRITE EVIDENCE: it would contain part of a configured RPC URL. Nothing was written.`);
      process.exit(5);
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
  // value becomes `MISMATCH sha256:<hash>`. Before round 5 the addresses were the last 40 hex characters of
  // whatever came back, so a result carrying a hex-encoded credential would have been TRUNCATED into
  // evidence, and a truncated credential defeats any string guard. Comparing to the pin first, and
  // hashing on mismatch, leaves nothing to truncate. The comparison (`ok`) uses the raw values.
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
  if (offset !== 32 || length > 256 || b.length < 64 + length) return null;
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
const resultHashes = {};
const held = {}; // provider-chosen verify bytes, recorded only if shared; see below
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
  // The return's bytes, and every field decoded from them, are provider-chosen. They are held back here and
  // recorded below ONLY if both providers, run by distinct operators, returned identical bytes: neither
  // operator knows the other's credential, so a shared answer cannot carry either one. Until then a
  // provider's return is recorded as a hash and a reason code. The adversary pass on round 5 showed a
  // well-formed return carrying the key minus one character, which no string guard matches reliably.
  resultHashes[p.id] = sha256(textOf(call.body.result));
  held[p.id] = { rawResult: call.body.result, decoded: dec };
  results[p.id] = {
    provider: p, identity: ident, identityOk: idOk, status: 'SERVED',
    attempts: call.attempts, requestHash: call.requestHash, responseHash: call.responseHash,
    rawResultSha256: resultHashes[p.id],
    decoded: dec.ok ? { ok: true, payloadSha256: dec.payloadSha256 } : dec,
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

// The shared answer, recorded in full: the only provider-chosen bytes this file ever holds verbatim.
const shared = level === 'two-distinct-operators' && resultHashes[A.id] !== undefined &&
  resultHashes[A.id] === resultHashes[B.id] && held[A.id].decoded.ok;
if (shared) for (const id of [A.id, B.id]) Object.assign(results[id], held[id]);

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
