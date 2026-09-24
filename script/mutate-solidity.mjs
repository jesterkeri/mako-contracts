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
const DEFAULT_REL = 'src/RoundSettlement.sol';
const DEFAULT_MATCH = 'RoundSettlementTest';

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
  // ---- slice 1 of MakoRoundsV1: the guards the library deliberately cannot make ----
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: allow settlement before closeTime',
    clause: 'SPEC 3 lifecycle',
    from: 'if (block.timestamp < closeTime) revert TooEarlyToSettle();',
    to: '// mutated: early-settlement guard removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: allow settlement at or after submitDeadline',
    clause: 'N13',
    from: 'if (block.timestamp >= closeTime + SUBMIT_WINDOW) revert SubmitWindowClosed();',
    to: '// mutated: submit-window guard removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: allow a round to settle twice',
    clause: 'SPEC 3 terminal states',
    from: 'if (r.status != Status.Active) revert RoundAlreadyTerminal(); // settlement guard',
    to: '// mutated: terminal-state guard removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: check the anchor against closeTime instead of startTime',
    clause: 'N25',
    from: 'RoundSettlement.check(anchorReport, uint32(r.startTime));',
    to: 'RoundSettlement.check(anchorReport, uint32(closeTime));',
    note: 'The anchor boundary IS the no-insider-entry property. If the anchor could be observed at closeTime, an entrant could act on a price they had seen.',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: check the close against startTime instead of closeTime',
    clause: 'N1',
    from: 'RoundSettlement.check(closeReport, uint32(closeTime));',
    to: 'RoundSettlement.check(closeReport, uint32(r.startTime));',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: invert the outcome direction',
    clause: 'SPEC 5.3',
    from: 'Outcome outcome = close.price > anchor.price ? Outcome.Up : Outcome.Down;',
    to: 'Outcome outcome = close.price > anchor.price ? Outcome.Down : Outcome.Up;',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: settle a tie as UP instead of refunding',
    clause: 'SPEC 5.3',
    from: 'if (close.price == anchor.price) {',
    to: 'if (false) {',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: drop the whole-minute boundary requirement',
    clause: 'N27',
    from: 'if (startTime % BOUNDARY_STEP != 0) revert StartTimeNotOnBoundary();',
    to: '// mutated: minute-boundary requirement removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: drop the creator allowlist',
    clause: 'SPEC 8',
    from: 'if (!_isCreator[msg.sender]) revert NotACreator();',
    to: '// mutated: creator allowlist removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: drop the per-creator active-round limit',
    clause: 'SPEC 4',
    from: 'if (creatorActiveRound[msg.sender] != 0) revert CreatorHasActiveRound();',
    to: '// mutated: per-creator limit removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: drop the global active-round cap',
    clause: 'SPEC 4, MAX_ACTIVE_ROUNDS',
    from: 'if (_activeIds.length >= MAX_ACTIVE_ROUNDS) revert TooManyActiveRounds();',
    to: '// mutated: global cap removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: drop the minimum scheduling lead',
    clause: 'SPEC 4, MIN_LEAD',
    from: 'if (startTime < openTime + MIN_LEAD) revert LeadTooShort();',
    to: '// mutated: MIN_LEAD removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: lock entries at startTime instead of ENTRY_LEAD before it',
    clause: 'N2, N25',
    from: 'if (block.timestamp >= r.startTime - ENTRY_LEAD) return Phase.Locked;',
    to: 'if (block.timestamp >= r.startTime) return Phase.Locked;',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: drop the strictly-ascending creator rule',
    clause: 'CREATORS_HASH canonicality',
    from: 'if (uint160(c) <= uint160(previous)) revert CreatorsNotStrictlyAscending();',
    to: '// mutated: creator ordering, duplicate and zero-address rule removed',
    note: 'One rule carries three properties: a canonical encoding so CREATORS_HASH identifies a set, no duplicates, and no zero address.',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: accept a zero treasury',
    clause: 'SPEC 4, TREASURY',
    from: 'if (treasury == address(0)) revert ZeroAddress();',
    to: '// mutated: zero-treasury guard removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: accept an empty creator set',
    clause: 'SPEC 8',
    from: 'if (creators.length == 0) revert NoCreators();',
    to: '// mutated: empty creator set allowed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: allow entry into a terminal round',
    clause: 'SPEC 3 terminal states',
    from: 'if (r.status != Status.Active) revert RoundAlreadyTerminal(); // entry guard',
    to: '// mutated: entry terminal-state guard removed',
  },
  // ---- slice 2: entry, exact-token semantics, pools, fees ----
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: allow entry at or after entryCloseTime',
    clause: 'N2, N25',
    from: 'if (block.timestamp >= r.startTime - ENTRY_LEAD) revert EntriesClosed();',
    to: '// mutated: entry cutoff removed',
    note: 'The cutoff is what stops anyone entering once the anchor second is knowable.',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: drop the minimum entry',
    clause: 'SPEC 4, MIN_ENTRY',
    from: 'if (amount < MIN_ENTRY) revert BelowMinimumEntry();',
    to: '// mutated: minimum entry removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: let one address take both sides',
    clause: 'N12',
    from: 'if (stake.side != Side.None && stake.side != side) revert AlreadyOnTheOtherSide();',
    to: '// mutated: one-address-one-side rule removed',
    note: 'The structural control against creator self-filling. No fee formula substitutes for it.',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: credit the requested amount rather than what arrived',
    clause: 'N22',
    from: 'if (received != amount) revert InexactTransfer(amount, received);',
    to: '// mutated: exact-balance check removed',
    note: 'Without this a fee-on-transfer token credits a stake the contract does not hold, and the shortfall surfaces much later as a claim that cannot be paid.',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: accept >= instead of == on the balance delta',
    clause: 'N22',
    from: 'if (received != amount) revert InexactTransfer(amount, received);',
    to: 'if (received < amount) revert InexactTransfer(amount, received);',
    note: 'The overshoot case: a >= check credits `amount` while the contract holds more, turning the surplus into dust nobody accounted for.',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: ignore a false or malformed transfer return',
    clause: 'N22',
    from: 'if (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool)))) revert TransferFailed(); // inbound',
    to: '// mutated: inbound transfer return value ignored',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: allow a one-sided round to settle',
    clause: 'N3, SPEC 5.2 per-submission, SPEC.md:135',
    from: 'if (r.upPool == 0 || r.downPool == 0) revert RoundIsOneSided();',
    to: '// mutated: one-sided guard removed',
    note: 'This is also what keeps settle and finalizeRefund(OneSided) mutually exclusive.',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: charge the protocol fee on the smaller side instead of the total',
    clause: 'SPEC 7',
    from: 'uint256 protocolFee = (total * PROTOCOL_FEE_BPS) / 10_000;',
    to: 'uint256 protocolFee = (smaller * PROTOCOL_FEE_BPS) / 10_000;',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: charge the creator fee on the total instead of the smaller side',
    clause: 'SPEC 7',
    from: 'uint256 creatorFee = (smaller * CREATOR_FEE_BPS) / 10_000;',
    to: 'uint256 creatorFee = (total * CREATOR_FEE_BPS) / 10_000;',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: leave the fees inside distributable',
    clause: 'SPEC 7 conservation',
    from: 'r.distributable = total - protocolFee - creatorFee;',
    to: 'r.distributable = total;',
    note: 'Breaks conservation: fees plus distributable would exceed the pot.',
  },
  // ---- slice 3: every path by which money leaves ----
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: refund a two-sided round as OneSided',
    clause: 'N3, settle/refund exclusivity',
    from: 'if (block.timestamp >= r.startTime - ENTRY_LEAD && (r.upPool == 0 || r.downPool == 0)) {',
    to: 'if (block.timestamp >= r.startTime - ENTRY_LEAD) {',
    note: 'Would let a round that could settle be refunded instead, reopening the race SPEC.md:135 closes.',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: allow NoPrice before submitDeadline',
    clause: 'N5, N13',
    from: '} else if (block.timestamp >= r.startTime + DURATION + SUBMIT_WINDOW) {',
    to: '} else if (block.timestamp >= r.startTime + DURATION) {',
    note: 'Overlaps the settle window, so a refund could pre-empt a valid settlement.',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: allow finalizeRefund on a terminal round',
    clause: 'SPEC 3 terminal states',
    from: 'if (r.status != Status.Active) revert RoundAlreadyTerminal(); // refund guard',
    to: '// mutated: refund terminal guard removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: allow claiming before a terminal state',
    clause: 'N6',
    from: 'if (r.status != Status.Settled && r.status != Status.Refunded) revert RoundNotTerminal();',
    to: '// mutated: terminal requirement on claim removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: pay any entrant as if they won',
    clause: 'SPEC 7, losers receive nothing',
    from: '} else if (stake.side == (r.outcome == Outcome.Up ? Side.Up : Side.Down)) {',
    to: '} else if (true) {',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: never mark a stake claimed',
    clause: 'N19 no double claim',
    from: '                stakePart = (stake.amount * r.distributable) / winningPool;\n                _stakeClaimed[roundId][msg.sender] = true;',
    to: '                stakePart = (stake.amount * r.distributable) / winningPool;',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: never mark the creator fee claimed',
    clause: 'N19 creator fee once',
    from: '            _creatorFeeClaimed[roundId] = true;',
    to: '            // mutated: creator fee flag removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: pay the creator fee on a refunded round',
    clause: 'N19 fees only on SETTLED',
    from: 'if (r.status == Status.Settled && msg.sender == r.creator && !_creatorFeeClaimed[roundId]) {',
    to: 'if (msg.sender == r.creator && !_creatorFeeClaimed[roundId]) {',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: sweep the remainder on the first winner, not the last',
    clause: 'N17',
    from: 'if (++r.winnersClaimed == winners) {',
    to: 'if (++r.winnersClaimed >= 1) {',
    note: 'Sweeps before the others have claimed, so later winners cannot be paid.',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: pay winners from the total instead of distributable',
    clause: 'SPEC 7, N17',
    from: 'stakePart = (stake.amount * r.distributable) / winningPool;',
    to: 'stakePart = (stake.amount * (r.upPool + r.downPool)) / winningPool;',
    note: 'Pays the fees out to winners and breaks conservation.',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: let anyone withdraw the treasury',
    clause: 'N19',
    from: 'if (msg.sender != TREASURY) revert NotTreasury();',
    to: '// mutated: treasury-only removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: do not zero the treasury balance on withdrawal',
    clause: 'N17, double spend',
    from: '        treasuryBalance = 0;\n        _safeTransferOut(TREASURY, amount);',
    to: '        _safeTransferOut(TREASURY, amount);',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: ignore an outbound shortfall',
    clause: 'N8, N17',
    from: 'if (sent != amount) revert InexactTransfer(amount, sent);',
    to: '// mutated: outbound balance check removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: remove the reentrancy guard',
    clause: 'N8',
    from: 'if (_lock != 1) revert Reentrancy();',
    to: '// mutated: reentrancy guard removed',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: do not accrue the protocol fee to the treasury',
    clause: 'N17, N19',
    from: 'treasuryBalance += protocolFee;',
    to: '// mutated: protocol fee accrual removed',
  },
  // ---- adversarial review fixes ----
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: list rounds before closeTime as pending',
    clause: 'SPEC 5.1',
    from: 'block.timestamp >= closeTime && block.timestamp < closeTime + SUBMIT_WINDOW && r.upPool != 0',
    to: 'block.timestamp < closeTime + SUBMIT_WINDOW && r.upPool != 0',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: list rounds past submitDeadline as pending',
    clause: 'SPEC 5.1',
    from: 'block.timestamp >= closeTime && block.timestamp < closeTime + SUBMIT_WINDOW && r.upPool != 0',
    to: 'block.timestamp >= closeTime && r.upPool != 0',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: list one-sided rounds as pending',
    clause: 'SPEC 5.1, SPEC.md:135',
    from: '&& r.downPool != 0\n            ) buf[k++] = id;',
    to: '\n            ) buf[k++] = id;',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: drop the tie evidence event',
    clause: 'SPEC 5.3, N14',
    from: '            emit RoundTied(',
    to: '            if (false) emit RoundTied(',
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: remove the reentrancy guard from settle',
    clause: 'N8, double settlement',
    from: 'bytes calldata closeReport) external nonReentrant {\n        _settle(',
    to: 'bytes calldata closeReport) external {\n        _settle(',
    note: "A verifier re-entering settle would run a full inner settlement under the outer call's passed status check.",
  },
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: forget to remove a round from the active index',
    clause: 'SPEC 4, MAX_ACTIVE_ROUNDS, SPEC 5.1',
    from: '        _activeIds.pop();',
    to: '        // mutated: pop removed',
  },
  // ---- Codex diff review r1 fixes ----
  {
    file: 'src/MakoRoundsV1.sol', match: 'MakoRoundsV1Test|AdversaryTest',
    name: 'rounds: accept a start time whose close boundary overflows uint32',
    clause: 'SPEC 5.2 boundary representation',
    from: 'if (startTime > type(uint32).max - DURATION) revert StartTimeOutOfRange();',
    to: '// mutated: uint32 bound removed',
    note: 'An unserviceable round would be accepted and forced onto NoPrice a day later.',
  },
];

const sources = new Map();
function sourceOf(rel) {
  if (!sources.has(rel)) sources.set(rel, readFileSync(join(REPO, rel), 'utf8'));
  return sources.get(rel);
}

let notKilled = 0;
const results = [];

console.log(`Mutation run: ${MUTATIONS.length} mutations\n`);

for (const m of MUTATIONS) {
  const rel = m.file || DEFAULT_REL;
  const match = m.match || DEFAULT_MATCH;
  const original = sourceOf(rel);
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
    writeFileSync(join(dir, rel), original.replace(m.from, m.to));

    let out = '', failed = false, compileError = false;
    try {
      out = execFileSync('forge', ['test', '--root', dir, '--match-contract', match], {
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

// The working tree must be untouched. Asserted rather than assumed, for every file touched.
for (const [rel, before] of sources) {
  if (readFileSync(join(REPO, rel), 'utf8') !== before) {
    console.error(`\n  FATAL: ${rel} differs from where it started. Restore it before continuing.`);
    process.exit(2);
  }
}

const killed = results.filter((r) => r.status.startsWith('KILLED')).length;
console.log(`\n  ${killed} killed, ${notKilled} not killed`);
console.log(`  every mutated file is byte-identical to where it started; all mutations ran on temp copies.`);
if (notKilled > 0) {
  console.log(`\n  A surviving mutation is a missing test, not a passing run.`);
  process.exit(1);
}
console.log(`\n  Every mutated clause is load-bearing: SPEC 5.2 in the library, and the round-level`);
console.log(`  guards the library cannot make in MakoRoundsV1.`);
