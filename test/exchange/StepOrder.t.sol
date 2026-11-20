// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Scene} from "./Scene.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// @notice Every ordering rule of plan section 4.4 ("Checks, in this order"): each test makes two defects at once and
/// requires the EARLIER step's error, and, for steps 1 to 5, that the call wrote nothing. A reorder of two adjacent steps
/// fails the test of that pair.
contract StepOrderTest is Scene {
    function _e(bytes4 sel) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(sel);
    }

    function _e(bytes4 sel, bytes32 h) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(sel, h);
    }

    bytes internal junk65 = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));

    // ------------------------------------------------------------------------------------------------ steps 1 to 3
    function test_step1_notOperator_beforePaused() public {
        ex.setPaused(true);
        Call memory c = _dBuy1(10e6);
        vm.prank(B);
        (bool ok, bytes memory ret) = address(ex).call(_data(c));
        assertFalse(ok);
        assertEq(ret, _e(X.NotOperator.selector));
    }

    function test_step1_notOperator_beforeShape() public {
        Call memory c = _dBuy1(10e6);
        c.ms = new X.Order[](0);
        vm.prank(B);
        (bool ok, bytes memory ret) = address(ex).call(_data(c));
        assertFalse(ok);
        assertEq(ret, _e(X.NotOperator.selector));
    }

    function test_step1_paused_beforeShape() public {
        ex.setPaused(true);
        Call memory c = _dBuy1(10e6);
        c.ms = new X.Order[](0);
        _expectNoWrite(_e(X.Paused.selector), _data(c));
    }

    function test_step1_paused_beforeTradingClosed() public {
        ex.setPaused(true);
        vm.warp(block.timestamp + 40 days);
        _expectNoWrite(_e(X.Paused.selector), _data(_dBuy1(10e6)));
    }

    function test_step2_badMakerCount_beforeLengthMismatch() public {
        Call memory c = _dBuy1(10e6);
        c.ms = new X.Order[](0); // no maker, and mss and fs have length 1
        _expectNoWrite(_e(X.BadMakerCount.selector), _data(c));
    }

    function test_step2_tooManyMakers_isBadMakerCount_boundaryIsTen() public {
        X.Order[] memory ms = new X.Order[](11);
        bytes[] memory mss = new bytes[](11);
        uint128[] memory fs = new uint128[](11);
        for (uint256 i; i < 11; ++i) {
            ms[i] = _order(A, m, 0, false, 40, LOT);
            mss[i] = junk65;
            fs[i] = uint128(LOT);
        }
        Call memory c;
        c.t = _order(T, m, 0, true, 70, 11 * LOT);
        c.ts = junk65;
        c.ms = ms;
        c.mss = mss;
        c.fs = fs;
        c.tf = uint128(11 * LOT);
        _expectNoWrite(_e(X.BadMakerCount.selector), _data(c));
    }

    function test_step2_lengthMismatch_sigsAndFills_beforeAnySignatureIsRead() public {
        Call memory c = _direct3();
        c.mss = new bytes[](2); // one signature short
        c.ts = ""; // an empty taker signature would be BadSignatureLength if any signature were read first
        _expectNoWrite(_e(X.LengthMismatch.selector), _data(c));
        c = _direct3();
        c.fs = new uint128[](4); // one fill too many
        c.ts = "";
        _expectNoWrite(_e(X.LengthMismatch.selector), _data(c));
        c = _direct3();
        c.fs = new uint128[](2);
        _expectNoWrite(_e(X.LengthMismatch.selector), _data(c));
    }

    function test_step3_tradingClosed_beforeSignatures() public {
        Call memory c = _dBuy1(10e6);
        c.ts = "";
        ex.closeEarly(m);
        _expectNoWrite(_e(X.TradingClosed.selector), _data(c));
    }

    function test_step3_marketIsTheTakers_aMakerFromAnotherMarketDoesNotChangeWhichCloses() public {
        // the call's market is taker.marketId: market 2 open, market 1 closed early -> a taker for market 1 is closed
        uint256 m2 = _market(3);
        ex.closeEarly(m);
        Call memory c = _dBuy1(10e6);
        c.ms[0].marketId = m2;
        _resign(c);
        _expectNoWrite(_e(X.TradingClosed.selector), _data(c));
    }

    // ------------------------------------------------------------------------------------------------ step 4
    function test_step4_takerSignatureFirst() public {
        Call memory c = _dBuy1(10e6);
        c.ts = junk65;
        c.mss[0] = junk65;
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.t)), _data(c));
        c.ts = "";
        _expectNoWrite(_e(X.BadSignatureLength.selector, _hash(c.t)), _data(c));
    }

    function test_step4_makersInIndexOrder() public {
        Call memory c = _direct3();
        c.mss[1] = new bytes(196);
        c.mss[2] = junk65;
        _expectNoWrite(_e(X.BadSignatureLength.selector, _hash(c.ms[1])), _data(c));
        c = _direct3();
        c.mss[1] = junk65;
        c.mss[2] = "";
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[1])), _data(c));
        c = _direct3();
        c.mss[0] = junk65;
        c.mss[1] = "";
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
    }

    function test_step4_signaturesBeforeEveryStep5Check() public {
        // MarketMismatch, BadOrderField, WrongKind, FillMismatch, SelfMatch, PriceNotCrossed and PartyRefused all present
        // in one call whose taker signature is wrong: the signature error wins
        Call memory c = _dBuy1(10e6);
        c.ms[0].marketId = 99;
        c.ms[0].price = 0;
        c.fs[0] = 1;
        c.ms[0].maker = T;
        _resign(c);
        c.ts = junk65;
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.t)), _data(c));
        // and with only a maker signature wrong
        _resign(c);
        c.mss[0] = junk65;
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[0])), _data(c));
    }

    function test_step4_everySignatureIsCheckedBeforeAnyWrite() public {
        // the last maker's signature is wrong: nothing earlier in the call was written
        Call memory c = _direct3();
        c.mss[2] = junk65;
        _expectNoWrite(_e(X.BadSignature.selector, _hash(c.ms[2])), _data(c));
    }

    // ------------------------------------------------------------------------------------------------ step 5
    function test_step5_marketMismatch_beforeBadOrderField() public {
        uint256 m2 = _market(3);
        Call memory c = _dBuy1(10e6);
        c.ms[0].marketId = m2;
        c.t.price = 0; // BadOrderField on the taker, which would come first in index order
        _resign(c);
        _expectNoWrite(_e(X.MarketMismatch.selector, _hash(c.ms[0])), _data(c));
    }

    function test_step5_marketMismatch_firstMismatchedMakerInIndexOrder() public {
        uint256 m2 = _market(3);
        Call memory c = _direct3();
        c.ms[1].marketId = m2;
        c.ms[2].marketId = m2;
        _resign(c);
        _expectNoWrite(_e(X.MarketMismatch.selector, _hash(c.ms[1])), _data(c));
    }

    function test_step5_marketMismatch_beforeEveryLaterCheck() public {
        uint256 m2 = _market(3);
        Call memory c = _mint3(10e6);
        c.ms[1].marketId = m2;
        c.fs[0] = 1; // FillMismatch
        c.ms[0].maker = T; // SelfMatch
        _resign(c);
        _expectNoWrite(_e(X.MarketMismatch.selector, _hash(c.ms[1])), _data(c));
    }

    function test_step5_badOrderField_everyFieldAndTheLotRule() public {
        Call memory c = _dBuy1(10e6);
        c.ms[0].price = 0;
        _resign(c);
        _expectNoWrite(_e(X.BadOrderField.selector, _hash(c.ms[0])), _data(c));
        c = _dBuy1(10e6);
        c.ms[0].price = 100;
        _resign(c);
        _expectNoWrite(_e(X.BadOrderField.selector, _hash(c.ms[0])), _data(c));
        c = _dBuy1(10e6);
        c.ms[0].size = 0;
        _resign(c);
        _expectNoWrite(_e(X.BadOrderField.selector, _hash(c.ms[0])), _data(c));
        c = _dBuy1(10e6);
        c.ms[0].size = uint128(10e6 + 1); // not a lot multiple
        _resign(c);
        _expectNoWrite(_e(X.BadOrderField.selector, _hash(c.ms[0])), _data(c));
        c = _dBuy1(10e6);
        c.ms[0].option = 3; // the market has options 0 to 2
        _resign(c);
        _expectNoWrite(_e(X.BadOrderField.selector, _hash(c.ms[0])), _data(c));
        c = _dBuy1(10e6);
        c.t.option = 3;
        _resign(c);
        _expectNoWrite(_e(X.BadOrderField.selector, _hash(c.t)), _data(c));
        // boundaries that are valid: price 1 and 99, option 2
        c = _dBuy1(10e6);
        c.ms[0].price = 1;
        c.t.price = 99;
        _resign(c);
        _send(c);
        c = _dBuy1(10e6);
        c.ms[0].price = 99;
        c.t.price = 99;
        c.t.salt = 12345; // a new order, not the first one again
        _resign(c);
        _send(c);
    }

    function test_step5_badOrderField_takerFirstThenMakersInIndexOrder() public {
        Call memory c = _direct3();
        c.t.price = 0;
        c.ms[0].price = 0;
        _resign(c);
        _expectNoWrite(_e(X.BadOrderField.selector, _hash(c.t)), _data(c));
        c = _direct3();
        c.ms[2].price = 0;
        c.ms[1].size = 0;
        _resign(c);
        _expectNoWrite(_e(X.BadOrderField.selector, _hash(c.ms[1])), _data(c));
    }

    function test_step5_badOrderField_beforeKindAndBeforeAnyFillIsRead() public {
        // wrong kind, zero fills, a self match and a refused party, but also a price of 0: BadOrderField is first
        Call memory c = _mint3(10e6);
        c.ms[0].option = 2; // two makers on option 2: WrongKind
        c.ms[1].price = 0;
        c.fs[0] = 0;
        c.fs[1] = 3;
        _resign(c);
        _expectNoWrite(_e(X.BadOrderField.selector, _hash(c.ms[1])), _data(c));
        // an option out of range cannot index the kind's option bitmap: BadOrderField, not a shift panic
        c = _mint3(10e6);
        c.ms[0].option = 200;
        _resign(c);
        _expectNoWrite(_e(X.BadOrderField.selector, _hash(c.ms[0])), _data(c));
    }

    function test_step5_wrongKind_beforeFillMismatch() public {
        Call memory c = _dBuy1(10e6);
        c.ms[0].isBuy = true; // same side as the taker, same option, two options? 3 options and 1 maker: not N - 1
        c.fs[0] = 3; // FillMismatch
        _resign(c);
        _expectNoWrite(_e(X.WrongKind.selector), _data(c));
    }

    function test_step5_wrongKind_everyShape() public {
        Call memory c = _mint3(10e6);
        c.ms[1].option = 1; // two makers on option 1
        _resign(c);
        _expectNoWrite(_e(X.WrongKind.selector), _data(c));
        c = _mint3(10e6);
        c.ms[1].option = 0; // a maker on the taker's own option
        _resign(c);
        _expectNoWrite(_e(X.WrongKind.selector), _data(c));
        c = _mint3(10e6);
        c.ms[1].isBuy = false; // a seller among buyers
        _resign(c);
        _expectNoWrite(_e(X.WrongKind.selector), _data(c));
        c = _mint3(10e6);
        c.ms = _one(c.ms[0]); // N - 2 makers
        c.mss = _oneSig(c.mss[0]);
        c.fs = _oneFill(10e6);
        _expectNoWrite(_e(X.WrongKind.selector), _data(c));
        c = _merge3(10e6);
        c.ms[0].isBuy = true;
        _resign(c);
        _expectNoWrite(_e(X.WrongKind.selector), _data(c));
        c = _direct3();
        c.ms[1].isBuy = true; // one maker on the taker's side among direct makers
        _resign(c);
        _expectNoWrite(_e(X.WrongKind.selector), _data(c));
        c = _direct3();
        c.ms[1].option = 1; // one maker on another option
        _resign(c);
        _expectNoWrite(_e(X.WrongKind.selector), _data(c));
    }

    function test_step5_fillMismatch_beforeSelfMatch() public {
        Call memory c = _dBuy1(10e6);
        c.ms[0].maker = T;
        c.fs[0] = 5e6; // sum != takerFill
        _resign(c);
        _expectNoWrite(_e(X.FillMismatch.selector), _data(c));
    }

    function test_step5_fillMismatch_perKindRules() public {
        // direct: the sum must equal takerFill
        Call memory c = _direct3();
        c.fs[0] = 30e6; // sum 80 against 90
        _expectNoWrite(_e(X.FillMismatch.selector), _data(c));
        // mint and merge: EVERY fill equals takerFill (50 + 50 against 100 fails at N = 3)
        c = _mint3(100e6);
        c.fs = _twoFill(50e6, 50e6);
        _expectNoWrite(_e(X.FillMismatch.selector), _data(c));
        c = _merge3(100e6);
        c.fs = _twoFill(50e6, 100e6);
        _expectNoWrite(_e(X.FillMismatch.selector), _data(c));
        // zero or not a lot multiple: a fill, and takerFill
        c = _dBuy1(10e6);
        c.fs[0] = 10e6 + 1;
        c.tf = uint128(10e6 + 1);
        _expectNoWrite(_e(X.FillMismatch.selector), _data(c));
        c = _dBuy1(10e6);
        c.fs[0] = 0;
        c.tf = 0;
        _expectNoWrite(_e(X.FillMismatch.selector), _data(c));
        c = _dBuy1(10e6);
        c.tf = 0; // takerFill 0 with a nonzero fill
        _expectNoWrite(_e(X.FillMismatch.selector), _data(c));
        c = _direct3();
        c.fs[1] = 0;
        c.fs[0] = 70e6;
        _expectNoWrite(_e(X.FillMismatch.selector), _data(c));
        // the sum is taken in uint256: two fills near 2^128 cannot wrap into a match
        c = _direct3();
        c.fs[0] = type(uint128).max - (type(uint128).max % uint128(LOT));
        c.fs[1] = type(uint128).max - (type(uint128).max % uint128(LOT));
        c.fs[2] = 10e6;
        c.tf = 10e6;
        _expectNoWrite(_e(X.FillMismatch.selector), _data(c));
    }

    function test_step5_selfMatch_beforeSetPriceSum() public {
        X.Order[] memory ms = _two(_order(T, m, 1, true, 60, 10e6), _order(B, m, 2, true, 50, 10e6)); // 110 > 100
        Call memory c = _mk(_order(T, m, 0, true, 99, 10e6), ms, 10e6, _twoFill(10e6, 10e6));
        _expectNoWrite(_e(X.SelfMatch.selector), _data(c));
    }

    function test_step5_setPriceSum_beforePriceNotCrossed_mintAndMerge() public {
        X.Order[] memory ms = _two(_order(A, m, 1, true, 60, 10e6), _order(B, m, 2, true, 50, 10e6));
        Call memory c = _mk(_order(T, m, 0, true, 1, 10e6), ms, 10e6, _twoFill(10e6, 10e6));
        _expectNoWrite(_e(X.SetPriceSum.selector), _data(c));
        ms = _two(_order(A, m, 1, false, 60, 10e6), _order(B, m, 2, false, 50, 10e6));
        c = _mk(_order(T, m, 0, false, 99, 10e6), ms, 10e6, _twoFill(10e6, 10e6));
        _expectNoWrite(_e(X.SetPriceSum.selector), _data(c));
    }

    function test_step5_setPriceSum_boundary_100IsAllowed_101IsNot() public {
        X.Order[] memory ms = _two(_order(A, m, 1, true, 61, 10e6), _order(B, m, 2, true, 40, 10e6)); // 101
        Call memory c = _mk(_order(T, m, 0, true, 99, 10e6), ms, 10e6, _twoFill(10e6, 10e6));
        _expectNoWrite(_e(X.SetPriceSum.selector), _data(c));
        ms = _two(_order(A, m, 1, true, 60, 10e6), _order(B, m, 2, true, 40, 10e6)); // 100
        c = _mk(_order(T, m, 0, true, 99, 10e6), ms, 10e6, _twoFill(10e6, 10e6));
        _send(c);
    }

    function test_step5_setPriceSum_tenMakersAt99_doesNotWrapOrPanic() public {
        // 11 options: ten makers at 99 sum to 990, a uint8 accumulator would wrap
        uint256 m11 = _market(11);
        X.Order[] memory ms = new X.Order[](10);
        bytes[] memory mss = new bytes[](10);
        uint128[] memory fs = new uint128[](10);
        for (uint256 i; i < 10; ++i) {
            (uint256 k, address a) = _party(string.concat("p11_", vm.toString(i)), m11, 100e6, 0);
            ms[i] = _order(a, m11, uint8(i + 1), true, 99, 10e6);
            mss[i] = _sign(k, ms[i]);
            fs[i] = 10e6;
        }
        Call memory c;
        c.t = _order(T, m11, 0, true, 99, 10e6);
        c.ts = _sign(keyOf[T], c.t);
        c.ms = ms;
        c.mss = mss;
        c.fs = fs;
        c.tf = 10e6;
        _expectNoWrite(_e(X.SetPriceSum.selector), _data(c));
    }

    function test_step5_priceNotCrossed_directBothSides_andSetKinds() public {
        Call memory c = _dBuy1(10e6);
        c.ms[0].price = 71; // the buyer's limit is 70
        _resign(c);
        _expectNoWrite(_e(X.PriceNotCrossed.selector), _data(c));
        c.ms[0].price = 70; // equal is crossed
        _resign(c);
        _send(c);
        c = _dSell1(10e6);
        c.ms[0].price = 29; // the seller's limit is 30
        _resign(c);
        _expectNoWrite(_e(X.PriceNotCrossed.selector), _data(c));
        c = _mint3(10e6);
        c.t.price = 49; // the taker pays 50
        _resign(c);
        _expectNoWrite(_e(X.PriceNotCrossed.selector), _data(c));
        c.t.price = 50;
        _resign(c);
        _send(c);
        c = _merge3(10e6);
        c.t.price = 51; // the taker receives 50
        _resign(c);
        _expectNoWrite(_e(X.PriceNotCrossed.selector), _data(c));
        c.t.price = 50;
        _resign(c);
        _send(c);
    }

    function test_step5_priceNotCrossed_oneBadLegAmongThree() public {
        Call memory c = _direct3();
        c.ms[2].price = 71;
        _resign(c);
        _expectNoWrite(_e(X.PriceNotCrossed.selector), _data(c));
    }

    function test_step5_priceNotCrossed_beforePartyRefused() public {
        (uint256 ok, address op) = _party("op2", m, 10_000e6, 100e6);
        ok;
        ex.setOperator(op, true);
        Call memory c = _dBuy1(10e6);
        c.ms[0] = _order(op, m, 0, false, 80, 10e6); // uncrossed, and the maker is an operator
        _resign(c);
        _expectNoWrite(_e(X.PriceNotCrossed.selector), _data(c));
        c.ms[0].price = 40;
        _resign(c);
        _expectNoWrite(_e(X.PartyRefused.selector, _hash(c.ms[0])), _data(c));
    }

    function test_step5_partyRefused_takerFirstThenMakers() public {
        (, address op1) = _party("op1", m, 10_000e6, 100e6);
        (, address op2) = _party("op2", m, 10_000e6, 100e6);
        ex.setOperator(op1, true);
        ex.setOperator(op2, true);
        Call memory c = _direct3();
        c.t = _order(op1, m, 0, true, 70, 90e6);
        c.ms[1] = _order(op2, m, 0, false, 40, 30e6);
        _resign(c);
        _expectNoWrite(_e(X.PartyRefused.selector, _hash(c.t)), _data(c));
        c.t = _order(T, m, 0, true, 70, 90e6);
        _resign(c);
        _expectNoWrite(_e(X.PartyRefused.selector, _hash(c.ms[1])), _data(c));
    }

    // ------------------------------------------------------------------------------------------------ step 5 before 6
    function test_step5_beforeStep6_everyPartyStateErrorComesAfterAMatchError() public {
        Call memory c = _dBuy1(10e6);
        vm.prank(A);
        ex.cancelOrders(_one(c.ms[0])); // step 6 error present (OrderCancelled)...
        c.ms[0].price = 71; // ...and PriceNotCrossed (step 5)
        // the cancelled hash changed with the price, so cancel the new hash too
        _resign(c);
        vm.prank(A);
        ex.cancelOrders(_one(c.ms[0]));
        _expectNoWrite(_e(X.PriceNotCrossed.selector), _data(c));
    }

    // ------------------------------------------------------------------------------------------------ step 6
    function test_step6_takerBeforeMakers() public {
        Call memory c = _dBuy1(10e6);
        vm.prank(A);
        ex.cancelOrders(_one(c.ms[0]));
        c.t.nonce = 5;
        _resign(c);
        vm.prank(A);
        ex.cancelOrders(_one(c.ms[0]));
        _expectErr(_e(X.NonceMismatch.selector, _hash(c.t)), _data(c));
    }

    function test_step6_makersInIndexOrder() public {
        Call memory c = _direct3();
        c.ms[1].expiration = uint64(block.timestamp - 1);
        c.ms[2].nonce = 9;
        _resign(c);
        _expectErr(_e(X.Expired.selector, _hash(c.ms[1])), _data(c));
    }

    function test_step6_withinAParty_cancelled_nonce_expiry_overfill_cash_cap() public {
        // cancelled before nonce
        Call memory c = _dBuy1(10e6);
        c.ms[0].nonce = 4;
        c.ms[0].expiration = uint64(block.timestamp - 1);
        _resign(c);
        vm.prank(A);
        ex.cancelOrders(_one(c.ms[0]));
        _expectErr(_e(X.OrderCancelled.selector, _hash(c.ms[0])), _data(c));
        // nonce before expiry
        c = _dBuy1(10e6);
        c.ms[0].salt = 777; // not the cancelled order
        c.ms[0].nonce = 4;
        c.ms[0].expiration = uint64(block.timestamp - 1);
        _resign(c);
        _expectErr(_e(X.NonceMismatch.selector, _hash(c.ms[0])), _data(c));
        // expiry before overfill: the order is expired and the fill exceeds its size
        c = _dBuy1(10e6);
        c.ms[0].size = uint128(LOT);
        c.ms[0].expiration = uint64(block.timestamp - 1);
        _resign(c);
        _expectErr(_e(X.Expired.selector, _hash(c.ms[0])), _data(c));
        // overfill before cash: the taker's fill exceeds its size and it has no cash
        (uint256 pk, address poor) = _party("poor", m, 0, 0);
        pk;
        c = _dBuy1(10e6);
        c.t = _order(poor, m, 0, true, 70, 10e6 - LOT);
        _resign(c);
        _expectErr(_e(X.Overfill.selector, _hash(c.t)), _data(c));
        // overfill before shares: a seller maker without shares and a fill beyond its size
        c = _dBuy1(10e6);
        (uint256 nk, address noShares) = _party("noShares", m, 0, 0);
        nk;
        c.ms[0] = _order(noShares, m, 0, false, 40, 10e6 - LOT);
        _resign(c);
        _expectErr(_e(X.Overfill.selector, _hash(c.ms[0])), _data(c));
    }

    function test_step6_cashBeforeCap_andSharesBeforeNothing() public {
        // cap 50 shares, the buyer has no cash and would exceed the cap: InsufficientCash comes first
        uint256 mc = _marketCap(2, FEE, 50e6);
        (, address buyer) = _party("buyer", mc, 0, 0);
        (, address seller) = _party("seller", mc, 0, 50e6);
        Call memory c = _mk(
            _order(buyer, mc, 0, true, 70, 100e6), _one(_order(seller, mc, 0, false, 40, 100e6)), 100e6, _oneFill(100e6)
        );
        _expectErr(_e(X.InsufficientCash.selector, _hash(c.t)), _data(c));
        // with cash, the cap is the error
        _deposit(buyer, 1_000e6);
        _expectErr(_e(X.PositionCap.selector, _hash(c.t)), _data(c));
    }

    function test_step6_insufficientCash_takerAndMaker_feeIncluded() public {
        // the taker holds exactly the value but not the fee
        (uint256 bk, address buyer) = _party("buyer", m, 40e6, 0);
        bk;
        Call memory c =
            _mk(_order(buyer, m, 0, true, 70, 100e6), _one(_order(A, m, 0, false, 40, 100e6)), 100e6, _oneFill(100e6));
        _expectErr(_e(X.InsufficientCash.selector, _hash(c.t)), _data(c));
        _deposit(buyer, _fee(100e6, 40));
        _send(c); // value + fee exactly: allowed
        assertEq(ex.cash(buyer), 0);
        // a maker buyer short of cash
        (uint256 mk2, address lowMaker) = _party("lowMaker", m, 1e6, 0);
        mk2;
        c = _mk(_order(T, m, 0, false, 30, 10e6), _one(_order(lowMaker, m, 0, true, 50, 10e6)), 10e6, _oneFill(10e6));
        _expectErr(_e(X.InsufficientCash.selector, _hash(c.ms[0])), _data(c));
    }

    function test_step6_insufficientShares_takerAndMaker() public {
        (, address noShares) = _party("noShares", m, 0, 0);
        Call memory c =
            _mk(_order(noShares, m, 0, false, 30, 10e6), _one(_order(A, m, 0, true, 50, 10e6)), 10e6, _oneFill(10e6));
        _expectErr(_e(X.InsufficientShares.selector, _hash(c.t)), _data(c));
        c = _mk(_order(T, m, 0, true, 70, 10e6), _one(_order(noShares, m, 0, false, 40, 10e6)), 10e6, _oneFill(10e6));
        _expectErr(_e(X.InsufficientShares.selector, _hash(c.ms[0])), _data(c));
        // set kinds: a merge maker without shares of its option, a mint buyer without cash
        c = _merge3(10e6);
        c.ms[1] = _order(noShares, m, 2, false, 30, 10e6);
        _resign(c);
        _expectErr(_e(X.InsufficientShares.selector, _hash(c.ms[1])), _data(c));
        (, address brokeBuyer) = _party("brokeBuyer", m, 0, 0);
        c = _mint3(10e6);
        c.ms[1] = _order(brokeBuyer, m, 2, true, 30, 10e6);
        _resign(c);
        _expectErr(_e(X.InsufficientCash.selector, _hash(c.ms[1])), _data(c));
    }

    function test_step6_aFailureAfterEarlierPartiesWroteRevertsEverything() public {
        Call memory c = _direct3();
        // C (the third maker) has no shares: taker, A and B were already settled in memory of the call
        (, address noShares) = _party("noShares", m, 0, 0);
        c.ms[2] = _order(noShares, m, 0, false, 50, 20e6);
        _resign(c);
        uint256 tCash = ex.cash(T);
        uint256 aCash = ex.cash(A);
        (uint128 f0,) = ex.orders(_hash(c.t));
        _expectErr(_e(X.InsufficientShares.selector, _hash(c.ms[2])), _data(c));
        assertEq(ex.cash(T), tCash);
        assertEq(ex.cash(A), aCash);
        (uint128 f1,) = ex.orders(_hash(c.t));
        assertEq(f1, f0);
        assertEq(ex.marketOf(m).feesHeld, 0);
    }

    function test_step6_takerChecksCoverEveryLeg_theMakersOnlyCredit() public {
        // the taker's cash must cover all three legs and fees at once, before any maker is credited
        (uint256 bk, address buyer) = _party("buyer", m, 0, 0);
        bk;
        _deposit(buyer, 34e6 + _fee(40e6, 30) + _fee(30e6, 40) + _fee(20e6, 50) - 1);
        Call memory c = _direct3();
        c.t = _order(buyer, m, 0, true, 70, 90e6);
        _resign(c);
        _expectErr(_e(X.InsufficientCash.selector, _hash(c.t)), _data(c));
        _deposit(buyer, 1);
        _send(c);
        assertEq(ex.cash(buyer), 0);
    }
}
