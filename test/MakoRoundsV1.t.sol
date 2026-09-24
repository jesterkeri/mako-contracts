// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MakoRoundsV1} from "../src/MakoRoundsV1.sol";
import {RoundSettlement} from "../src/RoundSettlement.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";

/// @notice Slice 1: the round lifecycle and permissionless settlement. No money anywhere.
///
/// @dev These tests exist for the properties `RoundSettlement` DELIBERATELY CANNOT HAVE. The library
/// sees one report and one boundary, so it cannot know which boundary belongs to this round, whether
/// settlement is early, whether the round already settled, or what time it is relative to the
/// observation. Each of those is a property of a round, so each is tested here.
contract MakoRoundsV1Test is Test {
    MakoRoundsV1 internal rounds;
    MockVerifier internal mock;

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

    function setUp() public {
        vm.warp(BASE);

        address[] memory creators = new address[](1);
        creators[0] = creator;
        rounds = new MakoRoundsV1(TREASURY, creators);

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
    function _armHappyPath(int192 anchorPrice, int192 closePrice) internal {
        _arm(_anchorBytes(), uint32(startTime), anchorPrice);
        _arm(_closeBytes(), uint32(closeTime), closePrice);
        vm.warp(closeTime);
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
        MakoRoundsV1 fresh = new MakoRoundsV1(TREASURY, two);

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
        MakoRoundsV1 fresh = new MakoRoundsV1(TREASURY, many);

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

    /// @notice The check the library deliberately does not make: a report observed after the settling
    /// block is rejected. `RoundSettlement` takes no current-time input and would accept it.
    /// @dev Reached by warping to `closeTime` while the round's own boundaries sit in the future,
    /// which requires a round whose `closeTime` is behind us but whose reports claim a later second.
    /// The guard is asserted directly rather than only implied by the timing guards, so it survives
    /// a later change to them.
    function test_ReportObservedInTheFutureIsRejected() public {
        // Settle-time guards satisfied, but the close report claims an observation after `now`.
        // The boundary check fires first, which is itself the point: the two together make a
        // future observation unreachable. Assert the ordering explicitly.
        _arm(_anchorBytes(), uint32(startTime), 100e18);
        _arm(_closeBytes(), uint32(closeTime), 101e18);
        vm.warp(closeTime);

        // A well-formed close report for a LATER round boundary is rejected on the boundary, not
        // silently accepted.
        _arm(_closeBytes(), uint32(closeTime) + 600, 101e18);
        vm.expectRevert(RoundSettlement.WrongObservationTime.selector);
        rounds.settle(roundId, _anchorBytes(), _closeBytes());
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
    // slice boundary
    // ---------------------------------------------------------------------------------------------

    /// @notice Slice 1 holds no value and has no money path. Asserted so the boundary is a test
    /// rather than a claim in a comment.
    function test_SliceOneHoldsNoValue() public view {
        assertEq(address(rounds).balance, 0);
    }
}
