// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Scene} from "./Scene.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// @notice Fuzz tests: O13 (no input reaches a Solidity panic), conservation across random settlements, the fee formula,
/// the signature length rule, and the sentinel rule (no amount slot a settlement writes ever returns to zero).
contract FuzzTest is Scene {
    function _r(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    function _known(bytes4 sel) internal pure returns (bool) {
        bytes4[24] memory k = [
            X.NotOperator.selector,
            X.Paused.selector,
            X.TradingClosed.selector,
            X.InsufficientGas.selector,
            X.BadSignature.selector,
            X.NonceMismatch.selector,
            X.OrderCancelled.selector,
            X.Expired.selector,
            X.Overfill.selector,
            X.InsufficientCash.selector,
            X.InsufficientShares.selector,
            X.PositionCap.selector,
            X.PartyRefused.selector,
            X.BadSignatureLength.selector,
            X.BadOrderField.selector,
            X.SelfMatch.selector,
            X.PriceNotCrossed.selector,
            X.WrongKind.selector,
            X.BadMakerCount.selector,
            X.LengthMismatch.selector,
            X.FillMismatch.selector,
            X.SetPriceSum.selector,
            X.MarketMismatch.selector,
            bytes4(0)
        ];
        for (uint256 i; i < 23; ++i) {
            if (k[i] == sel) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------------------------------------ O13
    /// @dev A random call, built from signed orders over random (often out of range) fields, random fills and array shapes,
    /// with some signatures broken. It either settles or reverts with one of the 23 named errors: never a panic
    /// (`Panic(uint256)`, 0x4e487b71), never an empty revert.
    /// forge-config: default.fuzz.runs = 1500
    /// forge-config: ci.fuzz.runs = 1500
    function testFuzz_O13_matchOrdersNeverPanics(uint256 seed) public {
        address[4] memory ps = [T, A, B, C];
        uint256 nM = _r(seed, 0) % 13; // 0 to 12 makers
        X.Order memory to = _rand(ps[_r(seed, 1) % 4], seed, 100);
        X.Order[] memory ms = new X.Order[](nM);
        bytes[] memory mss = new bytes[](_r(seed, 2) % 8 == 0 ? (nM + 1) % 13 : nM);
        uint128[] memory fs = new uint128[](_r(seed, 3) % 8 == 0 ? (nM + 2) % 13 : nM);
        uint256 kind = _r(seed, 4) % 3; // shapes: random, direct-like, set-like
        for (uint256 i; i < nM; ++i) {
            ms[i] = _rand(ps[_r(seed, 10 + i) % 4], seed, 200 + i);
            if (kind != 0) {
                ms[i].marketId = to.marketId;
                if (kind == 1) {
                    ms[i].option = to.option;
                    ms[i].isBuy = !to.isBuy;
                } else {
                    ms[i].option = uint8((to.option + 1 + i) % 3);
                    ms[i].isBuy = to.isBuy;
                }
            }
            if (i < mss.length) mss[i] = _sigFor(ms[i], seed, 300 + i);
            if (i < fs.length) fs[i] = uint128(_fill(seed, 400 + i));
        }
        bytes memory ts = _sigFor(to, seed, 500);
        bytes memory data = _data(Call(to, ts, ms, mss, fs, uint128(_fill(seed, 600))));
        vm.prank(operator);
        (bool ok, bytes memory ret) = address(ex).call(data);
        if (!ok) {
            assertTrue(ret.length >= 4, "an empty revert");
            assertTrue(_known(bytes4(ret)), "a revert that is not one of the named errors (a panic?)");
        }
    }

    function _rand(address maker, uint256 seed, uint256 salt) internal view returns (X.Order memory o) {
        uint256 r = _r(seed, salt);
        o.salt = r;
        o.maker = maker;
        o.marketId = (r >> 8) % 7 == 0 ? (r >> 16) % 5 : m; // sometimes an unknown market
        o.option = (r >> 20) % 9 == 0 ? uint8(r >> 24) : uint8((r >> 24) % 3);
        o.isBuy = (r >> 32) & 1 == 1;
        o.price = (r >> 40) % 11 == 0 ? uint8(r >> 48) : uint8(1 + (r >> 48) % 99);
        o.size = (r >> 56) % 9 == 0 ? uint128(r >> 64) : uint128(((r >> 64) % 400 + 1) * LOT);
        o.expiration = (r >> 130) % 5 == 0 ? uint64(r >> 140) : uint64(block.timestamp + 1 days);
        o.nonce = (r >> 190) % 7 == 0 ? uint64(r >> 200) % 3 : uint64(ex.nonces(maker));
    }

    function _fill(uint256 seed, uint256 salt) internal pure returns (uint256) {
        uint256 r = _r(seed, salt);
        if (r % 9 == 0) return r >> 8; // anything, including values near 2^128 and 2^256
        if (r % 9 == 1) return (r >> 8) % 100; // not a lot multiple
        return ((r >> 8) % 400 + 1) * LOT;
    }

    function _sigFor(X.Order memory o, uint256 seed, uint256 salt) internal view returns (bytes memory) {
        uint256 r = _r(seed, salt);
        if (r % 10 == 0) return new bytes((r >> 8) % 300); // any length, zeros
        if (r % 10 == 1) return _sign(keyOf[A], o); // someone else's signature
        return _sign(keyOf[o.maker], o);
    }

    /// @dev The same through the intake view: only a bool or BadSignatureLength.
    function testFuzz_O13_isValidOrderSignatureNeverPanics(uint256 seed, uint16 len) public view {
        X.Order memory o = _rand(A, seed, 1);
        bytes memory sig = new bytes(len % 400);
        for (uint256 i; i < sig.length; ++i) {
            sig[i] = bytes1(uint8(_r(seed, i)));
        }
        try ex.isValidOrderSignature(o, sig) returns (bool) {
            assertTrue(sig.length != 0 && sig.length <= 195);
        } catch (bytes memory ret) {
            assertEq(bytes4(ret), X.BadSignatureLength.selector);
            assertTrue(sig.length == 0 || sig.length > 195);
        }
    }

    function testFuzz_signatureLengthRule(uint16 len) public view {
        uint256 n = uint256(len) % 400;
        X.Order memory o = _order(A, m, 0, false, 40, 10e6);
        bytes memory sig = new bytes(n);
        (bool ok, bytes memory ret) = address(ex).staticcall(abi.encodeCall(X.isValidOrderSignature, (o, sig)));
        if (n == 0 || n > 195) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(X.BadSignatureLength.selector, _hash(o)));
        } else {
            assertTrue(ok, "any length from 1 to 195 is checked, not refused");
        }
    }

    // ------------------------------------------------------------------------------------------------ conservation
    /// @dev Random direct match, mint and merge calls between funded parties: when one settles, conservation (X1, X2, X15)
    /// holds and the parties' cash moved by exactly the plan's amounts.
    /// forge-config: default.fuzz.runs = 600
    /// forge-config: ci.fuzz.runs = 600
    function testFuzz_settlementsConserveMoneyAndSets(uint256 seed) public {
        uint256 steps = 1 + _r(seed, 0) % 4;
        for (uint256 s; s < steps; ++s) {
            uint256 k = _r(seed, 10 + s) % 3;
            uint256 size = (1 + _r(seed, 20 + s) % 300) * LOT * 10;
            Call memory c;
            if (k == 0) c = _dBuy1(size);
            else if (k == 1) c = _mint3(size);
            else c = _merge3(size);
            // random prices inside the crossing range, and a random partial fill
            uint256 fill = (1 + _r(seed, 30 + s) % (size / LOT)) * LOT;
            for (uint256 i; i < c.fs.length; ++i) {
                c.fs[i] = uint128(fill);
            }
            c.tf = uint128(fill);
            if (k == 0) {
                c.ms[0].price = uint8(1 + _r(seed, 40 + s) % 70); // at or under the taker's limit of 70
            } else if (k == 1) {
                c.ms[0].price = uint8(1 + _r(seed, 40 + s) % 30);
                c.ms[1].price = uint8(1 + _r(seed, 41 + s) % 30); // sum <= 60: the taker pays >= 40 <= its limit 60? tp = 100 - sum >= 40
                c.t.price = 99;
            } else {
                c.ms[0].price = uint8(1 + _r(seed, 40 + s) % 30);
                c.ms[1].price = uint8(1 + _r(seed, 41 + s) % 30);
                c.t.price = 1;
            }
            c.t.salt = _r(seed, 50 + s);
            c.ms[0].salt = _r(seed, 51 + s);
            if (c.ms.length > 1) c.ms[1].salt = _r(seed, 52 + s);
            _resign(c);
            uint256 snap = vm.snapshotState();
            vm.prank(operator);
            (bool ok,) = address(ex).call(_data(c));
            if (!ok) {
                vm.revertToState(snap);
                continue;
            }
            _assertConserved(m);
        }
    }

    function testFuzz_feeFormula(uint16 rate, uint128 size, uint8 t) public {
        rate = uint16(bound(rate, 0, 700));
        t = uint8(bound(t, 0, 99));
        uint256 mm = _marketCap(2, rate, CAP);
        uint256 fee = ex.feeOf(mm, size, t);
        uint256 num = uint256(rate) * size * t * (100 - t);
        // ceil(num / 1e8), written out two ways
        assertGe(fee * 1e8, num, "never rounds down");
        assertTrue(fee == 0 || (fee - 1) * 1e8 < num, "and never more than one unit up");
        if (rate == 0 || t == 0) assertEq(fee, 0);
    }

    // ------------------------------------------------------------------------------------------------ the sentinel rule
    /// @dev Plan 3.1 rule 1 (r31 d5): every amount slot `matchOrders` writes stays non-zero for good. A settlement is
    /// recorded; then each party withdraws everything, merges every set it can, and does it all again; no slot the
    /// settlement wrote may read zero afterwards.
    /// forge-config: default.fuzz.runs = 200
    /// forge-config: ci.fuzz.runs = 200
    function testFuzz_noAmountSlotReturnsToZero(uint256 seed) public {
        uint256 k = seed % 3;
        Call memory c = k == 0 ? _dBuy1(100e6) : k == 1 ? _mint3(100e6) : _merge3(100e6);
        vm.startStateDiffRecording();
        _send(c);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        // every slot of the exchange the call wrote
        bytes32[] memory slots = new bytes32[](256);
        uint256 n;
        for (uint256 i; i < acc.length; ++i) {
            for (uint256 j; j < acc[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory sa = acc[i].storageAccesses[j];
                if (sa.account == address(ex) && sa.isWrite && sa.newValue != bytes32(0)) slots[n++] = sa.slot;
            }
        }
        assertGt(n, 5);
        // each party empties itself, in a seeded order, repeatedly
        address[4] memory ps = [T, A, B, C];
        for (uint256 round; round < 2; ++round) {
            for (uint256 i; i < 4; ++i) {
                address a = ps[(i + seed % 4) % 4];
                uint256 minPos = type(uint256).max;
                for (uint8 o; o < 3; ++o) {
                    uint256 p = ex.positionOf(m, o, a);
                    if (p < minPos) minPos = p;
                }
                vm.startPrank(a);
                if (minPos >= LOT) ex.mergeSets(m, minPos / LOT * LOT);
                ex.withdraw(ex.cash(a));
                vm.stopPrank();
            }
        }
        for (uint256 i; i < n; ++i) {
            assertTrue(vm.load(address(ex), slots[i]) != bytes32(0), "a slot the settlement wrote went back to zero");
        }
    }
}
