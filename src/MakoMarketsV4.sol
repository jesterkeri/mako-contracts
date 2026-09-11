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
        /// @dev Moment after which `placeBet` reverts. Derived at
        ///      `createMarket` time from market type + duration (see
        ///      `_computeBettingCloseTime`). Always <= closeTime. For
        ///      sports, equals closeTime (creator sets closeTime = kickoff).
        ///      For crypto, earlier than closeTime (50%–85% of duration)
        ///      so betting stops before the evaluation moment — this is
        ///      what prevents late bettors from exploiting a clearly-
        ///      decided outcome window.
        uint64 bettingCloseTime;
        uint256 totalYes;
        uint256 totalNo;
        uint32 yesBettorCount;
        uint32 noBettorCount;
        Outcome outcome;
        bool resolved;
        bool creatorFeeClaimed;
        /// @dev Fee bps frozen at `createMarket` time. Every math path that
        ///      splits the pool (payout, creator fee, treasury accrual,
        ///      preview, multiplier) reads these — not the live globals.
        ///      `setFees` therefore only affects markets created AFTER the
        ///      change, never existing ones. This is what keeps a single
        ///      contract USDC balance from being double-spent across
        ///      markets when an owner tweaks fees between bet and claim.
        uint16 protocolFeeBpsSnapshot;
        uint16 creatorFeeBpsSnapshot;
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
    uint256 public constant MIN_DURATION = 5 minutes;
    uint256 public constant RESOLUTION_GRACE = 24 hours;
    uint256 public constant MIN_RATIO_FLOOR_BPS = 100;
    /// @notice Fixed cooldown between successive bets by the same wallet on
    ///         the same market. Kills burst-betting + rate-based
    ///         manipulation patterns. Constant rather than admin-tunable to
    ///         keep the per-bet gas predictable.
    uint64 public constant MIN_SECONDS_BETWEEN_BETS = 30;

    // -----------------------------------------------------------------------
    // Per-wallet / anti-abuse caps (admin-tunable; see `setStage*` helpers)
    // -----------------------------------------------------------------------

    /// @notice Maximum share (in bps) of the post-bet pool that any single
    ///         wallet may hold. Default 2000 (20%). Enforced only once the
    ///         pool grows past `shareCapMinPool` so that early-stage seeding
    ///         bets aren't blocked by the check.
    uint16 public maxWalletShareBps = 2000;
    /// @notice Pool size (USDC base units) below which the share cap is not
    ///         enforced. Default 200 USDC. Rationale: in the first few
    ///         bets, a single wallet IS most of the pool by definition.
    uint256 public shareCapMinPool = 200 * MIN_BET;
    /// @notice Maximum total USDC a wallet can bet across BOTH sides of a
    ///         single market. Default 10,000 USDC (permissive); admin
    ///         tightens for beta/production stages via setMaxBetPerWallet.
    uint256 public maxBetPerWalletPerMarket = 10_000 * MIN_BET;
    /// @notice Wallets flagged by the admin as abusive. Their `placeBet`
    ///         calls revert on every market. Flag/unflag via setBlocked.
    ///         Existing bets are unaffected — only new placements are
    ///         rejected.
    mapping(address => bool) public blocked;
    /// @notice Last bet timestamp per (market, wallet). Used to enforce
    ///         MIN_SECONDS_BETWEEN_BETS.
    mapping(uint256 => mapping(address => uint64)) public lastBetTime;

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
    /// @param forgoneAmount The amount that would have been paid if the pool
    ///        had been balanced enough to unlock the fee. Indexers use this
    ///        to show "creator left money on the table" without having to
    ///        recompute from storage.
    event CreatorFeeForfeited(uint256 indexed id, address indexed creator, uint256 forgoneAmount);
    event TreasuryWithdrawn(uint256 amount);
    event FeesChanged(uint16 oldProtocolBps, uint16 oldCreatorBps, uint16 newProtocolBps, uint16 newCreatorBps);
    event ResolverChanged(address indexed oldResolver, address indexed newResolver);
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event MaxBetPerWalletChanged(uint256 oldValue, uint256 newValue);
    event MaxWalletShareBpsChanged(uint16 oldValue, uint16 newValue);
    event ShareCapMinPoolChanged(uint256 oldValue, uint256 newValue);
    event WalletBlockStatusChanged(address indexed wallet, bool isBlocked);

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
    error BettingClosed();
    error BadDuration();
    error WalletIsBlocked();
    error BetTooSoon();
    error WalletCapExceeded();
    error WalletShareCapExceeded();

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

    /// @notice Create a market.
    /// @param  mType             Market category (FOOTBALL / BASKETBALL / CRYPTO).
    /// @param  oracleRef         Off-chain identifier the resolver interprets.
    /// @param  bettingCloseTime_ Moment after which `placeBet` reverts. Must
    ///                           be in the future AND <= closeTime. For sports,
    ///                           creators are expected to set this to
    ///                           kickoff/tipoff; for crypto, creators are
    ///                           expected to set it significantly before
    ///                           closeTime (UI callers can default via the
    ///                           `suggestedBettingCloseTime` view below).
    /// @param  closeTime         Moment after which `resolveMarket` becomes
    ///                           legal. Represents the event end (sports) or
    ///                           the price evaluation point (crypto).
    /// @param  question          Human-readable question (1–200 chars).
    ///
    /// @dev The two-timestamp design is deliberate. A single closeTime
    ///      conflates "betting stops" with "resolution starts," which for
    ///      sports means either betting stays open through the match (stale-
    ///      market exploitation) or the resolver can resolve before the event
    ///      finishes (premature resolution). Neither is acceptable.
    function createMarket(
        MarketType mType,
        bytes32 oracleRef,
        uint64 bettingCloseTime_,
        uint64 closeTime,
        string calldata question
    ) external returns (uint256 id) {
        if (closeTime <= block.timestamp) revert BadCloseTime();
        if (bettingCloseTime_ <= block.timestamp) revert BadCloseTime();
        if (bettingCloseTime_ > closeTime) revert BadCloseTime();
        uint256 duration = closeTime - block.timestamp;
        if (duration < MIN_DURATION) revert BadDuration();
        if (duration > MAX_DURATION) revert BadCloseTime();
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
        m.bettingCloseTime = bettingCloseTime_;
        // Snapshot the economics. Any `setFees` after this point will NOT
        // retroactively change what this market pays out.
        m.protocolFeeBpsSnapshot = protocolFeeBps;
        m.creatorFeeBpsSnapshot = creatorFeeBps;

        emit MarketCreated(id, msg.sender, mType, oracleRef, closeTime, question);
    }

    /// @notice UI helper for CRYPTO markets only — returns a sensible default
    ///         `bettingCloseTime` based on a duration tier. Callers are NOT
    ///         required to use this value; it's a convenience so frontends
    ///         don't each reinvent the same rule.
    ///
    ///         Duration tiers: ≤ 1 hour → 50% of duration; ≤ 1 day → 60%;
    ///         ≤ 3 days → 70%; else 85%. Rationale: crypto outcomes build
    ///         progressively via price action, so cutting off betting at a
    ///         fraction of duration prevents late bettors from piling onto
    ///         already-decided outcomes.
    ///
    /// @dev    Deliberately scoped to CRYPTO. There is no safe generic
    ///         default for sports — a UI that wants a default for
    ///         FOOTBALL / BASKETBALL must use its own knowledge of the
    ///         event schedule (kickoff / tipoff). A generic helper that
    ///         returned `resolutionTime` for sports would let naive
    ///         integrators reintroduce the "no sports cutoff" bug by
    ///         trusting the helper blindly.
    function suggestedCryptoBettingCloseTime(uint64 createdAt, uint64 resolutionTime) external pure returns (uint64) {
        if (resolutionTime <= createdAt) return createdAt;
        uint64 duration = resolutionTime - createdAt;
        uint64 pct;
        if (duration <= 1 hours) pct = 50;
        else if (duration <= 1 days) pct = 60;
        else if (duration <= 3 days) pct = 70;
        else pct = 85;
        return createdAt + ((duration * pct) / 100);
    }

    /// @notice Place a bet by transferring `amount` USDC from msg.sender to this contract.
    /// @dev    msg.sender must have approved this contract to spend `amount` USDC beforehand.
    ///         When called via ERC-4337 user op batching, the approve + placeBet calls are
    ///         bundled atomically so the user signs once.
    function placeBet(uint256 id, bool isYes, uint256 amount) external nonReentrant {
        Market storage m = markets[id];
        if (m.closeTime == 0) revert MarketMissing();
        if (block.timestamp >= m.bettingCloseTime) revert BettingClosed();
        if (m.resolved) revert AlreadyResolved();
        if (amount < MIN_BET) revert BelowMin();

        // -------- anti-abuse gates (all checked before taking funds) --------

        // 1. Hard blocklist. Admin-flagged wallets are rejected from all markets.
        if (blocked[msg.sender]) revert WalletIsBlocked();

        // 2. Rate limit. Same wallet cannot bet twice on this market within
        //    MIN_SECONDS_BETWEEN_BETS seconds — kills burst-betting patterns.
        uint64 lastBet = lastBetTime[id][msg.sender];
        if (lastBet != 0 && uint64(block.timestamp) < lastBet + MIN_SECONDS_BETWEEN_BETS) {
            revert BetTooSoon();
        }

        // 3. Per-wallet absolute cap. Sum of this wallet's bets across both
        //    sides of this market must not exceed the admin-set ceiling.
        uint256 walletTotalAfter = yesBets[id][msg.sender] + noBets[id][msg.sender] + amount;
        if (walletTotalAfter > maxBetPerWalletPerMarket) revert WalletCapExceeded();

        // 4. Per-wallet pool-share cap. Once the pool is large enough for
        //    concentration to matter (post-bet pool >= shareCapMinPool),
        //    reject bets that would push this wallet above maxWalletShareBps
        //    of the post-bet pool. Seed-stage markets are exempt because
        //    any single bettor is necessarily 100% of a brand-new pool.
        uint256 newPool = m.totalYes + m.totalNo + amount;
        if (newPool >= shareCapMinPool) {
            // walletTotalAfter * 10000 > newPool * maxWalletShareBps
            if (walletTotalAfter * 10000 > newPool * uint256(maxWalletShareBps)) {
                revert WalletShareCapExceeded();
            }
        }

        lastBetTime[id][msg.sender] = uint64(block.timestamp);

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

        // Only auto-REFUND a truly one-sided pool. A pool with zero total on
        // the losing side can't settle normally: the winning side would dilute
        // itself via fees, and a wrong-outcome would strand funds in the
        // contract. Any non-zero losing side resolves YES/NO per the
        // resolver's call — griefers can't force a refund by stuffing the
        // winning side because imbalance no longer triggers refund.
        //
        // Creator-self-dust attack (the reason we used to refund on imbalance)
        // is defanged at `claimCreatorFee` time: the creator fee is gated on
        // the same liquidity-ratio threshold, so dusting the losing side to
        // unlock the fee now produces zero revenue.
        uint256 minSide = m.totalYes < m.totalNo ? m.totalYes : m.totalNo;
        if (minSide == 0) {
            outcome = Outcome.REFUND;
        }

        m.outcome = outcome;
        m.resolved = true;

        if (outcome != Outcome.REFUND) {
            uint256 totalPool = m.totalYes + m.totalNo;
            // Use the market's snapshotted protocol fee, not the global —
            // otherwise a `setFees` between bet and resolve would alter
            // treasury accrual for an existing market.
            treasuryBalance += (totalPool * m.protocolFeeBpsSnapshot) / 10000;
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
        } else if (m.outcome == Outcome.YES || m.outcome == Outcome.NO) {
            // If the creator fee was forfeited at this pool ratio, winners
            // split (totalPool - protocolFee) — NOT (totalPool - protocolFee
            // - creatorFee). Otherwise the creator's forgone slice would sit
            // stranded in the contract's pooled USDC and silently leak into
            // future markets' balances.
            uint16 effectiveCreatorFee = _isCreatorFeeForfeited(m.totalYes, m.totalNo, m.creatorFeeBpsSnapshot)
                ? uint16(0)
                : m.creatorFeeBpsSnapshot;

            if (m.outcome == Outcome.YES) {
                uint256 userBet = yesBets[id][msg.sender];
                if (userBet == 0) revert NoPosition();
                payout = _calcPayout(m.totalYes, m.totalNo, userBet, m.protocolFeeBpsSnapshot, effectiveCreatorFee);
            } else {
                uint256 userBet = noBets[id][msg.sender];
                if (userBet == 0) revert NoPosition();
                payout = _calcPayout(m.totalNo, m.totalYes, userBet, m.protocolFeeBpsSnapshot, effectiveCreatorFee);
            }
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
        uint256 fee = (totalPool * m.creatorFeeBpsSnapshot) / 10000;

        // Creator-fee threshold gate. If the pool was too one-sided at
        // resolution, the creator fee is forfeited — this is what makes the
        // creator-self-dust attack unprofitable, because the attacker's only
        // revenue path (this fee) evaporates once the pool is skewed enough
        // for the attack to actually change the outcome.
        //
        // The forgone amount isn't silently retained: `claim()` uses the same
        // forfeit check and pays winners a larger share (excluding creator
        // fee from payout math) when this path fires, so total out = total in.
        if (_isCreatorFeeForfeited(m.totalYes, m.totalNo, m.creatorFeeBpsSnapshot)) {
            emit CreatorFeeForfeited(id, msg.sender, fee);
            return;
        }

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
    /// @dev Uses the market's snapshotted fees, and applies the same
    ///      creator-fee-forfeit threshold rule `claim()` does on the
    ///      POST-bet pool. If this bet would push the pool below threshold,
    ///      the creator fee drops out of the payout math — preview and
    ///      claim always agree for a given pool state.
    function previewPayout(uint256 id, bool isYes, uint256 betAmount) external view returns (uint256) {
        if (betAmount == 0) return 0;
        Market storage m = markets[id];
        uint256 newYes = m.totalYes + (isYes ? betAmount : 0);
        uint256 newNo = m.totalNo + (isYes ? 0 : betAmount);
        uint256 winnerPool = isYes ? newYes : newNo;
        uint256 loserPool = isYes ? newNo : newYes;
        if (loserPool == 0) return betAmount; // would refund via empty-side rule
        uint256 totalPool = winnerPool + loserPool;
        uint16 effectiveCreatorFee =
            _isCreatorFeeForfeited(newYes, newNo, m.creatorFeeBpsSnapshot) ? uint16(0) : m.creatorFeeBpsSnapshot;
        uint256 feeBps = uint256(m.protocolFeeBpsSnapshot) + uint256(effectiveCreatorFee);
        uint256 payoutPool = totalPool - (totalPool * feeBps / 10000);
        return (betAmount * payoutPool) / winnerPool;
    }

    /// @notice Current live multiplier for a side, scaled by 1e18. UI: divide by 1e18.
    /// @dev Forfeit-aware: at a ratio below threshold, quotes as if only the
    ///      protocol fee applies. Matches what `claim()` would pay at the
    ///      current pool state.
    function multiplier(uint256 id, bool isYes) external view returns (uint256) {
        Market storage m = markets[id];
        uint256 winnerPool = isYes ? m.totalYes : m.totalNo;
        if (winnerPool == 0) return 0;
        uint256 totalPool = m.totalYes + m.totalNo;
        uint16 effectiveCreatorFee = _isCreatorFeeForfeited(m.totalYes, m.totalNo, m.creatorFeeBpsSnapshot)
            ? uint16(0)
            : m.creatorFeeBpsSnapshot;
        uint256 feeBps = uint256(m.protocolFeeBpsSnapshot) + uint256(effectiveCreatorFee);
        uint256 payoutPool = totalPool - (totalPool * feeBps / 10000);
        return (payoutPool * 1e18) / winnerPool;
    }

    /// @dev True if the pool ratio is so one-sided that the creator fee is
    ///      forfeited. Used uniformly by `claim`, `claimCreatorFee`,
    ///      `previewPayout`, and `multiplier` so every view and state-change
    ///      agrees on which fee regime applies. Parameterized on the pool
    ///      values (not just a Market) so `previewPayout` can check the
    ///      post-bet pool state.
    function _isCreatorFeeForfeited(uint256 yes, uint256 no, uint16 creatorFeeBpsSnap) internal pure returns (bool) {
        uint256 minSide = yes < no ? yes : no;
        uint256 maxSide = yes < no ? no : yes;
        if (minSide == 0) return false; // empty-side is handled by REFUND, not forfeit
        uint256 minRatio = _minLiquidityRatioBps(creatorFeeBpsSnap);
        return minSide * 10000 < maxSide * minRatio;
    }

    /// @notice Minimum smaller-side / larger-side ratio (in bps) required to
    ///         unlock the creator fee on a resolved market. Below this
    ///         threshold, the creator fee is forfeited (market still settles
    ///         normally for bettors); above, the creator fee pays out.
    /// @dev    Derivation: the threshold must strictly dominate the break-even
    ///         point for a creator self-dust attack. Break-even in bps is
    ///         `10000 * cBps / (10000 - cBps)`; we use 2x that as a safety
    ///         margin, floored at `MIN_RATIO_FLOOR_BPS`. Parameterized so a
    ///         market's snapshotted creatorFeeBps, not the current global,
    ///         drives the gate at claim time.
    function _minLiquidityRatioBps(uint16 creatorFeeBpsSnap) internal pure returns (uint256) {
        uint256 cBps = uint256(creatorFeeBpsSnap);
        if (cBps == 0) return MIN_RATIO_FLOOR_BPS;
        uint256 breakevenBps = (10000 * cBps) / (10000 - cBps);
        uint256 safeBps = 2 * breakevenBps;
        return safeBps > MIN_RATIO_FLOOR_BPS ? safeBps : MIN_RATIO_FLOOR_BPS;
    }

    /// @notice Threshold for the current global creator fee. Backward-compat
    ///         shim for UIs — an individual market's threshold is whatever
    ///         `_minLiquidityRatioBps(m.creatorFeeBpsSnapshot)` returns.
    function minLiquidityRatioBps() public view returns (uint256) {
        return _minLiquidityRatioBps(creatorFeeBps);
    }

    /// @notice Per-market threshold, using the market's snapshotted fees.
    function marketMinLiquidityRatioBps(uint256 id) external view returns (uint256) {
        return _minLiquidityRatioBps(markets[id].creatorFeeBpsSnapshot);
    }

    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------

    function setResolver(address r) external onlyOwner {
        address old = resolver;
        resolver = r;
        emit ResolverChanged(old, r);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = t;
        emit TreasuryChanged(old, t);
    }

    /// @notice Change default fee bps for FUTURE markets only. Existing
    ///         markets keep the snapshotted values set at `createMarket` time.
    function setFees(uint16 _protocolBps, uint16 _creatorBps) external onlyOwner {
        if (_protocolBps + _creatorBps > MAX_TOTAL_FEE_BPS) revert FeesTooHigh();
        uint16 oldProto = protocolFeeBps;
        uint16 oldCreator = creatorFeeBps;
        protocolFeeBps = _protocolBps;
        creatorFeeBps = _creatorBps;
        emit FeesChanged(oldProto, oldCreator, _protocolBps, _creatorBps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    // -------- anti-abuse admin setters --------
    //
    // Intentional admin emergency brake: any of the three cap setters below,
    // tightened to extreme values, acts as a soft global pause on NEW bets.
    //   setMaxBetPerWalletPerMarket(0)    → every placeBet reverts WalletCapExceeded
    //   setMaxWalletShareBps(1)           → every post-seed-stage bet reverts (0.01% cap)
    //   setShareCapMinPool(0)             → cap enforced from first bet, same effect
    // Claims (claim, claimCreatorFee, forceRefund, withdrawTreasury) are
    // NOT affected — users can always exit. This is a deliberate
    // emergency-brake design and should be disclosed in the audit brief.

    function setMaxBetPerWalletPerMarket(uint256 newCap) external onlyOwner {
        uint256 old = maxBetPerWalletPerMarket;
        maxBetPerWalletPerMarket = newCap;
        emit MaxBetPerWalletChanged(old, newCap);
    }

    function setMaxWalletShareBps(uint16 newBps) external onlyOwner {
        // Allow any value up to 10000 (100% — effectively disables the cap).
        // Policy decision: a 0-bps cap would block every bet, so require > 0.
        if (newBps == 0 || newBps > 10000) revert FeesTooHigh();
        uint16 old = maxWalletShareBps;
        maxWalletShareBps = newBps;
        emit MaxWalletShareBpsChanged(old, newBps);
    }

    function setShareCapMinPool(uint256 newMinPool) external onlyOwner {
        uint256 old = shareCapMinPool;
        shareCapMinPool = newMinPool;
        emit ShareCapMinPoolChanged(old, newMinPool);
    }

    function setBlocked(address wallet, bool isBlocked) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        blocked[wallet] = isBlocked;
        emit WalletBlockStatusChanged(wallet, isBlocked);
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    /// @dev Known limitation: sum-of-floors rounding dust.
    ///      Each winner gets `floor(userBet * payoutPool / winnerPool)`.
    ///      `sum(floor(...))` ≤ `floor(sum(...))` ≤ `payoutPool`, with a
    ///      maximum residual of `N - 1` base units (1 micro-USDC per
    ///      non-first winner) left in the contract per resolved market.
    ///      At USDC scale this bound is ~10 ** -6 dollars per market;
    ///      we accept it rather than adding per-market claim-sum
    ///      accounting. This is standard practice for parimutuel
    ///      contracts (Polymarket, Gnosis-OS, etc. all accept the same
    ///      floor-division residual). The multi-winner invariant test
    ///      in MakoMarketsV4.t.sol asserts the N-1 bound holds.
    function _calcPayout(
        uint256 winnerPool,
        uint256 loserPool,
        uint256 userBet,
        uint16 protocolFeeBpsSnap,
        uint16 creatorFeeBpsSnap
    ) internal pure returns (uint256) {
        uint256 totalPool = winnerPool + loserPool;
        uint256 feeBps = uint256(protocolFeeBpsSnap) + uint256(creatorFeeBpsSnap);
        uint256 payoutPool = totalPool - (totalPool * feeBps / 10000);
        return (userBet * payoutPool) / winnerPool;
    }

    // No receive() / fallback() — this contract holds USDC only, never native value.
    // Any native MON/ETH sent to this address is unrecoverable.
}
