// Contract test for the archive probe's stdout/stderr wrapper: a write must come out as it went in, only
// (adopted into CI once the stream wrapper scrubbed bytes in each write's own encoding.)
// scrubbed. Written by the eleventh adversary pass, against 86e60a2.
//
//   node script/test-probe-stream-wrapper.mjs   about 2 seconds; no network
//
// 86e60a2 replaces process.stdout.write and process.stderr.write with a wrapper that turns every chunk into
// a UTF-8 string before scrubbing it. Two ordinary Writable behaviours are lost on the way:
//   - the `encoding` argument of a string write is dropped, so write('68656c6c6f0a', 'hex') prints the
//     twelve characters of the hex text instead of "hello\n", and write('é', 'latin1') prints two
//     bytes instead of one;
//   - a Buffer is decoded chunk by chunk, so a multi-byte character split across two writes becomes two
//     U+FFFD replacement characters (EF BF BD twice) instead of its own bytes.
// Nothing here carries a credential, so there is nothing for the scrubber to change: the output must be
// byte-identical to what an unwrapped stream writes.
//
// The writes come from a tiny --import module that registers them on process 'exit', after the probe has
// installed its wrapper. The probe itself runs in a temp copy with no provider configured, so it takes its
// fast "could not be resolved" path, exit 2. The same writes are made by a plain `node -e` as the reference.

import { mkdtempSync, cpSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const dir = mkdtempSync(join(tmpdir(), 'mako-adv11-stream-'));
let bad = 0;
try {
  cpSync(join(REPO, 'script'), join(dir, 'script'), { recursive: true });
  const e = Buffer.from('é');
  const writer = join(dir, 'writer.mjs');
  writeFileSync(writer, `
process.on('exit', () => {
  process.stdout.write('\\n<<');
  process.stdout.write('68656c6c6f', 'hex');
  process.stdout.write('|');
  process.stdout.write('\\u00e9', 'latin1');
  process.stdout.write('|');
  process.stdout.write(Buffer.from([${e[0]}]));
  process.stdout.write(Buffer.from([${e[1]}]));
  process.stdout.write('>>\\n');
});
`);
  const env = { PATH: process.env.PATH };
  const run = (args) => spawnSync(process.execPath, args, { env, cwd: dir, timeout: 60_000 });
  const tail = (buf) => { const s = buf.lastIndexOf(Buffer.from('\n<<')); return s < 0 ? null : buf.subarray(s + 3, buf.indexOf(Buffer.from('>>\n'), s)); };

  const ref = run(['--import', pathToFileURL(writer).href, '-e', '0']);
  const probe = run(['--import', pathToFileURL(writer).href, join(dir, 'script/probe-archive.mjs')]);
  const want = tail(ref.stdout);
  const got = tail(probe.stdout);

  const cases = [
    ['reference run produced the expected bytes (68656c6c6f7c e9 7c c3a9)', want?.toString('hex') === '68656c6c6f7ce97cc3a9'],
    ['probe took its fast path (exit 2, nothing configured)', probe.status === 2],
    ['probe output is byte-identical to the reference', got !== null && want !== null && got.equals(want)],
  ];
  for (const [name, ok] of cases) { if (!ok) bad++; console.log(`  [${ok ? ' ok ' : 'FAIL'}] ${name}`); }
  console.log(`         reference bytes ${want?.toString('hex')}`);
  console.log(`         probe bytes     ${got?.toString('hex')}`);
} finally {
  rmSync(dir, { recursive: true, force: true });
}
console.log(`\n  ${bad ? 'FAILED' : 'passed'}`);
process.exit(bad ? 1 : 0);
