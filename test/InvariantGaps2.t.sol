// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MakoRoundsV1} from "../src/MakoRoundsV1.sol";
import {RoundSettlement} from "../src/RoundSettlement.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";
import {MockUSDC} from "./mocks/TokenMocks.sol";

/// @notice Written by the second adversarial review of T1.4 (`d946901..5988c58`), against
/// blueprint/INVARIANTS.md r8 and blueprint/SPEC.md sections 3 to 9. Each test passes on the contract at
/// `5988c58` and fails on a mutant of `src/MakoRoundsV1.sol` or `src/RoundSettlement.sol` that survived
/// the whole `forge test` suite. The mutant each one kills is named in its dev note.
///
/// @dev Same harness shape as `InvariantGaps.t.sol`: `MockVerifier` etched at the pinned
/// `VERIFIER_PROXY`, answering per submitted report through `setReturnFor`.
contract InvariantGaps2Test is Test {
    MakoRoundsV1 internal rounds;
    MockVerifier internal mock;
    MockUSDC internal usdc;

    address internal constant VERIFIER = 0x72790f9eB82db492a7DDb6d2af22A270Dcc3Db64;
    address internal constant TREASURY = address(0x7777);
    address internal creatorA = address(0xC1);
    address internal up1 = address(0xA1);
    address internal up2 = address(0xA2);
    address internal down1 = address(0xD1);
    address internal down2 = address(0xD2);

    /// @dev 1789500000 % 60 == 0.
    uint64 internal constant BASE = 1789500000;
    uint64 internal constant ST = BASE + 3600;
    uint64 internal constant CT = ST + 900;

    function setUp() public {
        vm.warp(BASE);
        usdc = new MockUSDC();
        address[] memory creators = new address[](1);
        creators[0] = creatorA;
        rounds = new MakoRoundsV1(TREASURY, address(usdc), creators);

        MockVerifier template = new MockVerifier();
        vm.etch(VERIFIER, address(template).code);
        mock = MockVerifier(VERIFIER);

        address[4] memory funded = [up1, up2, down1, down2];
        for (uint256 i = 0; i < funded.length; i++) {
            usdc.mint(funded[i], 1_000_000_000_000);
            vm.prank(funded[i]);
            usdc.approve(address(rounds), type(uint256).max);
        }
    }

    function _payload(uint32 observedAt, int192 price, int192 bid, int192 ask) internal pure returns (bytes memory) {
        return abi.encode(
            RoundSettlement.FEED_ID,
            uint32(observedAt),
            uint32(observedAt),
            uint192(0),
            uint192(0),
            uint32(observedAt) + 30 days,
            price,
            bid,
            ask
        );
    }

    function _enter(uint256 id, address who, MakoRoundsV1.Side side, uint256 amount) internal {
        vm.prank(who);
        rounds.enter(id, side, amount);
    }

    /// @dev Arms zero-spread reports at `anchorPrice` and `closePrice`, warps to closeTime and settles.
    function _settle(uint256 id, int192 anchorPrice, int192 closePrice) internal {
        bytes memory a = abi.encodePacked(hex"a0", id);
        bytes memory c = abi.encodePacked(hex"c0", id);
        mock.setReturnFor(a, _payload(uint32(ST), anchorPrice, anchorPrice, anchorPrice));
        mock.setReturnFor(c, _payload(uint32(CT), closePrice, closePrice, closePrice));
        vm.warp(CT);
        rounds.settle(id, a, c);
    }

    // ---------------------------------------------------------------------------------------------
    // N17 and N19 on a DOWN-winning round. Every claim test in the suite settles UP.
    // ---------------------------------------------------------------------------------------------

    /// @notice N17: "once the last winner claims, sum(payouts) + protocolFee + creatorFee + remainder =
    /// total exactly, with the remainder credited to the treasury; before that, sum(claimed) <=
    /// distributable", on a round DOWN wins. SPEC §7: losers receive nothing; each winner receives
    /// floor(s_i * distributable / W).
    /// @dev Kills four mutants that each survive the whole suite at `5988c58`, because no test claims
    /// on a DOWN-winning round:
    ///   M1  `stake.side == (r.outcome == Outcome.Up ? Side.Up : Side.Down)` -> `stake.side == Side.Up`
    ///       (DOWN winners are refused and UP losers are paid)
    ///   M2  `winningPool = r.outcome == Outcome.Up ? r.upPool : r.downPool` -> `r.upPool`
    ///   M3  `winners = r.outcome == Outcome.Up ? r.upEntrants : r.downEntrants` -> `r.upEntrants`
    ///   M4  `else r.downEntrants++` -> `else r.downEntrants += 0`
    /// M3 needs the two sides to have DIFFERENT entrant counts, so UP has one entrant and DOWN two.
    function test_DownWinnersArePaidAndTheRemainderIsSwept() public {
        vm.prank(creatorA);
        uint256 id = rounds.schedule(ST);
        uint256 d1 = 10_000_001;
        uint256 d2 = 10_000_002;
        uint256 u1 = 33_333_333;
        uint256 u2 = 7_777_777;
        _enter(id, up1, MakoRoundsV1.Side.Up, u1);
        // A top-up by the same loser: ONE UP entrant against TWO DOWN winners, so a winner count read
        // from the wrong side (M3) sweeps after the first DOWN claim instead of the last.
        _enter(id, up1, MakoRoundsV1.Side.Up, u2);
        _enter(id, down1, MakoRoundsV1.Side.Down, d1);
        _enter(id, down2, MakoRoundsV1.Side.Down, d2);
        uint256 total = u1 + u2 + d1 + d2;

        _settle(id, 100e18, 99e18);
        MakoRoundsV1.Round memory r = rounds.roundOf(id);
        assertEq(uint256(r.outcome), uint256(MakoRoundsV1.Outcome.Down), "setup: DOWN wins");
        uint256 afterSettle = rounds.treasuryBalance();

        // Losers on the UP side are owed nothing.
        vm.prank(up1);
        vm.expectRevert(MakoRoundsV1.NothingOwed.selector);
        rounds.claim(id);

        // First DOWN winner: exactly the floored share, and no sweep yet.
        uint256 b1 = usdc.balanceOf(down1);
        vm.prank(down1);
        rounds.claim(id);
        uint256 p1 = usdc.balanceOf(down1) - b1;
        assertEq(p1, (d1 * r.distributable) / (d1 + d2), "DOWN winner 1 is paid floor(s * distributable / W)");
        assertEq(rounds.treasuryBalance(), afterSettle, "no sweep while a DOWN winner is still to claim");

        // Last DOWN winner: exactly the floored share, and the remainder is swept to the treasury.
        uint256 b2 = usdc.balanceOf(down2);
        vm.prank(down2);
        rounds.claim(id);
        uint256 p2 = usdc.balanceOf(down2) - b2;
        assertEq(p2, (d2 * r.distributable) / (d1 + d2), "DOWN winner 2 is paid floor(s * distributable / W)");

        uint256 remainder = r.distributable - p1 - p2;
        assertGt(remainder, 0, "the stakes must produce a real remainder or this test proves nothing");
        assertEq(rounds.treasuryBalance(), afterSettle + remainder, "the last DOWN winner sweeps the remainder");

        vm.prank(creatorA);
        rounds.claim(id);
        assertEq(p1 + p2 + r.protocolFee + r.creatorFee + remainder, total, "N17: conservation on a DOWN win");

        vm.prank(TREASURY);
        rounds.withdrawTreasury();
        assertEq(usdc.balanceOf(address(rounds)), 0, "a DOWN-won round drains to exactly zero");
    }

    // ---------------------------------------------------------------------------------------------
    // N3: a round with an EMPTY UP side. Every one-sided settle test in the suite empties DOWN.
    // ---------------------------------------------------------------------------------------------

    /// @notice N3: "A round with an empty side refunds (OneSided) ... whatever the price". SPEC §5.2:
    /// "both pools are non-empty (otherwise the round is OneSided, §6)". A round with DOWN entries and
    /// no UP entries must never settle.
    /// @dev Kills M5, which survives the whole suite: `if (r.upPool == 0 || r.downPool == 0) revert
    /// RoundIsOneSided();` -> `if (r.downPool == 0) revert RoundIsOneSided();`. On the mutant this round
    /// settles UP with no winners, so `distributable` belongs to nobody and is locked in the contract
    /// forever, and the protocol fee is charged on a round that had to refund.
    function test_DownOnlyRoundCannotSettle() public {
        vm.prank(creatorA);
        uint256 id = rounds.schedule(ST);
        _enter(id, down1, MakoRoundsV1.Side.Down, 10_000_000);

        bytes memory a = abi.encodePacked(hex"a0", id);
        bytes memory c = abi.encodePacked(hex"c0", id);
        mock.setReturnFor(a, _payload(uint32(ST), 100e18, 100e18, 100e18));
        mock.setReturnFor(c, _payload(uint32(CT), 101e18, 101e18, 101e18));
        vm.warp(CT);
        vm.expectRevert(MakoRoundsV1.RoundIsOneSided.selector);
        rounds.settle(id, a, c);

        assertEq(rounds.pendingSettlement().length, 0, "SPEC 5.1: a DOWN-only round is never listed as pending");

        rounds.finalizeRefund(id);
        assertEq(uint256(rounds.roundOf(id).refundReason), uint256(MakoRoundsV1.RefundReason.OneSided));
    }

    // ---------------------------------------------------------------------------------------------
    // N1 and N9: the outcome comes from `price`, not from `bid` or `ask`.
    // ---------------------------------------------------------------------------------------------

    /// @notice N9: "UP iff close.price > anchor.price". N14: both prices are stored. Every other
    /// settlement test uses bid == price == ask, so no test can tell `price` from `bid` or `ask`.
    /// @dev Kills two mutants of `src/RoundSettlement.sol` that survive the whole suite: the returned
    /// struct's `price: price` becomes `price: bid` (M8) or `price: ask` (M12). Here the price rises
    /// while both the bid and the ask fall, all inside `MAX_SPREAD_BPS`, so only the real price says UP.
    function test_OutcomeIsDecidedByPriceNotByBidOrAsk() public {
        vm.prank(creatorA);
        uint256 id = rounds.schedule(ST);
        _enter(id, up1, MakoRoundsV1.Side.Up, 10_000_000);
        _enter(id, down1, MakoRoundsV1.Side.Down, 10_000_000);

        bytes memory a = hex"a1a1";
        bytes memory c = hex"c1c1";
        // anchor: bid 99.99, price 100.000, ask 100.01  (2 bps wide)
        // close:  bid 99.98, price 100.001, ask 100.005 (2.5 bps wide)
        mock.setReturnFor(a, _payload(uint32(ST), 100e18, 99.99e18, 100.01e18));
        mock.setReturnFor(c, _payload(uint32(CT), 100.001e18, 99.98e18, 100.005e18));
        vm.warp(CT);
        rounds.settle(id, a, c);

        MakoRoundsV1.Round memory r = rounds.roundOf(id);
        assertEq(uint256(r.outcome), uint256(MakoRoundsV1.Outcome.Up), "the price rose, so UP wins");
        assertEq(r.anchorPrice, 100e18, "the stored anchor is the report's price");
        assertEq(r.closePrice, 100.001e18, "the stored close is the report's price");
    }

    // ---------------------------------------------------------------------------------------------
    // SPEC §7 fees: the SMALLER side, whichever side it is, and floored.
    // ---------------------------------------------------------------------------------------------

    /// @notice SPEC §7: `creatorFee = floor(min(up, down) * CREATOR_FEE_BPS / 10000)` and
    /// `protocolFee = floor(total * PROTOCOL_FEE_BPS / 10000)`. Here UP is the LARGER side and neither
    /// product divides evenly.
    /// @dev Kills three mutants that survive the whole suite. `test_FeesFollowTheSpecFormula` uses
    /// up 10 and down 30 USDC, so the smaller side is always UP and both fees divide exactly:
    ///   M11 `smaller = r.upPool < r.downPool ? r.upPool : r.downPool` -> `smaller = r.upPool`
    ///   M6  protocol fee rounded up: `(total * PROTOCOL_FEE_BPS + 9_999) / 10_000`
    ///   M7  creator fee rounded up:  `(smaller * CREATOR_FEE_BPS + 9_999) / 10_000`
    /// Every conservation assertion in the suite reads the fees back from the contract, so it holds
    /// for any fee values whatsoever.
    function test_FeesAreFlooredAndTakenOnTheSmallerSideWhicheverItIs() public {
        vm.prank(creatorA);
        uint256 id = rounds.schedule(ST);
        uint256 up = 30_000_099;
        uint256 down = 10_000_049;
        _enter(id, up1, MakoRoundsV1.Side.Up, up);
        _enter(id, down1, MakoRoundsV1.Side.Down, down);
        _settle(id, 100e18, 101e18);

        MakoRoundsV1.Round memory r = rounds.roundOf(id);
        // Independent arithmetic, written out: total 40_000_148, 1% = 400_001.48, floor 400_001.
        // Smaller side 10_000_049, 2% = 200_000.98, floor 200_000.
        assertEq(r.protocolFee, 400_001, "protocol fee is floor(1% of the total)");
        assertEq(r.creatorFee, 200_000, "creator fee is floor(2% of the smaller side, here DOWN)");
        assertEq(r.distributable, 40_000_148 - 400_001 - 200_000);
    }

    // ---------------------------------------------------------------------------------------------
    // N18 and SPEC §4: the per-round times every courier and client reads.
    // ---------------------------------------------------------------------------------------------

    /// @notice N18: "closeTime = startTime + DURATION"; SPEC §4: "submitDeadline = closeTime +
    /// SUBMIT_WINDOW", `entryCloseTime = startTime - ENTRY_LEAD`. The couriers and the watchdog read
    /// these from `closeTimeOf`, `submitDeadlineOf` and `RoundScheduled`, never from `_settle`.
    /// @dev Kills three mutants that survive the whole suite: `closeTimeOf` one minute late (M15),
    /// `submitDeadlineOf` an hour early (M16), and `RoundScheduled` emitting a closeTime and
    /// submitDeadline a minute late (M17). No test reads either view or the scheduling event.
    function test_PublishedRoundTimesMatchTheSchedule() public {
        vm.expectEmit(true, true, false, true, address(rounds));
        emit MakoRoundsV1.RoundScheduled(1, creatorA, BASE, ST, ST - 60, ST + 900, ST + 900 + 24 hours);
        vm.prank(creatorA);
        uint256 id = rounds.schedule(ST);

        assertEq(rounds.entryCloseTimeOf(id), ST - 60, "entryCloseTime = startTime - ENTRY_LEAD");
        assertEq(rounds.closeTimeOf(id), ST + 900, "closeTime = startTime + DURATION");
        assertEq(rounds.submitDeadlineOf(id), ST + 900 + 24 hours, "submitDeadline = closeTime + SUBMIT_WINDOW");
    }

    // ---------------------------------------------------------------------------------------------
    // N22 and SPEC §7: an OUTBOUND transfer that returns false fails.
    // ---------------------------------------------------------------------------------------------

    /// @notice N22: "false-returning, reverting, no-return and fee-on-transfer tokens are handled as
    /// SPEC §7 says". SPEC §7: "a call that reverts, returns `false`, or returns malformed data fails",
    /// and "Payouts use the same safe-call wrapper". A payout whose `transfer` moves the full amount but
    /// returns `false` must fail, not be treated as paid.
    /// @dev Kills M18, which survives the whole suite: the outbound return-value line in
    /// `_safeTransferOut` is deleted. `FalseReturnUSDC` overrides only `transferFrom`, so every
    /// false-return test is inbound; the outbound balance check cannot see a transfer that moved the
    /// right amount and then reported failure.
    function test_OutboundTransferReturningFalseReverts() public {
        FalseOnPayoutUSDC tok = new FalseOnPayoutUSDC();
        address[] memory cs = new address[](1);
        cs[0] = creatorA;
        MakoRoundsV1 rr = new MakoRoundsV1(TREASURY, address(tok), cs);
        address[2] memory who = [up1, down1];
        for (uint256 i = 0; i < 2; i++) {
            tok.mint(who[i], 1_000_000_000);
            vm.prank(who[i]);
            tok.approve(address(rr), type(uint256).max);
        }
        vm.prank(creatorA);
        uint256 id = rr.schedule(ST);
        vm.prank(up1);
        rr.enter(id, MakoRoundsV1.Side.Up, 10_000_000);
        vm.prank(down1);
        rr.enter(id, MakoRoundsV1.Side.Down, 30_000_000);

        bytes memory a = hex"a2a2";
        bytes memory c = hex"c2c2";
        mock.setReturnFor(a, _payload(uint32(ST), 100e18, 100e18, 100e18));
        mock.setReturnFor(c, _payload(uint32(CT), 101e18, 101e18, 101e18));
        vm.warp(CT);
        rr.settle(id, a, c);

        tok.setReturnFalse(true);
        vm.prank(up1);
        vm.expectRevert(MakoRoundsV1.TransferFailed.selector);
        rr.claim(id);
        assertFalse(rr.stakeClaimed(id, up1), "a payout the token reported as failed is not recorded as paid");
    }
}

/// @notice Moves the tokens on `transfer` and then returns `false` when told to. Inbound is well behaved.
contract FalseOnPayoutUSDC is MockUSDC {
    bool public returnFalse;

    function setReturnFalse(bool yes) external {
        returnFalse = yes;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return !returnFalse;
    }
}
