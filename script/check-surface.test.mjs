// Proves check-surface.mjs FAILS on the shapes it exists to refuse (Codex T1.4 r1), and passes the real contract.
// Each case writes a crafted ABI (the compiled one, changed) to a temp file and runs the gate on it.
//   node script/check-surface.test.mjs
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const abi = JSON.parse(execFileSync('forge', ['inspect', 'MakoRoundsV1', 'abi', '--json'], { encoding: 'utf8' }));
const dir = mkdtempSync(join(tmpdir(), 'surface-'));
const fn = (name, inputs, stateMutability = 'nonpayable') => ({ type: 'function', name, inputs, outputs: [], stateMutability });

const run = (label, a) => {
  const p = join(dir, `${label.replace(/\W+/g, '-')}.json`);
  writeFileSync(p, JSON.stringify(a));
  return spawnSync('node', ['script/check-surface.mjs', p], { encoding: 'utf8' });
};

const MUST_FAIL = [
  ['a state-changing overload of an allowlisted name: claim(bytes32)', [...abi, fn('claim', [{ name: 'x', type: 'bytes32' }])], 'claim(bytes32)'],
  ['an overload of enter with other arguments', [...abi, fn('enter', [{ name: 'to', type: 'address' }])], 'enter(address)'],
  ['a view overload is still an overload', [...abi, fn('claim', [{ name: 'a', type: 'address' }], 'view')], 'overloaded'],
  ['an allowlisted writer with a changed signature', abi.map((f) => (f.name === 'schedule' ? { ...f, inputs: [{ name: 't', type: 'uint256' }] } : f)), 'schedule(uint256)'],
  ['a tuple-argument writer', [...abi, fn('settle', [{ name: 'r', type: 'tuple', components: [{ name: 'a', type: 'uint256' }, { name: 'b', type: 'bytes' }] }])], 'settle((uint256,bytes))'],
  ['a new writer', [...abi, fn('sweep', [])], 'sweep()'],
];

let failed = 0;
for (const [label, a, expect] of MUST_FAIL) {
  const r = run(label, a);
  const ok = r.status !== 0 && (r.stderr + r.stdout).includes(expect);
  console.log(`${ok ? 'ok  ' : 'FAIL'} refuses ${label}`);
  if (!ok) {
    failed++;
    console.log(r.stdout, r.stderr);
  }
}
const real = run('the compiled ABI', abi);
const realOk = real.status === 0;
console.log(`${realOk ? 'ok  ' : 'FAIL'} accepts the compiled ABI`);
if (!realOk) failed++;
rmSync(dir, { recursive: true, force: true });
if (failed) {
  console.error(`\n${failed} surface-gate case(s) wrong`);
  process.exit(1);
}
