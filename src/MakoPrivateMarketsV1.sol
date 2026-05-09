// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MakoPrivateMarketsV1
/// @notice Creator-defined private markets in three shapes — Friendlies (binary
///         creator-resolved YES/NO), Open Vote (multi-outcome contract-ranked,
///         creator confirms, voters refunded stake-fee), Prize Pool
///         (multi-outcome contract-ranked, creator distributes, top-N
///         participant wallets paid proportionally from the pool).
/// @dev    Pull-payment settlement. Resolution writes only aggregate snapshot
///         data; each `claim()` computes per-recipient amount on demand.
///         Time-derived transitions (Created→Open at stakingOpensAt,
///         Open→AwaitingCreator at closeAt) are NEVER stored — they're
///         computed lazily by `getMarket().effectiveState`.
///         USDC-denominated (6 decimals).

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

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

contract MakoPrivateMarketsV1 {
    using SafeERC20Min for IERC20;

    // ---------------------------------------------------------------------
    // Enums
    // ---------------------------------------------------------------------

    enum MarketShape {
        Friendly,
        OpenVote,
        PrizePool
    }

    enum MarketState {
        Created,
        Open,                // Lazy only — never written to storage
        AwaitingCreator,     // Lazy only — never written to storage
        Resolved,
        EmptyPoolResolved,
        Canceled,
        TimedOut,
        ZeroStakeExpired
    }

    enum VisibilityView {
        LinkOnly,
        Public
    }

    enum VisibilityParticipation {
        Open,
        Allowlisted
    }

    enum FriendlyOutcome {
        NO,
        YES
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint256 public constant MIN_STAKE = 10_000;          // 0.01 USDC
    uint256 public constant POST_CLOSE_GRACE = 7 days;
    uint16  public constant PROTOCOL_FEE_BPS = 100;      // 1%
    uint16  public constant BPS_DENOMINATOR = 10_000;
    uint8   public constant MAX_OPTIONS = 50;
    uint8   public constant MAX_WINNERS = 10;
    uint8   public constant MAX_ALLOWLIST = 100;
    uint16  public constant MAX_TITLE_BYTES = 100;
    uint16  public constant MAX_DESCRIPTION_BYTES = 2_000;
    uint16  public constant MAX_OPTION_LABEL_BYTES = 80;
    uint16  public constant MAX_STREAM_URL_BYTES = 256;

    // Friendly binary option indices
    uint8 internal constant FRIENDLY_NO = 0;
    uint8 internal constant FRIENDLY_YES = 1;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotCreator();
    error InvalidShape();
    error InvalidTimestamps();
    error InvalidWinners();
    error InvalidOptions();
    error InvalidStakeBounds();
    error InvalidParticipants();
    error InvalidAllowlist();
    error MetadataTooLarge();
    error TreasuryNotAllowed();
    error MarketUnknown();
    error EditWindowClosed();
    error StakingClosed();
    error StakingNotOpen();
    error AmountBelowFloor();
    error AmountAboveCap();
    error WalletCapExceeded();
    error NotAllowlisted();
    error AlreadyVoted();
    error CreatorWindowClosed();
    error CreatorActionInvalidState();
    error NoStakesToSettle();
    error NothingToFinalize();
    error MetadataFreezeNotReady();
    error AlreadyClaimed();
    error NothingToClaim();
    error InvalidOutcome();
    error WrongShape();
    error NotInTerminalState();
    /// @dev Constructor-time guard. USDC has 6 decimals and every threshold
    ///      (`MIN_STAKE`, the per-stake floor, fee math) assumes that. If a
    ///      misconfigured token address (e.g. an 18-decimal stablecoin) gets
    ///      wired in, reject up front so the mistake surfaces at deploy.
    error BadDecimals();
    /// @dev Inbound balance delta on `bet` / `stake` did not equal `amount`.
    ///      Triggered by fee-on-transfer / deflationary ERC-20s. Canonical
    ///      USDC never hits this path; defensive guard against a misconfigured
    ///      `usdc` address.
    error TransferAmountMismatch();
    error ZeroAddress();

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    struct Market {
        // Identity & shape
        address creator;
        MarketShape shape;
        bytes32 clientNonce;
        // Timestamps
        uint64 createdAt;
        uint64 stakingOpensAt;
        uint64 closeAt;
        // Visibility
        VisibilityView viewMode;
        VisibilityParticipation participationMode;
        // Stored state (event-driven only — never holds Open / AwaitingCreator)
        MarketState state;
        // Stake bounds (per-stake)
        uint256 perStakeMin;     // 0 = defaults to MIN_STAKE floor
        uint256 perStakeMax;     // 0 = no cap
        uint256 perWalletCumulativeMax; // 0 = no cap (Prize Pool only)
        // Open Vote-only
        uint256 fixedStake;      // 0 if not Open Vote
        // Vote-shape winners count (Open Vote / Prize Pool)
        uint8 winnersCount;
        // Aggregates
        uint256 totalStake;
        uint16 firstStakeSequenceCounter;
        // Resolution snapshot — Friendlies-specific fields stored inline
        FriendlyOutcome friendlyOutcome;
        bool friendlyEmptyPoolPath;
        uint256 feeTaken;
        uint256 dust;
        // Metadata-frozen advisory event flag
        bool metadataFrozenEmitted;
    }

    struct VoteResolution {
        uint256[] topN;          // option indices (length <= winnersCount; may be shorter if few-staked)
        uint256[] topNStakes;    // pool received by each top-N option (Prize Pool); empty for Open Vote
        uint256 sumOfTopNStakes; // Prize Pool only
    }

    struct CreateParams {
        MarketShape shape;
        uint64 stakingOpensAt;
        uint64 closeAt;
        bytes title;
        bytes description;
        bytes streamUrl;
        bytes[] optionLabels;
        address[] participantWallets;   // Prize Pool only; empty otherwise
        address[] allowlist;            // empty if open participation
        VisibilityView viewMode;
        VisibilityParticipation participationMode;
        uint256 perStakeMin;
        uint256 perStakeMax;
        uint256 perWalletCumulativeMax;
        uint256 fixedStake;             // Open Vote only
        uint8 winnersCount;             // Vote shapes only
        bytes32 clientNonce;
    }

    /// @notice Mako treasury address. Cannot stake/bet; cannot appear in
    ///         allowlists or participant lists.
    address public immutable treasury;

    /// @notice USDC token used for all stakes and payouts.
    IERC20 public immutable usdc;

    uint256 public nextMarketId;

    mapping(uint256 => Market) internal _markets;

    // Per-market metadata (dynamic; not part of Market struct to keep struct size manageable)
    mapping(uint256 => bytes) internal _title;
    mapping(uint256 => bytes) internal _description;
    mapping(uint256 => bytes) internal _streamUrl;
    mapping(uint256 => bytes[]) internal _optionLabels;
    mapping(uint256 => address[]) internal _participantWallets;
    mapping(uint256 => address[]) internal _allowlist;

    // Per-market option pools + first-stake sequence per option
    mapping(uint256 => mapping(uint256 => uint256)) internal _poolPerOption;
    mapping(uint256 => mapping(uint256 => uint16)) internal _firstStakeSequence;
    mapping(uint256 => mapping(uint256 => bool)) internal _firstStakeSequenceSet;

    // Per-wallet aggregates per shape
    // Friendlies: bets[id][wallet][side] (side: 0=NO, 1=YES)
    mapping(uint256 => mapping(address => mapping(uint8 => uint256))) internal _bets;
    // Open Vote: voted option + amount per wallet
    mapping(uint256 => mapping(address => uint256)) internal _votedOption;
    mapping(uint256 => mapping(address => uint256)) internal _votedAmount;
    mapping(uint256 => mapping(address => bool)) internal _hasVoted;
    // Prize Pool: staked[id][wallet][option] + cumulative-per-wallet
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) internal _staked;
    mapping(uint256 => mapping(address => uint256)) internal _stakedCumulative;
    // Prize Pool participant lookup (wallet -> option index + 1; 0 = not participant)
    mapping(uint256 => mapping(address => uint256)) internal _participantOptionPlusOne;

    // Allowlist membership lookup
    mapping(uint256 => mapping(address => bool)) internal _onAllowlist;

    // Vote-shape resolution snapshot
    mapping(uint256 => VoteResolution) internal _voteResolution;

    // Per-claim flags
    mapping(uint256 => mapping(address => bool)) public userClaimed;
    /// @notice Cumulative amount the treasury has pulled per market (fee + dust
    ///         observed so far). Treasury may call `claim` multiple times — for
    ///         Friendlies, dust accumulates progressively as winners claim, so
    ///         each treasury call sweeps any newly-accrued residue.
    mapping(uint256 => uint256) public feeAndDustClaimed;

    /// @dev Friendlies-only: cumulative residue numerator from per-winner share
    ///      truncations. Each Friendly winner claim adds (myStake * (loserPool -
    ///      feeTaken)) % winnerPool to this number; whenever it overflows
    ///      winnerPool, a USDC base unit of dust gets credited to `m.dust`.
    ///      Open Vote and Prize Pool dust is exact at resolve and never touches
    ///      this counter.
    mapping(uint256 => uint256) internal _friendlyDustNumerator;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

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

    event Staked(
        uint256 indexed marketId,
        address indexed staker,
        uint256 optionIndex,
        uint256 amount,
        uint256 timestamp
    );

    /// @notice Emitted on Friendly Resolve.
    /// @param  totalOwed Gross winner-pool distributable BEFORE per-claim
    ///         truncation: `winnerPool + (loserPool - feeTaken)` for the normal
    ///         path, or the entire non-empty pool for the empty-pool path.
    ///         Actual sum of `Claimed` events to non-treasury recipients may be
    ///         strictly less than this on the normal path because per-winner
    ///         shares truncate down; the residue accrues to treasury via
    ///         `m.dust` and is recoverable through the progressive
    ///         `feeAndDustClaimed[id]` counter on subsequent treasury claims.
    ///         Indexers tracking exact winner payouts should sum the
    ///         non-treasury `Claimed` events for the market rather than reading
    ///         this field.
    event ResolvedFriendly(
        uint256 indexed marketId,
        uint8 outcome,
        bool emptyPoolPath,
        uint256 feeTaken,
        uint256 totalOwed
    );

    event ResolvedOpenVote(uint256 indexed marketId, uint256[] topN, uint256 feeTaken);

    event DistributedPrizePool(
        uint256 indexed marketId,
        uint256[] topN,
        address[] winnerWallets,
        uint256[] amountsOwed,
        uint256 feeTaken
    );

    event Canceled(uint256 indexed marketId, uint8 reason);

    event Claimed(uint256 indexed marketId, address indexed recipient, uint256 amount);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(address usdc_, address treasury_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        // Pin to USDC's canonical 6-decimal layout. MIN_STAKE and every fee /
        // per-claim payout path depend on this. A misconfigured token address
        // (e.g. an 18-decimal stablecoin) would silently produce mis-scaled
        // accounting in storage.
        if (IERC20(usdc_).decimals() != 6) revert BadDecimals();
        usdc = IERC20(usdc_);
        treasury = treasury_;
    }

    // ---------------------------------------------------------------------
    // Create / Edit
    // ---------------------------------------------------------------------

    function createMarket(CreateParams calldata p) external returns (uint256 marketId) {
        _validateCreate(p);

        marketId = nextMarketId++;

        Market storage m = _markets[marketId];
        m.creator = msg.sender;
        m.shape = p.shape;
        m.clientNonce = p.clientNonce;
        m.createdAt = uint64(block.timestamp);
        m.stakingOpensAt = p.stakingOpensAt;
        m.closeAt = p.closeAt;
        m.state = MarketState.Created;

        // Stream URL forces public view per taxonomy
        m.viewMode = (p.streamUrl.length > 0) ? VisibilityView.Public : p.viewMode;
        m.participationMode = p.participationMode;

        m.perStakeMin = p.perStakeMin == 0 ? MIN_STAKE : p.perStakeMin;
        m.perStakeMax = p.perStakeMax;
        m.perWalletCumulativeMax = p.perWalletCumulativeMax;
        m.fixedStake = p.fixedStake;
        m.winnersCount = p.winnersCount;

        _title[marketId] = p.title;
        _description[marketId] = p.description;
        _streamUrl[marketId] = p.streamUrl;

        // Option labels: stored per market, length frozen at create (mutable in pre-open via editMetadata)
        for (uint256 i = 0; i < p.optionLabels.length; i++) {
            _optionLabels[marketId].push(p.optionLabels[i]);
        }

        // Prize Pool participants
        if (p.shape == MarketShape.PrizePool) {
            for (uint256 i = 0; i < p.participantWallets.length; i++) {
                address w = p.participantWallets[i];
                _participantWallets[marketId].push(w);
                _participantOptionPlusOne[marketId][w] = i + 1;
            }
        }

        // Allowlist
        if (p.participationMode == VisibilityParticipation.Allowlisted) {
            for (uint256 i = 0; i < p.allowlist.length; i++) {
                address a = p.allowlist[i];
                _allowlist[marketId].push(a);
                _onAllowlist[marketId][a] = true;
            }
        }

        emit MarketCreated(
            marketId,
            msg.sender,
            uint8(p.shape),
            block.timestamp,
            p.stakingOpensAt,
            p.closeAt,
            uint8(m.viewMode),
            uint8(p.participationMode),
            p.clientNonce
        );
    }

    /// @notice Pre-open metadata edit. Replaces title / description / stream URL /
    ///         option labels / participant wallets / allowlist / caps / timestamps
    ///         (subject to stakingOpensAt > now). No event emitted per taxonomy —
    ///         indexers re-snapshot from storage at stakingOpensAt.
    function editMetadata(uint256 marketId, CreateParams calldata p) external {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert MarketUnknown();
        if (msg.sender != m.creator) revert NotCreator();
        if (block.timestamp >= m.stakingOpensAt) revert EditWindowClosed();
        if (p.shape != m.shape) revert InvalidShape();

        // Treasury exclusion + size + uniqueness all re-validated
        _validateCreate(p);

        m.stakingOpensAt = p.stakingOpensAt;
        m.closeAt = p.closeAt;
        m.viewMode = (p.streamUrl.length > 0) ? VisibilityView.Public : p.viewMode;
        m.participationMode = p.participationMode;
        m.perStakeMin = p.perStakeMin == 0 ? MIN_STAKE : p.perStakeMin;
        m.perStakeMax = p.perStakeMax;
        m.perWalletCumulativeMax = p.perWalletCumulativeMax;
        m.fixedStake = p.fixedStake;
        m.winnersCount = p.winnersCount;

        _title[marketId] = p.title;
        _description[marketId] = p.description;
        _streamUrl[marketId] = p.streamUrl;

        // Option labels: clear and rewrite
        delete _optionLabels[marketId];
        for (uint256 i = 0; i < p.optionLabels.length; i++) {
            _optionLabels[marketId].push(p.optionLabels[i]);
        }

        // Participants: clear lookup + array, rewrite
        if (m.shape == MarketShape.PrizePool) {
            address[] storage prev = _participantWallets[marketId];
            for (uint256 i = 0; i < prev.length; i++) {
                _participantOptionPlusOne[marketId][prev[i]] = 0;
            }
            delete _participantWallets[marketId];
            for (uint256 i = 0; i < p.participantWallets.length; i++) {
                address w = p.participantWallets[i];
                _participantWallets[marketId].push(w);
                _participantOptionPlusOne[marketId][w] = i + 1;
            }
        }

        // Allowlist: clear lookup + array, rewrite
        address[] storage prevA = _allowlist[marketId];
        for (uint256 i = 0; i < prevA.length; i++) {
            _onAllowlist[marketId][prevA[i]] = false;
        }
        delete _allowlist[marketId];
        if (p.participationMode == VisibilityParticipation.Allowlisted) {
            for (uint256 i = 0; i < p.allowlist.length; i++) {
                address a = p.allowlist[i];
                _allowlist[marketId].push(a);
                _onAllowlist[marketId][a] = true;
            }
        }
    }

    function _validateCreate(CreateParams calldata p) internal view {
        // Timestamps
        if (p.stakingOpensAt < block.timestamp) revert InvalidTimestamps();
        if (p.closeAt <= p.stakingOpensAt) revert InvalidTimestamps();

        // Sizes
        if (p.title.length == 0 || p.title.length > MAX_TITLE_BYTES) revert MetadataTooLarge();
        if (p.description.length > MAX_DESCRIPTION_BYTES) revert MetadataTooLarge();
        if (p.streamUrl.length > MAX_STREAM_URL_BYTES) revert MetadataTooLarge();

        // Options
        if (p.shape == MarketShape.Friendly) {
            // Binary: NO=0, YES=1 implicit; option labels must be exactly 2
            if (p.optionLabels.length != 2) revert InvalidOptions();
        } else {
            if (p.optionLabels.length < 2 || p.optionLabels.length > MAX_OPTIONS) revert InvalidOptions();
        }
        for (uint256 i = 0; i < p.optionLabels.length; i++) {
            if (p.optionLabels[i].length == 0 || p.optionLabels[i].length > MAX_OPTION_LABEL_BYTES) {
                revert MetadataTooLarge();
            }
        }

        // Stake bounds
        if (p.perStakeMin != 0 && p.perStakeMin < MIN_STAKE) revert InvalidStakeBounds();
        if (p.perStakeMax != 0 && p.perStakeMax < (p.perStakeMin == 0 ? MIN_STAKE : p.perStakeMin)) {
            revert InvalidStakeBounds();
        }

        if (p.shape == MarketShape.OpenVote) {
            if (p.fixedStake < MIN_STAKE) revert InvalidStakeBounds();
            // perStakeMin / perStakeMax / perWalletCumulativeMax not used for Open Vote — must be zero
            if (p.perStakeMin != 0 || p.perStakeMax != 0 || p.perWalletCumulativeMax != 0) revert InvalidStakeBounds();
        } else if (p.shape == MarketShape.Friendly) {
            if (p.fixedStake != 0) revert InvalidStakeBounds();
            // perWalletCumulativeMax is Prize-Pool-only — Friendlies allow same-wallet
            // hedge bets across both sides per taxonomy.
            if (p.perWalletCumulativeMax != 0) revert InvalidStakeBounds();
        } else {
            // PrizePool
            if (p.fixedStake != 0) revert InvalidStakeBounds();
        }

        if (p.shape == MarketShape.Friendly) {
            if (p.winnersCount != 0) revert InvalidWinners();
        } else {
            if (p.winnersCount == 0 || p.winnersCount > MAX_WINNERS) revert InvalidWinners();
            if (p.winnersCount > p.optionLabels.length) revert InvalidWinners();
        }

        // Participants (Prize Pool)
        if (p.shape == MarketShape.PrizePool) {
            if (p.participantWallets.length != p.optionLabels.length) revert InvalidParticipants();
            for (uint256 i = 0; i < p.participantWallets.length; i++) {
                address w = p.participantWallets[i];
                if (w == address(0)) revert InvalidParticipants();
                if (w == treasury) revert TreasuryNotAllowed();
                for (uint256 j = i + 1; j < p.participantWallets.length; j++) {
                    if (p.participantWallets[j] == w) revert InvalidParticipants();
                }
            }
        } else {
            if (p.participantWallets.length != 0) revert InvalidParticipants();
        }

        // Allowlist
        if (p.participationMode == VisibilityParticipation.Allowlisted) {
            if (p.allowlist.length == 0 || p.allowlist.length > MAX_ALLOWLIST) revert InvalidAllowlist();
            for (uint256 i = 0; i < p.allowlist.length; i++) {
                address a = p.allowlist[i];
                if (a == address(0)) revert InvalidAllowlist();
                if (a == treasury) revert TreasuryNotAllowed();
                for (uint256 j = i + 1; j < p.allowlist.length; j++) {
                    if (p.allowlist[j] == a) revert InvalidAllowlist();
                }
            }
        } else {
            if (p.allowlist.length != 0) revert InvalidAllowlist();
        }
    }

    // ---------------------------------------------------------------------
    // Stake / Bet
    // ---------------------------------------------------------------------

    /// @notice Friendlies binary bet. side 0 = NO, 1 = YES.
    function bet(uint256 marketId, uint8 side, uint256 amount) external {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert MarketUnknown();
        if (m.shape != MarketShape.Friendly) revert WrongShape();
        if (side != FRIENDLY_NO && side != FRIENDLY_YES) revert InvalidOutcome();
        _stakeCommon(marketId, m, side, amount);
        _bets[marketId][msg.sender][side] += amount;
        _stakeAccumulate(marketId, m, side, amount);
        emit Staked(marketId, msg.sender, side, amount, block.timestamp);
    }

    /// @notice Vote-shape stake. Dispatches by shape:
    ///         - Open Vote: amount must equal fixedStake; one stake per wallet.
    ///         - Prize Pool: variable amount within caps; multiple stakes per
    ///           wallet across options allowed up to perWalletCumulativeMax.
    ///         Friendlies must use `bet()` (binary YES/NO with side, not option).
    function stake(uint256 marketId, uint256 optionIndex, uint256 amount) external {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert MarketUnknown();
        if (m.shape == MarketShape.Friendly) revert WrongShape();
        if (optionIndex >= _optionLabels[marketId].length) revert InvalidOutcome();

        if (m.shape == MarketShape.OpenVote) {
            if (amount != m.fixedStake) revert AmountAboveCap();
            if (_hasVoted[marketId][msg.sender]) revert AlreadyVoted();
            _stakeCommon(marketId, m, optionIndex, amount);
            _hasVoted[marketId][msg.sender] = true;
            _votedOption[marketId][msg.sender] = optionIndex;
            _votedAmount[marketId][msg.sender] = amount;
        } else {
            // Prize Pool
            _stakeCommon(marketId, m, optionIndex, amount);
            uint256 newCumulative = _stakedCumulative[marketId][msg.sender] + amount;
            if (m.perWalletCumulativeMax != 0 && newCumulative > m.perWalletCumulativeMax) {
                revert WalletCapExceeded();
            }
            _staked[marketId][msg.sender][optionIndex] += amount;
            _stakedCumulative[marketId][msg.sender] = newCumulative;
        }
        _stakeAccumulate(marketId, m, optionIndex, amount);
        emit Staked(marketId, msg.sender, optionIndex, amount, block.timestamp);
    }

    function _stakeCommon(uint256 marketId, Market storage m, uint256 /*optionIndex*/, uint256 amount) internal {
        // Treasury cannot stake/bet
        if (msg.sender == treasury) revert TreasuryNotAllowed();
        // State / time gates
        if (m.state != MarketState.Created) revert StakingClosed();
        if (block.timestamp < m.stakingOpensAt) revert StakingNotOpen();
        if (block.timestamp >= m.closeAt) revert StakingClosed();
        // Allowlist
        if (m.participationMode == VisibilityParticipation.Allowlisted) {
            if (!_onAllowlist[marketId][msg.sender]) revert NotAllowlisted();
        }
        // Stake bounds (skip per-stake checks for Open Vote — fixed-stake equality already enforced upstream)
        if (m.shape != MarketShape.OpenVote) {
            uint256 floor = m.perStakeMin == 0 ? MIN_STAKE : m.perStakeMin;
            if (amount < floor) revert AmountBelowFloor();
            if (m.perStakeMax != 0 && amount > m.perStakeMax) revert AmountAboveCap();
        }
        // USDC pull. Stake paths intentionally call `safeTransferFrom` BEFORE
        // accumulating per-wallet aggregates (`_bets` / `_voted*` / `_staked` /
        // `_stakedCumulative`) and pool totals (`_stakeAccumulate`). This is
        // safe under canonical USDC because USDC has no transfer-receive
        // callback and cannot reenter, and a `false` / reverting transfer
        // bubbles up through `SafeERC20Min` before any state changes. If a
        // future deployment swaps in a token with ERC-777-style hooks the
        // ordering must change to checks-effects-interactions.
        //
        // Balance-delta guard: rejects fee-on-transfer / deflationary ERC-20s
        // that would credit less than `amount` to the contract while letting
        // pool aggregates record the requested figure. Canonical USDC never
        // trips this; it's a defensive guard against a misconfigured `usdc`.
        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = usdc.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TransferAmountMismatch();
    }

    function _stakeAccumulate(uint256 marketId, Market storage m, uint256 optionIndex, uint256 amount) internal {
        _poolPerOption[marketId][optionIndex] += amount;
        m.totalStake += amount;
        if (!_firstStakeSequenceSet[marketId][optionIndex]) {
            m.firstStakeSequenceCounter += 1;
            _firstStakeSequence[marketId][optionIndex] = m.firstStakeSequenceCounter;
            _firstStakeSequenceSet[marketId][optionIndex] = true;
        }
        if (!m.metadataFrozenEmitted) {
            m.metadataFrozenEmitted = true;
            emit MarketMetadataFrozen(marketId, block.timestamp);
        }
    }

    // ---------------------------------------------------------------------
    // Creator actions (resolve / confirm / distribute / cancel)
    // ---------------------------------------------------------------------

    function resolve(uint256 marketId, uint8 outcome) external {
        Market storage m = _markets[marketId];
        _requireCreatorAction(m);
        if (m.shape != MarketShape.Friendly) revert WrongShape();
        if (outcome != FRIENDLY_NO && outcome != FRIENDLY_YES) revert InvalidOutcome();

        uint256 poolYes = _poolPerOption[marketId][FRIENDLY_YES];
        uint256 poolNo = _poolPerOption[marketId][FRIENDLY_NO];
        m.friendlyOutcome = (outcome == FRIENDLY_YES) ? FriendlyOutcome.YES : FriendlyOutcome.NO;

        bool empty = (poolYes == 0 || poolNo == 0);
        if (empty) {
            m.state = MarketState.EmptyPoolResolved;
            m.friendlyEmptyPoolPath = true;
            m.feeTaken = 0;
            m.dust = 0;
            uint256 totalOwed = poolYes + poolNo; // entire non-empty pool refunded to its bettors
            emit ResolvedFriendly(marketId, outcome, true, 0, totalOwed);
        } else {
            m.state = MarketState.Resolved;
            uint256 winnerPool = (outcome == FRIENDLY_YES) ? poolYes : poolNo;
            uint256 loserPool = (outcome == FRIENDLY_YES) ? poolNo : poolYes;
            uint256 fee = (loserPool * uint256(PROTOCOL_FEE_BPS)) / uint256(BPS_DENOMINATOR);
            m.feeTaken = fee;
            // m.dust grows progressively as Friendly winners claim. See claim()
            // for the residue-numerator accumulator. Treasury sweeps fee + dust
            // via repeated `claim()` calls — feeAndDustClaimed[id] tracks
            // cumulative pulls so each call transfers only newly-accrued amount.
            m.dust = 0;
            uint256 totalOwed = winnerPool + (loserPool - fee);
            emit ResolvedFriendly(marketId, outcome, false, fee, totalOwed);
        }
    }

    function confirm(uint256 marketId) external {
        Market storage m = _markets[marketId];
        _requireCreatorAction(m);
        if (m.shape != MarketShape.OpenVote) revert WrongShape();

        m.state = MarketState.Resolved;
        // Per taxonomy: Open Vote fee = sum of per-voter fees, NOT aggregate
        // totalStake * 1% (which truncates differently and leaves negative-dust
        // for non-100-divisible fixedStake values).
        uint256 perVoterFee = (m.fixedStake * uint256(PROTOCOL_FEE_BPS)) / uint256(BPS_DENOMINATOR);
        uint256 voterCount = m.totalStake / m.fixedStake;
        uint256 fee = voterCount * perVoterFee;
        m.feeTaken = fee;
        // perVoterRefund = fixedStake - perVoterFee, voterCount voters refunded.
        // totalStake = voterCount * fixedStake = fee + voterCount * perVoterRefund,
        // so dust = 0 by construction.
        m.dust = 0;

        uint256[] memory topN = _computeTopN(marketId);
        VoteResolution storage r = _voteResolution[marketId];
        for (uint256 i = 0; i < topN.length; i++) r.topN.push(topN[i]);
        // Open Vote topNStakes/sumOfTopNStakes unused
        emit ResolvedOpenVote(marketId, topN, fee);
    }

    function distribute(uint256 marketId) external {
        Market storage m = _markets[marketId];
        _requireCreatorAction(m);
        if (m.shape != MarketShape.PrizePool) revert WrongShape();

        m.state = MarketState.Resolved;
        uint256 fee = (m.totalStake * uint256(PROTOCOL_FEE_BPS)) / uint256(BPS_DENOMINATOR);
        m.feeTaken = fee;
        uint256 distributable = m.totalStake - fee;

        uint256[] memory topN = _computeTopN(marketId);
        uint256 sum;
        for (uint256 i = 0; i < topN.length; i++) sum += _poolPerOption[marketId][topN[i]];

        VoteResolution storage r = _voteResolution[marketId];
        address[] memory winners = new address[](topN.length);
        uint256[] memory amounts = new uint256[](topN.length);
        uint256 totalOwed;
        for (uint256 i = 0; i < topN.length; i++) {
            r.topN.push(topN[i]);
            uint256 stk = _poolPerOption[marketId][topN[i]];
            r.topNStakes.push(stk);
            uint256 owed = sum == 0 ? 0 : (distributable * stk) / sum;
            winners[i] = _participantWallets[marketId][topN[i]];
            amounts[i] = owed;
            totalOwed += owed;
        }
        r.sumOfTopNStakes = sum;
        m.dust = distributable - totalOwed;

        emit DistributedPrizePool(marketId, topN, winners, amounts, fee);
    }

    function cancel(uint256 marketId) external {
        Market storage m = _markets[marketId];
        _requireCreatorAction(m);
        m.state = MarketState.Canceled;
        m.feeTaken = 0;
        m.dust = 0;
        emit Canceled(marketId, 0);
    }

    function _requireCreatorAction(Market storage m) internal view {
        if (m.creator == address(0)) revert MarketUnknown();
        if (msg.sender != m.creator) revert NotCreator();
        if (block.timestamp < m.closeAt) revert CreatorWindowClosed();
        if (block.timestamp >= m.closeAt + POST_CLOSE_GRACE) revert CreatorWindowClosed();
        // Stored state must be Created (effective state must be AwaitingCreator).
        // Zero-stake markets that lazily transitioned to ZeroStakeExpired reject here.
        if (m.state != MarketState.Created) revert CreatorActionInvalidState();
        if (m.totalStake == 0) revert NoStakesToSettle();
    }

    // ---------------------------------------------------------------------
    // Top-N selection (Vote / Prize Pool)
    // ---------------------------------------------------------------------

    /// @dev Selection sort over option indices by (poolPerOption desc,
    ///      firstStakeSequence asc). Skips zero-stake options.
    ///      O(N²) bounded by MAX_OPTIONS = 50.
    function _computeTopN(uint256 marketId) internal view returns (uint256[] memory) {
        Market storage m = _markets[marketId];
        uint256 optionCount = _optionLabels[marketId].length;
        // Collect non-zero options
        uint256[] memory candidates = new uint256[](optionCount);
        uint256 nz;
        for (uint256 i = 0; i < optionCount; i++) {
            if (_poolPerOption[marketId][i] > 0) {
                candidates[nz++] = i;
            }
        }
        uint256 take = nz < m.winnersCount ? nz : m.winnersCount;
        uint256[] memory result = new uint256[](take);
        // Selection sort: pick best, swap to front, continue.
        for (uint256 k = 0; k < take; k++) {
            uint256 bestIdx = k;
            for (uint256 j = k + 1; j < nz; j++) {
                if (_betterThan(marketId, candidates[j], candidates[bestIdx])) {
                    bestIdx = j;
                }
            }
            (candidates[k], candidates[bestIdx]) = (candidates[bestIdx], candidates[k]);
            result[k] = candidates[k];
        }
        return result;
    }

    function _betterThan(uint256 marketId, uint256 a, uint256 b) internal view returns (bool) {
        uint256 pa = _poolPerOption[marketId][a];
        uint256 pb = _poolPerOption[marketId][b];
        if (pa != pb) return pa > pb;
        // Tie: lower firstStakeSequence wins (asserted set since both have non-zero stake)
        return _firstStakeSequence[marketId][a] < _firstStakeSequence[marketId][b];
    }

    // ---------------------------------------------------------------------
    // Finalize (anyone, idempotent)
    // ---------------------------------------------------------------------

    function finalize(uint256 marketId) external {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert MarketUnknown();
        // Already-terminal stored states are no-ops (idempotent).
        if (m.state != MarketState.Created) return;
        if (m.totalStake == 0 && block.timestamp >= m.closeAt) {
            m.state = MarketState.ZeroStakeExpired;
            emit Canceled(marketId, 2);
            return;
        }
        if (m.totalStake > 0 && block.timestamp >= m.closeAt + POST_CLOSE_GRACE) {
            m.state = MarketState.TimedOut;
            emit Canceled(marketId, 1);
            return;
        }
        revert NothingToFinalize();
    }

    function finalizeMetadata(uint256 marketId) external {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert MarketUnknown();
        if (block.timestamp < m.stakingOpensAt) revert MetadataFreezeNotReady();
        if (m.metadataFrozenEmitted) return;
        m.metadataFrozenEmitted = true;
        emit MarketMetadataFrozen(marketId, block.timestamp);
    }

    // ---------------------------------------------------------------------
    // Claim
    // ---------------------------------------------------------------------

    function claim(uint256 marketId) external {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert MarketUnknown();
        MarketState eff = _effectiveState(m, marketId);
        if (
            eff != MarketState.Resolved &&
            eff != MarketState.EmptyPoolResolved &&
            eff != MarketState.Canceled &&
            eff != MarketState.TimedOut &&
            eff != MarketState.ZeroStakeExpired
        ) revert NotInTerminalState();

        uint256 amount;
        if (msg.sender == treasury) {
            // Treasury sweeps fee + dust progressively. Friendly markets keep
            // accruing dust as winners claim, so treasury may call multiple
            // times; each call transfers only newly-available residue.
            uint256 totalAvailable = m.feeTaken + m.dust;
            uint256 already = feeAndDustClaimed[marketId];
            if (totalAvailable <= already) revert NothingToClaim();
            amount = totalAvailable - already;
            feeAndDustClaimed[marketId] = totalAvailable;
        } else {
            if (userClaimed[marketId][msg.sender]) revert AlreadyClaimed();
            amount = _settleUserClaim(marketId, m, msg.sender, eff);
            if (amount == 0) revert NothingToClaim();
            userClaimed[marketId][msg.sender] = true;
        }

        // Effects-then-interactions: state already updated above. USDC has no
        // ERC-777-style callback so reentry through transfer is not a concern,
        // but the ordering keeps the path correct under any safer extension.
        usdc.safeTransfer(msg.sender, amount);
        emit Claimed(marketId, msg.sender, amount);
    }

    /// @dev Identical to `_computeUserClaim` but additionally updates
    ///      `_friendlyDustNumerator` / `m.dust` for Friendly winner claims so
    ///      dust accrues toward the treasury's progressive sweep. Called only
    ///      from the user-claim path of `claim()`.
    function _settleUserClaim(
        uint256 marketId,
        Market storage m,
        address w,
        MarketState eff
    ) internal returns (uint256) {
        if (m.shape == MarketShape.Friendly && eff == MarketState.Resolved) {
            uint256 winnerPool;
            uint256 loserPool;
            uint256 myStake;
            if (m.friendlyOutcome == FriendlyOutcome.YES) {
                winnerPool = _poolPerOption[marketId][FRIENDLY_YES];
                loserPool = _poolPerOption[marketId][FRIENDLY_NO];
                myStake = _bets[marketId][w][FRIENDLY_YES];
            } else {
                winnerPool = _poolPerOption[marketId][FRIENDLY_NO];
                loserPool = _poolPerOption[marketId][FRIENDLY_YES];
                myStake = _bets[marketId][w][FRIENDLY_NO];
            }
            if (myStake == 0) return 0;
            uint256 shareNum = myStake * (loserPool - m.feeTaken);
            uint256 share = shareNum / winnerPool;
            uint256 residue = shareNum - share * winnerPool; // < winnerPool
            uint256 acc = _friendlyDustNumerator[marketId] + residue;
            uint256 dustAdded = acc / winnerPool;
            _friendlyDustNumerator[marketId] = acc % winnerPool;
            if (dustAdded != 0) m.dust += dustAdded;
            return myStake + share;
        }
        // Non-Friendly-Resolved paths route through the pure view helper.
        return _computeUserClaim(marketId, m, w, eff);
    }

    function _computeUserClaim(
        uint256 marketId,
        Market storage m,
        address w,
        MarketState eff
    ) internal view returns (uint256) {
        if (m.shape == MarketShape.Friendly) {
            uint256 betYes = _bets[marketId][w][FRIENDLY_YES];
            uint256 betNo = _bets[marketId][w][FRIENDLY_NO];
            if (eff == MarketState.Resolved) {
                uint256 winnerPool;
                uint256 loserPool;
                uint256 myStake;
                if (m.friendlyOutcome == FriendlyOutcome.YES) {
                    winnerPool = _poolPerOption[marketId][FRIENDLY_YES];
                    loserPool = _poolPerOption[marketId][FRIENDLY_NO];
                    myStake = betYes;
                } else {
                    winnerPool = _poolPerOption[marketId][FRIENDLY_NO];
                    loserPool = _poolPerOption[marketId][FRIENDLY_YES];
                    myStake = betNo;
                }
                if (myStake == 0) return 0;
                // myStake + (myStake * (loserPool - feeTaken) / winnerPool)
                return myStake + (myStake * (loserPool - m.feeTaken)) / winnerPool;
            }
            if (eff == MarketState.EmptyPoolResolved) {
                uint256 poolYes = _poolPerOption[marketId][FRIENDLY_YES];
                uint256 poolNo = _poolPerOption[marketId][FRIENDLY_NO];
                if (poolYes == 0) return betNo; // refund NO stakes
                if (poolNo == 0) return betYes; // refund YES stakes
                return 0;
            }
            // Canceled / TimedOut / ZeroStakeExpired
            return betYes + betNo;
        }

        if (m.shape == MarketShape.OpenVote) {
            uint256 stk = _votedAmount[marketId][w];
            if (stk == 0) return 0;
            if (eff == MarketState.Resolved) {
                uint256 fee = (stk * uint256(PROTOCOL_FEE_BPS)) / uint256(BPS_DENOMINATOR);
                return stk - fee;
            }
            // Canceled / TimedOut / (ZeroStakeExpired impossible here: no stake)
            return stk;
        }

        // PrizePool
        if (eff == MarketState.Resolved) {
            uint256 plus1 = _participantOptionPlusOne[marketId][w];
            if (plus1 == 0) return 0;
            uint256 myOption = plus1 - 1;
            VoteResolution storage r = _voteResolution[marketId];
            // Is myOption in topN?
            bool found;
            for (uint256 i = 0; i < r.topN.length; i++) {
                if (r.topN[i] == myOption) { found = true; break; }
            }
            if (!found) return 0;
            if (r.sumOfTopNStakes == 0) return 0;
            uint256 distributable = m.totalStake - m.feeTaken;
            return (distributable * _poolPerOption[marketId][myOption]) / r.sumOfTopNStakes;
        }
        // Canceled / TimedOut: sum stakes across options
        uint256 sum;
        uint256 optCount = _optionLabels[marketId].length;
        for (uint256 i = 0; i < optCount; i++) {
            sum += _staked[marketId][w][i];
        }
        return sum;
    }

    // ---------------------------------------------------------------------
    // Lazy effective-state derivation
    // ---------------------------------------------------------------------

    function _effectiveState(Market storage m, uint256 /*marketId*/) internal view returns (MarketState) {
        if (m.state != MarketState.Created) return m.state;
        if (block.timestamp < m.stakingOpensAt) return MarketState.Created;
        if (block.timestamp < m.closeAt) return MarketState.Open;
        if (m.totalStake == 0) return MarketState.ZeroStakeExpired;
        if (block.timestamp < m.closeAt + POST_CLOSE_GRACE) return MarketState.AwaitingCreator;
        return MarketState.TimedOut;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    struct MarketView {
        address creator;
        MarketShape shape;
        bytes32 clientNonce;
        uint64 createdAt;
        uint64 stakingOpensAt;
        uint64 closeAt;
        VisibilityView viewMode;
        VisibilityParticipation participationMode;
        MarketState storedState;
        MarketState effectiveState;
        uint256 perStakeMin;
        uint256 perStakeMax;
        uint256 perWalletCumulativeMax;
        uint256 fixedStake;
        uint8 winnersCount;
        uint256 totalStake;
        FriendlyOutcome friendlyOutcome;
        bool friendlyEmptyPoolPath;
        uint256 feeTaken;
        uint256 dust;
        bool metadataFrozenEmitted;
    }

    function getMarket(uint256 marketId) external view returns (MarketView memory v) {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) revert MarketUnknown();
        v.creator = m.creator;
        v.shape = m.shape;
        v.clientNonce = m.clientNonce;
        v.createdAt = m.createdAt;
        v.stakingOpensAt = m.stakingOpensAt;
        v.closeAt = m.closeAt;
        v.viewMode = m.viewMode;
        v.participationMode = m.participationMode;
        v.storedState = m.state;
        v.effectiveState = _effectiveState(m, marketId);
        v.perStakeMin = m.perStakeMin;
        v.perStakeMax = m.perStakeMax;
        v.perWalletCumulativeMax = m.perWalletCumulativeMax;
        v.fixedStake = m.fixedStake;
        v.winnersCount = m.winnersCount;
        v.totalStake = m.totalStake;
        v.friendlyOutcome = m.friendlyOutcome;
        v.friendlyEmptyPoolPath = m.friendlyEmptyPoolPath;
        v.feeTaken = m.feeTaken;
        v.dust = m.dust;
        v.metadataFrozenEmitted = m.metadataFrozenEmitted;
    }

    function getMarketTitle(uint256 marketId) external view returns (bytes memory) {
        return _title[marketId];
    }

    function getMarketDescription(uint256 marketId) external view returns (bytes memory) {
        return _description[marketId];
    }

    function getMarketStreamUrl(uint256 marketId) external view returns (bytes memory) {
        return _streamUrl[marketId];
    }

    function getMarketOptions(uint256 marketId) external view returns (bytes[] memory) {
        return _optionLabels[marketId];
    }

    function getMarketParticipants(uint256 marketId) external view returns (address[] memory) {
        return _participantWallets[marketId];
    }

    function getMarketAllowlist(uint256 marketId) external view returns (address[] memory) {
        return _allowlist[marketId];
    }

    function getOptionPool(uint256 marketId, uint256 optionIndex) external view returns (uint256) {
        return _poolPerOption[marketId][optionIndex];
    }

    /// @notice Returns the per-option `firstStakeSequence` counter and whether
    ///         it has been set (i.e., at least one wallet staked on this option).
    ///         Phase 2B indexer mirrors this into `pm_options.firstStakeSequence`
    ///         so that off-chain tie-break previews stay byte-equivalent to the
    ///         contract's resolution-time selection sort.
    function getOptionFirstStakeSequence(uint256 marketId, uint256 optionIndex)
        external view returns (uint16 sequence, bool isSet)
    {
        sequence = _firstStakeSequence[marketId][optionIndex];
        isSet = _firstStakeSequenceSet[marketId][optionIndex];
    }

    function getStakerStake(uint256 marketId, address wallet, uint256 optionIndex) external view returns (uint256) {
        Market storage m = _markets[marketId];
        if (m.shape == MarketShape.Friendly) {
            return _bets[marketId][wallet][uint8(optionIndex)];
        }
        if (m.shape == MarketShape.OpenVote) {
            if (_votedOption[marketId][wallet] == optionIndex && _hasVoted[marketId][wallet]) {
                return _votedAmount[marketId][wallet];
            }
            return 0;
        }
        return _staked[marketId][wallet][optionIndex];
    }

    function getVoteResolution(uint256 marketId) external view returns (uint256[] memory topN, uint256[] memory topNStakes, uint256 sumOfTopNStakes) {
        VoteResolution storage r = _voteResolution[marketId];
        topN = r.topN;
        topNStakes = r.topNStakes;
        sumOfTopNStakes = r.sumOfTopNStakes;
    }

    /// @notice Returns the amount `wallet` would receive from `claim(marketId)`
    ///         right now. Returns zero if not in a terminal effective state, if
    ///         already claimed, or if the wallet has nothing to claim.
    function getPendingClaim(uint256 marketId, address wallet) external view returns (uint256) {
        Market storage m = _markets[marketId];
        if (m.creator == address(0)) return 0;
        MarketState eff = _effectiveState(m, marketId);
        if (
            eff != MarketState.Resolved &&
            eff != MarketState.EmptyPoolResolved &&
            eff != MarketState.Canceled &&
            eff != MarketState.TimedOut &&
            eff != MarketState.ZeroStakeExpired
        ) return 0;

        if (wallet == treasury) {
            uint256 totalAvailable = m.feeTaken + m.dust;
            uint256 already = feeAndDustClaimed[marketId];
            if (totalAvailable <= already) return 0;
            return totalAvailable - already;
        }
        if (userClaimed[marketId][wallet]) return 0;
        return _computeUserClaim(marketId, m, wallet, eff);
    }
}
