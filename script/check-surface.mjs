// Asserts MakoRoundsV1's ENTIRE external surface, for N7 and N10.
//
//   node script/check-surface.mjs                 checks the compiled contract
//   node script/check-surface.mjs path/to/abi.json   checks a given ABI (used to prove the gate fails)
//
// N7:  every SPEC.md §4 value is immutable, so there must be NO setter.
// N10: no pause can block settle, onReport, finalizeRefund, claim or withdrawTreasury.
//
// Neither can be proven from inside Solidity: a test cannot enumerate a contract's functions, so a
// test named test_NoSetters could only ever check for the setters its author thought to look for.
// This checks the compiled ABI against an exact allowlist instead, so ANY new state-changing
// function fails the build until someone decides, in review, that it belongs.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

// The complete set of functions allowed to change state. Adding one is a reviewed change to this
// list, which is the point. `onReport` joins it when the CRE forwarder layout is pinned (T2.0).
const ALLOWED_WRITERS = ['claim', 'enter', 'finalizeRefund', 'schedule', 'settle', 'withdrawTreasury'];

// SPEC §9: exactly four selectors are sponsored, "nothing else, ever". Recorded here so the
// sponsorship configuration has one source of truth to be checked against.
const SPONSORED = ['enter', 'claim', 'schedule', 'finalizeRefund'];

// Names that would signal an authority this contract must not have, whatever their mutability.
// Two patterns, because a setter is detected by CASE: `setTreasury` is a setter and `settle` is not.
// A single case-insensitive `set[A-Z]` matched the `t` in "settle" and failed the real contract,
// which a first run caught. A gate with a false positive gets switched off, so the setter pattern
// is case-sensitive and the authority words are not.
const FORBIDDEN_WORDS = /(^|_)(pause|unpause|owner|transferOwnership|renounce|admin|upgrade|initialize|sweep|rescue|emergency)/i;
const SETTER = /^set[A-Z0-9_]/;

const abi = process.argv[2]
  ? JSON.parse(readFileSync(process.argv[2], 'utf8'))
  : JSON.parse(execFileSync('forge', ['inspect', 'MakoRoundsV1', 'abi', '--json'], { encoding: 'utf8' }));

const fns = abi.filter((x) => x.type === 'function');
const writers = fns.filter((f) => f.stateMutability !== 'view' && f.stateMutability !== 'pure').map((f) => f.name).sort();
const payable = fns.filter((f) => f.stateMutability === 'payable').map((f) => f.name);
const forbidden = fns.map((f) => f.name).filter((n) => FORBIDDEN_WORDS.test(n) || SETTER.test(n));
const hasFallback = abi.some((x) => x.type === 'fallback' || x.type === 'receive');

const problems = [];
const extra = writers.filter((n) => !ALLOWED_WRITERS.includes(n));
const missing = ALLOWED_WRITERS.filter((n) => !writers.includes(n));
if (extra.length) problems.push(`state-changing functions not on the allowlist: ${extra.join(', ')}`);
if (missing.length) problems.push(`allowlisted functions missing from the contract: ${missing.join(', ')}`);
if (payable.length) problems.push(`payable functions, but this contract takes USDC only: ${payable.join(', ')}`);
if (forbidden.length) problems.push(`functions whose names imply forbidden authority: ${forbidden.join(', ')}`);
if (hasFallback) problems.push('a fallback or receive function exists, so native value could arrive');
for (const s of SPONSORED) if (!writers.includes(s)) problems.push(`sponsored selector ${s} does not exist`);

console.log(`MakoRoundsV1 surface: ${fns.length} functions, ${writers.length} state-changing`);
console.log(`  writers:   ${writers.join(', ')}`);
console.log(`  sponsored: ${SPONSORED.join(', ')}  (SPEC §9, exactly four)`);

if (problems.length) {
  console.error('\nSURFACE CHECK FAILED');
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log('\n  N7: no setter exists for any value.  N10: no pause exists on any path.');
