// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";

/// @notice Coverage and integrity checks on the shared rule-case corpus.
///
/// PROOF_STANDARD.md Version 3 §3 requires the case table to exist BEFORE the implementation, with
/// every row naming its expected result, its error selector and the spec clause it comes from. This
/// test enforces that the table actually covers what `INVARIANTS.md` demands, so a missing case is a
/// failing test rather than something noticed in review.
///
/// It does NOT evaluate the rule. `src/RoundSettlement.sol` does not exist yet, deliberately:
/// `INVARIANTS.md:45` requires the rule test before the contract, and the production library is
/// blocked on the distinct-operator archive proof. When it lands, its own test evaluates these same
/// rows and its verdicts are compared with `script/rule-reference.mjs`, which is the two-independent-
/// implementations half of §2. Until then this is a Type A offline claim about the corpus only.
contract RuleCorpusTest is Test {
    using stdJson for string;

    string internal corpus;

    /// Every test `INVARIANTS.md:12` (N1) names. A row must exist for each.
    string[10] internal REQUIRED_N1_TESTS = [
        "test_RejectsReportTheVerifierRejects",
        "test_RejectsV8ShapedReturn",
        "test_RejectsV11ShapedReturn",
        "test_RejectsShortOrLongReturn",
        "test_RejectsOtherFeed",
        "test_RejectsOneSecondEarlyAndLate",
        "test_AcceptsWindowEndingAtBoundary",
        "test_RejectsValidFromAfterObservation",
        "test_DecodesVerifiedBytesNotInput",
        "test_NoOutcomeParameter"
    ];

    function setUp() public {
        corpus = vm.readFile("test/fixtures/rule-cases/CASES.json");
    }

    function _ids() internal view returns (string[] memory) {
        return corpus.readStringArray("._index.ids");
    }

    /// @dev forge-std's JSON reader takes one value per path and rejects wildcards like
    /// `.cases[*].id`, so the generator emits flat parallel arrays under `_index`. They are
    /// generated, never hand-edited, and `node script/build-cases.mjs --check` compares the whole
    /// file against the generator in CI, so the index cannot drift from the rows it indexes.
    function _indexOf(string[] memory haystack, string memory needle) internal pure returns (int256) {
        bytes32 n = keccak256(bytes(needle));
        for (uint256 i = 0; i < haystack.length; i++) {
            if (keccak256(bytes(haystack[i])) == n) return int256(i);
        }
        return -1;
    }

    function _has(string[] memory haystack, string memory needle) internal pure returns (bool) {
        bytes32 n = keccak256(bytes(needle));
        for (uint256 i = 0; i < haystack.length; i++) {
            if (keccak256(bytes(haystack[i])) == n) return true;
        }
        return false;
    }

    /// @dev `test_NoOutcomeParameter` is a structural assertion on the harness ABI, not a data row,
    /// so it is the one N1 name the corpus legitimately does not carry. Every other name must.
    function test_CorpusCoversEveryNamedN1Test() public view {
        string[] memory named = corpus.readStringArray("._index.requiredTestNames");
        for (uint256 i = 0; i < REQUIRED_N1_TESTS.length; i++) {
            string memory required = REQUIRED_N1_TESTS[i];
            if (keccak256(bytes(required)) == keccak256(bytes("test_NoOutcomeParameter"))) continue;
            assertTrue(
                _has(named, required),
                string.concat("INVARIANTS.md:12 names this test and no corpus row claims it: ", required)
            );
        }
    }

    /// @dev The one fixture that cannot be replaced by a mock. Six of six sampled historical reports
    /// have a zero-width window, so a genuine `validFromTimestamp < observationsTimestamp` report is
    /// rare and this specific one is the only one captured. Four separate review rounds each found a
    /// different route to losing it, so it is asserted by id here as well.
    function test_MandatoryWidenedWindowRowIsPresent() public view {
        int256 at = _indexOf(_ids(), "accept-real-widened-window");
        assertTrue(at >= 0, "the mandatory widened-window row is gone");

        string[] memory sources = corpus.readStringArray("._index.sources");
        assertEq(sources[uint256(at)], "real", "the mandatory row must be the REAL report, never a mock");

        string[] memory verdicts = corpus.readStringArray("._index.verdicts");
        assertEq(verdicts[uint256(at)], "accept", "the mandatory row must be an ACCEPT case");

        assertTrue(
            _has(corpus.readStringArray("._index.requiredTestNames"), "test_AcceptsWindowEndingAtBoundary"),
            "the mandatory row lost its test name"
        );
    }

    /// @dev N11 requires one case per clause at the boundary AND at maximum-integer values. Both
    /// sides of the expiry boundary are named explicitly because step 7 is the only expiry defence
    /// that exists anywhere: `VerifierProxy.verify` does not check expiry at all, measured
    /// 2026-09-22 on a report three days past `expiresAt` that still returned 352 bytes.
    function test_CorpusCoversEveryN11Clause() public view {
        string[8] memory required = [
            "reject-price-zero",
            "reject-bid-above-price",
            "reject-ask-below-price",
            "reject-spread-one-bps-over",
            "accept-spread-exactly-at-limit",
            "accept-at-expiry-boundary",
            "reject-expired-by-one-second",
            "reject-fee-manager-present"
        ];
        string[] memory ids = _ids();
        for (uint256 i = 0; i < required.length; i++) {
            assertTrue(_has(ids, required[i]), string.concat("N11 clause row missing: ", required[i]));
        }
    }

    /// @dev The row the plan warns about. `price > 0` and `bid <= price <= ask` both pass, so step 6c
    /// is reached with `ask - bid` overflowing int192. Taken in 192 bits that wraps and the row is
    /// wrongly accepted; in Solidity the same mistake panics with 0x11 and the test would pass for
    /// the wrong reason, never reaching the spread rejection it claims to exercise. SPEC 5.2 step 6
    /// specifies uint256 for exactly this.
    function test_MaximumIntegerSpreadRowIsPresentAndMustNotPanic() public view {
        assertTrue(
            _has(_ids(), "reject-spread-max-integer-must-not-panic"),
            "N11 mandates a maximum-integer case and the corpus has lost it"
        );
        assertTrue(
            _has(corpus.readStringArray("._index.mustNotPanicIds"), "reject-spread-max-integer-must-not-panic"),
            "the maximum-integer row must forbid Panic(0x11) explicitly"
        );
    }

    /// @dev Duplicate ids would let one row silently shadow another in either evaluator.
    function test_CaseIdsAreUnique() public view {
        string[] memory ids = _ids();
        for (uint256 i = 0; i < ids.length; i++) {
            for (uint256 j = i + 1; j < ids.length; j++) {
                assertTrue(
                    keccak256(bytes(ids[i])) != keccak256(bytes(ids[j])), string.concat("duplicate case id: ", ids[i])
                );
            }
        }
    }

    /// @dev The encoder is validated against the chain, not against itself: the generator re-encodes
    /// the real verifier's return from its decoded fields and asserts the bytes are identical to
    /// what Monad testnet actually returned. If that check were ever dropped, every mock row would
    /// rest on an unvalidated encoder.
    function test_EncoderWasValidatedAgainstTheChain() public view {
        assertTrue(corpus.readBool("._encoderGroundTruth.checked"), "the encoder ground-truth check is not recorded");
        assertTrue(
            corpus.readBool("._encoderGroundTruth.identical"),
            "the generator no longer reproduces the real verified return"
        );
    }

    /// @dev The mock must refuse a non-empty `parameterPayload`, per SPEC 5.2 step 2. Asserted here
    /// so the guard is known to work before any library depends on it.
    function test_MockRejectsNonEmptyParameterPayload() public {
        MockVerifier mock = new MockVerifier();
        mock.setReturnData(hex"00");
        vm.expectRevert("MockVerifier: parameterPayload must be empty");
        mock.verify(hex"dead", hex"01");
    }

    /// @dev And it must fail loudly if `verify` is reached while a fee manager is set, which is how
    /// step 1 running before step 2 is proven rather than assumed.
    function test_MockDetectsWrongCheckOrdering() public {
        MockVerifier mock = new MockVerifier();
        mock.setFeeManager(address(0xBEEF));
        mock.setReturnData(hex"00");
        // The revert is the whole assertion. `verifyWasReached` cannot be read afterwards: the call
        // reverted, so every state change it made was rolled back. Checking it here would be
        // asserting on state that by definition no longer exists.
        vm.expectRevert(MockVerifier.VerifyReachedWithFeeManagerSet.selector);
        mock.verify(hex"dead", hex"");
    }
}
