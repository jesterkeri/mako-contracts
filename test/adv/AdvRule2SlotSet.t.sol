// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {GasMonotoneTest} from "../exchange/GasMonotone.t.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// Adversary, item 6 (tests that pass against a broken contract).
///
/// `GasMonotone.t.sol::test_gasMonotone_rule2_sameWritesWhetherOrNotAReceiptIsHeld` claims "the number of storage writes
/// depends on a party's net" is false, but it only COUNTS writes. A contract whose `_receive` writes the seller's cash
/// slot only when something reaches free cash, and the market's held-profit slot only when something is held, writes
/// exactly ONE of the two on each branch, so the count is equal while the set of slots written differs (plan 3.1 rule 2:
/// "no read or write is skipped or added because of a party-controlled value"). That mutant passes the whole default
/// `forge test`; only the Monad-schedule run of the gas fuzz catches it.
///
/// This test compares the SET of (slot) written by the same match when the seller's receipt is held and when it is
/// free. It passes on the real contract and fails on that mutant, under the default schedule.
contract AdvRule2SlotSet is GasMonotoneTest {
    function _writtenSlots(bool sellerHoldsReceipt) internal returns (bytes32[] memory out) {
        delete ps;
        M = _market(2);
        string memory tag = sellerHoldsReceipt ? "adv-held" : "adv-free";
        (address t, uint256 tk) = _pair(string.concat(tag, "-taker"));
        (address s, uint256 sk) = _pair(string.concat(tag, "-seller"));
        _deposit(t, 100e6);
        _deposit(s, 1e6);
        if (sellerHoldsReceipt) {
            _seed(s, 0, 10 * SHARE);
            _touchNet(s); // a record at net zero: the whole receipt is held
        } else {
            _mint(s, M, 10 * SHARE); // net 10: the receipt is all free cash
        }
        X.Order memory to = _order(t, M, 0, true, 70, 10 * SHARE);
        X.Order[] memory ms = _one(_order(s, M, 0, false, 40, 10 * SHARE));
        bytes memory d = abi.encodeCall(
            X.matchOrders, (to, _sign(tk, to), ms, _oneSig(_sign(sk, ms[0])), _oneFill(10 * SHARE), uint128(10 * SHARE))
        );
        vm.startStateDiffRecording();
        vm.prank(operator);
        (bool ok,) = address(ex).call(d);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        require(ok, "fixture: the match must settle");
        // the slots of the exchange the call WROTE, by distance from the party-independent ones: record slot NAMES that do
        // not depend on the party (the market's own slots) and the CLASS of each party slot (cash, record, shares, order)
        bytes32[] memory tmp = new bytes32[](64);
        uint256 n;
        for (uint256 i; i < acc.length; ++i) {
            for (uint256 j; j < acc[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory sa = acc[i].storageAccesses[j];
                if (sa.account == address(ex) && sa.isWrite) tmp[n++] = _classify(sa.slot);
            }
        }
        out = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = tmp[i];
        }
    }

    /// @dev Slot -> a label that is the same whichever wallet it belongs to: the market slots keep their offset, a mapping
    /// slot is labelled by the mapping it lives in (found by recomputing each mapping's slot for the three wallets).
    function _classify(bytes32 slot) internal view returns (bytes32) {
        uint256 base = uint256(keccak256(abi.encode(M, MARKETS_SLOT)));
        for (uint256 off; off < 6; ++off) {
            if (uint256(slot) == base + off) return bytes32(uint256(100 + off)); // market slot `off`
        }
        for (uint256 i; i < ps.length; ++i) {
            address a = ps[i].a;
            // cash: _cash is slot 9 (admin 3, pendingAdmin 4, resolver+paused 5, marketCount 6, treasuryBalance 7, _lock 8)
            if (slot == keccak256(abi.encode(a, uint256(9)))) return bytes32(uint256(1));
            if (slot == keccak256(abi.encode(keccak256(abi.encode(M, a)), REC_SLOT))) return bytes32(uint256(2));
            for (uint256 o; o < 3; ++o) {
                if (slot == _shareSlot(M, uint8(o), a)) return bytes32(uint256(3));
            }
        }
        return bytes32(uint256(4)); // an order record (keyed by order hash)
    }

    function _sorted(bytes32[] memory a) internal pure returns (bytes32[] memory) {
        for (uint256 i; i < a.length; ++i) {
            for (uint256 j = i + 1; j < a.length; ++j) {
                if (a[j] < a[i]) (a[i], a[j]) = (a[j], a[i]);
            }
        }
        return a;
    }

    function test_adv_rule2_theSetOfSlotsWritten_doesNotDependOnWhetherAReceiptIsHeld() public {
        bytes32[] memory free = _sorted(_writtenSlots(false));
        bytes32[] memory held = _sorted(_writtenSlots(true));
        assertGt(free.length, 8, "fixture: a real settlement writes");
        assertEq(held.length, free.length, "write count differs");
        for (uint256 i; i < free.length; ++i) {
            assertEq(held[i], free[i], "a different slot is written when the receipt is held than when it is free");
        }
    }
}
