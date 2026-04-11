// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MakoMarkets — short-form parimutuel prediction markets
/// @notice YES/NO pools. Market types: FOOTBALL, CRYPTO, ADHOC. Fees split to creator + treasury.
contract MakoMarkets {
    enum MarketType {
        FOOTBALL,
        CRYPTO,
        ADHOC
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

    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(address => uint256)) public yesBets;
    mapping(uint256 => mapping(address => uint256)) public noBets;
    mapping(uint256 => mapping(address => bool)) public claimed;

    uint256 public nextMarketId;
    address public owner;
    address public resolver;
    address public treasury;
    uint256 public treasuryBalance;

    uint16 public protocolFeeBps = 200; // 2%
    uint16 public creatorFeeBps = 100; // 1%
    uint16 public constant MAX_TOTAL_FEE_BPS = 500;
    uint256 public constant MIN_BET = 0.001 ether;
    uint256 public constant MAX_DURATION = 7 days;
    uint256 public constant RESOLUTION_GRACE = 24 hours; // anyone can forceRefund after closeTime + this
    uint256 public constant MIN_RATIO_FLOOR_BPS = 100; // hard floor under the dynamic threshold

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
    error TransferFailed();
    error BadCloseTime();
    error BadQuestion();
    error FeesTooHigh();
    error NotAuthorized();
    error ZeroAddress();
    error StillInGrace();

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

    constructor(address _treasury) {
        if (_treasury == address(0)) revert ZeroAddress();
        owner = msg.sender;
        resolver = msg.sender;
        treasury = _treasury;
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

    function placeBet(uint256 id, bool isYes) external payable nonReentrant {
        Market storage m = markets[id];
        if (m.closeTime == 0) revert MarketMissing();
        if (block.timestamp >= m.closeTime) revert MarketClosed();
        if (m.resolved) revert AlreadyResolved();
        if (msg.value < MIN_BET) revert BelowMin();

        if (isYes) {
            if (yesBets[id][msg.sender] == 0) m.yesBettorCount++;
            yesBets[id][msg.sender] += msg.value;
            m.totalYes += msg.value;
        } else {
            if (noBets[id][msg.sender] == 0) m.noBettorCount++;
            noBets[id][msg.sender] += msg.value;
            m.totalNo += msg.value;
        }

        emit BetPlaced(id, msg.sender, isYes, msg.value);
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
        // creator-fee payout. See minLiquidityRatioBps() — 2x break-even as safety margin,
        // floored at MIN_RATIO_FLOOR_BPS.
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
    /// @dev Protects bettors from abandoned resolvers or unresolvable oracleRef values.
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
        (bool ok,) = msg.sender.call{value: payout}("");
        if (!ok) revert TransferFailed();
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

        (bool ok,) = msg.sender.call{value: fee}("");
        if (!ok) revert TransferFailed();
        emit CreatorFeePaid(id, msg.sender, fee);
    }

    function withdrawTreasury() external nonReentrant {
        if (msg.sender != treasury && msg.sender != owner) revert NotAuthorized();
        uint256 bal = treasuryBalance;
        treasuryBalance = 0;
        (bool ok,) = treasury.call{value: bal}("");
        if (!ok) revert TransferFailed();
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
    /// @dev Dynamically tracks creatorFeeBps. Anything at-or-below the break-even ratio
    ///      `creatorFeeBps / (10000 - creatorFeeBps)` would let a creator-attacker self-dust-bet
    ///      the losing side for positive net via claimCreatorFee. We use 2x break-even as a
    ///      safety margin, floored at MIN_RATIO_FLOOR_BPS so zero-creator-fee markets still
    ///      reject truly dust-thin counterparties.
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

    receive() external payable {}
}
