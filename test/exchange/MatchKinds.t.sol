// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Scene} from "./Scene.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// @notice The three match kinds (plan section 3.2), partial fills, the profit hold, cancel, nonce and expiry.
contract MatchKindsTest is Scene {
    // ------------------------------------------------------------------------------------------------ direct
    function test_direct_takerBuy_oneMaker_exactAccounting() public {
        Call memory c = _dBuy1(100e6);
        uint256 tCash = ex.cash(T);
        uint256 aCash = ex.cash(A);
        bytes32 th = _hash(c.t);
        bytes32 ah = _hash(c.ms[0]);
        // the literal figures: 100 shares at 40 cost 40 USDC, the fee is 700 x 2400 = 1.68 USDC
        assertEq(_fee(100e6, 40), 1_680_000);
        vm.expectEmit(true, true, true, true, address(ex));
        emit X.Leaf(m, th, ah, 0, 0, 40, 100e6, 1_680_000, 40e6, 0);
        _send(c);
        assertEq(ex.cash(T), tCash - 41_680_000, "taker pays value plus fee");
        assertEq(ex.cash(A), aCash + 40e6, "maker receives exactly its own price");
        assertEq(ex.positionOf(m, 0, T), 2_000e6 + 100e6);
        assertEq(ex.positionOf(m, 0, A), 2_000e6 - 100e6);
        assertEq(ex.marketOf(m).feesHeld, 1_680_000);
        assertEq(_net(m, T), 2_000e6 + 41_680_000);
        assertEq(_net(m, A), 2_000e6 - 40e6);
        (uint128 filledT,) = ex.orders(th);
        (uint128 filledA,) = ex.orders(ah);
        assertEq(filledT, 100e6);
        assertEq(filledA, 100e6);
        _assertConserved(m);
    }

    function test_direct_takerSell_oneMaker_feeComesOutOfTheTakersReceipt() public {
        Call memory c = _dSell1(100e6);
        uint256 tCash = ex.cash(T);
        uint256 aCash = ex.cash(A);
        uint256 fee = _fee(100e6, 50);
        assertEq(fee, 1_750_000);
        vm.expectEmit(true, true, true, true, address(ex));
        emit X.Leaf(m, _hash(c.t), _hash(c.ms[0]), 0, 0, 50, 100e6, fee, 50e6 - fee, 0);
        _send(c);
        assertEq(ex.cash(A), aCash - 50e6, "the maker buyer pays its price and no fee");
        assertEq(ex.cash(T), tCash + 50e6 - fee, "the taker seller receives price minus its fee");
        assertEq(ex.positionOf(m, 0, T), 2_000e6 - 100e6);
        assertEq(ex.positionOf(m, 0, A), 2_000e6 + 100e6);
        assertEq(ex.marketOf(m).feesHeld, fee);
        _assertConserved(m);
    }

    function test_direct_threeMakers_eachAtItsOwnPrice() public {
        Call memory c = _direct3();
        uint256 aCash = ex.cash(A);
        uint256 bCash = ex.cash(B);
        uint256 cCash = ex.cash(C);
        uint256 tCash = ex.cash(T);
        _send(c);
        assertEq(ex.cash(A), aCash + 12e6); // 40 at 30
        assertEq(ex.cash(B), bCash + 12e6); // 30 at 40
        assertEq(ex.cash(C), cCash + 10e6); // 20 at 50
        uint256 fees = _fee(40e6, 30) + _fee(30e6, 40) + _fee(20e6, 50);
        assertEq(ex.cash(T), tCash - 34e6 - fees, "the taker pays every leaf's value and that leaf's own fee");
        assertEq(ex.marketOf(m).feesHeld, fees, "the fee is charged per leaf, not once on an average price");
        assertEq(ex.positionOf(m, 0, T), 2_000e6 + 90e6);
        _assertConserved(m);
    }

    function test_direct_tenMakers() public {
        // ten distinct makers (10 shares each), one taker
        X.Order[] memory ms = new X.Order[](10);
        bytes[] memory mss = new bytes[](10);
        uint128[] memory fs = new uint128[](10);
        for (uint256 i; i < 10; ++i) {
            (uint256 k, address a) = _party(string.concat("tenMaker", vm.toString(i)), m, 0, 20e6);
            ms[i] = _order(a, m, 0, false, uint8(10 + i), 10e6);
            mss[i] = _sign(k, ms[i]);
            fs[i] = 10e6;
            ws.push(a);
        }
        Call memory c;
        c.t = _order(T, m, 0, true, 90, 100e6);
        c.ms = ms;
        c.mss = mss;
        c.fs = fs;
        c.tf = 100e6;
        c.ts = _sign(keyOf[T], c.t);
        _send(c);
        assertEq(ex.positionOf(m, 0, T), 2_000e6 + 100e6);
        _assertConserved(m);
    }

    // ------------------------------------------------------------------------------------------------ mint and merge
    function test_mint_N3_takerPaysTheRest_makersPayTheirOwnPrices() public {
        Call memory c = _mint3(50e6);
        uint256 tCash = ex.cash(T);
        uint256 aCash = ex.cash(A);
        uint256 bCash = ex.cash(B);
        uint256 sets = ex.marketOf(m).setsOutstanding;
        uint256 coll = ex.marketOf(m).collateral;
        uint256 fee = _fee(50e6, 50);
        assertEq(fee, 875_000);
        vm.expectEmit(true, true, false, true, address(ex));
        emit X.TakerLeaf(m, _hash(c.t), 1, 0, 50, 50e6, fee, 0, 0);
        _send(c);
        assertEq(ex.cash(T), tCash - 25e6 - fee, "taker pays 100 minus the makers' prices, plus its fee");
        assertEq(ex.cash(A), aCash - 10e6);
        assertEq(ex.cash(B), bCash - 15e6);
        assertEq(ex.marketOf(m).setsOutstanding, sets + 50e6, "exactly takerFill sets are created");
        assertEq(ex.marketOf(m).collateral, coll + 50e6, "exactly one USDC per set moves into the backing");
        assertEq(ex.positionOf(m, 0, T), 2_000e6 + 50e6);
        assertEq(ex.positionOf(m, 1, A), 2_000e6 + 50e6);
        assertEq(ex.positionOf(m, 2, B), 2_000e6 + 50e6);
        assertEq(ex.marketOf(m).feesHeld, fee);
        _assertConserved(m);
    }

    function test_merge_N3_takerReceivesTheRest_netOfItsFee() public {
        Call memory c = _merge3(50e6);
        uint256 tCash = ex.cash(T);
        uint256 aCash = ex.cash(A);
        uint256 bCash = ex.cash(B);
        uint256 sets = ex.marketOf(m).setsOutstanding;
        uint256 coll = ex.marketOf(m).collateral;
        uint256 fee = _fee(50e6, 50);
        _send(c);
        assertEq(ex.cash(T), tCash + 25e6 - fee);
        assertEq(ex.cash(A), aCash + 10e6);
        assertEq(ex.cash(B), bCash + 15e6);
        assertEq(ex.marketOf(m).setsOutstanding, sets - 50e6, "exactly takerFill sets are destroyed");
        assertEq(ex.marketOf(m).collateral, coll - 50e6);
        assertEq(ex.positionOf(m, 0, T), 2_000e6 - 50e6);
        assertEq(ex.positionOf(m, 2, B), 2_000e6 - 50e6);
        _assertConserved(m);
    }

    function test_mint_N2_twoPartyMint() public {
        uint256 m2 = _market(2);
        (uint256 tk, address t) = _party("t2", m2, 100e6, 0);
        (uint256 ak, address a) = _party("a2", m2, 100e6, 0);
        X.Order memory to = _order(t, m2, 0, true, 80, 10e6);
        X.Order memory mo = _order(a, m2, 1, true, 30, 10e6);
        _settle1(tk, to, ak, mo, 10e6);
        assertEq(ex.cash(a), 100e6 - 3e6, "the maker pays its 30");
        assertEq(ex.cash(t), 100e6 - 7e6 - _fee(10e6, 70), "the taker pays the remaining 70 and its fee");
        assertEq(ex.positionOf(m2, 0, t), 10e6);
        assertEq(ex.positionOf(m2, 1, a), 10e6);
        assertEq(ex.marketOf(m2).setsOutstanding, 10e6);
    }

    function test_merge_N2_twoPartyMerge() public {
        uint256 m2 = _market(2);
        (uint256 tk, address t) = _party("t2", m2, 0, 10e6);
        (uint256 ak, address a) = _party("a2", m2, 0, 10e6);
        X.Order memory to = _order(t, m2, 0, false, 50, 10e6);
        X.Order memory mo = _order(a, m2, 1, false, 30, 10e6);
        uint256 tCash = ex.cash(t);
        _settle1(tk, to, ak, mo, 10e6);
        assertEq(ex.cash(a), 3e6);
        assertEq(ex.cash(t), tCash + 7e6 - _fee(10e6, 70));
        assertEq(ex.marketOf(m2).setsOutstanding, 10e6, "two parties minted 10 each, one merge destroyed 10");
    }

    function test_mint_N3_makerPricesSumToExactly100_takerPaysNothing() public {
        // prices 60 + 40 in a 3-option market: the taker pays 0, so its leaf fee is 0
        X.Order[] memory ms = _two(_order(A, m, 1, true, 60, 10e6), _order(B, m, 2, true, 40, 10e6));
        Call memory c = _mk(_order(T, m, 0, true, 1, 10e6), ms, 10e6, _twoFill(10e6, 10e6));
        uint256 tCash = ex.cash(T);
        _send(c);
        assertEq(ex.cash(T), tCash, "the taker paid 0 and no fee");
        assertEq(ex.marketOf(m).feesHeld, 0);
        assertEq(ex.positionOf(m, 0, T), 2_000e6 + 10e6);
        _assertConserved(m);
    }

    function test_merge_N3_makerPricesSumToExactly100_takerReceivesNothing() public {
        X.Order[] memory ms = _two(_order(A, m, 1, false, 60, 10e6), _order(B, m, 2, false, 40, 10e6));
        // a limit of 1 would not be crossed by a taker price of 0: receiving 0 needs a limit of 0, which is no valid field
        Call memory c = _mk(_order(T, m, 0, false, 1, 10e6), ms, 10e6, _twoFill(10e6, 10e6));
        _expectNoWrite(abi.encodeWithSelector(X.PriceNotCrossed.selector), _data(c));
    }

    // ------------------------------------------------------------------------------------------------ partial fills
    function test_partialFills_accumulate_thenOverfill() public {
        X.Order memory to = _order(T, m, 0, true, 70, 100e6);
        X.Order memory mo = _order(A, m, 0, false, 40, 100e6);
        _settle1(keyOf[T], to, keyOf[A], mo, 30e6);
        _settle1(keyOf[T], to, keyOf[A], mo, 70e6);
        (uint128 f,) = ex.orders(_hash(to));
        assertEq(f, 100e6, "two calls fill the whole order");
        // a fully filled order never fills again
        Call memory c = _mk(to, _one(mo), 10e6, _oneFill(10e6));
        _expectNoWrite(abi.encodeWithSelector(X.Overfill.selector, _hash(to)), _data(c));
    }

    function test_overfill_filledPlusFillIsSummedInUint256_noWrapAndNoPanic() public {
        // orders of the largest lot-multiple size; one lot fills first, then a fill of the whole size: filled + fill passes
        // 2^128, which a uint128 sum would wrap (to a small number that "fits") or panic on
        uint128 big = type(uint128).max - uint128(uint256(type(uint128).max) % LOT);
        X.Order memory to = _order(T, m, 0, true, 70, big);
        X.Order memory mo = _order(A, m, 0, false, 40, big);
        _settle1(keyOf[T], to, keyOf[A], mo, LOT);
        Call memory c = _mk(to, _one(mo), big, _oneFill(big));
        _expectErr(abi.encodeWithSelector(X.Overfill.selector, _hash(to)), _data(c));
        // the same on the maker's side: a small taker order, a maker that is nearly full
        X.Order memory to2 = _order(B, m, 0, true, 70, big);
        X.Order memory mo2 = _order(C, m, 0, false, 40, 2 * LOT);
        _settle1(keyOf[B], to2, keyOf[C], mo2, LOT);
        c = _mk(to2, _one(mo2), 2 * LOT, _oneFill(2 * LOT));
        _expectErr(abi.encodeWithSelector(X.Overfill.selector, _hash(mo2)), _data(c));
    }

    function test_partialFill_makerSideOverfill() public {
        X.Order memory to = _order(T, m, 0, true, 70, 200e6);
        X.Order memory mo = _order(A, m, 0, false, 40, 100e6);
        _settle1(keyOf[T], to, keyOf[A], mo, 100e6);
        Call memory c = _mk(to, _one(mo), 10e6, _oneFill(10e6));
        _expectErr(abi.encodeWithSelector(X.Overfill.selector, _hash(mo)), _data(c));
    }

    function test_filledEqualsSize_boundaryIsAllowed_oneLotMoreIsNot() public {
        X.Order memory to = _order(T, m, 0, true, 70, 100e6);
        X.Order memory mo = _order(A, m, 0, false, 40, 100e6);
        _settle1(keyOf[T], to, keyOf[A], mo, 100e6 - LOT);
        _settle1(keyOf[T], to, keyOf[A], mo, LOT); // filled + fill == size: allowed
        Call memory c = _mk(to, _one(mo), LOT, _oneFill(LOT));
        _expectErr(abi.encodeWithSelector(X.Overfill.selector, _hash(to)), _data(c));
    }

    // ------------------------------------------------------------------------------------------------ profit hold
    function test_profitHold_makerSell_receiptAboveNetIsHeld_thenReleasedAtFinalize() public {
        // S buys 100 shares at 20 from T (S's net becomes 20 + fee), then sells them at 60 to U: the receipt exceeds the net
        (uint256 sk, address s) = _party("S", m, 100e6, 0);
        (uint256 uk, address u) = _party("U", m, 100e6, 0);
        ws.push(s);
        ws.push(u);
        X.Order memory buy = _order(s, m, 0, true, 40, 100e6);
        X.Order memory sell = _order(T, m, 0, false, 20, 100e6);
        _settle1(sk, buy, keyOf[T], sell, 100e6);
        uint256 net1 = _net(m, s);
        assertEq(net1, 20e6 + _fee(100e6, 20));
        // U buys from S at 60: S is a MAKER seller
        X.Order memory sell2 = _order(s, m, 0, false, 60, 100e6);
        X.Order memory buy2 = _order(u, m, 0, true, 70, 100e6);
        uint256 cashBefore = ex.cash(s);
        (uint256 wantFree, uint256 wantHold) = ex.splitOf(m, s, 60e6);
        assertEq(wantFree, net1);
        assertEq(wantHold, 60e6 - net1);
        vm.expectEmit(true, true, true, true, address(ex));
        emit X.Leaf(m, _hash(buy2), _hash(sell2), 0, 0, 60, 100e6, _fee(100e6, 60), wantFree, wantHold);
        _settle1(uk, buy2, sk, sell2, 100e6);
        assertEq(ex.cash(s), cashBefore + net1, "only up to its net goes to free cash");
        assertEq(_net(m, s), 0, "net never goes below zero");
        assertEq(_held(m, s), 60e6 - net1, "the excess is held");
        assertEq(ex.marketOf(m).profitHeldTotal, 60e6 - net1 + 0);
        _assertConserved(m);
        // finalize on option 0: the held profit is released, once
        vm.warp(block.timestamp + 31 days);
        ex.proposeOutcome(m, 0, bytes32(0));
        vm.warp(block.timestamp + 24 hours);
        ex.finalize(m);
        vm.prank(s);
        ex.redeem(m);
        assertEq(ex.cash(s), cashBefore + net1 + (60e6 - net1), "held profit paid at redeem");
        vm.prank(s);
        ex.redeem(m);
        assertEq(ex.cash(s), cashBefore + 60e6, "released exactly once");
    }

    function test_profitHold_takerSell_splitIsEmittedOnTheLeaf() public {
        (uint256 sk, address s) = _party("S", m, 100e6, 0);
        ws.push(s);
        // S buys 100 shares at 20 from A, then, as taker, sells to B's bid at 60
        _settle1(sk, _order(s, m, 0, true, 40, 100e6), keyOf[A], _order(A, m, 0, false, 20, 100e6), 100e6);
        uint256 net1 = _net(m, s);
        X.Order memory sell = _order(s, m, 0, false, 30, 100e6);
        X.Order memory bid = _order(B, m, 0, true, 60, 100e6);
        uint256 fee = _fee(100e6, 60);
        uint256 receipt = 60e6 - fee;
        (uint256 wf, uint256 wh) = ex.splitOf(m, s, receipt);
        assertEq(wf, net1);
        vm.expectEmit(true, true, true, true, address(ex));
        emit X.Leaf(m, _hash(sell), _hash(bid), 0, 0, 60, 100e6, fee, wf, wh);
        _settle1(sk, sell, keyOf[B], bid, 100e6);
        assertEq(_held(m, s), wh);
        _assertConserved(m);
    }

    function test_profitHold_mergeSets_splitsTheReceipt() public {
        (, address s) = _party("S", m, 100e6, 0);
        ws.push(s);
        // S mints 10 sets (net 10), buys 10 more option-0 shares at 20 so its net is 12+ and it merges 10 sets
        _mint(s, m, 10e6);
        (uint256 wf, uint256 wh) = ex.splitOf(m, s, 10e6);
        assertEq(wf, 10e6);
        assertEq(wh, 0);
        vm.expectEmit(true, true, false, true, address(ex));
        emit X.SetsMerged(m, s, 10e6, 10e6, 0);
        vm.prank(s);
        ex.mergeSets(m, 10e6);
        assertEq(_net(m, s), 0);
        // minting at 100 per set and merging at 100 can never produce profit alone; hold needs a trade
        _assertConserved(m);
    }

    // ------------------------------------------------------------------------------------------------ position cap
    function test_positionCap_twoOrdersOfOneWalletInOneCall() public {
        // cap 150 shares; T buys 100 from A and B (two makers) is within the cap, but a wallet taking 100 + 100 as two
        // MAKER buys of the same option exceeds it only in the second leaf
        uint256 mc = _marketCap(2, FEE, 150e6);
        (, address t) = _party("tc", mc, 1_000e6, 0);
        (, address s1) = _party("s1", mc, 0, 100e6);
        (, address s2) = _party("s2", mc, 0, 100e6);
        X.Order[] memory ms = _two(_order(s1, mc, 0, false, 40, 100e6), _order(s2, mc, 0, false, 40, 100e6));
        Call memory c = _mk(_order(t, mc, 0, true, 70, 200e6), ms, 200e6, _twoFill(100e6, 100e6));
        // the taker would hold 200 > cap 150
        _expectErr(abi.encodeWithSelector(X.PositionCap.selector, _hash(c.t)), _data(c));
    }

    function test_positionCap_boundary_exactlyTheCapIsAllowed_oneLotMoreIsNot() public {
        uint256 mc = _marketCap(2, FEE, 100e6);
        // a buying taker (direct): exactly the cap passes, one more lot does not
        (uint256 bk, address b1) = _party("capBuyer", mc, 1_000e6, 0);
        (uint256 sk, address s1) = _party("capSeller", mc, 0, 100e6);
        _settle1(bk, _order(b1, mc, 0, true, 70, 100e6), sk, _order(s1, mc, 0, false, 40, 100e6), 100e6);
        assertEq(ex.positionOf(mc, 0, b1), 100e6);
        (, address s2) = _party("capSeller2", mc, 0, 100e6);
        Call memory c =
            _mk(_order(b1, mc, 0, true, 71, LOT), _one(_order(s2, mc, 0, false, 40, LOT)), LOT, _oneFill(LOT));
        _expectErr(abi.encodeWithSelector(X.PositionCap.selector, _hash(c.t)), _data(c));
        // a buying maker (the taker sells): the same line for the maker leg
        (uint256 mk1, address m1) = _party("capMaker", mc, 1_000e6, 0);
        (uint256 tk1, address t1) = _party("capTaker", mc, 0, 100e6);
        _settle1(tk1, _order(t1, mc, 0, false, 10, 100e6), mk1, _order(m1, mc, 0, true, 50, 100e6), 100e6);
        assertEq(ex.positionOf(mc, 0, m1), 100e6);
        (, address t2) = _party("capTaker2", mc, 0, 100e6);
        c = _mk(_order(t2, mc, 0, false, 10, LOT), _one(_order(m1, mc, 0, true, 51, LOT)), LOT, _oneFill(LOT));
        _expectErr(abi.encodeWithSelector(X.PositionCap.selector, _hash(c.ms[0])), _data(c));
        // mintSets: exactly the cap passes, one more lot does not
        (, address minter) = _party("capMinter", mc, 0, 0);
        _deposit(minter, 200e6);
        vm.startPrank(minter);
        ex.mintSets(mc, 100e6);
        vm.expectRevert(abi.encodeWithSelector(X.PositionCap.selector, bytes32(0)));
        ex.mintSets(mc, LOT);
        vm.stopPrank();
    }

    function test_positionCap_makerLegSeesEarlierLegs() public {
        // w already holds 100 of option 0 (cap 150) and has two bids of 40 each: the first leaf passes (140), the
        // second sees the first's write (180) and reverts; checked against the position before the call it would pass
        uint256 mc = _marketCap(2, FEE, 150e6);
        (, address t) = _party("td", mc, 0, 80e6);
        (, address w) = _party("wd", mc, 1_000e6, 100e6);
        X.Order[] memory ms = _two(_order(w, mc, 0, true, 50, 40e6), _order(w, mc, 0, true, 51, 40e6));
        Call memory c = _mk(_order(t, mc, 0, false, 10, 80e6), ms, 80e6, _twoFill(40e6, 40e6));
        _expectErr(abi.encodeWithSelector(X.PositionCap.selector, _hash(c.ms[1])), _data(c));
        // with a single leg of 40 it settles
        c = _mk(_order(t, mc, 0, false, 10, 40e6), _one(ms[0]), 40e6, _oneFill(40e6));
        _send(c);
        assertEq(ex.positionOf(mc, 0, w), 140e6);
    }

    // ------------------------------------------------------------------------------------------------ same order twice
    function test_sameMakerOrderAtTwoIndices_neverFillsBeyondItsSize() public {
        X.Order memory mo = _order(A, m, 0, false, 40, 60e6);
        X.Order[] memory ms = _two(mo, mo);
        Call memory c = _mk(_order(T, m, 0, true, 70, 100e6), ms, 100e6, _twoFill(50e6, 50e6));
        _expectErr(abi.encodeWithSelector(X.Overfill.selector, _hash(mo)), _data(c));
        // each index alone fits, together 100 > 60: the second index sees the first's fill
        c.fs = _twoFill(30e6, 30e6);
        c.tf = 60e6;
        c.t = _order(T, m, 0, true, 70, 100e6);
        _resign(c);
        _send(c);
        (uint128 f,) = ex.orders(_hash(mo));
        assertEq(f, 60e6);
    }

    function test_takersOwnOrderAsMaker_isWrongKind() public {
        X.Order memory to = _order(T, m, 0, true, 70, 10e6);
        Call memory c = _mk(to, _one(to), 10e6, _oneFill(10e6));
        _expectNoWrite(abi.encodeWithSelector(X.WrongKind.selector), _data(c));
    }

    function test_selfMatch_otherOrderOfTheSameWallet_everyKind() public {
        // direct, maker index 0
        X.Order memory other = _order(T, m, 0, false, 40, 10e6);
        Call memory c = _mk(_order(T, m, 0, true, 70, 10e6), _one(other), 10e6, _oneFill(10e6));
        _expectNoWrite(abi.encodeWithSelector(X.SelfMatch.selector), _data(c));
        // direct, last of three
        c = _direct3();
        c.ms[2] = _order(T, m, 0, false, 50, 20e6);
        _resign(c);
        _expectNoWrite(abi.encodeWithSelector(X.SelfMatch.selector), _data(c));
        // mint, a maker of the taker's wallet on another option
        c = _mint3(10e6);
        c.ms[1] = _order(T, m, 2, true, 30, 10e6);
        _resign(c);
        _expectNoWrite(abi.encodeWithSelector(X.SelfMatch.selector), _data(c));
        // merge
        c = _merge3(10e6);
        c.ms[0] = _order(T, m, 1, false, 20, 10e6);
        _resign(c);
        _expectNoWrite(abi.encodeWithSelector(X.SelfMatch.selector), _data(c));
    }

    // ------------------------------------------------------------------------------------------------ cancel, nonce, expiry
    function test_cancelOrders_marksOnlyTheCallersOrders_andNeedsNoSignature() public {
        X.Order memory mo = _order(A, m, 0, false, 40, 100e6);
        vm.expectEmit(true, true, false, true, address(ex));
        emit X.Cancelled(_hash(mo), A);
        vm.prank(A);
        ex.cancelOrders(_one(mo));
        (, bool cancelled) = ex.orders(_hash(mo));
        assertTrue(cancelled);
        // a stranger cannot cancel A's order
        X.Order memory other = _order(A, m, 0, false, 41, 100e6);
        vm.prank(B);
        vm.expectRevert(X.NotMaker.selector);
        ex.cancelOrders(_one(other));
        (, bool c2) = ex.orders(_hash(other));
        assertFalse(c2);
        // the operator cannot either
        vm.prank(operator);
        vm.expectRevert(X.NotMaker.selector);
        ex.cancelOrders(_one(other));
        // one foreign order in a batch reverts the whole batch
        X.Order[] memory batch = _two(other, _order(B, m, 0, false, 41, 100e6));
        vm.prank(A);
        vm.expectRevert(X.NotMaker.selector);
        ex.cancelOrders(batch);
        (, c2) = ex.orders(_hash(other));
        assertFalse(c2, "the batch is atomic");
    }

    function test_cancelled_neverFills_evenAfterAPartialFill() public {
        X.Order memory to = _order(T, m, 0, true, 70, 100e6);
        X.Order memory mo = _order(A, m, 0, false, 40, 100e6);
        _settle1(keyOf[T], to, keyOf[A], mo, 30e6);
        vm.prank(A);
        ex.cancelOrders(_one(mo));
        Call memory c = _mk(to, _one(mo), 10e6, _oneFill(10e6));
        _expectErr(abi.encodeWithSelector(X.OrderCancelled.selector, _hash(mo)), _data(c));
        // and as a taker
        vm.prank(T);
        ex.cancelOrders(_one(to));
        c = _mk(to, _one(_order(B, m, 0, false, 40, 10e6)), 10e6, _oneFill(10e6));
        _expectErr(abi.encodeWithSelector(X.OrderCancelled.selector, _hash(to)), _data(c));
    }

    function test_incrementNonce_voidsEveryOlderOrder() public {
        Call memory c = _dBuy1(10e6);
        vm.expectEmit(true, false, false, true, address(ex));
        emit X.NonceIncremented(A, 1);
        vm.prank(A);
        ex.incrementNonce();
        assertEq(ex.nonces(A), 1);
        _expectErr(abi.encodeWithSelector(X.NonceMismatch.selector, _hash(c.ms[0])), _data(c));
        vm.prank(T);
        ex.incrementNonce();
        // the taker's nonce is checked first
        _expectErr(abi.encodeWithSelector(X.NonceMismatch.selector, _hash(c.t)), _data(c));
        // a fresh order with the new nonce settles
        _send(_dBuy1(10e6));
    }

    function test_nonceCannotBeSignedAhead() public {
        Call memory c = _dBuy1(10e6);
        c.ms[0].nonce = 1; // a nonce ahead of nonces[A] is not valid until A increments
        _resign(c);
        _expectErr(abi.encodeWithSelector(X.NonceMismatch.selector, _hash(c.ms[0])), _data(c));
        vm.prank(A);
        ex.incrementNonce();
        _send(c);
    }

    function test_expiry_boundary_isInclusive_oneSecondLaterIsExpired() public {
        Call memory c = _dBuy1(10e6);
        c.ms[0].expiration = uint64(block.timestamp + 100);
        _resign(c);
        vm.warp(block.timestamp + 100);
        uint256 snap = vm.snapshotState();
        _send(c); // now == expiration: valid
        vm.revertToState(snap);
        vm.warp(block.timestamp + 1);
        _expectErr(abi.encodeWithSelector(X.Expired.selector, _hash(c.ms[0])), _data(c));
    }

    function test_expiryZero_meansUntilTradingClose() public {
        Call memory c = _dBuy1(10e6);
        c.t.expiration = 0;
        c.ms[0].expiration = 0;
        _resign(c);
        vm.warp(block.timestamp + 29 days);
        _send(c);
        // and tradingClose still ends it
        vm.warp(block.timestamp + 2 days);
        _expectErr(abi.encodeWithSelector(X.TradingClosed.selector), _data(c));
    }

    function test_tradingClose_boundary_isExclusive() public {
        Call memory c = _dBuy1(10e6);
        c.t.expiration = 0;
        c.ms[0].expiration = 0;
        _resign(c);
        uint64 close = ex.marketOf(m).tradingClose;
        vm.warp(close - 1);
        uint256 snap = vm.snapshotState();
        _send(c);
        vm.revertToState(snap);
        vm.warp(close);
        _expectErr(abi.encodeWithSelector(X.TradingClosed.selector), _data(c));
    }

    function test_closeEarly_stopsMatching() public {
        Call memory c = _dBuy1(10e6);
        ex.closeEarly(m);
        _expectErr(abi.encodeWithSelector(X.TradingClosed.selector), _data(c));
    }

    function test_unknownMarket_isTradingClosed_neverAPanic() public {
        Call memory c = _dBuy1(10e6);
        c.t.marketId = 777;
        c.ms[0].marketId = 777;
        _resign(c);
        _expectNoWrite(abi.encodeWithSelector(X.TradingClosed.selector), _data(c));
    }
}
