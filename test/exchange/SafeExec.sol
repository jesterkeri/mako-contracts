// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

/// @notice The Safe v1.4.1 calls the registered-signer tests and vectors send.
interface ISafeExec {
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);
    function swapOwner(address prevOwner, address oldOwner, address newOwner) external;
    function isOwner(address owner) external view returns (bool);
}

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address);
}

interface ISafeSetup {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
}

/// @notice Installs the pinned Safe v1.4.1 runtime code (`test/vectors/safe-v1.4.1/`, the code S1 used) at the
/// chain-10143 addresses on chain 31337, and sends a one-owner Safe's own transaction.
abstract contract SafeExec is Test {
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant SAFE_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_MODULE = 0x75cf11467937ce3F2f357CE24ffc3DBF8fD5c226;
    bytes32 internal constant SAFE_SINGLETON_CODEHASH =
        0x1fe2df852ba3299d6534ef416eefa406e56ced995bca886ab7a553e6d0c5e1c4;

    /// @dev False (the caller skips) when not on forge's default chain and the code is not there.
    function _installSafe() internal returns (bool) {
        if (SAFE_SINGLETON.code.length == 0) {
            if (vm.getChainId() != 31337) return false;
            vm.etch(SAFE_SINGLETON, _hexFile("test/vectors/safe-v1.4.1/Safe.hex"));
            vm.etch(SAFE_FACTORY, _hexFile("test/vectors/safe-v1.4.1/SafeProxyFactory.hex"));
            vm.etch(SAFE_MODULE, _hexFile("test/vectors/safe-v1.4.1/Safe4337Module.hex"));
        }
        assertEq(SAFE_SINGLETON.codehash, SAFE_SINGLETON_CODEHASH, "the pinned Safe singleton code");
        return true;
    }

    function _hexFile(string memory file) internal view returns (bytes memory) {
        return vm.parseBytes(vm.trim(vm.readFile(file)));
    }

    /// @dev The owner sends a one-owner Safe's transaction with the pre-approved signature (v == 1, r = owner).
    function _safeExec(address safe, address owner, address to, bytes memory data) internal returns (uint256 used) {
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
        vm.prank(owner);
        uint256 g = gasleft();
        bool ok = ISafeExec(safe).execTransaction(to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
        used = g - gasleft();
        require(ok, "Safe execTransaction failed");
    }
}
