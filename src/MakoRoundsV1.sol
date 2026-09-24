// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {RoundSettlement} from "./RoundSettlement.sol";

/// @title MakoRoundsV1
/// @notice Creator-hosted scheduled BTC/USD rounds, settled from Chainlink Data Streams reports the
/// contract verifies on-chain.
///
/// @dev SLICE 1 OF 3, AND DELIBERATELY MONEY-FREE. This slice is the round lifecycle and
/// permissionless settlement, and it holds no tokens, moves no value and has no entry, claim, refund
/// payout or treasury path. That isolates the security-critical new trust boundary, a verifier-backed
/// settlement, from token custody, so the two can be reviewed separately.
///
///   slice 1  lifecycle, scheduling, state transitions, settlement through `RoundSettlement`
///   slice 2  entry, exact-USDC transfer semantics, pools, fees, conservation
///   slice 3  claims, refund payouts, treasury withdrawal, reentrancy boundaries
///
/// Nothing here is deployable on its own. `MAX_ACTIVE_ROUNDS` is also provisional until the T0.1c
/// capacity gate passes at 10 (`SPEC.md` §4).
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

    /// @notice Protocol fee and rounding-remainder recipient. Unused in slice 1; no value moves.
    address public immutable TREASURY;

    /// @notice keccak256 of the abi-encoded creator list the constructor was given, so a deployment
    /// receipt can be checked against the addresses that were actually authorised.
    /// @dev Solidity has no immutable arrays, so the authorised set is a constructor-populated
    /// mapping with NO setter anywhere in this contract. This hash is what makes that set auditable.
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
    }

    mapping(uint256 => Round) private _rounds;

    /// @notice Ids start at 1, so zero means "no round".
    uint256 public roundCount;

    /// @notice How many rounds are non-terminal. Incremented by `schedule`, decremented by a
    /// terminal transition.
    /// @dev A round that passes `submitDeadline` without settling stays non-terminal, and therefore
    /// holds a slot, until someone calls `finalizeRefund` (slice 3). That call is permissionless and
    /// the creator is motivated to make it, but it means an abandoned round occupies capacity until
    /// somebody spends the gas. Recorded rather than designed around.
    uint256 public activeRoundCount;

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

    // ---------------------------------------------------------------------------------------------

    constructor(address treasury, address[] memory creators) {
        if (treasury == address(0)) revert NoCreators();
        if (creators.length == 0) revert NoCreators();
        TREASURY = treasury;
        CREATORS_HASH = keccak256(abi.encode(creators));
        for (uint256 i = 0; i < creators.length; i++) {
            _isCreator[creators[i]] = true;
        }
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
        if (activeRoundCount >= MAX_ACTIVE_ROUNDS) revert TooManyActiveRounds();

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
            closeReportHash: bytes32(0)
        });

        creatorActiveRound[msg.sender] = roundId;
        unchecked {
            activeRoundCount++;
        }

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
    function settle(uint256 roundId, bytes calldata anchorReport, bytes calldata closeReport) external {
        _settle(roundId, anchorReport, closeReport);
    }

    function _settle(uint256 roundId, bytes calldata anchorReport, bytes calldata closeReport) internal {
        Round storage r = _existing(roundId);

        // --- round-level guards, none of which the library can make ---------------------------
        if (r.status != Status.Active) revert RoundAlreadyTerminal();

        uint64 closeTime = r.startTime + DURATION;
        if (block.timestamp < closeTime) revert TooEarlyToSettle();
        // N13: settle and finalizeRefund(NoPrice) windows never overlap.
        if (block.timestamp >= closeTime + SUBMIT_WINDOW) revert SubmitWindowClosed();

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

        _releaseSlot(r);

        if (close.price == anchor.price) {
            // A tie refunds. In slice 1 that is a state transition and an event; the payout path is
            // slice 3.
            r.status = Status.Refunded;
            r.refundReason = RefundReason.Tie;
            emit RoundRefunded(roundId, RefundReason.Tie);
            return;
        }

        Outcome outcome = close.price > anchor.price ? Outcome.Up : Outcome.Down;
        r.status = Status.Settled;
        r.outcome = outcome;

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

    function _existing(uint256 roundId) private view returns (Round storage r) {
        r = _rounds[roundId];
        if (r.status == Status.None) revert NoSuchRound();
    }

    /// @dev A round leaving the non-terminal set frees both the global slot and its creator's.
    function _releaseSlot(Round storage r) private {
        creatorActiveRound[r.creator] = 0;
        unchecked {
            activeRoundCount--;
        }
    }
}
