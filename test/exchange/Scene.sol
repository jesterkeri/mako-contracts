// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ExchangeBase} from "./ExchangeBase.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// @notice A three-option market with a taker T and makers A, B, C, each holding cash and complete sets, and builders
/// for the five call shapes the plan names: direct buy, direct sell, direct with three makers, mint N = 3, merge N = 3.
abstract contract Scene is ExchangeBase {
    uint256 internal m;
    address internal T;
    address internal A;
    address internal B;
    address internal C;
    address[] internal ws;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(1_700_000_000); // a realistic clock, so `timestamp - 1` is a real past second
        m = _market(3);
        (, T) = _party("T", m, 10_000e6, 2_000e6);
        (, A) = _party("A", m, 10_000e6, 2_000e6);
        (, B) = _party("B", m, 10_000e6, 2_000e6);
        (, C) = _party("C", m, 10_000e6, 2_000e6);
        ws.push(T);
        ws.push(A);
        ws.push(B);
        ws.push(C);
    }

    function _mk(X.Order memory t, X.Order[] memory ms, uint256 tf, uint128[] memory fs)
        internal
        view
        returns (Call memory c)
    {
        c.t = t;
        c.ms = ms;
        c.fs = fs;
        c.tf = uint128(tf);
        c.mss = new bytes[](ms.length);
        _resign(c);
    }

    /// @dev T buys option 0 up to 70 against A selling option 0 at 40; `size` shares.
    function _dBuy1(uint256 size) internal view returns (Call memory) {
        return _mk(_order(T, m, 0, true, 70, size), _one(_order(A, m, 0, false, 40, size)), size, _oneFill(size));
    }

    /// @dev T sells option 0 down to 30 against A buying option 0 at 50.
    function _dSell1(uint256 size) internal view returns (Call memory) {
        return _mk(_order(T, m, 0, false, 30, size), _one(_order(A, m, 0, true, 50, size)), size, _oneFill(size));
    }

    /// @dev T buys 90 shares against A (40 at 30), B (30 at 40), C (20 at 50).
    function _direct3() internal view returns (Call memory c) {
        X.Order[] memory ms = new X.Order[](3);
        ms[0] = _order(A, m, 0, false, 30, 40e6);
        ms[1] = _order(B, m, 0, false, 40, 30e6);
        ms[2] = _order(C, m, 0, false, 50, 20e6);
        uint128[] memory fs = new uint128[](3);
        fs[0] = 40e6;
        fs[1] = 30e6;
        fs[2] = 20e6;
        return _mk(_order(T, m, 0, true, 70, 90e6), ms, 90e6, fs);
    }

    /// @dev Mint N = 3: T buys option 0 (limit 60), A buys option 1 at 20, B buys option 2 at 30, so T pays 50.
    function _mint3(uint256 size) internal view returns (Call memory c) {
        X.Order[] memory ms = _two(_order(A, m, 1, true, 20, size), _order(B, m, 2, true, 30, size));
        return _mk(_order(T, m, 0, true, 60, size), ms, size, _twoFill(size, size));
    }

    /// @dev Merge N = 3: T sells option 0 (limit 40), A sells option 1 at 20, B sells option 2 at 30, so T receives 50.
    function _merge3(uint256 size) internal view returns (Call memory c) {
        X.Order[] memory ms = _two(_order(A, m, 1, false, 20, size), _order(B, m, 2, false, 30, size));
        return _mk(_order(T, m, 0, false, 40, size), ms, size, _twoFill(size, size));
    }

    // ------------------------------------------------------------------------------------------------ conservation
    function _sumNet(uint256 mid) internal view returns (uint256 n, uint256 h) {
        for (uint256 i; i < ws.length; ++i) {
            (uint256 a, uint256 b) = ex.recOf(mid, ws[i]);
            n += a;
            h += b;
        }
    }

    /// @dev X1 (shares of every option equal the sets outstanding), X15 (collateral + fees + held = sum of nets) and X2 as
    /// an equality (the contract holds exactly what it owes) for the market `mid`, with only the scene's parties
    /// holding anything. Valid before finalization and with no other market live.
    function _assertConserved(uint256 mid) internal view {
        X.Market memory mk = ex.marketOf(mid);
        for (uint8 o; o < mk.nOptions; ++o) {
            uint256 s;
            for (uint256 i; i < ws.length; ++i) {
                s += ex.positionOf(mid, o, ws[i]);
            }
            assertEq(s, mk.setsOutstanding, "X1 shares of an option equal sets outstanding");
        }
        (uint256 n, uint256 h) = _sumNet(mid);
        assertEq(uint256(mk.collateral) + mk.feesHeld + h, n, "X15 collateral + feesHeld + profitHeld == sum of nets");
        assertEq(h, mk.profitHeldTotal, "profitHeldTotal is the sum of the held profits");
        assertEq(mk.collateral, mk.setsOutstanding, "one USDC backs each set");
        uint256 cashSum;
        for (uint256 i; i < ws.length; ++i) {
            cashSum += ex.cash(ws[i]);
        }
        assertEq(
            usd.balanceOf(address(ex)),
            cashSum + mk.collateral + mk.feesHeld + h + ex.treasuryBalance(),
            "X2 the contract holds exactly what it owes"
        );
    }
}
