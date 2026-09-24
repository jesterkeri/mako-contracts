// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice A stand-in for Chainlink's `VerifierProxy`, for return shapes the real one will not
/// produce: a v8- or v11-shaped payload, a payload that is not 288 bytes, a revert, a non-zero fee
/// manager, and bytes that differ from the ones submitted.
///
/// This is TEST-ONLY code and is never deployed.
///
/// @dev It is placed at the pinned `VERIFIER_PROXY` address with `vm.etch`, never passed in as a
/// parameter. `RoundSettlement` hardcodes that address, because a library taking
/// `(address verifier, ...)` lets a caller supply their own contract and settle any price they
/// like: an adversarial review built exactly that and settled a $1,000,000 BTC price from
/// `fullReport = 0xdead`, passing all seven SPEC 5.2 checks. Placing the mock at the real address
/// means every mock case exercises the shipping call path rather than a parameterised variant of it.
contract MockVerifier {
    bytes internal returnData;

    /// @dev A verified return keyed by the SUBMITTED bytes, so one mock can answer differently for a
    /// round's anchor and close reports, which are verified in the same transaction. Falls back to
    /// `returnData` when no key matches, preserving the single-return behaviour the rule tests use.
    /// Keying on the input is the MOCK's behaviour and says nothing about the library, which still
    /// decodes only what comes back: `test_DecodesVerifiedBytesNotInput` proves that separately by
    /// returning bytes that disagree with the input entirely.
    mapping(bytes32 => bytes) internal keyedReturns;
    address internal feeManager;
    address internal accessController;
    bool internal shouldRevert;
    bytes internal revertData;

    /// @notice Set by `verify`, read by the ordering test. SPEC 5.2 puts the fee-manager check
    /// FIRST, so a correct library never reaches `verify` while the fee manager is non-zero.
    bool public verifyWasReached;

    /// @dev Thrown when `verify` is reached although the fee manager is non-zero. This is how the
    /// ordering of step 1 before step 2 is proven rather than assumed from reading the source.
    error VerifyReachedWithFeeManagerSet();

    function setReturnData(bytes calldata data) external {
        returnData = data;
    }

    function setReturnFor(bytes calldata submitted, bytes calldata data) external {
        keyedReturns[keccak256(submitted)] = data;
    }

    function setFeeManager(address fm) external {
        feeManager = fm;
    }

    function setAccessController(address ac) external {
        accessController = ac;
    }

    function setShouldRevert(bool yes, bytes calldata data) external {
        shouldRevert = yes;
        revertData = data;
    }

    function resetReached() external {
        verifyWasReached = false;
    }

    function s_feeManager() external view returns (address) {
        return feeManager;
    }

    function s_accessController() external view returns (address) {
        return accessController;
    }

    function typeAndVersion() external pure returns (string memory) {
        return "VerifierProxy 2.0.0";
    }

    /// @dev `payable` and non-view, matching the real proxy. That is why `RoundSettlement.check`
    /// cannot be `view`: solc rejects a `view` function calling this with
    /// `Error (8961): Function cannot be declared as view because this expression (potentially)
    /// modifies the state`.
    function verify(bytes calldata payload, bytes calldata parameterPayload) external payable returns (bytes memory) {
        verifyWasReached = true;

        // The fee-manager gate belongs to the library and runs before this call. Reaching here with
        // a fee manager set means the library checked in the wrong order, so fail loudly instead of
        // returning something the test would then accept.
        if (feeManager != address(0)) revert VerifyReachedWithFeeManagerSet();

        // SPEC 5.2 step 2 requires an empty `parameterPayload`; a non-empty value engages fee
        // handling on the real verifier. Asserted here so a library passing something else cannot
        // pass a test by accident.
        require(parameterPayload.length == 0, "MockVerifier: parameterPayload must be empty");

        if (shouldRevert) {
            bytes memory d = revertData;
            if (d.length == 0) revert("MockVerifier: verification failed");
            assembly {
                revert(add(d, 0x20), mload(d))
            }
        }

        bytes memory keyed = keyedReturns[keccak256(payload)];
        if (keyed.length != 0) return keyed;

        // Otherwise the canned return, deliberately ignoring `payload`. The whole point of
        // `test_DecodesVerifiedBytesNotInput` is that the library must trust what comes back, not
        // what went in.
        return returnData;
    }
}
