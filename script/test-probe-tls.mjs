// Operator-authentication and ABI-strictness tests for the archive probe. Written by the sixth adversary
// pass (against 0fb84df), adopted into the repository and CI with one added case (--use-openssl-ca).
//
//   node script/test-probe-tls.mjs          needs `openssl` on PATH; about a minute
//
// Same pattern as test-probe-redaction.mjs: the REAL probe runs from a temp copy of the repo against local
// mock servers, with sentinel credentials. No network, no real credentials, the working tree is not modified.
//
// OPERATOR cases. The probe's contract: calls are answered only by the configured endpoint over an
// authenticated channel, and no environment variable may let a different server answer while the evidence
// names the configured operator. The probe refuses plain HTTP because "over HTTPS a proxy only tunnels, and
// the endpoint's certificate authenticates who answered". Here a local CONNECT proxy (standing in for any
// proxy or on-path attacker) sends every tunnel to a local TLS server whose certificate no operator issued.
// With NODE_TLS_REJECT_UNAUTHORIZED=0, or NODE_EXTRA_CA_CERTS naming the issuing test CA, in the environment,
// the certificate no longer authenticates the operator and that server answers for both configured operators.
//
// ABI cases. `typeAndVersion` must be accepted only as a real contract ABI-encodes the pinned string: head
// offset 32, length 19, the 19 bytes, then ZERO padding to a 32-byte boundary, 96 bytes in all.

import { mkdtempSync, cpSync, rmSync, writeFileSync, readFileSync, readdirSync, existsSync } from 'node:fs';
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { createServer as createTlsServer } from 'node:https';
import { connect } from 'node:net';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const SENTINEL_A = 'SENTINELADVAKEYaaaa1111';
const SENTINEL_B = 'SENTINELADVBKEYbbbb2222';

// ---- honest answers, from the repo's own vendored fixtures ----
const VERIFIER_CODE = readFileSync(join(REPO, 'test/fixtures/datastreams/verifier-runtime-62922075.hex'), 'utf8').trim();
if (createHash('sha256').update(Buffer.from(VERIFIER_CODE.slice(2), 'hex')).digest('hex') !== '246be742ffcc522f72309f1f42c77817af4d6f823969ce9e5763f2a9327ca231') {
  throw new Error('vendored verifier code does not match the pinned sha256');
}
const PINNED_B1 = JSON.parse(readFileSync(join(REPO, 'test/fixtures/datastreams/evidence/archive-probe-2026-09-24T21-28-43-466Z/RESULT.json'), 'utf8'));
const VERIFY_RETURN = PINNED_B1.providers['monad-public'].rawResult;
const ZERO_WORD = '0x' + '00'.repeat(32);
const word = (n) => n.toString(16).padStart(64, '0');
const TV = Buffer.from('VerifierProxy 2.0.0').toString('hex'); // 19 bytes
// What a real contract returns: offset, length, the bytes, zero padding. 96 bytes.
const TV_CANONICAL = '0x' + word(32) + word(19) + TV.padEnd(64, '0');

let TV_RESULT = TV_CANONICAL;
function honest(req, res) {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const { id, method, params } = JSON.parse(body);
    const data = String(params?.[0]?.data || '');
    const ok = (result) => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ jsonrpc: '2.0', id, result })); };
    if (method === 'eth_chainId') return ok('0x279f');
    if (method === 'eth_getCode') return ok(VERIFIER_CODE);
    if (method === 'eth_getBlockByNumber') return ok({ number: '0x3c01d5b', hash: '0x73f54743b7db644c8f010e74f422107337b586b59fed5a91916f98b384a722d6', timestamp: '0x6aaa0c48' });
    if (data.startsWith('0x38416b5b') || data.startsWith('0x94ba2846')) return ok(ZERO_WORD);
    if (data.startsWith('0x181f5a77')) return ok(TV_RESULT);
    if (data.startsWith('0xf7e83aee')) return ok(VERIFY_RETURN);
    ok(null);
  });
}

// ---- a TLS server with a certificate nobody trusts, and a CONNECT proxy that sends every tunnel to it ----
// A throwaway test CA, generated per run and deleted after, signs a leaf for both configured hosts. No
// system trusts it; it is trusted only when an environment variable says so.
const certDir = mkdtempSync(join(tmpdir(), 'mako-adv-cert-'));
const c = (f) => join(certDir, f);
const ossl = (...a) => execFileSync('openssl', a, { stdio: 'ignore' });
ossl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-keyout', c('ca.key'), '-out', c('ca.pem'),
  '-subj', '/CN=Impostor Test CA', '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign');
ossl('req', '-newkey', 'rsa:2048', '-nodes', '-keyout', c('leaf.key'), '-out', c('leaf.csr'), '-subj', '/CN=rpc-a.example.invalid');
writeFileSync(c('ext.cnf'), 'subjectAltName=DNS:rpc-a.example.invalid,DNS:rpc-b.example.invalid\n');
ossl('x509', '-req', '-in', c('leaf.csr'), '-CA', c('ca.pem'), '-CAkey', c('ca.key'), '-CAcreateserial', '-days', '1', '-out', c('leaf.pem'), '-extfile', c('ext.cnf'));
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

// ---- a plain loopback server for the ABI cases ----
const local = createServer(honest);
await new Promise((r) => local.listen(0, '127.0.0.1', r));
const HOST = `127.0.0.1:${local.address().port}`;

function tree() {
  const dir = mkdtempSync(join(tmpdir(), 'mako-adv-'));
  cpSync(join(REPO, 'script'), join(dir, 'script'), { recursive: true });
  cpSync(join(REPO, 'test/fixtures/datastreams/pending'), join(dir, 'test/fixtures/datastreams/pending'), { recursive: true });
  // .invalid hosts can never resolve, so nothing here can reach a real provider.
  writeFileSync(join(dir, 'script/providers.json'), JSON.stringify({
    providers: [
      { id: 'remote-a', host: 'rpc-a.example.invalid', urlEnv: 'MAKO_RPC_REMOTE_A', operator: 'Remote Operator A', credentialed: true },
      { id: 'remote-b', host: 'rpc-b.example.invalid', urlEnv: 'MAKO_RPC_REMOTE_B', operator: 'Remote Operator B', credentialed: true },
      { id: 'mock-a', host: HOST, urlEnv: 'MAKO_RPC_MOCK_A', operator: 'Mock Operator A', credentialed: true },
      { id: 'mock-b', host: HOST, urlEnv: 'MAKO_RPC_MOCK_B', operator: 'Mock Operator B', credentialed: true },
    ],
  }));
  return dir;
}

const RUN_BUDGET_MS = 180_000;
async function runProbe(env) {
  const dir = tree();
  try {
    const base = { ...process.env };
    for (const k of ['NODE_TLS_REJECT_UNAUTHORIZED', 'NODE_EXTRA_CA_CERTS', 'NODE_USE_ENV_PROXY', 'HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'NO_PROXY', 'no_proxy', 'NODE_OPTIONS', 'SSL_CERT_FILE', 'SSL_CERT_DIR', 'NODE_USE_SYSTEM_CA', 'OPENSSL_CONF']) delete base[k];
    const r = await new Promise((resolve) => {
      const child = spawn('node', [join(dir, 'script/probe-archive.mjs')], { env: { ...base, ...env } });
      const kill = setTimeout(() => child.kill('SIGKILL'), RUN_BUDGET_MS);
      let out = '';
      child.stdout.on('data', (d) => (out += d));
      child.stderr.on('data', (d) => (out += d));
      child.on('close', (status) => { clearTimeout(kill); resolve({ status, out }); });
    });
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
const mocks = {
  MAKO_PROVIDER_A: 'mock-a',
  MAKO_PROVIDER_B: 'mock-b',
  MAKO_RPC_MOCK_A: `http://${HOST}/v2/${SENTINEL_A}`,
  MAKO_RPC_MOCK_B: `http://${HOST}/v2/${SENTINEL_B}`,
};
const green = (r) => r.code === 0 && r.result?.status === 'VERIFIED_MATCH';
// Refused BECAUSE of the weakened TLS setting, not merely "not green" for some other reason.
const refusedForTls = (r) => r.code === 2 && r.out.includes('TLS certificate checking is weakened') && !r.leaked;

const scenarios = [
  {
    // Harness check: the proxy IS used, and with certificate checks on it cannot answer.
    name: 'CONTROL: through an intercepting proxy with TLS verification on, the impostor cannot answer',
    env: remote,
    check: (r, t) => t.length > 0 && !green(r) && !r.leaked,
  },
  {
    name: 'OPERATOR: NODE_TLS_REJECT_UNAUTHORIZED=0 must not let a server with an untrusted certificate answer for both operators',
    env: { ...remote, NODE_TLS_REJECT_UNAUTHORIZED: '0' },
    check: (r) => !green(r) && refusedForTls(r),
  },
  {
    name: 'OPERATOR: NODE_EXTRA_CA_CERTS naming an extra CA must not let a server that CA vouches for answer for both operators',
    env: { ...remote, NODE_EXTRA_CA_CERTS: c('ca.pem') },
    check: (r) => !green(r) && refusedForTls(r),
  },
  {
    name: 'OPERATOR: --use-openssl-ca with SSL_CERT_FILE naming an extra CA must not let that CA\'s server answer',
    env: { ...remote, NODE_OPTIONS: '--use-openssl-ca', SSL_CERT_FILE: c('ca.pem') },
    check: (r) => !green(r) && refusedForTls(r),
  },
  {
    // Harness check: the canonical 96-byte encoding goes green, so the next cases isolate the encoding alone.
    name: 'CONTROL: typeAndVersion as a real contract encodes it gives VERIFIED_MATCH',
    tv: TV_CANONICAL,
    env: mocks,
    check: (r) => green(r) && r.result.providers['mock-a'].identity.ok.typeAndVersion === true && !r.leaked,
  },
  {
    name: 'ABI: typeAndVersion with NON-ZERO padding after the 19 bytes (no contract returns this) is not accepted',
    tv: '0x' + word(32) + word(19) + TV + 'ff'.repeat(13),
    env: mocks,
    check: (r) => !green(r) && r.result?.providers['mock-a'].identity.ok?.typeAndVersion !== true,
  },
  {
    name: 'ABI: typeAndVersion followed by an extra trailing word (no contract returns this) is not accepted',
    tv: '0x' + word(32) + word(19) + TV + '00'.repeat(13) + word(0xdead),
    env: mocks,
    check: (r) => !green(r) && r.result?.providers['mock-a'].identity.ok?.typeAndVersion !== true,
  },
];

let bad = 0;
for (const sc of scenarios) {
  TV_RESULT = sc.tv || TV_CANONICAL;
  tunnels.length = 0;
  const r = await runProbe(sc.env);
  const ok = sc.check(r, tunnels);
  if (!ok) bad++;
  console.log(`  [${ok ? ' ok ' : 'FAIL'}] ${sc.name}`);
  console.log(`         exit ${r.code}, status ${r.result?.status ?? 'none'}, proofLevel ${r.result?.proofLevel ?? 'none'}, ` +
    `operators ${r.result ? Object.values(r.result.providers || {}).map((p) => p.provider?.operator).join(' + ') : 'none'}, ` +
    `tunnels ${tunnels.length}, leaked ${r.leaked}`);
}
impostor.close(); proxy.close(); local.close();
rmSync(certDir, { recursive: true, force: true });
console.log(`\n  ${scenarios.length - bad} of ${scenarios.length} scenarios behaved as required.`);
process.exit(bad ? 1 : 0);
