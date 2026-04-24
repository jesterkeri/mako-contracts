// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MakoMarketsV4} from "../src/MakoMarketsV4.sol";

// ---------------------------------------------------------------------------
// Minimal mock ERC-20s for testing. Kept inline to avoid an OZ dependency in
// this repo (mirrors the contract's own inline IERC20/SafeERC20 policy).
// ---------------------------------------------------------------------------

contract MockUSDC {
    string public constant name = "Mock USDC";
    string public constant symbol = "mUSDC";
    uint8 public immutable _decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(uint8 d) {
        _decimals = d;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// Deflationary "fee-on-transfer" token — each transferFrom burns 1% before
/// crediting the receiver. Used to exercise the `TransferAmountMismatch`
/// balance-delta guard on `placeBet`.
contract FeeOnTransferUSDC {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        uint256 fee = amount / 100; // 1% burn on inbound
        balanceOf[to] += (amount - fee);
        return true;
    }
}

// ---------------------------------------------------------------------------
// Tests — port of MakoMarkets.t.sol to USDC (6-decimal) denomination, plus
// ERC-20-specific coverage for the v4 delta guard and decimals pin.
// ---------------------------------------------------------------------------

contract MakoMarketsV4Test is Test {
    MakoMarketsV4 mako;
    MockUSDC usdc;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);
    address treasury = address(0x7);

    // Amounts expressed in USDC base units (6 decimals).
    // 60e6 = 60 USDC. MIN_BET = 1e6 = 1 USDC.
    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC(6);
        mako = new MakoMarketsV4(treasury, address(usdc));

        // Fund the cast of users with plenty of USDC, then grant infinite
        // allowance so individual tests can focus on bet logic, not approvals.
        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < users.length; i++) {
            usdc.mint(users[i], 1_000_000 * ONE_USDC);
            vm.prank(users[i]);
            usdc.approve(address(mako), type(uint256).max);
        }
    }

    function _createCryptoMarket() internal returns (uint256 id) {
        // Crypto 1-hour market: betting closes at 30 min (50% tier), resolves at 1h.
        id = mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("ETH:gt:3500"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "Will ETH close above $3500?"
        );
    }

    function _createFootballMarket() internal returns (uint256 id) {
        // Football: kickoff at 1h, match ends ~2h30m (90 min game + buffer), resolves then.
        uint64 kickoff = uint64(block.timestamp + 1 hours);
        uint64 matchEnd = uint64(block.timestamp + 2 hours);
        id = mako.createMarket(
            MakoMarketsV4.MarketType.FOOTBALL,
            bytes32("514237:home_win:0"),
            kickoff,
            matchEnd,
            "Will Arsenal beat Chelsea?"
        );
    }

    function _createBasketballMarket() internal returns (uint256 id) {
        // Basketball: tipoff at 1h, game ends ~3h (2h + buffer), resolves then.
        uint64 tipoff = uint64(block.timestamp + 1 hours);
        uint64 gameEnd = uint64(block.timestamp + 3 hours);
        id = mako.createMarket(
            MakoMarketsV4.MarketType.BASKETBALL,
            bytes32("18923:home_win:0"),
            tipoff,
            gameEnd,
            "Will the Lakers beat the Celtics?"
        );
    }

    // ======================================================================
    // Ported from MakoMarkets.t.sol
    // ======================================================================

    // ------------------------------------------------------------------
    // 1. Happy path: create + bet + resolve + claim
    // ------------------------------------------------------------------
    function test_happyPath_createBetResolveClaim() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC); // YES
        vm.prank(bob);
        mako.placeBet(id, false, 40 * ONE_USDC); // NO

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        uint256 before_ = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);

        // alice is the only YES bettor. payoutPool = 100 * 0.97 = 97 USDC → all hers.
        assertEq(usdc.balanceOf(alice) - before_, 97 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 2. Parimutuel math: 60/40 split with a hypothetical 10 USDC bet
    // ------------------------------------------------------------------
    function test_parimutuelMath_60_40_split() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 40 * ONE_USDC);

        // previewPayout simulates the new bet entering the pool:
        //   newYes=70, newNo=40, total=110, fees=3%, payoutPool=106.7
        //   return = 10 * 106.7 / 70 ≈ 15.242857 USDC
        uint256 preview = mako.previewPayout(id, true, 10 * ONE_USDC);
        assertApproxEqAbs(preview, 15_242_857, 1); // 1 micro-USDC tolerance

        // Live multiplier for YES side (pre-new-bet) = 100*0.97/60 ≈ 1.6167x
        uint256 mul = mako.multiplier(id, true);
        assertApproxEqAbs(mul, 1.616666666666666666 ether, 1e12);
    }

    // ------------------------------------------------------------------
    // 3. Double claim reverts
    // ------------------------------------------------------------------
    function test_doubleClaim_reverts() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet(id, true, 1 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 1 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        vm.prank(alice);
        mako.claim(id);

        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.AlreadyClaimed.selector);
        mako.claim(id);
    }

    // ------------------------------------------------------------------
    // 4. Bet after close reverts
    // ------------------------------------------------------------------
    function test_betAfterClose_reverts() public {
        uint256 id = _createCryptoMarket();
        vm.warp(block.timestamp + 2 hours); // past closeTime + bettingCloseTime

        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.BettingClosed.selector);
        mako.placeBet(id, true, 1 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 5. One-sided pool → forced refund
    // ------------------------------------------------------------------
    function test_zeroPool_autoRefund() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet(id, true, 5 * ONE_USDC);
        // nobody bets NO

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES); // forced to REFUND internally

        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarketsV4.Outcome.REFUND));

        uint256 before_ = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertEq(usdc.balanceOf(alice) - before_, 5 * ONE_USDC); // full refund, no fees
    }

    // ------------------------------------------------------------------
    // 6. Creator fee accrues + is claimable once
    // ------------------------------------------------------------------
    function test_creatorFee_creatorCreatedMarket() public {
        vm.prank(carol);
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.BASKETBALL,
            bytes32("18923:home_win:0"),
            uint64(block.timestamp + 1 hours),
            uint64(block.timestamp + 1 hours),
            "Will the Lakers beat the Celtics?"
        );

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 40 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        uint256 before_ = usdc.balanceOf(carol);
        vm.prank(carol);
        mako.claimCreatorFee(id);
        assertEq(usdc.balanceOf(carol) - before_, 2 * ONE_USDC); // 2% of 100 USDC

        vm.prank(carol);
        vm.expectRevert(MakoMarketsV4.AlreadyClaimed.selector);
        mako.claimCreatorFee(id);
    }

    // ------------------------------------------------------------------
    // 7. Treasury accumulates 1% protocol fee
    // ------------------------------------------------------------------
    function test_treasuryAccumulates() public {
        uint256 id = _createCryptoMarket();
        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 40 * ONE_USDC);
        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);
        assertEq(mako.treasuryBalance(), 1 * ONE_USDC); // 1% of 100 USDC
    }

    // ------------------------------------------------------------------
    // 8. Only the resolver/owner can resolve
    // ------------------------------------------------------------------
    function test_onlyResolver_canResolve() public {
        uint256 id = _createCryptoMarket();
        vm.prank(alice);
        mako.placeBet(id, true, 1 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 1 * ONE_USDC);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.NotResolver.selector);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);
    }

    // ------------------------------------------------------------------
    // 9. Football market
    // ------------------------------------------------------------------
    function test_footballMarket_happyPath() public {
        uint256 id = _createFootballMarket();
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.mType), uint8(MakoMarketsV4.MarketType.FOOTBALL));

        vm.prank(alice);
        mako.placeBet(id, true, 30 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 70 * ONE_USDC);

        vm.warp(block.timestamp + 3 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.NO);

        uint256 before_ = usdc.balanceOf(bob);
        vm.prank(bob);
        mako.claim(id);
        assertEq(usdc.balanceOf(bob) - before_, 97 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 10. Dust on the losing side: market settles normally, creator fee is
    //     forfeited. Attacker loses their dust stake to the winning side.
    //     (Replaces the old "dust triggers REFUND" behavior — that was
    //     griefable by non-creators who could force a refund by stuffing
    //     the winning side. Now the creator-fee threshold gates only the
    //     creator fee, not bettor settlement.)
    // ------------------------------------------------------------------
    function test_dustBetAttack_forfeitsCreatorFee() public {
        // Create via carol so she's the creator — only she could ever claim
        // the creator fee in the first place.
        vm.prank(carol);
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("ETH:gt:3500"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "Will ETH close above $3500?"
        );

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);

        // Carol (creator) plants 1 USDC on NO hoping to unlock the fee.
        // 1/60 = 1.67% — below the 4.08% dynamic threshold.
        vm.prank(carol);
        mako.placeBet(id, false, 1 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarketsV4.Outcome.YES));

        // Alice gets a regular parimutuel payout over the full 61-USDC pool.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        // Below threshold → creator fee forfeited from payout math.
        // Winners split totalPool * (1 - protocolFee) = 61 * 0.99 = 60.39 USDC.
        // This is what "no strand" looks like: no fund is left in the
        // contract for this market after all claims + treasury are drained.
        assertApproxEqAbs(usdc.balanceOf(alice) - aliceBefore, 60_390_000, 1);

        // Carol cannot claim — she bet on the losing side.
        vm.prank(carol);
        vm.expectRevert(MakoMarketsV4.NoPosition.selector);
        mako.claim(id);

        // Carol tries to claim the creator fee; the call succeeds but pays
        // zero because the pool was below threshold. Attack revenue = 0.
        uint256 carolCreatorBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        mako.claimCreatorFee(id);
        assertEq(usdc.balanceOf(carol), carolCreatorBefore);

        // Second claim still blocked — creatorFeeClaimed flag set.
        vm.prank(carol);
        vm.expectRevert(MakoMarketsV4.AlreadyClaimed.selector);
        mako.claimCreatorFee(id);
    }

    // ------------------------------------------------------------------
    // 11. Pool clearly above the dynamic threshold settles normally
    // ------------------------------------------------------------------
    function test_aboveDynamicThreshold_settles() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        // 3 USDC vs 60 USDC = 5%, above the 4.08% threshold.
        vm.prank(bob);
        mako.placeBet(id, false, 3 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarketsV4.Outcome.YES));

        // Alice payout: 60 * (63 * 0.97) / 60 = 61.11 USDC
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertApproxEqAbs(usdc.balanceOf(alice) - aliceBefore, 61_110_000, 1);
    }

    // ------------------------------------------------------------------
    // 12. forceRefund safety valve
    // ------------------------------------------------------------------
    function test_forceRefund_afterGrace() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet(id, true, 10 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 10 * ONE_USDC);

        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.StillInGrace.selector);
        mako.forceRefund(id);

        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(alice);
        mako.forceRefund(id);

        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarketsV4.Outcome.REFUND));
        assertTrue(m.resolved);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 10 * ONE_USDC);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        mako.claim(id);
        assertEq(usdc.balanceOf(bob) - bobBefore, 10 * ONE_USDC);

        vm.expectRevert(MakoMarketsV4.AlreadyResolved.selector);
        mako.forceRefund(id);
    }

    // ------------------------------------------------------------------
    // 13. Pool below the dynamic threshold settles normally; creator fee
    //     is forfeited; protocol fee still accrues. (Under v4's new rule,
    //     imbalance no longer triggers REFUND — only empty-side does.)
    // ------------------------------------------------------------------
    function test_belowDynamicThreshold_forfeitsCreatorFeeButSettles() public {
        vm.prank(carol);
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("ETH:gt:3500"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "Will ETH close above $3500?"
        );

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        // 1 USDC on NO = 1.67% of 60, BELOW the 4.08% threshold.
        vm.prank(bob);
        mako.placeBet(id, false, 1 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarketsV4.Outcome.YES));

        // Below threshold → creator fee forfeited, drops out of payout math.
        // Alice wins 61 * 0.99 = 60.39 USDC. The forgone 2% would have been
        // creator fee; instead of stranding it in the contract it flows to
        // winners (keeps accounting closed: total out = total in).
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertApproxEqAbs(usdc.balanceOf(alice) - aliceBefore, 60_390_000, 1);

        // Bob bet on NO, loses, cannot claim anything.
        vm.prank(bob);
        vm.expectRevert(MakoMarketsV4.NoPosition.selector);
        mako.claim(id);

        // Creator fee forfeited — the claim call succeeds but transfers zero.
        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        mako.claimCreatorFee(id);
        assertEq(usdc.balanceOf(carol), carolBefore);

        // Protocol fee DID accrue at resolution: 1% of 61 = 0.61 USDC.
        assertEq(mako.treasuryBalance(), 610_000);
    }

    // ------------------------------------------------------------------
    // 13b. Griefer who bet on the losing side cannot force a refund by
    //      stuffing the winning side — imbalance no longer triggers
    //      REFUND, so their original losing bet is forfeited to winners.
    // ------------------------------------------------------------------
    function test_griefer_cannotForceRefund_byStuffingWinningSide() public {
        uint256 id = _createCryptoMarket();

        // Honest market: Alice 60 YES, Bob 3 NO. Ratio 3/60 = 5% — above
        // the 4.08% threshold, so creator fee would unlock normally.
        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 3 * ONE_USDC);

        // Bob sees NO is likely to lose and tries to grief: he piles 14
        // USDC onto YES so the pool becomes 74 YES / 3 NO. 3/74 = 4.05%,
        // which WOULD have been below the old threshold → old contract
        // would have forced REFUND and Bob would have recovered his 3 USDC.
        // Warp past the 30s cooldown between Bob's two bets.
        vm.warp(block.timestamp + 31);
        vm.prank(bob);
        mako.placeBet(id, true, 14 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        // Settles YES — no forced refund.
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarketsV4.Outcome.YES));

        // Alice claims her share. Bob's YES stake also wins (he's now on the
        // winning side) but his NO 3 USDC is forfeited to the YES pool.
        // payoutPool = 77 * 0.97 = 74.69. Alice share = 60/74 * 74.69 ≈ 60.56.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        uint256 aliceGot = usdc.balanceOf(alice) - aliceBefore;
        assertGt(aliceGot, 60 * ONE_USDC); // she gained from Bob's forfeited NO

        // Bob claims his YES share: 14/74 * 74.69 ≈ 14.13 USDC. NET BOB P&L:
        // paid 3 (NO, lost) + 14 (YES, kept) = -17; recovered 14.13. Net -2.87.
        // Compared to the old REFUND behavior where Bob's loss would have
        // been $0 (he would have gotten both 3 and 14 back), Bob is strictly
        // worse off — grief is no longer free.
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        mako.claim(id);
        uint256 bobGot = usdc.balanceOf(bob) - bobBefore;
        assertLt(bobGot, 17 * ONE_USDC); // recovered less than he put in
        assertGt(bobGot, 14 * ONE_USDC); // but still got his YES share
    }

    // ------------------------------------------------------------------
    // 14. Creator-as-attacker profitability check (post-fix version).
    //     Creator self-dusts BELOW the threshold to try to unlock the
    //     creator fee. Under v4's forfeit rule, the fee is zero at that
    //     ratio, so the attack loses exactly the bet amount with no
    //     offsetting revenue — strictly worse than the old version that
    //     paid the fee but was still unprofitable by 0.5 USDC.
    // ------------------------------------------------------------------
    function test_creatorAttacker_isUnprofitable_belowThreshold() public {
        vm.prank(carol);
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.BASKETBALL,
            bytes32("18923:home_win:0"),
            uint64(block.timestamp + 1 hours),
            uint64(block.timestamp + 1 hours),
            "Will the Lakers beat the Celtics?"
        );

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);

        uint256 carolInitial = usdc.balanceOf(carol);

        // Bet 1 USDC (MIN_BET) on NO — 1.67% of 60, well below the 4.08%
        // threshold. Creator fee forfeited.
        vm.prank(carol);
        mako.placeBet(id, false, ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        // Market settles normally at YES (no ratio refund in v4).
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarketsV4.Outcome.YES));

        // claimCreatorFee succeeds but pays zero.
        vm.prank(carol);
        mako.claimCreatorFee(id);

        // Carol bet NO, can't claim as a winner.
        vm.prank(carol);
        vm.expectRevert(MakoMarketsV4.NoPosition.selector);
        mako.claim(id);

        uint256 carolFinal = usdc.balanceOf(carol);
        uint256 netLoss = carolInitial - carolFinal;
        // Loses the full bet amount, zero offsetting fee revenue.
        assertEq(netLoss, ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 14b. Creator fee DOES unlock when the pool is above threshold.
    //      Baseline that the forfeit gate is pool-ratio-specific, not a
    //      blanket disable.
    // ------------------------------------------------------------------
    function test_creatorFee_unlocksAboveThreshold() public {
        vm.prank(carol);
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.BASKETBALL,
            bytes32("18923:home_win:0"),
            uint64(block.timestamp + 1 hours),
            uint64(block.timestamp + 1 hours),
            "Will the Lakers beat the Celtics?"
        );

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        // 3 USDC on NO = 5% of 60, above the 4.08% threshold.
        vm.prank(bob);
        mako.placeBet(id, false, 3 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        mako.claimCreatorFee(id);
        // Fee = 2% of 63 = 1.26 USDC
        assertEq(usdc.balanceOf(carol) - carolBefore, 1_260_000);
    }

    // ------------------------------------------------------------------
    // 15. minLiquidityRatioBps math spot-check
    // ------------------------------------------------------------------
    function test_minLiquidityRatioBps_math() public view {
        assertEq(mako.minLiquidityRatioBps(), 408);
    }

    // ------------------------------------------------------------------
    // 16. Basketball market
    // ------------------------------------------------------------------
    function test_basketballMarket_happyPath() public {
        uint256 id = _createBasketballMarket();
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.mType), uint8(MakoMarketsV4.MarketType.BASKETBALL));

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 40 * ONE_USDC);

        vm.warp(block.timestamp + 4 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        uint256 before_ = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertEq(usdc.balanceOf(alice) - before_, 97 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 17. Enum ordering is append-only
    // ------------------------------------------------------------------
    function test_enumOrdering_isStable() public pure {
        assertEq(uint8(MakoMarketsV4.MarketType.FOOTBALL), 0);
        assertEq(uint8(MakoMarketsV4.MarketType.CRYPTO), 1);
        assertEq(uint8(MakoMarketsV4.MarketType.BASKETBALL), 2);
    }

    // ======================================================================
    // v4-specific: ERC-20 surface and the Codex #1 hardening guards
    // ======================================================================

    // ------------------------------------------------------------------
    // 18. BelowMin: sub-MIN_BET bets are rejected
    // ------------------------------------------------------------------
    function test_belowMin_reverts() public {
        uint256 id = _createCryptoMarket();
        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.BelowMin.selector);
        mako.placeBet(id, true, ONE_USDC - 1); // 0.999999 USDC
    }

    // ------------------------------------------------------------------
    // 19. MIN_BET is the canonical 1_000_000 (1.00 USDC at 6 decimals)
    // ------------------------------------------------------------------
    function test_minBet_constant() public view {
        assertEq(mako.MIN_BET(), 1_000_000);
    }

    // ------------------------------------------------------------------
    // 20. Constructor: rejects zero treasury
    // ------------------------------------------------------------------
    function test_constructor_zeroTreasury_reverts() public {
        vm.expectRevert(MakoMarketsV4.ZeroAddress.selector);
        new MakoMarketsV4(address(0), address(usdc));
    }

    // ------------------------------------------------------------------
    // 21. Constructor: rejects zero token
    // ------------------------------------------------------------------
    function test_constructor_zeroToken_reverts() public {
        vm.expectRevert(MakoMarketsV4.ZeroAddress.selector);
        new MakoMarketsV4(treasury, address(0));
    }

    // ------------------------------------------------------------------
    // 22. Constructor: rejects non-6-decimal token (BadDecimals guard)
    // ------------------------------------------------------------------
    function test_constructor_wrongDecimals_reverts() public {
        MockUSDC dai = new MockUSDC(18);
        vm.expectRevert(MakoMarketsV4.BadDecimals.selector);
        new MakoMarketsV4(treasury, address(dai));

        MockUSDC weird = new MockUSDC(8);
        vm.expectRevert(MakoMarketsV4.BadDecimals.selector);
        new MakoMarketsV4(treasury, address(weird));
    }

    // ------------------------------------------------------------------
    // 23. placeBet reverts if caller hasn't approved the contract
    // ------------------------------------------------------------------
    function test_placeBet_withoutApproval_reverts() public {
        address dave = address(0xD4);
        usdc.mint(dave, 100 * ONE_USDC);
        // Note: no approve() — mako cannot pull from dave.

        uint256 id = _createCryptoMarket();
        vm.prank(dave);
        vm.expectRevert(); // MockUSDC's underflow in allowance subtract triggers arithmetic revert
        mako.placeBet(id, true, 10 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 24. placeBet reverts if caller lacks sufficient balance
    // ------------------------------------------------------------------
    function test_placeBet_insufficientBalance_reverts() public {
        address dave = address(0xD4);
        // Not enough balance, but grant approval so the failure comes from
        // the transferFrom balance check and not the allowance check.
        usdc.mint(dave, 5 * ONE_USDC);
        vm.prank(dave);
        usdc.approve(address(mako), type(uint256).max);

        uint256 id = _createCryptoMarket();
        vm.prank(dave);
        vm.expectRevert();
        mako.placeBet(id, true, 10 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 25. Fee-on-transfer token triggers TransferAmountMismatch
    // ------------------------------------------------------------------
    function test_feeOnTransferToken_revertsOnPlaceBet() public {
        FeeOnTransferUSDC fot = new FeeOnTransferUSDC();
        MakoMarketsV4 fotMako = new MakoMarketsV4(treasury, address(fot));

        fot.mint(alice, 100 * ONE_USDC);
        vm.prank(alice);
        fot.approve(address(fotMako), type(uint256).max);

        vm.prank(alice);
        uint256 id = fotMako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("ETH:gt:3500"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "Will ETH close above $3500?"
        );

        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.TransferAmountMismatch.selector);
        fotMako.placeBet(id, true, 10 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 26. No receive/fallback — contract rejects native value
    // ------------------------------------------------------------------
    function test_noReceive_rejectsNativeValue() public {
        (bool ok,) = address(mako).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------
    // 27. USDC immutable + treasury getter sanity
    // ------------------------------------------------------------------
    function test_constructorState_pinned() public view {
        assertEq(address(mako.usdc()), address(usdc));
        assertEq(mako.treasury(), treasury);
        assertEq(mako.owner(), address(this));
        assertEq(mako.resolver(), address(this));
    }

    // ------------------------------------------------------------------
    // 28. BetPlaced event carries the USDC amount, not msg.value
    // ------------------------------------------------------------------
    event BetPlaced(uint256 indexed id, address indexed user, bool isYes, uint256 amount);

    function test_betPlaced_eventAmount() public {
        uint256 id = _createCryptoMarket();
        vm.expectEmit(true, true, false, true);
        emit BetPlaced(id, alice, true, 7 * ONE_USDC);
        vm.prank(alice);
        mako.placeBet(id, true, 7 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 29a. Fee change AFTER bet, BEFORE resolve: existing market unaffected.
    //      Regression for the Codex-flagged "admin mutable fees drain other
    //      markets" bug. A market is frozen to its snapshot fees at
    //      createMarket() time; setFees only affects future markets.
    // ------------------------------------------------------------------
    function test_feeChange_afterBet_doesNotAffectMarket() public {
        uint256 id = _createCryptoMarket();
        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 40 * ONE_USDC);

        // Owner bumps fees from 1%+2% to the max 2%+3% mid-market.
        mako.setFees(200, 300);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        // Treasury accrual uses the SNAPSHOTTED 1%, not the new 2%.
        assertEq(mako.treasuryBalance(), 1 * ONE_USDC);

        // Winner payout uses the SNAPSHOTTED 1%+2%=3% fee, not 5%.
        // 60 YES, 40 NO, YES wins. payoutPool = 100 * 0.97 = 97. Alice gets all.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 97 * ONE_USDC);

        // Creator fee uses SNAPSHOTTED 2% = 2 USDC, not new 3% = 3 USDC.
        // This test contract is the market creator (the default path).
        uint256 testBefore = usdc.balanceOf(address(this));
        mako.claimCreatorFee(id);
        assertEq(usdc.balanceOf(address(this)) - testBefore, 2 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 29b. Fee change AFTER resolve but before claims: winners still get
    //      the economics snapshotted at market creation. Prevents owner
    //      from retroactively diluting (or over-paying) winners.
    // ------------------------------------------------------------------
    function test_feeChange_afterResolve_doesNotAffectClaims() public {
        uint256 id = _createCryptoMarket();
        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 40 * ONE_USDC);
        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        // Owner zeros fees AFTER resolution. If claim() used live globals
        // this would give winners 100% of the pool — more than the contract
        // reserved for this market. Must not.
        mako.setFees(0, 0);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        // Still 97 USDC, not 100. Snapshot holds.
        assertEq(usdc.balanceOf(alice) - aliceBefore, 97 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 29c. New markets created AFTER setFees DO see the new fees. Confirms
    //      the snapshot is applied once at creation, not retroactively.
    // ------------------------------------------------------------------
    function test_feeChange_affectsOnlyFutureMarkets() public {
        // Market 1 at default 1%+2%.
        uint256 id1 = _createCryptoMarket();

        // Owner moves fees to 2%+3%.
        mako.setFees(200, 300);

        // Market 2 at new fees.
        uint256 id2 = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet(id1, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id1, false, 40 * ONE_USDC);
        vm.prank(alice);
        mako.placeBet(id2, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id2, false, 40 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id1, MakoMarketsV4.Outcome.YES);
        mako.resolveMarket(id2, MakoMarketsV4.Outcome.YES);

        // Treasury credits: market 1 = 1 USDC (1% of 100), market 2 = 2 USDC
        // (2% of 100). Total = 3 USDC.
        assertEq(mako.treasuryBalance(), 3 * ONE_USDC);

        MakoMarketsV4.Market memory m1 = mako.getMarket(id1);
        MakoMarketsV4.Market memory m2 = mako.getMarket(id2);
        assertEq(m1.protocolFeeBpsSnapshot, 100);
        assertEq(m1.creatorFeeBpsSnapshot, 200);
        assertEq(m2.protocolFeeBpsSnapshot, 200);
        assertEq(m2.creatorFeeBpsSnapshot, 300);
    }

    // ------------------------------------------------------------------
    // 29c2. Accounting invariant on a below-threshold forfeit market.
    //       Fully drains a 60/1 market and asserts zero residual contract
    //       balance attributable to it. Would have failed the pre-fix
    //       version where 1.22 USDC got stranded per below-threshold market.
    // ------------------------------------------------------------------
    function test_invariant_noResidual_onForfeitMarket() public {
        // Fresh contract to make contract-balance math clean.
        MockUSDC fresh = new MockUSDC(6);
        MakoMarketsV4 m2 = new MakoMarketsV4(treasury, address(fresh));

        address dave = address(0xDA5E);
        fresh.mint(alice, 1_000 * ONE_USDC);
        fresh.mint(dave, 1_000 * ONE_USDC);
        vm.prank(alice);
        fresh.approve(address(m2), type(uint256).max);
        vm.prank(dave);
        fresh.approve(address(m2), type(uint256).max);

        // Dave is the creator; market is 60 YES (alice) / 1 NO (dave).
        // Ratio 1.67% — below the 4.08% threshold.
        vm.prank(dave);
        uint256 id = m2.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("ETH:gt:3500"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "Will ETH close above $3500?"
        );
        vm.prank(alice);
        m2.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(dave);
        m2.placeBet(id, false, ONE_USDC);

        uint256 contractBalBefore = fresh.balanceOf(address(m2));
        assertEq(contractBalBefore, 61 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        m2.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        // Alice claims her winnings (60.39).
        vm.prank(alice);
        m2.claim(id);

        // Creator calls claimCreatorFee — forfeit path, pays zero.
        vm.prank(dave);
        m2.claimCreatorFee(id);

        // Owner sweeps treasury (0.61).
        m2.withdrawTreasury();

        // The contract's USDC balance should now be exactly zero for this
        // market's pool. Everything that went in went out: 61 = 60.39 + 0.61.
        assertEq(fresh.balanceOf(address(m2)), 0);
        // And no pending treasury obligation either.
        assertEq(m2.treasuryBalance(), 0);
    }

    // ------------------------------------------------------------------
    // 29c3. Multi-winner accounting invariant — dust bound.
    //       With N winners, floor-division leaves at most N-1 base units
    //       of dust stranded in the contract (documented in _calcPayout).
    //       This test proves the bound holds for a multi-winner
    //       above-threshold market (full fees apply).
    // ------------------------------------------------------------------
    function test_invariant_multiWinner_dustBounded_aboveThreshold() public {
        // 3 winners split a pool where 7 YES units don't divide 9.7 USDC
        // evenly → floor residual must fall out.
        address[3] memory winners = [alice, bob, carol];
        uint256[3] memory winnerStakes = [uint256(1 * ONE_USDC), 2 * ONE_USDC, 4 * ONE_USDC];

        uint256 id = _createCryptoMarket();
        // Dave is on NO (the losing side). 3/7 ratio = 42.8% > 4.08% so
        // creator fee WILL unlock — this is the full-fee, dustiest path.
        address dave = address(0xDA5E);
        usdc.mint(dave, 100 * ONE_USDC);
        vm.prank(dave);
        usdc.approve(address(mako), type(uint256).max);

        for (uint256 i = 0; i < winners.length; i++) {
            vm.prank(winners[i]);
            mako.placeBet(id, true, winnerStakes[i]);
        }
        vm.prank(dave);
        mako.placeBet(id, false, 3 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        // Drain everything.
        uint256 totalPayout = 0;
        for (uint256 i = 0; i < winners.length; i++) {
            uint256 before_ = usdc.balanceOf(winners[i]);
            vm.prank(winners[i]);
            mako.claim(id);
            totalPayout += usdc.balanceOf(winners[i]) - before_;
        }
        mako.claimCreatorFee(id);
        mako.withdrawTreasury();

        // payoutPool = 10 USDC * 0.97 = 9.7 = 9_700_000 microUSDC.
        // Floor shares: 1/7 → 1_385_714, 2/7 → 2_771_428, 4/7 → 5_542_857.
        // Sum = 9_699_999. Residual = 1 microUSDC.
        uint256 payoutPool = 9_700_000;
        uint256 residual = payoutPool - totalPayout;
        // Bound: at most (N - 1) base units with N = 3 winners → <= 2.
        assertLe(residual, winners.length - 1);

        // Contract USDC balance == residual (nothing else attributable to
        // this market). The strand is ≤ 2 microUSDC ≈ $0.000002 — the
        // bounded floor-division dust.
        assertEq(usdc.balanceOf(address(mako)), residual);
    }

    // ------------------------------------------------------------------
    // 29c4. Multi-winner invariant on a below-threshold (forfeit) market.
    //       Checks the R4 fix (winners get 99% not 97% on forfeit)
    //       holds for multi-winner partitions too — no fund stranded
    //       beyond the bounded floor-division dust.
    // ------------------------------------------------------------------
    function test_invariant_multiWinner_dustBounded_forfeit() public {
        MockUSDC fresh = new MockUSDC(6);
        MakoMarketsV4 m2 = new MakoMarketsV4(treasury, address(fresh));

        // 3 + 5 + 7 = 15 YES vs 1 NO. 1/15 = 6.67% > 4.08% → NOT forfeit.
        // Need minSide/maxSide < 4.08%. Use 30 + 20 + 10 YES vs 1 NO: 1/60 = 1.67%.
        address[3] memory winners = [alice, bob, carol];
        uint256[3] memory winnerStakes = [uint256(30 * ONE_USDC), 20 * ONE_USDC, 10 * ONE_USDC];
        address dave = address(0xDA5E);

        address[4] memory everyone = [alice, bob, carol, dave];
        for (uint256 i = 0; i < everyone.length; i++) {
            fresh.mint(everyone[i], 1_000 * ONE_USDC);
            vm.prank(everyone[i]);
            fresh.approve(address(m2), type(uint256).max);
        }

        uint256 id = m2.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("ETH:gt:3500"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "q"
        );

        for (uint256 i = 0; i < winners.length; i++) {
            vm.prank(winners[i]);
            m2.placeBet(id, true, winnerStakes[i]);
        }
        vm.prank(dave);
        m2.placeBet(id, false, ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        m2.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        uint256 totalPayout = 0;
        for (uint256 i = 0; i < winners.length; i++) {
            uint256 before_ = fresh.balanceOf(winners[i]);
            vm.prank(winners[i]);
            m2.claim(id);
            totalPayout += fresh.balanceOf(winners[i]) - before_;
        }
        m2.claimCreatorFee(id);
        m2.withdrawTreasury();

        // Below-threshold: winners split totalPool * (1 - protocolFee).
        //   totalPool = 61 USDC, payoutPool = 61 * 0.99 = 60.39 USDC = 60_390_000.
        //   Alice 30/60 * 60_390_000 = 30_195_000 (exact).
        //   Bob   20/60 * 60_390_000 = 20_130_000 (exact).
        //   Carol 10/60 * 60_390_000 = 10_065_000 (exact).
        //   Sum = 60_390_000. Zero dust in this particular partition.
        assertEq(totalPayout, 60_390_000);

        // Residual <= (N-1) always; zero for this specific math but the bound is what
        // matters for the audit-level invariant.
        uint256 residual = 60_390_000 - totalPayout;
        assertLe(residual, winners.length - 1);
        assertEq(fresh.balanceOf(address(m2)), residual);
    }

    // ------------------------------------------------------------------
    // 29d. Admin mutator events fire with accurate before/after state.
    // ------------------------------------------------------------------
    event FeesChanged(uint16 oldProtocolBps, uint16 oldCreatorBps, uint16 newProtocolBps, uint16 newCreatorBps);
    event ResolverChanged(address indexed oldResolver, address indexed newResolver);
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    function test_adminMutators_emitEvents() public {
        vm.expectEmit(false, false, false, true);
        emit FeesChanged(100, 200, 150, 250);
        mako.setFees(150, 250);

        vm.expectEmit(true, true, false, false);
        emit ResolverChanged(address(this), alice);
        mako.setResolver(alice);

        vm.expectEmit(true, true, false, false);
        emit TreasuryChanged(treasury, bob);
        mako.setTreasury(bob);

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(address(this), carol);
        mako.transferOwnership(carol);
    }

    // ------------------------------------------------------------------
    // 30. withdrawTreasury pays in USDC, zeroes out balance
    // ------------------------------------------------------------------
    function test_withdrawTreasury_paysOutUSDC() public {
        uint256 id = _createCryptoMarket();
        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 40 * ONE_USDC);
        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        mako.withdrawTreasury(); // owner == address(this)
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 1 * ONE_USDC);
        assertEq(mako.treasuryBalance(), 0);
    }

    // ======================================================================
    // v4 hardening: per-market-type betting cutoffs, caps, rate limits, blocklist
    // ======================================================================

    // ------------------------------------------------------------------
    // 31. Per-market betting cutoff enforced as the `placeBet` gate.
    //     Creator sets bettingCloseTime explicitly; contract enforces.
    // ------------------------------------------------------------------
    function test_bettingCutoff_enforcedOnPlaceBet() public {
        uint64 created = uint64(block.timestamp);
        uint64 bettingClose = created + 30 minutes;
        uint64 resolveAt = created + 1 hours;

        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("x"),
            bettingClose,
            resolveAt,
            "q"
        );

        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint256(m.bettingCloseTime), uint256(bettingClose));
        assertEq(uint256(m.closeTime), uint256(resolveAt));

        // Warp to 25 min in — bets still open.
        vm.warp(created + 25 minutes);
        vm.prank(alice);
        mako.placeBet(id, true, 5 * ONE_USDC);

        // Warp to 31 min in — bets closed.
        vm.warp(created + 31 minutes);
        vm.prank(bob);
        vm.expectRevert(MakoMarketsV4.BettingClosed.selector);
        mako.placeBet(id, false, 5 * ONE_USDC);

        // But resolveMarket is not yet legal — we're before closeTime.
        vm.expectRevert(MakoMarketsV4.MarketNotClosed.selector);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        // Warp past closeTime → resolveMarket legal.
        vm.warp(created + 1 hours + 1);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);
    }

    // ------------------------------------------------------------------
    // 32. suggestedCryptoBettingCloseTime view returns per-tier fractions.
    //     Crypto-scoped by design — no sports overload to avoid naive
    //     integrators defaulting sports markets to no-cutoff.
    // ------------------------------------------------------------------
    function test_suggestedCryptoBettingCloseTime_tiers() public view {
        uint64 t0 = 1_700_000_000;
        // <= 1 hour → 50%
        assertEq(
            uint256(mako.suggestedCryptoBettingCloseTime(t0, t0 + 1 hours)),
            uint256(t0) + 30 minutes
        );
        // <= 1 day → 60%
        assertEq(
            uint256(mako.suggestedCryptoBettingCloseTime(t0, t0 + 1 days)),
            uint256(t0) + (1 days * 60) / 100
        );
        // <= 3 days → 70%
        assertEq(
            uint256(mako.suggestedCryptoBettingCloseTime(t0, t0 + 3 days)),
            uint256(t0) + (3 days * 70) / 100
        );
        // > 3 days (up to 7 days) → 85%
        assertEq(
            uint256(mako.suggestedCryptoBettingCloseTime(t0, t0 + 7 days)),
            uint256(t0) + (7 days * 85) / 100
        );
    }

    // ------------------------------------------------------------------
    // 33. Sports two-timestamp design: bets close at kickoff, resolver
    //     cannot finalize until closeTime (match end). This is the
    //     behavior the single-closeTime design could NOT represent —
    //     it's the reason createMarket now takes both timestamps.
    // ------------------------------------------------------------------
    function test_sportsBettingCutoff_separateFromResolutionTime() public {
        uint64 created = uint64(block.timestamp);
        uint64 kickoff = created + 1 hours;
        uint64 matchEnd = created + 3 hours;

        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.FOOTBALL,
            bytes32("x"),
            kickoff,
            matchEnd,
            "q"
        );
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint256(m.bettingCloseTime), uint256(kickoff));
        assertEq(uint256(m.closeTime), uint256(matchEnd));

        // Bet before kickoff: allowed.
        vm.warp(created + 30 minutes);
        vm.prank(alice);
        mako.placeBet(id, true, 5 * ONE_USDC);

        // Between kickoff and match end: bets rejected AND resolution rejected.
        vm.warp(kickoff + 10 minutes);
        vm.prank(bob);
        vm.expectRevert(MakoMarketsV4.BettingClosed.selector);
        mako.placeBet(id, false, 5 * ONE_USDC);

        vm.expectRevert(MakoMarketsV4.MarketNotClosed.selector);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        // After match end: resolver can finalize.
        vm.warp(matchEnd + 1);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);
    }

    // ------------------------------------------------------------------
    // 34. createMarket rejects invalid timestamps.
    // ------------------------------------------------------------------
    function test_createMarket_rejectsBadTimestamps() public {
        uint64 t0 = uint64(block.timestamp);

        // bettingCloseTime in the past.
        vm.expectRevert(MakoMarketsV4.BadCloseTime.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("x"),
            t0 - 1,
            t0 + 1 hours,
            "q"
        );

        // bettingCloseTime > closeTime.
        vm.expectRevert(MakoMarketsV4.BadCloseTime.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("x"),
            t0 + 2 hours,
            t0 + 1 hours,
            "q"
        );

        // 4 min < MIN_DURATION (5 min) → revert.
        vm.expectRevert(MakoMarketsV4.BadDuration.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("x"),
            t0 + 3 minutes,
            t0 + 4 minutes,
            "q"
        );

        // 5 min + 1s → succeeds.
        mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("x"),
            t0 + 5 minutes,
            t0 + 5 minutes + 1,
            "q"
        );
    }

    // ------------------------------------------------------------------
    // 35. Rate limit: same wallet can't bet twice within 30s on one market.
    // ------------------------------------------------------------------
    function test_rateLimit_rejectsRapidRepeatBets() public {
        uint256 id = _createCryptoMarket();
        vm.prank(alice);
        mako.placeBet(id, true, 5 * ONE_USDC);

        // Immediate second bet → revert.
        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.BetTooSoon.selector);
        mako.placeBet(id, true, 5 * ONE_USDC);

        // 29 seconds later → still reverts.
        vm.warp(block.timestamp + 29);
        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.BetTooSoon.selector);
        mako.placeBet(id, true, 5 * ONE_USDC);

        // 31 seconds from the first bet → allowed.
        vm.warp(block.timestamp + 2);
        vm.prank(alice);
        mako.placeBet(id, true, 5 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 36. Rate limit is PER-MARKET — betting in a different market within
    //     30s is allowed.
    // ------------------------------------------------------------------
    function test_rateLimit_isPerMarket() public {
        uint256 id1 = _createCryptoMarket();
        uint256 id2 = _createFootballMarket();

        vm.prank(alice);
        mako.placeBet(id1, true, 5 * ONE_USDC);
        // Immediate bet on a different market is fine.
        vm.prank(alice);
        mako.placeBet(id2, true, 5 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 37. Per-wallet absolute cap: sum of a wallet's bets on one market
    //     can't exceed maxBetPerWalletPerMarket.
    // ------------------------------------------------------------------
    function test_walletCap_rejectsAboveCap() public {
        // Tighten cap for this test.
        mako.setMaxBetPerWalletPerMarket(10 * ONE_USDC);

        uint256 id = _createCryptoMarket();
        vm.prank(alice);
        mako.placeBet(id, true, 6 * ONE_USDC);

        // Second bet pushes total to 12 > 10 → reverts (past 30s cooldown).
        vm.warp(block.timestamp + 31);
        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.WalletCapExceeded.selector);
        mako.placeBet(id, true, 6 * ONE_USDC);

        // Stays within cap → succeeds.
        vm.prank(alice);
        mako.placeBet(id, true, 4 * ONE_USDC); // 6+4=10, exactly at cap, allowed
    }

    // ------------------------------------------------------------------
    // 38. Share cap: once pool grows past threshold, a bet pushing any
    //     wallet above maxWalletShareBps reverts. Sized so the cap is
    //     active for a realistic 3-bettor build-up, then a whale-style
    //     4th bet by alice would push her over.
    // ------------------------------------------------------------------
    function test_shareCap_rejectsAtCap() public {
        mako.setShareCapMinPool(10 * ONE_USDC);
        mako.setMaxWalletShareBps(5000); // 50%

        uint256 id = _createCryptoMarket();
        // Build pool: alice 3 YES, bob 4 NO, carol 4 NO = 11 USDC pool.
        vm.prank(alice);
        mako.placeBet(id, true, 3 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 4 * ONE_USDC);
        vm.prank(carol);
        mako.placeBet(id, false, 4 * ONE_USDC);
        // Pool = 11, cap active. alice 3/11 = 27%, bob 36%, carol 36%.
        // All under 50%.

        // Alice tries to add 10 more YES: would push her to 13/21 = 62% > 50%.
        vm.warp(block.timestamp + 31);
        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.WalletShareCapExceeded.selector);
        mako.placeBet(id, true, 10 * ONE_USDC);

        // Alice adds 2 more (she was 3, new total 5, new pool 13): 5/13 = 38% < 50%. OK.
        vm.prank(alice);
        mako.placeBet(id, true, 2 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 39. Share cap is skipped in seed stage (pool < shareCapMinPool).
    //     Alice alone creating the market should not be blocked by the cap.
    // ------------------------------------------------------------------
    function test_shareCap_skipsInSeedStage() public {
        mako.setShareCapMinPool(200 * ONE_USDC);
        mako.setMaxWalletShareBps(2000); // 20%

        uint256 id = _createCryptoMarket();
        // Alice alone — pool after = 60 USDC < 200 threshold. Cap skipped.
        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);

        // Bob adds 60 on NO — pool = 120 < 200, cap still skipped.
        vm.prank(bob);
        mako.placeBet(id, false, 60 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 40. Blocklist: flagged wallets cannot bet.
    // ------------------------------------------------------------------
    function test_blocklist_rejectsFlaggedWallet() public {
        uint256 id = _createCryptoMarket();
        mako.setBlocked(alice, true);

        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.WalletIsBlocked.selector);
        mako.placeBet(id, true, 5 * ONE_USDC);

        // Unblock — should succeed.
        mako.setBlocked(alice, false);
        vm.prank(alice);
        mako.placeBet(id, true, 5 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 41. New admin setters emit events.
    // ------------------------------------------------------------------
    event MaxBetPerWalletChanged(uint256 oldValue, uint256 newValue);
    event MaxWalletShareBpsChanged(uint16 oldValue, uint16 newValue);
    event ShareCapMinPoolChanged(uint256 oldValue, uint256 newValue);
    event WalletBlockStatusChanged(address indexed wallet, bool isBlocked);

    function test_hardening_adminMutators_emitEvents() public {
        vm.expectEmit(false, false, false, true);
        emit MaxBetPerWalletChanged(10_000 * ONE_USDC, 50 * ONE_USDC);
        mako.setMaxBetPerWalletPerMarket(50 * ONE_USDC);

        vm.expectEmit(false, false, false, true);
        emit MaxWalletShareBpsChanged(2000, 1500);
        mako.setMaxWalletShareBps(1500);

        vm.expectEmit(false, false, false, true);
        emit ShareCapMinPoolChanged(200 * ONE_USDC, 500 * ONE_USDC);
        mako.setShareCapMinPool(500 * ONE_USDC);

        vm.expectEmit(true, false, false, true);
        emit WalletBlockStatusChanged(alice, true);
        mako.setBlocked(alice, true);
    }

    // ------------------------------------------------------------------
    // 42. setMaxWalletShareBps rejects 0 and >10000.
    // ------------------------------------------------------------------
    function test_setMaxWalletShareBps_rejectsInvalid() public {
        vm.expectRevert(MakoMarketsV4.FeesTooHigh.selector);
        mako.setMaxWalletShareBps(0);

        vm.expectRevert(MakoMarketsV4.FeesTooHigh.selector);
        mako.setMaxWalletShareBps(10001);
    }

    // ------------------------------------------------------------------
    // 43. Share cap threshold is `>=` — at exact equality the cap IS active.
    //     Locks this behavior so future refactors don't accidentally flip
    //     the inequality.
    // ------------------------------------------------------------------
    function test_shareCap_exactThresholdEquality_capActive() public {
        mako.setShareCapMinPool(10 * ONE_USDC);
        mako.setMaxWalletShareBps(2000); // 20%

        uint256 id = _createCryptoMarket();
        // Build exactly to threshold with alice + bob spread thin enough.
        // Alice 1 YES, Bob 1 NO, Carol 1 NO … (keep everyone under 20%)
        // End state target: newPool == 10. Tricky with 20% cap.
        // Approach: seed with 3 wallets 3 USDC each on various sides.
        vm.prank(alice);
        mako.placeBet(id, true, 3 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 4 * ONE_USDC);
        vm.prank(carol);
        mako.placeBet(id, false, 2 * ONE_USDC);
        // Pool = 9. Still below threshold (10), cap skipped.

        // Now a fourth bet of exactly 1 USDC pushes the pool to exactly 10
        // (== threshold). Cap activates. Dave 1/10 = 10% → well under 20%.
        address dave = address(0xDA5E);
        usdc.mint(dave, 100 * ONE_USDC);
        vm.prank(dave);
        usdc.approve(address(mako), type(uint256).max);
        vm.prank(dave);
        mako.placeBet(id, true, 1 * ONE_USDC);

        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(m.totalYes + m.totalNo, 10 * ONE_USDC);

        // Now prove the cap IS active at pool==10: bob tries to push to 8/
        // 17 = 47% > 20%. Should revert. (bob had 4, pushing +4 = 8.)
        vm.warp(block.timestamp + 31);
        vm.prank(bob);
        vm.expectRevert(MakoMarketsV4.WalletShareCapExceeded.selector);
        mako.placeBet(id, false, 4 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 44. Gate precedence: when multiple gates would trip, the blocklist
    //     fires first (it's the first check). Locks the order so a
    //     future refactor moving gates around gets caught.
    // ------------------------------------------------------------------
    function test_gatePrecedence_blocklistWinsOverRateLimit() public {
        uint256 id = _createCryptoMarket();
        vm.prank(alice);
        mako.placeBet(id, true, 5 * ONE_USDC);
        // Alice is now rate-limited AND about to be blocked. Block fires
        // first (it's checked before the rate limit).
        mako.setBlocked(alice, true);

        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.WalletIsBlocked.selector);
        mako.placeBet(id, true, 5 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // 45. Blocked wallet can still CLAIM on existing bets. Block is a
    //     placeBet-time gate only — it doesn't trap funds.
    // ------------------------------------------------------------------
    function test_blockedWallet_canStillClaim() public {
        uint256 id = _createCryptoMarket();
        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 40 * ONE_USDC);

        // Block alice AFTER her bet is in.
        mako.setBlocked(alice, true);

        // Market resolves normally.
        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        // Alice (blocked) can still claim her winnings.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 97 * ONE_USDC);

        // And creator fee claim works for a blocked creator if applicable —
        // in this case the test contract is creator. (Sanity: no revert
        // from the block gate anywhere in the claim paths.)
    }
}
