// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {RoundSettlement} from "../src/RoundSettlement.sol";
import {RoundSettlementHarness} from "./RoundSettlementHarness.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";

/// @notice The Solidity half of PROOF_STANDARD.md Version 3 §2's two independent computations.
///
/// Every case comes from `test/fixtures/rule-cases/CASES.json`, the same rows
/// `script/rule-reference.mjs` evaluates. Each side asserts its own result against the corpus's
/// expected verdict INDEPENDENTLY, and neither reads the other's output.
///
/// @dev ON WHY THAT COUNTS AS COMPARING THE TWO. If Solidity agrees with the expectation and
/// JavaScript agrees with the expectation, the two agree with each other. The failure mode this
/// invites is that both implement the same misreading AND the hand-authored expectation shares it,
/// in which case all three agree and nothing is proven. Two things defend against that, and neither
/// is this file: every expectation is authored from a named SPEC clause recorded per row in
/// `specClauses`, and each evaluator is mutation-tested SEPARATELY with the corpus held fixed
/// (`script/mutate-reference.mjs` for JavaScript, the table in VERIFICATION.md for Solidity). A
/// corpus that can absorb a mutation is not a gate.
///
/// THE MOCK IS PLACED AT THE PINNED VERIFIER ADDRESS with `vm.etch`, never passed in. The library
/// hardcodes `VERIFIER_PROXY` precisely so a caller cannot supply their own, so every case here
/// exercises the shipping call path rather than a parameterised variant of it.
contract RoundSettlementTest is Test {
    using stdJson for string;

    RoundSettlementHarness internal harness;
    MockVerifier internal mock;
    string internal corpus;
    uint256 internal caseCount;

    address internal constant VERIFIER = 0x72790f9eB82db492a7DDb6d2af22A270Dcc3Db64;

    function setUp() public {
        harness = new RoundSettlementHarness();
        corpus = vm.readFile("test/fixtures/rule-cases/CASES.json");
        caseCount = corpus.readStringArray("._index.ids").length;

        // Deploy the mock anywhere, then place its runtime code at the pinned address. Everything
        // the library calls (`s_feeManager`, `verify`) then resolves there.
        MockVerifier template = new MockVerifier();
        vm.etch(VERIFIER, address(template).code);
        mock = MockVerifier(VERIFIER);
    }

    // ---------------------------------------------------------------------------------------------
    // the corpus, row by row
    // ---------------------------------------------------------------------------------------------

    /// @dev Maps a corpus error name to this library's selector. Written out rather than derived so
    /// the mapping itself is reviewable: if the library renamed an error, this stops compiling.
    function _selectorFor(string memory name) internal pure returns (bytes4) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("FeeManagerEnabled")) return RoundSettlement.FeeManagerEnabled.selector;
        if (h == keccak256("WrongSchema")) return RoundSettlement.WrongSchema.selector;
        if (h == keccak256("WrongFeed")) return RoundSettlement.WrongFeed.selector;
        if (h == keccak256("WrongObservationTime")) return RoundSettlement.WrongObservationTime.selector;
        if (h == keccak256("ValidFromAfterObservation")) {
            return RoundSettlement.ValidFromAfterObservation.selector;
        }
        if (h == keccak256("NonPositivePrice")) return RoundSettlement.NonPositivePrice.selector;
        if (h == keccak256("BidAskOutOfOrder")) return RoundSettlement.BidAskOutOfOrder.selector;
        if (h == keccak256("SpreadTooWide")) return RoundSettlement.SpreadTooWide.selector;
        if (h == keccak256("ReportExpired")) return RoundSettlement.ReportExpired.selector;
        revert(string.concat("corpus names an error this library does not define: ", name));
    }

    function _path(uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(".cases[", vm.toString(i), "]", field);
    }

    /// @notice Evaluates every mock-driven row in the corpus and asserts the library's verdict.
    /// @dev Rows marked `source: "real"` are skipped here and belong to the fork test: producing a
    /// genuine verified return requires the real verifier, and a mock standing in for it would prove
    /// nothing about the one fixture `INVARIANTS.md:12` requires by name.
    function test_LibraryAgreesWithTheCorpusOnEveryMockRow() public {
        uint256 evaluated;
        uint256 skippedReal;

        for (uint256 i = 0; i < caseCount; i++) {
            string memory id = corpus.readString(_path(i, ".id"));

            if (keccak256(bytes(corpus.readString(_path(i, ".source")))) == keccak256("real")) {
                skippedReal++;
                continue;
            }

            // --- configure the mock from the row's RAW BEHAVIOUR ONLY --------------------------
            // Never from its expected output. An expectation that leaked into the thing being
            // tested would make the test agree with itself.
            mock.setFeeManager(corpus.readAddress(_path(i, ".verifier.feeManager")));
            bool reverts = keccak256(bytes(corpus.readString(_path(i, ".verifier.behaviour")))) == keccak256("revert");
            mock.setShouldRevert(reverts, "");
            if (!reverts) mock.setReturnData(_verifiedBytesOf(i));

            uint32 boundary = uint32(corpus.readUint(_path(i, ".boundary")));
            vm.warp(corpus.readUint(_path(i, ".warpTo")));

            // The submitted report is irrelevant to a mock, which is the point of
            // test_DecodesVerifiedBytesNotInput: the library must trust what comes back, not what
            // went in. A non-empty placeholder is used so nothing depends on it being empty.
            bytes memory submitted = hex"deadbeef";

            string memory verdict = corpus.readString(_path(i, ".expect.verdict"));
            if (keccak256(bytes(verdict)) == keccak256("accept")) {
                RoundSettlement.Report memory r = harness.check(submitted, boundary);
                assertEq(r.feedId, RoundSettlement.FEED_ID, string.concat(id, ": accepted the wrong feed"));
                assertEq(
                    uint256(r.observationsTimestamp),
                    uint256(boundary),
                    string.concat(id, ": accepted an observation off the boundary")
                );
            } else if (reverts) {
                // The verifier itself rejected. The library must not swallow it.
                vm.expectRevert();
                harness.check(submitted, boundary);
            } else {
                bytes4 expected = _selectorFor(corpus.readString(_path(i, ".expect.errorName")));
                vm.expectRevert(expected);
                harness.check(submitted, boundary);
            }

            evaluated++;
        }

        assertEq(evaluated + skippedReal, caseCount, "some corpus row was neither evaluated nor skipped");
        assertGt(evaluated, 0, "no rows were evaluated");
        assertEq(skippedReal, 1, "exactly one row is the real fixture, owned by the fork test");
    }

    /// @dev The corpus stores the mock's return as the full ABI encoding of a `bytes` value, which
    /// is what an external call returns on the wire. `MockVerifier.setReturnData` takes the INNER
    /// bytes, because Solidity re-encodes them on return, so the envelope is stripped here.
    function _verifiedBytesOf(uint256 i) internal view returns (bytes memory inner) {
        bytes memory wrapped = corpus.readBytes(_path(i, ".verifier.returnData"));
        uint256 len;
        assembly ("memory-safe") {
            len := mload(add(wrapped, 64)) // skip length prefix + offset word
        }
        inner = new bytes(len);
        for (uint256 j = 0; j < len; j++) {
            inner[j] = wrapped[64 + j];
        }
    }

    // ---------------------------------------------------------------------------------------------
    // structural
    // ---------------------------------------------------------------------------------------------

    /// @notice `INVARIANTS.md:12` requires this by name: a submission carries no outcome and no
    /// price of its own.
    function test_NoOutcomeParameter() public pure {
        assertEq(
            RoundSettlementHarness.check.selector,
            bytes4(keccak256("check(bytes,uint32)")),
            "the entry point takes something other than (bytes, uint32)"
        );

        // A verifier address parameter is the specific shape that admitted the EvilVerifier, so it
        // is excluded by name as well as by the selector above.
        assertTrue(
            RoundSettlementHarness.check.selector != bytes4(keccak256("check(address,bytes,uint32)")),
            "the entry point accepts a verifier address"
        );
        assertTrue(
            RoundSettlementHarness.check.selector != bytes4(keccak256("check(bytes,uint32,uint8)")),
            "the entry point accepts an outcome"
        );
        assertTrue(
            RoundSettlementHarness.check.selector != bytes4(keccak256("check(bytes,uint32,int192)")),
            "the entry point accepts a price"
        );
    }

    /// @notice The verifier is a constant, not something a caller can choose.
    function test_VerifierAddressIsPinned() public pure {
        assertEq(RoundSettlement.VERIFIER_PROXY, 0x72790f9eB82db492a7DDb6d2af22A270Dcc3Db64);
    }

    /// @notice Step 1 runs before step 2. Proven by the mock reverting if `verify` is reached while
    /// a fee manager is set, rather than inferred from reading the source.
    function test_FeeManagerCheckRunsBeforeVerify() public {
        mock.setFeeManager(address(0xBEEF));
        mock.setShouldRevert(false, "");
        mock.setReturnData(hex"00");
        vm.warp(1789529160);

        // If the ordering were wrong the mock would revert with VerifyReachedWithFeeManagerSet
        // instead, and this exact-selector expectation would fail.
        vm.expectRevert(RoundSettlement.FeeManagerEnabled.selector);
        harness.check(hex"deadbeef", 1789529160);
    }

    /// @notice The verifier is called with an empty `parameterPayload`, per SPEC 5.2 step 2.
    /// @dev The mock requires it; a non-empty value would revert with its own message rather than
    /// the library's error, so a library passing something else cannot pass this test by accident.
    function test_VerifierCalledWithEmptyParameterPayload() public {
        mock.setFeeManager(address(0));
        mock.setShouldRevert(false, "");
        mock.setReturnData(hex"00"); // wrong length, so the library rejects AFTER the call succeeds
        vm.warp(1789529160);

        vm.expectRevert(RoundSettlement.WrongSchema.selector);
        harness.check(hex"deadbeef", 1789529160);
    }
}
