// Proves check-surface-exchange.mjs FAILS on the shapes it exists to refuse, and passes the real contract.
// ABI cases write a crafted ABI (the compiled one, changed) to a temp file; source cases write a changed copy of the
// contract source and point the gate at it with EXCHANGE_SRC.
//   node script/check-surface-exchange.test.mjs
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const abi = JSON.parse(execFileSync('forge', ['inspect', 'MakoOutcomeExchangeV1', 'abi', '--json'], { encoding: 'utf8' }));
const source = readFileSync('src/MakoOutcomeExchangeV1.sol', 'utf8');
const dir = mkdtempSync(join(tmpdir(), 'surface-ex-'));
const fn = (name, inputs, stateMutability = 'nonpayable') => ({ type: 'function', name, inputs, outputs: [], stateMutability });
const order = {
  name: 'o',
  type: 'tuple',
  components: ['uint256 salt', 'address maker', 'uint256 marketId', 'uint8 option', 'bool isBuy', 'uint8 price', 'uint128 size', 'uint64 expiration', 'uint64 nonce']
    .map((x) => ({ type: x.split(' ')[0], name: x.split(' ')[1] })),
};

const runAbi = (label, a) => {
  const p = join(dir, `${label.replace(/\W+/g, '-')}.json`);
  writeFileSync(p, JSON.stringify(a));
  return spawnSync('node', ['script/check-surface-exchange.mjs', p], { encoding: 'utf8' });
};
const runSrc = (label, mutate) => {
  const p = join(dir, `${label.replace(/\W+/g, '-')}.sol`);
  const changed = mutate(source);
  if (changed === source) throw new Error(`source case "${label}" changed nothing: update the test`);
  writeFileSync(p, changed);
  return spawnSync('node', ['script/check-surface-exchange.mjs'], { encoding: 'utf8', env: { ...process.env, EXCHANGE_SRC: p } });
};

const without = (name) => abi.filter((f) => f.name !== name);
const ABI_MUST_FAIL = [
  ['r6 matchOrders without signatures (0x2399e413) alongside the real one', [...abi, fn('matchOrders', [order, { name: 'm', type: 'tuple[]', components: order.components }, { name: 'f', type: 'uint128[]' }, { name: 't', type: 'uint128' }])], 'overloaded'],
  ['any other matchOrders overload', [...abi, fn('matchOrders', [{ name: 'x', type: 'bytes32' }])], 'matchOrders(bytes32)'],
  ['matchOrders removed', without('matchOrders'), 'allowlisted function missing from the contract: matchOrders'],
  ['matchOrders with a changed signature', abi.map((f) => (f.name === 'matchOrders' ? { ...f, inputs: f.inputs.slice(0, 3) } : f)), 'a matchOrders other than'],
  ['isValidOrderSignature removed', without('isValidOrderSignature'), 'isValidOrderSignature'],
  ['cancelOrders given a second argument', abi.map((f) => (f.name === 'cancelOrders' ? { ...f, inputs: [...f.inputs, { name: 'x', type: 'uint256' }] } : f)), 'cancelOrders'],
  ['a new function that takes an Order', [...abi, fn('quote', [order], 'view')], 'takes a tuple'],
  ['a new writer', [...abi, fn('sweep', [])], 'sweep()'],
  ['a new setter for a market term', [...abi, fn('setFeeRate', [{ name: 'r', type: 'uint16' }])], 'setFeeRate(uint16)'],
  ['a view turned into a writer', abi.map((f) => (f.name === 'feeOf' ? { ...f, stateMutability: 'nonpayable' } : f)), 'feeOf(uint256,uint256,uint256) is nonpayable'],
  ['a writer turned into a view', abi.map((f) => (f.name === 'deposit' ? { ...f, stateMutability: 'view' } : f)), 'deposit(uint256) is view'],
  ['a payable function', abi.map((f) => (f.name === 'deposit' ? { ...f, stateMutability: 'payable' } : f)), 'payable'],
  ['a receive function', [...abi, { type: 'receive', stateMutability: 'payable' }], 'fallback or receive'],
  ['a fallback function', [...abi, { type: 'fallback', stateMutability: 'nonpayable' }], 'fallback or receive'],
  ['setOrderSigner removed (the registered signer, plan 4.5, is built)', without('setOrderSigner'), 'allowlisted function missing from the contract: setOrderSigner(address)'],
  ['orderSigner view removed', without('orderSigner'), 'allowlisted function missing from the contract: orderSigner(address)'],
  ['setOrderSigner turned into a view', abi.map((f) => (f.name === 'setOrderSigner' ? { ...f, stateMutability: 'view' } : f)), 'setOrderSigner(address) is view'],
  ['an orderSigner overload', [...abi, fn('orderSigner', [{ name: 'a', type: 'address' }, { name: 'b', type: 'uint256' }], 'view')], 'overloaded'],
  ['the OrderSignerSet event removed', abi.filter((x) => !(x.type === 'event' && x.name === 'OrderSignerSet')), 'event missing: OrderSignerSet'],
  ['the OrderSignerSet event with a changed shape', abi.map((x) => (x.type === 'event' && x.name === 'OrderSignerSet' ? { ...x, inputs: x.inputs.map((i) => ({ ...i, indexed: false })) } : x)), 'OrderSignerSet(address indexed,address indexed) missing or changed'],
  ['a function overload of an allowlisted name', [...abi, fn('withdraw', [{ name: 'to', type: 'address' }])], 'overloaded'],
  ['a custom error removed', abi.filter((x) => !(x.type === 'error' && x.name === 'SetPriceSum')), 'custom error missing: SetPriceSum'],
  ['a new custom error', [...abi, { type: 'error', name: 'Surprise', inputs: [] }], 'custom error not on the allowlist: Surprise'],
  ['an event removed', abi.filter((x) => !(x.type === 'event' && x.name === 'Leaf')), 'event missing: Leaf'],
  ['an upgrade hook', [...abi, fn('upgradeTo', [{ name: 'a', type: 'address' }])], 'upgradeTo(address)'],
];

const SRC_MUST_FAIL = [
  ['a second function gated on isOperator[msg.sender]', (s) => s.replace('function incrementNonce() external {', 'function incrementNonce() external {\n        require(isOperator[msg.sender]);'), 'exactly once'],
  ['an operator modifier', (s) => s.replace('modifier nonReentrant() {', 'modifier onlyOperator() {\n        _;\n    }\n\n    modifier nonReentrant() {'), 'operator modifier'],
  ['delegatecall', (s) => s.replace('function _pk(', 'function _x(address a) internal {\n        a.delegatecall("");\n    }\n\n    function _pk('), 'delegatecall'],
  ['selfdestruct', (s) => s.replace('function _pk(', 'function _x() internal {\n        selfdestruct(payable(msg.sender));\n    }\n\n    function _pk('), 'selfdestruct'],
  ['fees to a caller-chosen address', (s) => s.replace('_safeTransferOut(TREASURY, amount);', '_safeTransferOut(msg.sender, amount);'), 'withdrawTreasury'],
  ['TREASURY no longer immutable', (s) => s.replace('address public immutable TREASURY;', 'address public TREASURY;'), 'TREASURY is not declared'],
  ['a third transfer out', (s) => s.replace('function _pk(', 'function _x(address a) internal {\n        _safeTransferOut(a, 1);\n    }\n\n    function _pk('), '_safeTransferOut must be called exactly twice'],
  ['the fee rate written after creation', (s) => s.replace('function incrementNonce() external {', 'function incrementNonce() external {\n        _markets[1].feeRate = 0;'), 'feeRate is written outside createMarket'],
  // adversary pass 1: the same writes through a storage alias of the market, and the other write forms
  ['market terms rewritten through a storage alias', (s) => s.replace('        mk.hasProposal = true;', '        MarketS storage x = mk;\n        x.feeRate = 0;\n        x.positionCap = 1;\n        x.nOptions = 2;\n        mk.hasProposal = true;'), 'feeRate is written outside createMarket'],
  ['the position cap raised with a compound assignment through an alias', (s) => s.replace('        mk.hasProposal = true;', '        MarketS storage y = _markets[m];\n        y.positionCap += 1;\n        mk.hasProposal = true;'), 'positionCap is written outside createMarket'],
  ['the option count incremented', (s) => s.replace('        mk.hasProposal = true;', '        ++mk.nOptions;\n        mk.hasProposal = true;'), 'nOptions is written outside createMarket'],
  ['the rules hash deleted', (s) => s.replace('        mk.hasProposal = true;', '        delete mk.rulesHash;\n        mk.hasProposal = true;'), 'rulesHash is written outside createMarket'],
  ['the Plan fee rate copied from a market pointer named p', (s) => s.replace('        mk.hasProposal = true;', '        MarketS storage p = mk;\n        mk.hasProposal = true;'), 'storage pointer named `p`'],
  ['a whole market struct overwritten', (s) => s.replace('function incrementNonce() external {', 'function incrementNonce() external {\n        _markets[1] = _markets[2];'), 'whole market struct'],
  ['an assembly sstore', (s) => s.replace('function incrementNonce() external {', 'function incrementNonce() external {\n        assembly { sstore(0, 0) }'), 'assembly sstore'],
  ['tradingClose written outside closeEarly', (s) => s.replace('function incrementNonce() external {', 'function incrementNonce() external {\n        _markets[1].tradingClose = type(uint64).max;'), 'tradingClose is written outside'],
  ['closeEarly allowed to move tradingClose later', (s) => s.replace('if (block.timestamp < mk.tradingClose) {', 'if (block.timestamp != mk.tradingClose) {'), 'closeEarly must only move'],
  ['the bounded owner check removed from the source', (s) => s.split('_boundedIsOwner').join('_boundedXOwner'), '_boundedIsOwner is missing'],
  ['a second isOwner call site', (s) => s.replace('function _pk(', 'function _x() internal {\n        bytes4 q = 0x2f54bf6e;\n        q;\n    }\n\n    function _pk('), '0x2f54bf6e must appear exactly once'],
  ['SIG_GAS changed', (s) => s.replace('SIG_GAS = 100_000;', 'SIG_GAS = 120_000;'), 'SIG_GAS must be'],
  ['MAX_SIG_LEN changed', (s) => s.replace('MAX_SIG_LEN = 195;', 'MAX_SIG_LEN = 196;'), 'MAX_SIG_LEN must be'],
  ['MAX_MAKERS changed', (s) => s.replace('MAX_MAKERS = 10;', 'MAX_MAKERS = 11;'), 'MAX_MAKERS must be'],
  ['a different EIP-712 domain', (s) => s.replace('EIP712("Mako Market Exchange", "1")', 'EIP712("Mako Market Exchange", "2")'), 'EIP-712 domain'],
  ['a native value transfer', (s) => s.replace('function _pk(', 'function _x(address a) internal {\n        payable(a).transfer(1);\n    }\n\n    function _pk('), 'native-value'],
];

let failed = 0;
const check = (label, r, expect) => {
  const ok = r.status !== 0 && (r.stderr + r.stdout).includes(expect);
  console.log(`${ok ? 'ok  ' : 'FAIL'} refuses ${label}`);
  if (!ok) {
    failed++;
    console.log(r.stdout, r.stderr);
  }
};
for (const [label, a, expect] of ABI_MUST_FAIL) check(label, runAbi(label, a), expect);
for (const [label, mutate, expect] of SRC_MUST_FAIL) check(label, runSrc(label, mutate), expect);

const real = runAbi('the compiled ABI', abi);
const realOk = real.status === 0;
console.log(`${realOk ? 'ok  ' : 'FAIL'} accepts the compiled ABI`);
if (!realOk) {
  failed++;
  console.log(real.stdout, real.stderr);
}
const realFull = spawnSync('node', ['script/check-surface-exchange.mjs'], { encoding: 'utf8' });
console.log(`${realFull.status === 0 ? 'ok  ' : 'FAIL'} accepts the compiled contract and its source`);
if (realFull.status !== 0) {
  failed++;
  console.log(realFull.stdout, realFull.stderr);
}
rmSync(dir, { recursive: true, force: true });
if (failed) {
  console.error(`\n${failed} surface-gate case(s) wrong`);
  process.exit(1);
}
