// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployRoundsV1} from "../script/DeployRoundsV1.s.sol";

/// @notice DeployRoundsV1 with its inputs set by the test instead of read from the environment. `vm.setEnv` is
/// process-wide and forge runs tests in parallel, so env-driven tests overwrite each other's inputs.
contract DeployRoundsV1WithInputs is DeployRoundsV1 {
    string internal treasuryRaw;
    string[] internal creatorsRaw;
    uint256 internal expectedCap;

    function setInputs(string memory treasury, string[] memory creators, uint256 cap) external {
        treasuryRaw = treasury;
        delete creatorsRaw;
        for (uint256 i = 0; i < creators.length; i++) {
            creatorsRaw.push(creators[i]);
        }
        expectedCap = cap;
    }

    function readInputs() public view override returns (address, address[] memory, uint256) {
        return inputsFrom(treasuryRaw, creatorsRaw, expectedCap);
    }
}
