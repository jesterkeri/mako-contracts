// Asserts MakoOutcomeExchangeV1's ENTIRE external surface (OFFCHAIN_MATCHING_PLAN.md 3.1, 3.3, 4.4, 4.5, 10.1).
//
//   node script/check-surface-exchange.mjs                   checks the compiled contract and its source
//   node script/check-surface-exchange.mjs path/to/abi.json  checks a given ABI (used to prove the gate fails)
//
// Environment overrides, used only by script/check-surface-exchange.test.mjs to prove the source rules fail:
//   EXCHANGE_SRC=path   the contract source to scan instead of src/MakoOutcomeExchangeV1.sol
//
// What it pins, and why a test cannot:
//   - EVERY external function, by exact canonical signature and state mutability, and (compiled mode) by selector. A test
//     cannot enumerate a contract's functions, so a test named test_NoSetters could only check the setters its author
//     thought of. Adding, removing or changing any function fails the build until a reviewer changes this list.
//   - The three functions that take an `Order` are matchOrders (0xe4ff4ef4), isValidOrderSignature (0x2d075cbf) and
//     cancelOrders (0x39ccdd5d), and no other function takes a tuple (plan 4.4). r6's matchOrders without signatures
//     (0x2399e413) and every other matchOrders overload must not exist (plan 3.1, r7).
//   - The registered order signer is ABSENT (plan 10.1, Q10): no setOrderSigner, orderSigner or OrderSignerSet, by name and
//     by selector. If the S1 decision record says the fallback fired, adding it is a reviewed change to THIS file.
//   - matchOrders is the only function gated on isOperator (plan 3.1 "Access control", O8), by source.
//   - No setter for a market term, no proxy, no delegatecall, no selfdestruct, fees only to the immutable TREASURY.
//   - The storage layout, slot by slot.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const CONTRACT = 'MakoOutcomeExchangeV1';
const ORDER = '(uint256,address,uint256,uint8,bool,uint8,uint128,uint64,uint64)';

// signature -> [stateMutability, selector]. The complete external function surface.
const FUNCTIONS = {
  'BACKSTOP_DELAY()': ['view', 'd53795f0'],
  'MAX_FEE_RATE()': ['view', '92f6576e'],
  'MAX_MAKERS()': ['view', '327d1b3e'],
  'MAX_SIG_LEN()': ['view', '04f0273a'],
  'ORDER_TYPEHASH()': ['view', 'f973a209'],
  'SIG_GAS()': ['view', '00082eca'],
  'TREASURY()': ['view', '2d2c5565'],
  'UNWIND()': ['view', '448a7319'],
  'USDC()': ['view', '89a30271'],
  'VETO_PERIOD()': ['view', 'e861dc85'],
  'acceptAdmin()': ['nonpayable', '0e18b681'],
  'admin()': ['view', 'f851a440'],
  'backstopUnwind(uint256)': ['nonpayable', '687efef8'],
  [`cancelOrders(${ORDER}[])`]: ['nonpayable', '39ccdd5d'],
  'cash(address)': ['view', 'b6dc16f6'],
  'closeEarly(uint256)': ['nonpayable', '14c9b8a5'],
  'createMarket(uint8,uint16,uint64,uint64,uint128,bytes32)': ['nonpayable', '4be3e449'],
  'deposit(uint256)': ['nonpayable', 'b6b55f25'],
  'eip712Domain()': ['view', '84b0196e'],
  'feeOf(uint256,uint256,uint256)': ['view', '78534b40'],
  'finalize(uint256)': ['nonpayable', '05261aea'],
  'incrementNonce()': ['nonpayable', '627cdcb9'],
  'isOperator(address)': ['view', '6d70f7ae'],
  [`isValidOrderSignature(${ORDER},bytes)`]: ['view', '2d075cbf'],
  'marketCount()': ['view', 'ec979082'],
  'marketOf(uint256)': ['view', 'eee97751'],
  [`matchOrders(${ORDER},bytes,${ORDER}[],bytes[],uint128[],uint128)`]: ['nonpayable', 'e4ff4ef4'],
  'mergeSets(uint256,uint256)': ['nonpayable', '03ccf5ba'],
  'mintSets(uint256,uint256)': ['nonpayable', '78c530fc'],
  'nonces(address)': ['view', '7ecebe00'],
  'orders(bytes32)': ['view', '9c3f1e90'],
  'paused()': ['view', '5c975abb'],
  'pendingAdmin()': ['view', '26782247'],
  'positionOf(uint256,uint8,address)': ['view', '95c0ea1a'],
  'proposeOutcome(uint256,uint8,bytes32)': ['nonpayable', '79a7c0ed'],
  'recOf(uint256,address)': ['view', 'ab001d4e'],
  'redeem(uint256)': ['nonpayable', 'db006a75'],
  'resolver()': ['view', '04f3bcec'],
  'setOperator(address,bool)': ['nonpayable', '558a7297'],
  'setPaused(bool)': ['nonpayable', '16c38b3c'],
  'setResolver(address)': ['nonpayable', '4e543b26'],
  'splitOf(uint256,address,uint256)': ['view', '12c66c5e'],
  'transferAdmin(address)': ['nonpayable', '75829def'],
  'treasuryBalance()': ['view', '313dab20'],
  'withdraw(uint256)': ['nonpayable', '2e1a7d4d'],
  'withdrawTreasury()': ['nonpayable', '166bab95'],
};

// The only functions that take an Order (plan 4.4).
const ORDER_TAKERS = {
  [`matchOrders(${ORDER},bytes,${ORDER}[],bytes[],uint128[],uint128)`]: 'e4ff4ef4',
  [`isValidOrderSignature(${ORDER},bytes)`]: '2d075cbf',
  [`cancelOrders(${ORDER}[])`]: '39ccdd5d',
};

// Selectors that must never exist: r6's matchOrders (no signatures), and the registered order signer (plan 4.5), whose
// selectors were derived with `cast sig` on 2026-11-20.
const ABSENT = {
  '2399e413': 'matchOrders without signatures (r6, withdrawn by r7)',
  '937832f9': 'setOrderSigner(address): the registered order signer is not built (plan 10.1, Q10)',
  '585dcd19': 'orderSigner(address): the registered order signer is not built (plan 10.1, Q10)',
};
const ABSENT_NAMES = /^(setOrderSigner|orderSigner|OrderSignerSet)$/;

// Every custom error and event of the ABI, by name. (The EIP-712 library's errors are included: they are part of the
// compiled surface.)
const ERRORS = [
  'BackstopNotOpen', 'BadFee', 'BadMakerCount', 'BadMarket', 'BadOption', 'BadOrderField', 'BadSignature',
  'BadSignatureLength', 'BadSize', 'Expired', 'FillMismatch', 'InexactTransfer', 'InsufficientCash', 'InsufficientGas',
  'InsufficientShares', 'InvalidShortString', 'LengthMismatch', 'MarketMismatch', 'NoProposal', 'NonceMismatch',
  'NotAdmin', 'NotAdminOrResolver', 'NotMaker', 'NotOperator', 'NotSettled', 'NotTreasury', 'NothingOwed',
  'OrderCancelled', 'Overfill', 'PartyRefused', 'Paused', 'PositionCap', 'PriceNotCrossed', 'ProposalPending',
  'ProposalTooLate', 'Reentrancy', 'RoleConflict', 'SelfMatch', 'SetPriceSum', 'StringTooLong', 'TradingClosed',
  'TradingOpen', 'TransferFailed', 'VetoElapsed', 'VetoRunning', 'WrongKind',
];
const EVENTS = [
  'AdminTransferStarted', 'AdminTransferred', 'Cancelled', 'Deposited', 'EIP712DomainChanged', 'Finalized', 'Leaf',
  'MarketCreated', 'NonceIncremented', 'OperatorSet', 'OutcomeProposed', 'PausedSet', 'Redeemed', 'ResolverSet',
  'SetsMerged', 'SetsMinted', 'TakerLeaf', 'TradingClosedEarly', 'TreasuryWithdrawn', 'Withdrawn',
];

// The storage layout, slot order, struct ids removed.
const STORAGE = [
  '_nameFallback:t_string_storage', '_versionFallback:t_string_storage', 'admin:t_address', 'pendingAdmin:t_address',
  'resolver:t_address', 'paused:t_bool', 'marketCount:t_uint256', 'treasuryBalance:t_uint256', '_lock:t_uint256',
  '_markets:t_mapping(t_uint256,t_struct(MarketS))', '_cash:t_mapping(t_address,t_uint256)',
  '_sharesS:t_mapping(t_bytes32,t_uint256)', '_rec:t_mapping(t_bytes32,t_struct(NetRec))',
  'orders:t_mapping(t_bytes32,t_struct(OrderState))', 'nonces:t_mapping(t_address,t_uint256)',
  'isOperator:t_mapping(t_address,t_bool)',
];

// The Market terms fixed at creation: written only in createMarket (plan 3.1 "no setters for market terms").
const TERMS = ['nOptions', 'feeRate', 'positionCap', 'rulesHash', 'resolutionDeadline'];

/// A function's canonical signature, as its selector is computed: tuples spelled out as `(t1,t2)`.
function canonicalType(p) {
  if (!p.type.startsWith('tuple')) return p.type;
  return `(${p.components.map(canonicalType).join(',')})${p.type.slice('tuple'.length)}`;
}
const signature = (f) => `${f.name}(${(f.inputs ?? []).map(canonicalType).join(',')})`;

const compiled = !process.argv[2];
const inspect = (what) => JSON.parse(execFileSync('forge', ['inspect', CONTRACT, what, '--json'], { encoding: 'utf8' }));
const abi = compiled ? inspect('abi') : JSON.parse(readFileSync(process.argv[2], 'utf8'));

const problems = [];
const fns = abi.filter((x) => x.type === 'function');
const seen = new Map(fns.map((f) => [signature(f), f.stateMutability]));

// ---- the complete function surface ----
for (const [sig, [mut]] of Object.entries(FUNCTIONS)) {
  if (!seen.has(sig)) problems.push(`allowlisted function missing from the contract: ${sig}`);
  else if (seen.get(sig) !== mut) problems.push(`${sig} is ${seen.get(sig)}, the allowlist pins ${mut}`);
}
for (const sig of seen.keys()) if (!(sig in FUNCTIONS)) problems.push(`external function not on the allowlist: ${sig}`);
const names = fns.map((f) => f.name);
const overloaded = [...new Set(names.filter((n, i) => names.indexOf(n) !== i))];
if (overloaded.length) problems.push(`overloaded function names (one function per name): ${overloaded.join(', ')}`);
if (fns.some((f) => f.name === 'matchOrders' && signature(f) !== Object.keys(ORDER_TAKERS)[0])) {
  problems.push('a matchOrders other than the section 4.4 one exists');
}
const payable = fns.filter((f) => f.stateMutability === 'payable').map((f) => f.name);
if (payable.length) problems.push(`payable functions, but this contract takes USDC only: ${payable.join(', ')}`);
if (abi.some((x) => x.type === 'fallback' || x.type === 'receive')) problems.push('a fallback or receive function exists, so native value could arrive');

// ---- exactly three functions take an Order (a tuple) ----
for (const f of fns) {
  const takesTuple = (f.inputs ?? []).some((i) => i.type.startsWith('tuple'));
  if (takesTuple && !(signature(f) in ORDER_TAKERS)) problems.push(`a function other than the three of plan 4.4 takes a tuple (an Order): ${signature(f)}`);
}
for (const sig of Object.keys(ORDER_TAKERS)) if (!seen.has(sig)) problems.push(`the plan 4.4 function is missing: ${sig}`);

// ---- the registered order signer is absent ----
for (const x of abi) {
  if (ABSENT_NAMES.test(x.name ?? '')) problems.push(`${x.type} ${x.name}: the registered order signer is not built (plan 10.1, Q10)`);
}

// ---- errors and events ----
const errs = abi.filter((x) => x.type === 'error').map((x) => x.name).sort();
const evs = abi.filter((x) => x.type === 'event').map((x) => x.name).sort();
for (const n of ERRORS) if (!errs.includes(n)) problems.push(`custom error missing: ${n}`);
for (const n of errs) if (!ERRORS.includes(n)) problems.push(`custom error not on the allowlist: ${n}`);
for (const n of EVENTS) if (!evs.includes(n)) problems.push(`event missing: ${n}`);
for (const n of evs) if (!EVENTS.includes(n)) problems.push(`event not on the allowlist: ${n}`);

// ---- compiled mode: selectors, storage layout, source rules ----
const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
function body(src, fn) {
  const m = src.match(new RegExp(`function\\s+${fn}\\s*\\([^)]*\\)[^{;]*\\{`));
  if (!m) return null;
  let depth = 1;
  let i = m.index + m[0].length;
  while (i < src.length && depth > 0) depth += src[i] === '{' ? 1 : src[i] === '}' ? -1 : 0, i++;
  return src.slice(m.index, i);
}

if (compiled) {
  const ids = inspect('methodIdentifiers');
  for (const [sig, [, sel]] of Object.entries(FUNCTIONS)) {
    if (ids[sig] !== sel) problems.push(`${sig} has selector ${ids[sig]}, the allowlist pins ${sel}`);
  }
  for (const [sel, why] of Object.entries(ABSENT)) {
    if (Object.values(ids).includes(sel)) problems.push(`selector 0x${sel} exists: ${why}`);
  }
  for (const [sig, sel] of Object.entries(ORDER_TAKERS)) {
    if (ids[sig] !== sel) problems.push(`order-taking function ${sig} must have selector 0x${sel}, has ${ids[sig]}`);
  }

  const layout = inspect('storageLayout').storage.map((x) => `${x.label}:${x.type.replace(/\)\d+_storage/g, ')').replace(/t_struct\((\w+)\)/g, 't_struct($1)')}`);
  const norm = (s) => s.replace(/\)\d+_storage/g, ')');
  const want = STORAGE.map(norm);
  const got = layout.map(norm);
  if (JSON.stringify(got) !== JSON.stringify(want)) problems.push(`storage layout differs from the allowlist.\n      want: ${want.join(' | ')}\n      got:  ${got.join(' | ')}`);

  const file = process.env.EXCHANGE_SRC ?? `src/${CONTRACT}.sol`;
  const src = strip(readFileSync(file, 'utf8'));

  // matchOrders is the only function gated on isOperator[msg.sender] (O8, plan 3.1)
  const gate = /isOperator\s*\[\s*msg\.sender\s*\]/g;
  const gates = [...src.matchAll(gate)];
  const mo = body(src, 'matchOrders');
  if (!mo) problems.push('matchOrders not found in the source');
  const inMatch = mo ? [...mo.matchAll(gate)].length : 0;
  if (gates.length !== 1 || inMatch !== 1) problems.push(`isOperator[msg.sender] must appear exactly once, inside matchOrders (found ${gates.length} in the file, ${inMatch} in matchOrders)`);
  if (/\bonlyOperator\b|\bonlyMatcher\b/.test(src)) problems.push('an operator modifier exists: matchOrders must be the only operator-gated function');

  // no delegatecall, callcode, selfdestruct, proxy, upgrade
  for (const w of ['delegatecall', 'callcode', 'selfdestruct', 'suicide']) {
    if (new RegExp(`\\b${w}\\b`).test(src)) problems.push(`the source uses ${w}`);
  }
  if (/\b(upgradeTo|upgradeToAndCall|_implementation|initialize|Proxy)\b/.test(src)) problems.push('the source mentions a proxy or an upgrade hook');
  // the registered signer is absent from the source too
  if (/\b(setOrderSigner|orderSigner|_boundedIsOwner|OrderSignerSet)\b/.test(src)) problems.push('the registered order signer appears in the source (plan 10.1, Q10)');

  // fees go to the immutable TREASURY only: the two places money leaves are withdraw (to the caller) and withdrawTreasury
  if (!/address\s+public\s+immutable\s+TREASURY\b/.test(src)) problems.push('TREASURY is not declared `address public immutable`');
  const outs = [...src.matchAll(/(?<!function\s)_safeTransferOut\s*\(\s*([^,]+?)\s*,/g)].map((m) => m[1]);
  if (JSON.stringify(outs.sort()) !== JSON.stringify(['TREASURY', 'msg.sender'])) problems.push(`_safeTransferOut must be called exactly twice, to TREASURY and to msg.sender (found: ${outs.join(', ')})`);
  const wt = body(src, 'withdrawTreasury');
  if (!wt || !/_safeTransferOut\s*\(\s*TREASURY\s*,/.test(wt) || !/msg\.sender\s*!=\s*TREASURY/.test(wt)) problems.push('withdrawTreasury must be TREASURY-only and pay TREASURY only');
  if (/\.(transfer|send|call)\s*[({]/.test(src.replace(/address\(USDC\)\.call\(/g, ''))) problems.push('a native-value or low-level call other than the two USDC calls exists');

  // no setter for any market term: written only in createMarket; tradingClose only there and in closeEarly (forward only)
  const cm = body(src, 'createMarket') ?? '';
  const ce = body(src, 'closeEarly') ?? '';
  const rest = src.replace(cm, '').replace(ce, '');
  // A write is caught whatever the struct is called (`mk`, `_markets[id]`, or any storage alias of a market, adversary
  // pass 1), in any assignment form, `++`/`--`, or `delete`. The one allowed match is the in-memory Plan copying the fee
  // rate once in matchOrders (`p.feeRate = mk.feeRate;`), so `p` may never name a market.
  const allowed = { feeRate: ['p.feeRate = mk.feeRate;'] };
  for (const t of [...TERMS, 'tradingClose']) {
    let r2 = rest;
    for (const a of allowed[t] ?? []) r2 = r2.split(a).join('');
    const assign = new RegExp(`\\.\\s*${t}\\s*(?:[-+*/%|&^]|<<|>>)?=(?!=)`);
    const step = new RegExp(`(\\+\\+|--)\\s*[\\w.\\[\\]\\s]*\\.\\s*${t}\\b|\\.\\s*${t}\\s*(\\+\\+|--)`);
    const del = new RegExp(`\\bdelete\\s+[^;]*\\.\\s*${t}\\b`);
    if (assign.test(r2) || step.test(r2) || del.test(r2)) problems.push(`market term ${t} is written outside createMarket${t === 'tradingClose' ? ' and closeEarly' : ''}`);
  }
  if (/MarketS\s+storage\s+p\b/.test(src)) problems.push('a market storage pointer named `p` (reserved for the in-memory Plan)');
  if (/_markets\s*\[[^\]]*\]\s*=(?!=)|\bdelete\s+_markets\b/.test(src)) problems.push('a whole market struct is assigned or deleted');
  if (/\bsstore\s*\(/.test(src)) problems.push('assembly sstore in the source');
  if (!/block\.timestamp\s*<\s*mk\.tradingClose/.test(ce)) problems.push('closeEarly must only move tradingClose earlier (no `block.timestamp < mk.tradingClose` guard found)');

  // the protocol constants of plan 1, 4.2 and 4.4
  const consts = [['MAX_MAKERS', '10'], ['MAX_SIG_LEN', '195'], ['SIG_GAS', '100_000'], ['MAX_FEE_RATE', '700']];
  for (const [n, v] of consts) {
    if (!new RegExp(`\\b${n}\\s*=\\s*${v}\\s*;`).test(src)) problems.push(`${n} must be ${v}`);
  }
  if (!/EIP712\s*\(\s*"Mako Market Exchange"\s*,\s*"1"\s*\)/.test(src)) problems.push('the EIP-712 domain must be ("Mako Market Exchange", "1")');
}

console.log(`${CONTRACT} surface: ${fns.length} functions, ${fns.filter((f) => f.stateMutability !== 'view' && f.stateMutability !== 'pure').length} state-changing`);

if (problems.length) {
  console.error('\nSURFACE CHECK FAILED');
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log('\n  every function pinned by signature, mutability and selector; exactly three take an Order; r6 matchOrders (0x2399e413) absent.');
console.log('  the registered order signer (setOrderSigner, orderSigner, OrderSignerSet) is absent.');
console.log('  isOperator[msg.sender] only in matchOrders; no delegatecall; fees only to the immutable TREASURY; no setter for a market term; storage exactly the allowlist.');
