// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MakoMarketsV4 — short-form parimutuel prediction markets, USDC-denominated
/// @notice Port of MakoMarkets.sol from native MON to ERC-20 USDC.
///         Bets, payouts, creator fees, and treasury are all denominated in USDC (6 decimals).
/// @dev Differences from v3:
///      - placeBet takes an `amount` argument (not msg.value); contract calls
///        safeTransferFrom on the provided USDC token.
///      - claim, claimCreatorFee, withdrawTreasury use safeTransfer (not native call).
///      - Constructor takes the USDC token address (varies per chain).
///      - No `payable` anywhere; no `receive()`. Any native value sent is lost.
///      - MIN_BET in USDC base units (6 decimals); 1_000_000 = 1 USDC.
///
///      Inline IERC20 + SafeERC20 used to keep this contract self-contained.
///      Auditor may recommend swapping to OpenZeppelin's SafeERC20 — both are
///      functionally equivalent for well-behaved tokens like USDC.

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @dev Minimal SafeERC20: wraps low-level calls and reverts on failure or false return.
///      Handles tokens that return no value (legacy ERC20s) AND tokens that return bool.
library SafeERC20Min {
    error ERC20TransferFailed();
    error ERC20TransferFromFailed();

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert ERC20TransferFailed();
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert ERC20TransferFromFailed();
    }
}

contract MakoMarketsV4 {
    using SafeERC20Min for IERC20;

    enum MarketType {
        FOOTBALL,
        CRYPTO,
        BASKETBALL
    }
    enum Outcome {
        UNRESOLVED,
        YES,
        NO,
        REFUND
    }

    struct Market {
        address creator;
        MarketType mType;
        bytes32 oracleRef;
        string question;
        uint64 createdAt;
        uint64 closeTime;
        uint256 totalYes;
        uint256 totalNo;
        uint32 yesBettorCount;
        uint32 noBettorCount;
        Outcome outcome;
        bool resolved;
        bool creatorFeeClaimed;
    }

    /// @notice The USDC (or USDC-compatible) ERC-20 token contract used for all bets and payouts.
    /// @dev Set once at construction; immutable to make state irrelevant to upgrades / re-orgs.
    IERC20 public immutable usdc;

    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(address => uint256)) public yesBets;
    mapping(uint256 => mapping(address => uint256)) public noBets;
    mapping(uint256 => mapping(address => bool)) public claimed;

    uint256 public nextMarketId;
    address public owner;
    address public resolver;
    address public treasury;
    uint256 public treasuryBalance;

    uint16 public protocolFeeBps = 100; // 1%
    uint16 public creatorFeeBps = 200; // 2%
    uint16 public constant MAX_TOTAL_FEE_BPS = 500;
    /// @notice Minimum bet amount in USDC base units (6 decimals). 1_000_000 = 1.00 USDC.
    uint256 public constant MIN_BET = 1_000_000;
    uint256 public constant MAX_DURATION = 7 days;
    uint256 public constant RESOLUTION_GRACE = 24 hours;
    uint256 public constant MIN_RATIO_FLOOR_BPS = 100;

    uint256 private _locked;

    event MarketCreated(
        uint256 indexed id,
        address indexed creator,
        MarketType mType,
        bytes32 oracleRef,
        uint64 closeTime,
        string question
    );
    event BetPlaced(uint256 indexed id, address indexed user, bool isYes, uint256 amount);
    event MarketResolved(uint256 indexed id, Outcome outcome);
    event Claimed(uint256 indexed id, address indexed user, uint256 amount);
    event CreatorFeePaid(uint256 indexed id, address indexed creator, uint256 amount);
    event TreasuryWithdrawn(uint256 amount);

    error NotOwner();
    error NotResolver();
    error Reentrancy();
    error MarketMissing();
    error MarketClosed();
    error MarketNotClosed();
    error AlreadyResolved();
    error NotResolved();
    error BadOutcome();
    error BelowMin();
    error AlreadyClaimed();
    error NoPosition();
    error BadCloseTime();
    error BadQuestion();
    error FeesTooHigh();
    error NotAuthorized();
    error ZeroAddress();
    error StillInGrace();
    /// @dev USDC has 6 decimals. MIN_BET and every payout path assume it. If a
    ///      token with a different decimal width is wired in at construction,
    ///      reject up front so the mistake surfaces at deploy rather than
    ///      silently producing 12- or 18-decimal accounting in storage.
    error BadDecimals();
    /// @dev Inbound balance delta on `placeBet` did not equal `amount`. Happens
    ///      with fee-on-transfer or deflationary ERC-20s. Canonical USDC never
    ///      hits this path; it's a defensive guard against a misconfigured
    ///      `_usdc` address.
    error TransferAmountMismatch();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    modifier onlyResolver() {
        if (msg.sender != resolver && msg.sender != owner) revert NotResolver();
        _;
    }
    modifier nonReentrant() {
        if (_locked == 1) revert Reentrancy();
        _locked = 1;
        _;
        _locked = 0;
    }

    /// @param _treasury Address that receives protocol-fee withdrawals.
    /// @param _usdc     USDC (or USDC-compatible ERC-20) token address. Differs per chain:
    ///                  Monad mainnet: 0x754704Bc059F8C67012fEd69BC8A327a5aafb603
    ///                  Monad testnet: 0x534b2f3A21130d7a60830c2Df862319e593943A3
    constructor(address _treasury, address _usdc) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        // Pin to USDC's canonical 6-decimal layout. MIN_BET and every payout
        // path depend on this. A misconfigured token address (e.g. an 18-decimal
        // stablecoin) would silently produce mis-scaled accounting in storage.
        if (IERC20(_usdc).decimals() != 6) revert BadDecimals();
        owner = msg.sender;
        resolver = msg.sender;
        treasury = _treasury;
        usdc = IERC20(_usdc);
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    function createMarket(MarketType mType, bytes32 oracleRef, uint64 closeTime, string calldata question)
        external
        returns (uint256 id)
    {
        if (closeTime <= block.timestamp) revert BadCloseTime();
        if (closeTime > block.timestamp + MAX_DURATION) revert BadCloseTime();
        uint256 qLen = bytes(question).length;
        if (qLen == 0 || qLen > 200) revert BadQuestion();

        id = nextMarketId++;
        Market storage m = markets[id];
        m.creator = msg.sender;
        m.mType = mType;
        m.oracleRef = oracleRef;
        m.question = question;
        m.createdAt = uint64(block.timestamp);
        m.closeTime = closeTime;

        emit MarketCreated(id, msg.sender, mType, oracleRef, closeTime, question);
    }

    /// @notice Place a bet by transferring `amount` USDC from msg.sender to this contract.
    /// @dev    msg.sender must have approved this contract to spend `amount` USDC beforehand.
    ///         When called via ERC-4337 user op batching, the approve + placeBet calls are
    ///         bundled atomically so the user signs once.
    function placeBet(uint256 id, bool isYes, uint256 amount) external nonReentrant {
        Market storage m = markets[id];
        if (m.closeTime == 0) revert MarketMissing();
        if (block.timestamp >= m.closeTime) revert MarketClosed();
        if (m.resolved) revert AlreadyResolved();
        if (amount < MIN_BET) revert BelowMin();

        // Balance-delta guard: pull USDC from the bettor and confirm we received
        // exactly `amount`. Canonical USDC is not fee-on-transfer so this is
        // always satisfied in practice, but a misconfigured `_usdc` address
        // pointing at a deflationary token would otherwise desync the recorded
        // pool from the claimable balance. Revert rather than credit accounting
        // that doesn't match reality.
        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = usdc.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TransferAmountMismatch();

        if (isYes) {
            if (yesBets[id][msg.sender] == 0) m.yesBettorCount++;
            yesBets[id][msg.sender] += amount;
            m.totalYes += amount;
        } else {
            if (noBets[id][msg.sender] == 0) m.noBettorCount++;
            noBets[id][msg.sender] += amount;
            m.totalNo += amount;
        }

        emit BetPlaced(id, msg.sender, isYes, amount);
    }

    function resolveMarket(uint256 id, Outcome outcome) external onlyResolver {
        Market storage m = markets[id];
        if (m.closeTime == 0) revert MarketMissing();
        if (m.resolved) revert AlreadyResolved();
        if (block.timestamp < m.closeTime) revert MarketNotClosed();
        if (outcome == Outcome.UNRESOLVED) revert BadOutcome();

        // Force refund if the pool is too one-sided to settle honestly.
        // The threshold is DYNAMIC — it must strictly dominate the creator-fee break-even
        // so a creator cannot profit from self-dust-betting the losing side to unlock the
        // creator-fee payout. See minLiquidityRatioBps() for derivation.
        uint256 minSide = m.totalYes < m.totalNo ? m.totalYes : m.totalNo;
        uint256 maxSide = m.totalYes < m.totalNo ? m.totalNo : m.totalYes;
        uint256 minRatio = minLiquidityRatioBps();
        if (minSide * 10000 < maxSide * minRatio) {
            outcome = Outcome.REFUND;
        }

        m.outcome = outcome;
        m.resolved = true;

        if (outcome != Outcome.REFUND) {
            uint256 totalPool = m.totalYes + m.totalNo;
            treasuryBalance += (totalPool * protocolFeeBps) / 10000;
        }

        emit MarketResolved(id, outcome);
    }

    /// @notice Safety valve: anyone can force REFUND on a stuck market after the grace period.
    function forceRefund(uint256 id) external {
        Market storage m = markets[id];
        if (m.closeTime == 0) revert MarketMissing();
        if (m.resolved) revert AlreadyResolved();
        if (block.timestamp < m.closeTime + RESOLUTION_GRACE) revert StillInGrace();

        m.outcome = Outcome.REFUND;
        m.resolved = true;
        emit MarketResolved(id, Outcome.REFUND);
    }

    function claim(uint256 id) external nonReentrant {
        Market storage m = markets[id];
        if (!m.resolved) revert NotResolved();
        if (claimed[id][msg.sender]) revert AlreadyClaimed();

        uint256 payout;
        if (m.outcome == Outcome.REFUND) {
            payout = yesBets[id][msg.sender] + noBets[id][msg.sender];
            if (payout == 0) revert NoPosition();
        } else if (m.outcome == Outcome.YES) {
            uint256 userBet = yesBets[id][msg.sender];
            if (userBet == 0) revert NoPosition();
            payout = _calcPayout(m.totalYes, m.totalNo, userBet);
        } else if (m.outcome == Outcome.NO) {
            uint256 userBet = noBets[id][msg.sender];
            if (userBet == 0) revert NoPosition();
            payout = _calcPayout(m.totalNo, m.totalYes, userBet);
        } else {
            revert BadOutcome();
        }

        claimed[id][msg.sender] = true;
        usdc.safeTransfer(msg.sender, payout);
        emit Claimed(id, msg.sender, payout);
    }

    function claimCreatorFee(uint256 id) external nonReentrant {
        Market storage m = markets[id];
        if (!m.resolved) revert NotResolved();
        if (msg.sender != m.creator) revert NotAuthorized();
        if (m.creatorFeeClaimed) revert AlreadyClaimed();
        if (m.outcome == Outcome.REFUND) revert BadOutcome();

        m.creatorFeeClaimed = true;
        uint256 totalPool = m.totalYes + m.totalNo;
        uint256 fee = (totalPool * creatorFeeBps) / 10000;

        usdc.safeTransfer(msg.sender, fee);
        emit CreatorFeePaid(id, msg.sender, fee);
    }

    function withdrawTreasury() external nonReentrant {
        if (msg.sender != treasury && msg.sender != owner) revert NotAuthorized();
        uint256 bal = treasuryBalance;
        treasuryBalance = 0;
        usdc.safeTransfer(treasury, bal);
        emit TreasuryWithdrawn(bal);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function getMarket(uint256 id) external view returns (Market memory) {
        return markets[id];
    }

    function getUserBet(uint256 id, address user) external view returns (uint256 yes, uint256 no, bool hasClaimed) {
        return (yesBets[id][user], noBets[id][user], claimed[id][user]);
    }

    /// @notice Live payout preview for the bet sheet. Accounts for the new bet entering the pool.
    function previewPayout(uint256 id, bool isYes, uint256 betAmount) external view returns (uint256) {
        if (betAmount == 0) return 0;
        Market storage m = markets[id];
        uint256 newYes = m.totalYes + (isYes ? betAmount : 0);
        uint256 newNo = m.totalNo + (isYes ? 0 : betAmount);
        uint256 winnerPool = isYes ? newYes : newNo;
        uint256 loserPool = isYes ? newNo : newYes;
        if (loserPool == 0) return betAmount; // would refund
        uint256 totalPool = winnerPool + loserPool;
        uint256 feeBps = protocolFeeBps + creatorFeeBps;
        uint256 payoutPool = totalPool - (totalPool * feeBps / 10000);
        return (betAmount * payoutPool) / winnerPool;
    }

    /// @notice Current live multiplier for a side, scaled by 1e18. UI: divide by 1e18.
    function multiplier(uint256 id, bool isYes) external view returns (uint256) {
        Market storage m = markets[id];
        uint256 winnerPool = isYes ? m.totalYes : m.totalNo;
        if (winnerPool == 0) return 0;
        uint256 totalPool = m.totalYes + m.totalNo;
        uint256 feeBps = protocolFeeBps + creatorFeeBps;
        uint256 payoutPool = totalPool - (totalPool * feeBps / 10000);
        return (payoutPool * 1e18) / winnerPool;
    }

    /// @notice Minimum smaller-side / larger-side ratio (in bps) required for non-refund settlement.
    /// @dev Dynamically tracks creatorFeeBps. See v3 for full derivation; same logic preserved.
    function minLiquidityRatioBps() public view returns (uint256) {
        uint256 cBps = uint256(creatorFeeBps);
        if (cBps == 0) return MIN_RATIO_FLOOR_BPS;
        uint256 breakevenBps = (10000 * cBps) / (10000 - cBps);
        uint256 safeBps = 2 * breakevenBps;
        return safeBps > MIN_RATIO_FLOOR_BPS ? safeBps : MIN_RATIO_FLOOR_BPS;
    }

    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------

    function setResolver(address r) external onlyOwner {
        resolver = r;
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
    }

    function setFees(uint16 _protocolBps, uint16 _creatorBps) external onlyOwner {
        if (_protocolBps + _creatorBps > MAX_TOTAL_FEE_BPS) revert FeesTooHigh();
        protocolFeeBps = _protocolBps;
        creatorFeeBps = _creatorBps;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    function _calcPayout(uint256 winnerPool, uint256 loserPool, uint256 userBet) internal view returns (uint256) {
        uint256 totalPool = winnerPool + loserPool;
        uint256 feeBps = protocolFeeBps + creatorFeeBps;
        uint256 payoutPool = totalPool - (totalPool * feeBps / 10000);
        return (userBet * payoutPool) / winnerPool;
    }

    // No receive() / fallback() — this contract holds USDC only, never native value.
    // Any native MON/ETH sent to this address is unrecoverable.
}
