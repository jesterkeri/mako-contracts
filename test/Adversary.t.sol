// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {MakoRoundsV1} from "../src/MakoRoundsV1.sol";
import {RoundSettlement} from "../src/RoundSettlement.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";
import {MockUSDC} from "./mocks/TokenMocks.sol";

/// @notice Adversarial review of `fe143bf..d552d94`, written against blueprint/SPEC.md r8 and
/// blueprint/INVARIANTS.md. Each test states the clause it holds the contract to.
///
/// @dev Same harness shape as `MakoRoundsV1.t.sol`: `MockVerifier` etched at the pinned
/// `VERIFIER_PROXY`, answering per submitted report through `setReturnFor`. Payloads are built with
/// `abi.encode` in the schema-v3 layout the library decodes.
contract AdversaryTest is Test {
    MakoRoundsV1 internal rounds;
    MockVerifier internal mock;
    MockUSDC internal usdc;

    address internal constant VERIFIER = 0x72790f9eB82db492a7DDb6d2af22A270Dcc3Db64;
    address internal constant TREASURY = address(0x7777);
    address internal creatorA = address(0xC1);
    address internal creatorB = address(0xC2);

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
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

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

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(rounds), type(uint256).max);
    }

    function _enter(uint256 id, address who, MakoRoundsV1.Side side, uint256 amount) internal {
        _fund(who, amount);
        vm.prank(who);
        rounds.enter(id, side, amount);
    }

    /// @dev Distinct report bytes per round and boundary, so two rounds never share a mock key.
    function _armAndSettle(uint256 id, int192 anchorPrice, int192 closePrice) internal {
        MakoRoundsV1.Round memory r = rounds.roundOf(id);
        uint64 closeTime = r.startTime + 900;
        bytes memory a = abi.encodePacked("anchor", id);
        bytes memory c = abi.encodePacked("close", id);
        mock.setReturnFor(a, _payload(uint32(r.startTime), anchorPrice));
        mock.setReturnFor(c, _payload(uint32(closeTime), closePrice));
        if (block.timestamp < closeTime) vm.warp(closeTime);
        rounds.settle(id, a, c);
    }

    function _contains(Vm.Log memory l, bytes32 word) internal pure returns (bool) {
        for (uint256 i = 0; i < l.topics.length; i++) {
            if (l.topics[i] == word) return true;
        }
        for (uint256 off = 0; off + 32 <= l.data.length; off += 32) {
            bytes32 w;
            bytes memory d = l.data;
            assembly {
                w := mload(add(add(d, 32), off))
            }
            if (w == word) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------------------------------------
    // DEFECT 1: SPEC §5.1 `pendingSettlement()` does not exist
    // ---------------------------------------------------------------------------------------------

    /// @notice SPEC §5.1: "A view, `pendingSettlement()`, returns the ids of rounds past `closeTime`,
    /// before `submitDeadline`, not terminal and two-sided, at most `MAX_ACTIVE_ROUNDS` of them."
    /// SPEC §5.5 step 1 makes it the courier's only input. A two-sided round sitting in its submit
    /// window must be listed.
    function test_PendingSettlementListsASettleableRound() public {
        vm.prank(creatorA);
        uint256 id = rounds.schedule(BASE + 3600);
        _enter(id, address(0xA1), MakoRoundsV1.Side.Up, 1_000_000);
        _enter(id, address(0xB1), MakoRoundsV1.Side.Down, 1_000_000);
        vm.warp(BASE + 3600 + 900);

        (bool ok, bytes memory data) = address(rounds).staticcall(abi.encodeWithSignature("pendingSettlement()"));
        assertTrue(ok, "SPEC 5.1: pendingSettlement() must exist and not revert");
        uint256[] memory ids = abi.decode(data, (uint256[]));
        assertEq(ids.length, 1, "exactly the one settleable round");
        assertEq(ids[0], id);
    }

    // ---------------------------------------------------------------------------------------------
    // DEFECT 2: a Tie stores the evidence but never emits it
    // ---------------------------------------------------------------------------------------------

    /// @notice SPEC §5.3, directly under "Equal: refund (RefundReason.Tie)": "Both prices, both
    /// observation seconds and keccak256 of both full reports are stored and emitted." N14: "Every
    /// settlement stores and emits both prices, both observation seconds and both report hashes."
    /// A Tie is decided inside `settle` from two verified reports, so its evidence must be on the
    /// log like any other settlement. Checked word by word so any event shape carrying it passes.
    function test_TieEmitsItsSettlementEvidence() public {
        uint64 startTime = BASE + 3600;
        uint64 closeTime = startTime + 900;
        vm.prank(creatorA);
        uint256 id = rounds.schedule(startTime);
        _enter(id, address(0xA1), MakoRoundsV1.Side.Up, 1_000_000);
        _enter(id, address(0xB1), MakoRoundsV1.Side.Down, 1_000_000);

        bytes memory a = abi.encodePacked("anchor", id);
        bytes memory c = abi.encodePacked("close", id);
        int192 price = 64_123e18;
        mock.setReturnFor(a, _payload(uint32(startTime), price));
        mock.setReturnFor(c, _payload(uint32(closeTime), price));
        vm.warp(closeTime);

        vm.recordLogs();
        rounds.settle(id, a, c);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        MakoRoundsV1.Round memory r = rounds.roundOf(id);
        assertEq(uint256(r.refundReason), uint256(MakoRoundsV1.RefundReason.Tie), "setup: this is a tie");

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(rounds)) continue;
            if (
                _contains(l, bytes32(uint256(uint192(price)))) && _contains(l, bytes32(uint256(startTime)))
                    && _contains(l, bytes32(uint256(closeTime))) && _contains(l, keccak256(a))
                    && _contains(l, keccak256(c))
            ) found = true;
        }
        assertTrue(found, "SPEC 5.3 / N14: a Tie must emit both prices, both seconds and both report hashes");
    }

    // ---------------------------------------------------------------------------------------------
    // Money attacks that FAILED to break the contract (kept as coverage)
    // ---------------------------------------------------------------------------------------------

    /// @notice Solvency across rounds: a settled round (creator also a winner, odd stakes, ragged
    /// remainder) beside a Tie round and a OneSided round, claimed in an adversarial order, must
    /// drain the contract to exactly zero, and nobody may be paid twice.
    function testFuzz_CrossRoundSolvencyDrainsToZero(uint64 s1, uint64 s2, uint64 s3, uint64 l1, uint64 cs) public {
        uint256 w1 = bound(s1, 100_000, 1e15);
        uint256 w2 = bound(s2, 100_000, 1e15);
        uint256 w3 = bound(s3, 100_000, 1e15);
        uint256 lo = bound(l1, 100_000, 1e15);
        uint256 cStake = bound(cs, 100_000, 1e15);

        vm.prank(creatorA);
        uint256 r1 = rounds.schedule(BASE + 3600);
        vm.prank(creatorB);
        uint256 r2 = rounds.schedule(BASE + 3600);

        // r1: creatorA backs UP with two strangers; one loser on DOWN.
        _enter(r1, creatorA, MakoRoundsV1.Side.Up, cStake);
        _enter(r1, address(0xA1), MakoRoundsV1.Side.Up, w1);
        _enter(r1, address(0xA2), MakoRoundsV1.Side.Up, w2);
        _enter(r1, address(0xA2), MakoRoundsV1.Side.Up, w3); // top-up
        _enter(r1, address(0xB1), MakoRoundsV1.Side.Down, lo);
        // r2: two-sided, ties.
        _enter(r2, address(0xA1), MakoRoundsV1.Side.Down, w1);
        _enter(r2, address(0xB2), MakoRoundsV1.Side.Up, lo);

        _armAndSettle(r1, 100e18, 101e18);
        _armAndSettle(r2, 100e18, 100e18);

        // r3: scheduled after r1 frees creatorA's slot, one-sided, refunded.
        vm.prank(creatorA);
        uint256 r3 = rounds.schedule(uint64(block.timestamp - (block.timestamp % 60)) + 1200);
        _enter(r3, address(0xB1), MakoRoundsV1.Side.Down, lo);
        vm.warp(rounds.entryCloseTimeOf(r3));
        rounds.finalizeRefund(r3);

        // Loser tries r1, a stranger tries everything, the treasury drains mid-way.
        vm.prank(address(0xB1));
        vm.expectRevert(MakoRoundsV1.NothingOwed.selector);
        rounds.claim(r1);
        vm.prank(address(0xDEAD));
        vm.expectRevert(MakoRoundsV1.NothingOwed.selector);
        rounds.claim(r1);

        vm.prank(address(0xA2));
        rounds.claim(r1);
        vm.prank(TREASURY);
        rounds.withdrawTreasury();
        vm.prank(address(0xA1));
        rounds.claim(r2);
        vm.prank(creatorA);
        rounds.claim(r1);
        vm.prank(address(0xB1));
        rounds.claim(r3);
        vm.prank(address(0xA1));
        rounds.claim(r1); // last winner, sweeps the remainder
        vm.prank(address(0xB2));
        rounds.claim(r2);
        vm.prank(TREASURY);
        rounds.withdrawTreasury();

        // Nobody is paid twice.
        vm.prank(creatorA);
        vm.expectRevert(MakoRoundsV1.NothingOwed.selector);
        rounds.claim(r1);
        vm.prank(address(0xA1));
        vm.expectRevert(MakoRoundsV1.NothingOwed.selector);
        rounds.claim(r2);

        assertEq(usdc.balanceOf(address(rounds)), 0, "every unit that came in went out exactly once");
        assertEq(rounds.treasuryBalance(), 0);
        assertEq(rounds.activeRoundCount(), 0, "no capacity slot leaks");
    }

    /// @notice A stranger topping up the empty side one second before `entryCloseTime` blocks
    /// OneSided, and cannot make the round refund early or settle late: the boundaries hold at ±1.
    function test_BoundariesHoldAtPlusMinusOne() public {
        uint64 startTime = BASE + 3600;
        uint64 closeTime = startTime + 900;
        uint64 deadline = closeTime + 24 hours;
        vm.prank(creatorA);
        uint256 id = rounds.schedule(startTime);
        _enter(id, address(0xA1), MakoRoundsV1.Side.Up, 1_000_000);

        // One second before entryCloseTime: OneSided is not yet available, and a stranger can
        // still make the round two-sided.
        vm.warp(startTime - 61);
        vm.expectRevert(MakoRoundsV1.NotRefundableYet.selector);
        rounds.finalizeRefund(id);
        _enter(id, address(0xB1), MakoRoundsV1.Side.Down, 100_000);

        // At entryCloseTime: entry closed, and the now two-sided round cannot refund as OneSided.
        vm.warp(startTime - 60);
        _fund(address(0xB2), 100_000);
        vm.prank(address(0xB2));
        vm.expectRevert(MakoRoundsV1.EntriesClosed.selector);
        rounds.enter(id, MakoRoundsV1.Side.Down, 100_000);
        vm.expectRevert(MakoRoundsV1.NotRefundableYet.selector);
        rounds.finalizeRefund(id);

        bytes memory a = abi.encodePacked("anchor", id);
        bytes memory c = abi.encodePacked("close", id);
        mock.setReturnFor(a, _payload(uint32(startTime), 100e18));
        mock.setReturnFor(c, _payload(uint32(closeTime), 101e18));

        vm.warp(closeTime - 1);
        vm.expectRevert(MakoRoundsV1.TooEarlyToSettle.selector);
        rounds.settle(id, a, c);

        vm.warp(deadline - 1);
        vm.expectRevert(MakoRoundsV1.NotRefundableYet.selector);
        rounds.finalizeRefund(id);

        vm.warp(deadline);
        vm.expectRevert(MakoRoundsV1.SubmitWindowClosed.selector);
        rounds.settle(id, a, c);
        rounds.finalizeRefund(id);
        assertEq(uint256(rounds.roundOf(id).refundReason), uint256(MakoRoundsV1.RefundReason.NoPrice));
    }

    /// @notice The last possible settle second, `submitDeadline - 1`, still settles, and a second
    /// valid submission, or a refund, cannot then touch the round.
    function test_LastSecondSettleWinsAndIsFinal() public {
        uint64 startTime = BASE + 3600;
        uint64 closeTime = startTime + 900;
        vm.prank(creatorA);
        uint256 id = rounds.schedule(startTime);
        _enter(id, address(0xA1), MakoRoundsV1.Side.Up, 1_000_000);
        _enter(id, address(0xB1), MakoRoundsV1.Side.Down, 1_000_000);

        bytes memory a = abi.encodePacked("anchor", id);
        bytes memory c = abi.encodePacked("close", id);
        mock.setReturnFor(a, _payload(uint32(startTime), 100e18));
        mock.setReturnFor(c, _payload(uint32(closeTime), 99e18));
        vm.warp(closeTime + 24 hours - 1);
        rounds.settle(id, a, c);

        vm.expectRevert(MakoRoundsV1.RoundAlreadyTerminal.selector);
        rounds.settle(id, a, c);
        vm.warp(closeTime + 24 hours);
        vm.expectRevert(MakoRoundsV1.RoundAlreadyTerminal.selector);
        rounds.finalizeRefund(id);
        assertEq(uint256(rounds.roundOf(id).outcome), uint256(MakoRoundsV1.Outcome.Down));
    }
}
