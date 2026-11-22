// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Scene} from "./Scene.sol";
import {SafeExec, ISafeProxyFactory, ISafeSetup} from "./SafeExec.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// @notice Adversary pass on the registered order signer at b33c90e. For the forms the plan says must be accepted (email
/// Safe v + 4, registered key), the same stored bytes are checked cold before and after each thing the party can do on
/// its own. Plan 3.1 rule 4: no more than +3,000 gas per party, or a named revert.
contract SignerCostDriftTest is Scene, SafeExec {
    bytes32 internal constant SAFE_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
    bytes32 internal constant SAFE_MSG_TYPEHASH = keccak256("SafeMessage(bytes message)");
    uint256 internal saltNonce = 7000;
    uint256 internal constant BOUND = 3_000;

    function setUp() public override {
        super.setUp();
        if (!_installSafe()) {
            vm.skip(true, "needs chain 31337");
            return;
        }
    }

    function _safe(string memory name) internal returns (uint256 pk, address owner, address safe) {
        (owner, pk) = makeAddrAndKey(name);
        address[] memory owners = new address[](1);
        owners[0] = owner;
        bytes memory init = abi.encodeCall(
            ISafeSetup.setup, (owners, 1, address(0), "", SAFE_MODULE, address(0), 0, payable(address(0)))
        );
        safe = ISafeProxyFactory(SAFE_FACTORY).createProxyWithNonce(SAFE_SINGLETON, init, saltNonce++);
    }

    function _safeSig(uint256 ownerPk, address safe, bytes32 h) internal view returns (bytes memory) {
        bytes32 domain = keccak256(abi.encode(SAFE_DOMAIN_TYPEHASH, vm.getChainId(), safe));
        bytes32 smh = keccak256(
            abi.encodePacked(
                hex"1901", domain, keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(abi.encodePacked(h))))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerPk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", smh)));
        return abi.encodePacked(r, s, uint8(v + 4));
    }

    function _cool(address a) internal {
        vm.cool(address(ex));
        vm.cool(a);
        vm.cool(SAFE_SINGLETON);
        vm.cool(SAFE_MODULE);
    }

    function _gas(X.Order memory o, bytes memory sig) internal returns (bool ok, uint256 used) {
        _cool(o.maker);
        uint256 g = gasleft();
        ok = ex.isValidOrderSignature(o, sig);
        used = g - gasleft();
    }

    function _add(address safe, address owner, address p) internal {
        _safeExec(safe, owner, safe, abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", p, 1));
    }

    /// @dev One party action per scenario.
    function _act(uint256 which, address safe, address owner) internal {
        if (which == 1) {
            _add(safe, owner, makeAddr("p1"));
        } else if (which == 2) {
            for (uint256 i; i < 5; ++i) {
                _add(safe, owner, makeAddr(string.concat("many", vm.toString(i))));
            }
        } else if (which == 3) {
            _safeExec(safe, owner, address(ex), abi.encodeCall(X.setOrderSigner, (makeAddr("zz"))));
        } else if (which == 4) {
            _safeExec(safe, owner, address(ex), abi.encodeCall(X.setOrderSigner, (owner)));
        } else if (which == 5) {
            vm.prank(owner);
            (bool ok,) = safe.call(abi.encodeWithSignature("approveHash(bytes32)", keccak256("x")));
            require(ok, "approveHash");
        } else if (which == 6) {
            address p = makeAddr("pp");
            _add(safe, owner, p);
            _safeExec(safe, owner, safe, abi.encodeWithSignature("removeOwner(address,address,uint256)", p, owner, 1));
        } else if (which == 7) {
            _safeExec(safe, owner, safe, abi.encodeWithSignature("enableModule(address)", makeAddr("mod")));
        }
    }

    function _scenario(bool registered, uint256 which) internal returns (bool ok0, uint256 g0, bool ok1, uint256 g1) {
        (uint256 pk, address owner, address safe) =
            _safe(string.concat("sc", vm.toString(registered ? 1 : 0), vm.toString(which)));
        if (registered) _safeExec(safe, owner, address(ex), abi.encodeCall(X.setOrderSigner, (owner)));
        X.Order memory o = _order(safe, m, 0, false, 40, 10 * SHARE);
        bytes memory sig = registered ? _sign(pk, o) : _safeSig(pk, safe, _hash(o));
        (ok0, g0) = _gas(o, sig); // first call after creation is dearer (creation-tx flags); take the second
        (ok0, g0) = _gas(o, sig);
        _act(which, safe, owner);
        (ok1, g1) = _gas(o, sig);
    }

    /// @dev Plan 4.5 amendment: "step 2 runs only for a signature that recovers no key". A v + 4 signature whose `s` is in
    /// the upper half makes `tryRecover` return `InvalidSignatureS` (it checks `s` before `ecrecover`), which recovers no
    /// key, so it must still reach the Safe, which does not look at `s`. Kills the mutant that counts any error other than
    /// a bad length as "recovers a key" (it survives the shipped suite).
    function test_adv_safeV4_highS_twin_stillReachesStep2() public {
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        (uint256 pk,, address safe) = _safe("highs-safe");
        X.Order memory o = _order(safe, m, 0, false, 40, 10 * SHARE);
        bytes memory low = _safeSig(pk, safe, _hash(o));
        bytes32 r;
        bytes32 s;
        uint8 v4;
        assembly {
            r := mload(add(low, 0x20))
            s := mload(add(low, 0x40))
            v4 := byte(0, mload(add(low, 0x60)))
        }
        assertTrue(ex.isValidOrderSignature(o, low), "control: the low-s form is accepted");
        bytes memory high = abi.encodePacked(r, bytes32(n - uint256(s)), uint8(((v4 - 4) == 27 ? 28 : 27) + 4));
        assertGt(uint256(bytes32(n - uint256(s))), n / 2, "the twin's s is in the upper half");
        vm.expectCall(safe, abi.encodeWithSelector(bytes4(0x1626ba7e)), 1);
        assertTrue(ex.isValidOrderSignature(o, high), "the high-s v + 4 twin of a valid Safe signature is accepted");
    }

    function test_adv_safeForms_partyActions_costDelta() public {
        for (uint256 r; r < 2; ++r) {
            for (uint256 w; w < 8; ++w) {
                uint256 s = vm.snapshotState();
                (bool ok0, uint256 g0, bool ok1, uint256 g1) = _scenario(r == 1, w);
                emit log_named_uint(r == 1 ? "registered plain, action" : "v+4 safe, action", w);
                emit log_named_uint("  before", g0);
                emit log_named_uint("  after ", g1);
                emit log_named_string("  accepted before/after", string.concat(ok0 ? "Y" : "N", ok1 ? "Y" : "N"));
                assertTrue(ok0, "control accepts");
                if (ok1) assertLe(g1, g0 + BOUND, "accepted again at more than +3,000 gas");
                vm.revertToState(s);
            }
        }
    }
}
