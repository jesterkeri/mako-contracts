// Regression test for script/check-no-secrets.mjs.
//
//   node script/test-check-no-secrets.mjs
//
// The Codex diff review (round 4) found the scanner exempting two tracked files by NAME, so a real key
// added to either passed CI unscanned. The exemption is gone. This proves it by injecting a key-shaped,
// non-live value into each formerly exempt file (and into a new file), in a temp clone, and requiring the
// scan to fail WITHOUT printing the value. It also proves a template placeholder still passes.
//
// Every fake value is BUILT AT RUNTIME, so this file never contains a literal key-shaped string and
// needs no exemption of its own.

import { mkdtempSync, rmSync, writeFileSync, readFileSync, copyFileSync, appendFileSync } from 'node:fs';
import { spawnSync, execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');

const FAKES = {
  alchemy: 'https://monad-testnet.g' + '.alchemy.com/v2/' + 'Qx7'.repeat(8),
  privateKey: 'PRIVATE' + '_KEY=0x' + '9f3a'.repeat(16),
  apikey: 'https://rpc.example.org/?api' + 'key=' + 'Zk3'.repeat(8),
  placeholder: 'PRIVATE' + '_KEY=0x' + '0'.repeat(64),
};

function clone() {
  const dir = mkdtempSync(join(tmpdir(), 'mako-scan-'));
  execFileSync('git', ['clone', '-q', REPO, dir]);
  // The clone has HEAD; bring over the CURRENT scanner so the test exercises what is about to ship.
  for (const f of ['script/check-no-secrets.mjs', 'script/test-probe-redaction.mjs']) {
    copyFileSync(join(REPO, f), join(dir, f));
  }
  return dir;
}

function scan(dir) {
  const r = spawnSync('node', ['script/check-no-secrets.mjs'], { cwd: dir, encoding: 'utf8' });
  return { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
}

const scenarios = [
  { name: 'baseline: the repository as it stands', inject: null, expect: 'pass' },
  { name: 'real-looking Alchemy endpoint in check-no-secrets.mjs (formerly exempt)',
    inject: { file: 'script/check-no-secrets.mjs', value: FAKES.alchemy }, expect: 'fail' },
  { name: 'real-looking private key in test-probe-redaction.mjs (formerly exempt)',
    inject: { file: 'script/test-probe-redaction.mjs', value: FAKES.privateKey }, expect: 'fail' },
  { name: 'apikey query parameter in a brand-new tracked file',
    inject: { file: 'notes.md', value: FAKES.apikey, add: true }, expect: 'fail' },
  { name: 'a template placeholder (all zeros) is NOT a secret',
    inject: { file: 'notes.md', value: FAKES.placeholder, add: true }, expect: 'pass' },
];

let bad = 0;
for (const sc of scenarios) {
  const dir = clone();
  try {
    if (sc.inject) {
      appendFileSync(join(dir, sc.inject.file), `\n// injected by test: ${sc.inject.value}\n`);
      if (sc.inject.add) execFileSync('git', ['add', sc.inject.file], { cwd: dir });
    }
    const r = scan(dir);
    const leakedValue = sc.inject && r.out.includes(sc.inject.value);
    const ok = (sc.expect === 'pass' ? r.code === 0 : r.code !== 0) && !leakedValue;
    if (!ok) bad++;
    console.log(`  [${ok ? ' ok ' : 'FAIL'}] ${sc.name}`);
    console.log(`         exit ${r.code}${leakedValue ? ', AND THE VALUE WAS PRINTED' : ', value not printed'}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

console.log(`\n  ${scenarios.length - bad} of ${scenarios.length} scenarios behaved as required.`);
if (bad) process.exit(1);
console.log('  No tracked file is exempt, and a hit never prints the secret.');
