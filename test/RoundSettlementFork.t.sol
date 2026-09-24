// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {RoundSettlement} from "../src/RoundSettlement.sol";
import {IVerifierProxy} from "../src/interfaces/IVerifierProxy.sol";
import {RoundSettlementHarness} from "./RoundSettlementHarness.sol";

/// @notice The shipping rule, against the REAL Chainlink VerifierProxy, on a Monad testnet fork, with
/// the real captured report `INVARIANTS.md:12` requires by name.
///
/// PROOF_STANDARD.md Version 3 Type **B2**. Every other test of the rule substitutes a `MockVerifier`
/// at the proxy address, which proves the mock and the library agree and nothing more. This is the
/// only place the library meets Chainlink's actual contract, so it is the only evidence that the
/// library accepts what the real verifier returns.
///
/// @dev ENV-GUARDED so offline CI stays green: without `MAKO_FORK_RPC` every test here SKIPS, with a
/// visible reason. A skipped fork test is not a passing one, and the evidence record says so. Run it:
///
///   MAKO_FORK_RPC=https://testnet-rpc.monad.xyz/      forge test --network monad --match-contract RoundSettlementFork -vvv
///   MAKO_FORK_RPC=https://rpc-testnet.monadinfra.com  forge test --network monad --match-contract RoundSettlementFork -vvv
///
/// `--network monad` is REQUIRED: Foundry 1.8 instantiates a per-family EVM and refuses to create a
/// Monad fork on the default Ethereum one ("cannot create a `monad` fork with an EVM instantiated for
/// `ethereum`").
///
/// Those are two distinct operators (QuickNode and Monad Foundation, per Monad's own documentation),
/// so running both is a B2 claim across two failure domains.
///
/// Missing from the first cut of this branch entirely, although the corpus, the rule test and the
/// evidence record all claimed it existed. The Codex diff review caught that.
contract RoundSettlementForkTest is Test {
    using stdJson for string;

    address internal constant VERIFIER = 0x72790f9eB82db492a7DDb6d2af22A270Dcc3Db64;
    bytes32 internal constant VERIFIER_CODE_KECCAK = 0x4bd86e898b2952f6f0d20fee037accf52490dbdd9279345cd4b0a7161b5c022b;

    /// The mandatory widened-window fixture and the block whose timestamp is its observation second.
    uint256 internal constant FORK_BLOCK = 62922075;
    uint32 internal constant B = 1789529160; // 2026-09-16 03:26:00 UTC
    uint32 internal constant VALID_FROM = 1789529157; // 03:25:57, a genuine three-second window
    uint32 internal constant EXPIRES_AT = 1792121160; // exactly 30 days after observation
    int192 internal constant PRICE = 75938791787880000000000;
    int192 internal constant BID = 75935199000000000000000;
    int192 internal constant ASK = 75944083700820000000000;

    /// @notice Ceilings from the approved plan, on the thing that ships: the whole `check()`, not only
    /// the inner `verify`. `MakoRoundsV1.settle` calls `check()` twice inside a 1,000,000 budget.
    /// @dev A `gasleft()` delta inside the harness: excludes the 21,000 intrinsic and calldata costs an
    /// `eth_estimateGas` figure includes, includes EIP-2929 cold access. Not comparable with the
    /// 103,053-105,299 estimateGas figure in `SPEC.md:156`, which is a different quantity.
    uint256 internal constant CHECK_GAS_CEILING = 150_000;

    RoundSettlementHarness internal harness;
    bytes internal fullReport;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAKO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return; // each test skips visibly below
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;

        harness = new RoundSettlementHarness();
        string memory f = vm.readFile("test/fixtures/datastreams/pending/btcusd-1789529160.json");
        fullReport = f.readBytes(".fullReport");
    }

    modifier onFork() {
        vm.skip(!forked, "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // identity: the contract whose answers are trusted, before trusting any
    // ---------------------------------------------------------------------------------------------

    /// @notice PROOF_STANDARD §9: the verifier is identified by its runtime code, not only its address.
    function test_ForkIsTheRealVerifierAtThePinnedBlock() public onFork {
        assertEq(block.chainid, 10143, "not Monad testnet");
        assertEq(block.number, FORK_BLOCK, "not the pinned block");
        assertEq(block.timestamp, B, "the pinned block's timestamp is the observation second");

        assertEq(VERIFIER.code.length, 7009, "runtime code length");
        assertEq(keccak256(VERIFIER.code), VERIFIER_CODE_KECCAK, "runtime code keccak256 differs from SPEC.md:78");
        assertEq(IVerifierProxy(VERIFIER).typeAndVersion(), "VerifierProxy 2.0.0");
        assertEq(IVerifierProxy(VERIFIER).s_feeManager(), address(0), "a fee manager would break settlement");
        assertEq(IVerifierProxy(VERIFIER).s_accessController(), address(0));
    }

    // ---------------------------------------------------------------------------------------------
    // the mandatory real report, through the shipping library
    // ---------------------------------------------------------------------------------------------

    /// @notice `INVARIANTS.md:12` names this test. The real 2026-09-16 03:26:00 report, whose window
    /// starts three seconds before its observation, is ACCEPTED at its boundary by the shipping library
    /// calling the real verifier. The direction §5.2 step 5 permits, proven on the only captured report
    /// that exercises it.
    function test_AcceptsWindowEndingAtBoundary() public onFork {
        RoundSettlement.Report memory r = harness.check(fullReport, B);

        assertEq(r.feedId, RoundSettlement.FEED_ID);
        assertEq(uint256(r.validFromTimestamp), uint256(VALID_FROM), "validFrom is B - 3");
        assertEq(uint256(r.observationsTimestamp), uint256(B), "observed at the boundary");
        assertLt(uint256(r.validFromTimestamp), uint256(r.observationsTimestamp), "a genuinely widened window");
        assertEq(uint256(r.expiresAt), uint256(EXPIRES_AT));
        assertEq(r.price, PRICE);
        assertEq(r.bid, BID);
        assertEq(r.ask, ASK);
    }

    /// @notice The whole `check()` stays inside its ceiling against the real verifier.
    function test_CheckStaysUnderItsGasCeiling() public onFork {
        (, uint256 gasUsed) = harness.checkWithGas(fullReport, B);
        emit log_named_uint("check() gas, real verifier, cold", gasUsed);
        assertLe(gasUsed, CHECK_GAS_CEILING, "check() exceeds its ceiling");
    }

    // ---------------------------------------------------------------------------------------------
    // rejections driven from the real report
    // ---------------------------------------------------------------------------------------------

    /// @notice N1: the real report is rejected one second either side of its boundary.
    function test_RejectsOneSecondEarlyAndLate() public onFork {
        vm.expectRevert(RoundSettlement.WrongObservationTime.selector);
        harness.check(fullReport, B - 1);

        vm.expectRevert(RoundSettlement.WrongObservationTime.selector);
        harness.check(fullReport, B + 1);
    }

    /// @notice Step 7 against the real verifier, which does NOT check expiry itself: accepted at
    /// `expiresAt`, rejected one second later. This is the only expiry defence in the system.
    function test_ExpiryIsEnforcedByTheLibraryNotTheVerifier() public onFork {
        vm.warp(EXPIRES_AT);
        harness.check(fullReport, B);

        vm.warp(uint256(EXPIRES_AT) + 1);
        // The real verifier still accepts the signature one second past expiry, measured 2026-09-22;
        // only the library's step 7 rejects it.
        (bool ok,) = VERIFIER.call(abi.encodeCall(IVerifierProxy.verify, (fullReport, "")));
        assertTrue(ok, "the real verifier itself ignores expiry");
        vm.expectRevert(RoundSettlement.ReportExpired.selector);
        harness.check(fullReport, B);
    }

    /// @notice Tampered SIGNED bytes are rejected by the real verifier's signature check.
    /// @dev The flipped byte is the low byte of `observationsTimestamp` inside the 288-byte signed
    /// report blob (the blob starts at byte 256 of this report; the field is its third word). The first
    /// draft flipped byte 200, which is unused signature padding, and the verifier rightly accepted it:
    /// see `test_UnusedSignaturePaddingIsMalleable`. A bare revert expectation is deliberate: the
    /// rejection is Chainlink's, and what matters is that the library does not return.
    function test_TamperedReportIsRejectedByTheRealVerifier() public onFork {
        bytes memory tampered = fullReport;
        uint256 at = 256 + 2 * 32 + 31;
        tampered[at] = bytes1(uint8(tampered[at]) ^ 0x01);
        vm.expectRevert();
        harness.check(tampered, B);
    }

    /// @notice FOUND BY THIS SUITE, and recorded because downstream code must not assume otherwise:
    /// a full report is MALLEABLE in its unused signature padding. The same signed report, with byte 200
    /// changed, still verifies to identical fields, so two different byte strings, and therefore two
    /// different `keccak256(fullReport)` values, settle a round identically.
    /// @dev Layout: `abi.encode(bytes32[3] context, bytes report, bytes32[] rs, bytes32[] ss, bytes32 rawVs)`.
    /// `rawVs` packs one recovery byte per signature and this report carries two, so rawVs bytes 2 to 31
    /// (report bytes 194 to 223) are verified by nothing. Money and outcome are unaffected, since only the
    /// verified return is decoded (N26 holds). But `MakoRoundsV1` stores and emits `keccak256` of the
    /// SUBMITTED bytes as the report hash, per SPEC §5.3, so that hash is not canonical: a settler can
    /// make the on-chain evidence hash differ from the hash of the report as Data Streams serves it.
    function test_UnusedSignaturePaddingIsMalleable() public onFork {
        bytes memory variant = fullReport;
        variant[200] = bytes1(uint8(variant[200]) ^ 0x01);
        assertTrue(keccak256(variant) != keccak256(fullReport), "setup: the byte strings differ");

        RoundSettlement.Report memory a = harness.check(fullReport, B);
        RoundSettlement.Report memory b = harness.check(variant, B);
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "identical verified report from different bytes");
    }
}
