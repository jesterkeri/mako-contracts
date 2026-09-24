// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {RoundSettlement} from "./RoundSettlement.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title MakoRoundsV1
/// @notice Creator-hosted scheduled BTC/USD rounds, settled from Chainlink Data Streams reports the
/// contract verifies on-chain.
///
/// @dev BUILT IN THREE SLICES. Slice 1 was the lifecycle and permissionless settlement, deliberately
/// money-free so the verifier-backed settlement boundary could be reviewed apart from token custody.
/// Slice 2 added entry, pools and fee accounting. Slice 3 adds every path by which money leaves.
///
///   slice 1  lifecycle, scheduling, state transitions, settlement through `RoundSettlement`
///   slice 2  entry, exact-USDC transfer semantics, pools, fee accounting, conservation
///   slice 3  finalizeRefund, claim, withdrawTreasury, the rounding remainder, reentrancy
///
/// STILL NOT DEPLOYABLE, for reasons outside this file: `onReport` (the CRE path) is unbuilt until
/// the forwarder's metadata layout is pinned; `MAX_ACTIVE_ROUNDS` is provisional until the T0.1c
/// capacity gate passes at 10 (`SPEC.md` §4); and the deferred §2 and §6 proof items plus the
/// adversarial and Codex reviews all block deployment.
///
/// WHAT THIS CONTRACT PROVES THAT THE LIBRARY CANNOT. `RoundSettlement` sees one report and one
/// boundary, so it cannot know which boundary is correct, whether settlement is early, whether the
/// round already settled, or what the current time is relative to the observation. Those are
/// properties of a round, and they live here:
///
///   - the anchor is observed at exactly `startTime` and the close at exactly `closeTime` (N25)
///   - settlement is impossible before `closeTime` and at or after `submitDeadline` (N13)
///   - a round settles at most once
///   - a report observed in the future relative to the settling block is rejected
contract MakoRoundsV1 {
    // ---------------------------------------------------------------------------------------------
    // Parameters, SPEC §4. Fixed at deployment, no setters, per SPEC §8.
    // ---------------------------------------------------------------------------------------------

    /// @notice Entries stop this long before `startTime`, so nobody can enter knowing the anchor.
    /// @dev The anchor is the report observed at exactly `startTime`, which does not exist before
    /// then, and entries stop `ENTRY_LEAD` earlier still. N25.
    uint64 public constant ENTRY_LEAD = 60;

    /// @notice `startTime` must be a whole minute, so every boundary is a minute mark. N27.
    /// @dev The availability gate measured minute marks specifically: 10,080 of 10,080 over 7 days.
    uint64 public constant BOUNDARY_STEP = 60;

    /// @notice Round length, `closeTime = startTime + DURATION`.
    uint64 public constant DURATION = 900;

    /// @notice Bounds from scheduling to `startTime`.
    uint64 public constant MIN_LEAD = 600;
    uint64 public constant MAX_LEAD = 7 days;

    /// @notice Reports may be submitted for this long after `closeTime`.
    /// @dev 24 hours, comfortably inside the 30-day window in which a report both stays acceptable
    /// to Mako (`expiresAt`) and stays fetchable from the Data Streams REST endpoint. Both were
    /// measured at exactly 30 days on 2026-09-23.
    uint64 public constant SUBMIT_WINDOW = 24 hours;

    /// @notice The most rounds that may be non-terminal at once.
    /// @dev PROVISIONAL. It stands only if the T0.1c load gate passes at 10, otherwise it is lowered
    /// before deployment.
    uint256 public constant MAX_ACTIVE_ROUNDS = 10;

    /// @notice Protocol fee and rounding-remainder recipient. Paid in slice 3.
    address public immutable TREASURY;

    /// @notice The only token this contract ever touches. `SPEC.md` §4.
    /// @dev The same token live V4 uses: 6 decimals, 1,798 bytes of code, runtime keccak256
    /// `0x96215e60…5a78`, not an ERC-1967 proxy. The deploy script asserts the address AND the code
    /// hash, per N22, because a pinned address alone does not say what is deployed at it.
    IERC20 public immutable USDC;

    /// @notice Smallest entry, 0.10 USDC. Six decimals, so 100,000.
    uint256 public constant MIN_ENTRY = 100_000;

    /// @notice 1% of the total pool, on settled rounds only.
    uint256 public constant PROTOCOL_FEE_BPS = 100;

    /// @notice 2% of the SMALLER side, on settled rounds only.
    /// @dev One rate, applied once, no multiplier. No fee formula makes self-filling unprofitable,
    /// because the thin side carries the better payout. The control is structural instead: one
    /// address, one side per round. The creator's seed is a bet under the same rules, not a fee.
    uint256 public constant CREATOR_FEE_BPS = 200;

    /// @notice keccak256 of the abi-encoded creator list the constructor was given, so a deployment
    /// receipt can be checked against the addresses that were actually authorised.
    /// @dev Solidity has no immutable arrays, so the authorised set is a constructor-populated
    /// mapping with NO setter anywhere in this contract. This hash is what makes that set auditable.
    ///
    /// THE ENCODING IS CANONICAL, which it has to be for the hash to mean anything. The constructor
    /// requires the list to be STRICTLY ASCENDING, which does three jobs at once: one set has exactly
    /// one valid encoding, so two deployments of the same creators always produce the same hash;
    /// duplicates are impossible, since a repeat is not strictly greater; and the list is trivially
    /// checkable by eye. The zero address is rejected separately. Without this, `keccak256` of a
    /// reordered list would give a different hash for the same authorised set, and the receipt would
    /// prove nothing.
    bytes32 public immutable CREATORS_HASH;

    mapping(address => bool) private _isCreator;

    // ---------------------------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------------------------

    /// @notice Stored status. The non-terminal phases are DERIVED from timestamps rather than
    /// stored, so no transaction is needed to move a round from open to locked to awaiting
    /// settlement, and no clock can drift out of step with the round's own schedule.
    enum Status {
        None,
        Active,
        Settled,
        Refunded
    }

    /// @notice The lifecycle `SPEC.md` §3 describes, computed for reading.
    enum Phase {
        None,
        Open,
        Locked,
        AwaitingSettlement,
        Settled,
        Refunded
    }

    enum Outcome {
        None,
        Up,
        Down
    }

    enum RefundReason {
        None,
        OneSided,
        Tie,
        NoPrice
    }

    enum Side {
        None,
        Up,
        Down
    }

    /// @notice One address holds at most one stake per round, on one side. N12.
    struct Stake {
        Side side;
        uint256 amount;
    }

    struct Round {
        address creator;
        uint64 openTime;
        uint64 startTime;
        Status status;
        Outcome outcome;
        RefundReason refundReason;
        int192 anchorPrice;
        int192 closePrice;
        uint32 anchorObservedAt;
        uint32 closeObservedAt;
        bytes32 anchorReportHash;
        bytes32 closeReportHash;
        // --- slice 2 ---
        uint256 upPool;
        uint256 downPool;
        /// @dev Entrant counts, one address one side, needed by slice 3's rounding remainder: the
        /// last winner to claim sweeps `distributable - sum(paid)` to the treasury, which requires
        /// knowing how many winners there are.
        uint32 upEntrants;
        uint32 downEntrants;
        /// @dev Computed once at settlement and stored, so a later claim cannot recompute them from
        /// state that has since changed. Zero on every refund: refunds pay stake and charge nothing.
        uint256 protocolFee;
        uint256 creatorFee;
        uint256 distributable;
        // --- slice 3 ---
        /// @dev How many winners have claimed, against the winning side's entrant count. The
        /// rounding remainder is known, and swept, only when the LAST winner claims.
        uint32 winnersClaimed;
        /// @dev Sum of payouts made so far. `distributable - paidOut` is the remainder.
        uint256 paidOut;
    }

    mapping(uint256 => mapping(address => Stake)) private _stakes;

    /// @notice Protocol fees and swept rounding remainders, owed to `TREASURY`.
    /// @dev One running balance rather than per round, because `withdrawTreasury` pays it all at once
    /// and nothing else may ever spend it.
    uint256 public treasuryBalance;

    /// @dev One flag per (round, address) for the stake half of `claim`, and one per round for the
    /// creator fee, so the two halves are each paid at most once and independently. N19.
    mapping(uint256 => mapping(address => bool)) private _stakeClaimed;
    mapping(uint256 => bool) private _creatorFeeClaimed;

    /// @dev 1 idle, 2 inside a value-moving call. N8 requires every value-moving function to be BOTH
    /// `nonReentrant` and balance-delta checked, because neither is sufficient alone: the guard stops
    /// a re-entrant call, the delta check stops a token that moves the wrong amount.
    uint256 private _lock = 1;

    mapping(uint256 => Round) private _rounds;

    /// @notice Ids start at 1, so zero means "no round".
    uint256 public roundCount;

    /// @notice The ids of every non-terminal round, in no particular order.
    /// @dev An index rather than a counter, because `pendingSettlement` has to LIST these rounds, and
    /// the only bounded way to list them is to keep them. The cap is `MAX_ACTIVE_ROUNDS`, so every
    /// loop over this array is bounded by a constant. Added after an adversarial review found
    /// `pendingSettlement` missing entirely: it was deferred in slice 1 because it needs pools, and
    /// then not picked up in slices 2 or 3.
    ///
    /// A round that passes `submitDeadline` without settling stays in here, holding a slot, until
    /// someone calls `finalizeRefund`, which anyone may do.
    uint256[] private _activeIds;

    /// @dev Position in `_activeIds` plus one, so zero means "not active". Used for O(1) removal.
    mapping(uint256 => uint256) private _activePos;

    /// @notice The one non-terminal round each creator may have, or zero.
    mapping(address => uint256) public creatorActiveRound;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event RoundScheduled(
        uint256 indexed roundId,
        address indexed creator,
        uint64 openTime,
        uint64 startTime,
        uint64 entryCloseTime,
        uint64 closeTime,
        uint64 submitDeadline
    );

    /// @notice N14: every settlement emits both prices, both observation seconds and both report
    /// hashes.
    /// @dev `settler` is recorded for auditability and has NO influence on the outcome. N26 requires
    /// that two different callers submitting the same valid reports produce the same result.
    event RoundSettled(
        uint256 indexed roundId,
        Outcome outcome,
        int192 anchorPrice,
        int192 closePrice,
        uint32 anchorObservedAt,
        uint32 closeObservedAt,
        bytes32 anchorReportHash,
        bytes32 closeReportHash,
        address settler
    );

    event RoundRefunded(uint256 indexed roundId, RefundReason reason);

    /// @notice A tie's settlement evidence. `SPEC.md` §5.3 and N14: both prices, both observation
    /// seconds and both report hashes are stored AND emitted on every settlement, a tie included.
    /// @dev A separate event rather than `RoundSettled` with no outcome, so a consumer can never read
    /// a refunded round as settled. Emitted immediately before `RoundRefunded(roundId, Tie)`.
    event RoundTied(
        uint256 indexed roundId,
        int192 price,
        uint32 anchorObservedAt,
        uint32 closeObservedAt,
        bytes32 anchorReportHash,
        bytes32 closeReportHash,
        address settler
    );

    event Entered(uint256 indexed roundId, address indexed entrant, Side side, uint256 amount, uint256 stakeTotal);

    /// @dev Emitted alongside `RoundSettled` so the accounting is auditable without a state read.
    event FeesAccrued(
        uint256 indexed roundId, uint256 total, uint256 protocolFee, uint256 creatorFee, uint256 distributable
    );

    event Claimed(uint256 indexed roundId, address indexed who, uint256 stakePart, uint256 creatorFeePart);
    event RemainderSwept(uint256 indexed roundId, uint256 amount);
    event TreasuryWithdrawn(address indexed to, uint256 amount);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error NotACreator();
    error StartTimeNotOnBoundary();
    error LeadTooShort();
    error LeadTooLong();
    error CreatorHasActiveRound();
    error TooManyActiveRounds();
    error NoSuchRound();
    error RoundAlreadyTerminal();
    error TooEarlyToSettle();
    error SubmitWindowClosed();
    error ObservationInFuture();
    error NoCreators();
    error ZeroAddress();
    error CreatorsNotStrictlyAscending();
    error EntriesClosed();
    error InvalidSide();
    error BelowMinimumEntry();
    error AlreadyOnTheOtherSide();
    error TransferFailed();
    error InexactTransfer(uint256 expected, uint256 received);
    error RoundIsOneSided();
    error Reentrancy();
    error NotRefundableYet();
    error RoundNotTerminal();
    error NothingOwed();
    error NotTreasury();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ---------------------------------------------------------------------------------------------

    /// @param creators the authorised creator set, STRICTLY ASCENDING and free of the zero address.
    constructor(address treasury, address usdc, address[] memory creators) {
        if (treasury == address(0)) revert ZeroAddress();
        if (usdc == address(0)) revert ZeroAddress();
        if (creators.length == 0) revert NoCreators();

        address previous = address(0);
        for (uint256 i = 0; i < creators.length; i++) {
            address c = creators[i];
            // Strictly greater than the last, so the zero address is excluded by the same comparison
            // that forbids duplicates and fixes the order. A single rule, three properties.
            if (uint160(c) <= uint160(previous)) revert CreatorsNotStrictlyAscending();
            previous = c;
            _isCreator[c] = true;
        }

        TREASURY = treasury;
        USDC = IERC20(usdc);
        CREATORS_HASH = keccak256(abi.encode(creators));
    }

    function isCreator(address who) external view returns (bool) {
        return _isCreator[who];
    }

    // ---------------------------------------------------------------------------------------------
    // Derived times. Stored once (`startTime`) and computed everywhere else, so they cannot disagree.
    // ---------------------------------------------------------------------------------------------

    function entryCloseTimeOf(uint256 roundId) public view returns (uint64) {
        return _existing(roundId).startTime - ENTRY_LEAD;
    }

    function closeTimeOf(uint256 roundId) public view returns (uint64) {
        return _existing(roundId).startTime + DURATION;
    }

    function submitDeadlineOf(uint256 roundId) public view returns (uint64) {
        return _existing(roundId).startTime + DURATION + SUBMIT_WINDOW;
    }

    /// @notice How many rounds are non-terminal right now.
    function activeRoundCount() external view returns (uint256) {
        return _activeIds.length;
    }

    /// @notice The rounds a courier should settle now. `SPEC.md` §5.1, and §5.5 step 1 makes it the
    /// keeper's and the CRE workflow's only input.
    /// @dev Rounds past `closeTime`, before `submitDeadline`, not terminal and two-sided. At most
    /// `MAX_ACTIVE_ROUNDS` of them by construction, since it filters the active index, so the loop is
    /// bounded by a constant and the view cannot become too expensive to call.
    ///
    /// "Two-sided" matters: a one-sided round can never settle (`SPEC.md:135`), so listing it would
    /// send a courier to fetch reports for a call that must revert.
    function pendingSettlement() external view returns (uint256[] memory ids) {
        uint256 n = _activeIds.length;
        uint256[] memory buf = new uint256[](n);
        uint256 k;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = _activeIds[i];
            Round storage r = _rounds[id];
            uint64 closeTime = r.startTime + DURATION;
            if (
                block.timestamp >= closeTime && block.timestamp < closeTime + SUBMIT_WINDOW && r.upPool != 0
                    && r.downPool != 0
            ) buf[k++] = id;
        }
        ids = new uint256[](k);
        for (uint256 i = 0; i < k; i++) {
            ids[i] = buf[i];
        }
    }

    function roundOf(uint256 roundId) external view returns (Round memory) {
        return _existing(roundId);
    }

    /// @notice The lifecycle position of a round right now.
    function phaseOf(uint256 roundId) public view returns (Phase) {
        Round storage r = _existing(roundId);
        if (r.status == Status.Settled) return Phase.Settled;
        if (r.status == Status.Refunded) return Phase.Refunded;
        if (block.timestamp >= r.startTime + DURATION) return Phase.AwaitingSettlement;
        if (block.timestamp >= r.startTime - ENTRY_LEAD) return Phase.Locked;
        return Phase.Open;
    }

    // ---------------------------------------------------------------------------------------------
    // Scheduling
    // ---------------------------------------------------------------------------------------------

    /// @notice Schedules a round. Creators only, per SPEC §8.
    /// @param startTime the anchor boundary second. Must be a whole minute, N27.
    function schedule(uint64 startTime) external returns (uint256 roundId) {
        if (!_isCreator[msg.sender]) revert NotACreator();
        if (startTime % BOUNDARY_STEP != 0) revert StartTimeNotOnBoundary();

        uint64 openTime = uint64(block.timestamp);
        // Checked against openTime rather than startTime so an overflow in `openTime + MAX_LEAD`
        // cannot widen the window.
        if (startTime < openTime + MIN_LEAD) revert LeadTooShort();
        if (startTime > openTime + MAX_LEAD) revert LeadTooLong();

        if (creatorActiveRound[msg.sender] != 0) revert CreatorHasActiveRound();
        if (_activeIds.length >= MAX_ACTIVE_ROUNDS) revert TooManyActiveRounds();

        roundId = ++roundCount;
        _rounds[roundId] = Round({
            creator: msg.sender,
            openTime: openTime,
            startTime: startTime,
            status: Status.Active,
            outcome: Outcome.None,
            refundReason: RefundReason.None,
            anchorPrice: 0,
            closePrice: 0,
            anchorObservedAt: 0,
            closeObservedAt: 0,
            anchorReportHash: bytes32(0),
            closeReportHash: bytes32(0),
            upPool: 0,
            downPool: 0,
            upEntrants: 0,
            downEntrants: 0,
            protocolFee: 0,
            creatorFee: 0,
            distributable: 0,
            winnersClaimed: 0,
            paidOut: 0
        });

        creatorActiveRound[msg.sender] = roundId;
        _activeIds.push(roundId);
        _activePos[roundId] = _activeIds.length;

        emit RoundScheduled(
            roundId,
            msg.sender,
            openTime,
            startTime,
            startTime - ENTRY_LEAD,
            startTime + DURATION,
            startTime + DURATION + SUBMIT_WINDOW
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Entry
    // ---------------------------------------------------------------------------------------------

    function stakeOf(uint256 roundId, address who) external view returns (Stake memory) {
        return _stakes[roundId][who];
    }

    /// @notice Stakes USDC on one side of a round. Anyone, until `entryCloseTime`.
    ///
    /// @dev N22, and the reason this is not a plain `transferFrom`: ONLY EXACT USDC IS CREDITED. The
    /// contract records its own balance, moves the tokens through a safe-call wrapper, and requires
    /// the balance increase to equal `amount` exactly, BEFORE any state is written. A fee-on-transfer
    /// token, a rebasing token, or a token that silently moves less all fail here rather than
    /// crediting a stake the contract does not hold. Tokens arriving any other way are never credited
    /// to anyone, because only this path writes a stake.
    ///
    /// N12, and it is a market-integrity control rather than bookkeeping: one address, one side. No
    /// fee formula can make a creator self-filling both sides unprofitable, since the thin side
    /// carries the better payout. Forbidding the same wallet from taking both sides is the control
    /// that actually bites.
    function enter(uint256 roundId, Side side, uint256 amount) external nonReentrant {
        Round storage r = _existing(roundId);

        if (side != Side.Up && side != Side.Down) revert InvalidSide();
        // Same condition as the one in `_settle`, deliberately written with its own comment so each
        // can be mutated independently: an identical line in two places is one line to a mutation
        // runner, and the sweep correctly refused to apply an ambiguous anchor rather than report a
        // false kill.
        if (r.status != Status.Active) revert RoundAlreadyTerminal(); // entry guard
        // N2. Entries stop ENTRY_LEAD before the anchor second exists, so no entrant can have seen
        // the opening price. Strictly `>=`: the boundary second itself is closed.
        if (block.timestamp >= r.startTime - ENTRY_LEAD) revert EntriesClosed();
        if (amount < MIN_ENTRY) revert BelowMinimumEntry();

        Stake storage stake = _stakes[roundId][msg.sender];
        if (stake.side != Side.None && stake.side != side) revert AlreadyOnTheOtherSide();

        // --- value moves BEFORE any state is written, and is checked exactly -------------------
        uint256 before = USDC.balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = USDC.balanceOf(address(this)) - before;
        if (received != amount) revert InexactTransfer(amount, received);

        if (stake.side == Side.None) {
            stake.side = side;
            if (side == Side.Up) r.upEntrants++;
            else r.downEntrants++;
        }
        stake.amount += amount;

        if (side == Side.Up) r.upPool += amount;
        else r.downPool += amount;

        emit Entered(roundId, msg.sender, side, amount, stake.amount);
    }

    /// @dev A call that reverts, returns `false`, or returns malformed data fails. A call that
    /// returns nothing is accepted here and caught by the balance check instead, which is what makes
    /// a no-return legacy token usable without trusting it.
    function _safeTransferFrom(address from, address to, uint256 amount) private {
        (bool ok, bytes memory data) = address(USDC).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!ok) revert TransferFailed();
        // Length is checked explicitly rather than left to `abi.decode` to panic on, so a malformed
        // return fails with this contract's own error instead of a bare Panic.
        if (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool)))) revert TransferFailed(); // inbound
    }

    // ---------------------------------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------------------------------

    /// @notice Settles a round from two Data Streams reports. ANYONE may call this, per SPEC §8.
    ///
    /// @dev The caller supplies bytes and nothing else. They choose no outcome, no price and no
    /// verifier: the reports are verified on-chain against the pinned `VERIFIER_PROXY`, and
    /// everything else is derived. N26.
    ///
    /// @param roundId the round
    /// @param anchorReport the full report observed at exactly `startTime`
    /// @param closeReport the full report observed at exactly `closeTime`
    /// @dev `nonReentrant` although it moves no value. `settle` calls the verifier twice BEFORE it
    /// writes anything, so a verifier that re-entered `settle` would run a complete inner settlement
    /// under the outer one's already-passed status check: the protocol fee would accrue twice and the
    /// slot would be released twice. That needs a compromised verifier, which could already lie about
    /// prices, so it adds nothing to that trust assumption; but it is the kind of double-count a
    /// cheap guard removes outright rather than leaving to an argument. Raised by the adversarial
    /// review as an unproven suspicion, and proven by `test_SettleIsNotReentrant`.
    function settle(uint256 roundId, bytes calldata anchorReport, bytes calldata closeReport) external nonReentrant {
        _settle(roundId, anchorReport, closeReport);
    }

    function _settle(uint256 roundId, bytes calldata anchorReport, bytes calldata closeReport) internal {
        Round storage r = _existing(roundId);

        // --- round-level guards, none of which the library can make ---------------------------
        if (r.status != Status.Active) revert RoundAlreadyTerminal(); // settlement guard

        uint64 closeTime = r.startTime + DURATION;
        if (block.timestamp < closeTime) revert TooEarlyToSettle();
        // N13: settle and finalizeRefund(NoPrice) windows never overlap.
        if (block.timestamp >= closeTime + SUBMIT_WINDOW) revert SubmitWindowClosed();

        // `SPEC.md:135`: a one-sided round is OneSided (§6) and must NEVER settle, whatever the
        // price (N3). Slice 1 named this line and could not write it, having no pools.
        //
        // It is also what closes the only race worth worrying about between `settle` and
        // `finalizeRefund`. `finalizeRefund(OneSided)` is available from `entryCloseTime`, which
        // overlaps the settle window, so without this both could apply to one round at one moment.
        // With it they are mutually exclusive BY THEIR OWN CONDITIONS rather than by who calls
        // first: a one-sided round cannot settle, and a two-sided round cannot refund as OneSided.
        // `finalizeRefund(NoPrice)` starts at `submitDeadline`, where the guard above has already
        // closed settlement, so those two are disjoint in time instead.
        if (r.upPool == 0 || r.downPool == 0) revert RoundIsOneSided();

        // --- the rule, once per report, at ITS OWN boundary -------------------------------------
        // Passing the boundaries here is what ties a report to this round. The library checks that
        // a report was observed at the boundary it is given; only the contract knows which boundary
        // is the right one. N25: the anchor's boundary is `startTime`, which is `ENTRY_LEAD` after
        // the last possible entry, so no entrant can have seen it.
        RoundSettlement.Report memory anchor = RoundSettlement.check(anchorReport, uint32(r.startTime));
        RoundSettlement.Report memory close = RoundSettlement.check(closeReport, uint32(closeTime));

        // --- the check the library deliberately does not make -----------------------------------
        // `RoundSettlement` takes no current-time input, so it accepts a report observed in the
        // future. Here it is rejected. It is implied by the guards above, since both boundaries are
        // at or before `closeTime` and `block.timestamp >= closeTime`, but it is asserted rather
        // than inferred so it survives any later change to those guards and so the property has a
        // test of its own. `VERIFICATION.md` hands this to T1.1 by name.
        if (
            uint256(anchor.observationsTimestamp) > block.timestamp
                || uint256(close.observationsTimestamp) > block.timestamp
        ) revert ObservationInFuture();

        // --- outcome, derived and never supplied -------------------------------------------------
        r.anchorPrice = anchor.price;
        r.closePrice = close.price;
        r.anchorObservedAt = anchor.observationsTimestamp;
        r.closeObservedAt = close.observationsTimestamp;
        r.anchorReportHash = keccak256(anchorReport);
        r.closeReportHash = keccak256(closeReport);

        _releaseSlot(roundId, r);

        if (close.price == anchor.price) {
            // A tie refunds, and a refund charges NOTHING: every entrant receives exactly their
            // stake, so `protocolFee`, `creatorFee` and `distributable` all stay zero and
            // `sum(refunds) == total` by construction. The payout path is slice 3.
            r.status = Status.Refunded;
            r.refundReason = RefundReason.Tie;
            // The evidence is emitted, not only stored: an adversarial review found the tie branch
            // emitting nothing but the refund reason. Both prices are equal, so one is enough.
            emit RoundTied(
                roundId,
                anchor.price,
                anchor.observationsTimestamp,
                close.observationsTimestamp,
                r.anchorReportHash,
                r.closeReportHash,
                msg.sender
            );
            emit RoundRefunded(roundId, RefundReason.Tie);
            return;
        }

        Outcome outcome = close.price > anchor.price ? Outcome.Up : Outcome.Down;
        r.status = Status.Settled;
        r.outcome = outcome;

        // --- fees, computed ONCE and stored, SPEC §7 -------------------------------------------
        // Stored rather than recomputed on each claim, so a later claim cannot derive a different
        // answer from state that has moved. Both floors, so neither fee can exceed its base, and
        // `distributable` absorbs the truncation. The rounding remainder inside `distributable` is
        // swept to the treasury by the last winner to claim, in slice 3.
        uint256 total = r.upPool + r.downPool;
        uint256 smaller = r.upPool < r.downPool ? r.upPool : r.downPool;
        uint256 protocolFee = (total * PROTOCOL_FEE_BPS) / 10_000;
        uint256 creatorFee = (smaller * CREATOR_FEE_BPS) / 10_000;

        r.protocolFee = protocolFee;
        r.creatorFee = creatorFee;
        r.distributable = total - protocolFee - creatorFee;

        // The protocol fee is owed to the treasury the moment the round settles. The creator fee is
        // NOT added here: it belongs to the creator and leaves only through their `claim`.
        treasuryBalance += protocolFee;

        emit FeesAccrued(roundId, total, protocolFee, creatorFee, r.distributable);

        emit RoundSettled(
            roundId,
            outcome,
            anchor.price,
            close.price,
            anchor.observationsTimestamp,
            close.observationsTimestamp,
            r.anchorReportHash,
            r.closeReportHash,
            msg.sender
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Refunds
    // ---------------------------------------------------------------------------------------------

    /// @notice Moves a round to REFUNDED when it can never settle. Anyone may call it, per SPEC §8.
    ///
    /// @dev Two reasons, and neither can overlap with settlement:
    ///   OneSided  from `entryCloseTime`, when either pool is empty. Pools cannot change after
    ///             `entryCloseTime`, so this depends on pool sizes alone. `settle` refuses a
    ///             one-sided round outright, so the two are mutually exclusive BY CONDITION. N3.
    ///   NoPrice   from `submitDeadline`, when the round is still not terminal. `settle` reverts at
    ///             `submitDeadline`, so the two are disjoint IN TIME. N13.
    /// A Tie is not here: it is decided inside `settle`, because it needs the prices.
    ///
    /// N5: this is what stops funds being stuck past `submitDeadline`. It is also the ONLY thing
    /// that frees a capacity slot from a round nobody settled, which is why it being permissionless
    /// matters beyond convenience: anyone can unjam the contract, not only the creator who walked
    /// away. No fees on any refund, so `sum(refunds) == total` by construction.
    function finalizeRefund(uint256 roundId) external {
        Round storage r = _existing(roundId);
        if (r.status != Status.Active) revert RoundAlreadyTerminal(); // refund guard

        RefundReason reason;
        if (block.timestamp >= r.startTime - ENTRY_LEAD && (r.upPool == 0 || r.downPool == 0)) {
            reason = RefundReason.OneSided;
        } else if (block.timestamp >= r.startTime + DURATION + SUBMIT_WINDOW) {
            reason = RefundReason.NoPrice;
        } else {
            revert NotRefundableYet();
        }

        _releaseSlot(roundId, r);
        r.status = Status.Refunded;
        r.refundReason = reason;
        emit RoundRefunded(roundId, reason);
    }

    // ---------------------------------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------------------------------

    /// @notice Pays the caller everything they are owed on one round, in one call.
    ///
    /// @dev Two independent parts, each payable at most once (N19):
    ///   - their payout if they backed the winning side, or their whole stake if the round refunded
    ///   - the creator fee, if they are this round's creator and it SETTLED
    /// A creator who never entered can call this for the fee alone. A loser is owed nothing, and the
    /// call reverts rather than succeeding with a zero transfer, as SPEC §7 requires.
    ///
    /// Pull, never push: nothing is sent unprompted, so one recipient that cannot receive can never
    /// block anyone else's money.
    function claim(uint256 roundId) external nonReentrant {
        Round storage r = _existing(roundId);
        if (r.status != Status.Settled && r.status != Status.Refunded) revert RoundNotTerminal();

        uint256 stakePart;
        uint256 feePart;

        Stake storage stake = _stakes[roundId][msg.sender];
        if (stake.amount != 0 && !_stakeClaimed[roundId][msg.sender]) {
            if (r.status == Status.Refunded) {
                // Exactly the stake, whatever the reason. No fees on a refund.
                stakePart = stake.amount;
                _stakeClaimed[roundId][msg.sender] = true;
            } else if (stake.side == (r.outcome == Outcome.Up ? Side.Up : Side.Down)) {
                uint256 winningPool = r.outcome == Outcome.Up ? r.upPool : r.downPool;
                // Floored per winner, per SPEC §7. The truncation accumulates as the remainder.
                stakePart = (stake.amount * r.distributable) / winningPool;
                _stakeClaimed[roundId][msg.sender] = true;
                r.paidOut += stakePart;

                uint32 winners = r.outcome == Outcome.Up ? r.upEntrants : r.downEntrants;
                if (++r.winnersClaimed == winners) {
                    // THE LAST WINNER SWEEPS THE REMAINDER. Only now is it known, since a floor was
                    // taken per winner. A winner who never claims holds this back indefinitely:
                    // their money is unclaimed, not stuck, and the remainder waits for them. SPEC §7
                    // authorises no timer that would take it sooner.
                    uint256 remainder = r.distributable - r.paidOut;
                    if (remainder != 0) {
                        treasuryBalance += remainder;
                        emit RemainderSwept(roundId, remainder);
                    }
                }
            }
            // A loser: nothing marked, nothing paid. They simply have no claim on the stake half.
        }

        if (r.status == Status.Settled && msg.sender == r.creator && !_creatorFeeClaimed[roundId]) {
            feePart = r.creatorFee;
            _creatorFeeClaimed[roundId] = true;
        }

        uint256 owed = stakePart + feePart;
        if (owed == 0) revert NothingOwed();

        // Every flag above is written BEFORE the transfer: checks, effects, then the interaction.
        // `nonReentrant` is the second line of defence, not the only one.
        _safeTransferOut(msg.sender, owed);
        emit Claimed(roundId, msg.sender, stakePart, feePart);
    }

    /// @notice Whether an address's stake half has been claimed, and whether a round's creator fee
    /// has been. For clients and for the watchdog.
    function stakeClaimed(uint256 roundId, address who) external view returns (bool) {
        return _stakeClaimed[roundId][who];
    }

    function creatorFeeClaimed(uint256 roundId) external view returns (bool) {
        return _creatorFeeClaimed[roundId];
    }

    // ---------------------------------------------------------------------------------------------
    // Treasury
    // ---------------------------------------------------------------------------------------------

    /// @notice Sends accrued protocol fees and swept remainders to `TREASURY`.
    /// @dev `TREASURY` only, and to `TREASURY` only: the destination is the immutable rather than a
    /// parameter, so even the treasury key cannot send the money anywhere else. N19.
    function withdrawTreasury() external nonReentrant {
        if (msg.sender != TREASURY) revert NotTreasury();
        uint256 amount = treasuryBalance;
        if (amount == 0) revert NothingOwed();
        treasuryBalance = 0;
        _safeTransferOut(TREASURY, amount);
        emit TreasuryWithdrawn(TREASURY, amount);
    }

    /// @dev The mirror of `_safeTransferFrom`, and checked the same way. A token that sends less than
    /// asked would leave the accounting right and the balance wrong, surfacing much later as a claim
    /// that cannot be paid. State is already written when this runs, so it reverts the whole call.
    function _safeTransferOut(address to, uint256 amount) private {
        uint256 before = USDC.balanceOf(address(this));
        (bool ok, bytes memory data) = address(USDC).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) revert TransferFailed();
        if (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool)))) revert TransferFailed(); // outbound
        uint256 sent = before - USDC.balanceOf(address(this));
        if (sent != amount) revert InexactTransfer(amount, sent);
    }

    // ---------------------------------------------------------------------------------------------

    function _existing(uint256 roundId) private view returns (Round storage r) {
        r = _rounds[roundId];
        if (r.status == Status.None) revert NoSuchRound();
    }

    /// @dev A round leaving the non-terminal set frees both the global slot and its creator's.
    /// Swap-and-pop, so removal is O(1) and the array never has holes. Checked arithmetic on the
    /// position means releasing a round that is not in the set reverts rather than corrupting the
    /// index, which is a second line of defence behind the terminal-state guards.
    function _releaseSlot(uint256 roundId, Round storage r) private {
        creatorActiveRound[r.creator] = 0;
        uint256 pos = _activePos[roundId] - 1;
        uint256 last = _activeIds[_activeIds.length - 1];
        _activeIds[pos] = last;
        _activePos[last] = pos + 1;
        _activeIds.pop();
        delete _activePos[roundId];
    }
}
