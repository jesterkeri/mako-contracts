// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Scene} from "./Scene.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// @notice A maker that answers `isOwner` (and `isValidSignature`) correctly only if it was handed nearly the whole
/// `SIG_GAS` it is owed. A checker that hands it less, with no `InsufficientGas`, would blame the maker for a short
/// gas limit (plan 4.2: "a short gas limit could make a valid signature look invalid and blame the maker").
contract GateMaker {
    function register(X ex, address key) external {
        ex.setOrderSigner(key);
    }

    function isOwner(address) external view returns (bool) {
        return gasleft() >= 99_000;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        return gasleft() >= 99_000 ? bytes4(0x1626ba7e) : bytes4(0);
    }
}

contract RevertOneOwner {
    function register(X ex, address key) external {
        ex.setOrderSigner(key);
    }

    fallback() external {
        assembly {
            mstore(0, 1)
            revert(0, 32)
        }
    }
}

/// @notice From the adversary pass on the registered order signer (plan 4.5) at c7b6135: the InsufficientGas guard is
/// exact on steps 1b and 2, and `_boundedIsOwner` requires the call to succeed.
contract SignerGasGuardTest is Scene {
    /// @dev The InsufficientGas guard is exact: at every outer gas limit the checker either reverts `InsufficientGas`
    /// or hands the maker its full `SIG_GAS`. It must never answer "invalid" for a valid signature because gas was short.
    function _sweep(bool registered) internal {
        (address key, uint256 k) = makeAddrAndKey("gate-key");
        GateMaker g = new GateMaker();
        if (registered) g.register(ex, key);
        X.Order memory o = _order(address(g), m, 0, false, 40, 10 * SHARE);
        bytes memory sig = _sign(k, o);
        // Step 2 is reached only by a signature that recovers no key: the Safe's `v + 4` form (the maker ignores it).
        if (!registered) sig[64] = bytes1(uint8(sig[64]) + 4);
        bytes memory data = abi.encodeCall(X.isValidOrderSignature, (o, sig));
        uint256 wrong;
        uint256 firstWrong;
        uint256 insufficient;
        uint256 accepted;
        for (uint256 gas_ = 100_000; gas_ <= 140_000; gas_ += 50) {
            (bool ok, bytes memory ret) = address(ex).staticcall{gas: gas_}(data);
            if (!ok) {
                if (ret.length >= 4 && bytes4(ret) == X.InsufficientGas.selector) ++insufficient;
                continue;
            }
            if (abi.decode(ret, (bool))) {
                ++accepted;
            } else {
                if (wrong == 0) firstWrong = gas_;
                ++wrong;
            }
        }
        emit log_named_uint("registered", registered ? 1 : 0);
        emit log_named_uint("insufficientGas answers", insufficient);
        emit log_named_uint("accepted answers", accepted);
        emit log_named_uint("WRONG invalid answers (valid sig, short gas)", wrong);
        emit log_named_uint("first outer gas giving a wrong answer", firstWrong);
        assertEq(wrong, 0, "a valid signature was blamed on the maker because the call had too little gas");
        assertGt(accepted, 0, "control: some gas limit accepts");
    }

    /// @dev Plan 4.5: valid only if the call SUCCEEDED. An `isOwner` that reverts with a 32-byte word 1 must be refused.
    /// Passes on c7b6135; kills the mutant that drops `ok` from `_boundedIsOwner` (it survives the shipped tests).
    function test_adv_isOwnerRevertsWithWordOne_refused() public {
        (address key, uint256 k) = makeAddrAndKey("revert-one");
        RevertOneOwner g = new RevertOneOwner();
        g.register(ex, key);
        X.Order memory o = _order(address(g), m, 0, false, 40, 10 * SHARE);
        assertFalse(ex.isValidOrderSignature(o, _sign(k, o)), "a reverting isOwner counted as an owner");
    }

    function test_adv_insufficientGasGuard_isExact_step1b() public {
        _sweep(true);
    }

    function test_adv_insufficientGasGuard_isExact_step2() public {
        _sweep(false);
    }
}
