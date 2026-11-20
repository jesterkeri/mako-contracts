// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Scene} from "../exchange/Scene.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// Adversary, item 1 (money): direct matches with 1 to 10 makers where the SAME wallet fills several legs (the shipped
/// invariant handler only builds one-maker directs), at random prices, fills and sides. Each wallet's cash + held
/// profit, positions and the market's fees are compared with an independent per-leg computation, and X1, X2, X15 hold.
contract AdvMultiMaker is Scene {
    uint256 internal settledCount;

    function _r(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    function _idx(address a) internal view returns (uint256) {
        for (uint256 i; i < ws.length; ++i) {
            if (ws[i] == a) return i;
        }
        revert("not a party");
    }

    function testFuzz_adv_directManyMakers_duplicateWallets_exactMoney(uint256 seed) public {
        bool takerBuy = _r(seed, 0) & 1 == 1;
        uint256 n = 1 + _r(seed, 1) % 10;
        uint8 opt = uint8(_r(seed, 2) % 3);
        uint8 tlim = takerBuy ? 99 : 1;
        X.Order memory to;
        X.Order[] memory ms = new X.Order[](n);
        uint128[] memory fs = new uint128[](n);
        int256[4] memory dCash;
        int256[4] memory dPos;
        uint256 total;
        uint256 feeSum;
        for (uint256 i; i < n; ++i) {
            address w = ws[1 + _r(seed, 10 + i) % 3]; // A, B or C; repeats on purpose
            uint8 price = uint8(1 + _r(seed, 20 + i) % 99);
            uint256 f = (1 + _r(seed, 30 + i) % 40) * LOT * 25;
            ms[i] = _order(w, m, opt, !takerBuy, price, f);
            ms[i].salt = _r(seed, 40 + i);
            fs[i] = uint128(f);
            total += f;
            uint256 v = f * price / 100;
            uint256 fee = _fee(f, price);
            feeSum += fee;
            uint256 wi = _idx(w);
            if (takerBuy) {
                dCash[0] -= int256(v + fee);
                dCash[wi] += int256(v);
                dPos[0] += int256(f);
                dPos[wi] -= int256(f);
            } else {
                dCash[0] += int256(v - fee);
                dCash[wi] -= int256(v);
                dPos[0] -= int256(f);
                dPos[wi] += int256(f);
            }
        }
        to = _order(T, m, opt, takerBuy, tlim, total);
        to.salt = _r(seed, 99);
        Call memory c = _mk(to, ms, total, fs);
        uint256[4] memory cb;
        uint256[4] memory pb;
        for (uint256 i; i < 4; ++i) {
            (, uint256 h) = ex.recOf(m, ws[i]);
            cb[i] = ex.cash(ws[i]) + h;
            pb[i] = ex.positionOf(m, opt, ws[i]);
        }
        uint256 feesBefore = ex.marketOf(m).feesHeld;
        _send(c);
        for (uint256 i; i < 4; ++i) {
            (, uint256 h) = ex.recOf(m, ws[i]);
            assertEq(int256(ex.cash(ws[i]) + h) - int256(cb[i]), dCash[i], "cash plus held profit of a wallet");
            assertEq(int256(ex.positionOf(m, opt, ws[i])) - int256(pb[i]), dPos[i], "position of a wallet");
        }
        assertEq(ex.marketOf(m).feesHeld - feesBefore, feeSum, "fees are the sum of the per-leaf fees");
        _assertConserved(m);
    }

    /// Mint and merge (N = 3) where the two makers may be the same wallet, at random prices and sizes.
    function testFuzz_adv_setMatches_duplicateMakerWallet_exactMoney(uint256 seed) public {
        bool mint = _r(seed, 0) & 1 == 1;
        uint8 tOpt = uint8(_r(seed, 1) % 3);
        uint256 q = (1 + _r(seed, 2) % 200) * LOT * 25;
        X.Order[] memory ms = new X.Order[](2);
        uint128[] memory fs = new uint128[](2);
        int256[4] memory dCash;
        int256[3][4] memory dPos;
        uint256 sum;
        uint256 k;
        for (uint8 o; o < 3; ++o) {
            if (o == tOpt) continue;
            address w = ws[1 + _r(seed, 10 + o) % 3];
            uint8 price = uint8(1 + _r(seed, 20 + o) % 49);
            sum += price;
            ms[k] = _order(w, m, o, mint, price, q);
            ms[k].salt = _r(seed, 30 + o);
            fs[k] = uint128(q);
            uint256 v = q * price / 100;
            uint256 wi = _idx(w);
            dCash[wi] += mint ? -int256(v) : int256(v);
            dPos[wi][o] += mint ? int256(q) : -int256(q);
            ++k;
        }
        uint256 tp = 100 - sum;
        uint256 tfee = _fee(q, tp);
        X.Order memory to = _order(T, m, tOpt, mint, mint ? 99 : 1, q);
        to.salt = _r(seed, 99);
        if (mint) dCash[0] -= int256(q * tp / 100 + tfee);
        else dCash[0] += int256(q * tp / 100) - int256(tfee);
        dPos[0][tOpt] += mint ? int256(q) : -int256(q);
        Call memory c = _mk(to, ms, q, fs);
        uint256[4] memory cb;
        uint256[3][4] memory pb;
        for (uint256 i; i < 4; ++i) {
            (, uint256 h) = ex.recOf(m, ws[i]);
            cb[i] = ex.cash(ws[i]) + h;
            for (uint8 o; o < 3; ++o) {
                pb[i][o] = ex.positionOf(m, o, ws[i]);
            }
        }
        uint256 feesBefore = ex.marketOf(m).feesHeld;
        _send(c);
        for (uint256 i; i < 4; ++i) {
            (, uint256 h) = ex.recOf(m, ws[i]);
            assertEq(int256(ex.cash(ws[i]) + h) - int256(cb[i]), dCash[i], "cash plus held profit");
            for (uint8 o; o < 3; ++o) {
                assertEq(int256(ex.positionOf(m, o, ws[i])) - int256(pb[i][o]), dPos[i][o], "position");
            }
        }
        assertEq(ex.marketOf(m).feesHeld - feesBefore, tfee, "the taker leaf's fee only");
        _assertConserved(m);
    }

    // ------------------------------------------------------------------------------------------------ end to end
    /// @dev Random trades through every match kind (taker and maker roles, duplicate wallets, holds, fees), then the market
    /// ends. `finalOutcome == 255` unwinds it. Everyone redeems and withdraws.
    function _randomHistory(uint256 seed) internal {
        uint256 steps = 3 + _r(seed, 0) % 8;
        for (uint256 s; s < steps; ++s) {
            uint256 k = _r(seed, 100 + s) % 3;
            uint256 size = (1 + _r(seed, 110 + s) % 100) * LOT * 25;
            Call memory c;
            if (k == 0) {
                bool tb = _r(seed, 120 + s) & 1 == 1;
                uint256 nm = 1 + _r(seed, 130 + s) % 4;
                X.Order[] memory ms = new X.Order[](nm);
                uint128[] memory fs = new uint128[](nm);
                uint256 total;
                for (uint256 i; i < nm; ++i) {
                    uint256 f = (1 + _r(seed, 140 + s * 16 + i) % 40) * LOT * 25;
                    total += f;
                    ms[i] = _order(
                        ws[1 + _r(seed, 150 + s * 16 + i) % 3], m, 0, !tb, uint8(1 + _r(seed, 160 + s * 16 + i) % 99), f
                    );
                    ms[i].salt = _r(seed, 170 + s * 16 + i);
                    fs[i] = uint128(f);
                }
                X.Order memory to = _order(T, m, 0, tb, tb ? 99 : 1, total);
                to.salt = _r(seed, 180 + s);
                c = _mk(to, ms, total, fs);
            } else {
                bool mint = k == 1;
                X.Order[] memory ms = new X.Order[](2);
                uint128[] memory fs = new uint128[](2);
                uint256 sum;
                for (uint8 o; o < 2; ++o) {
                    uint8 price = uint8(1 + _r(seed, 190 + s * 4 + o) % 40);
                    sum += price;
                    ms[o] = _order(ws[1 + _r(seed, 200 + s * 4 + o) % 3], m, o + 1, mint, price, size);
                    ms[o].salt = _r(seed, 210 + s * 4 + o);
                    fs[o] = uint128(size);
                }
                X.Order memory to = _order(T, m, 0, mint, mint ? 99 : 1, size);
                to.salt = _r(seed, 220 + s);
                c = _mk(to, ms, size, fs);
            }
            vm.prank(operator);
            (bool ok,) = address(ex).call(_data(c));
            if (ok) ++settledCount; // a revert (a wallet short of cash or shares) is fine: the history just skips that step
        }
    }

    function testFuzz_adv_unwind_everyWalletEndsExactlyWhereItStarted(uint256 seed) public {
        uint256 start = 12_000e6; // Scene: 10,000 cash plus 2,000 spent on sets, all deposited
        _randomHistory(seed);
        emit log_named_uint("settled steps", settledCount);
        vm.warp(ex.marketOf(m).tradingClose);
        ex.proposeOutcome(m, 255, bytes32(uint256(1)));
        vm.warp(block.timestamp + 1 days);
        ex.finalize(m);
        for (uint256 i; i < 4; ++i) {
            vm.prank(ws[i]);
            ex.redeem(m);
        }
        uint256 sumCash;
        for (uint256 i; i < 4; ++i) {
            assertEq(ex.cash(ws[i]), start, "after an unwind every wallet holds exactly what it deposited");
            sumCash += ex.cash(ws[i]);
        }
        X.Market memory k = ex.marketOf(m);
        assertEq(k.unwindPool, 0, "the unwind pool is exactly spent");
        assertEq(usd.balanceOf(address(ex)), sumCash, "the contract owes nothing and holds nothing more");
    }

    function testFuzz_adv_winner_conservationAndNoStuckMoney(uint256 seed) public {
        _randomHistory(seed);
        vm.warp(ex.marketOf(m).tradingClose);
        uint8 win = uint8(_r(seed, 999) % 3);
        ex.proposeOutcome(m, win, bytes32(uint256(1)));
        vm.warp(block.timestamp + 1 days);
        ex.finalize(m);
        for (uint256 i; i < 4; ++i) {
            vm.prank(ws[i]);
            ex.redeem(m);
        }
        X.Market memory k = ex.marketOf(m);
        uint256 sumCash;
        for (uint256 i; i < 4; ++i) {
            sumCash += ex.cash(ws[i]);
        }
        assertEq(k.collateral, 0, "every winning share was paid");
        assertEq(k.profitHeldTotal, 0, "every held profit was released");
        assertEq(k.feesHeld, 0);
        assertEq(usd.balanceOf(address(ex)), sumCash + ex.treasuryBalance(), "no USDC stuck, none missing");
        assertEq(sumCash + ex.treasuryBalance(), 4 * 12_000e6, "total money is conserved");
    }
}
