// Redaction test for the archive probe: Node's own debug logging of fetch. Written by the tenth adversary
// pass against 10f8323, adopted into CI once the probe scrubbed stdout/stderr at the stream. The
// NODE_DEBUG_NATIVE case was added then: native output bypasses JavaScript, so the probe must refuse.
//
//   node script/test-probe-debuglog.mjs   about 20 seconds; no network, no openssl
//
// The probe scrubs every credential form from console.log and console.error, and from evidence. Node's
// bundled undici also logs every request, method and FULL URL included, when NODE_DEBUG names `fetch` or
// `undici` (or `*`). That logging goes through util.debuglog, which writes to process.stderr directly and
// never passes the patched console, so the credential in the configured URL reaches output verbatim.
// NODE_DEBUG is an ordinary environment setting, not code run inside the process.
//
// Same harness shape as test-probe-redaction.mjs: the REAL probe runs from a temp copy of the repo against
// an honest local JSON-RPC mock (loopback http, which the probe allows), with sentinel credentials in the
// path and the query. PASS means no 10-character window of any sentinel appears on stdout or stderr.
// The CONTROL runs the same providers without NODE_DEBUG and must reach VERIFIED_MATCH with no leak, which
// proves the mock is honest, the output is captured, and the leak check is not tripped by the harness.

import { mkdtempSync, cpSync, rmSync, writeFileSync, readFileSync, readdirSync, existsSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const SENTINELS = ['SENTINELDBGPATHaaaa1111', 'SENTINELDBGQUERYbbbb2222', 'SENTINELDBGPATHcccc3333', 'SENTINELDBGQUERYdddd4444'];

// ---- honest answers, from the repo's own vendored fixtures ----
const VERIFIER_CODE = readFileSync(join(REPO, 'test/fixtures/datastreams/verifier-runtime-62922075.hex'), 'utf8').trim();
const PINNED_B1 = JSON.parse(readFileSync(join(REPO, 'test/fixtures/datastreams/evidence/archive-probe-2026-09-24T21-28-43-466Z/RESULT.json'), 'utf8'));
const VERIFY_RETURN = PINNED_B1.providers['monad-public'].rawResult;
const ZERO_WORD = '0x' + '00'.repeat(32);
const word = (n) => n.toString(16).padStart(64, '0');
const TV_CANONICAL = '0x' + word(32) + word(19) + Buffer.from('VerifierProxy 2.0.0').toString('hex').padEnd(64, '0');

const server = createServer((req, res) => {
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
    if (data.startsWith('0x181f5a77')) return ok(TV_CANONICAL);
    if (data.startsWith('0xf7e83aee')) return ok(VERIFY_RETURN);
    ok(null);
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const HOST = `127.0.0.1:${server.address().port}`;

function tree(hostA = HOST, hostB = HOST) {
  const dir = mkdtempSync(join(tmpdir(), 'mako-adv10-'));
  cpSync(join(REPO, 'script'), join(dir, 'script'), { recursive: true });
  cpSync(join(REPO, 'test/fixtures/datastreams/pending'), join(dir, 'test/fixtures/datastreams/pending'), { recursive: true });
  writeFileSync(join(dir, 'script/providers.json'), JSON.stringify({
    providers: [
      { id: 'mock-a', host: hostA, urlEnv: 'MAKO_RPC_MOCK_A', operator: 'Mock Operator A', credentialed: true },
      { id: 'mock-b', host: hostB, urlEnv: 'MAKO_RPC_MOCK_B', operator: 'Mock Operator B', credentialed: true },
    ],
  }));
  return dir;
}

// The developer's own settings must not decide the outcome, NODE_DEBUG above all.
const SCRUB = ['NODE_DEBUG', 'NODE_DEBUG_NATIVE', 'NODE_OPTIONS', 'NODE_TLS_REJECT_UNAUTHORIZED', 'NODE_EXTRA_CA_CERTS', 'NODE_USE_ENV_PROXY',
  'NODE_USE_SYSTEM_CA', 'HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'NO_PROXY', 'no_proxy', 'SSL_CERT_FILE', 'SSL_CERT_DIR', 'OPENSSL_CONF'];
function baseEnv() { const b = { ...process.env }; for (const k of SCRUB) delete b[k]; return b; }

async function runProbe(env, hosts = []) {
  const dir = tree(...hosts);
  try {
    const r = await new Promise((resolve) => {
      const child = spawn('node', [join(dir, 'script/probe-archive.mjs')], { env: { ...baseEnv(), ...env } });
      const kill = setTimeout(() => child.kill('SIGKILL'), 120_000);
      let out = '';
      child.stdout.on('data', (d) => (out += d));
      child.stderr.on('data', (d) => (out += d));
      child.on('close', (status) => { clearTimeout(kill); resolve({ status, out }); });
    });
    const evDir = join(dir, 'test/fixtures/datastreams/evidence');
    const runs = existsSync(evDir) ? readdirSync(evDir) : [];
    const resultText = runs.length && existsSync(join(evDir, runs[0], 'RESULT.json')) ? readFileSync(join(evDir, runs[0], 'RESULT.json'), 'utf8') : null;
    return { code: r.status, out: r.out, result: resultText ? JSON.parse(resultText) : null, resultText };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// Any 10-character window of a sentinel, case-insensitively, in the output or the evidence.
const leaked = (r) => {
  const text = (r.out + (r.resultText || '')).toLowerCase();
  return SENTINELS.some((s) => { for (let i = 0; i + 10 <= s.length; i++) if (text.includes(s.slice(i, i + 10).toLowerCase())) return true; return false; });
};

const providers = {
  MAKO_PROVIDER_A: 'mock-a',
  MAKO_PROVIDER_B: 'mock-b',
  MAKO_RPC_MOCK_A: `http://${HOST}/v2/${SENTINELS[0]}?apikey=${SENTINELS[1]}`,
  MAKO_RPC_MOCK_B: `http://${HOST}/v2/${SENTINELS[2]}?apikey=${SENTINELS[3]}`,
  MAKO_PROBE_RPC_TIMEOUT_MS: '3000',
};

const scenarios = [
  { name: 'CONTROL: honest providers, no NODE_DEBUG: VERIFIED_MATCH, nothing leaked', control: true, env: {} },
  { name: 'NODE_DEBUG=fetch', env: { NODE_DEBUG: 'fetch' } },
  { name: 'NODE_DEBUG=undici', env: { NODE_DEBUG: 'undici' } },
  { name: 'NODE_DEBUG=*', env: { NODE_DEBUG: '*' } },
  // The production shape: https, hosts under .invalid so nothing leaves the machine. The request never
  // connects (the name does not resolve), and the URL is logged anyway, before and after the failure.
  {
    name: 'NODE_DEBUG=fetch, https providers (unresolvable .invalid hosts, no network)',
    hosts: ['rpc-a.example.invalid', 'rpc-b.example.invalid'],
    env: {
      NODE_DEBUG: 'fetch',
      MAKO_RPC_MOCK_A: `https://rpc-a.example.invalid/v2/${SENTINELS[0]}?apikey=${SENTINELS[1]}`,
      MAKO_RPC_MOCK_B: `https://rpc-b.example.invalid/v2/${SENTINELS[2]}?apikey=${SENTINELS[3]}`,
    },
  },
  { name: 'NODE_DEBUG_NATIVE=* is refused before any call (native output cannot be scrubbed)', refuse: true, env: { NODE_DEBUG_NATIVE: '*' } },
];

let bad = 0;
for (const sc of scenarios) {
  const r = await runProbe({ ...providers, ...sc.env }, sc.hosts);
  const leak = leaked(r);
  const ok = sc.control
    ? r.code === 0 && r.result?.status === 'VERIFIED_MATCH' && r.out.includes('T0.1 archive probe') && !leak
    : sc.refuse ? r.code === 2 && r.out.includes('NODE_DEBUG_NATIVE is set') && !leak
    : !leak;
  if (!ok) bad++;
  console.log(`  [${ok ? ' ok ' : 'FAIL'}] ${sc.name}`);
  console.log(`         exit ${r.code}, status ${r.result?.status ?? 'none'}, leaked ${leak}`);
  if (leak) {
    // Show where, with the sentinel itself masked so this log is not a second copy of the pattern.
    const line = r.out.split('\n').find((l) => SENTINELS.some((s) => l.includes(s.slice(0, 10))));
    if (line) console.log(`         first leaking line: ${SENTINELS.reduce((l, s) => l.split(s).join('<SENTINEL>'), line).slice(0, 160)}`);
  }
}
server.close();
console.log(`\n  ${scenarios.length - bad} of ${scenarios.length} scenarios behaved as required.`);
process.exit(bad ? 1 : 0);
