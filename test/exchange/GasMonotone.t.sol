// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ExchangeBase} from "./ExchangeBase.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// Plan section 3.1 rule 4 (r31 d6, d7): the whole-class property behind plan 4.4 "Amount slots never return to zero" and 6.2 out-of-gas rule 3.
///
/// Nothing a party (or a third party) does on its own between the settler's gas estimate and inclusion may make
/// `matchOrders` cost more than it did at the estimate. For each kind (direct with 1, 2 and 3 makers, mint, merge) the
/// test builds a valid matched call with fuzzed party states (cash, shares, net, touched or untouched records, market
/// totals), measures its gas, reverts to the snapshot, applies 1 to 4 fuzzed actions the parties or a third party can
/// take for themselves (deposit, withdraw, mintSets, mergeSets, redeem, cancelOrders of an unrelated order,
/// incrementNonce), and measures the same call again. An action that makes the call revert (the order
/// itself invalid: cash, shares, nonce) is undone and skipped; those revert with named errors and are tested elsewhere.
///
/// Asserts gas_after <= estimate + TOL_PER_PARTY per party (taker plus makers). The registered signer of the spike's
/// action list (`setOrderSigner`) is not part of this build.
contract GasMonotoneTest is ExchangeBase {
    uint256 internal constant GAS_CAP = 20_000_000;
    /// One write that changes a slot costs 2,800 more than one that rewrites the same value (EIP-2200 warm: 2,900 vs 100).
    /// That wobble is allowed once per party in the call and nothing more; anything above is a defect.
    uint256 internal constant TOL_PER_PARTY = 3_000;
    uint8 internal constant DIRECT = 0;
    uint8 internal constant MINT = 1;
    uint8 internal constant MERGE = 2;

    struct Party {
        address a;
        uint256 k;
    }

    int256 internal maxDelta;
    Party[] internal ps; // taker, makers..., two third parties
    uint256 internal M;
    bytes internal data;

    // ------------------------------------------------------------------------------------------------ fuzz entries
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_gasMonotone_direct1(uint256 seed) public {
        _run(DIRECT, 1, seed, "direct1");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_gasMonotone_direct2(uint256 seed) public {
        _run(DIRECT, 2, seed, "direct2");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_gasMonotone_direct3(uint256 seed) public {
        _run(DIRECT, 3, seed, "direct3");
    }

    /// forge-config: default.fuzz.runs = 96
    function testFuzz_gasMonotone_direct10(uint256 seed) public {
        _run(DIRECT, 10, seed, "direct10");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_gasMonotone_mint(uint256 seed) public {
        _run(MINT, 0, seed, "mint");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_gasMonotone_merge(uint256 seed) public {
        _run(MERGE, 0, seed, "merge");
    }

    /// Codex R14 F1 counterexample (merge used 376,540 against a 373,950 bound that counted one party); kept as a
    /// regression: it must pass with the bound counting the taker and every maker.
    function test_gasMonotone_merge_codexR14Counterexample() public {
        _run(MERGE, 0, 15639020638419159078663078, "merge-r14");
    }

    // ------------------------------------------------------------------------------------------------ the property
    function _run(uint8 kindId, uint256 nM, uint256 seed, string memory tag) internal {
        _build(kindId, nM, seed);
        uint256 s0 = vm.snapshotState();
        (bool ok0, uint256 est) = _gas(data);
        require(ok0, "fixture: the estimate call must settle");
        vm.revertToState(s0);

        uint256 nAct = 1 + _r(seed, 900) % 4;
        for (uint256 i; i < nAct; ++i) {
            uint256 pre = vm.snapshotState();
            if (!_apply(seed, i)) {
                vm.revertToState(pre);
                continue;
            }
            uint256 pr = vm.snapshotState();
            (bool ok,) = _gas(data);
            vm.revertToState(pr);
            if (!ok) vm.revertToState(pre);
        }

        (bool okA, uint256 used) = _gas(data);
        require(okA, "fixture: the call after the actions must settle");
        int256 delta = int256(used) - int256(est);
        if (delta > maxDelta) maxDelta = delta;
        tag;
        // parties in the call = taker + makers as built (mint and merge derive their makers from the option count, so
        // nM is 0 for them); ps also holds two third parties, who act but are not in the call (Codex R14 F1)
        uint256 nParties = ps.length - 2;
        assertLe(
            used, est + TOL_PER_PARTY * nParties, "a party's own action made matchOrders dearer than at the estimate"
        );
    }

    function _gas(bytes memory d) internal returns (bool ok, uint256 used) {
        // a test is one transaction: make every account and slot the call can touch cold again, as in a real block
        vm.cool(address(ex));
        vm.cool(operator);
        vm.cool(address(usd));
        for (uint256 i; i < ps.length; ++i) {
            vm.cool(ps[i].a);
        }
        ex.MAX_MAKERS(); // constant read: warms the exchange account (its slots stay cold) so the CALL's own cold-account
        // charge, which depends on what ran earlier in this test transaction, is the same for every measurement
        vm.prank(operator);
        uint256 g = gasleft();
        (ok,) = address(ex).call{gas: GAS_CAP}(d);
        used = g - gasleft();
    }

    // ------------------------------------------------------------------------------------------------ actions
    function _apply(uint256 seed, uint256 i) internal returns (bool) {
        uint256 r = _r(seed, 100 + i);
        // 3 in 4 actions come from a party of the call (the interesting ones), the rest from anyone
        address a = ps[((r >> 120) & 3 != 0 ? r % (ps.length - 2) : r % ps.length)].a;
        uint256 kind = (r >> 8) % 11;
        if (kind >= 9) kind -= 7; // mintSets and mergeSets twice as likely
        uint256 amt = _amt(r >> 16);
        if (kind == 0 || kind == 8) {
            usd.mint(a, amt);
            vm.prank(a);
            usd.approve(address(ex), amt);
            return _try(a, abi.encodeCall(ex.deposit, (amt)));
        }
        if (kind == 1) {
            uint256 c = ex.cash(a);
            if ((r >> 100) & 1 == 1 || amt > c) amt = c;
            return _try(a, abi.encodeCall(ex.withdraw, (amt)));
        }
        if (kind == 9) {
            // merge every complete set the account holds (empties a third party's slot contribution, zeroes a net)
            uint256 nOpt = ex.marketOf(M).nOptions;
            amt = type(uint256).max;
            for (uint256 o; o < nOpt; ++o) {
                uint256 h = ex.positionOf(M, uint8(o), a);
                if (h < amt) amt = h;
            }
            amt = amt / LOT * LOT;
            return amt != 0 && _try(a, abi.encodeCall(ex.mergeSets, (M, amt)));
        }
        if (kind == 2) return _try(a, abi.encodeCall(ex.mintSets, (M, amt)));
        if (kind == 3) return _try(a, abi.encodeCall(ex.mergeSets, (M, amt)));
        if (kind == 4) return _try(a, abi.encodeCall(ex.redeem, (M)));
        if (kind == 5) {
            X.Order[] memory os = new X.Order[](1);
            os[0] = _order(a, M, 0, true, 7, 10 * SHARE);
            os[0].salt = r;
            return _try(a, abi.encodeCall(ex.cancelOrders, (os)));
        }
        if (kind == 6) return _try(a, abi.encodeCall(ex.incrementNonce, ()));
        return _try(a, abi.encodeCall(ex.incrementNonce, ()));
    }

    function _try(address from, bytes memory cd) internal returns (bool ok) {
        vm.prank(from);
        (ok,) = address(ex).call(cd);
    }

    // ------------------------------------------------------------------------------------------------ fixture
    function _r(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// Amounts that cross the interesting boundaries (a receipt vs a net, a position vs a fill), all lot multiples.
    function _amt(uint256 r) internal pure returns (uint256) {
        uint256 c = r % 8;
        if (c == 0) return LOT;
        if (c == 1) return 5 * LOT;
        if (c == 2) return SHARE;
        if (c == 3) return 3 * SHARE;
        if (c == 4) return 10 * SHARE;
        if (c == 5) return 25 * SHARE;
        if (c == 6) return (1 + (r >> 8) % 3000) * LOT;
        return 100 * LOT;
    }

    struct Spec {
        bool isBuy;
        uint8 option;
        uint8 price;
        uint256 fill;
        uint256 pay; // cash a buyer needs for this call
    }

    function _build(uint8 kindId, uint256 nM, uint256 seed) internal {
        delete ps;
        uint8 nOpt = kindId == DIRECT ? 2 : uint8(3 + _r(seed, 1) % 2);
        uint256 n = kindId == DIRECT ? nM : nOpt - 1;
        M = _market(nOpt);
        (Spec[] memory sp, uint256 total) = _specs(kindId, n, seed);
        _assemble(sp, n, seed, total);
    }

    function _specs(uint8 kindId, uint256 n, uint256 seed) internal view returns (Spec[] memory sp, uint256 total) {
        bool takerBuy = kindId == DIRECT ? (_r(seed, 2) & 1 == 0) : kindId == MINT;
        sp = new Spec[](n + 1); // 0 = taker
        if (kindId == DIRECT) {
            sp[0] = Spec(takerBuy, 0, takerBuy ? 70 : 30, 0, 0);
            for (uint256 i = 1; i <= n; ++i) {
                uint256 f = _amt(_r(seed, 10 + i));
                total += f;
                sp[i] =
                    Spec(!takerBuy, 0, uint8(takerBuy ? 20 + _r(seed, 20 + i) % 40 : 40 + _r(seed, 20 + i) % 40), f, 0);
            }
            sp[0].fill = total;
            _setPaysDirect(sp, takerBuy);
        } else {
            total = _amt(_r(seed, 10));
            uint256 sum;
            for (uint256 i = 1; i <= n; ++i) {
                uint8 pr = uint8(5 + _r(seed, 20 + i) % 16);
                sum += pr;
                sp[i] = Spec(takerBuy, uint8(i), pr, total, 0);
            }
            sp[0] = Spec(takerBuy, 0, takerBuy ? 99 : 1, total, 0);
            _setPays(sp, 100 - sum, kindId);
        }
    }

    function _assemble(Spec[] memory sp, uint256 n, uint256 seed, uint256 total) internal {
        X.Order[] memory ms = new X.Order[](n);
        bytes[] memory sigs = new bytes[](n);
        uint128[] memory fills = new uint128[](n);
        for (uint256 i; i <= n + 2; ++i) {
            (address a, uint256 k) = makeAddrAndKey(string.concat("gm", vm.toString(seed), "-", vm.toString(i)));
            ps.push(Party(a, k));
            if (i > n) {
                _fundThird(a, _r(seed, 300 + i));
                continue;
            }
            _fund(a, sp[i], _r(seed, 300 + i));
            if (i > 0) {
                ms[i - 1] = _ord(a, sp[i]);
                sigs[i - 1] = _sign(k, ms[i - 1]);
                fills[i - 1] = uint128(sp[i].fill);
            }
        }
        X.Order memory to = _ord(ps[0].a, sp[0]);
        data = abi.encodeCall(X.matchOrders, (to, _sign(ps[0].k, to), ms, sigs, fills, uint128(total)));
    }

    function _ord(address a, Spec memory s) internal view returns (X.Order memory) {
        return _order(a, M, s.option, s.isBuy, s.price, s.fill);
    }

    function _setPays(Spec[] memory sp, uint256 tp, uint8 kindId) internal view {
        for (uint256 i = 1; i < sp.length; ++i) {
            if (sp[i].isBuy) sp[i].pay = sp[i].fill * sp[i].price / 100;
        }
        if (kindId == MINT) sp[0].pay = sp[0].fill * tp / 100 + ex.feeOf(M, sp[0].fill, tp);
    }

    function _setPaysDirect(Spec[] memory sp, bool takerBuy) internal view {
        for (uint256 i = 1; i < sp.length; ++i) {
            uint256 v = sp[i].fill * sp[i].price / 100;
            if (takerBuy) sp[0].pay += v + ex.feeOf(M, sp[i].fill, sp[i].price);
            else sp[i].pay = v;
        }
    }

    /// One party's starting state: an optional prelude of its own trades (touches its account record, sets a net), the
    /// cash a buyer needs (exact or with spare), and the shares a seller needs (seeded: net 0, or with spare).
    function _fund(address a, Spec memory s, uint256 r) internal {
        // 1 mint, 2 mint+merge (touched, net 0), 3 mint+partial merge; 0 (untouched, rarely) can only make the later
        // call cheaper, so most parties start with every settlement slot already non-zero, the costly baseline
        uint256 prelude = r % 16 == 0 ? 0 : 1 + (r >> 4) % 3;
        uint256 mintAmt = _amt(r >> 8);
        uint256 cashAmt = s.isBuy ? s.pay + ((r >> 16) & 1 == 1 ? 0 : _amt(r >> 20)) : _amt(r >> 21);
        if (prelude != 0) cashAmt += mintAmt;
        if (cashAmt != 0) _deposit(a, cashAmt);
        if (prelude != 0) {
            vm.startPrank(a);
            ex.mintSets(M, mintAmt);
            if (prelude == 2) ex.mergeSets(M, mintAmt);
            if (prelude == 3) ex.mergeSets(M, mintAmt > LOT ? mintAmt / 2 / LOT * LOT : 0 == 0 ? mintAmt : 0);
            vm.stopPrank();
        }
        if (s.isBuy) {
            // a buyer must still be able to pay after the prelude spent cash: top up to exactly pay or more
            uint256 c = ex.cash(a);
            if (c < s.pay) _deposit(a, s.pay - c);
        } else {
            uint256 have = ex.positionOf(M, s.option, a);
            if (have < s.fill) {
                uint256 need = s.fill - have + ((r >> 30) & 3 == 0 ? 0 : _amt(r >> 34));
                _mint(a, M, need);
            }
        }
    }

    function _fundThird(address a, uint256 r) internal {
        _deposit(a, 1_000 * SHARE);
        if (r & 3 != 0) {
            vm.prank(a);
            ex.mintSets(M, _amt(r >> 8));
        }
    }
}
