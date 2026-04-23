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
        id = mako.createMarket(
            MakoMarketsV4.MarketType.CRYPTO,
            bytes32("ETH:gt:3500"),
            uint64(block.timestamp + 1 hours),
            "Will ETH close above $3500?"
        );
    }

    function _createFootballMarket() internal returns (uint256 id) {
        id = mako.createMarket(
            MakoMarketsV4.MarketType.FOOTBALL,
            bytes32("514237:home_win:0"),
            uint64(block.timestamp + 2 hours),
            "Will Arsenal beat Chelsea?"
        );
    }

    function _createBasketballMarket() internal returns (uint256 id) {
        id = mako.createMarket(
            MakoMarketsV4.MarketType.BASKETBALL,
            bytes32("18923:home_win:0"),
            uint64(block.timestamp + 3 hours),
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
        vm.warp(block.timestamp + 2 hours); // past closeTime

        vm.prank(alice);
        vm.expectRevert(MakoMarketsV4.MarketClosed.selector);
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
    // 10. Dust-bet grief attack → forced refund
    // ------------------------------------------------------------------
    function test_dustBetAttack_triggersRefund() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);

        // Attacker plants exactly MIN_BET (1 USDC) on the empty side to try
        // to unlock fee extraction. 1/60 = 1.67% — well below the 4.08%
        // dynamic threshold at the default 2% creator fee.
        vm.prank(carol);
        mako.placeBet(id, false, 1 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarketsV4.Outcome.REFUND));

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 60 * ONE_USDC);

        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        mako.claim(id);
        assertEq(usdc.balanceOf(carol) - carolBefore, 1 * ONE_USDC);

        vm.expectRevert(MakoMarketsV4.BadOutcome.selector);
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
    // 13. Pool below the dynamic threshold → forced refund
    // ------------------------------------------------------------------
    function test_belowDynamicThreshold_refunds() public {
        uint256 id = _createCryptoMarket();

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);
        // 1 USDC on NO = 1.67% of 60, BELOW the 4.08% threshold.
        vm.prank(bob);
        mako.placeBet(id, false, 1 * ONE_USDC);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);

        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarketsV4.Outcome.REFUND));

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        mako.claim(id);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 60 * ONE_USDC);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        mako.claim(id);
        assertEq(usdc.balanceOf(bob) - bobBefore, 1 * ONE_USDC);

        assertEq(mako.treasuryBalance(), 0);
    }

    // ------------------------------------------------------------------
    // 14. Creator-as-attacker profitability check
    // ------------------------------------------------------------------
    function test_creatorAttacker_isUnprofitable_atThreshold() public {
        vm.prank(carol);
        uint256 id = mako.createMarket(
            MakoMarketsV4.MarketType.BASKETBALL,
            bytes32("18923:home_win:0"),
            uint64(block.timestamp + 1 hours),
            "Will the Lakers beat the Celtics?"
        );

        vm.prank(alice);
        mako.placeBet(id, true, 60 * ONE_USDC);

        uint256 carolInitial = usdc.balanceOf(carol);

        uint256 threshold = mako.minLiquidityRatioBps();
        uint256 carolBet = (60 * ONE_USDC * threshold) / 10000; // ≈ 1.212 USDC at 408 bps
        vm.prank(carol);
        mako.placeBet(id, false, carolBet);

        vm.warp(block.timestamp + 2 hours);
        mako.resolveMarket(id, MakoMarketsV4.Outcome.YES);
        MakoMarketsV4.Market memory m = mako.getMarket(id);
        assertEq(uint8(m.outcome), uint8(MakoMarketsV4.Outcome.YES));

        vm.prank(carol);
        mako.claimCreatorFee(id);

        vm.prank(carol);
        vm.expectRevert(MakoMarketsV4.NoPosition.selector);
        mako.claim(id);

        uint256 carolFinal = usdc.balanceOf(carol);
        assertLt(carolFinal, carolInitial);
        uint256 netLoss = carolInitial - carolFinal;
        assertGt(netLoss, ONE_USDC / 2); // loses at least 0.5 USDC
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
    // 29. withdrawTreasury pays in USDC, zeroes out balance
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
}
