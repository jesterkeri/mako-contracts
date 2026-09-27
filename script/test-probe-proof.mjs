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
// Codex rounds 7 and 8: a proof run must START from a stripped environment, and the strip must happen before
// ANY interpreter starts, since each runs its own inherited hook first (BASH_ENV, NODE_OPTIONS). So the
// documented command begins with `env -i`, run by the operator's own interactive shell. The COMMAND cases
// spawn `env` exactly as that shell does, from a dirty environment holding a sentinel credential, a
// BASH_ENV hook that would leave a marker, and a report-enabling NODE_OPTIONS; they read the running Node
// process's real environment from /proc and send it the report signal. The PROOF-ENV case shows any other
// --as-proof run refuses, and the DOCS case pins the command text in the probe and VERIFICATION.md.
//
// It replaces test-probe-redaction.mjs and four other redaction tests, retired with the redaction they
// tested (in git history up to 56d307b). Codex diff review round 6's regression is the ENV case below: URLs
// placed in every environment variable the old probe read must receive no request at all.
//
// The TLS tests (test-probe-tls*.mjs) cover who can answer over https; this file covers everything else.

import { mkdtempSync, cpSync, rmSync, writeFileSync, readFileSync, readdirSync, existsSync } from 'node:fs';
const SENTINEL = 'SENTINELinheritedKEYzzzz9999';
// A dirty caller environment: an old credential, a BASH_ENV hook that would leave a marker if ANY Bash
// started from it ran, and NODE_OPTIONS that would make Node print a diagnostic report on SIGUSR2.
const HOOK_DIR = mkdtempSync(join(tmpdir(), 'mako-hook-'));
const HOOK_MARKER = join(HOOK_DIR, 'hook-ran');
writeFileSync(join(HOOK_DIR, 'hook.sh'), `printf '%s' "$MAKO_RPC_ALCHEMY" > '${HOOK_MARKER}'\n`);
const DIRTY = {
  MAKO_RPC_ALCHEMY: `https://example.invalid/v2/${SENTINEL}`, OTHER_SECRET: SENTINEL,
  BASH_ENV: join(HOOK_DIR, 'hook.sh'), NODE_OPTIONS: '--report-on-signal --report-filename=stdout',
};
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
      // 'slow' is honest with every answer 400 ms late, so a run lasts well past the 300 ms inspection point.
      const later = (f) => (m.mode === 'slow' ? setTimeout(f, 400) : f());
      const ok = (result) => later(() => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ jsonrpc: '2.0', id, result })); });
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
// The official ids, pointing at the mocks: the documented command passes no MAKO_PROVIDER_*, so the defaults apply.
const officialIds = () => honestProviders({ a: { id: 'monad-public' }, b: { id: 'monadinfra' } });
const honestProviders = (over = {}) => [
  { id: 'mock-a', url: `http://${A.host}/`, host: A.host, operator: 'Mock Operator A', ...over.a },
  { id: 'mock-b', url: `http://${B.host}/`, host: B.host, operator: 'Mock Operator B', ...over.b },
];

const RUN_BUDGET_MS = 120_000;
const PROOF_COMMAND = 'env -i PATH="$(dirname "$(command -v node)")" node script/probe-archive.mjs --as-proof';
const NODE_DIR = dirname(process.execPath);
async function runProbe({ providers = honestProviders(), args = [], env = {}, documented = false, during = null } = {}) {
  const dir = tree(providers);
  const started = Date.now();
  try {
    const r = await new Promise((resolve) => {
      // A MINIMAL environment: only PATH, the provider SELECTION (ids), and what the case adds. With
      // `documented`, the PROOF_COMMAND is run as the operator's shell runs it: `env -i PATH=<node dir> node
      // script/probe-archive.mjs --as-proof`, spawned from exactly the (dirty) environment given.
      const child = documented
        // stdin is /dev/null, NOT Node's default socket pipe: Bash skips BASH_ENV when stdin is a socket (it
        // assumes a remote shell), which would make a no-hook result vacuous. Measured 2026-09-27.
        ? spawn('env', ['-i', `PATH=${NODE_DIR}`, 'node', 'script/probe-archive.mjs', '--as-proof'], { cwd: dir, stdio: ['ignore', 'pipe', 'pipe'], env: { PATH: process.env.PATH, ...env } })
        : spawn(process.execPath, [join(dir, 'script/probe-archive.mjs'), ...args], {
          env: { PATH: process.env.PATH, MAKO_PROVIDER_A: 'mock-a', MAKO_PROVIDER_B: 'mock-b', ...env },
        });
      const kill = setTimeout(() => child.kill('SIGKILL'), RUN_BUDGET_MS);
      let out = '', seen = null;
      // `during` runs while the process is alive: `env` execs node, so this pid IS the Node process.
      if (during) setTimeout(() => { try { seen = during(child); } catch (e) { seen = { error: e.message }; } }, 300);
      child.stdout.on('data', (d) => (out += d));
      child.stderr.on('data', (d) => (out += d));
      child.on('close', (code, signal) => { clearTimeout(kill); resolve({ code, signal, out, seen }); });
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
  // ---- ENV: no URL is ever taken from the environment (Codex round 6); a diagnostic run, since a proof
  //      run refuses any such variable outright (next case) ----
  ['ENV: URLs in every variable the old probe read are ignored; the decoy gets no request',
    { env: { MAKO_RPC_A: `http://${DECOY.host}/?apikey=secret`, MAKO_RPC_B: `http://${DECOY.host}/`, MAKO_RPC_ALCHEMY: `http://${DECOY.host}/v2/key`, MAKO_RPC_MOCK_A: `http://${DECOY.host}/`, MAKO_RPC_MOCK_B: `http://${DECOY.host}/` } },
    (r) => r.code === 0 && status(r) === 'VERIFIED_MATCH' && DECOY.requests === 0],
  // ---- a proof run starts from a stripped environment (Codex round 7) ----
  ['PROOF-ENV: a direct --as-proof run from an environment holding an old credential variable refuses, naming it only',
    { args: ['--as-proof'], env: { MAKO_RPC_ALCHEMY: `https://example.invalid/v2/${SENTINEL}` } },
    (r) => r.code === 2 && r.out.includes('MAKO_RPC_ALCHEMY') && r.out.includes(PROOF_COMMAND) && !r.out.includes(SENTINEL)
      && r.result === null && A.requests === 0 && B.requests === 0],
  ['COMMAND: the documented command from a dirty shell: no hook runs, the live Node process holds ONLY PATH, the proof goes green',
    { documented: true, providers: officialIds(), modes: { a: 'slow', b: 'slow' }, env: DIRTY,
      during: (child) => readFileSync(`/proc/${child.pid}/environ`, 'latin1').split('\0').filter(Boolean) },
    (r) => Array.isArray(r.seen) && r.seen.length === 1 && r.seen[0].startsWith('PATH=') && !r.seen.join('\n').includes(SENTINEL)
      && !existsSync(HOOK_MARKER) && r.code === 0 && status(r) === 'VERIFIED_MATCH' && r.result.mode === 'proof' && !r.out.includes(SENTINEL)],
  ['COMMAND: the report signal to that process produces no report and no credential (NODE_OPTIONS never reaches Node)',
    { documented: true, providers: officialIds(), modes: { a: 'slow', b: 'slow' }, env: DIRTY,
      during: (child) => child.kill('SIGUSR2') },
    (r) => r.signal === 'SIGUSR2' && !r.out.includes(SENTINEL) && !r.out.includes('"header"') && !existsSync(HOOK_MARKER)],
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

// CONTROL for the COMMAND cases: a Bash started from the SAME dirty environment does run the BASH_ENV hook
// (and so would have read the credential), so the COMMAND case's "no hook ran" is a real result. This is the
// round-8 hazard that removed the Bash launcher.
{
  const { spawnSync } = await import('node:child_process');
  rmSync(HOOK_MARKER, { force: true });
  spawnSync('bash', ['-c', 'true'], { stdio: 'ignore', env: { PATH: process.env.PATH, ...DIRTY } });
  const ran = existsSync(HOOK_MARKER) && readFileSync(HOOK_MARKER, 'utf8').includes(SENTINEL);
  rmSync(HOOK_MARKER, { force: true });
  if (!ran) bad++;
  console.log(`  [${ran ? ' ok ' : 'FAIL'}] CONTROL: a Bash started from the dirty environment runs the BASH_ENV hook and reads the credential`);
}

// DOCS: the command the probe tells an operator to run, and the one VERIFICATION.md gives, are this exact one.
{
  const probe = readFileSync(join(REPO, 'script/probe-archive.mjs'), 'utf8');
  const record = readFileSync(join(REPO, 'test/fixtures/datastreams/VERIFICATION.md'), 'utf8');
  const ok = probe.includes(`const PROOF_COMMAND = '${PROOF_COMMAND}';`) && record.includes(PROOF_COMMAND) && !record.includes('bash script/run-proof.sh');
  if (!ok) bad++;
  console.log(`  [${ok ? ' ok ' : 'FAIL'}] DOCS: the probe and VERIFICATION.md give exactly the documented env -i command, and no Bash launcher`);
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
rmSync(HOOK_DIR, { recursive: true, force: true });
console.log(`\n  ${cases.length + 3 - bad} of ${cases.length + 3} cases behaved as required.`);
process.exit(bad ? 1 : 0);
