// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {RoundSettlement} from "../src/RoundSettlement.sol";

/// @notice Exposes the library through a real external function so its ABI can be asserted.
///
/// @dev The selector of an `internal` library function is not a meaningful ABI claim, so
/// `test_NoOutcomeParameter` is asserted against THIS contract.
///
/// Two inputs and nothing else. In particular NO verifier address: the library hardcodes
/// `VERIFIER_PROXY`, and an earlier draft that took one as a parameter was shown to settle a
/// $1,000,000 BTC price from `fullReport = 0xdead`. Also no outcome and no price, because deriving
/// UP, DOWN or Tie belongs to `MakoRoundsV1`.
///
/// Not `view`, matching the library, which in turn matches the real proxy's payable `verify`.
contract RoundSettlementHarness {
    function check(bytes calldata fullReport, uint32 boundary) external returns (RoundSettlement.Report memory) {
        return RoundSettlement.check(fullReport, boundary);
    }

    /// @notice Same call, reporting the gas the library itself consumed.
    /// @dev Measured with a `gasleft()` delta, which EXCLUDES the 21,000 intrinsic cost and the
    /// calldata cost an `eth_estimateGas` figure would include, and INCLUDES EIP-2929 cold-access
    /// costs. Those are different quantities and must not be compared with each other. The gas
    /// ceiling is asserted in the fork test against the real verifier; a figure measured against a
    /// mock means nothing.
    function checkWithGas(bytes calldata fullReport, uint32 boundary)
        external
        returns (RoundSettlement.Report memory r, uint256 gasUsed)
    {
        uint256 before = gasleft();
        r = RoundSettlement.check(fullReport, boundary);
        gasUsed = before - gasleft();
    }
}
