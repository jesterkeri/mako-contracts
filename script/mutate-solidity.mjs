// Mutation run for the Solidity library, per PROOF_STANDARD.md Version 3 §4.
//
//   node script/mutate-solidity.mjs
//
// The Solidity half of the mutation requirement. `script/mutate-reference.mjs` is the JavaScript
// half. The Version 3 review asked specifically for mutations that break the two evaluators
// INDEPENDENTLY with the corpus held fixed, so that a corpus able to absorb a mutation is caught.
//
// Every mutation runs on a COPY of the whole project in a temp directory. `src/RoundSettlement.sol`
// in the working tree is never edited and `git checkout` is never used, per the standing rule about
// undoing uncommitted work. The copy is 1.3 MB of lib/ plus source, which is cheap enough to do per
// mutation and removes any chance of leaving a mutated file behind.

import { mkdtempSync, writeFileSync, readFileSync, cpSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, '..');
const REL = 'src/RoundSettlement.sol';
const SRC = join(REPO, REL);

// Each mutation names the clause it breaks. A mutation that no test catches is a missing case.
const MUTATIONS = [
  {
    name: 'step 1: delete the fee-manager gate',
    clause: 'SPEC 5.2 step 1',
    from: 'if (IVerifierProxy(VERIFIER_PROXY).s_feeManager() != address(0)) revert FeeManagerEnabled();',
    to: '// mutated: fee-manager gate removed',
  },
  {
    name: 'step 2: pass a non-empty parameterPayload',
    clause: 'SPEC 5.2 step 2',
    from: '.verify(fullReport, "");',
    to: '.verify(fullReport, hex"01");',
    note: 'A non-empty parameterPayload engages fee handling on the real verifier. The mock refuses it, which is how this is caught.',
  },
  {
    name: 'step 3: accept any verified length',
    clause: 'SPEC 5.2 step 3',
    from: 'if (verified.length != VERIFIED_LENGTH) revert WrongSchema();',
    to: '// mutated: length check removed',
  },
  {
    name: 'step 3: drop the 0x0003 prefix check',
    clause: 'SPEC 5.2 step 3',
    from: 'if (bytes2(firstWord) != SCHEMA_V3) revert WrongSchema();',
    to: '// mutated: schema prefix check removed',
    note: 'The v8 and v11 rows STILL revert with this gone, as WrongFeed, because the prefix is the first two bytes of the feed id. Only the exact-selector expectation detects it. If this mutation ever survives, the suite has stopped asserting selectors.',
  },
  {
    name: 'step 4: skip the feed comparison',
    clause: 'SPEC 5.2 step 4',
    from: 'if (feedId != FEED_ID) revert WrongFeed();',
    to: '// mutated: feed check removed',
  },
  {
    name: 'step 5: allow observationsTimestamp != boundary',
    clause: 'SPEC 5.2 step 5',
    from: 'if (observationsTimestamp != boundary) revert WrongObservationTime();',
    to: '// mutated: observation-second check removed',
  },
  {
    name: 'step 5: allow validFrom after the observation',
    clause: 'SPEC 5.2 step 5',
    from: 'if (validFromTimestamp > observationsTimestamp) revert ValidFromAfterObservation();',
    to: '// mutated: valid-from ordering check removed',
  },
  {
    name: 'step 6: accept a non-positive price',
    clause: 'SPEC 5.2 step 6',
    from: 'if (price <= 0) revert NonPositivePrice();',
    to: '// mutated: price sign check removed',
  },
  {
    name: 'step 6: drop bid <= price <= ask',
    clause: 'SPEC 5.2 step 6',
    from: 'if (bid > price || price > ask) revert BidAskOutOfOrder();',
    to: '// mutated: bid/ask ordering check removed',
  },
  {
    name: 'step 6: compare the spread with >= instead of >',
    clause: 'SPEC 5.2 step 6',
    from: 'if (spread * 10_000 > uint256(int256(price)) * MAX_SPREAD_BPS) revert SpreadTooWide();',
    to: 'if (spread * 10_000 >= uint256(int256(price)) * MAX_SPREAD_BPS) revert SpreadTooWide();',
    note: 'Caught only by the exactly-at-the-limit accept row.',
  },
  {
    name: 'step 6: widen MAX_SPREAD_BPS to 51',
    clause: 'SPEC 5.2 step 6',
    from: 'uint256 internal constant MAX_SPREAD_BPS = 50;',
    to: 'uint256 internal constant MAX_SPREAD_BPS = 51;',
  },
  {
    name: 'step 6: take the spread difference in int192',
    clause: 'SPEC 5.2 step 6',
    from: 'uint256 spread = uint256(int256(ask) - int256(bid));',
    to: 'uint256 spread = uint256(int256(int192(ask - bid)));',
    note: 'THE one the plan warns about. This panics with 0x11 on the maximum-integer row instead of rejecting, so the row would pass for the wrong reason without an exact-selector expectation. This is why SPEC 5.2 step 6 names uint256.',
  },
  {
    name: 'step 7: use >= for expiry instead of >',
    clause: 'SPEC 5.2 step 7',
    from: 'if (block.timestamp > expiresAt) revert ReportExpired();',
    to: 'if (block.timestamp >= expiresAt) revert ReportExpired();',
    note: 'Caught only by the at-the-boundary accept row.',
  },
  {
    name: 'step 7: delete the expiry check',
    clause: 'SPEC 5.2 step 7',
    from: 'if (block.timestamp > expiresAt) revert ReportExpired();',
    to: '// mutated: expiry check removed',
    note: 'Load-bearing beyond the usual: VerifierProxy.verify does not check expiry at all, measured 2026-09-22, so this line is the only expiry defence in the system.',
  },
  {
    name: 'step 3: decode the SUBMITTED bytes instead of the verified return',
    clause: 'SPEC 5.2 step 3',
    from: '        ) = abi.decode(verified, (bytes32, uint32, uint32, uint192, uint192, uint32, int192, int192, int192));',
    to: '        ) = abi.decode(fullReport, (bytes32, uint32, uint32, uint192, uint192, uint32, int192, int192, int192));',
    note: 'The attack the whole design exists to stop. A library reading its input accepts whatever the caller wrote.',
  },
];

const original = readFileSync(SRC, 'utf8');
let notKilled = 0;
const results = [];

console.log(`Mutation run: ${MUTATIONS.length} mutations against ${REL}\n`);

for (const m of MUTATIONS) {
  const count = original.split(m.from).length - 1;
  if (count !== 1) {
    console.log(`  [SKIP] ${m.name}`);
    console.log(`         anchor matched ${count} times, expected exactly 1. NOT APPLIED, so the clause is UNPROVEN.`);
    results.push({ name: m.name, status: 'ANCHOR_STALE', matched: count });
    notKilled++;
    continue;
  }

  const dir = mkdtempSync(join(tmpdir(), 'mako-sol-mut-'));
  try {
    for (const p of ['src', 'test', 'lib', 'foundry.toml', 'remappings.txt']) {
      try { cpSync(join(REPO, p), join(dir, p), { recursive: true }); } catch {}
    }
    writeFileSync(join(dir, REL), original.replace(m.from, m.to));

    let out = '', failed = false, compileError = false;
    try {
      out = execFileSync('forge', ['test', '--root', dir, '--match-contract', 'RoundSettlementTest'], {
        encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (e) {
      out = (e.stdout || '') + (e.stderr || '');
      failed = true;
    }
    compileError = /Compiler run failed|Error \(\d+\)/.test(out);

    // A mutation that will not compile is still killed: the defect cannot ship. It is reported
    // separately so it is not mistaken for a test catching it at runtime.
    const status = compileError ? 'KILLED_AT_COMPILE' : failed ? 'KILLED' : 'SURVIVED';
    if (status === 'SURVIVED') notKilled++;

    const failing = [...out.matchAll(/\[FAIL[^\]]*\]\s+(\w+)/g)].map((x) => x[1]);
    console.log(`  [${status === 'SURVIVED' ? 'FAIL' : ' ok '}] ${m.name}`);
    console.log(`         ${m.clause}   ${status}${failing.length ? `  via ${[...new Set(failing)].join(', ')}` : ''}`);
    if (m.note && status === 'SURVIVED') console.log(`         note: ${m.note}`);
    results.push({ name: m.name, clause: m.clause, status, failing: [...new Set(failing)] });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// The working tree must be untouched. Asserted rather than assumed.
if (readFileSync(SRC, 'utf8') !== original) {
  console.error(`\n  FATAL: ${REL} differs from where it started. Restore it before continuing.`);
  process.exit(2);
}

const killed = results.filter((r) => r.status.startsWith('KILLED')).length;
console.log(`\n  ${killed} killed, ${notKilled} not killed`);
console.log(`  ${REL} is byte-identical to where it started; every mutation ran on a temp copy.`);
if (notKilled > 0) {
  console.log(`\n  A surviving mutation is a missing test, not a passing run.`);
  process.exit(1);
}
console.log(`\n  Every clause of SPEC 5.2 is load-bearing in the shipping library.`);
