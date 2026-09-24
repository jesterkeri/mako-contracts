// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {MakoRoundsV1} from "../src/MakoRoundsV1.sol";

/// @notice Exposes MakoRoundsV1's internal future-observation guard so it can be tested directly.
/// @dev Test-only. The guard is unreachable through `settle` (a report from a future second is rejected
/// earlier by the boundary check), so this is the only way to give it a test that can fail.
contract MakoRoundsV1Harness is MakoRoundsV1 {
    constructor(address treasury, address usdc, address[] memory creators) MakoRoundsV1(treasury, usdc, creators) {}

    function exposed_requireObservedBy(uint32 anchorObservedAt, uint32 closeObservedAt) external view {
        _requireObservedBy(anchorObservedAt, closeObservedAt);
    }
}
