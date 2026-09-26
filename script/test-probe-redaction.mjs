// Regression test: the archive probe must never write an RPC URL's secret parts into evidence.
//
//   node script/test-probe-redaction.mjs
//
// WHY THIS EXISTS. On 2026-09-23 the probe was run with a credentialed Alchemy endpoint. It stored the
// whole provider object, URL included, in RESULT.json, and that file was committed to a PUBLIC repository.
// The key must be rotated. The Codex diff review (round 3) found the code path; the leak had already happened.
//
// This test runs the REAL probe script, from a temp copy of the repo, against a local mock JSON-RPC
// server, with URLs whose path and query carry sentinel strings standing in for a key. It asserts the
// sentinels appear NOWHERE: not in RESULT.json, not on stdout, not on stderr. It covers the full run and
// the early provider-resolution failure path, and it proves the last-line guard by re-introducing the
// original bug in a temp copy and requiring the probe to refuse to write.
//
// Round 5 of the Codex diff review found that a provider echoing the credential ON ITS OWN, rather than
// the URL spelling of it, got past both the console scrubber and the evidence guard. The ATOM modes below
// return each path and query credential alone: as error text, hex-encoded as a malformed result,
// base64-encoded, percent-decoded, truncated into an address word, and as a block hash. The leak check
// looks for any 10-character window of a credential too, since a truncated credential is still a leak.
// The PARTIAL modes come from the adversary pass on that fix: the credential minus one character, hex in
// a well-formed result, raw when the key is itself hex, and a digits-only key as the JSON-RPC error code.
// The GROUND mode comes from the second adversary pass: a provider knows its own credential, so it can
// search offline for a response whose sha256, which the evidence records, contains 10 of its characters.
//
// No network. The working tree is never modified.

import { mkdtempSync, cpSync, rmSync, writeFileSync, readFileSync, readdirSync, existsSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const SENTINELS = ['SENTINELPATHKEYaaaa1111', 'SENTINELQUERYbbbb2222', 'SENTINELPATHKEYcccc3333', 'SENTINELQUERYdddd4444',
  'SENTINELQUERY+pct5555', 'SENTINELUSERffff6666', 'SENTINELPASSgggg7777', 'SENTINEL"QUOTEhhhh8888', '\u00e9SENTINELUTF8iiii9999',
  'SENTINELCJK\u9375\u79d8\u5bc6\u9375\u79d8\u5bc6\u9375\u79d8\u5bc6\u9375', 'sentinelidkkkk1111'];

// ---- a minimal JSON-RPC server answering the calls the probe makes ----
// MODE makes the mock HOSTILE in the way the Codex diff review (round 4) described: a provider, gateway or
// proxy is free to echo the request URL, credential included, back in text it controls.
let MODE = 'normal';
const WORD0 = '0x' + '00'.repeat(32);
const abiString = (str) => {
  const hex = Buffer.from(str).toString('hex');
  return '0x' + (32).toString(16).padStart(64, '0') + (hex.length / 2).toString(16).padStart(64, '0')
    + hex.padEnd(Math.ceil(hex.length / 64) * 64, '0');
};
const hexOf = (str) => Buffer.from(str).toString('hex');
// For the HONEST mode: the verifier's real runtime code at block 62922075 (fetched from two operators,
// byte-identical; sha256 is the probe's pin and keccak256 is SPEC.md:78's) and the real verify return
// from the pinned B1 record. With these a mock can pass every identity check and the run can go green.
const VERIFIER_CODE = readFileSync(join(REPO, 'test/fixtures/datastreams/verifier-runtime-62922075.hex'), 'utf8').trim();
if (createHash('sha256').update(Buffer.from(VERIFIER_CODE.slice(2), 'hex')).digest('hex') !== '246be742ffcc522f72309f1f42c77817af4d6f823969ce9e5763f2a9327ca231') {
  throw new Error('vendored verifier code does not match the pinned sha256');
}
const PINNED_B1 = JSON.parse(readFileSync(join(REPO, 'test/fixtures/datastreams/evidence/archive-probe-2026-09-24T21-28-43-466Z/RESULT.json'), 'utf8'));
const VERIFY_RETURN = PINNED_B1.providers['monad-public'].rawResult;
const ZERO_WORD = '0x' + '00'.repeat(32);
const server = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const { id, method, params } = JSON.parse(body);
    const data = String(params?.[0]?.data || '');
    res.setHeader('content-type', 'application/json');
    // The credentials of THIS request, as the provider sees them: the last path segment and the first
    // query value, the latter percent-DECODED, which is how a server framework hands it to its code.
    const u = new URL(req.url, 'http://mock');
    const pathAtom = u.pathname.split('/').filter(Boolean).pop() || '';
    const queryAtom = [...u.searchParams.values()][0] || '';
    const isVerify = method === 'eth_call' && data.startsWith('0xf7e83aee');
    const fail = (code, message) => res.end(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }));
    const ok = (result) => res.end(JSON.stringify({ jsonrpc: '2.0', id, result }));
    if (isVerify && MODE === 'atom-error-path') return fail(-32000, `invalid key ${pathAtom}`);
    if (isVerify && MODE === 'atom-error-query') return fail(3, `execution reverted: apikey ${queryAtom} unknown`);
    if (isVerify && MODE === 'atom-base64-error') return fail(-32000, `denied ${Buffer.from(pathAtom).toString('base64')}`);
    if (isVerify && MODE === 'atom-hex-malformed-path') return ok('0x' + hexOf(pathAtom));
    if (isVerify && MODE === 'atom-hex-malformed-query') return ok('0x' + hexOf(queryAtom));
    const envelope = (payloadHex) => '0x' + (32).toString(16).padStart(64, '0') + (288).toString(16).padStart(64, '0') + payloadHex.padEnd(576, '0');
    if (isVerify && MODE === 'atom-wellformed-query') return ok(envelope(hexOf(queryAtom)));
    if (isVerify && MODE === 'partial-hex-path') return ok(envelope(hexOf(pathAtom.slice(0, -1))));
    if (isVerify && MODE === 'partial-hex-query') return ok(envelope(hexOf(queryAtom.slice(1))));
    if (isVerify && MODE === 'partial-raw-hexkey') return ok(envelope(pathAtom.slice(0, -1)));
    if (isVerify && MODE === 'partial-rpc-code') return fail(Number(queryAtom.slice(0, -1)), 'execution reverted');
    // BOTH providers get the SAME well-formed answer carrying part of provider A's credential. Identical
    // answers from distinct operators ARE recorded verbatim, so here the last-line guard must refuse.
    if (isVerify && MODE === 'atom-hex-decoded-path') {
      // The path credential percent-decoded to BYTES, which need not be valid UTF-8, then hex-encoded.
      const bytes = Buffer.from(pathAtom.replace(/%([0-9a-fA-F]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16))), 'latin1');
      return ok('0x' + bytes.toString('hex'));
    }
    if (isVerify && MODE === 'ground-hash') return ok(GROUND_RESULT);
    if (MODE === 'honest') {
      if (method === 'eth_chainId') return ok('0x279f');
      if (method === 'eth_getCode') return ok(VERIFIER_CODE);
      if (method === 'eth_getBlockByNumber') return ok({ number: '0x3c01d5b', hash: '0x73f54743b7db644c8f010e74f422107337b586b59fed5a91916f98b384a722d6', timestamp: '0x6aaa0c48' });
      if (data.startsWith('0x38416b5b') || data.startsWith('0x94ba2846')) return ok(ZERO_WORD);
      if (data.startsWith('0x181f5a77')) return ok(abiString('VerifierProxy 2.0.0'));
      if (isVerify) return ok(VERIFY_RETURN);
    }
    // Third adversary pass: inputs that crashed the run (exit 1, no evidence) rather than leaked.
    // Fourth adversary pass: provider A (identified by its credential) stalls or redirects.
    const isA = pathAtom === SENTINELS[0];
    if (MODE === 'drip' && isA && method === 'eth_chainId') {
      // HTTP 200, the start of a valid answer, then one byte of whitespace every 200 ms, never finishing.
      res.writeHead(200, { 'content-type': 'application/json' });
      res.write(`{"jsonrpc":"2.0","id":${id},"result":"0x279f"`);
      const t = setInterval(() => res.write(' '), 200);
      res.on('close', () => clearInterval(t));
      return;
    }
    if (MODE === 'nul-tv' && isA && data.startsWith('0x181f5a77')) {
      // ~2 MB of NULs then one other byte: a trailing-NUL regex over this ran for ~18 minutes.
      return ok('0x' + '00'.repeat(64) + '00'.repeat(2_000_000) + '58');
    }
    if (MODE === 'unauthorized' && isA) {
      // Every call from provider A rejected as unauthenticated, as a mistyped key is (2026-09-26).
      res.writeHead(401, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32600, message: `Must be authenticated! ${req.url}` } }));
    }
    if (MODE === 'redirect' && isA) {
      // Every call from provider A is sent to provider B's endpoint instead.
      res.writeHead(307, { location: `http://${HOST}/v2/${SENTINELS[2]}?apikey=${SENTINELS[3]}` });
      return res.end();
    }
    if (MODE === 'huge-code' && isA && method === 'eth_getCode') return ok('0x' + 'ab'.repeat(6_000_000));
    if (MODE === 'object-hash' && method === 'eth_getBlockByNumber') {
      return ok({ number: '0x3c01d5b', hash: { toString: 1, note: req.url }, timestamp: '0x6aaa0c48' });
    }
    if (isVerify && MODE === 'object-message') return fail(-32000, { toString: 1, url: req.url });
    if (isVerify && MODE === 'partial-shared') return ok(envelope(hexOf(SENTINELS[0].slice(0, -1))));
    if (MODE === 'atom-address' && method === 'eth_call' && data.startsWith('0x38416b5b')) {
      // s_feeManager(): a 32-byte word ending in the credential, which a last-40-hex slice truncates.
      return ok('0x' + hexOf(pathAtom).padStart(64, '0'));
    }
    if (MODE === 'atom-blockhash' && method === 'eth_getBlockByNumber') {
      return ok({ number: '0x3c01d5b', hash: '0x' + hexOf(pathAtom).padEnd(64, '0'), timestamp: '0x6aaa0c48' });
    }
    if (MODE === 'echo-revert' && method === 'eth_call' && data.startsWith('0xf7e83aee')) {
      // HTTP 200, JSON-RPC code 3, and the full request path and query in the message.
      res.end(JSON.stringify({ jsonrpc: '2.0', id, error: { code: 3, message: `execution reverted; upstream ${req.url}` } }));
      return;
    }
    if (MODE === 'echo-tv' && method === 'eth_call' && data.startsWith('0x181f5a77')) {
      res.end(JSON.stringify({ jsonrpc: '2.0', id, result: abiString(`VerifierProxy 2.0.0 via ${req.url}`) }));
      return;
    }
    const result = {
      eth_chainId: '0x279f',
      eth_getCode: '0x00',
      eth_call: WORD0 + '00'.repeat(32), // 64 zero bytes: identity will mismatch, which is fine here
      eth_getBlockByNumber: { number: '0x3c01d5b', hash: '0x' + '11'.repeat(32), timestamp: '0x6aaa0c48' },
    }[method];
    res.end(JSON.stringify({ jsonrpc: '2.0', id, result }));
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const HOST = `127.0.0.1:${server.address().port}`;

function tree({ reintroduceBug = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'mako-redact-'));
  cpSync(join(REPO, 'script'), join(dir, 'script'), { recursive: true });
  cpSync(join(REPO, 'test/fixtures/datastreams/pending'), join(dir, 'test/fixtures/datastreams/pending'), { recursive: true });
  // Two mock providers with distinct operators, both "credentialed", both on the local server.
  writeFileSync(join(dir, 'script/providers.json'), JSON.stringify({
    providers: [
      { id: 'mock-a', host: HOST, urlEnv: 'MAKO_RPC_MOCK_A', operator: 'Mock Operator A', credentialed: true },
      { id: 'mock-b', host: HOST, urlEnv: 'MAKO_RPC_MOCK_B', operator: 'Mock Operator B', credentialed: true },
      { id: 'mock-remote', host: 'rpc.example.invalid', urlEnv: 'MAKO_RPC_MOCK_REMOTE', operator: 'Mock Remote', credentialed: true },
    ],
  }));
  if (reintroduceBug) {
    // Put the original defect back: serialize the full URL into the evidence object.
    const p = join(dir, 'script/probe-archive.mjs');
    const src = readFileSync(p, 'utf8');
    const leak = {
      partial: 'urlOf(A).slice(-15, -1)',
      // 'x' + 10 credential bytes: base64 of that starts the credential one byte off a 3-byte boundary.
      'base64-10': "Buffer.from('x' + urlOf(A).slice(-11, -1)).toString('base64')",
      // 10 characters spanning the quote, so no quote-free 10-character run exists to match unescaped.
      'decoded-query': "new URL(urlOf(A)).searchParams.get('apikey').slice(3, 13)",
      'decoded-query-10': "new URL(urlOf(A)).searchParams.get('apikey').slice(0, 10)",
      'pct-bytes': "[...Buffer.from(urlOf(A).slice(-11, -1))].map((x) => '%' + x.toString(16).padStart(2, '0')).join('')",
      'decoded-query-last-10': "Array.from(new URL(urlOf(A)).searchParams.get('apikey')).slice(-10).join('')",
    }[reintroduceBug] || 'urlOf(A)';
    const patched = src.replace('status,\n  proofLevel: level,', `status,\n  leakedUrl: ${leak},\n  proofLevel: level,`);
    if (patched === src) throw new Error('could not re-introduce the bug: anchor moved');
    writeFileSync(p, patched);
  }
  return dir;
}

// ASYNC, deliberately: the mock server runs in this same process, so a synchronous spawn would block the
// event loop and the server could never answer the probe it is waiting on. The first draft did exactly
// that and deadlocked.
// Every run is KILLED after RUN_BUDGET_MS, so a probe that hangs fails its scenario (code null) instead of
// hanging this test and the CI job with it.
const RUN_BUDGET_MS = 120_000;
async function runProbe(dir, env) {
  const started = Date.now();
  const r = await new Promise((resolve) => {
    const child = spawn('node', [join(dir, 'script/probe-archive.mjs')], {
      env: { ...process.env, MAKO_PROVIDER_A: 'mock-a', MAKO_PROVIDER_B: 'mock-b', ...env },
    });
    const kill = setTimeout(() => child.kill('SIGKILL'), RUN_BUDGET_MS);
    let stdout = '', stderr = '';
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('close', (status) => { clearTimeout(kill); resolve({ status, stdout, stderr }); });
  });
  const evDir = join(dir, 'test/fixtures/datastreams/evidence');
  const runs = existsSync(evDir) ? readdirSync(evDir) : [];
  const resultText = runs.length && existsSync(join(evDir, runs[0], 'RESULT.json'))
    ? readFileSync(join(evDir, runs[0], 'RESULT.json'), 'utf8') : null;
  return { code: r.status, out: (r.stdout || '') + (r.stderr || ''), resultText, ms: Date.now() - started };
}

// Plain AND hex-encoded, since a provider can return bytes that decode to the credential.
// A leak is any 10-character window of a credential, plain or hex, or the whole credential in base64.
function forms(secret) {
  const out = new Set([Buffer.from(secret).toString('base64').replace(/=+$/, ''), encodeURIComponent(secret)]);
  for (let i = 0; i + 10 <= secret.length; i++) {
    const w = secret.slice(i, i + 10);
    out.add(w.toLowerCase());
    out.add(Buffer.from(w).toString('hex'));
  }
  return [...out];
}
const leaks = (text, extra = []) => {
  if (!text) return [];
  const lower = text.toLowerCase();
  return [...SENTINELS, ...extra].filter((s) => s.length < 10
    ? lower.includes(s.toLowerCase())
    : forms(s).some((f) => lower.includes(f.toLowerCase())));
};
const urlA = `http://${HOST}/v2/${SENTINELS[0]}?apikey=${SENTINELS[1]}`;
const urlB = `http://${HOST}/v2/${SENTINELS[2]}?apikey=${SENTINELS[3]}`;
const both = { MAKO_RPC_MOCK_A: urlA, MAKO_RPC_MOCK_B: urlB };
const HEXKEY = 'feedfacecafebabe0123456789abcdef'; // an Infura-style key made only of hex characters
const NUMKEY = '314159265358979'; // a digits-only key
// Found by the second adversary pass with an offline search: sha256("0x000000001c0a4437") contains
// "6535897932", 10 consecutive digits of GROUND_DIGITS. Re-checked here so the fixture cannot silently rot.
const GROUND_DIGITS = '3141592653589793238462643383279';
const GROUND_RESULT = '0x000000001c0a4437';
{
  const h = createHash('sha256').update(GROUND_RESULT).digest('hex');
  if (!h.includes('6535897932') || !GROUND_DIGITS.includes('6535897932')) throw new Error('GROUND fixture no longer grinds');
}
const clean = (r, extra) => leaks(r.resultText, extra).length === 0 && leaks(r.out, extra).length === 0;
// "Evidence written" alone is also what a probe that can read NOTHING produces (a transport bug once made
// every request throw, and most scenarios still passed). So a written run must also show the HONEST
// provider, mock-b, actually served and identified: the hostile data was really read and handled.
const honestServed = (r) => { try { return JSON.parse(r.resultText).providers['mock-b'].identity.served === true; } catch { return false; } };
const written = (r, extra) => r.resultText !== null && clean(r, extra) && honestServed(r);
const refusedAtConfig = (r, extra) => r.code === 2 && r.resultText !== null && clean(r, extra);

const scenarios = [
  {
    name: 'full run through both credentialed providers',
    opts: {},
    env: { MAKO_RPC_MOCK_A: urlA, MAKO_RPC_MOCK_B: urlB },
    check: (r) => written(r),
  },
  {
    name: 'early failure path: one provider unresolved, evidence still written',
    opts: {},
    env: { MAKO_RPC_MOCK_A: urlA, MAKO_RPC_MOCK_B: '' },
    check: (r) => r.code === 2 && r.resultText !== null && leaks(r.resultText).length === 0 && leaks(r.out).length === 0,
  },
  {
    name: 'HOSTILE provider echoes the credentialed URL in a JSON-RPC revert message (round 4 finding)',
    mode: 'echo-revert',
    opts: {},
    env: { MAKO_RPC_MOCK_A: urlA, MAKO_RPC_MOCK_B: urlB },
    check: (r) => written(r),
  },
  {
    name: 'HOSTILE provider echoes the credentialed URL in its typeAndVersion string',
    mode: 'echo-tv',
    opts: {},
    env: { MAKO_RPC_MOCK_A: urlA, MAKO_RPC_MOCK_B: urlB },
    check: (r) => written(r),
  },
  // ---- round 5: the credential on its own ----
  { name: 'ATOM: path credential alone in a JSON-RPC error message', mode: 'atom-error-path', opts: {}, env: both, check: (r) => written(r) },
  { name: 'ATOM: query credential alone in a code-3 revert message', mode: 'atom-error-query', opts: {}, env: both, check: (r) => written(r) },
  { name: 'ATOM: path credential base64-encoded in an error message', mode: 'atom-base64-error', opts: {}, env: both, check: (r) => written(r) },
  { name: 'ATOM: path credential hex-encoded as a malformed verify result', mode: 'atom-hex-malformed-path', opts: {}, env: both, check: (r) => written(r) },
  { name: 'ATOM: query credential hex-encoded as a malformed verify result', mode: 'atom-hex-malformed-query', opts: {}, env: both, check: (r) => written(r) },
  { name: 'ATOM: path credential truncated into an address word (s_feeManager)', mode: 'atom-address', opts: {}, env: both, check: (r) => written(r) },
  { name: 'ATOM: path credential hex-encoded as the block hash', mode: 'atom-blockhash', opts: {}, env: both, check: (r) => written(r) },
  {
    name: 'ATOM: percent-encoded query credential echoed DECODED',
    mode: 'atom-error-query',
    opts: {},
    env: { MAKO_RPC_MOCK_A: `http://${HOST}/v2/${SENTINELS[0]}?apikey=${encodeURIComponent(SENTINELS[4])}`, MAKO_RPC_MOCK_B: urlB },
    check: (r) => written(r),
  },
  { name: 'ATOM: query credential hex in a WELL-FORMED return (not shared, so not recorded)', mode: 'atom-wellformed-query', opts: {}, env: both, check: (r) => written(r) },
  // ---- adversary pass on round 5: part of the credential ----
  { name: 'PARTIAL: path credential minus one char, hex, in a well-formed return', mode: 'partial-hex-path', opts: {}, env: both, check: (r) => written(r) },
  { name: 'PARTIAL: query credential minus one char, hex, in a well-formed return', mode: 'partial-hex-query', opts: {}, env: both, check: (r) => written(r) },
  {
    name: 'PARTIAL: hex-alphabet credential minus one char, raw, in a well-formed return',
    mode: 'partial-raw-hexkey',
    opts: {},
    env: { MAKO_RPC_MOCK_A: `http://${HOST}/v3/${HEXKEY}`, MAKO_RPC_MOCK_B: urlB },
    extra: [HEXKEY],
    check: (r) => written(r, [HEXKEY]),
  },
  {
    name: 'PARTIAL: digits-only credential minus one digit, as the JSON-RPC error code',
    mode: 'partial-rpc-code',
    opts: {},
    env: { MAKO_RPC_MOCK_A: `http://${HOST}/v2/${SENTINELS[0]}?apikey=${NUMKEY}`, MAKO_RPC_MOCK_B: urlB },
    extra: [NUMKEY],
    check: (r) => written(r, [NUMKEY]),
  },
  {
    // Since the twelfth adversary pass a non-ASCII credential is REFUSED before any call, so it can never be
    // echoed; these three cases now require that refusal, with the reason, and nothing leaked.
    name: 'CONFIG: a path credential with a non-UTF-8 escape is refused before any call',
    mode: 'atom-hex-decoded-path',
    opts: {},
    env: { MAKO_RPC_MOCK_A: `http://${HOST}/v2/%FF${SENTINELS[0]}`, MAKO_RPC_MOCK_B: urlB },
    check: (r) => refusedAtConfig(r) && r.out.includes('non-ASCII'),
  },
  {
    name: 'LAST-LINE GUARD: a SHARED well-formed return carrying part of a credential is refused (exit 5)',
    mode: 'partial-shared',
    opts: {},
    env: both,
    check: (r) => r.code === 5 && r.resultText === null && clean(r),
  },
  {
    name: 'GROUND: credential v<digits> (not a version label) with a hash ground to 10 of its digits is refused (exit 5)',
    mode: 'ground-hash',
    opts: {},
    env: { MAKO_RPC_MOCK_A: `http://${HOST}/v2/v${GROUND_DIGITS}`, MAKO_RPC_MOCK_B: urlB },
    extra: [GROUND_DIGITS],
    check: (r) => r.code === 5 && r.resultText === null && clean(r, [GROUND_DIGITS]),
  },
  {
    name: 'GROUND control: the same attack on credential k<digits> is refused (exit 5)',
    mode: 'ground-hash',
    opts: {},
    env: { MAKO_RPC_MOCK_A: `http://${HOST}/v2/k${GROUND_DIGITS}`, MAKO_RPC_MOCK_B: urlB },
    extra: [GROUND_DIGITS],
    check: (r) => r.code === 5 && r.resultText === null && clean(r, [GROUND_DIGITS]),
  },
  {
    name: 'LAST-LINE GUARD: a bug writing 10 credential bytes base64-encoded off a 3-byte boundary is refused (exit 5)',
    opts: { reintroduceBug: 'base64-10' },
    env: both,
    check: (r) => r.code === 5 && r.resultText === null && clean(r),
  },
  {
    name: 'LAST-LINE GUARD: a bug writing 10 credential characters spanning a quote (JSON-escaped) is refused (exit 5)',
    opts: { reintroduceBug: 'decoded-query' },
    env: { MAKO_RPC_MOCK_A: `http://${HOST}/v2/${SENTINELS[0]}?apikey=${encodeURIComponent(SENTINELS[7])}`, MAKO_RPC_MOCK_B: urlB },
    check: (r) => r.code === 5 && r.resultText === null && clean(r),
  },
  {
    name: 'CONFIG: a non-ASCII (accented) query credential is refused before any call',
    opts: {},
    env: { MAKO_RPC_MOCK_A: `http://${HOST}/v2/${SENTINELS[0]}?apikey=${encodeURIComponent(SENTINELS[8])}`, MAKO_RPC_MOCK_B: urlB },
    check: (r) => refusedAtConfig(r) && r.out.includes('non-ASCII'),
  },
  {
    name: 'CONFIG: a CJK query credential is refused before any call',
    opts: {},
    env: { MAKO_RPC_MOCK_A: `http://${HOST}/v2/${SENTINELS[0]}?apikey=${encodeURIComponent(SENTINELS[9])}`, MAKO_RPC_MOCK_B: urlB },
    check: (r) => refusedAtConfig(r) && r.out.includes('non-ASCII'),
  },
  // ---- third adversary pass ----
  {
    name: 'PROVIDER ID: a URL pasted into MAKO_PROVIDER_A is neither printed nor recorded',
    opts: {},
    env: { ...both, MAKO_PROVIDER_A: urlA },
    check: (r) => refusedAtConfig(r),
  },
  {
    name: 'PROVIDER ID: an unknown id shaped like a key is neither printed nor recorded',
    opts: {},
    env: { ...both, MAKO_PROVIDER_A: SENTINELS[10] },
    check: (r) => refusedAtConfig(r),
  },
  {
    name: 'ROBUST: a 12 MB eth_getCode result is refused as oversized and classified, not a crash',
    mode: 'huge-code',
    opts: {},
    env: both,
    check: (r) => {
      if (!(r.code === 3 && written(r))) return false;
      const a = JSON.parse(r.resultText).providers['mock-a'].identity.unserved?.eth_getCode || [];
      return a.length > 0 && a.every((x) => x.category === 'oversized');
    },
  },
  // ---- fifth adversary pass ----
  {
    name: 'BOUND: a typeAndVersion of ~2 MB of NULs plus one byte is classified in seconds, not minutes',
    mode: 'nul-tv',
    opts: {},
    env: both,
    check: (r) => r.code === 3 && written(r) && r.ms < 30_000,
  },
  {
    name: 'OPERATOR: a plain-HTTP endpoint that is not loopback is refused (a proxy or the path could answer)',
    opts: {},
    env: { ...both, MAKO_PROVIDER_A: 'mock-remote', MAKO_RPC_MOCK_REMOTE: `http://rpc.example.invalid/v2/${SENTINELS[0]}` },
    check: (r) => refusedAtConfig(r) && r.out.includes('must be an https:// URL'),
  },
  {
    name: 'HONEST: two honest providers with the real verifier code and return give VERIFIED_MATCH, and the run exits by itself',
    mode: 'honest',
    opts: {},
    env: both,
    check: (r) => r.code === 0 && r.ms < 30_000 && r.resultText !== null && JSON.parse(r.resultText).status === 'VERIFIED_MATCH' && clean(r),
  },
  // ---- fourth adversary pass ----
  {
    name: 'ROBUST: a provider dripping one byte at a time is timed out and classified, not waited on forever',
    mode: 'drip',
    opts: {},
    env: { ...both, MAKO_PROBE_RPC_TIMEOUT_MS: '1500' },
    check: (r) => r.code === 3 && written(r) && JSON.parse(r.resultText).status === 'ARCHIVE_UNAVAILABLE',
  },
  {
    name: 'OPERATOR: a provider redirecting its calls elsewhere is refused, not answered by the other endpoint',
    mode: 'redirect',
    opts: {},
    env: both,
    check: (r) => r.code === 3 && written(r) && JSON.parse(r.resultText).status === 'ARCHIVE_UNAVAILABLE',
  },
  {
    name: 'DIAGNOSTICS: a provider rejecting every call (a mistyped key) is recorded as HTTP 401 per read, nothing leaked',
    mode: 'unauthorized',
    opts: {},
    env: { ...both, MAKO_PROBE_RPC_TIMEOUT_MS: '1500' },
    check: (r) => {
      if (!(r.code === 3 && written(r))) return false;
      const u = JSON.parse(r.resultText).providers['mock-a'].identity.unserved || {};
      return Object.keys(u).length === 6 && Object.values(u).every((a) => a.every((x) => x.httpStatus === 401));
    },
  },
  {
    name: 'LAST-LINE GUARD: a bug writing 10 credential bytes with EVERY byte percent-escaped is refused (exit 5)',
    opts: { reintroduceBug: 'pct-bytes' },
    env: both,
    check: (r) => r.code === 5 && r.resultText === null && clean(r),
  },
  { name: 'ROBUST: a block hash that is an object with a non-callable toString', mode: 'object-hash', opts: {}, env: both, check: (r) => r.code === 3 && written(r) },
  { name: 'ROBUST: an error message that is an object carrying the URL', mode: 'object-message', opts: {}, env: both, check: (r) => r.code === 3 && written(r) },
  {
    name: 'LAST-LINE GUARD: a bug writing the query credential minus one char is refused (exit 5)',
    opts: { reintroduceBug: 'partial' },
    env: both,
    check: (r) => r.code === 5 && r.resultText === null && clean(r),
  },
  {
    name: 'CONFIG: a URL with user:password credentials is refused, and neither is printed',
    opts: {},
    env: { MAKO_RPC_MOCK_A: `http://${SENTINELS[5]}:${SENTINELS[6]}@${HOST}/v2/${SENTINELS[0]}`, MAKO_RPC_MOCK_B: urlB },
    check: (r) => refusedAtConfig(r),
  },
  {
    name: 'CONFIG: a short non-generic path segment is refused, not left unredacted',
    opts: {},
    env: { MAKO_RPC_MOCK_A: `http://${HOST}/v2/Kx9q2`, MAKO_RPC_MOCK_B: urlB },
    extra: ['Kx9q2'],
    check: (r) => refusedAtConfig(r, ['Kx9q2']),
  },
  {
    name: 'CONFIG: a short query value is refused',
    opts: {},
    env: { MAKO_RPC_MOCK_A: `http://${HOST}/v2/${SENTINELS[0]}?apikey=Zp4w`, MAKO_RPC_MOCK_B: urlB },
    extra: ['Zp4w'],
    check: (r) => refusedAtConfig(r, ['Zp4w']),
  },
  {
    name: 'CONFIG: a URL with a #fragment is refused',
    opts: {},
    env: { MAKO_RPC_MOCK_A: `http://${HOST}/v2/${SENTINELS[0]}#${SENTINELS[1]}`, MAKO_RPC_MOCK_B: urlB },
    check: (r) => refusedAtConfig(r),
  },
  {
    name: 'LAST-LINE GUARD: with the original bug put back, the probe refuses to write (exit 5)',
    opts: { reintroduceBug: true },
    env: { MAKO_RPC_MOCK_A: urlA, MAKO_RPC_MOCK_B: urlB },
    check: (r) => r.code === 5 && r.resultText === null && leaks(r.out).length === 0,
  },
];

let bad = 0;
for (const sc of scenarios) {
  const dir = tree(sc.opts);
  MODE = sc.mode || 'normal';
  try {
    const r = await runProbe(dir, sc.env);
    const ok = sc.check(r);
    if (!ok) bad++;
    console.log(`  [${ok ? ' ok ' : 'FAIL'}] ${sc.name}`);
    if (!ok) console.log(r.out.split('\n').filter((l) => /Error|error|at /.test(l)).slice(0, 6).map((l) => `         | ${l}`).join('\n'));
    console.log(`         exit ${r.code}, evidence ${r.resultText === null ? 'NOT written' : 'written'}, sentinel leaks: ` +
      `${leaks(r.resultText, sc.extra).length + leaks(r.out, sc.extra).length}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
server.close();

console.log(`\n  ${scenarios.length - bad} of ${scenarios.length} scenarios behaved as required.`);
if (bad) process.exit(1);
console.log('  No credential, whole or in part, in any tested encoding, reaches evidence or console output,');
console.log('  and the guard catches a regression.');
