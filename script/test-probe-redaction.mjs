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
// No network. The working tree is never modified.

import { mkdtempSync, cpSync, rmSync, writeFileSync, readFileSync, readdirSync, existsSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const SENTINELS = ['SENTINELPATHKEYaaaa1111', 'SENTINELQUERYbbbb2222', 'SENTINELPATHKEYcccc3333', 'SENTINELQUERYdddd4444'];

// ---- a minimal JSON-RPC server answering the calls the probe makes ----
const WORD0 = '0x' + '00'.repeat(32);
const server = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const { id, method } = JSON.parse(body);
    const result = {
      eth_chainId: '0x279f',
      eth_getCode: '0x00',
      eth_call: WORD0 + '00'.repeat(32), // 64 zero bytes: identity will mismatch, which is fine here
      eth_getBlockByNumber: { number: '0x3c01d5b', hash: '0x' + '11'.repeat(32), timestamp: '0x6aaa0c48' },
    }[method];
    res.setHeader('content-type', 'application/json');
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
    const patched = src.replace('status,\n  proofLevel: level,', 'status,\n  leakedUrl: urlOf(A),\n  proofLevel: level,');
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

const leaks = (text) => (text ? SENTINELS.filter((s) => text.includes(s)) : []);
const urlA = `http://${HOST}/v2/${SENTINELS[0]}?apikey=${SENTINELS[1]}`;
const urlB = `http://${HOST}/v2/${SENTINELS[2]}?apikey=${SENTINELS[3]}`;

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
    name: 'LAST-LINE GUARD: with the original bug put back, the probe refuses to write (exit 5)',
    opts: { reintroduceBug: true },
    env: { MAKO_RPC_MOCK_A: urlA, MAKO_RPC_MOCK_B: urlB },
    check: (r) => r.code === 5 && r.resultText === null && leaks(r.out).length === 0,
  },
];

let bad = 0;
for (const sc of scenarios) {
  const dir = tree(sc.opts);
  try {
    const r = await runProbe(dir, sc.env);
    const ok = sc.check(r);
    if (!ok) bad++;
    console.log(`  [${ok ? ' ok ' : 'FAIL'}] ${sc.name}`);
    if (!ok) console.log(r.out.split('\n').filter((l) => /Error|error|at /.test(l)).slice(0, 6).map((l) => `         | ${l}`).join('\n'));
    console.log(`         exit ${r.code}, evidence ${r.resultText === null ? 'NOT written' : 'written'}, sentinel leaks: ` +
      `${leaks(r.resultText).length + leaks(r.out).length}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
server.close();

console.log(`\n  ${scenarios.length - bad} of ${scenarios.length} scenarios behaved as required.`);
if (bad) process.exit(1);
console.log('  No RPC URL path or query reaches evidence or console output, and the guard catches a regression.');
