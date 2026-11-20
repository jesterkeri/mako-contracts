// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MakoFunder} from "../src/MakoFunder.sol";

/// Owner of the funder; drives every call with fuzzed arguments and records ghost state.
contract FunderHandler is Test {
    MakoFunder public f;
    address[6] public pool = [address(0x2001), address(0x2002), address(0x2003), address(0x2004), address(0x2005), address(0x2006)];
    address public constant OUT = address(0x7777);

    mapping(uint256 => uint256) public topUpsOnDay;
    uint256 public maxTopUpsOnADay;
    bool public sentMoreThanRoom;
    bool public sentMoreThanAmount;
    bool public keysAboveCapAfterTopUp;
    uint256 public totalIn; // deposits
    uint256 public totalOut; // topUp + withdraw + close
    uint256 public topUpCalls;

    constructor() {
        vm.warp(1_000 days);
        vm.roll(10);
        f = new MakoFunder(10 ether);
        vm.deal(address(this), 1e24);
        deposit(50 ether);
    }

    function deposit(uint256 amt) public {
        amt = bound(amt, 0, 100 ether);
        (bool ok,) = address(f).call{value: amt}("");
        require(ok);
        totalIn += amt;
    }

    function strangerToKey(uint256 i, uint256 amt) external {
        amt = bound(amt, 0, 20 ether);
        vm.deal(pool[i % 6], pool[i % 6].balance + amt);
    }

    function spend(uint256 i, uint256 amt) external {
        address k = pool[i % 6];
        vm.deal(k, k.balance - bound(amt, 0, k.balance));
    }

    function addKey(uint256 i) external {
        try f.addKey(pool[i % 6]) {} catch {}
    }

    function retireKey(uint256 i) external {
        try f.retireKey(pool[i % 6]) {} catch {}
    }

    function setCap(uint256 c) external {
        try f.setCap(bound(c, 0, 40 ether)) {} catch {}
    }

    function withdraw(uint256 amt) external {
        amt = bound(amt, 0, address(f).balance);
        try f.withdraw(OUT, amt) {
            totalOut += amt;
        } catch {}
    }

    function close() external {
        uint256 bal = address(f).balance;
        try f.close(OUT) {
            totalOut += bal;
        } catch {}
    }

    function advance(uint256 secs, uint256 blocks) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 3 days));
        vm.roll(vm.getBlockNumber() + bound(blocks, 1, 50));
    }

    /// `rBack`: how far behind the current block the reconciliation block is; `badDay` sometimes lies.
    function topUp(uint256 amount, uint256 rBack, uint256 spendAfter, bool badDay) external {
        amount = bound(amount, 0, 30 ether);
        uint256 r = vm.getBlockNumber() - bound(rBack, 1, vm.getBlockNumber());
        // a key spends between r and the call
        uint256 i = spendAfter % 6;
        vm.deal(pool[i], pool[i].balance - bound(spendAfter, 0, pool[i].balance));
        uint256 day = vm.getBlockTimestamp() / 1 days;
        if (badDay) day += 1;
        uint256 sumBefore = f.keysBalance();
        uint256 capNow = f.cap();
        uint256 balBefore = address(f).balance;
        topUpCalls++;
        try f.topUp(r, amount, day) {
            uint256 sent = balBefore - address(f).balance;
            totalOut += sent;
            if (sent > amount) sentMoreThanAmount = true;
            if (capNow < sumBefore || sent > capNow - sumBefore) sentMoreThanRoom = true;
            if (f.keysBalance() > capNow) keysAboveCapAfterTopUp = true;
            uint256 n = ++topUpsOnDay[day];
            if (n > maxTopUpsOnADay) maxTopUpsOnADay = n;
        } catch {}
    }
}

contract MakoFunderInvariantTest is Test {
    FunderHandler h;
    MakoFunder f;

    function setUp() public {
        h = new FunderHandler();
        f = h.f();
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](10);
        sel[0] = h.deposit.selector;
        sel[1] = h.strangerToKey.selector;
        sel[2] = h.spend.selector;
        sel[3] = h.addKey.selector;
        sel[4] = h.retireKey.selector;
        sel[5] = h.setCap.selector;
        sel[6] = h.withdraw.selector;
        sel[7] = h.close.selector;
        sel[8] = h.advance.selector;
        sel[9] = h.topUp.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    function invariant_topUpNeverSendsMoreThanRoomOrAmount() public view {
        assertFalse(h.sentMoreThanRoom());
        assertFalse(h.sentMoreThanAmount());
        assertFalse(h.keysAboveCapAfterTopUp());
    }

    function invariant_atMostOneTopUpPerUtcDay() public view {
        assertLe(h.maxTopUpsOnADay(), 1);
    }

    function invariant_balanceFallsOnlyByTopUpWithdrawClose() public view {
        // contract balance = deposits - everything that left through the three outgoing paths
        assertEq(address(f).balance, h.totalIn() - h.totalOut());
    }

    function invariant_ownerCanAlwaysWithdrawTheDeposit() public {
        uint256 snap = vm.snapshotState();
        uint256 bal = address(f).balance;
        address to = address(0x9999);
        uint256 before = to.balance;
        vm.prank(address(h));
        f.withdraw(to, bal);
        assertEq(to.balance - before, bal);
        assertEq(address(f).balance, 0);
        vm.revertToState(snap);
    }

    function invariant_keyListNeverExceedsFour() public view {
        assertLe(f.keys().length, 4);
    }
}
