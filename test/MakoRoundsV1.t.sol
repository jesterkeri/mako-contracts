// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MakoRoundsV1} from "../src/MakoRoundsV1.sol";
import {MakoRoundsV1Harness} from "./MakoRoundsV1Harness.sol";
import {RoundSettlement} from "../src/RoundSettlement.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";
import {
    MockUSDC,
    NoReturnUSDC,
    FalseReturnUSDC,
    RevertingUSDC,
    FeeOnTransferUSDC,
    MalformedReturnUSDC,
    OvershootUSDC,
    ShortTransferUSDC,
    ReentrantUSDC
} from "./mocks/TokenMocks.sol";

/// @notice Slice 1: the round lifecycle and permissionless settlement. No money anywhere.
///
/// @dev These tests exist for the properties `RoundSettlement` DELIBERATELY CANNOT HAVE. The library
/// sees one report and one boundary, so it cannot know which boundary belongs to this round, whether
/// settlement is early, whether the round already settled, or what time it is relative to the
/// observation. Each of those is a property of a round, so each is tested here.
contract MakoRoundsV1Test is Test {
    MakoRoundsV1 internal rounds;
    MockVerifier internal mock;
    MockUSDC internal usdc;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    address internal constant VERIFIER = 0x72790f9eB82db492a7DDb6d2af22A270Dcc3Db64;
    address internal constant TREASURY = address(0x7777);
    address internal creator = address(0xC1);
    address internal outsider = address(0x0FF);

    /// @dev A whole minute, so it is a legal `startTime` with no adjustment. 1789500000 % 60 == 0.
    uint64 internal constant BASE = 1789500000;

    uint64 internal startTime;
    uint64 internal closeTime;
    uint64 internal submitDeadline;
    uint256 internal roundId;

    uint256 internal constant MAX_CREATORS = 11;

    function setUp() public {
        vm.warp(BASE);

        usdc = new MockUSDC();

        address[] memory creators = new address[](1);
        creators[0] = creator;
        rounds = new MakoRoundsV1(TREASURY, address(usdc), creators);

        address[3] memory funded = [alice, bob, creator];
        for (uint256 i = 0; i < funded.length; i++) {
            usdc.mint(funded[i], 1_000_000_000);
            vm.prank(funded[i]);
            usdc.approve(address(rounds), type(uint256).max);
        }

        MockVerifier template = new MockVerifier();
        vm.etch(VERIFIER, address(template).code);
        mock = MockVerifier(VERIFIER);

        startTime = BASE + 3600;
        closeTime = startTime + 900;
        submitDeadline = closeTime + 24 hours;

        vm.prank(creator);
        roundId = rounds.schedule(startTime);
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev A well-formed 288-byte v3 payload. `bid == price == ask` gives a zero spread, so these
    /// reports differ from a passing one only in the field a given test is exercising.
    function _payload(uint32 observedAt, int192 price) internal pure returns (bytes memory) {
        return abi.encode(
            RoundSettlement.FEED_ID,
            uint32(observedAt), // validFromTimestamp
            uint32(observedAt), // observationsTimestamp
            uint192(0), // nativeFee, checked by nothing
            uint192(0), // linkFee, checked by nothing
            uint32(observedAt) + 30 days, // expiresAt
            price,
            price, // bid
            price // ask
        );
    }

    /// @dev Arms the mock so `submitted` verifies to a report observed at `observedAt` with `price`.
    function _arm(bytes memory submitted, uint32 observedAt, int192 price) internal {
        mock.setReturnFor(submitted, _payload(observedAt, price));
    }

    function _anchorBytes() internal pure returns (bytes memory) {
        return hex"a0a0a0";
    }

    function _closeBytes() internal pure returns (bytes memory) {
        return hex"c0c0c0";
    }

    /// @dev Arms both reports at their correct boundaries and warps to a settleable moment.
    /// @dev It also makes the round TWO-SIDED, because `SPEC.md:135` forbids settling a one-sided
    /// round at all. Every settlement test therefore needs both pools funded, which is itself worth
    /// noticing: after slice 2, "can this round settle" is no longer a question about reports alone.
    function _armHappyPath(int192 anchorPrice, int192 closePrice) internal {
        _twoSided();
        _arm(_anchorBytes(), uint32(startTime), anchorPrice);
        _arm(_closeBytes(), uint32(closeTime), closePrice);
        vm.warp(closeTime);
    }

    /// @dev Funds both sides of the round created in `setUp`, while entries are still open.
    function _twoSided() internal {
        uint256 t = block.timestamp;
        vm.warp(BASE);
        vm.prank(alice);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 10_000_000);
        vm.prank(bob);
        rounds.enter(roundId, MakoRoundsV1.Side.Down, 30_000_000);
        vm.warp(t);
    }

    // ---------------------------------------------------------------------------------------------
    // scheduling
    // ---------------------------------------------------------------------------------------------

    /// @notice N27: `schedule` reverts unless `startTime` is a whole minute. Asserted at ±1 second.
    function test_StartTimeOnMinute() public {
        uint64 onMinute = BASE + 7200;
        assertEq(onMinute % 60, 0, "test setup is not on a minute");

        vm.prank(creator);
        vm.expectRevert(MakoRoundsV1.StartTimeNotOnBoundary.selector);
        rounds.schedule(onMinute - 1);

        vm.prank(creator);
        vm.expectRevert(MakoRoundsV1.StartTimeNotOnBoundary.selector);
        rounds.schedule(onMinute + 1);
    }

    function test_OnlyCreatorsMaySchedule() public {
        vm.prank(outsider);
        vm.expectRevert(MakoRoundsV1.NotACreator.selector);
        rounds.schedule(BASE + 7200);
    }

    function test_LeadBoundsAreEnforcedAtTheBoundaryPlusMinusOne() public {
        // MIN_LEAD is 600 and the round in setUp already holds this creator's slot, so use a second
        // creator for these.
        address[] memory two = new address[](1);
        two[0] = outsider;
        MakoRoundsV1 fresh = new MakoRoundsV1(TREASURY, address(usdc), two);

        uint64 minOk = uint64(block.timestamp) + 600;
        minOk = minOk + (60 - (minOk % 60)) % 60; // round up to a minute

        vm.prank(outsider);
        vm.expectRevert(MakoRoundsV1.LeadTooShort.selector);
        fresh.schedule(minOk - 60);

        vm.prank(outsider);
        uint256 id = fresh.schedule(minOk);
        assertGt(id, 0);
    }

    function test_OneNonTerminalRoundPerCreator() public {
        vm.prank(creator);
        vm.expectRevert(MakoRoundsV1.CreatorHasActiveRound.selector);
        rounds.schedule(BASE + 7200);
    }

    function test_GlobalActiveRoundCapIsEnforced() public {
        address[] memory many = new address[](11);
        for (uint256 i = 0; i < 11; i++) {
            many[i] = address(uint160(0x1000 + i));
        }
        MakoRoundsV1 fresh = new MakoRoundsV1(TREASURY, address(usdc), many);

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(many[i]);
            fresh.schedule(uint64(BASE + 3600 + i * 60));
        }
        assertEq(fresh.activeRoundCount(), 10);

        vm.prank(many[10]);
        vm.expectRevert(MakoRoundsV1.TooManyActiveRounds.selector);
        fresh.schedule(BASE + 7200);
    }

    function test_SettlingFreesBothTheGlobalAndTheCreatorSlot() public {
        assertEq(rounds.activeRoundCount(), 1);
        assertEq(rounds.creatorActiveRound(creator), roundId);

        _armHappyPath(100e18, 101e18);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        assertEq(rounds.activeRoundCount(), 0, "global slot not released");
        assertEq(rounds.creatorActiveRound(creator), 0, "creator slot not released");

        vm.prank(creator);
        rounds.schedule(uint64(block.timestamp) + 3600 - ((uint64(block.timestamp) + 3600) % 60) + 60);
    }

    // ---------------------------------------------------------------------------------------------
    // phases
    // ---------------------------------------------------------------------------------------------

    function test_PhasesFollowTheClockWithoutATransaction() public {
        assertEq(uint256(rounds.phaseOf(roundId)), uint256(MakoRoundsV1.Phase.Open));

        vm.warp(startTime - 60 - 1);
        assertEq(uint256(rounds.phaseOf(roundId)), uint256(MakoRoundsV1.Phase.Open), "still open at T-61");

        vm.warp(startTime - 60);
        assertEq(uint256(rounds.phaseOf(roundId)), uint256(MakoRoundsV1.Phase.Locked), "locks at entryCloseTime");

        vm.warp(closeTime - 1);
        assertEq(uint256(rounds.phaseOf(roundId)), uint256(MakoRoundsV1.Phase.Locked));

        vm.warp(closeTime);
        assertEq(
            uint256(rounds.phaseOf(roundId)),
            uint256(MakoRoundsV1.Phase.AwaitingSettlement),
            "awaits settlement at closeTime"
        );
    }

    /// @notice N25: the anchor's boundary is `startTime`, which is `ENTRY_LEAD` after the last
    /// possible entry, so no entrant can have seen it.
    function test_AnchorSecondIsStartTime() public {
        _twoSided(); // SPEC.md:135 forbids settling a one-sided round at all
        assertEq(rounds.entryCloseTimeOf(roundId) + 60, startTime, "entries do not stop ENTRY_LEAD early");

        // A report observed one second either side of startTime is not this round's anchor.
        _arm(_anchorBytes(), uint32(startTime) + 1, 100e18);
        _arm(_closeBytes(), uint32(closeTime), 101e18);
        vm.warp(closeTime);
        vm.expectRevert(RoundSettlement.WrongObservationTime.selector);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        _arm(_anchorBytes(), uint32(startTime) - 1, 100e18);
        vm.expectRevert(RoundSettlement.WrongObservationTime.selector);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        // And specifically NOT closeTime. Without this the test passes even if the contract checks
        // the anchor against the wrong boundary entirely: an anchor armed at startTime +/- 1 is not
        // closeTime either, so it still reverts and the test still goes green. The 28-mutation run
        // found exactly that: "check the anchor against closeTime instead of startTime" was killed
        // by nine unrelated tests and never by this one, the test named for the property. A test
        // that cannot fail for the reason it exists is not testing that reason.
        _arm(_anchorBytes(), uint32(closeTime), 100e18);
        vm.expectRevert(RoundSettlement.WrongObservationTime.selector);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
    }

    function test_CloseSecondIsCloseTime() public {
        _twoSided(); // SPEC.md:135 forbids settling a one-sided round at all
        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime) + 1, 101e18);
        vm.warp(closeTime + 1);
        vm.expectRevert(RoundSettlement.WrongObservationTime.selector);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
    }

    // ---------------------------------------------------------------------------------------------
    // settlement timing, the guards the library cannot make
    // ---------------------------------------------------------------------------------------------

    function test_SettleRevertsBeforeCloseTime() public {
        _twoSided(); // SPEC.md:135 forbids settling a one-sided round at all
        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime), 101e18);

        vm.warp(closeTime - 1);
        vm.expectRevert(MakoRoundsV1.TooEarlyToSettle.selector);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        vm.warp(closeTime);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
        assertEq(uint256(rounds.phaseOf(roundId)), uint256(MakoRoundsV1.Phase.Settled));
    }

    /// @notice N13: `settle` reverts at or after `submitDeadline`, so the settle and NoPrice-refund
    /// windows never overlap.
    function test_SettleAndRefundWindowsDisjoint() public {
        _twoSided(); // SPEC.md:135 forbids settling a one-sided round at all
        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime), 101e18);

        vm.warp(submitDeadline - 1);
        uint256 snap = vm.snapshotState();
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
        assertEq(uint256(rounds.phaseOf(roundId)), uint256(MakoRoundsV1.Phase.Settled), "last settleable second");
        vm.revertToState(snap);

        vm.warp(submitDeadline);
        vm.expectRevert(MakoRoundsV1.SubmitWindowClosed.selector);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
    }

    function test_RoundSettlesAtMostOnce() public {
        _armHappyPath(100e18, 101e18);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        vm.expectRevert(MakoRoundsV1.RoundAlreadyTerminal.selector);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
    }

    function test_ARefundedRoundCannotThenSettle() public {
        _armHappyPath(100e18, 100e18); // a tie refunds
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
        assertEq(uint256(rounds.phaseOf(roundId)), uint256(MakoRoundsV1.Phase.Refunded));

        _arm(_closeBytes(), uint32(closeTime), 200e18);
        vm.expectRevert(MakoRoundsV1.RoundAlreadyTerminal.selector);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
    }

    function test_UnknownRoundReverts() public {
        vm.expectRevert(MakoRoundsV1.NoSuchRound.selector);
        rounds.settle(roundId + 999, _anchorBytes(), _closeBytes());
    }

    /// @notice A report whose observation is a FUTURE second is rejected on the public path, at the
    /// library's boundary check, as `WrongObservationTime`.
    /// @dev Renamed after the Codex diff review. It used to be called
    /// `test_ReportObservedInTheFutureIsRejected` and implied it proved the contract's
    /// `ObservationInFuture` guard, which it never reached: the boundary check fires first, and on this
    /// path the guard is unreachable. The name now says what the test actually shows. The guard itself
    /// is proven directly by `test_FutureObservationGuardRejectsDirectly`.
    function test_FutureBoundaryReportIsRejectedAtTheBoundaryCheck() public {
        _twoSided();
        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime) + 600, 101e18);
        vm.warp(closeTime);
        vm.expectRevert(RoundSettlement.WrongObservationTime.selector);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
    }

    /// @notice The retained future-observation guard, tested directly because no public path reaches it.
    /// @dev Either observation one second after `block.timestamp` is refused; both at exactly now pass.
    function test_FutureObservationGuardRejectsDirectly() public {
        address[] memory one = new address[](1);
        one[0] = creator;
        MakoRoundsV1Harness h = new MakoRoundsV1Harness(TREASURY, address(usdc), one);
        uint32 nowTs = uint32(block.timestamp);

        h.exposed_requireObservedBy(nowTs, nowTs);

        vm.expectRevert(MakoRoundsV1.ObservationInFuture.selector);
        h.exposed_requireObservedBy(nowTs + 1, nowTs);

        vm.expectRevert(MakoRoundsV1.ObservationInFuture.selector);
        h.exposed_requireObservedBy(nowTs, nowTs + 1);
    }

    /// @notice The stored report hash is SUBMITTED-CALLDATA provenance, not a canonical report id.
    /// @dev Two byte-distinct submissions that verify to the identical report settle a round identically
    /// but store different `anchorReportHash` values. The real-verifier version of this property is
    /// `test_UnusedSignaturePaddingIsMalleable` in the fork suite; this is the contract-level half, so a
    /// watchdog or indexer can never be written on the assumption that the hash identifies a report.
    function test_ReportHashIsSubmittedCalldataNotACanonicalId() public {
        _twoSided();
        bytes memory variant = hex"a0a0a1"; // a different byte string for the same verified anchor
        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(variant, uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime), 101e18);
        vm.warp(closeTime);

        uint256 snap = vm.snapshotState();
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
        MakoRoundsV1.Round memory a = rounds.roundOf(roundId);
        vm.revertToState(snap);
        rounds.settle(roundId, variant, _closeBytes());
        MakoRoundsV1.Round memory b = rounds.roundOf(roundId);

        assertEq(uint256(a.outcome), uint256(b.outcome), "same outcome");
        assertEq(a.anchorPrice, b.anchorPrice, "same verified anchor price");
        assertTrue(a.anchorReportHash != b.anchorReportHash, "different stored hash for the same verified report");
        assertEq(b.anchorReportHash, keccak256(variant), "the hash is of exactly what was submitted");
    }

    // ---------------------------------------------------------------------------------------------
    // outcome
    // ---------------------------------------------------------------------------------------------

    function test_OutcomeUpWhenCloseIsHigher() public {
        _armHappyPath(100e18, 100e18 + 1);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
        assertEq(uint256(rounds.roundOf(roundId).outcome), uint256(MakoRoundsV1.Outcome.Up));
    }

    function test_OutcomeDownWhenCloseIsLower() public {
        _armHappyPath(100e18, 100e18 - 1);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
        assertEq(uint256(rounds.roundOf(roundId).outcome), uint256(MakoRoundsV1.Outcome.Down));
    }

    function test_EqualPricesRefundAsTie() public {
        _armHappyPath(100e18, 100e18);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        MakoRoundsV1.Round memory r = rounds.roundOf(roundId);
        assertEq(uint256(r.outcome), uint256(MakoRoundsV1.Outcome.None), "a tie sets no outcome");
        assertEq(uint256(r.refundReason), uint256(MakoRoundsV1.RefundReason.Tie));
        assertEq(uint256(rounds.phaseOf(roundId)), uint256(MakoRoundsV1.Phase.Refunded));
    }

    /// @notice N14: every settlement stores and emits both prices, both observation seconds and both
    /// report hashes.
    function test_SettlementEmitsEvidence() public {
        _armHappyPath(100e18, 123e18);

        vm.expectEmit(true, false, false, true, address(rounds));
        emit MakoRoundsV1.RoundSettled(
            roundId,
            MakoRoundsV1.Outcome.Up,
            100e18,
            123e18,
            uint32(startTime),
            uint32(closeTime),
            keccak256(_anchorBytes()),
            keccak256(_closeBytes()),
            address(this)
        );
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        MakoRoundsV1.Round memory r = rounds.roundOf(roundId);
        assertEq(r.anchorPrice, 100e18);
        assertEq(r.closePrice, 123e18);
        assertEq(uint256(r.anchorObservedAt), uint256(startTime));
        assertEq(uint256(r.closeObservedAt), uint256(closeTime));
        assertEq(r.anchorReportHash, keccak256(_anchorBytes()));
        assertEq(r.closeReportHash, keccak256(_closeBytes()));
    }

    /// @notice N26: `settle` is callable by anyone and gives the caller no power over the result.
    function testFuzz_AnyCallerSameOutcome(address callerA, address callerB) public {
        vm.assume(callerA != address(0) && callerB != address(0) && callerA != callerB);

        _armHappyPath(100e18, 150e18);
        uint256 snap = vm.snapshotState();

        vm.prank(callerA);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
        MakoRoundsV1.Round memory a = rounds.roundOf(roundId);

        vm.revertToState(snap);

        vm.prank(callerB);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
        MakoRoundsV1.Round memory b = rounds.roundOf(roundId);

        assertEq(uint256(a.outcome), uint256(b.outcome), "the caller changed the outcome");
        assertEq(a.anchorPrice, b.anchorPrice);
        assertEq(a.closePrice, b.closePrice);
        assertEq(a.anchorReportHash, b.anchorReportHash);
        assertEq(a.closeReportHash, b.closeReportHash);
    }

    /// @notice Swapping the anchor and close reports must not settle the round.
    /// @dev FOUND BY THE FUZZER, not by me. `testFuzz_ArbitraryBytesCannotSettle` originally excluded
    /// each report only from its own slot, and its first counterexample was the two valid reports in
    /// each other's places. That is a plausible operator mistake as well as an attack, so it gets a
    /// named test rather than an `assume` that hides it. It is rejected on the boundary: a report
    /// observed at `closeTime` is not this round's anchor.
    function test_SwappedAnchorAndCloseReportsAreRejected() public {
        _armHappyPath(100e18, 101e18);

        vm.expectRevert(RoundSettlement.WrongObservationTime.selector);
        rounds.settle(roundId, _closeBytes(), _anchorBytes());

        assertEq(uint256(rounds.phaseOf(roundId)), uint256(MakoRoundsV1.Phase.AwaitingSettlement));
    }

    /// @notice A caller with any other bytes fails N1 rather than settling anything.
    function testFuzz_ArbitraryBytesCannotSettle(bytes calldata junkAnchor, bytes calldata junkClose) public {
        // Neither report in either slot. The swap is excluded here because it is a DIFFERENT
        // property with its own rejection path, tested by name above rather than assumed away.
        vm.assume(keccak256(junkAnchor) != keccak256(_anchorBytes()));
        vm.assume(keccak256(junkAnchor) != keccak256(_closeBytes()));
        vm.assume(keccak256(junkClose) != keccak256(_anchorBytes()));
        vm.assume(keccak256(junkClose) != keccak256(_closeBytes()));

        _armHappyPath(100e18, 101e18);

        // Unkeyed bytes fall through to the mock's empty canned return, which is not 288 bytes.
        vm.expectRevert(RoundSettlement.WrongSchema.selector);
        rounds.settle(roundId, junkAnchor, junkClose);

        assertEq(uint256(rounds.phaseOf(roundId)), uint256(MakoRoundsV1.Phase.AwaitingSettlement));
    }

    // ---------------------------------------------------------------------------------------------
    // the creator set, and its hash meaning something
    // ---------------------------------------------------------------------------------------------

    function _creators(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    function test_ConstructorRejectsZeroTreasury() public {
        address[] memory one = new address[](1);
        one[0] = creator;
        vm.expectRevert(MakoRoundsV1.ZeroAddress.selector);
        new MakoRoundsV1(address(0), address(usdc), one);
    }

    function test_ConstructorRejectsAnEmptyCreatorSet() public {
        vm.expectRevert(MakoRoundsV1.NoCreators.selector);
        new MakoRoundsV1(TREASURY, address(usdc), new address[](0));
    }

    /// @dev The zero address is excluded by the same strictly-greater comparison that forbids
    /// duplicates, since nothing is strictly greater than nothing at the start of the list.
    function test_ConstructorRejectsTheZeroAddressAsACreator() public {
        vm.expectRevert(MakoRoundsV1.CreatorsNotStrictlyAscending.selector);
        new MakoRoundsV1(TREASURY, address(usdc), _creators(address(0), address(0x2222)));
    }

    function test_ConstructorRejectsDuplicateCreators() public {
        vm.expectRevert(MakoRoundsV1.CreatorsNotStrictlyAscending.selector);
        new MakoRoundsV1(TREASURY, address(usdc), _creators(address(0x2222), address(0x2222)));
    }

    function test_ConstructorRejectsAnUnsortedCreatorSet() public {
        vm.expectRevert(MakoRoundsV1.CreatorsNotStrictlyAscending.selector);
        new MakoRoundsV1(TREASURY, address(usdc), _creators(address(0x3333), address(0x2222)));
    }

    /// @notice One authorised set has exactly one valid encoding, so its hash is canonical.
    /// @dev Without the ordering rule the same two creators in the other order would deploy fine and
    /// produce a DIFFERENT `CREATORS_HASH`, and a deployment receipt checked against that hash would
    /// prove nothing about which addresses were authorised.
    function test_CreatorsHashIsCanonicalForASet() public {
        address lo = address(0x2222);
        address hi = address(0x3333);

        MakoRoundsV1 a = new MakoRoundsV1(TREASURY, address(usdc), _creators(lo, hi));
        MakoRoundsV1 b = new MakoRoundsV1(TREASURY, address(usdc), _creators(lo, hi));
        assertEq(a.CREATORS_HASH(), b.CREATORS_HASH(), "the same set must hash the same");

        // The only other ordering of that set does not deploy at all, so no second hash exists.
        vm.expectRevert(MakoRoundsV1.CreatorsNotStrictlyAscending.selector);
        new MakoRoundsV1(TREASURY, address(usdc), _creators(hi, lo));

        assertTrue(a.isCreator(lo) && a.isCreator(hi));
        assertFalse(a.isCreator(outsider));
    }

    // ---------------------------------------------------------------------------------------------
    // capacity, as an operational constraint rather than a comment
    // ---------------------------------------------------------------------------------------------

    /// @notice Rounds that pass `submitDeadline` unsettled HOLD THEIR CAPACITY SLOTS, and with
    /// `MAX_ACTIVE_ROUNDS` of them nobody can schedule anything.
    ///
    /// @dev This is a real operational constraint, not a documentation note, so it is demonstrated
    /// rather than asserted in a comment. `finalizeRefund` (slice 3) is what frees a slot, and it is
    /// permissionless, so anyone can unblock the contract by spending the gas. Until slice 3 exists
    /// there is no way out at all, which is one reason slice 1 is not deployable on its own.
    ///
    /// It also bounds the damage: the cost of blocking scheduling is holding all
    /// `MAX_ACTIVE_ROUNDS` slots, and only the invited `CREATORS` can take a slot in the first place,
    /// so this is not open to the public. That is why the cap being provisional until T0.1c matters
    /// beyond throughput: it is also the size of this constraint.
    function test_StuckRoundsHoldCapacityUntilSomeoneRefundsThem() public {
        address[] memory many = new address[](MAX_CREATORS);
        for (uint256 i = 0; i < MAX_CREATORS; i++) {
            many[i] = address(uint160(0x2000 + i)); // strictly ascending
        }
        MakoRoundsV1 fresh = new MakoRoundsV1(TREASURY, address(usdc), many);

        uint64 st = BASE + 3600;
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(many[i]);
            fresh.schedule(st + uint64(i) * 60);
        }
        assertEq(fresh.activeRoundCount(), 10);

        // Every round sails past its submit deadline with nobody settling it.
        vm.warp(st + 10 * 60 + 900 + 24 hours + 1);

        // None of them can settle any more, so none of them can free its slot this way.
        vm.expectRevert(MakoRoundsV1.SubmitWindowClosed.selector);
        fresh.settle(1, _anchorBytes(), _closeBytes());

        // And scheduling is blocked for everyone, including the eleventh creator who did nothing.
        vm.prank(many[10]);
        vm.expectRevert(MakoRoundsV1.TooManyActiveRounds.selector);
        fresh.schedule(uint64(block.timestamp) + 3600 - (uint64(block.timestamp) + 3600) % 60 + 60);

        assertEq(fresh.activeRoundCount(), 10, "slots are still held");

        // SLICE 3: and anyone at all can now unjam it. `finalizeRefund` is permissionless, and it is
        // the ONLY thing that frees a slot from a round nobody settled, so the eleventh creator does
        // not have to wait for the ten who walked away.
        vm.prank(many[10]);
        fresh.finalizeRefund(1);
        assertEq(fresh.activeRoundCount(), 9, "one refund frees one slot");

        vm.prank(many[10]);
        fresh.schedule(uint64(block.timestamp) + 3600 - (uint64(block.timestamp) + 3600) % 60 + 60);
        assertEq(fresh.activeRoundCount(), 10);
    }

    // ---------------------------------------------------------------------------------------------
    // slice 2: entry
    // ---------------------------------------------------------------------------------------------

    function test_EntryRecordsStakeAndPool() public {
        vm.prank(alice);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 5_000_000);

        MakoRoundsV1.Stake memory st = rounds.stakeOf(roundId, alice);
        assertEq(uint256(st.side), uint256(MakoRoundsV1.Side.Up));
        assertEq(st.amount, 5_000_000);

        MakoRoundsV1.Round memory r = rounds.roundOf(roundId);
        assertEq(r.upPool, 5_000_000);
        assertEq(r.downPool, 0);
        assertEq(r.upEntrants, 1);
        assertEq(usdc.balanceOf(address(rounds)), 5_000_000, "the contract holds exactly the stake");
    }

    function test_TopUpOnTheSameSideAddsAndDoesNotDoubleCountTheEntrant() public {
        vm.startPrank(alice);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 5_000_000);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 3_000_000);
        vm.stopPrank();

        assertEq(rounds.stakeOf(roundId, alice).amount, 8_000_000);
        MakoRoundsV1.Round memory r = rounds.roundOf(roundId);
        assertEq(r.upPool, 8_000_000);
        assertEq(r.upEntrants, 1, "one address is one entrant however many times they top up");
    }

    /// @notice N12: a wallet that has entered one side cannot enter the other.
    /// @dev This is the structural control that makes creator self-filling pointless. No fee formula
    /// can do it, because the thin side carries the better payout, so the rule has to be on the
    /// wallet rather than on the price. V4 permits both sides; this deliberately does not inherit it.
    function test_OneAddressOneSide() public {
        vm.prank(alice);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 5_000_000);

        vm.prank(alice);
        vm.expectRevert(MakoRoundsV1.AlreadyOnTheOtherSide.selector);
        rounds.enter(roundId, MakoRoundsV1.Side.Down, 5_000_000);
    }

    /// @notice N2: entries revert at or after `entryCloseTime`, asserted at the boundary +/- 1.
    function test_EntryRevertsAtEntryClose() public {
        uint64 entryClose = startTime - 60;

        vm.warp(entryClose - 1);
        vm.prank(alice);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 1_000_000);

        vm.warp(entryClose);
        vm.prank(bob);
        vm.expectRevert(MakoRoundsV1.EntriesClosed.selector);
        rounds.enter(roundId, MakoRoundsV1.Side.Down, 1_000_000);
    }

    function test_EntryBelowTheMinimumReverts() public {
        vm.prank(alice);
        vm.expectRevert(MakoRoundsV1.BelowMinimumEntry.selector);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 99_999);

        vm.prank(alice);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 100_000);
    }

    function test_EntryWithNoSideReverts() public {
        vm.prank(alice);
        vm.expectRevert(MakoRoundsV1.InvalidSide.selector);
        rounds.enter(roundId, MakoRoundsV1.Side.None, 1_000_000);
    }

    // ---------------------------------------------------------------------------------------------
    // slice 2: N22, only exact USDC is credited
    // ---------------------------------------------------------------------------------------------

    function _roundsWith(MockUSDC token) internal returns (MakoRoundsV1 rr, uint256 id) {
        address[] memory cs = new address[](1);
        cs[0] = creator;
        rr = new MakoRoundsV1(TREASURY, address(token), cs);
        vm.prank(creator);
        id = rr.schedule(startTime);
        token.mint(alice, 1_000_000_000);
        vm.prank(alice);
        token.approve(address(rr), type(uint256).max);
    }

    /// @notice A token that takes a cut in transit must revert, not credit the full amount.
    /// @dev Without the exact-balance check the entrant is credited with what they asked for while
    /// the contract holds less, and the shortfall surfaces much later as a claim that cannot be paid.
    function test_FeeOnTransferTokenReverts() public {
        (MakoRoundsV1 rr, uint256 id) = _roundsWith(MockUSDC(address(new FeeOnTransferUSDC())));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MakoRoundsV1.InexactTransfer.selector, 1_000_000, 990_000));
        rr.enter(id, MakoRoundsV1.Side.Up, 1_000_000);
    }

    /// @notice And a token that credits MORE also reverts, which is why the check is `==` not `>=`.
    function test_OvershootingTokenReverts() public {
        (MakoRoundsV1 rr, uint256 id) = _roundsWith(MockUSDC(address(new OvershootUSDC())));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MakoRoundsV1.InexactTransfer.selector, 1_000_000, 1_000_001));
        rr.enter(id, MakoRoundsV1.Side.Up, 1_000_000);
    }

    function test_FalseReturningTokenReverts() public {
        (MakoRoundsV1 rr, uint256 id) = _roundsWith(MockUSDC(address(new FalseReturnUSDC())));
        vm.prank(alice);
        vm.expectRevert(MakoRoundsV1.TransferFailed.selector);
        rr.enter(id, MakoRoundsV1.Side.Up, 1_000_000);
    }

    function test_RevertingTokenReverts() public {
        (MakoRoundsV1 rr, uint256 id) = _roundsWith(MockUSDC(address(new RevertingUSDC())));
        vm.prank(alice);
        vm.expectRevert(MakoRoundsV1.TransferFailed.selector);
        rr.enter(id, MakoRoundsV1.Side.Up, 1_000_000);
    }

    /// @notice A malformed return fails with this contract's own error, not a bare decode panic.
    function test_MalformedReturnTokenReverts() public {
        (MakoRoundsV1 rr, uint256 id) = _roundsWith(MockUSDC(address(new MalformedReturnUSDC())));
        vm.prank(alice);
        vm.expectRevert(MakoRoundsV1.TransferFailed.selector);
        rr.enter(id, MakoRoundsV1.Side.Up, 1_000_000);
    }

    /// @notice A legacy token that returns nothing is ACCEPTED, because the balance check is what
    /// makes it safe rather than the return value.
    function test_NoReturnTokenIsAccepted() public {
        (MakoRoundsV1 rr, uint256 id) = _roundsWith(MockUSDC(address(new NoReturnUSDC())));
        vm.prank(alice);
        rr.enter(id, MakoRoundsV1.Side.Up, 1_000_000);
        assertEq(rr.stakeOf(id, alice).amount, 1_000_000);
    }

    /// @notice Tokens sent to the contract any other way are never credited to anyone.
    function test_StrayTransfersAreNeverCredited() public {
        usdc.mint(address(this), 50_000_000);
        usdc.transfer(address(rounds), 50_000_000);

        assertEq(usdc.balanceOf(address(rounds)), 50_000_000, "the tokens really did arrive");
        assertEq(rounds.roundOf(roundId).upPool, 0, "but no pool grew");
        assertEq(rounds.stakeOf(roundId, address(this)).amount, 0, "and nobody was credited");

        // And a later genuine entry still credits only its own amount.
        vm.prank(alice);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 1_000_000);
        assertEq(rounds.roundOf(roundId).upPool, 1_000_000);
    }

    // ---------------------------------------------------------------------------------------------
    // slice 2: fees and conservation
    // ---------------------------------------------------------------------------------------------

    /// @notice A one-sided round can never settle, whatever the price. N3, SPEC.md:135.
    function test_OneSidedRoundCannotSettle() public {
        vm.prank(alice);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 10_000_000);

        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime), 101e18);
        vm.warp(closeTime);

        vm.expectRevert(MakoRoundsV1.RoundIsOneSided.selector);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
    }

    /// @notice SPEC §7: protocol fee on the total, creator fee on the SMALLER side, both floored.
    function test_FeesFollowTheSpecFormula() public {
        _armHappyPath(100e18, 101e18); // up 10 USDC, down 30 USDC
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        MakoRoundsV1.Round memory r = rounds.roundOf(roundId);
        uint256 total = 40_000_000;
        uint256 smaller = 10_000_000;
        assertEq(r.protocolFee, total * 100 / 10_000, "1% of the total");
        assertEq(r.creatorFee, smaller * 200 / 10_000, "2% of the smaller side");
        assertEq(r.distributable, total - r.protocolFee - r.creatorFee);
    }

    /// @notice Nothing is created or destroyed: fees plus distributable equal the pot exactly.
    function testFuzz_SettlementConservesTheTotal(uint96 upAmount, uint96 downAmount) public {
        uint256 up = uint256(upAmount) % 1_000_000_000 + 100_000;
        uint256 down = uint256(downAmount) % 1_000_000_000 + 100_000;

        usdc.mint(alice, up);
        usdc.mint(bob, down);
        vm.prank(alice);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, up);
        vm.prank(bob);
        rounds.enter(roundId, MakoRoundsV1.Side.Down, down);

        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime), 101e18);
        vm.warp(closeTime);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        MakoRoundsV1.Round memory r = rounds.roundOf(roundId);
        assertEq(r.upPool + r.downPool, up + down, "pools must equal what was paid in");
        assertEq(
            r.protocolFee + r.creatorFee + r.distributable,
            up + down,
            "fees plus distributable must equal the total exactly"
        );
        assertEq(usdc.balanceOf(address(rounds)), up + down, "and the contract holds all of it");
    }

    /// @notice A refund charges nothing: no fee is accrued and the whole pot stays distributable to
    /// its owners. `sum(refunds) == total`.
    function test_ARefundChargesNoFees() public {
        _armHappyPath(100e18, 100e18); // a tie
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        MakoRoundsV1.Round memory r = rounds.roundOf(roundId);
        assertEq(uint256(r.refundReason), uint256(MakoRoundsV1.RefundReason.Tie));
        assertEq(r.protocolFee, 0, "a refund charges no protocol fee");
        assertEq(r.creatorFee, 0, "a refund charges no creator fee");
        assertEq(usdc.balanceOf(address(rounds)), r.upPool + r.downPool, "the whole pot is still here");
    }

    function test_EntryIntoATerminalRoundReverts() public {
        _armHappyPath(100e18, 101e18);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        vm.warp(BASE);
        vm.prank(alice);
        vm.expectRevert(MakoRoundsV1.RoundAlreadyTerminal.selector);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 1_000_000);
    }

    // ---------------------------------------------------------------------------------------------
    // slice 3: helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Settles the setUp round with alice UP 10 and bob DOWN 30, and UP winning.
    function _settleUpWins() internal {
        _armHappyPath(100e18, 101e18);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
    }

    // ---------------------------------------------------------------------------------------------
    // slice 3: finalizeRefund
    // ---------------------------------------------------------------------------------------------

    /// @notice N3: an empty side refunds as OneSided from entryCloseTime, whatever the price.
    /// Asserted at the boundary +/- 1.
    function test_OneSidedRefundsWithoutPrice() public {
        vm.prank(alice);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 10_000_000);

        uint64 entryClose = startTime - 60;
        vm.warp(entryClose - 1);
        vm.expectRevert(MakoRoundsV1.NotRefundableYet.selector);
        rounds.finalizeRefund(roundId);

        vm.warp(entryClose);
        rounds.finalizeRefund(roundId);

        MakoRoundsV1.Round memory r = rounds.roundOf(roundId);
        assertEq(uint256(r.refundReason), uint256(MakoRoundsV1.RefundReason.OneSided));
        assertEq(uint256(rounds.phaseOf(roundId)), uint256(MakoRoundsV1.Phase.Refunded));
    }

    /// @notice A two-sided round can NOT refund as OneSided, even after entries close. That is the
    /// other half of settle and finalizeRefund being mutually exclusive by condition.
    function test_TwoSidedRoundCannotRefundAsOneSided() public {
        _twoSided();
        vm.warp(closeTime);
        vm.expectRevert(MakoRoundsV1.NotRefundableYet.selector);
        rounds.finalizeRefund(roundId);
    }

    /// @notice N5: funds are never stuck past submitDeadline. NoPrice from submitDeadline, +/- 1.
    function test_FinalizeRefundAfterDeadline() public {
        _twoSided();

        vm.warp(submitDeadline - 1);
        vm.expectRevert(MakoRoundsV1.NotRefundableYet.selector);
        rounds.finalizeRefund(roundId);

        vm.warp(submitDeadline);
        rounds.finalizeRefund(roundId);
        assertEq(uint256(rounds.roundOf(roundId).refundReason), uint256(MakoRoundsV1.RefundReason.NoPrice));

        // And the money comes back.
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        rounds.claim(roundId);
        assertEq(usdc.balanceOf(alice) - before, 10_000_000, "exactly the stake, no fee");
    }

    function test_FinalizeRefundOnATerminalRoundReverts() public {
        _settleUpWins();
        vm.warp(submitDeadline);
        vm.expectRevert(MakoRoundsV1.RoundAlreadyTerminal.selector);
        rounds.finalizeRefund(roundId);
    }

    // ---------------------------------------------------------------------------------------------
    // slice 3: claim
    // ---------------------------------------------------------------------------------------------

    function test_WinnerIsPaidTheirShareOfDistributable() public {
        _settleUpWins();
        MakoRoundsV1.Round memory r = rounds.roundOf(roundId);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        rounds.claim(roundId);

        // alice is the only UP entrant, so her share is the whole of distributable.
        assertEq(usdc.balanceOf(alice) - before, r.distributable);
    }

    /// @notice A loser is owed nothing, and the call reverts rather than paying zero. SPEC §7.
    function test_LoserClaimReverts() public {
        _settleUpWins();
        vm.prank(bob);
        vm.expectRevert(MakoRoundsV1.NothingOwed.selector);
        rounds.claim(roundId);
    }

    /// @notice N19: nothing is paid twice.
    function test_NoDoubleClaim() public {
        _settleUpWins();
        vm.prank(alice);
        rounds.claim(roundId);

        vm.prank(alice);
        vm.expectRevert(MakoRoundsV1.NothingOwed.selector);
        rounds.claim(roundId);
    }

    function test_ClaimBeforeTerminalReverts() public {
        _twoSided();
        vm.warp(closeTime);
        vm.prank(alice);
        vm.expectRevert(MakoRoundsV1.RoundNotTerminal.selector);
        rounds.claim(roundId);
    }

    /// @notice N9: equality refunds as Tie, and the refund is exact.
    function test_TieRefunds() public {
        _armHappyPath(100e18, 100e18);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        uint256 a = usdc.balanceOf(alice);
        uint256 b = usdc.balanceOf(bob);
        vm.prank(alice);
        rounds.claim(roundId);
        vm.prank(bob);
        rounds.claim(roundId);

        assertEq(usdc.balanceOf(alice) - a, 10_000_000);
        assertEq(usdc.balanceOf(bob) - b, 30_000_000);
        assertEq(usdc.balanceOf(address(rounds)), 0, "a refunded round leaves nothing behind");
        assertEq(rounds.treasuryBalance(), 0, "and charges nothing");
    }

    // ---------------------------------------------------------------------------------------------
    // slice 3: fees
    // ---------------------------------------------------------------------------------------------

    /// @notice N19: fees are taken only on SETTLED.
    function test_FeesOnlyOnSettle() public {
        _armHappyPath(100e18, 100e18); // tie
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
        assertEq(rounds.treasuryBalance(), 0, "no protocol fee on a refund");

        vm.prank(creator);
        vm.expectRevert(MakoRoundsV1.NothingOwed.selector);
        rounds.claim(roundId); // no creator fee on a refund either
    }

    /// @notice N19: on a refunded round the creator is repaid their stake and NOTHING is recorded as
    /// a creator fee, because no fee exists.
    /// @dev FOUND BY THE MUTATION SWEEP. Dropping `r.status == Status.Settled` from the creator-fee
    /// condition survived every other test: a refunded round's `creatorFee` is always zero, so the
    /// mutant pays nothing extra and every balance stays right. But it still sets the creator-fee
    /// flag, so `creatorFeeClaimed` would tell clients and the watchdog a fee was claimed on a round
    /// that never had one. Balances were never the only thing that had to be true.
    function test_RefundRecordsNoCreatorFee() public {
        vm.warp(BASE);
        vm.prank(creator);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 10_000_000);
        vm.prank(bob);
        rounds.enter(roundId, MakoRoundsV1.Side.Down, 30_000_000);
        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime), 100e18); // tie
        vm.warp(closeTime);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        uint256 before = usdc.balanceOf(creator);
        vm.prank(creator);
        rounds.claim(roundId);

        assertEq(usdc.balanceOf(creator) - before, 10_000_000, "exactly the stake");
        assertFalse(rounds.creatorFeeClaimed(roundId), "no fee existed, so none may be recorded as claimed");
    }

    /// @notice N19: a creator with NO stake can still claim their fee, once.
    function test_ZeroStakeCreatorClaimsFee() public {
        _settleUpWins();
        uint256 fee = rounds.roundOf(roundId).creatorFee;
        assertGt(fee, 0);
        assertEq(rounds.stakeOf(roundId, creator).amount, 0, "the creator never entered");

        uint256 before = usdc.balanceOf(creator);
        vm.prank(creator);
        rounds.claim(roundId);
        assertEq(usdc.balanceOf(creator) - before, fee);

        vm.prank(creator);
        vm.expectRevert(MakoRoundsV1.NothingOwed.selector);
        rounds.claim(roundId);
    }

    /// @notice A creator who also backed the winning side gets payout AND fee, in one call, once.
    function test_CreatorWhoWonGetsPayoutAndFeeInOneCall() public {
        vm.warp(BASE);
        vm.prank(creator);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 10_000_000);
        vm.prank(bob);
        rounds.enter(roundId, MakoRoundsV1.Side.Down, 30_000_000);
        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime), 101e18);
        vm.warp(closeTime);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        MakoRoundsV1.Round memory r = rounds.roundOf(roundId);
        uint256 before = usdc.balanceOf(creator);
        vm.prank(creator);
        rounds.claim(roundId);
        assertEq(usdc.balanceOf(creator) - before, r.distributable + r.creatorFee);
        assertTrue(rounds.stakeClaimed(roundId, creator) && rounds.creatorFeeClaimed(roundId));
    }

    /// @notice N19: protocol fees and remainders leave only to TREASURY, only when TREASURY asks.
    function test_TreasuryOnly() public {
        _settleUpWins();
        uint256 owed = rounds.treasuryBalance();
        assertGt(owed, 0);

        vm.prank(alice);
        vm.expectRevert(MakoRoundsV1.NotTreasury.selector);
        rounds.withdrawTreasury();

        vm.prank(TREASURY);
        rounds.withdrawTreasury();
        assertEq(usdc.balanceOf(TREASURY), owed);
        assertEq(rounds.treasuryBalance(), 0);

        vm.prank(TREASURY);
        vm.expectRevert(MakoRoundsV1.NothingOwed.selector);
        rounds.withdrawTreasury();
    }

    // ---------------------------------------------------------------------------------------------
    // slice 3: N17, conservation, the property the whole contract exists to keep
    // ---------------------------------------------------------------------------------------------

    /// @notice Once the last winner claims, sum(payouts) + protocolFee + creatorFee + remainder is
    /// the total EXACTLY, the remainder is in the treasury, and the contract is left holding nothing.
    /// @dev Fuzzed over several winners with arbitrary stakes, because the remainder only exists
    /// when per-winner flooring truncates, which a single round number never does.
    function testFuzz_ConservationSettled(uint64 s1, uint64 s2, uint64 s3, uint64 loserStake) public {
        address[3] memory winners = [address(0xE1), address(0xE2), address(0xE3)];
        uint256[3] memory stakes =
            [uint256(s1) % 1e12 + 100_000, uint256(s2) % 1e12 + 100_000, uint256(s3) % 1e12 + 100_000];
        uint256 lose = uint256(loserStake) % 1e12 + 100_000;

        vm.warp(BASE);
        for (uint256 i = 0; i < 3; i++) {
            usdc.mint(winners[i], stakes[i]);
            vm.startPrank(winners[i]);
            usdc.approve(address(rounds), type(uint256).max);
            rounds.enter(roundId, MakoRoundsV1.Side.Up, stakes[i]);
            vm.stopPrank();
        }
        usdc.mint(bob, lose);
        vm.prank(bob);
        rounds.enter(roundId, MakoRoundsV1.Side.Down, lose);

        uint256 total = stakes[0] + stakes[1] + stakes[2] + lose;
        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime), 101e18);
        vm.warp(closeTime);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
        MakoRoundsV1.Round memory r = rounds.roundOf(roundId);

        uint256 paid;
        for (uint256 i = 0; i < 3; i++) {
            uint256 before = usdc.balanceOf(winners[i]);
            vm.prank(winners[i]);
            rounds.claim(roundId);
            paid += usdc.balanceOf(winners[i]) - before;
            // before the last winner, never more than distributable has left
            assertLe(paid, r.distributable, "claimed more than distributable");
        }

        vm.prank(creator);
        rounds.claim(roundId);

        uint256 remainder = r.distributable - paid;
        assertEq(rounds.treasuryBalance(), r.protocolFee + remainder, "remainder swept to treasury");
        assertEq(paid + r.protocolFee + r.creatorFee + remainder, total, "N17: conservation");

        vm.prank(TREASURY);
        rounds.withdrawTreasury();
        assertEq(usdc.balanceOf(address(rounds)), 0, "nothing is left behind or created");
    }

    /// @notice The remainder waits for the last winner: a winner who has not claimed holds it back.
    function test_RemainderWaitsForTheLastWinner() public {
        vm.warp(BASE);
        address w1 = address(0xE1);
        address w2 = address(0xE2);
        usdc.mint(w1, 10_000_001);
        usdc.mint(w2, 10_000_002);
        vm.prank(w1);
        usdc.approve(address(rounds), type(uint256).max);
        vm.prank(w2);
        usdc.approve(address(rounds), type(uint256).max);
        vm.prank(w1);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 10_000_001);
        vm.prank(w2);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 10_000_002);
        vm.prank(bob);
        rounds.enter(roundId, MakoRoundsV1.Side.Down, 33_333_333);
        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime), 101e18);
        vm.warp(closeTime);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        uint256 afterSettle = rounds.treasuryBalance();
        uint256 distributable = rounds.roundOf(roundId).distributable;

        uint256 b1 = usdc.balanceOf(w1);
        vm.prank(w1);
        rounds.claim(roundId);
        uint256 paid = usdc.balanceOf(w1) - b1;
        assertEq(rounds.treasuryBalance(), afterSettle, "no sweep while a winner is still to claim");

        uint256 b2 = usdc.balanceOf(w2);
        vm.prank(w2);
        rounds.claim(roundId);
        paid += usdc.balanceOf(w2) - b2;

        // These stakes are chosen so per-winner flooring truncates: without a non-zero remainder this
        // test would pass while proving nothing about the sweep, which is what the first draft's
        // `assertGe` did.
        uint256 remainder = distributable - paid;
        assertGt(remainder, 0, "the stakes must produce a real remainder or this test proves nothing");
        assertEq(rounds.treasuryBalance(), afterSettle + remainder, "the last winner sweeps exactly the remainder");
    }

    // ---------------------------------------------------------------------------------------------
    // slice 3: N8, reentrancy, one test per value-moving function
    // ---------------------------------------------------------------------------------------------

    function _roundsWithReentrant() internal returns (MakoRoundsV1 rr, ReentrantUSDC tok, uint256 id) {
        tok = new ReentrantUSDC();
        address[] memory cs = new address[](1);
        cs[0] = creator;
        rr = new MakoRoundsV1(TREASURY, address(tok), cs);
        vm.prank(creator);
        id = rr.schedule(startTime);
        address[2] memory who = [alice, bob];
        for (uint256 i = 0; i < 2; i++) {
            tok.mint(who[i], 1_000_000_000);
            vm.prank(who[i]);
            tok.approve(address(rr), type(uint256).max);
        }
    }

    /// @dev The re-entrant call is refused with `Reentrancy` specifically. Asserting the selector
    /// matters: a re-entrant `claim` from an address with nothing owed would also revert, with
    /// `NothingOwed`, and that would pass a bare "it reverted" check without the guard doing anything.
    function test_ClaimIsNotReentrant() public {
        (MakoRoundsV1 rr, ReentrantUSDC tok, uint256 id) = _roundsWithReentrant();
        vm.prank(alice);
        rr.enter(id, MakoRoundsV1.Side.Up, 10_000_000);
        vm.prank(bob);
        rr.enter(id, MakoRoundsV1.Side.Down, 30_000_000);
        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime), 101e18);
        vm.warp(closeTime);
        rr.settle(id, _anchorBytes(), _closeBytes());

        tok.arm(address(rr), abi.encodeCall(MakoRoundsV1.claim, (id)));
        vm.prank(alice);
        rr.claim(id);
        assertEq(bytes4(tok.lastRevert()), MakoRoundsV1.Reentrancy.selector);
    }

    function test_WithdrawTreasuryIsNotReentrant() public {
        (MakoRoundsV1 rr, ReentrantUSDC tok, uint256 id) = _roundsWithReentrant();
        vm.prank(alice);
        rr.enter(id, MakoRoundsV1.Side.Up, 10_000_000);
        vm.prank(bob);
        rr.enter(id, MakoRoundsV1.Side.Down, 30_000_000);
        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime), 101e18);
        vm.warp(closeTime);
        rr.settle(id, _anchorBytes(), _closeBytes());

        tok.arm(address(rr), abi.encodeCall(MakoRoundsV1.withdrawTreasury, ()));
        vm.prank(TREASURY);
        rr.withdrawTreasury();
        assertEq(bytes4(tok.lastRevert()), MakoRoundsV1.Reentrancy.selector);
    }

    function test_EnterIsNotReentrant() public {
        (MakoRoundsV1 rr, ReentrantUSDC tok, uint256 id) = _roundsWithReentrant();
        tok.arm(address(rr), abi.encodeCall(MakoRoundsV1.enter, (id, MakoRoundsV1.Side.Up, 1_000_000)));
        vm.warp(BASE);
        vm.prank(alice);
        rr.enter(id, MakoRoundsV1.Side.Up, 1_000_000);
        assertEq(bytes4(tok.lastRevert()), MakoRoundsV1.Reentrancy.selector);
    }

    /// @notice An outbound transfer that falls short reverts the whole claim.
    function test_ShortOutboundTransferReverts() public {
        ShortTransferUSDC tok = new ShortTransferUSDC();
        address[] memory cs = new address[](1);
        cs[0] = creator;
        MakoRoundsV1 rr = new MakoRoundsV1(TREASURY, address(tok), cs);
        vm.prank(creator);
        uint256 id = rr.schedule(startTime);
        address[2] memory who = [alice, bob];
        for (uint256 i = 0; i < 2; i++) {
            tok.mint(who[i], 1_000_000_000);
            vm.prank(who[i]);
            tok.approve(address(rr), type(uint256).max);
        }
        vm.prank(alice);
        rr.enter(id, MakoRoundsV1.Side.Up, 10_000_000);
        vm.prank(bob);
        rr.enter(id, MakoRoundsV1.Side.Down, 30_000_000);
        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime), 101e18);
        vm.warp(closeTime);
        rr.settle(id, _anchorBytes(), _closeBytes());

        tok.setShortchange(true);
        uint256 owed = rr.roundOf(id).distributable;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MakoRoundsV1.InexactTransfer.selector, owed, owed - 1));
        rr.claim(id);
        assertFalse(rr.stakeClaimed(id, alice), "a failed claim leaves no trace");
    }

    // ---------------------------------------------------------------------------------------------
    // slice 3: N6
    // ---------------------------------------------------------------------------------------------

    /// @notice N6: a stake, the creator's seed included, cannot leave before a terminal state.
    /// @dev There is no withdraw-before-settlement function at all, so the only exit is `claim`, and
    /// `claim` refuses a non-terminal round.
    function test_SeedLocked() public {
        vm.warp(BASE);
        vm.prank(creator);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 10_000_000);
        vm.prank(creator);
        vm.expectRevert(MakoRoundsV1.RoundNotTerminal.selector);
        rounds.claim(roundId);
    }

    // ---------------------------------------------------------------------------------------------
    // adversarial review findings
    // ---------------------------------------------------------------------------------------------

    function _pending() internal view returns (uint256[] memory) {
        return rounds.pendingSettlement();
    }

    /// @notice SPEC §5.1: a two-sided round in its submit window is listed, and each of the four
    /// filter conditions excludes a round on its own. One test per condition, because a view that
    /// listed too much would send the courier to fetch reports for calls that must revert.
    function test_PendingSettlementListsOnlySettleableRounds() public {
        _twoSided();

        vm.warp(closeTime - 1);
        assertEq(_pending().length, 0, "not before closeTime");

        vm.warp(closeTime);
        uint256[] memory ids = _pending();
        assertEq(ids.length, 1, "listed from closeTime");
        assertEq(ids[0], roundId);

        vm.warp(submitDeadline - 1);
        assertEq(_pending().length, 1, "still listed in the last second");

        vm.warp(submitDeadline);
        assertEq(_pending().length, 0, "not at or after submitDeadline");
    }

    function test_PendingSettlementExcludesOneSidedRounds() public {
        vm.prank(alice);
        rounds.enter(roundId, MakoRoundsV1.Side.Up, 10_000_000);
        vm.warp(closeTime);
        assertEq(_pending().length, 0, "a one-sided round can never settle, so it is never listed");
    }

    function test_PendingSettlementExcludesTerminalRounds() public {
        _settleUpWins();
        assertEq(_pending().length, 0, "a settled round is gone from the list");
    }

    /// @notice Bounded by the active index, so it can never list more than MAX_ACTIVE_ROUNDS.
    function test_PendingSettlementIsBoundedByTheCap() public {
        address[] memory many = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            many[i] = address(uint160(0x3000 + i));
        }
        MakoRoundsV1 fresh = new MakoRoundsV1(TREASURY, address(usdc), many);
        uint64 st = BASE + 3600;
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(many[i]);
            uint256 id = fresh.schedule(st);
            usdc.mint(alice, 1_000_000);
            usdc.mint(bob, 1_000_000);
            vm.prank(alice);
            usdc.approve(address(fresh), type(uint256).max);
            vm.prank(bob);
            usdc.approve(address(fresh), type(uint256).max);
            vm.prank(alice);
            fresh.enter(id, MakoRoundsV1.Side.Up, 1_000_000);
            vm.prank(bob);
            fresh.enter(id, MakoRoundsV1.Side.Down, 1_000_000);
        }
        vm.warp(st + 900);
        assertEq(fresh.pendingSettlement().length, 10, "every settleable round, and never more than the cap");
    }

    /// @notice The active index stays consistent when rounds leave it out of order.
    /// @dev Swap-and-pop moves the last id into the freed position, which is exactly where an
    /// off-by-one would corrupt the index. Retire the middle round first to exercise it.
    function test_ActiveIndexSurvivesOutOfOrderRemoval() public {
        address[] memory three = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            three[i] = address(uint160(0x4000 + i));
        }
        MakoRoundsV1 fresh = new MakoRoundsV1(TREASURY, address(usdc), three);
        uint64 st = BASE + 3600;
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(three[i]);
            fresh.schedule(st);
        }
        assertEq(fresh.activeRoundCount(), 3);

        vm.warp(st - 60); // entries closed, all three one-sided (empty)
        fresh.finalizeRefund(2);
        assertEq(fresh.activeRoundCount(), 2);
        fresh.finalizeRefund(3);
        fresh.finalizeRefund(1);
        assertEq(fresh.activeRoundCount(), 0, "every round leaves the index exactly once");

        vm.expectRevert(MakoRoundsV1.RoundAlreadyTerminal.selector);
        fresh.finalizeRefund(2);
    }

    /// @notice SPEC §5.3, N14: a tie emits its evidence, in an event that cannot be read as settled.
    function test_TieEmitsEvidenceWithoutClaimingToBeSettled() public {
        _armHappyPath(100e18, 100e18);
        vm.expectEmit(true, false, false, true, address(rounds));
        emit MakoRoundsV1.RoundTied(
            roundId,
            100e18,
            100e18,
            uint32(startTime),
            uint32(closeTime),
            keccak256(_anchorBytes()),
            keccak256(_closeBytes()),
            address(this)
        );
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
    }

    /// @notice A round whose close boundary would not fit a uint32 report timestamp is refused at
    /// scheduling, rather than accepted and forced onto the NoPrice path a day later. At the largest
    /// minute-aligned start that fits, it is accepted; one minute later, refused.
    function test_StartTimeMustFitAUint32ReportTimestamp() public {
        uint64 lastOk = uint64(type(uint32).max - 900);
        lastOk -= lastOk % 60;
        address[] memory one = new address[](1);
        one[0] = outsider;
        MakoRoundsV1 fresh = new MakoRoundsV1(TREASURY, address(usdc), one);

        vm.warp(lastOk - 3600);
        vm.prank(outsider);
        vm.expectRevert(MakoRoundsV1.StartTimeOutOfRange.selector);
        fresh.schedule(lastOk + 60);

        vm.prank(outsider);
        fresh.schedule(lastOk);
    }

    /// @notice A verifier that re-enters `settle` is refused, so a round cannot settle twice and the
    /// protocol fee cannot accrue twice.
    function test_SettleIsNotReentrant() public {
        _armHappyPath(100e18, 101e18);
        mock.setReenter(address(rounds), abi.encodeCall(MakoRoundsV1.settle, (roundId, _anchorBytes(), _closeBytes())));

        rounds.settle(roundId, _anchorBytes(), _closeBytes());

        assertEq(bytes4(mock.lastReenterRevert()), MakoRoundsV1.Reentrancy.selector, "refused by the guard");
        MakoRoundsV1.Round memory r = rounds.roundOf(roundId);
        assertEq(rounds.treasuryBalance(), r.protocolFee, "the fee accrued exactly once");
        assertEq(rounds.activeRoundCount(), 0, "the slot was released exactly once");
    }

    // ---------------------------------------------------------------------------------------------
    // slice boundary
    // ---------------------------------------------------------------------------------------------
}
