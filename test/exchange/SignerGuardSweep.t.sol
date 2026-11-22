// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Scene} from "./Scene.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// @notice A maker that answers correctly only if it receives at least `NEED` gas on entry. Probes the reserve of
/// `_boundedIsOwner` and `_bounded1271` at 1-gas resolution (SignerGasGuard sweeps in steps of 50 from 100,000).
contract NeedGas {
    uint256 public immutable NEED;

    constructor(uint256 need) {
        NEED = need;
    }

    function register(X ex, address key) external {
        ex.setOrderSigner(key);
    }

    function isOwner(address) external view returns (bool) {
        return gasleft() >= NEED;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        return gasleft() >= NEED ? bytes4(0x1626ba7e) : bytes4(0);
    }
}

/// @notice The same, in assembly with no dispatch: refuses unless it enters with at least 99,800 of the 100,000.
contract NeedGasAsm {
    function register(X ex, address key) external {
        ex.setOrderSigner(key);
    }

    fallback() external {
        assembly {
            let ok := iszero(lt(gas(), 99800))
            switch shr(224, calldataload(0))
            case 0x1626ba7e { mstore(0, mul(ok, shl(224, 0x1626ba7e))) }
            default { mstore(0, ok) }
            return(0, 32)
        }
    }
}

contract SignerGuardSweepTest is Scene {
    /// @dev Monad prices cold access higher, so the window where the check makes its call sits higher there.
    function _range() internal view returns (uint256 from, uint256 to) {
        bool monad = vm.envOr("EXPECT_MONAD_GAS", false);
        from = vm.envOr("SWEEP_FROM", monad ? uint256(118_000) : uint256(100_000));
        to = vm.envOr("SWEEP_TO", monad ? uint256(134_000) : uint256(125_000));
    }

    function _sweep(bool registered, uint256 maxLen) internal {
        (address key, uint256 k) = makeAddrAndKey("sweep1-key");
        // 99,500 received on entry: the callee must be handed essentially the whole SIG_GAS (it spends a few hundred
        // on its own dispatch before reading gasleft)
        NeedGas g = new NeedGas(99_500);
        if (registered) g.register(ex, key);
        X.Order memory o = _order(address(g), m, 0, false, 40, 10 * SHARE);
        bytes memory sig = _sign(k, o);
        if (!registered) {
            sig[64] = bytes1(uint8(sig[64]) + 4);
            // pad to the longest accepted signature: more calldata copied into the call
            bytes memory padded = new bytes(maxLen);
            for (uint256 i; i < sig.length; ++i) {
                padded[i] = sig[i];
            }
            sig = padded;
        }
        bytes memory data = abi.encodeCall(X.isValidOrderSignature, (o, sig));
        uint256 wrong;
        uint256 firstWrong;
        uint256 accepted;
        (uint256 from, uint256 to) = _range();
        for (uint256 gas_ = from; gas_ <= to; gas_ += 1) {
            (bool ok, bytes memory ret) = address(ex).staticcall{gas: gas_}(data);
            if (!ok) continue;
            if (abi.decode(ret, (bool))) {
                ++accepted;
            } else {
                if (wrong == 0) firstWrong = gas_;
                ++wrong;
            }
        }
        emit log_named_uint("accepted", accepted);
        emit log_named_uint("wrong answers", wrong);
        emit log_named_uint("first wrong at outer gas", firstWrong);
        assertEq(wrong, 0, "valid signature answered invalid because the call had too little gas");
        assertGt(accepted, 0);
    }

    /// @dev No-dispatch callee at 1-gas resolution: whenever the checker makes the call (no InsufficientGas) the callee
    /// must have been handed at least 99,800 of SIG_GAS = 100,000 (plan 4.2: "exactly SIG_GAS").
    function _sweepAsm(bool registered) internal {
        (address key, uint256 k) = makeAddrAndKey("sweepasm-key");
        NeedGasAsm g = new NeedGasAsm();
        if (registered) g.register(ex, key);
        X.Order memory o = _order(address(g), m, 0, false, 40, 10 * SHARE);
        bytes memory sig = _sign(k, o);
        if (!registered) sig[64] = bytes1(uint8(sig[64]) + 4);
        bytes memory data = abi.encodeCall(X.isValidOrderSignature, (o, sig));
        uint256 wrong;
        uint256 firstWrong;
        uint256 accepted;
        (uint256 from, uint256 to) = _range();
        for (uint256 gas_ = from; gas_ <= to; gas_ += 1) {
            (bool ok, bytes memory ret) = address(ex).staticcall{gas: gas_}(data);
            if (!ok) continue;
            if (abi.decode(ret, (bool))) {
                ++accepted;
            } else {
                if (wrong == 0) firstWrong = gas_;
                ++wrong;
            }
        }
        emit log_named_uint("accepted", accepted);
        emit log_named_uint("wrong answers", wrong);
        emit log_named_uint("first wrong at outer gas", firstWrong);
        assertEq(wrong, 0, "the callee was handed less than 99,800 gas with no InsufficientGas");
        assertGt(accepted, 0);
    }

    function test_adv_sweepAsm_step1b() public {
        _sweepAsm(true);
    }

    function test_adv_sweepAsm_step2() public {
        _sweepAsm(false);
    }

    function test_adv_sweep1_step1b() public {
        _sweep(true, 65);
    }

    function test_adv_sweep1_step2_65() public {
        _sweep(false, 65);
    }

    function test_adv_sweep1_step2_195() public {
        _sweep(false, 195);
    }
}
