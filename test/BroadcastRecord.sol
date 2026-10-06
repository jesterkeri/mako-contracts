// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice Builds forge broadcast records (`broadcast/<script>/<chainid>/run-latest.json`) in the shape forge
/// writes them, reduced to the fields `DeployRoundsV1.deployTransactionIn` reads: per transaction `hash`,
/// `transactionType`, `contractName`, `contractAddress`; per receipt `transactionHash`, `status`,
/// `blockNumber`, `contractAddress` (status and block as forge writes them, hex strings).
library BroadcastRecord {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function tx_(bytes32 hash, string memory kind, string memory name, address at)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"hash":"',
            vm.toString(hash),
            '","transactionType":"',
            kind,
            '","contractName":"',
            name,
            '","contractAddress":"',
            vm.toString(at),
            '"}'
        );
    }

    function receipt(bytes32 hash, uint256 status, uint256 blockNumber, address at)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"transactionHash":"',
            vm.toString(hash),
            '","status":"',
            vm.toString(bytes32(status)),
            '","blockNumber":"',
            vm.toString(bytes32(blockNumber)),
            '","contractAddress":"',
            vm.toString(at),
            '"}'
        );
    }

    function record(string memory txs, string memory receipts) internal pure returns (string memory) {
        return string.concat('{"transactions":[', txs, '],"receipts":[', receipts, "]}");
    }

    /// The honest record: one CREATE of MakoRoundsV1 at `at`, landed.
    function created(address at, bytes32 hash, uint256 status, uint256 blockNumber)
        internal
        pure
        returns (string memory)
    {
        return record(tx_(hash, "CREATE", "MakoRoundsV1", at), receipt(hash, status, blockNumber, at));
    }
}
