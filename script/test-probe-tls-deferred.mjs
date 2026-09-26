// Operator-authentication test for the archive probe: a trust-store change made AFTER tlsWeakening() ran.
// Written by the eighth adversary pass against 7f679ce and adopted into CI once the probe re-checked trust
// before every request. The SWAP case was added then: a store with the bundled COUNT but one certificate
// replaced by the test CA, so a check weakened to compare counts only would fail this test.
//
//   node script/test-probe-tls-deferred.mjs   needs `openssl` on PATH; about 20 seconds
//
// Same harness as test-probe-tls-bypass.mjs: the REAL probe runs from a temp copy of the repo against a local
// CONNECT proxy that sends every tunnel to a local TLS server whose certificate only a throwaway test CA
// vouches for. Sentinel credentials, hosts under .invalid, no network, the working tree is not modified.
//
// tlsWeakening() compares tls.getCACertificates('default') with 'bundled' ONCE, synchronously, when each
// provider is resolved at module top level. Node reads the default trust store again for every new TLS
// connection, and the probe retries transport errors (0, 0.5, 1.5, 3.5, 7.5 s). A preload whose only effect
// is tls.setDefaultCACertificates() (the case the probe documents as caught "because it changes the trust
// store"), run one second later instead of at load time, is invisible to the check and trusted by every
// later connection. The spec's preload exclusion does not cover it: "except where it merely changes the
// trust store".
//
// PASS means the impostor answered nothing and the run is not VERIFIED_MATCH, as in the bypass test. The
// PRECONDITION line proves, outside the probe, both that the store equals the bundled set when checked at
// load time and that the same preload makes Node trust the test CA one second later.

import { mkdtempSync, cpSync, rmSync, writeFileSync, readFileSync, readdirSync, existsSync } from 'node:fs';
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { createServer as createTlsServer } from 'node:https';
import { connect } from 'node:net';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const SENTINEL_A = 'SENTINELADVAKEYaaaa1111';
const SENTINEL_B = 'SENTINELADVBKEYbbbb2222';

// ---- honest answers, from the repo's own vendored fixtures ----
const VERIFIER_CODE = readFileSync(join(REPO, 'test/fixtures/datastreams/verifier-runtime-62922075.hex'), 'utf8').trim();
const PINNED_B1 = JSON.parse(readFileSync(join(REPO, 'test/fixtures/datastreams/evidence/archive-probe-2026-09-24T21-28-43-466Z/RESULT.json'), 'utf8'));
const VERIFY_RETURN = PINNED_B1.providers['monad-public'].rawResult;
const ZERO_WORD = '0x' + '00'.repeat(32);
const word = (n) => n.toString(16).padStart(64, '0');
const TV_CANONICAL = '0x' + word(32) + word(19) + Buffer.from('VerifierProxy 2.0.0').toString('hex').padEnd(64, '0');

let impostorAnswers = 0;
function honest(req, res) {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    impostorAnswers++;
    let parsed; try { parsed = JSON.parse(body); } catch { res.end('impostor'); return; }
    const { id, method, params } = parsed;
    const data = String(params?.[0]?.data || '');
    const ok = (result) => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ jsonrpc: '2.0', id, result })); };
    if (method === 'eth_chainId') return ok('0x279f');
    if (method === 'eth_getCode') return ok(VERIFIER_CODE);
    if (method === 'eth_getBlockByNumber') return ok({ number: '0x3c01d5b', hash: '0x73f54743b7db644c8f010e74f422107337b586b59fed5a91916f98b384a722d6', timestamp: '0x6aaa0c48' });
    if (data.startsWith('0x38416b5b') || data.startsWith('0x94ba2846')) return ok(ZERO_WORD);
    if (data.startsWith('0x181f5a77')) return ok(TV_CANONICAL);
    if (data.startsWith('0xf7e83aee')) return ok(VERIFY_RETURN);
    ok(null);
  });
}

// ---- throwaway CA, impostor TLS server, CONNECT proxy ----
const certDir = mkdtempSync(join(tmpdir(), 'mako-adv8-cert-'));
const c = (f) => join(certDir, f);
const ossl = (...a) => execFileSync('openssl', a, { stdio: 'ignore' });
ossl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-keyout', c('ca.key'), '-out', c('ca.pem'),
  '-subj', '/CN=Impostor Test CA', '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign');
ossl('req', '-newkey', 'rsa:2048', '-nodes', '-keyout', c('leaf.key'), '-out', c('leaf.csr'), '-subj', '/CN=rpc-a.example.invalid');
writeFileSync(c('ext.cnf'), 'subjectAltName=DNS:rpc-a.example.invalid,DNS:rpc-b.example.invalid\n');
ossl('x509', '-req', '-in', c('leaf.csr'), '-CA', c('ca.pem'), '-CAkey', c('ca.key'), '-CAcreateserial', '-days', '1', '-out', c('leaf.pem'), '-extfile', c('ext.cnf'));
// The preload does one thing: add the test CA to the default trust store, one second after start.
const DELAY_MS = 1000;
const widen = `const tls = require('node:tls');` +
  `setTimeout(() => tls.setDefaultCACertificates([...tls.getCACertificates('bundled'), require('node:fs').readFileSync(${JSON.stringify(c('ca.pem'))}, 'utf8')]), ${DELAY_MS}).unref();\n`;
writeFileSync(c('late.cjs'), widen);
// Same size as the bundled set, one certificate swapped for the test CA, applied at load time.
writeFileSync(c('swap.cjs'), `const tls = require('node:tls');` +
  `tls.setDefaultCACertificates([...tls.getCACertificates('bundled').slice(1), require('node:fs').readFileSync(${JSON.stringify(c('ca.pem'))}, 'utf8')]);\n`);
writeFileSync(c('late.mjs'), widen.replace(`const tls = require('node:tls');`, `import tls from 'node:tls'; import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);`));

const impostor = createTlsServer({ key: readFileSync(c('leaf.key')), cert: readFileSync(c('leaf.pem')) }, honest);
await new Promise((r) => impostor.listen(0, '127.0.0.1', r));
const tunnels = [];
const proxy = createServer((req, res) => { res.writeHead(405); res.end(); });
proxy.on('connect', (req, client, head) => {
  tunnels.push(req.url);
  const up = connect(impostor.address().port, '127.0.0.1', () => {
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (head?.length) up.write(head);
    up.pipe(client); client.pipe(up);
  });
  up.on('error', () => client.destroy());
  client.on('error', () => up.destroy());
});
await new Promise((r) => proxy.listen(0, '127.0.0.1', r));
const PROXY = `http://127.0.0.1:${proxy.address().port}`;

function tree() {
  const dir = mkdtempSync(join(tmpdir(), 'mako-adv8-'));
  cpSync(join(REPO, 'script'), join(dir, 'script'), { recursive: true });
  cpSync(join(REPO, 'test/fixtures/datastreams/pending'), join(dir, 'test/fixtures/datastreams/pending'), { recursive: true });
  writeFileSync(join(dir, 'script/providers.json'), JSON.stringify({
    providers: [
      { id: 'remote-a', host: 'rpc-a.example.invalid', urlEnv: 'MAKO_RPC_REMOTE_A', operator: 'Remote Operator A', credentialed: true },
      { id: 'remote-b', host: 'rpc-b.example.invalid', urlEnv: 'MAKO_RPC_REMOTE_B', operator: 'Remote Operator B', credentialed: true },
    ],
  }));
  return dir;
}

const SCRUB = ['NODE_TLS_REJECT_UNAUTHORIZED', 'NODE_EXTRA_CA_CERTS', 'NODE_USE_ENV_PROXY', 'NODE_USE_SYSTEM_CA', 'HTTP_PROXY', 'HTTPS_PROXY',
  'http_proxy', 'https_proxy', 'NO_PROXY', 'no_proxy', 'NODE_OPTIONS', 'SSL_CERT_FILE', 'SSL_CERT_DIR', 'OPENSSL_CONF'];
function baseEnv() { const b = { ...process.env }; for (const k of SCRUB) delete b[k]; return b; }

function run(args, env, cwd) {
  return new Promise((resolve) => {
    const child = spawn('node', args, { env, cwd });
    const kill = setTimeout(() => child.kill('SIGKILL'), 120_000);
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (out += d));
    child.on('close', (status) => { clearTimeout(kill); resolve({ status, out }); });
  });
}

// Outside the probe: at load time the store IS the bundled set (so tlsWeakening() sees nothing), and after
// the delay the same process trusts the impostor. Direct https, no proxy.
async function precondition(nodeArgs, env) {
  const script = `import dns from 'node:dns'; import tls from 'node:tls';` +
    `const d = tls.getCACertificates('default'), b = new Set(tls.getCACertificates('bundled'));` +
    `console.log('LOADTIME_EQUAL=' + (d.length === b.size && d.every((x) => b.has(x))));` +
    `console.log('COUNT_EQUAL=' + (d.length === b.size));` +
    `const l = dns.lookup; dns.lookup = (h, o, cb) => l('127.0.0.1', o, cb);` +
    `await new Promise((r) => setTimeout(r, ${DELAY_MS + 500}));` +
    `await fetch('https://rpc-a.example.invalid:${impostor.address().port}/', { method: 'POST', body: '{}' })` +
    `.then(() => console.log('TRUSTED'), (e) => console.log('REFUSED ' + (e.cause?.code || e.message)));`;
  const before = impostorAnswers;
  const r = await run([...nodeArgs, '--input-type=module', '-e', script], { ...baseEnv(), ...env }, certDir);
  impostorAnswers = before;
  return { loadTimeEqual: r.out.includes('LOADTIME_EQUAL=true'), countEqual: r.out.includes('COUNT_EQUAL=true'), trustedLater: r.out.includes('TRUSTED') };
}

async function runProbe(nodeArgs, env) {
  const dir = tree();
  try {
    const r = await run([...nodeArgs, join(dir, 'script/probe-archive.mjs')], { ...baseEnv(), ...env }, certDir);
    const evDir = join(dir, 'test/fixtures/datastreams/evidence');
    const runs = existsSync(evDir) ? readdirSync(evDir) : [];
    const resultText = runs.length && existsSync(join(evDir, runs[0], 'RESULT.json')) ? readFileSync(join(evDir, runs[0], 'RESULT.json'), 'utf8') : null;
    const result = resultText ? JSON.parse(resultText) : null;
    const leaked = [SENTINEL_A, SENTINEL_B].some((s) => (resultText || '').includes(s.slice(0, 10)) || r.out.includes(s.slice(0, 10)));
    return { code: r.status, out: r.out, result, leaked };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const remote = {
  MAKO_PROVIDER_A: 'remote-a',
  MAKO_PROVIDER_B: 'remote-b',
  MAKO_RPC_REMOTE_A: `https://rpc-a.example.invalid/v2/${SENTINEL_A}`,
  MAKO_RPC_REMOTE_B: `https://rpc-b.example.invalid/v2/${SENTINEL_B}`,
  HTTPS_PROXY: PROXY,
  NODE_USE_ENV_PROXY: '1',
  MAKO_PROBE_RPC_TIMEOUT_MS: '3000',
};
const green = (r) => r.code === 0 && r.result?.status === 'VERIFIED_MATCH';

const scenarios = [
  { name: 'CONTROL: intercepting proxy, normal TLS settings: tunnels opened, impostor answers nothing', control: true, args: [], env: {} },
  { name: `NODE_OPTIONS=--require=<preload calling tls.setDefaultCACertificates after ${DELAY_MS} ms>`, args: [], env: { NODE_OPTIONS: `--require=${c('late.cjs')}` } },
  { name: `node --import=<preload calling tls.setDefaultCACertificates after ${DELAY_MS} ms>`, args: [`--import=${c('late.mjs')}`], env: {} },
  { name: 'SWAP: a store of the bundled SIZE with one certificate replaced by the test CA', swap: true, args: [], env: { NODE_OPTIONS: `--require=${c('swap.cjs')}` } },
];

let bad = 0;
for (const sc of scenarios) {
  const pre = sc.control ? null : await precondition(sc.args, sc.env);
  tunnels.length = 0;
  impostorAnswers = 0;
  const r = await runProbe(sc.args, { ...remote, ...sc.env });
  const ok = sc.control
    ? tunnels.length > 0 && impostorAnswers === 0 && !green(r) && !r.leaked
    : sc.swap
      ? pre.countEqual && !pre.loadTimeEqual && pre.trustedLater && impostorAnswers === 0 && !green(r) && !r.leaked
      : pre.loadTimeEqual && pre.trustedLater && impostorAnswers === 0 && !green(r) && !r.leaked;
  if (!ok) bad++;
  console.log(`  [${ok ? ' ok ' : 'FAIL'}] ${sc.name}`);
  if (!sc.control) console.log(`         PRECONDITION store equals bundled at load time: ${pre.loadTimeEqual}; same count: ${pre.countEqual}; Node trusts the test CA: ${pre.trustedLater}`);
  console.log(`         exit ${r.code}, status ${r.result?.status ?? 'none'}, proofLevel ${r.result?.proofLevel ?? 'none'}, ` +
    `operators ${r.result ? Object.values(r.result.providers || {}).map((p) => p.provider?.operator).join(' + ') : 'none'}, ` +
    `tunnels ${tunnels.length}, impostor answers ${impostorAnswers}, leaked ${r.leaked}`);
}
impostor.close(); proxy.close();
rmSync(certDir, { recursive: true, force: true });
console.log(`\n  ${scenarios.length - bad} of ${scenarios.length} scenarios behaved as required.`);
process.exit(bad ? 1 : 0);
