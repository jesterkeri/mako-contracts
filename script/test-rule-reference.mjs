// Regression test for script/rule-reference.mjs's evidence handling.
//
//   node script/test-rule-reference.mjs
//
// The Codex diff review (round 2) showed the reference took whichever archive-probe directory sorted
// LAST, so a later failed probe run, or a missing evidence tree, turned the mandatory real row into a
// skip while the gate exited 0. The reference now evaluates the real row only against ONE B1 record
// pinned by path and checksum in the corpus, and treats anything else as a failure.
//
// This proves it by running the reference against TEMP COPIES of the repo's script/ and test/fixtures/
// with the evidence deliberately broken, one way per scenario. The working tree is never modified.

import { mkdtempSync, cpSync, rmSync, mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const sha = (b) => createHash('sha256').update(b).digest('hex');

function tree() {
  const dir = mkdtempSync(join(tmpdir(), 'mako-ref-'));
  cpSync(join(REPO, 'script'), join(dir, 'script'), { recursive: true });
  cpSync(join(REPO, 'test/fixtures'), join(dir, 'test/fixtures'), { recursive: true });
  return dir;
}

function run(dir) {
  try {
    const out = execFileSync('node', [join(dir, 'script/rule-reference.mjs'), '--json'], { encoding: 'utf8' });
    return { code: 0, json: JSON.parse(out) };
  } catch (e) {
    let json = null;
    try { json = JSON.parse(e.stdout); } catch {}
    return { code: e.status ?? 1, json };
  }
}

const corpusPath = (dir) => join(dir, 'test/fixtures/rule-cases/CASES.json');
const pinnedRecord = (dir) => join(dir, JSON.parse(readFileSync(corpusPath(dir), 'utf8'))._realEvidence.record.path);
const realRow = (r) => r.json?.rows?.find((x) => x.id === 'accept-real-widened-window');

// Rewrites the pinned record AND re-pins its checksum, so the ONLY thing under test is the content check.
function rewritePinned(dir, mutate) {
  const p = pinnedRecord(dir);
  const rec = JSON.parse(readFileSync(p, 'utf8'));
  mutate(rec);
  const text = JSON.stringify(rec, null, 2);
  writeFileSync(p, text);
  const c = JSON.parse(readFileSync(corpusPath(dir), 'utf8'));
  c._realEvidence.record.sha256 = sha(Buffer.from(text));
  writeFileSync(corpusPath(dir), JSON.stringify(c, null, 2) + '\n');
}

const scenarios = [
  {
    name: 'baseline: the pinned record is intact',
    arrange: () => {},
    expect: 'pass',
  },
  {
    name: 'a NEWER failed probe record exists (the round 2 finding): still evaluated from the pinned one',
    arrange: (d) => {
      const late = join(d, 'test/fixtures/datastreams/evidence/archive-probe-2099-01-01T00-00-00-000Z');
      mkdirSync(late, { recursive: true });
      writeFileSync(join(late, 'RESULT.json'), JSON.stringify({ status: 'ARCHIVE_UNAVAILABLE', reason: 'a provider could not be resolved' }));
    },
    expect: 'pass',
  },
  {
    name: 'the pinned record is missing',
    arrange: (d) => rmSync(pinnedRecord(d)),
    expect: 'fail',
  },
  {
    name: 'the whole evidence tree is missing',
    arrange: (d) => rmSync(join(d, 'test/fixtures/datastreams/evidence'), { recursive: true, force: true }),
    expect: 'fail',
  },
  {
    name: 'the pinned record was edited without re-pinning',
    arrange: (d) => writeFileSync(pinnedRecord(d), readFileSync(pinnedRecord(d), 'utf8') + ' '),
    expect: 'fail',
  },
  {
    name: 'the pinned record says ARCHIVE_UNAVAILABLE (re-pinned, so only the status check can catch it)',
    arrange: (d) => rewritePinned(d, (r) => { r.status = 'ARCHIVE_UNAVAILABLE'; }),
    expect: 'fail',
  },
  {
    name: 'the pinned record is one-domain (re-pinned)',
    arrange: (d) => rewritePinned(d, (r) => { r.proofLevel = 'one-domain'; }),
    expect: 'fail',
  },
  {
    name: 'the pinned record is for a different block hash (re-pinned)',
    arrange: (d) => rewritePinned(d, (r) => { r.target.blockHash = '0x' + '11'.repeat(32); }),
    expect: 'fail',
  },
  {
    name: 'the vendored fixture changed',
    arrange: (d) => {
      const f = join(d, 'test/fixtures/datastreams/pending/btcusd-1789529160.json');
      writeFileSync(f, readFileSync(f, 'utf8') + ' ');
    },
    expect: 'fail',
  },
];

let bad = 0;
for (const sc of scenarios) {
  const dir = tree();
  try {
    sc.arrange(dir);
    const r = run(dir);
    const row = realRow(r);
    const passed = r.code === 0;
    let ok;
    if (sc.expect === 'pass') {
      ok = passed && row?.status === 'AGREES';
    } else {
      // Must fail, AND the real row must be reported as FAILED, never as a skip.
      ok = !passed && row?.status === 'FAILED';
    }
    if (!ok) bad++;
    console.log(`  [${ok ? ' ok ' : 'FAIL'}] ${sc.name}`);
    console.log(`         exit ${r.code}, real row ${row?.status ?? 'absent'}${row?.why ? `: ${row.why}` : ''}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

console.log(`\n  ${scenarios.length - bad} of ${scenarios.length} scenarios behaved as required.`);
if (bad) process.exit(1);
console.log('  The mandatory real row can no longer be dropped from the reference while it exits 0.');
