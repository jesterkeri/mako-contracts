// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MakoMarkets} from "../src/MakoMarkets.sol";

contract MakoMarketsTest is Test {
    MakoMarkets mako;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);
    address treasury = address(0x7);

    function setUp() public {
        mako = new MakoMarkets(treasury);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    function _createCryptoMarket() internal returns (uint256 id) {
        id = mako.createMarket(
            MakoMarkets.MarketType.CRYPTO,
            bytes32("ETH:gt:3500"),
            uint64(block.timestamp + 1 hours),
            "Will ETH close above $3500?"
        );
    }

    function _createFootballMarket() internal returns (uint256 id) {
        id = mako.createMarket(
            MakoMarkets.MarketType.FOOTBALL,
            bytes32("514237:home_win:0"),
            uint64(block.timestamp + 2 hours),
            "Will Arsenal beat Chelsea?"
        );
    }

    function _createBasketballMarket() internal returns (uint256 id) {
        id = mako.createMarket(
            MakoMarkets.MarketType.BASKETBALL,
            bytes32("18923:home_win:0"),
            uint64(block.timestamp + 3 hours),
            "Will the Lakers beat the Celtics?"
        );
    }

    // ------------------------------------------------------------------
    // 1. Happy path: create + bet + resolve + claim
    // ------------------------------------------------------------------
    function test_happyPath_createBetResolveClaim() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet{value: 60 ether}(id, true); // YES
        vm.prank(bob);
        mako.placeBet{value: 40 ether}(id, false); // NO

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarkets.Outcome.YES);

        uint256 before_ = alice.balance;
        vm.prank(alice);
        mako.claim(id);

        // alice is the only YES bettor. payoutPool = 100 * 0.97 = 97 MON → all hers.
        assertEq(alice.balance - before_, 97 ether);
    }

    // ------------------------------------------------------------------
    // 2. Parimutuel math: 60/40 split with a hypothetical 10 MON bet
    // ------------------------------------------------------------------
    function test_parimutuelMath_60_40_split() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet{value: 60 ether}(id, true);
        vm.prank(bob);
        mako.placeBet{value: 40 ether}(id, false);

        // previewPayout simulates the new bet entering the pool:
        //   newYes=70, newNo=40, total=110, fees=3%, payoutPool=106.7
        //   return = 10 * 106.7 / 70 = 15.2428571... MON
        uint256 preview = mako.previewPayout(id, true, 10 ether);
        assertApproxEqAbs(preview, 15.242857142857142857 ether, 1e12);

        // And the live multiplier for YES side (before the new bet) should be 100*0.97/60 = 1.6167x
        uint256 mul = mako.multiplier(id, true);
        assertApproxEqAbs(mul, 1.616666666666666666 ether, 1e12);
    }

    // ------------------------------------------------------------------
    // 3. Double claim reverts
    // ------------------------------------------------------------------
    function test_doubleClaim_reverts() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet{value: 1 ether}(id, true);
        vm.prank(bob);
        mako.placeBet{value: 1 ether}(id, false);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarkets.Outcome.YES);

        vm.prank(alice);
        mako.claim(id);

        vm.prank(alice);
        vm.expectRevert(MakoMarkets.AlreadyClaimed.selector);
        mako.claim(id);
    }

    // ------------------------------------------------------------------
    // 4. Bet after close reverts
    // ------------------------------------------------------------------
    function test_betAfterClose_reverts() public {
        uint256 id = _createCryptoMarket();
        vm.warp(block.timestamp + 2 hours); // past closeTime

        vm.prank(alice);
        vm.expectRevert(MakoMarkets.MarketClosed.selector);
        mako.placeBet{value: 1 ether}(id, true);
    }

    // ------------------------------------------------------------------
    // 5. One-sided pool → forced refund (the #1 Codex bait)
    // ------------------------------------------------------------------
    function test_zeroPool_autoRefund() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet{value: 5 ether}(id, true);
        // nobody bets NO

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarkets.Outcome.YES); // forced to REFUND internally

        MakoMarkets.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarkets.Outcome.REFUND));

        uint256 before_ = alice.balance;
        vm.prank(alice);
        mako.claim(id);
        assertEq(alice.balance - before_, 5 ether); // full refund, no fees
    }

    // ------------------------------------------------------------------
    // 6. Creator fee accrues + is claimable once
    // ------------------------------------------------------------------
    function test_creatorFee_creatorCreatedMarket() public {
        vm.prank(carol);
        uint256 id = mako.createMarket(
            MakoMarkets.MarketType.BASKETBALL,
            bytes32("18923:home_win:0"),
            uint64(block.timestamp + 1 hours),
            "Will the Lakers beat the Celtics?"
        );

        vm.prank(alice);
        mako.placeBet{value: 60 ether}(id, true);
        vm.prank(bob);
        mako.placeBet{value: 40 ether}(id, false);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarkets.Outcome.YES);

        uint256 before_ = carol.balance;
        vm.prank(carol);
        mako.claimCreatorFee(id);
        assertEq(carol.balance - before_, 2 ether); // 2% of 100

        // second claim reverts
        vm.prank(carol);
        vm.expectRevert(MakoMarkets.AlreadyClaimed.selector);
        mako.claimCreatorFee(id);
    }

    // ------------------------------------------------------------------
    // 7. Treasury accumulates 2% protocol fee
    // ------------------------------------------------------------------
    function test_treasuryAccumulates() public {
        uint256 id = _createCryptoMarket();
        vm.prank(alice);
        mako.placeBet{value: 60 ether}(id, true);
        vm.prank(bob);
        mako.placeBet{value: 40 ether}(id, false);
        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarkets.Outcome.YES);
        assertEq(mako.treasuryBalance(), 1 ether); // 1% of 100
    }

    // ------------------------------------------------------------------
    // 8. Only the resolver/owner can resolve
    // ------------------------------------------------------------------
    function test_onlyResolver_canResolve() public {
        uint256 id = _createCryptoMarket();
        vm.prank(alice);
        mako.placeBet{value: 1 ether}(id, true);
        vm.prank(bob);
        mako.placeBet{value: 1 ether}(id, false);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(alice);
        vm.expectRevert(MakoMarkets.NotResolver.selector);
        mako.resolveMarket(id, MakoMarkets.Outcome.YES);
    }

    // ------------------------------------------------------------------
    // 9. Football market is just a different enum value — same flow
    // ------------------------------------------------------------------
    function test_footballMarket_happyPath() public {
        uint256 id = _createFootballMarket();
        MakoMarkets.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.mType), uint8(MakoMarkets.MarketType.FOOTBALL));

        vm.prank(alice);
        mako.placeBet{value: 30 ether}(id, true);
        vm.prank(bob);
        mako.placeBet{value: 70 ether}(id, false);

        vm.warp(block.timestamp + 3 hours);
        mako.resolveMarket(id, MakoMarkets.Outcome.NO);

        uint256 before_ = bob.balance;
        vm.prank(bob);
        mako.claim(id);
        // bob is only NO bettor → gets all 97 MON
        assertEq(bob.balance - before_, 97 ether);
    }

    // ------------------------------------------------------------------
    // 10. Dust-bet grief attack → forced refund (Codex finding #1)
    // ------------------------------------------------------------------
    function test_dustBetAttack_triggersRefund() public {
        uint256 id = _createCryptoMarket();

        // Alice places a legit 60 MON YES. Nobody takes NO organically.
        vm.prank(alice);
        mako.placeBet{value: 60 ether}(id, true);

        // Attacker plants MIN_BET on the empty side to try to unlock fee extraction.
        vm.prank(carol);
        mako.placeBet{value: 0.001 ether}(id, false);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarkets.Outcome.YES);

        // Ratio 0.001 / 60 = 0.00167%, well below 1% threshold → forced REFUND.
        MakoMarkets.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarkets.Outcome.REFUND));

        // Alice gets her full 60 MON back, no fees taken.
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        mako.claim(id);
        assertEq(alice.balance - aliceBefore, 60 ether);

        // Attacker gets her dust back — attack failed to extract anything.
        uint256 carolBefore = carol.balance;
        vm.prank(carol);
        mako.claim(id);
        assertEq(carol.balance - carolBefore, 0.001 ether);

        // Creator fee claim reverts because outcome is REFUND.
        vm.expectRevert(MakoMarkets.BadOutcome.selector);
        mako.claimCreatorFee(id);
    }

    // ------------------------------------------------------------------
    // 11. Pool clearly above the dynamic threshold settles normally
    // ------------------------------------------------------------------
    function test_aboveDynamicThreshold_settles() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet{value: 60 ether}(id, true);
        // Bob places 5% of YES side = 3 MON, clearly above the ~4.08% dynamic
        // threshold at the current 2% creator fee.
        vm.prank(bob);
        mako.placeBet{value: 3 ether}(id, false);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarkets.Outcome.YES);

        MakoMarkets.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarkets.Outcome.YES));

        // Alice payout: 60 * (63 * 0.97) / 60 = 63 * 0.97 = 61.11 MON
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        mako.claim(id);
        assertApproxEqAbs(alice.balance - aliceBefore, 61.11 ether, 1e12);
    }

    // ------------------------------------------------------------------
    // 12. forceRefund safety valve — works after grace, reverts before (Codex finding #2)
    // ------------------------------------------------------------------
    function test_forceRefund_afterGrace() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet{value: 10 ether}(id, true);
        vm.prank(bob);
        mako.placeBet{value: 10 ether}(id, false);

        // closeTime passes, but resolver abandons the market
        vm.warp(block.timestamp + 1 hours + 1);

        // Inside the 24h grace window → forceRefund reverts
        vm.prank(alice);
        vm.expectRevert(MakoMarkets.StillInGrace.selector);
        mako.forceRefund(id);

        // After 24h grace, anyone can force the refund
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(alice); // NOT the resolver or owner — just any user
        mako.forceRefund(id);

        MakoMarkets.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarkets.Outcome.REFUND));
        assertTrue(m.resolved);

        // Both bettors get full refunds
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        mako.claim(id);
        assertEq(alice.balance - aliceBefore, 10 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        mako.claim(id);
        assertEq(bob.balance - bobBefore, 10 ether);

        // Cannot forceRefund again — already resolved
        vm.expectRevert(MakoMarkets.AlreadyResolved.selector);
        mako.forceRefund(id);
    }

    // ------------------------------------------------------------------
    // 13. Pool below the dynamic threshold → forced refund
    // ------------------------------------------------------------------
    function test_belowDynamicThreshold_refunds() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet{value: 60 ether}(id, true);
        // Bob places 1.67% of YES side = 1 MON, BELOW the ~2.02% dynamic threshold.
        vm.prank(bob);
        mako.placeBet{value: 1 ether}(id, false);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarkets.Outcome.YES);

        // Too-thin opposing liquidity → forced REFUND
        MakoMarkets.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarkets.Outcome.REFUND));

        // Both sides get stakes back, no fees taken
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        mako.claim(id);
        assertEq(alice.balance - aliceBefore, 60 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        mako.claim(id);
        assertEq(bob.balance - bobBefore, 1 ether);

        assertEq(mako.treasuryBalance(), 0);
    }

    // ------------------------------------------------------------------
    // 14. Creator-as-attacker profitability check (Codex round 2)
    // ------------------------------------------------------------------
    // At exactly the dynamic threshold, a creator who self-dust-bets the losing side
    // must end up with a NEGATIVE net P&L even after claiming the creator fee.
    function test_creatorAttacker_isUnprofitable_atThreshold() public {
        // Carol is the market creator (and the attacker)
        vm.prank(carol);
        uint256 id = mako.createMarket(
            MakoMarkets.MarketType.BASKETBALL,
            bytes32("18923:home_win:0"),
            uint64(block.timestamp + 1 hours),
            "Will the Lakers beat the Celtics?"
        );

        // Alice places a legit 60 MON on YES
        vm.prank(alice);
        mako.placeBet{value: 60 ether}(id, true);

        // Record Carol's balance BEFORE she executes the attack
        uint256 carolInitial = carol.balance;

        // Carol plants a bet at EXACTLY the dynamic threshold on the losing side.
        // This is the most profitable attack point — if she's unprofitable here,
        // she's unprofitable everywhere above the threshold too.
        uint256 threshold = mako.minLiquidityRatioBps();
        uint256 carolBet = (60 ether * threshold) / 10000; // ~1.212 MON at 202 bps
        vm.prank(carol);
        mako.placeBet{value: carolBet}(id, false);

        // Market settles — we're AT the threshold, not below.
        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarkets.Outcome.YES);
        MakoMarkets.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarkets.Outcome.YES));

        // Carol claims her creator fee — her only non-zero revenue from the attack.
        vm.prank(carol);
        mako.claimCreatorFee(id);

        // Carol cannot claim() anything — she bet on the losing side.
        vm.prank(carol);
        vm.expectRevert(MakoMarkets.NoPosition.selector);
        mako.claim(id);

        // Net P&L must be strictly negative. At 2x break-even, she loses ~1% of X ≈ 0.6 MON.
        uint256 carolFinal = carol.balance;
        assertLt(carolFinal, carolInitial);
        uint256 netLoss = carolInitial - carolFinal;
        assertGt(netLoss, 0.5 ether); // loses at least 0.5 MON — attack is a money pit
    }

    // ------------------------------------------------------------------
    // 15. minLiquidityRatioBps math spot-check
    // ------------------------------------------------------------------
    function test_minLiquidityRatioBps_math() public view {
        // Default creatorFeeBps = 200 → breakeven = 200*10000/9800 = 204 → 2x = 408 bps
        assertEq(mako.minLiquidityRatioBps(), 408);
    }

    // ------------------------------------------------------------------
    // 16. Basketball market is just a different enum value — same flow
    // ------------------------------------------------------------------
    function test_basketballMarket_happyPath() public {
        uint256 id = _createBasketballMarket();
        MakoMarkets.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.mType), uint8(MakoMarkets.MarketType.BASKETBALL));

        vm.prank(alice);
        mako.placeBet{value: 60 ether}(id, true);
        vm.prank(bob);
        mako.placeBet{value: 40 ether}(id, false);

        vm.warp(block.timestamp + 4 hours);
        mako.resolveMarket(id, MakoMarkets.Outcome.YES);

        uint256 before_ = alice.balance;
        vm.prank(alice);
        mako.claim(id);
        assertEq(alice.balance - before_, 97 ether);
    }

    // ------------------------------------------------------------------
    // 17. Enum ordering is append-only — existing values don't shift
    // ------------------------------------------------------------------
    // Guards against anyone reordering the enum and silently remapping
    // on-chain state. If this ever fails, every existing `mType` in
    // storage is pointing at the wrong sport.
    function test_enumOrdering_isStable() public pure {
        assertEq(uint8(MakoMarkets.MarketType.FOOTBALL), 0);
        assertEq(uint8(MakoMarkets.MarketType.CRYPTO), 1);
        assertEq(uint8(MakoMarkets.MarketType.BASKETBALL), 2);
    }

    // Allow this test contract to receive MON refunds / payouts from its setUp-deployed mako.
    receive() external payable {}
}
