// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IVerifierProxy} from "./interfaces/IVerifierProxy.sol";

/// @title RoundSettlement
/// @notice The rule that decides whether a Chainlink Data Streams report may settle a Mako round.
///
/// Implements SPEC §5.2's seven checks and nothing else. It returns a verified report or reverts. It
/// derives no outcome and takes no price: UP, DOWN and Tie belong to `MakoRoundsV1`.
///
/// @dev THE VERIFIER IS A CONSTANT, NOT A PARAMETER, and that is the single most important line in
/// this file. An earlier draft took `(address verifier, bytes, uint64)` and read both
/// `s_feeManager()` and `verify()` from that argument. An adversarial review built exactly that and
/// settled a $1,000,000 BTC price from `fullReport = 0xdead`, passing all seven checks, using a
/// sixty-line `EvilVerifier` that returned whatever it liked. Checks 3 and
/// `test_DecodesVerifiedBytesNotInput` exist for no other purpose than to stop that, and they cannot
/// if the caller chooses the verifier. `SPEC.md:78` pins `VERIFIER_PROXY` in the constants table
/// beside `FEED_ID`, and §5.2 names the constant, never a parameter.
///
/// Consequence for tests: a mock verifier cannot be passed in, so every mock case places the mock's
/// code AT THIS ADDRESS with `vm.etch`. That is strictly better evidence, because each mock test
/// then exercises the shipping call path rather than a parameterised variant of it.
library RoundSettlement {
    // ---------------------------------------------------------------------------------------------
    // Constants, pinned from blueprint/SPEC.md
    // ---------------------------------------------------------------------------------------------

    /// @notice Chainlink's Data Streams verifier proxy on Monad testnet. `SPEC.md:78`.
    /// @dev Chainlink's own docs listed `0xC539…A4a1` until they were corrected on 2026-09-17; that
    /// address has no code. This one is verified: `VerifierProxy 2.0.0`, 7,009 bytes, runtime
    /// keccak256 `0x4bd86e89…c022b`, both managers zero, read through two distinct operators
    /// (QuickNode and Monad Foundation) at block 62922075 on 2026-09-23.
    address internal constant VERIFIER_PROXY = 0x72790f9eB82db492a7DDb6d2af22A270Dcc3Db64;

    /// @notice BTC/USD on Monad testnet, Data Streams v3. `SPEC.md:77`.
    /// @dev Its first two bytes are `0x0003`, which is the schema prefix step 3 checks. The prefix
    /// and the feed id are THE SAME BYTES: the verified payload's word 0 is the feed id. So step 4
    /// logically implies step 3, and no input can ever have the correct feed with a wrong prefix.
    /// Step 3 is therefore an ordering and error-specificity guarantee, not an admission control.
    bytes32 internal constant FEED_ID = 0x00037da06d56d083fe599397a4769a042d63aa73dc4ef57709d31e9971a5b439;

    /// @notice Maximum bid/ask spread, in basis points. `SPEC.md:75-93`.
    /// @dev Measured BTC/USD spreads are far inside this: 1.17 bps on the 2026-09-16 fixture.
    uint256 internal constant MAX_SPREAD_BPS = 50;

    /// @notice Data Streams v3 prices carry 18 decimals.
    /// @dev Recorded for `MakoRoundsV1`'s arithmetic. NOTHING HERE CHECKS IT: the schema fixes it,
    /// and a report claiming a different scale would be a different schema, rejected at step 3.
    uint8 internal constant PRICE_DECIMALS = 18;

    /// @notice The exact byte length of a verified v3 payload.
    /// @dev The RAW `eth_call` return is 352 bytes: 32 offset + 32 length + this. A check comparing
    /// 288 against a raw RPC result rejects every real report. Inside Solidity `verify` returns
    /// `bytes memory` already unwrapped, so 288 is the right number here.
    uint256 internal constant VERIFIED_LENGTH = 288;

    /// @notice Schema v3 prefix, the first two bytes of the verified payload. `SPEC.md:115-136`.
    bytes2 internal constant SCHEMA_V3 = 0x0003;

    // ---------------------------------------------------------------------------------------------
    // Errors. Each check has its own, because a bare revert passes on any failure including a typo,
    // and would let a check be deleted with the test still green.
    // ---------------------------------------------------------------------------------------------

    error FeeManagerEnabled(); // 0x47d64799
    error WrongSchema(); // 0x21b8eeb9
    error WrongFeed(); // 0x9ae97d9b
    error WrongObservationTime(); // 0xfecd62a4
    error ValidFromAfterObservation(); // 0xbb3c6d04
    error NonPositivePrice(); // 0x13caeeae
    error BidAskOutOfOrder(); // 0xb937a957
    error SpreadTooWide(); // 0xa4f46d5d
    error ReportExpired(); // 0x69458111

    /// @notice A decoded Data Streams v3 report.
    struct Report {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 price;
        int192 bid;
        int192 ask;
    }

    /// @notice Runs SPEC §5.2's seven checks against a Data Streams report for a boundary second.
    ///
    /// @dev NOT `view`. `IVerifierProxy.verify` is payable and non-view on the real proxy, and solc
    /// refuses a `view` function that calls it. That is correct rather than merely tolerated:
    /// `MakoRoundsV1` calls this from inside a settlement transaction, so nothing here ever wanted
    /// `view`. The `view` is deliberately NOT moved onto the interface to rescue the signature: our
    /// `eth_call` probes show only that this path happens not to write while `s_feeManager()` is
    /// zero, and a `staticcall` design would be a standing claim about somebody else's upgradeable
    /// contract.
    ///
    /// @param fullReport the 736-byte v3 report exactly as Data Streams served it. ATTACKER-CHOSEN.
    /// @param boundary the round boundary second `B`. ATTACKER-CHOSEN by `MakoRoundsV1`'s caller;
    ///        `uint32` to match the report's own `observationsTimestamp`, because a wider boundary
    ///        above `2**32 - 1` could never match and would fail silently.
    /// @return r the decoded report, trusted only after all seven checks pass.
    function check(bytes calldata fullReport, uint32 boundary) internal returns (Report memory r) {
        // --- step 1: the fee manager, BEFORE verify -------------------------------------------
        // Ordering is load-bearing, not stylistic. A fee manager would break settlement outright
        // (`KNOWN-LIMITS.md` 21), and reaching `verify` first would engage fee handling before we
        // ever noticed.
        if (IVerifierProxy(VERIFIER_PROXY).s_feeManager() != address(0)) revert FeeManagerEnabled();

        // --- step 2: verify, with an EMPTY parameter payload ------------------------------------
        // A non-empty `parameterPayload` engages fee handling. `SPEC.md:118`.
        bytes memory verified = IVerifierProxy(VERIFIER_PROXY).verify(fullReport, "");

        // --- step 3: shape, before anything is decoded ------------------------------------------
        // Only `verified` is ever decoded. The submitted bytes are never read again: a library that
        // decoded its input would accept whatever the caller wrote, which is the whole attack.
        if (verified.length != VERIFIED_LENGTH) revert WrongSchema();

        bytes32 firstWord;
        // The first word is the feed id, whose leading two bytes are the schema prefix. Read
        // directly rather than decoding, so the prefix is checked before any ABI decoding runs.
        assembly ("memory-safe") {
            firstWord := mload(add(verified, 32))
        }
        if (bytes2(firstWord) != SCHEMA_V3) revert WrongSchema();

        (
            bytes32 feedId,
            uint32 validFromTimestamp,
            uint32 observationsTimestamp,
            uint192 nativeFee,
            uint192 linkFee,
            uint32 expiresAt,
            int192 price,
            int192 bid,
            int192 ask
        ) = abi.decode(verified, (bytes32, uint32, uint32, uint192, uint192, uint32, int192, int192, int192));

        // --- step 4: the feed --------------------------------------------------------------------
        if (feedId != FEED_ID) revert WrongFeed();

        // --- step 5: the observation second, and a window that may start early but never late ----
        if (observationsTimestamp != boundary) revert WrongObservationTime();
        if (validFromTimestamp > observationsTimestamp) revert ValidFromAfterObservation();

        // --- step 6: sanity ----------------------------------------------------------------------
        if (price <= 0) revert NonPositivePrice();
        if (bid > price || price > ask) revert BidAskOutOfOrder();

        // The difference is widened to int256 BEFORE it is taken. `ask - bid` in int192 overflows
        // for the maximum-integer case N11 mandates (bid = int192.min, ask = int192.max), which
        // panics with 0x11 and never reaches this check, so the test would pass for the wrong
        // reason. Widening first cannot overflow, because both operands fit in int192 and int256
        // has 64 bits of headroom. The result is non-negative here, since `bid <= price <= ask`
        // was just established, so the uint256 cast is safe. This is why §5.2 names uint256.
        uint256 spread = uint256(int256(ask) - int256(bid));
        if (spread * 10_000 > uint256(int256(price)) * MAX_SPREAD_BPS) revert SpreadTooWide();

        // --- step 7: expiry, which the verifier does NOT enforce ----------------------------------
        // Measured 2026-09-22: a report three days past `expiresAt` still returns 352 bytes from the
        // real `VerifierProxy` at `latest`. `verify` authenticates signatures against a registered
        // configuration; it does not check expiry at all. THIS LINE IS THE ONLY EXPIRY DEFENCE
        // ANYWHERE IN THIS SYSTEM.
        if (block.timestamp > expiresAt) revert ReportExpired();

        r = Report({
            feedId: feedId,
            validFromTimestamp: validFromTimestamp,
            observationsTimestamp: observationsTimestamp,
            nativeFee: nativeFee,
            linkFee: linkFee,
            expiresAt: expiresAt,
            price: price,
            bid: bid,
            ask: ask
        });
    }
}
