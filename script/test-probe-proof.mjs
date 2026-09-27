// Proof-integrity test for the archive probe (script/probe-archive.mjs).
//
//   node script/test-probe-proof.mjs        about a minute; no network, no openssl
//
// The probe is keyless by construction (2026-09-27): it talks only to each provider's fixed public `url` in
// providers.json and reads no URL from the environment. This test runs the REAL probe from a temp copy of the
// repo against two local mock JSON-RPC servers (two ports, so two distinct hosts), each written into a temp
// providers.json as that provider's fixed url. The honest mocks serve the verifier's real runtime code
// (test/fixtures/datastreams/verifier-runtime-62922075.hex, sha256-checked) and the real verify return from
// the pinned B1 record, so an honest run is a genuine VERIFIED_MATCH.
//
// It replaces test-probe-redaction.mjs and four other redaction tests, retired with the redaction they
// tested (in git history up to 56d307b). Codex diff review round 6's regression is the ENV case below: URLs
// placed in every environment variable the old probe read must receive no request at all.
//
// The TLS tests (test-probe-tls*.mjs) cover who can answer over https; this file covers everything else.

import { mkdtempSync, cpSync, rmSync, writeFileSync, readFileSync, readdirSync, existsSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');

// ---- honest answers, from the repository's own fixtures ----
const VERIFIER_CODE = readFileSync(join(REPO, 'test/fixtures/datastreams/verifier-runtime-62922075.hex'), 'utf8').trim();
if (createHash('sha256').update(Buffer.from(VERIFIER_CODE.slice(2), 'hex')).digest('hex') !== '246be742ffcc522f72309f1f42c77817af4d6f823969ce9e5763f2a9327ca231') {
  throw new Error('vendored verifier code does not match the pinned sha256');
}
const PINNED_B1 = JSON.parse(readFileSync(join(REPO, 'test/fixtures/datastreams/evidence/archive-probe-2026-09-24T21-28-43-466Z/RESULT.json'), 'utf8'));
const VERIFY_RETURN = PINNED_B1.providers['monad-public'].rawResult;
const ZERO_WORD = '0x' + '00'.repeat(32);
const word = (n) => n.toString(16).padStart(64, '0');
const TV = '0x' + word(32) + word(19) + Buffer.from('VerifierProxy 2.0.0').toString('hex').padEnd(64, '0');
const BLOCK = { number: '0x3c01d5b', hash: '0x73f54743b7db644c8f010e74f422107337b586b59fed5a91916f98b384a722d6', timestamp: '0x6aaa0c48' };

// ---- mock servers: A, B, and a DECOY that must never be contacted ----
function mock() {
  const m = { mode: 'honest', requests: 0 };
  m.server = createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      m.requests++;
      const { id, method, params } = JSON.parse(body);
      const data = String(params?.[0]?.data || '');
      const isVerify = method === 'eth_call' && data.startsWith('0xf7e83aee');
      const ok = (result) => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ jsonrpc: '2.0', id, result })); };
      const fail = (code, message) => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } })); };
      switch (m.mode) {
        case 'drip':
          if (method === 'eth_chainId') {
            res.writeHead(200, { 'content-type': 'application/json' });
            res.write(`{"jsonrpc":"2.0","id":${id},"result":"0x279f"`);
            const t = setInterval(() => res.write(' '), 200);
            res.on('close', () => clearInterval(t));
            return;
          }
          break;
        case 'redirect':
          res.writeHead(307, { location: `http://${B.host}/` });
          return res.end();
        case 'unauthorized':
          res.writeHead(401, { 'content-type': 'application/json' });
          return res.end(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32600, message: 'Must be authenticated!' } }));
        case 'huge-code':
          if (method === 'eth_getCode') return ok('0x' + 'ab'.repeat(6_000_000));
          break;
        case 'nul-tv':
          if (data.startsWith('0x181f5a77')) return ok('0x' + '00'.repeat(64) + '00'.repeat(2_000_000) + '58');
          break;
        case 'object-values':
          if (method === 'eth_getBlockByNumber') return ok({ number: BLOCK.number, hash: { toString: 1 }, timestamp: BLOCK.timestamp });
          if (isVerify) return fail(-32000, { toString: 1 });
          break;
        case 'different-verify':
          if (isVerify) return ok(VERIFY_RETURN.slice(0, -2) + (VERIFY_RETURN.endsWith('00') ? '01' : '00'));
          break;
        case 'malformed-verify':
          if (isVerify) return ok('0x1234');
          break;
      }
      if (method === 'eth_chainId') return ok('0x279f');
      if (method === 'eth_getCode') return ok(VERIFIER_CODE);
      if (method === 'eth_getBlockByNumber') return ok(BLOCK);
      if (data.startsWith('0x38416b5b') || data.startsWith('0x94ba2846')) return ok(ZERO_WORD);
      if (data.startsWith('0x181f5a77')) return ok(TV);
      if (isVerify) return ok(VERIFY_RETURN);
      ok(null);
    });
  });
  return m;
}
const A = mock(), B = mock(), DECOY = mock();
for (const m of [A, B, DECOY]) {
  await new Promise((r) => m.server.listen(0, '127.0.0.1', r));
  m.host = `127.0.0.1:${m.server.address().port}`;
}

// ---- a temp copy of the repository with a providers.json pointing at the mocks ----
function tree(providers) {
  const dir = mkdtempSync(join(tmpdir(), 'mako-proof-'));
  cpSync(join(REPO, 'script'), join(dir, 'script'), { recursive: true });
  cpSync(join(REPO, 'test/fixtures/datastreams/pending'), join(dir, 'test/fixtures/datastreams/pending'), { recursive: true });
  writeFileSync(join(dir, 'script/providers.json'), JSON.stringify({ providers }));
  return dir;
}
const honestProviders = (over = {}) => [
  { id: 'mock-a', url: `http://${A.host}/`, host: A.host, operator: 'Mock Operator A', ...over.a },
  { id: 'mock-b', url: `http://${B.host}/`, host: B.host, operator: 'Mock Operator B', ...over.b },
];

const RUN_BUDGET_MS = 120_000;
async function runProbe({ providers = honestProviders(), args = [], env = {} } = {}) {
  const dir = tree(providers);
  const started = Date.now();
  try {
    const r = await new Promise((resolve) => {
      // A MINIMAL environment: only PATH, the provider SELECTION (ids), and what the case adds.
      const child = spawn(process.execPath, [join(dir, 'script/probe-archive.mjs'), ...args], {
        env: { PATH: process.env.PATH, MAKO_PROVIDER_A: 'mock-a', MAKO_PROVIDER_B: 'mock-b', ...env },
      });
      const kill = setTimeout(() => child.kill('SIGKILL'), RUN_BUDGET_MS);
      let out = '';
      child.stdout.on('data', (d) => (out += d));
      child.stderr.on('data', (d) => (out += d));
      child.on('close', (code) => { clearTimeout(kill); resolve({ code, out }); });
    });
    const evDir = join(dir, 'test/fixtures/datastreams/evidence');
    const runs = existsSync(evDir) ? readdirSync(evDir) : [];
    const text = runs.length && existsSync(join(evDir, runs[0], 'RESULT.json')) ? readFileSync(join(evDir, runs[0], 'RESULT.json'), 'utf8') : null;
    return { ...r, result: text ? JSON.parse(text) : null, ms: Date.now() - started };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const status = (r) => r.result?.status;
const unserved = (r, id, read) => r.result?.providers?.[id]?.identity?.unserved?.[read] || [];
const refused = (r, phrase) => r.code === 2 && r.out.includes(phrase) && A.requests === 0 && B.requests === 0;

const cases = [
  // ---- honest runs ----
  ['HONEST diagnostic: VERIFIED_MATCH, exit 0, the verify return recorded in full for both', {},
    (r) => r.code === 0 && status(r) === 'VERIFIED_MATCH' && r.result.providers['mock-a'].rawResult === VERIFY_RETURN
      && r.result.providers['mock-b'].rawResult === VERIFY_RETURN && r.result.providers['mock-a'].provider.url === `http://${A.host}/`],
  ['HONEST proof: two distinct operators, VERIFIED_MATCH as proof, exit 0', { args: ['--as-proof'] },
    (r) => r.code === 0 && status(r) === 'VERIFIED_MATCH' && r.result.proofLevel === 'two-distinct-operators' && r.out.includes('VERIFIED_MATCH as proof')],
  ['PROOF: one operator behind both providers is NOT_INDEPENDENT, exit 4',
    { args: ['--as-proof'], providers: honestProviders({ b: { operator: 'Mock Operator A' } }) },
    (r) => r.code === 4 && r.result.proofLevel === 'one-domain'],
  // ---- ENV: no URL is ever taken from the environment (Codex round 6) ----
  ['ENV: URLs in every variable the old probe read are ignored; the decoy gets no request',
    { args: ['--as-proof'], env: { MAKO_RPC_A: `http://${DECOY.host}/?apikey=secret`, MAKO_RPC_B: `http://${DECOY.host}/`, MAKO_RPC_ALCHEMY: `http://${DECOY.host}/v2/key`, MAKO_RPC_MOCK_A: `http://${DECOY.host}/`, MAKO_RPC_MOCK_B: `http://${DECOY.host}/` } },
    (r) => r.code === 0 && status(r) === 'VERIFIED_MATCH' && DECOY.requests === 0],
  // ---- answers that must not go green ----
  ['MISMATCH: providers returning different verify bytes', { modes: { b: 'different-verify' } },
    (r) => r.code === 3 && status(r) === 'VERIFICATION_MISMATCH' && r.result.bytesIdentical === false],
  ['MISMATCH: a malformed verify return is recorded by reason code, not bytes', { modes: { b: 'malformed-verify' } },
    (r) => r.code === 3 && status(r) === 'VERIFICATION_MISMATCH' && r.result.providers['mock-b'].decoded.reason === 'not-352-bytes'
      && !('rawResult' in r.result.providers['mock-b'])],
  // ---- hostile or broken providers are classified, in bounded time ----
  ['BOUND: a provider dripping one byte at a time is timed out and classified', { modes: { a: 'drip' }, env: { MAKO_PROBE_RPC_TIMEOUT_MS: '1500' } },
    (r) => r.code === 3 && status(r) === 'ARCHIVE_UNAVAILABLE' && unserved(r, 'mock-a', 'eth_chainId').every((x) => x.category === 'timeout') && r.ms < 60_000],
  ['OPERATOR: a provider redirecting its calls elsewhere is refused, not answered by the target', { modes: { a: 'redirect' } },
    (r) => r.code === 3 && status(r) === 'ARCHIVE_UNAVAILABLE'],
  ['DIAGNOSTICS: a provider rejecting every call is recorded as HTTP 401 per read', { modes: { a: 'unauthorized' } },
    (r) => r.code === 3 && Object.keys(r.result.providers['mock-a'].identity.unserved || {}).length === 6
      && Object.values(r.result.providers['mock-a'].identity.unserved).every((a) => a.every((x) => x.httpStatus === 401))],
  ['BOUND: a 12 MB eth_getCode result is refused as oversized', { modes: { a: 'huge-code' } },
    (r) => r.code === 3 && unserved(r, 'mock-a', 'eth_getCode').length > 0 && unserved(r, 'mock-a', 'eth_getCode').every((x) => x.category === 'oversized')],
  ['BOUND: a typeAndVersion of ~2 MB of NULs is classified in seconds', { modes: { a: 'nul-tv' } },
    (r) => r.code === 3 && r.result.providers['mock-a'].identity.ok.typeAndVersion === false && r.ms < 30_000],
  ['ROBUST: object-valued block hash and error message are classified, not a crash', { modes: { a: 'object-values' } },
    (r) => r.code === 3 && r.result !== null],
  // ---- provider records the probe must refuse before any request ----
  ...[
    ['a query string', `http://${'HOST'}/?apikey=secret`],
    ['a path', `http://${'HOST'}/v2/abcdefghij`],
    ['userinfo', `http://user:pass@${'HOST'}/`],
    ['a fragment', `http://${'HOST'}/#frag`],
    ['an upper-case scheme', `HTTP://${'HOST'}/`],
  ].map(([what, shape]) => [`CONFIG: a provider url with ${what} is refused before any request`,
    { providers: honestProviders({ a: { url: shape.replace('HOST', A.host) } }) },
    (r) => refused(r, 'url must be exactly')]),
  ['CONFIG: a plain-http url that is not loopback is refused',
    { providers: honestProviders({ a: { url: 'http://rpc.example.invalid/', host: 'rpc.example.invalid' } }) },
    (r) => refused(r, 'url must be https://')],
  ['CONFIG: a url whose host is not the recorded host is refused',
    { providers: honestProviders({ a: { host: 'rpc.example.invalid' } }) },
    (r) => refused(r, 'url must be exactly')],
  ['CONFIG: an unknown provider id is refused and not quoted back',
    { env: { MAKO_PROVIDER_A: 'https://pasted.example.invalid/v2/by-mistake' } },
    (r) => r.code === 2 && r.out.includes('not listed in providers.json') && !r.out.includes('pasted.example.invalid')
      && !JSON.stringify(r.result).includes('pasted.example.invalid')],
];

let bad = 0;
for (const [name, opts, check] of cases) {
  A.mode = opts.modes?.a || 'honest';
  B.mode = opts.modes?.b || 'honest';
  A.requests = B.requests = DECOY.requests = 0;
  const r = await runProbe(opts);
  const ok = !!check(r);
  if (!ok) bad++;
  console.log(`  [${ok ? ' ok ' : 'FAIL'}] ${name}`);
  console.log(`         exit ${r.code}, status ${status(r) ?? 'none'}, ${r.ms} ms, requests A=${A.requests} B=${B.requests} decoy=${DECOY.requests}`);
}

// The repository's own record: each fixed url is exactly https://<host>/, and the two operators differ.
{
  const real = JSON.parse(readFileSync(join(REPO, 'script/providers.json'), 'utf8')).providers;
  const shapeOk = real.length === 2 && real.every((p) => p.url === `https://${p.host}/`);
  const distinct = new Set(real.map((p) => p.operator)).size === 2;
  const ok = shapeOk && distinct;
  if (!ok) bad++;
  console.log(`  [${ok ? ' ok ' : 'FAIL'}] RECORD: providers.json holds two fixed https://<host>/ urls with distinct operators`);
}

for (const m of [A, B, DECOY]) m.server.close();
console.log(`\n  ${cases.length + 1 - bad} of ${cases.length + 1} cases behaved as required.`);
process.exit(bad ? 1 : 0);
