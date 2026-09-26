// Redaction test for the archive probe: output Node writes NATIVELY, past the JavaScript stream wrapper.
// (adopted into CI once the probe excluded the environment from reports, deleted the URL variables after reading them, and stopped building a regex from secrets.)
// Written by the eleventh adversary pass, against 86e60a2.
//
//   node script/test-probe-native-output.mjs   about 40 seconds; no network, no openssl
//
// 86e60a2 scrubs stdout and stderr at the JavaScript stream, and refuses NODE_DEBUG_NATIVE because native
// output writes to the file descriptor directly. Two more native routes are neither scrubbed nor refused:
//
//   1. The diagnostic report. NODE_OPTIONS="--report-on-signal --report-filename=stdout" is an ordinary
//      environment setting; `--report-signal=SIGTERM` binds it to the signal a CI runner sends when it
//      cancels or times out a job. The report is written by C++ and carries `environmentVariables`, so
//      every configured RPC URL, credential included, lands on stdout verbatim. JavaScript can close this
//      (`process.report.excludeEnv`, or refusing while `process.report.reportOnSignal` is set); the probe
//      does neither.
//   2. V8's own trace and print options, which node accepts on its command line. The probe's scrubber is
//      itself a RegExp whose source holds every configured URL and every 10-character window of each
//      credential, so `--trace-regexp-parser`, `--print-regexp-bytecode` or `--print-regexp-code` print
//      the credential while V8 compiles the very pattern meant to hide it. process.execArgv is not checked.
//
// Same harness shape as test-probe-debuglog.mjs: the REAL probe runs from a temp copy of the repo against
// an honest local JSON-RPC mock (loopback http), with sentinel credentials in the path and the query.
// The child gets a MINIMAL environment (PATH plus the probe's variables), so the developer's own settings
// cannot decide the outcome and a report cannot copy the developer's environment into this test's memory.
// PASS means no 10-character window of any sentinel appears on stdout, stderr or RESULT.json. A probe that
// refuses to run with the setting passes too, as long as it prints nothing of a credential.
// The CONTROL runs without any setting and must reach VERIFIED_MATCH with no leak.

import { mkdtempSync, cpSync, rmSync, writeFileSync, readFileSync, readdirSync, existsSync, openSync, closeSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const SENTINELS = ['SENTINELNATPATHaaaa1111', 'SENTINELNATQUERYbbbb2222', 'SENTINELNATPATHcccc3333', 'SENTINELNATQUERYdddd4444'];

// ---- honest answers, from the repo's own vendored fixtures ----
const VERIFIER_CODE = readFileSync(join(REPO, 'test/fixtures/datastreams/verifier-runtime-62922075.hex'), 'utf8').trim();
const PINNED_B1 = JSON.parse(readFileSync(join(REPO, 'test/fixtures/datastreams/evidence/archive-probe-2026-09-24T21-28-43-466Z/RESULT.json'), 'utf8'));
const VERIFY_RETURN = PINNED_B1.providers['monad-public'].rawResult;
const ZERO_WORD = '0x' + '00'.repeat(32);
const word = (n) => n.toString(16).padStart(64, '0');
const TV_CANONICAL = '0x' + word(32) + word(19) + Buffer.from('VerifierProxy 2.0.0').toString('hex').padEnd(64, '0');

// An honest provider that answers after DELAY_MS, so a run is still in flight when the signal arrives.
let DELAY_MS = 0;
const server = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => setTimeout(() => {
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
  }, DELAY_MS));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const HOST = `127.0.0.1:${server.address().port}`;

function tree() {
  const dir = mkdtempSync(join(tmpdir(), 'mako-adv11-'));
  cpSync(join(REPO, 'script'), join(dir, 'script'), { recursive: true });
  cpSync(join(REPO, 'test/fixtures/datastreams/pending'), join(dir, 'test/fixtures/datastreams/pending'), { recursive: true });
  writeFileSync(join(dir, 'script/providers.json'), JSON.stringify({
    providers: [
      { id: 'mock-a', host: HOST, urlEnv: 'MAKO_RPC_MOCK_A', operator: 'Mock Operator A', credentialed: true },
      { id: 'mock-b', host: HOST, urlEnv: 'MAKO_RPC_MOCK_B', operator: 'Mock Operator B', credentialed: true },
    ],
  }));
  return dir;
}

const providers = {
  MAKO_PROVIDER_A: 'mock-a',
  MAKO_PROVIDER_B: 'mock-b',
  MAKO_RPC_MOCK_A: `http://${HOST}/v2/${SENTINELS[0]}?apikey=${SENTINELS[1]}`,
  MAKO_RPC_MOCK_B: `http://${HOST}/v2/${SENTINELS[2]}?apikey=${SENTINELS[3]}`,
  MAKO_PROBE_RPC_TIMEOUT_MS: '5000',
};

// `signal`: sent once, as soon as the probe prints its first provider header, i.e. mid-run.
async function runProbe({ args = [], env = {}, signal = null }) {
  const dir = tree();
  try {
    // Output goes to a FILE, as it does under `node probe > log 2>&1`: a pipe the parent drains slowly can
    // make a large native write fail part way, which would make the outcome depend on scheduling.
    const logPath = join(dir, 'output.log');
    const fd = openSync(logPath, 'w');
    const r = await new Promise((resolve) => {
      const child = spawn(process.execPath, [...args, join(dir, 'script/probe-archive.mjs')], {
        env: { PATH: process.env.PATH, ...providers, ...env }, stdio: ['ignore', fd, fd],
      });
      const kill = setTimeout(() => child.kill('SIGKILL'), 120_000);
      let sent = false;
      const poll = setInterval(() => {
        if (signal && !sent && readFileSync(logPath, 'utf8').includes('--- mock-a')) { sent = true; child.kill(signal); }
      }, 50);
      child.on('close', (status) => { clearTimeout(kill); clearInterval(poll); resolve({ status, sent }); });
    });
    closeSync(fd);
    r.out = readFileSync(logPath, 'utf8');
    const evDir = join(dir, 'test/fixtures/datastreams/evidence');
    const runs = existsSync(evDir) ? readdirSync(evDir) : [];
    const resultText = runs.length && existsSync(join(evDir, runs[0], 'RESULT.json')) ? readFileSync(join(evDir, runs[0], 'RESULT.json'), 'utf8') : null;
    return { code: r.status, out: r.out, sent: r.sent, result: resultText ? JSON.parse(resultText) : null, resultText };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// Any 10-character window of a sentinel, case-insensitively, in the output or the evidence.
const leaked = (r) => {
  const text = (r.out + (r.resultText || '')).toLowerCase();
  for (const s of SENTINELS) for (let i = 0; i + 10 <= s.length; i++) if (text.includes(s.slice(i, i + 10).toLowerCase())) return true;
  return false;
};

const REPORT = '--report-on-signal --report-filename=stdout';
const scenarios = [
  { name: 'CONTROL: honest providers, no setting: VERIFIED_MATCH, nothing leaked', control: true },
  { name: 'CONTROL: a SIGUSR2 mid-run with no report setting is harmless (the signal itself is not the leak)', delay: 300, signal: 'SIGUSR2', signalControl: true },
  { name: `NODE_OPTIONS="${REPORT}", SIGUSR2 mid-run`, delay: 300, env: { NODE_OPTIONS: REPORT }, signal: 'SIGUSR2' },
  { name: `NODE_OPTIONS="${REPORT} --report-signal=SIGTERM", SIGTERM mid-run (a CI job cancel)`, delay: 300, env: { NODE_OPTIONS: `${REPORT} --report-signal=SIGTERM` }, signal: 'SIGTERM' },
  { name: 'node --trace-regexp-parser', args: ['--trace-regexp-parser'] },
  { name: 'node --print-regexp-bytecode', args: ['--print-regexp-bytecode'] },
  { name: 'node --print-regexp-code', args: ['--print-regexp-code'] },
];

let bad = 0;
for (const sc of scenarios) {
  DELAY_MS = sc.delay || 0;
  const r = await runProbe(sc);
  const leak = leaked(r);
  let ok;
  if (sc.control) ok = r.code === 0 && r.result?.status === 'VERIFIED_MATCH' && r.out.includes('T0.1 archive probe') && !leak;
  // SIGUSR2 with no handler terminates the child; what matters is that it was delivered mid-run and printed nothing.
  else if (sc.signalControl) ok = r.sent && !leak;
  // A probe that refuses the setting exits non-zero before the first provider header, so no signal is sent.
  else ok = !leak && (!sc.signal || r.sent || r.code !== 0);
  if (!ok) bad++;
  console.log(`  [${ok ? ' ok ' : 'FAIL'}] ${sc.name}`);
  console.log(`         exit ${r.code}, status ${r.result?.status ?? 'none'}, signal sent ${sc.signal ? r.sent : 'n/a'}, leaked ${leak}`);
  if (leak) {
    // Where, with each sentinel masked so this log is not a second copy of the pattern.
    const line = r.out.split('\n').find((l) => SENTINELS.some((s) => l.includes(s.slice(0, 10))));
    if (line) console.log(`         first leaking line: ${SENTINELS.reduce((l, s) => l.split(s).join('<SENTINEL>'), line).trim().slice(0, 150)}`);
  }
}
server.close();
console.log(`\n  ${scenarios.length - bad} of ${scenarios.length} scenarios behaved as required.`);
process.exit(bad ? 1 : 0);
