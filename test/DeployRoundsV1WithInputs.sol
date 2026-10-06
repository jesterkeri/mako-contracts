// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployRoundsV1} from "../script/DeployRoundsV1.s.sol";

/// @notice DeployRoundsV1 with its inputs set by the test instead of read from the environment. `vm.setEnv` is
/// process-wide and forge runs tests in parallel, so env-driven tests overwrite each other's inputs.
contract DeployRoundsV1WithInputs is DeployRoundsV1 {
    string internal treasuryRaw;
    string[] internal creatorsRaw;
    uint256 internal expectedCap;
    string internal record;
    bool internal hasRecord;
    bool internal hasChainView;
    ChainReceipt internal viewReceipt;
    bytes32 internal viewCodeBefore;
    bytes32 internal viewCodeAt;

    function setInputs(string memory treasury, string[] memory creators, uint256 cap) external {
        treasuryRaw = treasury;
        delete creatorsRaw;
        for (uint256 i = 0; i < creators.length; i++) {
            creatorsRaw.push(creators[i]);
        }
        expectedCap = cap;
    }

    /// A broadcast record for verifyDeployment, instead of forge's file on disk.
    function setBroadcastRecord(string memory json) external {
        record = json;
        hasRecord = true;
    }

    function broadcastRecord() public view override returns (string memory) {
        return hasRecord ? record : super.broadcastRecord();
    }

    /// A stand-in for the real chain's answers, for tests whose contract exists only on the local fork: the
    /// receipt it returns and the code hashes before and at `FAKE_DEPLOY_BLOCK`.
    function setChainView(ChainReceipt memory receipt, bytes32 codeHashBefore, bytes32 codeHashAt) public {
        hasChainView = true;
        viewReceipt = receipt;
        viewCodeBefore = codeHashBefore;
        viewCodeAt = codeHashAt;
    }

    /// The honest case: a successful creation of `created` in `FAKE_DEPLOY_BLOCK`, with `codeHashAt` from then.
    function setChainCreation(address created, bytes32 codeHashAt) external {
        setChainView(ChainReceipt(true, 1, FAKE_DEPLOY_BLOCK, created, address(0)), keccak256(""), codeHashAt);
    }

    function onChainReceipt(bytes32 txHash) public override returns (ChainReceipt memory) {
        return hasChainView ? viewReceipt : super.onChainReceipt(txHash);
    }

    function onChainCodeHash(address a, uint256 blockNumber) public override returns (bytes32) {
        if (!hasChainView) return super.onChainCodeHash(a, blockNumber);
        return blockNumber == FAKE_DEPLOY_BLOCK - 1 ? viewCodeBefore : viewCodeAt;
    }

    /// The deploy block the stand-in chain answers about.
    uint256 public constant FAKE_DEPLOY_BLOCK = 70000123;

    function readInputs() public view override returns (address, address[] memory, uint256) {
        return inputsFrom(treasuryRaw, creatorsRaw, expectedCap);
    }
}
