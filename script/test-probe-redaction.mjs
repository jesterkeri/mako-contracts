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
//
// No network. The working tree is never modified.

import { mkdtempSync, cpSync, rmSync, writeFileSync, readFileSync, readdirSync, existsSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const SENTINELS = ['SENTINELPATHKEYaaaa1111', 'SENTINELQUERYbbbb2222', 'SENTINELPATHKEYcccc3333', 'SENTINELQUERYdddd4444',
  'SENTINELQUERY+pct5555', 'SENTINELUSERffff6666', 'SENTINELPASSgggg7777'];

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
    ],
  }));
  if (reintroduceBug) {
    // Put the original defect back: serialize the full URL into the evidence object.
    const p = join(dir, 'script/probe-archive.mjs');
    const src = readFileSync(p, 'utf8');
    const leak = reintroduceBug === 'partial' ? 'urlOf(A).slice(-15, -1)' : 'urlOf(A)';
    const patched = src.replace('status,\n  proofLevel: level,', `status,\n  leakedUrl: ${leak},\n  proofLevel: level,`);
    if (patched === src) throw new Error('could not re-introduce the bug: anchor moved');
    writeFileSync(p, patched);
  }
  return dir;
}

// ASYNC, deliberately: the mock server runs in this same process, so a synchronous spawn would block the
// event loop and the server could never answer the probe it is waiting on. The first draft did exactly
// that and deadlocked.
async function runProbe(dir, env) {
  const r = await new Promise((resolve) => {
    const child = spawn('node', [join(dir, 'script/probe-archive.mjs')], {
      env: { ...process.env, MAKO_PROVIDER_A: 'mock-a', MAKO_PROVIDER_B: 'mock-b', ...env },
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('close', (status) => resolve({ status, stdout, stderr }));
  });
  const evDir = join(dir, 'test/fixtures/datastreams/evidence');
  const runs = existsSync(evDir) ? readdirSync(evDir) : [];
  const resultText = runs.length && existsSync(join(evDir, runs[0], 'RESULT.json'))
    ? readFileSync(join(evDir, runs[0], 'RESULT.json'), 'utf8') : null;
  return { code: r.status, out: (r.stdout || '') + (r.stderr || ''), resultText };
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
const clean = (r, extra) => leaks(r.resultText, extra).length === 0 && leaks(r.out, extra).length === 0;
const written = (r, extra) => r.resultText !== null && clean(r, extra);
const refusedAtConfig = (r, extra) => r.code === 2 && r.resultText !== null && clean(r, extra);

const scenarios = [
  {
    name: 'full run through both credentialed providers',
    opts: {},
    env: { MAKO_RPC_MOCK_A: urlA, MAKO_RPC_MOCK_B: urlB },
    check: (r) => r.resultText !== null && leaks(r.resultText).length === 0 && leaks(r.out).length === 0,
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
    check: (r) => r.resultText !== null && leaks(r.resultText).length === 0 && leaks(r.out).length === 0,
  },
  {
    name: 'HOSTILE provider echoes the credentialed URL in its typeAndVersion string',
    mode: 'echo-tv',
    opts: {},
    env: { MAKO_RPC_MOCK_A: urlA, MAKO_RPC_MOCK_B: urlB },
    check: (r) => r.resultText !== null && leaks(r.resultText).length === 0 && leaks(r.out).length === 0,
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
    name: 'ATOM: path credential with a non-UTF-8 escape, echoed as decoded bytes in hex',
    mode: 'atom-hex-decoded-path',
    opts: {},
    env: { MAKO_RPC_MOCK_A: `http://${HOST}/v2/%FF${SENTINELS[0]}`, MAKO_RPC_MOCK_B: urlB },
    check: (r) => written(r),
  },
  {
    name: 'LAST-LINE GUARD: a SHARED well-formed return carrying part of a credential is refused (exit 5)',
    mode: 'partial-shared',
    opts: {},
    env: both,
    check: (r) => r.code === 5 && r.resultText === null && clean(r),
  },
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
