// Contract test for the archive probe's rewritten scrubber, stream wrapper and environment deletion.
// Written by the twelfth adversary pass, against b6091a5.
//
//   node script/test-probe-wrapper-edges.mjs [repo]   about 20 seconds; no network, no openssl
//
// `repo` defaults to this checkout; pass another checkout (e.g. a worktree at 86e60a2) to compare.
//
// Same harness shape as test-probe-native-output.mjs: the REAL probe runs from a temp copy of the repo
// against an honest local JSON-RPC mock (loopback http), with sentinel credentials in the URLs, and a
// MINIMAL child environment. Where a case needs a write the probe itself never makes, a tiny --import
// module registers it on process 'exit' (or on a timer), after the probe has installed its wrapper, exactly
// as test-probe-stream-wrapper.mjs does. The cases:
//
//   1. Deleting MAKO_RPC_* after the first read. The same provider selected for A and B (a diagnostic
//      determinism run against one endpoint) is resolved twice; the second read finds the variable gone,
//      so the run stops with "environment variable ... is not set" and records ARCHIVE_UNAVAILABLE (exit 2),
//      where 86e60a2 resolves both and a diagnostic run reaches VERIFIED_MATCH at proofLevel one-domain.
//   2. A credential split across two writes at the 64 KiB flush. A write that takes the pending buffer past
//      64 KiB is flushed whole, so a credential whose first half ends that write and whose second half
//      starts the next is scrubbed as two pieces, each shorter than the 10-byte window.
//   (Adopted into CI at the fix for this pass; case 3 then also accepts the probe REFUSING a non-ASCII
//   credential before any call, which is the fix taken.)
//   3. Case-insensitivity for a non-ASCII credential. The replaced regex had the `i` flag, which folds case
//      for Cyrillic, Greek and accented Latin; the byte search folds only A-Z. A Cyrillic credential
//      echoed in the other case was redacted by 86e60a2 and is printed by b6091a5.
//   4. Bytes held without a newline are lost when the process dies by a signal (a CI job cancel sends
//      SIGTERM): the flush runs on 'exit' only, which a default signal death never emits. An unwrapped
//      stream wrote them at once.

import { mkdtempSync, cpSync, rmSync, writeFileSync, readFileSync, readdirSync, existsSync, openSync, closeSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { join, dirname, resolve as resolvePath } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const REPO = process.argv[2] ? resolvePath(process.argv[2]) : join(dirname(fileURLToPath(import.meta.url)), '..');
// The fixtures are read from THIS checkout, so an older checkout under test needs only its script/.
const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), '..');
const S = { pathA: 'SENTINELEDGPATHaaaa1111', queryA: 'SENTINELEDGQUERYbbbb2222', queryB: 'SENTINELEDGQUERYdddd4444' };
const SPLIT = 'SPLITSECRET18chars'; // 18 characters: two 9-character halves, each below the 10-byte window
const CYR = 'ключсекретныйдлинный'; // 20 Cyrillic characters, a path segment of provider A in case 3

// ---- honest answers, from the repo's own vendored fixtures ----
const VERIFIER_CODE = readFileSync(join(FIXTURES, 'test/fixtures/datastreams/verifier-runtime-62922075.hex'), 'utf8').trim();
const PINNED_B1 = JSON.parse(readFileSync(join(FIXTURES, 'test/fixtures/datastreams/evidence/archive-probe-2026-09-24T21-28-43-466Z/RESULT.json'), 'utf8'));
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

function tree() {
  const dir = mkdtempSync(join(tmpdir(), 'mako-adv12-'));
  cpSync(join(REPO, 'script'), join(dir, 'script'), { recursive: true });
  cpSync(join(FIXTURES, 'test/fixtures/datastreams/pending'), join(dir, 'test/fixtures/datastreams/pending'), { recursive: true });
  writeFileSync(join(dir, 'script/providers.json'), JSON.stringify({
    providers: [
      { id: 'mock-a', host: HOST, urlEnv: 'MAKO_RPC_MOCK_A', operator: 'Mock Operator A', credentialed: true },
      { id: 'mock-b', host: HOST, urlEnv: 'MAKO_RPC_MOCK_B', operator: 'Mock Operator B', credentialed: true },
    ],
  }));
  return dir;
}

const baseEnv = (a) => ({
  MAKO_PROVIDER_A: 'mock-a',
  MAKO_PROVIDER_B: 'mock-b',
  MAKO_RPC_MOCK_A: `http://${HOST}/v2/${a}?apikey=${S.queryA}`,
  MAKO_RPC_MOCK_B: `http://${HOST}/v2/${SPLIT}?apikey=${S.queryB}`,
  MAKO_PROBE_RPC_TIMEOUT_MS: '5000',
});

async function runProbe({ env = {}, writer = null, pathA = S.pathA, nodeArgs = [] }) {
  const dir = tree();
  try {
    const args = [...nodeArgs];
    if (writer) { writeFileSync(join(dir, 'writer.mjs'), writer); args.push('--import', pathToFileURL(join(dir, 'writer.mjs')).href); }
    const logPath = join(dir, 'output.log');
    const fd = openSync(logPath, 'w');
    const r = await new Promise((resolve) => {
      const child = spawn(process.execPath, [...args, join(dir, 'script/probe-archive.mjs')], {
        env: { PATH: process.env.PATH, ...baseEnv(pathA), ...env }, stdio: ['ignore', fd, fd],
      });
      const kill = setTimeout(() => child.kill('SIGKILL'), 90_000);
      child.on('close', (status, signal) => { clearTimeout(kill); resolve({ status, signal }); });
    });
    closeSync(fd);
    const out = readFileSync(logPath);
    const evDir = join(dir, 'test/fixtures/datastreams/evidence');
    const runs = existsSync(evDir) ? readdirSync(evDir) : [];
    const resultText = runs.length && existsSync(join(evDir, runs[0], 'RESULT.json')) ? readFileSync(join(evDir, runs[0], 'RESULT.json'), 'utf8') : null;
    return { code: r.status, signal: r.signal, out, text: out.toString('utf8'), result: resultText ? JSON.parse(resultText) : null, resultText };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// Any 10-character window of `secret`, with full Unicode case folding, in the output or the evidence.
const leaks = (r, secret) => {
  const text = (r.text + (r.resultText || '')).toLowerCase();
  const chars = Array.from(secret.toLowerCase());
  for (let i = 0; i + 10 <= chars.length; i++) if (text.includes(chars.slice(i, i + 10).join(''))) return true;
  return false;
};
const anyLeak = (r) => [S.pathA, S.queryA, S.queryB, SPLIT, CYR].some((s) => leaks(r, s));

const cases = [];

// CONTROL
{
  const r = await runProbe({});
  cases.push(['CONTROL: honest providers: VERIFIED_MATCH (exit 0), nothing leaked',
    r.code === 0 && r.result?.status === 'VERIFIED_MATCH' && !anyLeak(r), `exit ${r.code}, status ${r.result?.status ?? 'none'}, leaked ${anyLeak(r)}`]);
}

// 0. V8's --trace, a node command-line option like the --print-regexp-* ones test-probe-native-output.mjs
//    covers: it prints every JavaScript call's arguments from native code, so refuseUrlShape(url),
//    pctBytes(segment) and the rest print each configured URL and credential verbatim. The probe does not
//    look at process.execArgv, so it neither refuses the option nor could scrub its output.
{
  const r = await runProbe({ nodeArgs: ['--trace'] });
  const l = anyLeak(r);
  const line = l ? r.text.split('\n').find((x) => x.includes(S.pathA)) : null;
  cases.push(['0. node --trace: nothing of a credential reaches the output (refusing the option also passes)',
    !l, `exit ${r.code}, ${r.out.length} bytes of output, leaked ${l}${line ? `\n         first leaking line: ${line.trim().split(S.pathA).join('<SENTINEL pathA>').split(S.queryA).join('<SENTINEL queryA>').slice(0, 170)}` : ''}`]);
}

// 1. the same provider selected for A and B
{
  const r = await runProbe({ env: { MAKO_PROVIDER_B: 'mock-a' } });
  const notSet = /environment variable MAKO_RPC_MOCK_A is not set/.test(r.text);
  cases.push(['1. same provider for A and B (diagnostic): both resolve, VERIFIED_MATCH at proofLevel one-domain, no false "not set"',
    r.code === 0 && r.result?.status === 'VERIFIED_MATCH' && r.result?.proofLevel === 'one-domain' && !notSet && !anyLeak(r),
    `exit ${r.code}, status ${r.result?.status ?? 'none'}, proofLevel ${r.result?.proofLevel ?? 'none'}, says "not set": ${notSet}`]);
}

// 2. a credential split across the 64 KiB flush
{
  const writer = `process.on('exit', () => {
  process.stdout.write('x'.repeat(65530) + ${JSON.stringify(SPLIT.slice(0, 9))});
  process.stdout.write(${JSON.stringify(SPLIT.slice(9))} + '\\n');
});\n`;
  const r = await runProbe({ writer });
  const l = leaks(r, SPLIT);
  cases.push(['2. credential split across two writes at the 64 KiB flush is still redacted',
    r.code === 0 && !l, `exit ${r.code}, leaked ${l}${l ? ` (tail: ...${r.text.slice(r.text.lastIndexOf('xxxx') + 4).trim().replace(SPLIT, '<SPLIT SENTINEL, 18 chars>')})` : ''}`]);
}

// 3. a Cyrillic credential echoed in the other case
{
  const writer = `process.on('exit', () => { process.stdout.write('echo: ' + ${JSON.stringify(CYR.toUpperCase())} + '\\n'); });\n`;
  const r = await runProbe({ writer, pathA: CYR });
  const l = leaks(r, CYR);
  // Refusing a non-ASCII credential before any call also passes: no request is then ever made, so no
  // provider can echo it. The 'exit' writer here is this test's own instrument (a preload) printing the
  // secret itself, which after a refusal is not output the probe produced.
  const refused = r.code === 2 && r.text.includes('non-ASCII') && r.result?.status !== 'VERIFIED_MATCH'
    && !(r.result && JSON.stringify(r.result).includes('"served":true'));
  cases.push(['3. non-ASCII credential in the other case is redacted, or refused before any call',
    refused || (r.code === 0 && r.result?.status === 'VERIFIED_MATCH' && !l), `exit ${r.code}, status ${r.result?.status ?? 'none'}, refused ${refused}, leaked ${l}`]);
}

// 4. held bytes on a signal death
{
  const MARK = 'PARTIAL-LINE-WRITTEN-BEFORE-SIGTERM';
  const writer = `setTimeout(() => { process.stdout.write(${JSON.stringify(MARK)}); process.kill(process.pid, 'SIGTERM'); }, 0);\n`;
  const r = await runProbe({ writer });
  const seen = r.text.includes(MARK);
  cases.push(['4. bytes written without a newline still appear when a SIGTERM ends the run',
    r.signal === 'SIGTERM' && seen, `signal ${r.signal}, bytes appeared ${seen}`]);
}

server.close();
let bad = 0;
for (const [name, ok, detail] of cases) {
  if (!ok) bad++;
  console.log(`  [${ok ? ' ok ' : 'FAIL'}] ${name}`);
  console.log(`         ${detail}`);
}
console.log(`\n  ${cases.length - bad} of ${cases.length} cases behaved as required.`);
process.exit(bad ? 1 : 0);
