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

// The complete set of functions allowed to change state, by EXACT canonical signature. Names alone let an overload
// in: a second `claim(bytes32)` that writes state or moves USDC kept every name on the list (Codex T1.4 r1). Adding
// or changing one is a reviewed change to this list, which is the point. `onReport` joins it when the CRE
// forwarder layout is pinned (T2.0).
const ALLOWED_WRITERS = [
  'claim(uint256)',
  'enter(uint256,uint8,uint256)',
  'finalizeRefund(uint256)',
  'schedule(uint64)',
  'settle(uint256,bytes,bytes)',
  'withdrawTreasury()',
];

// SPEC §9: exactly four selectors are sponsored, "nothing else, ever". The one source of truth the sponsorship
// configuration is checked against: the app pins the same four selectors (mako-markets
// src/lib/rounds-call-allowlist.ts, ROUND_*_SELECTOR), and the compiled contract must produce exactly these.
const SPONSORED = {
  'enter(uint256,uint8,uint256)': '9ad6c260',
  'claim(uint256)': '379607f5',
  'schedule(uint64)': '0ad9f5d2',
  'finalizeRefund(uint256)': 'e6d6aedc',
};

/// A function's canonical signature, as its selector is computed: tuples spelled out as `(t1,t2)`.
function canonicalType(p) {
  if (!p.type.startsWith('tuple')) return p.type;
  return `(${p.components.map(canonicalType).join(',')})${p.type.slice('tuple'.length)}`;
}
const signature = (f) => `${f.name}(${(f.inputs ?? []).map(canonicalType).join(',')})`;

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
const writers = fns.filter((f) => f.stateMutability !== 'view' && f.stateMutability !== 'pure').map(signature).sort();
// Any name used by more than one function (view or not) is an overload, refused outright: a reviewer reading
// `claim` must be reading the only `claim`.
const names = fns.map((f) => f.name);
const overloaded = [...new Set(names.filter((n, i) => names.indexOf(n) !== i))];
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
if (overloaded.length) problems.push(`overloaded function names (one function per name): ${overloaded.join(', ')}`);
for (const s of Object.keys(SPONSORED)) if (!writers.includes(s)) problems.push(`sponsored function ${s} does not exist`);
// The selectors themselves, from the compiler, for the compiled contract.
if (!process.argv[2]) {
  const ids = JSON.parse(execFileSync('forge', ['inspect', 'MakoRoundsV1', 'methodIdentifiers', '--json'], { encoding: 'utf8' }));
  for (const [sig, sel] of Object.entries(SPONSORED)) {
    if (ids[sig] !== sel) problems.push(`sponsored ${sig} has selector ${ids[sig]}, the sponsorship list pins ${sel}`);
  }
}

// N7 beyond "no setter". The second adversary pass on T1.4 turned MAX_ACTIVE_ROUNDS into a storage variable
// written inside `schedule`: no setter function existed, so the ABI checks passed. So, from the compiled
// contract and its source:
//   (a) the storage layout must equal this allowlist EXACTLY, so a SPEC §4 value moved into storage adds a
//       slot and fails;
//   (b) every SPEC §4 value must be declared `constant` or `immutable`, which the compiler then enforces;
//   (c) the creator set, the one §4 value that must live in storage (Solidity has no immutable mapping), may
//       be written only inside the constructor.
if (!process.argv[2]) {
  const STORAGE = [
    '_isCreator:t_mapping(t_address,t_bool)', '_stakes', 'treasuryBalance:t_uint256', '_stakeClaimed:t_mapping(t_uint256,t_mapping(t_address,t_bool))',
    '_creatorFeeClaimed:t_mapping(t_uint256,t_bool)', '_lock:t_uint256', '_rounds', 'roundCount:t_uint256', '_activeIds:t_array(t_uint256)dyn_storage',
    '_activePos:t_mapping(t_uint256,t_uint256)', 'creatorActiveRound:t_mapping(t_address,t_uint256)',
  ];
  const layout = JSON.parse(execFileSync('forge', ['inspect', 'MakoRoundsV1', 'storageLayout', '--json'], { encoding: 'utf8' })).storage
    .map((x) => (x.label === '_stakes' || x.label === '_rounds' ? x.label : `${x.label}:${x.type}`));
  const extraSlots = layout.filter((x) => !STORAGE.includes(x));
  const missingSlots = STORAGE.filter((x) => !layout.includes(x));
  if (extraSlots.length) problems.push(`storage not on the allowlist (a SPEC §4 value in storage can be changed): ${extraSlots.join(', ')}`);
  if (missingSlots.length) problems.push(`allowlisted storage missing: ${missingSlots.join(', ')}`);

  const src = readFileSync('src/MakoRoundsV1.sol', 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
  const lib = readFileSync('src/RoundSettlement.sol', 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
  const SPEC4 = [['ENTRY_LEAD', src], ['BOUNDARY_STEP', src], ['DURATION', src], ['MIN_LEAD', src], ['MAX_LEAD', src], ['SUBMIT_WINDOW', src],
    ['MAX_ACTIVE_ROUNDS', src], ['MIN_ENTRY', src], ['PROTOCOL_FEE_BPS', src], ['CREATOR_FEE_BPS', src], ['TREASURY', src], ['USDC', src],
    ['CREATORS_HASH', src], ['VERIFIER_PROXY', lib], ['FEED_ID', lib], ['MAX_SPREAD_BPS', lib]];
  for (const [name, code] of SPEC4) {
    const decl = new RegExp(`\\b(?:constant|immutable)\\b[^;=]*\\b${name}\\b\\s*[;=]`);
    if (!decl.test(code)) problems.push(`SPEC §4 value ${name} is not declared constant or immutable`);
  }
  const ctor = src.match(/constructor\s*\([^)]*\)[^{]*\{([\s\S]*?)\n    \}/);
  const outside = ctor ? src.replace(ctor[0], '') : src;
  if (/_isCreator\s*\[[^\]]*\]\s*=(?!=)/.test(outside)) problems.push('the creator set (_isCreator) is written outside the constructor');
}

// N10 at the SOURCE, since the ABI shows no modifiers: no pause-like identifier may appear in the contract or
// its library, comments removed. Added at T1.4 after the adversary pointed out that a `whenNotPaused`
// modifier on an allowed writer would pass the ABI checks above. What this still cannot see is a gate under
// an innocent name inside one of the six allowed writers; that is left to review and to each writer's tests.
if (!process.argv[2]) {
  const PAUSE_WORDS = /\b\w*(pause|paused|halt|halted|freeze|frozen|stopped|circuitbreak|killswitch)\w*\b/i;
  for (const f of ['src/MakoRoundsV1.sol', 'src/RoundSettlement.sol']) {
    const code = readFileSync(f, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
    const hit = code.match(PAUSE_WORDS);
    if (hit) problems.push(`${f} declares or uses a pause-like identifier: ${hit[0]}`);
  }
}

console.log(`MakoRoundsV1 surface: ${fns.length} functions, ${writers.length} state-changing`);
console.log(`  writers:   ${writers.join(', ')}`);
console.log(`  sponsored: ${Object.entries(SPONSORED).map(([k, v]) => `${k} 0x${v}`).join(', ')}  (SPEC §9, exactly four)`);

if (problems.length) {
  console.error('\nSURFACE CHECK FAILED');
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log('\n  N7: no setter, every SPEC §4 value constant or immutable, storage exactly the allowlist, creator set written only in the constructor.');
console.log('  N10: no pause function in the ABI and no pause-like identifier in the source.');
