// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, Vm} from "forge-std/Test.sol";
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

        // The test contract itself is the creator for every helper-built
        // market and must pay the bundled creator seed (1 USDC). Fund and
        // approve so helpers don't have to.
        usdc.mint(address(this), 10_000 * ONE_USDC);
        usdc.approve(address(mako), type(uint256).max);
    }

    function _createCryptoMarket() internal returns (uint256 id) {
        // Crypto 1-hour market: betting closes at 30 min (50% tier), resolves at 1h.
        // Bundled seed: 1 USDC on YES (creator is the test contract).
        id = mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("ETH:gt:3500"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "Will ETH close above $3500?",
            ONE_USDC,
            true
        );
    }

    function _createFootballMarket() internal returns (uint256 id) {
        // Football: kickoff at 1h, match ends ~2h30m, resolves then.
        // Bundled seed: 1 USDC on YES.
        uint64 kickoff = uint64(block.timestamp + 1 hours);
        uint64 matchEnd = uint64(block.timestamp + 2 hours);
        id = mako.createMarket(
            MakoMarketsV4.MarketType.FOOTBALL,
            bytes32("514237:home_win:0"),
            kickoff,
            matchEnd,
            "Will Arsenal beat Chelsea?",
            ONE_USDC,
            true
        );
    }

    function _createBasketballMarket() internal returns (uint256 id) {
        // Basketball: tipoff at 1h, game ends ~3h, resolves then.
        // Bundled seed: 1 USDC on YES.
        uint64 tipoff = uint64(block.timestamp + 1 hours);
        uint64 gameEnd = uint64(block.timestamp + 3 hours);
        id = mako.createMarket(
            MakoMarketsV4.MarketType.BASKETBALL,
            bytes32("18923:home_win:0"),
            tipoff,
            gameEnd,
            "Will the Lakers beat the Celtics?",
            ONE_USDC,
            true
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

        // Pool = 1 (creator seed YES, from test contract via helper) + 60 (alice YES) + 40 (bob NO) = 101.
        // payoutPool = 101 * 0.97 = 97.97 USDC. Alice has 60/61 of YES side.
        // Alice payout = floor(60 * 97_970_000 / 61) = 96_363_934.
        // Test contract holds the other 1.6 USDC as creator seed share (not claimed here).
        assertEq(usdc.balanceOf(alice) - before_, 96_363_934);
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

        // Pool with creator seed: 1 (helper seed YES) + 60 (alice YES) + 40 (bob NO) = 101.
        // previewPayout simulates a +10 YES bet entering:
        //   newYes = 1 + 60 + 10 = 71, newNo = 40, total = 111
        //   fees 3% → payoutPool = 111 * 0.97 = 107.67
        //   return = floor(10_000_000 * 107_670_000 / 71_000_000) = 15_164_788
        uint256 preview = mako.previewPayout(id, true, 10 * ONE_USDC);
        assertApproxEqAbs(preview, 15_164_788, 1);

        // Live multiplier for YES side pre-new-bet = pool * 0.97 / yesTotal
        //   = 101_000_000 * 9700 / 10000 / 61_000_000 * 1e18 (Solidity floor math)
        //   = 97_970_000 * 1e18 / 61_000_000 ≈ 1.6060655737...
        uint256 mul = mako.multiplier(id, true);
        assertApproxEqAbs(mul, 1.606065573770491803 ether, 1e12);
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
            "Will the Lakers beat the Celtics?",
            ONE_USDC,
            true
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
        // Pool = 1 (carol's creator seed) + 60 + 40 = 101 USDC. 2% = 2.02 USDC.
        assertEq(usdc.balanceOf(carol) - before_, 2_020_000);

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
        // Pool = 1 (creator seed) + 60 + 40 = 101 USDC. Protocol fee = 1% = 1.01 USDC.
        assertEq(mako.treasuryBalance(), 1_010_000);
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
        // Pool = 1 (creator seed YES) + 30 (alice YES) + 70 (bob NO) = 101.
        // payoutPool = 97.97. NO wins. Bob is sole NO bettor → gets all 97.97 = 97_970_000.
        assertEq(usdc.balanceOf(bob) - before_, 97_970_000);
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
            "Will ETH close above $3500?",
            ONE_USDC,
            true
        );

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);

        // Skip past carol's seed cooldown (her create just set lastBetTime).
        vm.warp(block.timestamp + 31);

        // Carol (creator) plants 1 USDC on NO hoping to unlock the fee.
        // Pool composition: 1 carol_seed_YES + 60 alice_YES + 1 carol_NO = 62.
        // Carol NO / Alice YES ratio = 1/61 = 1.64% — below 4.08% threshold.
        vm.prank(carol);
        mako.placeBet(id, false, 1 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarketsV4.Outcome.YES));

        // Below threshold → creator fee forfeited from payout math.
        // Winners (carol_seed + alice) split totalPool * (1 - protocolFee) = 62 * 0.99 = 61.38 USDC.
        // Alice has 60 of 61 YES → 60 * 61_380_000 / 61 = 60_373_770 (floor).
        // Carol's seed share = 1 * 61_380_000 / 61 = 1_006_229. Total drains within 1 base unit.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertApproxEqAbs(usdc.balanceOf(alice) - aliceBefore, 60_373_770, 1);

        // Carol claims — she has a YES position from the creator seed (1 USDC).
        // Pool 62, payoutPool 61.38, carol has 1/61 of YES → ~1_006_229 base units.
        // Her 1 USDC NO bet is lost (NO didn't win).
        vm.prank(carol);
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

        // Pool: 1 (seed YES) + 60 alice_YES + 3 bob_NO = 64.
        // minSide/maxSide = 3/61 = 4.918% > 4.08% threshold → creator fee unlocks.
        // payoutPool = 64 * 0.97 = 62.08 USDC. Alice has 60/61 of YES side.
        // Payout = floor(60 * 62_080_000 / 61) = 61_062_295.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertApproxEqAbs(usdc.balanceOf(alice) - aliceBefore, 61_062_295, 1);
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
            "Will ETH close above $3500?",
            ONE_USDC,
            true
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

        // Pool: 1 (carol_seed_YES) + 60 alice_YES + 1 bob_NO = 62.
        // minSide/maxSide = 1/61 = 1.64% < 4.08% → creator fee forfeited.
        // payoutPool with fee forfeit = 62 * 0.99 = 61.38 USDC.
        // Alice has 60/61 of YES → floor(60 * 61_380_000 / 61) = 60_373_770.
        // Carol's seed share = 1_006_229; combined drains pool within 1 base unit dust.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertApproxEqAbs(usdc.balanceOf(alice) - aliceBefore, 60_373_770, 1);

        // Bob bet on NO, loses, cannot claim anything.
        vm.prank(bob);
        vm.expectRevert(MakoMarketsV4.NoPosition.selector);
        mako.claim(id);

        // Creator fee forfeited — the claim call succeeds but transfers zero.
        // Carol can also claim her creator-seed YES share (it's a real bet).
        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        mako.claimCreatorFee(id);
        assertEq(usdc.balanceOf(carol), carolBefore);

        // Pool 62 USDC × 1% protocol fee = 620_000.
        assertEq(mako.treasuryBalance(), 620_000);
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
        // Capture BEFORE createMarket so the seed bet outlay is included
        // in the carol-side accounting (the seed is a real USDC commitment,
        // not free market creation).
        uint256 carolInitial = usdc.balanceOf(carol);
        vm.prank(carol);
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.BASKETBALL,
            bytes32("18923:home_win:0"),
            uint64(block.timestamp + 1 hours),
            uint64(block.timestamp + 1 hours),
            "Will the Lakers beat the Celtics?",
            ONE_USDC,
            true
        );

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);

        // Skip past carol's seed cooldown (her create just set lastBetTime).
        vm.warp(block.timestamp + 31);

        // Bet 1 USDC on NO — 1.64% of YES side (60+1 seed), below 4.08% threshold.
        // Creator fee forfeited.
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

        // Carol claims her creator-seed YES share. Pool 62, payoutPool 61.38,
        // carol has 1/61 of YES → floor(1 * 61_380_000 / 61) = 1_006_229.
        vm.prank(carol);
        mako.claim(id);

        uint256 carolFinal = usdc.balanceOf(carol);
        // Carol total outlay: 1 USDC (seed at create) + 1 USDC (NO bet) = 2.
        // Recovery: 1_006_229 (seed YES share) + 0 (creator fee forfeit).
        // Net loss = 2_000_000 - 1_006_229 = 993_771. Attack is still
        // unprofitable — the bundled-seed actually shifts a sliver of the
        // forfeited creator fee back to creator-as-bettor, but the NO bet
        // outlay still dominates.
        uint256 netLoss = carolInitial - carolFinal;
        assertApproxEqAbs(netLoss, 2 * ONE_USDC - 1_006_229, 3);
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
            "Will the Lakers beat the Celtics?",
            ONE_USDC,
            true
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
        // Pool = 1 (carol's creator seed YES) + 60 + 3 = 64 USDC. Fee = 2% of 64 = 1.28 USDC.
        assertEq(usdc.balanceOf(carol) - carolBefore, 1_280_000);
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
        // Pool 101 (1 seed + 60 + 40); payoutPool 97.97. Alice has 60/61 of YES.
        assertEq(usdc.balanceOf(alice) - before_, 96_363_934);
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
        uint256 belowMin = mako.MIN_BET() - 1;
        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.BelowMin.selector);
        mako.placeBet(id, true, belowMin);
    }

    // ------------------------------------------------------------------
    // 19. MIN_BET is the canonical 100_000 (0.10 USDC at 6 decimals)
    // ------------------------------------------------------------------
    function test_minBet_constant() public view {
        assertEq(mako.MIN_BET(), 100_000);
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
    //
    //     Originally tested at placeBet, but with bundled creator-seed
    //     the first safeTransferFrom now happens inside createMarket
    //     itself — so the fot revert surfaces there.
    // ------------------------------------------------------------------
    function test_feeOnTransferToken_revertsOnCreateMarket() public {
        FeeOnTransferUSDC fot = new FeeOnTransferUSDC();
        MakoMarketsV4 fotMako = new MakoMarketsV4(treasury, address(fot));

        fot.mint(alice, 100 * ONE_USDC);
        vm.prank(alice);
        fot.approve(address(fotMako), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.TransferAmountMismatch.selector);
        fotMako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("ETH:gt:3500"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "Will ETH close above $3500?",
            ONE_USDC,
            true
        );
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

        // Treasury accrual uses the SNAPSHOTTED 1%, not the new 2%. Pool
        // is 101 (creator seed 1 + alice 60 + bob 40); protocol fee = 1.01 USDC.
        assertEq(mako.treasuryBalance(), 1_010_000);

        // Winner payout uses the SNAPSHOTTED 1%+2%=3% fee, not 5%.
        // Pool = 101, payoutPool = 97.97. Alice has 60/61 of YES side.
        // Alice payout = 60 * 97_970_000 / 61 = 96_363_934 (floor).
        // Test contract holds the remaining 1.6 USDC YES share (creator seed).
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 96_363_934);

        // Creator fee uses SNAPSHOTTED 2% of pool, not new 3%.
        // Pool 101 USDC × 2% = 2.02 USDC = 2_020_000.
        uint256 testBefore = usdc.balanceOf(address(this));
        mako.claimCreatorFee(id);
        assertEq(usdc.balanceOf(address(this)) - testBefore, 2_020_000);
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
        // Pool 101 (1 seed + 60 + 40), payoutPool 97.97 from snapshot (not 100 — snapshot holds).
        // Alice has 60/61 of YES → 96_363_934.
        assertEq(usdc.balanceOf(alice) - aliceBefore, 96_363_934);
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

        // Each market pool = 1 (helper seed) + 60 + 40 = 101 USDC.
        // Treasury credits: market 1 = 1% of 101 = 1.01 USDC, market 2 = 2% of 101 = 2.02 USDC.
        // Total = 3.03 USDC = 3_030_000.
        assertEq(mako.treasuryBalance(), 3_030_000);

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

        // Dave is the creator. Bundled seed is 1 USDC on YES (not NO,
        // so it doesn't perturb the 1 NO that Dave places later — the
        // 60/1 ratio under test would be wrong if Dave's seed landed
        // on NO too). After seed: 1 dave_YES_seed + (later 60 alice_YES)
        // + (later 1 dave_NO) = 61 YES / 1 NO. Ratio 1/62 = 1.61%, still
        // below the 4.08% forfeit threshold under test.
        vm.prank(dave);
        uint256 id = m2.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("ETH:gt:3500"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "Will ETH close above $3500?",
            ONE_USDC,
            true
        );

        // Skip past the 30s rate-limit cooldown so dave can also place
        // his subsequent NO bet without hitting BetTooSoon.
        vm.warp(block.timestamp + 31);
        vm.prank(alice);
        m2.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(dave);
        m2.placeBet(id, false, ONE_USDC);

        uint256 contractBalBefore = fresh.balanceOf(address(m2));
        // Pool with seed: 1 (dave seed YES) + 60 (alice YES) + 1 (dave NO) = 62.
        assertEq(contractBalBefore, 62 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        m2.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        // Alice claims her 60/61 share of payoutPool 61.38 = 60_373_770.
        vm.prank(alice);
        m2.claim(id);

        // Dave claims his creator-seed YES share (1/61 of 61.38 = 1_006_229).
        vm.prank(dave);
        m2.claim(id);

        // Creator calls claimCreatorFee — forfeit path, pays zero.
        vm.prank(dave);
        m2.claimCreatorFee(id);

        // Owner sweeps treasury (1% of 62 = 0.62 USDC).
        m2.withdrawTreasury();

        // Contract balance: dust ≤ N-1 where N = 2 winners on YES side
        // (alice + dave seed). Floor-division residual ≤ 1 base unit.
        assertLe(fresh.balanceOf(address(m2)), 1);
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

        // Drain everything. With the helper's bundled creator seed (1 USDC
        // YES from test contract), there are 4 winners on the YES side
        // (test contract + alice + bob + carol). Drain all four.
        uint256 totalPayout = 0;
        for (uint256 i = 0; i < winners.length; i++) {
            uint256 before_ = usdc.balanceOf(winners[i]);
            vm.prank(winners[i]);
            mako.claim(id);
            totalPayout += usdc.balanceOf(winners[i]) - before_;
        }
        // Test contract (creator) also claims its 1 USDC seed YES share.
        uint256 selfBefore = usdc.balanceOf(address(this));
        mako.claim(id);
        totalPayout += usdc.balanceOf(address(this)) - selfBefore;

        mako.claimCreatorFee(id);
        mako.withdrawTreasury();

        // Pool = 1 (seed YES) + 1+2+4 (alice/bob/carol YES) + 3 (dave NO) = 11 USDC.
        // payoutPool = 11 * 0.97 = 10.67 USDC = 10_670_000 base units.
        // YES side total = 8 (1+1+2+4). Floor shares sum slightly under 10_670_000.
        uint256 payoutPool = 10_670_000;
        uint256 residual = payoutPool - totalPayout;
        // Bound: at most (N - 1) with N = 4 winners → <= 3.
        assertLe(residual, 3);

        // Contract USDC balance == residual after all settled.
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

        // Test contract is the creator and pays the bundled seed.
        fresh.mint(address(this), 10 * ONE_USDC);
        fresh.approve(address(m2), type(uint256).max);

        uint256 id = m2.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("ETH:gt:3500"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "q",
            ONE_USDC,
            true
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
        // Test contract is also a winner via its 1 USDC YES seed.
        uint256 selfBefore = fresh.balanceOf(address(this));
        m2.claim(id);
        totalPayout += fresh.balanceOf(address(this)) - selfBefore;

        m2.claimCreatorFee(id);
        m2.withdrawTreasury();

        // Below-threshold forfeit: winners split totalPool * (1 - protocolFee).
        //   Pool = 1 (seed YES) + 30+20+10 (winners YES) + 1 (dave NO) = 62 USDC.
        //   payoutPool = 62 * 0.99 = 61.38 USDC = 61_380_000.
        //   YES side total = 61. Floor shares per winner = stake_i * 61_380_000 / 61.
        //     Seed (test contract) 1 USDC → 1_006_229
        //     Alice 30 USDC → 30_186_885
        //     Bob   20 USDC → 20_124_590
        //     Carol 10 USDC → 10_062_295
        //   Sum = 61_379_999. Residual 1 base unit dust.
        assertApproxEqAbs(totalPayout, 61_380_000, 3);

        // Residual <= N-1 base units where N = 4 winners on YES side
        // (test contract seed + alice + bob + carol). payoutPool = 61_380_000.
        uint256 residual = 61_380_000 - totalPayout;
        assertLe(residual, 3);
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
        // Pool 101, protocol fee 1% = 1.01 USDC.
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 1_010_000);
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
            MakoMarketsV4.MarketType.CRYPTO, bytes32("x"), bettingClose, resolveAt, "q", ONE_USDC, true
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
        assertEq(uint256(mako.suggestedCryptoBettingCloseTime(t0, t0 + 1 hours)), uint256(t0) + 30 minutes);
        // <= 1 day → 60%
        assertEq(uint256(mako.suggestedCryptoBettingCloseTime(t0, t0 + 1 days)), uint256(t0) + (1 days * 60) / 100);
        // <= 3 days → 70%
        assertEq(uint256(mako.suggestedCryptoBettingCloseTime(t0, t0 + 3 days)), uint256(t0) + (3 days * 70) / 100);
        // > 3 days (up to 7 days) → 85%
        assertEq(uint256(mako.suggestedCryptoBettingCloseTime(t0, t0 + 7 days)), uint256(t0) + (7 days * 85) / 100);
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

        uint256 id =
            mako.createMarket(MakoMarketsV4.MarketType.FOOTBALL, bytes32("x"), kickoff, matchEnd, "q", ONE_USDC, true);
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
        mako.createMarket(MakoMarketsV4.MarketType.CRYPTO, bytes32("x"), t0 - 1, t0 + 1 hours, "q", ONE_USDC, true);

        // bettingCloseTime > closeTime.
        vm.expectRevert(MakoMarketsV4.BadCloseTime.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO, bytes32("x"), t0 + 2 hours, t0 + 1 hours, "q", ONE_USDC, true
        );

        // 4 min < MIN_DURATION (5 min) → revert.
        vm.expectRevert(MakoMarketsV4.BadDuration.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO, bytes32("x"), t0 + 3 minutes, t0 + 4 minutes, "q", ONE_USDC, true
        );

        // 5 min + 1s → succeeds.
        mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO, bytes32("x"), t0 + 5 minutes, t0 + 5 minutes + 1, "q", ONE_USDC, true
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
        // Pool already starts at 1 (helper creator seed YES). Build to 9
        // with alice/bob/carol so dave's +1 USDC pushes pool to exactly 10
        // (preserving the "exactly at threshold" test intent).
        vm.prank(alice);
        mako.placeBet(id, true, 3 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 4 * ONE_USDC);
        vm.prank(carol);
        mako.placeBet(id, false, 1 * ONE_USDC);
        // Pool = 1 (seed) + 3 + 4 + 1 = 9. Still below threshold (10), cap skipped.

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
        // Pool 101, payoutPool 97.97, alice 60/61 of YES → 96_363_934.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 96_363_934);

        // And creator fee claim works for a blocked creator if applicable —
        // in this case the test contract is creator. (Sanity: no revert
        // from the block gate anywhere in the claim paths.)
    }

    // ======================================================================
    // Slice 2 — creator-seed + MAKO + MarketType expansion + owner alignment
    //
    // 17 new tests covering the round-7-cleared design:
    //   - 6 creator-seed branches (sub-MIN reject, YES + NO side recording,
    //     cooldown, constant pin, blocklist reject). The fee-on-transfer
    //     seed-transfer case is covered by the renamed
    //     test_feeOnTransferToken_revertsOnCreateMarket above, not duplicated
    //     here.
    //   - 6 MAKO-type branches (owner gate, non-owner reject, nonzero-seed
    //     reject, fee-snapshot zeroing, happy bet+claim, claimCreatorFee noop)
    //   - 4 new-enum smoke (FOREX / COMMODITIES / STOCKS happy + stability v2)
    //   - 1 owner-alignment regression (post-rotation rejection)
    // ======================================================================

    // ------------------------------------------------------------------
    // S2-1. createMarket with seed below MIN_CREATOR_SEED reverts
    // ------------------------------------------------------------------
    function test_createMarket_belowCreatorSeed_reverts() public {
        uint256 belowMin = mako.MIN_CREATOR_SEED() - 1;
        vm.expectRevert(MakoMarketsV4.CreatorSeedTooSmall.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("x"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "q",
            belowMin,
            true
        );
    }

    // ------------------------------------------------------------------
    // S2-2. Seed lands as creator's first bet on the chosen side (YES);
    //       yesBets / totalYes / yesBettorCount updated; BetPlaced emitted.
    // ------------------------------------------------------------------
    function test_createMarket_seedRecordedAsFirstBet() public {
        vm.recordLogs();
        uint256 id = _createCryptoMarket(); // helper seeds 1 USDC YES
        MakoMarketsV4.Market memory m = mako.getMarket(id);

        assertEq(mako.yesBets(id, address(this)), ONE_USDC);
        assertEq(m.totalYes, ONE_USDC);
        assertEq(uint256(m.yesBettorCount), 1);
        assertEq(mako.noBets(id, address(this)), 0);
        assertEq(m.totalNo, 0);
        assertEq(uint256(m.noBettorCount), 0);

        // BetPlaced event emitted alongside MarketCreated in the same tx.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawBetPlaced = false;
        bytes32 betPlacedSig = keccak256("BetPlaced(uint256,address,bool,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == betPlacedSig) {
                sawBetPlaced = true;
                break;
            }
        }
        assertTrue(sawBetPlaced, "BetPlaced not emitted for creator seed");
    }

    // ------------------------------------------------------------------
    // S2-3. Seed on NO side records correctly (creatorYes = false).
    // ------------------------------------------------------------------
    function test_createMarket_seedNo_recordsOnNoSide() public {
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("x"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "q",
            ONE_USDC,
            false
        );
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(mako.noBets(id, address(this)), ONE_USDC);
        assertEq(m.totalNo, ONE_USDC);
        assertEq(uint256(m.noBettorCount), 1);
        assertEq(m.totalYes, 0);
        assertEq(uint256(m.yesBettorCount), 0);
    }

    // ------------------------------------------------------------------
    // S2-4. Seed sets lastBetTime; creator's next placeBet within
    //       MIN_SECONDS_BETWEEN_BETS reverts BetTooSoon.
    // ------------------------------------------------------------------
    function test_createMarket_cooldownAppliesAfterSeed() public {
        uint256 id = _createCryptoMarket();

        // Test contract is creator; its placeBet within 30s of seed must revert.
        usdc.approve(address(mako), type(uint256).max);
        usdc.mint(address(this), 10 * ONE_USDC); // ensure funds for the would-be bet
        vm.expectRevert(MakoMarketsV4.BetTooSoon.selector);
        mako.placeBet(id, true, ONE_USDC);

        // After cooldown: succeeds.
        vm.warp(block.timestamp + 31);
        mako.placeBet(id, true, ONE_USDC);
    }

    // ------------------------------------------------------------------
    // S2-5. MIN_CREATOR_SEED constant pin: 1_000_000 base units (1.00 USDC).
    // ------------------------------------------------------------------
    function test_minCreatorSeed_constant() public view {
        assertEq(mako.MIN_CREATOR_SEED(), 1_000_000);
    }

    // ------------------------------------------------------------------
    // S2-6. Blocklisted wallet cannot create a non-MAKO market.
    //       Seed = bet, blocked wallets cannot bet anywhere else → must
    //       not slip through createMarket either.
    // ------------------------------------------------------------------
    function test_createMarket_blockedWallet_reverts() public {
        mako.setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.WalletIsBlocked.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("x"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "q",
            ONE_USDC,
            true
        );
    }

    // ------------------------------------------------------------------
    // S2-7. MAKO market: owner can create with seed = 0; pool starts empty.
    // ------------------------------------------------------------------
    function test_createMakoMarket_byOwner_succeeds() public {
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.MAKO,
            bytes32("mako:fed-rate-cut"),
            uint64(block.timestamp + 1 hours),
            uint64(block.timestamp + 2 hours),
            "Will the Fed cut rates this month?",
            0,
            true
        );
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.mType), uint8(MakoMarketsV4.MarketType.MAKO));
        assertEq(m.totalYes, 0);
        assertEq(m.totalNo, 0);
        assertEq(uint256(m.creatorFeeBpsSnapshot), 0); // MAKO forfeits creator fee
        assertEq(uint256(m.protocolFeeBpsSnapshot), 100); // 1% protocol fee still applies
    }

    // ------------------------------------------------------------------
    // S2-8. MAKO market: non-owner cannot create.
    // ------------------------------------------------------------------
    function test_createMakoMarket_byNonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.NotOwnerForMakoMarket.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.MAKO,
            bytes32("x"),
            uint64(block.timestamp + 1 hours),
            uint64(block.timestamp + 2 hours),
            "q",
            0,
            true
        );
    }

    // ------------------------------------------------------------------
    // S2-9. MAKO market with nonzero seed reverts CreatorSeedNotAllowed.
    // ------------------------------------------------------------------
    function test_createMakoMarket_withNonzeroSeed_reverts() public {
        vm.expectRevert(MakoMarketsV4.CreatorSeedNotAllowed.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.MAKO,
            bytes32("x"),
            uint64(block.timestamp + 1 hours),
            uint64(block.timestamp + 2 hours),
            "q",
            ONE_USDC, // disallowed for MAKO
            true
        );
    }

    // ------------------------------------------------------------------
    // S2-10. MAKO resolve path: protocol fee accrues at 1%, creator fee = 0.
    //        Bettors get 99% payout (vs 97% for the other types).
    // ------------------------------------------------------------------
    function test_makoMarket_resolvePath_paysOnly1PctProtocolFee() public {
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.MAKO,
            bytes32("mako:btc-price"),
            uint64(block.timestamp + 1 hours),
            uint64(block.timestamp + 2 hours),
            "Will BTC close above $100k on Friday?",
            0,
            true
        );

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 40 * ONE_USDC);

        vm.warp(block.timestamp + 3 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        // Pool 100 USDC, protocol fee 1% = 1 USDC. No creator fee.
        assertEq(mako.treasuryBalance(), 1 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // S2-11. MAKO happy path bet + claim: alice gets 99% payout (not 97%).
    // ------------------------------------------------------------------
    function test_makoMarket_betAndClaim_happyPath() public {
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.MAKO,
            bytes32("mako:event"),
            uint64(block.timestamp + 1 hours),
            uint64(block.timestamp + 2 hours),
            "Mako-curated question",
            0,
            true
        );

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 40 * ONE_USDC);

        vm.warp(block.timestamp + 3 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        // Pool 100, payoutPool with no creator fee = 100 * 0.99 = 99 USDC.
        // Alice is sole YES bettor → claims all 99 USDC.
        uint256 before_ = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertEq(usdc.balanceOf(alice) - before_, 99 * ONE_USDC);
    }

    // ------------------------------------------------------------------
    // S2-12. claimCreatorFee on a MAKO market: succeeds but transfers 0.
    //        Snapshot was zeroed at create; no special-case at claim time.
    // ------------------------------------------------------------------
    function test_makoMarket_claimCreatorFee_isZeroNoop() public {
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.MAKO,
            bytes32("x"),
            uint64(block.timestamp + 1 hours),
            uint64(block.timestamp + 2 hours),
            "q",
            0,
            true
        );
        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        vm.prank(bob);
        mako.placeBet(id, false, 40 * ONE_USDC);
        vm.warp(block.timestamp + 3 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        // Owner is the creator (address(this)). claimCreatorFee succeeds
        // but transfers zero because the snapshot is 0.
        uint256 before_ = usdc.balanceOf(address(this));
        mako.claimCreatorFee(id);
        assertEq(usdc.balanceOf(address(this)), before_);
    }

    // ------------------------------------------------------------------
    // S2-13. FOREX market happy path — same rules as CRYPTO (seed required).
    // ------------------------------------------------------------------
    function test_createForexMarket_succeeds() public {
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.FOREX,
            bytes32("EURUSD:gt:1.10"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "Will EUR/USD close above 1.10?",
            ONE_USDC,
            true
        );
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.mType), uint8(MakoMarketsV4.MarketType.FOREX));
        assertEq(m.totalYes, ONE_USDC);
        assertEq(uint256(m.creatorFeeBpsSnapshot), 200); // non-MAKO gets full creator fee
    }

    // ------------------------------------------------------------------
    // S2-14. COMMODITIES market happy path.
    // ------------------------------------------------------------------
    function test_createCommoditiesMarket_succeeds() public {
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.COMMODITIES,
            bytes32("XAU:gt:2000"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "Will gold close above $2000?",
            ONE_USDC,
            true
        );
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.mType), uint8(MakoMarketsV4.MarketType.COMMODITIES));
    }

    // ------------------------------------------------------------------
    // S2-15. STOCKS market happy path.
    // ------------------------------------------------------------------
    function test_createStocksMarket_succeeds() public {
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.STOCKS,
            bytes32("AAPL:gt:200"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "Will AAPL close above $200?",
            ONE_USDC,
            true
        );
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.mType), uint8(MakoMarketsV4.MarketType.STOCKS));
    }

    // ------------------------------------------------------------------
    // S2-16. Enum stability v2: append-only invariant. Original 3 entries
    //        keep their numeric identities; 4 new entries land at 3..6.
    //        Indexers + AA allowlists pin specific uint8 values; any
    //        reordering breaks them. This test makes reordering loud.
    // ------------------------------------------------------------------
    function test_enumOrdering_isStable_v2() public pure {
        assertEq(uint8(MakoMarketsV4.MarketType.FOOTBALL), 0);
        assertEq(uint8(MakoMarketsV4.MarketType.CRYPTO), 1);
        assertEq(uint8(MakoMarketsV4.MarketType.BASKETBALL), 2);
        assertEq(uint8(MakoMarketsV4.MarketType.FOREX), 3);
        assertEq(uint8(MakoMarketsV4.MarketType.COMMODITIES), 4);
        assertEq(uint8(MakoMarketsV4.MarketType.STOCKS), 5);
        assertEq(uint8(MakoMarketsV4.MarketType.MAKO), 6);
    }

    // ------------------------------------------------------------------
    // S2-17. Owner-alignment regression: after transferOwnership rotates
    //        ownership away from the deploy-time owner, the OLD owner can
    //        no longer create MAKO markets — only the new owner can.
    //        Locks in the deploy-script invariant that owner == admin Safe
    //        is what gates MAKO creation.
    // ------------------------------------------------------------------
    function test_makoCreation_requiresOwnerEqualsAdminSafe() public {
        // Transfer ownership to alice (simulating admin-Safe rotation).
        mako.transferOwnership(alice);

        // Old owner (test contract) can no longer create MAKO.
        vm.expectRevert(MakoMarketsV4.NotOwnerForMakoMarket.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.MAKO,
            bytes32("x"),
            uint64(block.timestamp + 1 hours),
            uint64(block.timestamp + 2 hours),
            "q",
            0,
            true
        );

        // New owner (alice) can create MAKO.
        vm.prank(alice);
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.MAKO,
            bytes32("x"),
            uint64(block.timestamp + 1 hours),
            uint64(block.timestamp + 2 hours),
            "q",
            0,
            true
        );
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.mType), uint8(MakoMarketsV4.MarketType.MAKO));
        assertEq(m.creator, alice);
    }

    // ======================================================================
    // Daily creator-create cap (MAX_CREATES_PER_DAY = 10)
    // ======================================================================
    //
    // Verifies the v4 redeploy slice 4f-contract invariant: a single wallet
    // can create at most 10 non-MAKO markets per UTC day. MAKO is exempt.
    // The cap resets at UTC midnight (block.timestamp / 86400 rollover).

    /// Helper — create a single CRYPTO market as `creator`. Uses a unique
    /// oracleRef per call so we don't accidentally collide on any future
    /// per-oracleRef invariant; mints + approves fresh USDC so the cap is
    /// the only thing standing between the caller and creation.
    function _createCryptoAs(address creator, uint256 seed) internal returns (uint256 id) {
        usdc.mint(creator, 2 * ONE_USDC);
        vm.prank(creator);
        usdc.approve(address(mako), type(uint256).max);
        vm.prank(creator);
        id = mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32(uint256(0x1000000 + seed)),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "q",
            ONE_USDC,
            true
        );
    }

    function test_dailyCap_constants_match_spec() public view {
        assertEq(mako.MAX_CREATES_PER_DAY(), 10);
        assertEq(mako.SECONDS_PER_DAY(), 86400);
    }

    function test_dailyCap_allowsExactlyTenCreatesThenReverts() public {
        // 10 successful creates within the same UTC day.
        for (uint256 i = 0; i < 10; i++) {
            _createCryptoAs(alice, i);
        }
        (uint256 count, uint256 remaining) = mako.creatorCreatesToday(alice);
        assertEq(count, 10);
        assertEq(remaining, 0);

        // 11th fails with CreatorDailyCapExceeded.
        usdc.mint(alice, 2 * ONE_USDC);
        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.CreatorDailyCapExceeded.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32(uint256(0x99)),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "q",
            ONE_USDC,
            true
        );
    }

    function test_dailyCap_isPerWallet_aliceCapDoesNotBlockBob() public {
        // Alice maxes out.
        for (uint256 i = 0; i < 10; i++) {
            _createCryptoAs(alice, i);
        }
        // Bob — same UTC day, different wallet — can still create.
        uint256 bobId = _createCryptoAs(bob, 100);
        MakoMarketsV4.Market memory bm = mako.getMarket(bobId);
        assertEq(bm.creator, bob);

        (uint256 aliceCount,) = mako.creatorCreatesToday(alice);
        (uint256 bobCount,) = mako.creatorCreatesToday(bob);
        assertEq(aliceCount, 10);
        assertEq(bobCount, 1);
    }

    function test_dailyCap_resetsAtUtcMidnightRollover() public {
        // Alice maxes out today.
        for (uint256 i = 0; i < 10; i++) {
            _createCryptoAs(alice, i);
        }

        // Warp into the NEXT UTC day. block.timestamp / SECONDS_PER_DAY
        // is what the contract keys on; bump it forward enough to land
        // in tomorrow's bucket. +1 day + 1 second guarantees we crossed
        // the boundary regardless of the test's starting offset.
        vm.warp(block.timestamp + 1 days + 1);

        // Now alice can create again. Counter for the NEW day starts at 0.
        (uint256 countBefore, uint256 remainingBefore) = mako.creatorCreatesToday(alice);
        assertEq(countBefore, 0);
        assertEq(remainingBefore, 10);

        uint256 id = _createCryptoAs(alice, 999);
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(m.creator, alice);
        (uint256 countAfter,) = mako.creatorCreatesToday(alice);
        assertEq(countAfter, 1);
    }

    function test_dailyCap_makoExempt_adminCanExceedTen() public {
        // Admin (test contract) maxes out non-MAKO.
        for (uint256 i = 0; i < 10; i++) {
            // Use unique oracleRef each iteration. CRYPTO type via the
            // test-contract caller (it's the deployer == owner here,
            // but the cap check only applies on the non-MAKO branch
            // anyway).
            usdc.mint(address(this), 2 * ONE_USDC);
            mako.createMarket(
                MakoMarketsV4.MarketType.CRYPTO,
                bytes32(uint256(0x2000000 + i)),
                uint64(block.timestamp + 30 minutes),
                uint64(block.timestamp + 1 hours),
                "q",
                ONE_USDC,
                true
            );
        }
        (uint256 count, uint256 remaining) = mako.creatorCreatesToday(address(this));
        assertEq(count, 10);
        assertEq(remaining, 0);

        // 11th non-MAKO reverts on the cap.
        usdc.mint(address(this), 2 * ONE_USDC);
        vm.expectRevert(MakoMarketsV4.CreatorDailyCapExceeded.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32(uint256(0xdead)),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "q",
            ONE_USDC,
            true
        );

        // BUT MAKO creation succeeds — admin path bypasses the cap.
        // Create three MAKO markets back-to-back to prove there's no
        // hidden parallel counter for MAKO either.
        for (uint256 j = 0; j < 3; j++) {
            uint256 makoId = mako.createMarket(
                MakoMarketsV4.MarketType.MAKO,
                bytes32(uint256(0x3000000 + j)),
                uint64(block.timestamp + 1 hours),
                uint64(block.timestamp + 2 hours),
                "mako q",
                0,
                true
            );
            MakoMarketsV4.Market memory m = mako.getMarket(makoId);
            assertEq(uint8(m.mType), uint8(MakoMarketsV4.MarketType.MAKO));
        }

        // The non-MAKO counter for the admin is unchanged by the MAKO
        // creates (MAKO never increments).
        (uint256 countAfterMako,) = mako.creatorCreatesToday(address(this));
        assertEq(countAfterMako, 10);
    }

    function test_dailyCap_revertDoesNotBurnSlot() public {
        // Alice has 9 valid creates. The 10th attempt has a BAD argument
        // (closeTime in the past) and reverts BEFORE the cap increment.
        // After that revert her counter must still be 9 — a doomed call
        // cannot burn a daily slot.
        for (uint256 i = 0; i < 9; i++) {
            _createCryptoAs(alice, i);
        }
        (uint256 countBefore,) = mako.creatorCreatesToday(alice);
        assertEq(countBefore, 9);

        usdc.mint(alice, 2 * ONE_USDC);
        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.BadCloseTime.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32(uint256(0x9999)),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp - 1), // closeTime in the past → BadCloseTime
            "q",
            ONE_USDC,
            true
        );

        // Counter still 9; alice can still do one more successful create.
        (uint256 countAfterRevert,) = mako.creatorCreatesToday(alice);
        assertEq(countAfterRevert, 9);

        uint256 id = _createCryptoAs(alice, 10);
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(m.creator, alice);
        (uint256 countAt10,) = mako.creatorCreatesToday(alice);
        assertEq(countAt10, 10);
    }

    function test_creatorCreatesToday_view_reflectsCountAndRemaining() public {
        // 0 / 10 at the start.
        (uint256 c0, uint256 r0) = mako.creatorCreatesToday(alice);
        assertEq(c0, 0);
        assertEq(r0, 10);

        _createCryptoAs(alice, 1);
        (uint256 c1, uint256 r1) = mako.creatorCreatesToday(alice);
        assertEq(c1, 1);
        assertEq(r1, 9);

        // Walk to 10 / 0.
        for (uint256 i = 2; i < 11; i++) {
            _createCryptoAs(alice, i);
        }
        (uint256 c10, uint256 r10) = mako.creatorCreatesToday(alice);
        assertEq(c10, 10);
        assertEq(r10, 0);
    }

    // Codex r1 MINOR 1: exact UTC-midnight equality. block.timestamp /
    // SECONDS_PER_DAY puts ts == N*86400-1 in day N-1 (still capped) and
    // ts == N*86400 in day N (fresh counter). Pin both ends of the
    // boundary rather than just "+1 day + 1 second crossed it."
    function test_dailyCap_utcMidnightBoundaryEquality() public {
        uint256 baseDay = (block.timestamp / 86400) + 10;
        uint256 dayEnd = baseDay * 86400 - 1;
        vm.warp(dayEnd);

        for (uint256 i = 0; i < 10; i++) {
            _createCryptoAs(alice, i);
        }
        (uint256 endCount,) = mako.creatorCreatesToday(alice);
        assertEq(endCount, 10);

        // 11th at the same second still reverts. dayEnd is the last
        // second of the "ending" bucket.
        usdc.mint(alice, 2 * ONE_USDC);
        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.CreatorDailyCapExceeded.selector);
        mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32(uint256(0xb04ed0ad)),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "q",
            ONE_USDC,
            true
        );

        // Step forward exactly one second — block.timestamp == N*86400,
        // integer division puts us in the new day. Counter resets.
        vm.warp(dayEnd + 1);
        (uint256 newDayCount, uint256 newDayRemaining) = mako.creatorCreatesToday(alice);
        assertEq(newDayCount, 0);
        assertEq(newDayRemaining, 10);

        uint256 id = _createCryptoAs(alice, 999);
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(m.creator, alice);
        (uint256 afterFresh,) = mako.creatorCreatesToday(alice);
        assertEq(afterFresh, 1);
    }

    // Codex r1 MINOR 2: post-increment revert rollback. The counter is
    // incremented before safeTransferFrom; a fee-on-transfer token causes
    // TransferAmountMismatch to revert later in the same call. EVM
    // semantics roll back every state write, including the counter.
    // Pin it so a future refactor that moves the increment past the
    // transfer (and thus stops rolling back on transfer-revert) is loud.
    function test_dailyCap_revertOnTransferRollsBackCounter() public {
        FeeOnTransferUSDC fot = new FeeOnTransferUSDC();
        MakoMarketsV4 fotMako = new MakoMarketsV4(treasury, address(fot));

        fot.mint(alice, 100 * ONE_USDC);
        vm.prank(alice);
        fot.approve(address(fotMako), type(uint256).max);

        (uint256 before,) = fotMako.creatorCreatesToday(alice);
        assertEq(before, 0);

        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.TransferAmountMismatch.selector);
        fotMako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("rollback"),
            uint64(block.timestamp + 30 minutes),
            uint64(block.timestamp + 1 hours),
            "q",
            ONE_USDC,
            true
        );

        (uint256 afterRevert, uint256 remainingAfter) = fotMako.creatorCreatesToday(alice);
        assertEq(afterRevert, 0);
        assertEq(remainingAfter, 10);
    }
}
