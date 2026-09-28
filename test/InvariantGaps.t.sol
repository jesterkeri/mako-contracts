// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MakoRoundsV1} from "../src/MakoRoundsV1.sol";
import {RoundSettlement} from "../src/RoundSettlement.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";
import {MockUSDC} from "./mocks/TokenMocks.sol";

/// @notice Written by the adversarial review of `d946901..f8a6cb7` (T1.4, the invariant coverage map) and
/// adopted into the suite; its five mutants are in script/mutate-solidity.mjs. Written against
/// blueprint/INVARIANTS.md r8. Each test holds the contract to one clause whose mapped evidence in
/// `test/fixtures/invariant-coverage.json` was shown NOT to fail when the clause is broken: a mutant of
/// `src/MakoRoundsV1.sol` breaking the clause survived the whole suite. Every test here passes on the
/// current contract and fails on that mutant.
///
/// @dev Same harness shape as `MakoRoundsV1.t.sol` and `Adversary.t.sol`: `MockVerifier` etched at the
/// pinned `VERIFIER_PROXY`, answering per submitted report through `setReturnFor`.
contract InvariantGapsTest is Test {
    MakoRoundsV1 internal rounds;
    MockVerifier internal mock;
    MockUSDC internal usdc;

    address internal constant VERIFIER = 0x72790f9eB82db492a7DDb6d2af22A270Dcc3Db64;
    address internal constant TREASURY = address(0x7777);
    address internal creatorA = address(0xC1);
    address internal creatorB = address(0xC2);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    /// @dev 1789500000 % 60 == 0.
    uint64 internal constant BASE = 1789500000;

    function setUp() public {
        vm.warp(BASE);
        usdc = new MockUSDC();
        address[] memory creators = new address[](2);
        creators[0] = creatorA;
        creators[1] = creatorB;
        rounds = new MakoRoundsV1(TREASURY, address(usdc), creators);

        MockVerifier template = new MockVerifier();
        vm.etch(VERIFIER, address(template).code);
        mock = MockVerifier(VERIFIER);

        address[2] memory funded = [alice, bob];
        for (uint256 i = 0; i < funded.length; i++) {
            usdc.mint(funded[i], 1_000_000_000);
            vm.prank(funded[i]);
            usdc.approve(address(rounds), type(uint256).max);
        }
    }

    function _payload(uint32 observedAt, int192 price) internal pure returns (bytes memory) {
        return abi.encode(
            RoundSettlement.FEED_ID,
            uint32(observedAt),
            uint32(observedAt),
            uint192(0),
            uint192(0),
            uint32(observedAt) + 30 days,
            price,
            price,
            price
        );
    }

    /// @dev Schedules a two-sided round for `creator` at `startTime`, alice UP 10 and bob DOWN 30, arms
    /// UP-winning reports keyed by the round id, and warps to its closeTime.
    function _twoSidedRoundReadyToSettle(address creator, uint64 startTime)
        internal
        returns (uint256 id, bytes memory a, bytes memory c)
    {
        vm.prank(creator);
        id = rounds.schedule(startTime);
        vm.prank(alice);
        rounds.enter(id, MakoRoundsV1.Side.Up, 10_000_000);
        vm.prank(bob);
        rounds.enter(id, MakoRoundsV1.Side.Down, 30_000_000);
        a = abi.encodePacked(hex"a0", id);
        c = abi.encodePacked(hex"c0", id);
        mock.setReturnFor(a, _payload(uint32(startTime), 100e18));
        mock.setReturnFor(c, _payload(uint32(startTime + 900), 101e18));
    }

    /// @notice N19: "the creator fee goes only to the round's creator". Another INVITED creator, who is
    /// a creator of the contract but not of this round, must not be able to take it.
    /// @dev Mutant that survives the whole suite: in `claim`, `msg.sender == r.creator` becomes
    /// `_isCreator[msg.sender]`. The mapped N19 tests only ever claim with the round's own creator, a
    /// winner or a loser, never with a second creator.
    function test_AnotherCreatorCannotTakeThisRoundsFee() public {
        uint64 st = BASE + 3600;
        (uint256 id, bytes memory a, bytes memory c) = _twoSidedRoundReadyToSettle(creatorA, st);
        vm.warp(st + 900);
        rounds.settle(id, a, c);
        uint256 fee = rounds.roundOf(id).creatorFee;
        assertGt(fee, 0, "the round must carry a creator fee or this test proves nothing");

        vm.prank(creatorB);
        vm.expectRevert(MakoRoundsV1.NothingOwed.selector);
        rounds.claim(id);

        uint256 before = usdc.balanceOf(creatorA);
        vm.prank(creatorA);
        rounds.claim(id);
        assertEq(usdc.balanceOf(creatorA) - before, fee, "the round's own creator is paid the whole fee");
    }

    /// @notice N26: "settle ... gives the caller no power over the result". The fee split is part of
    /// the result: the same reports settled by the round's creator and by a stranger must store the
    /// same fees and the same distributable.
    /// @dev Mutant that survives the whole suite: the creator fee is doubled when `msg.sender ==
    /// r.creator`. `testFuzz_AnyCallerSameOutcome` compares outcome, prices and hashes only, and its
    /// fuzzed callers essentially never hit the creator's address.
    function test_TheSettlerCannotChangeTheFees() public {
        uint64 st = BASE + 3600;
        (uint256 id, bytes memory a, bytes memory c) = _twoSidedRoundReadyToSettle(creatorA, st);
        vm.warp(st + 900);

        address[4] memory settlers = [creatorA, TREASURY, alice, address(0xBEEF)];
        uint256 snap = vm.snapshotState();
        vm.prank(address(0xBEEF));
        rounds.settle(id, a, c);
        MakoRoundsV1.Round memory ref = rounds.roundOf(id);
        uint256 refTreasury = rounds.treasuryBalance();

        for (uint256 i = 0; i < settlers.length; i++) {
            vm.revertToState(snap);
            vm.prank(settlers[i]);
            rounds.settle(id, a, c);
            MakoRoundsV1.Round memory r = rounds.roundOf(id);
            assertEq(uint256(r.outcome), uint256(ref.outcome), "outcome");
            assertEq(r.protocolFee, ref.protocolFee, "the settler changed the protocol fee");
            assertEq(r.creatorFee, ref.creatorFee, "the settler changed the creator fee");
            assertEq(r.distributable, ref.distributable, "the settler changed distributable");
            assertEq(rounds.treasuryBalance(), refTreasury, "the settler changed what the treasury accrued");
        }
    }

    /// @notice N18: `startTime - openTime <= MAX_LEAD`, at the boundary +/- 1 minute (startTime is a
    /// whole minute, so a minute is the finest step past the boundary).
    /// @dev Mutant that survives the whole suite: the `LeadTooLong` line is deleted. No test anywhere
    /// references `LeadTooLong`; `test_LeadBoundsAreEnforcedAtTheBoundaryPlusMinusOne` covers MIN_LEAD
    /// only.
    function test_MaxLeadAtTheBoundary() public {
        uint64 maxOk = BASE + 7 days; // BASE is a whole minute and 7 days is whole minutes
        vm.prank(creatorA);
        vm.expectRevert(MakoRoundsV1.LeadTooLong.selector);
        rounds.schedule(maxOk + 60);

        vm.prank(creatorA);
        assertGt(rounds.schedule(maxOk), 0, "exactly MAX_LEAD is allowed");
    }

    /// @notice N18: `MIN_LEAD <= startTime - openTime`, at ONE SECOND either side. The mapped test's
    /// name says plus/minus one but it checks a lead of 540 and 600, so any threshold from 541 to 600
    /// passes it. Here `openTime` is moved instead of `startTime`, which reaches a lead of 599.
    /// @dev Mutant that survives the whole suite: `startTime < openTime + MIN_LEAD - 59`.
    function test_MinLeadAtOneSecond() public {
        uint64 st = BASE + 600;
        vm.warp(BASE + 1); // lead 599
        vm.prank(creatorA);
        vm.expectRevert(MakoRoundsV1.LeadTooShort.selector);
        rounds.schedule(st);

        vm.warp(BASE); // lead 600
        vm.prank(creatorA);
        assertGt(rounds.schedule(st), 0, "exactly MIN_LEAD is allowed");
    }

    /// @notice N27: `startTime` must be a WHOLE MINUTE. A half-minute is not one.
    /// @dev Mutant that survives the whole suite: `BOUNDARY_STEP = 30`. `test_StartTimeOnMinute` checks
    /// only minute +/- 1 second, which every step size above 1 that divides 60 also rejects.
    function test_HalfMinuteIsRejected() public {
        vm.prank(creatorA);
        vm.expectRevert(MakoRoundsV1.StartTimeNotOnBoundary.selector);
        rounds.schedule(BASE + 3600 + 30);
    }
}
