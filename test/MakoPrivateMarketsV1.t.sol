// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MakoPrivateMarketsV1} from "../src/MakoPrivateMarketsV1.sol";

// ---------------------------------------------------------------------------
// Minimal mock USDC (6 decimals)
// ---------------------------------------------------------------------------

contract MockUSDC {
    string public constant name = "Mock USDC";
    string public constant symbol = "mUSDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @dev Mock token with configurable decimals — used to assert the constructor
///      rejects non-6-decimal tokens (the BadDecimals guard).
contract WrongDecimalsToken {
    uint8 public immutable decimals;

    constructor(uint8 d) {
        decimals = d;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev Deflationary mock — burns 1% of every transferFrom. Used to assert the
///      stake-path balance-delta guard rejects fee-on-transfer tokens.
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        uint256 burn = amount / 100; // 1% burn on inbound
        balanceOf[to] += amount - burn;
        return true;
    }
}

/// @dev USDC mock that fails on `transfer` (outbound) when toggled. Used to
///      assert claim-path rollback: failed payout must leave userClaimed and
///      feeAndDustClaimed unchanged so the recipient can retry.
contract FlakyUSDC {
    string public constant name = "Flaky USDC";
    string public constant symbol = "fUSDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public transferShouldRevert;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setTransferShouldRevert(bool v) external {
        transferShouldRevert = v;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (transferShouldRevert) revert("flaky transfer");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MakoPrivateMarketsV1Test is Test {
    MakoPrivateMarketsV1 internal pm;
    MockUSDC internal usdc;

    address internal treasury = address(0x7E0);
    address internal creator = address(0xC0FFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCAA01);
    address internal dave = address(0xDA7E);

    uint64 internal constant T0 = 1_700_000_000;

    uint8 constant SHAPE_FRIENDLY = 0;
    uint8 constant SHAPE_OPEN_VOTE = 1;
    uint8 constant SHAPE_PRIZE_POOL = 2;

    uint8 constant FRIENDLY_NO = 0;
    uint8 constant FRIENDLY_YES = 1;

    uint8 constant STATE_CREATED = 0;
    uint8 constant STATE_OPEN = 1;
    uint8 constant STATE_AWAITING = 2;
    uint8 constant STATE_RESOLVED = 3;
    uint8 constant STATE_EMPTY_RESOLVED = 4;
    uint8 constant STATE_CANCELED = 5;
    uint8 constant STATE_TIMED_OUT = 6;
    uint8 constant STATE_ZERO_STAKE = 7;

    function setUp() public {
        vm.warp(T0);
        usdc = new MockUSDC();
        pm = new MakoPrivateMarketsV1(address(usdc), treasury);

        // Fund test users
        address[5] memory users = [creator, alice, bob, carol, dave];
        for (uint256 i = 0; i < users.length; i++) {
            usdc.mint(users[i], 1_000_000 * 1e6); // 1M USDC
            vm.prank(users[i]);
            usdc.approve(address(pm), type(uint256).max);
        }
    }

    // -----------------------------------------------------------------
    // Builders
    // -----------------------------------------------------------------

    function _friendlyParams(uint64 opensAt, uint64 closeAt)
        internal
        pure
        returns (MakoPrivateMarketsV1.CreateParams memory p)
    {
        p.shape = MakoPrivateMarketsV1.MarketShape.Friendly;
        p.stakingOpensAt = opensAt;
        p.closeAt = closeAt;
        p.title = bytes("My Friendly");
        p.description = bytes("A friendly bet");
        p.streamUrl = bytes("");
        p.optionLabels = new bytes[](2);
        p.optionLabels[0] = bytes("NO");
        p.optionLabels[1] = bytes("YES");
        p.viewMode = MakoPrivateMarketsV1.VisibilityView.LinkOnly;
        p.participationMode = MakoPrivateMarketsV1.VisibilityParticipation.Open;
        p.clientNonce = bytes32(uint256(0xCAFE));
    }

    function _openVoteParams(uint64 opensAt, uint64 closeAt, uint256 fixedStake_, uint8 winners)
        internal
        pure
        returns (MakoPrivateMarketsV1.CreateParams memory p)
    {
        p.shape = MakoPrivateMarketsV1.MarketShape.OpenVote;
        p.stakingOpensAt = opensAt;
        p.closeAt = closeAt;
        p.title = bytes("My Vote");
        p.description = bytes("Vote for the best");
        p.streamUrl = bytes("");
        p.optionLabels = new bytes[](4);
        p.optionLabels[0] = bytes("Alpha");
        p.optionLabels[1] = bytes("Beta");
        p.optionLabels[2] = bytes("Gamma");
        p.optionLabels[3] = bytes("Delta");
        p.viewMode = MakoPrivateMarketsV1.VisibilityView.LinkOnly;
        p.participationMode = MakoPrivateMarketsV1.VisibilityParticipation.Open;
        p.fixedStake = fixedStake_;
        p.winnersCount = winners;
        p.clientNonce = bytes32(uint256(0xBABE));
    }

    function _prizePoolParams(uint64 opensAt, uint64 closeAt, address[] memory wallets, uint8 winners)
        internal
        pure
        returns (MakoPrivateMarketsV1.CreateParams memory p)
    {
        p.shape = MakoPrivateMarketsV1.MarketShape.PrizePool;
        p.stakingOpensAt = opensAt;
        p.closeAt = closeAt;
        p.title = bytes("Prize Pool");
        p.description = bytes("Stake on a team");
        p.streamUrl = bytes("");
        p.optionLabels = new bytes[](wallets.length);
        for (uint256 i = 0; i < wallets.length; i++) {
            p.optionLabels[i] = bytes("Team");
        }
        p.participantWallets = wallets;
        p.viewMode = MakoPrivateMarketsV1.VisibilityView.Public;
        p.participationMode = MakoPrivateMarketsV1.VisibilityParticipation.Open;
        p.winnersCount = winners;
        p.perStakeMin = 0;
        p.perStakeMax = 0;
        p.perWalletCumulativeMax = 0;
        p.clientNonce = bytes32(uint256(0xF00D));
    }

    function _createFriendly() internal returns (uint256 id) {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 days));
        vm.prank(creator);
        id = pm.createMarket(p);
    }

    function _createOpenVote(uint256 fixedStake_, uint8 winners) internal returns (uint256 id) {
        MakoPrivateMarketsV1.CreateParams memory p =
            _openVoteParams(uint64(block.timestamp), uint64(block.timestamp + 1 days), fixedStake_, winners);
        vm.prank(creator);
        id = pm.createMarket(p);
    }

    function _createPrizePool(address[] memory wallets, uint8 winners) internal returns (uint256 id) {
        MakoPrivateMarketsV1.CreateParams memory p =
            _prizePoolParams(uint64(block.timestamp), uint64(block.timestamp + 1 days), wallets, winners);
        vm.prank(creator);
        id = pm.createMarket(p);
    }

    // =================================================================
    // Group 1 — Lifecycle correctness
    // =================================================================

    function test_lifecycle_immediateOpenAccepted() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours));
        vm.prank(creator);
        uint256 id = pm.createMarket(p);
        assertEq(uint8(pm.getMarket(id).effectiveState), STATE_OPEN);
    }

    function test_lifecycle_futureOpenAccepted() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp + 1 hours), uint64(block.timestamp + 2 hours));
        vm.prank(creator);
        uint256 id = pm.createMarket(p);
        assertEq(uint8(pm.getMarket(id).effectiveState), STATE_CREATED);
    }

    function test_lifecycle_pastOpenReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp - 1), uint64(block.timestamp + 1 hours));
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.InvalidTimestamps.selector);
        pm.createMarket(p);
    }

    function test_lifecycle_closeBeforeOpenReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp + 100), uint64(block.timestamp + 50));
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.InvalidTimestamps.selector);
        pm.createMarket(p);
    }

    function test_lifecycle_closeEqualOpenReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp + 100), uint64(block.timestamp + 100));
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.InvalidTimestamps.selector);
        pm.createMarket(p);
    }

    function test_lifecycle_stakeAtOpenAccepted() public {
        uint64 opensAt = uint64(block.timestamp + 100);
        MakoPrivateMarketsV1.CreateParams memory p = _friendlyParams(opensAt, opensAt + 1 hours);
        vm.prank(creator);
        uint256 id = pm.createMarket(p);
        vm.warp(opensAt);
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
    }

    function test_lifecycle_stakeAtCloseRejected() public {
        uint256 id = _createFriendly();
        vm.warp(block.timestamp + 1 days); // == closeAt
        vm.prank(alice);
        vm.expectRevert(MakoPrivateMarketsV1.StakingClosed.selector);
        pm.bet(id, FRIENDLY_YES, 1e6);
    }

    function test_lifecycle_editAtOpenRejected() public {
        uint64 opensAt = uint64(block.timestamp + 100);
        MakoPrivateMarketsV1.CreateParams memory p = _friendlyParams(opensAt, opensAt + 1 hours);
        vm.prank(creator);
        uint256 id = pm.createMarket(p);
        vm.warp(opensAt);
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.EditWindowClosed.selector);
        pm.editMetadata(id, p);
    }

    function test_lifecycle_creatorActionAtCloseAcceptedWithStake() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 1e6);
        vm.warp(block.timestamp + 1 days); // == closeAt
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
    }

    function test_lifecycle_creatorActionAtTimeoutBoundaryRejected() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
        vm.warp(block.timestamp + 1 days + 7 days);
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.CreatorWindowClosed.selector);
        pm.resolve(id, FRIENDLY_YES);
    }

    function test_lifecycle_finalizeTooEarlyReverts() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
        vm.expectRevert(MakoPrivateMarketsV1.NothingToFinalize.selector);
        pm.finalize(id);
    }

    function test_lifecycle_finalizeTimeoutOk() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
        vm.warp(block.timestamp + 1 days + 7 days);
        pm.finalize(id);
        assertEq(uint8(pm.getMarket(id).storedState), STATE_TIMED_OUT);
    }

    function test_lifecycle_finalizeZeroStakeOk() public {
        uint256 id = _createFriendly();
        vm.warp(block.timestamp + 1 days);
        pm.finalize(id);
        assertEq(uint8(pm.getMarket(id).storedState), STATE_ZERO_STAKE);
    }

    function test_lifecycle_finalizeIdempotentTerminal() public {
        uint256 id = _createFriendly();
        vm.warp(block.timestamp + 1 days);
        pm.finalize(id);
        // Second call is a no-op (no revert)
        pm.finalize(id);
        assertEq(uint8(pm.getMarket(id).storedState), STATE_ZERO_STAKE);
    }

    // =================================================================
    // Group 2 — Create-time validation
    // =================================================================

    function test_create_titleTooLargeReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours));
        bytes memory big = new bytes(101);
        p.title = big;
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.MetadataTooLarge.selector);
        pm.createMarket(p);
    }

    function test_create_descriptionTooLargeReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours));
        p.description = new bytes(2001);
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.MetadataTooLarge.selector);
        pm.createMarket(p);
    }

    function test_create_optionLabelTooLargeReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _openVoteParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours), 1e6, 2);
        p.optionLabels[0] = new bytes(81);
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.MetadataTooLarge.selector);
        pm.createMarket(p);
    }

    function test_create_streamUrlTooLargeReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours));
        p.streamUrl = new bytes(257);
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.MetadataTooLarge.selector);
        pm.createMarket(p);
    }

    function test_create_tooManyOptionsReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _openVoteParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours), 1e6, 2);
        p.optionLabels = new bytes[](51);
        for (uint256 i = 0; i < 51; i++) {
            p.optionLabels[i] = bytes("X");
        }
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.InvalidOptions.selector);
        pm.createMarket(p);
    }

    function test_create_winnersZeroReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _openVoteParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours), 1e6, 0);
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.InvalidWinners.selector);
        pm.createMarket(p);
    }

    function test_create_winnersElevenReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _openVoteParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours), 1e6, 11);
        // Need >= 11 options for the winners-vs-options check to not trip first
        p.optionLabels = new bytes[](12);
        for (uint256 i = 0; i < 12; i++) {
            p.optionLabels[i] = bytes("X");
        }
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.InvalidWinners.selector);
        pm.createMarket(p);
    }

    function test_create_winnersExceedOptionsReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _openVoteParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours), 1e6, 5);
        p.optionLabels = new bytes[](3);
        p.optionLabels[0] = bytes("a");
        p.optionLabels[1] = bytes("b");
        p.optionLabels[2] = bytes("c");
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.InvalidWinners.selector);
        pm.createMarket(p);
    }

    function test_create_participantsDuplicatedReverts() public {
        address[] memory wallets = new address[](3);
        wallets[0] = alice;
        wallets[1] = bob;
        wallets[2] = alice;
        MakoPrivateMarketsV1.CreateParams memory p =
            _prizePoolParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours), wallets, 1);
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.InvalidParticipants.selector);
        pm.createMarket(p);
    }

    function test_create_participantZeroReverts() public {
        address[] memory wallets = new address[](2);
        wallets[0] = alice;
        wallets[1] = address(0);
        MakoPrivateMarketsV1.CreateParams memory p =
            _prizePoolParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours), wallets, 1);
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.InvalidParticipants.selector);
        pm.createMarket(p);
    }

    function test_create_participantTreasuryReverts() public {
        address[] memory wallets = new address[](2);
        wallets[0] = alice;
        wallets[1] = treasury;
        MakoPrivateMarketsV1.CreateParams memory p =
            _prizePoolParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours), wallets, 1);
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.TreasuryNotAllowed.selector);
        pm.createMarket(p);
    }

    function test_create_allowlistTreasuryReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours));
        p.participationMode = MakoPrivateMarketsV1.VisibilityParticipation.Allowlisted;
        p.allowlist = new address[](2);
        p.allowlist[0] = alice;
        p.allowlist[1] = treasury;
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.TreasuryNotAllowed.selector);
        pm.createMarket(p);
    }

    function test_create_allowlistTooLargeReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours));
        p.participationMode = MakoPrivateMarketsV1.VisibilityParticipation.Allowlisted;
        p.allowlist = new address[](101);
        for (uint256 i = 0; i < 101; i++) {
            p.allowlist[i] = address(uint160(i + 1));
        }
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.InvalidAllowlist.selector);
        pm.createMarket(p);
    }

    function test_create_streamForcesPublicView() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours));
        p.streamUrl = bytes("https://www.youtube.com/embed/abcdefghijk");
        p.viewMode = MakoPrivateMarketsV1.VisibilityView.LinkOnly; // request link-only
        vm.prank(creator);
        uint256 id = pm.createMarket(p);
        assertEq(uint8(pm.getMarket(id).viewMode), uint8(MakoPrivateMarketsV1.VisibilityView.Public));
    }

    function test_create_perStakeMinBelowFloorReverts() public {
        address[] memory wallets = new address[](2);
        wallets[0] = alice;
        wallets[1] = bob;
        MakoPrivateMarketsV1.CreateParams memory p =
            _prizePoolParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours), wallets, 1);
        p.perStakeMin = 9_999;
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.InvalidStakeBounds.selector);
        pm.createMarket(p);
    }

    // =================================================================
    // Group 3 — Friendlies correctness
    // =================================================================

    function test_friendly_pariMutuelPayout() public {
        uint256 id = _createFriendly();
        // YES pool 100, NO pool 200. Resolve YES.
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 100e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 200e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
        // fee = 200 * 100 / 10000 = 2 USDC; loser-fee=198; winner pool=100
        // alice owed = 100 + (100 * 198 / 100) = 100 + 198 = 298 USDC
        assertEq(pm.getPendingClaim(id, alice), 298e6);
        assertEq(pm.getPendingClaim(id, bob), 0);
    }

    function test_friendly_multiBetAggregation() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 30e6);
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 70e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 200e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
        // Alice has 100 on YES total → same outcome as single 100 bet
        assertEq(pm.getPendingClaim(id, alice), 298e6);
    }

    function test_friendly_emptyYesPoolResolveYes() public {
        uint256 id = _createFriendly();
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 50e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
        // EmptyPool path: NO bettors get refund, no fee
        assertEq(uint8(pm.getMarket(id).storedState), STATE_EMPTY_RESOLVED);
        assertEq(pm.getPendingClaim(id, bob), 50e6);
    }

    function test_friendly_emptyNoPoolResolveYes() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 50e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
        // YES bettors refunded full
        assertEq(uint8(pm.getMarket(id).storedState), STATE_EMPTY_RESOLVED);
        assertEq(pm.getPendingClaim(id, alice), 50e6);
    }

    function test_friendly_resolveOnlyByCreator() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 1e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(MakoPrivateMarketsV1.NotCreator.selector);
        pm.resolve(id, FRIENDLY_YES);
    }

    function test_friendly_timeoutRefundsAll() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 30e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 20e6);
        vm.warp(block.timestamp + 1 days + 7 days);
        // Lazy TimedOut without finalize
        assertEq(uint8(pm.getMarket(id).effectiveState), STATE_TIMED_OUT);
        assertEq(pm.getPendingClaim(id, alice), 30e6);
        assertEq(pm.getPendingClaim(id, bob), 20e6);
        // Treasury gets nothing
        assertEq(pm.getPendingClaim(id, treasury), 0);
    }

    function test_friendly_loserClaimReverts() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 100e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 100e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
        vm.prank(bob);
        vm.expectRevert(MakoPrivateMarketsV1.NothingToClaim.selector);
        pm.claim(id);
    }

    function test_friendly_sameWalletHedge() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 10e6);
        vm.prank(alice);
        pm.bet(id, FRIENDLY_NO, 5e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 95e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
        // YES pool=10 wins; NO pool=100; fee=1; alice winning side=10
        // alice owed = 10 + (10 * 99 / 10) = 10 + 99 = 109
        assertEq(pm.getPendingClaim(id, alice), 109e6);
    }

    // =================================================================
    // Group 4 — Open Vote correctness
    // =================================================================

    function test_openVote_fixedStakeEnforced() public {
        uint256 id = _createOpenVote(2e6, 2);
        vm.warp(block.timestamp); // already open
        vm.prank(alice);
        vm.expectRevert(MakoPrivateMarketsV1.AmountAboveCap.selector);
        pm.stake(id, 0, 1e6); // wrong amount
    }

    function test_openVote_oneStakePerWallet() public {
        uint256 id = _createOpenVote(2e6, 2);
        vm.prank(alice);
        pm.stake(id, 0, 2e6);
        vm.prank(alice);
        vm.expectRevert(MakoPrivateMarketsV1.AlreadyVoted.selector);
        pm.stake(id, 1, 2e6);
    }

    function test_openVote_confirmRanksAndRefunds() public {
        uint256 id = _createOpenVote(10e6, 2);
        // Option 0: 30 (3 voters), Option 1: 20 (2 voters), Option 2: 10 (1 voter), Option 3: 0
        address[6] memory voters = [alice, bob, carol, dave, address(0xE), address(0xF)];
        usdc.mint(voters[4], 100e6);
        usdc.mint(voters[5], 100e6);
        vm.prank(voters[4]);
        usdc.approve(address(pm), type(uint256).max);
        vm.prank(voters[5]);
        usdc.approve(address(pm), type(uint256).max);
        vm.prank(alice);
        pm.stake(id, 0, 10e6);
        vm.prank(bob);
        pm.stake(id, 0, 10e6);
        vm.prank(carol);
        pm.stake(id, 0, 10e6);
        vm.prank(dave);
        pm.stake(id, 1, 10e6);
        vm.prank(voters[4]);
        pm.stake(id, 1, 10e6);
        vm.prank(voters[5]);
        pm.stake(id, 2, 10e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.confirm(id);
        (uint256[] memory topN,,) = pm.getVoteResolution(id);
        assertEq(topN.length, 2);
        assertEq(topN[0], 0);
        assertEq(topN[1], 1);
        // Each voter owed 10 - (10 * 100 / 10000) = 9.9 USDC = 9_900_000
        assertEq(pm.getPendingClaim(id, alice), 9_900_000);
    }

    function test_openVote_cancelRefundsFull() public {
        uint256 id = _createOpenVote(5e6, 2);
        vm.prank(alice);
        pm.stake(id, 0, 5e6);
        vm.prank(bob);
        pm.stake(id, 1, 5e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.cancel(id);
        assertEq(pm.getPendingClaim(id, alice), 5e6);
        assertEq(pm.getPendingClaim(id, bob), 5e6);
    }

    // =================================================================
    // Group 5 — Prize Pool correctness
    // =================================================================

    function test_prizePool_distributeProportional() public {
        address[] memory wallets = new address[](4);
        wallets[0] = address(0xA1);
        wallets[1] = address(0xA2);
        wallets[2] = address(0xA3);
        wallets[3] = address(0xA4);
        uint256 id = _createPrizePool(wallets, 3);
        // Stakes: option 0 = 500, 1 = 300, 2 = 100, 3 = 50, total=950
        vm.prank(alice);
        pm.stake(id, 0, 500e6);
        vm.prank(bob);
        pm.stake(id, 1, 300e6);
        vm.prank(carol);
        pm.stake(id, 2, 100e6);
        vm.prank(dave);
        pm.stake(id, 3, 50e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.distribute(id);
        // fee = 950 * 1% = 9.5 → 9_500_000; distributable = 940_500_000
        // top3 sum = 900; option 0 owed = 940.5 * 500 / 900 = 522.5 → 522_500_000
        // option 1 = 940.5 * 300 / 900 = 313.5 → 313_500_000
        // option 2 = 940.5 * 100 / 900 = 104.5 → 104_500_000
        assertEq(pm.getPendingClaim(id, address(0xA1)), 522_500_000);
        assertEq(pm.getPendingClaim(id, address(0xA2)), 313_500_000);
        assertEq(pm.getPendingClaim(id, address(0xA3)), 104_500_000);
        assertEq(pm.getPendingClaim(id, address(0xA4)), 0);
    }

    function test_prizePool_perWalletCumulativeCap() public {
        address[] memory wallets = new address[](2);
        wallets[0] = address(0xA1);
        wallets[1] = address(0xA2);
        MakoPrivateMarketsV1.CreateParams memory p =
            _prizePoolParams(uint64(block.timestamp), uint64(block.timestamp + 1 days), wallets, 1);
        p.perWalletCumulativeMax = 100e6;
        vm.prank(creator);
        uint256 id = pm.createMarket(p);
        vm.prank(alice);
        pm.stake(id, 0, 60e6);
        vm.prank(alice);
        pm.stake(id, 1, 40e6);
        vm.prank(alice);
        vm.expectRevert(MakoPrivateMarketsV1.WalletCapExceeded.selector);
        pm.stake(id, 0, 1e6);
    }

    function test_prizePool_sameWalletParticipantAndStaker() public {
        address[] memory wallets = new address[](2);
        wallets[0] = alice;
        wallets[1] = bob;
        uint256 id = _createPrizePool(wallets, 1);
        vm.prank(alice); // alice stakes on her own option
        pm.stake(id, 0, 100e6);
        vm.prank(carol);
        pm.stake(id, 1, 50e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.distribute(id);
        // Total 150; fee 1.5; distributable 148.5; top 1 sum = 100 (option 0); alice owed = 148.5
        assertEq(pm.getPendingClaim(id, alice), 148_500_000);
    }

    function test_prizePool_cancelRefundsAll() public {
        address[] memory wallets = new address[](2);
        wallets[0] = address(0xA1);
        wallets[1] = address(0xA2);
        uint256 id = _createPrizePool(wallets, 1);
        vm.prank(alice);
        pm.stake(id, 0, 30e6);
        vm.prank(alice);
        pm.stake(id, 1, 20e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.cancel(id);
        assertEq(pm.getPendingClaim(id, alice), 50e6);
    }

    // =================================================================
    // Group 6 — Tie-breaker correctness
    // =================================================================

    function test_tieBreaker_lowerFirstStakeSequenceWins() public {
        uint256 id = _createOpenVote(10e6, 1);
        // Two options with equal stake; option that was staked first wins
        vm.prank(alice); // option 1 first
        pm.stake(id, 1, 10e6);
        vm.prank(bob); // option 0 second
        pm.stake(id, 0, 10e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.confirm(id);
        (uint256[] memory topN,,) = pm.getVoteResolution(id);
        assertEq(topN.length, 1);
        assertEq(topN[0], 1); // option 1 wins tie because it was staked first
    }

    function test_tieBreaker_capStrictlyTen() public {
        // Setting up an 11-way tie isn't feasible without 11 options; verify cap by config
        // Already covered by test_create_winnersElevenReverts; here verify takes only N
        uint256 id = _createOpenVote(10e6, 2);
        vm.prank(alice);
        pm.stake(id, 0, 10e6);
        vm.prank(bob);
        pm.stake(id, 1, 10e6);
        vm.prank(carol);
        pm.stake(id, 2, 10e6);
        vm.prank(dave);
        pm.stake(id, 3, 10e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.confirm(id);
        (uint256[] memory topN,,) = pm.getVoteResolution(id);
        assertEq(topN.length, 2);
    }

    // =================================================================
    // Group 7 — Visibility / allowlist
    // =================================================================

    function test_allowlist_rejectsNonMember() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 days));
        p.participationMode = MakoPrivateMarketsV1.VisibilityParticipation.Allowlisted;
        p.allowlist = new address[](1);
        p.allowlist[0] = alice;
        vm.prank(creator);
        uint256 id = pm.createMarket(p);
        vm.prank(bob);
        vm.expectRevert(MakoPrivateMarketsV1.NotAllowlisted.selector);
        pm.bet(id, FRIENDLY_YES, 1e6);
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
    }

    function test_treasury_cannotBet() public {
        uint256 id = _createFriendly();
        // Fund treasury and approve, but bet must still revert.
        usdc.mint(treasury, 100e6);
        vm.prank(treasury);
        usdc.approve(address(pm), type(uint256).max);
        vm.prank(treasury);
        vm.expectRevert(MakoPrivateMarketsV1.TreasuryNotAllowed.selector);
        pm.bet(id, FRIENDLY_YES, 1e6);
    }

    // =================================================================
    // Group 8 — Claim correctness (terminal-state gates + reclaim)
    // =================================================================

    function test_claim_userReclaimReverts() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 100e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 100e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
        vm.prank(alice);
        pm.claim(id);
        vm.prank(alice);
        vm.expectRevert(MakoPrivateMarketsV1.AlreadyClaimed.selector);
        pm.claim(id);
    }

    function test_claim_treasuryReclaimRevertsWhenNothingNew() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 100e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 100e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
        vm.prank(treasury);
        pm.claim(id);
        // Treasury swept fee + any current dust. With no new winner claims
        // since, the next call has nothing new to pull (counter == available).
        vm.prank(treasury);
        vm.expectRevert(MakoPrivateMarketsV1.NothingToClaim.selector);
        pm.claim(id);
    }

    function test_claim_lazyTimedOutWithoutFinalize() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 50e6);
        vm.warp(block.timestamp + 1 days + 7 days);
        // Lazy TimedOut — no finalize called
        vm.prank(alice);
        pm.claim(id);
        assertEq(usdc.balanceOf(alice), 1_000_000 * 1e6); // back to original
    }

    function test_claim_lazyZeroStakeRevertsForRandomCaller() public {
        uint256 id = _createFriendly();
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(MakoPrivateMarketsV1.NothingToClaim.selector);
        pm.claim(id);
    }

    function test_claim_treasuryFeePaid() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 100e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 100e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
        // fee = 100 * 1% = 1
        assertEq(pm.getPendingClaim(id, treasury), 1e6);
        vm.prank(treasury);
        pm.claim(id);
        assertEq(usdc.balanceOf(treasury), 1e6);
    }

    function test_claim_nonTerminalReverts() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
        vm.prank(alice);
        vm.expectRevert(MakoPrivateMarketsV1.NotInTerminalState.selector);
        pm.claim(id);
    }

    // =================================================================
    // Group 9 — Events fidelity
    // =================================================================

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        uint8 marketShape,
        uint256 createdAt,
        uint256 stakingOpensAt,
        uint256 closeAt,
        uint8 visibilityView,
        uint8 visibilityParticipation,
        bytes32 clientNonce
    );
    event MarketMetadataFrozen(uint256 indexed marketId, uint256 frozenAt);
    event Canceled(uint256 indexed marketId, uint8 reason);

    function test_event_marketCreatedClientNonce() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours));
        p.clientNonce = bytes32(uint256(0x1234));
        vm.expectEmit(true, true, false, true);
        emit MarketCreated(
            0,
            creator,
            uint8(MakoPrivateMarketsV1.MarketShape.Friendly),
            block.timestamp,
            block.timestamp,
            block.timestamp + 1 hours,
            uint8(MakoPrivateMarketsV1.VisibilityView.LinkOnly),
            uint8(MakoPrivateMarketsV1.VisibilityParticipation.Open),
            bytes32(uint256(0x1234))
        );
        vm.prank(creator);
        pm.createMarket(p);
    }

    function test_event_metadataFrozenOnFirstStake() public {
        uint256 id = _createFriendly();
        vm.expectEmit(true, false, false, true);
        emit MarketMetadataFrozen(id, block.timestamp);
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
    }

    function test_event_metadataFrozenViaFinalizeMetadata() public {
        uint64 opensAt = uint64(block.timestamp + 1 hours);
        MakoPrivateMarketsV1.CreateParams memory p = _friendlyParams(opensAt, opensAt + 1 hours);
        vm.prank(creator);
        uint256 id = pm.createMarket(p);
        vm.warp(opensAt);
        vm.expectEmit(true, false, false, true);
        emit MarketMetadataFrozen(id, block.timestamp);
        pm.finalizeMetadata(id);
    }

    function test_event_canceledReasonZeroOnCancel() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, false, false, true);
        emit Canceled(id, 0);
        vm.prank(creator);
        pm.cancel(id);
    }

    function test_event_canceledReasonOneOnTimeout() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
        vm.warp(block.timestamp + 1 days + 7 days);
        vm.expectEmit(true, false, false, true);
        emit Canceled(id, 1);
        pm.finalize(id);
    }

    function test_event_canceledReasonTwoOnZeroStake() public {
        uint256 id = _createFriendly();
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, false, false, true);
        emit Canceled(id, 2);
        pm.finalize(id);
    }

    // =================================================================
    // Group 10 — View function fidelity
    // =================================================================

    function test_view_getMarketReturnsCanonical() public {
        uint256 id = _createFriendly();
        MakoPrivateMarketsV1.MarketView memory v = pm.getMarket(id);
        assertEq(v.creator, creator);
        assertEq(uint8(v.shape), uint8(MakoPrivateMarketsV1.MarketShape.Friendly));
        assertEq(v.clientNonce, bytes32(uint256(0xCAFE)));
    }

    function test_view_optionsAndAllowlist() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours));
        p.participationMode = MakoPrivateMarketsV1.VisibilityParticipation.Allowlisted;
        p.allowlist = new address[](2);
        p.allowlist[0] = alice;
        p.allowlist[1] = bob;
        vm.prank(creator);
        uint256 id = pm.createMarket(p);
        bytes[] memory opts = pm.getMarketOptions(id);
        assertEq(opts.length, 2);
        address[] memory al = pm.getMarketAllowlist(id);
        assertEq(al.length, 2);
        assertEq(al[0], alice);
    }

    function test_view_getPendingClaimMatchesClaim() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 100e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 100e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
        uint256 expected = pm.getPendingClaim(id, alice);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pm.claim(id);
        assertEq(usdc.balanceOf(alice) - balBefore, expected);
    }

    // =================================================================
    // Group 11 — Edge cases (lazy state model + finalize coverage)
    // =================================================================

    function test_edge_lazyEffectiveStateAtBoundary() public {
        uint256 id = _createFriendly();
        // Pre-open
        assertEq(uint8(pm.getMarket(id).effectiveState), STATE_OPEN);
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
        vm.warp(block.timestamp + 1 days); // == closeAt
        assertEq(uint8(pm.getMarket(id).effectiveState), STATE_AWAITING);
        vm.warp(block.timestamp + 7 days); // closeAt + 7 days
        assertEq(uint8(pm.getMarket(id).effectiveState), STATE_TIMED_OUT);
    }

    function test_edge_zeroStakeCreatorActionReverts() public {
        uint256 id = _createFriendly();
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.NoStakesToSettle.selector);
        pm.resolve(id, FRIENDLY_YES);
    }

    function test_edge_finalizeIdempotentOnResolved() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 100e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 100e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
        // finalize on already-resolved should be a no-op
        pm.finalize(id);
        assertEq(uint8(pm.getMarket(id).storedState), STATE_RESOLVED);
    }

    function test_edge_claimLazyTimedOutBeforeFinalize() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 30e6);
        vm.warp(block.timestamp + 1 days + 7 days);
        // Stored state still Created; effective state TimedOut.
        assertEq(uint8(pm.getMarket(id).storedState), STATE_CREATED);
        assertEq(uint8(pm.getMarket(id).effectiveState), STATE_TIMED_OUT);
        vm.prank(alice); // succeeds without finalize
        pm.claim(id);
    }

    function test_edge_fewStakedOptions() public {
        // 4 options, ask for 4 winners, but only 3 receive stakes
        uint256 id = _createOpenVote(10e6, 4);
        vm.prank(alice);
        pm.stake(id, 0, 10e6);
        vm.prank(bob);
        pm.stake(id, 1, 10e6);
        vm.prank(carol);
        pm.stake(id, 2, 10e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.confirm(id);
        (uint256[] memory topN,,) = pm.getVoteResolution(id);
        assertEq(topN.length, 3); // capped at non-zero options
    }

    // =================================================================
    // Group 12 — Gas budget (informational)
    // =================================================================

    function test_gas_betUnder250k() public {
        uint256 id = _createFriendly();
        uint256 g0 = gasleft();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
        uint256 used = g0 - gasleft();
        assertLt(used, 250_000);
    }

    function test_gas_claimFriendlyUnder150k() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 100e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 100e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
        uint256 g0 = gasleft();
        vm.prank(alice);
        pm.claim(id);
        uint256 used = g0 - gasleft();
        assertLt(used, 150_000);
    }

    function test_gas_finalizeUnder150k() public {
        uint256 id = _createFriendly();
        vm.warp(block.timestamp + 1 days);
        uint256 g0 = gasleft();
        pm.finalize(id);
        uint256 used = g0 - gasleft();
        assertLt(used, 150_000);
    }

    // =================================================================
    // Group 13 — Round-1 follow-up coverage
    // =================================================================

    /// CRITICAL regression: non-100-divisible Open Vote fixedStake — the prior
    /// aggregate fee path `(totalStake * 1%)` underflowed on dust. Per-voter
    /// fee math + voterCount * perVoterFee must produce exact dust = 0 and
    /// every voter pulls `fixedStake - perVoterFee` cleanly.
    function test_openVote_nonRoundFixedStake_noDustUnderflow() public {
        // fixedStake = 10_099 → perVoterFee = 100; perVoterRefund = 9_999
        uint256 id = _createOpenVote(10_099, 1);
        vm.prank(alice);
        pm.stake(id, 0, 10_099);
        vm.prank(bob);
        pm.stake(id, 1, 10_099);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.confirm(id);
        // Per-voter refund = 10_099 - 100 = 9_999; fee = 200; treasury claims 200
        assertEq(pm.getPendingClaim(id, alice), 9_999);
        assertEq(pm.getPendingClaim(id, bob), 9_999);
        assertEq(pm.getPendingClaim(id, treasury), 200);
        // Sanity: contract holds exactly the totalStake; no dust trap
        assertEq(usdc.balanceOf(address(pm)), 20_198);
    }

    /// MAJOR regression: Friendly truncation residue must accrue into treasury
    /// dust deterministically. This case is hand-tuned to produce exactly 1
    /// base unit of dust across both winner claims.
    ///
    /// Setup: 2 winners on YES with stakes 10_000 each (winnerPool = 20_000).
    /// 1 loser on NO with stake 10_001 (loserPool = 10_001).
    ///   fee = 10_001 * 100 / 10_000 = 100 (truncated)
    ///   distributable = 9_901
    ///   per-winner shareNum  = 10_000 * 9_901 = 99_010_000
    ///   per-winner share     = 99_010_000 / 20_000 = 4_950 (truncated)
    ///   per-winner residue   = 99_010_000 - 4_950 * 20_000 = 10_000
    /// After both winners claim:
    ///   cumulative residue numerator = 20_000 (== winnerPool)
    ///   m.dust = 1; numerator wraps back to 0
    /// Treasury sweep: 100 (fee) + 1 (dust) = 101 base units total.
    function test_friendly_dustAccruesExactlyOneBaseUnit() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 10_000);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_YES, 10_000);
        vm.prank(carol);
        pm.bet(id, FRIENDLY_NO, 10_001);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);

        // Treasury can immediately claim fee = 100. Dust = 0 at this point.
        assertEq(pm.getPendingClaim(id, treasury), 100);
        vm.prank(treasury);
        pm.claim(id);
        assertEq(usdc.balanceOf(treasury), 100);

        // Each winner claims 10_000 (principal) + 4_950 (truncated share) = 14_950.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pm.claim(id);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 14_950);
        // After alice: residue numerator = 10_000, dust = 0.
        assertEq(pm.getPendingClaim(id, treasury), 0);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pm.claim(id);
        assertEq(usdc.balanceOf(bob) - bobBefore, 14_950);
        // After bob: cumulative numerator = 20_000 == winnerPool → 1 base unit dust.
        assertEq(pm.getPendingClaim(id, treasury), 1);

        // Treasury second sweep pulls exactly 1.
        uint256 treasBefore = usdc.balanceOf(treasury);
        vm.prank(treasury);
        pm.claim(id);
        assertEq(usdc.balanceOf(treasury) - treasBefore, 1);
        // No third claim — counter caught up to total available.
        vm.prank(treasury);
        vm.expectRevert(MakoPrivateMarketsV1.NothingToClaim.selector);
        pm.claim(id);
    }

    /// MAJOR: treasury claim progresses through fee → dust as winners claim.
    /// Same setup as the deterministic dust test above but exercises the
    /// alternative ordering: treasury claims AFTER winners. Should produce
    /// fee + dust in one shot.
    function test_friendly_treasuryClaimAfterWinnersGetsFeePlusDust() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 10_000);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_YES, 10_000);
        vm.prank(carol);
        pm.bet(id, FRIENDLY_NO, 10_001);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);

        vm.prank(alice);
        pm.claim(id);
        vm.prank(bob);
        pm.claim(id);
        // Both winners settled → m.dust = 1.
        assertEq(pm.getPendingClaim(id, treasury), 101); // 100 fee + 1 dust
        vm.prank(treasury);
        pm.claim(id);
        assertEq(usdc.balanceOf(treasury), 101);
    }

    /// MAJOR: tie-break sequence view exposed for indexer mirror.
    function test_view_getOptionFirstStakeSequence() public {
        uint256 id = _createOpenVote(10e6, 1);
        vm.prank(alice); // option 2 first
        pm.stake(id, 2, 10e6);
        vm.prank(bob); // option 0 second
        pm.stake(id, 0, 10e6);
        (uint16 seq2, bool set2) = pm.getOptionFirstStakeSequence(id, 2);
        (uint16 seq0, bool set0) = pm.getOptionFirstStakeSequence(id, 0);
        (uint16 seq1, bool set1) = pm.getOptionFirstStakeSequence(id, 1);
        assertTrue(set2);
        assertTrue(set0);
        assertFalse(set1);
        assertEq(seq2, 1);
        assertEq(seq0, 2);
        assertEq(seq1, 0);
    }

    /// MINOR 1 regression: Friendlies must reject perWalletCumulativeMax.
    function test_create_friendlyPerWalletCumulativeMaxReverts() public {
        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 hours));
        p.perWalletCumulativeMax = 100e6;
        vm.prank(creator);
        vm.expectRevert(MakoPrivateMarketsV1.InvalidStakeBounds.selector);
        pm.createMarket(p);
    }

    /// MINOR 2: treasury cannot stake on Open Vote.
    function test_treasury_cannotStakeOpenVote() public {
        uint256 id = _createOpenVote(1e6, 2);
        usdc.mint(treasury, 100e6);
        vm.prank(treasury);
        usdc.approve(address(pm), type(uint256).max);
        vm.prank(treasury);
        vm.expectRevert(MakoPrivateMarketsV1.TreasuryNotAllowed.selector);
        pm.stake(id, 0, 1e6);
    }

    /// MINOR 2: treasury cannot stake on Prize Pool.
    function test_treasury_cannotStakePrizePool() public {
        address[] memory wallets = new address[](2);
        wallets[0] = alice;
        wallets[1] = bob;
        uint256 id = _createPrizePool(wallets, 1);
        usdc.mint(treasury, 100e6);
        vm.prank(treasury);
        usdc.approve(address(pm), type(uint256).max);
        vm.prank(treasury);
        vm.expectRevert(MakoPrivateMarketsV1.TreasuryNotAllowed.selector);
        pm.stake(id, 0, 1e6);
    }

    /// MINOR 2: Staked event payload matches (marketId, staker, optionIndex,
    /// amount, timestamp).
    event Staked(
        uint256 indexed marketId, address indexed staker, uint256 optionIndex, uint256 amount, uint256 timestamp
    );

    function test_event_stakedPayload() public {
        uint256 id = _createFriendly();
        vm.expectEmit(true, true, false, true);
        emit Staked(id, alice, FRIENDLY_YES, 1e6, block.timestamp);
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
    }

    /// MINOR 2: ResolvedFriendly event payload (outcome, emptyPoolPath, fee, totalOwed).
    event ResolvedFriendly(
        uint256 indexed marketId, uint8 outcome, bool emptyPoolPath, uint256 feeTaken, uint256 totalOwed
    );

    function test_event_resolvedFriendlyPayload() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 100e6);
        vm.prank(bob);
        pm.bet(id, FRIENDLY_NO, 200e6);
        vm.warp(block.timestamp + 1 days);
        // fee = 200 * 1% = 2; totalOwed = 100 + 198 = 298
        vm.expectEmit(true, false, false, true);
        emit ResolvedFriendly(id, FRIENDLY_YES, false, 2e6, 298e6);
        vm.prank(creator);
        pm.resolve(id, FRIENDLY_YES);
    }

    /// MINOR 2: Claimed event payload.
    event Claimed(uint256 indexed marketId, address indexed recipient, uint256 amount);

    function test_event_claimedPayload() public {
        uint256 id = _createFriendly();
        vm.prank(alice);
        pm.bet(id, FRIENDLY_YES, 1e6);
        vm.warp(block.timestamp + 1 days + 7 days);
        vm.expectEmit(true, true, false, true);
        emit Claimed(id, alice, 1e6);
        vm.prank(alice);
        pm.claim(id);
    }

    /// MINOR 3: ResolvedOpenVote event payload (topN array, feeTaken).
    event ResolvedOpenVote(uint256 indexed marketId, uint256[] topN, uint256 feeTaken);

    function test_event_resolvedOpenVotePayload() public {
        uint256 id = _createOpenVote(10e6, 2);
        vm.prank(alice);
        pm.stake(id, 0, 10e6);
        vm.prank(bob);
        pm.stake(id, 1, 10e6);
        vm.prank(carol);
        pm.stake(id, 0, 10e6);
        vm.warp(block.timestamp + 1 days);
        // 3 voters * 10 USDC * 1% per voter = 300_000 base units fee.
        uint256[] memory expectedTopN = new uint256[](2);
        expectedTopN[0] = 0;
        expectedTopN[1] = 1;
        vm.expectEmit(true, false, false, true);
        emit ResolvedOpenVote(id, expectedTopN, 300_000);
        vm.prank(creator);
        pm.confirm(id);
    }

    /// MINOR 3: DistributedPrizePool event payload (topN, winners, amounts, fee).
    event DistributedPrizePool(
        uint256 indexed marketId, uint256[] topN, address[] winnerWallets, uint256[] amountsOwed, uint256 feeTaken
    );

    function test_event_distributedPrizePoolPayload() public {
        address[] memory wallets = new address[](3);
        wallets[0] = address(0xA1);
        wallets[1] = address(0xA2);
        wallets[2] = address(0xA3);
        uint256 id = _createPrizePool(wallets, 2);
        vm.prank(alice);
        pm.stake(id, 0, 200e6);
        vm.prank(bob);
        pm.stake(id, 1, 100e6);
        vm.prank(carol);
        pm.stake(id, 2, 50e6);
        vm.warp(block.timestamp + 1 days);
        // total = 350; fee = 350 * 1% = 3_500_000; distributable = 346_500_000
        // top2 sum = 300; option 0 owed = 346.5 * 200/300 = 231 → 231_000_000
        // option 1 owed = 346.5 * 100/300 = 115.5 → 115_500_000
        uint256[] memory expectedTopN = new uint256[](2);
        expectedTopN[0] = 0;
        expectedTopN[1] = 1;
        address[] memory expectedWinners = new address[](2);
        expectedWinners[0] = address(0xA1);
        expectedWinners[1] = address(0xA2);
        uint256[] memory expectedAmounts = new uint256[](2);
        expectedAmounts[0] = 231_000_000;
        expectedAmounts[1] = 115_500_000;
        vm.expectEmit(true, false, false, true);
        emit DistributedPrizePool(id, expectedTopN, expectedWinners, expectedAmounts, 3_500_000);
        vm.prank(creator);
        pm.distribute(id);
    }

    /// MINOR 2: USDC transfer-revert preserves unclaimed state — failed claim
    /// must NOT mutate userClaimed or feeAndDustClaimed; recipient can retry.
    function test_claim_transferFailureRollsBackUserClaimed() public {
        FlakyUSDC flaky = new FlakyUSDC();
        MakoPrivateMarketsV1 fpm = new MakoPrivateMarketsV1(address(flaky), treasury);
        flaky.mint(alice, 100e6);
        flaky.mint(bob, 100e6);
        vm.prank(alice);
        flaky.approve(address(fpm), type(uint256).max);
        vm.prank(bob);
        flaky.approve(address(fpm), type(uint256).max);

        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 days));
        vm.prank(creator);
        uint256 id = fpm.createMarket(p);
        vm.prank(alice);
        fpm.bet(id, FRIENDLY_YES, 10e6);
        vm.prank(bob);
        fpm.bet(id, FRIENDLY_NO, 10e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        fpm.resolve(id, FRIENDLY_YES);

        flaky.setTransferShouldRevert(true);
        vm.prank(alice);
        vm.expectRevert();
        fpm.claim(id);
        // userClaimed must remain false so retry is possible.
        assertFalse(fpm.userClaimed(id, alice));

        flaky.setTransferShouldRevert(false);
        // Retry succeeds and consumes the slot.
        vm.prank(alice);
        fpm.claim(id);
        assertTrue(fpm.userClaimed(id, alice));
    }

    /// MINOR 2: Treasury claim transfer-revert preserves feeAndDustClaimed.
    function test_claim_transferFailureRollsBackTreasuryCounter() public {
        FlakyUSDC flaky = new FlakyUSDC();
        MakoPrivateMarketsV1 fpm = new MakoPrivateMarketsV1(address(flaky), treasury);
        flaky.mint(alice, 100e6);
        flaky.mint(bob, 100e6);
        vm.prank(alice);
        flaky.approve(address(fpm), type(uint256).max);
        vm.prank(bob);
        flaky.approve(address(fpm), type(uint256).max);

        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 days));
        vm.prank(creator);
        uint256 id = fpm.createMarket(p);
        vm.prank(alice);
        fpm.bet(id, FRIENDLY_YES, 10e6);
        vm.prank(bob);
        fpm.bet(id, FRIENDLY_NO, 10e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        fpm.resolve(id, FRIENDLY_YES);

        flaky.setTransferShouldRevert(true);
        vm.prank(treasury);
        vm.expectRevert();
        fpm.claim(id);
        assertEq(fpm.feeAndDustClaimed(id), 0);

        flaky.setTransferShouldRevert(false);
        vm.prank(treasury);
        fpm.claim(id);
        assertEq(fpm.feeAndDustClaimed(id), 100_000); // 1% of 10e6 loser pool
    }

    // =================================================================
    // Group 14 — Round-3 follow-up: USDC safety guards
    // =================================================================

    function test_constructor_zeroUsdcReverts() public {
        vm.expectRevert(MakoPrivateMarketsV1.ZeroAddress.selector);
        new MakoPrivateMarketsV1(address(0), treasury);
    }

    function test_constructor_zeroTreasuryReverts() public {
        MockUSDC u = new MockUSDC();
        vm.expectRevert(MakoPrivateMarketsV1.ZeroAddress.selector);
        new MakoPrivateMarketsV1(address(u), address(0));
    }

    function test_constructor_wrongDecimalsReverts() public {
        WrongDecimalsToken wrong = new WrongDecimalsToken(18);
        vm.expectRevert(MakoPrivateMarketsV1.BadDecimals.selector);
        new MakoPrivateMarketsV1(address(wrong), treasury);
    }

    function test_constructor_decimalsExactlySixOk() public {
        WrongDecimalsToken six = new WrongDecimalsToken(6);
        // Should not revert even with the otherwise-degenerate mock.
        new MakoPrivateMarketsV1(address(six), treasury);
    }

    function test_stake_feeOnTransferReverts() public {
        FeeOnTransferUSDC fot = new FeeOnTransferUSDC();
        MakoPrivateMarketsV1 fpm = new MakoPrivateMarketsV1(address(fot), treasury);
        fot.mint(alice, 100e6);
        vm.prank(alice);
        fot.approve(address(fpm), type(uint256).max);

        MakoPrivateMarketsV1.CreateParams memory p =
            _friendlyParams(uint64(block.timestamp), uint64(block.timestamp + 1 days));
        vm.prank(creator);
        uint256 id = fpm.createMarket(p);
        vm.prank(alice);
        vm.expectRevert(MakoPrivateMarketsV1.TransferAmountMismatch.selector);
        fpm.bet(id, FRIENDLY_YES, 1e6);
    }

    function test_openVoteStake_feeOnTransferReverts() public {
        FeeOnTransferUSDC fot = new FeeOnTransferUSDC();
        MakoPrivateMarketsV1 fpm = new MakoPrivateMarketsV1(address(fot), treasury);
        fot.mint(alice, 100e6);
        vm.prank(alice);
        fot.approve(address(fpm), type(uint256).max);

        MakoPrivateMarketsV1.CreateParams memory p =
            _openVoteParams(uint64(block.timestamp), uint64(block.timestamp + 1 days), 1e6, 2);
        vm.prank(creator);
        uint256 id = fpm.createMarket(p);
        vm.prank(alice);
        vm.expectRevert(MakoPrivateMarketsV1.TransferAmountMismatch.selector);
        fpm.stake(id, 0, 1e6);
    }

    /// MINOR 2: Prize Pool 50-option Cancel-claim gas. Sums all 50 per-wallet
    /// stake slots; bound by O(MAX_OPTIONS).
    function test_gas_prizePoolCancelClaim50Options() public {
        address[] memory wallets = new address[](50);
        for (uint256 i = 0; i < 50; i++) {
            wallets[i] = address(uint160(0x100 + i));
        }
        uint256 id = _createPrizePool(wallets, 5);
        // alice stakes on every option
        for (uint256 i = 0; i < 50; i++) {
            vm.prank(alice);
            pm.stake(id, i, 1e6);
        }
        vm.warp(block.timestamp + 1 days);
        vm.prank(creator);
        pm.cancel(id);
        uint256 g0 = gasleft();
        vm.prank(alice);
        pm.claim(id);
        uint256 used = g0 - gasleft();
        assertLt(used, 600_000);
    }
}
