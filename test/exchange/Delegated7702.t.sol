// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Scene} from "./Scene.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// @notice A delegate that burns every bit of gas it is given, for every call.
contract BurnDelegate {
    fallback() external {
        while (true) {}
    }
}

/// @notice Adversary pass at b33c90e: an EOA maker with an EIP-7702 delegation (code `0xef0100 || delegate`) signing
/// plainly (plan 4.6: "passes step 1"), before and after the delegation is added or changed to a gas burner. The check
/// must cost the same and never call the delegate.
contract Delegated7702Test is Scene {
    function _delegate(address eoa, address to) internal {
        vm.etch(eoa, bytes.concat(hex"ef0100", bytes20(to)));
    }

    function test_adv_7702_plainSig_costsTheSame_neverCallsDelegate() public {
        (address e, uint256 ek) = makeAddrAndKey("d7702");
        X.Order memory o = _order(e, m, 0, false, 40, 10 * SHARE);
        bytes memory sig = _sign(ek, o);
        vm.cool(address(ex));
        vm.cool(e);
        uint256 g = gasleft();
        assertTrue(ex.isValidOrderSignature(o, sig));
        uint256 plain = g - gasleft();
        address burn = address(new BurnDelegate());
        _delegate(e, burn);
        assertEq(e.code.length, 23, "delegation designator is the code");
        vm.expectCall(burn, "", 0);
        vm.cool(address(ex));
        vm.cool(e);
        g = gasleft();
        bool ok = ex.isValidOrderSignature(o, sig);
        uint256 delegated = g - gasleft();
        assertTrue(ok, "a delegated EOA signing plainly is accepted");
        assertLe(delegated, plain + 3_000, "delegation added: more than +3,000 gas");
        // re-pointed to another delegate: same
        _delegate(e, address(this));
        vm.cool(address(ex));
        vm.cool(e);
        g = gasleft();
        assertTrue(ex.isValidOrderSignature(o, sig));
        assertLe(g - gasleft(), plain + 3_000, "delegation changed: more than +3,000 gas");
    }

    /// @dev A delegated EOA that registers a key and signs with it: plan 4.5 says an EOA's registration "never validates
    /// anything (the owner check needs code)", but a delegated EOA has code, so the delegate's `isOwner` runs. Not a
    /// path Mako's intake books (it must pass step 1), recorded as a fact.
    function test_adv_7702_registeredKeyOnDelegatedEoa_runsDelegateCode() public {
        (address e,) = makeAddrAndKey("d7702-reg");
        (address key, uint256 kk) = makeAddrAndKey("d7702-key");
        vm.prank(e);
        ex.setOrderSigner(key);
        address burn = address(new BurnDelegate());
        _delegate(e, burn);
        X.Order memory o = _order(e, m, 0, false, 40, 10 * SHARE);
        bytes memory sig = _sign(kk, o);
        uint256 g = gasleft();
        assertFalse(ex.isValidOrderSignature(o, sig));
        uint256 used = g - gasleft();
        // a burning delegate that ran spent the whole SIG_GAS; if forge ignores the designator nothing ran
        emit log_named_uint("gas used by the check", used);
        assertGt(used, 90_000, "the delegate's code did not run");
    }
}
