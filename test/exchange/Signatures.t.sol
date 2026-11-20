// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Scene} from "./Scene.sol";
import {Wallet1271} from "./Wallet1271.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";
import {MockUSDC} from "../mocks/TokenMocks.sol";

/// @notice The shared signature checker (plan sections 4.2 and 4.4): length rule, ECDSA first, bounded EIP-1271, chain and
/// contract binding, and the intake view. O2, O7, O9, O10.
contract SignaturesTest is Scene {
    Wallet1271 internal w;

    function setUp() public override {
        super.setUp();
        w = new Wallet1271();
        // the contract wallet W trades as a maker seller of option 0 with sets of its own
        _deposit(address(w), 1_000e6);
        vm.prank(address(w));
        ex.mintSets(m, 500e6);
    }

    function _e(bytes4 sel, bytes32 h) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(sel, h);
    }

    /// @dev A direct call whose maker is the contract wallet, signed by `sig` (the wallet approves that hash and sig).
    function _walletMakerCall(bytes memory sig, bool approve) internal returns (Call memory c) {
        c = _dBuy1(10e6);
        c.ms[0] = _order(address(w), m, 0, false, 40, 10e6);
        c.mss[0] = sig;
        c.ts = _sign(keyOf[T], c.t);
        if (approve) w.approve(_hash(c.ms[0]), sig);
    }

    function _bytesN(uint256 n, uint8 fill) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = bytes1(fill);
        }
    }

    // ------------------------------------------------------------------------------------------------ the length rule (step 0)
    function test_length_emptyIsRejected_takerAndMaker_andTheView() public {
        Call memory c = _dBuy1(10e6);
        c.ts = "";
        _expectNoWrite(_e(X.BadSignatureLength.selector, _hash(c.t)), _data(c));
        c = _dBuy1(10e6);
        c.mss[0] = "";
        _expectNoWrite(_e(X.BadSignatureLength.selector, _hash(c.ms[0])), _data(c));
        X.Order memory o = _order(T, m, 0, true, 70, 10e6);
        vm.expectRevert(abi.encodeWithSelector(X.BadSignatureLength.selector, _hash(o)));
        ex.isValidOrderSignature(o, "");
    }

    function test_length_195_isTheMaximum_196Rejected_boundary() public {
        bytes memory s195 = _bytesN(195, 0x11);
        Call memory c = _walletMakerCall(s195, true);
        _send(c); // 195 bytes: a wallet that approves it settles
        bytes memory s196 = _bytesN(196, 0x11);
        c = _walletMakerCall(s196, true);
        c.t.salt = 5;
        c.ts = _sign(keyOf[T], c.t);
        _expectNoWrite(_e(X.BadSignatureLength.selector, _hash(c.ms[0])), _data(c));
        X.Order memory o = _order(address(w), m, 0, false, 40, 10e6);
        vm.expectRevert(abi.encodeWithSelector(X.BadSignatureLength.selector, _hash(o)));
        ex.isValidOrderSignature(o, s196);
    }

    function test_length_rejectedBeforeAnyCall_aBurningWalletIsNeverCalled() public {
        w.setMode(Wallet1271.Mode.BURN);
        X.Order memory o = _order(address(w), m, 0, false, 40, 10e6);
        uint256 g = gasleft();
        vm.expectRevert(abi.encodeWithSelector(X.BadSignatureLength.selector, _hash(o)));
        ex.isValidOrderSignature(o, _bytesN(196, 1));
        assertLt(g - gasleft(), 60_000, "no copy, no recovery, no call: a 100,000-gas burn never ran");
    }

    // ------------------------------------------------------------------------------------------------ ECDSA (step 1)
    function test_ecdsa_wrongSigner_isBadSignature() public {
        Call memory c = _dBuy1(10e6);
        c.mss[0] = _sign(keyOf[B], c.ms[0]); // B signs A's order
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
    }

    function test_ecdsa_theZeroAddressIsNeverAValidMaker_anInvalidSignatureRecoversToZero() public {
        // ecrecover returns address(0) for a signature that recovers nothing; an order whose maker is address(0) must not
        // be accepted on that: the recovery error is checked, not only the address
        bytes memory junk = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));
        Call memory c = _dBuy1(10e6);
        c.ms[0].maker = address(0);
        c.mss[0] = junk;
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
        c = _dBuy1(10e6);
        c.t.maker = address(0);
        c.ts = junk;
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.t)), _data(c));
        assertFalse(ex.isValidOrderSignature(c.ms[0], junk));
        // and a signature of the wrong length for a zero maker, which has no code
        assertFalse(ex.isValidOrderSignature(c.t, hex"01"));
    }

    function test_ecdsa_malleableAndMalformedSignaturesAreRefused() public {
        Call memory c = _dBuy1(10e6);
        bytes memory good = c.mss[0];
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(good, 32))
            s := mload(add(good, 64))
            v := byte(0, mload(add(good, 96)))
        }
        // the high-s twin recovers the same signer in raw ecrecover, but OpenZeppelin refuses it
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(s));
        c.mss[0] = abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27));
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
        // v of 0 or 1
        c.mss[0] = abi.encodePacked(r, s, uint8(v - 27));
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
        // 64 bytes (EIP-2098 form) and 66 bytes are not 65
        c.mss[0] = abi.encodePacked(r, s);
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
        c.mss[0] = abi.encodePacked(r, s, v, uint8(0));
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
        // the genuine signature still settles
        c.mss[0] = good;
        _send(c);
    }

    function test_ecdsa_everyFieldIsSigned() public {
        // change each field after signing: the signature no longer matches
        for (uint256 i; i < 9; ++i) {
            Call memory c = _dBuy1(10e6);
            X.Order memory o = c.ms[0];
            if (i == 0) o.salt += 1;
            if (i == 1) o.maker = B;
            if (i == 2) o.marketId = m + 100; // an unknown market would fail earlier at the taker; the taker keeps m
            if (i == 3) o.option = 1;
            if (i == 4) o.isBuy = !o.isBuy;
            if (i == 5) o.price = 39;
            if (i == 6) o.size += uint128(LOT);
            if (i == 7) o.expiration += 1;
            if (i == 8) o.nonce += 1;
            c.ms[0] = o; // the old signature stays in place
            _expectNoWrite(_e(X.BadSignature.selector, _hash(o)), _data(c));
        }
    }

    function test_ecdsa_isTriedFirst_aSignerWithCodeThatSignedPlainlyNeverRunsItsCode() public {
        // an EIP-7702-style account: the address of a key, holding code that reverts on isValidSignature
        (address a, uint256 k) = makeAddrAndKey("delegated");
        keyOf[a] = k;
        _deposit(a, 1_000e6);
        vm.prank(a);
        ex.mintSets(m, 100e6);
        vm.etch(a, address(w).code); // now a "wallet" with code, mode 0 = HONEST (would answer 0xffffffff)
        Call memory c = _dBuy1(10e6);
        c.ms[0] = _order(a, m, 0, false, 40, 10e6);
        _resign(c);
        _send(c); // plain ECDSA recovers a: accepted, the code is never asked
        // while a signature that does NOT recover it falls through to the code, which refuses
        c = _dBuy1(10e6);
        c.t.salt = 9;
        c.ms[0] = _order(a, m, 0, false, 41, 10e6);
        _resign(c);
        c.mss[0] = _sign(keyOf[B], c.ms[0]);
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
    }

    // ------------------------------------------------------------------------------------------------ EIP-1271 (step 2)
    function test_1271_honestWallet_asMakerAndAsTaker() public {
        bytes memory sig = hex"deadbeef";
        Call memory c = _walletMakerCall(sig, true);
        uint256 cashBefore = ex.cash(address(w));
        _send(c);
        assertEq(ex.cash(address(w)), cashBefore + 4e6);
        // as the taker: the wallet buys from A
        Call memory d = _dBuy1(10e6);
        d.t = _order(address(w), m, 0, true, 70, 10e6);
        d.ts = hex"cafe";
        w.approve(_hash(d.t), d.ts);
        _send(d);
        assertEq(ex.positionOf(m, 0, address(w)), 500e6 - 10e6 + 10e6);
    }

    function test_1271_passesExactlyTheHashAndTheSignatureBytes() public {
        Call memory c = _walletMakerCall(hex"deadbeef", true);
        // approved for another signature of the same hash: refused; for the same signature, another hash: refused
        c.mss[0] = hex"deadbeee";
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
        c.mss[0] = hex"deadbeef";
        c.ms[0].salt = 77;
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
    }

    function test_1271_oddLengths_arePaddedAndPassedExactly() public {
        uint256[6] memory lens = [uint256(1), 31, 32, 33, 64, 130];
        for (uint256 i; i < lens.length; ++i) {
            bytes memory sig = _bytesN(lens[i], uint8(0x30 + i));
            Call memory c = _walletMakerCall(sig, false);
            c.ms[0].salt = 1000 + i;
            c.mss[0] = sig;
            w.approve(_hash(c.ms[0]), sig);
            c.t.salt = 2000 + i;
            c.ts = _sign(keyOf[T], c.t);
            _send(c);
        }
    }

    function test_1271_onlyTheExactMagic_O7() public {
        Wallet1271.Mode[5] memory bad = [
            Wallet1271.Mode.REVERT,
            Wallet1271.Mode.WRONG_MAGIC,
            Wallet1271.Mode.SHORT_RETURN,
            Wallet1271.Mode.DIRTY_TAIL,
            Wallet1271.Mode.BURN
        ];
        for (uint256 i; i < bad.length; ++i) {
            w.setMode(bad[i]);
            Call memory c = _walletMakerCall(hex"01", false);
            c.ms[0].salt = 50 + i;
            c.mss[0] = hex"01";
            _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
        }
        // a not-honest-but-lying wallet is accepted: the standard's own trust model (its owner chose it)
        w.setMode(Wallet1271.Mode.ALWAYS_OK);
        Call memory d = _walletMakerCall(hex"01", false);
        _send(d);
        // the magic word followed by a second word is accepted: only the first 32 bytes are read
        w.setMode(Wallet1271.Mode.TWO_WORDS);
        d = _walletMakerCall(hex"02", false);
        d.t.salt = 31;
        d.ms[0].salt = 31;
        d.mss[0] = hex"02";
        _resign2(d);
        _send(d);
    }

    function _resign2(Call memory c) internal view {
        c.ts = _sign(keyOf[T], c.t);
    }

    function test_1271_aGasBurner_isBadSignature_andCostsAtMostSigGas_O9() public {
        w.setMode(Wallet1271.Mode.BURN);
        X.Order memory o = _order(address(w), m, 0, false, 40, 10e6);
        uint256 g = gasleft();
        bool ok = ex.isValidOrderSignature(o, hex"01");
        uint256 used = g - gasleft();
        assertFalse(ok);
        assertGt(used, 100_000, "the wallet burned its whole allowance");
        assertLt(used, 100_000 + 30_000, "and only its allowance: all gas is never forwarded");
        // in a settlement it is BadSignature, never a revert of another kind or an out-of-gas of the whole call
        Call memory c = _walletMakerCall(hex"01", false);
        c.mss[0] = hex"01";
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
    }

    function test_calibration_theWalletSeesAbout97kWhenGivenSigGas() public {
        w.setMode(Wallet1271.Mode.GAS_ECHO);
        (bool ok, bytes memory ret) =
            address(w).staticcall{gas: 100_000}(abi.encodeCall(Wallet1271.isValidSignature, (bytes32(0), hex"01")));
        assertTrue(ok);
        uint256 seen = abi.decode(ret, (uint256));
        assertGt(
            seen,
            96_000,
            "calibration of NEEDS_NEAR_ALL: its 96,000 threshold sits just under what an exact bound gives"
        );
        assertLt(seen, 100_000);
    }

    function test_1271_noCallReceivesMoreThanSigGas_O9() public {
        // approves only with more than 100,000 gas left: impossible when the call is given exactly 100,000
        w.setMode(Wallet1271.Mode.NEEDS_MORE_GAS);
        X.Order memory o = _order(address(w), m, 0, false, 40, 10e6);
        assertFalse(ex.isValidOrderSignature{gas: 30_000_000}(o, hex"01"));
        // with the bound at 95,000 and a threshold under it, the wallet does see its allowance
        w.setMode(Wallet1271.Mode.NEEDS_95K);
        assertTrue(ex.isValidOrderSignature{gas: 30_000_000}(o, hex"01"));
        // and the value is exactly 100,000, not a trimmed figure
        w.setMode(Wallet1271.Mode.NEEDS_NEAR_ALL);
        assertTrue(ex.isValidOrderSignature{gas: 30_000_000}(o, hex"01"), "a trimmed bound would starve this wallet");
    }

    function test_1271_tooLittleGas_revertsInsufficientGas_neverReportsABadSignature_O9() public {
        w.setMode(Wallet1271.Mode.NEEDS_NEAR_ALL);
        X.Order memory o = _order(address(w), m, 0, false, 40, 10e6);
        uint256 insufficient;
        uint256 accepted;
        for (uint256 g = 95_000; g <= 140_000; g += 250) {
            (bool ok, bytes memory ret) =
                address(ex).staticcall{gas: g}(abi.encodeCall(X.isValidOrderSignature, (o, hex"01")));
            if (ok) {
                assertTrue(abi.decode(ret, (bool)), "a short gas limit must never turn a valid signature into false");
                ++accepted;
            } else if (ret.length == 4 && bytes4(ret) == X.InsufficientGas.selector) {
                ++insufficient;
            }
        }
        assertGt(insufficient, 0, "some limits are too short, and say so");
        assertGt(accepted, 0, "and some are enough");
    }

    function test_1271_insufficientGasInMatchOrders_isTheNamedError() public {
        w.setMode(Wallet1271.Mode.NEEDS_NEAR_ALL);
        Call memory c = _walletMakerCall(hex"01", true);
        bytes memory data = _data(c);
        uint256 insufficient;
        for (uint256 g = 120_000; g <= 400_000; g += 4_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(operator);
            (bool ok, bytes memory ret) = address(ex).call{gas: g}(data);
            vm.revertToState(snap);
            if (!ok && ret.length == 4 && bytes4(ret) == X.InsufficientGas.selector) ++insufficient;
            // never a BadSignature for a signature that is good
            if (!ok && ret.length >= 4) {
                assertTrue(bytes4(ret) != X.BadSignature.selector, "a short limit must not blame the maker");
            }
        }
        assertGt(insufficient, 0, "InsufficientGas is reached through matchOrders");
    }

    function test_1271_returnDataIsNeverCopied_aBombCostsOnlyWhatTheWalletSpends() public {
        X.Order memory o = _order(address(w), m, 0, false, 40, 10e6);
        w.approve(_hash(o), hex"01");
        uint256 g0 = gasleft();
        ex.isValidOrderSignature(o, hex"01");
        uint256 honest = g0 - gasleft();
        w.setMode(Wallet1271.Mode.BOMB);
        // what the wallet itself spends producing 190 KB of return data
        uint256 g1 = gasleft();
        (bool okW,) = address(w).staticcall(abi.encodeCall(Wallet1271.isValidSignature, (_hash(o), hex"01")));
        uint256 walletCost = g1 - gasleft();
        assertTrue(okW);
        assertGt(walletCost, 60_000, "the bomb is real");
        uint256 g2 = gasleft();
        assertTrue(ex.isValidOrderSignature(o, hex"01"), "a bomb that returns the magic first is accepted");
        uint256 bomb = g2 - gasleft();
        assertLe(bomb, honest + walletCost + 3_000, "the exchange paid no copy of the 190 KB");
    }

    // ------------------------------------------------------------------------------------------------ chain and contract binding
    function test_binding_aSignatureForAnotherExchangeIsRefused() public {
        X other = new X(address(usd), treasury);
        Call memory c = _dBuy1(10e6);
        bytes32 foreign = _hashFor(address(other), c.ms[0]);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[A], foreign);
        c.mss[0] = abi.encodePacked(r, s, v);
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
    }

    function test_binding_O2byChain_theSeparatorFollowsBlockChainid() public {
        uint256 originalChain = vm.getChainId();
        Call memory c = _dBuy1(10e6);
        c.t.expiration = 0;
        c.ms[0].expiration = 0;
        _resign(c); // signed for the current chain
        vm.chainId(10143);
        // after the chain id changed under the deployed exchange, an order signed for the old chain is refused
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.t)), _data(c));
        // and one signed for the new chain settles
        _resign(c);
        _send(c);
        // back: the new chain's signatures stop working, the old ones work again (the separator is never cached across chains)
        vm.chainId(originalChain);
        Call memory d = _dBuy1(10e6);
        d.t.salt = 3;
        d.t.expiration = 0;
        d.ms[0].expiration = 0;
        d.ms[0].salt = 3;
        _resign(d);
        vm.chainId(10143);
        _expectNoWrite(_e(X.BadSignature.selector, _hash(d.t)), _data(d));
        vm.chainId(originalChain);
        _send(d);
    }

    function test_binding_domainFieldsAreThePlans() public view {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address vc,,) = ex.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "Mako Market Exchange");
        assertEq(version, "1");
        assertEq(chainId, vm.getChainId());
        assertEq(vc, address(ex));
        assertEq(ex.ORDER_TYPEHASH(), ORDER_TYPEHASH, "the Order type string is the plan's, byte for byte");
        assertEq(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            DOMAIN_TYPEHASH
        );
    }

    // ------------------------------------------------------------------------------------------------ the intake view
    function test_view_isValidOrderSignature_trueForGood_falseForBad_neverWrites() public {
        X.Order memory o = _order(A, m, 0, false, 40, 10e6);
        assertTrue(ex.isValidOrderSignature(o, _sign(keyOf[A], o)));
        assertFalse(ex.isValidOrderSignature(o, _sign(keyOf[B], o)));
        // a contract wallet through the same bounded check
        X.Order memory wo = _order(address(w), m, 0, false, 40, 10e6);
        assertFalse(ex.isValidOrderSignature(wo, hex"0102"));
        w.approve(_hash(wo), hex"0102");
        assertTrue(ex.isValidOrderSignature(wo, hex"0102"));
    }
}
